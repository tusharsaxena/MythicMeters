# Test Cases

The full inventory of every headless test case in this repo, grouped by the suite file it
lives in. The `## Totals` table below is the **authoritative pass count** — the README test
badge and any count quoted in the docs must agree with it.

**Generated — do not hand-edit.** Regenerate with `lua tests/run.lua --list > docs/test-cases.md`.

### test_loadorder.lua (7)

- loadorder: every file the TOC names exists on disk
- loadorder: every shipped .lua on disk is named by the TOC
- loadorder: the TOC declares no duplicate file line
- loadorder: no file captures an NS symbol a later file publishes
- loadorder: locales/ loads ahead of every file that captures NS.L
- loadorder: the five LibKa0s seams load in the order their headers pin
- loadorder: core/MythicMeters.lua loads after every core/ setup file

### test_constants.lua (21)

- Constants: NS.Const and NS.Constants are the same table
- Constants: the chat prefix is the cyan [MM] tag and closes its color code
- Constants: the notice gray is a bare color opener with no closer
- Constants: the shipped monospace font path points into this addon's media
- Constants: the shipped font exists on disk under media/fonts/
- Constants: the LSM font key is a name, not the path
- Constants: every STATS row is fully populated and correctly typed
- Constants: no two STATS rows share a key or an enum value
- Constants: STAT_BY_KEY holds exactly the catalog, by identity
- Constants: each stat key is the name of the enum value it carries
- Constants: DEFAULT_STAT_KEYS is derived from defaultEnabled, in catalog order
- Constants: the six default columns are the design's six
- Constants: only the two rate stats carry isRate
- Constants: every stat label and short label has an enUS entry
- Constants: the resolved enums match the client's when it has them
- Constants: the hardcoded fallbacks equal the live enum values
- Constants: Dps and Hps are deliberately absent from STAT_TYPE
- Constants: every bus message is uniquely named under the addon's prefix
- Constants: every declared bus message is sent somewhere in the addon
- Constants: the throttle window is a real range around the shipped default
- Constants: the row cap covers a full raid and the pool step covers a party

### test_secrets.lua (38)

- Secrets: core/Secrets.lua is the only file that names a detection API
- Secrets: IsRestricted tracks the client's restriction state
- Secrets: IsRestricted answers a plain boolean, never the API's raw return
- Secrets: with no C_RestrictedActions, IsRestricted falls back to combat lockdown
- Secrets: with neither API nor lockdown, IsRestricted is false rather than an error
- Secrets: a raising IsAddOnRestrictionActive degrades instead of propagating
- Secrets: GetRestrictionState forwards the raw state, including Activating
- Secrets: GetRestrictionState answers nil — not a state — when the API is absent
- Secrets: STATE republishes the client's enum, and falls back to the documented literals
- Secrets: IsSecret is true for a secret and false for every plain value
- Secrets: IsSecret answers a boolean, not the client's raw return
- Secrets: CanAccess permits plain values and refuses an inaccessible secret
- Secrets: CanAccess permits a secret during the Activating edge
- Secrets: CanCompare refuses a secret and permits a plain value
- Secrets: CanCompare2 refuses when EITHER operand is secret
- Secrets: IsSafeKey refuses a secret even when this context may READ it
- Secrets: no inspector ever compares or measures the value it is handed
- Secrets: IsSecretTable distinguishes a secret table from a table of secrets
- Secrets: CanAccessTable refuses everything that is not a table
- Secrets: CanAccessTable refuses a secret table under enforcement
- SafeIterate: walks an ordinary array in order and reports how many it visited
- SafeIterate: stops at the first nil rather than running to the limit
- SafeIterate: never applies the length operator to the table
- SafeIterate: a secret table is refused before it is ever indexed
- SafeIterate: hands secret VALUES to the callback untouched
- SafeIterate: a callback returning false stops the walk
- SafeIterate: a callback returning nil does NOT stop the walk
- SafeIterate: bad arguments are refused rather than raising
- SafeIterate: an unbounded array stops at the hard ceiling
- SafeCount: counts an ordinary array and stops at the first nil
- SafeCount: never applies the length operator
- SafeCount: answers nil — not 0 — when the count is not obtainable
- SafeCount: counts a table of secret values without touching one
- SafeCount and SafeIterate agree on the same array
- Secrets degraded: with no detection APIs, nothing is secret and everything compares
- Secrets degraded: SafeIterate and SafeCount are ordinary array walks
- Secrets degraded: canaccessvalue alone missing still refuses a known secret
- Secrets degraded: canaccesstable alone missing still refuses a secret table

### test_compat.lua (23)

- Compat: GetAddOnMetadata reads the TOC through C_AddOns
- Compat: GetAddOnMetadata falls back to the deprecated bare global
- Compat: GetAddOnMetadata answers nil — not a placeholder — with no reader at all
- Compat: GetSpellInfo flattens C_Spell's struct to the old multi-return
- Compat: GetSpellInfo answers nil for an unknown spell rather than raising
- Compat: GetSpellInfo and GetSpellTexture fall back to the bare globals
- Compat: the spell shims answer nil with no API at all
- Compat: the spec shims prefer C_SpecializationInfo and fall back to the globals
- Compat: the spec shims answer nil with no API at all
- Compat: IsDamageMeterAvailable forwards Blizzard's own failure reason verbatim
- Compat: with no C_DamageMeter, IsDamageMeterAvailable is false and the addon still loads
- Compat: every session shim answers nil with no C_DamageMeter
- Compat: GetAvailableCombatSessions answers an EMPTY TABLE, never nil
- Compat: ResetAllCombatSessions reports whether the call was actually made
- Compat: a half-present C_DamageMeter degrades per function
- Compat: every meter shim survives a fully secret session
- Compat: the join key comes back SECRET under the restriction
- Compat: the optional source arguments are forwarded, never defaulted
- Compat: CreateNumericRuleFormatter does NOT abbreviate on its own
- Compat: CreateAbbreviatedNumberFormatter is the one that abbreviates
- Compat: the client's default breakpoints are reachable as a fallback
- Compat: CreateNumericRuleFormatter answers nil rather than a Lua lookalike
- Compat: no file in this addon divides a meter value

### test_state.lua (17)

- State: every flag starts at its shipped default on a fresh load
- State: no state flag leaks into the profile defaults tree
- State: the SavedVariables globals never carry a state flag after a full load
- State: SetRestricted normalizes to a plain boolean
- State: core/Secrets.lua stays the authority, and State is only its mirror
- State: only core/MythicMeters.lua writes the restriction mirror
- State: SetTestMode flips the flag and publishes TEST_MODE_CHANGED once
- State: SetTestMode no-ops when the flag is already in the requested state
- State: SetTestMode coerces truthy values to a boolean before comparing
- State: SetTestMode is the only sender of TEST_MODE_CHANGED
- State: SetActiveWindow moves the pointer and publishes NOTHING
- State: Cache creates a named sub-table on first use and returns the same one after
- State: two modules' caches are independent
- State: WipeCache empties one cache IN PLACE, keeping the caller's upvalue live
- State: WipeCache with no name empties every cache, still in place
- State: WipeCache on a cache that was never created is a no-op, not an error
- State: loading core/State.lua creates no frame and registers no game event

