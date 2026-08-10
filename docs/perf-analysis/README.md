# Perf analysis — the in-game capture store

**In-game captures only.** A human runs `/mm perf` in a live client and copies the result out; a
script cannot produce one, which is why this store exists at all. **Offline** scenario runs come from
`tests/perf.lua`, are driven by `tests/_kit/run-automated-tests.sh`, and live in the bundle for the
run that produced them, under [`../automated-tests/`](../automated-tests/). The two harnesses answer
different questions and their outputs are deliberately not merged: an offline run says nothing about
frame time, and an in-game capture says nothing about allocation.

See [../performance.md](../performance.md) for which paths are bracketed and why, what suspend does,
and how to read a report.

This directory is **standing and cumulative** rather than tied to one investigation, so captures
compare across addon versions. Bundles are committed as **evidence**: the raw capture outlives the
write-up that interprets it, and an interpretation without its record is an assertion.

## Bundle naming

```
docs/perf-analysis/<YYYYMMDD-HHMMSS>/
```

One directory per capture. The stamp is **local time**, rendered from the record's own `timestamp`
field (epoch seconds) — **when the capture happened**, not when it was written up, so a run analyzed
a week later still sorts against its neighbors. A bundle is never renamed to match a later
convention; a frozen directory stays as it was written.

A stamp that had to be reconstructed (a record with no usable `timestamp`) is said to be one, in that
bundle's `ANALYSIS.md`.

## The three artifacts

Each bundle carries exactly three files, and nothing else:

| File | What it is |
|---|---|
| `report.md` | The human-readable report the client printed, plus the run's lifecycle log lines (`run started`, `armed`, `RECORDING`, `ENDED`, `SUSPENDED`, `RESUMED`) |
| `dump.json` | The schema-2 JSON record, committed **verbatim** |
| `ANALYSIS.md` | The write-up, following the uniform prompt in the `PERF_ANALYSIS.md` playbook |

The lifecycle lines are kept on purpose: they are the capture's provenance. They are how a later
reader confirms that both arms were combat-gated, that arm B really was suspended, and that no
`/reload` landed between the arms — three conditions on a comparable pair, none of which the report
itself records.

**`dump.json` is the emitted line byte for byte** — one line, keys as sorted, figures as encoded. Not
pretty-printed, not re-keyed, not rounded, not stripped of a field that looks wrong. The library
emits sorted keys precisely so two records diff cleanly, and the encoder's quirks are part of the
record's identity. Read it with `jq`; never write it with one.

Bundles are **frozen once written** and are **never pruned**. If a reading turns out to be wrong, the
*next* capture's `ANALYSIS.md` says so — the frozen one is not corrected.

## Schema

One shape for both sources, so a single reader handles either. `schema` is the version stamp; this
addon emits **schema 2** — `LibKa0s-Perf-1.0`'s own, defined and versioned in the library, not here.
The full field-by-field contract is
[LibKa0s `docs/record-schema.md`](https://github.com/tusharsaxena/LibKa0s/blob/master/docs/record-schema.md),
and that document is the source of truth. The sketch below is for orientation only.

```jsonc
{
  "schema": 2,
  "addon": "MythicMeters",
  "source": "ingame",           // or "offline" for a tests/perf.lua record
  "version": "0.1.0",           // addon version, read from the TOC manifest
  "interface": 0,               // the CLIENT's build TOC — see the field notes
  "timestamp": 1785110400,      // epoch seconds — the bundle's directory stamp comes from here
  "label": "dummy-20man-7col",

  // Who / where / what, stamped once at the start of an in-game run. Absent offline.
  "context": { "character": "...", "realm": "...", "level": 80,
               "class": "...", "spec": "...",
               "zone": "...", "subZone": "...", "group": "raid" },

  // Per-bucket totals. In-game buckets are the probe's brackets; offline buckets are the
  // scenario names. In-game buckets MAY NEST — see `within`. NEVER sum a parent with its
  // children. Offline buckets never nest: each scenario is driven directly and times only
  // its own loop, so a missing `within` there means exactly that.
  "buckets": {
    "meterEvent":   { "calls": 0, "totalMs": 0.0, "maxMs": 0.0 },
    "refresh":      { "calls": 0, "totalMs": 0.0, "maxMs": 0.0 },
    "providerRead": { "calls": 0, "totalMs": 0.0, "maxMs": 0.0, "within": "refresh" },
    "renderRow":    { "calls": 0, "totalMs": 0.0, "maxMs": 0.0, "within": "render",
                      "apiPerIter": 0.0, "bytesPerIter": 0.0 }   // last two: offline only
  },

  // Frame sampling. Offline runs carry the fixed zeroed shape (no frames to sample).
  "fps": {
    "active":    { "seconds": 0, "frames": 0, "avgFps": 0, "msPerFrame": 0 },
    "suspended": { "seconds": 0, "frames": 0, "avgFps": 0, "msPerFrame": 0 },
    "deltaMsPerFrame": 0
  },

  "members": 20,       // offline only — group size the scenarios drove
  "columns": 7,        // offline only — enabled columns in the fixture
  "failures": []       // offline only — assertion failures, empty on a clean run
}
```

Every number in that block is zeroed on purpose: it is a **shape**, not a capture. Nothing in this
file is citable evidence until a real bundle sits beside it.

One encoding wart worth knowing: Lua has a single table type, so an **empty** list and an empty map
are indistinguishable to the encoder and both come out as `{}`. A run with no failures therefore
emits `"failures": {}`, not `[]`. Non-empty lists encode as proper arrays.

### Field notes

- **`fps.deltaMsPerFrame`** is the number the in-game harness exists to produce: the per-frame cost
  of the addon being active, with load order and shared-frame ownership held fixed by *suspend*
  rather than by disabling the addon. It has a resolution floor of roughly ±0.3 ms/frame on a 60–80 s
  A/B, so treat anything below about 0.5 ms/frame as **unresolved**, not as zero, and read the bucket
  figures instead. It reads `0` unless **both** arms were sampled — with one arm empty a subtraction
  would report the whole frame time as the addon's cost.
- **`buckets[*].totalMs`** is Lua execution time only.
- **`buckets[*].bytesPerIter`** (offline) is garbage produced per iteration, isolated by a full
  collect either side with the collector stopped. Allocation in a path running at combat event
  frequency matters more than its wall time.
- **`interface`** is the **client's** build TOC number, from `GetBuildInfo`'s fourth return — not the
  addon's `## Interface` line. A capture reading `interface: 0` is either offline (no client
  involved — `tests/perf.lua` hardcodes 0) or was taken against a build of the library older than
  Perf minor 5, and that is worth saying in its `ANALYSIS.md`.
