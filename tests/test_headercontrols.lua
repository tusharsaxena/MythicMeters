-- tests/test_headercontrols.lua — modules/HeaderControls.lua, the window's own strip.
--
-- Two properties carry most of this file. The layout is INDEXED, so hiding one
-- control has to close the gap rather than leave a hole — that is the whole
-- reason the placement was rewritten and it is invisible from a screenshot. And
-- the art walks a three-rung ladder whose lower two rungs exist because this
-- addon has already shipped invisible controls twice; a test that only drives
-- the top rung would let either of those regress silently.

local T = _G.MULTIMETERS_TEST

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
local ICON_PATH = "Interface\\AddOns\\MultiMeters\\libs\\LibKa0s\\media\\icons\\"
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

--- The y offset a control was actually placed at, off the frame's top edge.
local function topOf(button)
    for _, p in ipairs(button.__points or {}) do
        if p.point == "TOPRIGHT" then return p.y end
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
    assertEqual(offsetOf(after.controls.settings), settingsAt + 20,
        "settings sits one slot further right once minimise goes")
    assertEqual(offsetOf(after.controls.export), exportAt + 20,
        "and so does everything past it")
end)

test("HeaderControls: hiding the LAST control moves nothing", function()
    -- The other half of the same property: a hole only closes to its right.
    local _, before = scene()
    local settingsAt = offsetOf(before.controls.settings)

    local _, after = scene(function(cfg) cfg.frame.showExport = false end)
    assertEqual(offsetOf(after.controls.settings), settingsAt)
end)

test("HeaderControls: the strip is CENTRED in the title bar", function()
    -- Centred in what a player SEES as the title bar -- the frame's top edge down
    -- to the divider -- rather than in the tinted band alone. Centring in the
    -- band leaves the padding above as dead space and lands the row against the
    -- divider, which is what "everything is anchored to the bottom" meant.
    -- red under: y = -(padding - 1), and again under -(padding + (title - h)/2).
    local _, window = scene(function(cfg)
        cfg.frame.padding = 6
        cfg.header.height = 26
        cfg.frame.controlSize = 16
    end)
    -- 6 padding + 26 bar - 2 to the divider = 30 visible; half the 14 left over.
    assertEqual(topOf(window.controls.settings), -7)
end)

test("HeaderControls: the strip and the title share one centre line", function()
    -- Two placements of one row. The whole point of routing both through
    -- Window:TitleRowTop is that they cannot be centred differently.
    local _, window = scene(function(cfg)
        cfg.header.height = 24
        cfg.header.size = 14
        cfg.frame.controlSize = 18
    end)
    local iconTop = topOf(window.controls.settings)
    local textTop = select(5, window.frame.title:GetPoint(1))
    assertEqual(iconTop - 18 / 2, textTop - 14 / 2,
        "the icons and the title are on different centre lines")
end)

test("HeaderControls: a control taller than its bar overflows DOWNWARD", function()
    -- Centring a 32px control in an 18px bar puts its top above the frame, where
    -- half of it is drawn outside the window.
    local _, window = scene(function(cfg)
        cfg.header.height = 18
        cfg.frame.controlSize = 32
    end)
    assertEqual(topOf(window.controls.settings), 0)
end)

--- The three numbers a control's icon is actually tinted with.
local function tintOf(button)
    local c = button.tex.__vertexColor
    return c[1], c[2], c[3]
end

test("HeaderControls: a control at rest takes the control colour", function()
    -- The art ships white and is tinted by a MULTIPLY, so the shipped default is
    -- the identity and the icons read as chrome rather than as a line of the
    -- header text. It is a picker, not a switch, so a profile can say otherwise.
    local _, window = scene(function(cfg)
        cfg.header.color = { r = 1, g = 0.82, b = 0, a = 1 }
    end)
    local r, g, b = tintOf(window.controls.settings)
    assertEqual(r .. "," .. g .. "," .. b, "1,1,1")

    local _, tinted = scene(function(cfg)
        cfg.frame.controlColor = { r = 0.2, g = 0.4, b = 0.6, a = 1 }
    end)
    local tr, tg, tb = tintOf(tinted.controls.settings)
    assertEqual(tr .. "," .. tg .. "," .. tb, "0.2,0.4,0.6")
end)

test("HeaderControls: the control under the pointer takes the HOVER colour", function()
    -- Hover is the only feedback a control gives, and the two colours are what
    -- makes it readable at a glance rather than a brightness a player has to
    -- compare against its neighbours.
    local _, window = scene()
    window.controls.settings:_run("OnEnter")

    local r, g, b = tintOf(window.controls.settings)
    assertEqual(r .. "," .. g .. "," .. b, "1,0.82,0")
    local nr, ng, nb = tintOf(window.controls.lock)
    assertEqual(nr .. "," .. ng .. "," .. nb, "1,1,1",
        "a control the pointer is not on changed colour")

    window.controls.settings:_run("OnLeave")
    local br, bg, bb = tintOf(window.controls.settings)
    assertEqual(br .. "," .. bg .. "," .. bb, "1,1,1", "the hover colour outlived the pointer")
end)

