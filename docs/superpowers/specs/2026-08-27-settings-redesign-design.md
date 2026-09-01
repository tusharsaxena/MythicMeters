# Settings redesign — tabbed pages, a window banner, and a regrouped schema

**Date:** 2026-08-27
**Repos:** `WowAddonStandards` → `LibKa0s` → `MultiMeters`, in that order
**Branches:** `options-tabbed-pages` (standards, library) · `settings-redesign` (addon)

---

## The problem

The settings surface has 137 schema rows spread over nine pages, and the grouping grew by
accretion rather than by design. Three symptoms:

- **Sections are the wrong size.** General's "Debug" holds one control. Header's "Header
  controls" holds fifteen. Bars' "Cell text" holds twelve, Tooltip's "Tooltip bars" eleven.
- **Sections sit on the wrong pages.** The "Player | Damage | Healing" strip's eight styling
  rows are the third group of the Header page, three clicks from the Columns page where you
  choose the columns they label. `Show title bar` is on Frame, under "Frame behavior",
  controlling a surface the Header page owns. `Alternating background` sits inside "Bar
  background color", competing with the bar's own background.
- **A page is one long scroll.** Bars is 35 controls deep. Finding "Border thickness" means
  scrolling past five unrelated sections.

And a fourth, structural: six of the nine pages edit *the window the Windows page has
selected*, and nothing on those pages says which window that is. The tree fakes the
distinction with a typographic `  - ` indent because Blizzard offers no third level.

## What this changes

Three things, in dependency order.

1. **The standard** gains a tabbed-page pattern and a page-banner pattern, so the shapes
   below are conformant from the first commit rather than deviations to be ratified later.
2. **`LibKa0s-Options-1.0`** gains a chrome slot and three widget makers implementing them.
3. **MultiMeters** regroups all 137 rows onto those shapes.

Non-goals: the Blizzard tree keeps its nine pages in its current order and its current
indent. Profiles is untouched.

---

## 1. The standard

Two new sections in `standards/standards/options-ui.md`, and one amendment.

### §13 (new) — Tabbed pages

A page whose rows exceed what one scroll can present **MAY** render its sections as a
**tab strip** pinned above the scroll, one tab per section, instead of as a sequence of
section headings inside it. The rule set:

- **One tab per section, always.** A tab does not hold several sections and a section does
  not span several tabs. The tab label *is* the section name, so the two cannot drift, and
  the flow engine's existing `group` field remains the single declaration of both.
- **The strip wraps** rather than scrolls or truncates when the labels exceed one row. A
  page **SHOULD** hold its section count low enough for one row; a wrapped second row is
  permitted and is not a defect.
- **A tabbed page suppresses its section headings.** Drawing a `Heading` naming the tab you
  just clicked is a duplicated label, so §7's automatic heading is emitted only on untabbed
  pages.
- **Switching tabs is a structural re-render** — the same path a subject change takes — so
  it inherits the combat refusal of options-ui-§2 rather than needing its own.
- **The active tab is session state, per page.** It **MUST NOT** be persisted: a stored tab
  is UI position masquerading as a setting, and it makes a page look different to two
  characters on one account for no reason the player asked for.
- **The per-page Defaults button stays page-wide.** Its label and position do not change,
  so its blast radius **MUST NOT** narrow to the visible tab.

### §14 (new) — The page banner

A page that edits **one selected instance out of many** — a window, a profile, a unit —
**MUST** show which one, in a **banner** pinned above the strip and the scroll, carrying the
instance picker itself rather than a read-only label.

- **The banner is the only picker.** Where a page already carried a picker for the same
  state, that picker is deleted, not kept in step. One writer, one control class, and no
  propagation code — the banner re-reads the pointer at render time and the existing
  structural refresh already re-renders every panel.
- **The selection survives a tab switch and a page change.** Changing instance from a
  sub-page keeps you on the same tab: comparing one surface across two instances is the
  reason to switch from a sub-page at all.

### §7 amendment

The MUST becomes conditional: options are grouped under section headers **on an untabbed
page**; on a tabbed page the tab label carries the same name and the heading is suppressed.

### Ripple within the standards repo

`STANDARDS.md`'s options-ui blurb, the version-history entry, a version bump, and the
anti-pattern range if the "host copies the tab loop" case earns an entry.

---

## 2. `LibKa0s-Options-1.0`

### The chrome slot

`O.CreatePanel` currently anchors the body directly under the header, and `O.EnsureScroll`
pins the AceGUI `ScrollFrame` to `ctx.body`'s TOPLEFT (`Options.lua:369`). There is no slot
between them, so a banner or a strip would either scroll away with the content or overlap it.

`CreatePanel` gains **`ctx.chrome`** — a frame pinned to `ctx.body`'s top edge, zero height
until something is added to it. `EnsureScroll` anchors its TOPLEFT to `ctx.chrome`'s
BOTTOMLEFT instead.

**A page that adds no chrome is byte-identical to today**, because a zero-height frame at
the body's top edge puts the scroll exactly where it is now. That is the property that lets
the other eight Ka0s addons re-vendor this library without seeing a pixel move.

