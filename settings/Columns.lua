-- settings/Columns.lua
--
-- The Columns page: the ordered stat list a window draws, left to right — add,
-- remove, reorder, and per-column width and show-bar.
--
-- ---------------------------------------------------------------------------
-- WHY COLUMN EDITING LIVES HERE AND ONLY HERE
-- ---------------------------------------------------------------------------
--
-- Every other meter lets you drag a column edge in the window itself. This one
-- deliberately does not, and the reason is not effort — it is that the drag
-- editor is unimplementable against this data source (design §6).
--
-- Resizing a column by dragging means reading the cell's current geometry back:
-- GetWidth, GetLeft, GetPoint. A cell that has been handed a secret meter value
-- through StatusBar:SetValue is marked HasSecretValues, and from that moment its
-- own position and size data are secret too, and that propagates to everything
-- anchored to it (design §4). So the read that a drag editor is built out of is
-- exactly the read this addon may never perform on a live cell.
--
-- Confining column management to a settings panel removes the hazard rather
-- than guarding against it: layout is computed from config on the way OUT and
-- never read back on the way IN (design rule R3). There is no code path where a
-- cell's geometry is a question anyone asks.
--
-- The combat guard below is the same rule at the other end. The library already
-- refuses to render a page under lockdown, so this page cannot normally be
-- opened mid-pull — but a panel left open when a pull STARTS is still clickable,
-- and adding a column then would rebuild a frame whose cells are holding secret
-- values. So every mutation re-checks.
--
-- ---------------------------------------------------------------------------
-- WHY THE WRITES GO THROUGH THE SCHEMA SEAM
-- ---------------------------------------------------------------------------
--
-- `window.columns` is an ARRAY, not a scalar, so it is not a widget on any
-- page — but it is still a setting, and settings in this addon have exactly one
-- write seam (NS.SetByPath). Routing through it is what gives a column edit the
-- same debug line, the same CONFIG_CHANGED message and the same window refresh
-- that moving a slider gets. A direct table write here would be a second seam
-- that looks identical and announces nothing.
--
-- Each mutation therefore builds a fresh array from the stored one and hands
-- the whole array over. Mutating the live table in place and then "writing" it
-- would hand the seam a table it already holds, and any change detection it
-- does would correctly conclude that nothing happened.

local addonName, NS = ...

local L     = NS.L
local Const = NS.Constants

local PAGE = "columns"

local H = NS.Helpers or {}

local function print_(line)
    if NS.Print then NS.Print(line) end
end

-- ---------------------------------------------------------------------------
-- Reading the active window's columns
-- ---------------------------------------------------------------------------

local function activeWindow()
    local id = NS.State and NS.State.activeWindowId
    if not (NS.Database and NS.Database.FindWindow) then return nil end
    local w = NS.Database.FindWindow(id)
    if w then return w end
    -- Same healing rule as the Windows page: a stale pointer falls back to the
    -- first window rather than rendering a page with no subject.
    local list = (NS.Database.GetWindows and NS.Database.GetWindows()) or {}
    return list[1]
end

local function columnsOf(w)
    return (w and w.columns) or {}
end

--- A detached copy of the stored column array, safe to mutate before writing.
local function snapshot(w)
    local out = {}
    for i, c in ipairs(columnsOf(w)) do
        out[i] = { stat = c.stat, width = c.width, showBar = c.showBar }
    end
    return out
end

