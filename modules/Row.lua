-- modules/Row.lua
--
-- One row of the grid, and the cells inside it. A row is a plain Frame; a cell
-- is a StatusBar with two FontStrings on it and, in the name column, up to three
-- icons. Nothing here talks to C_DamageMeter, and nothing here decides WHICH
-- rows exist — modules/Aggregator.lua answers that and modules/Window.lua owns
-- the pool. This file only draws what it is handed.
--
-- ---------------------------------------------------------------------------
-- WHY THIS FILE NEVER LOOKS AT A NUMBER
-- ---------------------------------------------------------------------------
--
-- Every meter figure that reaches SetTotal / SetRate below is an OPAQUE HANDLE.
-- While Blizzard's Combat addon restriction is active those values are secret:
-- tainted code may store them, pass them along, hand them to a widget setter and
-- hand them to a native formatter, and may do NOTHING else — no arithmetic, no
-- comparison, no `#`, no use as a table key, no indexing (design §4, rule R1).
--
-- So the code below is written as if it did not know what a number is:
--
--   * `bar:SetValue(v)` and `bar:SetMinMaxValues(0, max)` take the handle raw.
--   * the text goes through modules/Format.lua, which owns the
--     NumericRuleFormatter instances — the only legal way to turn 12400000 into
--     "12.4M", because the division happens natively rather than in Lua.
--   * the only test applied to a value is `== nil`, which is legal on a
--     non-boolean secret and is how "this player has no dispels" is told apart
--     from "this player dispelled a secret number of times".
--
-- The consequence, and the reason rule R3 exists: a StatusBar that has been
-- handed a secret is marked HasSecretValues, and its POSITION data becomes
-- secret too, propagating to anything anchored to it. Hence every SetPoint below
-- is computed from the window's config — plain numbers this addon owns — and
-- there is not one GetWidth / GetHeight / GetLeft / GetPoint call in this file.
-- The layout table modules/Window.lua hands in is the whole geometry story.
--
-- ---------------------------------------------------------------------------
-- THE CELL DESCRIPTOR (the contract with Tooltip and DrillDown)
-- ---------------------------------------------------------------------------
--
-- Every cell carries the fields below, and modules/Tooltip.lua and
-- modules/DrillDown.lua are handed the cell itself rather than six loose
-- arguments, so a new field never means a new signature:
--
--   cell.frame     the StatusBar (also the mouse target)
--   cell.key       the stat key, or "name" for the leading column
--   cell.stat      the core/Constants.lua STATS row, nil for the name column
--   cell.window    the owning window instance (cell.window.config is its config)
--   cell.row       the owning row object (cell.row.entry is the current player)
--   cell.entry     the aggregator entry currently drawn here, nil when empty
--
-- Those two modules are resolved at CALL time, never captured at load: the TOC
-- loads this file before either of them, and a load-time upvalue would freeze a
-- nil in and silently kill every tooltip in the addon.

local addonName, NS = ...

-- Perf bracket upvalue (performance-§2): resolved ONCE at load, never through an
-- NS lookup on the hot path. core/PerfSetup.lua loads before modules/, so this
-- is always either the live harness or its stub, and `Perf.on` is false when no
-- capture is running — which is what makes the bracket free.
local Perf = NS.Perf

local Const = NS.Constants

