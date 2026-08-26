std = "lua51"
max_line_length = false
codes = true
-- libs/ is vendored third-party code; tests/_kit/ is a vendored harness; the docs/audits and
-- docs/reviews bundles are frozen snapshots and must never be "fixed" by a lint pass.
exclude_files = { "libs/", "tests/", "docs/audits/", "docs/reviews/", "_dev/" }
ignore = {
  "212/self",       -- unused argument self
  "212/event",      -- unused argument event
  "211/addonName",  -- `local addonName, NS = ...` bootstrap header; addonName often unused
}
read_globals = {
  -- core Lua/WoW globals
  "_G", "LibStub", "CreateFrame", "GetTime", "GetTimePreciseSec",
  "UIParent", "GameTooltip", "GameTooltip_SetDefaultAnchor",
  -- Where the pointer is, in SCALED coordinates. settings/ColumnBlocks.lua's drag
  -- reads it per OnUpdate frame and divides by UIParent:GetEffectiveScale().
  "GetCursorPosition",
  "GameFontNormal", "GameFontHighlight", "GameFontDisable", "STANDARD_TEXT_FONT",
  "hooksecurefunc", "securecallfunction", "PlaySound",
  -- Perf bracket timer (performance-§2). The bracket CALL SITES are addon code and are
  -- linted, even though the lib under libs/ is not.
  "debugprofilestop",
  -- Secret values (WoW 12.0). core/Secrets.lua is the ONLY file permitted to call these;
  -- they are declared here so that one file lints, not so that others may use them.
  "issecretvalue", "canaccessvalue", "issecrettable", "canaccesstable",
  "C_RestrictedActions",
  -- the meter itself — modules/Provider.lua is the only caller
  "C_DamageMeter",
  -- native formatting / curve evaluation: the only legal arithmetic on a secret value
  "C_StringUtil", "C_CurveUtil",
  "C_Timer", "C_Spell", "C_SpecializationInfo", "C_AddOns", "C_ChallengeMode",
  "Enum", "GetLocale", "GetSpellInfo",
  -- combat state. InCombatLockdown() gates secure writes; UnitAffectingCombat() drives
  -- combat-reactive display logic (they are not interchangeable).
  "InCombatLockdown", "UnitAffectingCombat",
  -- units / roster
  "UnitExists", "UnitGUID", "UnitName", "UnitClass", "UnitIsUnit", "UnitIsPlayer",
  "UnitGroupRolesAssigned", "UnitInVehicle", "UnitIsDead", "UnitIsDeadOrGhost",
  -- player state, for the visibility rules (modules/Visibility.lua). The
  -- namespaced probes those rules also need — C_PlayerInfo, C_Housing,
  -- C_DelvesUI, C_PartyInfo — reach the client through core/Compat.lua and are
  -- read off _G there, so they need no entry here.
  "UnitOnTaxi", "IsMounted", "GetShapeshiftFormID",
  "IsInGroup", "IsInRaid", "IsInInstance", "GetNumGroupMembers", "GetRaidRosterInfo",
  "GetInstanceInfo", "IsLoggedIn",
  -- settings panel / frame plumbing
  "Settings", "SettingsPanel", "UISpecialFrames", "HideUIPanel", "ShowUIPanel",
  "DEFAULT_CHAT_FRAME", "UIDropDownMenu_AddButton",
  -- death recap hand-off (modules/DrillDown.lua)
  "OpenDeathRecapUI", "DeathRecapFrame",
  -- color / util
  "CreateColor", "CreateColorFromHexString", "WrapTextInColorCode", "RAID_CLASS_COLORS",
  "CopyTable", "wipe", "tContains", "tinsert", "tremove", "strsplit", "strtrim", "strjoin",
  "date", "time",
  "BackdropTemplateMixin", "Mixin", "CreateFromMixins",
  "NORMAL_FONT_COLOR", "HIGHLIGHT_FONT_COLOR", "RED_FONT_COLOR", "GREEN_FONT_COLOR", "GRAY_FONT_COLOR",
  -- static popups
  "StaticPopup_Show",
}
globals = {
  "MultiMetersDB",     -- SavedVariables write target (the AceDB tree)
  "MultiMetersPerfDB", -- LibKa0s-Perf capture ring; a SECOND top-level SV global, deliberately
                       -- outside the AceDB tree so "copy profile" does not clone it and
                       -- "reset profile" does not wipe it
  "StaticPopupDialogs", -- addon registers named popups by adding fields to this table
}
