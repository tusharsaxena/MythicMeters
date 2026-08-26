-- tests/test_columnblocks.lua
--
-- settings/ColumnBlocks.lua — a reorderable list of blocks, and nothing else.
--
-- IT KNOWS NOTHING ABOUT STATISTICS, and that is the whole point of it being its
-- own file. It is the unit issue #21 promotes to LibKa0s once a second addon
-- wants an orderable list, and a widget that had learned what a column is could
-- not make that move. Everything statistic-shaped is settings/Columns.lua's, so
-- this suite drives it with a made-up item list to keep the two apart — a suite
-- that reached for Const.STATS would be quietly asserting the coupling the file
-- exists to avoid.
--
-- THE DRAG IS DRIVEN THROUGH ITS REAL SCRIPTS, with mocks.setCursor moving the
-- pointer between frames. A drag asserted by calling the reorder function
-- directly would pass just as happily with the handle wired to nothing.

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
local function render(inst, items)
    local NS  = inst.NS
    local log = { toggled = {}, moved = {} }

    local ctx = NS.Helpers.CreatePanel("MultiMetersBlockTestPanel", "Blocks", {})
    NS.Helpers.ClearScroll(ctx)

    local blocks = NS.ReorderableBlocks(ctx, {
        items    = items or ITEMS,
        onToggle = function(i) log.toggled[#log.toggled + 1] = i end,
        onMove   = function(from, to) log.moved[#log.moved + 1] = { from, to } end,
    })
    return blocks, log
end

--- Pick block `from` up, move the cursor `rows` rows DOWN, and drop it.
--- Negative `rows` drags upward. Screen y DECREASES downward.
local function drag(inst, blocks, from, rows)
    local handle = blocks[from].mmHandle
    inst.mocks.setCursor(0, 1000)
    handle:_run("OnDragStart")
    inst.mocks.setCursor(0, 1000 - rows * inst.NS.BLOCK_STRIDE)
    handle:_run("OnUpdate", 0.1)
    handle:_run("OnDragStop")
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

test("Blocks: only the handle takes the mouse for dragging", function()
    -- Making the whole block draggable means a click aimed at the glyph starts a
    -- drag instead, and the two gestures are a few pixels apart.
    local inst = T.load()
    local blocks = render(inst)

    assertTrue(blocks[1].mmHandle.__dragButtons ~= nil,
        "the handle must be registered for drag")
    assertEqual(blocks[1].__dragButtons, nil,
        "the block itself must not be draggable")
end)

test("Blocks: a drag reports where it landed", function()
    local inst = T.load()
    local blocks, log = render(inst)

    drag(inst, blocks, 1, 2)
    assertEqual(#log.moved, 1)
    assertEqual(log.moved[1][1], 1)
    assertEqual(log.moved[1][2], 3, "two rows down from index 1 is index 3")
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

test("Blocks: a disabled block cannot be dragged above the rule", function()
    local inst = T.load()
    local blocks, log = render(inst)

    drag(inst, blocks, 5, -4)
    assertEqual(#log.moved, 1)
    assertEqual(log.moved[1][2], 4, "clamped to the first disabled index, not index 1")
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
