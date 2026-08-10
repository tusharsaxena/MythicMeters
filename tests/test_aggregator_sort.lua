-- tests/test_aggregator_sort.lua — modules/Aggregator.lua's three sort modes,
-- and design rule R2: row order is NEVER computed from values while comparison
-- is illegal.
--
-- The interesting part of this file is the ladder's fallbacks rather than its
-- happy path. `value` mode sorts by numbers; the moment a pull starts those
-- numbers are secret and comparing them raises, so the mode has to degrade —
-- first to the order frozen at the last legal sort, and only then to the
-- provider's. Each rung is driven here with a fixture where the WRONG rung
-- produces a visibly different order, so a regression cannot pass by accident.

local T = _G.MYTHICMETERS_TEST

local test        = T.test
local assertEqual = T.assertEqual
local assertTrue  = T.assertTrue
local assertFalse = T.assertFalse

local CURRENT = 1

local ALPHA = "Player-1-0000000A"
local BETA  = "Player-1-0000000B"
local GAMMA = "Player-1-0000000C"

local GROUP = {
    { guid = ALPHA, name = "Alpha", class = "PALADIN", role = "TANK"    },
    { guid = BETA,  name = "Beta",  class = "PRIEST",  role = "HEALER"  },
    { guid = GAMMA, name = "Gamma", class = "ROGUE",   role = "DAMAGER" },
}

local function src(guid, total, opts)
    opts = opts or {}
    return {
        sourceGUID      = guid,
        name            = opts.name or guid,
        classFilename   = opts.class or "MAGE",
        totalAmount     = total,
        amountPerSecond = opts.rate,
    }
end

