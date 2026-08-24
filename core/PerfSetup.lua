local addonName, NS = ...

-- core/PerfSetup.lua — wires the addon into LibKa0s-Perf-1.0.
--
-- The probe, the guided A/B run, the record schema and the clickable step panel
-- are the library's. This file supplies the part only this addon can know: which
-- paths are worth measuring, and what "inert" means here.
--
-- TOC POSITION: seventh in the core block — after core/CoreSetup.lua, before
-- core/DebugLogSetup.lua — and BEFORE every module that takes
-- `local Perf = NS.Perf` as a load-time upvalue (all of modules/, which loads
-- after core/). That last constraint is the binding one. Two others are worth
-- stating because they are not symmetrical:
--   * core/Namespace.lua has run, so NS.version exists — the descriptor takes
--     `version` as a plain STRING resolved once at :New, so a file sitting higher
--     in the block would capture nil and stamp every capture record "v?",
--     unattributable the moment it leaves the session (performance-§8). This is
--     a HARD constraint: move this file above Namespace and captures go anonymous.
--   * core/DebugLogSetup.lua has NOT run yet, and that is fine. Every seam that
--     reaches the console — `log`, `showLog`, `decorate` — resolves NS.DebugLog
--     inside its own closure at CALL time rather than capturing it here, so the
--     sink is found the moment it exists. Do not "optimize" those into upvalues.
--
-- WHERE THE SIGNAL IS, and why the bucket list looks like this. This addon has
-- exactly one hot path and it is event-driven rather than per-frame: a busy pull
-- fires DAMAGE_METER_CURRENT_SESSION_UPDATED far faster than anything needs to
-- redraw, which is why the window coalesces to an interval instead of refreshing
-- per event. So the two questions a capture has to answer are "how much does the
-- event handler itself cost at raid rate" (meterEvent) and "what does one
-- coalesced pass cost" (refresh) — and the three buckets under `refresh` say
-- which third of that pass to look at: reading the columns off C_DamageMeter,
-- joining them by GUID and ordering them, or drawing.
--
-- `renderRow` nests inside `render` rather than beside it because a 20-player
-- group times 7 columns is 140 cells per pass, and per-row is the only grain at
-- which "the window is slow" becomes "the window is slow because of how many rows
-- it has". A reader comparing two captures months apart cannot be expected to
-- know which totals overlap, so the nesting is DECLARED rather than left as
-- prose, and a parent must never be summed with its children.

local lib = LibStub and LibStub("LibKa0s-Perf-1.0", true)

if not lib then
    -- A missing vendored lib must degrade, not error at load. The addon's own
    -- function is unaffected by the absence of a diagnostics harness, but the
    -- stub has to cover EVERY member the addon reaches: the hot-path gate `on`
    -- and sink `Note`, the `suspended` flag every show decision consults as step
    -- 0 of its ladder, and OnCommand — because `/mm perf` is registered
    -- unconditionally in settings/Slash.lua, so something has to answer it.
    --
    -- `Open`/`Close` are answered too. Nothing in this addon uses Shape B today
    -- (the inline Shape A form is mandatory on anything running per refresh), but
    -- a stub that omits a member is not a fallback — it is a crash moved to a
    -- rarer code path.
    NS.Perf = {
        on        = false,
        suspended = false,
        Note      = function() end,
        Open      = function() end,
        Close     = function() end,
        -- The cause half is core/CoreSetup.lua's shared clause
        -- (NS.LIBKA0S_MISSING); only the consequence is this seam's. Read at
        -- CALL time rather than captured into a load-time local, so the TOC
        -- order of the two setup files can never freeze a nil in.
        OnCommand = function()
            return { NS.LIBKA0S_MISSING .. ", so performance measurement is unavailable." }
        end,
    }
    return
end

--- Resolve one runtime module at CALL time, never hoisted: this file loads before
--- modules/, so a load-time lookup would answer nil forever.
---
--- Both shapes are tried because the module layer is free to be either an
--- AceAddon child module or a plain NS table, and suspend must not be the file
--- that pins that choice.
local function mod(name)
    local m = NS[name]
    if m then return m end
    if NS.GetModule then return NS:GetModule(name, true) end
    return nil
end

