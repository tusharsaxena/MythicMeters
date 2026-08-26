-- modules/HeaderControls.lua
--
-- Every control a window has, in one strip along the top of it.
--
-- ---------------------------------------------------------------------------
-- WHY THIS IS ITS OWN FILE
-- ---------------------------------------------------------------------------
--
-- The controls used to live in modules/Window.lua, which is the largest file in
-- this addon. Issue #6 adds two more of them, an indexed layout and a hover
-- reveal -- three hundred lines into the one file least able to take them.
--
-- The boundary is clean because a control only ever touches three things: the
-- frame it anchors to, the header's font and colour, and the window's own
-- config. It never touches a cell, a bar or a row. So the seam is three calls,
-- and modules/Window.lua keeps its own geometry:
--
--   Window:Build()        -> HeaderControls:Attach(window)
--   Window:ApplyHeader()  -> HeaderControls:Apply(window)
--   Window:HeaderRightInset() -> HeaderControls.WidthUsed(window) + padding
--
-- `HeaderRightInset` deliberately STAYS on Window. It is the seam the title and
-- the session line already depend on, and moving it would touch two things this
-- change has no business touching. It simply stops counting buttons by hand.
--
-- ---------------------------------------------------------------------------
-- WHY THIS FILE MAY MEASURE, WHEN ALMOST NOTHING ELSE HERE MAY
-- ---------------------------------------------------------------------------
--
-- Rule R3: a frame handed a secret value has SECRET GEOMETRY, so layout is
-- computed from config and never read back off a frame. That rule is what makes
-- modules/Row.lua free of a single GetWidth.
--
-- These buttons never hold a meter value. They are config-driven from first
-- principles -- a size, a gap, an index -- so the header is one of the few
-- places in this addon where geometry is legal at all. It is still not read
-- back: `WidthUsed` is computed from the same constants the placement uses, so
-- the number the title reserves and the number the buttons occupy cannot drift.
-- Nothing here calls GetWidth, GetLeft or GetPoint, and a test enforces it.
--
-- ---------------------------------------------------------------------------
-- WHY THE ART LADDER HAS THREE RUNGS
-- ---------------------------------------------------------------------------
--
-- core/Compat.lua records two previous failures at this exact spot and BOTH
-- WERE SILENT. First these controls were drawn from texture paths that do not
-- exist -- a texture that fails to load draws nothing and raises nothing, so
-- the control was simply invisible. Then they were redrawn as Unicode glyphs
-- (the padlock, the gear), which are not in the game's default font and came
-- out as replacement boxes.
--
--   our TGA  ->  Blizzard atlas  ->  ASCII character
--
-- An addon-shipped texture can fail to load too, and it fails the same silent
-- way, so shipping our own art does not retire the ladder -- it becomes the
-- first rung of it. Do not delete the rungs behind it as dead code. They are
-- the record of what has already gone wrong twice.
--
-- TOC POSITION: after modules/Window.lua, which owns the frames these attach to.

local addonName, NS = ...

local HeaderControls = {}
NS.HeaderControls = HeaderControls

-- ---------------------------------------------------------------------------
-- Geometry
-- ---------------------------------------------------------------------------

-- The gap between two controls. One number rather than the hand-matched 2px and
-- 4px seams the previous placement carried, which is what an index-based layout
-- buys: spacing is derived, so it cannot drift per button.
local GAP = 4

-- How much of a control's slot the art actually fills. The slot is the click
-- target and the layout pitch; the icon is drawn centred inside it.
--
-- WHY THE TWO ARE NOT THE SAME NUMBER. The art ships as a solid 64px glyph that
-- reaches its own edges, so an icon drawn at the full slot has no breathing room
-- and reads a great deal heavier than the header text beside it -- which was the
-- first thing anyone said about it in game. A font glyph in an 18px button is
-- about this fraction of it, which is why LibKa0s' close never looked oversized
-- at the same size ours did. Insetting the art rather than shrinking the slot
-- keeps `controlSize` meaning what the schema says it means, keeps the click
-- target where a player's cursor expects it, and fixes the look for a profile
-- that already stored a size.
local ART_SCALE = 0.72

