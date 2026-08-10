-- settings/Data.lua
--
-- The Data page: which combat session this window reads, how it orders rows,
-- which column decides that order, and how often it repaints.
--
-- Schema for the four settings, plus one bespoke action — "Reset meter data" —
-- which is not a setting at all and could not be a schema row: it has no stored
-- value to get, set or restore. It is a command, so it is a button.
--
-- WHY THE SORT MODE HAS THREE OPTIONS AND ONE OF THEM SILENTLY WINS.
--
--   value     Sort by the sort column's numbers. Comparing two meter values is
--             illegal while Blizzard's combat restriction is active (design §4,
--             rule R2), so this mode is ATTEMPTED and falls through to
--             `provider` for the rest of the pull when it cannot run. The order
--             is taken at the ADDON_RESTRICTION_STATE_CHANGED "Activating"
--             edge, which fires before enforcement begins and is the last
--             moment a correct value-sort can be taken.
--   provider  Follow the order the game returns `combatSources` in. Legal in
--             combat because iterating a table needs no comparison.
--   roster    Group order, then role, then name. Never reshuffles mid-pull.
--
-- Note that the restriction keys off Combat, not ChallengeMode: between packs
-- in a key the values are fully readable, so `value` works for most of a run
-- and only freezes during the pulls themselves.
--
-- WHY THE THROTTLE HAS A FLOOR. The meter events fire far faster than a person
-- can read, so a window coalesces them onto one repaint. A configurable
-- interval of zero would turn every event back into a full rebuild — the exact
-- failure the throttle exists to prevent — so the slider is clamped to
-- Constants.THROTTLE_MIN/MAX rather than to 0.

local addonName, NS = ...

local L = NS.L

local PAGE = "data"

-- Clearing the sessions is irreversible and reaches OUTSIDE this addon —
-- C_DamageMeter.ResetAllCombatSessions wipes the data Blizzard's own meter is
-- showing too, not just ours. A player who meant "clear my window" and got
-- "clear the game's history" has no way back, so it confirms first.
StaticPopupDialogs["MYTHICMETERS_RESET_METER_DATA"] = {
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

local function Build(mainCategory)
    if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then return nil end

    local H = NS.Helpers
    if not (H and H.CreatePanel) then return nil end

    local ctx = H.CreatePanel("MythicMetersDataPanel", L["Data"], {
        pageKey        = PAGE,
        defaultsButton = true,
    })
    ctx.panel.defaultsOnClick = function() H.RestoreDefaults(PAGE, ctx) end

    H.SetRenderer(ctx, function(c)
        c.unit = NS.State and NS.State.activeWindowId or nil
        H.ClearScroll(c)
        H.RenderSchema(c, PAGE)

        H.InlineButtonPair(c, {
            text    = L["Reset meter data"],
            tooltip = L["Clear every combat session the game is holding. This affects Blizzard's built-in meter too."],
            onClick = function() StaticPopup_Show("MYTHICMETERS_RESET_METER_DATA") end,
        }, nil)

        if H.Relayout then H.Relayout(c) end
    end)

    return Settings.RegisterCanvasLayoutSubcategory(mainCategory, ctx.panel, L["Data"])
end

if NS.RegisterOptionsPage then
    NS.RegisterOptionsPage(PAGE, L["Data"], Build)
end
