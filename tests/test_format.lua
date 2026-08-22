-- tests/test_format.lua — modules/Format.lua: rendering a meter number without
-- ever looking at one.
--
-- The whole file exists because abbreviating 12400000 to "12.4M" is a division,
-- and a division on a secret raises. So the cases below are written against the
-- SIMULATED SECRET (tests/wow_mock.lua), whose metatable traps `/`, `*`, `-`,
-- `..`, `<` and indexing: a division that crept back into this module would not
-- return a slightly wrong string here, it would raise, and every case that runs
-- a secret through Number / Rate / Duration / Percent is therefore a live probe
-- for that regression rather than a restatement of the header.

local T = _G.MYTHICMETERS_TEST

local test         = T.test
local assertEqual  = T.assertEqual
local assertTrue   = T.assertTrue
local assertFalse  = T.assertFalse

--- A fresh instance with the Combat restriction ACTIVE: meter values arrive
--- secret and are not accessible, which is the state most of a pull is spent in.
local function restricted()
    local inst = T.load()
    inst.mocks.setRestricted(true)
    return inst
end

-- ---------------------------------------------------------------------------
-- Publication
-- ---------------------------------------------------------------------------

test("Format: NS.Format is a callable table carrying both contracts", function()
    local NS = T.NS
    assertEqual(type(NS.Format), "table", "NS.Format must stay indexable")
    assertEqual(type(NS.Format.Number), "function")
    -- Calling it reaches LibKa0s-Core's chat printer; the collision is resolved
    -- by the __call metamethod rather than by taking either name away.
    local meta = getmetatable(NS.Format)
    assertEqual(type(meta and meta.__call), "function", "NS.Format must stay callable")
    -- Both aliases are the same table, not copies that can drift.
    assertTrue(NS.Numbers == NS.Format, "NS.Numbers aliases the formatter")
    assertTrue(NS.NumberFormat == NS.Format, "NS.NumberFormat aliases the formatter")
end)

-- ---------------------------------------------------------------------------
-- The native formatter is the path taken
-- ---------------------------------------------------------------------------

test("Format.Number goes through the native ABBREVIATING formatter", function()
    local inst = T.load()
    local NS, mocks = inst.NS, inst.mocks

    -- No formatter has been built yet: the instance is created lazily, on the
    -- first call, and cached for the session.
    assertEqual(mocks.__lastNumericFormatter, nil, "formatter must be built lazily")

    -- ONE decimal at every magnitude, by the ladder in modules/Format.lua, so
    -- "4.2M" and not "4M" — and not "4.20M" either. The ladder used to carry two
    -- rungs per suffix chasing three significant figures, which made a column
    -- change shape partway down itself: "4.75K" on one row and "10.2K" on the
    -- next, because the two had landed on different rungs.
    -- red under: CreateNumericRuleFormatter, which abbreviates nothing.
    local out = NS.Format.Number(4200000)
    assertEqual(out, "4.2M")

    local formatter = mocks.__lastNumericFormatter
    assertEqual(type(formatter), "table", "a formatter instance must have been created")
    -- One probe (the ladder self-check) plus this value. The probe is what proves
    -- the breakpoints actually took: SetBreakpoints returning without error is
    -- NOT proof, and the live client rendered "47K" where the ladder says "47.5K"
    -- because it had quietly kept its own.
    local afterFirst = formatter.__formatCount
    assertTrue(afterFirst >= 1, "the value must go through :FormatNumber")

    -- Cached: a second call reuses the instance rather than asking C_StringUtil
    -- again (280 calls a frame on a raid, otherwise).
    NS.Format.Number(9000)
    assertTrue(mocks.__lastNumericFormatter == formatter, "the instance must be cached")
    assertEqual(formatter.__formatCount, afterFirst + 1)
end)

test("Format.Invalidate drops the cached formatter instance", function()
    local inst = T.load()
    local NS, mocks = inst.NS, inst.mocks

    NS.Format.Number(1000)
    local first = mocks.__lastNumericFormatter
    NS.Format.Invalidate()
    NS.Format.Number(1000)
    assertFalse(mocks.__lastNumericFormatter == first,
        "a new instance must be built after Invalidate")
end)

test("Format.Number('full') renders every digit and no abbreviation", function()
    local inst = T.load()
    local NS = inst.NS

    -- "Full" goes to the RULE formatter — no breakpoints, so no abbreviation.
    -- That is the object v0.1.0 was using for everything by mistake, here doing
    -- the job it is actually for.
    assertEqual(NS.Format.Number(4200000, "full"), "4200000")
end)

