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
-- WHY THERE IS NO CACHE
-- ---------------------------------------------------------------------------
--
-- A cache here would hold meter values across time, which is the one thing this
-- addon does not do (see modules/Tooltip.lua's note on the per-stat reads). The
-- cost is paid instead by the caller: the section is OFF by default, it is drawn
-- on the Damage column only, and it runs on a hover rather than on the refresh
-- tick. A hover is a human action a few times a minute; the refresh is four
-- times a second.
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
    return name
end

--- Add one enemy's contribution from `player` into `totals`, or answer false.
---
--- FALSE MEANS ABANDON THE WHOLE BUILD, not "skip this enemy". An amount this
--- context may not read is the restriction being active, and the restriction is
--- not per-enemy — so a build that carried on would return a total summed from
--- whichever rows happened to be readable, which is the under-reporting this
--- file exists to refuse.
---
--- @param source table   one enemy's GetSourceDetail result
--- @param player string  the name being asked about
--- @param key any        this enemy's key in `totals`
--- @param totals table
--- @return boolean  whether the walk may continue
local function accumulateEnemy(source, player, key, totals)
    local Secrets = NS.Secrets
    if not (Secrets and Secrets.SafeIterate) then return false end

    local ok = true
    Secrets.SafeIterate(source.combatSpells, function(_, spell)
        if type(spell) ~= "table" then return end
        if not Secrets.CanAccessTable(spell) then return end
        if casterName(spell) ~= player then return end

        local amount = spell.totalAmount
        if amount == nil then return end
        -- The one check that matters. Everything after this line is arithmetic.
        if not Secrets.CanAccess(amount) or type(amount) ~= "number" then
            ok = false
            return false
        end

        totals[key] = (totals[key] or 0) + amount
    end)

    return ok
end

--- Every enemy `player` damaged, biggest first, or nil.
---
--- Nil is returned for all of "no provider", "no enemy column", "this player hit
--- nothing", and "the values may not be read" — deliberately one answer, because
--- the caller does the same thing with all four: draws no section. The
--- difference between them is not something a tooltip can usefully say.
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

    local P = provider()
    if not (P and P.GetColumn and P.GetSourceDetail) then return nil end

    local sessionType, sessionID = sessionTypeOf(window), sessionIDOf(window)
    local column = P:GetColumn(sessionType, ENEMY_STAT, sessionID)
    if type(column) ~= "table" or type(column.sources) ~= "table" then return nil end

    -- Keyed by POSITION in the enemy column, never by the enemy's GUID: a source
    -- GUID is secret and inaccessible for the whole of a pull (docs/data-flow.md
    -- §2), so keying on one raises. The index is ours, it is plain, and it is
    -- unique across the walk — which is everything a key here has to be.
    local totals, names = {}, {}
    local walked = 0

    for index = 1, #column.sources do
        if walked >= ENEMY_LIMIT then break end
        local enemy = column.sources[index]
        if type(enemy) == "table" then
            -- THE GUID IS DROPPED WHENEVER IT IS SECRET, and this is the line
            -- that makes the section work mid-pull at all. A meter sourceGUID is
            -- secret and inaccessible for the whole of a pull (docs/data-flow.md
            -- §2), and handing one back to the API resolves nothing — so the
            -- lookup falls to `sourceCreatureID`, which is a plain number, is
            -- never secret, and identifies an enemy exactly as well.
            --
            -- Passing both and hoping is not the same thing: the GUID is the
            -- FIRST argument, so a secret one is what the API tries first.
            local guid = enemy.guid
            if not Secrets.IsSafeKey(guid) then guid = nil end

            local source = P:GetSourceDetail(sessionType, ENEMY_STAT,
                guid, enemy.creatureID, sessionID)
            if type(source) == "table" then
                walked = walked + 1
                names[index] = enemy.name
                if not accumulateEnemy(source, player, index, totals) then
                    -- Restricted. Abandon everything rather than return a
                    -- partial sum: see this file's header.
                    return nil
                end
            end
        end
    end

    local list = {}
    for index, total in pairs(totals) do
        if total > 0 then
            list[#list + 1] = { name = names[index], total = total }
        end
    end
    if #list == 0 then return nil end

    -- Legal without asking: every amount in `totals` was checked accessible on
    -- the way in, and these are our own sums rather than meter values.
    table.sort(list, function(a, b) return a.total > b.total end)

    local cap = (type(limit) == "number" and limit >= 1) and limit or #list
    for i = #list, cap + 1, -1 do list[i] = nil end

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
