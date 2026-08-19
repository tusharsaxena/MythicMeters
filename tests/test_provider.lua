-- tests/test_provider.lua — modules/Provider.lua: the only reader of the meter.
--
-- Two claims are load-bearing and both are tested here rather than asserted in a
-- comment:
--
--   R1a  this is the ONLY file that reaches C_DamageMeter. Proved by scanning
--        the repo's own source, because a second caller would not fail any
--        behavioral test — it would just quietly exist.
--   R1b  nothing here inspects a value. Proved by running every read with the
--        simulated secret in place: the mock traps arithmetic, comparison,
--        concatenation and indexing, so an inspection is a raise rather than a
--        subtly wrong answer.

local T = _G.MYTHICMETERS_TEST

local test        = T.test
local assertEqual = T.assertEqual
local assertTrue  = T.assertTrue
local assertFalse = T.assertFalse
local assertNil   = T.assertNil

local CURRENT = 1   -- Enum.DamageMeterSessionType.Current, as the mock reports it

--- A loaded instance with one session installed for every stat, plus the
--- restriction flipped on when asked for.
local function withSession(opts)
    opts = opts or {}
    local inst = T.load()
    local session = inst.mocks.buildSession(opts.session or { count = 4 })
    inst.mocks.setSession(CURRENT, "*", session)
    if opts.restricted then inst.mocks.setRestricted(true) end
    inst.mocks.resetMeterCalls()
    return inst, session
end

-- ---------------------------------------------------------------------------
-- R1a — one caller, proved from the source
-- ---------------------------------------------------------------------------

