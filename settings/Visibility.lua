-- settings/Visibility.lua
--
-- The Visibility page: which contexts this window shows itself in, the extra
-- rules that override a context that already said yes, and the two combat
-- rules.
--
-- Pure schema — every widget is a `window.visibility.*` row in NS.Schema.
--
-- THESE ARE NOT DISPLAY SETTINGS, AND THE DIFFERENCE IS THE POINT. A window
-- refused by these rules does not merely skip its draw: modules/Visibility.lua
-- refuses AT THE SOURCE (performance-§6), so the window stops asking the
-- provider for data at all. Nothing is read from C_DamageMeter, nothing is
-- joined, no row is laid out. A player who runs six windows and shows one of
-- them in the open world pays for one.
--
-- IT IS ALSO WHY EVERYTHING SHIPS PERMISSIVE. Every context is on and every rule
-- is off, so a fresh profile shows the meter wherever the player stands. The
-- first version of this page argued the other way — the open world off, four
-- rules on, on the reasoning that a meter in the open world is noise — and that
-- reasoning was about somebody else's taste. The cost of being wrong about it is
-- this feature's worst failure: a window that never appears, and seventeen
-- checkboxes to read before you can tell which one took it away. A page that
-- only ever shows until you ask it not to cannot fail that way.
--
-- Combat state here is read with UnitAffectingCombat("player"), never
-- InCombatLockdown(). They are not interchangeable: lockdown is about whether
-- the addon may touch a protected frame, and these rules are about what the
-- player is doing. Using the wrong one gives a window that reappears a second
-- late every pull.
--
-- EVERY RULE BELOW THE CONTEXT BLOCK IS HIDE-SHAPED, including the two combat
-- rows, which is why the page offers "Hide in combat" rather than "Show in
-- combat". A key missing from a stored window must read as "nothing objects",
-- and a show-shaped key is false when absent — so a profile written before a
-- rule existed would have every window hidden by a setting its owner never
-- touched. See ShouldShow in modules/Visibility.lua.

local addonName, NS = ...

local L = NS.L

local PAGE = "visibility"

local function Build(mainCategory)
    if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then return nil end

    local H = NS.Helpers
    if not (H and H.CreatePanel) then return nil end

    local ctx = H.CreatePanel("MultiMetersVisibilityPanel", L["Visibility"], {
        pageKey        = PAGE,
        defaultsButton = true,
    })
    ctx.panel.defaultsOnClick = function() H.RestoreDefaults(PAGE, ctx) end

    H.SetRenderer(ctx, function(c)
        c.unit = NS.State and NS.State.activeWindowId or nil
        H.ClearScroll(c)
        H.RenderSchema(c, PAGE)
    end)

    return Settings.RegisterCanvasLayoutSubcategory(mainCategory, ctx.panel, L["Visibility"])
end

if NS.RegisterOptionsPage then
    NS.RegisterOptionsPage(PAGE, L["Visibility"], Build)
end
