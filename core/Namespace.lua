-- core/Namespace.lua
--
-- The addon's identity, and the one factory every message-bus consumer goes
-- through. Nothing here has a side effect: no frame, no event registration, no
-- SavedVariables read. That is deliberate — this file loads near the top of the
-- core block, so anything it did would happen before the addon has decided
-- whether it is even going to run.
--
-- WHY IT IS NOT core/Constants.lua. Constants owns values the DISPLAY reasons
-- about (the stat catalog, the shipped font, the bus names). This file owns who
-- the addon IS — name, version, chat tag — plus the bus-target factory, which is
-- infrastructure rather than a value. Keeping them apart means a reader chasing
-- "what is this addon called" and a reader chasing "which stats can it show"
-- never open the same file.
--
-- TOC POSITION: third in the core block — Compat, then Constants, then this
-- file. The hard constraint is Compat FIRST, because resolveVersion() below runs
-- at load and reads the TOC manifest through Compat.GetAddOnMetadata rather than
-- touching C_AddOns directly (architecture-§1: every cross-patch call lives in
-- Compat). Constants sitting ahead of this file is fine in both directions:
-- Constants reads nothing this file publishes, and nothing here reads
-- NS.Constants. Everything AFTER this point — State, Secrets, CoreSetup,
-- PerfSetup, DebugLogSetup, LSMPatch, MythicMeters, Database, and all of
-- modules/ and settings/ — may read NS.PREFIX / NS.name / NS.version at load
-- time, so this file must stay above them.

local addonName, NS = ...

-- Chat tag prepended to every user-facing chat line (slash-commands-§4). Single
-- source of truth: core/CoreSetup.lua hands the printer a FUNCTION that re-reads
-- this field, so a later retag is never frozen into the printer. Cyan is the
-- collection's mandated tag color; the bracketed short form is the addon's slash
-- verb in caps, matching /mm.
NS.PREFIX = "|cff00ffff[MM]|r"

-- Gray color opener for de-emphasized "notice" chat lines — something the user
-- should see but not be alarmed by (options-ui-§2). Wrap the message BODY only
-- (`GRAY .. text .. "|r"`); the cyan [MM] tag stays full-color. The canonical
-- consumer is the options-panel combat refusal, which declines rather than
-- defers.
NS.GRAY = "|cff9d9d9d"

-- The folder name, which is also the AceAddon name, the SavedVariables stem and
-- the Interface\AddOns path segment. Taken from the vararg rather than written
-- out so a rename cannot leave one of the four behind.
NS.name = addonName

-- Fallback version stamp, used only when the TOC manifest cannot be read (an
-- older client without C_AddOns, or the headless test harness where there is no
-- manifest at all). The manifest is the better source because it cannot drift
-- from the packaged build (slash-commands-§3) — a hand-edited constant can.
local FALLBACK_VERSION = "0.1.0"

--- Resolved once at load: the packaged version if the client can tell us, the
--- literal above otherwise. Read by `/mm version`, the perf descriptor's record
--- stamp and the options panel header.
---
--- Resolved HERE rather than lazily because LibKa0s-Perf-1.0 takes `version` as
--- a plain string at :New time and cannot defer it — a nil here stamps every
--- capture record "v?", which is unattributable the moment it leaves the session
--- (performance-§8).
local function resolveVersion()
    local Compat = NS.Compat
    local v = Compat and Compat.GetAddOnMetadata and Compat.GetAddOnMetadata(addonName, "Version")
    if type(v) == "string" and v ~= "" then return v end
    return FALLBACK_VERSION
end

NS.version = resolveVersion()

-- Kept as its own field so a caller that genuinely wants "what the source says"
-- (a test asserting the fallback path, a bug report comparing the two) can ask
-- for it without re-deriving the literal.
NS.FALLBACK_VERSION = FALLBACK_VERSION

--- A fresh AceEvent-embedded table for a message-bus / event RECEIVER
--- (architecture-§4).
---
--- Any consumer that is NOT itself an AceAddon module — a window instance, the
--- settings panel, the aggregator's throttle — MUST own a private target from
--- this factory rather than registering on the shared addon object.
--- CallbackHandler keys callbacks by (message, target), so two receivers of one
--- message registered on the SAME object silently clobber each other and only
--- the last registrant ever fires (anti-pattern #32). This addon is especially
--- exposed to that: every window subscribes to the same refresh messages, and
--- there can be many windows.
---
--- @return table|nil  an AceEvent-embedded table, or nil when AceEvent-3.0 is
---   absent (a broken install — callers treat that as "no bus" and degrade).
function NS.NewBusTarget()
    local AceEvent = LibStub and LibStub("AceEvent-3.0", true)
    if not AceEvent then return nil end
    local target = {}
    AceEvent:Embed(target)
    return target
end
