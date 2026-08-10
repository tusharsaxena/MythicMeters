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

--- Print one line through the addon's chat prefix.
local function out(line)
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
    out(string.format("  width=%d  showClass=%s showSpec=%s showRole=%s size=%s",
        inst.layout.nameColumn.width,
        tostring(icons.showClass), tostring(icons.showSpec),
        tostring(icons.showRole), tostring(icons.size)))

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
function Diagnostics.Report()
    out("|cffffd100Ka0s Mythic Meters — diagnostics|r  v" .. tostring(NS.version))

    for _, section in ipairs({
        reportAtlases, reportFormatter, reportVisibility, reportHeader,
        reportNameColumn, reportCells,
    }) do
        local ok, err = pcall(section)
        if not ok then out("  |cffff2020section failed:|r " .. tostring(err)) end
    end

    out("Copy the block above into the bug report.")
end
