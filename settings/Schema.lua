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

-- Every colour-mode dropdown in one window, in the order a player meets them.
-- The META ROW on the Frame page writes this whole list; each of them is also
-- still its own row, and setting one individually afterwards is expected rather
-- than an override to defend against.
--
-- WRITTEN THROUGH NS.SetByPath, ONE AT A TIME, and not by poking the config
-- table: each target then gets its own validation, its own debug line and its own
-- CONFIG_CHANGED, which is what makes a broadcast indistinguishable from the
-- player having set all nine by hand. A fan-out that wrote the tree directly
-- would be a second write seam, and the windows would not repaint.
-- THE THREE OTHER THINGS EVERY SURFACE STATES SEPARATELY, and the meta rows that
-- set each of them everywhere at once. Same bargain as the colour mode below: the
-- individual rows all still exist, the meta stores what it last broadcast, and
-- nothing reads it back.
--
-- The tooltip's keys carry a `font` prefix of their own (`fontOutline`, not
-- `outline`), which is why these are lists of PATHS rather than a group list and
-- a suffix assumed to be shared.
local BAR_TEXTURE_PATHS = {
    "window.bars.texture",
    "window.tooltip.barTexture",
}

local FONT_PATHS = {
    "window.text.font",
    "window.header.font",
    "window.columnHeader.font",
    "window.tooltip.font",
}

local OUTLINE_PATHS = {
    "window.text.outline",
    "window.header.outline",
    "window.columnHeader.outline",
    "window.tooltip.fontOutline",
}

-- TWO TEXT SURFACES ARE DELIBERATELY ABSENT: `window.text.colorMode`, the
-- numbers in the grid, and `window.tooltip.colorMode`, the tooltip's own text.
--
-- Both of them are drawn ON TOP OF a surface this list DOES broadcast to. Sending
-- "per statistic" to the whole window therefore painted the Damage number in the
-- Damage colour over a Damage-coloured bar, and the tooltip's text in the sorted
-- stat's colour over bars carrying that same colour -- the one place where making
-- every surface agree makes the text stop being readable at all.
--
-- Foreground text is the surface whose colour has to CONTRAST with the broadcast,
-- not match it, so it stays an explicit choice. Both remain their own rows on
-- their own pages, so a player who wants the match can still ask for it; what
-- they no longer get is it happening to them from a control labelled "all
-- surfaces".
local COLOR_MODE_PATHS = {
    "window.bars.colorMode",
    "window.bars.bgColorMode",
    "window.columnHeader.colorMode",
    "window.columnHeader.bgColorMode",
    "window.tooltip.barColorMode",
    "window.tooltip.barBgColorMode",
}

--- Broadcast one colour mode to every surface of the window.
---
--- THE META ROW IS A SHORTCUT, NOT A SOURCE OF TRUTH. It stores what was last
--- broadcast and nothing reads it back: every surface keeps its own mode, and a
--- player who then changes one individually has changed one, not "overridden" the
--- meta. The alternative -- deriving the meta from the nine and showing "mixed"
--- when they disagree -- makes a control that cannot be set to the thing it is
--- showing, which is worse than a shortcut that goes stale.
---
--- The meta's own path is deliberately absent from the list above, so this cannot
--- re-enter.
---
--- NOT DURING A RESET. "Restore this page's defaults" on the Frame page walks
--- every row of that page through NS.ApplyDefault, and a meta row that broadcast
--- from there would make the Frame page's Defaults button silently reset ten
--- settings on three other pages -- a button reaching past its own page, which is
--- the one thing a per-page reset must not do. The flag is set for exactly the
--- length of that call and is the narrowest way to say "this write is a restore,
--- not a click".
---
--- @param paths table   the surfaces to write
--- @param value any      the value to write to each
local function broadcast(paths, value)
    if NS.__restoring then return end
    if value == nil or value == "" then return end
    for _, path in ipairs(paths) do
        NS.SetByPath(path, value)
    end
end

--- @param value string  "class" | "stat" | "custom"
local function broadcastColorMode(value) broadcast(COLOR_MODE_PATHS, value) end

--- @param value string  an LSM statusbar key
local function broadcastBarTexture(value) broadcast(BAR_TEXTURE_PATHS, value) end

--- @param value string  an LSM font key
local function broadcastFont(value) broadcast(FONT_PATHS, value) end

--- @param value string  NONE | OUTLINE | THICKOUTLINE | MONOCHROME
local function broadcastOutline(value) broadcast(OUTLINE_PATHS, value) end

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
-- The colour MODE every text surface offers, and the one the two header
-- backgrounds offer too. Three entries rather than the bar background's four:
-- `none` is a legal answer for a tint drawn behind something and never for the
-- writing itself, and a text surface set to "no colour" is one nobody can read.
--
-- WHAT `stat` MEANS DEPENDS ON THE SURFACE, and each reader names which it took.
-- A CELL is about the statistic in its own column; a COLUMN HEADER about the
-- column it labels -- the one surface where "per statistic" is literally per
-- column; the TITLE BAR and the TOOLTIP about the window's SORT COLUMN, the
-- statistic the grid is currently ranked by. One question, answered by whichever
-- statistic the surface actually describes.
local TEXTCOLOR_VALUES = {
    class  = L["Class color"],
    stat   = L["Per-statistic color"],
    custom = L["Custom color"],
}
local TEXTCOLOR_SORT = { "class", "stat", "custom" }

local BARBG_VALUES = {
    class  = L["Class color"],
    stat   = L["Per-statistic color"],
    custom = L["Custom color"],
    none   = L["None"],
}
local BARBG_SORT = { "class", "stat", "custom", "none" }

-- TWO modes, not the three every text surface offers. "Per-statistic" cannot say anything true
-- about a header BUTTON: a close box does not belong to a statistic, so the option could only
-- ever paint it the sort column's colour -- which is a fact already on screen in that column's
-- own header and in its arrow.
local CONTROLCOLOR_VALUES = {
    class  = L["Class color"],
    custom = L["Custom color"],
}
local CONTROLCOLOR_SORT = { "class", "custom" }

-- The divider's three, and the extra one is the point. `skin` is not "a colour
-- that happens to match the skin" -- it is *don't touch the texture*, so whatever
-- LibKa0s-Core-1.0's ApplySkin just wrote stands. That is what keeps a re-skin
-- landing on this window along with the debug console and the perf panel
-- (standalone-windows): the shared value is never copied into this repo, never
-- stored in a profile, and never has to be migrated when it changes.
--
-- NO `stat` MODE, for the reason the header's other surfaces do not have one: the
-- divider is one line across the whole window, so "per statistic" could only ever
-- paint it the sort column's colour -- a fact already on screen twice over.
local DIVIDERCOLOR_VALUES = {
    skin   = L["Ka0s skin"],
    class  = L["Class color"],
    custom = L["Custom color"],
}
local DIVIDERCOLOR_SORT = { "skin", "class", "custom" }

-- ONE set for both slots, and EVERY VALUE IS LITERAL — modules/Row.lua renders
-- exactly what is asked for and never falls back to another figure. `none` in
-- particular means nothing at all, which it did not always: both slots set to
-- None used to still print the total, so the setting appeared to do nothing.
--
-- `smart` is the only value whose meaning depends on the column — the per-second
-- figure where the stat has one, the absolute figure everywhere else — and it is
-- what the left slot ships as. A counting stat still renders nothing for `rate`,
-- because "0.42 interrupts per second" is not a thing a meter should say; that is
-- a property of the STAT, not of the slot.
-- The two smart values are named for what they DO rather than being "smart" and
-- "smarter". Both branch on whether the column has a per-second figure at all --
-- that is what makes them smart -- and they differ in what they do with the
-- answer: one PICKS (the rate where there is one, the total otherwise) and the
-- other SHOWS BOTH, falling back to the total alone on a counting stat where
-- "0.42 interrupts per second" is not a thing a meter should say.
local SLOT_VALUES = {
    none     = L["None"],
    smart    = L["Smart value (Per Second or Absolute)"],
    combined = L["Smart value (Absolute | Per Second)"],
    total    = L["Absolute value"],
    rate     = L["Per second value"],
    percent  = L["Percent"],
}
local SLOT_SORT   = { "none", "smart", "combined", "total", "rate", "percent" }

