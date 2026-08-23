local addonName, NS = ...
NS.Slash = NS.Slash or {}
local Sl = NS.Slash

-- settings/Slash.lua — wires the addon into LibKa0s-Slash-1.0.
--
-- The dispatcher, the help renderer, the row and key/value formatters, the list
-- builder and the type-aware value parser live in libs/LibKa0s/Slash.lua and are
-- shared across every Ka0s addon. What stays ours is what is genuinely ours: the
-- verb table, the five host verbs that act on windows rather than on schema rows,
-- and the adapters that point the library's schema seams at this addon's write
-- seam.
--
-- ── WHY NS.COMMANDS IS POSITIONAL ───────────────────────────────────────────────
--
-- The entries are ORDERED POSITIONAL TRIPLES `{ name, description, handler }`.
-- That is the shape the library reads — `entry[1]`, `entry[2]`, `entry[3]` — and
-- a table of named fields (`{ name =, desc =, fn = }`) does not fail loudly: it
-- loads, dispatches nothing, and answers every verb the user types with "unknown
-- command". There is no error to read and nothing in the log.
--
-- The table STAYS THIS ADDON'S and is passed IN rather than owned, and that is
-- the load-bearing decision rather than an oversight: the settings landing page
-- renders these same rows, and if the library owned the table then the options
-- major drawing that page would have to resolve the slash major to read it — a
-- real dependency cycle between two majors at load time. Crossing between them as
-- plain data is what keeps them independent.
--
-- ── WHY THE HANDLERS RESOLVE LATE ───────────────────────────────────────────────
--
-- `cli` and every host verb below are FORWARD-DECLARED as locals above the table
-- and assigned beneath it. A handler therefore closes over the upvalue rather
-- than over its value, and resolves at CALL time — which is what lets the verb
-- table sit above the dispatcher it dispatches through, and lets the window verbs
-- reach modules/WindowManager.lua, which loads long after this file.
--
-- TOC POSITION: settings/, after core/CoreSetup.lua (the printer) and after the
-- schema seam this file's adapters call. Everything else is resolved through NS
-- at call time, so nothing further binds.

local function out(line)
    if NS.Print then NS.Print(line) end
end

--- The version the help header and `/mm version` both report. Read from the TOC
--- metadata first, so it cannot drift from the packaged manifest
--- (slash-commands-§3), with the in-code constant as the fallback for a client
--- without the metadata API. core/PerfSetup.lua resolves the same pair the same
--- way, so a capture record and `/mm version` cannot disagree.
---
--- The manifest is read through NS.Compat rather than by naming C_AddOns here:
--- core/Compat.lua owns the C_AddOns -> _G.GetAddOnMetadata fallback
--- (architecture-§1), so an inline re-spelling would both duplicate the shim and
--- drop the pre-11.x seam it exists to keep.
local function addonVersion()
    local get = NS.Compat and NS.Compat.GetAddOnMetadata
    local v = get and get(addonName, "Version")
    if type(v) == "string" and v ~= "" then return v end
    return NS.version or "?"
end
Sl.Version = addonVersion

-- Forward declarations. See "WHY THE HANDLERS RESOLVE LATE" above — every one of
-- these is assigned below the verb table that references it.
local cli
local doLock, doTest, doToggle, doWindow, doResetPositions, doExport, doDebug, doPerf

-- ---------------------------------------------------------------------
-- The verb table
-- ---------------------------------------------------------------------
--
-- The ten reserved verbs first, in the order slash-commands-§2 fixes, then this
-- addon's own. Every sub-verb a handler accepts is named in its own `desc`,
-- because the generated help index, the settings landing page and the README's
-- command table all read these strings and nothing else — a sub-verb missing here
-- is a sub-verb nobody can discover (slash-commands-§4).
NS.COMMANDS = {
    { "help",     "Show this help",            function() cli:PrintHelp() end },
    { "config",   "Open the settings panel",   function() if NS.OpenOptionsPanel then NS.OpenOptionsPanel() end end },
    { "list",     "List every setting",        function() cli:CliList() end },
    { "get",      "Read one setting: /mm get <path>",      function(a) cli:CliGet(a) end },
    { "set",      "Write one setting: /mm set <path> <value>", function(a) cli:CliSet(a) end },
    { "reset",    "Reset one setting: /mm reset <path>",   function(a) cli:CliReset(a) end },
    { "resetall", "Reset every setting to its default",    function() cli:CliResetAll() end },
    { "debug",    "Console; 'on'/'off' set logging, 'diag' a diagnostic report, 'recap' the death-recap probe",
                                                                     function(a) doDebug(a) end },
    { "perf",     "Performance capture; try /mm perf help", function(a) doPerf(a) end },
    { "version",  "Print the addon version",   function() cli:CliVersion() end },

    { "lock",     "Lock or unlock all windows for dragging",         function(a) doLock(a) end },
    { "test",     "Toggle test mode \226\128\148 placeholder rows for positioning",
                                                                     function(a) doTest(a) end },
    { "toggle",   "Show or hide a window by name, or all windows",   function(a) doToggle(a) end },
    { "window",   "Window management \226\128\148 list, new, delete, copy",
                                                                     function(a) doWindow(a) end },
    { "reset-positions", "Move every window back to the center of the screen",
                                                                     function(a) doResetPositions(a) end },
    { "export",   "Export a window's segment \226\128\148 /mm export [window]",
                                                                     function(a) doExport(a) end },
}

