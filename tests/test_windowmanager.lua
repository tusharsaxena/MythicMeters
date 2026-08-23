-- tests/test_windowmanager.lua — modules/WindowManager.lua: the registry.
--
-- The behavior worth the most here is the DEEP COPY. Two windows sharing one
-- sub-table is the classic profile-aliasing bug, where editing window 2's bar
-- color silently edits window 1's — and it is invisible in every test that only
-- checks the copied VALUES, because a shared table has the right values too. So
-- every copy case below mutates the SOURCE afterwards and asserts the target did
-- not move.

local T = _G.MULTIMETERS_TEST

local test        = T.test
local assertEqual = T.assertEqual
local assertTrue  = T.assertTrue
local assertFalse = T.assertFalse
local assertNil   = T.assertNil

--- A loaded, ENABLED instance: WindowManager:Init runs on OnEnable, so the
--- registry has a live instance per stored config.
local function loaded()
    local inst = T.load{ enable = true }
    return inst, inst.NS.WindowManager
end

-- ---------------------------------------------------------------------------
-- Publication and lifecycle
-- ---------------------------------------------------------------------------

test("WindowManager is published under the flat name every caller uses", function()
    local inst = T.load()
    -- NewModule writes into AceAddon's registry and NOWHERE else. Without the
    -- explicit assignment, settings/Slash.lua, settings/Frame.lua,
    -- settings/Windows.lua and settings/Schema.lua all find nil and silently do
    -- nothing — the whole window-management surface going quiet with no error.
    assertTrue(inst.NS.WindowManager ~= nil)
    assertTrue(inst.NS.WindowManager == inst.NS:GetModule("WindowManager"))
end)

