-- modules/Minimap.lua
--
-- The LibDataBroker launcher and the minimap button that fronts it.
--
-- The setting for this button already existed everywhere except here:
-- defaults/Profile.lua ships `minimap = { hide = false }`, settings/Schema.lua
-- offers a "Show minimap button" row whose onChange calls LibDBIcon's Refresh,
-- and the TOC vendors both libraries. What was missing was the one file that
-- actually creates the object those three describe, so the checkbox toggled a
-- value nothing read. This file closes that loop and does nothing else.
--
-- ---------------------------------------------------------------------------
-- WHY LibDBIcon OWNS THE TABLE
-- ---------------------------------------------------------------------------
--
-- LibDBIcon-1.0 is registered against `NS.db.profile.minimap` and then treats
-- that table as its own: it reads `hide`, and it WRITES `minimapPos` (and, if the
-- player drags the button off the minimap, `lock` / a free-position pair) as the
-- player moves it. That is why defaults/Profile.lua declares only `hide` and
-- comments that the shape is the library's — the addon must never enumerate the
-- table or normalize keys out of it, or a dragged button snaps back on the next
-- login. The addon's only interest in it is the one boolean the settings row
-- writes.
--
-- ---------------------------------------------------------------------------
-- WHY EVERY LIBRARY REACH IS OPTIONAL
-- ---------------------------------------------------------------------------
--
-- Both libraries are OptionalDeps in the TOC, and a player running a stripped
-- build (or an install where the packager dropped libs/) must lose the button and
-- nothing else. So every LibStub call passes the silent flag and every member is
-- checked before it is called: the failure mode of a missing broker library is a
-- meter with no minimap icon, never a Lua error during OnInitialize that takes
-- the options panel and the slash commands down with it.
--
-- TOC POSITION: anywhere in the `# Modules` block. It reads no other module at
-- load, and the one thing it does need — NS.db — is not touched until Init()
-- runs, which core/MythicMeters.lua calls from OnInitialize after NS:InitDB().

local addonName, NS = ...

local L = NS.L

-- The icon the launcher wears. The same texture the TOC's IconTexture names, so
-- the minimap button and the AddOns-list entry are recognisably the same addon.
local ICON = [[Interface\Icons\achievement_challengemode_gold]]

-- NO PERF BRACKET in this file, deliberately. Nothing here runs on a timer or per
-- frame: the launcher's callbacks fire on a human click and on tooltip hover, and
-- a bracket around either would measure the player's reflexes rather than the
-- addon's cost.

local Minimap = {}
NS.Minimap = Minimap

-- Set once registration succeeds, so Refresh() can tell "the player hid the
-- button" from "there is no button to hide". Kept here rather than probed off
-- LibDBIcon's registry each time because this file is the only thing that
-- registers under this name.
local registered = false

-- ---------------------------------------------------------------------------
-- Click behaviour
-- ---------------------------------------------------------------------------
--
-- Left toggles the windows, right opens the settings — the collection's standard
-- pairing, and the tooltip states both rather than leaving the right-click to be
-- discovered.
--
-- Both actions are routed through the SAME seams the slash commands use
-- (WindowManager:Toggle, NS.OpenOptionsPanel) rather than reimplemented here. In
-- particular OpenOptionsPanel carries the combat refusal — the options canvas is
-- a protected frame and opening it mid-pull is refused with a chat notice, not
-- deferred — and a private path from this button would be the one way to reach
-- the panel without that guard.

local function onClick(_, button)
    if button == "RightButton" then
        if NS.OpenOptionsPanel then NS.OpenOptionsPanel() end
        return
    end

    local wm = NS.WindowManager or (NS.GetModule and NS:GetModule("WindowManager", true))
    if wm and wm.Toggle then wm:Toggle() end
end

