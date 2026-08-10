-- tests/test_state.lua — core/State.lua, the session-only shared flags.
--
-- Small file, three properties worth pinning:
--
--   * NOTHING here is persisted. A flag that survives a /reload is a setting,
--     and settings live in defaults/Profile.lua. `debug` in particular must never
--     reach SavedVariables (debug-logging-§5) — a console left on across a login
--     is a console nobody asked for.
--   * SetTestMode is the ONE sender of TEST_MODE_CHANGED, and it NO-OPS when the
--     flag is already in the requested state. The settings panel re-applies a
--     whole page on every refresh, so a message per re-application would rebuild
--     every window several times per keystroke.
--   * WipeCache wipes IN PLACE. Reassigning was the obvious first implementation
--     and it silently orphans every module that took its sub-table as a load-time
--     upvalue: the module keeps writing to a table nothing reads.

local T = _G.MYTHICMETERS_TEST
local NS = T.NS
local test, assertEqual, assertTrue, assertFalse, assertNil =
    T.test, T.assertEqual, T.assertTrue, T.assertFalse, T.assertNil

local MSG = NS.Constants.MSG

--- Count TEST_MODE_CHANGED publications on an instance, and capture the last payload.
local function watchPreview(inst)
    local seen = { count = 0 }
    local target = inst.NS.NewBusTarget()
    target:RegisterMessage(MSG.TEST_MODE_CHANGED, function(_, payload)
        seen.count = seen.count + 1
        seen.last  = payload
    end)
    return seen
end

-- ── the flags themselves ────────────────────────────────────────────────────

test("State: every flag starts at its shipped default on a fresh load", function()
    -- Re-loading the addon re-runs the file and re-seeds every default, which is
    -- the point of the flags living here rather than in the profile.
    local S = T.load{}.NS.State
    assertEqual(S.debug, false, "debug defaults OFF and is never persisted")
    assertEqual(S.restricted, false)
    assertEqual(S.testMode, false)
    assertNil(S.activeWindowId)
end)

test("State: no state flag leaks into the profile defaults tree", function()
    -- red under: moving `debug` into defaults/Profile.lua, which is where it
    -- would end up in SavedVariables and survive a login.
    local inst = T.load{}
    local profile = inst.NS.defaults.profile
    for _, key in ipairs({ "debug", "restricted", "testMode", "activeWindowId" }) do
        assertNil(profile[key], "profile defaults must not carry the session flag " .. key)
    end
end)

test("State: the SavedVariables globals never carry a state flag after a full load", function()
    -- The belt to the braces above: the previous case reads the DEFAULTS tree,
    -- this one reads what actually landed in the saved global.
    local inst = T.load{}
    inst.NS.State.debug = true
    inst.NS.State.SetTestMode(true)
    local saved = _G.MythicMetersDB
    assertTrue(saved ~= nil, "the database must actually have been built")
    for _, key in ipairs({ "debug", "testMode", "restricted", "activeWindowId" }) do
        assertNil((saved.profiles and saved.profiles.Default or {})[key],
            key .. " reached SavedVariables")
    end
end)

test("State: SetRestricted normalizes to a plain boolean", function()
    -- The render pass branches on this forty times a second instead of calling
    -- into C_RestrictedActions; a truthy non-boolean would be a value the mirror
    -- cannot be compared against.
    local S = T.load{}.NS.State
    S.SetRestricted("yes")
    assertEqual(S.restricted, true)
    S.SetRestricted(nil)
    assertEqual(S.restricted, false)
end)

test("State: core/Secrets.lua stays the authority, and State is only its mirror", function()
    -- The mirror is a performance decision, not a second source of truth.
    -- Anything that must be RIGHT rather than fast asks Secrets.IsRestricted().
    -- red under: making State.restricted the value Secrets.IsRestricted returns.
    local inst = T.load{}
    inst.mocks.setRestricted(true)
    assertTrue(inst.NS.Secrets.IsRestricted(), "the client says restricted")
    assertFalse(inst.NS.State.restricted,
        "but the mirror only moves when core/MythicMeters.lua writes it")
end)

