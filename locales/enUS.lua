-- locales/enUS.lua
--
-- The default (and currently only) localization. `L` carries the metatable
-- fallback the standard mandates (anti-patterns #2): any missing key returns the
-- KEY ITSELF, so a module can ship `L["Some New String"]` without this file
-- having been updated first, and a partial translation degrades to English one
-- string at a time rather than rendering nil.
--
-- Keys ARE the English string. Translators copy this file, change the
-- right-hand sides, and rename it (deDE.lua, frFR.lua); the left-hand sides
-- never change, which is what keeps a call site stable across every locale.
--
-- ORGANIZATION mirrors the settings panel, page by page, in the order the pages
-- appear: Windows · Frame · Header · Rows · Bars · Text · Icons · Tooltip ·
-- Visibility · Columns · Data · General · Profiles. Shared vocabulary (anchor
-- points, font flags, yes/no) is collected at the end so it is not duplicated
-- into each page's block.
--
-- NOTE FOR LIBKA0S ADOPTERS: never pass this table as a library descriptor's
-- `L`. The fallback makes it answer a string for EVERY key, which shadows the
-- library's own strings entirely. Pass a plain table of just the keys you
-- actually translate (see the "L trap" section of LibKa0s' README).
--
-- locales/ loads FIRST in the TOC, ahead of core/, so this file bootstraps the
-- namespace itself.

local addonName, NS = ...

local L = setmetatable({}, {
    __index = function(_, k) return k end,
})
NS.L = L

-- ---------------------------------------------------------------------------
-- Addon shell
-- ---------------------------------------------------------------------------

L["Ka0s Mythic Meters"] = "Ka0s Mythic Meters"
L["A multi-column group meter: one row per player, one column per statistic."] =
    "A multi-column group meter: one row per player, one column per statistic."
L["Mythic Meters"] = "Mythic Meters"
L["Meter"] = "Meter"

-- ---------------------------------------------------------------------------
-- Statistics — the column catalog (core/Constants.lua's STATS[].label)
-- ---------------------------------------------------------------------------

L["Damage"] = "Damage"
L["Healing"] = "Healing"
L["Absorbs"] = "Absorbs"
L["Interrupts"] = "Interrupts"
L["Dispels"] = "Dispels"
L["Damage Taken"] = "Damage Taken"
L["Avoidable Damage"] = "Avoidable Damage"
L["Deaths"] = "Deaths"
L["Enemy Damage Taken"] = "Enemy Damage Taken"

-- Short column headers, at the width a default column gives them.
L["DMG"] = "DMG"
L["HEAL"] = "HEAL"
L["ABS"] = "ABS"
L["INT"] = "INT"
L["DIS"] = "DIS"
L["DTK"] = "DTK"
L["AVD"] = "AVD"
-- Column-header forms, for the stats whose full label does not fit a column.
L["Avoidable"] = "Avoidable"
L["Taken"] = "Taken"
L["Enemy Taken"] = "Enemy Taken"
L["DTH"] = "DTH"
L["EDT"] = "EDT"

L["Player"] = "Player"
L["Total"] = "Total"
L["Per second"] = "Per second"
L["Percent"] = "Percent"

-- ---------------------------------------------------------------------------
-- Page names
-- ---------------------------------------------------------------------------

L["Windows"] = "Windows"
L["Frame"] = "Frame"
L["Header"] = "Header"
L["Rows"] = "Rows"
L["Bars"] = "Bars"
L["Text"] = "Text"
L["Icons"] = "Icons"
L["Tooltip"] = "Tooltip"
L["Visibility"] = "Visibility"
L["Columns"] = "Columns"
L["Data"] = "Data"
L["General"] = "General"
L["Profiles"] = "Profiles"

-- ---------------------------------------------------------------------------
-- Windows page
-- ---------------------------------------------------------------------------

L["Active window"] = "Active window"
L["Which window the settings on every other page apply to. Each window is configured independently."] =
    "Which window the settings on every other page apply to. Each window is configured independently."
L["Window name"] = "Window name"
L["Name shown in this picker and, optionally, in the window's own header."] =
    "Name shown in this picker and, optionally, in the window's own header."
L["New window"] = "New window"
L["Create a new window with the default settings."] =
    "Create a new window with the default settings."
L["Duplicate window"] = "Duplicate window"
L["Create a copy of the active window, including every setting and column."] =
    "Create a copy of the active window, including every setting and column."
L["Delete window"] = "Delete window"
L["Delete the active window. This cannot be undone."] =
    "Delete the active window. This cannot be undone."
L["Delete the window '%s'?"] = "Delete the window '%s'?"
L["Copy settings from"] = "Copy settings from"
L["Copy another window's settings onto this one. Choose which group of settings to copy below."] =
    "Copy another window's settings onto this one. Choose which group of settings to copy below."
L["Settings to copy"] = "Settings to copy"
L["Copy every setting, or just one group."] = "Copy every setting, or just one group."
L["Everything"] = "Everything"
L["Copy"] = "Copy"
L["The last window cannot be deleted."] = "The last window cannot be deleted."
L["Window '%s' created."] = "Window '%s' created."
L["Window '%s' deleted."] = "Window '%s' deleted."
L["Copied %s from '%s'."] = "Copied %s from '%s'."

-- ---------------------------------------------------------------------------
-- Frame page
-- ---------------------------------------------------------------------------

L["Size and position"] = "Size and position"
L["Width"] = "Width"
L["Window width in pixels."] = "Window width in pixels."
L["Height"] = "Height"
L["Window height in pixels."] = "Window height in pixels."
L["Scale"] = "Scale"
L["Scale multiplier applied to the whole window."] =
    "Scale multiplier applied to the whole window."
L["Opacity"] = "Opacity"
L["Overall opacity of the window."] = "Overall opacity of the window."
L["Frame strata"] = "Frame strata"
L["Which layer the window sits in relative to the rest of your interface."] =
    "Which layer the window sits in relative to the rest of your interface."
L["Low"] = "Low"
L["Medium"] = "Medium"
L["High"] = "High"
L["Dialog"] = "Dialog"
L["Background color"] = "Background color"
L["Color drawn behind the rows."] = "Color drawn behind the rows."
L["Border style"] = "Border style"
L["LibSharedMedia border texture drawn around the window."] =
    "LibSharedMedia border texture drawn around the window."
L["Border thickness"] = "Border thickness"
L["Border edge size in pixels."] = "Border edge size in pixels."
L["Border color"] = "Border color"
L["Color of the window border."] = "Color of the window border."
L["Padding"] = "Padding"
L["Gap in pixels between the window edge and the rows inside it."] =
    "Gap in pixels between the window edge and the rows inside it."
L["Lock window"] = "Lock window"
L["When unlocked you can drag the window to reposition it, and it fills with placeholder data so you can see the layout."] =
    "When unlocked you can drag the window to reposition it, and it fills with placeholder data so you can see the layout."
L["Keep on screen"] = "Keep on screen"
L["Prevent the window from being dragged off the edge of the screen."] =
    "Prevent the window from being dragged off the edge of the screen."
L["Show title bar"] = "Show title bar"
L["Draw the title strip along the top of the window."] =
    "Draw the title strip along the top of the window."
L["Show close button"] = "Show close button"
L["Draw a close button in the title bar."] = "Draw a close button in the title bar."
L["Header controls"] = "Header controls"
L["Show minimise"] = "Show minimise"
L["Collapse the window to its title bar and back."] = "Collapse the window to its title bar and back."
L["Show lock"] = "Show lock"
L["Lock or unlock the window for dragging."] = "Lock or unlock the window for dragging."
L["Show settings"] = "Show settings"
L["Open this addon's settings at the window you clicked."] = "Open this addon's settings at the window you clicked."
L["Show segment picker"] = "Show segment picker"
L["Choose which fight this window shows. The session line stays clickable either way."] = "Choose which fight this window shows. The session line stays clickable either way."
L["Show reset"] = "Show reset"
L["Clear every recorded combat session. Asks first -- it wipes the game's own meter data too, not just this addon's."] = "Clear every recorded combat session. Asks first -- it wipes the game's own meter data too, not just this addon's."
L["Show export"] = "Show export"
L["Export this window's segment to CSV or to chat."] = "Export this window's segment to CSV or to chat."
L["Reveal controls on hover"] = "Reveal controls on hover"
L["Fade every control except the one under the pointer. Off keeps them all visible."] = "Fade every control except the one under the pointer. Off keeps them all visible."
L["Minimised"] = "Minimised"
L["Collapsed to the title bar. The window's stored height is untouched, so expanding restores it exactly."] = "Collapsed to the title bar. The window's stored height is untouched, so expanding restores it exactly."
L["Control color"] = "Control color"
L["Color the header controls are drawn in."] = "Color the header controls are drawn in."
L["Control hover color"] = "Control hover color"
L["Color the control under the pointer is drawn in."] =
    "Color the control under the pointer is drawn in."
L["Control size"] = "Control size"
L["How large each header control is drawn, in pixels."] = "How large each header control is drawn, in pixels."
L["Show resize grip"] = "Show resize grip"
L["Draw a drag handle in the bottom-right corner for resizing."] =
    "Draw a drag handle in the bottom-right corner for resizing."
L["Reset position"] = "Reset position"
L["Move the window back to the center of the screen."] =
    "Move the window back to the center of the screen."

-- ---------------------------------------------------------------------------
-- Header page
-- ---------------------------------------------------------------------------

L["Header text"] = "Header text"
L["Title"] = "Title"
L["Text shown in the header. Leave empty to use the window's name."] =
    "Text shown in the header. Leave empty to use the window's name."
L["Show session name"] = "Show session name"
L["Show which combat session the window is reading — the current pull, or the overall run."] =
    "Show which combat session the window is reading — the current pull, or the overall run."
L["Show duration"] = "Show duration"
L["Show how long the session has been running."] =
    "Show how long the session has been running."
L["Show totals"] = "Show totals"
L["Show the group total for the sort column."] =
    "Show the group total for the sort column."
L["Header height"] = "Header height"
L["Height of the header strip in pixels."] = "Height of the header strip in pixels."
L["Header background"] = "Header background"
L["Color drawn behind the header text."] = "Color drawn behind the header text."
L["Alignment"] = "Alignment"
L["Where the header text sits horizontally."] = "Where the header text sits horizontally."

-- ---------------------------------------------------------------------------
-- Rows page
-- ---------------------------------------------------------------------------

L["Row layout"] = "Row layout"
L["Maximum rows"] = "Maximum rows"
L["Largest number of rows to draw. Set to 0 to draw as many as the window has room for."] =
    "Largest number of rows to draw. Set to 0 to draw as many as the window has room for."
L["Row height"] = "Row height"
L["Height of one row in pixels."] = "Height of one row in pixels."
L["Row spacing"] = "Row spacing"
L["Gap in pixels between adjacent rows."] = "Gap in pixels between adjacent rows."
L["Growth direction"] = "Growth direction"
L["Whether rows stack downward from the header or upward from the bottom."] =
    "Whether rows stack downward from the header or upward from the bottom."
L["Row behavior"] = "Row behavior"
L["Always show yourself"] = "Always show yourself"
L["Keep your own row visible even when it would fall outside the maximum row count."] =
    "Keep your own row visible even when it would fall outside the maximum row count."
L["Highlight yourself"] = "Highlight yourself"
L["Mark your own row so it stands out at a glance."] =
    "Mark your own row so it stands out at a glance."
L["Alternating background"] = "Alternating background"
L["Shade every other row slightly so the grid is easier to read across."] =
    "Shade every other row slightly so the grid is easier to read across."
L["Highlight on mouseover"] = "Highlight on mouseover"
L["Brighten the row under the cursor."] = "Brighten the row under the cursor."

-- ---------------------------------------------------------------------------
-- Bars page
-- ---------------------------------------------------------------------------

L["Bar appearance"] = "Bar appearance"
L["Bar texture"] = "Bar texture"
L["LibSharedMedia statusbar texture used for every cell's bar."] =
    "LibSharedMedia statusbar texture used for every cell's bar."
L["Bar color mode"] = "Bar color mode"
L["Color bars by the player's class, by which statistic the column shows, or with one color everywhere."] =
    "Color bars by the player's class, by which statistic the column shows, or with one color everywhere."
L["Class color"] = "Class color"
L["Per-statistic color"] = "Per-statistic color"
L["Custom color"] = "Custom color"
L["Bar color"] = "Bar color"
L["Fill color used when the color mode is set to Custom color."] =
    "Fill color used when the color mode is set to Custom color."
L["Bar background color"] = "Bar background color"
L["Color drawn behind the unfilled part of each bar."] =
    "Color drawn behind the unfilled part of each bar."
L["Bar background opacity"] = "Bar background opacity"
L["Opacity of the unfilled part of each bar."] =
    "Opacity of the unfilled part of each bar."
L["Bar opacity"] = "Bar opacity"
L["Opacity of the filled part of each bar."] = "Opacity of the filled part of each bar."
L["Bar border"] = "Bar border"
L["Draw a thin outline around each bar."] = "Draw a thin outline around each bar."
L["Fill direction"] = "Fill direction"
L["Which edge of the cell each bar grows from."] =
    "Which edge of the cell each bar grows from."

-- ---------------------------------------------------------------------------
-- Text page
-- ---------------------------------------------------------------------------

L["Cell text"] = "Cell text"
L["Left text"] = "Left text"
L["What to show on the left of each cell. Set it to Total for the `1.41M  83.2K` pair; leave it empty for the per-second figure alone."] =
    "What to show on the left of each cell. Set it to Total for the `1.41M  83.2K` pair; leave it empty for the per-second figure alone."
L["Right text"] = "Right text"
L["What to show on the right of each cell. Per-second figures are only shown for Damage and Healing."] =
    "What to show on the right of each cell. Per-second figures are only shown for Damage and Healing."
L["Number format"] = "Number format"
L["Abbreviate large numbers (12.4M) or show them in full (12,400,000)."] =
    "Abbreviate large numbers (12.4M) or show them in full (12,400,000)."
L["Abbreviated"] = "Abbreviated"
L["Full"] = "Full"
L["Max name length"] = "Max name length"
L["Truncate a name past this many characters. 0 shows the whole name. The realm is always stripped."] =
    "Truncate a name past this many characters. 0 shows the whole name. The realm is always stripped."
L["Font"] = "Font"
L["Font used for every number in the grid. A monospace font keeps the columns from shifting as the numbers change."] =
    "Font used for every number in the grid. A monospace font keeps the columns from shifting as the numbers change."
L["Font size"] = "Font size"
L["Text size in pixels."] = "Text size in pixels."
L["Font outline"] = "Font outline"
L["Outline and monochrome flags applied to the text."] =
    "Outline and monochrome flags applied to the text."
L["Text shadow"] = "Text shadow"
L["Draw a drop shadow behind the text so it stays readable over a bright bar."] =
    "Draw a drop shadow behind the text so it stays readable over a bright bar."
L["Text color"] = "Text color"
L["Color of the numbers and names."] = "Color of the numbers and names."
L["Text opacity"] = "Text opacity"
L["Opacity of the numbers and names."] = "Opacity of the numbers and names."

-- ---------------------------------------------------------------------------
-- Icons page
-- ---------------------------------------------------------------------------

L["Row icons"] = "Row icons"
L["Show icon"] = "Show icon"
L["Show one icon beside each player's name: their specialization where it is known, and their class where it is not."] =
    "Show one icon beside each player's name: their specialization where it is known, and their class where it is not."
L["Icon size"] = "Icon size"
L["Size of the row icons in pixels."] = "Size of the row icons in pixels."
L["Icon position"] = "Icon position"
L["Which side of the player's name the icons sit on."] =
    "Which side of the player's name the icons sit on."

-- ---------------------------------------------------------------------------
-- Tooltip page
-- ---------------------------------------------------------------------------

L["Tooltip behavior"] = "Tooltip behavior"
L["Tooltip anchor"] = "Tooltip anchor"
L["Where the tooltip appears relative to the cursor or the window."] =
    "Where the tooltip appears relative to the cursor or the window."
L["At cursor"] = "At cursor"
L["Show spell breakdown"] = "Show spell breakdown"
L["List the individual spells behind a cell's number when you hover it."] =
    "List the individual spells behind a cell's number when you hover it."
L["Horizontal offset"] = "Horizontal offset"
L["Nudge the tooltip sideways from wherever the anchor puts it. Positive moves it right."] =
    "Nudge the tooltip sideways from wherever the anchor puts it. Positive moves it right."
L["Vertical offset"] = "Vertical offset"
L["Nudge the tooltip up or down from wherever the anchor puts it. Positive moves it up."] =
    "Nudge the tooltip up or down from wherever the anchor puts it. Positive moves it up."
L["Maximum spells"] = "Maximum spells"
L["How many spells to list in the breakdown before stopping. 0 lists every spell the breakdown found."] =
    "How many spells to list in the breakdown before stopping. 0 lists every spell the breakdown found."
L["Summarize on the name"] = "Summarize on the name"
L["Hovering a player's name shows every enabled statistic for that player at once."] =
    "Hovering a player's name shows every enabled statistic for that player at once."
L["Hide tooltips in combat"] = "Hide tooltips in combat"
L["Suppress tooltips while you are in combat so nothing sits under your cursor mid-pull."] =
    "Suppress tooltips while you are in combat so nothing sits under your cursor mid-pull."

L["Tooltip bars"] = "Tooltip bars"
L["LibSharedMedia statusbar texture drawn behind each spell line."] =
    "LibSharedMedia statusbar texture drawn behind each spell line."
L["Bar spacing"] = "Bar spacing"
L["Gap in pixels between one tooltip line and the next."] =
    "Gap in pixels between one tooltip line and the next."
L["Bar border style"] = "Bar border style"
L["LibSharedMedia border drawn around each spell bar. Most border art is cut for a window rather than a 14px line, so it may look heavy here."] =
    "LibSharedMedia border drawn around each spell bar. Most border art is cut for a window rather than a 14px line, so it may look heavy here."
L["Bar border thickness"] = "Bar border thickness"
L["Bar border color"] = "Bar border color"
L["Color of the border around each spell bar."] =
    "Color of the border around each spell bar."

L["Tooltip text"] = "Tooltip text"
L["Font used for the tooltip's spell names and numbers."] =
    "Font used for the tooltip's spell names and numbers."
L["Tooltip text size in pixels."] = "Tooltip text size in pixels."
L["Outline and monochrome flags applied to the tooltip text."] =
    "Outline and monochrome flags applied to the tooltip text."

L["Tooltip targets"] = "Tooltip targets"
L["Show targets"] = "Show targets"
L["On a Damage cell, list which enemies this player hit. Cross-referenced from the enemy damage taken column, so it is unavailable while a pull is in progress."] =
    "On a Damage cell, list which enemies this player hit. Cross-referenced from the enemy damage taken column, so it is unavailable while a pull is in progress."
L["Maximum targets"] = "Maximum targets"
L["How many enemies to list before stopping."] =
    "How many enemies to list before stopping."

L["Column headers"] = "Column headers"
L["Font used for the column header strip above the rows."] =
    "Font used for the column header strip above the rows."
L["Column header text size in pixels."] = "Column header text size in pixels."
L["Outline and monochrome flags applied to the column headers."] =
    "Outline and monochrome flags applied to the column headers."
L["Color of the column header labels."] = "Color of the column header labels."
L["Color drawn behind the column header strip. Transparent by default \226\128\148 the strip has never had a backdrop."] =
    "Color drawn behind the column header strip. Transparent by default \226\128\148 the strip has never had a backdrop."
L["Color of the amount and percentage on each tooltip line."] =
    "Color of the amount and percentage on each tooltip line."

-- Tooltip headers and rows, rendered at runtime.
L["Spell breakdown"] = "Spell breakdown"
L["Targets"] = "Targets"
L["Unknown"] = "Unknown"
L["All statistics"] = "All statistics"
L["Overkill"] = "Overkill"
L["Deadly"] = "Deadly"
L["Death recap"] = "Death recap"
L["Died at %s"] = "Died at %s"
L["Click for details"] = "Click for details"
L["Shift-click to open the death recap"] = "Shift-click to open the death recap"
L["and %d more"] = "and %d more"
L["No data yet"] = "No data yet"

-- ---------------------------------------------------------------------------
-- Visibility page
-- ---------------------------------------------------------------------------

L["Where to show this window"] = "Where to show this window"
L["Dungeons"] = "Dungeons"
L["Show this window in five-player dungeons, including Mythic+."] =
    "Show this window in five-player dungeons, including Mythic+."
L["Raids"] = "Raids"
L["Show this window in raid instances."] = "Show this window in raid instances."
L["Arenas"] = "Arenas"
L["Show this window in arena matches."] = "Show this window in arena matches."
L["Battlegrounds"] = "Battlegrounds"
L["Show this window in battlegrounds."] = "Show this window in battlegrounds."
L["Open world"] = "Open world"
L["Show this window outside instances."] = "Show this window outside instances."
L["Extra rules"] = "Extra rules"
L["Hide when solo"] = "Hide when solo"
L["Hide the window whenever you are not in a party or raid."] =
    "Hide the window whenever you are not in a party or raid."
L["Hide in vehicles"] = "Hide in vehicles"
L["Hide the window while you are controlling a vehicle."] =
    "Hide the window while you are controlling a vehicle."

-- ---------------------------------------------------------------------------
-- Columns page
-- ---------------------------------------------------------------------------

L["Column list"] = "Column list"
L["The columns this window shows, left to right. Columns can only be changed out of combat."] =
    "The columns this window shows, left to right. Columns can only be changed out of combat."
L["Add column"] = "Add column"
L["Add a statistic as a new column on the right."] =
    "Add a statistic as a new column on the right."
L["Remove column"] = "Remove column"
L["Remove this column from the window."] = "Remove this column from the window."
L["Move left"] = "Move left"
L["Move right"] = "Move right"
L["Column width"] = "Column width"
L["Width of this column in pixels."] = "Width of this column in pixels."
L["Show bar"] = "Show bar"
L["Draw a bar behind this column's number. Turn it off for a numbers-only column."] =
    "Draw a bar behind this column's number. Turn it off for a numbers-only column."
L["Statistic"] = "Statistic"
L["Which statistic this column shows."] = "Which statistic this column shows."
L["Columns cannot be changed during combat."] =
    "Columns cannot be changed during combat."
L["Every available statistic is already shown."] =
    "Every available statistic is already shown."
L["A window must keep at least one column."] =
    "A window must keep at least one column."

-- ---------------------------------------------------------------------------
-- Data page
-- ---------------------------------------------------------------------------

L["Data source"] = "Data source"
L["Session"] = "Session"
L["Read the current pull, or the accumulated totals for the whole run."] =
    "Read the current pull, or the accumulated totals for the whole run."
L["Current"] = "Current"
L["Overall"] = "Overall"
-- The header dropdown's title, and the label a window falls back to when it is
-- pinned to a segment whose name the client is not giving us.
L["Segment"] = "Segment"
L["Expired"] = "Expired"
L["Sort mode"] = "Sort mode"
L["How rows are ordered. Sorting by value is not possible while Blizzard's combat restriction is active, and falls back to the game's own order for the rest of the pull."] =
    "How rows are ordered. Sorting by value is not possible while Blizzard's combat restriction is active, and falls back to the game's own order for the rest of the pull."
L["By value"] = "By value"
-- Sorting by the Player column, which is what clicking that header does.
L["By name"] = "By name"
L["Game order"] = "Game order"
L["Group order"] = "Group order"
L["Sort column"] = "Sort column"
L["Class-colored row background"] = "Class-colored row background"
L["Tint each row with the player's class color. Rows with no class fall back to the alternating stripe."] =
    "Tint each row with the player's class color. Rows with no class fall back to the alternating stripe."
L["Row background opacity"] = "Row background opacity"
L["How strong the class tint is. Low values read as a tint rather than as a second bar."] =
    "How strong the class tint is. Low values read as a tint rather than as a second bar."
L["Bar background color mode"] = "Bar background color mode"
L["What colors the tint behind each bar. Class is the default and keeps working mid-fight, because a class is never hidden the way a number is."] =
    "What colors the tint behind each bar. Class is the default and keeps working mid-fight, because a class is never hidden the way a number is."
L["Sort ascending"] = "Sort ascending"
L["Merge pets into their owner"] = "Merge pets into their owner"
L["Add a pet's numbers to its owner's row instead of giving it its own. Blizzard's combat restriction forbids the addition while you are fighting, so a merged pet's numbers are missing until the pull ends."] =
    "Add a pet's numbers to its owner's row instead of giving it its own. Blizzard's combat restriction forbids the addition while you are fighting, so a merged pet's numbers are missing until the pull ends."
L["Put the smallest numbers at the top. Off means largest first, which is what a meter is usually read for."] =
    "Put the smallest numbers at the top. Off means largest first, which is what a meter is usually read for."
L["Which column's numbers decide the row order."] =
    "Which column's numbers decide the row order."
L["Refresh interval"] = "Refresh interval"
L["Seconds between refreshes. Lower is more responsive and costs more; the display updates at most this often no matter how fast the game reports numbers."] =
    "Seconds between refreshes. Lower is more responsive and costs more; the display updates at most this often no matter how fast the game reports numbers."
L["Reset meter data"] = "Reset meter data"
L["Clear every combat session the game is holding. This affects Blizzard's built-in meter too."] =
    "Clear every combat session the game is holding. This affects Blizzard's built-in meter too."
L["Clear every recorded combat session?"] = "Clear every recorded combat session?"

-- ---------------------------------------------------------------------------
-- General page
-- ---------------------------------------------------------------------------

L["Master controls"] = "Master controls"
L["Enable Mythic Meters"] = "Enable Mythic Meters"
L["Master switch for the addon. When off, no window is drawn and no data is read."] =
    "Master switch for the addon. When off, no window is drawn and no data is read."
L["Show minimap button"] = "Show minimap button"
L["Show the minimap button for opening these settings."] =
    "Show the minimap button for opening these settings."
L["Test mode"] = "Test mode"
L["Fill every window with placeholder data so you can lay out columns without being in combat."] =
    "Fill every window with placeholder data so you can lay out columns without being in combat."
L["Debug"] = "Debug"
L["Debug console"] = "Debug console"
L["Show or hide the on-screen debug console. Session only; it does not turn debug logging on."] =
    "Show or hide the on-screen debug console. Session only; it does not turn debug logging on."
L["Reset all settings"] = "Reset all settings"
L["Reset every setting on every page, for every window, back to the addon defaults. Profiles are left alone."] =
    "Reset every setting on every page, for every window, back to the addon defaults. Profiles are left alone."
L["Reset every window and every setting to the addon defaults? The active profile is the only one affected."] =
    "Reset every window and every setting to the addon defaults? The active profile is the only one affected."
L["Defaults"] = "Defaults"

-- Export defaults. These four are what the export modal opens showing; every
-- choice made in the modal writes straight back here, so the panel and the modal
-- are two views of one setting rather than two settings that drift apart.
L["Export"] = "Export"
L["Default metric"] = "Default metric"
-- Also the Metric menu's first entry. "" is a choice rather than an absent value:
-- it ranks by whichever column the exporting window is sorted by, which is what a
-- fresh profile ships with.
L["Match the window"] = "Match the window"
L["Which column 'Print to Chat' ranks by. Match the window follows whichever column the exporting window is sorted by; anything else pins every export to that one statistic."] =
    "Which column 'Print to Chat' ranks by. Match the window follows whichever column the exporting window is sorted by; anything else pins every export to that one statistic."
L["Default channel"] = "Default channel"
L["Where 'Print to Chat' sends its lines. Self only prints to your own chat frame and sends nothing to the group, which is why it is the default: a misclick cannot reach a raid."] =
    "Where 'Print to Chat' sends its lines. Self only prints to your own chat frame and sends nothing to the group, which is why it is the default: a misclick cannot reach a raid."
L["Whisper target"] = "Whisper target"
L["Who to whisper when the channel is Whisper. Cross-realm names need the realm, as Name-Realm."] =
    "Who to whisper when the channel is Whisper. Cross-realm names need the realm, as Name-Realm."
L["Chat lines"] = "Chat lines"
L["How many ranked lines 'Print to Chat' sends, after the header line. The meter never holds more than %d rows, so that is the ceiling."] =
    "How many ranked lines 'Print to Chat' sends, after the header line. The meter never holds more than %d rows, so that is the ceiling."

-- ---------------------------------------------------------------------------
-- The meter itself — availability and status
-- ---------------------------------------------------------------------------

L["Blizzard's damage meter is not available."] =
    "Blizzard's damage meter is not available."
L["Mythic Meters reads every number from the game's built-in damage meter. Enable it to see data here."] =
    "Mythic Meters reads every number from the game's built-in damage meter. Enable it to see data here."
L["Reason: %s"] = "Reason: %s"
L["Waiting for combat data..."] = "Waiting for combat data..."
-- Shown in gray on the header line for the whole of a pull. The grid is built a
-- different way while the game restricts combat data — rows come from the
-- engine's own ranking and are matched across columns by class and spec rather
-- than by GUID — and the player is owed the reason a cell can be blank.
-- Printed for the ONE header still refused mid-pull: the Player column. Ordering
-- by name compares a ConditionalSecret, which raises, and unlike a stat column
-- there is no engine ranking behind it to fall back on. Picking a stat column
-- and reversing the grid are both honoured during a pull and print nothing.
L["Sorting is not possible while the game restricts combat data."] =
    "Sorting is not possible while the game restricts combat data."
L["restricted"] = "restricted"
-- Appended to the above when two players share a class AND a specialization, so
-- their rows cannot be told apart. Those cells are left empty rather than filled
-- with a number that might be the other player's.
L["restricted \226\128\148 some rows cannot be told apart"] =
    "restricted \226\128\148 some rows cannot be told apart"
L["Test"] = "Test"
-- The red marker in a window's title bar while test mode is on. Upper case in
-- English on purpose; a translator may lower it.
L["TEST MODE"] = "TEST MODE"

-- ---------------------------------------------------------------------------
-- Export window
-- ---------------------------------------------------------------------------
--
-- The modal behind a window's export glyph, and the copy-paste window it opens
-- on top of itself. "Export" itself is declared with the settings rows above;
-- the modal reuses it as its title, because it is the same word for the same
-- feature.

-- The tooltip on the header glyph that opens the modal, left of the lock.
L["Export a segment to CSV or to chat"] = "Export a segment to CSV or to chat"

-- The three selector buttons render "Label: value", composed here rather than in
-- the module so a translation can move the colon or drop it entirely.
L["Metric: %s"] = "Metric: %s"
L["Channel: %s"] = "Channel: %s"
L["Lines: %s"] = "Lines: %s"

L["Export to CSV"] = "Export to CSV"
L["Print to Chat"] = "Print to Chat"
L["Metric"] = "Metric"
L["Channel"] = "Channel"
L["Lines"] = "Lines"
L["Whisper to"] = "Whisper to"

-- The copy window's title IS its instructions: there is no file I/O in WoW, so
-- the only way out of the addon is the player's own clipboard. Em dash written
-- as a decimal escape, as everywhere else in this file.
L["Ctrl+C, then Esc"] = "Ctrl+C, then Esc"

-- Channel names. Auto picks the widest channel the player is actually in
-- (instance, then raid, then party, then say); Self only sends nothing at all.
L["Auto"] = "Auto"
L["Say"] = "Say"
L["Party"] = "Party"
L["Raid"] = "Raid"
L["Instance"] = "Instance"
L["Guild"] = "Guild"
L["Whisper"] = "Whisper"
L["Self only"] = "Self only"

-- The refusal, shown in red in the modal and printed by the slash verb. Both
-- buttons are asked again on click, because the restriction can switch on while
-- the modal sits open: a CSV cell is a tostring, and tostring is not one of the
-- operations permitted on a value the game is hiding.
L["Export is not available while the game restricts combat data."] =
    "Export is not available while the game restricts combat data."

-- Status lines. Every one of these is a reason nothing happened, so each says
-- which of the several possible nothings it was.
L["There is nothing to export."] = "There is nothing to export."
L["Enter a name to whisper to."] = "Enter a name to whisper to."
L["No window named '%s'."] = "No window named '%s'."
L["Exported %d rows to chat."] = "Exported %d rows to chat."

-- ---------------------------------------------------------------------------
-- Slash commands (/mm, /mythicmeters)
-- ---------------------------------------------------------------------------

L["Slash Commands"] = "Slash Commands"
L["List available commands"] = "List available commands"
L["Print the addon version"] = "Print the addon version"
L["Open the settings panel"] = "Open the settings panel"
L["Toggle placeholder data so you can position a window"] =
    "Toggle placeholder data so you can position a window"
L["Lock every window in place"] = "Lock every window in place"
L["Unlock every window for dragging"] = "Unlock every window for dragging"
L["Toggle the window lock"] = "Toggle the window lock"
L["Print what the addon is doing right now"] = "Print what the addon is doing right now"
L["List every setting and its current value"] = "List every setting and its current value"
L["Print a setting's current value"] = "Print a setting's current value"
L["Set a setting"] = "Set a setting"
L["Reset one setting to its default"] = "Reset one setting to its default"
L["Reset every setting to its default"] = "Reset every setting to its default"
L["Clear every recorded combat session"] = "Clear every recorded combat session"
L["Measure performance"] = "Measure performance"
L["Debug subcommands"] = "Debug subcommands"
L["Available settings"] = "Available settings"
L["Setting not found: %s"] = "Setting not found: %s"
L["Invalid value for %s"] = "Invalid value for %s"
L["Allowed values: %s"] = "Allowed values: %s"
L["Cannot open settings during combat."] =
    "cannot open settings during combat — Blizzard's category switch is protected"
L["Windows are locked."] = "Windows are locked."
L["Windows are unlocked."] = "Windows are unlocked."
L["Test mode on."] = "Test mode on."
L["Test mode off."] = "Test mode off."
L["No window is selected."] = "No window is selected."

-- ---------------------------------------------------------------------------
-- Shared vocabulary
-- ---------------------------------------------------------------------------

L["Left"] = "Left"
L["Right"] = "Right"
L["Center"] = "Center"
L["Top"] = "Top"
L["Bottom"] = "Bottom"
L["Up"] = "Up"
L["Down"] = "Down"
L["Top left"] = "Top left"
L["Top right"] = "Top right"
L["Bottom left"] = "Bottom left"
L["Bottom right"] = "Bottom right"

L["None"] = "None"
L["Outline"] = "Outline"
L["Thick outline"] = "Thick outline"
L["Monochrome"] = "Monochrome"

L["Yes"] = "Yes"
L["No"] = "No"
L["OK"] = "OK"
L["Cancel"] = "Cancel"
L["Enabled"] = "Enabled"
L["Disabled"] = "Disabled"

L["Tank"] = "Tank"
L["Healer"] = "Healer"
L["Damage dealer"] = "Damage dealer"
L["Pet"] = "Pet"

-- The death drill-down (issue #1). "Death %d" numbers a player's deaths
-- chronologically, so the newest sits at the top of a list that counts down.
-- The dash is what a death whose recap the client no longer holds shows in
-- place of a time -- the row still exists, because the count above it says so.
L["Death %d"] = "Death %d"
L["No recap stored for this death"] = "No recap stored for this death"
L["(%s overkill)"] = "(%s overkill)"
L["%ds ago"] = "%ds ago"
L["%dm ago"] = "%dm ago"
L["Melee"] = "Melee"
L["Heal"] = "Heal"
L["Time of day"] = "Time of day"
L["How long ago"] = "How long ago"
L["Death timestamps"] = "Death timestamps"
L["How a death is labelled in the Deaths tooltip and the death list."] = "How a death is labelled in the Deaths tooltip and the death list."
