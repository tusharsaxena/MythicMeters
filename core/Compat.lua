-- core/Compat.lua
--
-- Every deprecated or cross-patch API call the addon makes lives here, so no
-- module has to do its own version detection and no module names a deprecated
-- global (architecture-§1). Callers reach for NS.Compat.X and get a shape that
-- matches a modern Midnight 12.x client; where the underlying API is missing the
-- shim degrades to a safe default rather than erroring at the call site.
--
-- This addon has an unusually large "might not exist" surface. C_DamageMeter is
-- new in 12.0, so a client one patch behind has none of it, and a PTR build can
-- have the namespace without one of its functions. Rather than sprinkle
-- `C_DamageMeter and C_DamageMeter.GetCombatSessionFromType and ...` across
-- modules/Provider.lua, the guards live here once and the provider reads like
-- the data-flow it is.
--
-- TOC POSITION: FIRST in the core block. core/Namespace.lua reads the TOC
-- manifest through Compat.GetAddOnMetadata on the very next line of the TOC.
--
-- WHAT THIS FILE MUST NOT DO. It never inspects a meter value. Reading a field
-- off a session table is not inspection — assigning it to a local and asking a
-- question about it is, and that is core/Secrets.lua's exclusive job (design §4,
-- rule R1). Everything below passes meter numbers through untouched.

local addonName, NS = ...

local Compat = {}
NS.Compat = Compat

-- ---------------------------------------------------------------------------
-- Addon manifest
-- ---------------------------------------------------------------------------

--- A field from the addon's TOC manifest.
---
--- 12.0 exposes the reader under C_AddOns; the bare _G.GetAddOnMetadata is the
--- deprecated pre-11.x seam and is only reached when the namespace is absent.
--- Returns nil rather than a placeholder so callers can tell "no manifest" from
--- "manifest says empty" and apply their own fallback (core/Namespace.lua's
--- FALLBACK_VERSION).
---
--- @param name string  addon folder name
--- @param field string "Version", "Title", ...
--- @return string|nil
function Compat.GetAddOnMetadata(name, field)
    if _G.C_AddOns and _G.C_AddOns.GetAddOnMetadata then
        return _G.C_AddOns.GetAddOnMetadata(name, field)
    end
    if _G.GetAddOnMetadata then
        return _G.GetAddOnMetadata(name, field)
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Spell APIs
-- ---------------------------------------------------------------------------
--
-- The meter hands us spellIDs on every DamageMeterCombatSpell row; the tooltip
-- and the drill-down turn them into a name and an icon. Both readers moved
-- behind C_Spell in 10.x, so the bare globals are the fallback only.

--- Basic spell info, flattened to the pre-C_Spell multi-return so call sites
--- read the same on either client.
---
--- @param spellID number
--- @return name, iconID, castTime, minRange, maxRange, spellID
function Compat.GetSpellInfo(spellID)
    if _G.C_Spell and _G.C_Spell.GetSpellInfo then
        local info = _G.C_Spell.GetSpellInfo(spellID)
        if info then
            return info.name, info.iconID, info.castTime,
                   info.minRange, info.maxRange, info.spellID
        end
        return nil
    end
    if _G.GetSpellInfo then
        return _G.GetSpellInfo(spellID)
    end
    return nil
end

--- File ID of a spell's icon texture, for the tooltip's spell rows.
--- @param spellID number
--- @return number|nil  fileID suitable for Texture:SetTexture()
function Compat.GetSpellTexture(spellID)
    if _G.C_Spell and _G.C_Spell.GetSpellTexture then
        return _G.C_Spell.GetSpellTexture(spellID)
    end
    if _G.GetSpellTexture then
        return _G.GetSpellTexture(spellID)
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Specialization APIs
-- ---------------------------------------------------------------------------
--
-- 12.0 (Midnight) moved the specialization query behind C_SpecializationInfo;
-- the bare GetSpecialization / GetSpecializationInfo globals are the deprecated
-- pre-11.x seam. Signatures are preserved: GetSpecialization returns the active
-- spec INDEX, GetSpecializationInfo(index) returns
-- (id, localizedName, description, iconID, role, ...).
--
-- The meter ships specIconID on every source row, so the row icons do NOT go
-- through here. What does is modules/Roster.lua's role lookup for the `roster`
-- sort mode, which needs the LOCAL player's spec when the group APIs have not
-- caught up yet (the first frame after a zone-in).

