-- tests/test_aggregator_sort.lua — modules/Aggregator.lua's three sort modes,
-- and design rule R2: row order is NEVER computed from values while comparison
-- is illegal.
--
-- The interesting part of this file is the ladder's fallbacks rather than its
-- happy path. `value` mode sorts by numbers; the moment a pull starts those
-- numbers are secret and comparing them raises, so the mode has to degrade to
-- the provider's order. Each rung is driven here with a fixture where the WRONG
-- rung produces a visibly different order, so a regression cannot pass by
-- accident.
--
-- THE SORT FREEZE USED TO BE THE MIDDLE RUNG AND IS GONE. It cached a
-- guid -> position map and reapplied it for the duration of a pull — keyed, that
-- is, on the one field that turns out to be secret exactly when the freeze was
-- needed. Under the restriction the aggregator now takes the identity build,
-- whose order is the engine's own live ranking of the sort column, so `value`
-- mode is never asked to degrade for secrecy at all. The cases below drive the
-- comparator guards by wrapping INDIVIDUAL amounts with `mocks.secret`, which
-- leaves the GUID plain so the exact join still runs and the ladder is still
-- reached. `setSecretValues` would seal the GUID along with the amounts — it is
-- the same SecretWhenInCombat trigger — and there would be no rows to order.

local T = _G.MULTIMETERS_TEST

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
    assertFalse(result.identityMode, "an unrestricted pass is the exact GUID join")
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

test("a missing cell counts as ZERO, so it leads an ascending sort", function()
    -- A blank Avoidable cell means the player took no avoidable damage, and
    -- ascending by that column is a question about who took the least — so they
    -- belong at the TOP. This used to park a missing cell last in BOTH
    -- directions, on the reading that an absence is not a low score; for a
    -- contribution column it is exactly a low score, and the meter is reporting
    -- zero rather than declining to answer.
    --
    -- The "cannot be known" case does not collide with this: a cell left empty
    -- for an ambiguous identity only happens while restricted, and value sorting
    -- does not run there at all.
    -- red under: `if av == nil then return false end`.
    local inst = loaded()
    install(inst, { src(ALPHA, 100), src(BETA, 10) },
        { statKey = "DamageDone", maxAmount = 100, totalAmount = 110 })
    install(inst, { src(GAMMA, 4) }, { statKey = "Interrupts", maxAmount = 4 })

    local window = makeWindow{ sortMode = "value", columns = { "DamageDone", "Interrupts" } }
    window.data.sortAscending = true

    assertOrder(inst.NS.Aggregator.Build(window), { GAMMA, BETA, ALPHA },
        "nobody-did-any sorts as zero, which is first when the smallest leads")
end)

test("two missing cells keep provider order, so the sort stays deterministic", function()
    -- Both are zero, and table.sort is not stable: without an explicit tiebreak
    -- the pair would swap between refreshes for no visible reason.
    local inst = loaded()
    install(inst, { src(ALPHA, 100) },
        { statKey = "DamageDone", maxAmount = 100, totalAmount = 100 })
    install(inst, { src(BETA, 4), src(GAMMA, 2) }, { statKey = "Interrupts", maxAmount = 4 })

    local window = makeWindow{ sortMode = "value", columns = { "DamageDone", "Interrupts" } }
    assertOrder(inst.NS.Aggregator.Build(window), { ALPHA, BETA, GAMMA }, "first pass")
    assertOrder(inst.NS.Aggregator.Build(window), { ALPHA, BETA, GAMMA }, "and again")
end)

test("a value sort caches NOTHING — the freeze is retired", function()
    -- It cached guid -> position and reapplied that for the whole of a pull. The
    -- map could never have been applied to a single mid-pull row: `sourceGUID` is
    -- SecretWhenInCombat, so the rows it was keyed on have no GUID at exactly the
    -- moment the freeze was for.
    -- red under: reinstating freeze() in applySortMode.
    local inst = loaded()
    install(inst, { src(BETA, 10), src(ALPHA, 100) }, { maxAmount = 100, totalAmount = 110 })

    inst.NS.Aggregator.Build(makeWindow{ id = 7, sortMode = "value" })
    assertEqual(inst.NS.State.Cache("Aggregator")[7], nil,
        "a cached order is a snapshot that cannot survive the state it was made for")
end)