-- HOW MANY DECIMALS, plus the un-abbreviated form. The three abbreviating entries
-- are ONE ladder at three fraction divisors (modules/Format.lua's scaledLadder);
-- `full` is the other formatter entirely.
--
-- NO THOUSANDS-SEPARATOR ENTRY, and there cannot be one. Grouping a number means
-- reading its digits, and every figure in this grid is a SECRET value for the
-- whole of a pull -- BreakUpLargeNumbers takes a plain number and raises on a
-- handle (design §4). What "Full" renders is every digit, unseparated, which is
-- what the client's own formatter can produce without inspecting anything.
local NUMFMT_VALUES  = {
    abbreviated      = L["Abbreviated (12.4M)"],
    abbreviatedWhole = L["Abbreviated, no decimals (12M)"],
    abbreviatedTwo   = L["Abbreviated, two decimals (12.40M)"],
    full             = L["Full (12400000)"],
}
local NUMFMT_SORT    = { "abbreviated", "abbreviatedWhole", "abbreviatedTwo", "full" }

-- How a death is labelled. A third value, "time into the fight", was built and
-- removed: nothing on the client can date a past death against the run it
-- happened in. See the note on modules/Format.lua's DeathTime.
local DEATHTIME_VALUES = {
    clock = L["Time of day"],
    ago   = L["How long ago"],
}
local DEATHTIME_SORT = { "clock", "ago" }

-- Every ANCHOR_* token GameTooltip:SetOwner accepts, minus ANCHOR_NONE and
-- ANCHOR_PRESERVE — both of which mean "the caller places it itself", which is
-- the one thing this addon may not do: a cell handed a secret value has secret
-- geometry, so there is no legal way to compute a point from it (rule R3).
-- Ordered cursor first, then the four edges, then the four corners.
-- NO "At cursor". It was the shipped default and it is what every other tooltip
-- in the game does, which is exactly the trouble: over a grid it lands wherever
-- the pointer happens to be inside a cell, so the same hover puts the tooltip in
-- a different place every time and reads as jitter rather than as a choice. TOP
-- is the deliberate version of the same thing -- above the cell, in one place --
-- and is the default now.
local ANCHOR_VALUES  = {
    TOP         = L["Top"],
    BOTTOM      = L["Bottom"],
    LEFT        = L["Left"],
    RIGHT       = L["Right"],
    TOPLEFT     = L["Top left"],
    TOPRIGHT    = L["Top right"],
    BOTTOMLEFT  = L["Bottom left"],
    BOTTOMRIGHT = L["Bottom right"],
}
local ANCHOR_SORT    = {
    "TOP", "BOTTOM", "LEFT", "RIGHT",
    "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT",
}

-- THE SORT AND SESSION LISTS ARE GONE with the rows that used them. `sortMode`,
-- `sortColumn`, `sortAscending` and `sessionType` are written by the window's own
-- controls -- a click on a column header, a pick from the header's segment
-- dropdown -- and are no longer settings-panel rows or CLI paths. The value lists
-- went with them rather than sitting here unreferenced.

-- The export destinations, derived from the channel catalog the export module
-- reads, for the same reason: one list, two consumers, and no chance of the
-- dropdown offering a channel nothing knows how to send to. The catalog stores
-- plain English in `label` and the localization happens HERE, at the use site,
-- because core/Constants.lua may load before locales/enUS.lua.
local CHANNEL_VALUES, CHANNEL_SORT = {}, {}
for i, channel in ipairs(Const.EXPORT_CHANNELS) do
    CHANNEL_VALUES[channel.key] = L[channel.label]
    CHANNEL_SORT[i] = channel.key
end

--- One header-control label with that control's own icon in front of it.
---
--- THE STRIP IS THE INDEX INTO THIS TAB. Eight checkboxes named "Show close",
--- "Show lock", "Show segment picker" ask a player to translate a word back into
--- the glyph they were actually looking at, and the two that draw a padlock and a
--- gear were the two hardest to name. Putting the icon in the label removes the
--- translation: the tick, the picture, the words.
---
--- BAKED INTO `label` because that is the only string the library draws --
--- LibKa0s' makeCheckbox reads `row.label` and nothing else, so an `icon` field
--- beside it would be a field with no renderer. The texture escape is a PREFIX,
--- never a replacement: tests/test_schema.lua's localization case strips it and
--- checks the rest is still a locale key, so a row cannot lose its translation by
--- gaining a picture.
---
--- NIL IS A REAL ANSWER from NS.Icon -- a degraded install has no art payload at
--- all (core/MediaSetup.lua) -- and it degrades to the plain label, which is what
--- this tab drew before. The size is the shipped `controlSize` default rather
--- than the player's, because a schema row is declared once at load and a label
--- that tracked the setting would need re-declaring every time it changed.
---
--- @param art string   an entry of the library's ICONS catalog
--- @param text string   the localized label
--- @return string
local function controlLabel(art, text)
    local path = NS.Icon and NS.Icon(art)
    if not path then return text end
    return string.format("|T%s:14:14:0:0|t %s", path, text)
end

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
    -- ── Windows ───────────────────────────────────────────────────────
    -- The picker, the create/duplicate/delete buttons and the copy-settings-from
    -- control are BESPOKE (settings/Windows.lua): they act on the registry, not on
    -- a leaf, so they have no path. The window's NAME is a leaf and is here, in the
    -- one-row "Window" tab it shares with those bespoke buttons.
    {
        path = "window.name", type = "string", default = "Multi Meters",
        dialogControl = "EditBox", maxLetters = 32,
        page = "windows", group = L["Window"],
        label = L["Window name"], desc = L["Name shown in this picker and, optionally, in the window's own header."],
        validate = function(v) return type(v) == "string" and v ~= "" end,
    },

    -- ── Frame ──────────────────────────────────────────────
    -- The chrome itself is LibKa0s-Core-1.0's shared SKIN, which tints the title
    -- and the divider on its own, so the edge colors are not settings. What the
    -- player owns is geometry, the backdrop and the LSM border.
    --
    -- FOUR TABS: the window-wide answers a player reaches for first (general --
    -- the two frame-level toggles and the four "set every surface at once" meta
    -- rows), then what the window IS (size and position), what is drawn behind
    -- and around it (background and border), and last the grid it draws (row).
    -- The title bar itself moved to the Header page, first in its own "Title
    -- bar" tab -- it is what the header strip draws, not what the frame is.

    -- ── General ──────────────────────────────────────────────
    -- FIRST, because it is where a player who has just opened this page wants to
    -- land: the two window-wide toggles, and the four meta rows that set every
    -- surface in the window at once. The meta rows arrived here when the "All
    -- surfaces" tab was retired -- a tab of four shortcuts sat at the far end of
    -- the strip, which is the last place someone reaching for "make it all one
    -- font" would look.
    --
    -- Locking implies preview mode: a player positioning a window at a target
    -- dummy needs a full grid to aim at, which is why the two are one control here
    -- and why modules/WindowManager.lua owns the coupling rather than this row.
    --
    -- NO `resizeGrip` ROW, and no setting behind it. The grip is drawn whenever
    -- the window is UNLOCKED and hidden whenever it is locked, which is the same
    -- question the lock already answers. Locking a window is how you put the
    -- grip away.
    --
    -- `frame.position` is deliberately NOT a row either. It is written by a drag,
    -- it is four values with one meaning, and -- rule R3 -- it is never read back
    -- off the live frame. A global reset reaches it the way it reaches everything
    -- else: "Reset all settings" is a PROFILE reset, and a position lives in the
    -- profile. `/mm reset-positions` is the targeted verb, and it goes to
    -- modules/WindowManager.lua, which owns re-anchoring a live frame.
    {
        path = "window.frame.locked", type = "bool", default = false,
        page = "frame", group = L["General"],
        label = L["Lock window"],
        desc = L["When unlocked you can drag the window to reposition it and drag its corner to resize. Nothing else changes \226\128\148 for placeholder rows use Test mode on the General page."],
    },
    {
        path = "window.frame.clampToScreen", type = "bool", default = true,
        page = "frame", group = L["General"],
        label = L["Keep on screen"], desc = L["Prevent the window from being dragged off the edge of the screen."],
    },
    -- THE FOUR META ROWS. Each sets several other rows at once rather than being
    -- read by anything itself (see the comment on the color-mode row below for
    -- the full argument, which applies to all four). `closeButton` and the rest
    -- of the header's own controls, and the column-header strip, are edited on
    -- the Header and Columns pages now -- every one of them is still
    -- `window.frame.*` or `window.columnHeader.*` under the hood, unrenamed.
    {
        -- A META ROW: it sets seven others rather than being read by anything.
        -- Every surface in a window carries its own colour mode -- the bar and its
        -- background, both header strips and both of their backgrounds, and both
        -- of the tooltip's bars -- which is right when a player wants one of them
        -- different and tedious when they want them all the same, which is the
        -- usual case.
        --
        -- IT SKIPS THE TWO TEXT SURFACES, and COLOR_MODE_PATHS says why at
        -- length: text is drawn on top of a surface this row broadcasts to, so
        -- making it agree is what makes it unreadable.
        --
        -- IT STORES WHAT WAS LAST BROADCAST AND NOTHING READS IT BACK. A player
        -- who then changes one surface individually has changed one surface; the
        -- meta does not fight them for it and does not claim to describe them
        -- afterwards. Deriving it instead -- showing "mixed" when the seven
        -- disagree -- would make a control that cannot be set to the value it is
        -- displaying, which is worse than a shortcut that goes stale.
        path = "window.colorMode", type = "string", default = "custom",
        values = TEXTCOLOR_VALUES, sorting = TEXTCOLOR_SORT,
        page = "frame", group = L["General"],
        label = L["Color mode (all surfaces)"],
        desc = L["Set the color mode of every bar and header in this window at once. Text colors are left alone — they sit on top of these surfaces and have to contrast with them. Each surface is still its own setting, so you can change one afterwards without changing the rest."],
        onChange = broadcastColorMode,
    },
    {
        path = "window.barTexture", type = "string", default = "Blizzard Raid Bar",
        values = lsmValues("statusbar"), dialogControl = "LSM30_Statusbar",
        page = "frame", group = L["General"],
        label = L["Bar texture (all surfaces)"],
        desc = L["Set the bar texture for the grid and the tooltip at once. Each of them is still its own setting."],
        onChange = broadcastBarTexture,
    },
    {
        path = "window.font", type = "string", default = "Friz Quadrata TT",
        values = lsmValues("font"), dialogControl = "LSM30_Font",
        page = "frame", group = L["General"],
        label = L["Font (all surfaces)"],
        desc = L["Set the font for the cell text, both header strips and the tooltip at once. Each of them is still its own setting."],
        onChange = broadcastFont,
    },
    {
        path = "window.fontOutline", type = "string", default = "NONE",
        values = OUTLINE_VALUES, sorting = OUTLINE_SORT,
        page = "frame", group = L["General"],
        label = L["Font outline (all surfaces)"],
        desc = L["Set the font outline for the cell text, both header strips and the tooltip at once. Each of them is still its own setting."],
        onChange = broadcastOutline,
    },
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
        min = 0, max = 1, step = 0.01, isPercent = true,
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
    -- ── Background and border ────────────────────────────────────────
    -- Both the fill inside the window and the edge around it, together: they used
    -- to be split across "Size and position" and "Border style" for no reason
    -- beyond having been declared that way, and a player looking for "what color
    -- is my window" was looking under a heading that said border.
    {
        path = "window.frame.borderStyle", type = "string", default = "Blizzard Tooltip",
        values = lsmValues("border"), dialogControl = "LSM30_Border",
        page = "frame", group = L["Background and border"],
        label = L["Border style"], desc = L["LibSharedMedia border texture drawn around the window."],
    },
    {
        path = "window.frame.borderSize", type = "number", default = 2,
        min = 0, max = 32, step = 1, fmt = "%d px",
        page = "frame", group = L["Background and border"],
        label = L["Border thickness"], desc = L["Border edge size in pixels."],
    },
    {
        -- THE FILL INSIDE THE WINDOW, under a heading that names both. It spent
        -- a release under "Size and position" and another under "Border style",
        -- and a player looking for "what colour is my window" found it under
        -- neither.
        path = "window.frame.backdropColor", type = "color",
        default = { r = 0, g = 0, b = 0, a = 0.75 },
        page = "frame", group = L["Background and border"],
        label = L["Background color"], desc = L["Color drawn behind the rows."],
    },
    {
        path = "window.frame.borderColor", type = "color",
        default = { r = 0, g = 0, b = 0, a = 1 },
        page = "frame", group = L["Background and border"],
        label = L["Border color"], desc = L["Color of the window border."],
    },
    -- ── Row ──────────────────────────────────────────
    -- FROM THE BARS PAGE. What the first four decide -- how tall a row is, how
    -- many there are and which way they grow -- shapes every bar the window
    -- draws, so they sit with the rest of the frame's own geometry rather than
    -- with the bar's appearance. The four under them are how a row BEHAVES: who
    -- is pinned, who is highlighted, and the stripe behind every other one.
    --
    -- ONE TAB, not the two it was. "Rows" and "Row behavior" were four controls
    -- each and one subject between them, and a player deciding how their grid
    -- reads was clicking between the two to do it.
    --
    -- The PATHS stay `window.rows.*`; a row's page is where it is edited, its
    -- path is where it is stored.
    {
        path = "window.rows.maxRows", type = "number", default = 0,
        min = 0, max = Const.MAX_ROWS, step = 1,
        page = "frame", group = L["Row"],
        label = L["Maximum rows"],
        desc = L["Largest number of rows to draw. Set to 0 to draw as many as the window has room for."],
        validate = isNumberIn(0, Const.MAX_ROWS),
    },
    {
        path = "window.rows.height", type = "number", default = 16,
        min = 8, max = 40, step = 1, fmt = "%d px",
        page = "frame", group = L["Row"],
        label = L["Row height"], desc = L["Height of one row in pixels."],
    },
    {
        path = "window.rows.spacing", type = "number", default = 1,
        min = 0, max = 10, step = 1, fmt = "%d px",
        page = "frame", group = L["Row"],
        label = L["Row spacing"], desc = L["Gap in pixels between adjacent rows."],
    },
    {
        path = "window.rows.growthDirection", type = "string", default = "DOWN",
        values = GROWTH_VALUES, sorting = GROWTH_SORT,
        page = "frame", group = L["Row"],
        label = L["Growth direction"], desc = L["Whether rows stack downward from the header or upward from the bottom."],
    },
    -- `rows.alternatingBackground` joined these from Bars' "Bar background color"
    -- group. `rows.classBackground` and `rows.classBackgroundAlpha` are gone
    -- entirely, and were doing nothing before they went: the row tint is painted
    -- per CELL from `bars.bgColorMode` and `bars.bgAlpha` (modules/Row.lua's
    -- cellBackground) -- it moved there when tinting the row itself turned out to
    -- lose the separators between columns -- and these two were left behind
    -- pointing at keys nothing reads.
    {
        path = "window.rows.alwaysShowSelf", type = "bool", default = true,
        page = "frame", group = L["Row"],
        label = L["Always show yourself"],
        desc = L["Keep your own row visible even when it would fall outside the maximum row count."],
    },
    {
        path = "window.rows.highlightSelf", type = "bool", default = true,
        page = "frame", group = L["Row"],
        label = L["Highlight yourself"], desc = L["Mark your own row so it stands out at a glance."],
    },
    {
        path = "window.rows.mouseoverHighlight", type = "bool", default = true,
        page = "frame", group = L["Row"],
        label = L["Highlight on mouseover"], desc = L["Brighten the row under the cursor."],
    },
    {
        -- FROM THE ROWS PAGE, into the group that owns the other thing drawn
        -- behind a row. It is a ROW-level fact (modules/Row.lua's RowProto:Update
        -- draws it, not the cells), and its PATH says so -- but a player choosing
        -- between a class tint and a stripe was reading two pages to do it.
        path = "window.rows.alternatingBackground", type = "bool", default = true,
        page = "frame", group = L["Row"],
        label = L["Alternating background"],
        desc = L["Shade every other row slightly so the grid is easier to read across. Sits behind the bar background above, so a strong tint will hide it."],
    },

    -- ── Header ────────────────────────────────────────────────────
    --
    -- FOUR ROWS LIVED AT THE TOP OF THIS PAGE and all four are gone, because each
    -- of them said something that was already on screen.
    --
    --   `title`            a second name for a window that already has one. The
    --                      header draws `window.name` now, always, so renaming a
    --                      window renames its header and there is no way for the
    --                      two to disagree.
    --   `showSessionName`  "Overall" written beside a window the player called
    --                      Overall.
    --   `showDuration`     the segment's own length, over a header whose segment
    --                      picker names the segment.
    --   `showTotals`       a group total, over a column holding the same figure
    --                      per player.
    --
    -- What the right-hand header line still says is in modules/Window.lua's
    -- UpdateHeaderText, and it is state rather than preference: the drill-down
    -- title and the restricted notice.
    --
    -- FOUR TABS: the title bar's own shape (Title bar), the face drawn on it
    -- (Title text), then every toggle for the icon strip it carries (Controls),
    -- and how every one of those controls is drawn (Button style). The
    -- column-header strip that used to sit here as a third group moved to the
    -- Columns page it labels -- see the note there.

    -- ── Title bar ────────────────────────────────────────────────
    -- Whether it draws, and its shape: alignment, height and background. This
    -- toggle is the header page's master switch, so its path moved with it:
    -- `window.header.show`, not `window.frame.titleBar` -- a path naming `frame`
    -- for a row on the Header page misleads the next reader and reads wrong in
    -- `/mm set`.
    {
        path = "window.header.show", type = "bool", default = true,
        page = "header", group = L["Title bar"],
        label = L["Show title bar"], desc = L["Draw the title strip along the top of the window."],
    },
    {
        path = "window.header.bgColor", type = "color",
        default = { r = 0, g = 0, b = 0, a = 0.5 },
        page = "header", group = L["Title bar"],
        label = L["Header background"], desc = L["Color drawn behind the title bar. The column-header strip has its own, on the Columns page."],
    },
    {
        path = "window.header.align", type = "string", default = "LEFT",
        values = ALIGN_VALUES, sorting = ALIGN_SORT,
        page = "header", group = L["Title bar"],
        label = L["Alignment"], desc = L["Where the header text sits horizontally."],
    },
    {
        path = "window.header.height", type = "number", default = 18,
        min = 8, max = 48, step = 1, fmt = "%d px",
        page = "header", group = L["Title bar"],
        label = L["Header height"], desc = L["Height of the header strip in pixels."],
    },
    -- THE HAIRLINE BETWEEN THE TITLE BAR AND THE COLUMN LABELS, and the one piece
    -- of the window's chrome that is a setting. It earns its keep when both
    -- strips are drawn plainly and is a line across the window for nothing once
    -- the title bar's own background is doing the separating -- which is a look,
    -- so it is the player's call rather than a rule.
    --
    -- ON by default: it is what the window has always drawn, and a chrome
    -- element that disappears on upgrade is a bug report.
    --
    -- THREE ROWS, NOT ONE, and the colour mode below is where the interesting
    -- part is. `NS.ApplySkin` tints `frame.divider` from LibKa0s-Core-1.0's shared
    -- SKIN; the mode's shipped value, `skin`, does not read that table and write
    -- it -- it writes NOTHING, leaving the library's tint standing. That is what
    -- keeps standalone-windows intact through a per-window picker: the rule is
    -- "never restate SKIN's values", and nothing here restates them.
    {
        path = "window.header.divider", type = "bool", default = true,
        page = "header", group = L["Title bar"],
        label = L["Show divider"],
        desc = L["Draw the hairline between the title bar and the column labels."],
    },
    {
        path = "window.header.dividerThickness", type = "number", default = 1,
        min = 1, max = 8, step = 1, fmt = "%d px",
        page = "header", group = L["Title bar"],
        label = L["Divider thickness"],
        desc = L["How thick the hairline under the title bar is, in pixels. It grows downward, into the gap above the column labels."],
        validate = isNumberIn(1, 8),
    },
    {
        path = "window.header.dividerColorMode", type = "string", default = "skin",
        values = DIVIDERCOLOR_VALUES, sorting = DIVIDERCOLOR_SORT,
        page = "header", group = L["Title bar"],
        label = L["Divider color mode"],
        desc = L["What colors the hairline. Ka0s skin leaves it to the shared collection skin, so a re-skin reaches this window along with the debug console and the perf panel; Class color is your own class."],
    },
    {
        -- A MID GREY, and deliberately not the skin's own values. Seeding this
        -- with SKIN.divider would be the copy standalone-windows forbids -- the
        -- one that drifts a hex digit at a time and then has to be migrated -- and
        -- it would also be a lie about what the row is: this is the colour the
        -- player CHOSE, and it is read only under `custom`, where the skin has
        -- already been declined.
        path = "window.header.dividerColor", type = "color",
        default = { r = 0.5, g = 0.5, b = 0.5, a = 0.85 },
        page = "header", group = L["Title bar"],
        label = L["Divider color"],
        desc = L["Color of the hairline under the title bar, used when the mode above is Custom color."],
    },
    -- ── Title text ──────────────────────────────────────────────
    -- TWO MODES, NOT THREE, and the half that is missing is the interesting half.
    --
    -- NO `stat`. Per-statistic could only ever paint this the SORT column's
    -- colour -- a fact already on screen twice, in that column's own header and
    -- in its arrow -- and the title bar is ONE strip over the whole window rather
    -- than a thing belonging to a column. That is the same argument that took the
    -- mode off the title bar's BACKGROUND, and it still holds, which is why this
    -- row takes the CONTROLS' pair rather than the three every cell surface answers.
    --
    -- CLASS DID NOT SURVIVE THE SAME ARGUMENT, and this note used to say it had:
    -- "class could only be the local player's, which the title bar is not about --
    -- it names the window". What settled it the other way is the rest of the
    -- strip. The controls wear a class colour and so does the divider under them;
    -- a title that alone could not was the odd one out rather than the principled
    -- one, and "this header is mine" is a perfectly good thing for a player to
    -- want a window to say. It is still the LOCAL player's class, because that is
    -- the only class a window-wide strip can mean.
    {
        path = "window.header.font", type = "string", default = "Friz Quadrata TT",
        values = lsmValues("font"), dialogControl = "LSM30_Font",
        page = "header", group = L["Title text"],
        label = L["Font"], desc = L["Font used for every number in the grid. A monospace font such as JetBrains Mono keeps columns from shifting as the numbers change; the default matches the window header."],
    },
    {
        path = "window.header.size", type = "number", default = 12,
        min = 6, max = 32, step = 1, fmt = "%d px",
        page = "header", group = L["Title text"],
        label = L["Font size"], desc = L["Text size in pixels."],
    },
    {
        path = "window.header.colorMode", type = "string", default = "custom",
        values = CONTROLCOLOR_VALUES, sorting = CONTROLCOLOR_SORT,
        page = "header", group = L["Title text"],
        label = L["Text color mode"],
        desc = L["What colors the window's title and the session line beside it. Class color is your own -- a window-wide strip has no other class it could mean."],
    },
    {
        path = "window.header.color", type = "color",
        default = { r = 1, g = 0.82, b = 0, a = 1 },
        page = "header", group = L["Title text"],
        label = L["Text color"], desc = L["Color of the header's own lines."],
    },
    {
        path = "window.header.outline", type = "string", default = "OUTLINE",
        values = OUTLINE_VALUES, sorting = OUTLINE_SORT,
        page = "header", group = L["Title text"],
        label = L["Font outline"], desc = L["Outline and monochrome flags applied to the text."],
    },
    {
        path = "window.header.shadow", type = "bool", default = false,
        page = "header", group = L["Title text"],
        label = L["Text shadow"],
        desc = L["Draw a drop shadow behind the header text so it stays readable over a bright backdrop."],
    },
    -- ── The meter's controls (issue #6) ────────────────────────────────────
    -- ON THE HEADER PAGE, which is where a player looks for them. They were on
    -- Frame for as long as `frame.closeButton` was the only one of them, and the
    -- stored PATHS are still `window.frame.*` -- every one of these draws into the
    -- frame's title bar, and renaming the keys to `window.header.*` for symmetry
    -- would migrate every stored profile in exchange for a tidiness nobody can
    -- see. A row's page is where it is EDITED; its path is where it is STORED.
    --
    -- ONE GROUP, not the two it was. They were split by what they act on --
    -- "Window buttons" for close, minimise, lock and settings; "Meter buttons"
    -- for the segment text, the segment picker, reset and export -- which is a
    -- true distinction and a useless one to click through: they are eight
    -- toggles for eight icons in one strip, and a player turning that strip down
    -- to the four they use was reading two tabs to find them. Kept CONTIGUOUS,
    -- because a group heading is emitted only when `group` CHANGES between
    -- consecutive rows.
    --
    -- Every default here is stated a SECOND time in defaults/Profile.lua, and
    -- both statements are checked against each other -- see the note above on
    -- why the two are deliberately not factored into one shared constant.
    --
    -- DECLARED IN THE ORDER THE STRIP READS, left to right: the segment line,
    -- then export, reset, the segment picker, settings, lock, minimise and
    -- close. modules/HeaderControls.lua's CONTROLS table is the same set written
    -- RIGHT to left -- index 0 sits against the frame's right edge -- so the two
    -- lists are deliberately mirror images and neither is the other's source.
    -- What matters is that a player ticking a box here can find the icon it
    -- governs by counting from the same end.
    {
        -- THE TEXT, not the button below it, and they are deliberately two rows.
        -- The picker is a click target in the icon strip; this is the line that
        -- says which fight you are looking at. A player who keeps the strip tidy
        -- and still wants to know what the window is showing needs to be able to
        -- turn one off without the other.
        path = "window.frame.showSegmentText", type = "bool", default = true,
        page = "header", group = L["Controls"],
        label = L["Show segment"],
        desc = L["Name the fight this window is showing, in the header to the left of the controls."],
    },
    {
        path = "window.frame.showExport", type = "bool", default = true,
        page = "header", group = L["Controls"],
        label = controlLabel("export", L["Show export"]), desc = L["Export this window's segment to CSV or to chat."],
    },
    {
        path = "window.frame.showReset", type = "bool", default = true,
        page = "header", group = L["Controls"],
        label = controlLabel("reset", L["Show reset"]), desc = L["Clear every recorded combat session. Asks first -- it wipes the game's own meter data too, not just this addon's."],
    },
    {
        path = "window.frame.showSegment", type = "bool", default = true,
        page = "header", group = L["Controls"],
        label = controlLabel("segment", L["Show segment picker"]), desc = L["Choose which fight this window shows. The session line stays clickable either way."],
    },
    {
        path = "window.frame.showSettings", type = "bool", default = true,
        page = "header", group = L["Controls"],
        label = controlLabel("settings", L["Show settings"]), desc = L["Open this addon's settings at the window you clicked."],
    },
    {
        path = "window.frame.showLock", type = "bool", default = true,
        page = "header", group = L["Controls"],
        label = controlLabel("lock", L["Show lock"]), desc = L["Lock or unlock the window for dragging."],
    },
    {
        path = "window.frame.showMinimise", type = "bool", default = true,
        page = "header", group = L["Controls"],
        label = controlLabel("minimise", L["Show minimise"]), desc = L["Collapse the window to its title bar and back."],
    },
    {
        path = "window.frame.closeButton", type = "bool", default = true,
        page = "header", group = L["Controls"],
        label = controlLabel("close", L["Show close"]), desc = L["Draw a close button in the title bar."],
    },
    -- `frame.minimised` is a HIDDEN row: it exists so the path is writable and
    -- listable, and it draws no control on the panel. It is STATE, not a
    -- preference -- the header's minimise control writes it, and a window left
    -- collapsed comes back collapsed. As a checkbox it duplicated that control on
    -- a page you have to open to reach, and read as a setting when it is a
    -- record of what you last did. `showMinimise` -- whether the control is
    -- drawn at all -- is the preference, and it stays a checkbox above. It cannot
    -- simply be DELETED the way `frame.position` is absent, and that is the
    -- whole reason `hidden` exists: NS.SetByPath refuses a path with no row, and
    -- the minimise control writes through that seam rather than poking the
    -- config table, because SetByPath is what publishes CONFIG_CHANGED. Filed
    -- with the other controls, contiguous with them, because that is the group
    -- it would draw in if it drew at all.
    {
        path = "window.frame.minimised", type = "bool", default = false, hidden = true,
        page = "header", group = L["Controls"],
        label = L["Minimised"], desc = L["Collapsed to the title bar. The window's stored height is untouched, so expanding restores it exactly."],
    },
    -- ── Button style ──────────────────────────────────────────────
    -- How every one of the eight controls above is drawn, not what any one of
    -- them does. FOUR PAIRS, and the pairing is the layout: the reveal beside the
    -- size, then rest and hover side by side down three lines -- mode, colour,
    -- opacity. Reading down a column is reading one state; reading across a line
    -- is comparing the two, which is the question a player setting a hover
    -- actually has.
    {
        path = "window.frame.hoverReveal", type = "bool", default = true,
        page = "header", group = L["Button style"],
        label = L["Reveal controls on hover"], desc = L["Fade every control except the one under the pointer. Off keeps them all visible."],
    },
    {
        path = "window.frame.controlSize", type = "number", default = 16,
        min = 10, max = 32, step = 1,
        page = "header", group = L["Button style"],
        label = L["Control size"], desc = L["How large each header control is drawn, in pixels."],
    },
    -- Two modes rather than one, because rest and hover are two independent answers: a player who
    -- wants their class colour under the pointer has not asked for the whole strip in it at rest,
    -- and a shared mode would make hover and rest the same colour for anyone who chose class --
    -- the one thing a hover colour must never be.
    {
        path = "window.frame.controlColorMode", type = "string", default = "custom",
        values = CONTROLCOLOR_VALUES, sorting = CONTROLCOLOR_SORT,
        page = "header", group = L["Button style"],
        label = L["Control color mode"],
        desc = L["What colors the header controls at rest."],
    },
    {
        path = "window.frame.controlHoverColorMode", type = "string", default = "custom",
        values = CONTROLCOLOR_VALUES, sorting = CONTROLCOLOR_SORT,
        page = "header", group = L["Button style"],
        label = L["Control hover color mode"],
        desc = L["What colors a header control while the pointer is over it."],
    },
    {
        path = "window.frame.controlColor", type = "color",
        default = { r = 1, g = 1, b = 1, a = 1 },
        page = "header", group = L["Button style"],
        label = L["Control color"], desc = L["Color the header controls are drawn in."],
    },
    {
        path = "window.frame.controlHoverColor", type = "color",
        default = { r = 1, g = 0.82, b = 0, a = 1 },
        page = "header", group = L["Button style"],
        label = L["Control hover color"],
        desc = L["Color the control under the pointer is drawn in."],
    },
    -- THE TWO ENDS OF THE REVEAL, and they were a hardcoded 0.25 and 1 until now.
    -- Both defaults are those two numbers, so a window that never touches either
    -- slider is drawn exactly as it was.
    --
    -- `controlAlpha` IS READ ONLY WHILE THE REVEAL IS ON -- with fading off there
    -- is no faded state to have an opacity -- and it is deliberately NOT disabled
    -- on the panel when it is off, which is the same bargain `bars.customColor`
    -- gets under a non-custom colour mode: setting the faded level before
    -- switching fading on is the normal order of operations, and a greyed-out
    -- slider makes that a two-visit job. See modules/HeaderControls.lua's
    -- stripAlphas.
    {
        path = "window.frame.controlAlpha", type = "number", default = 0.25,
        min = 0, max = 1, step = 0.01, isPercent = true,
        page = "header", group = L["Button style"],
        label = L["Control opacity"],
        desc = L["How faint a control NOT under the pointer is drawn, while Reveal controls on hover is on. With the reveal off there is nothing faded and this is not read."],
        validate = isNumberIn(0, 1),
    },
    {
        path = "window.frame.controlHoverAlpha", type = "number", default = 1.0,
        min = 0, max = 1, step = 0.01, isPercent = true,
        page = "header", group = L["Button style"],
        label = L["Control hover opacity"],
        desc = L["How opaque the control under the pointer is drawn. With Reveal controls on hover off, every control sits at this."],
        validate = isNumberIn(0, 1),
    },

    -- ── Bars ────────────────────────────────────────────────────
    -- `class` is the default because classFilename is NeverSecret: a class-colored
    -- bar is still correct at the height of a pull, when every number on the row is
    -- an opaque handle.
    --
    -- SIX TABS: the bar's own fill (Bar), what sits behind it (Background), its
    -- edge (Border), what the cell says (Text content, then Text style), and the
    -- row icon (Icons). "Background" and "Border" say bar without spelling it --
    -- every tab on this page is about the bar, so the word carried nothing. Row
    -- layout and row behaviour moved to the Frame page -- they shape the grid
    -- every bar here is drawn in, not the bar itself.
    {
        path = "window.bars.texture", type = "string", default = "Blizzard Raid Bar",
        values = lsmValues("statusbar"), dialogControl = "LSM30_Statusbar",
        page = "bars", group = L["Bar"],
        label = L["Bar texture"], desc = L["LibSharedMedia statusbar texture used for every cell's bar."],
    },
    {
        path = "window.bars.fillDirection", type = "string", default = "LEFT",
        values = SIDE_VALUES, sorting = SIDE_SORT,
        page = "bars", group = L["Bar"],
        label = L["Fill direction"], desc = L["Which edge of the cell each bar grows from."],
    },
    {
        path = "window.bars.colorMode", type = "string", default = "class",
        values = BARCOLOR_VALUES, sorting = BARCOLOR_SORT,
        page = "bars", group = L["Bar"],
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
        page = "bars", group = L["Bar"],
        label = L["Bar color"], desc = L["Fill color used when the color mode is set to Custom color."],
    },
    {
        path = "window.bars.alpha", type = "number", default = 1.0,
        min = 0, max = 1, step = 0.01, isPercent = true,
        page = "bars", group = L["Bar"],
        label = L["Bar opacity"], desc = L["Opacity of the filled part of each bar."],
        validate = isNumberIn(0, 1),
    },
    -- ── Background ──────────────────────────────────────────────────
    {
        path = "window.bars.bgColorMode", type = "string", default = "class",
        values = BARBG_VALUES, sorting = BARBG_SORT,
        page = "bars", group = L["Background"],
        label = L["Bar background color mode"],
        desc = L["What colors the tint behind each bar. Class is the default and keeps working mid-fight, because a class is never hidden the way a number is."],
    },
    {
        path = "window.bars.bgColor", type = "color",
        default = { r = 0, g = 0, b = 0, a = 1 },
        page = "bars", group = L["Background"],
        label = L["Bar background color"], desc = L["Color drawn behind the unfilled part of each bar."],
    },
    {
        path = "window.bars.bgAlpha", type = "number", default = 0.1,
        min = 0, max = 1, step = 0.01, isPercent = true,
        page = "bars", group = L["Background"],
        label = L["Bar background opacity"], desc = L["Opacity of the unfilled part of each bar."],
        validate = isNumberIn(0, 1),
    },
    -- ── Border ────────────────────────────────────────────────────
    {
        path = "window.bars.border", type = "bool", default = false,
        page = "bars", group = L["Border"],
        label = L["Bar border"], desc = L["Draw an outline around each bar."],
    },
    -- "None" IS A CHOICE, NOT A MISSING VALUE, and modules/Row.lua's
    -- borderEdge treats it as one -- it is what keeps the cheap four-texture
    -- outline as the default and puts a backdrop on a cell only for a player
    -- who has actually asked for edge art.
    {
        -- "None" IS A CHOICE, NOT A MISSING VALUE, and modules/Row.lua's
        -- borderEdge treats it as one -- it is what keeps the cheap four-texture
        -- outline as the default and puts a backdrop on a cell only for a player
        -- who has actually asked for edge art.
        path = "window.bars.borderStyle", type = "string", default = "None",
        values = lsmValues("border"), dialogControl = "LSM30_Border",
        page = "bars", group = L["Border"],
        label = L["Border style"],
        desc = L["Edge art drawn around each bar. None is a flat outline in the color below, which is what this setting has always drawn."],
    },
    {
        path = "window.bars.borderThickness", type = "number", default = 1,
        min = 1, max = 8, step = 1, fmt = "%d px",
        page = "bars", group = L["Border"],
        label = L["Border thickness"],
        desc = L["How thick the outline around each bar is, in pixels."],
        validate = isNumberIn(1, 8),
    },
    {
        path = "window.bars.borderColor", type = "color",
        default = { r = 0, g = 0, b = 0, a = 1 },
        page = "bars", group = L["Border"],
        label = L["Border color"],
        desc = L["Color of the outline around each bar. It used to be the skin's own edge color, which no setting could reach."],
    },
    -- ── Text content ──────────────────────────────────────────────
    -- Two slots per cell. Nothing here divides anything: `numberFormat` picks WHICH
    -- NumericRuleFormatter instance modules/Format.lua hands the value to, and the
    -- formatter does the division natively -- the only legal way to render "12.4M"
    -- from a secret (design section 4).
    --
    -- WHAT the cell says, split from HOW it is drawn below: content here, style
    -- in the next tab.
    {
        path = "window.text.leftSlot", type = "string", default = "smart",
        values = SLOT_VALUES, sorting = SLOT_SORT,
        page = "bars", group = L["Text content"],
        label = L["Left text"], desc = L["What to show on the left of each cell. The two smart values both follow the column: one shows the per-second figure where there is one and the absolute figure everywhere else, the other shows both side by side and falls back to the absolute alone. None means none: the cell is left empty."],
    },
    {
        path = "window.text.rightSlot", type = "string", default = "none",
        values = SLOT_VALUES, sorting = SLOT_SORT,
        page = "bars", group = L["Text content"],
        label = L["Right text"],
        desc = L["What to show on the right of each cell, beside the left figure. Per-second figures exist only for Damage and Healing; a column without one renders nothing rather than substituting its total."],
    },
    {
        path = "window.text.numberFormat", type = "string", default = "abbreviated",
        values = NUMFMT_VALUES, sorting = NUMFMT_SORT,
        page = "bars", group = L["Text content"],
        label = L["Number format"],
        desc = L["How large numbers are written. The three abbreviated forms differ only in how many decimal places they keep; Full writes every digit. There is no thousands-separated form -- separating digits means reading them, and a meter value cannot be read while a pull is running."],
    },
    {
        path = "window.text.deathTimeFormat", type = "string", default = "clock",
        values = DEATHTIME_VALUES, sorting = DEATHTIME_SORT,
        page = "bars", group = L["Text content"],
        label = L["Death timestamps"],
        desc = L["How a death is labelled in the Deaths tooltip and the death list."],
    },
    {
        -- 15 rather than WoW's 12-character player-name limit: a group meter also
        -- shows NPC names — follower-dungeon companions, and the enemy rows the
        -- damage-taken columns are made of — and those are not bound by it. It
        -- shipped at 20, which is wider than any name in a full group of players
        -- and spent that width on the columns beside it.
        -- 0 is the explicit off switch.
        path = "window.text.maxNameLength", type = "number", default = 15,
        min = 0, max = 40, step = 1, fmt = "%d",
        page = "bars", group = L["Text content"],
        label = L["Max name length"],
        desc = L["Truncate a name past this many characters. 0 shows the whole name. The realm is always stripped."],
    },
    -- ── Text style ──────────────────────────────────────────────
    {
        path = "window.text.font", type = "string", default = "Friz Quadrata TT",
        values = lsmValues("font"), dialogControl = "LSM30_Font",
        page = "bars", group = L["Text style"],
        label = L["Font"],
        desc = L["Font used for every number in the grid. A monospace font such as JetBrains Mono keeps columns from shifting as the numbers change; the default matches the window header."],
    },
    {
        path = "window.text.size", type = "number", default = 11,
        min = 6, max = 32, step = 1, fmt = "%d px",
        page = "bars", group = L["Text style"],
        label = L["Font size"], desc = L["Text size in pixels."],
    },
    {
        path = "window.text.colorMode", type = "string", default = "custom",
        values = TEXTCOLOR_VALUES, sorting = TEXTCOLOR_SORT,
        page = "bars", group = L["Text style"],
        label = L["Text color mode"],
        desc = L["What colors the numbers and names. Class is the class of the row being drawn; Per-statistic is the color of the column each cell sits in."],
    },
    {
        path = "window.text.color", type = "color",
        default = { r = 1, g = 1, b = 1, a = 1 },
        page = "bars", group = L["Text style"],
        label = L["Text color"], desc = L["Color of the numbers and names."],
    },
    {
        path = "window.text.outline", type = "string", default = "NONE",
        values = OUTLINE_VALUES, sorting = OUTLINE_SORT,
        page = "bars", group = L["Text style"],
        label = L["Font outline"], desc = L["Outline and monochrome flags applied to the text."],
    },
    {
        path = "window.text.shadow", type = "bool", default = true,
        page = "bars", group = L["Text style"],
        label = L["Text shadow"],
        desc = L["Draw a drop shadow behind the text so it stays readable over a bright bar."],
    },
    {
        path = "window.text.alpha", type = "number", default = 1.0,
        min = 0, max = 1, step = 0.01, isPercent = true,
        page = "bars", group = L["Text style"],
        label = L["Text opacity"], desc = L["Opacity of the numbers and names."],
        validate = isNumberIn(0, 1),
    },
    -- ── Icons ────────────────────────────────────────────────────
    -- classFilename and specIconID are NeverSecret, so these render correctly even
    -- mid-pull when every number beside them is opaque.
    {
        path = "window.icons.showIcon", type = "bool", default = true,
        page = "bars", group = L["Icons"],
        label = L["Show icon"],
        desc = L["Show one icon beside each player's name: their specialization where it is known, and their class where it is not."],
    },
    {
        path = "window.icons.position", type = "string", default = "LEFT",
        values = SIDE_VALUES, sorting = SIDE_SORT,
        page = "bars", group = L["Icons"],
        label = L["Icon position"], desc = L["Which side of the player's name the icons sit on."],
    },
    {
        path = "window.icons.size", type = "number", default = 14,
        min = 8, max = 32, step = 1, fmt = "%d px",
        page = "bars", group = L["Icons"],
        label = L["Icon size"], desc = L["Size of the row icons in pixels."],
    },

    -- ── Tooltip ────────────────────────────────────────────────────
    -- SIX TABS: where it goes and how big it is (General), the spell bar's own
    -- fill, background and border, the face it is drawn in (Text), and last what
    -- it lists (Contents). The two tabs a player sets once and leaves are at the
    -- END -- the three bar tabs are the ones they come back to, and they now sit
    -- together in the middle rather than with a text tab wedged in front of them.
    -- No "At cursor" anchor: over a grid it lands wherever the pointer
    -- happens to be inside a cell, so the same hover puts the tooltip somewhere
    -- different every time. TOP is the deliberate version of the same thing --
    -- above the cell, in one place -- and is the default now.
    {
        path = "window.tooltip.anchor", type = "string", default = "TOP",
        values = ANCHOR_VALUES, sorting = ANCHOR_SORT,
        page = "tooltip", group = L["General"],
        label = L["Tooltip anchor"], desc = L["Where the tooltip appears relative to the cursor or the window."],
    },
    {
        -- The tooltip's own, not the window's: a player who wants a bigger grid
        -- and a small tooltip, or the reverse, is asking two questions. Bounded
        -- rather than free -- below 0.5 the text stops being readable and above 2
        -- the tooltip stops fitting beside the window it came from.
        path = "window.tooltip.scale", type = "number", default = 1.0,
        min = 0.5, max = 2.0, step = 0.05, fmt = "%.2fx",
        page = "tooltip", group = L["General"],
        label = L["Tooltip scale"],
        desc = L["How large the tooltip is drawn. It is put back to normal when the tooltip closes, so nothing else in the interface inherits it."],
        validate = isNumberIn(0.5, 2.0),
    },
    {
        path = "window.tooltip.offsetX", type = "number", default = 0,
        min = -400, max = 400, step = 1, fmt = "%d px",
        page = "tooltip", group = L["General"],
        label = L["Horizontal offset"],
        desc = L["Nudge the tooltip sideways from wherever the anchor puts it. Positive moves it right."],
        validate = isNumberIn(-400, 400),
    },
    {
        path = "window.tooltip.offsetY", type = "number", default = 0,
        min = -400, max = 400, step = 1, fmt = "%d px",
        page = "tooltip", group = L["General"],
        label = L["Vertical offset"],
        desc = L["Nudge the tooltip up or down from wherever the anchor puts it. Positive moves it up."],
        validate = isNumberIn(-400, 400),
    },
    -- Off by default. Nothing about a tooltip is unsafe in combat -- its numbers go
    -- through the formatter like every other -- but a tooltip under the cursor
    -- during a pull is in the way, so this is a preference rather than a guard.
    {
        path = "window.tooltip.hideInCombat", type = "bool", default = false,
        page = "tooltip", group = L["General"],
        label = L["Hide tooltips in combat"],
        desc = L["Suppress tooltips while you are in combat so nothing sits under your cursor mid-pull."],
    },
    -- ── Bar ────────────────────────────────────────────────────
    -- Tooltip bars are configured SEPARATELY from the grid's, rather than
    -- inherited from `window.bars`. They are a different surface at a different
    -- size -- a 14px spell line against a 90px cell -- and a texture that reads
    -- well across one often does not across the other. The fill and the backdrop
    -- each answer the same three modes every text surface answers.
    {
        path = "window.tooltip.barTexture", type = "string", default = "Blizzard Raid Bar",
        values = lsmValues("statusbar"), dialogControl = "LSM30_Statusbar",
        page = "tooltip", group = L["Bar"],
        label = L["Bar texture"], desc = L["LibSharedMedia statusbar texture drawn behind each spell line."],
    },
    {
        path = "window.tooltip.barSpacing", type = "number", default = 1,
        min = 0, max = 12, step = 1, fmt = "%d px",
        page = "tooltip", group = L["Bar"],
        label = L["Bar spacing"], desc = L["Gap in pixels between one tooltip line and the next."],
        validate = isNumberIn(0, 12),
    },
    {
        -- THE FILL AND THE BACKDROP EACH ANSWER THE SAME THREE MODES, the same
        -- three every text surface answers. The fill used to be the hovered
        -- player's class and nothing else, with no setting reaching it, and the
        -- backdrop was a hard-coded black at 0.35 that no setting reached either.
        -- The setting ships at 0.1 now: the tooltip's bars sit on the tooltip's
        -- own backdrop, which is already dark, so a third of a screen of black
        -- on top of it read as a smear rather than as an unfilled bar.
        path = "window.tooltip.barColorMode", type = "string", default = "class",
        values = TEXTCOLOR_VALUES, sorting = TEXTCOLOR_SORT,
        page = "tooltip", group = L["Bar"],
        label = L["Bar color mode"],
        desc = L["What colors the filled part of each tooltip bar. Class is the player you are hovering; Per-statistic is the color of the column the grid is sorted by."],
    },
    {
        path = "window.tooltip.barColor", type = "color",
        default = { r = 0.6, g = 0.6, b = 0.6, a = 1 },
        page = "tooltip", group = L["Bar"],
        label = L["Bar color"], desc = L["Color of the filled part, when the mode above is Custom."],
    },
    {
        path = "window.tooltip.barAlpha", type = "number", default = 0.85,
        min = 0, max = 1, step = 0.01, isPercent = true,
        page = "tooltip", group = L["Bar"],
        label = L["Bar opacity"], desc = L["Opacity of the filled part of each tooltip bar."],
        validate = isNumberIn(0, 1),
    },
    -- ── Bar background ──────────────────────────────────────────────
    -- The backdrop used to be a hard-coded black at 0.35 that no setting reached.
    -- It ships at 0.1 now: the tooltip's bars sit on the tooltip's own backdrop,
    -- which is already dark, so a third of a screen of black on top of it read as
    -- a smear rather than as an unfilled bar.
    {
        path = "window.tooltip.barBgColorMode", type = "string", default = "custom",
        values = TEXTCOLOR_VALUES, sorting = TEXTCOLOR_SORT,
        page = "tooltip", group = L["Bar background"],
        label = L["Bar background color mode"],
        desc = L["What colors the unfilled part of each tooltip bar."],
    },
    {
        path = "window.tooltip.barBgColor", type = "color",
        default = { r = 0, g = 0, b = 0, a = 1 },
        page = "tooltip", group = L["Bar background"],
        label = L["Bar background color"],
        desc = L["Color of the unfilled part, when the mode above is Custom."],
    },
    {
        path = "window.tooltip.barBgAlpha", type = "number", default = 0.1,
        min = 0, max = 1, step = 0.01, isPercent = true,
        page = "tooltip", group = L["Bar background"],
        label = L["Bar background opacity"],
        desc = L["Opacity of the unfilled part of each tooltip bar."],
        validate = isNumberIn(0, 1),
    },
    -- ── Bar border ─────────────────────────────────────────────────
    -- Defaults to None, and that is not timidity. Most LibSharedMedia border art
    -- carries an 8-16px corner inset, and a spell bar is 14px tall -- so on a
    -- majority of the list the corners eat the whole edge. The option is here
    -- because it was asked for; the default is the one that always looks right.
    {
        path = "window.tooltip.barBorderStyle", type = "string", default = "None",
        values = lsmValues("border"), dialogControl = "LSM30_Border",
        page = "tooltip", group = L["Bar border"],
        label = L["Bar border style"],
        desc = L["LibSharedMedia border drawn around each spell bar. Most border art is cut for a window rather than a 14px line, so it may look heavy here."],
    },
    {
        path = "window.tooltip.barBorderSize", type = "number", default = 1,
        min = 0, max = 16, step = 1, fmt = "%d px",
        page = "tooltip", group = L["Bar border"],
        label = L["Bar border thickness"], desc = L["Border edge size in pixels."],
        validate = isNumberIn(0, 16),
    },
    {
        path = "window.tooltip.barBorderColor", type = "color",
        default = { r = 0, g = 0, b = 0, a = 1 },
        page = "tooltip", group = L["Bar border"],
        label = L["Bar border color"], desc = L["Color of the border around each spell bar."],
    },
    -- ── Text ────────────────────────────────────────────────────
    -- The font reaches GameTooltip's own line FontStrings, which are SHARED with
    -- every other addon -- so modules/Tooltip.lua restores every line it touched
    -- when the tooltip hides. See that file's `releaseLines`.
    {
        path = "window.tooltip.font", type = "string", default = "Friz Quadrata TT",
        values = lsmValues("font"), dialogControl = "LSM30_Font",
        page = "tooltip", group = L["Text"],
        label = L["Font"], desc = L["Font used for the tooltip's spell names and numbers."],
    },
    {
        path = "window.tooltip.fontSize", type = "number", default = 12,
        min = 6, max = 32, step = 1, fmt = "%d px",
        page = "tooltip", group = L["Text"],
        label = L["Font size"], desc = L["Tooltip text size in pixels."],
        validate = isNumberIn(6, 32),
    },
    {
        path = "window.tooltip.colorMode", type = "string", default = "custom",
        values = TEXTCOLOR_VALUES, sorting = TEXTCOLOR_SORT,
        page = "tooltip", group = L["Text"],
        label = L["Text color mode"],
        desc = L["What colors the tooltip's text. Class is the class of the player you are hovering; Per-statistic is the color of the column the grid is sorted by."],
    },
    {
        path = "window.tooltip.textColor", type = "color",
        default = { r = 1, g = 1, b = 1, a = 1 },
        page = "tooltip", group = L["Text"],
        label = L["Text color"], desc = L["Color of the amount and percentage on each tooltip line."],
    },
    {
        path = "window.tooltip.fontOutline", type = "string", default = "NONE",
        values = OUTLINE_VALUES, sorting = OUTLINE_SORT,
        page = "tooltip", group = L["Text"],
        label = L["Font outline"], desc = L["Outline and monochrome flags applied to the tooltip text."],
    },
    {
        path = "window.tooltip.fontShadow", type = "bool", default = false,
        page = "tooltip", group = L["Text"],
        label = L["Text shadow"],
        desc = L["Draw a drop shadow behind the tooltip text so it stays readable over a bright bar."],
    },
    -- ── Contents ──────────────────────────────────────────────
    {
        path = "window.tooltip.showSpells", type = "bool", default = true,
        page = "tooltip", group = L["Contents"],
        label = L["Show spell breakdown"], desc = L["List the individual spells behind a cell's number when you hover it."],
    },
    -- 0 is the explicit "no cap" value, the same spelling `rows.maxRows` and
    -- `text.maxNameLength` already use. It is honest rather than infinite: the
    -- collector stops at 64 rows however this is set, and the "and N more" line
    -- says so.
    {
        path = "window.tooltip.maxSpells", type = "number", default = 10,
        min = 0, max = 30, step = 1,
        page = "tooltip", group = L["Contents"],
        label = L["Maximum spells"],
        desc = L["How many spells to list in the breakdown before stopping. 0 lists every spell the breakdown found."],
        validate = isNumberIn(0, 30),
    },
    -- OFF by default, and for two reasons that are worth stating separately.
    -- It costs one provider call per enemy on a hover (modules/Targets.lua keeps
    -- built once per session), and it is a SUMMATION -- so it is absent for a pull
    -- rather than approximated. A player who wants it gets it; nobody pays for it
    -- without asking.
    {
        path = "window.tooltip.showTargets", type = "bool", default = false,
        page = "tooltip", group = L["Contents"],
        label = L["Show targets"],
        desc = L["On a Damage cell, list which enemies this player hit. Cross-referenced from the enemy damage taken column, so it is unavailable while a pull is in progress."],
    },
    {
        path = "window.tooltip.maxTargets", type = "number", default = 3,
        min = 1, max = 10, step = 1,
        page = "tooltip", group = L["Contents"],
        label = L["Maximum targets"], desc = L["How many enemies to list before stopping."],
        validate = isNumberIn(1, 10),
    },
    -- WHAT ENDED EACH DEATH, on the death list's own line: "Death 3 | Ragnaros |
    -- Sulfuras Smash". Two switches rather than one, because the two answer
    -- different questions -- who killed me is a positioning question and what
    -- killed me is a cooldown question -- and a player who wants one of them
    -- should not have to take the other with it.
    --
    -- BOTH ON, because the line without them says nothing a reader did not
    -- already know: the count is in the cell they hovered to get here.
    --
    -- Either half goes quiet on its own terms and neither is a failure: an
    -- environmental death has no caster, a melee swing has no spell name, and a
    -- restricted pull can withhold either -- see modules/Tooltip.lua's
    -- killingBlowOf, which draws what it can read plainly and nothing else.
    {
        path = "window.tooltip.showDeathCaster", type = "bool", default = true,
        page = "tooltip", group = L["Contents"],
        label = L["Name the killer"],
        desc = L["Add whoever landed the killing blow to each line of the Deaths list. Left off a death with no caster to name, such as a fall or a fire."],
    },
    {
        path = "window.tooltip.showDeathSpell", type = "bool", default = true,
        page = "tooltip", group = L["Contents"],
        label = L["Name the killing blow"],
        desc = L["Add the spell that landed the killing blow to each line of the Deaths list. A melee swing is named Melee; a spell the client cannot name is left off."],
    },
    {
        path = "window.tooltip.showAllStatsOnName", type = "bool", default = true,
        page = "tooltip", group = L["Contents"],
        label = L["Summarize on the name"],
        desc = L["Hovering a player's name shows every enabled statistic for that player at once."],
    },

    -- ── Visibility ─────────────────────────────────────────────────
    -- Refused AT THE SOURCE (performance section 6): a hidden window does not
    -- merely skip its draw, it stops asking the provider for data. That is why
    -- every row here carries an onChange -- the effect is a window appearing or
    -- disappearing, which is the show ladder's decision and not a redraw.
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
        path = "window.visibility.delve", type = "bool", default = true,
        page = "visibility", group = L["Where to show this window"],
        label = L["Delves"], desc = L["Show this window inside delves."],
        onChange = refreshVisibility,
    },
    {
        path = "window.visibility.scenario", type = "bool", default = true,
        page = "visibility", group = L["Where to show this window"],
        label = L["Scenarios"],
        desc = L["Show this window in scenarios and follower dungeons. Delves have their own setting."],
        onChange = refreshVisibility,
    },
    {
        path = "window.visibility.world", type = "bool", default = true,
        page = "visibility", group = L["Where to show this window"],
        label = L["Open world"], desc = L["Show this window outside instances."],
        onChange = refreshVisibility,
    },
    -- Every rule below is HIDE-shaped, and deliberately so: a key missing from a
    -- stored window must read as "nothing objects". See modules/Visibility.lua.
    {
        path = "window.visibility.hideWhenSolo", type = "bool", default = false,
        page = "visibility", group = L["When to hide this window"],
        label = L["Hide when solo"], desc = L["Hide the window whenever you are not in a party or raid."],
        onChange = refreshVisibility,
    },
    {
        path = "window.visibility.hideInVehicle", type = "bool", default = false,
        page = "visibility", group = L["When to hide this window"],
        label = L["Hide in vehicles"], desc = L["Hide the window while you are controlling a vehicle."],
        onChange = refreshVisibility,
    },
    {
        path = "window.visibility.hideWhenMounted", type = "bool", default = false,
        page = "visibility", group = L["When to hide this window"],
        label = L["Hide when mounted"],
        desc = L["Hide the window while you are mounted, including a druid's travel forms."],
        onChange = refreshVisibility,
    },
    {
        path = "window.visibility.hideWhenSkyriding", type = "bool", default = false,
        page = "visibility", group = L["When to hide this window"],
        label = L["Hide when skyriding"],
        desc = L["Hide the window while you are on a skyriding mount, from the moment it can glide rather than once you are airborne."],
        onChange = refreshVisibility,
    },
    {
        path = "window.visibility.hideOnTaxi", type = "bool", default = false,
        page = "visibility", group = L["When to hide this window"],
        label = L["Hide on flight paths"], desc = L["Hide the window while you are riding a flight path."],
        onChange = refreshVisibility,
    },
    {
        path = "window.visibility.hideInHousing", type = "bool", default = false,
        page = "visibility", group = L["When to hide this window"],
        label = L["Hide in player housing"],
        desc = L["Hide the window while you are inside your house or on your plot."],
        onChange = refreshVisibility,
    },
    {
        path = "window.visibility.hideInPetBattle", type = "bool", default = false,
        page = "visibility", group = L["When to hide this window"],
        label = L["Hide in pet battles"], desc = L["Hide the window while a pet battle is on screen."],
        onChange = refreshVisibility,
    },
    {
        path = "window.visibility.hideWhenDead", type = "bool", default = false,
        page = "visibility", group = L["When to hide this window"],
        label = L["Hide while dead"],
        desc = L["Hide the window while you are dead or a ghost. Off by default: reading the meter while dead is most of what it is for."],
        onChange = refreshVisibility,
    },
    -- Two independent rules rather than one tri-state control. Ticking both is a
    -- window that never shows, which is the player's business; `/mm debug diag` still
    -- names the side of the pull that decided.
    {
        path = "window.visibility.hideInCombat", type = "bool", default = false,
        page = "visibility", group = L["Combat"],
        label = L["Hide in combat"], desc = L["Hide the window while you are fighting."],
        onChange = refreshVisibility,
    },
    {
        path = "window.visibility.hideOutOfCombat", type = "bool", default = false,
        page = "visibility", group = L["Combat"],
        label = L["Hide out of combat"], desc = L["Hide the window whenever you are not fighting."],
        onChange = refreshVisibility,
    },

    -- ── Columns ──────────────────────────────────────────────
    -- The array itself has NO ROWS. See "WHY THE COLUMNS ARE NOT ROWS" at the top
    -- of this file; the page exists in the panel and in `/mm list`, and its
    -- contents are the array, drawn by a bespoke block picker rather than by any
    -- row below.
    --
    -- The column-header STRIP that labels those columns is styled here, though,
    -- and used to sit on the Header page as a third group beside the title
    -- strip -- three clicks from the page where the columns it labels are chosen.
    -- It used to borrow the font and size from `text` and the outline and colour
    -- from `header`, which meant changing the cell font silently restyled it too;
    -- every default here is the value that arrangement already produced. The
    -- PATHS stay `window.columnHeader.*` -- a row's page is where it is edited,
    -- its path is where it is stored.
    {
        path = "window.columnHeader.font", type = "string", default = "Friz Quadrata TT",
        values = lsmValues("font"), dialogControl = "LSM30_Font",
        page = "columns", group = L["Header text"],
        label = L["Font"], desc = L["Font used for the column header strip above the rows."],
    },
    {
        path = "window.columnHeader.size", type = "number", default = 11,
        min = 6, max = 32, step = 1, fmt = "%d px",
        page = "columns", group = L["Header text"],
        label = L["Font size"], desc = L["Column header text size in pixels."],
        validate = isNumberIn(6, 32),
    },
    {
        path = "window.columnHeader.colorMode", type = "string", default = "custom",
        values = TEXTCOLOR_VALUES, sorting = TEXTCOLOR_SORT,
        page = "columns", group = L["Header text"],
        label = L["Text color mode"],
        desc = L["What colors the column labels. Per-statistic gives each label its own column's color, which is the one surface where that is literally per column."],
    },
    {
        path = "window.columnHeader.color", type = "color",
        default = { r = 1, g = 0.82, b = 0, a = 1 },
        page = "columns", group = L["Header text"],
        label = L["Text color"], desc = L["Color of the column header labels."],
    },
    {
        path = "window.columnHeader.outline", type = "string", default = "OUTLINE",
        values = OUTLINE_VALUES, sorting = OUTLINE_SORT,
        page = "columns", group = L["Header text"],
        label = L["Font outline"], desc = L["Outline and monochrome flags applied to the column headers."],
    },
    {
        path = "window.columnHeader.shadow", type = "bool", default = false,
        page = "columns", group = L["Header text"],
        label = L["Text shadow"],
        desc = L["Draw a drop shadow behind the column labels so they stay readable over a bright backdrop."],
    },
    -- NO `bgColorMode` on the title bar's own background, but this strip keeps
    -- one: it labels the COLUMNS, so "per statistic" tints each label with its
    -- own column's colour and means something, where the same mode on the title
    -- bar -- one strip over the whole window -- could only ever mean the sort
    -- column's colour.
    {
        path = "window.columnHeader.bgColorMode", type = "string", default = "custom",
        values = TEXTCOLOR_VALUES, sorting = TEXTCOLOR_SORT,
        page = "columns", group = L["Header background"],
        label = L["Background color mode"],
        desc = L["What colors the strip behind the column labels. Per-statistic tints each label's own cell with that column's color, which is the one surface where that is literally per column."],
    },
    {
        path = "window.columnHeader.bgColor", type = "color",
        default = { r = 0, g = 0, b = 0, a = 0 },
        page = "columns", group = L["Header background"],
        label = L["Background color"],
        desc = L["Color drawn behind the column header strip. Transparent by default \226\128\148 the strip has never had a backdrop."],
    },

    -- ── General ──────────────────────────────────────────────
    -- The only genuinely addon-wide settings. Everything else is per-window.
    --
    -- ONE VISIBLE TAB: the master switch, the two addon-wide data settings, the
    -- two session-only toggles, and the page's two bespoke reset buttons, all on
    -- General.
    --
    -- TWO TABS BECAME NONE, ONE AT A TIME. "Maintenance" was one visible row --
    -- the debug console -- carrying a tab of its own next to the two reset
    -- buttons keyed to it: a click to reach three controls that were never a
    -- subject. "Data" was two rows, and the same argument retired it. Neither
    -- move changed what any of those controls DOES; the buttons hang off
    -- General's afterGroup hook (settings/General.lua) rather than
    -- Maintenance's, and that is the whole of it.
    --
    -- The three hidden export choices stay last so the tabs above them stay
    -- CONTIGUOUS: a group heading is emitted only when `group` CHANGES, so a
    -- block wedged between two "General" rows would print that heading twice.
    {
        path = "enabled", type = "bool", default = true,
        page = "general", group = L["General"],
        label = L["Enable Multi Meters"],
        desc = L["Master switch for the addon. When off, no window is drawn and no data is read."],
        onChange = refreshVisibility,
    },
    -- The one inverted row: LibDBIcon owns this table and its key is `hide`, while
    -- a checkbox the user reads has to be phrased positively. See "Inversion".
    {
        path = "minimap.hide", type = "bool", default = false, invert = true,
        page = "general", group = L["General"],
        label = L["Show minimap button"], desc = L["Show the minimap button for opening these settings."],
        onChange = refreshMinimap,
    },
    -- `data.mergePets` and `data.throttle` were `window.data.*` and are not
    -- per-window questions: one says what a pet's damage IS, the other is a
    -- refresh rate, and two windows disagreeing about either is two answers to
    -- one question. core/Database.lua's v4 -> v5 step lifts a stored pair off the
    -- first window in each profile. There is no Data PAGE any more -- the sort
    -- and session rows that used to share it with these two were deleted rather
    -- than moved, because the window's own controls already write them directly
    -- (modules/Window.lua's SortByColumn and the header's segment picker), and a
    -- settings page restating a control the player already has, three inches
    -- from where they are looking, was a second place for the same answer to
    -- live.
    {
        path = "data.mergePets", type = "bool", default = false,
        page = "general", group = L["General"],
        label = L["Merge pets into their owner"],
        desc = L["Add a pet's numbers to its owner's row instead of giving it its own. Blizzard's combat restriction forbids the addition while you are fighting, so a merged pet's numbers are missing until the pull ends."],
    },
    {
        path = "data.throttle", type = "number", default = 0.25,
        min = Const.THROTTLE_MIN, max = Const.THROTTLE_MAX, step = 0.05, fmt = "%.2fs",
        page = "general", group = L["General"],
        label = L["Refresh interval"],
        desc = L["Seconds between refreshes. Lower is more responsive and costs more; the display updates at most this often no matter how fast the game reports numbers."],
        validate = isNumberIn(Const.THROTTLE_MIN, Const.THROTTLE_MAX),
    },
    -- ── Session-only rows ──
    --
    -- Never persisted, so they have no home in the defaults tree and are exempt
    -- from ValidateSchema's resolution check. They are rows anyway because they
    -- belong on the page and in `/mm list` beside the settings they sit next to --
    -- a toggle that exists only in the panel is a toggle the CLI cannot reach.
    {
        path = "state.testMode", type = "bool", default = false, sessionOnly = true,
        page = "general", group = L["General"],
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
    -- (debug-logging section 5).
    {
        path = "state.debugConsole", type = "bool", default = false, sessionOnly = true,
        page = "general", group = L["General"],
        label = L["Debug console"],
        desc = L["Show or hide the on-screen debug console. Session only; it does not turn debug logging on."],
        get = function() return NS.DebugLog ~= nil and NS.DebugLog:IsShown() end,
        set = function(v)
            local D = NS.DebugLog
            if not D then return end
            if v then D:Show() else D:Hide() end
        end,
    },

    -- ── Export ──────────────────────────────────────────────
    --
    -- Addon-wide rather than per-window, and last on the page so the tabs above
    -- stay contiguous. ALL THREE ARE `hidden`. They are the choices the EXPORT
    -- MODAL remembers -- its own three controls are the ones a player uses,
    -- sitting in the dialog they are exporting from -- so a second copy on the
    -- General page restated a control the player only ever meets in the other
    -- place, and gave the two a chance to disagree about what is selected.
    --
    -- HIDDEN RATHER THAN DELETED, unlike the sort and session rows that went with
    -- the old Data page, and the difference is which seam does the writing.
    -- Those were written directly by the window's own controls; these are
    -- written by the modal through NS.SetByPath -- which REFUSES a path with no
    -- row. Deleting them would drop every export choice onto writeExport's
    -- degraded fallback, losing the validation, the debug line and
    -- CONFIG_CHANGED, and would take `/mm set export.channel WHISPER` with it.
    --
    -- THE METRIC IS NOT AMONG THEM, and its absence is deliberate. It used to be,
    -- with a "Match the window" entry the sort column had no use for. Export.Open
    -- now seeds the metric from the window it was opened from, so a value set
    -- here would be overwritten before it was ever read.
    {
        path = "export.channel", type = "string", default = "SELF", hidden = true,
        values = CHANNEL_VALUES, sorting = CHANNEL_SORT,
        page = "general", group = L["Export"],
        label = L["Default channel"],
        desc = L["Where 'Print to Chat' sends its lines. Self only prints to your own chat frame and sends nothing to the group, which is why it is the default: a misclick cannot reach a raid."],
    },
    {
        -- No non-empty check, unlike the window-name row this otherwise copies:
        -- the empty string is this row's shipped default and a legal value, and
        -- it is what every channel but Whisper means. The validator is here to
        -- refuse a table typed in from a hand-edited SavedVariables, nothing
        -- more; whether the name resolves to a character is the server's answer
        -- to give, not this seam's.
        path = "export.whisperTo", type = "string", default = "", hidden = true,
        dialogControl = "EditBox", maxLetters = 48,
        page = "general", group = L["Export"],
        label = L["Whisper recipient"],
        desc = L["Who to whisper when the channel is Whisper. Cross-realm names need the realm, as Name-Realm."],
        validate = function(v) return type(v) == "string" end,
    },
    {
        -- Ceiling shared with the row cap rather than restated: the aggregator
        -- clamps an export to MAX_ROWS anyway, so a slider that offered 60 would
        -- be offering a number the send could not honor.
        path = "export.lines", type = "number", default = 5, hidden = true,
        min = 1, max = Const.MAX_ROWS, step = 1, fmt = "%d",
        page = "general", group = L["Export"],
        label = L["Chat lines"],
        -- The one desc carrying a number: stating the ceiling as a literal here
        -- would be a second copy of Const.MAX_ROWS in a sentence nobody would
        -- think to update.
        desc = L["How many ranked lines 'Print to Chat' sends, after the header line. The meter never holds more than %d rows, so that is the ceiling."]:format(Const.MAX_ROWS),
        validate = isNumberIn(1, Const.MAX_ROWS),
    },

    -- ── Profiles ──────────────────────────────────────────────
    -- No rows, and that is enforced twice: AceDBOptions supplies the controls, and
    -- `page == "profiles"` is the reset-all veto in settings/OptionsSetup.lua,
    -- because resetting a profile row deletes user data rather than restoring a
    -- default (options-ui section 3).
}