test("Format.Number('full') renders a rate's DIGITS, not its decimals", function()
    -- `amountPerSecond` is a float. `string.format("%s", 53571.392857143)` — the
    -- old "full" path — put fifteen characters in a 92px cell, which is what
    -- made the live window overlap into its neighbour.
    -- red under: `return passthrough(v)` for the full mode.
    local out = T.load().NS.Format.Number(53571.392857143, "full")
    assertFalse(tostring(out):find("%.") ~= nil,
        "a full-format number must not carry a decimal tail: " .. tostring(out))
end)

test("Format.Number abbreviates a sub-thousand rate to its whole part", function()
    -- The floor breakpoint. Without it a rate that has not reached a thousand
    -- renders every digit of its float.
    -- red under: dropping the breakpoint = 0 entry from the ladder.
    local out = T.load().NS.Format.Number(470.66666666667)
    assertEqual(out, "470")
end)

test("Format.Number renders a value BELOW ONE without dumping its float", function()
    -- THE INTERMITTENT ONE. The ladder's floor sat at `breakpoint = 1`, so any
    -- value in (0, 1) matched no rule at all and the formatter fell back to its
    -- plain render — every digit of the float, in a 92px cell.
    --
    -- It looked random because of WHICH figures can be sub-one. The rate slot is
    -- the only place a fraction reaches the grid, and `isRate` is true for
    -- exactly two stats — which is why it was "primarily damage or healing" and
    -- why no other column ever showed it.
    -- red under: a floor entry the client's rules never reach below.
    local F = T.load().NS.Format
    for _, v in ipairs({ 0.42857142857143, 0.5, 0.999 }) do
        local out = F.Number(v)
        assertFalse(tostring(out):find("%.") ~= nil,
            "a sub-one value must not render its decimals: " .. tostring(v)
                .. " -> " .. tostring(out))
    end
    assertEqual(F.Number(0.42857142857143), "0")
    -- Zero itself has always been fine and must stay so.
    assertEqual(F.Number(0), "0")
end)

test("Format.Number('full') also covers a value below one", function()
    -- Same floor, same fault, on the non-abbreviating formatter: its single
    -- breakpoint was written at 0, which this client refuses outright.
    local F = T.load().NS.Format
    assertFalse(tostring(F.Number(0.42857142857143, "full")):find("%.") ~= nil,
        "full mode means every DIGIT, never every decimal place")
end)

test("Format: a formatter whose ladder never took is NOT cached", function()
    -- HARDENING. A formatter that refused every rung still abbreviates nothing,
    -- and caching it made one bad build stick for the rest of the session — the
    -- same shape of bug as modules/Roster.lua's partial map. Refusing to cache it
    -- sends the render down the AbbreviateNumbers rung, which always abbreviates,
    -- and lets the next invalidation try again.
    -- red under: `cache.numeric = f` regardless of whether the ladder applied.
    local inst = T.load()
    local NS, mocks = inst.NS, inst.mocks

    -- A client that accepts the call and keeps its own rules — the live failure
    -- this file's ladderTook exists to catch.
    local realCreate = mocks.C_StringUtil.CreateAbbreviatedNumberFormatter
    mocks.C_StringUtil.CreateAbbreviatedNumberFormatter = function()
        local f = realCreate()
        f.SetBreakpoints = function() end   -- silently ignored
        return f
    end
    NS.Format.Invalidate()

    local out = NS.Format.Number(4200000)
    mocks.C_StringUtil.CreateAbbreviatedNumberFormatter = realCreate

    assertFalse(tostring(out):find("4200000", 1, true) ~= nil,
        "an unabbreviating formatter must not be the one that renders: " .. tostring(out))
end)

test("Format: the abbreviating formatter is given breakpoints, or it does nothing", function()
    -- The whole bug in one assertion. A formatter with no breakpoints is not
    -- broken and does not raise — it just renders "4200000".
    local inst = T.load()
    inst.NS.Format.Number(4200000)
    local f = inst.mocks.__lastNumericFormatter
    assertEqual(f.__kind, "abbreviated", "the ABBREVIATING type must be the one built")
    assertTrue(f.__breakpoints ~= nil and #f.__breakpoints > 0,
        "and it must have been given a ladder")
end)

