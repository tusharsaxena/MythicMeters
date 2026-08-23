-- tests/test_mediasetup.lua — core/MediaSetup.lua, the LibKa0s-Media-1.0 seam.
--
-- THE CASE THAT EARNS THIS FILE is the catalog cross-check. Every icon this addon
-- draws is named as a plain string in modules/HeaderControls.lua and resolved
-- against a catalog that now lives in ANOTHER REPO. If the library renames a mark,
-- or this addon asks for one it never shipped, the answer is nil, the ladder walks
-- down to an atlas nobody has confirmed, and the control quietly stops being the
-- icon it was — with every suite green, because a texture that does not load draws
-- nothing and raises nothing. That failure has already happened twice here, which
-- is why the ladder exists at all; this is the first version of it that can be
-- caught out of game.

local T = _G.MULTIMETERS_TEST

local test        = T.test
local assertEqual = T.assertEqual
local assertTrue  = T.assertTrue
local assertNil   = T.assertNil

local VENDORED = "Interface\\AddOns\\MultiMeters\\libs\\LibKa0s\\media\\"

-- ---------------------------------------------------------------------------
-- The seam
-- ---------------------------------------------------------------------------

test("MediaSetup: NS.Icon answers the vendored path, extensionless", function()
    -- Extensionless is not a preference: this addon's header art has failed
    -- silently twice, and its surviving note says a path carrying `.tga` is one
    -- of the two spellings that draws nothing. The client appends it.
    local inst = T.load()
    assertEqual(inst.NS.Icon("settings"), VENDORED .. "icons\\settings")
end)

test("MediaSetup: an icon the library does not ship answers nil", function()
    -- nil is a value the ladder can branch on. A plausible path to a texture
    -- that is not there is a control that is simply absent, forever, silently.
    local inst = T.load()
    assertNil(inst.NS.Icon("nosuchicon"))
end)

test("MediaSetup: NS.MediaFont answers the vendored face", function()
    local inst = T.load()
    assertEqual(inst.NS.MediaFont("JetBrains Mono"),
        VENDORED .. "fonts\\JetBrainsMono-Regular.ttf")
    assertNil(inst.NS.MediaFont("Comic Sans"))
end)

test("MediaSetup: the font this addon names is the face the library registers", function()
    -- Two names for one thing, in two repos: Constants.FONT_MONO_NAME is what
    -- every default stores, and the library's FONTS is what gets registered with
    -- LibSharedMedia. A profile naming a key nobody registered silently renders
    -- in Blizzard's fallback face, which is the exact outcome shipping a
    -- monospace font was meant to prevent.
    local inst = T.load()
    local Media = inst.mocks.LibStub("LibKa0s-Media-1.0", true)
    assertTrue(Media ~= nil, "the vendored library did not load")
    assertTrue(Media.FONTS[inst.NS.Constants.FONT_MONO_NAME] ~= nil,
        "FONT_MONO_NAME is '" .. tostring(inst.NS.Constants.FONT_MONO_NAME)
        .. "', which the library's FONTS does not carry")
    assertEqual(inst.NS.Constants.FONT_MONO,
        inst.NS.MediaFont(inst.NS.Constants.FONT_MONO_NAME))
end)

-- ---------------------------------------------------------------------------
-- The catalog, against what this addon actually asks for
-- ---------------------------------------------------------------------------

test("MediaSetup: every icon the header strip draws is one the library ships", function()
    -- The names are strings in modules/HeaderControls.lua and the catalog is in
    -- another repo. A rename on either side answers nil, and nil draws nothing.
    -- red under: any art name here the library does not carry.
    local inst = T.load()
    local Media = inst.mocks.LibStub("LibKa0s-Media-1.0", true)
    local known = {}
    for _, name in ipairs(Media.ICONS) do known[name] = true end

    -- Both halves of every two-state control, because only one of them is drawn
    -- at a time and a test that took the default state would miss the other.
    for _, name in ipairs({ "close", "minimise", "expand", "lock", "unlock",
                            "settings", "segment", "reset", "export",
                            "sort-up", "sort-down" }) do
        assertTrue(known[name] == true,
            "the header draws '" .. name .. "', which LibKa0s-Media does not ship")
        assertTrue(inst.NS.Icon(name) ~= nil, "NS.Icon answered nil for " .. name)
    end
end)

test("MediaSetup: every name the library ships has a file in the vendored copy", function()
    -- The library's own suite checks its catalog against its own directory. This
    -- checks the COPY: a re-vendor that dropped a file, or a packaging step that
    -- filtered it out, leaves a catalog naming art this build does not carry.
    local inst = T.load()
    local Media = inst.mocks.LibStub("LibKa0s-Media-1.0", true)
    local root = (T.root or ".") .. "/libs/LibKa0s/media/icons/"
    local missing = {}
    for _, name in ipairs(Media.ICONS) do
        local fh = io.open(root .. name .. ".tga", "rb")
        if fh then fh:close() else missing[#missing + 1] = name end
    end
    assertEqual(table.concat(missing, ", "), "")
end)

-- ---------------------------------------------------------------------------
-- Degraded
-- ---------------------------------------------------------------------------

test("MediaSetup: with no library there is no art, and that is not an error", function()
    -- The art is INSIDE the payload that is missing, so a degraded install has
    -- none of it. NS.Icon answering nil is what sends the header down its ladder
    -- to the atlas and ASCII rungs, which exist for exactly this.
    local inst = T.load{ libFiles = {} }
    assertNil(inst.NS.Icon("settings"))
    assertNil(inst.NS.MediaFont("JetBrains Mono"))
end)
