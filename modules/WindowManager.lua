-- modules/WindowManager.lua
--
-- The window REGISTRY: create, delete, rename, duplicate, copy-settings-from,
-- and the one instance of modules/Window.lua that stands behind each stored
-- config. core/Database.lua owns the shape of a window config and the array it
-- lives in; this file owns the live objects and every mutation of the list.
--
-- WHY A REGISTRY AT ALL. A window is an instance, not a singleton (design §6):
-- there are no global display settings, so "the meter" is however many
-- independently configured grids the player has made. Something has to hold
-- them, keep the settings panel's picker and the slash CLI agreeing about which
-- is which, and make sure a copy is a DEEP copy — two windows sharing one
-- sub-table is the classic profile-aliasing bug, where editing window 2's bar
-- color silently edits window 1's.
--
-- THE SOLE SENDER of Ka0s_MultiMeters_WINDOWS_CHANGED (architecture-§4). That
-- message means the registry changed SHAPE — a window created, deleted, renamed
-- or duplicated — and is deliberately distinct from CONFIG_CHANGED, which is a
-- setting moving inside a window that already exists. The settings panel
-- rebuilds its picker off the first and merely refreshes off the second.
--
-- ---------------------------------------------------------------------------
-- IDENTIFYING A WINDOW
-- ---------------------------------------------------------------------------
--
-- Two callers address windows two ways and both are right. The settings panel
-- holds an ID (stable, never reused, and what the window-relative schema paths
-- resolve against). `/mm window delete Raid` holds a NAME, because that is what
-- a player can type. So every public entry point below takes EITHER, through
-- Resolve() — a number is an id, a string is a name — rather than making the
-- CLI look an id up first and pass one it never wanted to know about.

local addonName, NS = ...

local Const = NS.Constants
local MSG   = Const.MSG
local L     = NS.L

-- An AceAddon module rather than a plain table: core/PerfSetup.lua's suspend and
-- resume hooks reach it through NS:GetModule, and the standard's module idiom is
-- what a reader of a sibling addon expects.
--
-- PUBLISHED EXPLICITLY on the line after. NewModule writes the module into
-- AceAddon's own registry and NOWHERE else — it does not hang it on NS — so the
-- flat name every caller outside this file uses (settings/Slash.lua,
-- settings/Frame.lua, settings/Windows.lua, settings/Schema.lua and
-- settings/OptionsSetup.lua all read NS.WindowManager) has to be assigned here.
-- Without it every one of those call sites finds nil and silently does nothing,
-- which is the entire window-management surface going quiet with no error to say
-- so. modules/Provider.lua, modules/Roster.lua and modules/Aggregator.lua all
-- publish themselves the same way.
local M = NS:NewModule("WindowManager", "AceEvent-3.0")
NS.WindowManager = M

-- The live instances, keyed by window id. NOT an array: the ORDER is
-- db.profile.windows' order, which is the user's, and duplicating it here would
-- give the addon two answers to "which window is third".
local instances = {}

-- The config groups a copy can be filtered to. This list is the settings panel's
-- "Settings to copy" dropdown and the deep-copy filter at once, so a group added
-- to defaults/Profile.lua's template and not to this list simply never copies —
-- which is why it is written beside the template's own group order.
local COPY_GROUPS = {
    "frame", "header", "rows", "bars", "text",
    "icons", "tooltip", "visibility", "columns", "data",
}

local COPY_GROUP_SET = {}
for _, key in ipairs(COPY_GROUPS) do COPY_GROUP_SET[key] = true end

M.COPY_GROUPS = COPY_GROUPS

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Recursive deep copy. File-local and deliberately not shared with
--- core/Database.lua's: this one is the reason copy-settings-from is safe, and a
--- reader auditing that claim should find it in the same file as the claim.
local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deepcopy(x) end
    return out
end

local function windows()
    return NS.Database and NS.Database.GetWindows() or {}
end

