-- tests/test_minimap.lua — modules/Minimap.lua: the LibDataBroker launcher and
-- the button that fronts it.
--
-- The setting for this button already existed everywhere except here — the
-- profile ships `minimap = { hide = false }`, the schema offers the row, the TOC
-- vendors both libraries — so the failure this file closes was a checkbox that
-- toggled a value nothing read. The cases below therefore care about the loop
-- being closed (a broker object under the addon's own name, registered with
-- LibDBIcon against the LIVE profile table) and about every library reach being
-- optional, because both libraries are OptionalDeps and a stripped build must
-- lose the button and nothing else.

local T = _G.MYTHICMETERS_TEST

local test        = T.test
local assertEqual = T.assertEqual
local assertTrue  = T.assertTrue
local assertNil   = T.assertNil

local ADDON = "MythicMeters"

local function ldb(inst)  return inst.mocks.__libs["LibDataBroker-1.1"] end
local function icon(inst) return inst.mocks.__libs["LibDBIcon-1.0"] end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

test("Minimap.Init creates a launcher and registers it against the live profile", function()
    local inst = T.load()
    assertEqual(inst.NS.Minimap.Init(), true)

    local broker = ldb(inst).__objects[ADDON]
    assertTrue(broker ~= nil, "the object is named for the addon folder")
    -- "launcher" is the LDB type for an object whose value is a click rather
    -- than a number; a display addon uses it to decide it has a button and not a
    -- readout to render.
    assertEqual(broker.type, "launcher")
    assertEqual(type(broker.OnClick), "function")
    assertEqual(type(broker.OnTooltipShow), "function")
    assertTrue(broker.icon ~= nil)

    local registration = icon(inst).objects[ADDON]
    assertTrue(registration ~= nil)
    assertTrue(registration.broker == broker)
    -- LibDBIcon treats the table it is handed as its own and WRITES the button's
    -- position into it, so it has to be the live profile's table — registering
    -- before AceDB built the profile would hand it one that is thrown away.
    assertTrue(registration.db == inst.NS.db.profile.minimap)
end)

test("The launcher's name matches what the settings row looks it up by", function()
    local inst = T.load()
    inst.NS.Minimap.Init()
    -- settings/Schema.lua's refresh row resolves the registration by `addonName`.
    -- The two must agree, and the folder name is the one string neither can typo.
    assertTrue(ldb(inst):GetDataObjectByName(ADDON) ~= nil)
end)

test("Minimap.Init is idempotent", function()
    local inst = T.load()
    assertEqual(inst.NS.Minimap.Init(), true)
    local broker = ldb(inst).__objects[ADDON]

    -- LibDBIcon answers a duplicate name with a hard error, and a /reload is not
    -- the only way this path runs twice.
    assertEqual(inst.NS.Minimap.Init(), true)
    assertTrue(ldb(inst).__objects[ADDON] == broker)
end)

test("Minimap.Init adopts a broker object another path already created", function()
    local inst = T.load()
    local existing = ldb(inst):NewDataObject(ADDON, { type = "launcher", label = "prior" })

    assertEqual(inst.NS.Minimap.Init(), true)
    assertTrue(icon(inst).objects[ADDON].broker == existing,
        "the registry is checked first rather than blindly re-registered")
end)

-- ---------------------------------------------------------------------------
-- Degradation
-- ---------------------------------------------------------------------------

test("Init answers false, quietly, when LibDataBroker is absent", function()
    local inst = T.load{ mutate = function(mocks)
        mocks.__libs["LibDataBroker-1.1"] = nil
    end }
    -- The failure mode of a missing broker library is a meter with no minimap
    -- icon, never a Lua error during OnInitialize that takes the options panel
    -- and the slash commands down with it.
    assertEqual(inst.NS.Minimap.Init(), false)
end)

test("Init answers false when LibDBIcon is absent", function()
    local inst = T.load{ mutate = function(mocks)
        mocks.__libs["LibDBIcon-1.0"] = nil
    end }
    assertEqual(inst.NS.Minimap.Init(), false)
    assertNil(ldb(inst).__objects[ADDON], "and nothing half-registered is left behind")
end)

test("Init answers false before the database exists", function()
    local inst = T.load{ initDB = false, options = false }
    -- Called out of order, this must refuse rather than register against a
    -- profile table that does not exist yet.
    assertEqual(inst.NS.Minimap.Init(), false)
end)

test("Refresh before Init is a quiet no-op", function()
    local inst = T.load()
    inst.NS.Minimap.Refresh()
    assertNil(icon(inst).__refreshes, "\"the player hid the button\" is not \"there is no button\"")
end)

test("Refresh re-reads minimap.hide off the live profile", function()
    local inst = T.load()
    inst.NS.Minimap.Init()

    inst.NS.db.profile.minimap.hide = true
    inst.NS.Minimap.Refresh()
    assertEqual(icon(inst).__refreshes, 1)
    assertTrue(icon(inst).objects[ADDON].db == inst.NS.db.profile.minimap)
end)

