local addonName, NS = ...

-- core/DebugLogSetup.lua — wires the addon into LibKa0s-DebugLog-1.0.
--
-- The console window, the copy window, the two formatters, the 500-line buffer,
-- the scrollbar sync, the line counter and the enable seam live in
-- libs/LibKa0s/DebugLog.lua and are shared across every Ka0s addon. This file
-- supplies only the part that is ours: the frame-name prefix, the title, the
-- monospace font, where the debug flag actually lives, and what the [Init]
-- session summary says.
--
-- (The library's line format and its hex codes are deliberately not quoted
-- anywhere in this file — the degradation suite greps for them to prove the stub
-- below carries no copy, and a comment restating them would satisfy that grep.)
--
-- WHY THIS ADDON NEEDS THE CONSOLE MORE THAN MOST. Every number it renders is a
-- secret value for the whole of a pull, so the interesting bugs are the ones you
-- cannot inspect: a cell that shows nothing, a row that sorted wrong, a column
-- that read nil. The debug pass is how they get diagnosed, and NS.Debug's
-- deferred format is what makes that affordable — the format string and its
-- arguments are only assembled when the flag is on, and every argument goes
-- through safeToString on the way, so a secret reaching a log line renders as the
-- sentinel instead of raising inside the sink.
--
-- TOC POSITION. In core/ rather than modules/, and after core/CoreSetup.lua,
-- which pins three things:
--   * core/Constants.lua has run, so NS.Constants.FONT_MONO resolves;
--   * core/State.lua has run, so NS.State.debug — the flag — exists;
--   * core/CoreSetup.lua has run, so NS.Print and NS.SafeToString exist.
-- Everything that calls NS.Debug loads after it.

-- The monospace font ships to LibSharedMedia at load (debug-logging-§2), but the
-- registration is NOT repeated here: core/LSMPatch.lua owns it, under
-- NS.Constants.FONT_MONO_NAME, and it loads first. A second Register call from
-- this file added the same path under a hardcoded "JetBrains Mono" — a second LSM
-- key for one face, so the font dropdown listed it twice and a profile could
-- store the name core/LSMPatch.lua does not ship. The console takes
-- NS.Constants.FONT_MONO (the PATH) directly below either way, so it needs no
-- registration of its own.

-- ABOVE THE LIBRARY FORK ON PURPOSE. The stub branch below `return`s, so
-- anything defined after it does not exist on an install without LibKa0s — and
-- NS.DebugSteady is called from the render path behind `if State.debug`, so the
-- absence would surface only for a player who turned logging on with the library
-- missing. That is precisely the "crash moved to a rarer code path" the stub's
-- own comment warns about. It needs no library: it holds its own state and
-- forwards to NS.Debug, which both branches publish.
-- ---------------------------------------------------------------------------
-- The steady-state sink — one line per CHANGE, not one line per pass
-- ---------------------------------------------------------------------------
--
-- debug-logging-§9 collapses a repeating path from one line per ITEM to one line
-- per PASS. That is the right rule and this addon obeys it. It leaves the other
-- axis open: a pass that runs on a TIMER and reports the same thing every time.
--
-- Measured on this addon. `throttle = 0.25` is four passes a second, each
-- emitting an `[Aggregator]` line and a `[Render]` line, plus a second
-- `[Aggregator]` line while restricted — twelve lines a second, into a buffer
-- capped at 500 (§1). THE CONSOLE HOLDS FORTY SECONDS. A live capture showed
-- `identity rows=2 keys=3 collisions=0 filled=3/10` repeating byte-identically
-- for forty-one seconds: roughly 160 passes, ~480 lines, one string. That single
-- steady state evicts the entire history behind it, which is exactly the harm §9
-- names ("it EVICTS it") arriving by a route §9 does not cover.
--
-- So the pass is coalesced one step further, and the shape is chosen so that
-- nothing a reader wants is ever the thing that goes missing:
--
--   * A CHANGE IS NEVER DELAYED AND NEVER DROPPED. It emits on the pass it
--     happens. Throttling on a clock would suppress changes, and a change is the
--     only content these lines carry — a log that drops one to save nine
--     identical ones has thrown away the signal to save the noise.
--   * A RUN IS REPORTED ON THE LINE IT DESCRIBES. When a run of identical passes
--     ends, the run is emitted as `… (x160)` BEFORE the line that broke it, so
--     the count belongs to the state it counts rather than to the next one.
--   * SILENCE STILL MEANS SOMETHING. Without a heartbeat, a frozen refresh loop
--     and a healthy idle one produce identical logs, and "no lines" stops meaning
--     "nothing changed". An unchanged run re-emits at most once every
--     STEADY_HEARTBEAT seconds, so the log always shows the pass is alive and
--     when the current state began.
--
-- Recorded as an accepted deviation in docs/ARCHITECTURE.md -> Documented
-- deviations, against §8's "each recompute, as a single summary line".