### test_locale.lua (11)

- Locale: a missing key returns the key itself
- Locale: the fallback never returns nil, for any key shape
- Locale: NS.L is published before any consumer can read it
- Locale: every declared entry is a non-empty string
- Locale: no key is declared twice
- Locale: every translated value carries the same format specifiers as its key
- Locale: every stat label and short label in the catalog is declared
- Locale: keys are the English strings, not opaque identifiers
- Locale: NS.L is never handed to a LibKa0s descriptor as its `L`
- Locale: the locale file registers no second table over NS.L
- Locale: enUS is the only locale shipped, and it is unconditional

### test_database.lua (38)

- Database: InitDB publishes the live instance under both names
- Database: the profile is the SHARED Default, not a per-character one
- Database: with AceDB absent, InitDB says so and leaves NS.db nil
- Database: a stored false, "" and 0 all survive the window shape merge
- Database: the same false survives a REAL login — SavedVariables to merged profile
- Database: the merge fills every key the stored window is missing
- Database: the merge deep-copies, so no window shares a sub-table with the template
- Database: the three profile callbacks are registered in the method-name form
- Database: a stored columns array is left exactly as the user ordered it
- Database: an ABSENT columns array becomes an empty array, never nil
- Database: EnsureWindowShape is idempotent
- Database: EnsureWindowShape refuses a non-table without raising
- Database: GetWindows answers an empty table before the database is up
- Database: a fresh profile is seeded with exactly one window
- Database: the seed window is NOT an AceDB default, so a deleted last window stays deleted
- Database: FindWindow answers the window and its index, and nil for anything else
- Database: window ids are monotonic and never reused
- Database: NextWindowId answers 1 with no database rather than raising
- Database: a stored window with no id is given one rather than dropped
- Database: RunMigrations stamps and holds the current schema version
- Database: the schema version is account-wide, not per-profile
- Database: a version ahead of any registered step is walked forward, not spun on
- Database v2: every stored column is lifted to the one uniform width
- Database v2: the frame is widened to hold the new grid
- Database v2: a frame that already fits the grid is left alone
- Database v2: a frame already wider than the grid is left alone
- Database v2: EVERY saved profile is lifted, not just the active one
- Database v2: the step is idempotent and survives a malformed window
- Database: RunMigrations with no database is a no-op, not an error
- Database: RunMigrations normalizes every window whatever the version claims
- Database: a profile swap publishes PROFILE_CHANGED exactly once, with the new key
- Database: core/Database.lua is the only sender of PROFILE_CHANGED
- Database: a profile swap clears the session state derived from the old profile
- Database: the profile a swap lands on is migrated and normalized before anything reads it
- Database: a profile RESET re-seeds rather than leaving an empty registry
- Database v3: ANY of the three old icon flags means the icon stays on
- Database v3: all three off stays off
- Database v3: the three dead keys are REMOVED, not left to rot

### test_diagnostics.lua (13)

- Diagnostics: the report is published and reachable
- Diagnostics: `/mm debug diag` reaches it without the debug log
- Diagnostics: every section appears
- Diagnostics: it reports what the CLIENT has, not what the addon wants
- Diagnostics: a number that misses the ladder is FLAGGED, not just printed
- Diagnostics: one broken section cannot take the report down
- Diagnostics: it never renders a meter value
- Diagnostics: with no window it says so rather than erroring
- Diagnostics: the report lands in the debug console, not in chat
- Diagnostics: the console is OPENED, so the report is not written out of sight
- Diagnostics: with no console the report falls back to chat
- Diagnostics: a font size read back as 10.000000953674 is not called a failure
- Diagnostics: a font the layout reverted is named as such

### test_defaults.lua (24)

- Defaults: DefaultWindow stamps the id and the name it is given
- Defaults: DefaultWindow falls back to the template's name
- Defaults: two windows share NO sub-table, at any depth
- Defaults: a window shares NO sub-table with the shipped template
- Defaults: editing one window leaves the other and the template untouched
- Defaults: a new window's columns are the catalog's default set, in catalog order
- Defaults: every default column takes its width from the catalog and ships its bar on
- Defaults: two windows' column entries are separate tables
- Defaults: the template carries every group the settings pages edit
- Defaults: no template leaf is nil, and no leaf is a function
- Defaults: every stored color is a keyed RGBA table with all four channels
- Defaults: the grid and the header ship the SAME face
- Defaults: the shipped fonts are LSM keys, not paths
- Defaults: the shipped sort column is a stat the window ships enabled
- Defaults: the shipped session type is Overall, which is never empty
- Defaults: the shipped sort mode is `value`, which R2 may fall back from
- Defaults: the shipped position is stored, never read back off a frame
- Defaults: the profile itself is nearly empty — almost everything is per-window
- Defaults: the shipped registry is empty and the id counter starts at 1
- Defaults: the minimap table uses LibDBIcon's own `hide` key
- Defaults: global carries only what is genuinely account-wide
- Defaults: the remembered roster ships EMPTY and with both of its maps
- Defaults: NS.C aliases the profile defaults rather than copying them
- Defaults: the debug flag is NOT a profile default

### test_coresetup.lua (22)

- CoreSetup: the harness loads the vendored LibKa0s majors, so nothing measures a stub
- CoreSetup: the runner FEEDS the derived library list, and it is not empty
- CoreSetup: the TOC-derived addon list leaks no libs/ entry
- CoreSetup: the suite list and tests/test_*.lua on disk agree in both directions
- CoreSetup: NS.Print and NS.Util.print are the SAME function object
- CoreSetup: the printer survives AceConsole's embed
- CoreSetup: the prefix is re-read on every call, not frozen at load
- CoreSetup: NS.Format renders through the same printer
- CoreSetup: IsConcatSafe rejects a value table.concat would raise on
- CoreSetup: SafeToString renders a secret as the sentinel rather than raising
- CoreSetup: the secret-safe members are the library's own, published by reference
- CoreSetup: RGBA reads the keyed shape the profile ships
- CoreSetup: RGBA reads the positional shape the options color widget writes
- CoreSetup: a stored ZERO channel survives as zero
- CoreSetup: presence of any of r/g/b makes the keyed shape win for all four
- CoreSetup: channels fall back independently, so a three-element color keeps its alpha
- CoreSetup: RGBA answers the four defaults for a non-table
- CoreSetup: the fallback color reader stands behind the library's
- CoreSetup: the window edge comes from the library, never from a private lookalike
- CoreSetup: no addon file restates a Core.SKIN value
- CoreSetup: NS.LIBKA0S_MISSING is set on BOTH paths, not only the degraded one
- CoreSetup: all five seams append to the shared clause rather than re-spelling it

