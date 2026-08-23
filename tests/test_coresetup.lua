-- tests/test_coresetup.lua — LibKa0s-Core-1.0 wiring.
--
-- The first case is the one that keeps every other case in this repo honest.
-- testing-§9: a library file omitted from the runner's load list leaves its major
-- unregistered, the host's setup file falls back to its degradation stub, and the
-- suite happily measures THE STUB — green, and testing nothing. So the registry
-- is pinned before anything else is asserted.
--
-- What core/CoreSetup.lua itself owns is three seams:
--
--   * the PRINTER, which has to survive AceConsole's embed. AceAddon:NewAddon
--     stamps AceConsole's own `:Print` over NS.Print during the call in
--     core/MythicMeters.lua — green, trailing colon, no cyan tag, no error and
--     nothing to say so. The reclaim on the next line only restores the LIBRARY
--     printer because NS.Print and NS.Util.print hold one identical function
--     object rather than two wrappers around it.
--   * the SECRET-SAFE seam. Every number this addon prints came off
--     C_DamageMeter and is secret for the whole of a pull, so a chat line
--     carrying one is not an edge case — it is Tuesday.
--   * the STORED-COLOR reader, whose whole job is that a stored 0 survives as 0.

local T = _G.MYTHICMETERS_TEST
local NS, mocks = T.NS, T.mocks
local test, assertEqual, assertTrue, assertFalse, assertNil, assertNear =
    T.test, T.assertEqual, T.assertTrue, T.assertFalse, T.assertNil, T.assertNear

-- Every major LibKa0s.xml ships. Kept as data so the next case compares the
-- runner's derived list against it rather than trusting a second hand-typed one.
local MAJORS = {
    "LibKa0s-Core-1.0",
    "LibKa0s-DebugLog-1.0",
    "LibKa0s-Slash-1.0",
    "LibKa0s-Options-1.0",
    "LibKa0s-Perf-1.0",
}

-- ── the library is really loaded ────────────────────────────────────────────

test("CoreSetup: the harness loads the vendored LibKa0s majors, so nothing measures a stub",
function()
    for _, major in ipairs(MAJORS) do
        assertTrue(mocks.LibStub(major, true) ~= nil,
            major .. " is not registered — the runner's library load list is wrong, and every "
            .. "assertion in this repo would be measuring the degradation stub")
    end
end)