-- Used for exactly one question: may this GUID be looked at. A source GUID off
-- the meter is never secret, but a row can also carry one the roster read off
-- the unit API, and those can be (modules/Roster.lua's header).
local Secrets = NS.Secrets

-- The debug pass. Row.lua is a render path, so both are load-time upvalues and
-- every call site stays behind `if State.debug`.
local State = NS.State
local Debug = NS.Debug

local Row = {}
NS.Row = Row

-- ---------------------------------------------------------------------------
-- Resolved-at-call-time collaborators
-- ---------------------------------------------------------------------------
--
-- modules/Format.lua, modules/Tooltip.lua and modules/DrillDown.lua all load
-- AFTER this file. Each is reached through a small resolver rather than an
-- upvalue so that load order cannot freeze a nil, and so that a partial install
-- degrades to "no text" / "no tooltip" instead of erroring on every refresh.

--- The number formatter (modules/Format.lua).
---
--- Deliberately shape-agnostic. `NS.Format` is a CALLABLE TABLE: indexing it
--- reaches the number formatter, calling it reaches LibKa0s's chat printer,
--- because both wanted the same name. This asks for the SHAPE it needs — a table
--- answering `.Number` — and falls back to `NS.NumberFormat`, the second name
--- modules/Format.lua publishes itself under for exactly this reason.
local function formatter()
    local f = NS.Format
    if type(f) == "table" and f.Number then return f end
    f = NS.NumberFormat
    if type(f) == "table" and f.Number then return f end
    return nil
end

--- Render one meter value as text.
---
--- `NS.SafeToString` is the degradation, not `tostring`: a secret value survives
--- tostring() and the `..` operator and raises only inside table.concat, so the
--- naive fallback would put a Lua error on a coalesced refresh ticker rather
--- than a string in a FontString (core/CoreSetup.lua).
---
--- @param value any     an opaque meter handle, or nil
--- @param kind string    "total" | "rate"
--- @param mode string    the window's text.numberFormat
--- @return string
local function renderValue(value, kind, mode)
    if value == nil then return "" end
    local F = formatter()
    if F then
        if kind == "rate" and F.Rate then return F.Rate(value, mode) or "" end
        if F.Number then return F.Number(value, mode) or "" end
    end
    return NS.SafeToString and NS.SafeToString(value) or ""
end

--- Read one player's figure for one column, out of EITHER row shape the addon
--- produces.
---
--- modules/Aggregator.lua emits `row.cells[key] = { value, rate, maxAmount }`;
--- modules/DrillDown.lua emits `row.values[key] = { total, rate }` with the max
--- on the row. Both are legitimate — one is a player's column, the other a
--- spell's — and the render path is supposed to have no branch in it, so the
--- branch lives HERE, once, instead of in every call site.
---
--- The nil tests are the only inspection performed. `c.value or c.total` would
--- be a truth test on a secret, which raises; `== nil` on a non-boolean secret
--- is explicitly permitted (design §4).
---
--- `displayText` is the fifth return and the odd one out: a string this addon
--- COMPOSED, not a figure the meter reported. A death row's cell shows the
--- wall-clock time the player died (modules/DrillDown.lua), which no number
--- formatter can produce from a value. It is read here so the two row shapes
--- stay resolved in one place, exactly like the four figures beside it.
---
--- @return any total, any rate, any maxAmount, number|nil percent, string|nil displayText
local function cellFigures(entry, key)
    local source = entry.cells or entry.values
    local c = source and source[key]
    if c == nil then return nil, nil, nil, nil, nil end

    local total = c.value
    if total == nil then total = c.total end

    local max = c.maxAmount
    if max == nil then max = entry.maxAmount end

    return total, c.rate, max, c.percent, c.displayText
end

--- Render a share-of-the-group figure.
---
--- The SHARE IS ALREADY COMPUTED. modules/Aggregator.lua holds both the cell's
--- value and its column's total in one place and divides there, once per cell
--- per pass; this file used to ask modules/Window.lua for the column total
--- instead, which meant a second full Provider.GetColumn read per column per
--- refresh to re-derive a number the aggregator had already put on the cell.
---
--- `percent` is a PLAIN number or nil — the aggregator only produces it when the
--- division was legal, and nil is "cannot be known right now", which is most of
--- a pull. So percent is the one text slot that cannot survive combat, and an
--- empty slot is honest: a player who wants numbers that keep moving picks
--- another slot (modules/Format.lua).
---
--- @param percent number|nil  a percentage, already divided
--- @param mode string         the window's text.numberFormat
--- @return string
local function renderPercent(percent, mode)
    if percent == nil then return "" end
    local F = formatter()
    if F and F.Percent then return F.Percent(percent, mode) or "" end
    return ""
end

-- ---------------------------------------------------------------------------
-- Color
-- ---------------------------------------------------------------------------

-- LibKa0s-Core-1.0's RGBA reads BOTH shapes the collection persists colors in —
-- keyed `{ r =, g =, b =, a = }` and positional `{ r, g, b, a }`.
--
-- Taken from the CORE SEAM (core/CoreSetup.lua publishes NS.RGBA) rather than
-- from a second LibStub lookup with its own copied channel reader. Two files
-- each carrying "the same" four lines is the duplicate that drifts the first
-- time the library learns a third shape; the seam is the one place that knows.
-- Resolved defensively because a degraded install may have no seam at all, and a
-- window drawn in the caller's DEFAULT colors beats a window that raises.
local RGBA = NS.RGBA or function(_, dr, dg, db, da)
    return dr, dg, db, da
end

-- One color per stat for `bars.colorMode == "stat"`, so a glance at a wide
-- window tells you which column you are reading without tracing back up to the
-- header. Keyed by the catalog's stat key (core/Constants.lua), and deliberately
-- muted: these sit behind white text all day.
local STAT_COLORS = {
    DamageDone           = { 0.78, 0.25, 0.25 },
    HealingDone          = { 0.25, 0.70, 0.35 },
    Absorbs              = { 0.45, 0.65, 0.80 },
    Interrupts           = { 0.85, 0.65, 0.20 },
    Dispels              = { 0.55, 0.45, 0.80 },
    DamageTaken          = { 0.65, 0.35, 0.20 },
    AvoidableDamageTaken = { 0.80, 0.45, 0.15 },
    Deaths               = { 0.55, 0.55, 0.55 },
    EnemyDamageTaken     = { 0.60, 0.30, 0.45 },
}

local ROLE_COLORS = {
    TANK    = { 0.30, 0.50, 0.85 },
    HEALER  = { 0.25, 0.70, 0.35 },
    DAMAGER = { 0.78, 0.25, 0.25 },
}

-- The role atlas is deliberately gone with the role icon. Three roles across a
-- whole raid identifies nobody, and it was the icon most likely to be on screen
-- when the name column ran out of room — see drawUnitIcon's ladder.
local CLASS_TEXTURE = [[Interface\TargetingFrame\UI-Classes-Circles]]

--- The bar color for one cell, per the window's `bars.colorMode`.
---
--- `classFilename` is NeverSecret, which is what makes "class" the default and
--- what makes it keep working at the height of a pull when every number on the
--- row is opaque (design §4).
local function barColor(bars, entry, statKey)
    local mode = bars and bars.colorMode or "class"

    if mode == "class" then
        local classes = _G.RAID_CLASS_COLORS
        local c = classes and entry.classFilename and classes[entry.classFilename]
        if c then return c.r, c.g, c.b end
    elseif mode == "role" then
        local c = ROLE_COLORS[entry.role or ""]
        if c then return c[1], c[2], c[3] end
    elseif mode == "stat" then
        local c = STAT_COLORS[statKey or ""]
        if c then return c[1], c[2], c[3] end
    elseif mode == "custom" then
        -- `bars.customColor` is the setting; the literal is the LAST-RESORT
        -- fallback for a profile written before the key existed, not the color
        -- this mode renders. Its authoritative default lives beside every other
        -- one in defaults/Profile.lua.
        --
        -- Three returns, not RGBA's four: every caller destructures three, and
        -- letting the alpha leak out of one branch and not the other three is
        -- how a fourth value ends up silently passed to SetStatusBarColor.
        local r, g, b = RGBA(bars.customColor, 0.35, 0.55, 0.85, 1)
        return r, g, b
    end

    -- Every mode falls back to the same neutral rather than to its own, so an
    -- unknown class or an unassigned role reads as "no color information"
    -- instead of as a fourth palette.
    return 0.45, 0.45, 0.5
end

--- The BACKGROUND color for one cell, per `bars.bgColorMode`.
---
--- THIS IS THE ROW TINT. It was briefly a texture on the row itself, which tinted
--- the two-pixel seams between columns along with the cells and lost the column
--- separators the grid is read by. Painting the CELLS instead leaves those seams
--- untouched, so the separators come back for free and the tint lands exactly
--- where the numbers are.
---
--- Defaults to the class color at 0.1 — a tint, not a second bar. `classFilename`
--- is NeverSecret, so it keeps working at the height of a pull when every number
--- on the row is opaque.
---
--- @return number r, number g, number b, number a
local function cellBackground(bars, entry, statKey)
    local mode  = bars and bars.bgColorMode or "class"
    local alpha = bars and bars.bgAlpha or 0.1

    if mode == "none" then return 0, 0, 0, 0 end

    if mode == "custom" then
        local r, g, b = RGBA(bars and bars.bgColor, 0, 0, 0, 1)
        return r, g, b, alpha
    end

    -- `class` and `stat` share barColor's palettes rather than restating them:
    -- one color vocabulary for the bar and its background is what keeps a window
    -- looking like one object.
    local r, g, b = barColor({ colorMode = mode, customColor = bars and bars.bgColor },
        entry, statKey)
    return r, g, b, alpha
end

-- ---------------------------------------------------------------------------
-- Media
-- ---------------------------------------------------------------------------

local function lsm()
    return LibStub and LibStub("LibSharedMedia-3.0", true)
end

local function fontPath(name)
    local media = lsm()
    local path = media and name and media:Fetch("font", name, true)
    return path or Const.FONT_MONO or _G.STANDARD_TEXT_FONT
end

local function barTexture(name)
    local media = lsm()
    local path = media and name and media:Fetch("statusbar", name, true)
    return path or [[Interface\TargetingFrame\UI-StatusBar]]
end

-- ---------------------------------------------------------------------------
-- Mouse hand-off
-- ---------------------------------------------------------------------------
--
-- The three handlers below are the addon's ONLY route into modules/Tooltip.lua
-- and modules/DrillDown.lua. Each resolves its collaborator at call time and
-- does nothing at all when it is absent, so a window keeps drawing on a partial
-- install rather than erroring under the cursor.

local function cellOnEnter(frame)
    local cell = frame.mmCell
    if not cell then return end
    if cell.row then cell.row:SetMouseOver(true) end

    local entry = cell.entry
    local T = NS.Tooltip
    if not (T and entry) then return end

    local config = cell.window.config

    -- A BREAKDOWN ROW IS A SPELL, and the ROW owns its tooltip — see rowOnEnter.
    -- The cell does not show it and does not hide it, which is what stops the
    -- blink at every cell boundary.
    if entry.isDrillDown then return end

    -- Hovering the NAME cell summarizes every enabled stat for that player,
    -- which is the cross-column read the whole addon exists for; hovering any
    -- other cell asks the narrower question the column is about.
    local wantSummary = (config.tooltip or {}).showAllStatsOnName ~= false
    if cell.key == "name" and wantSummary and T.NameTooltip then
        T:NameTooltip(entry, frame, config)
    elseif cell.key ~= "name" and T.CellTooltip then
        T:CellTooltip(entry, cell.key, frame, config)
    end
end

local function cellOnLeave(frame)
    local cell = frame.mmCell
    if not cell then return end
    if cell.row then cell.row:SetMouseOver(false) end
    -- In a breakdown the ROW owns the tooltip. Hiding it here would undo the
    -- whole point: the cursor crossing a cell seam would blank a tooltip the row
    -- is still hovering.
    if cell.entry and cell.entry.isDrillDown then return end
    local T = NS.Tooltip
    if T and T.Hide then T:Hide() end
end

--- A click on a cell: left opens a breakdown, right leaves one.
---
--- RIGHT-CLICK IS THE ONLY WAY OUT that does not require finding the cell you
--- came in on. It replaced a Back button drawn above the rows — which cost a row
--- of height on every drilled window, and cost it in a way that pushed the last
--- row out through the bottom of the frame, because `layout.maxRows` is computed
--- from the body height and knew nothing about the button.
---
--- It is deliberately undocumented in the UI: right-click-to-go-back is the
--- conventional idiom in this class of addon, and a permanent hint in the header
--- would be the sort of chrome a player reads once and then looks past forever.
---
--- @param button string  "LeftButton" | "RightButton"
--- The ROW takes the mouse in a breakdown, and owns the tooltip while it does.
---
--- THE FLICKER THIS FIXES. Each cell is its own frame with its own OnEnter and
--- OnLeave, so dragging the cursor sideways across a row fires hide-then-show at
--- every cell boundary — and in a breakdown, where all the cells describe ONE
--- spell, that is a tooltip blinking for no reason the player can see.
---
--- Moving between cells never leaves the ROW's bounds, so the row's OnLeave does
--- not fire and the tooltip simply stays up. The cells sit on top and keep their
--- clicks and their mouseover highlight; they just stop touching the tooltip.
---
--- The grid is deliberately unchanged: there each column asks a different
--- question, so a per-cell tooltip is the correct behaviour rather than a bug.
local function rowOnEnter(frame)
    local row = frame.mmRow
    local entry = row and row.entry
    if not (entry and entry.isDrillDown) then return end
    -- The HIGHLIGHT as well as the tooltip. It is driven from the cells on the
    -- grid, and the cells have no mouse here (see ApplyMouse), so a breakdown row
    -- would light up nowhere if the row did not do it itself.
    row:SetMouseOver(true)
    local T = NS.Tooltip
    -- The probe that would have caught this handler never running at all: the
    -- cells above it consumed the motion, and from the outside "no tooltip" and
    -- "a tooltip that bailed" look identical. See the propagation note in
    -- newCell.
    if State.debug and Debug then
        Debug("Tooltip", "row spell=%s", tostring(entry.spellID))
    end
    if T and T.SpellTooltip then T:SpellTooltip(entry, frame, row.window.config) end
end

local function rowOnLeave(frame)
    local row = frame.mmRow
    local entry = row and row.entry
    if not (entry and entry.isDrillDown) then return end
    row:SetMouseOver(false)
    local T = NS.Tooltip
    if T and T.Hide then T:Hide() end
end

--- Right-click anywhere on a row leaves a breakdown.
---
--- On the ROW rather than only on the cells, because the cells do not tile it:
--- there are seams between them and a margin past the last column, and a
--- right-click that lands in one of those did nothing at all.
--- ...and a left-click on a DEATH row opens the game's own recap for it.
---
--- Both buttons come here rather than to the cells because the cells give up the
--- mouse inside a breakdown (see ApplyMouse). The decision itself belongs to
--- modules/DrillDown.lua — this file wires the click and does not know what a
--- death is.
local function rowOnMouseUp(frame, button)
    local row = frame.mmRow
    if not row then return end
    local D = NS.DrillDown
    if not D then return end

    if D.OnRowClick then
        D:OnRowClick(row.window.config, row.entry, button)
        return
    end
    -- The pre-OnRowClick behaviour, kept as the fallback so a partially loaded
    -- namespace still has a way out of a breakdown.
    if button == "RightButton" and D.Exit then D:Exit(row.window.config) end
end

local function cellOnMouseUp(frame, button)
    local cell = frame.mmCell
    if not (cell and cell.entry) then return end

    local D = NS.DrillDown
    if button == "RightButton" then
        -- Harmless on the grid: Exit answers false when there is no view to
        -- leave, so a stray right-click is a no-op rather than a special case.
        if D and D.Exit then D:Exit(cell.window.config) end
        return
    end

    -- INSIDE A BREAKDOWN, A LEFT CLICK DOES NOTHING. The rows here are spells,
    -- and a spell has no breakdown of its own — asking the provider for one
    -- answers nothing and the window renders empty, which reads as a broken
    -- addon rather than as "there is nothing here".
    if cell.entry.isDrillDown then return end

    -- The name column has no breakdown of its own to open — its question is
    -- "how is this player doing overall", which the tooltip already answers.
    if cell.key == "name" then return end
    if D and D.OnCellClick then D:OnCellClick(cell.window.config, cell.entry, cell.key) end
end

-- ---------------------------------------------------------------------------
-- The cell
-- ---------------------------------------------------------------------------

local Cell = {}
Cell.__index = Cell

--- Build one cell. Called only from the row factory, and only ever grown — the
--- pool never destroys a cell, so this runs once per (row, column) pair for the
--- life of the session.
---
--- @param row table      the owning row object
--- @param key string     stat key, or "name"
--- @return table
local function newCell(row, key)
    local bar = CreateFrame("StatusBar", nil, row.frame)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(bar)

    -- Two text slots, anchored to the BAR's edges with a fixed inset. Anchoring
    -- them to the bar is safe in the one direction that matters: secret geometry
    -- propagates from a frame to whatever is anchored TO it, and these two are
    -- the leaves. Nothing ever reads their position back.
    local left = bar:CreateFontString(nil, "OVERLAY")
    left:SetPoint("LEFT", bar, "LEFT", 2, 0)
    -- LEFT-ALIGNED, in every column.
    --
    -- The cells line up under their column HEADERS, which are left-aligned, and a
    -- left header over a right-aligned number reads as two different columns.
    -- Alignment is a property of the grid rather than of the number.
    left:SetJustifyH("LEFT")

    local right = bar:CreateFontString(nil, "OVERLAY")
    right:SetPoint("RIGHT", bar, "RIGHT", -2, 0)
    right:SetJustifyH("RIGHT")

    -- The right slot yields to the left one: a name is worth more than a
    -- per-second figure when the column is too narrow for both.
    left:SetPoint("RIGHT", right, "LEFT", -3, 0)

    local cell = setmetatable({
        frame  = bar,
        bg     = bg,
        left   = left,
        right  = right,
        key    = key,
        stat   = key ~= "name" and Const.STAT_BY_KEY[key] or nil,
        row    = row,
        window = row.window,
    }, Cell)

    -- The mouse scripts read the cell back off the frame rather than closing
    -- over it, so a pooled row that is re-pointed at a different player does not
    -- need its scripts rebuilt.
    bar.mmCell = cell
    bar:SetScript("OnEnter",   cellOnEnter)
    bar:SetScript("OnLeave",   cellOnLeave)
    bar:SetScript("OnMouseUp", cellOnMouseUp)
    -- Both buttons, or the OnMouseUp above never sees a right-click at all.
    if bar.RegisterForClicks then bar:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
    bar:EnableMouse(false)

    return cell
end

--- Place and re-skin one cell from the window's config.
---
--- EVERY number here comes from `layout` and `cfg`, which modules/Window.lua
--- derived from the profile. That is rule R3 in one function: the cell's
--- geometry is a function of settings this addon owns, never of anything read
--- back off a widget that has held a secret.
---
-- The four sides of the `bars.border` outline. Named rather than written out
-- four times so the create loop, the place loop and the tint loop all walk one
-- list and cannot disagree about how many edges a rectangle has.
local BORDER_SIDES = { "top", "bottom", "left", "right" }

--- Draw (or hide) the thin outline `bars.border` asks for.
---
--- Four 1px textures rather than a BackdropTemplate child frame. A frame
--- anchored to this StatusBar would inherit its secretness the moment the bar is
--- handed a value (rule R3), and would then be one more thing nobody may
--- measure; a texture is a leaf, exactly like the two FontStrings above it, and
--- nothing ever reads one back.
---
--- Built on FIRST USE and kept forever after, like every other widget in this
--- file — a player toggling the setting off does not destroy them, because the
--- pool's whole premise is that widget creation happens once.
---
--- The color is the collection's own edge (NS.SKIN.border) rather than a literal
--- picked here: `bars.border` is a yes/no setting with no color of its own, and
--- a hand-chosen outline would be the one line in this window that does not
--- match the frame around it.
function Cell:ApplyBorder(bars)
    local wanted = (bars and bars.border) and true or false
    local edges = self.border
    if not (wanted or edges) then return end

    if not edges then
        edges = {}
        for _, side in ipairs(BORDER_SIDES) do
            edges[side] = self.frame:CreateTexture(nil, "OVERLAY")
        end
        self.border = edges
    end

    if not wanted then
        for _, side in ipairs(BORDER_SIDES) do edges[side]:Hide() end
        return
    end

    local bar = self.frame
    local skin = NS.SKIN or {}
    local r, g, b, a = RGBA(skin.border, 0, 0, 0, 1)

    for _, side in ipairs(BORDER_SIDES) do
        local tex = edges[side]
        tex:ClearAllPoints()
        tex:SetColorTexture(r, g, b, a)
        if side == "top" then
            tex:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
            tex:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, 0)
            tex:SetHeight(1)
        elseif side == "bottom" then
            tex:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
            tex:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
            tex:SetHeight(1)
        elseif side == "left" then
            tex:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
            tex:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
            tex:SetWidth(1)
        else
            tex:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, 0)
            tex:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
            tex:SetWidth(1)
        end
        tex:Show()
    end
