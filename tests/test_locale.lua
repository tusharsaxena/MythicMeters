-- tests/test_locale.lua — locales/enUS.lua and the L contract.
--
-- The whole point of the locale table is that a MISS IS NOT A FAILURE: `L`
-- carries a metatable whose `__index` returns the key itself, so a module may
-- ship `L["Some New String"]` before this file has been updated and a partial
-- translation degrades to English one string at a time rather than rendering nil
-- (anti-patterns #2).
--
-- That fallback is also why the interesting failures here are all SILENT:
--
--   * a key declared twice. The second assignment wins, the first translation is
--     unreachable, and nothing raises.
--   * a translated value that drops a `%s` or a `%d` its key carries. Every one
--     of these strings is reached through `:format(...)`, and a specifier count
--     that does not match the argument count is a Lua error at the call site —
--     in a locale nobody on the team reads.
--   * the table handed to a LibKa0s descriptor as its `L`. The fallback makes it
--     answer a string for EVERY key, which satisfies the library's override check
--     for every key it has, so the library's own strings become unreachable and
--     the panel renders STEP_START / PANEL_TITLE_SUFFIX verbatim — visible only
--     in game. The locale file's own header calls this out; this suite is what
--     keeps it from happening anyway.

local T = _G.MYTHICMETERS_TEST
local NS = T.NS
local test, assertEqual, assertTrue, assertNil = T.test, T.assertEqual, T.assertTrue, T.assertNil

local L = NS.L
local ROOT = T.root or "."

--- locales/enUS.lua's source, read once per case that needs it. The RAW text is
--- what several cases below have to look at: the live table cannot tell a
--- declared key from a fallback, which is exactly the property under test.
local function localeSource()
    local fh = assert(io.open(ROOT .. "/locales/enUS.lua", "r"))
    local body = fh:read("*a")
    fh:close()
    return body
end

--- The `%s` / `%d` / `%.1f` specifiers in a string, sorted, as one comparable key.
local function specifiers(s)
    local found = {}
    for spec in tostring(s):gmatch("%%[%-%d%.]*[sdfxq%%]") do found[#found + 1] = spec end
    table.sort(found)
    return table.concat(found, "")
end

-- ── the fallback ────────────────────────────────────────────────────────────

test("Locale: a missing key returns the key itself", function()
    -- The contract every call site depends on. Without it a new string renders
    -- as nil, which in a SetText is a blank widget rather than an error.
    assertEqual(L["a string that will never be translated"],
        "a string that will never be translated")
end)

test("Locale: the fallback never returns nil, for any key shape", function()
    for _, key in ipairs({ "", "%s", "Column %d", "Ka0s Mythic Meters", "1234" }) do
        assertTrue(L[key] ~= nil, "L[" .. string.format("%q", key) .. "] answered nil")
    end
end)

test("Locale: NS.L is published before any consumer can read it", function()
    -- locales/ loads FIRST in the TOC, ahead of core/, so this file bootstraps
    -- the namespace. tests/test_loadorder.lua pins the ordering; this pins that
    -- the symbol exists at all and is the shape callers assume.
    assertEqual(type(L), "table")
    assertTrue(getmetatable(L) ~= nil, "NS.L must carry the fallback metatable")
    assertEqual(type(getmetatable(L).__index), "function")
end)

-- ── the shipped table ───────────────────────────────────────────────────────

test("Locale: every declared entry is a non-empty string", function()
    -- An empty value is worse than a missing one: the fallback would have
    -- rendered the English key, and an empty string renders nothing at all.
    local n = 0
    for key, value in localeSource():gmatch('L%["([^"]+)"%]%s*=%s*\n?%s*"([^"]*)"') do
        n = n + 1
        assertTrue(#value > 0, "locale entry " .. key .. " is empty")
    end
    assertTrue(n >= 300, "the locale scan found only " .. n .. " entries — the pattern drifted")
end)

test("Locale: no key is declared twice", function()
    -- The second assignment wins silently and the first translation becomes
    -- unreachable. Nothing else in the repo would notice.
    -- red under: pasting an existing key into a new block of the locale file.
    local seen, dupes = {}, {}
    for key in localeSource():gmatch('\nL%["([^"]+)"%]%s*=') do
        if seen[key] then dupes[#dupes + 1] = key end
        seen[key] = true
    end
    assertEqual(table.concat(dupes, ", "), "", "duplicate locale keys")
end)

test("Locale: every translated value carries the same format specifiers as its key", function()
    -- These strings are reached through `:format(...)`. A value that drops a
    -- `%s` its key carries raises at the call site — in a locale nobody on the
    -- team reads — and a value that ADDS one renders "%s" to the player.
    -- red under: dropping the `%d` from any "Column %d ..." value.
    local checked, problems = 0, {}
    for key, value in localeSource():gmatch('L%["([^"]+)"%]%s*=%s*\n?%s*"([^"]*)"') do
        checked = checked + 1
        if specifiers(key) ~= specifiers(value) then
            problems[#problems + 1] = key
        end
    end
    assertTrue(checked >= 300, "the scan checked only " .. checked .. " entries")
    assertEqual(table.concat(problems, "; "), "", "format specifiers differ between key and value")
end)

test("Locale: every stat label and short label in the catalog is declared", function()
    -- The one place the fallback is NOT good enough. A short label is three
    -- characters and reads identically whether it came from a translation or
    -- from the key, so a translator copying this file would never discover it
    -- was missing.
    local declared = {}
    for key in localeSource():gmatch('L%["([^"]+)"%]%s*=') do declared[key] = true end
    for _, stat in ipairs(NS.Constants.STATS) do
        assertTrue(declared[stat.label], "no locale entry for stat label " .. stat.label)
        assertTrue(declared[stat.shortLabel], "no locale entry for " .. stat.shortLabel)
    end
end)

test("Locale: keys are the English strings, not opaque identifiers", function()
    -- What keeps a call site stable across every locale: translators copy this
    -- file, change the right-hand sides, and rename it. An identifier-shaped key
    -- (SCREAMING_SNAKE, or dotted) means the English is somewhere else too.
    local offenders = {}
    for key in localeSource():gmatch('L%["([^"]+)"%]%s*=') do
        if key:match("^[A-Z][A-Z0-9_]+$") and #key > 3 then offenders[#offenders + 1] = key end
    end
    -- The catalog's short labels are the legitimate exception: DMG / HEAL / AVD
    -- are what fits a column header, and they ARE the English.
    local allowed = {}
    for _, stat in ipairs(NS.Constants.STATS) do allowed[stat.shortLabel] = true end
    local unexpected = {}
    for _, key in ipairs(offenders) do
        if not allowed[key] then unexpected[#unexpected + 1] = key end
    end
    assertEqual(table.concat(unexpected, ", "), "", "identifier-shaped locale keys")
end)

-- ── the L trap ──────────────────────────────────────────────────────────────

test("Locale: NS.L is never handed to a LibKa0s descriptor as its `L`", function()
    -- THE trap the locale file's own header documents. The fallback answers a
    -- string for every key, so a library handed this table finds an "override"
    -- for every one of ITS strings and renders its own identifiers to the
    -- player. core/PerfSetup.lua carries a comment explaining why it passes
    -- nothing; this is what enforces it.
    -- red under: adding `L = NS.L,` to any of the five seam descriptors.
    for _, rel in ipairs({ "core/PerfSetup.lua", "core/DebugLogSetup.lua",
                           "core/CoreSetup.lua", "settings/Slash.lua",
                           "settings/OptionsSetup.lua" }) do
        local fh = assert(io.open(ROOT .. "/" .. rel, "r"))
        local src = fh:read("*a")
        fh:close()
        src = src:gsub("%-%-[^\r\n]*", "")
        assertNil(src:match("[\r\n]%s*L%s*=%s*NS%.L"),
            rel .. " hands the addon-wide locale table to a library descriptor")
        assertNil(src:match("[\r\n]%s*L%s*=%s*L%s*,"),
            rel .. " hands a captured locale table to a library descriptor")
    end
end)

test("Locale: the locale file registers no second table over NS.L", function()
    -- One table, one metatable. A second `NS.L = ...` further down the file
    -- would drop every entry declared above it.
    local assignments = 0
    for _ in localeSource():gmatch("[\r\n]NS%.L%s*=") do assignments = assignments + 1 end
    assertEqual(assignments, 1, "locales/enUS.lua assigns NS.L " .. assignments .. " times")
end)

test("Locale: enUS is the only locale shipped, and it is unconditional", function()
    -- A locale file gated on GetLocale() would leave NS.L nil for every other
    -- client, and the fallback that makes a partial translation safe only exists
    -- once the table does.
    local files = {}
    for _, rel in ipairs(T.loadedAddonFiles) do
        if rel:lower():match("^locales/") then files[#files + 1] = rel end
    end
    assertEqual(table.concat(files, ", "), "locales/enUS.lua")
    assertNil(localeSource():match("GetLocale%s*%(%s*%)%s*[~=]="),
        "locales/enUS.lua must not gate itself on the client locale")
end)
