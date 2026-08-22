-- core/MythicMeters.lua
--
-- The AceAddon bootstrap and the addon's single game-event listener.
--
-- Two jobs, and they are related. AceAddon promotes the private namespace that
-- core/Compat.lua and friends have been hanging fields on into the real addon
-- object, which is what gives NS its RegisterEvent / SendMessage / ScheduleTimer
-- methods. Having those, this file becomes the ONE place that listens to the
-- game: every event the addon cares about is registered here and fanned onto the
-- closed message bus (architecture-§4). No module registers a game event of its
-- own, so "the game said something" turns into "the addon knows" in exactly one
-- reviewable place.
--
-- TOC POSITION: second-to-last in the core block, after every one of the five
-- setup files and before core/Database.lua. It must follow core/CoreSetup.lua
-- in particular, because the NS.Print reclaim below repoints NS.Print at the
-- printer object that file published -- AceAddon's AceConsole embed stamps its
-- own :Print over NS.Print during NewAddon, and reclaiming works only because
-- NS.Print and NS.Util.print are the identical function object.

local addonName, NS = ...

-- AceAddon stamps its mixin methods onto NS in place. NS is the private
-- namespace WoW passes as the second vararg to every file, and the core/ files
-- loaded earlier have already hung Compat / Constants / State / Secrets /
-- Database onto this same table. After this call NS IS the addon object — there
-- is NO _G.MythicMeters rebind, and there never will be: the namespace stays
-- private (architecture-§1).
local addon = LibStub("AceAddon-3.0"):NewAddon(
    NS,
    addonName,
    "AceEvent-3.0",
    "AceTimer-3.0",
    "AceConsole-3.0")

-- NewAddon promotes the table it is handed, so `addon` IS `NS`. The field is
-- published anyway because the test harness and the perf descriptor both want a
-- name for "the AceAddon object" that does not assume the promotion happened in
-- place — a detail of AceAddon that could change under us.
NS.addon = addon