--- How long an unchanged run may stay silent before it re-announces itself.
---
--- Ten seconds is one line per tag per ten seconds in a steady state — about 80
--- minutes of history in the same 500-line buffer that held 40 seconds, and
--- still frequent enough that a reader who grabs the log mid-pull sees the
--- current state rather than inferring it from a line five minutes old.
local STEADY_HEARTBEAT = 10

--- Per FORMAT STRING, per key: the last arguments emitted and how the run stands.
---
--- KEYED ON THE FORMAT, NOT THE TAG, and the first version got this wrong in a
--- way that looked like tuning rather than a bug. `modules/Aggregator.lua` has
--- TWO call sites under the tag `Aggregator` — the pass summary and the identity
--- line — and on one window they share a key. Sharing one slot, they alternated
--- through it: every call found the other's format sitting there, called itself a
--- change, and emitted. `[Render]` deduped perfectly while `[Aggregator]` never
--- deduped once, which reads as "the throttle is too generous" and is really
--- "the cache cannot tell two call sites apart".
---
--- A format string is a literal, so it identifies the call site for free and the
--- outer table holds one entry per site. `key` then separates emitters that share
--- a site — two windows both rendering. Both axes are needed and neither is
--- sufficient: the tag is not, which is what this comment is for.
local steady = {}

--- Whether every argument may be held and compared.
---
--- A SECRET IS NEVER STORED AND NEVER REPLAYED. Holding one is legal (rule R1
--- permits store and pass), and comparing one is legal too — `==` against a
--- secret answers false rather than raising. The problem is the third thing this
--- function does: a suppressed run is RE-EMITTED later, and re-emitting a handle
--- captured ten seconds ago prints a stale figure with a current timestamp on it.
--- That is the one failure mode a debug line must not have. So an argument that
--- is not concat-safe forces the line out immediately and keeps it out of the
--- store.
local function holdable(n, ...)
    for i = 1, n do
        local v = select(i, ...)
        if v ~= nil and not NS.IsConcatSafe(v) then return false end
    end
    return true
end

--- Whether `...` differs from the run recorded in `slot`.
---
--- Compared as ARGUMENTS rather than as a formatted string, so a suppressed pass
--- builds nothing it then throws away — which is the whole point of §4's
--- deferred format, applied to the comparison as well as to the emission.
local function changed(slot, n, fmt, ...)
    if slot.fmt ~= fmt or slot.n ~= n then return true end
    for i = 1, n do
        if slot[i] ~= select(i, ...) then return true end
    end
    return false
end

local function remember(slot, n, fmt, ...)
    slot.fmt, slot.n = fmt, n
    for i = 1, n do slot[i] = select(i, ...) end
end

--- One shared buffer for building the `(xN)` argument list.
---
--- IT HAS TO BE A TABLE, and this is the seam where getting it wrong is silent.
--- `NS.Debug(tag, fmt, ..., count)` and `NS.Debug(tag, fmt, unpack(slot), count)`
--- both TRUNCATE the expansion to its first value — Lua adjusts a vararg or a
--- multi-return to one result anywhere but the last argument position. The line
--- would still print, with every field after the first replaced by the count, and
--- nothing would raise. So the count is appended to a real list and the whole
--- list is expanded last.
---
--- Reused rather than allocated per emission: this runs on the refresh path.
local scratch = {}

--- Re-emit the run recorded in `slot`, carrying how many passes it stood for.
local function emitRun(tag, slot, passes)
    local n = slot.n
    for i = 1, n do scratch[i] = slot[i] end
    scratch[n + 1] = passes
    NS.Debug(tag, slot.fmt .. " (x%d)", unpack(scratch, 1, n + 1))
end

