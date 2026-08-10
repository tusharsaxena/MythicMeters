-- core/Secrets.lua
--
-- THE ONLY FILE IN THIS ADDON THAT INSPECTS A VALUE.
--
-- Everywhere else, a number that came out of C_DamageMeter is an OPAQUE HANDLE:
-- you may store it, pass it to a Lua function, put it in a table VALUE, hand it
-- to a widget setter or to the numeric formatter, and do nothing else with it.
-- If a module needs to know something about a value — is it secret, may I sort
-- these, how many entries does this array have — it asks this file. That is
-- design rule R1, and it is enforced by there being exactly one place with the
-- detection APIs in it.
--
-- ---------------------------------------------------------------------------
-- THE CONTRACT (WoW 12.0 "Secret Values"), stated here because this is where a
-- future reader will come looking for it.
-- ---------------------------------------------------------------------------
--
-- While the Combat addon restriction is active, meter numbers are returned to
-- tainted code — which is all of ours — as SECRET values.
--
-- Tainted code MAY:
--   * store them in variables and in table VALUES
--   * pass them to Lua functions and return them
--   * concatenate them, and call string.format / string.join / string.concat
--     with them
--   * pass them to StatusBar:SetValue / SetMinMaxValues and FontString:SetText
--   * call type() on them
--   * call NumericRuleFormatter:FormatNumber on them
--
-- Tainted code MAY NOT (each raises an immediate Lua error):
--   * do arithmetic on them
--   * compare them, or do a boolean test on them
--     (a NON-BOOLEAN secret can still be truth-tested for NIL-ness, which is the
--     single exception this file leans on — see SafeIterate)
--   * use them as table KEYS
--   * apply the # length operator to them
--   * index them
--
-- Detection: issecretvalue(v), canaccessvalue(v), issecrettable(t),
-- canaccesstable(t).
-- Restriction state: C_RestrictedActions.IsAddOnRestrictionActive(type),
-- C_RestrictedActions.GetAddOnRestrictionState(type), and the
-- ADDON_RESTRICTION_STATE_CHANGED(type, state) event — which fires with
-- state = Activating BEFORE enforcement begins, and access is still permitted
-- during that dispatch. That edge is the last moment a correct value-sort can be
-- taken (design §5), which is why the state is exposed here and not just the
-- boolean.
--
-- WIDGET CONSEQUENCE, stated once so no module has to rediscover it: calling
-- StatusBar:SetValue(secret) marks that frame HasSecretValues, which makes its
-- anchoring and position data secret too, and that propagates to anything
-- anchored to it. So NEVER read GetPoint / GetWidth / GetLeft / GetHeight back
-- off a cell. Layout is computed from config (design rule R3).
--
-- ---------------------------------------------------------------------------
-- DEGRADATION
-- ---------------------------------------------------------------------------
--
-- Every function here is correct when the whole secrets system is ABSENT — an
-- older client, or the headless test harness. The rule in that world is
-- "everything is a plain value": nothing is secret, everything is comparable,
-- and iteration is ordinary ipairs semantics. Each function assumes NOTHING
-- exists and builds up from there, rather than assuming the modern client and
-- guarding the exceptions.
--
-- NO PERF INSTRUMENTATION HERE, deliberately. core/PerfSetup.lua is the LAST
-- file in the core block, so a `local Perf = NS.Perf` upvalue taken at this
-- file's load time would capture nil forever, and an NS lookup per value is
-- exactly the per-call cost the perf contract forbids. The callers — the
-- aggregator's join and the window's render pass — carry the brackets instead,
-- which is also where a reader wants to see the number.

local addonName, NS = ...

local Secrets = {}
NS.Secrets = Secrets

-- ---------------------------------------------------------------------------
-- Restriction state
-- ---------------------------------------------------------------------------

-- Enum.AddOnRestrictionType.Combat, with the documented literal as the fallback
-- for a client that has C_RestrictedActions but not the enum (a PTR shape we
-- have actually seen). Resolved at load: the enum does not change mid-session.
local COMBAT_RESTRICTION =
    (_G.Enum and _G.Enum.AddOnRestrictionType and _G.Enum.AddOnRestrictionType.Combat) or 0

--- Enum.AddOnRestrictionState, republished so callers can name the states
--- rather than compare against bare numbers. Values are the documented
--- literals; the live enum wins where it exists.
local STATE = _G.Enum and _G.Enum.AddOnRestrictionState or nil
Secrets.STATE = {
    Inactive   = (STATE and STATE.Inactive)   or 0,
    Activating = (STATE and STATE.Activating) or 1,
    Active     = (STATE and STATE.Active)     or 2,
}

