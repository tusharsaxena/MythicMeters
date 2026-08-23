-- core/LSMPatch.lua
--
-- One piece of LibSharedMedia housekeeping that belongs to the addon rather than
-- to any one module: fixing up a third-party widget that renders LSM choices
-- badly inside our settings panel.
--
-- It lives in core/ (addon code) and not in libs/, so a future refresh of the
-- vendored libraries cannot blow it away.
--
-- ---------------------------------------------------------------------------
-- WHAT USED TO BE HERE, AND WHERE IT WENT
-- ---------------------------------------------------------------------------
--
-- This file also registered the monospace font this addon shipped. Both the font
-- and the registration moved to core/MediaSetup.lua when the face itself moved
-- into the LibKa0s payload (v1.9.0, `LibKa0s-Media-1.0`): the library owns the
-- bytes, so the library's own `RegisterLSM` is what names them — one key, one
-- path, agreed across every Ka0s addon rather than registered per addon from a
-- per-addon copy. Nothing about WHY it is registered at file load changed; that
-- reasoning is in MediaSetup now, beside the call.

-- The namespace is not needed here any more -- the font registration that used it moved to
-- core/MediaSetup.lua -- but the vararg header stays, because every file in this addon has one and
-- a file that silently differs is a file somebody has to read to find out why.
local _ = ...

-- No bar textures are REGISTERED anywhere. The addon still ships one —
-- media/textures/Default.tga, 256x32 RGBA, the shape a statusbar wants — but it
-- is not in the registry and nothing reads it yet, so the bars still use LSM
-- statusbar textures the player already has, defaulting to a Blizzard one that
-- exists on every install.
--
-- The two costs that kept it out are both smaller now that LibKa0s ships media:
-- the license question is answered the way the icons answered it (a notice
-- beside the bytes), and the collision-proof registry key is what
-- `LibKa0s-Media-1.0` already provides for fonts. If the texture is ever
-- registered it should go the same way the font went — into the library, under
-- one key for the whole collection — rather than being registered here. Until
-- then the file ships unused, which costs 971 bytes and no behavior. See
-- issue #4.

-- ---------------------------------------------------------------------------
-- AceGUI-3.0-SharedMediaWidgets: the LSM30_Border display tile
-- ---------------------------------------------------------------------------
--
-- Upstream AceGUI-3.0-SharedMediaWidgets' LSM30_Border widget pins a 42x42
-- displayButton border-preview tile to the widget's TOPLEFT (see
-- AGSMW:GetBaseFrameWithWindow in libs/AceGUI-3.0-SharedMediaWidgets/
-- prototypes.lua). Inside our canvas-layout settings panel that tile leaves a
-- 42px gap to the right of the closed dropdown's left edge, and the control
-- reads as misaligned beside the sliders and checkboxes stacked with it.
--
-- After PLAYER_LOGIN — by which point every addon's libs have run and the
-- LSM30_Border registry slot is stable — wrap whatever constructor AceGUI
-- currently holds, register the wrapper at currentVersion + 1 to win the version
-- race, and per-instance hide the displayButton plus re-anchor frame.label and
-- frame.DLeft to the frame's left edge so the empty 42px slot collapses. The
-- popup's per-row hover preview (upstream's ContentOnEnter swaps the popup
-- backdrop's edgeFile to the hovered border) is unaffected.
--
-- LSM30_Font and LSM30_Statusbar use AGSMW:GetBaseFrame, which has no
-- displayButton, so this fixup is Border-specific — which matters here because
-- this addon's settings surface is mostly fonts and statusbars, and only the
-- window/bar border rows reach the broken widget.

local hookFrame = CreateFrame("Frame")
hookFrame:RegisterEvent("PLAYER_LOGIN")
hookFrame:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()

    local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
    if not AceGUI then return end

    local registry = AceGUI.WidgetRegistry
    local current = registry and registry["LSM30_Border"]
    if not current then return end

    local currentVer = AceGUI:GetWidgetVersion("LSM30_Border") or 1

    AceGUI:RegisterWidgetType("LSM30_Border", function()
        local widget = current()
        local f = widget and widget.frame
        if f and f.displayButton then
            f.displayButton:Hide()
            if f.label then
                f.label:ClearAllPoints()
                f.label:SetPoint("TOPLEFT",  f, "TOPLEFT",  0, 0)
                f.label:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
            end
            -- DLeft is the left cap of the CharacterCreate-LabelFrame dropdown
            -- bar. Upstream AGSMW:GetBaseFrameWithWindow repositions it to
            -- displayButton.BOTTOMRIGHT; restore the original GetBaseFrame
            -- anchor so the bar starts at the frame's left edge again.
            if f.DLeft then
                f.DLeft:ClearAllPoints()
                f.DLeft:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", -17, -21)
            end
        end
        return widget
    end, currentVer + 1)
end)
