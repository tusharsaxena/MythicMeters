# Ka0s Mythic Meters — v0.1.0 Implementation Plan

Executes [the approved design](../specs/2026-08-09-mythic-meters-design.md). Written 2026-08-09.

## Sequencing rationale

The build is ordered by **contract depth**, not by feature. Files that define symbols other files
consume are written first, so that later work can be parallelized without agents guessing at each
other's shapes. The one genuinely risky area — secret values — is concentrated in two files
(`core/Secrets.lua`, `modules/Provider.lua`) and then verified adversarially rather than trusted.

## Stage 0 — Repository foundation *(done)*

| Step | Detail |
|---|---|
| `git init` | Repo did not previously exist |
| **`.gitattributes` first** | Client-bound canonical body verbatim from `line-endings-§5`, written before any other file |
| Vendor Ace3 stack | From `PanelMaster/libs` (AceAddon, AceEvent, AceTimer, AceDB, AceDBOptions, AceConsole, AceConfig, AceGUI, AceGUI-SharedMediaWidgets, LibSharedMedia, LibStub, CallbackHandler) |
| Vendor LDB | `LibDataBroker-1.1`, `LibDBIcon-1.0` from `LootHistory/libs` |
| Vendor Ka0s payloads | `LibKa0s/LibKa0s` → `libs/LibKa0s/` and `LibKa0s/testkit` → `tests/_kit/`, **whole, from the library repo**, `diff -r` empty both ways |
| Runner mode | `git update-index --chmod=+x tests/_kit/run-automated-tests.sh` → `100755` in the index |
| Console font | `media/fonts/JetBrainsMono-Regular.ttf` + `OFL.txt` |

## Stage 1 — Foundation (parallel, 3 agents)

Everything downstream depends on these symbols existing with a known shape.

- **`toc-and-config`** — `MythicMeters.toc` (fixed field order, `#`-section listing, single
  `## Interface: 120007`, `X-Standard`), `.luacheckrc`, `.pkgmeta`, `LICENSE`.
- **`core-namespace`** — `Compat`, `Constants` (the STAT catalog), `Namespace`, `State`,
  **`Secrets`**, `LSMPatch`, `MythicMeters` (AceAddon + the `NS.Print` reclaim), `Database`,
  `defaults/Profile.lua` (the window template — the only place a default is hardcoded),
  `locales/enUS.lua`.
- **`libka0s-setup`** — the five setup files, each a descriptor plus a degradation stub and nothing
  else. Perf buckets are declared here, so their names are fixed before any bracket is written.

## Stage 2 — Implementation (parallel, 5 agents)

Each agent receives the Stage 1 agents' published-symbol reports as context.

- **`data-layer`** — `Format` (native `NumericRuleFormatter`), `Provider` (sole `C_DamageMeter`
  caller), `Roster` (group, pet→owner, role), `Aggregator` (GUID join, sort modes, freeze-on-restrict).
- **`window-render`** — `WindowManager` (registry, copy-from), `Window` (frame, coalesced refresh,
  show-decision ladder), `Row` (pooled rows, bar + text + icons).
- **`interaction`** — `Tooltip` (cell spell breakdown, name all-stats), `DrillDown` (per-player view,
  death recap), `Visibility` (context rules, refused at the source).
- **`settings-schema`** — the single `NS.Schema` and the single write seam, including the
  window-relative path model.
- **`settings-pages`** — thirteen page files, eager category + lazy body + `EnsureDefaultsButton`.

## Stage 3 — Verify (parallel, 3 adversarial agents)

Three independent lenses over the code on disk, not over any summary:

1. **secrets** — illegal arithmetic/comparison/keying/`#`, `C_DamageMeter` outside `Provider`, value
   inspection outside `Secrets`, geometry read back off a secret-marked frame.
2. **contract** — publish-before-consume against TOC order, Lua 5.1 syntax, schema-vs-profile default
   agreement, the `or`-merge bug, accidental globals.
3. **standard** — setup files still descriptor-only, stub member coverage, bus single-sender, eager
   category / lazy body, perf bracket idiom and bucket reachability, deferred debug formatting, US
   spelling.

## Stage 4 — Integration *(mine, not delegated)*

Findings triaged and fixed by hand, then:

```sh
luacheck .                 # must be 0/0
lua tests/run.lua          # must be green
```

## Stage 5 — Tests

Suites on the vendored kit, covering **what is ours**: descriptors, degradation stubs (proven by
loading with the library *absent*, never by hand-stubbing), the secret guards against a mock that
returns opaque values, the GUID join, pet folding, sort-mode fallback, window-relative path
resolution, visibility rules, and the meter-unavailable path. Plus `tests/perf.lua` scenarios
including the mandatory zero-overhead-when-off case.

## Stage 6 — Documentation

Root three (`README.md`, `CLAUDE.md` stub with the **LibKa0s v1.8.3 provenance line**,
`DEPENDENCIES.md`) plus `LICENSE`. `docs/`: the trio, the five verification-and-record docs, all six
Tier 1 topic docs, Tier 2 triggers evaluated, and `ARCHITECTURE.md`'s `## Documentation map`
registering every page exactly once.

## Stage 7 — Record and release readiness

`tests/_kit/run-automated-tests.sh --release 0.1.0`, then the bundle's `ANALYSIS.md` and the
`RESULTS.md` standing sections by hand. CRLF normalization pass, then the first commit.

## Known risks carried into the build

| Risk | Mitigation |
|---|---|
| `combatSources` may not arrive pre-sorted | Only `provider` sort mode depends on it; correction confined to `Provider.lua` |
| Pet→owner has no API link | Best-effort via `UnitGUID("<unit>pet")`; unattributable pets dropped, never shown as phantom rows |
| Secret rules only fail inside a dungeon in combat | Dedicated adversarial verify pass plus a mock that returns opaque values |
| Full brief in one release | Provider seam isolates the riskiest assumption to one file |
