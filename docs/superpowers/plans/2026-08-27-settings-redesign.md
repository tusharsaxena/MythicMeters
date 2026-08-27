# Settings Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace MultiMeters' nine flat settings scrolls with tabbed pages carrying a window banner, on shapes the Ka0s standard defines and `LibKa0s-Options-1.0` implements.

**Architecture:** Three repos in strict dependency order. `WowAddonStandards` gains the tabbed-page and page-banner patterns so the code is conformant on its first commit. `LibKa0s-Options-1.0` gains a **chrome slot** — a reserved band between the page header and the scroll — plus `PageBanner`, `TabStrip` and `RenderTabbedSchema` built on it; a page that reserves no chrome renders byte-identically to today, which is what lets the other eight consumers re-vendor without a pixel moving. MultiMeters then regroups its 137 schema rows onto those shapes, renames one path, converts two booleans to colour-mode dropdowns, and deletes its own window picker in favour of the banner.

**Tech Stack:** Lua 5.1 (WoW client), AceGUI-3.0 via LibStub, AceDB-3.0, LibKa0s (`Core`, `Options`, `OptionsWidgets`, `OptionsScroll`, `Widgets`, `Slash`, `Media`), the vendored `tests/_kit` headless harness, `luacheck`, `lizard`.

**Spec:** `docs/superpowers/specs/2026-08-27-settings-redesign-design.md`

## Global Constraints

- **Repo order is absolute.** Standards → LibKa0s (tagged) → MultiMeters. The addon does not start until the library carries a git tag.
- **Branches, already created:** `options-tabbed-pages` in `../WowAddonStandards` and `../LibKa0s`; `settings-redesign` in `MultiMeters`.
- **Green gate before every commit, in whichever repo you are in:** `lua tests/run.lua` and `luacheck .` at **0 warnings / 0 errors**.
- **Complexity gate: zero functions above CCN 15** (`automated-tests-§3`). The release task runs the full battery and refuses to tag on a breach, so **every task that adds or grows a function verifies it at the time**, not at the end:
  ```sh
  python3 -m lizard -l lua -C 15 <the file you changed> | tail -20
  ```
  A clean run prints no warning block. Paste the output into your report — the number, not an expectation. For calibration in `OptionsWidgets.lua`: `RenderRows` is CCN 9 and `RenderField` is CCN 7, so anything near 15 is an outlier worth splitting into a file-local before it is committed.
