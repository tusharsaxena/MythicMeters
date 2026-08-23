-- modules/Export.lua
--
-- Takes what a meter window is showing and turns it into text a human can carry
-- somewhere else: a CSV of the whole segment for a spreadsheet, or a short
-- ranked list for chat. A glyph in the window header opens the modal below;
-- `/mm export` opens the same one.
--
-- TOC POSITION: modules/, after modules/DrillDown.lua. Everything it needs from
-- a sibling module is resolved at CALL time (see `mod` below), so its place in
-- the modules/ block carries no meaning beyond "after the things it reads".
--
-- ---------------------------------------------------------------------------
-- WHY THIS FILE HAS NO DATA PATH OF ITS OWN
-- ---------------------------------------------------------------------------
--
-- The tempting shape is a walk over the meter API: an export wants every stat
-- for every player, which is exactly the loop modules/Provider.lua already
-- writes. Doing it again here would put a SECOND caller on C_DamageMeter, and
-- rule R1 (docs/data-flow.md) allows exactly one.
--
-- So this file asks for its data the way a window does. SessionConfig builds a
-- SYNTHETIC window config — one naming every stat in the catalog, pointed at the
-- invoking window's segment — and hands it to Aggregator.Build. The aggregator
-- does not know or care that no frame will ever draw the result. Nothing below
-- touches Provider, Compat's meter shims, or C_DamageMeter, and it must stay
-- that way: an export is a consumer of the grid's data, not a second producer.
--
-- ---------------------------------------------------------------------------
-- WHY THE WHOLE THING IS A REFUSAL IN COMBAT
-- ---------------------------------------------------------------------------
--
-- A CSV cell is `tostring(value)`, and `tostring` is NOT on docs/data-flow.md's
-- list of operations permitted on a secret. It does not raise and it does not
-- launder: it answers a SECRET STRING, which then poisons the `find`, the `gsub`
-- and the `..` that RFC-4180 quoting is made of. There is no way to write a
-- serializer that is correct while the Combat restriction is active, and a
-- serializer that is subtly wrong mid-pull is worse than one that says no.
--
-- Hence two independent guards, deliberately belt-and-braces:
--
--   1. STRUCTURAL. Secrets.IsRestricted() is asked when the modal opens, again
--      inside each click handler, and once more at the top of the serializers.
--      The restriction can activate while the modal sits open; the click is the
--      last moment anyone can check.
--   2. PER VALUE. Every field passes Secrets.CanAccess on its way in and yields
--      "" when it fails. A race between the check and the walk can therefore
--      produce a blank cell. It can never produce an error.
--
-- ---------------------------------------------------------------------------
-- THE TWO HALVES
-- ---------------------------------------------------------------------------
--
-- Above the "Export modal" divider everything is PURE: no frames, no globals
-- beyond the ones the fields come from, and every function reachable from the
-- headless harness (tests/test_export.lua). Below it is UI, built lazily on the
-- first Open and guarded on CreateFrame so this file loads in a harness that has
-- no client at all — the UI half degrades to nil and the pure half still works.

local addonName, NS = ...

-- A PLAIN TABLE on NS, like NS.Slash — not an AceAddon module. There is no
-- OnEnable to run and nothing to wire at load: it is called directly
-- (NS.Export:Open) and nothing else.
--
-- It does take ONE bus subscription, and only once a modal has been built:
-- RESTRICTION_CHANGED, on a private target, so an open dialog greys its buttons
-- when a pull starts instead of waiting for a click to explain itself. Its only
-- other lasting state is the window it was opened from and the two lazily built
-- frames.
NS.Export = NS.Export or {}
local Export = NS.Export

local Const = NS.Constants
local L     = NS.L
local MSG   = Const.MSG

-- The modal's three selectors are LibKa0s-Widgets-1.0 dropdowns; see "The
-- modal's three selectors" below for why. Soft-optionaled like every other
-- LibKa0s seam this addon carries: `Export.Open` refuses rather than building a
-- modal with three dead controls when this is nil.
local W = LibStub and LibStub("LibKa0s-Widgets-1.0", true)

-- U+2014 EM DASH, spelled in bytes. The source files in this addon are read and
-- edited by tools whose encoding cannot be assumed; the escape always survives.
local EM_DASH = " \226\128\148 "

-- The choices the Lines selector offers. Not 1..40 in a spinner: the point of a
-- chat dump is that it is short, and five numbers are quicker to hit than a
-- slider. The last one is the aggregator's own ceiling rather than a literal 40,
-- so a change to MAX_ROWS moves both.
local LINE_CHOICES = { 3, 5, 10, 20, Const.MAX_ROWS }

-- Seconds between two lines of a chat dump. Roughly three a second, which is
-- under every flood threshold the server enforces and still fast enough that a
-- five-line ranking is on screen before anybody has read the first line. A
-- forty-line dump takes about twelve seconds, and arriving whole is the point.
local CHAT_STAGGER = 0.3

--- Resolve a collaborator by either shape it can have: a plain table hung on NS,
--- or an AceAddon module in the registry. Same helper modules/Window.lua uses,
--- and here for a second reason as well — modules/ load order relative to this
--- file is not guaranteed, so NOTHING below may be captured at file scope.
---
--- @param name string
--- @return table|nil
local function mod(name)
    local m = NS[name]
    if m then return m end
    if NS.GetModule then return NS:GetModule(name, true) end
    return nil
end

--- The number formatter, resolved defensively. NS.Format is a callable table and
--- NS.NumberFormat is the same object under its other name; a degraded install
--- can have published only one of them.
---
--- @return table|nil
local function fmt()
    local F = mod("Format")
    if type(F) ~= "table" or not F.Number then F = NS.NumberFormat end
    if type(F) ~= "table" or not F.Number then return nil end
    return F
end

--- Accept either a Window instance or a bare config table.
---
--- The slash verb has only a config (it walks the registry), the header glyph
--- has only an instance, and every entry point below is reachable from both. One
--- unwrap at the top of each is cheaper than two APIs.
---
--- @param win table|nil  a Window instance, or a window config
--- @return table  a config table, possibly empty
local function cfgOf(win)
    if type(win) ~= "table" then return {} end
    if type(win.config) == "table" then return win.config end
    return win
end

-- ---------------------------------------------------------------------------
-- The profile seam
-- ---------------------------------------------------------------------------
--
-- Every choice the modal makes is remembered at `export.*` in the profile, so
-- the second export of an evening is one click. Writes go through
-- NS.SetByPath — the schema's single write seam — which logs the change,
-- announces CONFIG_CHANGED and keeps an open settings panel in step. Reads go
-- through NS.GetSetting for the same reason: it is the one place that knows how
-- a path resolves.
--
-- Both fall back to the profile table directly, and that fallback is NOT
-- decoration. SetByPath refuses a path it has no schema row for, and a degraded
-- or partially loaded install can reach this file with settings/Schema.lua
-- absent. The fallback is what makes the modal remember a choice anyway, for
-- the length of the session at worst.

local EXPORT_GROUP = "export"

--- Read one remembered export choice.
---
--- @param key string       the leaf name under `export.`
--- @param fallback any     what to answer when nothing is stored
--- @return any
local function readExport(key, fallback)
    if type(NS.GetSetting) == "function" then
        local v = NS.GetSetting(EXPORT_GROUP .. "." .. key)
        if v ~= nil then return v end
    end
    local db = NS.db
    local group = db and db.profile and db.profile[EXPORT_GROUP]
    local stored = group and group[key]
    if stored ~= nil then return stored end
    return fallback
end