local function makeWindow(opts)
    opts = opts or {}
    local columns = {}
    for _, key in ipairs(opts.columns or { "DamageDone" }) do
        columns[#columns + 1] = { stat = key, width = 80 }
    end
    return {
        id      = opts.id or 1,
        columns = columns,
        rows    = {},
        data    = {
            sessionType = CURRENT,
            sortMode    = opts.sortMode or "value",
            sortColumn  = opts.sortColumn,
        },
    }
end

local function loaded(group)
    local inst = T.load()
    inst.mocks.setGroup(group or GROUP)
    inst.NS.Roster.Refresh()
    return inst
end

local function install(inst, sources, opts)
    opts = opts or {}
    local statType = opts.statKey
        and inst.NS.Constants.STAT_BY_KEY[opts.statKey].enumValue or "*"
    inst.mocks.setSession(CURRENT, statType, {
        combatSources = sources,
        maxAmount     = opts.maxAmount,
        totalAmount   = opts.totalAmount,
    })
end

--- The row GUIDs of a build, in order — what every case here is really about.
local function order(result)
    local out = {}
    for i, row in ipairs(result) do out[i] = row.guid end
    return out
end

local function assertOrder(result, expected, msg)
    local got = order(result)
    assertEqual(#got, #expected, (msg or "order") .. ": row count")
    for i = 1, #expected do
        assertEqual(got[i], expected[i], (msg or "order") .. ": position " .. i)
    end
end

-- ---------------------------------------------------------------------------
-- value mode, while comparison is legal
-- ---------------------------------------------------------------------------

test("value mode orders by the sort column's numbers, descending", function()
    local inst = loaded()
    -- The API's order is ASCENDING here on purpose: if the sort never ran, the
    -- assertion below would see the provider's order instead and fail.
    install(inst, { src(BETA, 10), src(GAMMA, 50), src(ALPHA, 100) },
        { maxAmount = 100, totalAmount = 160 })

    local result = inst.NS.Aggregator.Build(makeWindow{ sortMode = "value" })
    assertOrder(result, { ALPHA, GAMMA, BETA })
    assertEqual(result.sortFrozen, false, "a live sort is not a frozen one")
end)

test("value mode breaks a tie on providerIndex, so the order is deterministic", function()
    local inst = loaded()
    -- table.sort is not stable, so two equal values need an explicit tiebreak or
    -- the row order flickers between refreshes for no visible reason.
    install(inst, { src(GAMMA, 50), src(BETA, 50), src(ALPHA, 50) },
        { maxAmount = 50, totalAmount = 150 })

    local window = makeWindow{ sortMode = "value" }
    assertOrder(inst.NS.Aggregator.Build(window), { GAMMA, BETA, ALPHA }, "first pass")
    assertOrder(inst.NS.Aggregator.Build(window), { GAMMA, BETA, ALPHA }, "and again")
end)

test("value mode sorts a row with no cell in the sort column last", function()
    local inst = loaded()
    install(inst, { src(ALPHA, 100), src(BETA, 10) },
        { statKey = "DamageDone", maxAmount = 100, totalAmount = 110 })
    install(inst, { src(GAMMA, 4) }, { statKey = "Interrupts", maxAmount = 4 })

    local result = inst.NS.Aggregator.Build(
        makeWindow{ sortMode = "value", columns = { "DamageDone", "Interrupts" } })
    assertOrder(result, { ALPHA, BETA, GAMMA })
end)

test("value mode freezes the order it produced, keyed by GUID", function()
    local inst = loaded()
    install(inst, { src(BETA, 10), src(ALPHA, 100) }, { maxAmount = 100, totalAmount = 110 })

    inst.NS.Aggregator.Build(makeWindow{ id = 7, sortMode = "value" })
    local frozen = inst.NS.State.Cache("Aggregator")[7]
    assertEqual(type(frozen), "table")
    -- guid -> position, because the only question ever asked of it is "where
    -- does this GUID go"; an array would make that a scan per row per refresh.
    assertEqual(frozen[ALPHA], 1)
    assertEqual(frozen[BETA], 2)
end)

-- ---------------------------------------------------------------------------
-- value mode, while comparison is illegal
-- ---------------------------------------------------------------------------

test("value mode does NOT compare while restricted; it reuses the frozen order", function()
    local inst = loaded()
    local window = makeWindow{ id = 3, sortMode = "value" }

    -- One legal sort, out of combat: ALPHA is ahead of BETA and that is frozen.
    install(inst, { src(BETA, 10), src(ALPHA, 100) }, { maxAmount = 100, totalAmount = 110 })
    assertOrder(inst.NS.Aggregator.Build(window), { ALPHA, BETA }, "the legal sort")

    -- Now the pull starts. The numbers move AND the provider's order is
    -- BETA-first, so a fall-through to provider order would be visible.
    inst.mocks.setRestricted(true)
    install(inst, { src(BETA, 900), src(ALPHA, 100) }, { maxAmount = 900, totalAmount = 1000 })

    local result = inst.NS.Aggregator.Build(window)
    assertOrder(result, { ALPHA, BETA },
        "rows update in place; nothing reshuffles at the worst possible moment")
    assertEqual(result.sortFrozen, true, "and the header is told to say so")
end)

test("a GUID with no frozen place sorts after the frozen block", function()
    local inst = loaded()
    local window = makeWindow{ id = 4, sortMode = "value" }

    install(inst, { src(BETA, 10), src(ALPHA, 100) }, { maxAmount = 100, totalAmount = 110 })
    inst.NS.Aggregator.Build(window)

    -- Gamma joined mid-pull and sits FIRST in the provider's order. They appear
    -- at the bottom and disturb nothing above them.
    inst.mocks.setRestricted(true)
    install(inst, { src(GAMMA, 5000), src(BETA, 10), src(ALPHA, 100) },
        { maxAmount = 5000, totalAmount = 5110 })

    assertOrder(inst.NS.Aggregator.Build(window), { ALPHA, BETA, GAMMA })
end)

test("value mode falls through to provider order when there is no freeze", function()
    local inst = loaded()
    inst.mocks.setRestricted(true)
    install(inst, { src(BETA, 10), src(GAMMA, 50), src(ALPHA, 100) },
        { maxAmount = 100, totalAmount = 160 })

    -- Nothing was ever frozen for this window, so the only order left is the
    -- one the API returned — which needs no comparison and cannot fail.
    local result = inst.NS.Aggregator.Build(makeWindow{ id = 5, sortMode = "value" })
    assertOrder(result, { BETA, GAMMA, ALPHA })
    assertEqual(result.sortFrozen, false)
end)

test("value mode checks comparability in a pass BEFORE table.sort is entered", function()
    local inst = loaded()
    inst.mocks.setRestricted(true)
    install(inst, { src(BETA, 10), src(ALPHA, 100) }, { maxAmount = 100, totalAmount = 110 })

    -- The proof that the check is a separate pass rather than a test inside the
    -- comparator: CanCompare is consulted, and table.sort is never entered with
    -- values it would have raised on. A comparator that discovered the problem
    -- halfway through would already have raised, and there is no unwinding a
    -- partially sorted array.
    local Secrets = inst.NS.Secrets
    local real, calls = Secrets.CanCompare, 0
    Secrets.CanCompare = function(v) calls = calls + 1 return real(v) end

    local ok = pcall(inst.NS.Aggregator.Build, makeWindow{ id = 6, sortMode = "value" })
    Secrets.CanCompare = real

    assertTrue(ok, "the refusal must be clean, never a raise")
    assertTrue(calls > 0, "CanCompare must actually be consulted")
end)

test("the Activating edge takes one final sort for every value-sorted window", function()
    local inst = T.load()
    inst.mocks.setGroup(GROUP)
    inst.NS.Roster.Refresh()
    install(inst, { src(BETA, 10), src(ALPHA, 100) }, { maxAmount = 100, totalAmount = 110 })

    local NS = inst.NS
    local window = NS.Database.GetWindows()[1]
    window.data.sortMode    = "value"
    window.data.sortColumn  = "DamageDone"
    -- `install` seeds the CURRENT session; the shipped default is Overall.
    window.data.sessionType = CURRENT

    NS.State.WipeCache("Aggregator")
    -- Anything but Activating is ignored: Active is too late (enforcement has
    -- begun) and Inactive needs no help.
    NS.Aggregator:OnRestrictionChanged(nil, { state = NS.Secrets.STATE.Active })
    assertEqual(NS.State.Cache("Aggregator")[window.id], nil)

    -- Activating fires BEFORE enforcement begins and access is still permitted
    -- during the dispatch — the last legal moment for a correct value sort.
    NS.Aggregator:OnRestrictionChanged(nil, { state = NS.Secrets.STATE.Activating })
    local frozen = NS.State.Cache("Aggregator")[window.id]
    assertEqual(type(frozen), "table", "the pull's starting order is captured here")
    assertEqual(frozen[ALPHA], 1)
end)

-- ---------------------------------------------------------------------------
-- provider mode
-- ---------------------------------------------------------------------------

test("provider mode never compares a value, in combat or out", function()
    local inst = loaded()
    inst.mocks.setRestricted(true)
    install(inst, { src(BETA, 10), src(GAMMA, 50), src(ALPHA, 100) },
        { maxAmount = 100, totalAmount = 160 })

    -- CanCompare has exactly one caller in the aggregator: the value sort's
    -- pre-pass. Provider mode must not reach it at all.
    local Secrets = inst.NS.Secrets
    local real, calls = Secrets.CanCompare, 0
    Secrets.CanCompare = function(v) calls = calls + 1 return real(v) end

    local result = inst.NS.Aggregator.Build(makeWindow{ sortMode = "provider" })
    Secrets.CanCompare = real

    assertEqual(calls, 0, "provider mode asked whether it could compare — it should not care")
    assertOrder(result, { BETA, GAMMA, ALPHA })
    assertEqual(result.sortFrozen, false)
end)

test("an unrecognized sort mode degrades to provider order rather than to nothing", function()
    local inst = loaded()
    install(inst, { src(BETA, 10), src(ALPHA, 100) }, { maxAmount = 100, totalAmount = 110 })
    assertOrder(inst.NS.Aggregator.Build(makeWindow{ sortMode = "somethingelse" }),
        { BETA, ALPHA })
end)

-- ---------------------------------------------------------------------------
-- roster mode
-- ---------------------------------------------------------------------------

test("roster mode orders by group position, ignoring the numbers entirely", function()
    local inst = loaded()
    inst.mocks.setRestricted(true)
    install(inst, { src(GAMMA, 5000), src(BETA, 900), src(ALPHA, 1) },
        { maxAmount = 5000, totalAmount = 5901 })

    -- The mode that never moves: group order is a plain-data fact, so it is
    -- legal mid-pull when `value` mode is not.
    assertOrder(inst.NS.Aggregator.Build(makeWindow{ sortMode = "roster" }),
        { ALPHA, BETA, GAMMA })
end)

test("roster mode ranks role before name within one group position", function()
    local inst = loaded()
    -- Equal providerIndex — neither column is the sort column — so the
    -- comparator gets past its first test and onto the role rank.
    install(inst, { src(ALPHA, 1, { name = "Aaa" }) },
        { statKey = "DamageDone", maxAmount = 1 })
    install(inst, { src(BETA, 1, { name = "Zzz" }) },
        { statKey = "HealingDone", maxAmount = 1 })

    -- Roles that disagree with the names: alphabetically ALPHA wins, by role
    -- BETA does. Roles sort tank, healer, damager rather than alphabetically,
    -- because that is how a raid frame reads and the point of this mode is
    -- predictability.
    local NS = inst.NS
    local realGet, realGroup = NS.Roster.Get, NS.Roster.GetGroup
    NS.Roster.Get = function(guid)
        return { guid = guid, role = (guid == ALPHA) and "DAMAGER" or "HEALER" }
    end
    NS.Roster.GetGroup = function() return {} end

    local result = NS.Aggregator.Build(
        makeWindow{ sortMode = "roster", columns = { "DamageDone", "HealingDone" },
                    sortColumn = "Deaths" })

    NS.Roster.Get, NS.Roster.GetGroup = realGet, realGroup

    assertEqual(result[1].providerIndex, result[2].providerIndex,
        "the fixture must actually reach the role rank")
    assertOrder(result, { BETA, ALPHA }, "the healer outranks the damager")
end)

test("roster mode's NAME TIEBREAK refuses to compare two secret names", function()
    -- The bug this case exists for: the tiebreak is reached ONLY by rows absent
    -- from the roster — pets, enemies, cross-realm strays — and that is exactly
    -- the population whose `name` came from the meter's ConditionalSecret
    -- src.name rather than from a unit token. `<` on two of those raises
    -- mid-combat, and tostring() does not launder a secret: it survives it.
    local inst = loaded()
    inst.mocks.setRestricted(true)

    -- Two rows with EQUAL providerIndex: neither column is the sort column
    -- (Deaths is in the catalog but not on this window), so every row is parked
    -- at UNRANKED + its index, and each of these is the first row of its own
    -- column.
    install(inst, { src(ALPHA, 100, { name = "Zeta" }) },
        { statKey = "DamageDone", maxAmount = 100 })
    install(inst, { src(BETA, 100, { name = "Alfa" }) },
        { statKey = "HealingDone", maxAmount = 100 })

    local NS = inst.NS

    -- Absent from the roster, present as members. That combination is what the
    -- comparator's last branch is written for: the row exists, and nothing in
    -- the group array knows where to put it.
    local realGet, realGroup = NS.Roster.Get, NS.Roster.GetGroup
    NS.Roster.Get      = function() return nil end
    NS.Roster.GetGroup = function() return {} end

    -- Record every comparability question asked, so the guard can be shown to
    -- have been consulted for the NAMES rather than only for the amounts.
    local Secrets = NS.Secrets
    local realCompare2 = Secrets.CanCompare2
    local pairsSeen = {}
    Secrets.CanCompare2 = function(a, b)
        pairsSeen[#pairsSeen + 1] = { a, b }
        return realCompare2(a, b)
    end

    local ok, result = pcall(NS.Aggregator.Build,
        makeWindow{ sortMode = "roster", columns = { "DamageDone", "HealingDone" },
                    sortColumn = "Deaths" })

    Secrets.CanCompare2 = realCompare2
    NS.Roster.Get, NS.Roster.GetGroup = realGet, realGroup

    assertTrue(ok, "the name tiebreak must not raise: " .. tostring(result))
    assertEqual(#result, 2)
    assertEqual(result[1].providerIndex, result[2].providerIndex,
        "the fixture must actually reach the tiebreak")

    local sawNames = false
    for _, pair in ipairs(pairsSeen) do
        local a, b = inst.mocks.reveal(pair[1]), inst.mocks.reveal(pair[2])
        if (a == "Zeta" and b == "Alfa") or (a == "Alfa" and b == "Zeta") then
            sawNames = true
            assertTrue(inst.mocks.isSimulatedSecret(pair[1]), "the names really are secret")
            assertTrue(inst.mocks.isSimulatedSecret(pair[2]))
        end
    end
    assertTrue(sawNames,
        "the two names were never put to core/Secrets.lua — the guard is gone or bypassed")

    -- And having refused, it fell back to providerIndex rather than to an
    -- alphabetical order it had no legal way to compute.
    assertFalse(result[1].name == nil)
end)

test("roster mode compares names when they are plain", function()
    local inst = loaded()
    install(inst, { src(ALPHA, 100, { name = "Zeta" }) },
        { statKey = "DamageDone", maxAmount = 100 })
    install(inst, { src(BETA, 100, { name = "Alfa" }) },
        { statKey = "HealingDone", maxAmount = 100 })

    local NS = inst.NS
    local realGet, realGroup = NS.Roster.Get, NS.Roster.GetGroup
    NS.Roster.Get      = function() return nil end
    NS.Roster.GetGroup = function() return {} end

    local result = NS.Aggregator.Build(
        makeWindow{ sortMode = "roster", columns = { "DamageDone", "HealingDone" },
                    sortColumn = "Deaths" })

    NS.Roster.Get, NS.Roster.GetGroup = realGet, realGroup

    -- Out of combat the names are ordinary strings, the guard says yes, and the
    -- tiebreak does what it says on the tin.
    assertEqual(result[1].providerIndex, result[2].providerIndex)
    assertOrder(result, { BETA, ALPHA }, "\"Alfa\" before \"Zeta\"")
end)
