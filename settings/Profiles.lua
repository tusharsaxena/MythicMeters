-- settings/Profiles.lua
--
-- The Profiles page: AceDBOptions' create / switch / copy / reset / delete UI,
-- hosted inside this addon's own canvas.
--
-- ---------------------------------------------------------------------------
-- THE ONE PLACE AceConfigDialog IS PERMITTED
-- ---------------------------------------------------------------------------
--
-- Every other page in this addon is drawn by LibKa0s-Options-1.0 from NS.Schema,
-- and AceConfig is not in the picture at all. This page is the documented
-- exception, for one reason: the options table is not ours. AceDBOptions
-- generates it — every scope dropdown, every confirmation, every profile-list
-- refresh — and re-expressing that as schema rows would mean maintaining a copy
-- of AceDB's own profile model that goes stale the first time AceDB adds a
-- scope. So the library's page shell hosts an AceGUI container, and
-- AceConfigDialog renders into it.
--
-- The exception is scoped to CONTENT. The canvas, the header, the breadcrumb
-- and the registration are still Helpers.CreatePanel, so this page looks like
-- the other twelve rather than like a bolted-on Ace window.
--
-- ---------------------------------------------------------------------------
-- NO DEFAULTS BUTTON, AND IT IS NOT AN OVERSIGHT
-- ---------------------------------------------------------------------------
--
-- "Restore defaults" on this page would mean deleting the player's profiles,
-- which is not what anyone means by restoring a default (options-ui-§3). The
-- header button is suppressed here, and the same predicate is enforced a second
-- time in settings/OptionsSetup.lua's skipRestoreAll so that `/mm resetall` and
-- the global Defaults sweep skip these rows too. Two enforcements of one rule,
-- because the destructive controls this page hosts are the library's, not ours.
--
-- ---------------------------------------------------------------------------
-- WHY THIS PAGE DOES NOT USE SetRenderer
-- ---------------------------------------------------------------------------
--
-- SetRenderer's contract is "draw once, and again when the library says you are
-- dirty", which is right for a page whose widgets the library owns. Here the
-- widget tree belongs to AceConfigDialog, which reuses it and re-reads the
-- current profile on every Open. So this page re-Opens on every show — cheap,
-- and the only way the profile list reflects a switch made from the slash
-- command or from another addon's copy of the same AceDB.
--
-- That costs the combat refusal SetRenderer would have given, so it is spelled
-- out below: the Blizzard AddOns sidebar reaches a canvas without going through
-- OpenOptionsPanel, so a page with no guard of its own is reachable mid-pull.

local addonName, NS = ...

local L = NS.L

local PAGE = "profiles"

local function Build(mainCategory)
    if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then return nil end
    if not LibStub then return nil end

    local H = NS.Helpers
    if not (H and H.CreatePanel) then return nil end

    local AceDBOptions    = LibStub("AceDBOptions-3.0",    true)
    local AceConfig       = LibStub("AceConfig-3.0",       true)
    local AceConfigDialog = LibStub("AceConfigDialog-3.0", true)
    local AceGUI          = NS.AceGUI or LibStub("AceGUI-3.0", true)
    if not (AceDBOptions and AceConfig and AceConfigDialog and AceGUI) then return nil end

    -- AceDB may have failed to initialize (core/Database.lua degrades rather
    -- than raising), and an options table built over a nil db raises inside
    -- AceDBOptions instead of here.
    if not (NS.db and NS.db.profile) then return nil end

    -- Registered once, at build time. The table AceDBOptions returns is live
    -- against NS.db, so it does not need rebuilding when the profile changes.
    AceConfig:RegisterOptionsTable("MythicMeters-Profiles", AceDBOptions:GetOptionsTable(NS.db))

    local ctx = H.CreatePanel("MythicMetersProfilesPanel", L["Profiles"], {
        pageKey        = PAGE,
        defaultsButton = false,   -- explicit, per the note above
    })

    -- An AceGUI SimpleGroup parented to our body. AceConfigDialog:Open accepts
    -- any AceGUI container as its target, so pointing it here lands the
    -- AceDBOptions widgets inside this canvas instead of opening a second
    -- floating window over the settings panel.
    local container = AceGUI:Create("SimpleGroup")
    container:SetLayout("Fill")
    container.frame:SetParent(ctx.body)
    container.frame:ClearAllPoints()
    container.frame:SetPoint("TOPLEFT",     ctx.body, "TOPLEFT",      8, -8)
    container.frame:SetPoint("BOTTOMRIGHT", ctx.body, "BOTTOMRIGHT", -8,  8)

    ctx.panel:SetScript("OnShow", function()
        -- The refusal SetRenderer would otherwise have provided. Closing the
        -- window is what makes it legible; a silently blank page reads as a bug.
        if InCombatLockdown and InCombatLockdown() then
            if SettingsPanel and SettingsPanel.Close then
                SettingsPanel:Close()
            elseif HideUIPanel and SettingsPanel then
                HideUIPanel(SettingsPanel)
            end
            if NS.Print then NS.Print(L["Cannot open settings during combat."]) end
            return
        end
        AceConfigDialog:Open("MythicMeters-Profiles", container)
    end)

    return Settings.RegisterCanvasLayoutSubcategory(mainCategory, ctx.panel, L["Profiles"])
end

if NS.RegisterOptionsPage then
    NS.RegisterOptionsPage(PAGE, L["Profiles"], Build)
end
