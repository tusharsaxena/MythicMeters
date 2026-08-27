-- tests/test_columnblocks.lua
--
-- settings/ColumnBlocks.lua — the ROW of a reorderable list, and its wiring.
--
-- IT KNOWS NOTHING ABOUT STATISTICS, which is why it is its own file and why
-- this suite drives it with a made-up item list. A suite that reached for
-- Const.STATS would be quietly asserting the coupling the file exists to avoid;
-- everything statistic-shaped is settings/Columns.lua's.
--
-- THE GESTURE ITSELF IS NOT TESTED HERE ANY MORE. It belongs to
-- LibKa0s-Widgets-1.0's ReorderList since minor 8 -- the handle, the carried
-- copy, the insertion line, the clamp -- and LibKa0s' own tests/test_widgets.lua
-- covers it once for every consumer. Re-asserting it here would be two suites
-- claiming the same thing, and one of them going stale.
--
-- What is left is what this file owns: the row, and the wiring. Drags still run
-- through their real scripts, because the WIRING is what is under test -- a
-- boundary passed from the wrong end, or a controller nobody cancels, both look
-- exactly like a working list right up until you drag one.

local T = _G.MULTIMETERS_TEST
local test = T.test
local assertEqual, assertTrue, assertFalse = T.assertEqual, T.assertTrue, T.assertFalse

local ITEMS = {
    { key = "a", label = "Alpha",   enabled = true  },
    { key = "b", label = "Bravo",   enabled = true  },
    { key = "c", label = "Charlie", enabled = true  },
    { key = "d", label = "Delta",   enabled = false },
    { key = "e", label = "Echo",    enabled = false },
}

