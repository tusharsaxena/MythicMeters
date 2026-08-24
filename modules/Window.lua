-- modules/Window.lua
--
-- ONE window: its frames, its header, its row pool, and the coalesced refresh
-- loop that decides when any of it is redrawn. modules/WindowManager.lua owns
-- the registry of these; this file owns an instance.
--
-- A window is an INSTANCE, not a singleton (design §6). Every display setting
-- lives in the window's own config table, which is what makes multi-window and
-- copy-settings-from cheap — and it is why nothing in this file reads
-- `db.profile` for anything except the master enable.
--
-- ---------------------------------------------------------------------------
-- THE ANCHOR FRAME, AND WHY THERE ARE TWO FRAMES INSTEAD OF ONE
-- ---------------------------------------------------------------------------
--
-- Rule R3: a StatusBar handed a secret meter value is marked HasSecretValues,
-- which makes its position data secret and propagates that to anything anchored
-- to it. So no code path in this addon may read geometry back off a widget that
-- has held a value.
--
-- Dragging and resizing want exactly that, though: "where did the user just put
-- this window" is a GetPoint, and "how big did they just make it" is a GetWidth.
-- The way out is to keep those two questions on a frame that can never touch a
-- value. `inst.anchor` is a bare, empty, invisible Frame parented to UIParent.
-- It has no children, no textures and no cells; the VISIBLE window is anchored
-- TOPLEFT and BOTTOMRIGHT to it, so it inherits the anchor's position and size.
--
-- Secretness travels from a frame to whatever is anchored TO that frame — i.e.
-- downstream — and the anchor is upstream of everything. Drag and resize
-- therefore act on the anchor, the two getters read the anchor, and the visible
-- window and its rows are never asked a question about themselves. Everything
-- else on screen — the header strip, the column headers, the row positions, the
-- cell widths — is computed from config in BuildLayout below, and read back from
-- nothing at all.
--
-- ---------------------------------------------------------------------------
-- THE REFRESH LOOP
-- ---------------------------------------------------------------------------
--
-- Meter events fire far faster than a human reads. One event must NEVER drive
-- one rebuild, so every message handler in this file does nothing but set a
-- flag, and a single OnUpdate spends the window's `data.throttle` (0.25s by
-- default, clamped to Constants.THROTTLE_MIN/MAX) before turning that flag into
-- a Refresh. A twenty-second pull that reports two thousand times still draws
-- eighty times.
--
-- Each window owns a PRIVATE bus target from NS.NewBusTarget(). CallbackHandler
-- keys callbacks by (message, target), so several windows registering the same
-- message on the shared addon object would silently clobber each other and only
-- the last one would ever refresh (anti-pattern #32).

local addonName, NS = ...

-- Perf bracket upvalue (performance-§2): resolved ONCE at load, never through an
-- NS lookup on the hot path.
local Perf = NS.Perf

local Const = NS.Constants
local MSG   = Const.MSG
local L     = NS.L

local Window = {}
NS.Window = Window

local WindowProto = {}
WindowProto.__index = WindowProto

-- Gap between two adjacent columns. Defined in core/Constants.lua because
-- core/Database.lua's width migration sizes a frame around the same seam.
local COLUMN_GAP = Const.COLUMN_GAP

-- How tall the column-header strip is, as a multiple of the row height. The
-- headers are the same text at the same size as the rows, so tying them to the
-- row height keeps the grid on one rhythm when a player changes it.
local HEADER_ROW_FACTOR = 1.0

-- How far up from the bottom of the tinted title band the divider hairline is
-- drawn. Named because two things depend on it agreeing: the divider itself, and
-- `TitleRowTop`, which centres the whole title row in the space ABOVE it.
local DIVIDER_INSET = 2

-- How much of the header the session line is allowed to run across, right to
-- left. A constant rather than a measurement of the text inside it: this file
-- never measures a widget (rule R3), and the line is right-justified inside it,
-- so the number only has to be wide enough for the longest string it can hold.
local SESSION_LINE_WIDTH = 220

-- ---------------------------------------------------------------------------
-- HEADER ART, AND THE TWO WAYS IT ALREADY FAILED
-- ---------------------------------------------------------------------------
--
-- First attempt: texture paths (`Interface\Buttons\UI-SortArrow-Up`). They do
-- not exist, and a texture that fails to load draws nothing and raises nothing —
-- so the arrow was simply absent, with no error to read.
--
-- Second attempt: Unicode glyphs (BLACK UP-POINTING TRIANGLE, GEAR, LOCK). Those
-- are not in the game's default font and rendered as replacement boxes. "A glyph
-- is in the font or it renders as a box" was the reasoning, and the box is what
-- happened.
--
-- Both failures share a shape: the art was NAMED at authoring time and its
-- existence was never checked. So now it is checked at runtime — atlases through
-- Compat.FirstAtlas, which asks C_Texture.GetAtlasInfo — and underneath every
-- candidate there is an ASCII fallback, because the one thing that cannot fail is
-- a character every font has had since 1963.
--
-- The FALLBACK IS NOT A PLACEHOLDER. `v`, `^`, `*`, `#` and `>` are what this draws on
-- a client where nothing else resolves, and that is a legible header rather than
-- a row of boxes.
-- CONFIRMED PRESENT on a live 12.x client via `/mm debug diag`, which is the
-- only reason any of these names is here. `common-dropdown-icon-sortdown`,
-- `common-icon-settings` and `common-icon-lock` were all probed and all absent —
-- they are the names that looked right and were not.
--
-- `auctionhouse-ui-sortarrow` points DOWN as shipped; the ascending form is the
-- same texture flipped vertically, which is one SetTexCoord rather than a second
-- asset to go looking for.
local SORT_ATLAS_DOWN = { "auctionhouse-ui-sortarrow" }
local SORT_ATLAS_UP   = { "auctionhouse-ui-sortarrow" }
local SORT_ASCII_DOWN = "v"
local SORT_ASCII_UP   = "^"

-- THE TOP RUNG, above both of the above, and the reason it is not simply the
-- only rung is the paragraph above: art that is NAMED at authoring time and
-- never checked is how this header failed twice. `NS.Icon` answers nil for an
-- absent library AND for a name the catalog does not ship, so the check is the
-- same call that produces the path — there is no window in which a name is
-- believed and not verified.
--
-- Two assets, not one flipped. The atlas rung flips `auctionhouse-ui-sortarrow`
-- with SetTexCoord because the client ships one arrow; the collection ships
-- both, and flipping one of a matched pair would draw an inverted glyph that
-- looks right today and stops looking right the moment the art is redrawn.
--
-- Tinted with the HEADER colour rather than shipped gold, exactly as
-- BankLedger's LedgerTable.lua tints the same two marks: the art is near-white
-- by contract, and near-white beside a gold label reads as a second colour
-- inside one string rather than as one control.
local SORT_MARK_DOWN = "sort-down"
local SORT_MARK_UP   = "sort-up"

-- The gear, padlock and export art moved to modules/HeaderControls.lua with the
-- controls themselves. SORT_* above stays: ApplyColumnHeaders draws the sort
-- arrow and that is this file's own, not a header control.


-- The header's lock and gear buttons, as GLYPHS rather than as textures.
--
-- Textures were the first attempt and they would not line up. Each shipped icon
-- carries its own transparent padding, so three of them at a nominal 14x14 sit at
-- three different apparent heights and the row reads as if it were assembled by
-- accident. Nudging each one by hand fixes the screenshot and breaks at the next
-- font size.
--
-- A glyph has no padding problem: three FontStrings at one size on one baseline
-- ARE aligned, by construction, and they scale with the header font instead of
-- against it. This is also what the reference screenshot is doing.

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function lsm()
    return LibStub and LibStub("LibSharedMedia-3.0", true)
end

local function fontPath(name)
    local media = lsm()
    local path = media and name and media:Fetch("font", name, true)
    return path or Const.FONT_MONO or _G.STANDARD_TEXT_FONT
end

--- The LSM border texture the player picked, falling back to the LIBRARY's own
--- edge rather than to a literal: NS.SKIN's edgeFile is the Ka0s window edge
--- (standalone-windows), and restating it here would be the copy that goes stale
--- one hex digit at a time.
local function borderPath(name)
    local media = lsm()
    local path = media and name and media:Fetch("border", name, true)
    return path or (NS.SKIN and NS.SKIN.edgeFile)
end

-- Taken from the CORE SEAM (core/CoreSetup.lua publishes NS.RGBA), not from a
-- second LibStub lookup carrying its own copy of the library's channel reader —
-- the same note applies in modules/Row.lua, which is precisely the file the copy
-- was duplicated with. Resolved defensively so a degraded install renders in the
-- caller's default colors instead of raising.
local RGBA = NS.RGBA or function(_, dr, dg, db, da)
    return dr, dg, db, da
end

local function clamp(v, lo, hi)
    if type(v) ~= "number" then return lo end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- Resolve a collaborator module by either shape it can have: a plain table hung
--- on NS, or an AceAddon module in the registry. Same resolution PerfSetup uses,
--- and for the same reason — the modules are written by different hands and this
--- file must not care which idiom won.
local function mod(name)
    local m = NS[name]
    if m then return m end
    if NS.GetModule then return NS:GetModule(name, true) end
    return nil
end

-- ---------------------------------------------------------------------------
-- Layout — rule R3 in one function
-- ---------------------------------------------------------------------------

--- Compute every coordinate this window will use, from CONFIG ONLY.
---
--- Not one widget is consulted. That is the whole point: after a cell has been
--- handed a secret value its geometry is secret too, so the only trustworthy
--- source of "where does the third column start" is the arithmetic that put it
--- there. Recomputed on a settings change, never on a refresh.
---
--- @return table layout
function WindowProto:BuildLayout()
    local cfg    = self.config
    local frame  = cfg.frame or {}
    local rows   = cfg.rows or {}
    local header = cfg.header or {}

    local pad       = frame.padding or 6
    local rowHeight = rows.height or 16
    local spacing   = rows.spacing or 1

    local layout = {
        padding     = pad,
        rowHeight   = rowHeight,
        rowSpacing  = spacing,
        titleHeight = (frame.titleBar ~= false) and (header.height or 18) or 0,
        headerHeight = rowHeight * HEADER_ROW_FACTOR,
        growUp      = (rows.growthDirection == "UP"),
        columns     = {},
    }

    -- The name column is not a stat and can never be removed, so it is placed
    -- first and separately (core/Constants.lua).
    local x = 0
    layout.nameColumn = {
        key = "name", x = x, width = Const.NAME_COLUMN_WIDTH, showBar = true,
    }
    x = x + Const.NAME_COLUMN_WIDTH + COLUMN_GAP

    -- STAT COLUMNS SHARE WHATEVER THE FRAME HAS LEFT, EQUALLY.
    --
    -- Dragging the window wider used to leave the grid where it was and add empty
    -- space on the right; dragging it narrower clipped the rightmost column off
    -- the edge. Neither is what a player means by resizing a table.
    --
    -- So the stored per-column `width` stops being the drawn width and becomes
    -- what it always described — the shape a NEW column is born at. The drawn
    -- width is the frame's, minus the padding, minus the name column, minus the
    -- seams, divided by however many columns there are. The name column is
    -- excluded on purpose: a name does not get longer because the window did.
    --
    -- Const.COLUMN_MIN_WIDTH is the floor. Below it a column cannot hold an
    -- abbreviated number and its header at once, so the grid stops shrinking and
    -- the frame is clamped instead (MinResize below).
    local visible = {}
    for _, col in ipairs(cfg.columns or {}) do
        -- A column whose stat this build does not offer is DROPPED rather than
        -- drawn blank: it means the profile was written against a build with
        -- more stats in the catalog, and a nameless empty column is worse than
        -- an absent one.
        local stat = Const.STAT_BY_KEY[col.stat]
        if stat then visible[#visible + 1] = { col = col, stat = stat } end
    end

    local statWidth = Const.COLUMN_WIDTH
    if #visible > 0 then
        local available = (frame.width or 694) - pad * 2
            - Const.NAME_COLUMN_WIDTH - COLUMN_GAP * #visible
        statWidth = math.floor(available / #visible)
        if statWidth < Const.COLUMN_MIN_WIDTH then statWidth = Const.COLUMN_MIN_WIDTH end
    end

    for _, entry in ipairs(visible) do
        layout.columns[#layout.columns + 1] = {
            key     = entry.col.stat,
            stat    = entry.stat,
            x       = x,
            width   = statWidth,
            showBar = entry.col.showBar ~= false,
        }
        x = x + statWidth + COLUMN_GAP
    end

    -- The smallest this window may be dragged to, both axes, from the same
    -- arithmetic that just laid it out. Published on the layout so the resize
    -- clamp and the layout can never disagree about it.
    layout.minWidth = Const.NAME_COLUMN_WIDTH + pad * 2
        + math.max(#visible, 1) * (Const.COLUMN_MIN_WIDTH + COLUMN_GAP)
    layout.minHeight = pad * 2 + layout.titleHeight + layout.headerHeight + rowHeight

    layout.rowWidth = x - COLUMN_GAP
    layout.bodyWidth = (frame.width or 694) - pad * 2

    -- How many rows FIT, from the configured frame height. `rows.maxRows == 0`
    -- means "as many as fit", which is why this is computed rather than read off
    -- the frame — and it is also the cap that keeps a corrupted config from
    -- asking the pool for thousands of frames (Constants.MAX_ROWS).
    local bodyHeight = (frame.height or 220) - pad * 2 - layout.titleHeight - layout.headerHeight
    local fits = math.floor((bodyHeight + spacing) / (rowHeight + spacing))
    if fits < 1 then fits = 1 end
    local capped = rows.maxRows or 0
    if capped > 0 and capped < fits then fits = capped end
    layout.maxRows = math.min(fits, Const.MAX_ROWS)

    return layout
end

-- ---------------------------------------------------------------------------
-- Cached config (performance-§3)
-- ---------------------------------------------------------------------------

--- Cache the per-refresh config reads into instance fields, and rebuild the
--- layout. Called on creation and on ANY settings change — never per frame.
---
--- The values below are read on every OnUpdate tick, and reaching
--- `self.config.data.throttle` forty times a second through three table lookups
--- is exactly the per-frame cost the standard's upvalue rule exists to remove.
function WindowProto:RefreshUpvalues()
    local cfg = self.config
    local data = cfg.data or {}

    self.throttle    = clamp(data.throttle or 0.25, Const.THROTTLE_MIN, Const.THROTTLE_MAX)
    self.sessionType = data.sessionType or Const.SESSION_TYPE.Current
    self.sortColumn  = data.sortColumn or "DamageDone"
    self.locked      = (cfg.frame or {}).locked and true or false
    self.layout      = self:BuildLayout()
end

-- ---------------------------------------------------------------------------
-- Frame construction
-- ---------------------------------------------------------------------------

local function onDragStart(frame)
    local inst = frame.mmWindow
    if not inst or inst.locked then return end
    inst.anchor:StartMoving()
end

local function onDragStop(frame)
    local inst = frame.mmWindow
    if not inst then return end
    inst.anchor:StopMovingOrSizing()
    inst:SavePosition()
end

local function onSizeChanged(anchor, width, height)
    -- The handler ARGUMENTS are the new size. Taking them here rather than
    -- calling GetWidth later means the resize path never asks a frame a
    -- question, which keeps the rule the same on both axes even though the
    -- anchor would in fact be safe to ask.
    local inst = anchor.mmWindow
    if not inst then return end
    inst.pendingWidth  = width
    inst.pendingHeight = height
end

local function onResizeStop(grip)
    local inst = grip.mmWindow
    if not inst then return end
    inst.anchor:StopMovingOrSizing()
    inst:SaveSize()
end




--- Click on a column header: sort by it, or reverse it.
local function onColumnClick(button)
    local inst = button.mmWindow
    if inst then inst:SortByColumn(button.mmKey) end
end

--- Build the two frames, the header and the body. Runs once per window per
--- session; everything after it is re-application, never reconstruction.
function WindowProto:BuildFrame()
    if self.frame then return end

    local cfg   = self.config
    local frameCfg = cfg.frame or {}
    local name  = "MultiMetersWindow" .. tostring(self.id)

    -- The clean geometry frame. Empty on purpose — see the file header.
    local anchor = CreateFrame("Frame", name .. "Anchor", UIParent)
    anchor:SetSize(frameCfg.width or 694, frameCfg.height or 220)
    anchor:SetMovable(true)
    anchor:SetResizable(true)
    anchor:SetClampedToScreen(frameCfg.clampToScreen ~= false)
    anchor.mmWindow = self
    anchor:SetScript("OnSizeChanged", onSizeChanged)
    self.anchor = anchor

    local frame = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    frame:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, 0)
    frame:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 0, 0)
    frame:SetMovable(true)
    -- The BODY does not take the mouse. It used to, so that the whole window
    -- dragged as one object, and that is exactly what stole every hover from the
    -- cells underneath it. Dragging is the title bar's job now (dragBar, below).
    frame:EnableMouse(false)
    frame.mmWindow = self
    self.frame = frame

    -- The drag handle: an invisible strip over the title bar. A window is dragged
    -- from its title bar in every other frame in the game, and it is the one
    -- horizontal band of this window that no cell occupies — so dragging and
    -- hovering a number stop competing for the same clicks.
    local dragBar = CreateFrame("Frame", nil, frame)
    dragBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    dragBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    dragBar:EnableMouse(true)
    dragBar:RegisterForDrag("LeftButton")
    dragBar:SetScript("OnDragStart", onDragStart)
    dragBar:SetScript("OnDragStop",  onDragStop)
    dragBar.mmWindow = self
    self.dragBar = dragBar

    -- ESC DOES NOT CLOSE THIS WINDOW, and the frame is deliberately NOT in
    -- UISpecialFrames.
    --
    -- That list is right for a dialog you opened and will dismiss. A meter is
    -- neither: it is furniture, it is meant to sit there for a whole raid night,
    -- and Escape is a key a player presses constantly for other reasons —
    -- clearing a target, closing somebody else's frame, leaving a vehicle. Every
    -- one of those would take the meter down, and nothing about the resulting
    -- empty screen says which key did it or how to undo it.
    --
    -- Closing is therefore an explicit act: the X in the header, or `/mm toggle`.
    -- The frames are still NAMED, because a name is what `/framestack` and any
    -- other addon needs to talk about them.
    -- The title and divider members are assigned BEFORE ApplySkin so the library
    -- can tint them. Their colors are deliberately never set here: Core.SKIN's
    -- values are the contract, and a matching literal in this file is the copy
    -- that goes stale one hex digit at a time (standalone-windows).
    frame.title = frame:CreateFontString(nil, "OVERLAY")
    frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -5)

    frame.divider = frame:CreateTexture(nil, "ARTWORK")
    frame.divider:SetHeight(1)

    -- The header strip's own background (`header.bgColor`). On the BORDER layer:
    -- above the backdrop's bgFile, which is BACKGROUND, and below the divider,
    -- which is ARTWORK — so the strip tints without swallowing the line under
    -- it. Built here rather than on first use so moving the setting re-colors a
    -- texture that already exists instead of creating one mid-frame.
    --
    -- Not a member of `frame`: NS.ApplySkin walks a fixed set of frame keys and
    -- an extra one is a key it has never heard of.
    self.headerBG = frame:CreateTexture(nil, "BORDER")

    if NS.ApplySkin then NS.ApplySkin(frame) end

    -- ── The header's controls ──
    --
    -- Built by modules/HeaderControls.lua, which owns the whole strip: which
    -- controls exist, where each sits, what art it draws from, and when it
    -- fades. This file keeps the frames they hang on and nothing else about
    -- them -- see that module's header for why the boundary sits here.
    if NS.HeaderControls then
        NS.HeaderControls:Attach(self)
        NS.HeaderControls:HookHover(self)
    end

    -- The header's own text line, and the segment selector behind it.
    --
    -- The line carries the session name, its duration and -- when the window asks
    -- for it -- the group total for the sort column, folded into one string
    -- because every piece may be a secret and only `..` may join those.
    --
    -- IT TAKES NO MOUSE, and that is a deliberate removal. It used to be a
    -- Button carrying the segment dropdown, sized to a fixed 220px so the text
    -- could be right-justified inside it — which put an INVISIBLE CLICK TARGET
    -- across the middle of the header. It glowed red on hover, it opened a menu
    -- from a patch of empty title bar, and nothing on screen said it was there.
    -- Sizing it to its own text instead is not available: this file may not
    -- measure a widget (rule R3).
    --
    -- The dropdown did not go anywhere. The strip's segment control opens the
    -- same menu (modules/HeaderControls.lua), and it is a control a player can
    -- see, which the session line never was.
    --
    -- The FontString stays a child of this frame rather than of `frame`, because
    -- that is what lets ONE SetPoint in ApplyHeader place both.
    self.sessionLine = CreateFrame("Frame", nil, frame)

    self.sessionText = self.sessionLine:CreateFontString(nil, "OVERLAY")
    self.sessionText:SetJustifyH("RIGHT")
    self.sessionText:SetAllPoints(self.sessionLine)

    self.body = CreateFrame("Frame", nil, frame)

    -- ── SCROLLING ────────────────────────────────────────────────────────────
    --
    -- NOT a ScrollFrame, and not because one would be hard. This window already
    -- draws `layout.maxRows` rows chosen out of a longer list, so scrolling is
    -- choosing a DIFFERENT window into that list — one integer, applied at the
    -- top of the render loop. A ScrollFrame would mean building every row and
    -- letting the client clip them, which is more frames, more work per refresh,
    -- and a scroll child whose height would have to be measured.
    --
    -- The offset is plain and comes from a wheel event, so nothing here reads
    -- geometry back off a frame or looks at a meter value (rules R1 and R3 are
    -- untouched).
    self.scrollOffset = 0
    self.body:EnableMouseWheel(true)

    -- RIGHT-CLICK ON EMPTY SPACE leaves a breakdown. The rows handle their own
    -- (modules/Row.lua), but a short breakdown leaves most of the body bare and
    -- "right-click anywhere" has to mean anywhere.
    --
    -- The body's mouse is enabled ONLY while a breakdown is open. There is a
    -- comment on the frame above saying the body used to take the mouse and
    -- "stole every hover from the cells underneath it" — the cells are
    -- descendants and should still win, but that was learned the hard way, so the
    -- grid keeps exactly the behaviour it has today and only a drilled window
    -- changes.
    self.body:SetScript("OnMouseUp", function(_, button)
        if button ~= "RightButton" then return end
        local D = mod("DrillDown")
        if D and D.Exit then D:Exit(self.config) end
    end)
    if self.body.RegisterForClicks then
        self.body:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    end
    self.body:EnableMouse(false)
    self.body:SetScript("OnMouseWheel", function(_, delta)
        -- Up scrolls toward the top, which is `delta > 0` and a SMALLER offset.
        self:ScrollBy(delta > 0 and -1 or 1)
    end)

    -- The column-header strip lives on the BODY and holds plain FontStrings that
    -- never receive a value, so it is one of the few things here that could
    -- safely be measured — and still is not, for one rule rather than two.
    self.columnHeaders = {}
    self.headerFrame = CreateFrame("Frame", nil, frame)
    -- The column-header strip's backdrop. A plain texture rather than a
    -- BackdropTemplate: it is a flat fill behind text, nothing measures it, and a
    -- texture is a leaf the way the row backgrounds are. Transparent by default,
    -- so a window that never touches the setting looks exactly as it always did.
    self.headerBg = self.headerFrame:CreateTexture(nil, "BACKGROUND")
    self.headerBg:SetAllPoints(self.headerFrame)

    -- The meter-unavailable notice. Built once and kept hidden: it replaces the
    -- rows entirely when C_DamageMeter has nothing to give (design §6), and a
    -- window that has to build a panel at the moment it discovers a failure is a
    -- window that fails twice.
    self.notice = frame:CreateFontString(nil, "OVERLAY")
    self.notice:SetJustifyH("CENTER")
    self.notice:Hide()

    if frameCfg.resizeGrip ~= false then
        local grip = CreateFrame("Button", nil, frame)
        grip:SetSize(12, 12)
        grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
        grip:SetNormalTexture([[Interface\ChatFrame\UI-ChatIM-SizeGrabber-Up]])
        grip:SetHighlightTexture([[Interface\ChatFrame\UI-ChatIM-SizeGrabber-Highlight]])
        grip.mmWindow = self
        grip:SetScript("OnMouseDown", function() anchor:StartSizing("BOTTOMRIGHT") end)
        grip:SetScript("OnMouseUp", onResizeStop)
        self.grip = grip
    end

    frame:Hide()
end

-- ---------------------------------------------------------------------------
-- Applying config to the frames
-- ---------------------------------------------------------------------------

--- Push the whole config onto the widgets: geometry, chrome, header, column
--- headers and every pooled row. Idempotent, and the ONE path a settings change
--- takes — so "did I remember to re-apply X" has a single answer.
function WindowProto:ApplyConfig()
    self:BuildFrame()
    self:RefreshUpvalues()

    local cfg      = self.config
    local frameCfg = cfg.frame or {}
    local layout   = self.layout
    local frame    = self.frame

    self.anchor:SetSize(frameCfg.width or 694, frameCfg.height or 220)
    self.anchor:SetClampedToScreen(frameCfg.clampToScreen ~= false)
    self:ApplyPosition()

    frame:SetScale(frameCfg.scale or 1.0)
    frame:SetAlpha(frameCfg.alpha or 1.0)
    frame:SetFrameStrata(frameCfg.strata or "MEDIUM")

    -- The skin is re-applied rather than patched: ApplySkin owns the backdrop,
    -- the inner border and the two accent tints, and re-running it is how a
    -- re-skinned library lands here without this file knowing what changed.
    -- ApplyBorder then layers the player's edge over the result — in that order,
    -- because the skin is the base look and the setting is the override.
    if NS.ApplySkin then NS.ApplySkin(frame) end
    self:ApplyBorder(frameCfg)

    self:ApplyHeader()

    -- The body is placed from config, and everything below it hangs off the body
    -- rather than off a sibling — one anchor chain, one direction, no cycles.
    local pad = layout.padding
    self.body:ClearAllPoints()
    self.body:SetPoint("TOPLEFT", frame, "TOPLEFT", pad, -(pad + layout.titleHeight + layout.headerHeight))
    self.body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -pad, pad)

    self.notice:ClearAllPoints()
    self.notice:SetPoint("TOPLEFT", self.body, "TOPLEFT", 4, -8)
    self.notice:SetPoint("TOPRIGHT", self.body, "TOPRIGHT", -4, -8)
    self.notice:SetFont(fontPath((cfg.header or {}).font), (cfg.text or {}).size or 11, "")

    for _, row in ipairs(self.pool.all) do
        row:ApplyLayout(layout)
    end
    self:ApplyResizeBounds()
    self:ApplyLock()
    self:ApplyMinimised()
