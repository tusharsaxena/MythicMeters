# Columns page: draggable per-statistic blocks

**Date:** 2026-08-26
**Status:** approved, not yet implemented
**Touches:** `settings/Columns.lua`, `settings/Schema.lua`, `core/Database.lua`, `defaults/Profile.lua`,
`modules/Window.lua`, `modules/Row.lua`, `locales/enUS.lua`, `docs/ARCHITECTURE.md`, five test files

---

## The problem

The Columns page is a list of *chosen* columns. Adding one means picking a statistic from a dropdown
in a separate "Add column" section at the bottom; removing one means finding its block and clicking
**Remove column**; reordering means clicking **Move left** or **Move right** repeatedly and watching
the whole page re-render between each click. Every column also carries a **Column width** slider and
a **Show bar** checkbox, and every column gets its own `1. Damage` section heading, so eight columns
is eight headings and roughly forty widgets to scroll past.

Two of those controls no longer control anything a player wants:

- **Column width is already dead.** `modules/Window.lua:337-341` divides the available frame width
  evenly across the visible stat columns and writes that number into every layout entry. `col.width`
  is read nowhere in the layout path. The slider has moved a stored number that nothing consults
  since the window began auto-sizing its columns.
- **Show bar is not a real choice.** The bar is what makes the grid readable at a glance. A
  numbers-only column is a worse column, and nobody is asking for one.

Underneath the widgets, the model is wrong for the question being asked. A player does not think
"which columns exist and in what order" — they think "which of these statistics do I want to see, and
in what order". The page should be the catalog, not a subset of it.

## The design

### The page

Every statistic in `Constants.STATS` gets exactly one block, always present, and the blocks stack
vertically in the order the columns are drawn left to right.

```
 ┌──────────────────────────────────────────────────────────────────────┐
 │                                                              Columns │
 ├──────────────────────────────────────────────────────────────────────┤
 │                                                                      │
 │  Every statistic this build offers. Ticked ones are the columns this  │
 │  window draws, left to right, top to bottom. Drag a block by its      │
 │  handle to reorder. Columns can only be changed out of combat.        │
 │                                                                      │
 │  ╭────────────────────────────────────────────────────────────────╮  │
 │  │  ☰       ✔                                       Damage        │  │
 │  ╰────────────────────────────────────────────────────────────────╯  │
 │  ╭────────────────────────────────────────────────────────────────╮  │
 │  │  ☰       ✔                                       Healing       │  │
 │  ╰────────────────────────────────────────────────────────────────╯  │
 │  ╭────────────────────────────────────────────────────────────────╮  │
 │  │  ☰       ✔                                       Interrupts    │  │
 │  ╰────────────────────────────────────────────────────────────────╯  │
 │  ╭────────────────────────────────────────────────────────────────╮  │
 │  │  ☰       ✔                                       Dispels       │  │
 │  ╰────────────────────────────────────────────────────────────────╯  │
 │  ╭────────────────────────────────────────────────────────────────╮  │
 │  │  ☰       ✔                             Avoidable Damage        │  │
 │  ╰────────────────────────────────────────────────────────────────╯  │
 │  ╭────────────────────────────────────────────────────────────────╮  │
 │  │  ☰       ✔                                       Deaths        │  │
 │  ╰────────────────────────────────────────────────────────────────╯  │
 │  ────────────────────────────────────────────────────────────────    │
 │  ╭────────────────────────────────────────────────────────────────╮  │
 │  │  ☰       ✘                                       Absorbs       │  │
 │  ╰────────────────────────────────────────────────────────────────╯  │
 │  ╭────────────────────────────────────────────────────────────────╮  │
 │  │  ☰       ✘                                  Damage Taken       │  │
 │  ╰────────────────────────────────────────────────────────────────╯  │
 │                                                                      │
 └──────────────────────────────────────────────────────────────────────┘
```

Block anatomy, left to right:

