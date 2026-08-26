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
-- v3 collapses the three row-icon toggles into one.
-- v4 retires the export channel "AUTO".
-- v5 lifts mergePets and throttle from per-window to addon-wide.
-- v6 prunes the two row-background keys nothing ever read.
-- v7 turns four class-colour booleans into three-way colour modes.
local CURRENT_DB_VERSION = 7

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

--- The shipped display name for the nth window: "Multi Meters #3".
---
--- Lives here, beside the id counter, because two callers mint a default name
--- and neither may disagree with the other: SeedWindows below names the first
--- window of a fresh profile, and modules/WindowManager.lua names every window
--- created after it. The number is a plain one-up count of the windows that
--- exist, NOT the id — ids are never reused, so a player who deletes and
--- recreates would otherwise watch the name climb forever.
---
--- @param n number
--- @return string
function Database.WindowName(n)
    return NS.L["Multi Meters #%d"]:format(n)
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
        windows[1] = NS.DefaultWindow(id, Database.WindowName(1))
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

--- v3 -> v4: THE "AUTO" EXPORT CHANNEL IS RETIRED.
---
--- It resolved itself at send time — instance chat, then raid, then party, then
--- say — and the objection to it is not that the ladder was wrong. It is that a
--- player pressing "Print to Chat" is choosing an AUDIENCE, and a row that picks
--- the audience for them makes the one fact they need to be sure of the one fact
--- the dialog does not state. core/Constants.lua no longer offers the row.
---
--- A profile still holding the key would otherwise reach SendChatMessage with a
--- chat type of "AUTO", which is not one, so it folds to SELF — the shipped
--- default, and the only landing that cannot put a ranking somewhere the player
--- did not ask for. modules/Export.lua's ResolveChannel names the retired key as
--- well, for a profile that arrives from a copy or a hand edit after this ran.
migrations[3] = function(db)
    for _, profile in ipairs(allProfiles(db)) do
        local export = profile.export
        if type(export) == "table" and export.channel == "AUTO" then
            export.channel = "SELF"
        end
    end

    db.global.schemaVersion = 4
end

--- v4 -> v5: `mergePets` AND `throttle` BECOME ADDON-WIDE.
---
--- Neither was ever a property of a window. `mergePets` says what a pet's damage
--- IS — one row or its owner's — and `throttle` is how often the addon redraws.
--- Two windows on one screen disagreeing about either is two answers to one
--- question, and the settings tree was the only thing asking it twice.
---
--- THE FIRST WINDOW'S VALUES WIN, per profile. There is no merge rule that is
--- right for a player who set two windows differently, and the alternatives are
--- worse than arbitrary: taking the shipped default would discard a deliberate
--- choice from every profile that made one, and taking "any window that differs
--- from the default" would let a window the player had forgotten about outvote
--- the one they use. The first window is the one at the top of their own picker.
---
--- The per-window keys are then REMOVED. AceDB merges defaults in and never
--- prunes what the defaults stopped naming, so leaving them would put a stale
--- `throttle` in every saved window forever, next to the live one, with nothing
--- to say which the addon honors.
migrations[4] = function(db)
    for _, profile in ipairs(allProfiles(db)) do
        local windows = type(profile.windows) == "table" and profile.windows or {}
        local first = windows[1]
        local data = type(first) == "table" and type(first.data) == "table" and first.data or nil

        -- THE WINDOW'S VALUE WINS OUTRIGHT, and the `== nil` rule that governs
        -- EnsureWindowShape deliberately does not apply here. AceDB's defaults
        -- merge has already run by the time a migration does, so `profile.data`
        -- is never nil to test — it is sitting there filled with the shipped
        -- values, and "already set" cannot be told from "just merged in". Before
        -- this step the profile-level key did not exist and nothing read it, so
        -- there is no player intent to preserve at that address and every
        -- intent to preserve at the window's.
        if data and (data.mergePets ~= nil or data.throttle ~= nil) then
            local lifted = type(profile.data) == "table" and profile.data or {}
            if data.mergePets ~= nil then lifted.mergePets = data.mergePets end
            if data.throttle  ~= nil then lifted.throttle  = data.throttle  end
            profile.data = lifted
        end

        for _, w in ipairs(windows) do
            if type(w) == "table" and type(w.data) == "table" then
                w.data.mergePets, w.data.throttle = nil, nil
            end
        end
    end

    db.global.schemaVersion = 5
end

--- v5 -> v6: THE TWO DEAD ROW-BACKGROUND KEYS ARE PRUNED.
---
--- `rows.classBackground` and `rows.classBackgroundAlpha` were settings-panel
--- rows pointing at keys NOTHING READ. The row tint is painted per cell from
--- `bars.bgColorMode` and `bars.bgAlpha` (modules/Row.lua's cellBackground) --
--- it moved there when tinting the row itself turned out to tint the two-pixel
--- seams between the columns and lose the separators the grid is read by -- and
--- these two were left behind, answering a question already answered one page
--- over, into a void.
---
--- Removed rather than left to rot, for the reason the v2 -> v3 icon step gives:
--- AceDB merges defaults into a stored profile and never prunes what the defaults
--- stopped naming, so without this they sit in every saved window forever and the
--- next reader has to work out which of two keys the code honours. Neither had a
--- reader, which is exactly why nobody would guess.
migrations[5] = function(db)
    for _, profile in ipairs(allProfiles(db)) do
        for _, w in ipairs(type(profile.windows) == "table" and profile.windows or {}) do
            local rows = type(w) == "table" and w.rows
            if type(rows) == "table" then
                rows.classBackground, rows.classBackgroundAlpha = nil, nil
            end
        end
    end

    db.global.schemaVersion = 6
end

--- v6 -> v7: FOUR CLASS-COLOUR BOOLEANS BECOME COLOUR MODES.
---
--- Every text surface -- the cells, the title bar, the column labels and the
--- tooltip -- carried a `classColor` checkbox, which could only ever answer two
--- thirds of the question a player was asking: class, the statistic's own colour,
--- or the one they picked. `colorMode` answers all three, and the two header
--- BACKGROUNDS gained the same three, which they had none of before.
---
--- `true` becomes "class" and `false` becomes "custom", which is exactly what the
--- boolean meant. The key is REMOVED afterwards for the reason the v2 -> v3 icon
--- step gives: AceDB merges defaults in and never prunes what they stopped
--- naming, so a stale `classColor` would sit beside the live `colorMode` in every
--- saved profile with nothing to say which the addon honours.
---
--- The tooltip's key is in the same group as its `fontOutline` and `fontShadow`
--- siblings rather than under `text`, which is why this walks a list of GROUPS
--- rather than assuming one shape.
migrations[6] = function(db)
    local GROUPS = { "text", "header", "columnHeader", "tooltip" }

    for _, profile in ipairs(allProfiles(db)) do
        for _, w in ipairs(type(profile.windows) == "table" and profile.windows or {}) do
            for _, key in ipairs(GROUPS) do
                local group = type(w) == "table" and w[key]
                if type(group) == "table" and group.classColor ~= nil then
                    if group.colorMode == nil then
                        group.colorMode = group.classColor and "class" or "custom"
                    end
                    group.classColor = nil
                end
            end
        end
    end

    db.global.schemaVersion = 7
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