--- Remember one export choice.
---
--- @param key string
--- @param value any
--- @return boolean  whether it was stored anywhere
local function writeExport(key, value)
    if type(NS.SetByPath) == "function" then
        if NS.SetByPath(EXPORT_GROUP .. "." .. key, value) then return true end
    end
    local db = NS.db
    if not (db and db.profile) then return false end
    local group = db.profile[EXPORT_GROUP]
    if type(group) ~= "table" then
        group = {}
        db.profile[EXPORT_GROUP] = group
    end
    group[key] = value
    return true
end

-- ---------------------------------------------------------------------------
-- Serialization — pure
-- ---------------------------------------------------------------------------

--- Is exporting legal right now?
---
--- The one gate the whole file hangs off. False while the Combat restriction is
--- active, because a serializer cannot run there (see the header). Answers a
--- real boolean and a sentence the caller may show verbatim.
---
--- @return boolean available, string|nil reason
function Export.Available()
    local Secrets = mod("Secrets")
    if Secrets and Secrets.IsRestricted() then
        return false, L["Export is not available while the game restricts combat data."]
    end
    return true, nil
end

--- A stat key as a CSV header name: "DamageDone" -> "damage_done".
---
--- DERIVED, never a restated list. A hand-written table of nine header names is a
--- table that goes stale the first time the catalog grows a tenth stat, and it
--- goes stale silently — the new column would export under whatever name the
--- table's fallback picked. The one rule below covers every key the catalog has
--- and every key it will have, because the keys are CamelCase by construction.
---
--- A localized label is emphatically NOT what goes here: a CSV is a data
--- interchange, and a German client must produce a file a colleague on an
--- English client can open with the same formulas.
---
--- @param statKey string
--- @return string
function Export.HeaderName(statKey)
    local out = tostring(statKey):gsub("(%l)(%u)", "%1_%2")
    return out:lower()
end

--- One CSV field, RFC-4180 quoted: wrapped when it contains a comma, a quote, a
--- CR or an LF, with embedded quotes doubled.
---
--- This is the LAUNDERING POINT of the whole file. Everything upstream of it may
--- be an opaque meter handle; everything downstream is a plain Lua string, which
--- is why the row assembly below is allowed to use table.concat at all.
---
--- The CanAccess guard is the per-value half of the combat rule. `tostring` on a
--- secret answers a secret string rather than raising, and a secret string
--- poisons the `find` and the `gsub` on the next two lines — so the value is
--- asked first and a blank field is the answer when it says no. A blank cell in
--- a race is a cost worth paying for a serializer that cannot error.
---
--- @param v any     a plain value, or an opaque meter handle, or nil
--- @return string
function Export.CsvField(v)
    if v == nil then return "" end
    local Secrets = mod("Secrets")
    if Secrets and Secrets.CanAccess and not Secrets.CanAccess(v) then return "" end
    local s = tostring(v)
    if s:find('[,"\r\n]') then s = '"' .. s:gsub('"', '""') .. '"' end
    return s
end

--- The stat half of the CSV column set, in catalog order.
---
--- Three kinds, and the reason each exists:
---   * `total` — one per stat, always. The raw amount.
---   * `rate`  — one per `isRate` stat and no others, suffixed `_ps`. A
---               per-second figure for Deaths or Interrupts is nonsense, and an
---               always-blank column is worse than an absent one.
---   * `pct`   — one per stat, suffixed `_pct`. Blank rather than absent when the
---               share cannot be computed (a counted stat has no column total,
---               and no stat has one mid-pull), because a spreadsheet's columns
---               must line up between two exports of different fights.
---
--- Each entry carries the same three facts twice: positionally, for the terse
--- `for _, c in ipairs` walk the serializer does, and by name, so a call site
--- that wants one of them reads as prose.
---
--- @return table  array of { header, statKey, kind } / { header=, statKey=, kind= }
function Export.Columns()
    local columns = {}
    local function add(header, statKey, kind)
        columns[#columns + 1] = {
            header, statKey, kind,
            header = header, statKey = statKey, kind = kind,
        }
    end

    for _, stat in ipairs(Const.STATS) do
        local base = Export.HeaderName(stat.key)
        add(base, stat.key, "total")
        if stat.isRate then add(base .. "_ps", stat.key, "rate") end
        add(base .. "_pct", stat.key, "pct")
    end

    return columns
end

-- The identity columns every row leads with. Session and duration ride on EVERY
-- row rather than sitting in a preamble on purpose: two exports concatenated in
-- one sheet then still mean something, and a pivot table can group by fight
-- without anyone hand-editing the file first.
local LEAD_HEADERS = { "session", "duration", "name", "class", "spec", "role" }

