# Architecture

Orient-yourself map for **Ka0s Mythic Meters**. A single-frame, multi-column group meter for Retail
(Midnight, 12.x): one row per group member, one column per statistic, each cell a `StatusBar` with a
`FontString` on it. Every number is read from Blizzard's built-in damage meter through
`C_DamageMeter`; the addon never parses the combat log.

This file is the hub. Topic detail lives in `docs/` and is linked from each section — a section here
that outgrows a screen belongs in its topic doc with a summary and a link left behind.

## Overview

Forty-one non-vendored source files: 1 locale, 12 `core/`, 1 `defaults/`, 11 `modules/`, 16 `settings/`.

The addon is built on the **private namespace** WoW hands each file. `core/MythicMeters.lua` calls
`AceAddon-3.0:NewAddon(NS, addonName, …)`, which promotes that table in place — so **`NS` *is* the
addon object**. There is no `_G.MythicMeters` and no rebind. `NS.addon` is published for callers that
want to name "the AceAddon object" without assuming the promotion.

Three things define the shape of everything else:

- **The data source is Blizzard's.** `C_DamageMeter` accumulates the numbers; this addon reads,
  joins, orders and draws them. `modules/Provider.lua` is the only caller, through `core/Compat.lua`'s
  guarded shims — so an 11.x client, or a PTR build missing one function, degrades to a window
  rendering Blizzard's own failure reason rather than erroring at load.
