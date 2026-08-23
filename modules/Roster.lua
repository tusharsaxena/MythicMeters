-- modules/Roster.lua
--
-- Who is in the group, and which of the meter's rows belong to them.
--
-- ---------------------------------------------------------------------------
-- WHY THIS FILE EXISTS
-- ---------------------------------------------------------------------------
--
-- C_DamageMeter reports SOURCES, not group members. A session's combatSources
-- contains everything that did the thing being measured — party members, raid
-- members, their pets and guardians, and (for the enemy-facing stats) mobs. It
-- carries a sourceGUID, a name, a class and a classification, and it carries NO
-- link from a pet to its owner and no statement of group membership.
--
-- So the two facts the grid is built on — "is this row one of us" and "whose pet
-- is this" — have to come from the UNIT API instead, and this file is where the
-- two data sources are married. Everything it produces is keyed on GUID, which
-- is the only field plain enough to be a legal join key (design §5).
--
-- Nothing here touches a meter value. The roster is built entirely from
-- UnitGUID / UnitName / UnitClass / UnitGroupRolesAssigned.
--
-- ---------------------------------------------------------------------------
-- A UNIT GUID IS NOT ALWAYS PLAIN — THE CORRECTION THAT COST A DUNGEON RUN
-- ---------------------------------------------------------------------------
--
-- NEITHER source of GUIDs is reliably plain. The meter's own sourceGUID comes
-- back SECRET under the Combat restriction (see modules/Aggregator.lua), and the
-- UNIT API is no better: in a follower dungeon
-- `UnitGUID("party3pet")` answers a SECRET string, and the assignment below
-- raised "attempted to perform indexed assignment on a table that cannot be
-- indexed with secret keys" on every refresh tick for the entire run.
--
-- So every GUID that came from a unit token passes NS.Secrets.IsSafeKey before
-- it is used as a key, and every public lookup here checks its ARGUMENT the same
-- way. That second half is what keeps the guard from being one file deep:
-- modules/Aggregator.lua keys its row table on whatever owningMember() returned,
-- and owningMember only ever returns a GUID these lookups accepted. Refusing
-- here is therefore what stops a secret reaching a key anywhere downstream.
--
-- ---------------------------------------------------------------------------
-- PET ATTRIBUTION IS BEST EFFORT, AND SAYS SO
-- ---------------------------------------------------------------------------
--
-- The owner map is built by asking UnitGUID for every group member's pet unit
-- ("playerpet", "party3pet", "raid17pet"). That is EXACT for what it covers: if
-- the map says a GUID belongs to raid17, it does. What it does not cover is
-- everything that is not the unit-frame pet — guardians, totems, temporary
-- summons, a second pet, and any pet belonging to a member who is out of range
-- of the unit API at the moment the map was built.
--
-- An unattributable pet returns nil from OwnerOf, and the aggregator DROPS its
-- row rather than showing it. A phantom row with a pet's name in a group meter
-- is worse than a slightly low number: the number is explainable, the row looks
-- like a bug (design §5).
--
-- ---------------------------------------------------------------------------
-- IT DOES NOT SEND ROSTER_CHANGED — A DELIBERATE DEVIATION FROM THE BRIEF
-- ---------------------------------------------------------------------------
--
-- The build brief made this module the sole SENDER of the roster message. It
-- cannot be, and should not be: core/MultiMeters.lua is the addon's single game
-- event listener (architecture-§4), it already registers GROUP_ROSTER_UPDATE,
-- and it already wipes this module's cache and publishes
-- Constants.MSG.ROSTER_CHANGED. A second sender would be a second source of
-- truth for one transition, and a second GROUP_ROSTER_UPDATE registration would
-- put an event listener in a module.
--
-- So the direction is inverted: this module SUBSCRIBES to ROSTER_CHANGED and
-- rebuilds. The message keeps exactly one sender; it is just not this file.
--
-- ---------------------------------------------------------------------------
-- CACHING
-- ---------------------------------------------------------------------------
--
-- The map is rebuilt lazily on first read after an invalidation, not eagerly in
-- the event handler. A raid regroup can fire GROUP_ROSTER_UPDATE a dozen times
-- in a second while nothing is on screen; building on demand collapses that to
-- one build at the next refresh. The cache lives in core/State.lua's shared
-- cache under "Roster" — the same sub-table core/MultiMeters.lua wipes — so
-- there is one invalidation seam rather than two that can fall out of step.

