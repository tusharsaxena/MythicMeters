-- tests/test_visibility.lua — modules/Visibility.lua: where a window is allowed
-- to exist.
--
-- The module publishes a PREDICATE and nothing else — no Show, no Hide, no
-- SetAlpha — because the cheap version of this file (flip a frame on a zone
-- change and leave the pipeline running behind it) is the exact shape
-- performance-§6 forbids. A hidden window that still asks the provider for nine
-- columns, joins them by GUID and walks a row pool is paying the full cost of a
-- display nobody can see, and it pays it in the middle of a raid pull.
--
-- The last case in the "refused at the source" block is therefore the one that
-- matters most: it counts the meter calls a window that must not show makes, and
-- the answer has to be zero.

local T = _G.MYTHICMETERS_TEST

local test        = T.test
local assertEqual = T.assertEqual
local assertTrue  = T.assertTrue
local assertFalse = T.assertFalse
local assertNil   = T.assertNil

--- The shipped rules, copied so a case can move one field and say which.
local function defaultRules()
    local template = T.NS.WINDOW_TEMPLATE.visibility
    local out = {}
    for key, value in pairs(template) do out[key] = value end
    return out
end

local function windowWith(rules)
    return { id = 1, visibility = rules, frame = {}, columns = {}, rows = {}, data = {} }
end

-- ---------------------------------------------------------------------------
-- The context map
-- ---------------------------------------------------------------------------

test("GetContext translates Blizzard's instance token to the setting's name", function()
    local inst = T.load()
    local V = inst.NS.Visibility

    local CASES = {
        party    = "dungeon",
        raid     = "raid",
        arena    = "arena",
        pvp      = "battleground",
        none     = "world",
        scenario = "world",
    }
    for token, expected in pairs(CASES) do
        inst.mocks.setInstance(token)
        assertEqual(V.GetContext(), expected, token .. " must read as " .. expected)
    end
end)

test("An instance type this build has never heard of resolves to world", function()
    local inst = T.load()
    inst.mocks.setInstance("delve_or_whatever_comes_next")
    -- Deny-by-default in practice: `world` ships false, so a context the addon
    -- has never heard of does not silently start drawing a meter.
    assertEqual(inst.NS.Visibility.GetContext(), "world")
    assertEqual(T.NS.WINDOW_TEMPLATE.visibility.world, false)
end)

-- ---------------------------------------------------------------------------
-- The default matrix
-- ---------------------------------------------------------------------------

test("The shipped matrix is dungeon / raid / arena / battleground on, world off", function()
    local inst = T.load()
    local V = inst.NS.Visibility

    -- A group, so hideWhenSolo is not the thing being measured here.
    inst.mocks.setGroup{
        { guid = "Player-1-00000001", name = "A", class = "MAGE" },
        { guid = "Player-1-00000002", name = "B", class = "PRIEST" },
    }

    local window = windowWith(defaultRules())
    local EXPECTED = {
        party = true, raid = true, arena = true, pvp = true, none = false,
    }
    for token, shown in pairs(EXPECTED) do
        inst.mocks.setInstance(token)
        local show, reason = V.ShouldShow(window)
        assertEqual(show, shown, "instance type " .. token)
        if not shown then
            assertEqual(reason, "world", "the reason names the step that decided")
        end
    end
end)

test("The reason token is stable and unlocalized", function()
    local inst = T.load()
    inst.mocks.setInstance("party")
    inst.mocks.setSolo()

    -- `/mm status` prints it and the tests assert on it; both break the moment a
    -- translator gets hold of it.
    local rules = defaultRules()
    local show, reason = inst.NS.Visibility.ShouldShow(windowWith(rules))
    assertEqual(show, false)
    assertEqual(reason, "solo")

    rules.hideWhenSolo = false
    assertEqual(select(2, inst.NS.Visibility.ShouldShow(windowWith(rules))), "dungeon")
end)

-- ---------------------------------------------------------------------------
-- The two vetoes
-- ---------------------------------------------------------------------------

