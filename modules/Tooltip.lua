-- modules/Tooltip.lua
--
-- What a hover says. Two tooltips, one module:
--
--   * hovering a STAT CELL lists the individual spells behind that one number
--     for that one player — which kick, which dispel, which avoidable hit;
--   * hovering the NAME cell summarizes EVERY tracked statistic for that
--     player, including the columns this window is not showing, which is the
--     cross-column read the whole addon exists for.
--
-- ---------------------------------------------------------------------------
-- SECRETS: THE RULE THAT SHAPES EVERY LINE BELOW
-- ---------------------------------------------------------------------------
--
-- A tooltip looks like the safest place in a meter — it is unprotected, it is
-- built out of strings, nothing about it is secure. It is in fact the most
-- dangerous, because a tooltip is where a developer's instinct is to say "just
-- show the top five spells" and "put the total at the bottom". Both of those are
-- Lua errors mid-pull: a top-N is a COMPARISON and a total is ARITHMETIC, and
-- while the Combat addon restriction is active every amount on a spell row is a
-- SECRET value.
--
-- So, in this file:
--   * no amount is ever added, subtracted, divided or compared;
--   * every amount reaches the screen through string.format or through the
--     number formatter, both of which accept secrets (design §4);
--   * ordering is attempted ONLY when NS.Secrets says comparison is legal, and
--     otherwise the spells are shown in the order the API returned them, which
--     is a real ordering and not a fallback to nonsense;
--   * booleans off the API (isAvoidable, isDeadly) are never truth-tested
--     directly, because a SECRET boolean raises on a boolean test — they go
--     through `plainTruth`, which asks core/Secrets.lua first;
--   * nil-ness tests use an explicit `~= nil`, which is the one comparison a
--     non-boolean secret permits.
--
-- Counting is the other trap. `#spells` is the length operator, forbidden on a
-- secret table, so the count comes from NS.Secrets.SafeCount and the walk from
-- NS.Secrets.SafeIterate — which is also why the "and N more" line can exist at
-- all without measuring anything we are not allowed to measure.
--
-- ---------------------------------------------------------------------------
-- WHY GAMETOOLTIP
-- ---------------------------------------------------------------------------
--
-- A private tooltip frame would let us style it, and would cost us every addon
-- that hooks GameTooltip, the player's tooltip skin, and the automatic
-- repositioning that keeps a tooltip on screen. GameTooltip is cleared and
-- re-owned on every hover, so nothing we add outlives the hover.

local addonName, NS = ...

local Tooltip = NS:NewModule("Tooltip", "AceEvent-3.0")
NS.Tooltip = Tooltip

local L      = NS.L
local Const  = NS.Constants
local Compat = NS.Compat
local State  = NS.State
local Debug  = NS.Debug

-- Load-time upvalue, never an NS lookup in the bracket itself (performance-§2).
-- core/PerfSetup.lua loads well before modules/, and it always publishes at least
-- the degradation stub, so the `or {}` covers only a hand-broken install.
local Perf = NS.Perf or {}

-- Fallback icon for a spellID the client cannot resolve — a real texture rather
-- than a blank, so a missing icon reads as "unknown spell" instead of as a
-- broken layout.
local FALLBACK_ICON = [[Interface\ICONS\INV_Misc_QuestionMark]]

-- Icon edge length inside a tooltip line, in pixels. Sized to sit on the text
-- baseline at the game's default tooltip font rather than to match the row
-- icons, which are configurable and live in a different frame entirely.
local TOOLTIP_ICON_SIZE = 14

-- How many spell rows to pull off the API before deciding what to show.
--
-- Larger than any sane `tooltip.maxSpells` on purpose: when comparison is legal
-- we sort what we collected and show the biggest few, and sorting only the first
-- ten rows the API happened to hand back would produce a "top 5" that is nothing
-- of the sort. Small enough that a hover never walks a long array.
local COLLECT_LIMIT = 64

-- Gray used for statistics the hovered window is not currently showing. The
-- name tooltip deliberately lists every tracked stat — that is its whole job —
-- and the dimming is what keeps "this is on your grid" separable from "this is
-- extra" at a glance. NS.GRAY is the collection's canonical gray; never a second
-- hex literal.
local GRAY = NS.GRAY or "|cff9d9d9d"

