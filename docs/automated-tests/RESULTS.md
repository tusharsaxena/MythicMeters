# Automated test results

<!-- The newest run is prepended by tests/_kit/run-automated-tests.sh. -->
<!-- This file is OVERWRITTEN IN PLACE — the git history of this one path is the trend line. -->

One row per run. The frozen evidence for each is in the dated folder beside this file;
the analysis of a given run is its `ANALYSIS.md`.

**`lint` and `tests` gate the run and gate the commit** (`testing-§4`).
**`perf` and `complexity` never fail a run and never block a commit** — they are recorded,
read and compared, not thresholded (`performance-§9`, `performance-§10`).

**The tag is gated on all four suites at `pass`, plus zero functions above CCN 15**
(`automated-tests-§3`, *The release gate*), evaluated by `/wow-addon:bump-version` from the
`manifest.json` the release run writes — not by this script, whose exit code is unchanged.

A `skip` is a suite that did not run at all. It is never a pass, and at the release gate it is
**NOT EVALUATED** rather than passed: install the tool and re-run. A `—` is a suite that was
not selected, which is a different fact again.

| Run | Version | Lint w/e | Files | Tests | Perf | NLOC | Funcs | Avg NLOC | Avg CCN | Max CCN | CCN warn | Verdict |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| [`20260825-021705`](20260825-021705/) | 0.1.0 | 0/0 | 46 | 1246/1246 | fail | 26457 | 2867 | 7.7 | 2.5 | 31 | 19 | **amber** |
| [`20260809-195454`](20260809-195454/) | 0.1.0 | 0/0 | 40 | 676/676 | pass | 15173 | 1677 | 7.3 | 2.4 | 15 | 0 | **green** |
| [`20260809-194203`](20260809-194203/) | 0.1.0 | 0/0 | 40 | 676/676 | pass | 15005 | 1627 | 7.4 | 2.4 | 41 | 13 | **green** |

## Complexity watch list

Current as of [`20260809-195454`](20260809-195454/), the v0.1.0 release run.

### Functions over threshold

**None.** `lizard` reports 0 warnings and a maximum CCN of 15, which is the ceiling rather than a
breach — the release gate is "zero functions **above** 15" (`automated-tests-§3`).

That is a deliberate result, not a coincidence: the run before it,
[`20260809-194203`](20260809-194203/), reported 13 functions over the line with a maximum of 41, and
those thirteen were decomposed before the release run. The diff between the two bundles is the
evidence for what that cost and what it bought.

### At the ceiling — four functions to look at first

At exactly CCN 15, so not entries on the list above, but named here so that a run which does report
a warning has four obvious places to look, and so that whoever next edits one knows there is **zero**
headroom left.

| Function | File | Note |
|---|---|---|
| `normalizeColumns` | `settings/Schema.lua:1097-1151` | The `window.columns` carve-out's validator. Dense with per-field guards, not tangled control flow. |
| `WindowProto:BuildLayout` | `modules/Window.lua:147-192` | Rule R3 in one function — every coordinate derived from config. Its branching is per-config-key defaulting. |
| `Cell:ApplyBorder` | `modules/Row.lua:409-454` | Four leaf textures with per-edge config. |
| `Cell:Update` | `modules/Row.lua:530-581` | The per-cell value and appearance path; the hottest of the four. |

Worth carrying forward: `lizard` counts every `and` / `or` short-circuit as a decision, so in Lua a
run of defaulting lines scores high with no visible branching. All four above are **defaulting and
guarding** rather than knotted flow, and they want a different fix from one that is — a config
reader, not a state machine.

### Files by `layout-§1` band

| Band | File | LOC | Disposition |
|---|---|---|---|
| 1000–1500 (on notice) | `tests/wow_mock.lua` | 1478 | **Watch.** The largest file in the repo and the one closest to the 1500 cap. It is a thin extender over `tests/_kit/mock_base.lua` by construction, but this addon's mock surface is genuinely large: a controllable `C_DamageMeter`, a secret-value simulator, `C_RestrictedActions`, and the frame surface `Window`/`Row` need. `luacheck` never sees it (`tests/` is excluded), so it carries no lint signal. Re-check when the next stat column lands. |
| 1000–1500 (on notice) | `settings/Schema.lua` | 1371 | **Watch.** One row per setting across thirteen pages; the size is the schema's, and it is the single source the panel, the CLI and defaults reset all read. A split would have to be by page, which would put the "one table" property at risk. No action. |
| 1000–1500 (on notice) | `modules/Window.lua` | 1232 | **Watch.** Grew during the complexity work — the ~842-913 and ~464-553 functions were decomposed into named regions, which trades file length for function clarity, exactly as intended. If it approaches the cap the natural peel is the header build into a `Window_Header.lua`. |

Nothing is over the 1500 cap and nothing newly crossed a boundary — this is the first record, so
every band entry is an opening position rather than a trend.

No entry in either table is carried as a bare **Accepted**, so `automated-tests-§4`'s shelf-life rule
(nothing accepted across three consecutive release runs) has nothing outstanding against this record.
The three-release clock starts here: [`20260809-195454`](20260809-195454/) is this repo's first
release run.

## A note on the first two runs

Both bundles are dated 2026-08-09 and both are v0.1.0. That is not a mistake and neither is
disposable:

- [`20260809-194203`](20260809-194203/) is the **pre-remediation** run — 13 functions over CCN 15,
  max 41. It also reported `perf` as **0 scenarios** while `perf.txt` plainly held twelve, because
  `tests/perf.lua` printed a six-column table and the vendored runner counts scenario rows
  structurally as five fields. The runner is vendored and was not edited; `tests/perf.lua` was
  changed to emit the collection's five-column table instead, and `columnsPerIter` now rides in
  `perf.json` and in the assertions rather than in the printed table.
- [`20260809-195454`](20260809-195454/) is the **release** run, after both fixes.

Keeping the first is the point of a trend line. A record whose first entry is already green tells a
later reader nothing about what the gate caught.
