# Saved variables and the settings schema

Two saved-variables are declared in `MultiMeters.toc`:

| Global | Owner | What it holds |
|---|---|---|
| `MultiMetersDB` | AceDB-3.0, assembled in `core/Database.lua` | every setting — the window registry, the id counter, the minimap table, and the account-wide schema version |
| `MultiMetersPerfDB` | `LibKa0s-Perf-1.0`, wired in `core/PerfSetup.lua` | `/mm perf` A/B capture records |

`MultiMetersPerfDB` sits **outside** the profile tree on purpose, and it is not merely "a second
table for tidiness". A capture record is diagnostics, not configuration: it describes one measured
session on one machine, and it means nothing under a different profile. Folding it into
`db.profile` would make a profile switch appear to delete captures and a profile copy appear to
duplicate them, and it would put library-owned bytes inside the tree `NS.ValidateSchema` and the
Defaults sweep both walk. Nothing in this addon reads or writes it directly — the library owns its
shape, and deleting it loses captures and nothing else.

Everything below is about `MultiMetersDB`.

---

## `db.global` — account-wide

```lua
db.global = {
    schemaVersion = 1,     -- CURRENT_DB_VERSION in core/Database.lua
}
```

The version is **addon-wide rather than per-profile** (`savedvariables-§1`), so a migration runs
once per account instead of once per profile. `NS:RunMigrations()` walks it forward one step at a
time out of the `migrations` table in `core/Database.lua`, and is called from `NS:InitDB()` and
again from every AceDB profile callback (changed / copied / reset).

At v1 the `migrations` table is empty by design: the shipped shape **is** v1. The runner exists
anyway so that the next non-additive change ships beside its migrator rather than having one wired
up under deadline pressure. Adding a v2 is two edits and no bootstrap change:

```lua
migrations[1] = function(db) ... ; db.global.schemaVersion = 2 end
local CURRENT_DB_VERSION = 2
```

**Bump the version only for a non-additive change** — a rename, a restructure, a type change.
Adding a new leaf setting or a new window config group needs no bump: AceDB's defaults merge
absorbs the profile-level ones and `Database.EnsureWindowShape` absorbs the per-window ones.

### Why normalization is shape-driven and not version-gated

`Database.SeedWindows` runs **unconditionally**, after the version walk, on every Init and every
profile swap. It does not ask "is this account older than v2"; it asks "is this key missing".

That is not belt-and-braces, it is the only question with a reliable answer. AceDB's defaults merge
backfills `db.global.schemaVersion` to the current value the moment `db.global` is first touched —
so an account that has never seen a migration reads as already-current, and a version-gated step
would be skipped entirely, silently, on exactly the profile that needed it.

---

## `db.profile` — the profile tree

The whole thing:

```lua
db.profile = {
    enabled      = true,      -- master enable. Off = no window drawn, no provider read.
    windows      = { },       -- an ARRAY of window config tables, in picker order
    nextWindowId = 1,         -- monotonic id source; ids are never reused
    minimap      = { hide = false },   -- LibDBIcon-1.0 owns this table's shape
    data         = {                   -- how the meter is read, addon-wide
        mergePets = false,             -- a pet's own row, or added to its owner's
        throttle  = 0.25,              -- seconds between refreshes
    },
    export       = {                   -- how the player last exported a segment
        metric    = "",                -- a Constants.STATS key, or "" for
                                       -- "match the exporting window's sort column"
        channel   = "SELF",            -- a Constants.EXPORT_CHANNELS key
        whisperTo = "",                -- meaningful only while channel is WHISPER
        lines     = 5,                 -- ranked lines per chat export, 1..MAX_ROWS
    },
}
```

Six keys, and that is the design working rather than the profile being thin. A window is an
**instance, not a singleton** (design §6): there are no global display settings, so `frame`,
`header`, `rows`, `bars`, `text`, `icons`, `tooltip`, `visibility`, `columns` and `data` all live
inside one window's config. What is left at profile level is the handful of things that cannot
sensibly differ between windows.

### `windows` is an array, and it is empty in the defaults

`defaults/Profile.lua` ships `windows = {}` and `core/Database.lua` seeds exactly one window into
it. The seed **cannot** be a default: AceDB's defaults merge would fold a default window back into
a profile the user had deleted their last window from, resurrecting it on every login with no way
to refuse it. So the seed lives in `Database.SeedWindows`, which detects "brand new" by an **empty
registry** rather than by a version — the same shape-driven rule as above.

`Database.GetWindows()` is the one traversal seam; every consumer that reads the registry goes
through it, and every consumer that *mutates* it goes through `modules/WindowManager.lua`, which is
the sole sender of `WINDOWS_CHANGED`.

### `nextWindowId` — ids are minted, never reused

`Database.NextWindowId()` hands out the next integer and advances the counter. Reuse would let a
deleted window's id be handed to a new one, which would then silently inherit the settings panel's
active-window pointer and every window-relative schema path aimed at it. A window with no `id` (a
hand-edited SavedVariables, a build that predates the counter) is **given** one rather than dropped:
losing a configured window is worse than renumbering it.

### `minimap`

`{ hide = false }` is all this addon declares. `LibDBIcon-1.0` is registered against this table and
treats it as its own — it reads `hide` and **writes** `minimapPos` (and a lock / free-position pair
if the player drags the button off the minimap). The addon must never enumerate the table or
normalize keys out of it, or a dragged button snaps back on the next login.

### `data` — how the meter is read, addon-wide

| Path | Type | Default | Control |
|---|---|---|---|
| `data.mergePets` | bool | `false` | checkbox on `general` |
| `data.throttle` | number | `0.25` | slider, `THROTTLE_MIN` 0.05 .. `THROTTLE_MAX` 2.0 |

