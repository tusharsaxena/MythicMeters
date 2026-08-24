# CLAUDE.md — Ka0s Multi Meters

**Ka0s WoW addon.** Adheres to the **Ka0s WoW Addon Standard** —
https://github.com/tusharsaxena/WowAddonStandards

## Standards compliance (read first)

This repo is built to the **Ka0s WoW Addon Standard** (URL above). All development here — features,
refactors, doc changes — MUST conform to it. The standard is the source of truth for layout, TOC
shape, the Ace substrate, schema-driven settings, slash/prefix conventions, locales, Compat,
tests/lint, and doc structure.

**If a change would deviate from the standard, STOP and flag the deviation explicitly.** Do not
silently deviate and do not silently "fix" to match. Surface it and let the user decide which of
two things it is:

1. **An accepted deviation** — this addon intentionally differs; record it as a row in
   `docs/ARCHITECTURE.md` -> `## Documented deviations`, shaped
   `| Rule | What differs | Why | Decided | Re-check trigger |`. That register is the single home:
   a deviation not in it is not ratified.
2. **A change to the standard itself** — the standard's definition should evolve; the update
   belongs upstream in the WowAddonStandards repo, after which this addon conforms to the new rule.

When in doubt, treat standard conformance as a hard requirement and ask.

## The one rule specific to this addon

Every number this addon displays comes from Blizzard's built-in damage meter (`C_DamageMeter`) and
is a **secret value** whenever the `Combat` addon restriction is active. Tainted code may not
compare, add, key on, or apply `#` to a secret. Two invariants carry that rule:

- **`modules/Provider.lua` is the only file that calls `C_DamageMeter`.**
- **`core/Secrets.lua` is the only file that inspects a value.** Everywhere else a meter value is an
  opaque handle you may pass to a widget setter or the native formatter, and to nothing else.

A third follows from the widget side: a frame handed a secret via `SetValue` has secret anchoring
data, so **layout is computed from config and never read back off a frame**. Read
`docs/data-flow.md` before touching the data path.

Start here, then read the docs:

- **`docs/ARCHITECTURE.md`** — module map, settings schema, message bus, slash surface, event
  wiring, taint notes, known limitations, documented deviations. What this addon actually is.
- **`docs/testing.md`** — how to verify: the headless harness, lint, and the green commit gate.
- Topic detail in `docs/` as needed (`scope.md`, `module-map.md`, `schema.md`, `settings-panel.md`,
  `data-flow.md`, `common-tasks.md`, `smoke-tests.md`).

Green gate before every commit: `lua tests/run.lua` and `luacheck .` (0/0). Never auto-stage/commit/
push and never bump the version without an explicit instruction.

Bundles [LibKa0s](https://github.com/tusharsaxena/LibKa0s) v1.11.2 (MIT).