end

--- Skin the StatusBar itself: fill texture, fill direction, and the backdrop
--- that sits behind the fill.
---
--- @param bars table|nil   the window's `bars` config group
--- @param showBar boolean  whether this column draws its bar at all
function Cell:ApplyBarSkin(bars, _showBar)
    local bar = self.frame
    bar:SetStatusBarTexture(barTexture(bars and bars.texture))
    bar:SetAlpha(bars and bars.alpha or 1)
    bar:SetOrientation("HORIZONTAL")
    -- fillDirection "LEFT" means the bar GROWS rightward from the left edge,
    -- which is SetReverseFill(false). The setting is named for where the fill
    -- starts because that is what a player looking at the window sees.
    bar:SetReverseFill((bars and bars.fillDirection) == "RIGHT")

    -- THE BACKGROUND COLOR IS NOT SET HERE ANY MORE. It depends on WHOSE row this
    -- is — `bars.bgColorMode` defaults to the player's class — and this function
    -- runs on a settings change, when there is no entry to ask. Cell:SetValue
    -- sets it per row; all this does is decide whether it is drawn at all.
    --
    -- A cell with its bar switched off keeps its text and its background: the
    -- column still reads and still carries the class tint, it just stops
    -- competing for attention with a filled bar.
    self.bg:SetShown(true)