-- ---------------------------------------------------------------------------
-- Collaborators, resolved at call time
-- ---------------------------------------------------------------------------
--
-- modules/ files load in TOC order and this one cannot assume it is last, so
-- neither the provider nor the number formatter is captured as a load-time
-- upvalue. Both resolutions are shape-agnostic — flat NS field first, AceAddon
-- module second — because that is the pattern the rest of the addon uses to
-- reach a module and it costs one table read on a path that runs on a hover.

--- modules/Provider.lua, or nil.
local function provider()
    if NS.Provider then return NS.Provider end
    if NS.GetModule then return NS:GetModule("Provider", true) end
    return nil
end

--- Render one meter amount as text.
---
--- THE ONLY LEGAL ABBREVIATOR is C_StringUtil's numeric rule formatter, whose
--- FormatNumber does the division natively; modules/Format.lua owns the
--- instances. Note that `NS.Format` is NOT it — that name belongs to
--- LibKa0s-Core's chat printf, claimed in core/CoreSetup.lua — so the number
--- formatter is reached through the module registry.
---
--- When no formatter is reachable the value is returned UNTOUCHED rather than
--- stringified. It is then handed to string.format's `%s`, which accepts a
--- secret; calling tostring() on it here would be an inspection this file is not
--- allowed to make (rule R1).
---
--- @param value any   a meter amount, possibly secret
--- @param style string|nil  "abbreviated" | "full"
--- @return any  a string, or the original opaque value
local function formatNumber(value, style)
    local F = NS.Numbers or (NS.GetModule and NS:GetModule("Format", true))
    if F then
        if F.Number then return F.Number(value, style) end
        if F.FormatNumber then return F:FormatNumber(value, style) end
    end
    return value
end

-- ---------------------------------------------------------------------------
-- Secret-safe primitives
-- ---------------------------------------------------------------------------

--- Truth-test a field that MIGHT be a secret boolean.
---
--- `if spell.isAvoidable then` is the natural way to write this and it raises
--- the moment the Combat restriction is active, because a boolean test on a
--- secret boolean is exactly what tainted code may not do. Asking
--- core/Secrets.lua whether the value is accessible first keeps the inspection
--- in the one file allowed to make it, and an inaccessible flag reads as false —
--- the tooltip loses a "Deadly" tag mid-pull rather than erroring.
---
--- @param v any
--- @return boolean
local function plainTruth(v)
    local Secrets = NS.Secrets
    if not (Secrets and Secrets.CanAccess) then return false end
    if not Secrets.CanAccess(v) then return false end
    return v and true or false
end

--- A player's display name, or a placeholder.
---
--- `name` is ConditionalSecret: readable most of the time, opaque some of the
--- time, and never something to concatenate a fallback onto with `or` without
--- asking first. An inaccessible name still renders — it goes to the widget as
--- the opaque handle it is — but a NIL name has to become a string here, since
--- the tooltip's first line cannot be nil.
---
--- @param row table
--- @return any  a string, or an opaque name handle
local function displayName(row)
    local name = row and row.name
    if name == nil then return L["Player"] end
    return name
end

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

-- Every field the two builders read, with the shipped value beside it. Taken
-- from NS.WINDOW_TEMPLATE at CALL time rather than copied as literals, so a
-- change to defaults/Profile.lua cannot leave a stale second copy here.
local function tooltipConfig(window)
    local template = NS.WINDOW_TEMPLATE and NS.WINDOW_TEMPLATE.tooltip or nil
    local stored = (type(window) == "table" and window.tooltip) or nil

    local function field(key, hardDefault)
        if stored and stored[key] ~= nil then return stored[key] end
        if template and template[key] ~= nil then return template[key] end
        return hardDefault
    end

    return {
        anchor             = field("anchor", "CURSOR"),
        showSpells         = field("showSpells", true),
        maxSpells          = field("maxSpells", 10),
        showAllStatsOnName = field("showAllStatsOnName", true),
        hideInCombat       = field("hideInCombat", false),
    }
end

--- The window config a row belongs to.
---
--- Callers pass it explicitly wherever they have it; the lookup exists for the
--- row-pool call sites, which hold a window ID on the frame and not the table.
---
--- @param row table|nil
--- @param window table|nil
--- @return table|nil
local function resolveWindow(row, window)
    if type(window) == "table" then return window end
    local id = row and row.windowId
    if id ~= nil and NS.Database and NS.Database.FindWindow then
        local found = NS.Database.FindWindow(id)
        return found
    end
    return nil
end

