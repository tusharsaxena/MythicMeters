# The shared dropdown, and four export-window UX corrections — design

Status: **awaiting review 2026-08-24**.

Six UX complaints were raised after the LibKa0s-Media adoption. Two of them turned out to be
already-satisfied and are recorded here as such rather than dropped, because "we checked and it
already works" is a finding a later reader needs as much as a change. The remaining four are one
design because the largest of them — the export modal's dropdowns — decides where a widget lives
for the whole collection, and the other three sit in the frames that widget lands in.

Three repos are touched: **LibKa0s** (a new major), **BankLedger** (adopts it, loses its local
copy), **MultiMeters** (adopts it, plus three unrelated corrections). This document lives in
MultiMeters because MultiMeters is where the complaints were raised; the LibKa0s work is the
larger half of it.

## 1. What was verified before anything was designed

Every claim below was read out of the working tree on 2026-08-24. Three of them changed the plan.

| Question | Answer |
|---|---|
| Does "Export to CSV" already export all recorded columns? | **Yes.** `Export.SessionConfig` (`modules/Export.lua:318-321`) builds its synthetic window config with `enabled = true` for **every** entry of `Const.STATS`, and `Export.Columns` (`:274-291`) emits `total`, `_ps` and `_pct` per stat plus six lead columns. The invoking window's visible columns are never consulted — the file header says so in as many words. |
| Does "Print to Chat" already print only the selected metric? | **Yes.** `onPrintToChat` resolves one `statKey` and `Export.ChatLines` (`:526-585`) reads `row.values[stat.key]` and nothing else. `Export.Build(invoker, statKey)` additionally ranks by it. |
| Are `sort-up` / `sort-down` in MultiMeters' vendored payload? | **Yes.** `libs/LibKa0s/media/icons/sort-{up,down}.tga`, alongside `chevron-down.tga`. No re-vendor is needed for §5. |
| Do the two addons' flat skins actually match? | **Yes, to the number.** BankLedger's dropdown and MultiMeters' `makeButton` both use `WHITE8x8` at `edgeSize = 1` over `0.1/0.1/0.12/0.9` fill with a `0.24/0.24/0.27/0.9` border. The visual gap is layout, not palette. |
| Can `LibKa0s-Options-1.0` host the dropdown? | **No.** That major is AceGUI schema-panel machinery — `RenderField`, `RenderRows`, relative widths. A raw-`CreateFrame` HUD widget shares none of it and would drag an AceGUI dependency into hosts that draw their own chrome. |

## 2. `LibKa0s-Widgets-1.0` — the new major

### 2.1 Why a new major rather than a copy

The alternative was porting BankLedger's `MakeDropdown` into a MultiMeters module. It was rejected on
the same grounds `core/MediaSetup.lua` already argues for the icons: two copies of a widget is two
skins to keep in step, and the collection stops looking like one author's work the first time one
copy is restyled and the other is not. The icons were consolidated for this reason eight months of
commits ago; a widget that draws them is the same problem one layer up.

### 2.2 The file

`LibKa0s/Widgets.lua`, guarded with the `Media.lua` idiom verbatim:

```lua
local core = LibStub and LibStub("LibKa0s-Core-1.0", true)
local NEEDS_CORE = 1
if not core or (core.MINOR or 0) < NEEDS_CORE then return end

local MAJOR, MINOR = "LibKa0s-Widgets-1.0", 1
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end
lib.MAJOR, lib.MINOR = MAJOR, MINOR
lib.MODULES = lib.MODULES or {}
lib.MODULES.Widgets = MINOR
```

One file, one primary, no paired secondary. It depends on `Core` and on nothing else — **not on
`LibKa0s-Media-1.0`**, for a reason that is load-bearing and belongs in the file header:
`Media.Icon` takes the consuming addon's name, and a vendored library copy cannot know which addon
folder it was copied into. The host resolves its own art and hands the widget a path.

### 2.3 The surface

```
Widgets.Dropdown(parent, width, opts) -> dd
```

`opts` is the injection seam, and both fields are optional:

| Field | Meaning | Absent |
|---|---|---|
| `opts.chevron` | resolved texture path for the ▼ affordance | falls to `Interface\Buttons\Arrow-Down-Up`, the rung BankLedger already keeps |
| `opts.glyphFont` | font path for the optional leading row glyph | rows silently draw no glyph column |

The instance methods are BankLedger's, unchanged in name and behaviour, because the point of the
move is that its call sites do not have to be rewritten:

```
dd:SetOptions{ { value=, label=, color=, glyph= } ... }
dd:SetValue(value, label)          dd:SelectValue(value)
dd:SetMulti(on)                    dd:SetSelected(set)
dd:ToggleSelected(value)           dd:UpdateMultiLabel()
dd.onSelect(value)                 dd.onMultiSelect(selectedSet)
```

