# Settings panel

Thirteen pages, registered as **canvas-layout subcategories** under one parent category so they
share the header, the breadcrumb, the scroll and the two-column flow engine.

Almost none of that is in this repo. The shell, the header, the lazy Defaults button, the five
widget makers, the flow engine, the landing-page builder and the always-shown scrollbar patch belong
to `LibKa0s-Options-1.0` (`libs/LibKa0s/Options*.lua`). What lives under `settings/` is only the
part that is this addon's: **where a value lives, which rows belong to which page, what the window
picker does, and what a reset has to clear that no schema row owns.**

`NS.Helpers` **is** the library instance, decorated in place by the page files with the pieces that
did not generalize (`options-ui-§1`). It is never a fresh table copying members across: a page
helper added later has to be able to call `Helpers.RenderRows` like any other page does, and a suite
that swaps a member out to spy on it must be swapping the one the library's own callers see.

Companion docs: [schema.md](schema.md) for the row shape and the window-relative path model,
[common-tasks.md](common-tasks.md) for the recipes.

---

## The pages

Registration order is the order they appear, and it matches `settings/Schema.lua`'s declaration
order, `defaults/Profile.lua`'s group order, `modules/WindowManager.lua`'s `COPY_GROUPS`, and the
"Settings to copy" dropdown. One order, five places, deliberately.

| # | Page | Panel key | Rows | Defaults button | What is on it |
|---|---|---|---|---|---|
| 1 | Windows | `windows` | 1 (`window.name`) | **no** | The picker, New / Duplicate / Delete, and Copy settings from |
| 2 | Frame | `frame` | 15 | yes | Geometry, backdrop, LSM border, lock, title bar / close / grip · **Reset position** button |
| 3 | Header | `header` | 16 | yes | Title text, session name / duration / totals, font, alignment, strip height and background — plus **Column headers**, which own the "Player \| Damage \| Healing" strip's own font, size, outline, colour and background |
| 4 | Rows | `rows` | 8 | yes | Max rows, height, spacing, growth direction, self-pin, highlights, alternating background |
| 5 | Bars | `bars` | 8 | yes | Texture, color mode, custom color, opacity, fill direction, background color and opacity, outline |
| 6 | Text | `text` | 9 | yes | Left slot, right slot, number format, font, size, outline, shadow, color, opacity |
| 7 | Icons | `icons` | 3 | yes | One icon per row — spec where known, class otherwise, never a role — plus its size and which side of the name it sits on |
| 8 | Tooltip | `tooltip` | 18 | yes | Anchor and x/y offset, spell breakdown, max spells (0 = all), summarize-on-name, hide in combat, its own bar texture/spacing/border, its own font/size/outline, and the Targets section |
| 9 | Visibility | `visibility` | 7 | yes | Dungeon / raid / arena / battleground / world, hide when solo, hide in vehicle |
| 10 | Columns | `columns` | **0** | **no** | The ordered column list — add, remove, reorder, width, show-bar |
| 11 | Data | `data` | 4 | yes | Session, sort mode, sort column, refresh interval · **Reset meter data** button |
| 12 | General | `general` | 4 | yes | Master enable, minimap button, preview mode, debug console · **Reset all settings** button |
| 13 | Profiles | `profiles` | **0** | **no** | AceDBOptions' create / switch / copy / reset / delete |

Seven of the thirteen — Header, Rows, Bars, Text, Icons, Tooltip, Visibility — are one
`H.RenderSchema(c, PAGE)` call and nothing else. Frame and Data are the same plus a single bespoke
button. Adding an option to any of those nine means adding one row in `settings/Schema.lua` and
touching no page file at all.

Four are not:

- **Windows** and **Columns** act on the *registry* and on an *array*, neither of which a flat path
  addresses, so both are bespoke.
- **General** carries two session-only toggles drawn through `Helpers.SessionCheckbox`, which is
  wired to caller-supplied `get`/`set` instead of a settings path — so neither can accidentally
  become a stored value.
- **Profiles** hosts an options table this addon does not own.

### The three pages with no Defaults button, and why each

- **Windows** — nothing on it is a schema row except the name. "Restore this page's defaults" would
  have to mean deleting the registry back to one seed window, which is not what a player clicking
  Defaults expects.
- **Columns** — the column list is not a set of rows, so there is nothing per-row to restore.
  "Reset the columns" is what a fresh window gives, and the global reset already rebuilds them from
  the catalog through `NS.ApplyDefault`.
- **Profiles** — restoring here would delete the player's profiles, which is not what anyone means
  by restoring a default (`options-ui-§3`). This is enforced **twice**: the button is suppressed on
  the page, and `settings/OptionsSetup.lua`'s `skipRestoreAll` predicate
  (`row.page == "profiles"`) vetoes those rows from `/mm resetall`, the General page's
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

The parent category and all thirteen subcategories are registered during `OnInitialize`, before
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
is what every other page resolves against.

```
picker OnValueChanged
    → NS.State.SetActiveWindow(id)
    → NS.RefreshOptionsPanel()          -- STRUCTURAL, every panel
```

