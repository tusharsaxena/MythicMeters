-- defaults/Profile.lua
--
-- THE profile defaults tree, and the only place a profile default value is
-- hardcoded (savedvariables-§2). core/Database.lua owns the AceDB assembly and
-- the migration runner; this file owns the shape those migrate towards.
--
-- Load order: the TOC's `# Defaults` block sits AFTER `# Core`, so
-- core/Database.lua cannot capture this tree in a file-scope local — it reaches
-- NS.defaults at CALL time, from NS:InitDB(), which is well after every file has
-- loaded. This file itself loads after core/Constants.lua and DOES capture the
-- stat catalog at load time, which is safe in that direction.
--
-- ---------------------------------------------------------------------------
-- WHY ALMOST EVERYTHING IS PER-WINDOW
-- ---------------------------------------------------------------------------
--
-- A window is an INSTANCE, not a singleton (design §6). There are no global
-- display settings: `frame`, `header`, `rows`, `bars`, `text`, `icons`,
-- `tooltip`, `visibility`, `columns` and `data` all live inside one window's
-- config table. That is what makes multi-window and copy-settings-from cheap —
-- a copy is a deep table copy, optionally filtered to one group — and it is why
-- the profile itself is nearly empty: an array of windows, a counter, the two
-- genuinely addon-wide toggles, and the export group.
--
-- The export group is the exception that proves the rule rather than a crack in
-- it. It remembers how the player last exported — which statistic, to which
-- channel, how many lines — and an export is a one-shot ACTION rather than a
-- window's appearance, so there is no instance for it to belong to.
--
-- The debug flag is NOT here. It is session-only, in core/State.lua, and is
-- never persisted (debug-logging-§5).

local addonName, NS = ...

-- File-local recursive deep-copy. Deliberately independent of NS.Util — this
-- file must stay self-contained rather than depend on a load order that puts a
-- helper module ahead of it.
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

local Const = NS.Constants

-- ---------------------------------------------------------------------------
-- The window template
-- ---------------------------------------------------------------------------
--
-- Written once as a private literal and deep-copied per window by
-- NS.DefaultWindow(). Never handed out directly: two windows sharing one
-- sub-table is the classic profile-aliasing bug, where editing window 2's bar
-- color silently edits window 1's.