--- Active specialization index (or nil when unavailable).
--- @return number|nil
function Compat.GetSpecialization()
    if _G.C_SpecializationInfo and _G.C_SpecializationInfo.GetSpecialization then
        return _G.C_SpecializationInfo.GetSpecialization()
    end
    return _G.GetSpecialization and _G.GetSpecialization()
end

--- Spec info for a spec index. Multi-return passthrough of the underlying API.
--- @param index number
function Compat.GetSpecializationInfo(index)
    if _G.C_SpecializationInfo and _G.C_SpecializationInfo.GetSpecializationInfo then
        return _G.C_SpecializationInfo.GetSpecializationInfo(index)
    end
    if _G.GetSpecializationInfo then return _G.GetSpecializationInfo(index) end
    return nil
end

-- ---------------------------------------------------------------------------
-- C_DamageMeter — the addon's entire data source
-- ---------------------------------------------------------------------------
--
-- Blizzard's built-in meter, new in 12.0. modules/Provider.lua is the only
-- caller of these shims, and these shims are the only callers of the namespace.
--
-- EVERY one of them may return values that are SECRET while the Combat addon
-- restriction is active. Nothing here compares, adds, keys on, or measures the
-- length of anything that came back — the tables and their numbers are handed
-- straight to the caller. A single `if session.totalAmount > 0` in this file
-- would be a Lua error mid-pull, in the one place a player cannot see it.
--
-- The shims answer nil (or an empty table, where the caller wants to iterate
-- unconditionally) on a client without the namespace, which is exactly what the
-- "meter unavailable" render path already handles — so a 11.x client shows the
-- unavailable notice rather than erroring on load.

local function damageMeter()
    return _G.C_DamageMeter
end

--- Whether the built-in meter is usable right now.
---
--- The second return is Blizzard's own failure reason, which the window renders
--- verbatim in place of rows (design §6, "Degradation"). We do not translate it
--- and we do not second-guess it: it is the only thing that can tell a player
--- their meter is off because of a CVar rather than because our addon is broken.
---
--- @return boolean isAvailable, any failureReason
function Compat.IsDamageMeterAvailable()
    local api = damageMeter()
    if not (api and api.IsDamageMeterAvailable) then
        return false, nil
    end
    return api.IsDamageMeterAvailable()
end

--- One combat session for (sessionType, statType).
---
--- @param sessionType number Enum.DamageMeterSessionType value
--- @param statType number Enum.DamageMeterType value
--- @return table|nil  { combatSources, maxAmount, totalAmount, durationSeconds }
---   Fields are SECRET in combat. Pass them on; never look at them.
function Compat.GetCombatSessionFromType(sessionType, statType)
    local api = damageMeter()
    if not (api and api.GetCombatSessionFromType) then return nil end
    return api.GetCombatSessionFromType(sessionType, statType)
end

--- One combat session addressed by ID rather than by "current / overall".
--- Used by the session picker, which lists historical sessions.
--- @param sessionID number
--- @param statType number
--- @return table|nil
function Compat.GetCombatSessionFromID(sessionID, statType)
    local api = damageMeter()
    if not (api and api.GetCombatSessionFromID) then return nil end
    return api.GetCombatSessionFromID(sessionID, statType)
end

--- The per-source spell breakdown behind one cell — the tooltip and the
--- drill-down's data.
---
--- sourceGUID and sourceCreatureID are OPTIONAL in the underlying signature, so
--- they are forwarded rather than defaulted: passing an explicit nil and passing
--- nothing are the same thing to Lua here, and inventing a default would change
--- which source the API answers for.
---
--- @param sessionType number
--- @param statType number
--- @param sourceGUID string|nil
--- @param sourceCreatureID number|nil
--- @return table|nil  { combatSpells, maxAmount, totalAmount }
function Compat.GetCombatSessionSourceFromType(sessionType, statType, sourceGUID, sourceCreatureID)
    local api = damageMeter()
    if not (api and api.GetCombatSessionSourceFromType) then return nil end
    return api.GetCombatSessionSourceFromType(sessionType, statType, sourceGUID, sourceCreatureID)
