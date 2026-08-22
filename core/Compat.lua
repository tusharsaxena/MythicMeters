-- core/Compat.lua
--
-- Every deprecated or cross-patch API call the addon makes lives here, so no
-- module has to do its own version detection and no module names a deprecated
-- global (architecture-§1). Callers reach for NS.Compat.X and get a shape that
-- matches a modern Midnight 12.x client; where the underlying API is missing the
-- shim degrades to a safe default rather than erroring at the call site.
--
-- This addon has an unusually large "might not exist" surface. C_DamageMeter is
-- new in 12.0, so a client one patch behind has none of it, and a PTR build can
-- have the namespace without one of its functions. Rather than sprinkle
-- `C_DamageMeter and C_DamageMeter.GetCombatSessionFromType and ...` across
-- modules/Provider.lua, the guards live here once and the provider reads like
-- the data-flow it is.
--
-- TOC POSITION: FIRST in the core block. core/Namespace.lua reads the TOC
-- manifest through Compat.GetAddOnMetadata on the very next line of the TOC.
--
-- WHAT THIS FILE MUST NOT DO. It never inspects a meter value. Reading a field
-- off a session table is not inspection — assigning it to a local and asking a
-- question about it is, and that is core/Secrets.lua's exclusive job (design §4,
-- rule R1). Everything below passes meter numbers through untouched.

local addonName, NS = ...

local Compat = {}
NS.Compat = Compat

-- ---------------------------------------------------------------------------
-- Addon manifest
-- ---------------------------------------------------------------------------

--- A field from the addon's TOC manifest.
---
--- 12.0 exposes the reader under C_AddOns; the bare _G.GetAddOnMetadata is the
--- deprecated pre-11.x seam and is only reached when the namespace is absent.
--- Returns nil rather than a placeholder so callers can tell "no manifest" from
--- "manifest says empty" and apply their own fallback (core/Namespace.lua's
--- FALLBACK_VERSION).
---
--- @param name string  addon folder name
--- @param field string "Version", "Title", ...
--- @return string|nil
function Compat.GetAddOnMetadata(name, field)
    if _G.C_AddOns and _G.C_AddOns.GetAddOnMetadata then
        return _G.C_AddOns.GetAddOnMetadata(name, field)
    end
    if _G.GetAddOnMetadata then
        return _G.GetAddOnMetadata(name, field)
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Spell APIs
-- ---------------------------------------------------------------------------
--
-- The meter hands us spellIDs on every DamageMeterCombatSpell row; the tooltip
-- and the drill-down turn them into a name and an icon. Both readers moved
-- behind C_Spell in 10.x, so the bare globals are the fallback only.

--- Basic spell info, flattened to the pre-C_Spell multi-return so call sites
--- read the same on either client.
---
--- @param spellID number
--- @return name, iconID, castTime, minRange, maxRange, spellID
function Compat.GetSpellInfo(spellID)
    if _G.C_Spell and _G.C_Spell.GetSpellInfo then
        local info = _G.C_Spell.GetSpellInfo(spellID)
        if info then
            return info.name, info.iconID, info.castTime,
                   info.minRange, info.maxRange, info.spellID
        end
        return nil
    end
    if _G.GetSpellInfo then
        return _G.GetSpellInfo(spellID)
    end
    return nil
end

--- File ID of a spell's icon texture, for the tooltip's spell rows.
--- @param spellID number
--- @return number|nil  fileID suitable for Texture:SetTexture()
function Compat.GetSpellTexture(spellID)
    if _G.C_Spell and _G.C_Spell.GetSpellTexture then
        return _G.C_Spell.GetSpellTexture(spellID)
    end
    if _G.GetSpellTexture then
        return _G.GetSpellTexture(spellID)
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Specialization APIs
-- ---------------------------------------------------------------------------
--
-- 12.0 (Midnight) moved the specialization query behind C_SpecializationInfo;
-- the bare GetSpecialization / GetSpecializationInfo globals are the deprecated
-- pre-11.x seam. Signatures are preserved: GetSpecialization returns the active
-- spec INDEX, GetSpecializationInfo(index) returns
-- (id, localizedName, description, iconID, role, ...).
--
-- The meter ships specIconID on every source row, so the row icons do NOT go
-- through here. What does is modules/Roster.lua's role lookup for the `roster`
-- sort mode, which needs the LOCAL player's spec when the group APIs have not
-- caught up yet (the first frame after a zone-in).

