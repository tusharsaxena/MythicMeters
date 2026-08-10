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

    -- Two decimals at this magnitude, by the ladder in modules/Format.lua: a
    -- meter is read at three significant figures, so "4.20M" and not "4M".
    -- red under: CreateNumericRuleFormatter, which abbreviates nothing.
    local out = NS.Format.Number(4200000)
    assertEqual(out, "4.20M")

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
    assertEqual(out, "4.20M", "the NATIVE formatter did the arithmetic")

    -- A FontString takes it: the mock stores SetText's argument raw.
    local fs = mocks.__stubFrame("FontString")
    -- A bare FontString has no font, and SetText on one raises in the client (the
    -- harness models that now — it cost a load once). Real call sites always have
    -- a font by this point; this one is a scratch widget.
    fs:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    fs:SetText(out)
    assertEqual(fs:GetText(), "4.20M")
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