--- One debug line per CHANGE of a timer-driven pass, plus a bounded heartbeat.
---
--- `key` separates emitters that share a CALL SITE — two windows both logging the
--- same `Render` line would otherwise alternate and defeat each other's
--- comparison. The call site itself is identified by `fmt`; see the cache above
--- for why the tag cannot do that job.
---
--- Callers stay gated exactly as they were: this is not a replacement for the
--- `if State.debug` check at the call site, because the arguments are evaluated
--- to get here.
---
--- @param key any        stable identity of the emitter (a window id)
--- @param tag string     the log tag, as NS.Debug takes it
--- @param fmt string     the format string, a literal at the call site
local function DebugSteady(key, tag, fmt, ...)
    local byKey = steady[fmt]
    if byKey == nil then byKey = {} steady[fmt] = byKey end
    local slot = byKey[key]
    if slot == nil then slot = { n = -1 } byKey[key] = slot end

    local n = select("#", ...)
    local now = _G.GetTime and _G.GetTime() or 0

    if not holdable(n, ...) then
        slot.n, slot.fmt, slot.repeats, slot.at = -1, nil, 0, now
        NS.Debug(tag, fmt, ...)
        return
    end

    if changed(slot, n, fmt, ...) then
        -- The run that just ended gets its count, on its own line, before the
        -- line that ended it.
        if (slot.repeats or 0) > 0 and slot.fmt then
            emitRun(tag, slot, slot.repeats + 1)
        end
        remember(slot, n, fmt, ...)
        slot.repeats, slot.at = 0, now
        NS.Debug(tag, fmt, ...)
        return
    end

    slot.repeats = (slot.repeats or 0) + 1
    if now - (slot.at or 0) >= STEADY_HEARTBEAT then
        emitRun(tag, slot, slot.repeats + 1)
        slot.repeats, slot.at = 0, now
    end
end

NS.DebugSteady = DebugSteady

--- Forget every run, so the next pass of each speaks again.
---
--- Wired to the enable toggle below. NOT wired to the console's Clear button:
--- that lives inside the library and offers the host no hook, so a cleared
--- console can still sit silent until the heartbeat. Worth knowing before
--- reading a cleared log as "nothing is happening"; worth a library seam if it
--- ever bites in practice.
function NS.DebugSteadyReset()
    for fmt in pairs(steady) do steady[fmt] = nil end
end

local lib = LibStub and LibStub("LibKa0s-DebugLog-1.0", true)

if not lib then
    -- A missing vendored lib must degrade, not error at load. The stub covers
    -- EVERY member the addon calls — settings/Slash.lua's `/mm debug` verbs, the
    -- General page's console checkbox, core/PerfSetup.lua's `Add` sink, and the
    -- buffer introspection the suites drive — because a stub that omits one is
    -- not a fallback, it is a crash moved to a rarer code path.
    --
    -- The flag itself still works: NS.State.debug is ours, and a user who types
    -- `/mm debug on` must not be told nothing happened. What is lost is the
    -- WINDOW, and the stub says so once, honestly.
    --
    -- WHAT IS NOT HERE, AND WHY. debug-logging-§3 forbids reproducing the line
    -- format OR its color codes in a fallback, and the format is the half that
    -- matters: a log pasted from any Ka0s addon parses the same way by eye
    -- BECAUSE one library renders it. So the stub renders NO line — it has no
    -- console to render one into, and inventing a shape here would be a second
    -- format to keep in step with the library's. FormatPlain / FormatColored
    -- answer the member (surface parity is what debug-logging-§7 asks for) and
    -- hand back the message unchanged. The ON/OFF words in the ack below are
    -- likewise uncolored: those hexes are the library's string, not this file's
    -- to copy.
    --
    -- The cause half is core/CoreSetup.lua's shared clause (NS.LIBKA0S_MISSING);
    -- only the consequence is this seam's. Do not re-spell the cause here.
    local missing = NS.LIBKA0S_MISSING .. ", so the debug console window is unavailable."
    local announced = false
    local function sayOnce()
        if announced then return end
        announced = true
        if NS.Print then NS.Print(missing) end
    end

    local D
    D = {
        buffer          = {},
        Add             = function() end,
        -- The bare gated sink, matching the live instance's shape exactly: a
        -- plain function taking (tag, fmt, ...), so every call site reads
        -- NS.Debug("Render", "%s", x) on both paths.
        Debug           = function() end,
        Clear           = function() end,
        Show            = function() sayOnce() end,
        Hide            = function() end,
        Toggle          = function() sayOnce() end,
        IsShown         = function() return false end,
        IsEnabled       = function() return NS.State and NS.State.debug or false end,
        RefreshHeader   = function() end,
        ShowCopy        = function() sayOnce() end,
        CopyText        = function() return "" end,
        UpdateScrollBar = function() end,
        UpdateStatus    = function() end,
        BufferSize      = function() return 0 end,
        LastLine        = function() return nil end,
        FindLine        = function() return nil end,
        Text            = function(key) return key end,
        MakeCloseButton = function() return nil end,
        -- The message, verbatim. NOT the library's line — see the note above.
        FormatPlain     = function(_ts, _tag, msg) return tostring(msg) end,
        SetEnabled      = function(_, on)
            on = not not on
            if NS.State then NS.State.debug = on end
            -- The ACK is required (debug-logging-§7): a user who types
            -- `/mm debug on` has to be told it took.
            if NS.Print then NS.Print("debug logging " .. (on and "ON" or "OFF")) end
            if on then sayOnce() end
        end,
        ConsoleCheckbox = function()
            return {
                label   = "Debug console",
                tooltip = missing,
                get     = function() return false end,
                set     = function() sayOnce() end,
            }
        end,
    }
    D.FormatColored = D.FormatPlain
    NS.DebugLog = D
    NS.Debug = D.Debug
    return
