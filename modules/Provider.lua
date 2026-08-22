-- modules/Provider.lua
--
-- THE ONLY READER OF THE METER. Every number this addon shows enters the addon
-- through this file, and nothing here ever looks at one.
--
-- ---------------------------------------------------------------------------
-- THE SHAPE OF THE RULE
-- ---------------------------------------------------------------------------
--
-- The provider's whole job is to turn Blizzard's session tables into a flat
-- column table the aggregator can join on, WITHOUT inspecting a single value on
-- the way. It copies fields across. It never compares one, never adds two,
-- never uses one as a table key, never measures a table's length with `#`, and
-- never asks whether a number is "big enough to show" — every one of those is an
-- immediate Lua error while the Combat restriction is active, and every one of
-- them is the kind of line that gets added later by somebody being helpful.
--
-- Two habits enforce it, and they are visible in every function below:
--   * a session table is reached ONLY after NS.Secrets.CanAccessTable says so.
--     A secret table cannot be indexed at all, so `session.maxAmount` on an
--     unguarded read is not a wrong answer, it is a raise.
--   * combatSources and combatSpells are walked with NS.Secrets.SafeIterate,
--     never with ipairs and never with `#`. SafeIterate stops at the first nil
--     and applies no length operator, which is the only walk that is correct on
--     both a plain array and a secret one.
--
-- Nothing else in the addon names C_DamageMeter — and this file does not name it
-- either. Every call goes through NS.Compat, which owns the "does this client
-- even have the namespace" question (architecture-§1). So an 11.x client, or a
-- PTR build missing one function, degrades to an empty column carrying a REASON
-- rather than erroring: modules/Window.lua renders the reason in place of rows.
--
-- ---------------------------------------------------------------------------
-- THE UNVERIFIED ASSUMPTION, ISOLATED HERE ON PURPOSE
-- ---------------------------------------------------------------------------
--
-- `sources` below is returned in EXACTLY the order the API handed us
-- combatSources, and the addon's `provider` sort mode treats that order as
-- "sorted by the requested stat, descending".
--
-- NOTHING IN BLIZZARD'S DOCUMENTATION SAYS THAT. It is an assumption taken from
-- how the built-in meter displays, and it is recorded here rather than in a
-- commit message because this file is the ONLY place a correction would land:
--   * `provider` sort mode depends on it.
--   * `value` sort mode does not — it orders by the values themselves whenever
--     comparison is legal.
--   * `roster` sort mode does not — it orders by group position.
-- If it proves false in-game, the fix is a sort inside GetColumn (legal out of
-- combat, and out of combat is the only time `value` mode would have needed it
-- anyway), and no other file changes. Design §5 records the same thing.
--
-- IT IS NOW MEASURABLE RATHER THAN ONLY ASSERTED. core/Diagnostics.lua's
-- `provider order` section walks each column in the order returned here and
-- reports whether the totals descend — legal out of combat, where the amounts
-- are plain, and refused with `cannot be checked` rather than a false all-clear
-- inside a pull. It disproves the assumption outright or leaves it standing on
-- evidence, which is what this comment could not do on its own.
--
-- ---------------------------------------------------------------------------
-- WHAT IS NOT HERE
-- ---------------------------------------------------------------------------
--
-- Filtering. Deciding that a source is a group member, a pet, or an enemy is
-- modules/Roster.lua's and modules/Aggregator.lua's job. The provider hands over
-- everything the session contained, in order, because the moment it starts
-- dropping rows it needs a policy, and a policy in the data layer is a policy
-- two other files will disagree with.
--
-- Enum.DamageMeterType.Dps and .Hps are never queried, here or anywhere:
-- `amountPerSecond` ships on the same source row as `totalAmount`, so one
-- DamageDone read fills both halves of the Damage column (design §3).

local addonName, NS = ...

local Provider = NS:NewModule("Provider", "AceEvent-3.0")
NS.Provider = Provider

local Compat      = NS.Compat
local Secrets     = NS.Secrets
local State       = NS.State
local Const       = NS.Constants
local MSG         = Const.MSG
local STAT_BY_KEY = Const.STAT_BY_KEY

-- Perf bracket upvalue, resolved ONCE at load and never through an NS lookup on
-- the read path (performance-§2). core/PerfSetup.lua is in the core block, so
-- this is the real instance or its stub — never nil.
local Perf = NS.Perf

