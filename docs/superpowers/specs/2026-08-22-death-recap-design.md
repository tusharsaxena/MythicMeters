# Death recap — design (issue #1)

Status: drafted 2026-08-22, awaiting approval. Implements
[#1 "A death-recap window for the run"](https://github.com/tusharsaxena/MythicMeters/issues/1),
**re-shaped in the same conversation** from the issue's two-pane window to a drill-down. The
issue's target behaviour is unchanged; only the surface it lands on is.

The whole feature rests on one API the issue did not know existed — `C_DeathRecap` — and on a
probe that took three rounds to find it. §1 records what was measured, because every decision
below is downstream of it and the first two rounds reached the opposite conclusion.

## 1. What the client actually does (measured 2026-08-22)

`/mm debug recap`, three live runs. The probe is `core/Diagnostics.lua`'s `death recap` section
plus `Compat.RecapAPIs` / `RecapMembers` / `CallRecap`.

| Question the issue asked | Measured answer |
|---|---|
| Does `deathRecapID` resolve for a **non-local** player? | **Yes.** Two different non-local players, both resolved in full. |
| Does it resolve for a death from **earlier in the run**? | **Yes.** A death 11 minutes before the read resolved identically to the newest. |
| Is there a reader for the per-event breakdown? | **Yes** — `C_DeathRecap`, a namespace the issue, this addon and the probe's first two rounds all missed. |
| Is `deathTimeSeconds` usable for ordering? | Not on Overall (`-1` on every row). Moot — see §4. |

`C_DeathRecap` carries four members, all plainly enumerable:

| Call | Returns |
|---|---|
| `HasRecapEvents(recapID)` | `true` / `false` — the cheap gate. |
| `GetRecapEvents(recapID)` | An **array of event tables, newest first**, capped at 10 in every sample. |
| `GetRecapMaxHealth(recapID)` | The player's max HP for that death — the denominator for an HP percentage. |
| `GetRecapLink(recapID)` | A chat link, `[You died.]`. Unused by this design; noted in §10. |

One event, verbatim from a live read:

```
amount=327236, avoidable=true, critical=false, crushing=false, currentHP=179516,
deadly=false, destFlags=1298, destGUID=Player-3676-0DF7A8CC, destName=Skyclasher-Area52,
destRaidFlags=-2147483648, event=SPELL_DAMAGE, glancing=false, hideCaster=true,
isOffHand=false, overkill=147720, school=8, sourceFlags=2632,
sourceRaidFlags=-2147483648, spellId=1301253, spellName=Agony of Sethraliss,
spellSchool=8, timestamp=1787381686.521
```

Three properties of that payload drive the design:

* **`currentHP` is HP *before* the hit.** `179516 - 327236 = -147720`, exactly the reported
  `overkill`. The arithmetic closes, so the HP figure on a row is what the player had when the
  hit landed.
* **`timestamp` is absolute epoch**, not session-relative — unlike `deathTimeSeconds`, which is
  seconds-into-session. **The two clocks must never be mixed**; doing so produces plausible
  garbage rather than a visible failure.
* **`sourceName` and `sourceGUID` are sometimes absent**, with `hideCaster = true`. The sample
  above is one such event. The attacker is therefore optional in every render path.

**The event fields arrive PLAIN in combat.** Observed directly in
EllesmereUIDamageMeters' in-combat tooltip, which renders exact percentages and amounts mid-pull.
§6 explains why this design still does not depend on that.

## 2. Decisions taken

| Question | Answer |
|---|---|
| Two-pane window, or drill-down? | **Drill-down.** No new window type, no `WINDOW_TEMPLATE` migration, no second scroll surface. |
| What does a Deaths click do? | Enters a drill-down listing that player's deaths. It **stops** opening Blizzard's recap frame — that dead-end is what the issue opens with. |
| What labels a death row? | Name column: **`Death N`**, numbered chronologically. Deaths cell: **wall-clock `HH:MM:SS`** of the death. |
| Bar on a death row? | **Full.** A death is not a quantity; the bar is the row's backing, not a measure. |
| Where does the event breakdown live? | The **tooltip** of a hovered death row. No third drill-down level. |
| Tooltip columns | Time · icon · spell *(attacker)* · damage taken · HP % remaining. |
| Tooltip order | **Oldest first**, so the killing blow is the last line. Reverses the API's order. |
| HP % when the values are secret | Bar still drawn (engine divides); the **text** percentage is omitted. See §6. |
| Feign deaths | **Filtered.** In scope for this change — see §7. |
| Main-window Deaths bar | **No change.** `rescaleCounted` already scales it to the highest death count. |

## 3. Files

| File | Change |
|---|---|
| `core/Compat.lua` | Three shims: `HasRecapEvents`, `GetRecapEvents`, `GetRecapMaxHealth`. Guarded, nil-degrading. |
| `modules/Provider.lua` | `Provider.GetRecap(recapID)` — the one reader, memoized. Memo dropped on the same messages that drop the availability memo. |
| `modules/Aggregator.lua` | Keep **every** recap id per row (`row.deaths`), not only the first. Feign filter on the Deaths walk. |
| `modules/DrillDown.lua` | A second view kind, `deaths`, beside `spells`. `OnCellClick` enters it instead of opening Blizzard's frame. |
| `modules/Row.lua` | A cell may carry `displayText`, which wins over the formatted number. |
| `modules/Tooltip.lua` | A death branch in `SpellTooltip`, rendering the event list through the existing `drawLine`. |
| `core/MythicMeters.lua` | `UNIT_SPELLCAST_SUCCEEDED` onto the bus, for the feign filter. |
| `locales/enUS.lua` | New strings. |
| `tests/test_drilldown.lua`, `test_tooltip.lua`, `test_aggregator.lua`, `test_provider.lua`, `test_compat.lua` | Extended. |

No new module and no new file. The feature is a view kind and a tooltip body.

## 4. The data path

```
C_DeathRecap  ->  core/Compat.lua   (the only namer of the namespace)
              ->  modules/Provider.lua  Provider.GetRecap(recapID)   [memoized]
              ->  modules/DrillDown.lua deathRow()  /  modules/Tooltip.lua
```

`Provider.GetRecap(recapID)` returns `{ events = { ... }, maxHealth = opaque }` or `nil`. Rule R1
holds unchanged: Provider copies, never inspects, and every field travels onward as an opaque
handle.

**The memo is not an optimisation, it is a correctness requirement.** A death that has already
happened never changes, and the drill-down needs one `GetRecapEvents` call **per death** merely to
label the rows — see §5. Without a memo that cost is paid on every refresh pass, four times a
second. The memo is keyed on `recapID` and dropped on `METER_RESET` and `ENTERING_WORLD`,
alongside the availability memo it sits next to.

**Ordering does not need `deathTimeSeconds` at all.** Measured across three runs: recap ids are
identical across Current and Overall, in the same order, and descend monotonically with array
position. Newest-first is structural, which is what the counting fix already relies on. The
issue's note about `-1` on Overall is therefore closed rather than worked around.

## 5. The death drill-down

`DrillDown:Enter(window, row, "Deaths")` builds one row per entry in `row.deaths`:

```
◀  Name3 — Deaths
┌───────────┬────────┬─────┬─────────────┐
│ Player    │ Damage │ ... │ Deaths      │
├───────────┼────────┼─────┼─────────────┤
│ Death 3   │        │     │ ▇ 13:01:06  │
│ Death 2   │        │     │ ▇ 12:49:43  │
│ Death 1   │        │     │ ▇ 12:37:40  │
└───────────┴────────┴─────┴─────────────┘
```

* **Row order is newest first**, matching the grid and the API.
* **`Death N` is numbered chronologically** — `Death 1` is the run's first death, so the list
  counts *down*. The alternative (numbering from the newest) makes "his first death" mean the
  most recent one, which is the opposite of how anyone says it. Reversible in one line if the
  count-down reads worse in practice than it does on paper.
* **The Deaths cell carries `displayText`**, the formatted wall-clock time, and a bar with
  `total == maxAmount` so it draws full. `displayText` is a new, optional cell field; every
  existing cell leaves it nil and formats its number exactly as today.
* **The wall-clock time is the newest event's `timestamp`** in that death's recap, run through
  `date("%H:%M:%S", ...)`. This costs one `GetRecapEvents` per death on entry, memoized
  thereafter.
* **A death whose recap is empty still draws.** `HasRecapEvents` false, or an empty array, gives
  a row labelled `Death N` with `—` in place of a time. Its tooltip says there is nothing behind
  it. A missing recap must not remove a death that the count includes, or the drill-down and the
  cell above it disagree about how many times somebody died.

Clicking a death row does nothing. There is no third level.

## 6. The event tooltip

Hovering a death row calls `Tooltip:SpellTooltip`, which gains a death branch. Rendering goes
through the existing `drawLine(lineIndex, amount, share, value, max, style, label)` — the same
carrier the spell breakdown uses, so fonts, borders, colours and the width machinery are
inherited rather than duplicated.

```
Name3 — died 13:01:06
 [icon]  -45.4s Gust (Merektha)          -36.9K   100%
 [icon]  -35.9s Gale Force               -118.3K  100%
 [icon]  -21.4s Gust (Merektha)          -36.9K    93%
 [icon]   -0.0s Volley       -787.3K (138.1K overkill)  0%
```

| Slot | Content |
|---|---|
| icon | `Compat.GetSpellTexture(spellId)`; a melee fallback where there is none. |
| label | `SetFormattedText("-%.1fs %s (%s)", …)` — seconds before death, spell name, attacker. |
| amount | The damage taken, negative-signed; heals positive. Overkill appended on the killing blow. |
| share | The HP percentage remaining. |
| bar | HP remaining at that event. |

**Time is relative to the death, computed inside the array.** `deathTime` is the newest event's
timestamp; each row shows `timestamp - deathTime`. Both terms come from the same clock, which is
the whole reason §1 flags the two clocks as unmixable.

**The attacker is optional.** Dropped when `hideCaster` is true or `sourceName` is absent, in
which case the label is `SetFormattedText("-%.1fs %s", …)`. Never composed with `..` — a secret
name would raise, and `SetFormattedText` accepts secrets where concatenation does not.

**Heals are kept, not filtered.** `SPELL_HEAL` / `SPELL_PERIODIC_HEAL` render positive and
green; they are why an HP percentage can rise between two rows, and dropping them makes the HP
column look wrong.

### The HP percentage, and why the design does not bet on plain values

The percentage is a division, and dividing a secret is exactly what rule R1 forbids. Two paths,
chosen per event:

```lua
-- plain: divide in Lua, bar runs 0..1
bar:SetMinMaxValues(0, 1);         bar:SetValue(currentHP / maxHealth)
-- secret: hand both over whole, the engine divides
bar:SetMinMaxValues(0, maxHealth); bar:SetValue(currentHP)
```

The text percentage is rendered only on the plain path; on the secret path the share slot is
empty and the bar carries the information alone.

**The fields were measured plain in combat**, so in practice the plain path runs and the
percentage shows mid-pull — which is the behaviour we want. The design still carries the secret
path, because "plain today" is an observation about one build and the cost of being wrong is a
Lua error in the middle of a pull, in the one place a player cannot see it. The same code
produces the observed behaviour either way.

## 7. Feign deaths

`C_DamageMeter` hands a feign a **valid `deathRecapID`**, so a hunter's Feign Death is counted as
a death today. This is a live defect in the shipped Deaths column, independent of this feature,
and it is fixed here because the drill-down would otherwise list a death that never happened.

* `UNIT_SPELLCAST_SUCCEEDED` with `spellID == 5384` records the caster's GUID.
* The Deaths walk in `modules/Aggregator.lua` drops a source whose GUID is in that set.
* An entry clears when the unit is confirmed at 0 HP — a real death after a feign — or when it
  leaves the group, or at segment start.
* `UnitIsFeignDeath` is **not** used: it can stay true through a feign-then-die transition, which
  would hide the real death that followed.

Every input is plain and unrestricted: no combat log, no new data source, nothing that touches
the secret rules. `spellID` is guarded for secrecy before the `==` and the GUID before it is used
as a table key, because a secret key raises on index.

`deathRecapID` itself is filtered to `> 0`, gated behind `Secrets.IsSafeKey` so the comparison
can never meet a secret.

## 8. Degradation

| Condition | Behaviour |
|---|---|
| No `C_DeathRecap` on the client | Deaths click falls through to the ordinary breakdown, exactly as today. |
| `HasRecapEvents` false for one death | Row drawn, time shown as `—`, tooltip says no recap is stored. |
| `GetRecapEvents` raises | Treated as no recap. Every call is wrapped; a refusal is never allowed to reach the render path. |
| Recap arrives while restricted | Bars render, text percentages omitted. See §6. |
| Player has no deaths | The cell is not clickable, as today. |

## 9. Testing

The mock already carries a blank-slate `C_DeathRecap` seam (`mocks.setDeathRecap`) from the probe
work, defaulting to the namespace being **absent** so the degraded path is the default rather
than an afterthought.

Cases that must exist, each red before its fix:

* Every recap id survives the aggregator, not just the newest.
* A feigned GUID is dropped from the Deaths count; a real death after a feign is **not**.
* `Provider.GetRecap` is memoized, and the memo is dropped on reset.
* A death row's cell renders `displayText`, and every other cell still renders its number.
* A death with no recap still produces a row.
* The tooltip reverses the API order and computes time against the newest event.
* A secret `currentHP` renders a bar and no percentage; a plain one renders both.
* An absent `sourceName` renders the label without the attacker clause.
* Nothing in the path concatenates a possibly-secret string.

## 10. Follow-ups, not in scope

* **`GetRecapLink`** returns a chat link (`[You died.]`). A natural fit for `modules/Export.lua`'s
  Print to Chat, and out of scope here.
* **The two-pane window** the issue originally described. This design deliberately does not
  preclude it: the death list and the event list are separately addressable, so a later window
  type can render both side by side without redoing the data path.
* **The enemy-damage-taken window type**, which the issue suggested landing alongside. Now
  unrelated, since no `WINDOW_TEMPLATE` change is needed here.
* **The richer event fields** — `avoidable`, `critical`, `school`, `deadly` — are read and
  discarded. Avoidable damage in a recap is a plausible later refinement.
