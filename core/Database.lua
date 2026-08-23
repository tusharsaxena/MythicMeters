-- core/Database.lua
--
-- Owns the AceDB-3.0 instance, the window registry's shape, and the migration
-- runner. The defaults tree itself lives in defaults/Profile.lua, which is the
-- only place a profile default is hardcoded (savedvariables-§2).
--
-- The one thing this file does that a sibling addon's Database.lua does not is
-- key-fill the WINDOWS. Windows are an ARRAY of config tables, and AceDB's
-- defaults merge cannot reach inside an array — it fills keys of tables it knows
-- about, and it does not know that `profile.windows[3]` is supposed to look like
-- defaults/Profile.lua's WINDOW_TEMPLATE. So the merge is ours, and the rule
-- that makes it correct is spelled out at EnsureWindowShape: test with `== nil`,
-- NEVER `stored.k or D.k`.
--
-- TOC POSITION: after core/State.lua and before core/MultiMeters.lua, whose
-- OnInitialize calls NS:InitDB(). The defaults tree it merges against loads
-- LATER (the `# Defaults` block follows `# Core`), which is fine because every
-- read of NS.defaults here happens at CALL time.

local addonName, NS = ...

local Database = {}
NS.Database = Database

-- ---------------------------------------------------------------------------
-- Schema version
-- ---------------------------------------------------------------------------

-- Increment ONLY for a non-additive change to the profile's shape — a rename, a
-- restructure, a type change. Additive changes (a new leaf setting, a new window
-- group) are absorbed by AceDB's defaults merge and by EnsureWindowShape below,
-- and need no version bump.
--
-- The version is an addon-wide integer in db.global.schemaVersion, NOT
-- per-profile (savedvariables-§1), so a migration runs once per ACCOUNT.
-- v1 is the shipped shape.
-- v2 makes every column one uniform width (see migrations[1] below).
local CURRENT_DB_VERSION = 3

-- The ONE Ka0s_MultiMeters_PROFILE_CHANGED emitter (architecture-§4: one sender
-- per message). Every path that makes the active profile a different thing — a
-- swap, a copy, a reset — routes here rather than writing its own SendMessage,
-- so the bus catalog in docs/ARCHITECTURE.md names one site and stays true.
local function fireProfileChanged(key)
    if NS.SendMessage then
        NS:SendMessage(NS.Constants.MSG.PROFILE_CHANGED, { newProfileKey = key })
    end
end

-- File-local recursive deep-copy, deliberately independent of NS.Util: this file
-- is reached during OnInitialize and must not depend on a helper module's load
-- order.
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

-- ---------------------------------------------------------------------------
-- Window shape
-- ---------------------------------------------------------------------------

