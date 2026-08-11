-- modules/Format.lua
--
-- Turning a meter number into text, and the ONLY file that owns a
-- NumericRuleFormatter instance.
--
-- ---------------------------------------------------------------------------
-- WHY THIS FILE EXISTS AT ALL
-- ---------------------------------------------------------------------------
--
-- Abbreviating 12400000 to "12.4M" is a division and a rounding. Both are
-- arithmetic, and arithmetic on a secret value raises immediately in tainted
-- code — which is all of ours. Every number this addon displays comes off
-- C_DamageMeter and is secret for the whole of a pull, so "abbreviate this
-- number" is not an edge case here, it is the main path.
--
-- The one legal escape hatch is C_StringUtil.CreateNumericRuleFormatter(),
-- whose :FormatNumber(n) performs that arithmetic NATIVELY and accepts secrets
-- (design §4, "Number formatting"). This file owns those instances — built
-- lazily, cached for the session, dropped when the profile or a setting moves —
-- and it is the only place in the addon that asks for one.
--
-- NOTHING BELOW DIVIDES A METER VALUE. Not once, not behind a guard, not "only
-- out of combat". A Lua division that is correct out of combat and a hard error
-- in combat is the worst of the two possible failures, because it ships green
-- and breaks in a raid.
--
-- ---------------------------------------------------------------------------
-- WHAT A RETURN VALUE FROM HERE IS
-- ---------------------------------------------------------------------------
--
-- "A string, or something FontString:SetText will take." Those are the same
-- thing to a widget and different things to Lua: the formatter may hand back a
-- secret string, and passing a raw secret straight through is a legitimate
-- degradation. So a caller may SetText it and may concatenate it, and may do
-- nothing else with it — no comparing, no measuring, no keying (rule R1).
--
-- The degradation ladder for the abbreviated form is three deep, and each rung
-- is a real client:
--   1. NumericRuleFormatter — 12.x, the intended path.
--   2. AbbreviateNumbers    — Blizzard's own global, which also accepts secrets.
--   3. NS.SafeToString      — LibKa0s's secret-safe renderer, which answers
--                             "<secret>" rather than raising. Ugly, never wrong.
-- tonumber() appears nowhere: coercing a meter value is an inspection, and this
-- file is not core/Secrets.lua.
--
-- ---------------------------------------------------------------------------
-- NAMESPACE COLLISION, DELIBERATELY RESOLVED HERE (integrator: read this)
-- ---------------------------------------------------------------------------
--
-- core/CoreSetup.lua already publishes NS.Format — LibKa0s-Core-1.0's printf
-- style CHAT printer, `NS.Format(fmt, ...)`. The design brief also names
-- NS.Format for the number formatter published below. Rather than take the name
-- away from the printer (silently breaking every chat call site) or invent a
-- second name for the formatter (silently breaking every display call site),
-- NS.Format becomes a TABLE that is still CALLABLE: indexing it reaches the
-- number formatter, calling it forwards to the printer captured at this file's
-- load. Both contracts survive, and there is exactly one place — here — that a
-- reader has to understand.
--
-- The one thing this cannot survive is code that asserts type(NS.Format) ==
-- "function". Nothing in the addon does; a test that wants the printer should
-- assert it is callable.
--
-- TOC POSITION: first in the `# Modules` block. Nothing here reads another
-- module, and modules/Row.lua and modules/Tooltip.lua both format on their
-- first render.

local addonName, NS = ...

local Compat  = NS.Compat
local Secrets = NS.Secrets
local State   = NS.State
local L       = NS.L

-- LibKa0s-Core-1.0's chat printer, captured BEFORE the name is rebound below.
-- May be nil on an install so broken that core/CoreSetup.lua never ran; the
-- __call bridge degrades to the plain printer rather than to an error, because
-- a missing chat line must not take a render pass with it.
local chatFormat = NS.Format

-- NO PERF UPVALUE HERE, deliberately. Every function below is three lines around
-- a native call, and the cost a reader actually wants attributed is "what did
-- rendering this row cost" — which modules/Row.lua already brackets as
-- "renderRow". A second bracket inside it would cost more than the work it
-- measured and would double-count into the same pass.

local Format = {}

