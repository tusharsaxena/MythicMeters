# Shared dropdown + export-window UX — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote BankLedger's flat dropdown into a new `LibKa0s-Widgets-1.0` major, adopt it in both BankLedger and MultiMeters, and land four MultiMeters export-window UX corrections.

**Architecture:** Three repos, two phases separated by a library release. MultiMeters' three self-contained corrections land first because they depend on nothing. Then LibKa0s gains a new major carrying BankLedger's dropdown verbatim (plus its existing test suite, which moves with it), is dry-run-adopted in both consumers before being tagged, and is released. Then each consumer re-vendors and swaps its local implementation for the library's.

**Tech Stack:** Lua 5.1 (WoW client), LibStub, the LibKa0s vendored-payload model, the Ka0s headless test kit (`tests/_kit/`), luacheck, lizard.

**Spec:** `docs/superpowers/specs/2026-08-24-shared-dropdown-and-export-ux-design.md` (in this repo). Executors read both.

## Global Constraints

- **Line endings: CRLF.** Every repo here pins `* text=auto eol=crlf` in `.gitattributes`, except `*.sh` which is LF. A file written by `sed`, a heredoc or a generator lands LF and must be renormalized before it is staged. Verify with `CR == LF`: `tr -dc '\r' < f | wc -c` must equal `tr -dc '\n' < f | wc -c`.
- **LibKa0s file minors are the mechanism, not the tag.** LibStub keeps the highest minor offered for a major and discards the rest. A changed file whose `MINOR` did not move does not ship. Only files that actually change get bumped — never the whole library in lockstep.
- **A LibKa0s minor bump is not releasable without its API document.** `tests/test_versioning.lua` derives `docs/api/<Major>/version-<minors>-docs.md` from each major's live `lib.MODULES` and stays red until the file exists.
- **The provenance line and the vendored bytes move in the same commit.** Each consumer's `CLAUDE.md` names the LibKa0s tag it bundles; `tests/test_vendor_sync.lua` diffs `libs/LibKa0s/` and `tests/_kit/` against that tag in the sibling repo. Bumping one without the other is a red suite, correctly.
- **The library never resolves host art.** `Media.Icon` takes the consuming addon's name and a vendored copy cannot know which folder it was copied into. Every texture path and font path the widget draws arrives as a parameter.
- **Green gate before any version bump, in every repo:** `luacheck .` at 0/0 (scoped by that repo's `.luacheckrc`) and `lua tests/run.lua` all-pass. MultiMeters and BankLedger additionally run `tests/perf.lua` and `lizard` with zero functions above CCN 15 before a release bump.
- **Repo versions at plan time:** LibKa0s `v1.10.2` (Core 6, Media 3, DebugLog 10, Slash 7, Options 8, OptionsWidgets 7, OptionsScroll 3, Perf 7, PerfPanel 4, kit revision 11). BankLedger `1.0.0`, MultiMeters `0.1.0`. Both consumers bundle LibKa0s **v1.10.2**. The release cut by this plan is **v1.11.0** (new major ⇒ minor semver bump).
- **Scope is LibKa0s, BankLedger and MultiMeters, and nothing else.** Six other addons in the collection (AbsorbTracker, ConsumableMaster, KickCD, LootHistory, PanelMaster, PrettyChat, WhatGroup) vendor LibKa0s and several draw their own dropdowns. **Do not touch them.** They adopt later, from the prompt Task 10 produces. The only thing this plan writes about them is the Consumers table in `LibKa0s/docs/releasing.md`, which is a record of who vendors what — updating it is not adopting them.
- **Comments are the deliverable here as much as the code.** Both codebases carry long "why" headers, and several of them state reasoning this plan reverses. Where a task says a comment is rewritten, rewriting it is part of the task's definition of done — deleting it is not.

---

## File Structure

**LibKa0s** (new major)

| File | Responsibility |
|---|---|
| `LibKa0s/Widgets.lua` | **Create.** The whole `LibKa0s-Widgets-1.0` major: `Widgets.Dropdown`, the shared pooled popup menu, the click catcher, the pooled row buttons. Depends on `Core` only. |
| `LibKa0s/LibKa0s.xml` | Modify. One `<Script>` line, after `Media.lua`. |
| `tests/test_widgets.lua` | **Create.** The dropdown/menu suite, moved from `BankLedger/tests/test_browser.lua:469-662`, plus a local geometry-modelling frame factory and new cases for the three injected options. |
| `tests/run.lua` | Modify. A `MAJORS` row and a `Kit.run` suite entry. |
| `docs/api/LibKa0s-Widgets-1.0/version-1-docs.md` | **Create.** The public contract. Gated by `test_versioning.lua`. |
| `docs/api/README.md` | Modify. One table row. |
| `CHANGELOG.md` | Modify. The v1.11.0 block. |
| `docs/releasing.md` | Modify. Provenance template moves to v1.11.0; the semver in the header table. |
| `docs/test-cases.md` | Regenerate. |

**BankLedger** (adopts)

| File | Responsibility |
|---|---|
| `modules/Browser.lua` | Modify. Loses ~245 lines of widget machinery; `B:MakeDropdown` becomes a forwarder that injects the three host-resolved paths. Gains the degraded-load guard. |
| `tests/test_browser.lua` | Modify. The moved suite (`:469-662`) is deleted; the forwarder keeps a thin case. |
| `tests/test_marks.lua` | Modify. The `chevron-down` and `confirm` assertions re-point at the forwarder. |
| `tests/test_libka0s.lua` | Modify. `LibKa0s-Widgets-1.0` joins the majors this addon expects. |
| `core/MediaSetup.lua` | Modify. The icon-consumer table reworded. |
| `libs/LibKa0s/` + `CLAUDE.md` | Re-vendor at v1.11.0, same commit. |

**MultiMeters** (adopts, plus four corrections)

| File | Responsibility |
|---|---|
| `modules/Window.lua` | Modify. Sort arrow gains a LibKa0s-Media top rung. |
| `modules/Export.lua` | Modify. `FOLLOW_WINDOW` removed; whisper row reskinned; three selectors become `Widgets.Dropdown`; degraded-load refusal. |
| `settings/Schema.lua` | Modify. The `export.metric` row and its two derived tables removed. |
| `defaults/Profile.lua` | Modify. `metric` default becomes a real stat key. |
| `locales/enUS.lua` | Modify. Two strings removed. |
| `core/MediaSetup.lua` | Modify. Header note on the new icon consumers. |
| `tests/test_export.lua`, `test_window.lua`, `test_schema*.lua`, `test_locale.lua`, `test_degraded.lua`, `test_libka0s.lua` (if present) | Modify. |
| `docs/smoke-tests.md` | Modify. §25 rewritten for the new modal; a new in-client check for the sort arrow. |
| `libs/LibKa0s/` + `CLAUDE.md` | Re-vendor at v1.11.0, same commit. |

---

# Phase A — MultiMeters corrections that depend on nothing

Branch: `git checkout -b ux/export-corrections` in `MultiMeters/`. These three tasks touch no library and can be reviewed, merged and shipped without waiting on the LibKa0s release.

---

### Task 1: The sort arrow gains a LibKa0s-Media top rung

Spec §5. The column-header sort arrow currently resolves a Blizzard atlas with an ASCII fallback. It gains a rung above both: the collection's own `sort-up` / `sort-down`, tinted with the header colour, which is what BankLedger's `LedgerTable.lua` already draws.

**Files:**
- Modify: `modules/Window.lua:114-125` (the `SORT_*` constants and their comment), `modules/Window.lua:920-951` (the branch in `ApplyColumnHeaders`)
- Test: `tests/test_window.lua:992-1034`

**Interfaces:**
- Consumes: `NS.Icon(name)` from `core/MediaSetup.lua` — `@param name string`, `@return string|nil`. Answers nil when LibKa0s is absent or the name is not in the catalog.
- Produces: nothing other files read. `button.arrowTex` and `button.arrow` keep their current meanings.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_window.lua`, after the existing arrow cases:

```lua
test("The sort arrow prefers the collection's own art over the Blizzard atlas", function()
    -- The ladder's top rung. Red under: a build that still reaches straight for
    -- `auctionhouse-ui-sortarrow` while `sort-down.tga` sits unused in the payload.
    local inst = T.load()
    local window = inst.NS.WindowManager:Get(1)
    window:ApplyColumnHeaders()

    local marked = window.columnHeaders[2]
    assertEqual(marked.arrowTex.__texture, inst.NS.Icon("sort-down"),
        "the descending arrow is the shipped mark, not an atlas")
    assertTrue(marked.arrowTex:IsShown(), "and it is the rung actually drawn")
end)

test("The sort arrow's two directions are two assets, never one flipped", function()
    -- The atlas rung flips one texture with SetTexCoord because it has only one.
    -- The mark rung has both, so a flip here would draw an upside-down glyph that
    -- happens to look right and breaks the moment the art is redrawn.
    local inst = T.load()
    local window = inst.NS.WindowManager:Get(1)

    window.config.data.sortAscending = false
    window:ApplyColumnHeaders()
    local down = window.columnHeaders[2].arrowTex.__texture

    window.config.data.sortAscending = true
    window:ApplyColumnHeaders()
    local up = window.columnHeaders[2].arrowTex.__texture

    assertEqual(down, inst.NS.Icon("sort-down"))
    assertEqual(up, inst.NS.Icon("sort-up"))
    assertFalse(down == up, "ascending and descending are distinct assets")
end)

test("The sort arrow falls to the Blizzard atlas with no LibKa0s art", function()
    -- The rung below. Red under: a top rung that concatenates a nil path, or one
    -- that shows an empty texture rather than standing aside for the atlas.
    local inst = T.load()
    local realIcon = inst.NS.Icon
    inst.NS.Icon = function() return nil end

    local window = inst.NS.WindowManager:Get(1)
    window:ApplyColumnHeaders()
    local marked = window.columnHeaders[2]
    assertTrue(marked.arrowTex:IsShown() or marked.arrow:IsShown(),
        "the column still says which way it is sorted")
    assertFalse(marked.arrowTex.__texture == nil and marked.arrowTex:IsShown(),
        "and never shows a texture it failed to resolve")

    inst.NS.Icon = realIcon
end)
```

If `tests/test_window.lua` has no `T.load()` helper with a window at index 1, copy the two lines the existing case at `:992` uses to obtain `window` — that case is the model for these three.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd MultiMeters && lua tests/run.lua 2>&1 | grep -A3 "sort arrow"
```

Expected: three FAILs. The first two on `arrowTex.__texture` being nil (the atlas rung sets an atlas, never a texture path).

- [ ] **Step 3: Add the constants and rewrite their comment**

In `modules/Window.lua`, immediately after the existing `SORT_ASCII_UP` line (`:121`), add:

```lua
-- THE TOP RUNG, above both of the above, and the reason it is not simply the
-- only rung is the paragraph above: art that is NAMED at authoring time and
-- never checked is how this header failed twice. `NS.Icon` answers nil for an
-- absent library AND for a name the catalog does not ship, so the check is the
-- same call that produces the path — there is no window in which a name is
-- believed and not verified.
--
-- Two assets, not one flipped. The atlas rung flips `auctionhouse-ui-sortarrow`
-- with SetTexCoord because the client ships one arrow; the collection ships
-- both, and flipping one of a matched pair would draw an inverted glyph that
-- looks right today and stops looking right the moment the art is redrawn.
--
-- Tinted with the HEADER colour rather than shipped gold, exactly as
-- BankLedger's LedgerTable.lua tints the same two marks: the art is near-white
-- by contract, and near-white beside a gold label reads as a second colour
-- inside one string rather than as one control.
local SORT_MARK_DOWN = "sort-down"
local SORT_MARK_UP   = "sort-up"
```

- [ ] **Step 4: Add the branch in `ApplyColumnHeaders`**

In `modules/Window.lua`, inside `if key == sortKey then`, replace the line that opens the atlas branch so the mark is tried first. The existing block starts:

```lua
            local after = button.text:GetStringWidth() + 3
            local atlas = NS.Compat.FirstAtlas(
                data.sortAscending and SORT_ATLAS_UP or SORT_ATLAS_DOWN)

            if atlas then
```

becomes:

```lua
            local after = button.text:GetStringWidth() + 3
            local mark = NS.Icon and NS.Icon(
                data.sortAscending and SORT_MARK_UP or SORT_MARK_DOWN)
            local atlas = not mark and NS.Compat.FirstAtlas(
                data.sortAscending and SORT_ATLAS_UP or SORT_ATLAS_DOWN)

            if mark then
                button.arrowTex:ClearAllPoints()
                button.arrowTex:SetPoint("LEFT", button.text, "LEFT", after, 0)
                button.arrowTex:SetTexture(mark)
                -- No SetTexCoord: two assets, not one flipped. The atlas branch
                -- below flips because it has only one arrow to flip.
                button.arrowTex:SetTexCoord(0, 1, 0, 1)
                button.arrowTex:SetVertexColor(hr, hg, hb)
                button.arrowTex:Show()
                button.arrow:Hide()
            elseif atlas then
```

Leave the atlas branch's body, the `else` ASCII branch and the closing `end` exactly as they are. The `SetTexCoord(0, 1, 0, 1)` in the new branch is not decoration: `arrowTex` is reused across repaints and a coord left over from an atlas-rung frame would crop the mark.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd MultiMeters && lua tests/run.lua
```

Expected: all pass, including the three pre-existing arrow cases at `:992-1034` — they assert *that* an arrow is drawn and *that* the two directions differ, both of which the new rung satisfies.

- [ ] **Step 6: Lint**

```bash
cd MultiMeters && luacheck .
```

Expected: `0 warnings / 0 errors`.

- [ ] **Step 7: Commit**

```bash
cd MultiMeters
git add modules/Window.lua tests/test_window.lua
git commit -m "The column sort arrow wears the collection's own mark

It was reaching for auctionhouse-ui-sortarrow and flipping it, while
sort-up.tga and sort-down.tga sat unused in the vendored payload. Now the
mark is the top rung of the ladder that was already there, tinted with the
header colour the way BankLedger's column headers tint the same two marks.

The atlas and the ASCII rungs stay underneath. Two assets rather than one
flipped, so the ascending arrow is not an upside-down descending one."
```

---

### Task 2: Remove "Match the window"

Spec §7. `FOLLOW_WINDOW` (the empty string stored in `export.metric`) is removed. `Export.Open` seeds the metric from the invoking window's sort column instead, and the settings-panel row that seeding would render dead goes with it.

**Files:**
- Modify: `modules/Export.lua:87-91` (the constant), `:1086-1092` (`metricLabel`), `:1105-1131` (`ResolveMetric` + its docblock), `:1186-1200` (`openMetricMenu`), `:1444-1452` (`Export.Open`'s seeding comment)
- Modify: `settings/Schema.lua:371-380` (`EXPORTMETRIC_*`), `:1291-1297` (the row)
- Modify: `defaults/Profile.lua:495`
- Modify: `locales/enUS.lua:551-553`
- Test: `tests/test_export.lua:355-421`, `tests/test_schema.lua`, `tests/test_schema_defaults.lua`, `tests/test_locale.lua`

**Interfaces:**
- Consumes: `Const.STATS` (array, `{ key =, label =, isRate = }`), `Const.STAT_BY_KEY` (map keyed by `stat.key`) from `core/Constants.lua`.
- Produces: `Export.ResolveMetric(win) -> string` keeps its name and signature. Its contract narrows: it now always answers a key `Const.STAT_BY_KEY` holds, and no longer treats `""` as a meaningful stored choice.

- [ ] **Step 1: Rewrite the failing tests**

In `tests/test_export.lua`, replace the whole block from the `-- ResolveMetric` divider comment (`:355`) through the end of the "callable through the colon form" case (`:421`) with:

```lua
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
    assertNil(inst.NS.L["Match the window"],
        "the string is gone from the locale, not just from the menu")
end)
```

- [ ] **Step 2: Run to verify the new cases fail**

```bash
cd MultiMeters && lua tests/run.lua 2>&1 | grep -E "ResolveMetric|Metric selector"
```

Expected: "ships pinned to a real stat" FAILs (default is still `""`), "treats the old empty-string choice as unset" FAILs on the second assertion, "no sentinel entry" FAILs (the locale string still exists).

- [ ] **Step 3: Remove the constant and its two readers in `modules/Export.lua`**

Delete the `FOLLOW_WINDOW` local and its comment (`:87-91`). Then:

`metricLabel` loses its first branch —

```lua
local function metricLabel(statKey)
    if statKey == nil then return L["Unknown"] end
    local stat = Const.STAT_BY_KEY[statKey]
    if not stat then return L["Unknown"] end
    return L[stat.label] or stat.label
