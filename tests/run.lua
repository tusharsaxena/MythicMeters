-- tests/run.lua — the headless runner (testing-§1).
--
--   lua tests/run.lua            -- from anywhere; exits non-zero on any failure
--   lua tests/run.lua --list     -- emit docs/test-cases.md's body and exit 0
--
-- The registry, the assertion set, the skip status, the suite-inventory gate, the
-- `--list` renderer and the source loader all belong to the VENDORED KIT
-- (tests/_kit/, from LibKa0s — never edited here; tests/test_vendor_sync.lua is
-- the byte-identity gate). What stays in this file is only what is genuinely Ka0s
-- Mythic Meters': the two load lists, the instance factory, the lifecycle kick,
-- and the suite list.
--
-- COLLECT-THEN-RUN. The kit's `test()` only RECORDS; nothing executes until
-- Kit.run. That is why `--list` cannot disagree with the run it enumerates —
-- it is a pure filter over the same registry rather than a second code path.

-- Resolve the repo root from this script's path so it runs from anywhere.
local root = (arg and arg[0] and arg[0]:match("^(.*)/tests/run%.lua$")) or "."
package.path = root .. "/tests/?.lua;" .. package.path

local Kit    = dofile(root .. "/tests/_kit/framework.lua")
local Loader = dofile(root .. "/tests/_kit/loader.lua")
-- loadfile-and-call rather than dofile, so the mock builder is handed `root` and
-- can resolve tests/_kit/mock_base.lua — the base it layers over — without
-- assuming the process's working directory.
local mockmod = assert(loadfile(root .. "/tests/wow_mock.lua"))(root)

-- Every addon chunk is called as chunk("MythicMeters", NS), reproducing the
-- client's `local addonName, NS = ...` header. Library chunks ignore the varargs.
Loader.addonName = "MythicMeters"

-- ---------------------------------------------------------------------------
-- The vendored library load list
-- ---------------------------------------------------------------------------
--
-- Every file of libs/LibKa0s/LibKa0s.xml, in the XML's own order — DERIVED FROM
-- THE XML, never typed here (testing-§9).
--
-- The TOC pulls the whole library in through that one `.xml`, which
-- Loader.tocFiles deliberately skips, so every runner in the collection used to
-- re-type the same eight-entry list. Eight hand-typed copies of one list is eight
-- chances to drop an entry, and one of them did: a sibling addon's runner named
-- six of the eight and NOTHING NOTICED, because a short load list does not raise.
-- It leaves the dependent major unregistered, the host's setup file falls back to
-- its degradation stub, and the suite happily measures the stub — green, and
-- testing nothing (testing-§9).
--
-- Order comes out of the XML and matters: Core.lua registers first because the
-- other majors `return` before LibStub:NewLibrary without it, and the two Options
-- attachment files must follow their shell. Loader.xmlFiles preserves XML order
-- and RAISES on a missing XML rather than returning an empty list, which would
-- load nothing at all and read exactly like a clean run.
--
-- The assertion below is the belt to that braces. It names the majors this addon
-- actually reaches for — core/CoreSetup.lua, core/PerfSetup.lua,
-- core/DebugLogSetup.lua, settings/Slash.lua and settings/OptionsSetup.lua each
-- take a degradation branch when theirs is missing — so a re-vendor that drops a
-- file fails HERE, with a name, rather than silently downgrading five seams.
local LIB_FILES = Loader.xmlFiles(root .. "/libs/LibKa0s/LibKa0s.xml")

