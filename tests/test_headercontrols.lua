-- tests/test_headercontrols.lua — modules/HeaderControls.lua, the window's own strip.
--
-- Two properties carry most of this file. The layout is INDEXED, so hiding one
-- control has to close the gap rather than leave a hole — that is the whole
-- reason the placement was rewritten and it is invisible from a screenshot. And
-- the art walks a three-rung ladder whose lower two rungs exist because this
-- addon has already shipped invisible controls twice; a test that only drives
-- the top rung would let either of those regress silently.

local T = _G.MYTHICMETERS_TEST

local test        = T.test
local assertEqual = T.assertEqual
local assertTrue  = T.assertTrue
local assertFalse = T.assertFalse

local CURRENT = 1
local ALPHA = "Player-1-0000000A"

--- A window with its controls attached.
local function scene(configure)
    local inst = T.load()
    local NS, mocks = inst.NS, inst.mocks

    mocks.setSession(CURRENT, "*", {
        combatSources = { { sourceGUID = ALPHA, name = "Alpha", totalAmount = 100 } },
        maxAmount = 100, totalAmount = 100,
    })

    local cfg = NS.Database.GetWindows()[1]
    cfg.data.sessionType = CURRENT
    cfg.visibility = { dungeon = true, raid = true, arena = true,
                       battleground = true, world = true,
                       hideWhenSolo = false, hideInVehicle = false }
    if configure then configure(cfg) end

    local window = NS.Window.New(cfg)
    window:RefreshVisibility()
    return inst, window, cfg
end

--- The x offset a control was actually placed at, off the frame's right edge.
---
--- Read off the RECORDED point rather than off a getter: the mock's
--- GetLeft/GetRight answer a constant 0 for every frame, so a placement case
--- written against those would pass whatever the code did.
local function offsetOf(button)
    for _, p in ipairs(button.__points or {}) do
        if p.point == "TOPRIGHT" then return p.x end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- The registry
-- ---------------------------------------------------------------------------

test("HeaderControls: every control this addon builds is attached", function()
    local _, window = scene()
    for _, key in ipairs({ "minimise", "lock", "settings", "segment", "reset", "export" }) do
        assertTrue(window.controls[key] ~= nil, "missing control: " .. key)
        assertTrue(window.controls[key]:GetScript("OnClick") ~= nil,
            key .. " has no click")
    end
end)

test("HeaderControls: a control turned off is not placed at all", function()
    local _, window = scene(function(cfg) cfg.frame.showLock = false end)
    assertEqual(window.controls.lock:IsShown(), false)
end)

-- ---------------------------------------------------------------------------
-- The indexed layout
-- ---------------------------------------------------------------------------

test("HeaderControls: a hidden control YIELDS its slot", function()
    -- THE POINT OF THE REWRITE. The old placement was hand-computed offsets off a
    -- `dx` that its own comment admitted was not an accumulator, so turning one
    -- control off left a hole. Everything past the hidden one must move left by
    -- exactly one step, and everything before it must not move at all.
    -- red under: placing from a fixed per-control offset.
    local _, before = scene()
    local settingsAt = offsetOf(before.controls.settings)
    local exportAt   = offsetOf(before.controls.export)

    local _, after = scene(function(cfg) cfg.frame.showMinimise = false end)
    assertEqual(offsetOf(after.controls.settings), settingsAt + 22,
        "settings sits one slot further right once minimise goes")
    assertEqual(offsetOf(after.controls.export), exportAt + 22,
        "and so does everything past it")
end)

test("HeaderControls: hiding the LAST control moves nothing", function()
    -- The other half of the same property: a hole only closes to its right.
    local _, before = scene()
    local settingsAt = offsetOf(before.controls.settings)

    local _, after = scene(function(cfg) cfg.frame.showExport = false end)
    assertEqual(offsetOf(after.controls.settings), settingsAt)
end)

test("HeaderControls: control size comes from config", function()
    local _, window = scene(function(cfg) cfg.frame.controlSize = 24 end)
    assertEqual(window.controls.settings.__w, 24)
end)

