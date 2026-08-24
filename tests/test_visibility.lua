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

local T = _G.MULTIMETERS_TEST

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
        scenario = "scenario",
    }
    for token, expected in pairs(CASES) do
        inst.mocks.setInstance(token)
        assertEqual(V.GetContext(), expected, token .. " must read as " .. expected)
    end
end)

test("A delve reads as `delve`, not as the scenario it reports itself to be", function()
    local inst = T.load()
    -- Blizzard has no delve instance type: a delve reports "scenario", the same
    -- token an ordinary scenario and a follower dungeon report. The delve probe
    -- therefore has to run BEFORE the instance-type table, or the two contexts
    -- collapse into one checkbox that cannot tell them apart.
    inst.mocks.setDelve(true)
    assertEqual(inst.NS.Visibility.GetContext(), "delve")

    inst.mocks.setDelve(false)
    inst.mocks.setInstance("scenario")
    assertEqual(inst.NS.Visibility.GetContext(), "scenario")
end)

test("An instance type this build has never heard of resolves to world", function()
    local inst = T.load()
    inst.mocks.setInstance("delve_or_whatever_comes_next")
    -- The honest reading of "somewhere this addon has no name for": not a dungeon,
    -- not a raid, not an arena, so the outdoors as far as these rules go. And
    -- since `world` now ships TRUE, such a context SHOWS a meter the player can
    -- switch off rather than withholding one they cannot find the switch for.
    assertEqual(inst.NS.Visibility.GetContext(), "world")
    assertEqual(T.NS.WINDOW_TEMPLATE.visibility.world, true)
end)

-- ---------------------------------------------------------------------------
-- The default matrix
-- ---------------------------------------------------------------------------

test("A fresh profile shows the window everywhere and hides it nowhere", function()
    local inst = T.load()
    local V = inst.NS.Visibility

    -- SHOW EVERYWHERE, HIDE NOWHERE. Every context on, every rule off. A default
    -- that only ever shows cannot produce this feature's worst failure — a window
    -- that never appears, with seventeen checkboxes to read before you can tell
    -- which one took it away.
    local window = windowWith(defaultRules())
    inst.mocks.setSolo()
    for _, token in ipairs{ "party", "raid", "arena", "pvp", "scenario", "none" } do
        inst.mocks.setInstance(token)
        local show, reason = V.ShouldShow(window)
        assertEqual(show, true, "instance type " .. token .. " must show out of the box")
        assertEqual(reason, V.GetContext())
    end

    -- Solo, mounted, gliding, in a vehicle, on a taxi, in your house, in a pet
    -- battle, dead, and out of combat all at once — none of it matters until the
    -- player asks for it.
    inst.mocks.setInstance(nil)
    inst.mocks.setMounted(true)
    inst.mocks.setCanGlide(true)
    inst.mocks.setInVehicle(true)
    inst.mocks.setOnTaxi(true)
    inst.mocks.setInHousing(true)
    inst.mocks.setInPetBattle(true)
    inst.mocks.setDeadOrGhost(true)
    assertEqual(V.ShouldShow(window), true, "a shipped rule hid the window unasked")
end)

test("The reason token is stable and unlocalized", function()
    local inst = T.load()
    inst.mocks.setInstance("party")
    inst.mocks.setSolo()

    -- `/mm debug diag` prints it and the tests assert on it; both break the moment a
    -- translator gets hold of it.
    local rules = defaultRules()
    rules.hideWhenSolo = true   -- ships off; this case is about the reason it gives
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
    rules.hideWhenSolo = true
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
    rules.hideInVehicle = true
    inst.mocks.setInVehicle(true)
    local show, reason = inst.NS.Visibility.ShouldShow(windowWith(rules))
    assertEqual(show, false)
    assertEqual(reason, "vehicle")

    rules.hideInVehicle = false
    assertEqual(inst.NS.Visibility.ShouldShow(windowWith(rules)), true)
end)

