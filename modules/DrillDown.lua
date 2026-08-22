-- modules/DrillDown.lua
--
-- Clicking a cell replaces the window's grid with the story behind that one
-- number: which spells made up this player's damage, which kicks landed on
-- what, which avoidable hits actually connected. A back button returns to the
-- grid, and nothing about the trip is remembered past the session.
--
-- ---------------------------------------------------------------------------
-- ONE RENDERER, NOT TWO
-- ---------------------------------------------------------------------------
--
-- The obvious implementation is a second view with its own frames, its own
-- layout code and its own idea of what a row looks like. It is also the
-- implementation that drifts: the grid grows a font setting and the drill-down
-- does not, the grid learns about secret values and the drill-down learns about
-- them a patch later, in combat, in front of the player.
--
-- So this file builds no frames for rows at all. BuildRows() returns rows in the
-- SAME SHAPE modules/Aggregator.lua produces, and modules/Window.lua feeds them
-- to the same row pool and the same cell render path it already has. A spell is
-- a "row" whose name is the spell's name and whose one value is the spell's
-- amount. Everything the player configured about rows, bars, text and fonts
-- applies to the drill-down for free, because it is literally the same code
-- drawing it.
--
-- The ONLY widget this module owns is the back button, which the grid has no
-- equivalent of and which is three lines of frame code.
--
-- ---------------------------------------------------------------------------
-- COMBAT AND SECRETS
-- ---------------------------------------------------------------------------
--
-- Everything here works in combat. These are plain unprotected frames, so there
-- is no InCombatLockdown gate anywhere below and there must not be one: the
-- moment a raider most wants to know what killed them is the moment they are
-- still fighting.
--
-- What it must not do is look at a value. Nothing below adds, compares, keys on
-- or measures a meter amount:
--   * the spell walk goes through NS.Secrets.SafeIterate, which never applies
--     `#` to a possibly-secret array;
--   * amounts are copied into the row table as opaque handles and travel
--     untouched to the widget setters;
--   * ordering is left exactly as the API returned it. The drill-down does NOT
--     sort. modules/Tooltip.lua sorts when comparison is legal because a tooltip
--     is a snapshot; a drill-down is a live view that would reshuffle under the
--     cursor the instant the restriction lifted, which is worse than an order
--     the player can learn.
--
-- THE TITLE IS DISPLAY-ONLY. DrillDown.Title() builds its string with
-- string.format from `view.name`, which is the meter's ConditionalSecret name —
-- a folded pet whose owner has left, a cross-realm source, a stale roster entry
-- all make it opaque mid-pull. string.format on a secret returns a SECRET
-- STRING, and a secret string poisons everything a caller's instinct wants to do
-- with it: `if title then`, `title ~= ""`, `#title`, using it as a table key.
-- Every one of those raises while the restriction is active.
--
-- So the title travels to a SetText and nowhere else, and the question "is this
-- window drilled in" is answered by a PLAIN BOOLEAN that never touches the
-- string:
--
--   DrillDown.IsActive(window)  -> boolean
--   DrillDown:BuildRows(window) -> rows|nil, title|nil, active (boolean)
--
-- The third return of BuildRows is that same boolean, handed back at the call
-- site that needs it so a consumer never has to reach for the title to find out
-- whether there is one.
--
-- ---------------------------------------------------------------------------
-- STATE
-- ---------------------------------------------------------------------------
--
-- Drill-down state is per window and SESSION-ONLY — it lives in core/State.lua's
-- cache, never in SavedVariables. Logging in to a view of one spell breakdown
-- from last week's raid would be nonsense, and worse, it would be a stored
-- reference to a sourceGUID that no longer exists.
--
-- Living in State.Cache buys one more thing: core/MythicMeters.lua already wipes
-- every cache on DAMAGE_METER_RESET and on a profile change, and both of those
-- invalidate a breakdown completely. The wipe is in place, so the upvalue below
-- keeps pointing at the live table (see core/State.lua's WipeCache).

local addonName, NS = ...

local DrillDown = NS:NewModule("DrillDown", "AceEvent-3.0")
NS.DrillDown = DrillDown

local L      = NS.L
local Const  = NS.Constants
local Compat = NS.Compat
local State  = NS.State
local Debug  = NS.Debug

local Perf = NS.Perf or {}

-- [windowId] = { guid, statKey, kind, deaths, name, classFilename,
--                sessionType, sessionID }
--
-- `kind` is "spells" or "deaths" and picks which breakdown BuildRows produces.
-- `deaths` exists only on the second kind: a plain array of recap ids, copied
-- out of the aggregated row at Enter.
--
-- IT IS A SNAPSHOT, AND HAS TO BE. While a window is drilled in,
-- modules/Window.lua renders BuildRows INSTEAD of running an aggregate pass, so
-- there is no current row to re-read the deaths off. The consequence is
-- narrow and worth stating: a player who dies again while somebody is staring
-- at their death list will not see the new death until the list is left and
-- re-entered. Re-deriving it would cost a second aggregate pass per frame to
-- keep a list fresh that nobody is watching change.
local views = State.Cache("DrillDown")

-- [windowId] = Button. Frames are never destroyed, only hidden and reused —
-- creating one per entry into a drill-down would leak a frame per click for the
-- life of the session.
local backButtons = {}

-- Bus message announcing that a window entered or left a drill-down.
--
-- The catalog in core/Constants.lua is the ONLY source. A hand-spelled `or`
-- fallback would defeat the exact protection the catalog exists to give: a
-- misspelled or removed key must fail loudly at load, not quietly ship a name
-- that no subscriber is listening on. THIS FILE IS THE ONE SENDER
-- (architecture-§4); the payload is { windowId = number, active = boolean }.
local MSG_DRILLDOWN = Const.MSG.DRILLDOWN_CHANGED

-- Hard ceiling on drill-down rows. The row pool is sized for a raid, and a
-- breakdown with more entries than a raid has players is past the point where
-- anyone reads it; the cap keeps one pathological source from asking the pool
-- for hundreds of frames.
local MAX_SPELL_ROWS = Const.MAX_ROWS

-- What a death row shows instead of a wall clock when the client no longer
-- holds the recap. An em dash rather than an empty cell, so the row reads as
-- "there was a death here and its detail is gone" rather than as a render bug.
local NO_CLOCK = "\226\128\148"

-- inv_misc_bone_skull_03, the same icon the Deaths tooltip uses. Every row in
-- this view is a death, so the icon holds the column rather than telling one
-- row from another -- and a blank square where every other row in the addon has
-- an icon reads as a texture that failed to load.
local DEATH_ICON = 237275


local BACK_BUTTON_WIDTH  = 64
local BACK_BUTTON_HEIGHT = 18

-- ---------------------------------------------------------------------------
-- Collaborators
-- ---------------------------------------------------------------------------

--- modules/Provider.lua, resolved at call time — modules/ load in TOC order and
--- this file does not get to assume it is last.
local function provider()
    if NS.Provider then return NS.Provider end
    if NS.GetModule then return NS:GetModule("Provider", true) end
    return nil
end

--- A window's id, tolerating both a config table and a bare id.
local function windowIdOf(window)
    if type(window) == "table" then return window.id end
    return window
end

--- Which session this window reads.
local function sessionTypeOf(window)
    local data = type(window) == "table" and window.data or nil
    if data and data.sessionType ~= nil then return data.sessionType end
    return Const.SESSION_TYPE.Current
end

--- Which stored SEGMENT this window is pointed at, or nil for "the one
--- sessionType names".
---
--- Captured into the view alongside the type, so a breakdown opened on a
--- historical segment keeps showing that segment's spells rather than silently
--- switching to the live pull's the moment the next one starts.
local function sessionIDOf(window)
    local data = type(window) == "table" and window.data or nil
    return data and data.sessionID or nil
end

--- Announce a change to whoever is drawing this window.
---
--- A message rather than a direct call into modules/Window.lua: the window
--- registry is WindowManager's and the render loop is Window's, and reaching
--- into either from here is the cross-module grab architecture-§4 exists to stop.
local function announce(windowId, active)
    if NS.SendMessage then
        NS:SendMessage(MSG_DRILLDOWN, { windowId = windowId, active = active })
    end
end

-- ---------------------------------------------------------------------------
-- Death recap
-- ---------------------------------------------------------------------------

--- The recap ids on an aggregated row, as a fresh plain array, or nil.
---
--- COPIED, never referenced. modules/Aggregator.lua rebuilds every row from
--- scratch on the next pass, so holding its `deaths` table would pin an object
--- that is about to be garbage — the same reason Enter copies name and guid
--- rather than keeping the row.
---
--- A recap id is NeverSecret and this still vets each one: an id that could not
--- be used as a table key could not be memoized, passed to the client, or
--- printed, so it is dropped here rather than at three later places.
---
--- @param deaths table|nil  row.deaths, a flat array of ids
--- @return table|nil  a fresh flat array, newest first
local function copyRecapIDs(deaths)
    if type(deaths) ~= "table" then return nil end
    local Secrets = NS.Secrets
    local ids = {}
    for i = 1, #deaths do
        local id = deaths[i]
        -- EVERY DEATH KEEPS ITS SLOT, openable or not. An id the client withheld
        -- arrives as `false` and an id we may not use is turned into one here, so
        -- the list is always exactly as long as the count it was opened from.
        -- Dropping either would make the drill-down and the cell above it
        -- disagree about how many times somebody died.
        if id ~= false and id ~= nil and (not Secrets or Secrets.IsSafeKey(id)) then
            ids[#ids + 1] = id
        else
            ids[#ids + 1] = false
        end
    end
    if #ids == 0 then return nil end
    return ids
end

--- The session offsets on an aggregated row, as a fresh plain array.
---
--- Padded to the length of the ids it accompanies, because the two are read by
--- INDEX: a short array would silently label each death with the previous one's
--- time, which is worse than labelling none of them.
---
--- @param times table|nil   row.deathTimes
--- @param deaths table|nil  row.deaths, for the length
--- @return table|nil
local function copyOffsets(times, deaths)
    if type(deaths) ~= "table" then return nil end
    local out = {}
    for i = 1, #deaths do
        local when = (type(times) == "table") and times[i] or nil
        if when == nil then when = false end
        out[i] = when
    end
    return out
end

--- Whether an offset is a figure rather than the client's way of saying it has
--- none.
---
--- THREE WAYS TO HAVE NO OFFSET, and -1 is the one that bites: it is what the
--- OVERALL session reports for every death it holds, it is a perfectly ordinary
--- number, and treating it as one dates a death "00:00 into the fight". `false`
--- is modules/Aggregator.lua's placeholder, and nil is a row built before any of
--- this existed.
---
--- @param offset any
--- @return boolean
local function usableOffset(offset)
    if offset == nil or offset == false then return false end
    local Secrets = NS.Secrets
    if Secrets and Secrets.CanCompare and not Secrets.CanCompare(offset) then
        return false
    end
    return type(offset) == "number" and offset >= 0
end

--- Which timestamp style this window is set to.
--- @param window table|number
--- @return string|nil
local function timeStyleOf(window)
    local text = type(window) == "table" and window.text or nil
    return text and text.deathTimeFormat or nil
end

--- Whether this client can open a death at all.
---
--- Asked BEFORE entering the deaths view rather than discovered inside it: a
--- view whose every row says "no recap" is worse than the hand-off below, which
--- is what a client without C_DeathRecap has always had.
---
--- @return boolean
local function canReadRecaps()
    local P = provider()
    return (P and P.CanReadRecaps and P.CanReadRecaps()) and true or false
end


--- Hand a death off to Blizzard's own recap UI.
---
--- `deathRecapID` is NeverSecret, so it is readable at the height of a pull —
--- which is the only reason this can be a click action at all rather than an
--- out-of-combat nicety.
---
--- The shim is preferred over the global: core/Compat.lua is where every
--- cross-patch API call is supposed to live (architecture-§1). It does not carry
--- one for the recap yet, so the guarded global is the fallback, and the moment
--- `Compat.OpenDeathRecap(recapID)` exists this call site picks it up with no
--- edit. Returning a boolean rather than erroring is what lets the caller
--- degrade to the ordinary spell breakdown.
---
--- @param recapID number
--- @return boolean  whether the recap was opened
local function openDeathRecap(recapID)
    if recapID == nil then return false end

    if Compat and Compat.OpenDeathRecap then
        return Compat.OpenDeathRecap(recapID) and true or false
    end

    local open = _G.OpenDeathRecapUI
    if type(open) ~= "function" then return false end
    open(recapID)
    return true
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

--- The drill-down a window is currently showing, or nil for the grid.
--- @param window table|number
--- @return table|nil
function DrillDown.GetState(window)
    local id = windowIdOf(window)
    if id == nil then return nil end
    return views[id]
end

--- Whether this window is in a drill-down right now.
---
--- ALWAYS a plain boolean, and the only supported way to ask the question. It is
--- derived from the presence of the view table — never from DrillDown.Title's
--- string, which may be secret and therefore un-testable (see the header).
---
--- @param window table|number
--- @return boolean
function DrillDown.IsActive(window)
    return DrillDown.GetState(window) ~= nil
end

--- Enter the breakdown for one player and one statistic.
---
--- The row's identity is captured as PLAIN fields — guid, name, classFilename —
--- and never as a reference to the aggregated row itself. The row table is
--- rebuilt from scratch on the next refresh, so holding it would pin a stale
--- object; and its VALUES are meter amounts, which this module has no business
--- keeping across time.
---
--- @param window table
--- @param row table    an aggregated row (needs .guid)
--- @param statKey string
--- @param kind string|nil  "spells" (default) or "deaths"
--- @return boolean  whether the view changed
function DrillDown:Enter(window, row, statKey, kind)
    local id = windowIdOf(window)
    if id == nil or type(row) ~= "table" or row.guid == nil then return false end
    if not Const.STAT_BY_KEY[statKey] then return false end

    views[id] = {
        guid          = row.guid,
        statKey       = statKey,
        kind          = kind or "spells",
        deaths        = (kind == "deaths") and copyRecapIDs(row.deaths) or nil,
        -- The offsets travel WITH the ids and are read by index beside them.
        -- Captured here rather than looked up later for the same reason the ids
        -- are: the aggregated row is rebuilt from scratch on the next pass.
        deathTimes    = (kind == "deaths") and copyOffsets(row.deathTimes, row.deaths) or nil,
        -- Which of the three timestamp styles this window is set to. Read at
        -- Enter so every row in one list is labelled the same way even if the
        -- setting changes while it is open.
        timeStyle     = timeStyleOf(window),
        name          = row.name,
        classFilename = row.classFilename,
        sessionType   = sessionTypeOf(window),
        sessionID     = sessionIDOf(window),
    }

    if State.debug and Debug then
        Debug("DrillDown", "enter window=%s stat=%s", tostring(id), statKey)
    end
    announce(id, true)
    return true
end

--- Leave the breakdown and restore the grid.
--- @param window table|number
--- @return boolean  whether anything changed
function DrillDown:Exit(window)
    local id = windowIdOf(window)
    if id == nil or views[id] == nil then return false end

    views[id] = nil
    local button = backButtons[id]
    if button then button:Hide() end

    if State.debug and Debug then
        Debug("DrillDown", "exit window=%s", tostring(id))
    end
    announce(id, false)
    return true
end

--- Leave every drill-down. Used on a profile swap and on a meter reset, where
--- the captured GUIDs describe data that no longer exists.
function DrillDown:ExitAll()
    local any = false
    for id in pairs(views) do
        views[id] = nil
        local button = backButtons[id]
        if button then button:Hide() end
        announce(id, false)
        any = true
    end
    return any
end

-- ---------------------------------------------------------------------------
-- Click routing
-- ---------------------------------------------------------------------------

--- What a click on a cell does. modules/Row.lua wires every cell's OnClick here
--- so the decision lives in one place rather than in the row builder.
---
--- Deaths is the special case, and deliberately so: a death has a recap the game
--- already renders far better than a spell list could, and it is the one cell
--- where the player's question is "what happened to me" rather than "what did I
--- do". When the recap API or the id is missing the click falls through to the
--- ordinary breakdown, so the cell is never dead.
---
--- @param window table
--- @param row table
--- @param statKey string
--- @return string  what happened: "recap", "enter", "exit" or "none"
function DrillDown:OnCellClick(window, row, statKey)
    if type(row) ~= "table" then return "none" end

    -- A second click inside a drill-down returns to the grid. Two ways out (this
    -- and the back button) rather than one, because a player who clicked in
    -- expects the same click to take them out.
    local current = DrillDown.GetState(window)
    if current and current.guid == row.guid and current.statKey == statKey then
        return self:Exit(window) and "exit" or "none"
    end

    -- DEATHS IS A LADDER, and the order is the whole of it.
    --
    -- The deaths view first, where the client can read a recap and the row knows
    -- which deaths to list. Blizzard's own frame second, so a client without
    -- C_DeathRecap keeps exactly the behaviour it has today rather than losing
    -- the one thing that worked. The ordinary spell breakdown last, so the cell
    -- is never dead — even though a Deaths source has no spell list and that
    -- breakdown is the "No data yet" this feature exists to replace.
    if statKey == "Deaths" then
        local deaths = canReadRecaps() and copyRecapIDs(row.deaths) or nil
        if deaths ~= nil then
            return self:Enter(window, row, statKey, "deaths") and "enter" or "none"
        end
        if openDeathRecap(row.deathRecapID) then
            if State.debug and Debug then
                Debug("DrillDown", "recap id=%s", tostring(row.deathRecapID))
            end
            return "recap"
        end
    end

    return self:Enter(window, row, statKey) and "enter" or "none"
end

--- What a click on a drill-down ROW does.
---
--- The cells give up the mouse inside a breakdown (modules/Row.lua's
--- ApplyMouse), so every click in here lands on the row — which is why this is
--- separate from OnCellClick rather than folded into it.
---
--- A DEATH ROW OPENS BLIZZARD'S OWN RECAP. Confirmed in-client: the frame
--- renders another player's death in full when it is handed a live id, which is
--- what makes the division of labour work — this list answers "when", and the
--- game's frame answers "what killed them" better than a second window of ours
--- would. It does NOT leave the list: the frame opens over the window, and
--- returning to a grid the player did not ask for would lose their place.
---
--- A spell row stays the no-op it has always been. A spell has no breakdown of
--- its own, and asking for one renders an empty window that reads as a broken
--- addon rather than as "there is nothing here".
---
--- @param window table
--- @param row table
--- @param button string
--- @return string  "recap", "exit" or "none"
function DrillDown:OnRowClick(window, row, button)
    if button == "RightButton" then
        return self:Exit(window) and "exit" or "none"
    end
    if type(row) ~= "table" or row.recapID == nil then return "none" end

    if openDeathRecap(row.recapID) then
        if State.debug and Debug then
            Debug("DrillDown", "recap window id=%s", tostring(row.recapID))
        end
        return "recap"
    end
    return "none"
end

-- ---------------------------------------------------------------------------
-- Rows
-- ---------------------------------------------------------------------------
--
-- THE ROW CONTRACT, stated here because modules/Window.lua consumes it and the
-- two files have to agree exactly. A drill-down row is an aggregated row whose
-- "player" is a spell:
--
--   guid           "spell:<spellID>" — a plain STRING, never secret, usable as
--                  a table key and as the row pool's identity. The pool keys on
--                  guid, and a spell has none, so it is synthesized.
--   name           the spell's name (or "#<id>" when the client cannot resolve
--                  it). A plain string.
--   icon           the spell's icon fileID, for the name cell.
--   classFilename  the DRILLED-INTO PLAYER's class, so class-colored bars stay
--                  the player's color through the whole trip.
--   isDrillDown    true. The one flag that tells the render path this row is a
--                  spell and its name cell has no class/spec icons to draw.
--   values         { [statKey] = { total = <opaque>, rate = <opaque> } } —
--                  the same shape the aggregator emits, so the cell render path
--                  needs no branch.
--   maxAmount      the source's own maxAmount, for bar scaling. Handed to
--                  SetMinMaxValues; never compared here.
--   overkillAmount / isAvoidable / isDeadly
--                  passed through for the tooltip. Possibly secret; nothing in
--                  this file looks at them.
--
-- A DEATH ROW IS THE SAME SHAPE WITH A DIFFERENT "PLAYER" — one of that
-- player's deaths rather than one of their spells:
--
--   guid           "death:<recapID>", synthesized for the pool exactly as a
--                  spell's is.
--   recapID        the plain id. modules/Tooltip.lua keys its death branch on
--                  the presence of this field, and reads the recap through it.
--   name           "Death N", numbered CHRONOLOGICALLY — Death 1 is the run's
--                  first death, so a newest-first list counts down. Numbering
--                  from the newest would make "his first death" mean the most
--                  recent one, which is the opposite of how anyone says it.
--   icon           the death icon. Every row here is a death, so it holds the
--                  column rather than telling one row from another.
--   values         { [statKey] = { total = 1, maxAmount = 1,
--                                  displayText = "13:01:06" } } — PLAIN ones,
--                  so the bar draws full without this file or modules/Row.lua
--                  comparing two values that are secret on every other row, and
--                  a caption where a number would be, because no formatter can
--                  turn a value into a wall clock.

--- One drill-down row from one DamageMeterCombatSpell.
local function spellRow(spell, view, maxAmount)
    local spellID = spell.spellID
    local spellName, iconID
    if spellID ~= nil and Compat and Compat.GetSpellInfo then
        spellName, iconID = Compat.GetSpellInfo(spellID)
    end

    -- The synthesized key must be a plain string. string.format is legal even if
    -- spellID were secret, and the explicit nil branch is there because
    -- string.format("%s", nil) raises in Lua 5.1.
    local key = (spellID ~= nil) and string.format("spell:%s", spellID) or "spell:?"

    local values = {}
    values[view.statKey] = { total = spell.totalAmount, rate = spell.amountPerSecond }

    return {
        guid           = key,
        spellID        = spellID,
        name           = spellName or key,
        icon           = iconID,
        classFilename  = view.classFilename,
        isLocalPlayer  = false,
        isDrillDown    = true,
        values         = values,
        maxAmount      = maxAmount,
        overkillAmount = spell.overkillAmount,
        isAvoidable    = spell.isAvoidable,
        isDeadly       = spell.isDeadly,
    }
end

--- How this death is labelled, in whichever style the window is set to.
---
--- THE MOMENT OF DEATH COMES FROM THE RECAP'S OWN NEWEST EVENT, and never from
--- `deathTimeSeconds`. The two are different clocks: an event timestamp is
--- absolute epoch, while `deathTimeSeconds` is seconds-into-session and reads -1
--- on the Overall session, where most of this list is looked at. Mixing them
--- produces a plausible time rather than a visible failure, which is the worse
--- kind of wrong — so the offset is passed alongside as the OFFSET and used only
--- by the style that wants one.
---
--- The events arrive newest first, so element one is the killing blow and its
--- timestamp is the moment of death.
---
--- @param recap table|nil  a Provider.GetRecap result
--- @param offset any       this death's `deathTimeSeconds`, or false
--- @param style string|nil the window's timestamp style
--- @return string|nil
local function deathClock(recap, offset, style)
    local events = recap and recap.events
    if type(events) ~= "table" then return nil end

    local Secrets = NS.Secrets
    if Secrets and Secrets.CanAccessTable and not Secrets.CanAccessTable(events) then
        return nil
    end

    local newest = events[1]
    if type(newest) ~= "table" then return nil end
    if Secrets and Secrets.CanAccessTable and not Secrets.CanAccessTable(newest) then
        return nil
    end

    local F = NS.Numbers or NS.Format
    if not (F and F.DeathTime) then return nil end
    return F.DeathTime(newest.timestamp, offset, style)
end

--- One drill-down row from one death.
---
--- @param recapID number  plain, already vetted by copyRecapIDs
--- @param ordinal number   1 for the run's FIRST death
--- @param view table
local function deathRow(recapID, ordinal, view, offset)
    -- `false` is a death the client gave no id for. It still draws — the count
    -- says it happened — but there is nothing to read and nothing to open, so it
    -- carries no recapID and takes its pool identity from its position instead.
    local openable = (recapID ~= false and recapID ~= nil)

    local P = provider()
    -- THE OFFSET FALLS BACK TO THE CURRENT SESSION. Every offset on a row read
    -- off OVERALL is -1 — the client reports no figure there — and Overall is
    -- what a window shows by default, so "time into the fight" dated every death
    -- with the wall clock and looked identical to "time of day". Current holds
    -- the real figure for the same deaths, joined on the same recap id.
    if openable and not usableOffset(offset) and P and P.DeathOffset then
        offset = P.DeathOffset(recapID)
    end

    local clock = (openable and P and P.GetRecap)
        and deathClock(P.GetRecap(recapID), offset, view.timeStyle) or nil

    local values = {}
    -- Plain ones on purpose: see the row contract above. The caption carries the
    -- information; the bar is the row's backing, not a measure of anything.
    values[view.statKey] = { total = 1, maxAmount = 1, displayText = clock or NO_CLOCK }

    return {
        guid          = openable and string.format("death:%d", recapID)
                                 or  string.format("death:none:%d", ordinal),
        recapID       = openable and recapID or nil,
        isDeath       = true,
        -- The caption again, on the ROW as well as in the cell. modules/Tooltip.lua
        -- puts it in the death tooltip's header, and reaching into `values` for
        -- it would make the tooltip depend on which column the drill-down was
        -- opened from.
        deathClock    = clock or NO_CLOCK,
        name          = string.format(L["Death %d"] or "Death %d", ordinal),
        icon          = DEATH_ICON,
        classFilename = view.classFilename,
        isLocalPlayer = false,
        isDrillDown   = true,
        values        = values,
        maxAmount     = 1,
    }
end

--- Every death in the view, newest first.
---
--- A DEATH WITH NO RECAP STILL GETS A ROW. The client drops a recap eventually,
--- and skipping that death would make this list shorter than the count in the
--- cell it was opened from — the two disagreeing about how many times somebody
--- died is worse than one row reading as a dash.
local function deathRows(view)
    local ids = view.deaths
    local rows = {}
    if type(ids) ~= "table" then return rows end

    local total = #ids
    for i = 1, total do
        rows[#rows + 1] = deathRow(ids[i], total - i + 1, view,
            view.deathTimes and view.deathTimes[i])
        if #rows >= MAX_SPELL_ROWS then break end
    end
    return rows
end

--- The rows a window should draw while it is in a drill-down.
---
--- Returns nil when the window is not drilled in, which is how
--- modules/Window.lua decides between this and the aggregator with a single
--- test rather than a mode flag it has to keep in step.
---
--- Bracketed as "aggregate" because that is exactly what it substitutes for: the
--- perf report should show the same bucket whether the window is drawing a grid
--- or a breakdown, or the two cannot be compared.
---
--- The third return is the PLAIN BOOLEAN a consumer branches on. The title is a
--- possibly-secret string (see the header) and must never be truth-tested, so
--- "am I drawing a breakdown" is answered by `active`, which is derived from the
--- presence of the view table and never from the string.
---
--- @param window table
--- @return table|nil rows, string|nil title, boolean active
function DrillDown:BuildRows(window)
    local view = DrillDown.GetState(window)
    if not view then return nil, nil, false end

    local t0 = Perf.on and debugprofilestop()

    -- THE DEATHS BRANCH SKIPS THE SOURCE LOOKUP ENTIRELY. A Deaths source has no
    -- spell list — that is the whole reason this view exists — so fetching one
    -- and ignoring it would be a client read per refresh pass for nothing.
    if view.kind == "deaths" then
        local deathList = deathRows(view)
        if t0 then Perf.Note("aggregate", debugprofilestop() - t0) end
        if State.debug and Debug then
            Debug("DrillDown", "rows window=%s stat=%s kind=deaths n=%d",
                tostring(windowIdOf(window)), view.statKey, #deathList)
        end
        return deathList, DrillDown.Title(window), true
    end

    local P = provider()
    -- A test row answers for itself; the provider has no such source. Same
    -- reason as modules/Tooltip.lua's copy of this branch.
    local A = NS.Aggregator
    local source = A and A.TestSourceDetail and A.TestSourceDetail(view.guid, view.statKey)
    if source == nil then
        source = P and P.GetSourceDetail
            and P:GetSourceDetail(view.sessionType, view.statKey, view.guid, nil, view.sessionID)
    end

    local rows = {}
    if type(source) == "table" then
        local Secrets = NS.Secrets
        local maxAmount = source.maxAmount
        if Secrets and Secrets.SafeIterate then
            Secrets.SafeIterate(source.combatSpells, function(_, spell)
                if type(spell) ~= "table" then return end
                if Secrets.CanAccessTable and not Secrets.CanAccessTable(spell) then return end
                rows[#rows + 1] = spellRow(spell, view, maxAmount)
                if #rows >= MAX_SPELL_ROWS then return false end
            end)
        end
    end

    if t0 then Perf.Note("aggregate", debugprofilestop() - t0) end
    if State.debug and Debug then
        Debug("DrillDown", "rows window=%s stat=%s n=%d",
            tostring(windowIdOf(window)), view.statKey, #rows)
    end

    return rows, DrillDown.Title(window), true
end

--- The header line for the current drill-down: who, and which statistic.
---
--- DISPLAY-ONLY, and the file header says why at length: `view.name` is
--- ConditionalSecret, and string.format over a secret returns a SECRET STRING.
--- The caller may hand the result to FontString:SetText and may do nothing else
--- with it — no truth test, no comparison, no `#`, no use as a table key. Ask
--- DrillDown.IsActive(window) instead; that is a plain boolean built from the
--- view table, not from this string.
---
--- The name is placed with string.format rather than concatenated behind a truth
--- test, and it is not compared to anything to decide whether to use it: the one
--- test it gets is `~= nil`, which is the single comparison a non-boolean secret
--- permits.
---
--- @param window table|number
--- @return string|nil  display text only — never compare or truth-test it
function DrillDown.Title(window)
    local view = DrillDown.GetState(window)
    if not view then return nil end

    local stat = Const.STAT_BY_KEY[view.statKey]
    local label = stat and L[stat.label] or view.statKey
    if view.name == nil then return label end
    return string.format("%s - %s", view.name, label)
end

-- ---------------------------------------------------------------------------
-- The back button
-- ---------------------------------------------------------------------------

--- The window's back button, created on first use and reused forever after.
---
--- Anchored with SetPoint and never measured. A drill-down window has cells
--- carrying secret values, which makes the frame's own geometry secret and
--- propagates it to anything anchored to it — so this button's position comes
--- from the caller's config-derived offsets, and nothing reads GetPoint,
--- GetWidth or GetLeft back off anything (rule R3).
---
--- No combat gate: this is an unprotected button on an unprotected frame, and
--- leaving a player stuck inside a breakdown until the pull ended would be a bug
--- invented purely out of caution.
---
--- @param window table
--- @param parent table  the frame to anchor into (the window's body)
--- @param offsetX number|nil
--- @param offsetY number|nil
--- @return table|nil  the button, or nil where CreateFrame is unavailable
function DrillDown:AcquireBackButton(window, parent, offsetX, offsetY)
    local id = windowIdOf(window)
    if id == nil or not parent or not _G.CreateFrame then return nil end

    local button = backButtons[id]
    if not button then
        button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        button:SetSize(BACK_BUTTON_WIDTH, BACK_BUTTON_HEIGHT)
        button:SetText(L["Back"])
        button:SetScript("OnClick", function()
            DrillDown:Exit(id)
        end)
        backButtons[id] = button
    end

    button:SetParent(parent)
    button:ClearAllPoints()
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", offsetX or 0, offsetY or 0)
    button:Show()
    return button
end

--- Hide the window's back button without destroying it.
--- @param window table|number
function DrillDown:ReleaseBackButton(window)
    local id = windowIdOf(window)
    local button = id ~= nil and backButtons[id]
    if button then button:Hide() end
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------
--
-- Bus messages only — core/MythicMeters.lua is the addon's single game-event
-- listener. METER_RESET and PROFILE_CHANGED both invalidate every captured
-- GUID; WINDOWS_CHANGED can delete the window a view belongs to.

function DrillDown:OnEnable()
    local MSG = Const.MSG
    self:RegisterMessage(MSG.METER_RESET,     "OnMeterReset")
    self:RegisterMessage(MSG.PROFILE_CHANGED, "OnMeterReset")
    self:RegisterMessage(MSG.WINDOWS_CHANGED, "OnWindowsChanged")
end

function DrillDown:OnMeterReset()
    self:ExitAll()
end

--- A window that no longer exists cannot be drilled into. The registry is
--- WindowManager's, so this asks it rather than assuming the payload is complete
--- — an action of "deleted" carries the id, but a bulk reset may not.
function DrillDown:OnWindowsChanged(_, payload)
    local id = type(payload) == "table" and payload.windowId or nil
    if id ~= nil and views[id] ~= nil then
        self:Exit(id)
        return
    end

    local Database = NS.Database
    if not (Database and Database.FindWindow) then return end
    for viewId in pairs(views) do
        if not Database.FindWindow(viewId) then self:Exit(viewId) end
    end
end
