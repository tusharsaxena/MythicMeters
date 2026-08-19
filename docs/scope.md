# Scope

What Ka0s Mythic Meters is, what is in scope, and what is deliberately not. This doc records the
*boundary* decisions, so a fresh contributor can tell whether a feature request is in or out without
re-litigating it — and, for the two entries that matter most, so nobody re-proposes something the
data source cannot express.

## What it is

A single-frame, multi-column group meter for Retail (Midnight, 12.x). One row per group member, one
column per statistic, each cell a `StatusBar` with its text on it.

Every other meter shows one statistic per window. Answering "who kicked, who dispelled, who stood in
things, who died" means four windows or four mode switches. Mythic Meters shows all of them as
columns of one grid.

**Every number comes from Blizzard's built-in damage meter through `C_DamageMeter`.** The addon never
parses the combat log, never maintains its own event accumulator, and never persists a number. That
is the single largest scope decision in the project and everything below follows from it.

Identity: folder `MythicMeters` · TOC `MythicMeters.toc` · display name `Ka0s Mythic Meters` ·
`/mm` with a `/mythicmeters` alias · SavedVariables `MythicMetersDB` + `MythicMetersPerfDB` · MIT ·
Retail only · English only.

## In scope

- **Nine statistics**, catalogued in `core/Constants.lua`: Damage, Healing, Absorbs, Interrupts,
  Dispels, Damage Taken, Avoidable Damage, Deaths, Enemy Damage Taken. Six are enabled on a new
  window; adding a tenth is one row in that catalog and nothing else.
- **Multiple independent windows.** A window is an instance, not a singleton — there are no global
  display settings. `frame`, `header`, `rows`, `bars`, `text`, `icons`, `tooltip`, `visibility`,
  `columns` and `data` all live inside one window's config, which is what makes multi-window and
  copy-settings-from cheap: a copy is a deep table copy, optionally filtered to one group.
- **Copy settings from**, with a group filter — copying one window's columns onto another while
  leaving its position and visibility rules alone is the actual request behind the feature.