test("Context is decided BEFORE the two vetoes, so the reason is the real one", function()
    local inst = T.load()
    inst.mocks.setInstance(nil)
    inst.mocks.setSolo()
    inst.mocks.setInVehicle(true)

    -- Open world switched off BY THE PLAYER, with two vetoes that would also fire.
    -- Running the vetoes first would report "solo" as the reason a window is
    -- hidden in the open world, when the real reason is the context.
    local rules = defaultRules()
    rules.world, rules.hideWhenSolo, rules.hideInVehicle = false, true, true
    assertEqual(select(2, inst.NS.Visibility.ShouldShow(windowWith(rules))), "world")
end)

test("The vehicle answer is read live, because nothing on the bus announces it", function()
    local inst = T.load()
    inst.mocks.setInstance("party")
    inst.mocks.setGroup{
        { guid = "Player-1-00000001", name = "A", class = "MAGE" },
        { guid = "Player-1-00000002", name = "B", class = "PRIEST" },
    }
    local rules = defaultRules()
    rules.hideInVehicle = true
    local window = windowWith(rules)

    assertEqual(inst.NS.Visibility.ShouldShow(window), true)
    inst.mocks.setInVehicle(true)
    -- No Evaluate, no message, no cache priming: the next question gets the
    -- right answer because the inputs are read at the moment they are asked.
    assertEqual(inst.NS.Visibility.ShouldShow(window), false)
end)

-- ---------------------------------------------------------------------------
-- The player-state vetoes
-- ---------------------------------------------------------------------------
--
-- Every rule below is HIDE-shaped, and that is a deliberate choice rather than a
-- naming accident. The settings page could as easily have offered "show when
-- mounted"; it does not, because a key MISSING from a stored window has to mean
-- "nothing objects". A show-shaped key reads as false when absent, which would
-- hide every window in a profile written before the rule existed — and the
-- profile shape is filled in by core/Database.lua's EnsureWindowShape on a
-- schedule this module cannot see.

--- A window in a dungeon, in a group: a context that has already said yes, so
--- the only thing a case can be measuring is its own veto.
local function allowedInstance()
    local inst = T.load()
    inst.mocks.setInstance("party")
    inst.mocks.setGroup{
        { guid = "Player-1-00000001", name = "A", class = "MAGE" },
        { guid = "Player-1-00000002", name = "B", class = "PRIEST" },
    }
    return inst
end

-- Each row is { rule key, the mock that turns the state on, the reason token }.
local VETOES = {
    { "hideWhenMounted",   function(m) m.setMounted(true) end,     "mounted"    },
    { "hideWhenSkyriding", function(m) m.setCanGlide(true) end,    "skyriding"  },
    { "hideInHousing",     function(m) m.setInHousing(true) end,   "housing"    },
    { "hideOnTaxi",        function(m) m.setOnTaxi(true) end,      "taxi"       },
    { "hideInPetBattle",   function(m) m.setInPetBattle(true) end, "pet battle" },
    { "hideWhenDead",      function(m) m.setDeadOrGhost(true) end, "dead"       },
    { "hideInVehicle",     function(m) m.setInVehicle(true) end,   "vehicle"    },
}

test("Each player-state rule hides its own state, and only when switched on", function()
    for _, case in ipairs(VETOES) do
        local key, drive, token = case[1], case[2], case[3]
        local inst = allowedInstance()

        -- Off: the state is live and the window does not care.
        local rules = defaultRules()
        rules[key] = false
        drive(inst.mocks)
        assertEqual(inst.NS.Visibility.ShouldShow(windowWith(rules)), true,
            key .. " hid a window while switched off")

        -- On: the same state now decides, and says so in its own words.
        rules[key] = true
        local show, reason = inst.NS.Visibility.ShouldShow(windowWith(rules))
        assertEqual(show, false, key .. " did not hide")
        assertEqual(reason, token, key .. " reported the wrong reason")
    end
end)

