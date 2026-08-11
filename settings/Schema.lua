-- settings/Schema.lua
--
-- THE single source of truth for settings (settings-schema-§1). One ordered
-- array of rows drives three surfaces that would otherwise drift apart: the
-- options panel's widgets, the `/mm get|set|list|reset|resetall` CLI, and the
-- defaults reset. Adding a setting is one row here and nothing else.
--
-- ---------------------------------------------------------------------------
-- THE WINDOW-RELATIVE PATH MODEL — the one thing that is not standard-issue
-- ---------------------------------------------------------------------------
--
-- Almost every setting in this addon is PER-WINDOW (design §6), and a window is
-- an instance the user creates at runtime. Written out absolutely, a window row's
-- path would have to be `windows.<id>.frame.width` — dynamic, unknowable when
-- this file loads, and impossible to express in the flat path model the CLI and
-- the panel both read.
--
-- Resolution (design §8): a window row's path is RELATIVE to a window and is
-- spelled `window.frame.width`. NS.GetSetting and NS.SetByPath resolve the
-- `window.` prefix against the session's ACTIVE window — NS.State.activeWindowId,
-- which the panel's window picker moves and which defaults to the first window in
-- the registry. Global rows keep absolute paths (`enabled`, `minimap.hide`),
-- resolved against db.profile.
--
-- What that buys: ONE schema, ONE write seam, and `/mm set window.frame.width 300`
-- means "the window I am editing" on the CLI exactly as it does in the panel. The
-- picker retargets 70-odd rows by moving one integer of session state instead of
-- by rewriting every path.
--
-- ---------------------------------------------------------------------------
-- WHY THE COLUMNS ARE NOT ROWS
-- ---------------------------------------------------------------------------
--
-- `window.columns` is an ORDERED ARRAY of `{ stat, width, showBar }` whose length
-- is the user's, not the schema's. A path model addresses named leaves; it has no
-- vocabulary for "insert a column before index 2". So the columns subtree is a
-- documented CARVE-OUT rather than a row: `/mm get window.columns` reads (the
-- generic resolver reaches it like any other node), and a WRITE to
-- `window.columns` is accepted WHOLE-ARRAY — settings/Columns.lua builds the array
-- it wants and hands the seam all of it, which is the only granularity a path can
-- honestly express.
--
-- The seam still owns the write. It structurally validates the array (every entry
-- names a stat this build has, exactly once, at a width the Columns page's own
-- slider can produce, with a real boolean show-bar), rebuilds it entry by entry so
-- nothing downstream shares a table with the caller, and then takes the SAME debug
-- line, CONFIG_CHANGED message and panel re-sync every scalar write takes. A
-- direct table write in the page would be a second seam that looks identical and
-- announces nothing.
--
-- What is still refused is a write to a path INSIDE the array —
-- `window.columns.2.width`. Addressing one column by ordinal is exactly the
-- vocabulary a path model does not have: the ordinal moves the moment a column is
-- added, removed or reordered, so a stored reference to it is wrong by the next
-- edit.
--
-- ---------------------------------------------------------------------------
-- ROW SHAPE
-- ---------------------------------------------------------------------------
--
--   path      resolution path. `window.`-prefixed = active window; else profile.
--   type      "bool" | "number" | "string" | "color". This is the WIDGET
--             DISPATCH KEY — LibKa0s-Options-1.0 selects a maker from it, and
--             LibKa0s-Slash-1.0 selects a parser from the same field, which is
--             what keeps the CLI and the panel agreeing about what a row is.
--             There is deliberately no separate `widget` field: a second
--             selector is a second thing to keep in step. A `number` carrying
--             `values` is INFERRED as a dropdown by both majors; `string` with
--             `dialogControl = "EditBox"` is free text; everything else with
--             `values` is a dropdown.
--   default   the shipped value. MUST equal defaults/Profile.lua's — that
--             agreement is what NS.ValidateSchema() exists to prove.
--   page      the page key. Groups `/mm list`, feeds the panel's rowsForPage,
--             names the CONFIG_CHANGED section, and `page == "profiles"` is the
--             reset-all veto. One key, three jobs, no drift.
--   group     section heading inside the page.
--   label     / desc    displayed strings, localized at declaration through NS.L.
--   min/max/step/fmt/isPercent   slider shape.
--   values / sorting / dialogControl   dropdown shape.
--   validate  optional predicate; a false answer refuses the write.
--   onChange  optional reaction for the few settings the CONFIG_CHANGED message
--             cannot express on its own (see "Refresh routing" below).
--   invert    display is the negation of storage (the one minimap row).
--   sessionOnly  never persisted; the row's own get/set are the whole storage.
--
-- TOC POSITION: FIRST in settings/, before settings/Slash.lua and
-- settings/OptionsSetup.lua, both of which point their seams at NS.SetByPath /
-- NS.GetSetting / NS.FindSchemaRow / NS.ApplyDefault at load, and before every
-- settings/<page>.lua, which render these rows.
--
-- Nothing here is captured across the load boundary: NS.Helpers, NS.db,
-- NS.WindowManager and NS.Visibility are all resolved at CALL time, because this
-- file loads before all four.

local addonName, NS = ...

local L     = NS.L
local Const = NS.Constants
local MSG   = Const.MSG

-- ---------------------------------------------------------------------------
-- Path plumbing
-- ---------------------------------------------------------------------------

-- Split results are memoized because the set of paths is CLOSED and small — it is
-- the schema's own key set plus whatever the CLI is handed — while a panel drag
-- re-resolves one path many times a second. The cache is keyed on the path
-- string, so it can never grow beyond the paths that were actually asked for.
local splitCache = {}

