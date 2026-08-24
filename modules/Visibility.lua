-- modules/Visibility.lua
--
-- WHERE a window is allowed to exist. Not whether it is currently hidden — this
-- module never touches a frame — but whether the addon should be building and
-- refreshing that window at all.
--
-- ---------------------------------------------------------------------------
-- REFUSE AT THE SOURCE
-- ---------------------------------------------------------------------------
--
-- The cheap version of this module would Show/Hide a frame on a zone change and
-- leave the rest of the pipeline running behind it. That is the exact shape
-- performance-§6 forbids: a hidden window that still asks the provider for nine
-- columns, still joins them by GUID and still walks a row pool is paying the
-- full cost of a display nobody can see, and the cost lands in the middle of a
-- raid pull because that is when the meter events fire fastest.
--
-- So this file publishes a PREDICATE and nothing else. NS.ShouldShow (in
-- core/MultiMeters.lua) consults it as step 3 of the one show ladder, and a
-- window whose answer is false is never built and never refreshed. There is no
-- Show, no Hide and no SetAlpha anywhere below, and adding one would quietly
-- turn the refusal back into a curtain drawn over work that still happens.
--
-- ---------------------------------------------------------------------------
-- WHY THE ANSWER IS COMPUTED LIVE
-- ---------------------------------------------------------------------------
--
-- Every input here — IsInInstance, IsInGroup, UnitInVehicle, IsMounted and the
-- rest — is a cheap client query, and the predicate runs on context transitions
-- and once per window per refresh tick, never per frame. A cached context would
-- buy nothing measurable and would cost the one thing that matters: correctness
-- across a transition
-- this module cannot see: a cache keyed on the bus goes stale for exactly as long
-- as the player stays in a state whose edge was missed. Reading live means the
-- answer is right the next time anything asks.
--
-- BUT "THE NEXT TIME ANYTHING ASKS" IS NOT A CLOCK, and an earlier version of
-- this header claimed it was — "at worst one refresh interval later". It is not.
-- modules/Window.lua's onUpdate refreshes DATA and never re-asks NS.ShouldShow,
-- so the ladder is re-run only from a bus message a window subscribes to. Every
-- input to the rules below therefore needs an edge on the bus, or the rule that
-- reads it is dead. That is what core/MultiMeters.lua's player-state block is
-- for, and it is why `hideInVehicle` never fired for its first two releases.
--
-- Evaluate() therefore exists for its RETURN VALUE and its debug line, not to
-- prime a cache the predicate reads. What it keeps is the LAST answer per
-- window, so `/mm debug diag` and the tests can say what changed and why.
--
-- COMBAT: read with UnitAffectingCombat("player") and never InCombatLockdown().
-- Lockdown is about whether SECURE writes are legal, and nothing here writes
-- anything secure; as a proxy for "the player is fighting" it is wrong at both
-- edges of a pull, latching slightly early and releasing slightly late. Reading
-- it live also means there is no cached combat flag to go stale — a flag would
-- need a PLAYER_DEAD safety net, because leaving combat by dying does not
-- reliably fire PLAYER_REGEN_ENABLED and the flag would latch true until a
-- reload.

local addonName, NS = ...

local Visibility = NS:NewModule("Visibility", "AceEvent-3.0")

-- Published under the flat name as well as the AceAddon module registry, because
-- the two call sites reach for it differently: core/MultiMeters.lua's ladder
-- uses NS:GetModule("Visibility", true) so a partial install fails open, and
-- settings/Slash.lua resolves NS.<Name> first. Same object either way.
NS.Visibility = Visibility

local State    = NS.State
local Debug    = NS.Debug

-- ---------------------------------------------------------------------------
-- Context
-- ---------------------------------------------------------------------------
--
-- IsInInstance() answers (isInstance, instanceType) where instanceType is one of
-- "none", "party", "raid", "arena", "pvp" or "scenario". The window's visibility
-- config is keyed by the PLAYER-FACING name of each context, not by Blizzard's
-- token, so this table is the whole translation and the settings page and this
-- module cannot drift apart over what "pvp" means.
--
-- Anything not named here — "none" and any instance type a future patch invents
-- — resolves to "world", which is the honest reading of "somewhere this addon has
-- no name for": it is not a dungeon, a raid or an arena, so it is the outdoors as
-- far as these rules are concerned.
--
-- NOTE WHAT THAT MEANS NOW `world` SHIPS TRUE. An instance type a future patch
-- invents will SHOW by default rather than hide, which is the opposite of the
-- 0.1.0 behaviour, where `world` shipped false and the fallthrough was
-- deny-by-default in practice. That is the deliberate trade: a context nobody has
-- taught this addon about draws a meter the player can then switch off, rather
-- than silently withholding one they cannot find the switch for.
local CONTEXT_BY_INSTANCE_TYPE = {
    party    = "dungeon",
    raid     = "raid",
    arena    = "arena",
    pvp      = "battleground",
    scenario = "scenario",
}

