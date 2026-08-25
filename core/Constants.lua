-- core/Constants.lua
--
-- Named constants pulled out of the modules so each value lives in exactly one
-- place and a reader doesn't have to puzzle out a magic number at the use site.
--
-- TOC POSITION: second in the core block — after core/Compat.lua and BEFORE
-- core/Namespace.lua — so every consumer loaded later can read NS.Constants.*
-- without an existence check. Nothing below reads a field this file did not
-- itself publish, so sitting ahead of Namespace costs nothing: the only external
-- table it touches is `_G.Enum`, which the client owns.
--
-- This file MUST stay free of logic — no frame creation, no event registration,
-- no API calls beyond reading Enum tables — so that loading it early has no side
-- effects. Add a constant here only when it is used across modules, or when a
-- comment at the use site would otherwise have to explain the number.
--
-- The largest thing here is the STAT CATALOG: the single source of truth for
-- which Enum.DamageMeterType values this addon is willing to show. Add a column
-- to the addon by adding a row to it; the settings panel's column editor, the
-- defaults, the aggregator's per-stat read loop and the tooltip's header all
-- read the same table.

local addonName, NS = ...

local Constants = {}
NS.Constants = Constants

-- Short alias matching the collection's `Const` idiom. Both names point at the
-- same table, so a reader who learned one in a sibling addon finds it here.
NS.Const = Constants

-- ---------------------------------------------------------------------------
-- Shipped media
-- ---------------------------------------------------------------------------

-- The monospace face, from LibKa0s rather than from this addon. A meter is a grid
-- of numbers, and proportional digits make a column jitter as it ticks; a
-- monospace face is what makes "12.4M / 9.87M / 240K" line up on the decimal.
--
-- IT USED TO BE OURS, under media/fonts/. It ships inside the LibKa0s payload now
-- (v1.9.0, `LibKa0s-Media-1.0`) so that every Ka0s addon prints its numbers in
-- one face rather than in one copy of it each — see core/MediaSetup.lua, which
-- publishes this seam and registers the face with LibSharedMedia.
--
-- THE FALLBACK IS A REAL CLIENT FONT, NOT NIL. A degraded install has no LibKa0s
-- and therefore no face, and every reader of this constant uses it as the last
-- rung of a `path or FONT_MONO or STANDARD_TEXT_FONT` chain — so a nil here would
-- fall through, but a path to a file that is not there would NOT: SetFont takes
-- it, fails to load it, and the text simply does not draw. Resolving to the
-- client's own font means a degraded install loses the monospace grid and keeps
-- every number on screen.
Constants.FONT_MONO = NS.MediaFont and NS.MediaFont("JetBrains Mono")
    or _G.STANDARD_TEXT_FONT

