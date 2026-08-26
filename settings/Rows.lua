-- settings/Rows.lua
--
-- The Rows page: how many rows a window draws, how tall they are, which way
-- they stack, and the four per-row behaviors (pin self, highlight self,
-- alternating background, mouseover highlight).
--
-- Pure schema — every widget is a `window.rows.*` row in NS.Schema.
--
-- Two of these settings look cosmetic and are not, so they are worth naming
-- here rather than only in a tooltip:
--
--   maxRows          0 means "as many as fit the frame". A positive value caps
--                    the list, and the cap is applied to the ORDERED result, so
--                    it interacts with the sort mode on the Data page: under
--                    Blizzard's combat restriction the order is frozen at the
--                    moment the restriction activated (design rule R2), which
--                    means a capped window shows the same five players for the
--                    rest of the pull rather than reshuffling them.
--   alwaysShowSelf   pins the local player into a capped list. It is decided
--                    from `isLocalPlayer`, which the API marks NeverSecret, so
--                    it keeps working mid-pull when every number on the row is
--                    an opaque handle.

local addonName, NS = ...

local L = NS.L

local PAGE = "rows"

local function Build(mainCategory)
    if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then return nil end

    local H = NS.Helpers
    if not (H and H.CreatePanel) then return nil end

    local ctx = H.CreatePanel("MultiMetersRowsPanel", L["Rows"], {
        pageKey        = PAGE,
        defaultsButton = true,
    })
    ctx.panel.defaultsOnClick = function() H.RestoreDefaults(PAGE, ctx) end

    H.SetRenderer(ctx, function(c)
        c.unit = NS.State and NS.State.activeWindowId or nil
        H.ClearScroll(c)
        H.RenderSchema(c, PAGE)
    end)

    return Settings.RegisterCanvasLayoutSubcategory(mainCategory, ctx.panel, NS.SubPageLabel(L["Rows"]))
end

if NS.RegisterOptionsPage then
    NS.RegisterOptionsPage(PAGE, L["Rows"], Build)
end