test("Format.Number('') for nil, which is a different fact from zero", function()
    assertEqual(T.NS.Format.Number(nil), "")
    assertEqual(T.NS.Format.Rate(nil), "")
    assertEqual(T.NS.Format.Duration(nil), "")
    assertEqual(T.NS.Format.Percent(nil), "")
end)

-- ---------------------------------------------------------------------------
-- Secrets: nothing below divides, and the simulator proves it
-- ---------------------------------------------------------------------------

test("Format.Number accepts a secret and returns something SetText takes", function()
    local inst = restricted()
    local NS, mocks = inst.NS, inst.mocks

    local secret = mocks.secret(4200000)
    assertTrue(mocks.isSimulatedSecret(secret), "the fixture must actually be secret")
    assertFalse(NS.Secrets.CanAccess(secret), "and inaccessible while restricted")

    -- Any Lua arithmetic on `secret` raises MOCK_SECRET_VIOLATION, so reaching
    -- the assertion at all is the proof that nothing here divided.
    local out = NS.Format.Number(secret)
    assertEqual(out, "4.2M", "the NATIVE formatter did the arithmetic")

    -- A FontString takes it: the mock stores SetText's argument raw.
    local fs = mocks.__stubFrame("FontString")
    -- A bare FontString has no font, and SetText on one raises in the client (the
    -- harness models that now — it cost a load once). Real call sites always have
    -- a font by this point; this one is a scratch widget.
    fs:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    fs:SetText(out)
    assertEqual(fs:GetText(), "4.2M")
end)

test("Format.Rate renders the bare number — no unit suffix", function()
    local inst = restricted()
    local NS, mocks = inst.NS, inst.mocks

    -- The column header already says which statistic this is. Restating it per
    -- cell spends most of a column's width on two characters.
    -- red under: `return Number(v, mode) .. rateSuffix()` — the suffix comes back.
    local out = NS.Format.Rate(mocks.secret(300000))
    assertEqual(out, "300.0K")
    assertEqual(out, NS.Format.Number(mocks.secret(300000)),
        "Rate and Number agree on a rate value; only the call site differs")
end)

test("Format.Duration refuses the clock arithmetic on an inaccessible value", function()
    local inst = restricted()
    local NS, mocks = inst.NS, inst.mocks

    -- 212 seconds is 3:32, and computing that is a division and a modulo. While
    -- the value is inaccessible the function must take the OTHER path — the
    -- native formatter plus a suffix — rather than doing the arithmetic.
    local out = NS.Format.Duration(mocks.secret(212))
    assertEqual(out, "212" .. NS.L["s"],
        "an inaccessible duration renders abbreviated with a unit, not as mm:ss")
end)

test("Format.Duration does the clock arithmetic on a plain number", function()
    local F = T.NS.Format
    assertEqual(F.Duration(212), "3:32")
    assertEqual(F.Duration(0), "0:00")
    assertEqual(F.Duration(59.6), "1:00", "rounds to the nearest second")
    assertEqual(F.Duration(3725), "1:02:05", "past an hour it grows a field")
    assertEqual(F.Duration(-5), "0:00", "a negative duration is clamped, never negative-formatted")
end)

test("Format.Percent(value, total) refuses when an operand is inaccessible", function()
    local inst = restricted()
    local NS, mocks = inst.NS, inst.mocks

    -- The ratio form is a division. Both operands secret, one secret, and a zero
    -- denominator all answer EMPTY — never an approximation, and never "0%".
    assertEqual(NS.Format.Percent(mocks.secret(50), mocks.secret(100)), "")
    assertEqual(NS.Format.Percent(mocks.secret(50), 100), "")
    assertEqual(NS.Format.Percent(50, 0), "")
end)

test("Format.Percent computes the ratio when both operands are plain", function()
    local F = T.NS.Format
    assertEqual(F.Percent(25, 200), "12.5%")
    assertEqual(F.Percent(30, 200, 0), "15%", "the decimals argument reaches the format string")
    -- The pre-computed form: the aggregator divides, this only renders.
    assertEqual(F.Percent(12.5), "12.5%")
end)

test("Format.Percent refuses a pre-computed share it cannot access", function()
    local inst = restricted()
    -- A caller that hands a RAW meter value into the one-argument form has made
    -- a mistake; refusing beats guessing.
    assertEqual(inst.NS.Format.Percent(inst.mocks.secret(12.5)), "")
end)

-- ---------------------------------------------------------------------------
-- The degradation ladder
-- ---------------------------------------------------------------------------

