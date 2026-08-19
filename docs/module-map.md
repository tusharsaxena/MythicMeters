# Module map

Where each responsibility lives, what each file publishes, and what it consumes. `MythicMeters.toc`
is the source of truth for load order — check this map against it before editing.

Forty non-vendored source files: 1 locale, 11 `core/`, 1 `defaults/`, 11 `modules/`, 16 `settings/`.

Two rules govern almost every entry below, and they are worth having in mind while reading it:

- **R1** — `modules/Provider.lua` is the only caller of `C_DamageMeter` (through `core/Compat.lua`'s
  shims), and `core/Secrets.lua` is the only file that inspects a meter value. Everywhere else a
  value is an opaque handle.
- **R3** — layout is computed from config and never read back off a frame that has held a value.

Full reasoning in [data-flow.md](data-flow.md) and [ARCHITECTURE.md](ARCHITECTURE.md#taint-notes).

## Directory tree

```
MythicMeters (AceAddon; the private NS table is promoted in place — no _G.MythicMeters)
├── locales/
│   └── enUS.lua        — NS.L, with the key-is-the-string metatable fallback.
│                         Loads FIRST, ahead of core/, and bootstraps the namespace
├── core/
│   ├── Compat.lua      — every cross-patch API call: C_AddOns, C_Spell,
│                         C_SpecializationInfo, all eight C_DamageMeter reads and
│                         C_StringUtil.CreateNumericRuleFormatter. 15 shims, no logic
│   ├── Constants.lua   — NS.Constants / NS.Const: the STAT CATALOG (9 rows), the
│                         enum resolutions, the MSG bus catalog (12 names), throttle
│                         bounds, pool and row caps, the shipped mono font
│   ├── Namespace.lua   — identity (NS.PREFIX, NS.name, NS.version, NS.GRAY) and
│                         NS.NewBusTarget(), the private-bus-target factory
│   ├── State.lua       — session-only flags (debug, restricted, preview,
│                         activeWindowId) and the shared per-module cache with its
│                         one wipe seam. Nothing here is ever persisted
│   ├── Secrets.lua     — THE ONLY VALUE INSPECTOR (R1). Restriction state,
│                         IsSecret / CanAccess / CanCompare / CanCompare2,
│                         CanAccessTable, SafeIterate, SafeCount
│   ├── CoreSetup.lua   — LibKa0s-Core-1.0 seam: the secret-safe NS.PREFIX-tagged
│                         printer (NS.Print === NS.Util.print), NS.IsConcatSafe /
│                         NS.SafeToString, NS.RGBA, NS.SKIN / NS.ApplySkin /
│                         NS.MakeCloseButton, and NS.LIBKA0S_MISSING
│   ├── PerfSetup.lua   — LibKa0s-Perf-1.0 seam: NS.Perf, the 7 buckets, and the
│                         suspend/resume that makes the addon inert without a reload
│   ├── DebugLogSetup.lua — LibKa0s-DebugLog-1.0 seam: NS.DebugLog and the bare
│                         NS.Debug(tag, fmt, …) sink
│   ├── LSMPatch.lua    — registers the shipped JetBrains Mono face with LSM at file
│                         load, and the PLAYER_LOGIN fixup that hides the vendored
│                         LSM30_Border widget's 42×42 preview tile
│   ├── MythicMeters.lua — AceAddon bootstrap, the AceConsole printer reclaim, THE
│                         SINGLE GAME-EVENT LISTENER (7 events fanned onto the bus),
│                         and NS.ShouldShow — the one show ladder
│   └── Database.lua    — the AceDB instance, window-shape key-fill, the id counter,
│                         SeedWindows, the migration runner, and the ONE
│                         PROFILE_CHANGED emitter
├── defaults/
│   └── Profile.lua     — NS.defaults, NS.WINDOW_TEMPLATE, NS.DefaultWindow(). The
│                         only place a profile default is hardcoded
├── modules/
│   ├── Format.lua      — the NumericRuleFormatter instances and every text
│                         assembly. NS.Format is a CALLABLE TABLE (index → number
│                         formatter, call → chat printer); NS.Numbers and
│                         NS.NumberFormat are the same object
│   ├── Provider.lua    — THE ONLY READER OF THE METER (R1). Columns, per-source
│                         detail, session list, duration, reset, and the perf
│                         suspend that stops the addon ASKING
│   ├── Roster.lua      — group membership, pet→owner attribution, roles. Built
│                         from the unit API only; no meter value ever enters it
│   ├── Aggregator.lua  — the GUID join, group filtering, pet folding, the three
│                         sort modes, identity mode, the row cap, and the
│                         only two divisions in the addon
│   ├── WindowManager.lua — the window REGISTRY: create / delete / rename /
│                         duplicate / copy-from, lock, preview, toggle. The ONE
│                         WINDOWS_CHANGED emitter
│   ├── Window.lua      — one window instance: the anchor/visible frame pair, the
│                         layout computation (R3), the coalesced refresh loop, the
│                         row pool, the header line, the unavailable notice
│   ├── Row.lua         — one row and its cells: the StatusBar + two FontStrings,
│                         the name column's icons, the bar colors, the mouse
│                         hand-off. Nothing here looks at a number
│   ├── Targets.lua     — the enemy cross-reference: reconstructs "who did this
│                         player hit" out of the EnemyDamageTaken column, and
│                         refuses outright rather than summing secrets
│   ├── Tooltip.lua     — the per-cell spell breakdown, the all-statistics
│                         summary on a name and the Targets section, all on
│                         GameTooltip
│   ├── DrillDown.lua   — per-player per-stat breakdown rendered through the SAME
│                         row path, the back button, and the death-recap hand-off
│   ├── Visibility.lua  — the context predicate. Publishes no message and touches
│                         no frame; refuses at the source
│   └── Minimap.lua     — the LibDataBroker launcher and its LibDBIcon button
└── settings/
    ├── Schema.lua      — NS.Schema (95 rows) and the write seam: GetSetting,
    │                     SetByPath, FindSchemaRow, ApplyDefault, SchemaForPage,
    │                     ValidateSchema. Owns the window-relative path model
    ├── Slash.lua       — LibKa0s-Slash-1.0 seam: NS.COMMANDS (15 verbs), the five
    │                     schema adapters, and the five host verbs
    ├── OptionsSetup.lua — LibKa0s-Options-1.0 seam: NS.Helpers IS the library
    │                     instance, plus the panel registry and the reset-all veto
    └── Windows · Frame · Header · Rows · Bars · Text · Icons · Tooltip ·
        Visibility · Columns · Data · General · Profiles
                          — the 13 panel pages, in panel order
```

## What each file publishes and consumes

### `locales/`

| File | Owns | Publishes | Consumes |
|---|---|---|---|
| `enUS.lua` | Every user-facing string, organized page by page in panel order | `NS.L` | nothing — loads first |

`L` carries the mandated metatable fallback: a missing key returns the key itself. Never hand this
table to a LibKa0s descriptor's `L` field — it answers for *every* key and would shadow the library's
own strings entirely.

### `core/`

| File | Owns | Publishes | Consumes |
|---|---|---|---|
| `Compat.lua` | All 15 cross-patch shims. Never inspects a meter value; reading a field off a session table and passing it on is not inspection | `NS.Compat` | `_G` only |
| `Constants.lua` | The stat catalog, enum resolutions, the `MSG` catalog, timing and pool bounds, the shipped font path and its LSM key | `NS.Constants`, `NS.Const` | `_G.Enum` |
| `Namespace.lua` | Addon identity and the bus-target factory. No side effects at all | `NS.PREFIX`, `NS.GRAY`, `NS.name`, `NS.version`, `NS.FALLBACK_VERSION`, `NS.NewBusTarget` | `NS.Compat.GetAddOnMetadata` |
| `State.lua` | The four session flags, each with exactly one named writer, and `State.Cache` / `State.WipeCache` (wipes **in place**, so a module may hold its sub-table as an upvalue) | `NS.State` | `NS.Constants.MSG` |
| `Secrets.lua` | Restriction state, per-value and per-table inspection, and the two bounded walks. Correct when the whole secrets system is absent | `NS.Secrets` | `_G.C_RestrictedActions`, `_G.issecretvalue` and friends |
| `CoreSetup.lua` | The LibKa0s-Core seam and the shared "library missing" cause clause | `NS.Util.print` / `NS.Print`, `NS.Format` (printer, later rebound), `NS.IsConcatSafe`, `NS.SafeToString`, `NS.RGBA`, `NS.SKIN`, `NS.ApplySkin`, `NS.MakeCloseButton`, `NS.LIBKA0S_MISSING` | `NS.PREFIX` |
| `PerfSetup.lua` | The perf descriptor: bucket list, suspend, resume, log routing | `NS.Perf` | `NS.version`, `NS.Compat`, and `Provider` / `WindowManager` / `Visibility` at call time |
| `DebugLogSetup.lua` | The console descriptor and the debug sink | `NS.DebugLog`, `NS.Debug` | `NS.Constants.FONT_MONO`, `NS.State.debug`, `NS.Print`, `NS.SafeToString` |
| `LSMPatch.lua` | Shipped-media registration and the `LSM30_Border` widget fixup | nothing — side effects only | `NS.Constants.FONT_MONO*`, LibSharedMedia, AceGUI |
| `MythicMeters.lua` | AceAddon promotion, the printer reclaim, all 7 game-event registrations, the fan-out onto the bus, and `NS.ShouldShow` | `NS.addon`, `NS.ShouldShow`, `NS:OnInitialize` / `OnEnable` | `NS.Constants.MSG`, `NS.State`, `NS.Secrets`, `NS.Minimap`, `NS.CreateOptionsPanel`, `NS.Slash` |
| `Database.lua` | The AceDB instance, window shape key-fill, the monotonic id counter, seeding, migrations, and the AceDB profile callbacks | `NS.Database` (`GetWindows`, `FindWindow`, `NextWindowId`, `SeedWindows`, `EnsureWindowShape`), `NS.db`, `NS:InitDB`, `NS:RunMigrations` | `NS.defaults`, `NS.WINDOW_TEMPLATE`, `NS.DefaultWindow`, `NS.Constants.MSG` |

**Sends:** `MythicMeters.lua` sends `ENTERING_WORLD`, `ROSTER_CHANGED`, `ZONE_CHANGED`,
`RESTRICTION_CHANGED`, `METER_UPDATED`, `METER_SESSION`, `METER_RESET`. `State.lua` sends
`PREVIEW_CHANGED`. `Database.lua` sends `PROFILE_CHANGED`.

### `defaults/`

| File | Owns | Publishes | Consumes |
|---|---|---|---|
| `Profile.lua` | The window template (`frame`, `header`, `rows`, `bars`, `text`, `icons`, `tooltip`, `visibility`, `columns`, `data`) and the near-empty profile around it: the window array, the id counter, `enabled`, `minimap` | `NS.defaults`, `NS.WINDOW_TEMPLATE`, `NS.DefaultWindow(id, name)` | `NS.Constants` (stat catalog, font name) |

The default window ships six columns, derived from the catalog's `defaultEnabled` flags rather than
restated: Damage · Healing · Interrupts · Dispels · Avoidable Damage · Deaths.

### `modules/`

| File | Module? | Owns | Publishes | Consumes |
|---|---|---|---|---|
| `Format.lua` | plain table | The `NumericRuleFormatter` instances and the three-rung degradation ladder. No division of a meter value, anywhere | `NS.Format` (callable table), `NS.Numbers`, `NS.NumberFormat` — `Number`, `Rate`, `Duration`, `Percent`, `Invalidate` | `NS.Compat.CreateNumericRuleFormatter`, `NS.Secrets`, `NS.State.Cache("Format")`, `NS.L`. Subscribes `CONFIG_CHANGED`, `PROFILE_CHANGED` on a private bus target |
| `Provider.lua` | AceAddon | Every meter read, the memoized availability answer, and the suspend flag | `NS.Provider` — `GetColumn`, `GetSourceDetail`, `GetAvailableSessions`, `GetSessionDuration`, `IsAvailable`, `InvalidateAvailability`, `Reset`, `Suspend` / `Resume` / `IsSuspended` | `NS.Compat`, `NS.Secrets`, `NS.Constants.STAT_BY_KEY`. Subscribes `METER_RESET`, `METER_SESSION`, `ENTERING_WORLD`. **Sends `METER_RESET`** from `Provider.Reset` |
| `Roster.lua` | AceAddon | The group array, the GUID index, the pet→owner map, roles. Rebuilt lazily on first read after an invalidation | `NS.Roster` — `GetGroup`, `Get`, `IsGroupMember`, `OwnerOf`, `RoleOf`, `Refresh` | the unit API through `_G` at call time, `NS.State.Cache("Roster")`. Subscribes `ROSTER_CHANGED`, `ENTERING_WORLD`, `PROFILE_CHANGED` |
| `Aggregator.lua` | AceAddon | **Two builds**: the exact GUID join (filter, pet folding, ordering) and the identity build that replaces it while `sourceGUID` is secret. Plus the row cap and `percent` | `NS.Aggregator` — `Build`, `ApplyRowLimit`, `TestGroup` / `TestColumn` / `TestSourceDetail` | `NS.Provider`, `NS.Roster`, `NS.Secrets`, `NS.State.Cache("Aggregator")`. Subscribes `METER_RESET`, `PROFILE_CHANGED` |
| `WindowManager.lua` | AceAddon | The live instance registry and every mutation of the window list. Deep-copies on duplicate and copy-from | `NS.WindowManager` — `Resolve`, `Get`, `All`, `Init`, `Create`, `Delete`, `Rename`, `Duplicate`, `CopyFrom`, `RefreshAll`, `MarkAllDirty`, `ResetPosition(s)`, `SetLocked` / `IsLocked`, `SetPreview` / `IsPreview`, `Toggle`, `BuildListLines`, `Suspend` / `Resume`, `COPY_GROUPS` | `NS.Database`, `NS.Window`, `NS.State`, `NS.DefaultWindow`. Subscribes `PROFILE_CHANGED`. **The one `WINDOWS_CHANGED` sender** |
| `Window.lua` | plain table + prototype | One instance: the anchor/visible frame pair, `BuildLayout` (R3), `ApplyConfig`, the `OnUpdate` throttle, `Render`, `UpdateHeaderText`, `ShowNotice`, the pool | `NS.Window.New(config)` and the `WindowProto` methods | `NS.Constants`, `NS.Row`, `NS.Provider`, `NS.Aggregator`, `NS.DrillDown`, `NS.ShouldShow`, `NS.Format`, `NS.ApplySkin`. Each instance subscribes 9 messages on **its own** private bus target |
| `Row.lua` | plain table + prototype | Row and cell widgets, the cell descriptor, bar colors, icon placement, the mouse hand-off | `NS.Row.New(window)`, `NS.Row.OffsetFor(layout, index)` | `NS.Constants`, `NS.RGBA`, `NS.Format` / `NS.NumberFormat`, and `NS.Tooltip` / `NS.DrillDown` resolved at call time |
| `Targets.lua` | plain table | The enemy cross-reference. One walk over every `EnemyDamageTaken` source's spells builds **every** player's target list at once, keyed on `combatSpellDetails.unitName` and cached per session. **All-or-nothing**: one unreadable amount abandons the whole build | `NS.Targets` — `ForPlayer`, `Total`, `Invalidate` | `NS.Provider.GetColumn` / `GetSourceDetail`, `NS.Secrets`, `NS.State.Cache("Targets")`. Subscribes `METER_RESET`, `METER_SESSION`, `METER_UPDATED`, `PROFILE_CHANGED` on a private bus target |
| `Tooltip.lua` | AceAddon | Both tooltip builders, the legal-only spell sort, the "and N more" line, the Targets section, and the tooltip's own bar/font styling (including restoring the SHARED line FontStrings) | `NS.Tooltip` — `CellTooltip`, `NameTooltip`, `Hide` | `NS.Provider`, `NS.Secrets`, `NS.Numbers`, `NS.Compat.GetSpellInfo`, `NS.WINDOW_TEMPLATE`, `NS.Database.FindWindow` |
| `DrillDown.lua` | AceAddon | Per-window view state (session-only, in `State.Cache`), the spell-row contract, the back button, click routing, the death recap | `NS.DrillDown` — `GetState`, `IsActive`, `Enter`, `Exit`, `ExitAll`, `OnCellClick`, `BuildRows`, `Title`, `AcquireBackButton`, `ReleaseBackButton` | `NS.Provider`, `NS.Secrets`, `NS.Compat`, `NS.Database.FindWindow`. Subscribes `METER_RESET`, `PROFILE_CHANGED`, `WINDOWS_CHANGED`. **The one `DRILLDOWN_CHANGED` sender** |
| `Visibility.lua` | AceAddon | The context translation table and the predicate. No frame is touched and no message is sent | `NS.Visibility` — `GetContext`, `ShouldShow`, `Allows`, `Evaluate`, `Refresh`, `LastResult`, `Forget` | `NS.Database.GetWindows`, the instance API through `_G`. Subscribes `ZONE_CHANGED`, `ENTERING_WORLD`, `ROSTER_CHANGED`, `PROFILE_CHANGED` |
| `Minimap.lua` | plain table | The LDB launcher object and the LibDBIcon registration | `NS.Minimap.Init`, `NS.Minimap.Refresh` | `NS.db.profile.minimap` (owned by LibDBIcon once registered), `NS.WindowManager`, `NS.OpenOptionsPanel` |

### `settings/`

| File | Owns | Publishes | Consumes |
|---|---|---|---|
| `Schema.lua` | The 95-row schema, the window-relative path model, path memoization, the `columns` whole-array carve-out, and every validator and `onChange` | `NS.Schema`, `NS.GetSetting`, `NS.SetByPath`, `NS.FindSchemaRow`, `NS.RegisterSchemaRows`, `NS.ApplyDefault`, `NS.SchemaForPage`, `NS.ValidateSchema`, `NS.ResetPositions` | `NS.db`, `NS.State.activeWindowId`, `NS.Constants`, `NS.Helpers` and `NS.Visibility` at call time. **The one `CONFIG_CHANGED` sender** |
| `Slash.lua` | `NS.COMMANDS`, the five schema adapters pointed at the seam above, the five host verbs, and the library-absent stub | `NS.Slash` — `Register`, `OnSlash`, `PrintHelp`, `HelpRows`, `LandingRows`, `Version` | LibKa0s-Slash-1.0, `NS.WindowManager`, `NS.DebugLog`, `NS.Perf`, the schema seam |
| `OptionsSetup.lua` | The options descriptor, the page registry, the reset-all veto (`page == "profiles"`), and the library-absent stub | `NS.Helpers` (the library instance itself), `NS.CreateOptionsPanel`, `NS.OpenOptionsPanel`, `NS.RefreshOptionsPanel` | LibKa0s-Options-1.0, `NS.Schema`, `NS.Slash:LandingRows` |
| `Windows.lua` | The window picker — **the only writer of `NS.State.activeWindowId`** — and the five registry buttons plus the copy-from group filter | a page registration | `NS.WindowManager`, `NS.State.SetActiveWindow`, `NS.RefreshOptionsPanel` |
| `Frame.lua` | The Frame page (15 rows) plus the bespoke "Reset position" button | a page registration | `NS.Helpers`, `NS.WindowManager.ResetPosition` |
| `Header.lua` | The Header page (11 rows). Pure schema | a page registration | `NS.Helpers` |
| `Rows.lua` | The Rows page (10 rows). Pure schema | a page registration | `NS.Helpers` |
| `Bars.lua` | The Bars page (9 rows). Pure schema | a page registration | `NS.Helpers` |
| `Text.lua` | The Text page (10 rows). Pure schema | a page registration | `NS.Helpers` |
| `Icons.lua` | The Icons page (5 rows). Pure schema | a page registration | `NS.Helpers` |
| `Tooltip.lua` | The Tooltip page (17 rows). Pure schema | a page registration | `NS.Helpers` |
| `Visibility.lua` | The Visibility page (7 rows). Pure schema | a page registration | `NS.Helpers` |
| `Columns.lua` | The column editor — add, remove, reorder, width, show-bar. **No schema rows**: every write hands the seam a freshly built whole array, and every mutation re-checks combat | a page registration | `NS.SetByPath("window.columns", …)`, `NS.Constants.STATS` |
| `Data.lua` | The Data page (6 rows) plus the "Reset meter data" confirmation, which routes to `NS.Provider.Reset` rather than to the Compat shim | a page registration | `NS.Helpers`, `NS.Provider.Reset` |
| `General.lua` | The General page (4 rows) plus two session-only checkboxes (preview, debug console) and the reset-everything confirmation | a page registration | `NS.Helpers`, `NS.State`, `NS.DebugLog` |
| `Profiles.lua` | The AceDBOptions profile tree, hosted in this addon's canvas. **The one place `AceConfigDialog` is permitted**, and the one page vetoed from reset-all | a page registration | AceDBOptions-3.0, AceConfigDialog-3.0 |

Schema rows total 95 across 11 page keys. `columns` and `profiles` are pages with zero schema rows —
both are bespoke by necessity, and both say why in their file headers.

## Load order

`MythicMeters.toc` is authoritative. The order is dependency, not alphabetical.

1. **`libs/`** — LibStub, CallbackHandler, AceAddon/Event/Timer/DB/DBOptions/Console/Config/GUI,
   LibKa0s, LibSharedMedia, AceGUI-3.0-SharedMediaWidgets, LibDataBroker, LibDBIcon.
2. **`locales/enUS.lua`** — first, so `NS.L` exists for every declaration below.
3. **`core/`**, in this order and for these reasons:
   1. `Compat.lua` — **first**, because `Namespace.lua` reads the TOC manifest through it on the very
      next line.
   2. `Constants.lua` — before everything that reads `NS.Constants.*` without an existence check.
      Must stay free of logic.
   3. `Namespace.lua` — resolves `NS.version` at load; everything after may read it.
   4. `State.lua` — after `Constants` (the preview toggle names a message from the catalog).
   5. `Secrets.lua` — before any consumer. Deliberately carries **no** perf bracket.
   6. `CoreSetup.lua` — after `Constants` (for the prefix), before `MythicMeters.lua` (whose
      AceConsole reclaim reads `NS.Util.print`), and **first of the five LibKa0s seams**, because
      `NS.LIBKA0S_MISSING` is defined here.
   7. `PerfSetup.lua` — after `Namespace` (a nil `version` stamps every capture record `v?`) and
      **before every `modules/` file that takes `local Perf = NS.Perf` at load**.
   8. `DebugLogSetup.lua` — after `Constants`, `State` and `CoreSetup`.
   9. `LSMPatch.lua` — before `defaults/Profile.lua` names the font at load.
   10. `MythicMeters.lua` — after all five setup files; promotes `NS` into the AceAddon object.
   11. `Database.lua` — after `State`, before `OnInitialize` runs. Reads `NS.defaults` at *call*
       time, because `defaults/` loads later.
4. **`defaults/Profile.lua`** — after `core/Constants.lua`, whose stat catalog it captures at load.
5. **`modules/`** — `Format` first (nothing reads another module, and `Row` and `Tooltip` both format
   on their first render), then `Provider` → `Roster` → `Aggregator` → `WindowManager` → `Window` →
   `Row` → `Targets` → `Tooltip` → `DrillDown` → `Visibility` → `Minimap`. `Row.lua` loads before
   `Tooltip.lua` and `DrillDown.lua` and therefore resolves both at *call* time. `Targets.lua` loads
   before `Tooltip.lua`, which is its only caller, and resolves the provider at *call* time for the
   same reason `Tooltip.lua` does.
6. **`settings/`** — last, and `Schema.lua` first inside it: `Slash.lua` and `OptionsSetup.lua` both
   point their seams at `NS.SetByPath` / `NS.GetSetting` / `NS.FindSchemaRow` / `NS.ApplyDefault` at
   load. `OptionsSetup.lua` must precede every page file, because the pages call `NS.Helpers` members
   inside schema-row literals at file load.

## AceAddon lifecycle

`core/MythicMeters.lua` calls `AceAddon-3.0:NewAddon(NS, addonName, "AceEvent-3.0", "AceTimer-3.0",
"AceConsole-3.0")`. `NewAddon` promotes the table it is handed, so **`NS` is the addon object** —
there is no `_G.MythicMeters` and no rebind. `NS.addon` is published anyway, so a test or the perf
descriptor can name "the AceAddon object" without assuming the promotion happened in place.

Immediately after `NewAddon`, `NS.Print` is reclaimed from AceConsole's mixin by re-pointing it at
`NS.Util.print`. The two must remain the **same function object**, not two lookalike wrappers.

**`NS:OnInitialize`** (on `ADDON_LOADED`), in order:

1. `self:InitDB()` — builds AceDB against `NS.defaults` with the shared `"Default"` profile
   (the third argument is `true`; omitting it silently produces per-character profiles), then
   migrates and seeds.
2. `self:RunMigrations()` — idempotent after step 1, called explicitly so the lifecycle reads as the
   standard's four steps.
3. `NS.Minimap.Init()` — **after** `InitDB`, because LibDBIcon stores the button's position inside
   `NS.db.profile.minimap`.
4. `NS.CreateOptionsPanel()` — schema validation, the parent category, and the queued page builders.
5. `NS.Slash:Register()` — `/mm` and `/mythicmeters`, through AceConsole. If the settings layer never
   loaded, both verbs are claimed anyway and say so rather than going silent.

**`NS:OnEnable`** registers the seven game events and seeds `NS.State.restricted` from
`NS.Secrets.IsRestricted()` — a `/reload` taken mid-pull re-enables the addon inside an already
active restriction, and there is no second `ADDON_RESTRICTION_STATE_CHANGED` edge to catch.

**Module `OnEnable`** hooks then run: `Provider`, `Roster`, `Aggregator`, `Tooltip`, `DrillDown`,
`Visibility` each subscribe to their bus messages; `WindowManager:OnEnable` calls `Init()`, which
builds one `NS.Window.New(cfg)` instance per stored config. Windows are re-pointed with `SetConfig`
on a profile swap rather than torn down and rebuilt — a rebuild is a flicker the player sees.

## Bus-target discipline

CallbackHandler keys callbacks by `(message, target)`, so two receivers of one message registered on
the same object silently clobber each other and only the last registrant fires. This addon is
unusually exposed: every window subscribes to the same refresh messages, and there can be many
windows.

- AceAddon modules (`Provider`, `Roster`, `Aggregator`, `WindowManager`, `Tooltip`, `DrillDown`,
  `Visibility`) are their own AceEvent targets.
- Everything else — each `Window` instance, `modules/Format.lua` — owns a private target from
  `NS.NewBusTarget()`.
- Nothing registers on the shared addon object.