-- The LibSharedMedia key the font is registered under — by the LIBRARY, whose
-- catalog spells it this way (`LibKa0s-Media-1.0`'s `FONTS`). Kept beside the
-- path so this addon's defaults, which name the font by key, cannot drift from
-- what was registered.
Constants.FONT_MONO_NAME = "JetBrains Mono"

-- ---------------------------------------------------------------------------
-- Enum resolution
-- ---------------------------------------------------------------------------
--
-- C_DamageMeter and its enums are new in 12.0. On a client that does not have
-- them, `Enum.DamageMeterType.Interrupts` is an index into nil and raises at
-- FILE LOAD — which would take the whole addon down before it could render the
-- "meter unavailable" notice it already knows how to show.
--
-- So every enum read below is guarded and falls back to the documented numeric
-- literal. The literals are not a guess: they are the values published on
-- warcraft.wiki.gg for 12.0 and restated in docs/superpowers/specs. If Blizzard
-- ever renumbers them, the guarded read wins on any client that HAS the enum,
-- and only a client that lacks it entirely — where the meter does not exist —
-- would use the stale literal.

local function enumValue(enumName, key, fallback)
    local group = _G.Enum and _G.Enum[enumName]
    local value = group and group[key]
    if type(value) == "number" then return value end
    return fallback
end

--- Enum.DamageMeterType, resolved defensively. The values this addon actually
--- reads; Dps (1) and Hps (3) are deliberately ABSENT because it never queries
--- them — `amountPerSecond` ships on the same source row as `totalAmount`, so
--- one DamageDone read fills both halves of the Damage column (design §3).
Constants.STAT_TYPE = {
    DamageDone           = enumValue("DamageMeterType", "DamageDone",           0),
    HealingDone          = enumValue("DamageMeterType", "HealingDone",          2),
    Absorbs              = enumValue("DamageMeterType", "Absorbs",              4),
    Interrupts           = enumValue("DamageMeterType", "Interrupts",           5),
    Dispels              = enumValue("DamageMeterType", "Dispels",              6),
    DamageTaken          = enumValue("DamageMeterType", "DamageTaken",          7),
    AvoidableDamageTaken = enumValue("DamageMeterType", "AvoidableDamageTaken", 8),
    Deaths               = enumValue("DamageMeterType", "Deaths",               9),
    EnemyDamageTaken     = enumValue("DamageMeterType", "EnemyDamageTaken",    10),
}

--- Enum.DamageMeterSessionType. `Current` is the live pull, `Overall` is the
--- accumulated run, `Expired` is what the client keeps after a session closes.
--- Windows default to Current (design §8).
Constants.SESSION_TYPE = {
    Overall = enumValue("DamageMeterSessionType", "Overall", 0),
    Current = enumValue("DamageMeterSessionType", "Current", 1),
    Expired = enumValue("DamageMeterSessionType", "Expired", 2),
}

--- Enum.DamageMeterSourceDisplayType. Rows are filtered to Ally; Enemy rows are
--- what the EnemyDamageTaken column is made of, and None is the "not a
--- displayable source" marker.
Constants.SOURCE_DISPLAY_TYPE = {
    None  = enumValue("DamageMeterSourceDisplayType", "None",  0),
    Ally  = enumValue("DamageMeterSourceDisplayType", "Ally",  1),
    Enemy = enumValue("DamageMeterSourceDisplayType", "Enemy", 2),
}

-- ---------------------------------------------------------------------------
-- The stat catalog
-- ---------------------------------------------------------------------------
--
-- One row per column the addon can show, in the order the column editor offers
-- them. Fields:
--
--   key            stable identifier. This is what a window's column config
--                  stores, what `/mm` accepts, and what a test asserts on. It is
--                  NOT the enum name by accident — it is the enum name on
--                  purpose, so a reader holding Blizzard's documentation can map
--                  a row to an API value without a lookup table.
--   enumValue      the Enum.DamageMeterType number handed to the provider.
--   label          full English label for the settings panel and the tooltip
--                  header. LOCALIZE AT THE USE SITE — `NS.L[stat.label]` — never
--                  here: locales/enUS.lua may load before or after this file
--                  depending on the TOC, and a value frozen at load would miss a
--                  locale that registers later.
--   shortLabel     the three-or-four letter form. Still used by anything that
--                  has to fit a name into almost no width; the column HEADER no
--                  longer uses it (see headerLabel).
--   headerLabel    what the grid's column header says. Optional — defaults to
--                  `label`, and is only spelled out where the full label does not
--                  fit COLUMN_WIDTH. Full words beat initialisms in a header: a
--                  player reading "AVD" has to remember what it stood for, and
--                  the header is read far less often than the numbers under it,
--                  so the space is worth spending.
--   isCount        the session reports this stat as ONE ROW PER EVENT rather
--                  than as a per-source total, so the figure is how many rows a
--                  GUID has and `totalAmount` is meaningless. TRUE only for
--                  Deaths — see the note on the catalog row.
--   isRate         whether `amountPerSecond` is meaningful for this stat. TRUE
--                  ONLY for DamageDone and HealingDone. Counting stats (kicks,
--                  dispels, deaths) do carry an amountPerSecond field, but
--                  "0.42 interrupts per second" is noise, and the text assembler
--                  uses this flag to decide whether the right-hand text slot has
--                  anything to say.
--   defaultWidth   pixel width of the cell when the column is first added.
--                  UNIFORM ACROSS EVERY STAT — see COLUMN_WIDTH below.
--   defaultEnabled whether a brand-new window ships with this column.
--
-- ADDING A STAT: add a row. Nothing else in the addon enumerates these values.

--- The width every column is born at.
---
--- ONE NUMBER FOR EVERY STAT, and that is the point. Sizing each column to its
--- own content — 92 for damage, 44 for deaths — produced a ragged grid whose
--- header labels sat at nine different offsets, and the eye reads a meter by
--- scanning down a column, which a ragged grid makes harder for a saving of a
--- few dozen pixels. 92 is the widest of the old per-stat values (damage's),
--- which is the one that has to hold "1.41M" and a rate beside it; every other
--- column simply has room to spare.
---
--- Per-column width remains a SETTING. This is the default, not a constraint —
--- a player who wants a narrow deaths column still has one.
Constants.COLUMN_WIDTH = 92

-- Gap between two adjacent columns. Not a setting: it is the visual seam that
-- keeps two numbers from reading as one, and a player who wants more space
-- widens the column.
--
-- Lives here rather than in modules/Window.lua because the layout builder and
-- core/Database.lua's width migration both have to agree on it — the migration
-- sizes a frame to hold the grid the layout builder is about to lay out, and two
-- copies of "2" is the duplicate that drifts the first time one of them changes.
Constants.COLUMN_GAP = 2

-- The narrowest a stat column may be drawn.
--
-- Columns share the frame's width equally, so dragging the window narrow keeps
-- squeezing them — and below this a column cannot hold an abbreviated number and
-- its header at the same time, which is the point at which the window stops
-- being a meter. modules/Window.lua stops shrinking here and clamps the frame
-- instead of drawing something illegible.
Constants.COLUMN_MIN_WIDTH = 50
Constants.STATS = {
    {
        key = "DamageDone", enumValue = Constants.STAT_TYPE.DamageDone,
        label = "Damage", shortLabel = "DMG",
        isRate = true, defaultWidth = Constants.COLUMN_WIDTH, defaultEnabled = true,
    },
    {
        key = "HealingDone", enumValue = Constants.STAT_TYPE.HealingDone,
        label = "Healing", shortLabel = "HEAL",
        isRate = true, defaultWidth = Constants.COLUMN_WIDTH, defaultEnabled = true,
    },
    {
        key = "Absorbs", enumValue = Constants.STAT_TYPE.Absorbs,
        label = "Absorbs", shortLabel = "ABS",
        isRate = false, defaultWidth = Constants.COLUMN_WIDTH, defaultEnabled = false,
    },
    {
        key = "Interrupts", enumValue = Constants.STAT_TYPE.Interrupts,
        label = "Interrupts", shortLabel = "INT",
        isRate = false, defaultWidth = Constants.COLUMN_WIDTH, defaultEnabled = true,
    },
    {
        key = "Dispels", enumValue = Constants.STAT_TYPE.Dispels,
        label = "Dispels", shortLabel = "DIS",
        isRate = false, defaultWidth = Constants.COLUMN_WIDTH, defaultEnabled = true,
    },
    {
        key = "DamageTaken", enumValue = Constants.STAT_TYPE.DamageTaken,
        label = "Damage Taken", shortLabel = "DTK", headerLabel = "Taken",
        isRate = false, defaultWidth = Constants.COLUMN_WIDTH, defaultEnabled = false,
    },
    {
        key = "AvoidableDamageTaken", enumValue = Constants.STAT_TYPE.AvoidableDamageTaken,
        label = "Avoidable Damage", shortLabel = "AVD", headerLabel = "Avoidable",
        isRate = false, defaultWidth = Constants.COLUMN_WIDTH, defaultEnabled = true,
    },
    {
        key = "Deaths", enumValue = Constants.STAT_TYPE.Deaths,
        label = "Deaths", shortLabel = "DTH",
        -- DEATHS IS COUNTED, NOT SUMMED, and this flag is the whole reason the
        -- column read zero for everybody.
        --
        -- Every other stat hands back one source row per player carrying that
        -- player's total. Deaths hands back one row PER DEATH — the same
        -- sourceGUID appears once for each time they died, each with its own
        -- deathRecapID, and `totalAmount` is 0 on every one of them (and 0 on the
        -- session). Reading totalAmount therefore answers 0, correctly and
        -- uselessly. The figure a player means by "deaths" is how many rows they
        -- have.
        --
        -- Counting is arithmetic on a number THIS ADDON produced, not on a meter
        -- value, so it stays legal mid-pull where summing two secrets would not.
        isCount = true,
        isRate = false, defaultWidth = Constants.COLUMN_WIDTH, defaultEnabled = true,
    },
    {
        key = "EnemyDamageTaken", enumValue = Constants.STAT_TYPE.EnemyDamageTaken,
        label = "Enemy Damage Taken", shortLabel = "EDT", headerLabel = "Enemy Taken",
        isRate = false, defaultWidth = Constants.COLUMN_WIDTH, defaultEnabled = false,
    },
}

--- key -> catalog row, built from the array above so the two cannot disagree.
--- Consumers that hold a stored column's `stat` string resolve it through here
--- and treat nil as "a column the user configured against a build that offered
--- more stats than this one" — which they drop rather than render blank.
Constants.STAT_BY_KEY = {}
for _, stat in ipairs(Constants.STATS) do
    Constants.STAT_BY_KEY[stat.key] = stat
end

--- The default column set, in display order, left to right after the name
--- column: Damage · Healing · Interrupts · Dispels · Avoidable Damage · Deaths
--- (design §5). Derived from `defaultEnabled` rather than restated, so the two
--- can never drift; the ORDER is the catalog's order, which is why the catalog
--- is written in the order a player wants to read.
Constants.DEFAULT_STAT_KEYS = {}
for _, stat in ipairs(Constants.STATS) do
    if stat.defaultEnabled then
        Constants.DEFAULT_STAT_KEYS[#Constants.DEFAULT_STAT_KEYS + 1] = stat.key
    end
end

-- Width of the leading name column. Not a stat — every row has one and it can
-- never be removed — so it is a constant rather than a catalog entry.
--
-- WIDER THAN COLUMN_WIDTH ON PURPOSE, and the one place the uniform grid is
-- deliberately broken: it holds a class icon, a spec icon, a role icon and a
-- name of up to `text.maxNameLength` characters, where a stat column holds two
-- short numbers. 140 fits the 20-character default cap at 11pt with the icon
-- row in front of it.
Constants.NAME_COLUMN_WIDTH = 118

-- ---------------------------------------------------------------------------
-- The export channel catalog
-- ---------------------------------------------------------------------------
--
-- One row per destination the export modal's "Print to Chat" can reach, in the
-- order the dropdown lists them. Fields:
--
--   key          stable identifier. This is what the profile stores and what
--                `/mm set export.channel` accepts. For the five ordinary
--                channels it is SendChatMessage's own chatType string, on
--                purpose rather than by accident, so a reader holding
--                Blizzard's documentation can map a row to the API call
--                without a lookup table.
--   label        full English label for the settings dropdown and the modal.
--                LOCALIZE AT THE USE SITE — `NS.L[channel.label]` — never here,
--                for exactly the reason the stat catalog above gives.
--   chatType     the string handed to SendChatMessage, or nil where there is
--                nothing to hand it: AUTO has not decided yet and SELF never
--                sends at all.
--   auto         resolve this row at send time, walking EXPORT_AUTO_ORDER.
--   selfOnly     print through NS.Print and send nothing.
--   needsTarget  the whisper-name field is meaningful for this row.
--
-- SELF IS THE SHIPPED DEFAULT, and that is a safety decision rather than a
-- timid one: every other row puts the player's numbers in front of other
-- people, and a misclick on a glyph in a title bar must not be able to do that.
--
-- ADDING A CHANNEL: add a row. The settings dropdown and the export module both
-- derive from this array and neither restates it.
Constants.EXPORT_CHANNELS = {
    { key = "AUTO",          label = "Auto",            chatType = nil,             auto = true },
    { key = "SAY",           label = "Say",             chatType = "SAY" },
    { key = "PARTY",         label = "Party",           chatType = "PARTY" },
    { key = "RAID",          label = "Raid",            chatType = "RAID" },
    { key = "INSTANCE_CHAT", label = "Instance",        chatType = "INSTANCE_CHAT" },
    { key = "GUILD",         label = "Guild",           chatType = "GUILD" },
    { key = "WHISPER",       label = "Whisper",         chatType = "WHISPER", needsTarget = true },
    { key = "SELF",          label = "Self only",       chatType = nil,             selfOnly = true },
}

--- key -> channel row, built from the array above so the two cannot disagree.
--- A stored channel this build does not offer resolves to nil, which the export
--- module treats as "print to myself" rather than as a send — the same reading
--- an unknown stat key gets from STAT_BY_KEY, and for the same reason: the safe
--- answer is the one that does nothing the player did not ask for.
Constants.EXPORT_CHANNEL_BY_KEY = {}
for _, channel in ipairs(Constants.EXPORT_CHANNELS) do
    Constants.EXPORT_CHANNEL_BY_KEY[channel.key] = channel
end

--- The ladder `AUTO` walks, in resolution order: the instance group first (it is
--- the one channel everybody in a dungeon or a battleground can read), then raid,
--- then party, then say for a player standing alone.
---
--- Stated as KEYS into the catalog above rather than as chatType literals, so a
--- row renamed there cannot leave a stale string here that resolves to nothing.
Constants.EXPORT_AUTO_ORDER = { "INSTANCE_CHAT", "RAID", "PARTY", "SAY" }

-- ---------------------------------------------------------------------------
-- The message bus
-- ---------------------------------------------------------------------------
--
-- Modules talk to each other through AceEvent messages named
-- "Ka0s_MultiMeters_<Event>" and never by reaching into another module's table
-- (architecture-§4). Every name is declared here so the catalog in
-- docs/ARCHITECTURE.md has one place to be checked against, and so a typo in a
-- subscriber is a nil-index at load rather than a callback that silently never
-- fires.
--
-- ONE SENDER EACH. The owner is named in the comment beside each constant; a
-- second sender is a bug, not a convenience.
Constants.MSG = {
    -- core/MultiMeters.lua fans the raw game events onto the bus. Nothing else
    -- registers DAMAGE_METER_* / GROUP_ROSTER_UPDATE / ... directly, so there is
    -- one place where "the game said something" becomes "the addon knows".
    METER_UPDATED       = "Ka0s_MultiMeters_METER_UPDATED",       -- current session ticked
    METER_SESSION       = "Ka0s_MultiMeters_METER_SESSION",       -- { type, sessionID }
    METER_RESET         = "Ka0s_MultiMeters_METER_RESET",         -- sessions wiped
    ROSTER_CHANGED      = "Ka0s_MultiMeters_ROSTER_CHANGED",      -- group composition moved
    ZONE_CHANGED        = "Ka0s_MultiMeters_ZONE_CHANGED",        -- instance context moved
    ENTERING_WORLD      = "Ka0s_MultiMeters_ENTERING_WORLD",      -- login / reload / zone-in
    RESTRICTION_CHANGED = "Ka0s_MultiMeters_RESTRICTION_CHANGED", -- { type, state }

    -- The player's own state, for modules/Visibility.lua's rules. Two messages
    -- rather than one because they are two different kinds of transition:
    -- COMBAT_CHANGED fires twice a pull and is the only one anything other than
    -- visibility is ever likely to want, while PLAYER_STATE_CHANGED is the
    -- catch-all edge for mounting, gliding, shapeshifting, boarding a taxi,
    -- opening a pet battle and dying. Neither carries the state itself: the
    -- rules read it live at the moment they are asked, so a payload here would
    -- be a second answer that can disagree with the first.
    COMBAT_CHANGED      = "Ka0s_MultiMeters_COMBAT_CHANGED",      -- entered or left combat
    PLAYER_STATE_CHANGED = "Ka0s_MultiMeters_PLAYER_STATE_CHANGED", -- mount / glide / taxi / ...

    -- core/Database.lua, on an AceDB profile swap / copy / reset.
    PROFILE_CHANGED     = "Ka0s_MultiMeters_PROFILE_CHANGED",     -- { newProfileKey }

    -- settings/ — the single write seam (NS.SetByPath) announces, nobody else.
    CONFIG_CHANGED      = "Ka0s_MultiMeters_CONFIG_CHANGED",      -- { section, windowId }

    -- modules/WindowManager.lua, when the window REGISTRY changes shape (a
    -- window created, deleted, renamed or duplicated). Distinct from
    -- CONFIG_CHANGED, which is a setting moving inside a window that already
    -- exists: the registry message forces a rebuild, the config message a
    -- refresh.
    WINDOWS_CHANGED     = "Ka0s_MultiMeters_WINDOWS_CHANGED",     -- { windowId, action }

    -- core/State.lua, when preview mode is toggled by the unlock state or by
    -- `/mm test`.
    TEST_MODE_CHANGED     = "Ka0s_MultiMeters_PREVIEW_CHANGED",     -- { enabled }

    -- modules/DrillDown.lua, when a window enters or leaves a per-source
    -- breakdown. Declared here rather than spelled out at the two use sites: a
    -- hand-written wire string in the sender and another in the subscriber is
    -- exactly the pair this catalog exists to make impossible to mistype.
    DRILLDOWN_CHANGED   = "Ka0s_MultiMeters_DRILLDOWN_CHANGED",   -- { windowId, active }
}

--- How long to wait before asking the player-state rules a second time, in
--- seconds.
---
--- SOME CLIENT STATE LAGS ITS OWN EVENT. IsMounted() has already flipped by the
--- time PLAYER_MOUNT_DISPLAY_CHANGED arrives; C_PlayerInfo.GetGlidingInfo's
--- canGlide has not always done so at its edge. Read at the edge alone, a
--- lagging input answers with the state the player just left — and because a
--- hidden window has no OnUpdate running, that stale answer is the last one
--- anything takes until the next zone change or settings write.
---
--- So every player-state edge is answered twice: once immediately, and once
--- after this delay. Long enough for the client to settle, short enough that a
--- window coming back is not something the player waits on.
Constants.PLAYER_STATE_SETTLE = 0.5

-- ---------------------------------------------------------------------------
-- Refresh timing
-- ---------------------------------------------------------------------------

-- Floor on the per-window refresh throttle, in seconds. The meter events fire
-- far faster than a human can read, so a window coalesces them; letting a user
-- configure the interval down to zero would turn every event into a full
-- rebuild, which is the exact failure the throttle exists to prevent
-- (performance-§6). The settings slider clamps to this.
Constants.THROTTLE_MIN = 0.05

-- Ceiling on the same slider. Past this the display reads as broken rather than
-- as economical.
Constants.THROTTLE_MAX = 2.0

-- Row-pool growth step. Frames are never destroyed, only released, so this is
-- the size of the batch created when a bigger group arrives mid-session. Sized
-- to a party so a 5-man never grows twice.
Constants.POOL_GROW_STEP = 5

-- Upper bound on rows a single window will draw regardless of configuration.
-- A 40-player raid is the largest real group; the cap exists so a corrupted
-- config cannot ask the pool for thousands of frames.
Constants.MAX_ROWS = 40