--- Active specialization index (or nil when unavailable).
--- @return number|nil
function Compat.GetSpecialization()
    if _G.C_SpecializationInfo and _G.C_SpecializationInfo.GetSpecialization then
        return _G.C_SpecializationInfo.GetSpecialization()
    end
    return _G.GetSpecialization and _G.GetSpecialization()
end

--- Spec info for a spec index. Multi-return passthrough of the underlying API.
--- @param index number
function Compat.GetSpecializationInfo(index)
    if _G.C_SpecializationInfo and _G.C_SpecializationInfo.GetSpecializationInfo then
        return _G.C_SpecializationInfo.GetSpecializationInfo(index)
    end
    if _G.GetSpecializationInfo then return _G.GetSpecializationInfo(index) end
    return nil
end

-- ---------------------------------------------------------------------------
-- C_DamageMeter — the addon's entire data source
-- ---------------------------------------------------------------------------
--
-- Blizzard's built-in meter, new in 12.0. modules/Provider.lua is the only
-- caller of these shims, and these shims are the only callers of the namespace.
--
-- EVERY one of them may return values that are SECRET while the Combat addon
-- restriction is active. Nothing here compares, adds, keys on, or measures the
-- length of anything that came back — the tables and their numbers are handed
-- straight to the caller. A single `if session.totalAmount > 0` in this file
-- would be a Lua error mid-pull, in the one place a player cannot see it.
--
-- The shims answer nil (or an empty table, where the caller wants to iterate
-- unconditionally) on a client without the namespace, which is exactly what the
-- "meter unavailable" render path already handles — so a 11.x client shows the
-- unavailable notice rather than erroring on load.

local function damageMeter()
    return _G.C_DamageMeter
end

--- Whether the built-in meter is usable right now.
---
--- The second return is Blizzard's own failure reason, which the window renders
--- verbatim in place of rows (design §6, "Degradation"). We do not translate it
--- and we do not second-guess it: it is the only thing that can tell a player
--- their meter is off because of a CVar rather than because our addon is broken.
---
--- @return boolean isAvailable, any failureReason
function Compat.IsDamageMeterAvailable()
    local api = damageMeter()
    if not (api and api.IsDamageMeterAvailable) then
        return false, nil
    end
    return api.IsDamageMeterAvailable()
end

--- One combat session for (sessionType, statType).
---
--- @param sessionType number Enum.DamageMeterSessionType value
--- @param statType number Enum.DamageMeterType value
--- @return table|nil  { combatSources, maxAmount, totalAmount, durationSeconds }
---   Fields are SECRET in combat. Pass them on; never look at them.
function Compat.GetCombatSessionFromType(sessionType, statType)
    local api = damageMeter()
    if not (api and api.GetCombatSessionFromType) then return nil end
    return api.GetCombatSessionFromType(sessionType, statType)
end

--- One combat session addressed by ID rather than by "current / overall".
--- Used by the session picker, which lists historical sessions.
--- @param sessionID number
--- @param statType number
--- @return table|nil
function Compat.GetCombatSessionFromID(sessionID, statType)
    local api = damageMeter()
    if not (api and api.GetCombatSessionFromID) then return nil end
    return api.GetCombatSessionFromID(sessionID, statType)
end