end

--- Give both of the cell's text slots the window's font, color and shadow.
---
--- The two slots are always styled identically — they are one typographic
--- decision shown twice, and letting them drift is how a window ends up with a
--- name in one font and its number in another.
---
--- @param text table  the window's `text` config group (already defaulted)
--- Paint the name in its class color, or white where there is no class.
---
--- IDENTITY MOVES TO THE TEXT in the name column: it has no bar to carry the
--- class color, and `classFilename` is NeverSecret, so this keeps working at the
--- height of a pull when every number on the row is opaque.
---
--- ITS OWN FUNCTION BECAUSE TWO CALLERS NEED IT, and the second one is a bug
--- fix. Cell:ApplyTextStyle repaints every slot in the window's text color —
--- white — and it runs on every layout pass, which during a drag-resize is every
--- frame. The class color was only restored by the next Cell:SetPlayer, up to a
--- throttle interval later, so the names flashed white for as long as the mouse
--- was moving. Re-applying it at the end of the styling pass closes that window
--- entirely rather than shortening it.
---
--- @param entry table|nil  defaults to the cell's current row
function Cell:ApplyNameColor(entry)
    if self.key ~= "name" then return end
    entry = entry or self.entry
    local classes = _G.RAID_CLASS_COLORS
    local c = classes and entry and entry.classFilename and classes[entry.classFilename]
    if c then
        self.left:SetTextColor(c.r, c.g, c.b)
    else
        -- An unknown class reads as "no class information", not as a tenth color.
        self.left:SetTextColor(1, 1, 1)
    end
end

function Cell:ApplyTextStyle(text)
    local path = fontPath(text.font)
    local flags = (text.outline ~= "NONE") and text.outline or nil
    local size = text.size or 11
    local tr, tg, tb, ta = RGBA(text.color, 1, 1, 1, 1)
    local shadowX = text.shadow and 1 or 0
    local shadowY = text.shadow and -1 or 0

    self.left:SetFont(path, size, flags)
    self.right:SetFont(path, size, flags)
    self.left:SetTextColor(tr, tg, tb, ta)
    self.right:SetTextColor(tr, tg, tb, ta)
    self.left:SetShadowOffset(shadowX, shadowY)
    self.right:SetShadowOffset(shadowX, shadowY)

    -- LAST, and deliberately after the color above: the name column's color is
    -- the player's class, not the window's text color, and this pass would
    -- otherwise leave it white until the next refresh drew the row again.
    self:ApplyNameColor()
end

--- @param layout table  the window's computed layout (see modules/Window.lua)
--- @param col table     this cell's column descriptor { x, width, showBar }
function Cell:ApplyLayout(layout, col)
    local cfg = self.window.config
    local bar = self.frame
    local showBar = col.showBar ~= false

    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", self.row.frame, "TOPLEFT", col.x, 0)
    bar:SetSize(col.width, layout.rowHeight)

    local bars = cfg.bars
    self:ApplyBarSkin(bars, showBar)
    self:ApplyBorder(bars)

    local text = cfg.text or {}
    self:ApplyTextStyle(text)
    -- The two alphas multiply rather than override: `bars.alpha` fades the whole
    -- cell and `text.alpha` fades only the writing on top of it.
    bar:SetAlpha((bars and bars.alpha or 1) * (text.alpha or 1))

    self.showBar = showBar