| Element | Asset | Behaviour |
|---|---|---|
| Drag handle | `libs/LibKa0s/media/icons/list.tga` | The **only** mouse-enabled region. Drag to reorder. |
| State glyph | `Interface\RaidFrame\ReadyCheck-Ready` / `ReadyCheck-NotReady` | Clickable. **Is** the toggle, not a label beside one. |
| Statistic name | — | Right-aligned. Full colour when enabled, greyed when not. |

The two `ReadyCheck` textures are the same pair `ConsumableMaster/settings/Category.lua:48-49` uses
for its priority list, so the two addons read as one family.

The thin rule is all that remains of a section heading: it marks where the shown columns stop.
Nothing above it is disabled, nothing below it is enabled.

Gone from the page: the `N. Damage` section headings, the whole **Add column** section, the **Column
width** slider, the **Show bar** checkbox, and the **Move left** / **Move right** / **Remove column**
button row.

### Interaction rules

- **Ticking** a disabled block moves it to the **end of the enabled group** — it becomes the
  rightmost column.
- **Unticking** moves it to the **top of the disabled group** — the shortest possible travel, so the
  player can see where it went.
- **A drag that would cross the rule is clamped to it.** You reorder within your own group; the tick
  is what moves you between groups. Without the clamp, dropping an enabled block into the disabled
  half would have to silently untick it — a state change the player did not ask for, from a gesture
  that means "move", not "turn off".
- **The last enabled column cannot be unticked.** A window with no stat columns is a list of names,
  which reads as a broken addon rather than as a configuration. This is the existing
  "a window must keep at least one column" invariant, unchanged in force and re-sited.
- **Every mutation re-checks `InCombatLockdown`,** unchanged from today and for the reason the
  current file's header already gives: the library refuses to *render* a page under lockdown, but a
  panel left open when a pull *starts* is still clickable.

### Data model

`window.columns` stops being "the chosen columns" and becomes "the catalog, in your order":

```lua
w.columns = {
    { stat = "DamageDone",          enabled = true  },
    { stat = "HealingDone",         enabled = true  },
    { stat = "Interrupts",          enabled = true  },
    { stat = "Dispels",             enabled = true  },
    { stat = "AvoidableDamageTaken", enabled = true  },
    { stat = "Deaths",              enabled = true  },
    { stat = "Absorbs",             enabled = false },
    { stat = "DamageTaken",         enabled = false },
}
```

`width` and `showBar` are removed from the stored shape. Neither has a replacement: width is computed
in `BuildLayout` from the frame width and always was, and the bar is now unconditional.

The array length is the catalog length. The enabled entries, in order, are the columns.

### Validation

`normalizeColumns` in `settings/Schema.lua` becomes a **repairing** normalizer rather than a
rejecting one. Given any candidate array it:

1. Rejects a non-table, and rejects a table that is not a gapless array (the existing `#value` vs.
   `pairs` count proof — a hole makes `#` an arbitrary answer, so the shape is proved before anything
   is read out of it).
2. Walks the input, keeping each entry whose `stat` is a **known, not-yet-seen** catalog key.
   Coerces `enabled` to a boolean. Everything else about the entry is dropped, which is what already
   makes profile aliasing impossible — the stored array never shares a sub-table with its caller.
3. Appends every catalog stat the input did not mention, `enabled = false`, in catalog order.
4. Stable-partitions enabled ahead of disabled.
5. Rejects the result if nothing is enabled.

Steps 2 and 3 together mean a stat this build does not have is **dropped** rather than listed, and a
stat this build gained is **appended disabled** rather than missing. The old code deliberately listed
an unknown stat so the player could remove it — but with no remove button and a list that *is* the
catalog, there is nothing for them to do with it and no way to do it. Self-healing is strictly better
here than surfacing.

Step 4 makes "disabled sink to the bottom" a **stored invariant** rather than something the page has
to maintain. `/mm set window.columns ...` from the CLI and a hand-edited SavedVariables both land in
the same shape the page produces.

This deletes the width range check and its `COLUMN_MIN_WIDTH` / `COLUMN_MAX_WIDTH` constants, the
NaN guard that went with them, and the show-bar type check — three error paths that can no longer be
reached because the fields no longer exist.

### Migration

`migrations[10]`, taking the DB from schema version 10 to 11:

