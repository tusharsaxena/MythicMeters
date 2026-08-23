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

local T = _G.MULTIMETERS_TEST

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
        isLocalPlayer    = opts.localPlayer,
        totalAmount      = total,
        amountPerSecond  = opts.rate,
        deathTimeSeconds = opts.deathTime,
        deathRecapID     = opts.recapID,
        sourceDisplayType = opts.displayType,
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

test("A healer with no damage is on the mid-pull grid, from the healing column", function()
    -- THE MISSING ROWS. The identity build took its row list from the SORT
    -- column alone, so a healer who did no damage and a player whose only
    -- contribution was one interrupt were absent for the whole of a pull and
    -- reappeared the instant it ended — rows flickering into existence rather
    -- than a rule. The GUID join has always taken the union of every column.
    -- red under: building rows from the sort column only.
    local inst = loaded()
    inst.mocks.setRestricted(true)
    install(inst, { src(ALPHA, 100, { class = "WARRIOR" }) },
        { statKey = "DamageDone", maxAmount = 100 })
    install(inst, { src(BETA, 500, { class = "PRIEST" }) },
        { statKey = "HealingDone", maxAmount = 500 })

    local result = inst.NS.Aggregator.Build(
        makeWindow{ columns = { "DamageDone", "HealingDone" }, sortColumn = "DamageDone" })

    assertEqual(#result, 2, "the healer is on the grid")
    -- Ranked first, unranked after: the damage row holds its place and the
    -- healer is parked past it rather than interleaved.
    assertEqual(inst.mocks.reveal(result[1].values.DamageDone.total), 100)
    assertEqual(inst.mocks.reveal(result[2].values.HealingDone.total), 500)
    assertNil(result[2].values.DamageDone, "and has no damage cell, because they did none")
end)

test("An ambiguous key gets no invented row, because no column could ever fill it", function()
    -- Two priests: the healing column cannot say which of them a figure belongs
    -- to, so it fills neither — and inventing a row for the pair would put an
    -- always-empty line on the grid.
    local inst = loaded()
    inst.mocks.setRestricted(true)
    install(inst, { src(ALPHA, 100, { class = "WARRIOR" }) },
        { statKey = "DamageDone", maxAmount = 100 })
    install(inst, { src(BETA, 500, { class = "PRIEST" }), src(GAMMA, 300, { class = "PRIEST" }) },
        { statKey = "HealingDone", maxAmount = 500 })

    local result = inst.NS.Aggregator.Build(
        makeWindow{ columns = { "DamageDone", "HealingDone" }, sortColumn = "DamageDone" })

    assertEqual(#result, 1, "only the row the sort column actually ranked")
    assertTrue(result.ambiguous, "and the header is told the grid is short an answer")
end)

test("A correlated cell carries the RATE, or a rate column renders no text", function()
    -- THE EMPTY HEALING COLUMN. The shipped text layout is
    -- `leftSlot = "none"` / `rightSlot = "rate"`, so for a RATE stat — Damage,
    -- Healing — the figure on screen is `amountPerSecond`, not the total.
    -- Correlation carried only the total, so mid-pull every rate column but the
    -- sort one drew its bar from the total and its text from a nil rate: a bar
    -- with no number beside it.
    --
    -- Avoidable and Interrupts hid the bug, because neither is a rate stat and
    -- both fall back to rendering the total (modules/Row.lua's counting-stat
    -- branch). Only the rate columns were blank, which is exactly what was
    -- reported.
    -- red under: `row.values[statKey] = { total = value, maxAmount = ... }`.
    local inst = loaded()
    inst.mocks.setRestricted(true)
    install(inst, { src(ALPHA, 100, { rate = 10 }) },
        { statKey = "DamageDone", maxAmount = 100 })
    install(inst, { src(ALPHA, 500, { rate = 50 }) },
        { statKey = "HealingDone", maxAmount = 500 })

    local result = inst.NS.Aggregator.Build(
        makeWindow{ columns = { "DamageDone", "HealingDone" }, sortColumn = "DamageDone" })

    assertEqual(#result, 1)
    local healing = result[1].values.HealingDone
    assertEqual(inst.mocks.reveal(healing.total), 500)
    assertEqual(inst.mocks.reveal(healing.rate), 50,
        "a rate stat's text slot reads amountPerSecond — without it the cell is silent")
end)

test("A correlated Deaths column keeps the recap id the death view opens on", function()
    -- `deathRecapID` is NeverSecret and rides on the source row. The GUID join
    -- promotes it onto the row so neither the tooltip nor the drill-down has to
    -- know which column it arrived on; correlation dropped it, so mid-pull a
    -- death had no recap to open.
    local inst = loaded()
    inst.mocks.setRestricted(true)
    install(inst, { src(ALPHA, 100, { rate = 10 }) },
        { statKey = "DamageDone", maxAmount = 100 })
    install(inst, { src(ALPHA, 0, { recapID = 4242 }) },
        { statKey = "Deaths", maxAmount = 0 })

    local result = inst.NS.Aggregator.Build(
        makeWindow{ columns = { "DamageDone", "Deaths" }, sortColumn = "DamageDone" })

    assertEqual(result[1].values.Deaths.total, 1, "one source row, one death")
    assertEqual(result[1].deathRecapID, 4242)
end)

test("A pet is a ROW OF ITS OWN while restricted, not a dropped contribution", function()
    -- WHAT THE PET FOLD USED TO DO HERE, and why it stopped. Merging is
    -- addition; addition on two secrets raises; so mid-pull the fold refused and
    -- the pet's numbers were simply dropped, leaving the owner's total quietly
    -- low for the whole fight.
    --
    -- The fold cannot run mid-pull at all now — it needs the owner link, which
    -- needs a GUID, which is secret. So the pet arrives as what Blizzard's own
    -- list says it is: a source, on a row, with its own name and numbers. That is
    -- MORE information than the old behavior, not less, and nothing is summed.
    -- red under: attempting the fold in identity mode.
    local inst = withPet()
    inst.mocks.setRestricted(true)
    install(inst, {
        src(ALPHA, 100, { rate = 10, class = "WARLOCK" }),
        src(PET, 40, { rate = 4, name = "Ghoul", class = "PET" }),
    }, { maxAmount = 100, totalAmount = 140 })

    local result = inst.NS.Aggregator.Build(makeWindow{ mergePets = true })
    assertEqual(#result, 2, "the pet's damage is shown rather than discarded")
    assertEqual(inst.mocks.reveal(result[1].values.DamageDone.total), 100,
        "and the owner's own number is untouched — nothing was added to it")
    assertEqual(inst.mocks.reveal(result[2].values.DamageDone.total), 40)
end)

test("Aggregator adopts a pet's numbers into a column the owner has no cell in", function()
    local inst = withPet()
    -- The pet did damage its owner did not. Taking the pet's numbers wholesale
    -- is not a sum, so it is legal in either state — and it is correct: the
    -- owner DID that damage, through the pet.
    --
    -- Unrestricted, because that is the only state the fold runs in now: it is
    -- reached through the owner link, and the owner link is reached through a
    -- GUID that is secret for the whole of a pull.
    install(inst, { src(PET, 40, { rate = 4, name = "Ghoul" }) },
        { maxAmount = 40, totalAmount = 40 })

    local result = inst.NS.Aggregator.Build(makeWindow{ mergePets = true })
    assertEqual(#result, 1)
    assertEqual(result[1].guid, ALPHA)
    assertEqual(result[1].values.DamageDone.total, 40)
    assertEqual(result[1].values.DamageDone.maxAmount, 40,
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

test("A meter reset drops this module's cache", function()
    -- It held the frozen sort orders, which are retired. The seam stays: it is
    -- the one place "the numbers those rows described no longer exist" is
    -- expressed, and modules/Roster.lua and modules/Format.lua drop through it
    -- too.
    local inst = loaded()
    local cache = inst.NS.State.Cache("Aggregator")
    cache.probe = true

    inst.NS.Aggregator:OnMeterReset()
    assertNil(cache.probe, "the wipe must reach this namespace")
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

test("A dropped source says WHY, once per pass", function()
    -- `rows=0 dropped=N` is the shape every "my window is empty" report takes,
    -- and the counter alone cannot say which of the three causes it was: a GUID
    -- this context may not key on, a source belonging to nobody in the group, or
    -- a pet with no owner link. They need different fixes, so the refusal names
    -- itself.
    -- red under: incrementing pass.dropped and returning.
    local inst = loaded()
    local NS = inst.NS
    NS.State.debug = true
    install(inst, { src("Player-1-0000DEAD", 100) }, { maxAmount = 100 })

    NS.Aggregator.Build(makeWindow())

    local found = NS.DebugLog:FindLine("dropped guid=")
    assertTrue(found ~= nil, "a drop with no explanation costs a whole play session")
    assertTrue(found:find("member=false", 1, true) ~= nil, "got: " .. tostring(found))
end)

test("A secret-GUID source that says it is the local player keeps its row", function()
    -- THE PULL THAT DREW NOTHING. C_DamageMeter hands back a SECRET sourceGUID
    -- while the Combat restriction is active — measured in-game, contradicting
    -- the design's "a GUID is never secret" — so the join has no key, every
    -- source is dropped and the window empties for the whole fight.
    --
    -- `isLocalPlayer` stays plain, and it is the one identity claim that
    -- survives. A source making it is attributed to the roster's own local GUID:
    -- not a guess, the source's own statement about itself.
    -- red under: dropping every source whose GUID cannot be keyed on.
    local inst = loaded()
    install(inst, { src(inst.mocks.secret("Player-1-0000SECR"), 100,
                        { class = "WARLOCK", localPlayer = true }) },
        { maxAmount = 100 })

    local result = inst.NS.Aggregator.Build(makeWindow())

    assertEqual(#result, 1, "the player's own row must survive the restriction")
    assertEqual(result[1].guid, ALPHA, "keyed on the ROSTER's plain guid, never the meter's")
    assertEqual(result[1].name, "Alpha")
    assertEqual(result[1].isLocalPlayer, true)
    assertEqual(result[1].values.DamageDone.total, 100)
end)

test("A secret GUID that does NOT claim to be the local player is still dropped", function()
    -- The claim is the whole warrant. Without it there is nothing to attribute a
    -- source to, and a row invented for an unidentifiable source is a phantom —
    -- the same refusal the pet path already makes (design §5).
    local inst = loaded()
    install(inst, { src(inst.mocks.secret("Player-1-0000SECR"), 100) }, { maxAmount = 100 })

    assertEqual(#inst.NS.Aggregator.Build(makeWindow()), 0)
end)

test("A SECRET isLocalPlayer flag is not truth-tested, and claims nothing", function()
    -- A boolean test on a SECRET boolean raises. If a client ever makes this
    -- field conditional too, the fallback has to read as "no claim" rather than
    -- take the window down mid-pull.
    local inst = loaded()
    install(inst, { src(inst.mocks.secret("Player-1-0000SECR"), 100,
                        { localPlayer = inst.mocks.secret(true) }) },
        { maxAmount = 100 })

    local result
    local ok, err = pcall(function() result = inst.NS.Aggregator.Build(makeWindow()) end)
    assertTrue(ok, "a secret boolean was truth-tested: " .. tostring(err))
    assertEqual(#result, 0)
end)

test("A SECRET source GUID is dropped without raising, and is named as secret", function()
    -- The whole GUID join rests on `sourceGUID` being plain — it is the only
    -- thing in a session legal as a table KEY. If a client ever hands one back
    -- secret, NS.Secrets.IsSafeKey refuses it, every source is dropped and the
    -- window empties for the whole pull. That must stay a NAMED refusal rather
    -- than either a raise or a silent blank grid.
    local inst = loaded()
    local NS = inst.NS
    NS.State.debug = true
    install(inst, { src(inst.mocks.secret(ALPHA), 100) }, { maxAmount = 100 })

    local result
    local ok, err = pcall(function() result = NS.Aggregator.Build(makeWindow()) end)
    assertTrue(ok, "a secret GUID must never raise on the join: " .. tostring(err))
    assertEqual(#result, 0)

    local found = NS.DebugLog:FindLine("dropped guid=")
    assertTrue(found ~= nil and found:find("secret=true", 1, true) ~= nil,
        "got: " .. tostring(found))
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

-- ---------------------------------------------------------------------------
-- Allies nobody owns — pets, guardians, totems
-- ---------------------------------------------------------------------------

test("An ALLY nobody owns gets its own row, under its own name", function()
    -- A warlock's felguard, a shaman's elemental, a death knight's ghoul, every
    -- totem: their owner link needs the unit API to have seen them, which for a
    -- guardian it often never does. They used to vanish off the grid entirely
    -- while Blizzard's own meter showed them.
    --
    -- This is NOT the mislabeling the drop rule protects against. That rule is
    -- about attribution — one player's numbers under another player's name — and
    -- this row makes no claim about an owner at all. It carries the source's own
    -- name and the source's own figures.
    -- red under: dropping every source the roster cannot place.
    local inst = loaded()
    local ALLY = inst.mocks.Enum.DamageMeterSourceDisplayType.Ally
    install(inst, {
        src(ALPHA, 100),
        src(PET, 40, { name = "Gargoyle", displayType = ALLY }),
    }, { maxAmount = 100, totalAmount = 140 })

    local result = inst.NS.Aggregator.Build(makeWindow())
    assertEqual(#result, 2, "the unowned ally was dropped")

    local ally
    for _, row in ipairs(result) do if row.guid == PET then ally = row end end
    assertTrue(ally ~= nil, "no row was keyed on the ally's own GUID")
    assertEqual(ally.name, "Gargoyle", "the row did not carry the source's own name")
    assertEqual(ally.values.DamageDone.total, 40, "the row did not carry its own figures")
    assertTrue(ally.isPet, "the row does not read as a non-member")
    assertEqual(ally.ownerGuid, nil, "an owner was invented for a source that has none")
end)

test("The owner is still not credited for an unowned ally's damage", function()
    -- Giving it a row must not also fold it into somebody. Folding is addition
    -- into an OWNER's row, and the whole reason we are here is that there is no
    -- owner to add into.
    -- red under: crediting the local player for anything the roster could not place.
    local inst = loaded()
    local ALLY = inst.mocks.Enum.DamageMeterSourceDisplayType.Ally
    install(inst, {
        src(ALPHA, 100),
        src(PET, 40, { name = "Gargoyle", displayType = ALLY }),
    }, { maxAmount = 100, totalAmount = 140 })

    local result = inst.NS.Aggregator.Build(makeWindow())
    for _, row in ipairs(result) do
        if row.guid == ALPHA then
            assertEqual(row.values.DamageDone.total, 100, "the owner absorbed the ally's total")
        end
    end
end)

test("An ENEMY nobody owns is still refused", function()
    -- THE ONE THAT KEEPS THIS SAFE. Without the display-type gate the
    -- EnemyDamageTaken column puts every mob in the pull on the grid as a row.
    -- red under: keeping any source the roster cannot place.
    local inst = loaded()
    local ENEMY = inst.mocks.Enum.DamageMeterSourceDisplayType.Enemy
    install(inst, {
        src(ALPHA, 100),
        src("Creature-0-1234", 80, { name = "Some Boss", displayType = ENEMY }),
    }, { maxAmount = 100, totalAmount = 180 })

    local result = inst.NS.Aggregator.Build(makeWindow())
    assertEqual(#result, 1, "an enemy was promoted to a grid row")
    assertEqual(result[1].guid, ALPHA)
end)

test("A DELVE COMPANION, filed under None with a real class, gets a row", function()
    -- THE BUG THIS EXISTS FOR, measured on a live client. Valeera Sanguinar
    -- fought a nine-and-a-half minute delve, did 24.98M of the run's 61.31M, and
    -- never reached the grid — while the header total counted her, because a
    -- session total is the client's own sum and never consults the row gate. The
    -- drop log named it exactly:
    --
    --     display=0 class=ROGUE/false member=false owner=nil lookup=resolved
    --
    -- `None`, not `Ally`. The gate was written on the belief that anything of
    -- ours carries the Ally flag, and a delve companion does not.
    -- red under: `kind ~= Ally` as the only admission test.
    local inst = loaded()
    install(inst, {
        src(ALPHA, 100),
        src("Creature-0-3748-2933-99554-248567-0000075FD2", 80,
            { name = "Valeera Sanguinar", class = "ROGUE",
              displayType = inst.mocks.Enum.DamageMeterSourceDisplayType.None }),
    }, { maxAmount = 100, totalAmount = 180 })

    local result = inst.NS.Aggregator.Build(makeWindow())
    assertEqual(#result, 2, "the delve companion was dropped")

    local companion
    for _, row in ipairs(result) do
        if row.name == "Valeera Sanguinar" then companion = row end
    end
    assertTrue(companion ~= nil, "no row carries the companion's own name")
    assertEqual(companion.values.DamageDone.total, 80, "the row lost its own figures")
    assertEqual(companion.classFilename, "ROGUE", "the class the admission turned on is gone")
    assertEqual(companion.ownerGuid, nil, "an owner was invented for a source that has none")
end)

test("A None source with a class the CLIENT does not know is still refused", function()
    -- The narrowness is the whole safety argument. Admitting `None` outright
    -- would put a trash pack on the grid the moment one mob is flagged that way;
    -- admitting it only with a class RAID_CLASS_COLORS recognizes means a mob
    -- would have to carry a genuine class filename to slip through.
    --
    -- That table is the oracle rather than a list of our own because
    -- modules/Row.lua already looks a row up in it to color the bar and pick the
    -- class icon — so anything this refuses is something that could only draw as
    -- an uncolored, iconless row anyway.
    -- red under: admitting any non-nil classFilename.
    local inst = loaded()
    install(inst, {
        src(ALPHA, 100),
        src("Creature-0-1234", 90, { name = "Cave Lurker", class = "BEAST",
            displayType = inst.mocks.Enum.DamageMeterSourceDisplayType.None }),
    }, { maxAmount = 100, totalAmount = 190 })

    local result = inst.NS.Aggregator.Build(makeWindow())
    assertEqual(#result, 1, "a mob with an unrecognized class reached the grid")
    assertEqual(result[1].guid, ALPHA)
end)

test("An ENEMY with a real player class is refused, class or no class", function()
    -- The class test WIDENS the None branch and must not widen the Enemy one. A
    -- humanoid mob carrying a genuine class filename is exactly the case that
    -- would make an over-eager reading of this change dangerous.
    -- red under: testing the class before the display type.
    local inst = loaded()
    install(inst, {
        src(ALPHA, 100),
        src("Creature-0-5678", 90, { name = "Rogue Trainer", class = "ROGUE",
            displayType = inst.mocks.Enum.DamageMeterSourceDisplayType.Enemy }),
    }, { maxAmount = 100, totalAmount = 190 })

    local result = inst.NS.Aggregator.Build(makeWindow())
    assertEqual(#result, 1, "an enemy was promoted to a grid row on the strength of its class")
    assertEqual(result[1].guid, ALPHA)
end)

test("A source with NO display type is refused, not assumed friendly", function()
    -- The gate asks for Ally explicitly rather than for "not Enemy". Read as
    -- "not an enemy", a source with an absent or None display type becomes a
    -- row and the failure mode is the whole trash pack on the grid. Read as
    -- "not an ally" it stays dropped, and the failure mode is this feature doing
    -- nothing — visible, and far cheaper to diagnose.
    -- red under: `if isEnemySource(src) then drop end`.
    local inst = loaded()
    install(inst, {
        src(ALPHA, 100),
        src("Player-2-0000DEAD", 90, { name = "PassingStranger" }),
    }, { maxAmount = 100, totalAmount = 190 })

    local result = inst.NS.Aggregator.Build(makeWindow())
    assertEqual(#result, 1, "a source of unknown allegiance was given a row")
    assertEqual(result[1].guid, ALPHA)
end)

-- ---------------------------------------------------------------------------
-- row.deaths — every death, not just the newest (issue #1)
-- ---------------------------------------------------------------------------
--
-- The Deaths column has always known every death individually — the provider
-- hands back one source row PER DEATH, each carrying its own `deathRecapID` —
-- and this file threw all but the first away. `row.deathRecapID` stays exactly
-- as it is: it is the newest death and four call sites read it. The array is
-- strictly additive, and it is what the death drill-down lists.

test("Every death lands in row.deaths, not just the newest", function()
    -- red under: the `if cell.deathRecapID == nil then` first-wins capture being
    -- the only place a recap id is kept.
    local inst = loaded()
    install(inst, {
        src(ALPHA, 0, { recapID = 29, deathTime = 1356 }),
        src(ALPHA, 0, { recapID = 28, deathTime = 673  }),
        src(ALPHA, 0, { recapID = 27, deathTime = 296  }),
    }, { statKey = "Deaths", maxAmount = 0 })

    local row = inst.NS.Aggregator.Build(makeWindow{ columns = { "Deaths" } })[1]
    assertEqual(row.values.Deaths.total, 3, "the count itself must not change")
    assertEqual(#row.deaths, 3, "deaths were dropped")
    assertEqual(row.deaths[1], 29, "newest first, as the API returns them")
    assertEqual(row.deaths[3], 27)
end)

test("row.deathRecapID still names the NEWEST death", function()
    -- Four call sites read it — the click, the tooltip hint and two promotions.
    -- The array is additive; repurposing the scalar would break all of them.
    -- red under: replacing the scalar with the array.
    local inst = loaded()
    install(inst, {
        src(ALPHA, 0, { recapID = 29 }),
        src(ALPHA, 0, { recapID = 27 }),
    }, { statKey = "Deaths", maxAmount = 0 })

    local row = inst.NS.Aggregator.Build(makeWindow{ columns = { "Deaths" } })[1]
    assertEqual(row.deathRecapID, 29)
end)

test("A row with no deaths carries no deaths array at all", function()
    -- THE ROW MUST NOT WIDEN. newRow runs for every row in every window on every
    -- pass; a tenth field costs an allocation per row per pass for windows with
    -- no Deaths column. The array is created lazily, inside the counted branch.
    -- red under: `deaths = {}` in the newRow literal.
    local inst = loaded()
    install(inst, { src(ALPHA, 500) }, { maxAmount = 500 })
    local row = inst.NS.Aggregator.Build(makeWindow{ columns = { "DamageDone" } })[1]
    assertNil(row.deaths)
end)

test("The count and the deaths array can never disagree", function()
    -- They are two independent tallies of one fact, in two separate builds. A
    -- filter added to one and not the other makes the cell say 3 and the
    -- drill-down list 2, which is the disagreement the whole feature must not
    -- have.
    local inst = loaded()
    install(inst, {
        src(ALPHA, 0, { recapID = 29 }), src(ALPHA, 0, { recapID = 28 }),
        src(BETA,  0, { recapID = 27 }),
    }, { statKey = "Deaths", maxAmount = 0 })

    for _, row in ipairs(inst.NS.Aggregator.Build(makeWindow{ columns = { "Deaths" } })) do
        assertEqual(#row.deaths, row.values.Deaths.total,
            "the count and the list describe the same deaths")
    end
end)

test("A correlated Deaths column keeps every death too", function()
    -- Mid-pull there is no GUID, so the identity build tallies deaths through a
    -- parallel map instead. It is a SECOND capture point, and a change made to
    -- one build and not the other is invisible until somebody drills in during
    -- a pull.
    -- red under: accumulating the array only in setCell.
    local inst = loaded()
    install(inst, { src(ALPHA, 500, { class = "PALADIN", specIconID = 1 }) },
        { statKey = "DamageDone", maxAmount = 500 })
    install(inst, {
        src(ALPHA, 0, { class = "PALADIN", specIconID = 1, recapID = 29 }),
        src(ALPHA, 0, { class = "PALADIN", specIconID = 1, recapID = 27 }),
    }, { statKey = "Deaths", maxAmount = 0 })
    inst.mocks.setRestricted(true)

    local rows = inst.NS.Aggregator.Build(
        makeWindow{ columns = { "DamageDone", "Deaths" }, sortColumn = "DamageDone" })
    assertEqual(rows[1].values.Deaths.total, 2)
    assertEqual(#rows[1].deaths, 2, "the identity build dropped a death")
    assertEqual(rows[1].deaths[1], 29, "newest first here too")
end)

test("A collided identity key gets no deaths array, as it gets no cell", function()
    -- Two players of one class and spec cannot be told apart mid-pull, and this
    -- file's whole warrant for correlating is that it REFUSES rather than
    -- guesses. A death list attached outside that refusal would put one
    -- player's deaths under the other player's name.
    -- red under: assigning row.deaths outside the collision guard.
    local inst = loaded()
    install(inst, {
        src(ALPHA, 500, { class = "PALADIN", specIconID = 1 }),
        src(BETA,  400, { class = "PALADIN", specIconID = 1 }),
    }, { statKey = "DamageDone", maxAmount = 500 })
    install(inst, {
        src(ALPHA, 0, { class = "PALADIN", specIconID = 1, recapID = 29 }),
    }, { statKey = "Deaths", maxAmount = 0 })
    inst.mocks.setRestricted(true)

    local rows = inst.NS.Aggregator.Build(
        makeWindow{ columns = { "DamageDone", "Deaths" }, sortColumn = "DamageDone" })
    for _, row in ipairs(rows) do
        assertNil(row.values.Deaths, "the fixture is only meaningful if the key collided")
        assertNil(row.deaths, "a collided row was given somebody's death list")
    end
end)

test("Test mode produces a player with several deaths to drill into", function()
    -- The preview is how the drill-down is looked at without dying repeatedly in
    -- a dungeon. One death per member exercises the list at length 1 only, which
    -- is the length at which every ordering bug hides.
    -- red under: TestColumn emitting one Deaths source per member.
    local inst = T.load()
    inst.NS.State.testMode = true
    local rows = inst.NS.Aggregator.Build(makeWindow{ columns = { "Deaths" } })

    local most = 0
    for _, row in ipairs(rows) do
        local n = row.deaths and #row.deaths or 0
        if n > most then most = n end
        if row.deaths then
            assertEqual(n, row.values.Deaths.total, "preview count and list disagree")
        end
    end
    assertTrue(most > 1, "no preview player has more than one death")
end)

test("A death the client gave no recap id still occupies a slot in the list", function()
    -- FOUND BY REVIEW, and it is the invariant this whole feature rests on.
    -- `deaths[#deaths + 1] = src.deathRecapID` is a NO-OP when the id is nil, so
    -- a death with no id silently shortened the array while the count went up:
    -- the cell said 3 and the drill-down listed 2. A death with no id cannot be
    -- opened, but it certainly happened.
    -- red under: appending the id without a placeholder.
    local inst = loaded()
    install(inst, {
        src(ALPHA, 0, { recapID = 29 }),
        src(ALPHA, 0),
        src(ALPHA, 0, { recapID = 27 }),
    }, { statKey = "Deaths", maxAmount = 0 })

    local row = inst.NS.Aggregator.Build(makeWindow{ columns = { "Deaths" } })[1]
    assertEqual(row.values.Deaths.total, 3)
    assertEqual(#row.deaths, 3, "the count and the list disagree")
    assertEqual(row.deaths[1], 29)
    assertEqual(row.deaths[2], false, "an unopenable death is false, not missing")
    assertEqual(row.deaths[3], 27)
end)

test("The identity build keeps that slot too", function()
    -- Two builds, one shape. The GUID build being fixed and the identity build
    -- not would make the lists differ in and out of combat.
    local inst = loaded()
    install(inst, { src(ALPHA, 500, { class = "PALADIN", specIconID = 1 }) },
        { statKey = "DamageDone", maxAmount = 500 })
    install(inst, {
        src(ALPHA, 0, { class = "PALADIN", specIconID = 1, recapID = 29 }),
        src(ALPHA, 0, { class = "PALADIN", specIconID = 1 }),
    }, { statKey = "Deaths", maxAmount = 0 })
    inst.mocks.setRestricted(true)

    local rows = inst.NS.Aggregator.Build(
        makeWindow{ columns = { "DamageDone", "Deaths" }, sortColumn = "DamageDone" })
    assertEqual(rows[1].values.Deaths.total, 2)
    assertEqual(#rows[1].deaths, 2)
    assertEqual(rows[1].deaths[2], false)
end)

-- ---------------------------------------------------------------------------
-- The feign filter, where it actually bites
-- ---------------------------------------------------------------------------
--
-- modules/Feign.lua owns the set; this is the only place it changes what a
-- player sees. The module having tests of its own proves nothing about whether
-- the aggregator ever asks it — and for one commit, it did not.

test("A feigned player's death is not counted", function()
    -- red under: the filter not being called at all, which is how it shipped
    -- once. Verified by mutation: turning `feigned` into a constant false must
    -- make this red.
    local inst = loaded()
    install(inst, {
        src(ALPHA, 0, { recapID = 29 }),
        src(BETA,  0, { recapID = 28 }),
    }, { statKey = "Deaths", maxAmount = 0 })
    inst.NS.Feign.Note(ALPHA)

    local rows = inst.NS.Aggregator.Build(makeWindow{ columns = { "Deaths" } })
    assertEqual(#rows, 1, "the feigner still has a row")
    assertEqual(rows[1].guid, BETA, "and the wrong player was dropped")
end)

test("A feigned player's death is not LISTED either", function()
    -- Two tallies of one fact. A filter applied to the count and not to the
    -- array makes the cell say 1 and the drill-down list 2.
    local inst = loaded()
    install(inst, {
        src(ALPHA, 0, { recapID = 29 }),
        src(ALPHA, 0, { recapID = 27 }),
    }, { statKey = "Deaths", maxAmount = 0 })
    inst.NS.Feign.Note(ALPHA)

    assertEqual(#inst.NS.Aggregator.Build(makeWindow{ columns = { "Deaths" } }), 0,
        "the feigner's row survived")
end)

test("A real death after a feign is counted, and the feigns stay hidden", function()
    -- BOTH HALVES, because the fix for one broke the other twice over. The
    -- hunter feigned twice and then really died: the count must read 1, not 3
    -- and not 0.
    local inst = loaded()
    install(inst, {
        src(ALPHA, 0, { recapID = 11 }),
        src(ALPHA, 0, { recapID = 10 }),
    }, { statKey = "Deaths", maxAmount = 0 })
    inst.NS.Feign.Note(ALPHA)
    inst.mocks.setUnitFeignDeath("player", true)
    assertEqual(#inst.NS.Aggregator.Build(makeWindow{ columns = { "Deaths" } }), 0)

    -- They really die, and the client reports the new death alongside the old.
    install(inst, {
        src(ALPHA, 0, { recapID = 20 }),
        src(ALPHA, 0, { recapID = 11 }),
        src(ALPHA, 0, { recapID = 10 }),
    }, { statKey = "Deaths", maxAmount = 0 })
    inst.mocks.setUnitHealth("player", 0)

    local rows = inst.NS.Aggregator.Build(makeWindow{ columns = { "Deaths" } })
    assertEqual(#rows, 1)
    assertEqual(rows[1].values.Deaths.total, 1,
        "the two feigns came back the moment the real death cleared the entry")
    assertEqual(#rows[1].deaths, 1)
    assertEqual(rows[1].deaths[1], 20, "and it must be the REAL death that is listed")
end)

test("A death after the hunter stands back up is counted", function()
    -- The other direction. Without a way to notice the feign ended, this death
    -- was filtered out for the rest of the run.
    local inst = loaded()
    inst.NS.Feign.Note(ALPHA)
    -- The client has to have SEEN the feign before "not feigning any more" means
    -- anything — otherwise the entry would clear in the instant between the cast
    -- succeeding and the aura appearing.
    inst.mocks.setUnitFeignDeath("player", true)
    inst.mocks.setUnitHealth("player", 500)
    inst.NS.Feign.Prune()

    inst.mocks.setUnitFeignDeath("player", false)
    install(inst, { src(ALPHA, 0, { recapID = 40 }) },
        { statKey = "Deaths", maxAmount = 0 })
    local rows = inst.NS.Aggregator.Build(makeWindow{ columns = { "Deaths" } })
    assertEqual(#rows, 1, "a real death was eaten by a stale feign")
end)

test("The feign filter touches no column but Deaths", function()
    -- It is gated on `isCount`, and a feigning hunter is still doing damage.
    local inst = loaded()
    install(inst, { src(ALPHA, 500) }, { maxAmount = 500 })
    inst.NS.Feign.Note(ALPHA)
    assertEqual(#inst.NS.Aggregator.Build(makeWindow{ columns = { "DamageDone" } }), 1,
        "a feigning player stopped appearing on the damage column")
end)

test("The feign filter cannot run mid-pull, and does not pretend to", function()
    -- STRUCTURAL, not a defect. It joins a plain GUID against sourceGUID, and
    -- sourceGUID is secret for the whole of a pull — which is the entire reason
    -- there is a second, GUID-free build. Pinned as behaviour so nobody "fixes"
    -- it by keying on something secret.
    local inst = loaded()
    install(inst, { src(ALPHA, 500, { class = "PALADIN", specIconID = 1 }) },
        { statKey = "DamageDone", maxAmount = 500 })
    install(inst, { src(ALPHA, 0, { class = "PALADIN", specIconID = 1, recapID = 29 }) },
        { statKey = "Deaths", maxAmount = 0 })
    inst.NS.Feign.Note(ALPHA)
    inst.mocks.setRestricted(true)

    local rows = inst.NS.Aggregator.Build(
        makeWindow{ columns = { "DamageDone", "Deaths" }, sortColumn = "DamageDone" })
    assertEqual(rows[1].values.Deaths.total, 1,
        "if this ever reads 0, the restricted build found a plain key and the "
        .. "limitation can be lifted from docs/ARCHITECTURE.md")
end)