end

--- The window edge: `frame.borderStyle`, `borderSize` and `borderColor`.
---
--- LAYERED OVER NS.ApplySkin, never instead of it. The library has just written
--- its own backdrop onto the frame — bgFile, edgeFile, edgeSize, insets — and
--- this rewrites ONE part of that table: the edge. The base fields are read back
--- off NS.SKIN rather than restated as literals here, which is the whole reason
--- the seam exports SKIN alongside ApplySkin (core/CoreSetup.lua). A re-skinned
--- library therefore still lands on this window, and the only thing this file
--- claims to know is what the PLAYER chose.
---
--- `borderSize == 0` means "no edge", and it drops edgeFile with it: a zero
--- edgeSize with a texture still present is the combination WoW draws as a hard
--- 1px line, which is the setting doing the opposite of what it says.
---
--- @param frameCfg table  the window's `frame` config group
function WindowProto:ApplyBorder(frameCfg)
    local frame = self.frame
    if not frame.SetBackdrop then return end

    local skin = NS.SKIN or {}
    local size = clamp(frameCfg.borderSize or 2, 0, 32)
    local edge = (size > 0) and borderPath(frameCfg.borderStyle) or nil
    local inset = edge and size or 0

    frame:SetBackdrop({
        bgFile   = skin.bgFile,
        edgeFile = edge,
        edgeSize = edge and size or nil,
        insets   = { left = inset, right = inset, top = inset, bottom = inset },
    })

    local br, bg, bb, ba = RGBA(frameCfg.backdropColor, 0, 0, 0, 0.75)
    if frame.SetBackdropColor then frame:SetBackdropColor(br, bg, bb, ba) end

    if edge and frame.SetBackdropBorderColor then
        local er, eg, eb, ea = RGBA(frameCfg.borderColor, 0, 0, 0, 1)
        frame:SetBackdropBorderColor(er, eg, eb, ea)
    end
