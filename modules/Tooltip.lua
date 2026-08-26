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
--- Whether a value is present and may NOT be read.
---
--- Distinct from `plainWord` answering nil, which also covers "there is nothing
--- here". A caption that is absent costs a column nothing; one that is secret
--- costs the whole measurement.
local function unreadable(v)
    if v == nil then return false end
    local S = NS.Secrets
    return (S and S.CanAccess and not S.CanAccess(v)) and true or false
end

--- A string this code may compare, or nil.
---
--- The recap's `event` field decides whether a line is a swing or a heal, and a
--- comparison against a secret raises. nil means "cannot tell", which lands on
--- the ordinary path.
local function plainWord(v)
    if v == nil then return nil end
    local S = NS.Secrets
    if S and S.CanAccess and not S.CanAccess(v) then return nil end
    if type(v) ~= "string" then return nil end
    return v
end

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
        offsetX            = field("offsetX", 0),
        offsetY            = field("offsetY", 0),
        showSpells         = field("showSpells", true),
        maxSpells          = field("maxSpells", 10),
        showAllStatsOnName = field("showAllStatsOnName", true),
        hideInCombat       = field("hideInCombat", false),
        textColor          = field("textColor", nil),
        barTexture         = field("barTexture", "Blizzard Raid Bar"),
        barSpacing         = field("barSpacing", 1),
        barBorderStyle     = field("barBorderStyle", "None"),
        barBorderSize      = field("barBorderSize", 1),
        barBorderColor     = field("barBorderColor", nil),
        font               = field("font", "Friz Quadrata TT"),
        fontSize           = field("fontSize", 12),
        fontOutline        = field("fontOutline", "NONE"),
        showTargets        = field("showTargets", false),
        maxTargets         = field("maxTargets", 3),
    }
end

-- ---------------------------------------------------------------------------
-- Media
-- ---------------------------------------------------------------------------

local function lsm()
    return LibStub and LibStub("LibSharedMedia-3.0", true)
end

--- An LSM path, or nil. Nil is a real answer everywhere it is used here: a
--- StatusBar with no texture falls back to BAR_FALLBACK_TEXTURE, and a backdrop
--- with no edgeFile draws no border, which is what "None" has to mean.
local function mediaPath(mediaType, name)
    if type(name) ~= "string" or name == "" or name == "None" then return nil end
    local media = lsm()
    return media and media:Fetch(mediaType, name, true) or nil
end

--- The font this tooltip draws in: a path, a size, and the flag string WoW wants
--- as nil rather than as the literal "NONE".
---
--- The path falls all the way back to the client's own standard face rather than
--- to nil, because a FontString with NO font raises on SetText — and every
--- caller here sets text immediately afterwards.
---
--- @param config table
--- @return string path, number size, string|nil flags
local function tooltipFont(config)
    local path = mediaPath("font", config.font)
        or Const.FONT_MONO or _G.STANDARD_TEXT_FONT
    local size = config.fontSize
    if type(size) ~= "number" or size < 1 then size = 12 end
    local flags = (config.fontOutline ~= "NONE") and config.fontOutline or nil
    return path, size, flags
end

--- A color table's four channels, with a fallback per channel.
local function rgba(color, dr, dg, db, da)
    if type(color) ~= "table" then return dr, dg, db, da end
    return color.r or dr, color.g or dg, color.b or db, color.a or da
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
--- ZERO MEANS EVERY SPELL, and the honest value of "every" is COLLECT_LIMIT:
--- `collectSpells` never pulls more than that however this is set, so returning
--- anything larger would be a cap that lies about itself. Nothing is hidden by
--- the difference — the "and N more" line counts what was left out with
--- SafeCount and keeps saying so.
---
--- Everything else is clamped rather than trusted, because `maxSpells` comes off
--- a saved profile that an older build — or a hand edit — may have left as a
--- string or as a negative. The shipped default is the answer in both cases.
local function spellLineCap(config)
    local cap = config.maxSpells
    if cap == 0 then return COLLECT_LIMIT end
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
--
-- ANCHOR_NONE and ANCHOR_PRESERVE are deliberately absent. Both mean "the owner
-- places the tooltip itself", and placing it ourselves would mean computing a
-- point from the anchor frame — which is the read rule R3 forbids.
local ANCHOR_TOKENS = {
    CURSOR      = "ANCHOR_CURSOR",
    TOP         = "ANCHOR_TOP",
    BOTTOM      = "ANCHOR_BOTTOM",
    LEFT        = "ANCHOR_LEFT",
    RIGHT       = "ANCHOR_RIGHT",
    TOPLEFT     = "ANCHOR_TOPLEFT",
    TOPRIGHT    = "ANCHOR_TOPRIGHT",
    BOTTOMLEFT  = "ANCHOR_BOTTOMLEFT",
    BOTTOMRIGHT = "ANCHOR_BOTTOMRIGHT",
}

--- An offset that is safe to hand to SetOwner: a real number, bounded to the
--- range the schema offers. A saved profile carrying a string here would
--- otherwise raise inside Blizzard's own code, where the traceback names
--- neither this file nor the setting.
local function offset(v)
    if type(v) ~= "number" then return 0 end
    if v < -400 then return -400 end
    if v > 400 then return 400 end
    return v
end

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

    -- The offsets are passed to SetOwner rather than applied afterwards with a
    -- SetPoint of our own: the client still does the placing, and it still keeps
    -- the tooltip on screen. Nudging it ourselves would mean reading a point back
    -- off a frame that has held a secret (rule R3).
    GameTooltip:SetOwner(anchorFrame, ANCHOR_TOKENS[config.anchor] or "ANCHOR_CURSOR",
        offset(config.offsetX), offset(config.offsetY))
    GameTooltip:ClearLines()

    -- Line spacing is a property of the SHARED tooltip, like the minimum width,
    -- so releaseLines puts it back. Guarded because it arrived with the modern
    -- tooltip template and this addon still loads on a client without it.
    if GameTooltip.SetCustomLineSpacing then
        local spacing = config.barSpacing
        if type(spacing) ~= "number" or spacing < 0 then spacing = 0 end
        GameTooltip:SetCustomLineSpacing(spacing)
    end
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
--- SHARE_SLOT_WIDTH is a FLOOR rather than the whole answer. It was sized for
--- "xx.x%" on the reasoning that a share cannot exceed 100% and so cannot get
--- wider — which is wrong twice over: `Format.Percent` renders "%.1f%%", so a
--- full share is "100.0%" at SIX glyphs, and the tooltip font is configurable,
--- so any fixed pixel count clips at a large enough size. A capped row showed as
--- "100...." on screen. The drawn width is measured per font by `shareSlotWidth`
--- and this is what a client that refuses the measurement falls back to.
local SLOT_RIGHT_PAD    = 3
local SHARE_SLOT_WIDTH  = 44
local SLOT_GAP          = 6
local AMOUNT_SLOT_WIDTH = 66

--- The widest share there is, and therefore what the share slot must hold.
local SHARE_WIDEST = "100.0%"


--- Where a target's name starts inside its carrier.
---
--- The carrier's left edge already sits one icon past the line's left edge
--- (BAR_INSET_LEFT), and a spell name additionally clears the single space in
--- its own format string. This is that space, so a target name and a spell name
--- share an x.
local LABEL_INSET_LEFT = 4

--- How many characters of spell name the tooltip reserves room for.
---
--- DELIBERATELY NOT A SETTING, and deliberately not the grid's own
--- `Const.NAME_COLUMN_WIDTH`. The window's name column holds a player name and
--- this holds a spell name, which is a much longer thing — "Fury of the Storm
--- Elemental" does not fit where "Traxex" does — so the two are sized apart on
--- purpose and neither should drift into the other.
local NAME_COLUMN_CHARS = 25

