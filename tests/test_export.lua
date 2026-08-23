-- tests/test_export.lua — modules/Export.lua: turning a built grid into text
-- somebody can carry out of the game.
--
-- Only the PURE half is reachable from here, and that is the whole reason the
-- module is split where it is: everything above its "Export modal" divider is a
-- function of its arguments, so the cases below hand it a result table and read
-- a string back. The modal, the copy window and the three dropdowns are
-- smoke-tested (docs/smoke-tests.md), as LootHistory's are.
--
-- Two things are worth stating before the first case, because they are what the
-- file is really guarding:
--
--   1. A CSV CELL IS `tostring`, and `tostring` is NOT on docs/data-flow.md's
--      list of operations permitted on a secret — it neither raises nor
--      launders, it answers a SECRET STRING that then poisons the `find` and the
--      `gsub` behind it. So the serializers refuse outright while the Combat
--      restriction is active, and the refusal is asserted here rather than
--      trusted: a serializer that quietly kept working under a restricted
--      instance is the regression this suite exists to catch.
--   2. NOTHING IN THE MODULE SORTS. The rank in a chat dump is the order
--      Aggregator.Build returned, which it produced under its own comparison
--      guards. The ranking case below feeds rows in a deliberately unsorted
--      order and asserts they come back in exactly that order.
--
-- The fixtures are hand-built result tables rather than real aggregator output.
-- That is deliberate: these functions take a result and return text, and
-- building the result through the meter mock would make every case below also a
-- case about the join. tests/test_aggregator.lua owns that.

local T = _G.MULTIMETERS_TEST

local test        = T.test
local assertEqual = T.assertEqual
local assertTrue  = T.assertTrue
local assertFalse = T.assertFalse
local assertNil   = T.assertNil

local Const = T.NS.Constants

-- The refusal sentence, spelled once. It is a locale KEY as well as its own
-- English value, and the module hands it back verbatim for a caller to show.
local RESTRICTED_REASON = "Export is not available while the game restricts combat data."

-- U+2014 EM DASH with its surrounding spaces, in bytes — the same escape
-- modules/Export.lua uses, and for the same reason: the encoding of a source
-- file that passes through this many tools cannot be assumed.
local EM_DASH = " \226\128\148 "

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

--- One cell, in the shape modules/Aggregator.lua parks under `row.values[key]`.
---
--- `percent` is the aggregator's ONE derived number and reaches a cell as a
--- plain Lua number or as nil — never as an opaque handle — which is why the
--- serializer is allowed to `string.format` it.
---
--- @param total any        the raw amount
--- @param opts table|nil    { rate = , percent = , maxAmount = }
--- @return table
local function cell(total, opts)
    opts = opts or {}
    return {
        total     = total,
        rate      = opts.rate,
        maxAmount = opts.maxAmount,
        percent   = opts.percent,
    }
end

--- One row. `cells` is the alias the aggregator publishes beside `values`, and
--- it is the SAME TABLE there rather than a copy; reproducing the alias here
--- means a case cannot accidentally assert against a shape the aggregator does
--- not actually produce.
---
--- @param name string
--- @param values table      { [statKey] = cell }
--- @param opts table|nil    { class = , spec = , role = , guid = }
--- @return table
local function row(name, values, opts)
    opts = opts or {}
    return {
        guid          = opts.guid or name,
        name          = name,
        classFilename = opts.class,
        specIconID    = opts.spec,
        role          = opts.role,
        values        = values,
        cells         = values,
    }
end

--- An Aggregator.Build result: the row array IS the result table, with `rows`
--- pointing back at itself (tests/test_aggregator.lua asserts that identity).
---
--- @param rows table              array of rows
--- @param durationSeconds any     the segment's length
--- @return table
local function built(rows, durationSeconds)
    rows.rows            = rows
    rows.durationSeconds = durationSeconds
    return rows
end