test("A rule switched on with its state absent leaves the window alone", function()
    -- The other half of the case above: no rule may hide on a state that is not
    -- happening. A probe that answered true unconditionally — a namespace guard
    -- inverted, say — would pass the hide half and fail here.
    local inst = allowedInstance()
    local rules = defaultRules()
    for _, case in ipairs(VETOES) do rules[case[1]] = true end
    assertEqual(inst.NS.Visibility.ShouldShow(windowWith(rules)), true)
end)

test("A window whose rules predate these keys is not hidden by them", function()
    local inst = allowedInstance()
    -- Exactly the shape a profile written before this feature carries: the five
    -- original contexts and the two original vetoes, and nothing else.
    local rules = {
        dungeon = true, raid = true, arena = true, battleground = true,
        world = false, hideWhenSolo = false, hideInVehicle = false,
    }
    inst.mocks.setMounted(true)
    inst.mocks.setInHousing(true)
    inst.mocks.setOnTaxi(true)
    inst.mocks.setInPetBattle(true)
    inst.mocks.setDeadOrGhost(true)
    inst.mocks.setCanGlide(true)
    assertEqual(inst.NS.Visibility.ShouldShow(windowWith(rules)), true,
        "a missing key must read as `nothing objects`, not as `hide`")
end)

test("Skyriding hides on capability, before the player has left the ground", function()
    local inst = allowedInstance()
    local rules = defaultRules()
    rules.hideWhenSkyriding = true
    -- Not mounted, not flying: just sitting on a glide-capable mount. The rule is
    -- about having stopped fighting and started travelling.
    assertEqual(select(2, inst.NS.Visibility.ShouldShow(windowWith(rules))), "dungeon")
    inst.mocks.setCanGlide(true)
    assertEqual(select(2, inst.NS.Visibility.ShouldShow(windowWith(rules))), "skyriding")
end)

test("A druid travel form counts as mounted; a combat form does not", function()
    local inst = allowedInstance()
    local rules = defaultRules()
    rules.hideWhenMounted = true

    -- Travel (3), Aquatic (4) and Flight (27) are mount-like. Reading the form
    -- CATEGORY rather than the form's aura is what keeps this working when the
    -- aura's spell id drifts across a patch.
    for _, formID in ipairs{ 3, 4, 27 } do
        inst.mocks.setShapeshiftForm(formID)
        assertEqual(select(2, inst.NS.Visibility.ShouldShow(windowWith(rules))), "mounted",
            "form " .. formID .. " is mount-like")
    end

    -- Cat (1), Bear (5) and Moonkin (31) are how a druid FIGHTS. Hiding the
    -- meter in them would hide it for most of a druid's pull.
    for _, formID in ipairs{ 0, 1, 5, 31 } do
        inst.mocks.setShapeshiftForm(formID)
        assertEqual(select(2, inst.NS.Visibility.ShouldShow(windowWith(rules))), "dungeon",
            "form " .. formID .. " is not a mount")
    end
end)

-- ---------------------------------------------------------------------------
-- The combat rules
-- ---------------------------------------------------------------------------

test("hideInCombat and hideOutOfCombat each own one side of the pull", function()
    local inst = allowedInstance()

    local rules = defaultRules()
    rules.hideOutOfCombat = true
    assertEqual(select(2, inst.NS.Visibility.ShouldShow(windowWith(rules))), "out of combat")
    inst.mocks.setInCombat(true)
    assertEqual(inst.NS.Visibility.ShouldShow(windowWith(rules)), true)

    rules = defaultRules()
    rules.hideInCombat = true
    assertEqual(select(2, inst.NS.Visibility.ShouldShow(windowWith(rules))), "in combat")
    inst.mocks.setInCombat(false)
    assertEqual(inst.NS.Visibility.ShouldShow(windowWith(rules)), true)
end)

