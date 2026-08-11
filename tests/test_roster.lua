-- tests/test_roster.lua — modules/Roster.lua: who is in the group, and whose
-- pet that is.
--
-- Nothing in this module touches a meter value, which is exactly why it matters:
-- it is the source of every fact the grid can still be sure of mid-pull. The
-- cases below therefore care about two things — that the map is built from the
-- unit API in the right ORDER, and that pet attribution is honest about what it
-- cannot know.

local T = _G.MYTHICMETERS_TEST

local test        = T.test
local assertEqual = T.assertEqual
local assertTrue  = T.assertTrue
local assertFalse = T.assertFalse
local assertNil   = T.assertNil

local PARTY = {
    { guid = "Player-1-0000000A", name = "Tankadin", class = "PALADIN", role = "TANK"    },
    { guid = "Player-1-0000000B", name = "Healbot",  class = "PRIEST",  role = "HEALER"  },
    { guid = "Player-1-0000000C", name = "Stabby",   class = "ROGUE",   role = "DAMAGER" },
}

--- A fresh instance whose group is `spec`. The roster cache is cold, so the
--- first read of every case builds it.
local function grouped(spec, opts)
    local inst = T.load()
    inst.mocks.setGroup(spec, opts)
    inst.NS.Roster.Refresh()
    return inst
end

-- ---------------------------------------------------------------------------
-- The group array
-- ---------------------------------------------------------------------------

