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

test("Feign: a feigner still down stays feigned", function()
    -- The belt on the case above. A feign keeps the player's real health, so
    -- health alone cannot end one — it takes a confirmed zero (they died) or
    -- UnitIsFeignDeath going false on a living unit (they stood up).
    --
    -- This case used to read "still ALIVE stays feigned", which was true only
    -- while nothing could detect a feign ending; that gap is what let a stale
    -- entry eat every real death a hunter had for the rest of a run.
    local inst = loaded()
    cast(inst, "player", FEIGN_DEATH)
    inst.mocks.setUnitHealth("player", 1)
    inst.mocks.setUnitFeignDeath("player", true)
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

-- ---------------------------------------------------------------------------
-- A feign is a fact about ONE DEATH, not a flag on a player (found by review)
-- ---------------------------------------------------------------------------
--
-- The set began life as a live predicate — "is this GUID feigning right now" —
-- asked of a HISTORICAL list of source rows, and that is wrong in both
-- directions. Clear the entry and every death it was hiding comes back; leave it
-- standing and every real death the player has is eaten. The fix is to mark the
-- individual deaths, and to notice when a feign has ended.

test("Feign: a death judged fake STAYS fake after the player really dies", function()
    -- red under: filtering on the live set alone. The hunter feigns twice, is
    -- correctly filtered, then really dies — and the two feigns reappear in the
    -- count and never leave.
    local inst = loaded()
    cast(inst, "player", FEIGN_DEATH)
    assertTrue(inst.NS.Feign.ShouldDropDeath(ALPHA, 11))
    assertTrue(inst.NS.Feign.ShouldDropDeath(ALPHA, 10))

    -- They really die: the entry clears.
    inst.mocks.setUnitHealth("player", 0)
    inst.NS.Feign.Prune()
    assertFalse(inst.NS.Feign.IsFeigned(ALPHA))

    assertTrue(inst.NS.Feign.ShouldDropDeath(ALPHA, 11), "an earlier feign came back")
    assertTrue(inst.NS.Feign.ShouldDropDeath(ALPHA, 10), "an earlier feign came back")
    assertFalse(inst.NS.Feign.ShouldDropDeath(ALPHA, 20), "the real death was eaten")
end)

test("Feign: standing back up ends the feign, so the next death is real", function()
    -- THE OTHER DIRECTION, and the one that loses data. Nothing cleared a feign
    -- when the feign simply ENDED, so a hunter who feigned in pull one and died
    -- for real in pull three had that death filtered out for the rest of the
    -- run — unless some pass happened to catch them at exactly 0 HP.
    --
    -- UnitIsFeignDeath is safe to read in THIS direction: it can linger true
    -- through a feign-then-die transition, which is why it cannot be trusted to
    -- clear one, but a FALSE reading on a living unit means they are up.
    -- red under: Prune having only the 0-HP and left-the-group exits.
    local inst = loaded()
    cast(inst, "player", FEIGN_DEATH)
    inst.mocks.setUnitFeignDeath("player", true)
    inst.NS.Feign.Prune()
    assertTrue(inst.NS.Feign.IsFeigned(ALPHA), "still down, still feigning")

    inst.mocks.setUnitFeignDeath("player", false)
    inst.mocks.setUnitHealth("player", 500)
    inst.NS.Feign.Prune()
    assertFalse(inst.NS.Feign.IsFeigned(ALPHA), "they stood up; the feign is over")
    assertFalse(inst.NS.Feign.ShouldDropDeath(ALPHA, 20),
        "a death after standing up is a real one")
end)

test("Feign: a client with no UnitIsFeignDeath keeps the old behaviour", function()
    -- The API is read through _G at call time and may be absent. Missing must
    -- mean "cannot tell", which leaves the entry standing — the pre-existing
    -- behaviour, not a silent clear that would let feigns through.
    local inst = loaded()
    cast(inst, "player", FEIGN_DEATH)
    inst.mocks.setUnitFeignDeath("player", true)
    inst.mocks.setUnitHealth("player", 500)
    inst.NS.Feign.Prune()

    inst.mocks.UnitIsFeignDeath = nil
    inst.NS.Feign.Prune()
    assertTrue(inst.NS.Feign.IsFeigned(ALPHA))
end)

test("Feign: a reset forgets the fake deaths too", function()
    -- Recap ids are session-scoped counters, so id 11 after a reset is somebody
    -- else's death entirely. A surviving mark would hide a real one.
    local inst = loaded()
    cast(inst, "player", FEIGN_DEATH)
    assertTrue(inst.NS.Feign.ShouldDropDeath(ALPHA, 11))
    inst.NS:SendMessage(inst.NS.Constants.MSG.METER_RESET)
    assertFalse(inst.NS.Feign.ShouldDropDeath(ALPHA, 11))
end)

test("Feign: ShouldDropDeath answers no for anything it cannot key on", function()
    -- A secret recap id, an absent one, a secret guid. "Cannot tell" must mean
    -- "not a feign", because the alternative is dropping a real death.
    local inst = loaded()
    cast(inst, "player", FEIGN_DEATH)
    inst.mocks.setSecretsAccessible(false)
    assertFalse(inst.NS.Feign.ShouldDropDeath(inst.mocks.secret(ALPHA), 11))
    assertTrue(inst.NS.Feign.ShouldDropDeath(ALPHA, inst.mocks.secret(11)) ~= nil,
        "a secret id must answer, not raise")
end)
