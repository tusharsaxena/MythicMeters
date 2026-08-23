# Testing

A headless Lua unit harness lives under `tests/` — run `lua tests/run.lua` from the repo root (it
exits non-zero on any failure); `luacheck .` must stay at 0 warnings and 0 errors. The tree is clean
on both counts today, so a new warning is a regression rather than background noise.

The suites load every source under a WoW-API mock and assert what is genuinely ours: the LibKa0s
descriptors and their degradation stubs, the GUID join in `modules/Aggregator.lua`, pet folding,
sort-mode fallback, window-relative path resolution, the visibility ladder, the meter-unavailable
path, and — the one that matters most here — that no file outside `core/Secrets.lua` ever inspects a
value that came out of `C_DamageMeter`.

The harness draws nothing and cannot model taint, so it complements rather than replaces the in-game
checks in [smoke-tests.md](smoke-tests.md).

## Local toolchain

`lua` (5.1 exactly) and `luacheck` on `PATH` are the whole toolchain — there is no build step, and
the only runner beyond `tests/run.lua` is the vendored `tests/_kit/run-automated-tests.sh`, which
shells out to the same two commands. `lizard` is a third, **optional** tool, driven by the
non-gating `complexity` suite of that runner.

What to install, in the WSL2/Ubuntu commands that actually work, is the root
[DEPENDENCIES.md](../DEPENDENCIES.md). That file says *what to install*; this one says *how to
verify*. Lua 5.1 is a hard requirement there for a reason worth repeating once: the kit's loader
sandboxes each source chunk with `setfenv`, which 5.2 removed.

## What is the harness, and what is this addon's

The registry, the assertion set, the `skip` status, the suite-inventory gate, the `--list` renderer
and the source loader all belong to the **vendored kit** — `tests/_kit/framework.lua`,
`loader.lua`, `mock_base.lua`, `vendor_sync.lua`, copied verbatim from LibKa0s's `testkit/`.

**`tests/_kit/` is never edited here.** A kit fix goes upstream to LibKa0s and is re-vendored; a
local patch is reverted silently by the next re-vendor, and in the meantime this addon is testing
something no other repo runs. `tests/test_vendor_sync.lua` is the byte-identity gate that says so
out loud.

What stays in `tests/run.lua` is only what is genuinely Ka0s Multi Meters': the two load lists, the
instance factory `loadInstance`, the lifecycle kick, and the suite list.

The kit **collects, then runs**. `test()` only records a case; nothing executes until `Kit.run`.
That is why `--list` cannot disagree with the run it enumerates — it is a pure filter over the same
registry rather than a second code path.

### Both load lists are derived, never typed

```lua
local LIB_FILES   = Loader.xmlFiles(root .. "/libs/LibKa0s/LibKa0s.xml")
local ADDON_FILES = Loader.tocFiles(root .. "/MultiMeters.toc")
```

The addon half comes straight out of `MultiMeters.toc`, in TOC order, so the runner cannot drift
from what the client loads. The library half comes out of `LibKa0s.xml`, in the XML's own order,
because the TOC pulls the whole library in through that one `.xml` and `Loader.tocFiles`
deliberately skips it.

That derivation is not fussiness. **A short library load list does not raise.** It leaves the
dependent major unregistered, the host's setup file falls back to its degradation stub, and the
suite happily measures the stub — green, and testing nothing. Five seams in this addon degrade that
way (`core/CoreSetup.lua`, `core/PerfSetup.lua`, `core/DebugLogSetup.lua`, `settings/Slash.lua`,
`settings/OptionsSetup.lua`), so `tests/run.lua` also asserts by name that
`Core.lua`, `DebugLog.lua`, `Slash.lua`, `Options.lua`, `OptionsWidgets.lua`, `OptionsScroll.lua`,
`Perf.lua` and `PerfPanel.lua` are all present. A re-vendor that drops one fails there, with a name.

The degraded path is exercised by a **real load**, never by hand-stubbing the member under test:

```lua
local inst = T.load{ libFiles = {} }   -- the whole addon, with LibKa0s absent
```

### One environment detail worth knowing

Nearly every client-API read in this addon is spelled `_G.C_DamageMeter`, `_G.canaccessvalue`,
`_G.UnitGUID` — explicit, because `architecture-§1` forbids the deprecated bare globals and the
`_G.` prefix is what makes a Compat-bypassing read visible in review. The kit's per-chunk
environment falls through to the process's real `_G`, which holds no client API at all, so an
unbound `_G.X` would read nil and every secret-value case would quietly measure the *absent-API
fallback* instead of the API. `tests/run.lua` closes that by publishing the kit-built environment
back as `mocks._G`, per instance.