end

--- The same breakdown for a session addressed by ID.
--- @return table|nil
function Compat.GetCombatSessionSourceFromID(sessionID, statType, sourceGUID, sourceCreatureID)
    local api = damageMeter()
    if not (api and api.GetCombatSessionSourceFromID) then return nil end
    return api.GetCombatSessionSourceFromID(sessionID, statType, sourceGUID, sourceCreatureID)
end

--- Every session the client is still holding, newest first.
---
--- Returns an EMPTY TABLE rather than nil when the API is missing, because the
--- session picker iterates it unconditionally to build its dropdown; a nil there
--- would put an existence check in the UI layer for a case the UI cannot do
--- anything about.
---
--- @return table  array of { sessionID, name, durationSeconds }
function Compat.GetAvailableCombatSessions()
    local api = damageMeter()
    if not (api and api.GetAvailableCombatSessions) then return {} end
    return api.GetAvailableCombatSessions() or {}
end

--- Duration of a session type in seconds. May be nil (no session yet), and is
--- SECRET in combat — the header formats it through the numeric formatter like
--- any other meter number rather than doing minutes/seconds arithmetic on it.
--- @param sessionType number
--- @return number|nil
function Compat.GetSessionDurationSeconds(sessionType)
    local api = damageMeter()
    if not (api and api.GetSessionDurationSeconds) then return nil end
    return api.GetSessionDurationSeconds(sessionType)
end

--- Clear every session the client holds. Reached only through
--- `NS.Provider.Reset()`, which is the addon's sole permitted caller of the
--- C_DamageMeter shims — never from a refresh path, because it wipes data the
--- player may be reading.
--- @return boolean  whether the call was made
function Compat.ResetAllCombatSessions()
    local api = damageMeter()
    if not (api and api.ResetAllCombatSessions) then return false end
    api.ResetAllCombatSessions()
    return true
end

-- ---------------------------------------------------------------------------
-- Numeric rule formatter
-- ---------------------------------------------------------------------------
--
-- THE ONLY LEGAL WAY TO RENDER "12.4M" FROM A SECRET. Abbreviating a number is
-- division and rounding, and both are arithmetic, which is exactly what tainted
-- code may not do to a secret value. C_StringUtil.CreateNumericRuleFormatter
-- returns an object whose :FormatNumber(n) performs that arithmetic NATIVELY and
-- accepts secrets (design §4, "Number formatting").
--
-- modules/Format.lua owns the formatter INSTANCES — one per number style, built
-- once and reused — and is the only caller of this shim. No call site anywhere
-- in this addon divides a meter value.

--- A fresh ABBREVIATED number formatter, or nil where the API is absent.
---
--- THERE ARE THREE FORMATTER TYPES AND ONLY ONE OF THEM ABBREVIATES. Patch
--- 12.0.5 added `AbbreviatedNumberFormatter`, `NumericRuleFormatter` and
--- `SecondsFormatter`, all three sharing `NumericFormatter:FormatNumber`. This
--- addon shipped v0.1.0 calling `CreateNumericRuleFormatter()` — the RULE-based
--- one — with no breakpoints configured, which is a perfectly working formatter
--- that renders `1410000` as "1410000". Every number in the addon was
--- unabbreviated and nothing failed loudly, because nothing had failed: we were
--- asking the wrong object.
---
--- The nil case is still real and still the caller's to handle rather than
--- papered over here with a Lua formatter: a Lua fallback that did the division
--- would be correct out of combat and a hard error in combat, which is the worst
--- of the two possible failures. modules/Format.lua degrades instead.
---
--- @return table|nil  object with :FormatNumber(n) -> string and SetBreakpoints
function Compat.CreateAbbreviatedNumberFormatter()
    local util = _G.C_StringUtil
    if not (util and util.CreateAbbreviatedNumberFormatter) then return nil end
    return util.CreateAbbreviatedNumberFormatter()
end