end

--- The font every line of the header strip is drawn in: the player's face, its
--- size, and the outline flag WoW wants as nil rather than as the string "NONE".
--- One reader for all three so the title, the session line and the column labels
--- can never drift onto different fonts.
---
--- @param header table  the window's `header` config group
--- @return string path, number size, string|nil flags
local function headerFont(header)
    local flags = (header.outline ~= "NONE") and header.outline or nil
    return fontPath(header.font), header.size or 12, flags
end

--- The header's text color, defaulting to the gold WoW uses for its own headers.
local function headerColor(header)
    return RGBA(header.color, 1, 0.82, 0, 1)
end

--- The header's font and colour, in the one shape modules/HeaderControls.lua
--- asks for it.
---
--- THE SEAM EXISTED BEFORE ANYTHING FILLED IT. `HeaderControls.Style` has always
--- read `NS.HeaderStyle` and always fallen through to a white 12px fallback,
--- because nothing published the function — so every comment saying the controls
--- take the header's colour described something that had never run. Published
--- here rather than computed there for the reason `headerFont` is one reader for
--- three lines: a second opinion about what the header looks like is how the
--- title and the strip below it end up on different fonts.
---
--- @param window table
--- @return table  { path, size, flags, r, g, b }
function NS.HeaderStyle(window)
    local header = (window.config or {}).header or {}
    local path, size, flags = headerFont(header)
    local r, g, b = headerColor(header)
    return { path = path, size = size, flags = flags, r = r, g = g, b = b }
end

--- The column-header strip's own font, size and flags.
---
--- Its OWN group, and that is the point of it existing. These used to come from
--- two different places — the path and size off `text`, the outline off `header`
--- — so changing the cell font silently restyled the headers and no setting
--- could make the strip differ from the numbers beneath it.
local function columnHeaderFont(colHeader)
    local flags = (colHeader.outline ~= "NONE") and colHeader.outline or nil
    return fontPath(colHeader.font), colHeader.size or 11, flags
end

--- Where something `h` pixels tall sits so it is CENTRED in the title bar.
---
--- WHY EVERY LINE OF THE TITLE BAR ASKS THIS. The title and the session line were
--- pinned 5px below the frame's top edge — a constant that predates the title bar
--- having a configurable height and had nothing to do with the band it draws in.
--- Nobody noticed until the header grew a strip of icons and the two disagreed.
--- One centre for the text, the session line and the controls means the row
--- cannot drift again when the bar's height, the font size or the control size
--- changes.
---
--- WHICH BAND IT CENTRES IN, AND WHY IT IS NOT THE TITLE BAR'S OWN. What a player
--- sees as the title bar runs from the frame's TOP EDGE down to the divider — the
--- padding above it is not a margin to anyone looking at the window, because the
--- backdrop is drawn behind it and there is no seam. Centring in the tinted band
--- alone (`padding` .. `padding + titleHeight`) is arithmetically centred and
--- optically wrong: it leaves the padding as dead space above the row and lands
--- the text hard against the divider, which is exactly what "everything is
--- anchored to the bottom" meant when it was reported.
---
--- COMPUTED, NEVER MEASURED (rule R3): `h` is the caller's own configured size,
--- not something read back off a widget. Clamped at the frame's top edge so a
--- control larger than the bar it sits in overflows downward rather than off the
--- window.
---
--- @param h number  the height of the thing being placed
--- @return number y  the offset to anchor its TOP at, relative to the frame's top
function WindowProto:TitleRowTop(h)
    local layout = self.layout
    -- The divider sits 2px up from the bottom of the tinted band; see
    -- ApplyHeaderStrip, which draws it at exactly this offset.
    local visible = layout.padding + layout.titleHeight - DIVIDER_INSET
    local inset = (visible - (h or 0)) / 2
    if inset < 0 then inset = 0 end
    return -inset
end

--- Where the header's two text lines must stop on the right: the frame padding,
--- plus the width of each header button that is currently shown. Shared by the
--- title and the session line so neither can end up running underneath one.
function WindowProto:HeaderRightInset()
    -- Every button that sits in the top-right corner has to be counted here, or
    -- the session line runs underneath them. Computed rather than measured — the
    -- buttons are placed from these same numbers (rule R3).
    -- FROM CONFIG, NOT FROM THE WIDGETS. The previous version asked each button
    -- `:IsShown()`, and a freshly created Button is shown by default -- so until
    -- the first layout pass ran, the inset counted every button as present
    -- whether the player had turned it off or not. Asking the module means the
    -- room the title reserves is derived from the same config the placement
    -- reads, so the two cannot disagree.
    local used = NS.HeaderControls and NS.HeaderControls.WidthUsed(self) or 0
    if used > 0 then used = used + self.layout.padding end
    return self.layout.padding + used
end

