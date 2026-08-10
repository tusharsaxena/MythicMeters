-- settings/Header.lua
--
-- The Header page: the strip above the rows — its title, what it reports about
-- the session, and how it is drawn.
--
-- Pure schema. Every widget is a `window.header.*` row in NS.Schema, so this
-- file is the registration and the lazy body and nothing else; adding a header
-- option is one row in settings/Schema.lua.
--
-- Worth knowing while reading the rows this page renders: the header's EDGE
-- colors are not settings and never will be. The window's chrome comes from
-- LibKa0s-Core-1.0's shared SKIN and ApplySkin, which tints `frame.title` and
-- `frame.divider` itself (library-stack). A per-addon color picker for those
-- would be a private lookalike of the collection's shared look, and the first
-- thing to drift away from it. What IS configurable here is the header's own
-- text and background, which the skin does not own.

local addonName, NS = ...

local L = NS.L

local PAGE = "header"

local function Build(mainCategory)
    if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then return nil end

    local H = NS.Helpers
    if not (H and H.CreatePanel) then return nil end

    local ctx = H.CreatePanel("MythicMetersHeaderPanel", L["Header"], {
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
        H.RenderSchema(c, PAGE)
    end)

    return Settings.RegisterCanvasLayoutSubcategory(mainCategory, ctx.panel, L["Header"])
end

if NS.RegisterOptionsPage then
    NS.RegisterOptionsPage(PAGE, L["Header"], Build)
end
