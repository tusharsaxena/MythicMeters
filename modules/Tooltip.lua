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

--- One spell's share of the player's total for this column, as trailing text.
---
--- A SHARE IS A DIVISION, so this is the one slot on a spell line that cannot
--- survive a pull. modules/Format.lua's ratio form asks core/Secrets.lua whether
--- the two operands may be divided and answers an EMPTY STRING when they may
--- not — so mid-pull the percentages simply are not there, and the amount beside
--- them is unaffected. That is the intended behaviour, not a degraded one: the
--- alternative is approximating a number the client will not let us compute.
---
--- The empty answer must never be read as "0%". It is returned as "" precisely so
--- that a caller appends nothing rather than appending a lie.
---
--- @param value any   this spell's amount, possibly secret
--- @param total any   the player's total for this column, possibly secret
--- @return string     "" when the division is not permitted
local function formatShare(value, total)
    local F = NS.Numbers or (NS.GetModule and NS:GetModule("Format", true))
    if not (F and F.Percent) then return "" end
    return F.Percent(value, total) or ""
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
-- THE SPELL LINE: A BAR, AND TWO FIXED NUMBER SLOTS
-- ---------------------------------------------------------------------------
--
-- A GameTooltip line is TEXT. `|T…|t` embeds a texture but carries no tint, and
-- there is no markup that colors one — so the first attempt was a run of block
-- glyphs (not in the game font, drew boxes) and the second was a run of `=`
-- (legible, and obviously not a bar).
--
-- The real thing is a WIDGET PER LINE, pooled and re-anchored per hover rather
-- than created per line. Each pooled entry is a carrier Frame holding three
-- things:
--
--   * a StatusBar spanning the line, wearing the window's own bar texture and
--     the player's class color, filled to amount/max;
--   * the AMOUNT, right-aligned in a fixed-width slot;
--   * the SHARE, right-aligned in a second fixed-width slot beside it.
--
-- WHY THE NUMBERS LEFT THE TOOLTIP'S OWN RIGHT COLUMN. AddDoubleLine right-aligns
-- one string, so "5.7M 36.5%" and "398.9K 2.1%" line up at their right edge and
-- nowhere else — the percent column zig-zags, because the amount before it is a
-- different width on every row. Two right-aligned FontStrings at FIXED PIXEL
-- OFFSETS are the only way to get two columns out of one line, and the font is
-- proportional so padding with spaces cannot substitute.
--
-- WHY A CARRIER RATHER THAN HANGING THEM OFF THE BAR. The bar is absent whenever
-- the values may not be divided (see below) and the NUMBERS MUST NOT BE. Hanging
-- them off the bar would delete the tooltip's entire content mid-pull, which is
-- the exact inversion of the rule: a restricted tooltip loses decoration, never
-- information. So the carrier is always shown and the bar inside it is not.
--
-- GEOMETRY MATCHES THE GRID. A line spans from just past the icon out to the
-- tooltip's right margin, and the FILL inside it is amount/max, exactly like a
-- cell in modules/Row.lua. Every line's track is therefore the same length and
-- the fills are what differ — which is the only way a length can mean anything.
-- It starts past the icon so the icon reads as its own column and is not tinted,
-- and the spell NAME sits fully inside the track.
--
-- LAYERING. The carrier and the bar sit at the tooltip's OWN frame level, which
-- makes their draw layers interleave with the tooltip's rather than stack above
-- them. Track is BACKGROUND, fill is BORDER, GameTooltip draws its line
-- FontStrings in ARTWORK, and the two number slots are OVERLAY. So the spell name
-- lands on top of the bar and the numbers land on top of everything.
--
-- Everything comes down whenever the tooltip does — see `ensureTooltipHook` — so
-- a stale line can never outlive the hover that drew it.

--- The line height a bar has to cover. The icon is the tallest thing on a spell
--- line, so it sets the height; anything shorter leaves the line's text hanging
--- off the top and bottom of its own bar.
local BAR_HEIGHT = TOOLTIP_ICON_SIZE

--- Fallback fill for a window with no bar texture configured. A StatusBar with
--- no texture draws NOTHING, so the tint alone is not enough.
local BAR_FALLBACK_TEXTURE = "Interface\\Buttons\\WHITE8X8"