The pooled menu frame, its `FULLSCREEN_DIALOG` strata, the `FULLSCREEN` click-catcher, the pooled
row buttons and `paintMenuRow`'s every-field-every-pass discipline all move across as they are.
That discipline is not incidental — the rows are pooled **across dropdowns**, and the comment
explaining why a field left alone leaks the previous menu's glyph onto this one travels with the
code.

### 2.4 What the library must not acquire on the way

The move is a lift, not a redesign. Specifically **not** added: a search box, keyboard navigation,
scrolling for long lists, sub-menus, or a `SetEnabled`. Every one of those is a thing neither
consumer asks for today, and `Widgets` has to be able to grow one later without a major bump.

### 2.5 Release mechanics (`docs/releasing.md`)

A new major is more than a file. In order:

1. `LibKa0s/Widgets.lua` written, with `tests/test_widgets.lua` against `wow_mock`.
2. `LibKa0s.xml` gains `<Script file="Widgets.lua"/>` — placed after `Media.lua`, before
   `DebugLog.lua`, so the payload's own load order reads chrome-then-plumbing.
3. **A new row in `tests/run.lua`'s `MAJORS`** (`major`, `files = { "Widgets" }`,
   `primary = "Widgets"`, no `paired`) and `test_widgets` added to the `Kit.run` suite list.
   `test_versioning.lua` iterates that table; a major missing from it is a major nothing checks.
4. `docs/api/LibKa0s-Widgets-1.0/version-1-docs.md` written, and a row added to
   `docs/api/README.md`. This is a **gate**, not a courtesy — `test_versioning.lua` derives the
   path from `lib.MODULES` and stays red until the document exists.
5. `CHANGELOG.md` block for the release, naming `Widgets` at minor 1.
6. `lua tests/run.lua --list` regenerated into `docs/test-cases.md`, CRLF preserved.
7. Provenance template in `docs/releasing.md` moved to the new semver; green gate;
   `tests/_kit/run-automated-tests.sh --release <X.Y.Z>`; commit the bundle and the `RESULTS.md`
   row with the release; tag.
8. Re-vendor **both** consumers — `libs/LibKa0s/` and the `CLAUDE.md` provenance line in the same
   commit, or `tests/test_vendor_sync.lua` refuses it, correctly.
9. Re-sweep the Consumers table with the `grep -rnoE 'LibStub\("LibKa0s-[A-Za-z]+-1\.0", true\)'`
   loop in `docs/releasing.md` §9, and add the two new lookup sites.

`Core.MINOR` does not move. No existing file's minor moves — nothing in them changes.

## 3. BankLedger adopts it

`modules/Browser.lua` loses `makeMenuRow`, `paintMenuRow`, `rowSelected`, `rowOnClick`,
`menuWidth`, `EnsureMenu` and `MakeDropdown` — roughly lines 260-505. `B:MakeDropdown` survives as
the forwarder it already is, now filling in the two injected fields:

```lua
function B:MakeDropdown(parent, width)
  return W.Dropdown(parent, width, {
    chevron   = NS.Icon and NS.Icon("chevron-down"),
    glyphFont = C.FONT_MONO,
  })
end
```

Every call site (`Browser.lua:1046-1168`, `Export.lua:353`) is therefore untouched. A `core/`
lookup for `LibKa0s-Widgets-1.0` joins the ones already there.

**The risk, named:** this pulls a working, shipped widget out from under the ledger browser's seven
filter dropdowns and the export modal's Data Set selector. `tests/test_browser.lua` and
`tests/test_marks.lua` are what catch a mistake, and `test_marks.lua` will need updating on purpose:
it currently asserts which of this addon's own factories resolve `NS.Icon`, and `chevron-down` is
about to be resolved by the forwarder rather than inside `MakeDropdown`. That assertion is the
tripwire working, not failing — it must be re-pointed, not deleted.

`core/MediaSetup.lua`'s consumer table gets its `chevron-down` line reworded to name the forwarder.

## 4. MultiMeters' export modal (complaint #2)

`modules/Export.lua`'s three selectors are `makeButton` frames that open
`NS.Compat.OpenContextMenu`. The file header argues for that — "no new widget: a dropdown of our
own would be a second menu vocabulary to keep in step with Blizzard's". **That argument is now
inverted and the header must say so:** the dropdown is no longer our own, it is the collection's,
and MenuUtil is the second vocabulary. The header paragraph is rewritten rather than deleted, so a
reader who remembers the old reasoning finds out why it stopped applying.

- `openMetricMenu` / `openChannelMenu` / `openLinesMenu` become `SetOptions` tables built from the
  same `Const.STATS`, `Const.EXPORT_CHANNELS` and `LINE_CHOICES` catalogs they read today. No list
  is restated.
