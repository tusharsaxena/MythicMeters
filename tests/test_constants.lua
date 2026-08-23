-- tests/test_constants.lua — integrity of core/Constants.lua.
--
-- The file carries no logic, so nothing here asserts behavior. What it asserts
-- is that the tables are INTERNALLY CONSISTENT and that the two DERIVED tables —
-- STAT_BY_KEY and DEFAULT_STAT_KEYS — still say what the array they are built
-- from says. A derived table is exactly where a silent drift lives: both are
-- built by a loop at load, so a duplicate `key` in STATS makes STAT_BY_KEY quietly
-- one entry short and nothing raises.
--
-- The enum cases matter more than they look. Every value in STAT_TYPE /
-- SESSION_TYPE / SOURCE_DISPLAY_TYPE is read through a guarded `enumValue()`
-- helper with a hardcoded numeric fallback, and the fallback path is the ONLY
-- path on a client that predates C_DamageMeter. A wrong literal there is a
-- provider that reads the wrong column and shows plausible numbers in the wrong
-- place, which is worse than an error. So the fallbacks are loaded with `Enum`
-- deliberately removed and compared against the live values.

local T = _G.MULTIMETERS_TEST
local NS = T.NS
local test, assertEqual, assertTrue, assertNil =
    T.test, T.assertEqual, T.assertTrue, T.assertNil

local Const = NS.Constants

-- ── identity ────────────────────────────────────────────────────────────────

test("Constants: NS.Const and NS.Constants are the same table", function()
    -- Two names, one table. A copy would let a value added under one name be
    -- invisible under the other, and the collection's files use both spellings.
    assertTrue(NS.Const == NS.Constants, "NS.Const must alias NS.Constants, not copy it")
end)

test("Constants: the chat prefix is the cyan [MM] tag and closes its color code", function()
    assertEqual(NS.PREFIX, "|cff00ffff[MM]|r")
end)

test("Constants: the notice gray is a bare color opener with no closer", function()
    -- Callers wrap the message BODY and add their own `|r`; a closer here would
    -- make every notice line double-terminated and the tag would lose its cyan.
    assertTrue(NS.GRAY:match("^|cff%x%x%x%x%x%x$") ~= nil,
        "GRAY must be a bare color opener, got " .. tostring(NS.GRAY))
end)

-- ── shipped media ───────────────────────────────────────────────────────────

test("Constants: the monospace font comes from the LibKa0s payload", function()
    -- The face moved into the library at LibKa0s v1.9.0 so that every Ka0s addon
    -- prints its numbers in one face rather than in one copy of it each. The path
    -- is still absolute from this addon's own folder, because a vendored library
    -- lives inside it.
    -- red under: a path into this addon's own media/fonts/, which no longer exists.
    assertTrue(Const.FONT_MONO:find("Interface\\AddOns\\MultiMeters\\libs\\LibKa0s\\media\\fonts\\",
        1, true) == 1,
        "FONT_MONO must come from the vendored payload: " .. tostring(Const.FONT_MONO))
    assertTrue(Const.FONT_MONO:lower():match("%.ttf$") ~= nil, "FONT_MONO must name a TTF")
end)

test("Constants: the font it names exists in the vendored payload", function()
    -- A default that names a font the package does not carry renders as
    -- Blizzard's fallback face, silently — the exact thing shipping a monospace
    -- font was meant to avoid. It is now the LIBRARY's job to ship the bytes and
    -- this addon's job to carry the vendored copy, so the file has to be there.
    local rel = Const.FONT_MONO:gsub("\\", "/"):gsub("^Interface/AddOns/MultiMeters/", "")
    local fh = io.open((T.root or ".") .. "/" .. rel, "rb")
    assertTrue(fh ~= nil, "the vendored font is missing from the repo: " .. rel)
    if fh then fh:close() end
end)