--- How far past the left FontString's edge the track starts.
---
--- The spell icon is not a separate widget — it is a `|T…|t` escape INSIDE the
--- left line, so the FontString's left edge is the icon's left edge. A track
--- pinned there runs underneath the icon and tints it. Clearing exactly the icon
--- puts the track's edge in the space between icon and name, which leaves the
--- NAME fully inside the bar — the point of a full-width bar in the first place.
local BAR_INSET_LEFT = TOOLTIP_ICON_SIZE

--- The two number slots, in pixels, measured in from the line's right edge.
---
--- FIXED, and never measured off a widget. A slot sized from the text it holds
--- would have to read a FontString that has been handed a meter amount, and a
--- widget that has held a secret has secret geometry (rule R3). Fixed slots also
--- happen to be the requirement: they are what makes the column a column.
---
--- SHARE_SLOT_WIDTH fits "xx.x%" — the widest share there is, since a share
--- cannot exceed 100% and 100.0% is rendered at the same five glyphs.
local SLOT_RIGHT_PAD    = 3
local SHARE_SLOT_WIDTH  = 36
local SLOT_GAP          = 6
local AMOUNT_SLOT_WIDTH = 66

--- Breathing room between the longest spell name and the amount slot.
local NAME_GAP = 10

--- What GameTooltip adds around its own content, left and right together. Used
--- only to widen the tooltip, never to place anything.
local TOOLTIP_H_PADDING = 20

--- The white the share is drawn in, and the gold the amount keeps.
local AMOUNT_COLOR = { 1, 0.82, 0 }
local SHARE_COLOR  = { 1, 1, 1 }

local linePool = {}

--- The widest spell name this hover has drawn, in pixels, and the tooltip width
--- that implies. Reset per hover by `releaseLines`.
local widestName = 0

--- Take every line down, and put GameTooltip back the way it was found.
---
--- `pairs`, NOT `ipairs`. The pool is keyed by TOOLTIP LINE INDEX, and a spell
--- line is never line 1 — the header, the blank and the "Spell breakdown" caption
--- come first, so the first key is 4. `ipairs` stops at the hole at index 1 and
--- releases NOTHING, which is what left bars Shown on a recycled GameTooltip.
---
--- The bar is hidden alongside its carrier rather than left to the carrier's
--- visibility, so "is this bar showing" stays a question the widget itself can
--- answer.
---
--- The minimum width is cleared too. It is a property of the SHARED tooltip, so
--- leaving ours on it makes the next addon's item tooltip inexplicably wide —
--- the same class of bug as a bar left Shown.
local function releaseLines()
    for _, frame in pairs(linePool) do
        frame.bar:Hide()
        frame:Hide()
    end
    widestName = 0
    if _G.GameTooltip and GameTooltip.SetMinimumWidth then
        GameTooltip:SetMinimumWidth(0)
    end
end

-- ---------------------------------------------------------------------------
-- WHY THE LINES MUST COME DOWN WITH THE TOOLTIP
-- ---------------------------------------------------------------------------
--
-- GameTooltip is SHARED and RECYCLED. Hiding it does not un-Show the frames
-- parented to it — it only stops them being drawn — so a widget left Shown
-- reappears the instant anything else opens GameTooltip: a unit under the cursor,
-- an item, a quest. And because the lines are anchored to GameTooltipTextLeft<N>,
-- they re-anchor themselves onto WHATEVER that tooltip's lines now say, which is
-- how this addon put class-colored bars through the middle of a player's unit
-- tooltip and an item's stat block.
--
-- Releasing at the top of our own hovers is not enough: nothing routes another
-- addon's tooltip through this file. The only reliable signal is GameTooltip's
-- own OnHide, hooked once, for the life of the session.
local tooltipHooked = false

--- Hook GameTooltip:OnHide once, so the pool empties however the tooltip closes.
local function ensureTooltipHook()
    if tooltipHooked then return end
    local tip = _G.GameTooltip
    if not (tip and tip.HookScript) then return end
    tip:HookScript("OnHide", releaseLines)
    tooltipHooked = true
end