### test_perfsetup.lua (19)

- PerfSetup: NS.Perf is the library instance, with the gate as a plain boolean field
- PerfSetup: the capture ring is a SECOND SavedVariables global, outside the AceDB tree
- PerfSetup: the capture record is stamped from the TOC manifest
- PerfSetup: the manifest is read through NS.Compat, never by naming C_AddOns
- PerfSetup: no locale table is handed to the library
- PerfSetup: every declared bucket is reached by a real bracket in the addon's source
- PerfSetup: every bracket in the addon names a bucket the descriptor declares
- PerfSetup: the bucket nesting is declared, so a reader never sums a parent with a child
- PerfSetup: every instrumented module takes the probe as a file-scope upvalue
- PerfSetup: every bracket is gated, so an unstarted capture costs one boolean read
- PerfSetup: perf output is deliberately NOT gated on the debug flag
- PerfSetup: suspend stops the provider ASKING the meter, not just discarding the answer
- PerfSetup: suspend takes the provider's bus subscriptions down
- PerfSetup: the show decision refuses every window while suspended, above the master enable
- PerfSetup: resume restores from CURRENT state, not from a pre-suspend snapshot
- PerfSetup: suspend and resume are idempotent
- PerfSetup: the descriptor resolves its modules at CALL time
- PerfSetup: with LibKa0s absent the stub answers every member the addon reaches
- PerfSetup: the degraded `/mm perf` answers with the shared cause and its own consequence

### test_debuglogsetup.lua (18)

- DebugLogSetup: NS.DebugLog is the library instance and NS.Debug is its bare sink
- DebugLogSetup: the sink is gated on the flag and costs nothing when it is off
- DebugLogSetup: a SECRET reaching a log line renders as the sentinel, never as a raise
- DebugLogSetup: the flag stays the addon's — the library holds no second copy
- DebugLogSetup: the debug flag never reaches SavedVariables
- DebugLogSetup: enabling the console acknowledges in chat
- DebugLogSetup: the [Init] summary names the version, the schema and the profile
- DebugLogSetup: the console takes the shipped monospace font by PATH
- DebugLogSetup: the font is registered with LSM exactly once, and not from this file
- DebugLogSetup: the frame names are seeded from the addon name
- DebugLogSetup: the console's visibility change refreshes an open settings panel
- DebugLogSetup degraded: the stub carries the WHOLE live surface
- DebugLogSetup degraded: NS.Debug is still a plain callable function
- DebugLogSetup degraded: the flag still works, and says so once
- DebugLogSetup degraded: the honest missing-console line is said ONCE
- DebugLogSetup degraded: the stub reproduces NO part of the library's line format
- DebugLogSetup degraded: the console checkbox answers a usable data contract
- DebugLogSetup degraded: the buffer introspection answers rather than erroring

### test_lifecycle.lua (23)

- Lifecycle: NS IS the AceAddon object, promoted in place
- Lifecycle: every module registers, and the enable cascade runs them all
- Lifecycle: every module is also published under its flat NS name
- Lifecycle: the AceConsole embed is reclaimed on the line after NewAddon
- Lifecycle: OnInitialize builds the database FIRST
- Lifecycle: OnInitialize runs end to end on a fresh client
- Lifecycle: with the settings layer gone, `/mm` is claimed anyway and says why
- Lifecycle: OnEnable registers exactly the events the fan-out handles
- Lifecycle: no module registers a game event of its own
- Lifecycle: PLAYER_ENTERING_WORLD is republished with its login/reload flags
- Lifecycle: the roster cache is dropped BEFORE ROSTER_CHANGED goes out
- Lifecycle: a meter reset wipes EVERY cache before publishing
- Lifecycle: the session event forwards its payload, which is never secret
- Lifecycle: the meter update event is a bare republication
- Lifecycle: the three meter handlers carry the meterEvent bracket
- Lifecycle: OnEnable seeds the restriction mirror from the LIVE state
- Lifecycle: the restriction event updates the mirror and forwards the RAW state
- ShouldShow: the ladder answers a reason that names the step that decided
- ShouldShow: a non-table is refused before anything else is consulted
- ShouldShow: the master enable refuses every window
- ShouldShow: test mode overrides context, so a window can be positioned anywhere
- ShouldShow: the context rules are Visibility's, consulted rather than reimplemented
- ShouldShow: a missing Visibility module fails OPEN

### test_vendor_sync.lua (2)

- libs/LibKa0s is the LibKa0s release CLAUDE.md says this addon bundles
- tests/_kit is the test kit that shipped with that release

### test_format.lua (25)

- Format: NS.Format is a callable table carrying both contracts
- Format.Number goes through the native ABBREVIATING formatter
- Format.Invalidate drops the cached formatter instance
- Format.Number('full') renders every digit and no abbreviation
- Format.Number('full') renders a rate's DIGITS, not its decimals
- Format.Number abbreviates a sub-thousand rate to its whole part
- Format.Number renders a value BELOW ONE without dumping its float
- Format.Number('full') also covers a value below one
- Format: a formatter whose ladder never took is NOT cached
- Format: the abbreviating formatter is given breakpoints, or it does nothing
- Format.Number('') for nil, which is a different fact from zero
- Format.Number accepts a secret and returns something SetText takes
- Format.Rate renders the bare number — no unit suffix
- Format.Duration refuses the clock arithmetic on an inaccessible value
- Format.Duration does the clock arithmetic on a plain number
- Format.Percent(value, total) refuses when an operand is inaccessible
- Format.Percent computes the ratio when both operands are plain
- Format.Percent refuses a pre-computed share it cannot access
- Format.Number falls back to AbbreviateNumbers when C_StringUtil is absent
- Format.Number falls back to SafeToString when neither abbreviator exists
- Format.Rate degrades to the bare number when the suffix cannot be joined
- modules/Format.lua never calls tonumber on anything
- modules/Format.lua never calls table.concat
- Format.Number and Format.Rate contain no division at all
- A ladder the client silently refuses is DETECTED, not assumed

### test_provider.lua (35)

