-- settings/Columns.lua
--
-- The Columns page: one block per statistic, ticked or not, in the order the
-- window draws them left to right.
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
-- THE WIDTH SETTING IS GONE ENTIRELY NOW, which retires the argument rather than
-- answering it: modules/Window.lua divides the frame width evenly across the
-- visible columns, so there is no per-column width for anyone to drag OR to type
-- into a slider. The page still lives here, and the paragraph above is still why
-- a column editor could never have lived anywhere else.
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

-- The gap between the page's explanatory line and the block list under it. The
-- same number LibKa0s puts below a section heading, so this page's spacing is
-- the collection's spacing rather than one file's taste.
local SECTION_GAP = 10

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
        out[i] = { stat = c.stat, enabled = c.enabled and true or false }
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

-- Each answers with the seam's verdict rather than swallowing it, so a caller
-- (and a test) can tell an applied edit from a refused one.

--- Tick or untick one block.
---
--- A TOGGLE IS ALSO A MOVE, and that is the whole interaction. Ticking sends the
--- block to the END of the enabled group -- it becomes the rightmost column,
--- which is where a column you just added belongs. Unticking sends it to the TOP
--- of the disabled group, which is the shortest travel available: the player
--- watches it drop just below the rule rather than hunting for where it went.
---
--- The seam re-sorts anyway -- normalizeColumns partitions enabled ahead of
--- disabled -- so the position built here is only ever a position WITHIN a group.
--- Building it explicitly is what makes the two ends predictable rather than
--- whatever a stable partition happened to leave.
---
--- @param index number
--- @return boolean applied
local function toggle(index)
    local w = activeWindow()
    if not w then return false end

    local cols  = snapshot(w)
    local entry = cols[index]
    if not entry then return false end

    -- The seam refuses this too. Refusing HERE is what puts the reason in front
    -- of the player attached to the click that caused it, rather than as a line
    -- printed after a control appeared to do nothing.
    if entry.enabled then
        local shown = 0
        for _, c in ipairs(cols) do
            if c.enabled then shown = shown + 1 end
        end
        if shown <= 1 then
            print_(L["A window must keep at least one column."])
            return false
        end
    end

    tremove(cols, index)
    entry.enabled = not entry.enabled

    local boundary = 0
    for _, c in ipairs(cols) do
        if c.enabled then boundary = boundary + 1 end
    end

    -- Both ends land at the same insertion point: the first slot after the last
    -- enabled entry. Newly ticked, that is the end of the enabled group; newly
    -- unticked, it is the top of the disabled one.
    tinsert(cols, boundary + 1, entry)
    return commit(cols)
end

--- Move one block to another index.
---
--- Both are already in the same group -- settings/ColumnBlocks.lua clamped the
--- drop before it ever got here, because crossing the rule is a state change and
--- a drag is not how the player asks for one.
---
--- @param from number
--- @param to number
--- @return boolean applied
local function reorder(from, to)
    local w = activeWindow()
    if not w then return false end

    local cols = snapshot(w)
    if not (cols[from] and cols[to]) or from == to then return false end

    tinsert(cols, to, tremove(cols, from))
    return commit(cols)
end

--- Put this window's columns back to the shipped list.
---
--- THE PAGE'S OWN, because the library's RestoreDefaults walks a page's schema
--- ROWS and this page has none -- the column array is addressable only as a
--- whole, which is the same reason a profile reset cannot reach it row by row.
---
--- Built from NS.DefaultWindow rather than from a literal, so a statistic added
--- to the catalog is in the shipped list here with no edit, exactly as it is for
--- a brand-new window. The window's id goes in so the template's own `id` field
--- is not what comes back out.
local function restoreShippedColumns()
    local w = activeWindow()
    if not (w and NS.DefaultWindow) then return false end

    local shipped = NS.DefaultWindow(w.id).columns
    if type(shipped) ~= "table" then return false end
    return commit(shipped)
end

-- ---------------------------------------------------------------------------
-- The body
-- ---------------------------------------------------------------------------

--- The stored array in the shape the widget wants it.
---
--- Labels are localized HERE because core/Constants.lua stores the English label
--- and deliberately does not call L itself -- locales/ may load either side of
--- it.
---
--- A statistic this build does not have cannot appear: normalizeColumns drops it
--- on the way in. So there is no unknown-stat row to render and no fallback label
--- to invent, which the old page needed because its array was a subset the player
--- had assembled by hand.
local function items(w)
    local out = {}
    for i, c in ipairs(columnsOf(w)) do
        local stat = Const.STAT_BY_KEY[c.stat]
        out[i] = {
            key     = c.stat,
            label   = stat and L[stat.label] or tostring(c.stat),
            enabled = c.enabled and true or false,
        }
    end
    return out
end