test("hideWhenSolo hides a window whose context already said yes", function()
    local inst = T.load()
    inst.mocks.setInstance("party")

    local rules = defaultRules()
    inst.mocks.setSolo()
    assertEqual(inst.NS.Visibility.ShouldShow(windowWith(rules)), false)

    inst.mocks.setGroup{
        { guid = "Player-1-00000001", name = "A", class = "MAGE" },
        { guid = "Player-1-00000002", name = "B", class = "PRIEST" },
    }
    assertEqual(inst.NS.Visibility.ShouldShow(windowWith(rules)), true)
end)

test("hideInVehicle hides a window whose context already said yes", function()
    local inst = T.load()
    inst.mocks.setInstance("raid")
    inst.mocks.setGroup{
        { guid = "Player-1-00000001", name = "A", class = "MAGE" },
        { guid = "Player-1-00000002", name = "B", class = "PRIEST" },
    }

    local rules = defaultRules()
    inst.mocks.setInVehicle(true)
    local show, reason = inst.NS.Visibility.ShouldShow(windowWith(rules))
    assertEqual(show, false)
    assertEqual(reason, "vehicle")

    rules.hideInVehicle = false
    assertEqual(inst.NS.Visibility.ShouldShow(windowWith(rules)), true)
end)

test("Context is decided BEFORE the two vetoes, so the reason is the real one", function()
    local inst = T.load()
    inst.mocks.setInstance(nil)     -- the open world, which ships off
    inst.mocks.setSolo()
    inst.mocks.setInVehicle(true)

    -- Running the vetoes first would report "solo" as the reason a window is
    -- hidden in the open world, when the real reason is that open world is off.
    assertEqual(select(2, inst.NS.Visibility.ShouldShow(windowWith(defaultRules()))), "world")
end)

test("The vehicle answer is read live, because nothing on the bus announces it", function()
    local inst = T.load()
    inst.mocks.setInstance("party")
    inst.mocks.setGroup{
        { guid = "Player-1-00000001", name = "A", class = "MAGE" },
        { guid = "Player-1-00000002", name = "B", class = "PRIEST" },
    }
    local window = windowWith(defaultRules())

    assertEqual(inst.NS.Visibility.ShouldShow(window), true)
    inst.mocks.setInVehicle(true)
    -- No Evaluate, no message, no cache priming: the next question gets the
    -- right answer because the inputs are read at the moment they are asked.
    assertEqual(inst.NS.Visibility.ShouldShow(window), false)
end)

-- ---------------------------------------------------------------------------
-- Degradation
-- ---------------------------------------------------------------------------

test("A window with no rules at all is allowed, not hidden", function()
    local inst = T.load()
    -- A config predating the visibility group, or a hand-edited SavedVariables.
    -- The honest reading of "no rules" is "nothing objects".
    local show, reason = inst.NS.Visibility.ShouldShow({ id = 1 })
    assertEqual(show, true)
    assertEqual(reason, "no rules")
end)

test("A non-table window is refused by name", function()
    local show, reason = T.NS.Visibility.ShouldShow(nil)
    assertEqual(show, false)
    assertEqual(reason, "no window")
end)

test("Allows() is the same implementation under the ladder's name", function()
    local inst = T.load()
    inst.mocks.setInstance("party")
    inst.mocks.setSolo()
    local window = windowWith(defaultRules())

    local a, ar = inst.NS.Visibility:Allows(window)
    local b, br = inst.NS.Visibility.ShouldShow(window)
    assertEqual(a, b)
    assertEqual(ar, br)
end)

-- ---------------------------------------------------------------------------
-- The evaluation pass
-- ---------------------------------------------------------------------------

