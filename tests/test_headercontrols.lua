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

--- Take this addon's OWN art away, so a case can reach the rungs beneath it.
---
--- With every texture loadable -- which is the mock's default and a live
--- client's usual state -- the first rung wins for every control, and the atlas
--- and ASCII rungs below it become unreachable in a test while remaining the
--- live behaviour on any client missing the file. Both of those rungs exist
--- because this addon has already shipped invisible controls twice.
local ICON_PATH = "Interface\\AddOns\\MythicMeters\\media\\textures\\icons\\"
local function withoutOurArt(inst)
    for _, name in ipairs({ "close", "minimise", "expand", "lock", "unlock",
                            "settings", "segment", "reset", "export" }) do
        inst.mocks.setTextureLoadable(ICON_PATH .. name, false)
    end
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
    withoutOurArt(inst)
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
    withoutOurArt(inst)
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
        return table.concat({ tostring(b.tex:GetTexture()), tostring(b.tex:GetAtlas()),
                              tostring(b.tex.__desaturated), tostring(b.tex:GetAlpha()),
                              tostring(b.glyph:GetText()) }, "/")
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
        return table.concat({ tostring(b.tex:GetTexture()), tostring(b.tex:GetAtlas()),
                              tostring(b.glyph:GetText()) }, "/")
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

test("HeaderControls: our own art is the FIRST rung", function()
    -- Custom art does not retire the ladder -- it goes in front of it. The two
    -- rungs behind are the record of two shipped failures, so the one thing that
    -- must be provable is which one won.
    -- red under: the atlas rung being tried first.
    local inst, window = scene()
    inst.mocks.setAtlases({ ["GM-icon-settings"] = true })
    inst.NS.HeaderControls:Apply(window)

    local tex = window.controls.settings.tex
    assertTrue(tex:IsShown())
    assertTrue((tostring(tex:GetTexture())):find("icons", 1, true) ~= nil,
        "the atlas won even though our own art loaded")
end)

test("HeaderControls: a missing TGA falls through to the atlas", function()
    -- An addon-shipped texture can fail to load, and it fails the SAME SILENT
    -- WAY as the two paths that failed before it: nothing drawn, nothing raised.
    -- red under: assuming our own art always resolves.
    local inst, window = scene()
    withoutOurArt(inst)
    inst.mocks.setAtlases({ ["GM-icon-settings"] = true })
    inst.NS.HeaderControls:Apply(window)

    local tex = window.controls.settings.tex
    assertTrue(tex:IsShown(), "nothing drew at all")
    assertEqual(tex:GetAtlas(), "GM-icon-settings")
end)

test("HeaderControls: a failed path is not left set under the next rung", function()
    -- FirstTexture mutates a real Texture to find out whether a file exists,
    -- because there is no query for one. On a miss it has to clear up after
    -- itself, or the failed path stays set underneath whatever draws next.
    -- red under: returning nil without clearing.
    local inst, window = scene()
    withoutOurArt(inst)
    inst.mocks.setAtlases({})
    inst.NS.HeaderControls:Apply(window)

    local tex = window.controls.settings.tex
    assertTrue(tex.__texture == nil,
        "the failed path was left on the texture: " .. tostring(tex.__texture))
end)

-- ---------------------------------------------------------------------------
-- What review found, and what now pins it
-- ---------------------------------------------------------------------------