local addonName, NS = ...

local Roster = NS:NewModule("Roster", "AceEvent-3.0")
NS.Roster = Roster

local State   = NS.State
local Secrets = NS.Secrets
local Const   = NS.Constants
local MSG     = Const.MSG

-- NO PERF BRACKET IN THIS FILE. The rebuild is lazy, so it happens INSIDE
-- modules/Aggregator.lua's "aggregate" bracket on the first read after an
-- invalidation and is already counted there. A second bracket would double-count
-- the same microseconds into two buckets and make the report lie about where a
-- refresh went (performance-§2).

-- The shared cache sub-table, held as an upvalue. Safe because State.WipeCache
-- wipes IN PLACE rather than reassigning — a detail core/State.lua documents
-- precisely so a module may do this.
local cache = State.Cache("Roster")

-- ---------------------------------------------------------------------------
-- THE STICKY HALF, AND WHY THERE ARE TWO CACHES
-- ---------------------------------------------------------------------------
--
-- `cache` above answers "who is in the group RIGHT NOW", and is dropped on every
-- roster change. That is the correct answer to the question it is asked, and it
-- was the wrong thing for the grid to be built on.
--
-- WHAT WENT WRONG. modules/Aggregator.lua drops any source the roster cannot
-- place. Leave a dungeon group and the live roster collapses to `{ player }` — so
-- the window instantly showed one row, the player's own, for a session that still
-- held everybody's numbers. The data was intact; the filter had thrown it away.
-- Pets went the same way and for the same reason: `OwnerOf` is built from the
-- unit API, and there is no `party3pet` once you have left the party.
--
-- `seen` is the fix. Every member and every pet-owner link the live build learns
-- is ALSO written here, and nothing removes an entry — this table only grows.
--
-- ITS LIFETIME IS THE METER'S DATA, not the group's and not the session's — so
-- it is PERSISTED, in `db.global.roster`, and not in the session cache where it
-- started. The meter's numbers survive a `/reload`; a map of who those GUIDs
-- belong to that does not survive one puts the bug straight back, because the
-- filter throws the surviving data away all over again on the next login.
--
-- Global rather than per-profile: it describes the CLIENT's meter data, which one
-- AceDB profile does not own and a profile swap does not change.
--
-- Cleared when C_DamageMeter resets — the moment the numbers those GUIDs belonged
-- to stop existing. Until then a player who fought beside you belongs on the
-- meter whether or not they are still grouped, and whether or not you have
-- reloaded since.
---
--- @return table  { byGuid = {...}, pets = {...} }
local function remembered()
    local db = NS.db
    local g = db and db.global
    if not g then
        -- Before InitDB, or on an install broken enough to have no database. A
        -- throwaway table keeps every caller below branch-free; nothing is lost
        -- that was not already lost.
        return { byGuid = {}, pets = {} }
    end
    g.roster = g.roster or {}
    g.roster.byGuid = g.roster.byGuid or {}
    g.roster.pets   = g.roster.pets or {}
    return g.roster
end

-- Unit APIs are reached through _G at CALL time rather than captured at load.
-- Two reasons, and both are real: the headless test harness installs its unit
-- mocks after the files load, so a load-time capture would freeze the real
-- globals (or nil) in place; and a client missing one of them must degrade to a
-- solo roster rather than error, which a guarded read gives for free.
local function unitGUID(unit)  local f = _G.UnitGUID  return f and f(unit) end
local function unitName(unit)  local f = _G.UnitName  return f and f(unit) end
local function unitExists(unit) local f = _G.UnitExists return f and f(unit) and true or false end

