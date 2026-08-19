-- tests/test_targets.lua — modules/Targets.lua: the enemy cross-reference, and
-- the one refusal it exists to make.
--
-- "Which enemies did this player hit" is not a question the meter answers. It is
-- reconstructed by walking the OTHER column: every EnemyDamageTaken source is one
-- enemy, its `combatSpells` are the spells that hit it, and each of those carries
-- `combatSpellDetails.unitName` — the player who cast it. So the fixtures below
-- are built enemy-first, which is backwards from every other suite here and is
-- exactly the shape the client hands over.
--
-- THE CASE THAT MATTERS is not that the sums are right. It is that when the
-- amounts may not be read, the answer is nil rather than a smaller number. A sum
-- over whichever rows happened to be readable is a Targets list that is silently
-- wrong for the whole of a pull, in the direction of "this enemy took less than
-- it did" — and a player cannot see that, where an absent section is a visible
-- absence.

local T = _G.MYTHICMETERS_TEST

local test        = T.test
local assertEqual = T.assertEqual
local assertTrue  = T.assertTrue

local CURRENT = 1
local ENEMY   = "EnemyDamageTaken"

--- One enemy's spell list, as the EnemyDamageTaken column returns it.
---
--- @param hits table  array of { caster, amount }
local function enemyDetail(hits)
    local spells = {}
    for i, hit in ipairs(hits) do
        spells[i] = {
            spellID     = 500 + i,
            totalAmount = hit.amount,
            combatSpellDetails = { unitName = hit.caster },
        }
    end
    return { combatSpells = spells, maxAmount = 0, totalAmount = 0 }
end

--- An instance whose enemy column holds `enemies`, each with its own spell list.
---
--- `enemies` is an array of { name, hits }. The enemy session and the per-enemy
--- detail are installed separately because that is how the API is shaped: the
--- column names the enemies, and a second call describes one of them.
local function bench(enemies, opts)
    opts = opts or {}
    local inst = T.load()
    local NS, mocks = inst.NS, inst.mocks

    local sources = {}
    for i, enemy in ipairs(enemies) do
        local guid = string.format("Creature-0-0000-0-0-%04d", i)
        sources[i] = {
            sourceGUID = guid, guid = guid,
            sourceCreatureID = 6000 + i,
            name = enemy.name,
            totalAmount = 1,
            sourceDisplayType = mocks.Enum.DamageMeterSourceDisplayType.Enemy,
        }
        -- Registered under BOTH keys, because both are how an enemy is reached
        -- and which one is used depends on the restriction: out of combat the
        -- GUID resolves, and mid-pull it is secret and the creatureID is all
        -- there is. A fixture keyed on the GUID alone quietly stops resolving
        -- the moment a case turns the restriction on, which is how the refusal
        -- case below came to pass for the wrong reason.
        mocks.setSourceDetail(CURRENT, mocks.Enum.DamageMeterType.EnemyDamageTaken,
            guid, enemyDetail(enemy.hits))
        mocks.setSourceDetail(CURRENT, mocks.Enum.DamageMeterType.EnemyDamageTaken,
            "creature:" .. (6000 + i), enemyDetail(enemy.hits))
    end

    mocks.setSession(CURRENT, mocks.Enum.DamageMeterType.EnemyDamageTaken, {
        combatSources = sources, maxAmount = 1, totalAmount = 1, durationSeconds = 60,
    })

    if opts.restricted then mocks.setRestricted(true) end

    local cfg = NS.Database.GetWindows()[1]
    cfg.data.sessionType = CURRENT
    return inst, cfg
end

--- The enemy names a result lists, in order.
local function names(list)
    local out = {}
    for i = 1, #list do out[i] = list[i].name end
    return out
end

-- ---------------------------------------------------------------------------
-- The join
-- ---------------------------------------------------------------------------

