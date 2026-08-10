-- tests/test_window.lua — modules/Window.lua: the two frames, the coalesced
-- refresh clock, and rule R3.
--
-- R3 is the reason this file has two frames instead of one: a StatusBar handed a
-- secret meter value is marked HasSecretValues, its POSITION data becomes secret
-- with it, and that propagates to anything anchored to it. So drag and resize
-- act on a bare anchor frame that never holds a value, and every other
-- coordinate is computed from config. The cases below prove that by POISONING
-- the getters — replacing GetWidth / GetHeight / GetLeft / GetPoint on the live
-- cells with functions that raise — and then driving a full refresh through
-- them. A read that crept back in is a failure with a stack trace, not a comment
-- somebody has to notice.

local T = _G.MYTHICMETERS_TEST

local test        = T.test
local assertEqual = T.assertEqual
local assertTrue  = T.assertTrue
local assertFalse = T.assertFalse
local assertNil   = T.assertNil

local CURRENT = 1

local ALPHA = "Player-1-0000000A"
local BETA  = "Player-1-0000000B"

local GROUP = {
    { guid = ALPHA, name = "Alpha", class = "PALADIN", role = "TANK"    },
    { guid = BETA,  name = "Beta",  class = "PRIEST",  role = "HEALER"  },
}

local function src(guid, total, opts)
    opts = opts or {}
    return {
        sourceGUID      = guid,
        name            = opts.name or guid,
        classFilename   = opts.class or "MAGE",
        totalAmount     = total,
        amountPerSecond = opts.rate or 1,
    }
end

--- A loaded instance, a group, a session, and ONE live window instance whose
--- config has been made unconditionally visible and locked.
---
--- Locked matters: an unlocked window implies preview mode (a player
--- positioning a window at a target dummy needs a full grid), and preview data
--- never touches the provider — which would make every case below vacuous.
local function scene(opts)
    opts = opts or {}
    local inst = T.load()
    local NS, mocks = inst.NS, inst.mocks

    mocks.setGroup(GROUP)
    NS.Roster.Refresh()
    mocks.setSession(CURRENT, "*", {
        combatSources = opts.sources or { src(ALPHA, 100), src(BETA, 50) },
        maxAmount     = 100,
        totalAmount   = 150,
    })
    mocks.setSessionDuration(CURRENT, 212)
    if opts.restricted then mocks.setRestricted(true) end

    local cfg = NS.Database.GetWindows()[1]
    cfg.frame.locked  = true
    cfg.visibility    = { dungeon = true, raid = true, arena = true,
                          battleground = true, world = true,
                          hideWhenSolo = false, hideInVehicle = false }
    cfg.data.sortMode = opts.sortMode or "provider"
    -- The shipped default is Overall; these fixtures seed the CURRENT session,
    -- so the window is pointed at it explicitly rather than every case having to
    -- seed two sessions to assert one thing.
    cfg.data.sessionType = CURRENT
    if opts.configure then opts.configure(cfg) end

    local window = NS.Window.New(cfg)
    window:RefreshVisibility()
    return inst, window, cfg
end

-- ---------------------------------------------------------------------------
-- The two frames
-- ---------------------------------------------------------------------------

test("Window builds a bare anchor plus the visible frame, and names both", function()
    local inst, window = scene()

    assertTrue(window.anchor ~= nil, "the clean geometry frame")
    assertTrue(window.frame ~= nil, "the visible one")
    assertFalse(window.anchor == window.frame)
    assertEqual(window.frame:GetName(), "MythicMetersWindow" .. tostring(window.id))
    assertEqual(window.anchor:GetName(), window.frame:GetName() .. "Anchor")

    -- The visible window inherits the anchor's geometry rather than owning any:
    -- two points, TOPLEFT and BOTTOMRIGHT, both onto the anchor.
    assertEqual(window.frame:GetNumPoints(), 2)
    local point, relativeTo = window.frame:GetPoint(1)
    assertEqual(point, "TOPLEFT")
    assertTrue(relativeTo == window.anchor)

    -- ESC MUST NOT CLOSE IT. A meter is furniture, not a dialog: it is meant to
    -- sit there for a whole raid night, and Escape is a key a player presses
    -- constantly for other reasons — clearing a target, closing somebody else's
    -- frame, leaving a vehicle. Any of those taking the meter down leaves an
    -- empty screen with nothing to say which key did it.
    -- red under: tinsert(UISpecialFrames, name).
    for _, name in ipairs(inst.mocks.UISpecialFrames) do
        assertFalse(name == window.frame:GetName(),
            "the meter must not be in UISpecialFrames")
    end
end)

test("Closing HIDES the window; it never deletes it", function()
    -- `/mm toggle` and the X are the same action. A window you closed comes back
    -- with every setting and every column exactly as you left it; deleting one is
    -- a Windows-page action behind a confirmation.
    local inst, window = scene()
    local before = #inst.NS.Database.GetWindows()

    window:Hide("closed")
    assertEqual(window.frame:IsShown(), false)
    assertEqual(#inst.NS.Database.GetWindows(), before,
        "the configuration survives being closed")
end)

test("The header carries a lock and a gear, and the padlock shows the state", function()
    local _, window, cfg = scene()

    assertTrue(window.lockButton ~= nil)
    assertTrue(window.configButton ~= nil)
    assertTrue(window.lockButton:GetScript("OnClick") ~= nil)
    assertTrue(window.configButton:GetScript("OnClick") ~= nil)

    -- The padlock's art is whatever resolved: an atlas where the client has one,
    -- an ASCII character where it does not. Either way the two states must not
    -- look the same, which is the only thing that makes it a state indicator.
    -- The padlock is ONE asset in two states: there is a confirmed locked atlas
    -- and no unlocked one, so "unlocked" is the same art desaturated and faded.
    -- Whatever the mechanism, the two states must not look identical — that is
    -- the only thing that makes it a state indicator.
    local function art(button)
        return table.concat({
            tostring(button.tex:GetAtlas()),
            tostring(button.tex.__desaturated),
            tostring(button.tex:GetAlpha()),
            tostring(button.glyph:GetText()),
        }, "/")
    end

    cfg.frame.locked = true
    window:ApplyHeaderButtons()
    local lockedArt = art(window.lockButton)

    cfg.frame.locked = false
    window:ApplyHeaderButtons()
    assertFalse(art(window.lockButton) == lockedArt,
        "an open padlock and a closed one must not draw the same art")
end)

