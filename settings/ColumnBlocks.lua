-- settings/ColumnBlocks.lua
--
-- A reorderable list of blocks: a drag handle, a state glyph, a label, and a rule
-- where the enabled ones stop.
--
-- ---------------------------------------------------------------------------
-- WHY THIS IS ITS OWN FILE, AND WHY IT IS NOT IN LibKa0s YET
-- ---------------------------------------------------------------------------
--
-- Nothing here knows what a statistic is. It takes `items` and answers with
-- INDICES, which is what makes it the same widget any Ka0s addon with an ordered,
-- user-arrangeable list would want -- and by the Ka0s WoW Addon Standard a
-- generic options widget belongs in LibKa0s-Options beside Section, TextRow,
-- RenderGrid and InlineButtonPair, not in an addon's settings/.
--
-- It is here anyway, deliberately, and the deviation is ratified in
-- docs/ARCHITECTURE.md -> Documented deviations. A LibKa0s widget re-vendors into
-- every addon in the collection, so its API is expensive to change once shipped,
-- and one consumer is not enough evidence to freeze a signature on -- the first
-- real page it serves is what tells you which parts of the signature were
-- guesses. Keeping it in its own file rather than inside the page is what makes
-- the promotion a file move rather than an extraction. Tracked as issue #21.
--
-- ---------------------------------------------------------------------------
-- WHY THE DROP TARGET IS ARITHMETIC AND NOT A HIT TEST
-- ---------------------------------------------------------------------------
--
-- Every block is the same height, so where the cursor has landed is a division:
-- how far it moved, over the stride. Nothing is asked which block is under the
-- pointer, so nothing depends on the blocks having been laid out yet, on the
-- scroll position, or on AceGUI having finished its layout pass -- all three of
-- which are true at different moments during a drag.
--
-- ON RULE R3. This reads the CURSOR and the addon's own constants, and no frame
-- geometry at all. Rule R3 is about cells that have been handed a meter value
-- through SetValue and carry secret anchoring data from that moment on; an
-- options frame never receives one, so the rule does not reach here even where a
-- geometry read would have been legal.

local addonName, NS = ...   -- luacheck: ignore 211/addonName

local H = NS.Helpers or {}

-- The height of one block, and the distance from one block's top to the next's.
-- Published because settings/Columns.lua's suite computes drop distances from
-- them, and a test carrying its own copy of the stride is a test that passes
-- while the widget drops blocks in the wrong place.
NS.BLOCK_HEIGHT = 30
NS.BLOCK_STRIDE = NS.BLOCK_HEIGHT + 4

-- The same two textures ConsumableMaster's priority list wears, so a player who
-- runs both reads one glyph vocabulary rather than two.
local ENABLED_TEX  = "Interface\\RaidFrame\\ReadyCheck-Ready"
local DISABLED_TEX = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local HANDLE_ICON  = "list"

--- Where a block dropped `rows` rows from `from` lands, clamped to its own group.
---
--- THE CLAMP IS THE INTERACTION RULE, not a safety check. You reorder within your
--- own group and the tick is what moves you between them, so a drag that would
--- cross the rule stops at it. Without that, dropping an enabled block into the
--- disabled half would have to silently untick it -- a state change from a
--- gesture that means "move".
---
--- @param from number      the index picked up
--- @param rows number      how many rows down the cursor travelled (negative = up)
--- @param count number     how many blocks there are
--- @param boundary number  how many of them are enabled
--- @return number index    a valid index in `from`'s own group
local function dropIndex(from, rows, count, boundary)
    local lo, hi
    if from <= boundary then
        lo, hi = 1, boundary
    else
        lo, hi = boundary + 1, count
    end

    local to = from + rows
    if to < lo then to = lo end
    if to > hi then to = hi end
    return to
end

