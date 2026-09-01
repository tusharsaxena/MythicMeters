-- settings/Header.lua
--
-- The Header page: the strip above the rows — its title, what it reports about
-- the session, and how it is drawn.
--
-- Pure schema. Every widget is a `window.header.*` row in NS.Schema, so this
-- file is the registration and the lazy body and nothing else; adding a header
-- option is one row in settings/Schema.lua.
--
-- Worth knowing while reading the rows this page renders: the two accents the
-- SKIN owns -- `frame.title` and `frame.divider` -- are both configurable here
-- now, and the rule they were once withheld under is intact rather than waived.
--
-- The rule (standalone-windows) is "never RESTATE Core.SKIN's values", because a
-- copy drifts a hex digit at a time and then has to be migrated. It is not "never
-- let a player choose". So both accents are reached the same way: ApplySkin runs
-- first and owns the accent, and a setting that claims to govern it writes AFTER
-- the library rather than instead of it.
--
-- The divider goes one better, because it is the only one with a *default* that
-- has to mean "whatever the collection says". Its `skin` mode -- the shipped one
-- -- resolves nothing and writes nothing, leaving ApplySkin's tint standing. So
-- the shared value is never copied into this repo and never into a profile, and a
-- re-skin still lands on this window along with the debug console and the perf
-- panel. See modules/Window.lua's ApplyHeaderStrip.

local addonName, NS = ...

local L = NS.L

local PAGE = "header"

local function Build(mainCategory)
    if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then return nil end

    local H = NS.Helpers
    if not (H and H.CreatePanel) then return nil end

    local ctx = H.CreatePanel("MultiMetersHeaderPanel", L["Header"], {
        pageKey        = PAGE,
        defaultsButton = true,
    })
    ctx.panel.defaultsOnClick = function() H.RestoreDefaults(PAGE, ctx) end

    -- The library owns WHEN this draws — first show, and again when a refresh
    -- marked it dirty while hidden. Building at registration time would lay the
    -- widgets out against a zero-width body and lose the AceGUI skinning race
    -- (options-ui-§5).
    H.SetRenderer(ctx, function(c)
        c.unit = NS.State and NS.State.activeWindowId or nil
        H.ClearScroll(c)
        H.WindowBanner(c)
        H.RenderTabbedSchema(c, PAGE)
    end)

    return Settings.RegisterCanvasLayoutSubcategory(mainCategory, ctx.panel, NS.SubPageLabel(L["Header"]))
end

if NS.RegisterOptionsPage then
    NS.RegisterOptionsPage(PAGE, L["Header"], Build)
end
