-- modules/Feign.lua
--
-- The one source row this addon deliberately throws away.
--
-- ---------------------------------------------------------------------------
-- WHY THIS FILE EXISTS
-- ---------------------------------------------------------------------------
--
-- `C_DamageMeter` hands a Feign Death a VALID `deathRecapID`, so the meter
-- reports it as a death like any other and the Deaths column counts it. A
-- hunter who feigns twice in a dungeon reads as a hunter who died twice, and
-- the death drill-down (issue #1) would list two deaths with recaps behind
-- them.
--
-- Nothing about that is visible from offline tests or from reading the count:
-- the arithmetic is right, the source row is really there, and only knowing
-- what Feign Death is tells you the row is a lie.
--
-- ---------------------------------------------------------------------------
-- WHAT IT COSTS, STATED UP FRONT
-- ---------------------------------------------------------------------------
--
-- THE FILTER CANNOT RUN MID-PULL, and that is structural rather than an
-- oversight. It joins a GUID recorded here from a cast against `sourceGUID` on
-- a meter row — and `sourceGUID` is secret for the whole of a pull, which is
-- the entire reason modules/Aggregator.lua has a second, GUID-free build for
-- restricted mode. There is no plain key on the other side of the join while
-- the restriction is up, so a feign IS counted as a death mid-pull and the
-- count corrects itself the moment combat ends and the GUID build resumes.
--
-- Do not "fix" that by keying on something secret. There is nothing to key on.
--
-- ---------------------------------------------------------------------------
-- WHAT IT MAY TOUCH
-- ---------------------------------------------------------------------------
--
-- No meter value, ever. Everything here is a unit GUID, a spell id and a health
-- figure from the unit API — none of it from C_DamageMeter. Two of the three can
-- still arrive SECRET, and both are gated: a secret spell id cannot meet `==`,
-- and a secret GUID cannot be a table key at all.
--
-- Unit APIs are reached through `_G` at CALL time, never captured at load, for
-- the reasons modules/Roster.lua's header gives: the headless harness installs
-- its unit mocks after the files load.
--
-- The spell id itself lives in core/MythicMeters.lua beside the handler that
-- compares it, not here: this module never sees the cast, only its conclusion.

local addonName, NS = ...

local Feign = NS:NewModule("Feign", "AceEvent-3.0")
NS.Feign = Feign

local Const   = NS.Constants
local Secrets = NS.Secrets
local State   = NS.State
local Debug   = NS.Debug

local MSG = Const.MSG

-- [guid] = true, for players believed to be feigning. Session-scoped: a run's
-- feigns mean nothing to the next one.
local feigned = {}

-- Whether anything is in the set. `next` on every prune would be cheap already;
-- this makes the common case — nobody in the group has ever feigned — a single
-- boolean test on the refresh path.
local anyFeigned = false

local function unitHealth(unit)
    local f = _G.UnitHealth
    return f and f(unit) or nil
end

-- ---------------------------------------------------------------------------
-- The set
-- ---------------------------------------------------------------------------

--- Record that this GUID is feigning.
---
--- @param guid any  from the unit API, and NOT trusted to be plain
function Feign.Note(guid)
    -- A secret cannot be a table key: the assignment raises before it stores
    -- anything. The unit API is not a safe source — core/Secrets.lua records a
    -- follower dungeon handing out secret pet GUIDs — so this is a real gate
    -- rather than a formality.
    if not Secrets.IsSafeKey(guid) then return end
    feigned[guid] = true
    anyFeigned = true
    if State.debug and Debug then Debug("Feign", "noted %s", tostring(guid)) end
end

--- Whether this GUID is believed to be feigning rather than dead.
---
--- Answers FALSE for anything it cannot look up, including a secret. "I cannot
--- tell" and "not feigning" have to be the same answer here, because the
--- alternative is dropping a real death.
---
--- @param guid any
--- @return boolean
function Feign.IsFeigned(guid)
    if not anyFeigned then return false end
    if not Secrets.IsSafeKey(guid) then return false end
    return feigned[guid] == true
end

--- Forget everybody.
function Feign.Clear()
    if not anyFeigned then return end
    feigned = {}
    anyFeigned = false
end

--- Drop entries that are no longer true.
---
--- TWO WAYS OUT OF THE SET, and the first is the one that matters. A hunter who
--- feigns and then really dies must have that death counted, so a confirmed
--- zero health clears the entry. `UnitIsFeignDeath` is deliberately not used
--- for this: it can stay true through a feign-then-die transition, which would
--- hide the real death behind the fake one.
---
--- The second is leaving the group, which makes the entry untrackable — there is
--- no unit token left to read health from, so it could never be cleared and
--- would sit in the set for the rest of the session.
---
--- Called once per refresh pass from the Deaths walk, so the empty case — every
--- run where nobody has feigned — exits on one boolean before touching the
--- roster.
function Feign.Prune()
    if not anyFeigned then return end

    local Roster = NS.Roster
    local group = Roster and Roster.GetGroup and Roster.GetGroup() or nil

    -- guid -> unit token, built once so the walk below is O(N+M) rather than
    -- O(N*M). A group is small either way; the shape is what keeps it honest.
    local present = {}
    if group then
        for i = 1, #group do
            local entry = group[i]
            if entry and Secrets.IsSafeKey(entry.guid) and entry.unit then
                present[entry.guid] = entry.unit
            end
        end
    end

    local remaining = false
    for guid in pairs(feigned) do
        local unit = present[guid]
        if unit == nil then
            feigned[guid] = nil
        else
            local hp = unitHealth(unit)
            -- Nil-ness first, then the comparison, and only when the figure can
            -- legally be compared. A health figure from the unit API is not a
            -- meter value, but nothing says the client cannot make one secret.
            if hp ~= nil and Secrets.CanCompare(hp) and hp <= 0 then
                feigned[guid] = nil
            else
                remaining = true
            end
        end
    end
    anyFeigned = remaining
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
--
-- The cast itself arrives from core/MythicMeters.lua, which owns every game
-- event in this addon (architecture-§4). What is subscribed here are the three
-- bus messages that make the set stale.

function Feign:OnEnable()
    self:RegisterMessage(MSG.METER_RESET,    "OnForget")
    self:RegisterMessage(MSG.ENTERING_WORLD, "OnForget")
    self:RegisterMessage(MSG.ROSTER_CHANGED, "OnRosterChanged")
end

function Feign:OnForget()
    Feign.Clear()
end

function Feign:OnRosterChanged()
    Feign.Prune()
end