-- ---------------------------------------------------------------------------
-- Click behavior
-- ---------------------------------------------------------------------------

test("Left-click toggles the windows through WindowManager's own seam", function()
    local inst = T.load{ enable = true }
    inst.NS.Minimap.Init()

    local toggles = 0
    inst.NS.WindowManager.Toggle = function() toggles = toggles + 1 end

    ldb(inst).__objects[ADDON].OnClick(nil, "LeftButton")
    assertEqual(toggles, 1)
end)

test("Right-click opens the settings through OpenOptionsPanel, not a private path", function()
    local inst = T.load{ enable = true }
    inst.NS.Minimap.Init()

    local opens, toggles = 0, 0
    inst.NS.OpenOptionsPanel = function() opens = opens + 1 end
    inst.NS.WindowManager.Toggle = function() toggles = toggles + 1 end

    ldb(inst).__objects[ADDON].OnClick(nil, "RightButton")
    -- OpenOptionsPanel carries the combat refusal — the options canvas is a
    -- protected frame — and a private path from this button would be the one way
    -- to reach the panel without that guard.
    assertEqual(opens, 1)
    assertEqual(toggles, 0, "and a right-click does not also toggle")
end)

test("A click on a build with no window manager does nothing rather than raising", function()
    local inst = T.load()
    inst.NS.Minimap.Init()
    local saved = inst.NS.WindowManager
    inst.NS.WindowManager = nil
    inst.NS.GetModule = nil

    local ok = pcall(ldb(inst).__objects[ADDON].OnClick, nil, "LeftButton")
    inst.NS.WindowManager = saved
    assertTrue(ok)
end)

-- ---------------------------------------------------------------------------
-- The tooltip
-- ---------------------------------------------------------------------------

test("The tooltip states BOTH clicks and the version", function()
    local inst = T.load()
    inst.NS.Minimap.Init()

    local lines = {}
    local tt = {
        AddLine = function(_, text) lines[#lines + 1] = text end,
        AddDoubleLine = function(_, left, right) lines[#lines + 1] = left .. " " .. right end,
    }
    ldb(inst).__objects[ADDON].OnTooltipShow(tt)

    local text = table.concat(lines, "\n")
    assertTrue(text:find("Left%-click") ~= nil)
    -- The right-click is stated rather than left to be discovered.
    assertTrue(text:find("Right%-click") ~= nil)
    assertTrue(text:find(tostring(inst.NS.version), 1, true) ~= nil)
end)

test("The tooltip callback never shows or clears the tooltip itself", function()
    local inst = T.load()
    inst.NS.Minimap.Init()

    -- LibDataBroker hands the object already anchored and cleared. Calling
    -- Show() here is the classic way to get a tooltip that will not go away when
    -- the cursor leaves the button.
    local called = {}
    local tt = setmetatable({}, { __index = function(_, key)
        return function() called[key] = true end
    end })
    tt.AddLine = function() end
    tt.AddDoubleLine = function() end

    ldb(inst).__objects[ADDON].OnTooltipShow(tt)
    assertNil(called.Show)
    assertNil(called.ClearLines)
    assertNil(called.SetOwner)
end)

test("The tooltip callback tolerates an object it cannot write to", function()
    local inst = T.load()
    inst.NS.Minimap.Init()
    local ok = pcall(ldb(inst).__objects[ADDON].OnTooltipShow, {})
    assertTrue(ok, "a display addon with a minimal tooltip object must not break the hover")
    assertTrue(pcall(ldb(inst).__objects[ADDON].OnTooltipShow, nil))
end)

-- ---------------------------------------------------------------------------
-- The setting it exists to make real
-- ---------------------------------------------------------------------------

test("The profile ships the one key LibDBIcon reads, and nothing else", function()
    local minimap = T.NS.defaults.profile.minimap
    assertEqual(minimap.hide, false)
    -- LibDBIcon owns the shape of this table and writes `minimapPos` into it as
    -- the player drags the button. The addon must never enumerate it or
    -- normalize keys out of it, or a dragged button snaps back on the next
    -- login.
    local keys = 0
    for _ in pairs(minimap) do keys = keys + 1 end
    assertEqual(keys, 1)
end)

test("modules/Minimap.lua passes the silent flag to every LibStub call", function()
    -- Both libraries are OptionalDeps. A non-silent LibStub call on a stripped
    -- build raises inside OnInitialize.
    local fh = assert(io.open(T.root .. "/modules/Minimap.lua", "r"))
    local n, offenders = 0, {}
    for line in fh:lines() do
        n = n + 1
        if not line:match("^%s*%-%-") then
            local code = line:gsub("%s%-%-.*$", "")
            if code:find("LibStub%(") and not code:find("true%)") then
                offenders[#offenders + 1] = "modules/Minimap.lua:" .. n
            end
        end
    end
    fh:close()
    assertEqual(#offenders, 0, table.concat(offenders, ", "))
end)