Both were `window.data.*` until `schemaVersion` 5 and neither described a window — see
[the window template's `data` group](#data) for the lift and the one-time migration. `NS.DataSetting`
(`defaults/Profile.lua`) is the **one reader**: three modules want these two values
(`modules/Aggregator.lua` and `modules/Export.lua` want `mergePets`, `modules/Window.lua` wants
`throttle`), and each reaching into `NS.db` for itself would be three chances to disagree about what
a missing db means. Its fallback is the defaults tree rather than a literal, so a second copy of
`0.25` cannot drift from the schema row that claims to set it.

### `export` — the remembered export choices

| Path | Type | Default | Control |
|---|---|---|---|
| `export.metric` | string | `""` | no row — `Export.Open` reseeds it from the invoking window |
| `export.channel` | string | `"SELF"` | `hidden` row; drawn in the export modal |
| `export.whisperTo` | string | `""` | `hidden` row; drawn in the export modal |
| `export.lines` | number | `5` | `hidden` row; drawn in the export modal |

The three rows are filed on page `general` and all marked **`hidden`**, so the panel draws none of
them: the modal's own three controls are the ones a player uses, and a second copy on a settings page
restated a control met only in the dialog — with a standing chance of the two disagreeing about what
is selected.

**Hidden rather than deleted**, unlike the sort and session rows that went with the Data page, and
the difference is which seam writes them. Those were written directly by the window's own controls;
these are written by the modal through `NS.SetByPath`, which **refuses a path with no row**. Deleting
them would drop every export choice onto `writeExport`'s degraded fallback — the one that exists for
a half-loaded install — losing the validation, the debug line and `CONFIG_CHANGED`, and would take
`/mm set export.channel WHISPER` with it.

All are **absolute** paths — there is no `window.` prefix to resolve. They are the **one group in the profile that is not a property of
anything on screen**: every other setting here answers "how should this look", and these answer
"how did you last export", which is an action rather than an appearance.

That is why they are addon-wide despite an export always being started *from* a window. A player who
prints the top five to party does it from whichever window is nearest, and making them restate the
habit per window would be the settings tree being tidy at the player's expense. The segment is the
one thing an export does inherit from its invoking window, and it is inherited live rather than
stored — it is already `window.data`'s.

`channel` ships as `SELF`, which prints through `NS.Print` and reaches nobody else, and that default
is a safety property rather than a taste: the export surface is a glyph in a title bar, and a
misclick must not be able to put someone's numbers in front of a raid.

`metric` and `channel` are both dropdowns **derived from a catalog** rather than written out —
`Constants.STATS` and `Constants.EXPORT_CHANNELS` — so the panel, the CLI's `values` constraint and
the modal's own menu all offer exactly the keys that exist, and a stat or a channel removed from a
catalog cannot linger as an option that resolves to nothing. Localization happens at the use site in
`settings/Schema.lua` rather than in the catalog, because `core/Constants.lua` may load before
`locales/enUS.lua`.

`whisperTo` carries no non-empty check, unlike the window-name row it otherwise copies: `""` is both
its shipped default and a legal value, because it is what every channel but Whisper means. Its
validator refuses a table typed in from a hand-edited SavedVariables and nothing more — whether a
name resolves to a character is the server's answer to give, not this seam's — and a whisper with
nobody named falls back to printing to yourself rather than erroring at the send site. The modal
catches the empty box before that fallback can swallow it silently ("Enter a name to whisper to."),
and `Export.NoteSystemMessage` catches the server's *"no player named …"* answer to a name that is
filled in but wrong, cancelling the rest of the dump so one mistyped name is one message rather than
one per line.

The catalog carries **two whisper rows**, and they are two channels rather than one channel with a
mode: `WHISPER` takes its recipient from `export.whisperTo`, and `TARGET` reads it off whoever the
player has targeted at the moment the button is pressed. Nothing about the target is stored — a
remembered one is a name that was true when the modal opened.

`schemaVersion` 4 retires the channel `AUTO`, which used to resolve its own destination at send time
and was removed as ambiguous: choosing to print is choosing an audience, and a row that picks the
audience leaves the one fact the player needs unstated. A stored `AUTO` folds to `SELF`.

`lines` is clamped to `Constants.MAX_ROWS` rather than to a literal, because the aggregator truncates
an export there anyway and a slider offering 60 would be offering a number the send could not honor.

The modal writes every choice back through `NS.SetByPath`, so the panel's four widgets and the
modal's own copies of the same controls are two views of one preference rather than two preferences
that drift.

### What is deliberately *not* in the profile

The session-only flags in `core/State.lua`: `debug`, `restricted`, `preview`, `activeWindowId`, and
`State.cache`. A flag that survives a `/reload` is a setting; these are not. Persisting
`activeWindowId` in particular would make a deleted window's id outlive the window.

---

## The window config template

Written once as a private literal in `defaults/Profile.lua` and **deep-copied per window** by
`NS.DefaultWindow(id, name)`. It is never handed out by reference: two windows sharing one
sub-table is the classic profile-aliasing bug, where editing window 2's bar color silently edits
window 1's. The template is published as `NS.WINDOW_TEMPLATE` for the merge, the tests and the
schema validator.

```lua
{
    id   = <number>,     -- stamped by NS.DefaultWindow / Database.SeedWindows
    name = "Multi Meters #1",  -- Database.WindowName(n); shown in the picker and, optionally, in the header
    frame = {...}, header = {...}, rows = {...}, bars = {...}, text = {...},
    icons = {...}, tooltip = {...}, visibility = {...}, columns = {...}, data = {...},
}
```

Those ten group names are also `modules/WindowManager.lua`'s `COPY_GROUPS` and the settings panel's
"Settings to copy" dropdown — one list, three jobs. **A group added to the template and not to
`COPY_GROUPS` simply never copies.**

### The four text controls

Four groups draw text — `text` (the cells), `header` (the title bar), `columnHeader` (the label
strip) and `tooltip` — and each of them offers the **same five controls**: an LSM **font** picker, an
**outline** dropdown over one shared value set, a **shadow** checkbox, a **colour** picker and a
**`colorMode`** dropdown. They did not always: only `text` had a shadow, none had a class colour, and
a player styling a window had to discover which surface had grown which control.
`tests/test_schema.lua`'s *every text surface offers face, outline, shadow and colour* is the
contract — a fifth surface, or a sixth control, is a row added to that table and then made to pass.

**`class` means a different class on different surfaces, and the difference is not an
inconsistency.** A cell is about the player whose row it is, so `text.colorMode = "class"` takes
**that row's** — the same reading the Player column has always had and the same one
`bars.colorMode = "class"` has. A tooltip is about the player you are hovering, so it takes **that**
player's. The two header strips are about the **window** rather than about any row, so they take the
**local player's** — the only class those surfaces can sensibly mean. One reader answers all four:
`NS.ClassRGB(classFilename)` and `NS.PlayerClassRGB()` in `core/Namespace.lua`, so the header and a
row of the grid can never disagree about what a warlock looks like.

`stat` is resolved the same way — see [the table above](#the-four-text-surfaces-and-their-colour-modes)
— and `modules/Window.lua`'s `NS.SurfaceColor` is the one reader for both header strips and both of
their backgrounds.

The configured **alpha survives** every mode on every surface. Neither `RAID_CLASS_COLORS` nor
`Constants.STAT_COLORS` carries one, so taking one from them would make a colour mode silently cancel
Text opacity — one setting overruling another. A class or statistic that cannot be read keeps the
configured colour rather than falling back to a hue invented for the occasion.

**Text opacity is folded INTO that alpha**, in `modules/Row.lua`'s `textAlpha`, rather than living
only on `FontString:SetAlpha`. The per-row colour passes write their own alpha through
`SetTextColor` after the style pass has run, and in the client the numbers came back to full opacity
while the names stayed faded — one setting working on half the grid. Folding it in means every colour
write carries the opacity and a later write cannot undo it.

Every one of the new keys ships **off**: `header.shadow`, `columnHeader.shadow`,
`tooltip.fontShadow` are `false`, and all six `colorMode` / `bgColorMode` keys ship `"custom"`. A setting added to a shipped window
must not change how that window already looks, and a shadow under an outlined face is heavier than
either alone. `text.shadow` keeps its long-standing `true`.

### `frame` — the standalone window

| Key | Default | Notes |
|---|---|---|
| `width` | `716` | slider 160–1400. Derived from the grid: name column + six default columns at `COLUMN_WIDTH` + seams + padding. |
| `height` | `220` | slider 60–900 |
| `scale` | `1.0` | 0.5–2.0. Applied to the anchor **and** the visible frame. Scaling only the frame left the box its original size and shrank its contents, because the frame is pinned TOPLEFT/BOTTOMRIGHT to the anchor and inherits its screen rect. |
| `alpha` | `1.0` | 0–1, rendered as a percentage |
| `strata` | `"MEDIUM"` | `LOW` `MEDIUM` `HIGH` `DIALOG` |
| `backdropColor` | `{ r=0, g=0, b=0, a=0.75 }` | |
| `borderStyle` | `"Blizzard Tooltip"` | LSM `border` key |
| `borderStyle` = `"None"` (or `""`, or unset) | | means **no edge**, answered by `borderPath` itself. That resolver distinguishes a CHOICE from a FAILURE: "None" is nil, while a name it cannot fetch — a media pack that is no longer installed — still falls back to the library's own edge. Conflating the two handed a player who picked "None" the Ka0s edge they had just turned off. Same rule and same order as `modules/Tooltip.lua`'s `mediaPath`, the addon's other LSM resolver |
| `borderSize` | `2` | `0` drops `edgeFile` with it — a zero edge size with a texture still present is drawn as a hard 1px line. With no edge, the skin's 1px `frame.innerBorder` child is hidden too: it is not part of the backdrop `ApplyBorder` rewrites, so it used to be the whole visible border on a window whose border was switched off |
| `borderColor` | `{ r=0, g=0, b=0, a=1 }` | |
| `padding` | `6` | frame edge to rows |
| `locked` | `false` | unlocking implies preview mode |
| `clampToScreen` | `true` | |
| `titleBar` | `true` | |
| `closeButton` | `true` | a **header control**, grouped with the `show*` keys on the panel |
| `minimised` | `false` | a **hidden** schema row: writable through `NS.SetByPath` and listed by `/mm list`, but drawn as no control. It is per-window state the header's own minimise button writes, not a preference |
| `position` | `{ point="CENTER", relativePoint="CENTER", x=0, y=0 }` | **not a schema row** — see below |

The chrome itself is `LibKa0s-Core-1.0`'s shared `SKIN` / `ApplySkin`, which tints `frame.title` and
`frame.divider` on its own, so the accent colors are not settings here. What the player owns is
geometry, the backdrop and the LSM border, layered over the skin in that order.

**`frame.position` is not a schema row and cannot be one.** It is four values behind one concept,
which the flat path model has no vocabulary for, and it is written by a drag rather than typed. It
is also the one piece of window state that must never be *read back* off the live frame (rule R3).
`modules/Window.lua` keeps an empty, invisible `anchor` frame that never receives a value and reads
`GetPoint` off **that**; the visible window is anchored to it. Because positions have no row,
`NS.ApplyDefault` never reaches them. A global reset reaches them anyway, because "Reset all
settings" is a **profile reset** and a position lives in the profile. (`NS.ResetPositions` used to
exist for exactly this and was removed with its last caller; `/mm reset-positions` is the targeted
verb and goes straight to `modules/WindowManager.lua`, which owns re-anchoring a live frame.)

### `header` — the strip above the rows

`title = ""` (empty falls back to the window's name) · `showSessionName = true` ·
`showDuration = true` · `showTotals = true` · `font = "Friz Quadrata TT"` · `size = 12` ·
`outline = "OUTLINE"` · `color = { r=1, g=0.82, b=0, a=1 }` · `colorMode = "custom"` ·
`align = "LEFT"` · `height = 18` · `bgColor = { r=0, g=0, b=0, a=0.5 }` · `bgColorMode = "custom"`.

`showTotals` shows the group total **for the sort column**, taken off the aggregate the render pass
just parked on the window — never a second provider read.

**`bgColor` paints the TITLE BAR and stops there.** It used to cover both header rows, on the reading
that "the header" is the whole block a player points at — which meant `columnHeader.bgColor` was
drawn underneath it and could not be seen, and a colour picked for the title bar restyled the grid's
column labels too. Two strips, two settings, two rectangles.

All of these are edited under one **Frame header** group on the Header page. It was two groups
("Header text" and "Header background"), which put `align` and `height` — both properties of the
text — under a heading that said background.

### The four text surfaces and their colour modes

`text`, `header`, `columnHeader` and `tooltip` each carry the same five controls — face, outline,
shadow, colour, and a **`colorMode`** of `class` / `stat` / `custom`. The two header strips carry a
`bgColorMode` over the same three. `schemaVersion` 7 migrates the `classColor` boolean each of them
used to have: `true` → `"class"`, `false` → `"custom"`, which is exactly what it meant, and the dead
key is pruned.

**`stat` means a different statistic per surface, and that is the point** — it is one question ("which
statistic is this text about?") answered by whichever statistic the surface actually describes:

| Surface | What `class` is | What `stat` is |
|---|---|---|
| `text` (cells) | the class of the row being drawn | the column the cell sits in |
| `header` (title bar) | **yours** — a header is about the window, not a row | the window's **sort column** |
| `columnHeader` | yours, for the same reason | **each label's own column** — the one surface where it is literally per column |
| `tooltip` | the class of the player being hovered | the window's sort column |

`none` is deliberately **not** offered. It is a legal answer for a tint drawn behind something and
never for the writing itself, and a text surface set to "no colour" is one nobody can read.

The configured **alpha survives every mode**: neither `RAID_CLASS_COLORS` nor `Constants.STAT_COLORS`
carries one, and a mode that silently reset transparency would be one setting cancelling another.
That matters most for the two backgrounds, where the alpha is what makes a colour a tint rather than
a slab. A colour that cannot be resolved — an unknown class, a stat with no palette entry — falls
back to the configured one.

`columnHeader.bgColorMode == "stat"` is the only mode that paints **per column**: it puts a texture
behind each label rather than one across the strip, because a class is not a property of a column and
every other mode has exactly one colour to draw.

### `columnHeader` — the "Player | Damage | Healing" strip

`font = "Friz Quadrata TT"` · `size = 11` · `outline = "OUTLINE"` ·
`color = { r=1, g=0.82, b=0, a=1 }` · `colorMode = "custom"` · `bgColor = { r=0, g=0, b=0, a=0 }` ·
`bgColorMode = "custom"`.

**Separate from both neighbours, and it was not before.** The strip used to take its font path and
size from `text` and its outline and colour from `header`, so changing the cell font silently
restyled the headers and no setting could make the strip differ from the numbers beneath it. Every
default above is the value that arrangement already resolved to, so an existing window is
pixel-identical after the upgrade — what changed is that the settings exist and are independent.

`bgColor` is new capability rather than a moved one: the strip has never had a backdrop, which is why
it defaults fully transparent.

### `rows` — one per group member

Edited on the **Bars page**, at the top of it: how tall a row is, how many there are and which way
they grow decide the shape of every bar drawn under them, so the two groups sit above the bar's own.
The Rows page is gone; the paths did not move with it.

`maxRows = 0` (0 means "as many as fit the frame"; a positive value caps it, hard-ceilinged at
`Constants.MAX_ROWS = 40`) · `height = 16` · `spacing = 1` · `growthDirection = "DOWN"` ·
`alwaysShowSelf = true` · `highlightSelf = true` · `alternatingBackground = true` ·
`mouseoverHighlight = true`.

`alwaysShowSelf` spends the last visible slot on the local player rather than growing the list, so
the row count stays exactly at the cap (`Aggregator.ApplyRowLimit`).

**`alternatingBackground` lives here and is EDITED on the Bars page**, beside `bars.bgColorMode` —
the two of them decide what colour sits behind a row, and choosing between them meant reading two
pages. It stays a row-level key because it is a row-level fact: `RowProto:Update` draws it, not the
cells.

**`classBackground` and `classBackgroundAlpha` are gone, and they were doing nothing before they
went.** The row tint is painted per CELL from `bars.bgColorMode` and `bars.bgAlpha` — it moved there
when tinting the row itself turned out to tint the two-pixel seams between the columns and lose the
separators the grid is read by — and those two keys were left behind with no reader at all. Two
settings-panel controls answering a question that was already answered one page over, into a void.

### `bars` — the StatusBar in every cell

`texture = "Blizzard Raid Bar"` (LSM `statusbar`) · `colorMode = "class"` · `customColor =
{ r=0.35, g=0.55, b=0.85, a=1 }` · `bgColor = { r=0, g=0, b=0, a=1 }` · `bgAlpha = 0.35` ·
`border = false` · `borderThickness = 1` · `borderColor = { r=0, g=0, b=0, a=1 }` · `alpha = 1.0` ·
`fillDirection = "LEFT"`.

**`alpha` fades the FILL TEXTURE, not the cell.** It used to be `bar:SetAlpha`, and the StatusBar is
the cell — it parents the fill, the backdrop, both text slots and the name column's icon — so
dropping "Bar opacity" to 10% faded the whole grid. Three settings paint three surfaces (`alpha` the
fill, `bgAlpha` the backdrop, `text.alpha` the two FontStrings) and none can cancel another.

`borderThickness` and `borderColor` were constants until they were settings: one pixel, in the
library skin's own edge colour, which no setting could reach. The skin's edge is still the fallback
for the colour, so a window that never touched either keeps the border it had.

`colorMode` is `class` / `stat` / `custom`. **`class` is the default because `classFilename` is
`NeverSecret`** — a class-colored bar is still correct at the height of a pull, when every number on
the row is an opaque handle. `fillDirection` names where the fill *starts*, so `"LEFT"` means the
bar grows rightward (`SetReverseFill(false)`).

### The header's controls

The whole title row — name, session line and controls — is centred on one line through
`Window:TitleRowTop`, computed from the padding, `header.height` and each item's own configured size.
The band it centres in runs from the frame's **top edge** down to the divider, not the tinted band
alone: the padding above is not a margin to anyone looking at the window, so centring in the band
leaves it as dead space above the row and lands the text against the divider. Nothing in the title
bar is anchored to a hand-picked offset any more.

`showMinimise` · `showLock` · `showSettings` · `showSegment` · `showReset` · `showExport` — all
`true`. Six of the seven controls; `closeButton` is the seventh and deliberately keeps its older
name, because renaming it to `showClose` for symmetry would migrate every stored profile in exchange
for a consistency nobody can see. All seven sit in the panel's **Header controls** group, because
what each of them governs is a control in the header strip.

**There is no `resizeGrip` key.** There was, and it was read once while the frame was being built —
so unticking it did nothing until a reload. The grip follows the **lock**: drawn while the window is
unlocked, hidden while it is locked, which is the same question the lock already answers. Locking a
window is how you put its grip away.

`hoverReveal = true` fades every control except the one under the pointer — the reveal is per
control, not per strip, so it *is* the "which one am I about to click" feedback rather than a
separate highlight drawn behind it. `minimised = false`
collapses the window to that bar — the stored `frame.height` is untouched, so expanding restores it
exactly. `controlColor = { r=1, g=1, b=1, a=1 }` and `controlHoverColor = { r=1, g=0.82, b=0, a=1 }` — two
colours, because hover is the only feedback a control gives. The art ships white and is tinted by a
**multiply**, so the shipped `controlColor` is the identity rather than a recolour: the icons read as
chrome, and the pointer turns exactly one of them the gold the rest of the header uses. Both are
pickers rather than a "match the header text" switch — one of the two states being unconfigurable was
the complaint that produced them. (The tint had never run at all before: `HeaderControls.Style` read
`NS.HeaderStyle`, which nothing published, so it fell through to a white fallback every time.
`modules/Window.lua` publishes it now, and the controls take the header's **font** from it while
carrying their own colours.)

`controlSize = 16` is the *slot* each control occupies — its click target and the strip's layout
pitch. The art is drawn centred inside that slot at 72% of it, so a 64px icon lands at 11px in a 16px
box, on the same line as a 12px title; a glyph that reaches its own edges reads much heavier than the
header text beside it when it fills the slot outright.

**A collapsed window does not poll.** That is a real clause in `ShouldPoll`, not an emergent
property of hiding: `OnUpdate` is installed on the frame, and the frame stays shown while collapsed
— only the body hides.

### `text` — the FontString in every cell

`leftSlot = "smart"` · `rightSlot = "none"` — **both take the same five values**, `none` / `smart` /
`total` / `rate` / `percent`, in either position. They used to take different three-value sets
overlapping on two, which made "the total on the right" unexpressible for no reason anyone could
state.

**Every value is literal and nothing falls back.** `none` renders nothing, `rate` renders nothing on
a stat with no per-second figure, and a cell whose slots both come back empty stays empty — a bar
with no text is a legitimate thing to want. The old code substituted the total whenever a cell would
otherwise have been blank, which meant setting both slots to None appeared to do nothing at all. A
lone right-slot figure likewise stays on the right rather than sliding into the empty left slot.

`smart` is the one value whose meaning depends on the column: the per-second figure where the stat
has one (`Constants.STATS[].isRate` — Damage and Healing), the absolute figure everywhere else. It is
`isRate` read for you, so one setting says "the figure this column is about" across a grid that mixes
both kinds, and it is what the left slot ships as. · `numberFormat = "abbreviated"` (`abbreviated` / `full`) ·
`deathTimeFormat = "clock"` (`clock` / `ago`) · `maxNameLength = 20` (0 = no
cap) · `font = Const.FONT_MONO_NAME` ("JetBrains Mono") · `size = 11` · `outline = "NONE"` ·
`shadow = true` · `color = { r=1, g=1, b=1, a=1 }` · `alpha = 1.0`.

`text.alpha` is applied to the two **FontStrings**, never to the cell's StatusBar. The FontStrings
are children of that bar, so folding this setting into the bar's own alpha faded the fill, the
backdrop, the borders and the name column's icons along with the writing — fading the whole grid is
`bars.alpha`'s job. The compounding still happens in the one direction that is correct: a child's
alpha applies on top of its parent's, so a bar at 50% carrying text at 50% renders that text at 25%,
and never the reverse.

`maxNameLength` counts **characters, not bytes** — a byte slice can land inside a multi-byte
character and emit half a code point, and the names most likely to need truncating are exactly the
accented ones. It sits above WoW's 12-character player-name limit because a group meter also lists
NPCs, which are not bound by it. The realm is stripped regardless of the number.

Both the strip and the cap are **gated on the concat probe**: `string.match` and `string.sub` read
the characters of a value, and doing that to a secret is what rule R1 forbids, so a `ConditionalSecret`
name reaches the widget untouched and uncapped.

`deathTimeFormat` labels a death in the Deaths tooltip and the death drill-down — the time of day,
or how long ago. A third value, "time into the fight", was built and removed: nothing on the client
can date a past death against the run it happened in, and the captures that establish that are on
[issue #18](https://github.com/tusharsaxena/MultiMeters/issues/18). Both surviving values read the
recap's own newest event timestamp, which is absolute epoch and always present.

**Nothing here divides anything.** `numberFormat` picks which `NumericRuleFormatter` instance
`modules/Format.lua` hands the value to; the formatter does the division natively, which is the only
legal way to render "12.4M" from a secret. `percent` is the one slot that goes quiet in combat —
`modules/Aggregator.lua` only produces it when both operands were accessible, and empty means
"cannot be known right now", never "zero percent". That is why the shipped pair is `total` and
`none`.

A `rate` slot renders only for stats whose catalog row sets `isRate` — `DamageDone` and
`HealingDone`. Counting stats leave it empty rather than announcing "0.42 interrupts per second";
that is a property of the **stat**, not of the slot, which is why both slots offer `rate` and both
drop it on the same columns. A cell whose slots both come back empty falls back to its total, so a
column can never render a header, a bar and no number.

### `icons` — the marks in the name column

`showIcon = true` · `size = 14` · `position = "LEFT"`.

**ONE SLOT, ONE TOGGLE.** There were three flags, one per icon kind, and a player who turned them all
on got three textures competing with the name for a column that has to hold a name. The slot picks
its own icon per row, in this order: a **breakdown row is a spell**, so it draws the spell's icon and
stops; otherwise the **spec** where `specIconID` is known, because that separates the three druids in
a raid where a class icon cannot; otherwise the **class**; and a **role never** — three roles across
a whole raid identifies nobody, and it was the icon most likely to be on screen when the name column
ran out of room.

`schemaVersion` 3 migrates the old flags: `showIcon` is on if *any* of the three was, since somebody
running the role icon alone had asked for an icon, and the three dead keys are removed rather than
left to rot in every saved profile.

`classFilename` and `specIconID` are both `NeverSecret`, so this column renders in full even when
every number to its right is opaque.

### `tooltip`

`anchor = "CURSOR"` · `offsetX = 0` · `offsetY = 0` · `showSpells = true` · `maxSpells = 10` ·
`showAllStatsOnName = true` · `hideInCombat = false`.

Its own appearance, kept separate from `bars` and `text` on purpose — a 14px spell line and a 90px
cell are different surfaces, and a texture or a size that reads across one often does not across the
other: `barTexture = "Blizzard Raid Bar"` · `barSpacing = 1` · `scale = 1.0` · `barColorMode = "class"` · `barAlpha = 0.85` · `barBgColorMode = "custom"` ·
`barBgAlpha = 0.35` · `barBorderStyle = "None"` ·
`barBorderSize = 1` · `barBorderColor = { r = 0, g = 0, b = 0, a = 1 }` ·
`font = "Friz Quadrata TT"` · `fontSize = 12` · `fontOutline = "NONE"` ·
`textColor = { r = 1, g = 1, b = 1, a = 1 }`. One colour for **both** number slots: the amount used
to be hardcoded gold and the share hardcoded white, which read as two kinds of number when they are
one line's two figures.

The Targets section: `showTargets = false` · `maxTargets = 3`.

`anchor` takes nine values — `CURSOR`, the four edges and the four corners — and each maps to a
GameTooltip `ANCHOR_*` token. `ANCHOR_NONE` and `ANCHOR_PRESERVE` are deliberately absent: both mean
"the owner places the tooltip itself", which would require computing a point from a frame that has
held a secret value.

`maxSpells = 0` means "every spell the breakdown collected", which is the collector's own ceiling of
64 rather than literally unbounded — the "and N more" line stays honest about anything past it.

`showTargets` is off by default for two separate reasons: it costs one provider call per enemy on a
hover to build (cached per session afterwards), and it is a **summation**, so it is absent for the whole of a pull rather
than approximated ([data-flow.md §9](data-flow.md)).

`hideInCombat` is a **preference, not a guard**: a tooltip's numbers go through the formatter like
every other, so nothing about it is unsafe mid-pull — it is simply in the way. The combat test
behind it is `UnitAffectingCombat("player")`, not `InCombatLockdown()`; the setting is a statement
about the player, not about whether secure writes are currently legal.

### `visibility`

**Where to show this window** — every context `true`: `dungeon` · `raid` · `arena` ·
`battleground` · `delve` · `scenario` · `world`.

**When to hide this window** — every rule `false`: `hideWhenSolo` · `hideInVehicle` ·
`hideWhenMounted` · `hideWhenSkyriding` · `hideOnTaxi` · `hideInHousing` · `hideInPetBattle` ·
`hideWhenDead`.

**Combat** — `hideInCombat = false` · `hideOutOfCombat = false`.

**Show everywhere, hide nowhere.** A fresh profile draws the meter wherever the player stands and
nothing takes it away until they ask for it. This reverses 0.1.0, which shipped the open world off
and four rules on. That version was deciding on the player's behalf that a meter in the open world
is noise, and the cost of being wrong is this feature's worst failure: a window that never appears,
with seventeen checkboxes to read before you can tell which one did it. A default that only ever
shows has no such failure mode.

Refused **at the source** (`performance-§6`): a hidden window does not merely skip its draw, it
stops asking the provider for data. `modules/Visibility.lua` maps Blizzard's `instanceType` to these
keys, and anything it has never heard of resolves to `world`. Note what that means now `world` ships `true`:
an instance type a future patch invents **shows** rather than hides — the opposite of 0.1.0's
deny-by-default fallthrough, and the deliberate trade. A context nobody has taught this addon about
draws a meter the player can switch off, rather than silently withholding one they cannot find the
switch for.

**Delves resolve before the instance-type table**, because Blizzard has no delve instance type: a
delve reports `"scenario"`, the same token an ordinary scenario and a follower dungeon report.
`Compat.IsInDelve` owns the three-signal ladder that separates them — `C_PartyInfo.IsDelveInProgress`,
scenario difficulty `208`, `C_DelvesUI.HasActiveDelve` — and takes ANY of them as authoritative,
because outdoor delves do not light all three up together.

**Every rule after the context block is hide-shaped**, and that is load-bearing rather than a naming
habit. A key missing from a stored window has to read as "nothing objects"; a show-shaped key is
`false` when absent, so a profile written before the rule existed would have every window hidden by
a setting its owner never touched. `Database.EnsureWindowShape` backfills the shape, but on a
schedule `modules/Visibility.lua` cannot see and must not depend on. `hideInCombat` and
`hideOutOfCombat` are therefore two independent rules rather than one tri-state; ticking both is a
window that never shows, and `/mm debug diag` still names the side of the pull that decided.

The order of evaluation is context first, then every veto, then combat. Running it the other way
round would report `solo` as the reason a window is hidden in the open world, when the real reason
is that the player switched the open world off.

### `columns` — the ordered stat list

An **array**, filled by `NS.DefaultWindow` from `Constants.DEFAULT_STAT_KEYS` rather than written
out in the template, so the stat catalog in `core/Constants.lua` stays the single source of truth
for which stats exist and which ship enabled.

```lua
columns = {
    { stat = "DamageDone",           width = 92, showBar = true },
    { stat = "HealingDone",          width = 92, showBar = true },
    { stat = "Interrupts",           width = 48, showBar = true },
    { stat = "Dispels",              width = 48, showBar = true },
    { stat = "AvoidableDamageTaken", width = 78, showBar = true },
    { stat = "Deaths",               width = 44, showBar = true },
}
```

The catalog offers two more that ship disabled: `Absorbs` and `DamageTaken`. `EnemyDamageTaken` is
no longer offered as a column at all — it is read, never catalogued (issue #2), and a profile that
still holds such a column is not migrated: the renderer drops it and the Columns page lists it so it
can be removed by hand. `Dps` and `Hps` are absent from the catalog entirely and never queried — `amountPerSecond` ships on
the same source row as `totalAmount`, so one `DamageDone` read fills both halves of the column.

### `data`

`sessionType = Const.SESSION_TYPE.Overall` · `sortMode = "value"` · `sortColumn = "DamageDone"` ·
`sortAscending = false`.

**None of these four is a schema row, and that is the point.** Every one of them is written by a
control on the window itself — the header's segment dropdown writes `sessionType`, and one click on
a column header writes all three sort fields (`modules/Window.lua`'s `SortByColumn`) — so a settings
page for them restated a control the player already has three inches from where they are looking.
They were **deleted** rather than hidden, so there is no `/mm set` for them either: the click path
writes the fields directly rather than through `NS.SetByPath`, and a CLI that could also write them
was a second seam onto state the window owns.

**`mergePets` and `throttle` used to live here** and are addon-wide from `schemaVersion` 5, at
`profile.data`. Neither described a window: one says what a pet's damage *is*, the other is a refresh
rate, and two windows disagreeing about either is two answers to one question. The migration lifts
the **first** window's pair per profile and removes the keys from every window — there is no merge
rule that is right for a player who set two windows differently, and the first window is the one at
the top of their own picker. Note that the `== nil` rule that governs `EnsureWindowShape` deliberately
does **not** apply to that step: AceDB's defaults merge runs before any migration, so `profile.data`
is already filled with the shipped values and "the player set this" cannot be told from "the merge
just wrote it" — the window's value is the only one carrying intent.

`sortMode` is `value` / `name` / `provider` / `roster` — `name` is what the **Player** column header
sorts by — and it governs the **unrestricted** build only. While
the Combat restriction is active the rows are the engine's own ranking of the sort column, because
`sourceGUID` is secret and there is nothing of ours left to sort; see `docs/data-flow.md`.
`sortColumn` and `sortAscending` **do** still reach a restricted grid — picking a stat re-ranks it to
the engine's ordering for that stat, and the direction is applied as a reversal — so the two of them
are live in both states while `sortMode` is not.

**`sessionID` has no schema row and no default**, and both absences are deliberate. It is set by the
header's segment dropdown rather than by the settings panel, and its "unset" state is `nil` —
"no segment pinned, follow `sessionType`" — which a defaults tree cannot express. It is persisted:
`modules/Window.lua` writes it into `window.data` and AceDB stores it from there.

When it *is* set it **overrides `sessionType`**, and every read path honors it — the aggregator's
column reads, the header's duration, the tooltip's spell breakdown and the drill-down's. A pinned id
the client no longer holds is dropped back to `nil` by `WindowProto:DropStaleSegment` at the top of
the next refresh, because a stale id does not error, it silently reads an empty session.

---

## The window-relative path model

This is the part of the schema a reader will not guess, and it is the only thing about
`settings/Schema.lua` that is not standard-issue.

### The problem

Almost every setting is per-window, and a window is an instance the user creates at runtime. Written
out absolutely, a window row's path would have to be:

```
windows.<id>.frame.width
```

Dynamic, unknowable when `settings/Schema.lua` loads, and impossible to express in the **flat path
model** that the CLI (`LibKa0s-Slash-1.0`) and the panel (`LibKa0s-Options-1.0`) both read. A flat
path addresses a fixed named leaf; `<id>` is neither fixed nor named.

### The resolution

A window row's path is **relative to a window** and is spelled with a `window.` prefix:

```lua
{ path = "window.frame.width", type = "number", default = 716, page = "frame", ... }
```

`NS.GetSetting` and `NS.SetByPath` resolve that prefix against the session's **active window** —
`NS.State.activeWindowId`, which the settings panel's window picker moves. Global rows keep absolute
paths (`enabled`, `minimap.hide`) and resolve against `db.profile`.

```lua
-- settings/Schema.lua
local function resolveRoot(parts)
    if parts[1] == "window" then
        local w, id = activeWindow()      -- picker's selection, else windows[1]
        return w, 2, id
    end
    return NS.db and NS.db.profile or nil, 1, nil
end
```

`activeWindow()` falls back to **the first window in the registry** when nothing is selected, rather
than to nil. The CLI has no picker, and `/mm set window.frame.width 300` typed on a fresh login must
mean something rather than fail with a message about an internal pointer the user has never heard
of. `settings/Windows.lua` and `settings/Columns.lua` heal a stale pointer the same way on every
read.

### What it buys

One schema, one write seam, and one sentence that is true in both surfaces: **`window.frame.width`
means "the window I am editing"**, on the CLI exactly as in the panel. The picker retargets seventy
or so rows by moving one integer of session state instead of by rewriting every path. The panel does
not filter rows per window — it *moves the window every row resolves against*, which is why
`NS.SchemaForPage(pageKey, filter)` accepts the library's `ctx.unit` and passes it through
untouched.

### Why `NS.ValidateSchema` exists

The cost of the relative model is that a `window.`-prefixed path is resolved against a table that
does not exist until runtime, so a typo cannot fail at load. `NS.ValidateSchema()` is what closes
that hole. It runs from the options descriptor's `validate` hook at panel creation and is asserted
to return **0** by the headless suite. Two independent checks per non-session row:

1. **Resolution.** Every path must resolve against `defaults/Profile.lua` — `window.` rows against
   `NS.WINDOW_TEMPLATE`, global rows against `NS.defaults.profile`. A path that does not resolve is
   a setting whose writes land on a key nothing reads: the panel renders, the widget shows the row's
   own default, the write succeeds, and nothing anywhere says so. The row's own `default` is **not**
   an escape hatch from this — a row with a good default and a typo'd path is the worst case, not
   the exempt one.
2. **Agreement.** The row's `default` must equal the value the defaults tree ships. The two are
   restated in two files on purpose: one is what a widget shows before the db exists, the other is
   what a fresh profile is built from. A single shared reference would agree with itself by
   construction and prove nothing. A disagreement means a Defaults click silently moves a setting
   somewhere the addon never shipped it — the bug this function exists to catch.

Table defaults (every color) are compared field-wise one level deep, which is exactly as deep as
this schema's table defaults go.

---

## Row shape

```
path         resolution path. `window.`-prefixed = active window; else db.profile.
type         "bool" | "number" | "string" | "color". THE widget dispatch key —
             the options major picks a maker from it and the slash major picks a
             parser from the same field, which is what keeps the CLI and the panel
             agreeing about what a row is. There is deliberately no separate
             `widget` field: a second selector is a second thing to keep in step.
default      the shipped value; MUST equal defaults/Profile.lua's.
page         the page key. Groups `/mm list`, feeds the panel's rowsForPage, names
             the CONFIG_CHANGED section, and `page == "profiles"` is the reset-all
             veto. One key, four jobs.
group        section heading inside the page.
label, desc  displayed strings, localized at declaration through NS.L.
min/max/step/fmt/isPercent    slider shape.
values/sorting/dialogControl  dropdown shape. A `number` row carrying `values` is
             inferred as an enum by both majors and constrained rather than clamped.
validate     optional predicate; a false answer refuses the write.
onChange     optional reaction for the few settings CONFIG_CHANGED cannot express.
invert       display is the negation of storage (the one minimap row).
sessionOnly  never persisted; the row's own get/set are the whole storage.
```

### `invert` — exactly one row

`minimap.hide` stores the negation of what it displays. LibDBIcon owns the `minimap` table and its
key is `hide`, while a checkbox a user reads has to say "Show minimap button" — a checkbox labelled
with a negative is the settings-panel double-negative everyone mis-clicks once. Rather than give
that one row a private get/set pair (which the CLI would then have to know about separately), the
seam carries a two-line `toStored` / `toDisplay` concept used at three call sites. `default` is
always the **stored** value, so the validator still compares like with like.

### `sessionOnly` — exempt from validation, still rows

`state.preview` and `state.debugConsole` are never persisted, so they have no home in the defaults
tree and `NS.ValidateSchema` skips them. They are rows anyway because they belong on the page and in
`/mm list` beside the settings they sit next to — a toggle that exists only in the panel is a toggle
the CLI cannot reach. Their own `get` / `set` **are** the whole storage; `NS.GetSetting` returns
`row.get()` directly rather than `and`-ing it through, because a session row answering `false` is a
real answer and `row.get() or nil` would turn every "off" into "no such setting".

### `onChange` — the exception, not the rule

The default refresh for every row is the `CONFIG_CHANGED` message `NS.SetByPath` sends, and
`settings/Schema.lua` is its **one sender**. Windows subscribe and re-read their upvalues; the panel
re-reads its scalars. `onChange` exists only where the message genuinely cannot express the effect:

- every `window.visibility.*` row and `enabled` → `refreshVisibility()`, because the effect is a
  window appearing or disappearing (the show ladder's decision), not a window redrawing;
- `minimap.hide` → `refreshMinimap()`, because LibDBIcon holds a Blizzard-side object outside our
  config tree and has to be told to look again.

Both resolve their target through `NS` at call time, because both load after `settings/Schema.lua`.

---

## The write seam

`NS.SetByPath(path, value)` is the single write seam (`settings-schema-§1`). The panel's widgets,
`/mm set`, `/mm reset`, `NS.ApplyDefault` and the global Defaults sweep all land here, so validation,
the debug line, the row's reaction and the refresh cannot be skipped by whichever caller forgot one.

**Order is load-bearing**: write → react (`onChange`) → log once → announce `CONFIG_CHANGED` →
re-sync the panel's scalars. Reacting before the write would hand a refresher the old value; logging
in the reactor would log it once per subscriber.

Values are **deep-copied on the way in**. A color table handed straight from a widget (or from a
row's default) would otherwise be shared with whoever else holds it, and editing one window's color
would edit theirs. `NS.ApplyDefault` copies for the same reason, and takes the **row** rather than
the path because both library majors hand over the row.

The announcement carries `{ section = row.page, windowId = <id or nil> }`. A window ignores a
payload naming a different id, so a twenty-window profile does not re-apply nineteen windows because
one of them was edited.

The refresh at the tail is `Helpers.RefreshScalars()` — an in-place value re-read, never a structural
rebuild. A structural refresh here would rebuild the page under a slider mid-drag, and writing a
value emphatically does not change which rows exist. (The picker on the Windows page *does* force a
structural sweep, because there the rows changed **subject**; see `docs/settings-panel.md`.)

---

## The columns carve-out

`window.columns` is an ordered array whose length is the user's, not the schema's. A path model
addresses named leaves; it has no vocabulary for "insert a column before index 2". So the columns
subtree is a documented carve-out rather than a row:

| Operation | Behavior |
|---|---|
| `/mm get window.columns` | **reads** — the generic resolver reaches it like any other node |
| `NS.SetByPath("window.columns", array)` | **accepted whole-array** — the only granularity a path can honestly express |
| `NS.SetByPath("window.columns.2.width", 90)` | **refused** — the ordinal moves on the next add, remove or reorder, so a stored reference to it is wrong by the next edit |

Because the array has no row, it gets none of a row's `validate`, so the check lives at the seam and
is at least as strict. `normalizeColumns` proves the array shape before reading anything out of it
(a hole or a string key would make `#value` an arbitrary answer), then rebuilds it entry by entry:

- at least one column (a window of nothing but names reads as a broken addon);
- every `stat` is a string present in `Constants.STAT_BY_KEY`, **once** — two Damage columns show
  identical numbers twice and double the provider reads for them;
- `width` is a number in **24–240**, with an explicit `width ~= width` NaN test (NaN passes every
  ordinary comparison and would reach `SetWidth` as a size no frame can be given);
- `showBar` is a real boolean.

Rebuilding rather than accepting the caller's table does two jobs at once: the stored array can never
share a sub-table with whoever handed it over, and any extra key someone smuggled in is dropped
rather than persisted into a profile the renderer will not read. The write then takes the **same**
debug line, `CONFIG_CHANGED` message and panel re-sync every scalar write takes — a direct table
write in the page would be a second seam that looks identical and announces nothing.

---

## Merging a stored profile forward

AceDB's defaults merge fills keys of tables it knows about. It does **not** know that
`profile.windows[3]` is supposed to look like `WINDOW_TEMPLATE`, because it cannot reach inside an
array. So the per-window merge is ours, in `Database.EnsureWindowShape` → `fillMissing`.

### The `== nil` rule

```lua
for k, v in pairs(template) do
    if stored[k] == nil then
        stored[k] = copy(v)
    elseif type(v) == "table" and type(stored[k]) == "table" and v[1] == nil then
        fillMissing(stored[k], v)
    end
end
```

The presence test is `stored[k] == nil`. **It is never `stored[k] or template[k]`.**

`or` cannot tell *unset* from a stored `false`, `""` or `0`, and this profile is full of exactly
those values — `frame.locked = false`, `header.title = ""`, `rows.maxRows = 0`,
`bars.border = false`, `icons.showIcon = false`, `visibility.world = false`. An `or` merge would
silently reset a user's deliberate "off" back to the shipped "on" on every single login, and would
do it invisibly, because the setting they turned off would simply be on again.

The same rule appears in `core/CoreSetup.lua`'s `fallbackRGBA` (a stored channel of `0` survives as
`0`) and in `settings/Schema.lua`'s session-row read. It is one rule, applied everywhere a stored
value can legitimately be falsy.

### Arrays are left alone

The recursion guard is `v[1] == nil` — recurse into **keyed** sub-tables only. `columns` is an
ordered list the user edits, and key-filling it against the template would re-add columns they
removed. An **absent** `columns` array is a broken profile rather than an older one, and gets an
empty table so the window still renders.

`fillMissing` is idempotent and shape-driven, so it is safe to run on every login, every profile
swap, and after every `CopyFrom` and `Duplicate` — which is exactly where
`modules/WindowManager.lua` calls it.

---

## Profile lifecycle

`core/Database.lua` registers one callback for all three AceDB profile events:

```lua
db.RegisterCallback(Database, "OnProfileChanged", "OnProfileChanged")
db.RegisterCallback(Database, "OnProfileCopied",  "OnProfileChanged")
db.RegisterCallback(Database, "OnProfileReset",   "OnProfileChanged")
```

Each one runs `NS:RunMigrations()` (the newly-active profile may be a copy authored at an older
version, or a reset back to an empty registry), clears `NS.State.activeWindowId`, wipes every
session cache, and fires **one** `PROFILE_CHANGED` message. `fireProfileChanged` is the single
emitter — every path that makes the active profile a different thing routes through it, so the bus
catalog names one site and stays true.

`AceDB:New("MultiMetersDB", NS.defaults, true)` passes `true` as the third argument, which AceDB
expands to the shared `"Default"` profile. Omitting it falls back to a **per-character** profile,
which contradicts the documentation and is the source of every "each new character lands on its own
settings" report in the collection. Players who want per-character opt in through the Profiles page.

---

## Adding to the schema

The full recipe, with the gotchas, is in [common-tasks.md](common-tasks.md#add-a-setting). The short
version: one row in `settings/Schema.lua`, one matching default in `defaults/Profile.lua` at the same
path (relative to `WINDOW_TEMPLATE` for a `window.` row), the label and desc in `locales/enUS.lua`,
and nothing else — `/mm get|set|list|reset`, the page widget, the per-page Defaults button and
`/mm resetall` all follow. Then run `lua tests/run.lua`, which asserts `NS.ValidateSchema() == 0`.
