-- settings/Text.lua
--
-- The Text page: the FontString inside every cell — which figure goes in each
-- of the two text slots, how numbers are abbreviated, and the font that draws
-- them.
--
-- Pure schema — every widget is a `window.text.*` row in NS.Schema.
--
-- TWO THINGS THIS PAGE LOOKS LIKE IT CONTROLS AND DOES NOT.
--
-- "Number format" does not pick a Lua format string. Abbreviating 12400000 to
-- "12.4M" is a division and a rounding, and arithmetic on a secret value raises
-- immediately (design §4) — so no call site in this addon divides anything. The
-- setting picks which `C_StringUtil.CreateNumericRuleFormatter()` instance
-- modules/Format.lua hands the value to; the formatter does the arithmetic
-- NATIVELY, which is the only legal way to render an abbreviated secret.
--
-- "Right text" offers a per-second figure, but only Damage and Healing have one
-- worth showing. Every source row carries an `amountPerSecond`, including the
-- counting stats — "0.42 interrupts per second" is a real number and useless —
-- so the catalog's `isRate` flag decides whether the right slot has anything to
-- say for a given column (core/Constants.lua).
--
-- The font default is the shipped monospace face, and that is a legibility
-- decision rather than a taste one: a meter is a grid of numbers, and
-- proportional digits make a column jitter sideways every time a value ticks.

local addonName, NS = ...

local L = NS.L

local PAGE = "text"

local function Build(mainCategory)
    if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then return nil end

    local H = NS.Helpers
    if not (H and H.CreatePanel) then return nil end

    local ctx = H.CreatePanel("MultiMetersTextPanel", L["Text"], {
        pageKey        = PAGE,
        defaultsButton = true,
    })
    ctx.panel.defaultsOnClick = function() H.RestoreDefaults(PAGE, ctx) end

    H.SetRenderer(ctx, function(c)
        c.unit = NS.State and NS.State.activeWindowId or nil
        H.ClearScroll(c)
        H.RenderSchema(c, PAGE)
    end)

    return Settings.RegisterCanvasLayoutSubcategory(mainCategory, ctx.panel, L["Text"])
end

if NS.RegisterOptionsPage then
    NS.RegisterOptionsPage(PAGE, L["Text"], Build)
end