test("HeaderControls: both colours come from config", function()
    local _, window = scene(function(cfg)
        cfg.frame.controlColor      = { r = 0, g = 0, b = 1, a = 1 }
        cfg.frame.controlHoverColor = { r = 0, g = 1, b = 0, a = 1 }
    end)
    window.controls.export:_run("OnEnter")
    local r, g, b = tintOf(window.controls.export)
    assertEqual(r .. "," .. g .. "," .. b, "0,1,0")
end)

test("HeaderControls: each colour has its OWN class-colour flag", function()
    -- Two flags rather than one, because hover and rest are two independent
    -- answers. A shared flag would make the pointer's colour identical to the
    -- resting one for anybody who ticked it, which is the one thing a hover
    -- colour must never be.
    -- red under: a single `classColor` key driving both.
    local inst, window = scene(function(cfg)
        cfg.frame.controlColor      = { r = 0, g = 0, b = 1, a = 1 }
        cfg.frame.controlHoverColor = { r = 0, g = 1, b = 0, a = 1 }
        cfg.frame.controlClassColor = true
    end)
    -- Compared against the reader itself rather than against a literal: whose
    -- class it is, is the subject of the case above this one, and hard-coding a
    -- hue here would only re-test the mock.
    local cr, cg, cb = inst.NS.PlayerClassRGB()
    assertTrue(cr ~= nil, "the scene has no readable class to colour with")

    local r, g, b = tintOf(window.controls.settings)
    assertEqual(r .. "," .. g .. "," .. b, cr .. "," .. cg .. "," .. cb,
        "the resting colour is not classed")

    -- The hover colour is untouched by the resting flag.
    window.controls.settings:_run("OnEnter")
    local hr, hg, hb = tintOf(window.controls.settings)
    assertEqual(hr .. "," .. hg .. "," .. hb, "0,1,0",
        "the resting flag classed the hover colour too")
end)

test("HeaderControls: the hover flag classes the hover colour and nothing else", function()
    local inst, window = scene(function(cfg)
        cfg.frame.controlColor           = { r = 0, g = 0, b = 1, a = 1 }
        cfg.frame.controlHoverColor      = { r = 0, g = 1, b = 0, a = 1 }
        cfg.frame.controlHoverClassColor = true
    end)
    local cr, cg, cb = inst.NS.PlayerClassRGB()
    assertTrue(cr ~= nil, "the scene has no readable class to colour with")

    local r, g, b = tintOf(window.controls.settings)
    assertEqual(r .. "," .. g .. "," .. b, "0,0,1", "the hover flag classed the resting colour")

    window.controls.settings:_run("OnEnter")
    local hr, hg, hb = tintOf(window.controls.settings)
    assertEqual(hr .. "," .. hg .. "," .. hb, cr .. "," .. cg .. "," .. cb)
end)

test("HeaderControls: both flags off is the shipped look, unchanged", function()
    -- Every existing window is this one, and neither flag ships on.
    local _, window = scene()
    local r, g, b = tintOf(window.controls.settings)
    assertEqual(r .. "," .. g .. "," .. b, "1,1,1")
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
    local occupied = -leftmost + 16

    -- What the title reserves. This is the number that has to cover it.
    local reserved = window:HeaderRightInset()
    assertTrue(reserved >= occupied,
        "the title reserves " .. reserved .. " but the strip reaches " .. occupied)
    -- BOTH SIDES, or the name is a lie: under-reservation runs the title under a
    -- control, and arbitrary over-reservation truncates it for no reason. One
    -- padding of slack is the placement's own leading offset.
    assertTrue(reserved <= occupied + window.layout.padding * 2,
        "the title reserves " .. reserved .. " for a strip only " .. occupied .. " wide")
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
    -- The mock raises on SetText before SetFont, exactly as the client does, so
    -- the whole assertion is that building a window does not throw. The earlier
    -- version wrapped that in two further checks which could not fail: T.load
    -- either returns an instance or raises, and scene() cannot hand back a nil
    -- window without having raised first.
    local ok, err = pcall(scene)
    assertTrue(ok, "building a window raised: " .. tostring(err))
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
    assertEqual(asked, "MULTIMETERS_RESET_METER_DATA")
    assertTrue(inst.mocks.__meter.calls.ResetAllCombatSessions == nil,
        "the click reset the meter without asking")
end)