end
```

`ResolveMetric`'s body becomes —

```lua
function Export.ResolveMetric(win)
    if win == Export then win = nil end

    local stored = readExport("metric", nil)
    if stored ~= nil and Const.STAT_BY_KEY[stored] then return stored end

    local data = cfgOf(win or invoker).data or {}
    local sortColumn = data.sortColumn
    if sortColumn and Const.STAT_BY_KEY[sortColumn] then return sortColumn end
    return Const.STATS[1].key
end
```

Its docblock's third and fourth paragraphs — the ones arguing that `""` is a choice rather than an absent value, and that an earlier draft's seeding made the follow behaviour reachable exactly once — are replaced by:

```lua
--- Which stat the chat dump actually ranks by, right now.
---
--- The stored choice, when the catalog still answers for it. It always does on a
--- profile this build wrote: Export.Open SEEDS the invoking window's sort column
--- on the way in, so the selector shows a real stat before anyone has touched it.
---
--- The two fallbacks below are for the profiles that predate that. `""` was once
--- a deliberate choice meaning "match whichever column the window is sorted by",
--- and a build that offered a stat this one dropped leaves a key the catalog has
--- never heard of. Both read as unset, both land on the window's own column, and
--- neither needs a migration step — which is why there is not one.
---
--- Public and window-taking rather than a local reading the modal's `invoker`,
--- because a rule this easy to get wrong belongs where the harness can reach it;
--- the UI passes nothing and gets the window it was opened from.
---
--- @param win table|nil  a Window instance or config; the invoking window if nil
--- @return string  a key that Const.STAT_BY_KEY answers for
```

`openMetricMenu` loses its sentinel entry and its divider:

```lua
local function openMetricMenu(button)
    return NS.Compat.OpenContextMenu(button, function(_, root)
        root:CreateTitle(L["Metric"])
        for _, stat in ipairs(Const.STATS) do
            local key = stat.key
            root:CreateButton(L[stat.label] or stat.label, function()
                chooseExport("metric", key)
            end)
        end
    end)
end
```

(Task 8 replaces this function entirely. It is corrected here rather than left broken so Phase A merges on its own.)

- [ ] **Step 4: Seed on open**

In `Export.Open`, replace the "No metric seeding here" comment block and add the seed immediately above `refreshModal()`:

```lua
    -- SEEDED, and this reverses a decision this file used to argue for. The old
    -- shape stored "" — "match whichever column the window is sorted by" — and
    -- resolved it fresh at every use, which meant the Metric button showed a
    -- label naming a rule instead of naming a stat. The rule was right and
    -- unreadable; seeding keeps the behaviour and puts the answer in the control.
    --
    -- It is also what makes the settings panel's "Default metric" row removable:
    -- a preference every open overwrites is a preference in name only.
    --
    -- Only from a column the catalog answers for. A window that has never been
    -- sorted leaves whatever was chosen last time, which is the better of the
    -- two wrong answers.
    local seed = (cfgOf(win).data or {}).sortColumn
    if seed and Const.STAT_BY_KEY[seed] then writeExport("metric", seed) end

    refreshModal()
```

- [ ] **Step 5: Remove the settings row and its tables**

In `settings/Schema.lua`, delete the `EXPORTMETRIC_VALUES` / `EXPORTMETRIC_SORT` block (`:371-380`) including its four-line comment, and delete the `export.metric` row (`:1291-1297`). `STATCOL_VALUES` / `STATCOL_SORT` stay — the `sortColumn` row still reads them.

Add one line to the surviving comment above the export group, so the removal is recorded where a reader would look for the row:

```lua
    -- These are the REMEMBERED choices. The export modal has its own copies of
    -- the same dropdowns for a one-off send, and writes each choice back here,
    -- so the panel and the modal are two views of one preference rather than two
    -- preferences.
    --
    -- THE METRIC IS NOT AMONG THEM, and its absence is deliberate. It used to be,
    -- with a "Match the window" entry the sort column had no use for. Export.Open
    -- now seeds the metric from the window it was opened from, so a value set
    -- here would be overwritten before it was ever read.
```

- [ ] **Step 6: Default and locale**

`defaults/Profile.lua`: `metric = ""` becomes

```lua
            metric    = Const.STATS[1].key,
