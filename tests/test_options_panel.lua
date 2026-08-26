-- tests/test_options_panel.lua
--
-- settings/OptionsSetup.lua — the addon's half of LibKa0s-Options-1.0. The
-- canvas shell, the widget makers, the flow engine and the two refresh tiers are
-- the library's and are tested there (testing-§8). What is ours, and what is
-- asserted here, is the WIRING: where a value lives, which rows belong to which
-- page, what a global reset must not touch, and the four descriptor callbacks
-- that decide whether the panel and the CLI share one code path or merely look
-- like they do.
--
-- Two timing rules carry most of the weight, and both are invisible from the
-- source alone:
--
--   REGISTRATION IS EAGER, THE BODY IS LAZY. Every page's Blizzard category is
--   claimed during CreateOptionsPanel — a category that appears only once the
--   user has already found it is no category at all — while the body waits for
--   the panel's first OnShow, because ctx.body has zero width at enable time and
--   because AceGUI widgets built inside the load window miss every skinning hook
--   installed after them (options-ui-§5, anti-pattern #42).
--
--   ENSUREDEFAULTSBUTTON RUNS AT THE TOP OF *EVERY* OnShow, OUTSIDE the
--   already-rendered guard. Move it below that guard and the button is built on
--   the first show only — which looks identical until a page is re-shown after a
--   rebuild, and then the button is simply gone.

local T = _G.MULTIMETERS_TEST
local test = T.test
local assertEqual, assertTrue, assertFalse = T.assertEqual, T.assertTrue, T.assertFalse

local NS = T.NS

-- Every page settings/ registers, by panel key. Stated here rather than derived
-- from the same registry the assertions read, so a page that silently stopped
-- registering is a failure rather than a shorter list that still agrees with
-- itself.
-- GENERAL IS FIRST, above Windows, because it is the only page that is not
-- about one window. The order here is the TOC's registration order, which is the
-- order the tree draws.
local PAGES = {
    "general", "windows", "frame", "header", "bars",
    "tooltip", "visibility", "columns", "profiles",
}

-- The canvas frame name each page builds under. Used to reach a page's ctx while
-- `ctx.pageKey` is unset (see the `carries its page key` case below, which is the
-- failing test that pins the underlying defect); every other case in this suite
-- is about something else and should not be blocked behind it.
local PANEL_NAME = {
    windows    = "MultiMetersWindowsPanel",
    frame      = "MultiMetersFramePanel",
    header     = "MultiMetersHeaderPanel",
    bars       = "MultiMetersBarsPanel",
    tooltip    = "MultiMetersTooltipPanel",
    visibility = "MultiMetersVisibilityPanel",
    columns    = "MultiMetersColumnsPanel",
    general    = "MultiMetersGeneralPanel",
    profiles   = "MultiMetersProfilesPanel",
}

local function aceGUI(inst) return inst.mocks.__libs["AceGUI-3.0"] end

--- One page's ctx: through the library's own seam when it resolves, and by the
--- panel's frame name when it does not.
local function panelFor(inst, pageKey)
    local ctx = inst.NS.Helpers.__panelFor(pageKey)
    if ctx then return ctx end
    local name = PANEL_NAME[pageKey]
    for _, c in ipairs(inst.NS.Helpers.__panels()) do
        if c.panel and c.panel:GetName() == name then return c end
    end
    return nil
end

--- The widgets created since `from`, in creation order.
local function widgetsSince(inst, from)
    local created, out = aceGUI(inst).__created, {}
    for i = from + 1, #created do out[#out + 1] = created[i] end
    return out
end

--- The first widget of `wtype` whose label matches, among `list`.
local function findWidget(list, wtype, label)
    for _, w in ipairs(list) do
        if w.type == wtype and (label == nil or w.labelText == label or w.text == label) then
            return w
        end
    end
    return nil
end

--- Show a page's panel, driving the genuine deferred first render.
local function showPage(inst, pageKey)
    local ctx = panelFor(inst, pageKey)
    assertTrue(ctx ~= nil, "no panel registered for the '" .. pageKey .. "' page")
    ctx.panel:Hide()
    ctx.panel:Show()
    return ctx
end

-- ---------------------------------------------------------------------------
-- Eager registration
-- ---------------------------------------------------------------------------

test("Options: General is the FIRST page, above Windows", function()
    -- The tree order IS the registration order, and registration order is the
    -- TOC's. General is the only page that is not about one window, so it sits
    -- above the picker that retargets the other nine rather than below them.
    -- red under: moving settings\General.lua back down the TOC.
    local built = NS.Helpers.__pages()
    assertEqual(built[1] and built[1].key, "general")
    assertEqual(built[2] and built[2].key, "windows")
end)

test("Options: every window page is marked as nested, and the two that are not are not", function()
    -- Blizzard's Settings tree draws every canvas subcategory at the SAME depth,
    -- so nine pages that silently retarget when the Windows picker moves would
    -- read as peers of the two that never do. The mark is typography, prefixed
    -- to the TREE LABEL only.
    -- red under: marking General or Profiles, or dropping the mark from a page
    -- the picker retargets.
    -- INDENT PLUS HYPHEN, and the exact string matters: it shipped once as
    -- U+21B3 (Friz Quadrata drew a hollow box) and once as "|- " (which read as
    -- a bulleted list rather than as nesting). Leading whitespace is also the
    -- one part of this a toolkit could silently TRIM, so this is the case that
    -- would notice a mark that stopped arriving whole.
    local MARK = "  - "
    local NESTED = {
        frame = true, header = true, bars = true,
        tooltip = true, visibility = true, columns = true,
    }

    local labels = T.mocks.__subcategories
    for _, page in ipairs(NS.Helpers.__pages()) do
        local marked = labels[MARK .. page.name] ~= nil
        local plain  = labels[page.name] ~= nil
        if NESTED[page.key] then
            assertTrue(marked, page.key .. " is edited against the selected window and is not marked")
            assertFalse(plain, page.key .. " registered an unmarked label as well")
        else
            assertTrue(plain, page.key .. " must keep its plain label")
            assertFalse(marked, page.key .. " is not about one window and must not be marked")
        end
    end
end)

test("Options: the page HEADING keeps the plain name, mark or no mark", function()
    -- The mark is an indent in a tree. Written across the top of the page it
    -- reads as a typo, and the breadcrumb inherits the panel's own title.
    -- red under: passing SubPageLabel to CreatePanel as well.
    local ctx = panelFor(T, "frame")
    assertTrue(ctx ~= nil)
    assertEqual(ctx.panel.name, NS.L["Frame"],
        "the canvas panel's own name carries the mark")
end)

test("Options: the parent category is registered at CreateOptionsPanel time", function()
    assertTrue(T.mocks.__mainPanel ~= nil, "no canvas category was registered")
    assertEqual(T.mocks.__mainPanel:GetName(), "MultiMetersMainPanel",
        "the main panel is NAMED so /framestack attributes it to this addon")
end)

test("Options: every page's subcategory is registered eagerly, before any panel is shown", function()
    local built = {}
    for _, page in ipairs(NS.Helpers.__pages()) do built[page.key] = true end
    for _, key in ipairs(PAGES) do
        assertTrue(built[key], "the '" .. key .. "' page did not build")
    end
    assertEqual(#NS.Helpers.__pages(), #PAGES,
        "a page appeared or vanished; update PAGES deliberately rather than the count")

    -- And they really reached Blizzard's registry, not just the library's.
    local subs = 0
    for _ in pairs(T.mocks.__subcategories) do subs = subs + 1 end
    assertEqual(subs, #PAGES)
end)

-- SUSPECTED DEFECT, pinned rather than papered over.
--
-- Every settings/<page>.lua calls `H.CreatePanel(name, title, { panelKey = PAGE,
-- ... })`, while libs/LibKa0s/Options.lua:301 reads `opts.pageKey`. The key is
-- therefore dropped on the floor for all thirteen pages: `ctx.pageKey` is nil
-- everywhere, `Helpers.__panelFor(key)` — the library's published per-page handle,
-- which settings/OptionsSetup.lua's own degradation stub also publishes — resolves
-- nothing, and a renderer that raises is reported as page "?" instead of by name
-- (Options.lua:482). Nothing raises, which is exactly why it survived: the pages
-- draw correctly, because RenderSchema and RestoreDefaults are handed the page key
-- as an argument rather than reading it off the ctx.
--
-- The fix is one word per page file. This case goes green when it lands.
test("Options: a page's ctx carries its page key", function()
    for _, key in ipairs(PAGES) do
        local ctx = panelFor(T, key)
        assertTrue(ctx ~= nil, "no ctx for '" .. key .. "'")
        assertEqual(ctx.pageKey, key,
            "settings/" .. key .. " passes `panelKey`; LibKa0s-Options-1.0 reads `pageKey`")
    end
end)

-- ---------------------------------------------------------------------------
-- The lazy body
-- ---------------------------------------------------------------------------

test("Options: the body is NOT built until the panel's first OnShow", function()
    local inst = T.load()
    local ctx = panelFor(inst, "frame")
    assertFalse(ctx._rendered, "the body rendered at registration time")
    assertEqual(ctx.scroll, nil, "the AceGUI ScrollFrame was created before the panel had a width")

    local before = #aceGUI(inst).__created
    ctx.panel:Hide()
    ctx.panel:Show()

    assertTrue(ctx._rendered, "first OnShow must render the body")
    assertTrue(ctx.scroll ~= nil)
    assertTrue(#aceGUI(inst).__created > before, "no widgets were created by the render")
end)

test("Options: a second OnShow does NOT re-render an already-rendered page", function()
    local inst = T.load()
    local ctx = showPage(inst, "frame")
    local after = #aceGUI(inst).__created

    ctx.panel:Hide()
    ctx.panel:Show()

    assertEqual(#aceGUI(inst).__created, after,
        "rebuilding a page on every show is the cost the rendered guard exists to avoid")
end)

test("Options: a hidden page is marked dirty and re-renders on its NEXT show", function()
    local inst = T.load()
    local ctx = showPage(inst, "frame")
    ctx.panel:Hide()

    inst.NS.Helpers.RefreshAllPanels()
    assertTrue(ctx._dirty, "a structural refresh must flag a hidden page")

    local before = #aceGUI(inst).__created
    ctx.panel:Show()
    assertFalse(ctx._dirty)
    assertTrue(#aceGUI(inst).__created > before, "the dirty page did not repaint")
end)

-- ---------------------------------------------------------------------------
-- EnsureDefaultsButton, at the top of EVERY OnShow
-- ---------------------------------------------------------------------------

test("Options: the Defaults button is built on first show, not at registration", function()
    local inst = T.load()
    local ctx = panelFor(inst, "frame")
    assertTrue(ctx.panel.wantsDefaultsButton, "the Frame page asks for a Defaults button")
    assertEqual(ctx.panel.defaultsBtn, nil,
        "a button built inside the load window misses every skinning hook installed after it")

    ctx.panel:Hide()
    ctx.panel:Show()
    assertTrue(ctx.panel.defaultsBtn ~= nil)
    assertEqual(ctx.panel.defaultsBtn.text, "Defaults")
end)

test("Options: EnsureDefaultsButton runs OUTSIDE the already-rendered guard", function()
    local inst = T.load()
    local ctx = showPage(inst, "frame")
    assertTrue(ctx.panel.defaultsBtn ~= nil)

    -- Drop the button and show the page again. The body is already rendered and
    -- not dirty, so the renderer returns early — if the Ensure call sat below that
    -- guard, nothing would rebuild the button.
    ctx.panel.defaultsBtn = nil
    local before = #aceGUI(inst).__created
    ctx.panel:Hide()
    ctx.panel:Show()

    assertTrue(ctx.panel.defaultsBtn ~= nil,
        "the Defaults button was not rebuilt — EnsureDefaultsButton is inside the render guard")
    assertEqual(#aceGUI(inst).__created, before + 1,
        "exactly one widget — the button — should have been created; more means the body "
        .. "re-rendered and this case proves nothing")
end)

test("Options: a page that declines a Defaults button never grows one", function()
    -- The column list is not a set of schema rows, so there is nothing per-row to
    -- restore; the Profiles page's rows are user data.
    local inst = T.load()
    for _, key in ipairs({ "columns", "profiles", "windows" }) do
        local ctx = showPage(inst, key)
        assertFalse(ctx.panel.wantsDefaultsButton, key .. " asked for a Defaults button")
        assertEqual(ctx.panel.defaultsBtn, nil, key .. " grew a Defaults button anyway")
    end
end)

test("Options: the canvas footer's Defaults control reaches the same handler as the header button",
function()
    local inst = T.load()
    local ctx = showPage(inst, "frame")
    local clicks = 0
    ctx.panel.defaultsOnClick = function() clicks = clicks + 1 end
    ctx.panel.OnDefault()
    assertEqual(clicks, 1,
        "OnDefault must FORWARD through the panel at call time; a captured reference would "
        .. "have frozen nil, because the button does not exist when the page is built")
end)

-- ---------------------------------------------------------------------------
-- The combat refusal
-- ---------------------------------------------------------------------------

test("Options: opening the panel is REFUSED under combat lockdown, with a notice", function()
    local inst = T.load()
    local opens = 0
    inst.mocks.Settings.OpenToCategory = function() opens = opens + 1 end

    inst.mocks.setRestricted(true)
    local before = #inst.mocks.__chat
    inst.NS.OpenOptionsPanel()

    assertEqual(opens, 0, "Blizzard's category switch is protected; calling it taints the panel")
    assertTrue(#inst.mocks.__chat > before, "the refusal must be legible; a silent one reads as a bug")
    assertTrue(inst.mocks.__chat[#inst.mocks.__chat]:find("combat", 1, true) ~= nil,
        "the notice should say why: " .. tostring(inst.mocks.__chat[#inst.mocks.__chat]))
end)

test("Options: a refused open is NOT deferred and replayed when combat ends", function()
    local inst = T.load()
    local opens = 0
    inst.mocks.Settings.OpenToCategory = function() opens = opens + 1 end

    inst.mocks.setRestricted(true)
    local timersBefore = #inst.mocks.__timers
    inst.NS.OpenOptionsPanel()
    assertEqual(#inst.mocks.__timers, timersBefore,
        "nothing may be scheduled: a panel that opens itself the instant combat drops "
        .. "steals focus during post-pull recovery (options-ui-§2)")

    inst.mocks.setRestricted(false)
    inst.mocks.__flushTimers()
    assertEqual(opens, 0, "the refused open was replayed")

    -- And the command still works once the user asks again.
    inst.NS.OpenOptionsPanel()
    assertEqual(opens, 1)
end)

test("Options: a page reached from the Blizzard sidebar mid-combat refuses to render", function()
    local inst = T.load()
    local ctx = panelFor(inst, "frame")
    inst.mocks.setRestricted(true)

    ctx.panel:Hide()
    ctx.panel:Show()

    assertFalse(ctx._rendered, "the sidebar bypasses OpenOptionsPanel's guard, so OnShow re-checks")
    assertEqual(ctx.scroll, nil, "no body may be built under lockdown")
    assertTrue(inst.mocks.__settingsClosed > 0,
        "closing the window is what makes the refusal legible; a silent no-render reads as a bug")

    -- And it really is only the render that was refused: the Defaults button is
    -- built above the combat check, on every show, which is the ordering the
    -- previous case pins from the other direction.
    assertTrue(ctx.panel.defaultsBtn ~= nil)
end)

-- ---------------------------------------------------------------------------
-- One write seam, shared with the CLI
-- ---------------------------------------------------------------------------

test("Options: a widget's set() routes through NS.SetByPath", function()
    local inst = T.load()
    local ctx = panelFor(inst, "frame")
    local before = #aceGUI(inst).__created
    ctx.panel:Hide()
    ctx.panel:Show()

    local slider = findWidget(widgetsSince(inst, before), "Slider", inst.NS.L["Width"])
    assertTrue(slider ~= nil, "the Frame page's Width slider was not rendered")

    local seen = {}
    local real = inst.NS.SetByPath
    inst.NS.SetByPath = function(path, value)
        seen[#seen + 1] = { path = path, value = value }
        return real(path, value)
    end
    slider:__fire("OnMouseUp", 350)
    inst.NS.SetByPath = real

    assertEqual(#seen, 1, "the panel must not reach the db behind the seam")
    assertEqual(seen[1].path, "window.frame.width")
    assertEqual(seen[1].value, 350)
    assertEqual(inst.NS.GetSetting("window.frame.width"), 350)
end)

test("Options: a checkbox's set() routes through NS.SetByPath too", function()
    local inst = T.load()
    local ctx = panelFor(inst, "frame")
    local before = #aceGUI(inst).__created
    ctx.panel:Hide()
    ctx.panel:Show()

    local cb = findWidget(widgetsSince(inst, before), "CheckBox", inst.NS.L["Show title bar"])
    assertTrue(cb ~= nil)

    local seen = {}
    local real = inst.NS.SetByPath
    inst.NS.SetByPath = function(path, value)
        seen[#seen + 1] = path
        return real(path, value)
    end
    cb:__fire("OnValueChanged", false)
    inst.NS.SetByPath = real

    assertEqual(#seen, 1)
    assertEqual(seen[1], "window.frame.titleBar")
    assertEqual(inst.NS.GetSetting("window.frame.titleBar"), false)
end)

test("Options: applyDefault routes through NS.SetByPath, not around it", function()
    local inst = T.load()
    local seen = {}
    local real = inst.NS.SetByPath
    inst.NS.SetByPath = function(path, value)
        seen[#seen + 1] = path
        return real(path, value)
    end
    inst.NS.Helpers.RestoreDefaults("frame", nil)
    inst.NS.SetByPath = real

    assertTrue(#seen > 0, "the page reset wrote nothing")
    for _, path in ipairs(seen) do
        local row = inst.NS.FindSchemaRow(path)
        assertTrue(row ~= nil, path .. " is not a schema row")
        assertEqual(row.page, "frame", "a page reset must not reach past its own page")
    end
end)

test("Options: the panel and the CLI resolve a page's rows through the SAME function", function()
    -- rowsForPage is read off NS at call time; reaching for it on the library
    -- instance found nothing and fell through to a private inline loop — a second
    -- grouping rule that could not follow the schema's.
    local inst = T.load()
    local calls = 0
    local real = inst.NS.SchemaForPage
    inst.NS.SchemaForPage = function(...) calls = calls + 1; return real(...) end
    inst.NS.Helpers.RestoreDefaults("bars", nil)
    inst.NS.SchemaForPage = real
    assertTrue(calls > 0,
        "the descriptor's rowsForPage must resolve NS.SchemaForPage, not re-implement it")
end)

-- ---------------------------------------------------------------------------
-- The reset-all veto
-- ---------------------------------------------------------------------------

test("Options: skipRestoreAll vetoes the profiles page from a global reset", function()
    -- Resetting a profiles row deletes user data, which is not what "restore
    -- defaults" means to anyone (options-ui-§3). The schema ships no profiles row
    -- — AceDBOptions supplies those controls — so one is registered here, because
    -- a veto proven only against an empty set is a veto proven against nothing.
    local inst = T.load()
    inst.NS.RegisterSchemaRows({
        { path = "state.pretendProfileRow", type = "bool", default = false,
          sessionOnly = true, page = "profiles", label = "Pretend",
          get = function() return false end, set = function() end },
    })

    local seen = {}
    local real = inst.NS.SetByPath
    inst.NS.SetByPath = function(path, value)
        seen[path] = (seen[path] or 0) + 1
        return real(path, value)
    end
    inst.NS.Helpers.RestoreAllDefaults()
    inst.NS.SetByPath = real

    assertEqual(seen["state.pretendProfileRow"], nil,
        "a profiles row was reset — the veto is not wired to the descriptor")

    -- AND NOTHING THAT LIVES IN THE PROFILE. "Reset all settings" is a profile
    -- reset now, so writing each row's default first would announce
    -- CONFIG_CHANGED once per row for values about to be discarded whole. What
    -- the row walk is left with is the sessionOnly rows, which are the only
    -- settings a profile reset cannot reach — their storage is their own set().
    -- red under: a predicate that vetoes only the profiles page.
    assertEqual(seen["window.frame.width"], nil,
        "a profile-backed row was written just before the profile was discarded")
    assertEqual(seen["enabled"], nil)
    assertTrue(seen["state.testMode"] ~= nil,
        "the session-only rows still have to be swept row by row")
    assertTrue(seen["state.debugConsole"] ~= nil)
end)

test("Options: a global reset restores window POSITIONS, which no schema row owns", function()
    -- They come back with the rest of the profile now rather than from a
    -- ResetPositions call in afterRestoreAll, which is why this case still holds
    -- with that call gone.
    local inst = T.load()
    local NSi = inst.NS
    for _, w in ipairs(NSi.Database.GetWindows()) do
        w.frame.position = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 400, y = -300 }
    end
    NSi.Helpers.RestoreAllDefaults()
    for _, w in ipairs(NSi.Database.GetWindows()) do
        assertEqual(w.frame.position.point, "CENTER",
            "afterRestoreAll is the only hook that reaches a position")
        assertEqual(w.frame.position.x, 0)
    end
end)

-- ---------------------------------------------------------------------------
-- CreateOptionsPanel's own contract
-- ---------------------------------------------------------------------------

test("Options: CreateOptionsPanel is idempotent", function()
    local inst = T.load()
    local panelsBefore = #inst.NS.Helpers.__panels()
    inst.NS.CreateOptionsPanel()
    assertEqual(#inst.NS.Helpers.__panels(), panelsBefore,
        "a second call would double the RefreshAllPanels fan-out permanently")
end)

test("Options: CreateOptionsPanel runs the schema validator", function()
    local calls = 0
    local inst = T.load({ options = false })
    local real = inst.NS.ValidateSchema
    inst.NS.ValidateSchema = function(...) calls = calls + 1; return real(...) end
    inst.NS.CreateOptionsPanel()
    inst.NS.ValidateSchema = real
    assertEqual(calls, 1,
        "the descriptor's `validate` must reach NS.ValidateSchema; pointed at a Helpers member "
        .. "that does not exist, the check never ran in game at all")
end)

test("Options: AceGUI is resolved once and published for the page builders", function()
    local inst = T.load()
    assertTrue(inst.NS.AceGUI ~= nil,
        "library-stack-§4: resolve once and hand it over, rather than per page")
    assertEqual(inst.NS.AceGUI, inst.mocks.__libs["AceGUI-3.0"])
end)
