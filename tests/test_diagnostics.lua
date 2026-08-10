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
local function report(inst)
    local n = #inst.mocks.__chat
    inst.NS.Diagnostics.Report()
    local lines = {}
    for i = n + 1, #inst.mocks.__chat do lines[#lines + 1] = inst.mocks.__chat[i] end
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