- The three buttons become `Widgets.Dropdown(modal, width, { chevron = NS.Icon("chevron-down") })`
  at height 24, still anchored `TOPLEFT`/`TOPRIGHT` at the same three offsets. No `glyphFont` —
  none of these three menus has a glyph column.
- Labels stay `"Metric: %s"` / `"Channel: %s"` / `"Lines: %s"`, now left-justified, with the
  chevron on the right. The gold **selected-row** highlight replaces MenuUtil's gold **title**.
- `refreshModal` writes through `dd:SetValue` instead of `button.text:SetText`.
- The two action buttons keep `makeButton` untouched — they are buttons, not selectors, and the
  spreadsheet/chat marks beside their labels stay exactly as they are.

**Strata:** the modal is `DIALOG` specifically so a `FULLSCREEN` catcher above it closes an open
menu instead of the click landing on the modal. The shared menu uses the same two strata, so the
ordering survives the swap and the comment at `EnsureFrame` stays true — it is re-worded to name
the shared menu instead of MenuUtil.

`NS.Compat.OpenContextMenu` stays: the window header's segment selector is still a MenuUtil menu
and is out of scope here.

## 5. The sort arrow (complaint #1)

`modules/Window.lua:118-121` declares an art ladder — atlas rungs, then ASCII. It gains a **new top
rung**: `NS.Icon("sort-up")` / `NS.Icon("sort-down")`, tinted with the header colour via
`SetVertexColor(hr, hg, hb)` so it wears the header's gold exactly as BankLedger's inline
`tint255` markup does.

`ApplyColumnHeaders` (`:920-951`) already owns a texture (`button.arrowTex`) and a FontString
(`button.arrow`) and picks between them. The new rung is one branch above the existing atlas
branch, reusing `arrowTex` with `SetTexture` instead of `SetAtlas`. The `SetTexCoord` flip is
**not** needed on this rung — `sort-up` and `sort-down` are two distinct assets — so the flip stays
inside the atlas branch where it belongs.

`auctionhouse-ui-sortarrow` and the `^`/`v` characters stay underneath, unchanged. The hundred-line
comment above the constants gets a paragraph for the new rung; it is the ladder's own record of why
each rung exists, and a rung added without one is the failure mode that comment was written about.

## 6. The whisper box (complaint #3)

Today: `InputBoxTemplate` at `TOPLEFT 22, -126`, a separate `"Whisper to"` caption at `-114`, and a
`MODAL_HEIGHT` of 236 that does not account for either. Blizzard's template carries its own rounded
gold-ish art and its own insets, which is both why it reads as foreign and why the text clips.

Replaced by a row that matches the three selectors above it:

- A `BackdropTemplate` frame at the dropdowns' width and skin (`0.1/0.1/0.12` fill, `0.24` border,
  height 24), anchored `TOPLEFT 16, -126` / `TOPRIGHT -16, -126`.
- Inside it, a gold `"Whisper to: "` prefix FontString pinned `LEFT, 8, 0`, and a plain `EditBox`
  child filling from the prefix's right edge to `RIGHT, -8`. The modal's four rows then read as one
  column of `Label: value`.
- The separate caption FontString is deleted; `modal.whisperLabel` goes with it, and
  `refreshModal`'s show/hide pair collapses to one `whisperRow:SetShown(channel == "WHISPER")`.
- `MODAL_HEIGHT` grows by the row's height **only while whisper is selected**: `refreshModal`
  re-`SetHeight`s the modal and the warning line and the two action buttons are anchored below the
  row rather than at fixed offsets. This is the actual fix for the clipping — the current layout
  puts the box where the warning line wants to be.

`SetAutoFocus(false)`, the `OnEnterPressed` / `OnEditFocusLost` / `OnEscapePressed` trio and their
write-through to `export.whisperTo` are unchanged. Losing focus still stores, because nobody expects
to press Enter in a name box before clicking the button under it.

## 7. "Match the window" is removed (complaint #4)

`FOLLOW_WINDOW` is the empty string stored in `export.metric`, meaning "rank by whichever column the
invoking window is sorted by", resolved fresh at every use by `Export.ResolveMetric`
(`modules/Export.lua:1119-1131`). It is the shipped default. The behaviour is defensible; the label
is not, and the decision is to remove the concept rather than rename it.

**What replaces it:** `Export.Open` **seeds** `export.metric` from the invoking window's
`data.sortColumn` when that column is a stat the catalog answers for. The Metric dropdown then
always names one concrete stat, and opening the modal from a window sorted by Healing shows
"Metric: Healing" — the useful half of the old behaviour, now visible in the control instead of
hidden behind a label nobody could read.