--- The window config an export is built from: every stat in the catalog, the
--- invoking window's segment, and the aggregator's own row ceiling.
---
--- Deliberately NOT the window's own config. What is on screen is a display
--- choice — three columns, sorted by damage, capped at ten rows — and none of
--- that is what someone asking for "the data" means. The segment IS inherited,
--- because "export this" said while looking at last pull means last pull.
---
--- `sortColumn` is an argument rather than always the window's, so Print to Chat
--- can rank by the metric it is about to print. Ranking happens here, in the
--- aggregator, where comparing two values is legal; nothing below ever sorts.
---
--- @param win table|nil            a Window instance or config
--- @param sortColumn string|nil    override the window's sort column
--- @return table  a synthetic window config for Aggregator.Build
function Export.SessionConfig(win, sortColumn)
    local cfg  = cfgOf(win)
    local data = cfg.data or {}

    local columns = {}
    for _, stat in ipairs(Const.STATS) do
        columns[#columns + 1] = { stat = stat.key, enabled = true }
    end

    if sortColumn == nil or Const.STAT_BY_KEY[sortColumn] == nil then
        sortColumn = data.sortColumn
    end
    if sortColumn == nil or Const.STAT_BY_KEY[sortColumn] == nil then
        sortColumn = Const.STATS[1] and Const.STATS[1].key
    end

    return {
        -- A string id, where a window's is a number. It never enters the
        -- registry — it exists so the rows the aggregator stamps say where they
        -- came from if one ever turns up in a log.
        id      = "export",
        columns = columns,
        -- MAX_ROWS is the aggregator's hard ceiling anyway; naming it here makes
        -- the 40-row truncation a documented property of an export rather than
        -- something a reader has to find in ApplyRowLimit.
        rows    = { maxRows = Const.MAX_ROWS },
        data    = {
            sessionType   = data.sessionType or Const.SESSION_TYPE.Current,
            sessionID     = data.sessionID,
            sortColumn    = sortColumn,
            sortMode      = "value",
            sortAscending = false,
            mergePets     = data.mergePets,
        },
    }
end

--- Build the data an export renders.
---
--- @param win table|nil            a Window instance or config
--- @param sortColumn string|nil    rank by this stat instead of the window's
--- @return table|nil  an Aggregator.Build result, or nil with no aggregator
function Export.Build(win, sortColumn)
    local Aggregator = mod("Aggregator")
    if not (Aggregator and Aggregator.Build) then return nil end
    return Aggregator.Build(Export.SessionConfig(win, sortColumn))
end

--- What to call the segment being exported.
---
--- Asked of the WINDOW, never of the provider: naming a stored session means
--- matching an id against the session list, and this file is not allowed near
--- that API (rule R1). A window instance already answers the question for its
--- own header, so the instance answers it here too; a bare config falls back to
--- the two names a config can produce on its own.
---
--- pcall'd because SessionLabel reaches through a collaborator that a degraded
--- install may not have, and a missing label must cost an export nothing.
---
--- @param win table|nil
--- @return string
function Export.SessionLabel(win)
    if type(win) == "table" and type(win.SessionLabel) == "function" then
        local ok, label = pcall(win.SessionLabel, win, false)
        -- No `~= ""`: that is a comparison, and a window's label is a string
        -- built from a session name the meter may be hiding. type() is the whole
        -- test the answer needs.
        if ok and type(label) == "string" then return label end
    end

    local data = cfgOf(win).data or {}
    if data.sessionID ~= nil then return L["Segment"] end
    if data.sessionType == Const.SESSION_TYPE.Overall then return L["Overall"] end
    return L["Current"]
end

--- A cell's percentage as a bare two-decimal number, or "".
---
--- NOT Format.Percent, which appends a "%" — a spreadsheet wants a number it can
--- average. `cell.percent` is already scaled 0..100 and is computed by the
--- aggregator only when the comparison behind it was legal, so it is a plain
--- number or nil; the guards below are for the nil and for the impossible.
---
--- @param cell table|nil
--- @return string
local function percentField(cell)
    local pct = cell and cell.percent
    if type(pct) ~= "number" then return "" end
    return string.format("%.2f", pct)
end

--- A duration as raw whole seconds, for a spreadsheet. "" when it is missing or
--- cannot be looked at.
---
--- @param seconds any
--- @return string
local function durationField(seconds)
    if seconds == nil then return "" end
    local Secrets = mod("Secrets")
    if Secrets and Secrets.CanAccess and not Secrets.CanAccess(seconds) then return "" end
    if type(seconds) ~= "number" then return "" end
    return string.format("%d", math.floor(seconds + 0.5))
end

--- An Aggregator.Build result as CSV text.
---
--- Pure CSV: no preamble, no comment line, CRLF endings and a trailing CRLF, so
--- it pastes into a sheet without anyone deleting a header block first.
---
--- Refuses outright while the Combat restriction is active — see the file
--- header. The refusal is an EMPTY STRING rather than nil so a caller that hands
--- the answer straight to an EditBox cannot be the thing that errors; the reason
--- rides on the second return for a caller that wants to say why.
---
--- @param result table|nil   an Aggregator.Build result
--- @param session string|nil the segment's name, for the leading column
--- @return string csv, string|nil reason
function Export.CSV(result, session)
    local ok, reason = Export.Available()
    if not ok then return "", reason end
    if type(result) ~= "table" then return "", nil end

    local columns = Export.Columns()

    local header = {}
    for i, name in ipairs(LEAD_HEADERS) do header[i] = name end
    for _, column in ipairs(columns) do header[#header + 1] = column.header end

    local lines = { table.concat(header, ",") }

    -- `result.rows` and `result` are the same table in a normal build; the
    -- degenerate "no config" build returns a `rows` that is a separate empty
    -- array. Reading the field first is correct for both.
    local rows     = result.rows or result
    local session_ = Export.CsvField(session)
    local duration = Export.CsvField(durationField(result.durationSeconds))

    for _, row in ipairs(rows) do
        local cells = {
            session_,
            duration,
            Export.CsvField(row.name),
            Export.CsvField(row.classFilename),
            Export.CsvField(row.specIconID),
            Export.CsvField(row.role),
        }

        for _, column in ipairs(columns) do
            -- An absent cell is the COMMON case, not an error: most players have
            -- no row in Dispels, Interrupts or Deaths. It exports as blank.
            local cell = row.values and row.values[column.statKey]
            local value
            if column.kind == "pct" then
                value = percentField(cell)
            elseif column.kind == "rate" then
                value = cell and cell.rate
            else
                value = cell and cell.total
            end
            cells[#cells + 1] = Export.CsvField(value)
        end

        -- table.concat is legal here and nowhere near a meter value: every entry
        -- came out of CsvField, which answers a plain string or "".
        lines[#lines + 1] = table.concat(cells, ",")
    end

    return table.concat(lines, "\r\n") .. "\r\n", nil
end

--- One player's name, as a string safe to concatenate into a chat line.
---
--- `row.name` is ConditionalSecret — the roster's answer is plain, the meter's
--- fallback is not — so it is asked twice before it is used: CanAccess for "may
--- this context look at it", IsConcatSafe for "will `..` survive it". Out of
--- combat both say yes and this is one tostring; mid-pull neither is reached,
--- because ChatLines refuses before it gets here.
---
--- @param row table
--- @return string
local function displayName(row)
    local name = row.name
    if name == nil then return L["Unknown"] end

    local Secrets = mod("Secrets")
    if Secrets and Secrets.CanAccess and not Secrets.CanAccess(name) then
        return L["Unknown"]
    end
    if NS.IsConcatSafe and not NS.IsConcatSafe(name) then
        return NS.SafeToString and NS.SafeToString(name) or L["Unknown"]
    end
    return tostring(name)
end

--- An Aggregator.Build result as a short ranked list for chat.
---
--- The first line names the addon, the metric, the segment and its duration; the
--- rest are ranked entries. Abbreviated numbers here, unlike the CSV — chat
--- wants "4.8M", and nobody reads a nine-digit figure out of a scrolling frame.
---
--- The RANK IS THE ORDER THE AGGREGATOR RETURNED. Nothing here sorts: comparing
--- two meter values is the operation the restriction forbids, and the aggregator
--- has already done it under its own guards. Rank by a different stat by asking
--- Export.Build for that sort column.
---
--- Refuses to the empty array while restricted, for the reason in the header.
---
--- @param result table|nil    an Aggregator.Build result
--- @param statKey string|nil  which stat to print; defaults to the first catalog stat
--- @param limit number|nil    how many ranked lines; clamped 1..MAX_ROWS, default 5
--- @param session string|nil  the segment's name, for the header line
--- @return table  array of strings, possibly empty
function Export.ChatLines(result, statKey, limit, session)
    if not Export.Available() then return {} end
    if type(result) ~= "table" then return {} end

    local stat = Const.STAT_BY_KEY[statKey] or Const.STATS[1]
    if not stat then return {} end

    limit = tonumber(limit) or 5
    if limit < 1 then limit = 1 end
    if limit > Const.MAX_ROWS then limit = Const.MAX_ROWS end

    local F = fmt()
    if not F then return {} end

    -- Built with `..` rather than table.concat, which is the house rule for any
    -- string a meter value can reach: concat raises on a secret where `..` is on
    -- the permitted list, and a formatter can hand back a handle rather than a
    -- string on a client we have not met yet.
    local head = L["Multi Meters"] .. EM_DASH .. (L[stat.label] or stat.label)
    -- `type()` is permitted on a secret and `..` is permitted on one; asking
    -- whether it is the empty string is not. Window never answers "" anyway.
    if type(session) == "string" then
        head = head .. EM_DASH .. session
    end
    -- DECIDED FROM THE PLAIN INPUT, never from the formatter's answer. Duration
    -- can hand back a secret string, and `~= ""` on one is a comparison — which
    -- is on the forbidden list even though `..` two lines up is not.
    -- modules/Window.lua's DurationText makes the same distinction.
    local seconds = result.durationSeconds
    if seconds ~= nil and F.Duration then
        head = head .. " (" .. F.Duration(seconds) .. ")"
    end

    local lines = { head }
    local rows  = result.rows or result

    for index, row in ipairs(rows) do
        if index > limit then break end

        local cell = row.values and row.values[stat.key]
        local line = index .. ". " .. displayName(row) .. " "
            .. F.Number(cell and cell.total)

        -- The parenthetical carries whatever is meaningful and nothing else: no
        -- per-second figure for a counted stat, no share when the aggregator
        -- could not compute one. An empty "( )" would be noise on every line of
        -- a Deaths dump.
        -- `hasExtra` rather than `extra ~= ""`, for the same reason the duration
        -- above is decided from its input: a formatter may have put a secret
        -- string into `extra`, and reading one back to ask whether it is empty is
        -- a comparison. The boolean knows the answer without looking.
        local extra, hasExtra = "", false
        if stat.isRate and cell and cell.rate ~= nil and F.Rate then
            extra, hasExtra = extra .. F.Rate(cell.rate), true
        end
        if cell and type(cell.percent) == "number" and F.Percent then
            if hasExtra then extra = extra .. ", " end
            extra, hasExtra = extra .. F.Percent(cell.percent), true
        end
        if hasExtra then line = line .. " (" .. extra .. ")" end

        lines[#lines + 1] = line
    end

    return lines
end

-- ---------------------------------------------------------------------------
-- Channels
-- ---------------------------------------------------------------------------

--- One row out of the channel catalog, by key.
---
--- @param key string|nil
--- @return table|nil
local function channelRow(key)
    if key == nil then return nil end

    -- The BY_KEY map first: core/Constants.lua builds it from the array so the
    -- two cannot disagree, and it names this module as the consumer it exists
    -- for. The scan below is the degraded path only — a load where the map is
    -- absent but the array is not — rather than a second lookup with its own
    -- opinion about what a key means.
    local byKey = Const.EXPORT_CHANNEL_BY_KEY
    if type(byKey) == "table" then return byKey[key] end

    local catalog = Const.EXPORT_CHANNELS
    if type(catalog) ~= "table" then return nil end
    for _, row in ipairs(catalog) do
        if row.key == key then return row end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- What each rung of the AUTO ladder is asking about
-- ---------------------------------------------------------------------------
--
-- One predicate per catalog key, so the ORDER lives in core/Constants.lua
-- (EXPORT_AUTO_ORDER) and only the QUESTION lives here. Reordering the ladder is
-- then an edit to the catalog and nothing else.
--
-- SAY is deliberately absent and is the floor: a solo player who picked AUTO
-- asked for the lines to go somewhere, and there is nowhere more specific.
local AUTO_TEST = {
    -- Instance chat is the one channel everybody in a dungeon, a raid finder
    -- group or a battleground can read, so it outranks both group channels —
    -- but only while actually grouped, or it is a channel of one.
    -- MEMBERSHIP OF THE INSTANCE GROUP, NOT PRESENCE IN AN INSTANCE. Those are
    -- different facts and the difference is the whole rung: a guild raid that
    -- walks into a raid instance is in an instance and is NOT an instance group,
    -- and SendChatMessage on INSTANCE_CHAT for such a group is a silent no-op —
    -- no error, no message, nothing in the log. Asking IsInInstance() would
    -- therefore make RAID and PARTY unreachable for exactly the premade groups
    -- this addon is for, and the failure would look like "export does nothing".
    --
    -- IsInGroup takes a party category; the Enum is read defensively because the
    -- headless harness defines neither it nor the older global.
    INSTANCE_CHAT = function()
        local Enum = _G.Enum
        local category = (Enum and Enum.PartyCategory and Enum.PartyCategory.Instance)
            or _G.LE_PARTY_CATEGORY_INSTANCE
        if category and _G.IsInGroup and _G.IsInGroup(category) then return true end
        -- The queued-content fallback for a client whose category enum moved.
        return (_G.IsPartyLFG and _G.IsPartyLFG()) or false
    end,
    RAID  = function() return _G.IsInRaid and _G.IsInRaid() end,
    PARTY = function() return _G.IsInGroup and _G.IsInGroup() end,
}

-- The ladder to walk when core/Constants.lua's copy is missing. Same rungs in
-- the same order — this is a degraded-load fallback, not a second opinion.
local AUTO_ORDER_FALLBACK = { "INSTANCE_CHAT", "RAID", "PARTY", "SAY" }

--- Which channel AUTO actually resolves to, right now.
---
--- @return string  a channel key, never nil (SAY is the floor)
local function resolveAuto()
    local order = Const.EXPORT_AUTO_ORDER
    if type(order) ~= "table" or #order == 0 then order = AUTO_ORDER_FALLBACK end

    for _, key in ipairs(order) do
        local test = AUTO_TEST[key]
        -- A rung with no predicate is unconditional, which is what makes SAY the
        -- floor without naming SAY here.
        if not test then return key end
        if test() then return key end
    end

    return "SAY"
end

--- Turn a stored channel choice into the pair SendChatMessage wants.
---
--- SELF answers nil, and that is why it is the default: a misclick on a modal
--- that defaulted to RAID is a wipe-night apology, while a misclick on SELF is
--- three lines in your own chat frame.
---
--- AUTO walks the ladder "the group I am actually in, most specific first" —
--- instance chat inside a dungeon or raid finder group, then the raid, then the
--- party, then say. Say is the floor rather than a nil, because a solo player
--- who deliberately picked AUTO asked for it to go somewhere.
---
--- Anything else uses the catalog row's chatType when there is one and the key
--- itself otherwise; the keys ARE the chat types ("SAY", "PARTY", "GUILD"), so
--- this keeps working on a load where core/Constants.lua's catalog is missing.
---
--- @param channel string|nil  a key from Const.EXPORT_CHANNELS
--- @param target string|nil   the whisper recipient, for WHISPER
--- @return string|nil chatType, string|nil target
function Export.ResolveChannel(channel, target)
    if type(channel) ~= "string" or channel == "" then channel = "SELF" end
    channel = channel:upper()

    if channel == "SELF" then return nil, nil end

    if channel == "WHISPER" then
        if type(target) ~= "string" then target = nil end
        if target then target = target:gsub("^%s+", ""):gsub("%s+$", "") end
        -- A whisper with nobody to whisper to is not an error to report at the
        -- send site; it is the same "keep it to yourself" SELF means.
        if not target or target == "" then return nil, nil end
        return "WHISPER", target
    end

    if channel == "AUTO" then
        local key = resolveAuto()
        local row = channelRow(key)
        return (row and row.chatType) or key, nil
    end

    -- Everything past here is a plain channel, and every plain key in the
    -- catalog IS its own chat type ("SAY", "RAID", "GUILD"). AUTO, SELF and
    -- WHISPER are the only three that are not, and all three answered above.
    local row = channelRow(channel)
    return (row and row.chatType) or channel, nil
end

--- Put a set of chat lines where the player asked for them.
---
--- SELF goes through NS.Print, which is the addon's prefixed chat printer and
--- reaches nobody else. Everything else goes through SendChatMessage one line at
--- a time — the API's 255-byte ceiling is per message, and no line built above
--- comes close, because every field in one is a formatted number or a player
--- name.
---
--- Falls back to printing when the client has no SendChatMessage at all (the
--- headless harness does not define one), so a test of the caller does not need
--- a stub to avoid an error.
---
--- @param lines table|nil     array of strings
--- @param channel string|nil  a key from Const.EXPORT_CHANNELS
--- @param target string|nil   the whisper recipient
--- @return boolean  whether anything was emitted
function Export.Send(lines, channel, target)
    if type(lines) ~= "table" or #lines == 0 then return false end

    local chatType, to = Export.ResolveChannel(channel, target)
    local send = chatType and _G.SendChatMessage

    -- LOCAL PRINTING IS NOT A SEND and is not throttled: NS.Print writes straight
    -- into the player's own chat frame, reaches nobody, and the server never
    -- sees it. This is also the path a client with no SendChatMessage takes, so
    -- an export there degrades to "printed to yourself" rather than to silence.
    if not send then
        if not NS.Print then return false end
        for _, line in ipairs(lines) do NS.Print(line) end
        return true
    end

    -- ONE MESSAGE A FRAME IS A FLOOD. `Lines: 40` plus the header is 41 calls to
    -- SendChatMessage in a single frame, and the server answers that by dropping
    -- the tail and telling the player they are sending too quickly — so the dump
    -- arrives truncated, at the one moment a truncated ranking is worst.
    --
    -- The first line goes immediately, because a button that appears to do
    -- nothing for a third of a second is a button people press twice. The rest
    -- are staggered. On a client with no C_Timer they all go at once, which is
    -- the old behavior and still better than not sending.
    send(lines[1], chatType, nil, to)

    local after = _G.C_Timer and _G.C_Timer.After
    for i = 2, #lines do
        local line = lines[i]
        if after then
            after(CHAT_STAGGER * (i - 1), function() send(line, chatType, nil, to) end)
        else
            send(line, chatType, nil, to)
        end
    end

    return true
end

-- ---------------------------------------------------------------------------
-- Export modal
-- ---------------------------------------------------------------------------
--
-- Everything below needs a live client. It is built on the FIRST Open and reused
-- forever after: a modal rebuilt per click leaks a frame per click for the life
-- of the session, and frames are never destroyed in WoW.
--
-- Two frames rather than one. The modal picks what to export; the copy window
-- shows the result, at a higher strata so it sits ON TOP of the modal that
-- spawned it. That copy window is a deliberate local copy of the one in
-- LootHistory and the one in LibKa0s' debug log — the third in the collection,
-- recorded as a harvest candidate for the library rather than fixed here.

local MODAL_NAME = "MultiMetersExportWindow"
local COPY_NAME  = "MultiMetersExportCopyWindow"

local ROW_H        = 24

-- The modal's vertical grid, as one table rather than as eight literals scattered
-- through EnsureFrame. It is published on the module (`Export.__geometry`) for the
-- one reason a private constant ever should be: the whisper row's arithmetic is
-- the thing that was wrong — a 20px box at -126 under a warning line at -154 in a
-- frame 236 tall that accounted for neither — and out of game the arithmetic is
-- all there is to check. The modal itself is smoke-tested.
local GEOM = {
    rowHeight         = ROW_H,
    rowGap            = 6,
    metricTop         = 36,
    channelTop        = 66,
    linesTop          = 96,
    whisperTop        = 126,
    warningTop        = 158,
    height            = 236,
}
GEOM.heightWithWhisper = GEOM.height + GEOM.rowHeight + GEOM.rowGap

Export.__geometry = GEOM

local MODAL_WIDTH  = 372
local MODAL_HEIGHT = GEOM.height
local COPY_WIDTH   = 640
local COPY_HEIGHT  = 420
local TITLEBAR_H   = 26
local EDIT_FALLBACK_WIDTH = 590

-- Built lazily, kept forever.
local modal, copyWindow

-- The window an Open was invoked from, and the choices the modal is currently
-- showing. Module-level rather than stored on the frame because the frame is
-- built once and reused for every window: whatever it was showing last time is
-- not what this Open is about.
local invoker

--- Is there a client to build frames on? Asked at CALL time, not captured, so
--- the headless harness loads this file with the whole UI half inert while the
--- pure half above stays reachable.
---
--- @return boolean
local function hasUI()
    return type(CreateFrame) == "function"
end

--- Read a color out of the shared skin, with a fallback per channel.
---
--- NS.SKIN degrades to an EMPTY TABLE rather than nil, so the index is always
--- safe; the fallbacks are for the degraded branch, where every field is absent
--- and a button still has to be visible.
---
--- @param key string
--- @param dr number
--- @param dg number
--- @param db number
--- @param da number
--- @return number, number, number, number
local function skinColor(key, dr, dg, db, da)
    local skin = NS.SKIN
    local c = type(skin) == "table" and skin[key] or nil
    if NS.RGBA then return NS.RGBA(c, dr, dg, db, da) end
    if type(c) ~= "table" then return dr, dg, db, da end
    return c[1] or dr, c[2] or dg, c[3] or db, c[4] or da
end

--- The dragging title bar both frames wear. Identical construction in both, so
--- it is one function: a strip across the top that moves the frame, a centered
--- caption, and the shared close button on the right.
---
--- The caption is stored as `frame.title` because that is the key NS.ApplySkin
--- looks for when it applies the skin's accent color — which is why the whole
--- bar is built BEFORE the skin goes on. Setting the title color here instead
--- would be this file deciding what the addon looks like.
---
--- @param frame table   the frame being titled
--- @param text string   the caption
--- @return table  the title bar
local function makeTitleBar(frame, text)
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetHeight(TITLEBAR_H)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function() frame:StartMoving() end)
    bar:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)

    local caption = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    caption:SetPoint("CENTER")
    caption:SetText(text)
    frame.title = caption

    -- Two guards, not one: the helper may be absent on a degraded install, and
    -- it answers nil on a client with no CreateFrame. Anchoring is ours because
    -- the library hands the button back unanchored on purpose.
    if NS.MakeCloseButton then
        local close = NS.MakeCloseButton(bar, function() frame:Hide() end)
        if close then close:SetPoint("RIGHT", bar, "RIGHT", -6, 0) end
        frame.closeButton = close
    end

    return bar
end

--- A flat button in the addon's own colors.
---
--- The colors come out of NS.SKIN rather than being restated as literals here.
--- A hand-copied palette is a palette that drifts the first time the skin
--- changes, and it drifts silently — the button just stops matching.
---
--- @param parent table
--- @param text string
--- @param onClick function
--- @param icon string  optional. A LibKa0s-Media icon name drawn to the left of the label.
--- @return table  the button, with `.text` for later relabelling
local function makeButton(parent, text, onClick, icon)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetHeight(ROW_H)

    if button.SetBackdrop then
        button:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
            insets   = { left = 1, right = 1, top = 1, bottom = 1 },
        })
        button:SetBackdropColor(skinColor("bg", 0.1, 0.1, 0.12, 0.9))
        button:SetBackdropBorderColor(skinColor("innerBorder", 0.24, 0.24, 0.27, 0.9))
    end

    -- THE ICON IS BESIDE THE LABEL, NEVER INSTEAD OF IT. These two buttons are the
    -- only irreversible-ish things in the modal -- one opens a copy window, the
    -- other writes to a chat channel other people read -- and a mark alone would
    -- make "which one sends to guild?" a question answered by hovering. The label
    -- stays centred whether or not the art resolves, so a missing icon leaves the
    -- button exactly as it was rather than off-centre.
    local path = icon and NS.Icon and NS.Icon(icon)
    if path then
        local art = button:CreateTexture(nil, "OVERLAY")
        art:SetPoint("LEFT", button, "LEFT", 10, 0)
        art:SetSize(14, 14)
        art:SetTexture(path)
        art:SetVertexColor(1, 1, 1)
        button.icon = art
    end

    local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("CENTER")
    label:SetText(text)
    button.text = label

    button:SetScript("OnEnter", function()
        if button:IsEnabled() then label:SetTextColor(skinColor("title", 1, 0.82, 0)) end
    end)
    button:SetScript("OnLeave", function()
        label:SetTextColor(button:IsEnabled() and 1 or 0.4,
                           button:IsEnabled() and 1 or 0.4,
                           button:IsEnabled() and 1 or 0.4)
    end)
    button:SetScript("OnClick", onClick)

    return button
end

--- Grey a button out, or bring it back.
---
--- Both halves matter. The Disable is what makes the click do nothing; the color
--- is what tells the player why nothing happened before they click it a second
--- time.
---
--- @param button table|nil
--- @param enabled boolean
local function setEnabled(button, enabled)
    if not button then return end
    if enabled then
        button:Enable()
        if button.text then button.text:SetTextColor(1, 1, 1) end
    else
        button:Disable()
        if button.text then button.text:SetTextColor(0.4, 0.4, 0.4) end
    end
end

--- Put a frame over the meter window it was opened from.
---
--- Anchored to the window's ANCHOR, never to its visible frame. The visible
--- frame has held secret meter values, which makes its position data secret and
--- propagates that to anything anchored to it (rule R3); the anchor is the bare
--- invisible frame that exists precisely so there is something upstream of every
--- value to hang geometry off. Nothing is read back either way — SetPoint only
--- writes — but anchoring to the anchor keeps this frame outside the secret
--- graph entirely.
---
--- Re-applied on every open rather than once at build time, so the modal lands
--- over the window wherever the player has since dragged it.
---
--- @param frame table
--- @param win table|nil
local function centerOnWindow(frame, win)
    frame:ClearAllPoints()
    local target = type(win) == "table" and win.anchor or nil
    if target and target.IsShown and target:IsShown() then
        frame:SetPoint("CENTER", target, "CENTER", 0, 0)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

--- Build the copy window, once.
---
--- @return table|nil  the frame, or nil with no client
local function EnsureCopyFrame()
    if copyWindow then return copyWindow end
    if not hasUI() then return nil end

    copyWindow = CreateFrame("Frame", COPY_NAME, UIParent, "BackdropTemplate")
    copyWindow:SetSize(COPY_WIDTH, COPY_HEIGHT)
    copyWindow:SetPoint("CENTER")
    -- FULLSCREEN so it sits above the DIALOG-strata modal that opened it. The
    -- modal stays visible underneath, which is what makes "copy this, then pick
    -- a different metric" one trip rather than two.
    copyWindow:SetFrameStrata("FULLSCREEN")
    copyWindow:EnableMouse(true)
    copyWindow:SetMovable(true)
    copyWindow:SetClampedToScreen(true)

    makeTitleBar(copyWindow, L["Export"] .. EM_DASH .. L["Ctrl+C, then Esc"])

    local scroll = CreateFrame("ScrollFrame", nil, copyWindow, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 8, -30)
    scroll:SetPoint("BOTTOMRIGHT", -28, 10)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    -- The bundled monospace face, by PATH — the LibSharedMedia name is a
    -- different string and SetFont does not accept it. A CSV is columns of
    -- digits and only lines up in a fixed-width font.
    edit:SetFont(Const.FONT_MONO, 10, "")
    edit:SetAutoFocus(false)
    edit:SetWidth(EDIT_FALLBACK_WIDTH)
    edit:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        copyWindow:Hide()
    end)
    scroll:SetScrollChild(edit)
    copyWindow.scroll, copyWindow.edit = scroll, edit

    NS.ApplySkin(copyWindow)
    -- Denser than the shared skin's 0.92. This frame is a wall of small
    -- monospace text and the world behind it bleeding through costs legibility
    -- in a way it does not on a frame showing four controls.
    if copyWindow.SetBackdropColor then
        copyWindow:SetBackdropColor(0.06, 0.06, 0.08, 0.95)
    end

    copyWindow:Hide()

    -- By NAME, type-guarded: UISpecialFrames is a list of global frame names and
    -- the table itself is not guaranteed to exist outside a real client.
    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, COPY_NAME)
    end

    return copyWindow