-- ---------------------------------------------------------------------------
-- The statistic palette (General -> Statistic colors)
-- ---------------------------------------------------------------------------
--
-- THE ONE GENERATED BLOCK IN THIS FILE, and the reason is that the rows are not
-- a design decision -- they are one swatch per entry of core/Constants.lua's
-- palette, and writing them out by hand would be a second copy of that table
-- that goes stale the day a statistic is added. The catalog decides what exists;
-- this decides how it is edited.
--
-- IN CATALOG ORDER, not `pairs` order, so the tab reads in the same left-to-right
-- order as a window's columns and two players comparing screenshots see the same
-- list. A stat with no palette entry gets no row rather than a black swatch --
-- see the note in defaults/Profile.lua's statColorDefaults.
--
-- ADDON-WIDE (`statColors.*`, no `window.` prefix) for the reason that file
-- states: the palette's job is telling one column from another at a glance, and
-- per-window would let two windows disagree about what green means.
--
-- Appended AFTER the literal above rather than woven into it, which puts the
-- group after the hidden Export block. That is fine and deliberate: Export draws
-- no tab, so the general page's visible strip is General then Statistic colors,
-- and each group is still CONTIGUOUS, which is the property the heading logic
-- actually needs.
for _, stat in ipairs(Const.STATS) do
    local c = Const.STAT_COLORS[stat.key]
    if c then
        NS.Schema[#NS.Schema + 1] = {
            path = "statColors." .. stat.key, type = "color",
            default = { r = c[1], g = c[2], b = c[3], a = 1 },
            page = "general", group = L["Statistic colors"],
            label = L[stat.label],
            desc = L["Color for this statistic wherever it identifies a column: bars set to Per-statistic, the column header, and the tooltip's all-statistics list."],
        }
    end