end

--- Draw one player's figure for this column.
---
--- @param entry table  the aggregated row (a player, or a spell in a
---   drill-down); every numeric field on it is an OPAQUE handle apart from
---   `percent`, which modules/Aggregator.lua computed and is therefore plain
---   `displayText`, a caption this addon composed — see cellFigures
function Cell:SetValue(entry)
    self.entry = entry

    local cfg = self.window.config
    local text = cfg.text or {}
    local mode = text.numberFormat or "abbreviated"

    local total, rate, colMax, percent, displayText = cellFigures(entry, self.key)
    local bar = self.frame

    -- `== nil` is the ONE test this file applies to a meter value, and it is
    -- legal on a non-boolean secret. Everything else — how big it is, how it
    -- compares to the column max — is the widget's business, natively.
    if colMax == nil then
        bar:SetMinMaxValues(0, 1)
    else
        bar:SetMinMaxValues(0, colMax)
    end
    bar:SetValue(total == nil and 0 or total)

    if self.showBar then
        local r, g, b = barColor(cfg.bars, entry, self.key)
        bar:SetStatusBarColor(r, g, b)
    else
        bar:SetStatusBarColor(0, 0, 0, 0)
    end

    -- The class tint behind the bar, per row. See cellBackground.
    local br, bg, bb, ba = cellBackground(cfg.bars, entry, self.key)
    self.bg:SetColorTexture(br, bg, bb, ba)

    -- Both halves of the Damage and Healing columns come off ONE source row:
    -- `amountPerSecond` ships beside `totalAmount`, which is why the addon never
    -- queries Enum.DamageMeterType.Dps or .Hps at all (design §3). A counting
    -- stat has no meaningful rate, so its right slot stays empty rather than
    -- announcing "0.42 interrupts per second".
    local isRate = self.stat and self.stat.isRate

    -- TWO SLOTS, FILLED LEFT FIRST.
    --
    -- The left one is anchored to the cell's left edge and is left-aligned, under
    -- a left-aligned column header. So whatever the cell has to say goes THERE,
    -- and the right slot is only used when there are genuinely two figures. The
    -- earlier version filled the right slot first, which put a lone number hard
    -- against the cell's right edge and a column header hard against its left —
    -- reading as two columns rather than one.
    --- One slot's text, for any of the four things a slot may be set to.
    ---
    --- Both slots take the same four values now — None, Total, Per second,
    --- Percent — where they used to take different three-value sets that only
    --- overlapped on two. That asymmetry was not a design: it made "show me the
    --- total on the right" unexpressible for no reason anyone could state.
    ---
    --- `rate` on a COUNTING stat answers nil rather than a number, because
    --- "0.42 interrupts per second" is not a thing a meter should say.
    local function slotText(which)
        if which == "percent" then return renderPercent(percent, mode) end
        if which == "total" then return renderValue(total, "total", mode) end
        if which == "rate" and isRate then return renderValue(rate, "rate", mode) end
        return nil
    end

    -- TWO SLOTS, FILLED LEFT FIRST.
    --
    -- The left one is anchored to the cell's left edge and is left-aligned, under
    -- a left-aligned column header. So whatever the cell has to say goes THERE,
    -- and the right slot is only used when there are genuinely two figures. The
    -- earlier version filled the right slot first, which put a lone number hard
    -- against the cell's right edge and a column header hard against its left —
    -- reading as two columns rather than one.
    local secondary = slotText(text.rightSlot or "none")

    -- A CELL WITH NOTHING TO SAY FALLS BACK TO ITS TOTAL. Both slots can be set
    -- to None, and a counting stat silently drops a `rate` slot — either way the
    -- column would render a header, a bar and no number at all. Showing the one
    -- figure the stat has beats showing none.
    local primary = slotText(text.leftSlot or "total")
    if primary == nil and secondary == nil then
        primary = renderValue(total, "total", mode)
    end

    -- One figure sits at the left edge; two span the cell.
    if primary == nil then
        primary, secondary = secondary, nil
    end

    -- A CELL CAN CARRY A CAPTION INSTEAD OF A FIGURE, and when it does the
    -- caption is the whole cell. A death row's Deaths cell holds the wall-clock
    -- time of the death; a second number beside it would read as two columns,
    -- and the slot the profile happens to prefer — the shipped default is
    -- `rate` — would otherwise print a figure where the time belongs.
    --
    -- Applied AFTER the slot resolution and the fallback above, so a cell that
    -- leaves this nil goes through the identical path it always has. `~= nil`
    -- and not `or`: `or` is a truth test spelled differently, and it would also
    -- fire on an empty string.
    if displayText ~= nil then
        primary, secondary = displayText, nil
    end

    self.left:SetText(primary or "")
    self.right:SetText(secondary or "")
end

--- Blank the cell without releasing it. Used for a row that is on screen but has
--- nothing for this column, so the pool never has to rebuild a widget.
function Cell:Clear()
    self.entry = nil
    self.frame:SetValue(0)
    self.left:SetText("")
    self.right:SetText("")
end

-- ---------------------------------------------------------------------------
-- The name cell
-- ---------------------------------------------------------------------------
--
-- Same widget as any other cell — it is a StatusBar so the leading column can
-- carry a class-colored bar too — plus the icons. `classFilename` and
-- `specIconID` are NeverSecret, so this column renders in full even when every
-- number to its right is opaque.

local function newIcon(cell)
    local tex = cell.frame:CreateTexture(nil, "ARTWORK")
    tex:Hide()
    return tex
end