end

--- Show text in the copy window, selected and ready for Ctrl+C.
---
--- The order is load-bearing: width, then text, then cursor to the top, then
--- show, then focus, then highlight. Highlighting before the frame is shown
--- selects nothing, and focusing before the text is set leaves the cursor
--- wherever the last export left it.
---
--- The `scroll:GetWidth()` read-back deserves a note, because reading geometry
--- off a frame is otherwise forbidden here (rule R3). It is legal precisely
--- because this frame can never hold a meter value: its EditBox holds a plain
--- CSV string, produced by a serializer that refuses to run at all while values
--- can be secret. The fallback covers the first open, where the scroll frame has
--- not been laid out yet and answers 0.
---
--- @param text string
local function showCopy(text)
    local frame = EnsureCopyFrame()
    if not frame then return end

    centerOnWindow(frame, invoker)

    local width = frame.scroll:GetWidth()
    frame.edit:SetWidth((type(width) == "number" and width > 0) and width or EDIT_FALLBACK_WIDTH)
    frame.edit:SetText(text)
    frame.edit:SetCursorPosition(0)
    frame:Show()
    frame.edit:SetFocus()
    frame.edit:HighlightText()
end

-- ---------------------------------------------------------------------------
-- The modal's three selectors
-- ---------------------------------------------------------------------------
--
-- LibKa0s-Widgets-1.0 dropdowns, and this REVERSES what this file used to argue.
-- The old reasoning was that a dropdown of our own would be a second menu
-- vocabulary to keep in step with Blizzard's, so these were plain buttons opening
-- a MenuUtil context menu — the mechanism the window header's segment selector
-- still uses.
--
-- What changed is whose dropdown it is. It is not ours: it is the collection's,
-- shared with Bank Ledger's filter bar and specified by a suite in the library's
-- own repo. Against that, MenuUtil is the second vocabulary — a menu with
-- Blizzard's gold title and no selected-row mark, dropped from a button wearing
-- this addon's flat skin.
--
-- The header's segment selector is deliberately NOT converted here. It is a
-- different control in a different frame and its own change.