--- The ONE WINDOWS_CHANGED emitter.
--- @param id number|nil     the window the action was about
--- @param action string     "created" | "deleted" | "renamed" | "copied" | "reset"
local function announce(id, action)
    if NS.State and NS.State.debug and NS.Debug then
        NS.Debug("Windows", "%s id=%s (%d total)", action, tostring(id), #windows())
    end
    if NS.SendMessage then
        NS:SendMessage(MSG.WINDOWS_CHANGED, { windowId = id, action = action })
    end
end

-- ---------------------------------------------------------------------------
-- Lookup
-- ---------------------------------------------------------------------------

--- Find a window config by id or by name.
---
--- Names are compared case-INSENSITIVELY but stored exactly as typed: a window
--- name is user data, and folding it on the way in would rename something the
--- player did not rename. Folding it on the way out is just being forgiving
--- about what they type into chat.
---
--- @param key number|string|nil
--- @return table|nil config, number|nil index
function M.Resolve(key)
    if key == nil then return nil, nil end

    if type(key) == "number" then
        return NS.Database.FindWindow(key)
    end

    local wanted = tostring(key):lower()
    for i, w in ipairs(windows()) do
        if tostring(w.name or ""):lower() == wanted then return w, i end
    end

    -- A number typed into chat arrives as a string. Trying the id second rather
    -- than first means a window literally named "2" still wins its own name.
    local asId = tonumber(key)
    if asId then return NS.Database.FindWindow(asId) end
    return nil, nil
end

--- The live instance for a window, by id or name.
--- @return table|nil
function M.Get(key)
    local cfg = M.Resolve(key)
    return cfg and instances[cfg.id] or nil
end

--- Every live instance, in the registry's order (which is the user's).
--- @return table  array of window instances
function M.All()
    local out = {}
    for _, cfg in ipairs(windows()) do
        local inst = instances[cfg.id]
        if inst then out[#out + 1] = inst end
    end
    return out
end

--- A name no existing window is using, derived from `base`.
local function uniqueName(base)
    base = tostring(base or ""):match("^%s*(.-)%s*$")
    if base == "" then base = L["Meter"] end
    if not M.Resolve(base) then return base end
    local n = 2
    while M.Resolve(base .. " " .. n) do n = n + 1 end
    return base .. " " .. n
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- Build one instance per stored config, and drop any instance whose config is
--- gone. Idempotent, and the single path taken on login, on a profile swap and
--- after any registry change — so there is one answer to "which windows exist
--- right now" rather than one per entry point.
function M:Init()
    local seen = {}

    for _, cfg in ipairs(windows()) do
        seen[cfg.id] = true
        local inst = instances[cfg.id]
        if inst then
            -- A profile swap hands us a DIFFERENT table with the same id. The
            -- instance is re-pointed rather than rebuilt: tearing down a frame
            -- to build an identical one is churn the player sees as a flicker.
            inst:SetConfig(cfg)
        else
            instances[cfg.id] = NS.Window.New(cfg)
        end
    end

    for id, inst in pairs(instances) do
        if not seen[id] then
            inst:Destroy()
            instances[id] = nil
        end
    end
end

function M:OnEnable()
    -- The registry is built from the profile, so it cannot be built before
    -- core/Database.lua has one. OnEnable runs after OnInitialize's InitDB.
    self:Init()

    -- A profile swap replaces every config table in the registry, so the whole
    -- set is rebuilt. CONFIG_CHANGED is NOT handled here: each window subscribes
    -- to it on its own bus target and re-applies itself, which is what keeps a
    -- twenty-window profile from re-applying nineteen windows for one edit.
    self:RegisterMessage(MSG.PROFILE_CHANGED, function()
        self:Init()
        self:RefreshAll()
    end)
end

-- ---------------------------------------------------------------------------
-- Registry mutation
-- ---------------------------------------------------------------------------

--- Create a window with the shipped defaults.
--- @param name string|nil
--- @return boolean ok, string|nil err
function M:Create(name)
    local id = NS.Database.NextWindowId()
    local cfg = NS.DefaultWindow(id, uniqueName(name))
    NS.Database.EnsureWindowShape(cfg)

    local list = windows()
    list[#list + 1] = cfg
    instances[id] = NS.Window.New(cfg)

    announce(id, "created")
    if NS.Print then NS.Print(L["Window '%s' created."]:format(cfg.name)) end
    return true
end

--- Delete a window.
---
--- THE LAST WINDOW IS NOT DELETABLE. An addon whose entire user interface is its
--- windows has nothing left to be — no way back short of the settings panel the
--- player just lost their handle on — so the refusal is explicit and named.
--- The safety net behind it is core/Database.lua's SeedWindows, which re-seeds a
--- default whenever the registry is found empty for any other reason.
---
--- @param key number|string
--- @return boolean ok, string|nil err
function M:Delete(key)
    local cfg, index = M.Resolve(key)
    if not cfg then return false, L["No window is selected."] end

    local list = windows()
    if #list <= 1 then return false, L["The last window cannot be deleted."] end

    local name = cfg.name
    local id = cfg.id
    table.remove(list, index)

    local inst = instances[id]
    if inst then inst:Destroy() end
    instances[id] = nil

    -- The settings panel's window-relative schema paths resolve against the
    -- active window; leaving it pointed at a deleted id would make every row on
    -- every page read nil.
    if NS.State and NS.State.activeWindowId == id then
        NS.State.SetActiveWindow(list[1] and list[1].id or nil)
    end

    announce(id, "deleted")
    if NS.Print then NS.Print(L["Window '%s' deleted."]:format(tostring(name))) end
    return true
end

--- Rename a window. The new name is stored exactly as typed.
--- @return boolean ok, string|nil err
function M:Rename(key, newName)
    local cfg = M.Resolve(key)
    if not cfg then return false, L["No window is selected."] end
    newName = tostring(newName or ""):match("^%s*(.-)%s*$")
    if newName == "" then return false, L["Window name"] end

    cfg.name = uniqueName(newName)
    local inst = instances[cfg.id]
    if inst then inst:ApplyConfig() end

    announce(cfg.id, "renamed")
    return true
end

--- Copy a window whole, into a new one.
--- @return boolean ok, string|nil err
function M:Duplicate(key)
    local src = M.Resolve(key)
    if not src then return false, L["No window is selected."] end

    local id = NS.Database.NextWindowId()
    local cfg = deepcopy(src)
    cfg.id = id
    cfg.name = uniqueName(src.name)
    -- A duplicate that lands exactly on top of its original looks like nothing
    -- happened. Offsetting it is the cheapest way to show the player there are
    -- now two.
    if cfg.frame and cfg.frame.position then
        cfg.frame.position.x = (cfg.frame.position.x or 0) + 24
        cfg.frame.position.y = (cfg.frame.position.y or 0) - 24
    end
    NS.Database.EnsureWindowShape(cfg)

    local list = windows()
    list[#list + 1] = cfg
    instances[id] = NS.Window.New(cfg)

    announce(id, "created")
    return true
end

--- The set of config groups a copy is filtered to, or nil for "everything".
---
--- Accept both shapes a caller might hold: an array of keys (the CLI, a test) or
--- a set (the panel's multi-select). Neither is converted at the call site,
--- because a caller that has to know which one this wants is a caller that will
--- one day get it wrong. Anything that is neither a string nor a table is the
--- unfiltered case, and answers nil rather than an empty set — "no filter" and
--- "a filter that selects nothing" are opposite instructions.
---
--- @param groups string|table|nil
--- @return table|nil
local function requestedGroups(groups)
    if type(groups) == "string" then
        -- The settings panel's group dropdown hands over ONE key, because that
        -- is what its control holds. Accepting the bare string rather than
        -- making the panel wrap it keeps the wrapping — and the chance of
        -- wrapping it wrong — out of the caller.
        return COPY_GROUP_SET[groups] and { [groups] = true } or {}
    end
    if type(groups) ~= "table" then return nil end

    local wanted = {}
    for k, v in pairs(groups) do
        local key = (type(k) == "number") and v or (v and k or nil)
        -- A key this build does not know is DROPPED rather than copied blindly:
        -- it would put a group into the target that EnsureWindowShape has no
        -- template for and nothing ever reads.
        if key and COPY_GROUP_SET[key] then wanted[key] = true end
    end
    return wanted
end

--- Deep-copy the wanted groups of one window config onto another, and answer how
--- many landed.
---
--- EVERY group is deep-copied. Assigning `target.bars = source.bars` would make
--- two windows share one table, and the next edit to either would silently edit
--- both — the aliasing bug this whole file exists to prevent.
---
--- @param src table
--- @param dst table
--- @param wanted table|nil  nil copies every group
--- @return number copied
local function copyGroups(src, dst, wanted)
    local copied = 0
    for _, key in ipairs(COPY_GROUPS) do
        if (not wanted or wanted[key]) and src[key] ~= nil then
            dst[key] = deepcopy(src[key])
            copied = copied + 1
        end
    end
    return copied
end

--- Copy settings from one window onto another.
---
--- ARGUMENT ORDER IS (source, target), matching `/mm window copy <source>
--- <target>` and the English of the panel's "Copy settings from" control.
---
--- `groups` is nil for everything, or ONE group key, or a set / array of them
--- ("frame", "header", "rows", "bars", "text", "icons", "tooltip", "visibility",
--- "columns", "data"). Filtering is what makes this worth having: copying one
--- window's COLUMNS onto another while leaving its position and its visibility
--- rules alone is the actual request behind "copy settings from".
---
--- EVERY group is deep-copied (copyGroups above). Assigning `target.bars =
--- source.bars` would make two windows share one table, and the next edit to
--- either would silently edit both.
---
--- The target's IDENTITY is never copied: id and name stay the target's, or the
--- registry would end up with two windows claiming to be the same one.
---
--- @param source number|string
--- @param target number|string
--- @param groups string|table|nil
--- @return boolean ok, string|nil err
function M:CopyFrom(source, target, groups)
    local src = M.Resolve(source)
    local dst = M.Resolve(target)
    if not src then return false, L["No window is selected."] end
    if not dst then return false, L["No window is selected."] end
    if src == dst then return true end

    local wanted = requestedGroups(groups)

    -- Where the window sits is not a setting. A copied `frame` group carries the
    -- source's position with it and would drop the target exactly on top of the
    -- source, which reads as "the copy did nothing" — so the target's own
    -- position is taken before the copy and put back after it.
    local keepPosition = dst.frame and deepcopy(dst.frame.position)

    local copied = copyGroups(src, dst, wanted)

    if keepPosition and dst.frame then dst.frame.position = keepPosition end

    NS.Database.EnsureWindowShape(dst)

    local inst = instances[dst.id]
    if inst then inst:SetConfig(dst) end

    announce(dst.id, "copied")
    if NS.Print then
        NS.Print(L["Copied %s from '%s'."]:format(
            wanted and tostring(copied) .. " groups" or L["Everything"]:lower(),
            tostring(src.name)))
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Bulk operations
-- ---------------------------------------------------------------------------

--- Re-apply config and re-run the show ladder for every window. The path a
--- profile swap and a "reset all defaults" both take.
function M:RefreshAll()
    for _, inst in ipairs(M.All()) do
        inst:ApplyConfig()
        inst:RefreshVisibility()
        inst:MarkDirty()
    end
end

--- Mark every window dirty without re-applying anything. What a data-shaped
--- change (a meter reset, a roster change reaching the manager rather than the
--- windows) costs: one flag each, and the throttle decides the rest.
function M:MarkAllDirty()
    for _, inst in ipairs(M.All()) do inst:MarkDirty() end
end

--- Put every window back in the middle of the screen.
---
--- Reached from `/mm reset-positions` and from the options panel's
--- restore-defaults hook — window POSITIONS are not schema rows (they are
--- per-window instance state this file owns), so NS.ApplyDefault never reaches
--- them and this is the only path that does.
---
--- Put ONE window back in the middle of the screen — the Frame page's "Reset
--- position" button, which acts on the window the picker is pointed at rather
--- than on all of them.
---
--- @param key number|string|nil  defaults to the active window
--- @return boolean
function M:ResetPosition(key)
    if key == nil and NS.State then key = NS.State.activeWindowId end
    local cfg = M.Resolve(key)
    if not (cfg and cfg.frame) then return false end
    cfg.frame.position = { point = "CENTER", relativePoint = "CENTER", x = 0, y = 0 }
    local inst = instances[cfg.id]
    if inst then inst:ApplyPosition() end
    return true
end

--- @return number  how many windows moved
function M:ResetPositions()
    local moved = 0
    for _, cfg in ipairs(windows()) do
        if cfg.frame then
            cfg.frame.position = { point = "CENTER", relativePoint = "CENTER", x = 0, y = 0 }
            moved = moved + 1
            local inst = instances[cfg.id]
            if inst then inst:ApplyPosition() end
        end
    end
    announce(nil, "reset")
    return moved
end

-- ---------------------------------------------------------------------------
-- Lock and preview
-- ---------------------------------------------------------------------------

--- Lock or unlock every window.
---
--- LOCKING IS ABOUT MOVEMENT AND NOTHING ELSE — dragging and resizing, on or off.
---
--- It used to also switch test mode on, on the theory that somebody positioning a
--- window wants a full grid to aim at. That coupling made three controls each do
--- two things: `/mm lock off` silently turned placeholder data on, and unchecking
--- Test mode did nothing while any window was unlocked. A player who wants a grid
--- to position against asks for one with `/mm test`.
function M:SetLocked(locked)
    locked = locked and true or false
    for _, cfg in ipairs(windows()) do
        if cfg.frame then cfg.frame.locked = locked end
    end
    for _, inst in ipairs(M.All()) do
        inst:RefreshUpvalues()
        inst:ApplyLock()
        inst:RefreshVisibility()
        inst:MarkDirty()
    end
end

--- Whether every window is locked. Reported as a single answer because the
--- lock is presented to the player as a single switch; a per-window lock is a
--- setting the panel can still reach.
function M:IsLocked()
    for _, cfg in ipairs(windows()) do
        if cfg.frame and not cfg.frame.locked then return false end
    end
    return true
end

--- Placeholder data on or off. Routed through core/State.lua for the same
--- one-sender reason as above, then every window is marked dirty so the change
--- is visible on the next throttle tick rather than at the next meter event —
--- which, out of combat, may never come.
function M:SetTestMode(enabled)
    if NS.State and NS.State.SetTestMode then NS.State.SetTestMode(enabled) end
    for _, inst in ipairs(M.All()) do
        inst:RefreshVisibility()
        inst:MarkDirty()
    end
end

function M:IsTest()
    return (NS.State and NS.State.testMode) and true or false
end

--- `/mm toggle` with no name flips every window; with a name, one.
---
--- "Toggle" here means SHOWN, not enabled: it hides a window that is on screen
--- and shows one that is not, without touching the visibility rules that would
--- put it back at the next zone change. That is what a player who typed
--- `/mm toggle` in the middle of a pull wants.
---
--- @param name string|nil
--- @return boolean ok, string|nil err
function M:Toggle(name)
    if name == nil then
        local anyShown = false
        for _, inst in ipairs(M.All()) do
            if inst:IsShown() then anyShown = true end
        end
        for _, inst in ipairs(M.All()) do
            if anyShown then inst:Hide("toggled") else inst:Show() end
        end
        return true
    end

    local inst = M.Get(name)
    if not inst then
        return false, (L["Setting not found: %s"]):format(tostring(name))
    end
    if inst:IsShown() then inst:Hide("toggled") else inst:Show() end
    return true
end

-- ---------------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------------

--- The lines `/mm window list` prints: one per window, with the facts a player
--- needs to tell two windows apart — its name, whether it is on screen, and how
--- many columns it carries.
--- @return table  array of strings
function M:BuildListLines()
    local lines = {}
    for _, cfg in ipairs(windows()) do
        local inst = instances[cfg.id]
        local shown = inst and inst:IsShown()
        lines[#lines + 1] = ("|cFFFFFF00%s|r  %s  %s%d %s|r"):format(
            tostring(cfg.name or "?"),
            shown and L["Enabled"] or (NS.GRAY .. L["Disabled"] .. "|r"),
            NS.GRAY,
            #(cfg.columns or {}),
            L["Columns"])
    end
    if #lines == 0 then lines[1] = NS.GRAY .. L["No window is selected."] .. "|r" end
    return lines
end

-- ---------------------------------------------------------------------------
-- Perf suspend / resume (performance-§6)
-- ---------------------------------------------------------------------------

--- Stop the coalescing timers. NOT a hide: hiding from here would fight
--- modules/Visibility.lua, whose own ladder reads NS.Perf.suspended as step 0
--- and is therefore already refusing every window at the source. What this takes
--- away is the WORK — a pass already queued would otherwise fire once more,
--- inside the measurement window, and be attributed to an addon that is supposed
--- to be doing nothing.
function M:Suspend()
    for _, inst in ipairs(M.All()) do inst:Suspend() end
end

--- Restore from CURRENT state rather than from a snapshot: Init first, so a
--- window created while suspended comes back too.
function M:Resume()
    self:Init()
    for _, inst in ipairs(M.All()) do inst:Resume() end
end