test("HeaderControls: the width reserved equals the width occupied", function()
    -- These are two different computations of one number -- what the title
    -- reserves on its right, and where the leftmost control actually lands -- and
    -- if they are ever derived differently a title runs underneath a button.
    local inst, window = scene()

    local leftmost = 0
    for _, key in ipairs({ "minimise", "lock", "settings", "segment", "reset", "export" }) do
        local x = offsetOf(window.controls[key])
        if x and x < leftmost then leftmost = x end
    end
    -- How far in from the frame's right edge the strip actually reaches: the
    -- leftmost control's offset plus its own width.
    local occupied = -leftmost + 18

    -- What the title reserves. This is the number that has to cover it.
    local reserved = window:HeaderRightInset()
    assertTrue(reserved >= occupied,
        "the title reserves " .. reserved .. " but the strip reaches " .. occupied)
end)

test("HeaderControls: no title bar means no strip and no reservation", function()
    local inst, window = scene(function(cfg) cfg.frame.titleBar = false end)
    assertEqual(inst.NS.HeaderControls.WidthUsed(window), 0)
    assertEqual(window.controls.settings:IsShown(), false)
end)

-- ---------------------------------------------------------------------------
-- The art ladder
-- ---------------------------------------------------------------------------

test("HeaderControls: with no atlas the ASCII rung draws", function()
    -- The bottom rung, and it exists because Unicode glyphs shipped once and
    -- rendered as replacement boxes. It must never be unreachable.
    local inst, window = scene()
    inst.mocks.setAtlases({})
    inst.NS.HeaderControls:Apply(window)

    assertFalse(window.controls.settings.tex:IsShown(), "no atlas resolved")
    assertTrue(window.controls.settings.glyph:IsShown(), "so the ASCII rung draws")
    assertTrue((window.controls.settings.glyph:GetText() or ""):match("^%w") ~= nil
        or window.controls.settings.glyph:GetText() == "*",
        "and it is an ASCII character, not a glyph the font may lack")
end)

test("HeaderControls: an atlas beats the ASCII rung", function()
    local inst, window = scene()
    inst.mocks.setAtlases({ ["GM-icon-settings"] = true })
    inst.NS.HeaderControls:Apply(window)

    assertTrue(window.controls.settings.tex:IsShown(), "the atlas wins where it exists")
    assertFalse(window.controls.settings.glyph:IsShown())
end)

test("HeaderControls: the padlock's two states do not draw the same", function()
    -- One asset, two states. If they render identically the control stops being
    -- a state indicator, which is the only reason it is an icon rather than a
    -- word.
    local inst, window, cfg = scene()
    local function art()
        local b = window.controls.lock
        return table.concat({ tostring(b.tex:GetAtlas()), tostring(b.tex.__desaturated),
                              tostring(b.tex:GetAlpha()), tostring(b.glyph:GetText()) }, "/")
    end

    cfg.frame.locked = true
    inst.NS.HeaderControls:Apply(window)
    local locked = art()

    cfg.frame.locked = false
    inst.NS.HeaderControls:Apply(window)
    assertFalse(art() == locked, "an open padlock and a closed one must differ")
end)

test("HeaderControls: minimise shows the opposite of the state it is in", function()
    local inst, window, cfg = scene()
    local function art()
        local b = window.controls.minimise
        return tostring(b.tex:GetAtlas()) .. "/" .. tostring(b.glyph:GetText())
    end

    cfg.frame.minimised = false
    inst.NS.HeaderControls:Apply(window)
    local expanded = art()

    cfg.frame.minimised = true
    inst.NS.HeaderControls:Apply(window)
    assertFalse(art() == expanded, "collapsed and expanded must not look the same")
end)

test("HeaderControls: a glyph is never given text before a font", function()
    -- This took the whole addon down once, before a single window existed:
    -- SetText on a FontString with no font raises. Attach must set no text.
    local inst = T.load()
    local raised = false
    local ok = pcall(function()
        local _, window = scene()
        raised = window == nil
    end)
    assertTrue(ok, "building a window raised")
    assertFalse(raised)
    assertTrue(inst ~= nil)
end)