do
    local EXPECTED = {
        "Core.lua", "DebugLog.lua", "Slash.lua", "Options.lua",
        "OptionsWidgets.lua", "OptionsScroll.lua", "Perf.lua", "PerfPanel.lua",
    }
    local present = {}
    for _, path in ipairs(LIB_FILES) do
        present[path:match("([^/]+)$") or path] = true
    end
    local missing = {}
    for _, name in ipairs(EXPECTED) do
        if not present[name] then missing[#missing + 1] = name end
    end
    assert(#missing == 0,
        "libs/LibKa0s/LibKa0s.xml is missing " .. table.concat(missing, ", ")
        .. " — the vendored library is incomplete, and every LibKa0s seam in this "
        .. "addon would silently take its degradation stub")
end

-- The addon's own files, in TOC order. Repo-relative (`core/Compat.lua`), because
-- that is what the TOC says; only the loader needs them resolved. DERIVED, so the
-- runner cannot drift from what the client loads.
local ADDON_FILES = Loader.tocFiles(root .. "/MythicMeters.toc")

--- Repo-relative paths resolved against the root this script was invoked through.
local function rooted(list)
    local out = {}
    for i, rel in ipairs(list) do out[i] = root .. "/" .. rel end
    return out
end

-- ---------------------------------------------------------------------------
-- Instance factory: a fully-loaded, isolated addon environment
-- ---------------------------------------------------------------------------

--- Load a fresh, isolated addon instance under its own mock.
---
--- @param opts table|nil {
---   initDB   = boolean,   run NS:InitDB() + NS:RunMigrations() (default true)
---   options  = boolean,   run NS.CreateOptionsPanel()          (default true)
---   enable   = boolean,   run every module's OnEnable, then the addon's
---   mutate   = function(mocks), applied to the fresh mock BEFORE any source
---              loads — for suites that must change the simulated client before
---              a load-time read happens (the enum fallbacks in
---              core/Constants.lua and core/Secrets.lua are resolved at LOAD,
---              so `Enum` has to be wrong before the file runs, not after)
---   libFiles = table,     overrides LIB_FILES. Pass `{}` to load the addon with
---              LibKa0s ABSENT — the degraded scenario testing-§8 requires to be
---              exercised by a real load rather than by hand-stubbing the member
---              under test.
--- }
--- @return table inst  { NS = ..., mocks = ... }
---
--- Isolation is per-instance and comes from the mock, not from the process: the
--- kit's loader resolves every WoW global through THIS instance's `mocks` table,
--- and every symbol the addon publishes lands on THIS instance's `NS`. There is no
--- `_G.MythicMeters` rebind to share — the namespace stays private
--- (architecture-§1) — and no source file in this addon writes a global other
--- than its two SavedVariables tables, which are cleared below.
local function loadInstance(opts)
    opts = opts or {}
    local mocks = mockmod.build()
    if opts.mutate then opts.mutate(mocks) end

    -- `_G` MUST resolve to a table that answers from THIS instance's mocks.
    -- Nearly every client-API read in this addon is written `_G.C_DamageMeter`,
    -- `_G.canaccessvalue`, `_G.UnitGUID` — explicit, because architecture-§1
    -- forbids the deprecated bare globals and the `_G.` prefix is what makes a
    -- Compat-bypassing read visible in review. The kit's loader gives each chunk
    -- an environment whose `__index` falls through to the REAL `_G`, and the real
    -- `_G` has none of the client API in it, so an unbound `_G.X` would read nil
    -- and every secret-value case would silently measure the absent-API fallback
    -- instead of the API. Publishing that environment AS `mocks._G` closes it.
    mocks._G = Loader.makeEnv(mocks)

    -- The SavedVariables globals are process-wide (the loader's __newindex sends
    -- writes to the real _G, deliberately, so a migration path behaves as it does
    -- in the client). Clearing them per instance is what keeps two instances from
    -- inheriting each other's database.
    _G.MythicMetersDB     = nil
    _G.MythicMetersPerfDB = nil

    local NS = {}
    Loader.loadAll(opts.libFiles or LIB_FILES, NS, mocks)
    Loader.loadAll(rooted(ADDON_FILES), NS, mocks)

    -- ── the lifecycle kick, in the client's own order ──────────────────────
    --
    -- core/MythicMeters.lua's OnInitialize does exactly this: InitDB, then
    -- RunMigrations, then the minimap launcher, then the options panel, then the
    -- slash registration. It is spelled out here rather than called through
    -- OnInitialize so a suite can stop after any step — and so the standard's four
    -- lifecycle steps are visible in the runner rather than implied by one call.
    if opts.initDB ~= false then
        if NS.InitDB then NS:InitDB() end
        if NS.RunMigrations then NS:RunMigrations() end
    end
    if opts.options ~= false and NS.CreateOptionsPanel then
        NS.CreateOptionsPanel()
    end

    -- Module OnEnable is the client's job and there is no client here. Opt-in,
    -- because most suites want the modules loaded but NOT subscribed — a bus
    -- subscription made during load is one more thing every unrelated case has to
    -- reason about.
    if opts.enable and NS.__enableAll then
        NS:__enableAll()
        if mocks.__flushTimers then mocks.__flushTimers() end
    end

    return { NS = NS, mocks = mocks }
end

-- The shared instance most suites use: fully loaded, DB built, options panel
-- created, modules NOT enabled.
local shared = loadInstance()

-- ---------------------------------------------------------------------------
-- Suites
-- ---------------------------------------------------------------------------
--
-- BASENAMES, no extension — the kit appends it. Kit.run asserts this list against
-- tests/ IN BOTH DIRECTIONS before it loads a single case: a declared suite with
-- no file on disk is a hard error, and a `tests/test_*.lua` that is not declared
-- here is one too. Neither is a skip. A suite that is still being written is
-- declared as `{ name = "test_foo", pending = "why" }` and MUST lose that field
-- the moment its file lands.
local SUITES = {
    -- structure and the shared vocabulary
    "test_loadorder",
    "test_constants",
    "test_secrets",
    "test_compat",
    "test_state",
    "test_locale",
    -- database and defaults
    "test_database",
    "test_diagnostics",
    "test_defaults",
    -- the five LibKa0s seams and the addon lifecycle
    "test_coresetup",
    "test_perfsetup",
    "test_debuglogsetup",
    "test_lifecycle",
    "test_vendor_sync",
    -- the data path
    "test_format",
    "test_provider",
    "test_roster",
    "test_aggregator",
    "test_aggregator_sort",
    -- the display
    "test_window",
    "test_row",
    "test_targets",
    "test_tooltip",
    "test_drilldown",
    "test_export",
    "test_visibility",
    "test_windowmanager",
    "test_minimap",
    -- settings and the CLI
    "test_schema",
    "test_schema_defaults",
    "test_slash",
    "test_options_panel",
    "test_columns",
    -- and the whole addon with LibKa0s absent
    "test_degraded",
}

-- ---------------------------------------------------------------------------
-- The exposed contract
-- ---------------------------------------------------------------------------
--
-- Kit.expose merges the registry and every assertion into this table, so the
-- suites reach `T.test`, `T.assertEqual`, `T.skip`, `T.assertSurfaceParity` and
-- the rest off the same global they reach `T.NS` off.
_G.MYTHICMETERS_TEST = Kit.expose{
    root  = root,
    -- the shared instance
    NS    = shared.NS,
    mocks = shared.mocks,
    -- a fresh isolated instance, for migration / degradation / load-order cases
    load  = loadInstance,
    -- The three lists testing-§9 makes assertable: the suite list, the derived
    -- library load list exactly as it was fed to the loader, and the TOC-derived
    -- addon list.
    suites           = SUITES,
    libFiles         = LIB_FILES,
    loadedAddonFiles = ADDON_FILES,
    Loader           = Loader,
}

Kit.run{ dir = root .. "/tests/", suites = SUITES }