```

Confirm `Const` is already in scope in that file; if `defaults/Profile.lua` does not require it, use the literal key `Const.STATS[1].key` resolves to today (`lua -e 'print(...)'` is not available here — read it out of `core/Constants.lua` and spell it, with a comment naming the catalog as the source of truth).

`locales/enUS.lua`: delete the `L["Match the window"]` line (`:551`) and the two-line `L["Which column 'Print to Chat' ranks by…"]` entry (`:552-553`).

- [ ] **Step 7: Run tests**

```bash
cd MultiMeters && lua tests/run.lua
```

Expected: all pass. `tests/test_locale.lua` and `tests/test_schema*.lua` may fail if they enumerate expected keys or rows — that is the tripwire working. Remove exactly the two strings and the one row from those expectations, nothing else.

- [ ] **Step 8: Lint and commit**

```bash
cd MultiMeters && luacheck .
git add modules/Export.lua settings/Schema.lua defaults/Profile.lua locales/enUS.lua tests/
git commit -m "Remove 'Match the window' from the export metric selector

The behaviour was right and the label was not: a Metric button reading
'Match the window' names a rule rather than a stat, and there is no way to
tell from it what Print to Chat is about to do.

Export.Open now seeds the metric from the invoking window's sort column, so
opening the modal from a window sorted by Healing shows Healing. Same
behaviour, visible in the control.

That makes the settings panel's Default metric row a preference every open
overwrites, so it goes too, with its two locale strings. A profile carrying
the old '' degrades through the same path an unknown key already took --
window column, then the first catalog stat -- so there is no migration."
```

---

### Task 3: The whisper row gets the flat skin and stops clipping

Spec §6. `InputBoxTemplate` is replaced by a backdrop frame matching the three selectors, with the caption moved inside it as a prefix, and the modal grows a row while whisper is active instead of drawing over its own warning line.

**Files:**
- Modify: `modules/Export.lua:794-798` (`MODAL_HEIGHT`), `:1338-1372` (the whisper widgets and the warning line), `:1146-1175` (`refreshModal`), `:1380-1390` (the field stash)
- Test: `tests/test_export.lua`, `docs/smoke-tests.md` §25

**Interfaces:**
- Consumes: `skinColor(key, dr, dg, db, da) -> r, g, b, a` and `ROW_H`, both already file-locals in `modules/Export.lua`.
- Produces: `modal.whisperRow` (frame) replaces `modal.whisperLabel`; `modal.whisperBox` keeps its name and its `GetText`/`SetText` contract, so `refreshModal` and the two script handlers are the only readers that change.

- [ ] **Step 1: Write the failing test**

The modal is not reachable from the headless suite today (see `tests/test_export.lua`'s header — the modal, the copy window and the selectors are smoke-tested). Do not change that boundary for this task. Instead pin the one thing that *is* pure: the geometry constants must agree with each other.

Add to `tests/test_export.lua`:

```lua
test("The modal's whisper row is a row, not an overlap", function()
    -- red under: the InputBoxTemplate layout, where the box sat at -126 and the
    -- warning line at -154 with a 20px box between them and a fixed modal height
    -- that accounted for neither. The numbers are read off the module rather than
    -- restated, so this fails if a later edit moves one and not the others.
    local inst = T.load()
    local geom = inst.NS.Export.__geometry
    assertTrue(type(geom) == "table", "the modal's geometry is inspectable")

    assertTrue(geom.whisperTop + geom.rowHeight <= geom.warningTop,
        "the whisper row clears the warning line rather than drawing over it")
    assertEqual(geom.heightWithWhisper - geom.height, geom.rowHeight + geom.rowGap,
        "and the modal grows by exactly one row when it appears")
end)
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd MultiMeters && lua tests/run.lua 2>&1 | grep -A3 "whisper row is a row"
```

Expected: FAIL — `Export.__geometry` is nil.

- [ ] **Step 3: Publish the geometry**

In `modules/Export.lua`, beside `MODAL_WIDTH` / `MODAL_HEIGHT` (`:797`), replace the two bare constants with a named table and derive the rest from it:

```lua
-- The modal's vertical grid, as one table rather than as eight literals scattered
-- through EnsureFrame. It is published on the module (`Export.__geometry`) for the
-- one reason a private constant ever should be: the whisper row's arithmetic is
-- the thing that was wrong — a 20px box at -126 under a warning line at -154 in a
-- frame 236 tall that accounted for neither — and out of game the arithmetic is
-- all there is to check. The modal itself is smoke-tested.
local GEOM = {
    rowHeight         = ROW_H,
    rowGap            = 6,
    metricTop         = 36,
    channelTop        = 66,
    linesTop          = 96,
    whisperTop        = 126,
    warningTop        = 158,
    height            = 236,
}
GEOM.heightWithWhisper = GEOM.height + GEOM.rowHeight + GEOM.rowGap

local MODAL_WIDTH  = 372
local MODAL_HEIGHT = GEOM.height

Export.__geometry = GEOM
```

`ROW_H` must be declared above `GEOM`; if it is not, move its declaration up rather than duplicating the number.

Then reconcile `warningTop`: with the whisper row hidden the warning sits at `GEOM.warningTop`; with it shown, at `GEOM.warningTop + GEOM.rowHeight + GEOM.rowGap`. The test's first assertion is what forces `warningTop` to be at least `whisperTop + rowHeight`.

- [ ] **Step 4: Build the whisper row**

Replace the `whisperLabel` FontString and the `InputBoxTemplate` EditBox (`:1343-1362`) with:

```lua
    -- Shown only while the channel is WHISPER. Hidden rather than disabled: a
    -- greyed-out name box on a raid-channel export is a control asking to be
    -- filled in for no reason.
    --
    -- NOT InputBoxTemplate, and that is the fix rather than a preference. The
    -- template carries its own rounded, gold-edged art and its own text insets;
    -- beside three flat selectors it read as a control borrowed from another
    -- addon, and its insets are what clipped the name. This is the same backdrop
    -- the selectors above it wear, so the four rows are one column.
    local whisperRow = CreateFrame("Frame", nil, modal, "BackdropTemplate")
    whisperRow:SetHeight(GEOM.rowHeight)
    whisperRow:SetPoint("TOPLEFT", 16, -GEOM.whisperTop)
    whisperRow:SetPoint("TOPRIGHT", -16, -GEOM.whisperTop)
    if whisperRow.SetBackdrop then
        whisperRow:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
            insets   = { left = 1, right = 1, top = 1, bottom = 1 },
        })
        whisperRow:SetBackdropColor(skinColor("bg", 0.1, 0.1, 0.12, 0.9))
        whisperRow:SetBackdropBorderColor(skinColor("innerBorder", 0.24, 0.24, 0.27, 0.9))
    end

    -- The caption INSIDE the row, as a prefix, so this reads "Whisper to: …" in
    -- the same shape as "Metric: …" above it. It was a separate FontString above
    -- the box, in the 12px of空 the old layout did not actually have.
    local whisperCaption = whisperRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    whisperCaption:SetPoint("LEFT", 8, 0)
    whisperCaption:SetText(L["Whisper to:"] .. " ")
    whisperCaption:SetTextColor(skinColor("title", 1, 0.82, 0))

    local whisperBox = CreateFrame("EditBox", nil, whisperRow)
    whisperBox:SetPoint("LEFT", whisperCaption, "RIGHT", 2, 0)
    whisperBox:SetPoint("RIGHT", -8, 0)
    whisperBox:SetPoint("TOP", 0, 0)
    whisperBox:SetPoint("BOTTOM", 0, 0)
    whisperBox:SetFontObject("GameFontHighlightSmall")
    whisperBox:SetAutoFocus(false)
    whisperBox:SetScript("OnEnterPressed", function(self)
        chooseExport("whisperTo", self:GetText() or "")
        self:ClearFocus()
    end)
    -- Stored on focus loss as well as on Enter: nobody expects to have to press
    -- Enter in a name box before clicking the button right below it.
    whisperBox:SetScript("OnEditFocusLost", function(self)
        writeExport("whisperTo", self:GetText() or "")
    end)
    whisperBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
```

Note the literal `空` above is a typo guard — replace that comment line with `-- the 12px of room the old layout did not actually have.` when transcribing.

`SetFontObject` is required: an `EditBox` built without a template has no font and draws nothing at all, which would be a worse version of the bug being fixed.

- [ ] **Step 5: Re-anchor the warning line and the buttons, and update `refreshModal`**

The warning FontString's `SetPoint` calls move into `refreshModal` so they can follow the row. In `EnsureFrame`, anchor it once at the no-whisper position; in `refreshModal`, replace the show/hide pair with:

```lua
    local whispering = channel == "WHISPER"
    if whispering then
        modal.whisperBox:SetText(readExport("whisperTo", "") or "")
    end
    modal.whisperRow:SetShown(whispering)

    local warningTop = GEOM.warningTop + (whispering and (GEOM.rowHeight + GEOM.rowGap) or 0)
    modal.warning:ClearAllPoints()
    modal.warning:SetPoint("TOPLEFT", 16, -warningTop)
    modal.warning:SetPoint("TOPRIGHT", -16, -warningTop)
    modal:SetHeight(whispering and GEOM.heightWithWhisper or GEOM.height)
```

The two action buttons are anchored `BOTTOMLEFT` / `BOTTOMRIGHT` and need no change — growing the frame moves them with it, which is why they were anchored that way.

In the field stash, `modal.whisperLabel = whisperLabel` becomes `modal.whisperRow = whisperRow`.

- [ ] **Step 6: Locale**

`locales/enUS.lua`: `L["Whisper to"]` becomes `L["Whisper to:"]`. Change both the key and the value; leave the old key removed rather than aliased.

- [ ] **Step 7: Update the smoke test**

In `docs/smoke-tests.md` §25, replace the whisper step with:

```markdown
- Set **Channel: Whisper**. A fourth row appears below Lines, in the same flat
  box as the three above it, reading `Whisper to: ` in gold with an editable
  field beside it. **The modal grows by one row** — the red warning line and the
  two buttons move down with it, and nothing overlaps.
- Type a full name. The text is fully visible, not clipped at either end, and
  sits on the same baseline as the caption.
- Click **Print to Chat** without pressing Enter first. The dump is whispered:
  focus loss stores the name.
- Switch back to **Self only**. The row disappears and the modal shrinks back.
```

- [ ] **Step 8: Run tests, lint, commit**

```bash
cd MultiMeters && lua tests/run.lua && luacheck .
git add modules/Export.lua locales/enUS.lua tests/test_export.lua docs/smoke-tests.md
git commit -m "The whisper name box stops being Blizzard's and stops clipping

InputBoxTemplate brings its own rounded gold-edged art and its own text
insets. Beside three flat selectors it read as a control borrowed from
somewhere else, and the insets were half of why the name was cut off.