--- Which session (Current / Overall / Expired) this window reads.
local function sessionTypeOf(window)
    local data = type(window) == "table" and window.data or nil
    if data and data.sessionType ~= nil then return data.sessionType end
    return Const.SESSION_TYPE.Current
end

--- Which stored SEGMENT it is pointed at, or nil for "the one sessionType
--- names". A tooltip that read the live pull while the grid under it showed a
--- historical segment would be describing a different fight than the row the
--- cursor is on.
local function sessionIDOf(window)
    local data = type(window) == "table" and window.data or nil
    return data and data.sessionID or nil
end

--- The abbreviation style the hovered window is using, so the tooltip's numbers
--- read the same way its cells do. nil means "whatever the formatter defaults
--- to", which is what an unconfigured window wants.
local function numberStyleOf(window)
    return window and window.text and window.text.numberFormat or nil
end

--- How many spell lines the breakdown may draw.
---
--- Clamped here rather than trusted, because `maxSpells` comes off a saved
--- profile that an older build — or a hand edit — may have left as a string, as
--- zero, or as a negative. The shipped default is the answer in every one of
--- those cases.
local function spellLineCap(config)
    local cap = config.maxSpells
    if type(cap) ~= "number" or cap < 1 then return 10 end
    return cap
end

-- ---------------------------------------------------------------------------
-- Anchoring
-- ---------------------------------------------------------------------------
--
-- GameTooltip's own anchor tokens, keyed by the setting's value. The setting is
-- worded for a player ("Bottom right") and the token is Blizzard's; keeping the
-- translation in one table is what stops a typo'd "ANCHOR_BOTTOMRIGHT" from
-- silently falling back to the cursor.
--
-- NOTE ON SECRET GEOMETRY: we set the OWNER and let the client place the
-- tooltip. We never read GetPoint / GetLeft / GetWidth off the anchor frame to
-- position anything ourselves — a cell that has been handed a secret value has
-- secret geometry, and reading it back is rule R3's exact prohibition.
local ANCHOR_TOKENS = {
    CURSOR      = "ANCHOR_CURSOR",
    TOPLEFT     = "ANCHOR_TOPLEFT",
    TOPRIGHT    = "ANCHOR_TOPRIGHT",
    BOTTOMLEFT  = "ANCHOR_BOTTOMLEFT",
    BOTTOMRIGHT = "ANCHOR_BOTTOMRIGHT",
}

--- Claim GameTooltip for this hover, or answer false if it must not open.
---
--- The combat test is UnitAffectingCombat("player") and NOT InCombatLockdown().
--- They differ at both ends of a pull, and what the setting means is "while I am
--- fighting, keep this out of my way" — a statement about the player, not about
--- whether secure writes are currently legal.
---
--- @param anchorFrame table
--- @param config table
--- @return boolean  whether the tooltip was opened
local function openTooltip(anchorFrame, config)
    if not _G.GameTooltip or not anchorFrame then return false end

    if config.hideInCombat and _G.UnitAffectingCombat and UnitAffectingCombat("player") then
        return false
    end

    GameTooltip:SetOwner(anchorFrame, ANCHOR_TOKENS[config.anchor] or "ANCHOR_CURSOR")
    GameTooltip:ClearLines()
    return true
end

-- ---------------------------------------------------------------------------
-- Spell rows
-- ---------------------------------------------------------------------------