- Provider: core/Compat.lua is the only file that names C_DamageMeter
- Provider: modules/Provider.lua is the only caller of the meter shims
- Provider: the source walk uses SafeIterate, never ipairs and never `#`
- Provider.IsAvailable memoizes and InvalidateAvailability drops the memo
- Provider surfaces Blizzard's failureReason verbatim
- Provider.GetColumn names an unknown stat rather than skipping it
- Provider.GetColumn tells 'no session' apart from 'session sealed'
- Provider.GetColumn copies secret fields through without inspecting one
- Provider.GetColumn skips a source row it may not access, without raising
- Provider.GetColumn drops a source with no GUID rather than keying on nil
- Provider.GetColumn preserves the API's order verbatim
- Provider never asks for Enum.DamageMeterType.Dps or .Hps
- Provider: one DamageDone read fills both halves of the Damage column
- Provider.GetSourceDetail returns Blizzard's table, guarded but unflattened
- Provider.GetSourceDetail refuses rather than handing back a sealed table
- Provider.GetSourceDetail answers nil for an unknown stat or a missing source
- Provider accepts both the dot and the colon call shape
- Provider.GetAvailableSessions passes the client's list through untouched
- Provider.GetSessionDuration hands back the opaque handle
- Provider.Reset wipes the sessions, forgets availability and announces
- Provider.Reset answers false where the API is absent
- Provider:Suspend stops the addon ASKING, not merely drawing
- Provider:Suspend drops its bus subscriptions and Resume republishes them
- Provider: with no sessionID the read goes to the TYPE shim, as it always did
- Provider: a sessionID routes to the ID shim instead
- Provider: the colon call shape carries the sessionID too
- Provider: GetSourceDetail with a sessionID reaches the ID breakdown
- Provider: a segment's duration comes off the session LIST, not the type shim
- Provider: an unknown sessionID has no duration rather than a wrong one
- Provider.HasSession is the staleness check behind a persisted segment
- Provider: a suspended capture answers no segment questions
- Provider: reading a segment never inspects a value
- Provider.ProbeSourceByGuid names what the API did with a GUID it was handed
- Provider: an NPC source with no GUID is KEPT, on its creature ID
- Provider: a source with NEITHER identifier is still dropped

### test_roster.lua (22)

- Roster.GetGroup is player-first, then party order
- Roster.GetGroup carries name, class and role off the unit API
- Roster de-duplicates the player, who is both `player` and `raidN`
- Roster answers a one-entry group when solo
- Roster skips a unit the API cannot see
- Roster.IsGroupMember is a plain GUID lookup, legal at any point in a pull
- Roster.Get answers the entry, and nil for a stranger
- Roster.RoleOf answers NONE rather than nil for a non-member
- Roster normalizes an unrecognized role to NONE
- Roster.OwnerOf maps a unit-frame pet to its owner
- Roster.OwnerOf answers nil for anything that is not a unit-frame pet
- Roster never keys the map on a secret GUID
- Roster does not attribute a pet to a member it skipped
- Roster builds lazily and holds the map until it is invalidated
- Roster.Refresh drops the cache without rebuilding it eagerly
- Roster shares core/State.lua's cache seam rather than owning a private one
- Entering or leaving test mode invalidates the map
- Roster subscribes to the roster message; it never sends one
- modules/Roster.lua registers no game event of its own
- A partial build is NOT cached, so the next read retries
- A complete build IS cached
- Solo is complete, not partial

### test_aggregator.lua (52)

- Aggregator joins columns on the GUID, which is the only legal key
- Aggregator's result table IS the row array, and cells aliases values
- Aggregator takes identity from the roster and the spec icon from the meter
- Aggregator promotes deathRecapID onto the row, off whichever column carried it
- Aggregator puts the column max on every cell in the column
- Aggregator publishes columnTotals so nothing re-reads the session
- Aggregator surfaces the first column reason it met
- Aggregator skips a stored column whose stat this build does not offer
- Aggregator falls back to the first column when sortColumn is unusable
- Aggregator.Build answers an empty result for a non-table window
- Aggregator.Build accepts both the dot and the colon call shape
- Aggregator drops a source that is not a group member
- Aggregator drops an unattributable pet rather than showing a phantom row
- Aggregator sums an attributed pet into its owner out of combat
- A healer with no damage is on the mid-pull grid, from the healing column
- An ambiguous key gets no invented row, because no column could ever fill it
- A correlated cell carries the RATE, or a rate column renders no text
- A correlated Deaths column keeps the recap id the death view opens on
- A pet is a ROW OF ITS OWN while restricted, not a dropped contribution
- Aggregator adopts a pet's numbers into a column the owner has no cell in
- A pet's position never moves its owner in the provider order
- A row seen only outside the sort column is parked past every ranked row
- Aggregator computes percent out of combat
- Aggregator answers nil percent while restricted — never zero
- ApplyRowLimit truncates to maxRows
- ApplyRowLimit treats 0 and an over-large cap as the hard ceiling
- alwaysShowSelf spends the last visible slot on the player
- alwaysShowSelf does nothing when the player is already visible
- Aggregator applies the cap before dividing, not after
- Test mode substitutes the DATA, and the render path stays one path
- A test row's tooltip finds a breakdown, because it goes to the provider
- Test mode reaches no meter API at all
- Test data is deterministic — a jittering grid cannot be laid out against
- A meter reset drops this module's cache
- A pet gets its OWN row by default, with its own name
- A pet's own row survives the restriction, where a merged one would not
- Leaving the group does NOT empty the window
- A meter reset is what forgets them
- A pet stays attributed after its owner's group is gone
- A dropped source says WHY, once per pass
- A secret-GUID source that says it is the local player keeps its row
- A secret GUID that does NOT claim to be the local player is still dropped
- A SECRET isLocalPlayer flag is not truth-tested, and claims nothing
- A SECRET source GUID is dropped without raising, and is named as secret
- The Deaths column counts a GUID's rows rather than reading totalAmount
- A counted column scales its bars to the highest count, never to 0
- The NEWEST death wins the recap id
- Counting a death is legal mid-pull, where summing two secrets is not
- An ALLY nobody owns gets its own row, under its own name
- The owner is still not credited for an unowned ally's damage
- An ENEMY nobody owns is still refused
- A source with NO display type is refused, not assumed friendly

### test_aggregator_sort.lua (16)

- value mode orders by the sort column's numbers, descending
- value mode breaks a tie on providerIndex, so the order is deterministic
- value mode sorts a row with no cell in the sort column last
- a missing cell counts as ZERO, so it leads an ascending sort
- two missing cells keep provider order, so the sort stays deterministic
- a value sort caches NOTHING — the freeze is retired
- while restricted the order is the ENGINE's ranking, and it is live
- while restricted a row is keyed on its POSITION, never on the secret GUID
- value mode checks comparability in a pass BEFORE table.sort is entered
- the Activating edge is no longer listened for
- provider mode never compares a value, in combat or out
- an unrecognized sort mode degrades to provider order rather than to nothing
- roster mode orders by group position, ignoring the numbers entirely
- roster mode ranks role before name within one group position
- roster mode's NAME TIEBREAK refuses to compare two secret names
- roster mode compares names when they are plain

### test_window.lua (82)