--- The window's name, in the title bar.
function WindowProto:ApplyTitle()
    local cfg    = self.config
    local header = cfg.header or {}
    local frame  = self.frame
    local path, size, flags = headerFont(header)

    -- `header.align` needs the title to SPAN the strip: a FontString with no
    -- width is exactly as wide as its text, so SetJustifyH on the bare TOPLEFT
    -- anchor it used to carry would move nothing at all. The span stops short of
    -- the close button, and the session line keeps its own RIGHT anchor — the
    -- two halves of the strip are placed from opposite ends, so aligning one can
    -- never push the other off the frame.
    local y = self:TitleRowTop(size)
    frame.title:ClearAllPoints()
    frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, y)
    frame.title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -self:HeaderRightInset(), y)
    frame.title:SetJustifyH(header.align or "LEFT")
    frame.title:SetFont(path, size, flags)
    -- THE TEST-MODE MARKER RIDES ON THE TITLE, in red, the way Loot History
    -- marks its own. Test mode fills the grid with numbers that look exactly like
    -- real ones — that is the entire point of it — so the only thing standing
    -- between a player and reading placeholder data as their own performance is a
    -- label saying otherwise. It goes in the TITLE rather than in the session
    -- line because the title is the part of the window nothing else competes for.
    local title = header.title ~= "" and header.title or (cfg.name or L["Multi Meters"])
    if NS.State and NS.State.testMode then
        title = title .. "   |cffff2020" .. L["TEST MODE"] .. "|r"
    end
    frame.title:SetText(title)
    frame.title:SetShown((cfg.frame or {}).titleBar ~= false)
    -- The title COLOR is ApplySkin's to set (frame.title is one of the two
    -- members it tints), so nothing here touches it.
end

--- The tinted block behind the header and the hairline that closes it off.
function WindowProto:ApplyHeaderStrip()
    local header = self.config.header or {}
    local layout = self.layout
    local frame  = self.frame
    local pad    = layout.padding

    -- The strip covers BOTH header rows — the title bar and the column labels —
    -- because that is the block a player pointing at "the header" means.
    local ar, ag, ab, aa = RGBA(header.bgColor, 0, 0, 0, 0.5)
    self.headerBG:ClearAllPoints()
    self.headerBG:SetPoint("TOPLEFT", frame, "TOPLEFT", pad, -pad)
    self.headerBG:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -pad, -pad)
    self.headerBG:SetHeight(layout.titleHeight + layout.headerHeight)
    self.headerBG:SetColorTexture(ar, ag, ab, aa)
    self.headerBG:SetShown((layout.titleHeight + layout.headerHeight) > 0)

    -- The drag strip covers exactly the title bar. Sized from the layout like
    -- every other coordinate — never measured off the title FontString.
    self.dragBar:SetHeight(layout.titleHeight > 0 and layout.titleHeight or 1)
    self.dragBar:SetShown(layout.titleHeight > 0)

    if frame.divider then
        frame.divider:ClearAllPoints()
        local dy = -(pad + layout.titleHeight - DIVIDER_INSET)
        frame.divider:SetPoint("TOPLEFT", frame, "TOPLEFT", pad, dy)
        frame.divider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -pad, dy)
        frame.divider:SetShown(layout.titleHeight > 0)
    end
end

--- The right-hand line of the header strip: which session, how long, how much.
--- Only its widget is placed here — UpdateHeaderText writes the text, once per
--- refresh rather than once per settings change.
function WindowProto:ApplySessionLine()
    local header = self.config.header or {}
    local path, size, flags = headerFont(header)
    local shown = (header.showSessionName or header.showDuration
        or header.showTotals) and true or false

    -- The BUTTON is what gets placed; the text fills it (SetAllPoints, in Build).
    -- Its width is a constant rather than a measurement of the string inside it,
    -- because measuring is the one thing this file never does — and a fixed click
    -- target is also steadier for the player than one that changes size every
    -- time the group total ticks over a magnitude.
    self.sessionLine:ClearAllPoints()
    local height = math.max(size + 4, 12)
    self.sessionLine:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT",
        -self:HeaderRightInset(), self:TitleRowTop(height))
    self.sessionLine:SetSize(SESSION_LINE_WIDTH, height)
    self.sessionLine:SetShown(shown)

    self.sessionText:SetFont(path, size, flags)
    self.sessionText:SetTextColor(headerColor(header))
    self.sessionText:SetShown(shown)
end

--- The column labels above the grid.
function WindowProto:ApplyColumnHeaders()
    local cfg    = self.config
    local layout = self.layout
    local pad    = layout.padding
    local colHeader = cfg.columnHeader or {}
    local colFont, colSize, flags = columnHeaderFont(colHeader)
    local hr, hg, hb, ha = RGBA(colHeader.color, 1, 0.82, 0, 1)

    -- One FontString per drawn column plus the name column's, placed at the same
    -- x offsets the cells will use — from the SAME layout table, so a header can
    -- never drift from the column under it.
    self.headerFrame:ClearAllPoints()
    self.headerFrame:SetPoint("TOPLEFT", self.frame, "TOPLEFT", pad, -(pad + layout.titleHeight))
    self.headerFrame:SetSize(layout.rowWidth, layout.headerHeight)

    local bgr, bgg, bgb, bga = RGBA(colHeader.bgColor, 0, 0, 0, 0)
    self.headerBg:SetColorTexture(bgr, bgg, bgb, bga)

    local data = cfg.data or {}
    -- The arrow belongs on whichever header the CURRENT order came from, and in
    -- `name` mode that is the Player column rather than a stat one. Without this
    -- the name column was the one header that could be sorted by and never said
    -- so.
    local sortKey = (data.sortMode == "name") and "name" or data.sortColumn

    -- MID-PULL THE ARROW FOLLOWS THE GRID, NOT THE REQUEST. Under the Combat
    -- restriction every mode degrades to the engine's ranking of the sort COLUMN
    -- (`aggregate.applied == "provider"`), so a `name` window drawn there was
    -- putting the arrow on the Player header over rows ordered by damage — the
    -- grid state stating something untrue rather than admitting a limitation.
    -- Read off the aggregate the render pass parked here, for the same reason
    -- RestrictedNotice does: it describes the grid on screen rather than the
    -- restriction state at the moment the header was drawn.
    local aggregate = self.aggregate
    if aggregate and aggregate.identityMode then sortKey = data.sortColumn end

    -- EVERY HEADER IS A BUTTON, including the name column's — clicking it sorts
    -- by that column, clicking it again reverses. The widget is created once per
    -- index and re-pointed, never rebuilt, so a settings change costs no frames.
    local function place(index, key, label, x, width)
        local button = self.columnHeaders[index]
        if not button then
            button = CreateFrame("Button", nil, self.headerFrame)
            button.text = button:CreateFontString(nil, "OVERLAY")
            button.text:SetPoint("LEFT", button, "LEFT", 0, 0)
            -- The sort arrow, in the same shipped atlas the Loot History header
            -- uses, so it reads as "a column header arrow" rather than as this
            -- addon's own invention.
            button.arrow = button:CreateFontString(nil, "OVERLAY")
            button.arrow:SetPoint("LEFT", button.text, "LEFT", 0, 0)
            button.arrow:SetJustifyH("LEFT")
            button.arrow:Hide()
            button.arrowTex = button:CreateTexture(nil, "OVERLAY")
            button.arrowTex:SetSize(10, 10)
            button.arrowTex:Hide()
            button.mmWindow = self
            button:SetScript("OnClick", onColumnClick)
            self.columnHeaders[index] = button
        end

        button.mmKey = key
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", self.headerFrame, "TOPLEFT", x, 0)
        button:SetSize(width, layout.headerHeight)

        -- LEFT-ALIGNED, both the name column and every stat column. The cells
        -- below are right-aligned and the headers used to match them, which put
        -- each label hard against the NEXT column's numbers and read as if it
        -- belonged to them.
        button.text:SetWidth(width)
        button.text:SetHeight(layout.headerHeight)
        button.text:SetFont(colFont, colSize, flags)
        button.text:SetTextColor(hr, hg, hb, ha)
        button.text:SetJustifyH("LEFT")
        button.text:SetText(label)

        if key == sortKey then
            -- Placed after the label rather than at a fixed offset, so it follows
            -- the text however long the label is. GetStringWidth is a measurement
            -- of a FontString this window OWNS and that has never held a value —
            -- rule R3 is about cells that have, and this is neither.
            local after = button.text:GetStringWidth() + 3
            local mark = NS.Icon and NS.Icon(
                data.sortAscending and SORT_MARK_UP or SORT_MARK_DOWN)
            local atlas = not mark and NS.Compat.FirstAtlas(
                data.sortAscending and SORT_ATLAS_UP or SORT_ATLAS_DOWN)

            if mark then
                button.arrowTex:ClearAllPoints()
                button.arrowTex:SetPoint("LEFT", button.text, "LEFT", after, 0)
                button.arrowTex:SetTexture(mark)
                -- No SetTexCoord: two assets, not one flipped. The atlas branch
                -- below flips because it has only one arrow to flip.
                button.arrowTex:SetTexCoord(0, 1, 0, 1)
                button.arrowTex:SetVertexColor(hr, hg, hb)
                button.arrowTex:Show()
                button.arrow:Hide()
            elseif atlas then
                button.arrowTex:ClearAllPoints()
                button.arrowTex:SetPoint("LEFT", button.text, "LEFT", after, 0)
                button.arrowTex:SetAtlas(atlas)
                -- Flipped vertically for ascending: the shipped arrow points
                -- down, and one SetTexCoord beats a second asset to go missing.
                if data.sortAscending then
                    button.arrowTex:SetTexCoord(0, 1, 1, 0)
                else
                    button.arrowTex:SetTexCoord(0, 1, 0, 1)
                end
                button.arrowTex:Show()
                button.arrow:Hide()
            else
                button.arrow:SetFont(colFont, colSize, flags)
                button.arrow:SetTextColor(hr, hg, hb, ha)
                button.arrow:SetText(data.sortAscending and SORT_ASCII_UP or SORT_ASCII_DOWN)
                button.arrow:ClearAllPoints()
                button.arrow:SetPoint("LEFT", button.text, "LEFT", after, 0)
                button.arrow:Show()
                button.arrowTex:Hide()
            end
        else
            button.arrow:Hide()
            button.arrowTex:Hide()
        end

        button:Show()
    end

    place(1, "name", L["Player"], layout.nameColumn.x, layout.nameColumn.width)
    for i, col in ipairs(layout.columns) do
        -- Localized at the USE SITE, never in core/Constants.lua: the catalog
        -- stores the English key so a locale registering later still wins.
        -- `headerLabel` falls back to the full label; only the stats whose full
        -- label does not fit a column carry an override.
        place(i + 1, col.key, L[col.stat.headerLabel or col.stat.label], col.x, col.width)
    end
    for i = #layout.columns + 2, #self.columnHeaders do
        self.columnHeaders[i]:Hide()
    end
end

