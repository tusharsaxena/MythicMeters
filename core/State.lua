-- core/State.lua
--
-- Session-only shared state: the small set of flags several modules have to read
-- IDENTICALLY, and which must never reach SavedVariables. Nothing in this file
-- is persisted, and re-loading the addon re-runs it and re-seeds every default —
-- which is the point. A flag that survives a /reload is a setting, and settings
-- live in defaults/Profile.lua.
--
-- WHY A SEPARATE FILE. Two reasons, both about blast radius. First, "is test
-- mode on" is read by every window, the row pool and the settings panel; putting
-- it on any one of them would make the other two reach across a module boundary
-- to get it (architecture-§4 forbids the reach). Second, each flag here has
-- exactly ONE writer, named in its comment, and collecting them makes that
-- reviewable in one screen instead of grepped for.
--
-- NO SIDE EFFECTS. Unlike the sibling addons' State.lua, this one creates no
-- bootstrap frame and registers no events: core/MythicMeters.lua owns every game
-- event this addon listens to and fans them onto the bus, so a second listener
-- here would be a second source of truth for the same transition.
--
-- TOC POSITION: after core/Constants.lua (the test toggle publishes a bus
-- message named there) and before everything that reads NS.State.

local addonName, NS = ...

-- `debug` is the session-only debug-logging flag (debug-logging-§5). It defaults
-- OFF, is NEVER persisted, and resets on every /reload and fresh login. The ONLY
-- write path is NS.DebugLog:SetEnabled — modules READ NS.State.debug (through
-- the NS.Debug sink) and never mutate it.
--
-- `restricted` mirrors the Combat addon restriction so a per-frame render pass
-- can branch on a plain boolean instead of calling into C_RestrictedActions
-- forty times a second. core/MythicMeters.lua is its only writer, off
-- ADDON_RESTRICTION_STATE_CHANGED; core/Secrets.lua remains the AUTHORITY, and
-- anything that must be right rather than fast asks Secrets.IsRestricted()
-- directly.
--
-- `testMode` is placeholder-data mode, toggled by `/mm test` so a player can lay
-- their columns out without waiting for a fight. Required of any addon with a
-- positionable display.
--
-- IT IS NOT COUPLED TO THE LOCK. It used to be — unlocking a window turned it on
-- — and the result was three controls that each did two things: `/mm lock off`
-- silently switched test data on, and unchecking Test mode did nothing at all
-- while any window was unlocked, because the lock was still forcing it. Each of
-- the three now does exactly one thing:
--   toggle  shows or hides windows
--   lock    permits or forbids dragging and resizing
--   test    shows placeholder rows instead of the meter's
--
-- `activeWindowId` is which window the settings panel's window picker currently
-- points at. It exists because window settings use schema paths RELATIVE to a
-- window ("window.frame.width") and NS.GetSetting / NS.SetByPath resolve them
-- against this id (design §8). Session-only on purpose: which window you were
-- last editing is not a preference, and persisting it would make a deleted
-- window's id outlive the window.
local State = {
    debug          = false,
    restricted     = false,
    testMode       = false,
    activeWindowId = nil,
}
NS.State = State

-- ---------------------------------------------------------------------------
-- Writers
-- ---------------------------------------------------------------------------

--- Record the current addon-restriction state. Called ONLY from
--- core/MythicMeters.lua's ADDON_RESTRICTION_STATE_CHANGED handler.
--- @param v boolean
function State.SetRestricted(v)
    State.restricted = v and true or false
end

--- Record when the meter's current segment began, as an epoch time.
---
--- THE ONE CLOCK THE CLIENT DOES NOT SUPPLY. Measured on a live client reviewed
--- after a run: the Current session held zero deaths, the Overall session held
--- eighteen and reported `deathTimeSeconds = -1` for every one of them, and the
--- session's own duration is COMBAT time rather than wall time — 32 minutes of
--- it spanning a run whose deaths were three hours back. So there is nothing on
--- the client to measure "how far into the fight" against, and this is the
--- anchor "time into the fight" is computed from.
---
--- Called ONLY from core/MythicMeters.lua's fan-out, on the edges that begin a
--- segment. A `/reload` mid-run stamps it at the reload, which is why
--- `Provider.SegmentOffset` refuses a death older than the anchor rather than
--- reporting a negative one.
---
--- @param when number|nil  epoch seconds; defaults to now
function State.SetSegmentStart(when)
    State.segmentStartedAt = when or (_G.time and _G.time()) or nil
end

--- Turn test (placeholder data) mode on or off.
---
--- This is the ONE sender of TEST_MODE_CHANGED (architecture-§4). Every entry
--- point — `/mm test`, the General page's checkbox — routes here rather than each
--- publishing its own message, so the bus catalog names one site and stays true.
---
--- No-ops when the flag is already in the requested state, so a settings panel
--- that re-applies its whole page cannot spam a rebuild of every window.
---
--- @param enabled boolean
function State.SetTestMode(enabled)
    local v = enabled and true or false
    if State.testMode == v then return end
    State.testMode = v
    if NS.State.debug and NS.Debug then
        NS.Debug("Test", "%s", v and "on" or "off")
    end
    if NS.SendMessage then
        NS:SendMessage(NS.Constants.MSG.TEST_MODE_CHANGED, { enabled = v })
    end
end

--- Point the settings panel's window-relative schema paths at `id`.
---
--- Deliberately does NOT publish a message. Changing which window you are
--- EDITING changes nothing about what is on screen, and a bus message here would
--- make every window re-render each time the picker moved.
---
--- @param id number|nil  a window id, or nil to clear
function State.SetActiveWindow(id)
    State.activeWindowId = id
end

-- ---------------------------------------------------------------------------
-- Per-session caches
-- ---------------------------------------------------------------------------
--
-- Scratch space for derived data that is expensive to recompute and cheap to
-- invalidate: modules/Roster.lua's GUID -> { name, class, role, isPet } map, and
-- modules/Format.lua's resolved formatter instances.
--
-- They live HERE rather than as module-locals for one reason: they all have the
-- same lifetime and the same invalidation trigger — a roster change, a profile
-- swap, or a meter reset — so one wipe seam beats three that can fall out of
-- step. Each module owns its own sub-table and never reads another's.
State.cache = {}

--- The named sub-table, created on first use.
--- @param name string  the owning module's name
--- @return table
function State.Cache(name)
    local t = State.cache[name]
    if not t then
        t = {}
        State.cache[name] = t
    end
    return t
end

--- Drop one module's cache, or every cache when `name` is omitted.
---
--- Wipes IN PLACE rather than reassigning, so a module that took its sub-table
--- as an upvalue at load time keeps holding the live one. Reassigning here was
--- the obvious first implementation and it silently orphaned every such upvalue:
--- the module kept writing to a table nothing read.
---
--- @param name string|nil
function State.WipeCache(name)
    if name then
        local t = State.cache[name]
        if t then for k in pairs(t) do t[k] = nil end end
        return
    end
    for _, t in pairs(State.cache) do
        for k in pairs(t) do t[k] = nil end
    end
end
