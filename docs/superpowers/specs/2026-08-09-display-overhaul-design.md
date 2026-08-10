# Display overhaul — design

**Date:** 2026-08-09
**Status:** approved, building

Eight changes to how Ka0s Mythic Meters draws a row, plus a segment selector. The reference is the
player's gold-standard screenshot: a class-colored row, `1.41M | 83.2K`, no `/s`, uniform columns.

## 1. Numbers (items 1a, 1b, 2)

Abbreviation is arithmetic and arithmetic on a secret raises, so every number keeps going through
`NS.Format.Number` -> `NumericRuleFormatter`, which does it natively. `window.text.numberFormat`
already defaults to `abbreviated`, so the abbreviated form is already the shipped path.

**The only change is the suffix.** `Format.Rate` returns the bare formatted number; `rateSuffix()`
and the `L["/s"]` key go away. `Format.Duration`'s `L["s"]` is a different key and stays.

**Decision — native precision is accepted, in and out of combat.** The formatter may answer `1.4M`
where the screenshot shows `1.41M`. One code path, identical in and out of combat, is worth more than
matching the reference to a third significant figure — the alternative was a Lua path out of combat
and a native path in it, which changes the numbers' appearance every time a pull starts.

**Avoidable damage needs no code.** It already renders through `Format.Number`, and its catalog entry
carries `isRate = false`, which already leaves its rate slot empty. Item 2 is satisfied by item 1.

**Risk to verify in-game:** if numbers currently render unabbreviated, both `C_StringUtil` and
`AbbreviateNumbers` are failing and the diagnosis is different. This is a smoke-test line, not an
assumption.

## 2. The name column (items 3, 5, 6)

`Cell:SetPlayer` stops calling `SetValue` altogether. That is not only cosmetic: handing a widget a
secret marks it `HasSecretValues` and makes its anchoring data secret too, so dropping the call
removes a frame from that set. The bar is hidden; the name text carries the identity instead, colored
from `RAID_CLASS_COLORS[classFilename]` and falling back to white where the class is unknown.

**Realm strip and truncation are string operations**, so both are gated on `NS.IsConcatSafe` — the
same probe `nameText` already uses. A plain name is stripped of `-Realm` and capped; a secret name
passes through untouched and uncapped, because inspecting it is exactly what rule R1 forbids.

New schema row `window.text.maxNameLength`, default 20, `0` = no cap. 20 clears every name in the
reference screenshot, including the follower-dungeon NPCs that exceed WoW's 12-character player-name
limit.

## 3. Uniform column widths (item 4)

Widths are baked into the profile when a window is created, so a catalog change alone would not reach
an existing window.

- Every stat's `defaultWidth` becomes **92** (today's Damage width).
- `NAME_COLUMN_WIDTH` widens to **140** to hold a 20-character name.
- `frame.width` default rises **480 -> 690**: six default columns at 92 plus the name column plus
  gaps no longer fit in 480.
- A **schema migration** rewrites existing columns to the catalog width and existing windows to the
  new frame width. It discards hand-tuned widths, which is acceptable because the feature request is
  precisely "make them all the same".

Per-column width stays in the schema. Uniformity is a default, not a constraint.

## 4. Segment selector (item 7)

`Compat.GetCombatSessionFromID` and `Compat.GetAvailableCombatSessions` already exist and are
currently unreachable. This wires them.

**Threading:** `Provider.GetColumn`, `GetSourceDetail` and `GetSessionDuration` gain an **optional
trailing `sessionID`**. When it is present the read routes to the `FromID` shims; when it is nil
nothing about today's behavior changes. `modules/Provider.lua` remains the only caller of
`C_DamageMeter`. The aggregator threads `pass.sessionID` beside `pass.sessionType`.

**UI:** the header's session label becomes clickable and opens a dropdown listing every available
session — name and duration — above a separator and the two synthetic entries `Current` and
`Overall`.

**Persistence:** the choice is saved to `window.data.sessionID` and survives a reload. A saved ID that
is no longer in `GetAvailableCombatSessions()` falls back to `Current` on the next read, so a stale
pin cannot leave a window silently empty.

## 5. TODO.md (item 8)

Created, with one entry: enemy damage taken should become its own window type rather than a column,
because it describes enemies rather than group members and therefore wants a different row identity.
Moves to GitHub issues later.

## Testing

Every change lands with headless coverage:

- `Format.Rate` no longer appends a suffix (existing assertions in `test_format.lua` and
  `test_row.lua` are updated, not deleted).
- The name cell never calls `SetValue`, and its text is class-colored.
- Realm strip and truncation apply to a plain name and **not** to a simulated secret.
- The migration rewrites an old-shaped profile's widths and frame width.
- `Provider.GetColumn` with a `sessionID` reaches the `FromID` shim; without one it does not.
- A stale saved `sessionID` falls back to `Current`.

Green gate before finishing: `lua tests/run.lua` and `luacheck .` at 0/0.