--- Which visibility context the player is standing in right now.
---
--- THE DELVE PROBE RUNS FIRST, and it has to. Blizzard has no delve instance
--- type — a delve reports "scenario", the same token an ordinary scenario and a
--- follower dungeon report — so consulting the table first would collapse two
--- player-facing contexts into one checkbox that cannot tell them apart.
--- Compat.IsInDelve owns the three-signal ladder that makes the distinction.
---
--- @return string  "delve", "dungeon", "raid", "arena", "battleground",
---                 "scenario" or "world"
function Visibility.GetContext()
    if not _G.IsInInstance then return "world" end
    if NS.Compat and NS.Compat.IsInDelve and NS.Compat.IsInDelve() then
        return "delve"
    end
    local _, instanceType = IsInInstance()
    return CONTEXT_BY_INSTANCE_TYPE[instanceType] or "world"
end

--- Whether the player is currently driving a vehicle.
---
--- Guarded for absence rather than assumed present: the headless test harness
--- has no unit API at all, and "not in a vehicle" is the answer that keeps a
--- window visible, which is the safe direction for a query that only ever hides.
---
--- @return boolean
local function inVehicle()
    if not _G.UnitInVehicle then return false end
    return UnitInVehicle("player") and true or false
end

--- Whether the player is in a party or raid.
--- @return boolean
local function inGroup()
    if not _G.IsInGroup then return false end
    return IsInGroup() and true or false
end

--- Whether the player is fighting.
---
--- UnitAffectingCombat, never InCombatLockdown — see the COMBAT note in the
--- header. Read live, so there is no flag to latch through a death.
---
--- @return boolean
local function inCombat()
    if not _G.UnitAffectingCombat then return false end
    return UnitAffectingCombat("player") and true or false
end

-- The druid shapeshift form ids that are TRAVEL, not combat: Travel (3),
-- Aquatic (4) and Flight (27). Read as a form CATEGORY rather than by the form
-- aura's spell id, which has drifted across patches; no collision with the forms
-- a druid fights in — Cat (1), Bear (5), Moonkin (31).
local MOUNT_LIKE_FORM_IDS = { [3] = true, [4] = true, [27] = true }

--- Whether the player is mounted, or in a form that amounts to being mounted.
---
--- The form arm is what makes this rule mean the same thing for a druid as it
--- does for everybody else: IsMounted() is false in Travel Form, so without it a
--- druid ticking "hide when mounted" would watch the window stay up for the
--- entire ride. The flight forms that are not mounts and not druid — Dracthyr
--- Soar, Haranir — are caught by the skyriding rule instead, which keys on glide
--- capability rather than on being mounted.
---
--- @return boolean
local function mounted()
    if _G.IsMounted and IsMounted() then return true end
    if _G.GetShapeshiftFormID and MOUNT_LIKE_FORM_IDS[GetShapeshiftFormID()] then
        return true
    end
    return false
end

--- Whether the player is riding a flight path.
--- @return boolean
local function onTaxi()
    if not _G.UnitOnTaxi then return false end
    return UnitOnTaxi("player") and true or false
end

--- Whether a pet battle is on screen.
--- @return boolean
local function inPetBattle()
    local api = _G.C_PetBattles
    if not (api and api.IsInBattle) then return false end
    return api.IsInBattle() and true or false
end

--- Whether the player is dead or running as a ghost.
--- @return boolean
local function deadOrGhost()
    if not _G.UnitIsDeadOrGhost then return false end
    return UnitIsDeadOrGhost("player") and true or false
end

--- Whether the player is on a skyriding mount or in a glide-capable form.
--- @return boolean
local function skyriding()
    return (NS.Compat and NS.Compat.IsSkyriding and NS.Compat.IsSkyriding()) or false
end

--- Whether the player is inside their house or on their plot.
--- @return boolean
local function inHousing()
    return (NS.Compat and NS.Compat.IsInHousing and NS.Compat.IsInHousing()) or false
end

-- ---------------------------------------------------------------------------
-- The predicate
-- ---------------------------------------------------------------------------