test("CoreSetup: the runner FEEDS the derived library list, and it is not empty", function()
    -- An empty list loads nothing and reads exactly like a clean run.
    assertTrue(#T.libFiles > 0, "the runner fed the loader an EMPTY library list")
    assertEqual(#T.libFiles, #T.Loader.xmlFiles(T.root .. "/libs/LibKa0s/LibKa0s.xml"),
        "the fed list is not the list Loader.xmlFiles derives from LibKa0s.xml")
    for i, path in ipairs(T.libFiles) do
        assertTrue(path:find("libs/LibKa0s/", 1, true) ~= nil,
            "entry " .. i .. " is not a libs/LibKa0s path: " .. tostring(path))
        local fh = io.open(path, "r")
        assertTrue(fh ~= nil, "missing library file: " .. path)
        if fh then fh:close() end
    end
end)

test("CoreSetup: the TOC-derived addon list leaks no libs/ entry", function()
    -- Loader.tocFiles skips `libs\` lines on purpose: the vendored library comes
    -- in through an XML the TOC scan cannot see inside, and the runner loads it
    -- FIRST. A `libs/` path surviving into the addon list would load a library
    -- file a second time, after the addon's sources and out of XML order.
    assertTrue(#T.loadedAddonFiles > 0, "the TOC-derived addon list is empty")
    -- Only meaningful while the TOC actually declares a `.lua` under `libs\` for
    -- the skip to skip. It declares several today.
    local fh = assert(io.open(T.root .. "/MythicMeters.toc", "r"))
    local toc = fh:read("*a")
    fh:close()
    assertTrue(toc:lower():match("[\r\n]%s*libs[\\/][^\r\n]*%.lua") ~= nil,
        "the TOC declares no libs/*.lua line, so this guard asserts nothing")
    for _, rel in ipairs(T.loadedAddonFiles) do
        assertNil(rel:lower():match("^libs/"), "libs/ path leaked into the addon list: " .. rel)
    end
end)

test("CoreSetup: the suite list and tests/test_*.lua on disk agree in both directions", function()
    -- Kit.run asserts this before it loads a single case, so a drifting list is
    -- already a hard error. Restated here so the failure has a NAME in the run
    -- output rather than only in a stack trace before the run began.
    T.assertSuiteInventory(T.root .. "/tests/", T.suites)
end)

-- ── the printer ─────────────────────────────────────────────────────────────

test("CoreSetup: NS.Print and NS.Util.print are the SAME function object", function()
    -- Not two wrappers that render alike. The AceConsole reclaim in
    -- core/MythicMeters.lua restores NS.Print by reading NS.Util.print back, and
    -- it only restores the library printer because of this identity.
    -- red under: `Util.print = function(...) return NS.Print(...) end`.
    assertEqual(type(NS.Print), "function")
    assertTrue(NS.Print == NS.Util.print, "the reclaim would restore a different printer")
end)

test("CoreSetup: the printer survives AceConsole's embed", function()
    -- AceAddon:NewAddon stamps AceConsole's `:Print` over NS.Print. The reclaim
    -- runs on the very next line, so by the time any suite sees NS it must be
    -- the library printer again — and the way to tell is the cyan tag, which
    -- AceConsole's never emits.
    -- red under: deleting the reclaim block from core/MythicMeters.lua.
    local inst = T.load{}
    inst.NS.Print("hello")
    local line = inst.mocks.__chat[#inst.mocks.__chat]
    assertTrue(line ~= nil, "nothing reached the chat frame")
    assertTrue(line:find(inst.NS.PREFIX, 1, true) == 1,
        "the printed line does not lead with the cyan [MM] tag: " .. tostring(line))
    assertTrue(line:find("hello", 1, true) ~= nil)
end)

test("CoreSetup: the prefix is re-read on every call, not frozen at load", function()
    -- The printer is built once at load; the FUNCTION form of the prefix is what
    -- keeps a later retag from being frozen out.
    -- red under: passing `prefix = NS.PREFIX` instead of a function.
    local inst = T.load{}
    inst.NS.PREFIX = "|cffff0000[RETAG]|r"
    inst.NS.Print("after")
    assertTrue(inst.mocks.__chat[#inst.mocks.__chat]:find("[RETAG]", 1, true) ~= nil,
        "the printer froze the prefix at load")
end)

test("CoreSetup: NS.Format renders through the same printer", function()
    local inst = T.load{}
    inst.NS.Format("%s rows in %d windows", "12", 3)
    local line = inst.mocks.__chat[#inst.mocks.__chat]
    assertTrue(line:find("12 rows in 3 windows", 1, true) ~= nil, "got: " .. tostring(line))
end)

-- ── the secret-safe seam ────────────────────────────────────────────────────

test("CoreSetup: IsConcatSafe rejects a value table.concat would raise on", function()
    -- The probe has to test the operation that actually rejects a secret: a
    -- protected value survives tostring() and the `..` operator and raises only
    -- inside table.concat.
    assertTrue(NS.IsConcatSafe("text"))
    assertTrue(NS.IsConcatSafe(1234))
    assertFalse(NS.IsConcatSafe(mocks.secret(1234)),
        "a secret must be refused, or every chat line carrying one raises mid-pull")
end)

test("CoreSetup: SafeToString renders a secret as the sentinel rather than raising", function()
    assertEqual(NS.SafeToString(nil), "nil")
    assertEqual(NS.SafeToString(true), "true")
    assertEqual(NS.SafeToString(42), "42")
    local rendered = NS.SafeToString(mocks.secret(42))
    assertEqual(type(rendered), "string")
    assertFalse(rendered == "42", "a secret must not render as its value")
end)

test("CoreSetup: the secret-safe members are the library's own, published by reference", function()
    -- Lib-level and stateless, so they are published by reference rather than
    -- wrapped. A wrapper would be a second thing to keep in step with the
    -- library, in the file whose whole job is to have none.
    local lib = mocks.LibStub("LibKa0s-Core-1.0", true)
    assertTrue(NS.IsConcatSafe == lib.IsConcatSafe)
    assertTrue(NS.SafeToString == lib.SafeToString)
end)

-- ── the stored-color reader ─────────────────────────────────────────────────

test("CoreSetup: RGBA reads the keyed shape the profile ships", function()
    local r, g, b, a = NS.RGBA({ r = 0.1, g = 0.2, b = 0.3, a = 0.4 }, 1, 1, 1, 1)
    assertNear(r, 0.1); assertNear(g, 0.2); assertNear(b, 0.3); assertNear(a, 0.4)
end)

test("CoreSetup: RGBA reads the positional shape the options color widget writes", function()
    local r, g, b, a = NS.RGBA({ 0.1, 0.2, 0.3, 0.4 }, 1, 1, 1, 1)
    assertNear(r, 0.1); assertNear(g, 0.2); assertNear(b, 0.3); assertNear(a, 0.4)
end)

test("CoreSetup: a stored ZERO channel survives as zero", function()
    -- The `== nil` rule again, in the reader this time. `c.r or dr` would turn a
    -- deliberate black into the default on every read — and black is the shipped
    -- backdrop color, so this is not a hypothetical shape.
    -- red under: `return c.r or dr, c.g or dg, ...`.
    local r, g, b, a = NS.RGBA({ r = 0, g = 0, b = 0, a = 0 }, 1, 1, 1, 1)
    assertEqual(r, 0); assertEqual(g, 0); assertEqual(b, 0); assertEqual(a, 0)
end)

test("CoreSetup: presence of any of r/g/b makes the keyed shape win for all four", function()
    -- So `{ r = 1 }` cannot silently borrow its green from c[2].
    local r, g, b, a = NS.RGBA({ r = 1, 0.5, 0.5, 0.5 }, 0, 0, 0, 1)
    assertEqual(r, 1)
    assertEqual(g, 0, "green came from the positional slot of a keyed color")
    assertEqual(b, 0)
    assertEqual(a, 1)
end)

test("CoreSetup: channels fall back independently, so a three-element color keeps its alpha",
function()
    local r, g, b, a = NS.RGBA({ 0.2, 0.4, 0.6 }, 1, 1, 1, 0.75)
    assertNear(r, 0.2); assertNear(g, 0.4); assertNear(b, 0.6)
    assertNear(a, 0.75)
end)

test("CoreSetup: RGBA answers the four defaults for a non-table", function()
    local r, g, b, a = NS.RGBA(nil, 1, 2, 3, 4)
    assertEqual(r, 1); assertEqual(g, 2); assertEqual(b, 3); assertEqual(a, 4)
    assertEqual((NS.RGBA("not a color", 9, 9, 9, 9)), 9)
end)

test("CoreSetup: the fallback color reader stands behind the library's", function()
    -- lib.RGBA arrived at Core minor 4, and a vendored copy older than that
    -- answers the major without the member. The fallback is defined above the
    -- branch precisely so BOTH paths have it.
    -- red under: `NS.RGBA = lib.RGBA` with no `or fallbackRGBA`.
    local inst = T.load{}
    -- Rebuild the seam with a Core that has no RGBA, the way an older vendored
    -- copy would present. Only this instance's LibStub table is touched.
    local lib = inst.mocks.LibStub("LibKa0s-Core-1.0", true)
    local saved = lib.RGBA
    lib.RGBA = nil
    local NS2 = { Constants = inst.NS.Constants, PREFIX = inst.NS.PREFIX,
                  LIBKA0S_MISSING = inst.NS.LIBKA0S_MISSING, Util = {} }
    T.Loader.load(T.root .. "/core/CoreSetup.lua", NS2, inst.mocks)
    lib.RGBA = saved

    assertEqual(type(NS2.RGBA), "function", "the seam left no color reader at all")
    local r, g, b, a = NS2.RGBA({ r = 0, g = 0, b = 0, a = 0 }, 1, 1, 1, 1)
    assertEqual(r, 0); assertEqual(g, 0); assertEqual(b, 0); assertEqual(a, 0)
end)

-- ── the window chrome seam ──────────────────────────────────────────────────

test("CoreSetup: the window edge comes from the library, never from a private lookalike", function()
    -- standalone-windows: agreement by VALUE is a copy, and a copy drifts one hex
    -- digit at a time. modules/Window.lua reaches the edge through these three
    -- names so a re-skin lands on the meter window, the debug console and the
    -- perf panel at once.
    local lib = mocks.LibStub("LibKa0s-Core-1.0", true)
    assertTrue(NS.SKIN == lib.SKIN, "NS.SKIN must BE the library's table")
    assertTrue(NS.ApplySkin == lib.ApplySkin)
end)

test("CoreSetup: the close button is the library's, told which addon is asking", function()
    -- The one seam here that is WRAPPED rather than handed over. LibKa0s draws this
    -- collection's own close icon when it can build a texture path, and it cannot
    -- work that out itself: it is vendored, so there is no one path to it and a copy
    -- cannot know which folder it was copied into. The wrapper supplies the answer,
    -- once, for every close control in this addon.
    -- red under: NS.MakeCloseButton = lib.MakeCloseButton, which draws the glyph.
    local seen
    local lib = mocks.LibStub("LibKa0s-Core-1.0", true)
    local real = lib.MakeCloseButton
    lib.MakeCloseButton = function(_, _, name) seen = name; return nil end
    NS.MakeCloseButton(mocks.__stubFrame("Frame"), function() end)
    lib.MakeCloseButton = real

    assertEqual(seen, "MythicMeters",
        "the library was not told which addon folder to build the path from")
end)

test("CoreSetup: no addon file restates a Core.SKIN value", function()
    -- The copy this seam exists to prevent. modules/Window.lua and
    -- modules/Row.lua must read NS.SKIN, never a hex literal that happens to
    -- match it today.
    -- red under: pasting Core.SKIN's edgeFile or backdrop color into a module.
    local lib = mocks.LibStub("LibKa0s-Core-1.0", true)
    local literals = {}
    for _, value in pairs(lib.SKIN or {}) do
        if type(value) == "string" and #value > 12 then literals[#literals + 1] = value end
    end
    assertTrue(#literals > 0, "Core.SKIN carries no string value long enough to grep for")
    for _, rel in ipairs(T.loadedAddonFiles) do
        local fh = io.open(T.root .. "/" .. rel, "r")
        local src = fh and fh:read("*a") or ""
        if fh then fh:close() end
        for _, literal in ipairs(literals) do
            assertNil(src:find(literal, 1, true),
                rel .. " restates a Core.SKIN value verbatim: " .. literal)
        end
    end
end)

-- ── the shared cause clause ─────────────────────────────────────────────────

test("CoreSetup: NS.LIBKA0S_MISSING is set on BOTH paths, not only the degraded one", function()
    -- A half-vendored libs/LibKa0s can have Core.lua present and Perf.lua
    -- missing, and the four other seams append their own consequence to this
    -- clause. Setting it inside the `if not lib` branch would concatenate a nil
    -- and take core/PerfSetup.lua down at load on exactly that install.
    -- red under: moving the assignment inside the degraded branch.
    assertEqual(type(NS.LIBKA0S_MISSING), "string")
    assertTrue(NS.LIBKA0S_MISSING:find("LibKa0s", 1, true) ~= nil)
    assertTrue(NS.LIBKA0S_MISSING:find("libs/LibKa0s", 1, true) ~= nil,
        "the clause must name where the library is expected")
    -- No terminal punctuation: each seam appends its own consequence and its own
    -- full stop, so a trailing one here would produce "…installation. , so …".
    assertNil(NS.LIBKA0S_MISSING:match("[%.!]$"),
        "the shared clause must not carry its own terminal punctuation")
end)

test("CoreSetup: all five seams append to the shared clause rather than re-spelling it", function()
    -- One cause said the same way five times, and a different consequence each
    -- time. A hand-copied cause is five strings to keep in step.
    -- red under: writing "The LibKa0s library is missing" out again in a seam.
    for _, rel in ipairs({ "core/PerfSetup.lua", "core/DebugLogSetup.lua",
                           "settings/Slash.lua", "settings/OptionsSetup.lua" }) do
        local fh = assert(io.open(T.root .. "/" .. rel, "r"))
        local src = fh:read("*a")
        fh:close()
        assertTrue(src:find("NS.LIBKA0S_MISSING", 1, true) ~= nil,
            rel .. " does not use the shared cause clause")
        assertNil(src:match('"The LibKa0s library is missing'),
            rel .. " re-spells the shared cause clause instead of appending to it")
    end
end)
