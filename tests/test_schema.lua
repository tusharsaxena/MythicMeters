-- tests/test_schema.lua
--
-- settings/Schema.lua's two ideas that are not standard-issue:
--
--   1. THE WINDOW-RELATIVE PATH MODEL (design §8). A `window.`-prefixed path has
--      no window in it. It resolves against the SESSION'S ACTIVE WINDOW, so the
--      panel's picker retargets seventy-odd rows by moving one integer of session
--      state, and `/mm set window.frame.width 300` means "the window I am
--      editing" on the CLI exactly as it does in the panel. The test that matters
--      is therefore not "a path reads a value" but "the SAME path reads a
--      DIFFERENT window's value once the active window moves".
--
--   2. THE COLUMNS CARVE-OUT. `window.columns` is an ordered array, which a path
--      model has no vocabulary for, so it is written WHOLE through the same seam
--      and validated there instead of by a row's `validate`. That validator
--      REPAIRS rather than rejects -- it drops a statistic this build does not
--      have, appends one it gained, and sorts the enabled ones ahead of the
--      disabled ones -- so what is exercised here is both halves: what it fixes
--      silently, and the short list of shapes it genuinely cannot invent an
--      answer for.
--
-- Everything mutates, so every case builds its OWN instance through T.load()
-- rather than sharing one: a suite whose cases can only pass in the order they
-- happen to be declared in is a suite that will fail for the wrong reason later.

local T = _G.MULTIMETERS_TEST
local test = T.test
local assertEqual, assertTrue, assertFalse = T.assertEqual, T.assertTrue, T.assertFalse