--- The nth pooled line's carrier frame, created on first use. Its bar and its two
--- number slots hang off it under `.bar`, `.amount` and `.share`.
local function lineWidget(index)
    local line = linePool[index]
    if line then return line end
    -- First line of the session is also the moment the pool starts needing the
    -- OnHide hook, and the earliest point in this file that can install it.
    ensureTooltipHook()

    local frame = CreateFrame("Frame", nil, GameTooltip)
    frame:SetHeight(BAR_HEIGHT)
    -- The tooltip's own level, NOT one above it: see the layering note above.
    frame:SetFrameLevel(GameTooltip:GetFrameLevel())

    local b = CreateFrame("StatusBar", nil, frame)
    b:SetAllPoints(frame)
    b:SetFrameLevel(frame:GetFrameLevel())
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(b)
    bg:SetColorTexture(0, 0, 0, 0.35)
    b.bg = bg

    -- Right to left: the share is pinned to the line's right edge, and the amount
    -- to the share's left edge. Both are right-justified inside a fixed width, so
    -- both columns line up down the tooltip whatever the numbers are.
    local share = frame:CreateFontString(nil, "OVERLAY", "GameTooltipText")
    share:SetWidth(SHARE_SLOT_WIDTH)
    share:SetJustifyH("RIGHT")
    share:SetPoint("RIGHT", frame, "RIGHT", -SLOT_RIGHT_PAD, 0)
    share:SetTextColor(SHARE_COLOR[1], SHARE_COLOR[2], SHARE_COLOR[3])

    local amount = frame:CreateFontString(nil, "OVERLAY", "GameTooltipText")
    amount:SetWidth(AMOUNT_SLOT_WIDTH)
    amount:SetJustifyH("RIGHT")
    amount:SetPoint("RIGHT", share, "LEFT", -SLOT_GAP, 0)
    amount:SetTextColor(AMOUNT_COLOR[1], AMOUNT_COLOR[2], AMOUNT_COLOR[3])

    -- Keyed onto the carrier the way Blizzard's own `parentKey` does, so the
    -- pool holds one object rather than a record of four.
    frame.bar, frame.amount, frame.share = b, amount, share
    linePool[index] = frame
    return frame
end

--- Widen the tooltip enough that the two number slots never sit on a spell name.
---
--- GameTooltip sizes itself from its own text, and our numbers are not its text
--- any more — so without this the tooltip shrinks to the width of the names and
--- the slots overlap them. A MINIMUM is exactly the right instrument: a longer
--- header line still wins, and nothing here shrinks the tooltip.
---
--- The name width is read off GameTooltip's own left FontString for a SPELL line,
--- which holds an icon escape and a spell name and has never been handed a meter
--- amount. Rule R3 is about widgets that HAVE held one — and note this is
--- deliberately not read off our own amount slot, which has.
local function applyMinimumWidth()
    if widestName <= 0 then return end
    if not (_G.GameTooltip and GameTooltip.SetMinimumWidth) then return end
    GameTooltip:SetMinimumWidth(widestName + NAME_GAP + AMOUNT_SLOT_WIDTH
        + SLOT_GAP + SHARE_SLOT_WIDTH + TOOLTIP_H_PADDING)
end