end

NS.DebugLog = lib:New({
    -- Seeds MythicMetersDebugWindow / MythicMetersDebugCopyWindow /
    -- MythicMetersDebugCopyScroll. Two hosts sharing a name would clobber each
    -- other's globals and each other's Esc handler.
    name  = addonName,
    -- THE FOLDER NAME, which is a different question from the one above even though
    -- this addon answers both with the same string. `name` seeds frame globals;
    -- `addonName` is what the library builds a texture path from, so its own close,
    -- copy and clear controls can draw this collection's art instead of a
    -- multiplication sign and two words. A vendored library cannot work that out for
    -- itself -- there is no one path to it -- and a host where the two strings
    -- diverge would hand it a path into nowhere, which draws nothing and raises
    -- nothing. Passed explicitly for that reason rather than left to the library to
    -- infer from `name`.
    addonName = addonName,
    -- The library appends its own " — Debug", giving "Ka0s Mythic Meters — Debug".
    title = "Ka0s Mythic Meters",
    font  = NS.Constants and NS.Constants.FONT_MONO,
    slash = "/mm",
    -- fontSize omitted: 10 is the library's default and is this addon's value.

    -- The flag stays ours. NS.State.debug is session-only — never in
    -- SavedVariables, because a console left on across a login is a console
    -- nobody asked for — and it is read by the settings panel and by `/mm debug`,
    -- so a second copy inside the library would be a second truth.
    isEnabled  = function() return NS.State and NS.State.debug or false end,
    -- Toggling the flag also forgets every steady-state run. Without it, logging
    -- turned off and on again resumes mid-comparison: the first pass after the
    -- toggle matches a run the reader never saw and is suppressed, so the console
    -- opens on silence for up to the heartbeat interval — which reads exactly
    -- like the addon doing nothing.
    setEnabled = function(on)
        if NS.State then NS.State.debug = on end
        if NS.DebugSteadyReset then NS.DebugSteadyReset() end
    end,

    -- Both resolved at CALL time rather than captured. core/CoreSetup.lua has
    -- already run, so a captured reference would in fact be correct here — but
    -- the forwarder costs nothing and is what keeps this file's correctness from
    -- depending on a TOC line staying where it is (anti-patterns #36).
    print        = function(line) if NS.Print then NS.Print(line) end end,
    safeToString = function(v) return NS.SafeToString(v) end,

    -- The [Init] line the console brackets a session with. The library owns WHEN
    -- it is emitted — on enable, because the flag is off at login and a load-time
    -- summary would always be gated off — and only we can know what it says.
    initSummary = function()
        local ver     = NS.version or "?"
        local schema  = NS.db and NS.db.global and NS.db.global.schemaVersion or "?"
        local profile = NS.db and NS.db.GetCurrentProfile and NS.db:GetCurrentProfile() or "?"
        return ("MythicMeters v%s, schema v%s, profile '%s'"):format(
            NS.SafeToString(ver), NS.SafeToString(schema), NS.SafeToString(profile))
    end,

    -- The General page's "Debug console" checkbox mirrors the window's
    -- visibility, so a console closed with Esc or opened from `/mm debug` has to
    -- move the checkbox on a settings panel that is already open.
    onVisibilityChanged = function()
        local H = NS.Helpers
        if H and H.RefreshAllPanels then H.RefreshAllPanels() end
    end,
})

-- The addon-wide gated sink (debug-logging-§4), published under the name every
-- call site uses. Bound BARE rather than wrapped: it is a plain function
-- precisely so `NS.Debug("Aggregate", "rows=%d", n)` keeps working with no self
-- and no allocation when the flag is off.
NS.Debug = NS.DebugLog.Debug