-- Session cache for the formatter instances. Lives in core/State.lua's shared
-- cache rather than in a file-local so it shares ONE invalidation seam with the
-- roster map and the frozen sort order: a profile swap or a meter reset drops
-- all three together instead of two of three. State.WipeCache wipes IN PLACE, so
-- holding the sub-table as an upvalue here stays correct forever.
local cache = State.Cache("Format")

-- Localized rather than literal because a translator moves it (German writes
-- "Sek."), and read at CALL time through NS.L so a locale file that loads after
-- this one still wins.
--
-- THERE IS NO RATE SUFFIX. A per-second figure renders as the bare number: the
-- column header already says which statistic it is, and the reference meters
-- this addon is measured against put "1.41M  83.2K" in a row rather than
-- "1.41M  83.2K/s". Two characters per cell across seven columns and forty rows
-- is most of a column's width spent restating the header.
local function secondsSuffix() return L["s"] end

-- ---------------------------------------------------------------------------
-- The formatter instance
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- THE BREAKPOINT LADDER
-- ---------------------------------------------------------------------------
--
-- A NumberAbbreviationBreakpoint is
--   { breakpoint, abbreviation, significandDivisor, fractionDivisor,
--     abbreviationIsGlobal }
-- and the documented idiom is to specify them IN PAIRS: one at the named order
-- (1,000) with a fractionDivisor that buys decimals, and one an order higher
-- (10,000) with fewer, so "1234" reads "1.23K" and "12345" reads "12.3K" rather
-- than "12.345K".
--
-- THE TWO DIVISORS MULTIPLY, and that is not what the documentation implies.
--
-- Measured on a live client, across six values, perfectly consistently:
--
--     displayed = n / (significandDivisor * fractionDivisor)
--     decimals  = log10(fractionDivisor)
--
--     4750    with sig 1000, frac 100  ->  0.04K   (4750 / 100000)
--     47500   with sig 1000, frac 10   ->  4.7K    (47500 / 10000)
--     1410000 with sig 1e6,  frac 100  ->  0.01M   (1410000 / 1e8)
--
-- The wiki's example — "one at 1,000 with fractionDivisor = 10 … displays 1234 as
-- 1.2k" — does not hold under that formula, and the client is the authority. The
-- first ladder here was written from the documentation and put every number two
-- orders of magnitude too small; nothing errored, because nothing was wrong
-- except the arithmetic nobody could see.
--
-- So each rung is written as `significandDivisor = order / fractionDivisor`,
-- which is the identity that makes the displayed value come out at `n / order`
-- with the decimals asked for.
--
-- ONE DECIMAL PLACE AT EVERY MAGNITUDE, WHICH IS WHY THERE IS ONE RUNG PER
-- SUFFIX. The ladder used to carry two rungs per suffix — a `fractionDivisor` of
-- 100 below ten thousand and 10 above it — chasing three significant figures.
-- What that produced was a COLUMN THAT CHANGED SHAPE PARTWAY DOWN ITSELF:
-- "4.75K" on one row and "10.2K" on the next, two decimal places beside one,
-- because the two rows had landed on different rungs. A column of numbers is
-- read by scanning it vertically and the decimal point is the thing the eye
-- tracks, so consistency beats the extra digit.
--
-- The cost is real and small: "1.4M" where the old ladder said "1.41M". The
-- benefit is that every figure in a column has the same shape whatever its
-- magnitude.
--
-- `abbreviationIsGlobal = false` puts the literal K / M / B in rather than
-- looking up a global string. That is a deliberate trade against localization:
-- the addon is enUS-only (a documented limitation), the suffix is the one piece
-- of this string a player reads positionally rather than linguistically, and a
-- missing global name would silently render an empty suffix — "1.41" — which is
-- worse than an untranslated one.
--
-- THE FLOOR IS BELOW ONE, AND THAT IS THE WHOLE POINT OF IT. A breakpoint is a
-- rule for values AT OR ABOVE it, so a floor at 1 leaves (0, 1) matching nothing
-- at all — and a formatter with no matching rule renders the value plainly, which
-- for a float is every digit it has. That is what put "0.42857142857143" in a
-- 92px cell.
--
-- It read as intermittent because of WHICH figures can be sub-one. The rate slot
-- is the only place a fraction reaches the grid and `isRate` is true for exactly
-- two stats, which is why it was only ever seen in Damage and Healing.
--
-- 0 itself is deliberately NOT covered: the client refused a `breakpoint = 0` row
-- outright (the debug log said so) and took the whole array with it. A value of
-- exactly zero renders "0" through the plain path anyway, which is the answer the
-- rule would have produced.
local BREAKPOINTS = {
    { breakpoint =      0.001, abbreviation = "",  significandDivisor =   1, fractionDivisor =  1, abbreviationIsGlobal = false },
    { breakpoint =       1000, abbreviation = "K", significandDivisor = 100, fractionDivisor = 10, abbreviationIsGlobal = false },
    { breakpoint =    1000000, abbreviation = "M", significandDivisor = 1e5, fractionDivisor = 10, abbreviationIsGlobal = false },
    { breakpoint = 1000000000, abbreviation = "B", significandDivisor = 1e8, fractionDivisor = 10, abbreviationIsGlobal = false },
}