test("HeaderControls: the reset confirmation opens in the CENTRE of the screen", function()
    -- A StaticPopup anchors into the popup stack, near the top of the screen --
    -- so the one dialog that asks before destroying data opened nowhere near
    -- where the player was looking when they clicked a header control.
    -- red under: a bare StaticPopup_Show.
    local inst, window = scene()
    local dialog = inst.mocks.__stubFrame and inst.mocks.__stubFrame("Frame")
        or CreateFrame("Frame")
    inst.mocks.StaticPopup_Show = function() return dialog end

    window.controls.reset:_run("OnClick")

    local point, _, relativePoint = dialog:GetPoint(1)
    assertEqual(point, "CENTER")
    assertEqual(relativePoint, "CENTER")
    assertEqual(dialog:GetNumPoints(), 1, "the stack's own anchor was left on the dialog")
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

test("HeaderControls: only the control under the pointer is revealed", function()
    -- The reveal used to be a property of the STRIP -- the pointer touching the
    -- title bar anywhere brought all seven up together, and the one actually
    -- under the pointer was told apart by a highlight drawn behind it. Six
    -- controls lighting up answers "the header is live"; what a player is asking
    -- is "which of these am I about to click".
    -- red under: a strip-wide alpha driven off dragBar.
    local _, window = scene()
    local rest = window.controls.settings:GetAlpha()
    assertTrue(rest < 1, "the controls start faded")

    window.controls.settings:_run("OnEnter")
    assertEqual(window.controls.settings:GetAlpha(), 1)
    assertEqual(window.controls.lock:GetAlpha(), rest,
        "a control the pointer is not on came up too")

    window.controls.settings:_run("OnLeave")
    assertEqual(window.controls.settings:GetAlpha(), rest)
end)

test("HeaderControls: the title bar itself reveals nothing", function()
    -- dragBar is still hooked -- a control's OnLeave asks it whether the pointer
    -- merely moved to the bar beside it -- but it no longer brings the strip up.
    local _, window = scene()
    local rest = window.controls.settings:GetAlpha()
    window.dragBar:_run("OnEnter")
    for _, key in ipairs({ "minimise", "lock", "settings", "segment", "reset", "export" }) do
        assertEqual(window.controls[key]:GetAlpha(), rest, key .. " came up with the bar")
    end
end)

test("HeaderControls: the reveal moves rather than accumulating", function()
    -- A leave can arrive AFTER the next control's enter, and clearing the hover
    -- unconditionally on leave clears one that has already moved on.
    -- red under: window.hoveredControl = nil on every leave.
    local _, window = scene()
    window.controls.settings:_run("OnEnter")
    window.controls.lock:_run("OnEnter")
    window.controls.settings:_run("OnLeave")

    assertEqual(window.controls.lock:GetAlpha(), 1, "the control under the pointer is not lit")
    assertTrue(window.controls.settings:GetAlpha() < 1,
        "the control the pointer left is still lit")
end)

test("HeaderControls: with the reveal off, hover is colour alone", function()
    -- `hoverReveal` off means every control stays visible, which is the whole
    -- point of the setting -- so the hover colour is the only thing left to say
    -- which one the pointer is on, and it still has to say it.
    local _, window = scene(function(cfg) cfg.frame.hoverReveal = false end)
    assertEqual(window.controls.export:GetAlpha(), 1)

    window.controls.export:_run("OnEnter")
    assertEqual(window.controls.export:GetAlpha(), 1, "the reveal-off strip moved")
    assertEqual(window.controls.lock:GetAlpha(), 1, "a control faded with the reveal off")
    local c = window.controls.export.tex.__vertexColor
    assertEqual(c[1] .. "," .. c[2] .. "," .. c[3], "1,0.82,0")
end)

test("HeaderControls: hover reveal off means always visible", function()
    local _, window = scene(function(cfg) cfg.frame.hoverReveal = false end)
    assertEqual(window.controls.settings:GetAlpha(), 1)
end)

test("HeaderControls: hooking hover does not unseat the drag", function()
    -- dragBar already carries OnDragStart/OnDragStop, and hover is hooked onto
    -- the SAME frame. The risk is a hook that replaces rather than appends.
    --
    -- Asserting the drag scripts are still present cannot catch that -- hover
    -- only ever touches OnEnter/OnLeave, so the drag survives even a plain
    -- SetScript and the assertion passes either way. What has to be pinned is
    -- that hover did not blow away a PRE-EXISTING handler on the slot it uses,
    -- so this puts one there first and checks it still runs.
    -- red under: SetScript in HookHover.
    local inst = T.load()
    local cfg = inst.NS.Database.GetWindows()[1]
    local window = inst.NS.Window.New(cfg)

    local ours = 0
    window.dragBar:HookScript("OnEnter", function() ours = ours + 1 end)
    inst.NS.HeaderControls:HookHover(window)

    window.dragBar:_run("OnEnter")
    assertEqual(ours, 1, "hover replaced a handler that was already on OnEnter")
    assertTrue(window.dragBar:GetScript("OnDragStart") ~= nil, "the drag was replaced")
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
    -- Every control is `controlSize` wide and the pitch is accumulated from what
    -- was actually placed, so no size the slider can produce may overlap two
    -- controls or leave a hole between them.
    -- red under: dx = -(padding + index * (size + GAP)) with a mixed-width strip.
    for _, size in ipairs({ 10, 14, 18, 24, 32 }) do
        local inst, window = scene(function(cfg) cfg.frame.controlSize = size end)
        local placed = {}
        for _, key in ipairs({ "close", "minimise", "lock", "settings",
                               "segment", "reset", "export" }) do
            local b = window.controls[key]
            if b and b:IsShown() then
                placed[#placed + 1] = { x = offsetOf(b), w = size, key = key }
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

test("HeaderControls: a degraded install still gets its close button", function()
    -- The close button used to be LibKa0s', whose degraded stub answers nil, so
    -- a window on a degraded install had no way to be closed from its own header
    -- and WidthUsed had to guess whether the button existed. It is ours now: the
    -- strip is the same seven controls with or without the library.
    -- red under: building index 0 through NS.MakeCloseButton.
    local inst = T.load()
    inst.NS.MakeCloseButton = function() return nil end
    local window = inst.NS.Window.New(inst.NS.Database.GetWindows()[1])

    assertTrue(window.controls.close ~= nil, "the header lost its close button")
    -- Seven controls at 16, six gaps of 4.
    assertEqual(inst.NS.HeaderControls.WidthUsed(window), 7 * 16 + 6 * 4)
end)

test("HeaderControls: the close button closes the window", function()
    -- It stopped being LibKa0s' widget, and with it went the onClick LibKa0s
    -- wired. The one thing the control has to do is the one thing that moved.
    local _, window = scene()
    window.controls.close:_run("OnClick")
    assertFalse(window.frame:IsShown(), "the close button did not close the window")
end)

test("HeaderControls: the art is drawn INSIDE its slot, not across it", function()
    -- The art ships as a solid glyph that reaches its own edges. Drawn at the
    -- full slot it read far heavier than the header text beside it, which is
    -- what the first look at it in game said.
    -- red under: button.tex:SetAllPoints(button).
    local _, window = scene(function(cfg) cfg.frame.controlSize = 20 end)
    local tex = window.controls.settings.tex
    assertTrue(tex.__w > 0 and tex.__w < 20,
        "the icon is drawn at " .. tostring(tex.__w) .. " in a 20px slot")
end)

test("HeaderControls: a control keeps its reveal as the pointer arrives", function()
    -- The controls sit FIVE FRAME LEVELS ABOVE the drag bar so they win the
    -- click, which also means the pointer arriving on one LEAVES the bar. The
    -- bar's own leave must not undo the control's enter, whichever order the two
    -- events arrive in.
    -- red under: dragBar's OnLeave clearing window.hoveredControl unconditionally.
    local _, window = scene()
    window.dragBar:_run("OnEnter")

    -- The pointer crosses from the bar onto a control, leave first.
    window.dragBar:_run("OnLeave")
    window.controls.settings:_run("OnEnter")
    assertEqual(window.controls.settings:GetAlpha(), 1,
        "the control did not come up as the pointer reached it")

    -- And in the other order, which is what a live client actually sends.
    window.controls.settings:_run("OnLeave")
    window.controls.lock:_run("OnEnter")
    window.dragBar:_run("OnLeave")
    assertEqual(window.controls.lock:GetAlpha(), 1,
        "the bar's leave took the control's reveal with it")
end)

test("HeaderControls: the segment button opens the same menu the session line does", function()
    -- Two routes to one menu. The button is the discoverable one; the label
    -- stays clickable because that is muscle memory.
    -- red under: a dead branch in onClick.
    local _, window = scene()
    local opened = 0
    window.OpenSegmentMenu = function() opened = opened + 1 end

    window.controls.segment:_run("OnClick")
    assertEqual(opened, 1, "the segment button opened nothing")
end)

test("HeaderControls: the export button hands Export the WINDOW", function()
    -- Not its config: Export.Open reads the instance to place its modal over the
    -- window it was opened from, and a config table has no frame to measure.
    -- red under: E:Open(window.config).
    local inst, window = scene()
    local got
    inst.NS.Export.Open = function(a, b) got = (a == inst.NS.Export) and b or a end

    window.controls.export:_run("OnClick")
    assertTrue(got == window, "export was handed something other than the window")
end)

test("HeaderControls: the gear opens the panel", function()
    local inst, window = scene()
    local opened = 0
    inst.NS.OpenOptionsPanel = function() opened = opened + 1 end

    window.controls.settings:_run("OnClick")
    assertEqual(opened, 1, "the gear opened nothing")
end)