--- The label for a stat key, localized at the use site.
--- @param statKey string|nil
--- @return string
local function metricLabel(statKey)
    if statKey == nil then return L["Unknown"] end
    local stat = Const.STAT_BY_KEY[statKey]
    if not stat then return L["Unknown"] end
    return L[stat.label] or stat.label
end

--- Which stat the chat dump actually ranks by, right now.
---
--- The stored choice, when the catalog still answers for it. It always does on a
--- profile this build wrote: Export.Open SEEDS the invoking window's sort column
--- on the way in, so the selector shows a real stat before anyone has touched it.
---
--- The two fallbacks below are for the profiles that predate that. `""` was once
--- a deliberate choice meaning "match whichever column the window is sorted by",
--- and a build that offered a stat this one dropped leaves a key the catalog has
--- never heard of. Both read as unset, both land on the window's own column, and
--- neither needs a migration step — which is why there is not one.
---
--- Public and window-taking rather than a local reading the modal's `invoker`,
--- because a rule this easy to get wrong belongs where the harness can reach it;
--- the UI passes nothing and gets the window it was opened from.
---
--- @param win table|nil  a Window instance or config; the invoking window if nil
--- @return string  a key that Const.STAT_BY_KEY answers for
function Export.ResolveMetric(win)
    if win == Export then win = nil end

    local stored = readExport("metric", nil)
    if stored ~= nil and Const.STAT_BY_KEY[stored] then return stored end

    local data = cfgOf(win or invoker).data or {}
    local sortColumn = data.sortColumn
    if sortColumn and Const.STAT_BY_KEY[sortColumn] then return sortColumn end
    return Const.STATS[1].key
