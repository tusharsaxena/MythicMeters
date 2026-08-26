local addonName, NS = ...

-- settings/OptionsSetup.lua — wires the addon into LibKa0s-Options-1.0.
--
-- The settings-canvas shell, the header and breadcrumb, the lazy Defaults button,
-- the five widget makers, the two-column flow engine, the landing-page builder
-- and the always-shown scrollbar patch live in
-- libs/LibKa0s/{Options,OptionsWidgets,OptionsScroll}.lua. This file is only the
-- part that is ours: where a value lives, which rows belong to which page, and
-- what "reset everything" has to clear that no schema row owns.
--
-- NS.Helpers IS the library instance, decorated in place by the page files with
-- the pieces that did not generalize (options-ui-§1). NEVER a fresh table that
-- copies members across: a page helper added later has to be able to call
-- Helpers.RenderRows like any other page does, and a suite that swaps a member
-- out to spy on it must be swapping the one the library's own callers see.
--
-- TOC POSITION: BEFORE every settings/<page>.lua, because those page files call
-- Helpers members INSIDE schema-row literals at FILE LOAD. See the stub below for
-- what that costs.

-- ---------------------------------------------------------------------
-- The one rule about what a global reset must not touch
-- ---------------------------------------------------------------------
--
-- Profiles rows are AceDBOptions-supplied and resetting them deletes user data,
-- which is not what "restore defaults" means to anyone (options-ui-§3).
--
-- EVERYTHING ELSE IN THE PROFILE IS VETOED TOO, and that is not the loophole it
-- looks like. "Reset all settings" IS a profile reset now -- `afterRestoreAll`
-- below hands the whole thing to AceDB -- so walking the schema first and writing
-- each row's default into the profile would announce CONFIG_CHANGED once per row
-- for values that are about to be discarded whole, and would still leave the
-- extra windows the player wanted gone.
--
-- What the row walk is left with is exactly what a profile reset CANNOT reach:
-- `sessionOnly` rows, whose storage is their own `set()` rather than the db
-- (`state.preview`, `state.debugConsole`). Those have to be restored row by row
-- or they survive a reset that took everything around them.
--
-- Named ONCE because it is enforced TWICE -- by the library through
-- descriptor.skipRestoreAll, and by the degradation stub's own reset loop, which
-- has to keep working with no library at all. Two spellings of one predicate is
-- how a reset ends up deleting profiles on exactly the install nobody tests.
local function vetoedFromResetAll(row)
    if row.page == "profiles" then return true end
    return not row.sessionOnly
end

local lib = LibStub and LibStub("LibKa0s-Options-1.0", true)

local function helpers() return NS.Helpers end

-- ---------------------------------------------------------------------
-- The descriptor
-- ---------------------------------------------------------------------
--
-- Every callback reaches through the schema seam or through `helpers()` at CALL
-- time rather than capturing a member: the page files decorate this instance
-- AFTER this file has run, so a captured reference would be nil forever.