The other half was the layout: a 20px box at -126 under a warning line at
-154, in a frame 236 tall that accounted for neither. So the geometry is now
one table the suite can check the arithmetic of, and the modal grows by a row
while the channel is Whisper instead of drawing over itself."
```

---

# Phase B — LibKa0s v1.11.0

Branch: `git checkout -b feat/widgets-dropdown` in `LibKa0s/`.

---

### Task 4: `LibKa0s-Widgets-1.0` and its suite

Spec §2. BankLedger's dropdown moves into the library, with its existing test suite. One behavioural change is made on the way, and only one — see Step 4.

**Files:**
- Create: `LibKa0s/Widgets.lua`
- Create: `tests/test_widgets.lua`
- Modify: `LibKa0s/LibKa0s.xml`
- Source to transcribe from: `../BankLedger/modules/Browser.lua:281-505` and `../BankLedger/tests/test_browser.lua:469-662`

**Interfaces:**
- Consumes: `LibStub("LibKa0s-Core-1.0", true)` — needs `MINOR >= 1`.
- Produces:
  - `Widgets.Dropdown(parent, width, opts) -> dd`
    - `opts.chevron : string|nil` — resolved texture path for the ▼; falls to `Interface\Buttons\Arrow-Down-Up`
    - `opts.check : string|nil` — resolved texture path for the multi-select tick; falls to `Interface\Buttons\UI-CheckBox-Check`
    - `opts.glyphFont : string|nil` — font path for the optional leading row glyph; absent means no glyph column
  - Instance: `dd:SetOptions(opts)`, `dd:SetValue(value, label)`, `dd:SelectValue(value)`, `dd:SetMulti(on)`, `dd:SetSelected(set)`, `dd:ToggleSelected(value)`, `dd:UpdateMultiLabel()`
  - Instance fields read by hosts: `dd.text` (FontString), `dd.arrow` (Texture), `dd._value`, `dd._selected`, `dd.multi`
  - Callbacks the host assigns: `dd.onSelect(value)`, `dd.onMultiSelect(selectedSet)`

- [ ] **Step 1: Create the file with its guard and header**

`LibKa0s/Widgets.lua`:

```lua
-- LibKa0s-Widgets-1.0 — the collection's flat dropdown, and the one popup menu every instance of it
-- drops.
--
-- ── WHY THIS IS A LIBRARY AND NOT A COPY ──────────────────────────────────────────────────────
--
-- It was BankLedger's, local to modules/Browser.lua, and it was about to be MultiMeters' too. Two
-- copies of a widget is two skins to keep in step, and the collection stops looking like one
-- author's work the first time one copy is restyled and the other is not. That is the argument the
-- icons were consolidated under at v1.9.0; a widget that DRAWS those icons is the same argument one
-- layer up.
--
-- ── WHY IT DOES NOT DEPEND ON LibKa0s-Media-1.0 ───────────────────────────────────────────────
--
-- Because it cannot. `Media.Icon` takes the CONSUMING ADDON'S NAME to build a path, and this file
-- is vendored — every consumer has its own copy at its own path, and a copy cannot know which addon
-- folder it was copied into. So every piece of art arrives as a parameter: `opts.chevron` and
-- `opts.check` are resolved paths, and each falls to the Blizzard texture the host had before the
-- collection shipped art of its own. A host with no LibKa0s-Media still gets a working dropdown.
--
-- Same reasoning for `opts.glyphFont`: the optional leading glyph is a CHARACTER in a monospace
-- face, and which face is the host's decision.
--
-- ── WHAT IT DELIBERATELY IS NOT ───────────────────────────────────────────────────────────────
--
-- No search box, no keyboard navigation, no scrolling for a long list, no sub-menus, no per-row
-- disable. None of those is wanted by either shipped consumer, and every one of them is reachable
-- later without a major bump. A widget that grows features nobody asked for is a widget whose
-- degraded behaviour nobody has tested.
--
-- Depends on LibStub and LibKa0s-Core-1.0, and on no addon framework.

local core = LibStub and LibStub("LibKa0s-Core-1.0", true)
local NEEDS_CORE = 1
if not core or (core.MINOR or 0) < NEEDS_CORE then return end   -- no NewLibrary; module absent

local MAJOR, MINOR = "LibKa0s-Widgets-1.0", 1
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

lib.MAJOR, lib.MINOR = MAJOR, MINOR
lib.MODULES = lib.MODULES or {}
lib.MODULES.Widgets = MINOR
```

- [ ] **Step 2: Transcribe the machinery**

Copy `../BankLedger/modules/Browser.lua:281-505` into `LibKa0s/Widgets.lua` below the header — `MENU_ROW_H`, `menuWidth`, `makeMenuRow`, `rowSelected`, `paintMenuRow`, `rowOnClick`, the `EnsureMenu` singleton and `MakeDropdown` — **with their comments**. Add at the top of that block:

```lua
local WHITE = "Interface\\Buttons\\WHITE8X8"

-- The rungs below every piece of injected art. Named rather than inlined at the fallback site so
-- that "what does a host with no LibKa0s-Media draw?" is answerable by reading two lines.
local CHEVRON_FALLBACK = "Interface\\Buttons\\Arrow-Down-Up"
local CHECK_FALLBACK   = "Interface\\Buttons\\UI-CheckBox-Check"
```

Then apply exactly these four edits to the transcribed code, and no others:

1. `CHECK_MARKUP` was a file-local built once at load from `NS.Icon("confirm")`. It becomes **per-dropdown**, built in `MakeDropdown` and stashed as `dd.__check`:

```lua
  dd.__check = "|T" .. (opts.check or CHECK_FALLBACK) .. ":0|t "
```

`menuWidth` and `paintMenuRow` both read it from the dropdown they are given — `(dd.multi and dd.__check or "")` — rather than from the upvalue. They already take `dd`.

2. `MakeDropdown` gains the third parameter and uses it for the chevron:

```lua
local function MakeDropdown(parent, width, opts)
  opts = opts or {}
```

and the arrow's texture line becomes:

```lua
  arrow:SetTexture(opts.chevron or CHEVRON_FALLBACK)
```

3. **The one behavioural change.** `makeMenuRow` used to set the glyph's font once at row creation. The row pool is now process-wide and shared between addons that may not agree on a mono face, so the font moves into `paintMenuRow`, which already repaints every field on every pass for exactly this class of reason. In `makeMenuRow`, drop the `gl:SetFont(...)` line; in `paintMenuRow`, above the `SetText`:

```lua
  -- FONT SET ON EVERY PAINT, not once at creation, and that is the one thing this widget does
  -- differently from the version it was lifted out of. The row pool is shared across every dropdown
  -- in the process, which now spans addons — and two hosts need not name the same monospace face.
  -- A font set at creation would be whichever host opened a dropdown first.
  --
  -- A host that passes no face gets no glyph column: SetFont with a nil path raises, and a glyph
  -- drawn in the row's own proportional face is a box, which is the failure this widget's whole
  -- family of comments is about.
  if dd.__glyphFont and opt.glyph then
    b.glyph:SetFont(dd.__glyphFont, 11, "")
  end
```

and the glyph's `SetShown` becomes `b.glyph:SetShown(opt.glyph ~= nil and dd.__glyphFont ~= nil)`, with `dd.__glyphFont = opts.glyphFont` stashed in `MakeDropdown`.

4. Publish it: replace BankLedger's `function B:MakeDropdown(...)` forwarder with

```lua
--- Build a flat-skin dropdown button that drops the shared popup menu.
---
--- @param parent table         the frame to parent it to
--- @param width number         the collapsed button's width; the menu never drops narrower
--- @param opts table|nil       { chevron =, check =, glyphFont = }, each a resolved path or nil
--- @return table  the dropdown
function lib.Dropdown(parent, width, opts)
  return MakeDropdown(parent, width, opts)
end
```

- [ ] **Step 3: Register the file**

`LibKa0s/LibKa0s.xml` — add after the `Media.lua` line:

```xml
	<Script file="Widgets.lua"/>
```

(Tab-indented, matching the file. Chrome before plumbing: `Core`, `Media`, `Widgets`, then the rest.)

- [ ] **Step 4: Create the suite**

`tests/test_widgets.lua`. Its head installs a geometry-modelling frame factory, because LibKa0s's shared mock is the kit's base stub — `GetWidth` returns 0, `SetSize` is a no-op and `CreateTexture` answers the frame itself, none of which this widget's arithmetic survives. It is installed **here** rather than in `tests/wow_mock.lua` so the other fifteen suites in this repo keep the base's behaviour and this move stays behaviour-neutral for them.

```lua
-- tests/test_widgets.lua — LibKa0s-Widgets-1.0: the flat dropdown and its shared popup menu.
--
-- MOVED, not written. Every case below the divider came out of
-- BankLedger/tests/test_browser.lua, where this widget lived and where these rules were learned.
-- They are carried across verbatim so that "the library behaves as the addon did" is a claim the
-- suite makes rather than one a reviewer takes on trust; the cases ABOVE the divider are new, and
-- cover the three things the move introduced — injected art, an injected face, and their fallbacks.
--
-- ── WHY THIS FILE BUILDS ITS OWN FRAMES ───────────────────────────────────────────────────────
--
-- The kit's base stub returns 0 from GetWidth, no-ops SetSize and answers CreateTexture with the
-- frame itself. This widget sizes a button, then sizes a 12x12 arrow inside it, then measures the
-- button — so against the base stub every dropdown reports 12px wide and the "never narrower than
-- its own button" rule is unobservable. BankLedger's own mock models geometry for exactly this
-- reason.
--
-- The factory is installed HERE rather than in tests/wow_mock.lua deliberately: fifteen other
-- suites in this repo are written against the base's behaviour, and widening the shared mock to
-- suit one of them is a change to all sixteen.

local T = _G.LK_TEST
local test        = T.test
local assertEqual = T.assertEqual
local assertTrue  = T.assertTrue
local assertFalse = T.assertFalse
local mocks       = T.mocks

local W = LibStub("LibKa0s-Widgets-1.0")

-- A frame stub that models the geometry this widget does arithmetic on, and gives a texture its own
-- identity. Lifted from BankLedger/tests/wow_mock.lua, which grew it for this widget.
local function geomFrame()
  local f = { __shown = true, __w = 0, __h = 0, __scripts = {}, __points = {} }
  function f:SetSize(w, h) self.__w, self.__h = w, h; return self end
  function f:SetWidth(w) self.__w = w; return self end
  function f:SetHeight(h) self.__h = h; return self end
  function f:GetWidth() return self.__w end
  function f:GetHeight() return self.__h end
  function f:Show() self.__shown = true; return self end
  function f:Hide() self.__shown = false; return self end
  function f:SetShown(v) self.__shown = not not v; return self end
  function f:IsShown() return self.__shown end
  function f:SetScript(k, fn) self.__scripts[k] = fn; return self end
  function f:GetScript(k) return self.__scripts[k] end
  function f:__fire(k, ...) local fn = self.__scripts[k]; if fn then return fn(self, ...) end end
  function f:SetTexture(p) self.__texture = p; return self end
  function f:SetFont(p, s, fl) self.__font = { p, s, fl }; return self end
  function f:SetText(t) self.__text = t; return self end
  function f:GetText() return self.__text end
  -- A TEXTURE IS ITS OWN WIDGET. The catch-all would answer CreateTexture with the frame itself,
  -- and this widget sizes a button and then sizes the art inside it — so the button would measure
  -- 12px and every width rule below would be measuring the arrow.
  function f:CreateTexture() return geomFrame() end
  setmetatable(f, { __index = function(_, k)
    if type(k) == "string" and k:match("^%u") then return function() return f end end
    return nil
  end })
  return f