--- The per-source spell breakdown behind one cell — the tooltip and the
--- drill-down's data.
---
--- sourceGUID and sourceCreatureID are OPTIONAL in the underlying signature, so
--- they are forwarded rather than defaulted: passing an explicit nil and passing
--- nothing are the same thing to Lua here, and inventing a default would change
--- which source the API answers for.
---
--- @param sessionType number
--- @param statType number
--- @param sourceGUID string|nil
--- @param sourceCreatureID number|nil
--- @return table|nil  { combatSpells, maxAmount, totalAmount }
function Compat.GetCombatSessionSourceFromType(sessionType, statType, sourceGUID, sourceCreatureID)
    local api = damageMeter()
    if not (api and api.GetCombatSessionSourceFromType) then return nil end
    return api.GetCombatSessionSourceFromType(sessionType, statType, sourceGUID, sourceCreatureID)
end

--- The same breakdown for a session addressed by ID.
--- @return table|nil
function Compat.GetCombatSessionSourceFromID(sessionID, statType, sourceGUID, sourceCreatureID)
    local api = damageMeter()
    if not (api and api.GetCombatSessionSourceFromID) then return nil end
    return api.GetCombatSessionSourceFromID(sessionID, statType, sourceGUID, sourceCreatureID)
end

--- Every session the client is still holding, newest first.
---
--- Returns an EMPTY TABLE rather than nil when the API is missing, because the
--- session picker iterates it unconditionally to build its dropdown; a nil there
--- would put an existence check in the UI layer for a case the UI cannot do
--- anything about.
---
--- @return table  array of { sessionID, name, durationSeconds }
function Compat.GetAvailableCombatSessions()
    local api = damageMeter()
    if not (api and api.GetAvailableCombatSessions) then return {} end
    return api.GetAvailableCombatSessions() or {}
end

--- Duration of a session type in seconds. May be nil (no session yet), and is
--- SECRET in combat — the header formats it through the numeric formatter like
--- any other meter number rather than doing minutes/seconds arithmetic on it.
--- @param sessionType number
--- @return number|nil
function Compat.GetSessionDurationSeconds(sessionType)
    local api = damageMeter()
    if not (api and api.GetSessionDurationSeconds) then return nil end
    return api.GetSessionDurationSeconds(sessionType)
end

--- Clear every session the client holds. Reached only through
--- `NS.Provider.Reset()`, which is the addon's sole permitted caller of the
--- C_DamageMeter shims — never from a refresh path, because it wipes data the
--- player may be reading.
--- @return boolean  whether the call was made
function Compat.ResetAllCombatSessions()
    local api = damageMeter()
    if not (api and api.ResetAllCombatSessions) then return false end
    api.ResetAllCombatSessions()
    return true
end

-- ---------------------------------------------------------------------------
-- C_DeathRecap — what actually killed somebody
-- ---------------------------------------------------------------------------
--
-- The reader behind the death drill-down, and the API the whole of issue #1 was
-- blocked on. Measured on a live 12.x client 2026-08-22: it resolves for ANY
-- player in the group and ANY death earlier in the run, which is precisely what
-- Blizzard's own recap frame refuses and what the issue could not assume.
--
-- Four members exist; three are shimmed here. `GetRecapLink` is left alone until
-- something wants a chat link (spec §10).
--
-- SAME "MIGHT NOT EXIST" DISCIPLINE AS THE METER ABOVE. The namespace is new, a
-- client one patch behind has none of it, and a PTR build can carry it without
-- one of its functions — so the namespace and the member are guarded separately.
-- Every call is additionally wrapped: the client refuses an id it does not
-- recognise by RAISING, and a raise reaching the render path would take a
-- tooltip down mid-hover.
--
-- WHAT THESE MAY NOT DO. An event carries `amount`, `overkill` and `currentHP`,
-- and a recap's max health is the denominator of an HP percentage. All of them
-- are meter values. Nothing here asks how big one is, whether an array is empty,
-- or anything else: the tables and their numbers are handed straight back, and
-- `HasRecapEvents` is the only member that answers a question at all.

local function deathRecap()
    return _G.C_DeathRecap
end

--- Whether the client still holds a breakdown for this death.
---
--- A PLAIN boolean, whatever the client hands back. Callers branch on this to
--- decide whether a death row has anything behind it, and that branch has to be
--- answerable at the height of a pull — so a `nil`, a `1` or a secret must all
--- become `true` or `false` here rather than at ten call sites.
---
--- @param recapID number
--- @return boolean
function Compat.HasRecapEvents(recapID)
    local api = deathRecap()
    if not (api and api.HasRecapEvents) then return false end
    local ok, has = pcall(api.HasRecapEvents, recapID)
    if not ok then return false end
    return has and true or false
