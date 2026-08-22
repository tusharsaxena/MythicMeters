-- core/Diagnostics.lua
--
-- `/mm debug diag` — what the CLIENT actually reports, printed as facts.
--
-- ---------------------------------------------------------------------------
-- WHY THIS FILE EXISTS
-- ---------------------------------------------------------------------------
--
-- Three display bugs in a row were caused by the same thing: something was
-- assumed about the running client at authoring time and never checked against
-- it. Texture paths that do not exist draw nothing and raise nothing. Unicode
-- glyphs the game font lacks draw a replacement box. `SetBreakpoints` accepts an
-- array it then ignores, so a `pcall` that does not throw looks like success.
--
-- Every one of those was invisible to the test suite, because a headless harness
-- can only be as truthful as the person who wrote it, and each was diagnosed by
-- guessing at a screenshot and shipping another guess. This file replaces that
-- loop with one command whose whole job is to answer "what is really there".
--
-- ---------------------------------------------------------------------------
-- WHAT IT MAY AND MAY NOT DO
-- ---------------------------------------------------------------------------
--
-- It reports on WIDGETS and on APIs, never on meter values. Every number printed
-- below is either a plain number this addon produced, a boolean, or a string
-- naming a thing — and a cell's stored figure is described (`present` / `absent`)
-- rather than rendered, because rendering it would be fine and INSPECTING it to
-- describe it would not (rule R1).
--
-- Geometry IS read here, off cells that have held secret values, which the rest
-- of the addon may never do (rule R3). That is deliberate and is confined to this
-- file: `pcall` wraps every such read, and a refusal is itself the answer worth
-- printing — "this frame's geometry is secret" is exactly the kind of fact a
-- layout bug turns on. Nothing here feeds a value back into the render path.
--
-- TOC POSITION: last in the core block. It reaches modules at CALL time and owns
-- no state, so nothing depends on where it loads.

local addonName, NS = ...

local Diagnostics = {}
NS.Diagnostics = Diagnostics

-- The atlas candidates modules/Window.lua draws its header from, restated here
-- as a LIST TO PROBE rather than imported. The point of the probe is to find out
-- which names this client has; importing the same table would report on the
-- addon's opinion instead of on the client's, and reporting on our own opinion is
-- how we got here.
local ATLAS_PROBES = {
    "common-dropdown-icon-sortdown", "common-dropdown-icon-sortup",
    "auctionhouse-ui-sortarrow",
    "common-icon-settings", "GM-icon-settings",
    "common-icon-lock", "common-icon-unlock", "Garr_LockedBuilding",
    "UI-HUD-MicroMenu-GameMenu-Up",
    -- The export glyph's candidates. NONE of them has been confirmed on a live
    -- client, which is the entire reason they are in this list: modules/Window.lua
    -- draws the ASCII `>` until one of them answers yes here, and this report is
    -- the only way anybody finds out which.
    "poi-scrollofresonance", "communities-icon-chat", "UI-HUD-MicroMenu-Questlog-Up",
}

-- Values chosen so each one lands on a different rung of the breakpoint ladder in
-- modules/Format.lua. What they SHOULD render as is printed beside what they DO,
-- so a mismatch is visible without anybody having to remember the ladder.
-- WHAT THE CURRENT LADDER RENDERS, not what an earlier one did.
--
-- These wants were written against the three-significant-figure ladder that
-- modules/Format.lua has since retired on purpose — two rungs per suffix made a
-- column change shape partway down itself ("4.75K" above "10.2K"), so the ladder
-- is now ONE DECIMAL AT EVERY MAGNITUDE and 1410000 is meant to read "1.4M".
-- The stale wants outlived it, and a live report duly flagged three correct
-- figures as wrong — a diagnostic accusing the code of matching its own design.
--
-- 475000 is the one that looks off and is not: the ladder asks for a decimal, the
-- live client trims a trailing ".0" and renders "475K", and the offline formatter
-- keeps it. Neither is a ladder failure, so the comparison below normalizes that
-- one difference away rather than reporting a mark a reader can do nothing with.
-- Anything that changes BREAKPOINTS changes this table with it.
local NUMBER_PROBES = {
    { value = 470.66666666667, want = "470"   },
    { value = 4750,            want = "4.7K"  },
    { value = 47500,           want = "47.5K" },
    { value = 475000,          want = "475.0K" },
    { value = 1410000,         want = "1.4M"  },
    { value = 12400000,        want = "12.4M" },
}

--- Where this run's report goes. Set by Report(), cleared when it finishes.
---
--- The console is the right home: a diagnostic is forty lines that a player has
--- to hand back verbatim, and the console already has the buffer, the scrollback
--- and the copy window that a chat frame does not. Chat also TRUNCATES nothing
--- but interleaves everything, so a report pasted out of it arrives shuffled
--- with combat spam.
local emit = nil

--- Print one line, to the console when there is one and to chat otherwise.
---
--- The fallback is not decoration. With LibKa0s absent, `NS.DebugLog` is a stub
--- whose `Add` is a NO-OP — so routing there unconditionally would make the one
--- command a player runs when something is wrong print absolutely nothing, on
--- exactly the broken install where they need it most.
local function out(line)
    if emit then emit(line) return end
    if NS.Print then NS.Print(line) else print(line) end
end

local SECRET = "<secret>"


--- Whether a value can be put in a line at all.
---
--- Defers to the namespace's own concat probe where it exists (core/CoreSetup.lua)
--- so this file inherits one definition of "safe to print" rather than growing a
--- second. Rule R2 is intact: nothing here asks what the value IS.
---
--- @param v any
--- @return boolean
local function safe(v)
    local probeFn = NS.IsConcatSafe
    if probeFn then return probeFn(v) end
    return (pcall(table.concat, { v }))
end

--- A value rendered for a diagnostic line, or the sentinel when it may not be.
---
--- @param v any
--- @return string
local function shown(v)
    if v == nil then return "nil" end
    if type(v) == "boolean" then return tostring(v) end
    if not safe(v) then return SECRET end
    return tostring(v)
end

