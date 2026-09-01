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
-- TOC POSITION: after Compat, EnvSetup, MediaSetup and Constants in the core
-- block. The hard constraint is core/EnvSetup.lua FIRST, because resolveVersion()
-- below runs at load and reads the TOC manifest through NS.Meta — the
-- LibKa0s-Env-1.0 seam — rather than touching C_AddOns directly (architecture-§1:
-- every cross-patch call lives behind a seam). Constants sitting ahead of this
-- file is fine in both directions:
-- Constants reads nothing this file publishes, and nothing here reads
-- NS.Constants. Everything AFTER this point — State, Secrets, CoreSetup,
-- PerfSetup, DebugLogSetup, LSMPatch, MultiMeters, Database, and all of
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

--- One player's class color as three plain numbers, or nil when the class is not
--- known.
---
--- ONE READER FOR ALL FOUR SURFACES that can wear a class color: the bars and the
--- name in modules/Row.lua, that file's cell text under `text.classColor`, the
--- header lines in modules/Window.lua under `header.classColor` /
--- `columnHeader.classColor`, and the tooltip under `tooltip.classColor`. Four
--- private lookups into RAID_CLASS_COLORS is the duplicate that drifts the first
--- time one of them grows a fallback the others do not have.
---
--- `classFilename` is the token WoW's own table is keyed by ("MAGE", "PRIEST")
--- and is NeverSecret, which is what makes a class color legal to compute at the
--- height of a pull when every number beside it is opaque (design §4).
---
--- NIL IS AN ANSWER, never a tenth color. An unknown class means "no class
--- information", and every caller decides for itself what to draw instead --
--- white for a name, the shared neutral for a bar, the configured color for a
--- line of text. Substituting one here would make that decision for all of them.
---
--- The global is read at CALL time, not captured: RAID_CLASS_COLORS is Blizzard's
--- and this file loads early.
---
--- @param classFilename string|nil
--- @return number|nil r, number|nil g, number|nil b
function NS.ClassRGB(classFilename)
    if type(classFilename) ~= "string" then return nil end
    local classes = _G.RAID_CLASS_COLORS
    local c = classes and classes[classFilename]
    if not c then return nil end
    return c.r, c.g, c.b
end

--- One statistic's color as three plain numbers, or nil when the key has none.
---
--- ONE READER FOR EVERY SURFACE THAT WEARS THE PALETTE, exactly as ClassRGB above
--- is for class colors, and added for the same reason: the palette became a
--- SETTING (General -> Statistic colors), and five files each doing their own
--- `Const.STAT_COLORS[key]` would have been five surfaces that ignored it.
---
--- THE CONSTANT IS THE FALLBACK, NOT THE DEAD LETTER. It answers for a key the
--- profile has never stored, for a stat added to the catalog after a profile was
--- written, and for a degraded install with no database at all -- which is the
--- case that decides the shape here: a window must still draw its palette when
--- there is nothing to read a setting out of.
---
--- Plain numbers throughout: no part of this is a meter value, so none of it is
--- secret and all of it is legal at the height of a pull (design §4).
---
--- @param statKey string|nil
--- @return number|nil r, number|nil g, number|nil b
function NS.StatColor(statKey)
    if type(statKey) ~= "string" then return nil end

    local shipped = NS.Constants and NS.Constants.STAT_COLORS
    shipped = shipped and shipped[statKey]
    -- A key with no shipped entry has no row in the settings panel either
    -- (settings/Schema.lua generates one per palette entry), so there is nothing
    -- stored for it and nothing to fall back to.
    if not shipped then return nil end

    local stored = NS.GetSetting and NS.GetSetting("statColors." .. statKey)
    if stored ~= nil and NS.RGBA then
        local r, g, b = NS.RGBA(stored, shipped[1], shipped[2], shipped[3], 1)
        return r, g, b
    end

    return shipped[1], shipped[2], shipped[3]
end

--- The LOCAL player's class color, for a surface with no row to ask about.
---
--- The title bar and the column-header strip are about the window, not about any
--- one player, so "class color" there can only mean yours. Read through the same
--- reader, so the header and a row of the grid can never disagree about what a
--- warlock looks like.
---
--- @return number|nil r, number|nil g, number|nil b
function NS.PlayerClassRGB()
    local f = _G.UnitClass
    if not f then return nil end
    local _, classFilename = f("player")
    return NS.ClassRGB(classFilename)
end

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
    local v = NS.Meta("Version")
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
