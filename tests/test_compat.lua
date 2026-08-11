-- tests/test_compat.lua — core/Compat.lua, the addon's whole cross-patch surface.
--
-- Two properties, and the second is the one that actually bites:
--
--   * every shim forwards to the modern namespace where it exists, falls back to
--     the deprecated global where it does not, and answers a SAFE value where
--     neither is there. This addon's "might not exist" surface is unusually
--     large — C_DamageMeter is new in 12.0, so a client one patch behind has none
--     of it, and a PTR build can have the namespace without one of its functions.
--
--   * NOTHING here inspects a meter value. Reading a field off a session table is
--     not inspection; assigning it to a local and asking a question about it is,
--     and that is core/Secrets.lua's exclusive job (design rule R1). A single
--     `if session.totalAmount > 0` in this file would be a Lua error mid-pull, in
--     the one place a player cannot see it — so every meter shim is driven here
--     with the fixture arriving SECRET, which is the only configuration in which
--     that mistake shows up.

local T = _G.MYTHICMETERS_TEST
local NS, mocks = T.NS, T.mocks
local test, assertEqual, assertTrue, assertFalse, assertNil =
    T.test, T.assertEqual, T.assertTrue, T.assertFalse, T.assertNil

local Compat = NS.Compat
local Const  = NS.Constants

--- A fresh instance whose simulated client is missing the named namespaces.
local function loadWithout(...)
    local names = { ... }
    return T.load{ mutate = function(m)
        for _, name in ipairs(names) do m[name] = nil end
    end }
end

--- An instance with a five-source Damage session installed, arriving SECRET.
local function restrictedInstance()
    local inst = T.load{}
    local m = inst.mocks
    m.setSession(Const.SESSION_TYPE.Current, Const.STAT_TYPE.DamageDone, m.buildSession{ count = 5 })
    m.setSourceDetail(Const.SESSION_TYPE.Current, Const.STAT_TYPE.DamageDone, "*",
        m.buildSourceDetail{ count = 3 })
    m.setSessionDuration(Const.SESSION_TYPE.Current, 212)
    m.setRestricted(true)
    return inst
end

-- ── the manifest reader ─────────────────────────────────────────────────────

test("Compat: GetAddOnMetadata reads the TOC through C_AddOns", function()
    assertEqual(Compat.GetAddOnMetadata("MythicMeters", "Version"), mocks.__toc.Version)
    assertEqual(Compat.GetAddOnMetadata("MythicMeters", "Title"), mocks.__toc.Title)
end)

test("Compat: GetAddOnMetadata falls back to the deprecated bare global", function()
    -- The pre-11.x seam. core/Namespace.lua, settings/Slash.lua and
    -- core/PerfSetup.lua all resolve the version through this one shim, so
    -- losing the fallback would stamp three separate surfaces "0.1.0" from the
    -- in-code constant on an older client.
    local inst = T.load{ mutate = function(m)
        m.C_AddOns = nil
        m.GetAddOnMetadata = function(_, field) return field == "Version" and "9.9.9" or nil end
    end }
    assertEqual(inst.NS.Compat.GetAddOnMetadata("MythicMeters", "Version"), "9.9.9")
    assertEqual(inst.NS.version, "9.9.9",
        "core/Namespace.lua resolves the version through the same fallback at load")
end)

test("Compat: GetAddOnMetadata answers nil — not a placeholder — with no reader at all", function()
    -- nil is what lets core/Namespace.lua tell "no manifest" from "manifest says
    -- empty" and apply FALLBACK_VERSION.
    local inst = loadWithout("C_AddOns", "GetAddOnMetadata")
    assertNil(inst.NS.Compat.GetAddOnMetadata("MythicMeters", "Version"))
    assertEqual(inst.NS.version, inst.NS.FALLBACK_VERSION)
end)

-- ── spell APIs ──────────────────────────────────────────────────────────────

test("Compat: GetSpellInfo flattens C_Spell's struct to the old multi-return", function()
    -- Call sites read the same on either client precisely because this shim
    -- unpacks the struct rather than handing it on.
    local name, icon, castTime, minRange, maxRange, id = Compat.GetSpellInfo(4321)
    assertEqual(name, "Mock Spell 4321")
    assertEqual(icon, 130000 + 4321)
    assertEqual(castTime, 0)
    assertEqual(minRange, 0)
    assertEqual(maxRange, 40)
    assertEqual(id, 4321)
end)

