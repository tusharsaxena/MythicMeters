-- settings/Visibility.lua
--
-- The Visibility page: which contexts this window shows itself in, plus the two
-- extra rules (hide when solo, hide in vehicles).
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
-- That is also why "Open world" ships OFF while the four instance contexts ship
-- ON. It is not a taste default. The open world is where a meter is noise and
-- where a player spends most of their time, so it is the context where a window
-- left on by accident costs the most for the least.
--
-- Combat state here is read with UnitAffectingCombat("player"), never
-- InCombatLockdown(). They are not interchangeable: lockdown is about whether
-- the addon may touch a protected frame, and these rules are about what the
-- player is doing. Using the wrong one gives a window that reappears a second
-- late every pull.

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