- **Current vs Overall sessions**, per window, plus the historical session list the client keeps.
- **Three sort modes** — value, provider order, roster order — with the freeze described in
  [data-flow.md](data-flow.md#5-the-three-sort-modes-and-the-freeze).
- **Tooltips**: a per-cell spell breakdown, and an all-statistics summary on a player's name that
  deliberately includes the columns the window is *not* showing.
- **Cell drill-down** into a player's per-spell breakdown, rendered through the same row path as the
  grid, plus a hand-off to Blizzard's own death recap from the Deaths column.
- **Pet folding** into owners, best-effort — see the caveat below.
- **A thirteen-page settings panel** driven by one 99-row schema, with full `/mm` CLI parity for every
  schema-shaped operation.
- **Visibility rules** per window: dungeon, raid, arena and battleground on by default, open world
  off, plus hide-when-solo and hide-in-vehicle.
- **AceDB profiles**, all characters starting on the shared `"Default"` profile.
- **Preview mode** and an unlock/drag cycle, so a window can be laid out at a target dummy.
- **A minimap button** and LDB launcher (left-click toggles the windows, right-click opens settings).
- **A perf harness** (`/mm perf`) and an on-screen debug console (`/mm debug`), both LibKa0s's.

## Deferred: scoring

A weighted score across damage, healing, kicks and dispels — "who actually carried this key" — is the
most obvious feature this addon does not have. It is deferred rather than declined, and the reason is
structural rather than a matter of effort.

**A weighted score is arithmetic over meter values, so it cannot be computed in combat at all.**

While the `Combat` addon restriction is active, `C_DamageMeter`'s numeric returns come back to
tainted code — which is all of ours — as **secret values**. Tainted code may not do arithmetic on
one. Not multiply by a weight, not sum across four columns, not divide by a group total, not compare
two scores to rank them. Every one of those raises an immediate Lua error, and it raises in the
middle of a pull, in every window, four times a second.

There is no escape hatch for it. There *is* one for formatting — `NumericRuleFormatter:FormatNumber`
performs division and rounding natively and accepts secrets, which is the only reason "12.4M" is
legal at all (see [data-flow.md](data-flow.md#6-the-formatter)). That hatch **renders; it does not
sum**. The same asymmetry is what forces pet folding to drop a pet's row rather than add it to its
owner's while restricted.

So a scoring feature can land in exactly two shapes, and neither is a small change to the current
data layer:

1. **Out of combat / post-run.** Between packs in a key the restriction is inactive and values are
   plain numbers, so a score computed at the end of a run — or between pulls — is ordinary Lua. This
   is the likely shape.
2. **Expressed through `C_CurveUtil` curve objects**, which evaluate natively the way the numeric
   formatter formats natively. Whether the available curve surface can express a weighted sum across
   four independent inputs has not been established.

This is recorded now, at v0.1.0, so the data layer is not designed toward an in-combat aggregate it
can never produce — and so the next person to propose it reads this paragraph first.

**What is not the answer:** computing the score anyway and guarding it with `IsRestricted()`. That
produces code which is correct out of combat and a hard error in combat, which is the worst of the
two possible failures — it ships green and breaks in a raid.

## Out of scope

These have been considered and explicitly declined.

- **Parsing the combat log.** `COMBAT_LOG_EVENT_UNFILTERED` is the traditional way to build a meter
  and is the thing this addon exists not to do. Blizzard's meter is already accumulating the same
  numbers, correctly, natively, with no per-event Lua cost; re-deriving them would buy a second set
  of numbers that disagrees with the game's own.
- **An in-window column drag editor.** Every other meter lets you drag a column edge. This one
  deliberately does not, and it is not an effort question: resizing by dragging means reading the
  cell's geometry back (`GetWidth`, `GetLeft`, `GetPoint`), and a cell that has been handed a secret
  value through `SetValue` has secret geometry which propagates to everything anchored to it. That
  read is exactly the one this addon may never perform on a live cell. Confining column management to
  `settings/Columns.lua` removes the hazard rather than guarding against it (rule R3).
- **Bar colors that depend on the value** — "color by rank", "color above threshold", a gradient from
  the column max. All four shipped color modes (class, role, per-statistic, custom) are
  value-independent by necessity: deciding a color from a number requires comparing it, which is
  illegal for the whole of a pull, which is exactly when a meter is read.
- **Persisting meter numbers.** Nothing this addon stores in SavedVariables is a meter value. Holding
  one across time would mean holding a handle whose accessibility changes underneath us, and the
  client already keeps the session history the picker reads.
- **Resetting the meter as part of any refresh path.** `Provider.Reset` exists, is reachable only
  from the Data page's confirmation, and wipes the sessions Blizzard's *own* meter is showing too —
  not just ours. An addon that can silently reset the meter is an addon that will be blamed for a
  lost log.
- **Localization.** English only for the addon's own strings. `locales/enUS.lua` carries the mandated
  key-is-the-string metatable fallback and the file is structured for a translator to copy, so the
  plumbing exists — but no second locale ships and none is planned.

  This is **not** a license to be locale-*dependent*, which is a different thing. Nothing persisted
  or compared is derived from a localized string: stat keys are the English enum names, the visibility
  contexts are unlocalized tokens, and `Visibility.ShouldShow`'s second return — which `/mm status`
  prints and the tests assert on — is a stable token by design.
- **Classic support.** A single `## Interface` line, targeting Midnight. `C_DamageMeter` does not
  exist on any Classic client, so there is nothing to read.
- **A private tooltip frame.** `GameTooltip` costs us the ability to style it and buys every addon
  that hooks it, the player's tooltip skin, and the automatic repositioning that keeps a tooltip on
  screen.
- **Dps and Hps as separate columns.** `Enum.DamageMeterType.Dps` and `.Hps` are never queried:
  `amountPerSecond` ships on the same source row as `totalAmount`, so one `DamageDone` read fills
  both halves of the Damage column. A separate Dps column would be a second session read for a number
  already in hand.
- **A shipped bar texture.** The addon ships one font (JetBrains Mono, OFL — a meter is a grid of
  numbers, and proportional digits make a column shiver as it ticks) and no textures. Bars use LSM
  statusbar textures the player already has. A shipped texture is one more file to license and one
  more name to collide in a shared registry, in exchange for a look the player can pick anyway.

## Known caveats, not scope decisions

Two behaviors look like missing features and are documented limitations of the data source.

**Pet attribution is best-effort.** The API exposes `sourceGUID` and `classification` but no explicit
owner link, so `modules/Roster.lua` matches pets to owners by asking `UnitGUID` for each member's pet
unit. That is exact for what it covers — `playerpet`, `partyNpet`, `raidNpet` — and covers nothing
else: guardians, totems, temporary summons, a second pet, or a pet whose owner is out of unit-API
range at build time. An unattributable ally — a guardian, a totem, a second pet — is shown as **its own row under its own
name** rather than dropped or folded into a guessed owner. A row that names itself is not the failure
the drop rule was written for: that rule is about one player's numbers appearing under another
player's *name*, and this row makes no claim about an owner. Enemies are still refused, on an
explicit `sourceDisplayType == Ally` test.

**Percentage text slots go quiet in combat.** A percentage is a division. `modules/Aggregator.lua`
computes it once per cell when the operands are accessible and answers `nil` when they are not —
which is most of a pull — and `nil` means "cannot be known right now", never "zero percent". A column
configured to show percentages simply renders no text while restricted. This is why the text slots
default to total and rate.

## The unverified assumption

`provider` sort mode treats the order the API returns `combatSources` in as "sorted by the requested
statistic, descending". **Nothing in Blizzard's documentation states that.** It is an assumption taken
from how the built-in meter displays, and it is isolated in `modules/Provider.lua`'s header because
that file is the only place a correction would land — `value` and `roster` modes do not depend on it.
If it proves false in-game, the fix is a sort inside `GetColumn` and no other file changes.
