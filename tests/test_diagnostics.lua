-- tests/test_diagnostics.lua — core/Diagnostics.lua, the `/mm debug diag` report.
--
-- The report exists because three display bugs in a row were caused by assuming
-- something about the running client and never checking it. So the property that
-- matters most here is that the report itself cannot become another one: it must
-- run to completion on a hostile client, print rather than raise, and never be
-- the reason a player cannot describe what they are seeing.

local T = _G.MYTHICMETERS_TEST

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
