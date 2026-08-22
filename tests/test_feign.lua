-- tests/test_feign.lua — modules/Feign.lua, the one source row this addon
-- deliberately throws away.
--
-- `C_DamageMeter` hands a Feign Death a VALID `deathRecapID`, so the Deaths
-- column counts a hunter's feign as a death and the drill-down would list one.
-- Nothing about that is visible offline: the count is correct arithmetic over
-- rows the client really sent, and the row really is there.
--
-- The filter is deliberately narrow. It joins a GUID recorded from a cast
-- against a GUID on a meter source row, and mid-pull the second of those is
-- secret — so it can only run out of combat, and the tests below pin that
-- limitation as behaviour rather than leave it to be discovered.

local T = _G.MYTHICMETERS_TEST

local test        = T.test
local assertEqual = T.assertEqual
local assertTrue  = T.assertTrue
local assertFalse = T.assertFalse

local FEIGN_DEATH = 5384
local ALPHA = "Player-1-0000000A"
local BETA  = "Player-1-0000000B"

--- A loaded instance with a two-player group whose GUIDs the aggregator uses.
local function loaded()
    local inst = T.load{ enable = true }
    inst.mocks.setGroup({
        { guid = ALPHA, name = "Alpha", class = "HUNTER", role = "DAMAGER" },
        { guid = BETA,  name = "Beta",  class = "PRIEST", role = "HEALER"  },
    })
    return inst
end

--- Fire UNIT_SPELLCAST_SUCCEEDED the way the client does.
local function cast(inst, unit, spellID)
    inst.NS:OnSpellSucceeded("UNIT_SPELLCAST_SUCCEEDED", unit, "cast-1", spellID)
end

test("Feign: the module is published and reachable", function()
    local inst = loaded()
    assertEqual(type(inst.NS.Feign), "table")
    assertEqual(type(inst.NS.Feign.IsFeigned), "function")
end)

test("Feign: a Feign Death cast marks that player", function()
    -- red under: no handler, or one that does not resolve the unit's GUID.
    local inst = loaded()
    cast(inst, "player", FEIGN_DEATH)
    assertTrue(inst.NS.Feign.IsFeigned(ALPHA))
    assertFalse(inst.NS.Feign.IsFeigned(BETA))
end)

test("Feign: any other cast marks nobody", function()
    -- The handler runs on the busiest event this addon listens to — every cast
    -- by every unit — so the non-matching path must do nothing at all.
    -- red under: recording the caster regardless of the spell.
    local inst = loaded()
    cast(inst, "player", 12345)
    assertFalse(inst.NS.Feign.IsFeigned(ALPHA))
end)

test("Feign: a SECRET spell id is not compared", function()
    -- `spellID == 5384` raises on a secret, and this handler runs on every cast
    -- in a raid. The honest answer when the comparison is refused is to record
    -- nothing, which counts the feign as a death — the behaviour that shipped
    -- before this filter existed, and the safe direction to fail in.
    -- red under: comparing before asking whether comparison is legal.
    local inst = loaded()
    inst.mocks.setSecretsAccessible(false)
    local ok = pcall(cast, inst, "player", inst.mocks.secret(FEIGN_DEATH))
    assertTrue(ok, "a secret spell id raised in the cast handler")
    assertFalse(inst.NS.Feign.IsFeigned(ALPHA))
end)

test("Feign: a SECRET guid is never used as a key", function()
    -- Indexing a table with a secret raises outright. The unit API is not a safe
    -- source — core/Secrets.lua records a follower dungeon handing out secret
    -- pet GUIDs — so both the write and the read are gated.
    -- red under: `set[guid] = true` with no IsSafeKey.
    local inst = loaded()
    local secretGUID = inst.mocks.secret(ALPHA)
    inst.mocks.setUnit("player", { guid = secretGUID, name = "Alpha", class = "HUNTER" })
    inst.mocks.setSecretsAccessible(false)

    local ok = pcall(cast, inst, "player", FEIGN_DEATH)
    assertTrue(ok, "a secret guid raised in the cast handler")
    assertFalse(inst.NS.Feign.IsFeigned(secretGUID),
        "asking about a secret guid must answer no, not raise")
end)

test("Feign: a feigner confirmed at 0 HP stops being feigned", function()
    -- A hunter who feigns and then really dies must have that death counted.
    -- UnitIsFeignDeath is not used for this: it can stay true through the
    -- transition, which would hide the real death behind the fake one.
    -- red under: never clearing, or clearing on any health change.
    local inst = loaded()
    cast(inst, "player", FEIGN_DEATH)
    assertTrue(inst.NS.Feign.IsFeigned(ALPHA))

    inst.mocks.setUnitHealth("player", 0)
    inst.NS.Feign.Prune()
    assertFalse(inst.NS.Feign.IsFeigned(ALPHA), "the real death after a feign was hidden")
end)

test("Feign: a feigner still alive stays feigned", function()
    -- The belt on the case above. Pruning on anything short of a confirmed zero
    -- would let the feign back into the count.
    local inst = loaded()
    cast(inst, "player", FEIGN_DEATH)
    inst.mocks.setUnitHealth("player", 1)
    inst.NS.Feign.Prune()
    assertTrue(inst.NS.Feign.IsFeigned(ALPHA))
end)

test("Feign: somebody who left the group is forgotten", function()
    -- Untrackable: there is no unit token to read health from any more, so the
    -- entry could never be cleared and would sit there for the session.
    local inst = loaded()
    cast(inst, "player", FEIGN_DEATH)
    inst.mocks.setGroup({ { guid = BETA, name = "Beta", class = "PRIEST" } })
    inst.NS.Roster.Forget()
    inst.NS.Feign.Prune()
    assertFalse(inst.NS.Feign.IsFeigned(ALPHA))
end)

test("Feign: a meter reset forgets everything", function()
    local inst = loaded()
    cast(inst, "player", FEIGN_DEATH)
    inst.NS:SendMessage(inst.NS.Constants.MSG.METER_RESET)
    assertFalse(inst.NS.Feign.IsFeigned(ALPHA))
end)

test("Feign: pruning an empty set costs nothing", function()
    -- It is called once per refresh pass from the Deaths walk, four times a
    -- second, on a run where nobody has ever feigned.
    -- red under: enumerating the group before checking the set is empty.
    local inst = loaded()
    inst.mocks.setGroup(nil)
    local ok = pcall(inst.NS.Feign.Prune)
    assertTrue(ok)
end)
