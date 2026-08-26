-- tests/test_lifecycle.lua — core/MultiMeters.lua: the AceAddon bootstrap, the
-- addon's SINGLE game-event listener, and the show ladder.
--
-- A load-only harness runs to the bottom of the TOC and stops, which is the
-- blind spot this suite closes: the client then runs OnInitialize and, at
-- PLAYER_LOGIN, the whole OnEnable cascade — and that is where a module's bus
-- subscriptions are installed and where a nil method finally raises. Every case
-- below drives a FRESH instance through that cascade (`T.load{ enable = true }`)
-- rather than asserting about a namespace that never woke up.
--
-- The event fan-out is the other half. This addon registers game events in
-- EXACTLY ONE place and republishes them on the closed message bus
-- (architecture-§4), so "the game said something" becomes "the addon knows" in
-- one reviewable file. A module that grew its own RegisterEvent would be a
-- second answer to the same question, invisible until the two disagreed.

local T = _G.MULTIMETERS_TEST
local NS = T.NS
local test, assertEqual, assertTrue, assertFalse, assertNil =
    T.test, T.assertEqual, T.assertTrue, T.assertFalse, T.assertNil

local MSG  = NS.Constants.MSG
local ROOT = T.root or "."

-- The seven AceAddon children, in TOC order (grep: modules/ for `NS:NewModule`).
-- Kept as data so a newly-added module is deliberately wired into coverage
-- rather than silently skipped.
local MODULES = {
    "Provider", "Roster", "Feign", "Aggregator", "WindowManager", "Tooltip",
    "DrillDown", "Visibility",
}

-- Every game event core/MultiMeters.lua claims, and the handler it names.
local EVENTS = {
    PLAYER_ENTERING_WORLD                = "OnEnteringWorld",
    GROUP_ROSTER_UPDATE                  = "OnRosterUpdate",
    ZONE_CHANGED_NEW_AREA                = "OnZoneChanged",
    ADDON_RESTRICTION_STATE_CHANGED      = "OnRestrictionChanged",
    DAMAGE_METER_CURRENT_SESSION_UPDATED = "OnMeterUpdated",
    DAMAGE_METER_COMBAT_SESSION_UPDATED  = "OnMeterSession",
    UNIT_SPELLCAST_SUCCEEDED       = "OnSpellSucceeded",
    -- System chat, filtered to one line: the whisper-target error that cancels
    -- an export dump. Like the feign cast above it, nothing reaches the bus.
    CHAT_MSG_SYSTEM                      = "OnSystemMessage",
    DAMAGE_METER_RESET                   = "OnMeterReset",
    -- Player state, for modules/Visibility.lua's rules. PLAYER_IS_GLIDING_CHANGED
    -- is the probed one — see the case below that takes it away.
    PLAYER_REGEN_DISABLED                = "OnCombatChanged",
    PLAYER_REGEN_ENABLED                 = "OnCombatChanged",
    PLAYER_MOUNT_DISPLAY_CHANGED         = "OnPlayerStateChanged",
    UNIT_ENTERED_VEHICLE                 = "OnPlayerStateChanged",
    UNIT_EXITED_VEHICLE                  = "OnPlayerStateChanged",
    UPDATE_SHAPESHIFT_FORM               = "OnPlayerStateChanged",
    PLAYER_CAN_GLIDE_CHANGED             = "OnPlayerStateChanged",
    PLAYER_IS_GLIDING_CHANGED            = "OnPlayerStateChanged",
    PET_BATTLE_OPENING_START             = "OnPlayerStateChanged",
    PET_BATTLE_CLOSE                     = "OnPlayerStateChanged",
    PLAYER_DEAD                          = "OnPlayerStateChanged",
    PLAYER_ALIVE                         = "OnPlayerStateChanged",
    PLAYER_UNGHOST                       = "OnPlayerStateChanged",
}

