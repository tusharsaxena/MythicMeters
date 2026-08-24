-- tests/perf.lua — the offline scenario runner (performance-§9).
--
--   lua tests/perf.lua [--out <path>] [--label <text>]
--
-- DELIBERATELY OUTSIDE THE GREEN GATE. `lua tests/run.lua` does not invoke this
-- and no commit depends on it. What it asserts is the DETERMINISTIC half — how
-- many C_DamageMeter reads a refresh makes, how many refreshes a burst of events
-- produces, how many unit-API walks a roster change costs, and how many bytes a
-- dormant perf bracket allocates. It asserts NO wall-clock threshold, ever: those
-- vary with the machine and the CPU governor, and a gate that flakes is a gate
-- everyone learns to bypass.
--
-- Timings are printed for orientation ONLY. Read them as ratios between scenarios
-- inside one run, never as absolute numbers to compare across machines.
--
-- WHY THESE SCENARIOS. This addon's cost is event-driven rather than per-frame: a
-- busy pull fires DAMAGE_METER_CURRENT_SESSION_UPDATED far faster than anything
-- needs to redraw, which is why every window coalesces to an interval instead of
-- refreshing per event. So the two questions worth measuring are "what does one
-- coalesced pass cost at raid size" and "does the coalescing actually coalesce" —
-- plus the three transitions that force a full rebuild. Design §11 names exactly
-- this list.
--
-- THE ONE THAT IS A REGRESSION GUARD. `refresh20x7` asserts that ONE refresh
-- makes exactly ONE Provider.GetColumn call per enabled column. It used to make
-- two: modules/Window.lua re-entered the provider for each column's group total so
-- the cells could divide by it, while modules/Aggregator.lua already held both
-- operands and already divided (`cell.percent`). That was a doubling of the
-- addon's entire session-read cost on its hot path, and it was invisible because
-- nothing counted. This counts.

local root = (arg and arg[0] and arg[0]:match("^(.*)/tests/perf%.lua$")) or "."
package.path = root .. "/tests/?.lua;" .. package.path

local Loader  = dofile(root .. "/tests/_kit/loader.lua")
local mockmod = assert(loadfile(root .. "/tests/wow_mock.lua"))(root)

-- Each dofile of the kit loader returns a FRESH table, so this runner sets its
-- own addonName rather than inheriting one from tests/run.lua. Chunks are called
-- as ("MultiMeters", NS) to match the client's `local addonName, NS = ...`
-- header — core/PerfSetup.lua reads that first argument.
Loader.addonName = "MultiMeters"

-- ── arguments ───────────────────────────────────────────────────────────────

local opts = { out = nil, label = "offline" }
do
    local i = 1
    while arg and arg[i] do
        local a = arg[i]
        if a == "--out" then opts.out = arg[i + 1]; i = i + 2
        elseif a == "--label" then opts.label = arg[i + 1] or opts.label; i = i + 2
        else
            io.stderr:write("unknown argument: " .. tostring(a) .. "\n")
            io.stderr:write("usage: lua tests/perf.lua [--out <path>] [--label <text>]\n")
            os.exit(2)
        end
    end
end

-- ── environment ─────────────────────────────────────────────────────────────
--
-- Both load lists are DERIVED, never typed here (testing-§9). This runner is not
-- executed by `lua tests/run.lua`, so a hand-maintained list would rot silently
-- while the figures it produces were still being read as evidence. The library
-- half comes from LibKa0s.xml — the file the TOC actually reaches — because
-- omitting Core.lua does not fail loudly: Perf simply refuses to register,
-- NS.Perf becomes core/PerfSetup.lua's degradation stub, and the zero-overhead
-- scenario quietly measures a stub with no probe in it.

local mocks = mockmod.build()
mocks._G = Loader.makeEnv(mocks)