## What the mock models, and what it admits it cannot

`tests/wow_mock.lua` layers this addon's half over the shared base in `tests/_kit/mock_base.lua`,
overwriting per key. Its own header lists what it inherits and what it replaces, and why: the frame
model (the base returns the frame itself from every widget factory, which makes "which region got
the text" unanswerable — and this addon's entire output is text and bar values written onto per-cell
FontStrings and StatusBars), the Ace module lifecycle, the message bus, and `C_AddOns`.

**The secret simulator is the most valuable thing in that file.** `mocks.secret(v)` returns a table
whose metatable raises a tagged `MOCK_SECRET_VIOLATION` from every operation tainted code may not
perform on a secret — arithmetic, comparison, `..`, indexing, field assignment. Without it a suite
that "proves" the never-inspect rule proves nothing, because a plain number satisfies every
assertion a secret would have failed.

It is equally valuable for being honest about its holes, which the file states rather than papers
over. In Lua 5.1 there is no metamethod for truth-testing, so `if secret then` passes here and
raises in the client; `__len` is defined but 5.1 never consults it for a table, so `#secret` answers
0 here; a secret used as a table **key** is an ordinary hash lookup and cannot be trapped at all;
and `type(secret)` answers `"table"` where the client answers the underlying type. Those are not
covered by the harness, and the defenses against them are structural instead: `SafeIterate` /
`SafeCount` in `core/Secrets.lua` never apply `#`, `modules/Aggregator.lua` joins on `sourceGUID`
(the one field the client never makes secret), and review is what catches a truth test. Read that
header before writing a secret-handling case, then pair the case with a smoke test — a rule the
harness cannot enforce is a rule that has to be checked in a real client.

One deliberate over-strictness: `__concat` **is** trapped, which is stricter than the live client
(where `..` on a secret yields a secret string). Every call site here that concatenates a possibly
secret value already guards it — `pcall` in `modules/Format.lua`, `NS.IsConcatSafe` in
`modules/Row.lua` — so a trap there turns "somebody removed the guard" into a failing test.

The control surface is listed in one block at the top of `tests/wow_mock.lua`: the secret helpers,
the meter fixtures (`setSession`, `buildSession`, `setSourceDetail`, `setMeterAvailable`,
`resetMeterCalls`, `__meter`), the group fixtures, the frame registry, the TOC manifest and the
timers.

## Running it

```sh
lua tests/run.lua            # the whole suite; non-zero exit on any failure
lua tests/run.lua --list     # the inventory, printed; runs nothing, exits 0
luacheck .                   # must be 0 warnings / 0 errors
```

**There is no single-suite mode, and that is a design choice rather than a gap.** `Kit.run` asserts
the declared suite list against `tests/test_*.lua` on disk **in both directions** before it loads a
single case: a declared suite with no file is a hard error, and a suite file that is not declared is
one too. So narrowing `SUITES` in `tests/run.lua` to run one file does not work — it reddens
immediately. Run the whole thing (it is a few seconds) and filter the output instead:

```sh
lua tests/run.lua | grep -i provider     # just the cases whose names mention the provider
lua tests/run.lua | grep FAIL            # just the failures
```

A suite still being written is declared as `{ name = "test_foo", pending = "why" }` and **must** lose
that field the moment its file lands. A skip is never a pass: the runner counts skips in their own
column and prints each one with its reason.

### The inventory

The **authoritative case count and per-suite breakdown** live in the generated inventory at
[test-cases.md](test-cases.md) — never a hand-typed number in this file or in the README prose.

```sh
lua tests/run.lua --list > docs/test-cases.md            # regenerate
diff <(lua tests/run.lua --list) docs/test-cases.md      # verify in sync; no output = clean
```

Whenever the suite changes — a case added, removed or renamed, or the pass count moves — regenerate
the inventory **and** update the README `Tests` badge in the *same* change, never as a deferred
follow-up.

## Verifying the vendored copies

