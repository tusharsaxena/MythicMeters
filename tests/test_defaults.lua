-- tests/test_defaults.lua — defaults/Profile.lua, the only place a profile
-- default is hardcoded (savedvariables-§2).
--
-- The file is a data literal plus one factory, and the factory is where the bug
-- lives: NS.DefaultWindow must DEEP-COPY the template. Handing the template out
-- directly — or copying only its top level — makes every window share one
-- `frame` table, and editing window 2's backdrop silently edits window 1's. That
-- is the classic profile-aliasing bug, it is invisible until a user creates a
-- second window, and it survives a /reload because SavedVariables serializes the
-- alias as two identical copies that then diverge on the next edit.
--
-- The other property worth pinning is that the COLUMNS are derived from the stat
-- catalog rather than written out here. Adding a stat with defaultEnabled = true
-- has to put it in every new window with no edit to this file, and the order has
-- to be the catalog's — which is the left-to-right layout the design fixes.

local T = _G.MYTHICMETERS_TEST
local NS = T.NS
local test, assertEqual, assertTrue, assertFalse, assertNil =
    T.test, T.assertEqual, T.assertTrue, T.assertFalse, T.assertNil

local Const = NS.Constants
local TPL   = NS.WINDOW_TEMPLATE

--- Walk two tables in parallel, reporting every sub-table they SHARE by identity.
local function sharedTables(a, b, path, found)
    path, found = path or "window", found or {}
    if type(a) ~= "table" or type(b) ~= "table" then return found end
    if a == b then
        found[#found + 1] = path
        return found
    end
    for key, value in pairs(a) do
        if type(value) == "table" then
            sharedTables(value, b[key], path .. "." .. tostring(key), found)
        end
    end
    return found
end

-- ── the factory ─────────────────────────────────────────────────────────────

test("Defaults: DefaultWindow stamps the id and the name it is given", function()
    local w = NS.DefaultWindow(7, "Raid")
    assertEqual(w.id, 7)
    assertEqual(w.name, "Raid")
end)

test("Defaults: DefaultWindow falls back to the template's name", function()
    local w = NS.DefaultWindow(1)
    assertEqual(w.name, TPL.name)
    assertNil(NS.DefaultWindow(nil).id, "an omitted id must stay nil, not become 0")
end)

test("Defaults: two windows share NO sub-table, at any depth", function()
    -- THE case. A shallow copy leaves `frame`, `header`, every color table and
    -- every column entry aliased between windows.
    -- red under: `local w = { }; for k,v in pairs(WINDOW_TEMPLATE) do w[k] = v end`.
    local a, b = NS.DefaultWindow(1, "A"), NS.DefaultWindow(2, "B")
    local shared = sharedTables(a, b)
    assertEqual(table.concat(shared, ", "), "", "two windows share these tables")
end)

test("Defaults: a window shares NO sub-table with the shipped template", function()
    -- The template is the object both windows would alias, and it is also what
    -- core/Database.lua's merge copies FROM — so a live window holding it would
    -- let one user edit rewrite the shipped default for every later window.
    local w = NS.DefaultWindow(1)
    local shared = sharedTables(w, TPL)
    assertEqual(table.concat(shared, ", "), "", "the window aliases the template here")
end)

test("Defaults: editing one window leaves the other and the template untouched", function()
    -- The observable consequence of the two cases above, stated as behavior so
    -- a reader who does not follow the identity walk can still see what breaks.
    local a, b = NS.DefaultWindow(1), NS.DefaultWindow(2)
    local shippedAlpha = TPL.frame.backdropColor.a
    a.frame.backdropColor.a = 0.1
    a.header.font = "Something Else"
    a.columns[1].width = 1234

    assertEqual(b.frame.backdropColor.a, shippedAlpha, "window 2's backdrop moved with window 1's")
    assertEqual(b.header.font, TPL.header.font)
    assertEqual(b.columns[1].width, Const.STAT_BY_KEY[Const.DEFAULT_STAT_KEYS[1]].defaultWidth)
    assertEqual(TPL.frame.backdropColor.a, shippedAlpha, "the shipped template itself was edited")
end)

-- ── the derived columns ─────────────────────────────────────────────────────

test("Defaults: a new window's columns are the catalog's default set, in catalog order", function()
    -- Derived rather than literal, so adding a stat with defaultEnabled = true
    -- needs no edit here — and the ORDER is the display order.
    local w = NS.DefaultWindow(1)
    local keys = {}
    for _, column in ipairs(w.columns) do keys[#keys + 1] = column.stat end
    assertEqual(table.concat(keys, ","), table.concat(Const.DEFAULT_STAT_KEYS, ","))
end)

test("Defaults: every default column takes its width from the catalog and ships its bar on",
function()
    -- The bar is what makes the grid readable at a glance; a player who wants
    -- numbers only turns it off per column.
    local w = NS.DefaultWindow(1)
    assertTrue(#w.columns > 0, "a new window with no columns would draw nothing")
    for i, column in ipairs(w.columns) do
        local stat = Const.STAT_BY_KEY[column.stat]
        assertTrue(stat ~= nil, "column " .. i .. " names a stat the catalog does not have")
        assertEqual(column.width, stat.defaultWidth, "column " .. i .. " width")
        assertEqual(column.showBar, true, "column " .. i .. " must ship with its bar")
    end
end)

test("Defaults: two windows' column entries are separate tables", function()
    -- The columns array is built fresh per window, but each ENTRY is a table
    -- too, and a shared entry means resizing one window's Damage column resizes
    -- every window's.
    local a, b = NS.DefaultWindow(1), NS.DefaultWindow(2)
    for i = 1, #a.columns do
        assertFalse(a.columns[i] == b.columns[i], "column entry " .. i .. " is shared")
    end
end)

-- ── the template's shape ────────────────────────────────────────────────────

test("Defaults: the template carries every group the settings pages edit", function()
    -- A missing group is a whole settings page reading nil, and the schema rows
    -- for it would each resolve against nothing.
    for _, group in ipairs({ "frame", "header", "rows", "bars", "text", "icons",
                             "tooltip", "visibility", "columns", "data" }) do
        assertEqual(type(TPL[group]), "table", "the window template has no " .. group .. " group")
    end
end)

test("Defaults: no template leaf is nil, and no leaf is a function", function()
    -- A nil leaf cannot be told from a missing key by core/Database.lua's
    -- `== nil` fill, so it would be re-filled from itself forever; a function
    -- leaf would not survive SavedVariables serialization at all.
    local function walk(t, path)
        for key, value in pairs(t) do
            local at = path .. "." .. tostring(key)
            assertTrue(value ~= nil, at .. " is nil")
            assertTrue(type(value) ~= "function", at .. " is a function")
            if type(value) == "table" then walk(value, at) end
        end
    end
    walk(TPL, "window")
end)

test("Defaults: every stored color is a keyed RGBA table with all four channels", function()
    -- core/CoreSetup.lua's RGBA reader accepts both the keyed and the positional
    -- shape, but what this file SHIPS has to be one of them consistently — a
    -- half-keyed `{ r = 1, [2] = 0.5 }` reads its green from the default.
    local function walk(t, path)
        for key, value in pairs(t) do
            local at = path .. "." .. tostring(key)
            if type(value) == "table" then
                if value.r ~= nil or key:lower():match("color") then
                    for _, channel in ipairs({ "r", "g", "b", "a" }) do
                        assertEqual(type(value[channel]), "number", at .. "." .. channel)
                    end
                    assertNil(value[1], at .. " mixes the keyed and positional shapes")
                else
                    walk(value, at)
                end
            end
        end
    end
    walk(TPL, "window")
end)

test("Defaults: the grid and the header ship the SAME face", function()
    -- This is a main window, and the rest of the collection draws main windows in
    -- the game's own face — a grid in a different font from the header strip
    -- above it reads as two widgets stapled together. The monospace face still
    -- ships and is still one pick away in the font dropdown; the debug console,
    -- which is a different thing with a different job, still uses it.
    -- red under: text.font = Const.FONT_MONO_NAME.
    assertEqual(TPL.text.font, TPL.header.font)
end)

test("Defaults: the shipped fonts are LSM keys, not paths", function()
    -- Stored as NAMES. A profile naming a key LSM never heard of falls back to
    -- whatever the font dropdown lists first.
    for _, key in ipairs({ TPL.text.font, TPL.header.font }) do
        assertEqual(type(key), "string")
        assertTrue(key:find("\\") == nil, "a font is stored as an LSM key, not a path: " .. key)
    end
    assertTrue(Const.FONT_MONO_NAME ~= nil,
        "the shipped monospace face is still registered and still selectable")
end)

test("Defaults: the shipped sort column is a stat the window ships enabled", function()
    -- A sort column the window does not draw sorts by a number the player
    -- cannot see, which reads exactly like a broken sort.
    local enabled = {}
    for _, key in ipairs(Const.DEFAULT_STAT_KEYS) do enabled[key] = true end
    assertTrue(enabled[TPL.data.sortColumn],
        "the shipped sortColumn " .. tostring(TPL.data.sortColumn) .. " is not a default column")
end)

test("Defaults: the shipped session type is Overall, which is never empty", function()
    -- "Current" is empty between pulls, and a window that is blank most of the
    -- time reads as a broken addon rather than as an idle one. Overall always has
    -- something in it; a player who wants just this pull picks it out of the
    -- header's segment dropdown.
    assertEqual(TPL.data.sessionType, Const.SESSION_TYPE.Overall)
end)

test("Defaults: the shipped sort mode is `value`, which R2 may fall back from", function()
    -- `value` is the mode that needs comparison and is therefore the one that
    -- degrades to `provider` under the restriction. Shipping `provider` would
    -- make that fallback unreachable for every default install.
    assertEqual(TPL.data.sortMode, "value")
end)

test("Defaults: the shipped position is stored, never read back off a frame", function()
    -- Rule R3: a cell handed a secret makes its own geometry secret and
    -- propagates that to its parent, so GetPoint on a live window is not
    -- something this addon may do. The stored table is what makes that possible.
    local p = TPL.frame.position
    assertEqual(type(p), "table")
    assertEqual(type(p.point), "string")
    assertEqual(type(p.relativePoint), "string")
    assertEqual(type(p.x), "number")
    assertEqual(type(p.y), "number")
end)

-- ── the profile tree ────────────────────────────────────────────────────────

test("Defaults: the profile itself is nearly empty — almost everything is per-window", function()
    -- A window is an INSTANCE, not a singleton. There are no global display
    -- settings, which is what makes multi-window and copy-settings-from cheap.
    --
    -- `export` is addon-wide for the opposite reason rather than by exception:
    -- it is the memory of one dialog's last four choices, and a player who picks
    -- a channel in one window means it for the next window too.
    local keys = {}
    for key in pairs(NS.defaults.profile) do keys[#keys + 1] = key end
    table.sort(keys)
    assertEqual(table.concat(keys, ","), "enabled,export,minimap,nextWindowId,windows")
end)

test("Defaults: the shipped registry is empty and the id counter starts at 1", function()
    assertEqual(#NS.defaults.profile.windows, 0)
    assertEqual(NS.defaults.profile.nextWindowId, 1)
    assertEqual(NS.defaults.profile.enabled, true)
end)

test("Defaults: the minimap table uses LibDBIcon's own `hide` key", function()
    -- The shape belongs to LibDBIcon-1.0, not to this addon. Renaming it to
    -- `show` would leave the library writing its own `hide` beside ours.
    assertEqual(NS.defaults.profile.minimap.hide, false)
end)

test("Defaults: global carries only what is genuinely account-wide", function()
    -- Two entries, and both describe the CLIENT rather than a profile: the schema
    -- version (so a migration runs once per account) and the remembered roster
    -- (which describes C_DamageMeter's data, not anybody's settings). Anything
    -- else appearing here is a per-window setting that has escaped its window.
    local keys = {}
    for key in pairs(NS.defaults.global) do keys[#keys + 1] = key end
    table.sort(keys)
    assertEqual(table.concat(keys, ","), "roster,schemaVersion")
end)

test("Defaults: the remembered roster ships EMPTY and with both of its maps", function()
    -- Persisted rather than session-only: the meter's numbers survive a reload,
    -- so the map of who those GUIDs belong to has to survive one too — otherwise
    -- the aggregator's filter throws the surviving data away on the next login,
    -- which is the bug this exists to fix.
    local roster = NS.defaults.global.roster
    assertEqual(type(roster.byGuid), "table")
    assertEqual(type(roster.pets), "table")
    assertNil(next(roster.byGuid), "a shipped default must not name anybody")
end)

test("Defaults: NS.C aliases the profile defaults rather than copying them", function()
    -- The collection's short alias. A copy would let a value added under one
    -- name be invisible under the other.
    assertTrue(NS.C == NS.defaults.profile)
end)

test("Defaults: the debug flag is NOT a profile default", function()
    -- It is session-only, in core/State.lua, and never persisted
    -- (debug-logging-§5). A console left on across a login is a console nobody
    -- asked for.
    assertNil(NS.defaults.profile.debug)
    assertNil(NS.defaults.global.debug)
end)