end

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

--- Repair a candidate column array into the catalog, in the caller's order.
---
--- REPAIRING RATHER THAN REJECTING, and that is the change. The array used to be
--- a SUBSET the player assembled, so an entry naming a statistic this build does
--- not have was a real editing problem and was surfaced as one: stored, listed on
--- the page, and removable. There is nothing to surface now. The array IS the
--- catalog, there is no remove button, and a row for a statistic that does not
--- exist is a row nobody can act on. So an unknown statistic is DROPPED and one
--- this build gained is APPENDED disabled, and a profile carried back from a
--- newer build heals itself instead of growing a dead row.
---
--- ENABLED-FIRST IS ENFORCED HERE, WHICH IS WHY THE PAGE DOES NOT HAVE TO. The
--- Columns page sinks a disabled block below its rule, but `/mm set
--- window.columns ...` and a hand-edited SavedVariables reach this seam without
--- ever drawing a block. Partitioning here is what makes those three routes
--- agree, and the two-list build below is a STABLE partition: relative order
--- inside each group is exactly the caller's.
---
--- Rebuilding rather than accepting the caller's table also means the stored
--- array can never share a sub-table with whoever handed it over (the classic
--- profile-aliasing bug), and any extra key someone smuggled in is dropped
--- rather than persisted into a profile the renderer will not read.
---
--- @param value any
--- @return table|nil columns, string|nil err
local function normalizeColumns(value)
    if type(value) ~= "table" then
        return nil, L["Columns must be a list of columns, not %s."]:format(type(value))
    end

    local n = #value

    -- A hole or a string key would make `#value` an arbitrary answer, so the array
    -- shape is proved rather than assumed before anything is read out of it.
    local keys = 0
    for _ in pairs(value) do keys = keys + 1 end
    if keys ~= n then
        return nil, L["Columns must be a plain ordered list with no gaps."]
    end

    local enabled, disabled, seen = {}, {}, {}
    for i = 1, n do
        local c = value[i]
        if type(c) ~= "table" then
            return nil, L["Column %d is not a column."]:format(i)
        end

        -- An unknown statistic and a repeat are both dropped, silently and on
        -- purpose. THE FIRST APPEARANCE WINS: a later duplicate carrying a
        -- different `enabled` cannot quietly overrule the position the caller
        -- already gave it.
        local stat = c.stat
        if type(stat) == "string" and Const.STAT_BY_KEY[stat] and not seen[stat] then
            seen[stat] = true
            local entry = { stat = stat, enabled = c.enabled and true or false }
            local into  = entry.enabled and enabled or disabled
            into[#into + 1] = entry
        end
    end

    -- Every catalog statistic the caller did not mention, appended disabled in
    -- catalog order -- which is what makes a statistic added to core/Constants.lua
    -- appear on every existing profile's page with no migration of its own.
    for _, stat in ipairs(Const.STATS) do
        if not seen[stat.key] then
            disabled[#disabled + 1] = { stat = stat.key, enabled = false }
        end
    end

    -- A window with nothing but names in it reads as a broken addon rather than as
    -- a configuration. This is the one thing the repair cannot invent an answer
    -- for: which column did they mean to keep?
    if #enabled == 0 then
        return nil, L["A window must keep at least one column."]
    end

    local out = {}
    for _, entry in ipairs(enabled)  do out[#out + 1] = entry end
    for _, entry in ipairs(disabled) do out[#out + 1] = entry end
    return out
end

--- Published because core/Database.lua's migration ladder needs this same rule and
--- cannot reach a local in a file that loads eighteen TOC entries after it. Read
--- at MIGRATION time rather than at load time, which is the pattern `migrations[1]`
--- already uses for `NS.WINDOW_TEMPLATE`: the ladder runs on Init, long after
--- every file is in memory. A second implementation of "what shape is a column
--- array" is how the migration and the write seam end up disagreeing about it.
NS.NormalizeColumns = normalizeColumns

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

    -- HOW MANY ARE SHOWN, not how many there are. Every array is the catalog now,
    -- so `#cols` is the same number on every write, and a log line that never
    -- changes is a log line nobody can read a change out of. Two format arguments
    -- because that is what announceWrite forwards -- a third would be dropped and
    -- its `%d` would reach the console literally.
    local shown = 0
    for _, c in ipairs(cols) do
        if c.enabled then shown = shown + 1 end
    end
    announceWrite("columns", id, "%s = %d shown", COLUMNS_PREFIX, shown)
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
    -- A RESTORE IS NOT A CLICK, and one row cares: the Frame page's meta colour
    -- mode broadcasts to ten rows on three other pages when it is SET, which is
    -- the point of it -- and must not when the page's own Defaults button walks
    -- it, or that button silently resets settings on pages it has no business
    -- reaching. Set around the write rather than passed as an argument, because
    -- every other row and every other seam is indifferent to the difference.
    local was = NS.__restoring
    NS.__restoring = true
    -- toDisplay, because SetByPath expects display terms and will invert back. The
    -- round trip is what keeps `default` meaning "the stored value" for the
    -- validator while the seam still sees what a user would have clicked.
    NS.SetByPath(row.path, toDisplay(row, copy(row.default)))
    NS.__restoring = was
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
        -- `hidden` rows are skipped HERE and nowhere else, so they stay writable
        -- through NS.SetByPath, listable through `/mm list` and comparable by the
        -- schema-vs-defaults validator, and only ever miss the panel. A row is
        -- hidden when it is per-window STATE that something else in the UI already
        -- writes -- `frame.minimised` is the one -- rather than a preference.
        if row.page == pageKey and not row.hidden then rows[#rows + 1] = row end
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
--
-- `NS.ResetPositions` USED TO LIVE HERE and no longer does. It existed because
-- positions are not schema rows, so NS.ApplyDefault could not reach them, and the
-- options descriptor's `afterRestoreAll` called it to finish a global reset. That
-- reset is a PROFILE reset now (settings/OptionsSetup.lua): positions live in the
-- profile, so they come back with everything else and the seam had no caller
-- left. `/mm reset-positions` has always gone straight to
-- modules/WindowManager.lua, which owns re-anchoring a live frame.