test("Evaluate records the last answer per window and counts the changes", function()
    local inst = T.load()
    local NS = inst.NS
    inst.mocks.setInstance("party")
    inst.mocks.setGroup{
        { guid = "Player-1-00000001", name = "A", class = "MAGE" },
        { guid = "Player-1-00000002", name = "B", class = "PRIEST" },
    }

    local cfg = NS.Database.GetWindows()[1]
    assertEqual(NS.Visibility:Evaluate(), 1, "the first answer is always a change")
    local show, reason = NS.Visibility.LastResult(cfg.id)
    assertEqual(show, true)
    assertEqual(reason, "dungeon")

    assertEqual(NS.Visibility:Evaluate(), 0, "an unchanged answer is not a change")

    inst.mocks.setInstance(nil)
    assertEqual(NS.Visibility:Evaluate(), 1)
    assertEqual(select(2, NS.Visibility.LastResult(cfg.id)), "world")
end)

test("Refresh is Evaluate under the name a caller thinks in", function()
    local inst = T.load()
    inst.mocks.setInstance("party")
    assertEqual(type(inst.NS.Visibility:Refresh()), "number")
end)

test("Evaluate publishes NOTHING", function()
    local inst = T.load()
    local NS = inst.NS
    inst.mocks.setInstance("party")

    -- A message from this module would be a second, racing path to the same
    -- decision, and would let two windows disagree about the current zone for a
    -- frame. A window discovers the new answer by consulting NS.ShouldShow.
    local heard = 0
    local bus = NS.NewBusTarget()
    for _, message in pairs(NS.Constants.MSG) do
        bus:RegisterMessage(message, function() heard = heard + 1 end)
    end

    NS.Visibility:Evaluate()
    assertEqual(heard, 0)
end)

test("Forget drops every remembered answer", function()
    local inst = T.load()
    local NS = inst.NS
    inst.mocks.setInstance("party")
    local cfg = NS.Database.GetWindows()[1]

    NS.Visibility:Evaluate()
    assertTrue(NS.Visibility.LastResult(cfg.id) ~= nil)

    -- On a profile swap the ids on the other side describe entirely different
    -- windows, and a retained answer would be attributed to the wrong one.
    NS.Visibility.Forget()
    assertNil(NS.Visibility.LastResult(cfg.id))
end)

test("Evaluate copes with a database that is not up yet", function()
    local inst = T.load{ initDB = false, options = false }
    assertEqual(inst.NS.Visibility:Evaluate(), 0)
end)

-- ---------------------------------------------------------------------------
-- Refused AT THE SOURCE (performance-§6)
-- ---------------------------------------------------------------------------

