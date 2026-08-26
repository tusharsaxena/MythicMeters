-- tests/test_columns.lua
--
-- settings/Columns.lua — the ONLY place a window's column list can be edited.
--
-- Every other meter lets you drag a column edge in the window itself. This one
-- deliberately cannot: resizing by drag means reading a cell's geometry back
-- (GetWidth, GetLeft, GetPoint), and a cell that has been handed a secret meter
-- value through StatusBar:SetValue has secret geometry from that moment on
-- (design §4, rule R3). So the whole editor lives on a settings page, and that
-- page is what this suite drives.
--
-- IT IS DRIVEN THROUGH THE RENDERED WIDGETS, not through the file's internals.
-- Every mutation in settings/Columns.lua is a file-local reachable only from a
-- widget callback, and that is the honest surface: a control whose onClick is
-- unreachable from a test is a control that ships untested, which is how a page's
-- button once shipped wired to nothing at all.
--
-- The four properties worth the setup:
--
--   * every control really changes the STORED array, and really repaints;
--   * commit() checks the seam's ANSWER. A refusal followed by an unconditional
--     repaint is the worst outcome available: the page redraws from the unchanged
--     array, so the control looks like it did nothing rather than like it failed;
--   * a stat is never OFFERED twice, because NS.SetByPath would refuse it and a
--     picker must not offer a choice the seam would reject;
--   * the width slider's range and the carve-out's validator agree, because the
--     CLI and a hand-edited SavedVariables reach the seam without the slider.

local T = _G.MULTIMETERS_TEST
local test = T.test
local assertEqual, assertTrue, assertFalse = T.assertEqual, T.assertTrue, T.assertFalse

local PANEL = "MultiMetersColumnsPanel"

local function aceGUI(inst) return inst.mocks.__libs["AceGUI-3.0"] end

local function columnsPanel(inst)
    for _, ctx in ipairs(inst.NS.Helpers.__panels()) do
        if ctx.panel and ctx.panel:GetName() == PANEL then return ctx end
    end
    return nil
end