--- Pull up to COLLECT_LIMIT spell rows off a session source.
---
--- Walks through NS.Secrets.SafeIterate, which never applies `#` to the array
--- and stops at the first nil — the only way to traverse a possibly-secret table
--- without measuring it. Each row is additionally checked for accessibility,
--- because the ARRAY being walkable does not make every ENTRY indexable.
---
--- @param source table  a DamageMeterCombatSessionSource
--- @return table spells, number|nil totalCount
local function collectSpells(source)
    local Secrets = NS.Secrets
    local spells = {}
    if not (Secrets and Secrets.SafeIterate) then return spells, nil end

    local total = Secrets.SafeCount and Secrets.SafeCount(source.combatSpells) or nil

    Secrets.SafeIterate(source.combatSpells, function(_, spell)
        if type(spell) ~= "table" then return end
        if Secrets.CanAccessTable and not Secrets.CanAccessTable(spell) then return end
        spells[#spells + 1] = spell
        if #spells >= COLLECT_LIMIT then return false end
    end)

    return spells, total
end

--- Order the collected spells biggest-first, but ONLY when that is legal.
---
--- Every amount is checked BEFORE table.sort is entered, not inside the
--- comparator. A comparator that refused some comparisons would return an
--- inconsistent order and Lua would raise "invalid order function for sorting" —
--- a confusing error for a correct instinct. Checking up front means the answer
--- is binary: sort everything, or sort nothing and present the provider's order,
--- which the API already returns in a meaningful sequence.
---
--- A MISSING amount fails the pre-pass too, and that is not pedantry:
--- CanAccess(nil) is TRUE — nil is not a secret — so a spell row with no
--- totalAmount sails through a comparability check and then raises inside the
--- comparator with "attempt to compare nil with number". Refusing the whole sort
--- keeps the binary answer above honest, and the provider's order is a real
--- order rather than a degradation.
---
--- @param spells table
--- @return boolean  whether the list was sorted
local function sortSpellsIfLegal(spells)
    local Secrets = NS.Secrets
    if not (Secrets and Secrets.CanCompare) then return false end

    for i = 1, #spells do
        local amount = spells[i].totalAmount
        if amount == nil then return false end
        if not Secrets.CanCompare(amount) then return false end
    end

    table.sort(spells, function(a, b)
        return a.totalAmount > b.totalAmount
    end)
    return true
end

--- One "icon Spellname .... amount" line.
---
--- The left side is assembled with string.format, which is legal with secrets;
--- the right side is the amount itself, handed to the formatter and then to the
--- widget as whatever it comes back as. Nothing in between looks at it.
---
--- @param spell table
--- @param numberStyle string|nil
-- ---------------------------------------------------------------------------
-- THE BAR BEHIND A SPELL LINE
-- ---------------------------------------------------------------------------
--
-- A GameTooltip line is TEXT. `|T…|t` embeds a texture but carries no tint, and
-- there is no markup that colors one — so the first attempt was a run of block
-- glyphs (not in the game font, drew boxes) and the second was a run of `=`
-- (legible, and obviously not a bar).
--
-- The third is the real thing: STATUSBARS PARENTED TO THE TOOLTIP, one per line,
-- wearing the window's own bar texture and the player's class color. They are
-- pooled and re-anchored per hover rather than created per line, and they are
-- laid out from the tooltip's own line FontStrings — which are Blizzard's
-- widgets, have never held one of our secret values, and are therefore free to
-- measure. Rule R3 is about cells that HAVE held one.
--
-- They are hidden whenever the tooltip is, so a stale bar can never outlive the
-- hover that drew it.
local BAR_HEIGHT = 12

local barPool = {}

--- Hide every bar. Called at the top of each hover and when the tooltip closes.
local function releaseBars()
    for _, bar in ipairs(barPool) do bar:Hide() end
end

--- The nth pooled bar, created on first use.
local function bar(index)
    local b = barPool[index]
    if b then return b end
    b = CreateFrame("StatusBar", nil, GameTooltip)
    b:SetHeight(BAR_HEIGHT)
    b:SetFrameLevel(GameTooltip:GetFrameLevel())
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(b)
    bg:SetColorTexture(0, 0, 0, 0.35)
    b.bg = bg
    barPool[index] = b
    return b
end

--- Draw the bar for one spell line.
---
--- ABSENT WHILE THE VALUES CANNOT BE DIVIDED. A bar's length is amount / max,
--- which raises on two secrets, so it is drawn when core/Secrets.lua says both
--- operands are readable and omitted when they are not — exactly like the percent
--- text slot. The NUMBER never goes away, so a mid-pull tooltip loses decoration
--- rather than information.
---
--- @param lineIndex number  which tooltip line to sit behind
--- @param amount any        the spell's total, possibly secret
--- @param max any           the largest total in this breakdown, possibly secret
--- @param color table|nil   { r, g, b }
--- @param texture string|nil  an LSM statusbar path
local function drawBar(lineIndex, amount, max, color, texture)
    local Secrets = NS.Secrets
    if not (Secrets and Secrets.CanCompare2 and Secrets.CanCompare2(amount, max)) then
        return
    end
    if type(amount) ~= "number" or type(max) ~= "number" or max <= 0 then return end

    local name = GameTooltip:GetName()
    local left = name and _G[name .. "TextLeft" .. lineIndex]
    local right = name and _G[name .. "TextRight" .. lineIndex]
    if not (left and right) then return end

    local b = bar(lineIndex)
    b:ClearAllPoints()
    -- Spanning from just after the spell name to just before its number, so the
    -- bar occupies the empty middle of the line rather than sitting under either.
    b:SetPoint("LEFT", left, "RIGHT", 8, 0)
    b:SetPoint("RIGHT", right, "LEFT", -6, 0)
    if texture then b:SetStatusBarTexture(texture) end
    b:SetMinMaxValues(0, max)
    b:SetValue(amount)
    b:SetStatusBarColor((color and color.r) or 0.6, (color and color.g) or 0.6,
        (color and color.b) or 0.6, 0.85)
    b:Show()
end

local function addSpellLine(spell, numberStyle, max, color, texture)
    local spellID = spell.spellID
    local spellName, iconID
    if spellID ~= nil and Compat and Compat.GetSpellInfo then
        spellName, iconID = Compat.GetSpellInfo(spellID)
    end

    -- A spell the client cannot name is shown by ID rather than dropped: an
    -- unnamed row is still evidence, and a silently missing row is not. The nil
    -- case has to be handled explicitly because string.format("%s", nil) raises
    -- in Lua 5.1 — the one place this line could break is the one place the
    -- data is already unusual.
    local caption = spellName
    if caption == nil then
        caption = (spellID ~= nil) and string.format("#%s", spellID) or "#?"
    end

    local label = string.format("|T%s:%d:%d:0:0|t %s",
        iconID or FALLBACK_ICON,
        TOOLTIP_ICON_SIZE, TOOLTIP_ICON_SIZE,
        caption)

    GameTooltip:AddDoubleLine(label, formatNumber(spell.totalAmount, numberStyle),
        1, 1, 1, 1, 0.82, 0)

    -- The bar goes BEHIND the line that was just added, so it needs the line's
    -- index — which is NumLines now that the line exists.
    drawBar(GameTooltip:NumLines(), spell.totalAmount, max, color, texture)
end

--- The extra facts an Avoidable Damage row carries: whether the hit was
--- avoidable, and whether it was deadly.
---
--- Only rendered for the avoidable column, because that is the column where the
--- question "could I have stepped out of this" is the entire point. The flags go
--- through plainTruth, because they may be secret booleans and a boolean test on
--- one raises.
---
--- NO OVERKILL LINE. This used to render `overkillAmount` beneath the hit, and it
--- was noise in the one place it appeared: overkill is the part of a killing blow
--- that exceeded the target's remaining health, which is a fact about DAMAGE
--- DEALT. On damage the player TOOK it is either zero or the amount by which they
--- were already dead, and neither answers "could I have stepped out of this".
--- Blizzard still ships the field; we simply have no column it belongs to.
---
--- @param _numberStyle string|nil  kept so the signature matches its sibling
---   renderers; nothing here formats an amount any more
local function addAvoidableDetail(spell, _numberStyle)
    local marks
    if plainTruth(spell.isAvoidable) then marks = L["Avoidable"] end
    if plainTruth(spell.isDeadly) then
        marks = marks and (marks .. ", " .. L["Deadly"]) or L["Deadly"]
    end
    if marks then
        GameTooltip:AddLine(string.format("    %s%s|r", GRAY, marks))
    end
end

--- The provider's per-spell detail for one player in one column, or nil when
--- there is nothing to read.
---
--- Every step is optional and any one of them missing means "no breakdown": the
--- module may not be loaded, the build may not have GetSourceDetail, the row may
--- be a placeholder with no GUID, and the API may hand back something that is
--- not a table. Answering nil for all four keeps the two builders free of the
--- same four-way guard.
---
--- @param window table|nil
--- @param statKey string
--- @param row table|nil
--- @return table|nil
local function sourceDetailFor(window, statKey, row)
    if not (row and row.guid) then return nil end

    -- TEST ROWS ANSWER FOR THEMSELVES. The provider has nothing to say about a
    -- `Test-N` guid — correctly, there is no such source — so asking it drew
    -- "No data yet" over a grid full of numbers, which reads as a broken tooltip
    -- rather than as placeholder data.
    local A = NS.Aggregator
    if A and A.TestSourceDetail then
        local test = A.TestSourceDetail(row.guid, statKey)
        if test then return test end
    end

    local P = provider()
    local source = P and P.GetSourceDetail
        and P:GetSourceDetail(sessionTypeOf(window), statKey, row.guid, nil, sessionIDOf(window))
    if type(source) ~= "table" then return nil end
    return source
end

--- Draw the "Spell breakdown" section, and answer how many spell lines it drew.
---
--- The order is collect, then sort-if-legal, then draw: the sort is the one step
--- that may be refused mid-pull, and refusing it leaves the provider's own
--- ordering in place rather than degrading anything downstream of it.
---
--- @param source table       a DamageMeterCombatSessionSource
--- @param statKey string
--- @param cap number         the most lines this section may draw
--- @param numberStyle string|nil
--- @return number  lines drawn
local function addSpellBreakdown(source, statKey, cap, numberStyle, color, texture)
    local spells, spellTotal = collectSpells(source)
    sortSpellsIfLegal(spells)

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["Spell breakdown"], 1, 0.82, 0)

    -- The bars scale to the BIGGEST SPELL in this breakdown, not to the source's
    -- own maxAmount: a breakdown is read against itself — "which of my spells did
    -- the most" — and scaling to a column-wide max would leave every bar on a
    -- mediocre player's tooltip stubbed at one cell.
    --
    -- Taken after the sort, so it is the first entry when the sort was legal, and
    -- `source.maxAmount` when it was not. No comparison is performed here; drawBar
    -- refuses on its own if the operands cannot be divided.
    local barMax = (spells[1] and spells[1].totalAmount) or source.maxAmount

    local wantAvoidableDetail = (statKey == "AvoidableDamageTaken")
    local shown = 0
    for i = 1, #spells do
        if i > cap then break end
        addSpellLine(spells[i], numberStyle, barMax, color, texture)
        if wantAvoidableDetail then
            addAvoidableDetail(spells[i], numberStyle)
        end
        shown = i
    end

    -- SafeCount answers how many rows the array really holds without ever
    -- applying `#` to it, which is what lets this line be honest about what was
    -- left out. A nil count means "we could not see the array", and then there
    -- is nothing truthful to say.
    if spellTotal and spellTotal > shown then
        GameTooltip:AddLine(string.format(L["and %d more"], spellTotal - shown), 0.6, 0.6, 0.6)
    end

    return shown
