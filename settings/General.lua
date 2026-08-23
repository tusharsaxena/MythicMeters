-- settings/General.lua
--
-- The General page: the settings that are genuinely addon-wide rather than
-- per-window.
--
-- There are only two of them — the master enable and the minimap button — and
-- that is the design working rather than the page being thin. A window is an
-- instance (design §6), so everything a player thinks of as "a setting" belongs
-- to one: width, columns, colors, visibility. What is left over is the handful
-- of things that cannot sensibly differ between windows.
--
-- Two more controls sit here — Test mode and the Debug console — and both are
-- SESSION state that is never written to SavedVariables. They are nonetheless
-- SCHEMA ROWS, marked `sessionOnly`, and this file renders NOTHING of its own for
-- them.
--
-- THAT IS A CORRECTION, and it is worth stating because the wrong shape looked
-- reasonable. This page used to draw both bespoke, through
-- Helpers.SessionCheckbox, on the theory that session state is not a setting. The
-- schema then grew rows for the same two toggles so `/mm list` and `/mm set`
-- could reach them — which is right, and is what `sessionOnly` exists for — and
-- nobody removed the bespoke pair. The page rendered the schema AND its own
-- widgets, so the player saw "Preview mode" twice, "Debug console" twice, and two
-- separate "Debug" section headings.
--
-- The rule that prevents the repeat: if a control has a schema row, this file
-- does not draw it. A page renders the schema and its own NON-setting furniture
-- (the reset-everything button below), and nothing else.

local addonName, NS = ...

local L = NS.L

local PAGE = "general"

local H = NS.Helpers or {}

-- ---------------------------------------------------------------------------
-- Reset everything
-- ---------------------------------------------------------------------------
--
-- Irreversible and wide: every page, for every window, in the active profile.
-- The body is Helpers.RestoreAllDefaults so this popup, the header Defaults
-- button and `/mm resetall` are ONE implementation — the popup and the slash
-- command cannot drift into resetting different things — and so the Profiles
-- veto (settings/OptionsSetup.lua's skipRestoreAll) applies to all three
-- rather than to whichever path someone remembered.
StaticPopupDialogs["MULTIMETERS_RESET_ALL"] = {
    text         = L["Reset every window and every setting to the addon defaults? The active profile is the only one affected."],
    button1      = L["Yes"],
    button2      = L["No"],
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    OnAccept     = function()
        if H.RestoreAllDefaults then H.RestoreAllDefaults() end
    end,
}

-- ---------------------------------------------------------------------------
-- Builder
-- ---------------------------------------------------------------------------

local function Build(mainCategory)
    if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then return nil end
    if not (H and H.CreatePanel) then return nil end

    local ctx = H.CreatePanel("MultiMetersGeneralPanel", L["General"], {
        pageKey        = PAGE,
        defaultsButton = true,
    })
    ctx.panel.defaultsOnClick = function() H.RestoreDefaults(PAGE, ctx) end

    H.SetRenderer(ctx, function(c)
        H.ClearScroll(c)
        -- The WHOLE page. Test mode and the debug console are schema rows on this
        -- page (settings/Schema.lua, `sessionOnly`), so rendering the schema
        -- renders them — drawing either one here as well is what produced the
        -- duplicate checkboxes and the duplicate "Debug" heading.
        H.RenderSchema(c, PAGE)

        H.InlineButtonPair(c, {
            text    = L["Reset all settings"],
            tooltip = L["Reset every setting on every page, for every window, back to the addon defaults. Profiles are left alone."],
            onClick = function() StaticPopup_Show("MULTIMETERS_RESET_ALL") end,
        }, nil)

        if H.Relayout then H.Relayout(c) end
    end)

    return Settings.RegisterCanvasLayoutSubcategory(mainCategory, ctx.panel, L["General"])
end

if NS.RegisterOptionsPage then
    NS.RegisterOptionsPage(PAGE, L["General"], Build)
end