test("Format.Number falls back to AbbreviateNumbers when C_StringUtil is absent", function()
    local inst = T.load{ mutate = function(mocks) mocks.C_StringUtil = nil end }
    local NS, mocks = inst.NS, inst.mocks
    mocks.setRestricted(true)

    assertEqual(NS.Compat.CreateNumericRuleFormatter(), nil,
        "the shim must answer nil rather than inventing a Lua formatter")
    assertEqual(NS.Compat.CreateAbbreviatedNumberFormatter(), nil)
    -- Rung 2 is Blizzard's own global, which also accepts a secret. Its rounding
    -- is Blizzard's, not our ladder's — one decimal — and that is fine: this rung
    -- exists so a client without C_StringUtil still reads, not so it matches.
    assertEqual(NS.Format.Number(mocks.secret(4200000)), "4.2M")
    assertEqual(mocks.__lastNumericFormatter, nil, "no native formatter was reachable")
end)

test("Format.Number falls back to SafeToString when neither abbreviator exists", function()
    local inst = T.load{ mutate = function(mocks)
        mocks.C_StringUtil     = nil
        mocks.AbbreviateNumbers = nil
    end }
    local NS, mocks = inst.NS, inst.mocks
    mocks.setRestricted(true)

    -- Rung 3 is honest rather than pretty: it says the number exists and we may
    -- not render it, which is a different fact from "0".
    local out = NS.Format.Number(mocks.secret(4200000))
    assertEqual(type(out), "string", "SetText must still get a string")
    assertFalse(out == "0", "a hidden number must never render as zero")
    assertEqual(out, NS.SafeToString(mocks.secret(1)),
        "the last rung is NS.SafeToString, not tostring")
end)

test("Format.Rate degrades to the bare number when the suffix cannot be joined", function()
    local inst = T.load{ mutate = function(mocks)
        mocks.C_StringUtil      = nil
        mocks.AbbreviateNumbers = nil
    end }
    local NS, mocks = inst.NS, inst.mocks
    mocks.setRestricted(true)

    local out = NS.Format.Rate(mocks.secret(300))
    assertEqual(type(out), "string")
end)

-- ---------------------------------------------------------------------------
-- Static guarantees the header claims
-- ---------------------------------------------------------------------------