-- LibDataBroker hands the tooltip object itself, already anchored and cleared, so
-- this adds lines and nothing more — no Show(), no ClearLines(), and no
-- GameTooltip lookup. Calling Show() here is the classic way to get a tooltip
-- that will not go away when the cursor leaves the button.
local function onTooltipShow(tt)
    if not (tt and tt.AddLine) then return end
    tt:AddLine(L["Ka0s Mythic Meters"])
    if tt.AddDoubleLine then
        tt:AddDoubleLine(L["Version"], tostring(NS.version), 1, 1, 1, 0.6, 0.6, 0.6)
    end
    tt:AddLine(" ")
    tt:AddLine(L["Left-click to show or hide the meter windows."], 0.6, 0.6, 0.6)
    tt:AddLine(L["Right-click to open the settings."], 0.6, 0.6, 0.6)
end

-- ---------------------------------------------------------------------------
-- The three soft lookups
-- ---------------------------------------------------------------------------
--
-- Each of these answers nil for a real, reachable degraded install rather than
-- for a bug, which is why none of them raises and why none may be dropped:
-- a stripped build has no libraries, an old library may not carry the member we
-- are about to call, and Init() can be reached before NS:InitDB() has run.

--- Both broker libraries, or nil when this build cannot draw a button.
---
--- The silent LibStub flag plus the per-member check is the whole reason a
--- missing libs/ folder costs the player an icon and nothing else — see the
--- header. Returned as a pair so the caller's one `if` covers all four facts.
---
--- @return table|nil LDB, table|nil icon
local function brokerLibraries()
    local LDB  = LibStub and LibStub("LibDataBroker-1.1", true)
    local icon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not (LDB and icon and LDB.NewDataObject and icon.Register) then return nil end
    return LDB, icon
end

--- The live profile's `minimap` table — the one LibDBIcon takes ownership of, so
--- it has to be the profile's own table and never a copy (see the header). Nil
--- until NS:InitDB() has run.
---
--- @return table|nil
local function minimapSettings()
    local db = NS.db
    local profile = db and db.profile
    return profile and profile.minimap
end

--- The launcher object for this addon, reusing an existing registration under
--- the same name before creating one.
---
--- "launcher" is the LDB type for an object whose value is a click rather than a
--- number; a display addon that shows text feeds (Titan, ChocolateBar) uses the
--- type to decide it has a button and not a readout to render. The object is
--- named for the addon folder because settings/Schema.lua's refresh row looks the
--- registration up by `addonName` — the two must agree, and the folder name is
--- the one string neither can typo.
---
--- @param LDB table
--- @return table|nil
local function brokerObject(LDB)
    local existing = LDB.GetDataObjectByName and LDB:GetDataObjectByName(addonName)
    if existing then return existing end

    return LDB:NewDataObject(addonName, {
        type  = "launcher",
        label = L["Mythic Meters"],
        icon  = ICON,
        OnClick        = onClick,
        OnTooltipShow  = onTooltipShow,
    })
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- Create the broker object and hang the minimap button on it.
---
--- Called from core/MythicMeters.lua's OnInitialize AFTER NS:InitDB(), because
--- the table handed to LibDBIcon has to be the live profile's — see the header.
---
--- Idempotent: a second call (a reload of the settings layer, a test calling it
--- twice) is a no-op rather than a duplicate registration, which LibDBIcon would
--- answer with a hard error about a name it already owns.
---
--- @return boolean  whether a button now exists
function Minimap.Init()
    if registered then return true end

    local LDB, icon = brokerLibraries()
    if not LDB then return false end

    local settings = minimapSettings()
    if not settings then return false end

    local broker = brokerObject(LDB)
    if not broker then return false end

    -- The registry is checked first because LibDBIcon errors rather than warns on
    -- a duplicate name, and a /reload is not the only way this path runs twice.
    if not (icon.objects and icon.objects[addonName]) then
        icon:Register(addonName, broker, settings)
    end

    registered = true
    return true
end

--- Re-read `minimap.hide` and show or hide the button accordingly.
---
--- settings/Schema.lua's row calls LibDBIcon directly today; this exists so any
--- other caller has one addon-owned seam to use instead of learning the library's
--- argument order, and so a call made before Init() (or on a build with no broker
--- libraries) is a quiet no-op rather than an index into nil.
function Minimap.Refresh()
    if not registered then return end
    local icon = LibStub and LibStub("LibDBIcon-1.0", true)
    local db = NS.db
    if icon and icon.Refresh and db and db.profile then
        icon:Refresh(addonName, db.profile.minimap)
    end
end