end

--- Tell the player that the Deaths column answers a click.
---
--- It is the one cell where clicking does something other than drill down, so
--- the tooltip says so rather than leaving the player to discover it.
local function addDeathRecapHint(row, statKey)
    if statKey ~= "Deaths" then return end
    if not row or row.deathRecapID == nil then return end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["Click for details"], 0.6, 0.6, 0.6)
end

-- ---------------------------------------------------------------------------
-- Cell tooltip — the per-spell breakdown
-- ---------------------------------------------------------------------------

--- Show the spell breakdown behind one player's number in one column.
---
--- @param row table         the aggregated row under the cursor (needs .guid)
--- @param statKey string    a core/Constants.lua STATS key
--- @param anchorFrame table the cell frame the tooltip anchors to
--- @param window table|nil  the window config; looked up from row.windowId if
---                          omitted
function Tooltip:CellTooltip(row, statKey, anchorFrame, window)
    local t0 = Perf.on and debugprofilestop()

    window = resolveWindow(row, window)
    local config = tooltipConfig(window)
    -- Every bar from the previous hover comes down first: they are pooled and
    -- re-anchored, so a stale one would otherwise sit behind a line it no longer
    -- describes.
    releaseBars()
    if not openTooltip(anchorFrame, config) then return end

    local stat = Const.STAT_BY_KEY[statKey]
    GameTooltip:AddDoubleLine(displayName(row), stat and L[stat.label] or statKey,
        1, 1, 1, 1, 0.82, 0)

    local shown = 0
    local source = config.showSpells and sourceDetailFor(window, statKey, row)
    if source then
        -- The bars wear the hovered player's class color, so a tooltip reads as
        -- belonging to the row it came off. `classFilename` is NeverSecret, which
        -- is why this keeps working mid-pull when the bar LENGTHS cannot.
        local classes = _G.RAID_CLASS_COLORS
        local color = classes and row and row.classFilename and classes[row.classFilename] or nil
        -- The window's OWN bar texture, so a tooltip looks like the grid it came
        -- off rather than like a second addon.
        local media = LibStub and LibStub("LibSharedMedia-3.0", true)
        local barsCfg = (window and window.bars) or {}
        local texture = media and barsCfg.texture
            and media:Fetch("statusbar", barsCfg.texture, true) or nil

        shown = addSpellBreakdown(source, statKey, spellLineCap(config),
            numberStyleOf(window), color, texture)
    end

    if shown == 0 then
        GameTooltip:AddLine(L["No data yet"], 0.6, 0.6, 0.6)
    end

    addDeathRecapHint(row, statKey)

    GameTooltip:Show()

    if t0 then Perf.Note("tooltip", debugprofilestop() - t0) end
    if State.debug and Debug then
        Debug("Tooltip", "cell %s spells=%d", statKey, shown)
    end