test("The padlock toggles THIS window only", function()
    -- Per-window, unlike `/mm lock`, which moves every window at once. A player
    -- clicking a button attached to one window means that one.
    local inst, window, cfg = scene()
    assertTrue(inst.NS.WindowManager:Create("Second"))
    local other = inst.NS.Database.GetWindows()[2]
    other.frame.locked = true
    cfg.frame.locked = true

    window.lockButton:_run("OnClick")
    assertEqual(cfg.frame.locked, false)
    assertEqual(other.frame.locked, true, "the other window did not move")
end)

test("Dragging moves the ANCHOR, never the frame that holds the cells", function()
    local _, window, cfg = scene()
    cfg.frame.locked = false
    window:RefreshUpvalues()

    -- Dragging is the TITLE BAR's job. The body no longer takes the mouse at all,
    -- because taking it stole every hover from the cells underneath — and since a
    -- window ships unlocked, that meant tooltips did not work by default.
    window.dragBar:_run("OnDragStart")
    assertEqual(window.anchor.__moves, 1)
    assertNil(window.frame.__moves, "the value-carrying frame is never moved directly")

    window.dragBar:_run("OnDragStop")
    assertEqual(window.anchor.__stops, 1)
end)

test("A locked window refuses the drag entirely", function()
    local _, window, cfg = scene()
    cfg.frame.locked = true
    window:RefreshUpvalues()

    window.dragBar:_run("OnDragStart")
    assertNil(window.anchor.__moves, "a locked window does not move")
end)

test("SavePosition reads GetPoint off the anchor and off nothing else", function()
    local inst, window, cfg = scene()

    -- Poison the visible frame's getter. Reading position back off a frame whose
    -- cells have held a secret is exactly rule R3's prohibition; it would work
    -- today and become a Lua error the first time a cell received a value.
    window.frame.GetPoint = function()
        error("rule R3: GetPoint was read off the value-carrying frame", 2)
    end

    window.anchor:ClearAllPoints()
    window.anchor:SetPoint("TOPLEFT", inst.mocks.UIParent, "TOPLEFT", 120, -80)
    window:SavePosition()

    assertEqual(cfg.frame.position.point, "TOPLEFT")
    assertEqual(cfg.frame.position.x, 120)
    assertEqual(cfg.frame.position.y, -80)
end)

test("SaveSize uses the size OnSizeChanged was handed, never a getter", function()
    local _, window, cfg = scene()

    window.frame.GetWidth = function() error("rule R3: GetWidth off the frame", 2) end
    window.frame.GetHeight = function() error("rule R3: GetHeight off the frame", 2) end

    -- The handler ARGUMENTS are the new size. Taking them there keeps the resize
    -- path from ever asking a frame a question.
    window.anchor:_run("OnSizeChanged", 640.4, 300.6)
    window:SaveSize()

    assertEqual(cfg.frame.width, 640)
    assertEqual(cfg.frame.height, 301)
end)

-- ---------------------------------------------------------------------------
-- Layout — rule R3 in one function
-- ---------------------------------------------------------------------------

test("BuildLayout computes every coordinate from config alone", function()
    local inst, window, cfg = scene()
    local Const = inst.NS.Constants

    cfg.frame.padding = 6
    cfg.rows.height   = 16
    cfg.rows.spacing  = 1
    cfg.columns = {
        { stat = "DamageDone",  width = 90 },
        { stat = "Interrupts",  width = 40 },
    }
    cfg.frame.width = 500
    local layout = window:BuildLayout()

    assertEqual(layout.nameColumn.x, 0)
    assertEqual(layout.nameColumn.width, Const.NAME_COLUMN_WIDTH)

    -- STAT COLUMNS SHARE WHAT IS LEFT, EQUALLY. The stored per-column width is
    -- the shape a NEW column is born at, not the drawn width — dragging the
    -- window wider used to leave the grid where it was and add empty space, and
    -- narrower used to clip the rightmost column off the edge.
    local expected = math.floor((500 - 12 - Const.NAME_COLUMN_WIDTH - 2 * 2) / 2)
    assertEqual(layout.columns[1].width, expected)
    assertEqual(layout.columns[2].width, expected, "equally, not proportionally")
    assertEqual(layout.columns[1].x, Const.NAME_COLUMN_WIDTH + 2)
    assertEqual(layout.columns[2].x, Const.NAME_COLUMN_WIDTH + 2 + expected + 2)
    assertEqual(layout.rowHeight, 16)
end)

test("A stat column never shrinks below the legible floor", function()
    -- Below Const.COLUMN_MIN_WIDTH a column cannot hold an abbreviated number and
    -- its header at once. The grid stops shrinking and the frame is clamped
    -- instead of drawing something illegible.
    local inst, window, cfg = scene()
    local Const = inst.NS.Constants
    cfg.frame.width = 100          -- far below anything the grid can hold
    local layout = window:BuildLayout()

    for i, col in ipairs(layout.columns) do
        assertEqual(col.width, Const.COLUMN_MIN_WIDTH, "column " .. i)
    end
end)

