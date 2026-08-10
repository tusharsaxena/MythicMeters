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
    setEnabled = function(on) if NS.State then NS.State.debug = on end end,

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