local descriptor = {
    parentTitle   = "Ka0s Multi Meters",
    -- Named rather than anonymous so /framestack attributes the canvas to this
    -- addon and two addons cannot collide on it.
    mainPanelName = "MultiMetersMainPanel",

    print = function(line) if NS.Print then NS.Print(line) end end,
    debug = function(tag, fmt, ...) if NS.Debug then NS.Debug(tag, fmt, ...) end end,

    -- The schema seams — the SAME three settings/Slash.lua passes, so a panel
    -- click and a `/mm set` are one event: same validation, same debug line at
    -- the write seam, same onChange, same refresh (options-ui-§1). The
    -- window-relative path resolution (`window.frame.width` against the active
    -- window) lives behind NS.GetSetting / NS.SetByPath, not here, which is what
    -- lets the panel's window picker retarget every window row by changing one
    -- piece of session state rather than by rewriting paths.
    get          = function(path) return NS.GetSetting and NS.GetSetting(path) or nil end,
    set          = function(path, value) if NS.SetByPath then NS.SetByPath(path, value) end end,
    applyDefault = function(row) if NS.ApplyDefault then NS.ApplyDefault(row) end end,

    -- `filter` is ctx.unit, passed through by the library without interpreting
    -- it. Here it carries the active WINDOW, so one page definition renders the
    -- selected window's rows rather than every window's.
    --
    -- Resolved off NS, not off the library instance: SchemaForPage is
    -- settings/Schema.lua's, and reaching for it on `helpers()` found nothing and
    -- fell through to the inline loop below forever — a silent second grouping
    -- rule that could not follow the schema's. Read at CALL time even though
    -- Schema.lua loads first, so a TOC reshuffle cannot freeze a nil in.
    --
    -- The inline loop stays as the last resort for a half-loaded install (a page
    -- file that raised took RegisterSchemaRows with it), and is deliberately the
    -- same predicate NS.SchemaForPage uses.
    rowsForPage = function(pageKey, filter)
        if NS.SchemaForPage then return NS.SchemaForPage(pageKey, filter) end
        local rows = {}
        for _, row in ipairs(NS.Schema or {}) do
            if row.page == pageKey and not row.hidden then rows[#rows + 1] = row end
        end
        return rows
    end,
    allRows = function() return NS.Schema or {} end,

    skipRestoreAll = vetoedFromResetAll,

    -- RESET ALL SETTINGS IS A PROFILE RESET. The player asked for the equivalent
    -- of a brand-new profile, and that is one call: AceDB empties this profile
    -- (and only this one -- the profile LIST is untouched, which is the rule the
    -- Profiles veto above exists for), the defaults merge back, and
    -- `OnProfileReset` lands on core/Database.lua's OnProfileChanged, which runs
    -- the migrations, re-seeds a single default window through SeedWindows and
    -- publishes PROFILE_CHANGED. Every window, the open panel and the
    -- aggregator's caches rebuild off that one message, exactly as they do for a
    -- profile switch.
    --
    -- It is deliberately DESTRUCTIVE in the one way the old sweep was not: extra
    -- windows are deleted rather than restyled, and window names go back to the
    -- shipped one. That is what "a new profile" means, and the popup asks first.
    --
    -- The row walk above is not a second implementation of this: it is vetoed
    -- down to the sessionOnly rows, which are the only settings NOT in the
    -- profile and therefore the only ones a profile reset cannot reach.
    --
    -- Positions come back for free -- they live in the profile -- so there is no
    -- ResetPositions call here any more. A degraded install with no db has
    -- nothing to reset and says so by doing nothing, which is honest: there is no
    -- storage to restore.
    afterRestoreAll = function()
        local db = NS.db
        if db and db.ResetProfile then db:ResetProfile() end
    end,

    -- Backs the color picker's 50 ms drag throttle. A descriptor field rather
    -- than an AceTimer embed, because embedding would be the library's second
    -- dependency-budget breach. Without it a drag commits every frame — and this
    -- addon has a color row per column, so the omission would be felt.
    scheduleTimer = function(fn, delay)
        if C_Timer and C_Timer.After then C_Timer.After(delay, fn) end
    end,

    getLSM   = function() return LibStub and LibStub("LibSharedMedia-3.0", true) end,
    -- The validator is settings/Schema.lua's — NS.ValidateSchema — and not a
    -- member of the library instance. Read off `helpers()` it was nil, so the
    -- path-resolution and default-agreement checks never ran in game and the one
    -- bug they exist to catch (a row whose writes land on a key nothing reads)
    -- could only ever surface in the headless suite. Resolved at CALL time for the
    -- same reason as rowsForPage above.
    validate = function()
        if NS.ValidateSchema then NS.ValidateSchema() end
    end,

    -- library-stack-§4: resolve AceGUI once and hand it over, so the page
    -- builders read NS.AceGUI instead of each resolving it again.
    onAceGUI = function(AceGUI) NS.AceGUI = AceGUI end,

    -- The landing page. Its command list is GENERATED from NS.COMMANDS through
    -- Sl:LandingRows() — never a second hand-written list, which is how a panel
    -- and a help block drift into disagreeing about what the addon can do.
    --
    -- `rows` is a FUNCTION rather than an array because the library calls it at
    -- render time: a re-render then picks up a verb registered since this spec
    -- was declared, and this file loads before some of them.
    buildMain = function(ctx)
        local H = helpers()
        if not (H and H.BuildLandingPage) then return end
        H.BuildLandingPage(ctx, {
            logo  = NS.Constants and NS.Constants.LOGO,
            -- Through NS.Meta, never by naming C_AddOns here: core/EnvSetup.lua
            -- owns the seam over LibKa0s-Env-1.0 (architecture-§1). The `or ""`
            -- stays: NS.Meta answers nil for a TOC without a `## Notes` line, and
            -- the landing page wants a string.
            notes = function()
                return NS.Meta("Notes") or ""
            end,
            sections = {
                {
                    heading = "Slash commands",
                    rows    = function()
                        return (NS.Slash and NS.Slash.LandingRows
                            and NS.Slash:LandingRows()) or {}
                    end,
                },
            },
        })
    end,

    -- Colors are stored in the keyed { r =, g =, b =, a = } shape, which IS the
    -- library's default. Written out anyway rather than omitted, because the
    -- stored shape is a real contract with the rest of the addon — every bar and
    -- text color read in modules/ unpacks it — and a silent default is a poor
    -- place for a contract to live.
    colorDecode = function(c)
        if type(c) ~= "table" then c = {} end
        return c.r or 1, c.g or 1, c.b or 1, c.a or 1
    end,
    colorEncode = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 1 } end,
}

