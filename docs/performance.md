# Measuring the addon's performance

Two harnesses answer two different questions, and neither substitutes for the other.

| | Question | How | Where the output lands |
|---|---|---|---|
| **Offline** ([`tests/perf.lua`](../tests/perf.lua)) | Does a hot path do more work — more meter reads, more refreshes, more allocation — than it used to? | `lua tests/perf.lua`, under the headless mock | the run bundle, `docs/automated-tests/<run>/perf.txt` + `perf.json` |
| **In-game** (`/mm perf`) | What does this addon actually cost a live client, and is that cost even ours? | a guided A/B in a real client | a frozen bundle under [`perf-analysis/`](perf-analysis/) |

WoW's built-in Addon Profiler cannot answer the second one. It bills a **shared** library's dispatch
frame to whichever addon created it, so enabling and disabling addons moves the blame around and the
first-alphabetical Ace addon in an install absorbs cost belonging to its siblings. The only
trustworthy answer is an A/B on the **same fight** with load order and shared-frame ownership held
fixed — which is what the `perf` verb's suspend/resume contract provides.

## Where the cost actually is

Worth saying plainly, because a bucket list is easy to misread as a claim that everything in it is
expensive.

This addon has **exactly one hot path, and it is event-driven rather than per-frame.** There is no
`OnUpdate` doing work, no combat-log parsing, and no per-unit polling. What there is:

1. **`DAMAGE_METER_*` on a busy pull.** `DAMAGE_METER_CURRENT_SESSION_UPDATED` fires far faster than
   anything needs to redraw. Each of the three handlers in `core/MythicMeters.lua` does one thing —
   fan the event out on the message bus — and that fan-out walks every subscribed window's callback
   synchronously. That is the `meterEvent` bucket, and it scales with **event rate × number of open
   windows**.
2. **Coalescing.** Every window's message handlers do nothing but set `dirty`. A single `OnUpdate`
   tick spends `data.throttle` (0.25 s by default, clamped to `[0.05, 2.0]` by
   `Constants.THROTTLE_MIN/MAX`) and only then draws. So a burst of two hundred events costs **one**
   pass, not two hundred. That is the single most important performance property in the addon, and
   `tests/perf.lua` asserts it as a number rather than trusting the comment.
3. **The pass itself.** One coalesced refresh is: one `C_DamageMeter` session read **per enabled
   column**, a GUID join across the group, an ordering pass, and then one cell drawn per row per
   column. A twenty-player raid with seven columns is 140 cells.

So the whole cost model is: **event rate → coalesced to a throttle → times open windows → times
columns per window → times rows**. If a capture shows anything, it shows there. Everything else in
this addon runs on context transitions — zone-in, roster change, settings write — and is not worth
measuring.

## The harness

`LibKa0s-Perf-1.0`, vendored under `libs/LibKa0s/`. The probe, the guided A/B run, the record schema,
the saved-variable ring and the clickable step panel are **the library's** — not hand-rolled here.

[`core/PerfSetup.lua`](../core/PerfSetup.lua) supplies only the part that this addon alone can know:
which paths are worth measuring, and what "inert" means here. It sits **seventh in the core block**,
after `core/CoreSetup.lua` and before `core/DebugLogSetup.lua`. That position is load-bearing in two
directions:

- It must load **before every module**, because each module file takes `local Perf = NS.Perf` as a
  load-time upvalue. Move it below `modules/` and every bracket in the addon captures nil.
- It must load **after `core/Namespace.lua`**, because the descriptor takes `version` as a plain
  string resolved once at `:New`. Higher in the block it would capture nil and stamp every capture
  record `v?` — unattributable the moment it leaves the session.

The version itself is read from the **TOC manifest** through `NS.Compat`, with `NS.version` as the
fallback, so `/mm version` and a capture record cannot disagree, and neither can drift from the
packaged build.

