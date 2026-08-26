-- settings/Bars.lua
--
-- The Bars page — EVERYTHING DRAWN INSIDE A CELL, in five groups: the StatusBar
-- itself (texture, colour, opacity, fill direction), the tint behind it, its
-- border, the two TEXT slots, and the name column's icon.
--
-- THE TEXT AND ICONS PAGES FOLDED IN HERE. They were their own tree entries and
-- their own canvases, which meant styling one cell — the bar behind the number,
-- the number, and the icon beside the name — was three pages and two clicks
-- between each change you wanted to compare. Everything a cell draws is on one
-- page now, in the order it is drawn: back to front.
--
-- Pure schema — every widget is a `window.bars.*`, `window.text.*` or
-- `window.icons.*` row in NS.Schema. The PATHS did not move with the page and
-- must not: a row's page is where it is edited, its path is where it is stored,
-- and renaming `text.size` to `bars.textSize` for tidiness would migrate every
-- saved profile in the collection for nothing anybody can see.
--
-- THE CONSTRAINT BEHIND THE COLOR MODES. A bar's LENGTH comes from
-- `SetMinMaxValues(0, maxAmount)` + `SetValue(totalAmount)`, and under
-- Blizzard's combat restriction both of those are secret values — legal to hand
-- to a widget setter, illegal to compare, divide or test (design §4). So the
-- addon can never ask "is this bar more than half full" to decide anything, and
-- a color mode that depended on the value would be unimplementable mid-pull,
-- which is exactly when a meter is read.
--
-- The three shipped modes are therefore all value-independent:
--
--   class   the source's `classFilename`, which the API marks NeverSecret
--   stat    one color per column, decided by the column, not by its contents
--   custom  one color everywhere
--
-- A "color by rank" or "color above threshold" mode is not a missing feature
-- here; it is a thing this data source cannot express while a pull is running.

local addonName, NS = ...

local L = NS.L

local PAGE = "bars"

local function Build(mainCategory)
    if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then return nil end

    local H = NS.Helpers
    if not (H and H.CreatePanel) then return nil end

    local ctx = H.CreatePanel("MultiMetersBarsPanel", L["Bars"], {
        pageKey        = PAGE,
        defaultsButton = true,
    })
    ctx.panel.defaultsOnClick = function() H.RestoreDefaults(PAGE, ctx) end

    H.SetRenderer(ctx, function(c)
        c.unit = NS.State and NS.State.activeWindowId or nil
        H.ClearScroll(c)
        H.RenderSchema(c, PAGE)
    end)

    return Settings.RegisterCanvasLayoutSubcategory(mainCategory, ctx.panel, NS.SubPageLabel(L["Bars"]))
end

if NS.RegisterOptionsPage then
    NS.RegisterOptionsPage(PAGE, L["Bars"], Build)
end