local NS = {}
Loader.loadAll(Loader.xmlFiles(root .. "/libs/LibKa0s/LibKa0s.xml"), NS, mocks)
do
    local toc = Loader.tocFiles(root .. "/MultiMeters.toc")
    for i, rel in ipairs(toc) do toc[i] = root .. "/" .. rel end
    Loader.loadAll(toc, NS, mocks)
end

assert(NS.Perf and NS.Perf.Note, "NS.Perf did not resolve — the library load list is wrong")
assert(NS.Perf.SCHEMA, "NS.Perf is core/PerfSetup.lua's degradation stub, not the library "
    .. "instance — every figure below would be measuring a no-op")

-- ── the fixture ─────────────────────────────────────────────────────────────
--
-- Twenty players in a raid, standing in a dungeon, with a seven-column window
-- locked (so it draws live data rather than the preview grid) and every column
-- backed by a real session.

local MEMBERS = 20
local STAT_KEYS = {
    "DamageDone", "HealingDone", "Absorbs", "Interrupts",
    "Dispels", "AvoidableDamageTaken", "Deaths",
}

do
    local roster = {}
    for i = 1, MEMBERS do
        roster[i] = {
            guid = string.format("Player-1-%08X", i),
            name = "Mock" .. i,
            class = ({ "WARRIOR", "PRIEST", "MAGE", "ROGUE", "HUNTER" })[((i - 1) % 5) + 1],
            role = (i == 1 and "TANK") or (i == 2 and "HEALER") or "DAMAGER",
        }
    end
    mocks.setGroup(roster, { raid = true })
    -- A dungeon, because a dungeon is what this is meant to measure: a raid-sized
    -- group at meter event rate. The shipped defaults would allow the open world
    -- too, but a context that is only allowed by default is one setting away from
    -- refusing at the source (performance-§6), which would leave this measuring
    -- nothing at all rather than measuring less.
    mocks.setInstance("party")
end

-- OVERALL, BECAUSE THAT IS WHAT THE SHIPPED WINDOW READS.
--
-- This seeded `Current` while `defaults/Profile.lua` sets `data.sessionType` to
-- Overall, so every measured pass asked the mock for a session it had never been
-- given, got "no session" back, and produced no rows — a fixture that did not
-- join. The figures downstream were therefore measuring the empty path: seven
-- column reads that each returned nothing, a render of zero rows, and a
-- drill-down that had no row to open.
--
-- Nothing here forces the window's config to match the fixture, deliberately.
-- The harness has to measure the configuration a player actually runs, and if
-- the shipped default ever moves the fixture must move with it rather than a
-- line in this file quietly pinning the window to whatever the fixture happens
-- to hold. The assert below is what catches it either way.
local SESSION = NS.Constants.SESSION_TYPE.Overall
for _, key in ipairs(STAT_KEYS) do
    local stat = NS.Constants.STAT_BY_KEY[key]
    mocks.setSession(SESSION, stat.enumValue,
        mocks.buildSession{ count = MEMBERS, top = 4200000 })
    mocks.setSourceDetail(SESSION, stat.enumValue, "*", mocks.buildSourceDetail{ count = 6 })
end
mocks.setSessionDuration(SESSION, 212)

NS:InitDB()
NS:RunMigrations()
NS.CreateOptionsPanel()
NS:__enableAll()
if mocks.__flushTimers then mocks.__flushTimers() end

local window = NS.Database.GetWindows()[1]
assert(window, "no window in the registry — core/Database.lua's seed did not run")