The comment at `Export.Open` currently says "**No metric seeding here**" and explains why. That
comment is **replaced, not deleted** — it is a record of a decision being reversed, and the new text
says what changed and that the reversal is what makes the panel row below removable.

**The consequence, which is the reason this was asked about:** seeding on every open makes the
settings panel's `export.metric` row a control that writes a value the next modal open discards.
So it goes too:

| File | Change |
|---|---|
| `modules/Export.lua` | `FOLLOW_WINDOW` const, the `metricLabel` follow branch (`:1088`), the menu's first entry + divider (`:1191-1194`), and `ResolveMetric`'s follow arm all removed. `ResolveMetric` keeps its window fallback for the no-valid-stored-key case. |
| `settings/Schema.lua` | the `export.metric` row (`:1292-1297`) and the `EXPORTMETRIC_VALUES` / `EXPORTMETRIC_SORT` tables (`:371-380`) removed. `STATCOL_*`, which they derive from, stays — the sort-column row still uses it. |
| `defaults/Profile.lua` | `metric = ""` → `metric = Const.STATS[1].key`. |
| `locales/enUS.lua` | `L["Match the window"]` and the `"Which column 'Print to Chat' ranks by…"` description removed. |
| `tests/test_export.lua` | the case at `:359-385` currently asserts the default **is** `""` and names a non-empty default as the thing it goes red under. It inverts: the default must now be a key `Const.STAT_BY_KEY` answers for, and a stored `""` must resolve to a real stat rather than being treated as a choice. |
| `tests/test_schema*.lua` | any case naming `export.metric` drops with the row. |

A profile written by the current build carries `metric = ""`. `ResolveMetric` already treats a
stored key the catalog does not answer for as "fall back to the window, then to `STATS[1]`", so
`""` degrades correctly with no migration step. That is stated here because it is the kind of thing
a reader will otherwise go looking for.

## 8. Complaints #5 and #6 — no change

Recorded in §1 with file and line. Both behaviours are already what was asked for, and both are
pinned by existing cases in `tests/test_export.lua`. If either misbehaves in-client, it is a bug
against those cases and not this design.

## 9. Testing

| Repo | Suite | What it must cover |
|---|---|---|
| LibKa0s | `tests/test_widgets.lua` (new) | `Dropdown` builds; `SetOptions` + `SelectValue` sets the label; `onSelect` fires with the value and closes the menu; multi-select toggles, keeps the menu open and fires `onMultiSelect`; `UpdateMultiLabel`'s three arms (empty → All, one → its label, many → "N selected"); a row pooled from a glyphed menu into an unglyphed one draws no glyph; absent `opts.chevron` falls to the Blizzard path; absent `opts.glyphFont` draws no glyph column. |
| LibKa0s | `tests/test_versioning.lua` | passes with the new `MAJORS` row and the new API document — no new cases written by hand; it derives them. |
| BankLedger | `tests/test_browser.lua` | unchanged assertions must still pass through the forwarder. |
| BankLedger | `tests/test_marks.lua` | re-pointed: `chevron-down` is resolved by `B:MakeDropdown`, not inside the widget. |
| BankLedger | `tests/test_vendor_sync.lua` | green only after the provenance line and the payload move together. |
| MultiMeters | `tests/test_export.lua` | the metric-default inversion (§7); the three selectors expose `SetOptions`/`onSelect`; the whisper row shows only for `WHISPER` and the modal's height tracks it. |
| MultiMeters | `tests/test_window.lua` | the sort arrow's new top rung: `NS.Icon` present → texture path; `NS.Icon` nil → atlas; neither → `^`/`v`. |
| MultiMeters | `tests/test_schema*.lua`, `test_locale.lua` | the removed row and its two strings are gone from every list that enumerates them. |
| MultiMeters | `tests/test_degraded.lua` | with `LibKa0s-Widgets-1.0` absent the modal refuses to open and says so in chat (§10). |

Both consumers additionally re-run `luacheck`, the headless harness, `tests/perf.lua` and `lizard`
before their version bumps, per `automated-tests-§3`.

## 10. Degraded load: no `LibKa0s-Widgets-1.0`

Today a MultiMeters export modal on a client with no MenuUtil opens with three buttons that do
nothing, and the file header signs off on that. After the swap, a missing library means no widget
at all, and three dead labels would be a worse version of the same non-answer.

**Decision: refuse to open**, with a sentence in chat, through the same path `Export.Available`
already uses for the combat refusal — "the sentence in chat is the useful half of that
interaction" is the argument `Export.Open` makes today for refusing rather than opening a modal
with two dead buttons, and it applies unchanged. `tests/test_degraded.lua` asserts the refusal and
the sentence.

BankLedger's filter bar gets the same answer for the same reason: seven dropdowns that cannot open
is a browser that looks broken, and the ledger table itself still works without them.