end

--- The label for a channel key, localized at the use site.
--- @param key string|nil
--- @return string
local function channelLabel(key)
    local row = channelRow(key)
    if row and row.label then return L[row.label] or row.label end
    -- No catalog (or a stored key it no longer lists): show the key itself
    -- rather than "Unknown", because the key is what the player will read back
    -- in the settings panel.
    return tostring(key)
end

--- Re-read every remembered choice and repaint the modal from it.
---
--- One function rather than a repaint at each write site: the whisper box
--- appearing, the two action buttons greying out and the three labels changing
--- are all one question — "what does the profile say now" — and splitting it is
--- how a modal ends up showing a channel it is not going to send on.
local function refreshModal()
    if not modal then return end

    local available, reason = Export.Available()
    local channel = readExport("channel", "SELF")

    -- Shows the RESOLVED stat even when the stored choice is "match the window",
    -- because the question the player is asking of this button is "what will it
    -- print", not "what is in my profile".
    modal.metricDD:SetValue(Export.ResolveMetric(),
        L["Metric: %s"]:format(metricLabel(Export.ResolveMetric())))
    modal.channelDD:SetValue(channel, L["Channel: %s"]:format(channelLabel(channel)))
    local lines = readExport("lines", 5)
    modal.linesDD:SetValue(lines, L["Lines: %s"]:format(tostring(lines)))

    local whispering = channel == "WHISPER"
    if whispering then
        modal.whisperBox:SetText(readExport("whisperTo", "") or "")
    end
    modal.whisperRow:SetShown(whispering)

    local warningTop = GEOM.warningTop + (whispering and (GEOM.rowHeight + GEOM.rowGap) or 0)
    modal.warning:ClearAllPoints()
    modal.warning:SetPoint("TOPLEFT", 16, -warningTop)
    modal.warning:SetPoint("TOPRIGHT", -16, -warningTop)
    modal:SetHeight(whispering and GEOM.heightWithWhisper or GEOM.height)

    modal.warning:SetText(available and "" or (reason or ""))
    setEnabled(modal.csvButton, available)
    setEnabled(modal.chatButton, available)
