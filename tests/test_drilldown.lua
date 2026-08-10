-- tests/test_drilldown.lua — modules/DrillDown.lua: the breakdown behind one
-- cell, and the plain boolean that keeps its title from being truth-tested.
--
-- Two properties are the point of this module and both are tested rather than
-- described:
--
--   * the title is DISPLAY-ONLY. It is built with string.format from the
--     meter's ConditionalSecret `name`, and string.format over a secret returns
--     a SECRET STRING — which poisons `if title then`, `title ~= ""`, `#title`
--     and using it as a table key. So "is this window drilled in" is answered by
--     a boolean that never touches the string, and the cases below assert the
--     boolean's TYPE, not merely its truthiness.
--   * the drill-down does NOT sort. modules/Tooltip.lua sorts when comparison is
--     legal because a tooltip is a snapshot; a live view that reshuffled under
--     the cursor the instant the restriction lifted is worse than an order the
--     player can learn. The fixtures ascend so that a sort would be visible.

local T = _G.MYTHICMETERS_TEST

local test        = T.test
local assertEqual = T.assertEqual
local assertTrue  = T.assertTrue
local assertFalse = T.assertFalse
local assertNil   = T.assertNil

local CURRENT = 1
local ALPHA   = "Player-1-0000000A"

local function ascendingSpells()
    return {
        combatSpells = {
            { spellID = 101, totalAmount = 100, amountPerSecond = 10 },
            { spellID = 102, totalAmount = 200, amountPerSecond = 20 },
            { spellID = 103, totalAmount = 300, amountPerSecond = 30 },
        },
        maxAmount = 300, totalAmount = 600,
    }
end

local function bench(opts)
    opts = opts or {}
    local inst = T.load()
    inst.mocks.setSourceDetail(CURRENT, "*", "*", opts.detail or ascendingSpells())
    if opts.restricted then inst.mocks.setRestricted(true) end
    local cfg = inst.NS.Database.GetWindows()[1]
    -- The shipped default is Overall; this fixture seeds the CURRENT session.
    cfg.data.sessionType = CURRENT
    return inst, cfg
end

local function playerRow(opts)
    opts = opts or {}
    return {
        guid          = opts.guid or ALPHA,
        name          = opts.name or "Alpha",
        classFilename = opts.classFilename or "PALADIN",
        deathRecapID  = opts.deathRecapID,
        values        = {},
    }
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

test("DrillDown.IsActive is a PLAIN BOOLEAN, in both directions", function()
    local inst, cfg = bench()
    local D = inst.NS.DrillDown

    -- Not "falsy" — false. A consumer branches on this rather than on the title,
    -- which may be a secret string and may never be truth-tested.
    assertEqual(type(D.IsActive(cfg)), "boolean")
    assertEqual(D.IsActive(cfg), false)

    D:Enter(cfg, playerRow(), "DamageDone")
    assertEqual(type(D.IsActive(cfg)), "boolean")
    assertEqual(D.IsActive(cfg), true)
end)

test("Enter captures PLAIN identity fields, never a reference to the row", function()
    local inst, cfg = bench()
    local row = playerRow()
    assertEqual(inst.NS.DrillDown:Enter(cfg, row, "DamageDone"), true)

    local view = inst.NS.DrillDown.GetState(cfg)
    assertEqual(view.guid, ALPHA)
    assertEqual(view.statKey, "DamageDone")
    assertEqual(view.classFilename, "PALADIN")
    assertEqual(view.sessionType, cfg.data.sessionType)
    assertFalse(view == row, "the row is rebuilt every refresh; holding it pins a stale object")
end)

test("Enter refuses a row with no GUID and a stat this build does not offer", function()
    local inst, cfg = bench()
    local D = inst.NS.DrillDown
    assertEqual(D:Enter(cfg, { name = "no guid" }, "DamageDone"), false)
    assertEqual(D:Enter(cfg, playerRow(), "StatFromALaterBuild"), false)
    assertEqual(D.IsActive(cfg), false)
end)