- **Never auto-stage, auto-commit or auto-push outside the commit steps written here**, and never bump a version except where a step says to.
- **Non-ASCII is a byte escape, never a literal.** The collection writes `\226\128\148` for an em dash; this plan introduces `\226\128\186` for `›`. A literal depends on the file's encoding surviving every editor between here and a client.
- **Line endings are CRLF** in both repos (`.gitattributes` enforces it; `tests/test_eol.lua` in LibKa0s and the addon's lint check it).
- **`lib.LAYOUT` keys must be either published on the instance or carry an `-- INTERNAL: <KEY> — <reason>` comment with at least 30 characters of reason.** `tests/test_options.lua` fails naming any key that is neither, and fails again for any key that is both.
- **LibKa0s is additive-only.** No existing published member changes signature or behaviour. A page that calls nothing new must render exactly as it does today.
- **Every LibKa0s file you edit gets its minor bumped**, its `CHANGELOG.md` entry, and an API document for its major — `tests/test_versioning.lua` fails until the document exists.
- **MultiMeters row shape:** a schema row's `page` is where it is edited and its `path` is where it is stored, and the two are allowed to disagree.

---

## File Structure

**`../WowAddonStandards`**
- Modify: `standards/standards/options-ui.md` — add §13, §14; amend §7
- Modify: `standards/STANDARDS.md` — options-ui blurb, version history, version bump

**`../LibKa0s`**
- Modify: `LibKa0s/Options.lua` — `lib.LAYOUT` keys, instance publishing, `ctx.chrome` in `CreatePanel`, `O.SetChromeHeight`, `O.EnsureScroll` re-anchor, `O.ClearScroll` chrome reset, `MINOR`
- Modify: `LibKa0s/OptionsWidgets.lua` — `O.__layoutTabs`, `O.TabStrip`, `O.PageBanner`, `O.RenderTabbedSchema`, heading suppression in `O.RenderRows`, `WIDGETS_MINOR`
- Modify: `tests/test_options.lua` — chrome slot cases
- Modify: `tests/test_options_widgets.lua` — strip, banner, tabbed-schema cases
- Modify: `tests/fixture_options.lua` — a third page with four groups, for the strip
- Create: `docs/api/Options/version-10.9.3-docs.md`
- Modify: `docs/api/README.md`, `CHANGELOG.md`, `docs/releasing.md`, `docs/test-cases.md`

**`MultiMeters`**
- Modify: `libs/LibKa0s/**` — re-vendored payload (copy, never hand-edited)
- Modify: `settings/Schema.lua` — every row's `page`/`group`, declaration order, the rename, the two colour-mode rows
- Modify: `core/Database.lua` — `CURRENT_DB_VERSION` 12 → 13, `migrations[12]`
- Modify: `defaults/Profile.lua` — renamed key, two new keys, two deleted keys
- Modify: `modules/HeaderControls.lua` — reads a mode, not a flag
- Modify: `settings/Frame.lua`, `Header.lua`, `Bars.lua`, `Tooltip.lua`, `Visibility.lua` — banner + tabbed render
- Modify: `settings/Columns.lua` — banner, tabs, the two column-header groups
- Modify: `settings/General.lua` — tabs
- Modify: `settings/Windows.lua` — banner replaces the picker
- Modify: `settings/OptionsSetup.lua` — forward the four new members onto `NS.Helpers`
- Modify: `settings/Slash.lua` — `groupKey` becomes page › tab
- Modify: `locales/enUS.lua` — new group names and strings
- Modify: `tests/test_schema.lua`, `test_schema_defaults.lua`, `test_options_panel.lua`, `test_headercontrols.lua`, `test_database.lua`, `test_slash.lua`
- Modify: `docs/settings-panel.md`, `docs/schema.md`, `docs/ARCHITECTURE.md`, `docs/common-tasks.md`, `README.md`

---

# Part A — the standard

### Task 1: Define the tabbed page and the page banner

**Files:**
- Modify: `../WowAddonStandards/standards/standards/options-ui.md` (append after §12; amend §7 at line 109)
- Modify: `../WowAddonStandards/standards/STANDARDS.md` (options-ui blurb ~line 60; version history ~line 98)

**Interfaces:**
- Consumes: nothing.
- Produces: the section numbers `options-ui-§13` and `options-ui-§14`, cited by name in every LibKa0s and MultiMeters comment that follows.

- [ ] **Step 1: Amend §7 so a tabbed page may suppress its headings**

In `options-ui.md`, replace the first sentence of `### 7. Section headers`:

```
Options **MUST** be grouped under **section headers** rendered as an AceGUI **`Heading`**
```

with:

```
Options on an **untabbed** page **MUST** be grouped under **section headers** rendered as an
AceGUI **`Heading`**
```

and append this paragraph to the end of §7:

```markdown
On a **tabbed** page (options-ui-§13) the tab label carries the section's name, so the heading
is suppressed: drawing a `Heading` that repeats the tab the user just clicked is the same label
twice. The `group` field still declares the section either way — what changes is where it is
drawn, never who declares it.
```

- [ ] **Step 2: Add §13**

Append to `options-ui.md`:

```markdown
### 13. Tabbed pages

A page whose rows exceed what one scroll can present **MAY** render its sections as a **tab
strip** pinned above the scroll instead of as a sequence of section headings inside it.

- **One tab per section, always.** A tab **MUST NOT** hold several sections and a section
  **MUST NOT** span several tabs. The tab label *is* the section name, so the two cannot drift
  and the flow engine's existing `group` field stays the single declaration of both. A second
  field naming a tab is a second selector to keep in step (options-ui-§1's reasoning against a
  separate `widget` field, arriving one layer up).
- **The strip wraps.** When the labels exceed one row it **MUST** wrap to a second, never
  truncate, scroll horizontally, or shrink a label. A page **SHOULD** hold its section count low
  enough for one row at default UI scale; a wrapped second row is permitted and is not a defect.
- **Switching tabs is a structural re-render** — the same path a change of subject takes — so it
  inherits options-ui-§2's combat refusal rather than declaring its own. A host **MUST NOT**
  write a second combat guard for it.
- **The active tab is session state, per page, and MUST NOT be persisted.** A stored tab is UI
  position masquerading as a setting: it makes one page look different to two characters on one
  account for a reason the player never asked for, and it turns a cosmetic default into a
  migration the day the sections are renamed.
- **The per-page Defaults button stays page-wide.** Its label and its position do not change, so
  its blast radius **MUST NOT** narrow to the visible tab. A button whose meaning quietly shrank
  is the failure options-ui-§12 spends its whole length preventing at the global scale.
```

- [ ] **Step 3: Add §14**

Append to `options-ui.md`:

```markdown
### 14. The page banner

A page that edits **one selected instance out of many** — a window, a unit, a profile — **MUST**
say which one, in a **banner** pinned above the strip and the scroll. Six pages that silently
retarget when a picker elsewhere moves is the panel lying about what a click will change.

- **The banner carries the picker itself**, not a read-only label. A player who can see which
  instance they are editing and cannot change it from there has been told about the problem
  rather than given the fix.
- **The banner is the ONLY picker.** Where a page already carried one for the same state, that
  picker **MUST** be deleted rather than kept in step: one writer, one control class, and no
  propagation code. The banner re-reads the pointer at render time, and the structural refresh
  the write already triggers re-renders every panel — so two banners cannot disagree, because
  there is only ever one value.
- **The selection survives a tab switch and a page change.** Changing instance from a sub-page
  **MUST** leave the active tab alone: comparing one surface across two instances is the reason
  to switch from a sub-page at all, and resetting the tab defeats exactly that.
```

- [ ] **Step 4: Update the index and the version history**

In `STANDARDS.md`, extend the options-ui bullet (~line 60) — append to the existing sentence:

```
; and **tabbed pages** with a **page banner** — one tab per section, a strip that wraps rather
than truncates, a session-only active tab, and a banner that is the only picker for the instance
the page edits.
```

Add a version-history entry at the top of the list, bumping the version to **v2.37.0**:

```markdown
- **v2.37.0 (2026-08-27):** **options-ui-§13 and §14 — the tabbed page and the page banner.**
  MultiMeters' settings had reached 137 rows over nine pages with a one-control section, a
  fifteen-control section, and six pages that edit whichever window a picker two pages up has
  selected without saying so. Both rules are written narrow. §13 fixes **one tab per section**
  rather than letting a tab hold a themed bundle, because the moment a tab is its own container
  it needs its own declaration and the `group` field stops being the single statement of what a
  section is. §14 requires the banner to **replace** an existing picker rather than mirror it,
  because two controls over one piece of session state is a synchronisation problem invented by
  the design that then has to be solved forever. §7 becomes conditional in the same release: a
  tabbed page's heading is its tab.
```

- [ ] **Step 5: Verify the section numbering is unbroken**

Run:

```sh
cd ../WowAddonStandards && grep -n '^### [0-9]' standards/standards/options-ui.md
```

Expected: a contiguous run `### 1.` through `### 14.`, with no repeats and no gaps.

- [ ] **Step 6: Commit**

```sh
cd ../WowAddonStandards
git add standards/standards/options-ui.md standards/STANDARDS.md
git commit -m "Standard v2.37.0: the tabbed page and the page banner

options-ui-§13 fixes one tab per section rather than a themed bundle,
so the group field stays the single statement of what a section is.
§14 requires the banner to replace an existing picker rather than
mirror it: two controls over one piece of session state is a
synchronisation problem the design invented and would then own
forever. §7 becomes conditional in the same release, because a tabbed
page's heading is its tab."
```

---

# Part B — `LibKa0s-Options-1.0`

### Task 2: The chrome slot

**Files:**
- Modify: `../LibKa0s/LibKa0s/Options.lua` — `lib.LAYOUT` (line ~58), instance publishing (line ~222), `O.CreatePanel` (line 265), `O.EnsureScroll` (line 369), `O.ClearScroll` (line 404)
- Test: `../LibKa0s/tests/test_options.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `ctx.chrome` — a `Frame` parented to `ctx.body`, pinned across its top edge.
  - `ctx.chromeHeight` — number, pixels of reserved band; `0` on a fresh panel.
  - `O.SetChromeHeight(ctx, height)` — sets both and re-anchors an existing scroll.
  - `O.__scrollTopInset(ctx)` → number — the scroll's top offset; `CHROME_GAP` plus the reserved band.
  - `O.CHROME_GAP`, `O.TAB_H`, `O.BANNER_H` — published layout scalars.

- [ ] **Step 1: Write the failing tests**

Append to `../LibKa0s/tests/test_options.lua`:

```lua
-- ── the chrome slot ────────────────────────────────────────────────────────────────────────

test("options: a fresh panel reserves no chrome, so its scroll sits where it always did",
function()
  -- The whole additive bargain rests on this number. Eight consumers re-vendor this file
  -- without adopting anything new, and a non-zero default would move every one of their
  -- panels' first row by however many pixels the band happened to reserve.
  -- red under: defaulting chromeHeight to anything but 0, or folding the band into CHROME_GAP.
  local O = Fixture.new()
  local ctx = O.CreatePanel("ChromeFresh", "Chrome Fresh", {})
  assertEqual(ctx.chromeHeight, 0)
  assertTrue(ctx.chrome ~= nil, "the slot frame exists even when nothing is in it")
  assertEqual(O.__scrollTopInset(ctx), O.CHROME_GAP)
end)

test("options: reserving chrome pushes the scroll down by exactly that many pixels", function()
  -- red under: adding a second gap under the band, or reserving the band twice.
  local O = Fixture.new()
  local ctx = O.CreatePanel("ChromeReserve", "Chrome Reserve", {})
  O.SetChromeHeight(ctx, 40)
  assertEqual(ctx.chromeHeight, 40)
  assertEqual(O.__scrollTopInset(ctx), O.CHROME_GAP + 40)
end)

test("options: reserving chrome AFTER the scroll exists re-anchors the live scroll", function()
  -- A page draws its banner and its strip, then renders rows -- but a strip that WRAPS only
  -- learns its own height after it has laid out, which is after EnsureScroll may already have
  -- run for a previous render. A ctx that stored the number without moving the frame would put
  -- the second row of tabs underneath the first row of widgets.
  -- red under: storing chromeHeight without re-anchoring, or re-anchoring only the TOPLEFT.
  local O = Fixture.new()
  local ctx = O.CreatePanel("ChromeLate", "Chrome Late", {})
  local scroll = O.EnsureScroll(ctx)

  local points = {}
  rawset(scroll.frame, "SetPoint", function(_, ...) points[#points + 1] = { ... } end)
  rawset(scroll.frame, "ClearAllPoints", function() points[#points + 1] = { "CLEARED" } end)

  O.SetChromeHeight(ctx, 52)

  assertEqual(points[1][1], "CLEARED", "the old anchors go before the new ones land")
  assertEqual(points[2][1], "TOPLEFT")
  assertEqual(points[2][5], -(O.CHROME_GAP + 52), "the top inset carries the reserved band")
  assertEqual(points[3][1], "BOTTOMRIGHT", "the bottom anchor is restored, not dropped")

  rawset(scroll.frame, "SetPoint", nil)
  rawset(scroll.frame, "ClearAllPoints", nil)
end)

test("options: ClearScroll leaves the reserved band alone", function()
  -- ClearScroll releases the page's ROWS. The banner and the strip are chrome, they are not in
  -- the scroll, and a reset here would drop the band on every re-render -- so the first tab
  -- click on any tabbed page would slide the whole page up under its own strip.
  -- red under: adding ctx.chromeHeight = 0 to ClearScroll alongside ctx.lastGroup = nil.
  local O = Fixture.new()
  local ctx = O.CreatePanel("ChromeClear", "Chrome Clear", {})
  O.EnsureScroll(ctx)
  O.SetChromeHeight(ctx, 24)
  O.ClearScroll(ctx)
  assertEqual(ctx.chromeHeight, 24)
end)
```

- [ ] **Step 2: Run them and confirm they fail**

```sh
cd ../LibKa0s && lua tests/run.lua 2>&1 | tail -20
```

Expected: FAIL — four cases, the first raising on `O.__scrollTopInset` being nil.

- [ ] **Step 3: Add the layout keys**

In `LibKa0s/Options.lua`, inside `lib.LAYOUT`, after `BUTTON_PAIR_REL`:

```lua
  -- The gap between the bottom of the pinned chrome band (options-ui-§13/§14) and the top of
  -- the scroll. Equal to the literal 8 EnsureScroll used before the band existed, so a page
  -- that reserves nothing anchors its scroll exactly where it always did. PUBLISHED as
  -- O.CHROME_GAP: a host drawing bespoke chrome of its own has to know where its band ends.
  CHROME_GAP    = 8,
  -- Height of one row of tabs. PUBLISHED as O.TAB_H: a host that measures its own strip -- to
  -- reserve the band before drawing into it -- has no other way to read the number.
  TAB_H         = 24,
  -- Height of the page banner. PUBLISHED as O.BANNER_H, same reason as TAB_H.
  BANNER_H      = 30,
  -- INTERNAL: TAB_PAD_X — horizontal padding inside one tab, consumed by O.TabStrip when it
  -- sizes a button around its measured label; no host draws a tab itself.
  TAB_PAD_X     = 12,
  -- INTERNAL: TAB_GAP — horizontal gap between two tabs on one row, consumed by O.TabStrip and
  -- by O.__layoutTabs; a host that needed it would be laying out its own strip.
  TAB_GAP       = 4,
  -- INTERNAL: TAB_MIN_W — floor width of one tab, and the width every tab takes when the label
  -- cannot be measured (a headless harness, a font not yet loaded); never read by a host.
  TAB_MIN_W     = 60,
  -- INTERNAL: TAB_ROW_GAP — vertical gap between two wrapped rows of tabs, consumed by
  -- O.TabStrip alone; a host reads the finished band height off O.TAB_H instead.
  TAB_ROW_GAP   = 2,
```

- [ ] **Step 4: Publish the three scalars**

In `LibKa0s/Options.lua`, after line 225 (`O.BUTTON_PAIR_REL = L.BUTTON_PAIR_REL`):

```lua
  O.CHROME_GAP        = L.CHROME_GAP
  O.TAB_H             = L.TAB_H
  O.BANNER_H          = L.BANNER_H
```

- [ ] **Step 5: Build the slot in `CreatePanel`**

In `O.CreatePanel`, immediately after `panel.body = body`:

```lua
    -- The chrome slot (options-ui-§13, §14): pinned page furniture between the header and the
    -- scroll. A frame rather than a bare number because a banner and a strip need something to
    -- parent to that a page-wide release can empty; the NUMBER is what moves the scroll, and it
    -- starts at zero so a page that reserves nothing is byte-identical to one built before the
    -- slot existed.
    local chrome = CreateFrame("Frame", nil, body)
    chrome:SetPoint("TOPLEFT",  body, "TOPLEFT",  L.PADDING_X, 0)
    chrome:SetPoint("TOPRIGHT", body, "TOPRIGHT", -L.PADDING_X, 0)
    panel.chrome = chrome
```

and add two fields to the `ctx` literal, after `pageKey = opts.pageKey,`:

```lua
      chrome       = chrome,
      chromeHeight = 0,
```

- [ ] **Step 6: Add the inset helper and `SetChromeHeight`**

In `LibKa0s/Options.lua`, immediately before `function O.EnsureScroll(ctx)`:

```lua
  --- Where the scroll's top edge sits: the fixed gap plus whatever the page reserved.
  ---
  --- A named seam rather than the sum written out at both call sites, because the two sites are
  --- EnsureScroll (first render) and SetChromeHeight (every render after a strip wrapped), and
  --- a page whose two answers disagreed would move its own first row on the second render.
  function O.__scrollTopInset(ctx)
    return L.CHROME_GAP + ((ctx and ctx.chromeHeight) or 0)
  end

  --- Anchor a page's scroll under whatever chrome the page reserved.
  ---
  --- BOTH anchors in one place, not just the top one. EnsureScroll and SetChromeHeight each need
  --- the full pair -- the second re-anchors a LIVE scroll -- and a bottom inset restated at two
  --- sites is the same drift __scrollTopInset exists to prevent, one edge over.
  local function anchorScroll(O, ctx)
    local f = ctx.scroll and ctx.scroll.frame
    if not f then return end
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT",     ctx.body, "TOPLEFT",      L.PADDING_X - 4, -O.__scrollTopInset(ctx))
    f:SetPoint("BOTTOMRIGHT", ctx.body, "BOTTOMRIGHT", -(L.PADDING_X + 12), 8)
  end

  --- Reserve `height` pixels of pinned furniture above the scroll, and move a live scroll to
  --- match. Idempotent: reserving the same height twice reserves it once.
  function O.SetChromeHeight(ctx, height)
    if not ctx then return end
    ctx.chromeHeight = tonumber(height) or 0
    if ctx.chrome and ctx.chrome.SetHeight then
      -- Zero is not a height a frame can hold, and a slot with nothing in it has nothing to
      -- show anyway, so the frame is hidden rather than sized to nothing.
      if ctx.chromeHeight > 0 then
        ctx.chrome:SetHeight(ctx.chromeHeight)
        ctx.chrome:Show()
      else
        ctx.chrome:Hide()
      end
    end
    anchorScroll(O, ctx)
  end
```

- [ ] **Step 7: Re-anchor `EnsureScroll`**

In `O.EnsureScroll`, replace **both** anchor lines with the shared helper:

```lua
    ctx.scroll = scroll          -- anchorScroll reads ctx.scroll, so assign before anchoring
    anchorScroll(O, ctx)
```

Adjust to the surrounding code's shape — if `O` is already an upvalue there, drop the parameter.
What matters is that **each anchor value is written once**. `EnsureScroll` previously set points on
a freshly created frame without clearing; routing through the helper adds a `ClearAllPoints` on a
new frame, which is harmless — note it in the report so the reviewer is not surprised.

- [ ] **Step 8: Run the tests**

```sh
cd ../LibKa0s && lua tests/run.lua 2>&1 | tail -20
```

Expected: PASS, all four new cases plus every pre-existing one — especially `test_options.lua`'s published-or-annotated case, which now walks seven more keys.

- [ ] **Step 9: Lint**

```sh
cd ../LibKa0s && luacheck .
```

Expected: `0 warnings / 0 errors`.

- [ ] **Step 10: Commit**

```sh
cd ../LibKa0s
git add LibKa0s/Options.lua tests/test_options.lua
git commit -m "Options: reserve a chrome slot between the header and the scroll

A banner and a tab strip have to be pinned -- furniture that scrolls
away has stopped saying which window you are editing by the time you
reach the control that needs it -- and there was nowhere to put them:
EnsureScroll anchored the ScrollFrame straight to the body's top edge.

The band is a frame to parent to and a NUMBER that moves the scroll,
and the number starts at zero. That is the whole additive bargain: the
eight consumers that re-vendor this file without adopting anything new
get a scroll anchored exactly where it was."
```

---

### Task 3: `O.__layoutTabs` and `O.TabStrip`

**Files:**
- Modify: `../LibKa0s/LibKa0s/OptionsWidgets.lua` — after `O.Section` (line ~415)
- Test: `../LibKa0s/tests/test_options_widgets.lua`

**Interfaces:**
- Consumes: `ctx.chrome`, `O.SetChromeHeight(ctx, h)`, `O.TAB_H`, `lib.LAYOUT.TAB_GAP/TAB_PAD_X/TAB_MIN_W/TAB_ROW_GAP`.
- Produces:
  - `O.__layoutTabs(widths, available, gap)` → `number[][]` — rows of 1-based indices into `widths`.
  - `O.TabStrip(ctx, spec)` → `table[]|nil` — the button frames in tab order. `spec = { tabs = { { key, label, tooltip } }, value, onSelect }`. `onSelect` is called as `onSelect(key)` and is `pcall`ed.

- [ ] **Step 1: Write the failing tests**

Append to `../LibKa0s/tests/test_options_widgets.lua`:

```lua
-- ── the tab strip ──────────────────────────────────────────────────────────────────────────

test("widgets: tab packing fills a row and wraps to the next", function()
  -- Pure arithmetic, deliberately: the wrap rule is the part that decides whether a page's
  -- strip is one row or two, and a rule that can only be checked against a measured font is a
  -- rule nothing checks.
  -- red under: counting the gap before the first tab of a row, or comparing with >=.
  local O = Fixture.new()
  local rows = O.__layoutTabs({ 60, 60, 60 }, 150, 4)
  assertEqual(#rows, 2, "60+4+60 = 124 fits in 150; a third would need 188, so it wraps")
  assertEqual(#rows[1], 2)
  assertEqual(rows[1][1], 1)
  assertEqual(rows[1][2], 2)
  assertEqual(#rows[2], 1)
  assertEqual(rows[2][1], 3)
end)

test("widgets: a tab wider than the strip gets its own row rather than vanishing", function()
  -- The split only happens when the row already holds something, so an over-wide tab is
  -- always placed. A rule that dropped it would lose a whole section with no error.
  -- red under: splitting unconditionally, which loops forever or drops the tab.
  local O = Fixture.new()
  local rows = O.__layoutTabs({ 500 }, 200, 4)
  assertEqual(#rows, 1)
  assertEqual(rows[1][1], 1)

  local mixed = O.__layoutTabs({ 60, 500, 60 }, 200, 4)
  assertEqual(#mixed, 3, "the over-wide tab neither joins a row nor absorbs the next")
end)

test("widgets: an empty tab list lays out as no rows at all", function()
  -- red under: seeding the loop with an empty first row and returning it.
  local O = Fixture.new()
  assertEqual(#O.__layoutTabs({}, 200, 4), 0)
end)

test("widgets: TabStrip draws one button per tab, marks the active one, and reserves the band",
function()
  -- red under: reserving TAB_H before knowing the row count, or forgetting to reserve at all.
  local O, rec, ctx = bench()
  local picked = {}
  local buttons = O.TabStrip(ctx, {
    tabs = {
      { key = "one",   label = "One" },
      { key = "two",   label = "Two" },
      { key = "three", label = "Three" },
    },
    value = "two",
    onSelect = function(key) picked[#picked + 1] = key end,
  })

  assertEqual(#buttons, 3)
  assertEqual(buttons[1].__template, nil, "tabs are raw Buttons, not a Blizzard template")
  assertFalse(buttons[2]:IsEnabled(), "the active tab is the disabled one, as Blizzard marks a tab")
  assertTrue(buttons[1]:IsEnabled())
  assertTrue(ctx.chromeHeight >= O.TAB_H, "the strip reserved its own band")

  buttons[3]:__fire("OnClick")
  assertEqual(#picked, 1)
  assertEqual(picked[1], "three")
  assertEqual(rec, rec, "no store write: a tab is not a setting")
end)

test("widgets: clicking the ACTIVE tab does not re-fire onSelect", function()
  -- A re-render on every click of the tab you are already on is a page that flickers for
  -- nothing, and on a host whose renderer refuses in combat it is a refusal message for
  -- nothing.
  -- red under: wiring OnClick before checking the active key.
  local O, _, ctx = bench()
  local fired = 0
  local buttons = O.TabStrip(ctx, {
    tabs = { { key = "a", label = "A" }, { key = "b", label = "B" } },
    value = "a",
    onSelect = function() fired = fired + 1 end,
  })
  buttons[1]:__fire("OnClick")
  assertEqual(fired, 0)
  buttons[2]:__fire("OnClick")
  assertEqual(fired, 1)
end)

test("widgets: a second TabStrip call replaces the first rather than stacking on it", function()
  -- A strip is redrawn whenever the page's subject changes. Leaving the old buttons parented to
  -- the chrome would stack two strips, with only the newer one wired up -- and the older one on
  -- top, swallowing the clicks.
  -- red under: creating buttons without releasing the previous set.
  local O, _, ctx = bench()
  O.TabStrip(ctx, { tabs = { { key = "a", label = "A" } }, value = "a", onSelect = function() end })
  local second = O.TabStrip(ctx, {
    tabs = { { key = "a", label = "A" }, { key = "b", label = "B" } },
    value = "b", onSelect = function() end,
  })
  assertEqual(#second, 2)
  assertEqual(#ctx.__chromeKids, 2, "the first strip's button was released, not orphaned")
end)

test("widgets: TabStrip refuses politely with no AceGUI and with no tabs", function()
  -- Every maker in this file answers nil having drawn nothing rather than raising, because the
  -- degraded path is a real one: a consumer vendored without AceGUI must show a plain page.
  -- red under: indexing spec.tabs before checking it.
  withoutAceGUI(function()
    local O, _, ctx = bench()
    assertNil(O.TabStrip(ctx, { tabs = { { key = "a", label = "A" } } }))
  end)

  local O2, _, ctx2 = bench()
  assertNil(O2.TabStrip(ctx2, { tabs = {} }))
  assertNil(O2.TabStrip(ctx2, nil))
end)
```

Add this helper alongside `bench` at the top of `tests/test_options_widgets.lua` — the three
degraded-path cases in Tasks 3, 4 and 5 all use it:

```lua
--- Run `fn` with AceGUI absent, restoring it afterwards.
---
--- The instance resolves AceGUI ONCE, at New() time (`LibKa0s/Options.lua:217`), so the library
--- has to be built INSIDE this: flipping the mock after Fixture.new leaves the instance holding
--- the handle it already resolved, and the degraded path never runs. Save-and-restore rather
--- than assign-and-hope, copied from `tests/test_options.lua`'s own missing-AceGUI case.
local function withoutAceGUI(fn)
  local saved = T.mocks.__libs["AceGUI-3.0"]
  T.mocks.__libs["AceGUI-3.0"] = nil
  local ok, err = pcall(fn)
  T.mocks.__libs["AceGUI-3.0"] = saved
  if not ok then error(err) end
end
```

- [ ] **Step 2: Add the `withoutAceGUI` helper**

Add the helper shown above next to `bench` in `tests/test_options_widgets.lua`. **Do not add an override to `tests/fixture_options.lua`** — `Fixture.new`'s `overrides` are merged into the *descriptor* (`fixture_options.lua:173`), and `O.AceGUI` does not come from the descriptor; it is resolved from LibStub inside `New()`. An `aceGUI = false` override would set a descriptor field nothing reads and the test would silently exercise the normal path.

- [ ] **Step 3: Run and confirm failure**

```sh
cd ../LibKa0s && lua tests/run.lua 2>&1 | tail -20
```

Expected: FAIL on `O.__layoutTabs` being nil.

- [ ] **Step 4: Implement both**

In `LibKa0s/OptionsWidgets.lua`, after `O.Section`:

```lua
  --- Pack tab widths into rows that fit `available`. Pure arithmetic and no widgets, so the
  --- wrap rule -- the thing that decides whether a page's strip is one row or two -- is
  --- checkable without a measured font.
  ---
  --- A tab wider than the whole strip is placed alone rather than dropped: the split only fires
  --- when the row already holds something, so every index in `widths` comes back in exactly one
  --- row. Losing one would lose a whole section of a page with nothing said about it.
  ---
  --- @param widths number[]    each tab's pixel width, in tab order
  --- @param available number   usable width of the strip
  --- @param gap number         horizontal gap between two tabs sharing a row
  --- @return number[][]        rows of 1-based indices into `widths`, in order
  function O.__layoutTabs(widths, available, gap)
    local rows, row, used = {}, {}, 0
    for i = 1, #widths do
      local need = (#row > 0) and (gap + widths[i]) or widths[i]
      if #row > 0 and used + need > available then
        rows[#rows + 1] = row
        row, used, need = {}, 0, widths[i]
      end
      row[#row + 1] = i
      used = used + need
    end
    if #row > 0 then rows[#rows + 1] = row end
    return rows
  end

  --- Release whatever the page last parked in its chrome band.
  ---
  --- The band is redrawn whole on every render, so the previous set has to go: buttons left
  --- parented to the chrome stack under the new ones, and the OLD set is on top -- so the strip
  --- looks right and every click lands on a handler wired to the previous subject.
  local function releaseChrome(ctx)
    for _, f in ipairs(ctx.__chromeKids or {}) do
      f:Hide()
      f:SetParent(nil)
    end
    ctx.__chromeKids = {}
  end
  O.__releaseChrome = releaseChrome

  --- Measure a label, in pixels, or fall back to the floor width.
  ---
  --- Guarded twice over. A FontString may not be there at all (an inert widget in a headless
  --- harness), and a mock's catch-all metatable answers a capitalized call with the frame
  --- itself -- so a `GetStringWidth` that "worked" could still hand back a table, and the
  --- arithmetic below would raise inside a layout pass. Type-check the answer, not the method.
  local function labelWidth(fs)
    if not (fs and fs.GetStringWidth) then return L.TAB_MIN_W end
    local w = fs:GetStringWidth()
    if type(w) ~= "number" or w <= 0 then return L.TAB_MIN_W end
    return math.max(L.TAB_MIN_W, w + (L.TAB_PAD_X * 2))
  end

  --- A pinned tab strip in the page's chrome band (options-ui-§13). One tab per section.
  ---
  --- The ACTIVE tab is the DISABLED one, which is how Blizzard's own tab groups mark selection
  --- and is why it needs no second piece of art to say so: a disabled button does not highlight
  --- on hover and does not fire, so clicking the tab you are already on cannot re-render the
  --- page you are already looking at.
  ---
  --- `spec` = { tabs = { { key, label, tooltip } }, value, onSelect }. Returns the buttons in
  --- tab order, or nil having drawn nothing.
  function O.TabStrip(ctx, spec)
    if not (ctx and ctx.chrome and spec and type(spec.tabs) == "table" and #spec.tabs > 0) then
      return nil
    end
    if not O.AceGUI then return nil end

    releaseChrome(ctx)

    local buttons, widths = {}, {}
    for i, tab in ipairs(spec.tabs) do
      local b = CreateFrame("Button", nil, ctx.chrome)
      b:SetHeight(L.TAB_H)
      b:SetNormalFontObject(_G.GameFontNormalSmall)
      b:SetHighlightFontObject(_G.GameFontHighlightSmall)
      b:SetDisabledFontObject(_G.GameFontHighlightSmall)
      b:SetText(tab.label or "")

      -- A flat backing rather than a Blizzard tab atlas. The art is deliberately minimal here;
      -- what the strip owes the page is a readable active/inactive distinction, and the atlas
      -- question is one for a live client rather than for this file.
      local bg = b.CreateTexture and b:CreateTexture(nil, "BACKGROUND")
      if bg and bg.SetColorTexture then
        bg:SetAllPoints(b)
        bg:SetColorTexture(0, 0, 0, (tab.key == spec.value) and 0.55 or 0.25)
      end

      b:SetEnabled(tab.key ~= spec.value)
      b:SetScript("OnClick", function()
        -- Belt AND braces. A disabled Button does not fire OnClick in the client, so this guard
        -- is redundant there -- but the invariant is worth stating where it can be read, and it
        -- keeps the handler correct if anything ever re-enables the button without redrawing
        -- the strip. It is also the only thing a harness can assert against, since a mock's
        -- SetEnabled cannot suppress a directly-fired script.
        if tab.key == spec.value then return end
        if spec.onSelect then pcall(spec.onSelect, tab.key) end
      end)
      if tab.tooltip then O.AttachTooltip(b, tab.label, tab.tooltip) end

      buttons[i] = b
      widths[i]  = labelWidth(b.GetFontString and b:GetFontString())
      ctx.__chromeKids[#ctx.__chromeKids + 1] = b
    end

    -- The strip's own width, not the panel's: a body inset by PADDING_X on both edges.
    local available = ctx.chrome.GetWidth and ctx.chrome:GetWidth()
    if type(available) ~= "number" or available <= 0 then available = L.TAB_MIN_W end

    local rows = O.__layoutTabs(widths, available, L.TAB_GAP)
    for r, indices in ipairs(rows) do
      local x = 0
      local y = -((r - 1) * (L.TAB_H + L.TAB_ROW_GAP))
      for _, i in ipairs(indices) do
        buttons[i]:SetWidth(widths[i])
        buttons[i]:ClearAllPoints()
        buttons[i]:SetPoint("TOPLEFT", ctx.chrome, "TOPLEFT", x, y)
        buttons[i]:Show()
        x = x + widths[i] + L.TAB_GAP
      end
    end

    -- Reserved AFTER the wrap is known, never before: a strip that reserved one row and then
    -- laid out two would put its second row on top of the page's first widget.
    local rowCount = math.max(#rows, 1)
    O.SetChromeHeight(ctx,
      (ctx.__bannerHeight or 0) + (rowCount * L.TAB_H) + ((rowCount - 1) * L.TAB_ROW_GAP))

    return buttons
  end
```

- [ ] **Step 5: Run the tests**

```sh
cd ../LibKa0s && lua tests/run.lua 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 6: Lint and commit**

```sh
cd ../LibKa0s && luacheck .
git add LibKa0s/OptionsWidgets.lua tests/test_options_widgets.lua tests/fixture_options.lua
git commit -m "OptionsWidgets: a pinned tab strip, one tab per section

The wrap rule is a pure function over widths, because a rule that can
only be checked against a measured font is a rule nothing checks --
and a tab wider than the strip is placed alone rather than dropped, or
a page loses a whole section silently.

The active tab is the DISABLED one, which is how Blizzard's own tab
groups mark selection: it needs no second piece of art to say so, and
it makes clicking the tab you are already on unable to re-render the
page you are already looking at."
```

---

### Task 4: `O.PageBanner`

**Files:**
- Modify: `../LibKa0s/LibKa0s/OptionsWidgets.lua` — after `O.TabStrip`
- Test: `../LibKa0s/tests/test_options_widgets.lua`

**Interfaces:**
- Consumes: `ctx.chrome`, `releaseChrome`, `O.SetChromeHeight`, `O.BANNER_H`, `O.AttachTooltip`.
- Produces: `O.PageBanner(ctx, spec)` → `table|nil` (the AceGUI Dropdown). `spec = { label, list, order, value, onSelect, tooltip }`. Sets `ctx.__bannerHeight`, which `TabStrip` adds to its own band. **Call the banner before the strip.**

- [ ] **Step 1: Write the failing tests**

Append to `../LibKa0s/tests/test_options_widgets.lua`:

```lua
-- ── the page banner ────────────────────────────────────────────────────────────────────────

test("widgets: PageBanner draws a seeded picker and reserves the banner band", function()
  -- red under: reserving nothing, or seeding the dropdown from the list's first key.
  local O, _, ctx = bench()
  local chosen = {}
  local dd = O.PageBanner(ctx, {
    label = "Window",
    list  = { [1] = "Multi Meters #1", [2] = "Multi Meters #2" },
    order = { 1, 2 },
    value = 2,
    onSelect = function(key) chosen[#chosen + 1] = key end,
  })

  assertEqual(dd.type, "Dropdown")
  assertEqual(dd.value, 2, "seeded from the caller's pointer, not from the list")
  assertEqual(ctx.__bannerHeight, O.BANNER_H)
  assertTrue(ctx.chromeHeight >= O.BANNER_H)

  dd:__fire("OnValueChanged", 1)
  assertEqual(#chosen, 1)
  assertEqual(chosen[1], 1)
end)

test("widgets: banner then strip reserve ONE band between them, not two", function()
  -- The two are drawn in that order by every page that has both, and the band has to hold both.
  -- A strip that reserved only its own rows would slide up under the banner.
  -- red under: SetChromeHeight overwriting rather than accumulating the banner's share.
  local O, _, ctx = bench()
  O.PageBanner(ctx, { label = "W", list = { [1] = "One" }, order = { 1 }, value = 1,
                      onSelect = function() end })
  O.TabStrip(ctx, { tabs = { { key = "a", label = "A" } }, value = "a",
                    onSelect = function() end })
  assertEqual(ctx.chromeHeight, O.BANNER_H + O.TAB_H)
end)

test("widgets: PageBanner refuses politely with no AceGUI and with no spec", function()
  -- red under: reading spec.list before checking spec.
  withoutAceGUI(function()
    local O, _, ctx = bench()
    assertNil(O.PageBanner(ctx, { label = "W", list = {}, order = {}, value = 1 }))
  end)

  local O2, _, ctx2 = bench()
  assertNil(O2.PageBanner(ctx2, nil))
end)
```

- [ ] **Step 2: Run and confirm failure**

```sh
cd ../LibKa0s && lua tests/run.lua 2>&1 | tail -20
```

Expected: FAIL on `O.PageBanner` being nil.

- [ ] **Step 3: Implement it**

In `LibKa0s/OptionsWidgets.lua`, after `O.TabStrip`:

```lua
  --- The page banner (options-ui-§14): which instance this page is editing, and the picker for
  --- it, pinned above the strip and the scroll.
  ---
  --- It carries the PICKER rather than a label, and it is the ONLY picker: a page that already
  --- had one deletes it. Two controls over one piece of session state is a synchronisation
  --- problem the design invented and would then own forever -- here there is one value, read at
  --- render time, and the structural refresh the write already triggers repaints every panel.
  ---
  --- Draw it BEFORE the strip. It records its own share of the band in `ctx.__bannerHeight`,
  --- which TabStrip adds to the rows it reserves for itself; called the other way round, the
  --- strip's reservation would not know about it.
  ---
  --- `spec` = { label, list, order, value, onSelect, tooltip }. Returns the dropdown, or nil
  --- having drawn nothing.
  function O.PageBanner(ctx, spec)
    if not (ctx and ctx.chrome and spec) then return nil end
    local AceGUI = O.AceGUI
    if not AceGUI then return nil end

    releaseChrome(ctx)

    local dd = AceGUI:Create("Dropdown")
    dd:SetLabel(spec.label or "")
    dd:SetList(spec.list or {}, spec.order)
    dd:SetValue(spec.value)
    dd:SetCallback("OnValueChanged", function(_, _, key)
      -- pcall'd for the reason every host callback in this file is: a selection handler reaches
      -- into live addon state, and a raise inside AceGUI's own dispatch takes the click handling
      -- of every widget on the frame with it.
      if spec.onSelect then pcall(spec.onSelect, key) end
    end)
    if dd.frame then
      dd.frame:SetParent(ctx.chrome)
      dd.frame:ClearAllPoints()
      dd.frame:SetPoint("TOPLEFT",  ctx.chrome, "TOPLEFT",  0, 0)
      dd.frame:SetPoint("TOPRIGHT", ctx.chrome, "TOPRIGHT", 0, 0)
      dd.frame:SetHeight(L.BANNER_H)
      dd.frame:Show()
      ctx.__chromeKids[#ctx.__chromeKids + 1] = dd.frame
    end
    O.AttachTooltip(dd, spec.label, spec.tooltip)

    ctx.__bannerHeight = L.BANNER_H
    O.SetChromeHeight(ctx, L.BANNER_H)
    return dd
  end
```

Then, in `O.TabStrip`, move its `releaseChrome(ctx)` call so it does **not** discard the banner: replace the bare `releaseChrome(ctx)` at the top of `TabStrip` with a strip-only release.

```lua
    -- Only the strip's own buttons, never the banner: the banner is drawn first and a blanket
    -- release here would take it with them.
    for _, f in ipairs(ctx.__tabKids or {}) do
      f:Hide()
      f:SetParent(nil)
    end
    ctx.__tabKids = {}
```

and inside the tab loop replace `ctx.__chromeKids[#ctx.__chromeKids + 1] = b` with:

```lua
      ctx.__tabKids[#ctx.__tabKids + 1] = b
      ctx.__chromeKids[#ctx.__chromeKids + 1] = b
```

Update the Task 3 test `a second TabStrip call replaces the first rather than stacking on it` to assert on `ctx.__tabKids` instead of `ctx.__chromeKids` — the second strip's release now empties the strip's own ledger while the page-wide one still accumulates for `releaseChrome`.

- [ ] **Step 4: Run the tests**

```sh
cd ../LibKa0s && lua tests/run.lua 2>&1 | tail -20
```

Expected: PASS, including the amended Task 3 case.

- [ ] **Step 5: Lint and commit**

```sh
cd ../LibKa0s && luacheck .
git add LibKa0s/OptionsWidgets.lua tests/test_options_widgets.lua
git commit -m "OptionsWidgets: a page banner that IS the picker

A page editing one instance out of many that cannot say which one is
the panel lying about what a click will change -- and a banner that
only NAMED the instance would have told the player about the problem
rather than given them the fix.

So it carries the picker, and it is the only one: the page that had a
picker deletes it. Two controls over one piece of session state is a
synchronisation problem the design invented and would then own."
```

---

### Task 5: `O.RenderTabbedSchema`

**Files:**
- Modify: `../LibKa0s/LibKa0s/OptionsWidgets.lua` — `O.RenderRows` (line 845), and a new function after `O.RenderSchema` (line 886)
- Modify: `../LibKa0s/tests/fixture_options.lua` — a third page
- Test: `../LibKa0s/tests/test_options_widgets.lua`

**Interfaces:**
- Consumes: `d.rowsForPage`, `O.RenderRows`, `O.TabStrip`, `O.ClearScroll`, `ctx.activeTab`.
- Produces:
  - `O.RenderRows(ctx, rows, afterGroup, pairWith, opts)` — new fifth argument; `opts.noHeadings = true` suppresses `O.Section`. Every existing four-argument call is unchanged.
  - `O.RenderTabbedSchema(ctx, pageKey, afterGroup, pairWith)` → `string[]` — the group names in declaration order. Draws a strip when there are two or more; falls back to a plain `RenderSchema` when there are fewer or when AceGUI is absent.

- [ ] **Step 1: Add a third fixture page**

In `../LibKa0s/tests/fixture_options.lua`, add `"tabbed"` **and `"solo"`** to `Fixture.PAGES` and append these rows to `buildRows()`:

```lua
    -- tabbed ─────────────────────────────────────────────────────────────────────────────────
    -- FOUR groups, because the tabbed renderer's interesting cases are all about the group
    -- BOUNDARY: which rows a tab shows, which it hides, and that a group returning later would
    -- be a second tab with the same name. Two groups could not tell a partition apart from a
    -- filter that happens to keep the first two rows.
    { path = "tabAlpha",   page = "tabbed", group = "Alpha", order = 10, type = "bool",
      label = "Alpha one", default = false },
    { path = "tabAlphaTwo", page = "tabbed", group = "Alpha", order = 20, type = "bool",
      label = "Alpha two", default = true },
    { path = "tabBeta",    page = "tabbed", group = "Beta",  order = 10, type = "bool",
      label = "Beta one", default = false },
    { path = "tabGamma",   page = "tabbed", group = "Gamma", order = 10, type = "number",
      label = "Gamma one", default = 5, min = 0, max = 10, step = 1 },
    { path = "tabDelta",   page = "tabbed", group = "Delta", order = 10, type = "string",
      label = "Delta one", default = "", dialogControl = "EditBox" },

    -- solo ───────────────────────────────────────────────────────────────────────────────────
    -- ONE group, which no other fixture page has. Without it the "a one-group page draws no
    -- strip" case has nothing to point at, and an earlier draft aimed it at a two-group page
    -- behind an `if #groups == 1` guard that therefore never opened.
    { path = "soloOne", page = "solo", group = "Only", order = 10, type = "bool",
      label = "Solo one", default = false },
    { path = "soloTwo", page = "solo", group = "Only", order = 20, type = "bool",
      label = "Solo two", default = true },
```

- [ ] **Step 2: Write the failing tests**

Append to `../LibKa0s/tests/test_options_widgets.lua`:

```lua
-- ── the tabbed page ────────────────────────────────────────────────────────────────────────

--- Every label and heading currently sitting in a ctx's scroll, in order.
---
--- Built on Fixture.flatten rather than on a second hand-rolled walk: the fixture already owns
--- "every widget below this one, depth first", and a private copy here would be the thing that
--- disagrees with it the next time the flow engine nests a row one level deeper.
local function scrollLabels(ctx)
  local out = {}
  if not ctx.scroll then return out end
  for _, w in ipairs(Fixture.flatten(ctx.scroll)) do
    if w.type == "Heading" then
      out[#out + 1] = "HEADING:" .. tostring(w.text)
    elseif w.labelText then
      out[#out + 1] = w.labelText
    end
  end
  return out
end

test("widgets: a tabbed page draws ONLY the active group's rows", function()
  -- The partition is the whole feature. A renderer that drew the strip and then every row would
  -- look right on the first tab and be a 35-control scroll under a strip on every other.
  -- red under: rendering d.rowsForPage whole, or filtering on order rather than on group.
  local O, _, ctx = bench()
  local groups = O.RenderTabbedSchema(ctx, "tabbed")

  assertEqual(table.concat(groups, "|"), "Alpha|Beta|Gamma|Delta",
    "the tabs are the groups, in DECLARATION order")

  local labels = table.concat(scrollLabels(ctx), "|")
  assertTrue(labels:find("Alpha one", 1, true) ~= nil)
  assertTrue(labels:find("Alpha two", 1, true) ~= nil)
  assertNil(labels:find("Beta one", 1, true), "a group that is not the active tab is not drawn")
  assertNil(labels:find("Gamma one", 1, true))
end)

test("widgets: a tabbed page draws no section heading -- the tab IS the heading", function()
  -- red under: passing the rows through the four-argument RenderRows.
  local O, _, ctx = bench()
  O.RenderTabbedSchema(ctx, "tabbed")
  for _, label in ipairs(scrollLabels(ctx)) do
    assertNil(label:find("^HEADING:"), "a tabbed page drew a heading: " .. label)
  end
end)

test("widgets: an UNtabbed page still draws its headings", function()
  -- The amendment to RenderRows is opt-in through a fifth argument, so every existing caller
  -- must behave exactly as it did. This is the case that pins that.
  -- red under: defaulting noHeadings to true, or dropping O.Section from the untabbed path.
  local O, _, ctx = bench()
  O.RenderSchema(ctx, "general")
  local sawHeading = false
  for _, label in ipairs(scrollLabels(ctx)) do
    if label:find("^HEADING:") then sawHeading = true end
  end
  assertTrue(sawHeading, "an untabbed page lost its section headings")
end)

test("widgets: clicking a tab clears the scroll and renders the new group", function()
  -- red under: rendering the new group without clearing, which appends it under the old one.
  local O, _, ctx = bench()
  O.RenderTabbedSchema(ctx, "tabbed")
  local buttons = ctx.__tabKids
  buttons[3]:__fire("OnClick")

  assertEqual(ctx.activeTab, "Gamma")
  local labels = table.concat(scrollLabels(ctx), "|")
  assertTrue(labels:find("Gamma one", 1, true) ~= nil)
  assertNil(labels:find("Alpha one", 1, true), "the previous tab's rows were left behind")
end)

test("widgets: the active tab survives a re-render, and heals when its group disappears",
function()
  -- A window switch re-renders the page and must land on the same tab (options-ui-§14).
  -- But a ctx.activeTab naming a group the page no longer has -- a filtered subset, a renamed
  -- section -- would render an empty page under a strip, so it falls back to the first.
  -- red under: seeding activeTab unconditionally, or trusting it without checking membership.
  local O, _, ctx = bench()
  O.RenderTabbedSchema(ctx, "tabbed")
  ctx.__tabKids[2]:__fire("OnClick")
  assertEqual(ctx.activeTab, "Beta")

  O.RenderTabbedSchema(ctx, "tabbed")
  assertEqual(ctx.activeTab, "Beta", "a re-render kept the tab")

  ctx.activeTab = "NoSuchGroup"
  O.RenderTabbedSchema(ctx, "tabbed")
  assertEqual(ctx.activeTab, "Alpha", "a stale tab healed to the first group")
end)

test("widgets: a one-group page draws no strip at all", function()
  -- A strip over a single tab is chrome for its own sake, and it would reserve a band that
  -- pushes the page down for nothing.
  --
  -- Pointed at the "solo" fixture page, which exists for exactly this and holds ONE group. An
  -- earlier draft aimed this at "bar" and wrapped the assertion in `if #groups == 1` -- "bar"
  -- has two groups, so the guard never opened and the case could not fail.
  -- red under: drawing the strip before counting the groups.
  local O, _, ctx = bench()
  local groups = O.RenderTabbedSchema(ctx, "solo")
  assertEqual(#groups, 1, "the solo fixture page must hold exactly one group")
  assertEqual(ctx.chromeHeight, 0, "a single-group page reserved a band")
  assertEqual(#(ctx.__tabKids or {}), 0, "a single-group page built tab buttons")
end)

test("widgets: with no AceGUI a tabbed page falls back to the flat scroll", function()
  -- The degraded path shows the SETTINGS, not an empty canvas: a host that lost the strip has
  -- lost a convenience, not its options.
  -- red under: returning early before RenderSchema.
  withoutAceGUI(function()
    local O, _, ctx = bench()
    local groups = O.RenderTabbedSchema(ctx, "tabbed")
    assertEqual(#groups, 0, "no AceGUI, no tabs to report")
  end)
end)
```

- [ ] **Step 3: Run and confirm failure**

```sh
cd ../LibKa0s && lua tests/run.lua 2>&1 | tail -20
```

Expected: FAIL on `O.RenderTabbedSchema` being nil.

- [ ] **Step 4: Teach `RenderRows` to suppress headings**

In `LibKa0s/OptionsWidgets.lua`, change the signature and the `startGroup` call:

```lua
  function O.RenderRows(ctx, rows, afterGroup, pairWith, opts)
```

and inside the loop, replace `startGroup(O, ctx, row, flushRow)` with:

```lua
      -- A tabbed page's heading is its tab (options-ui-§7, as amended), so the Section is
      -- suppressed -- but the TRACKER still advances, or a later group would be treated as a
      -- continuation of this one and the flush between them would not happen.
      if opts and opts.noHeadings then
        if row.group and row.group ~= ctx.lastGroup then
          flushRow()
          ctx.lastGroup = row.group
        end
      else
        startGroup(O, ctx, row, flushRow)
      end
```

Extend the doc comment above `O.RenderRows` with:

```lua
  --   opts        { noHeadings = true } suppresses the automatic Section heading, for a page
  --               whose sections are drawn as tabs instead (options-ui-§13). Omitted by every
  --               untabbed caller, which is why it is a fifth argument rather than a field on
  --               the ctx: a page's tabbedness is a property of THIS render, and a ctx flag
  --               would leak it into the next one.
```

- [ ] **Step 5: Implement `RenderTabbedSchema`**

Append to `LibKa0s/OptionsWidgets.lua`, after `O.RenderSchema`:

```lua
  --- Render one page as a tab strip over its sections (options-ui-§13).
  ---
  --- The partition is by `group`, IN DECLARATION ORDER, and one tab is exactly one group. There
  --- is no second field naming a tab, for the reason options-ui-§1 gives against a second
  --- widget selector: a tab list declared apart from the rows is a list that goes stale the
  --- first time a section is renamed, and nothing would say so.
  ---
  --- Returns the group names, in tab order. A page with fewer than two groups draws no strip --
  --- a single tab is chrome for its own sake, and its band would push the page down for nothing.
  ---
  --- With no AceGUI there is nothing to draw AT ALL: EnsureScroll answers nil and every maker in
  --- this file refuses, so this reports an empty tab list and draws nothing -- which is what
  --- RenderSchema would also have done, reached or not. The fallback that matters is the
  --- single-group one above it, not this.
  function O.RenderTabbedSchema(ctx, pageKey, afterGroup, pairWith)
    local rows = d.rowsForPage(pageKey, ctx.unit) or {}

    local groups, seen = {}, {}
    for _, row in ipairs(rows) do
      if row.group and not seen[row.group] then
        seen[row.group] = true
        groups[#groups + 1] = row.group
      end
    end

    if not O.AceGUI then return {} end
    if #groups < 2 then
      O.RenderSchema(ctx, pageKey, afterGroup, pairWith)
      return groups
    end

    -- A tab pointing at a group this page no longer has renders an empty page under a strip,
    -- so a stale pointer heals to the first rather than being trusted. Cheap enough to check on
    -- every render, and the alternative is a page that is blank until the user clicks something.
    if not (ctx.activeTab and seen[ctx.activeTab]) then
      ctx.activeTab = groups[1]
    end

    local tabs = {}
    for i, name in ipairs(groups) do tabs[i] = { key = name, label = name } end

    O.TabStrip(ctx, {
      tabs  = tabs,
      value = ctx.activeTab,
      onSelect = function(key)
        if key == ctx.activeTab then return end
        ctx.activeTab = key
        -- The same structural path a change of subject takes, which is what earns the combat
        -- refusal for free (options-ui-§13): the host's renderer owns the guard, and a second
        -- one here would be a second policy to keep in step.
        O.ClearScroll(ctx)
        O.RenderTabbedSchema(ctx, pageKey, afterGroup, pairWith)
      end,
    })

    local active = {}
    for _, row in ipairs(rows) do
      if row.group == ctx.activeTab then active[#active + 1] = row end
    end
    O.RenderRows(ctx, active, afterGroup, pairWith, { noHeadings = true })

    return groups
  end
```

- [ ] **Step 6: Run the tests**

```sh
cd ../LibKa0s && lua tests/run.lua 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 7: Lint and commit**

```sh
cd ../LibKa0s && luacheck .
git add LibKa0s/OptionsWidgets.lua tests/test_options_widgets.lua tests/fixture_options.lua
git commit -m "OptionsWidgets: render a page as tabs over its own sections

One tab is exactly one group, and there is no second field naming a
tab -- a tab list declared apart from the rows goes stale the first
time a section is renamed, and nothing would say so.

The tab switch re-enters this function through ClearScroll, which is
the same structural path a change of subject takes, so the host
renderer's combat refusal covers it and there is no second guard to
keep in step. A stale activeTab heals to the first group rather than
rendering an empty page under a strip."
```

---

### Task 6: Release LibKa0s v1.20.0

**Files:**
- Modify: `../LibKa0s/LibKa0s/Options.lua` (`MINOR` 9 → 10), `../LibKa0s/LibKa0s/OptionsWidgets.lua` (`WIDGETS_MINOR` 8 → 9)
- Create: `../LibKa0s/docs/api/Options/version-10.9.3-docs.md`
- Modify: `../LibKa0s/docs/api/Options/version-9.8.3-docs.md`, `../LibKa0s/docs/api/README.md`, `../LibKa0s/CHANGELOG.md`, `../LibKa0s/docs/releasing.md`, `../LibKa0s/docs/test-cases.md`

**Interfaces:**
- Consumes: everything from Tasks 2–5.
- Produces: git tag `v1.20.0`, and the payload MultiMeters copies in Task 7.

- [ ] **Step 1: Bump both file minors**

In `LibKa0s/Options.lua` line 24: `local MAJOR, MINOR = "LibKa0s-Options-1.0", 10`.
In `LibKa0s/OptionsWidgets.lua`: `WIDGETS_MINOR` 8 → 9.

`OptionsScroll.lua` is untouched, so `SCROLL_MINOR` stays 3 — the new version key is therefore `10.9.3`.

**`Kit.VERSION` moved to 14** during the tab-strip task (the frame mock gained real enabled-state
tracking), so this release's version block says **kit revision 14**, and `tests/_kit/` must already
match `testkit/` — `tests/test_kitsync.lua` enforces it. Confirm with `grep -n 'Kit.VERSION' testkit/framework.lua tests/_kit/framework.lua` before writing the CHANGELOG block.

- [ ] **Step 2: Run the suite to see the versioning gate fail**

```sh
cd ../LibKa0s && lua tests/run.lua 2>&1 | tail -20
```

Expected: FAIL — `test_versioning.lua` naming `LibKa0s-Options-1.0` for a missing `docs/api/Options/version-10.9.3-docs.md`, and for a `CHANGELOG.md` version block that disagrees with `lib.MODULES`.

- [ ] **Step 3: Write the new API document**

```sh
cd ../LibKa0s
cp docs/api/Options/version-9.8.3-docs.md docs/api/Options/version-10.9.3-docs.md
```

In the **new** file: set `Status` to **Current**, fill `Supersedes` with `version-9.8.3-docs.md`, add a *What changed at this version* section covering the chrome slot, `SetChromeHeight`, `__scrollTopInset`, `TabStrip`, `PageBanner`, `RenderTabbedSchema`, `RenderRows`' fifth argument and the three new published scalars, and give every one of those a `Since` of **Options minor 10 / OptionsWidgets minor 9**. Document the two ordering contracts explicitly — **banner before strip**, and **`SetChromeHeight` after the wrap is known**.

In the **old** file (`version-9.8.3-docs.md`): set `Status` to Superseded, fill `Superseded by`, and add the closing *Moving to 10.9.3* section.

Add the row to the table in `docs/api/README.md`.

- [ ] **Step 4: Write the CHANGELOG entry**

At the top of `../LibKa0s/CHANGELOG.md`, under `# Changelog`'s preamble:

```markdown
## v1.20.0 — 2026-08-27

Versions in this release: **Core minor 6**, **Env minor 1**, **Pool minor 3**, **Item minor 1**,
**Media minor 3**, **Widgets minor 8**, **DebugLog minor 12**, **Slash minor 7**, **Options minor 10**,
**OptionsWidgets minor 9**, **OptionsScroll minor 3**, **Perf minor 7**, **PerfPanel minor 4**,
**kit revision 14**.

**`LibKa0s-Options-1.0` minors 10/9 — tabbed pages and a page banner, on a chrome slot that
costs an unadopting consumer nothing.**

MultiMeters' settings had reached 137 rows over nine pages, and the shape had run out: one
section held a single control, another held fifteen, and six pages edited whichever window a
picker two pages up had selected without saying so. Both fixes needed the same missing thing —
somewhere to put furniture that does not scroll away — and there was nowhere: `EnsureScroll`
anchored the `ScrollFrame` straight to the body's top edge.

**The chrome slot is a frame and a number, and the number starts at zero.** That is the whole
additive bargain. Eight consumers re-vendor this file without calling anything new, and their
scroll anchors where it always did, because `CHROME_GAP` is the literal `8` the old code used.

**One tab is exactly one group** (options-ui-§13). No second field names a tab, for the reason
§1 gives against a second widget selector: a tab list declared apart from the rows goes stale the
first time a section is renamed, and nothing says so. The wrap rule is a pure function over
widths (`O.__layoutTabs`) rather than something only a measured font can exercise, and a tab
wider than the strip is placed alone rather than dropped — losing one would lose a whole section
of a page silently.

**The banner carries the picker, and it is the only one** (options-ui-§14). A page that had one
deletes it. Two controls over one piece of session state is a synchronisation problem the design
invented and would then own forever.

The tab switch re-enters `RenderTabbedSchema` through `ClearScroll`, which is the same structural
path a change of subject takes — so the host renderer's combat refusal covers it and there is no
second guard to keep in step.
```

- [ ] **Step 5: Run the suite**

```sh
cd ../LibKa0s && lua tests/run.lua && luacheck .
```

Expected: PASS, `0 warnings / 0 errors`.

- [ ] **Step 6: Regenerate the case list**

Follow the exact command in `docs/test-cases.md`'s own banner (it pins CRLF):

```sh
cd ../LibKa0s && head -12 docs/test-cases.md
```

Run what that banner says, and confirm `git diff --stat docs/test-cases.md` shows only added cases.

- [ ] **Step 7: Move the provenance template and re-run the gate**

In `docs/releasing.md`: update the repo semver in the table at the top to `v1.20.0`, and move the templated provenance line under *Re-vendoring consumers* to `v1.20.0`.

```sh
cd ../LibKa0s && lua tests/run.lua && luacheck .
```

- [ ] **Step 8: Freeze the release bundle**

```sh
cd ../LibKa0s && tests/_kit/run-automated-tests.sh --release 1.20.0
```

Read all four suites before continuing. **The gate is all four at `pass` plus zero functions above CCN 15**; `perf` is a standing `skip` in this repo and is NOT a pass. If `lizard` reports a function over CCN 15, fix it before tagging — `O.TabStrip` is the likely offender, and the fix is to lift its per-tab body into a file-local `makeTab(ctx, tab, active)`.

- [ ] **Step 9: Commit and tag**

```sh
cd ../LibKa0s
git add -A
git commit -m "LibKa0s v1.20.0: tabbed pages and a page banner

Options minor 10, OptionsWidgets minor 9. The chrome slot is a frame
and a number, and the number starts at zero -- so the eight consumers
that re-vendor this file without calling anything new get a scroll
anchored exactly where it was."
git tag v1.20.0
```

- [ ] **Step 10: Confirm the tag and the payload**

```sh
cd ../LibKa0s && git tag --list 'v1.20*' && git show --stat v1.20.0 | head -20
```

Expected: `v1.20.0` exists and the tagged tree contains the frozen bundle.

---

# Part C — MultiMeters

### Task 7: Re-vendor LibKa0s v1.20.0

**Files:**
- Modify: `libs/LibKa0s/**`, `tests/_kit/**` (copies, never hand-edited)
- Modify: `CLAUDE.md` (the provenance line), `DEPENDENCIES.md`
- Test: `tests/test_vendor_sync.lua`

**Interfaces:**
- Consumes: LibKa0s tag `v1.20.0`.
- Produces: `NS.Helpers.SetChromeHeight`, `.TabStrip`, `.PageBanner`, `.RenderTabbedSchema`, `.CHROME_GAP`, `.TAB_H`, `.BANNER_H` available to `settings/`.

- [ ] **Step 1: Copy the payload**

```sh
cd /mnt/d/Profile/Users/Tushar/Documents/GIT/MultiMeters
cp -r ../LibKa0s/LibKa0s/. libs/LibKa0s/
```

**The kit revision DID move in v1.20.0 — 13 to 14** (the frame mock gained real enabled-state
tracking, without which a tab strip's active-tab assertion silently tests nothing). So both
payloads are re-copied, in this same commit:

```sh
cp -r ../LibKa0s/testkit/. tests/_kit/
```

Confirm the pairing before and after:

```sh
grep -n 'kit revision' ../LibKa0s/CHANGELOG.md | head -2
grep -n 'Kit.VERSION' ../LibKa0s/testkit/framework.lua tests/_kit/framework.lua
```

Expected: v1.20.0 says **kit revision 14**, v1.19.0 says 13, and both `framework.lua` copies read
`Kit.VERSION = 14`. `tests/test_vendor_sync.lua` compares the copies byte-for-byte and will stay
red until both payloads land.

- [ ] **Step 2: Roll the provenance line**

In `CLAUDE.md`, change the final line to:

```
Bundles [LibKa0s](https://github.com/tusharsaxena/LibKa0s) v1.20.0 (MIT).
```

Update the version in `DEPENDENCIES.md` wherever it names v1.19.0.

- [ ] **Step 3: Forward the new members onto the instance**

In `settings/OptionsSetup.lua`, extend the member list at line ~306 with the four new function names and the three new scalars:

```lua
        "SetChromeHeight", "TabStrip", "PageBanner", "RenderTabbedSchema",
```

and, wherever the file publishes the layout scalars alongside `PADDING_X`, add `CHROME_GAP`, `TAB_H`, `BANNER_H`. Read the surrounding lines first — the file copies members by name from the library instance onto `NS.Helpers`, and the scalars may travel through the same list or a second one.

- [ ] **Step 4: Run the gate**

```sh
lua tests/run.lua && luacheck .
```

Expected: PASS, `0/0`. `tests/test_vendor_sync.lua` compares the vendored copy byte-for-byte against `../LibKa0s`; a failure here means the copy was partial.

- [ ] **Step 5: Confirm the new members actually arrived**

```sh
lua -e 'local T = dofile("tests/run.lua")' 2>/dev/null || true
grep -n 'RenderTabbedSchema\|PageBanner\|TabStrip' libs/LibKa0s/OptionsWidgets.lua | head
```

Expected: all three present in the vendored file.

- [ ] **Step 6: Commit**

```sh
git add libs/LibKa0s tests/_kit CLAUDE.md DEPENDENCIES.md settings/OptionsSetup.lua
git commit -m "Carry the tagged LibKa0s v1.20.0 payload

Options minor 10, OptionsWidgets minor 9: the chrome slot, TabStrip,
PageBanner and RenderTabbedSchema. Nothing in settings/ calls them
yet -- the payload and the provenance line move in one commit so the
tree never claims a version it is not carrying."
```

---

### Task 8: Regroup the schema

**Files:**
- Modify: `settings/Schema.lua` — every row's `page` and `group`, and declaration order
- Modify: `locales/enUS.lua` — the new group names
- Test: `tests/test_schema.lua`

**Interfaces:**
- Consumes: nothing new.
- Produces: the page/group partition every later task renders. `NS.SchemaForPage(page)` returns rows grouped contiguously in the order below.

**The target partition.** Tab order is declaration order; a group must be contiguous.

| Page | Tabs, in order | Controls per tab |
|---|---|---|
| `general` | General · Data · Maintenance | 3 · 2 · 1 (+2 bespoke buttons) |
| `windows` | Window · Copy from | 1 (+3 bespoke) · 3 bespoke |
| `frame` | Size & position · Rows · Row behavior · Background & border · Behavior · All surfaces | 6 · 4 · 4 · 4 · 2 · 4 |
| `header` | Title bar · Title text · Window buttons · Meter buttons · Button style | 4 · 5 · 5 · 4 · 6 |
| `bars` | Bar · Bar background · Bar border · Text content · Text style · Icons | 5 · 3 · 4 · 5 · 7 · 3 |
| `tooltip` | Tooltip · Contents · Bar · Bar background · Bar border · Text | 5 · 5 · 5 · 3 · 3 · 6 |
| `visibility` | Where to show · When to hide · Combat | 7 · 8 · 2 |
| `columns` | Columns · Header text · Header background | bespoke · 6 · 2 |
| `profiles` | — untabbed | — |

- [ ] **Step 1: Write the failing test**

Replace the two existing header-page cases in `tests/test_schema.lua` — `the header page's groups are in the order the strips are drawn` (line ~695) and `the header controls are EDITED on Header and STORED under frame` (line ~714) — with one table-driven case covering every page. Append it in their place:

```lua
-- ---------------------------------------------------------------------------
-- The page/tab partition
-- ---------------------------------------------------------------------------

--- Every page's tabs, in the order the strip draws them, and how many controls each holds.
--- Stated here rather than derived from the schema the assertion reads, so a row that drifts
--- into another tab is a NAMED failure rather than a shorter list that still agrees with
--- itself.
---
--- VISIBLE rows only, because NS.SchemaForPage filters `hidden` and this table describes what
--- the panel DRAWS. So General has no Export tab -- its three export rows are hidden -- and
--- Window buttons counts four, not the five rows filed under it. The case below this one is
--- what keeps those hidden rows honest.
local PARTITION = {
    general    = { { "General", 3 }, { "Data", 2 }, { "Maintenance", 1 } },
    windows    = { { "Window", 1 } },
    frame      = { { "Size and position", 6 }, { "Rows", 4 }, { "Row behavior", 4 },
                   { "Background and border", 4 }, { "Behavior", 2 }, { "All surfaces", 4 } },
    header     = { { "Title bar", 4 }, { "Title text", 5 }, { "Window buttons", 4 },
                   { "Meter buttons", 4 }, { "Button style", 6 } },
    bars       = { { "Bar", 5 }, { "Bar background", 3 }, { "Bar border", 4 },
                   { "Text content", 5 }, { "Text style", 7 }, { "Icons", 3 } },
    tooltip    = { { "Tooltip", 5 }, { "Contents", 5 }, { "Bar", 5 },
                   { "Bar background", 3 }, { "Bar border", 3 }, { "Text", 6 } },
    visibility = { { "Where to show this window", 7 }, { "When to hide this window", 8 },
                   { "Combat", 2 } },
    columns    = { { "Header text", 6 }, { "Header background", 2 } },
}

test("Schema: every page's tabs are the designed ones, in order, at the designed size",
function()
    -- red under: moving a row to another tab, reordering a group, or letting a tab drift
    -- above six controls without the design saying so.
    local inst = T.load()
    local NS, L = inst.NS, inst.NS.L

    for page, expected in pairs(PARTITION) do
        local order, counts, seen = {}, {}, {}
        for _, row in ipairs(NS.SchemaForPage(page)) do
            local g = row.group or "?"
            if not seen[g] then
                seen[g] = true
                order[#order + 1] = g
            end
            counts[g] = (counts[g] or 0) + 1
        end

        local wantNames = {}
        for i, pair in ipairs(expected) do wantNames[i] = L[pair[1]] end
        assertEqual(table.concat(order, " | "), table.concat(wantNames, " | "),
            page .. ": tab order")

        for _, pair in ipairs(expected) do
            assertEqual(counts[L[pair[1]]], pair[2],
                page .. " / " .. pair[1] .. ": control count")
        end
    end
end)

test("Schema: no tab holds fewer than two controls", function()
    -- A tab over one control is a click that reveals a single checkbox. General's Maintenance
    -- is the one exemption and it is exempted BY NAME: its two reset buttons are bespoke
    -- commands with no stored value, so they cannot be rows and cannot be counted here.
    -- red under: a tab losing rows until one is left, or a new one-row section.
    local inst = T.load()
    local NS, L = inst.NS, inst.NS.L
    local EXEMPT = { [L["Maintenance"]] = true }

    local counts, pageOf = {}, {}
    for _, row in ipairs(NS.Schema) do
        if row.page and row.group then
            counts[row.group] = (counts[row.group] or 0) + 1
            pageOf[row.group] = row.page
        end
    end
    for group, n in pairs(counts) do
        if not EXEMPT[group] then
            assertTrue(n >= 2, pageOf[group] .. " / " .. group .. " holds only " .. n)
        end
    end
end)

test("Schema: a hidden row is filed under a tab that exists, and draws nothing", function()
    -- A hidden row still carries a page and a group -- that is what keeps it writable through
    -- NS.SetByPath, listable in `/mm list` and comparable by the schema-vs-defaults validator
    -- while missing the panel. It cannot produce a phantom tab, because SchemaForPage filters
    -- it before the strip is built; what it CAN do is lose its page and quietly drop out of
    -- `/mm list`, which is the half worth pinning.
    -- red under: dropping page or group from a hidden row "since it never draws".
    local inst = T.load()
    local NS = inst.NS

    local hidden, drawn = 0, {}
    for _, row in ipairs(NS.Schema) do
        if row.hidden then
            hidden = hidden + 1
            assertTrue(row.page ~= nil and row.group ~= nil,
                row.path .. " is hidden but carries no page or group")
        end
    end
    assertEqual(hidden, 4, "four rows are hidden: frame.minimised and the three export choices")

    -- And the other half: no tab the strip actually draws is empty.
    for _, page in ipairs({ "general", "windows", "frame", "header", "bars", "tooltip",
                            "visibility", "columns" }) do
        for _, row in ipairs(NS.SchemaForPage(page)) do
            drawn[row.group or "?"] = (drawn[row.group or "?"] or 0) + 1
        end
    end
    for group, n in pairs(drawn) do
        assertTrue(n >= 1, group .. " is a drawn tab with nothing in it")
    end
end)

test("Schema: every tab name is a localized string, not a bare literal", function()
    -- A tab label is now the most visible string on a page -- it is the heading AND the control
    -- you click -- and a group declared as a raw literal is a page that cannot be translated
    -- past its own headings. `L` answers its own key when a translation is missing, so the test
    -- is that the key EXISTS in the locale table rather than that the answer differs.
    -- red under: adding a group as "Bar border" instead of L["Bar border"].
    local inst = T.load()
    local NS = inst.NS
    local missing = {}
    for _, row in ipairs(NS.Schema) do
        if row.group and rawget(NS.L, row.group) == nil then
            missing[#missing + 1] = row.group
        end
    end
    table.sort(missing)
    assertEqual(table.concat(missing, ", "), "",
        "these group names are not in locales/enUS.lua")
end)

test("Schema: the active tab is session state and has no home in the schema", function()
    -- options-ui-§13: a stored tab is UI position masquerading as a setting. It would make one
    -- page look different to two characters on one account for a reason nobody asked for, and
    -- it turns a cosmetic default into a migration the day the sections are renamed.
    -- red under: adding an activeTab row "so /mm can reach it", which is the argument that
    -- correctly justifies the sessionOnly rows and does not justify this one.
    local inst = T.load()
    for _, row in ipairs(inst.NS.Schema) do
        assertFalse(row.path:find("activeTab") and true or false,
            "the active tab reached the schema: " .. row.path)
    end
end)

test("Schema: the column header strip is styled on the page where columns are chosen",
function()
    -- It LABELS the columns, and it spent three releases as the third group of a 31-control
    -- Header page. The paths stay under window.columnHeader.* -- a row's page is where it is
    -- edited and its path is where it is stored, and the two are allowed to disagree.
    -- red under: moving the group back to header, or renaming the paths to match the page.
    local inst = T.load()
    local NS = inst.NS

    local onColumns = 0
    for _, row in ipairs(NS.SchemaForPage("columns")) do
        onColumns = onColumns + 1
        assertTrue(row.path:find("^window%.columnHeader%."),
            row.path .. " is on the Columns page but is not a column-header setting")
    end
    assertEqual(onColumns, 8, "all eight moved, not some of them")

    for _, row in ipairs(NS.SchemaForPage("header")) do
        assertFalse(row.path:find("^window%.columnHeader%.") and true or false,
            "the Header page kept a column-header row: " .. row.path)
    end
end)
```

- [ ] **Step 2: Run and confirm failure**

```sh
lua tests/run.lua 2>&1 | tail -30
```

Expected: FAIL — tab order mismatches on every page.

- [ ] **Step 3: Add the new group names to the locale**

In `locales/enUS.lua`, add entries for each new string. The file's shape is `L["English"] = "English"`; follow it exactly.

New: `Maintenance`, `Window`, `Background and border`, `Behavior`, `All surfaces`, `Title bar`, `Title text`, `Window buttons`, `Meter buttons`, `Button style`, `Bar`, `Bar background`, `Bar border`, `Text content`, `Text style`, `Icons`, `Tooltip`, `Contents`, `Text`, `Header text`, `Header background`, `Rows`.

Retiring (delete only once nothing references them — `grep` first): `Frame header`, `Header controls`, `Column headers`, `Frame behavior`, `Bar appearance`, `Bar background color`, `Cell text`, `Row icons`, `Row layout`, `Tooltip behavior`, `Tooltip bars`, `Tooltip text`, `Master controls`, `Debug`.

Keeping, unchanged: `Size and position`, `Where to show this window`, `When to hide this window`, `Combat`, `Data`, `Export`, `Copy from`, `Active window` (now the banner's label, not a group), and `Border style` — which retires as a *group name* while surviving as a *row label*, so the key stays.

The file's header comment lists the pages in panel order (`Windows · Frame · Header · Rows · Bars · …`). Rewrite that list to the new page order and say that the blocks are now tabs.

- [ ] **Step 4: Regroup `settings/Schema.lua`**

Walk the file in declaration order and set every row's `page` and `group` to the partition above, **moving rows so each group is contiguous**. The moves that cross pages:

- `window.rows.maxRows`, `.height`, `.spacing`, `.growthDirection` → `page = "frame"`, `group = L["Rows"]`
- `window.rows.alwaysShowSelf`, `.highlightSelf`, `.mouseoverHighlight`, `window.rows.alternatingBackground` → `page = "frame"`, `group = L["Row behavior"]`
- all eight `window.columnHeader.*` → `page = "columns"`, split `L["Header text"]` (font, size, outline, shadow, color, colorMode) and `L["Header background"]` (bgColorMode, bgColor)
- `window.frame.minimised` stays `page = "header"`, and joins `group = L["Window buttons"]`. It is hidden and draws nothing; it keeps a page and a group so it stays writable through `NS.SetByPath` and listable in `/mm list`.
- **`window.frame.titleBar` moves here too** — `page = "header"`, `group = L["Title bar"]`, **first** in that group. Its **path does not change in this task**; Task 9 owns the rename, the defaults move and the migration. This task owns the partition, and leaving the row on Frame would make this task's own PARTITION test fail on a row it was never told to touch.

Within `header`, the eight button toggles split: close / minimise / lock / settings → `L["Window buttons"]`; segment / segment picker / reset / export → `L["Meter buttons"]`.

Within `general`: `enabled`, `minimap.hide`, `state.testMode` → `L["General"]`; `data.mergePets`, `data.throttle` → `L["Data"]`; `state.debugConsole` → `L["Maintenance"]`; the three hidden `export.*` keep `L["Export"]`.

`window.name` → `group = L["Window"]` (was `L["Active window"]`, whose picker Task 12 deletes).

- [ ] **Step 5: Repoint the hidden-row assertion at the page the row moved to**

`tests/test_schema.lua:536` currently walks `NS.SchemaForPage("frame")` asserting that
`window.frame.minimised` is not drawn. This task moves that row to the **header** page, which
makes the existing loop vacuously true — it would pass for the wrong reason forever. Change the
page it walks:

```lua
    for _, row in ipairs(NS.SchemaForPage("header")) do
        assertTrue(row.path ~= "window.frame.minimised",
            "a state row was rendered as a setting")
    end
```

Leave the rest of that case, and the export case below it, alone — the export rows do not move.

- [ ] **Step 6: Run the tests**

```sh
lua tests/run.lua 2>&1 | tail -30
```

Expected: PASS on the new cases. Other suites may still fail — `test_schema_defaults.lua` and `test_options_panel.lua` are Task 9's and Task 11's. If `Schema: every group on every page is CONTIGUOUS` fails, a row was moved without moving its neighbours.

- [ ] **Step 7: Confirm `COPY_GROUPS` needs no change**

The spec's ripple list named `modules/WindowManager.lua`'s `COPY_GROUPS`. Check it rather than
edit it:

```sh
sed -n '64,72p' modules/WindowManager.lua
```

Expected: `frame, header, rows, bars, text, icons, tooltip, visibility, columns, data` — these
are **storage sub-tree keys**, not page keys, and this task moved no storage. `window.rows.*`
still lives under `rows` however the Frame page draws it. **Make no edit here.** If a later task
renames a storage key, that task owns the `COPY_GROUPS` change.

- [ ] **Step 8: Lint and commit**

```sh
luacheck .
git add settings/Schema.lua locales/enUS.lua tests/test_schema.lua
git commit -m "Regroup 137 rows into tabs nobody has to scroll past

The sections had grown by accretion: one held a single control,
another fifteen, and the column-header strip was styled on the Header
page -- three clicks from the Columns page where you choose the
columns it labels.

The partition is asserted against a table stated in the test rather
than derived from the schema it reads, so a row that drifts into
another tab is a named failure rather than a shorter list that still
agrees with itself."
```

---

### Task 9: Rename `window.frame.titleBar`, and migrate

**Files:**
- Modify: `settings/Schema.lua` (the row), `defaults/Profile.lua`, `modules/Window.lua` and any other reader
- Modify: `core/Database.lua` — `CURRENT_DB_VERSION` 12 → 13, `migrations[12]`
- Test: `tests/test_database.lua`, `tests/test_schema_defaults.lua`

**Interfaces:**
- Consumes: Task 8's partition.
- Produces: `window.header.show` (bool, default `true`), on `page = "header"`, `group = L["Title bar"]`, as that tab's **first** row. `window.frame.titleBar` no longer exists anywhere.

- [ ] **Step 1: Find every reader**

```sh
grep -rn 'titleBar' --include='*.lua' . | grep -v '^./libs\|^./tests/_kit'
```

Record the list — every hit is a call site Step 4 must move.

- [ ] **Step 2: Write the failing migration test**

Append to `tests/test_database.lua`, following the shape of the file's existing migration cases:

```lua
test("Database: v12 -> v13 moves the title-bar toggle onto the header", function()
    -- The control moved to the Header page, and a path naming `frame` for a row on the Header
    -- page misleads the next reader and reads wrong in `/mm set`. Carried across rather than
    -- dropped: a player who turned their title bar OFF must not log in to it back on.
    -- red under: writing the default instead of the stored value, or forgetting the prune.
    local inst = T.load()
    local db = inst.NS.db

    db.global.schemaVersion = 12
    local w = db.profile.windows[1]
    w.frame.titleBar = false
    w.header.show = nil

    inst.NS.Database.Migrate(db)

    assertEqual(db.global.schemaVersion, 13)
    assertFalse(w.header.show, "the stored value carried across")
    assertNil(w.frame.titleBar, "AceDB merges defaults in and never removes what they stopped naming")
end)

test("Database: v12 -> v13 leaves a window that never stored the toggle alone", function()
    -- An absent key means "never changed from the default", and writing one during a migration
    -- would freeze today's default into every profile -- so the default could never move again.
    -- red under: unconditionally assigning header.show.
    local inst = T.load()
    local db = inst.NS.db

    db.global.schemaVersion = 12
    local w = db.profile.windows[1]
    w.frame.titleBar = nil
    w.header.show = nil

    inst.NS.Database.Migrate(db)
    assertNil(w.header.show)
end)
```

Confirm the migrate entry point's real name first — the file may expose it as `NS.Database.Migrate` or run it inside `InitDB`:

```sh
grep -n 'function M.Migrate\|Database.Migrate\|local function migrate' core/Database.lua | head
```

Use whatever the file actually publishes; if migration is only reachable through `InitDB`, drive it that way instead and say so in the test's comment.

- [ ] **Step 3: Run and confirm failure**

```sh
lua tests/run.lua 2>&1 | tail -20
```

Expected: FAIL — `schemaVersion` stops at 12.

- [ ] **Step 4: Rename the row and its readers**

In `settings/Schema.lua`, change the row's `path` to `"window.header.show"`. **Its `page` and `group` are already `header` / `L["Title bar"]` and it already sits at the top of that group** — Task 8 moved it, because Task 8 owns the partition. This task changes the path and nothing else about the row.

In `defaults/Profile.lua`, delete `titleBar` from the `frame` table and add `show = true` to the `header` table, positioned to match the schema's order.

Update every reader found in Step 1 to read `header.show`.

- [ ] **Step 5: Write the migration**

In `core/Database.lua`, set `CURRENT_DB_VERSION = 13` and append after `migrations[11]`:

```lua
--- v12 -> v13: THE TITLE-BAR TOGGLE MOVES ONTO THE HEADER.
---
--- `Show title bar` was on the Frame page, under "Frame behavior", switching a surface the
--- Header page owns -- so it sat three clicks from every control that styles the thing it turns
--- off. The control moved with the settings redesign; the PATH moved with it, because a row on
--- the Header page whose path says `frame` misleads the next reader of the schema and reads
--- wrong in `/mm set window.frame.titleBar`.
---
--- Carried across rather than defaulted: a player who turned their title bar off must not log
--- in to it back on. An ABSENT key is left absent, because absent means "never changed from the
--- default" -- writing one here would freeze today's default into every stored profile and the
--- default could never move again.
---
--- Pruned rather than left, for the reason every step here gives: AceDB merges defaults in and
--- never removes what they stopped naming, so a field nobody prunes outlives its reader.
migrations[12] = function(db)
    for _, profile in ipairs(allProfiles(db)) do
        for _, w in ipairs(type(profile.windows) == "table" and profile.windows or {}) do
            local frame = type(w) == "table" and w.frame
            if type(frame) == "table" and frame.titleBar ~= nil then
                if type(w.header) ~= "table" then w.header = {} end
                w.header.show = frame.titleBar
                frame.titleBar = nil
            end
        end
    end

    db.global.schemaVersion = 13
end
```

- [ ] **Step 6: Run the tests**

```sh
lua tests/run.lua 2>&1 | tail -20
```

Expected: PASS, including `test_schema_defaults.lua` — the schema default and the profile default must both be `true`.

- [ ] **Step 7: Note the copy-settings consequence, and confirm it is the right one**

This rename moves a key from the `frame` storage sub-tree to the `header` one, and both are
`COPY_GROUPS` entries — so *Copy settings from* still carries the toggle, but it now travels with
**Header** rather than with **Frame**. That is the correct half: the toggle switches the header
on, so copying a window's header without its on/off switch would be the surprising outcome. No
code change; add a sentence saying so to `docs/schema.md` in Task 14.

```sh
grep -n 'header' modules/WindowManager.lua | sed -n '1,4p'
```

Expected: `header` present in `COPY_GROUPS`. If it were not, this rename would silently drop the
toggle out of copy-settings altogether and the plan would need a `COPY_GROUPS` edit here.

- [ ] **Step 8: Confirm nothing still names the old path**

```sh
grep -rn 'titleBar' --include='*.lua' --include='*.md' . | grep -v '^./libs\|^./tests/_kit\|^./core/Database.lua\|^./docs/superpowers'
```

Expected: no hits. `core/Database.lua` keeps one, in the migration.

- [ ] **Step 9: Lint and commit**

```sh
luacheck .
git add settings/Schema.lua defaults/Profile.lua core/Database.lua modules/ tests/test_database.lua
git commit -m "Move the title-bar toggle onto the header, path and all

It switched a surface the Header page owns while living on Frame under
'Frame behavior', three clicks from every control that styles the
thing it turns off.

The path moved with the control rather than being left for tidiness'
sake: a row on the Header page whose path says frame misleads the next
reader and reads wrong in /mm set. A stored OFF carries across; an
absent key stays absent, because writing one would freeze today's
default into every profile and the default could never move again."
```

---

### Task 10: The header controls get colour modes

**Files:**
- Modify: `settings/Schema.lua` — two rows removed, two added; a new values table
- Modify: `defaults/Profile.lua`, `modules/HeaderControls.lua:489-510`
- Modify: `core/Database.lua` — extend `migrations[12]`
- Test: `tests/test_headercontrols.lua`, `tests/test_database.lua`

**Interfaces:**
- Consumes: Task 9's `migrations[12]`.
- Produces: `window.frame.controlColorMode` and `window.frame.controlHoverColorMode` — `string`, default `"custom"`, values `{ class, custom }`. `window.frame.controlClassColor` and `.controlHoverClassColor` no longer exist.

- [ ] **Step 1: Write the failing tests**

In `tests/test_headercontrols.lua`, replace the two cases at lines ~222 and ~245 (which set `controlClassColor` / `controlHoverClassColor`) with:

```lua
test("HeaderControls: each colour has its OWN colour mode", function()
    -- Two modes rather than one, because hover and rest are two independent answers. A shared
    -- mode would make the pointer's colour identical to the resting one for anybody who chose
    -- class, which is the one thing a hover colour must never be.
    -- red under: a single `controlColorMode` key driving both, or reading the retired boolean.
    local inst, window = scene(function(cfg)
        cfg.frame.controlColor          = { r = 0, g = 0, b = 1, a = 1 }
        cfg.frame.controlHoverColor     = { r = 0, g = 1, b = 0, a = 1 }
        cfg.frame.controlColorMode      = "class"
        cfg.frame.controlHoverColorMode = "custom"
    end)
    -- Compared against the reader itself rather than against a literal: whose class it is, is
    -- the subject of another case, and hard-coding a hue here would only re-test the mock.
    local cr, cg, cb = inst.NS.PlayerClassRGB()
    assertTrue(cr ~= nil, "the scene has no readable class to colour with")

    local r, g, b = tintOf(window.controls.settings)
    assertEqual(r .. "," .. g .. "," .. b, cr .. "," .. cg .. "," .. cb,
        "the resting colour is not classed")

    window.controls.settings:_run("OnEnter")
    local hr, hg, hb = tintOf(window.controls.settings)
    assertEqual(hr .. "," .. hg .. "," .. hb, "0,1,0",
        "the resting mode classed the hover colour too")
end)

test("HeaderControls: the hover mode classes the hover colour and nothing else", function()
    -- The other direction, and the one the type change put at risk: `hovered and A or B` used
    -- to answer B whenever A was false, and a mode STRING is never falsy -- so the same idiom
    -- would now answer the hover mode always instead of the resting one always. Same trap,
    -- opposite direction.
    -- red under: collapsing the resting/hover branch back to that idiom.
    local inst, window = scene(function(cfg)
        cfg.frame.controlColor          = { r = 0, g = 0, b = 1, a = 1 }
        cfg.frame.controlHoverColor     = { r = 0, g = 1, b = 0, a = 1 }
        cfg.frame.controlColorMode      = "custom"
        cfg.frame.controlHoverColorMode = "class"
    end)
    local cr, cg, cb = inst.NS.PlayerClassRGB()
    assertTrue(cr ~= nil, "the scene has no readable class to colour with")

    local r, g, b = tintOf(window.controls.settings)
    assertEqual(r .. "," .. g .. "," .. b, "0,0,1", "the hover mode classed the resting colour")

    window.controls.settings:_run("OnEnter")
    local hr, hg, hb = tintOf(window.controls.settings)
    assertEqual(hr .. "," .. hg .. "," .. hb, cr .. "," .. cg .. "," .. cb,
        "the hover mode did not class the hover colour")
end)
```

`scene(configure)` and `tintOf(button)` are the file's own helpers, at `tests/test_headercontrols.lua:21` and `:165`. The two cases above replace the existing `each colour has its OWN class-colour flag` (line ~215) and `the hover flag classes the hover colour and nothing else` (line ~243) in place — same names' worth of coverage, one type later.

Append to `tests/test_database.lua`:

```lua
test("Database: v12 -> v13 turns the control class-colour flags into modes", function()
    -- The two booleans sat beside colour pickers while every other surface in this addon
    -- expresses the same choice as a mode dropdown. A stored `true` becomes "class"; a stored
    -- `false` becomes "custom", which is what it already meant.
    -- red under: mapping false to nil, which leaves the row reading the schema default.
    local inst = T.load()
    local db = inst.NS.db

    db.global.schemaVersion = 12
    local w = db.profile.windows[1]
    w.frame.controlClassColor      = true
    w.frame.controlHoverClassColor = false

    inst.NS.Database.Migrate(db)

    assertEqual(w.frame.controlColorMode, "class")
    assertEqual(w.frame.controlHoverColorMode, "custom")
    assertNil(w.frame.controlClassColor)
    assertNil(w.frame.controlHoverClassColor)
end)
```

- [ ] **Step 2: Run and confirm failure**

```sh
lua tests/run.lua 2>&1 | tail -20
```

Expected: FAIL.

- [ ] **Step 3: Add the values table and the two rows**

In `settings/Schema.lua`, beside `TEXTCOLOR_VALUES`:

```lua
-- TWO modes, not the three every text surface offers. "Per-statistic" cannot say anything true
-- about a header BUTTON: a close box does not belong to a statistic, so the option could only
-- ever paint it the sort column's colour -- which is a fact already on screen in that column's
-- own header and in its arrow.
local CONTROLCOLOR_VALUES = {
    class  = L["Class color"],
    custom = L["Custom color"],
}
local CONTROLCOLOR_SORT = { "class", "custom" }
```

Replace the two boolean rows with mode rows, each placed **directly before** its colour picker so the mode and the swatch pair onto one line:

```lua
    {
        path = "window.frame.controlColorMode", type = "string", default = "custom",
        values = CONTROLCOLOR_VALUES, sorting = CONTROLCOLOR_SORT,
        page = "header", group = L["Button style"],
        label = L["Control color mode"],
        desc = L["What colors the header controls at rest."],
    },
    {
        path = "window.frame.controlColor", type = "color",
        default = { r = 1, g = 1, b = 1, a = 1 },
        page = "header", group = L["Button style"],
        label = L["Control color"], desc = L["Color of the header controls at rest."],
    },
    {
        path = "window.frame.controlHoverColorMode", type = "string", default = "custom",
        values = CONTROLCOLOR_VALUES, sorting = CONTROLCOLOR_SORT,
        page = "header", group = L["Button style"],
        label = L["Control hover color mode"],
        desc = L["What colors a header control while the pointer is over it."],
    },
    {
        path = "window.frame.controlHoverColor", type = "color",
        default = { r = 1, g = 0.82, b = 0, a = 1 },
        page = "header", group = L["Button style"],
        label = L["Control hover color"],
        desc = L["Color of a header control while the pointer is over it."],
    },
```

Add `Control color mode`, `Control hover color mode` and their descriptions to `locales/enUS.lua`.

- [ ] **Step 4: Update `defaults/Profile.lua`**

Delete `controlClassColor` and `controlHoverClassColor`; add `controlColorMode = "custom"` and `controlHoverColorMode = "custom"` in schema order.

- [ ] **Step 5: Update `modules/HeaderControls.lua`**

Replace the `classed` block at lines ~500-506:

```lua
    -- Spelled out rather than `hovered and A or B`, and the reason survived the type change: a
    -- mode string is never falsy, so the idiom would now answer the HOVER mode always instead of
    -- the resting one always. Same trap, opposite direction, still worth the four lines.
    local mode
    if hovered then
        mode = frameCfg.controlHoverColorMode
    else
        mode = frameCfg.controlColorMode
    end

    if mode == "class" and NS.PlayerClassRGB then
```

- [ ] **Step 6: Extend the migration**

Inside `migrations[12]`'s window loop in `core/Database.lua`, after the `titleBar` clause:

```lua
            -- The two class-colour flags become modes. A stored `false` becomes "custom", which
            -- is what it already meant -- mapping it to nil instead would leave the row reading
            -- the schema default, which is the same value today and need not be tomorrow.
            if type(frame) == "table" then
                if frame.controlClassColor ~= nil then
                    frame.controlColorMode = frame.controlClassColor and "class" or "custom"
                    frame.controlClassColor = nil
                end
                if frame.controlHoverClassColor ~= nil then
                    frame.controlHoverColorMode =
                        frame.controlHoverClassColor and "class" or "custom"
                    frame.controlHoverClassColor = nil
                end
            end
```

Extend the `migrations[12]` doc comment to name this second change — the step does two things now, and a comment describing one of them is worse than none.

- [ ] **Step 7: Run the tests**

```sh
lua tests/run.lua 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 8: Confirm nothing still names the flags**

```sh
grep -rn 'ClassColor' --include='*.lua' . | grep -v '^./libs\|^./tests/_kit\|^./core/Database.lua'
```

Expected: no hits outside the migration.

- [ ] **Step 9: Lint and commit**

```sh
luacheck .
git add settings/Schema.lua defaults/Profile.lua modules/HeaderControls.lua core/Database.lua locales/enUS.lua tests/
git commit -m "The header controls get a colour mode, like every other surface

Two booleans sat beside two colour pickers while every other surface
in this addon expresses the same choice as a mode dropdown -- so one
control read 'Use class color' and the next read 'Text color mode',
for the same decision.

Two modes rather than three: per-statistic cannot say anything true
about a close box. The spelled-out resting/hover branch survives the
type change, because a mode string is never falsy -- the idiom it
avoids would now answer the hover mode always instead of the resting
one always."
```

---

### Task 11: The five schema pages adopt tabs

**Files:**
- Modify: `settings/Frame.lua:49`, `settings/Header.lua:40`, `settings/Bars.lua:57`, `settings/Tooltip.lua`, `settings/Visibility.lua`, `settings/General.lua:160`
- Test: `tests/test_options_panel.lua`

**Interfaces:**
- Consumes: `H.RenderTabbedSchema`, `H.PageBanner` (Task 12 supplies the spec builder).
- Produces: each page's renderer draws its tabs. `ctx.activeTab` is live on each.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_options_panel.lua`:

```lua
-- ---------------------------------------------------------------------------
-- Tabs
-- ---------------------------------------------------------------------------

-- Every page that draws a strip, and the tab it opens on. Profiles is absent because its widget
-- tree is AceConfigDialog's; Windows and Columns are here because they are tabbed too, through
-- their own bespoke builders rather than through RenderTabbedSchema.
local TABBED = {
    general    = "General",
    windows    = "Window",
    frame      = "Size and position",
    header     = "Title bar",
    bars       = "Bar",
    tooltip    = "Tooltip",
    visibility = "Where to show this window",
    columns    = "Columns",
}

test("Panel: every tabbed page opens on its first tab and draws a strip", function()
    -- red under: a page left on RenderSchema, or one whose renderer draws the strip after the
    -- rows so the band is reserved too late.
    local inst = T.load()
    local L = inst.NS.L
    for page, firstTab in pairs(TABBED) do
        local ctx = showPage(inst, page)
        assertEqual(ctx.activeTab, L[firstTab], page .. ": opens on its first tab")
        assertTrue(#(ctx.__tabKids or {}) >= 2, page .. ": drew a strip")
    end
end)

test("Panel: Profiles draws no strip", function()
    -- Its widget tree belongs to AceConfigDialog, which reuses it and re-reads the profile on
    -- every Open. A strip over that would be tabs this addon cannot fill.
    -- red under: adding profiles to the tabbed set for consistency's sake.
    local inst = T.load()
    local ctx = showPage(inst, "profiles")
    assertEqual(#(ctx.__tabKids or {}), 0)
end)

test("Panel: switching tabs re-renders without leaving the previous tab's widgets behind",
function()
    -- The Frame page's second tab is Rows. Asserting on the TAB rather than on a child count is
    -- deliberate: a renderer that appended instead of clearing would still change the count, so
    -- a count assertion passes for the wrong reason. What proves the clear is that a widget from
    -- the tab we LEFT is gone.
    -- red under: rendering the new group without ClearScroll, which appends it under the old.
    local inst = T.load()
    local L = inst.NS.L
    local ctx = showPage(inst, "frame")

    local function labelled(name)
        for _, w in ipairs(ctx.scroll and ctx.scroll.children or {}) do
            for _, child in ipairs(w.children or {}) do
                if child.labelText == name then return true end
            end
        end
        return false
    end

    assertTrue(labelled(L["Width"]), "the Frame page did not open on Size and position")
    ctx.__tabKids[2]:__fire("OnClick")
    assertEqual(ctx.activeTab, L["Rows"])
    assertTrue(labelled(L["Maximum rows"]), "the Rows tab did not render")
    assertFalse(labelled(L["Width"]), "the previous tab's widgets were left behind")
end)
```

`showPage(inst, pageKey)` is the file's own local at `tests/test_options_panel.lua:92` — it takes
**two** arguments and drives the genuine deferred first render through `panelFor` (line 64). Use
it as-is; do not add a second helper. Every case above builds its own instance with `T.load()`,
matching the file's existing cases.

- [ ] **Step 2: Run and confirm failure**

```sh
lua tests/run.lua 2>&1 | tail -20
```

Expected: FAIL — `ctx.activeTab` nil on every page.

- [ ] **Step 3: Switch the five one-call pages**

In `settings/Frame.lua`, `Header.lua`, `Bars.lua`, `Tooltip.lua` and `Visibility.lua`, inside each `H.SetRenderer(ctx, function(c) ... end)` body, replace:

```lua
        H.RenderSchema(c, PAGE)
```

with:

```lua
        H.WindowBanner(c)
        H.RenderTabbedSchema(c, PAGE)
```

`H.WindowBanner` arrives in Task 12. Until then these five pages fail at render — that is expected, and Task 12's commit is what makes this task's tests pass. **Run the two tasks back to back; do not commit Task 11 alone.**

- [ ] **Step 4: Switch General**

`settings/General.lua` is tabbed but has **no** banner — it is the one page that is not about a window. Replace its `H.RenderSchema(c, PAGE)` with `H.RenderTabbedSchema(c, PAGE)` and leave the `afterGroup` hook that draws the two reset buttons pointed at `L["Maintenance"]` rather than at its old group name.

- [ ] **Step 5: Hold**

Do not run the gate yet — Task 12 completes the change. Proceed directly to Task 12.

---

### Task 12: The window banner replaces the picker

**Files:**
- Modify: `settings/Windows.lua` — delete the Active-window dropdown, add `H.WindowBanner`, tab the page
- Modify: `settings/Columns.lua` — banner + its two schema tabs alongside the block editor
- Test: `tests/test_options_panel.lua`

**Interfaces:**
- Consumes: `H.PageBanner`, `NS.State.activeWindowId`, `NS.RefreshOptionsPanel`.
- Produces: `H.WindowBanner(ctx)` → the banner dropdown, decorated onto `NS.Helpers` by `settings/Windows.lua` exactly as `H.ActionDropdown` and `H.Relayout` already are.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_options_panel.lua`:

```lua
test("Panel: every window sub-page banners the active window, and Windows has no second picker",
function()
    -- The banner is the ONLY picker (options-ui-§14). A page that kept its own would be a
    -- second writer of one piece of session state -- a synchronisation problem invented by the
    -- design, which would then have to be solved forever.
    -- red under: leaving the Active window dropdown on the Windows page, or bannering only some
    -- of the sub-pages.
    local inst = T.load()
    local SUBPAGES = { "windows", "frame", "header", "bars", "tooltip", "visibility", "columns" }
    for _, page in ipairs(SUBPAGES) do
        local ctx = showPage(inst, page)
        assertTrue(ctx.__bannerHeight ~= nil and ctx.__bannerHeight > 0,
            page .. ": drew no banner")
    end

    -- The banner's own dropdown is parented into the chrome band, NOT added to the scroll, so
    -- anything still carrying this label INSIDE the scroll is the old picker surviving.
    local dropdowns = 0
    local ctx = showPage(inst, "windows")
    for _, w in ipairs(ctx.scroll and ctx.scroll.children or {}) do
        for _, child in ipairs(w.children or {}) do
            if child.type == "Dropdown" and child.labelText == inst.NS.L["Active window"] then
                dropdowns = dropdowns + 1
            end
        end
    end
    assertEqual(dropdowns, 0, "the Windows page kept its own picker")
end)

test("Panel: choosing a window in the banner retargets every page and keeps the tab", function()
    -- Comparing one surface across two windows is the reason to switch from a sub-page at all,
    -- so the tab is a property of the page and not of the window (options-ui-§14).
    -- red under: resetting activeTab on a structural refresh.
    local inst = T.load()
    assertTrue(inst.NS.WindowManager:Create("Second"))
    local list = inst.NS.Database.GetWindows()

    local ctx = showPage(inst, "bars")
    ctx.__tabKids[3]:__fire("OnClick")
    assertEqual(ctx.activeTab, inst.NS.L["Bar border"])

    local banner = ctx.__bannerWidget
    banner:__fire("OnValueChanged", list[2].id)

    assertEqual(inst.NS.State.activeWindowId, list[2].id)
    assertEqual(ctx.activeTab, inst.NS.L["Bar border"], "the tab survived the retarget")
end)
```

- [ ] **Step 2: Run and confirm failure**

```sh
lua tests/run.lua 2>&1 | tail -20
```

Expected: FAIL — `H.WindowBanner` is nil, so Task 11's five pages raise.

- [ ] **Step 3: Write `H.WindowBanner`**

In `settings/Windows.lua`, beside `H.ActionDropdown` and `H.Relayout`, and for the same stated reason (decorated onto the instance so `settings/Columns.lua` and the five schema pages reach the one implementation):

```lua
--- The page banner: which window this page is editing, and the picker for it.
---
--- Decorated onto the instance rather than kept file-local because SEVEN pages draw it, and a
--- second copy is how two of them end up disagreeing about what the list contains. It stays
--- host-side rather than going upstream because the library's O.PageBanner is the generic half
--- -- the label, the anchoring and the band -- and this is the part that knows what a window is.
---
--- The onSelect writes NS.State.activeWindowId and forces a STRUCTURAL refresh, because the
--- other pages did not change VALUE, they changed SUBJECT. That sweep is also what re-renders
--- every other banner, which is why there is no propagation code here: one writer, one read at
--- render time.
H.WindowBanner = function(ctx)
    if not (H.PageBanner and ctx) then return nil end

    local list, order = {}, {}
    for _, w in ipairs(windows()) do
        list[w.id] = w.name or ("#" .. tostring(w.id))
        order[#order + 1] = w.id
    end

    local active = activeWindow()
    local dd = H.PageBanner(ctx, {
        label = L["Active window"],
        tooltip = L["The window every setting on this page belongs to. Changing it here changes it everywhere."],
        list = list,
        order = order,
        value = active and active.id,
        onSelect = function(id)
            if not id or (NS.State and id == NS.State.activeWindowId) then return end
            -- The SAME two calls the dropdown this replaces made, in the same order. Assigning
            -- NS.State.activeWindowId here instead would be a second writer of the pointer that
            -- skips whatever State.SetActiveWindow grows next, and afterRegistryChange is the
            -- file's one name for "every panel is now looking at a different window".
            if NS.State then NS.State.SetActiveWindow(id) end
            afterRegistryChange()
        end,
    })
    -- Parked on the ctx so a suite can drive the selection the way a click would; the library
    -- keeps its own widgets private and a test that cannot reach this one cannot prove the
    -- retarget happens at all.
    ctx.__bannerWidget = dd
    return dd
end
```

`afterRegistryChange()` is this file's existing local at `settings/Windows.lua:203`; it wraps the
argument-less `NS.RefreshOptionsPanel()`, which is `Helpers.RefreshAllPanels()`
(`settings/OptionsSetup.lua:369`). **`NS.RefreshOptionsPanel` takes no argument** — do not pass
one. `NS.State.SetActiveWindow(id)` is `core/State.lua:105`. All three already exist; this is a
move of the dropdown's two-line handler, not a new one.

- [ ] **Step 4: Rebuild the Windows page**

In `settings/Windows.lua`'s renderer: draw `H.WindowBanner(c)` first, **delete** the Active-window `H.ActionDropdown` entirely, and split the remaining content into two tabs — `L["Window"]` (the name row plus New / Duplicate / Delete) and `L["Copy from"]` (the source picker, the group filter and the Copy button). Because this page's content is bespoke rather than schema-driven, drive its strip with `H.TabStrip` directly and branch on `c.activeTab`:

```lua
        H.WindowBanner(c)
        H.TabStrip(c, {
            tabs = {
                { key = L["Window"],    label = L["Window"] },
                { key = L["Copy from"], label = L["Copy from"] },
            },
            value = c.activeTab or L["Window"],
            onSelect = function(key)
                if key == c.activeTab then return end
                c.activeTab = key
                H.ClearScroll(c)
                H.RefreshPanel(c, true)
            end,
        })
        c.activeTab = c.activeTab or L["Window"]
        if c.activeTab == L["Window"] then
            -- the name row and the three registry buttons, as they are drawn today
        else
            -- copy settings from, as it is drawn today
        end
```

- [ ] **Step 5: Rebuild the Columns page**

`settings/Columns.lua` gets the same treatment with three tabs: `L["Columns"]` (the existing block editor, unchanged), `L["Header text"]` and `L["Header background"]`. The two schema tabs render through `H.RenderRows(c, rowsOfGroup, nil, nil, { noHeadings = true })` — filter `NS.SchemaForPage("columns")` by `row.group` — because the block editor is not a schema group and `RenderTabbedSchema` would not know to include it.

Draw `H.WindowBanner(c)` before the strip.

- [ ] **Step 6: Run the whole suite**

```sh
lua tests/run.lua 2>&1 | tail -30
```

Expected: PASS, including Task 11's three cases.

- [ ] **Step 7: Lint and commit both tasks together**

```sh
luacheck .
git add settings/
git commit -m "Banner every window page, and delete the picker it replaces

Six pages edited whichever window a picker two pages up had selected,
and none of them said so -- the tree faked the distinction with a
typographic indent because Blizzard offers no third level.

The banner carries the picker rather than naming the window, and the
Windows page's own dropdown is DELETED rather than kept in step. Two
controls over one piece of session state is a synchronisation problem
the design would then own forever; one writer and a read at render
time is not a problem at all."
```

---

### Task 13: `/mm list` names the tab

**Files:**
- Modify: `settings/Slash.lua:207`
- Test: `tests/test_slash.lua`

**Interfaces:**
- Consumes: the schema's `page` and `group`.
- Produces: `groupKey(row)` → `"<page> › <group>"`.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_slash.lua`, following the file's existing capture idiom:

```lua
test("Slash: /mm list heads each block with the page AND the tab", function()
    -- `page` was the whole heading while a page was one scroll. It is now a page and a tab, and
    -- a CLI that named only the first half would send someone to a page with no way to say
    -- which of its six tabs the setting is on.
    -- red under: reverting groupKey to row.page, or joining with a plain "/" the panel never shows.
    local inst = T.load()
    local text = joined(say(inst, "list"))
    assertTrue(text:find("frame \226\128\186 ", 1, true) ~= nil,
        "no page \226\128\186 tab heading in the listing")
end)
```

`say(inst, msg)` and `joined(lines)` are the file's own helpers, at `tests/test_slash.lua:26`
and `:34`. The existing case at line 194 (`list groups by the row's PAGE`) asserts only that
`"frame"` appears somewhere in the listing, so it survives this change unedited — leave it.

- [ ] **Step 2: Run and confirm failure**

```sh
lua tests/run.lua 2>&1 | tail -20
```

Expected: FAIL — the listing heads blocks with a bare page key.

- [ ] **Step 3: Change `groupKey`**

In `settings/Slash.lua`, replace the `groupKey` descriptor field and extend its comment:

```lua
    -- Written out rather than omitted, and it names BOTH halves of where a setting lives. `page`
    -- was the whole answer while a page was one scroll; a page is now a strip of tabs
    -- (options-ui-§13), and a listing that named only the page would send someone to a screen
    -- with no word on which of its six tabs to click. The separator is a byte escape for the
    -- same reason every other non-ASCII string in this addon is: a literal depends on the file's
    -- encoding surviving every editor between here and a client.
    groupKey = function(row)
        return (row.page or "?") .. " \226\128\186 " .. (row.group or "?")
    end,
```

- [ ] **Step 4: Run the tests**

```sh
lua tests/run.lua 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 5: Lint and commit**

```sh
luacheck .
git add settings/Slash.lua tests/test_slash.lua
git commit -m "Name the tab in /mm list, not just the page

A page was one scroll when `page` became the whole heading. It is a
strip of tabs now, and a listing naming only the first half sends
someone to a screen with no word on which of six tabs to click."
```

---

### Task 14: Documentation

**Files:**
- Modify: `docs/settings-panel.md`, `docs/schema.md`, `docs/ARCHITECTURE.md`, `docs/common-tasks.md`, `README.md`

**Interfaces:**
- Consumes: the finished behaviour.
- Produces: docs that match the code. No code changes.

- [ ] **Step 1: Verify every count claim before writing one**

```sh
python3 - <<'PY'
import re
src = open('settings/Schema.lua', encoding='utf-8').read()
rows, i = [], 0
while True:
    m = re.compile(r'path\s*=\s*"([^"]+)"').search(src, i)
    if not m: break
    nxt = re.compile(r'path\s*=\s*"').search(src, m.end())
    blk = src[m.start(): nxt.start() if nxt else len(src)]
    def g(k):
        mm = re.search(k + r'\s*=\s*(?:L\[)?"([^"]+)"', blk)
        return mm.group(1) if mm else None
    rows.append((g('page'), g('group'), 'hidden = true' in blk))
    i = m.end()
from collections import OrderedDict
pages = OrderedDict()
for p, gp, h in rows:
    pages.setdefault(p, OrderedDict()).setdefault(gp, [0, 0])
    pages[p][gp][0] += 1
    if h: pages[p][gp][1] += 1
for p, gs in pages.items():
    print(f"{p}: {sum(v[0] for v in gs.values())} rows, {len(gs)} tabs")
    for gp, (n, hid) in gs.items():
        print(f"    {gp}: {n}" + (f" ({hid} hidden)" if hid else ""))
print("TOTAL", len(rows))
PY
```

Use these numbers — not the ones in this plan's tables, which are the design's intent — for every count you write down.

- [ ] **Step 2: Rewrite `docs/settings-panel.md`**

Update: the pages table's row counts and descriptions; a new section **The tab strip and the banner** explaining that one tab is one group, that the strip wraps, that the active tab is session-only per page, and that the banner is the only picker; the *bespoke controls* table (Reset position and Reset all settings now live under General's Maintenance tab); and the `The indent, and why the tree needs one` section, which is now half-solved — say that the banner carries the load the indent was faking, and that the indent stays because the tree's two levels are still real.

- [ ] **Step 3: Update `docs/schema.md`**

The `group` field's description becomes "section heading inside the page, **and the tab label on a tabbed page** — one tab is exactly one group". Update the `header` and `columns` sub-trees for the moved column-header rows, `frame`/`header` for the renamed `show`, and the header-controls block for the two colour modes. Add a `v12 -> v13` line wherever the file lists migrations.

- [ ] **Step 4: Update `docs/ARCHITECTURE.md`**

Update the settings-panel summary and the schema-version line to 13. **Check the Documented deviations register** — if it carries a row about the options UI that this work resolves, retire it, and note that §13/§14 are now in the standard rather than a deviation.

- [ ] **Step 5: Update `docs/common-tasks.md`**

The "add a setting" recipe now has to say which tab, and that a new tab is a new `group` and nothing else. Add a short recipe for splitting an over-full tab.

- [ ] **Step 6: Update `README.md`**

The settings section's description of the panel, and the bundled-LibKa0s line to v1.20.0 if the README states it.

- [ ] **Step 7: Sweep for stale references**

```sh
grep -rn 'Frame header\|Header controls\|Column headers\|Cell text\|Tooltip bars\|Row layout\|Frame behavior\|controlClassColor\|frame\.titleBar' docs/ README.md CLAUDE.md \
  | grep -v 'docs/audits/\|docs/reviews/\|docs/automated-tests/\|docs/superpowers/'
```

Expected: no hits. The frozen bundles are excluded deliberately — they record what was true when they were taken.

- [ ] **Step 8: Final gate and commit**

```sh
lua tests/run.lua && luacheck .
git add docs README.md
git commit -m "Say what the settings panel is now

Nine pages of tabs over a banner, 137 rows, one section that is not a
tab and one page that is not tabbed. The counts are read out of the
schema rather than carried over from the design, because the design's
numbers were intent and these are what shipped."
```

---

## Verification

Run in `MultiMeters` after Task 14:

```sh
lua tests/run.lua && luacheck .
```

Expected: every suite passing, `0 warnings / 0 errors`.

## Smoke tests (in client, after the branch is loaded)

These cannot be reached headlessly and are the acceptance list.

- [ ] Every one of Frame, Header, Bars, Tooltip, Visibility, Columns and Windows shows the banner naming the active window; changing it on any one changes it on all the others.
- [ ] Switching windows while on Bars' *Bar border* tab lands on *Bar border* for the new window.
- [ ] Clicking a tab **in combat** is refused with the standard grey message and leaves the page as it was.
- [ ] Clicking the tab you are already on does nothing at all — no flicker, no refusal message.
- [ ] Frame's six tabs and Bars' six fit one row at default UI scale; Header's five fit; note any that wrap.
- [ ] **Tab art:** the strip is a flat backing with the active tab darker. Decide in the client whether that reads as tabs or wants Blizzard's tab atlas — this is the one deliberately-open question in the plan, and changing it is a `LibKa0s/OptionsWidgets.lua` edit plus a minor bump.
- [ ] The Defaults button on a tabbed page resets the **whole page**, not the visible tab.
- [ ] With a skinning addon (ElvUI / AddOnSkins) loaded, the banner's dropdown is skinned — it is built lazily on first `OnShow`, like the Defaults button.
- [ ] A profile stored before this branch opens with its title bar and its control colours exactly as they were (the v12 → v13 migration).
- [ ] `/mm list` heads each block `frame › Rows`, and `/mm set window.header.show false` hides the title bar.