test("Compat: GetSpellInfo answers nil for an unknown spell rather than raising", function()
    local inst = T.load{ mutate = function(m)
        m.C_Spell = { GetSpellInfo = function() return nil end }
    end }
    assertNil(inst.NS.Compat.GetSpellInfo(1))
end)

test("Compat: GetSpellInfo and GetSpellTexture fall back to the bare globals", function()
    local inst = T.load{ mutate = function(m)
        m.C_Spell = nil
        m.GetSpellInfo    = function(id) return "Old " .. id, 7, 0, 0, 40, id end
        m.GetSpellTexture = function(id) return 500 + id end
    end }
    assertEqual((inst.NS.Compat.GetSpellInfo(3)), "Old 3")
    assertEqual(inst.NS.Compat.GetSpellTexture(3), 503)
end)

test("Compat: the spell shims answer nil with no API at all", function()
    -- The tooltip and the drill-down render spell rows from these; nil is what
    -- makes them draw a row without an icon rather than take the panel down.
    local inst = loadWithout("C_Spell", "GetSpellInfo", "GetSpellTexture")
    assertNil(inst.NS.Compat.GetSpellInfo(1))
    assertNil(inst.NS.Compat.GetSpellTexture(1))
end)

-- ── specialization APIs ─────────────────────────────────────────────────────

test("Compat: the spec shims prefer C_SpecializationInfo and fall back to the globals", function()
    assertEqual(Compat.GetSpecialization(), 1)
    local id, name, _, icon, role = Compat.GetSpecializationInfo(1)
    assertEqual(id, 250)
    assertEqual(name, "Blood")
    assertEqual(icon, 135771)
    assertEqual(role, "TANK")

    local inst = T.load{ mutate = function(m)
        m.C_SpecializationInfo = nil
        m.GetSpecialization     = function() return 3 end
        m.GetSpecializationInfo = function() return 577, "Havoc", "", 1, "DAMAGER" end
    end }
    assertEqual(inst.NS.Compat.GetSpecialization(), 3)
    assertEqual(select(2, inst.NS.Compat.GetSpecializationInfo(3)), "Havoc")
end)

test("Compat: the spec shims answer nil with no API at all", function()
    local inst = loadWithout("C_SpecializationInfo", "GetSpecialization", "GetSpecializationInfo")
    assertNil(inst.NS.Compat.GetSpecialization())
    assertNil(inst.NS.Compat.GetSpecializationInfo(1))
end)

-- ── C_DamageMeter: the addon's entire data source ───────────────────────────

test("Compat: IsDamageMeterAvailable forwards Blizzard's own failure reason verbatim", function()
    -- The window renders it in place of rows. We do not translate it and do not
    -- second-guess it: it is the only thing that can tell a player their meter
    -- is off because of a CVar rather than because this addon is broken.
    local inst = T.load{}
    local ok, reason = inst.NS.Compat.IsDamageMeterAvailable()
    assertTrue(ok)
    assertNil(reason)

    inst.mocks.setMeterAvailable(false, "DAMAGE_METER_DISABLED_BY_CVAR")
    ok, reason = inst.NS.Compat.IsDamageMeterAvailable()
    assertFalse(ok)
    assertEqual(reason, "DAMAGE_METER_DISABLED_BY_CVAR")
end)

test("Compat: with no C_DamageMeter, IsDamageMeterAvailable is false and the addon still loads",
function()
    -- An 11.x client has none of the namespace. The unavailable-notice path
    -- already knows how to render this, so a load-time error here would be the
    -- addon failing at the one thing it was built to degrade through.
    local inst = loadWithout("C_DamageMeter")
    local ok, reason = inst.NS.Compat.IsDamageMeterAvailable()
    assertFalse(ok)
    assertNil(reason)
end)

test("Compat: every session shim answers nil with no C_DamageMeter", function()
    local inst = loadWithout("C_DamageMeter")
    local C = inst.NS.Compat
    assertNil(C.GetCombatSessionFromType(1, 0))
    assertNil(C.GetCombatSessionFromID(1, 0))
    assertNil(C.GetCombatSessionSourceFromType(1, 0, "guid"))
    assertNil(C.GetCombatSessionSourceFromID(1, 0, "guid"))
    assertNil(C.GetSessionDurationSeconds(1))
end)