end

local realCreateFrame, realUIParent = mocks.CreateFrame, mocks.UIParent
mocks.CreateFrame = function() return geomFrame() end
mocks.UIParent    = geomFrame()

local CHEVRON_FALLBACK = "Interface\\Buttons\\Arrow-Down-Up"
local CHECK_FALLBACK   = "Interface\\Buttons\\UI-CheckBox-Check"
local HOST_CHEVRON     = "Interface\\AddOns\\Host\\media\\icons\\chevron-down"
local HOST_CHECK       = "Interface\\AddOns\\Host\\media\\icons\\confirm"
local HOST_FONT        = "Interface\\AddOns\\Host\\media\\fonts\\JetBrainsMono-Regular.ttf"

-- ── The injection seam (new at the move) ──────────────────────────────────────

test("Widgets.Dropdown draws the host's chevron when it is given one", function()
  local dd = W.Dropdown(mocks.UIParent, 110, { chevron = HOST_CHEVRON })
  assertEqual(dd.arrow.__texture, HOST_CHEVRON)
end)

test("Widgets.Dropdown falls to Blizzard's arrow with no host art", function()
  -- The rung a host with no LibKa0s-Media lands on. Red under: a library that
  -- reaches for Media.Icon itself, which cannot work from a vendored copy.
  local dd = W.Dropdown(mocks.UIParent, 110)
  assertEqual(dd.arrow.__texture, CHEVRON_FALLBACK)
end)

test("Widgets.Dropdown builds its tick markup from the host's check art", function()
  local dd = W.Dropdown(mocks.UIParent, 110, { check = HOST_CHECK })
  assertEqual(dd.__check, "|T" .. HOST_CHECK .. ":0|t ")
  local bare = W.Dropdown(mocks.UIParent, 110)
  assertEqual(bare.__check, "|T" .. CHECK_FALLBACK .. ":0|t ")
end)

test("Two dropdowns can carry different art without either winning", function()
  -- The reason the tick moved off a file-local: one popup menu is shared by every
  -- dropdown in the process, and that process now spans addons.
  local a = W.Dropdown(mocks.UIParent, 110, { check = HOST_CHECK })
  local b = W.Dropdown(mocks.UIParent, 110)
  assertFalse(a.__check == b.__check, "each dropdown keeps its own host's art")
end)
```

Then append the divider and the moved block:

```lua
-- ── Moved verbatim from BankLedger/tests/test_browser.lua:469-662 ─────────────
```

followed by that block with three mechanical substitutions: `B:MakeDropdown(parent, width)` becomes `W.Dropdown(parent, width, { check = HOST_CHECK, glyphFont = HOST_FONT })`; the `CHECK` local becomes `"|T" .. HOST_CHECK .. ":0|t "`; and the comment naming `Browser.lua` names `Widgets.lua`. Nothing else in it changes.

Finally, add two cases for the glyph-font rule, which is the move's one behavioural change:

```lua
test("A glyphed row is painted in the host's face on every pass", function()
  local dd = W.Dropdown(mocks.UIParent, 110, { glyphFont = HOST_FONT })
  dd:SetMulti(true)
  local rows = populate(dd, MENU_OPTS)
  assertEqual(rows[3].glyph.font[1], HOST_FONT, "the face comes from the dropdown, not the pool")
end)

test("A host that names no face gets no glyph column", function()
  -- Rather than SetFont(nil), which raises, or a glyph in the row's own
  -- proportional face, which is a replacement box.
  local dd = W.Dropdown(mocks.UIParent, 110, { check = HOST_CHECK })
  dd:SetMulti(true)
  local rows = populate(dd, MENU_OPTS)
  assertEqual(rows[3].glyph.shown, false)
end)
```

These read `rows[N].glyph.font`, so extend the moved `fakeFS()` helper with `function r:SetFont(p, s, f) self.font = { p, s, f } end`.

Restore the mock at the end of the file:

```lua
mocks.CreateFrame, mocks.UIParent = realCreateFrame, realUIParent
```

- [ ] **Step 5: Run the suite**

Add `"test_widgets"` to the `Kit.run` suite list in `tests/run.lua` (after `"test_media"`), then:

```bash
cd LibKa0s && lua tests/run.lua
```

Expected on the first run: failures. Work them to green — the moved cases are the specification, and a moved case that fails means the transcription lost something.

- [ ] **Step 6: Lint**

```bash
cd LibKa0s && luacheck .
```

Expected: `0 warnings / 0 errors`. Confirm `LibKa0s/Widgets.lua` is inside the checked set (`.luacheckrc`'s `exclude_files` lists `tests/` and `docs/`, not `LibKa0s/`) — a 0/0 over a file that was never read means nothing.

- [ ] **Step 7: Renormalize line endings and commit**

```bash
cd LibKa0s
for f in LibKa0s/Widgets.lua tests/test_widgets.lua; do
  printf 'checking %s: CR=%s LF=%s\n' "$f" "$(tr -dc '\r' < "$f" | wc -c)" "$(tr -dc '\n' < "$f" | wc -c)"
done
git add LibKa0s/Widgets.lua LibKa0s/LibKa0s.xml tests/test_widgets.lua tests/run.lua
git commit -m "LibKa0s-Widgets-1.0: the collection's flat dropdown

Lifted out of BankLedger/modules/Browser.lua, where it was written and where
it earned its keep, because MultiMeters was about to grow a second copy. Two
copies of a widget is two skins to keep in step, which is the argument the
icons were consolidated under at v1.9.0, one layer up.

It takes no dependency on LibKa0s-Media-1.0 and cannot: Media.Icon builds a
path from the consuming addon's name, and a vendored copy does not know which
folder it was copied into. Chevron, tick and glyph face all arrive as
parameters, each falling to the Blizzard rung the host had before.

One behavioural change on the way across: the row glyph's font is set on every
paint rather than once at row creation. The pool is process-wide and now spans
addons, so a face set at creation would be whichever host opened a dropdown
first.

BankLedger's suite for it moves too, verbatim, so 'the library behaves as the
addon did' is asserted rather than asserted-to."
```

---

### Task 5: Release wiring — versioning, API document, changelog

Spec §2.5. A new major is more than a file: three separate gates in this repo fail until it is fully declared.

**Files:**
- Modify: `tests/run.lua` (the `MAJORS` table)
- Create: `docs/api/LibKa0s-Widgets-1.0/version-1-docs.md`
- Modify: `docs/api/README.md`, `CHANGELOG.md`, `docs/releasing.md`, `docs/test-cases.md`

**Interfaces:**
- Consumes: `lib.MODULES.Widgets = 1` from Task 4.
- Produces: nothing code-facing. `tests/test_versioning.lua` reads all of it.

- [ ] **Step 1: Add the `MAJORS` row and watch the gate fail**

In `tests/run.lua`, after the `LibKa0s-Media-1.0` entry:

```lua
  {
    major = "LibKa0s-Widgets-1.0",
    files = { "Widgets" },
    primary = "Widgets",
  },
```

```bash
cd LibKa0s && lua tests/run.lua 2>&1 | grep -i "widgets"
```

Expected: `test_versioning` FAILs naming the missing `docs/api/LibKa0s-Widgets-1.0/version-1-docs.md`. That failure is the gate working — the document is a release requirement, not a courtesy.

- [ ] **Step 2: Write the API document**

Create `docs/api/LibKa0s-Widgets-1.0/version-1-docs.md`, following the shape of `docs/api/Media/` (read one before writing — the header block's field names are fixed). It must carry:

- `Status: **Current**`, `Supersedes: —` (this is version 1)
- A *What changed at this version* section reading "First release. Lifted from BankLedger's `modules/Browser.lua`; see that repo's history before v1.11.0 for the widget's prior life."
- `Since: 1` on every member
- The full contract: `Widgets.Dropdown(parent, width, opts)` with the three `opts` fields and each one's fallback; every instance method and its parameters; `dd.onSelect` / `dd.onMultiSelect`; the fields a host may read (`dd.text`, `dd.arrow`, `dd._value`, `dd._selected`, `dd.multi`)
- A **Behaviour a host must know** section stating: the popup menu is a process-wide singleton, so exactly one dropdown is open at a time across every addon using the library; rows are pooled across dropdowns and every field is repainted on every pass; the glyph column is absent unless `opts.glyphFont` is given
- A **Degraded** section: with `LibKa0s-Widgets-1.0` absent, `LibStub(..., true)` answers nil and the host must have a plan — both shipped consumers refuse the surface rather than draw dead controls

- [ ] **Step 3: Add the README row**

`docs/api/README.md` — one row for `LibKa0s-Widgets-1.0`, `version-1-docs.md`, Current, matching the table's existing columns.

- [ ] **Step 4: Write the changelog block**

`CHANGELOG.md`, above the `v1.10.2` heading:

```markdown
## v1.11.0 — 2026-08-24

Versions in this release: **Core minor 6**, **Media minor 3**, **Widgets minor 1**,
**DebugLog minor 10**, **Slash minor 7**, **Options minor 8**, **OptionsWidgets minor 7**,
**OptionsScroll minor 3**, **Perf minor 7**, **PerfPanel minor 4**, **kit revision 11**.

**New major: `LibKa0s-Widgets-1.0`.** The collection's flat dropdown, lifted out of
BankLedger's `modules/Browser.lua` because MultiMeters was about to grow a second copy of it.
One `Widgets.Dropdown(parent, width, opts)`, one process-wide popup menu behind every instance
of it, and a pooled row list. It takes no dependency on `LibKa0s-Media-1.0` — a vendored copy
cannot know which addon folder it sits in, so the chevron, the multi-select tick and the row
glyph's face all arrive as parameters, each with the Blizzard rung it falls to.

