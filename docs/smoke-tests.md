# Smoke tests

Manual, in-client checks for **Ka0s Mythic Meters**. Run before claiming a non-trivial change works,
before tagging a release, and after refreshing `libs/` or bumping `## Interface:`.

This file covers what the headless suite **cannot**. `lua tests/run.lua` loads every source file
under a mocked client and proves the logic: the schema resolves, the GUID join works, the sort ladder
falls through, the secret guards fire on mock secrets. What it cannot do is run inside a real client
with the real `C_DamageMeter`, real secret values, and the real `Combat` addon restriction — and
**that is where this addon's entire risk surface lives.** Everything in §8 through §11 exists because
a mock cannot fail the way a Mythic+ pull can.

Companion docs: [testing.md](testing.md) for the headless harness,
[ARCHITECTURE.md](ARCHITECTURE.md) for the secret-value rules referenced throughout.

## Conventions

- **`/reload`** abbreviates `/console reloadui`.
- **BugSack / BugGrabber** (or the stock Lua error frame) is the primary regression signal. A clean
  run is **"no errors thrown at any point"** — and in this addon the errors that matter arrive
  *four times a second, mid-pull*, so a single one is a hard fail even if the window looks right.
- **Chat banner.** Every line the addon prints starts with a cyan `[MM]`. A doubled `[MM][MM]`
  banner, or any line missing it, is a bug (`core/MythicMeters.lua` reclaims `NS.Print` from
  AceConsole immediately after `NewAddon` — a green line with a trailing colon means the reclaim
  broke).
- **"Restricted"** below means the `Combat` addon restriction is **active**, which is when meter
  numbers arrive as secret values. It keys off **combat, not Mythic+** — between packs in a key the
  values are fully readable. So "in a key" and "restricted" are not the same state, and several
  checks below depend on the difference.
- **"A pull"** means a real one: a trash pack in a Mythic+ dungeon, with the group actually fighting.
  A target dummy is **not** a substitute for the restricted-path checks — dummies do not activate the
  addon restriction.
- **Pass** lines describe what success looks like. If a step says "should X" and X does not happen,
  the smoke test failed.

## Suite