--- A loaded addon with TWO windows, and their ids.
local function twoWindows()
    local inst = T.load()
    local NS = inst.NS
    assertEqual(#NS.Database.GetWindows(), 1, "InitDB seeds exactly one window")
    assertTrue(NS.WindowManager:Create("Second"))
    local list = NS.Database.GetWindows()
    assertEqual(#list, 2)
    return inst, list[1].id, list[2].id
end

-- ---------------------------------------------------------------------------
-- The window-relative path model
-- ---------------------------------------------------------------------------

test("Schema: a window path resolves against the session's ACTIVE window", function()
    local inst, first, second = twoWindows()
    local NS = inst.NS

    NS.State.SetActiveWindow(first)
    assertTrue(NS.SetByPath("window.frame.width", 320))
    NS.State.SetActiveWindow(second)
    assertTrue(NS.SetByPath("window.frame.width", 640))

    -- One path, two answers, decided entirely by NS.State.activeWindowId.
    NS.State.SetActiveWindow(first)
    assertEqual(NS.GetSetting("window.frame.width"), 320)
    NS.State.SetActiveWindow(second)
    assertEqual(NS.GetSetting("window.frame.width"), 640)

    -- And the stored tables really are separate, not one table read twice.
    assertEqual(NS.Database.FindWindow(first).frame.width, 320)
    assertEqual(NS.Database.FindWindow(second).frame.width, 640)
end)

test("Schema: a global path is unaffected by which window is active", function()
    local inst, first, second = twoWindows()
    local NS = inst.NS

    NS.State.SetActiveWindow(first)
    assertTrue(NS.SetByPath("enabled", false))
    NS.State.SetActiveWindow(second)
    assertEqual(NS.GetSetting("enabled"), false,
        "`enabled` lives on the profile; moving the picker must not change it")

    assertTrue(NS.SetByPath("enabled", true))
    NS.State.SetActiveWindow(first)
    assertEqual(NS.GetSetting("enabled"), true)
    -- Neither window grew an `enabled` key on the way.
    assertEqual(NS.Database.FindWindow(first).enabled, nil)
    assertEqual(NS.Database.FindWindow(second).enabled, nil)
end)

test("Schema: an unset active window falls back to the FIRST window, never to nil", function()
    -- The CLI has no picker. `/mm set window.frame.width 300` typed on a fresh
    -- login must mean something rather than fail with a message about an internal
    -- pointer the user has never heard of.
    local inst, first = twoWindows()
    local NS = inst.NS
    assertEqual(NS.State.activeWindowId, nil, "nothing has moved the picker yet")

    assertTrue(NS.SetByPath("window.frame.height", 333))
    assertEqual(NS.Database.FindWindow(first).frame.height, 333)
end)

test("Schema: a stale active-window id falls back to the first window", function()
    local inst, first = twoWindows()
    local NS = inst.NS
    NS.State.SetActiveWindow(9999)
    assertEqual(NS.GetSetting("window.frame.width"),
        NS.Database.FindWindow(first).frame.width)
end)

test("Schema: the inverted row stores the negation of what it displays", function()
    local inst = T.load()
    local NS = inst.NS
    -- LibDBIcon owns `minimap.hide`; the checkbox says "Show minimap button".
    assertTrue(NS.SetByPath("minimap.hide", false))
    assertEqual(NS.db.profile.minimap.hide, true, "display false stores hide = true")
    assertEqual(NS.GetSetting("minimap.hide"), false, "and reads back in display terms")
end)

-- ---------------------------------------------------------------------------
-- The single write seam
-- ---------------------------------------------------------------------------

test("SetByPath: refuses a value the row's validate() rejects, and stores nothing", function()
    local inst = T.load()
    local NS = inst.NS
    local before = NS.GetSetting("window.frame.scale")
    local ok, err = NS.SetByPath("window.frame.scale", 9)   -- range is 0.5 .. 2.0
    assertFalse(ok)
    assertEqual(type(err), "string")
    assertEqual(NS.GetSetting("window.frame.scale"), before)
end)

test("SetByPath: refuses a path that is not a row", function()
    local inst = T.load()
    local ok, err = inst.NS.SetByPath("window.frame.wdith", 300)
    assertFalse(ok)
    assertEqual(type(err), "string")
end)

test("SetByPath: fires the row's onChange exactly once, with the value and window id", function()
    local inst, first = twoWindows()
    local NS = inst.NS
    NS.State.SetActiveWindow(first)

    local row = NS.FindSchemaRow("window.visibility.world")
    assertEqual(type(row.onChange), "function", "the visibility rows carry an onChange")

    local original = row.onChange
    local calls, sawValue, sawWindow = 0, nil, nil
    row.onChange = function(v, id) calls = calls + 1; sawValue, sawWindow = v, id end

    local ok = NS.SetByPath("window.visibility.world", true)
    row.onChange = original

    assertTrue(ok)
    assertEqual(calls, 1)
    assertEqual(sawValue, true)
    assertEqual(sawWindow, first, "a window row's onChange is told WHICH window moved")
end)

test("SetByPath: onChange runs AFTER the write, never before", function()
    local inst = T.load()
    local NS = inst.NS
    local row = NS.FindSchemaRow("enabled")
    local original = row.onChange
    local seen
    row.onChange = function() seen = NS.db.profile.enabled end
    NS.SetByPath("enabled", false)
    row.onChange = original
    assertEqual(seen, false,
        "reacting before the write would hand every refresher the OLD value")
end)

test("SetByPath: logs the change exactly ONCE", function()
    local inst = T.load()
    local NS = inst.NS
    local original = NS.Debug
    local lines = {}
    NS.Debug = function(tag, fmt, a, b) lines[#lines + 1] = { tag, fmt, a, b } end
    NS.SetByPath("window.frame.width", 500)
    NS.Debug = original

    assertEqual(#lines, 1,
        "a settings change that appears twice in the log is two changes to a reader")
    assertEqual(lines[1][1], "Set")
    assertEqual(lines[1][3], "window.frame.width", "the format is DEFERRED, not built at the seam")
    assertEqual(lines[1][4], 500)
end)

test("SetByPath: announces CONFIG_CHANGED once, tagged with the row's page and window", function()
    local inst, first = twoWindows()
    local NS = inst.NS
    NS.State.SetActiveWindow(first)

    local seen = {}
    NS:RegisterMessage(NS.Constants.MSG.CONFIG_CHANGED, function(_, payload)
        seen[#seen + 1] = payload
    end)

    assertTrue(NS.SetByPath("window.bars.border", true))
    assertEqual(#seen, 1)
    assertEqual(seen[1].section, "bars", "the section IS the row's page key")
    assertEqual(seen[1].windowId, first)

    -- A global row announces with no window id, because no window moved.
    assertTrue(NS.SetByPath("enabled", false))
    assertEqual(#seen, 2)
    assertEqual(seen[2].section, "general")
    assertEqual(seen[2].windowId, nil)
end)

test("SetByPath: re-syncs open panels IN PLACE, never structurally", function()
    local inst = T.load()
    local NS = inst.NS
    local scalars, structural = 0, 0
    local realScalars = NS.Helpers.RefreshScalars
    local realAll     = NS.Helpers.RefreshAllPanels
    NS.Helpers.RefreshScalars    = function() scalars = scalars + 1 end
    NS.Helpers.RefreshAllPanels  = function() structural = structural + 1 end

    NS.SetByPath("window.rows.height", 20)

    NS.Helpers.RefreshScalars   = realScalars
    NS.Helpers.RefreshAllPanels = realAll

    assertEqual(scalars, 1)
    assertEqual(structural, 0,
        "a structural rebuild would tear the page down under a slider mid-drag")
end)

test("SetByPath: a table value is COPIED in, never stored by reference", function()
    local inst, first, second = twoWindows()
    local NS = inst.NS
    local shared = { r = 0.1, g = 0.2, b = 0.3, a = 0.4 }

    NS.State.SetActiveWindow(first)
    assertTrue(NS.SetByPath("window.bars.customColor", shared))
    NS.State.SetActiveWindow(second)
    assertTrue(NS.SetByPath("window.bars.customColor", shared))

    local a = NS.Database.FindWindow(first).bars.customColor
    local b = NS.Database.FindWindow(second).bars.customColor
    assertTrue(a ~= shared, "the caller's table must not be the stored table")
    assertTrue(a ~= b, "two windows must not share one color table")
    a.r = 0.99
    assertEqual(b.r, 0.1, "editing one window's color edited the other's")
end)

test("ApplyDefault: restores through the same seam, deep-copying a table default", function()
    local inst = T.load()
    local NS = inst.NS
    local row = NS.FindSchemaRow("window.bars.customColor")

    assertTrue(NS.SetByPath("window.bars.customColor", { r = 1, g = 0, b = 0, a = 1 }))
    NS.ApplyDefault(row)

    local stored = NS.GetSetting("window.bars.customColor")
    assertEqual(stored.r, row.default.r)
    assertEqual(stored.a, row.default.a)
    assertTrue(stored ~= row.default,
        "storing the row's own default table would alias every profile onto it")
end)

test("ApplyDefault: round-trips the inverted row back to its SHIPPED stored value", function()
    local inst = T.load()
    local NS = inst.NS
    assertTrue(NS.SetByPath("minimap.hide", false))       -- display false -> stored true
    assertEqual(NS.db.profile.minimap.hide, true)
    NS.ApplyDefault(NS.FindSchemaRow("minimap.hide"))
    assertEqual(NS.db.profile.minimap.hide, false,
        "`default` is the STORED value, so the restore must land on false")
end)

-- ---------------------------------------------------------------------------
-- The columns carve-out
-- ---------------------------------------------------------------------------

local function goodColumns()
    return {
        { stat = "DamageDone",  enabled = true },
        { stat = "HealingDone", enabled = true },
    }
end

--- How many of the stored columns are shown.
local function shownCount(cols)
    local n = 0
    for _, c in ipairs(cols) do
        if c.enabled then n = n + 1 end
    end
    return n
end

test("SetByPath: window.columns repairs any array into the WHOLE catalog", function()
    -- The array used to be the SUBSET the player had assembled. It is the catalog
    -- now -- one entry per statistic, each carrying `enabled` -- because the page
    -- that reads it is a fixed list of blocks you tick rather than a list you add
    -- to, and a page that cannot add a column needs every column already there.
    local inst, first = twoWindows()
    local NS = inst.NS
    local Const = NS.Constants
    NS.State.SetActiveWindow(first)

    local ok, err = NS.SetByPath("window.columns", {
        { stat = "HealingDone", enabled = true },
        { stat = "DamageDone",  enabled = true },
    })
    assertTrue(ok, tostring(err))

    local stored = NS.Database.FindWindow(first).columns
    assertEqual(#stored, #Const.STATS,
        "the stored array IS the catalog now, however short the input was")
    assertEqual(stored[1].stat, "HealingDone", "the caller's order is kept for the enabled ones")
    assertEqual(stored[2].stat, "DamageDone")
    assertTrue(stored[1].enabled)
    assertTrue(stored[2].enabled)
    for i = 3, #stored do
        assertFalse(stored[i].enabled,
            "every statistic the caller did not name arrives disabled, not missing")
    end
    assertEqual(stored[1].width, nil, "width is not part of the shape any more")
    assertEqual(stored[1].showBar, nil, "showBar is not part of the shape any more")
end)

test("SetByPath: window.columns DROPS a statistic this build does not have", function()
    -- The old code STORED an unknown stat and listed it so the player could remove
    -- it. There is no remove button now and the list IS the catalog, so there is
    -- nothing they could do with the row -- self-healing beats surfacing a dead
    -- one.
    local inst, first = twoWindows()
    local NS = inst.NS
    NS.State.SetActiveWindow(first)

    local ok, err = NS.SetByPath("window.columns", {
        { stat = "DamageDone", enabled = true },
        { stat = "FutureStat", enabled = true },
    })
    assertTrue(ok, "an unknown statistic must not fail the whole write: " .. tostring(err))

    local stored = NS.Database.FindWindow(first).columns
    for _, c in ipairs(stored) do
        assertFalse(c.stat == "FutureStat", "the unknown statistic must not be stored")
    end
    assertEqual(#stored, #NS.Constants.STATS)
end)

test("SetByPath: window.columns keeps a repeated statistic's FIRST appearance only", function()
    local inst, first = twoWindows()
    local NS = inst.NS
    NS.State.SetActiveWindow(first)

    assertTrue((NS.SetByPath("window.columns", {
        { stat = "DamageDone",  enabled = true },
        { stat = "HealingDone", enabled = true },
        { stat = "DamageDone",  enabled = false },
    })))

    local stored = NS.Database.FindWindow(first).columns
    local seen = 0
    for _, c in ipairs(stored) do
        if c.stat == "DamageDone" then seen = seen + 1 end
    end
    assertEqual(seen, 1, "two Damage columns show identical numbers twice")
    assertEqual(stored[1].stat, "DamageDone")
    assertTrue(stored[1].enabled,
        "the first appearance wins, so a later duplicate cannot quietly untick it")
end)

test("SetByPath: window.columns stores the enabled ones ahead of the disabled ones", function()
    -- Sink-to-bottom is a STORED invariant rather than something the page
    -- maintains. `/mm set window.columns ...` and a hand-edited SavedVariables
    -- reach this seam without ever drawing a block, and three routes to one shape
    -- is three chances to disagree about it.
    local inst, first = twoWindows()
    local NS = inst.NS
    NS.State.SetActiveWindow(first)

    assertTrue((NS.SetByPath("window.columns", {
        { stat = "DamageDone",  enabled = false },
        { stat = "HealingDone", enabled = true },
        { stat = "Interrupts",  enabled = false },
        { stat = "Dispels",     enabled = true },
    })))

    local stored = NS.Database.FindWindow(first).columns
    assertEqual(stored[1].stat, "HealingDone", "relative order inside a group is the caller's")
    assertEqual(stored[2].stat, "Dispels")

    local sawDisabled = false
    for i, c in ipairs(stored) do
        if not c.enabled then sawDisabled = true end
        if c.enabled then
            assertFalse(sawDisabled,
                "entry " .. i .. " is enabled and follows a disabled one")
        end
    end
end)

test("SetByPath: window.columns REBUILDS the array rather than adopting the caller's", function()
    local inst, first = twoWindows()
    local NS = inst.NS
    NS.State.SetActiveWindow(first)

    local mine = goodColumns()
    mine[1].smuggled = "keep me out of the profile"
    assertTrue(NS.SetByPath("window.columns", mine))

    local stored = NS.Database.FindWindow(first).columns
    assertTrue(stored ~= mine, "the stored array must not be the caller's table")
    assertTrue(stored[1] ~= mine[1], "nor any of its entries")
    assertEqual(stored[1].smuggled, nil, "an extra key is dropped, not persisted")

    mine[1].stat = "Deaths"
    assertEqual(stored[1].stat, "DamageDone", "the caller can no longer reach into the profile")
end)

test("SetByPath: window.columns takes the same log, message and refresh a scalar takes", function()
    local inst, first = twoWindows()
    local NS = inst.NS
    NS.State.SetActiveWindow(first)

    local logs, messages, scalars = 0, {}, 0
    local realDebug, realScalars = NS.Debug, NS.Helpers.RefreshScalars
    NS.Debug = function() logs = logs + 1 end
    NS.Helpers.RefreshScalars = function() scalars = scalars + 1 end
    NS:RegisterMessage(NS.Constants.MSG.CONFIG_CHANGED, function(_, payload)
        messages[#messages + 1] = payload
    end)

    assertTrue(NS.SetByPath("window.columns", goodColumns()))

    NS.Debug = realDebug
    NS.Helpers.RefreshScalars = realScalars

    assertEqual(logs, 1, "a carve-out that announced nothing would be a silent second seam")
    assertEqual(#messages, 1)
    assertEqual(messages[1].section, "columns")
    assertEqual(messages[1].windowId, first)
    assertEqual(scalars, 1)
end)

test("SetByPath: window.columns is readable through the generic resolver", function()
    local inst, first = twoWindows()
    local NS = inst.NS
    NS.State.SetActiveWindow(first)
    assertTrue(NS.SetByPath("window.columns", goodColumns()))

    local read = NS.GetSetting("window.columns")
    assertEqual(type(read), "table")
    assertEqual(#read, #NS.Constants.STATS)
    assertEqual(read[1].stat, "DamageDone")
    assertEqual(shownCount(read), 2)
end)

-- Each refusal, one case per rule, because "it refused" without saying which rule
-- fired passes just as happily on a typo in the fixture.
--
-- THE LIST IS SHORTER THAN IT WAS, and that is the change rather than a gap in
-- coverage. An unknown statistic, a repeat, a width outside its range and a
-- non-boolean show-bar flag were four separate refusals; the first two are
-- repaired now and the last two name fields that no longer exist. What is left is
-- what the normalizer genuinely cannot invent an answer for.

local REFUSALS = {
    { "a non-table value",            "not a table" },
    { "an empty array",               {} },
    { "a gap or a string key",        { { stat = "DamageDone", enabled = true },
                                        extra = true } },
    { "an entry that is not a table", { "DamageDone" } },
    { "an array with nothing enabled",
                                      { { stat = "DamageDone", enabled = false } } },
    { "an array whose every statistic this build dropped",
                                      { { stat = "Nonsense", enabled = true } } },
}

for _, case in ipairs(REFUSALS) do
    local label, value = case[1], case[2]
    test("SetByPath: window.columns REFUSES " .. label .. ", with a message", function()
        local inst, first = twoWindows()
        local NS = inst.NS
        NS.State.SetActiveWindow(first)
        local before = NS.Database.FindWindow(first).columns

        local ok, err = NS.SetByPath("window.columns", value)
        assertFalse(ok, "the write was accepted")
        assertEqual(type(err), "string", "a refusal with no message tells the user nothing")
        assertTrue(#err > 0)
        assertEqual(NS.Database.FindWindow(first).columns, before,
            "a refused write must leave the stored array untouched")
    end)
end

test("SetByPath: a path INTO the column array is refused by name", function()
    local inst = T.load()
    local ok, err = inst.NS.SetByPath("window.columns.2.enabled", true)
    assertFalse(ok)
    assertEqual(type(err), "string")
    -- The ordinal moves on the next toggle or drag, so a stored reference to it is
    -- wrong by the next edit. It must not fall through to "not a row".
    assertTrue(err:find("Columns page", 1, true) ~= nil,
        "the refusal should point at the page that CAN do it, got: " .. err)
end)

test("Schema: NS.NormalizeColumns is published for the migration ladder", function()
    -- core/Database.lua's migrations[10] needs this rule and cannot reach a local
    -- in a file eighteen TOC entries later. A private copy there is how the
    -- migration and the write seam end up disagreeing about the shape.
    local inst = T.load()
    local NS = inst.NS
    assertEqual(type(NS.NormalizeColumns), "function")

    local out = NS.NormalizeColumns({ { stat = "Deaths", enabled = true } })
    assertEqual(type(out), "table")
    assertEqual(#out, #NS.Constants.STATS)
    assertEqual(out[1].stat, "Deaths")
    assertTrue(out[1].enabled)

    assertEqual(NS.NormalizeColumns({}), nil, "it refuses what it cannot repair")
end)

-- ---------------------------------------------------------------------------
-- The Frame page's shape
-- ---------------------------------------------------------------------------

test("Schema: a `hidden` row is writable and listable but draws no control", function()
    -- `frame.minimised` is per-window STATE, not a preference: the header's
    -- minimise control writes it and a window left collapsed comes back
    -- collapsed. As a checkbox it duplicated that control on a page you have to
    -- open to reach. It cannot simply be DELETED, though -- NS.SetByPath refuses
    -- a path with no row, and the minimise control writes through that seam
    -- precisely because it is what publishes CONFIG_CHANGED.
    -- red under: dropping the row, or dropping SchemaForPage's `hidden` filter.
    local inst = T.load()
    local NS = inst.NS

    local found
    for _, row in ipairs(NS.Schema) do
        if row.path == "window.frame.minimised" then found = row end
    end
    assertTrue(found ~= nil, "the path must still resolve, or minimise cannot write")
    assertEqual(found.hidden, true)

    for _, row in ipairs(NS.SchemaForPage("header")) do
        assertTrue(row.path ~= "window.frame.minimised",
            "a state row was rendered as a setting")
    end

    assertTrue((NS.SetByPath("window.frame.minimised", true)),
        "the seam must still accept it")
end)

test("Schema: the export choices are hidden from the panel but NOT from the seam", function()
    -- The modal's own three controls are the ones a player uses, so a second
    -- copy on General was a settings group restating a control met elsewhere --
    -- and a second chance for the two to disagree about what is selected.
    --
    -- HIDDEN RATHER THAN DELETED, and the difference is which seam writes them:
    -- the modal writes through NS.SetByPath, which REFUSES a path with no row, so
    -- deleting these would drop every export choice onto the degraded fallback
    -- and take `/mm set export.channel` with it.
    -- red under: deleting the rows, or leaving one of the three visible.
    local inst = T.load()
    local NS = inst.NS

    for _, path in ipairs({ "export.channel", "export.whisperTo", "export.lines" }) do
        local row = NS.FindSchemaRow(path)
        assertTrue(row ~= nil, path .. " lost its row, and with it the write seam")
        assertTrue(row.hidden, path .. " is still drawn on the panel")
    end

    for _, row in ipairs(NS.SchemaForPage("general")) do
        assertTrue(row.path:find("^export%.") == nil,
            "an export row is still rendered on General: " .. row.path)
    end

    -- And the seam still takes a write, which is the whole reason they stayed.
    assertTrue(NS.SetByPath("export.channel", "PARTY"))
    assertEqual(NS.GetSetting("export.channel"), "PARTY")
end)

test("The meta colour mode sets every bar and header in the window at once", function()
    -- Seven surfaces each carry a colour mode of their own -- the bar and its
    -- background, both header strips, the column strip's background and both of
    -- the tooltip's bars -- which is right when a player wants one of them
    -- different and tedious when they want them all the same.
    --
    -- The title bar's BACKGROUND is deliberately not among them: it is one strip
    -- over the whole window, so a per-statistic mode could only paint it the sort
    -- column's colour, which is on screen twice already. It kept its colour
    -- picker and lost the dropdown.
    -- red under: a path dropped from COLOR_MODE_PATHS.
    local inst = T.load()
    local NS = inst.NS

    assertTrue(NS.SetByPath("window.colorMode", "stat"))

    for _, path in ipairs({
        "window.bars.colorMode", "window.bars.bgColorMode",
        "window.columnHeader.colorMode", "window.columnHeader.bgColorMode",
        "window.tooltip.barColorMode", "window.tooltip.barBgColorMode",
    }) do
        assertEqual(NS.GetSetting(path), "stat", path .. " did not follow the meta")
    end
end)

test("The meta colour mode leaves both TEXT surfaces alone", function()
    -- Text is drawn ON TOP OF a surface the meta broadcasts to. Sending "per
    -- statistic" to the whole window painted the Damage number in the Damage
    -- colour over a Damage-coloured bar, and the tooltip's text in the sorted
    -- stat's colour over bars already carrying it -- the one place where making
    -- every surface agree is what makes the text stop being readable.
    -- red under: window.text.colorMode or window.tooltip.colorMode back in
    -- COLOR_MODE_PATHS.
    local inst = T.load()
    local NS = inst.NS

    local before = {
        text    = NS.GetSetting("window.text.colorMode"),
        tooltip = NS.GetSetting("window.tooltip.colorMode"),
    }

    assertTrue(NS.SetByPath("window.colorMode", "stat"))

    assertEqual(NS.GetSetting("window.text.colorMode"), before.text,
        "the grid's numbers must not follow the meta onto the bars behind them")
    assertEqual(NS.GetSetting("window.tooltip.colorMode"), before.tooltip,
        "the tooltip's text must not follow the meta onto its own bars")

    -- Still its own setting, so a player who WANTS the match can ask for it.
    assertTrue(NS.SetByPath("window.text.colorMode", "stat"))
    assertEqual(NS.GetSetting("window.text.colorMode"), "stat")
end)

test("The other three meta rows broadcast their own kind of setting", function()
    -- Same bargain as the colour mode: the individual rows all still exist, and
    -- each meta sets every surface that has one of its kind.
    -- red under: a path dropped from any of the three lists.
    local inst = T.load()
    local NS = inst.NS
    inst.mocks.__media.statusbar["Ka0s Bar"] = "Interface\\Test\\Bar"
    inst.mocks.__media.font["Ka0s Font"] = "Interface\\Test\\Font"

    assertTrue(NS.SetByPath("window.barTexture", "Ka0s Bar"))
    assertEqual(NS.GetSetting("window.bars.texture"), "Ka0s Bar")
    assertEqual(NS.GetSetting("window.tooltip.barTexture"), "Ka0s Bar")

    assertTrue(NS.SetByPath("window.font", "Ka0s Font"))
    for _, path in ipairs({ "window.text.font", "window.header.font",
                            "window.columnHeader.font", "window.tooltip.font" }) do
        assertEqual(NS.GetSetting(path), "Ka0s Font", path .. " did not follow the meta")
    end

    assertTrue(NS.SetByPath("window.fontOutline", "THICKOUTLINE"))
    -- The tooltip's key is `fontOutline`, not `outline`, which is why the fan-out
    -- is a list of PATHS rather than a suffix assumed to be shared.
    for _, path in ipairs({ "window.text.outline", "window.header.outline",
                            "window.columnHeader.outline", "window.tooltip.fontOutline" }) do
        assertEqual(NS.GetSetting(path), "THICKOUTLINE", path .. " did not follow the meta")
    end
end)

test("A surface changed after the broadcast keeps its own answer", function()
    -- The meta is a SHORTCUT, not a source of truth: a player who then changes one
    -- surface has changed one surface, and the meta does not fight them for it.
    local inst = T.load()
    local NS = inst.NS

    NS.SetByPath("window.colorMode", "class")
    NS.SetByPath("window.text.colorMode", "custom")

    assertEqual(NS.GetSetting("window.text.colorMode"), "custom")
    assertEqual(NS.GetSetting("window.bars.colorMode"), "class",
        "changing one surface reached the others")
end)

test("The Frame page's Defaults button does NOT broadcast", function()
    -- A per-page reset walks that page's rows through ApplyDefault. The meta row
    -- lives on Frame and writes ten rows on three other pages, so a broadcast
    -- from there would make the Frame page's Defaults button silently reset
    -- settings it has no business reaching.
    -- red under: dropping the restore guard from broadcastColorMode.
    local inst = T.load()
    local NS = inst.NS

    NS.SetByPath("window.text.colorMode", "stat")
    NS.Helpers.RestoreDefaults("frame", nil)

    assertEqual(NS.GetSetting("window.text.colorMode"), "stat",
        "the Frame page's reset reached the Bars page")
    assertEqual(NS.GetSetting("window.colorMode"), "custom",
        "the meta itself must still be restored")
end)

-- ---------------------------------------------------------------------------
-- The page/tab partition
-- ---------------------------------------------------------------------------

--- Every page's tabs, in the order the strip draws them, and how many controls each holds.
--- Stated here rather than derived from the schema the assertion reads, so a row that drifts
--- into another tab is a NAMED failure rather than a shorter list that still agrees with
--- itself.
---
--- VISIBLE rows only, because NS.SchemaForPage filters `hidden` and this table describes what
--- the panel DRAWS. So General has no Export tab -- its three export rows are hidden -- and
--- Window buttons counts four, not the five rows filed under it. The case below this one is
--- what keeps those hidden rows honest.
local PARTITION = {
    general    = { { "General", 3 }, { "Data", 2 }, { "Maintenance", 1 } },
    windows    = { { "Window", 1 } },
    frame      = { { "Size and position", 6 }, { "Rows", 4 }, { "Row behavior", 4 },
                   { "Background and border", 4 }, { "Behavior", 2 }, { "All surfaces", 4 } },
    header     = { { "Title bar", 4 }, { "Title text", 5 }, { "Window buttons", 4 },
                   { "Meter buttons", 4 }, { "Button style", 6 } },
    bars       = { { "Bar", 5 }, { "Bar background", 3 }, { "Bar border", 4 },
                   { "Text content", 5 }, { "Text style", 7 }, { "Icons", 3 } },
    tooltip    = { { "Tooltip", 5 }, { "Contents", 5 }, { "Bar", 5 },
                   { "Bar background", 3 }, { "Bar border", 3 }, { "Text", 6 } },
    visibility = { { "Where to show this window", 7 }, { "When to hide this window", 8 },
                   { "Combat", 2 } },
    columns    = { { "Header text", 6 }, { "Header background", 2 } },
}

test("Schema: every page's tabs are the designed ones, in order, at the designed size",
function()
    -- red under: moving a row to another tab, reordering a group, or letting a tab drift
    -- above six controls without the design saying so.
    local inst = T.load()
    local NS, L = inst.NS, inst.NS.L

    for page, expected in pairs(PARTITION) do
        local order, counts, seen = {}, {}, {}
        for _, row in ipairs(NS.SchemaForPage(page)) do
            local g = row.group or "?"
            if not seen[g] then
                seen[g] = true
                order[#order + 1] = g
            end
            counts[g] = (counts[g] or 0) + 1
        end

        local wantNames = {}
        for i, pair in ipairs(expected) do wantNames[i] = L[pair[1]] end
        assertEqual(table.concat(order, " | "), table.concat(wantNames, " | "),
            page .. ": tab order")

        for _, pair in ipairs(expected) do
            assertEqual(counts[L[pair[1]]], pair[2],
                page .. " / " .. pair[1] .. ": control count")
        end
    end
end)

test("Schema: no tab holds fewer than two controls", function()
    -- A tab over one control is a click that reveals a single checkbox. General's Maintenance
    -- and Windows' Window are the two exemptions and they are exempted BY NAME: each is a
    -- single stored row sharing its tab with BESPOKE commands that have no stored value and
    -- cannot be rows and cannot be counted here -- Maintenance's two reset buttons, Window's
    -- picker and create/duplicate/delete buttons.
    -- red under: a tab losing rows until one is left, or a new one-row section.
    local inst = T.load()
    local NS, L = inst.NS, inst.NS.L
    local EXEMPT = { [L["Maintenance"]] = true, [L["Window"]] = true }

    local counts, pageOf = {}, {}
    for _, row in ipairs(NS.Schema) do
        if row.page and row.group then
            counts[row.group] = (counts[row.group] or 0) + 1
            pageOf[row.group] = row.page
        end
    end
    for group, n in pairs(counts) do
        if not EXEMPT[group] then
            assertTrue(n >= 2, pageOf[group] .. " / " .. group .. " holds only " .. n)
        end
    end
end)

test("Schema: a hidden row is filed under a tab that exists, and draws nothing", function()
    -- A hidden row still carries a page and a group -- that is what keeps it writable through
    -- NS.SetByPath, listable in `/mm list` and comparable by the schema-vs-defaults validator
    -- while missing the panel. It cannot produce a phantom tab, because SchemaForPage filters
    -- it before the strip is built; what it CAN do is lose its page and quietly drop out of
    -- `/mm list`, which is the half worth pinning.
    -- red under: dropping page or group from a hidden row "since it never draws".
    local inst = T.load()
    local NS = inst.NS

    local hidden, drawn = 0, {}
    for _, row in ipairs(NS.Schema) do
        if row.hidden then
            hidden = hidden + 1
            assertTrue(row.page ~= nil and row.group ~= nil,
                row.path .. " is hidden but carries no page or group")
        end
    end
    assertEqual(hidden, 4, "four rows are hidden: frame.minimised and the three export choices")

    -- And the other half: no tab the strip actually draws is empty.
    for _, page in ipairs({ "general", "windows", "frame", "header", "bars", "tooltip",
                            "visibility", "columns" }) do
        for _, row in ipairs(NS.SchemaForPage(page)) do
            drawn[row.group or "?"] = (drawn[row.group or "?"] or 0) + 1
        end
    end
    for group, n in pairs(drawn) do
        assertTrue(n >= 1, group .. " is a drawn tab with nothing in it")
    end
end)

test("Schema: every tab name and row label is a localized string, not a bare literal", function()
    -- A tab label is now the most visible string on a page -- it is the heading AND the control
    -- you click -- and a group declared as a raw literal is a page that cannot be translated
    -- past its own headings. `L` answers its own key when a translation is missing, so the test
    -- is that the key EXISTS in the locale table rather than that the answer differs.
    --
    -- LABELS ARE WALKED TOO, and that is what this case is really for: a regroup moves `group`
    -- and `label` in two different fields, and a retirement checked only the first can retire a
    -- key still carrying the second -- exactly what happened to "Bar background color", which
    -- retired as a group name while still labelling window.bars.bgColor and
    -- window.tooltip.barBgColor. NOT `desc`: several desc strings were already missing their key
    -- before this case existed, and asserting on them here would fail this suite on a pre-existing
    -- gap this case is not the one to fix.
    -- red under: adding a group as "Bar border" instead of L["Bar border"], or retiring a locale
    -- key that is still a row's label.
    local inst = T.load()
    local NS = inst.NS
    local missing = {}
    for _, row in ipairs(NS.Schema) do
        if row.group and rawget(NS.L, row.group) == nil then
            missing[#missing + 1] = "group: " .. row.group
        end
        if row.label and rawget(NS.L, row.label) == nil then
            missing[#missing + 1] = row.path .. " label: " .. row.label
        end
    end
    table.sort(missing)
    assertEqual(table.concat(missing, ", "), "",
        "these strings are not in locales/enUS.lua")
end)

test("Schema: the active tab is session state and has no home in the schema", function()
    -- options-ui-§13: a stored tab is UI position masquerading as a setting. It would make one
    -- page look different to two characters on one account for a reason nobody asked for, and
    -- it turns a cosmetic default into a migration the day the sections are renamed.
    -- red under: adding an activeTab row "so /mm can reach it", which is the argument that
    -- correctly justifies the sessionOnly rows and does not justify this one.
    local inst = T.load()
    for _, row in ipairs(inst.NS.Schema) do
        assertFalse(row.path:find("activeTab") and true or false,
            "the active tab reached the schema: " .. row.path)
    end
end)

test("Schema: the column header strip is styled on the page where columns are chosen",
function()
    -- It LABELS the columns, and it spent three releases as the third group of a 31-control
    -- Header page. The paths stay under window.columnHeader.* -- a row's page is where it is
    -- edited and its path is where it is stored, and the two are allowed to disagree.
    -- red under: moving the group back to header, or renaming the paths to match the page.
    local inst = T.load()
    local NS = inst.NS

    local onColumns = 0
    for _, row in ipairs(NS.SchemaForPage("columns")) do
        onColumns = onColumns + 1
        assertTrue(row.path:find("^window%.columnHeader%."),
            row.path .. " is on the Columns page but is not a column-header setting")
    end
    assertEqual(onColumns, 8, "all eight moved, not some of them")

    for _, row in ipairs(NS.SchemaForPage("header")) do
        assertFalse(row.path:find("^window%.columnHeader%.") and true or false,
            "the Header page kept a column-header row: " .. row.path)
    end
end)


test("Schema: the header controls are EDITED on Header and STORED under frame", function()
    -- A row's page is where it is edited; its path is where it is stored, and the two are
    -- allowed to disagree. Every one of these draws a control into the title bar, so a player
    -- looks for them under Header -- but they are stored at `window.frame.*`, and renaming the
    -- keys for symmetry would migrate every saved profile for a tidiness nobody can see.
    -- red under: moving the group back to Frame, or renaming the paths to match the page.
    local inst = T.load()
    local NS, L = inst.NS, inst.NS.L
    local TABS = { [L["Window buttons"]] = true, [L["Meter buttons"]] = true,
                   [L["Button style"]] = true }

    local n = 0
    for _, row in ipairs(NS.Schema) do
        if row.page == "header" and TABS[row.group] then
            n = n + 1
            assertTrue(row.path:find("^window%.frame%.") ~= nil,
                row.path .. " is a header control and must still be stored under frame")
        end
    end
    -- Exactly 15: Window buttons (close/showMinimise/showLock/showSettings, plus the hidden
    -- `window.frame.minimised`) + Meter buttons (4) + Button style (6). Walked over NS.Schema,
    -- not SchemaForPage, so the hidden row counts.
    assertEqual(n, 15, "the whole set moved, not one row of it")
end)


test("Schema: every group on every page is CONTIGUOUS, or a heading prints twice", function()
    -- Group headings are emitted when `group` CHANGES between consecutive rows,
    -- so a row filed under a group that has already been left prints that
    -- heading a second time further down the page. Moving a group between pages
    -- -- the header controls, from Frame to Header -- is exactly the edit that
    -- breaks this, and it can break the page it LEFT as well as the one it
    -- joined, which is why this walks every page rather than only Frame.
    local inst = T.load()
    local pages = {}
    for _, row in ipairs(inst.NS.Schema) do
        if row.page then pages[row.page] = true end
    end

    for page in pairs(pages) do
        local seen, previous = {}, nil
        for _, row in ipairs(inst.NS.SchemaForPage(page)) do
            local group = row.group or ""
            if group ~= previous then
                assertFalse(seen[group] or false,
                    page .. ": group returned after being left: " .. tostring(group))
                seen[group] = true
                previous = group
            end
        end
    end
end)

test("Schema: every LSM border setting is one this suite knows honours \"None\"", function()
    -- "None" is LSM's own name for the empty border, and it has to mean NO EDGE on
    -- every surface that offers it. The window frame did not: its resolver fell
    -- back to the library's own edge on anything it could not fetch, and treated a
    -- deliberate "None" as a failed fetch.
    --
    -- This case does not re-test the rendering -- each surface has its own case
    -- for that, named below. It enumerates the border settings, so a THIRD one
    -- added later cannot quietly ship without someone checking it behaves like
    -- these two.
    -- red under: adding an LSM30_Border row without a "None" case behind it.
    local COVERED = {
        -- path -> the case that proves this surface honours "None"
        ["window.frame.borderStyle"] =
            "test_window.lua: Border style None draws NO edge, whatever the library's own is",
        ["window.tooltip.barBorderStyle"] =
            "test_tooltip.lua: A bar border is applied when asked and cleared off the POOLED line when not",
        ["window.bars.borderStyle"] =
            "test_row.lua: Border style None keeps the cheap flat outline and puts no backdrop on a cell",
    }

    local inst = T.load()
    local uncovered = {}
    for _, row in ipairs(inst.NS.Schema) do
        if row.dialogControl == "LSM30_Border" and not COVERED[row.path] then
            uncovered[#uncovered + 1] = row.path
        end
    end
    assertEqual(#uncovered, 0,
        "border settings with no \"None\" case: " .. table.concat(uncovered, ", "))

    -- And the reverse, so a path that is renamed or removed does not leave this
    -- list quietly claiming coverage of something that no longer exists.
    local present = {}
    for _, row in ipairs(inst.NS.Schema) do present[row.path] = true end
    for path in pairs(COVERED) do
        assertTrue(present[path], "this list names a row that is gone: " .. path)
    end
end)

-- ---------------------------------------------------------------------------
-- Every text surface offers the same four controls
-- ---------------------------------------------------------------------------

test("Schema: every text surface offers face, outline, shadow and colour", function()
    -- FOUR SURFACES DRAW TEXT and they used to offer different subsets of the
    -- same controls: the cell text had a shadow and the other three did not, and
    -- none of them could take a class colour. A player styling a window had to
    -- discover which of the four had grown which control.
    --
    -- The table is the contract. A fifth surface, or a fifth control, is a row
    -- added here and then made to pass -- which is the point: it fails until the
    -- surface actually offers it.
    --
    -- THE CLASS-COLOUR CHECKBOX BECAME A THREE-WAY MODE on all four at once, and
    -- "at once" is the property this case is really defending: class / per-
    -- statistic / custom answers a question the checkbox could only answer two
    -- thirds of, and a surface left on the old boolean would be the one a player
    -- discovers by finding it missing.
    -- red under: dropping any row below, on any surface.
    local SURFACES = {
        { label = "Cell text",      prefix = "window.text.",
          font = "font", outline = "outline", shadow = "shadow",
          color = "color", colorMode = "colorMode" },
        -- NO colorMode. The Frame header is the one text surface with a colour
        -- picker and no mode beside it: the title bar is one strip over the whole
        -- window, so "per statistic" could only ever paint it the sort column's
        -- colour and "class" only the local player's, and it is about neither --
        -- it names the window.
        { label = "Frame header",   prefix = "window.header.",
          font = "font", outline = "outline", shadow = "shadow",
          color = "color" },
        { label = "Column headers", prefix = "window.columnHeader.",
          font = "font", outline = "outline", shadow = "shadow",
          color = "color", colorMode = "colorMode" },
        -- The tooltip's keys carry a `font` prefix of their own, which is why
        -- this is a table of names rather than four suffixes assumed to be equal.
        { label = "Tooltip text",   prefix = "window.tooltip.",
          font = "font", outline = "fontOutline", shadow = "fontShadow",
          color = "textColor", colorMode = "colorMode" },
    }

    local inst = T.load()
    local byPath = {}
    for _, row in ipairs(inst.NS.Schema) do byPath[row.path] = row end

    local missing = {}
    for _, surface in ipairs(SURFACES) do
        local function need(control, key, wantType)
            local path = surface.prefix .. key
            local row = byPath[path]
            if not row then
                missing[#missing + 1] = surface.label .. " has no " .. control ..
                    " (" .. path .. ")"
            elseif row.type ~= wantType then
                missing[#missing + 1] = path .. " is a " .. tostring(row.type) ..
                    ", expected " .. wantType
            end
            return row
        end

        -- The face is a MEDIA row, not a free string: it has to be the LSM
        -- picker, or "font selector" is an edit box you can type a typo into.
        local face = need("font selector", surface.font, "string")
        if face then
            assertEqual(face.dialogControl, "LSM30_Font",
                surface.label .. "'s font is not the LSM picker")
        end

        -- The outline is a DROPDOWN over one shared value set, so the four
        -- surfaces cannot offer different outlines from each other.
        local outline = need("outline dropdown", surface.outline, "string")
        if outline then
            assertTrue(type(outline.values) == "table",
                surface.label .. "'s outline has no value list")
            for _, key in ipairs({ "NONE", "OUTLINE", "THICKOUTLINE" }) do
                assertTrue(outline.values[key] ~= nil,
                    surface.label .. "'s outline is missing " .. key)
            end
        end

        need("shadow checkbox", surface.shadow, "bool")
        need("colour picker", surface.color, "color")

        -- THREE MODES, THE SAME THREE, ON EVERY SURFACE THAT HAS ONE. A surface
        -- offering a SUBSET is the drift this table exists to catch: `stat` means
        -- a different statistic per surface, but a surface that offers a mode at
        -- all has to offer all three of them.
        --
        -- Having no mode is a different thing entirely and is not drift -- the
        -- Frame header deliberately has none, because neither `class` nor `stat`
        -- can say anything true about one strip that names the whole window. So
        -- the check is keyed on the table declaring a mode, and the day someone
        -- adds one back it starts applying again on its own.
        local mode = surface.colorMode
            and need("colour mode dropdown", surface.colorMode, "string")
        if mode then
            assertTrue(type(mode.values) == "table",
                surface.label .. "'s colour mode has no value list")
            for _, key in ipairs({ "class", "stat", "custom" }) do
                assertTrue(mode.values[key] ~= nil,
                    surface.label .. "'s colour mode is missing " .. key)
            end
            assertTrue(mode.values.none == nil,
                surface.label .. " offers 'none', which is text nobody can read")
        end
    end

    assertEqual(#missing, 0, table.concat(missing, "; "))
end)

-- ---------------------------------------------------------------------------
-- "Reset all settings" IS a profile reset
-- ---------------------------------------------------------------------------

test("RestoreAllDefaults resets EVERY window, not just the selected one", function()
    -- Every `window.` path resolves against ONE window -- whichever
    -- NS.State.activeWindowId names -- which is right for a panel click and for
    -- `/mm set`, and was wrong for the global sweep: the library walks the schema
    -- once, so "Reset all settings" reset the window you had selected and left
    -- the others exactly as they were.
    -- red under: afterRestoreAll going back to a per-row sweep.
    local inst, first = twoWindows()
    local NS = inst.NS

    for _, w in ipairs(NS.Database.GetWindows()) do
        w.frame.width = 999
        w.text.size   = 30
    end

    NS.State.SetActiveWindow(first)
    NS.Helpers.RestoreAllDefaults()

    for _, w in ipairs(NS.Database.GetWindows()) do
        assertEqual(w.frame.width, 694, "window " .. w.id .. " kept its width")
        assertEqual(w.text.size, 11, "window " .. w.id .. " kept its font size")
    end
end)

test("RestoreAllDefaults is the equivalent of a NEW PROFILE", function()
    -- The requirement, stated plainly: it deletes the extra windows rather than
    -- restyling them, and what comes back is one shipped window -- the same thing
    -- Profiles -> Reset Profile gives, because it IS that call.
    -- red under: afterRestoreAll restyling windows in place instead of handing
    -- the profile to AceDB.
    local inst = twoWindows()
    local NS = inst.NS
    assertEqual(#NS.Database.GetWindows(), 2)

    for _, w in ipairs(NS.Database.GetWindows()) do
        w.name        = "Renamed " .. w.id
        w.frame.width = 999
        w.columns     = { { stat = "Deaths", enabled = true } }
    end

    NS.Helpers.RestoreAllDefaults()

    local after = NS.Database.GetWindows()
    assertEqual(#after, 1, "the extra window survived a reset that means 'start over'")
    assertEqual(after[1].name, "Multi Meters #1", "the shipped name is what a new profile has")
    assertEqual(after[1].frame.width, 694)
    assertEqual(#after[1].columns, #NS.DefaultWindow(1).columns,
        "the column array is not a schema row, and only a profile reset reaches it")
end)

test("RestoreAllDefaults leaves the profile LIST alone", function()
    -- The rule the Profiles veto has always been about: resetting a profile is
    -- not deleting the player's profiles. `db:ResetProfile` empties the ACTIVE
    -- profile and touches no other, which is exactly the line to hold.
    -- red under: reaching for DeleteProfile, or resetting every profile.
    local inst = T.load()
    local NS = inst.NS
    NS.db:SetProfile("Spare")
    NS.db:SetProfile("Default")
    local before = #NS.db:GetProfiles()
    assertTrue(before >= 2, "the fixture needs a second profile to prove anything")

    NS.Helpers.RestoreAllDefaults()

    assertEqual(#NS.db:GetProfiles(), before, "a reset deleted a profile")
    assertEqual(NS.db:GetCurrentProfile(), "Default", "a reset switched profile")
end)

test("A profile reset rebuilds through the ONE message, not by direct calls", function()
    -- OnProfileReset lands on core/Database.lua's OnProfileChanged, which runs the
    -- migrations, re-seeds through SeedWindows and publishes PROFILE_CHANGED --
    -- and every window, the open panel and the aggregator's caches rebuild off
    -- that one message, exactly as they do for a profile switch
    -- (architecture-§4). A reset that emptied the profile without it would leave
    -- every live window drawing the settings that are no longer there.
    -- red under: afterRestoreAll emptying the profile itself rather than handing
    -- it to db:ResetProfile.
    --
    -- NOT red under `db:ResetProfile(nil, true)`, the real library's
    -- suppress-callbacks form: the harness's AceDB fires regardless of its
    -- arguments, so that mutation passes here and would break in the client.
    -- Recorded rather than worked around -- the fake is the vendored kit's.
    local inst = T.load()
    local NS = inst.NS

    local seen = 0
    local target = NS.NewBusTarget and NS.NewBusTarget()
    if target and target.RegisterMessage then
        target:RegisterMessage(NS.Const.MSG.PROFILE_CHANGED, function() seen = seen + 1 end)
    end

    NS.Helpers.RestoreAllDefaults()
    assertTrue(seen > 0, "PROFILE_CHANGED was not published, so nothing rebuilt")
end)