- Window builds a bare anchor plus the visible frame, and names both
- Closing HIDES the window; it never deletes it
- The header carries a lock and a gear, and the padlock shows the state
- The padlock toggles THIS window only
- Dragging moves the ANCHOR, never the frame that holds the cells
- A locked window refuses the drag entirely
- SavePosition reads GetPoint off the anchor and off nothing else
- SaveSize uses the size OnSizeChanged was handed, never a getter
- BuildLayout computes every coordinate from config alone
- A stat column never shrinks below the legible floor
- The window refuses to be dragged smaller than the grid needs
- BuildLayout drops a column whose stat this build does not offer
- BuildLayout derives how many rows FIT, capped by maxRows and MAX_ROWS
- The throttle is clamped to the constants, whatever the profile says
- The throttle coalesces N events into ONE refresh
- A clean window costs nothing when the clock comes round
- Refresh does nothing at all while the frame is hidden
- Refresh draws one row per aggregated entry, from the pool
- Rows come from a POOL: no CreateFrame on a second refresh
- HideAll returns every active row to the free list
- Render honors layout.maxRows and places rows from Row.OffsetFor
- growthDirection UP anchors from the bottom of the body
- R3: no geometry is read back off a cell that has held a secret
- modules/Window.lua reads geometry back off the anchor and nothing else
- An unavailable meter renders the prompt INSTEAD of rows
- The notice omits a reason it cannot safely render
- An empty session says so rather than leaving a blank grid
- ShouldShow STEP 0 is NS.Perf.suspended, above even the master enable
- ShouldShow's ladder reads master enable, then test mode, then context
- RefreshVisibility shows, hides, and marks dirty exactly once on the way in
- The header folds its parts with `..`, and survives a secret duration
- The header says the grid was built the restricted way
- The header names AMBIGUITY when two rows cannot be told apart
- The header line reads 'Test' while placeholder data is on screen
- Test data never reaches the provider
- UNLOCKING A WINDOW NO LONGER TURNS TEST DATA ON
- A drilled-in window draws the breakdown, decided by the ROWS not the title
- Suspend takes the OnUpdate away and Resume puts it back
- Destroy takes the window off screen and off the bus
- Each window owns a PRIVATE bus target, so two windows cannot clobber each other
- Segment menu: stored segments first, then a divider, then Current/Overall
- Segment menu: an entry is labelled with its name AND its duration
- Segment menu: picking a segment pins it and marks the window dirty
- Segment menu: picking Current CLEARS the pin
- Segment menu: with no menu API the click is refused, not an error
- Segment: a pinned segment is READ, not merely stored
- Segment: the header names the pinned segment rather than lying `Current`
- Segment: a stale pin is dropped on the next refresh
- Segment: a LIVE pin survives the staleness check
- Segment: with no provider the pin is left alone rather than rewritten
- Segment: the session line is a BUTTON and the text rides on it
- Column headers are BUTTONS carrying the full stat label, left-aligned
- The sort column shows an arrow and the others do not
- The arrow flips with the direction
- Clicking a header sorts by it; clicking again reverses
- Clicking a header drops the frozen sort order
- Sorting is REFUSED in combat, and says so rather than going quiet
- The Player header sorts by PLAYER, ascending first
- The Player header REFUSES while restricted, like every other header
- The sort arrow moves to the Player header in name mode
- Test mode is marked in RED in the title, and clears when it is off
- Leaving test mode does not close the window
- Building a window sets no text on a fontless FontString
- Header art falls back to ASCII on a client with none of the atlases
- Header art prefers an atlas where the client has one
- Changing a setting does not close a window the player asked for
- A zone change is what makes an explicit show stale
- Closing cancels the request, so it does not reappear
- Scrolling moves the window into the list, it does not shorten it
- The offset survives a refresh, or scrolling is impossible
- The offset cannot run past the end of the list
- A list that shrinks under a stationary offset re-clamps on the next draw
- Scrolling up stops at the top
- A list that fits entirely cannot be scrolled
- The body takes the wheel, or the handler is never called in game
- The wheel scrolls up on a positive delta
- Entering or leaving a breakdown puts the view back at the top
- A drill-down draws its rows from the top of the body, with none hanging out
- Right-clicking empty space below the rows leaves a breakdown
- The body claims the mouse only while a breakdown is open
- Column headers take their own font, not the cells'
- Column headers have their own colour and background

### test_row.lua (60)

- Row.OffsetFor is a pure function of the index and the row config
- Cell:ApplyLayout places every cell from the layout table
- A column toggled off hides its cell rather than destroying it
- modules/Row.lua contains no geometry getter at all
- Cell:SetValue hands the raw handle to SetValue and SetMinMaxValues
- Cell:SetValue substitutes 0 and 1 for an ABSENT figure, not for a hidden one
- A rate-capable column renders the TOTAL ALONE by default
- Both figures appear when the right slot is turned on
- A counting column renders the total only
- The text slots are configurable, and percent is the one that goes quiet
- A 'none' text slot renders nothing
- A cell with BOTH slots off still shows its total
- Both slots take the same four values, in either position
- Cell figures are read out of EITHER row shape the addon produces
- Class color comes from classFilename, which keeps working while restricted
- Every color mode falls back to one neutral, never to a fourth palette
- Role and stat color modes read their own tables
- A custom color comes from the setting, not from the last-resort literal
- A cell with its bar switched off keeps its text
- The name cell is never handed a meter value at all
- The name cell colors the NAME by class, now that no bar carries it
- An unknown class reads as white, not as a tenth palette entry
- The name cell renders a plain name and survives a secret one
- A cross-realm PLAYER name loses its realm
- An NPC keeps the hyphen in its name
- A pet keeps its hyphen too
- The name never wraps, and gets a fixed width to be truncated against
- The icon inset is the SAME for a row with no icons to draw
- A layout pass keeps the class color instead of flashing white
- A name past the cap is truncated with NO ellipsis
- Truncation counts CHARACTERS, never bytes
- A cap of 0 means no cap
- Neither the realm strip nor the cap is applied to a SECRET name
- A drill-down row keeps a hyphen, which is part of a spell name
- A nil name renders empty rather than the string 'nil'
- The single icon slot prefers the SPEC where there is one
- The slot falls back to the CLASS where no spec is known
- A ROLE icon is never drawn, whatever the row carries
- A breakdown row draws the SPELL's icon, not a unit's
- Turning the icon off hides it rather than destroying it
- highlightSelf honors both spellings of 'this row is you'
- The class tint is painted on the CELLS, not on the row
- A row with no class falls back to the alternating stripe
- The class tint can be switched off
- The mouseover overlay is driven from the CELLS, and honors the setting
- EnableCellMouse hands the mouse to every cell, including the name cell
- Release blanks the row without destroying a widget
- Hovering a stat cell asks the tooltip the narrow question
- Clicking a stat cell routes to the drill-down; the name cell does not
- A cell with no entry does nothing under the cursor
- Hovering a breakdown ROW shows the client's spell tooltip
- Crossing a cell boundary does NOT blink the breakdown tooltip
- Leaving the row hides the breakdown tooltip
- On the GRID a cell still owns its own tooltip
- A breakdown row with no resolvable spell still says which spell it is
- A left click inside a breakdown does nothing
- A right click leaves the breakdown
- A right click on the ROW ITSELF leaves the breakdown
- A right click on the GRID is a harmless no-op
- Cells register for BOTH buttons, or the right click never arrives