test("Compat: GetAvailableCombatSessions answers an EMPTY TABLE, never nil", function()
    -- The session picker iterates it unconditionally. A nil there would put an
    -- existence check in the UI layer for a case the UI cannot do anything about.
    -- red under: `return nil` in the missing-API branch.
    local inst = loadWithout("C_DamageMeter")
    local list = inst.NS.Compat.GetAvailableCombatSessions()
    assertEqual(type(list), "table")
    assertEqual(#list, 0)

    local live = T.load{}
    live.mocks.setAvailableSessions({ { sessionID = 7, name = "Ulgrax", durationSeconds = 180 } })
    assertEqual(#live.NS.Compat.GetAvailableCombatSessions(), 1)
end)

test("Compat: ResetAllCombatSessions reports whether the call was actually made", function()
    -- The boolean is not decoration: NS.Provider.Reset is the addon's sole
    -- permitted caller, and it has to tell the user whether anything happened.
    local inst = T.load{}
    assertTrue(inst.NS.Compat.ResetAllCombatSessions())
    assertEqual(inst.mocks.__meter.resets, 1)

    local bare = loadWithout("C_DamageMeter")
    assertFalse(bare.NS.Compat.ResetAllCombatSessions(),
        "with no API the call was not made, and saying `true` would be a lie to the caller")
end)

test("Compat: a half-present C_DamageMeter degrades per function", function()
    -- The PTR shape: the namespace exists, one function does not. Guarding the
    -- namespace alone would raise on the missing member.
    -- red under: `if not api then return nil end` without the member check.
    local inst = T.load{ mutate = function(m)
        m.C_DamageMeter = { IsDamageMeterAvailable = function() return true end }
    end }
    local C = inst.NS.Compat
    assertTrue((C.IsDamageMeterAvailable()))
    assertNil(C.GetCombatSessionFromType(1, 0))
    assertNil(C.GetSessionDurationSeconds(1))
    assertEqual(#C.GetAvailableCombatSessions(), 0)
    assertFalse(C.ResetAllCombatSessions())
end)

-- ── R1: the shims pass secrets through untouched ────────────────────────────

test("Compat: every meter shim survives a fully secret session", function()
    -- THE rule-R1 case for this file. Under the restriction every amount, rate,
    -- duration and display name arrives opaque; a comparison, an addition or a
    -- length operator anywhere in these shims raises here and nowhere else.
    -- red under: adding `if session.totalAmount > 0 then` to any shim.
    local inst = restrictedInstance()
    local C, m = inst.NS.Compat, inst.mocks

    local session = C.GetCombatSessionFromType(Const.SESSION_TYPE.Current,
        Const.STAT_TYPE.DamageDone)
    assertTrue(session ~= nil, "the fixture must actually be installed")
    assertTrue(m.isSimulatedSecret(session.totalAmount),
        "the session must arrive SECRET or this case proves nothing")

    local detail = C.GetCombatSessionSourceFromType(Const.SESSION_TYPE.Current,
        Const.STAT_TYPE.DamageDone, session.combatSources[1].sourceGUID)
    assertTrue(detail ~= nil and detail.combatSpells ~= nil)
    assertTrue(m.isSimulatedSecret(detail.totalAmount))

    local duration = C.GetSessionDurationSeconds(Const.SESSION_TYPE.Current)
    assertTrue(m.isSimulatedSecret(duration),
        "the duration is secret too — the header must format it, never do minutes/seconds on it")
end)

test("Compat: the join key comes back SECRET under the restriction", function()
    -- THE ASSERTION THAT USED TO SAY THE OPPOSITE, and it is why this suite was
    -- green while the addon drew an empty grid for every pull it ever ran. The
    -- addon was written believing `sourceGUID` was NeverSecret and therefore the
    -- one field legal as a table key. Blizzard annotates it SecretWhenInCombat,
    -- and in-game it arrives secret AND inaccessible — so mid-pull there is no
    -- join key, which is what modules/Aggregator.lua's identity build exists for.
    --
    -- Compat's own contract is unchanged: it is a courier and hands the value
    -- through untouched, secret or not.
    local inst = restrictedInstance()
    local session = inst.NS.Compat.GetCombatSessionFromType(Const.SESSION_TYPE.Current,
        Const.STAT_TYPE.DamageDone)
    local first = session.combatSources[1]
    assertTrue(inst.mocks.isSimulatedSecret(first.sourceGUID),
        "a fixture that hands back a plain GUID mid-pull is testing a client that does not exist")
    assertFalse(inst.mocks.isSimulatedSecret(first.classFilename),
        "classFilename IS NeverSecret — it is what colors a bar mid-pull, and what identifies a row")
end)

test("Compat: the optional source arguments are forwarded, never defaulted", function()
    -- Passing an explicit nil and passing nothing are the same thing to Lua
    -- here, so inventing a default would change WHICH source the API answers
    -- for — silently, and only for the callers that omitted it.
    local inst = T.load{}
    local m = inst.mocks
    local ST, DT = Const.SESSION_TYPE.Current, Const.STAT_TYPE.DamageDone
    m.setSourceDetail(ST, DT, "Player-1-00000001", m.buildSourceDetail{ count = 2 })
    m.setSourceDetail(ST, DT, "creature:1234", m.buildSourceDetail{ count = 5 })

    local byGUID = inst.NS.Compat.GetCombatSessionSourceFromType(ST, DT, "Player-1-00000001", nil)
    assertEqual(#byGUID.combatSpells, 2)
    local byCreature = inst.NS.Compat.GetCombatSessionSourceFromType(ST, DT, nil, 1234)
    assertEqual(#byCreature.combatSpells, 5)
end)

-- ── the numeric rule formatter ──────────────────────────────────────────────

test("Compat: CreateNumericRuleFormatter does NOT abbreviate on its own", function()
    -- THE BUG THAT COST v0.1.0 EVERY NUMBER IN THE GRID. There are three
    -- formatter types; this is the RULE one, and with no breakpoints on it it is
    -- a perfectly working formatter that renders 12400000 as "12400000". The
    -- addon called it for a release and nothing failed loudly, because nothing
    -- had failed — it was the wrong object.
    -- red under: a mock that abbreviates here, which is what hid this.
    local f = Compat.CreateNumericRuleFormatter()
    assertTrue(f ~= nil)
    assertEqual(type(f.FormatNumber), "function")
    assertEqual(f:FormatNumber(12400000), "12400000",
        "a rule formatter with no rules abbreviates nothing")
end)

test("Compat: CreateAbbreviatedNumberFormatter is the one that abbreviates", function()
    -- And it also needs breakpoints — it just has somewhere to put them.
    local f = Compat.CreateAbbreviatedNumberFormatter()
    assertTrue(f ~= nil, "the abbreviating formatter must be reachable")
    assertEqual(type(f.FormatNumber), "function")
    assertEqual(type(f.SetBreakpoints), "function",
        "modules/Format.lua puts its own ladder on this")

    f:SetBreakpoints(Compat.GetDefaultAbbreviationBreakpoints())
    assertEqual(f:FormatNumber(12400000), "12.4M")
end)

test("Compat: the client's default breakpoints are reachable as a fallback", function()
    local defaults = Compat.GetDefaultAbbreviationBreakpoints()
    assertTrue(type(defaults) == "table" and #defaults > 0,
        "the fallback under our own ladder has to exist")
end)

test("Compat: CreateNumericRuleFormatter answers nil rather than a Lua lookalike", function()
    -- A Lua fallback doing the division would be correct out of combat and a
    -- hard error in combat, which is the worst of the two possible failures.
    -- modules/Format.lua handles the nil by handing the raw value to the widget
    -- setter instead — unabbreviated, but never an error.
    -- red under: returning a hand-rolled formatter table from the missing branch.
    local inst = loadWithout("C_StringUtil")
    assertNil(inst.NS.Compat.CreateNumericRuleFormatter())
end)

test("Compat: no file in this addon divides a meter value", function()
    -- The rule the formatter exists to make keepable. Grepping for arithmetic in
    -- general would be noise, so this looks for the specific shapes: a division
    -- a `*`, `+` or `/` applied directly to a field the mock's SECRET_FIELDS list
    -- names. `-` is deliberately outside the set: the comment strip runs first,
    -- and once the operator is also the comment delimiter the two are
    -- indistinguishable.
    -- red under: `local pct = row.totalAmount / session.totalAmount`.
    local SECRET_FIELDS = { "totalAmount", "amountPerSecond", "maxAmount",
                            "overkillAmount", "deathTimeSeconds" }
    for _, rel in ipairs(T.loadedAddonFiles) do
        local fh = io.open((T.root or ".") .. "/" .. rel, "r")
        local src = fh and fh:read("*a") or ""
        if fh then fh:close() end
        -- Comments are stripped first: several files DESCRIBE the forbidden
        -- arithmetic in prose, and matching prose would make this unfixable.
        src = src:gsub("%-%-[^\r\n]*", "")
        for _, field in ipairs(SECRET_FIELDS) do
            for op in src:gmatch("%." .. field .. "%s*([%*%+/])") do
                T.fail(rel .. " applies `" .. op .. "` to ." .. field ..
                    " — arithmetic on a meter value raises in combat")
            end
        end
    end
end)
