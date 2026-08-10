# Ka0s Mythic Meters — Design

**Status:** approved 2026-08-09 · **Target:** v0.1.0

A single-frame, multi-column group meter for Retail (Midnight, 12.x). It reads every number from
Blizzard's built-in damage meter through `C_DamageMeter` and never parses the combat log.

---

## 1. Why this addon exists

Every other meter shows one statistic per window. Answering "who kicked, who dispelled, who stood in
things, who died" means four windows or four mode switches. Mythic Meters shows all of them as
columns of one grid, one row per group member, each cell carrying a bar and its text.

## 2. Scope

**In scope for v0.1.0:** the full brief — multiple independently configured windows with
copy-settings-from, the complete frame/header/rows/bars/text/icons/tooltip/visibility/columns/data
config tree, current-vs-overall sessions, tooltips, cell drill-down, and death recap.

**Explicitly out of scope:** the scoring mechanism. It is deferred, and §7 records why it cannot be
built the obvious way.

## 3. The data source

`C_DamageMeter`, discovered from the Midnight API documentation rather than assumed.

| Surface | Detail |
|---|---|
| `Enum.DamageMeterType` | `0 DamageDone` `1 Dps` `2 HealingDone` `3 Hps` `4 Absorbs` `5 Interrupts` `6 Dispels` `7 DamageTaken` `8 AvoidableDamageTaken` `9 Deaths` `10 EnemyDamageTaken` |
| `Enum.DamageMeterSessionType` | `0 Overall` `1 Current` `2 Expired` |
| Session read | `C_DamageMeter.GetCombatSessionFromType(sessionType, type)` → `{ combatSources, maxAmount, totalAmount, durationSeconds }` |
| Per-source detail | `C_DamageMeter.GetCombatSessionSourceFromType(sessionType, type, sourceGUID)` → `{ combatSpells, maxAmount, totalAmount }` |
| Source row | `sourceGUID`, `name`, `classFilename`, `specIconID`, `isLocalPlayer`, `totalAmount`, `amountPerSecond`, `deathTimeSeconds`, `deathRecapID`, `classification`, `sourceDisplayType`, `factionGroup` |
| Spell row | `spellID`, `totalAmount`, `amountPerSecond`, `creatureName`, `overkillAmount`, `isAvoidable`, `isDeadly` |
| Availability | `C_DamageMeter.IsDamageMeterAvailable()` → `isAvailable, failureReason` |
| Events | `DAMAGE_METER_CURRENT_SESSION_UPDATED`, `DAMAGE_METER_COMBAT_SESSION_UPDATED(type, sessionID)`, `DAMAGE_METER_RESET` |

`Dps` and `Hps` are never queried: `amountPerSecond` ships on the same source row as `totalAmount`,
so one `DamageDone` read fills both halves of the Damage column.

## 4. Secret values — the constraint that shapes everything

Session returns are `SecretWhenInCombat`. When the `Combat` addon restriction is active, the numeric
fields come back as **secret values**, and tainted code may not compare them, do arithmetic on them,
use them as table keys, or apply `#`. `classFilename`, `specIconID`, `isLocalPlayer` and
`deathRecapID` are marked `NeverSecret` and are always readable; `name` is `ConditionalSecret`.

| In combat | |
|---|---|
| Permitted | `StatusBar:SetValue` / `SetMinMaxValues` with secrets · `string.format`/concat with secrets · `NumericRuleFormatter:FormatNumber` · `ClearAllPoints`/`SetPoint` · creating, showing and hiding our own unprotected frames |
| Forbidden | comparing, adding or keying on a secret · reading `GetPoint`/`GetWidth`/`GetLeft` back off a frame that received one · clearing a secret aspect other than via `SetToDefaults()` |

Three design rules follow, and they are enforced in one place rather than remembered in twenty:

1. **`core/Secrets.lua` is the only file that inspects a value.** Everything downstream treats a
   value as an opaque handle it may pass to a widget setter or a formatter, and to nothing else.
2. **Row order is never computed from values in combat** (§5).
3. **Layout is computed from config, never read back off a frame** (§6).

`C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.Combat)` is the runtime test,
with `canaccessvalue()` as the per-value belt-and-braces. `ADDON_RESTRICTION_STATE_CHANGED(type,
state)` is the transition signal; it fires with `state = Activating` **before** enforcement begins,
which is the last moment a correct value-sort can be taken.

Note that the meter's secrecy keys off `Combat`, **not** `ChallengeMode`. Between packs in a key,
values are fully readable — so value sorting works for most of a dungeon run.

### Number formatting

Abbreviating `12400000` to `12.4M` is arithmetic and therefore illegal on a secret. The escape hatch
is `C_StringUtil.CreateNumericRuleFormatter()`, whose `FormatNumber(n)` performs the division and
rounding **natively** and accepts secrets. `modules/Format.lua` owns the formatter instances; no call
site divides anything.

## 5. Rows, columns and ordering

A **column** is one `Enum.DamageMeterType`. A **row** is one group member, keyed on `sourceGUID` —
never secret, so legal as a table key and the only stable join key across columns.

`modules/Aggregator.lua` reads one column per enabled stat, joins them by GUID, filters to group
members, folds pets into their owners, and orders the result. Three per-window sort modes:

| Mode | Behavior |
|---|---|
| `value` | Sort by the designated sort column's values. Attempted only when comparison is legal; falls through to `provider` when it is not. |
| `provider` | Follow the order Blizzard returns `combatSources` in for the sort column. Legal in combat because iteration order requires no comparison. |
| `roster` | Group order, then role, then name. Stable, never reshuffles mid-pull. |