-- ---------------------------------------------------------------------------
-- Clicks
-- ---------------------------------------------------------------------------

test("HeaderControls: reset asks before it wipes anything", function()
    -- The dialog reaches OUTSIDE this addon -- it clears the data Blizzard's own
    -- meter is showing -- so the button must open it and reset nothing itself.
    -- red under: calling Provider.Reset from the click.
    local inst, window = scene()
    local asked
    inst.mocks.StaticPopup_Show = function(key) asked = key end
    inst.mocks.resetMeterCalls()

    window.controls.reset:_run("OnClick")
    assertEqual(asked, "MYTHICMETERS_RESET_METER_DATA")
    assertTrue(inst.mocks.__meter.calls.ResetAllCombatSessions == nil,
        "the click reset the meter without asking")
end)

test("HeaderControls: minimise writes through the settings seam", function()
    -- Not by poking the config table: NS.SetByPath is what publishes
    -- CONFIG_CHANGED, and it is what the panel's own checkbox writes through, so
    -- a direct poke leaves the panel and the window disagreeing.
    -- red under: `frameCfg.minimised = not frameCfg.minimised`.
    local inst, window, cfg = scene()
    assertFalse(cfg.frame.minimised and true or false)

    window.controls.minimise:_run("OnClick")
    assertEqual(cfg.frame.minimised, true)

    window.controls.minimise:_run("OnClick")
    assertEqual(cfg.frame.minimised, false)
end)

test("HeaderControls: the lock button toggles this window only", function()
    local inst, window, cfg = scene()
    local before = cfg.frame.locked and true or false
    window.controls.lock:_run("OnClick")
    assertFalse((cfg.frame.locked and true or false) == before)
end)

-- ---------------------------------------------------------------------------
-- Hover reveal
-- ---------------------------------------------------------------------------

test("HeaderControls: the strip fades until the pointer is on the title bar", function()
    local inst, window = scene()
    local dim = window.controls.settings:GetAlpha()
    assertTrue(dim < 1, "the controls start faded")

    window.dragBar:_run("OnEnter")
    assertEqual(window.controls.settings:GetAlpha(), 1)

    window.dragBar:_run("OnLeave")
    assertEqual(window.controls.settings:GetAlpha(), dim)
end)

test("HeaderControls: one hover moves the WHOLE strip", function()
    -- Hooked to the strip rather than per button, because a per-button hover
    -- fires a leave every time the pointer crosses the gap between two of them
    -- and the set flickers.
    local _, window = scene()
    window.dragBar:_run("OnEnter")
    for _, key in ipairs({ "minimise", "lock", "settings", "segment", "reset", "export" }) do
        assertEqual(window.controls[key]:GetAlpha(), 1, key .. " did not follow the strip")
    end
end)

test("HeaderControls: hover reveal off means always visible", function()
    local _, window = scene(function(cfg) cfg.frame.hoverReveal = false end)
    assertEqual(window.controls.settings:GetAlpha(), 1)
end)

test("HeaderControls: hooking hover does not unseat the drag", function()
    -- dragBar already carries OnDragStart/OnDragStop. GetScript answers only the
    -- first handler while HookScript appends, so assigning would silently take
    -- the window's dragging away with nothing to say why.
    local _, window = scene()
    assertTrue(window.dragBar:GetScript("OnDragStart") ~= nil, "the drag was replaced")
    assertTrue(window.dragBar:GetScript("OnDragStop") ~= nil)
end)

test("HeaderControls: a locked window can still reveal its controls", function()
    -- ApplyLock used to disable dragBar's mouse, and a mouse-disabled frame
    -- fires no OnEnter -- so the reveal was dead in the one case a player most
    -- wants it. Locking is gated by the empty RegisterForDrag, not by the mouse.
    -- red under: dragBar:EnableMouse(not locked).
    local _, window = scene(function(cfg) cfg.frame.locked = true end)
    assertEqual(window.dragBar.__mouseEnabled, true,
        "a locked window's title bar took no mouse, so it cannot hover")
end)