- **Those numbers are secret in combat.** See [Taint notes](#taint-notes). This is the defining
  constraint and it is why the aggregator has two builds rather than one, why the formatter exists,
  and why there is no column drag editor.
- **A window is an instance, not a singleton.** There are no global display settings: `frame`,
  `header`, `rows`, `bars`, `text`, `icons`, `tooltip`, `visibility`, `columns` and `data` all live
  inside one window's own config. That is what makes multi-window and copy-settings-from cheap — a
  copy is a deep table copy, optionally filtered to one group — and it is why the profile itself is
  nearly empty: an array of windows, an id counter, and two addon-wide toggles.

Nine statistics are catalogued in `core/Constants.lua`; six ship enabled on a new window (Damage,
Healing, Interrupts, Dispels, Avoidable Damage, Deaths). Adding a tenth is one row in that catalog —
the column editor, the defaults, the aggregator's read loop, the sort-column dropdown and the tooltip
header all read the same table.

Chrome comes from LibKa0s-Core-1.0's shared `SKIN` / `ApplySkin`, never a private lookalike, so the
meter window, the debug console and the perf step panel wear the same Ka0s edge as every sibling
addon. Five LibKa0s seams are adopted — Core, Perf, DebugLog, Slash, Options — one setup file each,
and every one of them degrades to a stub rather than erroring when `libs/LibKa0s` is absent, all five
explaining the absence through the one shared cause clause `NS.LIBKA0S_MISSING`.

Full scope boundaries, including the two features that are structurally impossible rather than merely
unbuilt, in [scope.md](scope.md).

## Module map

Every file, what it owns, what it publishes, what it consumes, plus TOC load order and the AceAddon
lifecycle: **[module-map.md](module-map.md)**. The shape at a glance:

| Layer | Files | Responsibility |
|---|---|---|
| `locales/` | `enUS.lua` | `NS.L`, with the key-is-the-string fallback. Loads first. |
| `core/` boundary | `Compat.lua` | All 15 cross-patch shims, including the eight `C_DamageMeter` reads. No logic. |
| `core/` values | `Constants.lua`, `Namespace.lua`, `State.lua` | The stat catalog, the bus catalog, identity, session-only flags and the shared cache. |
| `core/` the rule | `Secrets.lua` | **The only file that inspects a meter value.** |
| `core/` seams | `CoreSetup`, `PerfSetup`, `DebugLogSetup`, `LSMPatch` | LibKa0s wiring and shipped-media registration. |
| `core/` runtime | `MythicMeters.lua`, `Database.lua` | The single game-event listener and the show ladder; AceDB and migrations. |
| `defaults/` | `Profile.lua` | The window template. The only place a profile default is hardcoded. |
| `modules/` data | `Provider`, `Roster`, `Aggregator`, `Format` | Read → join → order → render as text. |
| `modules/` display | `WindowManager`, `Window`, `Row`, `Targets`, `Tooltip`, `DrillDown`, `Visibility`, `Minimap` | The registry, one window, one row, the enemy cross-reference, the two hover surfaces, the breakdown, the context predicate, the launcher. |
| `settings/` | `Schema`, `Slash`, `OptionsSetup` + 13 pages | One schema drives the panel, the CLI and the defaults reset. |

The path a number takes through those layers — the throttle, the GUID join, pet folding, the sort
identity build, the formatter and the widget setters — is **[data-flow.md](data-flow.md)**. Read it before
touching the data path.

## Settings schema

`NS.Schema` in `settings/Schema.lua` is the single source of truth: **99 rows across 11 page keys**,
each one wiring automatically into its panel widget, its `/mm get|set|list|reset` coverage, and the
per-page and global defaults reset. Adding a setting is one row and never a parallel mutator.

The write seam is `NS.SetByPath`; the reader is `NS.GetSetting`. Both the panel and the CLI point at
them, so `/mm set window.frame.width 300` takes exactly the path a slider takes — same validation,
same debug line, same `CONFIG_CHANGED` message, same panel re-sync.

**The window-relative path model** is the one thing here that is not standard-issue. Almost every
setting is per-window, and a window is an instance created at runtime — so an absolute path would
have to be `windows.<id>.frame.width`: dynamic, unknowable at load, and inexpressible in the flat
path model the CLI and the panel both read. Resolution: a window row's path is **relative** and
spelled `window.frame.width`, resolved by the seam against `NS.State.activeWindowId`, which the
settings panel's window picker (`settings/Windows.lua`, its only writer) moves. Global rows keep
absolute paths (`enabled`, `minimap.hide`) and resolve against `db.profile`. Moving one integer of
session state retargets seventy-odd rows.

Two pages carry **zero** schema rows, both by necessity. `settings/Columns.lua` edits an ordered
array whose length is the user's, which a path model has no vocabulary for — so `window.columns` is a
documented carve-out: reads walk it like any node, and a write is accepted **whole-array**, validated
and rebuilt entry by entry by the same seam. `settings/Profiles.lua` hosts AceDBOptions' own tree and
is the one place `AceConfigDialog` is permitted, because the options table is not ours to re-express.
It is also the one page vetoed from reset-all — resetting it deletes user data.

`NS.ValidateSchema()` proves every row's `default` equals `defaults/Profile.lua`'s. The two are
restated independently rather than sharing a reference precisely so the check can prove something.

Panel behavior, the widget makers and the page tree: [settings-panel.md](settings-panel.md). The
persisted shape and the migration seam: [schema.md](schema.md).

## Message bus

Twelve `AceEvent` messages are the only inter-module communication channel — modules never call each
other across boundaries. Every name is declared once in `core/Constants.lua`'s `MSG` catalog, so a
typo in a subscriber is a nil-index at load rather than a callback that silently never fires.
**One sender each**; a second sender is a bug, not a convenience.

| Message | Sender | Consumers | Payload |
|---|---|---|---|
| `METER_UPDATED` | `core/MythicMeters.lua` | `Targets`, every `Window` | — |
| `METER_SESSION` | `core/MythicMeters.lua` | `Provider`, `Targets`, every `Window` | `{ type, sessionID }` |
| `METER_RESET` | `core/MythicMeters.lua`, and `Provider.Reset` for the manual path | `Provider`, `Aggregator`, `Targets`, `DrillDown`, every `Window` | — |
| `ROSTER_CHANGED` | `core/MythicMeters.lua` | `Roster`, `Visibility`, every `Window` | — |
| `ZONE_CHANGED` | `core/MythicMeters.lua` | `Visibility`, every `Window` | — |
| `ENTERING_WORLD` | `core/MythicMeters.lua` | `Provider`, `Roster`, `Visibility`, every `Window` | `{ isLogin, isReload }` |
| `RESTRICTION_CHANGED` | `core/MythicMeters.lua` | every `Window` | `{ type, state }` |
| `PROFILE_CHANGED` | `core/Database.lua` (`fireProfileChanged`) | `Format`, `Roster`, `Aggregator`, `Targets`, `WindowManager`, `DrillDown`, `Visibility` | `{ newProfileKey }` |
| `CONFIG_CHANGED` | `settings/Schema.lua` (`NS.SetByPath`) | `Format`, every `Window` | `{ section, windowId }` |
| `WINDOWS_CHANGED` | `modules/WindowManager.lua` (`announce`) | `DrillDown`, the settings panel | `{ windowId, action }` |
| `PREVIEW_CHANGED` | `core/State.lua` (`State.SetTestMode`) | `Roster`, every `Window` | `{ enabled }` |
| `DRILLDOWN_CHANGED` | `modules/DrillDown.lua` (`announce`) | the addressed `Window` | `{ windowId, active }` |

`METER_RESET` has two dispatch paths on purpose: the game fires `DAMAGE_METER_RESET` and
`Provider.Reset` also announces, so a manual reset does not depend on the event arriving. Every
handler on it is idempotent, and a duplicate wipe is a far smaller problem than a window still
drawing rows for sessions that no longer exist.

`CONFIG_CHANGED` and `WINDOWS_CHANGED` are deliberately distinct: the first is a setting moving
inside a window that already exists (re-apply and refresh), the second is the registry changing
*shape* (rebuild, and the panel re-draws its picker). Both carry `windowId`, so a twenty-window
profile does not re-apply nineteen windows for one edit.

**Bus-target discipline.** CallbackHandler keys callbacks by `(message, target)`, so two receivers of
one message on the same object silently clobber each other and only the last registrant fires. This
addon is unusually exposed — every window subscribes to the same refresh messages and there can be
many windows. AceAddon modules are their own targets; each `Window` instance and `modules/Format.lua`
own a private target from `NS.NewBusTarget()`. Nothing registers on the shared addon object.

## Slash commands

`/mm` and `/mythicmeters` are aliases, registered through AceConsole (never a raw `SLASH_*` global).
`NS.COMMANDS` in `settings/Slash.lua` is the sender-authoritative dispatch table: **15 verbs**, the
ten reserved ones first in the order the standard fixes, then this addon's five. The dispatcher, the
help renderer and the schema CLI are LibKa0s-Slash-1.0's; the verb table stays this addon's and is
passed *in*, because the settings landing page renders the same rows and library ownership would make
that a load-time cycle between two majors.

| Command | What it does |
|---|---|
| `help` | Show the command index |
| `config` | Open the settings panel (`options` is accepted as an alias) |
| `list` | List every setting and its current value |
| `get <path>` | Read one setting |
| `set <path> <value>` | Write one setting |
| `reset <path>` | Reset one setting to its default |
| `resetall` | Reset every setting to its default (Profiles rows are vetoed) |
| `debug` | Toggle the console window; `on` / `off` set session logging; **`diag`** prints the diagnostic report |
| `perf` | Performance capture — `/mm perf help` for the run's own verbs |
| `version` | Print the addon version, read from the TOC manifest |
| `lock` | Lock or unlock every window for dragging (unlocking implies preview) |
| `preview` | Toggle placeholder rows, for positioning |
| `toggle` | Show or hide one window by name, or all of them |
| `window` | `list` · `new <name>` · `delete <name>` · `copy <source> <target>` |
| `reset-positions` | Move every window back to the center of the screen |

The five host verbs act on **windows** — instances the registry owns — rather than on schema rows, so
they are untouched by the library's absence and route straight into `modules/WindowManager.lua`
rather than duplicating its rules. Window keys accept either an id or a name: a number is an id, a
string is a name, matched case-insensitively but stored exactly as typed.

## Event subscriptions

**`core/MythicMeters.lua` registers every game event this addon listens to, and no other file
registers any.** Each handler does the minimum translation and republishes onto the bus; none reads a
value and none decides anything, which is what lets that section be read as a wiring diagram.

| Event | Handler | Becomes |
|---|---|---|
| `PLAYER_ENTERING_WORLD` | `OnEnteringWorld` | `ENTERING_WORLD { isLogin, isReload }` |
| `GROUP_ROSTER_UPDATE` | `OnRosterUpdate` | wipes the `Roster` cache **first**, then `ROSTER_CHANGED` |
| `ZONE_CHANGED_NEW_AREA` | `OnZoneChanged` | `ZONE_CHANGED` |
| `ADDON_RESTRICTION_STATE_CHANGED` | `OnRestrictionChanged` | mirrors `NS.State.restricted`, then `RESTRICTION_CHANGED { type, state }` |
| `DAMAGE_METER_CURRENT_SESSION_UPDATED` | `OnMeterUpdated` | `METER_UPDATED` |
| `DAMAGE_METER_COMBAT_SESSION_UPDATED` | `OnMeterSession` | `METER_SESSION { type, sessionID }` |
| `DAMAGE_METER_RESET` | `OnMeterReset` | wipes every cache, then `METER_RESET` |

The three `DAMAGE_METER_*` handlers carry the `meterEvent` perf bracket. It measures the **fan-out**,
not the redraw: `SendMessage` walks every subscribed window's callback synchronously, which is the
cost that scales with window count at raid event rate. What a window then does on its own throttle
tick is the separate `refresh` bucket.

`ADDON_RESTRICTION_STATE_CHANGED` is registered even on a client without `C_RestrictedActions` — an
event that never fires costs nothing, and the alternative is a version check to keep in step with
`core/Secrets.lua`'s. `OnEnable` also **seeds** `NS.State.restricted` from `Secrets.IsRestricted()`,
because a `/reload` taken mid-pull re-enables the addon inside an already-active restriction and
there is no second edge to catch.

Everything else is a bus subscription. Registration by module is tabulated in
[module-map.md](module-map.md#what-each-file-publishes-and-consumes).

Perf buckets, declared in `core/PerfSetup.lua` with their nesting: `meterEvent` · `refresh`
(→ `providerRead`, `aggregate`, `render` → `renderRow`) · `tooltip`. A parent is never summed with
its children. Detail in [performance.md](performance.md) and
[perf-analysis/README.md](perf-analysis/README.md).

## Taint notes

**This is the constraint that shapes the whole addon.** Read it before changing anything on the data
path; the full trip is in [data-flow.md](data-flow.md).

`C_DamageMeter`'s session returns are `SecretWhenInCombat`. While the **`Combat`** addon restriction
is active, the numeric fields come back to tainted code — which is all of ours — as **secret values**.

| Tainted code MAY | Tainted code MAY NOT |
|---|---|
| store them in variables and in table **values** | do arithmetic on them |
| pass them to Lua functions and return them | compare them, or boolean-test them |
| concatenate with `..`, and `string.format` / `string.join` them | use them as table **keys** |
| pass them to `StatusBar:SetValue` / `SetMinMaxValues` and `FontString:SetText` | apply the `#` length operator |
| call `type()` on them, and test `== nil` | index them |
| call `NumericRuleFormatter:FormatNumber` on them | call `table.concat` with them |

Each forbidden operation raises **immediately**. The single exception the addon leans on is that a
**non-boolean** secret may still be tested for nil-ness, which is why `== nil` appears everywhere a
truth test would be natural — `value or 0` is a truth test and raises; `value == nil and 0 or value`
does not. `table.concat` is worth naming twice: it is the one string operation that raises on a
secret, which is exactly why LibKa0s uses it as the detection probe.

`classFilename`, `specIconID`, `isLocalPlayer` and `deathRecapID` are `NeverSecret` and always
readable — all four verified in-game under an active restriction. `name` is `ConditionalSecret`.

**`sourceGUID` is NOT.** The addon was built on the reading that a meter source GUID is never secret
and is therefore its only legal join key; in-game it comes back secret *and* inaccessible for the
whole of a pull, so the join has no key while the restriction is active. `isLocalPlayer` is what row
identity is rebuilt from — see Known limitations below.

**The unit API hands out secret GUIDs too**:
in a follower dungeon `UnitGUID("party3pet")` answers a secret string, and keying on one raises
`attempted to perform indexed assignment on a table that cannot be indexed with secret keys` on every
refresh tick. `modules/Roster.lua` — the addon's only reader of the unit API — therefore vets every
GUID through `NS.Secrets.IsSafeKey` before using it as a key, and vets the argument of `Get`,
`IsGroupMember` and `OwnerOf` the same way. An unreadable pet falls into the existing
"unattributable" case: no map entry, `OwnerOf` nil — and it then gets a row **of its own**, under its
own name, rather than being dropped (see [Known limitations](#known-limitations)).

Three design rules follow, and they are enforced in one place each rather than remembered in twenty:

- **R1 — `modules/Provider.lua` is the only caller of `C_DamageMeter`, and `core/Secrets.lua` is the
  only file that inspects a value.** Everything downstream treats a value as an opaque handle it may
  hand to a widget setter or the native formatter, and to nothing else. If a module needs to know
  something about a value — is it secret, may I sort these, how many entries does this array have —
  it asks `NS.Secrets`.
- **R2 — row order is never computed from values while comparison is illegal.** `orderByValue`
  proves comparability in a separate pass *before* `table.sort` is entered, because a comparator that
  discovers an illegal comparison halfway through has already raised.
- **R3 — layout is computed from config, never read back off a frame.** `SetValue(secret)` marks a
  frame `HasSecretValues`, which makes its position data secret and propagates that to anything
  anchored to it. There is not one `GetPoint` / `GetWidth` / `GetLeft` in `modules/Row.lua`; a window
  keeps drag and resize on a bare `inst.anchor` frame that never holds a value.

R3 also runs the other way: **a frame that is never handed a value keeps readable geometry**, so the
cheapest way to shrink the secret set is to stop handing values to frames that do not need them. The
name cell is the worked example — it used to take the sort column's figure purely to scale a bar
behind the player's name, and dropping that bar took the frame out of the secret set entirely. The
class color moved onto the name text, which is better anyway: `classFilename` is `NeverSecret`, so
the identity stays legible at the height of a pull when every number on the row is opaque.

The name cell is also where the addon's only **string inspection** lives. Stripping a realm
(`string.match`) and capping a length (`string.sub`) read the characters of a value, which R1 forbids
on a secret — so both are gated on the concat probe, and a `ConditionalSecret` name reaches the widget
untouched and uncapped. The cap counts UTF-8 characters rather than bytes; a byte slice can emit half
a code point, and accented names are exactly the ones most likely to need truncating.

**Secrecy keys off `Combat`, not `ChallengeMode`.** Between packs in a key the values and the GUIDs
are fully readable, so the exact GUID join runs for most of a dungeon run and identity mode covers the
pulls themselves. `ADDON_RESTRICTION_STATE_CHANGED` fires with `state = Activating` **before**
enforcement begins and access is still permitted during that dispatch, which is why
`core/Secrets.lua` exposes the raw state and not just a boolean. `modules/Aggregator.lua` no longer
listens for that edge: it existed to take one last value-sort and freeze the result, and a frozen
`guid → position` map cannot be applied to rows that have no GUID.

Two consequences worth stating once, because both look like bugs: **percentage text slots go quiet in
combat** (a percentage is a division), and **a pet keeps its own row rather than being summed into its
owner's while restricted** (a sum is arithmetic, and the native formatter renders but does not sum).
The second is why the scoring feature is deferred — [scope.md](scope.md#deferred-scoring).

## The segment selector

A window's header line is a **button**. Clicking it opens a context menu of every session the client
is still holding — name and duration, newest first as the API returns them — then a divider, then the
two synthetic entries `Current` and `Overall`.

The choice is stored in `window.data.sessionID`, which **overrides `sessionType` when set** and is
`nil` when no segment is pinned. It has no schema row: it is not a settings-panel control and its
unset state cannot be expressed as a default. It is persisted like any other key in `window.data`.

Threading it took one optional trailing argument rather than a new shape. `Provider.GetColumn`,
`GetSourceDetail` and `GetSessionDuration` each accept a trailing `sessionID`; nil routes to the
`…FromType` shim exactly as before, and a number routes to the `…FromID` shim. `modules/Provider.lua`
therefore remains the only caller of `C_DamageMeter`, and every existing call site was unchanged.
`Compat.GetCombatSessionFromID` and `Compat.GetAvailableCombatSessions` had shipped unused since v0.1.0
for precisely this.

Every read path honors the pin, and that matters more than it looks: a tooltip or a drill-down still
reading the live pull while the grid under it showed a fight from ten minutes ago would be describing
a different encounter than the row the cursor is on.

**Staleness is handled by forgetting, at the top of the refresh.** `WindowProto:DropStaleSegment`
asks `Provider.HasSession` and clears a pin the client no longer holds. A stale id does not raise —
it silently reads an empty session, which is indistinguishable from a broken addon. Session ids are
never reused, so nothing is lost by forgetting one. With no provider module at all the pin is left
alone: that is a broken install, not a stale segment, and rewriting the player's setting because of
our own load order would be the worse failure.

`Compat.OpenContextMenu` wraps `MenuUtil.CreateContextMenu` and is the only menu API wired. The
pre-11.0 alternatives are deliberately absent — they do not exist on any client this addon supports,
and a fallback nobody can run is a fallback nobody has tested.

## Known limitations

- English (`enUS`) only. The locale plumbing and the metatable fallback exist; no second locale ships.
- Retail / Midnight only — a single `## Interface` line. `C_DamageMeter` does not exist on Classic.
- **Pet attribution is best-effort, but an unattributable ally is no longer lost.** Guardians,
  totems, temporary summons and any pet whose owner was never within unit-API range cannot be tied
  to an owner — the roster REMEMBERS every attribution it once made, so leaving the group does not
  lose one, but a guardian the unit API never saw was never attributable in the first place. Such a
  source now gets **its own row, under its own name**, rather than vanishing off the grid. That is
  not the mislabeling the drop rule guards against: the rule is about putting one player's numbers
  under another player's *name*, and this row claims no owner at all. The gate that keeps it safe is
  `sourceDisplayType`, and it never reads "not Enemy" as "one of ours" — read that loose way, a
  source whose display type is absent becomes a row and the whole trash pack lands on the grid.
- **A delve companion is admitted, because the client files one under `None`.** The gate above was
  `Ally` and nothing else until a live delve showed Valeera Sanguinar doing 24.98M of a run's 61.31M
  and never reaching the grid, while the header total counted her — a session total is the client's
  own sum and never consults the row gate. `display=0` is `None`: neither `Ally` nor `Enemy`. So a
  `None` source is now admitted **only when its `classFilename` is a class `RAID_CLASS_COLORS`
  recognizes**. That table is the oracle rather than a list of our own because `modules/Row.lua`
  already looks a row up in it to color the bar and pick the class icon — what this refuses could
  only ever have drawn as an uncolored, iconless row. A mob would have to report `None` *and* carry
  a genuine class filename to slip through, and `/mm debug diag` prints the enemy column's display
  types so that a `None` there is reported rather than inferred from a wrong row.
- **`data.mergePets` is off by default, and has no effect during a pull.** A pet gets its own row,
  which needs no arithmetic and is exact in both states. Merging is addition and needs the owner
  link, so it runs only where GUIDs are plain — out of combat.
- **The roster is sticky for the life of the meter's data.** Someone who left the group mid-run stays
  on the grid until the meter is reset. That is deliberate: the alternative — what shipped in
  v0.1.0 — was the window emptying itself the moment you left a dungeon, for a session that still
  held everyone's numbers.
- **Two players of the same class AND specialization cannot be told apart mid-pull.** `sourceGUID`
  is `SecretWhenInCombat`, so while the restriction is active the grid is built by identity
  correlation (`classFilename` + `specIconID` + `isLocalPlayer`) rather than by the GUID join, over
  the union of every column. Rows are correct — the sort column's are the engine's own ranking, and
  anyone it never mentioned is parked after them — but where two rows share an identity key, their
  **secondary columns are left empty** rather than filled from a source that might be the other
  player's, and an ambiguous key gets no row invented for it at all. The header says `restricted — some rows cannot be told apart`, and the
  full grid returns on the first refresh after combat.
- **Pets are separate rows for the whole of a pull, whatever `data.mergePets` says.** Folding needs
  the owner link, the owner link needs a GUID, and there is none while restricted.
- **Percentage text slots render empty in combat.** By design; the slots default to total and rate.
- **The tooltip's Targets section is absent for the whole of a pull, not degraded.** It is the one
  place in the addon where restriction costs *information* rather than decoration, and it is
  deliberate, and there are now **two independent reasons**, either of which is sufficient:

  1. *The enemy cannot be identified.* Both identifiers the API accepts are secret in a pull —
     `sourceGUID` is `SecretWhenInCombat`, and `sourceCreatureID` turns out to be too. Passing a
     secret `sourceCreatureID` does not merely fail to resolve, it **raises**
     (`bad argument #4 … Secret values are only allowed during untainted execution`), and because
     `Targets.ForPlayer` runs on the tooltip's render path that raise took *every cell tooltip* down
     for the whole pull, not just this section. `modules/Targets.lua` now gates both identifiers
     through `NS.Secrets.IsSafeKey` and abandons the build when neither survives — calling with both
     nil does not fail, it answers for a **different source**, whose numbers would be summed in as
     though they were this enemy's.
  2. *The sum is illegal.* One enemy's damage from one player does not exist in the API; it is a
     **sum** over that enemy's matching spells, and a sum of secrets raises. Summing only the
     readable rows would show a number that is wrong, plausible and invisibly low, so the build is
     refused entire on the first unreadable amount.

  It is also off by default and Damage-column only, because it costs one provider call per enemy on
  the first hover of a session. See [data-flow.md §9](data-flow.md).
- **`provider` sort mode rests on an unverified assumption** — that `combatSources` arrives sorted by
  the requested statistic. Isolated in `modules/Provider.lua`; `value` and `roster` do not depend on
  it.
- **Scoring is deferred**, and cannot be computed in combat at all. See
  [scope.md](scope.md#deferred-scoring).
- **No in-window column drag editor** — settings-panel only, and structurally so (rule R3).
- **Scrolling is the mouse wheel only — there is no scrollbar.** A window draws `layout.maxRows`
  rows chosen out of a longer list, so scrolling moves an integer offset rather than a scroll child;
  there is no widget to size and nothing measured. The cost is that a player cannot see there are
  rows above or below without trying the wheel.
- Debug logging is session-only (`NS.State.debug`) and resets on every `/reload`.
- **A refresh pass logs on change, not on every pass.** The `[Aggregator]` and `[Render]` summary
  lines go through `NS.DebugSteady`, which emits a change immediately and otherwise re-announces an
  unchanged run at most every 10 seconds as `… (xN)`. It is what keeps a 500-line buffer holding
  hours rather than forty seconds. Ratified as a deviation from debug-logging §8 — see the register
  below. Note the console's **Clear** button does not reset the comparison (the library offers the
  host no hook), so a freshly cleared console can sit silent until the next change or heartbeat.
- No automated in-client tests: headless suites plus manual in-game smoke tests.
- Not published — `X-Curse-Project-ID` and `X-Wago-ID` are deliberately absent from the TOC.

## Documentation map

Every `.md` under `docs/` appears in exactly one of the three tables below (`documentation-§3`).
Frozen and generated directories are named once and never enumerated per run: `docs/automated-tests/`,
`docs/perf-analysis/`, `docs/superpowers/`. `docs/issues/` holds image evidence attached to GitHub
issues (GitHub's API has no supported path for uploading an issue attachment, so a raw link to a
committed file is the only way a screenshot reaches one); it carries no `.md` and so registers no row.

### Canonical trio (Tier 1)

| Doc | Covers |
|---|---|
| `ARCHITECTURE.md` | This file — the hub: overview, module map, schema, bus, slash, events, taint, limitations, this register, deviations |
| `testing.md` | How to run the harness and lint; the green commit gate |
| `smoke-tests.md` | The in-game smoke-test suite |

### Verification and record

| Doc | Covers |
|---|---|
| `test-cases.md` | The generated case inventory (authoritative pass count) |
| `performance.md` | The addon performance page: buckets, offline scenarios, the in-game A/B |
| `perf-analysis/README.md` | What a recorded in-game capture bundle is and how to produce it |
| `automated-tests/README.md` | What the automated-test record is and how to produce it |
| `automated-tests/RESULTS.md` | One row per run; generated, never hand-edited |

### Topic detail

| Doc | Covers |
|---|---|
| `scope.md` | What the addon does and deliberately does not, including why scoring cannot be computed in combat |
| `module-map.md` | Every non-vendored file, its responsibility, TOC load order, the AceAddon lifecycle |
| `schema.md` | The persisted shape, every default, and the migration seam |
| `settings-panel.md` | The thirteen pages, per-option behavior, and the write seam |
| `data-flow.md` | `C_DamageMeter` → pixel, and the secret-value rules that shape every hop |
| `common-tasks.md` | Recipes for the changes made most often here |
| `superpowers/specs/2026-08-09-mythic-meters-design.md` | Tier 3 planning history — the approved v0.1.0 design |
| `superpowers/plans/2026-08-09-mythic-meters-v0.1.0-plan.md` | Tier 3 planning history — the v0.1.0 build plan |
| `superpowers/specs/2026-08-09-display-overhaul-design.md` | Tier 3 planning history — the approved display overhaul |

### Tier 2 conditional docs — evaluated at v0.1.0

Each trigger was measured against the source, not assumed. None of the five ships; the measurements
that decided that are recorded here so a later audit can re-run them rather than re-argue them. This
is an evaluation record, not a fourth register table — every doc below that *does* exist is
registered above.

| Doc | Status | Trigger, as measured |
|---|---|---|
| `slash-dispatch.md` | Not applicable | **15 verbs in `NS.COMMANDS`.** Ten are the standard's reserved set, implemented entirely by LibKa0s-Slash-1.0 and documented by the standard. This addon's own surface is 5 verbs and one 4-entry sub-verb tree (`window`: list/new/delete/copy); `debug` takes 3 words and `perf` delegates its whole sub-surface to the library. The [Slash commands](#slash-commands) section carries all of it in 26 lines. |
| `message-bus.md` | Not applicable | **12 distinct messages**, all declared in one catalog (`core/Constants.lua` `MSG`) with the owning sender named beside each. Every payload is a flat table of one to two plain fields; none carries a handle, a curve object or a per-unit filter needing prose. The [Message bus](#message-bus) section carries sender, consumers and payload for all twelve in 22 lines. |
| `compat-layer.md` | Not applicable | **`core/Compat.lua` is 316 lines and 15 shims**, each a guarded namespace check around one passthrough, with no feature decisions and no state. Nothing there inspects a meter value. The comparison point is KickCD's 490-line Compat, which ships the doc. |
| `midnight-quirks.md` (secret values) | Not applicable | The 12.0 secret-value model is this addon's **defining** constraint, not a quirk beside its main subject — so it is carried by [Taint notes](#taint-notes) (the operation lists, R1/R3, the `Combat`-not-`ChallengeMode` fact) and by [data-flow.md](data-flow.md), which is Tier 1 and mandatory here regardless. A third copy would be the one that drifts. |
| `profiles.md` | Not applicable | `settings/Profiles.lua` is 113 lines hosting **AceDBOptions-3.0's own tree** unchanged. The addon adds no profile semantics beyond the `PROFILE_CHANGED` fan-out already tabulated above and the reset-all veto already stated under [Settings schema](#settings-schema); the persisted shape is [schema.md](schema.md)'s. |
| `debug.md` | Not applicable | The console is `LibKa0s-DebugLog-1.0`'s window. `/mm debug` toggles it and takes `on` / `off`. The one surface of this addon's own is `/mm debug diag` — `core/Diagnostics.lua`, ~200 lines of print statements whose header explains itself, with no state and no options for a doc to describe. |

## Documented deviations

The **single home** for a ratified deviation from the Ka0s WoW Addon Standard. A deviation not in this
table is not ratified: an audit that cannot find the decision here re-files it as an open MUST
failure, and the same argument gets had every cycle. The reasoning may live at length in the topic doc
named in **Why**; the row is what makes it a decision rather than a note.

**Re-check trigger** is the condition that *ends* the deviation, written so a reader can tell whether
it has already fired. A row without one is a permanent opt-out wearing a table's clothes. When a cited
rule changes so that the behavior becomes mandated or permitted outright, the row is **retired** —
this table must not become a graveyard.

Rows are shaped `| Rule | What differs | Why | Decided | Re-check trigger |`.

| Rule | What differs | Why | Decided | Re-check trigger |
|---|---|---|---|---|
| debug-logging §8 — each recompute logged "as a single summary line" | A refresh pass whose summary line is **unchanged** from the previous pass is not logged. The line is emitted on every *change*, plus a heartbeat at most every 10s carrying `(xN)` for the passes it stood for. | `throttle = 0.25` is four passes a second, each emitting an `[Aggregator]` and a `[Render]` line (three while restricted) into a buffer capped at 500 lines (§1) — **the console holds 40 seconds**. A live capture showed one identity line repeating byte-identically for 41 seconds: ~160 passes, ~480 lines, one string, evicting every other line in the buffer. That is the harm §9 names ("it **evicts** it") arriving by a route §9 does not cover: §9 bounds *per-item* emission and says nothing about a pass repeating unchanged on a timer. A change is never delayed and never dropped, so nothing a reader wants is what goes missing. Implementation and reasoning: `core/DebugLogSetup.lua` → the steady-state sink. | 2026-08-21 | debug-logging gains a rule for repeating timer-driven passes — the gap is general to any Ka0s addon with a refresh timer, so the standard is the right long-term home and this row retires the day it lands. |

**One row is ratified.** The register also carried a row for a root `TODO.md`
holding work that was decided but unscheduled, adopted as a stopgap until the repo had an issue store.
That row was retired on 2026-08-11 when the backlog moved to
[GitHub issues](https://github.com/tusharsaxena/MythicMeters/issues), which is precisely the re-check
trigger it was written with.

Rows above are ratified. The paragraph below is why the section is never *removed* even when it is
empty: an audit needs to be able to tell "nothing has been ratified" from "the register was never
written".

Three things read like deviations and are not, recorded here so the same question is not re-opened:

- **`NS.Format` is a callable table.** `core/CoreSetup.lua` publishes LibKa0s's chat printer under
  that name and the design brief names the same field for the number formatter.
  `modules/Format.lua` resolves the collision in one place rather than renaming either contract, and
  publishes `NS.Numbers` / `NS.NumberFormat` as unambiguous aliases. That is a naming decision inside
  this addon, not a departure from a numbered rule.
- **`modules/Roster.lua` does not send `ROSTER_CHANGED`.** The build brief made it the sender; it
  cannot be, because `core/MythicMeters.lua` is the single game-event listener and already owns
  `GROUP_ROSTER_UPDATE`. The direction is inverted and the module subscribes instead. The message
  still has exactly one sender — which is what the rule asks for.
- **`METER_RESET` has two dispatch sites.** Both are inside the one-sender contract's intent: the
  game's event and the addon's own `Provider.Reset`, which must announce even if the event never
  arrives. Every handler is idempotent. Reasoned in `modules/Provider.lua`.

## Load order

`MythicMeters.toc` is the source of truth; the order is dependency, not alphabetical. Full
per-file reasoning in [module-map.md](module-map.md#load-order). The binding constraints:

1. `libs/` — Ace3, LibKa0s, LibSharedMedia, AceGUI-3.0-SharedMediaWidgets, LibDataBroker, LibDBIcon.
2. `locales/enUS.lua` — first, so `NS.L` exists for every declaration below.
3. `core/Compat.lua` **first** in the core block: `core/Namespace.lua` reads the TOC manifest through
   it on the next line.
4. `core/CoreSetup.lua` before `core/MythicMeters.lua`, whose AceConsole reclaim reads
   `NS.Util.print`; and **first of the five LibKa0s seams**, because it defines `NS.LIBKA0S_MISSING`.
5. `core/PerfSetup.lua` after `core/Namespace.lua` (a nil `version` stamps every capture record `v?`)
   and **before every `modules/` file that takes `local Perf = NS.Perf` as a load-time upvalue**.
6. `defaults/Profile.lua` after `core/Constants.lua`, whose stat catalog it captures at load.
7. `modules/Format.lua` first in the module block; `modules/Row.lua` resolves `Tooltip` and
   `DrillDown` at *call* time because both load after it. `modules/Targets.lua` loads before
   `modules/Tooltip.lua`, its only caller.
8. `settings/Schema.lua` first in the settings block — `Slash.lua` and `OptionsSetup.lua` both point
   their seams at `NS.SetByPath` / `NS.GetSetting` at load — and `settings/OptionsSetup.lua` before
   every page file, which call `NS.Helpers` members inside schema-row literals at file load.