-- ---------------------------------------------------------------------
-- The degradation stub
-- ---------------------------------------------------------------------
--
-- `/mm` is registered unconditionally in Sl:Register, so something has to answer
-- it. The host verbs never went to the library, so they keep working untouched;
-- what is lost is the schema CLI, and each of those verbs NAMES the missing
-- library rather than going quiet.
--
-- Note what is NOT here: no copy of the row formatter, no copy of the key/value
-- shape, no copy of the value parser. Hand-copying the strings whose drift the
-- extraction exists to end is the one duplicate testing-§8 most specifically
-- forbids, so a degraded help row renders plainly and says so.
local SlashLib = LibStub and LibStub("LibKa0s-Slash-1.0", true)

if not SlashLib then
    -- The cause half is core/CoreSetup.lua's shared clause (NS.LIBKA0S_MISSING);
    -- only the consequence is this seam's. This is the one of the five whose
    -- consequence comes FIRST — the verb has to lead, or "/mm list" is buried
    -- mid-sentence — so it reads "<verb> is unavailable. <cause>."
    local missing = " is unavailable. " .. NS.LIBKA0S_MISSING .. "."

    SlashLib = {}
    SlashLib.ParseValue = function() return nil, "the LibKa0s library is missing" end
    -- Answers the member without owning the vocabulary. `nil` is the library's
    -- own "not a boolean word" signal, so `/mm lock on` degrades to a toggle
    -- rather than to a Lua error — see doLock.
    SlashLib.ParseBool  = function() return nil end

    function SlashLib:New(d)
        local stub = { SetRowAnnotator = function() end }
        local function absent(verb)
            return function() out(d.slash .. " " .. verb .. missing) end
        end
        for _, verb in ipairs({ "List", "Get", "Set", "Reset", "ResetAll" }) do
            stub["Cli" .. verb] = absent(verb:lower())
        end
        stub.CliVersion = function() out("v" .. tostring(d.version and d.version() or "?")) end
        stub.LandingRows = function()
            local rows = {}
            for _, e in ipairs(d.commands or {}) do
                rows[#rows + 1] = d.slash .. " " .. e[1] .. " \226\128\148 " .. e[2]
            end
            return rows
        end
        stub.HelpRows = function()
            local rows = {}
            for _, r in ipairs(stub.LandingRows()) do rows[#rows + 1] = "  " .. r end
            return rows
        end
        stub.PrintHelp = function()
            out("v" .. tostring(d.version and d.version() or "?") .. " slash commands")
            for _, r in ipairs(stub.HelpRows()) do out(r) end
        end
        stub.OnSlash = function(_, msg)
            local raw = (msg or ""):match("^%s*(.-)%s*$") or ""
            if raw == "" then return stub.PrintHelp() end
            local verb, rest = raw:match("^(%S+)%s*(.*)$")
            verb = (verb or ""):lower()
            verb = (d.aliases or {})[verb] or verb
            for _, e in ipairs(d.commands or {}) do
                if e[1] == verb then return e[3](rest or "") end
            end
            out("unknown command '" .. verb .. "'")
            stub.PrintHelp()
        end
        return stub
    end
end

-- ---------------------------------------------------------------------
-- The dispatcher
-- ---------------------------------------------------------------------

cli = SlashLib:New({
    slash        = "/mm",
    slashAliases = { "/multimeters" },
    commands     = NS.COMMANDS,
    aliases      = { options = "config" },   -- back-compat with the collection's older spelling

    print   = function(line) out(line) end,
    version = addonVersion,

    -- ── The schema seams ──────────────────────────────────────────────────
    --
    -- All five point at the addon's ONE write seam and ONE reader
    -- (settings-schema-§1), so a `/mm set` takes exactly the path a panel
    -- checkbox takes: same validation, same debug line at the seam, same
    -- onChange, same panel refresh.
    --
    -- This addon's twist is that a window row's path is RELATIVE — `window.frame.width`
    -- rather than `windows.<id>.frame.width` — and NS.GetSetting / NS.SetByPath
    -- resolve it against the session's active window. That resolution lives
    -- behind the seam rather than here, which is exactly why the CLI can be this
    -- thin: `/mm set window.frame.width 300` is one path lookup from the library's
    -- point of view, and the active-window question is the schema's to answer.
    get          = function(path) return NS.GetSetting and NS.GetSetting(path) or nil end,
    set          = function(path, v) if NS.SetByPath then NS.SetByPath(path, v) end end,
    findRow      = function(path) return NS.FindSchemaRow and NS.FindSchemaRow(path) or nil end,
    allRows      = function() return NS.Schema or {} end,
    -- Handed the ROW, not the path: NS.ApplyDefault owns the deep copy a table
    -- default needs, so two profiles resetting to the same color default do not
    -- end up sharing one table.
    applyDefault = function(row) if NS.ApplyDefault then NS.ApplyDefault(row) end end,

    -- Written out rather than omitted. It names the same key the library's own
    -- default reads, and it is here because `page` is a real contract in this
    -- addon — it is what groups `/mm list` and what feeds `rowsForPage` in
    -- settings/OptionsSetup.lua, so the CLI listing and the panel's pages cannot
    -- disagree about which page a row belongs to.
    groupKey = function(row) return row.page or "?" end,
})

-- ---------------------------------------------------------------------
-- The host verbs
-- ---------------------------------------------------------------------
--
-- These act on WINDOWS — instances the registry owns, created and deleted at
-- runtime — not on schema rows, so the library's schema CLI has nothing to say
-- about them and they are untouched by its absence. Each is a thin router: the
-- rule, the validation and the message bus all live in modules/WindowManager.lua,
-- and duplicating any of it here would give the CLI and the settings panel two
-- different ideas of what "delete a window" means.

--- The registry, resolved at CALL time, with one honest line when the module
--- layer has not loaded (a half-installed addon, or a headless suite driving the
--- CLI alone).
local function wm()
    local m = NS.WindowManager
    if m then return m end
    out("window management is unavailable \226\128\148 modules/WindowManager.lua did not load.")
    return nil
end

--- `on` / `off` / anything, through the library's own boolean vocabulary rather
--- than a private one. A `nil` answer means "not a boolean word", which is
--- exactly the signal that distinguishes `/mm lock` (toggle) from `/mm lock off`
--- (set) without re-reading the raw text.
local function boolArg(rest)
    local word = tostring(rest or ""):match("^%s*(%S*)")
    return SlashLib.ParseBool(word)
end

function doLock(rest)
    local M = wm()
    if not (M and M.SetLocked) then return end
    local want = boolArg(rest)
    if want == nil then want = not (M.IsLocked and M:IsLocked()) end
    M:SetLocked(want)
    out("windows " .. (want and "locked" or "unlocked \226\128\148 drag them into place"))
end

function doTest(rest)
    local M = wm()
    if not (M and M.SetTestMode) then return end
    local want = boolArg(rest)
    if want == nil then want = not (M.IsTest and M:IsTest()) end
    M:SetTestMode(want)
    -- LEAVING TEST MODE IS NOT CLOSING THE WINDOW. Test mode forces a window
    -- visible; without this, turning it off just stopped forcing and the ordinary
    -- visibility rules hid a window the player was looking at — so `/mm test`
    -- read as a close button with a confusing name. Whatever was on screen for
    -- test stays on screen for real data, and `/mm toggle` is how you close it.
    if not want then
        for _, inst in ipairs(M.All()) do inst:Show() end
    end
    out("test mode " .. (want and "on \226\128\148 showing placeholder rows" or "off"))
end

--- `/mm toggle` flips every window; `/mm toggle <name>` flips one. The name keeps
--- its case and its internal spacing, because a window name is user data and
--- folding it would resolve something the user did not name.
function doToggle(rest)
    local M = wm()
    if not (M and M.Toggle) then return end
    local name = tostring(rest or ""):match("^%s*(.-)%s*$")
    local ok, err = M:Toggle(name ~= "" and name or nil)
    if not ok and err then out(err) end
end

function doResetPositions()
    local M = wm()
    if not (M and M.ResetPositions) then return end
    local moved = M:ResetPositions()
    out(("moved %s back to the center of the screen"):format(
        tonumber(moved) == 1 and "1 window" or tostring(moved or 0) .. " windows"))
end

--- `/mm window <verb> [args]` — the four registry actions, each routed straight
--- through. The sub-verb is lowercased because it is an identifier; the remainder
--- is left exactly as typed because it is a window name.
local WINDOW_USAGE = "Usage: |cFFFFFF00/mm window list|r, "
    .. "|cFFFFFF00new <name>|r, |cFFFFFF00delete <name>|r, "
    .. "|cFFFFFF00copy <source> <target>|r"

-- The sub-verb table, built ONCE at file scope. slash-commands names an
-- `if verb == "x" then ... elseif` sub-dispatcher as an anti-pattern for the
-- reason visible in the version this replaced: the verb, the registry member it
-- needs and the usage fallback were smeared across a ladder, so "which sub-verbs
-- exist" could only be answered by reading every branch. A table answers it by
-- being read.
--
-- Every handler takes the registry and the untouched remainder of the line, and
-- answers modules/WindowManager.lua's own `ok, err` pair — including for the two
-- local refusals (a registry too old to carry the member, and a malformed copy),
-- which report WINDOW_USAGE through that same channel so doWindow has exactly one
-- place that prints a failure.
local WINDOW_VERBS = {}

--- `/mm window list`, and a bare `/mm window` — the registry renders its own
--- listing, because the columns belong with the data.
function WINDOW_VERBS.list(M)
    if not M.BuildListLines then return false, WINDOW_USAGE end
    for _, line in ipairs(M:BuildListLines()) do out(line) end
    return true
end

function WINDOW_VERBS.new(M, tail)
    if not M.Create then return false, WINDOW_USAGE end
    return M:Create(tail)
end

function WINDOW_VERBS.delete(M, tail)
    if not M.Delete then return false, WINDOW_USAGE end
    return M:Delete(tail)
end

--- `<source> <target>`: the source is the first word, the target the rest, so a
--- target name with spaces is expressible and a source with spaces is addressed
--- from the settings panel instead. A two-name command line has no unambiguous
--- split for both, and inventing one is a syntax the user has to learn for a job
--- the panel already does well.
function WINDOW_VERBS.copy(M, tail)
    if not M.CopyFrom then return false, WINDOW_USAGE end
    local source, target = tail:match("^(%S+)%s+(.+)$")
    if not source then return false, WINDOW_USAGE end
    return M:CopyFrom(source, target)
end

function doWindow(rest)
    local M = wm()
    if not M then return end
    local verb, tail = tostring(rest or ""):match("^%s*(%S*)%s*(.-)%s*$")
    verb = (verb or ""):lower()

    -- A bare `/mm window` means "show me what I have", which is the listing.
    local handler = WINDOW_VERBS[verb == "" and "list" or verb]
    if not handler then return out(WINDOW_USAGE) end

    local ok, err = handler(M, tail)
    if not ok and err then out(err) end
end

--- The window `/mm export` means when the player named none.
---
--- The same three-step ladder settings/Schema.lua walks for a window-relative
--- path, and it falls back to the first window rather than to nil for the same
--- reason: the CLI has no picker, and `/mm export` typed on a fresh login —
--- where nothing has ever set `activeWindowId` — has to mean something rather
--- than fail with a message about an internal pointer the player has never
--- heard of.
---
--- @param M table the window registry
--- @return table|nil config
local function defaultWindow(M)
    local id = NS.State and NS.State.activeWindowId
    if id ~= nil then
        local cfg = M.Resolve(id)
        if cfg then return cfg end
    end

    local Database = NS.Database
    local list = Database and Database.GetWindows and Database.GetWindows()
    return list and list[1] or nil
end

--- `/mm export` exports the window being edited; `/mm export <name>` exports the
--- one named. The name keeps its case and its internal spacing for the reason
--- `/mm toggle` does — a window name is user data, and folding it would resolve
--- something the player did not name.
---
--- The CONFIG is handed over rather than the live instance: a window in the
--- registry that has never been built still points at a segment, and its numbers
--- are as exportable as a drawn one's.
---
--- The restriction is asked about through `NS.Export.Available()` and nowhere
--- else here. Whether an export may run is the export module's answer to give,
--- and a second copy of the question in this file would be the copy that keeps
--- saying yes after the rule changes.
---
--- @param rest string|nil the raw remainder of the command line
function doExport(rest)
    local E = NS.Export
    if not (E and E.Open) then
        out("export is unavailable \226\128\148 modules/Export.lua did not load.")
        return
    end

    local ok, reason = E.Available()
    if not ok then
        out(reason or "export is not available right now.")
        return
    end

    local M = wm()
    if not (M and M.Resolve) then return end

    local name = tostring(rest or ""):match("^%s*(.-)%s*$")
    local cfg
    if name ~= "" then
        cfg = M.Resolve(name)
        if not cfg then
            out(NS.L["No window named '%s'."]:format(name))
            return
        end
    else
        cfg = defaultWindow(M)
        if not cfg then
            out("there is no window to export.")
            return
        end
    end

    E:Open(cfg)
end

-- ---------------------------------------------------------------------
-- The two harness verbs
-- ---------------------------------------------------------------------

--- `/mm debug` toggles the WINDOW only; `/mm debug on|off` sets the session-only
--- logging flag through the DebugLog seam. They are separate on purpose: logging
--- runs with the console closed, so a bug can be reproduced first and the log
--- read afterwards.
function doDebug(rest)
    local word = tostring(rest or ""):lower():match("^%s*(%S*)") or ""

    -- `diag` runs WITHOUT the debug log, deliberately. It is what a player is
    -- asked to run when something looks wrong, and requiring them to enable a
    -- console first is one more step between a bug and its report.
    if word == "diag" then
        if NS.Diagnostics then NS.Diagnostics.Report() end
        return
    end

    -- `recap` is the issue #1 probe on its own — the same report the full `diag`
    -- carries, without the forty lines of atlas and font output around it. It
    -- sits on this branch and not below for the same reason `diag` does: it is
    -- what a player is asked to run, and a console they have to open first is a
    -- step between us and the answer.
    if word == "recap" then
        if NS.Diagnostics then NS.Diagnostics.ReportDeathRecap() end
        return
    end

    if not NS.DebugLog then return end
    if word == "on" then
        NS.DebugLog:SetEnabled(true)
    elseif word == "off" then
        NS.DebugLog:SetEnabled(false)
    else
        NS.DebugLog:Toggle()
    end
end

--- `perf` is registered HERE, by the addon, and never by the harness. The library
--- owns the run; the addon owns which slash command reaches it, because the verb
--- table above is the one place every command in this addon is declared and a
--- verb registered behind its back would be a verb the help index, the landing
--- page and the README all miss.
function doPerf(rest)
    if not (NS.Perf and NS.Perf.OnCommand) then return end
    local lines = NS.Perf.OnCommand(rest)
    if type(lines) ~= "table" then return end
    for _, line in ipairs(lines) do out(line) end
end

-- ---------------------------------------------------------------------
-- The published surface
-- ---------------------------------------------------------------------

function Sl:OnSlash(msg)  return cli:OnSlash(msg)  end
function Sl:PrintHelp()   return cli:PrintHelp()   end
function Sl:HelpRows()    return cli:HelpRows()    end

--- The command list the settings landing page renders. The SAME formatter
--- `/mm help` prints through, minus the chat indent — so the panel and the help
--- block cannot drift, which is the whole reason settings/OptionsSetup.lua's
--- landing spec feeds this function rather than a second hand-written list.
function Sl:LandingRows() return cli:LandingRows() end

--- Registration goes through AceConsole, never through a raw SLASH_* global:
--- AceConsole owns the deregistration a `/reload` needs and the collision check
--- two addons claiming one token need, and a hand-rolled SLASH_MM1 has neither.
---
--- Both tokens reach the same dispatcher, so the alias is a real alias rather
--- than a second command with its own drift.
function Sl:Register()
    local target = NS.addon or NS
    if not target.RegisterChatCommand then return end
    target:RegisterChatCommand("mm", function(input) Sl:OnSlash(input) end)
    target:RegisterChatCommand("multimeters", function(input) Sl:OnSlash(input) end)
end
