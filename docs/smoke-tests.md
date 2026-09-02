# Smoke tests

Manual, in-client checks for **Ka0s Multi Meters**. Run before claiming a non-trivial change works,
before tagging a release, and after refreshing `libs/` or bumping `## Interface:`.

This file covers what the headless suite **cannot**. `lua tests/run.lua` loads every source file
under a mocked client and proves the logic: the schema resolves, the GUID join works, the sort ladder
falls through, the secret guards fire on mock secrets. What it cannot do is run inside a real client
with the real `C_DamageMeter`, real secret values, and the real `Combat` addon restriction — and
**that is where this addon's entire risk surface lives.** Everything in §8 through §11 exists because
a mock cannot fail the way a Mythic+ pull can.

Companion docs: [testing.md](testing.md) for the headless harness,
[ARCHITECTURE.md](ARCHITECTURE.md) for the secret-value rules referenced throughout.

**Re-verification note (2026-08-27, settings-redesign branch).** The header-controls bullets in
§1 and the settings-panel steps in §3 and §4 — page names, tab names, control names and the
lock/Test-mode relationship — were re-checked against `settings/Schema.lua` and the current page
files as part of documenting that branch's tab redesign. The rest of §1, and all of §2 and §5 through
§26, was **not** re-audited in that pass and may still describe older behaviour; treat any step
outside those specific bullets as unverified against the current branch until it has been walked
in-client.

## Conventions

- **`/reload`** abbreviates `/console reloadui`.
- **BugSack / BugGrabber** (or the stock Lua error frame) is the primary regression signal. A clean
  run is **"no errors thrown at any point"** — and in this addon the errors that matter arrive
  *four times a second, mid-pull*, so a single one is a hard fail even if the window looks right.