### test_targets.lua (22)

- Targets: a player's enemies are recovered from the enemy column
- Targets: one enemy's several spells are summed into one line
- Targets: another player's damage is not credited to this one
- Targets: a player who hit nothing gets nil, not an empty list
- Targets: the cap trims the list after ordering, not before
- Targets: Total adds a list up, for the share column
- Targets: an unreadable amount abandons the WHOLE build, not one enemy
- Targets: the enemy lookup drops a SECRET guid and resolves on creatureID
- Targets: an unreadable caster name is skipped, and skipping it is safe
- Targets: an unreadable HOVERED name answers nil rather than raising
- Targets: no enemy column means no section, not an error
- Targets: every meter read goes through the provider
- Targets: a cross-realm caster still matches the row it belongs to
- Targets: a realm-qualified ROW name matches a bare caster
- Targets: two casters differing only by realm are still told apart by name
- Targets: one walk answers for every player, not just the hovered one
- Targets: a second hover of the same player reads nothing
- Targets: the cap is applied to a COPY, never to the cached list
- Targets: a refusal does not pin the section shut for the session
- Targets: a new session's numbers replace the old ones
- Targets: the invalidating messages are actually subscribed
- Targets: two sessions do not share a map

### test_tooltip.lua (59)

- CellTooltip opens on the hovered cell and heads with the player and the stat
- CellTooltip honors the anchor setting and falls back to the cursor
- CellTooltip sorts biggest-first when comparison is legal
- CellTooltip REFUSES the sort while comparison is illegal
- CellTooltip refuses the sort when an amount is MISSING, not merely secret
- CellTooltip caps the list at maxSpells and says how many were left out
- CellTooltip renders secret amounts through the formatter, untouched
- CellTooltip says 'no data' rather than showing an empty frame
- showSpells = false keeps the header and drops the breakdown
- hideInCombat refuses the hover outright
- An unresolvable spell is shown by ID rather than dropped
- The avoidable column tags Avoidable and Deadly, and NOT Overkill
- Those flags are never truth-tested directly — a secret boolean would raise
- The Deaths cell advertises the click that opens the recap
- A death with no recap id advertises nothing
- NameTooltip lists EVERY tracked stat, dimming the ones not on screen
- NameTooltip works while restricted, adding nothing up
- showAllStatsOnName = false stops after the name
- NameTooltip says 'no data' when the meter has nothing for the player
- A tooltip resolves its window from row.windowId when it was not handed one
- Tooltip:Hide is unconditional
- modules/Tooltip.lua never applies `#` to a meter array
- A spell line carries a real class-colored BAR, not a run of characters
- Bars are released between hovers, never stacked
- The bar is OMITTED while the values cannot be divided
- A bar spans the FULL line, so its length is comparable down the column
- A bar clears the icon rather than running underneath it
- A bar sits UNDER the tooltip's text, not over it
- Bars come down when GameTooltip closes, whoever closed it
- A spell line carries its SHARE of the player's total beside the amount
- The percent slot GOES QUIET mid-pull rather than approximating
- The amount and the share sit in FIXED right-aligned slots
- Both number slots are white by default, not two kinds of number
- The tooltip text colour is configurable, and reaches every slot
- The AMOUNT survives a hover the bar cannot
- The tooltip is widened for the slots, and put back afterwards
- Every anchor the schema offers resolves to a real GameTooltip token
- The anchor dropdown offers nothing the token table cannot resolve
- The x/y offset reaches SetOwner rather than a SetPoint of our own
- A junk offset off an old profile is clamped, never handed to the client
- Bar spacing is applied to the tooltip, and taken back off when it hides
- The configured font reaches both number slots and the spell name
- NONE is an absent outline flag, not the literal string
- Every tooltip line we restyled is put back when the tooltip hides
- The tooltip's own bar texture is used, not the grid's
- A bar border is applied when asked and cleared off the POOLED line when not
- Border size zero drops the border FILE with it
- maxSpells 0 lists every spell the breakdown collected
- maxSpells 0 is bounded by the collector, and says so
- A negative or non-numeric cap still falls back to the shipped default
- The font survives a UI skin that re-fonts every line on show
- The post-layout pass still restores every line it touched
- A target's name is drawn on our own carrier, not on the tooltip's line
- The gap above a section is half the text size, not a whole blank line
- The half-size gap survives the post-layout pass
- The gap is restored with every other line it was applied alongside
- The tooltip is widened without measuring anything inside GameTooltip
- The width follows the font size and the name length, because it is computed
- A name that cannot be read simply does not widen the tooltip

### test_drilldown.lua (31)

- DrillDown.IsActive is a PLAIN BOOLEAN, in both directions
- Enter captures PLAIN identity fields, never a reference to the row
- Enter refuses a row with no GUID and a stat this build does not offer
- Enter and Exit announce on the bus, with the window id and a boolean
- Exit is a no-op when nothing is open
- Drill-down state is session-only, in the shared cache
- BuildRows returns nil, nil and a FALSE BOOLEAN when the window is not drilled in
- BuildRows emits aggregator-shaped rows, one per spell
- BuildRows does NOT sort — the API's order is kept exactly
- BuildRows builds while restricted, comparing and totaling nothing
- BuildRows skips a spell row it may not access
- BuildRows caps the breakdown at the row pool's ceiling
- BuildRows answers an empty list, not nil, when the provider refuses
- An unresolvable spell keeps its synthesized key as its name
- DrillDown.Title is text for a widget, and nil when nothing is open
- A view with no name still produces a title, without an `or` on the name
- The window branches on BuildRows' rows, never on its title
- Clicking a stat cell enters the breakdown
- Clicking the same cell again returns to the grid
- Clicking a DIFFERENT cell while drilled in switches the view
- The Deaths cell routes to the death recap via deathRecapID
- A Deaths click falls through to the breakdown when the recap API is absent
- A Deaths click with no recap id falls through too
- A Deaths click prefers the Compat shim the moment one exists
- A click on something that is not a row does nothing
- The back button is created once and re-used forever after
- The back button is anchored, never measured
- The back button exits the drill-down
- A meter reset leaves every drill-down
- Deleting a window leaves the drill-down that belonged to it
- A bulk registry change sweeps views whose window is gone

### test_visibility.lua (22)