--- The one write. Refuses under lockdown, hands the whole array to the seam,
--- and repaints the panel structurally because the page's SHAPE changed on any
--- add, remove or reorder.
---
--- The seam's ANSWER is checked, not discarded. It validates the array and can
--- legitimately say no (an unknown stat carried in from a newer build, a width
--- outside the slider's range, no window selected), and a refusal followed by an
--- unconditional repaint is the worst possible outcome: the page redraws from the
--- unchanged stored array, so the control looks like it did nothing at all rather
--- than like it failed. Repainting is therefore conditional on success, and the
--- reason is printed.
local function commit(cols)
    if InCombatLockdown and InCombatLockdown() then
        print_(L["Columns cannot be changed during combat."])
        return false
    end
    if not NS.SetByPath then return false end

    local ok, err = NS.SetByPath("window.columns", cols)
    if not ok then
        print_(err or L["That column change could not be applied."])
        return false
    end

    if NS.RefreshOptionsPanel then NS.RefreshOptionsPanel() end
    return true
end

-- ---------------------------------------------------------------------------
-- Mutations
-- ---------------------------------------------------------------------------

-- Each mutation ANSWERS with the seam's verdict rather than swallowing it, so a
-- caller (and a test) can tell an applied edit from a refused one.

local function setField(index, field, value)
    local w = activeWindow()
    if not w then return false end
    local cols = snapshot(w)
    if not cols[index] then return false end
    cols[index][field] = value
    return commit(cols)
end

local function moveColumn(index, delta)
    local w = activeWindow()
    if not w then return false end
    local cols   = snapshot(w)
    local target = index + delta
    if not (cols[index] and cols[target]) then return false end
    cols[index], cols[target] = cols[target], cols[index]
    return commit(cols)
end

local function removeColumn(index)
    local w = activeWindow()
    if not w then return false end
    local cols = snapshot(w)
    -- A window with no columns is a window with nothing but names in it, which
    -- reads as a broken addon rather than as a configuration.
    if #cols <= 1 then
        print_(L["A window must keep at least one column."])
        return false
    end
    if not cols[index] then return false end
    tremove(cols, index)
    return commit(cols)
end

local function addColumn(statKey)
    local stat = statKey and Const.STAT_BY_KEY[statKey]
    if not stat then return false end
    local w = activeWindow()
    if not w then return false end
    local cols = snapshot(w)
    -- Width and show-bar come from the catalog rather than from a fixed number,
    -- so a stat added to core/Constants.lua arrives sized for the text the
    -- formatter produces at its magnitude with no edit here.
    cols[#cols + 1] = { stat = stat.key, width = stat.defaultWidth or 80, showBar = true }
    return commit(cols)
end

-- ---------------------------------------------------------------------------
-- Option lists
-- ---------------------------------------------------------------------------

--- The stats not already shown, plus `keep` if it is given. Labels are localized
--- AT THE USE SITE — core/Constants.lua stores the English label and deliberately
--- does not call L itself, because locales/ may load either side of it.
---
--- A stat can appear once: two Damage columns would show identical numbers twice
--- and double the provider reads for it. That is an invariant NS.SetByPath now
--- enforces, so the pickers must not offer a choice it would refuse — which is
--- what `keep` is for. A column's own stat dropdown has to list the stat that
--- column already shows, or the control would open with nothing selected.
---
--- @param w table|nil
--- @param keep string|nil
--- @return table list, table order, number count
local function unusedStatList(w, keep)
    local used = {}
    for _, c in ipairs(columnsOf(w)) do used[c.stat] = true end

    local list, order = {}, {}
    for _, stat in ipairs(Const.STATS) do
        if not used[stat.key] or stat.key == keep then
            list[stat.key]    = L[stat.label]
            order[#order + 1] = stat.key
        end
    end
    return list, order, #order
end

-- Which stat the Add picker is pointed at. Page state: it means nothing outside
-- an open panel, so it is neither a schema row nor a stored value.
local pendingStat = nil

-- ---------------------------------------------------------------------------
-- Per-column widgets
-- ---------------------------------------------------------------------------

local function makeStatDropdown(index, current)
    return function(_, parent, relativeWidth)
        if not H.ActionDropdown then return nil end
        -- Built at RENDER time, not at declaration: which stats are free depends
        -- on the array as it stands now, and this closure outlives the edit that
        -- changed it.
        local list, order = unusedStatList(activeWindow(), current)
        return H.ActionDropdown(parent, relativeWidth, {
            label    = L["Statistic"],
            tooltip  = L["Which statistic this column shows."],
            list     = list,
            order    = order,
            value    = current,
            onSelect = function(key) setField(index, "stat", key) end,
        })
    end
end

local function makeWidthSlider(index, current)
    return function(_, parent, relativeWidth)
        local AceGUI = NS.AceGUI
        if not (AceGUI and parent) then return nil end

        local sl = AceGUI:Create("Slider")
        sl:SetLabel(L["Column width"])
        sl:SetRelativeWidth(relativeWidth or 1)
        sl:SetSliderValues(24, 240, 1)
        sl:SetValue(current or 80)
        -- Release-only, never OnValueChanged: a width write rebuilds the window
        -- and re-renders this page, and doing that per drag frame would tear the
        -- slider out from under the cursor.
        sl:SetCallback("OnMouseUp", function(_, _, value)
            setField(index, "width", value)
        end)
        if H.AttachTooltip then
            H.AttachTooltip(sl, L["Column width"], L["Width of this column in pixels."])
        end
        parent:AddChild(sl)
        return sl
    end
end

local function makeShowBarCheckbox(index, current)
    return function(_, parent, relativeWidth)
        local AceGUI = NS.AceGUI
        if not (AceGUI and parent) then return nil end

        local cb = AceGUI:Create("CheckBox")
        cb:SetLabel(L["Show bar"])
        cb:SetRelativeWidth(relativeWidth or 1)
        cb:SetValue(current and true or false)
        cb:SetCallback("OnValueChanged", function(_, _, value)
            setField(index, "showBar", value and true or false)
        end)
        if H.AttachTooltip then
            H.AttachTooltip(cb, L["Show bar"],
                L["Draw a bar behind this column's number. Turn it off for a numbers-only column."])
        end
        parent:AddChild(cb)
        return cb
    end
end

--- Move left / move right / remove, three across one full-width row.
---
--- Not InlineButtonPair, which is a PAIR by construction. Three buttons in a
--- Flow group is the smallest thing that says "this column's actions" without
--- splitting one column's controls over two visually unrelated rows.
local function makeColumnActions(index, count)
    return function(_, parent)
        local AceGUI = NS.AceGUI
        if not (AceGUI and parent) then return nil end

        local row = AceGUI:Create("SimpleGroup")
        row:SetLayout("Flow")
        row:SetFullWidth(true)
        row:SetHeight(28)

        local function button(text, tooltip, enabled, onClick)
            local btn = AceGUI:Create("Button")
            btn:SetText(text)
            btn:SetRelativeWidth(0.32)
            btn:SetDisabled(not enabled)
            btn:SetCallback("OnClick", function() pcall(onClick) end)
            if H.AttachTooltip then H.AttachTooltip(btn, text, tooltip) end
            row:AddChild(btn)
        end

        button(L["Move left"], L["Move left"], index > 1,
            function() moveColumn(index, -1) end)
        button(L["Move right"], L["Move right"], index < count,
            function() moveColumn(index, 1) end)
        button(L["Remove column"], L["Remove this column from the window."], count > 1,
            function() removeColumn(index) end)

        parent:AddChild(row)
        return row
    end
end

-- ---------------------------------------------------------------------------
-- The body
-- ---------------------------------------------------------------------------

local function renderColumn(ctx, index, column, count)
    local stat = Const.STAT_BY_KEY[column.stat]
    -- A column whose stat is not in this build's catalog is still listed, so a
    -- player who moved a profile back from a newer build can see it and remove
    -- it. The renderer drops it; the editor must not hide it.
    local label = stat and L[stat.label] or tostring(column.stat)

    H.Section(ctx, index .. ". " .. label)
    H.RenderGrid(ctx, {
        { make = makeStatDropdown(index, column.stat) },
        { make = makeWidthSlider(index, column.width) },
        { make = makeShowBarCheckbox(index, column.showBar) },
        { make = makeColumnActions(index, count), wide = true },
    })
end

local function renderAddColumn(ctx, w)
    local list, order, remaining = unusedStatList(w)

    H.Section(ctx, L["Add column"])
    if remaining == 0 then
        H.TextRow(ctx, L["Every available statistic is already shown."])
        return
    end

    if pendingStat ~= nil and list[pendingStat] == nil then pendingStat = nil end

    H.RenderGrid(ctx, {
        {
            make = function(_, parent, relativeWidth)
                if not H.ActionDropdown then return nil end
                return H.ActionDropdown(parent, relativeWidth, {
                    label    = L["Statistic"],
                    tooltip  = L["Add a statistic as a new column on the right."],
                    list     = list,
                    order    = order,
                    value    = pendingStat,
                    onSelect = function(key) pendingStat = key end,
                })
            end,
        },
    })
    H.InlineButtonPair(ctx, {
        text    = L["Add column"],
        tooltip = L["Add a statistic as a new column on the right."],
        onClick = function() addColumn(pendingStat) end,
    }, nil)
end

local function render(ctx)
    H.ClearScroll(ctx)

    local w = activeWindow()
    if not w then
        H.TextRow(ctx, L["No window is selected."])
        H.Relayout(ctx)
        return
    end

    H.Section(ctx, L["Column list"])
    H.TextRow(ctx, L["The columns this window shows, left to right. Columns can only be changed out of combat."])

    local cols  = columnsOf(w)
    local count = #cols
    for i = 1, count do
        renderColumn(ctx, i, cols[i], count)
    end

    renderAddColumn(ctx, w)
    H.Relayout(ctx)
end

local function Build(mainCategory)
    if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then return nil end
    if not (H and H.CreatePanel) then return nil end

    -- No Defaults button. The column list is not a set of schema rows, so there
    -- is nothing per-row to restore; "reset the columns" is what duplicating a
    -- fresh window gives, and the global reset already rebuilds them from the
    -- catalog through NS.ApplyDefault.
    local ctx = H.CreatePanel("MultiMetersColumnsPanel", L["Columns"], {
        pageKey        = PAGE,
        defaultsButton = false,
    })

    H.SetRenderer(ctx, function(c)
        c.unit = NS.State and NS.State.activeWindowId or nil
        render(c)
    end)

    return Settings.RegisterCanvasLayoutSubcategory(mainCategory, ctx.panel, NS.SubPageLabel(L["Columns"]))
end

if NS.RegisterOptionsPage then
    NS.RegisterOptionsPage(PAGE, L["Columns"], Build)
end