--- Blizzard's own abbreviation breakpoints — the K/M/B ladder the default UI
--- uses, already localized.
---
--- The safety net under modules/Format.lua's custom breakpoints: if this client
--- rejects the shape we build, the addon falls back to the client's own rather
--- than to no abbreviation at all.
---
--- @return table|nil  array of NumberAbbreviationBreakpoint
function Compat.GetDefaultAbbreviationBreakpoints()
    local util = _G.C_StringUtil
    if not (util and util.GetDefaultAbbreviationBreakpoints) then return nil end
    local ok, breakpoints = pcall(util.GetDefaultAbbreviationBreakpoints)
    if ok then return breakpoints end
    return nil
end

--- A fresh numeric RULE formatter, or nil where the API is absent.
---
--- Kept for the `full` number format, which wants a formatter that does not
--- abbreviate — which is exactly what this one is with no breakpoints on it.
--- See CreateAbbreviatedNumberFormatter above for why that distinction cost a
--- release.
---
--- @return table|nil  object with :FormatNumber(n) -> string
function Compat.CreateNumericRuleFormatter()
    local util = _G.C_StringUtil
    if not (util and util.CreateNumericRuleFormatter) then return nil end
    return util.CreateNumericRuleFormatter()
end

-- ---------------------------------------------------------------------------
-- Context menus
-- ---------------------------------------------------------------------------
--
-- The segment selector in a window's header is a dropdown, and dropdowns are the
-- part of the WoW UI that has been rewritten most often: UIDropDownMenu, then
-- EasyMenu, then MenuUtil in 11.0. Rather than let modules/Window.lua learn which
-- of those this client has, the question lives here with the rest of the "might
-- not exist" surface.
--
-- MenuUtil only. The older APIs are deliberately NOT wired as fallbacks: they are
-- absent on every client this addon supports, and a fallback nobody can run is a
-- fallback nobody has tested.

--- Open a context menu owned by `owner`, built by `generator`.
---
--- `generator` is called as `generator(owner, rootDescription)` and builds the
--- menu through the root's own CreateButton / CreateDivider / CreateTitle. That
--- is MenuUtil's contract and it is passed through unchanged rather than wrapped
--- in a descriptor shape of our own, which would be a second menu vocabulary to
--- keep in step with Blizzard's.
---
--- @param owner table     the region the menu anchors to
--- @param generator function
--- @return boolean  whether a menu was actually opened
function Compat.OpenContextMenu(owner, generator)
    local util = _G.MenuUtil
    if not (util and util.CreateContextMenu) then return false end
    if owner == nil or type(generator) ~= "function" then return false end
    -- pcall because this is a UI API being driven from a click handler: a menu
    -- that fails to open must not put an error in front of the player mid-pull.
    local ok = pcall(util.CreateContextMenu, owner, generator)
    return ok
end

-- ---------------------------------------------------------------------------
-- Icon art
-- ---------------------------------------------------------------------------
--
-- THIS EXISTS BECAUSE GUESSING FAILED TWICE, SILENTLY, IN A ROW.
--
-- The window header's sort arrow and its lock/gear buttons were first drawn from
-- texture paths (`Interface\Buttons\UI-SortArrow-Up`) that do not exist — and a
-- texture that fails to load draws NOTHING and raises nothing, so the arrow was
-- simply absent with no error to read. They were then redrawn as Unicode glyphs
-- (BLACK UP-POINTING TRIANGLE, GEAR, LOCK), which are not in the game's default
-- font and rendered as replacement boxes.
--
-- Both failures share a shape: the art was named at authoring time and its
-- existence was never checked. So it is checked HERE, at runtime, against the
-- client that is actually running — and there is a final fallback that cannot
-- fail, because it is an ASCII character every font has.

--- The first atlas in `names` this client actually has, or nil.
---
--- `C_Texture.GetAtlasInfo` is the only way to ask "does this exist" before
--- drawing it; SetAtlas on an unknown name is silent.
---
--- @param names table  candidate atlas names, best first
--- @return string|nil
function Compat.FirstAtlas(names)
    local api = _G.C_Texture
    if not (api and api.GetAtlasInfo) then return nil end
    for _, name in ipairs(names or {}) do
        local ok, info = pcall(api.GetAtlasInfo, name)
        if ok and info then return name end
    end
    return nil
end
