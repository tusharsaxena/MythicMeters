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
--   2. Index every source by sourceGUID. Nothing here is ever keyed on a VALUE;
--      that is an immediate Lua error in combat and the single most tempting
--      mistake in the whole addon.
--   3. Filter to group members (modules/Roster.lua) and fold pets into owners.
--   4. Order, per the window's sortMode.
--   5. Cap to rows.maxRows, honoring rows.alwaysShowSelf.
--
-- THAT IS THE UNRESTRICTED BUILD, AND IT IS HALF THE FILE. `sourceGUID` is
-- annotated SecretWhenInCombat, so for the whole of a pull there is no join key
-- at all: it cannot be keyed on, compared or looked up. The second build —
-- IDENTITY MODE, further down — is what runs then, and it correlates on the
-- fields that stay plain instead. The choice is made once per pass.
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
-- THE SORT FREEZE, AND WHY IT IS GONE
-- ---------------------------------------------------------------------------
--
-- `value` mode sorts by the sort column's numbers, which requires comparing
-- them, which is illegal while restricted. This file used to answer that by
-- caching each successful value-sort as a guid -> position map, taking one last
-- sort at the ADDON_RESTRICTION_STATE_CHANGED `Activating` edge, and reapplying
-- that frozen order for the rest of the pull so nothing reshuffled.
--
-- ALL OF IT RESTED ON ROWS HAVING GUIDS MID-PULL, AND THEY DO NOT. A frozen
-- order is a map keyed on the one field that turns out to be secret exactly when
-- the freeze is needed, so it could never have been reapplied to a single row.
--
-- Identity mode replaces it with something better rather than poorer: the sort
-- column's `combatSources` arrives ALREADY RANKED by that column, so the order
-- is the engine's, it is live rather than a snapshot of the pull's first frame,
-- and it costs no comparison of ours. Rows re-rank as the fight moves, which is
-- what a meter is for.
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
--     identityMode    = boolean,               -- rows correlated, not GUID-joined
--     ambiguous       = boolean,               -- a class+spec pair could not be told apart
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
        -- Whether this pass must build without the GUID join. Asked of
        -- core/Secrets.lua rather than of State.restricted, which is a mirror
        -- for the render path: this decides which algorithm runs and has to be
        -- right rather than fast.
        identityMode = Secrets.IsRestricted(),
        -- Set by the identity build when two sources shared one identity key.
        ambiguous    = false,

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

--- Truth-test a field that MIGHT be a secret boolean.
---
--- `if src.isLocalPlayer then` is the natural way to write this and it raises the
--- moment that field is secret, because a boolean test on a secret boolean is
--- exactly what tainted code may not do. Asking core/Secrets.lua first keeps the
--- inspection in the one file allowed to make it, and an inaccessible flag reads
--- as "no claim" — the same shape modules/Tooltip.lua uses for isAvoidable.
local function plainTruth(v)
    if not Secrets.CanAccess(v) then return false end
    return v and true or false
end

--- The plain GUID a source with an UNKEYABLE GUID can still be attributed to.
---
--- THE MEASURED FACT THIS EXISTS FOR: `C_DamageMeter` returns a SECRET
--- `sourceGUID` while the Combat restriction is active. The design assumed the
--- opposite — "a GUID is never secret, so it is the ONLY thing in a session
--- legal as a table KEY" — and on that assumption the entire join rests. It does
--- not hold: NS.Secrets.IsSafeKey correctly refuses the key, every source is
--- dropped, and the window emptied for the whole of every pull.
---
--- A secret GUID cannot be keyed on, compared, or looked up, so for most sources
--- there is genuinely nothing left to join on and they stay dropped (see the
--- header on why a phantom row is worse). ONE identity survives: `isLocalPlayer`
--- is plain, so a source that says it is us can be attributed to the roster's own
--- plain GUID. That is the source's own statement about itself, not a guess.
---
--- Deliberately narrow. `classFilename` is plain too and would "identify" a
--- group member whenever no two of them share a class — which is a coin flip in
--- a party and false in a raid, and getting it wrong prints one player's numbers
--- under another player's name. Dropping a row is a visible absence; mislabeling
--- one is a lie the player cannot see.
---
--- @return string|nil  the local player's roster GUID, or nil for no claim
local function localClaim(src)
    if not plainTruth(src.isLocalPlayer) then return nil end
    return Roster.LocalGUID()
end

