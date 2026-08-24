-- tests/test_envsetup.lua — core/EnvSetup.lua, the LibKa0s-Env-1.0 seam.
--
-- What is asserted here is THE SEAM, not the library. The library's own suite covers the
-- C_AddOns -> bare-global ladder inside GetAddOnMetadata; a second copy of those cases here is
-- exactly the consumer-side duplication testing-§8 forbids. What only this repo can check is that
-- this addon's helpers answer what its deleted Compat shim answered, that they ask about THIS
-- addon, that the fallback constant this addon chose is still reachable, and that the shim is gone.
--
-- THE CASE THAT EARNS THIS FILE is the last one. core/Namespace.lua resolves NS.version at FILE
-- SCOPE, so the seam has to be published before it; a TOC reshuffle that moved core/EnvSetup.lua
-- below core/Namespace.lua would leave NS.version as the hardcoded FALLBACK_VERSION for the life of
-- the session, and nothing else in the suite would say so — "0.1.0" is a perfectly plausible answer.

local T = _G.MULTIMETERS_TEST

local NS          = T.NS
local mocks       = T.mocks
local test        = T.test
local assertEqual = T.assertEqual
local assertTrue  = T.assertTrue
local assertNil   = T.assertNil

-- Stand a DIFFERENT version in the mock's manifest for the duration of `fn`, recording what the
-- reader was asked about.
--
-- A literal is needed here rather than the fixture because tests/wow_mock.lua stamps
-- `__toc.Version = "0.1.0"` and core/Namespace.lua's FALLBACK_VERSION is ALSO "0.1.0". Asserting
-- the fixture would pass just as green with the TOC unread, which is the one thing these cases
-- exist to rule out.
local function withTOC(version, fn)
    local askedName, askedField
    local saved = mocks.C_AddOns
    mocks.C_AddOns = { GetAddOnMetadata = function(name, field)
            askedName, askedField = name, field
            return field == "Version" and version or mocks.__toc[field]
        end,
        IsAddOnLoaded = saved and saved.IsAddOnLoaded }
    local ok, err = pcall(fn)
    mocks.C_AddOns = saved
    if not ok then error(err, 0) end
    return askedName, askedField
end

-- ---------------------------------------------------------------------------
-- The seam
-- ---------------------------------------------------------------------------

test("EnvSetup: the vendored library really did register, so the cases below mean something",
    function()
        -- Without this, every positive case here passes just as green on a re-vendor that DROPPED
        -- Env.lua: the seam's own fallback ladder answers identically, by design, so the whole file
        -- would quietly be measuring the degraded arm twice. tests/test_mediasetup.lua asks the
        -- same question of LibKa0s-Media-1.0 and for the same reason.
        assertTrue(mocks.LibStub("LibKa0s-Env-1.0", true) ~= nil,
            "libs/LibKa0s did not register LibKa0s-Env-1.0")
    end)

test("EnvSetup: NS.Meta reads this addon's TOC", function()
    assertEqual(NS.Meta("Version"), mocks.__toc.Version)
    assertEqual(NS.Meta("Title"), mocks.__toc.Title)
    assertEqual(NS.Meta("Notes"), mocks.__toc.Notes)
end)

test("EnvSetup: NS.Meta asks about THIS addon's folder, not its title or its chat tag", function()
    -- The one thing the vendored library cannot get right on its own: it has no idea which addon
    -- folder its copy sits in, so the host supplies the name. "MultiMeters", "Ka0s Multi Meters"
    -- and "[MM]" are all live strings in this repo and only the first is the folder; a wrong one
    -- reads some other addon's manifest, or none, and answers nil without raising a thing.
    local name, field = withTOC("9.9.9", function()
        assertEqual(NS.Meta("Version"), "9.9.9")
    end)
    assertEqual(name, "MultiMeters")
    assertEqual(field, "Version")
end)

test("EnvSetup: NS.Meta answers nil — not a placeholder — for a field the TOC does not carry",
    function()
        -- The behaviour the deleted Compat.GetAddOnMetadata was pinned on: callers can tell "no
        -- manifest" from "manifest says empty" and apply their own fallback.
        assertNil(NS.Meta("NoSuchTOCField"))
    end)

test("EnvSetup: NS.Version prefers the TOC over this addon's own constant", function()
    -- A packaged addon whose TOC can be read must never report the constant somebody forgot to
    -- edit (slash-commands-§3). `/mm version`, the options header and every perf capture record
    -- resolve through here, so they cannot disagree either.
    withTOC("9.9.9", function()
        assertEqual(NS.Version(), "9.9.9")
    end)
end)