--- Count publications of `message` on an instance, capturing the last payload.
local function watch(inst, message)
    local seen = { n = 0 }
    local target = inst.NS.NewBusTarget()
    target:RegisterMessage(message, function(_, payload)
        seen.n = seen.n + 1
        seen.last = payload
    end)
    return seen
end

-- ── the bootstrap ───────────────────────────────────────────────────────────

test("Lifecycle: NS IS the AceAddon object, promoted in place", function()
    -- NewAddon promotes the table it is handed, so there is no _G.MultiMeters
    -- rebind and there never will be: the namespace stays private
    -- (architecture-§1). NS.addon is published anyway so a caller has a name for
    -- "the AceAddon object" that does not assume the promotion.
    local inst = T.load{}
    assertTrue(inst.NS.addon == inst.NS, "NS.addon must be the same table as NS")
    assertEqual(type(inst.NS.SendMessage), "function", "AceEvent must be embedded")
    assertEqual(type(inst.NS.ScheduleTimer), "function", "AceTimer must be embedded")
    assertNil(_G.MultiMeters, "the namespace must not be rebound to a global")
end)

test("Lifecycle: every module registers, and the enable cascade runs them all", function()
    -- Any OnEnable throwing — a nil method, a bad message name — propagates out
    -- of __enableAll and fails here with the real error.
    local inst = T.load{ enable = true }
    for _, name in ipairs(MODULES) do
        assertTrue(inst.NS:GetModule(name, true) ~= nil, name .. " did not register")
    end
    assertEqual(#inst.NS.__moduleOrder, #MODULES,
        "the module count moved: " .. table.concat(inst.NS.__moduleOrder, ", "))
end)

test("Lifecycle: every module is also published under its flat NS name", function()
    -- NewModule writes the module into AceAddon's registry and NOWHERE else — it
    -- does not hang it on NS — so the flat name every caller outside the module
    -- uses has to be assigned explicitly. Without it those call sites find nil
    -- and silently do nothing, which is a whole surface going quiet with no
    -- error to say so.
    -- red under: deleting `NS.WindowManager = M` from modules/WindowManager.lua.
    local inst = T.load{}
    for _, name in ipairs(MODULES) do
        assertTrue(inst.NS[name] ~= nil, "NS." .. name .. " is not published")
        assertTrue(inst.NS[name] == inst.NS:GetModule(name),
            "NS." .. name .. " is not the registered module")
    end
end)

-- ── the printer reclaim ─────────────────────────────────────────────────────

