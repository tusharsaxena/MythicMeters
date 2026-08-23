-- settings/Bars.lua
--
-- The Bars page: the StatusBar that sits inside every cell — its texture, how
-- it is colored, its background, its opacity and which edge it fills from.
--
-- Pure schema — every widget is a `window.bars.*` row in NS.Schema.
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

    return Settings.RegisterCanvasLayoutSubcategory(mainCategory, ctx.panel, L["Bars"])
end

if NS.RegisterOptionsPage then
    NS.RegisterOptionsPage(PAGE, L["Bars"], Build)
end