-- WHERE THE ART LIVES IS NOT THIS FILE'S BUSINESS ANY MORE. The 49 icons moved
-- into the LibKa0s payload (v1.9.0, `LibKa0s-Media-1.0`) so that every Ka0s addon
-- draws the same marks from one set of bytes, and core/MediaSetup.lua is the seam
-- that knows this addon's own folder name -- which is the one thing a vendored
-- library cannot work out for itself.
--
-- `NS.Icon` answers nil twice over: no library, or no such icon. Both mean the
-- same thing here, and the ladder below already knows what to do with it.

-- ---------------------------------------------------------------------------
-- The controls
-- ---------------------------------------------------------------------------
--
-- ORDER IS THE LAYOUT. Index 0 sits hard against the frame's right edge and
-- every one after it steps left by one slot, so this table read top to bottom is
-- the strip read right to left.
--
-- `setting` is the config key under `window.frame` that shows or hides it.
-- `closeButton` is the odd one out and deliberately so: it predates the others
-- and renaming it to `showClose` for symmetry would migrate every stored profile
-- in exchange for a consistency nobody can see.
--
-- `art` / `atlas` / `ascii` are the three rungs. `state` marks a control whose
-- icon IS its state, resolved per draw rather than at attach.
local CONTROLS = {
    -- OURS, AND IT DID NOT USE TO BE. This was LibKa0s' close button for as long
    -- as the window has had one, which meant one control in the strip ignored
    -- our art, ignored `controlSize` and drew a font-string multiplication sign
    -- while its six neighbours drew shipped icons -- visibly the odd one out the
    -- moment the other six became art. It is a plain control now, on the same
    -- three-rung ladder as the rest. LibKa0s still closes the Export modal
    -- (modules/Export.lua); this is about a strip that has to look like a set.
    { key = "close",    setting = "closeButton",   art = "close",
      atlas = { "common-icon-redx" },           ascii = "X" },
    -- TWO STATES, TWO CHARACTERS. The atlas rung distinguishes a two-state icon
    -- by desaturating it, but the ASCII rung has no such trick -- so a control
    -- whose icon IS its state needs a second character or the bottom rung draws
    -- the same thing both ways and the control stops meaning anything.
    { key = "minimise", setting = "showMinimise",  art = "minimise", state = true,
      atlas = { "common-icon-forwardarrow" },   ascii = "-", asciiAlt = "+" },
    -- Two characters, for the reason minimise has two: the atlas rung tells the
    -- states apart by desaturating, and the ASCII rung has no such trick.
    { key = "lock",     setting = "showLock",      art = "lock",     state = true,
      atlas = { "Garr_LockedBuilding" },        ascii = "#", asciiAlt = "-" },
    { key = "settings", setting = "showSettings",  art = "settings",
      atlas = { "GM-icon-settings", "common-icon-settings" }, ascii = "*" },
    { key = "segment",  setting = "showSegment",   art = "segment",
      atlas = { "communities-icon-chat" },      ascii = "=" },
    { key = "reset",    setting = "showReset",     art = "reset",
      atlas = { "common-icon-undo" },           ascii = "@" },
    { key = "export",   setting = "showExport",    art = "export",
      atlas = { "poi-scrollofresonance", "UI-HUD-MicroMenu-Questlog-Up" }, ascii = ">" },
}

--- Whether a control is switched on for this window.
---
--- Defaults to SHOWN for everything, so a profile stored before these settings
--- existed gets the whole strip rather than an empty header.
local function enabled(frameCfg, control)
    return frameCfg[control.setting] ~= false
end