--- Lay the class / spec / role icons out along the name cell and return the
--- text inset they consume, so the name string starts clear of them.
---
--- @param layout table
--- @return number  the horizontal inset for the name text
function Cell:ApplyIcons(layout)
    local icons = self.window.config.icons or {}
    local size = icons.size or 14
    -- ONE SLOT. There were three, one per icon kind, and a player who turned
    -- them all on got three textures competing with the name for a column that
    -- has to hold a name. The slot picks its own icon per row — see drawUnitIcon.
    local slots = icons.showIcon and { "unit" } or {}

    self.iconOrder = slots
    self.icons = self.icons or {}

    local onRight = (icons.position == "RIGHT")
    local offset = 2
    for i, kind in ipairs(slots) do
        local tex = self.icons[kind] or newIcon(self)
        self.icons[kind] = tex
        tex:ClearAllPoints()
        tex:SetSize(size, size)
        local y = (layout.rowHeight - size) * -0.5
        if onRight then
            tex:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -(offset + (i - 1) * (size + 1)), y)
        else
            tex:SetPoint("TOPLEFT", self.frame, "TOPLEFT", offset + (i - 1) * (size + 1), y)
        end
    end

    -- Hide any icon the config just turned off. Kept rather than destroyed: the
    -- pool's whole point is that widget creation happens once.
    for kind, tex in pairs(self.icons) do
        local wanted = false
        for _, k in ipairs(slots) do if k == kind then wanted = true end end
        if not wanted then tex:Hide() end
    end

    -- FIXED SPACE FOR THE ICONS, WHETHER OR NOT A GIVEN ROW HAS THEM.
    --
    -- Computed from the CONFIGURED slots rather than from what this row managed
    -- to draw, so a follower NPC with no spec icon leaves a gap where the icon
    -- would be instead of sliding its name left. A column whose text starts at a
    -- different x on every row is not a column.
    local consumed = #slots > 0 and (offset + #slots * (size + 1)) or 2

    -- AN EXPLICIT WIDTH, NOT A SECOND ANCHOR. Two-point anchoring gives the
    -- FontString a width too, but it also lets it grow to whatever the frame
    -- becomes mid-resize; a fixed width is the same number every pass and is what
    -- the truncation cap is measured against.
    local column = layout.nameColumn or {}
    local width = (column.width or 0) - consumed - 2
    if width < 1 then width = 1 end

    self.left:ClearAllPoints()
    if onRight then
        self.left:SetPoint("LEFT", self.frame, "LEFT", 2, 0)
    else
        self.left:SetPoint("LEFT", self.frame, "LEFT", consumed, 0)
    end
    self.left:SetWidth(width)
    self.left:SetHeight(layout.rowHeight)

    -- ONE LINE, NEVER WRAPPED. A wrapped name is drawn OUTSIDE its own row — the
    -- second line lands on top of the row below it — which is what made the grid
    -- look shuffled whenever somebody had a long name. The cap in nameText is
    -- what shortens it; this is what guarantees the widget cannot undo that
    -- decision by reflowing.
    if self.left.SetWordWrap then self.left:SetWordWrap(false) end
    if self.left.SetMaxLines then self.left:SetMaxLines(1) end

    return consumed
end

-- The crop applied to a square icon FILE, so the art fills its slot without the
-- transparent border most icon textures carry. Written as the two edges rather
-- than as an inset and a subtraction: these four numbers go straight to
-- SetTexCoord and are compared literally by the render tests.
local ICON_TRIM_MIN, ICON_TRIM_MAX = 0.07, 0.93

-- Width of the "this row is you" edge. See the note where it is built.
local SELF_EDGE_WIDTH = 3

-- The default cap, restated nowhere else: settings/Schema.lua's row carries the
-- same number as its `default`, and this is the fallback for a window whose
-- config predates the setting.
local DEFAULT_MAX_NAME = 20