For each window in each profile, map each stored column to `{ stat = c.stat, enabled = true }`,
discarding `width` and `showBar`, then append every catalog stat not already present as
`enabled = false`. That is precisely what the new normalizer does, so the migration calls the same
helper rather than restating the rule — a second opinion about the shape is how the two drift.

`frame.width` is left alone. `migrations[1]` already widened frames to hold the uniform grid, and the
grid's width arithmetic is unchanged by this design.

### Downstream

- **`defaults/Profile.lua`** — `DefaultWindow` keeps its `Const.DEFAULT_STAT_KEYS` walk for the
  enabled prefix, then appends every catalog stat that list did not name as `enabled = false`. The
  partition therefore falls out of the two loops for free, and `DEFAULT_STAT_KEYS` keeps the
  production consumer it would otherwise lose — deleting the constant to avoid a dead export would
  also delete the one place that says which stats ship on. Adding a stat to the catalog still puts it
  in every new window with no edit here; a stat with `defaultEnabled = false` now arrives *present
  and unticked* instead of absent.
- **`modules/Window.lua`** — `BuildLayout`'s `visible` filter tests `col.enabled` in addition to the
  existing "is this stat in the catalog" test. The `showBar = entry.col.showBar ~= false` field comes
  off the layout entry entirely.
- **`modules/Row.lua`** — `ApplyCell`'s `local showBar = col.showBar ~= false` and the
  `self.showBar` branch in the draw path go; the bar is drawn unconditionally. `Cell:ApplyBarSkin`'s
  already-unused `_showBar` parameter is removed with them. `col.width` at line 1112 is untouched —
  it reads the *layout* entry, which still carries a computed width.

### The reorder widget

Each block is an AceGUI `SimpleGroup` of fixed height added straight to `H.EnsureScroll(ctx)`.
Only the handle texture takes the mouse.

On handle mouse-down: record the start index and show a single reusable **ghost** frame parented to
`UIParent` at tooltip strata, carrying the same handle, glyph and label at reduced alpha, following
`GetCursorPosition()` scaled by `UIParent:GetEffectiveScale()`. The target index comes from cursor Y
measured against the list's top and the known fixed block height. An **insertion line** texture is
moved to the target boundary each frame.

On mouse-up: if the target index differs from the start, build the reordered array and `commit()`,
which writes through `NS.SetByPath` and repaints the whole page from the stored value. There is no
settle animation and no partial state — the page after the drop is the page rendered from what was
saved.

The gap-opens-up feedback from the original sketch is deliberately **not** built. AceGUI owns the
layout of its own children, so animating a hole means fighting the layout engine every frame for a
cue an insertion line delivers in one texture.

**On rule R3.** This reads geometry (`GetTop`, `GetHeight`) off **options-panel** frames. Those
frames never receive a meter value, so they never carry secret anchoring data, and R3 — which is
about cells that have held a secret — does not reach them. No meter cell is read. This is the same
reasoning `modules/Window.lua`'s sort-arrow placement already records for `GetStringWidth` on a
FontString the window owns.

### The write seam is unchanged

`snapshot` and `commit` survive as they are. Every mutation still builds a fresh array from the
stored one and hands the **whole array** to `NS.SetByPath("window.columns", cols)`, still checks the
seam's answer rather than discarding it, and still repaints only on success — because a refused write
followed by an unconditional repaint redraws from the unchanged stored array, and the control looks
like it did nothing rather than like it failed.

What the page loses is functions, not seams: `makeWidthSlider`, `makeShowBarCheckbox`,
`makeColumnActions`, `makeStatDropdown`, `renderAddColumn`, `unusedStatList`, `pendingStat`,
`addColumn` and `removeColumn` all go. What replaces them is `toggle(index)` and `reorder(from, to)`,
both one-liners over `snapshot` + `commit`.

## The deviation

A reorderable block list is a **generic options widget**, and by the Ka0s WoW Addon Standard generic
options widgets live in `LibKa0s-Options` beside `Section`, `TextRow`, `RenderGrid` and
`InlineButtonPair` — not in an addon's `settings/`.

