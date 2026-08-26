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

--- The one floating copy of a block, carried under the cursor while dragging.
---
--- A DRAG NEEDS SOMETHING TO FOLLOW THE POINTER OR IT IS NOT A DRAG. The line
--- alone said where a block WOULD land while nothing said one was in your hand,
--- and the log of a working drag looked identical to the log of a broken one from
--- where the player was sitting.
---
--- ONE, ON UIParent, NOT ONE PER BLOCK. It has to escape the ScrollFrame's clip
--- rectangle to follow the cursor past the edge of the list, which a child of the
--- scroll cannot do -- and being a singleton on UIParent also puts it outside
--- AceGUI's pool entirely, so it is the one frame here with no recycling story to
--- get wrong.
---
--- MOUSE DISABLED, and that is load-bearing rather than tidy: a frame under the
--- pointer that accepts the mouse eats the very button-release that ends the drag
--- it is drawing.
local ghost

local function ghostFrame()
    if ghost then return ghost end

    ghost = CreateFrame("Frame", nil, UIParent)
    ghost:SetFrameStrata("TOOLTIP")
    ghost:SetHeight(NS.BLOCK_HEIGHT)
    ghost:SetWidth(300)
    ghost:EnableMouse(false)
    ghost:SetAlpha(0.9)
    ghost:Hide()

    ghost.bg = ghost:CreateTexture(nil, "BACKGROUND")
    ghost.bg:SetAllPoints(ghost)
    ghost.bg:SetColorTexture(0.12, 0.12, 0.12, 0.95)

    ghost.handleTex = ghost:CreateTexture(nil, "ARTWORK")
    ghost.handleTex:SetSize(16, 16)
    ghost.handleTex:SetPoint("LEFT", ghost, "LEFT", 8, 0)
    if NS.Icon then ghost.handleTex:SetTexture(NS.Icon(HANDLE_ICON)) end
    ghost.handleTex:SetVertexColor(1, 0.82, 0)

    ghost.glyph = ghost:CreateTexture(nil, "ARTWORK")
    ghost.glyph:SetSize(18, 18)
    ghost.glyph:SetPoint("LEFT", ghost, "LEFT", 42, 0)

    ghost.label = ghost:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ghost.label:SetPoint("RIGHT", ghost, "RIGHT", -12, 0)
    ghost.label:SetJustifyH("RIGHT")

    NS.__ColumnDragGhost = ghost
    return ghost
end

--- Put the ghost under the cursor. Offset right and up by half a row so the
--- pointer sits ON the thing it is carrying rather than at its corner.
local function moveGhost()
    if not (ghost and ghost:IsShown()) then return end
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    if not (type(x) == "number" and type(y) == "number" and type(scale) == "number") then
        return
    end
    ghost:ClearAllPoints()
    ghost:SetPoint("LEFT", UIParent, "BOTTOMLEFT", (x / scale) + 14, y / scale)
end

