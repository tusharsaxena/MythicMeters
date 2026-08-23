-- tests/test_slash.lua
--
-- settings/Slash.lua's half of the CLI. The dispatcher, the help renderer, the
-- row formatter and the value parser are LibKa0s-Slash-1.0's and are tested in
-- that repo (testing-§8); what is ours is the verb table, the five host verbs,
-- the adapters that point the library's schema seams at NS.SetByPath, and the
-- registration.
--
-- ── THE SHAPE CASE ────────────────────────────────────────────────────────────
--
-- NS.COMMANDS entries are ORDERED POSITIONAL TRIPLES `{ name, desc, handler }`,
-- because `entry[1]` / `entry[2]` / `entry[3]` is what the library reads. A table
-- of named fields (`{ name =, desc =, fn = }`) does not fail loudly: it loads
-- clean, `findCommand` matches nothing, and EVERY verb the user types answers
-- "unknown command" with no error to read and nothing in the log. It is the
-- cheapest possible mistake and the most expensive one to notice, so the shape is
-- asserted directly rather than inferred from one verb happening to work.

local T = _G.MULTIMETERS_TEST
local test = T.test
local assertEqual, assertTrue, assertFalse = T.assertEqual, T.assertTrue, T.assertFalse

local NS = T.NS

--- Every chat line one command produced, on a fresh instance.
local function say(inst, msg)
    local n = #inst.mocks.__chat
    inst.NS.Slash:OnSlash(msg)
    local out = {}
    for i = n + 1, #inst.mocks.__chat do out[#out + 1] = inst.mocks.__chat[i] end
    return out
end

local function joined(lines) return table.concat(lines, "\n") end