Three new `LAYOUT` keys, published on the instance because a host aligning a bespoke widget
with the strip has no other way to read them: `CHROME_GAP`, `TAB_H`, `BANNER_H`.

### `O.PageBanner(ctx, spec)`

Pinned identity bar. `spec = { label, list, order, value, onSelect, status }`.

Draws the instance name and its dropdown; `status`, if supplied, is a closure returning a
short line drawn beneath. Returns nil having drawn nothing when AceGUI is absent.

### `O.TabStrip(ctx, spec)`

Pinned, wrap-capable tab row. `spec = { tabs = { {key, label, tooltip} }, value, onSelect }`.
Grows `ctx.chrome` by however many rows it needed, so the scroll below re-anchors itself.

### `O.RenderTabbedSchema(ctx, pageKey)`

The per-page wrapper, sibling to `O.RenderSchema`. Walks `d.rowsForPage(pageKey, ctx.unit)`,
partitions by `group` **in declaration order**, builds the strip from the group names, and
renders only the active group's rows through the existing `O.RenderRows` with heading
emission suppressed.

Active tab lives on `ctx.activeTab`, defaulting to the first group. A tab click is
`O.ClearScroll(ctx)` plus a re-render of the new group — which is `O.RefreshPanel(ctx,
structural)`'s path, so the combat refusal comes for free.

**Degraded path:** with no AceGUI, `RenderTabbedSchema` falls back to plain `RenderRows` —
a flat scroll with section headings, i.e. exactly today's page. A host that loses the strip
still shows its settings rather than an empty canvas.

### Library ripple

Per-file minor bumps in `Options.lua` and `OptionsWidgets.lua`, `CHANGELOG.md` entries
matching the `<FileBasename> minor <N>` form `tests/test_versioning.lua` asserts, `docs/api/`
entries for the four new surfaces, the library's own tests, and a release tag.

---

## 3. MultiMeters

### The page plan

Tab = section throughout. Every page but Profiles is tabbed.

**General** — 3 tabs

| Tab | Controls |
|---|---|
| General | Enable Multi Meters · Show minimap button · Test mode |
| Data | Merge pets into their owner · Refresh interval |
| Maintenance | Debug console · Reset all settings · Reset position |

The one-control "Debug" group is gone; the two bespoke reset buttons get a home instead of
floating at the foot of a scroll.

**Windows** — banner, then 2 tabs

| Tab | Controls |
|---|---|
| Window | Window name · New · Duplicate · Delete |
| Copy from | Source window · Settings to copy · Copy |

The page's own "Active window" dropdown is **deleted**; the banner is the picker.

**Frame** — 6 tabs

| Tab | Controls |
|---|---|
| Size & position | Width · Height · Scale · Opacity · Frame strata · Padding |
| Rows | Maximum rows · Row height · Row spacing · Growth direction |
| Row behavior | Always show yourself · Highlight yourself · Highlight on mouseover · Alternating background |
| Background & border | Background color · Border style · Border thickness · Border color |
| Behavior | Lock window · Keep on screen |
| All surfaces | Color mode · Bar texture · Font · Font outline |

`window.rows.*` moves here from Bars: maximum rows and row height decide how tall the frame
needs to be, so they are geometry and they read next to Width and Height. It also brings
both pages to a single-row strip. `Alternating background` moves out of "Bar background
color", where it competed with the bar's own background, into Row behavior.

**Header** — 5 tabs

| Tab | Controls |
|---|---|
| Title bar | Show title bar · Header height · Alignment · Header background |
| Title text | Font · Font size · Font outline · Text shadow · Text color |
| Window buttons | Show close · Show minimise · Show lock · Show settings |
| Meter buttons | Show segment · Show segment picker · Show reset · Show export |
| Button style | Control size · Control color mode · Control color · Hover color mode · Hover color · Reveal on hover |

`Show title bar` arrives from Frame — it is this page's master switch. The 8-toggle button
bank splits along a real line: buttons that act on the **window** against buttons that act on
the **meter**. All eight `window.columnHeader.*` rows **leave** for Columns.

The four `hidden` rows are unaffected and stay undrawn: `window.frame.minimised` keeps its
`header` page so the header's own button can still write it, and General's three `export.*`
rows stay on `general` for the export modal to reach.

**Bars** — 6 tabs

| Tab | Controls |
|---|---|
| Bar | Bar texture · Bar color mode · Bar color · Bar opacity · Fill direction |
| Bar background | Mode · Color · Opacity |
| Bar border | Bar border · Border style · Border thickness · Border color |
| Text content | Left text · Right text · Number format · Death timestamps · Max name length |
| Text style | Font · Font size · Font outline · Text shadow · Text color · Text color mode · Text opacity |
| Icons | Show icon · Icon size · Icon position |

**Tooltip** — 6 tabs