- **Chat banner.** Every line the addon prints starts with a cyan `[MM]`. A doubled `[MM][MM]`
  banner, or any line missing it, is a bug (`core/MultiMeters.lua` reclaims `NS.Print` from
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
| 3 | Window handling | [Lock, drag, resize, Test mode](#3-lock-drag-resize-test-mode) |
| 4 | Settings panel | [Page sweep and panel/CLI parity](#4-settings-panel-sweep) |
| 5 | Columns | [Column editor](#5-column-editor) |
| 6 | Multi-window | [Second window, copy settings, independence](#6-multi-window) |
| 7 | Visibility | [Context matrix](#7-visibility-matrix) · [Hide rules and combat](#7b-hide-rules-and-combat) |
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
| 23 | Migration | [v12 → v13 title bar and control-colour migration](#23-v12--v13-title-bar-and-control-colour-migration) |
| 24 | Tooltip styling | [Tooltip appearance, anchor and offsets](#24-tooltip-appearance-anchor-and-offsets) |
| 25 | **Targets** | [**The Targets section, and its absence mid-pull**](#25-the-targets-section-and-its-absence-mid-pull) |
| 26 | **Export** | [**The export modal, the CSV and the chat dump**](#26-the-export-modal-the-csv-and-the-chat-dump) |

---

### 1. Fresh install + first login

**Setup.** Quit WoW. Delete `WTF/Account/<ACCOUNT>/SavedVariables/MultiMeters.lua` (and the `.bak`).
Confirm the addon is enabled in the character-select AddOns list as **Ka0s Multi Meters**.

**Steps.** Log in. Run `/mm`. Open Settings → AddOns.

### The header's controls (issues #6, #7)

**Steps:** hover the title bar; click each control in turn; turn some off in Settings → Frame.

**Pass.**
- **Seven controls, right to left:** close, minimise, lock, settings, segment, reset, export. They
  are drawn from this addon's own art — white glyphs that take the header's text colour. A control
  that is a plain letter (`*`, `#`, `>`) means the art AND the atlas both failed: the ladder is
  working, but say so, because it means a texture did not load.
- **The close button is ours too**, drawn from `libs/LibKa0s/media/icons/close.tga` at the same size and
  weight as its six neighbours. A thin grey multiplication sign there is LibKa0s' close button —
  which is what the strip used to end in, and what the art replaced.
- **The icons sit inside their slots.** Each is drawn at 72% of `Control size`, so there is visible
  air between two neighbours and the strip does not read heavier than the title beside it. Icons
  touching each other means the inset was lost and the art is filling its whole click target.
- **Turning one off closes the gap.** Hide the lock and everything to its left moves right by
  exactly one slot; nothing to its right moves. A hole where a control was is the indexed layout
  failing, and it is the whole point of the rewrite.
- **The title never runs under a control**, at any `Control size` from 10 to 32 and with any
  combination hidden.
- **The strip is centred in the title bar**, on the same line as the window name and the session
  line beside it, with the gap above the row matching the gap below it down to the divider. All three
  are placed from `Window:TitleRowTop`, so check it again after changing **Header → Height**,
  **Header → Size** and **Control size**: any of those moving one of the three off the shared line
  means something is back on a hand-picked offset. A row that hugs the divider with clear space above
  it means the centring is using the tinted band rather than the frame's top edge.
- **Exactly one control reveals** — the one under the pointer comes up to full alpha and turns gold;
  the other six do not move. Two lit at once is the reveal having gone back to being strip-wide, and
  a control left bright after the pointer has moved on is the leave handler clearing a hover that has
  already moved. **Sweep along the strip**: the bright one must follow the pointer control by
  control, without a flicker in the gaps and without the whole set coming up as you cross the title
  bar. **Check this on a LOCKED window too**: locking used to disable the title bar's mouse.
- **The colours are both settings.** Header → Button style → **Control color** (white by default)
  and **Control hover color** (gold). Change either and the strip must follow immediately, at rest
  and under the pointer.
- **Each colour has its OWN color-mode dropdown.** Set **Control color mode** to **Class color**: the
  strip goes to your class colour at rest and the **hover colour is unchanged**. Set **Control hover
  color mode** to Class color instead: the resting colour is unchanged and the control under the
  pointer takes your class. Both set to Class color is legal and makes hover indistinguishable from
  rest — that is the player's choice to make, but one dropdown driving both would force it, which is
  why there are two. (These were booleans, `controlClassColor` / `controlHoverClassColor`, migrated
  to `controlColorMode` / `controlHoverColorMode` at schemaVersion 12 → 13.)
- **`Reveal controls on hover` OFF keeps every control at full alpha** — and the hover **colour**
  must still say which one the pointer is on, because it is the only channel left.
- **Minimise collapses to the title bar** and the plus/minus flips. The column headers, the rows,
  the "Waiting for combat data…" notice and the resize grip all go — anything still drawn over a
  collapsed window is parented to the frame rather than the body.
- **A collapsed window stops updating.** Verify during a pull: it must not tick. It is a real clause
  in `ShouldPoll`, not a consequence of hiding, so it is exactly the kind of thing that regresses.
- **Expanding restores the exact height** the window had, including after a `/reload` — a collapsed
  window comes back collapsed, and expands to the size you chose rather than to a default.
- **Reset asks first.** It must open the confirmation, not clear anything, and the dialog must warn
  that it wipes the game's own meter data too. Cancelling must leave the sessions intact. **The
  dialog opens in the middle of the screen**, not up at the top where the popup stack puts it. It is
  re-anchored once, as it is shown: a SECOND popup opening on top of it re-stacks every dialog and
  can pull this one back up, which is accepted rather than fixed — a confirmation that is up at the
  same moment as another popup is rare, and following the stack means hooking Blizzard's own
  positioning.
- **Segment opens the selector**, and it is the ONLY route to it. The session line beside it takes no
  mouse: hovering the empty header to the left of "Overall" must produce no red glow, and clicking
  there must open nothing. That invisible 220px click target is what the control replaced.

**Pass.**
- Login completes with no Lua errors.
- Exactly **one** window exists, named "Multi Meters #1", centered on screen
  (`Database.SeedWindows` seeds one).
- It shows the six default columns left to right after the name column: **Damage · Healing ·
  Interrupts · Dispels · Avoidable Damage · Deaths**.
- Standing solo in the open world the window is **shown**: every context ships on and every hide
  rule ships off.
- `/mm` prints the help index. Every row carries the cyan `[MM]` banner; verb names are yellow.
- Settings → AddOns shows a **Ka0s Multi Meters** parent with **nine** subcategories in this
  order: General · Windows · Frame · Header · Bars · Tooltip · Visibility · Columns · Profiles. **General is first**, and the six between Windows and Profiles read as
  `  - Frame` — two spaces, a hyphen, a space — while General, Windows and Profiles sit flush.
  Two failure modes to watch for: a **hollow box** in front of a page name means a non-ASCII glyph
  has crept back in and the player's font does not have it, and a **flat list of hyphens** with no
  indent means the client has started trimming leading whitespace — they are the pages the banner
  retargets. General and Profiles do not carry it, and no page's own canvas heading does — the
  indent is tree-label-only.
- **No `schema error:` line and no "schema path does not resolve" line appears at any point.**
  `NS.ValidateSchema` runs from the options descriptor at panel creation; a line here means a schema
  row's path does not resolve against `defaults/Profile.lua`, or its default disagrees with the tree.
- After `/reload`, `MultiMetersDB` exists on disk with `profileKeys`, `profiles.Default`,
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

### 3. Lock, drag, resize, Test mode

**Steps.**
- `/mm lock off` (or uncheck **Frame → Lock window**).
- Drag the window by its body. Drag the bottom-right grip.
- `/mm lock on`. Try to drag again.
- `/mm test` on and off (or **General → General → Test mode**).

**Pass.**
- **Locking and Test mode are independent — not coupled.** `WindowManager:SetLocked` used to also
  switch Test mode on, on the theory that someone positioning a window wants a full grid to aim at;
  that coupling is gone. `/mm lock off` no longer fills the window with placeholder rows on its own,
  and unchecking Test mode while a window is unlocked now actually clears the placeholder rows rather
  than being a no-op. Confirm both halves: lock off with Test mode off shows a real (possibly empty)
  grid, and Test mode on with the window locked still shows placeholders.
- **Test mode fills the window with placeholder rows** — ten Ka0s-named members with plausible,
  **non-jittering** numbers. The numbers are deterministic; a preview that changes every refresh is
  unusable for judging column widths, which is the job it exists for.
- Dragging moves the window; the position persists across `/reload`.
- The resize grip is visible only while unlocked, and resizing persists. That is the **only** thing
  that governs it — there is no "Show resize grip" setting any more, and there must not be: the one
  there used to be was read while the frame was being built, so unticking it did nothing until a
  reload.
- **Locked**, the window does not drag, and hovering a cell produces a tooltip (locked hands the
  mouse to the cells). **Unlocked**, the whole window drags as one object and cells do not respond.
- `/mm reset-positions` re-centers every window and prints how many moved.

### 4. Settings panel sweep

**Steps.** Open every one of the nine pages. On each, move one control of each type present
(checkbox, slider, dropdown, color, edit box) and watch the window.

**Pass.**
- **The banner, and switching windows.** Frame, Header, Bars, Tooltip, Visibility, Columns and
  Windows each draw a banner naming the active window at the top of the page. Change the window from
  the dropdown on any one of the seven and every other one of the seven reflects it the next time you
  visit — the controls on that page now show the newly-picked window's values, not the old one's.
  **The active tab survives the switch**: land on Bars → **Border**, change windows from the
  banner, and you are still looking at *Border*, now for the new window — the active tab is
  per-page UI state, not tied to which window is selected, and must not snap back to the first tab.
- Every page draws on **first show** with correctly sized widgets — nothing squashed into a
  zero-width column, and every widget carries the same skin as the rest of your AceGUI addons. With a
  skinning addon (ElvUI / AddOnSkins) loaded, this reaches the banner's window dropdown and the tab
  strip too, not only the row controls — both are built lazily on first `OnShow`, like the Defaults
  button, and a skin that reaches everything else but not one of these three is the lazy-build rule
  failing for that one piece. (Both symptoms are the lazy-build rules failing; see
  [settings-panel.md](settings-panel.md#eager-category-lazy-body-lazy-defaults-button).)
- Every change applies **immediately** to the window, without a `/reload`.
- **The tooltip.** *Tooltip behavior* now holds the **scale** slider and the **Targets** pair (they
  had a group of their own for two rows). **Each anchor is a box of a 3×3 around the cell**: "Top left" is above and to
  the LEFT, "Left" is beside it and grows left, and so on around the eight. Walk all eight and check each opens AWAY from the cell rather than
  across it. **There is no "At cursor"** — it was the default, and over a grid it landed wherever the
  pointer happened to be inside a cell, so the same hover moved every time; **Top** is the deliberate
  version and is the default now. **This is the one
  place the addon positions the tooltip itself**, so it is also the check for a taint error: if
  hovering a cell mid-pull ever produces a Lua error naming this addon, the placement is the
  suspect — it is `pcall`'d and the tooltip should fall back to roughly the right place rather than
  failing to open, so a tooltip that opens in the WRONG box mid-pull and the right box out of combat
  is that fallback doing its job. Every **target line carries an icon** now, in the
  column where the spell lines put theirs. The **player's name is class-coloured** on every tooltip
  that names one. **Text color mode reaches the spell name as well as the numbers** — all the text on
  a bar, not two thirds of it. The **fill and the backdrop** each have their own colour, mode and
  opacity. And **Border draws something**: it is on the bar rather than under it now, so a style
  and a thickness are visible at last.
- **The five text controls, on all four surfaces.** Bars → Text style, Header → Title text, Columns →
  Header text, and Tooltip → Text each carry a **font** picker, a **font outline** dropdown, a **text
  shadow** checkbox, a **text colour** picker and a **Text color mode** dropdown of Class /
  Per-statistic / Custom. **Per-statistic means a different statistic on each**: the cell takes its
  own column's colour, the title bar takes the **sort column's** (change the sort and watch it follow), the tooltip
  takes **the column you hovered** — a Healing tooltip is Healing-coloured whatever the grid is
  sorted by, and each **column label takes its own column's** — that last one is the check
  that catches the strip being resolved once and painted uniformly. Columns → **Header background**
  also carries a **Background color mode** over the same three, where Per-statistic paints one
  rectangle behind each label rather than one across the strip. The **Title bar's** own background
  (Header → Title bar) is a plain colour picker with no mode: it is one strip over the whole window,
  so per-statistic could only ever paint it the sort column's colour. **The configured opacity survives
  every mode** — a class or statistic background must arrive as a tint, not a slab. Walk all four on each page and watch the
  right thing change: the cells, the title bar and session line, the "Player | Damage | Healing"
  strip, and a hovered tooltip. A control that moves the wrong surface means two groups are sharing a
  key that is supposed to be their own.
- **"Text color mode" set to Class means the right class on each surface.** On Bars → **Text style** the cells take
  **each row's** class, so a grid of mixed classes goes multi-coloured — not all one colour. On
  Tooltip → **Text** the text takes the class of the player you are **hovering**; hover two different
  players and the colour follows. On Header → **Title text** and Columns → **Header text** it takes
  **your own** class, because those strips are about the window rather than any row. Also set **Text
  opacity** to 50% with the colour mode set to Class: the text must stay half-transparent — a class
  colour that resets it is one setting cancelling another.
- **Reset all settings starts the profile over.** With **two or more** windows open, change something
  visible on each (font size, width, a column added or removed), rename them, select **one** in the
  window picker, then General → **Reset all settings**. You must come back with exactly **one** window
  called *Meter* at the screen centre wearing the shipped defaults — the extras **deleted**, not
  restyled. That is the point: it is a profile reset, the same act as Profiles → **Reset Profile**,
  and the popup warns about the deletion before it happens. Confirm the two paths give the identical
  result, and that **`/mm resetall` does too**.
- **A reset leaves your other profiles alone.** Make a second profile on the Profiles page, switch
  back, then reset. The profile list must be unchanged and you must still be on the profile you were
  on — a reset empties one profile, it never deletes any.
- **The four meta rows.** Frame → **General** carries **Color mode**, **Bar texture**, **Font**
  and **Font outline**, each marked *(all surfaces)*, below the lock and keep-on-screen toggles. Each sets every surface that has a setting of
  its kind — the bar texture reaches the grid and the tooltip, the font and its outline reach the
  cells, both header strips and the tooltip. The check below is written for the colour mode and is
  the same for all four.
- **The meta colour mode.** Frame → **General** → **Color mode (all surfaces)**. Set it to
  Per-statistic and check all **six** of the individual dropdowns followed — Bars → *Bar*, Bars →
  *Background*, Columns → *Header text*, Columns → *Header background*, Tooltip → *Bar* and
  Tooltip → *Bar background*. The three **text** modes must **not** move: Bars → *Text style*,
  Tooltip → *Text* and Header → *Title text* are each an explicit choice, because text is drawn on
  top of a surface the broadcast reaches and has to contrast with it. Then change **one** of the six
  back to Custom:
  only that one changes, and the meta is not fought. Finally press the Frame page's **Defaults**
  button and confirm the rest are **untouched** — a page's reset must not reach other pages, and this
  page's own Defaults resets the **whole page**, every tab, not just the visible one.
- **The Frame page's shape.** Four tabs, in order: *General* (lock, keep on screen, and the four
  meta rows above), *Size and position* (width, height, scale, opacity, strata, padding),
  *Background and border* (border style and thickness, then the window's own fill colour and its
  edge colour), and *Row* (max rows, row height, spacing, growth direction, then always-show-self,
  highlight-self, mouseover highlight and the alternating background). The page **opens on
  General**, and *Font outline (all surfaces)* there shows **None** on a fresh profile. Each tab label appears **once**; a heading printed twice means a row is
  filed under a tab the page has already left. There is **no** *Header controls* tab here — those
  rows are on **Header** — and **no** "Reset position" button, which is on **General**'s **Master
  controls** tab. There is also **no** "Show resize grip" checkbox and **no** "Minimised" checkbox: the lock
  governs the grip, and the header's own minimise button governs the collapse. Whether the title bar
  draws at all (`window.header.show`) is a **Header** page setting now, on its **Title bar** tab, not
  a Frame row.
- **The Bars page's shape.** Six tabs, outside in: *Bar*, *Background*, *Border*, *Text content*,
  *Text style*, *Icons* — every tab here is about the bar, so the two that used to say so in their
  names no longer do. The Text and Icons pages folded in here, and their paths did not move with
  them — `/mm get window.text.size` still answers; `window.rows.*` is on the **Frame** page's *Row*
  tab now, not on Bars.
- **The Header page's shape.** Four tabs, top to bottom in the order the strips are drawn: *Title
  bar* — the strip's own shape: whether it draws, its background, alignment, height, and the divider
  under it (on/off, thickness and colour) — then *Title text* — the face drawn on it, and the
  window's own name — then *Controls*, and *Button style* (the reveal beside the size, then rest and
  hover paired down three lines: mode, colour, opacity). `showClose` and the rest are still **stored** at
  `window.frame.*` (`/mm get window.frame.showClose` answers), which is deliberate: a row's page is
  where it is edited, its path is where it is stored. There is **no** *Column headers* tab here any
  more — that strip's rows moved to the **Columns** page, which is the page that labels it.
- **The Controls tab reads like the header strip.** Every checkbox draws **the control's own icon**
  between the tick box and the words, and the rows run in the order the strip runs **left to right**:
  the segment line first (no icon — it is text, not a glyph), then export, reset, segment picker,
  settings, lock, minimise, close. Check each icon against the one in the header above it; a missing
  icon means `NS.Icon` answered nil for that art name, which is a media-payload problem rather than a
  settings one, and the label falls back to its plain words.
- **The Visibility page's shape.** Three tabs: *Where to show this window* (the seven context
  checkboxes), *When to hide this window* (the mount/skyriding/housing/pet-battle/death/combat
  rules) and *Combat* (hide in/out of combat). Those first two are by a wide margin the longest tab
  labels in the whole panel, and the likeliest strip to wrap.
- **The divider under the title bar.** Header → *Title bar* → **Show divider** ships **on**. Turn it
  off and the hairline between the title strip and the column labels goes, and **nothing else moves**
  — the window title, the session line and the control strip stay exactly where they were, because
  the title row is centred against a constant rather than measured off the line. **Divider
  thickness** grows it downward, into the gap above the column labels. **Divider color mode** ships
  as **Ka0s skin**, which means the line is left exactly as the shared skin painted it — check that
  first, then switch to **Class color** and confirm it takes yours, and to **Custom color** and
  confirm it takes the swatch. Set the swatch's opacity to something low and switch between Custom
  and Class: the opacity must **not** change with the mode. There is deliberately no per-statistic
  mode — one line across the whole window could only ever mean the sort column.
- **The two control opacities.** Header → *Button style* → **Control opacity** (25%) and **Control
  hover opacity** (100%) are the two ends of the reveal and ship at what used to be hardcoded, so
  check first that an untouched window looks exactly as it did. Then move each on its own and confirm
  it moves only its end. Finally set **Control opacity** near zero and turn **Reveal controls on
  hover** OFF: the strip must come back to the *hover* value, not vanish — with fading off there is
  no faded state, so the rest slider is not read at all.
- **The lock icon is the same weight as its neighbours in both states.** Unlock a window and compare
  the padlock against the six controls beside it — same brightness, same colour; only the glyph
  changes, from a closed padlock to an open one. It used to be drawn at 45% while unlocked, which is
  the state a fresh window ships in, so the strip read as having one half-broken icon in it.
- **The tab strips all fit one row at default UI scale.** Frame's four tabs, Bars' six, Tooltip's
  six, Header's four and Visibility's three — note any that wrap onto a second row; a wrapped strip is a layout bug in
  `placeTabs`' coordinate arithmetic, not a copy problem.
- **Tab art — open question.** The strip is currently a flat backing with the active tab drawn
  darker. Whether that reads as tabs, or wants Blizzard's tab atlas instead, is a deliberately open
  call the plan left for the client: look at it and decide. Changing it is a
  `LibKa0s/OptionsWidgets.lua` edit plus a minor version bump, not a MultiMeters change.
- **The header background stops at the title bar.** Header → Title bar → **Header background** to
  something loud, and Columns → Header background → **Background color** to something else: two
  distinct bands, the second starting exactly where the first ends. One colour covering both rows is
  the old behaviour, in which the column strip's own setting was invisible underneath and a colour
  picked for the title bar restyled the grid's labels too.
- **Scale scales the whole window.** Frame → Scale to 0.5, then 2.0. The window's **outline** grows
  and shrinks with its contents. A box that stays exactly the size it was while the grid inside it
  shrinks into one corner means the scale reached the visible frame but not its anchor.
- **No border means no border.** Frame → Border style **None** and Border thickness **0**: the window
  has no edge of any kind. A 1px line surviving both is the library skin's `frame.innerBorder`, a
  child frame that is not part of the backdrop the border settings rewrite. Check **None** at a
  non-zero thickness too — it must also draw nothing, rather than falling back to the Ka0s edge. The
  addon has **two** LSM border settings and the rule is the same on both; the other is Tooltip → Bar
  border style, checked in §24.
- Six pages carry a **Defaults** button in the header (Frame, Header, Bars, Tooltip, Visibility,
  Columns); **Windows and Profiles do not.** Columns' button resets its block editor to the shipped
  catalog, ticked and ordered — it is **not** absent the way it used to be.
- **The Defaults blast radius stays page-wide on every tabbed page** (`options-ui-§13`): the button
  MUST NOT narrow to the tab on screen. On each of the six Defaults pages, change a value on a tab
  that is **not** the one showing, switch to a different tab, press **Defaults**, then switch back
  and confirm the value you changed is gone too. Columns is the sharpest version of this check —
  ticking/reordering a block lives on its *Columns* tab, but the header text and background rows the
  same button also restores live on the other two — so leave the page on the block-editor tab, change
  a value on *Header text* or *Header background* without visiting it, and confirm Defaults still
  reaches it.
- **The General page's shape and its buttons.** It is the **first** page in the tree, above Windows,
  and it draws **no banner** — it is not a window page. Three tabs, in this order.
  **Master controls** is `options-ui-§15`'s canonical set and opens the page: **Enable Multi
  Meters**, **General visibility**, **Master scale**, **Master alpha**, **Lock frame**, **Debug
  console**, closed by the **Reset position** / **Reset all settings** button pair and one sentence
  under it saying what each reaches. The four `master.*` rows are addon-wide and are **not** the
  per-window lock, scale and opacity on Frame — set Master scale to 0.5 with a window already at
  0.8 and the window draws at 0.4, and putting the master back to 1.0 gives every window exactly the
  size it was set to. **General** carries the minimap toggle, then **Merge pets into their owner**
  and **Refresh interval** — both addon-wide: change either and **every** window follows, not just
  the selected one — then Test mode. **Statistic colors** is the palette (below). The retired
  **Data** and **Maintenance** tabs are where the middle rows used to live. There is deliberately
  **no** Reset meter data button here, or on any page; the header's own reset control is the one way
  to it. Reset position is the one control on the page that is **not** addon-wide — it moves the
  window the banner is pointed at and nothing else, which the line under the pair says.
  **Nothing is drawn twice**: Test mode and the debug console are `sessionOnly` schema rows, so a
  second "Preview mode"/"Debug console" checkbox or a second *Debug* heading is the duplicate this
  redesign removed coming back.
- **The statistic palette is editable, and every surface follows it.** General → **Statistic
  colors** carries one swatch per statistic, shipped in the catalog's own colours, and a note under
  the grid saying where they are worn — read it and check it is true, because it is the only thing on
  that tab explaining why setting a colour can appear to do nothing. Change
  **Damage**'s to something unmistakable, then check all four surfaces that wear the palette move
  together: a Bars → *Bar* → Bar color mode of **Per-statistic**, a Bars → *Text style* → Text color
  mode of **Per-statistic**, the Columns → *Header text* / *Header background* modes, and — with no
  mode set anywhere — the **Damage** line of a name tooltip, which wears the palette always. Then
  press the General page's **Defaults** and confirm the shipped colours come back.
- **The two death-line switches.** Hover a **Deaths** cell for somebody who has died: on a fresh
  profile each line reads *Death 3 | <who>* — **Name the killer** ships on and **Name the killing
  blow** ships off, because the spell is the longest thing on the line and the half most often
  absent. Turn the spell on and the line becomes *Death 3 | <who> | <what>*. Turn **Name the killer**
  off and the caster half goes with no separator left behind; turn the spell back off and it goes the
  same way. A fall or a fire has no caster to name and a melee swing reads
  **Melee** — neither is a bug, and neither may take the numbered line down with it. **Check this
  mid-pull too**: a restricted client can hand either name back secret, and the correct behaviour is
  the same as "not available" — the half is simply absent.
- **The number formats.** Bars → *Text content* → **Number format** offers four: *Abbreviated
  (12.4M)*, *Abbreviated, no decimals (12M)*, *Abbreviated, two decimals (12.40M)* and *Full
  (12400000)*. Walk all four on a column holding a large number and confirm each renders what its
  name says. **The two-decimal rung is the one to look hardest at** — the ladder is probed against
  `47.50K` and a client that renders it any other way falls back to the client's own defaults, which
  would show as the setting quietly doing nothing.
- **The two smart values.** Bars → *Text content* → **Left text**. *Smart value (Per Second or
  Absolute)* picks one figure per column — the rate on Damage and Healing, the total on Interrupts
  and the rest. *Smart value (Absolute | Per Second)* shows both with a bar between them on the
  columns that have both, and the absolute **alone** on a counting column: an Interrupts cell reading
  `9 | 3` is the failure to look for. Check both **mid-pull**, when every figure is secret.
- **The window name takes the header's colour.** Header → *Title text* → **Text color**: the title in
  the window's title bar follows it, along with the font, size, outline and shadow it already
  followed. Set **Text color mode** to **Class color** and the title takes your class colour, exactly
  as the session line beside it does — the two are one header and must never differ. Drop the
  swatch's opacity and switch between the two modes: the opacity must **not** change with the mode.
  There is deliberately no per-statistic option — one strip over the whole window could only ever
  mean the sort column.
  The Settings window's own footer Defaults control works on the same tab.
- **Panel ↔ CLI parity.** With a page open, run `/mm set window.frame.width 640`. The Frame page's
  Width slider moves to 640 **without being reopened** (`RefreshScalars`). Conversely, move a slider
  and `/mm get window.frame.width` reports the new value.
- `/mm list` groups every setting under the same page keys the panel uses. It lists
  `window.frame.minimised`, which the **panel does not draw** — that row is `hidden`, because it is
  state the header's own minimise button writes rather than a preference. `/mm set
  window.frame.minimised true` must still collapse the window.
- **A tab click works in combat.** With a tabbed page already open, enter combat (a dummy is fine)
  and click a different tab. It redraws normally with **no** refusal — the strip is deliberately not
  combat-guarded (`options-ui-§13`): redrawing widgets inside an already-open panel is not a
  protected action. What **is** refused is *reaching* the panel mid-combat in the first place, which
  is the next bullet — a tab click that refuses is the defect here, not one that works.
- **Clicking the tab you are already on does nothing at all** — no flicker, no repaint, no refusal
  message.
- **Combat refusal.** Enter combat (a dummy is fine here). `/mm config` **refuses** and prints one
  gray notice. It must **not** queue the request and open the panel when combat ends.
- **Profiles page mid-combat.** With the Settings window closed, enter combat, then open Settings →
  AddOns → Ka0s Multi Meters → **Profiles** from the Blizzard sidebar. The page must close the
  Settings window and print the refusal — that route bypasses `/mm config` entirely, which is why the
  page carries its own guard.

### 5. Column editor

The page is **one block per statistic** — a drag handle, a green tick or a red cross, and a name.
Ticked blocks are the columns, in block order, and they always sit above the rule; unticked ones sit
below it. Nothing here can be driven offline, so every check below needs a client.

**Steps.** Out of combat, on the Columns page:

1. **Drag** a block from the bottom of the ticked group to the top, by its handle.
2. **Untick** a middle column.
3. **Re-tick** it.
4. Try to **drag a ticked block below the rule**.
5. Untick down to one column, then try to untick that one.

**Pass.**
- **1** — the window's columns reorder to match, immediately, and the page after the drop shows the
  new order. The **handle** is the full-height strip down the left edge carrying the icon — the whole
  strip is the target, not just the icon. Pressing anywhere else on the block does not start a drag.
- **If the drag does nothing at all**, turn on `/mm debug` and try again. The handle logs
  `[Blocks] grab N at y=…` when the press is received and `[Blocks] drop N -> M (R rows)` when it
  completes. No `grab` line means the press never reached the handle; a `grab` with no `drop` means
  no release path fired; a `drop` with `0 rows` means the cursor read did not move.
- **After any of these, look at the blocks themselves.** Each must show exactly ONE label and ONE
  glyph. Two names overprinted ("DamageDeaths") or a tick with a cross through it means blocks are
  stacking on recycled slots again, and the next thing to check is that clicking a glyph toggles the
  statistic you clicked rather than a different one.
- **2** — the block drops to the **top of the disabled group**, just below the rule, and the window
  loses that column. It lands where you can see it, not at the bottom of a long list.
- **3** — it lands at the **end of the ticked group** and reappears as the **rightmost** column.
- **4** — **a hidden column has no handle at all**, so there is nothing to grab below the rule. On a
  shown one the **insertion line stops at the rule** and the block stays ticked, wherever you take
  the cursor. The tick is what moves a block between groups; a drag must never silently turn a column off.
  A clamped drop writes nothing, so the line stopping is the only feedback there is — if you cannot
  see it, that is the bug, not the clamp.

**Throughout a drag, three things must be true at once:** a **copy of the block** follows the
cursor, the row it came from **fades** in the list, and a gold **insertion line** sits where it would
land. The list itself never reflows under the pointer — the copy and the line are the whole of the
feedback, and without them a working drag is indistinguishable from a broken one. The copy must
follow the cursor **past the top and bottom of the list**; if it clips at the edge it is parented to
the wrong frame.
- **5** — refused, with "A window must keep at least one column." printed. A window of nothing but
  names reads as a broken addon rather than as a configuration.

**Hover the handle before pressing it:** it goes **gold** and says *Drag to reorder*.

**Drag twice in a row.** The second drag must work exactly like the first — a handle that responds
once and then does nothing means a stale one from the previous render is taking the press, and the
carried copy is usually left floating over the list as the other half of that symptom.

**The Defaults button** (top right) puts the shipped statistics back, ticked and in shipped order.

**After every drag and after Defaults, look for leftovers.** No row may show two names stacked, and
no drag handle may appear anywhere that is not a block — not beside the page's intro text, not on
the scrollbar, nowhere. Either symptom means a handle or a block outlived the render that made it.
`/mm debug` prints `[Columns] paint window=N` per repaint, `[Blocks] released N blocks` and
`[Blocks] released N handles` on the way in, and `[Blocks] painted N rows, M draggable` on the way
out. **Blocks and handles released must equal blocks and handles painted**, every time — a
shortfall is something still parented to a container the page has already given back to AceGUI's
pool, which is where every leftover in this page's history has come from.

**Hover a tick and a cross.** Each says what the CLICK will do — *Click to hide this column* / *Click to show this column* — not what the glyph already means.

Also check: every column draws its **bar** (there is no numbers-only column any more), and the
columns share the frame width evenly (there is no per-column width to set).

**Combat refusal.** Leave the Columns page **open**, then pull. Click a glyph and drag a handle.

**Pass.** Both are refused with "Columns cannot be changed during combat." — printed, not silent.
**No Lua error.** This is the case the library's render-time refusal does not cover: a panel left
open when a pull starts is still clickable, and rebuilding cells that are holding secret values is
precisely what must not happen.

### 6. Multi-window

**Steps.**
1. Windows page → **New window**. Confirm the picker follows the new window, and that it is named
   "Multi Meters #2" — the count of windows, not the window id.
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
- The window picker is keyed by id: two windows both named "Raid" are still individually selectable.
- **Delete** confirms first, and the **last** window cannot be deleted ("The last window cannot be
  deleted.").
- After deleting the window the picker was pointed at, every settings page re-renders against the
  first surviving window rather than showing empty widgets.
- `/mm window list` lists both, with shown/hidden state and column count. `/mm window new`,
  `delete`, `copy <source> <target>` do the same things the panel does.

### 7. Visibility matrix

**Steps.** A **fresh profile**, so nothing has been switched. Visit: solo open world · grouped open
world · a five-player dungeon · a raid · a battleground · a delve · a vehicle (a quest turret or a
Mythic+ dungeon vehicle encounter).

**Pass.**
- **The window is visible in every one of them.** Show everywhere, hide nowhere is the shipped
  default: a fresh profile has all seven contexts on and all ten rules off, so nothing takes the
  window away until the player asks. A window missing anywhere on a fresh profile is a bug.
- Turn **Open world** off: it hides outdoors and still shows in the dungeon.
- Turn **Hide when solo** on and drop group: it hides. Group up: it returns.
- A **delve** → shown, and `/mm debug diag` reports `type=scenario resolved=delve`. This is the one
  context where Blizzard's token and the addon's answer deliberately disagree: delves have no
  instance type of their own. Turn **Delves** off and the window hides while **Scenarios** stays on —
  if it hides in both, the delve probe is not firing and both contexts have collapsed into one.
- An ordinary **scenario or follower dungeon** → shown, reported as `resolved=scenario`.
- Entering a vehicle hides the window; leaving shows it again — **immediately**, on the vehicle
  event itself. If it only hides after you next change zone, `UNIT_ENTERED_VEHICLE` is not reaching
  the fan-out; that was the 0.1.0 behaviour and it is the shape every visibility rule fails in.

### 7b. Hide rules and combat

**Steps.** One rule at a time, with the window otherwise showing. Mount up · summon a skyriding
mount and stand still on the ground · take a flight path · enter your house · start a pet battle ·
die · pull a target dummy.

**Pass.** Every rule below ships **off**, so each has to be switched on for its check.
- **Hide in player housing / on flight paths / in pet battles**: switched on, the window goes in
  your house, on a taxi and over a pet battle, and returns when you leave.
- **Hide when mounted**: switched on, the window goes while mounted — and for a druid
  it must also go in **Travel, Aquatic and Flight Form**, and must NOT go in Cat, Bear or Moonkin.
- **Hide when skyriding** fires from the moment the skyriding bar appears, standing on the ground,
  not only once airborne. A Dracthyr's Soar and a Haranir flight form count here even though
  `IsMounted()` is false in them. **Test the dismount as carefully as the mount**: a ground mount and
  a skyriding mount take different code paths — the ground one flips `IsMounted()` on its own edge,
  the skyriding one depends on the glide events arriving *and* on the settle pass, because
  `canGlide` can still read true at the dismount edge. A window that hides on mounting and never
  returns is the signature failure.
- **Hide while dead**: off by default so dying in a raid leaves the meter readable, which is most of
  what it is for. Switched on, the window goes on death and comes back on release or resurrection.
- **Hide in combat** / **Hide out of combat** are independent. Each hides on its own side of a pull
  and the window returns on the other side, promptly rather than a refresh tick late — both edges
  are announced on the bus. Ticking **both** is a window that never shows; `/mm debug diag` still
  reports `ShouldShow -> false (in combat)` or `(out of combat)` depending on where you are standing.
- After every one of these, `/mm debug diag` names the rule that decided in its `ShouldShow` line.
- **Master enable off** (`/mm set enabled false`, or General → Enable Multi Meters) hides every
  window immediately and stops the addon reading the meter at all.
- **Test mode overrides context**: with Test mode on, the window shows wherever you are standing.

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
- **Text renders, and it is abbreviated.** Damage reads `188K`, not `188000` and not `<secret>` — the
  shipped `leftSlot = "smart"` puts the PER-SECOND figure in a rate column's cell and the absolute
  one in every column without a rate, so Damage and Healing read as rates while Interrupts, Dispels,
  Avoidable Damage and Deaths read as counts and totals.
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
- **Text opacity fades only the text.** Settings → Text → **Text opacity** at 10%: the numbers and
  names go faint while the bars, the cell backgrounds, the borders and the class icons stay exactly
  as bright as they were. If the whole grid dims, `text.alpha` has been folded back into the cell's
  StatusBar alpha and is fading every child of it. **Bar opacity** (Settings → Bars) is the one that
  dims everything, and setting both to 50% must leave the text at 25% — a child's alpha rides on top
  of its parent's.
- **The text slots are literal — walk all six.** On Bars → *Text content* set **Left text** and
  **Right text** in turn and confirm each does exactly what it says, with no substitution anywhere:
  **None** on both leaves the cells with a bar and no text at all (this is the check that matters —
  it used to fall back to the total and the setting appeared to do nothing); **Smart value (Per
  Second or Absolute)** shows the rate on Damage and Healing and the absolute figure on Interrupts,
  Dispels, Avoidable and Deaths; **Smart value (Absolute | Per Second)** shows both on Damage and
  Healing and the absolute alone on the other four; **Absolute value** shows the total on every
  column including the rate ones; **Per second value** shows a figure on Damage and Healing and
  leaves Interrupts, Dispels, Avoidable and Deaths **empty** rather than substituting their totals;
  **Percent** behaves as below. Left None with Right
  set to anything must leave the figure on the RIGHT — it must not slide over into the empty left
  slot.
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
- Hovering an **Avoidable Damage** cell draws **one line per spell and nothing else** — no
  "Avoidable" / "Avoidable, Deadly" sub-line beneath a bar, and no Overkill line. Every spell in that
  breakdown is avoidable by definition, so the tag restated the column once per row. Check this in
  **Test mode** (`/mm test`) especially: its placeholder data sets both flags on alternating
  spells, which is where the tags were most visible.
- **Name tooltip** lists **every** tracked statistic for that player, including the ones this window
  is not showing. Each line wears **its own statistic's color, label and amount alike** — the same
  palette a bar takes under `bars.colorMode == "stat"`, and it wears it whatever that setting is
  currently set to. Hold the tooltip beside the grid and check the two **match**: a "Damage" line
  that reads as a paler or less saturated red than the Damage bars behind it means the palette has
  been lifted or tinted somewhere between the catalog and the tooltip. The statistics this window has
  no column for are the **same hue, dimmed**, not a flat gray — and the dimming reaches the number,
  not just the label. That cross-column read is the reason the addon exists.
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
- **Settings → Text → Death timestamps** offers two styles — time of day, and how long ago — and the
  Deaths cell tooltip and the death list must agree on whichever is picked: the first is the index
  into the second, and two labellings would make one list look like two. A third style, "time into
  the fight", was built and removed; see Known limitations before adding one back.
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
2. Put the window on **Damage** by clicking the **Damage** column header, and click it once more if
   the arrow is not pointing down. The sort is the window's own control — there is no settings row
   and no `/mm set` for it, deliberately: the click path writes `sortMode`, `sortColumn` and
   `sortAscending` directly.
3. Pick **Overall** from the header's **segment** dropdown, so both meters are describing the same
   span. (Overall is the accumulated run and the shipped default; Current is the live pull.)
4. Open **Blizzard's built-in damage meter** and put it on **Damage done**, same session scope.
5. Compare the two lists **top to bottom, by name**, and write both orders down.
6. Repeat for **Healing** (click the Healing column header) and for a counting stat —
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
  - *"Multi Meters reads every number from the game's built-in damage meter. Enable it to see data
    here."*
  - and, in gray, *"Reason: …"* — **Blizzard's own `failureReason`, quoted verbatim**. It is not
    translated and not second-guessed: the game knows why its meter is off, and guessing on its
    behalf is how an addon tells a player to enable something that was never the problem.
- **No Lua error**, and no empty window with no explanation.
- Re-enable the meter. Within a few seconds (or after a zone change / meter event, which invalidates
  the memoized availability answer) the rows come back **without a `/reload`**.

**The other empty state.** With the meter **enabled** but no combat data yet — fresh login, or right
after the header's **reset** control wipes the sessions — the window shows *"Waiting for combat data…"* instead.
These two messages must not be confused: one means "the meter is off", the other means "the meter is
on and there is nothing in it yet", which is the normal state between pulls.

**Reset meter data.** From the window header's **reset** control — there is no settings-page button
for it — click it and confirm the popup. Blizzard's **own** meter
window empties too — the call is `C_DamageMeter.ResetAllCombatSessions` and it is account-wide, which
is why the popup exists. Every open drill-down closes and this module's caches are dropped.

### 14. Slash surface

**Steps.** Run each verb.

```
/mm                          /mm help              /mm config
/mm list                     /mm version
/mm get window.frame.width   /mm set window.frame.width 520
/mm reset window.frame.width /mm resetall
/mm lock            /mm lock off        /mm test            /mm test on
/mm toggle          /mm toggle Meter
/mm window list     /mm window new Raid /mm window copy Meter Raid
/mm window delete Raid
/mm reset-positions
/mm debug           /mm debug on        /mm debug off
/mm perf            /mm perf help
/multimeters help
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
  them into place" and does **not** touch Test mode — the two used to be coupled
  (`WindowManager:SetLocked` also flipped it on) and are not any more; ask for placeholder rows
  with `/mm test` explicitly.
- `/mm debug` toggles the console **window**; `/mm debug on|off` sets the logging **flag**. They are
  separate on purpose: logging runs with the console closed so a bug can be reproduced first and the
  log read afterwards.
- **The console's title bar draws three icons, right to left: close, clear, copy** — the same art the
  meter window's header uses, one size and one pitch, gray at rest and gold under the pointer. Words
  there (`Copy`, `Clear`) or a multiplication sign mean `core/DebugLogSetup.lua` stopped passing
  `addonName`, or the art is missing from the vendored payload; the console still works either way,
  which is why nothing errors to tell you.
- **Hover copy and clear: each brightens to gold, and NOTHING pops up.** They carried a tooltip for
  one release; it anchored under the control, on top of the first line of the log. A tooltip
  reappearing there is a regression, not a nicety.
- **Clear empties the log; copy opens the copy window**, whose own title bar carries the same close
  icon. Ctrl+C then Esc still works there.

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
| General → **Master controls** → **Reset position** | the active window only, back to center |
| `/mm reset-positions` | every window back to center |

**Pass.**
- **Profiles are never touched** by any reset. Create a second profile first, then run
  `/mm resetall`, then confirm the second profile still exists and is unchanged. This is enforced in
  two places on purpose.
- "Reset all settings" **does** move every window back to center — but not through a position hook
  of its own any more. It is a **profile reset** (`db:ResetProfile()`), so the extra windows are
  **deleted** and the one that is re-seeded comes back at the shipped position with the rest of the
  profile. `afterRestoreAll` no longer calls `ResetPositions`.
- After `/mm resetall` the column list is back to the six shipped columns, in catalog order.

### 17. LibKa0s absent

**Setup.** Rename `libs/LibKa0s` to `libs/LibKa0s_off` (or delete it from a copy of the install).
`/reload`.

**Pass.**
- **The addon still loads and the window still draws rows.** This is the point: a missing vendored
  library degrades, it does not break the addon.
- One honest chat line names the cause, once, on the first line the addon prints — the shared clause
  *"The LibKa0s library is missing from this installation of Ka0s Multi Meters (expected in
  libs/LibKa0s)"* — followed by what is unavailable.
- `/mm config` says the settings panel is unavailable. `/mm list|get|set|reset|resetall` each name the
  missing library. `/mm perf` says performance measurement is unavailable.
- **The host verbs still work**: `/mm lock`, `/mm test`, `/mm toggle`, `/mm window list`,
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
2. **Click the segment control in the header strip** (the three horizontal lines). A menu opens:
   the stored fights with their durations, a divider, then `Current` and `Overall`. It anchors to the
   session line, which is where the menu has always come out. **The session line itself is not a
   click target** — that 220px invisible button was removed.
3. Pick a stored fight. **The grid changes to that fight's numbers and the header names it** rather
   than saying "Current".
4. Hover a cell and drill into a row. **Both describe the pinned fight**, not the live pull. This is
   the case that catches a half-threaded `sessionID`.
5. Pull something new. The pinned window **stays on its fight** while an unpinned second window
   follows the live pull.
6. Pick `Current` from the menu. The pin clears and the window follows the live pull again.
7. Pin a fight, then `/reload`. **The pin survives.**
8. Pin a fight, then reset the meter from the General settings page. On the next refresh the window
   **falls back to Current on its own** — it must not sit there empty.

### 22. v1 → v2 uniform column widths

Needs a profile written by v0.1.0, so do this before wiping SavedVariables.

1. Log in with an existing `MultiMeters.lua` SavedVariables file from before this change.
2. **Every column is the same width**, and the window is wide enough to show the rightmost one
   without clipping.
3. A window you had previously dragged **wider** than the grid needs keeps its width — the migration
   only ever widens.
4. `/reload` and confirm nothing moves again: the step is idempotent and `schemaVersion` is now 2.
5. Check a **second profile** you had not activated this session. Its widths are lifted too.

---

### 23. v12 → v13 title bar and control-colour migration

Needs a profile written before this branch (`schemaVersion` 12 or earlier), so do this before wiping
SavedVariables — same constraint as §22.

1. Log in with an existing `MultiMeters.lua` SavedVariables file from before this branch, on a window
   that had its title bar **turned off** and at least one of *Control class colour* / *Control hover
   class colour* **ticked**.
2. The window opens with its title bar **still off** and its control colours **exactly as they were**
   — the migration carries the stored value across; it does not re-default it. A title bar that comes
   back ON, or control colours that reset to Custom, is the migration writing a default instead of
   carrying the stored value.
3. Header → **Title bar** shows the toggle unticked, matching what §2 showed on the window itself; the
   old Frame → *Frame behavior* location is gone.
4. Frame → **General** (or wherever the control colour dropdowns now live) shows **Class** for
   whichever of the two flags was ticked before, not Custom.
5. `/reload` and confirm nothing moves again: the step is idempotent and `schemaVersion` is now 13.
6. Check a **second profile** you had not activated this session; its title bar and control colours
   are carried across too.

---

### 24. Tooltip appearance, anchor and offsets

Everything here is cosmetic except the last item, which is the one that can damage another addon.

**Steps:**
1. Settings → **Tooltip**. Set **Bar texture** to something visibly different from the grid's, set
   **Bar spacing** to 6, set **Font** and **Font size** to something obviously different, and set
   **Font outline** to Thick outline.
2. Hover a Damage cell.
3. Set **Bar border style** to a real LSM border with thickness 2, hover again; then set it back to
   **None** and hover the same cell again.
4. Walk **Tooltip anchor** through all eight values, hovering after each.
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
  of this hover is the same frame as line 4 of the last one. This is one of the addon's **two** LSM
  border settings, and "None" has to mean no edge on both: the other is Frame → Border style, checked
  in §4.
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

### 25. The Targets section, and its absence mid-pull

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

### 26. The export modal, the CSV and the chat dump

Two frames, two destinations and one hard refusal. Most of this is checkable at a target dummy —
**except the last block, which needs a real pull**, because the refusal keys off the `Combat` addon
restriction and a dummy does not activate it.

Read [data-flow.md §6](data-flow.md) first if a failure looks like a formatting problem. A CSV cell
is `tostring(value)`, and `tostring` is not on the list of operations permitted on a secret — it
answers a *secret string* rather than raising, which then poisons the quoting logic downstream. That
is why the whole serializer refuses in combat instead of degrading, and why "it produced a file with
odd-looking cells mid-pull" would be a much worse outcome than "it said no".

#### The export control in the title bar

**Steps.** Look at the header strip, right to left, and hover the export control.

**Pass.**
- **It is the leftmost of the seven**, at the same size, the same centre line and the same colour as
  the six beside it. The whole strip is covered by *The header's controls (issues #6, #7)* near the
  top of this file — what is checked here is only the export end of it.
- **It draws the collection's own art** (`libs/LibKa0s/media/icons/export.tga`). A plain `>` means BOTH our
  texture and every atlas candidate failed: the ladder is working as designed, but say so, because a
  shipped TGA that does not load is a packaging bug rather than a fallback.
- **The atlas rung is still unconfirmed.** `poi-scrollofresonance` and `UI-HUD-MicroMenu-Questlog-Up`
  are candidates that have **never been seen resolving on a live client**, which is the mistake the
  art-ladder note in `modules/HeaderControls.lua` records happening twice before. They are only
  reachable now on a client that cannot load our TGA, so confirming one is a `/mm debug diag` job,
  not something a normal run will show you.
- **`/mm debug diag` answers this for you.** Both candidates are in its atlas probe list and the
  export control is in its header dump, so one command reports what the client has and what the
  control actually drew.
- **Hovering it shows a tooltip** reading *Export a segment to CSV or to chat*. It is the only
  control in the strip with one, and deliberately: a gear and a padlock say what they are, and the
  export glyph is the one whose meaning is not obvious.
- **Turn the title bar off** (Frame → Title bar). The whole strip goes with it, export included —
  there is nothing to hang it on. Turn it back on and all seven return.
- **Clicking it opens the modal centered over that window** — see below.

#### The modal

**Steps.** Out of combat, after at least one pull, drag a window to a corner of the screen and click
its export glyph.

**Pass.**
- The modal opens **centered on the window it was clicked from**, wherever that window has been
  dragged to. It is anchored to the window's invisible anchor frame rather than to the visible frame
  (rule R3), so this must hold for a window that has been showing live numbers all fight.
- Its title bar reads **Export**, drags the modal, and carries the addon's usual close button — the
  **same icon the window header draws**, gray at rest and red under the pointer. A thin gray
  multiplication sign there means LibKa0s was not told which addon is asking (`core/CoreSetup.lua`
  wraps `MakeCloseButton` to pass the folder name), or the art is missing from the vendored payload.
- Three selector buttons stacked top to bottom — **Metric**, **Channel**, **Lines** — each reading
  `Label: value`, and two action buttons across the bottom: **Export to CSV** and **Print to Chat**.
- **Each action button carries an icon to the left of its label** — a spreadsheet on Export to CSV, a
  speech bubble on Print to Chat — and **the words are still there**. The mark says where the export
  lands; the label says what the button does, and it stays centered whether or not the art resolves,
  so a missing icon leaves the button looking exactly as it did before.
- **The modal is one frame, reused.** Open it from window 1, close it, open it from window 2: it
  re-centers on window 2 and exports window 2's segment. A modal that exported the *first* window's
  segment from then on is the invoker not being re-stamped.
- **Esc closes it** (it is registered in `UISpecialFrames`), and so does the close button.
- **Open a selector (Metric, Channel or Lines), then press Esc instead of picking a row.** The modal
  closes AND the dropped menu closes with it — it must not stay floating over the game. The shared
  `LibKa0s-Widgets-1.0` popup is a process-wide singleton parented to `UIParent`, not to this modal,
  so `modules/Export.lua`'s `EnsureFrame` hooks the modal's `OnHide` to call `W.CloseMenu()` for
  exactly this path; a menu left behind here means that hook regressed.
- **The copy window that opens from Export to CSV** carries the same close icon in its own title bar,
  and its text is the bundled monospace face — a CSV is columns of digits and only lines up in one.
- Click **Metric**. A flat menu drops **directly under the button, left-aligned
  with it** — dark panel, no gold title bar. The current metric's row is **gold**;
  the rest are light gray. It looks like Bank Ledger's Data Set menu, not like a
  Blizzard right-click menu.
- Click outside the menu, on the modal behind it. It closes **and the click lands**
  on the modal in that same press; a right-click there does the same. *(Changed at
  LibKa0s v1.13.0, Widgets minor 5. The menu used to be dismissed by a full-screen
  `Button` that consumed the press — and, registering `LeftButtonUp` only, swallowed
  a right-click entirely — so dismissing cost a click that did nothing else.)*
- Pick a different metric. The menu closes, the button reads `Metric: <that one>`.
- Repeat for **Channel** and **Lines**. Same skin, same behaviour, in all three.
- **Open Metric, then click Channel without picking anything.** The Metric menu **closes** as the
  Channel menu drops: exactly one menu on screen, never two stacked. There is one popup frame in the
  whole client — `LibKa0s-Widgets-1.0`'s menu is a process-wide singleton shared by every dropdown
  in every Ka0s addon loaded — so opening a second dropdown re-points that one frame the way a
  native game menu does. Two menus at once would mean two popups exist, which no amount of exercising
  the three selectors *one at a time* (the line above) can show.
- **No row in any of these three menus carries a leading glyph**, and none should. `makeSelector` in
  `modules/Export.lua` passes no `opts.glyphFont`, which is correct rather than an omission to
  repair: the face is a precondition for an option that sets `glyph`, and none of this modal's
  options does. A row here showing a box or a stray character in front of its label means one grew a
  `glyph` without the mono face growing with it.
- Open the modal from a window sorted by **Healing**. Metric reads
  **`Metric: Healing`** before you touch anything — there is no
  "Match the window" entry any more, and there should not be one.
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
- Set **Channel: Whisper**. A fourth row appears below Lines, in the same flat
  box as the three above it, reading `Whisper to: ` in gold with an editable
  field beside it. **The modal grows by one row** — the red warning line and the
  two buttons move down with it, and nothing overlaps.
- Type a full name. The text is fully visible, not clipped at either end, and
  sits on the same baseline as the caption.
- Click **Print to Chat** without pressing Enter first. The dump is whispered:
  focus loss stores the name.
- Switch back to **Self only**. The row disappears and the modal shrinks back.
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

**The copy window is LibKa0s-Widgets-1.0's now** — the frame is built by the library from
a descriptor this addon passes, and the six steps below are the adoption check. Nothing above is
meant to change; a difference between the two lists is the bug.

1. `/mm` → open a meter window → Export → **Export to CSV**.
2. The copy window opens **centred on the meter window**, above the modal, with the CSV **already
   selected**.
3. Ctrl+C, paste into a text editor: the whole CSV, with its line breaks.
4. Esc closes the copy window and leaves the modal open.
5. Drag the meter window somewhere else, export again: the copy window follows it.
6. `/reload`, export again: still one window, still centred.

**Now check the file itself**, in a text editor or by pasting into a spreadsheet:

- **The header line is exactly 26 columns**, and it is:
  ```
  session,duration,name,class,spec,role,damage_done,damage_done_ps,damage_done_pct,healing_done,healing_done_ps,healing_done_pct,absorbs,absorbs_pct,interrupts,interrupts_pct,dispels,dispels_pct,damage_taken,damage_taken_pct,avoidable_damage_taken,avoidable_damage_taken_pct,deaths,deaths_pct
  ```
  Names are `snake_case`, **derived from the stat keys and never localized** — a German client must
  produce a file a colleague on an English client can open with the same formulas. Run one export on
  a non-English locale if you can and diff the header line against the one above: it must be
  byte-identical.
- **`_ps` appears twice and only twice**, on Damage and Healing — the two `isRate` stats. `_pct`
  appears once per stat, eight times.
- **Every stat in the catalog is present, not the window's columns.** Export from a window showing
  only Damage and confirm the CSV still carries all eight — the export is "the data", not "what is on
  screen". `enemy_damage_taken` is **not** among them and must not come back: it is read by the
  Targets tooltip section, but it is not a column and so not a CSV field (issue #2).
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
3. Only once that is clean, work outward: Say · Party · Raid · Instance · Guild · Whisper ·
   Whisper my target.

**Pass.**
- **Self prints to your own frame and reaches nobody.** Every line carries the cyan `[MM]` banner,
  because Self goes through `NS.Print` and not `SendChatMessage`. **A group member seeing anything on
  a Self export is a hard fail** and worth stopping on.
- **The shape is a header line then ranked lines:**
  ```
  Multi Meters — Damage — Current (2:14)
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
- **There is no Automatic channel.** It was removed as ambiguous: the dropdown offers Say, Party,
  Raid, Instance, Guild, Whisper and Self only, and nothing else. A profile that still held `AUTO`
  is folded to **Self only** by the v3 → v4 migration, so an upgraded install opens on Self rather
  than on a destination it picked for you.
- **Say outside an instance arrives whole, or the server says why.** Stand in a city, set Lines = 20
  and send: every line leaves inside the click, because Blizzard only permits `SAY` / `YELL` /
  `CHANNEL` from a hardware event out in the world, and the addon prints a one-line warning first
  saying the server may drop some of them. **Only the header arriving is the bug this replaced** —
  that was the staggered send, every line of which the server dropped silently.
- **Say INSIDE a dungeon or raid is staggered like every other channel**, because the hardware-event
  rule is lifted there. Twenty lines take about seven seconds and all twenty arrive.
- **A long dump pauses every fifth line.** Lines = 20 to Party: watch the timing — five quick lines,
  a beat, five more. That extra second per batch is what keeps the server's message counter from
  swallowing the tail.
- **Whisper** with a name in the box reaches that character and nobody else.
- **Whisper my target** takes the recipient off your current target instead of the box, and the box
  is hidden for it. Target a group member and send: they get it. Target a **cross-realm** member and
  confirm it still arrives — the name is read with its realm, and dropping the realm would whisper
  whoever holds that name on yours. With **nothing targeted** it says "You have no target to whisper
  to."; with a **boss or an NPC** targeted, "Your target is not a player." Neither sends anything,
  and neither may silently print to you instead.
- **The target is read at the click, not when the modal opened.** Open the modal with one target,
  switch targets, then send: it goes to the second.
- **Whisper to a name nobody is playing stops after the first line.** Type a nonsense name and send
  20 lines: the game answers with its own "No player named ... is currently playing", the addon says
  **"There is nobody called '...' to whisper to. The rest of the export was not sent."** once, and
  the remaining nineteen lines are dropped. Nineteen repeats of the game's error is the failure.
- **No line is truncated.** `SendChatMessage` cuts at 255 bytes; these are far under, but a very long
  NPC ally name on a percent-bearing line is the closest this ever gets.
- Send with a segment that has **no rows at all** (a fresh login, before any pull): nothing is sent
  and nothing errors.

#### What is remembered

**Steps.** Set Metric = Healing, Channel = Party, Lines = 20, and a whisper name. Close the modal.
`/reload`. Re-open it.

**Pass.**
- Channel, Lines and the whisper name come back exactly as you left them. They live at `export.*` in
  the **profile** and are **addon-wide**, not per window — "I print the top five to party" is a habit
  rather than a window's appearance. Metric is not among them: the modal always seeds it from the
  window it was opened from, so there is nothing to remember there.
- **The General page shows NO Export group.** The modal's own three controls are the only ones: a
  second copy on a settings page restated a control a player only ever meets in the dialog, and gave
  the two a chance to disagree about what is selected. The rows still exist and are marked `hidden`,
  which is what keeps the seam below working.
- `/mm get export.channel` and `/mm set export.lines 10` still work, and the modal follows them —
  set `/mm set export.lines 10` with the modal closed, re-open it and confirm it reads `Lines: 10`.
  A "no such setting" answer means the rows were deleted rather than hidden, which also drops every
  modal write onto the degraded fallback that skips validation and `CONFIG_CHANGED`.
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

### 27. The identity-correlation capture (issue #22)

**Why this one is different.** Every other scenario here checks that something *works*. This one
takes a **measurement**, and three of the numbers it exists for cannot be produced offline at any
effort: what the running client annotates plain on a raw source row, how many players share one
class+spec at raid size, and whether the engine's ordering of sources is stable. The headless suite
proves the report runs; only a raid can tell it what to say.

**Take it in the largest group you can get.** A 5-player dungeon will produce a clean-looking capture
and prove nothing — the whole finding is that the correlation works at party size and falls apart
above it. 20+ is where it starts to be worth reading; 30 is what the issue was filed on.

1. `/mm debug on` **before** the pull. The rectangle is built only while the flag is on.
2. Pull. Roughly ten seconds in, `/mm debug identity`.
3. Wait ~15 seconds, still in combat, and run `/mm debug identity` **again**. Two captures is the
   ordering probe; one proves nothing about stability.
4. **After combat ends, run `/mm debug identity` once more.** Out of combat nothing is secret, so
   this is the only capture that can fill in the `values` column for fields that read `SECRET`
   mid-pull — which is how a candidate field gets settled either way. The `ABSENT` and `PARTIAL`
   lines hold in both states.
5. `/mm debug` to open the console and copy the whole buffer.

**What to read in it, and what each answer would mean:**

- **`unmatched` above zero in any column.** This is the fault the instrumentation was built to find:
  the column named a key and still produced no cell, which would mean a field the correlation trusts
  is less stable across columns than it looks. Report it with the column name — it is the highest
  value line in the whole capture.
- **`collided` dominating, `unmatched` zero.** The expected shape, and it says the blanking is
  working correctly and the *key* is the problem. Compare `collidedRows` against `rows`: that ratio,
  not the key count, is what bounds any fix.
- **`rows per key`.** Anything past "worn by 1 row" is a key blanking cells for every row wearing it.
- **A `PARTIAL` line.** A field the client sends for some rows and not others — the state a one-row
  probe had no word for. `specIconID` is the known case ([#24](https://github.com/tusharsaxena/MultiMeters/issues/24));
  report any *other* field that reads PARTIAL, with its `rows` count.
- **An `ABSENT` line.** A field the addon reads that the client does not send at all. Report these
  first: they are defects rather than facts about the client, and they are nil out of combat too.
- **A `WOULD widen the key` line in the field audit.** A plain field outside the key that actually
  *varies* across players. This is the single most valuable thing the capture can come back with,
  because it is the only one of the three directions that costs a player nothing — report the field
  name and its `values` count. `No usable candidates` is equally worth reporting: it retires that
  direction permanently. A field marked `no use as a key` carries one value for the whole group;
  don't chase it.
- **The seats of a collided key, across the two captures.** If a key's sources hold the same relative
  order in every column *and* in both captures, positional pairing is at least possible. If they move
  between captures, that direction is dead and should be recorded as such.

**What would make the capture worthless:** running it out of combat (there is no identity pass — the
GUID join is exact, and the report will say `no identity pass has been measured`), running it with
the debug flag off (same message, different cause — the report does not distinguish, and does not
pretend to), or running it in a party. None of the three raise; all three produce a clean-looking
nothing.

**Record for the report:** group size and composition (specifically, which class+spec pairs were
duplicated), instance and difficulty, both captures in full, and whether any Lua error appeared —
the probe walks a raw source row with `pairs`, which is the one thing here that touches a shape the
mock can only approximate.

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