test("A window that should not show never reaches the provider at all", function()
    local inst = T.load()
    local NS, mocks = inst.NS, inst.mocks

    mocks.setGroup{
        { guid = "Player-1-00000001", name = "A", class = "MAGE" },
        { guid = "Player-1-00000002", name = "B", class = "PRIEST" },
    }
    NS.Roster.Refresh()
    mocks.setSession(1, "*", {
        combatSources = { { sourceGUID = "Player-1-00000001", totalAmount = 100 } },
        maxAmount = 100, totalAmount = 100,
    })

    local cfg = NS.Database.GetWindows()[1]
    cfg.frame.locked = true
    mocks.setInstance(nil)          -- the open world, which ships off

    local window = NS.Window.New(cfg)
    window:RefreshVisibility()
    assertEqual(window:IsShown(), false)

    mocks.resetMeterCalls()
    -- Everything a live client would do to this window over a whole pull: mark
    -- it dirty on every meter event, and let the clock come round again and
    -- again.
    for _ = 1, 20 do
        window:MarkDirty()
        window.frame:_run("OnUpdate", 0.5)
    end

    for name, count in pairs(mocks.__meter.calls) do
        assertEqual(count, 0,
            "a refused window called " .. name .. " — it was built and hidden, not refused")
    end
    assertEqual(#window.pool.active, 0)
end)

test("The refusal lifts the moment the context does", function()
    local inst = T.load()
    local NS, mocks = inst.NS, inst.mocks

    mocks.setGroup{
        { guid = "Player-1-00000001", name = "A", class = "MAGE" },
        { guid = "Player-1-00000002", name = "B", class = "PRIEST" },
    }
    NS.Roster.Refresh()
    mocks.setSession(1, "*", {
        combatSources = { { sourceGUID = "Player-1-00000001", totalAmount = 100,
                            classFilename = "MAGE" } },
        maxAmount = 100, totalAmount = 100,
    })

    local cfg = NS.Database.GetWindows()[1]
    cfg.frame.locked  = true
    cfg.data.sortMode = "provider"
    -- The shipped default is Overall; this fixture seeds session type 1.
    cfg.data.sessionType = 1
    mocks.setInstance(nil)

    local window = NS.Window.New(cfg)
    window:RefreshVisibility()
    assertEqual(window:IsShown(), false)

    -- A window hidden by a context rule has no OnUpdate running — a hidden
    -- frame's script does not fire — so the ladder has to be re-run from the
    -- message or the window can never come back.
    mocks.setInstance("party")
    NS:SendMessage(NS.Constants.MSG.ZONE_CHANGED)
    assertEqual(window:IsShown(), true)

    window.frame:_run("OnUpdate", 1.0)
    assertEqual(#window.pool.active, 1, "and it draws on the next tick")
end)

test("modules/Visibility.lua never touches a frame", function()
    -- Adding a Show / Hide / SetAlpha here would quietly turn the refusal back
    -- into a curtain drawn over work that still happens.
    local fh = assert(io.open(T.root .. "/modules/Visibility.lua", "r"))
    local n, offenders = 0, {}
    for line in fh:lines() do
        n = n + 1
        if not line:match("^%s*%-%-") then
            local code = line:gsub("%s%-%-.*$", "")
            for _, call in ipairs{ ":Show%(", ":Hide%(", ":SetAlpha%(", ":SetShown%(" } do
                if code:find(call) then
                    offenders[#offenders + 1] = "modules/Visibility.lua:" .. n
                end
            end
        end
    end
    fh:close()
    assertEqual(#offenders, 0, table.concat(offenders, ", "))
end)

test("modules/Visibility.lua uses no combat rule, and no InCombatLockdown proxy", function()
    -- There is no combat rule today. If one is ever added it must use
    -- UnitAffectingCombat("player"): lockdown is about whether SECURE writes are
    -- legal, and nothing here writes anything secure.
    local fh = assert(io.open(T.root .. "/modules/Visibility.lua", "r"))
    local n = 0
    for line in fh:lines() do
        n = n + 1
        if not line:match("^%s*%-%-") then
            local code = line:gsub("%s%-%-.*$", "")
            assertFalse(code:find("InCombatLockdown", 1, true) ~= nil,
                "modules/Visibility.lua:" .. n)
        end
    end
    fh:close()
end)

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

test("Visibility listens on the bus and registers no game event", function()
    local inst = T.load()
    local NS, mocks = inst.NS, inst.mocks
    local MSG = NS.Constants.MSG

    NS.Visibility:OnEnable()
    for _, message in ipairs{ MSG.ZONE_CHANGED, MSG.ENTERING_WORLD,
                              MSG.ROSTER_CHANGED, MSG.PROFILE_CHANGED } do
        assertTrue((mocks.__busRegistry[message] or {})[NS.Visibility] ~= nil,
            "Visibility must listen on " .. message)
    end

    local fh = assert(io.open(T.root .. "/modules/Visibility.lua", "r"))
    for line in fh:lines() do
        if not line:match("^%s*%-%-") then
            assertFalse(line:gsub("%s%-%-.*$", ""):find("RegisterEvent", 1, true) ~= nil,
                "core/MythicMeters.lua is the addon's single game-event listener")
        end
    end
    fh:close()
end)

test("A profile change forgets the old answers and re-evaluates", function()
    local inst = T.load()
    local NS = inst.NS
    inst.mocks.setInstance("party")
    local cfg = NS.Database.GetWindows()[1]

    NS.Visibility:Evaluate()
    inst.mocks.setInstance(nil)
    NS.Visibility:OnProfileChanged()
    assertEqual(select(2, NS.Visibility.LastResult(cfg.id)), "world")
end)