-- THE DEATH TOOLTIP'S OWN COLUMNS, in characters, reserved exactly the way
-- NAME_COLUMN_CHARS is and for the same reason: a spell name and a caster name
-- are both resolved off ids the client can hand back SECRET, and measuring one
-- to size its column is the inspection rule R3 forbids. So each column is a
-- reservation at the configured font and the engine clips into it. Nothing here
-- cuts a string up — `string.sub` on a secret raises, and a truncation this code
-- performed would be an inspection besides.
local EVENT_SPELL_CHARS  = 22
-- A caster name is shorter than a spell name in nearly every case. Widened
-- again after 13 clipped "Grizzled Warbringer" a good deal earlier than the
-- column's own width suggested it would -- these are 'n' widths, and a name
-- full of wide glyphs runs out of room sooner than the reservation implies.
local EVENT_CASTER_CHARS = 16

-- The floor for the time column, and only the floor: the real width is measured
-- from the times actually in the recap being drawn. They are numbers this addon
-- computed, so measuring them is legal — unlike the names beside them.
local EVENT_TIME_WIDEST = "-9.9s"

-- The melee swing's own icon, the one Blizzard's recap uses. A swing carries no
-- spellId at all, so there is nothing to resolve one from.
local MELEE_ICON = 135274

-- inv_misc_bone_skull_03. Every line of a Deaths cell's tooltip is a death, so
-- they all wear the same icon — its job is to hold the column where every other
-- tooltip in the addon puts a spell icon, not to tell one row from another.
local DEATH_ICON = 237275

-- The widest a wall clock reads. The other two styles are shorter.
local DEATH_CLOCK_WIDEST = "00:00:00"

--- Rough width of one character, as a fraction of the font's point size.
---
--- A FALLBACK ONLY. The span above is measured properly on `measureText`; this
--- is what a client that refuses the measurement gets instead. 0.55 is a
--- middling ratio for the faces LSM ships, and it runs short on a narrow face —
--- which is survivable here and was not survivable when it sized a real name,
--- because the result is only ever a MINIMUM.
local NAME_WIDTH_PER_CHAR = 0.55

--- Breathing room between the name column and the amount slot.
local NAME_GAP = 10

--- What GameTooltip adds around its own content, left and right together. Used
--- only to widen the tooltip, never to place anything.
local TOOLTIP_H_PADDING = 20

--- The fallback for both number slots when no color is configured.
---
--- They used to be two constants — a gold amount and a white share — which read
--- as two kinds of number when they are one row's two figures. One color now,
--- and it is a setting.
local SLOT_COLOR_DEFAULT = { 1, 1, 1 }

local linePool = {}

-- ---------------------------------------------------------------------------
-- THE FONT, AND WHY IT HAS TO BE PUT BACK
-- ---------------------------------------------------------------------------
--
-- Our two number slots are our own FontStrings and may be set to anything. The
-- SPELL NAME is not: it is GameTooltipTextLeft<N>, which belongs to the SHARED
-- GameTooltip, and the tooltip is recycled by every addon and every unit, item
-- and quest hover in the game. A SetFont left on one is not a cosmetic leak —
-- it is this addon silently restyling somebody else's tooltip, and it survives
-- until a reload.
--
-- So every line index this hover wrote a font onto is recorded, and each one is
-- put back with SetFontObject("GameTooltipText") — the font object the real ones
-- inherit, which restores face, size and flags in one call rather than
-- reconstructing three values we would have had to read back off the widget.
--
-- `restoreFonts` runs from `releaseLines`, which is already wired to
-- GameTooltip's own OnHide — so it covers every route out of a hover, including
-- the ones that do not come back through this file.
local fontedLines = {}


--- What the font probe saw on the last spell line drawn, or nil.
---
--- Populated ONLY while the debug flag is on, and read by core/Diagnostics.lua.
--- It exists because "the spell name kept the game's font" has two completely
--- different causes — our SetFont was refused, or something after us put the font
--- back — and no screenshot can tell them apart. The probe samples the SAME
--- FontString twice, once immediately after we set it and once after
--- GameTooltip:Show() has laid the tooltip out, which is the only step between
--- the two that could revert it.
Tooltip.__fontProbe = nil

--- Give one tooltip line our font, and remember that we did.
---
--- The record keeps the font PER LINE rather than one font for the hover,
--- because they are not all the same: a section gap gets the same face at half
--- the size, and a single remembered font would have the post-layout pass stamp
--- full size back over it and quietly restore the gap this addon just halved.
local function applyLineFont(fontString, index, path, size, flags)
    if not (fontString and fontString.SetFont) then return end
    fontString:SetFont(path, size, flags)
    fontedLines[index] = { fs = fontString, path = path, size = size, flags = flags }

    if State.debug and fontString.GetFont then
        local gotPath, gotSize, gotFlags = fontString:GetFont()
        Tooltip.__fontProbe = {
            index     = index,
            line      = fontString,
            askedPath = path, askedSize = size, askedFlags = flags,
            setPath   = gotPath, setSize = gotSize, setFlags = gotFlags,
        }
    end
end

--- Re-read the probed line after the tooltip has been shown and laid out.
local function sampleFontAfterShow()
    local probe = Tooltip.__fontProbe
    if not (probe and probe.line and probe.line.GetFont) then return end
    probe.showPath, probe.showSize, probe.showFlags = probe.line:GetFont()
end

--- Add the gap that separates one tooltip section from the next.
---
--- A blank AddLine is a WHOLE line of the tooltip's font, which is more air than
--- a section break needs — it read as a paragraph gap above "Spell breakdown"
--- and again above "Targets". There is no half-line in GameTooltip, but a line's
--- HEIGHT follows its font, so the spacer is given the configured font at half
--- size and takes half the room.
---
--- It goes through `applyLineFont` like every other line we touch, so it is
--- restored with them — a shrunken font left on a shared line is the same leak
--- as any other, and it would land on whatever the next addon puts there.
---
--- @param style table  a resolved style from `lineStyle`
local function addSectionGap(style)
    GameTooltip:AddLine(" ")
    local name = GameTooltip:GetName()
    local index = GameTooltip:NumLines()
    local left = name and _G[name .. "TextLeft" .. index]
    if not left then return end

    local half = math.floor((style.fontSize or 12) / 2)
    if half < 1 then half = 1 end
    applyLineFont(left, index, style.fontPath, half, style.fontFlags)
end

--- Put our font back on every line, AFTER GameTooltip:Show() has laid out.
---
--- ---------------------------------------------------------------------------
--- WHY THE FONT IS SET TWICE
--- ---------------------------------------------------------------------------
---
--- Setting it once, before Show, is the obvious thing and it does not hold. The
--- probe in `applyLineFont` measured it on a live client: the SetFont takes
--- (`asked 10/OUTLINE` reads back as `10/OUTLINE`), and after Show the SAME
--- FontString reads `11/no flags`. Something in the show path re-fonts the
--- tooltip's lines.
---
--- That something is very often not Blizzard: a UI skin that restyles
--- GameTooltip hooks OnShow and re-applies its own face to every line. On the
--- client this was measured on, the PATH survived and only the size and flags
--- changed — which is the signature of a skin re-applying the same font at its
--- own size, not of a reset to the stock font object.
---
--- So the first pass (in `drawLine`) is what makes the width measurement honest,
--- and this second pass is what the player actually sees. Show is NOT called
--- again afterwards: whatever re-fonts on show would simply run again and undo
--- this, and the tooltip is already sized — `applyMinimumWidth` ran before Show
--- and a smaller font only ever leaves slack.
local function reapplyFonts()
    for _, entry in pairs(fontedLines) do
        if entry.fs.SetFont then
            entry.fs:SetFont(entry.path, entry.size, entry.flags)
        end
    end
    sampleFontAfterShow()
end

--- Put every line this hover restyled back onto the game's own tooltip font.
local function restoreFonts()
    for index, entry in pairs(fontedLines) do
        local fontString = entry.fs
        if fontString.SetFontObject and _G.GameTooltipText then
            fontString:SetFontObject(_G.GameTooltipText)
        end
        fontedLines[index] = nil
    end
