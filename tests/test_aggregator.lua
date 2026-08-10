-- tests/test_aggregator.lua — modules/Aggregator.lua: the GUID join, the group
-- filter, and pet folding.
--
-- Ordering lives in tests/test_aggregator_sort.lua. What is tested here is the
-- pass that produces the rows in the first place, and in particular the one
-- behavior that is deliberately DIFFERENT in and out of combat: adding a pet's
-- number to its owner's is arithmetic, arithmetic on a secret raises, and there
-- is no native escape hatch for a sum the way there is for formatting. So the
-- restricted case drops the pet's contribution and says so, and both halves of
-- that are asserted rather than assumed.

local T = _G.MYTHICMETERS_TEST

local test        = T.test
local assertEqual = T.assertEqual
local assertTrue  = T.assertTrue
local assertNil   = T.assertNil

local CURRENT = 1   -- Enum.DamageMeterSessionType.Current

local ALPHA = "Player-1-0000000A"
local BETA  = "Player-1-0000000B"
local GAMMA = "Player-1-0000000C"
local PET   = "Pet-0-00001111"

local GROUP = {
    { guid = ALPHA, name = "Alpha", class = "PALADIN", role = "TANK"    },
    { guid = BETA,  name = "Beta",  class = "PRIEST",  role = "HEALER"  },
    { guid = GAMMA, name = "Gamma", class = "ROGUE",   role = "DAMAGER" },
}

--- One combatSources row, in the shape modules/Provider.lua reads
--- (`sourceGUID`, not `guid` — see the harness contract).
local function src(guid, total, opts)
    opts = opts or {}
    return {
        sourceGUID       = guid,
        name             = opts.name or guid,
        classFilename    = opts.class or "MAGE",
        specIconID       = opts.specIconID,
        totalAmount      = total,
        amountPerSecond  = opts.rate,
        deathTimeSeconds = opts.deathTime,
        deathRecapID     = opts.recapID,
    }
end

