-- modules/Targets.lua
--
-- "Which enemies did this player hit?" — the one question the meter's own data
-- shape does not answer directly, reconstructed from a second column.
--
-- ---------------------------------------------------------------------------
-- WHY THIS IS A JOIN AND NOT A READ
-- ---------------------------------------------------------------------------
--
-- A DamageDone source knows the spells it cast and nothing about who they hit.
-- The information exists, but it is filed under the OTHER party: an
-- EnemyDamageTaken source is one enemy, its `combatSpells` are the spells that
-- hit that enemy, and each of those carries `combatSpellDetails.unitName` — the
-- name of the player who cast it. So "Rogue's targets" is obtained by walking
-- every enemy, walking every spell on every enemy, and keeping the ones whose
-- unitName is the player under the cursor.
--
-- That is O(enemies x spells) on a hover, and it is the only route there is.
--
-- ---------------------------------------------------------------------------
-- WHY THE WHOLE SECTION VANISHES MID-PULL, RATHER THAN DEGRADING
-- ---------------------------------------------------------------------------
--
-- Everywhere else in this addon a restricted value is passed through as an
-- opaque handle and the display loses decoration rather than information. That
-- escape does not exist here, because the number this file produces DOES NOT
-- EXIST in the API: one enemy's damage from one player is a SUM over that
-- enemy's matching spells, and a sum of secrets raises.
--
-- So the answer is binary and it is decided BEFORE any arithmetic runs. Every
-- amount is checked with NS.Secrets.CanAccess as it is collected, and the first
-- inaccessible one abandons the entire build — `nil`, meaning "not available",
-- which modules/Tooltip.lua renders as no section at all.
--
-- The alternative, which a sibling addon ships, is to pcall each read and treat
-- a refusal as zero. That produces a Targets list that is silently wrong for the
-- whole of a pull, and wrong in the direction of "this enemy took less than it
-- did". An absent section is a visible absence; an under-reported one is a lie
-- the player cannot see.
--
-- ---------------------------------------------------------------------------
-- ONE WALK BUILDS EVERY PLAYER, AND IT IS CACHED
-- ---------------------------------------------------------------------------
--
-- The walk above visits every spell of every enemy. Answering for ONE player
-- then throws away every caster but the hovered one — 100% of the work for about
-- a fifth of the result in a five-player group, and a twentieth in a raid. So it
-- builds the WHOLE map, every player at once, and `ForPlayer` is a lookup into
-- it. The marginal cost of keeping the other players is a table write per spell;
-- the saving is a complete re-walk per hovered row.
--
-- Measured offline against this repo: a hover is `1 + E` provider calls — 24 at
-- 23 enemies, 65 at ENEMY_LIMIT — against **9 calls for a full 20-player,
-- 7-column refresh**. Sweeping a cursor down a five-row Damage column cost 120
-- meter calls before this and costs 24 after.
--
-- WHY A CACHE IS LEGAL HERE, when this addon does not hold meter values across
-- time. Two reasons, and both are specific to this file rather than general
-- permission:
--
--   * this section REFUSES to compute mid-pull at all (see above), so the
--     session it caches is one nothing is writing to — there is no time for the
--     answer to drift across;
--   * what is stored is not a meter value. It is OUR OWN SUM of numbers already
--     proven readable, a plain Lua number in a plain table. No opaque handle is
--     retained, so nothing here can go stale in the way a held `totalAmount`
--     would.
--
-- The cost accepted in exchange is a staleness failure mode that did not exist
-- before: get the invalidation wrong and a player sees the PREVIOUS pull's
-- targets, which looks entirely correct. That is why the key is the session's
-- own identity and why the bus subscription below is not optional.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS FILE MAY TOUCH
-- ---------------------------------------------------------------------------
--
-- It never calls C_DamageMeter (rule R1 — modules/Provider.lua owns that) and it
-- never inspects a value itself (rule R2 — core/Secrets.lua owns that). Both
-- reads it needs already exist on the provider: GetColumn enumerates the enemy
-- sources, and GetSourceDetail hands back one enemy's spell list.