- **Frame limiters are not recorded**, and a pinned client produces an unusable delta the record
  cannot flag. Judge that from the arms: two arms at the same frame time, or at a round one like
  8.33 ms, means the client was capped.
- **`context.group`** matters more here than in most Ka0s addons: this addon's cost scales with group
  size × open windows × columns per window. A solo capture and a twenty-player capture are not
  comparable measurements of the same addon, and the write-up must say which it is.

### Nesting is declared but never observed

Worth knowing **before** you read a report from this addon, because it changes what one of its lines
means.

Containment is supplied at the recording call — `Perf.Note(key, ms, parentKey)` — and the library
reports a parent as *observed* only when that third argument was passed. Every bracket in this addon
calls `Perf.Note(key, ms)` with **two** arguments and no `parentKey`:

| Bucket | Call sites |
|---|---|
| `meterEvent` | `core/MythicMeters.lua:200`, `:210`, `:218` |
| `refresh` | `modules/Window.lua:699`, `:709`, `:731`, `:746` |
| `providerRead` | `modules/Provider.lua:255` |
| `aggregate` | `modules/Aggregator.lua:509`, `modules/DrillDown.lua:417` |
| `render` | `modules/Window.lua:826` |
| `renderRow` | `modules/Row.lua:835` |
| `tooltip` | `modules/Tooltip.lua:464`, `:503`, `:547` |

So `observedWithin` is **never populated** in a Ka0s Mythic Meters record, and every report prints
the *"`<bucket>` declares itself within `<parent>` — not observed"* form for the four nested buckets.

The declared tree in `core/PerfSetup.lua` — `providerRead`, `aggregate` and `render` within
`refresh`, `renderRow` within `render` — is therefore an **unverified claim**. It is a reasoned one
(a refresh pass calls all three inline, and the row loop runs inside the render), but reasoning is
not observation. An `ANALYSIS.md` **must say so** rather than presenting the declared tree as
measured containment, and must not subtract a declared child from its declared parent as though the
overlap were confirmed. Closing that gap — threading `parentKey` through the call sites — is a
legitimate action for a capture's `ANALYSIS.md` to raise.

One bucket is genuinely **not** nested and should not be read as though it were: `meterEvent`
brackets the bus fan-out at event rate, while `refresh` brackets the coalesced pass on the window's
own throttle clock. They are two different clocks, and their totals do not overlap.

## How a capture is taken

In the client, on a **repeatable** fight — a training dummy with a fixed rotation, not a raid pull —
holding zone, group state, the open window layout and the loaded addon set fixed:

```
/mm perf start [label]     # label says what was measured: dummy-solo-3col, raid-20man-7col
/mm perf measure a         # arm A: addon active. Pull; the arm records only while combat is up
/mm perf measure b         # arm B: addon suspended. Fight the same fight
/mm perf finish
/mm perf report            # the summary a human reads
/mm perf dump              # one line of JSON — the record the summary is built from
```

Then press **Copy** on the debug-log window (`Ctrl+C`, `Esc`). One paste carries the report, the dump
and the run's lifecycle lines — all three artifacts' raw material. `/mm` is the addon's slash
command; `/mythicmeters` is the long form and works identically. `/mm perf show` opens the clickable
step panel, which runs the identical code path as the typed verbs.

The same record is also on disk after a `/reload`, in the `MythicMetersPerfDB` global — a ring of the
last 10 runs — inside the addon's SavedVariables file:

```
_retail_/WTF/Account/<ACCOUNT>/SavedVariables/MythicMeters.lua
```

Note the filename: WoW names the file after the **addon**, not after the saved-variable globals it
declares, so both `MythicMetersDB` and `MythicMetersPerfDB` live in `MythicMeters.lua`. `/reload` (or
a clean logout) is what flushes a finished run to disk.

The perf ring is deliberately a separate top-level global rather than part of the AceDB tree, so it
is never cloned by "copy profile", wiped by "reset profile", or swapped out by a profile switch.

## Capture index

One row per bundle, newest last.

**No capture has been taken yet.** This store is empty, and that is the correct state for a
freshly scaffolded addon: nobody has played it in a live client, and an in-game capture cannot be
produced by a script or reconstructed from the headless harness. The first bundle lands the first
time somebody runs `/mm perf` through a real A/B and commits the paste.

**A fabricated first capture would be worse than an absent one** — it would make the reasoning in
`core/PerfSetup.lua` look measured when it is not, and every later capture would be compared against
a baseline that never happened. Add a row here only when a real `<YYYYMMDD-HHMMSS>/` directory sits
beside this file.

| Bundle | Addon version | Label | What it measured |
|---|---|---|---|
| _(none yet)_ | — | — | — |