local function unitClassFile(unit)
    local f = _G.UnitClass
    if not f then return nil end
    local _, classFilename = f(unit)
    return classFilename
end

--- The role this unit is playing.
---
--- TWO SOURCES, and the second is not a nicety. `UnitGroupRolesAssigned` answers
--- the role the GROUP assigned, and there is no group to assign one when you are
--- solo or in a party that never set roles — so it answers "NONE", and the row's
--- role icon silently disappeared for a player who had the setting switched on
--- and could see the icon perfectly well five minutes earlier in a dungeon.
---
--- The fallback is the player's own SPECIALIZATION role, which is what they are
--- actually doing whether or not anybody wrote it down. Available for the local
--- player only — GetSpecializationRole reads the active spec, and there is no
--- such call for an arbitrary unit — which is exactly the case the assigned role
--- fails to cover.
local function unitRole(unit)
    local f = _G.UnitGroupRolesAssigned
    local role = f and f(unit)
    if role == "TANK" or role == "HEALER" or role == "DAMAGER" then return role end

    if unit == "player" then
        local getSpec     = _G.GetSpecialization
        local getSpecRole = _G.GetSpecializationRole
        local spec = getSpec and getSpec()
        local specRole = spec and getSpecRole and getSpecRole(spec)
        if specRole == "TANK" or specRole == "HEALER" or specRole == "DAMAGER" then
            return specRole
        end
    end

    -- The API answers "NONE" for an unassigned member and nil for a unit that
    -- does not exist; both mean the same thing to the row's role icon.
    return "NONE"
end

-- ---------------------------------------------------------------------------
-- Building the map
-- ---------------------------------------------------------------------------

