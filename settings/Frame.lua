-- settings/Frame.lua
--
-- The Frame page: the standalone window's own geometry, chrome and lock state.
--
-- Every widget on this page is a row in NS.Schema with a `window.frame.*` path,
-- so the page body is one RenderSchema call. Adding a frame option means adding
-- one row in settings/Schema.lua and nothing here.
--
-- The one bespoke control is "Reset position". Position is not a schema row and
-- deliberately cannot be one: it is stored as
-- `{ point, relativePoint, x, y }` — four values behind one concept — and the
-- flat path model the CLI shares with this panel expresses a scalar, not a
-- tuple. It is also the one piece of window state that must never be READ back
-- off the live frame (design rule R3): a cell that has been handed a secret
-- meter value makes its own geometry secret and propagates that to its parent,
-- so `GetPoint` on a drawn window is not something this addon may call. Writing
-- a known-good position is always legal; reading one is not.
--
-- WHY THE BODY IS LAZY: the builder runs at enable time, when ctx.body still has
-- zero width and AceGUI would lay every child out against it, and before the
-- UI-skinning addons that hook AceGUI:RegisterAsWidget have loaded
-- (options-ui-§5, anti-pattern #42). SetRenderer hands both problems to the
-- library, which owns *when* a page draws: first show, and again after a refresh
-- marked it dirty while it was hidden.

local addonName, NS = ...

local L = NS.L

local PAGE = "frame"

local function Build(mainCategory)
    if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then return nil end

    local H = NS.Helpers
    if not (H and H.CreatePanel) then return nil end

    local ctx = H.CreatePanel("MultiMetersFramePanel", L["Frame"], {
        pageKey        = PAGE,
        defaultsButton = true,
    })

    -- Parked, not wired: the Defaults button does not exist until the panel's
    -- first OnShow (EnsureDefaultsButton), so the library reads this field then.
    -- The canvas footer's own Defaults control forwards to the same field, which
    -- is what keeps the two controls one implementation.
    ctx.panel.defaultsOnClick = function() H.RestoreDefaults(PAGE, ctx) end

    H.SetRenderer(ctx, function(c)
        -- Every `window.*` row resolves against the ACTIVE window through
        -- NS.GetSetting / NS.SetByPath. Handing the id to the library as the
        -- row filter as well means a page definition renders the selected
        -- window's rows rather than every window's, and the window picker on
        -- the Windows page retargets this whole page by moving one piece of
        -- session state instead of by rewriting paths.
        c.unit = NS.State and NS.State.activeWindowId or nil

        -- RenderSchema appends; it does not clear. Without this a re-render
        -- after the picker moved would stack a second copy of the page under
        -- the first.
        H.ClearScroll(c)
        H.RenderSchema(c, PAGE)

        H.InlineButtonPair(c, {
            text    = L["Reset position"],
            tooltip = L["Move the window back to the center of the screen."],
            onClick = function()
                local M = NS.WindowManager
                if M and M.ResetPosition then
                    M:ResetPosition(NS.State and NS.State.activeWindowId)
                end
            end,
        }, nil)

        -- InlineButtonPair adds after RenderRows already ran its layout pass,
        -- so the row it just appended has no measured height until we ask again.
        if H.Relayout then H.Relayout(c) end
    end)

    return Settings.RegisterCanvasLayoutSubcategory(mainCategory, ctx.panel, L["Frame"])
end

if NS.RegisterOptionsPage then
    NS.RegisterOptionsPage(PAGE, L["Frame"], Build)
end