end

-- ---------------------------------------------------------------------------
-- Name tooltip — every statistic for one player
-- ---------------------------------------------------------------------------

--- Which stats the hovered window has on screen, as a lookup.
---
--- Built per hover rather than cached: the column list is short, and holding a
--- cached copy would need invalidating on every column edit for no measurable
--- gain.
local function onScreenStats(window)
    local onScreen = {}
    if window and type(window.columns) == "table" then
        for i = 1, #window.columns do
            local column = window.columns[i]
            if type(column) == "table" and column.stat then onScreen[column.stat] = true end
        end
    end
    return onScreen
end

--- One line per tracked statistic, dimmed where the window is not showing that
--- column, and the count of lines drawn.
---
--- Stats the window does show are drawn in full color; the rest are dimmed, so
--- the two groups stay distinguishable without a second header.
---
--- One provider call per statistic. That is up to nine calls on a hover, and it
--- is the right trade: the totals live on the per-source read anyway, and
--- caching them would mean holding meter values across time — which is exactly
--- the thing this addon does not do.
---
--- `~= nil` is the only test applied to the amount; it then goes straight to the
--- formatter, which accepts a secret.
---
--- @param row table
--- @param window table|nil
--- @param numberStyle string|nil
--- @return number  lines drawn
local function addAllStatLines(row, window, numberStyle)
    local onScreen = onScreenStats(window)
    local rendered = 0

    for i = 1, #Const.STATS do
        local stat = Const.STATS[i]
        local source = sourceDetailFor(window, stat.key, row)
        if source and source.totalAmount ~= nil then
            local label = L[stat.label]
            if not onScreen[stat.key] then
                label = string.format("%s%s|r", GRAY, label)
            end
            GameTooltip:AddDoubleLine(label, formatNumber(source.totalAmount, numberStyle),
                1, 1, 1, 1, 1, 1)
            rendered = rendered + 1
        end
    end

    return rendered
