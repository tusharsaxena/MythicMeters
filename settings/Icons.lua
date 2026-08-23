-- settings/Icons.lua
--
-- The Icons page: the class, specialization and role marks drawn beside a
-- player's name in the leading name column.
--
-- Pure schema — every widget is a `window.icons.*` row in NS.Schema.
--
-- WHY THESE ARE THE ICONS THAT EXIST. `classFilename` and `specIconID` arrive
-- on the meter's own source row and the API marks both NeverSecret, so they are
-- readable at the height of a pull when every number on that same row is an
-- opaque handle. They cost nothing extra: no unit scan, no roster join, no
-- second API call. That is why they are on by default and why they are the ones
-- offered.
--
-- The ROLE icon is different in kind and worth flagging while reading these
-- rows: role is not on the meter's source row at all, so it comes from
-- modules/Roster.lua's group lookup and only exists for players who are
-- currently in the group. A row for someone who has left, or a folded pet, has
-- no role to draw, and the renderer leaves the slot empty rather than guessing.

local addonName, NS = ...

local L = NS.L

local PAGE = "icons"

local function Build(mainCategory)
    if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then return nil end

    local H = NS.Helpers
    if not (H and H.CreatePanel) then return nil end

    local ctx = H.CreatePanel("MultiMetersIconsPanel", L["Icons"], {
        pageKey        = PAGE,
        defaultsButton = true,
    })
    ctx.panel.defaultsOnClick = function() H.RestoreDefaults(PAGE, ctx) end

    H.SetRenderer(ctx, function(c)
        c.unit = NS.State and NS.State.activeWindowId or nil
        H.ClearScroll(c)
        H.RenderSchema(c, PAGE)
    end)

    return Settings.RegisterCanvasLayoutSubcategory(mainCategory, ctx.panel, L["Icons"])
end

if NS.RegisterOptionsPage then
    NS.RegisterOptionsPage(PAGE, L["Icons"], Build)
end