--- The CODE of one repo file, with every comment removed — whole-line and
--- trailing alike. The headers here discuss the very APIs the assertions
--- forbid, so a grep that cannot tell prose from code proves nothing either way.
local function codeLines(relPath)
    local fh = assert(io.open(T.root .. "/" .. relPath, "r"))
    local out, n = {}, 0
    for line in fh:lines() do
        n = n + 1
        if not line:match("^%s*%-%-") then
            out[#out + 1] = { n = n, text = (line:gsub("%s%-%-.*$", "")) }
        end
    end
    fh:close()
    return out
end

test("modules/Format.lua never calls tonumber on anything", function()
    -- Coercing a meter value is an inspection, and this file is not
    -- core/Secrets.lua. There is no guarded form of this that is acceptable.
    for _, line in ipairs(codeLines("modules/Format.lua")) do
        assertFalse(line.text:find("tonumber", 1, true) ~= nil,
            "modules/Format.lua:" .. line.n .. " calls tonumber")
    end
end)

test("modules/Format.lua never calls table.concat", function()
    -- `..` is legal on a secret; table.concat is the one string operation that
    -- raises on one — it is literally core/CoreSetup.lua's secret probe.
    for _, line in ipairs(codeLines("modules/Format.lua")) do
        assertFalse(line.text:find("table.concat", 1, true) ~= nil,
            "modules/Format.lua:" .. line.n .. " calls table.concat")
    end
end)

test("Format.Number and Format.Rate contain no division at all", function()
    -- The two functions on the render path. Duration and Percent DO divide, both
    -- behind a core/Secrets.lua gate and on plain numbers only, which the cases
    -- above exercise; these two have no gate because they have no arithmetic.
    local lines = codeLines("modules/Format.lua")
    local inFunction = false
    for _, line in ipairs(lines) do
        local name = line.text:match("^function Format%.(%a+)")
        if name == "Number" or name == "Rate" then
            inFunction = true
        elseif line.text:match("^function ") then
            inFunction = false
        elseif inFunction then
            assertFalse(line.text:find("/") ~= nil,
                "modules/Format.lua:" .. line.n .. " divides on the render path")
        end
    end
end)

test("A ladder the client silently refuses is DETECTED, not assumed", function()
    -- SetBreakpoints returning without error is not proof that it took. The live
    -- client rendered "47K" where the ladder says "47.5K", which means it had
    -- quietly kept its own — a pcall that does not throw looked like success and
    -- was not. So the result is measured, on a number this addon owns.
    -- red under: `if pcall(SetBreakpoints, ...) then return end`.
    local inst = T.load{ mutate = function(mocks)
        local real = mocks.C_StringUtil.CreateAbbreviatedNumberFormatter
        mocks.C_StringUtil = setmetatable({
            CreateAbbreviatedNumberFormatter = function()
                local f = real()
                -- Accepts the call, ignores the array: exactly what the live
                -- client appears to do with a breakpoint it does not like.
                f.SetBreakpoints = function(self, list)
                    if list and list[1] and list[1].breakpoint == 0 then return end
                    self.__breakpoints = list
                end
                return f
            end,
        }, { __index = mocks.C_StringUtil })
    end }

    -- The floor entry is what gets refused, so the ladder WITHOUT it must be the
    -- one that ends up installed — not Blizzard's defaults, and not nothing.
    assertEqual(inst.NS.Format.Number(47500), "47.5K")
end)

-- ---------------------------------------------------------------------------
-- Format.DeathTime — how a death is labelled (issue #1)
-- ---------------------------------------------------------------------------
--
-- Three ways to say when somebody died, because there are three different
-- questions a reader has: "when in the evening", "how long ago", and "how far
-- into the fight".

test("Format.DeathTime renders the wall clock by default", function()
    local inst = T.load()
    local F = inst.NS.Numbers or inst.NS.Format
    assertEqual(F.DeathTime(1787381686, 1356, "clock", 1787381686),
        inst.mocks.date("%H:%M:%S", 1787381686))
    assertEqual(F.DeathTime(1787381686, 1356, nil, 1787381686),
        inst.mocks.date("%H:%M:%S", 1787381686), "an unset style is the clock")
end)

test("Format.DeathTime counts backwards from now", function()
    local inst = T.load()
    local F = inst.NS.Numbers or inst.NS.Format
    -- 8 minutes and change before `now`.
    local now = 1787381686
    local text = F.DeathTime(now - 500, 1356, "ago", now)
    assertTrue(text:find("8", 1, true) ~= nil, "500s is 8 minutes, got " .. text)
    assertTrue(F.DeathTime(now - 20, 1356, "ago", now):lower():find("s") ~= nil,
        "under a minute must read in seconds, not '0 min'")
end)

test("Format.DeathTime renders time into the fight as mm:ss", function()
    local inst = T.load()
    local F = inst.NS.Numbers or inst.NS.Format
    assertEqual(F.DeathTime(1787381686, 1356, "elapsed", 1787381686), "22:36")
    assertEqual(F.DeathTime(1787381686, 96, "elapsed", 1787381686), "01:36")
end)

test("Format.DeathTime falls back to the clock when the offset is unusable", function()
    -- `deathTimeSeconds` reads -1 on the Overall session, which is where most of
    -- this list is looked at. A "-1" rendered as "-1:-1" would be a number that
    -- looks like data; the clock is always available.
    -- red under: formatting the offset without checking it.
    local inst = T.load()
    local F = inst.NS.Numbers or inst.NS.Format
    local clock = inst.mocks.date("%H:%M:%S", 1787381686)
    assertEqual(F.DeathTime(1787381686, -1, "elapsed", 1787381686), clock)
    assertEqual(F.DeathTime(1787381686, false, "elapsed", 1787381686), clock)
    assertEqual(F.DeathTime(1787381686, nil, "elapsed", 1787381686), clock)
end)

test("Format.DeathTime answers nil when there is no timestamp at all", function()
    local inst = T.load()
    local F = inst.NS.Numbers or inst.NS.Format
    assertTrue(nil == F.DeathTime(nil, 1356, "clock", 1787381686))
    assertTrue(nil == F.DeathTime(nil, 1356, "elapsed", 1787381686))
end)

test("Format.DeathTime never inspects a secret", function()
    -- Every one of these is arithmetic or a comparison, and all three inputs
    -- come off a recap. A refused input answers nil rather than raising.
    local inst = T.load()
    local F = inst.NS.Numbers or inst.NS.Format
    inst.mocks.setSecretsAccessible(false)
    local secret = inst.mocks.secret(1787381686)
    assertTrue(pcall(F.DeathTime, secret, 1356, "clock", 1787381686))
    assertTrue(nil == F.DeathTime(secret, 1356, "clock", 1787381686))
end)