--- The one insertion line for this scroll, built once and reused.
---
--- Cached on the content frame for exactly the reason the blocks are: a fresh one
--- per render would pile up on a recycled frame, and nothing would ever take the
--- old ones down.
---
--- A FRAME CARRYING A TEXTURE, not a bare texture, and that is not decoration. A
--- texture belongs to its own frame's draw layers, so one created on `content`
--- draws UNDER every block -- each block is a child frame with its own layers,
--- and a parent's OVERLAY still loses to a child. The line has to be a sibling
--- that outranks them, which means a frame with a raised level.
local function lineFor(content)
    if not content then return nil end
    if content.mmDropLine then return content.mmDropLine end

    local line = CreateFrame("Frame", nil, content)
    line:SetHeight(3)
    -- Guarded on the ANSWER, not just on the method existing: a stub that returns
    -- itself for anything it does not implement answers a table here, and adding
    -- 20 to it takes the whole render down.
    local level = content.GetFrameLevel and content:GetFrameLevel()
    if type(level) == "number" then line:SetFrameLevel(level + 20) end

    local tex = line:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints(line)
    tex:SetColorTexture(1, 0.82, 0, 0.9)

    line:Hide()
    content.mmDropLine = line
    return line
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
        if block.mmLine then block.mmLine:Hide() end
        if ghost then ghost:Hide() end
        block:SetAlpha(1)
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

    --- Put the insertion line where the block would land right now.
    ---
    --- ANCHORED TO THE TARGET BLOCK, never positioned by arithmetic. The index is
    --- computed from the cursor, but WHERE THAT INDEX IS on screen is a question
    --- only the frames can answer -- and anchoring to one asks it without reading
    --- a single coordinate back, which is both simpler than measuring and the
    --- habit rule R3 exists to build.
    ---
    --- IT IS SHOWN EVEN WHEN THE TARGET IS THE BLOCK'S OWN INDEX, and that is the
    --- point of it. A drag clamped at the rule used to end with nothing moved and
    --- nothing said, which is indistinguishable from a drag that never worked --
    --- the line stopping dead at the rule is what tells you the clamp is a rule
    --- rather than a failure.
    local function showLine(to)
        local line, siblings = block.mmLine, block.mmSiblings
        local target = siblings and siblings[to]
        if not (line and target) then return end

        line:ClearAllPoints()
        if to <= block.mmIndex then
            line:SetPoint("BOTTOMLEFT",  target, "TOPLEFT",  0, 0)
            line:SetPoint("BOTTOMRIGHT", target, "TOPRIGHT", 0, 0)
        else
            line:SetPoint("TOPLEFT",  target, "BOTTOMLEFT",  0, 0)
            line:SetPoint("TOPRIGHT", target, "BOTTOMRIGHT", 0, 0)
        end
        line:Show()
    end

    local function track()
        if not block.mmStartY then return end

        local _, y = GetCursorPosition()
        local moved = block.mmStartY - (y / UIParent:GetEffectiveScale())
        -- +0.5 then floor is round-to-nearest: a block dragged 60% of the way to
        -- the next slot has visibly left its own, and rounding down would drop it
        -- back where it started.
        block.mmRows = math.floor(moved / NS.BLOCK_STRIDE + 0.5)

        moveGhost()
        showLine(dropIndex(block.mmIndex, block.mmRows,
            block.mmCount or 1, block.mmBoundary or 0))

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
        -- The block you are carrying fades in the LIST, because the copy under
        -- the cursor is now the one you are looking at.
        block:SetAlpha(0.35)

        -- The copy itself: same glyph, same name, same width as the row it came
        -- from, so what you are carrying reads as that row rather than as a new
        -- widget that appeared. The width is read off the block, which is an
        -- options frame and has never held a meter value -- rule R3 is about
        -- cells that have.
        local g = ghostFrame()
        local w = block.GetWidth and block:GetWidth()
        if type(w) == "number" and w > 0 then g:SetWidth(w) end
        g.glyph:SetTexture(block.mmGlyphTexture)
        g.label:SetText(block.mmLabel:GetText() or "")
        if block.mmEnabled then
            g.label:SetTextColor(1, 0.82, 0)
        else
            g.label:SetTextColor(0.5, 0.5, 0.5)
        end
        g:Show()
        moveGhost()

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
    block.mmEnabled  = item.enabled and true or false
    block:SetAlpha(1)

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
    -- was carrying describe the list as it was before the write. The ghost goes
    -- with it -- a copy left floating over a list that has already changed is
    -- worse than no feedback at all.
    block:SetScript("OnUpdate", nil)
    block.mmStartY = nil
    if ghost then ghost:Hide() end

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

    -- Handed out AFTER the loop, because a block cannot be told about siblings
    -- that do not exist yet. Both are what the drag needs and neither is
    -- knowable while the list is still being built: `mmSiblings` is how the line
    -- finds the frame it should sit against, and `mmLine` is the one texture they
    -- all share.
    local line = lineFor(scroll.content or scroll.frame)
    if line then line:Hide() end
    for _, block in ipairs(blocks) do
        block.mmSiblings = blocks
        block.mmLine     = line
    end

    return blocks
end
