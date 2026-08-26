# Architecture

Orient-yourself map for **Ka0s Multi Meters**. A single-frame, multi-column group meter for Retail
(Midnight, 12.x): one row per group member, one column per statistic, each cell a `StatusBar` with a
`FontString` on it. Every number is read from Blizzard's built-in damage meter through
`C_DamageMeter`; the addon never parses the combat log.

This file is the hub. Topic detail lives in `docs/` and is linked from each section — a section here
that outgrows a screen belongs in its topic doc with a summary and a link left behind.

## Overview

Forty-eight non-vendored source files: 1 locale, 15 `core/`, 1 `defaults/`, 15 `modules/`, 16 `settings/`.

The addon is built on the **private namespace** WoW hands each file. `core/MultiMeters.lua` calls
`AceAddon-3.0:NewAddon(NS, addonName, …)`, which promotes that table in place — so **`NS` *is* the
addon object**. There is no `_G.MultiMeters` and no rebind. `NS.addon` is published for callers that
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
  nearly empty: an array of windows, an id counter, two addon-wide toggles, and the `export` group,
  which remembers an **action** the player takes rather than how any one window looks.

Eight statistics are catalogued in `core/Constants.lua`; six ship enabled on a new window (Damage,
Healing, Interrupts, Dispels, Avoidable Damage, Deaths). Adding a ninth is one row in that catalog —
the column editor, the defaults, the aggregator's read loop, the sort-column dropdown and the tooltip
header all read the same table.