Default is `value`, which degrades to a sort frozen at the `Activating` edge and updated in place for
the duration of the pull.

**Unverified assumption, deliberately isolated:** that `combatSources` arrives pre-sorted by the
requested stat. Nothing in the documentation states it. `provider` mode depends on it; `value` and
`roster` do not. If it proves false in-game, the correction is confined to `modules/Provider.lua`.

**Pet folding is best-effort.** The API exposes `sourceGUID` and `classification` but no explicit
owner link, so pets are matched to owners by GUID heuristics and by `UnitGUID` over the group. A pet
that cannot be attributed is dropped rather than shown as a phantom row.

**Default columns:** Player · Damage (total + per-second) · Healing (total + per-second) ·
Interrupts · Dispels · Avoidable Damage · Deaths. Every column carries a bar scaled to that column's
session `maxAmount`, plus text.

## 6. Windows

A window is `{ id, name, config }` — an instance, not a singleton. There are no global display
settings; everything is per-window. This is what makes multi-window and copy-settings-from cheap: a
copy is a deep table copy, optionally filtered to one config group.

`modules/WindowManager.lua` owns create / rename / delete / duplicate / copy-from and the window
registry. `modules/Window.lua` builds and refreshes one window. Cells are a `StatusBar` plus a
`FontString`, drawn from a pool.

**Column management is settings-panel only**, out of combat. There is no in-window drag editor. That
choice removes the secret-geometry hazard entirely: no code path needs to read a cell's position back
after that cell has been handed a secret value.

**Refresh.** The meter events mark a window dirty; an `OnUpdate` coalesces to a configurable
interval (default 0.25s) so a busy pull cannot drive one rebuild per event. `DAMAGE_METER_RESET` and
roster changes force a full rebuild.

**Degradation.** When `IsDamageMeterAvailable()` is false the window renders Blizzard's
`failureReason` and how to enable the meter, in place of rows.

## 7. Deferred: scoring

A weighted score across damage, healing, kicks and dispels is arithmetic over meter values, so it
**cannot be computed in combat at all**. When it lands it will be an out-of-combat / post-run
feature, or it will be expressed through `C_CurveUtil` curve objects, which evaluate natively. This
is recorded now so the v0.1.0 data layer is not designed toward an in-combat aggregate it can never
produce.

## 8. Settings

One `NS.Schema` table drives the panel, the slash CLI and defaults reset, per the standard.

Per-window settings would make schema paths dynamic (`windows.<id>.frame.width`), which the flat
path model does not express. **Resolution:** schema rows for window settings use a path relative to
a window — `window.frame.width` — and `NS.GetSetting` / `NS.SetByPath` resolve them against the
session's **active window** (the one selected in the panel's window picker). Global rows use absolute
paths. One schema, one write seam, and `/mm set window.frame.width 300` targets the active window.

Pages: Windows · Frame · Header · Rows · Bars · Text · Icons · Tooltip · Visibility · Columns ·
Data · General · Profiles.

**Visibility default:** dungeon, raid, arena and battleground on; open world off; plus hide-when-solo
and hide-in-vehicle.

## 9. Module map

| File | Responsibility |
|---|---|
| `core/Secrets.lua` | The only inspector of values: restriction state, `canaccessvalue` guards, safe iteration |
| `modules/Provider.lua` | The only caller of `C_DamageMeter`. Returns columns; never inspects a value |
| `modules/Roster.lua` | Group membership, pet→owner attribution, role lookup |
| `modules/Aggregator.lua` | GUID join, filtering, ordering |
| `modules/Format.lua` | `NumericRuleFormatter` instances and text assembly |
| `modules/WindowManager.lua` | Window registry, create/delete/duplicate/copy-from |
| `modules/Window.lua` | One window: frame, header, row pool, refresh loop |
| `modules/Row.lua` | Row and cell construction; bar + text + icons |
| `modules/Tooltip.lua` | Cell spell breakdown; name all-stats summary |
| `modules/DrillDown.lua` | Per-player per-stat view and death recap hand-off |
| `modules/Visibility.lua` | Context rules; refuses at the source, per performance-§6 |

## 10. Data flow

```
DAMAGE_METER_* ─► Window:MarkDirty ─► (coalesced ~0.25s) ─► Aggregator:Build
                                                                │
                        Provider:GetColumn(stat) ◄──────────────┤
                        Roster:GetGroup()        ◄──────────────┤
                                                                ▼
                                                        Window:Render
                                                    Row → Cell → bar + text
```

## 11. Testing

Headless suites on the vendored `tests/_kit/` harness, over what is ours: the descriptors and their
degradation stubs, the secret guards, the GUID join, pet folding, sort-mode fallback, the schema's
window-relative path resolution, visibility rules, and the meter-unavailable path. The provider is
tested against a mock `C_DamageMeter` that can return secret-like opaque values, so the "never
inspect a value" rule is provable rather than asserted.

Offline `tests/perf.lua` scenarios: 20-player × 7-column refresh, throttle sensitivity, drill-down
open, full rebuild on roster change, and the mandatory zero-overhead-when-off scenario.

In-game capture uses the wired `LibKa0s-Perf-1.0` harness via `/mm perf`.

## 12. Identity

Folder `MythicMeters` · TOC `MythicMeters.toc` · Title `Ka0s Mythic Meters` · slash `/mm` with a
`/mythicmeters` alias · SavedVariables `MythicMetersDB` + `MythicMetersPerfDB` · MIT · Retail only.