It is being built in `settings/Columns.lua` anyway, deliberately. A LibKa0s widget has to be
re-vendored into every addon in the collection, so its API is expensive to change once shipped, and
one consumer is not enough evidence to freeze a signature on. Building it here lets the API settle
against a real page before it becomes everyone's problem.

Tracked as [issue #21](https://github.com/tusharsaxena/MultiMeters/issues/21) and recorded as a row
in `docs/ARCHITECTURE.md` → `## Documented deviations`, shaped:

| Rule | What differs | Why | Decided | Re-check trigger |
|---|---|---|---|---|
| options-ui — generic options widgets live in `LibKa0s-Options` | The drag-to-reorder block list lives in `settings/Columns.lua`, private to this addon. | A LibKa0s widget re-vendors into every addon in the collection, so its API is expensive to change once shipped, and one consumer is not enough evidence to freeze a signature on. Building it against a real page first lets the API settle before it becomes everyone's problem. Tracked as issue #21. | 2026-08-26 | Any addon in the collection adding a second user-orderable list. That is the second consumer the API needs, and the row retires when the widget moves to LibKa0s. |

## Testing

Green gate is `lua tests/run.lua` and `luacheck .` at 0 / 0, as always.

| File | Change |
|---|---|
| `tests/test_columns.lua` | Rewritten. Toggle moves a block between groups at the right end. Unticking the last enabled column is refused. A drag across the rule is clamped. Every mutation is refused in combat. A refused write does not repaint. |
| `tests/test_schema.lua` | `normalizeColumns` drops an unknown stat, appends a missing one disabled, partitions enabled-first, rejects a holey array, rejects an all-disabled array, and never shares a sub-table with its caller. |
| `tests/test_database.lua` | `migrations[10]`: a v10 profile with three columns carrying `width` and `showBar` becomes eight entries, those three enabled and in their original order, `width` and `showBar` gone. |
| `tests/test_window.lua` | `BuildLayout` draws only enabled columns, in stored order. Layout entries no longer carry `showBar`. |
| `tests/test_row.lua` | The bar is drawn for every cell; the show-bar expectations go. |
| `tests/test_defaults.lua` | `DefaultWindow` emits one entry per catalog stat, `defaultEnabled` ones ticked and first. The `columns[1].width` assertion at line 84 goes with the field. |
| `tests/test_windowmanager.lua` | Line 113's `#columns == #DEFAULT_STAT_KEYS` becomes `#STATS`. |

Smoke tests to add to `docs/smoke-tests.md`, since none of the above runs in a client:

1. Drag a block from the bottom of the enabled group to the top; the window's columns reorder to
   match, and the page after the drop shows the new order.
2. Untick a middle column; it drops to just below the rule and the window loses that column.
3. Re-tick it; it lands at the bottom of the enabled group and the column reappears rightmost.
4. Try to drag an enabled block below the rule; it stops at the rule and stays enabled.
5. Open the page, start a pull, click a glyph; the change is refused and the reason is printed.
6. Untick down to one column, then try to untick it; refused, with the reason printed.

## Build order

1. `settings/Schema.lua` — the new normalizer, tests first.
2. `core/Database.lua` — `migrations[10]`, calling that normalizer.
3. `defaults/Profile.lua` — `DefaultWindow`.
4. `modules/Window.lua` + `modules/Row.lua` — consume `enabled`, drop `showBar`.
5. `settings/Columns.lua` — the page and the reorder widget.
6. `locales/enUS.lua` — retire the dead strings, add the new ones.
7. Docs: `docs/ARCHITECTURE.md` (the deviation row — and the "**One row is ratified.**" sentence
   below the table becomes two), `docs/schema.md` (the `window.columns` shape at line 683),
   `docs/settings-panel.md` (the Columns page's control inventory), `docs/common-tasks.md` (the
   `DEFAULT_STAT_KEYS` row at line 114), and `docs/smoke-tests.md` (the six checks above).

Steps 1-4 keep the addon green and shippable on their own; the page in step 5 is the only step with
no fallback, which is why it is last.