--- A configured colour as three numbers, defaulted.
---
--- Through `NS.RGBA` (LibKa0s' reader) because this collection persists colours
--- in BOTH a keyed and a positional shape and neither can be retired without
--- migrating everyone's SavedVariables. The hand-rolled branch under it is the
--- degraded install, where the library is not there to ask.
local function color(stored, dr, dg, db)
    local RGBA = NS.RGBA
    if RGBA then
        local r, g, b = RGBA(stored, dr, dg, db, 1)
        return r, g, b
    end
    if type(stored) == "table" then
        return stored.r or stored[1] or dr, stored.g or stored[2] or dg,
               stored.b or stored[3] or db
    end
    return dr, dg, db
end

--- The size one control is drawn at, from config.
local function controlSize(frameCfg)
    local size = frameCfg.controlSize
    if type(size) ~= "number" or size < 8 then return 18 end
    return size
end

--- How much horizontal room the strip occupies, in pixels.
---
--- COMPUTED, NEVER MEASURED. modules/Window.lua reserves exactly this much on
--- the right of the title and the session line, and if the two numbers were
--- arrived at differently they would eventually disagree and a title would run
--- underneath a button.
---
--- @param window table
--- @return number
function HeaderControls.WidthUsed(window)
    local frameCfg = (window.config or {}).frame or {}
    if frameCfg.titleBar == false then return 0 end

    -- COUNTED, NOT ASSUMED BUILT. Every control in the strip is now ours and
    -- every one is `controlSize` wide, so the reservation is one multiplication
    -- -- but it still counts only what `window.controls` actually holds when the
    -- window has been built, because a strip that reserves room for a button
    -- that is not there clips the title by that much for the life of a session.
    local size, shown = controlSize(frameCfg), 0
    local built = window.controls
    for i = 1, #CONTROLS do
        local control = CONTROLS[i]
        if enabled(frameCfg, control) and (not built or built[control.key]) then
            shown = shown + 1
        end
    end
    if shown == 0 then return 0 end
    return shown * size + (shown - 1) * GAP
end

-- ---------------------------------------------------------------------------
-- Art
-- ---------------------------------------------------------------------------

--- Draw one control's icon, walking the ladder until something takes.
---
--- @param button table    the control's frame
--- @param control table   its CONTROLS row
--- @param art string      which art name to use (a stateful control picks)
--- @param style table     { path, size, flags, r, g, b }
--- @param dimmed boolean  the "off" half of a two-state icon
local function drawIcon(button, control, art, style, dimmed, ascii)
    local Compat = NS.Compat

    -- RUNG ONE: the library's texture, which is this collection's own art.
    local shipped = NS.Icon and NS.Icon(art)
    if shipped and Compat and Compat.FirstTexture then
        local path = Compat.FirstTexture(button.tex, shipped)
        if path then
            -- Tinted rather than recoloured: the art ships WHITE precisely so a
            -- multiply lands on whatever the header's text colour is, and the
            -- icons obey the same setting the rest of the header does.
            button.tex:SetVertexColor(style.r, style.g, style.b)
            button.tex:SetAlpha(dimmed and 0.45 or 1)
            button.tex:Show()
            button.glyph:Hide()
            return "art"
        end
    end

    -- RUNG TWO: whatever atlas this client happens to carry.
    local atlas = Compat and Compat.FirstAtlas and Compat.FirstAtlas(control.atlas)
    if atlas then
        button.tex:SetAtlas(atlas)
        if button.tex.SetDesaturated then
            button.tex:SetDesaturated(dimmed and true or false)
        end
        button.tex:SetVertexColor(1, 1, 1)
        button.tex:SetAlpha(dimmed and 0.45 or 1)
        button.tex:Show()
        button.glyph:Hide()
        return "atlas"
    end

    -- RUNG THREE: a character every font has.
    button.glyph:SetFont(style.path, style.size, style.flags)
    button.glyph:SetTextColor(style.r, style.g, style.b)
    button.glyph:SetText(ascii or control.ascii)
    button.glyph:SetAlpha(dimmed and 0.45 or 1)
    button.glyph:Show()
    button.tex:Hide()
    return "ascii"
end

--- Which art and which state a control is in right now.
---
--- The two stateful controls draw their opposite when engaged, because the icon
--- IS the answer to the question a player is asking when they look at it: a
--- closed padlock means "this cannot be dragged", and a plus means "this will
--- open back up".
local function artFor(control, frameCfg)
    if control.key == "lock" then
        local locked = frameCfg.locked and true or false
        return locked and "lock" or "unlock", not locked,
               (locked and control.ascii or control.asciiAlt)
    end
    if control.key == "minimise" then
        local down = frameCfg.minimised and true or false
        return (down and "expand" or "minimise"), false,
               (down and control.asciiAlt or control.ascii)
    end
    return control.art, false, control.ascii
end

-- ---------------------------------------------------------------------------
-- Clicks
-- ---------------------------------------------------------------------------

--- Write one `window.frame.*` key through the settings seam.
---
--- `window.<key>` rather than `windows[n].frame.<key>`: NS.SetByPath resolves a
--- `window.` prefix against whichever window the panel has selected, and the
--- window a control was clicked on is by definition the one in front of the
--- player. Resolved at CALL time because settings/ loads ahead of modules/.
local function write(window, key, value)
    local set = NS.SetByPath
    if not set then return end

    -- POINT THE SEAM AT THIS WINDOW FIRST. `window.`-prefixed paths resolve
    -- against ONE integer -- the active window id -- and NS.SetByPath takes only
    -- (path, value): a third argument is silently ignored. Without this line a
    -- click on window 2's minimise wrote to whichever window the settings panel
    -- was last left on, which is a control doing something to a window the
    -- player is not looking at.
    --
    -- This is the same mechanism the gear has always used to make the panel open
    -- on the window whose gear was clicked.
    if window.id and NS.State and NS.State.SetActiveWindow then
        NS.State.SetActiveWindow(window.id)
    end
    set("window.frame." .. key, value)
end

local function onClick(frame)
    local window = frame.mmWindow
    local control = frame.mmControl
    if not (window and control) then return end
    local frameCfg = window.config.frame or {}

    if control == "close" then
        window:Hide("closed")
    elseif control == "minimise" then
        -- THROUGH THE WRITE SEAM, never by poking the config table. NS.SetByPath
        -- is what publishes CONFIG_CHANGED, and it is what the settings panel's
        -- own checkbox writes through -- so a button that wrote directly would
        -- leave the panel showing the opposite of what the window is doing until
        -- something else happened to refresh it.
        write(window, "minimised", not (frameCfg.minimised and true or false))
    elseif control == "lock" then
        write(window, "locked", not (frameCfg.locked and true or false))
    elseif control == "settings" then
        -- Point the panel at the window whose gear was clicked, so the pages
        -- that open are about THIS window rather than whichever one the picker
        -- was last left on. OpenOptionsPanel takes no arguments; the active id
        -- is how it is told which window it is about.
        if window.id and NS.State and NS.State.SetActiveWindow then
            NS.State.SetActiveWindow(window.id)
        end
        if NS.OpenOptionsPanel then NS.OpenOptionsPanel() end
    elseif control == "segment" then
        if window.OpenSegmentMenu then window:OpenSegmentMenu() end
    elseif control == "reset" then
        -- THE DIALOG ALREADY EXISTS, in settings/Data.lua, and it carries the
        -- warning that actually matters: this reset reaches OUTSIDE the addon
        -- and wipes what Blizzard's own meter is showing, not just ours. A
        -- second copy of that sentence is a second place for it to go stale,
        -- and the more dangerous the warning the worse that is.
        -- Through settings/Data.lua, which owns the dialog and centres it on
        -- the screen. Resolved at call time because settings/ loads ahead of
        -- modules/; the bare StaticPopup_Show behind it is the degraded path,
        -- where an uncentred confirmation still beats no confirmation.
        if NS.ShowResetMeterData then
            NS.ShowResetMeterData()
        else
            local show = _G.StaticPopup_Show
            if show then show("MULTIMETERS_RESET_METER_DATA") end
        end
    elseif control == "export" then
        -- The WINDOW, not its config: Export.Open reads the instance to centre
        -- its modal on the window it was opened from.
        local E = NS.Export
        if E and E.Open then E:Open(window) end
    end
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

--- Create every control on a window. Called once, from Window:Build.
function HeaderControls:Attach(window)
    local frame = window.frame
    if not frame then return end

    window.controls = {}
    for i = 1, #CONTROLS do
        local control = CONTROLS[i]
        local button = CreateFrame("Button", nil, frame)

        -- CENTRED, NOT SetAllPoints. The art is inset inside its slot (ART_SCALE)
        -- and the size that inset produces is only known at layout time, so the
        -- texture is anchored once here and sized in Apply.
        button.tex = button:CreateTexture(nil, "OVERLAY")
        button.tex:SetPoint("CENTER")
        button.tex:Hide()

        button.glyph = button:CreateFontString(nil, "OVERLAY")
        button.glyph:SetAllPoints(button)
        button.glyph:SetJustifyH("CENTER")

        button.mmWindow = window
        button.mmControl = control.key
        button:SetScript("OnClick", onClick)

        window.controls[control.key] = button
    end
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

--- Place, draw and show every control. Called from Window:ApplyHeader.
function HeaderControls:Apply(window)
    local controls = window.controls
    if not controls then return end

    local cfg      = window.config
    local frameCfg = cfg.frame or {}
    local layout   = window.layout
    local size     = controlSize(frameCfg)
    local visible  = (frameCfg.titleBar ~= false)

    local style = HeaderControls.Style(window)

    -- ABOVE THE DRAG BAR, EXPLICITLY. `dragBar` is an invisible mouse-enabled
    -- frame spanning the whole title strip -- exactly the band these sit in --
    -- and two siblings at one frame level compete for a click. The symptom of
    -- getting this wrong is a button that works sometimes, or only on part of
    -- itself.
    local level = window.dragBar and (window.dragBar:GetFrameLevel() + 5) or nil

    -- ONE CENTRE FOR THE WHOLE TITLE ROW. modules/Window.lua owns it, because the
    -- title and the session line are placed against the same number: the strip
    -- used to be pinned a pixel under the frame padding, which put it 3px below
    -- the text beside it and read as the icons hanging off the bottom of the bar.
    local y = window.TitleRowTop and window:TitleRowTop(size) or -(layout.padding - 1)
    local used = 0

    for i = 1, #CONTROLS do
        local control = CONTROLS[i]
        local button = controls[control.key]
        local on = enabled(frameCfg, control)

        if button then
            button:SetShown(visible and on)

            if visible and on then
                -- A HIDDEN CONTROL YIELDS ITS INDEX. `slot` counts what is
                -- actually drawn, so turning one off closes the gap rather than
                -- leaving a hole, and the controls past it move by exactly one
                -- step. That is the whole reason the placement is indexed.
                -- `used` accumulates the widths ACTUALLY placed rather than
                -- multiplying an index by one assumed size. Every control is the
                -- same width today, and this stays an accumulator anyway: it is
                -- the shape that survived a control that was not, and it costs
                -- one addition.
                local dx = -(layout.padding + used)
                button:ClearAllPoints()
                button:SetPoint("TOPRIGHT", window.frame, "TOPRIGHT", dx, y)
                button:SetSize(size, size)
                -- The art, inset inside the slot. Floored rather than rounded so
                -- a texture can never come out a pixel wider than the box it is
                -- centred in.
                local art = math.floor(size * ART_SCALE)
                button.tex:SetSize(art, art)
                used = used + size + GAP
                if level then button:SetFrameLevel(level) end
                -- The hit rect is grown past the art: 18px is a small target and
                -- the only thing behind these is a drag handle.
                if button.SetHitRectInsets then button:SetHitRectInsets(-3, -3, -3, -3) end

                local icon, dimmed, ascii = artFor(control, frameCfg)
                -- WHICH RUNG TOOK, remembered: the hover highlight recolours a
                -- control without redrawing it, and what may be recoloured
                -- depends on whether it is our white art, a finished atlas icon
                -- or a character.
                button.mmRung = drawIcon(button, control, icon, style, dimmed, ascii)
            end
        end
    end

    HeaderControls.ApplyHoverAlpha(window)
end

--- One control's colour, at rest or under the pointer.
---
--- TWO COLOURS AND TWO CLASS-COLOUR FLAGS, because they are two independent
--- answers: a player who wants their class colour under the pointer does not
--- necessarily want the whole strip in it at rest, and one shared flag would make
--- hover and rest the same colour for anyone who ticked it -- which is the one
--- thing a hover colour must never be.
---
--- The LOCAL player's class, like every other header surface: the strip is about
--- the window rather than about any row in it, so yours is the only class it can
--- sensibly mean (modules/Window.lua's headerColor says the same thing about the
--- title and the session line). A player whose class cannot be read keeps the
--- configured colour, which is the honest answer rather than a fallback hue.
---
--- @param frameCfg table
--- @param hovered boolean
--- @return number r, number g, number b
local function controlColor(frameCfg, hovered)
    local r, g, b
    if hovered then
        r, g, b = color(frameCfg.controlHoverColor, 1, 0.82, 0)
    else
        r, g, b = color(frameCfg.controlColor, 1, 1, 1)
    end

    -- Spelled out rather than `hovered and A or B`: that idiom answers B whenever
    -- A is false, so a window with the RESTING flag on and the hover flag off
    -- would take the resting flag's answer while hovered — the two flags
    -- collapsing back into the one this exists not to be.
    local classed
    if hovered then
        classed = frameCfg.controlHoverClassColor
    else
        classed = frameCfg.controlClassColor
    end

    if classed and NS.PlayerClassRGB then
        local cr, cg, cb = NS.PlayerClassRGB()
        if cr then r, g, b = cr, cg, cb end
    end

    return r, g, b
end

--- The font and colour every control draws with, resolved once per Apply.
---
--- Published so modules/Window.lua can hand over its own header font rather than
--- this file growing a second opinion about what the header looks like.
function HeaderControls.Style(window)
    local resolve = NS.HeaderStyle
    local style = resolve and resolve(window)
        or { path = nil, size = 12, flags = "", r = 1, g = 1, b = 1 }

    -- THE FONT IS THE HEADER'S, THE COLOUR IS THE STRIP'S OWN. The ASCII rung is
    -- text and has no business being on a different face from the title, but the
    -- controls are chrome rather than a line of the header: they carry two
    -- colours, one at rest and one under the pointer, and neither is the colour
    -- the header text is drawn in.
    local frameCfg = (window.config or {}).frame or {}
    style.r, style.g, style.b = controlColor(frameCfg, false)
    return style
end

-- ---------------------------------------------------------------------------
-- Hover
-- ---------------------------------------------------------------------------
--
-- ONE CONTROL AT A TIME. The reveal used to be a property of the STRIP: the
-- pointer touching the title bar anywhere brought all seven controls up
-- together, and the control actually under the pointer was told apart by a
-- highlight drawn behind it. That is two pieces of feedback answering one
-- question, and the loud one answered it wrong -- six controls lighting up says
-- "the header is live", when what a player wants to know is "which of these am I
-- about to click".
--
-- So the reveal IS the feedback now, and it is per control: the one under the
-- pointer comes up to full alpha and takes the hover colour, and the other six
-- stay exactly as they were. There is no highlight behind it, because a control
-- that is the only bright thing in the strip needs nothing behind it to be
-- found.
--
-- THE HOOKS STAY ON BOTH. `dragBar` no longer drives the alpha, but it is still
-- hooked: a control sits five frame levels above it, so leaving a control for
-- the bar and leaving the header entirely are different events and only the
-- second one clears the hover.

--- What alpha a control that is NOT under the pointer sits at.
local function restAlpha(window)
    local frameCfg = (window.config or {}).frame or {}
    if frameCfg.hoverReveal == false then return 1 end
    return 0.25
end

--- Colour one control for its current hover state.
---
--- WHICHEVER REGION DREW IT. Our art and an atlas icon are both textures and
--- take a vertex multiply; the ASCII rung is text and takes a text colour. The
--- rung is remembered at draw time (`button.mmRung`) so a hover can recolour a
--- control without walking the ladder again -- a hover fires far more often than
--- a config change, and re-resolving a texture path on every pointer move is
--- work nobody asked for.
local function applyTint(button, control, window, frameCfg)
    local hovered = (window.hoveredControl == control.key)
    local _, dimmed = artFor(control, frameCfg)

    local r, g, b = controlColor(frameCfg, hovered)

    -- The "off" half of a two-state icon stays dimmed against its own state,
    -- and the pointer still lifts it clear so a click target is never faint.
    local alpha = (hovered or not dimmed) and 1 or 0.45
    if button.mmRung == "ascii" then
        button.glyph:SetTextColor(r, g, b)
        button.glyph:SetAlpha(alpha)
    else
        button.tex:SetVertexColor(r, g, b)
        button.tex:SetAlpha(alpha)
    end
end

--- Push the current hover state onto every control.
---
--- Named for the reveal because that is what it started as, and kept that way
--- because modules/Window.lua calls it by this name on every header refresh.
function HeaderControls.ApplyHoverAlpha(window)
    local controls = window.controls
    if not controls then return end
    local rest     = restAlpha(window)
    local frameCfg = (window.config or {}).frame or {}
    for i = 1, #CONTROLS do
        local control = CONTROLS[i]
        local button = controls[control.key]
        if button then
            button:SetAlpha((window.hoveredControl == control.key) and 1 or rest)
            if button.mmRung then applyTint(button, control, window, frameCfg) end
        end
    end
end

--- Wire the strip's hover. Called once, from Window:Build, after Attach.
function HeaderControls:HookHover(window)
    local bar = window.dragBar
    if not bar then return end

    -- THE CONTROLS CARRY THE REVEAL. Each one knows only itself: its enter names
    -- it as the hovered control and its leave un-names it, and nothing else in
    -- the strip moves either way. dragBar is hooked below only to record whether
    -- the pointer is still on the header at all.
    for i = 1, #CONTROLS do
        local button = window.controls and window.controls[CONTROLS[i].key]
        if button and button.HookScript then
            local key = CONTROLS[i].key
            button:HookScript("OnEnter", function()
                window.headerHovered = true
                window.hoveredControl = key
                HeaderControls.ApplyHoverAlpha(window)
            end)
            button:HookScript("OnLeave", function()
                window.headerHovered = bar.IsMouseOver and bar:IsMouseOver() or false
                -- ONLY IF IT IS STILL OURS. Frames leave in no guaranteed order,
                -- so a leave arriving after the next control's enter would clear
                -- a reveal that has already moved on.
                if window.hoveredControl == key then window.hoveredControl = nil end
                HeaderControls.ApplyHoverAlpha(window)
            end)
        end
    end

    -- HOOKSCRIPT, NOT SETSCRIPT. `dragBar` already carries OnDragStart and
    -- OnDragStop; GetScript answers only the FIRST handler while HookScript
    -- appends, so assigning here would silently replace the drag wiring and the
    -- window would stop being draggable with nothing to say why.
    local hook = bar.HookScript and "HookScript" or "SetScript"

    bar[hook](bar, "OnEnter", function(frame)
        local w = frame.mmWindow
        if not w then return end
        -- Recorded, not acted on: the pointer being on the bar is what a
        -- control's OnLeave asks about to tell "moved to the bar beside it" from
        -- "left the header". It no longer reveals anything by itself.
        w.headerHovered = true
    end)

    bar[hook](bar, "OnLeave", function(frame)
        local w = frame.mmWindow
        if not w then return end
        w.headerHovered = false
        -- THE HOVER IS NOT CLEARED HERE. A control sits five frame levels above
        -- the bar, so the pointer crossing from the bar onto a control fires this
        -- leave -- and on a live client it can arrive AFTER that control's enter.
        -- Clearing here took the reveal straight back off the control the player
        -- had just reached. Each control clears its own on its own leave, which
        -- is the only event that actually means "the pointer is off it".
        HeaderControls.ApplyHoverAlpha(w)
    end)
end