- GetContext translates Blizzard's instance token to the setting's name
- An instance type this build has never heard of resolves to world
- The shipped matrix is dungeon / raid / arena / battleground on, world off
- The reason token is stable and unlocalized
- hideWhenSolo hides a window whose context already said yes
- hideInVehicle hides a window whose context already said yes
- Context is decided BEFORE the two vetoes, so the reason is the real one
- The vehicle answer is read live, because nothing on the bus announces it
- A window with no rules at all is allowed, not hidden
- A non-table window is refused by name
- Allows() is the same implementation under the ladder's name
- Evaluate records the last answer per window and counts the changes
- Refresh is Evaluate under the name a caller thinks in
- Evaluate publishes NOTHING
- Forget drops every remembered answer
- Evaluate copes with a database that is not up yet
- A window that should not show never reaches the provider at all
- The refusal lifts the moment the context does
- modules/Visibility.lua never touches a frame
- modules/Visibility.lua uses no combat rule, and no InCombatLockdown proxy
- Visibility listens on the bus and registers no game event
- A profile change forgets the old answers and re-evaluates

### test_windowmanager.lua (31)

- WindowManager is published under the flat name every caller uses
- Init builds one live instance per stored config, and is idempotent
- All() answers in the registry's order, which is the user's
- Resolve takes an id or a name, and folds case on the way in only
- A window literally named "2" wins over the window whose id is 2
- Create appends a window with the shipped defaults and a live instance
- Ids are monotonic and never reused
- A duplicate name is disambiguated rather than refused
- Rename stores the new name and refuses an empty one
- Duplicate deep-copies the source and offsets the copy
- Delete removes the config, destroys the instance and repoints the picker
- THE LAST WINDOW IS NOT DELETABLE
- An empty registry is re-seeded with a default
- Delete answers false for a window that is not there
- Every registry mutation announces WINDOWS_CHANGED, and nothing else does
- CopyFrom with no filter copies every group, deeply
- CopyFrom with ONE group key copies only that group
- CopyFrom accepts an array of keys and a set of them
- CopyFrom drops a group key this build does not know
- CopyFrom refuses a missing source or target, and no-ops onto itself
- CopyFrom re-normalizes the target's shape afterwards
- ResetPosition and ResetPositions put windows back in the middle
- ResetPosition defaults to the window the picker is pointed at
- SetLocked flips every window and touches NOTHING else
- IsLocked is false the moment any one window is unlocked
- SetTestMode routes through core/State.lua and marks every window dirty
- Toggle with no name flips every window; with a name, one
- MarkAllDirty costs one flag each and nothing else
- BuildListLines names every window and says whether it is on screen
- Suspend stops the coalescing timers without hiding anything
- Resume restores from CURRENT state: a window made while suspended comes back

### test_minimap.lua (17)

- Minimap.Init creates a launcher and registers it against the live profile
- The launcher's name matches what the settings row looks it up by
- Minimap.Init is idempotent
- Minimap.Init adopts a broker object another path already created
- Init answers false, quietly, when LibDataBroker is absent
- Init answers false when LibDBIcon is absent
- Init answers false before the database exists
- Refresh before Init is a quiet no-op
- Refresh re-reads minimap.hide off the live profile
- Left-click toggles the windows through WindowManager's own seam
- Right-click opens the settings through OpenOptionsPanel, not a private path
- A click on a build with no window manager does nothing rather than raising
- The tooltip states BOTH clicks and the version
- The tooltip callback never shows or clears the tooltip itself
- The tooltip callback tolerates an object it cannot write to
- The profile ships the one key LibDBIcon reads, and nothing else
- modules/Minimap.lua passes the silent flag to every LibStub call

### test_schema.lua (32)

- Schema: a window path resolves against the session's ACTIVE window
- Schema: a global path is unaffected by which window is active
- Schema: an unset active window falls back to the FIRST window, never to nil
- Schema: a stale active-window id falls back to the first window
- Schema: the inverted row stores the negation of what it displays
- SetByPath: refuses a value the row's validate() rejects, and stores nothing
- SetByPath: refuses a path that is not a row
- SetByPath: fires the row's onChange exactly once, with the value and window id
- SetByPath: onChange runs AFTER the write, never before
- SetByPath: logs the change exactly ONCE
- SetByPath: announces CONFIG_CHANGED once, tagged with the row's page and window
- SetByPath: re-syncs open panels IN PLACE, never structurally
- SetByPath: a table value is COPIED in, never stored by reference
- ApplyDefault: restores through the same seam, deep-copying a table default
- ApplyDefault: round-trips the inverted row back to its SHIPPED stored value
- SetByPath: window.columns ACCEPTS a well-formed ordered array and stores it
- SetByPath: window.columns REBUILDS the array rather than adopting the caller's
- SetByPath: window.columns takes the same log, message and refresh a scalar takes
- SetByPath: window.columns is readable through the generic resolver
- SetByPath: window.columns REFUSES a non-table value, with a message
- SetByPath: window.columns REFUSES an empty array, with a message
- SetByPath: window.columns REFUSES a gap or a string key, with a message
- SetByPath: window.columns REFUSES an entry that is not a table, with a message
- SetByPath: window.columns REFUSES a statistic this build does not have, with a message
- SetByPath: window.columns REFUSES the same statistic twice, with a message
- SetByPath: window.columns REFUSES a width below the slider's floor, with a message
- SetByPath: window.columns REFUSES a width above the slider's ceiling, with a message
- SetByPath: window.columns REFUSES a non-numeric width, with a message
- SetByPath: window.columns REFUSES a NaN width, with a message
- SetByPath: window.columns REFUSES a show-bar flag that is not a boolean, with a message
- SetByPath: a path INTO the column array is refused by name
- SetByPath: the columns validator agrees with the width slider's own range

### test_schema_defaults.lua (10)

- Schema defaults: the two trees the validator compares are both present
- Schema defaults: every non-session row resolves against defaults/Profile.lua
- Schema defaults: every row's default equals the shipped default, compared deeply
- Schema defaults: every color default agrees on all four channels
- Schema defaults: a table default is never the SAME table the defaults tree holds
- Schema defaults: session-only rows are exempt and carry their own storage
- ValidateSchema: reports zero failures on a healthy load
- ValidateSchema: counts a row whose default disagrees with the defaults tree
- ValidateSchema: counts a row whose path does not resolve
- ValidateSchema: compares a color CHANNEL, not just the presence of a table

### test_slash.lua (29)