Every `window.`-prefixed schema row resolves through `NS.GetSetting` / `NS.SetByPath` against that
id (see [schema.md](schema.md#the-window-relative-path-model)). Move the picker and eleven pages
retarget together, along with `/mm set window.frame.width 300` typed in chat. **No path is
rewritten, and no page filters rows per window** — the panel moves the window the rows resolve
against.

### Structural refresh, not scalar

This is the one place the distinction matters, and getting it wrong is invisible in the worst way.

| | What changed | Refresh |
|---|---|---|
| A slider moved, `/mm set` ran | a **value** | `Helpers.RefreshScalars()` — re-read widget values in place |
| The picker moved, a window was created / deleted / renamed / duplicated, columns were edited | the **subject**, or which rows exist | `NS.RefreshOptionsPanel()` → `Helpers.RefreshAllPanels()` — rebuild |

A scalar refresh after a picker move would leave every widget on ten pages showing the previous
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

- **The picker is keyed by id, labelled by name.** Nothing stops two windows being called "Meter";
  ids are minted monotonically and never reused, so they are the only thing here that is actually a
  key.
- **Rename fires on `OnEnterPressed` only**, never `OnTextChanged` — renaming fires
  `WINDOWS_CHANGED` and rebuilds the picker, and doing that per keystroke would pull focus out of
  the box the player is typing in.
- **Delete confirms** through a `StaticPopup`, because it discards every setting on ten pages and
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

Each column renders as a section — `1. Damage`, `2. Healing` — carrying four controls: a stat
dropdown, a width slider (24–240), a show-bar checkbox, and a three-across row of Move left / Move
right / Remove. Below them, an Add column picker offering only the stats not already shown.

Five details worth knowing:

- **Every mutation snapshots, edits, and hands the whole array to `NS.SetByPath("window.columns", …)`.**
  Mutating the live table in place and then "writing" it would hand the seam a table it already
  holds, and any change detection would correctly conclude that nothing happened.
- **The seam's answer is checked, not discarded.** It can legitimately say no — an unknown stat
  carried in from a newer build, a width outside range, no window selected. A refusal followed by an
  unconditional repaint is the worst outcome: the page redraws from the unchanged stored array, so
  the control looks like it did nothing rather than like it failed. Repainting is conditional on
  success and the reason is printed.
- **The width slider commits on `OnMouseUp`, never `OnValueChanged`.** A width write rebuilds the
  window and re-renders this page; doing that per drag frame would tear the slider out from under
  the cursor.
- **A stat can appear once**, which `NS.SetByPath` enforces — so the pickers must not offer a choice
  it would refuse. `unusedStatList(w, keep)` takes a `keep` argument for exactly that: a column's own
  stat dropdown has to list the stat that column already shows, or the control opens with nothing
  selected.
- **A column whose stat this build does not have is still listed**, labelled with its raw key, so a
  player who moved a profile back from a newer build can see it and remove it. The renderer drops
  it; the editor must not hide it.

---

## The bespoke controls

Five things on four pages are commands rather than settings — they have no stored value to get, set
or restore, so none of them can be a schema row.

| Control | Page | What it does |
|---|---|---|
| **Reset position** | Frame | `WindowManager:ResetPosition(activeWindowId)` — the active window only. Positions are not rows (four values, one concept, and never read back off a live frame), so `NS.ApplyDefault` cannot reach them. |
| **Reset meter data** | Data | Confirms, then `NS.Provider.Reset()`. Irreversible and reaches **outside** this addon: `C_DamageMeter.ResetAllCombatSessions` wipes the data Blizzard's own meter is showing too. Routed through the provider and never straight at the Compat shim — the provider is the only permitted caller of the meter shims, and it also forgets the memoized availability answer and announces `METER_RESET`. |
| **Reset all settings** | General | Confirms, then `Helpers.RestoreAllDefaults()` — the same implementation the header Defaults button and `/mm resetall` use, so the three cannot drift and the Profiles veto applies to all three. Runs `afterRestoreAll`, which resets every window position. |
| **Preview mode** | General | `Helpers.SessionCheckbox` over `NS.State.preview`. Fills every window with placeholder rows so columns can be laid out without being in combat. Session-only: persisting it would mean logging in to a screen full of fake numbers. Also reachable as `/mm preview`, and implied by unlocking a window. |
| **Debug console** | General | The console **window's** visibility, not the logging flag. Logging runs with the console closed so a bug can be reproduced first and the log read afterwards; the flag itself is `/mm debug on\|off`'s and is never written to SavedVariables (`debug-logging-§5`). The spec comes from `LibKa0s-DebugLog-1.0` itself (`D:ConsoleCheckbox()`) rather than being hand-written, so its label, tooltip and show/hide are the library's. |

Both General toggles are also `sessionOnly` schema rows (`state.preview`, `state.debugConsole`) so
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
are still `Helpers.CreatePanel`, so this page looks like the other twelve rather than like a bolted-on
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
