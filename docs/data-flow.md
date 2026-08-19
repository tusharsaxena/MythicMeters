# Data flow

**Read this before touching the data path.** It traces one number from `C_DamageMeter` to a lit pixel
and states the rules that shape every step of the trip. Those rules are not style preferences: an
operation this document calls forbidden raises an immediate Lua error in the middle of a raid pull,
where nobody can see it and every window is doing it four times a second.

The short version: a meter value is an **opaque handle**. You may store it, pass it, put it in a
table *value*, concatenate it with `..`, `string.format` it, hand it to `StatusBar:SetValue` /
`SetMinMaxValues` / `FontString:SetText`, hand it to the native numeric formatter, and call `type()`
on it. You may test it against `nil`. That is the entire list.

## The pipeline

The diagram from the design spec (§10), with the files that own each hop:

```
DAMAGE_METER_* ─► Window:MarkDirty ─► (coalesced ~0.25s) ─► Aggregator:Build
                                                                │
                        Provider:GetColumn(stat) ◄──────────────┤
                        Roster:GetGroup()        ◄──────────────┤
                                                                ▼
                                                        Window:Render
                                                    Row → Cell → bar + text
```

Expanded, with the guards named:

```
  C_DamageMeter                     core/Compat.lua            (14 guarded shims, no logic)
        │
        ▼
  DAMAGE_METER_CURRENT_SESSION_UPDATED
  DAMAGE_METER_COMBAT_SESSION_UPDATED(type, sessionID)
  DAMAGE_METER_RESET
        │  core/MythicMeters.lua — THE SINGLE GAME-EVENT LISTENER
        │  each handler translates and republishes; none decides anything
        ▼
  MSG.METER_UPDATED / METER_SESSION / METER_RESET        [bucket: meterEvent]
        │
        │  every Window instance's private bus target
        ▼
  WindowProto:MarkDirty()            ── sets one flag, and nothing else ──
        │
        │  WindowProto.onUpdate: accumulate elapsed; below self.throttle, return
        ▼
  WindowProto:Refresh()                                  [bucket: refresh]
        │
        ├─ Provider.IsAvailable()  ──false──► WindowProto:ShowNotice(reason)  ─► done
        ├─ DrillDown:BuildRows(cfg) ──rows──► WindowProto:Render(rows, false, true, title) ─► done
        │
        ▼
  Aggregator.Build(window)                               [bucket: aggregate]
        │
        ├─ per enabled column: Provider.GetColumn(sessionType, statKey)
        │        │                                       [bucket: providerRead]
        │        ├─ NS.Secrets.CanAccessTable(session)   ── refuse ─► reason = "session sealed"
        │        └─ NS.Secrets.SafeIterate(session.combatSources, collectSource)
        │                 └─ fields COPIED, never examined
        │
        ├─ join on sourceGUID          (Roster.IsGroupMember / Roster.OwnerOf)
        ├─ fold pets, or drop them     (Secrets.CanCompare2 decides which)
        ├─ order                       (value → provider, or roster; engine order when restricted)
        ├─ cap                         (Aggregator.ApplyRowLimit)
        └─ derive percent              (the only division, gated)
        │
        ▼
  WindowProto:Render(entries, preview) ──────────────────[bucket: render]
        │
        └─ per drawn row: RowProto:Update(entry, index)  [bucket: renderRow]
                 │
                 ├─ Cell:SetPlayer(entry, sortKey)   name column
                 └─ Cell:SetValue(entry)             one per stat column
                          │
                          ├─ bar:SetMinMaxValues(0, colMax)   ← opaque
                          ├─ bar:SetValue(total)              ← opaque
                          ├─ left:SetText(NS.Format.Number(total, mode))
                          └─ right:SetText(NS.Format.Rate(rate, mode))
```

## 1. The event stream and the coalescing throttle

`core/MythicMeters.lua` registers all seven game events this addon listens to and is the only file
that registers any. Each of the three `DAMAGE_METER_*` handlers does the minimum translation and
republishes onto the closed message bus; none of them reads a value and none of them decides
anything. Keeping the decisions out of there is what lets that section be read as a wiring diagram.

Every consumer of those messages **sets a flag and returns**. That is the whole discipline:

```lua
local function dirty() self:MarkDirty() end
bus:RegisterMessage(MSG.METER_UPDATED, dirty)
```