--- A rendered block list, plus a log of what it asked its host for.
---
--- `ctx` is optional and is how the recycling cases are written: passing the SAME
--- context back re-renders into the same scroll, which is what makes AceGUI hand
--- the same pooled SimpleGroups over and the raw blocks on them come back. A
--- fresh panel per render would never pool anything, and the stacking bug this
--- widget was rebuilt for would be invisible.
local function render(inst, items, ctx)
    local NS  = inst.NS
    local log = { toggled = {}, moved = {} }

    ctx = ctx or NS.Helpers.CreatePanel("MultiMetersBlockTestPanel", "Blocks", {})
    -- Exactly what settings/Columns.lua's render does, and in that order: cancel, THEN clear. A
    -- helper that skipped the cancel would be testing a page nobody ships.
    if NS.CancelReorder then NS.CancelReorder(ctx) end
    NS.Helpers.ClearScroll(ctx)

    local blocks = NS.ReorderableBlocks(ctx, {
        items    = items or ITEMS,
        onToggle = function(i) log.toggled[#log.toggled + 1] = i end,
        onMove   = function(from, to) log.moved[#log.moved + 1] = { from, to } end,
    })
    return blocks, log, ctx
end

--- Pick block `from` up, move the cursor `rows` rows DOWN, and release.
--- Negative `rows` drags upward. Screen y DECREASES downward.
---
--- Driven the way the client drives it: press, move, let go. The drop is decided
--- by the OnUpdate that first sees the button released, not by a separate
--- OnDragStop -- which is the whole reason the widget stopped using
--- RegisterForDrag.
local function drag(inst, blocks, from, rows)
    local block  = blocks[from]
    local handle = block.mmHandle

    inst.mocks.setMouseDown("LeftButton", true)
    inst.mocks.setCursor(0, 1000)
    handle:_run("OnMouseDown")

    inst.mocks.setCursor(0, 1000 - rows * inst.NS.BLOCK_STRIDE)
    block:_run("OnUpdate", 0.1)

    inst.mocks.setMouseDown("LeftButton", false)
    block:_run("OnUpdate", 0.1)
end

test("Blocks: one block per item, each carrying its index and its label", function()
    local inst = T.load()
    local blocks = render(inst)

    assertEqual(#blocks, #ITEMS)
    for i, item in ipairs(ITEMS) do
        assertEqual(blocks[i].mmIndex, i)
        assertEqual(blocks[i].mmLabel:GetText(), item.label)
    end
end)

test("Blocks: the glyph says enabled or disabled, and clicking it toggles", function()
    local inst = T.load()
    local blocks, log = render(inst)

    assertFalse(blocks[1].mmGlyphTexture == blocks[4].mmGlyphTexture,
        "an enabled block and a disabled one must not wear the same glyph")

    blocks[4].mmGlyph:_run("OnClick")
    assertEqual(#log.toggled, 1)
    assertEqual(log.toggled[1], 4, "the glyph must report ITS OWN index")
end)

test("Blocks: a slot owns exactly ONE block, cached on the slot itself", function()
    -- THE CACHE IS THE FIX FOR THE STACKING BUG, and this asserts the mechanism
    -- because the bug itself is not reachable offline.
    --
    -- In game, H.ClearScroll calls AceGUI's ReleaseChildren, the SimpleGroups go
    -- back to AceGUI's pool, and the NEXT render is handed the same `slot.frame`
    -- with the previous render's raw children still parented to it and still
    -- shown. Building a second block there stacked two labels and two glyphs on
    -- top of each other -- "DamageDeaths", a tick with a cross through it -- and
    -- every repaint added another layer. AceGUI cannot clean them up, because
    -- they are CreateFrame children rather than AceGUI widgets.
    --
    -- THE HARNESS DOES NOT RECYCLE: a probe confirms AceGUI hands back a fresh
    -- widget AND a fresh frame after ReleaseChildren here, so a test that
    -- re-rendered and compared blocks would pass whether the cache existed or
    -- not. What is checkable is that the block is stored ON its slot, which is
    -- what makes the second render find it instead of building another. The
    -- stacking itself is smoke test 5's job.
    -- red under: blockFor building a fresh frame instead of caching on the slot.
    local inst = T.load()
    local blocks = render(inst)

    for i, block in ipairs(blocks) do
        local slot = block:GetParent()
        assertTrue(slot ~= nil, "block " .. i .. " has no parent slot")
        assertEqual(slot.mmBlock, block,
            "block " .. i .. " is not cached on its slot, so a recycled slot "
            .. "would grow a second block over this one")
    end
end)

test("Blocks: a reused block reports the index it now carries, not the one it was built with", function()
    -- The other half of the stacking bug. Every script reads block.mmIndex at
    -- FIRE time; a closure over the index it was wired with meant the glyph you
    -- could see belonged to the newest block while the click it delivered carried
    -- an older render's index -- so ticking one statistic toggled a different one.
    -- red under: glyph:SetScript closing over `index`.
    local inst = T.load()
    local _, _, ctx = render(inst)

    -- Same slots, ITEMS reversed, so every block now carries a different index.
    local reversed = {}
    for i = #ITEMS, 1, -1 do reversed[#reversed + 1] = ITEMS[i] end
    local blocks, log = render(inst, reversed, ctx)

    blocks[1].mmGlyph:_run("OnClick")
    assertEqual(log.toggled[1], 1, "the block reported a stale index")
    assertEqual(blocks[1].mmLabel:GetText(), reversed[1].label,
        "and it must be showing the item that index now names")
end)

test("Blocks: a drag reports where it landed", function()
    local inst = T.load()
    local blocks, log = render(inst)

    drag(inst, blocks, 1, 2)
    assertEqual(#log.moved, 1)
    assertEqual(log.moved[1][1], 1)
    assertEqual(log.moved[1][2], 3, "two rows down from index 1 is index 3")
end)

test("Blocks: the page hands LibKa0s the boundary, so a shown column stops at the rule", function()
    -- THE CLAMP IS THE LIBRARY'S; passing it the right divide is this file's. A shown column may
    -- not be dragged among the hidden ones -- the tick is what moves a block between them, and a
    -- drag that crossed would have to silently turn a column off.
    -- red under: boundary not passed, or counted from the wrong end.
    local inst = T.load()
    local blocks, log = render(inst)   -- ITEMS is three enabled, then two disabled

    drag(inst, blocks, 1, 4)
    assertEqual(log.moved[1][2], 3, "an enabled block stopped somewhere other than the divide")
end)

test("Blocks: a hidden column has no handle, because its order means nothing", function()
    -- The hidden group HAS an order -- it is where a column lands when you tick it back on -- but
    -- nothing reads it, so dragging one was a gesture that appeared to do something and did not.
    --
    -- The row is still REGISTERED with the library, which is why the case checks both halves: drop
    -- the registration and the indices shift, and the rule a shown column clamps against is the
    -- first hidden row's own top edge.
    -- red under: draggable not passed, or the hidden rows not registered at all.
    local inst = T.load()
    local blocks = render(inst)

    assertTrue(blocks[1].mmHandle ~= nil, "a shown column must be draggable")
    assertTrue(blocks[3].mmHandle ~= nil, "the last shown column too")
    assertEqual(blocks[4].mmHandle, nil, "a hidden column must not offer a handle")
    assertEqual(blocks[5].mmHandle, nil)
end)

test("Blocks: a repaint cancels the controller the render before it built", function()
    -- A drag must not outlive the list it was describing. The chrome it leaves on screen -- the
    -- carried copy, the insertion line -- names rows that may not be there any more, and putting
    -- it away is the library's job once this file says the list is gone.
    -- red under: ReorderableBlocks not calling Cancel on ctx.mmReorder.
    local inst = T.load()
    local blocks, _, ctx = render(inst)

    inst.mocks.setMouseDown("LeftButton", true)
    inst.mocks.setCursor(0, 1000)
    blocks[1].mmHandle:_run("OnMouseDown")

    local before = ctx.mmReorder
    assertTrue(before ~= nil, "no controller was built")

    render(inst, nil, ctx)
    assertTrue(before.dead, "the previous render's controller was left live")
    assertFalse(ctx.mmReorder == before, "a repaint must build a fresh controller")
end)

test("Blocks: a drag that lands where it started reports nothing", function()
    -- Reporting it would rewrite the array and repaint the page for no change.
    local inst = T.load()
    local blocks, log = render(inst)

    drag(inst, blocks, 2, 0)
    assertEqual(#log.moved, 0, "a drag with no movement is not a reorder")
end)

test("Blocks: an enabled block cannot be dragged past the last enabled one", function()
    -- The tick is what moves a block between groups. A drag that crossed the rule
    -- would have to silently disable it -- a state change from a gesture that
    -- means "move", not "turn off".
    local inst = T.load()
    local blocks, log = render(inst)

    drag(inst, blocks, 1, 4)
    assertEqual(#log.moved, 1)
    assertEqual(log.moved[1][2], 3, "clamped to the last enabled index, not index 5")
end)

test("Blocks: a list with nothing disabled drags end to end", function()
    local inst = T.load()
    local allOn = {}
    for i, item in ipairs(ITEMS) do
        allOn[i] = { key = item.key, label = item.label, enabled = true }
    end
    local blocks, log = render(inst, allOn)

    drag(inst, blocks, 1, 4)
    assertEqual(log.moved[1][2], 5, "with no rule to clamp against, every index is reachable")
end)

test("Blocks: the rule is drawn once, under the last enabled block", function()
    -- It marks where the shown columns stop. A list with nothing disabled has no
    -- boundary to mark, and drawing one would claim a group that is not there.
    local inst = T.load()
    local blocks = render(inst)
    assertEqual(#blocks, #ITEMS, "the rule must not be counted as a block")

    local allOn = {}
    for i, item in ipairs(ITEMS) do
        allOn[i] = { key = item.key, label = item.label, enabled = true }
    end
    local onlyOn = render(inst, allOn)
    assertEqual(#onlyOn, #ITEMS)
end)
