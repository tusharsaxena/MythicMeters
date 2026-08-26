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
--      and validated there instead of by a row's `validate`. That validation is
--      the only thing standing between a hand-edited SavedVariables and a
--      renderer that indexes `stat`, `width` and `showBar` without re-checking
--      any of them, so every refusal it can make is exercised here.
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
        { stat = "DamageDone",  width = 92, showBar = true },
        { stat = "HealingDone", width = 80, showBar = false },
    }
end

test("SetByPath: window.columns ACCEPTS a well-formed ordered array and stores it", function()
    local inst, first = twoWindows()
    local NS = inst.NS
    NS.State.SetActiveWindow(first)

    local ok, err = NS.SetByPath("window.columns", goodColumns())
    assertTrue(ok, tostring(err))

    local stored = NS.Database.FindWindow(first).columns
    assertEqual(#stored, 2)
    assertEqual(stored[1].stat, "DamageDone")
    assertEqual(stored[1].width, 92)
    assertEqual(stored[1].showBar, true)
    assertEqual(stored[2].stat, "HealingDone")
    assertEqual(stored[2].showBar, false)
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

    mine[1].width = 999
    assertEqual(stored[1].width, 92, "the caller can no longer reach into the profile")
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
    assertEqual(#read, 2)
    assertEqual(read[1].stat, "DamageDone")
end)

-- Each refusal, one case per rule, because "it refused" without saying which rule
-- fired passes just as happily on a typo in the fixture.

local REFUSALS = {
    { "a non-table value",            "not a table" },
    { "an empty array",               {} },
    { "a gap or a string key",        { { stat = "DamageDone", width = 92, showBar = true },
                                        extra = true } },
    { "an entry that is not a table", { "DamageDone" } },
    { "a statistic this build does not have",
                                      { { stat = "Nonsense", width = 92, showBar = true } } },
    { "the same statistic twice",     { { stat = "DamageDone", width = 92, showBar = true },
                                        { stat = "DamageDone", width = 92, showBar = true } } },
    { "a width below the slider's floor",
                                      { { stat = "DamageDone", width = 23, showBar = true } } },
    { "a width above the slider's ceiling",
                                      { { stat = "DamageDone", width = 241, showBar = true } } },
    { "a non-numeric width",          { { stat = "DamageDone", width = "92", showBar = true } } },
    { "a NaN width",                  { { stat = "DamageDone", width = 0 / 0, showBar = true } } },
    { "a show-bar flag that is not a boolean",
                                      { { stat = "DamageDone", width = 92, showBar = 1 } } },
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
    local ok, err = inst.NS.SetByPath("window.columns.2.width", 120)
    assertFalse(ok)
    assertEqual(type(err), "string")
    -- The ordinal moves on the next add, remove or reorder, so a stored reference
    -- to it is wrong by the next edit. It must not fall through to "not a row".
    assertTrue(err:find("Columns page", 1, true) ~= nil,
        "the refusal should point at the page that CAN do it, got: " .. err)
end)

test("SetByPath: the columns validator agrees with the width slider's own range", function()
    -- settings/Columns.lua builds its slider with SetSliderValues(24, 240, 1), and
    -- the carve-out restates those bounds because the CLI and a hand-edited
    -- SavedVariables reach the seam without ever touching that slider. The two
    -- statements are checked against each other here.
    local inst, first = twoWindows()
    local NS = inst.NS
    NS.State.SetActiveWindow(first)

    local function widthOK(w)
        return (NS.SetByPath("window.columns", { { stat = "DamageDone", width = w, showBar = true } }))
    end
    assertTrue(widthOK(24),  "24 is the slider's floor and must be accepted")
    assertTrue(widthOK(240), "240 is the slider's ceiling and must be accepted")
    assertFalse(widthOK(23))
    assertFalse(widthOK(241))
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

    for _, row in ipairs(NS.SchemaForPage("frame")) do
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

test("Schema: the Header page's three groups are named and ordered for the strip they describe",
function()
    -- Two strips, three groups, top to bottom in the order they are drawn:
    -- everything about the TITLE BAR first (its text, its alignment, its height
    -- and its background — one group, because they are one strip), then the
    -- controls that sit in that bar, then the column-label strip below it.
    --
    -- "Header text" and "Header background" used to be two groups, which put the
    -- height and the alignment of the TEXT under a heading that said background.
    -- red under: splitting Frame header back up, or filing the controls below the
    -- column labels.
    local inst = T.load()
    local L = inst.NS.L

    local order, seen = {}, {}
    for _, row in ipairs(inst.NS.SchemaForPage("header")) do
        local g = row.group
        if g and not seen[g] then
            seen[g] = true
            order[#order + 1] = g
        end
    end

    assertEqual(table.concat(order, " | "),
        table.concat({ L["Frame header"], L["Header controls"], L["Column headers"] }, " | "))
end)

test("Schema: the header controls are EDITED on Header and STORED under frame", function()
    -- A row's page is where it is edited; its path is where it is stored, and the
    -- two are allowed to disagree. Every one of these draws a control into the
    -- title bar, so a player looks for them under Header — but they are stored at
    -- `window.frame.*`, and renaming the keys for symmetry would migrate every
    -- saved profile in exchange for a tidiness nobody can see.
    -- red under: moving the group back to Frame, or renaming the paths.
    local inst = T.load()
    local NS = inst.NS

    local closeGroup, onHeader = nil, 0
    for _, row in ipairs(NS.SchemaForPage("header")) do
        if row.group == NS.L["Header controls"] then
            onHeader = onHeader + 1
            assertTrue(row.path:find("^window%.frame%."),
                row.path .. " is a header control and must still be stored under frame")
        end
        if row.path == "window.frame.closeButton" then closeGroup = row.group end
    end
    assertEqual(closeGroup, NS.L["Header controls"])
    assertTrue(onHeader >= 10, "the whole group moved, not one row of it")

    local groups = {}
    for _, row in ipairs(NS.SchemaForPage("frame")) do groups[row.group or ""] = true end
    assertFalse(groups[NS.L["Header controls"]] or false,
        "the Frame page kept a header control")
    assertTrue(groups[NS.L["Frame behavior"]], "the Frame page lost its behavior group")
    assertFalse(groups[NS.L["Row behavior"]] or false,
        "\"Row behavior\" is the Rows page's heading, not this one's")
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
        { label = "Frame header",   prefix = "window.header.",
          font = "font", outline = "outline", shadow = "shadow",
          color = "color", colorMode = "colorMode" },
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

        -- THREE MODES, THE SAME THREE, ON ALL FOUR. A surface offering a subset
        -- is the drift this table exists to catch: `stat` means a different
        -- statistic per surface, but it has to be OFFERED by every one of them.
        local mode = need("colour mode dropdown", surface.colorMode, "string")
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
        w.columns     = { { stat = "Deaths", width = 44, showBar = true } }
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