-- A value whose formatting PROVES the ladder took: 47500 must render as "47.5K"
-- under the ladder above, and as "47K" under Blizzard's defaults.
local PROBE_VALUE    = 47500
local PROBE_EXPECTED = "47.5K"

-- The second probe, for the rung that claims a sub-one floor. 0.5 must render as
-- a whole "0" rather than as its own digits; a ladder that answers "0.5" here has
-- a floor the client did not take.
local PROBE_SMALL          = 0.5
local PROBE_SMALL_EXPECTED = "0"

--- Whether `f` is actually formatting the way the ladder above asks.
---
--- SetBreakpoints RETURNING WITHOUT ERROR IS NOT PROOF THAT IT TOOK. The live
--- client rendered "47K" where the ladder says "47.5K", which means it had
--- quietly rejected our array and kept its own — a `pcall` that does not throw
--- looked like success and was not. So the result is measured rather than
--- assumed, on a number this addon owns.
---
--- @param f table
--- @return boolean
local function ladderTook(f, alsoSmall)
    local ok, out = pcall(f.FormatNumber, f, PROBE_VALUE)
    if not ok or type(out) ~= "string" then return false end
    -- THE EXACT STRING, not "does it contain a decimal point".
    --
    -- The looser check is what let a wrong ladder through: under the previous
    -- divisors 47500 rendered "4.7K", which has a point, so the probe said yes to
    -- an answer that was off by two orders of magnitude.
    if out ~= PROBE_EXPECTED then return false end

    if alsoSmall then
        local okSmall, small = pcall(f.FormatNumber, f, PROBE_SMALL)
        if not okSmall or small ~= PROBE_SMALL_EXPECTED then return false end
    end
    return true
end

--- Put our ladder on `f`, falling back to the client's own.
---
--- FOUR outcomes, in descending order of how much we like them: our full ladder;
--- our ladder without its floor entry (a `breakpoint = 0` row is the most likely
--- reason the client would reject the array wholesale); Blizzard's defaults; or a
--- formatter with none, which is the v0.1.0 behavior and abbreviates nothing.
---
--- Each rung is CHECKED, not assumed — see ladderTook.
--- Put one candidate array on `f` and report whether it actually took.
---
--- Both halves matter and neither is enough alone: SetBreakpoints can refuse the
--- array (the pcall), and it can accept the call while keeping its own rules
--- (the probe). One rung, one question.
local function tryLadder(f, list, probeSmall)
    if not pcall(f.SetBreakpoints, f, list) then return false end
    return ladderTook(f, probeSmall)
end

