-- modules/Aggregator.lua
--
-- The join. Columns in, ordered rows out — and the file where design rule R2
-- ("row order is never computed from values while comparison is illegal") is
-- actually enforced rather than merely stated.
--
-- ---------------------------------------------------------------------------
-- THE ALGORITHM, IN THE ORDER THE CODE RUNS IT
-- ---------------------------------------------------------------------------
--
--   1. Read one column per enabled stat from modules/Provider.lua.
--   2. Index every source by sourceGUID. A GUID is never secret, so it is legal
--      as a table KEY — and it is the ONLY thing in a session that is. Nothing
--      here is ever keyed on a value; that is an immediate Lua error in combat
--      and it is the single most tempting mistake in the whole addon.
--   3. Filter to group members (modules/Roster.lua) and fold pets into owners.
--   4. Order, per the window's sortMode.
--   5. Cap to rows.maxRows, honoring rows.alwaysShowSelf.
--
-- ---------------------------------------------------------------------------
-- PET FOLDING IS ADDITION, AND ADDITION IS THE THING WE MAY NOT DO
-- ---------------------------------------------------------------------------
--
-- Adding a pet's damage to its owner's is arithmetic on two meter values. Out of
-- combat that is ordinary Lua. While the Combat restriction is active it raises,
-- and there is no native escape hatch for it the way there is for formatting —
-- NumericRuleFormatter renders, it does not sum.
--
-- So the behavior is honestly different in the two states, and it is logged once
-- per pass rather than hidden:
--   * unrestricted — the pet's value is summed into the owner's row.
--   * restricted   — the pet's row is DROPPED. The owner's number is low by
--                    whatever the pet contributed, which is a visible,
--                    explainable inaccuracy; the alternatives are a phantom pet
--                    row or a Lua error mid-pull.
-- Deferring the scoring feature rests on exactly this fact (design §7).
--
-- ---------------------------------------------------------------------------
-- THE SORT FREEZE
-- ---------------------------------------------------------------------------
--
-- `value` mode sorts by the sort column's numbers, which requires comparing
-- them, which is illegal while restricted. Falling back to `provider` order the
-- moment a pull starts would make every row jump at the worst possible time, so
-- instead:
--
--   * every successful value-sort CACHES its resulting GUID order per window;
--   * while restricted, that frozen order is reused — rows update their numbers
--     IN PLACE and nothing reshuffles;
--   * ADDON_RESTRICTION_STATE_CHANGED with state = Activating fires BEFORE
--     enforcement begins and access is still permitted during that dispatch, so
--     the handler at the bottom of this file takes one final sort there. That is
--     the last legal moment, and taking it is what makes the frozen order the
--     order as of the pull's start rather than as of whenever the player last
--     stood still.
--
-- A GUID with no frozen position (someone who joined mid-pull) sorts after the
-- frozen ones, in provider order. It never reorders the frozen block.
--
-- ---------------------------------------------------------------------------
-- WHAT BUILD RETURNS
-- ---------------------------------------------------------------------------
--
--   {
--     rows            = { row, ... },          -- ordered, capped
--     columns         = { [statKey] = column },-- the provider's column tables
--     columnTotals    = { [statKey] = opaque },-- the column's group total
--     sortColumn      = string|nil,            -- which column the order came from
--     sortTotal       = opaque,                -- columnTotals[sortColumn]
--     durationSeconds = opaque,                -- for the header
--     sessionName     = string|nil,
--     sortFrozen      = boolean,               -- the header says so when true
--     reason          = string|nil,            -- why a column came back empty
--   }
--
-- `columnTotals` exists so the render layer never has to issue a SECOND
-- Provider.GetColumn just to learn what a column's percentages are out of. The
-- build already holds every column table it read, and a per-column total is one
-- table read away from them; asking the provider again would double the number
-- of C_DamageMeter session reads on the refresh path for a number this file
-- already has. It is the same opaque handle the provider returned — a consumer
-- may hand it to NS.Format or to a widget setter and may do nothing else with
-- it (rule R1), which is exactly why the DIVIDED form (`cell.percent`) is
-- computed here, where core/Secrets.lua can gate the division, rather than
-- there.
--
-- and the result table IS ALSO THE ROW ARRAY: `result[1]` is `result.rows[1]`,
-- so `ipairs(Aggregator.Build(w))` and `Build(w).rows` are the same rows. That
-- is not decoration — the build brief specifies an ordered array and
-- modules/Window.lua was written against the result table, and satisfying both
-- with one object is cheaper and safer than a second shape that can drift.
--
-- A row is:
--
--   { guid, windowId, name, classFilename, specIconID, role,
--     isPlayer, isLocalPlayer,          -- the same fact under both names
--     providerIndex, sortValue, deathRecapID,
--     values = { [statKey] = { total, rate, maxAmount, columnTotal, percent,
--                              deathRecapID, deathTime } } }
--
-- `cells` is published as an ALIAS of `values` (one table, two names) for the
-- same reason: the design brief calls the map `cells`, modules/Row.lua reads
-- `values`, and an alias costs one assignment while a copy costs a divergence.
--
-- `total`, `rate` and the column's `maxAmount` are OPAQUE HANDLES. A consumer
-- may pass them to StatusBar:SetValue / SetMinMaxValues, to FontString:SetText
-- and to NS.Format, and may do nothing else with them (rule R1). `percent` is
-- the exception and is a PLAIN number or nil: computing it is a division, so it
-- exists only when the operands were accessible, which is only out of combat.