test("Init builds one live instance per stored config, and is idempotent", function()
    local inst, M = loaded()
    assertEqual(#M.All(), 1)

    local first = M.All()[1]
    M:Init()
    assertTrue(M.All()[1] == first, "a rebuild would be a flicker the player sees")

    -- A profile swap hands over a DIFFERENT table with the same id; the instance
    -- is re-pointed rather than torn down.
    local cfg = inst.NS.Database.GetWindows()[1]
    local replacement = {}
    for k, v in pairs(cfg) do replacement[k] = v end
    inst.NS.Database.GetWindows()[1] = replacement
    M:Init()
    assertTrue(M.All()[1] == first)
    assertTrue(first.config == replacement)
end)

test("All() answers in the registry's order, which is the user's", function()
    local inst, M = loaded()
    M:Create("Raid")
    M:Create("Dungeon")

    local windows = inst.NS.Database.GetWindows()
    local instances = M.All()
    assertEqual(#instances, #windows)
    for i, cfg in ipairs(windows) do
        assertEqual(instances[i].id, cfg.id)
    end
end)

-- ---------------------------------------------------------------------------
-- Resolve
-- ---------------------------------------------------------------------------

test("Resolve takes an id or a name, and folds case on the way in only", function()
    local inst, M = loaded()
    local cfg = inst.NS.Database.GetWindows()[1]
    cfg.name = "Raid Frame"

    assertTrue(M.Resolve(cfg.id) == cfg, "a number is an id")
    assertTrue(M.Resolve("raid frame") == cfg, "a string is a name, matched case-insensitively")
    assertEqual(cfg.name, "Raid Frame", "and stored exactly as the player typed it")
    assertNil(M.Resolve("nothing called this"))
    assertNil(M.Resolve(nil))
end)

test("A window literally named \"2\" wins over the window whose id is 2", function()
    local inst, M = loaded()
    M:Create("second")
    local windows = inst.NS.Database.GetWindows()
    -- The FIRST window is named "2"; the SECOND one has id 2. The two answers
    -- differ, which is the only way to tell the order of the two lookups apart.
    windows[1].name = "2"
    assertEqual(windows[2].id, 2)

    -- A number typed into chat arrives as a string, so the name is tried FIRST
    -- and the id second.
    assertTrue(M.Resolve("2") == windows[1], "a window named \"2\" wins its own name")
    assertTrue(M.Resolve(2) == windows[2], "a real number is still an id")
end)

-- ---------------------------------------------------------------------------
-- Create, rename, duplicate, delete
-- ---------------------------------------------------------------------------

test("Create appends a window with the shipped defaults and a live instance", function()
    local inst, M = loaded()
    assertEqual(M:Create("Raid"), true)

    local windows = inst.NS.Database.GetWindows()
    assertEqual(#windows, 2)
    assertEqual(windows[2].name, "Raid")
    assertEqual(#windows[2].columns, #inst.NS.Constants.DEFAULT_STAT_KEYS)
    assertTrue(M.Get("Raid") ~= nil, "and an instance stands behind it")
    assertEqual(M.Get("Raid").id, windows[2].id)
end)

test("Ids are monotonic and never reused", function()
    local inst, M = loaded()
    M:Create("A")
    local idA = M.Resolve("A").id
    M:Delete("A")
    M:Create("B")
    -- A reused id would let a new window inherit the settings panel's
    -- active-window pointer and every window-relative schema path aimed at it.
    assertFalse(M.Resolve("B").id == idA)
    assertTrue(inst.NS.db.profile.nextWindowId > idA)
end)

test("A duplicate name is disambiguated rather than refused", function()
    local _, M = loaded()
    M:Create("Raid")
    M:Create("Raid")
    M:Create("Raid")
    assertTrue(M.Resolve("Raid") ~= nil)
    assertTrue(M.Resolve("Raid 2") ~= nil)
    assertTrue(M.Resolve("Raid 3") ~= nil)
end)

test("Rename stores the new name and refuses an empty one", function()
    local inst, M = loaded()
    local cfg = inst.NS.Database.GetWindows()[1]

    assertEqual(M:Rename(cfg.id, "  Mythic+  "), true)
    assertEqual(cfg.name, "Mythic+", "trimmed, but otherwise exactly as typed")

    assertEqual(M:Rename(cfg.id, "   "), false)
    assertEqual(cfg.name, "Mythic+")
    assertEqual(M:Rename("no such window", "x"), false)
end)

test("Duplicate deep-copies the source and offsets the copy", function()
    local inst, M = loaded()
    local src = inst.NS.Database.GetWindows()[1]
    src.bars.colorMode  = "stat"
    src.frame.position  = { point = "CENTER", relativePoint = "CENTER", x = 10, y = 20 }
    src.columns = { { stat = "DamageDone", width = 90, showBar = true } }

    assertEqual(M:Duplicate(src.id), true)
    local copy = inst.NS.Database.GetWindows()[2]

    assertFalse(copy.id == src.id)
    assertFalse(copy.name == src.name)
    assertEqual(copy.bars.colorMode, "stat")
    -- A duplicate that lands exactly on top of its original looks like nothing
    -- happened.
    assertEqual(copy.frame.position.x, 34)
    assertEqual(copy.frame.position.y, -4)

    -- The aliasing check: mutate the source and watch the copy stay put.
    src.bars.colorMode = "role"
    src.columns[1].width = 999
    assertEqual(copy.bars.colorMode, "stat")
    assertEqual(copy.columns[1].width, 90)
end)

test("Delete removes the config, destroys the instance and repoints the picker", function()
    local inst, M = loaded()
    M:Create("Second")
    local first = inst.NS.Database.GetWindows()[1]
    inst.NS.State.SetActiveWindow(first.id)

    assertEqual(M:Delete(first.id), true)
    assertEqual(#inst.NS.Database.GetWindows(), 1)
    assertNil(M.Get(first.id))
    -- Leaving the picker pointed at a deleted id would make every row on every
    -- settings page read nil.
    assertFalse(inst.NS.State.activeWindowId == first.id)
end)

test("THE LAST WINDOW IS NOT DELETABLE", function()
    local inst, M = loaded()
    -- An addon whose entire user interface is its windows has nothing left to
    -- be, and no way back short of the settings panel the player just lost their
    -- handle on.
    local ok, err = M:Delete(inst.NS.Database.GetWindows()[1].id)
    assertEqual(ok, false)
    assertEqual(type(err), "string")
    assertEqual(#inst.NS.Database.GetWindows(), 1)
end)

test("An empty registry is re-seeded with a default", function()
    local inst = T.load{ enable = true }
    local windows = inst.NS.Database.GetWindows()
    for i = #windows, 1, -1 do windows[i] = nil end

    -- The safety net behind the refusal above: whenever the registry is found
    -- empty for any other reason, at least one window comes back.
    inst.NS.Database.SeedWindows()
    assertEqual(#inst.NS.Database.GetWindows(), 1)
    inst.NS.WindowManager:Init()
    assertEqual(#inst.NS.WindowManager.All(), 1)
end)

test("Delete answers false for a window that is not there", function()
    local _, M = loaded()
    assertEqual(M:Delete("no such window"), false)
end)

-- ---------------------------------------------------------------------------
-- WINDOWS_CHANGED — the sole sender
-- ---------------------------------------------------------------------------

test("Every registry mutation announces WINDOWS_CHANGED, and nothing else does", function()
    local inst, M = loaded()
    local heard = {}
    local bus = inst.NS.NewBusTarget()
    bus:RegisterMessage(inst.NS.Constants.MSG.WINDOWS_CHANGED,
        function(_, payload) heard[#heard + 1] = payload end)

    M:Create("Raid")
    assertEqual(heard[#heard].action, "created")

    M:Rename("Raid", "Raid2")
    assertEqual(heard[#heard].action, "renamed")

    M:Duplicate("Raid2")
    assertEqual(heard[#heard].action, "created")

    M:CopyFrom("Raid2", inst.NS.Database.GetWindows()[1].id)
    assertEqual(heard[#heard].action, "copied")

    M:Delete("Raid2")
    assertEqual(heard[#heard].action, "deleted")

    M:ResetPositions()
    assertEqual(heard[#heard].action, "reset")

    -- The registry changed SHAPE six times; a plain settings edit inside a
    -- window that already exists is CONFIG_CHANGED and must not appear here.
    assertEqual(#heard, 6)
end)

-- ---------------------------------------------------------------------------
-- CopyFrom
-- ---------------------------------------------------------------------------

--- Two windows, the source carrying a distinctive value in every copyable group.
local function twoWindows()
    local inst, M = loaded()
    M:Create("Target")
    local windows = inst.NS.Database.GetWindows()
    local source, target = windows[1], windows[2]

    source.name              = "Source"
    source.bars.colorMode    = "stat"
    source.rows.height       = 33
    source.text.numberFormat = "full"
    source.visibility.world  = true
    source.columns           = { { stat = "Deaths", width = 44, showBar = false } }
    source.frame.position    = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 5, y = -5 }
    target.frame.position    = { point = "CENTER", relativePoint = "CENTER", x = 99, y = 99 }

    return inst, M, source, target
end

test("CopyFrom with no filter copies every group, deeply", function()
    local inst, M, source, target = twoWindows()

    assertEqual(M:CopyFrom(source.id, target.id), true)
    assertEqual(target.bars.colorMode, "stat")
    assertEqual(target.rows.height, 33)
    assertEqual(target.text.numberFormat, "full")
    assertEqual(target.visibility.world, true)
    assertEqual(target.columns[1].stat, "Deaths")

    -- Identity is never copied, or the registry would end up with two windows
    -- claiming to be the same one.
    assertFalse(target.id == source.id)
    assertEqual(target.name, "Target")

    -- Where a window sits is not a setting: a copied `frame` group would drop
    -- the target exactly on top of the source.
    assertEqual(target.frame.position.x, 99)
    assertEqual(target.frame.position.y, 99)

    -- And the aliasing check, on every group that was copied.
    source.bars.colorMode  = "role"
    source.rows.height     = 1
    source.columns[1].width = 999
    assertEqual(target.bars.colorMode, "stat")
    assertEqual(target.rows.height, 33)
    assertEqual(target.columns[1].width, 44)
    assertFalse(target.bars == source.bars, "two windows must never share a sub-table")
    assertFalse(target.columns == source.columns)

    assertTrue(inst.NS.WindowManager.Get(target.id).config == target)
end)

test("CopyFrom with ONE group key copies only that group", function()
    local _, M, source, target = twoWindows()
    target.bars.colorMode = "class"
    target.rows.height    = 16

    -- The settings panel's dropdown hands over one bare key, because that is
    -- what its control holds.
    assertEqual(M:CopyFrom(source.id, target.id, "bars"), true)
    assertEqual(target.bars.colorMode, "stat")
    assertEqual(target.rows.height, 16, "everything else is left alone")

    source.bars.colorMode = "role"
    assertEqual(target.bars.colorMode, "stat", "and it is still a deep copy")
end)

test("CopyFrom accepts an array of keys and a set of them", function()
    local _, M, source, target = twoWindows()
    target.bars.colorMode = "class"
    target.rows.height    = 16
    target.text.numberFormat = "abbreviated"

    assertEqual(M:CopyFrom(source.id, target.id, { "bars", "rows" }), true)
    assertEqual(target.bars.colorMode, "stat")
    assertEqual(target.rows.height, 33)
    assertEqual(target.text.numberFormat, "abbreviated")

    assertEqual(M:CopyFrom(source.id, target.id, { text = true, icons = false }), true)
    assertEqual(target.text.numberFormat, "full")
end)

test("CopyFrom drops a group key this build does not know", function()
    local _, M, source, target = twoWindows()
    target.bars.colorMode = "class"

    -- Copying it blindly would put a group into the target that
    -- EnsureWindowShape has no template for and nothing ever reads.
    assertEqual(M:CopyFrom(source.id, target.id, { "somethingelse" }), true)
    assertEqual(target.bars.colorMode, "class", "nothing was copied")
    assertNil(target.somethingelse)
end)

test("CopyFrom refuses a missing source or target, and no-ops onto itself", function()
    local _, M, source = twoWindows()
    assertEqual(M:CopyFrom("nope", source.id), false)
    assertEqual(M:CopyFrom(source.id, "nope"), false)
    assertEqual(M:CopyFrom(source.id, source.id), true, "a self-copy is a no-op, not an error")
end)

test("CopyFrom re-normalizes the target's shape afterwards", function()
    local _, M, source, target = twoWindows()
    source.tooltip = nil            -- a source written by an older build
    assertEqual(M:CopyFrom(source.id, target.id), true)
    -- EnsureWindowShape fills what the copy could not supply, so the target is
    -- never left half-shaped.
    assertEqual(type(target.tooltip), "table")
    assertTrue(target.tooltip.maxSpells ~= nil)
end)

-- ---------------------------------------------------------------------------
-- Bulk operations
-- ---------------------------------------------------------------------------

test("ResetPosition and ResetPositions put windows back in the middle", function()
    local inst, M = loaded()
    M:Create("Second")
    local windows = inst.NS.Database.GetWindows()
    for _, cfg in ipairs(windows) do
        cfg.frame.position = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 40, y = -40 }
    end

    assertEqual(M:ResetPosition(windows[1].id), true)
    assertEqual(windows[1].frame.position.x, 0)
    assertEqual(windows[2].frame.position.x, 40, "one window, not all of them")

    assertEqual(M:ResetPositions(), 2)
    assertEqual(windows[2].frame.position.point, "CENTER")
    assertEqual(windows[2].frame.position.y, 0)
end)

test("ResetPosition defaults to the window the picker is pointed at", function()
    local inst, M = loaded()
    local cfg = inst.NS.Database.GetWindows()[1]
    cfg.frame.position = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 40, y = -40 }
    inst.NS.State.SetActiveWindow(cfg.id)

    assertEqual(M:ResetPosition(), true)
    assertEqual(cfg.frame.position.x, 0)
end)

test("SetLocked flips every window and touches NOTHING else", function()
    -- Locking governs dragging and resizing. It used to also switch test mode on,
    -- which made three controls each do two things: `/mm lock off` silently
    -- turned placeholder data on, and unchecking Test mode did nothing while any
    -- window was unlocked.
    -- red under: restoring the SetTestMode(not locked) call in SetLocked.
    local inst, M = loaded()
    M:Create("Second")

    M:SetLocked(false)
    for _, cfg in ipairs(inst.NS.Database.GetWindows()) do
        assertEqual(cfg.frame.locked, false)
    end
    assertEqual(inst.NS.State.testMode, false, "unlocking must not turn test data on")
    assertEqual(M:IsLocked(), false)

    inst.NS.State.SetTestMode(true)
    M:SetLocked(true)
    assertEqual(inst.NS.State.testMode, true, "and locking must not turn it off")
    assertEqual(M:IsLocked(), true)
end)

test("IsLocked is false the moment any one window is unlocked", function()
    local inst, M = loaded()
    M:Create("Second")
    M:SetLocked(true)
    inst.NS.Database.GetWindows()[2].frame.locked = false
    assertEqual(M:IsLocked(), false)
end)

test("SetTestMode routes through core/State.lua and marks every window dirty", function()
    local _, M = loaded()
    for _, w in ipairs(M.All()) do w.dirty = false end

    M:SetTestMode(true)
    assertEqual(M:IsTest(), true)
    for _, w in ipairs(M.All()) do
        assertEqual(w.dirty, true, "out of combat the next meter event may never come")
    end
    M:SetTestMode(false)
end)

test("Toggle with no name flips every window; with a name, one", function()
    local _, M = loaded()
    M:Create("Second")
    for _, w in ipairs(M.All()) do w:Show() end

    M:Toggle()
    for _, w in ipairs(M.All()) do assertEqual(w:IsShown(), false) end

    M:Toggle()
    for _, w in ipairs(M.All()) do assertEqual(w:IsShown(), true) end

    assertEqual(M:Toggle("Second"), true)
    assertEqual(M.Get("Second"):IsShown(), false)
    assertEqual(M.All()[1]:IsShown(), true, "the other window is untouched")

    local ok, err = M:Toggle("no such window")
    assertEqual(ok, false)
    assertEqual(type(err), "string")
end)

test("MarkAllDirty costs one flag each and nothing else", function()
    local inst, M = loaded()
    for _, w in ipairs(M.All()) do w.dirty = false end
    inst.mocks.resetMeterCalls()

    M:MarkAllDirty()
    for _, w in ipairs(M.All()) do assertEqual(w.dirty, true) end
    for name, count in pairs(inst.mocks.__meter.calls) do
        assertEqual(count, 0, "MarkAllDirty called " .. name .. "; the throttle decides the rest")
    end
end)

test("BuildListLines names every window and says whether it is on screen", function()
    local _, M = loaded()
    M:Create("Raid")
    local lines = M:BuildListLines()
    assertEqual(#lines, 2)
    assertTrue(lines[2]:find("Raid", 1, true) ~= nil)
    assertTrue(lines[2]:find("Columns", 1, true) ~= nil)
end)

-- ---------------------------------------------------------------------------
-- Perf suspend
-- ---------------------------------------------------------------------------

test("Suspend stops the coalescing timers without hiding anything", function()
    local _, M = loaded()
    M:Suspend()
    for _, w in ipairs(M.All()) do
        assertNil(w.frame:GetScript("OnUpdate"))
    end

    -- Hiding from here would fight modules/Visibility.lua, whose ladder already
    -- reads NS.Perf.suspended as step 0. What this takes away is the WORK.
    M:Resume()
    for _, w in ipairs(M.All()) do
        assertTrue(w.frame:GetScript("OnUpdate") ~= nil)
    end
end)

test("Resume restores from CURRENT state: a window made while suspended comes back", function()
    local _, M = loaded()
    M:Suspend()
    M:Create("Late")
    M:Resume()
    assertTrue(M.Get("Late") ~= nil)
    assertTrue(M.Get("Late").frame:GetScript("OnUpdate") ~= nil)
end)