-- ---------------------------------------------------------------------
-- The degradation stub — LOAD-COMPLETING, not member-answering
-- ---------------------------------------------------------------------
--
-- Every other setup file in this addon degrades to a table whose members each
-- print an honest "not installed" line. This one MUST NOT, and the reason is not
-- importance but WHEN the missing code is reached (options-ui-§1, the documented
-- exception).
--
-- The page files evaluate Helpers members INSIDE schema-row literals, at FILE
-- LOAD — `H.LSMValues("font")` on every text row, `H.ColumnValues()` on the
-- Columns page. With those members nil the page file RAISES, so its
-- RegisterSchemaRows never runs, so a third of NS.Schema is simply missing — and
-- `/mm list`, `/mm get`, `/mm set`, `/mm reset` and the profile defaults all
-- break with it, silently. The addon would not degrade; it would half-load and
-- say nothing.
--
-- So this branch's job is to let every page file FINISH LOADING. Members reached
-- at load are real enough to return a usable value; members reached from a
-- builder or a user action are no-ops, because by then there is no panel to draw
-- into and a no-op is honest.
--
-- Note what is NOT here: no widget maker, no flow engine, no header, and none of
-- the library's LAYOUT constants. A host copy of a library constant is the copy
-- that goes stale, and hand-copying the code whose drift the extraction exists to
-- end is the one duplicate testing-§8 most specifically forbids.
if not lib then
    -- The cause half is core/CoreSetup.lua's shared clause (NS.LIBKA0S_MISSING);
    -- only the consequence is this seam's.
    local MISSING = NS.LIBKA0S_MISSING .. ", so the settings panel is unavailable."

    local Helpers = {}
    NS.Helpers = Helpers

    -- Reached at LOAD, from inside schema-row literals, so these have to answer
    -- with something a row can hold rather than with nil.
    --
    -- LSMValues is a DEFERRED closure on the live path — the media hash is pulled
    -- at dropdown-render time, because the addons that register media have not
    -- run when a row is declared. The stub keeps the deferral and answers a
    -- single placeholder, for the same reason the library never answers empty: a
    -- dropdown with no options cannot be opened, and the CLI would then refuse
    -- even the value already stored.
    Helpers.LSMValues = function() return function() return { None = "None" } end end

    -- Reached only from a builder or a user action, so a no-op is honest.
    for _, name in ipairs({
        "CreatePanel", "EnsureDefaultsButton", "EnsureScroll", "ClearScroll", "Section",
        "AddSpacer", "TextRow", "BuildLandingPage", "AttachTooltip", "InlineButtonPair",
        "RenderField", "RenderRows", "RenderSchema", "RenderGrid", "SessionCheckbox",
        "SetRenderer", "RefreshAllPanels", "RefreshScalars", "RefreshPanel", "RestoreDefaults",
        "PatchAlwaysShowScrollbar", "RegisterOptionsPage", "CreateOptionsPanel",
    }) do
        Helpers[name] = function() end
    end
    Helpers.__pages    = function() return {} end
    Helpers.__panels   = function() return {} end
    Helpers.__panelFor = function() return nil end

    -- Kept REAL even though it is call-time: the user whose panel will not open
    -- is exactly the user who needs "reset everything", and the schema loaded
    -- fine, so the reset still works with no panel at all. It uses the same
    -- vetoedFromResetAll predicate the descriptor does, so a profiles row is safe
    -- on both paths rather than on the one somebody remembered.
    Helpers.RestoreAllDefaults = function()
        for _, row in ipairs(NS.Schema or {}) do
            if not vetoedFromResetAll(row) and NS.ApplyDefault then
                NS.ApplyDefault(row)
            end
        end
        if descriptor.afterRestoreAll then descriptor.afterRestoreAll() end
    end

    NS.RegisterOptionsPage = function() end
    NS.RefreshOptionsPanel = function() end
    NS.CreateOptionsPanel  = function()
        if NS.Print then NS.Print(MISSING) end
    end
    -- The one member a user actually reaches for. Same function as
    -- CreateOptionsPanel: there is nothing to create and nothing to open, and one
    -- honest line answers both.
    NS.OpenOptionsPanel = NS.CreateOptionsPanel
    return
end

-- ---------------------------------------------------------------------
-- The live wiring
-- ---------------------------------------------------------------------

NS.Helpers = lib:New(descriptor)

local Helpers = NS.Helpers

NS.RegisterOptionsPage = function(key, name, builder) Helpers.RegisterOptionsPage(key, name, builder) end
NS.CreateOptionsPanel  = function() Helpers.CreateOptionsPanel() end

-- OpenOptionsPanel REFUSES under combat lockdown and never defers-and-replays —
-- the library owns that refusal, and it is the standard's one documented
-- exception to "gate and defer" (options-ui-§1). A panel that opened three
-- seconds after the pull ended, because the user asked for it mid-pull and the
-- addon queued it, is a window nobody asked for at a moment nobody wanted it.
NS.OpenOptionsPanel = function() Helpers.OpenOptionsPanel() end

-- AceDB profile changes call this so any open page re-reads its values, and so do
-- `/mm set`, `/mm reset` and `/mm resetall` through the write seam.
NS.RefreshOptionsPanel = function() Helpers.RefreshAllPanels() end