local addonName, NS = ...

local Aggregator = NS:NewModule("Aggregator", "AceEvent-3.0")
NS.Aggregator = Aggregator

local Provider = NS.Provider
local Roster   = NS.Roster
local Secrets  = NS.Secrets
local State    = NS.State
local Const    = NS.Constants
local MSG      = Const.MSG

-- Perf bracket upvalue, resolved ONCE at load — never an NS lookup on the build
-- path (performance-§2). PerfSetup is in the core block, so this is always the
-- real instance or its stub.
local Perf = NS.Perf

-- Frozen sort orders, per window id. Lives in the shared session cache so it is
-- dropped by the same seam that drops the roster map and the formatters: a meter
-- reset or a profile swap makes a frozen order meaningless, and the alternative
-- is a window that keeps last fight's ordering after the meter has been wiped.
local frozen = State.Cache("Aggregator")

-- ---------------------------------------------------------------------------
-- Row assembly
-- ---------------------------------------------------------------------------

--- The window's enabled columns as an array of stat keys, in display order.
---
--- A stored column whose stat is not in the catalog is skipped rather than
--- rendered blank — that is a window configured against a build which offered
--- more stats than this one (core/Constants.lua says the same).
local function columnKeys(window)
    local keys = {}
    local columns = window and window.columns
    if type(columns) ~= "table" then return keys end
    for _, column in ipairs(columns) do
        local key = column and column.stat
        if key and Const.STAT_BY_KEY[key] then keys[#keys + 1] = key end
    end
    return keys
end

--- Start a row for `guid` from whichever column first mentioned it.
---
--- Identity comes from the ROSTER where the roster has it, and from the meter's
--- source row only as a fallback. That ordering is deliberate: the meter's
--- `name` field is ConditionalSecret and may be opaque mid-pull, while
--- UnitName's answer is always plain text. `classFilename` and `specIconID` are
--- NeverSecret on the source row, so those come from the meter, which knows the
--- source's spec and the unit API does not always.
local function newRow(guid, src, windowId)
    local member = Roster.Get(guid)
    local isPlayer = (member and member.isPlayer) or false
    local values = {}
    return {
        guid          = guid,
        windowId      = windowId,
        name          = (member and member.name) or (src and src.name),
        classFilename = (src and src.classFilename) or (member and member.classFilename),
        specIconID    = src and src.specIconID,
        role          = (member and member.role) or "NONE",
        isPlayer      = isPlayer,
        -- The same fact under the name modules/Row.lua reads. One boolean, two
        -- keys, assigned together so they cannot disagree.
        isLocalPlayer = isPlayer,
        values        = values,
        cells         = values,   -- alias, not a copy — see the header
    }
end

--- Write one source's numbers into a row's cell for `statKey`.
---
--- Pure copying. Not one of these fields is examined, compared or coerced on the
--- way through — they land in table VALUES, which is explicitly permitted, and
--- travel on as opaque handles.
local function setCell(row, statKey, src, maxAmount, isCount)
    -- A COUNTED STAT TALLIES ROWS. Deaths reports one source row per death, with
    -- totalAmount 0 on every one, so the figure is how many rows this GUID has —
    -- see the catalog note in core/Constants.lua. The counter is ours, so
    -- incrementing it is not arithmetic on a meter value and stays legal mid-pull.
    if isCount then
        local cell = row.values[statKey]
        if cell == nil then
            cell = { total = 0, maxAmount = maxAmount }
            row.values[statKey] = cell
        end
        cell.total = cell.total + 1
        -- The FIRST row wins the recap: the API returns deaths newest-first, and
        -- the death a player wants to look at is the one that just happened.
        if cell.deathRecapID == nil then
            cell.deathRecapID = src.deathRecapID
            cell.deathTime    = src.deathTimeSeconds
            if src.deathRecapID ~= nil then row.deathRecapID = src.deathRecapID end
        end
        return
    end

    row.values[statKey] = {
        total        = src.totalAmount,
        rate         = src.amountPerSecond,
        maxAmount    = maxAmount,
        deathRecapID = src.deathRecapID,
        deathTime    = src.deathTimeSeconds,
    }

    -- deathRecapID is NeverSecret, and both the tooltip and the drill-down read
    -- it off the ROW rather than off a cell (it identifies the player's death,
    -- not a column's number). Promoted here so neither has to know which column
    -- it arrived on.
    if src.deathRecapID ~= nil then row.deathRecapID = src.deathRecapID end
end

--- Fold a pet's numbers into its owner's existing cell.
---
--- Returns true when the sum happened, false when it was refused. The caller
--- counts the refusals and reports them once per pass; it does not retry and it
--- does not approximate.
---
--- CanCompare2 is the gate rather than IsRestricted because it asks the question
--- that actually decides — "may this execution context access both of these" —
--- and it is right on a client with no restriction system at all, where the
--- honest answer is yes.
local function foldPet(row, statKey, src)
    local cell = row.values[statKey]
    if cell == nil then
        -- The owner has no cell in this column yet (a pet that did damage its
        -- owner did not). Adopting the pet's numbers wholesale is not a sum, so
        -- it is legal in either state — and it is the correct answer: the owner
        -- DID that damage, through the pet.
        setCell(row, statKey, src, nil)
        return true
    end

    if not Secrets.CanCompare2(cell.total, src.totalAmount) then return false end
    if type(cell.total) ~= "number" or type(src.totalAmount) ~= "number" then return false end

    cell.total = cell.total + src.totalAmount
    if type(cell.rate) == "number" and type(src.amountPerSecond) == "number" then
        cell.rate = cell.rate + src.amountPerSecond
    end
    return true
end

--- `value` as a percentage of `total`, as a PLAIN NUMBER, or nil.
---
--- The only arithmetic this file performs on meter data other than the pet fold,
--- and it is gated the same way: a division on an inaccessible operand raises,
--- so an inaccessible operand yields nil and the cell's percent slot renders
--- empty. nil means "cannot be known right now", never "zero percent" — and the
--- text slots default to total/rate precisely because percent is the slot that
--- goes quiet in combat.
---
--- Returns a number rather than text because modules/Row.lua hands the result to
--- NS.Format.Percent for rendering; formatting here would format twice.
local function percentOf(value, total)
    if value == nil or total == nil then return nil end
    if not Secrets.CanCompare2(value, total) then return nil end
    if type(value) ~= "number" or type(total) ~= "number" then return nil end
    if total == 0 then return nil end
    return value / total * 100
end

-- Base position for a row that never appeared in the sort column, and for a row
-- with no frozen place. Large enough that it can never collide with a real
-- index — a session cannot hold more sources than the iteration limit
-- core/Secrets.lua enforces — and finite so the sort stays deterministic rather
-- than falling back on table order.
local UNRANKED = 100000

-- ---------------------------------------------------------------------------
-- Ordering
-- ---------------------------------------------------------------------------

--- Order by the position modules/Provider.lua returned for the sort column.
---
--- Needs no comparison of any meter value — `providerIndex` is a plain integer
--- this file assigned during the scan — so it is legal at any point in a pull.
--- It is also the fallback every other mode degrades TO, which is why it is the
--- simplest thing here.
local function orderByProvider(rows)
    table.sort(rows, function(a, b) return a.providerIndex < b.providerIndex end)
end

--- Order by the sort column's values — or refuse.
---
--- Comparability is checked in a SEPARATE PASS BEFORE table.sort runs, not
--- inside the comparator. That is the whole trick of this function: a comparator
--- that discovers an illegal comparison halfway through has already raised, and
--- there is no way to unwind a partially sorted array. One linear pass that
--- touches nothing but CanCompare turns a possible mid-sort error into a clean
--- "no".
---
--- `ascending` flips the direction and nothing else. A MISSING cell sorts last
--- in BOTH directions rather than flipping with them: "this player has no
--- dispels" is an absence, not a low score, and floating those rows to the top of
--- an ascending sort would bury everyone who actually did something.
---
--- @param ascending boolean|nil
--- @return boolean  whether the sort was taken
local function orderByValue(rows, statKey, ascending)
    for i = 1, #rows do
        local cell = rows[i].values[statKey]
        local v = cell and cell.total
        if v ~= nil and not Secrets.CanCompare(v) then return false end
    end

    table.sort(rows, function(a, b)
        local ac, bc = a.values[statKey], b.values[statKey]
        local av = ac and ac.total
        local bv = bc and bc.total
        -- A missing cell sorts last, and two missing cells fall back to provider
        -- order so the sort stays deterministic (table.sort is not stable).
        if av == nil and bv == nil then return a.providerIndex < b.providerIndex end
        if av == nil then return false end
        if bv == nil then return true end
        if av == bv then return a.providerIndex < b.providerIndex end
        if ascending then return av < bv end
        return av > bv
    end)
    return true
end

--- Order by the frozen GUID list captured at the last legal sort.
---
--- Rows absent from the freeze keep their provider position and are pushed after
--- every frozen row, so somebody who joined mid-pull appears at the bottom and
--- disturbs nothing above them.
---
--- @return boolean  whether a freeze existed to apply
local function orderByFreeze(rows, windowId)
    local order = frozen[windowId]
    if type(order) ~= "table" then return false end

    for i = 1, #rows do
        local row = rows[i]
        row.freezeIndex = order[row.guid] or (UNRANKED + row.providerIndex)
    end
    table.sort(rows, function(a, b) return a.freezeIndex < b.freezeIndex end)
    return true
end

--- Order by group position, then role, then name — the mode that never moves.
---
--- Roles sort tank, healer, damager rather than alphabetically, because that is
--- how a raid frame reads and the point of this mode is predictability.
local ROLE_RANK = { TANK = 1, HEALER = 2, DAMAGER = 3, NONE = 4 }

local function orderByRoster(rows)
    local position = {}
    for index, member in ipairs(Roster.GetGroup()) do position[member.guid] = index end

    table.sort(rows, function(a, b)
        local ap = position[a.guid] or (UNRANKED + a.providerIndex)
        local bp = position[b.guid] or (UNRANKED + b.providerIndex)
        if ap ~= bp then return ap < bp end
        local ar = ROLE_RANK[a.role] or 4
        local br = ROLE_RANK[b.role] or 4
        if ar ~= br then return ar < br end
        -- The name tiebreak is reached ONLY by rows absent from the roster --
        -- pets, enemies, cross-realm strays -- and that is exactly the
        -- population whose `name` came from the meter's ConditionalSecret
        -- src.name rather than from a unit token. `<` on two of those raises
        -- mid-combat, and `tostring()` does not launder a secret: it survives
        -- it. So compare names only when the values are comparable, and
        -- otherwise fall back to providerIndex, the deterministic escape
        -- orderByValue already uses.
        if not Secrets.CanCompare2(a.name, b.name) then
            return a.providerIndex < b.providerIndex
        end
        return tostring(a.name) < tostring(b.name)
    end)
end

--- Record the current order as this window's freeze.
---
--- Stored as guid -> position rather than as an array because the only question
--- ever asked of it is "where does this GUID go", and an array would make that a
--- linear scan per row per refresh.
local function freeze(rows, windowId)
    if windowId == nil then return end
    local order = {}
    for i = 1, #rows do order[rows[i].guid] = i end
    frozen[windowId] = order
end

-- ---------------------------------------------------------------------------
-- Build, one stage at a time
-- ---------------------------------------------------------------------------
--
-- Build is the join, and the join is five stages: decide what to read, read and
-- index it, order it, cap it, derive the per-row numbers. Each stage below is
-- one of those, and they share ONE mutable pass table rather than a chain of
-- tuple returns — the counters the debug line reports (dropped, unfolded,
-- reason, applied) are gathered by different stages, and threading them through
-- return values would mean every stage carrying numbers it has no opinion about.
--
-- The pass table is allocated once per Build, which is the same allocation the
-- old body made for its locals' worth of tables.

--- Everything the pass needs to know before it reads a single column.
---
--- A stored sortColumn whose stat is not in the catalog falls back to the first
--- enabled column, for the same reason columnKeys skips it: the window was
--- configured against a build that offered more stats than this one.
local function newPass(window)
    local data = window.data or {}
    local keys = columnKeys(window)

    local sortColumn = data.sortColumn
    if not (sortColumn and Const.STAT_BY_KEY[sortColumn]) then sortColumn = keys[1] end

    return {
        windowId    = window.id,
        sessionType = data.sessionType or Const.SESSION_TYPE.Current,
        -- The segment the header dropdown is pointed at, or nil for "whichever
        -- session sessionType names". Read straight off the config rather than
        -- off the window instance because modules/Window.lua CLEARS a stale id
        -- back to nil before it aggregates, so the config is the resolved answer
        -- by the time this runs — one source of truth rather than two.
        sessionID   = data.sessionID,
        keys        = keys,
        sortColumn  = sortColumn,
        mode        = data.sortMode or "value",
        -- Direction is a per-window setting the column headers toggle. Descending
        -- is the default because a meter is read top-down for "who did the most".
        sortAscending = data.sortAscending and true or false,
        -- Off by default: see rowForSource. Merging is arithmetic, and arithmetic
        -- on a secret raises, so the merged mode is exact out of combat and lossy
        -- inside it.
        mergePets   = data.mergePets and true or false,
        applied     = nil,

        byGuid  = {},
        rows    = {},
        columns = {},
        -- statKey -> the column's group total, lifted out of the column table it
        -- was already read from. Published so nothing downstream re-reads the
        -- session for a number this pass already has (see the header).
        columnTotals = {},

        dropped  = 0,
        unfolded = 0,
        reason   = nil,
    }
end

--- The group member a source's numbers belong to, or nil to drop the source.
---
--- A group member owns their own numbers; anyone else is a pet and belongs to
--- whoever the roster says summoned them. Best effort, and nil is a real answer:
--- an unattributable pet is dropped rather than shown as a phantom row
--- (design §5).
local function owningMember(guid)
    if Roster.IsGroupMember(guid) then return guid end
    local owner = Roster.OwnerOf(guid)
    if owner and Roster.IsGroupMember(owner) then return owner end
    return nil
end

--- The row `src` should be written into, started on first sight of its owner.
---
--- @return table|nil row  nil when the source was dropped (and counted)
--- @return boolean isOwn  true when the source IS the member, false for a pet
local function rowForSource(pass, src, index, isSortColumn)
    local guid = src.guid
    local ownerGuid = owningMember(guid)
    if ownerGuid == nil then
        pass.dropped = pass.dropped + 1
        return nil, false
    end

    local isOwn = (ownerGuid == guid)

    -- A PET GETS ITS OWN ROW unless the window asked for it to be merged.
    --
    -- Merging is ADDITION, and addition on two secrets raises — so the merged
    -- mode has never been able to do it mid-pull and drops the pet's numbers
    -- instead, leaving the owner's total quietly low for the whole fight. A
    -- separate row has no arithmetic in it at all: it is exact, in and out of
    -- combat, and it is what Blizzard's own meter shows. That is why it is the
    -- default and merging is the option rather than the other way round.
    --
    -- The row is keyed on the PET's guid and carries its own name and class off
    -- the source, so it reads as the pet it is rather than as a second copy of
    -- its owner. `ownerGuid` is kept on it for the tooltip and for anything that
    -- later wants to group them.
    local petOwner
    if not isOwn and not pass.mergePets then
        petOwner  = ownerGuid
        ownerGuid = guid
        isOwn     = true
    end

    local row = pass.byGuid[ownerGuid]
    if row == nil then
        row = newRow(ownerGuid, isOwn and src or nil, pass.windowId)
        if petOwner then
            row.isPet     = true
            row.ownerGuid = petOwner
        end
        -- Provider position comes from the SORT column, because that is what
        -- `provider` mode means: "the order Blizzard returned for the column
        -- this window is ordered by", not "the order of whichever column
        -- happened to mention this player first". A player who appears in some
        -- other column but not in the sort one (a death, with no damage) is
        -- parked past every ranked row, in first-seen order, rather than
        -- interleaved.
        row.providerIndex = isSortColumn and index or (UNRANKED + index)
        pass.byGuid[ownerGuid] = row
        pass.rows[#pass.rows + 1] = row
    end

    -- ONLY the member's own source sets the position. A pet's index is a
    -- position in the source list, not in the row list, and letting it through
    -- moved its owner to wherever the pet happened to sit.
    if isSortColumn and isOwn then row.providerIndex = index end

    return row, isOwn
end

--- Read one column from the provider and index every source in it by GUID.
---
--- The pet fold lives here, and so does its refusal: foldPet holds the
--- CanCompare2 gate and answers false while restricted, at which point the pet's
--- contribution is simply not counted (see the header's note on why dropping
--- beats a phantom row or a mid-pull error). The refusals are tallied on the
--- pass and reported once, not per source.
local function scanColumn(pass, statKey)
    local column = Provider.GetColumn(pass.sessionType, statKey, pass.sessionID)
    pass.columns[statKey] = column
    pass.columnTotals[statKey] = column.totalAmount
    if column.reason and pass.reason == nil then pass.reason = column.reason end

    local stat = Const.STAT_BY_KEY[statKey]
    local isCount = stat and stat.isCount or false

    -- A COUNTED COLUMN HAS NO USABLE MAX FROM THE SESSION. Deaths reports
    -- maxAmount 0 along with its zero totals, and a bar scaled to 0 draws full
    -- for everybody. The max is computed below, after the tally, out of counters
    -- this file produced — plain integers, so comparing them is legal mid-pull
    -- where comparing two meter values would not be.
    local maxAmount = not isCount and column.maxAmount or nil
    local isSortColumn = (statKey == pass.sortColumn)
    local touched = isCount and {} or nil

    for index, src in ipairs(column.sources) do
        local row, isOwn = rowForSource(pass, src, index, isSortColumn)
        if row then
            if isOwn then
                setCell(row, statKey, src, maxAmount, isCount)
                if touched then touched[row] = true end
            elseif isCount then
                -- A pet cannot die, and nothing else counts events. Reaching here
                -- would mean a counted stat grew a pet-shaped source; tally it on
                -- the pet's own row rather than inventing a fold for it.
                setCell(row, statKey, src, maxAmount, true)
                touched[row] = true
            elseif not foldPet(row, statKey, src) then
                pass.unfolded = pass.unfolded + 1
            end

            -- The column max belongs on every cell in the column, including ones
            -- a pet fold created without it.
            local cell = row.values[statKey]
            if cell and cell.maxAmount == nil and not isCount then
                cell.maxAmount = maxAmount
            end
        end
    end

    if touched then
        local highest = 0
        for row in pairs(touched) do
            local cell = row.values[statKey]
            if cell and cell.total > highest then highest = cell.total end
        end
        if highest < 1 then highest = 1 end
        for row in pairs(touched) do
            row.values[statKey].maxAmount = highest
        end
        pass.columnTotals[statKey] = nil
    end
end

--- Put the pass's rows in the window's order, and say which order that was.
---
--- Written as a ladder because the fallbacks are the interesting part: every
--- mode ends at `provider`, which cannot fail. The name returned is the mode
--- that ACTUALLY took effect, which is what the header reports and what the
--- debug line records — `value` degrading to `frozen` is the thing a bug report
--- most needs to show.
---
--- @return string  the mode applied: the window's own, or "frozen"/"provider"
local function applySortMode(pass)
    local rows, mode = pass.rows, pass.mode

    if mode == "roster" then
        orderByRoster(rows)
        return mode
    end

    if mode ~= "value" then
        orderByProvider(rows)
        return "provider"
    end

    if orderByValue(rows, pass.sortColumn, pass.sortAscending) then
        freeze(rows, pass.windowId)
        return mode
    end
    if orderByFreeze(rows, pass.windowId) then return "frozen" end

    orderByProvider(rows)
    return "provider"
end

--- Fill in `sortValue` and each cell's `columnTotal` / `percent`.
---
--- Taken in ONE pass over the rows that survived the cap rather than over every
--- source: `sortValue` scales the name column's bar, and `percent` is the only
--- number in the whole addon this file computes rather than copies. Both are
--- done after the cap because doing them earlier would divide for rows nobody
--- will see.
local function deriveRowFacts(kept, pass)
    local columnTotals = pass.columnTotals

    for i = 1, #kept do
        local row = kept[i]
        local cell = row.values[pass.sortColumn]
        row.sortValue = cell and cell.total

        for _, statKey in ipairs(pass.keys) do
            local c = row.values[statKey]
            if c then
                -- The column's total on the CELL as well as on the result, so a
                -- renderer holding one cell can show "x of y" without carrying
                -- the result table down with it. Opaque, exactly as it arrived.
                c.columnTotal = columnTotals[statKey]
                -- A division, and therefore legal only on accessible operands.
                -- percentOf holds that gate and answers nil rather than
                -- approximating, which is most of a pull — the percent text
                -- slots go quiet in combat by design (modules/Format.lua).
                c.percent = percentOf(c.total, c.columnTotal)
            end
        end
    end
end

--- ONE line per pass, arguments only — the format string is never built at the
--- call site and nothing here concatenates (debug-logging-§3).
local function logPass(pass, keptCount)
    if not State.debug then return end
    NS.Debug("Aggregator", "window=%s cols=%d rows=%d dropped=%d unfolded=%d sort=%s/%s reason=%s",
        tostring(pass.windowId), #pass.keys, keptCount, pass.dropped, pass.unfolded,
        pass.mode, pass.applied, pass.reason or "ok")
end

--- Hang the named result fields on the row array itself.
---
--- The result table IS the row array (see the header), so `result.rows` and
--- `ipairs(result)` walk one object. `sortTotal` rides along because the
--- header's "group total" is the sort column's, and the window would otherwise
--- have to know which column that was.
local function assembleResult(kept, pass)
    kept.rows            = kept
    kept.columns         = pass.columns
    kept.columnTotals    = pass.columnTotals
    kept.sortColumn      = pass.sortColumn
    kept.sortTotal       = pass.columnTotals[pass.sortColumn]
    kept.sortFrozen      = (pass.applied == "frozen")
    kept.reason          = pass.reason
    kept.durationSeconds = Provider.GetSessionDuration(pass.sessionType, pass.sessionID)
    return kept
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

--- Every row for one window, ordered and capped, plus the columns they came
--- from and the header's facts.
---
--- Callable as `Aggregator.Build(window)` or `Aggregator:Build(window)` —
--- modules/Window.lua uses the colon form, and a silent argument shift there
--- would build the wrong window rather than error.
---
--- @param window table  a window config from the profile
--- @return table  the result table, which is also the row array (see the header)
function Aggregator.Build(a, b)
    local window = (a == Aggregator) and b or a
    if type(window) ~= "table" then return { rows = {}, columns = {} } end

    local t0 = Perf.on and debugprofilestop()

    local pass = newPass(window)
    for _, statKey in ipairs(pass.keys) do scanColumn(pass, statKey) end
    pass.applied = applySortMode(pass)

    local kept = Aggregator.ApplyRowLimit(pass.rows, window.rows or {})
    deriveRowFacts(kept, pass)

    if t0 then Perf.Note("aggregate", debugprofilestop() - t0) end

    logPass(pass, #kept)
    return assembleResult(kept, pass)
end

--- Apply rows.maxRows and rows.alwaysShowSelf.
---
--- Split out of Build because it is the one piece of this file a settings change
--- can exercise on its own, and because the self-pinning rule reads as a rule
--- rather than as three lines at the bottom of a long function.
---
--- @param rows table  ordered rows, modified in place
--- @param rowsConfig table  the window's `rows` config group
--- @return table  the same array, truncated
function Aggregator.ApplyRowLimit(rows, rowsConfig)
    local cap = tonumber(rowsConfig and rowsConfig.maxRows) or 0
    -- 0 means "as many as fit", which the WINDOW decides from its own height;
    -- the aggregator only enforces the hard ceiling that stops a corrupted
    -- config asking the row pool for thousands of frames.
    if cap <= 0 or cap > Const.MAX_ROWS then cap = Const.MAX_ROWS end
    if #rows <= cap then return rows end

    -- Find the player BEFORE truncating, so the pin below knows whether they
    -- were about to fall off.
    local selfRow = nil
    for i = cap + 1, #rows do
        if rows[i].isPlayer then selfRow = rows[i] break end
    end

    for i = #rows, cap + 1, -1 do rows[i] = nil end

    -- The most-requested behavior of every meter ever written: never lose
    -- yourself off the bottom of the list. The last visible slot is spent on the
    -- player, keeping the row count exactly at the cap.
    if selfRow and rowsConfig and rowsConfig.alwaysShowSelf and cap > 0 then
        rows[cap] = selfRow
    end

    return rows
end

-- ---------------------------------------------------------------------------
-- Test rows
-- ---------------------------------------------------------------------------
--
-- Placeholder data, required of any addon with a positionable display: a player
-- who unlocks a window at a target dummy must see a full grid to lay their
-- columns out against, and `/mm test` gives the same thing on demand.
--
-- The numbers are DETERMINISTIC — derived from the row's index and the column's
-- position, never randomized. Test data that jitters every refresh is unusable
-- for the exact job it exists to do, which is judging column widths.

-- `spec` is a real specialization icon file id, so the spec-icon slot has
-- something to draw. Test mode is used to judge how a row LOOKS, and a row
-- missing one of its three icons is not the row the player is laying out.
local PREVIEW_MEMBERS = {
    { name = "Ka0stank",   class = "WARRIOR",     role = "TANK",    spec = 132342 },
    { name = "Ka0sheals",  class = "PRIEST",      role = "HEALER",  spec = 135940 },
    { name = "Ka0smage",   class = "MAGE",        role = "DAMAGER", spec = 135846 },
    { name = "Ka0srogue",  class = "ROGUE",       role = "DAMAGER", spec = 132320 },
    { name = "Ka0shunter", class = "HUNTER",      role = "DAMAGER", spec = 461112 },
    { name = "Ka0slock",   class = "WARLOCK",     role = "DAMAGER", spec = 136186 },
    { name = "Ka0smonk",   class = "MONK",        role = "DAMAGER", spec = 608951 },
    { name = "Ka0sdruid",  class = "DRUID",       role = "DAMAGER", spec = 625336 },
    { name = "Ka0spal",    class = "PALADIN",     role = "DAMAGER", spec = 135873 },
    { name = "Ka0sdk",     class = "DEATHKNIGHT", role = "DAMAGER", spec = 135771 },
}

-- HOW MUCH OF EACH STAT A ROLE ACTUALLY PRODUCES.
--
-- The first version gave every row the same smooth falloff in every column, so
-- the tank out-healed the healer and the healer out-damaged the rogue. That is
-- fine for judging a column WIDTH and useless for judging anything else — colors,
-- sort order, which columns are worth showing — because it does not look like a
-- fight. These multipliers make it look like one: a tank does little damage and
-- takes most of it, a healer heals and does neither.
local ROLE_SHAPE = {
    TANK    = { DamageDone = 0.45, HealingDone = 0.10, Absorbs = 0.30,
                DamageTaken = 1.00, AvoidableDamageTaken = 0.85,
                Interrupts = 1.00, Dispels = 0.30, Deaths = 0.35 },
    HEALER  = { DamageDone = 0.15, HealingDone = 1.00, Absorbs = 1.00,
                DamageTaken = 0.30, AvoidableDamageTaken = 0.55,
                Interrupts = 0.35, Dispels = 1.00, Deaths = 0.60 },
    DAMAGER = { DamageDone = 1.00, HealingDone = 0.12, Absorbs = 0.10,
                DamageTaken = 0.45, AvoidableDamageTaken = 1.00,
                Interrupts = 0.70, Dispels = 0.45, Deaths = 1.00 },
}

-- Spell names for the test breakdown, so hovering a test row shows a tooltip
-- rather than "No data yet".
--
-- The tooltip and the drill-down both go to modules/Provider.lua for a spell
-- list, and the provider has nothing to say about a `Test-N` guid — correctly,
-- because there is no such source. So test mode publishes its own, in the shape
-- the provider would have returned, and Aggregator.TestSourceDetail is what the
-- two consumers ask FIRST.
local PREVIEW_SPELLS = {
    { id = 116858, name = "Chaos Bolt",   icon = 236291 },
    { id = 348,    name = "Immolation",   icon = 135817 },
    { id = 17962,  name = "Conflagrate",  icon = 135807 },
    { id = 29722,  name = "Incinerate",   icon = 135789 },
    { id = 5740,   name = "Rain of Fire", icon = 136186 },
    { id = 6353,   name = "Soul Fire",    icon = 135808 },
}

-- Per-stat magnitude, so the test grid looks like a meter rather than like ten
-- copies of one number: damage and healing are in the millions, kicks and deaths
-- are single digits. Anything absent falls back to the counting shape.
local PREVIEW_SCALE = {
    DamageDone           = 4200000,
    HealingDone          = 2600000,
    Absorbs              =  480000,
    DamageTaken          =  910000,
    AvoidableDamageTaken =  120000,
    EnemyDamageTaken     = 3100000,
    Interrupts           =       9,
    Dispels              =       7,
    Deaths               =       3,
}

--- The test GROUP, in exactly the shape modules/Roster.lua builds.
---
--- The unit API is a data source too, and mocking only the meter would have left
--- the roster filter dropping every test row as "not in your group" — which is
--- the live behavior, correctly applied to invented data, and useless. So both
--- sources are mocked and everything between them is the live path.
---
--- @return table  array of { guid, unit, name, classFilename, role, isPlayer }
function Aggregator.TestGroup()
    local group = {}
    for index, member in ipairs(PREVIEW_MEMBERS) do
        group[index] = {
            guid          = string.format("Player-9999-TEST%04d", index),
            unit          = (index == 1) and "player" or ("party" .. (index - 1)),
            name          = member.name,
            classFilename = member.class,
            role          = member.role,
            isPlayer      = (index == 3),
        }
    end
    return group
end

--- One test COLUMN, in exactly the shape modules/Provider.lua returns.
---
--- This is where test mode now lives. It used to be a whole parallel result
--- table handed to the renderer (BuildTestRows), which made test mode and normal
--- mode two code paths that looked alike and diverged at every seam nobody
--- thought to duplicate. Substituting the PROVIDER's output instead means the
--- aggregator, the sorter, the row pool, the tooltip and the drill-down are all
--- the live code, reading numbers that happen to be invented.
---
--- The GUIDs are `Player-…` shaped rather than `Test-N`: modules/Roster.lua's
--- membership filter and modules/Row.lua's realm strip both key off that prefix,
--- and a test grid that skipped them would be testing a layout the live path
--- never produces.
---
--- @param sessionType number
--- @param statKey string
--- @return table  a provider column
function Aggregator.TestColumn(a, b, c)
    local statKey = b
    if a == Aggregator then statKey = c end

    local top = PREVIEW_SCALE[statKey or ""] or 8
    local column = { stat = statKey, maxAmount = top, totalAmount = top * 6, sources = {} }

    for index, member in ipairs(PREVIEW_MEMBERS) do
        local shape = ROLE_SHAPE[member.role] or ROLE_SHAPE.DAMAGER
        local total = math.floor(top * (1 - (index - 1) * 0.085) * (shape[statKey] or 1))
        if total < 0 then total = 0 end

        column.sources[index] = {
            guid            = string.format("Player-9999-TEST%04d", index),
            name            = member.name,
            classFilename   = member.class,
            specIconID      = member.spec,
            isLocalPlayer   = (index == 3),
            totalAmount     = total,
            amountPerSecond = math.floor(total / 300),
            deathRecapID    = (statKey == "Deaths") and (100 + index) or nil,
        }
    end

    return column
end

--- The spell breakdown behind one test row, in the provider's own shape.
---
--- modules/Tooltip.lua and modules/DrillDown.lua ask this BEFORE the provider
--- whenever test mode is on. Without it, hovering a test row reached
--- Provider.GetSourceDetail with a `Test-N` guid, got nil — correctly, there is
--- no such source — and drew "No data yet", which reads as a broken tooltip
--- rather than as placeholder data.
---
--- Deterministic, like every other number in this section, and derived from the
--- row's own guid so the same row always shows the same breakdown.
---
--- @param guid string|nil    a `Test-N` guid
--- @param statKey string|nil
--- @return table|nil  { combatSpells, maxAmount, totalAmount }
function Aggregator.TestSourceDetail(a, b, c)
    local guid, statKey = a, b
    if a == Aggregator then guid, statKey = b, c end
    if type(guid) ~= "string" then return nil end

    local index = tonumber(guid:match("^Player%-9999%-TEST(%d+)$"))
    if index == nil then return nil end

    local top = PREVIEW_SCALE[statKey or ""] or 8
    local scaled = math.floor(top * (1 - (index - 1) * 0.085))
    if scaled < 1 then scaled = 1 end

    local spells, total = {}, 0
    for i, spell in ipairs(PREVIEW_SPELLS) do
        local amount = math.floor(scaled * (1 - (i - 1) * 0.14))
        if amount < 1 then amount = 1 end
        total = total + amount
        spells[i] = {
            spellID     = spell.id,
            name        = spell.name,
            spellIcon   = spell.icon,
            totalAmount = amount,
            isAvoidable = (statKey == "AvoidableDamageTaken") and (i % 2 == 1) or nil,
            isDeadly    = (statKey == "AvoidableDamageTaken") and (i == 1) or nil,
        }
    end

    return { combatSpells = spells, maxAmount = spells[1].totalAmount, totalAmount = total }
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
--
-- Bus subscriptions only — core/MythicMeters.lua owns every game event and
-- publishes the restriction transition with its raw state attached, which is the
-- only reason the Activating edge is reachable from here at all.

function Aggregator:OnEnable()
    self:RegisterMessage(MSG.RESTRICTION_CHANGED, "OnRestrictionChanged")
    self:RegisterMessage(MSG.METER_RESET,         "OnMeterReset")
    self:RegisterMessage(MSG.PROFILE_CHANGED,     "OnMeterReset")
end

--- ADDON_RESTRICTION_STATE_CHANGED, forwarded.
---
--- `Activating` is the last moment a correct value-sort can be taken: it fires
--- BEFORE enforcement begins and access is still permitted during the dispatch
--- (design §4). So every window that sorts by value takes its final sort here,
--- and that result is the order it will hold for the whole pull.
---
--- Building every window costs one aggregate pass each, once per pull, at a
--- moment when the client is not yet doing anything expensive. That is the
--- cheapest point on the curve and the only correct one.
function Aggregator:OnRestrictionChanged(_, payload)
    local state = payload and payload.state
    if state == nil or state ~= Secrets.STATE.Activating then return end

    local profile = NS.db and NS.db.profile
    local windows = profile and profile.windows
    if type(windows) ~= "table" then return end

    for _, window in ipairs(windows) do
        if window and (window.data or {}).sortMode == "value" then
            Aggregator.Build(window)
        end
    end

    if State.debug then
        NS.Debug("Aggregator", "froze sort order for %d window(s) at the Activating edge", #windows)
    end
end

--- A frozen order describes a fight that no longer exists once the meter is
--- reset or the profile changes. Dropping it means the next unrestricted pass
--- takes a fresh sort instead of reviving last pull's ranking.
function Aggregator:OnMeterReset()
    State.WipeCache("Aggregator")
end