end

--- The incoming events behind one death, NEWEST FIRST, or nil.
---
--- Ten in every live sample. The array and its event tables are passed through
--- untouched — not counted, not reversed, not filtered. Whoever renders them
--- does that, under core/Secrets.lua's iteration rules.
---
--- @param recapID number
--- @return table|nil
function Compat.GetRecapEvents(recapID)
    local api = deathRecap()
    if not (api and api.GetRecapEvents) then return nil end
    local ok, events = pcall(api.GetRecapEvents, recapID)
    if not ok then return nil end
    return events
end

--- The player's maximum health for that death — the denominator of an HP
--- percentage, and possibly secret.
--- @param recapID number
--- @return any|nil
function Compat.GetRecapMaxHealth(recapID)
    local api = deathRecap()
    if not (api and api.GetRecapMaxHealth) then return nil end
    local ok, maxHealth = pcall(api.GetRecapMaxHealth, recapID)
    if not ok then return nil end
    return maxHealth
end

-- ---------------------------------------------------------------------------
-- Death-recap discovery (issue #1)
-- ---------------------------------------------------------------------------
--
-- WHAT NOBODY KNOWS. `deathRecapID` arrives on every Deaths source row and this
-- addon does nothing with it but hand it to Blizzard's frame
-- (modules/DrillDown.lua), which answers "Death Recap unavailable" for the past
-- deaths issue #1's window is entirely made of. Three questions have to be
-- settled on a LIVE client before that window can be designed: does an id
-- resolve for a non-local player, does it resolve for a death from earlier in
-- the run, and is there a reader for the per-event breakdown at all.
--
-- The last one is why this lives in Compat rather than in the diagnostic. A
-- reader could sit on C_DeathInfo or on the meter namespace itself, and this
-- file is the only one permitted to name the latter. Half a search in a file
-- that may not host it is not a search.
--
-- WHERE TO LOOK, AND WHY THE LIST GREW A THIRD ENTRY.
--
-- Rounds one and two of this probe both reported "no recap reader on this
-- client" and both were WRONG. The reader is `C_DeathRecap.GetRecapEvents`, in a
-- namespace neither round searched — EllesmereUIDamageMeters calls it on the
-- same client that came back empty here.
--
-- How round two missed it is the lesson worth keeping. Round one's doubt was
-- "the walk may not enumerate", so round two added a direct-index search and ran
-- it over THE SAME TWO NAMESPACES. Widening the names while leaving the haystack
-- alone re-asked a question that was already answered and left the one that
-- mattered untouched. A search is only as wide as its narrowest axis, and the
-- narrow axis here was never the one under suspicion.
local RECAP_NAMESPACES = { "C_DeathRecap", "C_DeathInfo", "C_DamageMeter" }

-- WHY THERE IS A NAME LIST AT ALL, having said a name list answers the question
-- with our own opinion. Round one of this probe walked a live 12.x client with
-- nine deaths in the session and came back with ONE function —
-- `C_DeathInfo.GetDeathReleasePosition`, a corpse coordinate. `GetRecapEvent`
-- and `GetDeathRecapLink` are the documented readers, both match the walk's own
-- filter, and neither appeared. Meanwhile Blizzard's recap frame demonstrably
-- opens on that client, so something reads recaps.
--
-- One hit where three were expected is the shape of a PARTIAL ENUMERATION, not
-- of an empty client: some retail `C_*` namespaces answer through `__index` and
-- their members never appear in `pairs`. So the walk is no longer the only
-- search. These names are asked for BY DIRECT INDEX, which sees through a proxy
-- that a walk cannot.
--
-- The distinction that keeps this honest: the walk asks "what is here" and this
-- list asks "is THIS here". A candidate is a question, and only a name the
-- client actually answers to is ever reported as a reader.
local RECAP_CANDIDATES = {
    -- THE ONES THAT ARE KNOWN TO WORK, from reading a working addon rather than
    -- from guessing: `GetRecapEvents(recapID)` hands back the event array, and
    -- `GetRecapMaxHealth(recapID)` the denominator the right pane's HP
    -- percentage needs. Listed first because they are the answer.
    { ns = "C_DeathRecap", name = "GetRecapEvents" },
    { ns = "C_DeathRecap", name = "GetRecapMaxHealth" },
    -- The documented pair, and the historical spelling of each.
    { ns = "C_DeathInfo", name = "GetRecapEvent" },
    { ns = "C_DeathInfo", name = "GetDeathRecapLink" },
    { ns = "C_DeathInfo", name = "GetRecapEvents" },
    { ns = "C_DeathInfo", name = "HasRecapData" },
    -- `deathRecapID` arrives on a METER row, so the meter namespace is the other
    -- place a 12.0 reader would plausibly live. Spellings we have never seen —
    -- which is the point: a miss costs one printed line, and a hit is the whole
    -- feature.
    { ns = "C_DamageMeter", name = "GetDeathRecap" },
    { ns = "C_DamageMeter", name = "GetDeathRecapEvent" },
    { ns = "C_DamageMeter", name = "GetDeathRecapEvents" },
    { ns = "C_DamageMeter", name = "GetRecapEvent" },
    { ns = "C_DamageMeter", name = "GetCombatSessionDeathRecap" },
}

--- Whether a member name looks like it reads a death recap.
---
--- Deliberately loose. A false positive costs one printed line in a report a
--- human reads; a false negative loses the finding the whole probe exists for.
---
--- @param name string
--- @return boolean
local function isRecapShaped(name)
    local lower = name:lower()
    return lower:find("recap", 1, true) ~= nil or lower:find("death", 1, true) ~= nil
end

--- Every member of every candidate namespace, UNFILTERED.
---
--- The filter is what made round one ambiguous, so the dump does not have one. A
--- namespace with seven members and no recap function among them is a conclusive
--- answer; a namespace with two is a proxy and the walk is the thing at fault.
--- Nobody can tell those apart from a filtered list.
---
--- `present` is separate from an empty `names` on purpose: "this client has no
--- C_DeathInfo" and "it has one and it enumerates as empty" are different
--- findings, and collapsing them would hide a load-order problem behind a design
--- conclusion.
---
--- @return table  { { ns = "C_DeathInfo", present = true, names = { ... } }, ... }
function Compat.RecapMembers()
    local dump = {}
    for _, nsName in ipairs(RECAP_NAMESPACES) do
        local namespace = _G[nsName]
        local entry = { ns = nsName, present = type(namespace) == "table", names = {} }
        if entry.present then
            for key in pairs(namespace) do
                if type(key) == "string" then entry.names[#entry.names + 1] = key end
            end
            table.sort(entry.names)
        end
        dump[#dump + 1] = entry
    end
    return dump
end

--- Every recap reader the CLIENT will answer to, from BOTH searches.
---
--- `how` is a finding rather than bookkeeping. A reader labelled `walk` means
--- round one's empty result was the client speaking; one labelled `named` means
--- it was the search, and that single word decides whether issue #1 is a reader
--- over `deathRecapID` or a combat-log capture of its own.
---
--- Sorted, because this report is pasted into an issue and compared against
--- another player's paste: `pairs` order would make two identical clients
--- produce two different reports and no reader could tell which difference
--- mattered.
---
--- @return table  { { ns = "C_DeathInfo", name = "GetRecapEvent", how = "walk" }, ... }
function Compat.RecapAPIs()
    local found, seen = {}, {}

    local function keep(nsName, key, how)
        local id = nsName .. "." .. key
        if seen[id] then return end
        seen[id] = true
        found[#found + 1] = { ns = nsName, name = key, how = how }
    end

    -- The walk goes first so a member both searches can see is labelled `walk`.
    for _, nsName in ipairs(RECAP_NAMESPACES) do
        local namespace = _G[nsName]
        if type(namespace) == "table" then
            for key, value in pairs(namespace) do
                if type(key) == "string" and type(value) == "function"
                    and isRecapShaped(key) then
                    keep(nsName, key, "walk")
                end
            end
        end
    end

    -- Then the direct index, which sees through a proxy the walk cannot.
    for _, candidate in ipairs(RECAP_CANDIDATES) do
        local namespace = _G[candidate.ns]
        if type(namespace) == "table"
            and type(namespace[candidate.name]) == "function" then
            keep(candidate.ns, candidate.name, "named")
        end
    end

    table.sort(found, function(a, b)
        if a.name == b.name then return a.ns < b.ns end
        return a.name < b.name
    end)
    return found
end

--- Call one discovered reader and hand back the outcome, whatever it is.
---
--- `pcall` is the point, not a precaution. "This client refuses a past death" is
--- the single most valuable thing the probe can find, and a probe that dies on a
--- refusal prints nothing at all — which reads exactly like a session with no
--- deaths in it, and would send issue #1 off on the opposite answer.
---
--- The result is NEVER examined here, not even for truthiness: a recap event
--- carries an amount and an HP figure, and both are meter values.
---
--- @param nsName string  a namespace name from RecapAPIs()
--- @param fnName string  a member name from RecapAPIs()
--- @return boolean ok, any valueOrError
function Compat.CallRecap(nsName, fnName, ...)
    local namespace = _G[nsName]
    if type(namespace) ~= "table" then return false, "no namespace " .. tostring(nsName) end
    local fn = namespace[fnName]
    if type(fn) ~= "function" then return false, "no function " .. tostring(fnName) end
    return pcall(fn, ...)
end

-- ---------------------------------------------------------------------------
-- Numeric rule formatter
-- ---------------------------------------------------------------------------
--
-- THE ONLY LEGAL WAY TO RENDER "12.4M" FROM A SECRET. Abbreviating a number is
-- division and rounding, and both are arithmetic, which is exactly what tainted
-- code may not do to a secret value. C_StringUtil.CreateNumericRuleFormatter
-- returns an object whose :FormatNumber(n) performs that arithmetic NATIVELY and
-- accepts secrets (design §4, "Number formatting").
--
-- modules/Format.lua owns the formatter INSTANCES — one per number style, built
-- once and reused — and is the only caller of this shim. No call site anywhere
-- in this addon divides a meter value.

--- A fresh ABBREVIATED number formatter, or nil where the API is absent.
---
--- THERE ARE THREE FORMATTER TYPES AND ONLY ONE OF THEM ABBREVIATES. Patch
--- 12.0.5 added `AbbreviatedNumberFormatter`, `NumericRuleFormatter` and
--- `SecondsFormatter`, all three sharing `NumericFormatter:FormatNumber`. This
--- addon shipped v0.1.0 calling `CreateNumericRuleFormatter()` — the RULE-based
--- one — with no breakpoints configured, which is a perfectly working formatter
--- that renders `1410000` as "1410000". Every number in the addon was
--- unabbreviated and nothing failed loudly, because nothing had failed: we were
--- asking the wrong object.
---
--- The nil case is still real and still the caller's to handle rather than
--- papered over here with a Lua formatter: a Lua fallback that did the division
--- would be correct out of combat and a hard error in combat, which is the worst
--- of the two possible failures. modules/Format.lua degrades instead.
---
--- @return table|nil  object with :FormatNumber(n) -> string and SetBreakpoints
function Compat.CreateAbbreviatedNumberFormatter()
    local util = _G.C_StringUtil
    if not (util and util.CreateAbbreviatedNumberFormatter) then return nil end
    return util.CreateAbbreviatedNumberFormatter()
end

--- Blizzard's own abbreviation breakpoints — the K/M/B ladder the default UI
--- uses, already localized.
---
--- The safety net under modules/Format.lua's custom breakpoints: if this client
--- rejects the shape we build, the addon falls back to the client's own rather
--- than to no abbreviation at all.
---
--- @return table|nil  array of NumberAbbreviationBreakpoint
function Compat.GetDefaultAbbreviationBreakpoints()
    local util = _G.C_StringUtil
    if not (util and util.GetDefaultAbbreviationBreakpoints) then return nil end
    local ok, breakpoints = pcall(util.GetDefaultAbbreviationBreakpoints)
    if ok then return breakpoints end
    return nil
end

--- A fresh numeric RULE formatter, or nil where the API is absent.
---
--- Kept for the `full` number format, which wants a formatter that does not
--- abbreviate — which is exactly what this one is with no breakpoints on it.
--- See CreateAbbreviatedNumberFormatter above for why that distinction cost a
--- release.
---
--- @return table|nil  object with :FormatNumber(n) -> string
function Compat.CreateNumericRuleFormatter()
    local util = _G.C_StringUtil
    if not (util and util.CreateNumericRuleFormatter) then return nil end
    return util.CreateNumericRuleFormatter()
end

-- ---------------------------------------------------------------------------
-- Context menus
-- ---------------------------------------------------------------------------
--
-- The segment selector in a window's header is a dropdown, and dropdowns are the
-- part of the WoW UI that has been rewritten most often: UIDropDownMenu, then
-- EasyMenu, then MenuUtil in 11.0. Rather than let modules/Window.lua learn which
-- of those this client has, the question lives here with the rest of the "might
-- not exist" surface.
--
-- MenuUtil only. The older APIs are deliberately NOT wired as fallbacks: they are
-- absent on every client this addon supports, and a fallback nobody can run is a
-- fallback nobody has tested.

--- Open a context menu owned by `owner`, built by `generator`.
---
--- `generator` is called as `generator(owner, rootDescription)` and builds the
--- menu through the root's own CreateButton / CreateDivider / CreateTitle. That
--- is MenuUtil's contract and it is passed through unchanged rather than wrapped
--- in a descriptor shape of our own, which would be a second menu vocabulary to
--- keep in step with Blizzard's.
---
--- @param owner table     the region the menu anchors to
--- @param generator function
--- @return boolean  whether a menu was actually opened
function Compat.OpenContextMenu(owner, generator)
    local util = _G.MenuUtil
    if not (util and util.CreateContextMenu) then return false end
    if owner == nil or type(generator) ~= "function" then return false end
    -- pcall because this is a UI API being driven from a click handler: a menu
    -- that fails to open must not put an error in front of the player mid-pull.
    local ok = pcall(util.CreateContextMenu, owner, generator)
    return ok
end

-- ---------------------------------------------------------------------------
-- Icon art
-- ---------------------------------------------------------------------------
--
-- THIS EXISTS BECAUSE GUESSING FAILED TWICE, SILENTLY, IN A ROW.
--
-- The window header's sort arrow and its lock/gear buttons were first drawn from
-- texture paths (`Interface\Buttons\UI-SortArrow-Up`) that do not exist — and a
-- texture that fails to load draws NOTHING and raises nothing, so the arrow was
-- simply absent with no error to read. They were then redrawn as Unicode glyphs
-- (BLACK UP-POINTING TRIANGLE, GEAR, LOCK), which are not in the game's default
-- font and rendered as replacement boxes.
--
-- Both failures share a shape: the art was named at authoring time and its
-- existence was never checked. So it is checked HERE, at runtime, against the
-- client that is actually running — and there is a final fallback that cannot
-- fail, because it is an ASCII character every font has.

--- The first atlas in `names` this client actually has, or nil.
---
--- `C_Texture.GetAtlasInfo` is the only way to ask "does this exist" before
--- drawing it; SetAtlas on an unknown name is silent.
---
--- @param names table  candidate atlas names, best first
--- @return string|nil
function Compat.FirstAtlas(names)
    local api = _G.C_Texture
    if not (api and api.GetAtlasInfo) then return nil end
    for _, name in ipairs(names or {}) do
        local ok, info = pcall(api.GetAtlasInfo, name)
        if ok and info then return name end
    end
    return nil
end
