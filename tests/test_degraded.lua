-- tests/test_degraded.lua — the whole addon, loaded with LibKa0s ABSENT.
--
-- Six files in this addon reach for a LibKa0s major and each carries a
-- degradation branch: core/CoreSetup.lua, core/PerfSetup.lua,
-- core/DebugLogSetup.lua, settings/Slash.lua, settings/OptionsSetup.lua and
-- modules/Export.lua. This suite is the only place all six are exercised, and
-- it exercises them BY ACTUALLY LOADING THE ADDON WITHOUT THE LIBRARY —
-- `T.load{ libFiles = {} }` — never by hand-stubbing the member under test
-- (testing-§8).
--
-- The difference matters. Hand-stubbing proves that the stub you just wrote
-- answers the call you just made. A real load proves that thirty-odd files
-- SURVIVE the absence in the order the client loads them, which is the failure
-- that actually ships.
--
-- ---------------------------------------------------------------------------
-- THE MEASURABLE ONE
-- ---------------------------------------------------------------------------
--
-- settings/OptionsSetup.lua's stub exists for one reason, and it is not
-- politeness. Each settings/<page>.lua calls Helpers members INSIDE its
-- schema-row literals AT FILE LOAD — `H.LSMValues("font")` on every text row,
-- `H.SessionCheckbox()` on the General page. With those members nil the page file
-- RAISES, its RegisterSchemaRows never runs, and a third of NS.Schema is simply
-- missing — taking `/mm list`, `/mm get`, `/mm set`, `/mm reset` and every
-- profile default with it. The addon would not degrade; it would HALF-LOAD and
-- say nothing.
--
-- So the assertion that catches that is a count: NS.Schema must hold exactly as
-- many rows with the library gone as it does with the library present, row for
-- row and path for path. A missing member turns that count into a smaller number
-- and this case names the page that vanished.

local T = _G.MULTIMETERS_TEST
local test, assertEqual, assertTrue, assertFalse, assertNil =
    T.test, T.assertEqual, T.assertTrue, T.assertFalse, T.assertNil

local ROOT = T.root or "."

-- The five majors, and the file that reaches for each.
local SEAMS = {
    { major = "LibKa0s-Core-1.0",     file = "core/CoreSetup.lua" },
    { major = "LibKa0s-Perf-1.0",     file = "core/PerfSetup.lua" },
    { major = "LibKa0s-DebugLog-1.0", file = "core/DebugLogSetup.lua" },
    { major = "LibKa0s-Slash-1.0",    file = "settings/Slash.lua" },
    { major = "LibKa0s-Options-1.0",  file = "settings/OptionsSetup.lua" },
    { major = "LibKa0s-Widgets-1.0",  file = "modules/Export.lua" },
}

--- The whole addon loaded with libs/LibKa0s NOT in the load list. The lifecycle
--- kick still runs — InitDB, migrations, the options panel — because a degraded
--- install is still an install and still logs in.
local function degradedInstance()
    return T.load{ libFiles = {} }
end

--- The same addon with the library present, for the comparisons that only mean
--- something as a difference.
local function fullInstance()
    return T.load{}
end

-- ── the premise ─────────────────────────────────────────────────────────────

test("Degraded: the library really is absent, so every case below is measuring a stub", function()
    -- The inverse of test_coresetup's first case, and just as load-bearing: if
    -- the library were somehow still registered, every assertion in this file
    -- would be measuring the LIVE seam and passing for the wrong reason.
    local inst = degradedInstance()
    for _, seam in ipairs(SEAMS) do
        assertNil(inst.mocks.LibStub(seam.major, true),
            seam.major .. " is registered — this suite is not testing the degraded path at all")
    end
    -- And the addon still loaded: every core table is there.
    for _, name in ipairs({ "Compat", "Constants", "State", "Secrets", "Database", "L" }) do
        assertTrue(inst.NS[name] ~= nil, "NS." .. name .. " is missing after a degraded load")
    end
end)