--- "window.frame.width" -> { "window", "frame", "width" }, memoized.
--- @param path string
--- @return table  array of segments (shared; callers must not mutate it)
local function splitPath(path)
    local parts = splitCache[path]
    if parts then return parts end
    parts = {}
    for segment in tostring(path):gmatch("[^%.]+") do
        parts[#parts + 1] = segment
    end
    splitCache[path] = parts
    return parts
end

--- Walk `parts` from `first` and return the leaf, or nil if any step is missing.
local function readFrom(root, parts, first)
    local node = root
    for i = first, #parts do
        if type(node) ~= "table" then return nil end
        node = node[parts[i]]
    end
    return node
end

--- Walk `parts` from `first`, creating missing tables, and write the leaf.
local function writeInto(root, parts, first, value)
    local node = root
    for i = first, #parts - 1 do
        local key = parts[i]
        if type(node[key]) ~= "table" then node[key] = {} end
        node = node[key]
    end
    node[parts[#parts]] = value
end

--- Recursive copy. A table default (every color) must never be handed out by
--- reference: two profiles reset to the same default would then share one table,
--- and editing one window's bar color would silently edit the other's.
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

-- ---------------------------------------------------------------------------
-- Window resolution
-- ---------------------------------------------------------------------------

local WINDOW_PREFIX = "window"

--- The window a `window.`-prefixed path resolves against: the picker's selection,
--- or the first window in the registry when nothing is selected.
---
--- Falling back to the first window rather than to nil is deliberate. The CLI has
--- no picker, and `/mm set window.frame.width 300` typed on a fresh login — where
--- nothing has ever set activeWindowId — must mean something rather than fail with
--- a message about an internal pointer the user has never heard of.
---
--- @return table|nil window, number|nil id
local function activeWindow()
    local Database = NS.Database
    if not Database then return nil, nil end

    local id = NS.State and NS.State.activeWindowId
    if id ~= nil then
        local w = Database.FindWindow(id)
        if w then return w, id end
    end

    local first = Database.GetWindows()[1]
    if first then return first, first.id end
    return nil, nil
end

--- Where a path lives: its root table, the index of its first segment inside that
--- root, and the id of the window it landed in (nil for a global row).
---
--- @param parts table  the split path
--- @return table|nil root, number first, number|nil windowId
local function resolveRoot(parts)
    if parts[1] == WINDOW_PREFIX then
        local w, id = activeWindow()
        return w, 2, id
    end
    local db = NS.db
    return db and db.profile or nil, 1, nil
end

-- ---------------------------------------------------------------------------
-- Inversion
-- ---------------------------------------------------------------------------
--
-- Exactly one row stores the negation of what it displays: LibDBIcon owns the
-- shape of `minimap`, and its key is `hide`, while the checkbox a user reads has
-- to say "Show minimap button" — a checkbox labelled with a negative is the
-- classic settings-panel double-negative that everyone mis-clicks once.
--
-- Rather than let that one row grow a private get/set pair (which the CLI would
-- then have to know about separately), the seam carries a two-line concept used at
-- three call sites and nowhere else. `default` is always the STORED value, so the
-- validator still compares like with like against defaults/Profile.lua.

local function toStored(row, v)
    if row.invert then return not v end
    return v
end

local function toDisplay(row, v)
    if row.invert then return not v end
    return v
end

-- ---------------------------------------------------------------------------
-- Refresh routing
-- ---------------------------------------------------------------------------
--
-- The DEFAULT refresh for every row is the CONFIG_CHANGED message that SetByPath
-- sends, and this file is its ONE sender (architecture-§4). Windows subscribe and
-- re-read their upvalues; the panel re-reads its scalars. A direct call from here
-- into modules/ would be the cross-module reach the standard forbids, and it would
-- also be a second refresh path for anything that already subscribes.
--
-- `onChange` therefore exists only for the handful of settings whose effect the
-- message genuinely cannot express — a decision that is not "this window's config
-- moved" but "the show/hide ladder has to be re-run", or "a Blizzard-side object
-- outside our config tree has to be told". Each resolves its target through NS at
-- CALL time, because every one of them loads after this file.

--- Re-run the visibility ladder for every window. Used by the master enable and by
--- the per-context rules, whose effect is a window appearing or disappearing
--- rather than a window redrawing.
local function refreshVisibility()
    local V = NS.Visibility or (NS.GetModule and NS:GetModule("Visibility", true))
    if V and V.Refresh then V:Refresh() end
end

--- Show or hide the minimap button. LibDBIcon holds the button and reads the same
--- `minimap` table this row writes, so it has to be told to look again. Guarded on
--- its registry rather than pcall'd: an unregistered button is the normal state of
--- an install whose broker never came up, not an error.
local function refreshMinimap()
    local icon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not (icon and icon.objects and icon.objects[addonName]) then return end
    local db = NS.db
    if icon.Refresh and db and db.profile then
        icon:Refresh(addonName, db.profile.minimap)
    end
end

-- ---------------------------------------------------------------------------
-- Dropdown vocabularies
-- ---------------------------------------------------------------------------
--
-- Key maps plus an explicit `sorting`, so the list reads in a deliberate order
-- (LOW → DIALOG, never alphabetically as "DIALOG, HIGH, LOW, MEDIUM"). The KEYS
-- are what is stored and what `/mm set` accepts; the values are display strings
-- and may be translated freely without touching a stored profile.

local STRATA_VALUES  = { LOW = L["Low"], MEDIUM = L["Medium"], HIGH = L["High"], DIALOG = L["Dialog"] }
local STRATA_SORT    = { "LOW", "MEDIUM", "HIGH", "DIALOG" }

local ALIGN_VALUES   = { LEFT = L["Left"], CENTER = L["Center"], RIGHT = L["Right"] }
local ALIGN_SORT     = { "LEFT", "CENTER", "RIGHT" }

local OUTLINE_VALUES = {
    NONE         = L["None"],
    OUTLINE      = L["Outline"],
    THICKOUTLINE = L["Thick outline"],
    MONOCHROME   = L["Monochrome"],
}
local OUTLINE_SORT   = { "NONE", "OUTLINE", "THICKOUTLINE", "MONOCHROME" }

local GROWTH_VALUES  = { DOWN = L["Down"], UP = L["Up"] }
local GROWTH_SORT    = { "DOWN", "UP" }

local SIDE_VALUES    = { LEFT = L["Left"], RIGHT = L["Right"] }
local SIDE_SORT      = { "LEFT", "RIGHT" }

local BARCOLOR_VALUES = {
    class  = L["Class color"],
    stat   = L["Per-statistic color"],
    custom = L["Custom color"],
}
local BARCOLOR_SORT  = { "class", "stat", "custom" }

-- The same three, plus an off switch. The background is decoration in a way the
-- bar is not, so it is the one of the two that a player may want gone entirely.
local BARBG_VALUES = {
    class  = L["Class color"],
    stat   = L["Per-statistic color"],
    custom = L["Custom color"],
    none   = L["None"],
}
local BARBG_SORT = { "class", "stat", "custom", "none" }

local LEFTSLOT_VALUES = { total = L["Total"], percent = L["Percent"], none = L["None"] }
local LEFTSLOT_SORT   = { "total", "percent", "none" }

local RIGHTSLOT_VALUES = { rate = L["Per second"], percent = L["Percent"], none = L["None"] }
local RIGHTSLOT_SORT   = { "rate", "percent", "none" }

local NUMFMT_VALUES  = { abbreviated = L["Abbreviated"], full = L["Full"] }
local NUMFMT_SORT    = { "abbreviated", "full" }

local ANCHOR_VALUES  = {
    CURSOR      = L["At cursor"],
    TOPLEFT     = L["Top left"],
    TOPRIGHT    = L["Top right"],
    BOTTOMLEFT  = L["Bottom left"],
    BOTTOMRIGHT = L["Bottom right"],
}
local ANCHOR_SORT    = { "CURSOR", "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }

local SORTMODE_VALUES = {
    value    = L["By value"],
    name     = L["By name"],
    provider = L["Game order"],
    roster   = L["Group order"],
}
local SORTMODE_SORT   = { "value", "name", "provider", "roster" }

-- The sort-column list is DERIVED from the stat catalog rather than restated, so
-- adding a stat to core/Constants.lua offers it here with no edit (and so a stat
-- removed from the catalog cannot linger as an option that resolves to nothing).
local STATCOL_VALUES, STATCOL_SORT = {}, {}
for i, stat in ipairs(Const.STATS) do
    STATCOL_VALUES[stat.key] = L[stat.label]
    STATCOL_SORT[i] = stat.key
end

-- The session list is a NUMERIC dropdown: the stored value is an
-- Enum.DamageMeterSessionType number, not a name, so the row is `type = "number"`
-- with an ordered `{ value =, text = }` array. Both majors infer "enum, not range"
-- from the presence of `values` on a number row and constrain rather than clamp,
-- which is what this row needs — a session type clamped to 1.5 is nothing.
local SESSION_VALUES = {
    { value = Const.SESSION_TYPE.Current, text = L["Current"] },
    { value = Const.SESSION_TYPE.Overall, text = L["Overall"] },
    { value = Const.SESSION_TYPE.Expired, text = L["Expired"] },
}

--- A DEFERRED LibSharedMedia list, pulled at render and at parse time.
---
--- Deferred is load-bearing twice over here. First for the usual reason — the
--- addons that register media have not run when a schema row is declared, so a
--- snapshot would freeze the list at whatever loaded first. Second because this
--- file loads BEFORE settings/OptionsSetup.lua, so NS.Helpers does not exist yet
--- and the library's own LSMValues cannot be called at declaration at all.
---
--- The library's closure is CONSUMED, never reimplemented: it owns the
--- never-answer-empty rule (a dropdown with no options cannot be opened, and the
--- CLI would then refuse even the value already stored), and a private copy here
--- would be the copy that goes stale.
local function lsmValues(mediaType)
    return function()
        local H = NS.Helpers
        local maker = H and H.LSMValues
        if not maker then return {} end
        local list = maker(mediaType)
        return (type(list) == "function" and list()) or list or {}
    end
end

-- ---------------------------------------------------------------------------
-- Common validators
-- ---------------------------------------------------------------------------

local function isNumberIn(minimum, maximum)
    return function(v)
        return type(v) == "number" and v >= minimum and v <= maximum
    end
end

-- ---------------------------------------------------------------------------
-- THE SCHEMA
-- ---------------------------------------------------------------------------
--
-- Ordered: pages in the order the panel lists them, and rows in the order they
-- render inside a page (the flow engine pairs consecutive rows two to a line, so
-- neighbours here are neighbours on screen).
--
-- Every default below is the SAME LITERAL defaults/Profile.lua ships. It is
-- restated rather than read out of the template because the row's default is what
-- a widget shows before the db exists and what a reset restores, and because two
-- independent statements of one value are exactly what NS.ValidateSchema() can
-- check — a single shared reference would agree with itself by construction and
-- prove nothing.

NS.Schema = {

    -- ── Windows ──────────────────────────────────────────────────────────────
    -- The picker, the create/duplicate/delete buttons and the copy-settings-from
    -- control are BESPOKE (settings/Windows.lua): they act on the registry, not on
    -- a leaf, so they have no path. The window's NAME is a leaf and is here.
    {
        path = "window.name", type = "string", default = "Mythic Meters",
        dialogControl = "EditBox", maxLetters = 32,
        page = "windows", group = L["Active window"],
        label = L["Window name"], desc = L["Name shown in this picker and, optionally, in the window's own header."],
        validate = function(v) return type(v) == "string" and v ~= "" end,
    },

    -- ── Frame ────────────────────────────────────────────────────────────────
    -- The chrome itself is LibKa0s-Core-1.0's shared SKIN, which tints the title
    -- and the divider on its own, so the edge colors are not settings. What the
    -- player owns is geometry, the backdrop and the LSM border.
    {
        path = "window.frame.width", type = "number", default = 694,
        min = 160, max = 1400, step = 10, fmt = "%d px",
        page = "frame", group = L["Size and position"],
        label = L["Width"], desc = L["Window width in pixels."],
    },
    {
        path = "window.frame.height", type = "number", default = 220,
        min = 60, max = 900, step = 10, fmt = "%d px",
        page = "frame", group = L["Size and position"],
        label = L["Height"], desc = L["Window height in pixels."],
    },
    {
        path = "window.frame.scale", type = "number", default = 1.0,
        min = 0.5, max = 2.0, step = 0.05, fmt = "%.2fx",
        page = "frame", group = L["Size and position"],
        label = L["Scale"], desc = L["Scale multiplier applied to the whole window."],
        validate = isNumberIn(0.5, 2.0),
    },
    {
        path = "window.frame.alpha", type = "number", default = 1.0,
        min = 0, max = 1, step = 0.05, isPercent = true,
        page = "frame", group = L["Size and position"],
        label = L["Opacity"], desc = L["Overall opacity of the window."],
        validate = isNumberIn(0, 1),
    },
    {
        path = "window.frame.strata", type = "string", default = "MEDIUM",
        values = STRATA_VALUES, sorting = STRATA_SORT,
        page = "frame", group = L["Size and position"],
        label = L["Frame strata"], desc = L["Which layer the window sits in relative to the rest of your interface."],
    },
    {
        path = "window.frame.padding", type = "number", default = 6,
        min = 0, max = 32, step = 1, fmt = "%d px",
        page = "frame", group = L["Size and position"],
        label = L["Padding"], desc = L["Gap in pixels between the window edge and the rows inside it."],
    },
    {
        path = "window.frame.backdropColor", type = "color",
        default = { r = 0, g = 0, b = 0, a = 0.75 },
        page = "frame", group = L["Border style"],
        label = L["Background color"], desc = L["Color drawn behind the rows."],
    },
    {
        path = "window.frame.borderStyle", type = "string", default = "Blizzard Tooltip",
        values = lsmValues("border"), dialogControl = "LSM30_Border",
        page = "frame", group = L["Border style"],
        label = L["Border style"], desc = L["LibSharedMedia border texture drawn around the window."],
    },
    {
        path = "window.frame.borderSize", type = "number", default = 2,
        min = 0, max = 32, step = 1, fmt = "%d px",
        page = "frame", group = L["Border style"],
        label = L["Border thickness"], desc = L["Border edge size in pixels."],
    },
    {
        path = "window.frame.borderColor", type = "color",
        default = { r = 0, g = 0, b = 0, a = 1 },
        page = "frame", group = L["Border style"],
        label = L["Border color"], desc = L["Color of the window border."],
    },
    -- Locking implies preview mode: a player positioning a window at a target
    -- dummy needs a full grid to aim at, which is why the two are one control here
    -- and why modules/WindowManager.lua owns the coupling rather than this row.
    {
        path = "window.frame.locked", type = "bool", default = false,
        page = "frame", group = L["Row behavior"],
        label = L["Lock window"],
        desc = L["When unlocked you can drag the window to reposition it and drag its corner to resize. Nothing else changes \226\128\148 for placeholder rows use Test mode on the General page."],
    },
    {
        path = "window.frame.clampToScreen", type = "bool", default = true,
        page = "frame", group = L["Row behavior"],
        label = L["Keep on screen"], desc = L["Prevent the window from being dragged off the edge of the screen."],
    },
    {
        path = "window.frame.titleBar", type = "bool", default = true,
        page = "frame", group = L["Row behavior"],
        label = L["Show title bar"], desc = L["Draw the title strip along the top of the window."],
    },
    {
        path = "window.frame.closeButton", type = "bool", default = true,
        page = "frame", group = L["Row behavior"],
        label = L["Show close button"], desc = L["Draw a close button in the title bar."],
    },
    {
        path = "window.frame.resizeGrip", type = "bool", default = true,
        page = "frame", group = L["Row behavior"],
        label = L["Show resize grip"], desc = L["Draw a drag handle in the bottom-right corner for resizing."],
    },
    -- `frame.position` is deliberately NOT a row. It is written by a drag, it is
    -- four values with one meaning, and — rule R3 — it is never read back off the
    -- live frame. NS.ResetPositions() is how a reset reaches it, wired into the
    -- options descriptor's afterRestoreAll.

    -- ── Header ───────────────────────────────────────────────────────────────
    {
        path = "window.header.title", type = "string", default = "",
        dialogControl = "EditBox", maxLetters = 48,
        page = "header", group = L["Header text"],
        label = L["Title"], desc = L["Text shown in the header. Leave empty to use the window's name."],
        validate = function(v) return type(v) == "string" end,
    },
    {
        path = "window.header.showSessionName", type = "bool", default = true,
        page = "header", group = L["Header text"],
        label = L["Show session name"],
        desc = L["Show which combat session the window is reading — the current pull, or the overall run."],
    },
    {
        path = "window.header.showDuration", type = "bool", default = true,
        page = "header", group = L["Header text"],
        label = L["Show duration"], desc = L["Show how long the session has been running."],
    },
    {
        path = "window.header.showTotals", type = "bool", default = false,
        page = "header", group = L["Header text"],
        label = L["Show totals"], desc = L["Show the group total for the sort column."],
    },
    {
        path = "window.header.font", type = "string", default = "Friz Quadrata TT",
        values = lsmValues("font"), dialogControl = "LSM30_Font",
        page = "header", group = L["Header text"],
        label = L["Font"], desc = L["Font used for every number in the grid. A monospace font such as JetBrains Mono keeps columns from shifting as the numbers change; the default matches the window header."],
    },
    {
        path = "window.header.size", type = "number", default = 12,
        min = 6, max = 32, step = 1, fmt = "%d px",
        page = "header", group = L["Header text"],
        label = L["Font size"], desc = L["Text size in pixels."],
    },
    {
        path = "window.header.outline", type = "string", default = "OUTLINE",
        values = OUTLINE_VALUES, sorting = OUTLINE_SORT,
        page = "header", group = L["Header text"],
        label = L["Font outline"], desc = L["Outline and monochrome flags applied to the text."],
    },
    {
        path = "window.header.color", type = "color",
        default = { r = 1, g = 0.82, b = 0, a = 1 },
        page = "header", group = L["Header text"],
        label = L["Text color"], desc = L["Color of the numbers and names."],
    },
    {
        path = "window.header.align", type = "string", default = "LEFT",
        values = ALIGN_VALUES, sorting = ALIGN_SORT,
        page = "header", group = L["Header background"],
        label = L["Alignment"], desc = L["Where the header text sits horizontally."],
    },
    {
        path = "window.header.height", type = "number", default = 18,
        min = 8, max = 48, step = 1, fmt = "%d px",
        page = "header", group = L["Header background"],
        label = L["Header height"], desc = L["Height of the header strip in pixels."],
    },
    {
        path = "window.header.bgColor", type = "color",
        default = { r = 0, g = 0, b = 0, a = 0.5 },
        page = "header", group = L["Header background"],
        label = L["Header background"], desc = L["Color drawn behind the header text."],
    },

    -- ── Rows ─────────────────────────────────────────────────────────────────
    {
        path = "window.rows.maxRows", type = "number", default = 0,
        min = 0, max = Const.MAX_ROWS, step = 1,
        page = "rows", group = L["Row layout"],
        label = L["Maximum rows"],
        desc = L["Largest number of rows to draw. Set to 0 to draw as many as the window has room for."],
        validate = isNumberIn(0, Const.MAX_ROWS),
    },
    {
        path = "window.rows.height", type = "number", default = 16,
        min = 8, max = 40, step = 1, fmt = "%d px",
        page = "rows", group = L["Row layout"],
        label = L["Row height"], desc = L["Height of one row in pixels."],
    },
    {
        path = "window.rows.spacing", type = "number", default = 1,
        min = 0, max = 10, step = 1, fmt = "%d px",
        page = "rows", group = L["Row layout"],
        label = L["Row spacing"], desc = L["Gap in pixels between adjacent rows."],
    },
    {
        path = "window.rows.growthDirection", type = "string", default = "DOWN",
        values = GROWTH_VALUES, sorting = GROWTH_SORT,
        page = "rows", group = L["Row layout"],
        label = L["Growth direction"], desc = L["Whether rows stack downward from the header or upward from the bottom."],
    },
    {
        path = "window.rows.alwaysShowSelf", type = "bool", default = true,
        page = "rows", group = L["Row behavior"],
        label = L["Always show yourself"],
        desc = L["Keep your own row visible even when it would fall outside the maximum row count."],
    },
    {
        path = "window.rows.highlightSelf", type = "bool", default = true,
        page = "rows", group = L["Row behavior"],
        label = L["Highlight yourself"], desc = L["Mark your own row so it stands out at a glance."],
    },
    {
        path = "window.rows.classBackground", type = "bool", default = true,
        page = "rows", group = L["Row behavior"],
        label = L["Class-colored row background"],
        desc = L["Tint each row with the player's class color. Rows with no class fall back to the alternating stripe."],
    },
    {
        path = "window.rows.classBackgroundAlpha", type = "number", default = 0.1,
        min = 0, max = 1, step = 0.05, isPercent = true,
        page = "rows", group = L["Row behavior"],
        label = L["Row background opacity"],
        desc = L["How strong the class tint is. Low values read as a tint rather than as a second bar."],
    },
    {
        path = "window.rows.alternatingBackground", type = "bool", default = true,
        page = "rows", group = L["Row behavior"],
        label = L["Alternating background"],
        desc = L["Shade every other row slightly so the grid is easier to read across."],
    },
    {
        path = "window.rows.mouseoverHighlight", type = "bool", default = true,
        page = "rows", group = L["Row behavior"],
        label = L["Highlight on mouseover"], desc = L["Brighten the row under the cursor."],
    },

    -- ── Bars ─────────────────────────────────────────────────────────────────
    -- `class` is the default because classFilename is NeverSecret: a class-colored
    -- bar is still correct at the height of a pull, when every number on the row is
    -- an opaque handle.
    {
        path = "window.bars.texture", type = "string", default = "Blizzard Raid Bar",
        values = lsmValues("statusbar"), dialogControl = "LSM30_Statusbar",
        page = "bars", group = L["Bar appearance"],
        label = L["Bar texture"], desc = L["LibSharedMedia statusbar texture used for every cell's bar."],
    },
    {
        path = "window.bars.colorMode", type = "string", default = "class",
        values = BARCOLOR_VALUES, sorting = BARCOLOR_SORT,
        page = "bars", group = L["Bar appearance"],
        label = L["Bar color mode"],
        desc = L["Color bars by the player's class, by which statistic the column shows, or with one color everywhere."],
    },
    -- Only read when `colorMode == "custom"`, and deliberately NOT disabled on the
    -- other two modes: a player picking their color before switching the mode is
    -- the normal order of operations, and a greyed-out swatch makes that a
    -- two-visit job.
    {
        path = "window.bars.customColor", type = "color",
        default = { r = 0.35, g = 0.55, b = 0.85, a = 1 },
        page = "bars", group = L["Bar appearance"],
        label = L["Bar color"], desc = L["Fill color used when the color mode is set to Custom color."],
    },
    {
        path = "window.bars.alpha", type = "number", default = 1.0,
        min = 0, max = 1, step = 0.05, isPercent = true,
        page = "bars", group = L["Bar appearance"],
        label = L["Bar opacity"], desc = L["Opacity of the filled part of each bar."],
        validate = isNumberIn(0, 1),
    },
    {
        path = "window.bars.fillDirection", type = "string", default = "LEFT",
        values = SIDE_VALUES, sorting = SIDE_SORT,
        page = "bars", group = L["Bar appearance"],
        label = L["Fill direction"], desc = L["Which edge of the cell each bar grows from."],
    },
    {
        path = "window.bars.bgColorMode", type = "string", default = "class",
        values = BARBG_VALUES, sorting = BARBG_SORT,
        page = "bars", group = L["Bar background color"],
        label = L["Bar background color mode"],
        desc = L["What colors the tint behind each bar. Class is the default and keeps working mid-fight, because a class is never hidden the way a number is."],
    },
    {
        path = "window.bars.bgColor", type = "color",
        default = { r = 0, g = 0, b = 0, a = 1 },
        page = "bars", group = L["Bar background color"],
        label = L["Bar background color"], desc = L["Color drawn behind the unfilled part of each bar."],
    },
    {
        path = "window.bars.bgAlpha", type = "number", default = 0.1,
        min = 0, max = 1, step = 0.05, isPercent = true,
        page = "bars", group = L["Bar background color"],
        label = L["Bar background opacity"], desc = L["Opacity of the unfilled part of each bar."],
        validate = isNumberIn(0, 1),
    },
    {
        path = "window.bars.border", type = "bool", default = false,
        page = "bars", group = L["Bar background color"],
        label = L["Bar border"], desc = L["Draw a thin outline around each bar."],
    },

    -- ── Text ─────────────────────────────────────────────────────────────────
    -- Two slots per cell. Nothing here divides anything: `numberFormat` picks WHICH
    -- NumericRuleFormatter instance modules/Format.lua hands the value to, and the
    -- formatter does the division natively — the only legal way to render "12.4M"
    -- from a secret (design §4).
    {
        path = "window.text.leftSlot", type = "string", default = "none",
        values = LEFTSLOT_VALUES, sorting = LEFTSLOT_SORT,
        page = "text", group = L["Cell text"],
        label = L["Left text"], desc = L["What to show on the left of each cell. Set it to Total for the `1.41M  83.2K` pair; leave it empty for the per-second figure alone."],
    },
    {
        path = "window.text.rightSlot", type = "string", default = "rate",
        values = RIGHTSLOT_VALUES, sorting = RIGHTSLOT_SORT,
        page = "text", group = L["Cell text"],
        label = L["Right text"],
        desc = L["What to show on the right of each cell. Per-second figures are only shown for Damage and Healing."],
    },
    {
        path = "window.text.numberFormat", type = "string", default = "abbreviated",
        values = NUMFMT_VALUES, sorting = NUMFMT_SORT,
        page = "text", group = L["Cell text"],
        label = L["Number format"], desc = L["Abbreviate large numbers (12.4M) or show them in full (12,400,000)."],
    },
    {
        -- 20 rather than WoW's 12-character player-name limit: a group meter also
        -- shows NPC names — follower-dungeon companions, and the enemy rows the
        -- damage-taken columns are made of — and those are not bound by it.
        -- 0 is the explicit off switch.
        path = "window.text.maxNameLength", type = "number", default = 20,
        min = 0, max = 40, step = 1, fmt = "%d",
        page = "text", group = L["Cell text"],
        label = L["Max name length"],
        desc = L["Truncate a name past this many characters. 0 shows the whole name. The realm is always stripped."],
    },
    {
        path = "window.text.font", type = "string", default = "Friz Quadrata TT",
        values = lsmValues("font"), dialogControl = "LSM30_Font",
        page = "text", group = L["Cell text"],
        label = L["Font"],
        desc = L["Font used for every number in the grid. A monospace font such as JetBrains Mono keeps columns from shifting as the numbers change; the default matches the window header."],
    },
    {
        path = "window.text.size", type = "number", default = 11,
        min = 6, max = 32, step = 1, fmt = "%d px",
        page = "text", group = L["Cell text"],
        label = L["Font size"], desc = L["Text size in pixels."],
    },
    {
        path = "window.text.outline", type = "string", default = "NONE",
        values = OUTLINE_VALUES, sorting = OUTLINE_SORT,
        page = "text", group = L["Cell text"],
        label = L["Font outline"], desc = L["Outline and monochrome flags applied to the text."],
    },
    {
        path = "window.text.shadow", type = "bool", default = true,
        page = "text", group = L["Cell text"],
        label = L["Text shadow"],
        desc = L["Draw a drop shadow behind the text so it stays readable over a bright bar."],
    },
    {
        path = "window.text.color", type = "color",
        default = { r = 1, g = 1, b = 1, a = 1 },
        page = "text", group = L["Cell text"],
        label = L["Text color"], desc = L["Color of the numbers and names."],
    },
    {
        path = "window.text.alpha", type = "number", default = 1.0,
        min = 0, max = 1, step = 0.05, isPercent = true,
        page = "text", group = L["Cell text"],
        label = L["Text opacity"], desc = L["Opacity of the numbers and names."],
        validate = isNumberIn(0, 1),
    },

    -- ── Icons ────────────────────────────────────────────────────────────────
    -- classFilename and specIconID are NeverSecret, so these render correctly even
    -- mid-pull when every number beside them is opaque.
    {
        path = "window.icons.showClass", type = "bool", default = true,
        page = "icons", group = L["Row icons"],
        label = L["Show class icon"], desc = L["Show each player's class icon beside their name."],
    },
    {
        path = "window.icons.showSpec", type = "bool", default = false,
        page = "icons", group = L["Row icons"],
        label = L["Show specialization icon"], desc = L["Show each player's specialization icon beside their name."],
    },
    {
        path = "window.icons.showRole", type = "bool", default = false,
        page = "icons", group = L["Row icons"],
        label = L["Show role icon"], desc = L["Show a tank, healer or damage icon beside each player's name."],
    },
    {
        path = "window.icons.size", type = "number", default = 14,
        min = 8, max = 32, step = 1, fmt = "%d px",
        page = "icons", group = L["Row icons"],
        label = L["Icon size"], desc = L["Size of the row icons in pixels."],
    },
    {
        path = "window.icons.position", type = "string", default = "LEFT",
        values = SIDE_VALUES, sorting = SIDE_SORT,
        page = "icons", group = L["Row icons"],
        label = L["Icon position"], desc = L["Which side of the player's name the icons sit on."],
    },

    -- ── Tooltip ──────────────────────────────────────────────────────────────
    {
        path = "window.tooltip.anchor", type = "string", default = "CURSOR",
        values = ANCHOR_VALUES, sorting = ANCHOR_SORT,
        page = "tooltip", group = L["Tooltip behavior"],
        label = L["Tooltip anchor"], desc = L["Where the tooltip appears relative to the cursor or the window."],
    },
    {
        path = "window.tooltip.showSpells", type = "bool", default = true,
        page = "tooltip", group = L["Tooltip behavior"],
        label = L["Show spell breakdown"], desc = L["List the individual spells behind a cell's number when you hover it."],
    },
    {
        path = "window.tooltip.maxSpells", type = "number", default = 10,
        min = 1, max = 30, step = 1,
        page = "tooltip", group = L["Tooltip behavior"],
        label = L["Maximum spells"], desc = L["How many spells to list in the breakdown before stopping."],
        validate = isNumberIn(1, 30),
    },
    {
        path = "window.tooltip.showAllStatsOnName", type = "bool", default = true,
        page = "tooltip", group = L["Tooltip behavior"],
        label = L["Summarize on the name"],
        desc = L["Hovering a player's name shows every enabled statistic for that player at once."],
    },
    -- Off by default. Nothing about a tooltip is unsafe in combat — its numbers go
    -- through the formatter like every other — but a tooltip under the cursor
    -- during a pull is in the way, so this is a preference rather than a guard.
    {
        path = "window.tooltip.hideInCombat", type = "bool", default = false,
        page = "tooltip", group = L["Tooltip behavior"],
        label = L["Hide tooltips in combat"],
        desc = L["Suppress tooltips while you are in combat so nothing sits under your cursor mid-pull."],
    },

    -- ── Visibility ───────────────────────────────────────────────────────────
    -- Refused AT THE SOURCE (performance-§6): a hidden window does not merely skip
    -- its draw, it stops asking the provider for data. That is why every row here
    -- carries an onChange — the effect is a window appearing or disappearing, which
    -- is the show ladder's decision and not a redraw.
    {
        path = "window.visibility.dungeon", type = "bool", default = true,
        page = "visibility", group = L["Where to show this window"],
        label = L["Dungeons"], desc = L["Show this window in five-player dungeons, including Mythic+."],
        onChange = refreshVisibility,
    },
    {
        path = "window.visibility.raid", type = "bool", default = true,
        page = "visibility", group = L["Where to show this window"],
        label = L["Raids"], desc = L["Show this window in raid instances."],
        onChange = refreshVisibility,
    },
    {
        path = "window.visibility.arena", type = "bool", default = true,
        page = "visibility", group = L["Where to show this window"],
        label = L["Arenas"], desc = L["Show this window in arena matches."],
        onChange = refreshVisibility,
    },
    {
        path = "window.visibility.battleground", type = "bool", default = true,
        page = "visibility", group = L["Where to show this window"],
        label = L["Battlegrounds"], desc = L["Show this window in battlegrounds."],
        onChange = refreshVisibility,
    },
    {
        path = "window.visibility.world", type = "bool", default = false,
        page = "visibility", group = L["Where to show this window"],
        label = L["Open world"], desc = L["Show this window outside instances."],
        onChange = refreshVisibility,
    },
    {
        path = "window.visibility.hideWhenSolo", type = "bool", default = true,
        page = "visibility", group = L["Extra rules"],
        label = L["Hide when solo"], desc = L["Hide the window whenever you are not in a party or raid."],
        onChange = refreshVisibility,
    },
    {
        path = "window.visibility.hideInVehicle", type = "bool", default = true,
        page = "visibility", group = L["Extra rules"],
        label = L["Hide in vehicles"], desc = L["Hide the window while you are controlling a vehicle."],
        onChange = refreshVisibility,
    },

    -- ── Columns ──────────────────────────────────────────────────────────────
    -- No rows. See "WHY THE COLUMNS ARE NOT ROWS" at the top of this file; the page
    -- exists in the panel and in `/mm list`, and its contents are the array.

    -- ── Data ─────────────────────────────────────────────────────────────────
    {
        path = "window.data.sessionType", type = "number", default = Const.SESSION_TYPE.Overall,
        values = SESSION_VALUES,
        page = "data", group = L["Data source"],
        label = L["Session"], desc = L["Read the current pull, or the accumulated totals for the whole run."],
    },
    {
        path = "window.data.sortMode", type = "string", default = "value",
        values = SORTMODE_VALUES, sorting = SORTMODE_SORT,
        page = "data", group = L["Data source"],
        label = L["Sort mode"],
        desc = L["How rows are ordered. Sorting by value is not possible while Blizzard's combat restriction is active, and falls back to the game's own order for the rest of the pull."],
    },
    {
        path = "window.data.sortColumn", type = "string", default = "DamageDone",
        values = STATCOL_VALUES, sorting = STATCOL_SORT,
        page = "data", group = L["Data source"],
        label = L["Sort column"], desc = L["Which column's numbers decide the row order."],
    },
    {
        -- Also toggled by clicking the sort column's header, which is how most
        -- players will ever touch it. The row exists so the CLI and the panel can
        -- reach it too, and so the setting has one documented home.
        path = "window.data.sortAscending", type = "bool", default = false,
        page = "data", group = L["Data source"],
        label = L["Sort ascending"],
        desc = L["Put the smallest numbers at the top. Off means largest first, which is what a meter is usually read for."],
    },
    -- Clamped to the constants rather than to literals, so the floor that exists to
    -- stop one rebuild per meter event is stated once (core/Constants.lua).
    {
        path = "window.data.mergePets", type = "bool", default = false,
        page = "data", group = L["Data source"],
        label = L["Merge pets into their owner"],
        desc = L["Add a pet's numbers to its owner's row instead of giving it its own. Blizzard's combat restriction forbids the addition while you are fighting, so a merged pet's numbers are missing until the pull ends."],
    },
    {
        path = "window.data.throttle", type = "number", default = 0.25,
        min = Const.THROTTLE_MIN, max = Const.THROTTLE_MAX, step = 0.05, fmt = "%.2fs",
        page = "data", group = L["Data source"],
        label = L["Refresh interval"],
        desc = L["Seconds between refreshes. Lower is more responsive and costs more; the display updates at most this often no matter how fast the game reports numbers."],
        validate = isNumberIn(Const.THROTTLE_MIN, Const.THROTTLE_MAX),
    },

    -- ── General ──────────────────────────────────────────────────────────────
    -- The only genuinely addon-wide settings. Everything else is per-window.
    {
        path = "enabled", type = "bool", default = true,
        page = "general", group = L["Master controls"],
        label = L["Enable Mythic Meters"],
        desc = L["Master switch for the addon. When off, no window is drawn and no data is read."],
        onChange = refreshVisibility,
    },
    -- The one inverted row: LibDBIcon owns this table and its key is `hide`, while
    -- a checkbox the user reads has to be phrased positively. See "Inversion".
    {
        path = "minimap.hide", type = "bool", default = false, invert = true,
        page = "general", group = L["Master controls"],
        label = L["Show minimap button"], desc = L["Show the minimap button for opening these settings."],
        onChange = refreshMinimap,
    },
    -- ── Session-only rows ──
    --
    -- Never persisted, so they have no home in the defaults tree and are exempt
    -- from ValidateSchema's resolution check. They are rows anyway because they
    -- belong on the page and in `/mm list` beside the settings they sit next to —
    -- a toggle that exists only in the panel is a toggle the CLI cannot reach.
    {
        path = "state.testMode", type = "bool", default = false, sessionOnly = true,
        page = "general", group = L["Master controls"],
        label = L["Test mode"],
        desc = L["Fill every window with placeholder data so you can lay out columns without being in combat."],
        get = function() return NS.State and NS.State.testMode or false end,
        set = function(v)
            -- Through the registry when it is up (unlocking and preview are coupled
            -- there), and through the state writer otherwise, which is the sole
            -- sender of TEST_MODE_CHANGED either way.
            local M = NS.WindowManager
            if M and M.SetTestMode then
                M:SetTestMode(v)
                -- Same rule as `/mm test`: leaving test mode is not closing the
                -- window. See settings/Slash.lua's doTest.
                if not v then
                    for _, inst in ipairs(M.All()) do inst:Show() end
                end
                return
            end
            if NS.State then NS.State.SetTestMode(v) end
        end,
    },
    -- The console WINDOW's visibility, NOT the logging flag: logging runs with the
    -- console closed so a bug can be reproduced first and the log read afterwards,
    -- and the flag itself is session-only state that `/mm debug on|off` owns
    -- (debug-logging-§5).
    {
        path = "state.debugConsole", type = "bool", default = false, sessionOnly = true,
        page = "general", group = L["Debug"],
        label = L["Debug console"],
        desc = L["Show or hide the on-screen debug console. Session only; it does not turn debug logging on."],
        get = function() return NS.DebugLog ~= nil and NS.DebugLog:IsShown() end,
        set = function(v)
            local D = NS.DebugLog
            if not D then return end
            if v then D:Show() else D:Hide() end
        end,
    },

    -- ── Profiles ─────────────────────────────────────────────────────────────
    -- No rows, and that is enforced twice: AceDBOptions supplies the controls, and
    -- `page == "profiles"` is the reset-all veto in settings/OptionsSetup.lua,
    -- because resetting a profile row deletes user data rather than restoring a
    -- default (options-ui-§3).
}

-- ---------------------------------------------------------------------------
-- The index
-- ---------------------------------------------------------------------------
--
-- path -> row, so a lookup is a hash hit rather than a walk of ~75 rows. Rebuilt
-- rather than appended to, so it cannot fall out of step with the array after a
-- late registration.

local index = {}

local function reindex()
    for k in pairs(index) do index[k] = nil end
    for _, row in ipairs(NS.Schema) do
        index[row.path] = row
    end
end

reindex()

--- The row for `path`, or nil.
--- @param path string
--- @return table|nil
function NS.FindSchemaRow(path)
    if type(path) ~= "string" then return nil end
    return index[path]
end

--- Append rows declared elsewhere (a page file with a row whose `values` cannot be
--- expressed until that page's helpers exist) and rebuild the index.
---
--- The append seam exists so such a row still lands in THIS array — the one the
--- CLI, the panel and the reset all read — rather than in a second list one of the
--- three would inevitably miss.
---
--- @param rows table  array of rows
function NS.RegisterSchemaRows(rows)
    if type(rows) ~= "table" then return end
    for _, row in ipairs(rows) do
        NS.Schema[#NS.Schema + 1] = row
    end
    reindex()
end

-- ---------------------------------------------------------------------------
-- The read seam
-- ---------------------------------------------------------------------------

--- The current value of `path`, in DISPLAY terms (inverted rows are un-inverted
--- here, which is why the panel and the CLI both agree with the label).
---
--- Also resolves paths that are not rows — `window.columns`, or a sub-table like
--- `window.frame` — because `/mm get` is a debugging tool as much as a settings
--- reader and refusing to show a node that plainly exists helps nobody.
---
--- @param path string
--- @return any
function NS.GetSetting(path)
    if type(path) ~= "string" then return nil end

    local row = index[path]
    if row and row.sessionOnly then
        -- Returned rather than `and`-ed through: a session row answering `false` is
        -- a real answer, and `row.get() or nil` would turn every "off" into "no
        -- such setting" — which reads to the CLI as a missing row.
        if row.get then return row.get() end
        return nil
    end

    local parts = splitPath(path)
    local root, first = resolveRoot(parts)
    if not root then return nil end

    local value = readFrom(root, parts, first)
    if row then return toDisplay(row, value) end
    return value
end

-- ---------------------------------------------------------------------------
-- The write seam
-- ---------------------------------------------------------------------------

local COLUMNS_PREFIX = WINDOW_PREFIX .. ".columns"

--- The tail EVERY write shares: log once, announce once, re-sync the panel.
---
--- Factored out because the columns carve-out below is a second writer into the
--- same config tree, and a carve-out that skipped the announcement would be a
--- setting that changes without any window hearing about it — which is precisely
--- the failure the single-seam rule exists to prevent.
---
--- The format is DEFERRED into NS.Debug (debug-logging-§10) rather than built
--- here, so a disabled log costs nothing.
---
--- @param page string      the CONFIG_CHANGED section
--- @param windowId number|nil
--- @param fmt string       debug format
--- @param a any
--- @param b any
local function announceWrite(page, windowId, fmt, a, b)
    -- Logged ONCE, here. Downstream reactors must not re-echo the same value: a
    -- settings change that appears three times in the log is three changes as far
    -- as a reader can tell.
    if NS.Debug then NS.Debug("Set", fmt, a, b) end

    -- The ONE sender of CONFIG_CHANGED (architecture-§4). `section` is the row's
    -- page key, which is also the window config group it lives in, so a subscriber
    -- can skip work for a group it does not draw.
    if NS.SendMessage then
        NS:SendMessage(MSG.CONFIG_CHANGED, { section = page, windowId = windowId })
    end

    -- In-place scalar refresh, never a structural one. A widget's own set() already
    -- calls this, so the cost of repeating it is one pcall'd loop; a structural
    -- RefreshAllPanels here would rebuild the page under a slider mid-drag, which
    -- is what writing a value emphatically does not change (no row appeared or
    -- disappeared). It is what keeps a `/mm set` visible on an open panel.
    local H = NS.Helpers
    if H and H.RefreshScalars then H.RefreshScalars() end
end

-- ---------------------------------------------------------------------------
-- The columns carve-out
-- ---------------------------------------------------------------------------
--
-- See "WHY THE COLUMNS ARE NOT ROWS" at the top of this file. A column array has
-- no schema row, so it gets none of a row's `validate` — which means the check
-- has to live here and has to be at least as strict. Everything downstream
-- (modules/Row.lua's cell builder, modules/Window.lua's header) indexes
-- `stat`, `width` and `showBar` without re-checking any of them.

-- The bounds the Columns page's own width slider produces. Stated here as well
-- because the CLI and a hand-edited SavedVariables reach this seam without ever
-- touching that slider, and a column 4000px wide is a window with one column in it.
local COLUMN_MIN_WIDTH, COLUMN_MAX_WIDTH = 24, 240

--- Validate a candidate column array and return a FRESH one built entry by entry.
---
--- Rebuilding rather than accepting the caller's table does two jobs at once: the
--- stored array can never share a sub-table with whoever handed it over (the
--- classic profile-aliasing bug), and any extra key someone smuggled in is dropped
--- rather than persisted into a profile the renderer will not read.
---
--- @param value any
--- @return table|nil columns, string|nil err
local function normalizeColumns(value)
    if type(value) ~= "table" then
        return nil, L["Columns must be a list of columns, not %s."]:format(type(value))
    end

    local n = #value
    if n == 0 then
        return nil, L["A window must keep at least one column."]
    end

    -- A hole or a string key would make `#value` an arbitrary answer, so the array
    -- shape is proved rather than assumed before anything is read out of it.
    local keys = 0
    for _ in pairs(value) do keys = keys + 1 end
    if keys ~= n then
        return nil, L["Columns must be a plain ordered list with no gaps."]
    end

    local out, seen = {}, {}
    for i = 1, n do
        local c = value[i]
        if type(c) ~= "table" then
            return nil, L["Column %d is not a column."]:format(i)
        end

        local stat = c.stat
        if type(stat) ~= "string" or not Const.STAT_BY_KEY[stat] then
            return nil, L["Column %d names a statistic this build does not have: %s"]
                :format(i, tostring(stat))
        end
        -- One column per stat: two Damage columns show identical numbers twice and
        -- double the provider reads for them.
        if seen[stat] then
            return nil, L["Column %d repeats the statistic %s."]:format(i, stat)
        end
        seen[stat] = true

        local width = c.width
        -- `width ~= width` is the NaN test: NaN passes every comparison below and
        -- would reach SetWidth as a size no frame can be given.
        if type(width) ~= "number" or width ~= width
            or width < COLUMN_MIN_WIDTH or width > COLUMN_MAX_WIDTH then
            return nil, L["Column %d has a width outside %d-%d: %s"]
                :format(i, COLUMN_MIN_WIDTH, COLUMN_MAX_WIDTH, tostring(width))
        end

        if type(c.showBar) ~= "boolean" then
            return nil, L["Column %d's show-bar flag is not true or false."]:format(i)
        end

        out[i] = { stat = stat, width = width, showBar = c.showBar }
    end

    return out
end

--- Write the whole column array of the active window.
--- @param value any
--- @return boolean ok, string|nil err
local function setColumns(value)
    local cols, err = normalizeColumns(value)
    if not cols then return false, err end

    local w, id = activeWindow()
    if not w then return false, L["No window is selected."] end

    -- No copy() on the way in: normalizeColumns already returned a table built
    -- here, held by nobody else.
    w.columns = cols

    announceWrite("columns", id, "%s = %d columns", COLUMNS_PREFIX, #cols)
    return true
end

--- Write one setting. THE single write seam (settings-schema-§1): the panel's
--- widgets, `/mm set`, `/mm reset` and the defaults restore all land here, so
--- validation, the debug line, the row's reaction and the refresh cannot be
--- skipped by whichever caller forgot one.
---
--- Order is load-bearing: write, then react, then log ONCE, then announce, then
--- re-sync the panel. Reacting before the write would hand a refresher the old
--- value; logging in the reactor would log it per subscriber.
---
--- @param path string
--- @param value any
--- @return boolean ok, string|nil err
function NS.SetByPath(path, value)
    if type(path) ~= "string" then return false, L["Setting not found: %s"]:format(tostring(path)) end

    -- The columns carve-out. The array as a WHOLE is writable — that is the only
    -- granularity a path can express — while a path INTO it is refused, because the
    -- ordinal it would address moves on the next add, remove or reorder.
    if path == COLUMNS_PREFIX then
        return setColumns(value)
    end
    if path:sub(1, #COLUMNS_PREFIX + 1) == COLUMNS_PREFIX .. "." then
        return false, L["A single column is not a setting — edit columns on the Columns page."]
    end

    local row = index[path]
    if not row then
        return false, L["Setting not found: %s"]:format(path)
    end
    if row.validate and not row.validate(value) then
        return false, L["Invalid value for %s"]:format(path)
    end

    local windowId

    if row.sessionOnly then
        -- No db write by definition; the row's own set() IS the storage.
        if row.set then row.set(value) end
    else
        local parts = splitPath(path)
        local root, first, id = resolveRoot(parts)
        if not root then
            return false, L["No window is selected."]
        end
        windowId = id
        -- copy() on the way in: a color table handed straight from a widget (or
        -- from a row's default) would otherwise be shared with whoever else holds
        -- it, and editing one window's color would edit theirs.
        writeInto(root, parts, first, copy(toStored(row, value)))
    end

    if row.onChange then row.onChange(value, windowId) end

    announceWrite(row.page, windowId, "%s = %s", path, value)

    return true
end

--- Restore one row to its shipped default, through the same seam everything else
--- writes through.
---
--- Takes the ROW rather than the path because both library majors hand the row,
--- and because the deep copy a table default needs belongs on this side of the
--- seam: two profiles restored to the same color default must not end up holding
--- one table between them.
---
--- @param row table
function NS.ApplyDefault(row)
    if type(row) ~= "table" or row.path == nil then return end
    -- toDisplay, because SetByPath expects display terms and will invert back. The
    -- round trip is what keeps `default` meaning "the stored value" for the
    -- validator while the seam still sees what a user would have clicked.
    NS.SetByPath(row.path, toDisplay(row, copy(row.default)))
end

-- ---------------------------------------------------------------------------
-- Page and validation surfaces
-- ---------------------------------------------------------------------------

--- The rows of one page, in declaration order.
---
--- `filter` is the library's `ctx.unit`, passed through untouched. This addon does
--- not interpret it, and that is the whole point of the window-relative path
--- model: the panel does not filter rows per window, it MOVES the window every row
--- resolves against (NS.State.activeWindowId). The parameter is accepted so the
--- descriptor's signature is honest and so a later per-window row exclusion has
--- somewhere to go.
---
--- @param pageKey string
--- @param filter any
--- @return table  array of rows
function NS.SchemaForPage(pageKey, filter)   -- luacheck: ignore 212/filter
    local rows = {}
    for _, row in ipairs(NS.Schema) do
        if row.page == pageKey then rows[#rows + 1] = row end
    end
    return rows
end

--- Compare a schema default against a defaults-tree default. Tables are compared
--- field-wise one level deep, which is exactly as deep as this schema's table
--- defaults go (a color is `{ r, g, b, a }`).
local function sameDefault(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end

--- Prove the schema against the defaults tree. Returns the number of rows that
--- FAILED, which is 0 on a healthy load and is what the headless suite asserts on.
---
--- Two independent checks, and the second is the one this validator exists for:
---
--- 1. RESOLUTION. Every non-session path must resolve against defaults/Profile.lua
---    — window rows against WINDOW_TEMPLATE, global rows against defaults.profile.
---    A path that does not resolve is a setting whose writes land on a key nothing
---    reads: the panel renders, the widget shows the row's own default, the write
---    succeeds, and nothing anywhere says so. The row's own `default` is NOT an
---    escape hatch from this, because a row with a good default and a typo'd path
---    is the worst case rather than the exempt one.
---
--- 2. AGREEMENT. The row's `default` must EQUAL the value the defaults tree ships.
---    They are restated in two files on purpose — one is what a widget shows before
---    the db exists, the other is what a fresh profile is built from — and a
---    disagreement means a Defaults click silently moves a setting somewhere the
---    addon never shipped it. This is the bug the whole function is here to catch.
---
--- @return number  count of failing rows
function NS.ValidateSchema()
    local profile  = NS.defaults and NS.defaults.profile
    local template = NS.WINDOW_TEMPLATE
    if not (profile and template) then return 0 end

    local out = NS.Print
    local failed = 0

    for _, row in ipairs(NS.Schema) do
        if not row.sessionOnly then
            local parts = splitPath(row.path)
            local root, first
            if parts[1] == WINDOW_PREFIX then
                root, first = template, 2
            else
                root, first = profile, 1
            end

            local shipped = readFrom(root, parts, first)
            if shipped == nil then
                failed = failed + 1
                if out then out("schema path does not resolve against the defaults: " .. row.path) end
            elseif not sameDefault(shipped, row.default) then
                failed = failed + 1
                if out then out("schema default disagrees with defaults/Profile.lua: " .. row.path) end
            end
        end
    end

    return failed
end

-- ---------------------------------------------------------------------------
-- Positions
-- ---------------------------------------------------------------------------

--- Move every window back to the shipped position.
---
--- Positions are not schema rows — they are written by a drag and read only from
--- config (rule R3: a cell handed a secret value makes its own geometry secret and
--- propagates that upward, so GetPoint on a live window is not something this addon
--- may do) — so `applyDefault` never reaches them and a "reset everything" would
--- leave every window exactly where it was. This is the hook that fixes that; it is
--- wired into the options descriptor's `afterRestoreAll`, which runs BEFORE the
--- panels refresh.
---
--- Delegates to modules/WindowManager.lua when it is up, because the registry owns
--- re-anchoring a live frame. The fallback writes the config and lets the next
--- render place the window, which is correct if slower, and is what a headless
--- suite with no frames exercises.
---
--- @return number  windows moved
function NS.ResetPositions()
    local M = NS.WindowManager
    if M and M.ResetPositions then
        return tonumber(M:ResetPositions()) or 0
    end

    local template = NS.WINDOW_TEMPLATE
    local shipped  = template and template.frame and template.frame.position
    local Database = NS.Database
    if not (shipped and Database) then return 0 end

    local moved = 0
    for _, w in ipairs(Database.GetWindows()) do
        if type(w.frame) == "table" then
            w.frame.position = copy(shipped)
            moved = moved + 1
        end
    end
    return moved
end