When the library is absent, `core/PerfSetup.lua` publishes a stub covering **every** member the addon
reaches — `on`, `Note`, `suspended`, `Open`, `Close`, `OnCommand` — because `/mm perf` is registered
unconditionally in `settings/Slash.lua` and something has to answer it. A stub that omits a member is
not a fallback; it is a crash moved to a rarer code path.

## The buckets

Declared once, on the descriptor in `core/PerfSetup.lua`, with their **nesting declared** rather than
left as prose — a reader comparing two captures months apart cannot be expected to know which totals
overlap, and **a parent must never be summed with its children**.

| Bucket | Inside | What it brackets | Call sites |
|---|---|---|---|
| `meterEvent` | — | one `DAMAGE_METER_*` handler, i.e. the bus fan-out to every window | `core/MythicMeters.lua:200`, `:210`, `:218` |
| `refresh` | — | one coalesced window refresh pass | `modules/Window.lua:699`, `:709`, `:731`, `:746` (every exit) |
| `providerRead` | `refresh` | one `C_DamageMeter` column read | `modules/Provider.lua:255` |
| `aggregate` | `refresh` | the GUID join and the ordering pass | `modules/Aggregator.lua:509`, `modules/DrillDown.lua:417` |
| `render` | `refresh` | the window's draw | `modules/Window.lua:826` |
| `renderRow` | `render` | one row's cells | `modules/Row.lua:835` |
| `tooltip` | — | one tooltip build | `modules/Tooltip.lua:464`, `:503`, `:547` |

The three buckets under `refresh` exist to answer "which third of the pass is it" — reading the
columns off `C_DamageMeter`, joining them by GUID and ordering them, or drawing.

`renderRow` nests inside `render` rather than sitting beside it because twenty players times seven
columns is 140 cells per pass, and per-row is the only grain at which *"the window is slow"* becomes
*"the window is slow because of how many rows it has"*.

**Every bracket instruments every exit.** A bucket recorded on the happy path only reports a
cheaper-than-real average, because the early returns it skipped are exactly the cheap ones.

Two notes on reading a report, both important enough that
[`perf-analysis/README.md`](perf-analysis/README.md) repeats them: the nesting above is **declared,
not observed** (every call site passes two arguments to `Perf.Note`, never a `parentKey`), and
`Note()` records an undeclared key anyway — so a new bucket can be added ad hoc the moment a capture
points at one, and it simply will not appear in the report until it is declared here.

## The gated bracket idiom

```lua
local Perf = NS.Perf                       -- once, at file load

local t0 = Perf.on and debugprofilestop()
...
if t0 then Perf.Note("renderRow", debugprofilestop() - t0) end
```

**When capture is off, that costs one upvalue read plus one boolean test.** `Perf.on` is false,
`and` short-circuits, `debugprofilestop()` is never called, `t0` is false, and the closing `if` is a
second boolean test on a local. No function call, no table allocation, no string built, nothing
appended to a list. This is why the brackets can sit on a path that runs at raid event rate without
anyone having to argue about whether to remove them later.

Two details that keep it that way:

- **The upvalue is resolved at load, never per call.** `NS.Perf` is a table index; doing it inside
  the bracket would put a hash lookup on the hot path to save nothing. `core/PerfSetup.lua` loads
  before `modules/`, so the upvalue is always either the live harness or its stub — never nil.
- **`core/MythicMeters.lua` deliberately does the opposite** and resolves `NS.Perf` at call time
  (`local Perf = NS.Perf; local t0 = Perf and Perf.on and ...`). Its handlers are an *event* path,
  not a per-frame one, so one extra table index behind an `and` is affordable — and it buys immunity
  to the seam being republished after load on a degraded install or under test.

`core/Secrets.lua` carries **no instrumentation at all**, deliberately: it loads before
`core/PerfSetup.lua` so an upvalue would freeze nil, and a per-value `NS` lookup is precisely the
per-call cost this contract forbids. Its callers — the aggregator's join and the window's render —
carry the brackets instead, which is also where a reader wants to see the number.