--- A window config shaped exactly like a stored one, but small enough that a
--- case names only what it is about.
local function makeWindow(opts)
    opts = opts or {}
    local columns = {}
    for _, key in ipairs(opts.columns or { "DamageDone" }) do
        columns[#columns + 1] = { stat = key, width = 80, showBar = true }
    end
    return {
        id      = opts.id or 1,
        name    = "Test",
        columns = columns,
        rows    = opts.rows or {},
        data    = {
            sessionType = CURRENT,
            -- `provider` unless a case is about ordering: it needs no comparison
            -- and so cannot quietly reorder what a join case is asserting.
            sortMode    = opts.sortMode or "provider",
            sortColumn  = opts.sortColumn,
            -- Off is the shipped default: a pet gets its own row. The folding
            -- mode is opt-in because merging is addition, and addition on two
            -- secret values raises.
            mergePets   = opts.mergePets or false,
        },
    }
end

--- A loaded instance with the standard three-player group.
local function loaded(opts)
    opts = opts or {}
    local inst = T.load()
    inst.mocks.setGroup(opts.group or GROUP)
    inst.NS.Roster.Refresh()
    return inst
end

--- Install one session spec under `statKey` (or every stat when omitted).
local function install(inst, sources, opts)
    opts = opts or {}
    local statType = opts.statKey
        and inst.NS.Constants.STAT_BY_KEY[opts.statKey].enumValue or "*"
    inst.mocks.setSession(CURRENT, statType, {
        combatSources   = sources,
        maxAmount       = opts.maxAmount,
        totalAmount     = opts.totalAmount,
        durationSeconds = opts.durationSeconds,
    })
end

-- ---------------------------------------------------------------------------
-- The join
-- ---------------------------------------------------------------------------

test("Aggregator joins columns on the GUID, which is the only legal key", function()
    local inst = loaded()
    install(inst, { src(ALPHA, 100), src(BETA, 50) },
        { statKey = "DamageDone", maxAmount = 100, totalAmount = 150 })
    install(inst, { src(BETA, 3), src(ALPHA, 1) },
        { statKey = "Interrupts", maxAmount = 3, totalAmount = 4 })

    local result = inst.NS.Aggregator.Build(
        makeWindow{ columns = { "DamageDone", "Interrupts" } })

    assertEqual(#result, 2)
    local byGuid = {}
    for _, row in ipairs(result) do byGuid[row.guid] = row end

    -- One row per player carrying BOTH columns, though the two sessions listed
    -- them in opposite orders.
    assertEqual(byGuid[ALPHA].values.DamageDone.total, 100)
    assertEqual(byGuid[ALPHA].values.Interrupts.total, 1)
    assertEqual(byGuid[BETA].values.DamageDone.total, 50)
    assertEqual(byGuid[BETA].values.Interrupts.total, 3)
end)

test("Aggregator's result table IS the row array, and cells aliases values", function()
    local inst = loaded()
    install(inst, { src(ALPHA, 100) }, { maxAmount = 100, totalAmount = 100 })

    local result = inst.NS.Aggregator.Build(makeWindow())
    assertTrue(result.rows == result, "result.rows and ipairs(result) are one object")
    assertEqual(#result.rows, 1)
    assertTrue(result[1] == result.rows[1])
    -- One table, two names — an alias costs one assignment, a copy costs a
    -- divergence between what the brief calls it and what modules/Row.lua reads.
    assertTrue(result[1].cells == result[1].values)
end)

test("Aggregator takes identity from the roster and the spec icon from the meter", function()
    local inst = loaded()
    install(inst, { src(ALPHA, 100, { name = "StaleName", class = "WARRIOR",
                                      specIconID = 135771 }) },
        { maxAmount = 100 })

    local row = inst.NS.Aggregator.Build(makeWindow())[1]
    -- The meter's `name` is ConditionalSecret; UnitName's answer is always plain
    -- text, so the roster wins for the name and loses for the spec icon.
    assertEqual(row.name, "Alpha")
    assertEqual(row.classFilename, "WARRIOR")
    assertEqual(row.specIconID, 135771)
    assertEqual(row.role, "TANK")
    assertEqual(row.isPlayer, true)
    assertTrue(row.isLocalPlayer == row.isPlayer, "one fact, two keys, assigned together")
    assertEqual(row.windowId, 1)
end)

test("Aggregator promotes deathRecapID onto the row, off whichever column carried it", function()
    local inst = loaded()
    install(inst, { src(ALPHA, 100) }, { statKey = "DamageDone", maxAmount = 100 })
    install(inst, { src(ALPHA, 1, { recapID = 4242, deathTime = 91 }) },
        { statKey = "Deaths", maxAmount = 1 })

    local row = inst.NS.Aggregator.Build(makeWindow{ columns = { "DamageDone", "Deaths" } })[1]
    -- It identifies the player's death, not a column's number, so neither the
    -- tooltip nor the drill-down has to know which column it arrived on.
    assertEqual(row.deathRecapID, 4242)
    assertEqual(row.values.Deaths.deathTime, 91)
end)

test("Aggregator puts the column max on every cell in the column", function()
    local inst = loaded()
    install(inst, { src(ALPHA, 100), src(BETA, 20) }, { maxAmount = 100, totalAmount = 120 })

    local result = inst.NS.Aggregator.Build(makeWindow())
    for _, row in ipairs(result) do
        assertEqual(row.values.DamageDone.maxAmount, 100,
            "every bar in a column scales to the same max")
    end
end)

test("Aggregator publishes columnTotals so nothing re-reads the session", function()
    local inst = loaded()
    install(inst, { src(ALPHA, 100), src(BETA, 20) },
        { maxAmount = 100, totalAmount = 120, durationSeconds = 212 })
    inst.mocks.setSessionDuration(CURRENT, 212)
    inst.mocks.resetMeterCalls()

    local result = inst.NS.Aggregator.Build(makeWindow())
    assertEqual(result.columnTotals.DamageDone, 120)
    assertEqual(result.sortColumn, "DamageDone")
    assertEqual(result.sortTotal, 120)
    assertEqual(result.durationSeconds, 212)
    assertEqual(result[1].values.DamageDone.columnTotal, 120,
        "and on the cell too, so a renderer holding one cell can say `x of y`")

    -- One session read per column, and one duration read. Re-entering the
    -- provider for a number this pass already holds would double the meter reads
    -- on the refresh path.
    assertEqual(inst.mocks.__meter.calls.GetCombatSessionFromType, 1)
end)

test("Aggregator surfaces the first column reason it met", function()
    local inst = loaded()
    -- No session installed at all for the second column.
    install(inst, { src(ALPHA, 100) }, { statKey = "DamageDone", maxAmount = 100 })

    local result = inst.NS.Aggregator.Build(
        makeWindow{ columns = { "DamageDone", "Interrupts" } })
    assertEqual(result.reason, "no session")
end)

test("Aggregator skips a stored column whose stat this build does not offer", function()
    local inst = loaded()
    install(inst, { src(ALPHA, 100) }, { maxAmount = 100 })

    local window = makeWindow{ columns = { "DamageDone" } }
    window.columns[#window.columns + 1] = { stat = "StatFromALaterBuild", width = 80 }

    local result = inst.NS.Aggregator.Build(window)
    assertNil(result.columns.StatFromALaterBuild, "the unknown column is dropped, not blank")
    assertEqual(result.columns.DamageDone.stat, "DamageDone")
end)

test("Aggregator falls back to the first column when sortColumn is unusable", function()
    local inst = loaded()
    install(inst, { src(ALPHA, 100) }, { maxAmount = 100 })
    local result = inst.NS.Aggregator.Build(
        makeWindow{ columns = { "DamageDone", "Interrupts" },
                    sortColumn = "StatFromALaterBuild" })
    assertEqual(result.sortColumn, "DamageDone")
end)

test("Aggregator.Build answers an empty result for a non-table window", function()
    local result = T.NS.Aggregator.Build(nil)
    assertEqual(#result.rows, 0)
    assertEqual(type(result.columns), "table")
end)

test("Aggregator.Build accepts both the dot and the colon call shape", function()
    local inst = loaded()
    install(inst, { src(ALPHA, 100) }, { maxAmount = 100 })
    local window = makeWindow()
    -- modules/Window.lua uses the colon form; a silent argument shift there
    -- would build the wrong window rather than error.
    assertEqual(#inst.NS.Aggregator.Build(window), 1)
    assertEqual(#inst.NS.Aggregator:Build(window), 1)
end)

-- ---------------------------------------------------------------------------
-- Filtering to group members
-- ---------------------------------------------------------------------------

test("Aggregator drops a source that is not a group member", function()
    local inst = loaded()
    install(inst, {
        src(ALPHA, 100),
        src("Player-2-0000DEAD", 90, { name = "PassingStranger" }),
        src("Creature-0-1234", 80, { name = "Some Boss" }),
    }, { maxAmount = 100, totalAmount = 270 })

    local result = inst.NS.Aggregator.Build(makeWindow())
    assertEqual(#result, 1)
    assertEqual(result[1].guid, ALPHA)
end)

test("Aggregator drops an unattributable pet rather than showing a phantom row", function()
    local inst = loaded()
    -- No setPet call: the roster cannot prove whose this is.
    install(inst, { src(ALPHA, 100), src(PET, 40, { name = "Gargoyle" }) },
        { maxAmount = 100, totalAmount = 140 })

    local result = inst.NS.Aggregator.Build(makeWindow())
    assertEqual(#result, 1, "a phantom row with a pet's name is worse than a low number")
    assertEqual(result[1].guid, ALPHA)
    assertEqual(result[1].values.DamageDone.total, 100, "and the owner is not credited for it")
end)

-- ---------------------------------------------------------------------------
-- Pet folding
-- ---------------------------------------------------------------------------

--- The three-player group with the player's pet attributed.
--- A group whose player has a pet. `merge` opts into the FOLDING mode, which is
--- no longer the default: a pet gets its own row unless the window asks for it to
--- be merged, because merging is addition and addition on secrets raises.
local function withPet()
    local inst = loaded()
    inst.mocks.setPet("player", PET)
    inst.NS.Roster.Refresh()
    return inst
end

test("Aggregator sums an attributed pet into its owner out of combat", function()
    local inst = withPet()
    install(inst, {
        src(ALPHA, 100, { rate = 10 }),
        src(PET, 40, { rate = 4, name = "Ghoul" }),
    }, { maxAmount = 100, totalAmount = 140 })

    local result = inst.NS.Aggregator.Build(makeWindow{ mergePets = true })
    assertEqual(#result, 1, "the pet is folded, never listed")
    assertEqual(result[1].guid, ALPHA)
    assertEqual(result[1].values.DamageDone.total, 140)
    assertEqual(result[1].values.DamageDone.rate, 14, "the rate folds with the total")
end)

test("Aggregator DROPS a pet's contribution while restricted, rather than summing", function()
    local inst = withPet()
    install(inst, {
        src(ALPHA, 100, { rate = 10 }),
        src(PET, 40, { rate = 4, name = "Ghoul" }),
    }, { maxAmount = 100, totalAmount = 140 })
    inst.mocks.setRestricted(true)

    -- Summing two secrets is arithmetic and raises; there is no native escape
    -- hatch for a sum. Reaching the assertions at all is the proof it refused.
    local result = inst.NS.Aggregator.Build(makeWindow{ mergePets = true })
    assertEqual(#result, 1, "and still no phantom pet row")
    assertEqual(result[1].guid, ALPHA)

    local total = result[1].values.DamageDone.total
    assertTrue(inst.mocks.isSimulatedSecret(total), "the owner's own handle, untouched")
    assertEqual(inst.mocks.reveal(total), 100,
        "the number is low by whatever the pet contributed — visible and explainable")
end)

test("Aggregator adopts a pet's numbers into a column the owner has no cell in", function()
    local inst = withPet()
    -- The pet did damage its owner did not. Taking the pet's numbers wholesale
    -- is not a sum, so it is legal in either state — and it is correct: the
    -- owner DID that damage, through the pet.
    install(inst, { src(PET, 40, { rate = 4, name = "Ghoul" }) },
        { maxAmount = 40, totalAmount = 40 })
    inst.mocks.setRestricted(true)

    local result = inst.NS.Aggregator.Build(makeWindow{ mergePets = true })
    assertEqual(#result, 1)
    assertEqual(result[1].guid, ALPHA)
    assertEqual(inst.mocks.reveal(result[1].values.DamageDone.total), 40)
    assertEqual(inst.mocks.reveal(result[1].values.DamageDone.maxAmount), 40,
        "the column max reaches a cell a pet fold created")
end)

test("A pet's position never moves its owner in the provider order", function()
    local inst = withPet()
    -- The pet sits at index 1 and its owner at index 3. A pet's index is a
    -- position in the SOURCE list, not in the row list.
    install(inst, {
        src(PET, 400, { name = "Ghoul" }),
        src(BETA, 200),
        src(ALPHA, 100),
    }, { maxAmount = 400, totalAmount = 700 })

    local result = inst.NS.Aggregator.Build(makeWindow{ mergePets = true })
    assertEqual(#result, 2)
    assertEqual(result[1].guid, BETA, "Beta was the first REAL member in the source list")
    assertEqual(result[2].guid, ALPHA)
    assertEqual(result[2].providerIndex, 3, "the owner keeps its own index, not the pet's")
end)

test("A row seen only outside the sort column is parked past every ranked row", function()
    local inst = loaded()
    install(inst, { src(BETA, 100) }, { statKey = "DamageDone", maxAmount = 100 })
    install(inst, { src(ALPHA, 1, { recapID = 7 }) }, { statKey = "Deaths", maxAmount = 1 })

    local result = inst.NS.Aggregator.Build(
        makeWindow{ columns = { "DamageDone", "Deaths" }, sortColumn = "DamageDone" })
    assertEqual(#result, 2)
    -- A player who died and did no damage is parked at the bottom in first-seen
    -- order rather than interleaved into the damage ranking.
    assertEqual(result[1].guid, BETA)
    assertEqual(result[1].providerIndex, 1)
    assertTrue(result[2].providerIndex > 1000, "unranked rows sit past every ranked one")
end)

-- ---------------------------------------------------------------------------
-- Percent — the one number this file computes
-- ---------------------------------------------------------------------------

test("Aggregator computes percent out of combat", function()
    local inst = loaded()
    install(inst, { src(ALPHA, 75), src(BETA, 25) },
        { maxAmount = 75, totalAmount = 100 })

    local result = inst.NS.Aggregator.Build(makeWindow{ mergePets = true })
    assertEqual(result[1].values.DamageDone.percent, 75)
    assertEqual(result[2].values.DamageDone.percent, 25)
end)

test("Aggregator answers nil percent while restricted — never zero", function()
    local inst = loaded()
    install(inst, { src(ALPHA, 75), src(BETA, 25) },
        { maxAmount = 75, totalAmount = 100 })
    inst.mocks.setRestricted(true)

    local result = inst.NS.Aggregator.Build(makeWindow{ mergePets = true })
    -- A division on an inaccessible operand raises, so the slot goes quiet. nil
    -- means "cannot be known right now" and callers must not read it as 0%.
    assertNil(result[1].values.DamageDone.percent)
    assertNil(result[2].values.DamageDone.percent)
end)

-- ---------------------------------------------------------------------------
-- The row cap
-- ---------------------------------------------------------------------------

test("ApplyRowLimit truncates to maxRows", function()
    local rows = {}
    for i = 1, 6 do rows[i] = { guid = i, isPlayer = false } end
    local kept = T.NS.Aggregator.ApplyRowLimit(rows, { maxRows = 3 })
    assertEqual(#kept, 3)
    assertEqual(kept[3].guid, 3)
end)

test("ApplyRowLimit treats 0 and an over-large cap as the hard ceiling", function()
    local NS = T.NS
    local rows = {}
    for i = 1, NS.Constants.MAX_ROWS + 5 do rows[i] = { guid = i } end
    assertEqual(#NS.Aggregator.ApplyRowLimit(rows, { maxRows = 0 }), NS.Constants.MAX_ROWS)

    local more = {}
    for i = 1, NS.Constants.MAX_ROWS + 5 do more[i] = { guid = i } end
    assertEqual(#NS.Aggregator.ApplyRowLimit(more, { maxRows = 9999 }), NS.Constants.MAX_ROWS)
end)

test("alwaysShowSelf spends the last visible slot on the player", function()
    local rows = {}
    for i = 1, 6 do rows[i] = { guid = "g" .. i, isPlayer = (i == 5) } end

    local kept = T.NS.Aggregator.ApplyRowLimit(rows, { maxRows = 3, alwaysShowSelf = true })
    assertEqual(#kept, 3, "the row count stays exactly at the cap")
    assertEqual(kept[3].guid, "g5", "the player is pinned into the last slot")
    assertEqual(kept[1].guid, "g1")
end)

test("alwaysShowSelf does nothing when the player is already visible", function()
    local rows = {}
    for i = 1, 6 do rows[i] = { guid = "g" .. i, isPlayer = (i == 2) } end
    local kept = T.NS.Aggregator.ApplyRowLimit(rows, { maxRows = 3, alwaysShowSelf = true })
    assertEqual(kept[3].guid, "g3", "nothing is displaced")
end)

test("Aggregator applies the cap before dividing, not after", function()
    local inst = loaded()
    install(inst, { src(ALPHA, 60), src(BETA, 30), src(GAMMA, 10) },
        { maxAmount = 60, totalAmount = 100 })

    local result = inst.NS.Aggregator.Build(makeWindow{ rows = { maxRows = 2 } })
    assertEqual(#result, 2, "the cap is enforced")
    assertEqual(result[1].values.DamageDone.percent, 60,
        "and the survivors still carry their share")
end)

-- ---------------------------------------------------------------------------
-- Preview
-- ---------------------------------------------------------------------------

test("Test mode substitutes the DATA, and the render path stays one path", function()
    -- It used to hand the renderer a whole separate result table built by a
    -- separate function, and the two modes then diverged at every seam nobody
    -- thought to duplicate: the tooltip found no source and said "No data yet",
    -- the drill-down opened on nothing, and every fix had to be applied twice.
    -- Substituting modules/Provider.lua's output instead means everything
    -- downstream is the live code reading invented numbers.
    -- red under: a `if testMode then BuildTestRows()` branch in the renderer.
    local inst = loaded()
    inst.NS.State.SetTestMode(true)

    local result = inst.NS.Aggregator.Build(makeWindow{ columns = { "DamageDone" } })
    assertTrue(#result > 1, "test mode must produce a full grid through Build")
    assertTrue(result[1].values.DamageDone ~= nil, "shaped exactly like live rows")
    assertTrue(result[1].name ~= nil)
end)

test("A test row's tooltip finds a breakdown, because it goes to the provider", function()
    -- The seam that was broken for a release. The tooltip asks the provider; the
    -- provider is what test mode replaces; so the tooltip needs no idea which
    -- mode it is in.
    local inst = loaded()
    inst.NS.State.SetTestMode(true)

    local result = inst.NS.Aggregator.Build(makeWindow{ columns = { "DamageDone" } })
    local detail = inst.NS.Provider.GetSourceDetail(CURRENT, "DamageDone", result[1].guid)
    assertTrue(type(detail) == "table", "a test row must have a spell breakdown")
    assertTrue(#detail.combatSpells > 0)
end)

test("Test mode reaches no meter API at all", function()
    -- The substitution is at the provider, so nothing behind it is ever asked.
    local inst = loaded()
    inst.NS.State.SetTestMode(true)
    inst.mocks.resetMeterCalls()

    inst.NS.Aggregator.Build(makeWindow{ columns = { "DamageDone", "Deaths" } })
    for name, count in pairs(inst.mocks.__meter.calls) do
        assertEqual(count, 0, "test mode called " .. name)
    end
end)

test("Test data is deterministic — a jittering grid cannot be laid out against", function()
    local inst = loaded()
    inst.NS.State.SetTestMode(true)
    local window = makeWindow{ columns = { "DamageDone" } }

    local first  = inst.NS.Aggregator.Build(window)
    local second = inst.NS.Aggregator.Build(window)
    assertEqual(#first, #second)
    for i = 1, #first do
        assertEqual(first[i].values.DamageDone.total, second[i].values.DamageDone.total)
    end
end)

test("A meter reset drops the frozen sort orders", function()
    local inst = loaded()
    install(inst, { src(ALPHA, 100) }, { maxAmount = 100, totalAmount = 100 })

    -- A successful value sort freezes the order it produced.
    inst.NS.Aggregator.Build(makeWindow{ sortMode = "value" })
    local frozen = inst.NS.State.Cache("Aggregator")
    assertTrue(frozen[1] ~= nil, "the value sort froze this window's order")

    inst.NS.Aggregator:OnMeterReset()
    assertNil(frozen[1], "a frozen order describes a fight that no longer exists")
end)

-- ---------------------------------------------------------------------------
-- The pet gets its own row, and the roster remembers
-- ---------------------------------------------------------------------------

test("A pet gets its OWN row by default, with its own name", function()
    -- Merging is addition and addition on secrets raises, so the merged mode is
    -- exact out of combat and lossy inside it. A separate row has no arithmetic
    -- in it at all, and is what Blizzard's own meter shows.
    -- red under: folding unconditionally, which loses the pet mid-pull.
    local inst = withPet()
    install(inst, {
        src(ALPHA, 100, { rate = 10 }),
        src(PET, 40, { rate = 4, name = "Bheemyn" }),
    }, { maxAmount = 100, totalAmount = 140 })

    local result = inst.NS.Aggregator.Build(makeWindow())
    assertEqual(#result, 2, "the owner and the pet")

    local byGuid = {}
    for _, row in ipairs(result) do byGuid[row.guid] = row end
    assertEqual(byGuid[ALPHA].values.DamageDone.total, 100, "the owner keeps HER OWN number")
    assertEqual(byGuid[PET].values.DamageDone.total, 40)
    assertEqual(byGuid[PET].name, "Bheemyn", "the pet reads as the pet, not as a second owner row")
    assertEqual(byGuid[PET].isPet, true)
    assertEqual(byGuid[PET].ownerGuid, ALPHA, "and still knows whose it is")
end)

test("A pet's own row survives the restriction, where a merged one would not", function()
    local inst = withPet()
    inst.mocks.setRestricted(true)
    install(inst, {
        src(ALPHA, inst.mocks.secret(100)),
        src(PET, inst.mocks.secret(40), { name = "Bheemyn" }),
    }, { maxAmount = inst.mocks.secret(100) })

    -- No sum is attempted, so there is nothing for the restriction to forbid.
    local result = inst.NS.Aggregator.Build(makeWindow())
    assertEqual(#result, 2, "mid-pull, both rows are present and both are exact")
end)

test("Leaving the group does NOT empty the window", function()
    -- THE BUG. modules/Aggregator.lua drops any source the roster cannot place,
    -- and the live roster collapses to { player } the moment you leave a dungeon
    -- group — so the window showed one row for a session that still held
    -- everybody's numbers. The data was intact; the filter had thrown it away.
    -- red under: Roster.IsGroupMember consulting only the live cache.
    local inst = loaded()
    install(inst, { src(ALPHA, 100), src(BETA, 50), src(GAMMA, 25) },
        { maxAmount = 100, totalAmount = 175 })
    assertEqual(#inst.NS.Aggregator.Build(makeWindow()), 3, "grouped, all three show")

    -- You leave the party. GROUP_ROSTER_UPDATE fires and the live roster rebuilds
    -- as a solo one.
    inst.mocks.setSolo(ALPHA, "Alpha", "PALADIN")
    inst.NS.Roster.Refresh()

    assertEqual(#inst.NS.Aggregator.Build(makeWindow()), 3,
        "the people you just fought beside are still on the meter")
end)

test("A meter reset is what forgets them", function()
    -- The right boundary: a reset is the moment the numbers those GUIDs belonged
    -- to stopped existing. Until then they belong on the meter.
    local inst = loaded()
    install(inst, { src(ALPHA, 100), src(BETA, 50) }, { maxAmount = 100 })
    inst.NS.Aggregator.Build(makeWindow())

    inst.mocks.setSolo(ALPHA, "Alpha", "PALADIN")
    inst.NS.Roster.Forget()

    assertEqual(#inst.NS.Aggregator.Build(makeWindow()), 1,
        "after a reset the roster is only who is actually here")
end)

test("A pet stays attributed after its owner's group is gone", function()
    -- OwnerOf is built from the unit API, and there is no party3pet once you have
    -- left the party. Without the remembered map the pet becomes unattributable
    -- and its row is dropped outright.
    local inst = withPet()
    inst.NS.Roster.GetGroup()          -- learn the pet while the group exists

    inst.mocks.setUnit("playerpet", nil)
    inst.NS.Roster.Refresh()

    assertEqual(inst.NS.Roster.OwnerOf(PET), ALPHA,
        "the link outlives the unit that taught it")
end)

-- ---------------------------------------------------------------------------
-- Deaths is COUNTED, not summed
-- ---------------------------------------------------------------------------

test("The Deaths column counts a GUID's rows rather than reading totalAmount", function()
    -- THE BUG, straight off a live dump. Every other stat hands back one source
    -- row per player carrying that player's total. Deaths hands back one row PER
    -- DEATH — the same sourceGUID once for each time they died, each with its own
    -- deathRecapID — and `totalAmount` is 0 on every one of them, and 0 on the
    -- session. Reading totalAmount answered 0 for everybody, correctly and
    -- uselessly.
    -- red under: setCell reading src.totalAmount for a counted stat.
    local inst = loaded()
    install(inst, {
        src(ALPHA, 0, { recapID = 23 }),
        src(BETA,  0, { recapID = 22 }),
        src(ALPHA, 0, { recapID = 21 }),
        src(ALPHA, 0, { recapID = 20 }),
    }, { statKey = "Deaths", maxAmount = 0, totalAmount = 0 })

    local result = inst.NS.Aggregator.Build(makeWindow{ columns = { "Deaths" } })
    local byGuid = {}
    for _, row in ipairs(result) do byGuid[row.guid] = row end

    assertEqual(byGuid[ALPHA].values.Deaths.total, 3, "three rows, three deaths")
    assertEqual(byGuid[BETA].values.Deaths.total, 1)
end)

test("A counted column scales its bars to the highest count, never to 0", function()
    -- The session reports maxAmount 0 alongside its zero totals, and a bar scaled
    -- to 0 draws full for everybody. The max is computed from the counters this
    -- file produced — plain integers, so comparing them is legal mid-pull.
    local inst = loaded()
    install(inst, {
        src(ALPHA, 0, { recapID = 3 }), src(ALPHA, 0, { recapID = 2 }),
        src(BETA,  0, { recapID = 1 }),
    }, { statKey = "Deaths", maxAmount = 0, totalAmount = 0 })

    local result = inst.NS.Aggregator.Build(makeWindow{ columns = { "Deaths" } })
    for _, row in ipairs(result) do
        assertEqual(row.values.Deaths.maxAmount, 2, "the busiest row sets the scale")
    end
end)

test("The NEWEST death wins the recap id", function()
    -- The API returns deaths newest-first, and the death a player wants to look
    -- at is the one that just happened.
    local inst = loaded()
    install(inst, { src(ALPHA, 0, { recapID = 23 }), src(ALPHA, 0, { recapID = 20 }) },
        { statKey = "Deaths", maxAmount = 0 })

    local row = inst.NS.Aggregator.Build(makeWindow{ columns = { "Deaths" } })[1]
    assertEqual(row.deathRecapID, 23)
end)

test("Counting a death is legal mid-pull, where summing two secrets is not", function()
    -- The counter is ours, not the meter's, so incrementing it is not arithmetic
    -- on a secret. The simulator raises on the illegal form, so reaching the
    -- assertion is the proof.
    local inst = loaded()
    inst.mocks.setRestricted(true)
    inst.mocks.setSecretValues(true)
    install(inst, { src(ALPHA, 0, { recapID = 2 }), src(ALPHA, 0, { recapID = 1 }) },
        { statKey = "Deaths" })

    local ok, err = pcall(inst.NS.Aggregator.Build, makeWindow{ columns = { "Deaths" } })
    assertTrue(ok, "counting inspected a meter value: " .. tostring(err))
end)