--- Whether the Combat addon restriction is active RIGHT NOW — i.e. whether the
--- meter's numbers are arriving secret.
---
--- The whole C_RestrictedActions namespace is guarded, not just the function:
--- on a client without it the honest answer is "we cannot know", and the closest
--- available approximation is combat lockdown, which is when the restriction
--- would be active if the client had one. Erring toward "restricted" is the safe
--- direction — the cost is a sort frozen for the duration of a pull, and the
--- cost of erring the other way is a Lua error mid-fight.
---
--- Note the restriction keys off Combat, NOT ChallengeMode: between packs in a
--- key the values are fully readable, so value sorting works for most of a
--- dungeon run (design §4).
---
--- @return boolean
function Secrets.IsRestricted()
    local api = _G.C_RestrictedActions
    if api and api.IsAddOnRestrictionActive then
        local ok, active = pcall(api.IsAddOnRestrictionActive, COMBAT_RESTRICTION)
        if ok then return active and true or false end
    end
    return (_G.InCombatLockdown and _G.InCombatLockdown()) and true or false
end

--- The raw Enum.AddOnRestrictionState for the Combat restriction, or nil where
--- the API is absent.
---
--- Callers want this over IsRestricted() in exactly one situation: reacting to
--- ADDON_RESTRICTION_STATE_CHANGED, where `Activating` means "enforcement has
--- not started yet, this is your last chance to read values". Collapsing that to
--- a boolean would throw away the only edge at which a correct value-sort can be
--- taken.
---
--- @return number|nil
function Secrets.GetRestrictionState()
    local api = _G.C_RestrictedActions
    if not (api and api.GetAddOnRestrictionState) then return nil end
    local ok, state = pcall(api.GetAddOnRestrictionState, COMBAT_RESTRICTION)
    if ok then return state end
    return nil
end

-- ---------------------------------------------------------------------------
-- Per-value inspection
-- ---------------------------------------------------------------------------

--- Whether `v` is a secret value.
---
--- Guarded for absence: on a client without the secrets system nothing is
--- secret, so the answer is false rather than an error about a nil global.
---
--- @param v any
--- @return boolean
function Secrets.IsSecret(v)
    local fn = _G.issecretvalue
    if not fn then return false end
    return fn(v) and true or false
end

--- Whether the current execution context may access `v`.
---
--- Distinct from IsSecret in a way that matters: a value can be secret and still
--- accessible — canaccessvalue is the question "may I look at this", and it is
--- the one that decides whether a comparison is legal. A plain value always
--- answers true.
---
--- @param v any
--- @return boolean
function Secrets.CanAccess(v)
    local fn = _G.canaccessvalue
    if fn then return fn(v) and true or false end
    -- No canaccessvalue: fall back to "accessible unless known secret".
    return not Secrets.IsSecret(v)
end

--- Whether ORDERING on `v` is legal right now.
---
--- This is the question modules/Aggregator.lua asks before attempting `value`
--- sort mode, and it is the whole of design rule R2: row order is never computed
--- from values while comparison is illegal. When this answers false the
--- aggregator falls through to `provider` order, which needs no comparison.
---
--- @param v any
--- @return boolean
function Secrets.CanCompare(v)
    return Secrets.CanAccess(v)
end

--- Whether ordering `a` against `b` is legal right now. Both operands have to be
--- accessible: a comparison is a single operation and one secret operand is
--- enough to raise.
---
--- Exists as its own function rather than being spelled out at the call site
--- because a sort comparator is the one place in this addon where forgetting the
--- second operand would produce a bug that only appears in combat, in a raid,
--- when two players' numbers happen to straddle the restriction edge.
---
--- @param a any
--- @param b any
--- @return boolean
function Secrets.CanCompare2(a, b)
    return Secrets.CanAccess(a) and Secrets.CanAccess(b)
end

