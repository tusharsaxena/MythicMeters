-- tests/test_diagnostics.lua — core/Diagnostics.lua, the `/mm debug diag` report.
--
-- The report exists because three display bugs in a row were caused by assuming
-- something about the running client and never checking it. So the property that
-- matters most here is that the report itself cannot become another one: it must
-- run to completion on a hostile client, print rather than raise, and never be
-- the reason a player cannot describe what they are seeing.

local T = _G.MULTIMETERS_TEST

local test        = T.test
local assertEqual = T.assertEqual
local assertTrue  = T.assertTrue
local assertFalse = T.assertFalse

--- Run the report and hand back everything it printed, as one string.
---
--- BOTH SINKS are drained, because the report has two and picks between them at
--- run time: the debug console when one is open, and chat when it is not. A
--- helper that read only chat reported "the report printed nothing" for a report
--- that printed forty lines into the console — so the content cases below would
--- all have to be rewritten every time the routing changed. Draining both keeps
--- every content assertion about CONTENT, and leaves the routing itself to the
--- two cases that actually test it.
local function report(inst)
    local D      = inst.NS.DebugLog
    local buffer = D and D.buffer
    local chatN  = #inst.mocks.__chat
    local bufN   = buffer and #buffer or 0

    inst.NS.Diagnostics.Report()

    local lines = {}
    if buffer then
        for i = bufN + 1, #buffer do lines[#lines + 1] = buffer[i] end
    end
    for i = chatN + 1, #inst.mocks.__chat do lines[#lines + 1] = inst.mocks.__chat[i] end
    return table.concat(lines, "\n"), lines
end

test("Diagnostics: the report is published and reachable", function()
    local inst = T.load{ enable = true }
    assertEqual(type(inst.NS.Diagnostics), "table")
    assertEqual(type(inst.NS.Diagnostics.Report), "function")
end)

