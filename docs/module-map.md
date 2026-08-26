# Module map

Where each responsibility lives, what each file publishes, and what it consumes. `MultiMeters.toc`
is the source of truth for load order — check this map against it before editing.

Forty-eight non-vendored source files: 1 locale, 15 `core/`, 1 `defaults/`, 15 `modules/`,
16 `settings/`.

Two rules govern almost every entry below, and they are worth having in mind while reading it:

- **R1** — `modules/Provider.lua` is the only caller of `C_DamageMeter` (through `core/Compat.lua`'s
  shims), and `core/Secrets.lua` is the only file that inspects a meter value. Everywhere else a
  value is an opaque handle.
- **R3** — layout is computed from config and never read back off a frame that has held a value.

Full reasoning in [data-flow.md](data-flow.md) and [ARCHITECTURE.md](ARCHITECTURE.md#taint-notes).

## Directory tree

```
MultiMeters (AceAddon; the private NS table is promoted in place — no _G.MultiMeters)
├── locales/
│   └── enUS.lua        — NS.L, with the key-is-the-string metatable fallback.
│                         Loads FIRST, ahead of core/, and bootstraps the namespace
├── core/
│   ├── Compat.lua      — every cross-patch API call: C_Spell,
│                         C_SpecializationInfo, all eight C_DamageMeter reads and
│                         C_StringUtil.CreateNumericRuleFormatter. 28 shims, no logic
│   ├── EnvSetup.lua    — the LibKa0s-Env seam: NS.Meta / NS.Version, the TOC-manifest
│                         reader Compat used to own. BEFORE Namespace.lua, which
│                         resolves NS.version at file scope
│   ├── Constants.lua   — NS.Constants / NS.Const: the STAT CATALOG (9 rows), the
│                         per-stat palette (STAT_COLORS + STAT_DIM, worn by both
│                         a bar and a name-tooltip line), the off-catalog reads
│                         (EnemyDamageTaken — read, never a column), the
│                         enum resolutions, the MSG bus catalog (14 names), throttle
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
│   ├── PerfSetup.lua   — LibKa0s-Perf-1.0 seam: NS.Perf, the 8 buckets, and the
│                         suspend/resume that makes the addon inert without a reload
│   ├── DebugLogSetup.lua — LibKa0s-DebugLog-1.0 seam: NS.DebugLog, the bare
│                         NS.Debug(tag, fmt, …) sink, and NS.DebugSteady — the
│                         same sink for a pass that repeats on a timer
│   ├── PoolSetup.lua   — LibKa0s-Pool-1.0 seam: NS.Pool, the window row pool's
│                         free/active halves. After libs/, BEFORE modules/Window.lua,
│                         its only consumer. RANK STABILITY IS THE LIBRARY'S — minor 3
│                         parks the active set backward — and the degraded fallback
│                         here parks the same way rather than flickering
│   ├── MediaSetup.lua  — the LibKa0s-Media seam: NS.Icon / NS.MediaFont, and the one
│   │                     call that registers the library's font with LSM. Loads BEFORE
│   │                     Constants, which resolves FONT_MONO from it
│   ├── LSMPatch.lua    — the PLAYER_LOGIN fixup that hides the vendored LSM30_Border
│                         widget's 42×42 preview tile. It registered the shipped font
│                         too until the face moved into the LibKa0s payload
│   ├── MultiMeters.lua — AceAddon bootstrap, the AceConsole printer reclaim, THE
│                         SINGLE GAME-EVENT LISTENER (21 events, all but one
│                         fanned onto the bus), and NS.ShouldShow — the one show
│                         ladder
│   ├── Database.lua    — the AceDB instance, window-shape key-fill, the id counter,
│                         SeedWindows, the migration runner, and the ONE
│                         PROFILE_CHANGED emitter
│   └── Diagnostics.lua — `/mm debug diag`: the sectioned report a player pastes into
│                         a bug report. Reads modules at CALL time, owns no state,
│                         and every section is pcall-wrapped so one broken probe
│                         cannot take the report down
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
│   ├── Feign.lua       — the one source row the addon throws away. C_DamageMeter
│   │                     gives a Feign Death a valid deathRecapID, so a hunter's
│   │                     feign is reported as a death; this holds the GUIDs that
│   │                     are feigning. Cannot run mid-pull -- see its header.
│   ├── Aggregator.lua  — the GUID join, group filtering, pet folding, the three
│                         sort modes, identity mode, the row cap, and the
│                         only two divisions in the addon
│   ├── WindowManager.lua — the window REGISTRY: create / delete / rename /
│                         duplicate / copy-from, lock, preview, toggle. The ONE
│                         WINDOWS_CHANGED emitter
│   ├── Window.lua      — one window instance: the anchor/visible frame pair, the
│                         layout computation (R3), the coalesced refresh loop, the
│                         row pool, the header line, the unavailable notice
│   ├── HeaderControls.lua — the window's own control strip: which controls exist,
│                         where each sits (right-to-left, a hidden one yields its
│                         slot), the TGA → Blizzard atlas → ASCII art ladder, and
│                         when the set fades. Built here with or without LibKa0s
│   ├── Row.lua         — one row and its cells: the StatusBar + two FontStrings,
│                         the name column's icons, the bar colors, the mouse
│                         hand-off. Nothing here looks at a number
│   ├── Targets.lua     — the enemy cross-reference: reconstructs "who did this
│                         player hit" out of the EnemyDamageTaken data — which is
│                         read, never a column of this grid (issue #2) — and
│                         refuses outright rather than summing secrets
│   ├── Tooltip.lua     — the per-cell spell breakdown, the all-statistics
│                         summary on a name and the Targets section, all on
│                         GameTooltip
│   ├── DrillDown.lua   — per-player per-stat breakdown rendered through the SAME
│                         row path, right-click-to-leave, and the death-recap hand-off
│   ├── Export.lua      — a segment as CSV or as ranked chat lines: the pure
│                         serializers, the modal that drives them, and its own
│                         copy-paste window. Refuses outright while restricted
│   ├── Visibility.lua  — the context predicate. Publishes no message and touches
│                         no frame; refuses at the source
│   └── Minimap.lua     — the LibDataBroker launcher and its LibDBIcon button
└── settings/
    ├── Schema.lua      — NS.Schema (124 rows) and the write seam: GetSetting,
    │                     SetByPath, FindSchemaRow, ApplyDefault, SchemaForPage,
    │                     ValidateSchema. Owns the window-relative path model
    ├── Slash.lua       — LibKa0s-Slash-1.0 seam: NS.COMMANDS (16 verbs), the five
    │                     schema adapters, and the six host verbs
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
| `Compat.lua` | All 28 cross-patch shims — the TOC-manifest reader is no longer among them; it moved to `EnvSetup.lua`. Never inspects a meter value; reading a field off a session table and passing it on is not inspection | `NS.Compat` | `_G` only |
| `Constants.lua` | The stat catalog, the per-stat palette (`STAT_COLORS`, worn unchanged by both a bar and a name-tooltip line, plus the `STAT_DIM` factor), the two stat lookups — `STAT_BY_KEY` ("may this be a column") and `READABLE_STAT_BY_KEY` ("may this be read", the catalog plus `OFF_CATALOG_STATS`), enum resolutions, the `MSG` catalog, timing and pool bounds, the monospace font path (resolved from the LibKa0s payload, falling back to the client font) and its LSM key | `NS.Constants`, `NS.Const` | `_G.Enum`, `NS.MediaFont` |
| `EnvSetup.lua` | The LibKa0s-Env seam: this addon's TOC manifest, and the one place the manifest-then-constant version pair is resolved. Repeats the reader ladder itself on a degraded install, so an install missing LibKa0s still reports its packaged version | `NS.Meta`, `NS.Version` | `LibKa0s-Env-1.0`, `NS.version` at call time. Owns no state and registers no event |
| `Namespace.lua` | Addon identity and the bus-target factory. No side effects at all | `NS.PREFIX`, `NS.GRAY`, `NS.name`, `NS.version`, `NS.FALLBACK_VERSION`, `NS.NewBusTarget` | `NS.Meta` |
| `State.lua` | The four session flags, each with exactly one named writer, and `State.Cache` / `State.WipeCache` (wipes **in place**, so a module may hold its sub-table as an upvalue) | `NS.State` | `NS.Constants.MSG` |
| `Secrets.lua` | Restriction state, per-value and per-table inspection, and the two bounded walks. Correct when the whole secrets system is absent | `NS.Secrets` | `_G.C_RestrictedActions`, `_G.issecretvalue` and friends |
| `MediaSetup.lua` | The LibKa0s-Media seam: where the icons and the monospace face come from, and the one call that registers the face with LibSharedMedia. Answers `nil` for both on a degraded install, which is what sends the header down its art ladder | `NS.Icon`, `NS.MediaFont` | `LibKa0s-Media-1.0`, LibSharedMedia. Owns no state and registers no event |
| `CoreSetup.lua` | The LibKa0s-Core seam and the shared "library missing" cause clause. `NS.MakeCloseButton` is the one member WRAPPED rather than handed over: it supplies the addon folder name the library needs to build a texture path for its own close icon | `NS.Util.print` / `NS.Print`, `NS.Format` (printer, later rebound), `NS.IsConcatSafe`, `NS.SafeToString`, `NS.RGBA`, `NS.SKIN`, `NS.ApplySkin`, `NS.MakeCloseButton`, `NS.LIBKA0S_MISSING` | `NS.PREFIX` |
| `PerfSetup.lua` | The perf descriptor: bucket list, suspend, resume, log routing | `NS.Perf` | `NS.Version`, and `Provider` / `WindowManager` / `Visibility` at call time |
| `DebugLogSetup.lua` | The console descriptor (including `addonName`, which is what makes the console's own close/copy/clear draw the collection's art), the debug sink, and the steady-state sink a timer-driven pass logs through | `NS.DebugLog`, `NS.Debug`, `NS.DebugSteady`, `NS.DebugSteadyReset` | `NS.Constants.FONT_MONO`, `NS.State.debug`, `NS.Print`, `NS.SafeToString` |
| `PoolSetup.lua` | The LibKa0s-Pool seam: the free/active halves of the window row pool. What stays in `modules/Window.lua` is what the library holds no opinion about — `pool.all` (every row ever built, so a **parked** row is re-laid-out too) and batch growth, folded into the `Acquire` factory closure. The degraded fallback is the same three members locally, parking **backward** exactly as `LibKa0s-Pool-1.0` minor 3 does; a forward-parked degraded install is the rank flicker back | `NS.Pool` | `LibKa0s-Pool-1.0`. Owns no state and registers no event |
| `LSMPatch.lua` | The `LSM30_Border` widget fixup, and nothing else since the shipped font moved into the LibKa0s payload | nothing — side effects only | LibSharedMedia, AceGUI |
| `MultiMeters.lua` | AceAddon promotion, the printer reclaim, all 21 game-event registrations, the fan-out onto the bus, and `NS.ShouldShow` | `NS.addon`, `NS.ShouldShow`, `NS:OnInitialize` / `OnEnable` | `NS.Constants.MSG`, `NS.State`, `NS.Secrets`, `NS.Minimap`, `NS.CreateOptionsPanel`, `NS.Slash` |
| `Database.lua` | The AceDB instance, window shape key-fill, the monotonic id counter, seeding, migrations, and the AceDB profile callbacks | `NS.Database` (`GetWindows`, `FindWindow`, `NextWindowId`, `SeedWindows`, `EnsureWindowShape`), `NS.db`, `NS:InitDB`, `NS:RunMigrations` | `NS.defaults`, `NS.WINDOW_TEMPLATE`, `NS.DefaultWindow`, `NS.Constants.MSG` |
| `Diagnostics.lua` | The `/mm debug diag` report: atlas probes, the formatter ladder, visibility, header, name column, cells, tooltip font and width, the Targets cross-reference, and the provider-order probe. Every section is `pcall`-wrapped, and nothing here inspects a meter value | `NS.Diagnostics` (`Report`) | `NS.DebugLog`, `NS.Print`, `NS.Provider`, `NS.Constants.STATS`, `NS.Database`, `NS.Secrets`, `NS.WindowManager` |

**Sends:** `MultiMeters.lua` sends `ENTERING_WORLD`, `ROSTER_CHANGED`, `ZONE_CHANGED`,
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
| `Feign.lua` | AceAddon | The set of GUIDs believed to be feigning rather than dead. `C_DamageMeter` hands a Feign Death a valid `deathRecapID`, so the Deaths column counts it. **Cannot run while restricted**: it joins a plain GUID against `sourceGUID`, which is secret for the whole of a pull | `NS.Feign` — `Note`, `IsFeigned`, `Prune`, `Clear` | the unit API through `_G` at call time, `NS.Roster.GetGroup`, `NS.Secrets`. Subscribes `METER_RESET`, `ENTERING_WORLD`, `ROSTER_CHANGED`. Fed by `core/MultiMeters.lua`'s `UNIT_SPELLCAST_SUCCEEDED` handler, which owns the only game event |
| `Aggregator.lua` | AceAddon | **Two builds**: the exact GUID join (filter, pet folding, ordering) and the identity build that replaces it while `sourceGUID` is secret. Plus the row cap and `percent` | `NS.Aggregator` — `Build`, `ApplyRowLimit`, `TestGroup` / `TestColumn` / `TestSourceDetail` | `NS.Provider`, `NS.Roster`, `NS.Secrets`, `NS.State.Cache("Aggregator")`. Subscribes `METER_RESET`, `PROFILE_CHANGED` |
| `WindowManager.lua` | AceAddon | The live instance registry and every mutation of the window list. Deep-copies on duplicate and copy-from | `NS.WindowManager` — `Resolve`, `Get`, `All`, `Init`, `Create`, `Delete`, `Rename`, `Duplicate`, `CopyFrom`, `RefreshAll`, `MarkAllDirty`, `ResetPosition(s)`, `SetLocked` / `IsLocked`, `SetPreview` / `IsPreview`, `Toggle`, `BuildListLines`, `Suspend` / `Resume`, `COPY_GROUPS` | `NS.Database`, `NS.Window`, `NS.State`, `NS.DefaultWindow`. Subscribes `PROFILE_CHANGED`. **The one `WINDOWS_CHANGED` sender** |
| `Window.lua` | plain table + prototype | One instance: the anchor/visible frame pair, `BuildLayout` (R3), `ApplyConfig`, the `OnUpdate` throttle, `Render`, `UpdateHeaderText`, `ShowNotice`, the pool | `NS.Window.New(config)`, `NS.HeaderStyle(window)` (the header's font and colour, read by `modules/HeaderControls.lua`), and the `WindowProto` methods — including `TitleRowTop(h)`, the one centre line the title, the session line and the control strip are all placed against | `NS.Constants`, `NS.Row`, `NS.Provider`, `NS.Aggregator`, `NS.DrillDown`, `NS.ShouldShow`, `NS.Format`, `NS.ApplySkin`. Each instance subscribes 10 messages on **its own** private bus target |
| `HeaderControls.lua` | plain table | The window's own control strip: which controls exist, where each sits (right-to-left, indexed, a hidden one yields its slot), what art each draws from (our TGA -> Blizzard atlas -> ASCII) and when the set fades | `NS.HeaderControls` — `Attach`, `Apply`, `HookHover`, `WidthUsed` | `NS.Compat.FirstTexture` / `FirstAtlas`, `NS.SetByPath`, `NS.HeaderStyle`, `NS.ShowResetMeterData`. Every control in the strip is built here, close included, so the strip is the same seven controls with or without LibKa0s. Owns no state and registers no event |
| `Row.lua` | plain table + prototype | Row and cell widgets, the cell descriptor, bar colors, icon placement, the mouse hand-off | `NS.Row.New(window)`, `NS.Row.OffsetFor(layout, index)` | `NS.Constants`, `NS.RGBA`, `NS.Format` / `NS.NumberFormat`, and `NS.Tooltip` / `NS.DrillDown` resolved at call time |
| `Targets.lua` | plain table | The enemy cross-reference. One walk over every `EnemyDamageTaken` source's spells builds **every** player's target list at once, keyed on `combatSpellDetails.unitName` and cached per session. **All-or-nothing**: one unreadable amount abandons the whole build | `NS.Targets` — `ForPlayer`, `Total`, `Invalidate` | `NS.Provider.GetColumn` / `GetSourceDetail`, `NS.Secrets`, `NS.State.Cache("Targets")`. Subscribes `METER_RESET`, `METER_SESSION`, `METER_UPDATED`, `PROFILE_CHANGED` on a private bus target |
| `Tooltip.lua` | AceAddon | Both tooltip builders, the legal-only spell sort, the "and N more" line, the Targets section, and the tooltip's own bar/font styling (including restoring the SHARED line FontStrings) | `NS.Tooltip` — `CellTooltip`, `NameTooltip`, `Hide` | `NS.Provider`, `NS.Secrets`, `NS.Numbers`, `NS.Compat.GetSpellInfo`, `NS.WINDOW_TEMPLATE`, `NS.Database.FindWindow` |
| `DrillDown.lua` | AceAddon | Per-window view state (session-only, in `State.Cache`), the spell-row contract, click routing, the death recap | `NS.DrillDown` — `GetState`, `IsActive`, `Enter`, `Exit`, `ExitAll`, `OnCellClick`, `BuildRows`, `Title`, `AcquireBackButton`, `ReleaseBackButton` | `NS.Provider`, `NS.Secrets`, `NS.Compat`, `NS.Database.FindWindow`. Subscribes `METER_RESET`, `PROFILE_CHANGED`, `WINDOWS_CHANGED`. **The one `DRILLDOWN_CHANGED` sender** |
| `Export.lua` | plain table | The two serializers and the surface that drives them: `HeaderName`, `CsvField` and `Columns` derive the CSV shape from the stat catalog rather than restating it; `SessionConfig` builds the synthetic window config the aggregator is asked with; the modal, its three selectors — `LibKa0s-Widgets-1.0` dropdowns since the collection grew a shared one — and the copy window are built lazily on the first `Open` and reused forever. **Refuses entire while the Combat restriction is active** — `tostring` is not a permitted operation on a secret | `NS.Export` — `Available`, `HeaderName`, `CsvField`, `Columns`, `SessionConfig`, `Build`, `SessionLabel`, `ResolveMetric`, `CSV`, `ChatLines`, `ResolveChannel`, `Send`, `Open` | `NS.Aggregator.Build`, `NS.Secrets`, `NS.Format`, `NS.Constants` (`STATS`, `STAT_BY_KEY`, `MAX_ROWS`, `EXPORT_CHANNELS`, `EXPORT_CHANNEL_BY_KEY`, `EXPORT_AUTO_ORDER`, `FONT_MONO`), `NS.GetSetting` / `NS.SetByPath`, `NS.ApplySkin`, `NS.MakeCloseButton`, `NS.Compat.OpenContextMenu`, `NS.NewBusTarget`, `NS.Constants.MSG`, and `LibKa0s-Widgets-1.0` looked up directly — the one library this file reaches for itself rather than through a `core/*Setup.lua` seam, because the widget is built lazily inside `Open` rather than wired at load; it calls `W.CloseMenu()` from the modal's `OnHide`, since the popup is process-wide and the modal's own `Hide` does not reach it. Subscribes exactly one message — `RESTRICTION_CHANGED`, on a private target taken with the modal frame, so an open dialog greys itself when a pull starts — and sends none |
| `Visibility.lua` | AceAddon | The context translation table and the predicate: context first, then the hide-shaped vetoes, then the two combat rules. No frame is touched and no message is sent | `NS.Visibility` — `GetContext`, `ShouldShow`, `Allows`, `Evaluate`, `Refresh`, `LastResult`, `Forget` | `NS.Database.GetWindows`, the instance and player-state APIs through `_G`, and `NS.Compat` for the delve / skyriding / housing probes. Subscribes `ZONE_CHANGED`, `ENTERING_WORLD`, `ROSTER_CHANGED`, `COMBAT_CHANGED`, `PLAYER_STATE_CHANGED`, `PROFILE_CHANGED` — for the Evaluate pass and its debug line only; the window re-runs the ladder off the same two messages, because this module publishes nothing |
| `Minimap.lua` | plain table | The LDB launcher object and the LibDBIcon registration | `NS.Minimap.Init`, `NS.Minimap.Refresh` | `NS.db.profile.minimap` (owned by LibDBIcon once registered), `NS.WindowManager`, `NS.OpenOptionsPanel` |

### `settings/`

| File | Owns | Publishes | Consumes |
|---|---|---|---|
| `Schema.lua` | The 124-row schema, the window-relative path model, path memoization, the `columns` whole-array carve-out, and every validator and `onChange` | `NS.Schema`, `NS.GetSetting`, `NS.SetByPath`, `NS.FindSchemaRow`, `NS.RegisterSchemaRows`, `NS.ApplyDefault`, `NS.SchemaForPage`, `NS.ValidateSchema`, `NS.ResetPositions` | `NS.db`, `NS.State.activeWindowId`, `NS.Constants`, `NS.Helpers` and `NS.Visibility` at call time. **The one `CONFIG_CHANGED` sender** |
| `Slash.lua` | `NS.COMMANDS`, the five schema adapters pointed at the seam above, the six host verbs, and the library-absent stub | `NS.Slash` — `Register`, `OnSlash`, `PrintHelp`, `HelpRows`, `LandingRows`, `Version` | LibKa0s-Slash-1.0, `NS.WindowManager`, `NS.DebugLog`, `NS.Perf`, `NS.Export`, the schema seam |
| `OptionsSetup.lua` | The options descriptor, the page registry, the reset-all veto (`page == "profiles"`), and the library-absent stub | `NS.Helpers` (the library instance itself), `NS.CreateOptionsPanel`, `NS.OpenOptionsPanel`, `NS.RefreshOptionsPanel` | LibKa0s-Options-1.0, `NS.Schema`, `NS.Slash:LandingRows` |
| `Windows.lua` | The window picker — **the only writer of `NS.State.activeWindowId`** — and the five registry buttons plus the copy-from group filter | a page registration | `NS.WindowManager`, `NS.State.SetActiveWindow`, `NS.RefreshOptionsPanel` |
| `Frame.lua` | The Frame page (26 rows) plus the bespoke "Reset position" button | a page registration | `NS.Helpers`, `NS.WindowManager.ResetPosition` |
| `Header.lua` | The Header page (16 rows). Pure schema | a page registration | `NS.Helpers` |
| `Rows.lua` | The Rows page (10 rows). Pure schema | a page registration | `NS.Helpers` |
| `Bars.lua` | The Bars page (9 rows). Pure schema | a page registration | `NS.Helpers` |
| `Text.lua` | The Text page (11 rows). Pure schema | a page registration | `NS.Helpers` |
| `Icons.lua` | The Icons page (3 rows). Pure schema | a page registration | `NS.Helpers` |
| `Tooltip.lua` | The Tooltip page (18 rows). Pure schema | a page registration | `NS.Helpers` |
| `Visibility.lua` | The Visibility page (17 rows across three groups — where, extra rules, combat). Pure schema | a page registration | `NS.Helpers` |
| `Columns.lua` | The column editor — add, remove, reorder, width, show-bar. **No schema rows**: every write hands the seam a freshly built whole array, and every mutation re-checks combat | a page registration | `NS.SetByPath("window.columns", …)`, `NS.Constants.STATS` |
| `Data.lua` | The Data page (6 rows) plus the "Reset meter data" confirmation, which routes to `NS.Provider.Reset` rather than to the Compat shim | a page registration | `NS.Helpers`, `NS.Provider.Reset` |
| `General.lua` | The General page (7 rows): the master enable, the minimap toggle, the two session-only checkboxes (test mode, debug console) and the three addon-wide export preferences — plus the reset-everything confirmation | a page registration | `NS.Helpers`, `NS.State`, `NS.DebugLog` |
| `Profiles.lua` | The AceDBOptions profile tree, hosted in this addon's canvas. **The one place `AceConfigDialog` is permitted**, and the one page vetoed from reset-all | a page registration | AceDBOptions-3.0, AceConfigDialog-3.0 |

Schema rows total 124 across 11 page keys. `columns` and `profiles` are pages with zero schema rows —
both are bespoke by necessity, and both say why in their file headers.

## Load order

`MultiMeters.toc` is authoritative. The order is dependency, not alphabetical.

1. **`libs/`** — LibStub, CallbackHandler, AceAddon/Event/Timer/DB/DBOptions/Console/Config/GUI,
   LibKa0s, LibSharedMedia, AceGUI-3.0-SharedMediaWidgets, LibDataBroker, LibDBIcon.
2. **`locales/enUS.lua`** — first, so `NS.L` exists for every declaration below.
3. **`core/`**, in this order and for these reasons:
   1. `Compat.lua` — first in the block, though nothing now depends on that: the TOC-manifest
      reader that used to make it load-bearing has moved to `EnvSetup.lua`.
   2. `EnvSetup.lua` — **before `Namespace.lua`**, which calls the `NS.Meta` it publishes at file
      scope. A seam loading later would neither raise nor log; `NS.version` would simply be the
      hardcoded `FALLBACK_VERSION` for the session. Load-bearing, not conventional.
   3. `Constants.lua` — before everything that reads `NS.Constants.*` without an existence check.
      Must stay free of logic.
   4. `Namespace.lua` — resolves `NS.version` at load; everything after may read it.
   5. `State.lua` — after `Constants` (the preview toggle names a message from the catalog).
   6. `Secrets.lua` — before any consumer. Deliberately carries **no** perf bracket.
   7. `CoreSetup.lua` — after `Constants` (for the prefix), before `MultiMeters.lua` (whose
      AceConsole reclaim reads `NS.Util.print`), and **first of the LibKa0s seams that report a
      degraded install**, because `NS.LIBKA0S_MISSING` is defined here. `EnvSetup.lua` and
      `MediaSetup.lua` are exempt: neither touches the clause, and both are pinned earlier by a
      file-scope reader.
   8. `PerfSetup.lua` — after `Namespace` (a nil `version` stamps every capture record `v?`) and
      **before every `modules/` file that takes `local Perf = NS.Perf` at load**.
   9. `DebugLogSetup.lua` — after `Constants`, `State` and `CoreSetup`.
   10. `MediaSetup.lua` — **before `Constants.lua`**, which resolves `FONT_MONO` from `NS.MediaFont`,
      and therefore before `defaults/Profile.lua` names the font at load. This is one of the few
      TOC positions in `core/` that is load-bearing rather than conventional.
   11. `PoolSetup.lua` — after the `libs/` block and **before `modules/Window.lua`**, the pool's
      only consumer. It carries no other constraint: it publishes `NS.Pool` and captures nothing.
   12. `LSMPatch.lua` — unconstrained now that it only patches an AceGUI widget at PLAYER_LOGIN.
   13. `MultiMeters.lua` — after every setup file; promotes `NS` into the AceAddon object.
   14. `Database.lua` — after `State`, before `OnInitialize` runs. Reads `NS.defaults` at *call*
       time, because `defaults/` loads later.
   15. `Diagnostics.lua` — **last in the block, and deliberately unconstrained.** It reads every
       module at *call* time and owns no state, so nothing depends on where it loads.
4. **`defaults/Profile.lua`** — after `core/Constants.lua`, whose stat catalog it captures at load.
5. **`modules/`** — `Format` first (nothing reads another module, and `Row` and `Tooltip` both format
   on their first render), then `Provider` → `Roster` → `Feign` → `Aggregator` → `WindowManager` →
   `Window` → `HeaderControls` → `Row` → `Targets` → `Tooltip` → `DrillDown` → `Export` →
   `Visibility` → `Minimap`. `Row.lua` loads
   before `Tooltip.lua` and `DrillDown.lua` and therefore resolves both at *call* time. `Targets.lua`
   loads before `Tooltip.lua`, which is its only caller, and resolves the provider at *call* time for
   the same reason `Tooltip.lua` does. `Export.lua` is the one entry here under **no** constraint at
   all: its in-addon caller — `modules/Window.lua`'s header glyph — loads *before* it, so it can
   capture no sibling at load and looks every one of them up when a button is clicked instead. It
   sits after `DrillDown.lua` because that is where the reading order puts it, the last of the things
   a window does with its rows, and not because anything would break elsewhere.
6. **`settings/`** — last, and `Schema.lua` first inside it: `Slash.lua` and `OptionsSetup.lua` both
   point their seams at `NS.SetByPath` / `NS.GetSetting` / `NS.FindSchemaRow` / `NS.ApplyDefault` at
   load. `OptionsSetup.lua` must precede every page file, because the pages call `NS.Helpers` members
   inside schema-row literals at file load.

## AceAddon lifecycle

`core/MultiMeters.lua` calls `AceAddon-3.0:NewAddon(NS, addonName, "AceEvent-3.0", "AceTimer-3.0",
"AceConsole-3.0")`. `NewAddon` promotes the table it is handed, so **`NS` is the addon object** —
there is no `_G.MultiMeters` and no rebind. `NS.addon` is published anyway, so a test or the perf
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
5. `NS.Slash:Register()` — `/mm` and `/multimeters`, through AceConsole. If the settings layer never
   loaded, both verbs are claimed anyway and say so rather than going silent.

**`NS:OnEnable`** registers the seven game events and seeds `NS.State.restricted` from
`NS.Secrets.IsRestricted()` — a `/reload` taken mid-pull re-enables the addon inside an already
active restriction, and there is no second `ADDON_RESTRICTION_STATE_CHANGED` edge to catch.

**Module `OnEnable`** hooks then run: `Provider`, `Roster`, `Aggregator`, `Tooltip`, `DrillDown`,
`Visibility` each subscribe to their bus messages; `WindowManager:OnEnable` calls `Init()`, which
builds one `NS.Window.New(cfg)` instance per stored config. Windows are re-pointed with `SetConfig`
on a profile swap rather than torn down and rebuilt — a rebuild is a flicker the player sees.

`modules/Export.lua` appears nowhere in that sequence and needs to. It is a plain table with no
`OnEnable` and nothing to wire at load; its two frames are built on the first `Open` and never
before, so a session in which nobody exports never pays for it. The one thing it does keep is taken
with the modal rather than at load: a private bus target carrying `RESTRICTION_CHANGED`, so a dialog
left open across a pull greys its own buttons.

## Bus-target discipline

CallbackHandler keys callbacks by `(message, target)`, so two receivers of one message registered on
the same object silently clobber each other and only the last registrant fires. This addon is
unusually exposed: every window subscribes to the same refresh messages, and there can be many
windows.

- AceAddon modules (`Provider`, `Roster`, `Aggregator`, `WindowManager`, `Tooltip`, `DrillDown`,
  `Visibility`) are their own AceEvent targets.
- Everything else — each `Window` instance, `modules/Format.lua`, and the export modal in
  `modules/Export.lua` once it has been built — owns a private target from `NS.NewBusTarget()`.
- Nothing registers on the shared addon object.
