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
    -- profile could store a name nothing ships.
    -- red under: adding an LSM:Register back into core/DebugLogSetup.lua.
    assertNil(source("core/DebugLogSetup.lua"):match("LSM[^\r\n]*:Register"),
        "core/DebugLogSetup.lua registers the font a second time")

    -- AND NO FILE HERE REGISTERS A FONT AT ALL ANY MORE. The face ships inside
    -- the LibKa0s payload (v1.9.0), so the LIBRARY registers it -- one key, one
    -- path, agreed across every Ka0s addon -- and core/MediaSetup.lua is the one
    -- place that asks it to. An LSM:Register reappearing anywhere in this addon
    -- is this addon naming the library's bytes under a second key.
    local registrars, askers = {}, {}
    for _, rel in ipairs(T.loadedAddonFiles) do
        local src = source(rel):gsub("%-%-[^\r\n]*", "")
        if src:match("Register%(%s*LSM%.MediaType") then registrars[#registrars + 1] = rel end
        if src:find("RegisterLSM", 1, true) then askers[#askers + 1] = rel end
    end
    assertEqual(table.concat(registrars, ", "), "")
    assertEqual(table.concat(askers, ", "), "core/MediaSetup.lua")
end)

test("DebugLogSetup: the library is told the FOLDER name, not just the frame name", function()
    -- Two fields, two questions, one string in this addon: `name` seeds the frame
    -- globals, `addonName` is what the library builds a texture path from so its own
    -- close, copy and clear draw this collection's art. A host where the two diverge
    -- would hand the library a path into nowhere -- which draws nothing and raises
    -- nothing -- so this is passed explicitly rather than inferred.
    -- red under: dropping `addonName` and letting the console keep its glyph and words.
    local src = source("core/DebugLogSetup.lua"):gsub("%-%-[^\r\n]*", "")
    assertTrue(src:match("addonName%s*=%s*addonName") ~= nil,
        "the descriptor does not pass addonName, so the console draws the minor-8 title bar")
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

-- ── the steady-state sink ───────────────────────────────────────────────────
--
-- debug-logging-§9 collapses per-ITEM to per-PASS. These cases are about the
-- axis it leaves open: a pass on a timer that reports the same thing every time.
-- Measured on this addon, that is twelve lines a second into a 500-line buffer —
-- forty seconds of history, and a single steady state evicts everything behind
-- it. Recorded as an accepted deviation in docs/ARCHITECTURE.md.

--- Every line the sink emitted while `body` ran.
local function lines(inst, body)
    local D = inst.NS.DebugLog
    local n = #D.buffer
    body()
    local out = {}
    for i = n + 1, #D.buffer do out[#out + 1] = D.buffer[i] end
    return out
end

test("DebugSteady: an unchanged pass emits once, not once per pass", function()
    -- THE BUG THIS EXISTS FOR. A live capture showed one identity line repeating
    -- byte-identically for forty-one seconds — about 160 passes, ~480 lines, one
    -- string — which is the whole buffer spent on a single steady state.
    -- red under: forwarding straight to NS.Debug.
    local inst = T.load{ enable = true }
    inst.NS.State.debug = true
    local emitted = lines(inst, function()
        for _ = 1, 40 do inst.NS.DebugSteady(1, "Render", "drew %d/%d rows", 2, 2) end
    end)
    assertEqual(#emitted, 1, "an unchanged pass was logged more than once")
end)

test("DebugSteady: a CHANGE emits on the pass it happens, never delayed", function()
    -- The one thing a clock-based throttle gets wrong. A change is the only
    -- content these lines carry, so suppressing one to save nine identical ones
    -- throws away the signal to save the noise.
    -- red under: gating the emission on the heartbeat interval.
    local inst = T.load{ enable = true }
    inst.NS.State.debug = true
    local emitted = lines(inst, function()
        inst.NS.DebugSteady(1, "Render", "drew %d/%d rows", 2, 2)
        inst.NS.DebugSteady(1, "Render", "drew %d/%d rows", 2, 2)
        inst.NS.DebugSteady(1, "Render", "drew %d/%d rows", 3, 3)
    end)
    assertTrue(emitted[#emitted]:find("3/3", 1, true) ~= nil,
        "the changed line did not come out on the pass it changed")
end)

test("DebugSteady: the run's count lands on the line it describes", function()
    -- `(x40)` belongs to the state it counts, not to the state that replaced it.
    -- Reported before the line that broke the run, so a reader sees "this held
    -- for forty passes, then became that" in the order it happened.
    -- red under: appending the count to the NEW line.
    local inst = T.load{ enable = true }
    inst.NS.State.debug = true
    local emitted = lines(inst, function()
        for _ = 1, 40 do inst.NS.DebugSteady(1, "Render", "drew %d/%d rows", 2, 2) end
        inst.NS.DebugSteady(1, "Render", "drew %d/%d rows", 3, 3)
    end)
    assertEqual(#emitted, 3, "expected the first line, the run summary, then the change")
    assertTrue(emitted[2]:find("2/2", 1, true) ~= nil, "the run summary lost its own figures")
    assertTrue(emitted[2]:find("(x40)", 1, true) ~= nil, "the run summary lost its count")
    assertTrue(emitted[3]:find("3/3", 1, true) ~= nil, "the changed line is missing")
end)

test("DebugSteady: the (xN) line keeps EVERY field, not just the first", function()
    -- The seam where getting it wrong is silent. `NS.Debug(tag, fmt, ..., count)`
    -- truncates the vararg to its first value — Lua adjusts a multi-value
    -- expansion to one result anywhere but the last argument position — so the
    -- line still prints, with every field after the first replaced by the count,
    -- and nothing raises.
    -- red under: passing the count after `...` instead of appending it to a list.
    local inst = T.load{ enable = true }
    inst.NS.State.debug = true
    local emitted = lines(inst, function()
        for _ = 1, 3 do inst.NS.DebugSteady(1, "Aggregator", "rows=%d keys=%d filled=%d", 2, 3, 7) end
        inst.NS.DebugSteady(1, "Aggregator", "rows=%d keys=%d filled=%d", 2, 3, 8)
    end)
    assertTrue(emitted[2]:find("rows=2 keys=3 filled=7", 1, true) ~= nil,
        "the run summary lost fields to the count: " .. emitted[2])
end)

test("DebugSteady: two windows sharing a tag do not defeat each other", function()
    -- A tag-only cache would see the two windows alternate, call every pass a
    -- change, and suppress nothing — the fix silently doing nothing, and only on
    -- an install with a second window.
    -- red under: keying the cache on the tag alone.
    local inst = T.load{ enable = true }
    inst.NS.State.debug = true
    local emitted = lines(inst, function()
        for _ = 1, 20 do
            inst.NS.DebugSteady(1, "Render", "window %d drew %d rows", 1, 2)
            inst.NS.DebugSteady(2, "Render", "window %d drew %d rows", 2, 5)
        end
    end)
    assertEqual(#emitted, 2, "the two windows defeated each other's comparison")
end)

test("DebugSteady: an unchanged run re-announces itself, so silence still means something", function()
    -- Without this a frozen refresh loop and a healthy idle one produce
    -- identical logs, and "no lines" stops meaning "nothing changed".
    -- red under: dropping the heartbeat and suppressing on content alone.
    local inst = T.load{ enable = true }
    inst.NS.State.debug = true
    local emitted = lines(inst, function()
        for _ = 1, 8 do inst.NS.DebugSteady(1, "Render", "drew %d rows", 2) end
        inst.mocks.__now = inst.mocks.__now + 11
        inst.NS.DebugSteady(1, "Render", "drew %d rows", 2)
    end)
    assertEqual(#emitted, 2, "an unchanged run never re-announced itself")
    assertTrue(emitted[2]:find("(x9)", 1, true) ~= nil,
        "the heartbeat did not say how many passes it stood for")
end)

test("DebugSteady: a SECRET argument is emitted at once and never replayed", function()
    -- Holding a secret is legal and comparing one is legal, but a suppressed run
    -- gets RE-EMITTED later — and replaying a handle captured ten seconds ago
    -- prints a stale figure under a current timestamp. That is the one failure a
    -- debug line must not have.
    -- red under: storing every argument regardless of what it is.
    local inst = T.load{ enable = true }
    inst.NS.State.debug = true
    local secret = inst.mocks.secret(42)
    local emitted = lines(inst, function()
        for _ = 1, 5 do inst.NS.DebugSteady(1, "Render", "value=%s", secret) end
    end)
    assertEqual(#emitted, 5, "a secret was held across passes and replayed")
end)

test("DebugSteady: it exists without the library, because the render path calls it", function()
    -- The stub branch RETURNS, so anything defined after it does not exist on an
    -- install without LibKa0s — and this is called behind `if State.debug`, so
    -- the absence would surface only for a player who turned logging on with the
    -- library missing. debug-logging-§7 is about exactly this surface.
    -- red under: defining the helper after the library fork.
    local inst = T.load{ libFiles = {} }
    assertEqual(type(inst.NS.DebugSteady), "function")
    inst.NS.DebugSteady(1, "Render", "drew %d rows", 2)   -- must not raise
end)

test("DebugSteady: a reset makes the next pass speak again", function()
    -- After the console is cleared, the first line a reader waits for is the one
    -- describing the state they are looking at. Suppressing it against a
    -- comparison they can no longer see is the console lying by omission.
    -- red under: no reset seam.
    local inst = T.load{ enable = true }
    inst.NS.State.debug = true
    local emitted = lines(inst, function()
        inst.NS.DebugSteady(1, "Render", "drew %d rows", 2)
        inst.NS.DebugSteadyReset()
        inst.NS.DebugSteady(1, "Render", "drew %d rows", 2)
    end)
    assertEqual(#emitted, 2, "the pass stayed silent after a reset")
end)

test("DebugSteady: toggling the flag forgets every run", function()
    -- Logging turned off and on again must not resume mid-comparison. The first
    -- pass after the toggle would match a run the reader never saw, be
    -- suppressed, and leave the console silent for up to the heartbeat — which
    -- reads exactly like the addon doing nothing.
    -- red under: setEnabled writing the flag and nothing else.
    local inst = T.load{ enable = true }
    inst.NS.DebugLog:SetEnabled(true)
    inst.NS.DebugSteady(1, "Render", "drew %d rows", 2)
    inst.NS.DebugLog:SetEnabled(false)
    inst.NS.DebugLog:SetEnabled(true)

    local emitted = lines(inst, function()
        inst.NS.DebugSteady(1, "Render", "drew %d rows", 2)
    end)
    assertEqual(#emitted, 1, "the first pass after a toggle stayed silent")
end)

test("DebugSteady: two call sites under ONE tag do not defeat each other", function()
    -- THE BUG THE FIRST VERSION SHIPPED WITH, and it looked like a tuning problem
    -- rather than a defect. modules/Aggregator.lua has two call sites under the
    -- tag `Aggregator` — the pass summary and the identity line — and on a single
    -- window they share a key. Through one slot they alternated: each call found
    -- the other's format sitting there, called itself a change, and emitted. In a
    -- live log `[Render]` deduped to `(x41)` while `[Aggregator]` repeated four
    -- times a second exactly as before.
    -- red under: caching on (tag, key) instead of (format, key).
    local inst = T.load{ enable = true }
    inst.NS.State.debug = true
    local emitted = lines(inst, function()
        for _ = 1, 20 do
            inst.NS.DebugSteady(1, "Aggregator", "window=%d rows=%d", 1, 2)
            inst.NS.DebugSteady(1, "Aggregator", "identity rows=%d keys=%d", 2, 3)
        end
    end)
    assertEqual(#emitted, 2, "two call sites sharing a tag defeated each other's comparison")
end)