end

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
    restoreFonts()
    if _G.GameTooltip and GameTooltip.SetMinimumWidth then
        GameTooltip:SetMinimumWidth(0)
    end
    -- Line spacing belongs to the shared tooltip too, and a value left on it is
    -- the same class of bug as a bar left Shown: the next addon's item tooltip
    -- inherits our spacing for no reason it can discover.
    if _G.GameTooltip and GameTooltip.SetCustomLineSpacing then
        GameTooltip:SetCustomLineSpacing(0)
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

    -- BackdropTemplate for the optional LSM border. Asked for at CREATION, since
    -- a template cannot be added to a frame afterwards — so a player who turns
    -- the border on mid-session gets it on lines that were pooled before they
    -- did. Nothing is read back off the backdrop; it is set and forgotten, which
    -- is what keeps it clear of rule R3.
    local frame = CreateFrame("Frame", nil, GameTooltip, "BackdropTemplate")
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


    -- The LABEL slot, used by target lines and left empty by spell lines.
    --
    -- A target has no icon — a unit is not a spell — but its name still has to
    -- start where a spell NAME starts, not where a spell ICON starts, or the two
    -- sections read as two different tables. There is no way to indent
    -- GameTooltip's own line text (a `|T…|t` spacer needs a transparent texture
    -- to point at, and padding with spaces is font-dependent), so the name goes
    -- on OUR carrier instead — which is already anchored past the icon, wears the
    -- configured font for free, and can be placed to the pixel.
    --
    -- Bounded on the right by the amount slot so a long unit name is clipped
    -- rather than drawn underneath the numbers.
    local label = frame:CreateFontString(nil, "OVERLAY", "GameTooltipText")
    label:SetJustifyH("LEFT")
    label:SetPoint("LEFT", frame, "LEFT", LABEL_INSET_LEFT, 0)

    local amount = frame:CreateFontString(nil, "OVERLAY", "GameTooltipText")
    amount:SetWidth(AMOUNT_SLOT_WIDTH)
    amount:SetJustifyH("RIGHT")
    amount:SetPoint("RIGHT", share, "LEFT", -SLOT_GAP, 0)


    -- Keyed onto the carrier the way Blizzard's own `parentKey` does, so the
    -- pool holds one object rather than a record of four.
    label:SetPoint("RIGHT", amount, "LEFT", -SLOT_GAP, 0)

    -- TWO MORE SLOTS, USED ONLY BY THE DEATH BRANCH. They are created for every
    -- carrier rather than lazily because the pool never destroys one: a carrier
    -- that grew slots on its first event line would be a different object from
    -- one that had only ever drawn spells, and the layout below would have to
    -- test for that on every draw.
    --
    -- Their placement and width are stated per draw, in `applySlotLayout`, and
    -- NOT here — the carrier drawing line 4 of this hover drew line 4 of the
    -- last one, so anything set once at creation is a stale value waiting to
    -- happen.
    local time = frame:CreateFontString(nil, "OVERLAY", "GameTooltipText")
    time:SetJustifyH("RIGHT")
    if time.SetWordWrap then time:SetWordWrap(false) end

    local caster = frame:CreateFontString(nil, "OVERLAY", "GameTooltipText")
    caster:SetJustifyH("LEFT")
    if caster.SetWordWrap then caster:SetWordWrap(false) end
    if label.SetWordWrap then label:SetWordWrap(false) end

    frame.bar, frame.amount, frame.share, frame.label = b, amount, share, label
    frame.time, frame.caster = time, caster
    linePool[index] = frame
    return frame
end


--- A hidden FontString kept solely to measure text, OUTSIDE GameTooltip.
---
--- IT ONLY EVER SEES A CONSTANT OF OURS. An earlier version measured the spell
--- captions on it, which is what the note on `applyMinimumWidth` describes as
--- having failed: a caption can be secret, and a secret measured is a secret
--- back. Everything it is given now is a literal in this file, so the width it
--- answers is an ordinary number and rule R3 is not in play — the ruler is
--- parentless, never placed inside the tooltip, and has never been handed a
--- meter value.
local ruler = nil

--- The width of one PLAIN string at one font, or nil if unmeasurable.
---
--- @param text string  a literal of ours — never a caption, never a meter value
local function measureText(text, path, size, flags)
    if not ruler then
        local host = CreateFrame("Frame")
        host:Hide()
        ruler = host:CreateFontString(nil, "OVERLAY")
    end
    if not ruler.SetFont then return nil end
    ruler:SetFont(path, size, flags)
    ruler:SetText(text)
    local ok, w = pcall(ruler.GetStringWidth, ruler)
    if not ok or type(w) ~= "number" then return nil end
    return w
end

--- The width of N characters at one font, for a reserved column.
local function charSpan(chars, path, size, flags)
    return measureText(string.rep("n", chars), path, size, flags)
        or (chars * size * NAME_WIDTH_PER_CHAR)
end

--- Place the carrier's text slots for the kind of line about to be drawn.
---
--- STATED ON EVERY DRAW, BOTH WAYS. The pool keys a carrier by tooltip line
--- index, so the frame drawing line 4 of this hover is the one that drew line 4
--- of the last one — and an event line narrows the name column and shows two
--- extra slots. A spell line that inherited either would render its name into a
--- 22-character box with a stray time beside it.
---
--- @param frame table   a pooled carrier
--- @param style table
--- @param mode string|nil  nil for an ordinary line, "event" for a recap event,
---   "clock" for a death in a Deaths cell's list
local function applySlotLayout(frame, style, mode)
    local path, size, flags = style.fontPath, style.fontSize, style.fontFlags
    local label = frame.label

    label:ClearAllPoints()
    frame.share:ClearAllPoints()
    frame.share:Show()
    frame.share:SetPoint("RIGHT", frame, "RIGHT", -SLOT_RIGHT_PAD, 0)
    frame.amount:ClearAllPoints()
    frame.amount:SetPoint("RIGHT", frame.share, "LEFT", -SLOT_GAP, 0)
    frame.amount:SetWidth(AMOUNT_SLOT_WIDTH)

    if mode == "clock" then
        -- ONE FIGURE, AT THE RIGHT EDGE. A death has no share, and leaving the
        -- empty share slot in place held the time a whole column short of the
        -- bar's edge while every other tooltip's rightmost figure sits against
        -- it. So the share comes down and the amount takes its place.
        frame.time:Hide()
        frame.caster:Hide()
        frame.share:Hide()
        frame.amount:ClearAllPoints()
        frame.amount:SetPoint("RIGHT", frame, "RIGHT", -SLOT_RIGHT_PAD, 0)
        frame.amount:SetWidth((measureText(DEATH_CLOCK_WIDEST, path, size, flags)
            or AMOUNT_SLOT_WIDTH) + SLOT_RIGHT_PAD)
        label:SetWidth(0)
        label:SetPoint("LEFT", frame, "LEFT", LABEL_INSET_LEFT, 0)
        label:SetPoint("RIGHT", frame.amount, "LEFT", -SLOT_GAP, 0)
        return
    end

    if mode ~= "event" then
        frame.time:Hide()
        frame.caster:Hide()
        -- Width from its two anchors, as it has always been: the name column of
        -- a spell line runs from the icon to the amount slot.
        label:SetWidth(0)
        label:SetPoint("LEFT", frame, "LEFT", LABEL_INSET_LEFT, 0)
        label:SetPoint("RIGHT", frame.amount, "LEFT", -SLOT_GAP, 0)
        return
    end

    -- Measured from this recap's own longest time where one was worked out,
    -- with the constant as a floor. Sized to a constant it carried a character
    -- of slack down its left edge on every list whose longest was shorter.
    local timeWidth = (style.eventTimeWidth
        or measureText(EVENT_TIME_WIDEST, path, size, flags) or 0) + SLOT_RIGHT_PAD

    frame.time:Show()
    frame.time:SetFont(path, size, flags)
    frame.time:SetWidth(timeWidth)
    frame.time:ClearAllPoints()
    -- The same inset the share slot keeps on the right, so the row's two edges
    -- are symmetrical.
    frame.time:SetPoint("LEFT", frame, "LEFT", SLOT_RIGHT_PAD, 0)

    -- MEASURED WHERE THAT IS LEGAL, RESERVED WHERE IT IS NOT. `style.eventSpellWidth`
    -- is set only when every caption in this recap could be read, which out of
    -- combat is all of them — and out of combat is when a death recap is read.
    -- Mid-pull the captions are secret, the measurement is refused, and the
    -- column falls back to the character reservation it always had.
    label:SetWidth(style.eventSpellWidth or charSpan(EVENT_SPELL_CHARS, path, size, flags))
    label:SetPoint("LEFT", frame.time, "RIGHT", SLOT_GAP, 0)

    frame.caster:Show()
    frame.caster:SetFont(path, size, flags)
    frame.caster:SetWidth(style.eventCasterWidth
        or charSpan(EVENT_CASTER_CHARS, path, size, flags))
    frame.caster:ClearAllPoints()
    frame.caster:SetPoint("LEFT", label, "RIGHT", SLOT_GAP, 0)
