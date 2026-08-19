-- tests/test_database.lua — core/Database.lua: the AceDB instance, the window
-- registry's shape, and the migration runner.
--
-- THE CASE THIS SUITE EXISTS FOR is the `== nil` merge (savedvariables-§5,
-- anti-pattern #54). AceDB's defaults merge cannot reach inside an ARRAY — it
-- fills keys of tables it knows about, and it does not know that
-- `profile.windows[3]` is supposed to look like a window — so the fill is this
-- addon's own, and the rule that makes it correct is that a missing key is
-- detected with `stored[k] == nil` and NEVER with `stored[k] or template[k]`.
--
-- `or` cannot tell UNSET from a stored `false`, `""` or `0`, and this profile is
-- full of exactly those values. An `or` merge would reset a user's deliberate
-- "off" back to the shipped "on" on EVERY LOGIN, invisibly — the setting they
-- turned off would simply be on again, with no error and nothing in the log. So
-- the case below stores a false, an empty string and a zero, runs the real merge,
-- and asserts all three survived.

local T = _G.MYTHICMETERS_TEST
local NS = T.NS
local test, assertEqual, assertTrue, assertFalse, assertNil =
    T.test, T.assertEqual, T.assertTrue, T.assertFalse, T.assertNil

local MSG = NS.Constants.MSG

-- ---------------------------------------------------------------------------
-- Driving a profile swap
-- ---------------------------------------------------------------------------
--
-- core/Database.lua registers its profile callbacks in CallbackHandler's
-- METHOD-NAME form — `db.RegisterCallback(Database, "OnProfileChanged",
-- "OnProfileChanged")` — which AceDB dispatches as `target:method(event, db,
-- key)`. The vendored AceDB fake in tests/_kit/mock_base.lua dispatches FUNCTION
-- callbacks only, so it raises on that form rather than calling the handler.
--
-- The profile STATE has already moved by the time it raises (SetProfile assigns
-- `db.profile` before it fires), so the helpers below let the fake do the state
-- change and then supply the dispatch it cannot. The `if not ok` guard means a
-- future fake that grows the method-name form dispatches once, through itself,
-- and these cases keep asserting the same thing rather than double-firing.
--
-- What a direct dispatch cannot show is that the REGISTRATION is really that
-- form; that half has its own case below, read off the source.

local function dispatchProfileChange(inst, event, key)
    inst.NS.Database[event](inst.NS.Database, event, inst.NS.db, key)
end

--- Switch to `key`, then make sure the handler ran exactly once.
local function swapProfile(inst, key)
    local ok = pcall(inst.NS.db.SetProfile, inst.NS.db, key)
    if not ok then dispatchProfileChange(inst, "OnProfileChanged", key) end
end

--- Reset the active profile, then make sure the handler ran exactly once.
--- AceDB passes nil for the key on OnProfileReset, which is the case the
--- handler's substitution exists for.
local function resetProfile(inst)
    local ok = pcall(inst.NS.db.ResetProfile, inst.NS.db)
    if not ok then dispatchProfileChange(inst, "OnProfileChanged", nil) end
end

--- A loaded instance with NO database yet, so a case can seed the SavedVariables
--- global and then drive the REAL NS:InitDB() against it.
local function preSeeded(saved)
    local inst = T.load{ initDB = false, options = false }
    _G.MythicMetersDB = saved
    inst.NS:InitDB()
    inst.NS:RunMigrations()
    return inst
end

-- ── the AceDB instance ──────────────────────────────────────────────────────

test("Database: InitDB publishes the live instance under both names", function()
    local inst = T.load{}
    assertTrue(inst.NS.db ~= nil, "NS.db is the contract every module relies on")
    assertTrue(inst.NS.Database.db == inst.NS.db, "Database.db must be the same object")
    assertEqual(type(inst.NS.db.profile), "table")
    assertEqual(type(inst.NS.db.global), "table")
end)

test("Database: the profile is the SHARED Default, not a per-character one", function()
    -- AceDB:New's third argument is `true`, which it expands to the shared
    -- "Default" profile. Omitting it falls back to a PER-CHARACTER profile,
    -- which contradicts the documentation and is the source of every "each new
    -- character lands on its own settings" report in the collection.
    -- red under: dropping the third argument from the AceDB:New call.
    local fh = assert(io.open((T.root or ".") .. "/core/Database.lua", "r"))
    local src = fh:read("*a")
    fh:close()
    assertTrue(src:match('AceDB:New%("MythicMetersDB",%s*NS%.defaults,%s*true%)') ~= nil,
        "InitDB must pass `true` for the shared Default profile")
    assertEqual(T.load{}.NS.db:GetCurrentProfile(), "Default")
end)

test("Database: with AceDB absent, InitDB says so and leaves NS.db nil", function()
    -- A broken install. The printer is reached at CALL time rather than captured,
    -- so the TOC order between core/CoreSetup.lua and this file cannot freeze a
    -- nil in.
    local inst = T.load{ initDB = false, options = false,
        mutate = function(m) m.__libs["AceDB-3.0"] = nil end }
    local before = #inst.mocks.__chat
    inst.NS:InitDB()
    assertNil(inst.NS.db)
    assertTrue(#inst.mocks.__chat > before, "a missing AceDB must be reported, not swallowed")
    assertTrue(inst.mocks.__chat[#inst.mocks.__chat]:find("AceDB", 1, true) ~= nil)
end)

-- ── the `== nil` merge — the case this suite exists for ─────────────────────

test("Database: a stored false, \"\" and 0 all survive the window shape merge", function()
    -- savedvariables-§5 / anti-pattern #54, proved rather than asserted about.
    -- Every value here is one the shipped template sets to something TRUTHY, so
    -- an `or` merge would silently overwrite all three.
    -- red under: rewriting fillMissing as `stored[k] = stored[k] or template[k]`.
    local tpl = NS.WINDOW_TEMPLATE
    assertTrue(tpl.frame.clampToScreen == true, "the fixture needs a truthy shipped default")
    assertEqual(tpl.frame.strata, "MEDIUM")
    assertTrue(tpl.frame.scale > 0)
    assertTrue(tpl.rows.alwaysShowSelf == true)
    assertTrue(tpl.tooltip.maxSpells > 0)

    local stored = {
        id = 1,
        frame = { clampToScreen = false, strata = "", scale = 0 },
        rows  = { alwaysShowSelf = false },
        tooltip = { maxSpells = 0 },
    }
    NS.Database.EnsureWindowShape(stored)

    assertEqual(stored.frame.clampToScreen, false, "a stored false was reset to the shipped true")
    assertEqual(stored.frame.strata, "", "a stored empty string was reset to the shipped value")
    assertEqual(stored.frame.scale, 0, "a stored 0 was reset to the shipped 1.0")
    assertEqual(stored.rows.alwaysShowSelf, false)
    assertEqual(stored.tooltip.maxSpells, 0)
end)

test("Database: the same false survives a REAL login — SavedVariables to merged profile",
function()
    -- The unit case above proves the function; this proves the wiring. An `or`
    -- merge anywhere on the InitDB path resets the user's choice on every login,
    -- and the only way to see that is to come in through the saved global.
    local inst = preSeeded({
        profiles = { Default = { windows = { { id = 1, name = "Mine",
            frame = { clampToScreen = false, scale = 0 },
            rows  = { alwaysShowSelf = false } } } } },
        global   = { schemaVersion = 1 },
    })
    local w = inst.NS.Database.FindWindow(1)
    assertTrue(w ~= nil, "the stored window must survive InitDB")
    assertEqual(w.frame.clampToScreen, false)
    assertEqual(w.frame.scale, 0)
    assertEqual(w.rows.alwaysShowSelf, false)
    assertEqual(w.name, "Mine", "and the user's name must not be replaced by the template's")
end)

test("Database: the merge fills every key the stored window is missing", function()
    -- The other half of the same function: an old profile written before a
    -- setting existed must come up with the shipped value rather than nil, or
    -- every reader of that setting gets nil at render time.
    local stored = { id = 9 }
    NS.Database.EnsureWindowShape(stored)
    for group, values in pairs(NS.WINDOW_TEMPLATE) do
        if type(values) == "table" then
            assertEqual(type(stored[group]), "table", "group " .. group .. " was not filled")
            for key in pairs(values) do
                assertTrue(stored[group][key] ~= nil,
                    "window." .. group .. "." .. key .. " was not filled")
            end
        end
    end
end)

test("Database: the merge deep-copies, so no window shares a sub-table with the template",
function()
    -- Two windows aliasing one sub-table is the classic profile bug: editing
    -- window 2's bar color silently edits window 1's. The template is the shared
    -- object both would alias.
    -- red under: `stored[k] = v` instead of `stored[k] = copy(v)`.
    local a, b = { id = 1 }, { id = 2 }
    NS.Database.EnsureWindowShape(a)
    NS.Database.EnsureWindowShape(b)
    assertFalse(a.frame == NS.WINDOW_TEMPLATE.frame, "the window aliases the shipped template")
    assertFalse(a.frame == b.frame, "two windows share one frame table")
    assertFalse(a.frame.backdropColor == b.frame.backdropColor, "two windows share one color table")
    local shipped = NS.WINDOW_TEMPLATE.frame.width
    a.frame.width = shipped + 999
    assertEqual(b.frame.width, shipped, "writing one window moved the other")
    assertEqual(NS.WINDOW_TEMPLATE.frame.width, shipped, "writing a window moved the template")
end)

test("Database: the three profile callbacks are registered in the method-name form", function()
    -- AceDB dispatches `db.RegisterCallback(target, event, "MethodName")` as
    -- `target:MethodName(event, db, key)`, which is the signature
    -- Database:OnProfileChanged is written for. Registering a bare FUNCTION
    -- instead would call it with the event as `self`, and `db` and the key would
    -- land one argument to the left — so `newProfileKey` would be the db table.
    -- All three events must be covered: a copy and a reset change the active
    -- profile just as a swap does.
    -- red under: dropping the OnProfileCopied or OnProfileReset registration.
    local fh = assert(io.open((T.root or ".") .. "/core/Database.lua", "r"))
    local src = fh:read("*a")
    fh:close()
    for _, event in ipairs({ "OnProfileChanged", "OnProfileCopied", "OnProfileReset" }) do
        assertTrue(src:match('RegisterCallback%(Database,%s*"' .. event
            .. '",%s*"OnProfileChanged"%)') ~= nil,
            event .. " is not registered against Database:OnProfileChanged")
    end
end)

test("Database: a stored columns array is left exactly as the user ordered it", function()
    -- `columns` is an ordered list the user edits. Key-filling it against the
    -- template would re-add columns they removed, on every login.
    -- red under: recursing into arrays in fillMissing.
    local stored = { id = 3, columns = { { stat = "Deaths", width = 44, showBar = false } } }
    NS.Database.EnsureWindowShape(stored)
    assertEqual(#stored.columns, 1, "the user's one-column layout grew back")
    assertEqual(stored.columns[1].stat, "Deaths")
    assertEqual(stored.columns[1].showBar, false)
end)

test("Database: an ABSENT columns array becomes an empty array, never nil", function()
    -- A broken profile, not an older one. Every renderer iterates this
    -- unconditionally, so nil would be an error at draw time.
    local stored = { id = 4 }
    NS.Database.EnsureWindowShape(stored)
    assertEqual(type(stored.columns), "table")
    local wrongType = { id = 5, columns = "not a table" }
    NS.Database.EnsureWindowShape(wrongType)
    assertEqual(type(wrongType.columns), "table")
end)

test("Database: EnsureWindowShape is idempotent", function()
    -- It runs on every login and on every profile swap. A second pass that
    -- changed anything would mean the first pass did not finish.
    local w = { id = 6, frame = { scale = 0 } }
    NS.Database.EnsureWindowShape(w)
    local snapshot = {}
    for k, v in pairs(w.frame) do snapshot[k] = v end
    NS.Database.EnsureWindowShape(w)
    for k, v in pairs(snapshot) do assertEqual(w.frame[k], v, "frame." .. k .. " moved") end
end)

test("Database: EnsureWindowShape refuses a non-table without raising", function()
    NS.Database.EnsureWindowShape(nil)
    NS.Database.EnsureWindowShape("not a window")
    NS.Database.EnsureWindowShape(7)
end)

-- ── the registry ────────────────────────────────────────────────────────────

test("Database: GetWindows answers an empty table before the database is up", function()
    -- Callers iterate it unconditionally. Returning nil would put an existence
    -- check in every consumer for a case none of them can act on.
    local inst = T.load{ initDB = false, options = false }
    assertEqual(type(inst.NS.Database.GetWindows()), "table")
    assertEqual(#inst.NS.Database.GetWindows(), 0)
end)

test("Database: a fresh profile is seeded with exactly one window", function()
    local inst = T.load{}
    local windows = inst.NS.Database.GetWindows()
    assertEqual(#windows, 1)
    assertEqual(windows[1].name, "Meter")
    assertEqual(windows[1].id, 1)
    assertTrue(#windows[1].columns > 0, "the seeded window must ship with its default columns")
end)

test("Database: the seed window is NOT an AceDB default, so a deleted last window stays deleted",
function()
    -- If `windows` carried a default entry, AceDB's merge would fold it back
    -- into a profile the user had emptied — resurrecting it on every login with
    -- no way to refuse.
    -- red under: putting a window into defaults/Profile.lua's `profile.windows`.
    assertEqual(#NS.defaults.profile.windows, 0, "the defaults tree must ship an EMPTY registry")
    local inst = preSeeded({
        profiles = { Default = { windows = {} } },
        global   = { schemaVersion = 1 },
    })
    -- A brand-new EMPTY registry does get its seed — that is the "first login"
    -- path — so the distinction is proved by deleting AFTER the seed instead.
    local windows = inst.NS.Database.GetWindows()
    for i = #windows, 1, -1 do windows[i] = nil end
    swapProfile(inst, "Other")
    swapProfile(inst, "Default")
    assertEqual(#inst.NS.Database.GetWindows(), 1,
        "the registry is reseeded by SeedWindows, not resurrected by the defaults merge")
end)

test("Database: FindWindow answers the window and its index, and nil for anything else", function()
    local inst = T.load{}
    local w, i = inst.NS.Database.FindWindow(1)
    assertTrue(w ~= nil)
    assertEqual(i, 1)
    assertNil((inst.NS.Database.FindWindow(999)))
    assertNil((inst.NS.Database.FindWindow(nil)))
end)

test("Database: window ids are monotonic and never reused", function()
    -- A reused id would let a deleted window's id be handed to a new one, which
    -- would silently inherit the settings panel's active-window pointer and
    -- every window-relative schema path aimed at it.
    -- red under: deriving the next id from #windows + 1.
    local inst = T.load{}
    local D = inst.NS.Database
    local first = D.NextWindowId()
    local second = D.NextWindowId()
    assertTrue(second > first, "ids must advance")
    -- Delete every window and ask again: the counter must not rewind.
    local windows = D.GetWindows()
    for i = #windows, 1, -1 do windows[i] = nil end
    assertTrue(D.NextWindowId() > second, "the counter rewound after a delete")
end)

test("Database: NextWindowId answers 1 with no database rather than raising", function()
    local inst = T.load{ initDB = false, options = false }
    assertEqual(inst.NS.Database.NextWindowId(), 1)
end)

test("Database: a stored window with no id is given one rather than dropped", function()
    -- Written by a build that predates the counter, or hand-edited into
    -- SavedVariables. Losing a user's configured window is worse than
    -- renumbering it.
    local inst = preSeeded({
        profiles = { Default = { windows = { { name = "Nameless" } }, nextWindowId = 5 } },
        global   = { schemaVersion = 1 },
    })
    local windows = inst.NS.Database.GetWindows()
    assertEqual(#windows, 1, "the window must not be dropped")
    assertEqual(windows[1].name, "Nameless")
    assertEqual(windows[1].id, 5, "and must be minted the next id, not id 1")
end)

-- ── migrations ──────────────────────────────────────────────────────────────

test("Database: RunMigrations stamps and holds the current schema version", function()
    local inst = T.load{}
    local v = inst.NS.db.global.schemaVersion
    assertEqual(type(v), "number")
    inst.NS:RunMigrations()
    assertEqual(inst.NS.db.global.schemaVersion, v, "a second run must be a no-op")
end)

test("Database: the schema version is account-wide, not per-profile", function()
    -- savedvariables-§1: a migration runs once per ACCOUNT. In `profile` it
    -- would re-run for every profile the user has, and a non-idempotent step
    -- would then run several times over data it had already moved.
    local inst = T.load{}
    assertTrue(inst.NS.db.global.schemaVersion ~= nil, "schemaVersion must live in db.global")
    assertNil(inst.NS.db.profile.schemaVersion, "schemaVersion must NOT live in db.profile")
    assertNil(NS.defaults.profile.schemaVersion)
    assertTrue(NS.defaults.global.schemaVersion ~= nil)
end)

test("Database: a version ahead of any registered step is walked forward, not spun on", function()
    -- The runner has no migrator at v1 by design. A `while` loop with no step
    -- and no bump would hang the client at login, which is the one failure worse
    -- than a bad migration.
    -- red under: `break`ing out of the loop without setting schemaVersion.
    local inst = preSeeded({
        profiles = { Default = {} },
        global   = { schemaVersion = 0 },
    })
    assertTrue(inst.NS.db.global.schemaVersion >= 1,
        "an older account must be walked forward to the current version")
end)

-- ── v1 -> v2: one uniform column width ──────────────────────────────────────

--- A v1 account whose windows carry the old per-stat widths.
local function v1Account(frameWidth)
    return preSeeded({
        profiles = {
            Default = {
                nextWindowId = 2,
                windows = { {
                    id = 1,
                    frame   = { width = frameWidth, padding = 6 },
                    columns = {
                        { stat = "DamageDone",           width = 92, showBar = true },
                        { stat = "Interrupts",           width = 48, showBar = true },
                        { stat = "Deaths",               width = 44, showBar = true },
                    },
                } },
            },
        },
        global = { schemaVersion = 1 },
    })
end

test("Database v2: every stored column is lifted to the one uniform width", function()
    -- A width is written into a window when it is CREATED, not read live off the
    -- catalog, so moving Const.COLUMN_WIDTH alone reaches new windows only. This
    -- step is what reaches the window the player already has.
    -- red under: bumping CURRENT_DB_VERSION without registering migrations[1].
    local inst = v1Account(480)
    local w = inst.NS.Database.FindWindow(1)

    for _, col in ipairs(w.columns) do
        assertEqual(col.width, inst.NS.Constants.COLUMN_WIDTH,
            col.stat .. " kept its old per-stat width")
    end
    assertEqual(inst.NS.db.global.schemaVersion, 3,
        "the walk must run all the way to the current version, not stop at v2")
end)

test("Database v2: the frame is widened to hold the new grid", function()
    -- The full default column set at one uniform width no longer fits the old
    -- 480 default, and a frame that clips its rightmost column reads as a broken
    -- window rather than as one that needs dragging.
    -- red under: migrating widths without touching frame.width.
    local Const = T.load{}.NS.Constants
    local columns = {}
    for _, key in ipairs(Const.DEFAULT_STAT_KEYS) do
        columns[#columns + 1] = { stat = key, width = 48, showBar = true }
    end

    local inst = preSeeded({
        profiles = { Default = { windows = { {
            id = 1, frame = { width = 480, padding = 6 }, columns = columns,
        } } } },
        global = { schemaVersion = 1 },
    })

    local needed = Const.NAME_COLUMN_WIDTH
        + #columns * (Const.COLUMN_WIDTH + Const.COLUMN_GAP) + 12
    assertEqual(inst.NS.Database.FindWindow(1).frame.width, needed,
        "480 could not hold the uniform grid and had to grow")
    assertEqual(needed, inst.NS.WINDOW_TEMPLATE.frame.width,
        "and the shipped default is that same computed width, not a guess")
end)

test("Database v2: a frame that already fits the grid is left alone", function()
    -- Three columns fit inside 480 comfortably, so there is nothing to fix and
    -- the migration must not resize a window for the sake of resizing it.
    assertEqual(v1Account(480).NS.Database.FindWindow(1).frame.width, 480)
end)

test("Database v2: a frame already wider than the grid is left alone", function()
    -- Only ever WIDENED. A player who dragged their window out to 900 chose that,
    -- and a migration that narrowed it would be undoing their layout to satisfy
    -- an arithmetic minimum.
    -- red under: `frame.width = needed` unconditionally.
    local inst = v1Account(900)
    assertEqual(inst.NS.Database.FindWindow(1).frame.width, 900)
end)

test("Database v2: EVERY saved profile is lifted, not just the active one", function()
    -- A profile the player has not activated this session is still theirs. Lifting
    -- only db.profile leaves the others stale AFTER schemaVersion has been stamped
    -- forward, so the step never gets a second chance at them.
    -- red under: iterating `{ db.profile }` instead of db.sv.profiles.
    local inst = preSeeded({
        profiles = {
            Default = { windows = { { id = 1,
                frame = { width = 480, padding = 6 },
                columns = { { stat = "Deaths", width = 44, showBar = true } } } } },
            Raid    = { windows = { { id = 7,
                frame = { width = 480, padding = 6 },
                columns = { { stat = "Deaths", width = 44, showBar = true } } } } },
        },
        global = { schemaVersion = 1 },
    })

    local raid = inst.NS.db.sv.profiles.Raid
    assertEqual(raid.windows[1].columns[1].width, inst.NS.Constants.COLUMN_WIDTH,
        "the inactive Raid profile was left at the old width")
end)

test("Database v2: the step is idempotent and survives a malformed window", function()
    -- Migrations run on every Init and every profile swap. A second pass must
    -- change nothing, and a hand-edited profile must not take the login down.
    local inst = preSeeded({
        profiles = { Default = { windows = {
            { id = 1, frame = "not a table", columns = { "not a column" } },
            { id = 2 },
        } } },
        global = { schemaVersion = 1 },
    })
    inst.NS:RunMigrations()
    assertEqual(inst.NS.db.global.schemaVersion, 3)
end)

test("Database: RunMigrations with no database is a no-op, not an error", function()
    local inst = T.load{ initDB = false, options = false }
    inst.NS:RunMigrations()
end)

test("Database: RunMigrations normalizes every window whatever the version claims", function()
    -- Shape normalization runs AFTER the version walk and unconditionally, so a
    -- profile that arrived from a copy or a hand edit is brought to the current
    -- shape even when its version says it is already current.
    local inst = preSeeded({
        profiles = { Default = { windows = { { id = 1 } } } },
        global   = { schemaVersion = 99 },
    })
    local w = inst.NS.Database.FindWindow(1)
    assertEqual(type(w.frame), "table", "a version-current profile was left unnormalized")
    assertEqual(w.frame.width, NS.WINDOW_TEMPLATE.frame.width)
end)

-- ── profile callbacks ───────────────────────────────────────────────────────

test("Database: a profile swap publishes PROFILE_CHANGED exactly once, with the new key",
function()
    -- Everything downstream rebuilds off this one message rather than off a
    -- direct call from core/Database.lua (architecture-§4).
    local inst = T.load{}
    local seen = { n = 0 }
    local target = inst.NS.NewBusTarget()
    target:RegisterMessage(MSG.PROFILE_CHANGED, function(_, payload)
        seen.n = seen.n + 1
        seen.key = payload and payload.newProfileKey
    end)
    swapProfile(inst, "Raid")
    assertEqual(seen.n, 1)
    assertEqual(seen.key, "Raid")
end)

test("Database: core/Database.lua is the only sender of PROFILE_CHANGED", function()
    local senders = {}
    for _, rel in ipairs(T.loadedAddonFiles) do
        local fh = io.open((T.root or ".") .. "/" .. rel, "r")
        local src = fh and fh:read("*a") or ""
        if fh then fh:close() end
        src = src:gsub("%-%-[^\r\n]*", "")
        if src:match("SendMessage%(%s*[%w_%.]*PROFILE_CHANGED") then senders[#senders + 1] = rel end
    end
    assertEqual(table.concat(senders, ", "), "core/Database.lua")
end)

test("Database: a profile swap clears the session state derived from the old profile", function()
    -- The active-window pointer names an id that may not exist in the new
    -- profile, and every cache was keyed against the old one.
    local inst = T.load{}
    inst.NS.State.SetActiveWindow(1)
    inst.NS.State.Cache("Roster").guid = "stale"
    swapProfile(inst, "Raid")
    assertNil(inst.NS.State.activeWindowId, "the active window pointer must be cleared")
    assertNil(inst.NS.State.Cache("Roster").guid, "the caches must be wiped")
end)

test("Database: the profile a swap lands on is migrated and normalized before anything reads it",
function()
    -- A copy may have been authored at an older schema version, and a reset
    -- lands on an empty registry. Both need the full pass before a window is
    -- read, which is why OnProfileChanged calls RunMigrations rather than
    -- assuming Init already did.
    local inst = T.load{}
    swapProfile(inst, "Raid")
    local windows = inst.NS.Database.GetWindows()
    assertEqual(#windows, 1, "the new profile must be seeded")
    assertEqual(type(windows[1].frame), "table", "and normalized")
end)

test("Database: a profile RESET re-seeds rather than leaving an empty registry", function()
    -- AceDB passes nil for the profile key on OnProfileReset, so the handler
    -- substitutes the active one. A nil key reaching the message payload would
    -- be a subscriber told the profile changed to nothing.
    local inst = T.load{}
    local seen = {}
    local target = inst.NS.NewBusTarget()
    target:RegisterMessage(MSG.PROFILE_CHANGED, function(_, p) seen.key = p and p.newProfileKey end)
    resetProfile(inst)
    assertEqual(seen.key, "Default", "the reset must name the active profile, not nil")
    assertEqual(#inst.NS.Database.GetWindows(), 1)
end)

-- ---------------------------------------------------------------------------
-- v2 -> v3: the three row-icon toggles collapse into one
-- ---------------------------------------------------------------------------

--- A v2 account whose single window carries the three old icon flags.
local function v2Icons(flags)
    return preSeeded({
        profiles = {
            Default = {
                nextWindowId = 2,
                windows = { { id = 1, icons = flags } },
            },
        },
        global = { schemaVersion = 2 },
    })
end

test("Database v3: ANY of the three old icon flags means the icon stays on", function()
    -- Somebody running the ROLE icon alone had asked for an icon. Reading only
    -- showClass would take it away from them without asking — the new slot
    -- answers the same question better rather than withdrawing the answer.
    -- red under: `icons.showIcon = icons.showClass`.
    for _, flags in ipairs({
        { showClass = true,  showSpec = false, showRole = false },
        { showClass = false, showSpec = true,  showRole = false },
        { showClass = false, showSpec = false, showRole = true  },
    }) do
        local inst = v2Icons(flags)
        assertEqual(inst.NS.Database.FindWindow(1).icons.showIcon, true,
            "a window with an icon on lost it in the migration")
    end
end)

test("Database v3: all three off stays off", function()
    -- The one combination that must NOT turn an icon on: a player who had
    -- deliberately cleared the name column keeps it clear.
    -- red under: defaulting showIcon to true regardless.
    local inst = v2Icons{ showClass = false, showSpec = false, showRole = false }
    assertEqual(inst.NS.Database.FindWindow(1).icons.showIcon, false,
        "a deliberately icon-free window got one back")
end)

test("Database v3: the three dead keys are REMOVED, not left to rot", function()
    -- AceDB merges defaults into a stored profile but never prunes what the
    -- defaults stopped naming, so without this they sit in every saved profile
    -- forever and the next reader has to work out which of four keys the code
    -- honours.
    -- red under: setting showIcon without clearing the old flags.
    local inst = v2Icons{ showClass = true, showSpec = true, showRole = true }
    local icons = inst.NS.Database.FindWindow(1).icons

    assertNil(icons.showClass, "showClass survived the migration")
    assertNil(icons.showSpec,  "showSpec survived the migration")
    assertNil(icons.showRole,  "showRole survived the migration")
    assertEqual(inst.NS.db.global.schemaVersion, 3)
end)