test("Enter and Exit announce on the bus, with the window id and a boolean", function()
    local inst, cfg = bench()
    local heard = {}
    local bus = inst.NS.NewBusTarget()
    bus:RegisterMessage(inst.NS.Constants.MSG.DRILLDOWN_CHANGED,
        function(_, payload) heard[#heard + 1] = payload end)

    inst.NS.DrillDown:Enter(cfg, playerRow(), "DamageDone")
    inst.NS.DrillDown:Exit(cfg)

    assertEqual(#heard, 2)
    assertEqual(heard[1].windowId, cfg.id)
    assertEqual(heard[1].active, true)
    assertEqual(heard[2].active, false)
end)

test("Exit is a no-op when nothing is open", function()
    local inst, cfg = bench()
    assertEqual(inst.NS.DrillDown:Exit(cfg), false)
end)

test("Drill-down state is session-only, in the shared cache", function()
    local inst, cfg = bench()
    inst.NS.DrillDown:Enter(cfg, playerRow(), "DamageDone")

    -- Logging in to a view of one spell breakdown from last week's raid would be
    -- nonsense, and worse, a stored reference to a sourceGUID that is gone.
    assertTrue(inst.NS.State.Cache("DrillDown")[cfg.id] ~= nil)
    assertNil(inst.NS.db.profile.drilldown)

    inst.NS.State.WipeCache()
    assertEqual(inst.NS.DrillDown.IsActive(cfg), false)
end)

-- ---------------------------------------------------------------------------
-- Rows
-- ---------------------------------------------------------------------------

test("BuildRows returns nil, nil and a FALSE BOOLEAN when the window is not drilled in", function()
    local inst, cfg = bench()
    local rows, title, active = inst.NS.DrillDown:BuildRows(cfg)
    assertNil(rows, "modules/Window.lua decides on the rows, with a single test")
    assertNil(title)
    assertEqual(type(active), "boolean")
    assertEqual(active, false)
end)

test("BuildRows emits aggregator-shaped rows, one per spell", function()
    local inst, cfg = bench()
    inst.NS.DrillDown:Enter(cfg, playerRow(), "DamageDone")

    local rows, title, active = inst.NS.DrillDown:BuildRows(cfg)
    assertEqual(active, true)
    assertEqual(type(title), "string")
    assertEqual(#rows, 3)

    local first = rows[1]
    -- A synthesized plain-string key: the pool keys on guid and a spell has
    -- none, and it must be usable as a table key, so it can never be secret.
    assertEqual(first.guid, "spell:101")
    assertEqual(type(first.guid), "string")
    assertEqual(first.isDrillDown, true)
    assertEqual(first.isLocalPlayer, false)
    -- The drilled-into PLAYER's class, so class-colored bars stay the player's
    -- color through the whole trip.
    assertEqual(first.classFilename, "PALADIN")
    assertEqual(first.icon, inst.mocks.C_Spell.GetSpellInfo(101).iconID)
    assertEqual(first.values.DamageDone.total, 100)
    assertEqual(first.values.DamageDone.rate, 10)
    assertEqual(first.maxAmount, 300, "the source's own max, for bar scaling")
end)

test("BuildRows does NOT sort — the API's order is kept exactly", function()
    local inst, cfg = bench()
    inst.NS.DrillDown:Enter(cfg, playerRow(), "DamageDone")

    -- The fixture ascends. A view that reshuffled the instant the restriction
    -- lifted would be worse than an order the player can learn.
    local rows = inst.NS.DrillDown:BuildRows(cfg)
    assertEqual(rows[1].guid, "spell:101")
    assertEqual(rows[2].guid, "spell:102")
    assertEqual(rows[3].guid, "spell:103")
end)

test("BuildRows builds while restricted, comparing and totaling nothing", function()
    local inst, cfg = bench{ restricted = true }
    inst.NS.DrillDown:Enter(cfg, playerRow{ name = "Alpha" }, "DamageDone")

    local ok, rows = pcall(function() return inst.NS.DrillDown:BuildRows(cfg) end)
    assertTrue(ok, tostring(rows))
    assertEqual(#rows, 3)

    -- The amounts arrived opaque and travel on as opaque handles.
    assertTrue(inst.mocks.isSimulatedSecret(rows[1].values.DamageDone.total))
    assertEqual(inst.mocks.reveal(rows[1].values.DamageDone.total), 100)
    assertEqual(rows[1].guid, "spell:101", "and the order is still the API's")
end)

test("BuildRows skips a spell row it may not access", function()
    local inst, cfg = bench()
    local sealed = inst.mocks.secretTable{ spellID = 999 }
    inst.mocks.C_DamageMeter.GetCombatSessionSourceFromType = function()
        return { combatSpells = { sealed, { spellID = 101, totalAmount = 5 } },
                 maxAmount = 5 }
    end
    inst.mocks.setSecretsAccessible(false)

    inst.NS.DrillDown:Enter(cfg, playerRow(), "DamageDone")
    local rows = inst.NS.DrillDown:BuildRows(cfg)
    assertEqual(#rows, 1)
    assertEqual(rows[1].guid, "spell:101")
end)

test("BuildRows caps the breakdown at the row pool's ceiling", function()
    local inst, cfg = bench()
    local spells = {}
    for i = 1, inst.NS.Constants.MAX_ROWS + 10 do
        spells[i] = { spellID = 1000 + i, totalAmount = i }
    end
    inst.mocks.setSourceDetail(CURRENT, "*", "*",
        { combatSpells = spells, maxAmount = #spells })

    inst.NS.DrillDown:Enter(cfg, playerRow(), "DamageDone")
    assertEqual(#inst.NS.DrillDown:BuildRows(cfg), inst.NS.Constants.MAX_ROWS)
end)

test("BuildRows answers an empty list, not nil, when the provider refuses", function()
    local inst = T.load()
    local cfg = inst.NS.Database.GetWindows()[1]
    inst.NS.DrillDown:Enter(cfg, playerRow(), "DamageDone")

    -- Still drilled in — there is simply nothing behind the cell right now.
    local rows, _, active = inst.NS.DrillDown:BuildRows(cfg)
    assertEqual(type(rows), "table")
    assertEqual(#rows, 0)
    assertEqual(active, true)
end)

test("An unresolvable spell keeps its synthesized key as its name", function()
    local inst, cfg = bench{
        detail = { combatSpells = { { spellID = 909, totalAmount = 5 } }, maxAmount = 5 } }
    inst.mocks.C_Spell.GetSpellInfo = function() return nil end

    inst.NS.DrillDown:Enter(cfg, playerRow(), "DamageDone")
    local rows = inst.NS.DrillDown:BuildRows(cfg)
    assertEqual(rows[1].name, "spell:909")
end)

-- ---------------------------------------------------------------------------
-- The title
-- ---------------------------------------------------------------------------

test("DrillDown.Title is text for a widget, and nil when nothing is open", function()
    local inst, cfg = bench()
    assertNil(inst.NS.DrillDown.Title(cfg))

    inst.NS.DrillDown:Enter(cfg, playerRow{ name = "Alpha" }, "DamageDone")
    assertEqual(inst.NS.DrillDown.Title(cfg), "Alpha - Damage")
end)

test("A view with no name still produces a title, without an `or` on the name", function()
    local inst, cfg = bench()
    -- `view.name or label` would be a truth test on a ConditionalSecret. The one
    -- test the name gets is `~= nil`.
    inst.NS.DrillDown:Enter(cfg, { guid = ALPHA, classFilename = "MAGE" }, "Interrupts")
    assertEqual(inst.NS.DrillDown.Title(cfg), "Interrupts")
end)

test("The window branches on BuildRows' rows, never on its title", function()
    -- The structural claim, checked against the source: modules/Window.lua takes
    -- the drill-down branch on the plain rows table, and the title reaches a
    -- SetText and nothing else.
    local fh = assert(io.open(T.root .. "/modules/Window.lua", "r"))
    local n, offenders, sawRowsBranch = 0, {}, false
    for line in fh:lines() do
        n = n + 1
        if not line:match("^%s*%-%-") then
            local code = line:gsub("%s%-%-.*$", "")
            if code:find("if drillRows then") then sawRowsBranch = true end
            -- Any use of drillTitle other than a nil test or a SetText is a
            -- truth test on a possibly-secret string.
            if code:find("drillTitle") then
                local safe = code:find("drillTitle == nil")
                    or code:find("drillTitle%)")          -- passed on as an argument
                    or code:find("drillTitle$")           -- a parameter list
                    or code:find("drillTitle,")
                if not safe then offenders[#offenders + 1] = "modules/Window.lua:" .. n end
            end
        end
    end
    fh:close()
    assertTrue(sawRowsBranch, "the branch must be taken on the rows table")
    assertEqual(#offenders, 0, "drillTitle is inspected at " .. table.concat(offenders, ", "))
end)

-- ---------------------------------------------------------------------------
-- Click routing
-- ---------------------------------------------------------------------------

test("Clicking a stat cell enters the breakdown", function()
    local inst, cfg = bench()
    assertEqual(inst.NS.DrillDown:OnCellClick(cfg, playerRow(), "DamageDone"), "enter")
    assertEqual(inst.NS.DrillDown.IsActive(cfg), true)
end)

test("Clicking the same cell again returns to the grid", function()
    local inst, cfg = bench()
    local row = playerRow()
    inst.NS.DrillDown:OnCellClick(cfg, row, "DamageDone")
    -- Two ways out, not one: a player who clicked in expects the same click to
    -- take them out.
    assertEqual(inst.NS.DrillDown:OnCellClick(cfg, row, "DamageDone"), "exit")
    assertEqual(inst.NS.DrillDown.IsActive(cfg), false)
end)

test("Clicking a DIFFERENT cell while drilled in switches the view", function()
    local inst, cfg = bench()
    inst.NS.DrillDown:OnCellClick(cfg, playerRow(), "DamageDone")
    assertEqual(inst.NS.DrillDown:OnCellClick(cfg, playerRow(), "Interrupts"), "enter")
    assertEqual(inst.NS.DrillDown.GetState(cfg).statKey, "Interrupts")
end)

test("The Deaths cell routes to the death recap via deathRecapID", function()
    local inst, cfg = bench()
    local action = inst.NS.DrillDown:OnCellClick(cfg,
        playerRow{ deathRecapID = 4242 }, "Deaths")

    assertEqual(action, "recap")
    assertEqual(inst.mocks.__lastRecapID, 4242)
    assertEqual(inst.mocks.__deathRecaps, 1)
    assertEqual(inst.NS.DrillDown.IsActive(cfg), false,
        "a recap is the game's own UI, not a view of ours")
end)

test("A Deaths click falls through to the breakdown when the recap API is absent", function()
    local inst, cfg = bench{}
    -- The addon must degrade rather than leave the cell dead. core/Compat.lua
    -- carries no shim for the recap yet, so the guarded global is what is here.
    inst.mocks.OpenDeathRecapUI = nil

    local action = inst.NS.DrillDown:OnCellClick(cfg,
        playerRow{ deathRecapID = 4242 }, "Deaths")
    assertEqual(action, "enter")
    assertEqual(inst.NS.DrillDown.GetState(cfg).statKey, "Deaths")
end)

test("A Deaths click with no recap id falls through too", function()
    local inst, cfg = bench()
    assertEqual(inst.NS.DrillDown:OnCellClick(cfg, playerRow(), "Deaths"), "enter")
    assertEqual(inst.mocks.__deathRecaps, nil)
end)

test("A Deaths click prefers the Compat shim the moment one exists", function()
    local inst, cfg = bench()
    local seen
    inst.NS.Compat.OpenDeathRecap = function(id) seen = id return true end

    local action = inst.NS.DrillDown:OnCellClick(cfg,
        playerRow{ deathRecapID = 77 }, "Deaths")
    inst.NS.Compat.OpenDeathRecap = nil

    assertEqual(action, "recap")
    assertEqual(seen, 77)
    assertNil(inst.mocks.__lastRecapID, "the shim wins over the guarded global")
end)

test("A click on something that is not a row does nothing", function()
    local inst, cfg = bench()
    assertEqual(inst.NS.DrillDown:OnCellClick(cfg, nil, "DamageDone"), "none")
end)

-- ---------------------------------------------------------------------------
-- The back button
-- ---------------------------------------------------------------------------

test("The back button is created once and re-used forever after", function()
    local inst, cfg = bench()
    local parent = inst.mocks.__stubFrame("Frame")

    local first = inst.NS.DrillDown:AcquireBackButton(cfg, parent, 0, 0)
    assertTrue(first ~= nil)
    assertEqual(first:IsShown(), true)

    local framesBefore = #inst.mocks.__frames
    local second = inst.NS.DrillDown:AcquireBackButton(cfg, parent, 0, 0)
    assertTrue(second == first, "a frame per click would leak one per click")
    assertEqual(#inst.mocks.__frames, framesBefore)

    inst.NS.DrillDown:ReleaseBackButton(cfg)
    assertEqual(first:IsShown(), false, "hidden, never destroyed")
end)

test("The back button is anchored, never measured", function()
    local inst, cfg = bench()
    local parent = inst.mocks.__stubFrame("Frame")
    local button = inst.NS.DrillDown:AcquireBackButton(cfg, parent, 4, -6)

    local point, relativeTo, _, x, y = button:GetPoint(1)
    assertEqual(point, "TOPLEFT")
    assertTrue(relativeTo == parent)
    assertEqual(x, 4)
    assertEqual(y, -6)
end)

test("The back button exits the drill-down", function()
    local inst, cfg = bench()
    inst.NS.DrillDown:Enter(cfg, playerRow(), "DamageDone")
    local button = inst.NS.DrillDown:AcquireBackButton(cfg, inst.mocks.__stubFrame("Frame"), 0, 0)

    button:_run("OnClick")
    assertEqual(inst.NS.DrillDown.IsActive(cfg), false)
end)

-- ---------------------------------------------------------------------------
-- Invalidation
-- ---------------------------------------------------------------------------

test("A meter reset leaves every drill-down", function()
    local inst, cfg = bench()
    inst.NS.DrillDown:Enter(cfg, playerRow(), "DamageDone")
    -- The captured GUIDs describe data that no longer exists.
    inst.NS.DrillDown:OnMeterReset()
    assertEqual(inst.NS.DrillDown.IsActive(cfg), false)
end)

test("Deleting a window leaves the drill-down that belonged to it", function()
    local inst, cfg = bench()
    inst.NS.DrillDown:Enter(cfg, playerRow(), "DamageDone")
    inst.NS.DrillDown:OnWindowsChanged(nil, { windowId = cfg.id, action = "deleted" })
    assertEqual(inst.NS.DrillDown.IsActive(cfg), false)
end)

test("A bulk registry change sweeps views whose window is gone", function()
    local inst, cfg = bench()
    inst.NS.DrillDown:Enter(cfg, playerRow(), "DamageDone")

    -- An action of "deleted" carries the id, but a bulk reset may not — so the
    -- registry is asked rather than the payload trusted.
    local views = inst.NS.State.Cache("DrillDown")
    views[9999] = { guid = ALPHA, statKey = "DamageDone" }
    inst.NS.DrillDown:OnWindowsChanged(nil, {})

    assertNil(views[9999], "the window 9999 does not exist")
    assertEqual(inst.NS.DrillDown.IsActive(cfg), true, "and the live one is untouched")
end)