end

--- The width of `NAME_COLUMN_CHARS` characters at one font.
---
--- 'n' is the reference glyph on purpose: it is the classic average-width letter
--- (the "en"), so 25 of them approximate 25 characters of a real name far better
--- than 25 of a wide 'W' or a narrow 'i' would.
local function measureNameSpan(path, size, flags)
    return measureText(string.rep("n", NAME_COLUMN_CHARS), path, size, flags)
        or (NAME_COLUMN_CHARS * size * NAME_WIDTH_PER_CHAR)
end

--- How wide the share slot must be at one font to hold a full "100.0%".
---
--- Measured rather than assumed, for the reason on SHARE_SLOT_WIDTH: the share
--- is six glyphs at its widest, not five, and the font size is the player's to
--- choose. The constant is the floor, so this never makes the slot narrower than
--- it has always been.
local function shareSlotWidth(path, size, flags)
    local w = measureText(SHARE_WIDEST, path, size, flags)
    if not w then return SHARE_SLOT_WIDTH end
    w = w + SLOT_RIGHT_PAD
    return (w > SHARE_SLOT_WIDTH) and w or SHARE_SLOT_WIDTH
end

--- The terms the minimum width is built from, for `/mm debug diag`.
---
--- Split out so the diagnostic reports the SAME arithmetic the tooltip runs
--- rather than a restatement of it that can drift. Every term comes from config
--- or from the ruler, so this is safe to call outside a hover — and it reads no
--- widget that has ever held a meter value.
---
--- @param style table|nil  a resolved style; nil resolves the configured tooltip
---   font instead, which is what the diagnostic has — it runs outside a hover
---   and so has no style in hand.
--- @return table
function Tooltip.WidthParts(style)
    local path, size, flags
    if style then
        path, size, flags = style.fontPath, style.fontSize, style.fontFlags
    else
        path, size, flags = tooltipFont(tooltipConfig(nil))
    end
    if type(size) ~= "number" or size < 1 then size = 12 end

    local nameSpan = measureNameSpan(path, size, flags)
    local share    = shareSlotWidth(path, size, flags)

    return {
        chars    = NAME_COLUMN_CHARS,
        nameSpan = nameSpan,
        nameGap  = NAME_GAP,
        amount   = AMOUNT_SLOT_WIDTH,
        slotGap  = SLOT_GAP,
        share    = share,
        padding  = TOOLTIP_H_PADDING,
        total    = nameSpan + NAME_GAP + AMOUNT_SLOT_WIDTH + SLOT_GAP
            + share + TOOLTIP_H_PADDING,
    }
end

--- Widen the tooltip enough that the two number slots never sit on a spell name.
---
--- GameTooltip sizes itself from its own text, and our numbers are not its text
--- any more — so without this the tooltip shrinks to the width of the names and
--- the slots overlap them. A MINIMUM is exactly the right instrument: a longer
--- header line still wins, and nothing here shrinks the tooltip.
---
--- THE NAME SPAN IS FIXED, AND IT HAS TO BE. Two earlier versions sized it from
--- the names themselves — first by reading GameTooltip's own FontStrings, then
--- by measuring the captions on a ruler of our own — and both failed in combat
--- for the same reason, which took instrumenting the live client to see: a spell
--- breakdown's captions are SECRET mid-pull. `C_DamageMeter` hands out a secret
--- `spellID`, so the name the client resolves from it is secret too. It RENDERS
--- — `SetText` is a widget setter and takes a secret happily, which is why the
--- tooltip shows "Chain Lightning" while this code cannot tell that it does —
--- but it cannot be measured, because taking the widest of several measurements
--- is a comparison and rule R3 forbids comparing a secret. There is no
--- arrangement of a ruler that escapes that: secret in, secret out.
---
--- So the span is a reservation rather than a measurement — `NAME_COLUMN_CHARS`
--- characters at the configured font, the same in combat and out. Nothing here
--- clips a longer name: the result is a FLOOR, and GameTooltip still grows past
--- it for its own longer text.
---
--- @param style table  a resolved style from `lineStyle`, for its font
local function applyMinimumWidth(style)
    if not (_G.GameTooltip and GameTooltip.SetMinimumWidth) then return end
    GameTooltip:SetMinimumWidth(Tooltip.WidthParts(style).total)
end

--- The same floor, plus the death tooltip's two extra columns.
---
--- A death line carries a time and a caster that a spell line does not, and they
--- have to be paid for or they overlap the numbers. Reserved from the font like
--- everything else here — see the note on applyMinimumWidth for why none of it
--- may be measured off the names themselves.
local function applyDeathMinimumWidth(style)
    if not (_G.GameTooltip and GameTooltip.SetMinimumWidth) then return end
    local path, size, flags = style.fontPath, style.fontSize, style.fontFlags
    local extra = (measureText(EVENT_TIME_WIDEST, path, size, flags) or 0)
        + SLOT_RIGHT_PAD + SLOT_GAP
        + charSpan(EVENT_CASTER_CHARS, path, size, flags) + SLOT_GAP
    GameTooltip:SetMinimumWidth(Tooltip.WidthParts(style).total + extra)
end