--- The ordered unit tokens of the current group: the player first, then the
--- other members in group order.
---
--- Player-first is not cosmetic. `roster` sort mode uses this order verbatim,
--- and a player wants to find themselves at a fixed place in the list rather
--- than wherever the raid frames happen to have put them.
---
--- Solo — genuinely not in a group — still yields { "player" }, so every
--- downstream consumer has a one-entry roster instead of an empty-case branch.
---
--- @return table  array of unit tokens
local function groupUnits()
    local units = { "player" }

    local inRaid   = _G.IsInRaid and _G.IsInRaid()
    local numGroup = (_G.GetNumGroupMembers and _G.GetNumGroupMembers()) or 0

    if inRaid then
        -- In a raid the player is one of raidN, so "player" would be listed
        -- twice; the duplicate is filtered by GUID during the build below rather
        -- than by working out which raid index we are, which changes under us on
        -- every regroup.
        for i = 1, numGroup do units[#units + 1] = "raid" .. i end
    else
        for i = 1, numGroup - 1 do units[#units + 1] = "party" .. i end
    end

    return units
end

--- The pet unit token for a group unit, or nil where there cannot be one.
---
--- "playerpet" / "partyNpet" / "raidNpet" are the only pet units the API
--- exposes, which is exactly the limit on pet attribution described in the
--- header.
local function petUnitFor(unit)
    if unit == "player" then return "playerpet" end
    return unit .. "pet"
end

--- Rebuild the group array, the GUID index and the pet-owner map.
---
--- One pass, three outputs, because they are derived from the same unit walk and
--- splitting them would walk the group three times on every regroup.
local function build()
    -- TEST MODE MOCKS THE UNIT API, exactly as it mocks the meter.
    --
    -- The two have to move together: mocking only the meter would leave this
    -- filter dropping every invented row as "not in your group", which is the
    -- live behavior correctly applied to test data and useless. Resolved at CALL
    -- time because modules/Aggregator.lua loads after this file.
    if State.testMode then
        local A = NS.Aggregator
        if A and A.TestGroup then
            local group, byGuid = A.TestGroup(), {}
            for _, entry in ipairs(group) do byGuid[entry.guid] = entry end
            cache.group, cache.byGuid, cache.pets = group, byGuid, {}
            return group
        end
    end

    local group, byGuid, pets = {}, {}, {}
    local petCount = 0
    local seenMap = remembered()

    for _, unit in ipairs(groupUnits()) do
        if unitExists(unit) then
            local guid = unitGUID(unit)
            -- byGuid doubles as the duplicate filter for the raid case above:
            -- the player appears as both "player" and "raidN", and the first
            -- entry (which is "player", by construction) wins.
            --
            -- IsSafeKey covers the nil case and the secret case in one question,
            -- and both mean the same thing here: this member cannot be joined on,
            -- so it is left out rather than entered under a key that raises.
            if Secrets.IsSafeKey(guid) and byGuid[guid] == nil then
                local entry = {
                    guid          = guid,
                    unit          = unit,
                    name          = unitName(unit),
                    classFilename = unitClassFile(unit),
                    role          = unitRole(unit),
                    isPlayer      = (unit == "player"),
                }
                group[#group + 1] = entry
                byGuid[guid] = entry
                -- Remembered for the life of the meter's DATA, not the group's
                -- and not the session's. Stored as a plain copy rather than as
                -- the live entry: this goes to SavedVariables, and the entry is
                -- shared with the live map that gets wiped on every regroup.
                seenMap.byGuid[guid] = {
                    guid          = guid,
                    name          = entry.name,
                    classFilename = entry.classFilename,
                    role          = entry.role,
                    isPlayer      = entry.isPlayer,
                }

                local petUnit = petUnitFor(unit)
                if unitExists(petUnit) then
                    local petGuid = unitGUID(petUnit)
                    -- THE LINE THIS FILE EXISTS TO GET RIGHT. A follower
                    -- dungeon's companion pets answer UnitGUID with a SECRET
                    -- string, and keying on one raises on every refresh for the
                    -- whole run. An unreadable pet is exactly the "cannot prove
                    -- whose this is" case the header already describes, so it
                    -- falls through to the same handling: no map entry, OwnerOf
                    -- answers nil, and modules/Aggregator.lua drops the row.
                    if Secrets.IsSafeKey(petGuid) then
                        pets[petGuid] = guid
                        seenMap.pets[petGuid] = guid
                        petCount = petCount + 1
                    end
                end
            end
        end
    end

    -- AN UNDER-POPULATED BUILD IS NOT CACHED, and this is the fix for a window
    -- that stayed empty for an entire boss fight.
    --
    -- What happened: the roster is invalidated on GROUP_ROSTER_UPDATE and
    -- PLAYER_ENTERING_WORLD, and both of those fire BEFORE the unit API has
    -- populated. The next read built a map with almost nobody in it, cached that,
    -- and nothing invalidated it again — so for the whole pull every source the
    -- meter reported was dropped as "not in your group". The debug log showed it
    -- exactly: `rows=0 dropped=10` for forty seconds, then one `[Roster] built
    -- members=5` after combat and `rows=5` immediately after.
    --
    -- `GetNumGroupMembers` is the cross-check, and it is a fair one: it is
    -- populated well before the individual unit tokens are, so "the API says five
    -- and I found two" is a reliable "ask again in a moment". Leaving the cache
    -- cold makes the next refresh retry — a quarter of a second later — and the
    -- map self-corrects instead of being wrong until the group next changes.
    --
    -- The result is still RETURNED, so this pass renders with what there is
    -- rather than with nothing.
    cache.group  = group
    cache.byGuid = byGuid
    cache.pets   = pets

    -- MARKED, not withheld. The map is stored either way so every lookup below
    -- has something to answer from; what `partial` changes is that `ensure` will
    -- build again on the next read instead of trusting it.
    local expected = (_G.GetNumGroupMembers and _G.GetNumGroupMembers()) or 0
    cache.partial = (expected > 1 and #group < expected) or nil
    if cache.partial then
        if State.debug then
            NS.Debug("Roster", "partial build (%d of %d) — will retry", #group, expected)
        end
        return group
    end

    -- ONE line per build, format DEFERRED — the arguments are counters the loop
    -- already kept, so nothing is built at the call site (debug-logging-§3).
    if State.debug then
        NS.Debug("Roster", "built members=%d pets=%d raid=%s", #group, petCount,
            (_G.IsInRaid and _G.IsInRaid()) and "yes" or "no")
    end

    return group
end

--- Build if the cache is cold; otherwise hand back what is there.
--- Build if the cache is cold OR if what is there is known to be short.
---
--- THE RETRY IS THE FIX FOR AN EMPTY WINDOW. The roster is invalidated on
--- GROUP_ROSTER_UPDATE and PLAYER_ENTERING_WORLD, and both fire BEFORE the unit
--- API has populated. The next read built a map with almost nobody in it, cached
--- it, and nothing invalidated it again — so for an entire boss fight every
--- source the meter reported was dropped as "not in your group". The live debug
--- log showed exactly that: `rows=0 dropped=10` for forty seconds, then one
--- `[Roster] built members=5` after combat and `rows=5` on the very next pass.
---
--- `GetNumGroupMembers` is the cross-check and it is a fair one: it populates
--- well before the individual unit tokens do, so "the API says five and I found
--- two" is a reliable "ask again in a moment". Retrying costs one unit walk per
--- refresh — a quarter of a second apart — and only until the group resolves.
local function ensure()
    local group = cache.group
    if group and not cache.partial then return group end
    return build()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- The group, in display order: the player first, then party1..N / raid1..N.
---
--- Entries are { guid, unit, name, classFilename, role, isPlayer }. Every field
--- is plain data — no meter value ever enters this table — so callers may
--- compare, sort and key on any of it freely. That is the whole reason `roster`
--- sort mode is legal mid-pull when `value` mode is not.
---
--- @return table  array of member entries
function Roster.GetGroup()
    return ensure()
end

--- The LOCAL player's GUID, from the unit API, or nil before the map has built.
---
--- THE ONE IDENTITY THAT SURVIVES THE RESTRICTION. `C_DamageMeter` hands back a
--- SECRET `sourceGUID` while the Combat restriction is active — the meter's GUID
--- is not the plain join key this addon was designed around — so mid-pull a
--- source cannot be looked up, keyed on, or compared. What it can still say for
--- itself is `isLocalPlayer`, which stays plain, and this is the plain GUID that
--- claim resolves to. modules/Aggregator.lua is the caller; see the note there.
---
--- Read off the built map rather than from `UnitGUID("player")` directly, so the
--- answer is the same string the rest of the map is keyed on and a row built
--- from it joins the roster's own name, class and role.
---
--- @return string|nil
function Roster.LocalGUID()
    local group = ensure()
    for i = 1, #group do
        if group[i].isPlayer then return group[i].guid end
    end
    return nil
end

--- One member entry by GUID, or nil.
---
--- Preferred over reading a name off the meter's source row where both exist:
--- the meter's `name` field is ConditionalSecret and may be opaque mid-pull,
--- while this one came from UnitName and is always plain text.
---
--- @param guid string
--- @return table|nil
function Roster.Get(guid)
    if not Secrets.IsSafeKey(guid) then return nil end
    ensure()
    -- Live group first, remembered second. The live entry is the fresher of the
    -- two — a player who respecced has a new spec icon — and the remembered one
    -- is what keeps a row alive after the group is gone.
    return cache.byGuid[guid] or remembered().byGuid[guid]
end

--- Whether `guid` is a member of the current group.
---
--- The aggregator's primary filter. A GUID is never secret, so this is an
--- ordinary table lookup and is legal at any point in a pull.
---
--- @param guid string
--- @return boolean
function Roster.IsGroupMember(guid)
    if not Secrets.IsSafeKey(guid) then return false end
    ensure()
    if cache.byGuid[guid] ~= nil then return true end
    -- "Was in the group while this data was being collected" is the question the
    -- grid actually means. Answering the narrower "is in the group at this
    -- instant" is what emptied the window on leaving a dungeon.
    return remembered().byGuid[guid] ~= nil
end

--- The owner of a pet GUID, or nil when it cannot be attributed.
---
--- BEST EFFORT — see the header. nil means "this addon cannot prove whose this
--- is", and the caller's contract is to DROP the row, not to guess.
---
--- @param petGUID string
--- @return string|nil  owner GUID
function Roster.OwnerOf(petGUID)
    if not Secrets.IsSafeKey(petGUID) then return nil end
    ensure()
    return cache.pets[petGUID] or remembered().pets[petGUID]
end

--- The assigned role for a GUID: "TANK" / "HEALER" / "DAMAGER" / "NONE".
---
--- Answers "NONE" for a GUID that is not in the group rather than nil, so a row
--- icon has one code path. A caller that needs to distinguish "not in the group"
--- asks IsGroupMember, which is the question it actually means.
---
--- @param guid string
--- @return string
function Roster.RoleOf(guid)
    local entry = Roster.Get(guid)
    return (entry and entry.role) or "NONE"
end

--- Drop the cached LIVE map. The next read rebuilds it.
---
--- Called on the roster message and on a zone-in. Deliberately does NOT rebuild
--- here: a raid regroup fires the underlying event repeatedly, and rebuilding
--- eagerly would do the work once per event instead of once per refresh.
---
--- LEAVES THE REMEMBERED MAP ALONE, which is the whole reason there are two (see
--- the header). Wiping it here would put back the bug this split exists to fix:
--- leaving a dungeon group fires the roster message, and the window would empty
--- itself of everyone you had just fought beside.
function Roster.Refresh()
    State.WipeCache("Roster")
end

--- Forget everyone — live and remembered.
---
--- The meter-reset path, and the ONLY thing that clears the remembered map. A
--- reset is the moment the numbers those GUIDs belonged to stopped existing,
--- which is precisely when remembering them stops being useful and starts being
--- a list of strangers.
---
--- core/MultiMeters.lua's reset handler wipes every cache namespace and so
--- reaches both of these already; this exists so a caller that means "the meter
--- was reset" has one spelling for it rather than having to know there are two
--- namespaces to clear.
function Roster.Forget()
    State.WipeCache("Roster")
    local db = NS.db
    if db and db.global then db.global.roster = { byGuid = {}, pets = {} } end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
--
-- Bus subscriptions only. core/MultiMeters.lua owns GROUP_ROSTER_UPDATE and
-- PLAYER_ENTERING_WORLD and publishes both onto the bus; this module listens.
-- See the header for why the message's sender is there and not here.
--
-- ENTERING_WORLD matters as much as the roster message does: on a zone-in the
-- group is unchanged but the unit API has not populated yet, so a map built a
-- frame earlier can be full of nils that never correct themselves.

-- TEST_MODE_CHANGED is here for the same reason as the other three: it changes
-- WHICH GROUP the map describes. build() substitutes the mocked unit API while
-- test mode is on, but that substitution only happens on a BUILD, and by the
-- time anybody types `/mm test` the map is long since warm — so the invented
-- sources were joined against the real group, modules/Aggregator.lua dropped
-- every one of them as "not in your group", and the test grid was empty with no
-- notice to explain it (preview suppresses the notice). Leaving test mode is the
-- same bug reversed: the mocked group stayed cached and every REAL source was
-- dropped until the next regroup.
function Roster:OnEnable()
    self:RegisterMessage(MSG.ROSTER_CHANGED,    "OnRosterChanged")
    self:RegisterMessage(MSG.ENTERING_WORLD,    "OnRosterChanged")
    self:RegisterMessage(MSG.PROFILE_CHANGED,   "OnRosterChanged")
    self:RegisterMessage(MSG.TEST_MODE_CHANGED, "OnRosterChanged")
end

function Roster:OnRosterChanged()
    Roster.Refresh()
end