--- One block: the handle, the glyph and the label, on a plain frame.
---
--- A raw CreateFrame rather than an AceGUI widget because AceGUI has no block --
--- a SimpleGroup would give a container and every child would still be built by
--- hand inside it, for a layout that is three fixed positions.
local function makeBlock(parent, index, item, spec)
    local block = CreateFrame("Frame", nil, parent)
    block:SetHeight(NS.BLOCK_HEIGHT)
    block:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    block:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    block.mmIndex = index

    -- A disabled block is dimmer but still a block: it can be dragged, and it is
    -- what you click to bring the column back.
    local bg = block:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(block)
    bg:SetColorTexture(1, 1, 1, item.enabled and 0.06 or 0.03)

    local handle = CreateFrame("Button", nil, block)
    handle:SetSize(16, 16)
    handle:SetPoint("LEFT", block, "LEFT", 8, 0)
    handle:RegisterForDrag("LeftButton")
    local handleTex = handle:CreateTexture(nil, "ARTWORK")
    handleTex:SetAllPoints(handle)
    if NS.Icon then handleTex:SetTexture(NS.Icon(HANDLE_ICON)) end
    handleTex:SetVertexColor(0.7, 0.7, 0.7)
    block.mmHandle = handle

    local glyph = CreateFrame("Button", nil, block)
    glyph:SetSize(18, 18)
    glyph:SetPoint("LEFT", block, "LEFT", 40, 0)
    -- Recorded as well as set: the mock's SetNormalTexture stores the path where
    -- a test can compare two blocks' glyphs without reaching into the mock's
    -- private fields, and the widget is the honest place to publish it.
    block.mmGlyphTexture = item.enabled and ENABLED_TEX or DISABLED_TEX
    glyph:SetNormalTexture(block.mmGlyphTexture)
    glyph:SetScript("OnClick", function()
        if spec.onToggle then spec.onToggle(index) end
    end)
    block.mmGlyph = glyph

    local label = block:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("RIGHT", block, "RIGHT", -10, 0)
    label:SetJustifyH("RIGHT")
    label:SetText(item.label or "")
    -- Greyed rather than hidden: a label you cannot read is a block you cannot
    -- aim at, and aiming at it is how you turn the column back on.
    if not item.enabled then label:SetTextColor(0.5, 0.5, 0.5) end
    block.mmLabel = label

    return block
end

--- Wire one block's handle to the drag.
local function wireDrag(block, spec, count, boundary)
    local handle = block.mmHandle
    local startY, rows

    -- Stored on the handle rather than closed over by OnDragStart, so the tracker
    -- can be installed and taken off again without either script holding the
    -- other.
    handle.mmTrack = function()
        if not startY then return end
        local _, y = GetCursorPosition()
        local moved = startY - (y / UIParent:GetEffectiveScale())
        -- +0.5 then floor is round-to-nearest: a block dragged 60% of the way to
        -- the next slot has visibly left its own, and rounding down would drop it
        -- back where it started.
        rows = math.floor(moved / NS.BLOCK_STRIDE + 0.5)
    end

    handle:SetScript("OnDragStart", function()
        local _, y = GetCursorPosition()
        startY = y / UIParent:GetEffectiveScale()
        rows = 0
        handle:SetScript("OnUpdate", handle.mmTrack)
    end)

    handle:SetScript("OnDragStop", function()
        handle:SetScript("OnUpdate", nil)
        if not startY then return end
        startY = nil

        local to = dropIndex(block.mmIndex, rows or 0, count, boundary)
        -- A drag that lands where it started is not a reorder, and reporting one
        -- would rewrite the array and repaint the page for no change at all.
        if to ~= block.mmIndex and spec.onMove then
            spec.onMove(block.mmIndex, to)
        end
    end)
end

--- Render `spec.items` as blocks into `ctx`'s scroll.
---
--- @param ctx table   an options page context (H.CreatePanel's return)
--- @param spec table  { items, onToggle, onMove }
--- @return table blocks  the block frames, in order
function NS.ReorderableBlocks(ctx, spec)
    local scroll = H.EnsureScroll and H.EnsureScroll(ctx)
    local AceGUI = NS.AceGUI
    if not (scroll and AceGUI and type(spec) == "table") then return {} end

    local items = spec.items or {}
    local count = #items

    local boundary = 0
    for _, item in ipairs(items) do
        if item.enabled then boundary = boundary + 1 end
    end

    local blocks = {}
    for i, item in ipairs(items) do
        -- One AceGUI SimpleGroup per block, holding one raw frame. The group is
        -- what the ScrollFrame lays out; the frame inside it is what this file
        -- draws. Going through AceGUI for the LAYOUT and no further is what keeps
        -- the blocks flowing with the rest of the page without asking AceGUI for
        -- a widget it does not have.
        local slot = AceGUI:Create("SimpleGroup")
        slot:SetLayout(nil)
        slot:SetFullWidth(true)
        slot:SetHeight(NS.BLOCK_STRIDE)
        scroll:AddChild(slot)

        local block = makeBlock(slot.frame or slot.content, i, item, spec)
        wireDrag(block, spec, count, boundary)
        blocks[i] = block

        -- The rule, drawn under the LAST enabled block so it marks where the
        -- shown columns stop. Nothing above it is disabled and nothing below it
        -- is enabled, which is a property normalizeColumns guarantees rather than
        -- one this file arranges -- and a list with nothing disabled has no
        -- boundary to mark, so it gets no rule.
        if i == boundary and boundary < count then
            local rule = AceGUI:Create("Heading")
            rule:SetText("")
            rule:SetFullWidth(true)
            rule:SetHeight(12)
            scroll:AddChild(rule)
        end
    end

    return blocks
end
