-- settings/Frame.lua
--
-- The Frame page: the standalone window's own geometry, chrome and lock state.
--
-- Every widget on this page is a row in NS.Schema with a `window.frame.*` path,
-- so the page body is one RenderSchema call. Adding a frame option means adding
-- one row in settings/Schema.lua and nothing here.
--
-- NO BESPOKE CONTROLS. "Reset position" used to sit at the bottom of this page
-- and now sits on General beside "Reset all settings", where the player looks
-- for a reset. It still acts on the ACTIVE window — position is per-window and
-- there is nothing addon-wide about it — so settings/General.lua says which
-- window it means rather than leaving the page's scope to imply the wrong one.
--
-- The Header controls group left this page too, for the Header page. Both moves
-- are page placement only: `window.frame.*` is still where every one of those
-- settings is STORED.
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
    end)

    return Settings.RegisterCanvasLayoutSubcategory(mainCategory, ctx.panel, NS.SubPageLabel(L["Frame"]))
end

if NS.RegisterOptionsPage then
    NS.RegisterOptionsPage(PAGE, L["Frame"], Build)
end
