# Columns Page Blocks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Columns page into a list of draggable per-statistic blocks, one per catalog stat, with a tick/cross toggle and no width, show-bar, add, remove or move controls.

**Architecture:** `window.columns` stops being "the chosen columns" and becomes "the catalog, in your order" — one `{ stat, enabled }` entry per statistic in `Constants.STATS`, enabled ones sorted ahead of disabled ones as a stored invariant. `settings/Schema.lua`'s `normalizeColumns` becomes a repairing normalizer that produces that shape from anything, and is published as `NS.NormalizeColumns` so the DB migration and the page share one definition of the rule. The page itself splits into a generic reorderable-block widget and the page that drives it.

**Tech Stack:** Lua 5.1 (WoW client), Ace3 + AceGUI-3.0, LibKa0s-Options, headless test harness in `tests/` (`lua tests/run.lua`), `luacheck`.

**Spec:** `docs/superpowers/specs/2026-08-26-columns-page-blocks-design.md`

**Branch:** `columns-page-blocks`

## Global Constraints

- **Green gate before every commit:** `lua tests/run.lua` (0 failed) **and** `luacheck .` (0 warnings / 0 errors). Both, every task.
- **Never bump the version.** Not the TOC, not `README.md`, not anything. No explicit instruction has been given.
- **Never push.** Commit locally on `columns-page-blocks` only.
- `core/Secrets.lua` is the only file that inspects a meter value; `modules/Provider.lua` is the only file that reaches `C_DamageMeter`. **Nothing in this plan touches either rule** — the Columns page is config, not data.
- **Rule R3** (layout is computed from config, never read back off a frame) applies to frames that have held a meter value. Options-panel frames never do. Task 3 reads `GetTop`/`GetHeight` off options frames and this is legal; say so in the code comment.
- `tests/_kit/` is **vendored from LibKa0s and must not be edited**. `tests/wow_mock.lua` is this addon's own file and may be.
- Comment style: this codebase explains **why**, at length, in block comments above the thing. Match it. A line that only restates the code is worse than no line.
- Locale strings are always `L["English"] = "English"` in `locales/enUS.lua`, and are looked up at the **use site**, never in `core/Constants.lua`.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `settings/Schema.lua` | The single write seam. Owns the columns carve-out's validator. | Modify: `normalizeColumns` rewritten as repairing; published as `NS.NormalizeColumns`. |
| `defaults/Profile.lua` | The shipped profile. Owns `NS.DefaultWindow`. | Modify: `DefaultWindow` emits the full catalog. |
| `core/Database.lua` | AceDB wiring and the migration ladder. | Modify: `CURRENT_DB_VERSION` 10 → 11, new `migrations[10]`. |
| `modules/Window.lua` | Builds the layout from config. | Modify: `BuildLayout` filters on `enabled`, stops emitting `showBar`. |
| `modules/Row.lua` | Draws one row's cells. | Modify: the bar is unconditional. |
| `settings/ColumnBlocks.lua` | **New.** A generic reorderable block list: draws blocks, owns the drag, owns the toggle glyph. Knows nothing about statistics. | Create. |
| `settings/Columns.lua` | The Columns page: reads the window, drives the widget, writes through the seam. | Rewrite. |
| `MultiMeters.toc` | Load order. | Modify: `settings\ColumnBlocks.lua` before `settings\Columns.lua`. |
| `locales/enUS.lua` | Every user-facing string. | Modify: retire dead strings, add new ones. |
| `tests/wow_mock.lua` | The WoW API stub. | Modify: add `GetCursorPosition` + `setCursor`. |

