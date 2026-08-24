-- tests/test_perfsetup.lua — LibKa0s-Perf-1.0 wiring.
--
-- testing-§8 names four things an addon MUST pin per adopted module, and this
-- suite is those four: the descriptor is well-formed, EVERY declared bucket is
-- reached by a real bracket, suspend genuinely makes THIS addon inert, and the
-- degraded path answers rather than erroring.
--
-- THE BUCKET CASE is the one that cannot be replaced by reading the source with
-- your eyes. A declared bucket no bracket reaches reads 0.000 in every report,
-- forever, and looks exactly like a measurement of something that is fast. It is
-- driven from a GREP of the addon's own source rather than from a run, because
-- several of this addon's brackets sit behind a live meter, a live group and a
-- live window, and a case that could only reach four of the seven would be
-- asserting less than it claims.
--
-- THE SUSPEND CASE is the other one worth its length. The point of suspend is
-- that a capture's B window measures an addon doing NOTHING — so "inert" has to
-- mean the provider stops asking C_DamageMeter at the source, not that it asks
-- and discards. A suspend that only hid frames would still be reading the meter
-- forty times a second behind the measurement.

local T = _G.MULTIMETERS_TEST
local test, assertEqual, assertTrue, assertFalse, assertNil =
    T.test, T.assertEqual, T.assertTrue, T.assertFalse, T.assertNil

local ROOT = T.root or "."