local WINDOW_TEMPLATE = {
    -- Display name, shown in the window picker and (optionally) in the header.
    -- Every real window overwrites this: core/Database.lua's WindowName mints
    -- "Multi Meters #<n>" and both seeding and modules/WindowManager.lua hand
    -- the result to NS.DefaultWindow.
    name = "Multi Meters",

    -- The META colour mode: what the Frame page's "Color mode (all surfaces)"
    -- dropdown last broadcast to the ten surfaces that each carry one of their
    -- own. NOTHING READS IT -- it is a shortcut for setting all ten, and a player
    -- who changes one of them afterwards has changed one, not overridden this.
    colorMode = "custom",
    -- The other three meta controls, same bargain: each sets its own kind of
    -- setting on every surface that has one, stores what it last broadcast, and
    -- is read by nothing.
    barTexture  = "Blizzard Raid Bar",
    font        = "Friz Quadrata TT",
    fontOutline = "OUTLINE",

    -- -----------------------------------------------------------------------
    -- frame — the standalone window itself
    -- -----------------------------------------------------------------------
    --
    -- The chrome is LibKa0s-Core-1.0's shared SKIN and ApplySkin (never a
    -- private lookalike), so the edge colors are NOT settings here: the library
    -- tints frame.title and frame.divider itself. What IS configurable is the
    -- geometry, the backdrop, and the border the player picks from LSM.
    frame = {
        -- Derived from the grid rather than chosen: the name column, six default
        -- stat columns at Const.COLUMN_WIDTH, the seams between them and the
        -- padding on both edges. A narrower default clipped the rightmost column
        -- the moment every stat went to one uniform width, which reads as a
        -- broken window rather than as a window that needs dragging.
        width          = 694,
        height         = 220,
        scale          = 1.0,
        alpha          = 1.0,
        strata         = "MEDIUM",     -- LOW | MEDIUM | HIGH | DIALOG
        backdropColor  = { r = 0, g = 0, b = 0, a = 0.75 },
        borderStyle    = "Blizzard Tooltip",  -- LSM "border" key
        borderSize     = 2,
        borderColor    = { r = 0, g = 0, b = 0, a = 1 },
        padding        = 6,            -- inset from the frame edge to the rows
        -- Locked hides the drag handle and lets the mouse through to the rows
        -- for tooltips. Unlocking implies preview mode (core/State.lua), so a
        -- player positioning a window at a target dummy still sees a full grid.
        locked         = false,
        clampToScreen  = true,
        titleBar       = true,
        -- ── The header's controls (issue #6) ──
        --
        -- Seven keys, one per control that this addon builds. `closeButton` is
        -- the odd one out and deliberately keeps its old name: renaming it to
        -- `showClose` for symmetry would migrate every stored profile in exchange
        -- for a consistency nobody can see. It sits here rather than up beside
        -- `titleBar` because what it draws is a header control.
        closeButton     = true,
        showMinimise    = true,
        showLock        = true,
        showSettings    = true,
        showSegment     = true,
        showReset       = true,
        showExport      = true,
        -- Chrome fades until the pointer is over the title strip. Off is the
        -- behaviour every version before this one had, so it is the honest
        -- fallback rather than a degraded one.
        hoverReveal     = true,
        -- STATE, not a preference, and deliberately not a settings row: the
        -- header's minimise control writes it, and a window left collapsed comes
        -- back collapsed. Persisted like every other window fact.
        minimised       = false,
        -- TWO COLOURS, BECAUSE HOVER IS THE ONLY FEEDBACK A CONTROL GIVES. The
        -- art ships white and is tinted by a multiply, so white is the identity
        -- and the icons read as chrome against any header colour a player picks;
        -- the pointer turns one of them the gold the rest of the header text
        -- uses. Both are pickers rather than a "match the header" switch: the
        -- strip is the only part of the window whose two states a player sees
        -- constantly, and one of them being unconfigurable was the complaint.
        controlColor      = { r = 1, g = 1, b = 1, a = 1 },
        controlHoverColor = { r = 1, g = 0.82, b = 0, a = 1 },
        -- One class-colour flag EACH, and both ship off so no window changes
        -- appearance. Two rather than one because hover and rest are two
        -- independent answers: sharing a flag would make the pointer's colour
        -- identical to the resting one for anybody who ticked it, which is the
        -- one thing a hover colour must never be. The LOCAL player's class, like
        -- every other header surface — the strip is about the window, not about
        -- any row in it.
        controlClassColor      = false,
        controlHoverClassColor = false,
        -- The SLOT a control occupies -- its click target and the strip's layout
        -- pitch. The art is drawn centred inside it at 72% of it, so 16 puts an
        -- 11px icon on the same line as a 12px title and the strip stops
        -- outweighing the text beside it.
        controlSize     = 16,
        -- NO `resizeGrip` KEY. The grip follows the LOCK -- drawn while the
        -- window is unlocked, hidden while it is locked -- and a second setting
        -- for it was one that could disagree with the lock, and did: it was read
        -- only while the frame was being built, so unticking it changed nothing
        -- until a reload.
        -- Position is stored, never read back off the frame. Rule R3: a cell
        -- that has been handed a secret value makes its own geometry secret and
        -- propagates that to its parent, so GetPoint on a live window is not
        -- something this addon may do (design §4).
        position       = { point = "CENTER", relativePoint = "CENTER", x = 0, y = 0 },
    },

    -- -----------------------------------------------------------------------
    -- header — the strip above the rows
    -- -----------------------------------------------------------------------
    -- `title`, `showSessionName`, `showDuration` and `showTotals` LIVED HERE and
    -- are gone. Each said something already on screen: a second name for a window
    -- that has one, "Overall" beside a window called Overall, the length of a
    -- segment the header's own picker names, and a group total over a column
    -- holding the same figure per player. The header draws `window.name` now, so
    -- renaming a window renames its header.
    header = {
        font            = "Friz Quadrata TT",
        size            = 12,
        outline         = "OUTLINE",   -- NONE | OUTLINE | THICKOUTLINE | MONOCHROME
        -- OFF, on both new keys, and deliberately: a setting added to a shipped
        -- window must not change how that window already looks. A shadow under
        -- an outlined face is heavier than either alone, and a class-colored
        -- header is a taste rather than an improvement.
        shadow          = false,
        -- The ONE thing that colours the header text, and there is deliberately no
        -- mode beside it. The title bar is one strip over the whole window, so
        -- "per statistic" could only ever paint it the sort column's colour -- a
        -- fact already on screen twice over -- and "class" could only be the local
        -- player's, which the title bar is not about either: it names the window.
        color           = { r = 1, g = 0.82, b = 0, a = 1 },  -- Blizzard gold
        align           = "LEFT",      -- LEFT | CENTER | RIGHT
        height          = 18,
        bgColor         = { r = 0, g = 0, b = 0, a = 0.5 },
    },

    -- -----------------------------------------------------------------------
    -- columnHeader — the "Player | Damage | Healing" strip above the rows
    -- -----------------------------------------------------------------------
    --
    -- SEPARATE FROM BOTH NEIGHBOURS, and it was not before. The column headers
    -- used to take their font PATH from `text`, their size from `text`, their
    -- outline from `header` and their colour from `header` — so changing the
    -- cell font silently restyled the headers, and there was no way to make the
    -- headers differ from the numbers under them at all.
    --
    -- Every default below is the value that muddle already resolved to, so an
    -- existing window looks identical after the upgrade; what changes is that
    -- the settings are now reachable and independent.
    columnHeader = {
        font     = "Friz Quadrata TT",
        size     = 11,
        outline  = "OUTLINE",   -- NONE | OUTLINE | THICKOUTLINE | MONOCHROME
        -- Both off for the reason the header's are: a new setting must not
        -- restyle a window that already exists.
        shadow   = false,
        color    = { r = 1, g = 0.82, b = 0, a = 1 },   -- Blizzard gold
        -- The local player's class, like the header's -- the strip labels the
        -- grid rather than any row in it.
        colorMode  = "custom",
        -- Transparent: the strip has never had a backdrop, and defaulting one on
        -- would change every existing window's appearance to introduce a setting.
        bgColorMode = "custom",
        bgColor  = { r = 0, g = 0, b = 0, a = 0 },
    },

    -- -----------------------------------------------------------------------
    -- rows — one per group member
    -- -----------------------------------------------------------------------
    rows = {
        -- 0 means "as many as fit the frame". A positive value caps it, which is
        -- what a raider wants for a window pinned to the top five.
        maxRows               = 0,
        height                = 16,
        spacing               = 1,
        growthDirection       = "DOWN",   -- DOWN | UP
        -- Pin the local player into view even when they fall off the bottom of
        -- a capped list. The single most-requested behavior of every meter.
        alwaysShowSelf        = true,
        highlightSelf         = true,
        -- Shade every other row so the grid is easier to read across. A ROW-level
        -- fact, which is why it lives here — but it is EDITED on the Bars page,
        -- beside the per-cell tint it competes with, because choosing between the
        -- two meant reading two pages.
        --
        -- The class tint itself is `bars.bgColorMode` and lives with the bars. It
        -- was briefly a row-level texture too, and tinting the row turned out to
        -- tint the two-pixel seams between the columns and lose the separators
        -- the grid is read by; painting the cells leaves them clear.
        alternatingBackground = true,
        mouseoverHighlight    = true,
    },

    -- -----------------------------------------------------------------------
    -- bars — the StatusBar inside every cell
    -- -----------------------------------------------------------------------
    bars = {
        texture       = "Blizzard Raid Bar",   -- LSM "statusbar" key
        -- class  — the source's classFilename color (NeverSecret, so always
        --          available, even mid-pull)
        -- stat   — one color per column, so a glance tells you which stat
        -- custom — a single color for every bar
        colorMode     = "class",
        -- The single color `colorMode == "custom"` paints every bar with. It is
        -- a stored setting rather than a constant in modules/Row.lua because
        -- "custom" that cannot be customized is a mode with no meaning; the
        -- shipped value is the muted blue that mode used to hardcode.
        customColor   = { r = 0.35, g = 0.55, b = 0.85, a = 1 },
        -- THE ROW TINT LIVES HERE, on the cell background, rather than on the
        -- row. Painting the row tinted the two-pixel seams between columns along
        -- with the cells and lost the separators the grid is read by; painting
        -- each cell leaves them clear.
        --
        -- `class` by default, at 0.1 — a tint, not a second bar. classFilename is
        -- NeverSecret, so it keeps working mid-pull when every number is opaque.
        bgColorMode   = "class",   -- class | stat | custom | none
        bgColor       = { r = 0, g = 0, b = 0, a = 1 },
        bgAlpha       = 0.1,
        border        = false,
        -- The outline's own thickness and colour. It used to be one pixel of the
        -- library skin's edge colour, which no setting could reach -- so "Bar
        -- border" was a switch with no dial and no swatch beside it.
        borderStyle     = "None",              -- LSM "border" key; None = flat
        borderThickness = 1,
        borderColor     = { r = 0, g = 0, b = 0, a = 1 },
        alpha         = 1.0,
        fillDirection = "LEFT",    -- LEFT (fills rightward) | RIGHT
    },

    -- -----------------------------------------------------------------------
    -- text — the FontString inside every cell
    -- -----------------------------------------------------------------------
    --
    -- Two slots per cell, each rendering exactly what it is set to and nothing
    -- else — none | smart | total | rate | percent, the same five in either
    -- position. `rate` is empty on a stat that has no per-second figure
    -- (Constants.STATS[].isRate), and `smart` is what reads that flag for you.
    --
    -- `numberFormat` picks which NumericRuleFormatter instance modules/Format.lua
    -- hands the value to. NOTHING here divides: abbreviating is arithmetic and
    -- arithmetic on a secret raises (design §4).
    text = {
        -- ONE FIGURE, AND IT IS THE ONE THE COLUMN IS ABOUT. `smart` is the
        -- per-second figure on a stat that has one — "who is doing the most
        -- damage right now" is what a meter is read for, and the running total
        -- answers it least well — and the absolute figure on every stat that
        -- does not, because a kick count per second is not a number. The right
        -- slot ships empty; a player who wants `12.4M  188K` sets it to `total`.
        --
        -- EVERY VALUE IS LITERAL. There is no fallback anywhere in modules/Row.lua:
        -- `none` renders nothing, `rate` on a counting stat renders nothing, and
        -- a cell whose slots both come back empty stays empty. Both slots take all
        -- five values in either position.
        leftSlot     = "smart",   -- none | smart | total | rate | percent
        rightSlot    = "none",    -- none | smart | total | rate | percent
        numberFormat = "abbreviated",  -- abbreviated | full
        -- How a death is labelled in the Deaths tooltip and the death list.
        deathTimeFormat = "clock",     -- clock | ago
        -- Characters, not bytes, and 0 means "no cap". Above WoW's 12-character
        -- player-name limit because a meter also lists NPCs, which are not bound
        -- by it. The realm is stripped regardless of this number.
        maxNameLength = 20,
        -- THE HEADER'S FACE, not the monospace one.
        --
        -- A monospace grid keeps columns of digits from jittering as they tick,
        -- which is a real argument and the reason this shipped as JetBrains Mono.
        -- It is outweighed by the window not looking like the rest of the
        -- collection: this is a main window, and Loot History and Bank Ledger both
        -- draw theirs in the game's own face. The debug console is a different
        -- thing with a different job and keeps its monospace.
        --
        -- The jitter argument also lost most of its force when the numbers started
        -- abbreviating: "1.41M" is four glyphs whatever the value, where
        -- "1410000" was seven and "53571.392857143" was fifteen.
        font         = "Friz Quadrata TT",
        size         = 11,
        outline      = "NONE",
        shadow       = true,
        color        = { r = 1, g = 1, b = 1, a = 1 },
        -- THIS one takes the ROW's class, not the local player's: a cell is about
        -- the player whose row it is. The Player column has always been drawn
        -- that way; this extends it to the numbers. Off by default, because the
        -- numbers reading white against nine bar colors is what makes a grid
        -- scannable.
        colorMode    = "custom",
        alpha        = 1.0,
    },

    -- -----------------------------------------------------------------------
    -- icons — the class / spec / role marks in the name column
    -- -----------------------------------------------------------------------
    --
    -- classFilename and specIconID are NeverSecret, so these render correctly
    -- even at the height of a pull when every number on the row is opaque.
    icons = {
        -- ONE SLOT, ONE TOGGLE. The three separate flags let a player ask for
        -- three icons in the name column, which is three chances to push the
        -- name out of a column that has to hold a name. What the icon is for is
        -- "which unit is this row", and the spec answers that better than the
        -- class does whenever it is known — so the slot picks for itself:
        -- spec if there is one, class otherwise, and never a role.
        showIcon  = true,
        size      = 14,
        position  = "LEFT",   -- LEFT | RIGHT of the name text
    },

    -- -----------------------------------------------------------------------
    -- tooltip — the cell spell breakdown
    -- -----------------------------------------------------------------------
    tooltip = {
        -- CURSOR | TOP | BOTTOM | LEFT | RIGHT
        --        | TOPLEFT | TOPRIGHT | BOTTOMLEFT | BOTTOMRIGHT
        -- Above the cell, in ONE place. "At cursor" was the default and is gone:
        -- over a grid it lands wherever the pointer happens to be inside a cell,
        -- so the same hover puts the tooltip somewhere different every time.
        anchor             = "TOP",
        -- The TOOLTIP's scale, not the window's: a player who wants a bigger grid
        -- and a small tooltip is asking two questions. Put back to 1 when the
        -- tooltip closes, because GameTooltip is Blizzard's and shared.
        scale              = 1.0,
        -- Nudge applied on top of whichever anchor is chosen, in pixels. Passed
        -- to GameTooltip:SetOwner, which takes the pair natively — so the client
        -- still does the placing and nothing here reads geometry back off a
        -- frame (rule R3).
        offsetX            = 0,
        offsetY            = 0,
        showSpells         = true,
        -- 0 means "every spell the breakdown collected", which is
        -- modules/Tooltip.lua's COLLECT_LIMIT and not literally unbounded — the
        -- collector never pulls more than that, and the "and N more" line stays
        -- honest about anything past it.
        maxSpells          = 10,
        -- Hovering the NAME cell summarizes every enabled stat for that player,
        -- which is the cross-column read the whole addon exists for.
        showAllStatsOnName = true,
        -- Off by default: the tooltip is unprotected and its numbers go through
        -- the formatter like any other, so there is nothing unsafe about it in
        -- combat — but a tooltip under the cursor during a pull is in the way.
        hideInCombat       = false,

        -- The spell line's own appearance. Separate from `bars` on purpose: the
        -- tooltip is a different surface at a different size, and a texture that
        -- reads well across a 90px cell often does not across a 14px line.
        barTexture         = "Blizzard Raid Bar",  -- LSM "statusbar" key
        barSpacing         = 1,                    -- px between tooltip lines
        -- The fill and the backdrop each carry a colour, a MODE and an opacity.
        -- The fill was the hovered player's class with no setting reaching it; the
        -- backdrop was a hard-coded black at 0.35 with none either. It ships at
        -- 0.1: these bars sit on the tooltip's own dark backdrop, so a third of
        -- a screen of black over it read as a smear rather than an empty bar.
        barColor           = { r = 0.6, g = 0.6, b = 0.6, a = 1 },
        barColorMode       = "class",
        barAlpha           = 0.85,
        barBgColor         = { r = 0, g = 0, b = 0, a = 1 },
        barBgColorMode     = "custom",
        barBgAlpha         = 0.1,
        barBorderStyle     = "None",               -- LSM "border" key
        barBorderSize      = 1,
        barBorderColor     = { r = 0, g = 0, b = 0, a = 1 },

        -- Applied to the addon's own number slots AND to the tooltip's line
        -- FontStrings, which are SHARED with every other addon — so every line
        -- touched is restored when the tooltip hides. See modules/Tooltip.lua.
        font               = "Friz Quadrata TT",
        fontSize           = 12,
        fontOutline        = "NONE",   -- NONE | OUTLINE | THICKOUTLINE | MONOCHROME
        -- Off, so the tooltip keeps the face it has always had.
        fontShadow         = false,
        -- Both number slots on a spell line. The amount used to be hardcoded
        -- gold and the share hardcoded white, which read as two kinds of number
        -- when they are one row's two figures.
        textColor          = { r = 1, g = 1, b = 1, a = 1 },
        -- The HOVERED row's class. A tooltip is already about one player, which
        -- is what makes the question answerable here and not on the header.
        colorMode          = "custom",

        -- Which enemies this player hit, cross-referenced out of the meter's
        -- EnemyDamageTaken data by modules/Targets.lua — which is NOT a column in
        -- this addon's grid (issue #2), only a source it reads. OFF by default: it is
        -- one provider call per enemy on a hover, and it is a summation, so it is
        -- absent for the whole of a pull (see that file's header).
        showTargets        = false,
        maxTargets         = 3,
    },

    -- -----------------------------------------------------------------------
    -- visibility — where this window shows itself
    -- -----------------------------------------------------------------------
    --
    -- Refused AT THE SOURCE (performance-§6): a hidden window does not just skip
    -- its draw, it stops asking the provider for data at all.
    -- SHOW EVERYWHERE, HIDE NOWHERE. Every context ships on and every rule ships
    -- off, so a fresh profile draws the meter wherever the player is standing and
    -- nothing takes it away until they ask for it.
    --
    -- This is a deliberate reversal of the shape that shipped in 0.1.0, where the
    -- open world was off and four rules were on. That version was arguing about
    -- taste on the player's behalf — it decided a meter in the open world was
    -- noise — and the cost of being wrong was the worst failure a visibility
    -- feature has: a window that never appears, with seventeen checkboxes to read
    -- before you can work out which one did it. A default that only ever shows
    -- has no such failure. Every rule here is opt-in, and each one hides exactly
    -- one thing the player went looking for.
    --
    -- Every rule is HIDE-shaped so that a key missing from a stored window reads
    -- as "nothing objects" — see modules/Visibility.lua's ShouldShow.
    visibility = {
        dungeon      = true,
        raid         = true,
        arena        = true,
        battleground = true,
        delve        = true,
        scenario     = true,
        world        = true,

        hideWhenSolo      = false,
        hideInVehicle     = false,
        hideWhenMounted   = false,
        hideWhenSkyriding = false,
        hideOnTaxi        = false,
        hideInHousing     = false,
        hideInPetBattle   = false,
        hideWhenDead      = false,
        hideInCombat      = false,
        hideOutOfCombat   = false,
    },

    -- -----------------------------------------------------------------------
    -- columns — the ordered stat list, left to right
    -- -----------------------------------------------------------------------
    --
    -- Filled by NS.DefaultWindow from Constants.DEFAULT_STAT_KEYS rather than
    -- written out here, so the catalog stays the single source of truth for
    -- which stats exist and which ship enabled (core/Constants.lua).
    columns = {},

    -- -----------------------------------------------------------------------
    -- data — what this window reads and how it orders it
    -- -----------------------------------------------------------------------
    data = {
        -- OVERALL rather than Current. "Current" is empty between pulls, and a
        -- window that is blank most of the time reads as a broken addon rather
        -- than as an idle one — the "waiting for combat data" notice was the
        -- single most common thing a new install showed. Overall always has
        -- something in it, and a player who wants just this pull picks it out of
        -- the header's segment dropdown.
        sessionType = Const.SESSION_TYPE.Overall,
        -- value    — sort by the sort column's numbers. Attempted only while
        --            comparison is legal, and falls through to `provider` when
        --            it is not (design rule R2).
        -- provider — follow the order Blizzard returns combatSources in. Legal
        --            in combat because iteration needs no comparison.
        -- roster   — group order, then role, then name. Never reshuffles.
        sortMode    = "value",
        sortColumn  = "DamageDone",
        -- Largest first. Toggled by clicking the sort column's header.
        sortAscending = false,
        -- `mergePets` and `throttle` USED TO LIVE HERE and are now addon-wide,
        -- at `profile.data` below. Neither is a property of how a window looks,
        -- which is the test everything else in this template passes: one is a
        -- statement about what a pet's damage IS, and the other is a refresh
        -- rate. A player who wanted them to differ between two windows on the
        -- same screen would be describing two different answers to one
        -- question. core/Database.lua's v4 -> v5 step lifts them.
    },
}