--- Lay out one spell line and fill in its numbers.
---
--- THE BAR IS ABSENT WHILE THE VALUES CANNOT BE DIVIDED. A bar's length is
--- amount / max, which raises on two secrets, so it is drawn when core/Secrets.lua
--- says both operands are readable and omitted when they are not — exactly like
--- the share slot. THE AMOUNT NEVER GOES AWAY: it is set on the widget as
--- whatever the formatter returned, secret or not, so a mid-pull tooltip loses
--- decoration rather than information.
---
--- @param lineIndex number   which tooltip line this sits on
--- @param amount any         the formatted amount, possibly a secret string
--- @param share string       the formatted share, or "" when it may not be taken
--- @param value any          the spell's raw total, possibly secret
--- @param max any            the largest total in this breakdown, possibly secret
--- @param color table|nil    { r, g, b }
--- @param texture string|nil an LSM statusbar path
local function drawLine(lineIndex, amount, share, value, max, color, texture)
    local name = GameTooltip:GetName()
    local left = name and _G[name .. "TextLeft" .. lineIndex]
    if not left then return end

    local frame = lineWidget(lineIndex)
    frame:ClearAllPoints()
    -- Past the icon on the left, out to the tooltip's own right margin on the
    -- right. Anchoring the right edge to GameTooltip rather than to the line's
    -- right FontString keeps the track a fixed span even though that FontString is
    -- now empty — the numbers moved onto this carrier.
    frame:SetPoint("LEFT", left, "LEFT", BAR_INSET_LEFT, 0)
    frame:SetPoint("RIGHT", GameTooltip, "RIGHT", -(TOOLTIP_H_PADDING / 2), 0)
    frame:Show()

    frame.amount:SetText(amount)
    frame.share:SetText(share)

    if left.GetStringWidth then
        local w = left:GetStringWidth() or 0
        if w > widestName then widestName = w end
    end

    local Secrets = NS.Secrets
    if not (Secrets and Secrets.CanCompare2 and Secrets.CanCompare2(value, max)) then
        frame.bar:Hide()
        return
    end
    if type(value) ~= "number" or type(max) ~= "number" or max <= 0 then
        frame.bar:Hide()
        return
    end

    local b = frame.bar
    b:SetStatusBarTexture(texture or BAR_FALLBACK_TEXTURE)
    -- BORDER, so the tooltip's ARTWORK spell name reads on top of the fill rather
    -- than under it. SetStatusBarTexture replaces the texture object, so the layer
    -- has to be re-stated every draw and not once at creation.
    local fill = b.GetStatusBarTexture and b:GetStatusBarTexture()
    if fill and fill.SetDrawLayer then fill:SetDrawLayer("BORDER") end
    b:SetMinMaxValues(0, max)
    b:SetValue(value)
    b:SetStatusBarColor((color and color.r) or 0.6, (color and color.g) or 0.6,
        (color and color.b) or 0.6, 0.85)
    b:Show()
end

local function addSpellLine(spell, numberStyle, max, color, texture, sourceTotal)
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

    -- The amount and the share go onto our OWN widgets, in their own fixed slots,
    -- so this line is added with a LEFT SIDE ONLY. Handing them to AddDoubleLine
    -- instead would right-align the pair as one string and the share column would
    -- zig-zag behind amounts of different widths.
    --
    -- Neither is inspected on the way. `formatNumber` may hand back the ORIGINAL
    -- OPAQUE VALUE when no formatter is reachable; it travels to SetText, which is
    -- a widget setter and accepts a secret.
    GameTooltip:AddLine(label, 1, 1, 1)

    local amount = formatNumber(spell.totalAmount, numberStyle)
    local share = sourceTotal ~= nil and formatShare(spell.totalAmount, sourceTotal) or ""

    -- The line widget goes BEHIND the tooltip line that was just added, so it
    -- needs that line's index — which is NumLines now that the line exists.
    drawLine(GameTooltip:NumLines(), amount, share, spell.totalAmount, max,
        color, texture)
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
    -- `source.maxAmount` when it was not. No comparison is performed here; drawLine
    -- refuses to fill on its own if the operands cannot be divided.
    local barMax = (spells[1] and spells[1].totalAmount) or source.maxAmount

    local wantAvoidableDetail = (statKey == "AvoidableDamageTaken")
    local shown = 0
    for i = 1, #spells do
        if i > cap then break end
        addSpellLine(spells[i], numberStyle, barMax, color, texture, source.totalAmount)
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
    -- Every line widget from the previous hover comes down first: they are pooled
    -- and re-anchored, so a stale one would otherwise sit behind a tooltip line it
    -- no longer describes.
    releaseLines()
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

    -- After every line, before the Show that sizes the frame: the number slots are
    -- our widgets, so GameTooltip cannot size itself around them.
    applyMinimumWidth()

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
    -- Every line widget from the previous hover comes down first: they are pooled
    -- and re-anchored, so a stale one would otherwise sit behind a tooltip line it
    -- no longer describes.
    releaseLines()
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
    -- Unconditionally, and BEFORE the hide: the OnHide hook covers every other
    -- route out, but only once a hover has opened a tooltip and installed it.
    releaseLines()
    if _G.GameTooltip then GameTooltip:Hide() end
end
