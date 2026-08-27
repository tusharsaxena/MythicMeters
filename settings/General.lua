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
-- Irreversible and wide: this is a PROFILE RESET, so it is the equivalent of
-- starting a brand-new profile. Every setting on every page goes back to the
-- shipped value, and the extra windows are DELETED rather than restyled — you
-- come back with one fresh window. Other profiles are untouched.
--
-- The popup says the destructive part out loud, because it is the part that
-- surprises: "reset settings" does not sound like "delete my three windows", and
-- an OnAccept that does something the text did not warn about is how a player
-- loses a layout they spent an evening on.
--
-- The body is Helpers.RestoreAllDefaults so this popup, the header Defaults
-- button and `/mm resetall` are ONE implementation — the popup and the slash
-- command cannot drift into resetting different things — and so the Profiles
-- veto (settings/OptionsSetup.lua's skipRestoreAll) applies to all three
-- rather than to whichever path someone remembered.
StaticPopupDialogs["MULTIMETERS_RESET_ALL"] = {
    text         = L["Reset this profile to the addon defaults? Every setting goes back to its shipped value and your extra windows are DELETED \226\128\148 you come back with one fresh window, exactly as if you had made a new profile. Your other profiles are not affected."],
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
-- Reset meter data
-- ---------------------------------------------------------------------------
--
-- NO BUTTON ON THIS PAGE, and the dialog is here anyway. The Data page carried
-- both and no longer exists; the button went with the page, because a reset that
-- wipes the sessions Blizzard's own meter is reading does not belong one click
-- from the addon's front door beside two resets that only touch this addon.
--
-- The DIALOG stays because it is still opened -- by the header's own reset
-- control (modules/HeaderControls.lua), which is the deliberate way to reach it:
-- you press it on the window whose numbers you are looking at, having seen them.
--
-- The rest of the Data page's story: its four sort and session rows are written
-- by the window's own controls and were deleted, and the two that were left --
-- Merge pets and Refresh interval -- are addon-wide now and render on this page.
--
-- The dialog is declared at FILE LOAD rather than inside the builder, because
-- the header's own reset control opens it (modules/HeaderControls.lua) on an
-- install that has never opened the settings panel.

-- Clearing the sessions is irreversible and reaches OUTSIDE this addon —
-- C_DamageMeter.ResetAllCombatSessions wipes the data Blizzard's own meter is
-- showing too, not just ours. A player who meant "clear my window" and got
-- "clear the game's history" has no way back, so it confirms first.
StaticPopupDialogs["MULTIMETERS_RESET_METER_DATA"] = {
    text         = L["Clear every recorded combat session?"],
    button1      = L["Yes"],
    button2      = L["No"],
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    OnAccept     = function()
        -- Through the PROVIDER, never straight at core/Compat.lua's shim.
        -- modules/Provider.lua is the only permitted caller of the meter shims
        -- (that is where the suspend-while-restricted state and the memo
        -- invalidation live), and it publishes Reset() for exactly this button.
        -- Resolved at call time because settings/ loads ahead of modules/, and
        -- because a popup handler can fire long after either.
        local Provider = NS.Provider
        if Provider and Provider.Reset then Provider.Reset() end
    end,
}

--- Open the reset confirmation, CENTRED ON THE SCREEN.
---
--- WHY IT IS NOT LEFT WHERE BLIZZARD PUTS IT. A StaticPopup is anchored into the
--- popup STACK -- centred horizontally, pinned near the top of the screen -- so
--- the one dialog in this addon that asks before it destroys data appeared
--- nowhere near where the player was looking when they clicked, which for a
--- header control is the middle of the screen at most. Re-anchoring is the
--- narrowest fix: the dialog is still Blizzard's, still `hideOnEscape`, still in
--- the stack it registered into.
---
--- The frame is repositioned and nothing else: a StaticPopup is not a protected
--- frame, so moving one taints no secure code path.
---
--- ONCE, AS IT IS SHOWN. Blizzard re-stacks every dialog when another popup opens
--- or closes, so a second popup arriving on top of this one can pull it back up
--- to the stack. That is accepted rather than fixed: following the stack means
--- hooking `StaticPopup_SetUpPosition` for a case -- two dialogs up at once --
--- that this addon can produce only by accident.
---
--- Answers the dialog frame, or nil when every popup slot is already in use --
--- which is a legitimate outcome of StaticPopup_Show and not an error here.
function NS.ShowResetMeterData()
    local show = _G.StaticPopup_Show
    if not show then return nil end

    local dialog = show("MULTIMETERS_RESET_METER_DATA")
    if dialog and dialog.SetPoint and _G.UIParent then
        dialog:ClearAllPoints()
        dialog:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 0)
    end
    return dialog
end

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

    -- The page's two non-setting controls, side by side because both are resets and a player
    -- looking for one is looking for the other.
    --
    -- RESET POSITION IS PER-WINDOW on an otherwise addon-wide page, and that is why its
    -- tooltip names the window rather than saying "the window". It moved here from Frame
    -- because a reset is what a player comes to General for; what it resets did not change
    -- with the move.
    --
    -- Fired through RenderTabbedSchema's afterGroup hook, keyed to the Maintenance tab (the
    -- group the Debug console row already lives in) rather than drawn unconditionally after
    -- the schema: with the page tabbed, "after the schema" is no longer "at the bottom of the
    -- page" for every tab, and these buttons belong with Maintenance, not appended under
    -- whichever group happens to be open.
    local function afterMaintenance(c)
        H.InlineButtonPair(c, {
            text    = L["Reset all settings"],
            tooltip = L["Start over: reset the active profile to the addon defaults, which deletes every window but one. The same thing Profiles \226\134\146 Reset Profile does. Your other profiles are left alone."],
            onClick = function() StaticPopup_Show("MULTIMETERS_RESET_ALL") end,
        }, {
            text    = L["Reset position"],
            tooltip = L["Move the window selected on the Windows page back to the center of the screen. Only that window moves."],
            onClick = function()
                local M = NS.WindowManager
                if M and M.ResetPosition then
                    M:ResetPosition(NS.State and NS.State.activeWindowId)
                end
            end,
        })
        if H.Relayout then H.Relayout(c) end
    end

    H.SetRenderer(ctx, function(c)
        H.ClearScroll(c)
        -- The WHOLE page. Test mode and the debug console are schema rows on this
        -- page (settings/Schema.lua, `sessionOnly`), so rendering the schema
        -- renders them — drawing either one here as well is what produced the
        -- duplicate checkboxes and the duplicate "Debug" heading.
        H.RenderTabbedSchema(c, PAGE, { [L["Maintenance"]] = afterMaintenance })
    end)

    return Settings.RegisterCanvasLayoutSubcategory(mainCategory, ctx.panel, L["General"])
end

if NS.RegisterOptionsPage then
    NS.RegisterOptionsPage(PAGE, L["General"], Build)
end