The offline `probeOverheadOff` / `probeOverheadOn` pair turns all of the above into evidence rather
than a claim; see below.

## Suspend and resume

The A/B's B arm makes the addon inert **without a `/reload`**. Reloading, or disabling the addon
through the AddOns list, shifts shared-frame ownership — the exact confound that makes the built-in
profiler untrustworthy for this question. So the flip happens in place, live, mid-session.

`suspend` stops three things, and it is three because the addon has three independent sources of
work:

1. **The meter reads.** `modules/Provider.lua` owns every `C_DamageMeter` registration, so its
   `Suspend()` stops the reads **at the source** rather than letting them run and discarding the
   result. A suspended provider answers an empty column carrying the reason `"suspended"`.
2. **The coalescing timers.** `modules/WindowManager.lua:Suspend()` stops every window instance's
   clock. A pass already queued when suspend lands would otherwise fire once more, *inside*
   measurement window B, and be attributed to an addon that is supposed to be doing nothing.
3. **Visibility** — and this is the rule that matters most:

> **Visibility is refused at the SOURCE, never by hiding frames.** `NS.ShouldShow` reads
> `NS.Perf.suspended` as **step 0** of its ladder, above even the master enable. Nothing — a combat
> transition, a zone-in, a roster change, a settings write — can re-show a window behind suspend's
> back.

`core/PerfSetup.lua` calls `Visibility:Refresh()` only to make the already-shown windows act on that
step *now* rather than at the next event. It never calls `Hide()`. An imperative hide from the setup
file would fight the ladder, and the ladder would win at the next context change — silently, mid
measurement.

`resume` restores from **current** state, not from a snapshot: each module's `Resume` rebuilds its
registrations from the columns and windows enabled *now*, so a column toggled or a window created
while suspended comes back correctly. `WindowManager:Resume()` calls `Init()` first for exactly that
reason. No `CONFIG_CHANGED` is published from the setup file — the modules' own resume paths
re-register and re-render, so `core/PerfSetup.lua` never becomes a second sender of a message the bus
already has an owner for.

Perf output is **not** gated on `NS.State.debug`, unlike `NS.Debug`. That gate exists to keep the
addon free when idle; a perf run is explicit user action and none of it executes unless someone typed
`/mm perf start`.

## 1. Offline — `tests/perf.lua`

```sh
lua tests/perf.lua                                   # print the table
lua tests/perf.lua --out /tmp/mm.json --label wip    # also emit a record
```

**Outside the green gate.** `lua tests/run.lua` does not invoke it and no commit depends on it. The
vendored runner drives it as its `perf` suite and keeps the output in the run bundle; that suite is
recorded, never gating (see [testing.md](testing.md)).

It asserts on the **deterministic** half only — API calls, column reads, refresh counts, unit-API
walks and bytes allocated per iteration, isolated by a full collect either side of the measured loop
**with the collector stopped for the duration**. (`collectgarbage("count")` reports the live heap, so
with the incremental collector running the delta across a loop is whatever survived the sweeps that
happened to land inside it — a figure that moved kilobytes between identical runs and once reported
the *armed* arm as cheaper than the dormant one, which is impossible.)

It asserts **no wall-clock threshold, ever**: timings move with the machine, the CPU governor and
whatever else is running, and a gate that flakes is a gate everyone learns to bypass. Timings are
printed for orientation only — read them as ratios between scenarios inside one run.

### The fixture

Twenty group members in a raid, standing in a **dungeon** (`visibility.world` ships false, so an
open-world fixture would hide the window and the whole refresh path would never run — refusal at the
source, again), a **locked** seven-column window so it draws live data rather than the preview grid,
and every column backed by a real session.

### The scenarios