test("The window refuses to be dragged smaller than the grid needs", function()
    -- Enforced by the CLIENT through SetResizeBounds rather than by clamping in
    -- Lua on every tick, so there is no frame in which the window is drawn at an
    -- illegal size.
    -- red under: never calling SetResizeBounds.
    local inst, window, cfg = scene()
    local Const = inst.NS.Constants
    window:ApplyConfig()

    local minW, minH = window.anchor:GetResizeBounds()
    assertEqual(minW, window.layout.minWidth)
    assertEqual(minH, window.layout.minHeight)

    -- The height floor is the title bar, the column-header strip and ONE row: a
    -- window with room for no rows shows nothing, which is not a size anybody
    -- means to drag to.
    local pad = cfg.frame.padding or 6
    assertEqual(minH, pad * 2 + window.layout.titleHeight
        + window.layout.headerHeight + (cfg.rows.height or 16))
    assertTrue(minW >= Const.NAME_COLUMN_WIDTH + #window.layout.columns * Const.COLUMN_MIN_WIDTH)
end)

test("BuildLayout drops a column whose stat this build does not offer", function()
    local _, window, cfg = scene()
    cfg.columns = {
        { stat = "DamageDone", width = 90 },
        { stat = "StatFromALaterBuild", width = 90 },
    }
    local layout = window:BuildLayout()
    assertEqual(#layout.columns, 1, "a nameless empty column is worse than an absent one")
    assertEqual(layout.columns[1].key, "DamageDone")
end)

test("BuildLayout derives how many rows FIT, capped by maxRows and MAX_ROWS", function()
    local inst, window, cfg = scene()

    cfg.frame.height = 220
    cfg.rows.maxRows = 0        -- "as many as fit"
    local fits = window:BuildLayout().maxRows
    assertTrue(fits > 1, "a 220px window fits more than one 16px row")

    cfg.rows.maxRows = 3
    assertEqual(window:BuildLayout().maxRows, 3, "a positive cap wins when it is smaller")

    cfg.frame.height = 4000
    cfg.rows.maxRows = 0
    assertEqual(window:BuildLayout().maxRows, inst.NS.Constants.MAX_ROWS,
        "and the hard ceiling wins over the frame height")
end)

test("The throttle is clamped to the constants, whatever the profile says", function()
    local inst, window, cfg = scene()
    local Const = inst.NS.Constants

    cfg.data.throttle = 0
    window:RefreshUpvalues()
    assertEqual(window.throttle, Const.THROTTLE_MIN,
        "zero would turn every meter event into a full rebuild")

    cfg.data.throttle = 99
    window:RefreshUpvalues()
    assertEqual(window.throttle, Const.THROTTLE_MAX)
end)

-- ---------------------------------------------------------------------------
-- The refresh clock
-- ---------------------------------------------------------------------------

test("The throttle coalesces N events into ONE refresh", function()
    local _, window, cfg = scene()
    cfg.data.throttle = 0.25
    window:RefreshUpvalues()

    local refreshes = 0
    window.Refresh = function() refreshes = refreshes + 1 end

    window.dirty, window.elapsed = false, 0
    -- Twenty meter events. Every message handler in the file does nothing but
    -- set the flag; only the clock turns a flag into work.
    for _ = 1, 20 do window:MarkDirty() end

    for _ = 1, 4 do window.frame:_run("OnUpdate", 0.05) end
    assertEqual(refreshes, 0, "0.20s of a 0.25s throttle has not elapsed")

    window.frame:_run("OnUpdate", 0.05)
    assertEqual(refreshes, 1, "twenty events, one refresh")

    for _ = 1, 10 do window.frame:_run("OnUpdate", 0.05) end
    assertEqual(refreshes, 1, "and nothing more until something is dirty again")
end)

test("A clean window costs nothing when the clock comes round", function()
    local _, window = scene()
    local refreshes = 0
    window.Refresh = function() refreshes = refreshes + 1 end
    window.dirty, window.elapsed = false, 0
    for _ = 1, 20 do window.frame:_run("OnUpdate", 0.05) end
    assertEqual(refreshes, 0)
end)

test("Refresh does nothing at all while the frame is hidden", function()
    local inst, window = scene()
    window:Hide("test")
    inst.mocks.resetMeterCalls()

    window:MarkDirty()
    window:Refresh()
    for name, count in pairs(inst.mocks.__meter.calls) do
        assertEqual(count, 0, "a hidden window called " .. name)
    end
end)

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

test("Refresh draws one row per aggregated entry, from the pool", function()
    local _, window = scene()
    window:Refresh()

    assertEqual(#window.pool.active, 2)
    assertEqual(window.pool.active[1].entry.guid, ALPHA)
    assertEqual(window.pool.active[2].entry.guid, BETA)
    assertEqual(window.pool.active[1].frame:IsShown(), true)
    assertFalse(window.notice:IsShown(), "there is data, so no notice")
end)

test("Rows come from a POOL: no CreateFrame on a second refresh", function()
    local inst, window = scene()
    local Const = inst.NS.Constants

    window:Refresh()
    -- The pool grows a batch at a time, so one acquire builds POOL_GROW_STEP.
    assertEqual(#window.pool.all, Const.POOL_GROW_STEP)
    assertEqual(#window.pool.free, Const.POOL_GROW_STEP - 2)

    local framesBefore = #inst.mocks.__frames
    window:Refresh()
    window:Refresh()
    assertEqual(#inst.mocks.__frames, framesBefore,
        "WoW never truly frees a frame; a reshuffling raid must not churn them")
    assertEqual(#window.pool.all, Const.POOL_GROW_STEP)
    assertEqual(#window.pool.active, 2, "released and re-acquired, not recreated")
end)

test("HideAll returns every active row to the free list", function()
    local _, window = scene()
    window:Refresh()
    window:HideAll()

    assertEqual(#window.pool.active, 0)
    assertEqual(#window.pool.free, #window.pool.all)
    for _, row in ipairs(window.pool.all) do
        assertEqual(row.frame:IsShown(), false)
        assertNil(row.entry, "a released row holds no reference to the player it drew")
    end
end)

test("Render honors layout.maxRows and places rows from Row.OffsetFor", function()
    local inst, window, cfg = scene{
        sources = { src(ALPHA, 100), src(BETA, 50) },
    }
    cfg.rows.maxRows = 1
    window:ApplyConfig()
    window:Refresh()

    assertEqual(#window.pool.active, 1)

    cfg.rows.maxRows = 0
    window:ApplyConfig()
    window:Refresh()
    assertEqual(#window.pool.active, 2)

    local layout = window.layout
    local second = window.pool.active[2].frame
    local _, _, _, _, y = second:GetPoint(1)
    assertEqual(-y, inst.NS.Row.OffsetFor(layout, 2),
        "the vertical position is a pure function of the index and the row config")
end)

test("growthDirection UP anchors from the bottom of the body", function()
    local _, window, cfg = scene()
    cfg.rows.growthDirection = "UP"
    window:ApplyConfig()
    window:Refresh()

    local point = window.pool.active[1].frame:GetPoint(1)
    assertEqual(point, "BOTTOMLEFT")
end)

-- ---------------------------------------------------------------------------
-- Rule R3, driven
-- ---------------------------------------------------------------------------

--- Replace the four geometry getters on every cell of every pooled row with
--- functions that raise, and hand back a restore function.
local function poisonCellGetters(window)
    local poisoned = {}
    local GETTERS = { "GetWidth", "GetHeight", "GetLeft", "GetPoint" }
    for _, row in ipairs(window.pool.all) do
        local cells = { row.nameCell }
        for _, cell in pairs(row.cells) do cells[#cells + 1] = cell end
        for _, cell in ipairs(cells) do
            poisoned[#poisoned + 1] = cell.frame
            for _, name in ipairs(GETTERS) do
                cell.frame[name] = function()
                    error("rule R3: " .. name .. " was read off a cell that has held a value", 2)
                end
            end
        end
    end
    return function()
        for _, frame in ipairs(poisoned) do
            for _, name in ipairs(GETTERS) do frame[name] = nil end
        end
    end
end

test("R3: no geometry is read back off a cell that has held a secret", function()
    local _, window = scene{ restricted = true }

    window:Refresh()

    -- The bars really are marked, which is what makes the poisoning meaningful:
    -- these are the frames whose anchoring data the client has just made secret.
    local marked = 0
    for _, row in ipairs(window.pool.active) do
        for _, cell in pairs(row.cells) do
            if cell.frame:HasSecretValues() then marked = marked + 1 end
        end
    end
    assertTrue(marked > 0, "the fixture must actually hand secrets to the bars")

    local restore = poisonCellGetters(window)
    local ok, err = pcall(function()
        window:MarkDirty()
        window:Refresh()
        window:ApplyLock()
        window:UpdateHeaderText(false)
    end)
    restore()
    assertTrue(ok, tostring(err))
end)

test("modules/Window.lua reads geometry back off the anchor and nothing else", function()
    -- A static sweep beside the dynamic one: the dynamic case can only catch a
    -- read on a path it happened to drive, and this catches the line.
    local fh = assert(io.open(T.root .. "/modules/Window.lua", "r"))
    local n, offenders = 0, {}
    for line in fh:lines() do
        n = n + 1
        if not line:match("^%s*%-%-") then
            local code = line:gsub("%s%-%-.*$", "")
            for _, getter in ipairs{ "GetWidth", "GetHeight", "GetLeft", "GetPoint" } do
                local at = code:find(":" .. getter .. "%(")
                if at and not code:find("self%.anchor:" .. getter) then
                    offenders[#offenders + 1] = "modules/Window.lua:" .. n
                end
            end
        end
    end
    fh:close()
    assertEqual(#offenders, 0,
        "geometry is read off something other than the anchor: "
        .. table.concat(offenders, ", "))
end)

-- ---------------------------------------------------------------------------
-- The meter-unavailable path
-- ---------------------------------------------------------------------------

test("An unavailable meter renders the prompt INSTEAD of rows", function()
    local inst, window = scene()
    window:Refresh()
    assertEqual(#window.pool.active, 2)

    inst.mocks.setMeterAvailable(false, "DAMAGE_METER_DISABLED_BY_CVAR")
    inst.NS.Provider.InvalidateAvailability()
    window:Refresh()

    assertEqual(#window.pool.active, 0, "the rows come down")
    assertEqual(window.notice:IsShown(), true)

    local text = window.notice:GetText()
    assertTrue(text:find("built%-in damage meter") ~= nil, "it says where the numbers come from")
    -- Blizzard's own reason, quoted rather than interpreted: the game knows why
    -- its meter is off, and guessing on its behalf sends the player to the wrong
    -- setting.
    assertTrue(text:find("DAMAGE_METER_DISABLED_BY_CVAR", 1, true) ~= nil)
end)

test("The notice omits a reason it cannot safely render", function()
    local inst, window = scene()
    inst.mocks.setMeterAvailable(false, nil)
    inst.NS.Provider.InvalidateAvailability()
    window:Refresh()

    assertEqual(window.notice:IsShown(), true)
    assertFalse(window.notice:GetText():find("Reason") ~= nil,
        "a nil reason must not become the string 'nil'")
end)

test("An empty session says so rather than leaving a blank grid", function()
    local inst, window = scene()
    inst.mocks.setSession(CURRENT, "*", { combatSources = {}, maxAmount = 0, totalAmount = 0 })
    window:Refresh()

    assertEqual(#window.pool.active, 0)
    assertEqual(window.notice:IsShown(), true)
    assertTrue(window.notice:GetText():find("Waiting for combat", 1, true) ~= nil,
        "an empty grid with no explanation reads as a broken addon")
end)

-- ---------------------------------------------------------------------------
-- The show ladder
-- ---------------------------------------------------------------------------

test("ShouldShow STEP 0 is NS.Perf.suspended, above even the master enable", function()
    local inst = T.load()
    local NS = inst.NS
    local cfg = NS.Database.GetWindows()[1]
    cfg.visibility.world = true
    cfg.visibility.hideWhenSolo = false

    assertEqual(select(2, NS.ShouldShow(cfg)), "shown")

    -- Nothing may re-show a window behind suspend's back — not preview, not the
    -- master enable, not a context change (performance-§6).
    NS.State.SetTestMode(true)
    NS.Perf.suspended = true
    local show, reason = NS.ShouldShow(cfg)
    NS.Perf.suspended = false
    NS.State.SetTestMode(false)

    assertEqual(show, false)
    assertEqual(reason, "suspended")
end)

test("ShouldShow's ladder reads master enable, then test mode, then context", function()
    local inst = T.load()
    local NS = inst.NS
    local cfg = NS.Database.GetWindows()[1]

    NS.db.profile.enabled = false
    assertEqual(select(2, NS.ShouldShow(cfg)), "disabled")
    NS.db.profile.enabled = true

    -- The open world ships off, so this window is refused by context...
    assertEqual(NS.ShouldShow(cfg), false)
    -- ...until test mode, which shows regardless: the whole point is to lay a
    -- layout out wherever the player happens to be standing.
    --
    -- ONE-WAY. Test mode can force a window ON and never forces one off, which is
    -- what stops `/mm test` from reading as a close button with a confusing name.
    NS.State.SetTestMode(true)
    local show, reason = NS.ShouldShow(cfg)
    NS.State.SetTestMode(false)
    assertEqual(show, true)
    assertEqual(reason, "test")

    assertEqual(select(2, NS.ShouldShow(nil)), "no window")
end)

test("RefreshVisibility shows, hides, and marks dirty exactly once on the way in", function()
    local inst, window, cfg = scene()
    assertEqual(window:IsShown(), true)

    cfg.visibility.world = false
    inst.mocks.setInstance(nil)
    local show, reason = window:RefreshVisibility()
    assertEqual(show, false)
    assertEqual(reason, "world")
    assertEqual(window:IsShown(), false)
    assertEqual(#window.pool.active, 0, "hiding releases the rows")

    cfg.visibility.world = true
    window.dirty = false
    assertEqual(window:RefreshVisibility(), true)
    assertEqual(window.dirty, true)
    assertEqual(window.elapsed, window.throttle, "it draws on the next tick, not in 0.25s")
end)

-- ---------------------------------------------------------------------------
-- The header line
-- ---------------------------------------------------------------------------

test("The header folds its parts with `..`, and survives a secret duration", function()
    local _, window, cfg = scene{ restricted = true }
    cfg.header.showSessionName = true
    cfg.header.showDuration    = true
    cfg.header.showTotals      = true
    window:ApplyConfig()

    -- Two of the pieces come out of NS.Format having been built from a secret,
    -- and a formatted secret is itself secret. `..` is legal on one;
    -- table.concat is the one string operation that RAISES on one.
    window:Refresh()

    local line = window.sessionText:GetText()
    assertEqual(type(line), "string")
    assertTrue(line:find("Current", 1, true) ~= nil, "which session")
    assertTrue(line:find("212", 1, true) ~= nil, "how long it has run")
end)

test("The header says so when the row order has stopped tracking the numbers", function()
    local inst, window, cfg = scene{ restricted = true, sortMode = "value" }
    cfg.header.showSessionName = true
    -- core/State.lua's mirror is the cheap read of the fact core/Secrets.lua is
    -- the authority on; core/MythicMeters.lua is its only writer, so a headless
    -- scene has to seed it the way OnEnable does.
    inst.NS.State.SetRestricted(true)
    window:ApplyConfig()
    window:Refresh()

    -- The player is watching a list that no longer reorders and is owed the
    -- reason.
    assertTrue(window.sessionText:GetText():find("frozen", 1, true) ~= nil)
end)

test("The header line reads 'Test' while placeholder data is on screen", function()
    local inst, window = scene()
    inst.NS.State.SetTestMode(true)
    window:Refresh()
    assertTrue(window.sessionText:GetText():find("Test", 1, true) ~= nil)
end)

test("Test data never reaches the provider", function()
    local inst, window = scene()
    inst.NS.State.SetTestMode(true)
    inst.mocks.resetMeterCalls()
    window:Refresh()

    assertEqual(inst.mocks.__meter.calls.GetCombatSessionFromType or 0, 0)
    assertTrue(#window.pool.active > 2, "and the grid is full, which is the point")
end)

test("UNLOCKING A WINDOW NO LONGER TURNS TEST DATA ON", function()
    -- The first bug reported against the addon. A fresh install ships unlocked,
    -- so the very first login showed placeholder rows, and no amount of
    -- unchecking "Preview mode" cleared them — the lock was forcing it back on.
    -- Three controls each did two things; each now does one.
    -- red under: `return State.testMode or not self.locked`.
    local inst, window, cfg = scene()
    cfg.frame.locked = false
    window:ApplyConfig()

    assertFalse(window:IsTest(), "an unlocked window shows REAL data")
    inst.mocks.resetMeterCalls()
    window:Refresh()
    assertTrue((inst.mocks.__meter.calls.GetCombatSessionFromType or 0) > 0,
        "and therefore reads the meter")
end)

-- ---------------------------------------------------------------------------
-- The drill-down branch
-- ---------------------------------------------------------------------------

test("A drilled-in window draws the breakdown, decided by the ROWS not the title", function()
    local inst, window, cfg = scene{ restricted = true }
    local NS, mocks = inst.NS, inst.mocks

    mocks.setSourceDetail(CURRENT, "*", "*", {
        combatSpells = {
            { spellID = 101, totalAmount = 60, amountPerSecond = 6 },
            { spellID = 102, totalAmount = 40, amountPerSecond = 4 },
        },
        maxAmount = 60, totalAmount = 100,
    })
    NS.DrillDown:Enter(cfg, { guid = ALPHA, name = "Alpha", classFilename = "PALADIN" },
        "DamageDone")

    window:Refresh()

    assertEqual(#window.pool.active, 2, "two spells, drawn through the ordinary row pool")
    assertEqual(window.pool.active[1].entry.guid, "spell:101")
    assertEqual(window.pool.active[1].entry.isDrillDown, true)

    -- The title is display-only and may be a secret string; the branch above it
    -- was taken on the plain rows table.
    assertEqual(window.sessionText:GetText(), NS.DrillDown.Title(cfg))

    NS.DrillDown:Exit(cfg)
    window:Refresh()
    assertEqual(window.pool.active[1].entry.guid, ALPHA, "and back to the grid")
end)

-- ---------------------------------------------------------------------------
-- Suspend and teardown
-- ---------------------------------------------------------------------------

test("Suspend takes the OnUpdate away and Resume puts it back", function()
    local _, window = scene()

    window:Suspend()
    assertNil(window.frame:GetScript("OnUpdate"),
        "a pass already queued must not fire once more inside a measurement window")

    window:Resume()
    assertTrue(window.frame:GetScript("OnUpdate") ~= nil)
end)

test("Destroy takes the window off screen and off the bus", function()
    local inst, window = scene()
    window:Refresh()
    window:Destroy()

    assertEqual(window:IsShown(), false)
    assertEqual(#window.pool.active, 0)
    assertNil(window.frame:GetScript("OnUpdate"))

    local MSG = inst.NS.Constants.MSG
    assertNil((inst.mocks.__busRegistry[MSG.METER_UPDATED] or {})[window.bus])
end)

test("Each window owns a PRIVATE bus target, so two windows cannot clobber each other", function()
    local inst, first, cfg = scene()
    local second = inst.NS.Window.New(cfg)

    assertFalse(first.bus == second.bus,
        "CallbackHandler keys callbacks by (message, target); a shared target loses all but one")

    first.dirty, second.dirty = false, false
    inst.NS:SendMessage(inst.NS.Constants.MSG.METER_UPDATED)
    assertEqual(first.dirty, true)
    assertEqual(second.dirty, true, "both windows heard it")
end)

-- ---------------------------------------------------------------------------
-- The segment selector
-- ---------------------------------------------------------------------------

--- A scene whose client is holding two stored segments.
local function withSegments(opts)
    opts = opts or {}
    local inst, window, cfg = scene(opts)
    inst.mocks.setAvailableSessions{
        { sessionID = 4, name = "Bribed Guard", durationSeconds = 22 },
        { sessionID = 5, name = "Bribed Guard", durationSeconds = 17 },
    }
    return inst, window, cfg
end

test("Segment menu: stored segments first, then a divider, then Current/Overall", function()
    -- The reason to open this menu at all is almost always to look back at a
    -- fight that just ended, so the fights come first.
    local inst, window = withSegments()
    assertTrue(window:OpenSegmentMenu(), "the menu must actually open")

    local menu = inst.mocks.__lastMenu
    local kinds = {}
    for _, e in ipairs(menu.entries) do kinds[#kinds + 1] = e.kind end
    assertEqual(table.concat(kinds, ","), "title,button,button,divider,button,button")

    assertEqual(menu:Nth("button", 3).text, inst.NS.L["Current"])
    assertEqual(menu:Nth("button", 4).text, inst.NS.L["Overall"])
end)

test("Segment menu: an entry is labelled with its name AND its duration", function()
    local inst, window = withSegments()
    window:OpenSegmentMenu()
    assertEqual(inst.mocks.__lastMenu:Nth("button", 1).text, "Bribed Guard   0:22")
end)

test("Segment menu: picking a segment pins it and marks the window dirty", function()
    local inst, window, cfg = withSegments()
    window:OpenSegmentMenu()
    window.dirty = false

    inst.mocks.__lastMenu:Nth("button", 2).callback()
    assertEqual(cfg.data.sessionID, 5, "the SECOND stored segment, not the first")
    assertEqual(window.dirty, true, "a pinned segment has to redraw to take effect")
end)

test("Segment menu: picking Current CLEARS the pin", function()
    -- Picking "Current" out of a menu that is showing a stored fight means "stop
    -- showing that fight". Leaving the id set would make the choice do nothing.
    -- red under: SetSessionType writing sessionType without nil-ing sessionID.
    local inst, window, cfg = withSegments()
    window:SetSegment(4)

    window:OpenSegmentMenu()
    inst.mocks.__lastMenu:Nth("button", 3).callback()

    assertNil(cfg.data.sessionID)
    assertEqual(cfg.data.sessionType, inst.NS.Constants.SESSION_TYPE.Current)
end)

test("Segment menu: with no menu API the click is refused, not an error", function()
    local inst, window = withSegments()
    inst.mocks.MenuUtil = nil
    assertFalse(window:OpenSegmentMenu())
end)

test("Segment: a pinned segment is READ, not merely stored", function()
    -- The whole point. red under: an aggregator that ignores pass.sessionID,
    -- which would leave the header claiming a segment while the grid showed the
    -- live pull.
    local inst, window, cfg = withSegments()
    inst.mocks.setSession(4, "*", {
        combatSources = { src(ALPHA, 999) }, maxAmount = 999, totalAmount = 999,
    })
    cfg.data.sessionID = 4
    inst.mocks.resetMeterCalls()

    window:Refresh()
    assertEqual(inst.mocks.__meter.calls.GetCombatSessionFromID ~= nil, true,
        "the pinned segment was never read")
end)

test("Segment: the header names the pinned segment rather than lying `Current`", function()
    local _, window, cfg = withSegments()
    cfg.data.sessionID = 4
    assertEqual(window:SessionLabel(false), "Bribed Guard   0:22")

    cfg.data.sessionID = nil
    assertEqual(window:SessionLabel(false), "Current",
        "and with no pin it goes back to naming the session type")
end)

test("Segment: a stale pin is dropped on the next refresh", function()
    -- sessionID is persisted, so a window can come back from a reload or a meter
    -- reset still pointed at a segment the client has discarded. A stale id does
    -- not error — it silently reads an empty session, which looks like a broken
    -- addon.
    -- red under: removing the DropStaleSegment call from Refresh.
    local _, window, cfg = withSegments()
    cfg.data.sessionID = 99

    window:Refresh()
    assertNil(cfg.data.sessionID, "a segment the client no longer holds must be forgotten")
end)

test("Segment: a LIVE pin survives the staleness check", function()
    local _, window, cfg = withSegments()
    cfg.data.sessionID = 5
    window:Refresh()
    assertEqual(cfg.data.sessionID, 5)
end)

test("Segment: with no provider the pin is left alone rather than rewritten", function()
    -- No provider is a broken install, not a stale segment. Dropping the pin
    -- there would quietly rewrite the player's setting because of our load order.
    local inst, window, cfg = withSegments()
    cfg.data.sessionID = 4
    inst.NS.Provider = nil
    window:DropStaleSegment()
    assertEqual(cfg.data.sessionID, 4)
end)

test("Segment: the session line is a BUTTON and the text rides on it", function()
    -- A click target positioned separately from the text it claims to cover is a
    -- click target that drifts the first time either moves.
    local _, window = withSegments()
    assertTrue(window.sessionButton ~= nil)
    assertEqual(window.sessionButton.mmWindow, window)
    assertTrue(window.sessionButton:GetScript("OnClick") ~= nil,
        "the header line has to be clickable for the selector to be reachable")
end)

-- ---------------------------------------------------------------------------
-- Sorting from the column headers
-- ---------------------------------------------------------------------------

test("Column headers are BUTTONS carrying the full stat label, left-aligned", function()
    -- A player reading "AVD" has to remember what it stood for. The header is
    -- read far less often than the numbers under it, so the space is worth it.
    local inst, window = scene{ configure = function(c)
        c.columns = {
            { stat = "DamageDone", width = 92, showBar = true },
            { stat = "AvoidableDamageTaken", width = 92, showBar = true },
        }
    end }
    local L = inst.NS.L

    local name, damage, avoidable = window.columnHeaders[1], window.columnHeaders[2],
        window.columnHeaders[3]
    assertEqual(name.text:GetText(), L["Player"])
    assertEqual(damage.text:GetText(), L["Damage"], "the full label, not DMG")
    assertEqual(avoidable.text:GetText(), L["Avoidable"],
        "the one stat whose full label does not fit a column")
    assertEqual(damage.text:GetJustifyH(), "LEFT")
    assertTrue(damage:GetScript("OnClick") ~= nil, "a header has to be clickable to sort")
end)

test("The sort column shows an arrow and the others do not", function()
    local _, window, cfg = scene{ sortMode = "value" }
    cfg.data.sortColumn = "DamageDone"
    window:ApplyColumnHeaders()

    -- Texture where the client has the atlas, ASCII where it does not — the
    -- marker is that ONE of them is drawn.
    local function marked(button)
        return button.arrowTex:IsShown() or button.arrow:IsShown()
    end

    local damage = window.columnHeaders[2]
    assertEqual(damage.mmKey, "DamageDone")
    assertTrue(marked(damage))
    assertFalse(marked(window.columnHeaders[3]),
        "only the column the rows are actually ordered by is marked")
end)

test("The arrow flips with the direction", function()
    local _, window, cfg = scene{ sortMode = "value" }
    cfg.data.sortColumn = "DamageDone"

    -- A GLYPH, not a texture. The first version used
    -- `Interface\\Buttons\\UI-SortArrow-Up/-Down`, which do not exist — and a
    -- texture that fails to load is silent, so the column simply had no arrow and
    -- there was nothing to read.
    -- red under: SetTexture on a path that does not resolve.
    -- The shipped arrow points DOWN; ascending is the same texture flipped, which
    -- is one SetTexCoord rather than a second asset to go missing.
    local function arrowState(button)
        return tostring(button.arrow:GetText()) .. "/" ..
            table.concat({ button.arrowTex:GetTexCoord() }, ",")
    end

    cfg.data.sortAscending = false
    window:ApplyColumnHeaders()
    local down = arrowState(window.columnHeaders[2])

    cfg.data.sortAscending = true
    window:ApplyColumnHeaders()
    assertFalse(arrowState(window.columnHeaders[2]) == down,
        "ascending and descending must not draw the same arrow")
end)

test("Clicking a header sorts by it; clicking again reverses", function()
    local _, window, cfg = scene{ sortMode = "provider" }

    assertTrue(window:SortByColumn("Interrupts"))
    assertEqual(cfg.data.sortColumn, "Interrupts")
    assertEqual(cfg.data.sortMode, "value", "picking a column implies ordering by its values")
    assertEqual(cfg.data.sortAscending, false, "largest first on the first click")

    assertTrue(window:SortByColumn("Interrupts"))
    assertEqual(cfg.data.sortAscending, true, "the second click reverses")

    assertTrue(window:SortByColumn("DamageDone"))
    assertEqual(cfg.data.sortColumn, "DamageDone")
    assertEqual(cfg.data.sortAscending, false,
        "a DIFFERENT column starts descending rather than inheriting the flip")
end)

test("Clicking a header drops the frozen sort order", function()
    -- The freeze is a snapshot of the OLD sort and would be reapplied over the
    -- new one for the rest of the pull, so the click would appear to do nothing.
    -- red under: removing the WipeCache("Aggregator") call.
    local inst, window = scene{ sortMode = "value" }
    local frozen = inst.NS.State.Cache("Aggregator")
    frozen[window.id] = { "Player-1-0000000A" }

    window:SortByColumn("Interrupts")
    assertNil(inst.NS.State.Cache("Aggregator")[window.id])
end)

test("Sorting is REFUSED in combat, and says so rather than going quiet", function()
    -- Ordering by value means comparing meter values, which raises while they are
    -- secret. A click that silently did nothing would read as a broken button.
    -- red under: dropping the IsRestricted guard from SortByColumn.
    local inst, window, cfg = scene{ sortMode = "value", restricted = true }
    cfg.data.sortColumn = "DamageDone"

    local said = {}
    inst.NS.Print = function(msg) said[#said + 1] = msg end

    assertFalse(window:SortByColumn("Interrupts"))
    assertEqual(cfg.data.sortColumn, "DamageDone", "the order must not have moved")
    assertEqual(#said, 1, "the player is owed the reason")
end)

test("The Player header sorts by group order, which is legal in combat", function()
    -- "Sort by name" would be a string comparison on a ConditionalSecret name.
    -- Group order is the stable, always-legal thing a player means by clicking it.
    local _, window, cfg = scene{ sortMode = "value", restricted = true }

    assertTrue(window:SortByColumn("name"), "the name header works while restricted")
    assertEqual(cfg.data.sortMode, "roster")
    assertTrue(window:SortByColumn("name"))
    assertEqual(cfg.data.sortMode, "value", "and toggles back")
end)

test("Test mode is marked in RED in the title, and clears when it is off", function()
    -- Test mode fills the grid with numbers that look exactly like real ones —
    -- that is the point of it — so the only thing between a player and reading
    -- placeholder data as their own performance is a label saying otherwise.
    -- red under: writing the title without consulting State.testMode.
    local inst, window = scene()
    assertFalse(window.frame.title:GetText():find("TEST MODE", 1, true) ~= nil)

    inst.NS.State.SetTestMode(true)
    local marked = window.frame.title:GetText()
    assertTrue(marked:find("TEST MODE", 1, true) ~= nil, "the marker must appear on the toggle")
    assertTrue(marked:find("|cffff2020", 1, true) ~= nil, "and it must be red")

    inst.NS.State.SetTestMode(false)
    assertFalse(window.frame.title:GetText():find("TEST MODE", 1, true) ~= nil)
end)

test("Leaving test mode does not close the window", function()
    -- Test mode forces a window visible. Without a matching Show on the way out,
    -- turning it off just stopped forcing and the ordinary visibility rules hid a
    -- window the player was looking at — so `/mm test` read as a close button
    -- with a confusing name.
    -- red under: dropping the Show loop from settings/Slash.lua's doTest.
    local inst = T.load()
    local cfg = inst.NS.Database.GetWindows()[1]
    cfg.visibility = { dungeon = false, raid = false, arena = false,
                       battleground = false, world = false,
                       hideWhenSolo = false, hideInVehicle = false }
    inst.NS.WindowManager:Init()

    inst.NS.Slash:OnSlash("test on")
    assertTrue(inst.NS.WindowManager.All()[1]:IsShown(), "test mode forces it visible")

    inst.NS.Slash:OnSlash("test off")
    assertTrue(inst.NS.WindowManager.All()[1]:IsShown(),
        "and leaving test mode is not the same keystroke as closing it")
end)

test("Building a window sets no text on a fontless FontString", function()
    -- THE BUG THAT BROKE THE LOAD. A FontString has no font until SetFont is
    -- called, and SetText on one answers `FontString:SetText(): Font not set` —
    -- at BuildFrame, which took the whole addon down before a single window
    -- existed. The harness models the client's rule now, so this case is the
    -- whole build path run under it.
    -- red under: SetText on a glyph in BuildFrame, before ApplyHeaderButtons.
    local inst = T.load()
    local cfg = inst.NS.Database.GetWindows()[1]

    local ok, err = pcall(inst.NS.Window.New, cfg)
    assertTrue(ok, "building a window raised: " .. tostring(err))

    -- And the glyphs did get their text, once they had a font to draw it with.
    local window = inst.NS.Window.New(cfg)
    window:ApplyHeaderButtons()
    -- One of the two draws, never neither: an atlas if the client has one, an
    -- ASCII character if it does not.
    assertTrue(window.configButton.tex:IsShown() or window.configButton.glyph:IsShown(),
        "the gear must draw something")
    assertTrue(window.lockButton.tex:IsShown() or window.lockButton.glyph:IsShown(),
        "and the padlock too")
end)

test("Header art falls back to ASCII on a client with none of the atlases", function()
    -- THE TWO FAILURES THIS GUARDS. Texture paths that do not exist draw nothing
    -- and raise nothing; Unicode glyphs the game font lacks draw a replacement
    -- box. Both were shipped, and both were invisible to every test, because the
    -- art was named at authoring time and never asked about.
    -- red under: SetAtlas / SetText with no existence check.
    local inst = T.load()
    inst.mocks.setAtlases({})          -- a client with no matching atlas at all
    local window = inst.NS.Window.New(inst.NS.Database.GetWindows()[1])
    window:ApplyHeaderButtons()

    assertFalse(window.configButton.tex:IsShown(), "no atlas resolved")
    assertTrue(window.configButton.glyph:IsShown(), "so the ASCII fallback draws")
    local text = window.configButton.glyph:GetText()
    assertTrue(text ~= nil and text ~= "", "and it is not empty")
end)

test("Header art prefers an atlas where the client has one", function()
    local inst = T.load()
    inst.mocks.setAtlases({ ["GM-icon-settings"] = true })
    local window = inst.NS.Window.New(inst.NS.Database.GetWindows()[1])
    window:ApplyHeaderButtons()

    assertTrue(window.configButton.tex:IsShown(), "the atlas wins when it exists")
    assertFalse(window.configButton.glyph:IsShown())
end)

test("Changing a setting does not close a window the player asked for", function()
    -- The ladder is consulted on every CONFIG_CHANGED, and a window that is on
    -- screen because the player asked for it is not on screen because the ladder
    -- said so. So the first unrelated settings edit re-ran the ladder, got "no"
    -- from a context rule, and hid it — which reads as "the settings panel closes
    -- my meter", and is a wrong explanation as well as a baffling one.
    -- red under: RefreshVisibility ignoring forcedShow.
    local inst = T.load{ enable = true }
    local cfg = inst.NS.Database.GetWindows()[1]
    cfg.visibility = { dungeon = false, raid = false, arena = false,
                       battleground = false, world = false,
                       hideWhenSolo = false, hideInVehicle = false }

    local window = inst.NS.WindowManager.All()[1]
    window:Show()
    assertTrue(window:IsShown(), "an explicit request shows it")

    inst.NS:SendMessage(inst.NS.Constants.MSG.CONFIG_CHANGED, { windowId = window.id })
    assertTrue(window:IsShown(), "and an unrelated settings edit must not take it away")
end)

test("A zone change is what makes an explicit show stale", function()
    -- Deliberately not permanent: the visibility rules exist to follow you between
    -- a dungeon and a city, and a flag that outlived that would quietly disable
    -- the whole page.
    local inst = T.load{ enable = true }
    local cfg = inst.NS.Database.GetWindows()[1]
    cfg.visibility = { dungeon = false, raid = false, arena = false,
                       battleground = false, world = false,
                       hideWhenSolo = false, hideInVehicle = false }

    local window = inst.NS.WindowManager.All()[1]
    window:Show()
    inst.NS:SendMessage(inst.NS.Constants.MSG.ZONE_CHANGED)
    assertFalse(window:IsShown(), "the context rules get their say again")
end)

test("Closing cancels the request, so it does not reappear", function()
    -- The same bug pointed the other way.
    local inst = T.load{ enable = true }
    local window = inst.NS.WindowManager.All()[1]
    window:Show()
    window:Hide("closed")

    inst.NS:SendMessage(inst.NS.Constants.MSG.CONFIG_CHANGED, { windowId = window.id })
    assertFalse(window:IsShown(), "a closed window stays closed")
end)
