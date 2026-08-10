# Analysis — `20260809-195454`

**Ka0s Mythic Meters 0.1.0 · release run · verdict green**

The first release run, and the run the `v0.1.0` tag is gated on. All four suites pass and no function
exceeds CCN 15, which is what `/wow-addon:bump-version` reads out of `manifest.json`.

| Suite | Result |
|---|---|
| `lint` | pass — 0 warnings / 0 errors across 40 files |
| `tests` | pass — 676 passed, 0 failed, 676 total |
| `perf` | pass — 12 scenarios recorded |
| `complexity` | pass — 0 warnings, 15173 NLOC / 1677 funcs, avg NLOC 7.3, avg CCN 2.4, **max CCN 15** |

## What this run is measuring for the first time

Nothing here has a predecessor to be compared against except
[`20260809-194203`](../20260809-194203/), taken 12 minutes earlier on the same source. That makes
this pair unusually informative for a first record, because the diff isolates one piece of work.

### Complexity — the whole delta

| | `194203` | `195454` |
|---|---|---|
| Functions over CCN 15 | 13 | **0** |
| Max CCN | 41 | **15** |
| NLOC | 15005 | 15173 (+168) |
| Functions | 1627 | 1677 (+50) |
| Avg NLOC per function | 7.4 | **7.3** |
| Avg CCN | 2.4 | 2.4 |

Fifty new functions for 168 lines is the shape a genuine decomposition leaves: roughly three lines of
new signature and scope per extracted function, and no new logic. Average NLOC per function fell,
which is the number that would have moved the wrong way had the work been the forbidden
`part2`/`doTheRest` split — that pattern produces *fewer, longer* helpers and leaves the average flat
or rising while the headline CCN drops.

The single largest contributor was `Aggregator.Build`, **CCN 41 → 8**, decomposed into the five
stages its own header comment already named (read the columns, join by GUID, filter and fold pets,
order, assemble). The gates travelled with the code they guard — the pet fold's `CanCompare2` check
stayed inside `foldPet`, and the percent division's gate stayed inside `percentOf` — which is the
property that mattered most here, because an extracted helper that does the arithmetic while its
guard stays behind in the caller is a dungeon-only crash that no suite in this repo would catch.

### Perf — the baseline, and one regression guard that has already earned its place

Twelve scenarios. Two are worth naming now because later runs will be read against them:

- **`refresh20x7`** — 20 group members × 7 columns, asserting **exactly 7.00 provider column reads
  per refresh**. That assertion is not decoration: an earlier version of the render path called
  `Provider.GetColumn` a second time per column, per refresh, purely to obtain a group total the
  aggregator already held. The bug was fixed by publishing `columnTotals` / `sortTotal` on the
  aggregate; this scenario is what stops it coming back. A future run showing 14 api/iter here is
  that regression, not a slow machine.
- **`probeOverheadOff` vs `probeOverheadOn`** — 309297.0 vs 309302.1 bytes per iteration, a 5-byte
  difference on a 309 KB pass. That is the `performance-§9` evidence that instrumentation is free
  when capture is off, stated as a measurement rather than as a comment.

Timings in `perf.txt` are for orientation only and must never be compared across machines. The
allocation and call-count columns are the ones that carry meaning between runs.

### Tests — what the 676 actually cover

The suite is weighted toward the two things that cannot be checked in a client without a raid group
and a mythic key:

- **Secret-value safety.** `tests/wow_mock.lua` ships a simulator whose values raise on `__lt`,
  `__add`, `__len`, `__concat` and `__index`, so an illegal operation anywhere in the addon fails a
  test loudly instead of passing silently and erroring in a dungeon three weeks later. `__eq` and
  truth-testing cannot be trapped in Lua 5.1 and the mock says so rather than implying coverage it
  does not have — that residue is what `docs/smoke-tests.md` exists for.
- **The degraded path**, proven by actually loading the addon with `libs/LibKa0s/` absent rather than
  by hand-stubbing the member under test. The load-bearing assertion is that the **schema row count
  is unchanged** versus a full load: a page file raising at load would otherwise take a third of the
  schema with it, silently, and every other assertion in that suite would still pass.

## What this run does not tell you

**No in-game capture exists.** `docs/perf-analysis/` is empty and correctly says so. Every number
above is from a headless Lua 5.1 harness against a mock — the addon has never been loaded by a WoW
client. The offline scenarios prove call counts, allocation behavior and that instrumentation is free
when off; they prove nothing about frame time in a twenty-player pull.

**One load-bearing assumption is still unverified**, and no automated suite can verify it: that
`C_DamageMeter`'s `combatSources` arrives pre-sorted by the requested stat. Only the `provider` sort
mode depends on it. `docs/smoke-tests.md` carries an explicit procedure for checking it against
Blizzard's own meter window, and if it proves false the correction is confined to
`modules/Provider.lua`.

## Watch list

Maintained in [`../RESULTS.md`](../RESULTS.md). Summary: no function over threshold; four functions
sitting at exactly CCN 15 with zero headroom (`normalizeColumns`, `WindowProto:BuildLayout`,
`Cell:ApplyBorder`, `Cell:Update`); three files in the 1000–1500 LOC band
(`tests/wow_mock.lua` 1478, `settings/Schema.lua` 1371, `modules/Window.lua` 1232), none over the cap,
all opening positions rather than trends.