NS.Perf = lib:New({
    name    = addonName,
    title   = "Ka0s Multi Meters",
    slash   = "/mm",
    sv      = "MultiMetersPerfDB",
    -- The TOC manifest is the better source than the in-code constant: it cannot
    -- drift from the packaged build (slash-commands-§3). NS.version remains the
    -- fallback for a client without the metadata API.
    --
    -- Both are resolved by NS.Version() — core/EnvSetup.lua's seam over
    -- LibKa0s-Env-1.0 (architecture-§1) — rather than by an inline ladder here.
    -- That inline ladder is what this file used to carry, and re-spelling it was
    -- how a call site quietly dropped the pre-11.x rung. settings/Slash.lua asks
    -- the same function, so `/mm version` and a capture record cannot disagree.
    version = NS.Version(),

    -- Ordered for the report, with nesting declared. These keys are the contract
    -- the module layer brackets against — a bracket naming a key that is not here
    -- still records, it just never appears in the report, which is the quiet
    -- failure mode this list exists to prevent.
    buckets = {
        { key = "meterEvent" },                          -- a DAMAGE_METER_* event handler
        { key = "refresh" },                             -- one coalesced window refresh pass
        { key = "providerRead", within = "refresh" },    -- one C_DamageMeter column read
        { key = "aggregate",    within = "refresh" },    -- GUID join + ordering
        { key = "render",       within = "refresh" },    -- window render
        { key = "renderRow",    within = "render"  },    -- one row's cells
        { key = "tooltip" },                             -- a tooltip build
        -- Nested under `tooltip`, because that is the only thing that triggers
        -- one — and because it is the expensive half: modules/Targets.lua makes
        -- a provider call PER ENEMY to reconstruct a list the API does not carry.
        -- Its own bucket precisely so the cost of the Targets section is separable
        -- from the cost of the tooltip that holds it.
        { key = "targets",      within = "tooltip" },    -- the target cross-reference
    },

    --- Make the addon inert without a /reload.
    ---
    --- Reloading, or disabling the addon through the AddOns list, shifts
    --- shared-frame ownership — the exact confound that makes the built-in
    --- profiler untrustworthy for this question. So the flip has to happen in
    --- place, live, mid-session.
    ---
    --- Three things have to stop, and they are three because the addon has three
    --- independent sources of work:
    ---   1. the meter events. Provider owns every C_DamageMeter registration, so
    ---      its Suspend is what stops the reads at the source rather than letting
    ---      them run and discarding the result.
    ---   2. the coalescing timer. A pass already queued when suspend lands would
    ---      otherwise fire once more, inside measurement window B, and be
    ---      attributed to an addon that is supposed to be doing nothing.
    ---   3. visibility. NOT enforced by hiding frames from here
    ---      (performance-§6): Visibility's own show decision reads
    ---      NS.Perf.suspended as step 0 of its ladder, so nothing — a combat
    ---      transition, a roster change, a settings write — can re-show a window
    ---      behind suspend's back. Refreshing it here is what makes the already
    ---      shown windows act on that step now rather than at the next event.
    suspend = function()
        local provider = mod("Provider")
        if provider and provider.Suspend then provider:Suspend() end

        local wm = mod("WindowManager")
        if wm and wm.Suspend then wm:Suspend() end

        local vis = mod("Visibility")
        if vis and vis.Refresh then vis:Refresh() end
    end,

    --- Restore everything suspend took away, from CURRENT state: each module's
    --- Resume rebuilds its registrations from the columns and windows enabled
    --- NOW, so a column toggled or a window created while suspended comes back
    --- correctly (performance-§6).
    ---
    --- No CONFIG_CHANGED is published from here. The modules' own Resume paths
    --- re-register and re-render, so this file does not become a second sender of
    --- a message the bus already has an owner for.
    resume = function()
        local provider = mod("Provider")
        if provider and provider.Resume then provider:Resume() end

        local wm = mod("WindowManager")
        if wm and wm.Resume then wm:Resume() end

        local vis = mod("Visibility")
        if vis and vis.Refresh then vis:Refresh() end
    end,

    -- Perf output is deliberately NOT gated on NS.State.debug, unlike NS.Debug.
    -- That gate keeps the addon free when idle; a perf run is explicit user
    -- action and none of it executes unless someone typed `/mm perf start`.
    -- Gating it meant a user who started a run without first enabling debug
    -- logging watched a console that stayed empty while a capture plainly ran.
    log = function(line)
        if NS.DebugLog and NS.DebugLog.Add then
            NS.DebugLog:Add("Perf", line)
        elseif NS.Print then
            NS.Print(line)
        end
    end,

    print = function(line) if NS.Print then NS.Print(line) end end,

    -- `start`, `report` and `dump` want the console in front of the user.
    -- Everything else must not pop it open: a lifecycle line mid-pull is the last
    -- moment to throw a window on screen.
    showLog = function()
        if NS.DebugLog and NS.DebugLog.Show and not NS.DebugLog:IsShown() then
            NS.DebugLog:Show()
        end
    end,

    -- NO `L`, deliberately, and this is a trap rather than an omission.
    --
    -- NS.L carries the metatable fallback the standard mandates: a miss returns
    -- the KEY rather than nil, so NS.L["STEP_START"] is the string "STEP_START".
    -- Handing the library an addon-wide locale table satisfies its override check
    -- for EVERY key, its own strings become unreachable, and the panel renders
    -- STEP_START / STEP_MEASURE_A / PANEL_TITLE_SUFFIX verbatim — visible only in
    -- game. This addon has no perf translations, so it passes nothing and lets
    -- the library's English through.

    -- NO `decorate`, DELIBERATELY, and its absence is the fix rather than an
    -- omission.
    --
    -- This addon shipped one, and its entire body was a close button. It called
    -- `NS.DebugLog.MakeCloseButton(frame, api.Hide)` — two arguments onto a
    -- three-argument function — so the panel drew a multiplication sign while the
    -- console two inches away wore the collection's mark. The dropped third
    -- argument is the addon folder name, and a texture path that is never built
    -- draws nothing and raises nothing: luacheck was clean, 1,206 tests were green,
    -- and the only witness was a screenshot.
    --
    -- From PerfPanel minor 4 (LibKa0s v1.10.2) the library builds that control
    -- itself, from `addonName or name` — and `name` above IS this file's first
    -- vararg — at the same 18px inset from the same corner. So the hook was a
    -- second copy of library behavior that could fall behind it, and had; deleting
    -- it is what the standard now asks for (performance-§4, debug-logging-§12,
    -- anti-pattern #65).
    --
    -- Add one back only for chrome the library does not draw, and build its close
    -- control through `NS.MakeCloseButton` (core/CoreSetup.lua) — the one wrapper
    -- that carries the folder name — never with a bare call to any factory.
})