local addonName, NS = ...

local Targets = {}
NS.Targets = Targets

local Const = NS.Constants
local State = NS.State

-- Load-time upvalue, never an NS lookup in the loop (performance-§2).
local Perf = NS.Perf or {}

--- The stat whose sources are enemies. Named once, because reading it as
--- anything else silently produces a list of PLAYERS and no error.
local ENEMY_STAT = "EnemyDamageTaken"

--- Hard ceiling on how many enemy sources one build will walk.
---
--- A trash pull in a Mythic+ can put a long tail of one-hit adds in the enemy
--- column, and each one costs a provider call. Sixty-four is far past any list a
--- player reads off a tooltip capped at ten, so the bound never changes an
--- answer the player would have seen — it only stops a pathological session from
--- turning a hover into a stall.
local ENEMY_LIMIT = 64

--- The built map, and the session it was built from.
---
--- In `State.Cache` rather than a file-local table so it is wiped by the same
--- machinery every other cache here is: core/MythicMeters.lua wipes the lot on
--- the events that invalidate everything, and the bus subscription at the foot
--- of this file wipes this one on the two that invalidate only it.
---
--- Shape: `cache.key` is the session identity the map was built from, and
--- `cache.map` is `{ [bareName] = { { name, total }, ... } }`, each list already
--- ordered biggest-first. A nil `map` with a live `key` is a build that was
--- REFUSED, and it is deliberately not cached — see `buildMap`.
local cache = State.Cache("Targets")

--- The identity of the session a map belongs to.
---
--- Both halves matter. `sessionType` separates Current from Overall, and
--- `sessionID` separates one stored segment from another — a player flipping
--- between two past fights in the header dropdown must not be shown the first
--- one's targets under the second one's name.
local function cacheKey(sessionType, sessionID)
    return tostring(sessionType) .. "|" .. tostring(sessionID)
end

--- Drop the built map. Wired to the bus at the foot of this file.
function Targets.Invalidate()
    cache.key, cache.map = nil, nil
end

--- modules/Provider.lua, or nil. Resolved at call time for the same reason
--- modules/Tooltip.lua does it: modules/ load in TOC order and this file cannot
--- assume the provider is already an upvalue-able global.
local function provider()
    if NS.Provider then return NS.Provider end
    if NS.GetModule then return NS:GetModule("Provider", true) end
    return nil
end

--- Which session (Current / Overall / Expired) a window reads.
local function sessionTypeOf(window)
    local data = type(window) == "table" and window.data or nil
    if data and data.sessionType ~= nil then return data.sessionType end
    return Const.SESSION_TYPE.Current
end

--- Which stored segment a window is pointed at, or nil for "the live one".
local function sessionIDOf(window)
    local data = type(window) == "table" and window.data or nil
    return data and data.sessionID or nil
end

--- A player name with its realm removed, for comparison only.
---
--- THE BUG THIS EXISTS FOR. The two sides of the match arrive in different
--- shapes: a combat source's `name` is bare, and a spell's
--- `combatSpellDetails.unitName` is realm-qualified for anyone from another
--- realm. So same-realm players matched and cross-realm players silently did
--- not — which looked like "targets work for every other row" and was really
--- "targets work for everyone on your own realm".
---
--- Splitting at the first hyphen is exact here rather than heuristic, because
--- both sides are PLAYER names and a player name cannot contain a hyphen. That
--- is not true elsewhere in this addon — modules/Row.lua gates the same strip on
--- the GUID because an NPC like "Crenna Earth-Daughter" keeps its hyphen — but
--- nothing but a player casts a spell into the enemy column.
---
--- Blizzard's own Ambiguate is preferred where it exists, so the rule stays
--- theirs rather than ours.
---
--- @param name string
--- @return string
local function bareName(name)
    local ambiguate = _G.Ambiguate
    if ambiguate then
        local ok, short = pcall(ambiguate, name, "short")
        if ok and type(short) == "string" and short ~= "" then return short end
    end
    return name:match("^([^-]+)") or name