| Scenario | What it drives | What is asserted |
|---|---|---|
| `refresh20x7` | one full coalesced pass — 7 session reads, a 20-source join per column, 140 cells | **exactly one `Provider.GetColumn` per enabled column**; exactly one `GetCombatSessionFromType` per column per refresh; at most one `IsDamageMeterAvailable` across the whole run; **zero** unit-API walks in steady state |
| `refresh20x7Restricted` | the same pass **mid-pull**, where `sourceGUID` is secret and `modules/Aggregator.lua` takes the identity build instead of the GUID join | **exactly one `Provider.GetColumn` per enabled column** — correlating a column must not re-enter the provider per row; **zero** unit-API walks; an absolute allocation ceiling |
| `throttleBurst` | 200 bus events, then 100 sub-interval ticks, then one tick that spends the throttle | **exactly one** refresh, reading exactly one pass worth of columns; zero refreshes before the interval elapses |
| `throttleIdle` | ticks with nothing dirty | zero refreshes, zero column reads |
| `drillOpenClose` | `DrillDown:Enter` / `BuildRows` / `Exit` | zero `GetColumn` calls — a breakdown reads `GetSourceDetail`, never a whole column — and the view is really closed afterwards |
| `refreshWhileDrilled` | a full refresh with a breakdown open | zero column reads; the grid is not being drawn behind the drill-down |
| `rosterRebuild` | one `ROSTER_CHANGED` plus one refresh | the cache really was invalidated (walks > 0) |
| `rosterBurst` | **ten** `ROSTER_CHANGED` plus one refresh | the same walk count as a single message — `modules/Roster.lua` rebuilds **lazily**, on the next read, not eagerly in the handler |
| `rosterCached` | refreshes with an unchanged roster | zero unit reads |
| `applyConfig` | a settings change re-applying config and re-laying every row | recorded only |
| `probeOverheadOff` / `probeOverheadOn` | the same refresh with brackets dormant, then armed | the zero-overhead assertions below |
| `suspended` | a refresh with the provider suspended | **zero** meter API calls — suspend stops the reads at the source |

**A restricted pass costs about 22% more than an unrestricted one** — 397702 bytes against 325890
for the same 20×7 window — and roughly a third of that gap is the harness rather than the addon: the
mock simulates a secret value as a *table* with a trapping metatable, so every secret field becomes an
allocation the client does not make. The rest is identity correlation itself: one key per source per
non-sort column, plus a lookup table per column. The breakdown was measured by running the scenario
with the correlation stubbed out, not estimated.

**The regression guard worth knowing by name is `refresh20x7`'s column count.** One refresh used to
make *two* `GetColumn` calls per column: `modules/Window.lua` re-entered the provider for each
column's group total so the cells could divide by it, while `modules/Aggregator.lua` already held
both operands and had already divided (`cell.percent`). That doubled the addon's entire session-read
cost on its hot path, and it was invisible because nothing counted. Now something counts.

### The zero-overhead pair

`performance-§9` requires this scenario by name, and it carries four assertions:

- the dormant arm stays under an **absolute byte ceiling** (`PROBE_OFF_BYTES_CEILING`, currently
  320000, against a measured 309297 for a 20×7 pass). The relation alone is not enough: if a
  regression adds allocation to `Refresh` itself, both arms rise together and `off <= on` still
  holds. **A rise in that figure IS the finding** — raise the ceiling only with a recorded reason.
- the dormant arm allocates no more than the armed one, which is what the gating idiom buys.
- the probe changes neither how many meter API calls nor how many columns a pass costs.
- the dormant arm reproduces the plain `refresh20x7` figure, proving the two are the same path.

**Read that absolute figure with one caveat.** Most of it is the *harness*, not the addon:
`tests/wow_mock.lua` materializes a fresh session table on every `C_DamageMeter` read — that is what
lets the same fixture arrive plain or secret — so seven columns times twenty sources is a deep copy
per pass that the client never makes. The ceiling still does its job (it catches a rise in what one
refresh allocates) and the ratio between the two arms is unaffected, because both arms pay the
identical harness cost.