- Slash: NS.COMMANDS entries are positional triples, not named fields
- Slash: no verb is declared twice
- Slash: every reserved verb is present, in the order the standard fixes
- Slash: the host verbs are declared and each carries a real handler
- Slash: `reset` takes a PATH, not a page
- Slash: every sub-verb a handler accepts is named in its own description
- Slash: an unknown verb says so and prints the help
- Slash: `options` is an alias for `config`, not a second command
- Slash: `version` reports the TOC's version rather than a hardcoded string
- Slash: `get` and `set` land on the addon's own schema seam
- Slash: `set` on a window path writes the ACTIVE window
- Slash: `reset <path>` restores exactly that one setting
- Slash: `resetall` restores every row
- Slash: `list` groups by the row's PAGE, the same key the panel pages use
- Slash: `perf` is declared in NS.COMMANDS and routed to NS.Perf.OnCommand
- Slash: the library did not register `perf` behind the addon's back
- Slash: `lock` sets, and a bare `lock` toggles
- Slash: `test` sets and toggles through the registry
- Slash: `lock` moves the lock and NOTHING else
- Slash: `window new` and `window delete` act on the registry
- Slash: `window list` prints one line per window
- Slash: `window` with an unknown sub-verb prints the usage
- Slash: `toggle` reaches the registry and reports its refusal
- Slash: `reset-positions` moves every window and says how many
- Slash: `debug on` / `debug off` set the logging flag; a bare `debug` moves the window
- Slash: registration goes through AceConsole, on both tokens
- Slash: both registered tokens reach the SAME dispatcher
- Slash: no raw SLASH_* global is claimed anywhere
- Slash: Register is a no-op rather than a raise when there is no AceConsole

### test_options_panel.lua (22)

- Options: the parent category is registered at CreateOptionsPanel time
- Options: every page's subcategory is registered eagerly, before any panel is shown
- Options: a page's ctx carries its page key
- Options: the body is NOT built until the panel's first OnShow
- Options: a second OnShow does NOT re-render an already-rendered page
- Options: a hidden page is marked dirty and re-renders on its NEXT show
- Options: the Defaults button is built on first show, not at registration
- Options: EnsureDefaultsButton runs OUTSIDE the already-rendered guard
- Options: a page that declines a Defaults button never grows one
- Options: the canvas footer's Defaults control reaches the same handler as the header button
- Options: opening the panel is REFUSED under combat lockdown, with a notice
- Options: a refused open is NOT deferred and replayed when combat ends
- Options: a page reached from the Blizzard sidebar mid-combat refuses to render
- Options: a widget's set() routes through NS.SetByPath
- Options: a checkbox's set() routes through NS.SetByPath too
- Options: applyDefault routes through NS.SetByPath, not around it
- Options: the panel and the CLI resolve a page's rows through the SAME function
- Options: skipRestoreAll vetoes the profiles page from a global reset
- Options: a global reset restores window POSITIONS, which no schema row owns
- Options: CreateOptionsPanel is idempotent
- Options: CreateOptionsPanel runs the schema validator
- Options: AceGUI is resolved once and published for the page builders

### test_columns.lua (23)

- Columns: the page renders one control set per stored column
- Columns: the first column cannot move left and the last cannot move right
- Columns: the width slider writes the stored width and repaints
- Columns: the show-bar checkbox writes the stored flag as a real boolean
- Columns: the stat dropdown re-points a column at another statistic
- Columns: Move left swaps a column with its neighbour
- Columns: Move right swaps a column with its neighbour
- Columns: Remove drops exactly that column
- Columns: the last column cannot be removed
- Columns: Add appends the picked statistic, sized from the catalog
- Columns: Add with nothing picked does nothing
- Columns: the Add picker offers only statistics not already shown
- Columns: a column's own picker offers the free stats PLUS the one it shows
- Columns: the Add section says so rather than offering an empty picker
- Columns: the picker never offers a choice NS.SetByPath would refuse
- Columns: a refused write is REPORTED and the page is not repainted
- Columns: an accepted write IS repainted
- Columns: every mutation goes through NS.SetByPath, never straight into the profile
- Columns: the stored array is never the page's own working copy
- Columns: no mutation is applied under combat lockdown
- Columns: the width slider's range matches the carve-out's validator
- Columns: a width the slider can produce is never refused by the seam
- Columns: a stat from a newer build is still LISTED so the player can remove it

### test_degraded.lua (26)

- Degraded: the library really is absent, so every case below is measuring a stub
- Degraded: every seam soft-optionals its major, so a missing library is not a load error
- Degraded: core/CoreSetup.lua takes its fallback and the printer still works
- Degraded: the 'not installed' line is said ONCE, on the first line the addon prints
- Degraded: the secret-safe probe survives, because this addon's values are secret
- Degraded: the window chrome degrades to NOTHING rather than to a hand-copied backdrop
- Degraded: the stored-color reader does NOT degrade to nothing
- Degraded: core/PerfSetup.lua takes its fallback and every bracket short-circuits
- Degraded: core/DebugLogSetup.lua takes its fallback and the flag still works
- Degraded: settings/Slash.lua takes its fallback
- Degraded: settings/OptionsSetup.lua takes its fallback and says the panel is unavailable
- Degraded: `/mm` with no arguments still prints help
- Degraded: every declared verb is reachable and none of them raises
- Degraded: the schema verbs NAME the missing library rather than going quiet
- Degraded: the host verbs are untouched, because they never went to the library
- Degraded: an unknown verb is named and followed by help
- Degraded: `/mm version` still answers with the packaged version
- Degraded: the options stub publishes every Helpers member the page files touch
- Degraded: LSMValues keeps its DEFERRED shape and never answers an empty list
- Degraded: reset-everything still works, and still refuses to touch the Profiles page
- Degraded: the schema row count is UNCHANGED versus a full load
- Degraded: the schema is the same rows, path for path and page for page
- Degraded: every schema page is registered as an options page on both paths
- Degraded: the namespace publishes the same seam members with and without the library
- Degraded: every NS.Perf member the addon actually reaches exists on the stub
- Degraded: the addon still enables end to end with no library

## Totals

| Suite | Cases |
|-------|------:|
| test_loadorder.lua | 7 |
| test_constants.lua | 21 |
| test_secrets.lua | 38 |
| test_compat.lua | 23 |
| test_state.lua | 17 |
| test_locale.lua | 11 |
| test_database.lua | 38 |
| test_diagnostics.lua | 13 |
| test_defaults.lua | 24 |
| test_coresetup.lua | 22 |
| test_perfsetup.lua | 19 |
| test_debuglogsetup.lua | 18 |
| test_lifecycle.lua | 23 |
| test_vendor_sync.lua | 2 |
| test_format.lua | 25 |
| test_provider.lua | 35 |
| test_roster.lua | 22 |
| test_aggregator.lua | 52 |
| test_aggregator_sort.lua | 16 |
| test_window.lua | 82 |
| test_row.lua | 60 |
| test_targets.lua | 22 |
| test_tooltip.lua | 59 |
| test_drilldown.lua | 31 |
| test_visibility.lua | 22 |
| test_windowmanager.lua | 31 |
| test_minimap.lua | 17 |
| test_schema.lua | 32 |
| test_schema_defaults.lua | 10 |
| test_slash.lua | 29 |
| test_options_panel.lua | 22 |
| test_columns.lua | 23 |
| test_degraded.lua | 26 |
| **Total** | **892** |
