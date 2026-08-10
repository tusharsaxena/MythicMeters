-- tests/test_debuglogsetup.lua — LibKa0s-DebugLog-1.0 wiring.
--
-- This addon needs the console more than most of its siblings. Every number it
-- renders is a secret value for the whole of a pull, so the interesting bugs are
-- the ones you cannot inspect: a cell that shows nothing, a row that sorted
-- wrong, a column that read nil. The debug pass is how those get diagnosed, and
-- NS.Debug's deferred format is what makes it affordable — the format string and
-- its arguments are only assembled when the flag is on, and every argument goes
-- through safeToString on the way, so a SECRET reaching a log line renders as
-- the sentinel instead of raising inside the sink.
--
-- What this file owns, and what each case here is therefore about:
--   * the frame-name prefix, the title and the monospace font;
--   * WHERE THE FLAG LIVES — NS.State.debug is ours, session-only, and a second
--     copy inside the library would be a second truth;
--   * what the [Init] session summary says;
--   * a degradation stub that carries the whole surface AND NO COPY of the
--     library's line format (debug-logging-§3). That last one has its own case,
--     because a fallback that re-implements the format is exactly the drift the
--     extraction exists to end.

local T = _G.MYTHICMETERS_TEST
local test, assertEqual, assertTrue, assertFalse, assertNil =
    T.test, T.assertEqual, T.assertTrue, T.assertFalse, T.assertNil

local ROOT = T.root or "."

local function source(rel)
    local fh = assert(io.open(ROOT .. "/" .. rel, "r"))
    local src = fh:read("*a")
    fh:close()
    return src
end

-- ── the live seam ───────────────────────────────────────────────────────────

test("DebugLogSetup: NS.DebugLog is the library instance and NS.Debug is its bare sink", function()
    -- debug-logging-§4: the addon-wide sink is bound BARE rather than wrapped —
    -- it is a plain function precisely so `NS.Debug("Aggregate", "rows=%d", n)`
    -- keeps working with no self and no allocation when the flag is off.
    -- red under: `NS.Debug = function(...) return NS.DebugLog.Debug(...) end`.
    local inst = T.load{}
    assertTrue(inst.NS.DebugLog ~= nil)
    assertEqual(type(inst.NS.Debug), "function")
    assertTrue(inst.NS.Debug == inst.NS.DebugLog.Debug, "NS.Debug must BE the instance's sink")
end)

test("DebugLogSetup: the sink is gated on the flag and costs nothing when it is off", function()
    -- The flag defaults OFF and is never persisted, so "off" is the state the
    -- addon spends its whole life in.
    local inst = T.load{}
    local D = inst.NS.DebugLog
    assertFalse(inst.NS.State.debug, "the flag must default off")
    local before = D:BufferSize()
    inst.NS.Debug("Render", "rows=%d", 12)
    assertEqual(D:BufferSize(), before, "a gated-off sink still wrote a line")

    inst.NS.State.debug = true
    inst.NS.Debug("Render", "rows=%d", 12)
    assertTrue(D:BufferSize() > before, "the sink wrote nothing with the flag on")
    assertTrue(D:LastLine():find("rows=12", 1, true) ~= nil, "got: " .. tostring(D:LastLine()))
end)

test("DebugLogSetup: a SECRET reaching a log line renders as the sentinel, never as a raise",
function()
    -- THE case for this addon specifically. A secret raises inside string.format
    -- exactly as it does inside table.concat, and a debug line on a coalesced
    -- refresh ticker is a repeating call site — one raise takes the feature down
    -- until /reload.
    -- red under: passing the raw varargs to string.format without safeToString.
    local inst = T.load{}
    inst.NS.State.debug = true
    local secretValue = inst.mocks.secret(4200000)
    local ok, err = pcall(inst.NS.Debug, "Render", "total=%s", secretValue)
    assertTrue(ok, "the sink raised on a secret: " .. tostring(err))
    local line = inst.NS.DebugLog:LastLine()
    assertTrue(line ~= nil, "nothing was logged")
    assertFalse(line:find("4200000", 1, true) ~= nil, "the raw secret value leaked into the log")
end)

test("DebugLogSetup: the flag stays the addon's — the library holds no second copy", function()
    -- NS.State.debug is read by the settings panel and by `/mm debug`, so a copy
    -- inside the library would be a second truth and the two would disagree the
    -- first time one of them was written directly.
    local inst = T.load{}
    inst.NS.State.debug = true
    assertTrue(inst.NS.DebugLog:IsEnabled(), "the library must READ our flag")
    inst.NS.State.debug = false
    assertFalse(inst.NS.DebugLog:IsEnabled())

    inst.NS.DebugLog:SetEnabled(true)
    assertTrue(inst.NS.State.debug, "SetEnabled must WRITE our flag, not a private one")
    inst.NS.DebugLog:SetEnabled(false)
    assertFalse(inst.NS.State.debug)
end)