--- The CODE of one repo file, as { n, text }, with every comment removed —
--- whole-line and trailing alike.
---
--- Stripping is not tidiness. Half the headers in this addon discuss
--- C_DamageMeter by name, and core/PerfSetup.lua names it in a trailing comment
--- on a live line; a grep that cannot tell prose from code either passes
--- vacuously or fails on documentation, and neither outcome is a test.
local function codeLines(relPath)
    local fh = assert(io.open(T.root .. "/" .. relPath, "r"))
    local out, n = {}, 0
    for line in fh:lines() do
        n = n + 1
        if not line:match("^%s*%-%-") then
            out[#out + 1] = { n = n, text = (line:gsub("%s%-%-.*$", "")) }
        end
    end
    fh:close()
    return out
end

test("Provider: core/Compat.lua is the only file that names C_DamageMeter", function()
    local offenders = {}
    for _, rel in ipairs(T.loadedAddonFiles) do
        local path = rel:gsub("\\", "/")
        if path ~= "core/Compat.lua" then
            for _, line in ipairs(codeLines(path)) do
                if line.text:find("C_DamageMeter", 1, true) then
                    offenders[#offenders + 1] = path .. ":" .. line.n
                end
            end
        end
    end
    assertEqual(#offenders, 0,
        "C_DamageMeter is named outside core/Compat.lua: " .. table.concat(offenders, ", "))
end)

test("Provider: modules/Provider.lua is the only caller of the meter shims", function()
    local SHIMS = {
        "Compat%.IsDamageMeterAvailable",
        "Compat%.GetCombatSession",
        "Compat%.GetAvailableCombatSessions",
        "Compat%.GetSessionDurationSeconds",
        "Compat%.ResetAllCombatSessions",
    }
    local offenders = {}
    for _, rel in ipairs(T.loadedAddonFiles) do
        local path = rel:gsub("\\", "/")
        if path ~= "core/Compat.lua" and path ~= "modules/Provider.lua" then
            for _, line in ipairs(codeLines(path)) do
                for _, pattern in ipairs(SHIMS) do
                    if line.text:find(pattern) then
                        offenders[#offenders + 1] = path .. ":" .. line.n
                    end
                end
            end
        end
    end
    assertEqual(#offenders, 0,
        "a meter shim is called outside modules/Provider.lua: " .. table.concat(offenders, ", "))
end)

test("Provider: the source walk uses SafeIterate, never ipairs and never `#`", function()
    -- The two forbidden spellings, in the one function that walks a possibly
    -- secret array. `#` on a secret table raises in the client; ipairs is safe
    -- on an array but is the habit that reintroduces `#` next to it.
    local walkers, offenders = 0, {}
    for _, line in ipairs(codeLines("modules/Provider.lua")) do
        if line.text:find("SafeIterate", 1, true) then walkers = walkers + 1 end
        if line.text:find("combatSources", 1, true) then
            if line.text:find("ipairs", 1, true) or line.text:find("#", 1, true) then
                offenders[#offenders + 1] = "modules/Provider.lua:" .. line.n
            end
        end
    end
    assertTrue(walkers > 0, "modules/Provider.lua must walk through NS.Secrets.SafeIterate")
    assertEqual(#offenders, 0, "combatSources is measured or ipaired: "
        .. table.concat(offenders, ", "))
end)

-- ---------------------------------------------------------------------------
-- Availability
-- ---------------------------------------------------------------------------

test("Provider.IsAvailable memoizes and InvalidateAvailability drops the memo", function()
    local inst = withSession()
    local NS, mocks = inst.NS, inst.mocks

    assertEqual(NS.Provider.IsAvailable(), true)
    NS.Provider.IsAvailable()
    NS.Provider.IsAvailable()
    assertEqual(mocks.__meter.calls.IsDamageMeterAvailable, 1,
        "the answer is asked once per column per refresh; it must be memoized")

    NS.Provider.InvalidateAvailability()
    NS.Provider.IsAvailable()
    assertEqual(mocks.__meter.calls.IsDamageMeterAvailable, 2)
end)

test("Provider surfaces Blizzard's failureReason verbatim", function()
    local inst = withSession()
    local NS, mocks = inst.NS, inst.mocks

    mocks.setMeterAvailable(false, "DAMAGE_METER_DISABLED_BY_CVAR")
    NS.Provider.InvalidateAvailability()

    local ok, reason = NS.Provider.IsAvailable()
    assertEqual(ok, false)
    assertEqual(reason, "DAMAGE_METER_DISABLED_BY_CVAR",
        "the reason is passed through untranslated and uninterpreted")

    local column = NS.Provider.GetColumn(CURRENT, "DamageDone")
    assertEqual(column.reason, "unavailable")
    assertEqual(column.failureReason, "DAMAGE_METER_DISABLED_BY_CVAR")
    assertEqual(#column.sources, 0)
end)

test("Provider.GetColumn names an unknown stat rather than skipping it", function()
    local column = T.NS.Provider.GetColumn(CURRENT, "SomeStatFromALaterBuild")
    assertEqual(column.reason, "unknown stat")
    assertEqual(column.stat, "SomeStatFromALaterBuild")
end)

test("Provider.GetColumn tells 'no session' apart from 'session sealed'", function()
    local inst = T.load()
    local NS, mocks = inst.NS, inst.mocks

    -- Nothing installed for this session type at all.
    assertEqual(NS.Provider.GetColumn(CURRENT, "DamageDone").reason, "no session")

    -- A session table this execution context may not access. "We may not look"
    -- and "there is nothing there" are different facts and the window says
    -- different things about them.
    local sealed = mocks.secretTable{ combatSources = {} }
    mocks.C_DamageMeter.GetCombatSessionFromType = function() return sealed end
    mocks.setSecretsAccessible(false)

    local column = NS.Provider.GetColumn(CURRENT, "DamageDone")
    assertEqual(column.reason, "session sealed",
        "an inaccessible session must be refused, not indexed")
    assertEqual(#column.sources, 0)
end)

-- ---------------------------------------------------------------------------
-- Reads under the restriction
-- ---------------------------------------------------------------------------

test("Provider.GetColumn copies secret fields through without inspecting one", function()
    local inst = withSession{ restricted = true, session = { count = 3, top = 4200000 } }
    local NS, mocks = inst.NS, inst.mocks

    local column = NS.Provider.GetColumn(CURRENT, "DamageDone")
    assertEqual(column.reason, nil, "a readable session yields no reason")
    assertEqual(#column.sources, 3)

    -- Every amount arrived opaque and left opaque: the provider is a courier.
    assertTrue(mocks.isSimulatedSecret(column.maxAmount), "maxAmount stays secret")
    assertTrue(mocks.isSimulatedSecret(column.totalAmount), "totalAmount stays secret")
    assertTrue(mocks.isSimulatedSecret(column.durationSeconds), "durationSeconds stays secret")

    local first = column.sources[1]
    assertTrue(mocks.isSimulatedSecret(first.totalAmount))
    assertTrue(mocks.isSimulatedSecret(first.amountPerSecond))
    assertTrue(mocks.isSimulatedSecret(first.name), "`name` is ConditionalSecret")
    assertEqual(mocks.reveal(first.totalAmount), 4200000, "and the handle is the right one")

    -- The GUID goes through opaque like everything else. It was believed to be
    -- the one field a join could key on; it is annotated SecretWhenInCombat, so
    -- mid-pull it is another handle this file carries without examining.
    assertTrue(mocks.isSimulatedSecret(first.guid),
        "sourceGUID is SecretWhenInCombat — the premise the whole join rested on")
    assertEqual(first.classFilename, "WARRIOR",
        "classFilename is NeverSecret, and is what identity correlation is built from")
end)

test("Provider.GetColumn skips a source row it may not access, without raising", function()
    local inst = T.load()
    local NS, mocks = inst.NS, inst.mocks
    mocks.setRestricted(true)

    -- The ARRAY is walkable but one ENTRY is not. Guarding per row is what
    -- removes the last way this loop could raise.
    local sealedRow = mocks.secretTable{ sourceGUID = "Player-1-000000FF" }
    mocks.C_DamageMeter.GetCombatSessionFromType = function()
        return {
            combatSources = {
                sealedRow,
                { sourceGUID = "Player-1-00000001", name = mocks.secret("Mock1"),
                  totalAmount = mocks.secret(100), classFilename = "MAGE" },
            },
            maxAmount = mocks.secret(100),
        }
    end
    mocks.setSecretsAccessible(false)

    local column = NS.Provider.GetColumn(CURRENT, "DamageDone")
    assertEqual(#column.sources, 1, "the inaccessible row is skipped, the rest is kept")
    assertEqual(column.sources[1].guid, "Player-1-00000001")
end)

test("Provider.GetColumn drops a source with no GUID rather than keying on nil", function()
    local inst = T.load()
    local NS, mocks = inst.NS, inst.mocks
    mocks.C_DamageMeter.GetCombatSessionFromType = function()
        return { combatSources = {
            { name = "no guid at all", totalAmount = 1 },
            { sourceGUID = "Player-1-00000002", totalAmount = 2 },
        } }
    end
    local column = NS.Provider.GetColumn(CURRENT, "DamageDone")
    assertEqual(#column.sources, 1)
    assertEqual(column.sources[1].guid, "Player-1-00000002")
end)

test("Provider.GetColumn preserves the API's order verbatim", function()
    local inst = withSession{ session = { count = 4 } }
    local column = inst.NS.Provider.GetColumn(CURRENT, "DamageDone")
    for i = 1, 4 do
        assertEqual(column.sources[i].guid, string.format("Player-1-%08X", i),
            "`provider` sort mode depends on this order being untouched")
    end
end)

-- ---------------------------------------------------------------------------
-- Dps and Hps are never queried
-- ---------------------------------------------------------------------------

test("Provider never asks for Enum.DamageMeterType.Dps or .Hps", function()
    local inst = withSession()
    local NS, mocks = inst.NS, inst.mocks

    -- Record the stat enum the provider actually hands the API, for every stat
    -- in the catalog. `amountPerSecond` rides on the DamageDone row, so a Dps
    -- read would be a second session read for a number we already have.
    local asked = {}
    local real = mocks.C_DamageMeter.GetCombatSessionFromType
    mocks.C_DamageMeter.GetCombatSessionFromType = function(sessionType, statType)
        asked[#asked + 1] = statType
        return real(sessionType, statType)
    end

    for _, stat in ipairs(NS.Constants.STATS) do
        NS.Provider.GetColumn(CURRENT, stat.key)
    end

    assertEqual(#asked, #NS.Constants.STATS, "one read per stat, no more")
    local DPS = mocks.Enum.DamageMeterType.Dps
    local HPS = mocks.Enum.DamageMeterType.Hps
    for _, value in ipairs(asked) do
        assertFalse(value == DPS, "Enum.DamageMeterType.Dps was queried")
        assertFalse(value == HPS, "Enum.DamageMeterType.Hps was queried")
    end

    -- And the catalog itself refuses to name them, so no future column can.
    assertNil(NS.Constants.STAT_TYPE.Dps)
    assertNil(NS.Constants.STAT_TYPE.Hps)
end)

test("Provider: one DamageDone read fills both halves of the Damage column", function()
    local inst = withSession{ restricted = true, session = { count = 2, top = 3000000 } }
    local NS, mocks = inst.NS, inst.mocks

    local column = NS.Provider.GetColumn(CURRENT, "DamageDone")
    assertEqual(mocks.__meter.calls.GetCombatSessionFromType, 1, "exactly one session read")

    local first = column.sources[1]
    assertTrue(first.totalAmount ~= nil, "the total")
    assertTrue(first.amountPerSecond ~= nil, "and the rate, off the same row")
    assertEqual(mocks.reveal(first.amountPerSecond), math.floor(3000000 / 300))
end)

-- ---------------------------------------------------------------------------
-- Source detail
-- ---------------------------------------------------------------------------

test("Provider.GetSourceDetail returns Blizzard's table, guarded but unflattened", function()
    local inst = T.load()
    local NS, mocks = inst.NS, inst.mocks
    mocks.setSourceDetail(CURRENT, "*", "*", mocks.buildSourceDetail{ count = 3 })
    mocks.setRestricted(true)

    local source = NS.Provider:GetSourceDetail(CURRENT, "DamageDone", "Player-1-00000001")
    assertEqual(type(source), "table")
    assertEqual(type(source.combatSpells), "table", "the spell array is handed over whole")
    assertEqual(#source.combatSpells, 3)
    assertTrue(mocks.isSimulatedSecret(source.combatSpells[1].totalAmount))
end)

test("Provider.GetSourceDetail refuses rather than handing back a sealed table", function()
    local inst = T.load()
    local NS, mocks = inst.NS, inst.mocks
    mocks.C_DamageMeter.GetCombatSessionSourceFromType = function()
        return mocks.secretTable{ combatSpells = {} }
    end
    mocks.setSecretsAccessible(false)

    -- Refusing here is the whole job: handing it back would move the raise into
    -- the tooltip, which has no way to recover.
    assertNil(NS.Provider:GetSourceDetail(CURRENT, "DamageDone", "Player-1-00000001"))
end)

test("Provider.GetSourceDetail answers nil for an unknown stat or a missing source", function()
    local inst = T.load()
    assertNil(inst.NS.Provider.GetSourceDetail(CURRENT, "NotAStat", "Player-1-00000001"))
    assertNil(inst.NS.Provider.GetSourceDetail(CURRENT, "DamageDone", "Player-1-00000001"))
end)

-- ---------------------------------------------------------------------------
-- Both call shapes
-- ---------------------------------------------------------------------------

test("Provider accepts both the dot and the colon call shape", function()
    local inst = withSession{ session = { count = 2 } }
    local NS = inst.NS

    -- A silent argument shift here would read the WRONG SESSION, in combat,
    -- where nobody can see it.
    local dot   = NS.Provider.GetColumn(CURRENT, "DamageDone")
    local colon = NS.Provider:GetColumn(CURRENT, "DamageDone")
    assertEqual(dot.stat, "DamageDone")
    assertEqual(colon.stat, "DamageDone")
    assertEqual(#dot.sources, #colon.sources)
    assertEqual(#colon.sources, 2)
end)

-- ---------------------------------------------------------------------------
-- Sessions, duration and reset
-- ---------------------------------------------------------------------------

test("Provider.GetAvailableSessions passes the client's list through untouched", function()
    local inst = T.load()
    local list = { { sessionID = 4, name = "Trash", durationSeconds = 30 } }
    inst.mocks.setAvailableSessions(list)
    assertTrue(inst.NS.Provider.GetAvailableSessions() == list)
end)

test("Provider.GetSessionDuration hands back the opaque handle", function()
    local inst = T.load()
    inst.mocks.setSessionDuration(CURRENT, 212)
    inst.mocks.setRestricted(true)

    local seconds = inst.NS.Provider.GetSessionDuration(CURRENT)
    assertTrue(inst.mocks.isSimulatedSecret(seconds), "durations are secret in combat")
    assertEqual(inst.mocks.reveal(seconds), 212)
end)

test("Provider.Reset wipes the sessions, forgets availability and announces", function()
    local inst = withSession()
    local NS, mocks = inst.NS, inst.mocks

    local heard = 0
    local bus = NS.NewBusTarget()
    bus:RegisterMessage(NS.Constants.MSG.METER_RESET, function() heard = heard + 1 end)

    NS.Provider.IsAvailable()
    assertEqual(mocks.__meter.calls.IsDamageMeterAvailable, 1)

    assertEqual(NS.Provider.Reset(), true)
    assertEqual(mocks.__meter.resets, 1)
    assertEqual(heard, 1, "METER_RESET is announced so the frozen orders are dropped")

    NS.Provider.IsAvailable()
    assertEqual(mocks.__meter.calls.IsDamageMeterAvailable, 2,
        "a reset is one of the three ways the availability answer can change")
end)

test("Provider.Reset answers false where the API is absent", function()
    local inst = T.load{ mutate = function(mocks) mocks.C_DamageMeter = nil end }
    assertEqual(inst.NS.Provider.Reset(), false)
end)

-- ---------------------------------------------------------------------------
-- Suspend (performance-§6)
-- ---------------------------------------------------------------------------

test("Provider:Suspend stops the addon ASKING, not merely drawing", function()
    local inst = withSession{ session = { count = 4 } }
    local NS, mocks = inst.NS, inst.mocks

    NS.Provider:Suspend()
    assertEqual(NS.Provider.IsSuspended(), true)
    mocks.resetMeterCalls()

    local column = NS.Provider.GetColumn(CURRENT, "DamageDone")
    assertEqual(column.reason, "suspended")
    assertEqual(#column.sources, 0)
    assertNil(NS.Provider.GetSourceDetail(CURRENT, "DamageDone", "Player-1-00000001"))
    assertEqual(#NS.Provider.GetAvailableSessions(), 0)
    assertNil(NS.Provider.GetSessionDuration(CURRENT))

    -- Nothing reached the API at all: a suspended capture must be inert.
    for name, count in pairs(mocks.__meter.calls) do
        assertEqual(count, 0, "a suspended provider called " .. name)
    end

    NS.Provider:Resume()
    assertEqual(NS.Provider.IsSuspended(), false)
    assertEqual(#NS.Provider.GetColumn(CURRENT, "DamageDone").sources, 4)
end)

test("Provider:Suspend drops its bus subscriptions and Resume republishes them", function()
    local inst = withSession()
    local NS = inst.NS

    NS.Provider:OnEnable()
    NS.Provider:Suspend()
    -- A busy pull behind a suspended capture must do no work at all: the
    -- invalidation messages have nowhere to land.
    local registry = inst.mocks.__busRegistry
    local targets = registry[NS.Constants.MSG.METER_RESET] or {}
    assertNil(targets[NS.Provider], "the subscription must come down")

    NS.Provider:Resume()
    assertTrue((registry[NS.Constants.MSG.METER_RESET] or {})[NS.Provider] ~= nil,
        "and go back up on resume")
end)

-- ---------------------------------------------------------------------------
-- Addressing a session by ID — the segment selector's read path
-- ---------------------------------------------------------------------------

test("Provider: with no sessionID the read goes to the TYPE shim, as it always did", function()
    -- The parameter is optional and nil is the old behavior verbatim. This is the
    -- regression guard for every existing caller.
    local inst = withSession()
    inst.NS.Provider.GetColumn(CURRENT, "DamageDone")

    local calls = inst.mocks.__meter.calls
    assertEqual(calls.GetCombatSessionFromType, 1)
    assertNil(calls.GetCombatSessionFromID, "an absent id must not reach the ID shim")
end)

test("Provider: a sessionID routes to the ID shim instead", function()
    -- red under: ignoring the new argument, which would silently keep reading the
    -- live pull while the header claimed to be showing a stored segment.
    local inst = T.load()
    inst.mocks.setSession(77, "*", inst.mocks.buildSession{ count = 3 })
    inst.mocks.resetMeterCalls()

    local column = inst.NS.Provider.GetColumn(CURRENT, "DamageDone", 77)

    local calls = inst.mocks.__meter.calls
    assertEqual(calls.GetCombatSessionFromID, 1)
    assertNil(calls.GetCombatSessionFromType, "the type shim must not also be called")
    assertEqual(#column.sources, 3)
end)

test("Provider: the colon call shape carries the sessionID too", function()
    -- Every entry point accepts both shapes; a new trailing argument is exactly
    -- where that shim silently shifts by one if it was not widened with it.
    local inst = T.load()
    inst.mocks.setSession(77, "*", inst.mocks.buildSession{ count = 2 })
    inst.mocks.resetMeterCalls()

    local column = inst.NS.Provider:GetColumn(CURRENT, "DamageDone", 77)
    assertEqual(#column.sources, 2)
    assertEqual(inst.mocks.__meter.calls.GetCombatSessionFromID, 1)
end)

test("Provider: GetSourceDetail with a sessionID reaches the ID breakdown", function()
    local inst = T.load()
    inst.mocks.setSourceDetail(77, "*", "*", { combatSpells = { { spellID = 1 } } })
    inst.mocks.resetMeterCalls()

    local source = inst.NS.Provider:GetSourceDetail(
        CURRENT, "DamageDone", "Player-1-00000001", nil, 77)
    assertTrue(source ~= nil)
    assertEqual(inst.mocks.__meter.calls.GetCombatSessionSourceFromID, 1)
end)

test("Provider: a segment's duration comes off the session LIST, not the type shim", function()
    -- There is no "duration of session N" call in the API — GetSessionDurationSeconds
    -- is type-addressed only — so a stored segment's duration is read off its own
    -- entry in GetAvailableCombatSessions.
    local inst = T.load()
    inst.mocks.setAvailableSessions{
        { sessionID = 4, name = "Bribed Guard", durationSeconds = 22 },
        { sessionID = 5, name = "Bribed Guard", durationSeconds = 17 },
    }
    inst.mocks.setSessionDuration(CURRENT, 999)
    inst.mocks.resetMeterCalls()

    assertEqual(inst.NS.Provider.GetSessionDuration(CURRENT, 5), 17)
    assertNil(inst.mocks.__meter.calls.GetSessionDurationSeconds,
        "the type shim cannot answer for a stored segment and must not be asked")
    assertEqual(inst.NS.Provider.GetSessionDuration(CURRENT), 999,
        "and with no id it still goes to the type shim")
end)

test("Provider: an unknown sessionID has no duration rather than a wrong one", function()
    local inst = T.load()
    inst.mocks.setAvailableSessions{ { sessionID = 4, durationSeconds = 22 } }
    assertNil(inst.NS.Provider.GetSessionDuration(CURRENT, 99))
end)

test("Provider.HasSession is the staleness check behind a persisted segment", function()
    -- A window that saved "segment 4" and came back after a reset must not sit
    -- there drawing an empty grid for a session the client no longer holds.
    local inst = T.load()
    inst.mocks.setAvailableSessions{
        { sessionID = 4, name = "Bribed Guard", durationSeconds = 22 },
    }
    local P = inst.NS.Provider

    assertTrue(P.HasSession(4))
    assertFalse(P.HasSession(99), "a segment the client dropped")
    assertFalse(P.HasSession(nil), "nil is `no segment chosen`, not a match")
    assertTrue(P:HasSession(4), "and the colon shape agrees")
end)

test("Provider: a suspended capture answers no segment questions", function()
    local inst = T.load()
    inst.mocks.setAvailableSessions{ { sessionID = 4, durationSeconds = 22 } }
    inst.NS.Provider:Suspend()

    assertFalse(inst.NS.Provider.HasSession(4))
    assertNil(inst.NS.Provider.GetSessionDuration(CURRENT, 4))
end)

test("Provider: reading a segment never inspects a value", function()
    -- R1b, on the new path. The simulator traps arithmetic, comparison,
    -- concatenation and indexing, so an inspection raises rather than answering
    -- subtly wrong.
    local inst = T.load()
    inst.mocks.setSession(77, "*", inst.mocks.buildSession{ count = 5 })
    inst.mocks.setAvailableSessions{ { sessionID = 77, durationSeconds = 22 } }
    inst.mocks.setRestricted(true)
    inst.mocks.setSecretValues(true)

    local ok, err = pcall(function()
        inst.NS.Provider.GetColumn(CURRENT, "DamageDone", 77)
        inst.NS.Provider.GetSessionDuration(CURRENT, 77)
        inst.NS.Provider.HasSession(77)
    end)
    assertTrue(ok, "a segment read inspected a value: " .. tostring(err))
end)

test("Provider.ProbeSourceByGuid names what the API did with a GUID it was handed", function()
    -- The diagnostic behind the open design question: `sourceGUID` is
    -- SecretWhenInCombat, so Lua may not key on it or look it up — but passing a
    -- secret to a function is permitted, and this API takes a sourceGUID
    -- argument. If the client resolves it, the per-source join we may not do
    -- ourselves can be done by the client, and a full grid survives a pull.
    --
    -- Every answer is a plain string because the failures differ: refused
    -- outright, accepted-and-matched-nothing, and readable-but-sealed each point
    -- at a different design.
    local guid = "Player-1-0000000A"
    local inst = T.load()
    inst.mocks.setSourceDetail(CURRENT, "*", guid, {
        combatSpells = {}, maxAmount = 10, totalAmount = 100,
    })

    assertEqual(inst.NS.Provider.ProbeSourceByGuid(CURRENT, "DamageDone", guid), "resolved")
    assertEqual(inst.NS.Provider.ProbeSourceByGuid(CURRENT, "DamageDone", "Player-1-0000NONE"), "nil")
    assertEqual(inst.NS.Provider.ProbeSourceByGuid(CURRENT, "NoSuchStat", guid), "no stat")
end)

test("Provider: an NPC source with no GUID is KEPT, on its creature ID", function()
    -- THE BUG THAT EMPTIED THE ENEMY COLUMN. An NPC carries a sourceCreatureID
    -- and no player GUID, so a `sourceGUID == nil` guard dropped every enemy —
    -- and the column then reported zero sources with `reason = nil`, which reads
    -- as "the session was fine and held nothing": the most misleading answer
    -- available, and one that took the tooltip's Targets section with it.
    -- red under: `if guid == nil then return end`.
    local inst = T.load()
    inst.mocks.setSession(1, inst.mocks.Enum.DamageMeterType.EnemyDamageTaken, {
        combatSources = {
            { sourceGUID = nil, sourceCreatureID = 6001, name = "Spirit of Hunger", totalAmount = 100 },
            { sourceGUID = nil, sourceCreatureID = 6002, name = "Thornclaw",        totalAmount = 50 },
        }, maxAmount = 100, totalAmount = 150 })

    local col = inst.NS.Provider:GetColumn(1, "EnemyDamageTaken", nil)
    assertEqual(#col.sources, 2, "every enemy was dropped for want of a player GUID")
    assertEqual(col.sources[1].creatureID, 6001, "the creature ID did not survive the flatten")
    assertEqual(col.sources[1].guid, nil, "a GUID was invented for a source that has none")
end)

test("Provider: a source with NEITHER identifier is still dropped", function()
    -- Loosening the guard must not turn it off. A row that can be identified by
    -- nothing cannot be joined, keyed or looked up, and keeping it would put an
    -- unaddressable entry in front of every consumer.
    -- red under: dropping the guard entirely.
    local inst = T.load()
    inst.mocks.setSession(1, inst.mocks.Enum.DamageMeterType.EnemyDamageTaken, {
        combatSources = {
            { sourceGUID = nil, sourceCreatureID = nil,  name = "Nobody",   totalAmount = 10 },
            { sourceGUID = nil, sourceCreatureID = 6003, name = "Somebody", totalAmount = 20 },
        }, maxAmount = 20, totalAmount = 30 })

    local col = inst.NS.Provider:GetColumn(1, "EnemyDamageTaken", nil)
    assertEqual(#col.sources, 1, "an unidentifiable source was kept")
    assertEqual(col.sources[1].name, "Somebody")
end)