--- `pcall` a getter and describe the outcome rather than returning it.
---
--- A refusal is the interesting answer: geometry read off a frame that has held a
--- secret is exactly what rule R3 forbids everywhere else, and "this raised" tells
--- a reader the frame is in the secret set.
local function probe(fn, ...)
    local ok, value = pcall(fn, ...)
    if not ok then return "<refused>" end
    if value == nil then return "nil" end
    -- A SECRET RESULT IS DESCRIBED, NEVER FORMATTED. string.format does not
    -- raise on one, it propagates — the whole formatted line comes back secret,
    -- and the console renders the ENTIRE row as `<secret>`. That is how the
    -- three most informative lines in this report (the header's session line,
    -- the sort column's cell, the first enemy) came back carrying nothing at all
    -- in a pull, which is the one moment the report exists for. One field goes
    -- dark now, and the plain fields beside it survive.
    if not safe(value) then return SECRET end
    if type(value) == "number" then return string.format("%.1f", value) end
    return tostring(value)
end

-- ---------------------------------------------------------------------------
-- Sections
-- ---------------------------------------------------------------------------

local function reportAtlases()
    out("|cff00ff00-- atlases --|r")
    local api = _G.C_Texture
    if not (api and api.GetAtlasInfo) then
        out("  C_Texture.GetAtlasInfo: ABSENT (every atlas falls back to ASCII)")
        return
    end
    for _, name in ipairs(ATLAS_PROBES) do
        local ok, info = pcall(api.GetAtlasInfo, name)
        out(string.format("  %-38s %s", name, (ok and info) and "yes" or "no"))
    end
end

local function reportFormatter()
    out("|cff00ff00-- number formatting --|r")

    local util = _G.C_StringUtil
    out("  C_StringUtil:                      " .. (util and "yes" or "no"))
    if util then
        out("  CreateAbbreviatedNumberFormatter:  "
            .. (util.CreateAbbreviatedNumberFormatter and "yes" or "no"))
        out("  GetDefaultAbbreviationBreakpoints: "
            .. (util.GetDefaultAbbreviationBreakpoints and "yes" or "no"))
    end

    local F = NS.Numbers or NS.NumberFormat
    if not (F and F.Number) then
        out("  the addon's formatter is unreachable")
        return
    end

    -- Through the addon's own path, so what is printed is what a cell would draw.
    -- "475.0K" and "475K" are the same ladder rendered by two formatters that
    -- disagree about a trailing zero — the live client drops it, the offline one
    -- keeps it. Only the digits that carry magnitude are compared, so a mark in
    -- this column always means something the reader can act on.
    local function trimmed(text)
        return (text:gsub("%.0(%a*)$", "%1"))
    end

    for _, p in ipairs(NUMBER_PROBES) do
        local got = tostring(F.Number(p.value))
        local mark = (trimmed(got) == trimmed(p.want)) and ""
            or "   <-- expected " .. p.want
        out(string.format("  %-16s -> %-10s%s", tostring(p.value), got, mark))
    end
end

--- One line per cell in the first drawn row of the first window.
---
--- THE FIGURE IS NOT PRINTED, only whether there is one. Rendering it would be
--- legal and asking what it is would not, and this file is not core/Secrets.lua.
local function reportCells()
    out("|cff00ff00-- first row's cells --|r")

    local M = NS.WindowManager
    local inst = M and M.All and M.All()[1]
    if not inst then out("  no window") return end

    local row = inst.pool and inst.pool.active and inst.pool.active[1]
    if not row then out("  no drawn row (is the window showing data?)") return end

    out(string.format("  columns in layout: %d", #inst.layout.columns))
    for _, col in ipairs(inst.layout.columns) do
        local cell = row.cells[col.key]
        if not cell then
            out(string.format("  %-22s NO CELL", col.key))
        else
            local mn, mx = probe(cell.frame.GetMinMaxValues, cell.frame)
            out(string.format(
                "  %-22s showBar=%-5s w=%-6s value=%-8s max=%s/%s secret=%s text=%q",
                col.key,
                tostring(cell.showBar),
                tostring(col.width),
                probe(cell.frame.GetValue, cell.frame),
                tostring(mn), tostring(mx),
                probe(cell.frame.HasSecretValues, cell.frame),
                shown(cell.left:GetText())))
        end
    end
end

local function reportNameColumn()
    out("|cff00ff00-- name column --|r")
    local M = NS.WindowManager
    local inst = M and M.All and M.All()[1]
    if not inst then out("  no window") return end

    local icons = (inst.config.icons or {})
    out(string.format("  width=%d  showIcon=%s size=%s position=%s",
        inst.layout.nameColumn.width,
        tostring(icons.showIcon), tostring(icons.size), tostring(icons.position)))

    local row = inst.pool and inst.pool.active and inst.pool.active[1]
    if row and row.nameCell then
        out(string.format("  text inset=%s  text=%q",
            probe(row.nameCell.left.GetLeft, row.nameCell.left),
            shown(row.nameCell.left:GetText())))
    end
end

--- Why the window is or is not on screen — the show ladder's own answer.
---
--- Added because "changing a setting closes my window" turned out to be the
--- ladder correctly refusing a context the player had not noticed, and there was
--- no way to see that from outside.
local function reportVisibility()
    out("|cff00ff00-- visibility --|r")
    local M = NS.WindowManager
    local inst = M and M.All and M.All()[1]
    if not inst then out("  no window") return end

    local v = inst.config.visibility or {}
    out(string.format("  dungeon=%s raid=%s arena=%s bg=%s world=%s",
        tostring(v.dungeon), tostring(v.raid), tostring(v.arena),
        tostring(v.battleground), tostring(v.world)))
    out(string.format("  hideWhenSolo=%s hideInVehicle=%s",
        tostring(v.hideWhenSolo), tostring(v.hideInVehicle)))

    local inInstance, kind = false, "none"
    if _G.IsInInstance then inInstance, kind = _G.IsInInstance() end
    out(string.format("  context: inInstance=%s type=%s inGroup=%s testMode=%s",
        tostring(inInstance), tostring(kind),
        tostring(_G.IsInGroup and _G.IsInGroup()),
        tostring(NS.State and NS.State.testMode)))

    local show, reason = true, "?"
    if NS.ShouldShow then show, reason = NS.ShouldShow(inst.config) end
    out(string.format("  ShouldShow -> %s (%s)   shown=%s forcedShow=%s",
        tostring(show), tostring(reason),
        tostring(inst:IsShown()), tostring(inst.forcedShow)))
end

local function reportHeader()
    out("|cff00ff00-- header --|r")
    local M = NS.WindowManager
    local inst = M and M.All and M.All()[1]
    if not inst then out("  no window") return end

    local header = inst.config.header or {}
    out(string.format("  showSessionName=%s showDuration=%s showTotals=%s align=%s",
        tostring(header.showSessionName), tostring(header.showDuration),
        tostring(header.showTotals), tostring(header.align)))
    out(string.format("  title=%q", shown(inst.frame.title:GetText())))
    -- The session line carries the header TOTALS, which are secret for the
    -- whole of a pull. Printed through `shown` the line still says so; printed
    -- through tostring it took the title above it down with it.
    out(string.format("  session line=%q", shown(inst.sessionText:GetText())))

    -- EVERY CONTROL, WALKED OFF THE WINDOW ITSELF. This used to name three
    -- fields -- configButton, lockButton, exportButton -- inside `if button
    -- then`, so when the controls moved to modules/HeaderControls.lua the loop
    -- printed nothing at all: no error, just a diagnostic that had quietly
    -- stopped covering the header. Walking `inst.controls` means a control added
    -- later appears here without anyone remembering to add it.
    local controls = inst.controls
    if not controls then
        out("  header controls: none built")
        return
    end
    for _, key in ipairs({ "close", "minimise", "lock", "settings",
                           "segment", "reset", "export" }) do
        local button = controls[key]
        if not button then
            out(string.format("  %-9s absent", key))
        else
            out(string.format("  %-9s atlas=%s glyph=%q shown=%s alpha=%s",
                key,
                tostring(button.tex and button.tex.GetAtlas and button.tex:GetAtlas()),
                tostring(button.glyph and button.glyph:GetText()),
                tostring(button:IsShown()),
                tostring(button.GetAlpha and button:GetAlpha())))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Death recap — can issue #1's window be built at all?
-- ---------------------------------------------------------------------------
--
-- Issue #1 wants a two-pane Death Recap window: a left pane listing every death
-- in the run, a right pane breaking the selected one down into incoming events.
-- Every `deathRecapID` it needs is already arriving — modules/Provider.lua
-- copies one off each Deaths source row — and this addon does nothing with them
-- but hand ONE to Blizzard's own frame, which answers "Death Recap unavailable".
--
-- Three things about the live client decide whether that window is a reader over
-- `deathRecapID` or a combat-log capture of our own, and every one of them is
-- currently a guess:
--
--   1. does an id resolve for a NON-LOCAL player? Blizzard's recap frame is
--      built around the local player's own deaths.
--   2. does one resolve for a death from EARLIER IN THE RUN, or only the most
--      recent? The whole left pane is past deaths.
--   3. is there a READER for the per-event breakdown at all, or only the
--      frame-opening call this addon already uses?
--
-- Answer them wrong and the feature is a materially larger job than the issue
-- describes. So this section measures instead of guessing: it dumps every id the
-- session holds, asks the client which recap functions it carries, and calls
-- each one against four deliberately chosen ids — the local player's newest and
-- an older one, another player's newest and an older one. What comes back is
-- printed verbatim-ish and NOT interpreted, beyond naming which fork each
-- outcome puts the issue on.
--
-- Rule R1 holds throughout. Every read goes through modules/Provider.lua, no
-- amount is inspected, and a recap payload's fields are rendered through
-- `shown` — which describes a secret rather than asking what it is.

-- How many death rows the dump prints. A raid night can hold dozens and the
-- report is pasted into an issue by hand; twelve is enough to show repeats of
-- one player, which is the shape that matters.
local RECAP_DUMP_LIMIT = 12

-- The four ids worth calling, in the order they are chosen. The labels are the
-- open questions restated as slots: anything that answers `local/newest` and
-- refuses the other three is Blizzard's frame behaviour, and that answer sinks
-- the design as written.
local RECAP_SLOTS = { "local/newest", "local/older", "other/newest", "other/older" }

--- The Deaths column for one session, or nil.
local function deathsColumn(sessionType, sessionID)
    local P = NS.Provider
    if not (P and P.GetColumn) then return nil end
    local column = P:GetColumn(sessionType, "Deaths", sessionID)
    if type(column) ~= "table" then return nil end
    return column
end

--- Which of the four slots a source row belongs in, or nil for a row we already
--- have a slot filled for.
---
--- `isLocalPlayer` is read the way modules/Aggregator.lua reads it — it stays
--- plain under the restriction, which is the whole reason identity survives a
--- pull — but it is vetted first anyway. A row we cannot classify goes in no
--- slot rather than in the wrong one.
---
--- THE BOOLEAN CASE IS CHECKED BEFORE `safe`, exactly as `shown` does it: this
--- file's `safe` is a CONCAT probe, and `table.concat{ false }` raises, so a
--- plain `false` — which is every non-local player — reads as unprintable and
--- would have put the whole `other/*` half of the probe in the "no such death"
--- branch. The two questions this section exists to answer are both on that
--- half.
---
--- @param slots table   label -> source, filled in place
--- @param src table
--- @return string|nil   the label filled, when one was
local function fillRecapSlot(slots, src)
    local isLocal = src.isLocalPlayer
    if type(isLocal) ~= "boolean" and not safe(isLocal) then return nil end
    local mine = (isLocal == true)
    local newest = mine and "local/newest" or "other/newest"
    local older  = mine and "local/older"  or "other/older"
    if slots[newest] == nil then slots[newest] = src return newest end
    if slots[older]  == nil then slots[older]  = src return older  end
    return nil
end

--- Print one death row.
local function reportDeathRow(index, src)
    out(string.format("    [%2d] name=%-14s local=%-5s deathTime=%-8s recap=%s",
        index, shown(src.name), shown(src.isLocalPlayer),
        shown(src.deathTimeSeconds), shown(src.deathRecapID)))
end

--- Dump one session's Deaths column and hand back its sources.
---
--- EVERY ROW, not one per player. The client reports one source row PER DEATH
--- with the same GUID repeated, and modules/Aggregator.lua keeps only the first
--- recap id it sees — which is precisely the discard issue #1 exists to undo. A
--- probe that read the aggregated grid would confirm our own bug back to us.
---
--- @return table|nil sources
local function reportDeathsSession(label, sessionType, sessionID)
    local column = deathsColumn(sessionType, sessionID)
    if not column then
        out(string.format("  -- deaths, %s -- provider unavailable", label))
        return nil
    end

    out(string.format("  -- deaths, %s -- %d rows, reason=%s",
        label, #column.sources, tostring(column.reason)))
    for i = 1, math.min(#column.sources, RECAP_DUMP_LIMIT) do
        reportDeathRow(i, column.sources[i])
    end
    if #column.sources > RECAP_DUMP_LIMIT then
        out(string.format("    ... %d more rows not printed",
            #column.sources - RECAP_DUMP_LIMIT))
    end
    return column.sources
end

--- One table's string-keyed fields, sorted for a stable paste.
--- @return string|nil  nil when the table has no string keys at all
local function describeRecapFields(tbl)
    local keys = {}
    for k in pairs(tbl) do
        if type(k) == "string" then keys[#keys + 1] = k end
    end
    if #keys == 0 then return nil end
    table.sort(keys)

    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = k .. "=" .. shown(tbl[k])
    end
    return "table{ " .. table.concat(parts, ", ") .. " }"
end

--- Describe whatever a reader handed back, without asking what it is.
---
--- THE ARRAY CASE IS THE ONE THAT MATTERS. `GetRecapEvents` returns an ARRAY of
--- event tables, and issue #1's whole right pane is made of their fields — spell,
--- time, amount, HP. Described by string keys alone, which is all the first two
--- rounds of this probe could do, an array prints as `table{}`: the report would
--- find the reader and then say it handed back nothing useful, which is the same
--- wrong answer arriving by a new route.
---
--- The length comes from core/Secrets.lua's counter rather than from `#`, and
--- the walk from SafeIterate: a recap event's fields may be secret mid-pull, and
--- `#` on a secret is the operator rule R1 names outright.
---
--- AN EMPTY ARRAY IS A REAL "NO". `#raw == 0` is how a working addon detects
--- "this id carries no recap", so the second return exists to keep a
--- zero-length reply out of the answered tally — counting it would hand back
--- the green light for a client that refused every id.
---
--- @param value any
--- @return string description, boolean answered
local function describeRecapValue(value)
    if value == nil then return "nil", false end
    if type(value) ~= "table" then return shown(value), true end
    -- NS.Secrets is read at CALL time, not captured at file scope: this file
    -- loads last in the core block and reaches every module the same way.
    local S = NS.Secrets
    if not S or not S.CanAccessTable(value) then return "<inaccessible table>", true end

    local first, count = nil, 0
    S.SafeIterate(value, function(index, entry)
        count = index
        if first == nil and type(entry) == "table"
            and S.CanAccessTable(entry) then first = entry end
    end)

    if count > 0 then
        local shape = first and describeRecapFields(first) or "<entries are not tables>"
        return string.format("array[%d] of %s", count, shape), true
    end

    local fields = describeRecapFields(value)
    if fields then return fields, true end
    return "array[0] — the client has no recap for this id", false
end

--- Call one reader against one id, both ways round, and print both outcomes.
---
--- TWO ARITIES, because nobody knows which the reader takes. Blizzard's own
--- recap UI walks events by index, so `(id)` and `(id, 1)` are both plausible
--- and trying both costs two lines. A refusal on one and an answer on the other
--- IS the shape of the API.
--- @return boolean  whether either call came back with anything at all
local function probeRecapReader(api, recapID)
    local P = NS.Provider
    local path = api.ns .. "." .. api.name
    local answered = false

    -- `~= nil` IS THE ONLY QUESTION ASKED OF THE RESULT, and it is the one
    -- question rule R1 permits of a possibly-secret value: nil-ness, never
    -- truthiness and never a comparison against anything else.
    local function line(label, ok, value)
        if not ok then
            out(string.format("      %s%-8s -> refused: %s", path, label,
                tostring(value)))
            return
        end
        local description, gotSomething = describeRecapValue(value)
        if gotSomething then answered = true end
        out(string.format("      %s%-8s -> %s", path, label, description))
    end

    line("(id)",    P.CallRecap(api.ns, api.name, recapID))
    line("(id, 1)", P.CallRecap(api.ns, api.name, recapID, 1))
    return answered
end

--- The four chosen ids, each put to every reader the client carries.
---
--- @return table answered, number probed  slot labels that got an answer, and
---         how many slots there was actually a death to ask about
local function reportRecapProbes(apis, slots)
    local S = NS.Secrets
    local answered, probed = {}, 0
    for _, label in ipairs(RECAP_SLOTS) do
        local src = slots[label]
        if src == nil then
            out(string.format("    %-13s no such death in this session", label))
        else
            local recapID = src.deathRecapID
            -- THE ID IS GATED BEFORE IT IS PASSED. `deathRecapID` is documented
            -- NeverSecret and the probe still does not bet a raise on it:
            -- forwarding a secret into a client function is the `bad argument
            -- #4` that already shipped once through modules/Targets.lua.
            if not (S and S.IsSafeKey(recapID)) then
                out(string.format("    %-13s id is secret or absent — not called", label))
            else
                probed = probed + 1
                out(string.format("    %-13s id=%s  name=%s", label,
                    tostring(recapID), shown(src.name)))
                for _, api in ipairs(apis) do
                    if probeRecapReader(api, recapID) then
                        if answered[#answered] ~= label then
                            answered[#answered + 1] = label
                        end
                    end
                end
            end
        end
    end
    return answered, probed
end

--- The whole surface of every candidate namespace, unfiltered.
---
--- THE SECTION THAT RESOLVES ROUND ONE'S AMBIGUITY. A walk of a live 12.x client
--- turned up one recap-shaped function and it was a corpse coordinate, which
--- reads as "this client has no reader" and reads equally well as "the walk
--- cannot see this namespace". A filtered list cannot tell those apart. An
--- unfiltered one can: a `C_DeathInfo` with seven ordinary members and no recap
--- function among them is a conclusive no, and one that enumerates as empty or
--- near-empty is a proxy, where the fault is the search.
local function reportRecapSurface()
    local P = NS.Provider
    out("  -- namespace surface (unfiltered) --")
    for _, entry in ipairs(P.RecapMembers()) do
        if not entry.present then
            out(string.format("    %s: not on this client", entry.ns))
        elseif #entry.names == 0 then
            out(string.format("    %s: present, enumerates as EMPTY — a proxy;"
                .. " the walk is blind here", entry.ns))
        else
            out(string.format("    %s: %d members", entry.ns, #entry.names))
            -- Wrapped rather than one per line: a meter namespace runs to a
            -- dozen names and this report is pasted by hand.
            local line = "     "
            for _, name in ipairs(entry.names) do
                if #line + #name + 2 > 92 then out(line) line = "     " end
                line = line .. " " .. name
            end
            if line ~= "     " then out(line) end
        end
    end
end

--- The reader list, each entry carrying which search found it.
local function reportRecapReaders(apis)
    if #apis == 0 then
        out("  readers on this client: none, by either search")
        return
    end
    for _, api in ipairs(apis) do
        local note = (api.how == "named")
            and "  <-- found by direct index; the walk cannot see it"
            or  ""
        out(string.format("  reader: %-44s [%s]%s",
            api.ns .. "." .. api.name, api.how, note))
    end
end

--- Why each death is dated the way it is.
---
--- KEPT AFTER THE FEATURE IT WAS WRITTEN FOR WAS REMOVED. "Time into the fight"
--- never worked and is gone, and this section is what proved it could not: it
--- prints the INPUTS rather than the conclusion, which is how the third failed
--- derivation was caught instead of shipped. Anything that later tries to date a
--- death against its run will need exactly this again.
local function reportDeathDating(sources)
    out("  -- dating --")

    local S = NS.Secrets
    local F = NS.Numbers or NS.Format
    local P = NS.Provider
    if not (F and F.DeathTime and P) then
        out("    formatter or provider unavailable")
        return
    end

    local windows = NS.Database and NS.Database.GetWindows and NS.Database.GetWindows()
    local cfg = windows and windows[1]
    local text = cfg and cfg.text or {}
    out(string.format("    window 1: sessionType=%s  text.deathTimeFormat=%s",
        tostring(cfg and cfg.data and cfg.data.sessionType),
        tostring(text.deathTimeFormat)))

    local printed = 0
    for i = 1, #(sources or {}) do
        local src = sources[i]
        local id = src.deathRecapID
        if not (S and S.IsSafeKey(id)) then
            out("    [id is secret — nothing can be dated from it]")
        else
            local recap = P.GetRecap and P.GetRecap(id) or nil
            local newest = recap and recap.events and recap.events[1]
            local when = newest and newest.timestamp

            -- `deathTimeSeconds` is printed although nothing reads it any more.
            -- It is the field three separate attempts were built on, and seeing
            -- it read -1 here is what a reader needs before trying a fourth.
            out(string.format("    id=%s  row deathTimeSeconds=%s  recap timestamp=%s",
                tostring(id), shown(src.deathTimeSeconds), shown(when)))
            out(string.format("      clock=%s  ago=%s",
                tostring(F.DeathTime(when, "clock")),
                tostring(F.DeathTime(when, "ago"))))
        end
        printed = printed + 1
        if printed >= 4 then break end
    end
end

--- What the outcome above means for issue #1, said out loud.
---
--- The reader list being empty is not a detail a reader of the report should
--- have to infer from silence: it is the answer that re-scopes the issue.
---
--- THE VERDICT RESTS ON BOTH SEARCHES, and says so. Round one claimed "no recap
--- reader" on the strength of a walk alone, and a walk alone cannot support it —
--- the same output comes back from a client with a reader behind a proxy. Two
--- independent searches agreeing is a materially stronger claim than one, and
--- the wording has to carry that difference or the next person re-scopes a
--- feature on the weaker evidence.
--- THE VERDICT FOLLOWS THE ANSWERS, NOT THE LIST. Measured: round one found
--- exactly one recap-shaped function on a live client —
--- `C_DeathInfo.GetDeathReleasePosition`, a corpse coordinate — which returned
--- nil for all four ids, and the report printed "all four answering is the green
--- light" underneath it because the LIST was non-empty. A verdict that reads a
--- found name as a working reader is the diagnostic lying about its own finding.
---
--- THE DENOMINATOR IS WHAT WAS ASKED, NOT WHAT EXISTS. Measured: a run where
--- the local player never died probed two slots, both answered in full, and the
--- verdict still warned "some slots answered and some did not" — the wording
--- reserved for a client that REFUSED. Nothing had refused; two slots had no
--- death to ask about. A diagnostic crying wolf over its own missing fixture
--- teaches a reader to discount it.
---
--- @param apis table
--- @param answered table  slot labels that got an answer
--- @param probed number   slots there was actually a death to ask about
local function reportRecapVerdict(apis, answered, probed)
    local RESCOPE = {
        "  Issue #1's window would need its own event capture: a materially",
        "  larger job. Re-scope the issue before starting it.",
    }

    if #apis == 0 then
        out("  |cffff2020no recap reader, by both searches|r — neither the walk nor a")
        out("  direct index of the documented names found one, so the only recap")
        out("  call this addon has is Blizzard's frame-opening one, which cannot")
        out("  fill a pane.")
        for _, line in ipairs(RESCOPE) do out(line) end
        return
    end

    if #answered == 0 then
        out("  |cffff2020every reader answered for no id|r — functions were found and")
        out("  none of them handed back a recap, so what the searches turned up is")
        out("  not a reader for this. Same conclusion as finding nothing at all.")
        for _, line in ipairs(RESCOPE) do out(line) end
        return
    end

    out(string.format("  answered: %s   (%d of %d slots had a death to ask about)",
        table.concat(answered, ", "), #answered, probed))
    if #answered >= probed then
        out("  |cff20ff20every death this session could offer resolved|r — issue #1's")
        out("  window can be built on deathRecapID. A run covering all four slots")
        out("  confirms it hardest, but nothing here refused.")
    else
        out("  |cffffd100some slots answered and some did not|r. A reader that answers")
        out("  local/newest alone is Blizzard's own frame behaviour, and sinks the")
        out("  window as designed; the left pane is made of past deaths and the")
        out("  column covers the whole group.")
    end
    out("  Paste this into issue #1.")
end

--- The whole probe. Safe to run at any time; most useful straight after a run
--- with several deaths spread across it.
local function reportDeathRecap()
    out("|cff00ff00-- death recap (issue #1) --|r")

    local P = NS.Provider
    if not (P and P.GetColumn and P.RecapAPIs and P.CallRecap and P.RecapMembers) then
        out("  provider unavailable")
        return
    end

    local windows = NS.Database and NS.Database.GetWindows and NS.Database.GetWindows()
    local cfg = windows and windows[1]
    local sessionID = cfg and cfg.data and cfg.data.sessionID or nil
    local ST = NS.Constants.SESSION_TYPE

    -- BOTH SESSIONS, because they disagree and the disagreement matters. A live
    -- dump showed `deathTimeSeconds = -1` on Overall and a real figure on
    -- Current, and issue #1's left pane is keyed on timestamps — so which
    -- session carries a usable time is a design input, not trivia.
    reportDeathsSession("Current", ST.Current, sessionID)
    local sources = reportDeathsSession("Overall", ST.Overall, sessionID)
    -- Current is preferred for the probe: it is the session whose times are
    -- believed real. Overall is the fallback so a probe run after a reset still
    -- has ids to call.
    local current = deathsColumn(ST.Current, sessionID)
    if current and #current.sources > 0 then sources = current.sources end

    reportRecapSurface()
    local apis = P.RecapAPIs()
    reportRecapReaders(apis)

    local slots = {}
    for i = 1, #(sources or {}) do fillRecapSlot(slots, sources[i]) end

    out("  -- probes --")
    local answered, probed = reportRecapProbes(apis, slots)
    reportDeathDating(sources)
    reportRecapVerdict(apis, answered, probed)
end

--- `/mm debug recap` — the probe on its own.
---
--- It rides along in the full report too, so a player running `/mm debug diag`
--- after a dungeon hands the evidence over for free. The dedicated verb exists
--- because the answer wanted here is specific enough to ask for on its own, and
--- forty lines of atlas and font output around it makes it harder to read.
function Diagnostics.ReportDeathRecap()
    local D = NS.DebugLog
    if D and D.Add and D.Show and D.IsShown then
        pcall(function() D:Show() end)
        if D:IsShown() then
            emit = function(line) D:Add("Diag", line) end
        end
    end

    local ok, err = pcall(reportDeathRecap)
    if not ok then out("  |cffff2020section failed:|r " .. tostring(err)) end
    emit = nil
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

--- Print the whole report. Called from `/mm debug diag`.
---
--- Every section is independent and wrapped, so one broken probe cannot take the
--- rest of the report with it — a diagnostic that dies halfway is worse than no
--- diagnostic, because it looks like the thing it was diagnosing.
-- ---------------------------------------------------------------------------
-- Tooltip font — did our SetFont stick, and did it survive the layout?
-- ---------------------------------------------------------------------------

--- Report what the last spell line's font actually was, at two moments.
---
--- "The spell name kept the game's font" has two causes that look identical on
--- screen and need opposite fixes:
---
---   * SetFont was REFUSED or given a bad path — then `asked` and `after set`
---     disagree, and the fix is in what we pass;
---   * SetFont took and something later put it back — then `asked` and `after
---     set` agree while `after Show` differs, and the fix is to apply the font
---     after GameTooltip:Show() rather than before it.
---
--- modules/Tooltip.lua samples the same FontString at both moments while the
--- debug flag is on. A missing probe means no tooltip has been built since the
--- flag went on, which is its own useful answer.
local function reportTooltipFont()
    out("|cff00ff00-- tooltip font --|r")

    local Tip = NS.Tooltip
    local sample = Tip and Tip.__fontProbe
    if not sample then
        out("  no sample yet — turn the debug flag on, then hover a cell with a")
        out("  spell breakdown, then run this again.")
        return
    end

    local function line(label, path, size, flags)
        out(string.format("  %-12s %-42s %s / %s", label,
            tostring(path):gsub("^.*[\\/]", ""), tostring(size), tostring(flags)))
    end

    out(string.format("  tooltip line index: %s", tostring(sample.index)))
    line("asked:",      sample.askedPath, sample.askedSize, sample.askedFlags)
    line("after set:",  sample.setPath,   sample.setSize,   sample.setFlags)
    line("after Show:", sample.showPath,  sample.showSize,  sample.showFlags)

    -- NEAR-equality, not equality. The client stores a font size as a float and
    -- reads 10 back as 10.000000953674, so `~=` reported "SetFont did not take"
    -- for a SetFont that took perfectly — a diagnostic confidently naming the
    -- wrong cause, which is worse than no diagnostic at all.
    local function near(a, b)
        if type(a) ~= "number" or type(b) ~= "number" then return a == b end
        return math.abs(a - b) < 0.5
    end

    if not near(sample.setSize, sample.askedSize) then
        out("  |cffff2020SetFont did not take|r — the path or size we passed was refused.")
    elseif not near(sample.showSize, sample.setSize)
        or (sample.showFlags or "") ~= (sample.askedFlags or "") then
        out("  |cffff2020the layout reverted it|r — apply the font AFTER Show.")
    else
        out("  the font stuck through layout; if the name still looks wrong the")
        out("  cause is elsewhere (wrong FontString, or the name is not line N).")
    end
end

-- ---------------------------------------------------------------------------
-- Tooltip width — why the spell names and the amounts collide
-- ---------------------------------------------------------------------------

--- Report how the tooltip's minimum width is composed.
---
--- Every term comes from config or from the tooltip's own ruler, never from a
--- widget that has held a meter value, so this is safe to run at any time. It is
--- here because the width was got wrong three times: the spell captions are
--- SECRET in combat, so the span reserved for a name is a fixed number of
--- characters rather than anything measured off the names. See
--- `applyMinimumWidth` in modules/Tooltip.lua.
local function reportTooltipWidth()
    out("|cff00ff00-- tooltip width --|r")

    local Tip = NS.Tooltip
    local parts = Tip and Tip.WidthParts and Tip.WidthParts()
    if not parts then
        out("  the tooltip module is not loaded.")
        return
    end

    out(string.format("  name span: %s chars -> %.1fpx", tostring(parts.chars), parts.nameSpan))
    out(string.format("  + gap %s + amount %s + gap %s + share %.1f + padding %s",
        tostring(parts.nameGap), tostring(parts.amount), tostring(parts.slotGap),
        parts.share, tostring(parts.padding)))
    out(string.format("  = minimum width %.1fpx, the same in combat and out", parts.total))
end

-- ---------------------------------------------------------------------------
-- Targets — where the enemy cross-reference stops
-- ---------------------------------------------------------------------------

--- What the client flags the enemy column's sources as.
---
--- THE BELT ON A LOOSENED GATE. modules/Aggregator.lua used to admit an unowned
--- source only on an explicit `Ally`, and a delve companion filed under `None`
--- was dropped for the whole of a run because of it. `None` is now admitted when
--- the source carries a real player class — which is safe exactly as long as
--- enemies keep reporting `Enemy`, and that is an assumption about a live client
--- rather than a fact about the code.
---
--- So it is printed rather than assumed. A `None` in this tally is the warning
--- that the class test is the only thing standing between a trash pack and the
--- grid, and it arrives in a report instead of as a wrong row nobody can explain.
---
--- @param column table
local function reportEnemyDisplayTypes(column)
    local tally, order = {}, {}
    for _, src in ipairs(column.sources) do
        local key = shown(src.sourceDisplayType)
        if tally[key] == nil then order[#order + 1] = key end
        tally[key] = (tally[key] or 0) + 1
    end

    local parts = {}
    for _, key in ipairs(order) do
        parts[#parts + 1] = string.format("%s x%d", key, tally[key])
    end
    out("  display types: " .. (parts[1] and table.concat(parts, " · ") or "none"))

    -- THE BELT CANNOT ANSWER MID-PULL, and it must say so rather than look calm.
    -- `sourceDisplayType` is secret for the whole of a pull — measured, not
    -- assumed: a live report printed `display types: <secret> x5`. With every
    -- entry unreadable the check below finds no `0` and prints nothing, which
    -- reads exactly like "checked, all clear" and is not.
    if tally[SECRET] and tally[SECRET] == #column.sources then
        out("  |cffffd100every display type is secret|r — they are for the whole of a")
        out("  pull, so this check has not run. Re-run out of combat.")
        return
    end

    -- 2 is Enemy. Naming the number rather than the enum keeps this readable
    -- against a raw log line, which is the form it is pasted back in.
    if tally["0"] then
        out("  |cffff2020an enemy is flagged None (0)|r — the aggregator admits a")
        out("  None source that carries a real player class, so a mob with a class")
        out("  filename could now reach the grid. Report this line.")
    end
end

-- ---------------------------------------------------------------------------
-- The provider-order probe
-- ---------------------------------------------------------------------------
--
-- modules/Provider.lua rests on ONE assumption that nothing in Blizzard's
-- documentation supports: that `combatSources` arrives already ranked by the
-- stat that was asked for, descending. Everything the addon draws in a pull
-- stands on it. Identity mode takes row IDENTITY from position, so if the order
-- is not the ranking then the mid-pull grid is wrong rather than merely
-- misordered — and no amount of reading the source can settle it.
--
-- It is settleable HERE. Out of combat the amounts are plain and `<` is legal,
-- so walking each column in the order the API returned it and asking whether the
-- totals descend is a direct measurement of the assumption. A break disproves it
-- outright; a clean walk is strong evidence for it, short of proof only because
-- the API could in principle build the array differently under the restriction.
--
-- The probe therefore prints a DECISION rather than a dump: ranked, NOT ranked
-- with the index where it broke, or an explicit admission that it could not run.

--- Where the sources stop descending, or nil if they never do.
---
--- Comparability is proved for BOTH operands before `<` is reached, exactly as
--- modules/Aggregator.lua's sort ladder does it: a comparison that discovers a
--- secret has already raised. A single unreadable pair abandons the whole walk
--- rather than skipping past it, because a probe that silently steps over the
--- values it cannot see reports a clean column it never actually checked.
---
--- @param column table  a provider column
--- @return number|nil breakIndex, boolean checked
local function firstOrderBreak(column)
    local Secrets = NS.Secrets
    local previous = nil

    for index, src in ipairs(column.sources) do
        local total = src.totalAmount
        if total == nil then return nil, false end
        if previous ~= nil then
            if not (Secrets and Secrets.CanCompare2(previous, total)) then
                return nil, false
            end
            if previous < total then return index, true end
        end
        previous = total
    end

    return nil, true
end

--- One column's verdict, as the line it prints.
---
--- Split from the section below so each of them says one thing: this decides,
--- that walks the catalog. It also keeps both under the complexity ceiling the
--- release gate enforces, which a single nested ladder was over.
---
--- @return string line, boolean isBroken
local function orderVerdict(statKey, column)
    local count = (type(column) == "table" and #column.sources) or 0

    -- One source cannot be out of order with itself, and a verdict on it would
    -- pad the section with lines that carry nothing.
    if count < 2 then
        return string.format("  %-22s %d sources — nothing to check", statKey, count), false
    end

    local breakIndex, checked = firstOrderBreak(column)
    if not checked then
        return string.format("  %-22s %d sources — |cffffd100cannot be checked|r",
            statKey, count), false
    end
    if breakIndex then
        return string.format("  %-22s %d sources — |cffff2020NOT ranked|r, breaks at index %d",
            statKey, count, breakIndex), true
    end
    return string.format("  %-22s %d sources — ranked, descending", statKey, count), false
end

--- Measure the one assumption modules/Provider.lua admits it cannot verify.
local function reportProviderOrder()
    out("|cff00ff00-- provider order --|r")

    local P = NS.Provider
    if not (P and P.GetColumn) then
        out("  provider unavailable")
        return
    end

    local windows = NS.Database and NS.Database.GetWindows and NS.Database.GetWindows()
    local data = windows and windows[1] and windows[1].data or {}
    local sessionType = data.sessionType or 1

    local broken = false
    for _, stat in ipairs(NS.Constants.STATS) do
        local line, isBroken = orderVerdict(stat.key,
            P:GetColumn(sessionType, stat.key, data.sessionID))
        if isBroken then broken = true end
        out(line)
    end

    if broken then
        out("  |cffff2020the provider-order assumption is FALSE on this client|r —")
        out("  modules/Provider.lua names the fix: a sort inside GetColumn, which is")
        out("  legal out of combat. Paste this section into issue #14.")
    else
        out("  Values are secret for the whole of a pull, so a `cannot be checked`")
        out("  line means only that: re-run this out of combat for a verdict.")
    end
end

--- Walk the enemy column the way modules/Targets.lua does, and say where it dies.
---
--- The section has five places it can silently produce nothing, and they are
--- indistinguishable from "no Targets header": no enemy column, enemies dropped
--- for want of a GUID, a source detail that will not resolve, spells with no
--- `combatSpellDetails`, or a `unitName` that never matches the row's name. This
--- prints a count at each step, so the first zero is the answer.
---
--- Rule R1 holds: every read goes through modules/Provider.lua. No amount is
--- inspected — spells are COUNTED and names are described, never rendered.
local function reportTargets()
    out("|cff00ff00-- targets cross-reference --|r")

    local P = NS.Provider
    if not (P and P.GetColumn and P.GetSourceDetail) then
        out("  provider unavailable")
        return
    end

    local windows = NS.Database and NS.Database.GetWindows and NS.Database.GetWindows()
    local cfg = windows and windows[1]
    local sessionType = (cfg and cfg.data and cfg.data.sessionType) or 1
    local sessionID   = cfg and cfg.data and cfg.data.sessionID or nil
    out(string.format("  session type=%s id=%s", tostring(sessionType), tostring(sessionID)))

    local column = P:GetColumn(sessionType, "EnemyDamageTaken", sessionID)
    if type(column) ~= "table" then
        out("  enemy column: nil")
        return
    end
    out(string.format("  enemy column: %d sources, reason=%s",
        #column.sources, tostring(column.reason)))
    reportEnemyDisplayTypes(column)
    if #column.sources == 0 then
        out("  |cffff2020no enemies|r — either the session holds none, or every one")
        out("  was dropped by the provider's `sourceGUID == nil` guard.")
        return
    end

    local Secrets = NS.Secrets
    local withDetail, withSpells, withDetails, sampleNames = 0, 0, 0, {}
    -- How many enemies could be ASKED about at all. Without this the walk's
    -- first failure and its last were reported as the same thing.
    local identified = 0

    for i = 1, math.min(#column.sources, 8) do
        local enemy = column.sources[i]
        local guid = enemy.guid
        -- Named for what it answers, and not `safe`: this file now has a
        -- module-level `safe` for "printable", and a local shadowing it made two
        -- different questions share one word.
        local plainGUID = Secrets and Secrets.IsSafeKey(guid)
        -- The creature ID gets the same gate as the GUID. It is plain out of
        -- combat and SECRET in a pull, and forwarding a secret one is what
        -- raised `bad argument #4` here and, more seriously, on the tooltip's
        -- own render path — see modules/Targets.lua.
        local creatureID = enemy.creatureID
        local safeID = Secrets and Secrets.IsSafeKey(creatureID)
        out(string.format("  [%d] name=%s guid=%s creatureID=%s display=%s",
            i, shown(enemy.name), plainGUID and "plain" or "secret/absent",
            safeID and tostring(creatureID) or "secret/absent",
            shown(enemy.sourceDisplayType)))

        local source = (plainGUID or safeID)
            and P:GetSourceDetail(sessionType, "EnemyDamageTaken",
                plainGUID and guid or nil, safeID and creatureID or nil, sessionID)
            or nil
        if plainGUID or safeID then identified = identified + 1 end
        if type(source) ~= "table" then
            out("        detail: nil")
        else
            withDetail = withDetail + 1
            local spells = 0
            Secrets.SafeIterate(source.combatSpells, function(_, spell)
                if type(spell) ~= "table" then return end
                spells = spells + 1
                local d = spell.combatSpellDetails
                if Secrets.CanAccessTable(d) then
                    withDetails = withDetails + 1
                    local n = d.unitName
                    if n ~= nil and Secrets.CanAccess(n) and type(n) == "string"
                        and #sampleNames < 6 then
                        sampleNames[#sampleNames + 1] = n
                    end
                end
            end)
            if spells > 0 then withSpells = withSpells + 1 end
            out(string.format("        detail: yes, %d spells", spells))
        end
    end

    out(string.format("  enemies with a detail: %d · with spells: %d · spells carrying combatSpellDetails: %d",
        withDetail, withSpells, withDetails))

    -- WHERE THE WALK DIED DECIDES WHAT THIS MEANS, and conflating the two
    -- readings is how a live report came back accusing the client of a missing
    -- field it in fact carries. In a pull BOTH identifiers on every enemy are
    -- secret, so `GetSourceDetail` is never called, so no spell is ever seen —
    -- and the old verdict read that silence as "this build does not carry the
    -- caster". The same client, out of combat, hands over the caster name
    -- immediately. Only a walk that actually REACHED spells can say anything
    -- about the field.
    if identified == 0 then
        out("  |cffffd100no enemy had a readable GUID or creature ID|r — both are")
        out("  secret for the whole of a pull, so the walk stops before it reaches")
        out("  a spell. This says nothing about the build; re-run out of combat.")
    elseif withDetail == 0 then
        out("  |cffff2020every source detail came back nil|r — the identifiers were")
        out("  readable but resolved to nothing.")
    elseif withDetails == 0 then
        out("  |cffff2020no combatSpellDetails on any spell|r — this build does not")
        out("  carry the caster, and the cross-reference cannot work at all.")
    end

    if #sampleNames > 0 then
        out("  caster names seen: " .. table.concat(sampleNames, ", "))
    else
        out("  caster names seen: none readable")
    end

    -- The comparison that actually decides it. A realm suffix on one side and not
    -- the other makes every match fail while both strings look right in print.
    local roster = NS.Roster and NS.Roster.GetGroup and NS.Roster.GetGroup()
    if roster then
        local names = {}
        for i = 1, math.min(#roster, 6) do names[#names + 1] = tostring(roster[i].name) end
        out("  roster names:      " .. table.concat(names, ", "))
        out("  ^ these two lists must match EXACTLY for a target row to appear.")
    end
end

function Diagnostics.Report()
    -- Open the console and route into it — but only once it has actually opened.
    -- `IsShown` is asked rather than the library's presence assumed, because the
    -- degraded stub answers every member and shows nothing, and a report that
    -- vanished into a no-op sink would look exactly like a report with nothing
    -- to say.
    local D = NS.DebugLog
    if D and D.Add and D.Show and D.IsShown then
        pcall(function() D:Show() end)
        if D:IsShown() then
            emit = function(line) D:Add("Diag", line) end
        end
    end

    out("|cffffd100Ka0s Mythic Meters — diagnostics|r  v" .. tostring(NS.version))

    for _, section in ipairs({
        reportAtlases, reportFormatter, reportVisibility, reportHeader,
        reportNameColumn, reportCells, reportTooltipFont, reportTooltipWidth,
        reportTargets, reportProviderOrder, reportDeathRecap,
    }) do
        local ok, err = pcall(section)
        if not ok then out("  |cffff2020section failed:|r " .. tostring(err)) end
    end

    if emit then
        out("Copy the block above into the bug report — the console's copy button")
        out("takes the whole buffer.")
    else
        out("Copy the block above into the bug report.")
    end
    emit = nil
end