--- Fill any key a stored window is missing from the shipped template, in place
--- and recursively.
---
--- CRITICAL, and the reason this is a named function with a comment rather than
--- three inline lines (savedvariables-§5, anti-pattern #54): the presence test is
--- `stored[k] == nil`. It is NEVER `stored[k] or template[k]`.
---
--- `or` cannot tell UNSET from a stored `false`, `""` or `0`. This profile is
--- full of exactly those values — `frame.locked = false`, `header.title = ""`,
--- `rows.maxRows = 0`, `bars.border = false` — so an `or` merge would silently
--- reset a user's deliberate "off" back to the shipped "on" on every single
--- login, and would do it invisibly, because the setting they turned off would
--- simply be on again.
---
--- Arrays are left ALONE when present. `columns` is an ordered list the user
--- edits; key-filling it against the template would re-add columns they removed.
--- An absent columns array is a broken profile, not an older one, and gets the
--- template's copy so the window renders something.
---
--- @param stored table    the window config from SavedVariables
--- @param template table  defaults/Profile.lua's WINDOW_TEMPLATE (or a sub-table)
local function fillMissing(stored, template)
    for k, v in pairs(template) do
        if stored[k] == nil then
            stored[k] = copy(v)
        elseif type(v) == "table" and type(stored[k]) == "table" and v[1] == nil then
            -- Recurse into KEYED sub-tables only. `v[1] ~= nil` marks an array
            -- (the template's `columns` is empty, so this guard is about future
            -- array-shaped groups), and an array is the user's ordering to keep.
            fillMissing(stored[k], v)
        end
    end
end

--- Bring one stored window up to the current shape. Idempotent, shape-driven,
--- and safe to run on every login and every profile swap.
---
--- Shape-driven rather than version-gated on purpose. AceDB's defaults merge
--- backfills `db.global.schemaVersion` to the CURRENT value the moment
--- `db.global` is first touched, which masks an older account as already-current
--- and would skip a version-gated step entirely. Keying on "is this key missing"
--- asks the only question that has a reliable answer.
---
--- @param w table
function Database.EnsureWindowShape(w)
    if type(w) ~= "table" then return end
    local template = NS.WINDOW_TEMPLATE
    if type(template) ~= "table" then return end
    fillMissing(w, template)
    if type(w.columns) ~= "table" then
        w.columns = {}
    end
end

--- The live window array. THE traversal seam: every consumer that reads or
--- mutates the registry goes through here, so the `db.profile.windows` walk
--- lives in exactly one place.
---
--- Returns an empty table rather than nil when the database is not up yet, so a
--- caller can iterate unconditionally. Callers that need to MUTATE the registry
--- go through modules/WindowManager.lua, which owns create / delete / rename /
--- duplicate and is the sender of WINDOWS_CHANGED.
---
--- @return table  array of window config tables
function Database.GetWindows()
    local db = NS.db
    if not (db and db.profile) then return {} end
    db.profile.windows = db.profile.windows or {}
    return db.profile.windows
end

--- One window by id, plus its index in the registry.
--- @param id number
--- @return table|nil window, number|nil index
function Database.FindWindow(id)
    if id == nil then return nil, nil end
    for i, w in ipairs(Database.GetWindows()) do
        if w.id == id then return w, i end
    end
    return nil, nil
end

--- Hand out the next window id and advance the counter.
---
--- Ids are monotonic and never reused. A reused id would let a deleted window's
--- id be handed to a new one, which would silently inherit the settings panel's
--- active-window pointer and every window-relative schema path aimed at it
--- (design §8).
---
--- @return number
function Database.NextWindowId()
    local db = NS.db
    if not (db and db.profile) then return 1 end
    local id = db.profile.nextWindowId or 1
    db.profile.nextWindowId = id + 1
    return id
end

--- Seed a brand-new profile with exactly one window, and normalize every window
--- already there.
---
--- "Brand new" is detected by an EMPTY registry, not by a version, for the same
--- reason EnsureWindowShape is shape-driven. And the seed lives here rather than
--- in defaults/Profile.lua's tree because AceDB's defaults merge would fold a
--- default window back into a profile the user had deleted their last window
--- from — resurrecting it on every login, with no way to refuse it.
function Database.SeedWindows()
    local windows = Database.GetWindows()

    if #windows == 0 then
        local id = Database.NextWindowId()
        windows[1] = NS.DefaultWindow(id, "Meter")
        if NS.State and NS.State.debug then
            NS.Debug("Init", "seeded default window id=%d", id)
        end
    end

    for _, w in ipairs(windows) do
        -- An id can be missing on a window written by a build that predates the
        -- counter, or hand-edited into SavedVariables. Mint one rather than
        -- dropping the window: losing a user's configured window is worse than
        -- renumbering it.
        if w.id == nil then w.id = Database.NextWindowId() end
        Database.EnsureWindowShape(w)
    end
end

-- ---------------------------------------------------------------------------
-- Migrations
-- ---------------------------------------------------------------------------
--
-- Each step is idempotent, reads and writes db, and walks
-- db.global.schemaVersion forward by exactly one. Adding a v2 means appending
-- `[1] = function(db) ... db.global.schemaVersion = 2 end` and bumping
-- CURRENT_DB_VERSION. No bootstrap change is required.
--
local migrations = {}

--- Every profile in the account, active or not.
---
--- Real AceDB-3.0 exposes the raw SavedVariables table as `db.sv`, and a
--- migration has to reach `sv.profiles` rather than `db.profile`: a profile the
--- player has not activated this session is still THEIR profile, and lifting only
--- the active one leaves the others to surprise them on the next swap — after
--- schemaVersion has already been stamped forward, so the step never runs again.
---
--- Falls back to the active profile alone where `db.sv` is absent, which is the
--- degraded case rather than the normal one.
---
--- @param db table
--- @return table  array of profile tables
local function allProfiles(db)
    local sv = db.sv
    if type(sv) == "table" and type(sv.profiles) == "table" then
        local out = {}
        for _, profile in pairs(sv.profiles) do
            if type(profile) == "table" then out[#out + 1] = profile end
        end
        return out
    end
    return type(db.profile) == "table" and { db.profile } or {}
end

--- v1 -> v2: ONE UNIFORM COLUMN WIDTH.
---
--- Widths are written into a window when it is CREATED (defaults/Profile.lua),
--- not read live from the catalog, so moving every stat's defaultWidth to
--- Const.COLUMN_WIDTH would have changed nothing for a window that already
--- existed. This is the step that reaches them.
---
--- IT DISCARDS A HAND-TUNED WIDTH, deliberately and once. That is the feature
--- being asked for — "make the columns the same width" is not satisfiable while
--- honoring per-column widths a previous version chose — and per-column width
--- remains a setting afterwards, so anything deliberate can be set again.
---
--- The frame is only ever WIDENED, never narrowed: a player who had already
--- dragged their window wider than the grid needs keeps that, while one still at
--- the old 480 default gets a frame that actually holds the new grid instead of
--- clipping its rightmost column.
migrations[1] = function(db)
    local Const = NS.Constants
    local template = NS.WINDOW_TEMPLATE or {}
    local defaultPad = ((template.frame or {}).padding) or 6

    for _, profile in ipairs(allProfiles(db)) do
        for _, w in ipairs(type(profile.windows) == "table" and profile.windows or {}) do
            local columns = type(w.columns) == "table" and w.columns or {}
            for _, col in ipairs(columns) do
                if type(col) == "table" then col.width = Const.COLUMN_WIDTH end
            end

            local frame = w.frame
            if type(frame) == "table" then
                local pad = frame.padding or defaultPad
                local needed = Const.NAME_COLUMN_WIDTH
                    + #columns * (Const.COLUMN_WIDTH + Const.COLUMN_GAP)
                    + pad * 2
                if type(frame.width) ~= "number" or frame.width < needed then
                    frame.width = needed
                end
            end
        end
    end

    db.global.schemaVersion = 2
end

--- v2 -> v3: the three row-icon toggles collapse into one.
---
--- `icons.showClass` / `showSpec` / `showRole` become a single `icons.showIcon`,
--- and the slot decides for itself which icon to draw (modules/Row.lua's
--- drawUnitIcon: spec where it is known, class where it is not, never a role).
---
--- ANY of the three counts as "on". Somebody running the role icon alone had
--- asked for AN icon, and reading only `showClass` would take it away from them
--- without asking — the new slot answers the same question better rather than
--- withdrawing the answer.
---
--- The old keys are REMOVED rather than left to rot. AceDB merges defaults into
--- a stored profile but never prunes what the defaults stopped naming, so three
--- dead booleans would sit in every saved profile forever, and the next reader
--- of the file would have to work out which of the four keys the code honours.
migrations[2] = function(db)
    for _, profile in ipairs(allProfiles(db)) do
        for _, w in ipairs(type(profile.windows) == "table" and profile.windows or {}) do
            local icons = w.icons
            if type(icons) == "table" then
                if icons.showIcon == nil then
                    icons.showIcon = (icons.showClass or icons.showSpec or icons.showRole)
                        and true or false
                end
                icons.showClass, icons.showSpec, icons.showRole = nil, nil, nil
            end
        end
    end

    db.global.schemaVersion = 3
end

--- Walk the account forward to CURRENT_DB_VERSION. Runs on Init and on every
--- profile swap, and is a no-op once at the current version.
function NS:RunMigrations()
    local db = NS.db
    if not (db and db.global) then return end
    local g = db.global

    g.schemaVersion = g.schemaVersion or 1

    while g.schemaVersion < CURRENT_DB_VERSION do
        local from = g.schemaVersion
        local step = migrations[from]
        if not step then
            -- No registered migrator for this jump. Bump to the current version
            -- rather than spinning: a real schema change would have registered
            -- its step before CURRENT_DB_VERSION moved.
            g.schemaVersion = CURRENT_DB_VERSION
            break
        end
        step(db)
        if NS.State and NS.State.debug then
            NS.Debug("Migrate", "v%d -> v%d", from, from + 1)
        end
    end

    -- Shape normalization runs AFTER the version walk and unconditionally, so a
    -- profile that arrives from a copy or a hand edit is brought to the current
    -- window shape whatever its version claims.
    Database.SeedWindows()
end

-- ---------------------------------------------------------------------------
-- Profile callbacks
-- ---------------------------------------------------------------------------

--- AceDB calls this as `obj:method(event, db, newProfileKey)` for
--- OnProfileChanged / OnProfileCopied. OnProfileReset passes nil for the third
--- argument, so the active key is substituted.
---
--- Everything downstream — every window, the settings panel, the aggregator's
--- caches — rebuilds off the single PROFILE_CHANGED message rather than off a
--- direct call from here (architecture-§4).
function Database:OnProfileChanged(_, db, newProfileKey)
    local key = newProfileKey or (db and db.keys and db.keys.profile) or "Default"

    if NS.State and NS.State.debug then
        NS.Debug("Profile", "switched to '%s'", tostring(key))
    end

    -- The newly-active profile may be a copy authored at an older schema
    -- version, or a reset back to an empty registry. Both need the full
    -- migrate-then-normalize pass before anything reads a window.
    NS:RunMigrations()

    -- Per-session state that was derived from the OLD profile is now wrong.
    if NS.State then
        NS.State.SetActiveWindow(nil)
        NS.State.WipeCache()
    end

    fireProfileChanged(key)
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------

--- Build the AceDB instance. Called once, from NS:OnInitialize().
---
--- After this returns, NS.db is the live AceDB object — a contract every module
--- relies on and the reason the call is first in OnInitialize.
function NS:InitDB()
    local AceDB = LibStub and LibStub("AceDB-3.0", true)
    if not AceDB then
        -- Reached at call time, not captured: core/CoreSetup.lua publishes the
        -- printer and the TOC order between the two files must not be able to
        -- freeze a nil in.
        local out = NS.Util and NS.Util.print
        if out then out("AceDB-3.0 is missing — settings cannot be loaded.") end
        return
    end

    -- The third argument is `true`, which AceDB expands to the shared "Default"
    -- profile. Omitting it falls back to a PER-CHARACTER profile, which
    -- contradicts the documentation and is the source of every "each new
    -- character lands on its own settings" report in the collection. Players who
    -- want per-character opt in through the Profiles page.
    local db = AceDB:New("MultiMetersDB", NS.defaults, true)
    NS.db         = db
    Database.db   = db

    -- Migrate, then seed and normalize the window registry. RunMigrations does
    -- both, so Init and a profile swap share one path.
    NS:RunMigrations()

    -- AceDB calls these as `obj:method(event, db, key)` given the
    -- (self, "OnProfileChanged", "OnProfileChanged") registration form.
    db.RegisterCallback(Database, "OnProfileChanged", "OnProfileChanged")
    db.RegisterCallback(Database, "OnProfileCopied",  "OnProfileChanged")
    db.RegisterCallback(Database, "OnProfileReset",   "OnProfileChanged")
end