test("Roster.GetGroup is player-first, then party order", function()
    local inst = grouped(PARTY)
    local group = inst.NS.Roster.GetGroup()

    assertEqual(#group, 3)
    -- Player-first is not cosmetic: `roster` sort mode uses this order verbatim,
    -- and a player wants to find themselves at a fixed place in the list.
    assertEqual(group[1].unit, "player")
    assertEqual(group[1].isPlayer, true)
    assertEqual(group[1].guid, "Player-1-0000000A")
    assertEqual(group[2].unit, "party1")
    assertEqual(group[2].isPlayer, false)
    assertEqual(group[3].unit, "party2")
end)

test("Roster.GetGroup carries name, class and role off the unit API", function()
    local entry = grouped(PARTY).NS.Roster.GetGroup()[2]
    assertEqual(entry.name, "Healbot")
    assertEqual(entry.classFilename, "PRIEST")
    assertEqual(entry.role, "HEALER")
end)

test("Roster de-duplicates the player, who is both `player` and `raidN`", function()
    local inst = grouped(PARTY, { raid = true })
    local group = inst.NS.Roster.GetGroup()

    -- In a raid the walk visits "player" and then raid1..N, and raid1 IS the
    -- player. The duplicate is filtered by GUID rather than by working out which
    -- raid index we are, which changes on every regroup.
    assertEqual(#group, 3, "the player must appear exactly once")
    assertEqual(group[1].unit, "player", "and the `player` entry is the one that wins")
    local seen = {}
    for _, member in ipairs(group) do
        assertNil(seen[member.guid], "duplicate GUID " .. tostring(member.guid))
        seen[member.guid] = true
    end
end)

test("Roster answers a one-entry group when solo", function()
    local inst = T.load()
    inst.mocks.setSolo("Player-1-00000001", "Loner", "MAGE")
    inst.NS.Roster.Refresh()

    -- Solo still yields { player } rather than {}, so every consumer has a
    -- one-entry roster instead of an empty-case branch.
    local group = inst.NS.Roster.GetGroup()
    assertEqual(#group, 1)
    assertEqual(group[1].name, "Loner")
    assertEqual(group[1].isPlayer, true)
end)

test("Roster skips a unit the API cannot see", function()
    local inst = T.load()
    inst.mocks.setGroup(PARTY)
    -- party2 exists as far as GetNumGroupMembers is concerned but the unit is
    -- out of range: UnitExists answers false and the member is left out rather
    -- than entered with a nil GUID.
    inst.mocks.setUnit("party2", nil)
    inst.NS.Roster.Refresh()

    local group = inst.NS.Roster.GetGroup()
    assertEqual(#group, 2)
    assertEqual(inst.NS.Roster.IsGroupMember("Player-1-0000000C"), false)
end)

-- ---------------------------------------------------------------------------
-- Lookups
-- ---------------------------------------------------------------------------

test("Roster.IsGroupMember is a plain GUID lookup, legal at any point in a pull", function()
    local inst = grouped(PARTY)
    inst.mocks.setRestricted(true)

    local R = inst.NS.Roster
    assertEqual(R.IsGroupMember("Player-1-0000000B"), true)
    assertEqual(R.IsGroupMember("Creature-0-1234"), false)
    assertEqual(R.IsGroupMember(nil), false, "nil is not a member and is not an error")
end)

test("Roster.Get answers the entry, and nil for a stranger", function()
    local R = grouped(PARTY).NS.Roster
    assertEqual(R.Get("Player-1-0000000C").name, "Stabby")
    assertNil(R.Get("Player-1-0000FFFF"))
    assertNil(R.Get(nil))
end)

test("Roster.RoleOf answers NONE rather than nil for a non-member", function()
    local R = grouped(PARTY).NS.Roster
    assertEqual(R.RoleOf("Player-1-0000000A"), "TANK")
    -- A row icon has one code path; a caller that needs "not in the group" asks
    -- IsGroupMember, which is the question it actually means.
    assertEqual(R.RoleOf("Creature-0-999"), "NONE")
end)

test("Roster normalizes an unrecognized role to NONE", function()
    local inst = T.load()
    inst.mocks.setGroup{ { guid = "Player-1-00000001", name = "Nobody",
                           class = "MAGE", role = "SOMETHINGNEW" } }
    inst.NS.Roster.Refresh()
    assertEqual(inst.NS.Roster.GetGroup()[1].role, "NONE")
end)

-- ---------------------------------------------------------------------------
-- Pet attribution — best effort, and it says so
-- ---------------------------------------------------------------------------

test("Roster.OwnerOf maps a unit-frame pet to its owner", function()
    local inst = T.load()
    inst.mocks.setGroup(PARTY)
    inst.mocks.setPet("player", "Pet-0-1111")
    inst.mocks.setPet("party2", "Pet-0-3333")
    inst.NS.Roster.Refresh()

    local R = inst.NS.Roster
    assertEqual(R.OwnerOf("Pet-0-1111"), "Player-1-0000000A")
    assertEqual(R.OwnerOf("Pet-0-3333"), "Player-1-0000000C",
        "the pet token is derived from the owner's unit token, so it cannot mismatch")
end)

test("Roster.OwnerOf answers nil for anything that is not a unit-frame pet", function()
    local inst = T.load()
    inst.mocks.setGroup(PARTY)
    inst.mocks.setPet("player", "Pet-0-1111")
    inst.NS.Roster.Refresh()

    -- Guardians, totems, temporary summons, a second pet, and a pet belonging to
    -- a member out of range all land here. nil means "this addon cannot prove
    -- whose this is", and the aggregator's contract is to DROP the row.
    assertNil(inst.NS.Roster.OwnerOf("Creature-0-2222"))
    assertNil(inst.NS.Roster.OwnerOf(nil))
end)

test("Roster never keys the map on a secret GUID", function()
    -- FROM A LIVE FOLLOWER DUNGEON: UnitGUID("party3pet") answered a SECRET
    -- string, and `pets[petGuid] = guid` raised "attempted to perform indexed
    -- assignment on a table that cannot be indexed with secret keys" on every
    -- refresh. The addon's design note said a GUID is never secret; it is not
    -- true of the unit API, only of the meter's own sourceGUID.
    --
    -- The harness cannot trap a secret used as a key (tests/wow_mock.lua says so
    -- outright — it is legal Lua), so the assertion is on the map itself: no key
    -- in it may be a secret. That is the invariant the client enforces for us.
    local inst = T.load()
    inst.mocks.setGroup(PARTY)
    inst.mocks.setPet("party1", "Pet-0-2222")
    local secretPet = inst.mocks.secret("Pet-0-SECRET")
    inst.mocks.setPet("party2", secretPet)
    inst.NS.Roster.Refresh()

    local R = inst.NS.Roster
    assertEqual(#R.GetGroup(), 3, "an unreadable pet must not cost us its owner")

    for key in pairs(inst.NS.State.Cache("Roster").pets) do
        assertFalse(inst.mocks.isSimulatedSecret(key),
            "a secret GUID reached the pet map as a KEY")
    end
    for key in pairs(inst.NS.State.Cache("Roster").byGuid) do
        assertFalse(inst.mocks.isSimulatedSecret(key),
            "a secret GUID reached the member index as a KEY")
    end

    assertEqual(R.OwnerOf("Pet-0-2222"), "Player-1-0000000B",
        "the readable pet is still attributed")
    assertNil(R.OwnerOf(secretPet),
        "and an unreadable one is unattributable, which the aggregator drops")
    assertFalse(R.IsGroupMember(secretPet), "lookups refuse a secret rather than raising")
    assertNil(R.Get(secretPet))
end)

test("Roster does not attribute a pet to a member it skipped", function()
    local inst = T.load()
    inst.mocks.setGroup(PARTY)
    inst.mocks.setPet("party1", "Pet-0-2222")
    inst.mocks.setUnit("party1", nil)   -- the owner went out of range
    inst.NS.Roster.Refresh()

    assertNil(inst.NS.Roster.OwnerOf("Pet-0-2222"),
        "a pet whose owner was not enumerated is unattributable, not misattributed")
end)

-- ---------------------------------------------------------------------------
-- Caching and invalidation
-- ---------------------------------------------------------------------------

test("Roster builds lazily and holds the map until it is invalidated", function()
    local inst = grouped(PARTY)
    local R = inst.NS.Roster

    assertEqual(#R.GetGroup(), 3)

    -- A raid regroup can fire GROUP_ROSTER_UPDATE a dozen times a second while
    -- nothing is on screen. Until something says the map is stale, the cached
    -- one is what every reader gets.
    inst.mocks.setSolo("Player-1-0000000A", "Tankadin", "PALADIN")
    assertEqual(#R.GetGroup(), 3, "the map is cached, not recomputed per read")

    R.Refresh()
    assertEqual(#R.GetGroup(), 1, "and the next read after an invalidation rebuilds it")
end)

test("Roster.Refresh drops the cache without rebuilding it eagerly", function()
    local inst = grouped(PARTY)
    local NS = inst.NS

    NS.Roster.GetGroup()
    local cache = NS.State.Cache("Roster")
    assertTrue(cache.group ~= nil, "the build populated the shared cache")

    NS.Roster.Refresh()
    assertNil(cache.group, "Refresh drops it")
    assertNil(cache.byGuid)
    assertNil(cache.pets)
end)

test("Roster shares core/State.lua's cache seam rather than owning a private one", function()
    local inst = grouped(PARTY)
    local NS = inst.NS

    NS.Roster.GetGroup()
    -- One invalidation seam for the roster map, the formatter instances and the
    -- frozen sort orders. A wipe-all must reach this module.
    NS.State.WipeCache()
    assertNil(NS.State.Cache("Roster").group)
    assertEqual(#NS.Roster.GetGroup(), 3, "and the next read rebuilds cleanly")
end)

test("Entering or leaving test mode invalidates the map", function()
    -- THE EMPTY TEST GRID. Test mode substitutes BOTH data sources — the meter
    -- in modules/Provider.lua and the unit API in this file's build() — but the
    -- substitution here only takes effect on a BUILD, and the live client always
    -- has a warm map by the time anybody types `/mm test`. So the invented
    -- sources were joined against the REAL group, every one of them was dropped
    -- as "not in your group", and the window drew nothing at all — with no
    -- notice, because preview suppresses it.
    --
    -- Leaving test mode is the same bug pointing the other way: the mocked group
    -- stayed cached and every real source was dropped until the next regroup.
    -- red under: no TEST_MODE_CHANGED subscription.
    local inst = grouped(PARTY)
    local NS = inst.NS
    NS.Roster:OnEnable()

    assertEqual(#NS.Roster.GetGroup(), 3, "the map is warm before test mode is touched")

    NS.State.SetTestMode(true)
    local group = NS.Roster.GetGroup()
    assertEqual(#group, #NS.Aggregator.TestGroup(),
        "test mode must be joined against the mocked group, or every row is dropped")
    assertTrue(NS.Roster.IsGroupMember(group[1].guid))

    NS.State.SetTestMode(false)
    assertEqual(#NS.Roster.GetGroup(), 3, "and the real group comes straight back")
end)

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

test("Roster subscribes to the roster message; it never sends one", function()
    local inst = grouped(PARTY)
    local NS, mocks = inst.NS, inst.mocks
    local MSG = NS.Constants.MSG

    NS.Roster:OnEnable()
    for _, message in ipairs{ MSG.ROSTER_CHANGED, MSG.ENTERING_WORLD, MSG.PROFILE_CHANGED,
                              MSG.TEST_MODE_CHANGED } do
        assertTrue((mocks.__busRegistry[message] or {})[NS.Roster] ~= nil,
            "Roster must listen on " .. message)
    end

    NS.Roster.GetGroup()
    inst.mocks.setSolo("Player-1-0000000A", "Tankadin", "PALADIN")
    NS:SendMessage(MSG.ROSTER_CHANGED)
    assertEqual(#NS.Roster.GetGroup(), 1, "the message invalidates the map")
end)

test("modules/Roster.lua registers no game event of its own", function()
    -- core/MythicMeters.lua is the addon's single game-event listener
    -- (architecture-§4). A second GROUP_ROSTER_UPDATE registration here would be
    -- a second source of truth for one transition.
    local fh = assert(io.open(T.root .. "/modules/Roster.lua", "r"))
    local n = 0
    for line in fh:lines() do
        n = n + 1
        if not line:match("^%s*%-%-") then
            local code = line:gsub("%s%-%-.*$", "")
            assertFalse(code:find("RegisterEvent", 1, true) ~= nil,
                "modules/Roster.lua:" .. n .. " registers a game event")
        end
    end
    fh:close()
end)

test("A partial build is NOT cached, so the next read retries", function()
    -- THE EMPTY WINDOW. The roster is invalidated on GROUP_ROSTER_UPDATE and
    -- PLAYER_ENTERING_WORLD, and both fire before the unit API has populated. The
    -- next read built a map with almost nobody in it, cached that, and nothing
    -- invalidated it again — so for an entire boss fight every source the meter
    -- reported was dropped as "not in your group". The live debug log showed
    -- `rows=0 dropped=10` for forty seconds, then one build after combat and
    -- `rows=5` immediately.
    -- red under: caching unconditionally at the end of build().
    local inst = T.load()
    inst.mocks.setGroup(PARTY)
    -- The API knows there are three; only one unit token has resolved yet.
    inst.mocks.setUnit("party1", nil)
    inst.mocks.setUnit("party2", nil)
    inst.NS.Roster.Refresh()

    assertEqual(#inst.NS.Roster.GetGroup(), 1, "it renders with what there is")
    assertTrue(inst.NS.State.Cache("Roster").partial,
        "but it must know the map is short, so the next read rebuilds")

    -- The units arrive; the very next read is correct, with no event needed.
    inst.mocks.setGroup(PARTY)
    assertEqual(#inst.NS.Roster.GetGroup(), 3, "and self-corrects on the next refresh")
end)

test("A complete build IS cached", function()
    local inst = T.load()
    inst.mocks.setGroup(PARTY)
    inst.NS.Roster.Refresh()

    assertEqual(#inst.NS.Roster.GetGroup(), 3)
    assertTrue(inst.NS.State.Cache("Roster").group ~= nil)
    assertNil(inst.NS.State.Cache("Roster").partial,
        "a full map must not be rebuilt on every read")
end)

test("Solo is complete, not partial", function()
    -- GetNumGroupMembers answers 0 when solo, and one member is the whole group.
    local inst = T.load()
    inst.mocks.setSolo("Player-1-00000001", "Loner", "MAGE")
    inst.NS.Roster.Refresh()

    assertEqual(#inst.NS.Roster.GetGroup(), 1)
    assertNil(inst.NS.State.Cache("Roster").partial,
        "a solo roster must cache, or it rebuilds four times a second forever")
end)