end

--- Store a choice and repaint.
--- @param key string
--- @param value any
local function chooseExport(key, value)
    writeExport(key, value)
    refreshModal()
end

--- The Metric selector's options: the catalog, in catalog order.
--- @return table
local function metricOptions()
    local out = {}
    for i, stat in ipairs(Const.STATS) do
        out[i] = { value = stat.key, label = L[stat.label] or stat.label }
    end
    return out
end

--- The Channel selector's options.
---
--- The catalog is core/Constants.lua's and only core/Constants.lua's. Restating
--- the channel list here would be two lists to keep in step, and the settings
--- panel reads the same one.
--- @return table
local function channelOptions()
    local out = {}
    for i, row in ipairs(Const.EXPORT_CHANNELS or {}) do
        out[i] = { value = row.key, label = L[row.label] or row.label }
    end
    return out
end

--- The Lines selector's options.
--- @return table
local function linesOptions()
    local out = {}
    for i, count in ipairs(LINE_CHOICES) do
        out[i] = { value = count, label = tostring(count) }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- The two actions
-- ---------------------------------------------------------------------------

--- Serialize the invoking window's segment and show it for copying.
---
--- The availability check is repeated here, at the click, and that repetition is
--- the point: the modal may have been opened out of combat and clicked ten
--- seconds into a pull, and the greyed-out button is a hint rather than a
--- guarantee.
local function onExportCsv()
    local available, reason = Export.Available()
    if not available then
        if NS.Print then NS.Print(reason) end
        refreshModal()
        return
    end

    local result = Export.Build(invoker)
    -- SAYING SO, rather than a button that swallows the click. A window showing
    -- "Waiting for combat data" has nothing to serialize, and a dialog that
    -- answers a press with nothing at all reads as broken rather than as empty.
    if not result or #result == 0 then
        if NS.Print then NS.Print(L["There is nothing to export."]) end
        return
    end
    showCopy((Export.CSV(result, Export.SessionLabel(invoker))))
end