No other shipped file moves. Every other minor above is unchanged from v1.10.2.
```

- [ ] **Step 5: Regenerate the case list**

```bash
cd LibKa0s && lua tests/run.lua --list > /tmp/cases.txt
```

Then write it into `docs/test-cases.md` **keeping CRLF** — that file's own banner names the exact command; follow the banner rather than this line if the two disagree.

- [ ] **Step 6: Move the provenance template**

In `docs/releasing.md`: the header table's repo-semver example and the templated provenance line under "Re-vendoring consumers" both move to `v1.11.0`. Also add `Widgets.lua` to step 2's list of files and their exact minor constant names (`MINOR` in `Widgets.lua`), and add `BankLedger` and `MultiMeters` rows to the Consumers table for the new major.

- [ ] **Step 7: Run the gate**

```bash
cd LibKa0s && lua tests/run.lua && luacheck .
```

Expected: all pass, 0/0. `test_versioning` now agrees that the changelog block, `lib.MODULES` and the API document all name Widgets at minor 1.

- [ ] **Step 8: Commit**

```bash
cd LibKa0s
git add tests/run.lua docs/ CHANGELOG.md
git commit -m "Declare LibKa0s-Widgets-1.0 for release

A new major is three gates, not one file: the MAJORS row test_versioning
iterates, the versioned API document it derives from lib.MODULES and stays red
without, and the changelog block it cross-checks. Plus the provenance template
and the consumers table, which are maintained by hand and were the two things
the last release order was written down to stop anyone forgetting."
```

---

### Task 6: Dry-run adoption, then cut v1.11.0

Spec §2.5 steps 7-8. The library is tagged before either consumer adopts it, and `tests/test_vendor_sync.lua` compares against the **tag** — so a gap found after tagging costs a patch release. This task closes that gap by running both consumers' suites against the candidate payload before the tag exists.

**Files:** none committed in the dry run. Then `docs/releasing.md`, `CHANGELOG.md`, the release bundle, and the tag.

**Interfaces:** none.

- [ ] **Step 1: Dry-run BankLedger**

```bash
cd /mnt/d/Profile/Users/Tushar/Documents/GIT/BankLedger
git stash list > /tmp/bl-stash-before.txt
cp -r ../LibKa0s/LibKa0s/. libs/LibKa0s/
lua tests/run.lua
```

Expected: everything passes **except `test_vendor_sync`**, which fails because the working tree now carries bytes that exist at no tag. That one failure is expected and is not a finding. Read every other suite.

- [ ] **Step 2: Restore BankLedger**

```bash
cd /mnt/d/Profile/Users/Tushar/Documents/GIT/BankLedger
git checkout -- libs/LibKa0s/
git status --short   # must be empty
lua tests/run.lua    # must be fully green again, vendor_sync included
```

- [ ] **Step 3: Dry-run MultiMeters and restore it the same way**

```bash
cd /mnt/d/Profile/Users/Tushar/Documents/GIT/MultiMeters
cp -r ../LibKa0s/LibKa0s/. libs/LibKa0s/
lua tests/run.lua
git checkout -- libs/LibKa0s/
git status --short
```

Same expectation: only `test_vendor_sync` red, and green again after the restore.

If either dry run surfaces a real failure, **go back to Task 4** and fix `Widgets.lua`. Nothing below this line runs until both dry runs are clean.

- [ ] **Step 4: Green gate and the release bundle**

```bash
cd /mnt/d/Profile/Users/Tushar/Documents/GIT/LibKa0s
lua tests/run.lua && luacheck .
tests/_kit/run-automated-tests.sh --release 1.11.0
```

Read all four suites before going further. The release gate is all four at `pass` plus zero functions above CCN 15. `perf` is a standing `skip` in this repo (it ships no `tests/perf.lua`) — a skip is NOT EVALUATED rather than passed, and that is a known recorded hole, not a green light for the other three.

- [ ] **Step 5: Commit the bundle and tag**

```bash
cd /mnt/d/Profile/Users/Tushar/Documents/GIT/LibKa0s
git add docs/automated-tests/ RESULTS.md 2>/dev/null || git add docs/automated-tests/
git commit -m "Release v1.11.0 — LibKa0s-Widgets-1.0

The bundle and its RESULTS.md row belong in the release commit, so the tagged
tree contains the evidence for itself."
git tag v1.11.0
```

The tagged tree must already say v1.11.0 in `docs/releasing.md`'s provenance template and header table — Task 5 Step 6 did that, before this commit, deliberately.

- [ ] **Step 6: Merge to master**

```bash
cd /mnt/d/Profile/Users/Tushar/Documents/GIT/LibKa0s
git checkout master && git merge --no-ff feat/widgets-dropdown
```

Push and branch deletion are the user's call — do not push without being asked.

---

# Phase C — the consumers adopt it

---

### Task 7: BankLedger adopts the shared dropdown

Spec §3. The widget leaves `modules/Browser.lua`; `B:MakeDropdown` survives as the forwarder that injects the three host-resolved paths, so no call site changes.

**Files:**
- Modify: `modules/Browser.lua:281-507`, and its `core/` LibKa0s lookups
- Modify: `tests/test_browser.lua` (delete `:469-662`, add one forwarder case), `tests/test_marks.lua`, `tests/test_libka0s.lua`
- Modify: `core/MediaSetup.lua`
- Modify: `libs/LibKa0s/` (re-vendor), `CLAUDE.md` (provenance line) — **same commit**

**Interfaces:**
- Consumes: `LibStub("LibKa0s-Widgets-1.0", true).Dropdown(parent, width, opts)` — see Task 4's Produces block for the full signature.
- Produces: `B:MakeDropdown(parent, width) -> dd`, unchanged signature, unchanged return contract. `modules/Export.lua:353` and `modules/Browser.lua:1046-1168` are its only callers.

- [ ] **Step 1: Branch and re-vendor**

```bash
cd /mnt/d/Profile/Users/Tushar/Documents/GIT/BankLedger
git checkout -b feat/shared-dropdown
cp -r ../LibKa0s/LibKa0s/. libs/LibKa0s/
```

Update the provenance line in `CLAUDE.md:46` from `v1.10.2` to `v1.11.0`.

```bash
lua tests/run.lua 2>&1 | grep -i vendor
```

Expected: `test_vendor_sync` PASSES — the working tree now matches the `v1.11.0` tag the provenance line names.

- [ ] **Step 2: Write the failing forwarder test**

In `tests/test_browser.lua`, **delete** lines 469-662 (everything from the `-- ── The shared dropdown menu ──` divider to the end of the file — those cases now live in LibKa0s). In their place:

```lua
-- ── The dropdown forwarder ────────────────────────────────────────────────────
--
-- The widget itself is LibKa0s-Widgets-1.0's now, and its behaviour is asserted in that repo's
-- tests/test_widgets.lua — the cases that used to sit here moved there verbatim. What is still this
-- addon's is the INJECTION: three resolved paths that only a host can produce, because the library
-- builds a path from an addon name it does not have. Getting one of them wrong draws nothing and
-- raises nothing, which is the failure this addon's mark suite exists for.

test("Browser: MakeDropdown injects this addon's chevron, tick and mono face", function()
  local dd = B:MakeDropdown(mocks.UIParent, 110)
  assertEqual(dd.arrow.__texture, NS.Icon("chevron-down"),
    "the collapsed button wears the collection's chevron")
  assertEqual(dd.__check, "|T" .. NS.Icon("confirm") .. ":0|t ",
    "and a multi-select row's tick is the collection's check glyph")
  assertEqual(dd.__glyphFont, NS.Constants.FONT_MONO,
    "the direction glyph gets the face that actually has the character")
end)

test("Browser: MakeDropdown still hands back a working dropdown with no LibKa0s art", function()
  -- The rung below. Red under: a forwarder that concatenates a nil into a path.
  local realIcon = NS.Icon
  NS.Icon = function() return nil end
  local dd = B:MakeDropdown(mocks.UIParent, 110)
  assertEqual(dd.arrow.__texture, "Interface\\Buttons\\Arrow-Down-Up")
  NS.Icon = realIcon
end)
```

- [ ] **Step 3: Run to verify it fails**

```bash
cd BankLedger && lua tests/run.lua 2>&1 | grep -A3 "MakeDropdown injects"
```

Expected: FAIL on `dd.__check` — the local `MakeDropdown` does not set it.

- [ ] **Step 4: Delete the local widget and write the forwarder**

In `modules/Browser.lua`, delete `MENU_ROW_H`, `menuWidth`, `makeMenuRow`, `rowSelected`, `paintMenuRow`, `rowOnClick`, the `menu` / `EnsureMenu` singleton and `MakeDropdown` (`:281-505`), plus the `CHECK_MARKUP` local and its comment (`:32-34`). **Keep `WHITE`** — `:524` and `:1095` still use it.

Add near the file's other library lookups:

```lua
local W = LibStub and LibStub("LibKa0s-Widgets-1.0", true)
```

and replace the old forwarder with:

```lua
-- The flat dropdown is LibKa0s-Widgets-1.0's now. What stays here is the INJECTION, and it stays
-- here because it cannot live there: the library builds no path of its own — Media.Icon needs the
-- consuming addon's name, and a vendored copy does not know which folder it was copied into. So the
-- three pieces of art a Bank Ledger dropdown wears are resolved on this side and handed over.
--
-- FONT_MONO for the glyph because the row font has no ▲/▼, which is the same documented deviation
-- the Direction column in modules/LedgerTable.lua carries, for the same reason.
function B:MakeDropdown(parent, width)
  if not W then return nil end
  return W.Dropdown(parent, width, {
    chevron   = NS.Icon and NS.Icon("chevron-down"),
    check     = NS.Icon and NS.Icon("confirm"),
    glyphFont = C.FONT_MONO,
  })
end
```

- [ ] **Step 5: Handle the degraded load**

Spec §10: with the library absent, the filter bar refuses rather than drawing seven dead controls. `MakeDropdown` answering nil (Step 4) is half of it; `BuildFilterBar` must not then index nil. Guard the bar's construction at its top:

```lua
  -- No dropdown widget, no filter bar. Seven controls that open nothing is a browser that looks
  -- broken; the ledger table underneath still works, and the absence is legible.
  if not W then
    if NS.Print then NS.Print("Filters need LibKa0s. The ledger itself is unaffected.") end
    return
  end
