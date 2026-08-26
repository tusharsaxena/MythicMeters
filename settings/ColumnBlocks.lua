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
local HANDLE_ICON  = "segment"

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

--- The one block on `parent`, built the first time and reused forever after.
---
--- REUSED, NOT REBUILT, AND THAT IS THE WHOLE BUG THIS FIXES. H.ClearScroll calls
--- AceGUI's ReleaseChildren, which pools the SimpleGroups -- so the NEXT render
--- gets the same `slot.frame` back with the previous render's raw children still
--- parented to it and still shown. Building a second block on it stacked one over
--- the other: two labels ("DamageDeaths"), two glyphs (a tick with a cross
--- through it), and every repaint added another layer.
---
--- AceGUI cannot clean these up because it does not know about them: they are
--- CreateFrame children, not AceGUI widgets. So the slot owns exactly one block
--- for its whole life, and re-rendering re-points that block instead.
local function blockFor(parent)
    if parent.mmBlock then return parent.mmBlock end

    local block = CreateFrame("Frame", nil, parent)
    block:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    block:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    block:SetHeight(NS.BLOCK_HEIGHT)

    block.bg = block:CreateTexture(nil, "BACKGROUND")
    block.bg:SetAllPoints(block)

    -- ONLY THE HANDLE TAKES THE MOUSE. Making the whole block draggable means a
    -- press aimed at the glyph starts a drag instead, and the two are a few
    -- pixels apart.
    -- FULL BLOCK HEIGHT, not an 18px square. The icon inside it stays small, but
    -- the thing you have to hit to start a drag is the whole left edge of the
    -- row -- an 18px target in a 30px row is a miss most of the time, and a miss
    -- here is indistinguishable from the drag not working.
    local handle = CreateFrame("Button", nil, block)
    handle:SetSize(30, NS.BLOCK_HEIGHT)
    handle:SetPoint("LEFT", block, "LEFT", 2, 0)
    handle:EnableMouse(true)
    handle:RegisterForDrag("LeftButton")
    block.mmHandle = handle

    block.handleTex = handle:CreateTexture(nil, "ARTWORK")
    block.handleTex:SetSize(16, 16)
    block.handleTex:SetPoint("CENTER", handle, "CENTER", 0, 0)
    if NS.Icon then block.handleTex:SetTexture(NS.Icon(HANDLE_ICON)) end
    block.handleTex:SetVertexColor(0.7, 0.7, 0.7)

    local glyph = CreateFrame("Button", nil, block)
    glyph:SetSize(18, 18)
    glyph:SetPoint("LEFT", block, "LEFT", 42, 0)
    glyph:EnableMouse(true)
    block.mmGlyph = glyph

    block.mmLabel = block:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    block.mmLabel:SetPoint("RIGHT", block, "RIGHT", -12, 0)
    block.mmLabel:SetJustifyH("RIGHT")

    -- EVERY SCRIPT READS ITS STATE OFF THE BLOCK AT FIRE TIME, never off an
    -- upvalue captured when it was wired. A closure over `index` was the second
    -- half of the stacking bug: the visible glyph belonged to the newest block
    -- and the click it delivered carried an older render's index, so ticking one
    -- statistic toggled a different one.
    glyph:SetScript("OnClick", function()
        local spec = block.mmSpec
        if spec and spec.onToggle then spec.onToggle(block.mmIndex) end
    end)

    -- ── the drag ───────────────────────────────────────────────────────────
    --
    -- EVERY DELIVERY PATH CAN START IT AND EVERY DELIVERY PATH CAN END IT, and
    -- that redundancy is deliberate rather than lazy. The first two attempts each
    -- picked one pair and each failed in the client while passing offline, so
    -- what is depended on now is "at least one of these arrives" rather than any
    -- particular one:
    --
    --   start   OnMouseDown (immediate) · OnDragStart (after the drag threshold)
    --   end     OnMouseUp · OnDragStop · the poll below
    --
    -- Both helpers are idempotent, so whichever order the client delivers them
    -- in, the drag begins once and completes once.
    --
    -- THE POLL IS THE ONE THAT CANNOT BE TRUSTED ALONE, and that is why it now
    -- has to see the button held BEFORE it may act on it being released. If
    -- IsMouseButtonDown is unavailable or simply answers false on the first
    -- frame, the old code called finish() immediately with zero rows travelled --
    -- which is not an error, not a Lua fault, and indistinguishable from a drag
    -- that never started. `mmSawDown` makes that failure mode impossible: an API
    -- that never answers true can never end a drag, and the two script-driven
    -- enders above carry it instead.
    local function mouseHeld()
        if type(IsMouseButtonDown) ~= "function" then return nil end
        local ok, held = pcall(IsMouseButtonDown, "LeftButton")
        if not ok then return nil end
        return held and true or false
    end

    local function finish()
        block:SetScript("OnUpdate", nil)
        if not block.mmStartY then return end
        block.mmStartY  = nil
        block.mmSawDown = nil

        local to = dropIndex(block.mmIndex, block.mmRows or 0,
            block.mmCount or 1, block.mmBoundary or 0)

        if NS.State and NS.State.debug and NS.Debug then
            NS.Debug("Blocks", "drop %d -> %d (%d rows)",
                block.mmIndex, to, block.mmRows or 0)
        end

        -- A drag that lands where it started is not a reorder, and reporting one
        -- would rewrite the array and repaint the page for no change at all.
        local spec = block.mmSpec
        if to ~= block.mmIndex and spec and spec.onMove then
            spec.onMove(block.mmIndex, to)
        end
    end

    local function track()
        if not block.mmStartY then return end

        local _, y = GetCursorPosition()
        local moved = block.mmStartY - (y / UIParent:GetEffectiveScale())
        -- +0.5 then floor is round-to-nearest: a block dragged 60% of the way to
        -- the next slot has visibly left its own, and rounding down would drop it
        -- back where it started.
        block.mmRows = math.floor(moved / NS.BLOCK_STRIDE + 0.5)

        local held = mouseHeld()
        if held then
            block.mmSawDown = true
        elseif held == false and block.mmSawDown then
            finish()
        end
    end

    local function begin()
        if block.mmStartY then return end
        local _, y = GetCursorPosition()
        block.mmStartY  = y / UIParent:GetEffectiveScale()
        block.mmRows    = 0
        block.mmSawDown = nil
        block:SetScript("OnUpdate", track)

        if NS.State and NS.State.debug and NS.Debug then
            NS.Debug("Blocks", "grab %d at y=%.1f", block.mmIndex, block.mmStartY)
        end
    end

    handle:SetScript("OnMouseDown", begin)
    handle:SetScript("OnDragStart", begin)
    handle:SetScript("OnMouseUp",   finish)
    handle:SetScript("OnDragStop",  finish)

    parent.mmBlock = block
    return block
end

--- Re-point one block at the item now sitting at `index`.
local function applyBlock(block, index, item, spec, count, boundary)
    block.mmIndex    = index
    block.mmSpec     = spec
    block.mmCount    = count
    block.mmBoundary = boundary

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

    -- A drag interrupted by a repaint must not survive it: the indices this block
    -- was carrying describe the list as it was before the write.
    block:SetScript("OnUpdate", nil)
    block.mmStartY = nil

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

        local block = blockFor(slot.frame or slot.content)
        applyBlock(block, i, item, spec, count, boundary)
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