```sh
diff -r --strip-trailing-cr ../LibKa0s/LibKa0s libs/LibKa0s   # content — MUST be empty
diff -r ../LibKa0s/LibKa0s libs/LibKa0s                       # bytes  — SHOULD be empty
diff -r --strip-trailing-cr ../LibKa0s/testkit tests/_kit      # content — MUST be empty
diff -r ../LibKa0s/testkit tests/_kit                          # bytes  — SHOULD be empty
```

Run **both** halves of each pair before every commit — they are different findings, and nothing
about "the tests are green" will tell you the copies have diverged. The library's own suite passes
against the library; this addon's passes against a stale copy that still works.

**Content differs** → a real fork in `libs/` or `tests/_kit/`, the forbidden state. Name every hunk.

**Bytes differ but content matches** → a line-ending divergence, not a fork. Both repos pin
`* text=auto eol=crlf` with LF blobs, so a working tree holding *either* ending reads clean to
`git status` and neither side's cleanliness proves anything. Establish which side drifted
(`file -b <path>`, and `git cat-file -p HEAD:<path> | file -b -` for what git stores) and
renormalize that side. **Re-vendoring will not converge it, and the fix is never an edit under
`libs/` or `tests/_kit/`** — that makes a fork nobody knows about, which the next re-vendor reverts
silently.

## Automated test records — the consolidated run

All four out-of-game suites go through one vendored runner, and every run is recorded:

```sh
tests/_kit/run-automated-tests.sh                                          # all four, writes a bundle
tests/_kit/run-automated-tests.sh --suite complexity                       # a subset
tests/_kit/run-automated-tests.sh --suite lint --suite tests --no-bundle   # the green gate; writes nothing
tests/_kit/run-automated-tests.sh --release 0.1.0                          # mark the bundle a release record
```

There are **two checkpoints** — the **commit** and the **release** (the tag) — and a suite's answer
differs between them, so a bare "gates? yes/no" column cannot be written honestly. Both are named:

| Suite | Command | Gates the **commit**? | Gates the **release** (tag)? |
|---|---|---|---|
| `lint` | `luacheck .` | **yes** | **yes** |
| `tests` | `lua tests/run.lua` | **yes** | **yes** |
| `perf` | `lua tests/perf.lua` | **no — recorded only** | **yes** |
| `complexity` | `lizard -l lua -x "./libs/*" -x "./tests/_kit/*" .` | **no — recorded only** | **yes** |

**`lint` and `tests` gate the COMMIT.** Both green, every time, before anything is staged.

**`perf` and `complexity` never fail a run and never gate a commit** — they are measured, recorded
and diffed, not thresholded. A threshold that fails a run teaches everyone to reach for
`--no-verify`, after which the gate protects nothing and the habit remains. They contribute `amber`,
which is a signal rather than a stop.

**The RELEASE is gated on all four.** The tag requires all four suites at `pass` **plus zero
functions above CCN 15**, evaluated by `/wow-addon:bump-version` from the `manifest.json` the release
run writes — not by the runner, whose exit code is unchanged.

**A missing tool is a SKIP recorded with its reason, never a pass.** A green run that measured
nothing must not be mistakable for a green run that measured everything, so an absent `lizard` or
`luacheck` is written into the manifest as `skip` with the install line that fixes it. **A skip is
not a pass for the release gate either**: at the tag a `skip` is NOT EVALUATED rather than passed.
Install the tool and re-run.

Results live in [`automated-tests/`](automated-tests/) — `RESULTS.md` for the trend line, one frozen
`<YYYYMMDD-HHMMSS>/` bundle per run. See that directory's [README](automated-tests/README.md).

## The offline perf scenarios

`lua tests/perf.lua` is the fourth thing that can be run out of game, and it sits **outside the
green gate** on purpose: `lua tests/run.lua` does not invoke it and no commit depends on it. What it
asserts is the deterministic half — how many `C_DamageMeter` reads a refresh makes, how many
refreshes a burst of events produces, how many unit-API walks a roster change costs, how many bytes
a dormant perf bracket allocates. It asserts **no** wall-clock threshold, ever.

The scenarios, what they guard and how to read the output are in
[performance.md](performance.md).

## In-game checks

The harness draws nothing, cannot model taint, and — per the mock's own header — cannot trap a truth
test, a `#`, or a secret used as a table key. Everything in that gap is
[smoke-tests.md](smoke-tests.md), and the secret-value scenarios there are not optional: they are the
only place rules R1 and R3 are checked against a client that actually enforces them. Run that file
before claiming a non-trivial change works.