-- ---------------------------------------------------------------------------
-- BOTH CALL SHAPES, ON PURPOSE
-- ---------------------------------------------------------------------------
--
-- The read API is documented as plain functions — `NS.Provider.GetColumn(s, k)`
-- — because none of it needs a `self`. But this module is also an AceAddon
-- module, and every consumer written against a module reaches for it with a
-- colon: modules/Window.lua calls `Provider:IsAvailable()`, modules/Tooltip.lua
-- and modules/DrillDown.lua call `P:GetSourceDetail(...)`.
--
-- Rather than pick one and leave the other as a silent argument shift — which
-- would not error, it would just read the WRONG SESSION, in combat, where
-- nobody can see it — every entry point accepts both. `args` drops the leading
-- self when it is this module and passes everything through otherwise. It is
-- three lines and it removes an entire class of integration bug.
local function args(a, b, c, d, e, f)
    if a == Provider then return b, c, d, e, f end
    return a, b, c, d, e
end

-- ---------------------------------------------------------------------------
-- ADDRESSING A SESSION: BY TYPE, OR BY ID
-- ---------------------------------------------------------------------------
--
-- Every read below takes an OPTIONAL trailing `sessionID`. Nil means "the
-- Current or Overall session named by sessionType", which is what every caller
-- meant before the segment selector existed and is still the default. A number
-- means "that specific stored segment", which is what modules/Window.lua passes
-- when the player has picked one out of the header dropdown.
--
-- The branch lives here rather than in modules/Window.lua or the aggregator
-- because this file is the only permitted caller of the C_DamageMeter shims
-- (architecture-§1), and `GetCombatSessionFromID` is a different shim from
-- `GetCombatSessionFromType` rather than the same one with a different argument.

--- The session table for a stat, addressed either way.
--- @param sessionType number
--- @param sessionID number|nil
--- @param enumValue number
--- @return table|nil
local function sessionFor(sessionType, sessionID, enumValue)
    if sessionID == nil then
        return Compat.GetCombatSessionFromType(sessionType, enumValue)
    end
    return Compat.GetCombatSessionFromID(sessionID, enumValue)
end

-- ---------------------------------------------------------------------------
-- Availability
-- ---------------------------------------------------------------------------
--
-- IsDamageMeterAvailable is cheap but it is asked once per column per refresh —
-- seven columns at four refreshes a second — so the answer is memoized and
-- invalidated on the meter's own events instead. The invalidation set is small
-- because there are only three ways the answer can change: the meter was reset,
-- a session boundary moved, or the player zoned (which is when a CVar or an
-- instance restriction takes effect).

local memo = { checked = false, ok = false, reason = nil }

--- Whether the built-in meter is usable right now, and Blizzard's own reason
--- when it is not.
---
--- The reason is passed through untranslated and uninterpreted: it is the only
--- thing that can tell a player their meter is off because of a setting rather
--- than because this addon is broken, and second-guessing it here would replace
--- a true statement with a guess.
---
--- @return boolean isAvailable, any failureReason
function Provider.IsAvailable(_)
    -- Test mode answers YES without asking the client. A player laying a window
    -- out on a machine whose meter is switched off would otherwise get the
    -- "meter unavailable" notice instead of a grid.
    if NS.State and NS.State.testMode then return true, nil end
    if memo.checked then return memo.ok, memo.reason end
    local ok, reason = Compat.IsDamageMeterAvailable()
    memo.checked = true
    memo.ok      = ok and true or false
    memo.reason  = reason
    return memo.ok, memo.reason
end

--- Forget the memoized availability answer. Called from the meter's events.
function Provider.InvalidateAvailability()
    memo.checked = false
end

-- ---------------------------------------------------------------------------
-- Column reads
-- ---------------------------------------------------------------------------

-- Suspended is the perf harness's inert state (performance-§6): a suspended
-- capture must stop the addon ASKING for data, not merely stop drawing it. So
-- the flag is checked at the top of the read rather than at the top of the
-- render, and a suspended provider answers an empty column with a reason.
local suspended = false

-- The collector the source walk writes into, plus the ONE closure SafeIterate
-- calls. Hoisted to file scope rather than built per call because GetColumn runs
-- seven times per refresh: a fresh closure per call is 28 allocations a second
-- doing nothing but capturing a local that never changes shape. GetColumn is not
-- reentrant — it takes no callbacks and yields nowhere — so a shared collector
-- is safe, and `collect` is re-pointed at the top of every walk.
local collect = nil