`EnemyDamageTaken` is **read but not catalogued**. The meter offers it and `modules/Targets.lua`
walks it to build "which enemies this player hit", but it is not a column: every catalog row answers
a question about a group member, and that one answers a question about an enemy, so offering it as a
column asked a single grid row to be both a player and a mob. `Constants.STAT_BY_KEY` is therefore
"may this be a column" and `Constants.READABLE_STAT_BY_KEY` — the catalog plus
`Constants.OFF_CATALOG_STATS` — is "may this be read", which is the lookup `modules/Provider.lua`
alone uses. It returns as its own window type, whose rows are enemies
([issue #2](https://github.com/tusharsaxena/MultiMeters/issues/2)).

Chrome comes from LibKa0s-Core-1.0's shared `SKIN` / `ApplySkin`, never a private lookalike, so the
meter window, the debug console and the perf step panel wear the same Ka0s edge as every sibling
addon. Nine LibKa0s majors are consumed — Core, Media, Perf, DebugLog, Env, Pool, Slash, Options and
Widgets. Eight are reached through a seam file of their own (`core/CoreSetup.lua`,
`core/MediaSetup.lua`, `core/PerfSetup.lua`, `core/DebugLogSetup.lua`, `core/EnvSetup.lua`,
`core/PoolSetup.lua`, `settings/Slash.lua`, `settings/OptionsSetup.lua`); Widgets is resolved at its
one call site, `modules/Export.lua`, because the export modal is the only thing in the addon that
builds a dropdown. Every one of the nine degrades rather than erroring when `libs/LibKa0s` is
absent. Two of them pass the addon's own **folder name** to the library (`core/CoreSetup.lua`'s `MakeCloseButton` wrapper and
`core/DebugLogSetup.lua`'s descriptor), and a third gets there by accident of its own descriptor —
`core/PerfSetup.lua` passes the folder name as `name`, which is what the perf panel's own close
control is built from (`PerfPanel.lua` minor 4). This is why that file passes **no** `decorate` hook:
the one it used to carry drew a close button with the name dropped, so the panel wore a
multiplication sign beside a console wearing the mark. The name matters because a texture path is
absolute from `Interface\AddOns\`
and a vendored library cannot know which folder it was copied into — that is what lets the library's
own windows wear the same close, copy and clear marks the meter window's header draws. Five explain the
absence through the one shared cause clause `NS.LIBKA0S_MISSING`; **Media is deliberately silent**,
because what it degrades is chrome. The icons this window draws and its monospace face ship inside the
LibKa0s payload (`LibKa0s-Media-1.0`), so a missing library takes the art with it — the header walks
down its own atlas-then-ASCII ladder, the numbers fall back to the client font, and neither wants a
line of chat about it.

Full scope boundaries, including the two features that are structurally impossible rather than merely
unbuilt, in [scope.md](scope.md).

## Module map

Every file, what it owns, what it publishes, what it consumes, plus TOC load order and the AceAddon
lifecycle: **[module-map.md](module-map.md)**. The shape at a glance:

| Layer | Files | Responsibility |
|---|---|---|
| `locales/` | `enUS.lua` | `NS.L`, with the key-is-the-string fallback. Loads first. |
| `core/` boundary | `Compat.lua` | All 28 cross-patch shims, including the eight `C_DamageMeter` reads. No logic. |
| `core/` boundary | `EnvSetup.lua` | The `LibKa0s-Env-1.0` seam: `NS.Meta` / `NS.Version`, the TOC-manifest reader `Compat.lua` used to own. |
| `core/` values | `Constants.lua`, `Namespace.lua`, `State.lua` | The stat catalog, the bus catalog, identity, session-only flags and the shared cache. |
| `core/` the rule | `Secrets.lua` | **The only file that inspects a meter value.** |
| `core/` seams | `MediaSetup`, `CoreSetup`, `PerfSetup`, `DebugLogSetup`, `PoolSetup`, `LSMPatch` | LibKa0s wiring, the art and font seam, the window row pool, and one AceGUI widget fixup. |
| `core/` runtime | `MultiMeters.lua`, `Database.lua` | The single game-event listener and the show ladder; AceDB and migrations. |
| `defaults/` | `Profile.lua` | The window template. The only place a profile default is hardcoded. |
| `modules/` data | `Provider`, `Roster`, `Feign`, `Aggregator`, `Format` | Read → join → order → render as text. `Feign` is the one source row the addon deliberately discards. |
| `modules/` display | `WindowManager`, `Window`, `HeaderControls`, `Row`, `Targets`, `Tooltip`, `DrillDown`, `Visibility`, `Minimap` | The registry, one window, one row, the enemy cross-reference, the two hover surfaces, the breakdown, the context predicate, the launcher. |
| `modules/` output | `Export` | The segment a window is pointed at, as CSV or as ranked chat lines. Calls no meter API — it asks the aggregator, exactly as a window does. |
| `settings/` | `Schema`, `Slash`, `OptionsSetup` + 10 pages | One schema drives the panel, the CLI and the defaults reset. |

The path a number takes through those layers — the throttle, the GUID join, pet folding, the sort
identity build, the formatter and the widget setters — is **[data-flow.md](data-flow.md)**. Read it before
touching the data path.

## Settings schema

`NS.Schema` in `settings/Schema.lua` is the single source of truth: **129 rows across 8 page keys**,
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
settings panel's window picker (`settings/Windows.lua`, its only writer) moves. The other seven rows
keep absolute paths and resolve against `db.profile`: `enabled`, `minimap.hide`, the three `export.*`
preferences, and the two `sessionOnly` rows `state.testMode` and `state.debugConsole`, whose own
`get`/`set` are the whole of their storage. Moving one integer of session state retargets a hundred
and seventeen rows.

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

Fourteen `AceEvent` messages are the only inter-module communication channel — modules never call each
other across boundaries. Every name is declared once in `core/Constants.lua`'s `MSG` catalog, so a
typo in a subscriber is a nil-index at load rather than a callback that silently never fires.
**One sender each**; a second sender is a bug, not a convenience.

| Message | Sender | Consumers | Payload |
|---|---|---|---|
| `METER_UPDATED` | `core/MultiMeters.lua` | `Targets`, every `Window` | — |
| `METER_SESSION` | `core/MultiMeters.lua` | `Provider`, `Targets`, every `Window` | `{ type, sessionID }` |
| `METER_RESET` | `core/MultiMeters.lua`, and `Provider.Reset` for the manual path | `Provider`, `Aggregator`, `Targets`, `DrillDown`, every `Window` | — |
| `ROSTER_CHANGED` | `core/MultiMeters.lua` | `Roster`, `Visibility`, every `Window` | — |
| `ZONE_CHANGED` | `core/MultiMeters.lua` | `Visibility`, every `Window` | — |
| `ENTERING_WORLD` | `core/MultiMeters.lua` | `Provider`, `Roster`, `Visibility`, every `Window` | `{ isLogin, isReload }` |
| `RESTRICTION_CHANGED` | `core/MultiMeters.lua` | every `Window`, the export modal (`modules/Export.lua`) | `{ type, state }` |
| `COMBAT_CHANGED` | `core/MultiMeters.lua` | `Visibility`, every `Window` | — |
| `PLAYER_STATE_CHANGED` | `core/MultiMeters.lua` | `Visibility`, every `Window` | — |
| `PROFILE_CHANGED` | `core/Database.lua` (`fireProfileChanged`) | `Format`, `Roster`, `Aggregator`, `Targets`, `WindowManager`, `DrillDown`, `Visibility` | `{ newProfileKey }` |
| `CONFIG_CHANGED` | `settings/Schema.lua` (`NS.SetByPath`) | `Format`, every `Window` | `{ section, windowId }` |
| `WINDOWS_CHANGED` | `modules/WindowManager.lua` (`announce`) | `DrillDown`, the settings panel | `{ windowId, action }` |
| `TEST_MODE_CHANGED` | `core/State.lua` (`State.SetTestMode`) | `Roster`, every `Window` | `{ enabled }` |
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
many windows. AceAddon modules are their own targets; each `Window` instance, `modules/Format.lua`
and the export modal own a private target from `NS.NewBusTarget()`. Nothing registers on the shared
addon object.

## Slash commands

`/mm` and `/multimeters` are aliases, registered through AceConsole (never a raw `SLASH_*` global).
`NS.COMMANDS` in `settings/Slash.lua` is the sender-authoritative dispatch table: **16 verbs**, the
ten reserved ones first in the order the standard fixes, then this addon's six. The dispatcher, the
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
| `resetall` | Reset the active profile to the shipped defaults — a **profile reset**, so it is the equivalent of a new profile: extra windows are deleted and one fresh window is left. The same act as Profiles → Reset Profile; other profiles are never touched. See [settings-panel.md](settings-panel.md#reset-all-settings-vs-reset-profile) |
| `debug` | Toggle the console window; `on` / `off` set session logging; **`diag`** prints the diagnostic report; **`recap`** prints the death-recap probe alone |
| `perf` | Performance capture — `/mm perf help` for the run's own verbs |
| `version` | Print the addon version, read from the TOC manifest |
| `lock` | Lock or unlock every window for dragging (unlocking implies preview) |
| `test` | Toggle test mode — placeholder rows, for positioning |
| `toggle` | Show or hide one window by name, or all of them |
| `window` | `list` · `new <name>` · `delete <name>` · `copy <source> <target>` |
| `reset-positions` | Move every window back to the center of the screen |
| `export` | Open the export modal for one window's segment: `/mm export [window]` |

The six host verbs act on **windows** — instances the registry owns — rather than on schema rows, so
they are untouched by the library's absence and route straight into `modules/WindowManager.lua`
rather than duplicating its rules. Window keys accept either an id or a name: a number is an id, a
string is a name, matched case-insensitively but stored exactly as typed.

`export` is the one of the six that ends somewhere other than the registry: it resolves a window the
same way `/mm toggle` does, then hands the **config** — not the live instance — to `NS.Export:Open`. A window in the registry that has never been built still points at a segment, and
its numbers are as exportable as a drawn one's. Named with no argument it means the window the
settings panel is pointed at, falling back to the first in the registry, because the CLI has no
picker and `/mm export` on a fresh login has to mean something. Whether an export may run at all is
asked once, of `NS.Export.Available()`, and is never re-decided here — see [Taint notes](#taint-notes).

## Event subscriptions

**`core/MultiMeters.lua` registers every game event this addon listens to, and no other file
registers any.** Each handler does the minimum translation and republishes onto the bus; none reads a
value and — with two stated exceptions, the feign filter and the system-message filter below — none
decides anything, which is what lets that section be read as a wiring diagram.

| Event | Handler | Becomes |
|---|---|---|
| `PLAYER_ENTERING_WORLD` | `OnEnteringWorld` | `ENTERING_WORLD { isLogin, isReload }` |
| `GROUP_ROSTER_UPDATE` | `OnRosterUpdate` | wipes the `Roster` cache **first**, then `ROSTER_CHANGED` |
| `ZONE_CHANGED_NEW_AREA` | `OnZoneChanged` | `ZONE_CHANGED` |
| `ADDON_RESTRICTION_STATE_CHANGED` | `OnRestrictionChanged` | mirrors `NS.State.restricted`, then `RESTRICTION_CHANGED { type, state }` |
| `DAMAGE_METER_CURRENT_SESSION_UPDATED` | `OnMeterUpdated` | `METER_UPDATED` |
| `DAMAGE_METER_COMBAT_SESSION_UPDATED` | `OnMeterSession` | `METER_SESSION { type, sessionID }` |
| `DAMAGE_METER_RESET` | `OnMeterReset` | wipes every cache, then `METER_RESET` |
| `PLAYER_REGEN_DISABLED` / `PLAYER_REGEN_ENABLED` | `OnCombatChanged` | `COMBAT_CHANGED` |
| `PLAYER_MOUNT_DISPLAY_CHANGED`, `UNIT_ENTERED_VEHICLE`, `UNIT_EXITED_VEHICLE`, `UPDATE_SHAPESHIFT_FORM`, `PLAYER_CAN_GLIDE_CHANGED`, `PLAYER_IS_GLIDING_CHANGED`, `PET_BATTLE_OPENING_START`, `PET_BATTLE_CLOSE`, `PLAYER_DEAD`, `PLAYER_ALIVE`, `PLAYER_UNGHOST` | `OnPlayerStateChanged` | `PLAYER_STATE_CHANGED` |
| `UNIT_SPELLCAST_SUCCEEDED` | `OnSpellSucceeded` | **the one handler that decides something** — Feign Death (5384) only, straight into `modules/Feign.lua`. Nothing reaches the bus: republishing every cast in a raid to save one comparison would be worse, and no other file may see a game event |
| `CHAT_MSG_SYSTEM` | `OnSystemMessage` | **the second handler that decides something** — offered straight to `modules/Export.lua`'s `NoteSystemMessage`, which answers `false` unless a whisper dump is in flight. Nothing reaches the bus, for the reason above it: the line is chatty, one file cares, and the filter belongs with the queue it cancels |

The three `DAMAGE_METER_*` handlers carry the `meterEvent` perf bracket. It measures the **fan-out**,
not the redraw: `SendMessage` walks every subscribed window's callback synchronously, which is the
cost that scales with window count at raid event rate. What a window then does on its own throttle
tick is the separate `refresh` bucket.

The player-state block exists for `modules/Visibility.lua`'s rules and carries **no payload**,
because those rules read their inputs live at the moment they are asked.

**These edges are load-bearing, not an optimisation.** There is no fallback poll: `onUpdate` in
`modules/Window.lua` refreshes *data* and never re-asks `NS.ShouldShow`, so the show ladder is
re-run only from a bus message a window subscribes to (`ROSTER_CHANGED`, `ZONE_CHANGED`,
`ENTERING_WORLD`, `COMBAT_CHANGED`, `PLAYER_STATE_CHANGED`, `TEST_MODE_CHANGED`, `CONFIG_CHANGED`).
A visibility input with no edge on the bus is a rule that never fires — which is exactly what
happened to `hideInVehicle`, shipped in 0.1.0 with no vehicle event registered, and to the first cut
of the player-state rules, which reached `Visibility` but not the window.

`PLAYER_IS_GLIDING_CHANGED` is **probed** through `C_EventUtils.IsEventValid` rather than registered
outright: it is the newest of the set and a client that has not got it raises on `RegisterEvent`.
Losing that one edge is survivable where losing the block is not — `PLAYER_CAN_GLIDE_CHANGED` still
fires when the mount changes, which is the transition the skyriding rule turns on.
`UNIT_ENTERED_VEHICLE` / `UNIT_EXITED_VEHICLE` fire for every unit, so `OnPlayerStateChanged`
filters those two to `"player"`; that check is a filter, not a decision.

**The filter is keyed on the event name, and must stay that way.** Only the vehicle pair carries a
unit token in `arg1`. `PLAYER_CAN_GLIDE_CHANGED` and `PLAYER_IS_GLIDING_CHANGED` carry a **boolean**
there (`canGlide` / `isGliding`); `PLAYER_MOUNT_DISPLAY_CHANGED` carries nothing. A filter that
tested `arg1 ~= "player"` for the whole block swallowed both skyriding edges while ground mounts kept
working — which read as "skyriding is broken" rather than as a filter bug.

**Every edge is answered twice**, immediately and again after `Constants.PLAYER_STATE_SETTLE` (0.5s).
Some client state lags its own event: `IsMounted()` has flipped by the time
`PLAYER_MOUNT_DISPLAY_CHANGED` arrives, `GetGlidingInfo`'s `canGlide` has not always done so. Read at
the edge alone, a lagging input answers with the state the player just left, and since a hidden
window has no `OnUpdate` running, that stale answer stands until the next zone change. One settle
pass is booked per burst, not per event — mounting fires several at once.

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

**`tostring` is not on the permitted list, and that is why an export is a refusal rather than a
degradation.** A CSV cell is `tostring(value)` and a chat line splices a formatted number into a
sentence. `tostring` on a secret neither raises nor launders it: it answers a **secret string**,
which then poisons the `find` and the `gsub` that RFC-4180 quoting is made of, and the `table.concat`
that joins a row. Everywhere else in the addon a restricted value travels on as an opaque handle and
the display loses a bar or a percentage; there is no equivalent escape for a serializer, because a
serializer's whole job is to look at the characters of a value. A serializer that is subtly wrong
mid-pull is worse than one that says no.

So `modules/Export.lua` says no, at four points rather than one, because the restriction can activate
between any two of them: `Export.Available()` answers false, `/mm export` prints the sentence and
opens nothing, the modal refuses to open, and `Export.CSV` / `Export.ChatLines` refuse again at their
own first line for a caller that reached them anyway. Underneath all four, and independent of them,
every field passes `Secrets.CanAccess` on its way into a cell and yields `""` when it fails — so a
race between the check and the walk can produce a blank cell, and can never raise.

The other half of that file's discipline is what it does **not** do. An export wants every stat for
every player, which is exactly the loop `modules/Provider.lua` already writes — so writing it again
would put a second caller on `C_DamageMeter` and break R1. Instead `Export.SessionConfig` builds a
synthetic window config naming every catalogued stat, pointed at the invoking window's segment, and
hands it to `Aggregator.Build`. The aggregator neither knows nor cares that no frame will draw the
result, and the ranking a chat dump needs happens there, under the aggregator's own guards, rather
than in a sort of the exporter's own.

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

The **segment control** in the header strip — the three horizontal lines — opens a context menu of
every session the client is still holding — name and duration, newest first as the API returns them — then a divider, then the
two synthetic entries `Current` and `Overall`. The menu anchors to the header's session line, which
is where it has always come out; that line used to be a 220px Button and opened the menu itself,
which put an invisible click target across the middle of the title bar and was removed.

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

`Compat.OpenContextMenu` wraps `MenuUtil.CreateContextMenu` and is the only Blizzard menu API
wired. The pre-11.0 alternatives are deliberately absent — they do not exist on any client this
addon supports, and a fallback nobody can run is a fallback nobody has tested.

**It is no longer the only menu in the addon, and this control is deliberately the one that keeps
it.** The export modal's three selectors are `LibKa0s-Widgets-1.0` dropdowns — a flat-skinned button
that drops the library's own popup, shared process-wide with every other Ka0s addon's dropdowns.
This control is not converted: it is a mark in a header strip rather than a labelled selector in a
form, its list is built from live client state and carries a divider, and a dropdown button wide
enough to show a session name would take back the title bar the removed 220px Button already cost.
The two mechanisms coexist on purpose — see `modules/Export.lua`'s "The modal's three selectors"
comment, which argues the same split from the other side.

## Known limitations

- **The feign-death filter cannot run mid-pull, and that is structural.** `C_DamageMeter` hands a
  Feign Death a valid `deathRecapID`, so the Deaths column counts a hunter's feign as a death.
  `modules/Feign.lua` records the GUID off the cast and `modules/Aggregator.lua` drops that source —
  but the join is a plain GUID against `sourceGUID`, and `sourceGUID` is secret for the whole of a
  pull. That is the entire reason the aggregator has a second, GUID-free identity build. There is no
  plain key on the other side of the join while the restriction is up, so **a feign is counted as a
  death mid-pull and the count corrects itself the moment combat ends.** Do not "fix" this by keying
  on something secret; there is nothing to key on.
- **A past death cannot be dated against the run it happened in, so the addon does not try.**
  Measured on a live client: the **Current** session held *zero* deaths, the **Overall** session held
  eighteen and reported `deathTimeSeconds = -1` for every one, and the session's own duration is
  *combat* time rather than wall time — 32 minutes of it spanning a run whose deaths were three hours
  back. A "time into the fight" timestamp style was built on three separate derivations of that
  figure and removed — see [#18](https://github.com/tusharsaxena/MultiMeters/issues/18), which
  carries the captures. `/mm debug recap`'s **dating** section is what proved each one could not
  work, and is kept for whoever tries again. Deaths are dated by wall clock or by "how long ago".
- **The death list is a snapshot taken on entry.** While a window is drilled into a player's deaths,
  `modules/Window.lua` renders `DrillDown:BuildRows` *instead of* running an aggregate pass, so there
  is no current row to re-read the deaths off. A player who dies again while somebody is looking at
  their list will not appear in it until the list is left and re-entered. Re-deriving it would cost a
  second aggregate pass per frame to keep fresh a list nobody is watching change.
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
- **Mid-pull the grid can be re-ranked and reversed, but not sorted.** Picking a different stat
  column and flipping the direction both reach the grid during a pull — neither compares anything,
  the first because identity mode builds its rows out of the chosen column's own `combatSources` and
  the second because reversing is a permutation. Ordering by **name** is still refused with a
  message: it compares a `ConditionalSecret` and has no engine ranking behind it. The sort arrow
  follows `applied` rather than the request, so it never marks a column the rows are not in.
- **The provider-order assumption is measured, not proven.** The engine's ranking is what identity
  mode calls "the order", and nothing in Blizzard's documentation says `combatSources` arrives
  ranked. `/mm debug diag`'s **provider order** section checks it out of combat, where comparison is
  legal, and refuses inside a pull rather than reporting an all-clear it did not earn.
- **Percentage text slots render empty in combat.** By design; the slots default to total and rate.
- **Exporting is unavailable for the whole of a pull.** Both halves — the CSV and the chat dump —
  refuse while the Combat restriction is active, and say so in a sentence rather than producing a
  file of `<secret>`. The reason is `tostring`, which is not a permitted operation on a secret; the
  full argument is in [Taint notes](#taint-notes).
- **An export is capped at 40 rows**, inherited from `Constants.MAX_ROWS` by way of
  `Aggregator.ApplyRowLimit`. A 40-player raid exports whole; a larger group is truncated at the
  aggregator's own ceiling. Stated rather than worked around: raising it means raising the cap every
  window draws against, which is a display decision and not an export one.
- **An export carries the segment's ranking, not the invoking window's view.** It names every stat in
  the catalog, not the window's enabled columns, and it ignores the window's row cap and sort — what
  is on screen is a display choice, and "export this" means the data behind it. Only the *segment* is
  inherited, because "export this" said while looking at last pull means last pull.
- **The export copy window is the third copy-paste window in the collection**, after
  `LibKa0s/DebugLog.lua`'s and `LootHistory/modules/Export.lua`'s. It is a deliberate local copy
  rather than an oversight — the three want to evolve apart — but the shape is stable enough to
  harvest, and the destination is `lib.MakeCopyWindow(name, title)` in LibKa0s Core. Recorded here
  rather than in the deviations register below, because that register is for departures from a
  numbered rule of the standard and this is a library-harvest candidate: no rule is being departed
  from. Filed as a limitation so the issue sweep picks it up as a follow-up.
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
  unchanged run at most every 10 seconds as `… (xN)`. It is what keeps a 1500-line buffer holding
  hours rather than two minutes. Ratified as a deviation from debug-logging §8 — see the register
  below. Note the console's **Clear** button does not reset the comparison (the library offers the
  host no hook), so a freshly cleared console can sit silent until the next change or heartbeat.
- No automated in-client tests: headless suites plus manual in-game smoke tests.
- Not published — `X-Curse-Project-ID` and `X-Wago-ID` are deliberately absent from the TOC.

## Documentation map

Every `.md` under `docs/` appears in exactly one of the three tables below (`documentation-§3`).
**A store gets one row; its dated bundles get none.** `docs/automated-tests/` and
`docs/perf-analysis/` register their two live docs — the README that says how a bundle is produced
and, for the automated-test record, the `RESULTS.md` the runner rewrites — and nothing else under
them; the dated folders beside those files are frozen evidence, and evidence is not registered.
`docs/revendor/` and `docs/superpowers/` are frozen through and through and get one row apiece.

`docs/issues/` used to hold image evidence attached to GitHub issues — GitHub's API has no supported
path for uploading an issue attachment, so a raw link to a committed file is the only way a
screenshot reaches one. **The directory is gone.** An issue's images are deleted when it closes and
its links are re-pointed at the commit that last carried them, which keeps resolving forever without
the repo carrying the weight; issue #1's are pinned to `dcb29ad`. Re-create it only when an open
issue needs a picture, and expect it to empty itself again.

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
| `settings-panel.md` | The ten pages, per-option behavior, and the write seam |
| `data-flow.md` | `C_DamageMeter` → pixel, and the secret-value rules that shape every hop |
| `common-tasks.md` | Recipes for the changes made most often here |
| `superpowers/` | Tier 3 planning history, frozen — the approved design specs and build plans behind each feature, under `specs/` and `plans/`, dated and never revised after the fact |
| `revendor/` | Frozen — one dated bundle per LibKa0s re-vendor: the payload delta and what was adopted, declined or filed from it |

### Tier 2 conditional docs — evaluated at v0.1.0

Each trigger was measured against the source, not assumed. **None of the six ships today**, and the
measurements that decided that are recorded here so a later audit can re-run them rather than
re-argue them — one of them, `compat-layer.md`, is now flagged as having crossed its own line. This
is an evaluation record, not a fourth register table — every doc below that *does* exist is
registered above.

| Doc | Status | Trigger, as measured |
|---|---|---|
| `slash-dispatch.md` | Not applicable | **16 verbs in `NS.COMMANDS`.** Ten are the standard's reserved set, implemented entirely by LibKa0s-Slash-1.0 and documented by the standard. This addon's own surface is 6 verbs and one 4-entry sub-verb tree (`window`: list/new/delete/copy); `debug` takes 4 words, `perf` delegates its whole sub-surface to the library, and `export` takes one optional window name. The [Slash commands](#slash-commands) section carries all of it in a screen. |
| `message-bus.md` | Not applicable | **14 distinct messages**, all declared in one catalog (`core/Constants.lua` `MSG`) with the owning sender named beside each. Every payload is a flat table of one to two plain fields; none carries a handle, a curve object or a per-unit filter needing prose. The [Message bus](#message-bus) section carries sender, consumers and payload for all fourteen in one table. |
| `compat-layer.md` | **Re-measure — the trigger now fires** | **`core/Compat.lua` is 753 lines and 28 shims** (8 of them `C_DamageMeter`, 4 death-recap, plus the recap-namespace probe `RecapMembers` / `RecapAPIs` / `CallRecap`), each still a guarded namespace check around one passthrough, with no feature decisions and no state, and nothing there inspects a meter value. But the comparison point — KickCD's 490-line Compat, which ships the doc — has been passed by half again. It was 389 lines and 18 shims when this row was last measured. Raise the doc, or re-argue the trigger, through `/wow-addon:standards-audit`; it is not this register's call to make. |
| `midnight-quirks.md` (secret values) | Not applicable | The 12.0 secret-value model is this addon's **defining** constraint, not a quirk beside its main subject — so it is carried by [Taint notes](#taint-notes) (the operation lists, R1/R3, the `Combat`-not-`ChallengeMode` fact) and by [data-flow.md](data-flow.md), which is Tier 1 and mandatory here regardless. A third copy would be the one that drifts. |
| `profiles.md` | Not applicable | `settings/Profiles.lua` is 113 lines hosting **AceDBOptions-3.0's own tree** unchanged. The addon adds no profile semantics beyond the `PROFILE_CHANGED` fan-out already tabulated above and the reset-all veto already stated under [Settings schema](#settings-schema); the persisted shape is [schema.md](schema.md)'s. |
| `debug.md` | Not applicable | The console is `LibKa0s-DebugLog-1.0`'s window. `/mm debug` toggles it and takes `on` / `off`. This addon's own surface is `/mm debug diag` and `/mm debug recap` — `core/Diagnostics.lua`, ~1240 lines of print statements whose header explains itself, with no state and no options for a doc to describe. It has grown — the death-recap probe for issue #1 is the newest section, the first with a verb of its own, and the first to search the client two ways because one was measured to be unreliable — so this is the Tier 2 trigger nearest to firing; re-measure it when a section gains state or an option. |

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
| debug-logging §8 — each recompute logged "as a single summary line" | A refresh pass whose summary line is **unchanged** from the previous pass is not logged. The line is emitted on every *change*, plus a heartbeat at most every 10s carrying `(xN)` for the passes it stood for. | `throttle = 0.25` is four passes a second, each emitting an `[Aggregator]` and a `[Render]` line (three while restricted) into a buffer capped at 500 lines (§1) — **the console holds 40 seconds**. (Measured 2026-08-21 against the cap of the day; LibKa0s v1.15.0 raised it to 1500, which buys two minutes rather than forty seconds and evicts the console just the same.) A live capture showed one identity line repeating byte-identically for 41 seconds: ~160 passes, ~480 lines, one string, evicting every other line in the buffer. That is the harm §9 names ("it **evicts** it") arriving by a route §9 does not cover: §9 bounds *per-item* emission and says nothing about a pass repeating unchanged on a timer. A change is never delayed and never dropped, so nothing a reader wants is what goes missing. Implementation and reasoning: `core/DebugLogSetup.lua` → the steady-state sink. | 2026-08-21 | debug-logging gains a rule for repeating timer-driven passes — the gap is general to any Ka0s addon with a refresh timer, so the standard is the right long-term home and this row retires the day it lands. |

**One row is ratified.** The register also carried a row for a root `TODO.md`
holding work that was decided but unscheduled, adopted as a stopgap until the repo had an issue store.
That row was retired on 2026-08-11 when the backlog moved to
[GitHub issues](https://github.com/tusharsaxena/MultiMeters/issues), which is precisely the re-check
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
  cannot be, because `core/MultiMeters.lua` is the single game-event listener and already owns
  `GROUP_ROSTER_UPDATE`. The direction is inverted and the module subscribes instead. The message
  still has exactly one sender — which is what the rule asks for.
- **`METER_RESET` has two dispatch sites.** Both are inside the one-sender contract's intent: the
  game's event and the addon's own `Provider.Reset`, which must announce even if the event never
  arrives. Every handler is idempotent. Reasoned in `modules/Provider.lua`.

## Load order

`MultiMeters.toc` is the source of truth; the order is dependency, not alphabetical. Full
per-file reasoning in [module-map.md](module-map.md#load-order). The binding constraints:

1. `libs/` — Ace3, LibKa0s, LibSharedMedia, AceGUI-3.0-SharedMediaWidgets, LibDataBroker, LibDBIcon.
2. `locales/enUS.lua` — first, so `NS.L` exists for every declaration below.
3. `core/Compat.lua` **first** in the core block — it is the boundary every later file's cross-patch
   call goes through — and `core/EnvSetup.lua` immediately after it and **before
   `core/Namespace.lua`**, whose `resolveVersion()` runs at *file scope* and reads the TOC manifest
   through the `NS.Meta` seam that file publishes. A seam that loaded later would pin `NS.version` to
   `FALLBACK_VERSION` for the whole session, silently.
4. `core/MediaSetup.lua` **before `core/Constants.lua`**, which resolves `FONT_MONO` from the
   `NS.MediaFont` it publishes. It is the one seam outside the cause clause, so it is free to load
   first and has to.
5. `core/PoolSetup.lua` after the `libs/` block and **before `modules/Window.lua`**, the pool's only
   consumer. It carries no other constraint: it publishes `NS.Pool` and captures nothing.
6. `core/CoreSetup.lua` before `core/MultiMeters.lua`, whose AceConsole reclaim reads
   `NS.Util.print`; and **first of the five seams that share the cause clause**, because it defines
   `NS.LIBKA0S_MISSING`.
7. `core/PerfSetup.lua` after `core/Namespace.lua` (a nil `version` stamps every capture record `v?`)
   and **before every `modules/` file that takes `local Perf = NS.Perf` as a load-time upvalue**.
8. `defaults/Profile.lua` after `core/Constants.lua`, whose stat catalog it captures at load.
9. `modules/Format.lua` first in the module block; `modules/Row.lua` resolves `Tooltip` and
   `DrillDown` at *call* time because both load after it. `modules/Targets.lua` loads before
   `modules/Tooltip.lua`, its only caller. `modules/Export.lua` sits after `modules/DrillDown.lua`
   and is the one file in the block whose position carries no constraint at all: it captures no
   sibling at load and resolves every one of them — `Aggregator`, `Format`, `Secrets` — at call
   time, because `modules/Window.lua` loads *before* it and holds the button that calls it.
10. `settings/Schema.lua` first in the settings block — `Slash.lua` and `OptionsSetup.lua` both point
    their seams at `NS.SetByPath` / `NS.GetSetting` at load — and `settings/OptionsSetup.lua` before
    every page file, which call `NS.Helpers` members inside schema-row literals at file load.