end

--- Summarize EVERY tracked statistic for one player, including the columns this
--- window does not show.
---
--- Showing the hidden columns is the requirement, not an accident: the reason to
--- hover a name is to ask "what else did they do", and a summary limited to the
--- columns already on screen would answer nothing the grid has not answered
--- already.
---
--- @param row table
--- @param anchorFrame table
--- @param window table|nil
function Tooltip:NameTooltip(row, anchorFrame, window)
    local t0 = Perf.on and debugprofilestop()

    window = resolveWindow(row, window)
    local config = tooltipConfig(window)
    -- Every bar from the previous hover comes down first: they are pooled and
    -- re-anchored, so a stale one would otherwise sit behind a line it no longer
    -- describes.
    releaseBars()
    if not openTooltip(anchorFrame, config) then return end

    GameTooltip:AddLine(displayName(row), 1, 1, 1)

    if not config.showAllStatsOnName then
        GameTooltip:Show()
        if t0 then Perf.Note("tooltip", debugprofilestop() - t0) end
        return
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["All statistics"], 1, 0.82, 0)

    local rendered = addAllStatLines(row, window, numberStyleOf(window))

    if rendered == 0 then
        GameTooltip:AddLine(L["No data yet"], 0.6, 0.6, 0.6)
    end

    GameTooltip:Show()

    if t0 then Perf.Note("tooltip", debugprofilestop() - t0) end
    if State.debug and Debug then
        Debug("Tooltip", "name stats=%d", rendered)
    end
end

-- ---------------------------------------------------------------------------
-- Teardown
-- ---------------------------------------------------------------------------

--- Close whatever this module opened. Wired to every cell's OnLeave.
---
--- Unconditional rather than "hide it if we own it": GameTooltip is shared, and
--- a hide the addon did not need to do is invisible, whereas a tooltip left
--- pinned under the cursor after the mouse has moved is the single most
--- reported meter bug there is.
function Tooltip:Hide()
    if _G.GameTooltip then GameTooltip:Hide() end
end