--- Everything a line needs to draw itself, resolved ONCE per hover.
---
--- Resolved once rather than per line because every one of these is an LSM fetch
--- or a config walk and a breakdown may be sixty-four lines deep — and because a
--- style that could differ between two lines of one tooltip would be a bug with
--- no way to see it.
---
--- @param config table      the resolved tooltip config
--- @param color table|nil   the hovered player's class color, or nil
--- @return table
local function lineStyle(config, color)
    local path, size, flags = tooltipFont(config)
    local borderSize = config.barBorderSize
    if type(borderSize) ~= "number" or borderSize < 0 then borderSize = 0 end

    local tr, tg, tb = rgba(config.textColor,
        SLOT_COLOR_DEFAULT[1], SLOT_COLOR_DEFAULT[2], SLOT_COLOR_DEFAULT[3], 1)

    return {
        color      = color,
        textColor  = { tr, tg, tb },
        texture    = mediaPath("statusbar", config.barTexture),
        -- Size zero drops the FILE with it. A zero edgeSize with a texture still
        -- present is the combination WoW draws as a hard 1px line, which is the
        -- setting doing the opposite of what it says (modules/Window.lua says
        -- the same about the window's own border).
        border     = (borderSize > 0) and mediaPath("border", config.barBorderStyle) or nil,
        borderSize = borderSize,
        borderColor = config.barBorderColor,
        fontPath   = path,
        fontSize   = size,
        fontFlags  = flags,
    }
end

--- Put the configured border around one line's carrier, or take it off.
---
--- Called on every draw and not once at creation, because the carrier is POOLED:
--- the frame drawing line 4 of this hover drew line 4 of the last one, and a
--- player who turned the border off between the two would otherwise keep it.
--- Clearing is an explicit SetBackdrop(nil) for exactly that reason.
local function applyLineBorder(frame, style)
    if not frame.SetBackdrop then return end

    if not style.border then
        frame:SetBackdrop(nil)
        return
    end

    frame:SetBackdrop({
        -- No bgFile: the bar underneath already draws the line's background, and
        -- a backdrop fill on top of it would flatten every bar to one color.
        edgeFile = style.border,
        edgeSize = style.borderSize,
    })
    if frame.SetBackdropBorderColor then
        local r, g, b, a = rgba(style.borderColor, 0, 0, 0, 1)
        frame:SetBackdropBorderColor(r, g, b, a)
    end
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
--- @param style table        a resolved style from `lineStyle`
--- @param label string|nil   text for the carrier's own name slot (target lines);
---                           nil leaves it empty, which is what a spell line wants
local function drawLine(lineIndex, amount, share, value, max, style, label, mode)
    local name = GameTooltip:GetName()
    local left = name and _G[name .. "TextLeft" .. lineIndex]
    if not left then return end

    local frame = lineWidget(lineIndex)

    -- The player's font, on OUR two slots and on the tooltip's own line. The
    -- line is shared and is restored by `restoreFonts`; the slots are ours and
    -- are simply re-set on every draw.
    frame.amount:SetFont(style.fontPath, style.fontSize, style.fontFlags)
    frame.share:SetFont(style.fontPath, style.fontSize, style.fontFlags)
    frame.label:SetFont(style.fontPath, style.fontSize, style.fontFlags)

    -- Which slots exist on this line, and how wide they are. Re-stated here for
    -- the same reason the font above it is: the carrier is pooled.
    applySlotLayout(frame, style, mode)

    -- The share slot is sized from the font, so it is re-stated every draw for
    -- the same reason the font is: the carrier is pooled, and line 4 of this
    -- hover is the frame that drew line 4 of the last one, at whatever size that
    -- hover was configured with.
    frame.share:SetWidth(shareSlotWidth(style.fontPath, style.fontSize, style.fontFlags))

    -- Re-stated every draw rather than once at creation, exactly like the font:
    -- the carrier is pooled, so line 4 of this hover is the frame that drew line
    -- 4 of the last one, under whatever color that hover was configured with.
    local tc = style.textColor
    frame.amount:SetTextColor(tc[1], tc[2], tc[3])
    frame.share:SetTextColor(tc[1], tc[2], tc[3])
    frame.label:SetTextColor(tc[1], tc[2], tc[3])
    applyLineFont(left, lineIndex, style.fontPath, style.fontSize, style.fontFlags)

    applyLineBorder(frame, style)

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
    frame.label:SetText(label or "")
    -- Blanked rather than left alone: a hidden slot still holds last hover's
    -- text, and the death path reads them back in tests.
    if mode ~= "event" then
        frame.time:SetText("")
        frame.caster:SetText("")
    end

    -- THE BAR TAKES THE HANDLES RAW, exactly as modules/Row.lua's cells do.
    --
    -- This used to gate on `CanCompare2(value, max)` and hide the bar whenever
    -- the two could not be compared — which is every line of every breakdown in
    -- combat, so the tooltip lost its bars for the whole of every pull while the
    -- main window kept its own. That was a misreading of the rule. A bar's fill
    -- is amount/max computed NATIVELY, by the widget, in code that is allowed to
    -- see secrets; tainted code only may not do that division ITSELF.
    -- core/Secrets.lua says so in as many words: SetValue and SetMinMaxValues are
    -- on the MAY list.
    --
    -- So the only test applied here is `== nil`, which is legal on a non-boolean
    -- secret and is the one test Row.lua applies too. How big the value is, and
    -- how it compares to the max, is the widget's business.
    --
    -- The consequence is the documented one and it is already paid: a frame that
    -- has been handed a secret has secret geometry, so nothing anchored to this
    -- bar may be read back. Layout here is computed from config (rule R3).
    local b = frame.bar
    b:SetStatusBarTexture(style.texture or BAR_FALLBACK_TEXTURE)
    -- BORDER, so the tooltip's ARTWORK spell name reads on top of the fill rather
    -- than under it. SetStatusBarTexture replaces the texture object, so the layer
    -- has to be re-stated every draw and not once at creation.
    local fill = b.GetStatusBarTexture and b:GetStatusBarTexture()
    if fill and fill.SetDrawLayer then fill:SetDrawLayer("BORDER") end
    if max == nil then
        b:SetMinMaxValues(0, 1)
    else
        b:SetMinMaxValues(0, max)
    end
    b:SetValue(value == nil and 0 or value)
    local color = style.color
    b:SetStatusBarColor((color and color.r) or 0.6, (color and color.g) or 0.6,
        (color and color.b) or 0.6, 0.85)
    b:Show()
end

local function addSpellLine(spell, numberStyle, max, style, sourceTotal)
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
    drawLine(GameTooltip:NumLines(), amount, share, spell.totalAmount, max, style, nil)
end

-- How many deaths a grid cell's tooltip will list before it stops. A raid night
-- can hold more than anyone reads in a hover, and the drill-down is one click
-- away with the whole list in it.
local MAX_DEATH_LINES = 12

-- What a death shows in place of a time when the client no longer holds its
-- recap. The same em dash modules/DrillDown.lua puts in the cell.
local NO_CLOCK_TEXT = "\226\128\148"

--- How one death is labelled, in whichever style the hovered window is set to.
---
--- The moment of death is the recap's NEWEST event, never `deathTimeSeconds` —
--- those are different clocks, one absolute and one seconds-into-session, and
--- the second is unusable besides (see modules/Format.lua's DeathTime).
---
--- Kept in step with modules/DrillDown.lua's copy on purpose: this tooltip is
--- the INDEX into that list, and the two labelling deaths differently would make
--- one list look like two.
---
--- @param recap table|nil
--- @param style string|nil  the window's timestamp style
--- @return string|nil
local function deathClockOf(recap, style)
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
    return F.DeathTime(newest.timestamp, style)
end

-- ---------------------------------------------------------------------------
-- Death events (issue #1)
-- ---------------------------------------------------------------------------
--
-- One line per incoming event behind a death, drawn on the same carrier the
-- spell breakdown uses so fonts, borders, colours and the width machinery are
-- inherited rather than duplicated.
--
-- WHAT IS DIFFERENT FROM A SPELL LINE, and why each difference exists:
--
--   * the bar is HP REMAINING, not the amount. A death is read by watching a
--     health bar empty, and `currentHP` with the recap's own max is exactly that
--     — handed over raw so the WIDGET divides. Tainted code doing that division
--     itself is the thing rule R1 forbids.
--   * the caption carries a time and an attacker as well as a spell. Both extra
--     terms come off the event, both may be secret, and the join is therefore
--     ONE string.format rather than any `..`. This file has never concatenated
--     anything that could be secret and this is not where it starts.
--   * the amount slot is the damage alone. Overkill goes in the CAPTION instead,
--     because AMOUNT_SLOT_WIDTH is a fixed 66px with no per-font measurement and
--     "-787.3K (138.1K overkill)" would clip exactly the way "100.0%" once
--     clipped to "100....". Widening it would change every tooltip in the addon.

--- Seconds between an event and the death, as a negative number, or nil.
---
--- GATED, even though a live capture showed these fields plain in combat. A
--- subtraction is arithmetic, arithmetic on a secret raises, and "plain today"
--- is an observation about one build. A refused subtraction costs the time
--- prefix on one line; an ungated one costs the tooltip mid-pull.
---
--- @return number|nil
local function eventOffset(when, deathTime)
    if when == nil or deathTime == nil then return nil end
    local Secrets = NS.Secrets
    if not (Secrets and Secrets.CanCompare2 and Secrets.CanCompare2(when, deathTime)) then
        return nil
    end
    return when - deathTime
end

--- The three text columns of one event, plus the icon that heads its line.
---
--- SPLIT RATHER THAN COMPOSED. One string used to hold the time, the spell, the
--- caster and an overkill clause, so a long name pushed the numbers off the
--- right edge and the killing blow rendered as "355.8Kove…37.3%". Each part now
--- goes to its own reserved slot and the engine clips into it.
---
--- Nothing here joins two of them. A spell name and a caster name are both
--- resolved off ids the client can hand back secret, and `..` on a secret
--- raises where a widget setter takes one happily.
---
--- @param event table
--- @param secondsBefore number|nil  already gated; nil when it could not be computed
--- @return string icon, any timeText, any name, any caster
local function eventColumns(event, secondsBefore)
    local spellID = event.spellId
    local icon = (spellID ~= nil and Compat and Compat.GetSpellTexture)
        and Compat.GetSpellTexture(spellID) or nil

    -- A MELEE SWING HAS NO SPELL AT ALL — no id, no name — so it fell through to
    -- the "the client could not name this" placeholder and printed "#?", which
    -- reads as a bug in the addon rather than as a melee hit. Blizzard's own
    -- recap draws it as "Melee" with the weapon icon, and so does this.
    --
    -- The event type is read through `plainWord`, because it comes off a recap
    -- like everything else and comparing a secret string raises.
    local kind = plainWord(event.event)
    local name = event.spellName
    if name == nil then
        if kind == "SWING_DAMAGE" then
            name = L["Melee"] or "Melee"
            icon = icon or MELEE_ICON
        elseif kind == "SPELL_HEAL" or kind == "SPELL_PERIODIC_HEAL" then
            name = L["Heal"] or "Heal"
        else
            -- A spell the client cannot name is shown by id rather than dropped,
            -- exactly as addSpellLine does it. The explicit nil branch is there
            -- because string.format("%s", nil) raises in Lua 5.1.
            name = (spellID ~= nil) and string.format("#%s", spellID) or "#?"
        end
    end

    -- `hideCaster` may be a secret boolean, so it goes through plainTruth. An
    -- absent caster leaves the column EMPTY rather than collapsing it: the
    -- columns have to line up down the whole tooltip.
    local caster = event.sourceName
    if plainTruth(event.hideCaster) then caster = nil end

    local timeText = ""
    if secondsBefore ~= nil then
        -- SPELLED WITH THE SIGN, not left to the subtraction. Every event
        -- precedes the death, so the figure is zero or negative — and the
        -- killing blow's is exactly zero, which `%.1f` renders as "0.0s" while
        -- the whole column reads in negatives. "-0.0s" is the honest one: it
        -- says "at the moment of death", not "zero seconds".
        if secondsBefore > 0 then
            timeText = string.format("%.1fs", secondsBefore)
        else
            -- math.abs, not unary minus: negating a zero yields NEGATIVE
            -- zero, which "%.1f" renders as "-0.0" and the sign above then
            -- doubles into "--0.0s".
            timeText = string.format("-%.1fs", math.abs(secondsBefore))
        end
    end

    return string.format("|T%s:%d:%d:0:0|t", icon or FALLBACK_ICON,
        TOOLTIP_ICON_SIZE, TOOLTIP_ICON_SIZE), timeText, name, caster or ""
end

--- Draw one recap event.
---
--- NO OVERKILL. It is the part of a killing blow that exceeded health the player
--- no longer had, it appears on exactly one line out of ten, and on this surface
--- it was colliding with the HP percentage beside it. The figure is still in the
--- payload for anything that later wants it.
---
--- @param event table
--- @param deathTime any|nil   the newest event's timestamp
--- @param maxHealth any|nil   the recap's own max, for the bar
local function addEventLine(event, deathTime, maxHealth, numberStyle, style)
    local icon, timeText, name, caster =
        eventColumns(event, eventOffset(event.timestamp, deathTime))

    -- The tooltip's own line carries ONLY the icon. Everything else is on the
    -- carrier, in fixed slots, so the columns line up down the whole tooltip
    -- instead of ragging against names of a dozen different lengths.
    GameTooltip:AddLine(icon, 1, 1, 1)

    local index = GameTooltip:NumLines()
    drawLine(index,
        formatNumber(event.amount, numberStyle),
        formatShare(event.currentHP, maxHealth),
        event.currentHP, maxHealth, style, name, "event")

    local frame = lineWidget(index)
    frame.time:SetText(timeText)
    frame.caster:SetText(caster)
end

--- Every event behind one death, oldest first.
---
--- REVERSED FROM THE CLIENT'S ORDER, which is newest first. The killing blow
--- reads as the last line for the same reason a story ends with its ending.
---
--- @return boolean  whether anything was drawn
local function drawDeathEvents(recap, numberStyle, style)
    local events = recap and recap.events
    if type(events) ~= "table" then return false end
    local Secrets = NS.Secrets
    if not (Secrets and Secrets.SafeIterate) then return false end
    if Secrets.CanAccessTable and not Secrets.CanAccessTable(events) then return false end

    -- Collected first, because the walk has to run backwards and SafeIterate —
    -- the only legal way to measure an array whose entries may be secret — runs
    -- forwards. `#` on it is what rule R1 forbids.
    local ordered = {}
    Secrets.SafeIterate(events, function(_, event)
        if type(event) ~= "table" then return end
        if Secrets.CanAccessTable and not Secrets.CanAccessTable(event) then return end
        ordered[#ordered + 1] = event
        if #ordered >= COLLECT_LIMIT then return false end
    end)

    local total = #ordered
    if total == 0 then return false end

    -- Element one is the killing blow, so its timestamp is the moment of death
    -- and every other line is measured against it.
    local deathTime = ordered[1].timestamp
    local maxHealth = recap.maxHealth

    -- The time column is sized from THIS recap's longest offset, before any line
    -- is drawn. The offsets are plain numbers this addon computed — the gate in
    -- `eventOffset` guarantees it — so comparing and measuring them is legal
    -- where doing the same to the names beside them would not be.
    local path, size, flags = style.fontPath, style.fontSize, style.fontFlags
    local widest, spellW, casterW = nil, 0, 0
    -- One unreadable caption abandons the whole measurement rather than sizing
    -- the column from the readable half — a column that fits four names out of
    -- ten is worse than one reserved for all of them.
    local namesReadable = true

    for i = 1, total do
        local off = eventOffset(ordered[i].timestamp, deathTime)
        if off ~= nil then
            local text = (off > 0) and string.format("%.1fs", off)
                or string.format("-%.1fs", math.abs(off))
            local w = measureText(text, path, size, flags)
            if w ~= nil and (widest == nil or w > widest) then widest = w end
        end

        if namesReadable then
            local name = plainWord(ordered[i].spellName)
            local caster = plainWord(ordered[i].sourceName)
            -- nil is fine on either — a swing has no spell name and plenty of
            -- events name no caster. What is NOT fine is a value that is there
            -- and may not be read, which is what plainWord answers nil for too,
            -- so the two are told apart by asking Secrets directly.
            if unreadable(ordered[i].spellName) or unreadable(ordered[i].sourceName) then
                namesReadable = false
            else
                local sw = name and measureText(name, path, size, flags) or 0
                local cw = caster and measureText(caster, path, size, flags) or 0
                if sw and sw > spellW then spellW = sw end
                if cw and cw > casterW then casterW = cw end
            end
        end
    end

    style.eventTimeWidth = widest

    -- A couple of characters of air, so a name that exactly fills its column
    -- does not read as though it were clipped. Capped at the reservation, or
    -- shrinking to fit would become growing to fit and a forty-character boss
    -- ability would push the numbers off the edge.
    if namesReadable then
        local pad = charSpan(2, path, size, flags)
        style.eventSpellWidth  = math.min(spellW + pad, charSpan(EVENT_SPELL_CHARS, path, size, flags))
        style.eventCasterWidth = math.min(casterW + pad, charSpan(EVENT_CASTER_CHARS, path, size, flags))
    else
        style.eventSpellWidth, style.eventCasterWidth = nil, nil
    end

    for i = total, 1, -1 do
        addEventLine(ordered[i], deathTime, maxHealth, numberStyle, style)
    end
    return true
end

--- @param row table          a death drill-down row (needs .recapID)
--- @param style table        the line style every carrier is drawn with
--- @param numberStyle string|nil  the hovered window's abbreviation style
local function addDeathBreakdown(row, style, numberStyle)
    local P = NS.Provider
    local recap = (row.recapID ~= nil and P and P.GetRecap)
        and P.GetRecap(row.recapID) or nil

    -- THE HEADER IS NOT DECORATION; IT KEEPS A CARRIER OFF LINE 1.
    --
    -- drawLine fonts the tooltip line its carrier sits behind and records it, and
    -- restoreFonts puts SetFontObject(GameTooltipText) back on teardown. On a
    -- live client GameTooltipTextLeft1 inherits GameTooltipHeaderText, NOT
    -- GameTooltipText — so an event on line 1 would leave every GameTooltip in
    -- the game rendering its title in the small body font until the next
    -- /reload. The damage is to a shared FontString this addon does not own,
    -- which is why it outlives the hover and everything else here.
    --
    -- Every other caller already puts a header on line 1 for its own reasons,
    -- which is why releaseLines can claim "a spell line is never line 1" and why
    -- this never fired before. The death branch is the first path that would
    -- have started at the top.
    --
    -- It earns its place besides: the row says only "Death 3", so this is where
    -- a reader finds out whose death and when. Both terms go through one
    -- AddDoubleLine rather than any concatenation — `displayName` may be secret.
    GameTooltip:AddDoubleLine(displayName(row),
        row.deathClock or L["Death recap"] or "Death recap",
        1, 1, 1, 1, 0.82, 0)

    -- THE SAME GAP AND CAPTION EVERY OTHER SECTION IN THIS FILE GETS. Without
    -- them the header sat flush against the first bar, which nothing else here
    -- does, and the tooltip read as though a different addon had drawn it. The
    -- gap is also what keeps a carrier off line 1 with room to spare.
    addSectionGap(style)
    GameTooltip:AddLine(L["Death recap"] or "Death recap", 1, 0.82, 0)

    if not drawDeathEvents(recap, numberStyle, style) then
        -- A DEATH THE CLIENT NO LONGER HOLDS SAYS SO. An empty tooltip under the
        -- cursor reads as a broken addon; a sentence reads as a fact about the
        -- client, which is what it is.
        GameTooltip:AddLine(L["No recap stored for this death"] or
            "No recap stored for this death", 1, 0.82, 0)
        return
    end

    -- Reserved from CONFIG, never measured off a line that has held a recap
    -- value — the whole reason applyMinimumWidth exists. SpellTooltip has never
    -- needed it before because its other paths draw no carriers.
    applyDeathMinimumWidth(style)
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

--- Draw the "Deaths" section on a GRID cell: one line per death, newest first.
---
--- ISSUE #1'S FIRST COMPLAINT. This cell used to run the ordinary spell path,
--- which asks the provider for `combatSpells` on a Deaths source — there is no
--- spell list on a death row, so it rendered "No data yet": technically honest
--- and completely useless. A Deaths cell should never have been showing a spell
--- breakdown at all.
---
--- The lines are the same shape the drill-down's rows are, and deliberately so:
--- this tooltip is the INDEX into that list, so hovering and then clicking
--- shows the same deaths in the same order.
---
--- @param row table       an aggregated row (needs .deaths)
--- @param style table
--- @param timeStyle string|nil  the window's timestamp style
--- @return number  lines drawn
local function addDeathList(row, style, timeStyle)
    local deaths = row.deaths
    if type(deaths) ~= "table" or #deaths == 0 then return 0 end

    local P = provider()
    if not (P and P.GetRecap) then return 0 end

    addSectionGap(style)
    GameTooltip:AddLine(L["Deaths"], 1, 0.82, 0)

    local total = #deaths
    local drawn = 0
    for i = 1, total do
        local id = deaths[i]
        local clock
        if id ~= false and id ~= nil then
            -- The offset falls back to the Current session for the reason
            -- modules/DrillDown.lua's copy records: Overall reports -1 for every
            -- death it holds, and Overall is what a window shows by default.
            clock = deathClockOf(P.GetRecap(id), timeStyle)
        end

        -- Numbered chronologically and listed newest first, exactly as
        -- modules/DrillDown.lua builds the rows this indexes. A reader who hovers
        -- and then clicks must see the same list twice.
        GameTooltip:AddLine(string.format("|T%d:%d:%d:0:0|t %s", DEATH_ICON,
            TOOLTIP_ICON_SIZE, TOOLTIP_ICON_SIZE,
            string.format(L["Death %d"] or "Death %d", total - i + 1)), 1, 1, 1)
        -- The time goes in the AMOUNT slot rather than the line, so the times
        -- line up in a column instead of ragging against names of two lengths.
        --
        -- PLAIN ONES FOR THE BAR, so it draws FULL. A death is not a quantity
        -- and there is nothing here to scale against, but an empty bar behind
        -- every line reads as a value that failed to load — so the bar is the
        -- row's backing, exactly as it is on a death row in the drill-down.
        drawLine(GameTooltip:NumLines(), clock or NO_CLOCK_TEXT, "", 1, 1, style, nil, "clock")
        drawn = drawn + 1
        if drawn >= MAX_DEATH_LINES then break end
    end
    return drawn
end

--- Draw the "Spell breakdown" section, and answer how many spell lines it drew.
---
--- The order is collect, then sort-if-legal, then draw: the sort is the one step
--- that may be refused mid-pull, and refusing it leaves the provider's own
--- ordering in place rather than degrading anything downstream of it.
---
--- @param source table       a DamageMeterCombatSessionSource
--- @param _statKey string     kept so the call site reads like its siblings; the
---   breakdown is drawn the same way for every column
--- @param cap number         the most lines this section may draw
--- @param numberStyle string|nil
--- @return number  lines drawn
local function addSpellBreakdown(source, _statKey, cap, numberStyle, style)
    local spells, spellTotal = collectSpells(source)
    sortSpellsIfLegal(spells)

    addSectionGap(style)
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

    -- ONE LINE PER SPELL, on every column including this one. The avoidable
    -- breakdown used to tag each spell with a gray "Avoidable" / "Avoidable,
    -- Deadly" sub-line beneath its bar, and it was noise in the one place it
    -- appeared: EVERY spell in an Avoidable Damage breakdown is avoidable — the
    -- tooltip's own header says so — so the tag restated the column for each row
    -- while breaking the list into ragged, mismatched groups.
    local shown = 0
    for i = 1, #spells do
        if i > cap then break end
        addSpellLine(spells[i], numberStyle, barMax, style, source.totalAmount)
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

-- ---------------------------------------------------------------------------
-- Targets — which enemies this player hit
-- ---------------------------------------------------------------------------

--- The stat whose cells this section appears under. Damage only: "who did you
--- hit" is a question about damage dealt, and the same list under a Healing or
--- an Interrupts cell would be answering a question nobody asked of it.
local TARGET_STAT = "DamageDone"

--- Draw the "Targets" section, and answer how many lines it drew.
---
--- Everything hard about this lives in modules/Targets.lua, which either hands
--- back a list whose numbers are PLAIN — it refuses outright rather than sum
--- secrets — or hands back nil. So this function is ordinary: nil means no
--- section, and a list means the amounts may be formatted, divided and drawn
--- exactly like any other.
---
--- The bars scale to the biggest target rather than to the player's own total,
--- for the same reason the spell bars scale to the biggest spell: a breakdown is
--- read against itself.
---
--- @param row table
--- @param statKey string
--- @param config table
--- @param style table
--- @param numberStyle string|nil
--- @param window table|nil
--- @return number  lines drawn
local function addTargetBreakdown(row, statKey, config, style, numberStyle, window)
    if not config.showTargets then return 0 end
    if statKey ~= TARGET_STAT then return 0 end

    local T = NS.Targets
    if not (T and T.ForPlayer) then return 0 end

    local cap = config.maxTargets
    if type(cap) ~= "number" or cap < 1 then cap = 3 end

    local list = T.ForPlayer(window, row and row.name, cap)
    if not list then return 0 end

    local total = T.Total(list)
    local max = list[1] and list[1].total

    addSectionGap(style)
    GameTooltip:AddLine(L["Targets"], 1, 0.82, 0)

    for i = 1, #list do
        local entry = list[i]
        -- The tooltip line is deliberately BLANK. Its only job is to exist, so
        -- the carrier has something to anchor to and the tooltip reserves a row
        -- of height; the visible name is drawn on the carrier's own label slot,
        -- which is the only way to start it where a spell name starts rather
        -- than where a spell icon starts. See `lineWidget`.
        GameTooltip:AddLine(" ", 1, 1, 1)
        drawLine(GameTooltip:NumLines(),
            formatNumber(entry.total, numberStyle),
            formatShare(entry.total, total),
            entry.total, max, style,
            entry.name or L["Unknown"])
    end

    return #list
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

    -- The bars wear the hovered player's class color, so a tooltip reads as
    -- belonging to the row it came off. `classFilename` is NeverSecret, which is
    -- why this keeps working mid-pull when the bar LENGTHS cannot.
    local classes = _G.RAID_CLASS_COLORS
    local color = classes and row and row.classFilename and classes[row.classFilename] or nil
    local style = lineStyle(config, color)

    -- DEATHS TAKES ITS OWN PATH, and never the spell one. See addDeathList.
    local shown = 0
    if statKey == "Deaths" then
        shown = addDeathList(row, style, config.deathTimeFormat
            or (window and window.text and window.text.deathTimeFormat))
    else
        local source = config.showSpells and sourceDetailFor(window, statKey, row)
        if source then
            shown = addSpellBreakdown(source, statKey, spellLineCap(config),
                numberStyleOf(window), style)
        end
    end

    if shown == 0 then
        GameTooltip:AddLine(L["No data yet"], 0.6, 0.6, 0.6)
    end

    addTargetBreakdown(row, statKey, config, style, numberStyleOf(window), window)

    addDeathRecapHint(row, statKey)

    -- After every line, before the Show that sizes the frame: the number slots are
    -- our widgets, so GameTooltip cannot size itself around them.
    applyMinimumWidth(style)

    GameTooltip:Show()
    -- AFTER Show, not before: the show path re-fonts the tooltip's lines. See
    -- `reapplyFonts`.
    reapplyFonts()

    if t0 then Perf.Note("tooltip", debugprofilestop() - t0) end
    if State.debug and Debug then
        Debug("Tooltip", "cell %s spells=%d", statKey, shown)
    end
end

-- ---------------------------------------------------------------------------
-- Name tooltip — every statistic for one player
-- ---------------------------------------------------------------------------

--- One statistic's color as three plain numbers, dimmed when the hovered window
--- has no column for it.
---
--- The catalog's palette, the same three numbers modules/Row.lua paints the bar
--- with. An unknown key answers a neutral rather than a tenth color, so a stat
--- added to the catalog without a palette entry renders plainly instead of
--- inventing a hue nothing else in the addon uses.
---
--- @param statKey string
--- @param shown boolean|nil  is this statistic a column in the hovered window
--- @return number, number, number
local function statColor(statKey, shown)
    local c = Const.STAT_COLORS and Const.STAT_COLORS[statKey or ""]
    if not c then
        if shown then return 1, 1, 1 end
        return 0.62, 0.62, 0.62
    end
    if shown then return c[1], c[2], c[3] end
    local dim = Const.STAT_DIM or 0.6
    return c[1] * dim, c[2] * dim, c[3] * dim
end

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
--- EVERY LINE WEARS ITS OWN STATISTIC'S COLOR, label and amount alike — the
--- catalog's palette (`Const.STAT_COLORS`), the same eight colors a bar takes
--- under `bars.colorMode == "stat"`, and it wears them WHATEVER that setting says.
--- This is the one place all eight statistics are on screen at once, so the color
--- is doing work here that it is only optionally doing on a bar: it is what ties
--- the "Healing" line in this list to the Healing column in the grid behind it.
--- The setting governs the BARS; this list is not a bar.
---
--- Stats the window does show are drawn in full color; the rest are dimmed — the
--- same hue at a lower level rather than a flat gray, so the two groups stay
--- distinguishable without a hidden statistic losing its identity.
---
--- One provider call per statistic. That is up to eight calls on a hover, and it
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
            -- BOTH SIDES IN THE SAME COLOR, so the line reads as one fact rather
            -- than as a colored name beside a neutral number.
            --
            -- Through AddDoubleLine's own color arguments and NOT through a
            -- `|cff…` escape on the string. Two reasons, and the second is the
            -- one that matters: an escape is a concatenation, and `formatNumber`
            -- may hand back a SECRET, which may not be concatenated. The tooltip
            -- applies the color arguments to whatever string it was handed,
            -- secret or not, so the same mechanism serves both sides of the line.
            local r, g, b = statColor(stat.key, onScreen[stat.key])
            GameTooltip:AddDoubleLine(L[stat.label],
                formatNumber(source.totalAmount, numberStyle), r, g, b, r, g, b)
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
-- Spell tooltip — a row inside a breakdown
-- ---------------------------------------------------------------------------

--- Show the GAME's own tooltip for the spell a drill-down row stands for.
---
--- The rows of a breakdown are spells, not players, and the two tooltips this
--- file otherwise builds both answer the wrong question about one. The cell
--- tooltip asks the provider for a spell breakdown OF a spell and renders "No
--- data yet"; the name tooltip lists every tracked statistic for a source that
--- is not a source and renders a column of zeros. Both are honest and both are
--- useless.
---
--- What a player wants there is the spell — what it does, what it costs, what it
--- scales with — and the client already renders that better than this addon
--- could. So the row hands GameTooltip a spell ID and gets out of the way.
---
--- EVERY CELL IN THE ROW, the name included. A breakdown row is one thing rather
--- than a grid of independent numbers, so hovering any part of it asks the same
--- question and must get the same answer.
---
--- @param row table         a drill-down row (needs .spellID)
--- @param anchorFrame table the cell frame the tooltip anchors to
--- @param window table|nil  the window config
function Tooltip:SpellTooltip(row, anchorFrame, window)
    local t0 = Perf.on and debugprofilestop()

    window = resolveWindow(row, window)
    local config = tooltipConfig(window)
    -- Our own line widgets come down first: this tooltip is the client's, and a
    -- pooled bar left over from a spell breakdown would sit behind its text.
    releaseLines()
    if not openTooltip(anchorFrame, config) then return end

    -- THE DEATH BRANCH GOES FIRST, above the spellID path and not below it.
    -- SetSpellByID replaces the tooltip's whole content, so a death row that
    -- happened to carry a spellID would silently render the client's spell page
    -- instead of the event list — a failure that looks like a design choice.
    -- KEYED ON THE ROW KIND, not on the id. A death the client gave no recap id
    -- for is still a death row, and falling through to the one-line name path
    -- would render "Death 2" and nothing else — indistinguishable from a tooltip
    -- that failed to build.
    if row and row.isDeath then
        -- The same class-colour resolution CellTooltip does. `classFilename` is
        -- NeverSecret, and a death row carries the drilled-into player's, so the
        -- bars stay that player's colour for the whole trip. A nil colour is a
        -- legitimate answer: drawLine falls back to grey.
        local classes = _G.RAID_CLASS_COLORS
        local color = classes and row.classFilename and classes[row.classFilename] or nil
        addDeathBreakdown(row, lineStyle(config, color), numberStyleOf(window))
        GameTooltip:Show()
        reapplyFonts()
        if t0 then Perf.Note("tooltip", debugprofilestop() - t0) end
        return
    end

    local spellID = row and row.spellID
    -- SetSpellByID replaces the tooltip's whole content, so it is the last word
    -- rather than something to add lines to.
    if spellID ~= nil and GameTooltip.SetSpellByID then
        local ok = pcall(GameTooltip.SetSpellByID, GameTooltip, spellID)
        if ok then
            GameTooltip:Show()
            if t0 then Perf.Note("tooltip", debugprofilestop() - t0) end
            return
        end
    end

    -- No id, or a client that refused it. A one-line name beats an empty frame:
    -- the row is still telling the player which spell it is.
    GameTooltip:AddLine(displayName(row), 1, 1, 1)
    GameTooltip:Show()
    reapplyFonts()

    if t0 then Perf.Note("tooltip", debugprofilestop() - t0) end
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