--- Title, session line, and the column headers — the whole header strip, in the
--- order it is stacked on screen.
--- Show or hide everything below the title bar, per `frame.minimised`.
---
--- APPLIED FROM CONFIG AT THE TAIL OF ApplyConfig, not from the click. Any
--- CONFIG_CHANGED re-runs ApplyConfig, which unconditionally restores the body's
--- anchors and the window's size -- so a collapse driven only from the button
--- would be silently undone by the next unrelated setting change.
---
--- THE ANCHOR IS NOT RESIZED. Shrinking it fires onSizeChanged, which writes
--- pendingWidth/pendingHeight, and SaveSize persists whatever is pending on the
--- next resize-stop -- so a collapsed height would leak into `frame.height` and
--- the window would never come back to the size the player chose. Hiding the
--- children is the whole collapse.
---
--- Four things hang below the title, not one: the body carries the rows, but the
--- column-header strip, the notice and the grip are parented to the FRAME and
--- would go on drawing over a collapsed window.
function WindowProto:ApplyMinimised()
    local frameCfg = self.config.frame or {}
    -- `and true or false`, never `~= false`: a profile stored before this
    -- existed has no key at all, and `~= false` would collapse every one of them.
    local down = frameCfg.minimised and true or false

    -- THE WINDOW ACTUALLY SHRINKS. Hiding the children alone left a full-height
    -- empty frame sitting there, which is not what "collapse to the title bar"
    -- means to anybody looking at it.
    --
    -- The ANCHOR is left alone -- resizing it fires onSizeChanged, which writes
    -- pendingWidth/pendingHeight, and SaveSize persists whatever is pending on
    -- the next resize-stop, so the collapsed height would leak into
    -- frame.height and the window would never come back to the size the player
    -- chose. The visible frame is unpinned from the anchor's bottom instead and
    -- given the title bar's own height; expanding re-pins it.
    local frame = self.frame
    if down then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", self.anchor, "TOPLEFT", 0, 0)
        frame:SetPoint("TOPRIGHT", self.anchor, "TOPRIGHT", 0, 0)
        frame:SetHeight(self.layout.padding * 2 + self.layout.titleHeight)
    else
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", self.anchor, "TOPLEFT", 0, 0)
        frame:SetPoint("BOTTOMRIGHT", self.anchor, "BOTTOMRIGHT", 0, 0)
    end

    if self.body then self.body:SetShown(not down) end
    if self.headerFrame then self.headerFrame:SetShown(not down) end
    -- The notice is re-shown by Refresh whenever there is nothing to draw, so
    -- hiding it here is not enough on its own -- Refresh checks the same flag.
    if self.notice and down then self.notice:Hide() end
    -- ApplyLock is the grip's other author, so expanding must not resurrect a
    -- grip the lock had hidden.
    if self.grip then
        self.grip:SetShown(not down and not (frameCfg.locked and true or false))
    end
end

function WindowProto:ApplyHeader()
    -- FIRST, and the order is load-bearing: ApplyTitle and ApplySessionLine both
    -- read HeaderRightInset, which is derived from what the controls occupy.
    if NS.HeaderControls then NS.HeaderControls:Apply(self) end
    self:ApplyTitle()
    self:ApplyHeaderStrip()
    self:ApplySessionLine()
    self:ApplyColumnHeaders()
end

--- Position from the STORED anchor. Never from the frame — see the file header.
function WindowProto:ApplyPosition()
    local pos = (self.config.frame or {}).position or {}
    self.anchor:ClearAllPoints()
    self.anchor:SetPoint(pos.point or "CENTER", UIParent,
        pos.relativePoint or "CENTER", pos.x or 0, pos.y or 0)
end

--- Persist where the user just dragged the window to.
---
--- GetPoint is called on the ANCHOR, which has never held a value and never will
--- — that is the entire reason it exists (see the file header). Reading it off
--- `self.frame` would work today and would become a Lua error the first time a
--- cell inside it received a secret.
function WindowProto:SavePosition()
    local point, _, relativePoint, x, y = self.anchor:GetPoint()
    local frameCfg = self.config.frame
    if not frameCfg then return end
    frameCfg.position = {
        point         = point or "CENTER",
        relativePoint = relativePoint or "CENTER",
        x             = x or 0,
        y             = y or 0,
    }
    if NS.State and NS.State.debug and NS.Debug then
        NS.Debug("Window", "%d moved to %s %d,%d", self.id, point or "CENTER",
            math.floor(x or 0), math.floor(y or 0))
    end
end

--- Persist the size the user just dragged out, from the size the OnSizeChanged
--- handler was HANDED rather than from a getter.
function WindowProto:SaveSize()
    local frameCfg = self.config.frame
    if not (frameCfg and self.pendingWidth) then return end
    frameCfg.width  = math.floor(self.pendingWidth + 0.5)
    frameCfg.height = math.floor(self.pendingHeight + 0.5)
    self.pendingWidth, self.pendingHeight = nil, nil
    self:ApplyConfig()
    self:MarkDirty()
end

--- Refuse to be dragged smaller than the grid needs.
---
--- Enforced by the CLIENT through SetResizeBounds rather than by clamping in Lua
--- on every OnSizeChanged tick: the frame simply stops following the cursor, so
--- there is no fight between the drag and the clamp and no frame in which the
--- window is drawn at an illegal size.
---
--- Both minimums come off the layout, which is where they were computed from the
--- same arithmetic that placed the columns — so the size the window refuses to go
--- below and the size the grid needs cannot drift apart.
---
---   width   the name column, plus every stat column at Const.COLUMN_MIN_WIDTH,
---           plus the seams and the padding.
---   height  the title bar, the column-header strip and ONE row. A window with
---           room for no rows at all is a window showing nothing, which is not a
---           size anybody means to drag to.
function WindowProto:ApplyResizeBounds()
    local anchor = self.anchor
    if not (anchor and anchor.SetResizeBounds) then return end
    anchor:SetResizeBounds(self.layout.minWidth, self.layout.minHeight)
end

--- Lock / unlock.
---
--- THE CELLS ALWAYS OWN THE MOUSE. They used to own it only while the window was
--- locked, on the theory that an unlocked window should drag as one object — and
--- since a window ships UNLOCKED, the effect was that tooltips and drill-down did
--- not work at all until you happened to lock it. A meter whose numbers you
--- cannot hover is most of a meter missing, and nothing about an unlocked window
--- says that is why.
---
--- Dragging moved to the TITLE BAR instead, which is where a window is dragged
--- from in every other frame in the game, and which is a region no cell occupies.
--- So the two are no longer in competition and the lock governs exactly one
--- thing: whether that title bar responds.
---
--- SetMovable is deliberately left true throughout — flipping it is how a window
--- ends up permanently undraggable until a reload.
function WindowProto:ApplyLock()
    local locked = self.locked
    -- MINIMISE IS THE GRIP'S OTHER AUTHOR, so this has to agree with it or
    -- `/mm lock off` resurrects a grip over a collapsed window. Whichever of the
    -- two runs last wins, so both ask the same question.
    if self.grip then
        local down = (self.config.frame or {}).minimised and true or false
        self.grip:SetShown(not locked and not down)
    end

    for _, row in ipairs(self.pool.all) do
        row:EnableCellMouse()
    end

    -- Written as a branch, not as `locked and nil or "LeftButton"`: that
    -- expression can never produce nil, because `or` takes over the moment the
    -- left side is falsy, so the "locked" case would still register the drag.
    if locked then
        self.dragBar:RegisterForDrag()
    else
        self.dragBar:RegisterForDrag("LeftButton")
    end
    -- MOUSE STAYS ON, ALWAYS. Locking is what `RegisterForDrag()` above does --
    -- an empty registration is what stops the drag -- and the mouse flag was only
    -- ever suppressing hover as a side effect. A locked window is exactly when a
    -- player wants the chrome to fade, so a mouse-disabled dragBar fires no
    -- OnEnter and modules/HeaderControls.lua's reveal is dead in its commonest
    -- case.
    self.dragBar:EnableMouse(true)
end

-- ---------------------------------------------------------------------------
-- The row pool
-- ---------------------------------------------------------------------------
--
-- Ten or more dynamic frames means a pool rather than create-and-destroy: a
-- 40-player raid that reshuffles every quarter second would otherwise churn
-- hundreds of frames a minute, and WoW never truly frees one. Rows are acquired
-- for a refresh, released at the end of it, and kept forever.