Exit code is non-zero on an assertion failure, so this is CI-usable even though nothing gates on it
today.

## 2. In-game — `/mm perf`

```
/mm perf                       # usage
/mm perf start [label]         # begin a run; zeroes the counters, stamps who and where you are
/mm perf measure a             # arm Experiment A — addon ACTIVE; records only while combat is up
/mm perf measure b             # arm Experiment B — same, with the addon SUSPENDED first
/mm perf finish                # end the run, save it to MythicMetersPerfDB, lift any suspend
/mm perf report                # totals for the run
/mm perf dump                  # the raw record, one line of JSON, ready to paste
/mm perf cancel                # abandon the run; nothing is saved
/mm perf show | hide | toggle  # the clickable step panel
```

`/mythicmeters` is the long form and works identically. The step panel runs the identical code path
as the typed verbs — the library returns lines, `settings/Slash.lua` prints them through the tagged
printer — so clicking and typing cannot diverge.

`perf` is a **reserved verb across the collection** and is registered by the addon, in
`NS.COMMANDS`, never by the library behind the verb table's back. A verb registered elsewhere is a
verb the help index, the settings landing page and the README all miss.

### The A/B protocol

1. Pick a **repeatable** fight — a training dummy with a fixed rotation, not a raid pull. The two
   arms must be the same work, not the same clock.
2. Hold everything else fixed: same zone, same group state, same addons loaded and in the same order.
   Suspend holds shared-frame ownership fixed; you hold the rest. Hold the **window layout** fixed
   too — this addon's cost scales with open windows and columns per window, so an arm with a second
   window open is not the same measurement.
3. `/mm perf start <label>`, then `measure a`, fight; then `measure b`, fight the same fight. Each
   arm records only while combat is up.
4. `/mm perf finish`, then `report` and `dump`. `/reload` to flush `MythicMetersPerfDB` to disk.
5. Press **Copy** on the debug-log window and commit the run as a bundle under
   [`perf-analysis/`](perf-analysis/) if it is worth keeping. One paste carries the report, the dump
   and the run's lifecycle lines — all three of the bundle's artifacts.

Caveat before you read a delta: `fps.deltaMsPerFrame` has a resolution floor. Treat anything below
roughly 0.5 ms/frame as **unresolved** rather than as zero, and read the bucket figures instead —
those measure the addon directly and are unaffected by arm mismatch or frame pacing. A client with a
frame limiter pinned produces an unusable delta and the record cannot tell you so; judge that from
the arms (two arms at the same frame time, or at a round one like 8.33 ms).

## 3. Where the numbers go

- **In-game captures worth keeping** → [`perf-analysis/`](perf-analysis/), standing and cumulative,
  so captures compare across addon versions. One frozen bundle per capture at
  `docs/perf-analysis/<YYYYMMDD-HHMMSS>/`, holding exactly three artifacts: `report.md`,
  `dump.json` and `ANALYSIS.md`. That directory's README documents the naming, the artifacts, the
  schema and how a capture is taken.
- **Offline runs** → the bundle for the run that produced them, under
  [`automated-tests/`](automated-tests/). They are reproducible from the repo, so they need no
  standing store.
- **An interpretation without its record is an assertion.** If a decision is taken off a capture, the
  capture gets committed and the decision cites its bundle. No decision in `core/PerfSetup.lua`
  currently quotes a figure, because no in-game capture has been taken yet — the bucket list there is
  reasoned from the addon's structure, and it says so.

## 4. Complexity

Cyclomatic complexity is measured by the same vendored runner, as its `complexity` suite:

```sh
lizard -l lua -x "./libs/*" -x "./tests/_kit/*" .
```

Recorded and compared, **never thresholded into a build failure** — though the **release** does gate
on zero functions above CCN 15. Both checkpoints are stated in full in
[testing.md](testing.md#automated-test-records--the-consolidated-run).