| Tab | Controls |
|---|---|
| Tooltip | Anchor · Scale · Horizontal offset · Vertical offset · Hide in combat |
| Contents | Show spell breakdown · Maximum spells · Show targets · Maximum targets · Summarize on the name |
| Bar | Texture · Spacing · Color mode · Color · Opacity |
| Bar background | Mode · Color · Opacity |
| Bar border | Style · Thickness · Color |
| Text | Font · Size · Outline · Shadow · Color · Color mode |

The 11-control bar blob splits into the same Bar / Background / Border triple the Bars page
uses, so the addon's two bar-styling surfaces finally look alike.

**Visibility** — 3 tabs, grouping unchanged: Where to show (7) · When to hide (8) ·
Combat (2). The two banks stay over the size guideline deliberately — they are homogeneous
lists, and splitting them would invent a distinction that is not there.

**Columns** — 3 tabs

| Tab | Controls |
|---|---|
| Columns | the block editor |
| Header text | Font · Size · Outline · Shadow · Color · Color mode |
| Header background | Background color mode · Background color |

The strip labels the columns, so its styling belongs where the columns are chosen.

**Profiles** — untouched, untabbed.

### Content changes

Two removals and two additions, one pair:

`window.frame.controlClassColor` and `window.frame.controlHoverClassColor` are booleans
sitting beside color pickers. Every other surface in this addon expresses the same choice as
a **colorMode dropdown** (`class` / `custom`). The two bools are removed and replaced by
`window.frame.controlColorMode` and `window.frame.controlHoverColorMode`, each rendered
directly left of its swatch. `modules/HeaderControls.lua` reads the mode instead of the bool.

### Path rename

One: `window.frame.titleBar` → **`window.header.show`**. The control moves to Header, and a
path naming `frame` for a row on the Header page misleads the next reader and reads wrong in
`/mm set`. Costs a `schemaVersion` bump and a one-clause migration, which the colorMode
conversion needs anyway.

No other path moves. Storage does not have to mirror the UI tree, and `window.rows.*` and
`window.text.*` are accurate names for what they hold regardless of which page draws them.

### Behaviours

- **Defaults button** — page-wide, contract unchanged.
- **Window switch from a sub-page** — stays on the same tab.
- **Active tab** — session-only, per page, first tab on a fresh login.
- **`/mm list`** — groups as `page › tab`, so the CLI names the same place the panel does.

### Addon ripple

`settings/Schema.lua` (regroup, page moves, rename, colorMode conversion, `schemaVersion`
bump + migration) · `defaults/Profile.lua` (group order, renamed key, new keys) · the eight
page files · `modules/WindowManager.lua` `COPY_GROUPS` order · `modules/HeaderControls.lua` ·
`settings/Slash.lua` · `locales/enUS.lua` · docs (`settings-panel.md`, `schema.md`,
`ARCHITECTURE.md`, `common-tasks.md`, `README.md`) · tests (`test_schema`,
`test_schema_defaults`, `test_options_panel`, `test_defaults`, `test_headercontrols`,
`test_slash`, `test_vendor_sync`).

The one-order-five-places invariant holds: `Schema.lua` declaration order, `Profile.lua`
group order, `COPY_GROUPS`, the "Settings to copy" dropdown and the page registration order
all move together.

---

## Testing

The headless harness cannot see a pixel, so the tests assert the **declarations**, and the
in-game checks live in the smoke list.

**Automated:**

- Every schema row's `page` and `group` match this document — a table-driven expectation, so
  a row that drifts to another tab fails a named assertion rather than a count.
- No group holds fewer than two controls (Visibility's Combat is the floor at two).
- Every group name is localized through `NS.L`.
- `defaults/Profile.lua` still equals every row's `default`, with `window.header.show`
  present and `window.frame.titleBar` absent.
- The migration turns a stored `schemaVersion`-old profile into the new shape: renamed key
  carried across, the two bools converted to their modes.
- `COPY_GROUPS` order equals declaration order.
- `/mm list` output carries `page › tab` headings.
- Library: `RenderTabbedSchema` partitions by group in declaration order; a page with one
  group draws no strip; the AceGUI-absent path falls back to `RenderRows`.
- `test_vendor_sync` still matches the re-vendored payload.

**Smoke (in client):**

- Each of the six sub-pages shows the banner naming the active window; changing it there
  changes it on the Windows page and vice versa.
- Switching windows from Bars' "Bar border" tab lands on "Bar border" for the new window.
- A tab click in combat is refused with the standard message and leaves the page intact.
- Bars and Frame strips fit one row at default UI scale; Header's fits or wraps to two.
- The Defaults button on a tabbed page resets the whole page, not the visible tab.
- With a skinning addon loaded, the strip and banner are skinned (they are built lazily, on
  first `OnShow`, like the Defaults button).

## Execution order

1. Standards: §13, §14, §7 amendment, index blurb, version bump. Commit.
2. Library: chrome slot → the three makers → tests → docs → minors → tag. Commit per piece.
3. Addon: re-vendor → schema + migration → page files → modules → CLI → locale → docs →
   tests. Green gate (`lua tests/run.lua`, `luacheck .` at 0/0) before each commit.

Each step is a separate commit and the addon does not start until the library is tagged.