test("DebugLogSetup: the debug flag never reaches SavedVariables", function()
    -- debug-logging-§5. A console left on across a login is a console nobody
    -- asked for, and the flag is session-only for exactly that reason.
    local inst = T.load{}
    inst.NS.DebugLog:SetEnabled(true)
    local saved = _G.MythicMetersDB
    assertNil((saved.profiles and saved.profiles.Default or {}).debug)
    assertNil((saved.global or {}).debug)
end)

test("DebugLogSetup: enabling the console acknowledges in chat", function()
    -- debug-logging-§7: a user who types `/mm debug on` has to be told it took.
    local inst = T.load{}
    local before = #inst.mocks.__chat
    inst.NS.DebugLog:SetEnabled(true)
    assertTrue(#inst.mocks.__chat > before, "SetEnabled said nothing")
end)

test("DebugLogSetup: the [Init] summary names the version, the schema and the profile", function()
    -- Emitted on ENABLE rather than at login, because the flag is off at login
    -- and a load-time summary would always be gated off. All three facts have to
    -- be there: a log without them cannot be read a week later.
    -- red under: dropping the schema version from initSummary.
    local inst = T.load{}
    inst.NS.DebugLog:SetEnabled(true)
    local line = inst.NS.DebugLog:FindLine("MythicMeters v")
    assertTrue(line ~= nil, "no [Init] session summary was emitted")
    assertTrue(line:find(inst.NS.version, 1, true) ~= nil, "the summary omits the version")
    assertTrue(line:find("schema v" .. tostring(inst.NS.db.global.schemaVersion), 1, true) ~= nil,
        "the summary omits the schema version: " .. line)
    assertTrue(line:find("profile 'Default'", 1, true) ~= nil, "the summary omits the profile")
end)

test("DebugLogSetup: the console takes the shipped monospace font by PATH", function()
    -- A meter is a grid of numbers and a proportional face makes the columns
    -- shiver. The console shares the same face so a log of a render pass lines
    -- up the way the window does.
    local src = source("core/DebugLogSetup.lua")
    assertTrue(src:find("NS.Constants and NS.Constants.FONT_MONO", 1, true) ~= nil,
        "the console must take the shipped font from the one constant")
end)

test("DebugLogSetup: the font is registered with LSM exactly once, and not from this file",
function()
    -- A second Register call added the same path under a hardcoded name — a
    -- second LSM key for one face, so the font dropdown listed it twice and a
    -- profile could store a name core/LSMPatch.lua does not ship.
    -- red under: adding an LSM:Register back into core/DebugLogSetup.lua.
    assertNil(source("core/DebugLogSetup.lua"):match("LSM[^\r\n]*:Register"),
        "core/DebugLogSetup.lua registers the font a second time")
    local registrars = {}
    for _, rel in ipairs(T.loadedAddonFiles) do
        local src = source(rel):gsub("%-%-[^\r\n]*", "")
        if src:match("Register%(%s*LSM%.MediaType") then registrars[#registrars + 1] = rel end
    end
    assertEqual(table.concat(registrars, ", "), "core/LSMPatch.lua")
end)

test("DebugLogSetup: the frame names are seeded from the addon name", function()
    -- Two hosts sharing a name would clobber each other's globals and each
    -- other's Esc handler.
    local src = source("core/DebugLogSetup.lua")
    assertTrue(src:match("name%s*=%s*addonName") ~= nil,
        "the descriptor must seed its frame names from addonName, not a literal")
end)

test("DebugLogSetup: the console's visibility change refreshes an open settings panel", function()
    -- The General page's "Debug console" checkbox mirrors the window's
    -- visibility, so a console closed with Esc or opened from `/mm debug` has to
    -- move a checkbox on a panel that is already open.
    local src = source("core/DebugLogSetup.lua"):gsub("%-%-[^\r\n]*", "")
    assertTrue(src:find("onVisibilityChanged", 1, true) ~= nil)
    assertTrue(src:find("RefreshAllPanels", 1, true) ~= nil)
    assertTrue(src:find("local H = NS.Helpers", 1, true) ~= nil,
        "Helpers must be resolved at CALL time — settings/ loads long after this file")
end)

-- ── the degraded seam ───────────────────────────────────────────────────────

test("DebugLogSetup degraded: the stub carries the WHOLE live surface", function()
    -- testing-§8: proved by a real load with the library gone, never by
    -- hand-stubbing the member under test. A stub that omits one member is not a
    -- fallback — it is a crash moved to a rarer code path.
    local live     = T.load{}.NS.DebugLog
    local degraded = T.load{ libFiles = {} }.NS.DebugLog
    assertTrue(degraded ~= nil, "NS.DebugLog must exist with no library at all")
    T.assertSurfaceParity(live, degraded, "NS.DebugLog", {
        -- Library-internal test seams, not part of the contract the addon calls.
        "_toggleClickForTest", "_frameForTest",
    })
end)

test("DebugLogSetup degraded: NS.Debug is still a plain callable function", function()
    -- Every call site in the addon reads `NS.Debug("Render", "%s", x)` on both
    -- paths, so the degraded sink has to have the same shape and swallow rather
    -- than raise.
    local inst = T.load{ libFiles = {} }
    assertEqual(type(inst.NS.Debug), "function")
    inst.NS.Debug("Render", "rows=%d", 12)
    inst.NS.Debug("Render", "secret=%s", inst.mocks.secret(1))
end)

test("DebugLogSetup degraded: the flag still works, and says so once", function()
    -- What is LOST is the window. NS.State.debug is ours, and a user who types
    -- `/mm debug on` must not be told nothing happened.
    local inst = T.load{ libFiles = {} }
    local before = #inst.mocks.__chat
    inst.NS.DebugLog:SetEnabled(true)
    assertTrue(inst.NS.State.debug, "the flag is ours and must still flip")
    assertTrue(inst.NS.DebugLog:IsEnabled())
    assertTrue(#inst.mocks.__chat > before, "the degraded SetEnabled acknowledged nothing")

    local text = table.concat(inst.mocks.__chat, "\n")
    assertTrue(text:find(inst.NS.LIBKA0S_MISSING, 1, true) ~= nil,
        "the degraded seam never said WHY the console is missing")
    assertTrue(text:find("debug console window is unavailable", 1, true) ~= nil,
        "the degraded seam never named its own consequence")
end)

test("DebugLogSetup degraded: the honest missing-console line is said ONCE", function()
    -- Stapling it to every debug action turns a one-time fact into noise on a
    -- ticker.
    local inst = T.load{ libFiles = {} }
    inst.NS.DebugLog:Show()
    inst.NS.DebugLog:Toggle()
    inst.NS.DebugLog:ShowCopy()
    inst.NS.DebugLog:SetEnabled(true)
    local n = 0
    for _, line in ipairs(inst.mocks.__chat) do
        if line:find("debug console window is unavailable", 1, true) then n = n + 1 end
    end
    assertEqual(n, 1, "the degraded notice was printed " .. n .. " times")
end)

test("DebugLogSetup degraded: the stub reproduces NO part of the library's line format", function()
    -- debug-logging-§3 forbids reproducing the line format OR its color codes in
    -- a fallback, and the format is the half that matters: a log pasted from any
    -- Ka0s addon parses the same way by eye BECAUSE one library renders it. The
    -- stub renders NO line — it has no console to render one into — and its
    -- FormatPlain hands the message back unchanged.
    -- red under: copying the "%s | [%s] %s" shape or either hex code into the stub.
    local src = source("core/DebugLogSetup.lua")
    for _, forbidden in ipairs({ "6f8faf", "c9a66b", "40ff40", "ff4040", "%s | [%s] %s" }) do
        assertNil(src:find(forbidden, 1, true),
            "core/DebugLogSetup.lua carries a copy of the library's format: " .. forbidden)
    end
    local inst = T.load{ libFiles = {} }
    assertEqual(inst.NS.DebugLog.FormatPlain(nil, "Tag", "the message"), "the message",
        "the degraded formatter must hand the message back unchanged, not render a line")
    assertTrue(inst.NS.DebugLog.FormatColored == inst.NS.DebugLog.FormatPlain,
        "the two degraded formatters must be one function — there is no color to add")
end)

test("DebugLogSetup degraded: the console checkbox answers a usable data contract", function()
    -- The General page renders whatever this returns, so a nil here is a
    -- settings page that raises on the degraded install the stub exists for.
    local inst = T.load{ libFiles = {} }
    local box = inst.NS.DebugLog:ConsoleCheckbox()
    assertEqual(type(box), "table")
    assertEqual(type(box.label), "string")
    assertEqual(type(box.tooltip), "string")
    assertEqual(type(box.get), "function")
    assertEqual(type(box.set), "function")
    assertFalse(box.get(), "there is no console, so the box must read false")
    box.set(true)   -- must not raise
end)

test("DebugLogSetup degraded: the buffer introspection answers rather than erroring", function()
    local D = T.load{ libFiles = {} }.NS.DebugLog
    assertEqual(type(D.buffer), "table")
    assertEqual(D:BufferSize(), 0)
    assertNil(D:LastLine())
    assertNil(D:FindLine("anything"))
    assertEqual(D:CopyText(), "")
    assertFalse(D:IsShown())
    assertNil(D.MakeCloseButton())
end)