--- A brand-new window config, deep-copied so nothing is shared with the
--- template or with any existing window.
---
--- @param id number|nil    the window id to stamp (WindowManager supplies it)
--- @param name string|nil  display name; defaults to the template's
--- @return table
function NS.DefaultWindow(id, name)
    local w = copy(WINDOW_TEMPLATE)
    w.id = id
    if name then w.name = name end

    -- Columns are derived rather than literal: adding a stat to the catalog with
    -- defaultEnabled = true puts it in every new window with no edit here, and
    -- the ORDER is the catalog's order. `showBar` is true for every default
    -- column — the bar is what makes the grid readable at a glance, and a
    -- player who wants numbers only turns it off per column.
    for _, key in ipairs(Const.DEFAULT_STAT_KEYS) do
        local stat = Const.STAT_BY_KEY[key]
        w.columns[#w.columns + 1] = {
            stat    = key,
            width   = stat and stat.defaultWidth or 80,
            showBar = true,
        }
    end

    return w
end

-- Published for tests and for the settings panel's per-group "copy from" and
-- "reset this group" actions, which need the shipped value of one group without
-- rebuilding a whole window.
NS.WINDOW_TEMPLATE = WINDOW_TEMPLATE

--- One addon-wide `data.*` setting, with the shipped value as the floor.
---
--- The ONE reader for `profile.data`, because three modules want these two
--- values (modules/Aggregator.lua and modules/Export.lua want `mergePets`,
--- modules/Window.lua wants `throttle`) and each reaching into `NS.db` for
--- itself is three chances to disagree about what a missing db means.
---
--- The fallback is the DEFAULTS TREE rather than a literal: this file is the
--- only place a profile default is hardcoded (savedvariables-§2), and a second
--- copy of 0.25 in a module is a value that can drift from the schema row that
--- claims to set it.
---
--- @param key string  a leaf under `data.`
--- @return any
function NS.DataSetting(key)
    local profile = NS.db and NS.db.profile
    local stored  = profile and profile.data and profile.data[key]
    if stored ~= nil then return stored end
    return NS.defaults.profile.data[key]
