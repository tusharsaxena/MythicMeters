-- settings/Windows.lua
--
-- The Windows page: the window picker, the five registry actions (new, rename,
-- delete, duplicate) and "copy settings from", with a group filter.
--
-- ---------------------------------------------------------------------------
-- WHY THIS PAGE EXISTS AT ALL
-- ---------------------------------------------------------------------------
--
-- A window is an INSTANCE, not a singleton (design §6). There are no global
-- display settings in this addon — frame, header, rows, bars, text, icons,
-- tooltip, visibility, columns and data all live inside one window's config.
-- That makes every other settings page ambiguous on its own: "Width" is not a
-- setting, it is a setting OF something.
--
-- The resolution the design picked is one piece of session state rather than a
-- dynamic path model. Schema rows for window settings carry a path relative to
-- a window — `window.frame.width` — and NS.GetSetting / NS.SetByPath resolve it
-- against NS.State.activeWindowId. This page is the only writer of that state.
-- Move the picker and every other page, and `/mm set window.frame.width 300`,
-- retarget together. Nothing else changes and no path is rewritten.
--
-- The consequence is that the picker must force a STRUCTURAL refresh of every
-- panel, not a scalar one: the other pages did not change value, they changed
-- subject. NS.RefreshOptionsPanel is that sweep.
--
-- ---------------------------------------------------------------------------
-- WHY THE REGISTRY ACTIONS ROUTE THROUGH WindowManager
-- ---------------------------------------------------------------------------
--
-- Creating a window is not a table insert. It has to mint a non-reused id, deep
-- copy the template so two windows never share a sub-table, build the frame,
-- and announce WINDOWS_CHANGED so every consumer rebuilds. All of that is
-- modules/WindowManager.lua's, and it is also what `/mm window new` calls — one
-- implementation, so the panel and the CLI cannot drift into disagreeing about
-- what "new window" means (options-ui-§1).
--
-- This file therefore contains no registry logic. It contains a picker, some
-- buttons, and a confirmation.

local addonName, NS = ...

local L = NS.L

local PAGE = "windows"

-- ---------------------------------------------------------------------------
-- Two helpers this page needs and the library does not have
-- ---------------------------------------------------------------------------
--
-- Decorated onto the library INSTANCE rather than kept as file locals, because
-- settings/Columns.lua needs both and copying them into a second page file is
-- how two copies of a widget maker end up disagreeing about their own defaults
-- (options-ui-§1: NS.Helpers is the instance, decorated in place). They stay
-- host-side rather than being pushed upstream because neither has yet been
-- wanted by a second addon, which is the bar LibKa0s sets for publishing.
--
-- Declared unconditionally, so they exist on the degraded path too: with no
-- library there is no AceGUI, and each answers nil having drawn nothing —
-- exactly what every library maker does in the same situation.

local H = NS.Helpers or {}

--- A dropdown wired to caller-supplied get/set rather than to a settings path.
---
--- The library's own dropdown maker reads and writes a stored path, which is
--- right for a setting and wrong for everything on this page: the window picker
--- writes SESSION state, and the column editor writes one element of an array
--- through a carve-out. Neither has a scalar path to name.
---
--- `spec` = { label, tooltip, list, order, value, onSelect }.
H.ActionDropdown = function(parent, relativeWidth, spec)
    local AceGUI = NS.AceGUI
    if not (AceGUI and parent) then return nil end

    local dd = AceGUI:Create("Dropdown")
    dd:SetLabel(spec.label or "")
    if relativeWidth then dd:SetRelativeWidth(relativeWidth) else dd:SetFullWidth(true) end
    dd:SetList(spec.list or {}, spec.order)
    dd:SetValue(spec.value)
    dd:SetCallback("OnValueChanged", function(_, _, key)
        -- pcall'd for the same reason the library pcalls a button's onClick: a
        -- selection handler here reaches into live addon state, and a raise
        -- inside AceGUI's own dispatch would take the click handling of every
        -- widget on the frame with it.
        if spec.onSelect then pcall(spec.onSelect, key) end
    end)
    if H.AttachTooltip then H.AttachTooltip(dd, spec.label, spec.tooltip) end
    parent:AddChild(dd)
    return dd
end

--- Ask the page's scroll to measure itself again.
---
--- RenderRows ends with its own DoLayout; RenderGrid deliberately does not, and
--- InlineButtonPair appends after RenderRows has already run one. So any page
--- that draws past the end of a RenderSchema call has children with no measured
--- height until it asks. One named seam rather than the same three-clause
--- `if ctx.scroll and ctx.scroll.DoLayout` written out on five pages.
H.Relayout = function(ctx)
    if ctx and ctx.scroll and ctx.scroll.DoLayout then ctx.scroll:DoLayout() end