```

Add the matching case to `tests/test_browser.lua` asserting the browser still opens and the table still populates with `W` nil.

- [ ] **Step 6: Re-point the mark suite**

`tests/test_marks.lua` currently asserts which of this addon's factories resolve `NS.Icon`. `chevron-down` and `confirm` are now resolved by `B:MakeDropdown` rather than inside the widget. Update those assertions to read the forwarder's output. **Do not delete them** — they are the tripwire that catches a path resolved to nothing, which is the one failure that draws nothing and raises nothing.

- [ ] **Step 7: `tests/test_libka0s.lua` and `core/MediaSetup.lua`**

Add `LibKa0s-Widgets-1.0` to the majors `test_libka0s.lua` expects the vendored payload to register. In `core/MediaSetup.lua`, reword the `chevron-down` consumer line and add a `confirm` line, both naming `modules/Browser.lua`'s forwarder rather than a factory that no longer exists.

- [ ] **Step 8: Full battery**

```bash
cd BankLedger && lua tests/run.lua && luacheck . && lizard modules core settings -T nloc=60 -C 15
```

Expected: all green, 0/0, zero functions above CCN 15.

- [ ] **Step 9: Commit**

```bash
cd BankLedger
git add libs/LibKa0s CLAUDE.md modules/Browser.lua core/MediaSetup.lua tests/
git commit -m "Adopt LibKa0s-Widgets-1.0; the dropdown stops being ours

Re-vendors LibKa0s at v1.11.0 and deletes the ~245 lines of dropdown and
shared-menu machinery this addon has carried since the filter bar was built.
It is the library's now, along with the suite that specified it.

B:MakeDropdown stays, as the forwarder it already half was: the library
resolves no art of its own -- Media.Icon needs an addon name a vendored copy
does not have -- so the chevron, the tick and the mono face are injected from
here. Every call site is untouched.

