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

-- ---------------------------------------------------------------------------
-- The deaths view (issue #1)
-- ---------------------------------------------------------------------------
--
-- A second view kind beside the spell breakdown. Its rows are DEATHS, not
-- spells: the name column carries an ordinal and the drilled column carries the
-- wall-clock time the player died, with a full bar behind it.
--
-- The Deaths click becomes a ladder rather than a replacement. The deaths view
-- first; Blizzard's own frame second, so a client without C_DeathRecap keeps
-- exactly the behaviour it has today; the ordinary breakdown last, so the cell
-- is never dead.

--- A grid row for a player who died `n` times, ids descending as the API gives
--- them.
local function deadRow(ids, opts)
    local row = playerRow(opts)
    row.deaths = {}
    for i = 1, #ids do row.deaths[i] = ids[i] end
    row.deathRecapID = ids[1]
    return row
end

--- Install a client that answers a recap for every id, with a known death time.
local function withRecaps(inst, opts)
    opts = opts or {}
    inst.mocks.setDeathRecap({
        HasRecapEvents    = function(id) return not (opts.missing and opts.missing[id]) end,
        GetRecapEvents    = function(id)
            if opts.missing and opts.missing[id] then return nil end
            return {
                { spellId = 1301253, spellName = "Agony", amount = 327236,
                  currentHP = 179516, overkill = 147720, event = "SPELL_DAMAGE",
                  timestamp = (opts.base or 1787381686) + id },
                { spellId = 264206, spellName = "Burrow", amount = 549517,
                  currentHP = 466585, event = "SPELL_DAMAGE",
                  timestamp = (opts.base or 1787381686) + id - 10 },
            }
        end,
        GetRecapMaxHealth = function() return 738800 end,
    })
end

test("A Deaths click on a player who died enters the DEATHS view", function()
    -- red under: the Deaths branch still handing off to Blizzard's frame first.
    local inst, cfg = bench()
    withRecaps(inst)
    local action = inst.NS.DrillDown:OnCellClick(cfg, deadRow{ 29, 28, 27 }, "Deaths")

    assertEqual(action, "enter")
    assertTrue(inst.NS.DrillDown.IsActive(cfg))
    assertEqual(inst.NS.DrillDown.GetState(cfg).kind, "deaths")
    assertNil(inst.mocks.__lastRecapID, "Blizzard's frame must not also open")
end)

test("The deaths view lists one row per death, newest first", function()
    local inst, cfg = bench()
    withRecaps(inst)
    inst.NS.DrillDown:OnCellClick(cfg, deadRow{ 29, 28, 27 }, "Deaths")

    local rows = inst.NS.DrillDown:BuildRows(cfg)
    assertEqual(#rows, 3)
    assertEqual(rows[1].recapID, 29, "the most recent death is at the top")
    assertEqual(rows[3].recapID, 27)
end)

test("A death row is numbered CHRONOLOGICALLY, so the list counts down", function()
    -- Death 1 is the run's first death. Numbering from the newest would make
    -- "his first death" mean the most recent one, which is the opposite of how
    -- anyone says it.
    -- red under: ordinal = the array index.
    local inst, cfg = bench()
    withRecaps(inst)
    inst.NS.DrillDown:OnCellClick(cfg, deadRow{ 29, 28, 27 }, "Deaths")

    local rows = inst.NS.DrillDown:BuildRows(cfg)
    assertTrue(rows[1].name:find("3", 1, true) ~= nil, "the newest of three is Death 3")
    assertTrue(rows[3].name:find("1", 1, true) ~= nil, "the oldest is Death 1")
end)

test("A death row carries the wall-clock time as its cell caption", function()
    -- The timestamp on a recap event is absolute epoch, unlike deathTimeSeconds
    -- which is seconds-into-session. The two clocks must never be mixed, so the
    -- caption comes from the recap's own newest event.
    -- red under: formatting deathTimeSeconds, which is -1 on Overall.
    local inst, cfg = bench()
    withRecaps(inst, { base = 0 })
    inst.NS.DrillDown:OnCellClick(cfg, deadRow{ 29 }, "Deaths")

    local cell = inst.NS.DrillDown:BuildRows(cfg)[1].values.Deaths
    assertEqual(cell.displayText, inst.mocks.date("%H:%M:%S", 29))
    assertEqual(cell.total, 1)
    assertEqual(cell.maxAmount, 1, "the bar draws full from the data, not a branch")
end)

test("A death whose recap the client has dropped still gets a row", function()
    -- A missing recap must not remove a death the count includes, or the
    -- drill-down and the cell above it disagree about how many times somebody
    -- died.
    -- red under: skipping a death whose GetRecap answers nil.
    local inst, cfg = bench()
    withRecaps(inst, { missing = { [28] = true } })
    inst.NS.DrillDown:OnCellClick(cfg, deadRow{ 29, 28, 27 }, "Deaths")

    local rows = inst.NS.DrillDown:BuildRows(cfg)
    assertEqual(#rows, 3, "a death vanished from the list")
    assertTrue(rows[2].values.Deaths.displayText ~= nil,
        "a row with no recap still needs something in the cell")
end)

test("A Deaths click on a player with no deaths array keeps today's behaviour", function()
    -- The second rung. A client without C_DeathRecap, or a row built before this
    -- feature existed, still reaches Blizzard's own frame rather than a view
    -- with nothing in it.
    local inst, cfg = bench()
    withRecaps(inst)
    local action = inst.NS.DrillDown:OnCellClick(cfg, playerRow{ deathRecapID = 4242 }, "Deaths")
    assertEqual(action, "recap")
    assertEqual(inst.mocks.__lastRecapID, 4242)
end)

test("With no C_DeathRecap a Deaths click does not enter an empty deaths view", function()
    -- red under: entering the view on row.deaths alone, without asking whether
    -- anything can read one.
    local inst, cfg = bench()
    inst.mocks.setDeathRecap(nil)
    local action = inst.NS.DrillDown:OnCellClick(cfg, deadRow{ 29, 28 }, "Deaths")
    assertEqual(action, "recap", "the frame hand-off is still the better fallback")
end)

test("A second click on the same Deaths cell leaves the deaths view", function()
    -- The exit toggle keys on guid + statKey, and the view must keep the
    -- PLAYER's guid for it to keep matching.
    -- red under: storing a synthesized guid on the view.
    local inst, cfg = bench()
    withRecaps(inst)
    local row = deadRow{ 29, 28 }
    inst.NS.DrillDown:OnCellClick(cfg, row, "Deaths")
    assertEqual(inst.NS.DrillDown:OnCellClick(cfg, row, "Deaths"), "exit")
    assertEqual(inst.NS.DrillDown.IsActive(cfg), false)
end)

test("The deaths view never asks the provider for a spell breakdown", function()
    -- Two view kinds, one lifecycle: the deaths branch must skip the source
    -- detail lookup entirely rather than fetching one and ignoring it.
    -- red under: branching after the GetSourceDetail call.
    local inst, cfg = bench()
    withRecaps(inst)
    inst.NS.DrillDown:OnCellClick(cfg, deadRow{ 29 }, "Deaths")
    inst.mocks.resetMeterCalls()

    inst.NS.DrillDown:BuildRows(cfg)
    assertNil(inst.mocks.__meter.calls.GetCombatSessionSourceFromType,
        "the deaths view read a spell breakdown it cannot use")
end)

test("A death row is flagged as a drill-down row", function()
    -- modules/Row.lua keys three behaviours off it: the realm strip, the class
    -- icon ladder, and giving the mouse to the row rather than the cell — which
    -- is the only way the tooltip is reachable at all.
    local inst, cfg = bench()
    withRecaps(inst)
    inst.NS.DrillDown:OnCellClick(cfg, deadRow{ 29 }, "Deaths")
    assertEqual(inst.NS.DrillDown:BuildRows(cfg)[1].isDrillDown, true)
end)

test("The deaths view is capped like every other breakdown", function()
    local inst, cfg = bench()
    withRecaps(inst)
    local ids = {}
    for i = 1, inst.NS.Constants.MAX_ROWS + 10 do ids[i] = 500 - i end
    inst.NS.DrillDown:OnCellClick(cfg, deadRow(ids), "Deaths")
    assertEqual(#inst.NS.DrillDown:BuildRows(cfg), inst.NS.Constants.MAX_ROWS)
end)

test("Clicking a death row opens the game's own recap window", function()
    -- Confirmed in-client: OpenDeathRecapUI renders another player's death in
    -- full when it is handed a live id. The list answers "when", Blizzard's
    -- frame answers "what", and neither has to be rebuilt.
    -- red under: a left click inside a breakdown staying the no-op it is for a
    -- spell row.
    local inst, cfg = bench()
    withRecaps(inst)
    inst.NS.DrillDown:OnCellClick(cfg, deadRow{ 29, 28 }, "Deaths")
    local row = inst.NS.DrillDown:BuildRows(cfg)[2]

    assertEqual(inst.NS.DrillDown:OnRowClick(cfg, row, "LeftButton"), "recap")
    assertEqual(inst.mocks.__lastRecapID, 28, "the row's OWN death, not the newest")
end)

test("Clicking a death row does not leave the list", function()
    -- The frame opens over the window; coming back to a grid the player did not
    -- ask to return to would lose their place in the list.
    local inst, cfg = bench()
    withRecaps(inst)
    inst.NS.DrillDown:OnCellClick(cfg, deadRow{ 29 }, "Deaths")
    inst.NS.DrillDown:OnRowClick(cfg, inst.NS.DrillDown:BuildRows(cfg)[1], "LeftButton")
    assertTrue(inst.NS.DrillDown.IsActive(cfg), "the deaths list closed itself")
end)

test("Right-clicking a death row still leaves the list", function()
    local inst, cfg = bench()
    withRecaps(inst)
    inst.NS.DrillDown:OnCellClick(cfg, deadRow{ 29 }, "Deaths")
    assertEqual(inst.NS.DrillDown:OnRowClick(cfg,
        inst.NS.DrillDown:BuildRows(cfg)[1], "RightButton"), "exit")
    assertEqual(inst.NS.DrillDown.IsActive(cfg), false)
end)

test("Clicking a SPELL row is still a no-op", function()
    -- A spell has no breakdown of its own, and asking for one renders an empty
    -- window that reads as a broken addon.
    -- red under: treating every drill-down row as a death row.
    local inst, cfg = bench()
    inst.NS.DrillDown:OnCellClick(cfg, playerRow(), "DamageDone")
    local row = inst.NS.DrillDown:BuildRows(cfg)[1]
    assertEqual(inst.NS.DrillDown:OnRowClick(cfg, row, "LeftButton"), "none")
    assertTrue(inst.NS.DrillDown.IsActive(cfg))
end)

test("Clicking a death whose recap has gone does nothing rather than opening an empty frame", function()
    local inst, cfg = bench()
    withRecaps(inst)
    inst.NS.DrillDown:OnCellClick(cfg, deadRow{ 29 }, "Deaths")
    local row = inst.NS.DrillDown:BuildRows(cfg)[1]
    inst.mocks.OpenDeathRecapUI = nil

    assertEqual(inst.NS.DrillDown:OnRowClick(cfg, row, "LeftButton"), "none")
end)

test("A death with no recap id is still a row, and is not clickable", function()
    -- It happened; the count says so. It just cannot be opened.
    -- red under: copyRecapIDs dropping the placeholder, which would make the
    -- list shorter than the cell it was opened from.
    local inst, cfg = bench()
    withRecaps(inst)
    local row = playerRow()
    row.deaths = { 29, false, 27 }
    row.deathRecapID = 29
    inst.NS.DrillDown:OnCellClick(cfg, row, "Deaths")

    local rows = inst.NS.DrillDown:BuildRows(cfg)
    assertEqual(#rows, 3, "the unopenable death vanished")
    assertNil(rows[2].recapID)
    assertEqual(inst.NS.DrillDown:OnRowClick(cfg, rows[2], "LeftButton"), "none")
end)

test("Every death row has a distinct pool identity, id or no id", function()
    -- The row pool keys on guid. Two rows sharing one would fight over a widget.
    local inst, cfg = bench()
    withRecaps(inst)
    local row = playerRow()
    row.deaths = { false, false }
    row.deathRecapID = nil
    inst.NS.DrillDown:OnCellClick(cfg, row, "Deaths")

    local rows = inst.NS.DrillDown:BuildRows(cfg)
    assertEqual(#rows, 2)
    assertTrue(rows[1].guid ~= rows[2].guid, "two death rows share a pool identity")
end)

test("A death row's caption follows the window's timestamp setting", function()
    -- red under: deathClock formatting the wall clock unconditionally.
    local inst, cfg = bench()
    withRecaps(inst, { base = 0 })
    cfg.text = cfg.text or {}
    cfg.text.deathTimeFormat = "elapsed"

    local row = playerRow()
    row.deaths, row.deathTimes = { 29 }, { 1356 }
    row.deathRecapID = 29
    inst.NS.DrillDown:OnCellClick(cfg, row, "Deaths")

    assertEqual(inst.NS.DrillDown:BuildRows(cfg)[1].values.Deaths.displayText, "22:36")
end)

test("A death with no session offset falls back to the wall clock", function()
    -- `deathTimeSeconds` is -1 on Overall, which is where most of this list is
    -- looked at. Rendering that as "-1:-1" would be a number that looks like data.
    local inst, cfg = bench()
    withRecaps(inst, { base = 0 })
    cfg.text = cfg.text or {}
    cfg.text.deathTimeFormat = "elapsed"

    local row = playerRow()
    row.deaths, row.deathTimes = { 29 }, { -1 }
    inst.NS.DrillDown:OnCellClick(cfg, row, "Deaths")

    assertEqual(inst.NS.DrillDown:BuildRows(cfg)[1].values.Deaths.displayText,
        inst.mocks.date("%H:%M:%S", 29))
end)

test("The offsets travel with the ids, in step", function()
    -- Two parallel arrays copied into the view. If only one is captured, or they
    -- fall out of step, each death is labelled with the previous one's time.
    local inst, cfg = bench()
    withRecaps(inst, { base = 0 })
    cfg.text = cfg.text or {}
    cfg.text.deathTimeFormat = "elapsed"

    local row = playerRow()
    row.deaths, row.deathTimes = { 29, 28, 27 }, { 1356, 673, 296 }
    inst.NS.DrillDown:OnCellClick(cfg, row, "Deaths")

    local rows = inst.NS.DrillDown:BuildRows(cfg)
    assertEqual(rows[1].values.Deaths.displayText, "22:36")
    assertEqual(rows[2].values.Deaths.displayText, "11:13")
    assertEqual(rows[3].values.Deaths.displayText, "04:56")
end)