--- Split CSV text into its lines, consuming the CRLF pairs. A line the module
--- did not terminate is therefore invisible here, which is the point: the
--- trailing CRLF is part of the format.
---
--- @param text string
--- @return table  array of strings
local function csvLines(text)
    local out = {}
    for line in tostring(text):gmatch("([^\r\n]*)\r\n") do out[#out + 1] = line end
    return out
end

--- Split one UNQUOTED CSV line into fields. Naive on purpose — a case about
--- quoting asserts against the line itself rather than through this.
---
--- @param line string
--- @return table  array of strings
local function fields(line)
    local out = {}
    for field in (line .. ","):gmatch("([^,]*),") do out[#out + 1] = field end
    return out
end

--- A fresh instance with the Combat restriction ACTIVE — the state an export is
--- a refusal in.
---
--- @return table
local function restricted()
    local inst = T.load()
    inst.mocks.setRestricted(true)
    return inst
end

-- ---------------------------------------------------------------------------
-- Publication
-- ---------------------------------------------------------------------------

test("Export is a plain table on NS, not an AceAddon module", function()
    local NS = T.NS
    assertEqual(type(NS.Export), "table")
    -- No lifecycle: it subscribes to nothing, owns no state that survives a
    -- click, and is called directly. A module here would be a module whose
    -- OnEnable had nothing to do.
    assertEqual(NS.Export.OnEnable, nil, "Export must not carry a module lifecycle")
    for _, name in ipairs({ "Available", "CsvField", "Columns", "HeaderName",
                            "SessionConfig", "Build", "SessionLabel", "CSV",
                            "ChatLines", "ResolveChannel", "ResolveMetric", "Send",
                            "Open" }) do
        assertEqual(type(NS.Export[name]), "function", "Export." .. name .. " must be published")
    end
end)

-- ---------------------------------------------------------------------------
-- Availability — the one gate the whole file hangs off
-- ---------------------------------------------------------------------------

test("Export.Open refuses to open at all while restricted", function()
    -- A modal with two dead buttons explains nothing; the sentence in chat is the
    -- useful half of that interaction.
    local inst = restricted()
    assertNil(inst.NS.Export.Open({}))
    assertNil(inst.NS.Export:Open({}), "and through the colon form the header uses")
end)

test("Export.Available says yes out of combat, with nothing to explain", function()
    local ok, reason = T.load().NS.Export.Available()
    assertTrue(ok, "an export out of combat is legal")
    assertNil(reason, "there is nothing to say when the answer is yes")
end)

test("Export.Available refuses while the Combat restriction is active", function()
    -- red under: dropping the Secrets check, which would leave `tostring` to run
    -- on a secret and hand a secret string to `find`.
    local ok, reason = restricted().NS.Export.Available()
    assertFalse(ok, "an export mid-pull must be refused")
    assertEqual(reason, RESTRICTED_REASON)
end)

test("Export.Available resolves Secrets at CALL time, not at load", function()
    -- The modal can sit open across the edge into a pull, so the same instance
    -- must answer differently before and after. Captured-at-load would answer
    -- "available" for the whole fight.
    local inst = T.load()
    assertTrue(inst.NS.Export.Available())
    inst.mocks.setRestricted(true)
    assertFalse(inst.NS.Export.Available())
    inst.mocks.setRestricted(false)
    assertTrue(inst.NS.Export.Available(), "and back again when the pull ends")
end)

-- ---------------------------------------------------------------------------
-- Header names — derived, never restated
-- ---------------------------------------------------------------------------

test("Export.HeaderName turns a catalog key into snake_case", function()
    local HeaderName = T.NS.Export.HeaderName
    assertEqual(HeaderName("DamageDone"), "damage_done")
    assertEqual(HeaderName("HealingDone"), "healing_done")
    assertEqual(HeaderName("Absorbs"), "absorbs")
    assertEqual(HeaderName("EnemyDamageTaken"), "enemy_damage_taken")
    assertEqual(HeaderName("AvoidableDamageTaken"), "avoidable_damage_taken")
end)

test("Export.HeaderName covers every key in the catalog and invents no gaps", function()
    -- The rule is one gsub over CamelCase, and it has to hold for the tenth stat
    -- somebody adds as well as the nine that are there. A hand-written table of
    -- header names would go stale silently — the new column would export under
    -- whatever the fallback picked — so this walks the catalog rather than
    -- restating it.
    local HeaderName = T.NS.Export.HeaderName
    local seen = {}
    for _, stat in ipairs(Const.STATS) do
        local header = HeaderName(stat.key)
        assertEqual(type(header), "string")
        assertTrue(header ~= "", stat.key .. " must produce a header name")
        assertEqual(header, header:lower(), stat.key .. " -> " .. header .. " must be lower case")
        assertNil(header:find("[^%l_]"), header .. " must be letters and underscores only")
        -- Two stats sharing a header name would collide into one spreadsheet
        -- column and silently overwrite each other.
        assertNil(seen[header], "duplicate header name " .. header)
        seen[header] = stat.key
    end
end)

-- ---------------------------------------------------------------------------
-- CsvField — the laundering point
-- ---------------------------------------------------------------------------

test("Export.CsvField leaves an ordinary field alone", function()
    local CsvField = T.NS.Export.CsvField
    assertEqual(CsvField("Kaosz"), "Kaosz")
    assertEqual(CsvField("WARLOCK"), "WARLOCK")
    assertEqual(CsvField(4821993), "4821993")
    assertEqual(CsvField(0), "0")
end)

test("Export.CsvField quotes a field carrying a comma", function()
    -- Unquoted, one comma in a name turns one row into a row with an extra
    -- column, and every column right of it shifts by one for that row only —
    -- which reads in a sheet as "the export is fine except for that guy".
    assertEqual(T.NS.Export.CsvField("Last, First"), '"Last, First"')
end)

test("Export.CsvField doubles an embedded double quote and wraps the field", function()
    -- RFC 4180's escape: the quote is the escape character for itself.
    assertEqual(T.NS.Export.CsvField('say "hi"'), '"say ""hi"""')
end)

test("Export.CsvField quotes a field carrying a CR or an LF", function()
    local CsvField = T.NS.Export.CsvField
    assertEqual(CsvField("one\r\ntwo"), '"one\r\ntwo"')
    assertEqual(CsvField("one\ntwo"), '"one\ntwo"')
    assertEqual(CsvField("one\rtwo"), '"one\rtwo"')
end)

test("Export.CsvField leaves the two names from the issue unquoted", function()
    -- Neither a hyphen nor a space is a CSV metacharacter, and quoting them
    -- anyway would put literal quote marks in every cell of a cross-realm raid.
    -- These are the two shapes that motivated the quoting rule in the first
    -- place, so they are asserted by name.
    local CsvField = T.NS.Export.CsvField
    assertEqual(CsvField("Kaosz-Draenor"), "Kaosz-Draenor")
    assertEqual(CsvField("Crenna Earth-Daughter"), "Crenna Earth-Daughter")
end)

test("Export.CsvField answers empty for nil, never the string 'nil'", function()
    -- A blank cell is an absence; "nil" is a four-character string a spreadsheet
    -- will happily average as text and quietly refuse to sum.
    assertEqual(T.NS.Export.CsvField(nil), "")
end)

test("Export.CsvField answers empty for a value it may not look at", function()
    -- The per-value half of the combat rule. CanAccess is asked BEFORE the
    -- tostring, because tostring on a secret answers a secret string rather than
    -- raising — and a secret string poisons the find and the gsub behind it.
    -- red under: moving the guard below the tostring.
    local inst = T.load()
    local hidden = inst.mocks.secret(4821993)
    assertEqual(inst.NS.Export.CsvField(hidden), "")
end)

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------

test("Export.Columns carries _ps for exactly the rate stats and no others", function()
    -- A per-second figure for Deaths or Interrupts is nonsense, and an
    -- always-blank column is worse than an absent one.
    local Export = T.NS.Export
    local byHeader = {}
    for _, column in ipairs(Export.Columns()) do byHeader[column.header] = column end

    for _, stat in ipairs(Const.STATS) do
        local base = Export.HeaderName(stat.key)
        local rate = byHeader[base .. "_ps"]
        if stat.isRate then
            assertTrue(rate ~= nil, stat.key .. " is a rate stat and needs a _ps column")
            assertEqual(rate.kind, "rate")
            assertEqual(rate.statKey, stat.key)
        else
            assertNil(rate, stat.key .. " is not a rate stat and must have no _ps column")
        end
    end
end)

test("Export.Columns carries a total and a _pct for every stat in the catalog", function()
    -- _pct is present even where it will be blank: a spreadsheet's columns must
    -- line up between two exports of different fights, and mid-pull no stat has
    -- a percentage at all.
    local Export = T.NS.Export
    local byHeader = {}
    for _, column in ipairs(Export.Columns()) do byHeader[column.header] = column end

    for _, stat in ipairs(Const.STATS) do
        local base = Export.HeaderName(stat.key)
        assertTrue(byHeader[base] ~= nil, stat.key .. " must have a total column")
        assertEqual(byHeader[base].kind, "total")
        assertEqual(byHeader[base].statKey, stat.key)
        assertTrue(byHeader[base .. "_pct"] ~= nil, stat.key .. " must have a _pct column")
        assertEqual(byHeader[base .. "_pct"].kind, "pct")
        assertEqual(byHeader[base .. "_pct"].statKey, stat.key)
    end
end)

test("Export.Columns follows catalog order and states each fact twice", function()
    local Export = T.NS.Export
    local columns = Export.Columns()

    -- Positional and named spellings on the same entry, so the serializer's
    -- terse walk and a call site that wants one fact both read well.
    for _, column in ipairs(columns) do
        assertEqual(column[1], column.header)
        assertEqual(column[2], column.statKey)
        assertEqual(column[3], column.kind)
    end

    -- Catalog order, derived rather than restated: rebuild the expected header
    -- list from Const.STATS and compare it whole.
    local expected = {}
    for _, stat in ipairs(Const.STATS) do
        local base = Export.HeaderName(stat.key)
        expected[#expected + 1] = base
        if stat.isRate then expected[#expected + 1] = base .. "_ps" end
        expected[#expected + 1] = base .. "_pct"
    end
    assertEqual(#columns, #expected)
    for i, header in ipairs(expected) do assertEqual(columns[i].header, header) end
end)

-- ---------------------------------------------------------------------------
-- ResolveMetric — which column the chat dump ranks by
-- ---------------------------------------------------------------------------
--
-- `export.metric` used to ship as "", which was a CHOICE ("match the window")
-- rather than an absent value, resolved fresh against the invoking window at
-- every use. That choice is gone: the label was unreadable, and a control whose
-- value is "whatever something else says" cannot show you what it will do.
--
-- What replaced it is SEEDING — Export.Open writes the invoking window's sort
-- column into the profile — so the useful half survives and is visible in the
-- selector. These cases pin the narrowed contract: ResolveMetric always answers
-- a key the catalog holds, and "" is now just an unrecognized stored value.

--- Store one export preference the way the modal does.
---
--- @param inst table   a loaded instance
--- @param value any    what to store under export.metric
local function storeMetric(inst, value)
    local profile = inst.NS.db and inst.NS.db.profile
    profile.export = profile.export or {}
    profile.export.metric = value
end

test("Export.ResolveMetric answers the pinned stat", function()
    local inst = T.load()
    storeMetric(inst, "Deaths")
    assertEqual(inst.NS.Export.ResolveMetric({ data = { sortColumn = "HealingDone" } }), "Deaths")
end)

test("Export.ResolveMetric ships pinned to a real stat, never to the empty string", function()
    -- red under: the old FOLLOW_WINDOW default surviving the removal. A profile
    -- default of "" would now be an unrecognized value on every fresh install.
    local inst = T.load()
    local shipped = inst.NS.defaults.profile.export.metric
    assertTrue(Const.STAT_BY_KEY[shipped] ~= nil,
        "the shipped default is a key the catalog answers for, not a sentinel")
    assertEqual(shipped, Const.STATS[1].key)
end)

test("Export.ResolveMetric treats the old empty-string choice as unset", function()
    -- A profile written by the build that shipped FOLLOW_WINDOW. It degrades to
    -- the window's column and then to the first catalog stat, with no migration
    -- step — which is the whole reason no migration step was written.
    local inst = T.load()
    storeMetric(inst, "")
    assertEqual(inst.NS.Export.ResolveMetric({ data = { sortColumn = "HealingDone" } }),
        "HealingDone")
    assertEqual(inst.NS.Export.ResolveMetric({ data = {} }), Const.STATS[1].key)
end)

test("Export.ResolveMetric treats a stat this build does not offer as unset", function()
    local inst = T.load()
    storeMetric(inst, "AbsorbsFromTheFuture")
    assertEqual(inst.NS.Export.ResolveMetric({ data = { sortColumn = "Dispels" } }), "Dispels")
end)

test("Export.ResolveMetric falls back to the first catalog stat", function()
    local inst = T.load()
    storeMetric(inst, nil)
    assertEqual(inst.NS.Export.ResolveMetric({ data = {} }), Const.STATS[1].key)
    assertEqual(inst.NS.Export.ResolveMetric({}), Const.STATS[1].key)
    assertEqual(inst.NS.Export.ResolveMetric(nil), Const.STATS[1].key)
end)

test("Export.ResolveMetric is callable through the colon form", function()
    local inst = T.load()
    storeMetric(inst, "Deaths")
    assertEqual(inst.NS.Export:ResolveMetric(), "Deaths")
end)

test("The Metric selector offers exactly the catalog, with no sentinel entry", function()
    -- red under: "Match the window" surviving as a menu entry after the stored
    -- choice behind it was removed, which would write a value nothing resolves.
    local inst = T.load()
    assertNil(rawget(inst.NS.L, "Match the window"),
        "the string is gone from the locale, not just from the menu")
end)

-- ---------------------------------------------------------------------------
-- SessionConfig — the synthetic window an export is built from
-- ---------------------------------------------------------------------------

test("Export.SessionConfig names every catalog stat, enabled", function()
    -- Deliberately NOT the invoking window's column set. Three columns sorted by
    -- damage is a display choice; "the data" means all of it.
    -- The fixture carries display choices of its own — one column and a cap of
    -- five — and every one of them must be ignored. Without them this case would
    -- still pass against an implementation that simply echoed the window back.
    local cfg = T.NS.Export.SessionConfig({
        columns = { { stat = "DamageDone", enabled = true } },
        rows    = { maxRows = 5 },
    })
    assertEqual(#cfg.columns, #Const.STATS)
    assertEqual(cfg.rows.maxRows, Const.MAX_ROWS, "an export is not capped by the window's height")
    for i, stat in ipairs(Const.STATS) do
        assertEqual(cfg.columns[i].stat, stat.key)
        assertTrue(cfg.columns[i].enabled, stat.key .. " must be enabled in an export")
    end
end)

test("Export.SessionConfig caps at the aggregator's own ceiling", function()
    local cfg = T.NS.Export.SessionConfig({})
    assertEqual(cfg.rows.maxRows, Const.MAX_ROWS)
    assertEqual(cfg.id, "export")
    -- A value sort descending, because an export is a ranking and the
    -- aggregator is the only place a comparison of two meter values is legal.
    assertEqual(cfg.data.sortMode, "value")
    assertFalse(cfg.data.sortAscending)
end)

test("Export.SessionConfig inherits the invoking window's segment", function()
    -- "Export this" said while looking at last pull means last pull.
    local cfg = T.NS.Export.SessionConfig({
        data = {
            sessionType = Const.SESSION_TYPE.Overall,
            sessionID   = 17,
            mergePets   = true,
        },
    })
    assertEqual(cfg.data.sessionType, Const.SESSION_TYPE.Overall)
    assertEqual(cfg.data.sessionID, 17)
    assertTrue(cfg.data.mergePets)
end)

test("Export.SessionConfig falls back to the Current session with no window", function()
    local cfg = T.NS.Export.SessionConfig(nil)
    assertEqual(cfg.data.sessionType, Const.SESSION_TYPE.Current)
    assertNil(cfg.data.sessionID)
end)

test("Export.SessionConfig takes a Window INSTANCE as well as a bare config", function()
    -- The header glyph has an instance; the slash verb walks the registry and
    -- has only a config. One unwrap at the top beats two APIs.
    local config = { data = { sessionType = Const.SESSION_TYPE.Overall, sessionID = 4 } }
    local cfg = T.NS.Export.SessionConfig({ config = config })
    assertEqual(cfg.data.sessionType, Const.SESSION_TYPE.Overall)
    assertEqual(cfg.data.sessionID, 4)
end)

test("Export.SessionConfig ranks by the requested column, then the window's", function()
    local SessionConfig = T.NS.Export.SessionConfig
    local win = { data = { sortColumn = "Dispels" } }

    -- The argument wins: Print to Chat ranks by the metric it is about to print.
    assertEqual(SessionConfig(win, "Interrupts").data.sortColumn, "Interrupts")
    -- Absent, the window's own choice stands.
    assertEqual(SessionConfig(win).data.sortColumn, "Dispels")
    -- A key this build does not offer is not trusted into the aggregator — it
    -- falls back exactly as if it had not been given.
    assertEqual(SessionConfig(win, "NoSuchStat").data.sortColumn, "Dispels")
    -- And with neither, the first stat in the catalog.
    assertEqual(SessionConfig({}, "NoSuchStat").data.sortColumn, Const.STATS[1].key)
    assertEqual(SessionConfig({}).data.sortColumn, Const.STATS[1].key)
end)

-- ---------------------------------------------------------------------------
-- CSV
-- ---------------------------------------------------------------------------

--- The two-row fixture the CSV cases read: one fully-populated player and one
--- carrying nothing but a name, which is what a source with no roster entry and
--- no cells looks like.
---
--- @return table
local function csvFixture()
    return built({
        row("Kaosz", {
            DamageDone  = cell(4821993, { rate = 84210, percent = 31.2 }),
            HealingDone = cell(0, { rate = 0, percent = 0 }),
        }, { class = "WARLOCK", spec = 265, role = "DAMAGER" }),
        row("Crenna Earth-Daughter", {}),
    }, 134)
end

test("Export.CSV leads with the identity headers, then the derived stat columns", function()
    local Export = T.NS.Export
    local text = Export.CSV(csvFixture(), "Ulgrax")
    local lines = csvLines(text)

    local expected = { "session", "duration", "name", "class", "spec", "role" }
    for _, column in ipairs(Export.Columns()) do expected[#expected + 1] = column.header end
    assertEqual(lines[1], table.concat(expected, ","))
end)

test("Export.CSV writes one row per entry and terminates with a CRLF", function()
    -- CRLF because it pastes into a sheet, and TERMINATED rather than separated
    -- so two exports concatenated in one file do not weld a row onto a header.
    local text = T.NS.Export.CSV(csvFixture(), "Ulgrax")
    local lines = csvLines(text)
    assertEqual(#lines, 3, "a header line and two rows")
    assertEqual(text:sub(-2), "\r\n", "the last row must be terminated, not merely separated")
    assertNil(text:find("\n\n"), "no blank line")
end)

test("Export.CSV puts the session and duration on EVERY row", function()
    -- Not in a preamble: two exports concatenated in one sheet then still mean
    -- something, and a pivot table can group by fight without hand-editing.
    local text = T.NS.Export.CSV(csvFixture(), "Ulgrax")
    local lines = csvLines(text)
    for i = 2, #lines do
        local cells = fields(lines[i])
        assertEqual(cells[1], "Ulgrax", "row " .. i .. " must name its session")
        assertEqual(cells[2], "134", "row " .. i .. " must carry the duration in whole seconds")
    end
end)

test("Export.CSV rounds a fractional duration to whole seconds", function()
    -- red under: `tostring(seconds)`, which writes 134.6 into a column the header
    -- calls "duration" in seconds and every other row reports as an integer.
    local text = T.NS.Export.CSV(built({ { name = "Kaosz", values = {} } }, 134.6), "Ulgrax")
    assertEqual(fields(csvLines(text)[2])[2], "135")
    -- Rounded, not truncated: 134.4 is nearer 134.
    text = T.NS.Export.CSV(built({ { name = "Kaosz", values = {} } }, 134.4), "Ulgrax")
    assertEqual(fields(csvLines(text)[2])[2], "134")
end)

test("Export.CSV leaves the duration blank rather than reading a secret one", function()
    -- The per-value half of the combat rule, on the one field that is not a cell.
    -- A blank column in a race beats a serializer that raises mid-write.
    local inst = T.load()
    local text = inst.NS.Export.CSV(
        built({ { name = "Kaosz", values = {} } }, inst.mocks.secret(134)), "Ulgrax")
    assertEqual(fields(csvLines(text)[2])[2], "")
    -- and the row is still written, session column and all.
    assertEqual(fields(csvLines(text)[2])[1], "Ulgrax")
end)

test("Export.CSV writes raw values and a two-decimal share", function()
    -- A spreadsheet wants 4821993, not "4.8M": the abbreviation is a display
    -- decision and an export is a data interchange.
    local Export = T.NS.Export
    local lines = csvLines(Export.CSV(csvFixture(), "Ulgrax"))
    local header = fields(lines[1])
    local cells  = fields(lines[2])

    local index = {}
    for i, name in ipairs(header) do index[name] = i end

    assertEqual(cells[index.name], "Kaosz")
    assertEqual(cells[index.class], "WARLOCK")
    assertEqual(cells[index.spec], "265")
    assertEqual(cells[index.role], "DAMAGER")
    assertEqual(cells[index.damage_done], "4821993")
    assertEqual(cells[index.damage_done_ps], "84210")
    assertEqual(cells[index.damage_done_pct], "31.20")
end)

test("Export.CSV writes an absent cell as blank, never as a zero or a 'nil'", function()
    -- Most players have no row in Dispels, Interrupts or Deaths. That is the
    -- COMMON case, not an error — and a zero there would be a claim the meter
    -- never made.
    local Export = T.NS.Export
    local lines  = csvLines(Export.CSV(csvFixture(), "Ulgrax"))
    local header = fields(lines[1])
    local cells  = fields(lines[3])

    local index = {}
    for i, name in ipairs(header) do index[name] = i end

    assertEqual(cells[index.name], "Crenna Earth-Daughter")
    assertEqual(cells[index.class], "", "a source with no roster entry has no class")
    assertEqual(cells[index.damage_done], "")
    assertEqual(cells[index.damage_done_ps], "")
    assertEqual(cells[index.damage_done_pct], "")
    -- Every declared column is still present, blank: the widths must line up
    -- between two exports.
    assertEqual(#cells, #header)
end)

test("Export.CSV quotes a session name that would otherwise split the row", function()
    -- The leading columns go through CsvField too. An unquoted comma there would
    -- shift every column of every row in the file by one, which is the failure
    -- mode a sheet shows as plausible-looking nonsense rather than as an error.
    local text  = T.NS.Export.CSV(csvFixture(), 'Ulgrax, the "Devourer"')
    local quoted = '"Ulgrax, the ""Devourer"""'
    local lines = csvLines(text)
    assertEqual(lines[2]:sub(1, #quoted), quoted)
    assertEqual(lines[2]:sub(#quoted + 1, #quoted + 1), ",", "and the field must end there")
end)

test("Export.CSV writes a header and nothing else for an empty result", function()
    local text = T.NS.Export.CSV(built({}, 0), "Ulgrax")
    assertEqual(#csvLines(text), 1)
end)

test("Export.CSV reads the degenerate build's separate rows array", function()
    -- Aggregator.Build with no config answers `{ rows = {}, columns = {} }`,
    -- where `rows` is a DIFFERENT table rather than the result itself. Reading
    -- the field first is correct for both shapes.
    local result = { rows = { row("Kaosz", { DamageDone = cell(10) }) }, columns = {} }
    assertEqual(#csvLines(T.NS.Export.CSV(result, "Ulgrax")), 2)
end)

test("Export.CSV answers nothing at all for something that is not a result", function()
    local text, reason = T.NS.Export.CSV(nil, "Ulgrax")
    assertEqual(text, "")
    assertNil(reason, "an absent result is not a refusal and has nothing to explain")
end)

test("Export.CSV refuses while the Combat restriction is active", function()
    -- The structural half of the combat rule, and the one that matters: an empty
    -- string rather than nil, so a caller handing the answer straight to an
    -- EditBox cannot be the thing that errors.
    -- red under: dropping the Available() gate at the top of the serializer.
    local inst = restricted()
    local text, reason = inst.NS.Export.CSV(csvFixture(), "Ulgrax")
    assertEqual(text, "")
    assertEqual(reason, RESTRICTED_REASON)
end)

-- ---------------------------------------------------------------------------
-- ChatLines
-- ---------------------------------------------------------------------------

--- Three ranked rows, fed in the order they are meant to come back out in.
---
--- @return table
local function chatFixture()
    return built({
        row("Kaosz", { DamageDone = cell(4821993, { rate = 84210, percent = 31.2 }) }),
        row("Brewz", { DamageDone = cell(4100000, { rate = 71900, percent = 26.6 }) }),
        row("Zippy", { DamageDone = cell(900000,  { rate = 15000, percent = 5.8  }) }),
    }, 134)
end

test("Export.ChatLines heads the dump with the addon, the metric and the segment", function()
    local lines = T.NS.Export.ChatLines(chatFixture(), "DamageDone", 5, "Ulgrax")
    assertEqual(lines[1], "Multi Meters" .. EM_DASH .. "Damage" .. EM_DASH .. "Ulgrax (2:14)")
end)

test("Export.ChatLines omits the segment from the header when there is none", function()
    local lines = T.NS.Export.ChatLines(chatFixture(), "DamageDone", 5, nil)
    assertEqual(lines[1], "Multi Meters" .. EM_DASH .. "Damage (2:14)")
end)

test("Export.ChatLines numbers the rows and never reorders them", function()
    -- The rank IS the order the aggregator returned. Comparing two meter values
    -- is the operation the restriction forbids, and the aggregator has already
    -- done it behind its own guards; a sort here would be a second, unguarded
    -- one. So the fixture is fed in a deliberately UNSORTED order and must come
    -- back untouched.
    -- red under: any table.sort in ChatLines.
    local result = built({
        row("Third",  { DamageDone = cell(100) }),
        row("First",  { DamageDone = cell(900) }),
        row("Second", { DamageDone = cell(500) }),
    }, 60)
    local lines = T.NS.Export.ChatLines(result, "DamageDone", 5, "Ulgrax")
    assertEqual(#lines, 4)
    assertTrue(lines[2]:find("^1%. Third ") ~= nil, lines[2])
    assertTrue(lines[3]:find("^2%. First ") ~= nil, lines[3])
    assertTrue(lines[4]:find("^3%. Second ") ~= nil, lines[4])
end)

test("Export.ChatLines abbreviates the amount and carries rate then share", function()
    -- Chat wants "4.8M": nobody reads a nine-digit figure out of a scrolling
    -- frame. This is the one place the module goes through NS.Format.
    local lines = T.NS.Export.ChatLines(chatFixture(), "DamageDone", 1, "Ulgrax")
    assertEqual(lines[2], "1. Kaosz 4.8M (84.2K, 31.2%)")
end)

test("Export.ChatLines drops the rate parenthetical for a counted stat", function()
    -- A per-second figure for Deaths or Interrupts is nonsense, and the cell is
    -- given one here anyway so the assertion is about the isRate flag rather
    -- than about the fixture happening to be short.
    -- red under: printing cell.rate without consulting stat.isRate.
    local result = built({
        row("Kaosz", { Interrupts = cell(3, { rate = 99999, percent = 42.5 }) }),
    }, 60)
    local lines = T.NS.Export.ChatLines(result, "Interrupts", 5, "Ulgrax")
    assertEqual(lines[2], "1. Kaosz 3 (42.5%)")
end)

test("Export.ChatLines drops the share when the aggregator could not compute one", function()
    -- `percent` is nil for "cannot be known right now", never for "zero percent",
    -- and an empty "( )" would be noise on every line of a Deaths dump.
    local result = built({
        row("Kaosz", { Deaths = cell(2) }),
    }, 60)
    local lines = T.NS.Export.ChatLines(result, "Deaths", 5, "Ulgrax")
    assertEqual(lines[2], "1. Kaosz 2", "no parenthetical at all when there is nothing in it")
end)

test("Export.ChatLines names an unreadable row rather than dropping it", function()
    local inst = T.load()
    local result = built({
        row(inst.mocks.secret("Kaosz"), { DamageDone = cell(100) }),
    }, 60)
    local lines = inst.NS.Export.ChatLines(result, "DamageDone", 5, "Ulgrax")
    assertTrue(lines[2]:find("^1%. Unknown ") ~= nil, lines[2])
end)

test("Export.ChatLines prints five ranked lines by default", function()
    local rows = {}
    for i = 1, 9 do rows[i] = row("Mock" .. i, { DamageDone = cell(1000 - i) }) end
    local lines = T.NS.Export.ChatLines(built(rows, 60), "DamageDone", nil, "Ulgrax")
    assertEqual(#lines, 6, "a header line and five ranked ones")
end)

test("Export.ChatLines clamps the cap to 1..MAX_ROWS", function()
    local rows = {}
    for i = 1, Const.MAX_ROWS + 5 do
        rows[i] = row("Mock" .. i, { DamageDone = cell(1000 - i) })
    end
    local result = built(rows, 60)
    local ChatLines = T.NS.Export.ChatLines

    -- A zero or a negative would otherwise print a header and nothing under it,
    -- which reads as a broken export rather than as a setting at its floor.
    assertEqual(#ChatLines(result, "DamageDone", 0, "U"), 2)
    assertEqual(#ChatLines(result, "DamageDone", -7, "U"), 2)
    -- The ceiling is the aggregator's own, so a change to MAX_ROWS moves both.
    assertEqual(#ChatLines(result, "DamageDone", 999, "U"), Const.MAX_ROWS + 1)
    -- A string off a dropdown is a number's worth of intent.
    assertEqual(#ChatLines(result, "DamageDone", "3", "U"), 4)
end)

test("Export.ChatLines falls back to the first catalog stat for an unknown key", function()
    local lines = T.NS.Export.ChatLines(chatFixture(), "NoSuchStat", 1, "Ulgrax")
    assertEqual(lines[1], "Multi Meters" .. EM_DASH .. "Damage" .. EM_DASH .. "Ulgrax (2:14)")
end)

test("Export.ChatLines answers nothing rather than raising with no formatter", function()
    -- A degraded install can have published neither NS.Format nor its other name.
    -- Every line here is built from formatter output, so there is nothing honest
    -- to emit — and an empty array is what the caller already handles as "nothing
    -- to export".
    local inst = T.load()
    inst.NS.Format = nil
    inst.NS.NumberFormat = nil
    if inst.NS.GetModule then
        local real = inst.NS.GetModule
        inst.NS.GetModule = function(self, name, ...)
            if name == "Format" then return nil end
            return real(self, name, ...)
        end
    end

    local lines = inst.NS.Export.ChatLines(chatFixture(), "DamageDone", 5, "Ulgrax")
    assertEqual(type(lines), "table")
    assertEqual(#lines, 0)
end)

test("Export.ChatLines refuses to the empty array while restricted", function()
    -- red under: dropping the Available() gate. Every line below it is a `..`
    -- over a formatted meter value, and the formatter may hand back a handle.
    local lines = restricted().NS.Export.ChatLines(chatFixture(), "DamageDone", 5, "Ulgrax")
    assertEqual(type(lines), "table")
    assertEqual(#lines, 0, "not even the header line: an empty dump is the refusal")
end)

-- ---------------------------------------------------------------------------
-- Channels
-- ---------------------------------------------------------------------------

test("Export.ResolveChannel answers nothing for SELF, which is the default", function()
    -- SELF is the shipped default precisely because it resolves to no chat type:
    -- a misclick on a glyph in a title bar must not be able to reach a group.
    local ResolveChannel = T.NS.Export.ResolveChannel
    local chatType, target = ResolveChannel("SELF")
    assertNil(chatType)
    assertNil(target)
    -- Nothing at all is SELF too, for the same reason.
    assertNil((ResolveChannel(nil)))
    assertNil((ResolveChannel("")))
end)

test("Export.ResolveChannel walks AUTO's instance -> raid -> party -> say ladder", function()
    local inst = T.load()
    local ResolveChannel = inst.NS.Export.ResolveChannel
    local mocks = inst.mocks

    -- Alone in the world: say, rather than nothing. A solo player who
    -- deliberately picked AUTO asked for it to go somewhere.
    mocks.setSolo()
    mocks.setInstance(nil)
    assertEqual((ResolveChannel("AUTO")), "SAY")

    -- A party in the open world.
    mocks.setGroup({ { name = "A" }, { name = "B" }, { name = "C" } })
    assertEqual((ResolveChannel("AUTO")), "PARTY")

    -- A raid in the open world.
    mocks.setGroup({ { name = "A" }, { name = "B" }, { name = "C" } }, { raid = true })
    assertEqual((ResolveChannel("AUTO")), "RAID")

    -- A QUEUED group — dungeon finder, raid finder, a battleground — is the one
    -- case instance chat wins, because it is the one channel everybody in there
    -- can read.
    mocks.setGroup({ { name = "A" }, { name = "B" }, { name = "C" } })
    mocks.setInstance("party")
    mocks.setInstanceGroup(true)
    assertEqual((ResolveChannel("AUTO")), "INSTANCE_CHAT")

    -- THE CASE THIS ADDON EXISTS FOR, and the one an earlier ladder got wrong by
    -- asking IsInInstance() instead of asking about membership: a premade party
    -- that walks into a dungeon is INSIDE an instance and is still a HOME group.
    -- SendChatMessage on INSTANCE_CHAT for one of those is a silent no-op, so
    -- resolving to it would make Print to Chat do nothing at all in a key.
    mocks.setGroup({ { name = "A" }, { name = "B" }, { name = "C" } })
    mocks.setInstance("party")
    assertEqual((ResolveChannel("AUTO")), "PARTY")

    -- The same for a guild raid inside a raid instance.
    mocks.setGroup({ { name = "A" }, { name = "B" }, { name = "C" } }, { raid = true })
    mocks.setInstance("raid")
    assertEqual((ResolveChannel("AUTO")), "RAID")

    -- An instance entered alone is not a group, so the ladder falls past it.
    mocks.setSolo()
    mocks.setInstance("party")
    assertEqual((ResolveChannel("AUTO")), "SAY")
end)

test("Export.ResolveChannel trims a whisper target and refuses an empty one", function()
    local ResolveChannel = T.NS.Export.ResolveChannel
    local chatType, target = ResolveChannel("WHISPER", "  Kaosz-Draenor  ")
    assertEqual(chatType, "WHISPER")
    assertEqual(target, "Kaosz-Draenor")

    -- A whisper with nobody to whisper to is not an error to raise at the send
    -- site; it is the same "keep it to yourself" SELF means.
    assertNil((ResolveChannel("WHISPER", "   ")))
    assertNil((ResolveChannel("WHISPER", nil)))
end)

test("Export.ResolveChannel takes every other key from the catalog", function()
    local ResolveChannel = T.NS.Export.ResolveChannel
    for _, channel in ipairs(Const.EXPORT_CHANNELS) do
        if channel.chatType and channel.key ~= "WHISPER" then
            assertEqual((ResolveChannel(channel.key)), channel.chatType,
                channel.key .. " must resolve to its own chat type")
        end
    end
end)

test("Export.ResolveChannel treats an unknown key as its own chat type", function()
    -- The keys ARE the chat types, which is what keeps this working on a load
    -- where core/Constants.lua's catalog never landed.
    assertEqual((T.NS.Export.ResolveChannel("OFFICER")), "OFFICER")
    -- And it is case-insensitive, because a stored profile is user data.
    assertEqual((T.NS.Export.ResolveChannel("guild")), "GUILD")
end)

test("Export.Send prints to the player alone for SELF", function()
    local inst = T.load()
    local before = #inst.mocks.__chat
    assertTrue(inst.NS.Export.Send({ "one", "two" }, "SELF"))
    assertEqual(#inst.mocks.__chat - before, 2, "one printed line each, and nothing sent")
end)

test("Export.Send hands one message per line to the client", function()
    -- SendChatMessage's 255-byte ceiling is per message, and no line built above
    -- comes close — every field in one is a formatted number or a player name.
    local inst = T.load()
    local sent = {}
    inst.mocks.SendChatMessage = function(text, chatType, _, target)
        sent[#sent + 1] = { text = text, chatType = chatType, target = target }
    end

    assertTrue(inst.NS.Export.Send({ "one", "two", "three" }, "WHISPER", "Kaosz"))

    -- THE FIRST LINE GOES IMMEDIATELY and the rest are staggered onto timers. A
    -- button that appears to do nothing for a third of a second is a button
    -- people press twice, and forty lines in one frame is a flood the server
    -- answers by dropping the tail.
    assertEqual(#sent, 1, "only the first line may leave in the calling frame")
    assertEqual(sent[1].text, "one")
    assertEqual(sent[1].chatType, "WHISPER")
    assertEqual(sent[1].target, "Kaosz")

    inst.mocks.__fireTimers()
    assertEqual(#sent, 3, "the queued lines must all arrive")
    assertEqual(sent[2].text, "two")
    assertEqual(sent[3].text, "three")
    -- ORDER IS THE WHOLE POINT of a ranking, so the stagger must not reorder it.
    assertEqual(sent[3].chatType, "WHISPER")
    assertEqual(sent[3].target, "Kaosz")
end)

test("Export.Send sends every line at once on a client with no C_Timer", function()
    -- Degraded rather than silent: a stagger that cannot be scheduled is worse
    -- than a flood only if the flood is the thing that loses the message.
    local inst = T.load()
    local sent = 0
    inst.mocks.SendChatMessage = function() sent = sent + 1 end
    inst.mocks.C_Timer = nil

    assertTrue(inst.NS.Export.Send({ "one", "two", "three" }, "PARTY"))
    assertEqual(sent, 3)
end)

test("Export.Send prints locally for SELF and sends nothing to any channel", function()
    -- red under: routing SELF through SendChatMessage, which would put a private
    -- ranking into whatever channel the client defaulted to.
    local inst = T.load()
    local sent = 0
    inst.mocks.SendChatMessage = function() sent = sent + 1 end

    assertTrue(inst.NS.Export.Send({ "one", "two" }, "SELF"))
    inst.mocks.__fireTimers()
    assertEqual(sent, 0, "SELF must never reach the server")
end)

test("Export.Send does nothing with nothing to send", function()
    assertFalse(T.NS.Export.Send(nil, "SELF"))
    assertFalse(T.NS.Export.Send({}, "SELF"))
end)

-- ---------------------------------------------------------------------------
-- The segment's name
-- ---------------------------------------------------------------------------

test("Export.SessionLabel asks the window, never the provider", function()
    -- Naming a stored session means matching an id against the session list, and
    -- rule R1 keeps this file away from that API. A window instance already
    -- answers the question for its own header.
    local win = { SessionLabel = function() return "Ulgrax" end, config = {} }
    assertEqual(T.NS.Export.SessionLabel(win), "Ulgrax")
end)

test("Export.SessionLabel survives a window whose label raises", function()
    -- SessionLabel reaches through a collaborator a degraded install may not
    -- have, and a missing label must cost an export nothing.
    local win = { SessionLabel = function() error("no provider") end, config = {} }
    assertEqual(T.NS.Export.SessionLabel(win), "Current")
end)

test("Export.SessionLabel names what a bare config can name on its own", function()
    local SessionLabel = T.NS.Export.SessionLabel
    assertEqual(SessionLabel({ data = { sessionType = Const.SESSION_TYPE.Current } }), "Current")
    assertEqual(SessionLabel({ data = { sessionType = Const.SESSION_TYPE.Overall } }), "Overall")
    assertEqual(SessionLabel({ data = { sessionID = 9 } }), "Segment")
    assertEqual(SessionLabel(nil), "Current")
end)

-- ---------------------------------------------------------------------------
-- End to end, through the aggregator
-- ---------------------------------------------------------------------------

test("Export.Build goes through the aggregator and nowhere near the meter API", function()
    -- The one case that proves the data path claim rather than restating it: a
    -- session installed on the mock reaches a CSV, and it does so through
    -- Aggregator.Build with a synthetic config. Nothing in modules/Export.lua
    -- touches Provider or C_DamageMeter, and rule R1 allows exactly one caller.
    local inst = T.load()
    inst.mocks.setGroup({
        { name = "Kaosz", class = "WARLOCK", role = "DAMAGER" },
        { name = "Brewz", class = "MONK",    role = "TANK"    },
    })
    inst.NS.Roster.Refresh()
    inst.mocks.setSession(Const.SESSION_TYPE.Current, "*", inst.mocks.buildSession({
        count = 2, names = { "Kaosz", "Brewz" }, durationSeconds = 134,
    }))

    local result = inst.NS.Export.Build({ data = { sessionType = Const.SESSION_TYPE.Current } })
    assertEqual(type(result), "table")
    assertEqual(#result.rows, 2)

    local text = inst.NS.Export.CSV(result, inst.NS.Export.SessionLabel(nil))
    local lines = csvLines(text)
    assertEqual(#lines, 3, "a header line and one row per group member")
    assertTrue(lines[2]:find("Kaosz", 1, true) ~= nil, lines[2])
end)

test("Export.Build answers nil when there is no aggregator to ask", function()
    -- Every collaborator is resolved at CALL time rather than captured at file
    -- scope, because load order within modules/ carries no guarantee — so a
    -- missing aggregator has to be a nil answer here and not an upvalue that was
    -- nil for the whole session. Both lookups are removed: the plain table on NS
    -- and the AceAddon registry behind it.
    local inst = T.load()
    local NS = inst.NS
    local savedTable, savedGetModule = NS.Aggregator, NS.GetModule
    NS.Aggregator, NS.GetModule = nil, nil
    local ok, result = pcall(NS.Export.Build, {})
    NS.Aggregator, NS.GetModule = savedTable, savedGetModule
    assertTrue(ok, "a missing aggregator must not raise")
    assertNil(result)
end)
