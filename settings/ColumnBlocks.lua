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
-- WHY THIS FILE POOLS ITS OWN BLOCKS
-- ---------------------------------------------------------------------------
--
-- H.ClearScroll calls AceGUI's ReleaseChildren, which pools the SimpleGroups.
-- The blocks are CreateFrame children, not AceGUI widgets, so AceGUI neither
-- hides nor knows about them -- they ride a released container into whatever
-- asks for a SimpleGroup next, and on an options page that is almost everything:
-- a spacer, a section heading, a grid row.
--
-- So the blocks are pooled HERE and released on the next render, and every
-- script reads `block.mmIndex` at FIRE time rather than from an upvalue captured
-- when it was wired -- a closure over the index made the visible glyph toggle a
-- different statistic than the one clicked.

local addonName, NS = ...   -- luacheck: ignore 211/addonName

local L = NS.L
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

-- ── the block pool ─────────────────────────────────────────────────────────
--
-- THIS FILE OWNS ITS BLOCKS. It does not cache them on the AceGUI frames it is
-- handed, and the reason is a bug that survived two attempts to fix it.
--
-- Caching on `slot.frame` looked right, because H.ClearScroll releases the slot
-- and the next render gets the same one back. But AceGUI's pool is PROCESS-WIDE
-- and keyed only by widget type, and a SimpleGroup is what almost everything on
-- an options page is made of -- H.AddSpacer creates one, H.Section creates one,
-- H.RenderGrid creates one. So a slot this file released was handed straight to
-- the SPACER between the page's intro line and the first block, arriving with a
-- live block still parented to it and still shown. Which is precisely where the
-- ghost label kept appearing: over row one, every time.
--
-- Same lesson the drag handles learned one layer down: a frame's identity is not
-- ours to borrow. Blocks come from a free list here and are RELEASED on the next
-- render -- hidden, unanchored and reparented off the AceGUI frame in one step --
-- so a block can only ever be visible on a frame this file put it on, during a
-- render it is live for.

local blockPool, blockAttic = {}, nil

local function attic()
    if not blockAttic then
        blockAttic = CreateFrame("Frame", nil, UIParent)
        blockAttic:Hide()
    end
    return blockAttic
end

--- Give every block from the previous render back to the free list.
local function releaseBlocks(ctx)
    local live = ctx and ctx.mmBlocks
    if not live then return 0 end

    local n = #live
    for i = n, 1, -1 do
        local block = live[i]
        live[i] = nil
        block.mmSpec  = nil
        block.mmIndex = nil
        block:Hide()
        block:ClearAllPoints()
        block:SetParent(attic())
        blockPool[#blockPool + 1] = block
    end
    return n
end

--- A block, from the free list or newly built, parented to `parent`.
local function acquireBlock(parent)
    local block = tremove(blockPool)
    if block then
        block:SetParent(parent)
        block:ClearAllPoints()
        block:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
        block:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
        return block
    end

    block = CreateFrame("Frame", nil, parent)
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
    -- WHAT THE CLICK WILL DO, not what the glyph currently means. A tick that
    -- said "shown" would be describing the thing you are already looking at; the
    -- question a player has over a control is what happens if they press it.
    -- Read off the block at HOVER time, like every other script here, so a
    -- re-pointed block never offers last render's promise.
    glyph:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(block.mmEnabled and L["Click to hide this column"]
            or L["Click to show this column"], 1, 1, 1)
        GameTooltip:Show()
    end)
    glyph:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)
    block.mmGlyph = glyph

    block.mmLabel = block:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    block.mmLabel:SetPoint("RIGHT", block, "RIGHT", -12, 0)
    block.mmLabel:SetJustifyH("RIGHT")

    return block
end

--- Re-point one block at the item now sitting at `index`.
local function applyBlock(block, index, item, spec)
    block.mmIndex   = index
    block.mmSpec    = spec
    -- Read by the glyph's tooltip at HOVER time, so a re-pointed block never offers
    -- last render's promise.
    block.mmEnabled = item.enabled and true or false

    -- A disabled block is dimmer but still a block: it cannot be dragged, but it
    -- is what you click to bring the column back.
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

--- Stop the previous render's drag and give its handles back.
---
--- SEPARATE FROM ReorderableBlocks, AND CALLED BEFORE H.ClearScroll, which is the
--- whole point of it being its own function. Releasing a handle is what takes it
--- off the AceGUI frame it was parented to -- and ClearScroll hands every one of
--- those frames back to AceGUI's process-wide pool, where the next thing to ask
--- for a SimpleGroup gets one with a live handle still sitting on it. That is how
--- drag handles turned up on rows that were not lists.
function NS.CancelReorder(ctx)
    if ctx and ctx.mmReorder then
        ctx.mmReorder:Cancel()
        ctx.mmReorder = nil
    end

    local n = releaseBlocks(ctx)
    if n > 0 and NS.State and NS.State.debug and NS.Debug then
        NS.Debug("Blocks", "released %d blocks", n)
    end
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
        handleTooltip = NS.L and NS.L["Drag to reorder"] or nil,
        onMove     = spec.onMove,
        debug      = (NS.State and NS.State.debug and NS.Debug)
            and function(fmt, ...) NS.Debug("Blocks", fmt, ...) end or nil,
    })
    ctx.mmReorder = list

    -- Parked on the ctx so the NEXT render can hand them back. Held here rather
    -- than in a file-local because two panels could each be showing a list.
    local blocks, live = {}, {}
    ctx.mmBlocks = live

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

        local block = acquireBlock(slot.frame or slot.content)
        applyBlock(block, i, item, spec)
        blocks[i] = block
        live[i] = block

        if list then
            -- A HIDDEN COLUMN IS NOT DRAGGABLE. The order of the hidden group is real -- it is
            -- where a column lands when you tick it back on -- but nothing reads it, so dragging
            -- one was a gesture that appeared to do something and did nothing. It is still
            -- REGISTERED, because the row still counts for indices and still anchors the line: a
            -- shown column dragged down must stop at the rule, and the rule is the first hidden
            -- row's top edge.
            block.mmHandle = list:AddRow(block, {
                draggable      = item.enabled and true or false,
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