--- Rank the chosen metric and put it where the player asked.
local function onPrintToChat()
    local available, reason = Export.Available()
    if not available then
        if NS.Print then NS.Print(reason) end
        refreshModal()
        return
    end

    -- A whisper with nobody named resolves to "keep it to yourself" inside
    -- ResolveChannel, which is the safe answer but a silent one — the player
    -- asked for it to reach somebody. Caught here, where there is still a name
    -- box on screen to point at.
    local channel = readExport("channel", "SELF")
    local whisperTo = readExport("whisperTo", "")
    if channel == "WHISPER" and tostring(whisperTo):match("^%s*$") then
        if NS.Print then NS.Print(L["Enter a name to whisper to."]) end
        return
    end

    local statKey = Export.ResolveMetric()
    -- Built with the metric as the SORT COLUMN, so "top 5 healing" is the top
    -- five healers rather than the top five damage dealers listed with their
    -- healing beside them.
    local result = Export.Build(invoker, statKey)
    if not result or #result == 0 then
        if NS.Print then NS.Print(L["There is nothing to export."]) end
        return
    end

    local lines = Export.ChatLines(result, statKey, readExport("lines", 5),
        Export.SessionLabel(invoker))
    Export.Send(lines, channel, whisperTo)

    -- Confirmed only for a send that LEFT this client. On SELF the lines are
    -- themselves the confirmation, sitting in the chat frame, and a summary under
    -- them would be one line of noise per export.
    if channel ~= "SELF" and NS.Print then
        -- The header line is not a ranked row, so it is not counted.
        NS.Print(L["Exported %d rows to chat."]:format(math.max(#lines - 1, 0)))
    end
end

--- Build the modal, once.
---
--- @return table|nil  the frame, or nil with no client
local function EnsureFrame()
    if modal then return modal end
    if not hasUI() then return nil end

    modal = CreateFrame("Frame", MODAL_NAME, UIParent, "BackdropTemplate")
    modal:SetSize(MODAL_WIDTH, MODAL_HEIGHT)
    modal:SetPoint("CENTER")
    -- DIALOG, which is BELOW the FULLSCREEN strata the shared dropdown menu puts
    -- its click-catcher on (FULLSCREEN_DIALOG for the menu itself, FULLSCREEN for
    -- the catcher beneath it — LibKa0s-Widgets-1.0's own popup, one instance
    -- shared by every dropdown in the process). That ordering is what lets a
    -- click outside an open selector menu close the menu instead of landing on
    -- the modal — and the copy window, also FULLSCREEN, still opens above this.
    modal:SetFrameStrata("DIALOG")
    modal:EnableMouse(true)
    modal:SetMovable(true)
    modal:SetClampedToScreen(true)

    makeTitleBar(modal, L["Export"])

    local metricDD = W.Dropdown(modal, MODAL_WIDTH - 32, { chevron = NS.Icon("chevron-down") })
    metricDD:SetHeight(GEOM.rowHeight)
    metricDD:SetPoint("TOPLEFT", 16, -GEOM.metricTop)
    metricDD:SetPoint("TOPRIGHT", -16, -GEOM.metricTop)
    metricDD:SetOptions(metricOptions())
    metricDD.onSelect = function(v) chooseExport("metric", v) end

    local channelDD = W.Dropdown(modal, MODAL_WIDTH - 32, { chevron = NS.Icon("chevron-down") })
    channelDD:SetHeight(GEOM.rowHeight)
    channelDD:SetPoint("TOPLEFT", 16, -GEOM.channelTop)
    channelDD:SetPoint("TOPRIGHT", -16, -GEOM.channelTop)
    channelDD:SetOptions(channelOptions())
    channelDD.onSelect = function(v) chooseExport("channel", v) end

    local linesDD = W.Dropdown(modal, MODAL_WIDTH - 32, { chevron = NS.Icon("chevron-down") })
    linesDD:SetHeight(GEOM.rowHeight)
    linesDD:SetPoint("TOPLEFT", 16, -GEOM.linesTop)
    linesDD:SetPoint("TOPRIGHT", -16, -GEOM.linesTop)
    linesDD:SetOptions(linesOptions())
    linesDD.onSelect = function(v) chooseExport("lines", v) end

    -- Shown only while the channel is WHISPER. Hidden rather than disabled: a
    -- greyed-out name box on a raid-channel export is a control asking to be
    -- filled in for no reason.
    --
    -- NOT InputBoxTemplate, and that is the fix rather than a preference. The
    -- template carries its own rounded, gold-edged art and its own text insets;
    -- beside three flat selectors it read as a control borrowed from another
    -- addon, and its insets are what clipped the name. This is the same backdrop
    -- the selectors above it wear, so the four rows are one column.
    local whisperRow = CreateFrame("Frame", nil, modal, "BackdropTemplate")
    whisperRow:SetHeight(GEOM.rowHeight)
    whisperRow:SetPoint("TOPLEFT", 16, -GEOM.whisperTop)
    whisperRow:SetPoint("TOPRIGHT", -16, -GEOM.whisperTop)
    if whisperRow.SetBackdrop then
        whisperRow:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
            insets   = { left = 1, right = 1, top = 1, bottom = 1 },
        })
        whisperRow:SetBackdropColor(skinColor("bg", 0.1, 0.1, 0.12, 0.9))
        whisperRow:SetBackdropBorderColor(skinColor("innerBorder", 0.24, 0.24, 0.27, 0.9))
    end

    -- The caption INSIDE the row, as a prefix, so this reads "Whisper to: …" in
    -- the same shape as "Metric: …" above it. It was a separate FontString above
    -- the box, in 12px of room the old layout did not actually have.
    local whisperCaption = whisperRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    whisperCaption:SetPoint("LEFT", 8, 0)
    whisperCaption:SetText(L["Whisper to:"] .. " ")
    whisperCaption:SetTextColor(skinColor("title", 1, 0.82, 0))

    local whisperBox = CreateFrame("EditBox", nil, whisperRow)
    whisperBox:SetPoint("LEFT", whisperCaption, "RIGHT", 2, 0)
    whisperBox:SetPoint("RIGHT", -8, 0)
    whisperBox:SetPoint("TOP", 0, 0)
    whisperBox:SetPoint("BOTTOM", 0, 0)
    whisperBox:SetFontObject("GameFontHighlightSmall")
    whisperBox:SetAutoFocus(false)
    whisperBox:SetScript("OnEnterPressed", function(self)
        chooseExport("whisperTo", self:GetText() or "")
        self:ClearFocus()
    end)
    -- Stored on focus loss as well as on Enter: nobody expects to have to press
    -- Enter in a name box before clicking the button right below it.
    whisperBox:SetScript("OnEditFocusLost", function(self)
        writeExport("whisperTo", self:GetText() or "")
    end)
    whisperBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local warning = modal:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    warning:SetPoint("TOPLEFT", 16, -GEOM.warningTop)
    warning:SetPoint("TOPRIGHT", -16, -GEOM.warningTop)
    warning:SetJustifyH("CENTER")
    warning:SetWordWrap(true)
    -- The one hand-set color in this file, and it is a state rather than a style:
    -- the sentence is a refusal, and the skin has no "this is refused" accent.
    warning:SetTextColor(0.9, 0.25, 0.25)

    -- A spreadsheet for the CSV and a speech bubble for chat: the two icons say
    -- WHERE the export lands, which is the only difference between these buttons.
    local csvButton = makeButton(modal, L["Export to CSV"], onExportCsv, "spreadsheet")
    csvButton:SetWidth(160)
    csvButton:SetPoint("BOTTOMLEFT", 16, 14)

    local chatButton = makeButton(modal, L["Print to Chat"], onPrintToChat, "chat")
    chatButton:SetWidth(160)
    chatButton:SetPoint("BOTTOMRIGHT", -16, 14)

    modal.metricDD   = metricDD
    modal.channelDD  = channelDD
    modal.linesDD    = linesDD
    modal.whisperBox = whisperBox
    modal.whisperRow = whisperRow
    modal.warning    = warning
    modal.csvButton  = csvButton
    modal.chatButton = chatButton

    NS.ApplySkin(modal)
    modal:Hide()

    -- The modal is in UISpecialFrames (below), so Escape hides it directly —
    -- never through onHide/a click handler this file controls. An open Metric,
    -- Channel or Lines menu is the shared LibKa0s-Widgets-1.0 popup: a
    -- process-wide singleton parented to UIParent at FULLSCREEN_DIALOG, not to
    -- this modal, so the modal's own Hide() does not reach it (see the
    -- FrameStrata comment above and Widgets version-2-docs.md, "Behavior a host
    -- must know"). Without this, Escape would leave the menu orphaned above the
    -- game with the modal that owned it already gone. CloseMenu() is a safe
    -- no-op when no dropdown here has ever opened the menu, or when it is
    -- already closed, so this needs no extra guard beyond W itself, which is
    -- already resolved as a file-local and nil on a degraded load.
    if W then
        modal:SetScript("OnHide", function() W.CloseMenu() end)
    end

    -- THE RESTRICTION ARRIVES WHILE THE MODAL IS OPEN, and that is the ordinary
    -- case rather than the exotic one: a player opens this between pulls and the
    -- tank pulls. Nothing else on screen would repaint it, so the two action
    -- buttons would sit lit above a serializer that has started refusing, and
    -- the warning line would stay blank until a click explained it.
    --
    -- The clicks re-check regardless (onExportCsv / onPrintToChat refuse on
    -- their own). This subscription is what makes the modal SAY so first, which
    -- is the difference between a dialog that looks broken and one that reads as
    -- the game's rule being enforced.
    --
    -- One private bus target, taken once with the frame it repaints, exactly as
    -- each window takes its own (modules/Window.lua). Nil on a degraded load
    -- with no AceEvent, where a modal that does not repaint is a cost worth
    -- paying over a modal that does not open.
    local bus = NS.NewBusTarget and NS.NewBusTarget()
    if bus and MSG then
        bus:RegisterMessage(MSG.RESTRICTION_CHANGED, function() refreshModal() end)
    end
    modal.bus = bus

    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, MODAL_NAME)
    end

    return modal
end

--- Show the export modal for one window.
---
--- Callable as `NS.Export:Open(win)` (what the header glyph does) and as
--- `NS.Export.Open(cfg)` (what the slash verb does). The sniff is the same one
--- Aggregator.Build uses, and it exists for the same reason: two call sites
--- written by different hands, neither of which should have to care.
---
--- Refuses to open at all while restricted, rather than opening a modal with two
--- dead buttons — the sentence in chat is the useful half of that interaction.
---
--- @param a table|nil  Export, or a Window instance / config
--- @param b table|nil  a Window instance / config when called with a colon
--- @return table|nil  the modal, or nil when it did not open
function Export.Open(a, b)
    local win = (a == Export) and b or a

    local available, reason = Export.Available()
    if not available then
        if NS.Print then NS.Print(reason) end
        return nil
    end

    invoker = win

    -- SPEC §10. No widget, no modal. Three labels that open nothing look like a
    -- broken addon; a sentence looks like a missing library, which is what it is.
    -- Same shape as the combat refusal above, for the same reason.
    if not W then
        if NS.Print then NS.Print(L["The export window needs LibKa0s."]) end
        return nil
    end

    local frame = EnsureFrame()
    if not frame then return nil end

    -- SEEDED, and this reverses a decision this file used to argue for. The old
    -- shape stored "" — "match whichever column the window is sorted by" — and
    -- resolved it fresh at every use, which meant the Metric button showed a
    -- label naming a rule instead of naming a stat. The rule was right and
    -- unreadable; seeding keeps the behaviour and puts the answer in the control.
    --
    -- It is also what makes the settings panel's "Default metric" row removable:
    -- a preference every open overwrites is a preference in name only.
    --
    -- Only from a column the catalog answers for. A window that has never been
    -- sorted leaves whatever was chosen last time, which is the better of the
    -- two wrong answers.
    local seed = (cfgOf(win).data or {}).sortColumn
    if seed and Const.STAT_BY_KEY[seed] then writeExport("metric", seed) end

    refreshModal()
    centerOnWindow(frame, win)
    frame:Show()

    return frame
end
