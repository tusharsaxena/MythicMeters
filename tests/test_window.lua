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
    -- ADDON-WIDE since schemaVersion 5: a refresh rate is one answer, not one
    -- per window, so it is read off the profile rather than off the config.
    local inst, window = scene()
    local Const = inst.NS.Constants
    local data = inst.NS.db.profile.data

    data.throttle = 0
    window:RefreshUpvalues()
    assertEqual(window.throttle, Const.THROTTLE_MIN,
        "zero would turn every meter event into a full rebuild")

    data.throttle = 99
    window:RefreshUpvalues()
    assertEqual(window.throttle, Const.THROTTLE_MAX)
end)

-- ---------------------------------------------------------------------------
-- The refresh clock
-- ---------------------------------------------------------------------------

test("The throttle coalesces N events into ONE refresh", function()
    local inst, window = scene()
    inst.NS.db.profile.data.throttle = 0.25
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

-- A ROW WIDGET MUST KEEP ITS RANK ACROSS REFRESHES, and the guarantee is the LIBRARY's now.
--
-- `Acquire` pops the free list from the end, so the direction `ReleaseAll` parks in decides which
-- widget the next render hands to which rank. Parked forward, the mapping reverses and re-reverses,
-- alternating with period 2 for as long as the window keeps drawing; parked backward, rank n comes
-- back to rank n. LibKa0s-Pool-1.0 minor 3 made parking backward a documented contract, so
-- `WindowProto:HideAll` is a bare `ReleaseAll` again — the host-side reversal it used to carry was
-- removed in the same commit as that payload, because against a backward-parking library it
-- double-reverses and puts the fault straight back.
--
-- WHY THIS TEST DID NOT MOVE WITH THE FIX: what it pins is the INVARIANT, not whichever layer
-- currently supplies it. A widget that keeps its rank is handed the same figure every refresh; a
-- widget that swaps rank is handed a different player's, and a meter value is a secret handle that
-- shows a transient while it resolves — so a swap paints every bar full and snaps it back, four
-- times a second, all fight. Nothing else in this repo would go red for it: the counts stay right,
-- no frame leaks, and preview mode never shows it because placeholder figures apply with no resolve
-- step. This case is the only thing between that bug and its next regression, wherever it comes
-- from, so it outlives the host code it was originally written against.
--
-- THREE PASSES, NOT TWO. A period-2 alternation is right way up on every other render, so a single
-- round trip can pass by luck; the third pass is what makes a swap unable to hide.
test("A row widget keeps its RANK across refreshes: the pool hands them back in order", function()
    local _, window = scene()

    window:Refresh()
    local firstPass = {}
    for i, row in ipairs(window.pool.active) do firstPass[i] = row end
    assertTrue(#firstPass > 1, "the fixture must draw enough rows for an order to exist")

    for pass = 2, 3 do
        window:Refresh()
        assertEqual(#window.pool.active, #firstPass, "the same rows are drawn on every pass")
        for i, row in ipairs(window.pool.active) do
            assertTrue(row == firstPass[i], string.format(
                "rank %d drew a DIFFERENT row widget on refresh %d. Acquire pops the free list " ..
                "from the end, so LibKa0s-Pool-1.0 ReleaseAll must park rows in reverse rank " ..
                "order (minor 3) and HideAll must NOT reverse that again -- either fault alone " ..
                "alternates the mapping every render, which hands every bar a different " ..
                "player's value four times a second, and a secret value shows a transient when " ..
                "it changes", i, pass))
        end
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

test("An explicit Show draws on the next tick too, not a throttle later", function()
    -- The `/mm toggle` half of the same fact. Show puts the frame on screen
    -- itself rather than going through RefreshVisibility, so it did not inherit
    -- that file's clock nudge: the chrome appeared instantly and the rows landed
    -- up to a full `data.throttle` later, which reads as the window assembling
    -- itself in two stages.
    -- red under: WindowProto:Show leaving `elapsed` where the hide left it.
    local _, window = scene()
    window:Hide("toggled")
    window.dirty, window.elapsed = false, 0

    window:Show()
    assertTrue(window.dirty, "the request marks it dirty")
    assertEqual(window.elapsed, window.throttle,
        "and hands the clock a full tick, so the first draw is the next frame")
end)

-- ---------------------------------------------------------------------------
-- The header line
-- ---------------------------------------------------------------------------

test("The header folds its parts with `..`, and survives a secret piece", function()
    -- Two of the pieces this line can carry come out of NS.Format having been
    -- built from a secret, and a formatted secret is itself secret. `..` is legal
    -- on one; table.concat is the one string operation that RAISES on one -- it
    -- is literally the probe core/CoreSetup.lua uses to detect a secret at all.
    -- red under: joining the line rather than folding it.
    local _, window = scene{ restricted = true, preview = true }
    window:ApplyConfig()
    window:Refresh()

    local line = window.sessionText:GetText()
    assertEqual(type(line), "string")
    assertTrue(#line > 0, "the line said nothing at all")
end)

test("The header line says only what has nowhere else to be said", function()
    -- The session NAME, the DURATION and the TOTAL were three checkboxes and are
    -- gone: the name repeated the window's own title, the duration belongs to the
    -- segment the picker already names, and the total is a figure the column
    -- under it holds per player. What is left is the drill-down title and the
    -- restricted notice -- state, not preference.
    -- red under: putting any of the three back into UpdateHeaderText.
    local _, window = scene()
    window:ApplyConfig()
    window:Refresh()

    local line = window.sessionText:GetText() or ""
    assertEqual(line, "", "an ordinary grid must leave the header line blank")
end)

test("The header says the grid was built the restricted way", function()
    -- REPLACES THE FROZEN-SORT NOTICE. The rows have not stopped reordering —
    -- they are the engine's own live ranking. What the player is owed is why a
    -- CELL can be empty: mid-pull the other columns are matched to those rows by
    -- class and spec, because `sourceGUID` is secret and cannot be joined on.
    local inst, window = scene{ restricted = true, sortMode = "value" }
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

test("The master switch closes a window the player asked for", function()
    -- forcedShow used to override the WHOLE ladder, which made "Enable Multi
    -- Meters" do nothing: any window that had ever been shown carried the flag, so
    -- unticking the master switch re-ran the ladder, got "disabled", and was
    -- overruled by a flag that means "I asked for this window in this zone" -- a
    -- far narrower statement than the one the master switch makes.
    -- red under: `if not show and self.forcedShow then` with no UNFORCEABLE check.
    local inst = T.load{ enable = true }
    local NS = inst.NS

    local window = NS.WindowManager.All()[1]
    window:Show()
    assertTrue(window:IsShown(), "an explicit request shows it")

    assertTrue(NS.SetByPath("enabled", false))
    assertFalse(window:IsShown(), "the master switch is not a context rule")
end)

test("A perf suspend closes a window the player asked for", function()
    -- Step 0 of the ladder exists to say a suspended capture is INERT: nothing --
    -- a combat transition, a zone-in, a settings change -- may re-show a window
    -- behind suspend's back. forcedShow was doing exactly that.
    -- red under: forcedShow overriding a "suspended" answer.
    local inst = T.load{ enable = true }
    local NS = inst.NS

    local window = NS.WindowManager.All()[1]
    window:Show()
    assertTrue(window:IsShown())

    NS.Perf.suspended = true
    window:RefreshVisibility()
    assertFalse(window:IsShown(), "a suspended capture must be inert")
end)

test("A CONTEXT rule still cannot close a window the player asked for", function()
    -- The other half of the same fix, and the reason forcedShow exists at all: it
    -- must still outrank the context rules, or narrowing the override would have
    -- brought back the bug it was written for.
    local inst = T.load{ enable = true }
    local NS = inst.NS
    local cfg = NS.Database.GetWindows()[1]
    cfg.visibility = { dungeon = false, raid = false, arena = false,
                       battleground = false, world = false,
                       hideWhenSolo = false, hideInVehicle = false }

    local window = NS.WindowManager.All()[1]
    window:Show()
    window:RefreshVisibility()
    assertTrue(window:IsShown(), "every context says no, and the request still wins")
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

test("Per-statistic mode leaves the Player header white, not the sort column's colour", function()
    -- The Player column labels the NAMES, not a statistic, so there is no stat
    -- colour for it to take. It was taking one anyway: its fallback resolved
    -- through windowStat() -- the sort column -- so "Player" came out red on a
    -- damage-sorted window and changed colour whenever the sort moved.
    -- red under: `button.text:SetTextColor(hr, hg, hb, ha)` for the name column.
    local inst, window, cfg = scene{ configure = function(c)
        c.columnHeader.colorMode = "stat"
    end }
    cfg.data.sortColumn = "DamageDone"
    window:ApplyColumnHeaders()

    local byKey = {}
    for _, button in ipairs(window.columnHeaders or {}) do byKey[button.mmKey] = button end

    local nr, ng, nb = byKey["name"].text:GetTextColor()
    assertEqual(nr, 1, "the Player header must be white in per-statistic mode")
    assertEqual(ng, 1, "the Player header must be white in per-statistic mode")
    assertEqual(nb, 1, "the Player header must be white in per-statistic mode")

    -- The stat columns still take their own colours, which is the whole feature.
    local dr, dg, db = byKey["DamageDone"].text:GetTextColor()
    local want = inst.NS.Constants.STAT_COLORS["DamageDone"]
    assertEqual(dr, want[1], "the Damage header lost its own statistic colour")
    assertEqual(dg, want[2], "the Damage header lost its own statistic colour")
    assertEqual(db, want[3], "the Damage header lost its own statistic colour")
end)

test("The Player header's sort arrow is white too, in per-statistic mode", function()
    -- Sorting by name puts the arrow on the Player header, where it was drawn
    -- from the same stat-resolved fallback the label was -- so the arrow stayed
    -- red over a label that is no longer red.
    -- red under: the arrow branches reading `hr, hg, hb` instead of the
    -- per-header colour.
    local _, window = scene{ configure = function(c)
        c.columnHeader.colorMode = "stat"
    end }
    window:SortByColumn("name")
    window:ApplyColumnHeaders()

    local nameButton
    for _, button in ipairs(window.columnHeaders or {}) do
        if button.mmKey == "name" then nameButton = button end
    end
    assertTrue(nameButton ~= nil, "the Player header must exist as a button")

    local r, g, b
    if nameButton.arrowTex:IsShown() then
        local c = nameButton.arrowTex.__vertexColor
        assertTrue(c ~= nil, "the shown arrow texture was never tinted")
        r, g, b = c[1], c[2], c[3]
    else
        r, g, b = nameButton.arrow:GetTextColor()
    end
    assertEqual(r, 1, "the Player header's sort arrow must match its white label")
    assertEqual(g, 1, "the Player header's sort arrow must match its white label")
    assertEqual(b, 1, "the Player header's sort arrow must match its white label")
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

-- ---------------------------------------------------------------------------
-- The header's four text controls
-- ---------------------------------------------------------------------------

test("Header shadow reaches every line of the strip", function()
    -- The cell text has had a shadow all along and the other three surfaces had
    -- not, so a player styling a window had to discover which of the four had
    -- grown which control. All four carry the same four now.
    -- red under: setting the header font without its shadow.
    local _, window, cfg = scene()
    cfg.header.shadow = true
    window:ApplyConfig()

    assertEqual(window.frame.title.__shadow[1], 1, "the title has no shadow")
    assertEqual(window.frame.title.__shadow[2], -1)
    assertEqual(window.sessionText.__shadow[1], 1, "the session line has no shadow")

    cfg.header.shadow = false
    window:ApplyConfig()
    assertEqual(window.frame.title.__shadow[1], 0, "the shadow did not come off")
end)

test("Column header shadow is its OWN setting, not the header's", function()
    -- The two strips are separate groups precisely so they can differ; a shared
    -- shadow would undo half of that.
    -- red under: reading header.shadow for the column labels.
    local _, window, cfg = scene()
    cfg.header.shadow       = false
    cfg.columnHeader.shadow = true
    window:ApplyConfig()

    local button = window.columnHeaders and window.columnHeaders[1]
    assertTrue(button ~= nil, "no column header was built")
    assertEqual(button.text.__shadow[1], 1)
    assertEqual(window.frame.title.__shadow[1], 0,
        "the title took the column strip's shadow")
end)

test("Header class color is the LOCAL player's, since the header has no row", function()
    -- The header is about the WINDOW. A cell answers the same setting with the
    -- class of the row it is drawing (modules/Row.lua); this one has no row to
    -- ask about, so yours is the only class it can sensibly mean.
    -- red under: colouring the header from a row, or ignoring the setting.
    local inst, window, cfg = scene()
    -- The scene's `player` unit is Alpha, a paladin. The mock ships every class
    -- the same colour, so one is given its own -- otherwise "took SOME class
    -- colour" would pass for "took the LOCAL player's".
    inst.mocks.RAID_CLASS_COLORS.PALADIN = { r = 0.41, g = 0.8, b = 0.94 }
    cfg.header.color      = { r = 1, g = 0.82, b = 0, a = 1 }
    cfg.header.colorMode = "class"
    window:ApplyConfig()

    local c = window.sessionText.__textColor
    assertEqual(c[1], 0.41)
    assertEqual(c[3], 0.94)
    assertEqual(c[4], 1, "the configured alpha must survive the class colour")

    cfg.header.colorMode = "custom"
    window:ApplyConfig()
    assertEqual(window.sessionText.__textColor[1], 1, "the gold did not come back")
    assertEqual(window.sessionText.__textColor[2], 0.82)
end)

test("Per-statistic colour on the header is the SORT COLUMN's", function()
    -- A title bar is not "about" one column the way a cell is, so `stat` has to
    -- mean something for a surface that is not a statistic: the statistic the
    -- grid is currently ranked by is the only one it describes.
    -- red under: resolving it to the first column, or to nothing.
    local inst, window, cfg = scene()
    local Const = inst.NS.Constants
    cfg.header.colorMode  = "stat"
    cfg.data.sortColumn   = "HealingDone"
    window:ApplyConfig()

    local want = Const.STAT_COLORS.HealingDone
    assertTrue(want ~= nil, "the palette has no HealingDone entry to compare against")
    assertEqual(window.frame.title.__textColor[1], want[1])
    assertEqual(window.sessionText.__textColor[1], want[1],
        "the title and the session line are one header and must not differ")

    -- And it follows the sort, because that is what it names.
    cfg.data.sortColumn = "DamageDone"
    window:ApplyConfig()
    assertEqual(window.frame.title.__textColor[1], Const.STAT_COLORS.DamageDone[1])
end)

test("Per-statistic colour on the COLUMN strip is per column", function()
    -- The one surface where "per statistic" is literally per column: each label
    -- takes the colour of the column it labels, rather than one colour for the
    -- strip.
    -- red under: resolving the strip once and painting every label with it.
    local inst, window, cfg = scene()
    local Const = inst.NS.Constants
    cfg.columnHeader.colorMode = "stat"
    window:ApplyConfig()

    local seen = {}
    for _, button in ipairs(window.columnHeaders or {}) do
        if button.mmKey and button.mmKey ~= "name" then
            local want = Const.STAT_COLORS[button.mmKey]
            if want then
                assertEqual(button.text.__textColor[1], want[1],
                    button.mmKey .. "'s label is not in its own column's colour")
                seen[#seen + 1] = button.mmKey
            end
        end
    end
    assertTrue(#seen >= 2, "the scene needs two coloured columns to prove per-column")
end)

test("Per-statistic BACKGROUND on the column strip paints each label, not the strip", function()
    -- A class is not a property of a column, so every other mode stays on the one
    -- strip-wide texture; `stat` is the one that has to become several.
    local inst, window, cfg = scene()
    local Const = inst.NS.Constants
    cfg.columnHeader.bgColorMode = "stat"
    cfg.columnHeader.bgColor     = { r = 0, g = 0, b = 0, a = 0.8 }
    window:ApplyConfig()

    assertFalse(window.headerBg:IsShown(), "the strip-wide texture was left drawn under the columns")

    local painted = 0
    for _, button in ipairs(window.columnHeaders or {}) do
        if button.mmKey and button.mmKey ~= "name" and Const.STAT_COLORS[button.mmKey] then
            assertTrue(button.bg:IsShown(), button.mmKey .. " has no background of its own")
            assertEqual(button.bg.__colorTexture[1], Const.STAT_COLORS[button.mmKey][1])
            assertEqual(button.bg.__colorTexture[4], 0.8, "the configured opacity was dropped")
            painted = painted + 1
        end
    end
    assertTrue(painted >= 2)

    -- Switching back takes them down and brings the strip back, or a player who
    -- changes their mind keeps both.
    cfg.columnHeader.bgColorMode = "custom"
    window:ApplyConfig()
    assertTrue(window.headerBg:IsShown())
    for _, button in ipairs(window.columnHeaders or {}) do
        assertFalse(button.bg:IsShown(), "a per-column background outlived the mode that asked for it")
    end
end)

test("The title bar's background is a plain colour, with no mode of its own", function()
    -- It is ONE strip over the whole window, so a per-statistic mode could only
    -- paint it the sort column's colour -- a fact on screen twice already. The
    -- column strip below it keeps its mode, because there "per statistic" tints
    -- each label with its own column's colour and means something.
    -- red under: giving the title bar a bgColorMode back.
    local inst, window, cfg = scene()
    cfg.header.bgColor = { r = 0.2, g = 0.4, b = 0.6, a = 0.4 }
    window:ApplyConfig()

    local c = window.headerBG.__colorTexture
    assertEqual(c[1], 0.2)
    assertEqual(c[4], 0.4, "the configured opacity was dropped")
    assertNil(inst.NS.FindSchemaRow("window.header.bgColorMode"),
        "the title bar grew a background mode back")
end)

test("The Player column is the shipped width for the shipped config, exactly", function()
    -- The formula is CALIBRATED against NAME_COLUMN_WIDTH: 118 is a measured
    -- value that has been right in the client for as long as this addon has had a
    -- name column, so a window nobody has touched must still get it. Otherwise
    -- "the column follows Max name length" would be a new look for every window
    -- that never asked for one.
    -- red under: moving NAME_CHAR_RATIO or NAME_COLUMN_PAD without re-anchoring.
    local inst, window = scene()
    assertEqual(window.config.text.maxNameLength, 20, "the calibration point moved")
    assertEqual(window.config.icons.showIcon, true)
    assertEqual(window.layout.nameColumn.width, inst.NS.Constants.NAME_COLUMN_WIDTH)
end)

test("The Player column follows Max name length, and the icon's share with it", function()
    -- The cap names a number of CHARACTERS, so the column it lives in is the one
    -- thing that should follow it. It did not: the cap shortened the text and the
    -- column stayed at 118px, so lowering it left a wide column with a short name
    -- rattling around and raising it clipped the name the setting had permitted.
    -- red under: a fixed nameColumn.width.
    local _, window, cfg = scene()
    local wide = window.layout.nameColumn.width

    cfg.text.maxNameLength = 6
    window:ApplyConfig()
    local narrow = window.layout.nameColumn.width
    assertTrue(narrow < wide, "a shorter cap must give the width back")

    cfg.text.maxNameLength = 40
    window:ApplyConfig()
    assertTrue(window.layout.nameColumn.width > wide, "a longer cap must make room")

    -- Turning the icon off gives its share to the name rather than leaving a hole
    -- where a picture was.
    cfg.text.maxNameLength = 20
    window:ApplyConfig()
    local withIcon = window.layout.nameColumn.width
    cfg.icons.showIcon = false
    window:ApplyConfig()
    local withoutIcon = window.layout.nameColumn.width
    assertEqual(withIcon - withoutIcon, (cfg.icons.size or 14) + 4,
        "the icon's allowance is its size plus the gap Row.lua reserves")
end)

test("A bigger font widens the Player column, because the cap is in characters", function()
    local _, window, cfg = scene()
    cfg.text.maxNameLength = 20
    window:ApplyConfig()
    local small = window.layout.nameColumn.width

    cfg.text.size = 22
    window:ApplyConfig()
    assertTrue(window.layout.nameColumn.width > small,
        "twenty characters at 22pt need more room than twenty at 11pt")
end)

test("No name cap keeps the shipped width, and nothing goes below the floor", function()
    -- 0 is the documented "no cap", and a window with no cap has no length to
    -- size itself from.
    local inst, window, cfg = scene()
    cfg.text.maxNameLength = 0
    window:ApplyConfig()
    assertEqual(window.layout.nameColumn.width, inst.NS.Constants.NAME_COLUMN_WIDTH)

    -- And a one-character cap with no icon must still hold the word "Player".
    cfg.text.maxNameLength = 1
    cfg.icons.showIcon = false
    cfg.text.size = 6
    window:ApplyConfig()
    assertEqual(window.layout.nameColumn.width, inst.NS.Constants.NAME_COLUMN_MIN)
end)

test("The header background covers the TITLE BAR only, not the column strip", function()
    -- It used to cover both header rows, on the reading that "the header" is the
    -- whole block a player points at. That was wrong twice: the column strip has
    -- its OWN background setting, so a player who set both got one drawn over the
    -- other with no way to see the lower one, and a colour picked for the title
    -- bar silently restyled the grid's column labels too.
    -- red under: SetHeight(titleHeight + headerHeight).
    local _, window, cfg = scene()
    cfg.header.height = 18
    window:ApplyConfig()

    local layout = window.layout
    assertTrue(layout.headerHeight > 0, "the scene has no column strip to be wrong about")
    assertEqual(window.headerBG:GetHeight(), layout.titleHeight)
    assertTrue(window.headerBG:GetHeight() < layout.titleHeight + layout.headerHeight,
        "the background still reaches the column labels")
end)

test("A window with no title bar draws no header background at all", function()
    -- The strip is sized off the title row now, so "no title row" has to mean
    -- "no rectangle" rather than "a rectangle the height of the column labels".
    local _, window, cfg = scene()
    cfg.frame.titleBar = false
    window:ApplyConfig()
    assertFalse(window.headerBG:IsShown())
end)

test("The header draws the WINDOW'S NAME, and follows a rename", function()
    -- `header.title` was a second name for a window that already has one, and two
    -- names for one thing is two things that can disagree: a window renamed in
    -- the picker kept whatever its header had been set to, so the header could
    -- not be used to tell which window you were looking at.
    -- red under: restoring the title override.
    local _, window, cfg = scene()
    cfg.name = "Raid frame"
    window:ApplyConfig()
    assertEqual(window.frame.title:GetText(), "Raid frame")

    cfg.name = "Mythic+"
    window:ApplyConfig()
    assertEqual(window.frame.title:GetText(), "Mythic+", "the header did not follow the rename")
end)

test("The window NAME takes the header's colour, class colour and all", function()
    -- The title used to be left to the library's skin, so the Header text group
    -- styled every part of the strip except the one word a player thinks of as
    -- the header: font, size, outline and shadow all came from that group and
    -- only the colour did not.
    -- red under: dropping the SetTextColor from ApplyTitle, or letting ApplySkin
    -- run after it.
    local inst, window, cfg = scene()
    inst.mocks.RAID_CLASS_COLORS.PALADIN = { r = 0.41, g = 0.8, b = 0.94 }

    cfg.header.color      = { r = 0.2, g = 0.4, b = 0.6, a = 1 }
    cfg.header.colorMode = "custom"
    window:ApplyConfig()

    local c = window.frame.title.__textColor
    assertEqual(c[1], 0.2, "the title ignored the header colour")
    assertEqual(c[3], 0.6)

    -- And the same class-colour reading the session line beside it takes.
    cfg.header.colorMode = "class"
    window:ApplyConfig()
    c = window.frame.title.__textColor
    assertEqual(c[1], 0.41)
    assertEqual(c[3], 0.94)
    assertEqual(c[1], window.sessionText.__textColor[1],
        "the title and the session line are one header and must not differ")
end)

test("Column header class color is the local player's too", function()
    -- The strip labels the grid rather than any row in it, so it takes the same
    -- reading the title bar does.
    -- red under: the two strips disagreeing about whose class they mean.
    local inst, window, cfg = scene()
    inst.mocks.RAID_CLASS_COLORS.PALADIN = { r = 0.41, g = 0.8, b = 0.94 }
    cfg.columnHeader.colorMode = "class"
    window:ApplyConfig()

    local button = window.columnHeaders and window.columnHeaders[1]
    assertTrue(button ~= nil, "no column header was built")
    assertEqual(button.text.__textColor[1], 0.41)
end)

test("Scale scales the WINDOW, not just what is inside it", function()
    -- The visible frame is pinned TOPLEFT and BOTTOMRIGHT to the anchor, so the
    -- anchor's screen rect dictates the frame's whatever scale the frame carries.
    -- Scaling the frame alone therefore left the box the size it was and shrank
    -- only its contents: at 0.5 a full-size window with a miniature grid in the
    -- corner of it.
    -- red under: dropping anchor:SetScale and keeping frame:SetScale alone.
    local _, window, cfg = scene()
    cfg.frame.scale = 0.5
    window:ApplyConfig()

    assertEqual(window.anchor:GetScale(), 0.5, "the geometry frame did not scale")
    assertEqual(window.frame:GetScale(), 0.5, "the visible frame did not scale")

    cfg.frame.scale = nil
    window:ApplyConfig()
    assertEqual(window.anchor:GetScale(), 1.0, "an unset scale is 1, not 0")
    assertEqual(window.frame:GetScale(), 1.0)
end)

test("Border style None draws NO edge, whatever the library's own is", function()
    -- `borderPath` falls back to NS.SKIN's edge when a NAMED texture cannot be
    -- fetched, which is right for a missing media pack and wrong for a CHOICE:
    -- LSM's name for the empty border is not a failed fetch, and falling back on
    -- it handed the player the Ka0s edge they had just turned off.
    --
    -- Asserted at a NON-ZERO thickness, because the `borderSize == 0` branch would
    -- otherwise hide the bug: the style has to answer for itself.
    -- red under: moving the "None" test out of `borderPath` and back behind the
    -- size check, or dropping it.
    local _, window, cfg = scene()
    cfg.frame.borderSize = 8

    -- Every spelling of "no border", including the two a hand-edited
    -- SavedVariables or a profile written before the setting existed can produce.
    for _, style in ipairs({ "None", "", "\0" }) do
        cfg.frame.borderStyle = (style ~= "\0") and style or nil
        window:ApplyConfig()
        local backdrop = window.frame.__backdrop or {}
        assertEqual(backdrop.edgeFile, nil,
            ("%q still drew an edge"):format(tostring(cfg.frame.borderStyle)))
    end
end)

test("A border style that CANNOT be fetched still falls back to the library edge", function()
    -- The other half of the same function, and the reason "None" could not simply
    -- be lumped in with it. A named texture that does not resolve is a media pack
    -- that is no longer installed -- a failure, not a choice -- and a window that
    -- silently loses its edge over it is worse than one wearing the collection's.
    -- red under: `borderPath` answering nil for anything it cannot fetch.
    local _, window, cfg = scene()
    cfg.frame.borderStyle = "A Border No Media Pack Here Provides"
    cfg.frame.borderSize  = 2
    window:ApplyConfig()

    local backdrop = window.frame.__backdrop or {}
    assertTrue(backdrop.edgeFile ~= nil,
        "an unfetchable NAME is a failure, and falls back to the Ka0s edge")
end)

test("With no border, the SKIN's inner highlight goes too", function()
    -- LibKa0s's ApplySkin builds a 1px `frame.innerBorder` CHILD inset inside the
    -- black edge. It is not part of the backdrop ApplyBorder rewrites, so with the
    -- style set to None and the thickness at 0 it was the whole visible border --
    -- outliving both controls that claim to govern one.
    -- red under: ApplyBorder leaving frame.innerBorder alone.
    local _, window, cfg = scene()
    cfg.frame.borderStyle = "None"
    cfg.frame.borderSize  = 0
    window:ApplyConfig()

    -- ASSERTED, not skipped when absent: the harness loads the real
    -- libs/LibKa0s/Core.lua, so ApplySkin has genuinely built this child by now.
    -- A guarded `if type(...) == "table"` here would pass on a day the library
    -- stopped building it, which is exactly the day this case has to fail.
    assertEqual(type(window.frame.innerBorder), "table",
        "the library's inner border was never built -- this case is asserting nothing")
    assertEqual(window.frame.innerBorder:IsShown(), false,
        "the skin's highlight is the border the settings could not turn off")

    -- And it comes back with the edge, because inside a real border it is the
    -- highlight the library drew it to be.
    cfg.frame.borderStyle = "Blizzard Tooltip"
    cfg.frame.borderSize  = 2
    window:ApplyConfig()
    assertEqual(window.frame.innerBorder:IsShown(), true)
end)

test("The resize grip is built unconditionally and follows the LOCK", function()
    -- There used to be a `resizeGrip` setting read inside BuildFrame, which runs
    -- ONCE per window -- so unticking it did nothing at all until a reload. The
    -- lock already answers this question, and now it is the only thing that does.
    -- red under: restoring the `if frameCfg.resizeGrip ~= false then` gate.
    local _, window, cfg = scene()
    assertTrue(window.grip ~= nil, "the grip was not built")

    cfg.frame.locked = false
    window:ApplyConfig()
    assertEqual(window.grip:IsShown(), true, "an unlocked window offers its grip")

    cfg.frame.locked = true
    window:ApplyConfig()
    assertEqual(window.grip:IsShown(), false, "locking is how you put the grip away")
end)

test("`resizeGrip` is gone from the code, not just from the panel", function()
    -- The BEHAVIOURAL guard above cannot catch this one coming back. A resurrected
    -- `if frameCfg.resizeGrip ~= false then` reads a key no profile has any more,
    -- so it is always true and every case still passes -- right up until someone
    -- re-adds the schema row and the old bug with it. So the guard is static.
    -- red under: any read of frameCfg.resizeGrip anywhere in these two files.
    local offenders = {}
    for _, path in ipairs{ "/modules/Window.lua", "/settings/Schema.lua",
                           "/defaults/Profile.lua" } do
        local fh = assert(io.open(T.root .. path, "r"))
        local n = 0
        for line in fh:lines() do
            n = n + 1
            local code = line:gsub("%s*%-%-.*$", "")
            if code:find("resizeGrip", 1, true) then
                offenders[#offenders + 1] = path .. ":" .. n
            end
        end
        fh:close()
    end
    assertEqual(#offenders, 0, table.concat(offenders, ", "))
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