end

-- ---------------------------------------------------------------------------
-- Reading the registry
-- ---------------------------------------------------------------------------

local function windows()
    return (NS.Database and NS.Database.GetWindows and NS.Database.GetWindows()) or {}
end

--- The active window, healing a stale pointer on the way.
---
--- activeWindowId can outlive the window it names — deleted here, deleted by
--- `/mm window delete`, or dropped by a profile switch that brought a different
--- registry. Every consumer of the pointer would then resolve `window.frame.*`
--- against nothing, so the panel would render a page of empty widgets and a
--- write would go nowhere. Falling back to the first window makes that
--- unreachable, and it is cheap enough to do on every read.
local function activeWindow()
    local list = windows()
    local id   = NS.State and NS.State.activeWindowId
    for _, w in ipairs(list) do
        if w.id == id then return w end
    end
    local first = list[1]
    if first and NS.State then NS.State.SetActiveWindow(first.id) end
    return first
end

--- The picker's option list: keyed by id, labelled by name.
---
--- Keyed by ID and not by name on purpose. Names are user text and nothing stops
--- two windows being called "Meter"; ids are minted monotonically and never
--- reused, so they are the only thing here that is actually a key.
local function windowList()
    local list, order = {}, {}
    for _, w in ipairs(windows()) do
        list[w.id]         = w.name or tostring(w.id)
        order[#order + 1]  = w.id
    end
    return list, order
end

-- The config groups a copy can be filtered to, in the order the settings pages
-- appear. "*" is the everything option and is deliberately not a group name, so
-- a group can never be added that collides with it.
local COPY_ALL    = "*"
local COPY_GROUPS = {
    { key = "frame",      label = L["Frame"] },
    { key = "header",     label = L["Header"] },
    { key = "rows",       label = L["Rows"] },
    { key = "bars",       label = L["Bars"] },
    { key = "text",       label = L["Text"] },
    { key = "icons",      label = L["Icons"] },
    { key = "tooltip",    label = L["Tooltip"] },
    { key = "visibility", label = L["Visibility"] },
    { key = "columns",    label = L["Columns"] },
    { key = "data",       label = L["Data"] },
}

local function groupList()
    local list, order = { [COPY_ALL] = L["Everything"] }, { COPY_ALL }
    for _, g in ipairs(COPY_GROUPS) do
        list[g.key]       = g.label
        order[#order + 1] = g.key
    end
    return list, order
end

-- Which source and which group the copy control is currently pointed at. Page
-- state, not settings: it has no meaning outside an open panel and is not worth
-- a SavedVariables key or a schema row.
local copySourceId = nil
local copyGroup    = COPY_ALL

-- ---------------------------------------------------------------------------
-- Registry actions
-- ---------------------------------------------------------------------------

local function print_(line)
    if NS.Print then NS.Print(line) end
end

--- Call one WindowManager method, honestly, whether or not it is there.
---
--- The module can be absent — a raising module file costs itself and not the
--- addon — and a button that silently does nothing is the worst version of
--- that. One line naming the verb beats a dead control.
local function manager(method)
    local M = NS.WindowManager
    if M and type(M[method]) == "function" then return M end
    print_(L["No window is selected."])
    return nil
end

--- Repaint the panel after the registry or the active window moved.
---
--- STRUCTURAL, not scalar. The other pages did not change value, they changed
--- SUBJECT: their rows now resolve against a different window. A scalar refresh
--- would leave every widget showing the previous window's numbers under the new
--- window's name.
local function afterRegistryChange()
    if NS.RefreshOptionsPanel then NS.RefreshOptionsPanel() end
end

--- The page banner: which window this page is editing, and the picker for it.
---
--- Decorated onto the instance rather than kept file-local because SEVEN pages draw it, and a
--- second copy is how two of them end up disagreeing about what the list contains. It stays
--- host-side rather than going upstream because the library's O.PageBanner is the generic half
--- -- the label, the anchoring and the band -- and this is the part that knows what a window is.
---
--- The onSelect writes NS.State.activeWindowId and forces a STRUCTURAL refresh, because the
--- other pages did not change VALUE, they changed SUBJECT. That sweep is also what re-renders
--- every other banner, which is why there is no propagation code here: one writer, one read at
--- render time.
H.WindowBanner = function(ctx)
    if not (H.PageBanner and ctx) then return nil end

    local list, order = windowList()
    local active = activeWindow()
    local dd = H.PageBanner(ctx, {
        label   = L["Active window"],
        tooltip = L["Which window the settings on every other page apply to. Each window is configured independently."],
        list    = list,
        order   = order,
        value   = active and active.id,
        onSelect = function(id)
            if not id or (NS.State and id == NS.State.activeWindowId) then return end
            -- The SAME two calls the dropdown this replaces made, in the same order. Assigning
            -- NS.State.activeWindowId here instead would be a second writer of the pointer that
            -- skips whatever State.SetActiveWindow grows next, and afterRegistryChange is the
            -- file's one name for "every panel is now looking at a different window".
            if NS.State then NS.State.SetActiveWindow(id) end
            afterRegistryChange()
        end,
    })
    -- Parked on the ctx so a suite can drive the selection the way a click would; the library
    -- keeps its own widgets private and a test that cannot reach this one cannot prove the
    -- retarget happens at all.
    ctx.__bannerWidget = dd
    return dd
end

--- Point the panel at the last window in the registry.
---
--- Create and duplicate append, and both need the panel to follow what they
--- just made — a new window the player cannot see the settings of is a new
--- window they will assume failed. Reading the registry back rather than
--- trusting a return value keeps this working against any WindowManager that
--- reports success without handing the window over.
local function selectLast()
    local list = windows()
    local last = list[#list]
    if last and NS.State then NS.State.SetActiveWindow(last.id) end
end

local function doCreate()
    local M = manager("Create")
    if not M then return end
    -- No name: the registry mints "Multi Meters #<n>" off how many windows
    -- there are (modules/WindowManager.lua's defaultName).
    local ok, err = M:Create()
    if not ok then return print_(err or L["No window is selected."]) end
    selectLast()
    afterRegistryChange()
end

local function doDuplicate()
    local w = activeWindow()
    if not w then return print_(L["No window is selected."]) end
    local M = manager("Duplicate")
    if not M then return end
    local ok, err = M:Duplicate(w.name)
    if not ok then return print_(err or L["No window is selected."]) end
    selectLast()
    afterRegistryChange()
end

local function doRename(newName)
    local w = activeWindow()
    if not w then return print_(L["No window is selected."]) end
    newName = newName and strtrim(newName) or ""
    if newName == "" or newName == w.name then return end
    local M = manager("Rename")
    if not M then return end
    local ok, err = M:Rename(w.name, newName)
    if not ok then return print_(err or L["No window is selected."]) end
    afterRegistryChange()
end

local function doDelete()
    local w = activeWindow()
    if not w then return print_(L["No window is selected."]) end
    -- The last window is not deletable: an empty registry would leave every
    -- window-relative schema path unresolvable, so the panel would render pages
    -- of dead widgets. core/Database.lua seeds one window for the same reason.
    if #windows() <= 1 then return print_(L["The last window cannot be deleted."]) end
    local M = manager("Delete")
    if not M then return end
    local ok, err = M:Delete(w.name)
    if not ok then return print_(err or L["No window is selected."]) end
    -- Clear rather than reassign: activeWindow() heals the pointer to the first
    -- surviving window on its next read, so there is one rule for where the
    -- selection lands instead of two.
    if NS.State then NS.State.SetActiveWindow(nil) end
    afterRegistryChange()
end

local function doCopy()
    local dst = activeWindow()
    if not dst then return print_(L["No window is selected."]) end
    if copySourceId == nil or copySourceId == dst.id then return end

    local src
    for _, w in ipairs(windows()) do
        if w.id == copySourceId then src = w end
    end
    if not src then return end

    local M = manager("CopyFrom")
    if not M then return end
    local group = (copyGroup ~= COPY_ALL) and copyGroup or nil
    local ok, err = M:CopyFrom(src.name, dst.name, group)
    if not ok then return print_(err or L["No window is selected."]) end
    afterRegistryChange()
end

-- Deleting a window discards every setting on ten pages and cannot be undone,
-- so it confirms. Registered at file load with the window name stamped in at
-- show time by StaticPopup_Show's format argument.
StaticPopupDialogs["MULTIMETERS_DELETE_WINDOW"] = {
    text         = L["Delete the window '%s'?"],
    button1      = L["Yes"],
    button2      = L["No"],
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    OnAccept     = function() doDelete() end,
}

-- ---------------------------------------------------------------------------
-- The body
-- ---------------------------------------------------------------------------

local function renderNameBox(_, parent, relativeWidth)
    local AceGUI = NS.AceGUI
    if not (AceGUI and parent) then return nil end
    local w = activeWindow()

    local box = AceGUI:Create("EditBox")
    box:SetLabel(L["Window name"])
    box:SetRelativeWidth(relativeWidth or 1)
    box:SetText(w and w.name or "")
    -- OnEnterPressed only, never OnTextChanged: renaming fires WINDOWS_CHANGED
    -- and rebuilds the picker, and doing that per keystroke would pull the focus
    -- out of the box the player is typing in.
    box:SetCallback("OnEnterPressed", function(_, _, text) doRename(text) end)
    if H.AttachTooltip then
        H.AttachTooltip(box, L["Window name"],
            L["Name shown in this picker and, optionally, in the window's own header."])
    end
    parent:AddChild(box)
    return box
end

local function renderCopySource(_, parent, relativeWidth)
    local list, order = windowList()
    local active = activeWindow()
    -- The active window is not offered as its own source: copying a window onto
    -- itself is a no-op that looks like a bug when nothing changes.
    if active then
        list[active.id] = nil
        for i = #order, 1, -1 do
            if order[i] == active.id then tremove(order, i) end
        end
    end
    if copySourceId ~= nil and list[copySourceId] == nil then copySourceId = nil end

    return H.ActionDropdown(parent, relativeWidth, {
        label   = L["Copy settings from"],
        tooltip = L["Copy another window's settings onto this one. Choose which group of settings to copy below."],
        list    = list,
        order   = order,
        value   = copySourceId,
        onSelect = function(id) copySourceId = id end,
    })
end

local function renderCopyGroup(_, parent, relativeWidth)
    local list, order = groupList()
    return H.ActionDropdown(parent, relativeWidth, {
        label    = L["Settings to copy"],
        tooltip  = L["Copy every setting, or just one group."],
        list     = list,
        order    = order,
        value    = copyGroup,
        onSelect = function(key) copyGroup = key or COPY_ALL end,
    })
end

--- The Window tab: the name row and the three registry buttons.
local function renderWindowTab(ctx)
    H.RenderGrid(ctx, {
        { make = renderNameBox },
    })
    H.InlineButtonPair(ctx,
        {
            text    = L["New window"],
            tooltip = L["Create a new window with the default settings."],
            onClick = doCreate,
        },
        {
            text    = L["Duplicate window"],
            tooltip = L["Create a copy of the active window, including every setting and column."],
            onClick = doDuplicate,
        })
    H.InlineButtonPair(ctx, {
        text    = L["Delete window"],
        tooltip = L["Delete the active window. This cannot be undone."],
        onClick = function()
            local w = activeWindow()
            if not w then return print_(L["No window is selected."]) end
            if #windows() <= 1 then return print_(L["The last window cannot be deleted."]) end
            StaticPopup_Show("MULTIMETERS_DELETE_WINDOW", w.name or "")
        end,
    }, nil)
end

--- The Copy from tab: the source picker, the group filter and the Copy button.
local function renderCopyTab(ctx)
    H.RenderGrid(ctx, {
        { make = renderCopySource },
        { make = renderCopyGroup },
    })
    H.InlineButtonPair(ctx, {
        text    = L["Copy"],
        tooltip = L["Copy another window's settings onto this one. Choose which group of settings to copy below."],
        onClick = doCopy,
    }, nil)
end

-- The page's content is bespoke rather than schema rows -- a name box, three registry buttons,
-- a source picker, a group filter and a Copy button -- so H.RenderTabbedSchema, which partitions
-- SCHEMA ROWS by `group`, has nothing here to drive. The strip is drawn directly with
-- H.TabStrip and the page branches on ctx.activeTab itself, same as it always resolved which
-- half of the page to draw, only now the split is a click instead of a scroll.
local function render(ctx)
    H.ClearScroll(ctx)

    H.WindowBanner(ctx)
    H.TabStrip(ctx, {
        tabs = {
            { key = L["Window"],    label = L["Window"] },
            { key = L["Copy from"], label = L["Copy from"] },
        },
        value = ctx.activeTab or L["Window"],
        onSelect = function(key)
            if key == ctx.activeTab then return end
            ctx.activeTab = key
            H.ClearScroll(ctx)
            H.RefreshPanel(ctx, true)
        end,
    })
    ctx.activeTab = ctx.activeTab or L["Window"]

    if ctx.activeTab == L["Window"] then
        renderWindowTab(ctx)
    else
        renderCopyTab(ctx)
    end

    H.Relayout(ctx)
end

local function Build(mainCategory)
    if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then return nil end
    if not (H and H.CreatePanel) then return nil end

    -- No Defaults button: nothing on this page is a schema row, so there is
    -- nothing for "restore this page's defaults" to restore. Deleting the
    -- registry back to one seed window is not what a player clicking Defaults
    -- expects, and it is what the button would have to mean.
    local ctx = H.CreatePanel("MultiMetersWindowsPanel", L["Windows"], {
        pageKey        = PAGE,
        defaultsButton = false,
    })

    H.SetRenderer(ctx, render)

    return Settings.RegisterCanvasLayoutSubcategory(mainCategory, ctx.panel, L["Windows"])
end

if NS.RegisterOptionsPage then
    NS.RegisterOptionsPage(PAGE, L["Windows"], Build)
end