`modules/Window.lua`'s single `OnUpdate` is the only clock in the file. It accumulates `elapsed`,
returns until `self.throttle` has passed, and only then turns a set flag into one `Refresh`. The
throttle is per-window (`data.throttle`, default 0.25s), cached into an instance field by
`RefreshUpvalues` rather than read back through three table lookups forty times a second, and clamped
to `Constants.THROTTLE_MIN` (0.05) / `THROTTLE_MAX` (2.0). A twenty-second pull that reports two
thousand times still draws eighty times.

Two messages bypass the wait deliberately by setting `self.elapsed = self.throttle`, so the next tick
draws instead of the one a quarter second later: `DRILLDOWN_CHANGED` (a click must not wait) and the
show transition in `RefreshVisibility`.

Three things do **not** go through the throttle, because they change what the window *is* rather than
what it shows:

- `CONFIG_CHANGED` → `ApplyConfig()` → `RefreshVisibility()` → `MarkDirty()`. The payload names a
  `windowId` when the change was window-relative, so a twenty-window profile does not re-apply
  nineteen windows because one was edited.
- `ROSTER_CHANGED` → `RefreshVisibility()` *and* `MarkDirty()`. A window hidden by `hideWhenSolo` has
  no `OnUpdate` running (a hidden frame's script does not fire), so the ladder must be re-run from
  the message or the window can never come back when the player groups up.
- `ZONE_CHANGED` / `ENTERING_WORLD` → `RefreshVisibility()` only.

**Perf suspend cuts higher than the throttle.** `NS.Perf.suspended` is step 0 of `NS.ShouldShow`,
above even the master enable, and `Provider:Suspend()` makes reads answer an empty column and drops
the bus subscriptions — so a suspended capture stops the addon *asking*, not merely stops it drawing.

## 2. Provider's column read

`modules/Provider.lua` is the only caller of `C_DamageMeter` (rule R1), and it never looks at a
value. `Provider.GetColumn(sessionType, statKey)` turns one Blizzard session table into a flat column
the aggregator can join on:

```
{ stat, maxAmount, totalAmount, durationSeconds, reason, failureReason,
  sources = { { guid, creatureID, name, classFilename, specIconID, isLocalPlayer,
                totalAmount, amountPerSecond, deathTimeSeconds, deathRecapID,
                classification, sourceDisplayType, factionGroup }, … } }
```

Two habits are visible in every function there and are the reason it cannot raise:

- **A session table is reached only after `NS.Secrets.CanAccessTable` says so.** A secret table cannot
  be indexed at all, so `session.maxAmount` on an unguarded read is not a wrong answer — it is a
  raise. Each source row is checked again individually: an accessible array can still hold an
  inaccessible entry.
- **`combatSources` and `combatSpells` are walked with `NS.Secrets.SafeIterate`, never with `ipairs`
  and never with `#`.** `SafeIterate` applies no length operator, guards on `canaccesstable` first,
  stops at the first `nil`, bounds itself at 512 iterations, and never inspects the value it passes
  to the callback.

A source is kept when **either** identifier is present — `sourceGUID` **or** `sourceCreatureID`.
Requiring the GUID silently emptied the entire `EnemyDamageTaken` column, because an NPC source
carries a creature id and no player GUID: every enemy failed the guard, and the column then reported
zero sources with `reason = nil`, which reads as "the session was fine and held nothing". A source
carrying neither identifier is still dropped — it can be neither joined, keyed, nor looked up.

Every field is *copied*, never examined. `name` is `ConditionalSecret`; `totalAmount`,
`amountPerSecond` and `deathTimeSeconds` are secret in combat. They land in table **values**, which is
explicitly permitted, and travel onward as opaque handles.

`sourceGUID` was the exception the whole design rested on, and **it does not hold**. The addon
shipped on the reading that a meter source GUID is never secret and is therefore the one field legal
as a table **key**; measured in-game, `C_DamageMeter` hands back a `sourceGUID` that is secret *and*
inaccessible for the whole of a pull:

```
[Aggregator] dropped guid=<secret> secret=true access=false member=false owner=nil
             local=true/false class=WARLOCK/false
```

So mid-pull a source cannot be keyed on, compared, or looked up, and the GUID join — the algorithm in
§3 — has no key to run on. Every guard behaved correctly: `NS.Secrets.IsSafeKey` refused the key, the
aggregator dropped the source, and the window showed "Waiting for combat data" for a whole fight with
a full session sitting behind it. What was wrong was the premise.

What survives is `isLocalPlayer`, which stays plain, so a source that says it is the player is
attributed to the roster's own plain GUID — the source's own claim about itself, not an inference.
`classFilename` stays plain too and is deliberately **not** used for identity: it would name a group
member only when no two of them share a class, and mislabeling one player's numbers with another's
name is a lie the player cannot see, where a dropped row is a visible absence.

The unit API is no safer: it returns secret GUIDs too (a follower dungeon's companion pets), which is
why `modules/Roster.lua` passes every GUID it reads through `NS.Secrets.IsSafeKey` before keying on
one. **Neither source of GUIDs may be assumed plain.**

An empty column carries a **`reason`** — `"suspended"`, `"unknown stat"`, `"unavailable"`,
`"no session"`, `"session sealed"` — because "we may not look" and "there is nothing there" are
different facts and the window says different things about them. `Provider.IsAvailable()` is memoized
and invalidated on `METER_RESET`, `METER_SESSION` and `ENTERING_WORLD`, because it is otherwise asked
once per column per refresh: seven columns at four refreshes a second.

`Enum.DamageMeterType.Dps` and `.Hps` are **never queried**, here or anywhere. `amountPerSecond`
ships on the same source row as `totalAmount`, so one `DamageDone` read fills both halves of the
Damage column.

`Provider.GetSourceDetail` is the exception to the flattening: it hands back Blizzard's own guarded
`sessionSource` table, because its only two callers (`modules/Tooltip.lua`, `modules/DrillDown.lua`)
each walk `combatSpells` through `SafeIterate` to honor their own display cap and neither wants the
list whole. What it *does* do is refuse — `nil` means "meter off, unknown stat, suspended, no such
source, or a session this context may not access", and a caller holding a table may index it.

### The unverified assumption, isolated on purpose

`sources` is returned in exactly the order the API handed over `combatSources`, and `provider` sort
mode treats that order as "sorted by the requested stat, descending". **Nothing in Blizzard's
documentation says that.** It is recorded in `modules/Provider.lua`'s header because that file is the
only place a correction would land: `value` mode orders by the values themselves, `roster` mode by
group position, and neither depends on it. If it proves false in-game the fix is a sort inside
`GetColumn` — legal out of combat, which is the only time `value` mode would have needed it anyway.

## 3. The GUID join

`modules/Aggregator.lua` runs the algorithm in this order:

1. Read one column per enabled stat from the provider.
2. Index every source by `sourceGUID`, where that GUID is plain. It is **not** plain under the
   Combat restriction (see §2); a source unkeyable then is attributed by `isLocalPlayer`, or dropped.
3. Filter to group members (`modules/Roster.lua`) and fold pets into owners.
4. Order, per the window's `sortMode`.
5. Cap to `rows.maxRows`, honoring `rows.alwaysShowSelf`.

The roster half is the other data source, and it is entirely plain: `C_DamageMeter` reports
**sources**, not group members, and carries no owner link and no statement of membership. So
`modules/Roster.lua` builds the group array, the GUID index and the pet→owner map from `UnitGUID` /
`UnitName` / `UnitClass` / `UnitGroupRolesAssigned`, all of which return plain data in combat. That is
the whole reason `roster` sort mode is legal mid-pull when `value` mode is not.

The roster map is rebuilt **lazily** on first read after an invalidation, not eagerly in the event
handler: a raid regroup fires `GROUP_ROSTER_UPDATE` a dozen times a second while nothing is on
screen, and building on demand collapses that to one build per refresh. It lives in
`core/State.lua`'s shared cache alongside the formatter instances, so both drop through one wipe
seam.

Row identity comes from the roster where the roster has it, and from the meter's source row only as
a fallback — `name` off the meter is `ConditionalSecret` and may be opaque mid-pull, while
`UnitName`'s answer is always plain text. `classFilename` and `specIconID` go the other way: both are
`NeverSecret` on the source row, and the meter knows a source's spec when the unit API does not.

`providerIndex` comes from the **sort column** specifically. That is what `provider` mode means — the
order Blizzard returned for the column this window is ordered by, not the order of whichever column
happened to mention this player first. A player who appears in some other column but not the sort one
(a death, with no damage) is parked past every ranked row rather than interleaved. Only the member's
own source sets the position; a pet's index is a position in the *source* list, not the row list.

## 4. Pet folding, and why it is dropped rather than summed

Adding a pet's damage to its owner's is arithmetic on two meter values. Out of combat that is
ordinary Lua. While the Combat restriction is active it raises, and there is **no native escape hatch
for it** the way there is for formatting — `NumericRuleFormatter` renders, it does not sum.

So the behavior is honestly different in the two states, and `Aggregator.foldPet` logs the refusals
once per pass rather than hiding them:

| State | Behavior |
|---|---|
| Unrestricted (`Secrets.CanCompare2` says yes) | The pet's value is summed into the owner's cell. |
| Restricted | The fold does not run at all — it is reached through the owner link, and the owner link is reached through a GUID that is secret. The pet is a **row of its own**, exactly as the meter reported it, and nothing is summed. |

Dropping is chosen over the two alternatives deliberately: a phantom pet row in a group meter looks
like a bug, and a Lua error mid-pull takes the window with it. A low number is a visible, explainable
inaccuracy.

One case is legal in either state and is taken: if the owner has **no cell yet** in that column (a
pet did damage its owner did not), the pet's numbers are adopted wholesale. That is not a sum — and
it is the correct answer, because the owner did that damage, through the pet.

Attribution itself is best-effort. `modules/Roster.lua` builds the owner map by asking `UnitGUID` for
every member's pet unit (`playerpet`, `party3pet`, `raid17pet`). That is *exact* for what it covers
and covers nothing else: guardians, totems, temporary summons, a second pet, or a pet whose owner is
out of range of the unit API at build time. `Roster.OwnerOf` answers `nil` for those, and the
aggregator's contract is to **drop the row, not guess**.

Deferring the scoring feature rests on exactly this fact — see [scope.md](scope.md#deferred-scoring).

## 5. The three sort modes, and identity mode

| Mode | Behavior | Legal in combat? |
|---|---|---|
| `value` (default) | Order by the sort column's numbers, descending | No — falls through |
| `name` | Alphabetical by the row's name, ascending first. What the **Player** header sorts by | No — `name` is `ConditionalSecret`, so it falls through |
| `provider` | Follow the order the API returned `combatSources` in | Yes — iteration needs no comparison |
| `roster` | Group position, then role rank (tank/healer/damager), then name | Yes — every input is plain |

`orderByValue` checks comparability in a **separate pass before `table.sort` runs**, not inside the
comparator. That is the whole trick of the function: a comparator that discovers an illegal
comparison halfway through has already raised, and there is no way to unwind a partially sorted
array. One linear pass over `Secrets.CanCompare` turns a possible mid-sort error into a clean "no".

`orderByName` is guarded exactly like `orderByValue` and for the same reason: `name` is
`ConditionalSecret`, `<` on a secret raises, and `tostring()` does not launder one — it survives it.
So comparability is proved in a pass before `table.sort` is entered. A row with **no name at all**
sorts last in both directions, which is deliberately *not* the missing-number rule below: an empty
string is not a position in the alphabet, so there is nothing for it to be least of.

**A missing cell counts as zero**, so it flips with the direction like any other figure: last
descending, first ascending. For a contribution column an absence *is* zero — the meter omits a
source row because the player did none of that thing, not because it declined to say — and "sort
ascending by Avoidable" is a question about who took the least, which the people who took none
answer. The genuine "cannot be known" case never reaches this function: a cell left empty for an
ambiguous identity happens only while restricted, where the order is the engine's instead. Two zeros
fall back to `providerIndex`, because `table.sort` is not stable and the pair would otherwise swap
between refreshes.

`orderByRoster`'s name tiebreak is guarded for the same reason. It is reached only by rows *absent*
from the roster — pets, enemies, cross-realm strays — which is exactly the population whose `name`
came from the meter's `ConditionalSecret` `src.name`. `<` on two of those raises, and `tostring()`
does not launder a secret: it survives it. So names are compared only behind `CanCompare2`, and
otherwise the deterministic `providerIndex` escape is used.

### Identity mode — the grid while the GUID is secret

The table above describes the **unrestricted** build. Under the Combat restriction none of it runs,
because `sourceGUID` is secret: there is no key to join the columns on, nothing to sort, and nothing
for a row to be identified by. `Aggregator.Build` chooses between two builds once per pass, on
`Secrets.IsRestricted()`, so a grid is never half one shape and half the other.

Identity mode is built out of the fields Blizzard annotates `NeverSecret`:

- The **sort column's** `combatSources` supplies the ranked rows, in the order the engine returned
  them — which *is* the ranking for that column. Row identity is its position, `"rank_<n>"`, a plain
  string the row pool and the drill-down can hold. The local player is the exception: `isLocalPlayer`
  is plain and `UnitGUID("player")` is not secret, so their row keeps the roster's own GUID, name and
  role.
- **Every other column** is read on its own and correlated back to those rows by an identity key of
  `classFilename .. specIconID .. isLocalPlayer`.
- **The rows are the UNION of every column, not just the sort one.** A source some other column knows
  and no row yet stands for gets its own row, keyed `"ident:<key>"` and parked past every ranked row
  in first-seen order — the same place the GUID join parks a player who appears in one column but not
  the sort one. Without it the grid was whatever the sort column happened to mention, so a healer who
  did no damage and a player whose only contribution was one interrupt were missing for the whole of
  a pull and reappeared the instant it ended. An **ambiguous** key gets no invented row: no column
  could ever fill it, and an always-empty line is noise.
- A key appearing **twice** — two players of one class *and* one spec — is ambiguous, and every
  secondary cell for it is left **empty**. `/mm debug on` prints one `identity` line per pass —
  `rows= keys= collisions= filled=/` — which separates the two reasons a secondary column can come
  out blank: ambiguity doing its job, or keys not matching between columns at all. `kept.ambiguous` says so and the header line reports it.
  Class alone identifies nobody in a raid; class plus spec plus "is it me" identifies almost
  everybody almost always, and the exceptions are detected rather than guessed at. An empty cell is a
  visible absence; a mislabeled number is a lie the player cannot see.
- Enemies are filtered by the plain `sourceDisplayType`, because the roster cannot answer for a
  source it cannot key on.
- **Pets are rows**, not folded contributions. The fold needs the owner link, the owner link needs a
  GUID, and there is none — so a pet appears as the source Blizzard reports, with its own name and
  numbers, and nothing is summed.

**The sort freeze is retired.** It cached each successful value-sort as a `guid → position` map and
reapplied it for the duration of a pull, so rows would not jump — keyed, that is, on the one field
that is secret exactly when the freeze was needed, and therefore never applicable to a single
mid-pull row. The engine's ranking replaces it and is strictly better: live rather than a snapshot of
the pull's first frame, and free of any comparison of ours. `ADDON_RESTRICTION_STATE_CHANGED` is no
longer listened for in `modules/Aggregator.lua`; `modules/Window.lua` still redraws on it.

The restriction keys off **`Combat`, not `ChallengeMode`**. Between packs in a key the values and the
GUIDs are fully readable, so the exact join runs for most of a dungeon run and identity mode covers
the pulls.

### `percent` — the one derived number

`Aggregator.percentOf` is the only place other than the pet fold where this addon does arithmetic on
meter data, and it is gated the same way: an inaccessible operand yields **`nil`**, which means
"cannot be known right now" and never "zero percent". It is computed once per surviving cell per
pass, after the row cap, so nothing is divided for rows nobody will see. It reaches the cell as a
**plain number** — every other figure on a cell is opaque.

The consequence is worth stating plainly, because it looks like a bug and is not: **a column
configured to show percentages goes quiet in combat.** That is why the text slots default to
total/rate.

## 6. The formatter

Abbreviating `12400000` to `"12.4M"` is a division and a rounding. Both are arithmetic, and every
number this addon displays is secret for the whole of a pull — so "abbreviate this number" is not an
edge case here, it is the main path.

`modules/Format.lua` owns the one legal escape hatch: `C_StringUtil.CreateNumericRuleFormatter()`,
whose `:FormatNumber(n)` performs that arithmetic **natively** and accepts secrets. Instances are
built lazily, cached in `State.Cache("Format")` (as `false` on failure, so a client without the API
does not pay a fresh failing call per cell per refresh — 280 a frame at seven columns and forty
rows), and dropped on `CONFIG_CHANGED` / `PROFILE_CHANGED`.

Nothing in that file divides a meter value. Not once, not behind a guard, not "only out of combat" —
a Lua division that is correct out of combat and a hard error in combat is the worst of the two
possible failures, because it ships green and breaks in a raid. `tonumber()` appears nowhere either:
coercing a value is an inspection, and this is not `core/Secrets.lua`.

The degradation ladder for the abbreviated form is three deep, and each rung is a real client:

1. `NumericRuleFormatter` — 12.x, the intended path.
2. `AbbreviateNumbers` — Blizzard's own global, which also accepts secrets.
3. `NS.SafeToString` — LibKa0s's secret-safe renderer, which answers `"<secret>"`. Ugly, never wrong.

| Function | Notes |
|---|---|
| `Format.Number(v, mode)` | `"full"` skips the formatter entirely (its job is abbreviation) and only renders. |
| `Format.Rate(v, mode)` | **No suffix** — the bare number, same as `Number`. The column header already names the statistic, and restating it per cell spent most of a column's width on two characters. Kept as its own entry point because the catalog's `isRate` flag selects it and a future rate-specific style has one home. |
| `Format.Duration(seconds)` | Two paths. Accessible → real mm:ss arithmetic. Inaccessible → the native formatter plus a unit suffix, which reads worse and cannot raise. |
| `Format.Percent(value, total?, decimals?)` | Dual shape: a pre-divided share, or a ratio it divides itself. Either way it answers **empty** rather than approximating when an operand is inaccessible. |

**A return value from this file is "a string, or something `SetText` will take".** Those are the same
thing to a widget and different things to Lua — the formatter may hand back a *secret string*. A
caller may `SetText` it and concatenate it, and may do nothing else with it.

`NS.Format` is a **callable table**: indexing it reaches the number formatter, calling it forwards to
LibKa0s's chat printer, because both wanted the same name. `NS.Numbers` and `NS.NumberFormat` are the
same table under two more names. Nothing in the addon asserts `type(NS.Format) == "function"`; a test
that wants the printer should assert it is *callable*.

## 7. The widget setters

`modules/Row.lua` is written as if it did not know what a number is. The only test it applies to a
value is `== nil` — legal on a non-boolean secret, and how "this player has no dispels" is told apart
from "this player dispelled a secret number of times".

```lua
if colMax == nil then bar:SetMinMaxValues(0, 1) else bar:SetMinMaxValues(0, colMax) end
bar:SetValue(total == nil and 0 or total)
```

Note the shape. `colMax or 1` and `total or 0` are both **truth tests**, and a truth test on a secret
raises. `== nil` is the one comparison permitted.

Text goes out through `renderValue` / `renderPercent`, which resolve `modules/Format.lua` by *shape*
(`type(f) == "table" and f.Number`) rather than by name, so the callable-table collision above cannot
break them. `cellFigures` reads both row shapes the addon produces — the aggregator's
`cells[key] = { total, rate, maxAmount, percent }` and the drill-down's `values[key] = { total,
rate }` with the max on the row — so the render path has no branch in it.

Bar color never depends on a value. `class` (the default) reads `classFilename`, `role` reads the
roster's role, `stat` reads the column, `custom` reads the setting. All four are plain, which is what
makes them keep working at the height of a pull. **A "color by rank" or "color above threshold" mode
is not a missing feature — it is a thing this data source cannot express while a pull is running.**

### Rule R3: geometry is computed, never read back

`StatusBar:SetValue(secret)` marks that frame `HasSecretValues`, which makes its **anchoring and
position data secret too**, and that propagates to anything anchored to it. So:

- There is not one `GetWidth` / `GetHeight` / `GetLeft` / `GetPoint` call in `modules/Row.lua`.
- `WindowProto:BuildLayout()` computes every coordinate the window will use from **config only** —
  padding, row height, spacing, each column's `x` and `width`, and `maxRows` from the frame height.
  Recomputed on a settings change, never on a refresh.
- `Row.OffsetFor(layout, index)` is the same rule on the vertical axis, published so the window can
  place a row without restating it and so a test can assert the arithmetic without a frame.
- Cell borders are four 1px **textures**, not a `BackdropTemplate` child frame. A frame anchored to
  the bar would inherit its secretness; a texture is a leaf.
- The two `FontString`s are anchored to the bar's edges, which is safe in the one direction that
  matters — secretness travels from a frame to whatever is anchored *to* it, and these are leaves.

**The anchor frame.** Dragging and resizing genuinely need "where did the user just put this" (a
`GetPoint`) and "how big did they make it" (a `GetWidth`). `modules/Window.lua` keeps those two
questions on `inst.anchor`: a bare, empty, invisible `Frame` parented to `UIParent` with no children,
no textures and no cells. The visible window is anchored `TOPLEFT` and `BOTTOMRIGHT` to it, so it
inherits position and size. Secretness travels downstream, and the anchor is upstream of everything —
so drag and resize act on the anchor, the two getters read the anchor, and the visible window is
never asked a question about itself. `SaveSize` goes further still and takes the size from the
arguments `OnSizeChanged` was *handed* rather than from a getter, keeping the rule identical on both
axes even though the anchor would in fact be safe to ask.

This is also why **column management is settings-panel only** and there is no in-window drag editor.
A drag editor is built out of exactly the read this addon may never perform on a live cell. Confining
it to `settings/Columns.lua` removes the hazard rather than guarding against it.

### The header line

`WindowProto:UpdateHeaderText` folds the session name, the duration, the group total and the
restricted-grid notice into one string with `..` and an `add()` helper — **never `table.concat`**. Two of those
pieces come out of `NS.Format` having been built from a secret, and a formatted secret is itself
secret. `..` is explicitly legal on one; `table.concat` is the single string operation that *raises*
on one — it is literally the probe LibKa0s uses to detect a secret at all.

Emptiness is decided from the **plain input**, not the formatted output: `if seconds ~= nil then
add(F.Duration(seconds))`, because the formatted string is a secret that may be neither truth-tested
nor compared to `""`. The group total is read off `self.aggregate.sortTotal`, parked there by the
render pass, rather than from a fresh `Provider.GetColumn` — the same reason `percent` moved into the
aggregator.

## 8. The two side paths

**Tooltips** (`modules/Tooltip.lua`) look like the safest place in a meter and are the most dangerous,
because a tooltip is where the instinct is to say "just show the top five spells" and "put the total
at the bottom". A top-N is a *comparison* and a total is *arithmetic*. So: spells are collected
through `SafeIterate` (up to 64, deliberately more than any sane `maxSpells`, because sorting only
the first ten the API happened to return would produce a "top 5" that is nothing of the sort), sorted
**only** when a pre-pass proves every amount comparable, and the "and N more" line uses
`Secrets.SafeCount` — which obtains a length without the `#` operator. A missing `totalAmount` fails
the pre-pass too: `CanAccess(nil)` is `true`, so a row with no amount would sail through and raise
inside the comparator with "attempt to compare nil with number". Booleans off the API (`isAvoidable`,
`isDeadly`) go through `plainTruth`, because a boolean test on a *secret boolean* raises.

**Drill-down** (`modules/DrillDown.lua`) builds no row frames at all. `BuildRows` returns rows in the
same shape the aggregator produces, and `modules/Window.lua` feeds them to the same row pool and the
same cell path — so everything the player configured about rows, bars, text and fonts applies for
free. A spell is a "row" whose synthesized `guid` is `"spell:<id>"` (a plain string, so the pool can
key on it). It does **not** sort: a live view that reshuffled under the cursor the instant the
restriction lifted is worse than an order the player can learn.

Three things follow from a breakdown row being a **spell** rather than a player, and all three were
wrong until they were stated: hovering any cell of it shows the *client's* spell tooltip rather than
either of this addon's, because a spell has no per-stat breakdown and no cross-column summary — both
rendered honestly and uselessly; a left-click does nothing, because it used to ask the provider for a
breakdown of a spell and render an empty window; and leaving is a **right-click on any row**, which
replaced a Back button that cost a row of height and pushed the last row out through the bottom of
the frame.

Its title is the trap worth knowing about. `DrillDown.Title` builds its string with `string.format`
from `view.name`, which is `ConditionalSecret` — and `string.format` on a secret returns a **secret
string**, which poisons `if title then`, `title ~= ""`, `#title` and using it as a table key. So the
title travels to a `SetText` and nowhere else, and "is this window drilled in" is answered by
`DrillDown.IsActive(window)`, a plain boolean derived from the presence of the view table.
`WindowProto:Refresh` branches on the returned `drillRows` table and carries the title alongside as
text only.

## 9. The target cross-reference, and the one place refusal beats degradation

`modules/Targets.lua` answers "which enemies did this player hit", and it is the only place in the
addon where the display **withholds information rather than decoration** while the restriction is
active. Worth understanding before touching it, because the reasoning inverts the rule everywhere
else.

**It is a join, not a read.** A `DamageDone` source knows its spells and nothing about who they hit.
The information is filed under the other party: an `EnemyDamageTaken` source is one enemy, its
`combatSpells` are the spells that hit it, and each carries `combatSpellDetails.unitName` — the
player who cast it. So the walk is enemy-first:

```
Provider.GetColumn(session, "EnemyDamageTaken")     -- enumerate the enemies
  └─ per enemy: Provider.GetSourceDetail(session, "EnemyDamageTaken", guid, creatureID)
       └─ SafeIterate(combatSpells)
            └─ keep spell where combatSpellDetails.unitName == the hovered player
                 └─ totals[enemy] += spell.totalAmount
```

**The GUID is dropped whenever it is secret**, and that is the line the whole section depends on
mid-pull. `sourceGUID` is secret and inaccessible for the entire of a pull (§2), and it is the
*first* argument to `GetSourceDetail` — so passing it resolves nothing and the section silently
disappears for a whole fight. `sourceCreatureID` is a plain number, is never secret, and identifies
an enemy exactly as well, so a GUID that fails `Secrets.IsSafeKey` is replaced with `nil` and the
lookup falls to the creature ID.

**Why the section vanishes instead of degrading.** Everywhere else a restricted value travels on as
an opaque handle and the display loses a bar or a percentage. That escape does not exist here,
because the number does not exist in the API: one enemy's damage from one player is a **sum**, and a
sum of secrets raises. So the answer is binary and is decided *before* any arithmetic — every amount
is checked with `CanAccess` as it is collected, and the first inaccessible one abandons the whole
build and returns `nil`. Skipping the unreadable rows and carrying on would produce a total summed
from whatever happened to be visible: wrong, plausible, and in the direction of "this enemy took less
than it did". An absent section is a visible absence; an under-reported one is a lie the player
cannot see.

**Both names are normalized before they are compared.** They arrive in different shapes: a combat
source's `name` is bare, and a spell's `combatSpellDetails.unitName` is realm-qualified for anyone
from another realm. Compared as they arrive, same-realm players matched and cross-realm players
silently did not — which reads in game as "targets work on every other row" and is really "targets
work for everyone on your own realm". Splitting at the first hyphen is exact rather than heuristic
here, because both sides are *player* names and a player name cannot contain one; `modules/Row.lua`
gates the same strip on the GUID precisely because an NPC like "Crenna Earth-Daughter" keeps hers.
The accepted cost is that two players sharing a name on different realms merge into one row.

An unreadable *caster name* is different and is skipped rather than fatal — a spell nobody can be
attributed to belongs to nobody rather than to everybody, so dropping it costs one spell's
contribution instead of corrupting a number that is still on screen.

**One walk builds every player, and the result is cached.** The walk visits every spell of every
enemy regardless; answering for a single player then discards every other caster — 100% of the work
for a fifth of the result in a party, a twentieth in a raid. So `buildMap` keeps them all and
`ForPlayer` is a lookup with a per-call trim. Measured offline against this repo: a hover is `1 + E`
provider calls (24 at 23 enemies, 65 at `ENEMY_LIMIT`) against **9 for a full 20-player, 7-column
refresh** — and a cursor swept down a five-row Damage column fell from 120 meter calls to 24.

The cache lives in `State.Cache("Targets")`, keyed on `(sessionType, sessionID)`. **Why that is
legal here** when the addon does not hold meter values across time, and both halves are specific to
this file rather than general permission: the section refuses to compute mid-pull at all, so the
session it caches is one nothing is writing to; and what it stores is *our own sum* of numbers
already proven readable — a plain Lua number, never an opaque handle.

**Invalidation is wider than `modules/Aggregator.lua`'s, and has to be.** The key is the session's
*identity*, and for the live Current or Overall session that identity never changes while its
contents do — so identity alone cannot detect staleness. Four messages do: `METER_RESET`,
`METER_SESSION`, `METER_UPDATED` and `PROFILE_CHANGED`. `METER_UPDATED` is the one that closes the
hole; without it a map built after one fight would still be showing after the next. It fires only
while fighting, when no map can exist anyway, so subscribing costs two nil assignments a tick.
Over-invalidating costs a rebuild; under-invalidating shows the previous pull's numbers under this
pull's heading, and looks entirely correct.

A refusal is never stored, and could not pin the section shut even if it were: a nil map is
re-derived on the next call, because the cache lookup answers nil for "no key" and "key present, map
nil" alike.

## Where the guards live

If you are adding to the data path, these are the only files that may know anything about a value:

| Question | Ask | Never |
|---|---|---|
| Is the restriction active? | `NS.Secrets.IsRestricted()` | `InCombatLockdown()` |
| What state is it in? | `NS.Secrets.GetRestrictionState()` — `Activating` is the last legal read | a boolean |
| May I compare these two? | `NS.Secrets.CanCompare2(a, b)` | `a < b` and hope |
| May I walk this array? | `NS.Secrets.SafeIterate(t, fn)` | `ipairs`, `#t` |
| How long is it? | `NS.Secrets.SafeCount(t)` — returns `nil`, not `0`, when it cannot see | `#t` |
| Can I print this? | `NS.IsConcatSafe(v)` / `NS.SafeToString(v)` | `tostring(v)` into `table.concat` |
| Can I abbreviate this? | `NS.Format.Number(v, mode)` | any division |

`core/State.lua`'s `restricted` flag is a **mirror** for the render path, not an authority: anything
that must be right rather than fast asks `NS.Secrets.IsRestricted()` directly.