test("EnvSetup: NS.Version falls back to this addon's own constant", function()
    -- The fallback lives at the call site rather than in the library because which constant this
    -- addon falls back to is genuinely its own business — so it is the seam's job to prove it still
    -- works. Removing BOTH readers is what a client that cannot answer looks like, and is exactly
    -- what the headless harness is.
    local savedC, savedG = mocks.C_AddOns, mocks.GetAddOnMetadata
    mocks.C_AddOns, mocks.GetAddOnMetadata = nil, nil
    local ok, v = pcall(NS.Version)
    mocks.C_AddOns, mocks.GetAddOnMetadata = savedC, savedG
    assertTrue(ok, "NS.Version raised with no manifest reader: " .. tostring(v))
    assertEqual(v, NS.version)
    assertTrue(v ~= nil and v ~= "", "a version string, never nil — it goes straight into a banner")
end)

-- ---------------------------------------------------------------------------
-- Degraded
-- ---------------------------------------------------------------------------

test("EnvSetup degraded: an install with no LibKa0s still reads its own TOC", function()
    -- The case that earns the written-out fallback ladders. Without LibKa0s the seam would answer
    -- nil for everything unless it repeats the ladder the deleted shim ran, and nil is not an error
    -- a player would ever see reported: it is a blank version in the banner and "v?" on every perf
    -- record. Nothing here loads the library, so this runs the else-branch of both helpers.
    local inst = T.load{ libFiles = {} }
    assertEqual(inst.NS.Meta("Version"), inst.mocks.__toc.Version)
    assertEqual(inst.NS.Version(), inst.mocks.__toc.Version)
end)

-- ---------------------------------------------------------------------------
-- What the seam replaced, and where it has to sit
-- ---------------------------------------------------------------------------

test("EnvSetup: the deleted shim is gone from Compat", function()
    -- A seam that leaves the old copy in place is a second answer nobody removed, and the next
    -- caller reaches for whichever one autocomplete offers first.
    assertNil(NS.Compat.GetAddOnMetadata)
end)

test("EnvSetup: the deprecated bare global is still a live rung, all the way to NS.version",
    function()
        -- Ported from tests/test_compat.lua with the shim it used to cover. The rung ITSELF is the
        -- library's to prove (testing-§8); what only this repo can say is that a client old enough
        -- to have no C_AddOns still resolves core/Namespace.lua's load-time version through it.
        -- Losing it would stamp `/mm version`, the options header and every capture record with the
        -- in-code constant on such a client, and all three would agree, so nothing would look wrong.
        local inst = T.load{ mutate = function(m)
            m.C_AddOns = nil
            m.GetAddOnMetadata = function(_, field) return field == "Version" and "9.9.9" or nil end
        end }
        assertEqual(inst.NS.Meta("Version"), "9.9.9")
        assertEqual(inst.NS.version, "9.9.9")
    end)

test("EnvSetup: with no reader at all, core/Namespace.lua takes its own FALLBACK_VERSION",
    function()
        -- Also ported. nil from the seam is what lets core/Namespace.lua tell "no manifest" from
        -- "manifest says empty" and apply the constant — which is the fallback this addon chose,
        -- and therefore this addon's to assert rather than the library's.
        local inst = T.load{ mutate = function(m)
            m.C_AddOns, m.GetAddOnMetadata = nil, nil
        end }
        assertNil(inst.NS.Meta("Version"))
        assertEqual(inst.NS.version, inst.NS.FALLBACK_VERSION)
    end)

test("EnvSetup: the version was resolved at load, not deferred", function()
    -- core/Namespace.lua reads it at FILE SCOPE. If core/EnvSetup.lua loaded after it, NS.version
    -- would be the hardcoded FALLBACK_VERSION for the life of the session and nothing else would
    -- say so.
    --
    -- A fresh instance with a manifest that does NOT match the constant is the only way to ask
    -- this: the shared instance's fixture version is "0.1.0" and FALLBACK_VERSION is "0.1.0" too,
    -- so asserting against it would be just as green with the seam loading last, or missing.
    local inst = T.load{ mutate = function(m) m.__toc.Version = "9.9.9" end }
    assertEqual(inst.NS.version, "9.9.9")
    assertTrue(inst.NS.version ~= inst.NS.FALLBACK_VERSION,
        "core/Namespace.lua fell back to its constant, so the seam was not published yet")
end)
