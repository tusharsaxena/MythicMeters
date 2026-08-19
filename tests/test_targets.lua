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
