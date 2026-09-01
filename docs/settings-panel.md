# Settings panel

Nine pages, registered as **canvas-layout subcategories** under one parent category so they share
the header, the breadcrumb, the scroll and the flow engine. Within a page, `settings/Schema.lua`'s
`group` field is now a **tab**: `LibKa0s-Options-1.0`'s `RenderTabbedSchema` partitions a page's rows
by `group`, in declaration order, and draws one tab per distinct group — there is no second field
naming a tab, because one tab *is* one group. A page with fewer than two visible groups falls back to
the library's older `RenderSchema` (no strip at all) rather than drawing a strip with one tab on it.

`settings/Schema.lua` currently carries **154 rows across 8 page keys** (windows, frame, header,
bars, tooltip, visibility, columns, general); a ninth registered page, Profiles, hosts no schema rows
at all — see [The pages](#the-pages) below for the per-page breakdown, read straight out of the
schema rather than carried over from any design document.

Almost none of the panel machinery is in this repo. The shell, the header, the lazy Defaults button,
the five widget makers, the tab strip, the page banner, the flow engine, the landing-page builder and
the always-shown scrollbar patch belong to `LibKa0s-Options-1.0` (`libs/LibKa0s/Options*.lua`, v1.20.0
bundled). What lives under `settings/` is only the part that is this addon's: **where a value lives,
which rows belong to which page and which tab, what the window picker does, and what a reset has to
clear that no schema row owns.**

`NS.Helpers` **is** the library instance, decorated in place by the page files with the pieces that
did not generalize (`options-ui-§1`). It is never a fresh table copying members across: a page
helper added later has to be able to call `Helpers.RenderRows` like any other page does, and a suite
that swaps a member out to spy on it must be swapping the one the library's own callers see.

Companion docs: [schema.md](schema.md) for the row shape and the window-relative path model,
[common-tasks.md](common-tasks.md) for the recipes.

---

## The pages

Registration order is the order they appear in the tree: `MultiMeters.toc` loads `General` before
`Windows`, so General is the one page that is **not** where `settings/Schema.lua` declares it —
Schema.lua's own row order runs Windows, Frame, Header, Bars, Tooltip, Visibility, Columns, General,
General last. The two orders exist for different readers: the tree is what a player clicks through,
the schema file is grouped so a row's neighbors on the page are its neighbors in the file. See
[locales/enUS.lua](../locales/enUS.lua)'s header comment for the same reconciliation on the locale
side, and do not assume the two ever have to match — they answer different questions.

Counts below are read out of `settings/Schema.lua` directly (see this task's extraction), and split
into schema rows (what `/mm list` sees, including `hidden` ones) versus rendered tabs (what a click
in the panel sees — a schema `group` with every one of its rows `hidden` is real for the CLI and
invisible in the panel, because `RenderTabbedSchema` groups only the rows `rowsForPage` hands it, and
that filter drops `hidden` rows before grouping runs).

| # | Page | Panel key | Schema rows | Tabs | Defaults | Banner | What is on it |
|---|---|---|---|---|---|---|---|
| 1 | General | `general` | 17 (14 visible + 3 `hidden`) | 2 — **General**, **Statistic colors** | yes | no | **General** — master enable, minimap button, **Merge pets** and **Refresh interval** (addon-wide since schemaVersion 5), Test mode and the debug console's visibility, plus the **Reset all settings** and **Reset position** buttons, fired through `RenderTabbedSchema`'s `afterGroup` hook keyed to General. **Statistic colors** — one swatch per entry of `Constants.STAT_COLORS`, [generated rather than written out](#the-statistic-palette), read back through `NS.StatColor`, with a note under the grid saying where those colours are actually worn (drawn through the same `afterGroup` hook, keyed to this tab). Two tabs were retired into General along the way: **Maintenance** (the console toggle and the two buttons) and **Data** (the two addon-wide data rows); neither was a subject worth a click. A third schema group, **Export**, holds the export modal's three remembered choices — all three `hidden`, so the group is real for `/mm list` and the schema-vs-defaults validator and never appears as a tab: this is the one *section that is not a tab*. General is not a window page, so it draws no banner. |
| 2 | Windows | `windows` | 1 (`window.name`) | 2 bespoke — **Window**, **Copy from** | no | yes | The picker, New / Duplicate / Delete, and Copy settings from, on the Window tab; the source picker, group filter and Copy button on Copy from. Content is bespoke rather than schema rows, so the strip is drawn directly with `H.TabStrip` rather than `RenderTabbedSchema`, which has nothing here to partition. |
| 3 | `  - `Frame | `frame` | 24 | 4 — General, Size and position, Row, Background and border | yes | yes | **General** — lock and keep-on-screen, plus the four **meta rows** (Color mode, Bar texture, Font, Font outline, each "(all surfaces)"), which broadcast one value to every surface with a setting of that kind and are read by nothing. **Size and position** — geometry, scale, opacity, strata and padding. **Row** — height, count, spacing and growth, then always-show-self, highlight-self, mouseover highlight and the alternating stripe. **Background and border** — the fill inside the window and the LSM edge around it. |
| 4 | `  - `Header | `header` | 31 (30 visible + 1 `hidden`) | 4 — Title bar, Title text, Controls, Button style | yes | yes | **Title bar** — whether it draws, its background, alignment and height, plus the **divider** under it: on/off, thickness, and a colour mode whose default (`skin`) writes nothing at all, so the shared skin still owns the line unless the player takes it. **Title text** — the six text controls for the window's own name, including a **colour mode** (class or custom, never per-statistic) that the title and the session line beside it both follow. **Controls** — every toggle for the icon strip, **in the order the strip reads left to right** and each carrying **its own icon in front of its label** (`controlLabel`): the segment line, then export, reset, segment picker, settings, lock, minimise, close — plus `window.frame.minimised` (the one `hidden` row: state the header's own minimise button writes). **Button style** — four pairs, read across rather than down: the reveal beside the size, then rest and hover side by side for mode, colour and **opacity**. The two color-mode dropdowns replaced the old `controlClassColor` / `controlHoverClassColor` booleans at schemaVersion 13; the two opacity sliders replaced a hardcoded `0.25` and `1` in `restAlpha`, and ship at those numbers so nothing moved. |
| 5 | `  - `Bars | `bars` | 27 | 6 — Bar, Background, Border, Text content, Text style, Icons | yes | yes | **Everything drawn inside a cell.** Bar texture/color mode/opacity/fill direction; the background's mode, color and opacity plus the alternating row stripe; the border; the two text slots, number format, max name length; the four text controls; and the row icon, its size and which side of the name it sits on. |
| 6 | `  - `Tooltip | `tooltip` | 29 | 6 — General, Bar, Bar background, Bar border, Text, Contents | yes | yes | **General** — anchor, scale, the two offsets and hide-in-combat. **Bar** / **Bar background** / **Bar border** — the spell line's own surfaces, configured separately from the grid's, and kept adjacent because they are read together. **Text** — its own six text controls. **Contents**, last because it is the tab you set once — spell breakdown and max spells (0 = all), targets and max targets, the two **death-line** switches (name the killer, name the killing blow), and summarize-on-name. |
| 7 | `  - `Visibility | `visibility` | 17 | 3 — Where to show this window, When to hide this window, Combat | yes | yes | **Where to show this window** — dungeon / raid / arena / battleground / delve / scenario / world, all on. **When to hide this window** — solo, vehicles, mounted, skyriding, flight paths, player housing, pet battles, while dead, all off. **Combat** — hide in combat, hide out of combat, both off. |
| 8 | `  - `Columns | `columns` | 8 (Header text 6, Header background 2) | 3 — **Columns** (bespoke block editor), Header text, Header background | yes | yes | **Columns** — one block per statistic, a drag handle, a tick/cross toggle and a name; ticked ones are the columns, in block order. This is the *page that is not tabbed by `RenderTabbedSchema`*: its Columns tab holds no schema rows at all, so the strip is drawn directly with `H.TabStrip` and each tab renders its own filtered row list. **Header text** and **Header background** are the `window.columnHeader.*` rows that used to sit on the Header page — they moved here because this is the page that labels the strip they style. |
| 9 | Profiles | `profiles` | 0 | none | no | no | AceDBOptions' create / switch / copy / reset / delete. The one page with no tab strip at all — see [Profiles — the one place AceConfigDialog is permitted](#profiles--the-one-place-aceconfigdialog-is-permitted). |

**147 schema rows total.** Five of the nine pages — Frame, Header, Bars, Tooltip, Visibility — draw
their entire body from one `H.WindowBanner(c)` plus one `H.RenderTabbedSchema(c, PAGE)` call and
nothing else. Adding an option to any of them means adding one row in `settings/Schema.lua` — with
the `group` you want it to land on — and touching no page file at all; adding an option to a *new*
tab on one of them means adding one row with a `group` no existing row uses, and nothing else either.

Four pages are not schema-driven bodies:

- **Windows** and **Columns**' block editor act on the *registry* and on an *array*, neither of which
  a flat path addresses, so both are bespoke — Columns' other two tabs are ordinary schema rows.
- **General** carries two session-only toggles drawn through `Helpers.SessionCheckbox`, which is
  wired to caller-supplied `get`/`set` instead of a settings path — so neither can accidentally
  become a stored value — plus the addon's three bespoke reset buttons.
- **Profiles** hosts an options table this addon does not own.

## The statistic palette

The General page's **Statistic colors** tab is the one **generated** block in `settings/Schema.lua`:
a loop after the literal appends one `color` row per entry of `Constants.STAT_COLORS`, in catalog
order, at `statColors.<StatKey>`. The rows are not a design decision — they are one swatch per
palette entry — and writing them by hand would be a second copy of that table that goes stale the
day a statistic is added. A stat with no palette entry gets no row rather than a black swatch.

The palette is **addon-wide**, not per-window, which makes it the third exception to "everything
display-related is per-window" alongside `data` and `export`: its whole job is telling one column
from another *at a glance*, and two windows disagreeing about what green means is the one thing that
breaks it. The tooltip's all-statistics block also lists every stat whether the hovered window has a
column for it or not, so there is no window to read a colour off in the first place.

Every surface that wears a statistic colour reads it through **one seam**, `NS.StatColor(statKey)`
in `core/Namespace.lua` — the grid's bars and cell text (`modules/Row.lua`), the column-header strip
(`modules/Window.lua`) and both tooltip paths (`modules/Tooltip.lua`). `Constants.STAT_COLORS` stays
the shipped palette and the **fallback**: it answers for a key nothing has stored, for a stat added to
the catalog after a profile was written, and for a degraded install with no database to read.

## The tab strip and the banner

**One tab is exactly one group.** `RenderTabbedSchema(ctx, pageKey)` reads `rowsForPage(pageKey,
ctx.unit)`, collects the distinct `group` values in the order their first row appears, and draws one
`H.TabStrip` tab per group — there is deliberately no second field naming a tab; the group heading
that used to sit over a scrolling section *is* the tab label now. A page with fewer than two visible
groups skips the strip and falls back to the library's plain `RenderSchema`, which is why Windows'
single schema row (the `Window` group) never grows a strip of its own — the page's two visible tabs
are drawn by its own bespoke `H.TabStrip` call instead, alongside the picker.

**The strip wraps.** `H.TabStrip` lays tabs out left to right and wraps onto a second row at the
panel's width rather than shrinking or scrolling; whether the widest pages (Bars and Tooltip, six
tabs each) wrap at default UI scale is a client check, not something this doc can assert from the
schema.

**The active tab is session-only, per page.** `ctx.activeTab` lives on the page's own render context,
not in the schema or the profile — switching a window while sat on Bars' *Border* tab keeps you
on *Border* for the new window, and reloading or closing the panel forgets which tab you were on.
A tab pointing at a group the current page no longer has (a stale `activeTab` surviving a schema
change) heals to the first group rather than rendering a blank page under the strip.

**Clicking a tab is not combat-guarded, and that is deliberate (`options-ui-§13`).** The library's
combat refusal lives in the panel's `OnShow` and covers *opening or switching a settings category* —
the action Blizzard's own lockdown protects. Redrawing widgets inside a category that is already open
is not a protected action, so a tab click never checks `InCombatLockdown()` and is never refused —
see [Combat lockdown: the panel refuses, it never defers](#combat-lockdown-the-panel-refuses-it-never-defers)
for the guard that *does* apply, which is about reaching the panel at all, not about what you click
once you are in it.

**The banner is the only window picker left on a window sub-page.** Frame, Header, Bars, Tooltip,
Visibility, Columns and Windows itself each open with `H.WindowBanner(ctx)` before their tab strip —
a dropdown naming the window the rest of the page edits, backed by `H.PageBanner` (`options-ui-§14`).
Moving it on any one of those seven pages moves it on all seven, because they all read the same
`NS.State.activeWindowId` the banner writes. The Windows page's own "Active window" dropdown, which
used to be the *only* picker, was **deleted** in this redesign — the banner does the job now, on every
page a window setting can appear on, not just the one that used to own it. General and Profiles are
not window pages and draw no banner.

### The indent, and why the tree needs one

Blizzard's Settings tree draws every canvas subcategory of one addon at the **same depth**, and these
pages are not one flat set. Seven of them edit *the window the banner is pointed at*; General and
Profiles edit the addon. Nine pages that silently retarget when a picker on a different page moves,
presented as peers of the two that never do, is the tree lying about what a click will change.

**The banner is now half of what the indent was faking on its own.** Before this redesign the indent
was the *only* signal that a page's content depended on something set elsewhere — a typographic hint
standing in for the fact the page never said out loud. The banner says it directly, in the page's own
body, in a place a player is already looking: which window this page edits. What the banner does not
and cannot fix is the **tree** itself — Blizzard's Settings sidebar still draws Frame, Header, Bars,
Tooltip, Visibility, Columns and Windows as peers of General and Profiles, at the same depth, with no
API for a third level. That structural fact is still real, which is why the indent stays: it is no
longer the only place the dependency is visible, but it is still the only place the **tree** says so.

There is no API for a third level, so the mark is **typography**: two spaces, a hyphen and a space,
prefixed by `NS.SubPageLabel` (`settings/OptionsSetup.lua`) to the **tree label only**. The canvas
heading and the breadcrumb keep the plain name — a page heading that starts indented reads as a
layout bug. It is not a locale string: it is furniture, and a translator handed two spaces and a
hyphen has nothing to translate and one more chance to drop a space.

**The indent does the nesting; the hyphen marks the item.** Two earlier spellings got one of those
and not the other, and both are recorded because each failed in its own way:

| Tried | Why it went |
|---|---|
| `U+21B3` (↳) | Exactly the right character; Friz Quadrata does not have it. The client drew a **hollow box** in front of all six indented pages, and the settings tree offers no way to hand the player a font that does have it. |
| `\|- ` | Draws on any font, and reads as a bulleted **list** rather than as nesting: with nothing indenting it, the mark sat where the page name should start and competed with it for the eye. |
| `    ` (four spaces) | Nests correctly and marks nothing — confirmed in the client, which is what made the hyphen safe to add on top. |
| `  - ` | Both jobs, each done by the part that is good at it. |

**Leading whitespace is the kind of thing a UI toolkit trims**, and this one was checked in-client
rather than assumed. That check is also why the hyphen is decoration rather than load-bearing: if a
future client does start trimming, the six pages keep a visible `- ` and degrade to a flat bulleted
list rather than to nothing at all.

### Where a setting is edited is not where it is stored

Two groups make the point, and both are deliberate:

- **Header controls** are edited on **Header** and stored at `window.frame.*`. Every one of them
  draws a control into the title bar, which is what a player looks for under Header — but renaming
  the keys to `window.header.*` for symmetry would migrate every saved profile in exchange for a
  tidiness nobody can see.
- **Reset position** sits on **General**'s **General** tab and acts on the **selected window**.
  It is the one control on that page that is not addon-wide, which is why its tooltip names the
  window rather than saying "the window".

### What is no longer here

- **The Data page is gone.** Session, sort mode, sort column and sort ascending were all reachable
  from the window itself long before they were rows: the header's segment picker writes
  `sessionType`, and one click on a column header writes all three sort fields
  (`modules/Window.lua`'s `SortByColumn`). They were **deleted**, not hidden, so `/mm set
  window.data.sortColumn` is gone too — the click path writes those fields directly rather than
  through `NS.SetByPath`, so a CLI that could also write them was a second seam onto state the
  window owns. Merge pets and Refresh interval moved to General and became addon-wide; the page's
  **Reset meter data** button was **deleted rather than moved**: a reset that wipes the sessions
  Blizzard's own meter is reading does not belong one click from the addon's front door, beside two
  resets that touch only this addon. Its dialog lives on in `settings/General.lua` because the
  header's own reset control still opens it — which is the deliberate way to reach it, on the window
  whose numbers you are looking at.

### The two pages with no Defaults button, and why each

Columns is **not** one of these any more: the array became the whole catalog (every statistic ships
on the page; only which are ticked, and in what order, can differ from the shipped list), which gives
"restore this page's defaults" something exact to mean, so the page now carries its own Defaults
button (`ctx.panel.defaultsOnClick = restoreShippedColumns`) that ticks and orders the block editor
back to the shipped list — a bespoke handler rather than `H.RestoreDefaults`, because that helper
walks a page's *schema rows* and the block editor is not one, though the page's other two tabs
(Header text, Header background) are ordinary schema rows and would be covered by the sweep either
way.

- **Windows** — nothing on it is a schema row except the name. "Restore this page's defaults" would
  have to mean deleting the registry back to one seed window, which is not what a player clicking
  Defaults expects.
- **Profiles** — restoring here would delete the player's profiles, which is not what anyone means
  by restoring a default (`options-ui-§3`). This is enforced **twice**: the button is suppressed on
  the page, and `settings/OptionsSetup.lua`'s `skipRestoreAll` predicate
  (`row.page == "profiles"` **or** `row.path == "window.name"`) vetoes those rows from `/mm resetall`, the General page's
  "Reset all settings" popup and the header Defaults sweep alike. Two enforcements of one rule,
  because the destructive controls this page hosts are the library's rather than ours — and because
  the degradation stub in `settings/OptionsSetup.lua` runs its own reset loop with **the same
  named predicate**, so a profiles row is safe on both paths rather than on the one somebody
  remembered.

---

## Eager category, lazy body, lazy Defaults button

The three happen at three different moments, and they are three because they answer two different
problems.

```
addon load        →  NS.RegisterOptionsPage(key, name, Build)     -- queued
OnInitialize      →  NS.CreateOptionsPanel()                      -- categories registered
first OnShow      →  the page's renderer runs                     -- widgets built
first OnShow      →  H.EnsureDefaultsButton(panel)                -- button built
```

### Why the category is eager

The parent category and all nine subcategories are registered during `OnInitialize`, before
anything is drawn. That is what makes the addon appear in the Blizzard AddOns list, what makes
`/mm config` have somewhere to go, and what makes the Settings window's own search find the pages.
A category registered lazily is a category the player cannot find until they have already found it.

### Why the body is lazy — reason one: zero width

A builder that ran at registration time would lay its children out against a `ctx.body` that still
has **zero width**, because the canvas has never been shown. AceGUI measures relative widths against
the parent it is given, so every `SetRelativeWidth(0.5)` on the page would resolve to half of
nothing.

### Why the body is lazy — reason two: the skinning race

UI-skinning addons restyle AceGUI widgets by hooking `AceGUI:RegisterAsWidget`. A widget built during
load, when this addon happens to load before the skinner, keeps Blizzard's stock art forever —
visibly different from every other AceGUI widget on the player's screen, and only in game
(`options-ui-§5`, anti-pattern #42).

`H.SetRenderer(ctx, fn)` hands both problems to the library, which owns **when** a page draws: on
first show, and again after a refresh marked it dirty while it was hidden. Every page file in this
addon uses it. Exactly one does not — see Profiles below.

### Why the Defaults button is lazy for reason two only

The Defaults button is an AceGUI `Button`, so it is subject to the skinning race like any other
widget, but it is not laid out against the body and does not care about width. It is therefore built
on the panel's first `OnShow` by `Helpers.EnsureDefaultsButton(panel)`.

Builders **park** the handler rather than wiring it:

```lua
ctx.panel.defaultsOnClick = function() H.RestoreDefaults(PAGE, ctx) end
```

A plain function, parked on the frame — `EnsureDefaultsButton` wires it with
`:SetCallback("OnClick", …)` and **not** `:SetScript`, because the AceGUI widget object is not a
Blizzard Frame. Parking rather than wiring is also what lets the Settings window's own **footer**
Defaults control work: `CreatePanel` stamps an `OnDefault` forwarder on the canvas that reads
`panel.defaultsOnClick` at click time, not at `CreatePanel` time — the only ordering that works when
every builder parks its handler after `CreatePanel` has returned.

---

## Combat lockdown: the panel refuses, it never defers

`NS.OpenOptionsPanel` forwards to `Helpers.OpenOptionsPanel`, and the library **refuses** under
combat lockdown. It does not queue the request and replay it when the pull ends.

This is the standard's one documented exception to "gate and defer" (`options-ui-§1`). A panel that
opened three seconds after the fight finished — because the player asked for it mid-pull and the
addon helpfully queued it — is a window nobody asked for at a moment nobody wanted it, and in this
addon it would land on top of the meter the player was reading. The refusal prints one gray notice
line and stops.

Three places re-state the guard, and each is a real hole rather than caution:

1. **`settings/Profiles.lua`'s `OnShow`.** That page does not use `SetRenderer` (below), so it gets
   none of the library's refusal. The Blizzard AddOns sidebar reaches a canvas **without** going
   through `NS.OpenOptionsPanel`, so a page with no guard of its own is reachable mid-pull. Its
   handler closes the Settings window and prints — a silently blank page reads as a bug.
2. **`settings/Columns.lua`'s `commit()`.** The library already refuses to *render* a page under
   lockdown, so the Columns page cannot normally be *opened* mid-pull — but a panel left open when a
   pull **starts** is still clickable. Every column mutation therefore re-checks
   `InCombatLockdown()` and prints "Columns cannot be changed during combat." rather than rebuilding
   a frame whose cells are holding secret values.
3. **`modules/Tooltip.lua`'s `hideInCombat`**, which is a preference rather than a guard, and uses
   `UnitAffectingCombat("player")` rather than `InCombatLockdown()` because the two differ at both
   ends of a pull and the setting is a statement about the player.

Nothing else in this addon has a combat gate, and `modules/DrillDown.lua` deliberately has none:
those are unprotected frames, and the moment a raider most wants to know what killed them is the
moment they are still fighting.

---

## The window picker

`settings/Windows.lua` is the **only writer** of `NS.State.activeWindowId`, and that single integer
is what every other page resolves against. The picker itself is `H.WindowBanner`, decorated onto the
library instance by `settings/Windows.lua` and drawn by all **seven** window pages (Frame, Header,
Bars, Tooltip, Visibility, Columns and Windows itself) at the top of their body, before the tab
strip — it replaced a dropdown that used to sit on the Windows page alone. The Windows page's own
"Window" tab keeps the name box and the registry buttons; the "Active window" dropdown is the banner
now, same on every page it appears on, and there is no second picker anywhere in the panel.

```
picker OnValueChanged
    → NS.State.SetActiveWindow(id)
    → NS.RefreshOptionsPanel()          -- STRUCTURAL, every panel
```

Every `window.`-prefixed schema row resolves through `NS.GetSetting` / `NS.SetByPath` against that
id (see [schema.md](schema.md#the-window-relative-path-model)). Move the picker and seven pages
retarget together, along with `/mm set window.frame.width 300` typed in chat. **No path is
rewritten, and no page filters rows per window** — the panel moves the window the rows resolve
against.

### Structural refresh, not scalar

This is the one place the distinction matters, and getting it wrong is invisible in the worst way.

| | What changed | Refresh |
|---|---|---|
| A slider moved, `/mm set` ran | a **value** | `Helpers.RefreshScalars()` — re-read widget values in place |
| The picker moved, a window was created / deleted / renamed / duplicated, columns were edited | the **subject**, or which rows exist | `NS.RefreshOptionsPanel()` → `Helpers.RefreshAllPanels()` — rebuild |

A scalar refresh after a picker move would leave every widget on seven pages showing the previous
window's numbers under the new window's name. A structural refresh after a slider move would rebuild
the page under the cursor mid-drag.

Each page's renderer also stamps `c.unit = NS.State.activeWindowId`. That is the library's `ctx.unit`
row filter, passed through to `NS.SchemaForPage(pageKey, filter)` — which accepts it and
deliberately ignores it. The parameter exists so the descriptor's signature is honest and so a later
per-window row exclusion has somewhere to go; today the retargeting is entirely the active-window
pointer's job.

### A stale pointer heals itself

`activeWindowId` can outlive the window it names: deleted from this page, deleted by
`/mm window delete`, or dropped by a profile switch that brought a different registry. Every reader
falls back to the first window in the registry rather than resolving against nothing —
`settings/Schema.lua`'s `activeWindow()`, `settings/Windows.lua`'s and `settings/Columns.lua`'s.
`M:Delete` **clears** the pointer rather than reassigning it, so there is one rule for where the
selection lands instead of two.

### The registry actions route through WindowManager

New, Duplicate, Rename, Delete and Copy all call `modules/WindowManager.lua`. Creating a window is
not a table insert: it has to mint a non-reused id, deep-copy the template so two windows never
share a sub-table, build the frame, and announce `WINDOWS_CHANGED`. All of that is the module's, and
it is also what `/mm window new` calls — one implementation, so the panel and the CLI cannot drift
into disagreeing about what "new window" means.

Details that are the page's rather than the module's:

- **The picker is keyed by id, labelled by name.** Nothing stops two windows being called "Raid";
  ids are minted monotonically and never reused, so they are the only thing here that is actually a
  key.
- **Rename fires on `OnEnterPressed` only**, never `OnTextChanged` — renaming fires
  `WINDOWS_CHANGED` and rebuilds the picker, and doing that per keystroke would pull focus out of
  the box the player is typing in.
- **Delete confirms** through a `StaticPopup`, because it discards every setting on seven pages and
  cannot be undone. The last window is not deletable, refused in both the page and the module: an
  empty registry would leave every window-relative path unresolvable and the panel would render
  pages of dead widgets.
- **The active window is removed from its own "Copy settings from" list.** Copying a window onto
  itself is a no-op that looks like a bug when nothing changes.
- **Copy is filterable to one group** — "Everything" or one of the ten config groups. Copying one
  window's columns onto another while leaving its position and visibility rules alone is the actual
  request behind "copy settings from". The target's `id`, `name` and `frame.position` are never
  copied; a copy that landed exactly on top of its source reads as "the copy did nothing".

`H.ActionDropdown` and `H.Relayout` are decorated onto the library instance by this page because
`settings/Columns.lua` needs both. The library's own dropdown maker reads and writes a stored path,
which is right for a setting and wrong for everything on these two pages: the picker writes
**session state**, and the column editor writes one element of an array through a carve-out. Neither
has a scalar path to name.

---

## Column editing is settings-panel-only, and out of combat only

Every other meter lets you drag a column edge in the window itself. This one deliberately does not,
and the reason is not effort — **the drag editor is unimplementable against this data source.**

Resizing a column by dragging means reading the cell's current geometry back: `GetWidth`, `GetLeft`,
`GetPoint`. A cell that has been handed a secret meter value through `StatusBar:SetValue` is marked
`HasSecretValues`, and **from that moment its own position and size data are secret too**, and that
propagates to everything anchored to it. So the read that a drag editor is built out of is exactly
the read this addon may never perform on a live cell.

Confining column management to the settings panel removes the hazard rather than guarding against
it. Layout is computed from config on the way **out** (`WindowProto:BuildLayout`, which consults not
one widget) and never read back on the way **in** — design rule R3. There is no code path where a
cell's geometry is a question anyone asks. The one place the addon *does* call `GetPoint` is
`modules/Window.lua`'s `inst.anchor`: an empty, invisible, childless frame that the visible window is
anchored **to**, upstream of everything, and which can therefore never receive a value.

The out-of-combat rule is the same constraint at the other end. Adding or removing a column rebuilds
the window's cells, and doing that while those cells are holding secret values is the operation the
whole design is arranged to avoid. `commit()` refuses under `InCombatLockdown()` and says so.

### How the editor works

The page is **one block per statistic in the catalog**, always all of them, in the order the window
draws them left to right. A block is a drag handle, a state glyph (`ReadyCheck-Ready` /
`ReadyCheck-NotReady`, the same pair ConsumableMaster's priority list wears) and a right-aligned
name. A thin rule sits under the last ticked block, marking where the shown columns stop.

There is no add, no remove, no move-left, no move-right, no width slider and no show-bar checkbox.
The array *is* the catalog, so there is nothing to add and nothing to remove — only an order, and
which of them you want to see.

Five details worth knowing:

- **Every mutation snapshots, edits, and hands the whole array to `NS.SetByPath("window.columns", …)`.**
  Mutating the live table in place and then "writing" it would hand the seam a table it already
  holds, and any change detection would correctly conclude that nothing happened.
- **The seam's answer is checked, not discarded.** It can legitimately say no — no window selected,
  or an edit that would leave nothing ticked. A refusal followed by an unconditional repaint is the
  worst outcome: the page redraws from the unchanged stored array, so the control looks like it did
  nothing rather than like it failed. Repainting is conditional on success and the reason is printed.
- **A toggle is also a move.** Ticking sends a block to the end of the ticked group — it becomes the
  rightmost column, which is where a column you just added belongs. Unticking sends it to the top of
  the unticked group, the shortest travel available, so the player watches it drop just below the
  rule rather than hunting the list for where it went.
- **A drag that would cross the rule is clamped to it.** You reorder within your own group and the
  tick is what moves you between them. Without the clamp, dropping a ticked block into the unticked
  half would have to silently untick it — a state change from a gesture that means "move".
- **The drop target is index arithmetic, not a hit test.** Every block is `NS.BLOCK_STRIDE` tall, so
  where the cursor landed is a division. Nothing asks which block is under the pointer, so nothing
  depends on the blocks having been laid out yet, on the scroll position, or on AceGUI having
  finished its layout pass — all three of which are true at different moments during a drag.

The **gesture** — the handle, the copy carried under the cursor, the insertion line, the index
arithmetic and the clamp — is `LibKa0s-Widgets-1.0`'s `ReorderList`, shared with ConsumableMaster's
priority list since Widgets minor 8. **`settings/ColumnBlocks.lua`** keeps the row: the glyph, the
label, the dimming and the rule. The library owns no row content at all, deliberately — the two
adopting lists draw nothing alike, and a callback wide enough for both would be a hole shaped like
two addons.

---

## The bespoke controls

Four things on two pages are commands rather than settings — they have no stored value to get, set
or restore, so none of them can be a schema row.

| Control | Page | Tab | What it does |
|---|---|---|---|
| **Reset position** | General | General | `WindowManager:ResetPosition(activeWindowId)` — the active window only. Positions are not rows (four values, one concept, and never read back off a live frame), so `NS.ApplyDefault` cannot reach them. |
| **Reset meter data** | *the window header, not a page* | — | Confirms, then `NS.Provider.Reset()`. Irreversible and reaches **outside** this addon: `C_DamageMeter.ResetAllCombatSessions` wipes the data Blizzard's own meter is showing too. Routed through the provider and never straight at the Compat shim — the provider is the only permitted caller of the meter shims, and it also forgets the memoized availability answer and announces `METER_RESET`. |
| **Reset all settings** | General | General | Confirms, then `Helpers.RestoreAllDefaults()` — the same implementation the header Defaults button and `/mm resetall` use, so the three cannot drift. `afterRestoreAll` hands the profile to `db:ResetProfile()`, which makes this the **equivalent of a new profile**: every setting back to shipped, extra windows **deleted**, names reset, one fresh window left. Other profiles untouched. See *Reset all settings vs Reset Profile* below. |
| **Test mode** | General | General | `Helpers.SessionCheckbox` over `NS.State.testMode`. Fills every window with placeholder rows so columns can be laid out without being in combat. Session-only: persisting it would mean logging in to a screen full of fake numbers. Also reachable as `/mm test`. **Not** implied by unlocking a window any more — `WindowManager:SetLocked` used to also switch it on, which made `/mm lock off` silently turn placeholder data on and made unchecking Test mode a no-op while any window was unlocked; locking is now about movement and nothing else, and a player who wants a grid to aim at asks for one with `/mm test`. |
| **Debug console** | General | General | The console **window's** visibility, not the logging flag. Logging runs with the console closed so a bug can be reproduced first and the log read afterwards; the flag itself is `/mm debug on\|off`'s and is never written to SavedVariables (`debug-logging-§5`). The spec comes from `LibKa0s-DebugLog-1.0` itself (`D:ConsoleCheckbox()`) rather than being hand-written, so its label, tooltip and show/hide are the library's. |

Both General toggles are also `sessionOnly` schema rows (`state.testMode`, `state.debugConsole`) so
that `/mm list` and `/mm get` can reach them — a toggle that exists only in the panel is a toggle the
CLI cannot reach. The rows carry their own `get`/`set`; the checkboxes are drawn bespoke because
`SessionCheckbox` is wired to functions rather than to a path.

---

## Profiles — the one place AceConfigDialog is permitted

Every other page is drawn by `LibKa0s-Options-1.0` from `NS.Schema`, and AceConfig is not in the
picture at all. This page is the documented exception for one reason: **the options table is not
ours.** AceDBOptions generates it — every scope dropdown, every confirmation, every profile-list
refresh — and re-expressing that as schema rows would mean maintaining a copy of AceDB's own profile
model that goes stale the first time AceDB adds a scope.

The exception is scoped to **content**. The canvas, the header, the breadcrumb and the registration
are still `Helpers.CreatePanel`, so this page looks like the other eight rather than like a bolted-on
Ace window. An AceGUI `SimpleGroup` is parented to `ctx.body` and `AceConfigDialog:Open` targets it,
which lands the widgets inside this canvas instead of opening a second floating window over the
settings panel.

**It does not use `SetRenderer`,** and that is deliberate. `SetRenderer`'s contract is "draw once,
and again when the library says you are dirty", which is right for a page whose widgets the library
owns. Here the widget tree belongs to AceConfigDialog, which reuses it and re-reads the current
profile on every `Open`. So the page re-`Open`s on every show — cheap, and the only way the profile
list reflects a switch made from the slash command or from another addon's copy of the same AceDB.
The cost is the combat refusal `SetRenderer` would have given, which is why the guard is spelled out
in the page's own `OnShow`.

---

## Refresh routing

```
NS.SetByPath(path, value)
    ├─ row.onChange(value, windowId)          -- only where CONFIG_CHANGED cannot express it
    ├─ NS.Debug("Set", …)                     -- logged ONCE, here
    ├─ SendMessage(CONFIG_CHANGED,            -- the ONE sender
    │       { section = row.page, windowId })
    │       └─ every window instance re-applies IF the id matches (or is nil)
    └─ Helpers.RefreshScalars()               -- in-place widget re-read
```

Downstream reactors must not re-echo the value: a settings change that appears three times in the
debug log is three changes as far as a reader can tell. And each window subscribes on its **own**
private bus target from `NS.NewBusTarget()` — CallbackHandler keys callbacks by
`(message, target)`, so several windows registering the same message on the shared addon object
would silently clobber each other and only the last one would ever refresh (anti-pattern #32).

`NS.RefreshOptionsPanel` (→ `Helpers.RefreshAllPanels`) is called from three places and three only:
the AceDB profile callbacks, the Windows page's registry actions and picker, and the Columns page
after a successful commit.

---

## The degradation stub is load-completing, not member-answering

Every other setup file in this addon degrades to a table whose members each print an honest "not
installed" line. `settings/OptionsSetup.lua` **must not**, and the reason is not importance but
**when** the missing code is reached (`options-ui-§1`, the documented exception).

The page files evaluate `Helpers` members **inside schema-row literals, at file load** —
`lsmValues("font")` on every font row, `H.ActionDropdown` referenced by the Windows and Columns
pages. With those members nil the page file **raises**, so its registration never runs, so a third
of `NS.Schema` is simply missing — and `/mm list`, `/mm get`, `/mm set`, `/mm reset` and the profile
defaults break with it, silently. The addon would not degrade; it would half-load and say nothing.

So the stub's job is to let every page file **finish loading**:

- members reached at load return something a row can hold (`Helpers.LSMValues` keeps its deferred
  shape and answers a single `{ None = "None" }` placeholder, because the library never answers
  empty either — a dropdown with no options cannot be opened, and the CLI would then refuse even the
  value already stored);
- members reached from a builder or a user action are no-ops, because by then there is no panel to
  draw into and a no-op is honest;
- `Helpers.RestoreAllDefaults` stays **real**, using the same `vetoedFromResetAll` predicate the
  live descriptor uses. The user whose panel will not open is exactly the user who needs "reset
  everything", and the schema loaded fine.

What is deliberately **not** in the stub: no widget maker, no flow engine, no header, and none of
the library's layout constants. A host copy of a library constant is the copy that goes stale, and
hand-copying the code whose drift the extraction exists to end is the one duplicate `testing-§8`
most specifically forbids.

---

## Panel and CLI are one event

`settings/OptionsSetup.lua`'s descriptor and `settings/Slash.lua`'s descriptor point at **the same
three seams**:

```lua
get          = function(path) return NS.GetSetting(path) end,
set          = function(path, v) NS.SetByPath(path, v) end,
applyDefault = function(row) NS.ApplyDefault(row) end,
```

So a panel click and a `/mm set` are one event: same validation, same debug line at the write seam,
same `onChange`, same refresh. The window-relative resolution lives **behind** the seam rather than
in either descriptor, which is exactly why the CLI can be as thin as it is —
`/mm set window.frame.width 300` is one path lookup from the library's point of view, and the
active-window question is the schema's to answer.

`row.page` is the shared grouping key: it feeds the panel's `rowsForPage` and the CLI's `groupKey`,
so `/mm list`'s sections and the panel's pages cannot disagree about which page a row belongs to.

The landing page's command list is **generated** from `NS.COMMANDS` through `Sl:LandingRows()` — the
same formatter `/mm help` prints through, minus the chat indent. Never a second hand-written list,
which is how a panel and a help block drift into disagreeing about what the addon can do. It is
passed as a **function** rather than an array because the library calls it at render time, so a
re-render picks up a verb registered since the descriptor was declared.

Two descriptor callbacks were nil once and failed silently, which is why both are resolved off `NS`
rather than off `helpers()`, at call time:

- `rowsForPage` → `NS.SchemaForPage`. Reaching for it on the library instance found nothing and fell
  through to an inline loop forever — a silent second grouping rule that could not follow the
  schema's. The inline loop survives as the last resort for a half-loaded install, using the same
  predicate.
- `validate` → `NS.ValidateSchema`. Read off `helpers()` it was nil, so the path-resolution and
  default-agreement checks never ran in game and the one bug they exist to catch could only ever
  surface in the headless suite.

## Reset all settings vs Reset Profile

They are now the **same act**, deliberately: **General → Reset all settings** hands the profile to
AceDB and is the equivalent of starting a brand-new profile.

```lua
resetProfile = function()
    local db = NS.db
    if db and db.ResetProfile then db:ResetProfile() end
end,
```

`resetProfile` is `LibKa0s-Options-1.0` **minor 9**'s descriptor field, added so this policy stops
being restated once per addon — nine repos were writing the same hand-rolled `afterRestoreAll`. With
it supplied the library narrows its own row walk to the `sessionOnly` rows *before* consulting
`skipRestoreAll`, so the veto below is belt to that braces on the live path and the whole policy on
the degraded one, where there is no library to do the narrowing.

`db:ResetProfile()` empties the **active** profile — and only that one; the profile *list* is
untouched, which is the line the Profiles veto has always been about — the defaults merge back, and
`OnProfileReset` lands on `core/Database.lua`'s `OnProfileChanged`, which runs the migrations,
re-seeds a single default window through `SeedWindows` and publishes `PROFILE_CHANGED`. Every window,
the open panel and the aggregator's caches rebuild off that one message, exactly as they do for a
profile switch (`architecture-§4`).

So it is **destructive in a way the old sweep was not**: your extra windows are **deleted**, not
restyled, and window names go back to the shipped one. The popup says so out loud, because "reset
settings" does not sound like "delete my three windows" and an OnAccept that does something the text
did not warn about is how a player loses a layout they spent an evening on.

**The row walk is vetoed down to the session rows.** `skipRestoreAll` refuses the Profiles page as it
always did, and now also refuses everything else that lives in the profile: writing each row's
default first would announce `CONFIG_CHANGED` once per row for values about to be discarded whole,
and would still leave the extra windows behind. What is left for the walk is exactly what a profile
reset **cannot** reach — the `sessionOnly` rows (`state.testMode`, `state.debugConsole`), whose
storage is their own `set()` rather than the db.

Window positions come back with the rest of the profile, so `afterRestoreAll` no longer calls
`ResetPositions`. The **Reset position** button — on General since it moved off Frame — is
unaffected and still moves the active window alone.

**What was wrong before.** Every `window.` path resolves against ONE window — whichever
`NS.State.activeWindowId` names — which is exactly right for a panel click and for `/mm set`. The
library's reset sweep walks the schema **once**, so "Reset all settings" reset the window you happened
to have selected and left every other one untouched, while `afterRestoreAll`'s `ResetPositions`
re-centred **all** of them: one action with two different scopes, and nothing on the button to say
which you would get. Column arrays were missed entirely, because `window.columns` is a
`NS.SetByPath` carve-out rather than a schema row and no `ApplyDefault` can address it.