test("Lifecycle: the AceConsole embed is reclaimed on the line after NewAddon", function()
    -- AceConsole stamps its own `:Print` onto the namespace during NewAddon:
    -- green, trailing colon, no cyan tag, no error and nothing anywhere to say
    -- the addon's printer was replaced (anti-pattern #36).
    -- red under: deleting the reclaim block.
    local inst = T.load{}
    assertTrue(inst.NS.Print == inst.NS.Util.print, "NS.Print is not the library printer")
    inst.NS.Print("line")
    local line = inst.mocks.__chat[#inst.mocks.__chat]
    assertNil(line:match("^|cff33ff99"), "AceConsole's printer answered: " .. line)
end)

-- ── OnInitialize ────────────────────────────────────────────────────────────

test("Lifecycle: OnInitialize builds the database FIRST", function()
    -- After InitDB returns, NS.db is live — a contract every module relies on,
    -- and the reason it is first. The minimap launcher in particular must come
    -- after it, because LibDBIcon stores the button's position in
    -- NS.db.profile.minimap and registering earlier would hand it a table that
    -- is thrown away on the next profile swap.
    -- red under: moving the InitDB call below the Minimap.Init call.
    local src = assert(io.open(ROOT .. "/core/MultiMeters.lua", "r")):read("*a")
    local body = src:match("function NS:OnInitialize%(%)(.-)\nend")
    assertTrue(body ~= nil, "could not find OnInitialize")
    local dbAt      = body:find("self:InitDB()", 1, true)
    local minimapAt = body:find("NS.Minimap.Init()", 1, true)
    local optionsAt = body:find("NS.CreateOptionsPanel()", 1, true)
    local slashAt   = body:find("NS.Slash:Register()", 1, true) or body:find("Slash:Register", 1, true)
    assertTrue(dbAt ~= nil and minimapAt ~= nil and optionsAt ~= nil and slashAt ~= nil,
        "OnInitialize no longer performs all four lifecycle steps")
    assertTrue(dbAt < minimapAt, "the minimap button is registered before the profile exists")
    assertTrue(dbAt < optionsAt, "the options panel is created before the database")
    assertTrue(optionsAt < slashAt, "the slash verbs are claimed before the panel they open")
end)

test("Lifecycle: OnInitialize runs end to end on a fresh client", function()
    local inst = T.load{ initDB = false, options = false }
    inst.NS:OnInitialize()
    assertTrue(inst.NS.db ~= nil, "the database must be live after OnInitialize")
    assertEqual(#inst.NS.Database.GetWindows(), 1, "the registry must be seeded")
end)

test("Lifecycle: with the settings layer gone, `/mm` is claimed anyway and says why", function()
    -- Swallowing the verbs entirely looks like the addon is not installed, which
    -- sends the player looking in the wrong place.
    -- red under: `if NS.Slash then ... end` with no else branch.
    local inst = T.load{ initDB = false, options = false }
    inst.NS.Slash = nil
    local claimed = {}
    inst.NS.RegisterChatCommand = function(_, token, handler)
        claimed[token] = handler
    end
    inst.NS:OnInitialize()
    assertTrue(claimed.mm ~= nil, "/mm was not claimed")
    assertTrue(claimed.multimeters ~= nil, "/multimeters was not claimed")

    local before = #inst.mocks.__chat
    claimed.mm("")
    assertTrue(#inst.mocks.__chat > before, "the fallback handler said nothing")
    assertTrue(inst.mocks.__chat[#inst.mocks.__chat]:find("settings layer", 1, true) ~= nil)
end)

-- ── the single game-event listener ──────────────────────────────────────────

test("Lifecycle: OnEnable registers exactly the events the fan-out handles", function()
    local inst = T.load{ enable = true }
    local registered = inst.NS.__events
    for event, handler in pairs(EVENTS) do
        assertEqual(registered[event], handler, event .. " is not registered to " .. handler)
        assertEqual(type(inst.NS[handler]), "function", handler .. " is not a function on NS")
    end
    local extra = {}
    for event in pairs(registered) do
        if EVENTS[event] == nil then extra[#extra + 1] = event end
    end
    table.sort(extra)
    assertEqual(table.concat(extra, ", "), "",
        "core/MultiMeters.lua registered an event with no case covering it")
end)

test("Lifecycle: no module registers a game event of its own", function()
    -- architecture-§4. One place where "the game said something" becomes "the
    -- addon knows"; a second listener is a second source of truth for the same
    -- transition, and the two only disagree under load.
    -- red under: adding a RegisterEvent to any module.
    for _, rel in ipairs(T.loadedAddonFiles) do
        local fh = io.open(ROOT .. "/" .. rel, "r")
        local src = fh and fh:read("*a"):gsub("%-%-[^\r\n]*", "") or ""
        if fh then fh:close() end
        local low = rel:lower()
        -- core/MultiMeters.lua owns the addon's events; core/LSMPatch.lua owns
        -- its own one-shot PLAYER_LOGIN frame, which is a widget hook rather
        -- than an addon event and is documented as such in its header.
        if low ~= "core/multimeters.lua" and low ~= "core/lsmpatch.lua" then
            assertNil(src:match("[^%w]RegisterEvent%s*%("),
                rel .. " registers a game event — the fan-out in core/MultiMeters.lua owns them")
        end
    end
end)

test("Lifecycle: both combat edges fan out as one message carrying nothing", function()
    local inst = T.load{ enable = true }
    local seen = watch(inst, MSG.COMBAT_CHANGED)

    -- Which edge it was is deliberately not published. The only subscriber reads
    -- UnitAffectingCombat live, and a payload would be a second answer that can
    -- disagree with the first across a death, where PLAYER_REGEN_ENABLED does not
    -- reliably fire.
    inst.NS:OnCombatChanged()
    assertEqual(seen.n, 1)
    assertNil(seen.last)
end)

test("Lifecycle: every player-state edge fans out as PLAYER_STATE_CHANGED", function()
    local inst = T.load{ enable = true }
    local seen = watch(inst, MSG.PLAYER_STATE_CHANGED)

    -- Mounting, shapeshifting, gliding, a pet battle, dying and coming back all
    -- ask the same question of the same subscriber: re-check where this window is
    -- allowed to be. Eight messages with one handler between them would be eight
    -- names to keep in step for no gain.
    -- The two vehicle events are the only ones in the block whose arg1 is a unit
    -- token, and they are filtered to the player; every other event carries no
    -- argument or carries its own payload. Driving them all with the same bare
    -- call would test the filter, not the fan-in.
    local UNIT_ARG = { UNIT_ENTERED_VEHICLE = "player", UNIT_EXITED_VEHICLE = "player" }

    local n = 0
    for event, handler in pairs(EVENTS) do
        if handler == "OnPlayerStateChanged" then
            n = n + 1
            inst.NS[handler](inst.NS, event, UNIT_ARG[event])
        end
    end
    assertTrue(n >= 10, "the player-state fan-in lost its events")
    assertEqual(seen.n, n)
end)

test("Lifecycle: a client with no PLAYER_IS_GLIDING_CHANGED still enables", function()
    -- Taking off while staying mounted is the newest edge of the set, and a
    -- client that has not got it raises on RegisterEvent. Losing it costs the
    -- skyriding rule a refresh tick, not an answer, so the addon must load
    -- straight past it rather than guard the whole feature behind it.
    local inst = T.load{ enable = true, mutate = function(m)
        m.setEventInvalid("PLAYER_IS_GLIDING_CHANGED")
    end }
    assertNil(inst.NS.__events["PLAYER_IS_GLIDING_CHANGED"])
    assertEqual(inst.NS.__events["PLAYER_CAN_GLIDE_CHANGED"], "OnPlayerStateChanged",
        "the rest of the set must still be registered")
end)

test("Lifecycle: PLAYER_ENTERING_WORLD is republished with its login/reload flags", function()
    local inst = T.load{ enable = true }
    local seen = watch(inst, MSG.ENTERING_WORLD)
    assertTrue(inst.NS:__fireEvent("PLAYER_ENTERING_WORLD", true, false), "the event did not fire")
    assertEqual(seen.n, 1)
    assertEqual(seen.last.isLogin, true)
    assertEqual(seen.last.isReload, false)
end)

test("Lifecycle: the roster cache is dropped BEFORE ROSTER_CHANGED goes out", function()
    -- A subscriber that rebuilds synchronously must not be handed the stale map.
    -- Ordering, not just "both happen" — so the assertion is taken from INSIDE
    -- the subscriber.
    -- red under: moving the WipeCache call below the SendMessage.
    local inst = T.load{ enable = true }
    inst.NS.State.Cache("Roster")["Player-1-1"] = "stale"
    local sawStale
    local target = inst.NS.NewBusTarget()
    target:RegisterMessage(MSG.ROSTER_CHANGED, function()
        sawStale = inst.NS.State.Cache("Roster")["Player-1-1"]
    end)
    inst.NS:__fireEvent("GROUP_ROSTER_UPDATE")
    assertNil(sawStale, "a subscriber was handed the stale roster cache")
end)

test("Lifecycle: a meter reset wipes EVERY cache before publishing", function()
    -- Not just the roster's: a reset invalidates the formatter instances and
    -- anything else derived from a session that no longer exists.
    local inst = T.load{ enable = true }
    inst.NS.State.Cache("Roster").a = 1
    inst.NS.State.Cache("Format").b = 2
    local seen = {}
    local target = inst.NS.NewBusTarget()
    target:RegisterMessage(MSG.METER_RESET, function()
        seen.roster = inst.NS.State.Cache("Roster").a
        seen.format = inst.NS.State.Cache("Format").b
    end)
    inst.NS:__fireEvent("DAMAGE_METER_RESET")
    assertNil(seen.roster)
    assertNil(seen.format)
end)

test("Lifecycle: the session event forwards its payload, which is never secret", function()
    -- Both values identify a session rather than describe one, so they arrive
    -- plain even mid-pull — which is what makes the session picker legal.
    local inst = T.load{ enable = true }
    inst.mocks.setRestricted(true)
    local seen = watch(inst, MSG.METER_SESSION)
    inst.NS:__fireEvent("DAMAGE_METER_COMBAT_SESSION_UPDATED", 0, 4242)
    assertEqual(seen.n, 1)
    assertEqual(seen.last.type, 0)
    assertEqual(seen.last.sessionID, 4242)
end)

test("Lifecycle: the meter update event is a bare republication", function()
    local inst = T.load{ enable = true }
    local seen = watch(inst, MSG.METER_UPDATED)
    inst.NS:__fireEvent("DAMAGE_METER_CURRENT_SESSION_UPDATED")
    inst.NS:__fireEvent("DAMAGE_METER_CURRENT_SESSION_UPDATED")
    assertEqual(seen.n, 2, "every meter tick must reach the bus; the WINDOW owns the throttle")
end)

test("Lifecycle: the three meter handlers carry the meterEvent bracket", function()
    -- They are the addon's one hot path. The bracket measures the FAN-OUT — the
    -- SendMessage walks every subscribed window's callback synchronously, which
    -- is the cost that scales with window count at raid event rate.
    local inst = T.load{ enable = true }
    local P = inst.NS.Perf
    P.on = true
    P.Reset()
    inst.NS:__fireEvent("DAMAGE_METER_CURRENT_SESSION_UPDATED")
    inst.NS:__fireEvent("DAMAGE_METER_COMBAT_SESSION_UPDATED", 0, 1)
    inst.NS:__fireEvent("DAMAGE_METER_RESET")
    P.on = false
    local bucket = P.__buckets().meterEvent
    assertTrue(bucket ~= nil, "the meterEvent bucket was never reached")
    assertEqual(bucket.calls, 3, "all three meter handlers must be bracketed")
end)

-- ── the restriction edge ────────────────────────────────────────────────────

test("Lifecycle: OnEnable seeds the restriction mirror from the LIVE state", function()
    -- A /reload taken mid-pull re-enables the addon inside an active
    -- restriction, and ADDON_RESTRICTION_STATE_CHANGED has already fired by then
    -- — there is no second edge to catch.
    -- red under: leaving State.restricted at its `false` default in OnEnable.
    local inst = T.load{ mutate = function(m) m.setRestricted(true) end }
    assertFalse(inst.NS.State.restricted, "the mirror starts at its default")
    inst.NS:OnEnable()
    assertTrue(inst.NS.State.restricted, "the mirror was not seeded from the live state")
end)

test("Lifecycle: the restriction event updates the mirror and forwards the RAW state", function()
    -- Collapsing the state to a boolean here would throw away the Activating
    -- edge — the last moment a correct value-sort can be taken (design §5).
    -- red under: publishing `{ restricted = true }` instead of the raw state.
    local inst = T.load{ enable = true }
    local seen = watch(inst, MSG.RESTRICTION_CHANGED)
    local STATE = inst.NS.Secrets.STATE

    inst.mocks.setRestricted(true)
    inst.mocks.setRestrictionState(STATE.Activating)
    inst.NS:__fireEvent("ADDON_RESTRICTION_STATE_CHANGED", 0, STATE.Activating)
    assertEqual(seen.n, 1)
    assertEqual(seen.last.type, 0)
    assertEqual(seen.last.state, STATE.Activating, "the raw state must survive the fan-out")
    assertTrue(inst.NS.State.restricted, "the mirror must follow the client, not the payload")

    inst.mocks.setRestricted(false)
    inst.mocks.setRestrictionState(nil)
    inst.NS:__fireEvent("ADDON_RESTRICTION_STATE_CHANGED", 0, STATE.Inactive)
    assertFalse(inst.NS.State.restricted)
end)

-- ── the show ladder ─────────────────────────────────────────────────────────

test("ShouldShow: the ladder answers a reason that names the step that decided", function()
    -- `/mm debug diag` prints it and these tests assert on it, so it is a stable
    -- unlocalized token rather than a sentence.
    local inst = T.load{ enable = true }
    inst.mocks.setInstance("party")
    inst.mocks.setGroup({ {}, {}, {}, {}, {} })
    local window = inst.NS.Database.GetWindows()[1]

    local ok, reason = inst.NS.ShouldShow(window)
    assertTrue(ok)
    assertEqual(reason, "shown")
end)

test("ShouldShow: a non-table is refused before anything else is consulted", function()
    local inst = T.load{}
    local ok, reason = inst.NS.ShouldShow(nil)
    assertFalse(ok)
    assertEqual(reason, "no window")
end)

test("ShouldShow: the master enable refuses every window", function()
    local inst = T.load{ enable = true }
    inst.mocks.setInstance("party")
    inst.mocks.setGroup({ {}, {}, {}, {}, {} })
    local window = inst.NS.Database.GetWindows()[1]
    inst.NS.db.profile.enabled = false
    local ok, reason = inst.NS.ShouldShow(window)
    assertFalse(ok)
    assertEqual(reason, "disabled")
end)

test("ShouldShow: test mode overrides context, so a window can be positioned anywhere", function()
    -- The whole point is to lay columns out wherever the player happens to be
    -- standing — which is normally the open world, where the window ships off.
    -- red under: putting the preview step below the context step.
    local inst = T.load{ enable = true }
    inst.mocks.setSolo()
    inst.mocks.setInstance("none")
    local window = inst.NS.Database.GetWindows()[1]
    window.visibility.world = false   -- every context ships on; refuse one by hand
    assertFalse((inst.NS.ShouldShow(window)), "the fixture needs a context that refuses")

    inst.NS.State.SetTestMode(true)
    local ok, reason = inst.NS.ShouldShow(window)
    assertTrue(ok)
    assertEqual(reason, "test")
end)

test("ShouldShow: the context rules are Visibility's, consulted rather than reimplemented",
function()
    -- Duplicating them in the ladder would give the addon two places that can
    -- answer "why is my window not showing" differently.
    local inst = T.load{ enable = true }
    local window = inst.NS.Database.GetWindows()[1]
    window.visibility.world = false
    window.visibility.hideWhenSolo = true
    inst.mocks.setInstance("none")
    inst.mocks.setSolo()
    local ok, reason = inst.NS.ShouldShow(window)
    assertFalse(ok)
    assertEqual(reason, "world", "the ladder must forward Visibility's own reason token")

    inst.mocks.setInstance("party")
    inst.mocks.setSolo()
    assertEqual(select(2, inst.NS.ShouldShow(window)), "solo")
end)

test("ShouldShow: a missing Visibility module fails OPEN", function()
    -- A broken module must not make the addon look uninstalled.
    -- red under: `if not Visibility then return false end`.
    local inst = T.load{ enable = true }
    inst.mocks.setInstance("none")
    inst.mocks.setSolo()
    local window = inst.NS.Database.GetWindows()[1]
    window.visibility.world = false
    assertFalse((inst.NS.ShouldShow(window)), "the fixture needs Visibility to be refusing first")

    inst.NS.__modules.Visibility = nil
    local ok, reason = inst.NS.ShouldShow(window)
    assertTrue(ok, "the ladder must fail open when the module is gone")
    assertEqual(reason, "shown")
end)