--- @return boolean  whether ANY rung actually took
local function applyBreakpoints(f)
    if type(f.SetBreakpoints) ~= "function" then
        if State.debug then
            NS.Debug("Format", "formatter has no SetBreakpoints — numbers will not abbreviate")
        end
        return false
    end

    -- The same ladder with its floor moved back up to 1, for a client that
    -- refuses a fractional breakpoint the way this one refuses a zero. Sub-one
    -- values render their digits under it — which is the old behavior, and the
    -- point is that it is the SECOND choice rather than the only one.
    local integerFloor = { { breakpoint = 1, abbreviation = "", significandDivisor = 1,
                             fractionDivisor = 1, abbreviationIsGlobal = false } }
    local withoutFloor = {}
    for i = 2, #BREAKPOINTS do
        integerFloor[#integerFloor + 1] = BREAKPOINTS[i]
        withoutFloor[#withoutFloor + 1] = BREAKPOINTS[i]
    end

    -- The first rung is probed for the SUB-ONE case as well, because that is the
    -- only thing distinguishing it from the second.
    if tryLadder(f, BREAKPOINTS, true) then return true end

    local rungs = {
        { integerFloor, "sub-one floor rejected; values below 1 will show their digits" },
        { withoutFloor, "breakpoint floor rejected; using the ladder without it" },
        { Compat.GetDefaultAbbreviationBreakpoints(),
          "custom breakpoints refused; using the client's defaults" },
    }

    for _, rung in ipairs(rungs) do
        if rung[1] and tryLadder(f, rung[1]) then
            if State.debug then NS.Debug("Format", rung[2]) end
            return true
        end
    end

    if State.debug then
        NS.Debug("Format", "no breakpoints applied — numbers will not abbreviate")
    end
    return false
end

--- The session's ABBREVIATING formatter, or nil where C_StringUtil is absent.
---
--- Cached as `false` rather than nil on failure so a client without the API
--- does not pay a fresh (failing) API call per cell per refresh — with seven
--- columns and forty rows that is 280 calls a frame, which is exactly the shape
--- of cost the perf contract exists to catch.
---
--- @return table|nil  object answering :FormatNumber(n)
local function numeric()
    local f = cache.numeric
    if f == false then return nil end
    if f ~= nil then return f end

    local fresh = Compat.CreateAbbreviatedNumberFormatter()

    -- A FORMATTER THAT DOES NOT ABBREVIATE IS WORSE THAN NO FORMATTER, and this
    -- is the seam that used to hide one. The old shape built it, applied whatever
    -- breakpoints it could, and cached the object either way — so a client that
    -- silently kept its own rules got an object that renders "4200000", cached
    -- for the rest of the session, with no way back until a profile change.
    --
    -- Caching `false` instead sends every render down the AbbreviateNumbers rung,
    -- which always abbreviates and accepts secrets. It is cached rather than
    -- retried per cell for the reason below: seven columns times forty rows is
    -- 280 failing API calls a frame. Format.Invalidate is what tries again.
    if not (fresh and applyBreakpoints(fresh)) then
        cache.numeric = false
        return nil
    end

    cache.numeric = fresh
    return fresh
end

--- The session's NON-abbreviating formatter, for `numberFormat = "full"`.
---
--- Cached separately from `numeric` because they are two different objects with
--- two different breakpoint sets, and a window on `full` sitting beside one on
--- `abbreviated` must not make them fight over one cache slot.
---
--- @return table|nil
local function plain()
    local f = cache.plain
    if f == nil then
        f = Compat.CreateNumericRuleFormatter()
        if f and type(f.SetBreakpoints) == "function" then
            -- ONE entry, and it is not "no breakpoints". "Full" means every
            -- DIGIT, not every decimal place: `amountPerSecond` is a float, and
            -- an unbounded render of 53571.392857143 is fifteen characters in a
            -- 92px cell. Dividing by 1 with no fraction keeps the whole number
            -- and drops the tail.
            -- 0.001 rather than 0, for the reason the ladder above gives: the
            -- client refuses a `breakpoint = 0` row and takes the array with it,
            -- which left THIS formatter with no rules at all — so "full" mode
            -- rendered the very float it exists to trim.
            pcall(f.SetBreakpoints, f, {
                { breakpoint = 0.001, abbreviation = "", significandDivisor = 1,
                  fractionDivisor = 1, abbreviationIsGlobal = false },
            })
        end
        cache.plain = f or false
    end
    if f == false then return nil end
    return f
end

--- Render `v` without interpreting it.
---
--- string.format with a secret is explicitly permitted (design §4), and it is
--- what turns a number into something a FontString and a concatenation both
--- accept. The pcall is not superstition: the permitted-operation list is a 12.0
--- contract we are consuming rather than one we control, and the cost of being
--- wrong about one entry on it is a Lua error on a coalesced refresh ticker.
--- When it fails, the raw handle goes through — SetText takes it.
local function passthrough(v)
    local ok, out = pcall(string.format, "%s", v)
    if ok then return out end
    return v
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- A meter value as display text.
---
--- @param v any     an opaque meter value (possibly secret), or nil
--- @param mode string|nil  "abbreviated" (default) or "full"
--- @return any  a string, or a handle FontString:SetText accepts
function Format.Number(v, mode)
    -- Nil-ness is the ONE boolean-shaped test permitted on a non-boolean secret
    -- (core/Secrets.lua's contract). Everything below this line treats `v` as
    -- present without ever asking what it is.
    if v == nil then return "" end

    if mode == "full" then
        -- "Full" is the un-abbreviated form, which means the RULE formatter with
        -- no breakpoints on it rather than the abbreviating one — the same
        -- object v0.1.0 was using for everything by mistake, here doing the job
        -- it is actually for.
        --
        -- Not `passthrough`: a rate is a float, and `string.format("%s", …)` on
        -- one renders "53571.392857143". "Full" means every DIGIT, not every
        -- decimal place.
        local full = plain()
        if full then
            local ok, out = pcall(full.FormatNumber, full, v)
            if ok then return out end
        end
        return passthrough(v)
    end

    local f = numeric()
    if f then
        local ok, out = pcall(f.FormatNumber, f, v)
        if ok then return out end
    end

    -- Rung 2: Blizzard's own abbreviator. Reached through _G rather than named
    -- as a global so a client (or the headless harness) without it degrades
    -- instead of erroring, and so .luacheckrc does not have to declare a global
    -- that exactly one line uses.
    local abbreviate = _G.AbbreviateNumbers
    if abbreviate then
        local ok, out = pcall(abbreviate, v)
        if ok then return out end
    end

    -- Rung 3. Honest rather than pretty: "<secret>" says the number exists and
    -- we may not render it, which is a different fact from "0".
    return NS.SafeToString(v)
end

--- The per-second form of a meter value — `amountPerSecond`, not something
--- divided here.
---
--- The rate arrives on the source row already computed by the client (design
--- §3), which is the entire reason the Dps and Hps meter types are never
--- queried. Nothing is divided here and nothing is appended.
---
--- KEPT AS ITS OWN FUNCTION even though it now forwards verbatim. modules/Row.lua
--- selects it by the cell's `kind`, the catalog's `isRate` flag decides which
--- columns reach it, and a future decision to render rates differently — a
--- distinct color, a suffix a player asked back for — has one home rather than a
--- conditional inside Number.
---
--- @param v any
--- @param mode string|nil
--- @return any
function Format.Rate(v, mode)
    if v == nil then return "" end
    return Format.Number(v, mode)
end

--- A duration as mm:ss (or h:mm:ss past an hour).
---
--- Two paths, and the split is the whole point. A session duration is secret
--- while the Combat restriction is active, and minutes-and-seconds is division
--- and modulo — so when the value cannot be accessed it goes through the native
--- formatter with a unit appended instead, which is worse to read and cannot
--- raise. The clock arithmetic below runs ONLY on a value core/Secrets.lua has
--- confirmed is a plain number.
---
--- @param seconds any
--- @return string
function Format.Duration(seconds)
    if seconds == nil then return "" end

    if not Secrets.CanAccess(seconds) then
        local text = Format.Number(seconds, "abbreviated")
        local ok, out = pcall(function() return text .. secondsSuffix() end)
        return ok and out or text
    end

    if type(seconds) ~= "number" then return NS.SafeToString(seconds) end

    local total = math.floor(seconds + 0.5)
    if total < 0 then total = 0 end
    local minutes = math.floor(total / 60)
    local secs    = total - minutes * 60
    if minutes >= 60 then
        local hours = math.floor(minutes / 60)
        return string.format("%d:%02d:%02d", hours, minutes - hours * 60, secs)
    end
    return string.format("%d:%02d", minutes, secs)
end

--- A percentage as display text. TWO CALL SHAPES, and the second argument tells
--- them apart:
---
---   Format.Percent(share)            -- share is ALREADY a percentage number
---   Format.Percent(share, "full")    -- ditto, with the window's format mode
---   Format.Percent(value, total)     -- a ratio, computed here
---
--- The dual shape is not cleverness for its own sake. modules/Aggregator.lua
--- computes `percent` per cell — it is the only place that holds both the value
--- and its column total — and modules/Row.lua then renders that number the same
--- way it renders every other slot, as `Percent(value, mode)`. Supporting only
--- the ratio form would make the row's call silently produce nothing; supporting
--- only the pre-computed form would leave no home for the division.
---
--- Either way a percentage is a DIVISION, so the ratio form answers EMPTY rather
--- than approximating whenever an operand is inaccessible — which is most of a
--- pull. That is why the text slots default to total/rate: a column configured
--- to show percentages simply goes quiet in combat.
---
--- Callers must not read the emptiness as "zero percent". Nothing in the addon
--- does; the cell just renders no text.
---
--- @param value any            a percentage, or a numerator
--- @param total any            a denominator, or the format mode, or nil
--- @param decimals number|nil  digits after the point (default 1)
--- @return string
function Format.Percent(value, total, decimals)
    if value == nil then return "" end

    local share
    if type(total) == "number" then
        if not Secrets.CanCompare2(value, total) then return "" end
        if type(value) ~= "number" then return "" end
        if total == 0 then return "" end
        share = value / total * 100
    else
        -- Pre-computed. The aggregator only ever produces this field when the
        -- division was legal, so an inaccessible value here means somebody
        -- handed us a raw meter number by mistake; refusing beats guessing.
        if not Secrets.CanAccess(value) then return "" end
        if type(value) ~= "number" then return "" end
        share = value
    end

    return string.format("%." .. (decimals or 1) .. "f%%", share)
end

--- Drop the cached formatter instances.
---
--- Called when the number-format setting moves and on a profile swap. Cheap —
--- the next Number() rebuilds — and correct in the one case that matters: a
--- future formatter built from configurable rules would otherwise keep the
--- previous profile's rules for the rest of the session.
function Format.Invalidate()
    State.WipeCache("Format")
end

-- ---------------------------------------------------------------------------
-- Invalidation
-- ---------------------------------------------------------------------------
--
-- A PRIVATE bus target, not the shared addon object. CallbackHandler keys
-- callbacks by (message, target), so two receivers of one message registered on
-- the same object silently clobber each other and only the last one ever fires
-- (architecture-§4, anti-pattern #32). This module is not an AceAddon module —
-- it has no lifecycle and, unlike a module, it must carry the __call metatable
-- below, which AceAddon's own metatable would fight over — so it owns a target
-- rather than being one.

local bus = NS.NewBusTarget()
if bus then
    local MSG = NS.Constants.MSG
    bus:RegisterMessage(MSG.CONFIG_CHANGED,  Format.Invalidate)
    bus:RegisterMessage(MSG.PROFILE_CHANGED, Format.Invalidate)
end

-- ---------------------------------------------------------------------------
-- Publication
-- ---------------------------------------------------------------------------
--
-- The callable table described in the header. Indexing reaches this module;
-- calling reaches LibKa0s's chat printer. The perf bracket wraps NOTHING here on
-- purpose: formatting is measured inside modules/Row.lua's "renderRow" bucket,
-- where a reader wants the per-row number, and a second bracket around a
-- three-line function would cost more than the function.

NS.Format = setmetatable(Format, {
    __call = function(_, fmt, ...)
        if chatFormat then return chatFormat(fmt, ...) end
        -- No printer at all: say the thing unformatted rather than swallow it.
        local out = NS.Print or _G.print
        if out then out(NS.SafeToString(fmt)) end
    end,
})

-- Two more names for the same table, both of them already in use by files this
-- one does not own:
--   NS.Numbers      — modules/Tooltip.lua resolves the number formatter here,
--                     precisely to avoid the NS.Format collision above.
--   NS.NumberFormat — the unambiguous name, for a call site that wants to say
--                     which formatter it means, and the name a future decision
--                     to give NS.Format back to the printer would land on.
NS.Numbers      = Format
NS.NumberFormat = Format