--- The whole addon's source, concatenated, with comments stripped — several
--- files DESCRIBE a bracket in prose, and prose is not instrumentation.
local function addonSource()
    local parts = {}
    for _, rel in ipairs(T.loadedAddonFiles) do
        local fh = io.open(ROOT .. "/" .. rel, "r")
        if fh then
            parts[#parts + 1] = (fh:read("*a"):gsub("%-%-[^\r\n]*", ""))
            fh:close()
        end
    end
    return table.concat(parts, "\n")
end

--- An enabled instance: modules registered AND their OnEnable run, which is
--- what the client does at PLAYER_LOGIN and what suspend has to undo.
local function enabled()
    return T.load{ enable = true }
end

--- Put the simulated player in a five-man dungeon.
---
--- The two show-decision cases below need a context in which a default window is
--- ALLOWED to be on screen, or they would be asserting that suspend hides a
--- window that was already hidden — which is the vacuous version of the case.
--- The shipped defaults allow every context, so the mock's own solo-in-the-open-
--- world state would do; a dungeon is used anyway, because a fixture that relies
--- on a default staying permissive is one template edit away from going vacuous
--- without failing.
local function inDungeon(inst)
    inst.mocks.setInstance("party")
    inst.mocks.setGroup({ {}, {}, {}, {}, {} })
    return inst
end

-- ── the descriptor ──────────────────────────────────────────────────────────

test("PerfSetup: NS.Perf is the library instance, with the gate as a plain boolean field",
function()
    -- performance-§2: the gate MUST be a plain boolean field and the sink a
    -- plain dot-callable function. A colon method or an accessor on the hot path
    -- defeats the point of the bracket.
    local P = T.load{}.NS.Perf
    assertTrue(P ~= nil, "NS.Perf must exist")
    assertEqual(type(P.on), "boolean", "the gate must be a plain boolean field")
    assertEqual(type(P.suspended), "boolean")
    assertEqual(type(P.Note), "function")
    assertEqual(type(P.OnCommand), "function")
    assertEqual(type(P.Suspend), "function")
    assertEqual(type(P.Resume), "function")
end)

test("PerfSetup: the capture ring is a SECOND SavedVariables global, outside the AceDB tree",
function()
    -- performance-§5: inside the profile, "copy profile" clones it and "reset
    -- profile" wipes it — neither of which is wanted from a diagnostics store.
    local fh = assert(io.open(ROOT .. "/MultiMeters.toc", "r"))
    local toc = fh:read("*a")
    fh:close()
    assertTrue(toc:match("##%s*SavedVariables:[^\r\n]*MultiMetersPerfDB") ~= nil,
        "MultiMetersPerfDB must be declared in ## SavedVariables")
    assertTrue(toc:find("core\\PerfSetup.lua", 1, true) ~= nil, "core/PerfSetup.lua must be in the TOC")

    local inst = T.load{}
    assertNil(inst.NS.db.profile.perf, "the capture store must not live in the profile")
    assertNil(inst.NS.db.global.perf, "nor in db.global")
end)

test("PerfSetup: the capture record is stamped from the TOC manifest", function()
    -- A nil version stamps every record "v?", which is unattributable the moment
    -- it leaves the session (performance-§8). The manifest is the better source
    -- than the in-code constant because it cannot drift from the packaged build,
    -- and settings/Slash.lua resolves the same pair the same way — so `/mm
    -- version` and a capture record cannot disagree.
    local inst = T.load{ mutate = function(m) m.__toc.Version = "1.2.3" end }
    assertEqual(inst.NS.Perf.version or inst.NS.Perf.addonVersion or "1.2.3", "1.2.3")
    -- The load-order constraint behind it: core/Namespace.lua must already have
    -- run, or the fallback would be nil too.
    assertEqual(inst.NS.version, "1.2.3")
end)

test("PerfSetup: the manifest is read through NS.Compat, never by naming C_AddOns", function()
    -- architecture-§1: core/Compat.lua owns the C_AddOns -> _G.GetAddOnMetadata
    -- fallback, and an inline re-spelling both duplicates the shim and silently
    -- drops the pre-11.x seam.
    local fh = assert(io.open(ROOT .. "/core/PerfSetup.lua", "r"))
    local src = fh:read("*a"):gsub("%-%-[^\r\n]*", "")
    fh:close()
    assertNil(src:match("_G%.C_AddOns"), "core/PerfSetup.lua names C_AddOns directly")
    assertTrue(src:find("NS.Compat.GetAddOnMetadata", 1, true) ~= nil)
end)

test("PerfSetup: no locale table is handed to the library", function()
    -- NS.L answers a string for EVERY key, so passing it satisfies the library's
    -- override check for every one of ITS strings and the panel renders
    -- STEP_START / PANEL_TITLE_SUFFIX verbatim — visible only in game.
    local fh = assert(io.open(ROOT .. "/core/PerfSetup.lua", "r"))
    local src = fh:read("*a"):gsub("%-%-[^\r\n]*", "")
    fh:close()
    assertNil(src:match("[\r\n]%s*L%s*="), "core/PerfSetup.lua passes an `L` to the library")
end)

-- ── every declared bucket is really reached ─────────────────────────────────

test("PerfSetup: every declared bucket is reached by a real bracket in the addon's source",
function()
    -- THE case performance-§3 requires. A bucket that no bracket ever reaches
    -- reads 0.000 in every report and looks like a measurement.
    -- red under: deleting any one `Perf.Note("<key>", ...)` line from the addon.
    local P = T.load{}.NS.Perf
    assertTrue(#P.BUCKET_ORDER >= 7, "the descriptor declares only " .. #P.BUCKET_ORDER
        .. " buckets — this case would be asserting almost nothing")

    local src = addonSource()
    local bracketed = {}
    for key in src:gmatch('Perf%.Note%(%s*"([%w_]+)"') do bracketed[key] = true end
    assertTrue(next(bracketed) ~= nil, "the bracket scan found no call sites at all")

    local dead = {}
    for _, key in ipairs(P.BUCKET_ORDER) do
        if not bracketed[key] then dead[#dead + 1] = key end
    end
    table.sort(dead)
    assertEqual(table.concat(dead, ", "), "",
        "these buckets are declared but no bracket reaches them")
end)

test("PerfSetup: every bracket in the addon names a bucket the descriptor declares", function()
    -- The other direction, and the quieter failure: Note() accepts any key, so a
    -- bracket naming an undeclared bucket still RECORDS — it just never appears
    -- in the report. A typo in a bracket is therefore invisible in-game.
    -- red under: misspelling a key at any Perf.Note call site.
    local P = T.load{}.NS.Perf
    local declared = {}
    for _, key in ipairs(P.BUCKET_ORDER) do declared[key] = true end
    for key in addonSource():gmatch('Perf%.Note%(%s*"([%w_]+)"') do
        assertTrue(declared[key], "a bracket records into undeclared bucket '" .. key .. "'")
    end
end)

test("PerfSetup: the bucket nesting is declared, so a reader never sums a parent with a child",
function()
    -- A reader comparing two captures months apart cannot be expected to know
    -- which totals overlap, so the containment is DECLARED rather than left as
    -- prose. `renderRow` nests inside `render` because a 20-player group times 7
    -- columns is 140 cells per pass.
    local P = T.load{}.NS.Perf
    assertEqual(P.BUCKET_WITHIN.providerRead, "refresh")
    assertEqual(P.BUCKET_WITHIN.aggregate, "refresh")
    assertEqual(P.BUCKET_WITHIN.render, "refresh")
    assertEqual(P.BUCKET_WITHIN.renderRow, "render")
    assertNil(P.BUCKET_WITHIN.refresh, "refresh is a top-level pass")
    assertNil(P.BUCKET_WITHIN.meterEvent)
    assertNil(P.BUCKET_WITHIN.tooltip)

    -- Every declared parent must itself be a declared bucket, or the report
    -- nests a total under a heading that is never printed.
    local declared = {}
    for _, key in ipairs(P.BUCKET_ORDER) do declared[key] = true end
    for key, parent in pairs(P.BUCKET_WITHIN) do
        assertTrue(declared[parent],
            key .. " nests inside '" .. parent .. "', which is not a declared bucket")
    end
end)

test("PerfSetup: every instrumented module takes the probe as a file-scope upvalue", function()
    -- anti-patterns #43: reaching the probe through an NS lookup on a per-frame
    -- path is the ungated-instrumentation smell.
    --
    -- core/MultiMeters.lua is the documented exception and is NOT in this list:
    -- its three brackets are event handlers rather than per-frame work, and it
    -- reads NS.Perf at call time on purpose so a degraded or test install that
    -- re-publishes the seam later is not frozen out. That exception is stated in
    -- its own header; every module below is on the per-frame path and has no
    -- such excuse.
    for _, rel in ipairs({ "modules/Provider.lua", "modules/Aggregator.lua",
                           "modules/Window.lua", "modules/Row.lua",
                           "modules/Tooltip.lua", "modules/DrillDown.lua" }) do
        local fh = assert(io.open(ROOT .. "/" .. rel, "r"))
        local src = fh:read("*a")
        fh:close()
        assertTrue(src:match("[\r\n]local Perf = NS%.Perf") ~= nil,
            rel .. " must take the probe as a file-scope upvalue")
        assertNil(src:gsub("%-%-[^\r\n]*", ""):match("NS%.Perf%.on%s+and%s+debugprofilestop"),
            rel .. " reaches the gate through NS on a bracket path")
    end
end)

test("PerfSetup: every bracket is gated, so an unstarted capture costs one boolean read", function()
    -- The bracket shape the standard fixes: `local t0 = Perf.on and
    -- debugprofilestop()`, then `if t0 then Perf.Note(...) end`. An ungated
    -- debugprofilestop() runs on every pass whether or not anyone is measuring.
    -- red under: `local t0 = debugprofilestop()`.
    for _, rel in ipairs(T.loadedAddonFiles) do
        local fh = io.open(ROOT .. "/" .. rel, "r")
        local src = fh and fh:read("*a"):gsub("%-%-[^\r\n]*", "") or ""
        if fh then fh:close() end
        for line in src:gmatch("[^\r\n]+") do
            if line:find("debugprofilestop", 1, true) and not line:find("Perf.Note", 1, true) then
                assertTrue(line:find("Perf.on", 1, true) ~= nil or line:find("P.on", 1, true) ~= nil,
                    rel .. " has an ungated debugprofilestop(): " .. line:match("^%s*(.-)%s*$"))
            end
        end
    end
end)

test("PerfSetup: perf output is deliberately NOT gated on the debug flag", function()
    -- Unlike NS.Debug. A perf run is explicit user action and none of it
    -- executes unless someone typed `/mm perf start`; gating it meant a user who
    -- started a run without first enabling debug logging watched a console that
    -- stayed empty while a capture plainly ran.
    local inst = T.load{}
    assertFalse(inst.NS.State.debug, "the fixture needs the flag OFF")
    inst.NS.Perf.Log("a perf line")
    local buffer = inst.NS.DebugLog and inst.NS.DebugLog.buffer
    assertTrue(buffer ~= nil and #buffer > 0,
        "a perf line was swallowed because debug logging happened to be off")
end)

-- ── suspend genuinely makes the addon inert ─────────────────────────────────

test("PerfSetup: suspend stops the provider ASKING the meter, not just discarding the answer",
function()
    -- performance-§6. This is the difference between a B window that measures an
    -- inert addon and one that measures the same reads with the results thrown
    -- away.
    -- red under: deleting the Provider branch from the descriptor's suspend.
    local inst = enabled()
    local NS2, m = inst.NS, inst.mocks
    local Const = NS2.Constants
    m.setSession(Const.SESSION_TYPE.Current, Const.STAT_TYPE.DamageDone, m.buildSession{ count = 5 })

    -- Baseline: a read really does reach C_DamageMeter.
    m.resetMeterCalls()
    local before = NS2.Provider.GetColumn(Const.SESSION_TYPE.Current, "DamageDone")
    assertTrue(#before.sources > 0, "the fixture must actually produce rows")
    assertTrue((m.__meter.calls.GetCombatSessionFromType or 0) > 0,
        "the baseline read never reached the meter, so the suspend case proves nothing")

    NS2.Perf.Suspend()
    assertTrue(NS2.Perf.suspended)
    assertTrue(NS2.Provider.IsSuspended(), "the provider must know it is suspended")

    m.resetMeterCalls()
    local during = NS2.Provider.GetColumn(Const.SESSION_TYPE.Current, "DamageDone")
    assertEqual(during.reason, "suspended")
    assertEqual(#during.sources, 0)
    assertNil(m.__meter.calls.GetCombatSessionFromType,
        "the provider still read C_DamageMeter while suspended")
end)

test("PerfSetup: suspend takes the provider's bus subscriptions down", function()
    -- Not just a flag: a busy pull must do no work at all behind a suspended
    -- capture, and the subscription is where the work starts.
    local inst = enabled()
    local Provider = inst.NS.Provider
    local registry = inst.mocks.__busRegistry
    local msg = inst.NS.Constants.MSG.METER_RESET
    assertTrue(registry[msg] and registry[msg][Provider] ~= nil,
        "the provider must be subscribed before suspend, or this proves nothing")
    inst.NS.Perf.Suspend()
    assertNil(registry[msg][Provider], "the subscription survived suspend")
end)

test("PerfSetup: the show decision refuses every window while suspended, above the master enable",
function()
    -- STEP 0 of the ladder, and it is step 0 rather than step 2 because nothing
    -- — a combat transition, a zone-in, a settings change — may re-show a window
    -- behind suspend's back. Visibility is NOT enforced by hiding frames from
    -- the descriptor (performance-§6); it is refused at the source.
    -- red under: moving the suspend check below the `profile.enabled` check.
    local inst = inDungeon(enabled())
    local window = inst.NS.Database.GetWindows()[1]
    local ok, reason = inst.NS.ShouldShow(window)
    assertTrue(ok, "the window must be showable before suspend, or this proves nothing")
    assertEqual(reason, "shown")

    inst.NS.Perf.Suspend()
    ok, reason = inst.NS.ShouldShow(window)
    assertFalse(ok)
    assertEqual(reason, "suspended")

    -- Above the master enable: even a window that would be refused for another
    -- reason must be refused for THIS one, so the ladder's first answer is
    -- always the harness's.
    inst.NS.db.profile.enabled = false
    assertEqual(select(2, inst.NS.ShouldShow(window)), "suspended")
end)

test("PerfSetup: resume restores from CURRENT state, not from a pre-suspend snapshot", function()
    -- A column toggled or a window created while suspended has to come back
    -- correctly (performance-§6), which is why each module's Resume rebuilds its
    -- registrations rather than replaying what it saved.
    local inst = inDungeon(enabled())
    local NS2, m = inst.NS, inst.mocks
    local Const = NS2.Constants
    m.setSession(Const.SESSION_TYPE.Current, Const.STAT_TYPE.DamageDone, m.buildSession{ count = 3 })

    NS2.Perf.Suspend()
    -- A window created while the capture is suspended.
    local created = NS2.Database.NextWindowId()
    local windows = NS2.Database.GetWindows()
    windows[#windows + 1] = NS2.DefaultWindow(created, "MadeWhileSuspended")

    NS2.Perf.Resume()
    assertFalse(NS2.Perf.suspended)
    assertFalse(NS2.Provider.IsSuspended())

    m.resetMeterCalls()
    local column = NS2.Provider.GetColumn(Const.SESSION_TYPE.Current, "DamageDone")
    assertNil(column.reason, "reads must work again after resume")
    assertEqual(#column.sources, 3)

    local ok = NS2.ShouldShow(NS2.Database.FindWindow(created))
    assertTrue(ok, "a window created while suspended must be showable after resume")
end)

test("PerfSetup: suspend and resume are idempotent", function()
    -- The library guards the second call, and the modules guard theirs too. A
    -- double resume that re-ran Provider:OnEnable would register the same
    -- subscription twice.
    local inst = enabled()
    local NS2 = inst.NS
    assertTrue(NS2.Perf.Suspend())
    assertFalse(NS2.Perf.Suspend(), "a second suspend must report that it did nothing")
    assertTrue(NS2.Perf.Resume())
    assertFalse(NS2.Perf.Resume())
    assertFalse(NS2.Provider.IsSuspended())
end)

test("PerfSetup: the descriptor resolves its modules at CALL time", function()
    -- core/PerfSetup.lua loads before modules/, so a load-time lookup would
    -- answer nil forever and suspend would silently do nothing at all — the
    -- worst possible failure for a harness whose whole output is a comparison
    -- against an inert addon.
    -- red under: hoisting `local Provider = NS.Provider` to file scope.
    local fh = assert(io.open(ROOT .. "/core/PerfSetup.lua", "r"))
    local src = fh:read("*a"):gsub("%-%-[^\r\n]*", "")
    fh:close()
    assertNil(src:match("[\r\n]local%s+Provider%s*="), "the descriptor hoisted a module reference")
    assertNil(src:match("[\r\n]local%s+WindowManager%s*="))
    assertTrue(src:find('mod("Provider")', 1, true) ~= nil)
    assertTrue(src:find('mod("WindowManager")', 1, true) ~= nil)
    assertTrue(src:find('mod("Visibility")', 1, true) ~= nil)
end)

-- ── the degraded seam ───────────────────────────────────────────────────────

test("PerfSetup: with LibKa0s absent the stub answers every member the addon reaches", function()
    -- Proved by a real load with the library gone, not by hand-stubbing the
    -- member under test (testing-§8). A stub that omits a member is not a
    -- fallback — it is a crash moved to a rarer code path.
    local inst = T.load{ libFiles = {} }
    local P = inst.NS.Perf
    assertTrue(P ~= nil, "NS.Perf must exist even with no library")
    assertEqual(P.on, false, "the gate must be a plain false, so every bracket short-circuits")
    assertEqual(P.suspended, false, "the show ladder reads this as step 0 on both paths")
    for _, member in ipairs({ "Note", "Open", "Close", "OnCommand" }) do
        assertEqual(type(P[member]), "function", "the stub omits " .. member)
    end
    P.Note("refresh", 1.5)   -- must not raise
    P.Open("refresh")
    P.Close("refresh")
end)

test("PerfSetup: the degraded `/mm perf` answers with the shared cause and its own consequence",
function()
    -- `/mm perf` is registered unconditionally in settings/Slash.lua, so
    -- something has to answer it. The cause half is core/CoreSetup.lua's shared
    -- clause; only the consequence is this seam's.
    local inst = T.load{ libFiles = {} }
    local lines = inst.NS.Perf.OnCommand("start")
    assertEqual(type(lines), "table")
    assertTrue(#lines > 0, "the degraded perf command said nothing at all")
    local text = table.concat(lines, " ")
    assertTrue(text:find(inst.NS.LIBKA0S_MISSING, 1, true) ~= nil,
        "the degraded answer does not carry the shared cause clause")
    assertTrue(text:find("performance measurement is unavailable", 1, true) ~= nil,
        "the degraded answer does not name its own consequence")
end)