--- Whether `v` may be used as a TABLE KEY right now.
---
--- The addon joins everything on GUIDs, on the strength of a design note that
--- said a GUID is never secret. That note was right about the METER — a
--- sourceGUID off C_DamageMeter is plain — and wrong about the UNIT API, which
--- is where modules/Roster.lua gets its GUIDs. In a follower dungeon
--- `UnitGUID("party3pet")` answers a secret string, and `pets[petGuid] = guid`
--- raises "attempted to perform indexed assignment on a table that cannot be
--- indexed with secret keys" on every refresh for the whole run.
---
--- So a GUID that came from a unit token is checked here before it is keyed on,
--- and a caller that gets false DROPS the entry: an unattributable pet is
--- already a case the roster and the aggregator handle honestly, and reusing it
--- costs one pet's contribution rather than the entire window.
---
--- Note this is IsSecret and not CanAccess: the key restriction is about the
--- value being secret at all, not about whether this context may read it, and
--- those two answers differ (see CanAccess above).
---
--- @param v any
--- @return boolean
function Secrets.IsSafeKey(v)
    if v == nil then return false end
    return not Secrets.IsSecret(v)
end

-- ---------------------------------------------------------------------------
-- Table inspection
-- ---------------------------------------------------------------------------

--- Whether `t` is a secret table.
--- @param t any
--- @return boolean
function Secrets.IsSecretTable(t)
    local fn = _G.issecrettable
    if not fn then return false end
    return fn(t) and true or false
end

--- Whether the current execution context may access the CONTENTS of `t`.
---
--- The distinction from IsSecretTable is the same as CanAccess vs IsSecret, and
--- it is the gate every iteration below sits behind: a table we may not access
--- cannot be walked at all, and the correct behavior is to render nothing rather
--- than to error.
---
--- @param t any
--- @return boolean
function Secrets.CanAccessTable(t)
    if type(t) ~= "table" then return false end
    local fn = _G.canaccesstable
    if fn then return fn(t) and true or false end
    return not Secrets.IsSecretTable(t)
end

-- Hard ceiling on a single SafeIterate walk.
--
-- The loop cannot use `#` (forbidden on a secret) and cannot trust that the
-- array is nil-terminated where it thinks — so without a bound, a table whose
-- indices are dense past any sane length would spin the client. 512 is far
-- beyond the largest real session (a 40-player raid plus its pets plus every
-- enemy in a pull) and small enough that hitting it costs nothing.
local ITERATION_LIMIT = 512

--- Iterate a possibly-secret array safely, calling `fn(index, value)` per entry.
---
--- THE RULES THIS OBEYS, all four of which are load-bearing:
---   1. It never applies `#` to the table. The length operator is forbidden on
---      a secret, and `#` on a secret table is the single most likely way for a
---      well-meaning refactor to reintroduce a combat error.
---   2. It guards on canaccesstable FIRST and returns 0 when access is refused,
---      so it cannot error on a secret table.
---   3. It stops at the first nil. Testing a NON-BOOLEAN secret for nil-ness is
---      the one permitted boolean-shaped operation (see the contract above), and
---      an array of session rows is exactly that case — the entries are tables,
---      never booleans.
---   4. It never inspects the VALUE it passes to `fn`. The value goes through
---      untouched; what the callback does with it is the callback's contract,
---      not this function's.
---
--- The callback may return false to stop the walk early — used by the tooltip,
--- which only wants the first N spells and has no legal way to ask how many
--- there are first.
---
--- @param tbl table|nil  the array to walk (may be secret, may be nil)
--- @param fn function    called as fn(index, value); return false to stop
--- @return number  how many entries were visited
function Secrets.SafeIterate(tbl, fn)
    if type(tbl) ~= "table" or type(fn) ~= "function" then return 0 end
    if not Secrets.CanAccessTable(tbl) then return 0 end

    local visited = 0
    for i = 1, ITERATION_LIMIT do
        local value = tbl[i]
        -- Nil-ness test only. Never `if value then`, which is a boolean test and
        -- would raise on a secret boolean, and never a comparison against
        -- anything but nil.
        if value == nil then break end
        visited = i
        if fn(i, value) == false then break end
    end
    return visited
end

--- How many entries an array has, obtained WITHOUT the length operator.
---
--- Returns nil — not 0 — when the count is not obtainable, because the two are
--- different facts and a caller that renders "0 sources" when it means "I cannot
--- see the sources" is lying to the player. A window uses the nil to fall back
--- to its unavailable notice; a test uses it to prove the guard fires.
---
--- @param tbl table|nil
--- @return number|nil
function Secrets.SafeCount(tbl)
    if type(tbl) ~= "table" then return nil end
    if not Secrets.CanAccessTable(tbl) then return nil end
    local n = 0
    for i = 1, ITERATION_LIMIT do
        if tbl[i] == nil then break end
        n = i
    end
    return n
end
