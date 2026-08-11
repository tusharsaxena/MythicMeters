-- core/LSMPatch.lua
--
-- Two pieces of LibSharedMedia housekeeping that belong to the addon rather than
-- to any one module: registering the media we SHIP, and fixing up a third-party
-- widget that renders LSM choices badly inside our settings panel.
--
-- Both live in core/ (addon code) and not in libs/, so a future refresh of the
-- vendored libraries cannot blow them away.
--
-- ---------------------------------------------------------------------------
-- 1. The shipped monospace font
-- ---------------------------------------------------------------------------
--
-- A meter is a grid of numbers that changes several times a second. In a
-- proportional face the digits have different widths, so "1.11M" and "9.99M"
-- occupy different amounts of space and a column of numbers visibly shivers as
-- it ticks. A monospace face pins the digits to a grid and the column stops
-- moving. That is why the addon ships one rather than relying on whatever the
-- player has installed.
--
-- Registering it with LSM (rather than only naming the path in a default) is
-- what puts it in the settings panel's font dropdown alongside every other
-- font on the player's system, and what lets a profile store it as a NAME —
-- portable across installs — instead of as a path.
--
-- Registration happens at FILE LOAD, not at PLAYER_LOGIN: LibSharedMedia is
-- vendored under libs/ and has therefore already run by the time the TOC reaches
-- this file, and defaults/Profile.lua names the font at load time too. Deferring
-- would open a window in which a default named a font LSM had never heard of.

local addonName, NS = ...

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

if LSM then
    -- LSM:Register is idempotent for an identical (mediatype, key, path) triple,
    -- so a double-load — two copies of the addon, or a test harness that runs
    -- the file twice — costs nothing.
    LSM:Register(LSM.MediaType.FONT, NS.Constants.FONT_MONO_NAME, NS.Constants.FONT_MONO)
end

-- No bar textures are REGISTERED here. The addon now ships one —
-- media/textures/Default.tga, 256x32 RGBA, the shape a statusbar wants — but it
-- is not in the registry and nothing reads it yet, so the bars still use LSM
-- statusbar textures the player already has, defaulting to a Blizzard one that
-- exists on every install.
--
-- The two costs that kept it out remain the two things to settle before it goes
-- in: it needs a license recorded beside it the way media/fonts/ records the
-- font's OFL, and it needs a registry key that will not collide in a namespace
-- every addon writes into. Until both are answered the file ships unused, which
-- costs 971 bytes and no behavior. See issue #4.

-- ---------------------------------------------------------------------------
-- 2. AceGUI-3.0-SharedMediaWidgets: the LSM30_Border display tile
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