test("Both combat rules on is a window that never shows, and says which side", function()
    local inst = allowedInstance()
    local rules = defaultRules()
    rules.hideInCombat, rules.hideOutOfCombat = true, true

    -- Not a state to defend against — a player who ticks both has asked for a
    -- window that never appears — but the reason must still name the side of the
    -- pull they are standing on, or `/mm debug diag` cannot explain it.
    assertEqual(select(2, inst.NS.Visibility.ShouldShow(windowWith(rules))), "out of combat")
    inst.mocks.setInCombat(true)
    assertEqual(select(2, inst.NS.Visibility.ShouldShow(windowWith(rules))), "in combat")
end)

test("The combat answer is read live, with no latched flag to go stale", function()
    local inst = allowedInstance()
    local rules = defaultRules()
    rules.hideInCombat = true
    local window = windowWith(rules)

    -- A cached flag needs a PLAYER_DEAD safety net, because leaving combat by
    -- dying does not reliably fire PLAYER_REGEN_ENABLED and the flag would latch
    -- true until a reload. Reading UnitAffectingCombat at the moment of asking
    -- has no such edge to miss.
    inst.mocks.setInCombat(true)
    assertEqual(inst.NS.Visibility.ShouldShow(window), false)
    inst.mocks.setInCombat(false)
    assertEqual(inst.NS.Visibility.ShouldShow(window), true)
end)

test("Not one rule ships switched on", function()
    -- The roll-call, so that turning a default back on is a deliberate edit to a
    -- test that says why rather than a quiet flip in the template. 0.1.0 shipped
    -- four of these on and the open world off; the reversal is the whole point.
    local v = T.NS.WINDOW_TEMPLATE.visibility
    for _, key in ipairs{ "hideWhenSolo", "hideInVehicle", "hideWhenMounted",
                          "hideWhenSkyriding", "hideOnTaxi", "hideInHousing",
                          "hideInPetBattle", "hideWhenDead", "hideInCombat",
                          "hideOutOfCombat" } do
        assertEqual(v[key], false, key .. " ships switched on")
    end
    for _, key in ipairs{ "dungeon", "raid", "arena", "battleground", "delve",
                          "scenario", "world" } do
        assertEqual(v[key], true, key .. " ships switched off")
    end
end)

test("Context is decided before EVERY veto, however many there are", function()
    local inst = T.load()
    inst.mocks.setInstance(nil)     -- the open world, which ships off
    inst.mocks.setSolo()
    for _, case in ipairs(VETOES) do case[2](inst.mocks) end

    local rules = defaultRules()
    rules.world = false
    for _, case in ipairs(VETOES) do rules[case[1]] = true end
    rules.hideInCombat, rules.hideOutOfCombat = true, true

    -- Eight rules all shouting at once, and the answer is still that open world
    -- is switched off. Order is context, then vetoes — the other way round
    -- reports whichever override happens to be listed first.
    assertEqual(select(2, inst.NS.Visibility.ShouldShow(windowWith(rules))), "world")
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
    cfg.visibility.world = false    -- the player switched the open world off
    mocks.setInstance(nil)

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
    cfg.visibility.world = false    -- the player switched the open world off
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

test("The combat rules use UnitAffectingCombat, never an InCombatLockdown proxy", function()
    -- Lockdown is about whether SECURE writes are legal, and nothing here writes
    -- anything secure. Using it as a proxy for "the player is fighting" is wrong
    -- at both edges of a pull: it latches on slightly before combat and releases
    -- slightly after, which is a window that blinks a beat late every time.
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
                              MSG.ROSTER_CHANGED, MSG.PROFILE_CHANGED,
                              MSG.COMBAT_CHANGED, MSG.PLAYER_STATE_CHANGED } do
        assertTrue((mocks.__busRegistry[message] or {})[NS.Visibility] ~= nil,
            "Visibility must listen on " .. message)
    end

    local fh = assert(io.open(T.root .. "/modules/Visibility.lua", "r"))
    for line in fh:lines() do
        if not line:match("^%s*%-%-") then
            assertFalse(line:gsub("%s%-%-.*$", ""):find("RegisterEvent", 1, true) ~= nil,
                "core/MultiMeters.lua is the addon's single game-event listener")
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