`settings/ColumnBlocks.lua` is split out rather than living inside the page because it is the unit destined for LibKa0s under [issue #21](https://github.com/tusharsaxena/MultiMeters/issues/21). Keeping it in its own file with its own test makes that promotion a file move rather than an extraction.

---

### Task 1: The stored shape

`window.columns` becomes the catalog. The normalizer, the shipped defaults and the migration move together because they are one rule seen from three places: the defaults must produce what the normalizer accepts, and the migration must produce what both agree on.

**Files:**
- Modify: `settings/Schema.lua` — `normalizeColumns` (currently lines 1896-1952), `setColumns` (1955-1969), and the `COLUMN_MIN_WIDTH, COLUMN_MAX_WIDTH` local (1884)
- Modify: `defaults/Profile.lua:536-546` — `NS.DefaultWindow`'s column loop
- Modify: `core/Database.lua:46` — `CURRENT_DB_VERSION`; append `migrations[10]` after `migrations[9]` (ends line 546)
- Test: `tests/test_schema.lua`, `tests/test_defaults.lua`, `tests/test_database.lua`, `tests/test_windowmanager.lua`

**Interfaces:**
- Consumes: `Const.STATS` (ordered catalog array), `Const.STAT_BY_KEY` (key → row), `Const.DEFAULT_STAT_KEYS` (the keys with `defaultEnabled`, in catalog order)
- Produces:
  - `NS.NormalizeColumns(value) -> table|nil, string|nil` — the repaired array, or nil plus a reason. Task 3's migration and Task 4's page both rely on this name.
  - Stored shape: `w.columns` is an array of exactly `#Const.STATS` entries, each `{ stat = "<catalog key>", enabled = <boolean> }`, all `enabled == true` entries before all `enabled == false` entries.

- [ ] **Step 1: Write the failing normalizer tests**

Replace the columns block in `tests/test_schema.lua`. Find the existing round-trip test near line 271 and the `for` table of refusal cases near line 354, and replace both with:

```lua
test("Schema: the columns carve-out repairs an array into the whole catalog", function()
    local inst = T.load()
    local NS = inst.NS
    local Const = NS.Constants

    local ok = NS.SetByPath("window.columns", {
        { stat = "HealingDone", enabled = true },
        { stat = "DamageDone",  enabled = true },
    })
    assertTrue(ok, "a two-entry array naming known stats must be accepted")

    local stored = NS.Database.GetWindows()[1].columns
    assertEqual(#stored, #Const.STATS,
        "the stored array IS the catalog now, however short the input was")
    assertEqual(stored[1].stat, "HealingDone", "the caller's order is kept for the enabled ones")
    assertEqual(stored[2].stat, "DamageDone")
    assertTrue(stored[1].enabled)
    assertTrue(stored[2].enabled)
    for i = 3, #stored do
        assertFalse(stored[i].enabled,
            "every stat the caller did not name arrives disabled, not missing")
    end
    assertEqual(stored[1].width, nil, "width is not part of the shape any more")
    assertEqual(stored[1].showBar, nil, "showBar is not part of the shape any more")
end)

test("Schema: an unknown statistic is dropped rather than stored", function()
    -- The old code LISTED an unknown stat so the player could remove it. There
    -- is no remove button now and the list IS the catalog, so there is nothing
    -- they could do with it -- self-healing beats surfacing a dead row.
    local inst = T.load()
    local NS = inst.NS

    local ok = NS.SetByPath("window.columns", {
        { stat = "DamageDone", enabled = true },
        { stat = "FutureStat", enabled = true },
    })
    assertTrue(ok, "an unknown stat must not fail the whole write")

    local stored = NS.Database.GetWindows()[1].columns
    for _, c in ipairs(stored) do
        assertFalse(c.stat == "FutureStat", "the unknown stat must not be stored")
    end
    assertEqual(#stored, #NS.Constants.STATS)
end)

test("Schema: a repeated statistic keeps its first appearance only", function()
    local inst = T.load()
    local NS = inst.NS

    assertTrue((NS.SetByPath("window.columns", {
        { stat = "DamageDone",  enabled = true },
        { stat = "HealingDone", enabled = true },
        { stat = "DamageDone",  enabled = false },
    })))

    local stored = NS.Database.GetWindows()[1].columns
    local seen = 0
    for _, c in ipairs(stored) do
        if c.stat == "DamageDone" then seen = seen + 1 end
    end
    assertEqual(seen, 1, "two Damage columns show identical numbers twice")
    assertEqual(stored[1].stat, "DamageDone")
    assertTrue(stored[1].enabled, "the FIRST appearance wins, so it stays enabled")
end)

test("Schema: enabled columns are stored ahead of disabled ones", function()
    -- Sink-to-bottom is a STORED invariant, not something the page maintains.
    -- The CLI and a hand-edited SavedVariables reach this seam without ever
    -- touching a block, and must land in the shape the page produces.
    local inst = T.load()
    local NS = inst.NS

    assertTrue((NS.SetByPath("window.columns", {
        { stat = "DamageDone",  enabled = false },
        { stat = "HealingDone", enabled = true },
        { stat = "Interrupts",  enabled = false },
        { stat = "Dispels",     enabled = true },
    })))

    local stored = NS.Database.GetWindows()[1].columns
    assertEqual(stored[1].stat, "HealingDone")
    assertEqual(stored[2].stat, "Dispels")

    local sawDisabled = false
    for _, c in ipairs(stored) do
        if not c.enabled then sawDisabled = true end
        if c.enabled then
            assertFalse(sawDisabled, "an enabled column must never follow a disabled one")
        end
    end
end)

test("Schema: the columns carve-out refuses what it cannot repair", function()
    local inst = T.load()
    local NS = inst.NS
    local before = NS.Database.GetWindows()[1].columns

    local cases = {
        { "a non-table",           "nonsense" },
        { "an empty list",         {} },
        { "a gap or a string key", { [1] = { stat = "DamageDone", enabled = true }, x = 1 } },
        { "an all-disabled list",  { { stat = "DamageDone", enabled = false } } },
        { "an entry that is not a column", { "DamageDone" } },
    }

    for _, case in ipairs(cases) do
        local ok, err = NS.SetByPath("window.columns", case[2])
        assertFalse(ok, case[1] .. " must be refused")
        assertTrue(type(err) == "string" and #err > 0,
            case[1] .. " was refused with no reason, so nothing could be printed")
    end

    assertEqual(NS.Database.GetWindows()[1].columns, before,
        "a refused write must not have touched the stored array")
end)

test("Schema: the stored array never shares a sub-table with its caller", function()
    -- The classic profile-aliasing bug: a caller holding the table it wrote can
    -- mutate the profile afterwards, past every check this seam performs.
    local inst = T.load()
    local NS = inst.NS

    local mine = { { stat = "DamageDone", enabled = true } }
    assertTrue((NS.SetByPath("window.columns", mine)))
    mine[1].stat = "Deaths"

    assertEqual(NS.Database.GetWindows()[1].columns[1].stat, "DamageDone")
end)
```

Delete the old width-range test near `tests/test_schema.lua:409` (the one calling `NS.SetByPath` with a `width = w`) and the `w.columns = { { stat = "Deaths", width = 44, showBar = true } }` line near line 829, replacing the latter with `w.columns = { { stat = "Deaths", enabled = true } }`.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
lua tests/run.lua 2>&1 | grep -E "^  FAIL|passed,"
```

Expected: the new `Schema: the columns carve-out repairs...` cases FAIL (the current normalizer rejects an entry with no `width`).

- [ ] **Step 3: Rewrite the normalizer**

In `settings/Schema.lua`, delete the `COLUMN_MIN_WIDTH, COLUMN_MAX_WIDTH` local and its comment (around line 1882-1884), and replace the whole of `normalizeColumns` with:

```lua
--- Repair a candidate column array into the catalog, in the caller's order.
---
--- REPAIRING RATHER THAN REJECTING, and that is the change. The array used to be
--- a SUBSET the player assembled, so an entry naming a stat this build does not
--- have was a real editing problem and got surfaced as one: it was stored, listed
--- on the page, and removable. There is nothing to surface now. The array IS the
--- catalog, there is no remove button, and a row for a stat that does not exist
--- is a row nobody can act on. So an unknown stat is DROPPED and a stat this
--- build gained is APPENDED disabled, and a profile carried back from a newer
--- build heals itself instead of growing a dead row.
---
--- ENABLED-FIRST IS ENFORCED HERE, WHICH IS WHY THE PAGE DOES NOT HAVE TO. The
--- Columns page sinks a disabled block below the rule, but `/mm set
--- window.columns ...` and a hand-edited SavedVariables reach this seam without
--- ever drawing a block. Partitioning here is what makes those three routes
--- agree, and the two-list build below is a stable partition: relative order
--- inside each group is exactly the caller's.
---
--- Rebuilding rather than accepting the caller's table also means the stored
--- array can never share a sub-table with whoever handed it over (the classic
--- profile-aliasing bug), and any extra key someone smuggled in is dropped
--- rather than persisted into a profile the renderer will not read.
---
--- @param value any
--- @return table|nil columns, string|nil err
local function normalizeColumns(value)
    if type(value) ~= "table" then
        return nil, L["Columns must be a list of columns, not %s."]:format(type(value))
    end

    local n = #value

    -- A hole or a string key would make `#value` an arbitrary answer, so the array
    -- shape is proved rather than assumed before anything is read out of it.
    local keys = 0
    for _ in pairs(value) do keys = keys + 1 end
    if keys ~= n then
        return nil, L["Columns must be a plain ordered list with no gaps."]
    end

    local enabled, disabled, seen = {}, {}, {}
    for i = 1, n do
        local c = value[i]
        if type(c) ~= "table" then
            return nil, L["Column %d is not a column."]:format(i)
        end

        -- An unknown stat and a repeat are both dropped, silently and on purpose.
        -- The FIRST appearance wins: a later duplicate carrying a different
        -- `enabled` cannot quietly overrule the position the caller already gave
        -- it.
        local stat = c.stat
        if type(stat) == "string" and Const.STAT_BY_KEY[stat] and not seen[stat] then
            seen[stat] = true
            local entry = { stat = stat, enabled = c.enabled and true or false }
            local into  = entry.enabled and enabled or disabled
            into[#into + 1] = entry
        end
    end

    -- Every catalog stat the caller did not mention, appended disabled in catalog
    -- order -- which is what makes a stat added to core/Constants.lua appear on
    -- every existing profile's page with no migration of its own.
    for _, stat in ipairs(Const.STATS) do
        if not seen[stat.key] then
            disabled[#disabled + 1] = { stat = stat.key, enabled = false }
        end
    end

    -- A window with nothing but names in it reads as a broken addon rather than
    -- as a configuration. This is the one thing the repair cannot invent an
    -- answer for: which column did they mean to keep?
    if #enabled == 0 then
        return nil, L["A window must keep at least one column."]
    end

    local out = {}
    for _, entry in ipairs(enabled)  do out[#out + 1] = entry end
    for _, entry in ipairs(disabled) do out[#out + 1] = entry end
    return out
end

--- Published because core/Database.lua's migration ladder needs the same rule and
--- cannot reach a local in a file that loads eighteen entries after it. Read at
--- MIGRATION time rather than at load time, which is the pattern `migrations[1]`
--- already uses for `NS.WINDOW_TEMPLATE`: the ladder runs on Init, long after
--- every file is in memory. A second implementation of "what shape is a column
--- array" is how the migration and the seam end up disagreeing.
NS.NormalizeColumns = normalizeColumns
```

Then in `setColumns`, replace the `announceWrite` line so the debug line reports something that still varies (every array is now the same length):

```lua
    local shown = 0
    for _, c in ipairs(cols) do
        if c.enabled then shown = shown + 1 end
    end
    announceWrite("columns", id, "%s = %d of %d shown", COLUMNS_PREFIX, shown, #cols)
```

- [ ] **Step 4: Rewrite the shipped defaults**

In `defaults/Profile.lua`, replace the column loop in `NS.DefaultWindow` (lines 536-546, the comment block plus the `for _, key in ipairs(Const.DEFAULT_STAT_KEYS)` loop):

```lua
    -- Columns are derived rather than literal, and the catalog IS the list now:
    -- every stat gets an entry, and DEFAULT_STAT_KEYS names the prefix of it that
    -- ships ON. Adding a stat to the catalog therefore puts it on every new
    -- window with no edit here -- ticked if it carries `defaultEnabled`, present
    -- and unticked if it does not, where before it was simply absent.
    --
    -- The two loops are also what makes the enabled-first invariant true of a
    -- fresh window without a sort: everything the first loop emits is enabled and
    -- everything the second emits is not.
    local shipped = {}
    for _, key in ipairs(Const.DEFAULT_STAT_KEYS) do
        shipped[key] = true
        w.columns[#w.columns + 1] = { stat = key, enabled = true }
    end
    for _, stat in ipairs(Const.STATS) do
        if not shipped[stat.key] then
            w.columns[#w.columns + 1] = { stat = stat.key, enabled = false }
        end
    end
```

Also fix the stale comment at `defaults/Profile.lua:487`, which says the array is "Filled by NS.DefaultWindow from Constants.DEFAULT_STAT_KEYS" — it is now filled from `Constants.STATS`, with `DEFAULT_STAT_KEYS` choosing which are on.

- [ ] **Step 5: Add the migration**

In `core/Database.lua`, change line 46 to `local CURRENT_DB_VERSION = 11`, then append after `migrations[9]` (which ends at line 546):

```lua
--- v10 -> v11: THE COLUMN ARRAY BECOMES THE CATALOG.
---
--- `window.columns` was the columns the player had CHOSEN; it is now every
--- statistic this build offers, in their order, each carrying `enabled`. The
--- page that reads it is a fixed list of blocks you tick and drag rather than a
--- list you add to and remove from, and a page that cannot add a column needs
--- every column already present to tick.
---
--- `width` and `showBar` are pruned rather than left. Width has been dead since
--- the window began auto-sizing -- BuildLayout divides the frame width evenly
--- across the visible columns and has never read `col.width` -- and the bar is
--- unconditional now. AceDB merges defaults in and never removes what they
--- stopped naming, so a field nobody prunes is a field that outlives its reader.
---
--- IT GOES THROUGH NS.NormalizeColumns RATHER THAN RESTATING THE RULE. That
--- function is settings/Schema.lua's, which loads eighteen TOC entries after this
--- file -- but the ladder RUNS on Init, long after every file is in memory, which
--- is the same deferred read `migrations[1]` already makes for NS.WINDOW_TEMPLATE.
--- A private copy of "what shape is a column array" here is how the migration and
--- the write seam end up disagreeing about it.
migrations[10] = function(db)
    local normalize = NS.NormalizeColumns

    for _, profile in ipairs(allProfiles(db)) do
        for _, w in ipairs(type(profile.windows) == "table" and profile.windows or {}) do
            if type(w) == "table" and type(w.columns) == "table" then
                -- Every stored column was a column the player was SHOWN, so every
                -- one of them arrives enabled. The normalizer appends the rest
                -- disabled and drops anything this build no longer has.
                local carried = {}
                for _, col in ipairs(w.columns) do
                    if type(col) == "table" and type(col.stat) == "string" then
                        carried[#carried + 1] = { stat = col.stat, enabled = true }
                    end
                end

                -- The refusal case is a profile whose every column named a stat
                -- this build dropped, which leaves nothing enabled and no way to
                -- guess what they meant. The shipped list is the only honest
                -- answer, and it is what a new window would have had anyway.
                w.columns = (normalize and normalize(carried))
                    or (NS.DefaultWindow and NS.DefaultWindow(w.id).columns)
                    or w.columns
            end
        end
    end

    db.global.schemaVersion = 11
end
```

- [ ] **Step 6: Update the remaining tests to the new shape**

In `tests/test_defaults.lua`:
- Line 84: delete the `assertEqual(b.columns[1].width, ...)` assertion — the field is gone.
- Line 96: the `assertEqual(table.concat(keys, ","), table.concat(Const.DEFAULT_STAT_KEYS, ","))` check now describes the **enabled prefix**. Change it to build `keys` from enabled entries only.
- Line 109: replace the `column.showBar` assertion with:

```lua
        assertEqual(column.width, nil, "column " .. i .. " must not carry a dead width")
        assertEqual(column.showBar, nil, "column " .. i .. " must not carry a dead show-bar flag")
```

- Line 196 and the loop around it: `enabled[key] = true` from `DEFAULT_STAT_KEYS` still describes which ship on; assert the entry exists with that `enabled` value rather than asserting presence.

Add:

```lua
test("Defaults: a new window carries every statistic, defaults ticked and first", function()
    local inst = T.load()
    local Const = inst.NS.Constants
    local w = inst.NS.DefaultWindow(1, "Test")

    assertEqual(#w.columns, #Const.STATS, "the column array IS the catalog")

    local on = {}
    for _, key in ipairs(Const.DEFAULT_STAT_KEYS) do on[key] = true end

    local sawDisabled = false
    for i, c in ipairs(w.columns) do
        assertEqual(c.enabled, on[c.stat] == true,
            "column " .. i .. " (" .. c.stat .. ") does not match its defaultEnabled flag")
        if not c.enabled then sawDisabled = true end
        if c.enabled then
            assertFalse(sawDisabled, "an enabled column must never follow a disabled one")
        end
    end
end)
```

In `tests/test_database.lua`:
- Line 215-219: the round-trip stub `{ stat = "Deaths", width = 44, showBar = false } }` becomes `{ stat = "Deaths", enabled = true }`, and the `showBar` assertion becomes an `enabled` one.
- Lines 380-382 and 415: the v1 migration fixture keeps `width`/`showBar` (it is testing a v1 profile, which really did have them) — leave it, but assert the **post-ladder** result is the new shape.
- Lines 457-460: `{ stat = "Deaths", width = 44, showBar = true }` becomes `{ stat = "Deaths", enabled = true }`.

Add:

```lua
test("Database: v10 -> v11 turns the chosen columns into the whole catalog", function()
    local inst = T.load()
    local NS = inst.NS
    local Const = NS.Constants

    NS.db.global.schemaVersion = 10
    local w = NS.Database.GetWindows()[1]
    w.columns = {
        { stat = "Deaths",     width = 44, showBar = true },
        { stat = "DamageDone", width = 92, showBar = false },
    }

    NS:RunMigrations()

    assertEqual(NS.db.global.schemaVersion, 11)
    local cols = NS.Database.GetWindows()[1].columns
    assertEqual(#cols, #Const.STATS, "every statistic must be present after the migration")
    assertEqual(cols[1].stat, "Deaths", "the player's order survives")
    assertEqual(cols[2].stat, "DamageDone")
    assertTrue(cols[1].enabled, "a column that was SHOWN arrives enabled")
    assertTrue(cols[2].enabled, "showBar = false was never 'hidden', so it stays enabled too")
    for i = 3, #cols do
        assertFalse(cols[i].enabled, "a statistic that was not a column arrives disabled")
    end
    assertEqual(cols[1].width, nil, "width must be pruned, not left for AceDB to merge forward")
    assertEqual(cols[1].showBar, nil, "showBar must be pruned")
end)

test("Database: v10 -> v11 falls back to the shipped list when nothing survives", function()
    -- A profile whose every column named a stat this build dropped leaves nothing
    -- enabled, and there is no way to guess what the player meant.
    local inst = T.load()
    local NS = inst.NS

    NS.db.global.schemaVersion = 10
    NS.Database.GetWindows()[1].columns = {
        { stat = "GoneStat",    width = 44, showBar = true },
        { stat = "AlsoGoneStat", width = 44, showBar = true },
    }

    NS:RunMigrations()

    local cols = NS.Database.GetWindows()[1].columns
    assertEqual(#cols, #NS.Constants.STATS)
    local shown = 0
    for _, c in ipairs(cols) do
        if c.enabled then shown = shown + 1 end
    end
    assertEqual(shown, #NS.Constants.DEFAULT_STAT_KEYS,
        "the shipped list is the only honest answer when nothing survived")
end)
```

In `tests/test_windowmanager.lua:113`, change `#inst.NS.Constants.DEFAULT_STAT_KEYS` to `#inst.NS.Constants.STATS`.

- [ ] **Step 7: Run the full suite and lint**

```bash
lua tests/run.lua 2>&1 | tail -3
luacheck . 2>&1 | tail -3
```

Expected: 0 failed, and 0 warnings / 0 errors. Other suites (`test_columns`, `test_row`, `test_window`) will still be **red** at this point because they assert the old shape — that is expected and Tasks 2 and 4 fix them. **Do not commit until they are green**, so fix the mechanical fixtures they use now: `tests/test_row.lua:33-34`, `tests/test_window.lua:1054-1055` and every `{ stat = ..., width = ..., showBar = ... }` literal in `tests/test_columns.lua` become `{ stat = ..., enabled = true }`. Any assertion about width sliders, show-bar checkboxes or add/remove buttons that now fails is Task 4's problem — if it blocks, `T.skip` it with a comment naming Task 4 and remove the skip there.

- [ ] **Step 8: Commit**

```bash
git add settings/Schema.lua defaults/Profile.lua core/Database.lua tests/
git commit -F - <<'EOF'
Make the column array the catalog rather than a subset of it

`window.columns` was the columns the player had CHOSEN, which is the
wrong list for the question they actually ask -- "which of these
statistics do I want, and in what order". It is now every statistic this
build offers, in their order, each carrying `enabled`, with the enabled
ones stored ahead of the disabled ones.

Enabled-first is enforced in the normalizer rather than by the page,
because `/mm set window.columns` and a hand-edited SavedVariables reach
that seam without ever drawing a block, and three routes to one stored
shape is three chances to disagree about it.

The normalizer also REPAIRS rather than rejects now. An unknown stat used
to be stored and listed so the player could remove it; with no remove
button and a list that IS the catalog there is nothing they could do with
it, so it is dropped and a stat this build gained is appended disabled.

`width` and `showBar` are pruned. Width has been dead since the window
began auto-sizing -- BuildLayout divides the frame width evenly across
the visible columns and has never read `col.width` -- and the bar is
unconditional from here on.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_019FtWnLGKT5uimw6X63zTzr
EOF
```

---

### Task 2: The renderers consume `enabled`

**Files:**
- Modify: `modules/Window.lua:325-350` — `BuildLayout`'s `visible` filter and the layout entry
- Modify: `modules/Row.lua:680-684` (`ApplyBarSkin`), `872-896` (`ApplyLayout`), `922-928` (`SetValue`)
- Test: `tests/test_window.lua`, `tests/test_row.lua`

**Interfaces:**
- Consumes: the stored shape from Task 1 — `{ stat, enabled }`
- Produces: layout entries shaped `{ key, stat, x, width }`. **`showBar` is no longer a field on a layout entry**; `Cell.showBar` no longer exists.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_window.lua`:

```lua
test("Window: BuildLayout draws only the enabled columns, in stored order", function()
    local inst, window = scene{}
    window.config.columns = {
        { stat = "Interrupts",  enabled = true  },
        { stat = "DamageDone",  enabled = true  },
        { stat = "HealingDone", enabled = false },
        { stat = "Deaths",      enabled = false },
    }

    local layout = window:BuildLayout()
    assertEqual(#layout.columns, 2, "a disabled statistic is not a column")
    assertEqual(layout.columns[1].key, "Interrupts", "the stored order is the drawn order")
    assertEqual(layout.columns[2].key, "DamageDone")
    assertEqual(layout.columns[1].showBar, nil,
        "showBar is not a layout field any more; the bar is unconditional")
    assertTrue(inst ~= nil)
end)
```

Add to `tests/test_row.lua`, replacing the test around line 405 that sets `cfg.columns[1].showBar = false`:

```lua
test("Row: every cell draws its bar, because the bar is not optional", function()
    -- Show-bar used to be a per-column checkbox. The bar is what makes the grid
    -- readable at a glance, and a numbers-only column is a worse column -- so
    -- there is no longer a state in which a cell paints its fill transparent.
    local _, row = rowScene()
    for i, cell in ipairs(row.cells or {}) do
        assertEqual(cell.showBar, nil,
            "cell " .. i .. " still carries a show-bar decision")
    end
end)
```

Adapt `rowScene`/`scene` to whatever the surrounding helpers in each file are actually called — read the top of each test file first and match it.

- [ ] **Step 2: Run to verify they fail**

```bash
lua tests/run.lua 2>&1 | grep -E "^  FAIL|passed,"
```

Expected: both new tests FAIL.

- [ ] **Step 3: Filter on `enabled` in `BuildLayout`**

In `modules/Window.lua`, replace the `visible` loop (currently lines 325-333):

```lua
    local visible = {}
    for _, col in ipairs(cfg.columns or {}) do
        -- TWO REASONS A STORED ENTRY IS NOT DRAWN, and they are different facts.
        -- `enabled == false` is the player's decision, made on the Columns page
        -- and reversible there. An unknown stat is a profile written against a
        -- build with more statistics than this one -- normalizeColumns drops
        -- those on the way in, so reaching one here means a profile that has not
        -- been through the seam yet, and a nameless empty column is worse than an
        -- absent one either way.
        local stat = col.enabled and Const.STAT_BY_KEY[col.stat]
        if stat then visible[#visible + 1] = { col = col, stat = stat } end
    end
```

And drop `showBar` from the layout entry (currently lines 344-350):

```lua
    for _, entry in ipairs(visible) do
        layout.columns[#layout.columns + 1] = {
            key   = entry.col.stat,
            stat  = entry.stat,
            x     = x,
            width = statWidth,
        }
        x = x + statWidth + COLUMN_GAP
    end
```

- [ ] **Step 4: Make the bar unconditional in `modules/Row.lua`**

`ApplyBarSkin` (line 680-683) — drop the dead parameter and its doc line:

```lua
--- Skin the StatusBar itself: fill texture, fill direction, and the backdrop
--- that sits behind the fill.
---
--- @param bars table|nil   the window's `bars` config group
function Cell:ApplyBarSkin(bars)
```

`ApplyLayout` (872-896) — drop `showBar` from the doc comment, the local, the `ApplyBarSkin` call and the trailing assignment:

```lua
--- @param layout table  the window's computed layout (see modules/Window.lua)
--- @param col table     this cell's column descriptor { x, width }
function Cell:ApplyLayout(layout, col)
    local cfg = self.window.config
    local bar = self.frame

    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", self.row.frame, "TOPLEFT", col.x, 0)
    bar:SetSize(col.width, layout.rowHeight)

    local bars = cfg.bars
    self:ApplyBarSkin(bars)
    self:ApplyBorder(bars)

    -- `text.alpha` is applied INSIDE ApplyTextStyle, to the two FontStrings. The
    -- bar's own alpha is `bars.alpha` alone (ApplyBarSkin, just above) — it is the
    -- parent of everything in the cell, so folding the text setting into it faded
    -- the fill and the icons too.
    local text = cfg.text or {}
    self:ApplyTextStyle(text)
end
```

`SetValue` (922-928) — the branch goes:

```lua
    -- UNCONDITIONAL. Show-bar was a per-column checkbox and is not a choice any
    -- more: the bar is what makes the grid readable at a glance, so there is no
    -- state in which a cell paints its fill transparent.
    local r, g, b = barColor(cfg.bars, entry, self.key)
    bar:SetStatusBarColor(r, g, b)
```

- [ ] **Step 5: Run to verify they pass**

```bash
lua tests/run.lua 2>&1 | tail -3
luacheck . 2>&1 | tail -3
```

Expected: 0 failed, 0 warnings / 0 errors. `test_columns.lua` may still carry skips from Task 1 Step 7 — that is fine.

- [ ] **Step 6: Commit**

```bash
git add modules/Window.lua modules/Row.lua tests/
git commit -F - <<'EOF'
Draw the enabled columns, and draw every bar

BuildLayout used to filter on one question -- is this statistic in the
catalog -- and now asks two, which are different facts. `enabled == false`
is the player's decision, made on the Columns page and reversible there.
An unknown stat is a profile written against a build with more statistics
than this one, which normalizeColumns already drops on the way in.

Show-bar goes with it. The bar is what makes the grid readable at a
glance, and a numbers-only column is a worse column, so there is no
longer a state in which a cell paints its fill transparent -- which takes
the flag off the layout entry, off the cell, and out of ApplyBarSkin's
signature, where it had already decayed to an unread `_showBar`.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_019FtWnLGKT5uimw6X63zTzr
EOF
```

---

### Task 3: The reorderable block list

A generic widget. It knows about blocks, handles, glyphs and a boundary — never about statistics. This is the unit issue #21 promotes to LibKa0s, which is why it is its own file.

**Files:**
- Create: `settings/ColumnBlocks.lua`
- Create: `tests/test_columnblocks.lua`
- Modify: `MultiMeters.toc` — insert `settings\ColumnBlocks.lua` immediately **before** `settings\Columns.lua`
- Modify: `tests/wow_mock.lua` — add `GetCursorPosition` and `setCursor`
- Modify: `tests/run.lua` if it enumerates test files explicitly (check first)

**Interfaces:**
- Consumes: `NS.Helpers` (`EnsureScroll`, `AttachTooltip`), `NS.AceGUI`, `NS.Icon`
- Produces:
  - `NS.ReorderableBlocks(ctx, spec) -> table` — renders the blocks into `ctx`'s scroll and returns the array of block frames it built (for tests). `spec` is:
    ```lua
    {
        items    = { { key = "DamageDone", label = "Damage", enabled = true }, ... },
        onToggle = function(index) end,   -- the glyph was clicked
        onMove   = function(from, to) end, -- a drag landed; to ~= from guaranteed
    }
    ```
  - Each returned block carries `block.mmIndex`, `block.mmHandle`, `block.mmGlyph` and `block.mmLabel` so a test can drive it without reaching into file locals.
  - Constants `NS.BLOCK_HEIGHT` and `NS.BLOCK_STRIDE` (height plus the gap), published because the page's tests compute drop distances from them.

- [ ] **Step 1: Add the cursor to the mock**

In `tests/wow_mock.lua`, immediately after `M.InCombatLockdown = function() ... end` (line 986), add:

```lua
    -- ── the cursor ─────────────────────────────────────────────────────────
    --
    -- settings/ColumnBlocks.lua's drag reads it on every OnUpdate frame, and a
    -- drag nothing offline can drive is a drag that ships untested -- which is
    -- exactly how a page's button once shipped wired to nothing at all. Scaled
    -- coordinates, like the real one: callers divide by GetEffectiveScale().
    M.__cursorX, M.__cursorY = 0, 0
    M.GetCursorPosition = function() return M.__cursorX, M.__cursorY end
    function M.setCursor(x, y) M.__cursorX, M.__cursorY = x or 0, y or 0 end
```

Add `mocks.setCursor(x, y)` to the helper list in the header comment at line 138.

- [ ] **Step 2: Write the failing widget tests**

Create `tests/test_columnblocks.lua`:

```lua
-- tests/test_columnblocks.lua
--
-- settings/ColumnBlocks.lua — a reorderable list of blocks, and nothing else.
--
-- IT KNOWS NOTHING ABOUT STATISTICS. That is the whole point of it being its own
-- file: it is the unit issue #21 promotes to LibKa0s once a second addon wants an
-- orderable list, and a widget that had learned what a column is could not make
-- that move. Everything statistic-shaped is settings/Columns.lua's, and this
-- suite drives the widget with a made-up item list to keep the two apart.
--
-- THE DRAG IS DRIVEN THROUGH ITS REAL SCRIPTS, with mocks.setCursor moving the
-- pointer between frames. A drag asserted by calling the reorder function
-- directly would pass with the handle wired to nothing.

local T = _G.MULTIMETERS_TEST
local test = T.test
local assertEqual, assertTrue, assertFalse = T.assertEqual, T.assertTrue, T.assertFalse

local ITEMS = {
    { key = "a", label = "Alpha",   enabled = true  },
    { key = "b", label = "Bravo",   enabled = true  },
    { key = "c", label = "Charlie", enabled = true  },
    { key = "d", label = "Delta",   enabled = false },
    { key = "e", label = "Echo",    enabled = false },
}

--- A rendered block list over ITEMS, plus a log of what it asked for.
local function render(inst, items)
    local NS  = inst.NS
    local log = { toggled = {}, moved = {} }

    local ctx = NS.Helpers.CreatePanel("MultiMetersBlockTestPanel", "Blocks", {})
    NS.Helpers.ClearScroll(ctx)

    local blocks = NS.ReorderableBlocks(ctx, {
        items    = items or ITEMS,
        onToggle = function(i) log.toggled[#log.toggled + 1] = i end,
        onMove   = function(from, to) log.moved[#log.moved + 1] = { from, to } end,
    })
    return blocks, log
end

--- Pick block `from` up, move the cursor `blocks` rows DOWN, and drop it.
local function drag(inst, blocks, from, rows)
    local handle = blocks[from].mmHandle
    inst.mocks.setCursor(0, 1000)
    handle:_run("OnDragStart")
    inst.mocks.setCursor(0, 1000 - rows * inst.NS.BLOCK_STRIDE)
    handle:_run("OnUpdate", 0.1)
    handle:_run("OnDragStop")
end

test("Blocks: one block per item, each carrying its index and its label", function()
    local inst = T.load()
    local blocks = render(inst)

    assertEqual(#blocks, #ITEMS)
    for i, item in ipairs(ITEMS) do
        assertEqual(blocks[i].mmIndex, i)
        assertEqual(blocks[i].mmLabel:GetText(), item.label)
    end
end)

test("Blocks: the glyph says enabled or disabled, and clicking it toggles", function()
    local inst = T.load()
    local blocks, log = render(inst)

    assertFalse(blocks[1].mmGlyph:GetTexture() == blocks[4].mmGlyph:GetTexture(),
        "an enabled block and a disabled one must not wear the same glyph")

    blocks[4].mmGlyph:_run("OnClick")
    assertEqual(#log.toggled, 1)
    assertEqual(log.toggled[1], 4, "the glyph must report ITS OWN index")
end)

test("Blocks: only the handle takes the mouse for dragging", function()
    -- Making the whole block draggable means a click meant for the glyph starts a
    -- drag instead, and the two gestures are a few pixels apart.
    local inst = T.load()
    local blocks = render(inst)

    assertTrue(blocks[1].mmHandle.__dragButtons ~= nil,
        "the handle must be registered for drag")
    assertEqual(blocks[1].__dragButtons, nil,
        "the block itself must not be draggable")
end)

test("Blocks: a drag reports where it landed", function()
    local inst = T.load()
    local blocks, log = render(inst)

    drag(inst, blocks, 1, 2)
    assertEqual(#log.moved, 1)
    assertEqual(log.moved[1][1], 1)
    assertEqual(log.moved[1][2], 3, "two rows down from index 1 is index 3")
end)

test("Blocks: a drag that lands where it started reports nothing", function()
    local inst = T.load()
    local blocks, log = render(inst)

    drag(inst, blocks, 2, 0)
    assertEqual(#log.moved, 0, "a drag with no movement is not a reorder")
end)

test("Blocks: an enabled block cannot be dragged past the last enabled one", function()
    -- The tick is what moves a block between groups. A drag that crossed the rule
    -- would have to silently disable it -- a state change from a gesture that
    -- means "move", not "turn off".
    local inst = T.load()
    local blocks, log = render(inst)

    drag(inst, blocks, 1, 4)
    assertEqual(#log.moved, 1)
    assertEqual(log.moved[1][2], 3, "clamped to the last enabled index, not index 5")
end)

test("Blocks: a disabled block cannot be dragged above the rule", function()
    local inst = T.load()
    local blocks, log = render(inst)

    drag(inst, blocks, 5, -4)
    assertEqual(#log.moved, 1)
    assertEqual(log.moved[1][2], 4, "clamped to the first disabled index, not index 1")
end)

test("Blocks: a list with nothing disabled still drags end to end", function()
    local inst = T.load()
    local allOn = {}
    for i, item in ipairs(ITEMS) do
        allOn[i] = { key = item.key, label = item.label, enabled = true }
    end
    local blocks, log = render(inst, allOn)

    drag(inst, blocks, 1, 4)
    assertEqual(log.moved[1][2], 5, "with no rule to clamp against, every index is reachable")
end)
```

- [ ] **Step 3: Run to verify they fail**

```bash
lua tests/run.lua 2>&1 | grep -E "Blocks:|passed,"
```

Expected: every `Blocks:` test FAILS with `NS.ReorderableBlocks` being nil.

- [ ] **Step 4: Write the widget**

Create `settings/ColumnBlocks.lua`:

```lua
-- settings/ColumnBlocks.lua
--
-- A reorderable list of blocks: a drag handle, a state glyph, a label, and a rule
-- where the enabled ones stop.
--
-- ---------------------------------------------------------------------------
-- WHY THIS IS ITS OWN FILE, AND WHY IT IS NOT IN LibKa0s YET
-- ---------------------------------------------------------------------------
--
-- Nothing here knows what a statistic is. It takes `items` and answers with
-- indices, which is what makes it the same widget any Ka0s addon with an ordered,
-- user-arrangeable list would want -- and by the Ka0s WoW Addon Standard a
-- generic options widget belongs in LibKa0s-Options beside Section, TextRow,
-- RenderGrid and InlineButtonPair, not in an addon's settings/.
--
-- It is here anyway, deliberately, and the deviation is ratified in
-- docs/ARCHITECTURE.md -> Documented deviations. A LibKa0s widget re-vendors into
-- every addon in the collection, so its API is expensive to change once shipped,
-- and one consumer is not enough evidence to freeze a signature on. Keeping it in
-- its own file rather than inside the page is what makes the promotion a file
-- move rather than an extraction. Tracked as issue #21.
--
-- ---------------------------------------------------------------------------
-- WHY THE DRAG IS INDEX ARITHMETIC AND NOT A HIT TEST
-- ---------------------------------------------------------------------------
--
-- Every block is the same height, so where the cursor has landed is a division:
-- how far it has moved, over the stride. Nothing is asked which block is under
-- the pointer, so nothing depends on the blocks having been laid out yet, on the
-- scroll position, or on AceGUI having finished its layout pass -- all three of
-- which are true at different times during a drag.
--
-- ON RULE R3. This reads geometry off OPTIONS-PANEL frames. Rule R3 is about
-- cells that have been handed a meter value through SetValue and have secret
-- anchoring data from that moment on; an options frame never receives one. The
-- same distinction modules/Window.lua already records for GetStringWidth on the
-- sort arrow's FontString.

local addonName, NS = ...

local L = NS.L
local H = NS.Helpers or {}

-- The height of one block and the distance from one block's top to the next's.
-- Published because settings/Columns.lua's suite computes drop distances from
-- them, and a test carrying its own copy of the stride is a test that passes
-- while the widget drops blocks in the wrong place.
NS.BLOCK_HEIGHT = 30
NS.BLOCK_STRIDE = NS.BLOCK_HEIGHT + 4

local ENABLED_TEX  = "Interface\\RaidFrame\\ReadyCheck-Ready"
local DISABLED_TEX = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local HANDLE_ICON  = "list"

--- Where a block dropped `rows` rows from `from` lands, clamped to its own group.
---
--- THE CLAMP IS THE INTERACTION RULE, not a safety check. You reorder within your
--- own group and the tick is what moves you between them, so a drag that would
--- cross the rule stops at it. Without that, dropping an enabled block into the
--- disabled half would have to silently untick it -- a state change from a
--- gesture that means "move".
---
--- @param from number      the index picked up
--- @param rows number      how many rows down the cursor travelled (negative = up)
--- @param count number     how many blocks there are
--- @param boundary number  how many of them are enabled
--- @return number index    a valid index in `from`'s own group
local function dropIndex(from, rows, count, boundary)
    local lo, hi
    if from <= boundary then
        lo, hi = 1, boundary
    else
        lo, hi = boundary + 1, count
    end

    local to = from + rows
    if to < lo then to = lo end
    if to > hi then to = hi end
    return to
end

--- One block: the handle, the glyph and the label, on a plain frame.
---
--- A raw CreateFrame rather than an AceGUI widget because AceGUI has no block --
--- a SimpleGroup would give a container and then every child would still be built
--- by hand inside it, for a layout that is three fixed positions.
local function makeBlock(parent, index, item, spec)
    local block = CreateFrame("Button", nil, parent)
    block:SetHeight(NS.BLOCK_HEIGHT)
    block:SetPoint("LEFT", parent, "LEFT", 0, 0)
    block:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    block.mmIndex = index

    local border = block:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints(block)
    border:SetColorTexture(1, 1, 1, item.enabled and 0.06 or 0.03)

    -- ONLY THE HANDLE TAKES THE MOUSE FOR DRAGGING. Making the whole block
    -- draggable means a click aimed at the glyph starts a drag instead, and the
    -- two are a few pixels apart.
    local handle = CreateFrame("Button", nil, block)
    handle:SetSize(16, 16)
    handle:SetPoint("LEFT", block, "LEFT", 8, 0)
    handle:RegisterForDrag("LeftButton")
    local handleTex = handle:CreateTexture(nil, "ARTWORK")
    handleTex:SetAllPoints(handle)
    if NS.Icon then handleTex:SetTexture(NS.Icon(HANDLE_ICON)) end
    handleTex:SetVertexColor(0.7, 0.7, 0.7)
    block.mmHandle = handle

    local glyph = CreateFrame("Button", nil, block)
    glyph:SetSize(18, 18)
    glyph:SetPoint("LEFT", block, "LEFT", 40, 0)
    glyph:SetNormalTexture(item.enabled and ENABLED_TEX or DISABLED_TEX)
    glyph.GetTexture = function() return item.enabled and ENABLED_TEX or DISABLED_TEX end
    glyph:SetScript("OnClick", function()
        if spec.onToggle then spec.onToggle(index) end
    end)
    block.mmGlyph = glyph

    local label = block:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("RIGHT", block, "RIGHT", -10, 0)
    label:SetJustifyH("RIGHT")
    label:SetText(item.label or "")
    -- Greyed rather than hidden: a disabled block is still a block you can drag,
    -- and a label you cannot read is a block you cannot aim at.
    if not item.enabled then label:SetTextColor(0.5, 0.5, 0.5) end
    block.mmLabel = label

    return block
end

--- Wire one block's handle to the drag.
local function wireDrag(block, spec, count, boundary)
    local handle = block.mmHandle
    local startY, rows

    handle:SetScript("OnDragStart", function()
        local _, y = GetCursorPosition()
        startY = y / UIParent:GetEffectiveScale()
        rows = 0
        handle:SetScript("OnUpdate", handle.mmTrack)
    end)

    -- Stored on the handle rather than closed over, so OnDragStart can install it
    -- and OnDragStop can take it off again without either holding the other.
    handle.mmTrack = function()
        if not startY then return end
        local _, y = GetCursorPosition()
        local moved = startY - (y / UIParent:GetEffectiveScale())
        -- +0.5 then floor is round-to-nearest: a block dragged 60% of the way to
        -- the next slot has visibly left its own, and rounding down would drop it
        -- back where it started.
        rows = math.floor(moved / NS.BLOCK_STRIDE + 0.5)
    end

    handle:SetScript("OnDragStop", function()
        handle:SetScript("OnUpdate", nil)
        if not startY then return end
        startY = nil

        local to = dropIndex(block.mmIndex, rows or 0, count, boundary)
        -- A drag that lands where it started is not a reorder, and reporting one
        -- would rewrite the array and repaint the page for nothing.
        if to ~= block.mmIndex and spec.onMove then
            spec.onMove(block.mmIndex, to)
        end
    end)
end

--- Render `spec.items` as blocks into `ctx`'s scroll.
---
--- @param ctx table   an options page context (H.CreatePanel's return)
--- @param spec table  { items, onToggle, onMove }
--- @return table blocks  the block frames, in order
function NS.ReorderableBlocks(ctx, spec)
    local scroll = H.EnsureScroll and H.EnsureScroll(ctx)
    local AceGUI = NS.AceGUI
    if not (scroll and AceGUI) then return {} end

    local items = spec.items or {}
    local count = #items

    local boundary = 0
    for _, item in ipairs(items) do
        if item.enabled then boundary = boundary + 1 end
    end

    local blocks = {}
    for i, item in ipairs(items) do
        -- One AceGUI SimpleGroup per block, holding one raw frame. The group is
        -- what the ScrollFrame lays out; the frame inside it is what this file
        -- draws. Going through AceGUI for the LAYOUT and no further is what keeps
        -- the blocks flowing with the rest of the page without asking AceGUI for
        -- a widget it does not have.
        local slot = AceGUI:Create("SimpleGroup")
        slot:SetLayout(nil)
        slot:SetFullWidth(true)
        slot:SetHeight(NS.BLOCK_STRIDE)
        scroll:AddChild(slot)

        local block = makeBlock(slot.frame or slot.content, i, item, spec)
        wireDrag(block, spec, count, boundary)
        blocks[i] = block

        -- The rule: drawn under the LAST enabled block, so it marks where the
        -- shown columns stop. Nothing above it is disabled, nothing below it is
        -- enabled -- which is a property normalizeColumns guarantees, not one
        -- this file arranges.
        if i == boundary and boundary < count then
            local rule = AceGUI:Create("Heading")
            rule:SetText("")
            rule:SetFullWidth(true)
            rule:SetHeight(12)
            scroll:AddChild(rule)
        end
    end

    return blocks
end
```

- [ ] **Step 5: Register the file**

In `MultiMeters.toc`, insert `settings\ColumnBlocks.lua` on the line immediately before `settings\Columns.lua`. Then check whether `tests/run.lua` enumerates addon files or test files explicitly:

```bash
grep -n "ADDON_FILES\|test_" tests/run.lua | head -20
```

If there is an explicit list, add `settings/ColumnBlocks.lua` and `tests/test_columnblocks.lua` to it. `tests/test_vendor_sync.lua` may also assert the TOC matches a file list — run the suite and read what it says.

- [ ] **Step 6: Run to verify they pass**

```bash
lua tests/run.lua 2>&1 | grep -E "Blocks:|^  FAIL|passed,"
luacheck . 2>&1 | tail -3
```

Expected: every `Blocks:` test PASSES, 0 failed overall, 0 warnings / 0 errors.

- [ ] **Step 7: Commit**

```bash
git add settings/ColumnBlocks.lua tests/test_columnblocks.lua tests/wow_mock.lua MultiMeters.toc tests/run.lua
git commit -F - <<'EOF'
Add a reorderable block list, drag and all

A drag handle, a state glyph, a label, and a rule where the enabled ones
stop. It takes `items` and answers with indices, and knows nothing about
statistics -- which is what makes it the widget any Ka0s addon with an
ordered list would want, and why it is its own file rather than a section
of the page: issue #21 promotes it to LibKa0s once a second addon wants
one, and that should be a file move rather than an extraction.

The drop target is index arithmetic, not a hit test. Every block is the
same height, so where the cursor landed is a division -- which means
nothing depends on the blocks having been laid out yet, on the scroll
position, or on AceGUI having finished its layout pass, all three of
which are true at different moments during a drag.

The clamp is the interaction rule rather than a safety check: you reorder
within your own group and the tick is what moves you between them, so a
drag that would cross the rule stops at it instead of silently unticking
what it carried.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_019FtWnLGKT5uimw6X63zTzr
EOF
```

---

### Task 4: The Columns page

**Files:**
- Rewrite: `settings/Columns.lua`
- Rewrite: `tests/test_columns.lua`

**Interfaces:**
- Consumes: `NS.ReorderableBlocks(ctx, spec)`, `NS.BLOCK_STRIDE` (Task 3); the stored shape and `NS.SetByPath("window.columns", ...)` (Task 1)
- Produces: nothing other files read. The page is a leaf.

- [ ] **Step 1: Rewrite the page**

Replace `settings/Columns.lua` entirely. Keep the existing file's two header essays — **why column editing lives here and only here**, and **why the writes go through the schema seam** — verbatim; they are still true and still the reason the file exists. Replace everything from `-- Per-column widgets` onward with:

```lua
-- ---------------------------------------------------------------------------
-- Mutations
-- ---------------------------------------------------------------------------

-- Each answers with the seam's verdict rather than swallowing it, so a caller
-- (and a test) can tell an applied edit from a refused one.

--- Tick or untick one block.
---
--- A TOGGLE IS ALSO A MOVE, and that is the whole interaction. Ticking sends the
--- block to the END of the enabled group -- it becomes the rightmost column,
--- which is where a column you just added belongs. Unticking sends it to the TOP
--- of the disabled group, which is the shortest travel available: the player
--- watches it drop just below the rule rather than hunting for where it went.
---
--- The seam re-sorts anyway (normalizeColumns partitions enabled ahead of
--- disabled), so the position built here is only ever a position WITHIN a group.
--- Building it explicitly is what makes the two ends predictable rather than
--- whatever a stable partition happened to leave.
local function toggle(index)
    local w = activeWindow()
    if not w then return false end

    local cols = snapshot(w)
    local entry = cols[index]
    if not entry then return false end

    -- A window with nothing but names in it reads as a broken addon. The seam
    -- refuses this too, but refusing here is what puts the reason in front of the
    -- player attached to the click that caused it.
    if entry.enabled then
        local shown = 0
        for _, c in ipairs(cols) do
            if c.enabled then shown = shown + 1 end
        end
        if shown <= 1 then
            print_(L["A window must keep at least one column."])
            return false
        end
    end

    tremove(cols, index)
    entry.enabled = not entry.enabled

    local boundary = 0
    for _, c in ipairs(cols) do
        if c.enabled then boundary = boundary + 1 end
    end

    tinsert(cols, entry.enabled and boundary + 1 or boundary + 1, entry)
    return commit(cols)
end

--- Move one block to another index. Both are already in the same group -- the
--- widget clamped the drop before it ever got here.
local function reorder(from, to)
    local w = activeWindow()
    if not w then return false end

    local cols = snapshot(w)
    if not (cols[from] and cols[to]) or from == to then return false end

    local entry = tremove(cols, from)
    tinsert(cols, to, entry)
    return commit(cols)
end

-- ---------------------------------------------------------------------------
-- The body
-- ---------------------------------------------------------------------------

--- The stored array as the widget wants it: a label per entry, localized HERE
--- because core/Constants.lua stores the English label and deliberately does not
--- call L itself (locales/ may load either side of it).
---
--- A stat this build does not have cannot appear -- normalizeColumns drops it on
--- the way in -- so there is no unknown-stat row to render and no fallback label
--- to invent.
local function items(w)
    local out = {}
    for i, c in ipairs(columnsOf(w)) do
        local stat = Const.STAT_BY_KEY[c.stat]
        out[i] = {
            key     = c.stat,
            label   = stat and L[stat.label] or tostring(c.stat),
            enabled = c.enabled and true or false,
        }
    end
    return out
end

local function render(ctx)
    H.ClearScroll(ctx)

    local w = activeWindow()
    if not w then
        H.TextRow(ctx, L["No window is selected."])
        H.Relayout(ctx)
        return
    end

    H.TextRow(ctx, L["Every statistic this build offers. Ticked ones are the columns "
        .. "this window shows, left to right, top to bottom. Drag a block by its handle to "
        .. "reorder them. Columns can only be changed out of combat."])

    NS.ReorderableBlocks(ctx, {
        items    = items(w),
        onToggle = toggle,
        onMove   = reorder,
    })

    H.Relayout(ctx)
end
```

Delete `makeStatDropdown`, `makeWidthSlider`, `makeShowBarCheckbox`, `makeColumnActions`, `renderColumn`, `renderAddColumn`, `unusedStatList`, `pendingStat`, `addColumn`, `removeColumn`, and the `H.Section(ctx, L["Column list"])` call. Update `snapshot` to copy the new shape:

```lua
local function snapshot(w)
    local out = {}
    for i, c in ipairs(columnsOf(w)) do
        out[i] = { stat = c.stat, enabled = c.enabled and true or false }
    end
    return out
end
```

`commit`, `activeWindow`, `columnsOf`, `print_` and `Build` are unchanged. Keep `Build`'s "No Defaults button" comment as it stands.

- [ ] **Step 2: Rewrite the page tests**

Rewrite `tests/test_columns.lua`. Keep its header essay's first two paragraphs (why the editor lives on a settings page, and why it is driven through rendered widgets), then replace the "four properties worth the setup" list with the properties that now apply, and replace the body with:

```lua
local PANEL = "MultiMetersColumnsPanel"

local function columnsPanel(inst)
    for _, ctx in ipairs(inst.NS.Helpers.__panels()) do
        if ctx.panel and ctx.panel:GetName() == PANEL then return ctx end
    end
    return nil
end

local function storedColumns(inst)
    return inst.NS.Database.GetWindows()[1].columns
end

local function statKeys(inst)
    local keys = {}
    for i, c in ipairs(storedColumns(inst)) do keys[i] = c.stat end
    return keys
end

local function enabledCount(inst)
    local n = 0
    for _, c in ipairs(storedColumns(inst)) do
        if c.enabled then n = n + 1 end
    end
    return n
end

--- The blocks the open page drew, recovered off the panel's frame tree.
local function blocksOf(ctx)
    local out = {}
    local function walk(frame)
        for _, child in ipairs(frame.__children or {}) do
            if child.mmIndex then out[child.mmIndex] = child end
            walk(child)
        end
    end
    walk(ctx.panel)
    return out
end

local function openPage(inst)
    inst = inst or T.load()
    local ctx = columnsPanel(inst)
    assertTrue(ctx ~= nil, "the Columns page did not register a panel")
    ctx.panel:Hide()
    ctx.panel:Show()
    assertTrue(ctx._rendered, "the Columns page did not render; the renderer raised "
        .. "and was swallowed by pcall")
    return inst, ctx, blocksOf(ctx)
end

test("Columns: the page draws one block per statistic in the catalog", function()
    local inst, _, blocks = openPage()
    assertEqual(#blocks, #inst.NS.Constants.STATS,
        "every statistic gets a block, shown or not -- there is no add button")
end)

test("Columns: unticking a column removes it and drops it below the rule", function()
    local inst, ctx, blocks = openPage()
    local before = enabledCount(inst)
    local key = storedColumns(inst)[1].stat

    blocks[1].mmGlyph:_run("OnClick")

    assertEqual(enabledCount(inst), before - 1)
    local cols = storedColumns(inst)
    assertEqual(cols[before].stat, key,
        "the unticked block lands at the TOP of the disabled group")
    assertFalse(cols[before].enabled)
    assertTrue(ctx._rendered)
end)

test("Columns: ticking a statistic adds it as the rightmost column", function()
    local inst, _, blocks = openPage()
    local before = enabledCount(inst)
    local key = storedColumns(inst)[before + 1].stat

    blocks[before + 1].mmGlyph:_run("OnClick")

    assertEqual(enabledCount(inst), before + 1)
    local cols = storedColumns(inst)
    assertEqual(cols[before + 1].stat, key, "a newly ticked column goes to the right")
    assertTrue(cols[before + 1].enabled)
end)

test("Columns: the last shown column cannot be unticked", function()
    local inst, _, blocks = openPage()

    -- Untick everything but the first.
    while enabledCount(inst) > 1 do
        local _, _, current = openPage(inst)
        current[2].mmGlyph:_run("OnClick")
    end

    local _, _, last = openPage(inst)
    last[1].mmGlyph:_run("OnClick")
    assertEqual(enabledCount(inst), 1,
        "a window with nothing but names in it reads as a broken addon")
end)

test("Columns: dragging a block reorders the stored array", function()
    local inst, _, blocks = openPage()
    local before = statKeys(inst)

    local handle = blocks[1].mmHandle
    inst.mocks.setCursor(0, 1000)
    handle:_run("OnDragStart")
    inst.mocks.setCursor(0, 1000 - 2 * inst.NS.BLOCK_STRIDE)
    handle:_run("OnUpdate", 0.1)
    handle:_run("OnDragStop")

    local after = statKeys(inst)
    assertEqual(after[3], before[1], "the dragged block landed two rows down")
    assertEqual(after[1], before[2], "everything it passed moved up one")
    assertEqual(#after, #before, "a reorder must not add or lose a statistic")
end)

test("Columns: every change is refused in combat, with a reason", function()
    -- The library refuses to RENDER a page under lockdown, so this page cannot
    -- normally be opened mid-pull -- but a panel left open when a pull STARTS is
    -- still clickable, which is why every mutation re-checks rather than trusting
    -- the render guard.
    local inst, _, blocks = openPage()
    local before = statKeys(inst)

    inst.mocks.setRestricted(true)
    local printed = inst.mocks.__printed and #inst.mocks.__printed or 0
    blocks[1].mmGlyph:_run("OnClick")

    assertEqual(table.concat(statKeys(inst), ","), table.concat(before, ","),
        "the stored array must be untouched")
    assertTrue((inst.mocks.__printed and #inst.mocks.__printed or 0) > printed,
        "a refusal with no reason printed looks like a control wired to nothing")
end)

test("Columns: a refused write does not repaint the page", function()
    -- A refusal followed by an unconditional repaint is the worst outcome
    -- available: the page redraws from the UNCHANGED array, so the control looks
    -- like it did nothing rather than like it failed.
    local inst, ctx, blocks = openPage()
    inst.mocks.setRestricted(true)

    local renders = ctx._renderCount
    blocks[1].mmGlyph:_run("OnClick")
    assertEqual(ctx._renderCount, renders, "a refused change must not repaint")
end)
```

Read `tests/wow_mock.lua` and `tests/_kit/` first to confirm the real names for the frame child list (`__children` above is a guess), the print capture (`__printed`) and any render counter on the panel context (`_renderCount`). If a render counter does not exist, assert on the AceGUI creation count the way the current `repaint` helper does instead — do **not** add a counter to `tests/_kit/`, which is vendored.

- [ ] **Step 3: Run to verify**

```bash
lua tests/run.lua 2>&1 | grep -E "Columns:|^  FAIL|passed,"
luacheck . 2>&1 | tail -3
```

Expected: 0 failed, 0 warnings / 0 errors. Remove any `T.skip` left over from Task 1 Step 7.

- [ ] **Step 4: Commit**

```bash
git add settings/Columns.lua tests/test_columns.lua
git commit -F - <<'EOF'
Rebuild the Columns page as blocks you tick and drag

The page was a list of CHOSEN columns with a section heading, a stat
dropdown, a width slider, a show-bar checkbox and three buttons each --
eight headings and forty widgets to scroll past, to answer a question
nobody asks in that shape. It is now one block per statistic: a handle, a
tick or a cross, and a name.

A toggle is also a move, which is the whole interaction. Ticking sends a
block to the end of the enabled group, where a column you just added
belongs. Unticking sends it to the top of the disabled group -- the
shortest travel there is, so the player watches it drop just below the
rule rather than hunting for where it went.

Gone with the controls: add, remove, move-left, move-right, the per-column
headings and the Add column section. The array is the catalog now, so
there is nothing to add and nothing to remove -- only an order, and which
of them you want to see.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_019FtWnLGKT5uimw6X63zTzr
EOF
```

---

### Task 5: Strings and documentation

**Files:**
- Modify: `locales/enUS.lua:530-552` — the Columns page block
- Modify: `docs/ARCHITECTURE.md` — the deviation row and the sentence under the table
- Modify: `docs/schema.md:683-694, 931` — the `window.columns` shape
- Modify: `docs/settings-panel.md` — the Columns page's control inventory
- Modify: `docs/common-tasks.md:114` — the `DEFAULT_STAT_KEYS` row
- Modify: `docs/module-map.md` — add `settings/ColumnBlocks.lua`
- Modify: `docs/smoke-tests.md` — the six in-client checks
- Test: `tests/test_locale.lua` (it checks every `L[...]` use site has a string)

- [ ] **Step 1: Update the locale block**

In `locales/enUS.lua`, delete these keys — nothing uses them any more:

```
"Column list", "Add column", "Add a statistic as a new column on the right.",
"Remove column", "Remove this column from the window.", "Move left", "Move right",
"Column width", "Width of this column in pixels.", "Show bar",
"Draw a bar behind this column's number. Turn it off for a numbers-only column.",
"Statistic", "Which statistic this column shows.",
"Every available statistic is already shown.",
"The columns this window shows, left to right. Columns can only be changed out of combat."
```

Also delete the Schema error strings the new normalizer no longer raises:

```
"Column %d names a statistic this build does not have: %s"
"Column %d repeats the statistic %s."
"Column %d has a width outside %d-%d: %s"
"Column %d's show-bar flag is not true or false."
```

Add:

```lua
L["Every statistic this build offers. Ticked ones are the columns this window shows, left to right, top to bottom. Drag a block by its handle to reorder them. Columns can only be changed out of combat."] =
    "Every statistic this build offers. Ticked ones are the columns this window shows, left to right, top to bottom. Drag a block by its handle to reorder them. Columns can only be changed out of combat."
```

Keep `"Columns cannot be changed during combat."`, `"A window must keep at least one column."`, `"Columns must be a list of columns, not %s."`, `"Columns must be a plain ordered list with no gaps."`, `"Column %d is not a column."`, `"A single column is not a setting — edit columns on the Columns page."` and `"That column change could not be applied."` — all still reachable.

Then confirm nothing was missed:

```bash
lua tests/run.lua 2>&1 | grep -iE "locale|missing string"
grep -rn 'L\["Column width"\]\|L\["Show bar"\]\|L\["Move left"\]' core modules settings defaults
```

Expected: the second command prints nothing.

- [ ] **Step 2: Add the deviation row**

In `docs/ARCHITECTURE.md`, append to the deviations table (after the `debug-logging §8` row):

```markdown
| options-ui — generic options widgets live in `LibKa0s-Options` | The drag-to-reorder block list is `settings/ColumnBlocks.lua`, private to this addon, rather than a `LibKa0s-Options` member beside `Section`, `TextRow`, `RenderGrid` and `InlineButtonPair`. | A LibKa0s widget re-vendors into every addon in the collection, so its API is expensive to change once shipped, and one consumer is not enough evidence to freeze a signature on — the first real page it serves is what tells you which parts of the signature were guesses. It is kept in its own file rather than inside the page precisely so the promotion is a file move rather than an extraction. Tracked as [issue #21](https://github.com/tusharsaxena/MultiMeters/issues/21). | 2026-08-27 | Any addon in the collection adding a second user-orderable list. That is the second consumer the API needs; the widget moves to LibKa0s and this row retires. |
```

Then fix the count claim below the table: `**One row is ratified.**` becomes `**Two rows are ratified.**`.

- [ ] **Step 3: Update the schema doc**

In `docs/schema.md`, replace the `window.columns` example at lines 683-694 with the new shape (all eight stats, `enabled` flags, defaults ticked and first), rewrite the surrounding prose to say the array **is** the catalog, and replace the `showBar` bullet at line 931 with the current rules: every catalog stat exactly once, unknown stats dropped, missing ones appended disabled, enabled before disabled, at least one enabled.

- [ ] **Step 4: Update the remaining docs**

- `docs/settings-panel.md` — the Columns page's entry: one block per statistic, handle / glyph / label, no add, remove, move, width or show-bar controls.
- `docs/common-tasks.md:114` — `DEFAULT_STAT_KEYS` now chooses which of `STATS` ship **enabled**, rather than which appear at all.
- `docs/module-map.md` — add `settings/ColumnBlocks.lua` with its one-line responsibility and its load-order position.
- `docs/smoke-tests.md` — add the six in-client checks from the spec's Testing section verbatim.

- [ ] **Step 5: Verify and commit**

```bash
lua tests/run.lua 2>&1 | tail -3
luacheck . 2>&1 | tail -3
```

Expected: 0 failed, 0 warnings / 0 errors.

```bash
git add locales/enUS.lua docs/
git commit -F - <<'EOF'
Retire the strings and docs the old Columns page owned

Thirteen locale keys and four Schema error strings named controls and
refusals that no longer exist -- a width outside its range cannot be
raised by a page with no width, and a repeated statistic is dropped now
rather than refused. A string nothing reaches is a string a translator
spends effort on for nothing.

The deviation register gains its second ratified row: the reorderable
block list is a generic options widget living in settings/, which the
standard puts in LibKa0s-Options. The row carries the trigger that ends
it -- a second addon wanting an orderable list -- so it cannot quietly
become a permanent opt-out.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_019FtWnLGKT5uimw6X63zTzr
EOF
```

---

## After the plan

The six in-client smoke tests in `docs/smoke-tests.md` are the only remaining verification, and none of them runs offline:

1. Drag a block from the bottom of the enabled group to the top; the window's columns reorder to match.
2. Untick a middle column; it drops to just below the rule and the window loses that column.
3. Re-tick it; it lands at the bottom of the enabled group and reappears as the rightmost column.
4. Try to drag an enabled block below the rule; it stops at the rule and stays enabled.
5. Open the page, start a pull, click a glyph; the change is refused and the reason is printed.
6. Untick down to one column, then try to untick it; refused, with the reason printed.

Report these to the user as the hand-off — they need a client, and nothing in this plan can stand in for them.