--- Whether `window` is allowed to be on screen in the current context.
---
--- ORDER MATTERS, and it is: context first, then every veto. The context answers
--- the primary question the settings page asks ("show this window in
--- dungeons?"), and the vetoes are overrides layered on top of a context that
--- already said yes. Running them the other way round would report "solo" as the
--- reason a window is hidden in the open world, when the real reason is that
--- open world ships off.
---
--- WHY EVERY RULE IS HIDE-SHAPED. The settings page could as easily have offered
--- "show when mounted" or "show in combat"; it does not, and the reason is this
--- function's second line. A key MISSING from a stored window has to read as
--- "nothing objects" — a show-shaped key is false when absent, so a profile
--- written before the rule existed would have every window hidden by a setting
--- its owner never touched. core/Database.lua's EnsureWindowShape backfills the
--- shape, but on a schedule this module cannot see and must not depend on.
---
--- The second return names the step that decided. It is a stable, UNLOCALIZED
--- token — `/mm debug diag` prints it and the tests assert on it, and both of those
--- break the moment a translator gets hold of it.
---
--- Note what is NOT here: the master enable, preview mode and the perf suspend
--- flag. Those are steps 0 to 2 of NS.ShouldShow, they apply to every window
--- rather than to a window's own rules, and duplicating them here would give the
--- addon two places that can answer "why is my window not showing" differently.
---
--- @param window table  a window config from the profile
--- @return boolean show, string reason
function Visibility.ShouldShow(window)
    if type(window) ~= "table" then return false, "no window" end

    -- A window whose config predates the visibility group (or a hand-edited
    -- SavedVariables) has no rules to apply, and the honest reading of "no
    -- rules" is "nothing objects" rather than "hide it". core/Database.lua's
    -- EnsureWindowShape normally fills this in long before we are asked.
    local rules = window.visibility
    if type(rules) ~= "table" then return true, "no rules" end

    local context = Visibility.GetContext()
    if not rules[context] then return false, context end

    -- The vetoes, most-specific state first. The order between them only shows
    -- up in the REASON when two states are true at once, so it is ordered the way
    -- a player would explain it: the thing you are sitting in or on, then what
    -- you are doing, then where you are, then whether anyone is with you.
    if rules.hideInVehicle and inVehicle() then return false, "vehicle" end
    if rules.hideWhenSkyriding and skyriding() then return false, "skyriding" end
    if rules.hideWhenMounted and mounted() then return false, "mounted" end
    if rules.hideOnTaxi and onTaxi() then return false, "taxi" end
    if rules.hideInPetBattle and inPetBattle() then return false, "pet battle" end
    if rules.hideWhenDead and deadOrGhost() then return false, "dead" end
    if rules.hideInHousing and inHousing() then return false, "housing" end
    if rules.hideWhenSolo and not inGroup() then return false, "solo" end

    -- Combat last, and read as two independent rules rather than one tri-state.
    -- Ticking both is a window that never shows; that is the player's business,
    -- and the reason still names the side of the pull they are standing on so
    -- `/mm debug diag` can explain it.
    if inCombat() then
        if rules.hideInCombat then return false, "in combat" end
    elseif rules.hideOutOfCombat then
        return false, "out of combat"
    end

    return true, context
end

--- The ladder's entry point, named for what the ladder asks rather than for what
--- this module computes: core/MultiMeters.lua reads
--- `Visibility:Allows(window)`.
---
--- A method (colon) rather than a plain function because that is how the ladder
--- calls every module it consults; `self` is deliberately ignored so the two
--- names stay one implementation.
---
--- @param window table
--- @return boolean ok, string reason
function Visibility:Allows(window)
    return Visibility.ShouldShow(window)
end

-- ---------------------------------------------------------------------------
-- Evaluation pass
-- ---------------------------------------------------------------------------

-- [windowId] = { show = boolean, reason = string } — the last answer this module
-- gave for each window. Session-only and module-local rather than in
-- State.Cache: nothing else reads it, and the caches in core/State.lua are wiped
-- on a meter reset, which has nothing to do with where a window may appear.
local lastResult = {}

--- The key a window's answer is remembered under: its own id when it has one,
--- and its position in the registry when it does not. The fallback matters for a
--- profile written before window ids existed — without it every such window
--- shares the key `nil` and the pass reports one change per tick forever.
---
--- @param window table|nil
--- @param index number  the window's position in the registry
--- @return number|string
local function windowKey(window, index)
    if type(window) == "table" and window.id then return window.id end
    return index
end

--- Store the answer for `id` and say whether it differs from the answer this
--- module gave last time. A window that has never been evaluated counts as
--- changed, so the first pass of a session reports every window.
---
--- @return boolean  whether the answer moved
local function remember(id, show, reason)
    local previous = lastResult[id]
    if previous and previous.show == show and previous.reason == reason then
        return false
    end
    lastResult[id] = { show = show, reason = reason }
    return true
end

--- One window's slice of the debug line, in the form `#3=hide(solo)`.
--- Called only from inside the debug gate — see Evaluate.
---
--- @return string
local function describeResult(id, show, reason)
    return string.format("#%s=%s(%s)", tostring(id), show and "show" or "hide", reason)
end

--- The last answer computed for a window id, or nil if it has never been
--- evaluated. Exists for `/mm debug diag` and the tests; the render path uses the
--- predicate directly and never this.
---
--- @param windowId number|nil
--- @return boolean|nil show, string|nil reason
function Visibility.LastResult(windowId)
    local entry = lastResult[windowId]
    if not entry then return nil end
    return entry.show, entry.reason
end

--- Re-evaluate every window in the registry.
---
--- Publishes NOTHING. That is not an omission — it is the point of refusing at
--- the source. A window discovers the new answer the next time it consults
--- NS.ShouldShow, which is on the same bus messages that brought us here plus
--- its own refresh tick; a message from this module would be a second, racing
--- path to the same decision and would let two windows disagree about the
--- current zone for one frame.
---
--- @return number  how many windows changed their answer
function Visibility:Evaluate()
    local Database = NS.Database
    local windows = Database and Database.GetWindows and Database.GetWindows()
    if type(windows) ~= "table" then return 0 end

    local changed = 0
    local summary

    for i = 1, #windows do
        local window = windows[i]
        local id = windowKey(window, i)
        local show, reason = Visibility.ShouldShow(window)

        if remember(id, show, reason) then
            changed = changed + 1
        end

        -- ONE line per pass, not one per window, and the string that builds it
        -- lives entirely inside the gate so a debug-off session pays nothing for
        -- the concatenation (debug-logging-§4).
        if State.debug and Debug then
            summary = (summary and (summary .. " ") or "") .. describeResult(id, show, reason)
        end
    end

    if summary and Debug then
        Debug("Visibility", "%s", summary)
    end

    return changed
end

--- The name the rest of the addon uses when it wants the pass re-run —
--- settings/Slash.lua calls `NS.Visibility:Refresh()` after a settings change.
--- Same pass, spelled the way a caller thinks about it.
---
--- @return number  how many windows changed their answer
function Visibility:Refresh()
    return self:Evaluate()
end

--- Forget every remembered answer. Called on a profile swap, where the window
--- ids on the other side of the swap describe entirely different windows and a
--- retained answer would be attributed to the wrong one.
function Visibility.Forget()
    for id in pairs(lastResult) do lastResult[id] = nil end
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------
--
-- Bus messages only. core/MultiMeters.lua is the addon's single game-event
-- listener (architecture-§4), so this module hears about a zone change through
-- ZONE_CHANGED rather than by registering ZONE_CHANGED_NEW_AREA itself — which
-- is what keeps "the game said something" to one reviewable place.
--
-- The module object carries its own embedded AceEvent, so these registrations
-- land on this module's target and cannot collide with another subscriber's.

function Visibility:OnEnable()
    local MSG = NS.Constants.MSG
    self:RegisterMessage(MSG.ZONE_CHANGED,     "OnContextChanged")
    self:RegisterMessage(MSG.ENTERING_WORLD,   "OnContextChanged")
    self:RegisterMessage(MSG.ROSTER_CHANGED,   "OnContextChanged")
    -- The player-state edges. This module's own subscription exists for the
    -- Evaluate pass and its debug line ONLY — it is not what makes a window
    -- react. modules/Window.lua subscribes to the same two messages and re-runs
    -- the show ladder there, because this module publishes nothing and a window
    -- has no other reason to ask again.
    self:RegisterMessage(MSG.COMBAT_CHANGED,       "OnContextChanged")
    self:RegisterMessage(MSG.PLAYER_STATE_CHANGED, "OnContextChanged")
    self:RegisterMessage(MSG.PROFILE_CHANGED,  "OnProfileChanged")
end

function Visibility:OnContextChanged()
    self:Evaluate()
end

function Visibility:OnProfileChanged()
    Visibility.Forget()
    self:Evaluate()
end
