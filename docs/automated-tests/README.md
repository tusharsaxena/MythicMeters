# Automated test records

Every run of the four out-of-game suites, recorded. The normative rules are the standard's
[`automated-tests`](https://github.com/tusharsaxena/WowAddonStandards/blob/master/standards/standards/automated-tests.md)
section; this file is the local how-to. How to *verify the addon* is
[../testing.md](../testing.md).

## Running

```sh
tests/_kit/run-automated-tests.sh                                          # all four, writes a bundle
tests/_kit/run-automated-tests.sh --suite complexity                       # a subset
tests/_kit/run-automated-tests.sh --suite lint --suite tests --no-bundle   # the green gate; writes nothing
tests/_kit/run-automated-tests.sh --release 0.1.0                          # mark the bundle a release record
```

Run it from the repo root.

The runner is **vendored** from LibKa0s's `testkit/` and is byte-identical in every Ka0s addon.
**Use `tests/_kit/run-automated-tests.sh` — never an addon-side copy of it.** There is no
`scripts/` variant here and there must not be one: a local runner is a fork that drifts from every
sibling repo while still printing a familiar-looking table, and the next re-vendor reverts it
silently. A runner fix goes upstream to LibKa0s and comes back through re-vendoring.

The same rule covers the rest of `tests/_kit/` — never edit it. `tests/test_vendor_sync.lua` is the
byte-identity gate that catches an edit.

## What gates, and what only records

There are **two checkpoints** — the **commit** and the **release** (the tag) — and a suite's answer
differs between them, so a bare "gates? yes/no" column cannot be written honestly. Both are named:

| Suite | Command | Gates the **commit**? | Gates the **release** (tag)? |
|---|---|---|---|
| `lint` | `luacheck .` | **yes** | **yes** |
| `tests` | `lua tests/run.lua` | **yes** | **yes** |
| `perf` | `lua tests/perf.lua` | **no — recorded only** | **yes** |
| `complexity` | `lizard -l lua -x "./libs/*" -x "./tests/_kit/*" .` | **no — recorded only** | **yes** |

**`lint` and `tests` gate the COMMIT.** Both must be green before anything is staged. The runner's
exit code is non-zero only when the verdict is `red`, which is exactly "a gating suite failed", so
`--suite lint --suite tests --no-bundle` is usable as a pre-commit check on its own.

**`perf` and `complexity` never fail a run and never gate a commit.** They are measured, recorded
and diffed — not thresholded. A threshold that fails a run teaches everyone to reach for
`--no-verify`, after which the gate protects nothing and the habit remains. They contribute `amber`,
which is a signal rather than a stop.

### The release gate

**The RELEASE — the tag — is gated on all four suites at `pass`, plus zero functions above CCN 15.**

That evaluation is `/wow-addon:bump-version`'s, made from the `manifest.json` the release run writes,
**not** the runner's: the script's exit code is unchanged by `perf` or `complexity`, and it stays
that way on purpose so the commit gate and the release gate cannot be confused for one another. A
release run is produced *before* the tag, with `--release <version>`, and carries an `ANALYSIS.md`
write-up.

### A missing tool is a skip, with its reason

An absent `lizard`, `luacheck` or Lua interpreter means the suite **did not run**. It is recorded as
`skip` together with the reason and the install line that fixes it (`lizard not on PATH — install:
pipx install lizard`) — never as a pass, so a green run that measured nothing cannot be mistaken for
a green run that measured everything.

**A skip is not a pass for the release gate either.** At the tag a `skip` is **NOT EVALUATED**
rather than passed: install the tool, re-run, and tag from a run that actually measured all four.

## What is here

- **`RESULTS.md`** — one row per run across all four suites, plus the current complexity watch list.
  **One file, overwritten in place.** That is the point: the git history of that single path *is*
  the trend line, so a regression is a `git log -p docs/automated-tests/RESULTS.md` away rather than
  a directory listing to reconstruct. Never fork it into dated copies.

- **`<YYYYMMDD-HHMMSS>/`** — one **frozen bundle** per run: `manifest.json` plus one file per suite,
  and the `ANALYSIS.md` write-up.

  | File | Suite | What it is |
  |---|---|---|
  | `manifest.json` | — | the machine-readable verdict: per-suite status, notes, host tool versions, the release marker. The release gate reads this. |
  | `lint.txt` | `lint` | `luacheck .` output, verbatim |
  | `tests.txt` | `tests` | `lua tests/run.lua` output, verbatim |
  | `test-cases.md` | `tests` | the `--list` inventory as of that run |
  | `perf.txt` | `perf` | the offline scenario table |
  | `perf.json` | `perf` | the same run as a schema record |
  | `complexity.txt` | `complexity` | `lizard` output, including the functions over CCN 15 |
  | `ANALYSIS.md` | — | the write-up: what moved, what it means, what to watch |

  A suite that was skipped contributes no file — the manifest carries the reason.

Bundles are **frozen once written**: never edited, never pruned, never renamed to match a later
convention. If a reading turns out to be wrong, the *next* bundle's `ANALYSIS.md` says so.

## Where perf records live

**Offline** perf records (`tests/perf.lua`) live in the bundle for the run that produced them — right
here, as `perf.txt` and `perf.json`. They are reproducible from the repo, so they need no standing
store.

**In-game** captures cannot be produced by a script: a human runs `/mm perf` in a live client and
copies the record out. Those keep their own standing store of frozen per-capture bundles at
[`../perf-analysis/`](../perf-analysis/). The two harnesses answer different questions and their
outputs are deliberately not merged — see [../performance.md](../performance.md).