--- Take a row from the free list, growing the pool a batch at a time.
function WindowProto:Acquire()
    local pool = self.pool
    local row = table.remove(pool.free)
    if not row then
        for _ = 1, Const.POOL_GROW_STEP do
            local fresh = NS.Row.New(self)
            fresh:ApplyLayout(self.layout)
            fresh:EnableCellMouse()
            pool.all[#pool.all + 1] = fresh
            pool.free[#pool.free + 1] = fresh
        end
        row = table.remove(pool.free)
    end
    pool.active[#pool.active + 1] = row
    return row
end

--- Return every active row to the free list.
function WindowProto:HideAll()
    local pool = self.pool
    for i = #pool.active, 1, -1 do
        local row = pool.active[i]
        row:Release()
        pool.active[i] = nil
        pool.free[#pool.free + 1] = row
    end
end

-- ---------------------------------------------------------------------------
-- The refresh
-- ---------------------------------------------------------------------------

--- Mark the window as needing a redraw. Every message handler ends here and
--- nothing else, which is what makes the throttle the only clock in the file.
--- The largest legal scroll offset for a list of `count` rows.
---
--- Derived from `layout.maxRows`, which is itself derived from the configured
--- frame height — so this is config arithmetic rather than a measurement, and it
--- answers 0 whenever everything already fits.
function WindowProto:MaxScroll(count)
    local visible = (self.layout and self.layout.maxRows) or 1
    local over = (count or 0) - visible
    return (over > 0) and over or 0
end

--- Move the scroll offset by `delta` rows and redraw.
---
--- ONLY THE FLOOR IS APPLIED HERE. The ceiling is the length of a list this
--- function does not have: it runs from a wheel event, between refreshes, and
--- asking the aggregator for a fresh list to find out how long it is would turn
--- a scroll into a meter read. So the offset is allowed to run optimistically
--- past the end and `Render` clamps it against the list it is actually drawing.
---
--- That is not a shortcut, it is the only ordering that cannot go stale: a
--- remembered row count is one refresh out of date the moment the group changes,
--- and clamping against a stale count is how a scroll silently stops one row
--- short of the bottom.
---
--- @param delta number  rows to move; negative is toward the top
function WindowProto:ScrollBy(delta)
    local want = (self.scrollOffset or 0) + (delta or 0)
    if want < 0 then want = 0 end
    if want == self.scrollOffset then return end

    self.scrollOffset = want
    self:MarkDirty()
    -- The wheel must answer NOW rather than on the next throttle tick, for the
    -- same reason a drill-down click does.
    self.elapsed = self.throttle
end

--- Put the view back at the top. Called when the LIST CHANGES IDENTITY —
--- entering or leaving a breakdown — because an offset carried across is an
--- offset into a list that no longer exists.
function WindowProto:ResetScroll()
    if self.scrollOffset == 0 then return end
    self.scrollOffset = 0
end

function WindowProto:MarkDirty()
    self.dirty = true
end

--- Whether this window should redraw on the throttle tick even though no message
--- has marked it dirty.
---
--- THE METER'S EVENTS ARE NOT A COMPLETE HEARTBEAT, and relying on them alone is
--- why a live window's numbers sat still through a fight.
--- `DAMAGE_METER_CURRENT_SESSION_UPDATED` describes the CURRENT session; a window
--- reading Overall, or pinned to a stored segment, is not what that event is
--- about and can go a whole pull without one arriving. The rows were correct and
--- stale at the same time, which is the worst way for a meter to be wrong.
---
--- So while a fight is on, a SHOWN window polls on the clock it already has.
--- This costs one aggregate per throttle tick per visible window — 0.25s by
--- default, which is exactly the rate a busy pull already drives through the
--- dirty flag — and it costs nothing at all out of combat, where the events are
--- sufficient and a still window should do no work.
---
--- @return boolean
function WindowProto:ShouldPoll()
    if not self.frame:IsShown() then return false end
    -- A COLLAPSED WINDOW HAS NOTHING TO DRAW INTO. This is a real clause and not
    -- an emergent one: `OnUpdate` is installed on `frame`, which stays SHOWN
    -- while minimised -- only the body hides -- so without this the window goes
    -- on aggregating every stat and rendering rows into a hidden body four times
    -- a second, forever.
    if (self.config.frame or {}).minimised then return false end
    if self:IsTest() then return false end
    local inCombat = _G.InCombatLockdown and _G.InCombatLockdown()
    if inCombat then return true end
    return (NS.Secrets and NS.Secrets.IsRestricted()) and true or false
end

local function onUpdate(frame, elapsed)
    local inst = frame.mmWindow
    if not inst then return end
    inst.elapsed = (inst.elapsed or 0) + elapsed
    if inst.elapsed < inst.throttle then return end
    inst.elapsed = 0
    if not inst.dirty and not inst:ShouldPoll() then return end
    inst.dirty = false
    inst:Refresh()
end

--- Can the game's meter give this window anything, and if not, what does it say
--- about why.
---
--- Provider is called in the DOT form its own file publishes it in
--- (`Provider.IsAvailable`): these are plain namespaced functions, not methods,
--- and a colon here would hand it this window as its first argument. A missing
--- Provider is treated as available, because the notice it would raise is about
--- the GAME's meter and there is nothing here to have asked.
---
--- @return boolean available, string|nil reason
local function meterAvailability()
    local Provider = mod("Provider")
    if Provider and Provider.IsAvailable then
        return Provider.IsAvailable()
    end
    return true, nil
end

--- The spell breakdown this window is drilled into, or nil when it is showing
--- the ordinary grid.
---
--- Detected by BuildRows answering non-nil rather than by a mode flag this file
--- would have to keep in step with modules/DrillDown.lua's own idea of what is
--- open. The rows are a plain table, so testing THEM is safe; the title beside
--- them may be a secret string — DrillDown formats the source's
--- ConditionalSecret name into it — so it is passed on as text and never tested.
---
--- @return table|nil rows, string|nil title
local function drillRowsFor(config)
    local DrillDown = mod("DrillDown")
    if DrillDown and DrillDown.BuildRows then
        return DrillDown:BuildRows(config)
    end
    return nil, nil
end

--- The ordered rows the aggregator answers for this window.
---
--- ONE PATH. There is no test branch here any more. Test mode used to hand the
--- renderer a whole separate result table built by a separate function, which
--- made the two modes diverge at every seam nobody thought to duplicate:
--- tooltips found no source, the drill-down opened on nothing, and every fix had
--- to be applied twice. It now substitutes the DATA, at modules/Provider.lua and
--- modules/Roster.lua — the two files that talk to the client — so everything
--- from here down is the live code reading invented numbers.
---
--- Called in the DOT form for the same reason meterAvailability is.
local function aggregateEntries(Aggregator, config)
    if Aggregator.Build then return Aggregator.Build(config) end
    return nil
end

--- Whether the window draws placeholder data.
---
--- ONE DOOR: `/mm test`, or the General page's checkbox, both of which write
--- NS.State.testMode.
---
--- An unlocked window used to imply this, and that coupling was the first bug
--- reported against the addon: a fresh install ships unlocked, so the very first
--- login showed placeholder rows and no amount of unchecking "Preview mode"
--- would clear them — the lock was still forcing it back on. The lock now governs
--- dragging and nothing else.
function WindowProto:IsTest()
    return (NS.State and NS.State.testMode) and true or false
end

--- Draw the window.
---
--- The order matters. Availability is asked FIRST, because a client with the
--- meter switched off has nothing for any of the rest of this to do; then a
--- drill-down replaces the grid entirely if one is open; then the data comes
--- from the aggregator, in preview form when the window is unlocked or preview
--- mode is on; then the rows are drawn.
function WindowProto:Refresh()
    if not (self.frame and self.frame:IsShown()) then return end
    -- A COLLAPSED WINDOW HAS NOWHERE TO DRAW. ShouldPoll's clause covers the
    -- polling half of the tick and nothing else: onUpdate takes an early branch
    -- on `dirty`, and every meter message sets that flag, so without this the
    -- whole aggregate-and-render ran for a hidden body through an entire fight.
    -- It also stops ShowNotice putting the "waiting for combat data" line back
    -- over a window that has been collapsed.
    if (self.config.frame or {}).minimised then return end

    local t0 = Perf.on and debugprofilestop()

    local available, reason = meterAvailability()
    if not available then
        self:ShowNotice(reason)
        if t0 then Perf.Note("refresh", debugprofilestop() - t0) end
        return
    end

    -- No aggregator is a BROKEN INSTALL, not a switched-off meter, so it draws
    -- nothing rather than telling the player to enable something that is already
    -- on. The chat printer has already said the addon is half-loaded.
    local Aggregator = mod("Aggregator")
    if not Aggregator then
        self:HideAll()
        if t0 then Perf.Note("refresh", debugprofilestop() - t0) end
        return
    end

    -- A PINNED SEGMENT THAT NO LONGER EXISTS IS DROPPED HERE, before anything
    -- reads it. sessionID is persisted, so a window can come back from a reload,
    -- a meter reset or a zone change still pointed at a segment the client has
    -- discarded — and a stale id does not error, it silently reads an empty
    -- session, which looks exactly like a broken addon.
    --
    -- Cleared in the CONFIG rather than shadowed on the instance so there is one
    -- resolved answer: modules/Aggregator.lua, the tooltip and the drill-down all
    -- read `data.sessionID` directly, and a session id is never reused, so
    -- forgetting one loses nothing that could come back.
    self:DropStaleSegment()

    -- A window that is drilled into a player's spell breakdown draws THAT
    -- instead of the grid, so it is asked before the aggregator is. The "is this
    -- a breakdown" answer travels on as its own boolean and the title travels
    -- beside it as text only — a secret string may be drawn, never truth-tested.
    local drillRows, title = drillRowsFor(self.config)
    if drillRows then
        self:Render(drillRows, false, true, title)
        if t0 then Perf.Note("refresh", debugprofilestop() - t0) end
        return
    end

    local preview = self:IsTest()
    self:Render(aggregateEntries(Aggregator, self.config), preview)

    if t0 then Perf.Note("refresh", debugprofilestop() - t0) end
end

--- Put the aggregator's answer on screen.
---
--- The percent text slot used to cost a second full session read per column per
--- refresh: this file asked Provider.GetColumn for every column's group total so
--- the cells could divide by it. modules/Aggregator.lua already holds both
--- operands and already divides — `cell.percent` — so the row path reads that
--- and the extra read is gone.
---
--- @param entries table|nil  the ordered array of rows to draw
--- @param preview boolean
--- @param isDrill boolean|nil  true when these rows are a spell breakdown. A
---   PLAIN boolean, deliberately separate from the title: `drillTitle` can be a
---   secret string and must never be branched on.
--- @param drillTitle string|nil  the breakdown's header line, text only
function WindowProto:Render(entries, preview, isDrill, drillTitle)
    local t0 = Perf.on and debugprofilestop()

    self.notice:Hide()
    self:HideAll()

    local layout = self.layout
    entries = entries or {}

    -- The back button belongs to modules/DrillDown.lua and is anchored into this
    -- window's body at a config-derived offset — nothing measures it, and
    -- nothing measures the body it lands in (rule R3).
    local DrillDown = mod("DrillDown")
    -- NO BACK BUTTON. It used to be acquired here and every drill row shifted
    -- down by its height — which is what pushed the last row out through the
    -- bottom of the frame, since `layout.maxRows` is derived from the body
    -- height and knew nothing about a button drawn inside it. Right-click on any
    -- row leaves a breakdown now (modules/Row.lua), so the height is the rows'
    -- again and the overflow cannot recur.
    if DrillDown and DrillDown.ReleaseBackButton then
        DrillDown:ReleaseBackButton(self.config)
    end

    -- See the note where this script was installed: the body claims the mouse
    -- only while a breakdown is open, so the grid's hover behaviour is untouched.
    self.body:EnableMouse(isDrill and true or false)

    -- THE CLAMP LIVES HERE, and only here. `ScrollBy` applies the floor; this
    -- applies the ceiling, against the list actually being drawn rather than
    -- against a remembered count that a group change would have made stale.
    --
    -- Re-clamping every draw is what covers the list shrinking under a
    -- stationary offset, which happens constantly — a player leaves the group, a
    -- breakdown has fewer spells than the grid had rows — and an offset past the
    -- end would render an empty window that scrolling could not fix.
    local offset = self.scrollOffset or 0
    local maxOffset = self:MaxScroll(#entries)
    if offset > maxOffset then offset = maxOffset end
    if offset < 0 then offset = 0 end
    self.scrollOffset = offset

    local drawn = 0
    for i = 1 + offset, #entries do
        if drawn >= layout.maxRows then break end
        local entry = entries[i]
        if entry then
            drawn = drawn + 1
            local row = self:Acquire()
            local y = NS.Row.OffsetFor(layout, drawn)
            row.frame:ClearAllPoints()
            if layout.growUp then
                row.frame:SetPoint("BOTTOMLEFT", self.body, "BOTTOMLEFT", 0, y)
            else
                row.frame:SetPoint("TOPLEFT", self.body, "TOPLEFT", 0, -y)
            end
            row:Update(entry, drawn)
        end
    end

    -- An empty grid with no explanation reads as a broken addon. The meter is
    -- available (Refresh established that above), there is simply nothing in the
    -- session yet — which is the normal state between pulls.
    if drawn == 0 and not preview and not isDrill then
        self.notice:SetText(NS.GRAY .. L["Waiting for combat data..."] .. "|r")
        self.notice:Show()
    end

    -- Park the aggregate on the window so UpdateHeaderText can read the group
    -- total off it. The aggregator already computed the sort column's total
    -- during the pass it just made; re-entering Provider.GetColumn for the same
    -- number would be a second full session read per refresh, on the hot path.
    self.aggregate = entries

    self:UpdateHeaderText(preview, isDrill, drillTitle)

    -- ONE debug line per pass, built inside the gate. A line per row would be
    -- forty allocations a quarter second on a raid, all of them discarded by a
    -- disabled sink (debug-logging-§4).
    if NS.State and NS.State.debug then
        -- Keyed on the window id: two windows sharing the `Render` tag would
        -- otherwise alternate and defeat each other's comparison, so neither
        -- would ever be suppressed and the fix would silently do nothing.
        NS.DebugSteady(self.id, "Render", "window %d drew %d/%d rows%s",
            self.id, drawn, #entries, preview and " (preview)" or "")
    end

    if t0 then Perf.Note("render", debugprofilestop() - t0) end
end

-- ---------------------------------------------------------------------------
-- Sorting from the column headers
-- ---------------------------------------------------------------------------

--- Sort this window by `key`, or reverse it if it is already the sort column.
---
--- REFUSES WHILE THE COMBAT RESTRICTION IS ACTIVE, and says so. Ordering by value
--- means comparing meter values, which raises while they are secret — the
--- aggregator already declines to re-sort mid-pull and holds the frozen order
--- (rule R2). Without a message the click would simply do nothing, which reads as
--- a broken button rather than as a rule.
---
--- The name column sorts by `roster` — group order — because "sort by name" over
--- a `ConditionalSecret` name is a string comparison on a value we may not read.
--- Group order is the stable, always-legal thing a player actually means when
--- they click the Player header.
---
--- @param key string  a stat key, or "name"
--- @return boolean  whether the sort changed
function WindowProto:SortByColumn(key)
    if key == nil then return false end

    local data = self.config.data
    if not data then return false end

    -- ONE HEADER IS REFUSED WHILE THE RESTRICTION IS ACTIVE, AND ONLY ONE.
    --
    -- This used to refuse EVERY header, which is where "sorting does nothing in
    -- combat" came from. It was too wide by two whole operations:
    --
    --   * Picking a different STAT column compares nothing. modules/Aggregator.lua
    --     builds the entire mid-pull row list out of `sortColumn`'s own
    --     combatSources, so changing which column that is re-ranks the grid by
    --     the engine's own ordering for the new stat.
    --   * Reversing compares nothing either — it is a permutation of an array
    --     this addon built, and the aggregator applies it without touching a
    --     value (see reverseRows there).
    --
    -- The Player column is the genuine refusal. Ordering by name compares a
    -- ConditionalSecret, which raises, and unlike a stat column there is no
    -- engine ranking standing behind it — `name` mode mid-pull would draw the
    -- damage order under an arrow pointing at the Player header. Without a
    -- message the click would simply do nothing, which reads as a broken button
    -- rather than as a rule.
    if key == "name" and NS.Secrets and NS.Secrets.IsRestricted() then
        if NS.Print then
            NS.Print(L["Sorting is not possible while the game restricts combat data."])
        end
        return false
    end

    -- THE PLAYER COLUMN SORTS BY PLAYER. It used to toggle between `roster` and
    -- `value`, which is a reasonable thing for some header to do and not what a
    -- header labelled "Player" says. Ascending first, because A-Z is what a
    -- player means by "sort by name"; clicking again reverses it, exactly like a
    -- stat column.
    if key == "name" then
        if data.sortMode == "name" then
            data.sortAscending = not data.sortAscending
        else
            data.sortMode      = "name"
            data.sortAscending = true
        end
        self:ApplyColumnHeaders()
        self:MarkDirty()
        return true
    end

    if data.sortColumn == key and data.sortMode == "value" then
        data.sortAscending = not data.sortAscending
    else
        data.sortColumn    = key
        data.sortMode      = "value"
        data.sortAscending = false
    end

    -- The frozen order is a snapshot of the OLD sort and would be reapplied over
    -- the new one for the rest of the pull. Dropping it is what makes the click
    -- take effect rather than appear to.
    if NS.State and NS.State.WipeCache then NS.State.WipeCache("Aggregator") end

    self:ApplyColumnHeaders()
    self:MarkDirty()
    return true
end

-- ---------------------------------------------------------------------------
-- The segment selector
-- ---------------------------------------------------------------------------
--
-- `data.sessionType` picks Current or Overall. `data.sessionID`, when set,
-- overrides it with one specific stored segment — the fight the player picked
-- out of the header dropdown. Nil means "no segment pinned", which is the
-- default and the behavior the addon had before this existed.

--- One stored session's entry, as menu text: its name, then its duration.
---
--- Both pieces come off the API and BOTH MAY BE SECRET, so the two rules that
--- shape every other display string apply here too: joined with `..` and never
--- with table.concat, and the name goes through the concat probe before
--- tostring. A menu label is drawn and nothing else is ever asked of it.
---
--- @param entry table  { sessionID, name, durationSeconds }
--- @return string
local function segmentLabel(entry)
    local name = entry.name
    if name == nil then
        name = L["Segment"]
    elseif NS.IsConcatSafe and NS.IsConcatSafe(name) then
        name = tostring(name)
    else
        name = NS.SafeToString and NS.SafeToString(name) or L["Segment"]
    end

    local F = NS.Format
    if type(F) ~= "table" or not F.Duration then F = NS.NumberFormat end
    if entry.durationSeconds == nil or not (F and F.Duration) then return name end

    local ok, out = pcall(function() return name .. "   " .. F.Duration(entry.durationSeconds) end)
    return ok and out or name
end

--- Forget a pinned segment the client no longer holds. See Refresh.
function WindowProto:DropStaleSegment()
    local data = self.config.data
    if not (data and data.sessionID ~= nil) then return end

    local Provider = mod("Provider")
    -- No provider at all is a broken install, not a stale segment: leaving the
    -- pin alone means it still works once the module is there, and dropping it
    -- would quietly rewrite the player's setting because of our own load order.
    if not (Provider and Provider.HasSession) then return end

    if not Provider.HasSession(data.sessionID) then
        if NS.State and NS.State.debug then
            NS.Debug("Window", "window %d dropped stale segment %s",
                self.id, tostring(data.sessionID))
        end
        data.sessionID = nil
    end
end

--- Point this window at one stored segment, or at nil for "follow sessionType".
--- @param sessionID number|nil
function WindowProto:SetSegment(sessionID)
    local data = self.config.data
    if not data then return end
    if data.sessionID == sessionID then return end
    data.sessionID = sessionID
    self:MarkDirty()
end

--- Point this window at Current or Overall, clearing any pinned segment.
---
--- Clearing is the point: picking "Current" out of a menu that is showing a
--- stored fight means "stop showing that fight", and leaving the id set would
--- make the choice do nothing at all.
--- @param sessionType number
function WindowProto:SetSessionType(sessionType)
    local data = self.config.data
    if not data then return end
    data.sessionType = sessionType
    data.sessionID   = nil
    self.sessionType = sessionType
    self:MarkDirty()
end

--- Open the header's segment dropdown.
---
--- Stored segments first, newest first as the API returns them, then a divider,
--- then the two synthetic entries. That order matches what the player is
--- reaching for: the reason to open this menu at all is almost always to look
--- back at a fight that just ended.
function WindowProto:OpenSegmentMenu()
    local Provider = mod("Provider")
    if not (Provider and Provider.GetAvailableSessions) then return false end

    local sessions = Provider.GetAvailableSessions()
    local data = self.config.data or {}

    return NS.Compat.OpenContextMenu(self.sessionLine, function(_, root)
        root:CreateTitle(L["Segment"])

        for _, entry in ipairs(sessions) do
            if type(entry) == "table" and entry.sessionID ~= nil then
                local id = entry.sessionID
                root:CreateButton(segmentLabel(entry), function()
                    self:SetSegment(id)
                end)
            end
        end

        root:CreateDivider()
        root:CreateButton(L["Current"], function()
            self:SetSessionType(Const.SESSION_TYPE.Current)
        end)
        root:CreateButton(L["Overall"], function()
            self:SetSessionType(Const.SESSION_TYPE.Overall)
        end)
        -- `data` is captured so a future radio-style menu can mark the active
        -- entry; MenuUtil's CreateRadio needs an is-selected predicate and this
        -- is the state it would ask about.
        return data
    end)
end

--- Which session the header names — or nil when it names none.
---
--- The name comes from the window's own setting rather than from the data: the
--- aggregator returns rows, and asking it to name the session would make it read
--- a field it has no other use for.
---
--- @param preview boolean
--- @return string|nil
function WindowProto:SessionLabel(preview)
    if preview then return L["Test"] end
    if not (self.config.header or {}).showSessionName then return nil end

    -- A PINNED SEGMENT NAMES ITSELF. Saying "Current" over a window that is
    -- showing a fight from ten minutes ago is the one label that is actively
    -- misleading, and it is also the only feedback the player gets that their
    -- click landed.
    local sessionID = (self.config.data or {}).sessionID
    if sessionID ~= nil then
        local Provider = mod("Provider")
        for _, entry in ipairs(Provider and Provider.GetAvailableSessions() or {}) do
            if type(entry) == "table" and entry.sessionID == sessionID then
                return segmentLabel(entry)
            end
        end
        -- Pinned but not in the list: Refresh's staleness check has not run yet
        -- this pass. Say so rather than falling through to a label that claims a
        -- session this window is not reading.
        return L["Segment"]
    end

    return (self.sessionType == Const.SESSION_TYPE.Overall)
        and L["Overall"] or L["Current"]
end

--- How long the session has run, formatted — or nil when there is no duration to
--- show.
---
--- Emptiness is decided from the PLAIN INPUT, not from the output.
--- Format.Duration answers "" for a nil and something non-empty for anything
--- else, so `seconds ~= nil` is the same question — asked of a value this file is
--- allowed to test, where the formatted string is a secret that may be neither
--- truth-tested nor compared to "".
---
--- @param F table|nil  the resolved number formatter
--- @return string|nil
function WindowProto:DurationText(F)
    local header = self.config.header or {}
    local Provider = mod("Provider")
    if not (header.showDuration and Provider and Provider.GetSessionDuration
        and F and F.Duration) then
        return nil
    end
    local seconds = Provider.GetSessionDuration(self.sessionType,
        (self.config.data or {}).sessionID)
    if seconds == nil then return nil end
    return F.Duration(seconds)
end

--- The group total for the sort column, formatted — or nil when the header does
--- not show totals.
---
--- Taken from the aggregate the render pass just parked on the window rather than
--- from a fresh provider read. `sortTotal` is an opaque value like any other: it
--- is handed straight to the native formatter and never inspected.
---
--- @param F table|nil  the resolved number formatter
--- @return string|nil
function WindowProto:SortTotalText(F)
    local header = self.config.header or {}
    if not (header.showTotals and F and F.Number) then return nil end
    local total = self.aggregate and self.aggregate.sortTotal
    if total == nil then return nil end
    return F.Number(total, (self.config.text or {}).numberFormat)
end

--- The note that this grid was built the restricted way, or nil when it was not.
---
--- REPLACES THE FROZEN-SORT NOTICE, which said the rows had stopped reordering.
--- They have not: `sourceGUID` is secret for the whole of a pull, so the rows are
--- the engine's own ranking of the sort column and they re-rank live. What the
--- player is owed instead is why a CELL can be empty — the other columns are
--- matched to those rows by class and spec, and a pair that cannot be told apart
--- has its cells left blank rather than guessed at.
---
--- Read off the aggregate the render pass parked here rather than from the
--- restriction state directly, so the line describes the grid actually on screen
--- rather than the state at the moment the header was drawn.
---
--- @param preview boolean
--- @return string|nil
function WindowProto:RestrictedNotice(preview)
    if preview then return nil end
    local aggregate = self.aggregate
    if not (aggregate and aggregate.identityMode) then return nil end
    if aggregate.ambiguous then
        return NS.GRAY .. L["restricted \226\128\148 some rows cannot be told apart"] .. "|r"
    end
    return NS.GRAY .. L["restricted"] .. "|r"
end

--- The header's right-hand line: which session, how long it has run, and the
--- group total for the sort column.
---
--- Both the duration and the total are OPAQUE handles like every other number
--- here. The duration goes to NS.Format.Duration and the total to
--- NS.Format.Number — neither is divided, floored or compared in this file,
--- which is why "1:23" is legal mid-pull at all: the formatter does the
--- arithmetic natively (design §4).
---
--- @param preview boolean
--- @param isDrill boolean|nil    a PLAIN boolean; see Render
--- @param drillTitle string|nil  "<player> - <stat>" while drilled in, and
---   possibly a SECRET string — it is written to the widget, never tested
function WindowProto:UpdateHeaderText(preview, isDrill, drillTitle)
    if not self.sessionText:IsShown() then return end

    -- A breakdown is about one player and one statistic, and saying so is worth
    -- more than the session line it replaces. `== nil` rather than `or ""`: the
    -- title is a formatted string and `or` would truth-test it.
    if isDrill then
        self.sessionText:SetText(drillTitle == nil and "" or drillTitle)
        return
    end

    local F = NS.Format
    if type(F) ~= "table" or not F.Number then F = NS.NumberFormat end

    -- FOLDED WITH `..`, NOT JOINED WITH table.concat.
    --
    -- Two of the pieces below come out of NS.Format having been built from a
    -- secret, and a formatted secret is itself secret. `..` is explicitly legal
    -- on one; table.concat is the single string operation that RAISES on one —
    -- it is literally the probe core/CoreSetup.lua uses to detect a secret at
    -- all. Joining this line was therefore a Lua error on the first refresh
    -- after the header showed a duration or a total, four times a second, for
    -- the whole of every pull.
    --
    -- Each piece answers nil when it has nothing to say, and `part == nil` is
    -- the only question asked about it: a piece that IS present may be a
    -- formatted secret, which may be concatenated but never truth-tested.
    local line
    local function add(part)
        if part == nil then return end
        if line == nil then line = part else line = line .. "  " .. part end
    end

    add(self:SessionLabel(preview))
    add(self:DurationText(F))
    add(self:SortTotalText(F))
    add(self:RestrictedNotice(preview))

    self.sessionText:SetText(line == nil and "" or line)
end

--- Replace the rows with Blizzard's own reason and what to do about it.
---
--- The failure reason comes from C_DamageMeter.IsDamageMeterAvailable and is
--- quoted rather than interpreted: the game knows why its meter is off, and
--- guessing on its behalf is how an addon tells a player to enable something
--- that was never the problem.
function WindowProto:ShowNotice(reason)
    self:HideAll()
    local lines = {
        L["Blizzard's damage meter is not available."],
        L["Multi Meters reads every number from the game's built-in damage meter. Enable it to see data here."],
    }
    if reason ~= nil and NS.IsConcatSafe and NS.IsConcatSafe(reason) then
        lines[#lines + 1] = NS.GRAY .. L["Reason: %s"]:format(tostring(reason)) .. "|r"
    end
    self.notice:SetText(table.concat(lines, "\n\n"))
    self.notice:Show()
end

-- ---------------------------------------------------------------------------
-- Show / hide
-- ---------------------------------------------------------------------------

--- Consult the ladder and act on it.
---
--- The decision is NS.ShouldShow's — one ordered function, with perf suspend as
--- step 0 — and it is refused AT THE SOURCE: a window that must not show never
--- reaches the aggregator at all, rather than building rows and hiding them
--- afterwards (performance-§6).
--- Re-run the show ladder, honoring an explicit request.
---
--- `forcedShow` IS WHY CHANGING A SETTING NO LONGER CLOSES THE WINDOW.
---
--- The ladder is consulted on every CONFIG_CHANGED, and a window that is on
--- screen because the player asked for it — `/mm toggle`, or leaving test mode —
--- is not on screen because the ladder said so. So the first unrelated settings
--- edit re-ran the ladder, got "no" from a context rule, and hid the window. From
--- the player's side that is "the settings panel closes my meter", which is both
--- baffling and, as an explanation, wrong.
---
--- An explicit request therefore STICKS until the context genuinely changes — a
--- zone change or a login, which is when a context rule has something new to say.
--- It is deliberately not permanent: the visibility rules exist to follow you
--- between a dungeon and a city, and a flag that outlived that would quietly
--- disable the whole page.
function WindowProto:RefreshVisibility()
    local show, reason = true, "shown"
    if NS.ShouldShow then show, reason = NS.ShouldShow(self.config) end

    if not show and self.forcedShow then
        show, reason = true, "requested"
    end

    if show then
        if not self.frame:IsShown() then
            self.frame:Show()
            self:MarkDirty()
            self.elapsed = self.throttle   -- draw on the next tick, not in 0.25s
        end
    else
        self:Hide(reason)
    end
    return show, reason
end

function WindowProto:Show()
    self:BuildFrame()
    -- An explicit request. See RefreshVisibility for why it is remembered.
    self.forcedShow = true
    self.frame:Show()
    self:MarkDirty()
end

--- Forget an explicit show request. Called on a real context change, which is
--- when the visibility rules have something new to say.
function WindowProto:ClearForcedShow()
    self.forcedShow = nil
end

function WindowProto:Hide(reason)
    if not self.frame then return end
    if self.frame:IsShown() and NS.State and NS.State.debug then
        NS.Debug("Window", "%d hidden (%s)", self.id, tostring(reason or "?"))
    end
    -- A DELIBERATE hide cancels a deliberate show. Closing the window with the X
    -- or with `/mm toggle` and having it reappear on the next settings edit would
    -- be the same bug pointed the other way.
    if reason == "closed" or reason == "toggled" then self.forcedShow = nil end
    self.frame:Hide()
    self:HideAll()
end

function WindowProto:IsShown()
    return self.frame and self.frame:IsShown() and true or false
end

-- ---------------------------------------------------------------------------
-- Bus wiring
-- ---------------------------------------------------------------------------
--
-- A PRIVATE target per window (NS.NewBusTarget), never the shared addon object.
-- Every handler does the same two things — invalidate what the message
-- invalidated, then set the dirty flag — because the throttle is the only thing
-- allowed to decide when work happens.

function WindowProto:RegisterBus()
    local bus = NS.NewBusTarget()
    self.bus = bus
    if not bus then return end

    local function dirty() self:MarkDirty() end

    bus:RegisterMessage(MSG.METER_UPDATED, dirty)
    bus:RegisterMessage(MSG.METER_SESSION, dirty)
    bus:RegisterMessage(MSG.METER_RESET, function()
        self:MarkDirty()
    end)
    bus:RegisterMessage(MSG.RESTRICTION_CHANGED, dirty)

    -- A roster change is both: the rows are stale AND the show answer may have
    -- moved, because `hideWhenSolo` is a roster fact. A window hidden by that
    -- rule has no OnUpdate running — a hidden frame's script does not fire — so
    -- the ladder has to be re-run from the message or the window can never come
    -- back when the player groups up.
    bus:RegisterMessage(MSG.ROSTER_CHANGED, function()
        self:RefreshVisibility()
        self:MarkDirty()
    end)

    -- Context messages change the SHOW answer, not the data, so they go through
    -- the ladder rather than through the dirty flag.
    -- A zone change is the one thing that makes an explicit "show this" stale:
    -- the context rules now have something new to say, which is their whole job.
    bus:RegisterMessage(MSG.ZONE_CHANGED, function()
        self:ClearForcedShow()
        self:RefreshVisibility()
    end)
    bus:RegisterMessage(MSG.ENTERING_WORLD, function()
        self:ClearForcedShow()
        self:RefreshVisibility()
    end)
    -- The player's own state. These are the SAME shape as the roster case above
    -- and they are here for the same reason: modules/Visibility.lua is a
    -- predicate that publishes nothing, so a rule it owns takes effect only when
    -- something re-runs the ladder — and there is no fallback, because onUpdate
    -- refreshes DATA and never re-asks NS.ShouldShow. Without these two
    -- subscriptions, "hide when skyriding" waits for the next zone change,
    -- group change or settings write, which is indistinguishable from not
    -- working. ClearForcedShow is deliberately NOT called: `/mm toggle` is an
    -- explicit request about THIS window, and mounting up is not a reason to
    -- forget it.
    bus:RegisterMessage(MSG.PLAYER_STATE_CHANGED, function()
        self:RefreshVisibility()
    end)
    bus:RegisterMessage(MSG.COMBAT_CHANGED, function()
        self:RefreshVisibility()
    end)
    bus:RegisterMessage(MSG.TEST_MODE_CHANGED, function()
        -- ApplyTitle as well as MarkDirty: the red TEST MODE marker lives in the
        -- title, and the title is only rewritten on a config change — so without
        -- this the marker appeared on the next settings edit rather than on the
        -- toggle that turned it on.
        self:ApplyTitle()
        self:RefreshVisibility()
        self:MarkDirty()
    end)

    -- Entering or leaving a drill-down changes what this window draws entirely.
    -- The name comes from the bus catalog and from nowhere else: a hand-spelled
    -- fallback beside it is a second definition of the same string, and the day
    -- the catalog's value changes the sender moves and the listener does not
    -- (architecture-§4).
    bus:RegisterMessage(MSG.DRILLDOWN_CHANGED,
        function(_, payload)
            local id = payload and payload.windowId
            if id ~= nil and id ~= self.id then return end
            -- The list is about to become a different list. An offset carried
            -- from the grid into a breakdown points into rows that are not there.
            self:ResetScroll()
            self:MarkDirty()
            self.elapsed = self.throttle   -- a click must not wait a full tick
        end)

    -- A settings write. The payload names a window id when the change was
    -- window-relative, so a twenty-window profile does not re-apply nineteen
    -- windows because one of them was edited.
    bus:RegisterMessage(MSG.CONFIG_CHANGED, function(_, payload)
        local id = payload and payload.windowId
        if id ~= nil and id ~= self.id then return end
        self:ApplyConfig()
        self:RefreshVisibility()
        self:MarkDirty()
    end)
end

function WindowProto:UnregisterBus()
    if self.bus and self.bus.UnregisterAllMessages then
        self.bus:UnregisterAllMessages()
    end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- Build one window instance around a stored config.
---
--- @param config table  a window config from db.profile.windows
--- @return table
function Window.New(config)
    local inst = setmetatable({
        id     = config.id,
        config = config,
        pool   = { all = {}, active = {}, free = {} },
        dirty  = true,
        elapsed = 0,
    }, WindowProto)

    inst:ApplyConfig()
    inst:RegisterBus()
    inst.frame:SetScript("OnUpdate", onUpdate)
    inst:RefreshVisibility()

    return inst
end

--- Point an existing instance at a (possibly rewritten) config table and
--- re-apply everything. Used by the manager after a copy or a rename, so a
--- window is never torn down and rebuilt for a settings change.
function WindowProto:SetConfig(config)
    self.config = config
    self.id = config.id
    self:ApplyConfig()
    self:RefreshVisibility()
    self:MarkDirty()
end

--- Take the window off screen and off the bus for good. The frames survive —
--- WoW never frees one — but nothing references them and nothing drives them.
function WindowProto:Destroy()
    self:UnregisterBus()
    if self.frame then
        self.frame:SetScript("OnUpdate", nil)
        self.frame:Hide()
    end
    self:HideAll()
end

--- Stop doing work without changing what the user configured (performance-§6).
--- The OnUpdate goes, which is what stops the coalesced pass already queued from
--- firing once more inside a measurement window and being attributed to an addon
--- that is supposed to be idle. Bus registrations stay: Resume republishes, and
--- a window that had torn them down would never hear it.
function WindowProto:Suspend()
    if self.frame then self.frame:SetScript("OnUpdate", nil) end
end

function WindowProto:Resume()
    if self.frame then self.frame:SetScript("OnUpdate", onUpdate) end
    self:RefreshVisibility()
    self:MarkDirty()
end