-- Seven columns, and LOCKED so modules/Window.lua takes the live
-- Aggregator.Build path rather than BuildTestRows (an unlocked window implies
-- preview mode, which reads no session at all).
window.columns = {}
for _, key in ipairs(STAT_KEYS) do
    window.columns[#window.columns + 1] =
        { stat = key, width = NS.Constants.STAT_BY_KEY[key].defaultWidth, showBar = true }
end
window.frame.locked = true

local WM = NS.WindowManager
WM:Init()
local inst = WM.Get(window.id)
assert(inst, "no live window instance — modules/WindowManager.lua did not build one")
inst:ApplyConfig()
inst:RefreshVisibility()
assert(inst:IsShown(), "the window is hidden, so Refresh returns immediately and every "
    .. "figure below would be zero — check the visibility fixture")

-- ── the counting layer ──────────────────────────────────────────────────────
--
-- Wrapped HERE rather than inside tests/wow_mock.lua on purpose: the gated suite
-- must keep measuring the addon, not a counting shim, and a mock that counted for
-- everyone would be one more thing every future case has to reason about.
--
-- modules/Aggregator.lua captured `local Provider = NS.Provider` at load, but it
-- calls `Provider.GetColumn(...)` — a table index at CALL time on the same table
-- this replaces — so wrapping the member is enough and nothing has to be
-- reloaded.

local columnCalls = 0
do
    local original = NS.Provider.GetColumn
    NS.Provider.GetColumn = function(...)
        columnCalls = columnCalls + 1
        return original(...)
    end
end

local unitCalls = 0
do
    local original = mocks.UnitGUID
    mocks.UnitGUID = function(...)
        unitCalls = unitCalls + 1
        return original(...)
    end
end

local refreshes = 0
do
    -- An INSTANCE field shadowing the prototype method, so the throttle scenario
    -- can count passes without touching WindowProto (which every other window in
    -- a multi-window profile would share).
    local original = getmetatable(inst).__index.Refresh
    inst.Refresh = function(self, ...)
        refreshes = refreshes + 1
        return original(self, ...)
    end
end

-- ── measurement helpers ─────────────────────────────────────────────────────

local results  = {}
local failures = {}

local function assert_(cond, msg)
    if not cond then failures[#failures + 1] = msg end
    return cond
end

--- Run `fn` `iterations` times, reporting wall time, meter API calls, column
--- reads and bytes allocated PER ITERATION.
---
--- The allocation figure is the load-bearing one, and it is taken with the
--- COLLECTOR STOPPED. `collectgarbage("count")` reports the live heap, not the
--- total allocated, so with the incremental collector running the difference
--- across a loop is whatever survived the sweeps that happened to land inside it
--- — a figure that moves several kilobytes between identical runs and reported
--- the ARMED perf arm as cheaper than the dormant one, which is impossible.
--- Stopping the collector for the duration makes the delta the real allocation
--- total for the path, which is the quantity performance-§9 calls deterministic.
local function measure(name, iterations, fn)
    collectgarbage("collect")
    collectgarbage("collect")
    mocks.resetMeterCalls()
    columnCalls, unitCalls, refreshes = 0, 0, 0
    collectgarbage("stop")
    local kbBefore = collectgarbage("count")
    local t0 = os.clock()
    for i = 1, iterations do fn(i) end
    local elapsed = os.clock() - t0
    local kbAfter = collectgarbage("count")
    collectgarbage("restart")

    local meterCalls = 0
    for _, n in pairs(mocks.__meter.calls) do meterCalls = meterCalls + n end

    local r = {
        name          = name,
        iterations    = iterations,
        totalMs       = elapsed * 1000,
        msPerIter     = (elapsed * 1000) / iterations,
        apiCalls      = meterCalls,
        apiPerIter    = meterCalls / iterations,
        columnsPerIter = columnCalls / iterations,
        unitsPerIter  = unitCalls / iterations,
        refreshes     = refreshes,
        bytesPerIter  = ((kbAfter - kbBefore) * 1024) / iterations,
    }
    results[#results + 1] = r
    return r
end

local ITERS = 300

-- ── 1. the 20-player x 7-column refresh ─────────────────────────────────────
--
-- The addon's whole hot path in one call: seven session reads, a GUID join across
-- twenty sources per column, an ordering pass, and one hundred and forty cells
-- drawn.

local COLUMNS = #STAT_KEYS

-- One priming pass OUTSIDE the measurement. modules/Roster.lua rebuilds its map
-- lazily on the first read after an invalidation, so a cold cache would put one
-- twenty-one-unit walk inside the first iteration and make the steady-state
-- figure below a blend of two different passes.
inst.dirty = true
inst:Refresh()

local refresh = measure("refresh20x7", ITERS, function()
    inst.dirty = true
    inst:Refresh()
end)

assert_(refresh.columnsPerIter > 0,
    "the refresh made no Provider.GetColumn calls — the counting layer is not attached, "
    .. "or the window is drawing preview data")

-- THE REGRESSION GUARD. Exactly one read per enabled column per refresh. Two is
-- the bug that was just fixed (see the header); anything above one means a
-- consumer is re-entering the provider for a number the aggregate already holds.
assert_(refresh.columnsPerIter == COLUMNS,
    ("one refresh made %.2f Provider.GetColumn calls over %d enabled columns — it must be "
     .. "exactly %d, ONE read per column per refresh. More than one means something is "
     .. "re-reading the session for a figure modules/Aggregator.lua already published on "
     .. "the result table (columnTotals / cell.percent)")
        :format(refresh.columnsPerIter, COLUMNS, COLUMNS))

-- And the same statement one layer down, at the API itself: the provider must not
-- turn one GetColumn into several session reads.
assert_(mocks.__meter.calls.GetCombatSessionFromType == ITERS * COLUMNS,
    ("%d refreshes made %s C_DamageMeter.GetCombatSessionFromType calls, expected %d "
     .. "(one per column per refresh)")
        :format(ITERS, tostring(mocks.__meter.calls.GetCombatSessionFromType), ITERS * COLUMNS))

-- Availability is memoized and invalidated on the meter's own events, so a
-- refresh must not re-ask the client every pass.
assert_((mocks.__meter.calls.IsDamageMeterAvailable or 0) <= 1,
    ("%s IsDamageMeterAvailable calls over %d refreshes — the memo in "
     .. "modules/Provider.lua is not holding")
        :format(tostring(mocks.__meter.calls.IsDamageMeterAvailable), ITERS))

-- The roster is cached and rebuilt lazily. A steady-state refresh must not walk
-- the unit API at all.
assert_(refresh.unitsPerIter == 0,
    ("a steady-state refresh made %.2f UnitGUID calls — modules/Roster.lua's cache is "
     .. "being invalidated by something the refresh itself does")
        :format(refresh.unitsPerIter))

-- ── 1b. the same refresh, MID-PULL ──────────────────────────────────────────
--
-- The path that runs while the client is busiest, and until now the harness
-- never touched it. `sourceGUID` is SecretWhenInCombat, so under the restriction
-- modules/Aggregator.lua takes the IDENTITY build instead of the GUID join: the
-- sort column supplies the rows, every other column is read on its own and
-- correlated back by class and spec, and each source's fields arrive as secret
-- handles the mock materializes on every read.
--
-- The property being guarded is the one that matters on a raid pull: identity
-- mode must still cost exactly ONE read per column per refresh. Correlating a
-- column is a walk over a list already in hand, and any re-entry into the
-- provider to resolve a row would multiply the session reads by the number of
-- rows at the worst possible moment.

mocks.setRestricted(true)
NS.State.SetRestricted(true)

local restricted = measure("refresh20x7Restricted", ITERS, function()
    inst.dirty = true
    inst:Refresh()
end)

mocks.setRestricted(false)
NS.State.SetRestricted(false)
NS.State.WipeCache()

assert_(restricted.columnsPerIter == COLUMNS,
    ("a restricted refresh made %.2f Provider.GetColumn calls over %d enabled columns — "
     .. "identity mode must read each column exactly once, the same as the GUID join. More "
     .. "than one per column means a row is being resolved through the provider")
        :format(restricted.columnsPerIter, COLUMNS))

assert_(restricted.unitsPerIter == 0,
    ("a restricted refresh made %.2f UnitGUID calls — Roster.LocalGUID must answer from the "
     .. "cached map rather than re-walking the unit API mid-pull")
        :format(restricted.unitsPerIter))

-- A restricted pass costs about 29% more than the unrestricted one (421214
-- against 325955 for the same 20x7 window). The gap was measured rather than
-- assumed, by re-running this scenario with pieces removed:
--
--   * ~47KB is identity correlation itself — one key per source per non-sort
--     column (120 of them at this size), the lookup maps per column, and the
--     cells they produce. The GUID join pays for the cells too, so the genuine
--     extra is the keys and the maps.
--   * ~24KB more arrived with the RATE. A correlated cell has to carry
--     `amountPerSecond` as well as the total, because the shipped text layout
--     renders the rate for a rate stat — without it Healing drew a bar and no
--     number. Three fields rather than two rounds each cell's hash part up to
--     the next power of two, and there are 120 of them. Not reducible while the
--     rate is what the column displays.
--   * ~24KB is the HARNESS, not the addon. tests/wow_mock.lua simulates a secret
--     value as a TABLE with a trapping metatable, so every secret field in every
--     source becomes an allocation here that the client — where a secret is a
--     value — does not make. It appears only in this scenario, because it is the
--     only one that runs restricted.
--
-- The ceiling carries the same ~3.5% headroom as the dormant one above. What it
-- catches is identity correlation GROWING; the gap to `refresh20x7` is expected
-- and is not itself a failure.
local RESTRICTED_BYTES_CEILING = 436000   -- measured 421214 for a 20x7 pass
assert_(restricted.bytesPerIter <= RESTRICTED_BYTES_CEILING,
    ("a restricted pass allocated %.0f bytes/iter, over the %d-byte ceiling — identity "
     .. "correlation grew"):format(restricted.bytesPerIter, RESTRICTED_BYTES_CEILING))

-- ── 2. throttle sensitivity ─────────────────────────────────────────────────
--
-- The single most important performance property in the addon: N meter events
-- inside one throttle window must produce exactly ONE refresh. Every message
-- handler in modules/Window.lua does nothing but set `dirty`, and the OnUpdate
-- tick is the only clock.

local BURST = 200
local MSG = NS.Constants.MSG
local onUpdate = inst.frame:GetScript("OnUpdate")
assert(onUpdate, "the window has no OnUpdate — the coalescing clock is not installed")

local throttle = measure("throttleBurst", 1, function()
    inst.elapsed = 0
    inst.dirty = false

    -- The burst. Every one of these is a full bus dispatch through
    -- core/MultiMeters.lua's fan-out, exactly as a busy pull produces it.
    for _ = 1, BURST do
        NS:SendMessage(MSG.METER_UPDATED)
    end

    -- Ticks that do NOT spend the throttle. A hundred frames at 60fps is well
    -- under 0.25s and must draw nothing.
    for _ = 1, 100 do
        onUpdate(inst.frame, 0.001)
    end
    assert_(refreshes == 0,
        ("%d refresh(es) happened before the throttle interval elapsed — the coalescer is "
         .. "not coalescing"):format(refreshes))

    -- One tick that spends it.
    onUpdate(inst.frame, inst.throttle)
end)

assert_(throttle.refreshes == 1,
    ("%d meter events plus %d sub-interval ticks produced %d refreshes; it must be exactly 1")
        :format(BURST, 100, throttle.refreshes))
assert_(throttle.columnsPerIter == COLUMNS,
    ("the coalesced pass read %.2f columns, expected %d — a burst must cost one pass, not one "
     .. "pass per event"):format(throttle.columnsPerIter, COLUMNS))

-- A second tick with nothing dirty must do no work at all. This is the other half
-- of the property: the clock runs whether or not there is anything to draw.
local idle = measure("throttleIdle", ITERS, function()
    onUpdate(inst.frame, inst.throttle)
end)
assert_(idle.refreshes == 0,
    ("%d idle ticks produced %d refreshes — the dirty flag is not gating the pass")
        :format(ITERS, idle.refreshes))
assert_(idle.columnsPerIter == 0,
    ("an idle tick read %.2f columns — it must read none"):format(idle.columnsPerIter))

-- ── 3. drill-down open / close ──────────────────────────────────────────────
--
-- Entering a breakdown replaces the grid entirely: the window stops asking the
-- aggregator for rows and asks modules/DrillDown.lua for a spell list instead. The
-- interesting figure is that a drilled window makes FEWER column reads, not more.

local DrillDown = NS:GetModule("DrillDown")
local entries = NS.Aggregator.Build(window)
assert(entries[1], "the aggregator produced no rows — the fixture does not join")
local topRow = entries[1]

local drill = measure("drillOpenClose", ITERS, function()
    DrillDown:Enter(window, topRow, "DamageDone")
    local rows = DrillDown:BuildRows(window)
    assert_(rows ~= nil, "BuildRows answered nil while a view was open")
    DrillDown:Exit(window)
end)

assert_(DrillDown.IsActive(window) == false,
    "the drill-down is still active after Exit")
assert_(drill.columnsPerIter == 0,
    ("open/close made %.2f Provider.GetColumn calls — a breakdown reads GetSourceDetail, "
     .. "never a whole column"):format(drill.columnsPerIter))

-- And the window's own pass while drilled in: one GetSourceDetail, no columns.
DrillDown:Enter(window, topRow, "DamageDone")
local drilledRefresh = measure("refreshWhileDrilled", ITERS, function()
    inst.dirty = true
    inst:Refresh()
end)
assert_(drilledRefresh.columnsPerIter == 0,
    ("a drilled window read %.2f columns per refresh — it must read none; the grid is not "
     .. "being drawn"):format(drilledRefresh.columnsPerIter))
DrillDown:Exit(window)

-- ── 4. full rebuild on roster change ────────────────────────────────────────
--
-- A raid regroup fires GROUP_ROSTER_UPDATE a dozen times a second.
-- modules/Roster.lua drops its cache on the message and rebuilds LAZILY, on the
-- next read, so a burst of roster events collapses to ONE unit-API walk at the
-- next refresh rather than one walk per event.

local rebuild = measure("rosterRebuild", ITERS, function()
    NS:SendMessage(MSG.ROSTER_CHANGED)
    inst.dirty = true
    inst:Refresh()
end)

assert_(rebuild.unitsPerIter > 0,
    "a roster change produced no unit-API walk — the cache was never invalidated")

do
    -- The lazy-rebuild property, stated as a number: ten roster messages followed
    -- by ONE refresh must cost exactly ONE walk, not ten.
    local burst = measure("rosterBurst", 1, function()
        for _ = 1, 10 do NS:SendMessage(MSG.ROSTER_CHANGED) end
        inst.dirty = true
        inst:Refresh()
    end)
    assert_(burst.unitsPerIter == rebuild.unitsPerIter,
        ("ten roster messages plus one refresh cost %.0f unit reads against a single "
         .. "message's %.0f — modules/Roster.lua is rebuilding eagerly in the handler")
            :format(burst.unitsPerIter, rebuild.unitsPerIter))
end

do
    -- And the converse: with no invalidation, repeated refreshes cost nothing.
    local cached = measure("rosterCached", ITERS, function()
        inst.dirty = true
        inst:Refresh()
    end)
    assert_(cached.unitsPerIter == 0,
        ("a refresh with an unchanged roster cost %.2f unit reads — the cache is not being "
         .. "held"):format(cached.unitsPerIter))
end

-- Full window rebuild: a settings change re-applies config and re-lays every row.
measure("applyConfig", ITERS, function()
    inst:ApplyConfig()
end)

-- ── 5. THE ZERO-OVERHEAD SCENARIO (performance-§9 MUST) ─────────────────────
--
-- The instrumentation must be free when capture is off, or the measurement tool
-- is itself the regression. Same path, brackets dormant versus armed — evidence,
-- not a comment.

local probeOff = measure("probeOverheadOff", ITERS, function()
    inst.dirty = true
    inst:Refresh()
end)

NS.Perf.on = true
local probeOn = measure("probeOverheadOn", ITERS, function()
    inst.dirty = true
    inst:Refresh()
end)
NS.Perf.on = false

-- The RELATION alone cannot go red the way it matters: if a regression adds
-- allocation to Refresh itself, BOTH arms rise together and `off <= on + 1` still
-- holds. The dormant arm therefore also carries an ABSOLUTE CEILING, set just
-- above the measured figure. Raise it only with a recorded reason — a rise IS the
-- finding.
--
-- READ THE ABSOLUTE FIGURE WITH ONE CAVEAT: most of it is the HARNESS, not the
-- addon. tests/wow_mock.lua materializes a fresh session table on every
-- C_DamageMeter read (that is what lets the same fixture arrive plain or secret),
-- so seven columns times twenty sources is a deep copy per pass that the client
-- does not make. The ceiling still does its job — it catches a rise in what one
-- refresh allocates — and the ratio between the two arms below is unaffected,
-- because both arms pay the identical harness cost.
-- RE-RECORDED 2026-08-11, and the reason is that the previous figure could not
-- have been measured for some time. The fixture above seeded the `Current`
-- session while the shipped window reads `Overall`, so every pass here joined
-- NOTHING: the ceiling was being compared against an empty refresh, which is why
-- a 309297-byte record sat under a path that now measures 325890.
--
-- The growth itself is NOT this changeset's — the same fixture repair against the
-- committed tree measures 326594, marginally higher than the figure recorded
-- here. Where the ~5% came from cannot be established: the harness was blind to
-- it for the whole period, and this repo has a single commit, so there is nothing
-- to bisect. Recorded as unexplained rather than attributed to a guess.
--
-- The figure is deterministic to the byte across runs, so the headroom is the
-- same ~3.5% the previous ceiling carried, and a real regression still shows.
local PROBE_OFF_BYTES_CEILING = 336000   -- measured 325955 for a 20x7 pass

assert_(probeOff.bytesPerIter <= PROBE_OFF_BYTES_CEILING,
    ("a dormant pass allocated %.0f bytes/iter, over the %d-byte ceiling — one refresh of "
     .. "this window grew"):format(probeOff.bytesPerIter, PROBE_OFF_BYTES_CEILING))
assert_(probeOff.bytesPerIter <= probeOn.bytesPerIter + 1,
    ("a dormant bracket allocated %.1f bytes/iter against the armed arm's %.1f — the gating "
     .. "idiom is wrong (performance-§2 wants one upvalue read, one field read, one boolean "
     .. "test)"):format(probeOff.bytesPerIter, probeOn.bytesPerIter))
assert_(probeOff.apiPerIter == probeOn.apiPerIter,
    ("the probe changed how many meter API calls a pass makes: %.1f dormant against %.1f armed")
        :format(probeOff.apiPerIter, probeOn.apiPerIter))
assert_(probeOff.columnsPerIter == probeOn.columnsPerIter,
    ("the probe changed how many columns a pass reads: %.2f dormant against %.2f armed")
        :format(probeOff.columnsPerIter, probeOn.columnsPerIter))
assert_(math.abs(refresh.bytesPerIter - probeOff.bytesPerIter) < 2048,
    ("the dormant arm (%.0f bytes/iter) did not reproduce the plain refresh figure (%.0f) — "
     .. "the two are the same path"):format(probeOff.bytesPerIter, refresh.bytesPerIter))

-- The gate must also be free where nothing runs at all: a suspended capture stops
-- the addon ASKING for data, not merely stop drawing it (performance-§6).
NS.Perf.suspended = true
NS.Provider:Suspend()
local suspended = measure("suspended", ITERS, function()
    inst.dirty = true
    inst:Refresh()
end)
NS.Provider:Resume()
NS.Perf.suspended = false
assert_(suspended.apiPerIter == 0,
    ("a suspended capture still made %.2f meter API calls per pass — suspend must stop the "
     .. "reads at the source"):format(suspended.apiPerIter))

-- ── report ──────────────────────────────────────────────────────────────────

print(("Ka0s Multi Meters \226\128\148 offline perf  (v%s, label '%s')")
    :format(tostring(NS.version), opts.label))
print(("%d group members, %d columns, throttle %.2fs, %d events per burst")
    :format(MEMBERS, COLUMNS, inst.throttle, BURST))
print()
-- FIVE columns, and that is a contract rather than a layout choice. The vendored
-- runner counts scenario rows structurally -- `NF==5` with a numeric second field
-- (tests/_kit/run-automated-tests.sh) -- so a sixth column makes every row
-- uncountable and the run reports "0 scenarios" while the table below plainly
-- holds twelve. A suite that reports having measured nothing is worse than a red
-- one, because it is believed. `columnsPerIter` is not lost: it rides in perf.json
-- and, more importantly, it is asserted directly above -- the printed table is for
-- a human skimming a diff, the assertions are what actually guard the behavior.
print(("%-22s %8s %11s %10s %12s")
    :format("scenario", "iters", "ms/iter", "api/iter", "bytes/iter"))
for _, r in ipairs(results) do
    print(("%-22s %8d %11.5f %10.2f %12.1f")
        :format(r.name, r.iterations, r.msPerIter, r.apiPerIter, r.bytesPerIter))
end
print()
print("timings are for orientation only \226\128\148 compare scenarios within a run, "
    .. "never across machines")

if #failures > 0 then
    print()
    print(("%d assertion%s FAILED:"):format(#failures, #failures == 1 and "" or "s"))
    for _, f in ipairs(failures) do print("  - " .. f) end
end

-- ── record ──────────────────────────────────────────────────────────────────

if opts.out then
    local buckets = {}
    for _, r in ipairs(results) do
        -- Map the scenario onto the shared bucket shape: `calls` is the iteration
        -- count and `totalMs` / `maxMs` carry the same meaning as in-game, so one
        -- reader handles both sources. No `within`, deliberately: each scenario is
        -- driven directly and times only its own loop, so no scenario's total is
        -- contained in another's — which is precisely what a missing `within`
        -- means in the record schema. The in-game buckets DO nest; these do not,
        -- and claiming otherwise would be the exact false containment
        -- performance-§3 forbids.
        buckets[r.name] = {
            calls          = r.iterations,
            totalMs        = r.totalMs,
            maxMs          = r.msPerIter,
            apiPerIter     = r.apiPerIter,
            columnsPerIter = r.columnsPerIter,
            bytesPerIter   = r.bytesPerIter,
        }
    end

    local record = {
        schema    = NS.Perf.SCHEMA,
        addon     = "MultiMeters",
        source    = "offline",
        version   = NS.version,
        interface = 0,          -- no client involved
        timestamp = os.time(),
        label     = opts.label,
        buckets   = buckets,
        fps       = {           -- fixed shape; an offline run has no frames to sample
            active    = { seconds = 0, frames = 0, avgFps = 0, msPerFrame = 0 },
            suspended = { seconds = 0, frames = 0, avgFps = 0, msPerFrame = 0 },
            deltaMsPerFrame = 0,
        },
        members   = MEMBERS,
        columns   = COLUMNS,
        failures  = failures,
    }

    local fh, err = io.open(opts.out, "w")
    if not fh then
        io.stderr:write("cannot write " .. opts.out .. ": " .. tostring(err) .. "\n")
        os.exit(2)
    end
    fh:write(NS.Perf.EncodeJSON(record), "\n")
    fh:close()
    print("wrote " .. opts.out)
end

os.exit(#failures == 0 and 0 or 1)