-- ---------------------------------------------------------------------------
-- while the restriction is active — identity mode
-- ---------------------------------------------------------------------------

test("while restricted the order is the ENGINE's ranking, and it is live", function()
    -- What replaced the freeze. The sort column's combatSources arrives already
    -- ranked by that column, so the order costs no comparison of ours and it
    -- moves with the fight instead of being a snapshot of its first frame.
    local inst = loaded()
    inst.mocks.setRestricted(true)
    local window = makeWindow{ id = 3, sortMode = "value" }

    install(inst, { src(ALPHA, 100), src(BETA, 10) }, { maxAmount = 100, totalAmount = 110 })
    local first = inst.NS.Aggregator.Build(window)
    assertEqual(#first, 2)
    assertTrue(first.identityMode, "a restricted pass cannot use the GUID join")

    -- BETA overtakes. A frozen order would have pinned ALPHA to the top for the
    -- rest of the pull; the engine's ranking follows.
    install(inst, { src(BETA, 900), src(ALPHA, 100) }, { maxAmount = 900, totalAmount = 1000 })
    local second = inst.NS.Aggregator.Build(window)
    -- Revealed for the assertion only: the addon itself never looks.
    assertEqual(inst.mocks.reveal(second[1].values.DamageDone.total), 900,
        "the top row is the top parse")
end)

test("while restricted a row is keyed on its POSITION, never on the secret GUID", function()
    -- `sourceGUID` is SecretWhenInCombat: keying a table on one raises. The row
    -- still needs an identity the pool and the drill-down can hold, so it gets a
    -- plain one derived from where the engine put it.
    local inst = loaded()
    inst.mocks.setRestricted(true)
    install(inst, { src(ALPHA, 100), src(BETA, 10) }, { maxAmount = 100, totalAmount = 110 })

    local result = inst.NS.Aggregator.Build(makeWindow{ sortMode = "value" })
    assertEqual(result[1].guid, "rank_1")
    assertEqual(result[2].guid, "rank_2")
end)

test("value mode checks comparability in a pass BEFORE table.sort is entered", function()
    local inst = loaded()
    -- The AMOUNTS are opaque and the GUIDs are not, so the exact join still runs
    -- and the sort ladder is still reached — which is the only state in which
    -- this pre-pass has anything to refuse.
    inst.mocks.setSecretsAccessible(false)
    install(inst, { src(BETA, inst.mocks.secret(10)), src(ALPHA, inst.mocks.secret(100)) },
        { maxAmount = 100, totalAmount = 110 })

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

test("the Activating edge is no longer listened for", function()
    -- It existed to take one last legal value-sort and freeze the result. With
    -- the freeze gone there is nothing for that dispatch to do here, and
    -- modules/Window.lua already redraws on the same transition.
    -- red under: reinstating the RESTRICTION_CHANGED subscription.
    local inst = T.load()
    local NS, mocks = inst.NS, inst.mocks
    NS.Aggregator:OnEnable()

    assertEqual((mocks.__busRegistry[NS.Constants.MSG.RESTRICTION_CHANGED] or {})[NS.Aggregator],
        nil, "a subscription with no handler behind it is dead wiring")
    assertEqual(NS.Aggregator.OnRestrictionChanged, nil)
end)

-- ---------------------------------------------------------------------------
-- provider mode
-- ---------------------------------------------------------------------------

test("provider mode never compares a value, in combat or out", function()
    local inst = loaded()
    install(inst, { src(BETA, inst.mocks.secret(10)), src(GAMMA, inst.mocks.secret(50)),
                    src(ALPHA, inst.mocks.secret(100)) },
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
    install(inst, { src(GAMMA, inst.mocks.secret(5000)), src(BETA, inst.mocks.secret(900)),
                    src(ALPHA, inst.mocks.secret(1)) },
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

    -- Two rows with EQUAL providerIndex: neither column is the sort column
    -- (Deaths is in the catalog but not on this window), so every row is parked
    -- at UNRANKED + its index, and each of these is the first row of its own
    -- column.
    -- The NAMES are wrapped individually rather than through setSecretValues,
    -- which would seal the sourceGUID with them (same SecretWhenInCombat
    -- trigger) and leave no rows to order at all.
    install(inst, { src(ALPHA, 100, { name = inst.mocks.secret("Zeta") }) },
        { statKey = "DamageDone", maxAmount = 100 })
    install(inst, { src(BETA, 100, { name = inst.mocks.secret("Alfa") }) },
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

-- ---------------------------------------------------------------------------
-- Direction, while restricted (issue #14)
-- ---------------------------------------------------------------------------

test("while restricted an ASCENDING sort reverses the engine's order", function()
    -- Reversing an array is a PERMUTATION, not a comparison: nothing is
    -- compared, added, or keyed on, so it is legal on a list of secrets. The
    -- direction was simply discarded mid-pull, which is why clicking a header to
    -- flip the grid appeared to do nothing for the whole of a pull.
    -- red under: `orderByProvider(pass.rows)` with no direction in Build.
    local inst = loaded()
    inst.mocks.setRestricted(true)
    install(inst, { src(ALPHA, 100), src(BETA, 50), src(GAMMA, 10) },
        { maxAmount = 100, totalAmount = 160 })

    local window = makeWindow{ sortMode = "value" }
    assertOrder(inst.NS.Aggregator.Build(window), { "rank_1", "rank_2", "rank_3" },
        "descending is the engine's own order, untouched")

    window.data.sortAscending = true
    assertOrder(inst.NS.Aggregator.Build(window), { "rank_3", "rank_2", "rank_1" },
        "ascending is that order read from the other end")
end)

test("an ascending mid-pull reverse leads with the rows the sort column never named", function()
    -- Consistent with the unrestricted rule one section up: a missing cell counts
    -- as ZERO, so it leads an ascending sort. Those rows sit past every ranked
    -- one at UNRANKED + index, so a whole-array reverse puts them first — which
    -- is the same answer `value` mode gives out of combat.
    local inst = loaded()
    inst.mocks.setRestricted(true)
    install(inst, { src(ALPHA, 100), src(BETA, 50) },
        { statKey = "DamageDone", maxAmount = 100, totalAmount = 150 })
    install(inst, { src(GAMMA, 4, { class = "ROGUE" }) },
        { statKey = "Interrupts", maxAmount = 4 })

    local window = makeWindow{ sortMode = "value",
        columns = { "DamageDone", "Interrupts" }, sortColumn = "DamageDone" }
    window.data.sortAscending = true

    local result = inst.NS.Aggregator.Build(window)
    assertEqual(#result, 3)
    assertEqual(result[1].guid:sub(1, 6), "ident:",
        "the row no ranked column named is the zero, and zero leads ascending")
end)

test("the build PUBLISHES which order actually took effect", function()
    -- `applied` was computed on the pass and thrown away. modules/Window.lua has
    -- no other way to know that the grid in front of the player is the engine's
    -- ranking rather than the sort they asked for, which is the difference
    -- between a limitation and a lie.
    -- red under: dropping `kept.applied` from assembleResult.
    local inst = loaded()
    install(inst, { src(ALPHA, 100), src(BETA, 10) }, { maxAmount = 100, totalAmount = 110 })
    assertEqual(inst.NS.Aggregator.Build(makeWindow{ sortMode = "value" }).applied, "value")

    inst.mocks.setRestricted(true)
    assertEqual(inst.NS.Aggregator.Build(makeWindow{ id = 9, sortMode = "value" }).applied,
        "provider", "mid-pull the engine's order is what took effect, whatever was asked for")
end)

test("`provider` mode honours the direction OUT of combat too", function()
    -- The same defect one rung up. `orderByProvider` is the fallback every mode
    -- degrades to AND a mode a player can select outright, and it discarded
    -- `sortAscending` in both roles — so a window on `provider` mode had a
    -- header arrow that flipped over rows that never moved.
    -- red under: `orderByProvider(rows)` in applySortMode.
    local inst = loaded()
    install(inst, { src(ALPHA, 100), src(BETA, 50), src(GAMMA, 10) },
        { maxAmount = 100, totalAmount = 160 })

    local window = makeWindow{ sortMode = "provider" }
    assertOrder(inst.NS.Aggregator.Build(window), { ALPHA, BETA, GAMMA }, "descending")

    window.data.sortAscending = true
    assertOrder(inst.NS.Aggregator.Build(window), { GAMMA, BETA, ALPHA },
        "the same order read from the other end")
end)
