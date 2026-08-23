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

-- What LibKa0s draws its close button at, fixed by that library rather than by
-- this addon's `controlSize` (libs/LibKa0s/Core.lua). The strip has to know,
-- because a slot pitch that assumes every control is `controlSize` wide puts the
-- close button on top of its neighbour at any size below 14.
local EXTERNAL_SIZE = 18

-- Where our own art lives. Extensionless on purpose -- the client appends it,
-- and a path carrying `.tga` is one of the two spellings that silently draws
-- nothing.
local ART = "Interface\\AddOns\\MythicMeters\\media\\textures\\icons\\"

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
    -- NOT OURS TO BUILD. LibKa0s owns the close button and its degraded stub
    -- answers nil (core/CoreSetup.lua:163), so index 0 is genuinely ABSENT on a
    -- degraded install rather than merely hidden. Everything below tolerates a
    -- nil control for that reason, and a test drives the degraded case.
    { key = "close",    setting = "closeButton",   art = "close", external = true,
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

    -- THE EXTERNAL CONTROL IS NOT OUR SIZE AND MAY NOT EXIST. LibKa0s fixes the
    -- close button at 18x18 whatever `controlSize` says, and its degraded stub
    -- builds nothing at all -- so counting it as `size`, or counting it when it
    -- was never created, reserves room that does not match the strip. Both were
    -- real: at controlSize 10 the title ran under the X, and on a degraded
    -- install 22px of header was reserved for a button that is not there.
    local size, total, shown = controlSize(frameCfg), 0, 0
    local built = window.controls
    for i = 1, #CONTROLS do
        local control = CONTROLS[i]
        if enabled(frameCfg, control)
            and (not control.external or not built or built[control.key]) then
            total = total + (control.external and EXTERNAL_SIZE or size)
            shown = shown + 1
        end
    end
    if shown == 0 then return 0 end
    return total + (shown - 1) * GAP
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

    -- RUNG ONE: our own texture.
    if Compat and Compat.FirstTexture then
        local path = Compat.FirstTexture(button.tex, ART .. art)
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
        local show = _G.StaticPopup_Show
        if show then show("MYTHICMETERS_RESET_METER_DATA") end
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
        local button

        if control.external then
            -- LibKa0s builds it, or answers nil on a degraded install. Either is
            -- a legitimate outcome and neither is an error here.
            if NS.MakeCloseButton then
                button = NS.MakeCloseButton(frame, function() window:Hide("closed") end)
            end
            if button then
                window.controls[control.key] = button
            end
        else
            button = CreateFrame("Button", nil, frame)

        button.tex = button:CreateTexture(nil, "OVERLAY")
        button.tex:SetAllPoints(button)
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

    local y = -(layout.padding - 1)
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
                -- `used` accumulates the widths ACTUALLY placed, rather than
                -- multiplying an index by one assumed size: the close button is
                -- 18 whatever `controlSize` says, so an index-times-size step
                -- overlapped it with its neighbour below 14 and left a hole
                -- above 18.
                local width = control.external and EXTERNAL_SIZE or size
                local dx = -(layout.padding + used)
                button:ClearAllPoints()
                button:SetPoint("TOPRIGHT", window.frame, "TOPRIGHT", dx, y)
                if not control.external then button:SetSize(size, size) end
                used = used + width + GAP
                if level then button:SetFrameLevel(level) end
                -- The hit rect is grown past the art: 18px is a small target and
                -- the only thing behind these is a drag handle.
                if button.SetHitRectInsets then button:SetHitRectInsets(-3, -3, -3, -3) end

                -- AN EXTERNAL CONTROL KEEPS ITS OWN LOOK. LibKa0s builds the
                -- close button and draws it; it carries none of the `.tex` /
                -- `.glyph` pair the ladder writes into, so it is placed and
                -- sized here and nothing else. Reaching into another library's
                -- widget to restyle it is how a re-vendor silently reverts your
                -- art.
                if not control.external then
                    local art, dimmed, ascii = artFor(control, frameCfg)
                    drawIcon(button, control, art, style, dimmed, ascii)
                end
            end
        end
    end

    HeaderControls.ApplyHoverAlpha(window)
end

--- The font and colour every control draws with, resolved once per Apply.
---
--- Published so modules/Window.lua can hand over its own header font rather than
--- this file growing a second opinion about what the header looks like.
function HeaderControls.Style(window)
    local resolve = NS.HeaderStyle
    if resolve then return resolve(window) end
    return { path = nil, size = 12, flags = "", r = 1, g = 1, b = 1 }
end

-- ---------------------------------------------------------------------------
-- Hover reveal
-- ---------------------------------------------------------------------------
--
-- HOOKED TO THE STRIP, NOT TO THE BUTTONS. A per-button OnEnter/OnLeave fires a
-- leave every time the pointer crosses the gap between two of them, and the set
-- flickers. `dragBar` already spans the whole title strip and already has the
-- mouse, so one enter and one leave covers every control and costs nothing.

--- What alpha the strip should be at right now.
local function hoverAlpha(window)
    local frameCfg = (window.config or {}).frame or {}
    if frameCfg.hoverReveal == false then return 1 end
    return window.headerHovered and 1 or 0.25
end

--- Push the current alpha onto every control.
function HeaderControls.ApplyHoverAlpha(window)
    local controls = window.controls
    if not controls then return end
    local alpha = hoverAlpha(window)
    for i = 1, #CONTROLS do
        local button = controls[CONTROLS[i].key]
        if button then button:SetAlpha(alpha) end
    end
end

--- Wire the strip's hover. Called once, from Window:Build, after Attach.
function HeaderControls:HookHover(window)
    local bar = window.dragBar
    if not bar then return end

    -- THE CONTROLS THEMSELVES HAVE TO BE HOOKED TOO, and this is not belt and
    -- braces. They sit FIVE FRAME LEVELS ABOVE dragBar so they win the click --
    -- which also means the pointer reaching a control leaves dragBar, firing its
    -- OnLeave and fading the strip at the exact moment the player went for it.
    --
    -- Hooking both and treating hover as "the pointer is on the strip OR on one
    -- of its controls" is what makes the reveal survive its own frame ordering.
    for i = 1, #CONTROLS do
        local button = window.controls and window.controls[CONTROLS[i].key]
        if button and button.HookScript then
            button:HookScript("OnEnter", function()
                window.headerHovered = true
                HeaderControls.ApplyHoverAlpha(window)
            end)
            button:HookScript("OnLeave", function()
                window.headerHovered = bar.IsMouseOver and bar:IsMouseOver() or false
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
        w.headerHovered = true
        HeaderControls.ApplyHoverAlpha(w)
    end)

    bar[hook](bar, "OnLeave", function(frame)
        local w = frame.mmWindow
        if not w then return end
        w.headerHovered = false
        HeaderControls.ApplyHoverAlpha(w)
    end)
end