test("State: only core/MythicMeters.lua writes the restriction mirror", function()
    -- One writer per flag is what makes this file reviewable in a screen. A
    -- second caller of SetRestricted is a second answer to "when did that flip".
    -- red under: calling State.SetRestricted from a module's OnEnable.
    local callers = {}
    for _, rel in ipairs(T.loadedAddonFiles) do
        local fh = io.open((T.root or ".") .. "/" .. rel, "r")
        local src = fh and fh:read("*a") or ""
        if fh then fh:close() end
        src = src:gsub("%-%-[^\r\n]*", "")
        if src:match("SetRestricted%s*%(") and rel:lower() ~= "core/state.lua" then
            callers[#callers + 1] = rel
        end
    end
    assertEqual(table.concat(callers, ", "), "core/MythicMeters.lua")
end)

-- ── testMode ─────────────────────────────────────────────────────────────────

test("State: SetTestMode flips the flag and publishes TEST_MODE_CHANGED once", function()
    local inst = T.load{}
    local seen = watchPreview(inst)
    inst.NS.State.SetTestMode(true)
    assertTrue(inst.NS.State.testMode)
    assertEqual(seen.count, 1)
    assertEqual(seen.last.enabled, true, "the payload names the new state")
end)

test("State: SetTestMode no-ops when the flag is already in the requested state", function()
    -- The settings panel re-applies a whole page on every refresh. A message per
    -- re-application rebuilds every window on the screen for a value that did
    -- not move.
    -- red under: dropping the `if State.testMode == v then return end` guard.
    local inst = T.load{}
    local seen = watchPreview(inst)
    inst.NS.State.SetTestMode(true)
    inst.NS.State.SetTestMode(true)
    inst.NS.State.SetTestMode(true)
    assertEqual(seen.count, 1, "three identical writes must publish once")
    inst.NS.State.SetTestMode(false)
    assertEqual(seen.count, 2, "a real change must still publish")
    assertEqual(seen.last.enabled, false)
end)

test("State: SetTestMode coerces truthy values to a boolean before comparing", function()
    -- Without the coercion, `SetTestMode("x")` then `SetTestMode(true)` would look
    -- like two different states and publish twice for one visible change.
    local inst = T.load{}
    local seen = watchPreview(inst)
    inst.NS.State.SetTestMode("x")
    assertEqual(inst.NS.State.testMode, true)
    inst.NS.State.SetTestMode(true)
    assertEqual(seen.count, 1)
end)

test("State: SetTestMode is the only sender of TEST_MODE_CHANGED", function()
    -- Every entry point routes here, so
    -- the bus catalog names one site and stays true (architecture-§4).
    local senders = {}
    for _, rel in ipairs(T.loadedAddonFiles) do
        local fh = io.open((T.root or ".") .. "/" .. rel, "r")
        local src = fh and fh:read("*a") or ""
        if fh then fh:close() end
        src = src:gsub("%-%-[^\r\n]*", "")
        if src:match("SendMessage%(%s*[%w_%.]*TEST_MODE_CHANGED") then senders[#senders + 1] = rel end
    end
    assertEqual(table.concat(senders, ", "), "core/State.lua")
end)

-- ── the active window pointer ───────────────────────────────────────────────

test("State: SetActiveWindow moves the pointer and publishes NOTHING", function()
    -- Changing which window you are EDITING changes nothing about what is on
    -- screen. A bus message here would re-render every window each time the
    -- settings panel's picker moved.
    -- red under: adding a SendMessage to SetActiveWindow.
    local inst = T.load{}
    local sent = 0
    local target = inst.NS.NewBusTarget()
    for _, name in pairs(MSG) do
        target:RegisterMessage(name, function() sent = sent + 1 end)
    end
    inst.NS.State.SetActiveWindow(4)
    assertEqual(inst.NS.State.activeWindowId, 4)
    inst.NS.State.SetActiveWindow(nil)
    assertNil(inst.NS.State.activeWindowId, "nil must clear the pointer, not be ignored")
    assertEqual(sent, 0, "retargeting the settings panel must not publish anything")
end)

-- ── the per-session caches ──────────────────────────────────────────────────

test("State: Cache creates a named sub-table on first use and returns the same one after", function()
    local S = T.load{}.NS.State
    local first = S.Cache("Roster")
    assertEqual(type(first), "table")
    first.guid = "value"
    assertTrue(S.Cache("Roster") == first, "Cache must not hand back a fresh table each call")
    assertEqual(S.Cache("Roster").guid, "value")
end)

test("State: two modules' caches are independent", function()
    local S = T.load{}.NS.State
    S.Cache("Roster").x = 1
    S.Cache("Format").y = 2
    assertNil(S.Cache("Roster").y)
    assertNil(S.Cache("Format").x)
end)

test("State: WipeCache empties one cache IN PLACE, keeping the caller's upvalue live", function()
    -- THE case. Reassigning the sub-table orphans every module that took it as a
    -- load-time upvalue — the module keeps writing to a table nothing reads, and
    -- nothing raises.
    -- red under: `State.cache[name] = {}`.
    local S = T.load{}.NS.State
    local held = S.Cache("Roster")     -- what a module would capture at load
    held.guid = "Player-1-1"
    S.WipeCache("Roster")
    assertNil(held.guid, "the wipe must empty the table the module is still holding")
    assertTrue(S.Cache("Roster") == held, "and must not replace it")
end)

test("State: WipeCache with no name empties every cache, still in place", function()
    local S = T.load{}.NS.State
    local roster, format = S.Cache("Roster"), S.Cache("Format")
    roster.a, format.b = 1, 2
    S.WipeCache()
    assertNil(roster.a)
    assertNil(format.b)
    assertTrue(S.Cache("Roster") == roster)
    assertTrue(S.Cache("Format") == format)
end)

test("State: WipeCache on a cache that was never created is a no-op, not an error", function()
    local S = T.load{}.NS.State
    S.WipeCache("NeverUsed")
    assertEqual(type(S.Cache("NeverUsed")), "table")
end)

-- ── no side effects at load ─────────────────────────────────────────────────

test("State: loading core/State.lua creates no frame and registers no game event", function()
    -- Unlike the sibling addons' State.lua this one is inert: core/MythicMeters.lua
    -- owns every game event and fans it onto the bus, so a second listener here
    -- would be a second source of truth for the same transition.
    local fh = assert(io.open((T.root or ".") .. "/core/State.lua", "r"))
    local src = fh:read("*a")
    fh:close()
    src = src:gsub("%-%-[^\r\n]*", "")
    assertNil(src:match("CreateFrame"), "core/State.lua must create no frame")
    assertNil(src:match("RegisterEvent"), "core/State.lua must register no game event")
end)