--- SafeIterate callback: one DamageMeterCombatSource -> one plain row.
---
--- Every field is COPIED, never examined. `name` is ConditionalSecret and
--- `totalAmount` / `amountPerSecond` / `deathTimeSeconds` are secret in combat;
--- they land in table VALUES, which is explicitly permitted, and travel onward
--- as opaque handles.
---
--- `sourceGUID` WAS the field the whole design rested on — "the meter's source
--- GUID is never secret, so it is the only field legal as a table KEY, and it is
--- therefore the join key for every column" (design §5). MEASURED IN-GAME, THAT
--- IS FALSE: under the Combat restriction it arrives secret AND inaccessible, so
--- for the duration of a pull there is no join key at all and every source was
--- dropped as unidentifiable.
---
--- It is still copied here, unexamined, exactly like every other field — a
--- secret in a table VALUE is permitted, and out of combat it is the plain join
--- key it always was. What changed is downstream: modules/Aggregator.lua no
--- longer assumes it can key on one, and rebuilds the local player's identity
--- from `isLocalPlayer` (which stays plain) when it cannot.
---
--- The UNIT API is no safer — it hands out secret GUIDs too (a follower
--- dungeon's companion pets), which is why modules/Roster.lua vets every GUID it
--- reads through NS.Secrets.IsSafeKey before keying on one. NEITHER source of
--- GUIDs may be assumed plain.
local function collectSource(_, src)
    -- A row inside an accessible session can still be individually inaccessible.
    -- Guarding per row costs one call and removes the only remaining way this
    -- loop could raise.
    if not Secrets.CanAccessTable(src) then return end

    local guid       = src.sourceGUID
    local creatureID = src.sourceCreatureID
    -- A source is kept when EITHER identifier is present.
    --
    -- This used to require a `sourceGUID`, and that silently emptied the whole
    -- EnemyDamageTaken column: an NPC source carries a `sourceCreatureID` and NO
    -- player GUID, so every enemy failed the guard and the column reported zero
    -- sources with `reason = nil` — "the session was fine and held nothing",
    -- which is the most misleading answer available. It took the tooltip's
    -- Targets section down with it, since that column is what the cross-reference
    -- is built from.
    --
    -- Nil-ness only, on both. Never `if guid then`, which is a boolean test and
    -- raises on a secret.
    if guid == nil and creatureID == nil then return end

    collect[#collect + 1] = {
        guid              = guid,
        creatureID        = creatureID,
        name              = src.name,
        classFilename     = src.classFilename,
        specIconID        = src.specIconID,
        isLocalPlayer     = src.isLocalPlayer,
        totalAmount       = src.totalAmount,
        amountPerSecond   = src.amountPerSecond,
        deathTimeSeconds  = src.deathTimeSeconds,
        deathRecapID      = src.deathRecapID,
        classification    = src.classification,
        sourceDisplayType = src.sourceDisplayType,
        factionGroup      = src.factionGroup,
    }
end

--- One column of the grid: a session read for one stat, flattened.
---
--- @param sessionType number   Enum.DamageMeterSessionType (Current / Overall)
--- @param statKey string       a key from Constants.STATS
--- @return table  {
---   stat            = statKey,
---   maxAmount       = opaque,      -- what every bar in the column scales to
---   totalAmount     = opaque,      -- the group total, for the header
---   durationSeconds = opaque,
---   reason          = string|nil,  -- why the column is empty, when it is
---   failureReason   = any|nil,     -- Blizzard's own, verbatim
---   sources         = { { guid, name, classFilename, specIconID, isLocalPlayer,
---                         totalAmount, amountPerSecond, deathTimeSeconds,
---                         deathRecapID, classification, sourceDisplayType }, ... }
--- }
--- `sources` is in the order the API returned — see the header's assumption.
--- Callable as either `Provider.GetColumn(s, k)` or `Provider:GetColumn(s, k)`.
function Provider.GetColumn(a, b, c, d)
    local sessionType, statKey, sessionID = args(a, b, c, d)

    -- TEST MODE SUBSTITUTES THE DATA SOURCE AND NOTHING ELSE.
    --
    -- It used to be a branch in modules/Window.lua's render path, which handed
    -- the renderer a whole separate result table built by a separate function.
    -- The consequence was that test mode and normal mode were two code paths that
    -- LOOKED alike and behaved differently at every seam nobody thought to
    -- duplicate: tooltips found no source and said "No data yet", the drill-down
    -- opened on nothing, sorting ran over a table the sorter had not built, and
    -- every fix had to be applied twice.
    --
    -- Mocking HERE — at the one function that talks to C_DamageMeter — makes the
    -- two modes identical by construction. Everything downstream is the live code
    -- path, reading numbers that happen to be invented, which is the only
    -- difference there should ever have been.
    if NS.State and NS.State.testMode then
        local A = NS.Aggregator
        if A and A.TestColumn then return A.TestColumn(sessionType, statKey) end
    end

    local column = { stat = statKey, sources = {} }

    if suspended then
        column.reason = "suspended"
        return column
    end

    local stat = STAT_BY_KEY[statKey]
    if not stat then
        -- A column configured against a build that offered more stats than this
        -- one. Named rather than silently skipped so `/mm status` can say which.
        column.reason = "unknown stat"
        return column
    end

    local available, failure = Provider.IsAvailable()
    if not available then
        column.reason        = "unavailable"
        column.failureReason = failure
        return column
    end

    local t0 = Perf.on and debugprofilestop()

    local session = sessionFor(sessionType, sessionID, stat.enumValue)
    if type(session) ~= "table" then
        column.reason = "no session"
    elseif not Secrets.CanAccessTable(session) then
        -- The whole session is opaque to us. Empty, with a distinct reason: "we
        -- may not look" is a different fact from "there is nothing there", and
        -- the window says different things about them.
        column.reason = "session sealed"
    else
        column.maxAmount       = session.maxAmount
        column.totalAmount     = session.totalAmount
        column.durationSeconds = session.durationSeconds

        collect = column.sources
        Secrets.SafeIterate(session.combatSources, collectSource)
        collect = nil
    end

    if t0 then Perf.Note("providerRead", debugprofilestop() - t0) end
    return column
end

-- ---------------------------------------------------------------------------
-- Per-source drill-down
-- ---------------------------------------------------------------------------

--- The spell breakdown behind one cell — what the tooltip and the drill-down
--- are made of.
---
--- RETURNS BLIZZARD'S OWN sessionSource TABLE, guarded but NOT flattened. That
--- is a deliberate departure from GetColumn, which does flatten, and the reason
--- is the shape of the two consumers. A column is joined across seven stats and
--- forty rows, so flattening it once beats every consumer re-walking a possibly
--- secret array. A source detail is read by exactly two callers — the tooltip
--- and the drill-down — each of which already walks `combatSpells` through
--- NS.Secrets.SafeIterate to honor its own display limit ("and 6 more…", the
--- drill-down's row cap). Flattening here would walk the array a second time to
--- build a list neither of them wants whole.
---
--- What this function DOES do is the part neither caller can safely do for
--- itself: refuse. A nil return means "there is nothing to show, for one of the
--- reasons below" — meter off, unknown stat, suspended capture, no such source,
--- or a session table this execution context may not access. A caller that got a
--- table may index it; that is the guarantee being bought here.
---
--- Callable as `Provider.GetSourceDetail(...)` or `Provider:GetSourceDetail(...)`.
---
--- @param sessionType number
--- @param statKey string
--- @param guid string|nil          the source to describe
--- @param creatureID number|nil    for enemy sources, which have no player GUID
--- @return table|nil  { combatSpells, maxAmount, totalAmount }, or nil
function Provider.GetSourceDetail(a, b, c, d, e, f)
    local sessionType, statKey, guid, creatureID, sessionID = args(a, b, c, d, e, f)

    -- Same substitution as GetColumn, for the same reason: the tooltip and the
    -- drill-down must not know which mode they are in.
    if NS.State and NS.State.testMode then
        local A = NS.Aggregator
        if A and A.TestSourceDetail then return A.TestSourceDetail(guid, statKey) end
    end

    if suspended then return nil end

    local stat = STAT_BY_KEY[statKey]
    if not stat then return nil end
    if not Provider.IsAvailable() then return nil end

    -- guid and creatureID are forwarded as given, including nil: they are
    -- OPTIONAL in the underlying signature and inventing a default would change
    -- which source the API answers for (core/Compat.lua says the same).
    local source
    if sessionID == nil then
        source = Compat.GetCombatSessionSourceFromType(sessionType, stat.enumValue, guid, creatureID)
    else
        source = Compat.GetCombatSessionSourceFromID(sessionID, stat.enumValue, guid, creatureID)
    end
    if type(source) ~= "table" then return nil end

    -- A sealed session cannot be indexed at all, so handing it back would move
    -- the raise from here into the tooltip. Refusing is the whole job.
    if not Secrets.CanAccessTable(source) then return nil end

    return source
end

--- DIAGNOSTIC ONLY: can the API resolve a source from a SECRET sourceGUID?
---
--- THE QUESTION THE WHOLE MID-PULL GRID TURNS ON. `sourceGUID` is annotated
--- SecretWhenInCombat, so Lua may not key on it, compare it or look it up — but
--- passing a secret to a function IS permitted, and this API takes a sourceGUID
--- as an argument. If the native side will accept the secret handle we were just
--- handed, then the per-source join we may not perform in Lua can be performed
--- BY THE CLIENT: read the sort column's sources, then ask for each source's
--- figure in every other column by passing its own opaque GUID straight back.
--- That is a full multi-column grid mid-pull rather than the local player's row
--- alone.
---
--- Answers a short plain string rather than a boolean, because the interesting
--- failures are different from each other: "raised" says the argument is refused
--- outright, "nil" says it is accepted and matches nothing, and "sealed" says we
--- get a table we may not read.
---
--- pcall, because this is the one call in the addon deliberately made with an
--- argument the contract does not promise is legal. Reached only from
--- modules/Aggregator.lua's first-drop debug line, so it is off unless the debug
--- flag is on and costs one call per refresh when it is.
---
--- @return string
function Provider.ProbeSourceByGuid(sessionType, statKey, guid)
    local stat = STAT_BY_KEY[statKey]
    if not stat then return "no stat" end

    local ok, source = pcall(Compat.GetCombatSessionSourceFromType,
        sessionType, stat.enumValue, guid)
    if not ok then return "raised" end
    if type(source) ~= "table" then return "nil" end
    if not Secrets.CanAccessTable(source) then return "sealed" end
    return (source.totalAmount ~= nil) and "resolved" or "no total"
end

-- ---------------------------------------------------------------------------
-- Sessions
-- ---------------------------------------------------------------------------

--- Every session the client still holds, for the session picker.
---
--- Always an array (Compat answers {} where the API is absent), so the picker
--- iterates unconditionally. The entries are Blizzard's own
--- { sessionID, name, durationSeconds } and are passed through untouched.
---
--- @return table
function Provider.GetAvailableSessions(_)
    if suspended then return {} end
    return Compat.GetAvailableCombatSessions()
end

--- How long a session has been running. SECRET in combat, so it goes to
--- NS.Format.Duration rather than into any arithmetic here.
---
--- A SPECIFIC SEGMENT TAKES A DIFFERENT ROUTE, because the API offers no
--- "duration of session N" call: `GetSessionDurationSeconds` is type-addressed
--- only. The duration of a stored segment instead ships on that segment's own
--- entry in GetAvailableCombatSessions, so it is looked up there. The lookup
--- compares sessionIDs, never durations — an ID is plain, a duration is not.
---
--- @param sessionType number
--- @param sessionID number|nil
--- @return any
function Provider.GetSessionDuration(a, b, c)
    local sessionType, sessionID = args(a, b, c)
    -- A fixed, plausible duration, so the header reads the same shape it will
    -- with real data.
    if NS.State and NS.State.testMode then return 212 end
    if suspended then return nil end

    if sessionID == nil then
        return Compat.GetSessionDurationSeconds(sessionType)
    end

    for _, entry in ipairs(Compat.GetAvailableCombatSessions()) do
        if type(entry) == "table" and entry.sessionID == sessionID then
            return entry.durationSeconds
        end
    end
    return nil
end

--- Whether `sessionID` is still one the client is holding.
---
--- The staleness check behind a PERSISTED segment choice: a window that saved
--- "segment 4" and came back after a reload, a meter reset or a zone change must
--- not sit there drawing an empty grid for a session that no longer exists. The
--- window falls back to its sessionType when this answers false.
---
--- Compares IDs only. A sessionID is a plain number; the `name` and
--- `durationSeconds` beside it are not necessarily, and are not touched here.
---
--- @param sessionID number|nil
--- @return boolean
function Provider.HasSession(a, b)
    local sessionID = args(a, b)
    if sessionID == nil then return false end
    if suspended then return false end

    for _, entry in ipairs(Compat.GetAvailableCombatSessions()) do
        if type(entry) == "table" and entry.sessionID == sessionID then return true end
    end
    return false
end

--- Wipe every session the client holds.
---
--- THE ONLY SUPPORTED WAY TO RESET THE METER. The Data settings page's
--- confirmation popup comes here rather than to
--- NS.Compat.ResetAllCombatSessions, because this file is the only permitted
--- caller of the C_DamageMeter shims (architecture-§1) and because a bare shim
--- call resets the meter and leaves the addon believing everything it had
--- cached is still true.
---
--- Never wired to a refresh path: it destroys data the player may be reading,
--- and an addon that can silently reset the meter is an addon that will be
--- blamed for a lost log.
---
--- What the shim alone does NOT do, and this function therefore does:
---   * forgets the memoized availability answer — a reset is one of the three
---     ways it can change (see the Availability block above);
---   * announces METER_RESET on the bus, which is what wipes the frozen sort
---     orders, drops every open drill-down and marks the windows dirty. The game
---     fires DAMAGE_METER_RESET too and core/MythicMeters.lua fans that onto the
---     same message, so the dispatch may happen twice — every handler on it is
---     idempotent, and a duplicate wipe is a far smaller problem than a window
---     that keeps drawing rows for sessions that no longer exist if the event
---     never arrives.
---
--- @return boolean  whether the call reached the API
function Provider.Reset(_)
    local ok = Compat.ResetAllCombatSessions()
    if not ok then return false end

    Provider.InvalidateAvailability()
    if Provider.SendMessage then Provider:SendMessage(MSG.METER_RESET) end
    if State.debug then NS.Debug("Provider", "reset all combat sessions") end
    return true
end

-- ---------------------------------------------------------------------------
-- Death recaps (issue #1)
-- ---------------------------------------------------------------------------
--
-- One death, opened up: the incoming events that ended it, plus the max health
-- an HP percentage divides by. `C_DeathRecap` resolves this for ANY player in
-- the group and ANY death earlier in the run — measured, not assumed; see
-- docs/superpowers/specs/2026-08-22-death-recap-design.md §1.

--- recapID -> { events, maxHealth }, or `false` for "asked, there is nothing".
---
--- THE MEMO IS A CORRECTNESS REQUIREMENT, NOT AN OPTIMISATION. The death
--- drill-down needs one read PER DEATH merely to label its rows with a wall-clock
--- time, and modules/Window.lua rebuilds those rows on every refresh pass — four
--- times a second. Uncached, a five-death list is twenty client calls a second
--- for a list that cannot change: a death that has already happened is immutable,
--- which is exactly what makes caching it safe.
---
--- The negative is cached too, as `false` rather than nil, so a death the client
--- no longer holds is asked about once instead of on every pass. `false` is
--- distinguishable from "not asked yet" and, unlike nil, survives a table lookup.
local recapCache = {}

--- Forget every cached recap.
---
--- Recap ids are SESSION-SCOPED COUNTERS — a live dump showed 18 through 29 for
--- one run — so id 29 in the next run is a different player's different death. A
--- memo that outlived a reset would show one player the recap of another, which
--- is worse than showing nothing.
function Provider.InvalidateRecaps()
    recapCache = {}
end

--- The breakdown behind one death, or nil.
---
--- @param recapID number  a `deathRecapID` from a Deaths source row
--- @return table|nil  { events = array (newest first), maxHealth = opaque }
function Provider.GetRecap(recapID)
    -- Suspended first, above everything, exactly like GetColumn: performance-§6
    -- says a suspended capture must stop the addon ASKING, not merely stop
    -- drawing, and an answer served from the memo would still be an answer this
    -- module is meant to be incapable of giving.
    if suspended then return nil end

    -- `deathRecapID` is documented NeverSecret and this does not bet a raise on
    -- it. A secret cannot be a table key — indexing the memo with one raises
    -- before the client is ever reached — and forwarding one into a client
    -- function is the `bad argument #4` that already shipped once through
    -- modules/Targets.lua. Both hazards are closed by the same gate.
    if not Secrets.IsSafeKey(recapID) then return nil end

    local cached = recapCache[recapID]
    if cached ~= nil then return cached or nil end

    -- The cheap gate first. A death the client no longer holds answers here
    -- rather than through an empty array we would have to measure — and
    -- measuring an array of meter values is what `#` is forbidden for.
    if not Compat.HasRecapEvents(recapID) then
        recapCache[recapID] = false
        return nil
    end

    local events = Compat.GetRecapEvents(recapID)
    if events == nil then
        recapCache[recapID] = false
        return nil
    end

    -- maxHealth is allowed to be absent. It is only the denominator of the HP
    -- percentage, and modules/Tooltip.lua degrades to a bar without one; losing
    -- the whole recap because the client withheld one number would be a much
    -- larger failure than the one being handled.
    local recap = { events = events, maxHealth = Compat.GetRecapMaxHealth(recapID) }
    recapCache[recapID] = recap
    return recap
end

-- ---------------------------------------------------------------------------
-- The death-recap probe (issue #1)
-- ---------------------------------------------------------------------------
--
-- Issue #1 wants a two-pane Death Recap window and cannot be designed until
-- three facts about the running client are in hand: whether a `deathRecapID`
-- resolves for a NON-LOCAL player, whether it resolves for a death from EARLIER
-- IN THE RUN, and whether any reader exists that hands back the per-event
-- breakdown at all. This addon has never read a recap — modules/DrillDown.lua
-- only hands an id off to Blizzard's own frame — so all three are guesses, and
-- the issue says plainly that guessing wrong turns the feature into its own
-- combat-log capture.
--
-- The two functions below are the provider's half of the answer, and they are
-- pass-throughs on purpose: the search may have to look at the meter namespace
-- itself, which only core/Compat.lua may name. They DISCOVER and CALL. They
-- never conclude and they never inspect — a recap event's amount and its HP
-- figure are meter values, so a result travels back as an opaque handle exactly
-- like every other read above. core/Diagnostics.lua does the describing.

--- Every member of every candidate namespace, unfiltered. See the shim.
--- @return table  { { ns = "C_DeathInfo", present = true, names = { ... } }, ... }
function Provider.RecapMembers()
    return Compat.RecapMembers()
end

--- Every recap reader the client will answer to, from both searches. See the
--- shim; `how` says which search found it, and that is the finding.
--- @return table  { { ns = "C_DeathInfo", name = "GetRecapEvent", how = "walk" }, ... }
function Provider.RecapAPIs()
    return Compat.RecapAPIs()
end

--- Call one discovered reader and hand back the outcome, whatever it is.
--- @param nsName string  a namespace name from RecapAPIs()
--- @param fnName string  a member name from RecapAPIs()
--- @return boolean ok, any valueOrError
function Provider.CallRecap(nsName, fnName, ...)
    return Compat.CallRecap(nsName, fnName, ...)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
--
-- The provider registers no GAME events — core/MythicMeters.lua owns every one
-- of those and fans them onto the bus (architecture-§4). What it registers is
-- the three bus messages that can invalidate a memoized answer. Being an
-- AceAddon module, it is its OWN AceEvent target, so its subscriptions cannot
-- clobber another consumer's.

function Provider:OnEnable()
    self:RegisterMessage(MSG.METER_RESET,    "OnMeterInvalidated")
    self:RegisterMessage(MSG.METER_SESSION,  "OnMeterInvalidated")
    self:RegisterMessage(MSG.ENTERING_WORLD, "OnMeterInvalidated")
end

function Provider:OnMeterInvalidated()
    Provider.InvalidateAvailability()
    -- The recap memo goes with it. Recap ids are session-scoped counters, so the
    -- same id means a different death after a reset — see InvalidateRecaps.
    Provider.InvalidateRecaps()
end

--- Perf-harness suspend (performance-§6). Stops the addon ASKING the meter for
--- anything: reads answer an empty column, availability is forgotten so the
--- resume re-checks it, and the bus subscriptions come down so a busy pull does
--- no work at all behind a suspended capture.
function Provider:Suspend()
    if suspended then return end
    suspended = true
    self:UnregisterAllMessages()
    if State.debug then NS.Debug("Provider", "suspended") end
end

--- Undo Suspend. Re-checks availability on the next read rather than caching the
--- pre-suspend answer, which may be stale by an entire instance.
function Provider:Resume()
    if not suspended then return end
    suspended = false
    Provider.InvalidateAvailability()
    self:OnEnable()
    if State.debug then NS.Debug("Provider", "resumed") end
end

--- Whether reads are currently inert. Published for `/mm status` and the tests.
--- @return boolean
function Provider.IsSuspended(_)
    return suspended
end