end

-- ---------------------------------------------------------------------------
-- The profile
-- ---------------------------------------------------------------------------

--- The AceDB defaults table. `global.schemaVersion` is addon-wide rather than
--- per-profile so a migration runs once per ACCOUNT (savedvariables-§1); see
--- core/Database.lua's migration runner.
---
--- `profile.windows` is deliberately EMPTY here and seeded with exactly one
--- window by NS:InitDB(). It cannot be a default: AceDB's defaults merge would
--- fold the seed window back into a profile from which the user had deleted
--- their last window, resurrecting it on every login.
NS.defaults = {
    profile = {
        -- Master enable. Off means no window draws and no provider read happens.
        enabled      = true,

        -- The window registry: an ARRAY of window config tables, in the order
        -- the picker lists them. Seeded with one window on first creation.
        windows      = {},

        -- Monotonic id source. Ids are never reused, so a deleted window's id
        -- cannot be handed to a new window and inherit a stale active-window
        -- pointer or a stale per-window schema path.
        nextWindowId = 1,

        -- Minimap / DataBroker button (LibDBIcon-1.0 owns the shape of this
        -- table — `hide` is its key, not ours).
        minimap      = { hide = false },

        -- How the meter is read, addon-wide. Both of these were per-window and
        -- neither described a window: `mergePets` says what a pet's damage IS,
        -- and `throttle` is a refresh rate. Two windows disagreeing about either
        -- is two answers to one question, and the settings tree was the only
        -- thing asking it twice.
        data         = {
            -- A pet gets its OWN row. Merging it into its owner is addition, and
            -- addition on two secret values raises — so the merged mode cannot do
            -- it mid-pull and drops the pet's numbers instead, leaving the owner's
            -- total quietly low for the whole fight. A separate row is exact in
            -- both states, and is what Blizzard's own meter shows.
            mergePets = false,
            -- Seconds between refreshes. The meter events fire far faster than a
            -- human reads; this coalesces them so a busy pull cannot drive one
            -- rebuild per event. Clamped to Constants.THROTTLE_MIN/MAX.
            throttle  = 0.25,
        },

        -- What the export surface remembers between uses. ADDON-WIDE rather
        -- than per-window, and that is the one deliberate exception to the rule
        -- the header above states: these four describe an ACTION the player
        -- takes, not how a window looks. "I print the top five to party" is a
        -- habit, and making them re-state it for every window they own would be
        -- the settings tree being tidy at the player's expense.
        --
        -- `channel` ships as SELF — printed to nobody but the player — because
        -- the export surface is a glyph in a title bar and a misclick must not
        -- be able to put someone's numbers in front of a raid.
        export       = {
            -- The first entry of core/Constants.lua's STATS catalog — a real stat,
            -- not a sentinel. Export.Open reseeds this from the invoking window's
            -- sort column on every open, so this value is only ever seen on a
            -- profile whose export modal has never been opened.
            metric    = Const.STATS[1].key,
            channel   = "SELF",        -- a Constants.EXPORT_CHANNELS key
            whisperTo = "",            -- meaningful only while channel is WHISPER
            lines     = 5,             -- ranked lines per chat export, 1..MAX_ROWS
        },
    },
    global = {
        schemaVersion = 1,
        -- The remembered roster: who was in the group while the meter's current
        -- data was being collected, and whose pet was whose.
        --
        -- PERSISTED, and it has to be. It began as session-only state, and a
        -- `/reload` after leaving a dungeon emptied the window right back down to
        -- one row — the meter's data survives a reload, so the map of who those
        -- GUIDs belong to has to survive it too or the filter throws the data
        -- away all over again.
        --
        -- Global rather than per-profile: it describes the CLIENT's meter data,
        -- which one AceDB profile does not own and a profile swap does not
        -- change. Cleared when C_DamageMeter resets, which is the moment the
        -- numbers those GUIDs belonged to stop existing.
        roster = { byGuid = {}, pets = {} },
    },
}

-- The collection's short alias for the defaults tree, so a reader who learned
-- `NS.C` in a sibling addon finds the same thing here.
NS.C = NS.defaults.profile
