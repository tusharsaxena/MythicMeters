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
}

-- Values chosen so each one lands on a different rung of the breakpoint ladder in
-- modules/Format.lua. What they SHOULD render as is printed beside what they DO,
-- so a mismatch is visible without anybody having to remember the ladder.
local NUMBER_PROBES = {
    { value = 470.66666666667, want = "470"    },
    { value = 4750,            want = "4.75K"  },
    { value = 47500,           want = "47.5K"  },
    { value = 475000,          want = "475.0K" },
    { value = 1410000,         want = "1.41M"  },
    { value = 12400000,        want = "12.4M"  },
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

--- `pcall` a getter and describe the outcome rather than returning it.
---
--- A refusal is the interesting answer: geometry read off a frame that has held a
--- secret is exactly what rule R3 forbids everywhere else, and "this raised" tells
--- a reader the frame is in the secret set.
local function probe(fn, ...)
    local ok, value = pcall(fn, ...)
    if not ok then return "<refused>" end
    if value == nil then return "nil" end
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
    for _, p in ipairs(NUMBER_PROBES) do
        local got = tostring(F.Number(p.value))
        local mark = (got == p.want) and "" or "   <-- expected " .. p.want
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
                tostring(cell.left:GetText())))
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
            tostring(row.nameCell.left:GetText())))
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
    out(string.format("  title=%q", tostring(inst.frame.title:GetText())))
    out(string.format("  session line=%q", tostring(inst.sessionText:GetText())))

    for label, button in pairs({ gear = inst.configButton, lock = inst.lockButton }) do
        if button then
            out(string.format("  %-5s atlas=%s glyph=%q shown=%s",
                label,
                tostring(button.tex and button.tex:GetAtlas()),
                tostring(button.glyph and button.glyph:GetText()),
                tostring(button:IsShown())))
        end
    end
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
-- Targets — where the enemy cross-reference stops
-- ---------------------------------------------------------------------------

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
    if #column.sources == 0 then
        out("  |cffff2020no enemies|r — either the session holds none, or every one")
        out("  was dropped by the provider's `sourceGUID == nil` guard.")
        return
    end

    local Secrets = NS.Secrets
    local withDetail, withSpells, withDetails, sampleNames = 0, 0, 0, {}

    for i = 1, math.min(#column.sources, 8) do
        local enemy = column.sources[i]
        local guid = enemy.guid
        local safe = Secrets and Secrets.IsSafeKey(guid)
        out(string.format("  [%d] name=%s guid=%s creatureID=%s",
            i, tostring(enemy.name), safe and "plain" or "secret/absent",
            tostring(enemy.creatureID)))

        local source = P:GetSourceDetail(sessionType, "EnemyDamageTaken",
            safe and guid or nil, enemy.creatureID, sessionID)
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

    if withDetails == 0 then
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
        reportNameColumn, reportCells, reportTooltipFont, reportTargets,
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