-- ---------------------------------------------------------------------------
-- RECLAIM THE PRINTER
-- ---------------------------------------------------------------------------
--
-- AceConsole-3.0's mixin stamps its OWN `:Print` onto the namespace during the
-- NewAddon call above. Anything that then calls NS.Print gets AceConsole's
-- version: green `|cff33ff99...|r`, a trailing colon, and no cyan [MM] tag — no
-- error, and nothing anywhere to say the addon's printer was replaced
-- (architecture-§2, anti-pattern #36).
--
-- So we take the name back, immediately, on the line after NewAddon. NS.Print
-- and NS.Util.print must be the SAME FUNCTION OBJECT, not two wrappers that
-- happen to render alike: a wrapper would drift the moment one of them grew a
-- feature, and a test asserting `NS.Print == NS.Util.print` is the cheapest way
-- to keep the reclaim from being quietly undone by a future refactor.
--
-- The guard covers a broken install where core/CoreSetup.lua never ran; in that
-- case AceConsole's Print is worse than nothing but better than nil, so it is
-- left alone rather than replaced with a stub of our own.
if NS.Util and NS.Util.print then
    NS.Print = NS.Util.print
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function NS:OnInitialize()
    -- Builds the AceDB instance and normalizes the window registry. After this
    -- returns, NS.db is live — a contract every module relies on, and the reason
    -- it is first.
    self:InitDB()

    -- Idempotent after InitDB (which runs the same pass), and called explicitly
    -- so the lifecycle reads as the standard's four steps rather than relying on
    -- a side effect of the one above.
    self:RunMigrations()

    -- The LibDataBroker launcher and its minimap button. AFTER InitDB, and that
    -- ordering is a requirement rather than tidiness: LibDBIcon stores the
    -- button's position in the table it is registered against, which here is
    -- NS.db.profile.minimap — registering before AceDB has built the profile
    -- would hand it a table that is thrown away on the next profile swap.
    -- Reached at call time because modules/ loads after core/, and guarded
    -- because a build without the two vendored broker libs simply has no button.
    if NS.Minimap and NS.Minimap.Init then NS.Minimap.Init() end

    -- The options surface: schema validation, the parent canvas category, and
    -- the queued page builders. Reached at call time because settings/ loads
    -- after core/.
    if NS.CreateOptionsPanel then NS.CreateOptionsPanel() end

    -- `/mm` and `/mythicmeters`. The dispatcher, the help renderer and the
    -- schema CLI are LibKa0s-Slash-1.0's, adopted in settings/Slash.lua; this is
    -- the registration seam.
    if NS.Slash and NS.Slash.Register then
        NS.Slash:Register()
    else
        -- The settings layer never loaded. Claim the verbs anyway and say so:
        -- swallowing `/mm` entirely looks like the addon is not installed, which
        -- sends the player looking in the wrong place.
        local function unavailable()
            local out = (NS.Util and NS.Util.print) or _G.print
            out("slash commands are unavailable — the settings layer failed to load")
        end
        self:RegisterChatCommand("mm", unavailable)
        self:RegisterChatCommand("mythicmeters", unavailable)
    end
end

function NS:OnEnable()
    -- Lifecycle and context. PLAYER_ENTERING_WORLD covers login, /reload and
    -- every zone-in; ZONE_CHANGED_NEW_AREA covers the sub-zone moves that change
    -- an instance's visibility answer without a loading screen.
    self:RegisterEvent("PLAYER_ENTERING_WORLD",  "OnEnteringWorld")
    self:RegisterEvent("GROUP_ROSTER_UPDATE",    "OnRosterUpdate")
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA",  "OnZoneChanged")

    -- The secret-value transition signal. Registered even on a client without
    -- C_RestrictedActions: an event that never fires costs nothing, and the
    -- alternative is a version check that would have to be kept in step with the
    -- one in core/Secrets.lua.
    self:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED", "OnRestrictionChanged")

    -- Feign Death, and nothing else on this event. It is the busiest thing this
    -- addon listens to — every cast by every unit in a raid — and it is
    -- registered because the meter reports a feign as a real death and there is
    -- no other edge that tells us it was one. See modules/Feign.lua.
    self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", "OnSpellSucceeded")

    -- The meter itself.
    self:RegisterEvent("DAMAGE_METER_CURRENT_SESSION_UPDATED", "OnMeterUpdated")
    self:RegisterEvent("DAMAGE_METER_COMBAT_SESSION_UPDATED",  "OnMeterSession")
    self:RegisterEvent("DAMAGE_METER_RESET",                   "OnMeterReset")

    -- Seed the restriction mirror from the live state rather than assuming
    -- "inactive". A /reload taken mid-pull re-enables the addon inside an active
    -- restriction, and ADDON_RESTRICTION_STATE_CHANGED has already fired by then
    -- — there is no second edge to catch.
    if NS.State and NS.Secrets then
        NS.State.SetRestricted(NS.Secrets.IsRestricted())
    end
end

-- ---------------------------------------------------------------------------
-- Event fan-out
-- ---------------------------------------------------------------------------
--
-- Each handler does the minimum translation and republishes. None of them reads
-- a meter value, and none of them decides anything: the window's throttle
-- decides when to rebuild, and modules/Visibility.lua decides whether it should
-- be on screen at all. Keeping the decisions out of here is what lets a reader
-- treat this section as a wiring diagram.

local MSG = NS.Constants.MSG

-- Feign Death. Spelled here as well as in modules/Feign.lua because this handler
-- must not reach into a module to ask a question it can answer with a constant,
-- and because the module may be absent on a degraded load.
local FEIGN_DEATH_SPELL = 5384

function NS:OnEnteringWorld(_, isLogin, isReload)
    self:SendMessage(MSG.ENTERING_WORLD, { isLogin = isLogin, isReload = isReload })
end

function NS:OnRosterUpdate()
    -- The roster cache is derived from a group that just changed shape, so it is
    -- dropped BEFORE the message goes out — a subscriber that rebuilds
    -- synchronously must not be handed the stale map.
    if NS.State then NS.State.WipeCache("Roster") end
    self:SendMessage(MSG.ROSTER_CHANGED)
end

function NS:OnZoneChanged()
    self:SendMessage(MSG.ZONE_CHANGED)
end

--- UNIT_SPELLCAST_SUCCEEDED(unit, castGUID, spellID) — Feign Death only.
---
--- THE ONE HANDLER IN THIS SECTION THAT DECIDES SOMETHING, and it is worth
--- saying why the section's own rule is bent here rather than quietly broken.
--- The decision is "was this cast Feign Death", and there is nowhere else it
--- could be made: no other file may see a game event (architecture-§4), and
--- putting the raw event on the bus would republish every cast in the raid to
--- every subscriber to save one integer comparison.
---
--- So the body stays as small as the question allows — a nil check, one gated
--- comparison, an early return — because it runs on the busiest path here.
---
--- A SECRET SPELL ID IS NOT COMPARED. `spellID == 5384` raises on one, and the
--- honest answer when the comparison is refused is to record nothing: that
--- counts the feign as a death, which is exactly the behaviour that shipped
--- before the filter existed and the safe direction to fail in.
function NS:OnSpellSucceeded(_, unit, _castGUID, spellID)
    if unit == nil or spellID == nil then return end
    if not (NS.Secrets and NS.Secrets.CanCompare(spellID)) then return end
    if spellID ~= FEIGN_DEATH_SPELL then return end

    local F = NS.Feign
    if not (F and F.Note) then return end

    local getGUID = _G.UnitGUID
    if not getGUID then return end
    F.Note(getGUID(unit))
end

--- ADDON_RESTRICTION_STATE_CHANGED(type, state).
---
--- The `Activating` state is the interesting one: it fires BEFORE enforcement
--- begins, and access is still permitted during this dispatch. It is therefore
--- the last moment a correct value-sort can be taken (design §5), which is why
--- the raw state is forwarded rather than collapsed to a boolean here.
function NS:OnRestrictionChanged(_, restrictionType, state)
    if NS.State and NS.Secrets then
        NS.State.SetRestricted(NS.Secrets.IsRestricted())
    end
    self:SendMessage(MSG.RESTRICTION_CHANGED, { type = restrictionType, state = state })
end

-- The three DAMAGE_METER_* handlers are the addon's one hot path — a busy pull
-- fires the first of them far faster than anything needs to redraw — so each
-- carries the `meterEvent` bracket core/PerfSetup.lua declares. The bracket
-- measures the FAN-OUT, not the redraw: the SendMessage call inside it walks
-- every subscribed window's callback synchronously, which is the cost that scales
-- with window count at raid event rate. What each window then does on its own
-- throttle tick is the separate `refresh` bucket.
--
-- NS.Perf is resolved at CALL time, matching NS.ShouldShow below. core/PerfSetup.lua
-- does load before this file, so a load-time upvalue would in fact resolve -- but
-- it would also freeze the stub in place on a degraded install where the library
-- arrives late or is swapped by a test, and this handler is an event path rather
-- than a per-frame one. The lookup is one table index behind an `and`, which is
-- why it stays affordable here.

function NS:OnMeterUpdated()
    local Perf = NS.Perf
    local t0 = Perf and Perf.on and debugprofilestop()
    self:SendMessage(MSG.METER_UPDATED)
    if t0 then Perf.Note("meterEvent", debugprofilestop() - t0) end
end

--- DAMAGE_METER_COMBAT_SESSION_UPDATED(type, sessionID) — the only meter event
--- that carries a payload. Both values are plain, never secret: they identify a
--- session rather than describe one.
function NS:OnMeterSession(_, statType, sessionID)
    local Perf = NS.Perf
    local t0 = Perf and Perf.on and debugprofilestop()
    self:SendMessage(MSG.METER_SESSION, { type = statType, sessionID = sessionID })
    if t0 then Perf.Note("meterEvent", debugprofilestop() - t0) end
end

function NS:OnMeterReset()
    local Perf = NS.Perf
    local t0 = Perf and Perf.on and debugprofilestop()
    if NS.State then NS.State.WipeCache() end
    -- A WIPED SESSION IS A NEW SEGMENT, and "time into the fight" is measured
    -- from here. The client supplies no such clock — core/State.lua records what
    -- was measured — so this stamp is the only anchor there is. Set BEFORE the
    -- message, like the cache wipe above it, so a subscriber that recomputes
    -- synchronously is never handed the previous run's start.
    if NS.State and NS.State.SetSegmentStart then NS.State.SetSegmentStart() end
    self:SendMessage(MSG.METER_RESET)
    if t0 then Perf.Note("meterEvent", debugprofilestop() - t0) end
end

-- ---------------------------------------------------------------------------
-- The show decision
-- ---------------------------------------------------------------------------
--
-- ONE ladder, published here, consulted by every window. It exists as a single
-- ordered function rather than as a set of conditions scattered through the
-- render path so that "why is my window not showing" has one answer with one
-- reading order — and so that suspend cannot be overridden from behind.
--
-- NS.Perf is read at CALL time rather than taken as a load-time upvalue. That is
-- the opposite of the rule for hot paths, and it is correct here for two
-- reasons: the seam may be re-published on a degraded or test install after this
-- file has loaded, so a load-time upvalue could freeze a stale stub; and this
-- ladder runs on context transitions (zone-in, roster change, settings change),
-- not per frame, so the lookup is not in a measured path.

--- Whether `window` should be on screen right now.
---
--- @param window table  a window config from the profile
--- @return boolean show, string reason  the reason names the step that decided,
---   which is what `/mm status` prints and what a test asserts on.
function NS.ShouldShow(window)
    -- STEP 0 — perf suspend. FIRST, and above even the master enable, because a
    -- suspended capture must be inert: nothing — a combat transition, a zone-in,
    -- a settings change — may re-show a window behind suspend's back
    -- (performance-§6).
    local Perf = NS.Perf
    if Perf and Perf.suspended then return false, "suspended" end

    if type(window) ~= "table" then return false, "no window" end

    -- STEP 1 — master enable.
    local profile = NS.db and NS.db.profile
    if not (profile and profile.enabled) then return false, "disabled" end

    -- STEP 2 — test mode. A window in test mode shows regardless of context: the
    -- whole point is to lay a layout out wherever the player happens to be
    -- standing, which is rarely a place the visibility rules would allow.
    --
    -- ONE-WAY. It can force a window ON; it never forces one off — and that
    -- asymmetry is the whole of the fix for `/mm test` appearing to CLOSE the
    -- window. Turning test mode off simply stops forcing, and the ladder below
    -- decides as it always would; what it must not do is make "leave test mode"
    -- and "hide this window" the same keystroke.
    if NS.State and NS.State.testMode then return true, "test" end

    -- STEP 3 — context. modules/Visibility.lua owns the instance / solo /
    -- vehicle rules; it is consulted rather than reimplemented, and its absence
    -- (a partial install) fails OPEN so a broken module cannot make the addon
    -- look uninstalled.
    local Visibility = NS.GetModule and NS:GetModule("Visibility", true)
    if Visibility and Visibility.Allows then
        local ok, reason = Visibility:Allows(window)
        if not ok then return false, reason or "context" end
    end

    return true, "shown"
end
