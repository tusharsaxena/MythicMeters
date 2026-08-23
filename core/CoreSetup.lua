local addonName, NS = ...   -- luacheck: ignore addonName
NS.Util = NS.Util or {}
local Util = NS.Util

-- core/CoreSetup.lua — wires the addon into LibKa0s-Core-1.0.
--
-- Two seams come from the library, and both are things this addon would otherwise
-- have grown a private lookalike of:
--
--   * the SECRET-SAFE seam. A value WoW protects in combat survives tostring()
--     and the `..` operator and raises only inside table.concat, so a detector
--     has to probe the operation that actually rejects it. That matters more here
--     than in any other Ka0s addon: every number this addon displays comes off
--     C_DamageMeter and is secret for the whole of a pull, so a chat line, a debug
--     line or an error message carrying one is not an edge case — it is Tuesday.
--     NS.IsConcatSafe / NS.SafeToString are how anything outside core/Secrets.lua
--     is allowed to look at such a value at all, and even they only look far
--     enough to decide whether it can be rendered.
--
--   * the WINDOW CHROME seam. Core.SKIN is the Ka0s window edge, adopted
--     normatively by the standard (standalone-windows) after five debug consoles
--     side by side split into two looks. modules/Window.lua takes the meter
--     window's edge from NS.ApplySkin below rather than agreeing with Core.SKIN
--     by value — agreement by value is a copy, and a copy drifts one hex digit at
--     a time.
--
-- PUBLISHED AS BOTH NS.Print AND NS.Util.print, AND THEY ARE THE SAME OBJECT.
-- core/MultiMeters.lua embeds AceConsole-3.0 into NS via AceAddon:NewAddon,
-- which stamps AceConsole's own `:Print` over NS.Print — green, trailing colon,
-- no cyan tag, no error and nothing to say so (anti-patterns #36). That file
-- reclaims the key afterwards by reading it back off NS.Util.print, and the
-- reclaim only restores the LIBRARY printer because the two names hold one
-- identical function object rather than two wrappers around it.
--
-- TOC POSITION. Three constraints bind:
--   AFTER  core/Constants.lua   — NS.PREFIX is the tag. Belt and braces: the
--                                 prefix is handed over in the FUNCTION form
--                                 below anyway, so it is re-read on every call.
--   BEFORE core/MultiMeters.lua — its AceConsole reclaim reads NS.Util.print.
--   FIRST of the five LibKa0s seams — NS.LIBKA0S_MISSING is set here and the
--                                 other four append their own consequence to it.

-- The ONE cause clause, shared by every seam that has to explain the same
-- absence: this file, core/PerfSetup.lua, core/DebugLogSetup.lua,
-- settings/Slash.lua and settings/OptionsSetup.lua. Each appends its own
-- "so <what> is unavailable" and its own terminal punctuation, so a degraded
-- install says the same thing about WHY five times and a different thing about
-- WHAT each time. Keep the phrasing byte-identical across the collection apart
-- from the addon name.
--
-- Set OUTSIDE the branch below because the seams that read it are reached on
-- BOTH paths — a half-vendored libs/LibKa0s can have Core.lua present and
-- Perf.lua missing — and set HERE because this file is the first of the five the
-- TOC loads.
NS.LIBKA0S_MISSING = "The LibKa0s library is missing from this installation of Ka0s Multi Meters " ..
    "(expected in libs/LibKa0s)"

-- The stored-color reader's fallback, defined ONCE and above the branch because
-- BOTH paths need it: a missing libs/LibKa0s has no RGBA at all, and a vendored
-- Core older than minor 4 answers the major but not this member. Publishing it
-- from here is what stops modules/Window.lua and modules/Row.lua each doing their
-- own LibStub lookup and each carrying their own hand-copied channel reader —
-- three copies of one library behavior, in the addon whose file header says
-- degradation is this file's job.
--
-- Both persisted shapes are read, because the collection ships both and neither
-- can be retired without migrating users' SavedVariables: keyed
-- `{ r =, g =, b =, a = }` (the Slash value parser's output) and positional
-- `{ r, g, b, a }` (what the Ka0s options color widget writes). Presence of any
-- of r/g/b makes the keyed shape win for all four channels, so `{ r = 1 }` cannot
-- borrow its green from c[2]. Channels fall back INDEPENDENTLY and absence is
-- tested with `== nil` rather than `or`, so a stored 0 survives as 0.
local function fallbackRGBA(c, dr, dg, db, da)
    if type(c) ~= "table" then return dr, dg, db, da end
    local r, g, b, a
    if c.r ~= nil or c.g ~= nil or c.b ~= nil then
        r, g, b, a = c.r, c.g, c.b, c.a
    else
        r, g, b, a = c[1], c[2], c[3], c[4]
    end
    if r == nil then r = dr end
    if g == nil then g = dg end
    if b == nil then b = db end
    if a == nil then a = da end
    return r, g, b, a
end

local lib = LibStub and LibStub("LibKa0s-Core-1.0", true)

if not lib then
    -- A missing vendored lib must degrade, not error at load. Silence is not an
    -- option the way it is for a diagnostics harness: the printer is how the
    -- slash CLI answers, how the schema validator reports and how the
    -- meter-unavailable path explains itself, and a nil printer would take all
    -- three with it.
    --
    -- So the fallbacks WORK — they are the pre-library implementations, kept
    -- short — and the honest "it is not installed" line is said ONCE, on the
    -- first line the addon prints, rather than stapled to every one of them.
    --
    -- The concat probe is reproduced here even though a stub "must not
    -- re-implement the library", because a probe is not rendering: it is the
    -- difference between a chat line and a Lua error on a coalesced refresh
    -- ticker, and this addon's values are secret for the whole of a pull. What is
    -- deliberately NOT copied is any FORMAT — no row shape, no key/value
    -- coloring, no console line.
    local function probeConcat(v) return table.concat({ v }) end

    function NS.IsConcatSafe(v)
        return (pcall(probeConcat, v))
    end

    function NS.SafeToString(v)
        if v == nil then return "nil" end
        if type(v) == "boolean" then return tostring(v) end
        if NS.IsConcatSafe(v) then return tostring(v) end
        return "<secret>"
    end

    local announced = false
    local function emit(line)
        if not DEFAULT_CHAT_FRAME then return end
        if not announced then
            announced = true
            DEFAULT_CHAT_FRAME:AddMessage(NS.SafeToString(NS.PREFIX) .. " " ..
                NS.LIBKA0S_MISSING .. "; running on reduced built-in fallbacks.")
        end
        DEFAULT_CHAT_FRAME:AddMessage(line)
    end

    local function fallbackPrint(...)
        local parts = { NS.SafeToString(NS.PREFIX) }
        for i = 1, select("#", ...) do parts[i + 1] = NS.SafeToString((select(i, ...))) end
        emit(table.concat(parts, " "))
    end

    -- ONE function object under both names, exactly as on the live path — the
    -- AceConsole reclaim in core/MultiMeters.lua compares them.
    NS.Print   = fallbackPrint
    Util.print = fallbackPrint

    function NS.Format(fmt, ...)
        local n = select("#", ...)
        if n == 0 then return fallbackPrint(fmt) end
        local parts = {}
        for i = 1, n do parts[i] = NS.SafeToString((select(i, ...))) end
        fallbackPrint(NS.SafeToString(fmt):format(unpack(parts)))
    end

    -- The window edge degrades to NOTHING rather than to a hand-copied backdrop.
    -- Core.SKIN's values ARE the contract (standalone-windows), and a host copy
    -- of them is the copy that goes stale one hex digit at a time — which is the
    -- precise duplicate the extraction exists to end. Core's own ApplySkin is
    -- already a no-op on a frame with no SetBackdrop, on the stated view that
    -- undecorated is not broken; a degraded install gets the same deal.
    --
    -- SKIN is an empty TABLE rather than nil so modules/Window.lua may index it
    -- without a guard at every field, and MakeCloseButton answers nil — exactly
    -- what Core's own does where CreateFrame is unavailable, so the caller's
    -- existing nil check is the only one it needs.
    NS.SKIN            = {}
    NS.ApplySkin       = function() end
    NS.MakeCloseButton = function() return nil end
    -- Unlike SKIN, the color reader does NOT degrade to nothing: it is not chrome
    -- the user can live without, it is how every bar and every label gets its
    -- color out of the profile at all, and a degraded install still renders rows.
    NS.RGBA            = fallbackRGBA
    return
end

-- ── the live seam ────────────────────────────────────────────────────────────

-- Lib-level and stateless, so they are published by reference rather than
-- wrapped. `lib.SECRET` is the "<secret>" sentinel the suites name.
NS.IsConcatSafe = lib.IsConcatSafe
NS.SafeToString = lib.SafeToString

-- `lib.RGBA(c, dr, dg, db, da) -> r, g, b, a` arrived at Core minor 4, and a
-- vendored copy older than that answers the major without the member — so the
-- fallback stands behind it here too. modules/Window.lua and modules/Row.lua read
-- NS.RGBA and never LibStub for themselves: one lookup, one degradation decision,
-- in the file that owns both.
NS.RGBA = lib.RGBA or fallbackRGBA

-- The shared Ka0s window edge (standalone-windows). modules/Window.lua reaches
-- the edge through these three names — never through a private lookalike and
-- never by restating Core.SKIN's values — so a re-skin lands on the meter window,
-- the debug console and the perf panel at once. Published as flat NS members
-- because the degraded branch above owes the caller the same three names.
--
-- SKIN is exported alongside ApplySkin rather than kept private: a window that
-- wants only the backdrop color for a sub-region (a header strip, a row
-- highlight) must read it from here, not guess it.
NS.SKIN            = lib.SKIN
NS.ApplySkin       = lib.ApplySkin
-- WRAPPED, TO SAY WHO IS ASKING. LibKa0s draws its own `close` icon when it is
-- told which addon folder to build a texture path from, and the library cannot
-- work that out for itself: it is vendored, so there is no one path to it and a
-- copy cannot know which folder it was copied into. `addonName` is that answer,
-- and this file has it as its first vararg.
--
-- Every close control in this addon comes through here -- the export modal, its
-- copy window -- so one wrapper puts the same mark on all of them, and the
-- header strip's own close (modules/HeaderControls.lua, which builds its own)
-- already drew it. Without the name the library falls back to a multiplication
-- sign, which is exactly what a degraded install should get.
NS.MakeCloseButton = function(parent, onClick)
    return lib.MakeCloseButton(parent, onClick, addonName)
end

-- The prefix is handed over as a FUNCTION rather than as the value of NS.PREFIX.
-- It reads the same here, where core/Constants.lua has already run — but the
-- printer is built once at load, and the function form is what keeps a later
-- change to NS.PREFIX (a test swapping it, a profile-driven retag) from being
-- frozen out. `sep` is left at its default single space: NS.PREFIX is
-- "|cff00ffff[MM]|r" with no trailing space of its own.
local printer = lib:New({
    prefix = function() return NS.PREFIX end,
})

-- Plain functions, never methods — call sites do `local print = NS.Print` at file
-- scope and call it bare, so neither may need a `self`.
--
-- THE SAME OBJECT under both names. See the header: core/MultiMeters.lua's
-- AceConsole reclaim restores NS.Print from NS.Util.print, and it only restores
-- the library printer because these two assignments share one function.
NS.Print   = printer.Print
Util.print = NS.Print
NS.Format  = printer.Format