--- The rows of one schema group on this page, in declaration order.
---
--- Filtered rather than driven by H.RenderTabbedSchema, because the Columns tab is the block
--- editor and not a schema group at all -- RenderTabbedSchema partitions ALL of a page's rows
--- by `group`, and would have nothing to say about where a non-schema tab belongs in that
--- partition. Filtering NS.SchemaForPage by group directly is the same partition, done by hand,
--- for the two tabs that ARE schema rows.
local function rowsOfGroup(groupName)
    local out = {}
    for _, row in ipairs(NS.SchemaForPage and NS.SchemaForPage(PAGE) or {}) do
        if row.group == groupName then out[#out + 1] = row end
    end
    return out
end

--- NO SECTION HEADINGS on the block editor, and no Add section. Each column used to get its own
--- `1. Damage` heading over four controls, so eight columns was eight headings and forty widgets
--- to scroll past. The array is the catalog now: there is nothing to add and nothing to remove,
--- only an order and which of them you want to see.
local function renderBlockEditor(ctx)
    local w = activeWindow()
    if not w then
        H.TextRow(ctx, L["No window is selected."])
        return
    end

    H.TextRow(ctx, L["Every statistic this build offers. Ticked ones are the columns this window shows, left to right, top to bottom. Drag a block by its handle to reorder them. Columns can only be changed out of combat."])

    -- The blocks are a LIST, and a list that starts flush against the paragraph
    -- explaining it reads as part of the same paragraph. Every other page gets
    -- this gap from H.Section's own bottom spacer; this page has no heading to
    -- carry one, so it asks for the same measurement directly rather than
    -- inventing a second opinion about what a gap is.
    local scroll = H.EnsureScroll and H.EnsureScroll(ctx)
    if scroll and H.AddSpacer then H.AddSpacer(scroll, SECTION_GAP) end

    NS.ReorderableBlocks(ctx, {
        items    = items(w),
        onToggle = toggle,
        onMove   = reorder,
    })
end

-- Three tabs: the block editor (bespoke, not schema rows) and the two schema groups that used
-- to sit under it with no heading saying which window they belonged to. H.RenderTabbedSchema
-- cannot drive this page -- it partitions ALL of a page's rows by group, and the Columns tab has
-- none -- so the strip is drawn directly with H.TabStrip and each schema tab renders its own
-- filtered row list through H.RenderRows.
local TAB_COLUMNS = L["Columns"]
local TAB_HEADER_TEXT = L["Header text"]
local TAB_HEADER_BG = L["Header background"]

local function render(ctx)
    -- BEFORE ClearScroll, not after. ClearScroll hands every AceGUI container on this page back to
    -- a process-wide pool, and a drag handle is parented to one of them until the controller is
    -- cancelled -- so cancelling afterwards means some unrelated widget has already been handed a
    -- frame with a live handle on it.
    if NS.CancelReorder then NS.CancelReorder(ctx) end
    H.ClearScroll(ctx)

    if NS.State and NS.State.debug and NS.Debug then
        local w0 = activeWindow()
        NS.Debug("Columns", "paint window=%s", tostring(w0 and w0.id))
    end

    H.WindowBanner(ctx)
    H.TabStrip(ctx, {
        tabs = {
            { key = TAB_COLUMNS,    label = TAB_COLUMNS },
            { key = TAB_HEADER_TEXT, label = TAB_HEADER_TEXT },
            { key = TAB_HEADER_BG,   label = TAB_HEADER_BG },
        },
        value = ctx.activeTab or TAB_COLUMNS,
        onSelect = function(key)
            if key == ctx.activeTab then return end
            ctx.activeTab = key
            -- No H.ClearScroll here: RefreshPanel(ctx, true) re-enters render(), which clears the
            -- scroll AFTER cancelling the reorder controller (see the comment at the top of render
            -- above). Clearing here too would run BEFORE the cancel on a tab click -- the one path
            -- that matters, since this is the page with a live reorder controller.
            H.RefreshPanel(ctx, true)
        end,
    })
    ctx.activeTab = ctx.activeTab or TAB_COLUMNS

    if ctx.activeTab == TAB_HEADER_TEXT then
        H.RenderRows(ctx, rowsOfGroup(TAB_HEADER_TEXT), nil, nil, { noHeadings = true })
    elseif ctx.activeTab == TAB_HEADER_BG then
        H.RenderRows(ctx, rowsOfGroup(TAB_HEADER_BG), nil, nil, { noHeadings = true })
    else
        renderBlockEditor(ctx)
    end

    H.Relayout(ctx)
end

local function Build(mainCategory)
    if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then return nil end
    if not (H and H.CreatePanel) then return nil end

    -- A DEFAULTS BUTTON THAT DOES ITS OWN WORK. The page carried none for as long
    -- as the column list was a subset the player assembled: it is not a set of
    -- schema rows, so H.RestoreDefaults -- which walks the rows of a page -- would
    -- have found nothing to restore and done nothing at all.
    --
    -- The array is the catalog now, and that gives the button something exact to
    -- mean: the statistics that ship ticked, in the order they ship in. Which is
    -- a thing a player can want and previously could only get by making a whole
    -- new window.
    local ctx = H.CreatePanel("MultiMetersColumnsPanel", L["Columns"], {
        pageKey          = PAGE,
        defaultsButton   = true,
        defaultsTooltip  = L["Restore the statistics this window ships with, ticked and in their shipped order, and the header text and background settings on this page to their shipped values."],
    })

    -- TWO RESETS BEHIND ONE BUTTON, because this page carries both a bespoke array (the column
    -- list, addressable only as a whole -- see restoreShippedColumns above) and eight
    -- window.columnHeader.* schema rows on its other two tabs. options-ui-§13 makes the Defaults
    -- button page-wide, not tab-wide, so both halves have to come back regardless of which tab is
    -- showing when it is clicked.
    ctx.panel.defaultsOnClick = function()
        restoreShippedColumns()
        H.RestoreDefaults(PAGE, ctx)
    end

    H.SetRenderer(ctx, function(c)
        c.unit = NS.State and NS.State.activeWindowId or nil
        render(c)
    end)

    return Settings.RegisterCanvasLayoutSubcategory(mainCategory, ctx.panel, NS.SubPageLabel(L["Columns"]))
end

if NS.RegisterOptionsPage then
    NS.RegisterOptionsPage(PAGE, L["Columns"], Build)
end