| # | Area | Scenario |
|---|---|---|
| 1 | Cold start | [Fresh install + first login](#1-fresh-install--first-login) |
| 2 | Reload | [`/reload` integrity](#2-reload-integrity) |
| 3 | Window handling | [Lock, drag, resize, preview](#3-lock-drag-resize-preview) |
| 4 | Settings panel | [Page sweep and panel/CLI parity](#4-settings-panel-sweep) |
| 5 | Columns | [Column editor](#5-column-editor) |
| 6 | Multi-window | [Second window, copy settings, independence](#6-multi-window) |
| 7 | Visibility | [Context matrix](#7-visibility-matrix) |
| 8 | **Secret values** | [**Mythic+ pull — the secret-value path**](#8-mythic-pull--the-secret-value-path) |
| 9 | **Sorting** | [**Live ranking mid-pull, and identity ambiguity**](#9-live-ranking-mid-pull-and-identity-ambiguity) |
| 10 | **Interaction** | [**Tooltips, drill-down and death recap mid-pull**](#10-tooltips-drill-down-and-death-recap-mid-pull) |
| 11 | **Unverified assumption** | [**Does `combatSources` arrive pre-sorted?**](#11-verify-the-unverified-assumption-provider-order) |
| 12 | Pets | [Pet attribution](#12-pet-attribution) |
| 13 | Degradation | [Meter-unavailable prompt](#13-meter-unavailable-prompt) |
| 14 | Slash | [Slash surface](#14-slash-surface) |
| 15 | Profiles | [Profiles](#15-profiles) |
| 16 | Resets | [Resets](#16-resets) |
| 17 | Degraded install | [LibKa0s absent](#17-libka0s-absent) |
| 18 | Diagnostics | [Debug console and perf capture](#18-debug-console-and-perf-capture) |
| 19 | **Number rendering** | [**Abbreviation actually reaches the cells**](#19-abbreviation-actually-reaches-the-cells) |
| 20 | Names | [Realm strip and truncation](#20-realm-strip-and-truncation) |
| 21 | **Segments** | [**The header segment selector**](#21-the-header-segment-selector) |
| 22 | Migration | [v1 → v2 uniform column widths](#22-v1--v2-uniform-column-widths) |
| 23 | Tooltip styling | [Tooltip appearance, anchor and offsets](#23-tooltip-appearance-anchor-and-offsets) |
| 24 | **Targets** | [**The Targets section, and its absence mid-pull**](#24-the-targets-section-and-its-absence-mid-pull) |
| 25 | **Export** | [**The export modal, the CSV and the chat dump**](#25-the-export-modal-the-csv-and-the-chat-dump) |

---

### 1. Fresh install + first login

**Setup.** Quit WoW. Delete `WTF/Account/<ACCOUNT>/SavedVariables/MythicMeters.lua` (and the `.bak`).
Confirm the addon is enabled in the character-select AddOns list as **Ka0s Mythic Meters**.

**Steps.** Log in. Run `/mm`. Open Settings → AddOns.

**Pass.**
- Login completes with no Lua errors.
- Exactly **one** window exists, named "Meter", centered on screen (`Database.SeedWindows` seeds
  one).
- It shows the six default columns left to right after the name column: **Damage · Healing ·
  Interrupts · Dispels · Avoidable Damage · Deaths**.
- Standing solo in the open world the window is **hidden** — `visibility.world` ships `false` and
  `hideWhenSolo` ships `true`.
- `/mm` prints the help index. Every row carries the cyan `[MM]` banner; verb names are yellow.
- Settings → AddOns shows a **Ka0s Mythic Meters** parent with **thirteen** subcategories in this
  order: Windows · Frame · Header · Rows · Bars · Text · Icons · Tooltip · Visibility · Columns ·
  Data · General · Profiles.
- **No `schema error:` line and no "schema path does not resolve" line appears at any point.**
  `NS.ValidateSchema` runs from the options descriptor at panel creation; a line here means a schema
  row's path does not resolve against `defaults/Profile.lua`, or its default disagrees with the tree.
- After `/reload`, `MythicMetersDB` exists on disk with `profileKeys`, `profiles.Default`,
  `global.schemaVersion = 1`, a one-entry `profile.windows` array whose window has `id = 1`, and
  `profile.nextWindowId = 2`.

### 2. `/reload` integrity

**Steps.** Move the window, resize it, change a bar color and a column width. `/reload`.

**Pass.** Position, size, color and width all survive. No errors during load. The window re-appears
in the same visibility state it was in. `nextWindowId` has not moved (a reload creates no windows).

**Also.** Take a `/reload` **during** a pull, with the restriction active. The addon must come back
without errors — `NS:OnEnable` seeds `NS.State.restricted` from `Secrets.IsRestricted()` rather than
assuming "inactive", because `ADDON_RESTRICTION_STATE_CHANGED` has already fired and there is no
second edge to catch.

### 3. Lock, drag, resize, preview

**Steps.**
- `/mm lock off` (or uncheck **Frame → Lock window**).
- Drag the window by its body. Drag the bottom-right grip.
- `/mm lock on`. Try to drag again.
- `/mm preview` on and off.

**Pass.**
- Unlocking **fills the window with placeholder rows** — ten Ka0s-named members with plausible,
  **non-jittering** numbers. The numbers are deterministic; a preview that changes every refresh is
  unusable for judging column widths, which is the job it exists for.
- Unlocking implies preview: the two are coupled in `WindowManager:SetLocked`, and the General page's
  Preview mode checkbox agrees with the lock state.
- Dragging moves the window; the position persists across `/reload`.
- The resize grip is visible only while unlocked, and resizing persists.
- **Locked**, the window does not drag, and hovering a cell produces a tooltip (locked hands the
  mouse to the cells). **Unlocked**, the whole window drags as one object and cells do not respond.
- `/mm reset-positions` re-centers every window and prints how many moved.

### 4. Settings panel sweep

**Steps.** Open every one of the thirteen pages. On each, move one control of each type present
(checkbox, slider, dropdown, color, edit box) and watch the window.

**Pass.**
- Every page draws on **first show** with correctly sized widgets — nothing squashed into a
  zero-width column, and every widget carries the same skin as the rest of your AceGUI addons. (Both
  symptoms are the lazy-build rules failing; see
  [settings-panel.md](settings-panel.md#eager-category-lazy-body-lazy-defaults-button).)
- Every change applies **immediately** to the window, without a `/reload`.
- Ten pages carry a **Defaults** button in the header; **Windows, Columns and Profiles do not.**
  The Settings window's own footer Defaults control works on the same ten.
- **Panel ↔ CLI parity.** With a page open, run `/mm set window.frame.width 640`. The Frame page's
  Width slider moves to 640 **without being reopened** (`RefreshScalars`). Conversely, move a slider
  and `/mm get window.frame.width` reports the new value.
- `/mm list` groups every setting under the same page keys the panel uses.
- **Combat refusal.** Enter combat (a dummy is fine here). `/mm config` **refuses** and prints one
  gray notice. It must **not** queue the request and open the panel when combat ends.
- **Profiles page mid-combat.** With the Settings window closed, enter combat, then open Settings →
  AddOns → Ka0s Mythic Meters → **Profiles** from the Blizzard sidebar. The page must close the
  Settings window and print the refusal — that route bypasses `/mm config` entirely, which is why the
  page carries its own guard.

### 5. Column editor

**Steps.** Out of combat, on the Columns page: add **Absorbs**; move it left twice; widen it; turn
its bar off; remove it. Then try to add a stat already shown.

**Pass.**
- Each edit repaints the window immediately and repaints the page (the page's shape changed).
- The width slider commits **on release**, not while dragging — the slider must not tear out from
  under the cursor.
- The Add picker offers only stats not already shown; when every stat is shown it says so instead of
  offering an empty dropdown.
- A column's own stat dropdown lists the stat that column already shows (or it would open with
  nothing selected).
- **Remove** is disabled when only one column remains, and attempting it anyway prints "A window must
  keep at least one column."
- Turning a bar off leaves the column's **text** — the column still reads, it just stops competing
  for attention.

**Combat refusal.** Leave the Columns page **open**, then pull. Click Add / Remove / Move.

**Pass.** Every mutation is refused with "Columns cannot be changed during combat." — printed, not
silent. **No Lua error.** This is the case the library's render-time refusal does not cover: a panel
left open when a pull starts is still clickable, and rebuilding cells that are holding secret values
is precisely what must not happen.

### 6. Multi-window

**Steps.**
1. Windows page → **New window**. Confirm the picker follows the new window.
2. Give the two windows visibly different settings — different width, bar color, column set, sort
   column.
3. Change a setting on window 2 and confirm window 1 does **not** move.
4. Windows page → **Copy settings from** → source = window 1, group = **Bars** → Copy.
5. Repeat with group = **Everything**.
6. **Duplicate window**, then **Delete** one.

**Pass.**
- Both windows draw independently, each with its own columns, sorting and refresh interval.
- Editing one changes only that one. **This is the aliasing check**: if changing window 2's bar color
  changes window 1's, two windows are sharing a sub-table and `deepcopy` has been bypassed somewhere.
- Copying **Bars** copies the bar settings and nothing else — width, columns, position and visibility
  rules on the target are untouched.
- Copying **Everything** copies all ten groups but **not** the target's `id`, `name` or **position** —
  the copy must not land exactly on top of its source.
- Duplicate offsets the new window by 24px down-right, so it is visibly a second window.
- The window picker is keyed by id: two windows both named "Meter" are still individually selectable.
- **Delete** confirms first, and the **last** window cannot be deleted ("The last window cannot be
  deleted.").
- After deleting the window the picker was pointed at, every settings page re-renders against the
  first surviving window rather than showing empty widgets.
- `/mm window list` lists both, with shown/hidden state and column count. `/mm window new`,
  `delete`, `copy <source> <target>` do the same things the panel does.

### 7. Visibility matrix

**Steps.** With the shipped rules (dungeon / raid / arena / battleground on, world off,
hide-when-solo on, hide-in-vehicle on), visit: solo open world · grouped open world · a five-player
dungeon · a raid · a battleground · a vehicle (a quest turret or a Mythic+ dungeon vehicle
encounter).

**Pass.**
- Solo open world → hidden. Grouped open world → still hidden (world is off).
- Turn **Open world** on: grouped open world shows, solo still hides (`hideWhenSolo` is layered on
  top of a context that already said yes).
- Dungeon / raid / battleground → shown.
- Entering a vehicle hides the window; leaving shows it again. This one may take up to one refresh
  interval (0.25s default) because no bus message announces a vehicle transition — the predicate is
  read live rather than cached, which is why it is right at all.
- **Master enable off** (`/mm set enabled false`, or General → Enable Mythic Meters) hides every
  window immediately and stops the addon reading the meter at all.
- **Preview mode overrides context**: with preview on, the window shows wherever you are standing.

### 8. Mythic+ pull — the secret-value path

**This is the most important test in the file.** Everything else can be checked at a target dummy;
this cannot. Secret values only arrive when the `Combat` addon restriction is active, and every
inspection that is illegal on one raises an immediate Lua error — four times a second, in the middle
of a pull, where nobody can see it until BugSack fills up.

**Setup.** A real Mythic+ dungeon, a real group, BugSack (or the stock error frame) enabled and
**cleared**. Window locked, `sortMode = "value"` (the default), all six default columns.

**Steps.**
1. Zone in. Confirm the window appears and shows rows for the whole group between packs.
2. Pull a trash pack and fight it through to the end. **Do not touch anything** — just watch.
3. Repeat for at least three packs and one boss.
4. Check the error frame after every pull.

**Pass — and each of these is a separate failure mode:**

- **No Lua error of any kind.** The specific ones to watch for read like
  *"attempt to compare two secret values"*, *"attempt to perform arithmetic on a secret value"*,
  *"attempt to use a secret value as a table index"*, *"attempt to get length of a secret value"*, or
  a `table.concat` error. Any of them means a value was inspected outside `core/Secrets.lua`.
- **Bars move.** Every cell's `StatusBar` fills and drains as the fight progresses. A bar frozen at
  zero for the whole pull means `SetValue` is being handed something it should not be, or
  `maxAmount` never arrived.
- **Text renders, and it is abbreviated.** Damage reads `12.4M`, not `12400000` and not `<secret>`.
  `<secret>` in a cell means the `NumericRuleFormatter` was unreachable and the addon fell all the
  way to its third degradation rung — honest, but it means `C_StringUtil` is missing or the formatter
  cache is broken.
- **Names and class colors are correct throughout.** `classFilename` and `specIconID` are
  `NeverSecret`, so the name column must render in full even at the height of a pull. A row whose
  name goes blank mid-pull is the `ConditionalSecret` `name` field being handled wrong — the class
  icon and the bar should carry the identity instead, and the row must still draw.
- **The header renders in combat**: session name ("Current"), duration ticking as `m:ss`, and the
  group total for the sort column. All three are built from secret values and folded together with
  `..` — a `table.concat` here would be a Lua error on every refresh, so a header that goes blank or
  errors is this exact bug.
- **Percent slots, if you configured any, go empty in combat.** That is correct and by design: a
  percentage is a division, and an empty slot means "cannot be known right now", never "zero
  percent". Set `text.leftSlot = "percent"` for one pull and confirm the slot empties on pull and
  refills between packs.
- **The refresh is smooth, not frantic.** With `data.throttle = 0.25` the grid updates roughly four
  times a second regardless of how fast the game reports. If it visibly stutters or the client
  hitches at the start of a big pull, capture it (§18) rather than guessing.
- **THE GRID IS NOT EMPTY.** A window reading *"Waiting for combat data…"* for a whole pull with a
  live session behind it is the bug this section exists for: `sourceGUID` is `SecretWhenInCombat`, and
  any code that keys, compares or looks one up mid-pull drops every source silently. `/mm debug on`
  and a `dropped=` count equal to the group size is the signature.
- **Between packs, everything comes back**: percentages return, secondary cells that were blanked for
  ambiguity fill in, pets fold per `mergePets`, and the gray `restricted` note disappears.

**Record for the report:** dungeon and key level, group composition, number of packs, and whether the
error frame stayed empty. "No errors" from a five-minute dummy session is not evidence for this test.

### 9. Live ranking mid-pull, and identity ambiguity

**Setup.** As §8, `sortMode = "value"`, `sortColumn = "DamageDone"`. Run it once in a group where
every player has a different specialization, and once in a group containing **two players of the same
class AND spec** — that second run is the whole point of this case.

**Steps.**
1. Between packs, note the row order top to bottom.
2. Pull. Watch the order, and watch the columns other than Damage, for the whole fight.
3. Kill the pack. Watch again.

**Pass.**
- **Rows keep coming, and they re-rank live.** `sourceGUID` is secret for the whole of a pull, so the
  grid is built by identity correlation and its order is the game's own ranking of the sort column.
  Someone overtaking someone else moves up *during* the fight.
- **The header says `restricted`** in gray. The grid is built a different way and the player is owed
  the reason a cell can be blank.
- **Every row is present**, including pets — which appear as their own rows mid-pull whatever
  `mergePets` says, because folding needs an owner link the GUID would have provided.
- **With two players of one class and spec**: their Damage figures are still right (that column comes
  off the row itself), and their **other columns are empty**. The header reads
  `restricted — some rows cannot be told apart`. An empty cell here is the correct answer: the addon
  cannot prove which of the two a secondary figure belongs to, and will not guess.
- **After the pull everything fills in** on the next refresh — exact GUID correlation, all columns,
  pets folded per `mergePets` — and the gray note disappears.
- Switch `sortMode` to **`roster`** and repeat: out of combat the order is group order (you first),
  then role, then name. In combat the ranking is the engine's, as above — `roster` mode needs GUIDs
  to place a row and cannot run while they are secret.
- Switch to **`provider`** and repeat: out of combat the order follows the game's own, which is what
  identity mode uses in combat too, so this mode looks the same on both sides of a pull.
- **Click a stat header mid-pull.** The grid re-ranks to the engine's ordering for *that* stat, and
  the arrow moves with it. Clicking the same header again **reverses** the grid. Neither prints
  anything — nothing was refused.
- **Click the Player header mid-pull.** This is the one refusal left: nothing moves, and
  *"Sorting is not possible while the game restricts combat data."* is printed. A click that went
  quiet would read as a broken button.
- **With `sortMode = "name"` when a pull starts**, the arrow leaves the Player header and appears on
  the sort column, because that is the order the rows are actually in. An arrow left on Player would
  be the grid stating something untrue.

### 10. Tooltips, drill-down and death recap mid-pull

There is deliberately **no** combat gate on any of this. These are unprotected frames, and the moment
a raider most wants to know what killed them is the moment they are still fighting.

**Steps, all performed during a pull with the window locked:**
1. Hover a **Damage** cell.
2. Hover the **name** cell.
3. Click a Damage cell; then **right-click any row** to leave; then click the same cell twice.
4. Hover a **Deaths** cell on a row for someone who has died, then click it; hover a death
   row in the list that opens, then click that.
5. Move the mouse off the window.

**Pass.**
- **Cell tooltip** lists the spells behind that number, with icons, capped at `tooltip.maxSpells`
  (10 by default), and an *"and N more"* line when there are more. The count comes from
  `Secrets.SafeCount`, which never applies `#` — so an "and N more" line that is present and correct
  mid-pull is itself evidence the safe walk is working.
- Out of combat the spell list is **biggest first**. In combat it is in the game's own order — the
  sort is attempted only when comparison is legal, and it refuses **as a whole** rather than
  partially. A partial sort would raise *"invalid order function for sorting"*.
- Hovering an **Avoidable Damage** cell adds the "Avoidable" / "Deadly" tags and an Overkill line
  where present. Those flags may be **secret booleans**; a Lua error here means one was truth-tested
  directly.
- **Name tooltip** lists **every** tracked statistic for that player, including the ones this window
  is not showing — the extras dimmed gray. That cross-column read is the reason the addon exists.
- **Drill-down**: clicking a cell replaces the grid with that player's spell breakdown, styled
  identically (same fonts, bars, row height — it is the same renderer), with the header reading
  `<player> - <stat>`. Clicking the same cell again returns to the grid, and so does a **right-click
  on any row** — there is no Back button, deliberately: it cost a row of height on every drilled
  window and pushed the last row out through the bottom of the frame.
- **Every row of a breakdown is a spell, so the whole row shows the SPELL's tooltip** — the client's
  own, not this addon's. Hovering the name cell must show it too. A tooltip reading "No data yet" or
  a column of zeroed statistics means a drill row reached one of the player tooltips. It must appear
  over the MIDDLE of a cell, not only in the seams between columns: the tooltip belongs to the row
  frame, and a tooltip that shows in a seam and nowhere else means the cells have taken their mouse
  back. The row must highlight there too — the cells drive that on the grid and cannot here. With
  `/mm debug` on, one `[Tooltip] row spell=<id>` line per row entered says the handler ran at all.
- **A left-click inside a SPELL breakdown does nothing at all.** It used to ask the provider for a
  breakdown of a spell and render an empty window. A left-click inside a DEATH list is different —
  see the death-recap block below.
- **The mouse wheel scrolls both the grid and a breakdown** when there are more rows than fit. It
  stops at both ends, survives the refresh tick rather than snapping back, and resets to the top when
  you enter or leave a breakdown. Shrink the window until rows are hidden to test it.
- The drill-down **does not reshuffle** while you watch it, in or out of combat.
- **Settings → Text → Death timestamps** offers three styles, and the Deaths cell tooltip and the
  death list must agree on whichever is picked — the first is the index into the second, and two
  labellings would make one list look like two. **Time into the fight** is the meter's own offset
  into the segment the window is showing, so it reads as time into the run in a key and time into the
  fight in the open world; on **Overall** the client reports `-1` for every death, so the figure is
  looked up on the **Current** session instead and joined on the recap id. Check this one on an
  Overall window specifically: that is the case it was reported broken in, and "time into the fight"
  reading identically to "time of day" there means the lookup is not firing. Mid-pull it does fall
  back to the clock, because both the id and the offset are secret then. **After the run, out of the
  dungeon**, the client offers nothing at all — Current is empty and Overall reports `-1` — so the
  figure comes from an anchor this addon stamps at the meter reset. A `/reload` mid-run moves that
  anchor, and deaths before it correctly show the wall clock instead of a negative offset.
- **Deaths cell tooltip**: it lists **that player's deaths, one line each, newest first**, each
  labelled `Death N` with the wall-clock time in the right-hand column. It must NOT say "Spell
  breakdown" and must NOT say "No data yet" — a Deaths source carries no spell list, and running the
  spell path there is the dead end this feature replaced. The list is the index into the drill-down:
  hover then click, and the same deaths appear in the same order.
- **Deaths cell**: clicking it opens a **list of that player's deaths** — one row each, the name
  column reading `Death 1`, `Death 2`… numbered chronologically so a newest-first list counts *down*,
  and the Deaths cell carrying the **wall-clock time** of that death with a full bar behind it. A
  time reading `—` means the client no longer holds that recap; the row must still be there, because
  the count in the cell it came from says a death happened.
- **The number of rows in that list must equal the number in the cell you clicked.** They are two
  independent tallies of one fact, in two separate builds, and disagreeing is the failure this whole
  surface must not have. Check it both in and out of combat: the identity build runs mid-pull.
- **The death tooltip is laid out like every other one** — header, a paragraph gap, a caption, then
  the bars. A header sitting flush against the first bar means the section gap is missing, and on a
  live client it also means a bar carrier is on tooltip line 1, which permanently restyles the title
  of every GameTooltip in the game until `/reload`.
- **Hovering a death row** lists what killed them — one line per incoming hit, **oldest first**, in
  four columns: seconds before death, spell, attacker, damage taken, and the HP percentage
  remaining. The columns must line up down the whole tooltip; a long spell or caster name is clipped
  into its column rather than pushing the numbers off the edge, and it must never wrap onto a second
  line. A **melee swing** reads as `Melee` with the weapon icon — it carries no spell id at all, and
  `#?` there means the fallback is broken. The bar behind each line is **HP remaining**,
  not damage, so it empties as you read down. The last line is the killing blow and carries an
  overkill clause. An event with `hideCaster` shows no parentheses at all — never an empty `()`.
- **Mid-pull the bars must still draw.** The percentage text may vanish (a percentage is a division,
  and dividing a secret is illegal) but the bar is the widget dividing natively and is unaffected. A
  measured capture showed these fields arriving *plain* in combat, so in practice the percentages
  stay — but a build where they disappear and the bars remain is correct, and a Lua error here means
  something computed the ratio in Lua.
- **Clicking a death row opens Blizzard's own Death Recap** for that exact death — not the newest
  one. Verify with a player who died more than once: the frame's contents must match the row you
  clicked. The list must stay open behind it; returning to the grid would lose your place.
- **A hunter's Feign Death must not appear as a death**, in the count or in the list. Out of combat
  only — see Known limitations: the filter joins a plain GUID against `sourceGUID`, which is secret
  for the whole of a pull, so mid-pull a feign IS counted and the number corrects itself when combat
  ends. Feign, leave combat, check the count; then feign, actually die, and confirm the real death is
  still counted.
- If the client has no `C_DeathRecap` at all, the Deaths click must fall back to **Blizzard's frame**
  and then to the ordinary breakdown — the cell is never dead. (`deathRecapID` is `NeverSecret`,
  which is the only reason any of this can be a click action at all.)
- Moving the mouse off the window **always** hides the tooltip. A tooltip left pinned under the
  cursor is the single most reported meter bug there is.
- Set **Tooltip → Hide tooltips in combat** and repeat step 1 during a pull: no tooltip appears, and
  one **does** appear the moment you drop combat. The test behind it is
  `UnitAffectingCombat("player")`, so the transition should track the player leaving combat, not the
  lockdown edge.

### 11. Verify the unverified assumption (provider order)

**The addon ships with one assumption it has not been able to prove, and this test is how it gets
proven or corrected.**

`modules/Provider.lua` returns `sources` in exactly the order `C_DamageMeter` handed back
`combatSources`, and `sortMode = "provider"` treats that order as *"sorted by the requested stat,
descending"*. **Nothing in Blizzard's documentation says that.** It is an inference from how the
built-in meter displays.

Only `provider` mode depends on it. `value` mode orders by the values themselves whenever comparison
is legal, and `roster` mode orders by group position — neither cares. And **if the assumption is
false, the correction is confined to `modules/Provider.lua`**: a sort inside `GetColumn`, legal out
of combat, which is the only time `value` mode would have needed it anyway. No other file changes.

**The addon now measures it for you.** Out of combat the amounts are plain and `<` is legal, so
`/mm debug diag` walks each column in the order the API returned it and prints a verdict per stat:

```
-- provider order --
  DamageDone             5 sources - ranked, descending
  HealingDone            5 sources - NOT ranked, breaks at index 3
  Interrupts             1 sources - nothing to check
```

`NOT ranked` disproves the assumption outright and names the position where the order broke. Inside a
pull every line reads `cannot be checked` — the values are secret and the probe refuses rather than
finding no break it was never able to look for. **Run the probe first; the manual comparison below is
what confirms its verdict against a second meter.**

**Procedure.**

0. Out of combat, after at least one pull: `/mm debug diag`, and read the **provider order** section.
   If any stat says `NOT ranked`, paste that section into issue #14 — that is the deliverable, and
   the steps below are then confirmation rather than discovery.
1. In a Mythic+ dungeon or a raid, with a full group and at least one completed pull, stand **out of
   combat**.
2. Set the window to `sortMode = "provider"` and `sortColumn = "DamageDone"`:
   ```
   /mm set window.data.sortMode provider
   /mm set window.data.sortColumn DamageDone
   ```
3. On the **Data** page, set **Session** to **Overall** so both meters are describing the same span.
   (Current — the live pull — is the shipped default; Overall is the accumulated run. The stored
   value is an `Enum.DamageMeterSessionType` number, so prefer the dropdown to
   `/mm set window.data.sessionType 0`.)
4. Open **Blizzard's built-in damage meter** and put it on **Damage done**, same session scope.
5. Compare the two lists **top to bottom, by name**, and write both orders down.
6. Repeat for **Healing** (`/mm set window.data.sortColumn HealingDone`) and for a counting stat —
   **Interrupts** is the sharpest test, because ties are common and a stable tie-break is exactly
   where an order assumption breaks.
7. Repeat once **during** a pull, with the restriction active, comparing the order the addon holds
   against Blizzard's live window.

**Pass.** The addon's row order matches Blizzard's, for each stat, out of combat and in.

**If it does not match, report:**
- the stat key, the dungeon/raid and the session type;
- the addon's order and Blizzard's order, both by name;
- whether the mismatch was out of combat, in combat, or both;
- whether the addon's order looked like *any* consistent order (first-seen, GUID, roster) or like
  none.

That report is the whole deliverable. The fix lands in `modules/Provider.lua` and in the header
comment there that records the assumption, and in design §5 — nowhere else.

### 12. Pet attribution

**Setup.** Bring a **hunter** and a **warlock** (a shadow priest's Mindbender, a mage's water
elemental and a shaman's elementals are also good, and are the cases the unit-frame pet map does
*not* cover).

**Steps.** Complete a pull, then check the grid **out of combat**.

**Pass.**
- **An unowned ally has its own row, under its own name.** A guardian, a totem or a pet whose owner
  the unit API never saw is shown rather than dropped — it names itself, so nothing is being
  attributed to the wrong player.
- **A delve companion has a row.** Run a delve and check the grid afterwards: Valeera (or whichever
  companion came along) must appear with her own name, class color and figures. She is filed under
  `None` rather than `Ally`, and is admitted on her class filename. Cross-check the total against
  another meter — the row's figure plus yours should equal the header total.
- **No ENEMY ever gets a row.** This is the half that can go badly wrong: `None` is admitted when the
  source carries a real player class, so a mob flagged `None` with a class filename is the one thing
  that could put trash on the grid. If a mob's name appears as a row, stop and report it — and run
  `/mm debug diag`, whose targets section prints the enemy column's display types for exactly this.
- **Out of combat, pet damage folds into the owner.** Compare the hunter's Damage figure against
  Blizzard's own meter, which also attributes pet damage to the owner. They should agree.
- **In combat the owner's number is low by whatever the pet contributed**, and that is correct
  behavior rather than a bug. Adding a pet's damage to its owner's is arithmetic on two secret
  values, and there is no native escape hatch for summing the way there is for formatting. Confirm
  the number **catches up** the moment combat ends.
- **No Lua error at the transition** in either direction.
- With `/mm debug on`, the aggregator's one-line-per-pass log reports `dropped=` and `unfolded=`
  counts. A large `dropped=` out of combat means the owner map missed something worth naming in a
  report; `unfolded=` in combat is expected and is the fold being refused rather than approximated.

**Also worth checking:** a hunter who dismisses and re-summons mid-dungeon, and a warlock who swaps
demons. The owner map is rebuilt lazily on the next read after `GROUP_ROSTER_UPDATE`, so a swap
should correct itself within one refresh.

### 13. Meter-unavailable prompt

**Setup.** Disable Blizzard's built-in damage meter (the client's own meter setting / CVar).

**Steps.** `/reload`. Look at the window.

**Pass.**
- The window **explains itself** in place of rows:
  - *"Blizzard's damage meter is not available."*
  - *"Mythic Meters reads every number from the game's built-in damage meter. Enable it to see data
    here."*
  - and, in gray, *"Reason: …"* — **Blizzard's own `failureReason`, quoted verbatim**. It is not
    translated and not second-guessed: the game knows why its meter is off, and guessing on its
    behalf is how an addon tells a player to enable something that was never the problem.
- **No Lua error**, and no empty window with no explanation.
- Re-enable the meter. Within a few seconds (or after a zone change / meter event, which invalidates
  the memoized availability answer) the rows come back **without a `/reload`**.

**The other empty state.** With the meter **enabled** but no combat data yet — fresh login, or right
after `/mm` → Data → **Reset meter data** — the window shows *"Waiting for combat data…"* instead.
These two messages must not be confused: one means "the meter is off", the other means "the meter is
on and there is nothing in it yet", which is the normal state between pulls.

**Reset meter data.** From the Data page, click it and confirm the popup. Blizzard's **own** meter
window empties too — the call is `C_DamageMeter.ResetAllCombatSessions` and it is account-wide, which
is why the popup exists. Every open drill-down closes and this module's caches are dropped.

### 14. Slash surface

**Steps.** Run each verb.

```
/mm                          /mm help              /mm config
/mm list                     /mm version
/mm get window.frame.width   /mm set window.frame.width 520
/mm reset window.frame.width /mm resetall
/mm lock            /mm lock off        /mm preview        /mm preview on
/mm toggle          /mm toggle Meter
/mm window list     /mm window new Raid /mm window copy Meter Raid
/mm window delete Raid
/mm reset-positions
/mm debug           /mm debug on        /mm debug off
/mm perf            /mm perf help
/mythicmeters help
```

**Pass.**
- Every verb answers; none errors; unknown verbs print "unknown command" followed by the help index.
- `/mm help` and the settings **landing page** list the **same** commands — the panel generates its
  list from `NS.COMMANDS` through the same formatter, so a divergence means someone wrote a second
  list.
- `/mm version` matches the TOC's `## Version` line (it reads the manifest, not a constant).
- `/mm set window.frame.width 520` moves the **active** window — the one the picker is on — and
  `/mm get` reads it back. With two windows, select the other in the picker and confirm the same
  command now targets the other one **with no change to the path typed**.
- `/mm set window.columns.2.width 90` is **refused** with a message pointing at the Columns page. A
  single column is not addressable by ordinal, because the ordinal moves on the next edit.
- `/mm set window.frame.scale 5` is refused (validator: 0.5–2.0). `/mm set nonsense.path 1` is
  refused with "Setting not found".
- `/mm toggle` with no name flips every window; with a name it flips one, and the name keeps its case
  and spacing.
- `/mm lock` with no argument **toggles**; `/mm lock off` sets. Unlocking prints "unlocked — drag
  them into place" and turns preview on.
- `/mm debug` toggles the console **window**; `/mm debug on|off` sets the logging **flag**. They are
  separate on purpose: logging runs with the console closed so a bug can be reproduced first and the
  log read afterwards.

### 15. Profiles

**Steps.** Profiles page → create "Test" → switch to it → change several settings and add a window →
switch back to Default → copy from Test → reset.

**Pass.**
- Switching profiles rebuilds every window immediately: the previous profile's windows are gone and
  the new profile's are drawn, positioned and populated.
- The settings panel re-renders against the new profile's windows; the picker lists them.
- A profile with a different **number** of windows works in both directions.
- Copying a profile brings its windows across, and editing one profile's window afterwards does not
  touch the other's.
- Resetting a profile re-seeds exactly one window.
- **A fresh character lands on the shared `Default` profile**, not on its own. (`AceDB:New(..., true)`
  — omitting that third argument silently gives per-character profiles, which is the source of every
  "each new character has its own settings" report in the collection.)
- No Lua errors, and no stale window left on screen after a switch.

### 16. Resets

| Control | Expected scope |
|---|---|
| A page's **Defaults** button | every schema row on **that page**, for the **active window** |
| General → **Reset all settings** (confirms) | every row on every page, for every window, in the active profile — **plus every window position** |
| `/mm resetall` | identical to the above; it is the same implementation |
| `/mm reset <path>` | that one row |
| Frame → **Reset position** | the active window only, back to center |
| `/mm reset-positions` | every window back to center |

**Pass.**
- **Profiles are never touched** by any reset. Create a second profile first, then run
  `/mm resetall`, then confirm the second profile still exists and is unchanged. This is enforced in
  two places on purpose.
- "Reset all settings" **does** move every window back to center. Positions are not schema rows, so
  they are reset by a separate hook — without it, "reset everything" would leave every window exactly
  where it was.
- After `/mm resetall` the column list is back to the six shipped columns, in catalog order.

### 17. LibKa0s absent

**Setup.** Rename `libs/LibKa0s` to `libs/LibKa0s_off` (or delete it from a copy of the install).
`/reload`.

**Pass.**
- **The addon still loads and the window still draws rows.** This is the point: a missing vendored
  library degrades, it does not break the addon.
- One honest chat line names the cause, once, on the first line the addon prints — the shared clause
  *"The LibKa0s library is missing from this installation of Ka0s Mythic Meters (expected in
  libs/LibKa0s)"* — followed by what is unavailable.
- `/mm config` says the settings panel is unavailable. `/mm list|get|set|reset|resetall` each name the
  missing library. `/mm perf` says performance measurement is unavailable.
- **The host verbs still work**: `/mm lock`, `/mm preview`, `/mm toggle`, `/mm window list`,
  `/mm reset-positions`. They never went to the library.
- **`/mm resetall` still works.** The user whose panel will not open is exactly the user who needs
  "reset everything", and the schema loaded fine.
- **No Lua error at load, and no half-loaded schema.** `/mm list`'s absence message is expected; a
  *partial* settings surface is not — that would mean a page file raised inside a schema-row literal
  and took its rows with it.
- Restore the directory and `/reload`. Everything comes back.

### 18. Debug console and perf capture

**Steps.**
```
/mm debug on
/mm debug           -- open the console
```
Then complete a pull, watch the log, and run a capture:
```
/mm perf help
/mm perf start
... play through two or three packs ...
/mm perf finish
```

**Pass — debug log.**
- One line per aggregator pass, not one per row: `window=1 cols=6 rows=5 dropped=0 unfolded=0
  sort=value/frozen reason=ok`. During a pull `sort=value/frozen` is the expected reading; between
  packs it should be `sort=value/value`.
- One line per render pass, one per roster build, one per visibility pass.
- **Nothing is logged per row or per cell.** Forty allocations a quarter second on a raid, discarded
  by a disabled sink, is exactly what the deferred-format rule exists to prevent.
- `/mm debug off` silences it and the console stays open. Neither the flag nor the console state
  survives a `/reload` — both are session-only and must never reach SavedVariables.

**Pass — perf capture.**
- The A/B run makes the addon **inert** during its B window without a `/reload`: the provider stops
  reading, the coalescing timers stop, and every window is refused at the source. **Nothing** — a
  combat transition, a roster change, a settings write — may bring a window back while suspended.
- After `finish`, the report names the declared buckets — `meterEvent`, `refresh`, and under it
  `providerRead` / `aggregate` / `render`, with `renderRow` under `render`, plus `tooltip`.
- Every capture record carries the addon version. A record stamped `v?` is unattributable the moment
  it leaves the session and is a bug in its own right.
- `/mm perf` output appears **whether or not** debug logging is on: a perf run is explicit user
  action, and a user who started one without enabling debug first should not watch an empty console.
- Hand the report and the JSON dump to `/wow-addon:perf-analysis`, which writes the frozen bundle.

---

### 19. Abbreviation actually reaches the cells

**Why this is a case and not an assumption.** Abbreviating is arithmetic, so the addon cannot do it
in Lua — it hands the value to `C_StringUtil.CreateNumericRuleFormatter`'s `FormatNumber`, falls back
to `AbbreviateNumbers`, and falls back again to `"<secret>"`. Which rung a live client actually lands
on is not knowable from the headless harness, and rung 3 renders a window full of `<secret>`.

1. Stand at a target dummy, out of combat, and hit it until Damage reads over a million.
2. **Damage shows an abbreviated figure** — `1.4M` or similar, always ONE decimal place whatever the
   magnitude. Note the exact precision it
   produces; the reference screenshots show three significant figures and the native formatter may
   give fewer, which is accepted, not a bug.
3. **No `/s` anywhere.** The rate slot is the bare number.
4. Pull the dummy and check again **in combat**, when the values are secret. The figures must look
   the same as they did out of combat. A number that renders `1.4M` out of combat and `<secret>` in it
   means the formatter rung changed under the restriction — report it with both screenshots.
5. Set `window.text.numberFormat` to `full` and confirm the unabbreviated form appears.

**If step 2 shows raw digits** (`1410000`), neither formatter exists on this client and the
degradation ladder is landing on a rung nobody planned for. That is a different bug from anything in
this change set.

### 20. Realm strip and truncation

1. Group with someone from another realm. **Their name shows without `-Realm`.**
2. Run a follower dungeon. The companion NPCs — names longer than a player's 12-character limit —
   show in full at the default cap of 20.
3. `/mm set window.text.maxNameLength 8`. Names truncate with a single `…` glyph, not three periods.
4. Find or invite a name with an accent in it (`Helyâ`). Truncate it right at the accented character
   and confirm **no replacement box appears** — the cut counts characters, not bytes.
5. `/mm set window.text.maxNameLength 0`. Names show in full again.
6. Drill into a player, and confirm a **spell name containing a hyphen keeps it**. The realm strip is
   anchored to the first hyphen and must not apply to a breakdown row.

### 21. The header segment selector

1. Run two or three pulls so the client is holding several stored sessions.
2. **Click the header's session line.** A menu opens: the stored fights with their durations, a
   divider, then `Current` and `Overall`.
3. Pick a stored fight. **The grid changes to that fight's numbers and the header names it** rather
   than saying "Current".
4. Hover a cell and drill into a row. **Both describe the pinned fight**, not the live pull. This is
   the case that catches a half-threaded `sessionID`.
5. Pull something new. The pinned window **stays on its fight** while an unpinned second window
   follows the live pull.
6. Pick `Current` from the menu. The pin clears and the window follows the live pull again.
7. Pin a fight, then `/reload`. **The pin survives.**
8. Pin a fight, then reset the meter from the Data settings page. On the next refresh the window
   **falls back to Current on its own** — it must not sit there empty.

### 22. v1 → v2 uniform column widths

Needs a profile written by v0.1.0, so do this before wiping SavedVariables.

1. Log in with an existing `MythicMeters.lua` SavedVariables file from before this change.
2. **Every column is the same width**, and the window is wide enough to show the rightmost one
   without clipping.
3. A window you had previously dragged **wider** than the grid needs keeps its width — the migration
   only ever widens.
4. `/reload` and confirm nothing moves again: the step is idempotent and `schemaVersion` is now 2.
5. Check a **second profile** you had not activated this session. Its widths are lifted too.

---

### 23. Tooltip appearance, anchor and offsets

Everything here is cosmetic except the last item, which is the one that can damage another addon.

**Steps:**
1. Settings → **Tooltip**. Set **Bar texture** to something visibly different from the grid's, set
   **Bar spacing** to 6, set **Font** and **Font size** to something obviously different, and set
   **Font outline** to Thick outline.
2. Hover a Damage cell.
3. Set **Bar border style** to a real LSM border with thickness 2, hover again; then set it back to
   **None** and hover the same cell again.
4. Walk **Tooltip anchor** through all nine values, hovering after each.
5. Set **Horizontal offset** to 60 and **Vertical offset** to -60, hover again.
6. Set **Maximum spells** to 0 and hover a cell for someone with a long spell list.
7. **Now hover a bag item, a party member's unit frame, and a quest in the tracker.**

**Pass.**
- The tooltip's bars wear the **tooltip's** texture, not the grid's — these are two settings now and
  changing one must not move the other.
- Spacing visibly opens up between lines; 0 restores the tight default.
- The font, size and outline apply to the **spell names as well as** the two number columns. A font
  that reached only the numbers means the shared line FontStrings were skipped.
- The border appears around each spell bar and **disappears completely** when set back to None. A
  border that lingers means the pooled carrier was not cleared — the lines are recycled, so line 4
  of this hover is the same frame as line 4 of the last one.
- Every anchor moves the tooltip somewhere different. An anchor that behaves identically to **At
  cursor** means its token is missing and it silently fell back.
- The offsets move the tooltip and it **still stays on screen** near the edges — the client is doing
  the placing, and an offset that lets the tooltip run off the edge means it is being positioned by
  hand, which is a rule R3 violation.
- **Maximum spells 0** lists every spell, up to the collector's own ceiling of 64, with an *"and N
  more"* line if the player had more than that. 0 must not behave like 10.
- **Step 7 is the one that matters.** The item, unit and quest tooltips must look **exactly as they
  always do** — stock font, stock spacing, no bars, no borders. Anything carried over means the
  addon has restyled the shared `GameTooltip` and left it that way, which persists until a reload
  and is invisible until somebody else's tooltip looks wrong.

### 24. The Targets section, and its absence mid-pull

The one place in this addon where the restriction costs *information* rather than decoration. Read
[data-flow.md §9](data-flow.md) before judging a failure here — "the section is missing mid-pull" is
the **correct** behavior, not the bug.

**Steps:**
1. Settings → **Tooltip** → enable **Show targets**, leave **Maximum targets** at 3.
2. **Out of combat**, after a pull with several different enemies, hover your own **Damage** cell.
3. Hover a **Healing** cell and an **Interrupts** cell.
4. Hover another player's Damage cell.
5. **During a pull**, hover a Damage cell.
6. Raise **Maximum targets** to 10, repeat step 2.
7. Turn **Show targets** back off and repeat step 2.

**Pass.**
- Out of combat, a **Targets** header appears below the spell breakdown, listing the enemies you hit,
  biggest first, with bars and a share column exactly like the spell lines.
- The section appears on **Damage cells only**. A Targets list under Healing or Interrupts means the
  column guard is missing.
- Another player's tooltip lists **their** targets, not yours and not the group's. This is the
  failure worth hunting: every enemy's spell list holds the whole group mixed together, so a broken
  caster filter shows everyone the same list and looks entirely plausible.
- **Mid-pull the section is absent entirely.** Not a shorter list, not zeroes — absent. A Targets
  list that *does* appear during a pull is a hard fail: the numbers behind it were summed from
  whichever rows happened to be readable and every one of them is too low.
- No Lua error at any point in step 5. The build touches secret amounts and secret GUIDs on that
  path, and it must refuse rather than raise.
- Raising the cap lists more enemies, still ordered biggest-first — the cap trims **after** ordering,
  so the top three at cap 3 are the same three enemies that lead the list at cap 10.
- With the setting off, no Targets header and — check with `/mm perf` — **no `targets` bucket
  activity at all**. The section costs one provider call per enemy, and an off switch that still
  pays for the walk is a bug.

### 25. The export modal, the CSV and the chat dump

Two frames, two destinations and one hard refusal. Most of this is checkable at a target dummy —
**except the last block, which needs a real pull**, because the refusal keys off the `Combat` addon
restriction and a dummy does not activate it.

Read [data-flow.md §6](data-flow.md) first if a failure looks like a formatting problem. A CSV cell
is `tostring(value)`, and `tostring` is not on the list of operations permitted on a secret — it
answers a *secret string* rather than raising, which then poisons the quoting logic downstream. That
is why the whole serializer refuses in combat instead of degrading, and why "it produced a file with
odd-looking cells mid-pull" would be a much worse outcome than "it said no".

#### The glyph in the title bar

**Steps.** Look at any window's title bar, right to left.

**Pass.**
- **Four buttons, in this order right to left: close · gear · lock · export.** The export button sits
  one slot left of the padlock, at the same size and the same vertical line as the other three.
- **What it draws is almost certainly `>`.** The three atlas names in `modules/Window.lua`
  (`poi-scrollofresonance`, `communities-icon-chat`, `UI-HUD-MicroMenu-Questlog-Up`) are
  **candidates and have never been confirmed on a live client** — which is exactly the mistake the
  header-art note in that file records happening twice before. `Compat.FirstAtlas` walks them in
  order and takes the first the client admits to; when none resolves, the ASCII fallback `>` is drawn
  in the header font and header color. **That is the shipped appearance, not a failure.**
- **A replacement box, an empty slot or a stretched icon is the failure.** Any of those means an
  atlas resolved and is the wrong shape for a 14px header button.
- **`/mm debug diag` answers this for you.** All three candidates are in its atlas probe list and the
  export button is in its header dump, so one command reports both what the client has and what the
  button actually drew. **A confirmed `yes` for one of them is a deliverable** — it is what lets the
  ASCII fallback stop being what ships.
- **Hovering it shows a tooltip** reading *Export a segment to CSV or to chat*. It is the only header
  button with one, and deliberately: a gear and a padlock say what they are, and a bare `>` does not.
- **Turn the title bar off** (Frame → Title bar). The export button disappears with the gear and the
  lock — there is nothing to hang it on. Turn it back on and all three return.
- Turn the **close button** off and confirm the remaining three slide right by one slot together. The
  gap between gear, lock and export must stay even; a widened seam means the header's offsets were
  turned into an accumulator.
- **Clicking it opens the modal centered over that window** — see below.

#### The modal

**Steps.** Out of combat, after at least one pull, drag a window to a corner of the screen and click
its export glyph.

**Pass.**
- The modal opens **centered on the window it was clicked from**, wherever that window has been
  dragged to. It is anchored to the window's invisible anchor frame rather than to the visible frame
  (rule R3), so this must hold for a window that has been showing live numbers all fight.
- Its title bar reads **Export**, drags the modal, and carries the addon's usual close button.
- Three selector buttons stacked top to bottom — **Metric**, **Channel**, **Lines** — each reading
  `Label: value`, and two action buttons across the bottom: **Export to CSV** and **Print to Chat**.
- **The modal is one frame, reused.** Open it from window 1, close it, open it from window 2: it
  re-centers on window 2 and exports window 2's segment. A modal that exported the *first* window's
  segment from then on is the invoker not being re-stamped.
- **Esc closes it** (it is registered in `UISpecialFrames`), and so does the close button.
- **Each selector opens a context menu** — the same `MenuUtil` mechanism the header's segment
  selector uses. Metric lists **Match the window**, a divider, then all **nine** catalog stats;
  Channel lists the **eight** entries of `Constants.EXPORT_CHANNELS` (Auto · Say · Party · Raid ·
  Instance · Guild · Whisper · Self only); Lines offers **3 / 5 / 10 / 20 / 40**, the last being
  `Constants.MAX_ROWS` rather than a literal.
- **A click outside an open menu closes the menu, not the modal.** The modal sits at `DIALOG` strata,
  below the menu's own click-catcher, which is what makes that work.
- **Picking anything repaints the modal immediately** — the button's label changes to what you picked
  before the menu has finished closing.
- **On a fresh profile the Metric follows the window it was opened from.** `defaults/Profile.lua`
  ships `export.metric = ""`, which is the choice *Match the window* rather than an absent value, and
  `Export.ResolveMetric` answers it against the invoking window at every use. Sort a window by
  **Healing**, export from it, and the Metric button must read **Healing**; sort another by
  **Interrupts**, export from that one, and the same modal must now read **Interrupts**.
- **Pinning beats the window, and is reversible.** Pick **Deaths** from the Metric menu, then export
  from a window sorted by Healing: it must stay on Deaths, and survive a `/reload`. Re-pick **Match
  the window** (the first entry, above the divider) and the following behavior must come back. A
  Metric that will not go back to following is the sentinel being written over.

#### The whisper name box

**Steps.** Walk the Channel selector through every entry, watching the space under the Lines button.

**Pass.**
- **The name box exists only while Channel is Whisper.** Every other channel hides it outright — it
  is hidden rather than greyed, because a disabled name box on a Raid export is a control asking to
  be filled in for no reason.
- Type a name and press **Enter**: it is stored, and the box loses focus.
- Type a name and **click away without pressing Enter**: it is stored anyway (`OnEditFocusLost`).
  This is the one that catches people — nobody expects to have to press Enter in a box directly above
  the button they are about to click.
- **Esc in the box clears focus** and leaves the modal open. A second Esc closes the modal.
- Switch to another channel and back to Whisper: the name you typed is still there.
- **Whisper with the box empty prints to your own chat frame and sends nothing.** That is deliberate
  — a whisper with nobody to whisper to means the same thing "Print to myself" means. Confirm no
  error and no stray `SendChatMessage` failure in the error frame.
- A cross-realm target needs `Name-Realm`, exactly as the client's own `/w` does.

#### The CSV copy window

**Steps.** With a segment holding several players, click **Export to CSV**.

**Pass.**
- A second, wider window opens **above** the modal — it sits at `FULLSCREEN` strata deliberately, so
  the modal stays visible underneath and "copy this, now try a different metric" is one trip. Its
  title reads **Export — Ctrl+C, then Esc**, and it too centers on the meter window.
- **There is text in it**, in the bundled JetBrains Mono, and the columns of digits line up. A
  proportional font here means `Constants.FONT_MONO` was passed by LibSharedMedia *name* rather than
  by path — `SetFont` does not accept the name.
- **The whole text is pre-selected** — highlighted the moment the window appears, with the view at
  the **top** of the file rather than at the bottom. Cursor position, show, focus and highlight
  happen in a load-bearing order; a window that opens scrolled to the end, or with nothing
  highlighted, means that order broke.
- **Ctrl+C copies.** Paste into a text editor and confirm you got the whole thing, not one line.
- **Esc closes the copy window and leaves the modal open.**
- Open it a second time without closing the first: it re-fills rather than stacking a second frame.
- Widen nothing and check the **first open specifically** — the EditBox falls back to a 590px width
  when the scroll frame has not been laid out yet, so a first export whose lines wrap oddly and a
  second that does not is that fallback doing its job (report it, but it is cosmetic).

**Now check the file itself**, in a text editor or by pasting into a spreadsheet:

- **The header line is exactly 26 columns**, and it is:
  ```
  session,duration,name,class,spec,role,damage_done,damage_done_ps,damage_done_pct,healing_done,healing_done_ps,healing_done_pct,absorbs,absorbs_pct,interrupts,interrupts_pct,dispels,dispels_pct,damage_taken,damage_taken_pct,avoidable_damage_taken,avoidable_damage_taken_pct,deaths,deaths_pct,enemy_damage_taken,enemy_damage_taken_pct
  ```
  Names are `snake_case`, **derived from the stat keys and never localized** — a German client must
  produce a file a colleague on an English client can open with the same formulas. Run one export on
  a non-English locale if you can and diff the header line against the one above: it must be
  byte-identical.
- **`_ps` appears twice and only twice**, on Damage and Healing — the two `isRate` stats. `_pct`
  appears once per stat, nine times.
- **Every stat in the catalog is present, not the window's columns.** Export from a window showing
  only Damage and confirm the CSV still carries all nine — the export is "the data", not "what is on
  screen".
- **Values are raw integers.** `4821993`, never `4.8M`. A spreadsheet wants the number; the
  abbreviation belongs to the chat dump. `_pct` is a bare two-decimal number with no `%` sign.
- **`session` and `duration` repeat on every row** rather than sitting in a preamble, so two exports
  pasted into one sheet still mean something and a pivot can group by fight. `session` is what the
  window's own header says — a stored fight's name if the window is pinned to one, otherwise
  `Current` or `Overall`.
- **Empty cells are empty, never the string `nil`.** Most players have no row in Dispels, Interrupts
  or Deaths, and that is the common case rather than an error.
- **Line endings are CRLF, and the file ends with one.** Paste into a spreadsheet and confirm no
  trailing blank row appears where a stray newline would put one.
- **The 40-row ceiling.** In a raid of more than 40, the CSV stops at 40 data rows —
  `Constants.MAX_ROWS`, inherited from the aggregator and documented rather than worked around.

**The name test, which is the one worth doing carefully.** Run a **follower dungeon** or a **delve**
and export afterwards, so the grid holds an NPC ally whose name has both a space and a hyphen —
`Crenna Earth-Daughter` is the canonical one.

- **The name survives intact and lands in ONE spreadsheet cell**: `Crenna Earth-Daughter`.
- It is **unquoted**, and that is correct: `Export.CsvField` quotes only on a comma, a double quote,
  a CR or an LF, and a hyphen and a space are none of those. A name split across two cells, or one
  that arrives as `Crenna` alone, means either the quoting rule or the realm strip has reached the
  serializer — the realm strip belongs to `modules/Row.lua`'s *display* path and must never run here.
- **Group with someone from another realm** and export: their `name` field keeps `-Realm`. The CSV is
  data interchange, so the realm-qualified form is the right answer even though the grid strips it.
- If any name in your group contains a comma or a quote (an NPC ally can), that field **is** wrapped
  in double quotes with embedded quotes doubled, and a spreadsheet still reads it as one cell.

#### Print to Chat — Self only first

**Do the Self run before any other channel.** `SELF` is the shipped default precisely so a misclick
cannot reach a raid, and the first time anyone runs this feature is the most likely time for a
misclick.

**Steps.**
1. Channel = **Print to myself**. Metric = **Damage**. Lines = **5**. Click **Print to Chat**.
2. Read your own chat frame. Ask someone in the group whether they saw anything.
3. Only once that is clean, work outward: Say · Party · Raid · Instance · Guild · Whisper · Automatic.

**Pass.**
- **Self prints to your own frame and reaches nobody.** Every line carries the cyan `[MM]` banner,
  because Self goes through `NS.Print` and not `SendChatMessage`. **A group member seeing anything on
  a Self export is a hard fail** and worth stopping on.
- **The shape is a header line then ranked lines:**
  ```
  Mythic Meters — Damage — Current (2:14)
  1. Kaosz 4.8M (84.2K, 31.2%)
  2. Brewz 4.1M (71.9K, 26.6%)
  ```
  Numbers are **abbreviated** here, unlike the CSV — chat wants `4.8M`.
- **The parenthetical carries only what is meaningful.** Switch Metric to **Deaths** or
  **Interrupts** and re-send: the per-second figure disappears (they are not `isRate` stats) and the
  lines read `1. Kaosz 3 (12.5%)`. An empty `( )` on any line is a bug.
- **The ranking follows the metric.** Set Metric = **Healing** and confirm the list is the top
  healers, not the top damage dealers with their healing beside them. This is the check that catches
  the export being built with the window's sort column instead of the chosen one.
- **The line cap holds.** Lines = 3 → four lines total (header plus three). Lines = 40 in a
  five-player group → six lines, not forty: the cap is a ceiling, not a pad. Walk all five choices.
- **Say** reaches only people nearby; **Party** and **Raid** reach the group; **Instance** works
  inside a dungeon or LFR group; **Guild** reaches the guild. Each sends the same lines, **without**
  the `[MM]` banner (that belongs to `NS.Print`).
- **Automatic** resolves to the widest channel you are actually in, most specific first: instance
  chat inside a dungeon or raid-finder group → Raid → Party → **Say** standing alone. Check at least
  the solo case and the dungeon case — a solo Automatic must go to Say rather than silently nowhere.
- **Whisper** with a name in the box reaches that character and nobody else.
- **No line is truncated.** `SendChatMessage` cuts at 255 bytes; these are far under, but a very long
  NPC ally name on a percent-bearing line is the closest this ever gets.
- Send with a segment that has **no rows at all** (a fresh login, before any pull): nothing is sent
  and nothing errors.

#### What is remembered

**Steps.** Set Metric = Healing, Channel = Party, Lines = 20, and a whisper name. Close the modal.
`/reload`. Re-open it. Then open **Settings → General**.

**Pass.**
- All four choices come back exactly as you left them. They live at `export.*` in the **profile** and
  are **addon-wide**, not per window — "I print the top five to party" is a habit rather than a
  window's appearance.
- **The General page shows the same four values** under an **Export** group: Default metric, Default
  channel, Whisper target, Chat lines. The panel and the modal are two views of one preference, so
  changing one must move the other — change Chat lines to 10 on the panel with the modal closed, then
  re-open the modal and confirm it reads `Lines: 10`.
- `/mm get export.channel` and `/mm set export.lines 10` work on the same rows, as they do for any
  schema path.
- Switch **profiles** and confirm the export choices switch with them.

#### `/mm export`

**Steps.**
```
/mm export
/mm export Meter
/mm export Nosuchwindow
```

**Pass.**
- `/mm export` with no name opens the modal for **the window the settings picker is on**
  (`State.activeWindowId`), falling back to the first window when nothing has ever selected one. With
  two windows, select the second in the panel, pin it to a *different* segment from the first, then
  `/mm export` and confirm the `session` column of the CSV names the second window's segment.
- `/mm export <name>` opens it for the named window; the name keeps its case and its internal
  spacing, exactly as `/mm toggle` does.
- `/mm export Nosuchwindow` prints `no window named Nosuchwindow` and opens nothing.
- The verb appears in `/mm` help **and** on the settings landing page, with the same description
  string — both read `NS.COMMANDS` and nothing else.
- A window that exists in the registry but has **never been drawn** is still exportable — the verb
  hands over the config, not the live instance.

#### The combat refusal — the case this section exists for

**This one needs a real pull.** A target dummy will not do: dummies do not activate the `Combat`
addon restriction, and the restriction is the entire subject.

**Setup.** A Mythic+ dungeon or a raid, a real group, BugSack cleared.

**Steps.**
1. **Between packs**, click the export glyph. The modal opens normally. **Leave it open.**
2. **Pull.** Watch the modal for the whole fight without touching it.
3. **Mid-pull, click Export to CSV.** Then click **Print to Chat**.
4. Finish the pull.
5. Separately, mid-pull: click a window's **export glyph**, and run `/mm export`.

**Pass.**
- **Nothing is exported.** No copy window opens, no chat line is sent, nothing reaches the group.
- **One line is printed, and it is the sentence itself:** *"Export is not available while the game
  restricts combat data."* — banner and all. A click that went silently nowhere would read as a
  broken button.
- **The modal repaints on that click**: both action buttons grey out, and the same sentence appears
  in red across the middle of the modal. This is the visible half of the refusal, and it is why the
  check is repeated **inside** each click handler rather than only at open — the modal was opened out
  of combat, when the answer was yes.
- **The glyph does not grey and ungrey through the fight.** It is deliberately not wired to the
  restriction: a header icon flickering four times a second is worse to look at than a modal that
  opens and says plainly why it cannot export.
- **The export glyph mid-pull opens nothing** and prints the same sentence. So does `/mm export`.
- **NO LUA ERROR OF ANY KIND**, and the specific ones to watch for read like *"attempt to compare two
  secret values"* or a `table.concat` error. One of those here means a serializer ran on secret input
  — the whole point of the refusal is that it cannot.
- **After the pull, both action buttons come back live on their own, with no interaction** — the
  warning line clears at the same moment. The modal takes a private bus target when it is built and
  repaints on `RESTRICTION_CHANGED`, so this is the case to watch: buttons that stay grey until you
  click something mean that subscription is not landing. Confirm the export then works normally.
  (On a degraded load with no AceEvent there is no bus target and no repaint; closing and re-opening
  the modal is the fallback there.)
- Repeat once with the modal **closed** through the pull and opened afterwards: it opens with both
  buttons live, as though the pull had not happened.

**Record for the report:** which of the three atlas candidates resolved (or that `>` was drawn),
dungeon and key level, whether the error frame stayed empty, and the exact header line of one CSV.

## What to report

For any failure, the minimum useful report is:

- **Where**: dungeon and key level, or raid, or open world; solo or grouped, and the composition.
- **When**: in combat or between packs; before or after a pull; on login, on reload, on zone-in.
- **The full Lua error with its stack**, if there was one. A secret-value error names the operation
  (compare / arithmetic / index / length / concat), which is what identifies the rule that was broken
  and therefore the file that broke it.
- **Window config**: sort mode, sort column, session type, throttle, and the column list. `/mm list`
  dumps all of it.
- **Whether it reproduces with one window**, and whether it reproduces with `sortMode = "roster"` —
  which takes the value-comparison path out of the picture entirely and is the fastest way to tell a
  sorting bug from a rendering one.