end

--- The caster name on one spell row, or nil when there is nothing usable.
---
--- Three separate refusals, and they are not the same refusal written three
--- times. `combatSpellDetails` may be a table this context cannot index at all;
--- `unitName` may be present but inaccessible (it is ConditionalSecret, like
--- every other name the meter hands out); and an accessible name may still be
--- SECRET, which bars it from being a table key even though it can be read.
---
--- @param spell table
--- @return string|nil
local function casterName(spell)
    local Secrets = NS.Secrets
    if not Secrets then return nil end

    local details = spell.combatSpellDetails
    if not Secrets.CanAccessTable(details) then return nil end

    local name = details.unitName
    if name == nil then return nil end
    if not Secrets.CanAccess(name) then return nil end
    -- Keyed on below, so the key rule applies and not merely the access rule.
    if not Secrets.IsSafeKey(name) then return nil end
    if type(name) ~= "string" or name == "" then return nil end
    return bareName(name)
end

--- Fold one enemy's spells into the per-player totals, or answer false.
---
--- FALSE MEANS ABANDON THE WHOLE BUILD, not "skip this enemy". An amount this
--- context may not read is the restriction being active, and the restriction is
--- not per-enemy — so a build that carried on would return a total summed from
--- whichever rows happened to be readable, which is the under-reporting this
--- file exists to refuse.
---
--- EVERY caster is kept, not just one. The walk visits each spell either way;
--- filtering to a single player here is what made a five-row column sweep cost
--- five identical walks. `byPlayer[name][key]` is one table write more per spell
--- and it is what the cache is built out of.
---
--- @param source table    one enemy's GetSourceDetail result
--- @param key any         this enemy's key, unique across the walk
--- @param byPlayer table  bareName -> { [enemyKey] = total }
--- @return boolean  whether the walk may continue
local function accumulateEnemy(source, key, byPlayer)
    local Secrets = NS.Secrets
    if not (Secrets and Secrets.SafeIterate) then return false end

    local ok = true
    Secrets.SafeIterate(source.combatSpells, function(_, spell)
        if type(spell) ~= "table" then return end
        if not Secrets.CanAccessTable(spell) then return end

        local caster = casterName(spell)
        if caster == nil then return end

        local amount = spell.totalAmount
        if amount == nil then return end
        -- The one check that matters. Everything after this line is arithmetic.
        if not Secrets.CanAccess(amount) or type(amount) ~= "number" then
            ok = false
            return false
        end

        local totals = byPlayer[caster]
        if totals == nil then
            totals = {}
            byPlayer[caster] = totals
        end
        totals[key] = (totals[key] or 0) + amount
    end)

    return ok
end