test("Targets: a player's enemies are recovered from the enemy column", function()
    -- The whole premise. Alpha's damage is filed under the enemies that took it,
    -- never under Alpha, so nothing here works without the cross-reference.
    -- red under: reading DamageDone's own source detail instead.
    local inst, cfg = bench{
        { name = "Gulkat",   hits = { { caster = "Alpha", amount = 500 } } },
        { name = "Illusion", hits = { { caster = "Alpha", amount = 200 } } },
    }

    local list = inst.NS.Targets.ForPlayer(cfg, "Alpha", 5)
    assertTrue(list ~= nil, "the cross-reference found nothing at all")
    assertEqual(#list, 2, "an enemy went missing from the join")
    assertEqual(list[1].name, "Gulkat", "the list is not ordered biggest-first")
    assertEqual(list[1].total, 500)
    assertEqual(list[2].total, 200)
end)

test("Targets: one enemy's several spells are summed into one line", function()
    -- An enemy is one row, not one row per spell that hit it — which is the only
    -- reason this module has to add anything at all.
    -- red under: pushing each spell as its own entry.
    local inst, cfg = bench{
        { name = "Gulkat", hits = {
            { caster = "Alpha", amount = 100 },
            { caster = "Alpha", amount = 250 },
            { caster = "Alpha", amount = 50 },
        } },
    }

    local list = inst.NS.Targets.ForPlayer(cfg, "Alpha", 5)
    assertEqual(#list, 1, "one enemy produced more than one line")
    assertEqual(list[1].total, 400, "the enemy's spells were not summed")
end)

test("Targets: another player's damage is not credited to this one", function()
    -- Every enemy's spell list mixes the whole group together, so the unitName
    -- filter is the only thing separating one player's row from another's.
    -- Getting this wrong shows every player the RAID's targets and looks right.
    -- red under: dropping the casterName comparison.
    local inst, cfg = bench{
        { name = "Gulkat", hits = {
            { caster = "Alpha", amount = 100 },
            { caster = "Beta",  amount = 900 },
        } },
    }

    local list = inst.NS.Targets.ForPlayer(cfg, "Alpha", 5)
    assertEqual(list[1].total, 100, "Beta's damage landed on Alpha's tooltip")

    local other = inst.NS.Targets.ForPlayer(cfg, "Beta", 5)
    assertEqual(other[1].total, 900, "Beta's own damage went missing")
end)

test("Targets: a player who hit nothing gets nil, not an empty list", function()
    -- One answer for "nothing to show" keeps the caller from having to tell four
    -- kinds of absence apart, none of which a tooltip can usefully say.
    -- red under: returning the empty accumulator.
    local inst, cfg = bench{
        { name = "Gulkat", hits = { { caster = "Beta", amount = 900 } } },
    }
    assertEqual(inst.NS.Targets.ForPlayer(cfg, "Alpha", 5), nil)
end)

test("Targets: the cap trims the list after ordering, not before", function()
    -- Trimming first would answer "the first three enemies the API mentioned",
    -- which is not a top three and would change from hover to hover.
    -- red under: capping the walk instead of the result.
    local inst, cfg = bench{
        { name = "Small",  hits = { { caster = "Alpha", amount = 10 } } },
        { name = "Big",    hits = { { caster = "Alpha", amount = 900 } } },
        { name = "Medium", hits = { { caster = "Alpha", amount = 400 } } },
    }

    local list = inst.NS.Targets.ForPlayer(cfg, "Alpha", 2)
    assertEqual(#list, 2, "the cap was not applied")
    assertEqual(names(list)[1], "Big")
    assertEqual(names(list)[2], "Medium", "the cap kept API order rather than the top two")
end)

test("Targets: Total adds a list up, for the share column", function()
    -- red under: a Total that walks the wrong field.
    local inst, cfg = bench{
        { name = "Gulkat",   hits = { { caster = "Alpha", amount = 500 } } },
        { name = "Illusion", hits = { { caster = "Alpha", amount = 200 } } },
    }
    local list = inst.NS.Targets.ForPlayer(cfg, "Alpha", 5)
    assertEqual(inst.NS.Targets.Total(list), 700)
end)

-- ---------------------------------------------------------------------------
-- The refusal
-- ---------------------------------------------------------------------------

test("Targets: an unreadable amount abandons the WHOLE build, not one enemy", function()
    -- THE CASE THIS MODULE EXISTS FOR. The restriction is not per-enemy, so a
    -- build that skipped the unreadable rows and carried on would return a total
    -- summed from whatever happened to be visible — a number that is wrong,
    -- plausible, and invisible to the player.
    --
    -- THE STATE HAS TO BE MIXED, and getting there takes three steps rather than
    -- one. Turning the restriction on wholesale also makes every unitName secret,
    -- and then no spell is attributable to anyone, the accumulator stays empty,
    -- and nil comes back whether the guard exists or not — a test that passes for
    -- the wrong reason and catches nothing. So: restriction on, blanket secrecy
    -- back off, and exactly ONE amount made secret by hand. The first enemy stays
    -- plainly readable, which is what makes the partial sum the tempting wrong
    -- answer: a broken build returns { Readable = 500 } and looks entirely healthy.
    -- red under: `return` instead of `ok = false; return false` in accumulateEnemy.
    local inst, cfg = bench{
        { name = "Readable",   hits = { { caster = "Alpha", amount = 500 } } },
        { name = "Restricted", hits = { { caster = "Alpha", amount = 700 } } },
    }

    local mocks = inst.mocks
    local detail = enemyDetail{ { caster = "Alpha", amount = 700 } }
    detail.combatSpells[1].totalAmount = mocks.secret(700)
    for _, key in ipairs({ "Creature-0-0000-0-0-0002", "creature:6002" }) do
        mocks.setSourceDetail(CURRENT,
            mocks.Enum.DamageMeterType.EnemyDamageTaken, key, detail)
    end

    mocks.setRestricted(true)
    mocks.setSecretValues(false)

    -- The fixture really is mixed: enemy one is readable and enemy two is not.
    -- Asserted rather than assumed, because the whole case is worthless if both
    -- enemies happen to be unreadable.
    local readable = inst.NS.Provider:GetSourceDetail(CURRENT, ENEMY, nil, 6001, nil)
    assertTrue(inst.NS.Secrets.CanAccess(readable.combatSpells[1].totalAmount),
        "the fixture made the FIRST enemy unreadable too, so it proves nothing")

    assertEqual(inst.NS.Targets.ForPlayer(cfg, "Alpha", 5), nil,
        "a restricted amount produced a partial sum instead of no answer")
end)

test("Targets: the enemy lookup drops a SECRET guid and resolves on creatureID", function()
    -- Mid-pull every meter sourceGUID is secret and inaccessible, and the GUID is
    -- the API's FIRST argument — so passing it and hoping resolves nothing and
    -- the whole section silently disappears for the entire fight. creatureID is a
    -- plain number and identifies an enemy just as well.
    -- red under: passing enemy.guid through unconditionally.
    local inst, cfg = bench{
        { name = "Gulkat", hits = { { caster = "Alpha", amount = 500 } } },
    }
    inst.mocks.setRestricted(true)
    -- Names and amounts readable; only the GUIDs are secret, which is the state
    -- this line is about.
    inst.mocks.setSecretValues(false)

    local list = inst.NS.Targets.ForPlayer(cfg, "Alpha", 5)
    assertTrue(list ~= nil, "a secret enemy GUID took the whole section down with it")
    assertEqual(list[1].total, 500)
end)

test("Targets: an unreadable caster name is skipped, and skipping it is safe", function()
    -- Distinct from the amount case on purpose. A name this context cannot read
    -- is a row that cannot be ATTRIBUTED — it belongs to nobody rather than to
    -- everybody — so dropping it costs one spell's contribution, where dropping
    -- an unreadable AMOUNT would silently shrink a number that is still shown.
    -- red under: truth-testing unitName directly, which raises on a secret.
    local inst, cfg = bench{ { name = "Gulkat", hits = {
        { caster = "Alpha", amount = 100 },
    } } }

    local mocks = inst.mocks
    local guid = string.format("Creature-0-0000-0-0-%04d", 1)
    local detail = enemyDetail{
        { caster = "Alpha", amount = 100 },
        { caster = "Alpha", amount = 900 },
    }
    detail.combatSpells[2].combatSpellDetails.unitName = mocks.secret("Alpha")
    mocks.setSourceDetail(CURRENT, mocks.Enum.DamageMeterType.EnemyDamageTaken, guid, detail)
    mocks.setRestricted(true)
    mocks.setSecretValues(false)

    local list = inst.NS.Targets.ForPlayer(cfg, "Alpha", 5)
    -- Either answer is correct here — what must NOT happen is a raise.
    if list then
        assertEqual(list[1].total, 100, "an unattributable spell was credited anyway")
    end
end)

test("Targets: an unreadable HOVERED name answers nil rather than raising", function()
    -- The hovered row's own name is ConditionalSecret too, and it is what every
    -- spell row is matched against — so there is no comparison to make.
    -- red under: comparing casterName(spell) to a secret string.
    local inst, cfg = bench{
        { name = "Gulkat", hits = { { caster = "Alpha", amount = 500 } } },
    }
    assertEqual(inst.NS.Targets.ForPlayer(cfg, inst.mocks.secret("Alpha"), 5), nil)
end)

test("Targets: no enemy column means no section, not an error", function()
    -- red under: indexing column.sources without checking it is a table.
    local inst = T.load()
    local cfg = inst.NS.Database.GetWindows()[1]
    cfg.data.sessionType = CURRENT
    assertEqual(inst.NS.Targets.ForPlayer(cfg, "Alpha", 5), nil)
end)

-- ---------------------------------------------------------------------------
-- Rule R1: this file may not talk to the meter
-- ---------------------------------------------------------------------------

test("Targets: every meter read goes through the provider", function()
    -- modules/Provider.lua is the ONLY file allowed to call C_DamageMeter, and a
    -- join like this one is exactly where the shortcut is tempting: the enemy
    -- session is two API calls away and the provider adds a layer. The check is
    -- textual because that is what the rule is about — the file, not the call.
    -- red under: a direct C_DamageMeter call anywhere in modules/Targets.lua.
    local f = assert(io.open(T.root .. "/modules/Targets.lua", "r"))
    local src = f:read("*a")
    f:close()

    for line in src:gmatch("[^\n]+") do
        if not line:match("^%s*%-%-") then
            assertTrue(not line:match("C_DamageMeter%s*%."),
                "modules/Targets.lua calls C_DamageMeter directly: " .. line)
        end
    end
end)

-- ---------------------------------------------------------------------------
-- The realm suffix
-- ---------------------------------------------------------------------------

test("Targets: a cross-realm caster still matches the row it belongs to", function()
    -- MEASURED IN GAME, not imagined. The two sides arrive in different shapes:
    -- a combat source's `name` is bare, and a spell's `combatSpellDetails.
    -- unitName` is realm-qualified for anyone from another realm. So same-realm
    -- players matched and cross-realm players silently did not — which looked
    -- like "targets work on every other row" and was really "targets work for
    -- everyone on your own realm".
    -- red under: comparing the two names as they arrive.
    local inst, cfg = bench{
        { name = "Gulkat", hits = {
            { caster = "Juanaveli-Sargeras", amount = 500 },
            { caster = "Helya",              amount = 200 },
        } },
    }

    local cross = inst.NS.Targets.ForPlayer(cfg, "Juanaveli", 5)
    assertTrue(cross ~= nil, "a cross-realm player got no targets at all")
    assertEqual(cross[1].total, 500, "the cross-realm caster's damage went missing")

    -- The same-realm case must not regress on the way.
    local same = inst.NS.Targets.ForPlayer(cfg, "Helya", 5)
    assertEqual(same[1].total, 200, "the same-realm caster stopped matching")
end)

test("Targets: a realm-qualified ROW name matches a bare caster", function()
    -- Both sides go through the same normalizer, so it does not matter which of
    -- them carried the realm — and which one does is not something this addon
    -- controls or should depend on.
    -- red under: stripping only the caster side.
    local inst, cfg = bench{
        { name = "Gulkat", hits = { { caster = "Oruuta", amount = 700 } } },
    }
    local list = inst.NS.Targets.ForPlayer(cfg, "Oruuta-Zul'jin", 5)
    assertTrue(list ~= nil, "a realm-qualified row name matched nothing")
    assertEqual(list[1].total, 700)
end)

test("Targets: two casters differing only by realm are still told apart by name", function()
    -- The cost of normalizing: two players with the same name on different
    -- realms now collide into one row. Recorded as a test rather than left to be
    -- discovered — it is the known and accepted price of matching at all, and if
    -- it ever needs fixing this is the case that says what changed.
    -- red under: nothing. This pins current behavior.
    local inst, cfg = bench{
        { name = "Gulkat", hits = {
            { caster = "Helya-RealmA", amount = 100 },
            { caster = "Helya-RealmB", amount = 300 },
        } },
    }
    local list = inst.NS.Targets.ForPlayer(cfg, "Helya", 5)
    assertEqual(list[1].total, 400, "same-name cross-realm casters are merged, as documented")
end)

-- ---------------------------------------------------------------------------
-- The cache
-- ---------------------------------------------------------------------------
--
-- The cache is the one thing here that can be wrong in a way the player cannot
-- see: a stale map shows the PREVIOUS pull's numbers under this pull's heading
-- and looks entirely correct. So these cases are about invalidation far more
-- than they are about speed.

--- How many meter reads a call made.
local function meterCalls(inst)
    local n = 0
    for _, v in pairs(inst.mocks.__meter.calls) do n = n + v end
    return n
end

test("Targets: one walk answers for every player, not just the hovered one", function()
    -- The walk visits every spell of every enemy either way. Answering for one
    -- player and discarding the rest was 100% of the work for a fifth of the
    -- result — a five-row column sweep cost five identical walks.
    -- red under: filtering to the hovered player inside accumulateEnemy.
    local inst, cfg = bench{
        { name = "Gulkat", hits = {
            { caster = "Alpha", amount = 500 },
            { caster = "Beta",  amount = 300 },
        } },
    }

    inst.mocks.resetMeterCalls()
    assertEqual(inst.NS.Targets.ForPlayer(cfg, "Alpha", 5)[1].total, 500)
    local first = meterCalls(inst)
    assertTrue(first > 0, "the first hover read nothing at all")

    -- A DIFFERENT player, off the same build.
    inst.mocks.resetMeterCalls()
    assertEqual(inst.NS.Targets.ForPlayer(cfg, "Beta", 5)[1].total, 300)
    assertEqual(meterCalls(inst), 0, "hovering a second player re-walked the whole column")
end)

test("Targets: a second hover of the same player reads nothing", function()
    -- red under: rebuilding per call.
    local inst, cfg = bench{
        { name = "Gulkat", hits = { { caster = "Alpha", amount = 500 } } },
    }
    inst.NS.Targets.ForPlayer(cfg, "Alpha", 5)
    inst.mocks.resetMeterCalls()
    inst.NS.Targets.ForPlayer(cfg, "Alpha", 5)
    assertEqual(meterCalls(inst), 0, "the cached map was not reused")
end)

test("Targets: the cap is applied to a COPY, never to the cached list", function()
    -- THE ONE THAT BITES SILENTLY. The cached list outlives the call and is
    -- handed to every later hover, so trimming it in place would make the first
    -- hover at a cap of one permanently delete every other target — for every
    -- window and every cap afterwards.
    -- red under: `for i = #list, cap + 1, -1 do list[i] = nil end` on the cached list.
    local inst, cfg = bench{
        { name = "Big",    hits = { { caster = "Alpha", amount = 900 } } },
        { name = "Medium", hits = { { caster = "Alpha", amount = 400 } } },
        { name = "Small",  hits = { { caster = "Alpha", amount = 100 } } },
    }

    assertEqual(#inst.NS.Targets.ForPlayer(cfg, "Alpha", 1), 1, "the cap was not applied")
    assertEqual(#inst.NS.Targets.ForPlayer(cfg, "Alpha", 3), 3,
        "a narrow cap on one hover truncated the cache for every hover after it")
end)

test("Targets: a refusal does not pin the section shut for the session", function()
    -- The property that matters to a player: hovering mid-pull gets nothing, and
    -- hovering again once the restriction lifts gets the real list. Worth a test
    -- even though it holds STRUCTURALLY rather than by a guard — the nil map is
    -- re-derived on the next call because the cache lookup answers nil for "no
    -- key" and for "key present, map nil" alike.
    -- red under: an early `return` on a cached nil, or a `map` sentinel that
    -- reads as present.
    local inst, cfg = bench{
        { name = "Readable",   hits = { { caster = "Alpha", amount = 500 } } },
        { name = "Restricted", hits = { { caster = "Alpha", amount = 700 } } },
    }
    local mocks = inst.mocks
    local detail = enemyDetail{ { caster = "Alpha", amount = 700 } }
    detail.combatSpells[1].totalAmount = mocks.secret(700)
    for _, key in ipairs({ "Creature-0-0000-0-0-0002", "creature:6002" }) do
        mocks.setSourceDetail(CURRENT, mocks.Enum.DamageMeterType.EnemyDamageTaken, key, detail)
    end

    mocks.setRestricted(true)
    mocks.setSecretValues(false)
    assertEqual(inst.NS.Targets.ForPlayer(cfg, "Alpha", 5), nil, "the refusal did not happen")

    -- The restriction lifts. The section must come back WITHOUT anything else
    -- having to invalidate on its behalf.
    mocks.setRestricted(false)
    for _, key in ipairs({ "Creature-0-0000-0-0-0002", "creature:6002" }) do
        mocks.setSourceDetail(CURRENT, mocks.Enum.DamageMeterType.EnemyDamageTaken, key,
            enemyDetail{ { caster = "Alpha", amount = 700 } })
    end

    local list = inst.NS.Targets.ForPlayer(cfg, "Alpha", 5)
    assertTrue(list ~= nil, "the section stayed shut after the restriction lifted")
    assertEqual(list[1].total, 700)
end)

test("Targets: a new session's numbers replace the old ones", function()
    -- THE STALENESS FAILURE THE CACHE INTRODUCES. The key is the session's
    -- IDENTITY, and for the live Current or Overall session that identity never
    -- changes while its CONTENTS do — so identity alone cannot detect this and
    -- the bus has to. Without it a map built after one fight keeps showing after
    -- the next, which looks entirely correct.
    -- red under: dropping METER_UPDATED / METER_SESSION from the subscriptions.
    local inst, cfg = bench{
        { name = "Gulkat", hits = { { caster = "Alpha", amount = 500 } } },
    }
    assertEqual(inst.NS.Targets.ForPlayer(cfg, "Alpha", 5)[1].total, 500)

    -- The next pull lands on the same session identity.
    local mocks = inst.mocks
    for _, key in ipairs({ "Creature-0-0000-0-0-0001", "creature:6001" }) do
        mocks.setSourceDetail(CURRENT, mocks.Enum.DamageMeterType.EnemyDamageTaken, key,
            enemyDetail{ { caster = "Alpha", amount = 9000 } })
    end

    inst.NS.Targets.Invalidate()
    assertEqual(inst.NS.Targets.ForPlayer(cfg, "Alpha", 5)[1].total, 9000,
        "the map outlived the numbers it was summed from")
end)

test("Targets: the invalidating messages are actually subscribed", function()
    -- Invalidate() being correct is worth nothing if nothing calls it. This
    -- asserts the wiring rather than the function.
    -- red under: dropping any RegisterMessage at the foot of the file.
    local inst, cfg = bench{
        { name = "Gulkat", hits = { { caster = "Alpha", amount = 500 } } },
    }
    local MSG = inst.NS.Constants.MSG

    for _, message in ipairs({ MSG.METER_RESET, MSG.METER_SESSION,
                               MSG.METER_UPDATED, MSG.PROFILE_CHANGED }) do
        assertEqual(inst.NS.Targets.ForPlayer(cfg, "Alpha", 5)[1].total, 500)
        inst.mocks.resetMeterCalls()
        inst.NS.SendMessage(inst.NS, message, {})
        inst.NS.Targets.ForPlayer(cfg, "Alpha", 5)
        assertTrue(meterCalls(inst) > 0,
            message .. " did not invalidate the cached map")
    end
end)

test("Targets: two sessions do not share a map", function()
    -- A player flipping between two stored segments in the header dropdown must
    -- not be shown the first one's targets under the second one's name.
    -- red under: a cache key that ignores sessionID.
    local inst, cfg = bench{
        { name = "Gulkat", hits = { { caster = "Alpha", amount = 500 } } },
    }
    assertEqual(inst.NS.Targets.ForPlayer(cfg, "Alpha", 5)[1].total, 500)

    -- Same session TYPE, a different stored segment, with different numbers.
    local mocks = inst.mocks
    local ENEMY = mocks.Enum.DamageMeterType.EnemyDamageTaken
    local guid = "Creature-0-0000-0-0-0001"
    mocks.setSession(77, ENEMY, { combatSources = {
        { sourceGUID = guid, guid = guid, sourceCreatureID = 6001,
          name = "Gulkat", totalAmount = 1 } }, maxAmount = 1, totalAmount = 1 })
    for _, key in ipairs({ guid, "creature:6001" }) do
        mocks.setSourceDetail(77, ENEMY, key, enemyDetail{ { caster = "Alpha", amount = 4242 } })
    end

    cfg.data.sessionID = 77
    assertEqual(inst.NS.Targets.ForPlayer(cfg, "Alpha", 5)[1].total, 4242,
        "a second segment was served the first segment's map")
end)