--- Say WHY a source was refused, on the first drop of the pass only.
---
--- `rows=0 dropped=N` is the shape every "my window is empty" report takes, and
--- the counter alone cannot say which of the causes it was: a GUID this context
--- may not key on, a source belonging to nobody in the group, or a pet with no
--- owner link. They need different fixes, so the refusal names itself.
---
--- `lookup` asks whether the CLIENT will resolve a source from a GUID we may not
--- resolve ourselves (modules/Provider.lua's ProbeSourceByGuid) — the question
--- that decides whether a future build can do better than identity correlation.
---
--- Every argument goes through NS.SafeToString: a GUID this branch could not use
--- is exactly the one that is likely secret, and a secret raises inside
--- string.format.
local function logDrop(pass, src, guid)
    NS.Debug("Aggregator",
        "dropped guid=%s secret=%s access=%s member=%s owner=%s local=%s/%s class=%s/%s lookup=%s",
        NS.SafeToString(guid), tostring(Secrets.IsSecret(guid)),
        tostring(Secrets.CanAccess(guid)),
        tostring(Roster.IsGroupMember(guid)), NS.SafeToString(Roster.OwnerOf(guid)),
        NS.SafeToString(src.isLocalPlayer), tostring(Secrets.IsSecret(src.isLocalPlayer)),
        NS.SafeToString(src.classFilename), tostring(Secrets.IsSecret(src.classFilename)),
        Provider.ProbeSourceByGuid(pass.sessionType, pass.sortColumn, guid))
end

--- The local player's row, started on first sight of it.
---
--- Reached only when the GUID join could not place the source and the source
--- claimed to be us — a mixed pass, where most GUIDs are plain and this one is
--- not. `claimed` is the ROSTER's own GUID, so the row keys, names and roles
--- exactly like any other, and nothing here touches the secret one.
local function claimedRow(pass, src, index, isSortColumn, claimed)
    local row = pass.byGuid[claimed]
    if row == nil then
        row = newRow(claimed, src, pass.windowId)
        row.providerIndex = isSortColumn and index or (UNRANKED + index)
        pass.byGuid[claimed] = row
        pass.rows[#pass.rows + 1] = row
    elseif isSortColumn then
        row.providerIndex = index
    end
    return row
end

--- The row `src` should be written into, started on first sight of its owner.
---
--- @return table|nil row  nil when the source was dropped (and counted)
--- @return boolean isOwn  true when the source IS the member, false for a pet
--- Refuse a source, count it, and say why the first time in each pass.
---
--- First-drop only, because a raid pull drops every enemy in the pack and forty
--- lines a quarter second is a log nobody can read (debug-logging-§4).
local function dropSource(pass, src, guid)
    pass.dropped = pass.dropped + 1
    if State.debug and pass.dropped == 1 then logDrop(pass, src, guid) end
    return nil, false
end

--- The row a placed source belongs on, started on first sight of its owner.
---
--- A PET GETS ITS OWN ROW unless the window asked for it to be merged. Merging
--- is ADDITION, so it runs only where the operands are accessible; a separate row
--- has no arithmetic in it at all, is exact in both states, and is what
--- Blizzard's own meter shows. That is why it is the default and merging is the
--- option rather than the other way round.
---
--- A pet's row is keyed on the PET's guid and carries its own name and class off
--- the source, so it reads as the pet it is rather than as a second copy of its
--- owner. `ownerGuid` is kept on it for the tooltip and for anything that later
--- wants to group them.
local function placedRow(pass, src, index, isSortColumn, ownerGuid, isOwn)
    local petOwner
    if not isOwn and not pass.mergePets then
        petOwner  = ownerGuid
        ownerGuid = src.guid
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

--- The row `src` should be written into.
---
--- @return table|nil row  nil when the source was dropped (and counted)
--- @return boolean isOwn  true when the source IS the member, false for a pet
local function rowForSource(pass, src, index, isSortColumn)
    local guid = src.guid
    local ownerGuid = owningMember(guid)

    if ownerGuid == nil then
        -- The local-player fallback returns EARLY rather than joining the path
        -- below, which compares `ownerGuid` against `guid` — and `guid` is
        -- exactly the secret value that got us here. `==` on a secret is a
        -- comparison, and a comparison raises. The row is the member's own by
        -- construction, so there is nothing to work out.
        local claimed = localClaim(src)
        if claimed == nil then return dropSource(pass, src, guid) end
        return claimedRow(pass, src, index, isSortColumn, claimed), true
    end

    return placedRow(pass, src, index, isSortColumn, ownerGuid, ownerGuid == guid)
end

-- ---------------------------------------------------------------------------
-- IDENTITY MODE — the grid while the GUID is secret
-- ---------------------------------------------------------------------------
--
-- Under the Combat restriction `sourceGUID` is SecretWhenInCombat, so the GUID
-- join below cannot run: a source can be neither keyed on, compared, nor looked
-- up. Everything that IDENTIFIES a source stays plain, though — `classFilename`,
-- `specIconID` and `isLocalPlayer` are all annotated NeverSecret — and that is
-- enough to build the grid a different way:
--
--   * the SORT column's `combatSources` is the row list, in the order the engine
--     returned it, which is the ranking. Row identity is its POSITION;
--   * every other column is read on its own and correlated to those rows by an
--     identity key built from the three plain fields;
--   * a key that appears twice in either the row list or a correlated column is
--     AMBIGUOUS — two players of the same class and spec — and every secondary
--     cell for it is left empty rather than filled with a number that might
--     belong to the other one.
--
-- That last rule is the whole reason this is honest. Class alone identifies
-- nobody in a raid; class plus spec plus "is it me" identifies almost everybody
-- almost always, and the cases where it does not are DETECTED rather than
-- guessed at. An empty cell is a visible absence; a mislabeled number is a lie
-- the player cannot see.
--
-- The local player is the one row that keeps a real GUID: `isLocalPlayer` is
-- plain and `UnitGUID("player")` never was secret, so their row is keyed on the
-- roster's own GUID and carries the roster's name and role.
--
-- Verified against Blizzard's field annotations and against Scoot's Damage Meter
-- Y, which solves it the same way.

--- The plain triple that stands in for a GUID while the GUID is secret.
local function identityKey(src)
    local class = src.classFilename
    if Secrets.IsSecret(class) then class = nil end
    local icon = src.specIconID
    if Secrets.IsSecret(icon) then icon = nil end
    -- Concatenation only, on values just proved plain. Never `..` on a secret.
    return (class or "UNKNOWN") .. "_" .. tostring(icon or 0)
        .. "_" .. tostring(plainTruth(src.isLocalPlayer))
end

--- Whether this source is an enemy rather than one of us.
---
--- `sourceDisplayType` is a plain enum, which is what makes it usable here: the
--- unrestricted path filters mobs out by asking the roster, and the roster
--- cannot answer for a source it cannot key on.
local function isEnemySource(src)
    local kind = src.sourceDisplayType
    if kind == nil or Secrets.IsSecret(kind) then return false end
    return kind == Const.SOURCE_DISPLAY_TYPE.Enemy
end

--- One correlated column: identity key -> the figure to show, plus the keys that
--- turned out to be ambiguous.
---
--- A counted stat (Deaths) reports one source row per event, so repeats of a key
--- are the same player dying twice and are TALLIED. For every other stat a
--- repeat is a genuine collision, because a player appears at most once.
local function correlateColumn(column, isCount, collisions)
    local byKey, seen = {}, {}
    for _, src in ipairs(column.sources) do
        if not isEnemySource(src) then
            local key = identityKey(src)
            if isCount then
                byKey[key] = (byKey[key] or 0) + 1
            elseif seen[key] then
                collisions[key] = true
            else
                seen[key] = true
                -- The value is copied, never examined — opaque exactly as it
                -- arrived, and it reaches a widget setter or the formatter.
                byKey[key] = src.totalAmount
            end
        end
    end
    return byKey
end

--- Read one column onto the pass and hand it back. Shared by both halves of the
--- identity build so the bookkeeping is written once.
local function takeColumn(pass, statKey)
    local column = Provider.GetColumn(pass.sessionType, statKey, pass.sessionID)
    pass.columns[statKey] = column
    pass.columnTotals[statKey] = column.totalAmount
    if column.reason and pass.reason == nil then pass.reason = column.reason end
    return column, (Const.STAT_BY_KEY[statKey] or {}).isCount or false
end

--- A counted column scales every bar to the highest COUNT.
---
--- Those counters are ours and plain, so comparing them is legal mid-pull where
--- comparing two meter values would not be. The session's own max is useless
--- here: Deaths reports 0, and a bar scaled to 0 draws full for everybody.
local function rescaleCounted(pass, statKey)
    local highest = 0
    for i = 1, #pass.rows do
        local cell = pass.rows[i].values[statKey]
        if cell and cell.total > highest then highest = cell.total end
    end
    if highest < 1 then highest = 1 end
    for i = 1, #pass.rows do
        local cell = pass.rows[i].values[statKey]
        if cell then cell.maxAmount = highest end
    end
    pass.columnTotals[statKey] = nil
end

--- The row this source belongs on, started on first sight of it.
---
--- The local player keeps a REAL guid — `isLocalPlayer` is plain and
--- `UnitGUID("player")` is not secret — so their row joins the roster's name and
--- role. Everyone else is keyed on their POSITION, a plain string the row pool
--- and the drill-down can hold without ever touching the secret one.
local function identityRow(pass, src, index, localGuid)
    local isLocal = plainTruth(src.isLocalPlayer)
    local rowGuid = (isLocal and localGuid) or ("rank_" .. index)

    local row = pass.byGuid[rowGuid]
    if row ~= nil then return row end

    row = newRow(rowGuid, src, pass.windowId)
    -- newRow takes identity from the roster where the roster has it, which here
    -- is the local player and nobody else. For every other row the source's own
    -- fields are all there is — and `name` among them is ConditionalSecret, so it
    -- travels to SetText and nowhere else.
    if not isLocal then
        row.isPlayer      = false
        row.isLocalPlayer = false
    end
    row.identityKey   = identityKey(src)
    row.providerIndex = index
    pass.byGuid[rowGuid] = row
    pass.rows[#pass.rows + 1] = row
    return row
end

--- Fill one non-sort column by correlating it back onto the rows already built.
local function fillCorrelated(pass, statKey, collisions)
    local column, isCount = takeColumn(pass, statKey)
    local byKey = correlateColumn(column, isCount, collisions)

    for i = 1, #pass.rows do
        local row = pass.rows[i]
        local value = byKey[row.identityKey]
        -- A collided key is left EMPTY rather than filled from a source that
        -- might be the other player's. That refusal is the whole warrant for
        -- correlating on class and spec at all.
        if value ~= nil and not collisions[row.identityKey] then
            row.values[statKey] = {
                total     = value,
                maxAmount = not isCount and column.maxAmount or nil,
            }
        end
    end

    if isCount then rescaleCounted(pass, statKey) end
end

--- Build every row from the sort column's source list, then fill the rest of the
--- grid by identity correlation.
local function buildByIdentity(pass)
    local sortKey = pass.sortColumn
    local column, sortCount = takeColumn(pass, sortKey)
    local collisions, seenKeys = {}, {}
    local localGuid = Roster.LocalGUID()

    for index, src in ipairs(column.sources) do
        if isEnemySource(src) then
            pass.dropped = pass.dropped + 1
        else
            local key = identityKey(src)
            if seenKeys[key] then collisions[key] = true end
            seenKeys[key] = true

            local row = identityRow(pass, src, index, localGuid)
            setCell(row, sortKey, src, not sortCount and column.maxAmount or nil, sortCount)
        end
    end

    for _, statKey in ipairs(pass.keys) do
        if statKey ~= sortKey then fillCorrelated(pass, statKey, collisions) end
    end

    if sortCount then rescaleCounted(pass, sortKey) end
    pass.ambiguous = next(collisions) ~= nil
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
--- that ACTUALLY took effect, which is what the debug line records.
---
--- ONLY EVER REACHED UNRESTRICTED. While the Combat restriction is active the
--- pass takes the identity build instead, which has its own order — the engine's
--- — so the ladder below never has to degrade for secrecy. That is what retired
--- the sort freeze: it existed to hold a GUID order steady through a pull, and
--- mid-pull rows no longer have GUIDs to hold.
---
--- @return string  the mode applied: the window's own, or "provider"
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

    if orderByValue(rows, pass.sortColumn, pass.sortAscending) then return mode end

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
    -- Published so the window can say WHY a mid-pull grid reads differently:
    -- rows came from identity correlation rather than the GUID join, and
    -- `ambiguous` means at least one class+spec pair could not be told apart and
    -- had its secondary cells left empty on purpose.
    kept.identityMode    = pass.identityMode
    kept.ambiguous       = pass.ambiguous
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

    -- TWO BUILDS, chosen by whether the join key exists at all. The GUID join is
    -- the exact one and runs whenever `sourceGUID` is plain; under the Combat
    -- restriction it is secret, and identity correlation is what stands in for
    -- it (see the section header). The choice is made ONCE per pass rather than
    -- per source, so a grid is never half one shape and half the other.
    if pass.identityMode then
        buildByIdentity(pass)
        -- Engine order IS the ranking, and it is the only order available: value
        -- sorting needs comparisons, and the frozen order is keyed on GUIDs that
        -- no longer resolve. `applied` reports what actually happened.
        orderByProvider(pass.rows)
        pass.applied = "provider"
    else
        for _, statKey in ipairs(pass.keys) do scanColumn(pass, statKey) end
        pass.applied = applySortMode(pass)
    end

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
-- Bus subscriptions only — core/MythicMeters.lua owns every game event.
--
-- THE `Activating` EDGE IS NO LONGER LISTENED FOR. It used to be the last legal
-- moment to take a value-sort, and that sort's result was frozen and reapplied
-- for the whole pull. Both halves are gone: mid-pull rows are keyed on their
-- position rather than on a GUID, so there is no order to freeze and nothing to
-- reapply it to. The engine's own ranking of the sort column is the order now,
-- and it is live rather than a snapshot. modules/Window.lua still redraws on the
-- transition, which is all that was ever needed here.

function Aggregator:OnEnable()
    self:RegisterMessage(MSG.METER_RESET,     "OnMeterReset")
    self:RegisterMessage(MSG.PROFILE_CHANGED, "OnMeterReset")
end

--- The cache this module owns describes a fight that no longer exists once the
--- meter is reset or the profile changes.
function Aggregator:OnMeterReset()
    State.WipeCache("Aggregator")
end