--- Render `entry.name` for the FontString: realm stripped, length capped.
---
--- `entry.name` is ConditionalSecret, so it goes through the same concat probe a
--- number would: on a client that hides it mid-pull the row still draws, with
--- the class icon carrying the identity instead. `== nil` is the one test
--- allowed on it; everything past that asks the core seam whether the value may
--- be turned into a string at all.
---
--- BOTH TRANSFORMS ARE GATED ON THAT PROBE, and that is the whole subtlety here.
--- `string.match` and `string.sub` are INSPECTIONS — they read the characters of
--- the value — and performing one on a secret is exactly what rule R1 forbids.
--- So a plain name is stripped and capped, and a secret name is handed to the
--- widget untouched and uncapped. The uncapped case is not a hole: a name we may
--- not read is one the client is already refusing to show in full.
---
--- WHAT IT MUST NOT DO IS RENDER THE SENTINEL. The opaque branch used to answer
--- NS.SafeToString(name), which is `"<secret>"` — so every row but the local
--- player's said `<secret>` where a name should be, for the whole of a pull. That
--- is the debug renderer's answer, and it is the right one for a LOG LINE, where
--- the alternative is a raise inside string.format.
---
--- A widget is not a log line. `FontString:SetText` ACCEPTS a secret and the
--- client draws the real characters — that is the whole point of the value being
--- opaque to us rather than hidden from the player, and it is the same permission
--- modules/Format.lua relies on to put "12.4M" on a bar it may not divide. So the
--- handle goes to the widget untouched, and the return type of this function is
--- "a string, or something SetText will take" (modules/Format.lua's phrase). Its
--- ONE caller passes it straight to SetText and does nothing else with it; a
--- future caller that wants to compare or concatenate the result has to reach for
--- NS.IsConcatSafe itself.
---
--- Truncate to `cap` CHARACTERS, counting UTF-8 rather than bytes. NO ELLIPSIS:
--- the name column is narrow and a cap that spends its last character saying "I
--- ran out of characters" is a character it could have spent on the name.
---
--- `s:sub(1, cap)` is wrong here and wrong in a way that only shows up on the
--- names most likely to need truncating: "Helyâ" is six bytes and five
--- characters, and a byte slice can land in the middle of the â and emit half a
--- code point, which renders as a replacement box. So the walk skips
--- continuation bytes (0x80-0xBF), which are never the start of a character.
---
--- Pure Lua rather than strlenutf8 / string.utf8sub: those are client globals
--- that the headless harness does not have, and the whole function is six lines.
---
--- @param s string   a PLAIN string — never call this on a secret
--- @param cap number
--- @return string
local function utf8Truncate(s, cap)
    local chars, i, n = 0, 1, #s
    while i <= n do
        local b = s:byte(i)
        -- A continuation byte belongs to the character before it and is not
        -- counted; anything else starts a new one.
        if b < 0x80 or b > 0xBF then
            chars = chars + 1
            if chars > cap then return s:sub(1, i - 1) end
        end
        i = i + 1
    end
    return s
end

--- @param name any        a name string, an opaque handle, or nil
--- @param text table|nil  the window's `text` config group
--- @param stripRealm boolean  true only for a real player's row (see below)
--- @return any  a string, or something SetText will take — see above
local function nameText(name, text, stripRealm)
    if name == nil then return "" end

    if not (NS.IsConcatSafe and NS.IsConcatSafe(name)) then
        -- Opaque. No match, no sub, no length — hand it over AS-IS, which is
        -- what the widget wants and what draws the player's actual name.
        return name
    end

    local out = tostring(name)

    -- REALM STRIP. A cross-realm name arrives as "Player-Realm"; the realm is
    -- never what a player is scanning a meter for and it is most of the column.
    --
    -- GATED ON THE ROW BEING AN ACTUAL PLAYER, and that gate is load-bearing
    -- rather than defensive. A hyphen is only a realm separator in a PLAYER's
    -- name; everywhere else in this grid it is part of the name. The first build
    -- of this stripped on the hyphen unconditionally and rendered the
    -- follower-dungeon NPC "Crenna Earth-Daughter" as "Crenna Earth", which
    -- reads as a truncation bug rather than as a feature.
    --
    -- The test is the GUID, not the name: `Player-` prefixes a character's GUID
    -- and nothing else's. Guessing from the string — "does the part before the
    -- hyphen contain a space" — would be a heuristic about naming conventions we
    -- do not control, when the row is already carrying the answer.
    if stripRealm then
        local bare = out:match("^([^-]+)")
        if bare then out = bare end
    end

    -- LENGTH CAP. 0 means "no cap" — an explicit off switch rather than a
    -- sentinel nobody can guess.
    local cap = (text and text.maxNameLength) or DEFAULT_MAX_NAME
    if type(cap) == "number" and cap > 0 then
        out = utf8Truncate(out, cap)
    end

    return out
end

--- Draw the leading icon slot: the player's class, or — in a drill-down — the
--- spell's own icon.
---
--- A drill-down row is a SPELL, not a player, so the class slot carries the
--- spell's icon, which is the only identity it has. The bar stays the
--- drilled-into player's class color, so the trip into a breakdown and back
--- reads as one continuous view.
--- Draw the row's single icon: the spell's in a breakdown, otherwise the unit's.
---
--- THE LADDER, and each rung is there for a reason rather than as a preference:
---
---   1. A BREAKDOWN ROW IS A SPELL. Its `icon` is the spell's own file id and it
---      has no class, no spec and no role — this rung has nothing to do with
---      units and is first because the row is not one.
---   2. SPEC IF THERE IS ONE. "Which unit is this row" is the question the icon
---      answers, and a spec answers it better than a class: it separates the
---      three druids in a raid, which a class icon cannot.
---   3. CLASS OTHERWISE. A spec is not always known — an NPC, a pet, a player
---      the unit API has not resolved — and a class icon is still an answer.
---   4. NEVER A ROLE. Three roles across a whole raid identifies nobody, and it
---      was the icon most likely to be showing when the name got squeezed.
---
--- `classFilename` and `specIconID` are both NeverSecret, so every branch here
--- keeps working mid-pull when the numbers beside it are opaque.
local function drawUnitIcon(tex, entry)
    if entry.isDrillDown then
        if entry.icon then
            tex:SetTexture(entry.icon)
            tex:SetTexCoord(ICON_TRIM_MIN, ICON_TRIM_MAX, ICON_TRIM_MIN, ICON_TRIM_MAX)
            tex:Show()
        else
            tex:Hide()
        end
        return
    end

    if entry.specIconID then
        tex:SetTexture(entry.specIconID)
        tex:SetTexCoord(ICON_TRIM_MIN, ICON_TRIM_MAX, ICON_TRIM_MIN, ICON_TRIM_MAX)
        tex:Show()
        return
    end

    local coords = _G.CLASS_ICON_TCOORDS
    local c = coords and entry.classFilename and coords[entry.classFilename]
    if c then
        tex:SetTexture(CLASS_TEXTURE)
        tex:SetTexCoord(c[1], c[2], c[3], c[4])
        tex:Show()
    else
        tex:Hide()
    end
end

--- Draw the name column for one player: icons, and a class-colored name.
---
--- NO BAR. The name column used to draw one scaled to the sort column, which
--- duplicated what the sort column's own cell already shows an arm's length to
--- the right and cost this frame its readable geometry to do it.
---
--- @param entry table   the aggregated row
--- @param _sortKey string  the window's sort column; see the note below on why
---   the name cell no longer reads it
function Cell:SetPlayer(entry, _sortKey)
    self.entry = entry

    -- THE NAME CELL IS NEVER HANDED A VALUE. Not "handed one and told not to
    -- draw it" — never handed one.
    --
    -- SetValue(secret) marks a frame HasSecretValues, which makes its anchoring
    -- and position data secret too and propagates that to everything anchored to
    -- it (rule R3). The name cell used to take the sort column's figure purely to
    -- scale a bar behind the name; dropping that bar therefore also takes this
    -- frame out of the secret set entirely, which is a taint win on top of the
    -- visual one. `sortKey` is now unused here and kept in the signature because
    -- modules/Row.lua's caller passes it positionally and a future re-read of the
    -- sort column would land here.
    --
    -- The bar is flattened rather than hidden: the widget still exists (it is the
    -- cell's frame and everything else anchors to it), it just draws nothing.
    self.frame:SetMinMaxValues(0, 1)
    self.frame:SetValue(0)
    self.frame:SetStatusBarColor(0, 0, 0, 0)

    self:ApplyNameColor(entry)

    -- THE CLASS TINT RUNS ACROSS THIS CELL TOO. It is painted by Cell:SetValue
    -- for every stat column, and the name column was the one cell that never got
    -- it — so the tint began at the Damage column and the player column sat
    -- conspicuously undressed beside it. The background is the cell's own
    -- texture, not the bar, so this stays true of a cell whose bar is flattened
    -- to nothing (which this one always is).
    local br, bgc, bb, ba = cellBackground((self.window.config.bars or {}), entry, self.key)
    self.bg:SetColorTexture(br, bgc, bb, ba)

    -- A `Player-…` GUID is the only thing whose name can carry a realm. A pet, a
    -- follower-dungeon NPC, an enemy and a drill-down spell all keep every
    -- hyphen they came with.
    local isCharacter = entry.guid ~= nil and not entry.isDrillDown
        and Secrets.IsSafeKey(entry.guid)
        and tostring(entry.guid):match("^Player%-") ~= nil

    self.left:SetText(nameText(entry.name, self.window.config.text, isCharacter))
    self.right:SetText("")

    local icons = self.icons
    if not icons then return end
    if icons.unit then drawUnitIcon(icons.unit, entry) end
end

-- ---------------------------------------------------------------------------
-- The row
-- ---------------------------------------------------------------------------

local RowProto = {}
RowProto.__index = RowProto

--- Build a row and its cells. Called by the window's pool when it grows, never
--- on a refresh.
---
--- @param window table  the owning window instance
--- @return table
function Row.New(window)
    local frame = CreateFrame("Frame", nil, window.body)
    frame:Hide()
    -- The row's own mouse. The cells sit on top and keep their hovers and their
    -- clicks; what the row adds is the seams BETWEEN them and the margin past
    -- the last column, which the cells do not tile — and, in a breakdown,
    -- ownership of the tooltip so it stops blinking at every cell boundary.
    frame:SetScript("OnEnter",   rowOnEnter)
    frame:SetScript("OnLeave",   rowOnLeave)
    frame:SetScript("OnMouseUp", rowOnMouseUp)
    if frame.RegisterForClicks then frame:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
    frame:EnableMouse(false)

    local row = setmetatable({
        window = window,
        frame  = frame,
        cells  = {},   -- [statKey] = cell
    }, RowProto)

    -- The scripts above read the row back off the frame rather than closing over
    -- it, matching how the cells do it: a pooled row is re-pointed at a different
    -- player, never rebuilt, so nothing may capture the row it was built for.
    frame.mmRow = row

    row.bg = frame:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints(frame)
    row.bg:Hide()

    -- Two separate overlays rather than one re-tinted texture: "this is you" and
    -- "the cursor is here" are independent facts and a player wants to see both
    -- at once.
    -- "THIS ROW IS YOU", as an EDGE rather than as a wash.
    --
    -- It used to be a gold texture across the whole row, and once rows started
    -- carrying a class tint the two fought: the wash sat on top and turned a
    -- warlock's purple into the same yellow every other class got, so the one row
    -- a player looks at first was the one row whose class color was gone.
    --
    -- A left edge says the same thing and takes nothing away — it is in a part of
    -- the row the tint does not use, and it reads at a glance precisely because
    -- nothing else in the grid is a vertical bar.
    row.selfHighlight = frame:CreateTexture(nil, "OVERLAY")
    row.selfHighlight:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    row.selfHighlight:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    row.selfHighlight:SetWidth(SELF_EDGE_WIDTH)
    row.selfHighlight:Hide()

    row.mouseHighlight = frame:CreateTexture(nil, "OVERLAY")
    row.mouseHighlight:SetAllPoints(frame)
    row.mouseHighlight:SetColorTexture(1, 1, 1, 0.10)
    row.mouseHighlight:Hide()

    row.nameCell = newCell(row, "name")

    return row
end

--- Re-place every widget from the window's config. Called on creation and on any
--- settings change — never on a refresh, because none of these numbers can move
--- between refreshes.
function RowProto:ApplyLayout(layout)
    local frame = self.frame
    frame:SetSize(layout.rowWidth, layout.rowHeight)

    self.nameCell:ApplyLayout(layout, layout.nameColumn)
    self.nameCell:ApplyIcons(layout)

    -- Grow the cell set to match the enabled columns, and hide any cell whose
    -- column was removed. Cells are never destroyed: a column toggled off and on
    -- again re-uses the widget it had before.
    local live = {}
    for _, col in ipairs(layout.columns) do
        local cell = self.cells[col.key]
        if not cell then
            cell = newCell(self, col.key)
            self.cells[col.key] = cell
        end
        cell:ApplyLayout(layout, col)
        cell.frame:Show()
        live[col.key] = true
    end
    for key, cell in pairs(self.cells) do
        if not live[key] then
            cell.frame:Hide()
            cell:Clear()
        end
    end

    local rows = self.window.config.rows or {}
    -- Full opacity: it is three pixels wide, and a three-pixel marker at 12%
    -- alpha is a marker nobody sees.
    self.selfHighlight:SetColorTexture(1, 0.82, 0, rows.highlightSelf and 1 or 0)
    self.mouseHighlight:SetShown(false)
end

--- Point this row at one player.
---
--- Every figure a cell needs rides on the entry itself — including `percent`,
--- which modules/Aggregator.lua divides once per cell per pass. The window used
--- to hand a per-column totals table down this call so the cells could divide
--- again; it cost a second Provider.GetColumn read per column per refresh and
--- produced a number the entry was already carrying.
---
--- @param entry table       the aggregator row: { guid, name, classFilename,
---   specIconID, role, isPlayer, cells = { [statKey] = { value, rate,
---   maxAmount, percent, deathRecapID, deathTime } } }
--- @param index number      1-based position in the drawn list
function RowProto:Update(entry, index)
    local t0 = Perf.on and debugprofilestop()

    self.entry = entry
    self.index = index

    -- THE CLASS TINT IS THE CELLS', NOT THE ROW'S. It lived here briefly and
    -- tinted the two-pixel seams between columns along with the cells, which lost
    -- the column separators the grid is read by. Cell:SetValue paints each cell's
    -- own background instead (`bars.bgColorMode`), so the seams stay clear.
    --
    -- What is left here is the alternating stripe, which is a ROW-level fact.
    local rows = self.window.config.rows or {}
    if rows.alternatingBackground and index % 2 == 0 then
        self.bg:SetColorTexture(1, 1, 1, 0.05)
        self.bg:Show()
    else
        self.bg:Hide()
    end
    -- Both spellings of "this row is you" are honored: modules/Aggregator.lua
    -- says `isPlayer`, modules/DrillDown.lua and the API's source rows say
    -- `isLocalPlayer`. Reading both is one `or` here against a bug report about
    -- a highlight that works in the grid and not in a breakdown.
    local isSelf = entry.isPlayer or entry.isLocalPlayer
    self.selfHighlight:SetShown((rows.highlightSelf and isSelf) and true or false)

    self.nameCell:SetPlayer(entry, self.window.sortColumn)

    for _, cell in pairs(self.cells) do
        cell:SetValue(entry)
    end

    -- After the entry is set, because who takes the mouse depends on what kind
    -- of row this now is.
    self:ApplyMouse()

    self.frame:Show()

    if t0 then Perf.Note("renderRow", debugprofilestop() - t0) end
end

--- Toggle the mouseover overlay. Driven from the CELLS on the grid, and from the
--- ROW in a breakdown, because that is where the mouse is in each case — see
--- ApplyMouse.
function RowProto:SetMouseOver(on)
    local rows = self.window.config.rows or {}
    self.mouseHighlight:SetShown((on and rows.mouseoverHighlight) and true or false)
end

--- Hand the mouse to whichever frame is supposed to have it.
---
--- ON THE GRID it is the CELLS. Each column asks a different question, so each
--- cell owns its own tooltip and its own click into a breakdown.
---
--- IN A BREAKDOWN it is the ROW, ALONE — and the cells give theirs up, which is
--- the whole mechanism rather than a tidy-up. A cell is a CHILD of the row frame
--- and therefore sits on top of it, and a mouse-enabled frame consumes mouse
--- motion, so while the cells kept their mouse the row's OnEnter fired only in
--- the seams between columns and in the margin past the last one — which is to
--- say almost never, and the breakdown's spell tooltip never appeared.
---
--- Letting the motion through instead is not available to us: the API for it,
--- `SetPropagateMouseMotion`, is PROTECTED, and an addon that calls it gets
--- ADDON_ACTION_BLOCKED rather than a tooltip. Giving the mouse up is the only
--- route, and it costs nothing, because a breakdown cell has no job left: a
--- left-click there does nothing by design, all its cells describe ONE spell so
--- there is no per-column question to ask, and right-click-to-leave and the
--- mouseover highlight are both already on the row.
---
--- Called from Update, so it follows the entry rather than the lock.
function RowProto:ApplyMouse()
    local drilled = (self.entry and self.entry.isDrillDown) and true or false
    self.frame:EnableMouse(true)
    self.nameCell.frame:EnableMouse(not drilled)
    for _, cell in pairs(self.cells) do
        cell.frame:EnableMouse(not drilled)
    end
end

--- Kept as the name modules/Window.lua calls on a lock change and on a freshly
--- grown row. The lock no longer governs this — dragging moved to the title bar
--- (see WindowProto:ApplyLock) — so the answer is ApplyMouse's either way.
function RowProto:EnableCellMouse()
    self:ApplyMouse()
end

--- Show and hide the row.
---
--- The pooled object here is this TABLE, not the frame it wraps, and LibKa0s-Pool-1.0 asks a
--- pooled object for exactly two methods — `:Show()` and `:Hide()`. Forwarding them is the whole
--- of what the row had to grow to be poolable by the library; everything else the pool does to a
--- row it does through the `before` hook, which calls `Release` below.
function RowProto:Show() self.frame:Show() end
function RowProto:Hide() self.frame:Hide() end

--- Return the row to the pool: hidden, blank, and holding no reference to the
--- player it was drawing.
function RowProto:Release()
    self.entry = nil
    self.index = nil
    self.frame:Hide()
    self.mouseHighlight:Hide()
    self.selfHighlight:Hide()
    self.bg:Hide()
    self.nameCell:Clear()
    for _, cell in pairs(self.cells) do cell:Clear() end
end

--- Where the row at `index` sits, as a distance from the body's growth edge.
---
--- Published so modules/Window.lua can place a row without restating the rule,
--- and so a test can assert the arithmetic without a frame. The answer is a pure
--- function of the index and the row config — no widget is consulted — which is
--- rule R3 for the vertical axis exactly as ApplyLayout is for the horizontal.
---
--- @param layout table
--- @param index number   1-based
--- @return number y      offset from the body's top (DOWN) or bottom (UP)
function Row.OffsetFor(layout, index)
    return (index - 1) * (layout.rowHeight + layout.rowSpacing)
end