--- Widgets of one AceGUI type, in creation order, out of `list`.
local function byType(list, wtype)
    local out = {}
    for _, w in ipairs(list) do
        if w.type == wtype then out[#out + 1] = w end
    end
    return out
end

--- The columns page, rendered, with its controls sorted into the shape the page
--- draws them in.
---
---   dropdowns  one per column, in order, then the Add picker last
---   sliders    one per column
---   checks     one per column
---   buttons    move-left / move-right / remove per column, then "Add column"
local function controls(inst, ctx, widgets)
    local NS = inst.NS
    local count = #NS.Database.GetWindows()[1].columns
    local dropdowns = byType(widgets, "Dropdown")
    local sliders   = byType(widgets, "Slider")
    local checks    = byType(widgets, "CheckBox")
    local buttons   = byType(widgets, "Button")

    return {
        ctx        = ctx,
        count      = count,
        dropdowns  = dropdowns,
        sliders    = sliders,
        checks     = checks,
        buttons    = buttons,
        addPicker  = dropdowns[count + 1],
        addButton  = buttons[#buttons],
        moveLeft   = function(i) return buttons[(i - 1) * 3 + 1] end,
        moveRight  = function(i) return buttons[(i - 1) * 3 + 2] end,
        remove     = function(i) return buttons[(i - 1) * 3 + 3] end,
    }
end

--- Load the addon, show the Columns page and hand back its live controls.
local function openPage(inst)
    inst = inst or T.load()
    local ctx = columnsPanel(inst)
    assertTrue(ctx ~= nil, "the Columns page did not register a panel")
    local before = #aceGUI(inst).__created
    ctx.panel:Hide()
    ctx.panel:Show()
    assertTrue(ctx._rendered, "the Columns page did not render; H.Relayout or H.ActionDropdown "
        .. "may be missing, in which case the renderer raised and was swallowed by pcall")
    return inst, controls(inst, ctx, (function()
        local created, out = aceGUI(inst).__created, {}
        for i = before + 1, #created do out[#out + 1] = created[i] end
        return out
    end)())
end

--- Re-render the open page and re-read its controls. Every mutation repaints, so
--- a widget captured before one is stale by definition.
local function repaint(inst, ctx)
    local before = #aceGUI(inst).__created
    inst.NS.Helpers.RefreshAllPanels()
    local created, out = aceGUI(inst).__created, {}
    for i = before + 1, #created do out[#out + 1] = created[i] end
    return controls(inst, ctx, out)
end

local function storedColumns(inst)
    return inst.NS.Database.GetWindows()[1].columns
end

local function statKeys(inst)
    local keys = {}
    for i, c in ipairs(storedColumns(inst)) do keys[i] = c.stat end
    return keys
end

-- ---------------------------------------------------------------------------
-- The page draws what is stored
-- ---------------------------------------------------------------------------

test("Columns: the page renders one control set per stored column", function()
    local inst, ui = openPage()
    local cols = storedColumns(inst)
    assertEqual(ui.count, #cols)
    assertTrue(ui.count >= 3, "the shipped window has six default columns")

    assertEqual(#ui.sliders, ui.count, "one width slider per column")
    assertEqual(#ui.checks, ui.count, "one show-bar checkbox per column")
    assertEqual(#ui.dropdowns, ui.count + 1, "one stat picker per column, plus the Add picker")
    assertEqual(#ui.buttons, ui.count * 3 + 1, "move/move/remove per column, plus Add column")

    for i, c in ipairs(cols) do
        assertEqual(ui.dropdowns[i].value, c.stat)
        assertEqual(ui.sliders[i].value, c.width)
        assertEqual(ui.checks[i].value, c.showBar)
    end
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

test("Columns: the first column cannot move left and the last cannot move right", function()
    local _, ui = openPage()
    assertTrue(ui.moveLeft(1).disabled, "there is nothing to the left of column 1")
    assertFalse(ui.moveLeft(2).disabled)
    assertTrue(ui.moveRight(ui.count).disabled)
    assertFalse(ui.moveRight(1).disabled)
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

-- ---------------------------------------------------------------------------
-- Each control really changes the stored array, and really repaints
-- ---------------------------------------------------------------------------

test("Columns: the width slider writes the stored width and repaints", function()
    local inst, ui = openPage()
    local repaints = 0
    local real = inst.NS.RefreshOptionsPanel
    inst.NS.RefreshOptionsPanel = function() repaints = repaints + 1; return real() end

    ui.sliders[2]:__fire("OnMouseUp", 137)
    inst.NS.RefreshOptionsPanel = real

    assertEqual(storedColumns(inst)[2].width, 137)
    assertEqual(repaints, 1, "the page's SHAPE is driven by this array; it must repaint")
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

test("Columns: the show-bar checkbox writes the stored flag as a real boolean", function()
    local inst, ui = openPage()
    assertEqual(storedColumns(inst)[1].showBar, true)

    ui.checks[1]:__fire("OnValueChanged", false)
    assertEqual(storedColumns(inst)[1].showBar, false)

    ui = repaint(inst, ui.ctx)
    assertEqual(ui.checks[1].value, false, "the repainted page must show what was stored")

    ui.checks[1]:__fire("OnValueChanged", true)
    assertEqual(storedColumns(inst)[1].showBar, true)
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

test("Columns: the stat dropdown re-points a column at another statistic", function()
    local inst, ui = openPage()
    local before = statKeys(inst)
    -- Absorbs ships disabled, so it is free and the picker offers it.
    ui.dropdowns[1]:__fire("OnValueChanged", "Absorbs")

    local after = statKeys(inst)
    assertEqual(after[1], "Absorbs")
    assertEqual(#after, #before, "re-pointing a column must not add or remove one")
    for i = 2, #before do assertEqual(after[i], before[i]) end
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

test("Columns: Move left swaps a column with its neighbour", function()
    local inst, ui = openPage()
    local before = statKeys(inst)

    ui.moveLeft(2).callbacks["OnClick"]()

    local after = statKeys(inst)
    assertEqual(after[1], before[2])
    assertEqual(after[2], before[1])
    assertEqual(#after, #before)
    for i = 3, #before do assertEqual(after[i], before[i], "column " .. i .. " must not move") end
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

test("Columns: Move right swaps a column with its neighbour", function()
    local inst, ui = openPage()
    local before = statKeys(inst)

    ui.moveRight(1).callbacks["OnClick"]()

    local after = statKeys(inst)
    assertEqual(after[1], before[2])
    assertEqual(after[2], before[1])
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

test("Columns: Remove drops exactly that column", function()
    local inst, ui = openPage()
    local before = statKeys(inst)

    ui.remove(2).callbacks["OnClick"]()

    local after = statKeys(inst)
    assertEqual(#after, #before - 1)
    assertEqual(after[1], before[1])
    assertEqual(after[2], before[3], "removing column 2 must close the gap, not blank it")
    for _, key in ipairs(after) do
        assertTrue(key ~= before[2], before[2] .. " is still in the array")
    end
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

test("Columns: the last column cannot be removed", function()
    local inst = T.load()
    -- Down to one column through the seam, then render: with one column left the
    -- Remove button is disabled AND the mutation itself refuses, because a window
    -- with nothing but names in it reads as a broken addon.
    assertTrue(inst.NS.SetByPath("window.columns",
        { { stat = "DamageDone", width = 92, showBar = true } }))

    local _, ui = openPage(inst)
    assertEqual(ui.count, 1)
    assertTrue(ui.remove(1).disabled, "the control must be disabled at one column")

    local chatBefore = #inst.mocks.__chat
    ui.remove(1).callbacks["OnClick"]()
    assertEqual(#storedColumns(inst), 1, "the last column was removed")
    assertTrue(#inst.mocks.__chat > chatBefore, "the refusal must be explained")
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

test("Columns: Add appends the picked statistic, sized from the catalog", function()
    local inst, ui = openPage()
    local before = statKeys(inst)

    ui.addPicker:__fire("OnValueChanged", "Absorbs")
    ui.addButton.callbacks["OnClick"]()

    local cols = storedColumns(inst)
    assertEqual(#cols, #before + 1)
    assertEqual(cols[#cols].stat, "Absorbs", "a new column goes on the RIGHT")
    assertEqual(cols[#cols].width, inst.NS.Constants.STAT_BY_KEY["Absorbs"].defaultWidth,
        "the width comes from the catalog, so a new stat arrives sized for its own magnitude")
    assertEqual(cols[#cols].showBar, true)
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

test("Columns: Add with nothing picked does nothing", function()
    local inst, ui = openPage()
    local before = #storedColumns(inst)
    ui.addButton.callbacks["OnClick"]()
    assertEqual(#storedColumns(inst), before)
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

-- ---------------------------------------------------------------------------
-- A stat is never offered twice
-- ---------------------------------------------------------------------------

test("Columns: the Add picker offers only statistics not already shown", function()
    local inst, ui = openPage()
    local used = {}
    for _, c in ipairs(storedColumns(inst)) do used[c.stat] = true end

    local offered = ui.addPicker.list
    assertEqual(type(offered), "table")
    local n = 0
    for key in pairs(offered) do
        n = n + 1
        assertFalse(used[key], key .. " is already a column and must not be offered again")
    end
    assertEqual(n, #inst.NS.Constants.STATS - #storedColumns(inst))
    assertTrue(n > 0, "the shipped window leaves three statistics free")
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

test("Columns: a column's own picker offers the free stats PLUS the one it shows", function()
    local inst, ui = openPage()
    local cols = storedColumns(inst)
    local mine = cols[1].stat

    local offered = ui.dropdowns[1].list
    assertTrue(offered[mine] ~= nil,
        "a control that omitted its own value would open with nothing selected")
    for i = 2, #cols do
        assertEqual(offered[cols[i].stat], nil,
            cols[i].stat .. " is shown by another column and must not be offered here")
    end
    assertEqual(ui.dropdowns[1].value, mine)
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

test("Columns: the Add section says so rather than offering an empty picker", function()
    local inst = T.load()
    -- Every statistic in the catalog, at once.
    local all = {}
    for i, stat in ipairs(inst.NS.Constants.STATS) do
        all[i] = { stat = stat.key, width = stat.defaultWidth or 80, showBar = true }
    end
    assertTrue(inst.NS.SetByPath("window.columns", all))

    local _, ui = openPage(inst)
    assertEqual(#ui.dropdowns, ui.count,
        "no Add picker should be drawn when nothing is left to add")
    assertEqual(#ui.buttons, ui.count * 3, "and no Add button either")
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

test("Columns: the picker never offers a choice NS.SetByPath would refuse", function()
    -- The invariant from the other side: whatever the Add picker offers must
    -- actually be writable, or the control is a trap.
    local inst, ui = openPage()
    for key in pairs(ui.addPicker.list) do
        local cols = {}
        for i, c in ipairs(storedColumns(inst)) do
            cols[i] = { stat = c.stat, width = c.width, showBar = c.showBar }
        end
        cols[#cols + 1] = { stat = key, width = 80, showBar = true }
        local ok, err = inst.NS.SetByPath("window.columns", cols)
        assertTrue(ok, "the picker offers " .. key .. " but the seam refuses it: " .. tostring(err))
    end
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

-- ---------------------------------------------------------------------------
-- commit() checks the seam's answer
-- ---------------------------------------------------------------------------

test("Columns: a refused write is REPORTED and the page is not repainted", function()
    local inst, ui = openPage()
    local repaints = 0
    local realRefresh = inst.NS.RefreshOptionsPanel
    local realSet     = inst.NS.SetByPath
    inst.NS.RefreshOptionsPanel = function() repaints = repaints + 1 end
    inst.NS.SetByPath = function() return false, "the seam said no" end

    local chatBefore = #inst.mocks.__chat
    ui.sliders[1]:__fire("OnMouseUp", 120)

    inst.NS.RefreshOptionsPanel = realRefresh
    inst.NS.SetByPath = realSet

    assertEqual(repaints, 0,
        "repainting after a refusal redraws the UNCHANGED array, so the control looks like "
        .. "it did nothing rather than like it failed")
    local said = table.concat(inst.mocks.__chat, "\n", chatBefore + 1, #inst.mocks.__chat)
    assertTrue(said:find("the seam said no", 1, true) ~= nil,
        "the seam's own reason must be printed, got: " .. said)
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

test("Columns: an accepted write IS repainted", function()
    -- The other half of the case above: without this, "never repaints" would pass
    -- it just as happily.
    local inst, ui = openPage()
    local repaints = 0
    local real = inst.NS.RefreshOptionsPanel
    inst.NS.RefreshOptionsPanel = function() repaints = repaints + 1 end
    ui.sliders[1]:__fire("OnMouseUp", 120)
    inst.NS.RefreshOptionsPanel = real
    assertEqual(repaints, 1)
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

test("Columns: every mutation goes through NS.SetByPath, never straight into the profile", function()
    local inst, ui = openPage()
    local paths = {}
    local real = inst.NS.SetByPath
    inst.NS.SetByPath = function(path, value)
        paths[#paths + 1] = path
        return real(path, value)
    end

    ui.sliders[1]:__fire("OnMouseUp", 120)
    ui = repaint(inst, ui.ctx)
    ui.checks[1]:__fire("OnValueChanged", false)
    ui = repaint(inst, ui.ctx)
    ui.moveRight(1).callbacks["OnClick"]()
    ui = repaint(inst, ui.ctx)
    ui.remove(1).callbacks["OnClick"]()

    inst.NS.SetByPath = real

    assertEqual(#paths, 4, "one seam call per mutation")
    for _, path in ipairs(paths) do
        assertEqual(path, "window.columns",
            "a direct table write would be a second seam that looks identical and announces nothing")
    end
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

test("Columns: the stored array is never the page's own working copy", function()
    local inst, ui = openPage()
    ui.sliders[1]:__fire("OnMouseUp", 120)
    local first = storedColumns(inst)
    ui = repaint(inst, ui.ctx)
    ui.sliders[1]:__fire("OnMouseUp", 130)
    assertTrue(storedColumns(inst) ~= first,
        "the seam rebuilds the array entry by entry, so each write installs a fresh table")
    assertEqual(first[1].width, 120, "the previous array must not have been mutated in place")
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

-- ---------------------------------------------------------------------------
-- Combat
-- ---------------------------------------------------------------------------

test("Columns: no mutation is applied under combat lockdown", function()
    local inst, ui = openPage()
    local before = storedColumns(inst)[1].width
    inst.mocks.setRestricted(true)

    local chatBefore = #inst.mocks.__chat
    ui.sliders[1]:__fire("OnMouseUp", 200)

    assertEqual(storedColumns(inst)[1].width, before,
        "adding or resizing a column mid-pull rebuilds frames whose cells hold secret values")
    assertTrue(#inst.mocks.__chat > chatBefore, "the refusal must be explained")

    inst.mocks.setRestricted(false)
    ui.sliders[1]:__fire("OnMouseUp", 200)
    assertEqual(storedColumns(inst)[1].width, 200, "and it works again once combat drops")
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

-- ---------------------------------------------------------------------------
-- The width range, stated twice and checked against itself
-- ---------------------------------------------------------------------------

test("Columns: the width slider's range matches the carve-out's validator", function()
    local inst, ui = openPage()
    for i, s in ipairs(ui.sliders) do
        assertEqual(s.min, 24, "slider " .. i .. " floor")
        assertEqual(s.max, 240, "slider " .. i .. " ceiling")
        assertEqual(s.step, 1)
    end

    local function write(width)
        return (inst.NS.SetByPath("window.columns",
            { { stat = "DamageDone", width = width, showBar = true } }))
    end
    assertTrue(write(ui.sliders[1].min), "the slider's floor must be a writable width")
    assertTrue(write(ui.sliders[1].max), "the slider's ceiling must be a writable width")
    assertFalse(write(ui.sliders[1].min - 1))
    assertFalse(write(ui.sliders[1].max + 1))
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

test("Columns: a width the slider can produce is never refused by the seam", function()
    local inst, ui = openPage()
    local s = ui.sliders[1]
    for width = s.min, s.max, s.step * 12 do
        local ok, err = inst.NS.SetByPath("window.columns",
            { { stat = "DamageDone", width = width, showBar = true } })
        assertTrue(ok, "the slider can produce " .. width .. " but the seam refused: " .. tostring(err))
    end
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")

-- ---------------------------------------------------------------------------
-- A column whose stat this build does not have
-- ---------------------------------------------------------------------------

test("Columns: a stat from a newer build is still LISTED so the player can remove it", function()
    local inst = T.load()
    -- Written past the seam on purpose: this is a profile carried back from a
    -- build that had a statistic this one does not, which is exactly the shape
    -- NS.SetByPath refuses and the editor must nevertheless display.
    local w = inst.NS.Database.GetWindows()[1]
    w.columns = {
        { stat = "DamageDone", width = 92, showBar = true },
        { stat = "FutureStat", width = 80, showBar = true },
    }

    local _, ui = openPage(inst)
    assertEqual(ui.count, 2, "the renderer drops an unknown column; the EDITOR must not hide it")
    local headings = 0
    for _, widget in ipairs(ui.buttons) do
        if widget.text == inst.NS.L["Remove column"] then headings = headings + 1 end
    end
    assertEqual(headings, 2, "both columns need a Remove button, including the unknown one")
end, "the Columns page is being rebuilt as tick-and-drag blocks; these cases describe the width slider, the show-bar checkbox and the add/remove/move buttons, none of which the page still has. Rewritten in Task 4 of docs/superpowers/plans/2026-08-27-columns-page-blocks.md")