local function verbNames(commands)
    local names = {}
    for _, entry in ipairs(commands) do names[#names + 1] = entry[1] end
    return names
end

local function findVerb(commands, name)
    for _, entry in ipairs(commands) do
        if entry[1] == name then return entry end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- The verb table's shape
-- ---------------------------------------------------------------------------

test("Slash: NS.COMMANDS entries are positional triples, not named fields", function()
    assertEqual(type(NS.COMMANDS), "table")
    assertTrue(#NS.COMMANDS >= 15, "the table is an ARRAY; a keyed table has length 0")

    for i, entry in ipairs(NS.COMMANDS) do
        local where = "NS.COMMANDS[" .. i .. "]"
        assertEqual(type(entry), "table", where)
        assertEqual(type(entry[1]), "string", where .. "[1] must be the verb name")
        assertEqual(type(entry[2]), "string", where .. "[2] must be the description")
        assertEqual(type(entry[3]), "function", where .. "[3] must be the handler")
        assertTrue(entry[1] ~= "", where .. " has an empty verb name")
        assertTrue(entry[2] ~= "", where .. " has an empty description")

        -- The named-field spelling, asserted absent. This is the whole case: an
        -- entry carrying BOTH shapes would satisfy the three checks above and
        -- still be the wrong table to hand the library.
        assertEqual(entry.name, nil, where .. " carries a `name` field — the library reads entry[1]")
        assertEqual(entry.desc, nil, where .. " carries a `desc` field — the library reads entry[2]")
        assertEqual(entry.fn,   nil, where .. " carries an `fn` field — the library reads entry[3]")
        assertEqual(entry.handler, nil, where .. " carries a `handler` field")
    end
end)

test("Slash: no verb is declared twice", function()
    local seen = {}
    for _, name in ipairs(verbNames(NS.COMMANDS)) do
        assertEqual(seen[name], nil, "the verb '" .. tostring(name) .. "' is declared twice")
        seen[name] = true
    end
end)

test("Slash: every reserved verb is present, in the order the standard fixes", function()
    local RESERVED = {
        "help", "config", "list", "get", "set",
        "reset", "resetall", "debug", "perf", "version",
    }
    local names = verbNames(NS.COMMANDS)
    for i, want in ipairs(RESERVED) do
        assertEqual(names[i], want,
            "reserved verb " .. i .. " should be '" .. want .. "', got '" .. tostring(names[i]) .. "'")
    end
end)

test("Slash: the host verbs are declared and each carries a real handler", function()
    for _, name in ipairs({ "lock", "test", "toggle", "window", "reset-positions" }) do
        local entry = findVerb(NS.COMMANDS, name)
        assertTrue(entry ~= nil, "the host verb '" .. name .. "' is missing")
        assertEqual(type(entry[3]), "function")
    end
end)

test("Slash: `reset` takes a PATH, not a page", function()
    local entry = findVerb(NS.COMMANDS, "reset")
    local desc = entry[2]
    assertTrue(desc:find("<path>", 1, true) ~= nil,
        "the help index and the README both render this string; it must name a path, got: " .. desc)
    assertTrue(desc:lower():find("page") == nil,
        "a page-shaped reset is what the panel's own Defaults button is for, got: " .. desc)
end)

test("Slash: every sub-verb a handler accepts is named in its own description", function()
    -- The generated help index, the settings landing page and the README's
    -- command table read these strings and nothing else, so a sub-verb missing
    -- here is a sub-verb nobody can discover (slash-commands-§4).
    assertTrue(findVerb(NS.COMMANDS, "debug")[2]:find("on", 1, true) ~= nil)
    assertTrue(findVerb(NS.COMMANDS, "debug")[2]:find("off", 1, true) ~= nil)
    local window = findVerb(NS.COMMANDS, "window")[2]
    for _, sub in ipairs({ "list", "new", "delete", "copy" }) do
        assertTrue(window:find(sub, 1, true) ~= nil,
            "`/mm window " .. sub .. "` is implemented but undocumented: " .. window)
    end
end)

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

test("Slash: an unknown verb says so and prints the help", function()
    local inst = T.load()
    local lines = say(inst, "wibble")
    assertTrue(#lines > 1, "an unknown verb should be answered and then helped")
    assertTrue(joined(lines):lower():find("wibble") ~= nil, joined(lines))
end)

test("Slash: `options` is an alias for `config`, not a second command", function()
    assertEqual(findVerb(NS.COMMANDS, "options"), nil,
        "the back-compat spelling is an ALIAS; a second entry would be a second thing to keep in step")
    local inst = T.load()
    local opened = 0
    inst.NS.OpenOptionsPanel = function() opened = opened + 1 end
    say(inst, "options")
    say(inst, "config")
    assertEqual(opened, 2, "both spellings must reach the same handler")
end)

test("Slash: `version` reports the TOC's version rather than a hardcoded string", function()
    local inst = T.load()
    inst.mocks.__toc.Version = "9.9.9"
    assertTrue(joined(say(inst, "version")):find("9.9.9", 1, true) ~= nil,
        "the version must be read from the packaged manifest (slash-commands-§3)")
end)

test("Slash: `get` and `set` land on the addon's own schema seam", function()
    local inst = T.load()
    say(inst, "set window.frame.width 300")
    assertEqual(inst.NS.GetSetting("window.frame.width"), 300)
    assertTrue(joined(say(inst, "get window.frame.width")):find("300", 1, true) ~= nil)
end)

test("Slash: `set` on a window path writes the ACTIVE window", function()
    local inst = T.load()
    local NSi = inst.NS
    assertTrue(NSi.WindowManager:Create("Second"))
    local list = NSi.Database.GetWindows()
    NSi.State.SetActiveWindow(list[2].id)

    say(inst, "set window.frame.width 360")
    assertEqual(list[2].frame.width, 360)
    assertEqual(list[1].frame.width, 694, "the window the picker is NOT on must be untouched")
end)

test("Slash: `reset <path>` restores exactly that one setting", function()
    local inst = T.load()
    local NSi = inst.NS
    say(inst, "set window.frame.width 300")
    say(inst, "set window.frame.height 400")
    say(inst, "reset window.frame.width")
    assertEqual(NSi.GetSetting("window.frame.width"), 694, "the shipped width")
    assertEqual(NSi.GetSetting("window.frame.height"), 400, "reset must not sweep the page")
end)

test("Slash: `resetall` restores every row", function()
    local inst = T.load()
    local NSi = inst.NS
    say(inst, "set window.frame.width 300")
    say(inst, "set window.rows.height 30")
    say(inst, "resetall")
    assertEqual(NSi.GetSetting("window.frame.width"), 694)
    assertEqual(NSi.GetSetting("window.rows.height"), 16)
end)

test("Slash: `list` groups by the row's PAGE, the same key the panel pages use", function()
    local inst = T.load()
    local text = joined(say(inst, "list"))
    -- `groupKey` is written out on the descriptor precisely so the CLI listing
    -- and the panel cannot disagree about where a row belongs.
    assertTrue(text:find("window.frame.width", 1, true) ~= nil, text)
    assertTrue(text:lower():find("frame") ~= nil, text)
end)

-- ---------------------------------------------------------------------------
-- perf: registered by the ADDON, never by the library
-- ---------------------------------------------------------------------------

test("Slash: `perf` is declared in NS.COMMANDS and routed to NS.Perf.OnCommand", function()
    local inst = T.load()
    local entry = findVerb(inst.NS.COMMANDS, "perf")
    assertTrue(entry ~= nil, "the verb table is the ONE place every command is declared")

    local seen = {}
    inst.NS.Perf.OnCommand = function(rest)
        seen[#seen + 1] = rest
        return { "perf line" }
    end
    local lines = say(inst, "perf start pulls")
    assertEqual(#seen, 1)
    assertEqual(seen[1], "start pulls", "the remainder keeps its case and its spacing")
    assertTrue(joined(lines):find("perf line", 1, true) ~= nil,
        "the handler must print what the library's run answers")
end)

-- ---------------------------------------------------------------------------
-- export: the verb, and the two ways it refuses
-- ---------------------------------------------------------------------------

--- Replace NS.Export.Open with a spy and hand back the call log.
---
--- @param inst table
--- @return table  array of the windows Open was called with
local function spyOnExport(inst)
    local opened = {}
    inst.NS.Export.Open = function(a, b)
        opened[#opened + 1] = (a == inst.NS.Export) and b or a
    end
    return opened
end

test("Slash: `export` opens the modal on the window the player named", function()
    local inst = T.load()
    assertTrue(findVerb(inst.NS.COMMANDS, "export") ~= nil,
        "the verb table is the ONE place every command is declared")

    assertTrue(inst.NS.WindowManager:Create("Cleave"))
    local opened = spyOnExport(inst)

    say(inst, "export Cleave")
    assertEqual(#opened, 1, "one window named, one modal opened")
    assertEqual(opened[1].name, "Cleave", "the CONFIG of the named window, not another")
end)

test("Slash: `export` with no name falls back to a window rather than to nothing", function()
    -- `/mm export` typed on a fresh login, where nothing has ever set
    -- activeWindowId, has to mean something: the CLI has no picker.
    local inst = T.load()
    local opened = spyOnExport(inst)

    say(inst, "export")
    assertEqual(#opened, 1)
    assertTrue(opened[1] ~= nil, "a window, not nil")
end)

test("Slash: `export` names a window it cannot find rather than opening another", function()
    local inst = T.load()
    local opened = spyOnExport(inst)

    local lines = say(inst, "export NoSuchWindow")
    assertEqual(#opened, 0, "a typo must never export somebody else's window")
    assertTrue(joined(lines):find("NoSuchWindow", 1, true) ~= nil,
        "the message has to name what was typed")
end)

test("Slash: `export` refuses while the game restricts combat data", function()
    -- red under: dropping the Available() call, which would open a modal with two
    -- dead buttons instead of saying why.
    local inst = T.load()
    inst.mocks.setRestricted(true)
    local opened = spyOnExport(inst)

    local lines = say(inst, "export")
    assertEqual(#opened, 0, "no modal opens mid-pull")
    assertTrue(joined(lines):lower():find("restrict", 1, true) ~= nil,
        "the refusal must say why: " .. joined(lines))
end)

test("Slash: the library did not register `perf` behind the addon's back", function()
    -- A verb registered outside NS.COMMANDS is a verb the help index, the settings
    -- landing page and the README all miss. LandingRows is generated FROM
    -- NS.COMMANDS, so anything the dispatcher answers that is not in that list
    -- would be invisible in all three.
    local rows = NS.Slash:LandingRows()
    local perfRows = 0
    for _, line in ipairs(rows) do
        if line:find("/mm perf", 1, true) then perfRows = perfRows + 1 end
    end
    assertEqual(perfRows, 1, "`/mm perf` must appear exactly once in the generated list")
    assertEqual(#rows, #NS.COMMANDS,
        "the landing list is generated from NS.COMMANDS; a different length means a verb "
        .. "was registered somewhere else")
end)

-- ---------------------------------------------------------------------------
-- The host verbs
-- ---------------------------------------------------------------------------

test("Slash: `lock` sets, and a bare `lock` toggles", function()
    local inst = T.load()
    local M = inst.NS.WindowManager
    say(inst, "lock on")
    assertTrue(M:IsLocked())
    say(inst, "lock off")
    assertFalse(M:IsLocked())
    say(inst, "lock")
    assertTrue(M:IsLocked(), "a bare verb toggles, which is what a nil boolean parse means")
end)

test("Slash: `test` sets and toggles through the registry", function()
    local inst = T.load()
    local M = inst.NS.WindowManager
    say(inst, "test on")
    assertTrue(M:IsTest())
    say(inst, "test off")
    assertFalse(M:IsTest())
end)

test("Slash: `lock` moves the lock and NOTHING else", function()
    -- One verb, one effect. `/mm lock off` used to switch placeholder data on as
    -- a side effect, which is how a player ends up with a window full of Ka0stank
    -- and no idea which control put it there.
    -- red under: restoring the SetTestMode call in WindowManager:SetLocked.
    local inst = T.load()
    local M = inst.NS.WindowManager
    say(inst, "lock off")
    assertFalse(M:IsLocked())
    assertFalse(M:IsTest(), "unlocking is not a request for test data")

    say(inst, "test on")
    say(inst, "lock on")
    assertTrue(M:IsLocked())
    assertTrue(M:IsTest(), "and locking does not take it away again")
end)

test("Slash: `window new` and `window delete` act on the registry", function()
    local inst = T.load()
    local NSi = inst.NS
    assertEqual(#NSi.Database.GetWindows(), 1)
    say(inst, "window new Raid Frame")
    assertEqual(#NSi.Database.GetWindows(), 2)
    assertEqual(NSi.Database.GetWindows()[2].name, "Raid Frame",
        "a window name is user data and keeps its case and its spacing")
    say(inst, "window delete Raid Frame")
    assertEqual(#NSi.Database.GetWindows(), 1)
end)

test("Slash: `window list` prints one line per window", function()
    local inst = T.load()
    say(inst, "window new Second")
    local lines = say(inst, "window list")
    assertTrue(#lines >= 2, "two windows, at least two lines; got " .. #lines)
end)

test("Slash: `window` with an unknown sub-verb prints the usage", function()
    local inst = T.load()
    local text = joined(say(inst, "window explode"))
    assertTrue(text:find("/mm window list", 1, true) ~= nil, text)
end)

test("Slash: `toggle` reaches the registry and reports its refusal", function()
    local inst = T.load()
    local lines = say(inst, "toggle NoSuchWindow")
    assertTrue(#lines >= 1, "a named window that does not exist must be answered")
end)

test("Slash: `reset-positions` moves every window and says how many", function()
    local inst = T.load()
    local NSi = inst.NS
    say(inst, "window new Second")
    for _, w in ipairs(NSi.Database.GetWindows()) do
        w.frame.position = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 111, y = -222 }
    end
    local text = joined(say(inst, "reset-positions"))
    assertTrue(text:find("2 windows", 1, true) ~= nil, text)
    for _, w in ipairs(NSi.Database.GetWindows()) do
        assertEqual(w.frame.position.point, "CENTER")
        assertEqual(w.frame.position.x, 0)
    end
end)

test("Slash: `debug on` / `debug off` set the logging flag; a bare `debug` moves the window", function()
    local inst = T.load()
    local D = inst.NS.DebugLog
    assertTrue(D ~= nil, "the debug console seam must have loaded")
    say(inst, "debug on")
    assertTrue(inst.NS.State.debug, "`on` sets the session-only logging flag")
    say(inst, "debug off")
    assertFalse(inst.NS.State.debug)
    -- The window and the flag are separate on purpose: logging runs with the
    -- console closed so a bug can be reproduced first and read afterwards.
    local shownBefore = D:IsShown()
    say(inst, "debug")
    assertTrue(D:IsShown() ~= shownBefore, "a bare `debug` toggles the console window")
    assertFalse(inst.NS.State.debug, "and must not touch the logging flag")
end)

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

test("Slash: registration goes through AceConsole, on both tokens", function()
    local inst = T.load()
    local target = inst.NS.addon or inst.NS
    local registered = {}
    local real = target.RegisterChatCommand
    target.RegisterChatCommand = function(_, token, handler)
        registered[token] = handler
    end
    inst.NS.Slash:Register()
    target.RegisterChatCommand = real

    assertEqual(type(registered["mm"]), "function")
    assertEqual(type(registered["multimeters"]), "function")
end)

test("Slash: both registered tokens reach the SAME dispatcher", function()
    local inst = T.load()
    local target = inst.NS.addon or inst.NS
    local registered = {}
    local real = target.RegisterChatCommand
    target.RegisterChatCommand = function(_, token, handler) registered[token] = handler end
    inst.NS.Slash:Register()
    target.RegisterChatCommand = real

    local opened = 0
    inst.NS.OpenOptionsPanel = function() opened = opened + 1 end
    registered["mm"]("config")
    registered["multimeters"]("config")
    assertEqual(opened, 2, "the alias must be a real alias, not a second command with its own drift")
end)

test("Slash: no raw SLASH_* global is claimed anywhere", function()
    -- AceConsole owns the deregistration a /reload needs and the collision check
    -- two addons claiming one token need; a hand-rolled SLASH_MM1 has neither.
    local inst = T.load()
    inst.NS.Slash:Register()
    for _, name in ipairs({
        "SLASH_MM1", "SLASH_MM2", "SLASH_MULTIMETERS1", "SLASH_MULTIMETERS2",
        "SLASH_KA0SMULTIMETERS1",
    }) do
        assertEqual(_G[name], nil, name .. " was set — registration must go through AceConsole")
        assertEqual(inst.mocks[name], nil, name .. " was set on the simulated client")
    end
    assertEqual(_G.SlashCmdList, nil)
    assertEqual(inst.mocks.SlashCmdList, nil)
end)

test("Slash: Register is a no-op rather than a raise when there is no AceConsole", function()
    local inst = T.load()
    local target = inst.NS.addon or inst.NS
    local real = target.RegisterChatCommand
    target.RegisterChatCommand = nil
    local ok = pcall(function() inst.NS.Slash:Register() end)
    target.RegisterChatCommand = real
    assertTrue(ok, "a half-installed Ace stack must not take the load down")
end)
