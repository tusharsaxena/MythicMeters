# Export — design (issue #5)

Status: approved 2026-08-22. Implements
[#5 "Export a segment to CSV"](https://github.com/tusharsaxena/MythicMeters/issues/5), widened in
the same conversation to a general export surface: a glyph in a meter window's title bar opens a
small modal offering **Export to CSV** and **Print to Chat**.

The shape is `LootHistory/modules/Export.lua`, deliberately and near-literally: a pure
serialization block that unit tests can reach, and beneath it a lazily built modal plus its **own**
copy window — not the debug console's, so the two can evolve apart.

## 1. Decisions taken

| Question | Answer |
|---|---|
| What does the CSV contain? | The **whole session, every stat in the catalog** — not the invoking window's column set, sort or row cap. |
| Which session? | The **segment the invoking window is pointed at** (`data.sessionType` / `data.sessionID`). Exporting from a window showing Overall exports Overall. |
| Where does the CSV land? | A copy-paste window: monospace `EditBox`, text pre-selected, Ctrl+C then Esc. There is no file I/O in WoW. |
| Chat shape | **One metric, ranked, capped** — a header line then N ranked lines. |
| Channels | Auto → Say / Party / Raid / Instance / Guild → Whisper… → **Self only (default)**. |
| Combat | **Refuse**, and say so. Not a stopgap — see §7. |
| Copy window ownership | A local copy in this addon, as LootHistory does. Recorded in §10 as a harvest candidate. |

## 2. Files

| File | Change |
|---|---|
| `modules/Export.lua` | **new** — serializers (pure) + modal + copy window (lazy). |
| `modules/Window.lua` | A fourth header button, left of the lock. `EXPORT_ATLAS` / `EXPORT_ASCII` beside `GEAR_*` / `LOCK_*`; `onExportClick` → `NS.Export:Open(self)`. |
| `core/Constants.lua` | `Constants.EXPORT_CHANNELS` — the one channel catalog both Export and Schema read. |
| `defaults/Profile.lua` | Addon-wide `export = { metric = nil, channel = "SELF", whisperTo = "", lines = 5 }`. |
| `settings/Schema.lua` | Four rows on page `general`, group `L["Export"]`. |
| `settings/Slash.lua` | `/mm export [window]`. |
| `locales/enUS.lua` | New strings. |
| `MythicMeters.toc` | `modules\Export.lua`, after `modules\DrillDown.lua`. |
| `tests/test_export.lua` + `tests/run.lua` | **new** suite, declared in the manifest. |

## 3. Public API

```lua
NS.Export                                     -- plain table on NS, like NS.Slash

-- pure, unit-tested
Export.CsvField(v)                 -> string  -- RFC-4180 quoting
Export.SessionConfig(win)          -> table   -- synthetic window config (§4)
Export.Columns()                   -> array   -- { { header, statKey, kind } }, kind = total|rate|pct
Export.CSV(result)                 -> string  -- an Aggregator.Build result -> CSV text
Export.ChatLines(result, statKey, limit) -> array<string>
Export.ResolveChannel(channel)     -> chatType|nil, target|nil   -- "AUTO" resolves; "SELF" -> nil
Export.Available()                 -> boolean, reason|nil        -- false while restricted

-- side-effecting
Export.Send(lines, channel, target)           -- SendChatMessage, or NS.Print for SELF
Export:Open(win)                              -- build (once) and show the modal
```

`win` is a Window **instance**; every entry point accepts either the instance or a bare config table
(`(win and win.config) or win`), because the slash verb has only the config.

## 4. The data path — no new one

`Export.SessionConfig` builds a synthetic window config and hands it to `Aggregator.Build`. Nothing
here talks to `Provider` and nothing here reads `C_DamageMeter`; rule R1 is untouched by
construction.

```lua
{
  id      = "export",
  columns = { { stat = <every Const.STATS key>, enabled = true }, … },   -- catalog order
  rows    = { maxRows = Const.MAX_ROWS },                                -- 40, the hard ceiling
  data    = {
    sessionType   = <invoking window's>,   sessionID = <invoking window's>,
    sortColumn    = <invoking window's, or the first catalog key>,
    sortMode      = "value",  sortAscending = false,
    mergePets     = <invoking window's>,
  },
}
```

`Const.MAX_ROWS` is 40 and `Aggregator.ApplyRowLimit` clamps to it, so a group larger than 40 is
truncated. That is stated in the docs rather than worked around.

## 5. CSV format

Pure CSV, no preamble, CRLF line endings, so it pastes straight into a sheet. Session identity rides
as leading columns so several exports concatenate meaningfully:

```
session,duration,name,class,spec,role,damage_done,damage_done_ps,damage_done_pct,healing_done,healing_done_ps,healing_done_pct,…
Ulgrax,134,Kaosz,WARLOCK,265,DAMAGER,4821993,84210,31.20,0,0,0.00,…
Ulgrax,134,"Crenna Earth-Daughter",,,NONE,1200,21,0.01,…
```

- Header names are `snake_case`, derived from `Const.STATS[i].key` (`DamageDone` → `damage_done`),
  never from a localized label — a CSV is a data interchange, not a display.
- `_ps` appears only for `isRate` stats; `_pct` for every stat, from `cell.percent` at two decimals,
  blank when `percent` is nil.
- Values are **raw** — `4821993`, never `Format.Number`'s `4.8M`. A spreadsheet wants the integer.
- `Export.CsvField`: quote when the field matches `[,"\r\n]`, doubling embedded quotes. This is what
  makes `Crenna Earth-Daughter` and cross-realm `Name-Realm` safe.
- A nil field is the empty string, never `"nil"`.

## 6. Chat format

```
Mythic Meters — Damage — Ulgrax (2:14)
1. Kaosz 4.8M (84.2k, 31.2%)
2. Brewz 4.1M (71.9k, 26.6%)
```

- Through `NS.Format.Number` / `Format.Rate` / `Format.Duration` here — chat wants `4.8M`.
- The rate parenthetical is omitted for a non-`isRate` stat; the percent is omitted when nil.
- Metric defaults to the invoking window's sort column; the modal's dropdown overrides it.
- `limit` is clamped 1..`Const.MAX_ROWS`, default 5.
- `SendChatMessage` takes 255 bytes a line; these are far under, and no line is ever built by
  concatenating an unbounded field.
- `AUTO` resolves in this order: `INSTANCE_CHAT` when in an instance group → `RAID` → `PARTY` →
  `SAY`. `SELF` sends nothing and prints through `NS.Print`, which is why it is the default: a
  misclick can never reach a group.

## 7. Combat is a refusal, not a workaround

`Secrets.IsRestricted()` is asked when the modal opens **and again inside each button's click
handler** — the restriction can activate while the modal sits open.

- Restricted: both buttons disabled, and a red line in the modal reads
  *"Export is not available while the game restricts combat data."*
- `/mm export` while restricted prints the same sentence and opens nothing.
- Independently, every value passes `Secrets.CanAccess` on its way into a field and yields `""` when
  it fails. A race can therefore produce a blank cell; it can never raise.

Why structural rather than cosmetic: `tostring` is **not** on `docs/data-flow.md`'s list of
operations permitted on a secret. A CSV cell is `tostring`, so the whole serializer is legal only
out of combat.

## 8. UI

Two frames, both built lazily, both registered in `UISpecialFrames`, both wearing `NS.ApplySkin`,
both closing with `NS.MakeCloseButton`.

**`MythicMetersExportWindow`** — strata `DIALOG`, dragging title bar reading "Export", centered on
the meter window it was opened from (falling back to `UIParent`). Controls:

- `Metric:` — every catalog stat, defaulting to the invoking window's sort column
- `Channel:` — `Const.EXPORT_CHANNELS`
- `Lines:` — 3 / 5 / 10 / 20 / 40
- a whisper-name `EditBox`, shown only while Channel is `WHISPER`
- `[ Export to CSV ]` and `[ Print to Chat ]`

Dropdowns are `NS.Compat.OpenContextMenu` on a plain button — the mechanism the segment selector
already uses (`WindowProto:OpenSegmentMenu`). No new widget, and it degrades the same way.

**`MythicMetersExportCopyWindow`** — strata `FULLSCREEN`, so it sits above the modal. Title
"Export — Ctrl+C, then Esc". `ScrollFrame` + multi-line `EditBox` in `Const.FONT_MONO`; on open:
`SetText`, `SetCursorPosition(0)`, `HighlightText()`, `SetFocus()`. Esc clears focus and hides.

Every choice the modal makes writes through to the profile (`export.*`) so it is remembered.

## 9. Settings

Four rows, page `general`, group `L["Export"]`, all addon-wide (path with no `window.` prefix):

| Path | Type | Default |
|---|---|---|
| `export.metric` | string, `values` derived from `Const.STATS` | `"DamageDone"` |
| `export.channel` | string, `values` derived from `Const.EXPORT_CHANNELS` | `"SELF"` |
| `export.whisperTo` | string | `""` |
| `export.lines` | number, 1..`Const.MAX_ROWS` | `5` |

## 10. Documented follow-ups

- **Copy-window duplication.** This is the third copy-paste window in the collection
  (`LibKa0s/DebugLog.lua`, `LootHistory/modules/Export.lua`, this). It is a deliberate local copy —
  LootHistory's own comment gives the reason — and a harvest candidate for
  `lib.MakeCopyWindow(name, title)` in LibKa0s Core, not a change to make inside a low-severity
  issue.
- **40-row ceiling** on exports, inherited from `Const.MAX_ROWS`.

## 11. Testing

`tests/test_export.lua`, pure half only:

- `CsvField` — plain, comma, embedded quote, CRLF, and the two names from the issue
  (`Name-Realm`, `Crenna Earth-Daughter`)
- `Columns` — one `_ps` per `isRate` stat and no others; `_pct` for every stat; header names are
  snake_case and derived, not restated
- `CSV` — header line, one row per entry, leading `session`/`duration`, nil → empty, CRLF terminator
- `ChatLines` — header line, ranking, cap clamped 1..40, rate parenthetical dropped for a non-rate
  stat, percent dropped when nil
- `ResolveChannel` — AUTO's four-step ladder, SELF returning nil
- `SessionConfig` — names every catalog stat, inherits the window's segment, caps at `MAX_ROWS`
- restriction — `Available()` false and `CSV` refusing while `Secrets.IsRestricted()`

The UI half is smoke-tested (`docs/smoke-tests.md`), as LootHistory's is.