test("Diagnostics: `/mm debug diag` reaches it without the debug log", function()
    -- It is what a player is asked to run when something looks wrong, and
    -- requiring them to enable a console first is one more step between a bug and
    -- its report.
    -- red under: an early `if not NS.DebugLog then return end` in doDebug.
    local inst = T.load{ enable = true }
    inst.NS.DebugLog = nil

    local n = #inst.mocks.__chat
    inst.NS.Slash:OnSlash("debug diag")
    assertTrue(#inst.mocks.__chat > n, "the report printed nothing")
end)

test("Diagnostics: every section appears", function()
    local inst = T.load{ enable = true }
    local text = report(inst)
    for _, section in ipairs({ "atlases", "number formatting", "visibility",
                               "header", "name column", "cells" }) do
        assertTrue(text:find(section, 1, true) ~= nil, "missing section: " .. section)
    end
end)

test("Diagnostics: it reports what the CLIENT has, not what the addon wants", function()
    -- The whole point. Importing the addon's own candidate list would report on
    -- our opinion instead of on the client's, and reporting on our own opinion is
    -- how the three bugs happened.
    local inst = T.load{ enable = true }
    inst.mocks.setAtlases({ ["common-icon-settings"] = true })

    local text = report(inst)
    assertTrue(text:find("common%-icon%-settings%s+yes") ~= nil,
        "an atlas the client HAS must read yes")
    assertTrue(text:find("common%-icon%-lock%s+no") ~= nil,
        "and one it lacks must read no")
end)

test("Diagnostics: a number that misses the ladder is FLAGGED, not just printed", function()
    -- A column of numbers with no expectation beside them is a column somebody
    -- has to check by eye, which is the step that keeps going wrong.
    local inst = T.load{ enable = true }
    local text = report(inst)
    assertTrue(text:find("47500", 1, true) ~= nil, "the probe values must appear")
    assertTrue(text:find("47.5K", 1, true) ~= nil, "and what each one should render as")
end)

test("Diagnostics: one broken section cannot take the report down", function()
    -- A diagnostic that dies halfway is worse than none, because it looks like
    -- the thing it was diagnosing.
    -- red under: dropping the pcall around each section.
    local inst = T.load{ enable = true }
    inst.NS.WindowManager.All = function() error("boom", 2) end

    local text, lines = report(inst)
    assertTrue(#lines > 4, "the report stopped at the broken section")
    assertTrue(text:find("section failed", 1, true) ~= nil,
        "and it must SAY which section broke rather than going quiet")
    assertTrue(text:find("atlases", 1, true) ~= nil,
        "sections before the break still ran")
end)

test("Diagnostics: it never renders a meter value", function()
    -- It reports on widgets and APIs, never on numbers. A cell's stored figure is
    -- described rather than read: rendering it would be legal and INSPECTING it to
    -- describe it would not (rule R1). The simulator raises on an inspection, so
    -- reaching the end is the proof.
    local inst = T.load{ enable = true }
    inst.mocks.setRestricted(true)
    inst.mocks.setSecretValues(true)

    local ok, err = pcall(inst.NS.Diagnostics.Report)
    assertTrue(ok, "the report inspected a secret: " .. tostring(err))
end)

test("Diagnostics: with no window it says so rather than erroring", function()
    local inst = T.load{}
    local text = report(inst)
    assertFalse(text == "", "the report must still print")
end)

-- ---------------------------------------------------------------------------
-- Where the report goes
-- ---------------------------------------------------------------------------

test("Diagnostics: the report lands in the debug console, not in chat", function()
    -- Forty lines a player has to hand back verbatim belong in the window that
    -- has a buffer, scrollback and a copy button. Chat interleaves them with
    -- combat spam, so a report pasted out of it arrives shuffled.
    -- red under: `out` printing straight to NS.Print.
    local inst = T.load{ enable = true }
    local D = inst.NS.DebugLog

    local chatN, bufN = #inst.mocks.__chat, #D.buffer
    inst.NS.Diagnostics.Report()

    assertTrue(#D.buffer > bufN + 10, "the report did not reach the console buffer")
    assertEqual(#inst.mocks.__chat, chatN, "the report also spammed chat")
end)

test("Diagnostics: the console is OPENED, so the report is not written out of sight", function()
    -- Writing into a closed window would be the same failure as writing into a
    -- no-op: the player sees nothing and reports that the command does nothing.
    -- red under: Add without Show.
    local inst = T.load{ enable = true }
    inst.NS.DebugLog:Hide()
    assertFalse(inst.NS.DebugLog:IsShown(), "the console was already open")

    inst.NS.Diagnostics.Report()
    assertTrue(inst.NS.DebugLog:IsShown(), "the report never opened the console")
end)

test("Diagnostics: with no console the report falls back to chat", function()
    -- THE ONE THAT MATTERS. With LibKa0s absent, NS.DebugLog is a stub whose Add
    -- is a NO-OP and whose IsShown always answers false — so routing there
    -- unconditionally makes the one command a player runs when something is
    -- wrong print absolutely nothing, on exactly the broken install where they
    -- need it most.
    -- red under: `emit` set without checking IsShown.
    local inst = T.load{ enable = true }
    local swallowed = 0
    inst.NS.DebugLog = {
        buffer    = {},
        Add       = function() swallowed = swallowed + 1 end,
        Show      = function() end,
        IsShown   = function() return false end,
    }

    local n = #inst.mocks.__chat
    inst.NS.Diagnostics.Report()

    assertTrue(#inst.mocks.__chat > n + 10, "the report vanished into a no-op sink")
    assertEqual(swallowed, 0, "the report was written to a console that never opened")
end)

test("Diagnostics: a font size read back as 10.000000953674 is not called a failure", function()
    -- The client stores a font size as a float and reads 10 back as
    -- 10.000000953674, so an equality test reported "SetFont did not take" for a
    -- SetFont that took perfectly. A diagnostic that confidently names the wrong
    -- cause is worse than no diagnostic — it sends the fix to the wrong place.
    -- red under: `sample.setSize ~= sample.askedSize`.
    local inst = T.load{ enable = true }
    inst.NS.Tooltip.__fontProbe = {
        index = 4, line = inst.mocks.__stubFrame("FontString"),
        askedPath = "X.ttf", askedSize = 10,               askedFlags = "OUTLINE",
        setPath   = "X.ttf", setSize   = 10.000000953674,  setFlags   = "OUTLINE",
        showPath  = "X.ttf", showSize  = 10.000000953674,  showFlags  = "OUTLINE",
    }

    local text = report(inst)
    assertFalse(text:find("SetFont did not take") ~= nil,
        "a float-precision difference was reported as a refused SetFont")
    assertTrue(text:find("stuck through layout") ~= nil,
        "the font verdict is missing entirely")
end)

test("Diagnostics: a font the layout reverted is named as such", function()
    -- The other half of the same verdict, and the one the live client hit: the
    -- SetFont takes, and the show path re-fonts the line at its own size with no
    -- flags. That needs the opposite fix to a refused SetFont, so the report has
    -- to tell them apart.
    -- red under: collapsing the two branches into one message.
    local inst = T.load{ enable = true }
    inst.NS.Tooltip.__fontProbe = {
        index = 13, line = inst.mocks.__stubFrame("FontString"),
        askedPath = "X.ttf", askedSize = 10,              askedFlags = "OUTLINE",
        setPath   = "X.ttf", setSize   = 10.000000953674, setFlags   = "OUTLINE",
        showPath  = "X.ttf", showSize  = 10.999999046326, showFlags  = "",
    }

    local text = report(inst)
    assertTrue(text:find("the layout reverted it") ~= nil,
        "a reverted font was not reported as a revert")
end)

-- ---------------------------------------------------------------------------
-- The targets cross-reference verdict
-- ---------------------------------------------------------------------------

test("Diagnostics: a walk that never reached a spell does not blame the build", function()
    -- THE BUG THIS EXISTS FOR, and it is a diagnostic telling a lie rather than
    -- a display drawing one. In a pull an enemy's GUID and its creature ID are
    -- both secret, so `GetSourceDetail` is never called, so no spell is ever
    -- seen — and the verdict read that silence as "this build does not carry the
    -- caster". The same client answered with the caster name immediately once
    -- combat ended. A report that confidently names the wrong cause sends the
    -- fix to the wrong place, which is the one thing this file must not do.
    -- red under: `if withDetails == 0 then` as the only branch.
    local inst = T.load{ enable = true }
    local mocks = inst.mocks

    -- One enemy in the column, reachable by neither identifier — which is every
    -- enemy for the whole of a pull.
    mocks.setSession(1, mocks.Enum.DamageMeterType.EnemyDamageTaken, {
        combatSources = { {
            sourceGUID       = mocks.secret("Creature-0-0000-0-0-0001"),
            guid             = mocks.secret("Creature-0-0000-0-0-0001"),
            sourceCreatureID = mocks.secret(6001),
            creatureID       = mocks.secret(6001),
            name             = mocks.secret("Cleave Training Dummy"),
            totalAmount      = 1,
            sourceDisplayType = mocks.Enum.DamageMeterSourceDisplayType.Enemy,
        } },
        maxAmount = 1, totalAmount = 1, durationSeconds = 60,
    })
    inst.NS.Database.GetWindows()[1].data.sessionType = 1
    mocks.setRestricted(true)

    local text = report(inst)
    assertTrue(text:find("enemy column: 1 sources", 1, true) ~= nil,
        "the fixture never reached the targets section")
    assertFalse(text:find("this build does not", 1, true) ~= nil,
        "the report blamed the client for a field the restriction merely hid")
    assertTrue(text:find("re%-run out of combat") ~= nil,
        "and it must say what to do instead of stopping at the accusation")
end)

test("Diagnostics: the number probes expect what the SHIPPING ladder renders", function()
    -- These wants were written against a three-significant-figure ladder that
    -- modules/Format.lua has since retired on purpose, and they outlived it — so
    -- a live report flagged three correct figures as wrong. A column of
    -- expectations nobody maintains is worse than no column, because it trains
    -- the reader to ignore the marks that matter.
    -- red under: want = "4.75K" / "475.0K" / "1.41M".
    local inst = T.load{ enable = true }
    local text = report(inst)

    local section = text:match("%-%- number formatting %-%-(.-)\n[^\n]*%-%- visibility")
    assertTrue(section ~= nil, "the number formatting section is missing")
    assertFalse(section:find("<%-%- expected") ~= nil,
        "the shipping ladder's own output is flagged as unexpected:\n" .. section)
end)


--- An enemy column holding one source with the given display type.
local function enemyColumn(inst, displayType)
    local mocks = inst.mocks
    mocks.setSession(1, mocks.Enum.DamageMeterType.EnemyDamageTaken, {
        combatSources = { {
            sourceGUID        = "Creature-0-0000-0-0-0001",
            guid              = "Creature-0-0000-0-0-0001",
            sourceCreatureID  = 6001,
            creatureID        = 6001,
            name              = "Cleave Training Dummy",
            totalAmount       = 1,
            sourceDisplayType = displayType,
        } },
        maxAmount = 1, totalAmount = 1, durationSeconds = 60,
    })
    inst.NS.Database.GetWindows()[1].data.sessionType = 1
end

test("Diagnostics: the enemy column's display types are printed, not assumed", function()
    -- THE BELT ON A LOOSENED GATE. modules/Aggregator.lua now admits a source
    -- flagged None when it carries a real player class, which is safe exactly as
    -- long as enemies keep reporting Enemy — an assumption about a live client,
    -- not a fact about the code. So the client is asked and the answer printed.
    -- red under: no display-type line in the targets section.
    local inst = T.load{ enable = true }
    enemyColumn(inst, inst.mocks.Enum.DamageMeterSourceDisplayType.Enemy)

    local text = report(inst)
    assertTrue(text:find("display types: 2 x1", 1, true) ~= nil,
        "the enemy column's display types are missing from the report")
end)

test("Diagnostics: an enemy flagged None is called out, because it defeats the class gate", function()
    -- The one reading that turns the aggregator's new branch from narrow into
    -- dangerous. If a mob is ever filed under None, the class filename is the
    -- only thing between a trash pack and the grid — and that is a sentence a
    -- player should read in a report rather than infer from a wrong row.
    -- red under: printing the tally without checking it.
    local inst = T.load{ enable = true }
    enemyColumn(inst, inst.mocks.Enum.DamageMeterSourceDisplayType.None)

    local text = report(inst)
    assertTrue(text:find("flagged None", 1, true) ~= nil,
        "a None-flagged enemy passed without comment")
end)

test("Diagnostics: a display-type check that could not run says so", function()
    -- `sourceDisplayType` is secret for the whole of a pull — measured on a live
    -- client, which printed `display types: <secret> x5` across a five-enemy
    -- column. With every entry unreadable the None check finds nothing and
    -- prints nothing, which reads exactly like "checked, all clear". A belt that
    -- silently did not run is worse than no belt.
    -- red under: printing the tally and falling through to the None check.
    local inst = T.load{ enable = true }
    enemyColumn(inst, inst.mocks.secret(2))
    inst.mocks.setRestricted(true)

    local text = report(inst)
    assertTrue(text:find("every display type is secret", 1, true) ~= nil,
        "a check that could not run passed itself off as a clean one")
end)

-- ---------------------------------------------------------------------------
-- The provider-order probe (issue #14)
-- ---------------------------------------------------------------------------
--
-- modules/Provider.lua rests on ONE unverified assumption: that `combatSources`
-- arrives already ranked by the stat that was asked for, descending. The whole
-- mid-pull grid is built on it — identity mode takes row identity from POSITION,
-- so if the order is wrong the grid is wrong, not merely the sort. Nothing in
-- Blizzard's documentation says it, and it has never been measured.
--
-- It is measurable HERE, out of combat, where the amounts are plain and `<` is
-- legal: walk each column in the order the API returned it and ask whether the
-- totals descend. The check cannot run mid-pull and says so rather than looking
-- calm, exactly like the display-type belt above it.

test("Diagnostics: the provider-order probe reports a RANKED column as ranked", function()
    local inst = T.load{ enable = true }
    -- The shipped default is Overall; the fixture seeds Current, and the probe
    -- reads whichever session the first window is pointed at.
    inst.NS.Database.GetWindows()[1].data.sessionType = 1
    inst.mocks.setSession(1, "*", {
        combatSources = {
            { sourceGUID = "Player-1-0000000A", name = "Alpha", totalAmount = 300 },
            { sourceGUID = "Player-1-0000000B", name = "Beta",  totalAmount = 200 },
            { sourceGUID = "Player-1-0000000C", name = "Gamma", totalAmount = 100 },
        },
        maxAmount = 300, totalAmount = 600,
    })

    local text = report(inst)
    assertTrue(text:find("provider order", 1, true) ~= nil, "the section must appear")
    assertTrue(text:find("ranked", 1, true) ~= nil,
        "a descending column is the assumption holding, and the probe must say so")
end)

test("Diagnostics: the probe NAMES the position where the order breaks", function()
    -- The decision this probe exists to print. An out-of-order column disproves
    -- the assumption outright, and the index is what turns "it is wrong" into
    -- something the fix can be written against.
    -- red under: reporting a bare yes/no with no index.
    local inst = T.load{ enable = true }
    -- The shipped default is Overall; the fixture seeds Current, and the probe
    -- reads whichever session the first window is pointed at.
    inst.NS.Database.GetWindows()[1].data.sessionType = 1
    inst.mocks.setSession(1, "*", {
        combatSources = {
            { sourceGUID = "Player-1-0000000A", name = "Alpha", totalAmount = 100 },
            { sourceGUID = "Player-1-0000000B", name = "Beta",  totalAmount = 900 },
        },
        maxAmount = 900, totalAmount = 1000,
    })

    local text = report(inst)
    assertTrue(text:find("NOT ranked", 1, true) ~= nil,
        "an ascending column disproves the assumption and must say so loudly")
    assertTrue(text:find("index 2", 1, true) ~= nil, "and name where it broke")
end)

test("Diagnostics: the probe REFUSES mid-pull rather than reporting a false all-clear", function()
    -- Comparing two secrets raises. A probe that quietly found no break while
    -- unable to compare anything would print exactly what a healthy column
    -- prints, which is the failure mode the display-type belt was written for.
    -- red under: dropping the CanCompare2 gate.
    local inst = T.load{ enable = true }
    -- The shipped default is Overall; the fixture seeds Current, and the probe
    -- reads whichever session the first window is pointed at.
    inst.NS.Database.GetWindows()[1].data.sessionType = 1
    inst.mocks.setSession(1, "*", {
        combatSources = {
            { sourceGUID = "Player-1-0000000A", name = "Alpha",
              totalAmount = inst.mocks.secret(100) },
            { sourceGUID = "Player-1-0000000B", name = "Beta",
              totalAmount = inst.mocks.secret(900) },
        },
        maxAmount = 900, totalAmount = 1000,
    })
    inst.mocks.setSecretsAccessible(false)

    local text = report(inst)
    assertTrue(text:find("cannot be checked", 1, true) ~= nil,
        "the probe has to admit it did not run")
    assertTrue(text:find("NOT ranked", 1, true) == nil,
        "and must not accuse the API on evidence it never gathered")
end)

-- ---------------------------------------------------------------------------
-- The death-recap probe (issue #1)
-- ---------------------------------------------------------------------------
--
-- Issue #1 wants a two-pane Death Recap window whose left pane lists every death
-- and whose right pane breaks the selected one down. Three things about the live
-- client decide whether that window can be built on `deathRecapID` at all, and
-- all three are currently guesses:
--
--   * does an id resolve for a NON-LOCAL player?
--   * does one resolve for a death from EARLIER IN THE RUN?
--   * is there any reader for the per-event breakdown, or only Blizzard's
--     frame-opening call?
--
-- If the answers are no, the window needs its own combat-log capture and the
-- issue is a materially larger job. This section is what turns that fork into
-- something a player can paste back instead of something we guess at twice.

--- Run only the recap probe and hand back everything it printed.
local function recapReport(inst)
    local D      = inst.NS.DebugLog
    local buffer = D and D.buffer
    local chatN  = #inst.mocks.__chat
    local bufN   = buffer and #buffer or 0

    inst.NS.Diagnostics.ReportDeathRecap()

    local lines = {}
    if buffer then
        for i = bufN + 1, #buffer do lines[#lines + 1] = buffer[i] end
    end
    for i = chatN + 1, #inst.mocks.__chat do lines[#lines + 1] = inst.mocks.__chat[i] end
    return table.concat(lines, "\n"), lines
end

--- A client that answers a recap for every id.
local function withRecapsFor(inst)
    inst.mocks.setDeathRecap({
        HasRecapEvents    = function() return true end,
        GetRecapEvents    = function(id)
            return { { spellId = 1, spellName = "X", amount = 1, currentHP = 1,
                       timestamp = 1787381686 + id } }
        end,
        GetRecapMaxHealth = function() return 1000 end,
    })
end

--- Seed the Deaths column with raw source rows and point window 1 at Current.
local function deathsSession(inst, rows)
    inst.NS.Database.GetWindows()[1].data.sessionType = 1
    inst.mocks.setSession(1, inst.mocks.Enum.DamageMeterType.Deaths, {
        combatSources = rows, maxAmount = 0, totalAmount = 0,
    })
end

--- The shape the client actually reports: ONE ROW PER DEATH, newest first, the
--- same `sourceGUID` repeated, a distinct `deathRecapID` on each.
local function death(guid, name, isLocal, recapID, when)
    return { sourceGUID = guid, name = name, isLocalPlayer = isLocal,
             totalAmount = 0, deathRecapID = recapID, deathTimeSeconds = when }
end

test("Diagnostics: `/mm debug recap` reaches the probe without the debug log", function()
    -- Same reasoning as `diag`: it is what a player is asked to run, and making
    -- them open a console first is one more step between us and the answer.
    -- red under: hanging the verb off the DebugLog branch in doDebug.
    local inst = T.load{ enable = true }
    inst.NS.DebugLog = nil

    local n = #inst.mocks.__chat
    inst.NS.Slash:OnSlash("debug recap")
    assertTrue(#inst.mocks.__chat > n, "the probe printed nothing")
end)

test("Diagnostics: the probe lists EVERY death, not just the newest per player", function()
    -- THE WHOLE POINT OF THE DUMP. modules/Aggregator.lua keeps one recap id per
    -- player and throws the rest away, which is exactly what issue #1 says has to
    -- stop. A probe that reported the aggregator's view would confirm the bug
    -- instead of measuring the client.
    -- red under: reading row.deathRecapID off the aggregated grid.
    local inst = T.load{ enable = true }
    deathsSession(inst, {
        death("Player-1-0000000A", "Pillows", false, 1003, 210),
        death("Player-1-0000000A", "Pillows", false, 1002, 118),
        death("Player-1-0000000A", "Pillows", false, 1001, 42),
    })

    local text = recapReport(inst)
    for _, id in ipairs({ "1001", "1002", "1003" }) do
        assertTrue(text:find(id, 1, true) ~= nil, "recap id " .. id .. " was dropped")
    end
end)

test("Diagnostics: it probes a NON-LOCAL id and an OLDER id, not only the newest", function()
    -- These two ARE the open questions. A probe that only ever called the local
    -- player's most recent death would come back green on a client that answers
    -- nothing else, and issue #1 would be designed on it.
    -- red under: probing sources[1] alone.
    local inst = T.load{ enable = true }
    deathsSession(inst, {
        death("Player-1-0000000A", "Me",     true,  2002, 300),
        death("Player-1-0000000A", "Me",     true,  2001, 100),
        death("Player-1-0000000B", "Notme",  false, 3002, 280),
        death("Player-1-0000000B", "Notme",  false, 3001, 90),
    })
    inst.mocks.setDeathInfo({ GetRecapEvent = function() return nil end })

    local text = recapReport(inst)
    assertTrue(text:find("local/newest", 1, true) ~= nil)
    assertTrue(text:find("local/older", 1, true) ~= nil)
    assertTrue(text:find("other/newest", 1, true) ~= nil)
    assertTrue(text:find("other/older", 1, true) ~= nil)
    -- and each of those four labels must carry the id it actually called with.
    for _, id in ipairs({ "2002", "2001", "3002", "3001" }) do
        assertTrue(text:find("id=" .. id, 1, true) ~= nil,
            "the probe did not call with id " .. id)
    end
end)

test("Diagnostics: a client with no reader is the answer that RE-SCOPES the issue", function()
    -- The fork the whole probe exists to resolve, and the one outcome a reader
    -- of the report must not have to infer from silence.
    -- red under: printing an empty reader list and moving on.
    local inst = T.load{ enable = true }
    deathsSession(inst, { death("Player-1-0000000A", "Me", true, 2001, 100) })
    inst.mocks.setDeathInfo(nil)

    local text = recapReport(inst)
    assertTrue(text:find("no recap reader", 1, true) ~= nil,
        "the probe must name the absence")
    assertTrue(text:find("its own event capture", 1, true) ~= nil,
        "and name what that costs issue #1")
end)

test("Diagnostics: a reader that refuses an id is reported, not swallowed", function()
    -- "Death Recap unavailable" for a past death is the observed behaviour issue
    -- #1 opens with. A refusal per id is the finding; a probe that died on the
    -- first one would print nothing for the three ids after it.
    -- red under: calling the reader outside the provider's pcall.
    local inst = T.load{ enable = true }
    deathsSession(inst, {
        death("Player-1-0000000A", "Me",    true,  2002, 300),
        death("Player-1-0000000B", "Notme", false, 3002, 280),
    })
    inst.mocks.setDeathInfo({
        GetRecapEvent = function(id)
            if id == 2002 then return { spellID = 5, amount = 12 } end
            error("no recap for that id")
        end,
    })

    local text = recapReport(inst)
    assertTrue(text:find("refused", 1, true) ~= nil, "the refusal was swallowed")
    assertTrue(text:find("spellID", 1, true) ~= nil,
        "and the id that DID answer must show what it answered")
end)

test("Diagnostics: the probe survives a client that answers nothing at all", function()
    -- No deaths, no reader, no window pointed anywhere useful. The report must
    -- still run to completion — a diagnostic that dies halfway looks like the
    -- thing it was diagnosing.
    local inst = T.load{ enable = true }
    local ok = pcall(recapReport, inst)
    assertTrue(ok, "the probe raised on an empty client")
end)

test("Diagnostics: a secret id is described rather than called", function()
    -- `deathRecapID` is documented NeverSecret and the probe still may not bet a
    -- raise on it: passing a secret into a client function is the `bad argument
    -- #4` that already shipped once through modules/Targets.lua.
    -- red under: forwarding the id without the safe-key gate.
    local inst = T.load{ enable = true }
    deathsSession(inst, {
        death("Player-1-0000000A", "Me", true, inst.mocks.secret(2002), 300),
    })
    inst.mocks.setSecretsAccessible(false)
    inst.mocks.setDeathInfo({
        GetRecapEvent = function() error("should never have been called") end,
    })

    local text = recapReport(inst)
    assertTrue(text:find("secret", 1, true) ~= nil,
        "a secret id must be described as one")
    assertTrue(text:find("should never have been called", 1, true) == nil,
        "the probe called the client with a secret")
end)

test("Diagnostics: the recap probe also rides along in the full report", function()
    -- A player running `/mm debug diag` after a dungeon hands over the evidence
    -- for free, which is worth more than a tidier report.
    local inst = T.load{ enable = true }
    local text = report(inst)
    assertTrue(text:find("death recap", 1, true) ~= nil, "missing section: death recap")
end)

-- ---------------------------------------------------------------------------
-- The death-recap probe, round two (issue #1)
-- ---------------------------------------------------------------------------
--
-- Round one, on a live 12.x client with nine deaths in the session, found ONE
-- recap-shaped function and it was `C_DeathInfo.GetDeathReleasePosition` — a
-- corpse coordinate. Read literally that re-scopes issue #1 into its own
-- combat-log capture. It is not read literally, because the same client opens
-- Blizzard's recap frame, and because a walk that misses a proxy namespace
-- produces exactly that output on a client that has a reader.
--
-- So the report now has to make the difference VISIBLE: the whole namespace
-- surface unfiltered, and a per-name verdict for the documented readers the walk
-- did not turn up.

test("Diagnostics: the probe prints the whole namespace surface, unfiltered", function()
    -- A healthy namespace with no recap function in it is conclusive; a namespace
    -- with two members in it is a proxy and the walk is at fault. A filtered list
    -- cannot tell those apart, which is the ambiguity round one shipped.
    -- red under: printing only the reader list.
    local inst = T.load{ enable = true }
    inst.mocks.setDeathInfo({
        GetGraveyardsForMap     = function() end,
        GetSelfResurrectOptions = function() end,
    })

    local text = recapReport(inst)
    assertTrue(text:find("GetGraveyardsForMap", 1, true) ~= nil,
        "a member with nothing to do with a recap is exactly what the dump is for")
    assertTrue(text:find("GetSelfResurrectOptions", 1, true) ~= nil)
end)

test("Diagnostics: an absent namespace reads absent, not empty", function()
    -- red under: printing `C_DeathInfo: 0 members` for a client that has none.
    local inst = T.load{ enable = true }
    inst.mocks.setDeathInfo(nil)
    local text = recapReport(inst)
    assertTrue(text:find("C_DeathInfo: not on this client", 1, true) ~= nil)
end)

test("Diagnostics: it says WHICH search found each reader", function()
    -- The single word the fork turns on. `walk` means round one's empty result
    -- was the client speaking; `named` means it was the search.
    -- red under: printing a bare list of names.
    local inst = T.load{ enable = true }
    deathsSession(inst, { death("Player-1-0000000A", "Me", true, 25, 100) })
    local hidden = setmetatable({}, { __index = function(_, key)
        if key == "GetRecapEvent" then return function() return { spellID = 5 } end end
        return nil
    end })
    inst.mocks.setDeathInfo(hidden)

    local text = recapReport(inst)
    assertTrue(text:find("named", 1, true) ~= nil,
        "a reader only a direct index could see must be labelled as such")
    assertTrue(text:find("the walk cannot see", 1, true) ~= nil,
        "and the report must say what that means")
end)

test("Diagnostics: with both searches empty the verdict says so CONCLUSIVELY", function()
    -- Round one's verdict said "no recap reader" off one search. Two searches
    -- agreeing is a different claim and has to read like one, or the next person
    -- re-scopes the issue on the weaker evidence.
    -- red under: keeping the one-search wording.
    local inst = T.load{ enable = true }
    inst.mocks.setDeathInfo({ GetGraveyardsForMap = function() end })

    local text = recapReport(inst)
    assertTrue(text:find("both searches", 1, true) ~= nil,
        "the verdict must rest on the pair, not on the walk alone")
    assertTrue(text:find("its own event capture", 1, true) ~= nil)
end)

test("Diagnostics: a reader that answers NOTHING is not a green light", function()
    -- MEASURED ON A LIVE CLIENT, and the reason this branch exists. Round one
    -- found exactly one recap-shaped function — `GetDeathReleasePosition`, a
    -- corpse coordinate — which returned nil for all four ids, and the verdict
    -- printed the "all four answering is the green light" wording underneath it
    -- because the LIST was non-empty. A verdict must follow what came back, not
    -- what was found.
    -- red under: branching on #apis instead of on the answers.
    local inst = T.load{ enable = true }
    deathsSession(inst, {
        death("Player-1-0000000A", "Me",    true,  25, 100),
        death("Player-1-0000000B", "Notme", false, 26, 90),
    })
    inst.mocks.setDeathInfo({ GetDeathReleasePosition = function() return nil end })

    local text = recapReport(inst)
    assertTrue(text:find("answered for no id", 1, true) ~= nil,
        "the verdict must say the readers came back empty")
    assertTrue(text:find("green light", 1, true) == nil,
        "a client that answered nothing was told it was good to go")
end)

test("Diagnostics: the verdict names WHICH of the four slots answered", function()
    -- The two open questions are slots, not totals. A reader that answers the
    -- local player's newest death and nothing else is Blizzard's frame
    -- behaviour, and the report has to make that visible at a glance rather than
    -- leaving it to be counted out of twenty probe lines.
    -- red under: reporting a bare answered/not-answered count.
    local inst = T.load{ enable = true }
    deathsSession(inst, {
        death("Player-1-0000000A", "Me",    true,  25, 100),
        death("Player-1-0000000A", "Me",    true,  18, 50),
        death("Player-1-0000000B", "Notme", false, 26, 90),
    })
    inst.mocks.setDeathInfo({
        GetRecapEvent = function(id)
            if id == 25 then return { spellID = 5, amount = 12 } end
            return nil
        end,
    })

    local text = recapReport(inst)
    assertTrue(text:find("answered: local/newest", 1, true) ~= nil,
        "the slot that answered must be named")
    assertTrue(text:find("Blizzard's own frame behaviour", 1, true) ~= nil,
        "and local/newest alone is exactly the outcome that sinks the design")
end)

test("Diagnostics: a reader found by name is actually CALLED", function()
    -- Finding it and not calling it would answer the cheap question and leave the
    -- expensive one — does it resolve for a past death, or another player's —
    -- exactly as open as before.
    -- red under: probing only the walk's results.
    local inst = T.load{ enable = true }
    deathsSession(inst, { death("Player-1-0000000A", "Me", true, 25, 100) })
    local called = {}
    local hidden = setmetatable({}, { __index = function(_, key)
        if key ~= "GetRecapEvent" then return nil end
        return function(id) called[#called + 1] = id return { spellID = 5, amount = 12 } end
    end })
    inst.mocks.setDeathInfo(hidden)

    local text = recapReport(inst)
    assertEqual(called[1], 25, "the reader was listed but never called")
    assertTrue(text:find("spellID", 1, true) ~= nil, "and what it answered was not printed")
end)

test("Diagnostics: an ARRAY of events is described as one, with its fields", function()
    -- `GetRecapEvents` hands back an array of event tables, and the whole right
    -- pane of issue #1 is made of their fields. Described by string keys alone —
    -- which is all rounds one and two ever met — an array prints as `table{}`:
    -- the report would find the reader and then say it returned nothing useful.
    -- red under: describing only string-keyed members.
    local inst = T.load{ enable = true }
    deathsSession(inst, { death("Player-1-0000000A", "Me", true, 25, 100) })
    inst.mocks.setDeathRecap({
        GetRecapEvents = function()
            return {
                { spellId = 100, spellName = "Crush", amount = 900, currentHP = 0,
                  timestamp = 1000.5, event = "SPELL_DAMAGE", overkill = 40 },
                { spellId = 101, spellName = "Bite", amount = 400, currentHP = 900,
                  timestamp = 998.4, event = "SPELL_DAMAGE" },
            }
        end,
    })

    local text = recapReport(inst)
    assertTrue(text:find("array[2]", 1, true) ~= nil, "the length was not reported")
    for _, field in ipairs({ "spellId", "spellName", "amount", "currentHP",
                             "timestamp", "event", "overkill" }) do
        assertTrue(text:find(field, 1, true) ~= nil,
            "the event field " .. field .. " never reached the report")
    end
end)

test("Diagnostics: an empty array is not mistaken for an answer", function()
    -- `#raw == 0` is how a working addon detects "this id has no recap", so it
    -- is a real client answer and must not count toward a slot answering.
    -- red under: treating any non-nil return as an answer.
    local inst = T.load{ enable = true }
    deathsSession(inst, { death("Player-1-0000000A", "Me", true, 25, 100) })
    inst.mocks.setDeathRecap({ GetRecapEvents = function() return {} end })

    local text = recapReport(inst)
    assertTrue(text:find("array[0]", 1, true) ~= nil)
    assertTrue(text:find("answered for no id", 1, true) ~= nil,
        "an empty array was counted as a recap")
end)

test("Diagnostics: a slot with no death is not counted as a slot that refused", function()
    -- MEASURED. A run where the local player never died probed only the two
    -- `other/*` slots, both answered in full — and the verdict still printed
    -- "some slots answered and some did not", warning about the local-only
    -- signature that sinks the design. Nothing had refused: two slots had no
    -- death to ask about. A report that cries wolf about its own missing
    -- fixture is worse than one that says less.
    -- red under: comparing the answered count against #RECAP_SLOTS.
    local inst = T.load{ enable = true }
    deathsSession(inst, {
        death("Player-1-0000000B", "Notme", false, 29, 1356),
        death("Player-1-0000000C", "Alsonotme", false, 28, 673),
    })
    inst.mocks.setDeathRecap({
        GetRecapEvents = function() return { { spellId = 5, amount = 12 } } end,
    })

    local text = recapReport(inst)
    assertTrue(text:find("every death this session could offer", 1, true) ~= nil,
        "two of two probed slots answering is a clean result and must read as one")
    assertTrue(text:find("some slots answered and some did not", 1, true) == nil,
        "the report warned about slots that were never asked")
end)

test("Diagnostics: a slot that WAS probed and refused still raises the warning", function()
    -- The belt on the fix above. Narrowing the verdict to probed slots must not
    -- turn off the finding it exists for.
    -- red under: dropping the partial branch entirely.
    local inst = T.load{ enable = true }
    deathsSession(inst, {
        death("Player-1-0000000A", "Me",    true,  25, 100),
        death("Player-1-0000000B", "Notme", false, 29, 90),
    })
    inst.mocks.setDeathRecap({
        GetRecapEvents = function(id)
            if id == 25 then return { { spellId = 5 } } end
            return nil
        end,
    })

    local text = recapReport(inst)
    assertTrue(text:find("some slots answered and some did not", 1, true) ~= nil)
end)

test("Diagnostics: the recap probe reports why a death is dated the way it is", function()
    -- Kept after the feature it was written for was removed. "Time into the
    -- fight" never worked, and this section is what proved it could not: it
    -- prints the INPUTS rather than the conclusion, which is how the third
    -- failed derivation was caught instead of shipped. Anything that later tries
    -- to date a death against its run will need exactly this again.
    -- red under: printing the dates without the inputs that produced them.
    local inst = T.load{ enable = true }
    deathsSession(inst, {
        death("Player-1-0000000A", "Me", true, 29, 1356),
        death("Player-1-0000000B", "Notme", false, 28, -1),
    })
    withRecapsFor(inst)

    local text = recapReport(inst)
    assertTrue(text:find("-- dating --", 1, true) ~= nil, "the section must appear")
    assertTrue(text:find("deathTimeFormat", 1, true) ~= nil,
        "the setting in force has to be printed, not assumed")
    assertTrue(text:find("deathTimeSeconds", 1, true) ~= nil,
        "the field three failed derivations were built on has to be visible")
    -- Both styles, side by side, so a reader can see them agreeing.
    for _, style in ipairs({ "clock", "ago" }) do
        assertTrue(text:find(style, 1, true) ~= nil, "missing style: " .. style)
    end
end)

test("Diagnostics: the header section covers every control, by walking them", function()
    -- IT HAS ALREADY FAILED SILENTLY ONCE HERE. The previous version named three
    -- button fields inside `if button then`, so when the controls moved to
    -- modules/HeaderControls.lua the loop printed nothing at all: no error, just
    -- a report that had quietly stopped covering the header. Walking the
    -- registry is what makes a control added later appear without anyone
    -- remembering to add it.
    -- red under: naming fields instead of walking window.controls.
    local inst = T.load{ enable = true }
    local text = report(inst)
    for _, key in ipairs({ "close", "minimise", "lock", "settings",
                           "segment", "reset", "export" }) do
        assertTrue(text:find(key, 1, true) ~= nil,
            "the header section never mentions " .. key)
    end
end)

test("Diagnostics: a window with no controls says so rather than printing nothing", function()
    -- The failure mode that hid the last one: an empty section reads exactly
    -- like a section with nothing to report.
    local inst = T.load{ enable = true }
    local win = inst.NS.WindowManager.All()[1]
    if win then win.controls = nil end

    local text = report(inst)
    assertTrue(text:find("none built", 1, true) ~= nil,
        "an absent control set printed silence")
end)