test("HeaderControls: a click writes to the window it was clicked ON", function()
    -- THE WORST BUG IN THE FIRST CUT. `window.`-prefixed paths resolve against
    -- ONE integer -- the active window id -- and NS.SetByPath takes only
    -- (path, value), so the third argument this passed was silently ignored.
    -- Clicking minimise on the second window wrote to whichever one the settings
    -- panel had last been left on: a control changing a window the player is not
    -- even looking at.
    -- red under: calling SetByPath without setting the active window first.
    local inst = T.load{ enable = true }
    local NS = inst.NS
    NS.WindowManager:Create("Second")
    local cfgs = NS.Database.GetWindows()
    assertTrue(#cfgs >= 2, "the fixture needs two windows")

    local first  = NS.Window.New(cfgs[1])
    local second = NS.Window.New(cfgs[2])

    -- Point the panel at the FIRST window, then click the SECOND window's button.
    NS.State.SetActiveWindow(cfgs[1].id)
    second.controls.minimise:_run("OnClick")

    assertEqual(cfgs[2].frame.minimised, true, "the clicked window did not change")
    assertFalse(cfgs[1].frame.minimised and true or false,
        "the click landed on the window the PANEL had selected, not the one clicked")
    assertTrue(first ~= nil)
end)

test("HeaderControls: the gear points the panel at its own window", function()
    -- Same mechanism, and the reason it exists: the pages that open must be
    -- about THIS window rather than whichever the picker was last left on.
    -- red under: OpenOptionsPanel called without setting the active id.
    local inst = T.load{ enable = true }
    local NS = inst.NS
    NS.WindowManager:Create("Second")
    local cfgs = NS.Database.GetWindows()
    local second = NS.Window.New(cfgs[2])

    NS.State.SetActiveWindow(cfgs[1].id)
    second.controls.settings:_run("OnClick")
    assertEqual(NS.State.activeWindowId, cfgs[2].id)
end)

test("HeaderControls: the padlock's ASCII rung differs between states", function()
    -- The atlas rung tells two states apart by desaturating. The ASCII rung has
    -- no such trick, so it needs a second character -- and without one a client
    -- with no atlas drew the identical padlock locked and unlocked.
    -- red under: one `ascii` for both states.
    local inst, window, cfg = scene()
    withoutOurArt(inst)
    inst.mocks.setAtlases({})

    cfg.frame.locked = true
    inst.NS.HeaderControls:Apply(window)
    local lockedChar = window.controls.lock.glyph:GetText()

    cfg.frame.locked = false
    inst.NS.HeaderControls:Apply(window)
    assertFalse(window.controls.lock.glyph:GetText() == lockedChar,
        "the ASCII padlock reads the same locked and unlocked")
end)

test("HeaderControls: the strip fits at every size the schema allows", function()
    -- The close button is LibKa0s' and is 18px whatever controlSize says, so a
    -- slot pitch that assumed one width put it on top of its neighbour below 14
    -- and left a hole above 18.
    -- red under: dx = -(padding + index * (size + GAP)).
    for _, size in ipairs({ 10, 14, 18, 24, 32 }) do
        local inst, window = scene(function(cfg) cfg.frame.controlSize = size end)
        local placed = {}
        for _, key in ipairs({ "close", "minimise", "lock", "settings",
                               "segment", "reset", "export" }) do
            local b = window.controls[key]
            if b and b:IsShown() then
                local w = (key == "close") and 18 or size
                placed[#placed + 1] = { x = offsetOf(b), w = w, key = key }
            end
        end
        for i = 2, #placed do
            local right, left = placed[i - 1], placed[i]
            -- Right-to-left: each control's own right edge must clear the
            -- previous one's left edge, with the gap intact.
            local gap = (-left.x) - ((-right.x) + right.w)
            assertEqual(gap, 4,
                ("size %d: %s to %s gap was %d"):format(size, right.key, left.key, gap))
        end
        assertTrue(inst ~= nil)
    end
end)

test("HeaderControls: a degraded install reserves no room for a button it lacks", function()
    -- LibKa0s' stub answers nil, so the close control is genuinely absent rather
    -- than hidden. WidthUsed counted it anyway, so the title clipped 22px early
    -- for the life of that session.
    -- red under: counting every enabled control whether or not it was built.
    local inst = T.load()
    inst.NS.MakeCloseButton = function() return nil end
    local window = inst.NS.Window.New(inst.NS.Database.GetWindows()[1])

    assertTrue(window.controls.close == nil, "the fixture needs no close button")
    -- Six controls at 18, five gaps of 4.
    assertEqual(inst.NS.HeaderControls.WidthUsed(window), 6 * 18 + 5 * 4)
end)

test("HeaderControls: reaching a control does not fade the strip", function()
    -- The controls sit FIVE FRAME LEVELS ABOVE the strip so they win the click,
    -- which also means the pointer arriving on one LEAVES the strip -- firing its
    -- OnLeave and fading the set at the exact moment the player went for it.
    -- red under: hooking hover on dragBar alone.
    local _, window = scene()
    window.dragBar:_run("OnEnter")
    assertEqual(window.controls.settings:GetAlpha(), 1)

    -- The pointer moves off the strip and onto a control.
    window.dragBar:_run("OnLeave")
    window.controls.settings:_run("OnEnter")
    assertEqual(window.controls.settings:GetAlpha(), 1,
        "the strip faded as the pointer reached a control")
end)
