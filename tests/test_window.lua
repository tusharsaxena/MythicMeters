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

local T = _G.MULTIMETERS_TEST

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
    assertEqual(window.frame:GetName(), "MultiMetersWindow" .. tostring(window.id))
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
    local inst, window, cfg = scene()

    -- The controls live on window.controls now, built by
    -- modules/HeaderControls.lua. Same widgets, same clicks, one owner.
    assertTrue(window.controls.lock ~= nil)
    assertTrue(window.controls.settings ~= nil)
    assertTrue(window.controls.lock:GetScript("OnClick") ~= nil)
    assertTrue(window.controls.settings:GetScript("OnClick") ~= nil)

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
    inst.NS.HeaderControls:Apply(window)
    local lockedArt = art(window.controls.lock)

    cfg.frame.locked = false
    inst.NS.HeaderControls:Apply(window)
    assertFalse(art(window.controls.lock) == lockedArt,
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

    window.controls.lock:_run("OnClick")
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

    -- The open world ships ON now, so the fixture has to switch it off itself to
    -- get a context that refuses — which is the step this case is measuring.
    cfg.visibility.world = false
    -- ...refused by context...
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

test("The header says the grid was built the restricted way", function()
    -- REPLACES THE FROZEN-SORT NOTICE. The rows have not stopped reordering —
    -- they are the engine's own live ranking. What the player is owed is why a
    -- CELL can be empty: mid-pull the other columns are matched to those rows by
    -- class and spec, because `sourceGUID` is secret and cannot be joined on.
    local inst, window, cfg = scene{ restricted = true, sortMode = "value" }
    cfg.header.showSessionName = true
    window:ApplyConfig()
    window:Refresh()

    assertTrue(window.sessionText:GetText():find("restricted", 1, true) ~= nil,
        "got: " .. tostring(window.sessionText:GetText()))
end)

test("The header names AMBIGUITY when two rows cannot be told apart", function()
    -- Two players of one class AND one spec: the identity key cannot separate
    -- them, so their secondary cells are left empty rather than filled with a
    -- number that might be the other one's. That is a visible absence and it
    -- needs a reason on the line.
    local inst, window, cfg = scene{
        restricted = true,
        sources = { src(ALPHA, 100, { class = "MAGE" }), src(BETA, 50, { class = "MAGE" }) },
    }
    cfg.header.showSessionName = true
    window:ApplyConfig()
    window:Refresh()

    assertTrue(window.sessionText:GetText():find("told apart", 1, true) ~= nil,
        "got: " .. tostring(window.sessionText:GetText()))
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
    -- Back to the grid — and this scene is RESTRICTED, so the grid's rows are
    -- keyed on their rank rather than on a GUID nothing may key on.
    assertEqual(window.pool.active[1].entry.guid, "rank_1", "and back to the grid")
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

test("Segment: the session line takes NO mouse", function()
    -- It used to be a 220px Button so its text could be right-justified inside
    -- it, which put an invisible click target across the middle of the header: it
    -- glowed red on hover and opened the segment menu from a patch of empty title
    -- bar. The strip's segment control is the visible route to the same menu.
    -- red under: CreateFrame("Button") with an OnClick and a highlight texture.
    local _, window = withSegments()
    assertTrue(window.sessionLine ~= nil)
    assertTrue(window.sessionLine.GetScript == nil
        or window.sessionLine:GetScript("OnClick") == nil,
        "the session line is clickable again")
    assertTrue(window.sessionLine.__highlightTexture == nil,
        "the session line still carries a hover highlight")
    -- The text still rides on it: a line positioned separately from the frame it
    -- is justified inside drifts the first time either moves.
    assertEqual(window.sessionText.__allPoints, window.sessionLine)
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
    --
    -- Covers the arrowTex's texture AND atlas along with the ASCII glyph and its
    -- coord, because which of those three rungs answers depends on what is
    -- registered in the environment the test runs in — the top mark rung wins
    -- here, and it differs by TEXTURE rather than by flipping a coord.
    local function arrowState(button)
        return tostring(button.arrow:GetText()) .. "/" ..
            tostring(button.arrowTex.__texture) .. "/" ..
            tostring(button.arrowTex.__atlas) .. "/" ..
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

test("The sort arrow prefers the collection's own art over the Blizzard atlas", function()
    -- The ladder's top rung. Red under: a build that still reaches straight for
    -- `auctionhouse-ui-sortarrow` while `sort-down.tga` sits unused in the payload.
    local inst, window, cfg = scene{ sortMode = "value" }
    cfg.data.sortColumn = "DamageDone"
    window:ApplyColumnHeaders()

    local marked = window.columnHeaders[2]
    assertEqual(marked.arrowTex.__texture, inst.NS.Icon("sort-down"),
        "the descending arrow is the shipped mark, not an atlas")
    assertTrue(marked.arrowTex:IsShown(), "and it is the rung actually drawn")
end)

test("The sort arrow's two directions are two assets, never one flipped", function()
    -- The atlas rung flips one texture with SetTexCoord because it has only one.
    -- The mark rung has both, so a flip here would draw an upside-down glyph that
    -- happens to look right and breaks the moment the art is redrawn.
    local inst, window, cfg = scene{ sortMode = "value" }
    cfg.data.sortColumn = "DamageDone"

    cfg.data.sortAscending = false
    window:ApplyColumnHeaders()
    local down = window.columnHeaders[2].arrowTex.__texture

    cfg.data.sortAscending = true
    window:ApplyColumnHeaders()
    local up = window.columnHeaders[2].arrowTex.__texture

    assertEqual(down, inst.NS.Icon("sort-down"))
    assertEqual(up, inst.NS.Icon("sort-up"))
    assertFalse(down == up, "ascending and descending are distinct assets")
end)

test("The sort arrow falls to the Blizzard atlas with no LibKa0s art", function()
    -- The rung below. Red under: a top rung that concatenates a nil path, or one
    -- that shows an empty texture rather than standing aside for the atlas.
    local inst, window, cfg = scene{ sortMode = "value" }
    cfg.data.sortColumn = "DamageDone"
    local realIcon = inst.NS.Icon
    inst.NS.Icon = function() return nil end

    window:ApplyColumnHeaders()
    local marked = window.columnHeaders[2]
    assertTrue(marked.arrowTex:IsShown() or marked.arrow:IsShown(),
        "the column still says which way it is sorted")
    -- The atlas rung legitimately leaves __texture nil (SetAtlas clears it, per
    -- the mock's "a texture is either a file or an atlas, never both") — so the
    -- failure this guards is arrowTex shown with NEITHER a texture NOR an atlas,
    -- not the atlas rung's ordinary shape.
    assertFalse(marked.arrowTex:IsShown() and marked.arrowTex.__texture == nil
        and marked.arrowTex.__atlas == nil,
        "and never shows a texture it failed to resolve")

    inst.NS.Icon = realIcon
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

test("A STAT header is honoured in combat: the column it ranks by is a choice", function()
    -- The refusal used to cover every header, and it was too wide. Picking a
    -- different stat mid-pull compares NOTHING: modules/Aggregator.lua builds the
    -- whole mid-pull row list out of `sortColumn`'s own combatSources, so
    -- changing which column that is re-ranks the grid by the engine's own
    -- ordering for the new stat. Refusing it was the whole of "sorting does
    -- nothing in combat" (issue #14).
    -- red under: reinstating the blanket IsRestricted guard in SortByColumn.
    local inst, window, cfg = scene{ sortMode = "value", restricted = true }
    cfg.data.sortColumn = "DamageDone"

    local said = {}
    inst.NS.Print = function(msg) said[#said + 1] = msg end

    assertTrue(window:SortByColumn("Interrupts"))
    assertEqual(cfg.data.sortColumn, "Interrupts", "the grid re-ranks by the new column")
    assertEqual(#said, 0, "nothing was refused, so there is nothing to explain")
end)

test("A stat header REVERSES in combat too, because reversing compares nothing", function()
    -- The direction reaches modules/Aggregator.lua, which applies it by turning
    -- the engine's order back to front — a permutation, legal on secrets.
    local _, window, cfg = scene{ sortMode = "value", restricted = true }
    cfg.data.sortColumn    = "DamageDone"
    cfg.data.sortAscending = false

    assertTrue(window:SortByColumn("DamageDone"))
    assertEqual(cfg.data.sortAscending, true, "the second click reverses, pull or no pull")
end)

test("The Player header sorts by PLAYER, ascending first", function()
    -- It used to toggle between `roster` and `value` — a reasonable thing for
    -- some header to do, and not what a header labelled "Player" says. A-Z is
    -- what a player means by "sort by name", so the first click ascends and the
    -- second reverses, exactly like a stat column.
    -- red under: toggling sortMode between roster and value.
    local _, window, cfg = scene{ sortMode = "value" }

    assertTrue(window:SortByColumn("name"))
    assertEqual(cfg.data.sortMode, "name")
    assertEqual(cfg.data.sortAscending, true, "A-Z first")

    assertTrue(window:SortByColumn("name"))
    assertEqual(cfg.data.sortMode, "name", "still by name")
    assertEqual(cfg.data.sortAscending, false, "and the second click reverses it")
end)

test("The Player header is the ONE that still refuses while restricted", function()
    -- Ordering by name compares a ConditionalSecret, which raises mid-pull, and
    -- unlike a stat column there is no engine ranking to fall back on: `name`
    -- mode mid-pull would silently draw the damage order under an arrow pointing
    -- at the Player column. Refusing with a message beats that.
    local inst, window, cfg = scene{ sortMode = "value", restricted = true }
    local said = {}
    inst.NS.Print = function(msg) said[#said + 1] = msg end

    assertFalse(window:SortByColumn("name"))
    assertEqual(cfg.data.sortMode, "value", "the click changed nothing")
    assertEqual(#said, 1, "the player is owed the reason")
end)

test("Mid-pull the arrow sits on the column the rows are ACTUALLY ordered by", function()
    -- `name` mode survives into a pull when the restriction starts after the
    -- click. The order then comes from the sort COLUMN, and leaving the arrow on
    -- the Player header makes the grid state a lie rather than a limitation
    -- (issue #14).
    -- red under: `sortKey = (data.sortMode == "name") and "name" or data.sortColumn`
    -- with no identity-mode branch.
    local inst, window, cfg = scene{ sortMode = "value" }
    window:SortByColumn("name")
    cfg.data.sortColumn = "DamageDone"

    inst.mocks.setRestricted(true)
    window:Refresh()
    window:ApplyColumnHeaders()

    local byKey = {}
    for _, button in ipairs(window.columnHeaders or {}) do byKey[button.mmKey] = button end
    local function marked(button)
        return button ~= nil and (button.arrow:IsShown() or button.arrowTex:IsShown())
    end

    assertFalse(marked(byKey["name"]),
        "nothing is ordered by name mid-pull, so the Player header must not claim it is")
    assertTrue(marked(byKey["DamageDone"]),
        "the engine ranked these rows by Damage, and the header has to say so")
end)

test("The sort arrow moves to the Player header in name mode", function()
    -- The name column was the one header that could be sorted by and never said
    -- so, because the arrow was placed from `sortColumn` alone.
    local _, window, cfg = scene{ sortMode = "value" }
    window:SortByColumn("name")
    window:ApplyColumnHeaders()

    local nameButton
    for _, button in ipairs(window.columnHeaders or {}) do
        if button.mmKey == "name" then nameButton = button end
    end
    assertTrue(nameButton ~= nil, "the Player header must exist as a button")
    assertTrue(nameButton.arrow:IsShown() or nameButton.arrowTex:IsShown(),
        "the header the order came from has to carry the arrow")
    assertEqual(cfg.data.sortMode, "name")
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

test("A player-state edge re-runs the show ladder on the window itself", function()
    -- THE BUG THE FIRST CUT OF THE PLAYER-STATE RULES SHIPPED WITH. The rules
    -- lived in modules/Visibility.lua and were correct; the window never asked
    -- them again. modules/Visibility.lua is a PREDICATE and publishes nothing by
    -- design, and WindowProto:RefreshVisibility only runs off a bus message — so
    -- a rule with no message the WINDOW listens to takes effect on the next zone
    -- change, group change or settings write, and never on its own edge. Ticking
    -- "hide when skyriding" appeared to work only because the tick itself fires
    -- CONFIG_CHANGED; mounting up afterwards did nothing.
    -- red under: dropping PLAYER_STATE_CHANGED from WindowProto:RegisterBus.
    local inst = T.load()
    local NS, mocks = inst.NS, inst.mocks
    local cfg = NS.Database.GetWindows()[1]
    cfg.frame.locked = true
    cfg.visibility = { world = true, hideWhenSkyriding = true }

    local window = NS.Window.New(cfg)
    assertTrue(window:IsShown(), "the window starts visible in the open world")

    -- Nothing else moves: no zone change, no group change, no settings write.
    -- The player simply got on a skyriding mount.
    mocks.setCanGlide(true)
    NS:SendMessage(NS.Constants.MSG.PLAYER_STATE_CHANGED)
    assertFalse(window:IsShown(), "the window did not hear its own rule's edge")

    mocks.setCanGlide(false)
    NS:SendMessage(NS.Constants.MSG.PLAYER_STATE_CHANGED)
    assertTrue(window:IsShown(), "and it must come back on the other edge")
end)

test("A combat edge re-runs the show ladder on the window itself", function()
    -- Same defect, other message. A hidden window's OnUpdate does not fire, so
    -- without this subscription a window hidden in combat could never come back
    -- when the pull ended.
    -- red under: dropping COMBAT_CHANGED from WindowProto:RegisterBus.
    local inst = T.load()
    local NS, mocks = inst.NS, inst.mocks
    local cfg = NS.Database.GetWindows()[1]
    cfg.frame.locked = true
    cfg.visibility = { world = true, hideInCombat = true }

    local window = NS.Window.New(cfg)
    assertTrue(window:IsShown())

    mocks.setInCombat(true)
    NS:SendMessage(NS.Constants.MSG.COMBAT_CHANGED)
    assertFalse(window:IsShown())

    mocks.setInCombat(false)
    NS:SendMessage(NS.Constants.MSG.COMBAT_CHANGED)
    assertTrue(window:IsShown(), "a hidden window's OnUpdate never fires, so only the message can lift it")
end)

test("The show ladder is re-run ONLY from a message, never from the refresh tick", function()
    -- The property the two cases above rest on, stated once so it cannot rot
    -- unnoticed: onUpdate refreshes DATA. It does not re-ask NS.ShouldShow, so
    -- there is no per-tick fallback for a rule whose edge nothing announces —
    -- every visibility input needs a message the window subscribes to.
    local inst = T.load()
    local NS, mocks = inst.NS, inst.mocks
    local cfg = NS.Database.GetWindows()[1]
    cfg.frame.locked = true
    cfg.visibility = { world = true, hideWhenMounted = true }

    local window = NS.Window.New(cfg)
    assertTrue(window:IsShown())

    mocks.setMounted(true)
    for _ = 1, 20 do
        window:MarkDirty()
        window.frame:_run("OnUpdate", 0.5)
    end
    assertTrue(window:IsShown(),
        "if this ever goes red the tick has started re-running the ladder — " ..
        "rewrite the comments in modules/Window.lua and modules/Visibility.lua that say it does not")

    NS:SendMessage(NS.Constants.MSG.PLAYER_STATE_CHANGED)
    assertFalse(window:IsShown())
end)

test("Entering a vehicle hides the window on its own edge", function()
    -- hideInVehicle shipped in the first release and had NEVER fired on its own:
    -- no vehicle event reached core/MultiMeters.lua's fan-out, and the module
    -- header's claim that the answer would be right "at worst one refresh
    -- interval later" was wrong, because the tick does not re-ask the ladder.
    -- The rule only ever took effect if a zone change happened to follow.
    -- red under: dropping UNIT_ENTERED_VEHICLE from core/MultiMeters.lua.
    local inst = T.load{ enable = true }
    local NS, mocks = inst.NS, inst.mocks
    local cfg = NS.Database.GetWindows()[1]
    cfg.frame.locked = true
    cfg.visibility = { world = true, hideInVehicle = true }

    -- The registration is asserted as well as the behaviour: calling the handler
    -- by hand proves the fan-out works and proves nothing about whether the game
    -- can ever reach it, which is exactly the gap this rule fell into.
    assertEqual(NS.__events["UNIT_ENTERED_VEHICLE"], "OnPlayerStateChanged")
    assertEqual(NS.__events["UNIT_EXITED_VEHICLE"], "OnPlayerStateChanged")

    local window = NS.Window.New(cfg)
    assertTrue(window:IsShown())

    mocks.setInVehicle(true)
    NS:OnPlayerStateChanged("UNIT_ENTERED_VEHICLE", "player")
    assertFalse(window:IsShown())

    mocks.setInVehicle(false)
    NS:OnPlayerStateChanged("UNIT_EXITED_VEHICLE", "player")
    assertTrue(window:IsShown())
end)

test("A vehicle event about somebody else is not republished", function()
    -- UNIT_ENTERED_VEHICLE fires for every unit, so in a raid it is one of the
    -- busier events the addon could listen to. The unit filter is the only
    -- decision in this handler and it is a FILTER, not a rule: nothing about
    -- another player's vehicle can change where this player's window belongs.
    -- red under: dropping the unit check from NS:OnPlayerStateChanged.
    local inst = T.load{ enable = true }
    local NS = inst.NS
    local seen = 0
    local bus = NS.NewBusTarget()
    bus:RegisterMessage(NS.Constants.MSG.PLAYER_STATE_CHANGED, function() seen = seen + 1 end)

    NS:OnPlayerStateChanged("UNIT_ENTERED_VEHICLE", "raid7")
    assertEqual(seen, 0, "a raider's vehicle woke every window in the raid")

    NS:OnPlayerStateChanged("UNIT_ENTERED_VEHICLE", "player")
    assertEqual(seen, 1)

    -- An event with no unit argument at all still passes: nil is not somebody
    -- else, it is "this event is not about a unit".
    NS:OnPlayerStateChanged("PLAYER_MOUNT_DISPLAY_CHANGED")
    assertEqual(seen, 2)
end)

test("A state that lags its own event is caught by the settle pass", function()
    -- THE SKYRIDING DISMOUNT. A ground mount works on the edge alone, because
    -- IsMounted() has already flipped by the time PLAYER_MOUNT_DISPLAY_CHANGED
    -- arrives. GetGlidingInfo's canGlide has not: at the dismount edge the client
    -- still reports the player as glide-capable, the ladder correctly re-hides,
    -- and then NOTHING asks again — a hidden window has no OnUpdate running, so
    -- it stayed hidden until the next zone change or settings write.
    -- red under: dropping the deferred pass from NS:OnPlayerStateChanged.
    local inst = T.load{ enable = true }
    local NS, mocks = inst.NS, inst.mocks
    local cfg = NS.Database.GetWindows()[1]
    cfg.frame.locked = true
    cfg.visibility = { world = true, hideWhenSkyriding = true }

    local window = NS.Window.New(cfg)
    mocks.setCanGlide(true)
    NS:OnPlayerStateChanged("PLAYER_MOUNT_DISPLAY_CHANGED")
    assertFalse(window:IsShown(), "mounting up hides it")

    -- The dismount edge, read while the client still says canGlide. This is the
    -- read that used to be the last word.
    NS:OnPlayerStateChanged("PLAYER_MOUNT_DISPLAY_CHANGED")
    assertFalse(window:IsShown())

    -- The client settles a moment later, and the deferred pass asks again.
    mocks.setCanGlide(false)
    mocks.__fireTimers()
    assertTrue(window:IsShown(), "the window never came back after the state settled")
end)

test("The settle pass is scheduled once, however many edges land together", function()
    -- Mounting fires several of these at once — the mount display, the glide
    -- capability, sometimes a shapeshift. One deferred pass answers all of them,
    -- and scheduling one per event would put a burst of timers on the frame that
    -- fires them for no additional answer.
    -- red under: dropping the pending guard in NS:OnPlayerStateChanged.
    local inst = T.load{ enable = true }
    local NS, mocks = inst.NS, inst.mocks

    local before = #mocks.__timers
    NS:OnPlayerStateChanged("PLAYER_MOUNT_DISPLAY_CHANGED")
    NS:OnPlayerStateChanged("PLAYER_CAN_GLIDE_CHANGED")
    NS:OnPlayerStateChanged("UPDATE_SHAPESHIFT_FORM")
    assertEqual(#mocks.__timers - before, 1, "one settle pass, not one per event")

    -- And the guard reopens once it has run, or the second mount of the session
    -- would have no settle pass at all.
    mocks.__fireTimers()
    NS:OnPlayerStateChanged("PLAYER_MOUNT_DISPLAY_CHANGED")
    assertEqual(#mocks.__timers, 1, "the guard never reopened")
end)

test("A glide event's boolean payload is not mistaken for a unit token", function()
    -- THE BUG THAT MADE SKYRIDING LOOK SPECIAL. Both glide events carry a
    -- BOOLEAN as arg1 — oUF_Fader spells it out: "unit is true/false with the
    -- event being PLAYER_IS_GLIDING_CHANGED", and ElvUI reads
    -- PLAYER_CAN_GLIDE_CHANGED's arg as canGlide. A filter that tested arg1
    -- against "player" for EVERY event in the block therefore dropped every
    -- skyriding edge, while ground mounts kept working because
    -- PLAYER_MOUNT_DISPLAY_CHANGED carries no argument at all.
    -- red under: filtering on arg1 without keying on the event name.
    local inst = T.load{ enable = true }
    local NS = inst.NS
    local seen = 0
    local bus = NS.NewBusTarget()
    bus:RegisterMessage(NS.Constants.MSG.PLAYER_STATE_CHANGED, function() seen = seen + 1 end)

    NS:OnPlayerStateChanged("PLAYER_CAN_GLIDE_CHANGED", true)
    NS:OnPlayerStateChanged("PLAYER_CAN_GLIDE_CHANGED", false)
    NS:OnPlayerStateChanged("PLAYER_IS_GLIDING_CHANGED", true)
    NS:OnPlayerStateChanged("PLAYER_IS_GLIDING_CHANGED", false)
    assertEqual(seen, 4, "a skyriding edge was swallowed by the unit filter")
end)

test("A filtered-out unit event schedules nothing", function()
    -- The unit filter runs FIRST. A raid full of vehicle events must not each
    -- put a timer on the frame to answer a question about somebody else.
    -- red under: moving the ScheduleTimer above the unit check.
    local inst = T.load{ enable = true }
    local NS, mocks = inst.NS, inst.mocks

    local before = #mocks.__timers
    NS:OnPlayerStateChanged("UNIT_ENTERED_VEHICLE", "raid7")
    assertEqual(#mocks.__timers - before, 0)
end)

test("Building a window sets no text on a fontless FontString", function()
    -- THE BUG THAT BROKE THE LOAD. A FontString has no font until SetFont is
    -- called, and SetText on one answers `FontString:SetText(): Font not set` —
    -- at BuildFrame, which took the whole addon down before a single window
    -- existed. The harness models the client's rule now, so this case is the
    -- whole build path run under it.
    -- red under: SetText on a glyph in Attach, before the first Apply.
    local inst = T.load()
    local cfg = inst.NS.Database.GetWindows()[1]

    local ok, err = pcall(inst.NS.Window.New, cfg)
    assertTrue(ok, "building a window raised: " .. tostring(err))

    -- And the glyphs did get their text, once they had a font to draw it with.
    local window = inst.NS.Window.New(cfg)
    inst.NS.HeaderControls:Apply(window)
    -- One of the two draws, never neither: an atlas if the client has one, an
    -- ASCII character if it does not.
    assertTrue(window.controls.settings.tex:IsShown() or window.controls.settings.glyph:IsShown(),
        "the gear must draw something")
    assertTrue(window.controls.lock.tex:IsShown() or window.controls.lock.glyph:IsShown(),
        "and the padlock too")
end)

test("Header art falls back to ASCII on a client with none of the atlases", function()
    -- THE TWO FAILURES THIS GUARDS. Texture paths that do not exist draw nothing
    -- and raise nothing; Unicode glyphs the game font lacks draw a replacement
    -- box. Both were shipped, and both were invisible to every test, because the
    -- art was named at authoring time and never asked about.
    -- red under: SetAtlas / SetText with no existence check.
    local inst = T.load()
    -- Our own art goes first in the ladder, so it has to be taken away before
    -- the rung under test is reachable at all. tests/test_headercontrols.lua
    -- covers the ladder in full; this case stays because it is the one that
    -- names the two failures the ladder exists for.
    inst.mocks.setTextureLoadable(
        "Interface\\AddOns\\MultiMeters\\libs\\LibKa0s\\media\\icons\\settings", false)
    inst.mocks.setAtlases({})          -- a client with no matching atlas at all
    local window = inst.NS.Window.New(inst.NS.Database.GetWindows()[1])
    inst.NS.HeaderControls:Apply(window)

    assertFalse(window.controls.settings.tex:IsShown(), "no atlas resolved")
    assertTrue(window.controls.settings.glyph:IsShown(), "so the ASCII fallback draws")
    local text = window.controls.settings.glyph:GetText()
    assertTrue(text ~= nil and text ~= "", "and it is not empty")
end)

test("Header art prefers an atlas where the client has one", function()
    local inst = T.load()
    inst.mocks.setAtlases({ ["GM-icon-settings"] = true })
    local window = inst.NS.Window.New(inst.NS.Database.GetWindows()[1])
    inst.NS.HeaderControls:Apply(window)

    assertTrue(window.controls.settings.tex:IsShown(), "the atlas wins when it exists")
    assertFalse(window.controls.settings.glyph:IsShown())
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
    -- A context that refuses, so what is being measured is forcedShow being
    -- cleared rather than the ladder happening to say yes. With the shipped
    -- defaults every context says yes, and a closed window DOES come back on the
    -- next settings write — see the note on Hide in modules/Window.lua.
    window.config.visibility.world = false
    inst.mocks.setInstance(nil)
    window:Show()
    window:Hide("closed")

    inst.NS:SendMessage(inst.NS.Constants.MSG.CONFIG_CHANGED, { windowId = window.id })
    assertFalse(window:IsShown(), "a closed window stays closed")
end)

-- ---------------------------------------------------------------------------
-- Scrolling
-- ---------------------------------------------------------------------------
--
-- NOT a ScrollFrame. The window already draws `layout.maxRows` rows chosen out
-- of a longer list, so scrolling is choosing a different window into that list —
-- one integer applied at the top of the render loop. Which means the cases worth
-- writing are about the INTEGER: is it clamped, does it survive a refresh, and
-- does it reset when the list stops being the same list.

--- A window whose frame fits exactly `visible` rows, rendering `total` entries.
local function scrollScene(visible, total)
    local inst, window, cfg = scene{ configure = function(c)
        c.rows.maxRows = visible
    end }
    local rows = {}
    for i = 1, total do
        rows[i] = { guid = string.format("Player-1-%08X", i), name = "Mock" .. i,
                    classFilename = "MAGE", values = {}, cells = {} }
    end
    return inst, window, cfg, rows
end

--- The names the window actually drew, top to bottom.
local function drawnNames(window)
    local out = {}
    for _, row in ipairs(window.pool.active or {}) do
        out[#out + 1] = row.entry and row.entry.name
    end
    return out
end

test("Scrolling moves the window into the list, it does not shorten it", function()
    -- red under: a render loop that always starts at index 1.
    local _, window, _, rows = scrollScene(3, 10)
    window:Render(rows, false)
    assertEqual(drawnNames(window)[1], "Mock1", "the fixture did not start at the top")
    assertEqual(#drawnNames(window), 3, "the row cap is not what the fixture set")

    window:ScrollBy(2)
    window:Render(rows, false)
    assertEqual(drawnNames(window)[1], "Mock3", "scrolling down did not move the first row")
    assertEqual(#drawnNames(window), 3, "scrolling changed how many rows are drawn")
end)

test("The offset survives a refresh, or scrolling is impossible", function()
    -- The window redraws four times a second. An offset reset per render would
    -- snap the view back to the top before a player let go of the wheel.
    -- red under: zeroing scrollOffset in Render.
    local _, window, _, rows = scrollScene(3, 10)
    window:ScrollBy(4)
    for _ = 1, 5 do window:Render(rows, false) end
    assertEqual(window.scrollOffset, 4, "a redraw threw the scroll position away")
end)

test("The offset cannot run past the end of the list", function()
    -- red under: an unclamped offset, which renders an empty window that
    -- scrolling cannot recover from.
    local _, window, _, rows = scrollScene(3, 10)
    window:ScrollBy(500)
    window:Render(rows, false)

    assertEqual(window.scrollOffset, 7, "the offset was not clamped to the last full page")
    assertEqual(#drawnNames(window), 3, "the last page is not full")
    assertEqual(drawnNames(window)[3], "Mock10", "the last row is not the last entry")
end)

test("A list that shrinks under a stationary offset re-clamps on the next draw", function()
    -- This happens constantly: a player leaves the group, a breakdown has fewer
    -- spells than the grid had rows. An offset left past the end renders nothing.
    -- red under: clamping only inside ScrollBy.
    local _, window, _, rows = scrollScene(3, 10)
    window:ScrollBy(7)
    window:Render(rows, false)
    assertEqual(#drawnNames(window), 3)

    local short = { rows[1], rows[2], rows[3], rows[4] }
    window:Render(short, false)
    assertEqual(window.scrollOffset, 1, "the offset was not re-clamped to the shorter list")
    assertTrue(#drawnNames(window) > 0, "the window rendered empty after the list shrank")
end)

test("Scrolling up stops at the top", function()
    -- red under: a negative offset.
    local _, window, _, rows = scrollScene(3, 10)
    window:ScrollBy(-5)
    window:Render(rows, false)
    assertEqual(window.scrollOffset, 0)
    assertEqual(drawnNames(window)[1], "Mock1")
end)

test("A list that fits entirely cannot be scrolled", function()
    -- red under: MaxScroll returning a negative, which would let the view slide
    -- off the top of a list that was never long enough to scroll.
    local _, window, _, rows = scrollScene(10, 3)
    window:ScrollBy(5)
    window:Render(rows, false)
    assertEqual(window.scrollOffset, 0, "a window with room to spare still scrolled")
    assertEqual(#drawnNames(window), 3, "and it still drew every row it had")
end)

test("The body takes the wheel, or the handler is never called in game", function()
    -- A live OnMouseWheel script on a frame that never called EnableMouseWheel
    -- runs perfectly in a harness and does nothing in the client.
    -- red under: dropping EnableMouseWheel.
    local _, window = scrollScene(3, 10)
    assertTrue(window.body:IsMouseWheelEnabled(), "the body does not accept the wheel")
end)

test("The wheel scrolls up on a positive delta", function()
    -- Getting this backwards is the kind of thing no unit test catches unless it
    -- names the direction: delta > 0 is "wheel up", which means a SMALLER offset.
    -- red under: inverting the sign.
    local _, window, _, rows = scrollScene(3, 10)
    window:ScrollBy(5)
    window:Render(rows, false)
    local before = window.scrollOffset
    assertTrue(before > 0, "the fixture never scrolled at all")

    window.body:_run("OnMouseWheel", 1)
    window:Render(rows, false)
    assertTrue(window.scrollOffset < before, "wheel up moved the view down the list")

    window.body:_run("OnMouseWheel", -1)
    window:Render(rows, false)
    assertEqual(window.scrollOffset, before, "wheel down did not undo it")
end)

test("Entering or leaving a breakdown puts the view back at the top", function()
    -- An offset carried from the grid into a breakdown points into rows that are
    -- not there — and it would then be re-clamped rather than reset, leaving a
    -- player part-way down a list they never scrolled.
    -- red under: dropping ResetScroll from the DRILLDOWN_CHANGED handler.
    local inst, window, cfg, rows = scrollScene(3, 10)
    window:ScrollBy(5)
    window:Render(rows, false)
    assertEqual(window.scrollOffset, 5)

    inst.NS.DrillDown:Enter(cfg,
        { guid = "Player-1-00000001", name = "Mock1", values = {} }, "DamageDone")
    assertEqual(window.scrollOffset, 0, "the grid's scroll position followed us into the breakdown")
end)

test("A drill-down draws its rows from the top of the body, with none hanging out", function()
    -- THE OVERFLOW. `layout.maxRows` is derived from the body height, and every
    -- drill row used to be pushed down by the height of a Back button drawn
    -- inside that body — so a full page of rows put its last row through the
    -- bottom of the frame. The button is gone and the offset with it.
    -- red under: re-adding a fixed drill offset to Row.OffsetFor's result.
    local _, window, _, rows = scrollScene(3, 10)

    window:Render(rows, false, false)
    local gridTop = window.pool.active[1].frame.__points[1].y

    window:Render(rows, false, true, "Alpha - Damage")
    local drillTop = window.pool.active[1].frame.__points[1].y

    assertEqual(drillTop, gridTop,
        "a breakdown's first row starts lower than the grid's, so its last row overflows")
end)

test("Right-clicking empty space below the rows leaves a breakdown", function()
    -- The rows handle their own right-click, but a short breakdown leaves most
    -- of the body bare and "right-click anywhere" has to mean anywhere.
    -- red under: no OnMouseUp on the body.
    local inst, window, cfg = scene()
    inst.NS.DrillDown:Enter(cfg,
        { guid = ALPHA, name = "Alpha", values = {} }, "DamageDone")
    assertTrue(inst.NS.DrillDown.IsActive(cfg), "the fixture never entered a breakdown")

    window.body:_run("OnMouseUp", "RightButton")
    assertFalse(inst.NS.DrillDown.IsActive(cfg), "the body ignored the right click")
end)

test("The body claims the mouse only while a breakdown is open", function()
    -- There is a hard-won comment saying the body taking the mouse "stole every
    -- hover from the cells underneath it". The cells are descendants and should
    -- still win, but that was learned the expensive way — so the grid keeps
    -- exactly the behaviour it has today and only a drilled window changes.
    -- red under: EnableMouse(true) on the body unconditionally.
    local _, window = scene()
    local rows = { { guid = ALPHA, name = "Alpha", values = {}, cells = {} } }

    window:Render(rows, false, false)
    assertFalse(window.body:IsMouseEnabled(), "the grid's body took the mouse")

    window:Render(rows, false, true, "Alpha - Damage")
    assertTrue(window.body:IsMouseEnabled(), "a breakdown's body did not take the mouse")
end)

test("Column headers take their own font, not the cells'", function()
    -- They used to borrow the font PATH and size from `text` and the outline and
    -- colour from `header`, so changing the cell font silently restyled the
    -- headers and nothing could make the strip differ from the numbers beneath.
    -- red under: reading textCfg.font / textCfg.size in ApplyColumnHeaders.
    local _, window = scene{ configure = function(c)
        c.text.size = 9
        c.columnHeader.size = 21
        c.columnHeader.outline = "THICKOUTLINE"
    end }
    window:ApplyColumnHeaders()

    local _, size, flags = window.columnHeaders[1].text:GetFont()
    assertEqual(size, 21, "the header took the cell text size")
    assertEqual(flags, "THICKOUTLINE", "the header took its outline from somewhere else")
end)

test("Column headers have their own colour and background", function()
    -- The strip has never had a backdrop, so the setting is new capability and
    -- defaults transparent — an existing window must look identical.
    -- red under: tinting from header.color, or no headerBg texture at all.
    local _, window = scene{ configure = function(c)
        c.header.color = { r = 0, g = 1, b = 0, a = 1 }
        c.columnHeader.color = { r = 1, g = 0, b = 0, a = 1 }
        c.columnHeader.bgColor = { r = 0, g = 0, b = 1, a = 0.5 }
    end }
    window:ApplyColumnHeaders()

    local r, g = window.columnHeaders[1].text:GetTextColor()
    assertEqual(r, 1, "the header label took the title strip's colour")
    assertEqual(g, 0, "the header label took the title strip's colour")

    local bg = window.headerBg.__colorTexture
    assertTrue(bg ~= nil, "the header strip has no backdrop texture")
    assertEqual(bg[3], 1, "the backdrop did not take the configured colour")
end)

-- ---------------------------------------------------------------------------
-- Minimise (issue #6)
-- ---------------------------------------------------------------------------
--
-- Review found this had ZERO behavioural coverage: ApplyMinimised could be made
-- a no-op and the suite stayed green, on the headline addition of the change.
-- Everything below is a property somebody would notice in game and nothing
-- offline was checking.

test("Minimise hides everything below the title bar", function()
    -- Four things hang there, not one. The body carries the rows, but the
    -- column-header strip, the notice and the grip are parented to the FRAME --
    -- so hiding the body alone leaves three of them drawn over a collapsed
    -- window.
    -- red under: hiding self.body and nothing else.
    local _, window, cfg = scene()
    cfg.frame.minimised = true
    window:ApplyConfig()

    assertEqual(window.body:IsShown(), false, "the rows are still there")
    if window.headerFrame then
        assertEqual(window.headerFrame:IsShown(), false, "the column headers are still there")
    end
    if window.grip then assertEqual(window.grip:IsShown(), false, "the grip is still there") end
end)

test("Minimise actually shrinks the window", function()
    -- Hiding the children left a full-height empty frame sitting there, which is
    -- not what "collapse to the title bar" means to anyone looking at it.
    -- red under: hiding children without changing the frame's height.
    local _, window, cfg = scene()
    window:ApplyConfig()

    -- Expanded, the visible frame takes its height by being pinned to BOTH
    -- corners of the anchor -- it is never explicitly sized, which is why its
    -- recorded height is 0 and cannot be the thing asserted on.
    local function pinnedToBottom(frame)
        for _, p in ipairs(frame.__points or {}) do
            if p.point == "BOTTOMRIGHT" then return true end
        end
        return false
    end
    assertTrue(pinnedToBottom(window.frame), "expanded, the frame spans the anchor")

    cfg.frame.minimised = true
    window:ApplyConfig()
    assertFalse(pinnedToBottom(window.frame),
        "collapsed, the frame must stop spanning the anchor")
    assertTrue((window.frame.__h or 0) > 0, "and take the title bar's height instead")

    cfg.frame.minimised = false
    window:ApplyConfig()
    assertTrue(pinnedToBottom(window.frame), "expanding re-pins it")
end)

test("Minimise leaves the STORED height alone, so expanding restores it", function()
    -- The anchor is deliberately not resized: doing so fires onSizeChanged,
    -- which writes pendingWidth/pendingHeight, and SaveSize persists whatever is
    -- pending on the next resize-stop -- so a collapsed height would leak into
    -- frame.height and the window would never come back to the size chosen.
    -- red under: collapsing by resizing self.anchor.
    local _, window, cfg = scene()
    local stored = cfg.frame.height

    cfg.frame.minimised = true
    window:ApplyConfig()
    assertEqual(cfg.frame.height, stored, "the collapse rewrote the stored height")

    cfg.frame.minimised = false
    window:ApplyConfig()
    assertEqual(cfg.frame.height, stored)
    assertEqual(window.body:IsShown(), true, "expanding did not bring the rows back")
end)

test("A collapsed window does not aggregate or render", function()
    -- THE COST CLAIM, and it needed two clauses rather than one. ShouldPoll
    -- covers the polling half of the tick; onUpdate takes an early branch on
    -- `dirty`, and every meter message sets that flag -- so without the guard in
    -- Refresh the whole aggregate-and-render ran for a hidden body all fight.
    -- red under: removing either clause.
    local inst, window, cfg = scene()
    cfg.frame.minimised = true
    window:ApplyConfig()

    local built = 0
    local realBuild = inst.NS.Aggregator.Build
    inst.NS.Aggregator.Build = function(...) built = built + 1 return realBuild(...) end

    window:MarkDirty()
    window:Refresh()
    assertEqual(window:ShouldPoll(), false, "a collapsed window still polls")
    assertEqual(built, 0, "a collapsed window still aggregated")

    inst.NS.Aggregator.Build = realBuild
end)

test("A collapsed window keeps the notice hidden", function()
    -- Refresh puts the "waiting for combat data" line back whenever there is
    -- nothing to draw, so hiding it once at collapse time was not enough.
    local _, window, cfg = scene()
    cfg.frame.minimised = true
    window:ApplyConfig()
    window:Refresh()
    assertEqual(window.notice:IsShown(), false, "the notice came back over a collapsed window")
end)

test("Unlocking does not resurrect the grip on a collapsed window", function()
    -- ApplyLock and ApplyMinimised are two authors of one property, so whichever
    -- runs last wins unless they ask the same question. `/mm lock off` was the
    -- path that put the grip back.
    -- red under: ApplyLock doing grip:SetShown(not locked).
    local _, window, cfg = scene()
    cfg.frame.minimised = true
    cfg.frame.locked = false
    window:ApplyConfig()
    window:ApplyLock()
    if window.grip then
        assertEqual(window.grip:IsShown(), false, "unlocking put the grip back")
    end
end)

test("A profile written before minimise existed is not collapsed", function()
    -- `~= false` would collapse every stored profile on upgrade, because none of
    -- them has the key at all.
    -- red under: `local down = frameCfg.minimised ~= false`.
    local _, window, cfg = scene()
    cfg.frame.minimised = nil
    window:ApplyConfig()
    assertEqual(window.body:IsShown(), true, "an upgraded profile came back collapsed")
end)

-- ── pool.all reaches PARKED rows (LibKa0s-Pool-1.0 adoption) ────────────────
--
-- The one thing the library's pool cannot express, and therefore the one thing a
-- careless adoption would have dropped. `pool.all` holds every row ever built,
-- free ones included, and ApplyLayout iterates it so a row sitting on the free
-- list is re-laid-out too. Drop that and everything still looks right until the
-- group GROWS and a parked row is handed out at the old width — long after the
-- settings change that caused it, with nothing pointing back.

test("pool: a layout change re-applies to FREE rows, not just active ones", function()
    local _, window = scene()
    window:Refresh()

    -- Park everything, so every row in `all` is on the free list.
    window:HideAll()
    assertEqual(#window.pool.active, 0)
    assertEqual(#window.pool.free, #window.pool.all, "all rows are parked")

    local applied = {}
    for _, row in ipairs(window.pool.all) do
        local real = row.ApplyLayout
        row.ApplyLayout = function(self, layout) applied[self] = true; return real(self, layout) end
    end

    window:ApplyConfig()

    local n = 0
    for _ in pairs(applied) do n = n + 1 end
    assertEqual(n, #window.pool.all,
        "every row got the new layout, including the ones nobody is drawing with")
end)

test("pool: every row built lands in `all`, including the batch surplus", function()
    -- Batch growth moved into the Acquire factory closure, which the library calls once per miss.
    -- A closure that registered only the row it RETURNED would leave four of every five rows out
    -- of `all` — and those four would then never be re-laid-out.
    local inst, window = scene()
    local Const = inst.NS.Constants

    window:Refresh()
    assertEqual(#window.pool.all, Const.POOL_GROW_STEP,
        "the whole batch is tracked, not just the row handed back")
    assertEqual(#window.pool.free + #window.pool.active, #window.pool.all,
        "and every tracked row is accounted for as either parked or out")
end)