test("Constants: the LSM font key is a name, not the path", function()
    -- A profile stores the NAME, which is what makes a font choice portable
    -- between installs. Storing a path would pin the profile to this addon's
    -- folder layout.
    assertTrue(Const.FONT_MONO_NAME:find("\\", 1, true) == nil,
        "FONT_MONO_NAME must not be a path")
    assertTrue(#Const.FONT_MONO_NAME > 0, "FONT_MONO_NAME must not be empty")
end)

-- ── the stat catalog ────────────────────────────────────────────────────────

test("Constants: every STATS row is fully populated and correctly typed", function()
    assertTrue(#Const.STATS > 0, "the stat catalog is empty")
    for i, stat in ipairs(Const.STATS) do
        local at = "STATS[" .. i .. "]"
        assertEqual(type(stat.key), "string", at .. ".key")
        assertEqual(type(stat.enumValue), "number", at .. ".enumValue")
        assertEqual(type(stat.label), "string", at .. ".label")
        assertEqual(type(stat.shortLabel), "string", at .. ".shortLabel")
        assertEqual(type(stat.isRate), "boolean", at .. ".isRate")
        assertEqual(type(stat.defaultWidth), "number", at .. ".defaultWidth")
        assertEqual(type(stat.defaultEnabled), "boolean", at .. ".defaultEnabled")
        assertTrue(stat.defaultWidth > 0, at .. ".defaultWidth must be positive")
    end
end)

test("Constants: no two STATS rows share a key or an enum value", function()
    -- A duplicate key makes STAT_BY_KEY silently one entry short; a duplicate
    -- enum value makes two columns read the same C_DamageMeter statistic while
    -- claiming to be different stats.
    local byKey, byEnum = {}, {}
    for _, stat in ipairs(Const.STATS) do
        assertNil(byKey[stat.key], "duplicate stat key: " .. stat.key)
        byKey[stat.key] = true
        assertNil(byEnum[stat.enumValue],
            "duplicate enum value " .. stat.enumValue .. " on " .. stat.key)
        byEnum[stat.enumValue] = true
    end
end)

test("Constants: STAT_BY_KEY holds exactly the catalog, by identity", function()
    -- Identity rather than equality: the lookup must point AT the catalog rows,
    -- so a field added to a row is visible through both.
    local n = 0
    for key, stat in pairs(Const.STAT_BY_KEY) do
        n = n + 1
        assertEqual(stat.key, key, "STAT_BY_KEY key does not match its row")
    end
    assertEqual(n, #Const.STATS, "STAT_BY_KEY and STATS disagree about how many stats exist")
    for _, stat in ipairs(Const.STATS) do
        assertTrue(Const.STAT_BY_KEY[stat.key] == stat,
            stat.key .. " is not the same table in STAT_BY_KEY as in STATS")
    end
end)

test("Constants: each stat key is the name of the enum value it carries", function()
    -- Stated as a rule in the file's header and worth pinning: a reader holding
    -- Blizzard's documentation maps a catalog row to an API value with no lookup
    -- table, and `/mm` accepts the same spelling.
    for _, stat in ipairs(Const.STATS) do
        assertEqual(Const.STAT_TYPE[stat.key], stat.enumValue,
            stat.key .. " does not carry STAT_TYPE." .. stat.key)
    end
end)

test("Constants: DEFAULT_STAT_KEYS is derived from defaultEnabled, in catalog order", function()
    -- Both halves matter. Membership is what a new window ships with; ORDER is
    -- the left-to-right column layout the design fixes (Damage · Healing ·
    -- Interrupts · Dispels · Avoidable Damage · Deaths).
    local expected = {}
    for _, stat in ipairs(Const.STATS) do
        if stat.defaultEnabled then expected[#expected + 1] = stat.key end
    end
    assertTrue(#expected > 0, "no stat ships enabled — a new window would have no columns")
    assertEqual(table.concat(Const.DEFAULT_STAT_KEYS, ","), table.concat(expected, ","),
        "DEFAULT_STAT_KEYS has drifted from the catalog's defaultEnabled flags")
end)

test("Constants: the six default columns are the design's six", function()
    -- red under: flipping any defaultEnabled flag in the catalog. Named
    -- explicitly rather than derived, because "derived from the same table"
    -- would make the previous case and this one one case.
    assertEqual(table.concat(Const.DEFAULT_STAT_KEYS, ","),
        "DamageDone,HealingDone,Interrupts,Dispels,AvoidableDamageTaken,Deaths")
end)

test("Constants: only the two rate stats carry isRate", function()
    -- Counting stats do ship an amountPerSecond field, but "0.42 interrupts per
    -- second" is noise, and this flag is what the text assembler reads to decide
    -- whether the right-hand slot has anything to say.
    local rates = {}
    for _, stat in ipairs(Const.STATS) do
        if stat.isRate then rates[#rates + 1] = stat.key end
    end
    assertEqual(table.concat(rates, ","), "DamageDone,HealingDone")
end)

test("Constants: every stat label and short label has an enUS entry", function()
    -- The locale's __index answers the key on a miss, so a missing translation
    -- never errors — it renders the key, which for a short label is
    -- indistinguishable from a correct render. Compare the RAW table instead.
    local raw = {}
    local src = assert(io.open((T.root or ".") .. "/locales/enUS.lua", "r"))
    local body = src:read("*a")
    src:close()
    for key in body:gmatch('L%["([^"]+)"%]%s*=') do raw[key] = true end
    for _, stat in ipairs(Const.STATS) do
        assertTrue(raw[stat.label], "locales/enUS.lua has no entry for label " .. stat.label)
        assertTrue(raw[stat.shortLabel],
            "locales/enUS.lua has no entry for short label " .. stat.shortLabel)
    end
end)

-- ── the enums and their fallbacks ───────────────────────────────────────────

test("Constants: the resolved enums match the client's when it has them", function()
    local E = T.mocks.Enum
    for key, value in pairs(Const.STAT_TYPE) do
        assertEqual(value, E.DamageMeterType[key], "STAT_TYPE." .. key)
    end
    for key, value in pairs(Const.SESSION_TYPE) do
        assertEqual(value, E.DamageMeterSessionType[key], "SESSION_TYPE." .. key)
    end
    for key, value in pairs(Const.SOURCE_DISPLAY_TYPE) do
        assertEqual(value, E.DamageMeterSourceDisplayType[key], "SOURCE_DISPLAY_TYPE." .. key)
    end
end)

test("Constants: the hardcoded fallbacks equal the live enum values", function()
    -- THE case. On a client without C_DamageMeter the literals in
    -- core/Constants.lua are the only values there are, and a wrong one reads
    -- the wrong column and renders plausible numbers in the wrong place. The
    -- enum has to be gone BEFORE the file loads — it is resolved at load — which
    -- is what `mutate` is for.
    -- red under: changing any literal in core/Constants.lua's enumValue() calls.
    local bare = T.load{ mutate = function(mocks) mocks.Enum = nil end }
    local C2 = bare.NS.Constants
    for key, value in pairs(Const.STAT_TYPE) do
        assertEqual(C2.STAT_TYPE[key], value, "STAT_TYPE." .. key .. " fallback")
    end
    for key, value in pairs(Const.SESSION_TYPE) do
        assertEqual(C2.SESSION_TYPE[key], value, "SESSION_TYPE." .. key .. " fallback")
    end
    for key, value in pairs(Const.SOURCE_DISPLAY_TYPE) do
        assertEqual(C2.SOURCE_DISPLAY_TYPE[key], value, "SOURCE_DISPLAY_TYPE." .. key .. " fallback")
    end
end)

test("Constants: Dps and Hps are deliberately absent from STAT_TYPE", function()
    -- The addon never queries them: amountPerSecond ships on the same source row
    -- as totalAmount, so one DamageDone read fills both halves of the Damage
    -- column. A row for them here would invite a second read per column.
    assertNil(Const.STAT_TYPE.Dps, "STAT_TYPE.Dps must stay absent")
    assertNil(Const.STAT_TYPE.Hps, "STAT_TYPE.Hps must stay absent")
end)

-- ── the message bus catalog ─────────────────────────────────────────────────

test("Constants: every bus message is uniquely named under the addon's prefix", function()
    -- CallbackHandler keys by string, so two constants sharing one wire name
    -- would silently deliver one message to both sets of subscribers.
    local seen, n = {}, 0
    for key, name in pairs(Const.MSG) do
        n = n + 1
        assertEqual(type(name), "string", "MSG." .. key)
        assertTrue(name:find("Ka0s_MultiMeters_", 1, true) == 1,
            "MSG." .. key .. " is not prefixed: " .. name)
        assertNil(seen[name], "two MSG constants share the wire name " .. name)
        seen[name] = key
    end
    assertTrue(n >= 10, "the bus catalog shrank unexpectedly (" .. n .. " messages)")
end)

test("Constants: every declared bus message is sent somewhere in the addon", function()
    -- A declared-but-unsent message is a subscriber that can never fire, and the
    -- catalog is the only place the name exists — so nothing else would catch it.
    -- REGISTERING for a message is not evidence it is sent, which is why this
    -- looks only at SendMessage call sites: modules/Window.lua subscribes to
    -- DRILLDOWN_CHANGED, and a check that merely grepped for the key would have
    -- been satisfied by the subscriber alone.
    -- red under: deleting a SendMessage call site without deleting its constant.
    local body = {}
    for _, rel in ipairs(T.loadedAddonFiles) do
        local fh = io.open((T.root or ".") .. "/" .. rel, "r")
        if fh then body[#body + 1] = fh:read("*a"); fh:close() end
    end
    local src = table.concat(body, "\n")

    -- Senders spell the constant, but several take a file-scope alias first
    -- (`local MSG_DRILLDOWN = Const.MSG.DRILLDOWN_CHANGED`), so the aliases are
    -- resolved before the call sites are read.
    local aliasOf = {}
    for name, key in src:gmatch("local%s+([%w_]+)%s*=%s*[%w_%.]*MSG%.([%w_]+)") do
        aliasOf[name] = key
    end

    local sent, sites = {}, 0
    for expr in src:gmatch("SendMessage%(%s*([%w_%.]+)") do
        sites = sites + 1
        local key = expr:match("MSG%.([%w_]+)$") or aliasOf[expr]
        if key then sent[key] = true end
    end
    assertTrue(sites >= 10, "found only " .. sites .. " SendMessage call sites — the scan drifted")

    local orphans = {}
    for key in pairs(Const.MSG) do
        if not sent[key] then orphans[#orphans + 1] = key end
    end
    table.sort(orphans)
    assertEqual(table.concat(orphans, ", "), "",
        "these bus messages are declared but nothing sends them")
end)

-- ── refresh timing and pool sizing ──────────────────────────────────────────

test("Constants: the throttle window is a real range around the shipped default", function()
    assertTrue(Const.THROTTLE_MIN > 0, "a zero floor turns every meter event into a rebuild")
    assertTrue(Const.THROTTLE_MIN < Const.THROTTLE_MAX, "the throttle slider has no range")
    local shipped = NS.WINDOW_TEMPLATE.data.throttle
    assertTrue(shipped >= Const.THROTTLE_MIN and shipped <= Const.THROTTLE_MAX,
        "the shipped throttle " .. shipped .. " sits outside the slider's own clamp")
end)

test("Constants: the row cap covers a full raid and the pool step covers a party", function()
    assertTrue(Const.MAX_ROWS >= 40, "MAX_ROWS must cover a 40-player raid")
    assertTrue(Const.POOL_GROW_STEP >= 5, "a 5-man must not grow the pool twice")
    assertTrue(Const.NAME_COLUMN_WIDTH > 0, "the name column has no width")
end)
