-- settings/ColumnBlocks.lua
--
-- One block per statistic: a drag handle, a state glyph, a label, and a rule
-- where the enabled ones stop.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS FILE STILL DOES, NOW THAT LibKa0s OWNS THE DRAG
-- ---------------------------------------------------------------------------
--
-- The gesture is `LibKa0s-Widgets-1.0`'s `ReorderList` (minor 8): the handle,
-- the copy carried under the cursor, the insertion line, the index arithmetic
-- and the clamp at the rule. This file kept none of it.
--
-- What is left is the ROW, which the library deliberately owns none of: the
-- tick-or-cross glyph and what clicking it means, the statistic's name, the
-- dimming that says a column is not shown, and the rule drawn under the last
-- enabled block. That split is the whole reason the library member exists in the
-- shape it does -- ConsumableMaster's priority list draws a completely different
-- row and shares the identical gesture.
--
-- ---------------------------------------------------------------------------
-- WHY THE BLOCKS ARE STILL CACHED ON THEIR SLOTS
-- ---------------------------------------------------------------------------
--
-- H.ClearScroll calls AceGUI's ReleaseChildren, which pools the SimpleGroups --
-- so the next render is handed the same `slot.frame` back with the previous
-- render's raw children still parented to it and still shown. Building a second
-- block on it stacked two labels and two glyphs on top of each other, and every
-- repaint added another layer. AceGUI cannot clean them up because they are
-- CreateFrame children, not AceGUI widgets.
--
-- So a slot owns exactly one block for its whole life, and every script reads
-- `block.mmIndex` at FIRE time rather than from an upvalue captured when it was
-- wired -- a closure over the index was the second half of that bug, and made
-- the visible glyph toggle a different statistic than the one clicked.

local addonName, NS = ...   -- luacheck: ignore 211/addonName

local H = NS.Helpers or {}

-- The height of one block and the distance from one block's top to the next's.
-- The stride is what the library does its arithmetic on, and it is published
-- because settings/Columns.lua's suite computes drop distances from it -- a test
-- carrying its own copy is a test that passes while blocks land in the wrong
-- place.
NS.BLOCK_HEIGHT = 30
NS.BLOCK_STRIDE = NS.BLOCK_HEIGHT + 4

-- The same two textures ConsumableMaster's priority list wears, so a player who
-- runs both reads one glyph vocabulary rather than two.
local ENABLED_TEX  = "Interface\\RaidFrame\\ReadyCheck-Ready"
local DISABLED_TEX = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local HANDLE_ICON  = "segment"

--- The library, or nil on an install without it.
local function widgets()
    return LibStub and LibStub("LibKa0s-Widgets-1.0", true)
end

--- The one block on `parent`, built the first time and reused forever after.
--- See the header for why it is cached rather than rebuilt.
local function blockFor(parent)
    if parent.mmBlock then return parent.mmBlock end

    local block = CreateFrame("Frame", nil, parent)
    block:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    block:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    block:SetHeight(NS.BLOCK_HEIGHT)

    block.bg = block:CreateTexture(nil, "BACKGROUND")
    block.bg:SetAllPoints(block)

    local glyph = CreateFrame("Button", nil, block)
    glyph:SetSize(18, 18)
    glyph:SetPoint("LEFT", block, "LEFT", 42, 0)
    glyph:EnableMouse(true)
    glyph:SetScript("OnClick", function()
        local spec = block.mmSpec
        if spec and spec.onToggle then spec.onToggle(block.mmIndex) end
    end)
    block.mmGlyph = glyph

    block.mmLabel = block:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    block.mmLabel:SetPoint("RIGHT", block, "RIGHT", -12, 0)
    block.mmLabel:SetJustifyH("RIGHT")

    parent.mmBlock = block
    return block
end

--- Re-point one block at the item now sitting at `index`.
local function applyBlock(block, index, item, spec)
    block.mmIndex = index
    block.mmSpec  = spec

    -- A disabled block is dimmer but still a block: it can be dragged, and it is
    -- what you click to bring the column back.
    block.bg:SetColorTexture(1, 1, 1, item.enabled and 0.06 or 0.03)

    block.mmGlyphTexture = item.enabled and ENABLED_TEX or DISABLED_TEX
    block.mmGlyph:SetNormalTexture(block.mmGlyphTexture)

    block.mmLabel:SetText(item.label or "")
    -- Greyed rather than hidden: a label you cannot read is a block you cannot
    -- aim at, and aiming at it is how you turn the column back on.
    if item.enabled then
        block.mmLabel:SetTextColor(1, 0.82, 0)
    else
        block.mmLabel:SetTextColor(0.5, 0.5, 0.5)
    end

    block:SetAlpha(1)
    block:Show()
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

    -- A DRAG MUST NOT OUTLIVE THE LIST IT WAS DESCRIBING. Every render replaces
    -- the controller, so the one from the pass before is told to stop -- a ghost
    -- left floating over a list that has already changed names a row that may
    -- not be there any more.
    if ctx.mmReorder then ctx.mmReorder:Cancel() end

    local items = spec.items or {}
    local count = #items

    local boundary = 0
    for _, item in ipairs(items) do
        if item.enabled then boundary = boundary + 1 end
    end

    local W = widgets()
    local list = W and W.ReorderList({
        stride     = NS.BLOCK_STRIDE,
        -- The one list in the collection with two groups. A shown column may not
        -- be dragged among the hidden ones: the tick is what moves a block
        -- between them, and a drag that crossed would have to silently turn a
        -- column off -- a state change from a gesture that means "move".
        boundary   = boundary,
        handleIcon = NS.Icon and NS.Icon(HANDLE_ICON) or nil,
        handleSize = 30,
        onMove     = spec.onMove,
        debug      = (NS.State and NS.State.debug and NS.Debug)
            and function(fmt, ...) NS.Debug("Blocks", fmt, ...) end or nil,
    })
    ctx.mmReorder = list

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

        local block = blockFor(slot.frame or slot.content)
        applyBlock(block, i, item, spec)
        blocks[i] = block

        if list then
            block.mmHandle = list:AddRow(block, {
                ghostText      = item.label,
                ghostIcon      = block.mmGlyphTexture,
                ghostTextColor = item.enabled and { 1, 0.82, 0 } or { 0.5, 0.5, 0.5 },
                height         = NS.BLOCK_HEIGHT,
            })
        end

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

    -- The insertion line lives on the scroll's content, which is what every block
    -- shares as an ancestor.
    if list then list:Finish(scroll.content or scroll.frame) end

    return blocks
end