The mark suite is re-pointed rather than relaxed: those two paths are still the
ones that draw nothing and raise nothing when they are wrong."
```

---

### Task 8: MultiMeters adopts the shared dropdown

Spec §4. The export modal's three MenuUtil selectors become `Widgets.Dropdown`.

**Files:**
- Modify: `modules/Export.lua:1074-1082` (the header paragraph arguing for MenuUtil), `:1186-1228` (the three menu openers), `:1146-1175` (`refreshModal`), `:1324-1336` (the three buttons), `:1312-1320` (the strata comment), `Export.Open` (degraded refusal)
- Modify: `libs/LibKa0s/`, `CLAUDE.md`
- Modify: `tests/test_export.lua`, `tests/test_degraded.lua`, `core/MediaSetup.lua`, `docs/smoke-tests.md` §25

**Interfaces:**
- Consumes: `LibStub("LibKa0s-Widgets-1.0", true).Dropdown(parent, width, opts)`; `Const.STATS`, `Const.EXPORT_CHANNELS`, `LINE_CHOICES`.
- Produces: `modal.metricDD`, `modal.channelDD`, `modal.linesDD` replace `modal.metricButton` / `.channelButton` / `.linesButton`.

- [ ] **Step 1: Branch and re-vendor**

```bash
cd /mnt/d/Profile/Users/Tushar/Documents/GIT/MultiMeters
git checkout -b feat/shared-dropdown
cp -r ../LibKa0s/LibKa0s/. libs/LibKa0s/
```

Update the provenance line in `CLAUDE.md:51` to `v1.11.0`, then confirm:

```bash
lua tests/run.lua 2>&1 | grep -i vendor
```

- [ ] **Step 2: Write the failing degraded-load test**

In `tests/test_degraded.lua`:

```lua
test("The export modal refuses to open with no dropdown widget", function()
    -- Spec §10. Three labels that open nothing is a worse answer than a sentence:
    -- it looks like the addon is broken rather than like a library is missing.
    -- Red under: an Open that builds the frame and lets the selectors be nil.
    local inst = T.load({ withoutLibKa0sWidgets = true })
    local said = inst.captureChat(function()
        assertNil(inst.NS.Export.Open({}))
    end)
    assertTrue(#said > 0, "and it says why, in chat")
end)
```

Match `T.load`'s existing option-name convention in that file — read how it suppresses LibKa0s today and follow it exactly rather than inventing `withoutLibKa0sWidgets` if a different key already exists.

- [ ] **Step 3: Run to verify it fails**

```bash
cd MultiMeters && lua tests/run.lua 2>&1 | grep -A3 "refuses to open with no dropdown"
```

- [ ] **Step 4: Rewrite the header paragraph**

`modules/Export.lua:1074-1082` currently argues *for* MenuUtil: "No new widget: a dropdown of our own would be a second menu vocabulary to keep in step with Blizzard's". Replace it:

```lua
-- ---------------------------------------------------------------------------
-- The modal's three selectors
-- ---------------------------------------------------------------------------
--
-- LibKa0s-Widgets-1.0 dropdowns, and this REVERSES what this file used to argue.
-- The old reasoning was that a dropdown of our own would be a second menu
-- vocabulary to keep in step with Blizzard's, so these were plain buttons opening
-- a MenuUtil context menu — the mechanism the window header's segment selector
-- still uses.
--
-- What changed is whose dropdown it is. It is not ours: it is the collection's,
-- shared with Bank Ledger's filter bar and specified by a suite in the library's
-- own repo. Against that, MenuUtil is the second vocabulary — a menu with
-- Blizzard's gold title and no selected-row mark, dropped from a button wearing
-- this addon's flat skin.
--
-- The header's segment selector is deliberately NOT converted here. It is a
-- different control in a different frame and its own change.
```

- [ ] **Step 5: Build the three dropdowns**

Replace `openMetricMenu` / `openChannelMenu` / `openLinesMenu` with option-table builders:

```lua
--- The Metric selector's options: the catalog, in catalog order.
--- @return table
local function metricOptions()
    local out = {}
    for i, stat in ipairs(Const.STATS) do
        out[i] = { value = stat.key, label = L[stat.label] or stat.label }
    end
    return out
end

--- The Channel selector's options.
---
--- The catalog is core/Constants.lua's and only core/Constants.lua's. Restating
--- the channel list here would be two lists to keep in step, and the settings
--- panel reads the same one.
--- @return table
local function channelOptions()
    local out = {}
    for i, row in ipairs(Const.EXPORT_CHANNELS or {}) do
        out[i] = { value = row.key, label = L[row.label] or row.label }
    end
    return out
end

--- The Lines selector's options.
--- @return table
local function linesOptions()
    local out = {}
    for i, count in ipairs(LINE_CHOICES) do
        out[i] = { value = count, label = tostring(count) }
    end
    return out
end
```

In `EnsureFrame`, replace the three `makeButton` calls:

```lua
    local metricDD = W.Dropdown(modal, MODAL_WIDTH - 32, { chevron = NS.Icon("chevron-down") })
    metricDD:SetHeight(GEOM.rowHeight)
    metricDD:SetPoint("TOPLEFT", 16, -GEOM.metricTop)
    metricDD:SetPoint("TOPRIGHT", -16, -GEOM.metricTop)
    metricDD:SetOptions(metricOptions())
    metricDD.onSelect = function(v) chooseExport("metric", v) end

    local channelDD = W.Dropdown(modal, MODAL_WIDTH - 32, { chevron = NS.Icon("chevron-down") })
    channelDD:SetHeight(GEOM.rowHeight)
    channelDD:SetPoint("TOPLEFT", 16, -GEOM.channelTop)
    channelDD:SetPoint("TOPRIGHT", -16, -GEOM.channelTop)
    channelDD:SetOptions(channelOptions())
    channelDD.onSelect = function(v) chooseExport("channel", v) end

    local linesDD = W.Dropdown(modal, MODAL_WIDTH - 32, { chevron = NS.Icon("chevron-down") })
    linesDD:SetHeight(GEOM.rowHeight)
    linesDD:SetPoint("TOPLEFT", 16, -GEOM.linesTop)
    linesDD:SetPoint("TOPRIGHT", -16, -GEOM.linesTop)
    linesDD:SetOptions(linesOptions())
    linesDD.onSelect = function(v) chooseExport("lines", v) end
```

No `check` and no `glyphFont`: none of these three menus is multi-select and none has a glyph column. Passing art a control cannot draw is how a fallback ladder rots.

`refreshModal`'s three label writes become:

```lua
    modal.metricDD:SetValue(Export.ResolveMetric(),
        L["Metric: %s"]:format(metricLabel(Export.ResolveMetric())))
    modal.channelDD:SetValue(channel, L["Channel: %s"]:format(channelLabel(channel)))
    local lines = readExport("lines", 5)
    modal.linesDD:SetValue(lines, L["Lines: %s"]:format(tostring(lines)))
```

Stash `modal.metricDD`, `modal.channelDD`, `modal.linesDD` instead of the three `*Button` fields.

- [ ] **Step 6: The strata comment, and the refusal**

The comment at `EnsureFrame` explaining why the modal is `DIALOG` names MenuUtil. Reword it to name the shared menu — the two strata are the same (`FULLSCREEN_DIALOG` menu over a `FULLSCREEN` catcher over a `DIALOG` modal), so the reasoning holds and only the subject changes.

At the top of `modules/Export.lua`, beside the other library lookups:

```lua
local W = LibStub and LibStub("LibKa0s-Widgets-1.0", true)
```

and in `Export.Open`, above `EnsureFrame`:

```lua
    -- SPEC §10. No widget, no modal. Three labels that open nothing look like a
    -- broken addon; a sentence looks like a missing library, which is what it is.
    -- Same shape as the combat refusal above, for the same reason.
    if not W then
        if NS.Print then NS.Print(L["The export window needs LibKa0s."]) end
        return nil
    end
```

Add that string to `locales/enUS.lua`.

- [ ] **Step 7: `core/MediaSetup.lua` and the smoke test**

Add `chevron-down` to `core/MediaSetup.lua`'s consumer notes, naming `modules/Export.lua`'s three selectors. In `docs/smoke-tests.md` §25, rewrite the selector steps:

```markdown
- Click **Metric**. A flat menu drops **directly under the button, left-aligned
  with it** — dark panel, no gold title bar. The current metric's row is **gold**;
  the rest are light gray. It looks like Bank Ledger's Data Set menu, not like a
  Blizzard right-click menu.
- Click outside the menu. It closes and the click does **not** land on the modal
  behind it.
- Pick a different metric. The menu closes, the button reads `Metric: <that one>`.
- Repeat for **Channel** and **Lines**. Same skin, same behaviour, in all three.
- Open the modal from a window sorted by **Healing**. Metric reads
  **`Metric: Healing`** before you touch anything — there is no
  "Match the window" entry any more, and there should not be one.
```

- [ ] **Step 8: Full battery**

```bash
cd MultiMeters && lua tests/run.lua && luacheck . && lua tests/perf.lua && lizard modules core settings -T nloc=60 -C 15
```

- [ ] **Step 9: Commit**

```bash
cd MultiMeters
git add libs/LibKa0s CLAUDE.md modules/Export.lua core/MediaSetup.lua locales/enUS.lua tests/ docs/smoke-tests.md
git commit -m "The export selectors become LibKa0s-Widgets-1.0 dropdowns

This file used to argue the other way -- no dropdown of our own, because it
would be a second menu vocabulary to keep in step with Blizzard's -- and the
three selectors were buttons opening a MenuUtil context menu.

What changed is whose dropdown it is. It is not ours; it is the collection's,
shared with Bank Ledger's filter bar and specified by a suite in the library's
repo. Against that, MenuUtil was the second vocabulary: a gold-titled Blizzard
menu dropped from a button wearing this addon's flat skin.

The header's segment selector stays MenuUtil. It is a different control in a
different frame and it is its own change.

With the library absent the modal now refuses and says so, rather than opening
three labels that open nothing."
```

---

### Task 9: Documentation sweep and version bumps

Both consumers' docs still describe the world before this change, and both need a release bump. This is one task because a bump that ships stale docs is the drift the sync tooling exists to remove.

**Files:** `BankLedger/` and `MultiMeters/` — `README.md`, `CLAUDE.md`, `DEPENDENCIES.md`, `docs/ARCHITECTURE.md`, TOC `## Version`.

- [ ] **Step 1: Sync BankLedger's docs**

```bash
cd /mnt/d/Profile/Users/Tushar/Documents/GIT/BankLedger
```

Run `/wow-addon:sync-docs`. It covers count claims, dead exports, comment citations and the `DEPENDENCIES.md` / toolchain drift that the widget's departure creates. Pay particular attention to any `modules/Browser.lua` line-count or responsibility claim in `docs/ARCHITECTURE.md` — the file just lost ~245 lines.

- [ ] **Step 2: Bump BankLedger**

Run `/wow-addon:bump-version 1.1.0`. It gates on the full four-suite battery and refuses if anything is red or any function is above CCN 15. A new shared dependency and a removed subsystem is a minor bump, not a patch.

- [ ] **Step 3: Sync MultiMeters' docs**

```bash
cd /mnt/d/Profile/Users/Tushar/Documents/GIT/MultiMeters
```

Run `/wow-addon:sync-docs`. `docs/settings-panel.md` names the removed **Default metric** row; `docs/module-map.md` and `docs/ARCHITECTURE.md` describe `modules/Export.lua`'s selectors as MenuUtil buttons. Both are drift this task exists to close.

- [ ] **Step 4: Bump MultiMeters**

Run `/wow-addon:bump-version 0.2.0`.

- [ ] **Step 5: Report**

State plainly which suites ran, in which repos, and their actual results. If any smoke test in `docs/smoke-tests.md` §25 or the new sort-arrow check has **not** been run in-client — and none of them can be, from here — say so rather than implying the UI was seen working. Four of the six changes in this plan are visual, and no headless suite has looked at any of them.

---

### Task 10: The adoption prompt for the rest of the collection

The other Ka0s addons are **out of scope for every task above** and none of their files is touched by this plan. What they get is a drop-in prompt, written once, from a library that has now been adopted twice — so the prompt describes a path that has actually been walked rather than one that looks plausible.

`LibKa0s/docs/adoption-prompt.md` is the collection's existing precedent for this and is the shape to follow: self-contained, dropped into a fresh session **in the addon's own repo**, naming what to read rather than restating rules that may have moved on.

**Files:**
- Create: `LibKa0s/docs/widgets-adoption-prompt.md`
- Modify: `LibKa0s/docs/adoption-prompt.md` — one cross-reference line, so someone who opens the older prompt is pointed at the newer one rather than concluding Widgets does not exist

**Interfaces:** none. This task writes prose.

- [ ] **Step 1: Gather what the two adoptions actually cost**

Before writing a word, read back what Tasks 7 and 8 really did, because the prompt's credibility is that these numbers are measured rather than estimated:

```bash
cd /mnt/d/Profile/Users/Tushar/Documents/GIT/BankLedger
git diff --stat master..feat/shared-dropdown -- modules/ core/ tests/
cd /mnt/d/Profile/Users/Tushar/Documents/GIT/MultiMeters
git diff --stat master..feat/shared-dropdown -- modules/ core/ tests/
```

Record: lines removed from each, which suites went red on the way, and what each adoption found that the other did not. The existing `adoption-prompt.md` makes a point of saying that each adopter surfaces an assumption that only held for the ones before it — if Task 8 found something Task 4 had not anticipated, that finding is the most valuable paragraph in the new prompt.

- [ ] **Step 2: Survey the remaining consumers, read-only**

```bash
cd /mnt/d/Profile/Users/Tushar/Documents/GIT
for a in AbsorbTracker ConsumableMaster KickCD LootHistory PanelMaster PrettyChat WhatGroup; do
  echo "-- $a"
  grep -rnE 'UIDropDownMenu|MenuUtil|OpenContextMenu|MakeDropdown|CreateDropdown' "$a" \
    --include='*.lua' | grep -v '/libs/' | grep -v '/tests/' | head -5
done
```

**Read only.** Do not edit anything in those repos. The output tells the prompt which addons have a dropdown at all, which use Blizzard's `UIDropDownMenu` (a taint surface, and the strongest case for adopting), which use `MenuUtil` (a vocabulary mismatch, the case MultiMeters made), and which have none (nothing to do — say so in the prompt so nobody goes looking).

- [ ] **Step 3: Write `LibKa0s/docs/widgets-adoption-prompt.md`**

It must contain, in this order:

1. **A header explaining how to use it** — copy everything below the line into a fresh Claude Code session in the addon's own repo.
2. **Who has already adopted, and what it cost them**, with the real figures from Step 1. Name BankLedger as the source repo (it wrote the widget) and MultiMeters as the first true adopter.
3. **The per-addon status table** from Step 2: for each of the seven, whether it has a dropdown, what kind, and therefore whether this prompt applies to it at all. An addon with nothing to convert must be told that explicitly.
4. **The prerequisite:** the addon must already vendor LibKa0s at **v1.11.0 or later**. If its `CLAUDE.md` provenance line names anything earlier, re-vendoring is step zero — `cp -r ../LibKa0s/LibKa0s/. libs/LibKa0s/`, bump the provenance line **in the same commit**, and confirm `tests/test_vendor_sync.lua` goes green before touching any UI code.
5. **The API**, spelled out rather than linked: `Widgets.Dropdown(parent, width, opts)`, the three `opts` fields and their Blizzard fallbacks, every instance method, `onSelect` / `onMultiSelect`, and the fields a host may read. Point at `docs/api/LibKa0s-Widgets-1.0/version-1-docs.md` as the authority, but do not make the reader open it to get started.
6. **The injection rule, and why it is a rule:** the library resolves no art of its own and cannot — `Media.Icon` builds a path from the consuming addon's name, and a vendored copy does not know which folder it sits in. Every host writes its own three-line forwarder. Show BankLedger's, verbatim, as the model.
7. **The degraded-load decision, already made:** with `LibKa0s-Widgets-1.0` absent, refuse the surface with a sentence rather than draw dead controls. Both shipped consumers do this; a third that opened a dead menu would be the odd one out. Show both call sites.
8. **What NOT to convert.** MultiMeters keeps its window-header segment selector on MenuUtil, deliberately — it is a different control in a different frame and its own change. A prompt that says "convert every menu" will get every menu converted.
9. **The gate:** `lua tests/run.lua`, `luacheck .`, `tests/perf.lua` and `lizard` all green with zero functions above CCN 15 before any version bump, then `/wow-addon:sync-docs` and `/wow-addon:bump-version`.
10. **The caution the existing prompt earned and this one inherits:** inside a frozen `-1.0` major there is no deprecation. If you are the third host to touch this surface and it does not fit, treat it as a library gap on first contact — one host's misfit is a setup-file concern, two is a library gap, and this surface has only ever had two.

- [ ] **Step 4: Cross-reference the old prompt**

Add to `LibKa0s/docs/adoption-prompt.md`, under its "Remaining targets" paragraph:

```markdown
**`LibKa0s-Widgets-1.0` is a separate adoption with its own prompt** —
[`widgets-adoption-prompt.md`](widgets-adoption-prompt.md). It landed at v1.11.0, after every
consumer above had already adopted the five majors this prompt covers, so nothing here mentions it
and nothing here needs to: an addon adopts the library once and the widget separately, if it has a
dropdown at all.
```

- [ ] **Step 5: Line endings, commit**

```bash
cd /mnt/d/Profile/Users/Tushar/Documents/GIT/LibKa0s
f=docs/widgets-adoption-prompt.md
echo "CR=$(tr -dc '\r' < $f | wc -c) LF=$(tr -dc '\n' < $f | wc -c)"
git add docs/widgets-adoption-prompt.md docs/adoption-prompt.md
git commit -m "The Widgets adoption prompt, written from two real adoptions

Same shape as docs/adoption-prompt.md and for the same reason: a prompt
dropped into the addon's own repo, naming what to read rather than restating
rules that may have moved on.

It carries the measured cost of both adoptions rather than an estimate, and a
per-addon survey saying which of the remaining seven have a dropdown at all --
so the four that have nothing to convert are told so instead of going looking."
```

- [ ] **Step 6: Hand it to the user**

Print the prompt's body in chat as well as committing it, so it can be copied without opening the file.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §1 verification (complaints #5, #6 already true) | Task 9 Step 5 reports it; no code task, by design |
| §2 `LibKa0s-Widgets-1.0` | Tasks 4, 5, 6 |
| §3 BankLedger adopts | Task 7 |
| §4 MultiMeters modal | Task 8 |
| §5 sort arrow | Task 1 |
| §6 whisper box | Task 3 |
| §7 remove "Match the window" | Task 2 |
| §8 no change for #5/#6 | Task 9 Step 5 |
| §9 testing | folded into each task's own steps |
| §10 degraded load refusal | Task 7 Step 5, Task 8 Steps 2 and 6 |
| (user, mid-plan) cross-collection adoption prompt | Task 10 |

**Type consistency:** `Widgets.Dropdown(parent, width, opts)` is spelled identically in Task 4 (definition), Task 7 (BankLedger forwarder) and Task 8 (MultiMeters call sites). `opts.chevron` / `opts.check` / `opts.glyphFont` are the same three names throughout. `dd.__check` and `dd.__glyphFont` are set in Task 4 and read in Task 7's assertions. `Export.__geometry` / `GEOM` is introduced in Task 3 and consumed in Task 8's anchoring. `Export.ResolveMetric(win) -> string` keeps its signature across Tasks 2 and 8.

**Known soft spot, stated rather than hidden:** Task 2 Step 6 asks the implementer to read a literal out of `core/Constants.lua` rather than spelling it, because this plan cannot execute Lua to resolve `Const.STATS[1].key`. It is pointed out at its use site rather than left to be discovered.

**Scope:** every task above touches only LibKa0s, BankLedger and MultiMeters. Task 10 is the handoff for the rest of the collection and changes no code in any of them.