--- Every player's target list for one session, built in a single walk.
---
--- Answers nil for all of "no provider", "no enemy column" and "the values may
--- not be read" — and a nil is NOT cached. Caching a refusal would pin the
--- section shut for the rest of the session: the next hover would find a live
--- cache key, read a nil map, and never retry once the restriction lifted.
---
--- @param sessionType number
--- @param sessionID number|nil
--- @return table|nil  { [bareName] = { { name, total }, ... } }, ordered
local function buildMap(sessionType, sessionID)
    local Secrets = NS.Secrets
    local P = provider()
    if not (P and P.GetColumn and P.GetSourceDetail) then return nil end

    local column = P:GetColumn(sessionType, ENEMY_STAT, sessionID)
    if type(column) ~= "table" or type(column.sources) ~= "table" then return nil end

    -- Keyed by POSITION in the enemy column, never by the enemy's GUID: a source
    -- GUID is secret and inaccessible for the whole of a pull (docs/data-flow.md
    -- §2), so keying on one raises. The index is ours, it is plain, and it is
    -- unique across the walk — which is everything a key here has to be.
    local byPlayer, names = {}, {}
    local walked = 0

    for index = 1, #column.sources do
        if walked >= ENEMY_LIMIT then break end
        local enemy = column.sources[index]
        if type(enemy) == "table" then
            -- NEITHER IDENTIFIER MAY BE ASSUMED PLAIN, and this is the line
            -- that makes the section work mid-pull at all. A meter sourceGUID is
            -- secret and inaccessible for the whole of a pull (docs/data-flow.md
            -- §2), and handing one back to the API resolves nothing.
            --
            -- The GUID was dropped here for that reason and the creature ID was
            -- forwarded beside it, on the belief that a `sourceCreatureID` is a
            -- plain number and never secret. IT IS NOT. In a live pull the
            -- client refuses the call outright — `bad argument #4 … Secret
            -- values are only allowed during untainted execution` — and because
            -- this runs on the render path, that raise took EVERY cell tooltip
            -- down with it, not just the Targets section. It looked plain only
            -- because it is plain out of combat, which is where it was read.
            --
            -- So both go through the same gate. Passing a secret and hoping is
            -- not an option for either argument.
            local guid = enemy.guid
            if not Secrets.IsSafeKey(guid) then guid = nil end
            local creatureID = enemy.creatureID
            if not Secrets.IsSafeKey(creatureID) then creatureID = nil end

            -- With neither identifier there is no way to ask about THIS enemy,
            -- and asking with both nil does not fail — it answers for a
            -- different source, whose numbers would be summed in as if they were
            -- this one's. Abandon, for the same reason a restricted read below
            -- abandons: a wrong total is worse than an absent section.
            if guid == nil and creatureID == nil then return nil end

            local source = P:GetSourceDetail(sessionType, ENEMY_STAT,
                guid, creatureID, sessionID)
            if type(source) == "table" then
                walked = walked + 1
                names[index] = enemy.name
                if not accumulateEnemy(source, index, byPlayer) then
                    -- Restricted. Abandon everything rather than return a
                    -- partial sum: see this file's header.
                    return nil
                end
            end
        end
    end

    -- Each player's enemy map becomes an ordered array once, here, rather than
    -- on every hover. Sorting is legal without asking: every amount was checked
    -- accessible on the way in, and these are our own sums.
    local map = {}
    for player, totals in pairs(byPlayer) do
        local list = {}
        for index, total in pairs(totals) do
            if total > 0 then
                list[#list + 1] = { name = names[index], total = total }
            end
        end
        if #list > 0 then
            table.sort(list, function(a, b) return a.total > b.total end)
            map[player] = list
        end
    end

    return map
end

--- Every enemy `player` damaged, biggest first, or nil.
---
--- Nil is returned for all of "no provider", "no enemy column", "this player hit
--- nothing", and "the values may not be read" — deliberately one answer, because
--- the caller does the same thing with all four: draws no section. The
--- difference between them is not something a tooltip can usefully say.
---
--- The map is built on the first hover of a session and reused by every hover
--- after it. Only the TRIM is per-call, so two windows with different
--- `maxTargets` share one build.
---
--- @param window table|nil  the window config, for its session
--- @param player any        the hovered row's name
--- @param limit number|nil  how many entries to keep
--- @return table|nil  array of { name = string, total = number }, descending
function Targets.ForPlayer(window, player, limit)
    local t0 = Perf.on and debugprofilestop()

    local Secrets = NS.Secrets
    -- The hovered name is ConditionalSecret too, and it is what every spell row
    -- is matched against — so an unreadable one means there is no comparison to
    -- make, which is the same nil as everything else.
    if not (Secrets and Secrets.CanAccess and Secrets.CanAccess(player)) then return nil end
    if type(player) ~= "string" or player == "" then return nil end
    -- Both sides go through the same normalizer, so it does not matter which of
    -- them carried a realm.
    player = bareName(player)

    local sessionType, sessionID = sessionTypeOf(window), sessionIDOf(window)
    local key = cacheKey(sessionType, sessionID)

    local map = (cache.key == key) and cache.map or nil
    if map == nil then
        map = buildMap(sessionType, sessionID)
        -- A REFUSED build stores nothing and returns early.
        --
        -- Note what is actually load-bearing here, because it is not this
        -- branch: a nil map is re-derived on the very next call regardless,
        -- since the lookup above answers nil for "no key" and "key present,
        -- map nil" alike. So the section cannot be pinned shut by a refusal
        -- even if the nil WERE stored. This early return is the cheaper spelling
        -- of the same thing, not the guarantee — the guarantee is the recheck.
        if map == nil then
            if t0 then Perf.Note("targets", debugprofilestop() - t0) end
            return nil
        end
        cache.key, cache.map = key, map
    end

    local built = map[player]
    if built == nil or #built == 0 then
        if t0 then Perf.Note("targets", debugprofilestop() - t0) end
        return nil
    end

    -- A COPY, always. The cached list outlives this call and is handed to every
    -- later hover of the same player, so trimming it in place would make the
    -- first hover at a cap of three permanently delete the fourth target for
    -- every window and every cap after it.
    local cap = (type(limit) == "number" and limit >= 1) and limit or #built
    if cap > #built then cap = #built end

    local list = {}
    for i = 1, cap do list[i] = built[i] end

    if t0 then Perf.Note("targets", debugprofilestop() - t0) end
    return list
end

--- The group total across a target list, for the share column.
---
--- Its own function so the summation stays beside the walk that proved the
--- operands addable. A caller holding a list from ForPlayer may add it up; a
--- caller holding meter values may not, and the two are not distinguishable at
--- the call site without this.
---
--- @param list table  a ForPlayer result
--- @return number
function Targets.Total(list)
    local total = 0
    for i = 1, #list do total = total + list[i].total end
    return total
end

-- ---------------------------------------------------------------------------
-- Invalidation
-- ---------------------------------------------------------------------------
--
-- A PRIVATE bus target, not the shared addon object. CallbackHandler keys
-- callbacks by (message, target), so two receivers of one message registered on
-- the same object silently clobber each other and only the last one ever fires
-- (architecture-§4, anti-pattern #32). This module has no lifecycle and is not
-- an AceAddon module, so it owns a target rather than being one — the same shape
-- modules/Format.lua uses for the same reason.
--
-- FOUR messages, and the list is deliberately wider than the one
-- modules/Aggregator.lua uses. The cache key is the session's IDENTITY —
-- `(sessionType, sessionID)` — and for the live Current or Overall session that
-- identity never changes while its CONTENTS do. So identity alone cannot detect
-- staleness, and the events have to.
--
--   * METER_RESET     — the session it was summed from is gone.
--   * METER_SESSION   — a session boundary moved; a stored segment is not the
--                       one this map describes.
--   * METER_UPDATED   — the current session ticked, so anything summed from it
--                       is now short. This fires throughout a pull and is the
--                       one that closes the hole: without it, a map built after
--                       one fight would still be showing after the next.
--   * PROFILE_CHANGED — a profile swap can move the window onto a different
--                       session entirely.
--
-- Subscribing to METER_UPDATED costs two nil assignments per tick and only while
-- fighting, when no map can exist anyway — the build refuses while restricted.
-- Over-invalidating costs a rebuild; under-invalidating shows a player the
-- previous pull's numbers under this pull's heading, which looks entirely
-- correct. That trade is not close.
local bus = NS.NewBusTarget and NS.NewBusTarget()
if bus then
    local MSG = Const.MSG
    bus:RegisterMessage(MSG.METER_RESET,     Targets.Invalidate)
    bus:RegisterMessage(MSG.METER_SESSION,   Targets.Invalidate)
    bus:RegisterMessage(MSG.METER_UPDATED,   Targets.Invalidate)
    bus:RegisterMessage(MSG.PROFILE_CHANGED, Targets.Invalidate)
end