test("Degraded: every seam soft-optionals its major, so a missing library is not a load error",
function()
    -- `LibStub("X", true)` — the silent flag. Without it LibStub RAISES on a
    -- missing major and the file never finishes, which is the load error the
    -- whole degradation design exists to avoid.
    -- red under: dropping the `, true` from any of the five lookups.
    for _, seam in ipairs(SEAMS) do
        local fh = assert(io.open(ROOT .. "/" .. seam.file, "r"))
        local src = fh:read("*a")
        fh:close()
        assertTrue(src:find('LibStub("' .. seam.major .. '", true)', 1, true) ~= nil,
            seam.file .. " does not soft-optional " .. seam.major)
    end
end)

-- ── each of the five takes its real fallback ────────────────────────────────

test("Degraded: core/CoreSetup.lua takes its fallback and the printer still works", function()
    -- Silence is not an option the way it is for a diagnostics harness: the
    -- printer is how the slash CLI answers, how the schema validator reports and
    -- how the meter-unavailable path explains itself.
    local inst = degradedInstance()
    assertEqual(type(inst.NS.Print), "function")
    assertTrue(inst.NS.Print == inst.NS.Util.print,
        "the two names must be ONE function on the degraded path too — the AceConsole reclaim "
        .. "in core/MultiMeters.lua compares them")

    inst.NS.Print("a degraded line")
    local chat = inst.mocks.__chat
    assertTrue(#chat > 0, "the fallback printer printed nothing")
    local text = table.concat(chat, "\n")
    assertTrue(text:find("a degraded line", 1, true) ~= nil)
    assertTrue(text:find(inst.NS.PREFIX, 1, true) ~= nil, "the fallback dropped the [MM] tag")
    assertTrue(text:find(inst.NS.LIBKA0S_MISSING, 1, true) ~= nil,
        "the honest 'not installed' line was never said")
end)

test("Degraded: the 'not installed' line is said ONCE, on the first line the addon prints",
function()
    -- Stapling it to every line turns a one-time fact into noise on a ticker.
    local inst = degradedInstance()
    for i = 1, 5 do inst.NS.Print("line " .. i) end
    local n = 0
    for _, line in ipairs(inst.mocks.__chat) do
        if line:find("reduced built-in fallbacks", 1, true) then n = n + 1 end
    end
    assertEqual(n, 1, "the degraded announcement was printed " .. n .. " times")
end)

test("Degraded: the secret-safe probe survives, because this addon's values are secret", function()
    -- The one thing the CoreSetup stub is allowed to reproduce, and the header
    -- says why: a probe is not rendering. It is the difference between a chat
    -- line and a Lua error on a coalesced refresh ticker.
    -- red under: `NS.SafeToString = tostring` in the fallback.
    local inst = degradedInstance()
    assertTrue(inst.NS.IsConcatSafe("text"))
    assertFalse(inst.NS.IsConcatSafe(inst.mocks.secret(1)))
    assertEqual(inst.NS.SafeToString(nil), "nil")
    assertEqual(inst.NS.SafeToString(12), "12")
    assertFalse(inst.NS.SafeToString(inst.mocks.secret(12)) == "12",
        "a secret rendered as its value on the degraded path")

    -- And a secret reaching the printer must not take it down.
    local ok, err = pcall(inst.NS.Print, "total", inst.mocks.secret(4200000))
    assertTrue(ok, "the fallback printer raised on a secret: " .. tostring(err))
end)

test("Degraded: the window chrome degrades to NOTHING rather than to a hand-copied backdrop",
function()
    -- Core.SKIN's values ARE the contract (standalone-windows), and a host copy
    -- is the copy that goes stale one hex digit at a time. SKIN is an empty
    -- TABLE rather than nil so modules/Window.lua may index it without a guard
    -- at every field; MakeCloseButton answers nil, which is exactly what the
    -- library's own does where CreateFrame is unavailable.
    -- red under: pasting Core.SKIN's values into the fallback.
    local inst = degradedInstance()
    assertEqual(type(inst.NS.SKIN), "table")
    assertNil(next(inst.NS.SKIN), "the degraded SKIN carries a copy of the library's values")
    assertEqual(type(inst.NS.ApplySkin), "function")
    inst.NS.ApplySkin(inst.mocks.__stubFrame("Frame"))   -- must not raise
    assertNil(inst.NS.MakeCloseButton(inst.mocks.__stubFrame("Frame")))
end)

test("Degraded: the stored-color reader does NOT degrade to nothing", function()
    -- Unlike SKIN. It is not chrome the user can live without — it is how every
    -- bar and every label gets its color out of the profile at all, and a
    -- degraded install still renders rows.
    -- red under: `NS.RGBA = function() end` in the fallback.
    local inst = degradedInstance()
    assertEqual(type(inst.NS.RGBA), "function")
    local r, g, b, a = inst.NS.RGBA({ r = 0, g = 0, b = 0, a = 0 }, 1, 1, 1, 1)
    assertEqual(r, 0); assertEqual(g, 0); assertEqual(b, 0); assertEqual(a, 0)
    local pr, pg, pb, pa = inst.NS.RGBA({ 0.25, 0.5, 0.75 }, 1, 1, 1, 0.5)
    assertEqual(pr, 0.25); assertEqual(pg, 0.5); assertEqual(pb, 0.75); assertEqual(pa, 0.5)
end)

test("Degraded: core/PerfSetup.lua takes its fallback and every bracket short-circuits", function()
    local inst = degradedInstance()
    local P = inst.NS.Perf
    assertEqual(P.on, false)
    assertEqual(P.suspended, false)
    for _, member in ipairs({ "Note", "Open", "Close", "OnCommand" }) do
        assertEqual(type(P[member]), "function", "the Perf stub omits " .. member)
    end
    -- The show ladder reads `Perf.suspended` as step 0 on BOTH paths, so a
    -- degraded install must not have every window refused for a capture that
    -- cannot exist.
    inst.mocks.setInstance("party")
    inst.mocks.setGroup({ {}, {}, {}, {}, {} })
    local ok, reason = inst.NS.ShouldShow(inst.NS.Database.GetWindows()[1])
    assertTrue(ok, "a degraded install refused a window for reason: " .. tostring(reason))
end)

test("Degraded: core/DebugLogSetup.lua takes its fallback and the flag still works", function()
    local inst = degradedInstance()
    assertEqual(type(inst.NS.Debug), "function")
    assertFalse(inst.NS.DebugLog:IsShown(), "there is no console to show")
    inst.NS.DebugLog:SetEnabled(true)
    assertTrue(inst.NS.State.debug, "the flag is ours and must still flip with no library")
end)

test("Degraded: settings/Slash.lua takes its fallback", function()
    local inst = degradedInstance()
    assertEqual(type(inst.NS.Slash.OnSlash), "function")
    assertEqual(type(inst.NS.COMMANDS), "table")
    assertTrue(#inst.NS.COMMANDS >= 15, "the verb table shrank on the degraded path")
end)

test("Degraded: settings/OptionsSetup.lua takes its fallback and says the panel is unavailable",
function()
    local inst = degradedInstance()
    assertEqual(type(inst.NS.Helpers), "table")
    assertEqual(type(inst.NS.CreateOptionsPanel), "function")
    assertTrue(inst.NS.OpenOptionsPanel == inst.NS.CreateOptionsPanel,
        "there is nothing to create and nothing to open — one honest line answers both")
    local before = #inst.mocks.__chat
    inst.NS.OpenOptionsPanel()
    assertTrue(#inst.mocks.__chat > before, "opening the panel said nothing at all")
    assertTrue(inst.mocks.__chat[#inst.mocks.__chat]:find("settings panel is unavailable", 1, true)
        ~= nil, "the degraded panel did not name its own consequence")
end)

-- ── /mm still answers ───────────────────────────────────────────────────────

test("Degraded: `/mm` with no arguments still prints help", function()
    -- `/mm` is registered unconditionally in Sl:Register, so something has to
    -- answer it. Swallowing the verb looks like the addon is not installed.
    local inst = degradedInstance()
    local before = #inst.mocks.__chat
    inst.NS.Slash:OnSlash("")
    local printed = #inst.mocks.__chat - before
    assertTrue(printed > #inst.NS.COMMANDS,
        "degraded help printed only " .. printed .. " lines for " .. #inst.NS.COMMANDS .. " verbs")
end)

test("Degraded: every declared verb is reachable and none of them raises", function()
    -- The degraded dispatcher walks the same NS.COMMANDS table the live one
    -- does, so a verb that raises here raises in game on exactly the install
    -- that has no console to read the error in.
    local inst = degradedInstance()
    for _, entry in ipairs(inst.NS.COMMANDS) do
        local ok, err = pcall(inst.NS.Slash.OnSlash, inst.NS.Slash, entry[1])
        assertTrue(ok, "/mm " .. entry[1] .. " raised on the degraded path: " .. tostring(err))
    end
end)

test("Degraded: the schema verbs NAME the missing library rather than going quiet", function()
    -- What is lost is the schema CLI. Each of those verbs says so; a silent
    -- `/mm list` reads as a bug in the addon.
    -- red under: making the degraded CliList a no-op.
    local inst = degradedInstance()
    for _, verb in ipairs({ "list", "get", "set", "reset", "resetall" }) do
        local before = #inst.mocks.__chat
        inst.NS.Slash:OnSlash(verb)
        local said = table.concat(inst.mocks.__chat, "\n", before + 1)
        assertTrue(said:find("is unavailable", 1, true) ~= nil,
            "/mm " .. verb .. " went quiet instead of naming the missing library")
        assertTrue(said:find(inst.NS.LIBKA0S_MISSING, 1, true) ~= nil,
            "/mm " .. verb .. " did not carry the shared cause clause")
    end
end)

test("Degraded: the host verbs are untouched, because they never went to the library", function()
    -- lock / preview / toggle / window / reset-positions act on WINDOWS, which
    -- the registry owns. The library's schema CLI has nothing to say about them.
    local inst = degradedInstance()
    local before = #inst.mocks.__chat
    inst.NS.Slash:OnSlash("window list")
    assertTrue(#inst.mocks.__chat > before, "/mm window list said nothing")

    before = #inst.mocks.__chat
    inst.NS.Slash:OnSlash("test")
    assertTrue(inst.NS.State.testMode, "/mm test did not take effect on the degraded path")
    assertTrue(#inst.mocks.__chat > before, "/mm test did not acknowledge")

    inst.NS.Slash:OnSlash("window new Second")
    assertEqual(#inst.NS.Database.GetWindows(), 2, "/mm window new did not create a window")
end)

test("Degraded: an unknown verb is named and followed by help", function()
    local inst = degradedInstance()
    local before = #inst.mocks.__chat
    inst.NS.Slash:OnSlash("nonsense")
    local said = table.concat(inst.mocks.__chat, "\n", before + 1)
    assertTrue(said:find("unknown command 'nonsense'", 1, true) ~= nil, "got: " .. said)
end)

test("Degraded: `/mm version` still answers with the packaged version", function()
    local inst = degradedInstance()
    local before = #inst.mocks.__chat
    inst.NS.Slash:OnSlash("version")
    local said = table.concat(inst.mocks.__chat, "\n", before + 1)
    assertTrue(said:find(inst.NS.version, 1, true) ~= nil,
        "the degraded version verb said: " .. said)
end)

-- ── the load-completing options stub ────────────────────────────────────────

test("Degraded: the options stub publishes every Helpers member the page files touch", function()
    -- THE reason that stub exists. Every `H.<Name>` a settings page reaches for
    -- has to resolve to something callable, whether it comes from the stub or
    -- from a page file decorating the same instance in place.
    -- red under: dropping a name from settings/OptionsSetup.lua's no-op list.
    local inst = degradedInstance()
    local H = inst.NS.Helpers
    assertEqual(type(H), "table")

    local wanted, seen = {}, 0
    for _, rel in ipairs(T.loadedAddonFiles) do
        -- settings/OptionsSetup.lua itself is excluded: it is the file that
        -- BUILDS both surfaces, and the calls in its live branch
        -- (`Helpers.OpenOptionsPanel()`) are unreachable on the degraded path by
        -- construction. What this case is about is the PAGE files, which run on
        -- both paths and cannot tell which one they are on.
        if rel:lower():match("^settings/") and rel:lower() ~= "settings/optionssetup.lua" then
            local fh = assert(io.open(ROOT .. "/" .. rel, "r"))
            local src = fh:read("*a"):gsub("%-%-[^\r\n]*", "")
            fh:close()
            -- Only CALLS: `H.Foo(` / `Helpers.Foo(`. A bare mention in a table
            -- literal is not a member that has to answer.
            for name in src:gmatch("[^%w_]H%.([%w_]+)%s*%(") do wanted[name] = rel end
            for name in src:gmatch("[^%w_]Helpers%.([%w_]+)%s*%(") do wanted[name] = rel end
        end
    end
    local missing = {}
    for name, rel in pairs(wanted) do
        seen = seen + 1
        if type(H[name]) ~= "function" then
            missing[#missing + 1] = name .. " (called from " .. rel .. ")"
        end
    end
    table.sort(missing)
    -- A canary on the SCAN, not a budget on the pages: if this collapses, the
    -- pattern above stopped matching and every assertion below it is vacuous.
    --
    -- Was 15 until settings/General.lua stopped drawing Test mode and the debug
    -- console by hand. Both are `sessionOnly` SCHEMA rows and were being rendered
    -- twice — once by RenderSchema and once bespoke — which put two "Preview
    -- mode" checkboxes and two "Debug" headings on the page. Deleting the bespoke
    -- pair took H.SessionCheckbox's last call site with it.
    assertTrue(seen >= 14, "the Helpers scan found only " .. seen .. " members — it drifted")
    assertEqual(table.concat(missing, ", "), "",
        "these Helpers members are called by a settings page and are nil with no library")
end)

test("Degraded: LSMValues keeps its DEFERRED shape and never answers an empty list", function()
    -- On the live path it is a closure resolved at dropdown-render time, because
    -- the addons that register media have not run when a row is DECLARED. The
    -- stub keeps the deferral for the same reason the library never answers
    -- empty: a dropdown with no options cannot be opened, and the CLI would then
    -- refuse even the value already stored.
    -- red under: `Helpers.LSMValues = function() return {} end`.
    local inst = degradedInstance()
    local deferred = inst.NS.Helpers.LSMValues("font")
    assertEqual(type(deferred), "function", "LSMValues must answer a closure, not a table")
    local values = deferred()
    assertEqual(type(values), "table")
    assertTrue(next(values) ~= nil, "the degraded dropdown would have no options at all")
end)

test("Degraded: reset-everything still works, and still refuses to touch the Profiles page",
function()
    -- The user whose panel will not open is exactly the user who needs "reset
    -- everything", and the schema loaded fine — so the reset works with no panel
    -- at all. The profiles veto is enforced TWICE, by the library through
    -- descriptor.skipRestoreAll and by this stub's own loop, because two
    -- spellings of one predicate is how a reset ends up deleting profiles on
    -- exactly the install nobody tests.
    -- red under: dropping the vetoedFromResetAll guard from the stub's loop.
    local inst = degradedInstance()
    local applied = {}
    local realApplyDefault = inst.NS.ApplyDefault
    inst.NS.ApplyDefault = function(row)
        applied[#applied + 1] = row.page
        return realApplyDefault(row)
    end
    inst.NS.Helpers.RestoreAllDefaults()
    inst.NS.ApplyDefault = realApplyDefault

    assertTrue(#applied > 0, "the degraded reset applied no defaults at all")
    for _, page in ipairs(applied) do
        assertFalse(page == "profiles", "the degraded reset touched a profiles row")
    end
end)

-- ── the measurable one ──────────────────────────────────────────────────────

test("Degraded: the schema row count is UNCHANGED versus a full load", function()
    -- THE case this suite exists for. A page file that raises at load takes its
    -- RegisterSchemaRows with it, and a third of NS.Schema simply never appears
    -- — with `/mm list`, `/mm get`, `/mm set`, `/mm reset` and every profile
    -- default broken behind it, silently.
    -- red under: deleting any name from settings/OptionsSetup.lua's no-op list.
    local full     = fullInstance().NS
    local degraded = degradedInstance().NS

    assertTrue(#full.Schema > 50,
        "the full schema holds only " .. #full.Schema .. " rows — the baseline is wrong")
    assertEqual(#degraded.Schema, #full.Schema,
        "a settings page raised at load and took its schema rows with it")
end)

test("Degraded: the schema is the same rows, path for path and page for page", function()
    -- The count alone could be matched by a page that lost two rows while
    -- another gained two. Compare the paths, and the per-page tallies with them,
    -- so the failure NAMES the page that vanished.
    local full     = fullInstance().NS
    local degraded = degradedInstance().NS

    local function index(schema)
        local paths, perPage = {}, {}
        for _, row in ipairs(schema) do
            paths[#paths + 1] = tostring(row.path)
            perPage[row.page or "?"] = (perPage[row.page or "?"] or 0) + 1
        end
        table.sort(paths)
        return paths, perPage
    end

    local fullPaths, fullPages = index(full.Schema)
    local degPaths,  degPages  = index(degraded.Schema)

    for page, n in pairs(fullPages) do
        assertEqual(degPages[page] or 0, n,
            "the '" .. page .. "' page lost rows on the degraded load")
    end
    for page in pairs(degPages) do
        assertTrue(fullPages[page] ~= nil, "the degraded load invented a page: " .. page)
    end
    assertEqual(table.concat(degPaths, "\n"), table.concat(fullPaths, "\n"),
        "the degraded schema is not the same set of paths")
end)

test("Degraded: every schema page is registered as an options page on both paths", function()
    -- The other half of "the pages all finished loading": a page file may
    -- register its rows and still have raised before it registered the page
    -- builder, which is a page that exists in `/mm list` and nowhere in the UI.
    local degraded = degradedInstance().NS
    local pages = {}
    for _, row in ipairs(degraded.Schema) do pages[row.page or "?"] = true end
    assertTrue(next(pages) ~= nil, "the degraded schema declares no pages at all")
    -- Every page a row claims must be one this build knows how to render on the
    -- full path; the degraded path has no renderer, which is the whole point.
    local full = fullInstance().NS
    local fullPages = {}
    for _, row in ipairs(full.Schema) do fullPages[row.page or "?"] = true end
    for page in pairs(pages) do
        assertTrue(fullPages[page], "the degraded load declares a page the full load does not: "
            .. page)
    end
end)

-- ── the whole namespace, compared ───────────────────────────────────────────

test("Degraded: the namespace publishes the same seam members with and without the library",
function()
    -- Surface parity over the five seams at once. Three of this collection's
    -- surviving High findings are one omitted stub member: a stub returns
    -- without assigning a name, so the command raises on exactly the degraded
    -- path the stub exists to survive.
    local full     = fullInstance().NS
    local degraded = degradedInstance().NS
    for _, name in ipairs({ "Print", "Format", "IsConcatSafe", "SafeToString", "RGBA",
                            "ApplySkin", "MakeCloseButton", "Debug",
                            "RegisterOptionsPage", "RefreshOptionsPanel",
                            "CreateOptionsPanel", "OpenOptionsPanel" }) do
        assertEqual(type(degraded[name]), type(full[name]),
            "NS." .. name .. " is " .. type(full[name]) .. " live and "
            .. type(degraded[name]) .. " degraded")
    end
end)

test("Degraded: every NS.Perf member the addon actually reaches exists on the stub", function()
    -- Deliberately NOT full surface parity against the library instance. The
    -- library's surface is the whole capture harness — Start, Measure, Save,
    -- FormatReport, the panel — and core/PerfSetup.lua's stub says in its own
    -- header that it covers EVERY MEMBER THE ADDON REACHES and no more. That is
    -- the right contract, and the assertion has to match it: reproducing the
    -- library's surface in the stub is the duplicate testing-§8 forbids.
    --
    -- So the wanted set is GREPPED out of the addon, which makes it move on its
    -- own the moment a module reaches for something new.
    -- red under: adding `Perf.Start(...)` to a module without extending the stub.
    local full     = fullInstance().NS
    local degraded = degradedInstance().NS

    local wanted = {}
    for _, rel in ipairs(T.loadedAddonFiles) do
        -- core/PerfSetup.lua is excluded: it is the file that BUILDS both
        -- surfaces, so its own mentions are definitions rather than uses.
        if rel:lower() ~= "core/perfsetup.lua" then
            local fh = assert(io.open(ROOT .. "/" .. rel, "r"))
            local src = fh:read("*a"):gsub("%-%-[^\r\n]*", "")
            fh:close()
            for name in src:gmatch("[^%w_]Perf%.([%w_]+)") do wanted[name] = rel end
        end
    end

    local n = 0
    for name, rel in pairs(wanted) do
        n = n + 1
        assertEqual(type(degraded.Perf[name]), type(full.Perf[name]),
            "NS.Perf." .. name .. " (reached from " .. rel .. ") is "
            .. type(full.Perf[name]) .. " live and " .. type(degraded.Perf[name]) .. " degraded")
    end
    assertTrue(n >= 4, "the Perf member scan found only " .. n .. " members — it drifted")
end)

-- ── the sixth seam: modules/Export.lua ──────────────────────────────────────

test("Degraded: the export modal refuses to open with no dropdown widget", function()
    -- Spec §10. Three labels that open nothing is a worse answer than a
    -- sentence: it looks like the addon is broken rather than like a library is
    -- missing.
    -- red under: an Open that builds the frame and lets the selectors be nil.
    local inst = degradedInstance()
    assertNil(inst.NS.Export.Open({}))
    assertTrue(#inst.mocks.__chat > 0, "and it says why, in chat")
end)

test("Degraded: the addon still enables end to end with no library", function()
    -- The lifecycle cascade is where a nil member finally raises. Loading is not
    -- enough: the client runs OnEnable at PLAYER_LOGIN, and a degraded install
    -- gets there too.
    local inst = T.load{ libFiles = {}, enable = true }
    for _, name in ipairs({ "Provider", "Roster", "Aggregator", "WindowManager",
                            "Tooltip", "DrillDown", "Visibility" }) do
        assertTrue(inst.NS:GetModule(name, true) ~= nil, name .. " did not survive a degraded load")
    end
    -- And a full meter tick fans out without raising.
    inst.NS:__fireEvent("DAMAGE_METER_CURRENT_SESSION_UPDATED")
    inst.NS:__fireEvent("GROUP_ROSTER_UPDATE")
    inst.mocks.__flushTimers()
end)
