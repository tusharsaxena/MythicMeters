# Ka0s Multi Meters

![WoW](https://img.shields.io/badge/WoW-Midnight_12.0.7-purple)
![Version](https://img.shields.io/badge/Version-0.1.0-blue)
![License](https://img.shields.io/badge/License-MIT-orange)
![Standard](https://img.shields.io/badge/Ka0s-WoW_Addon_Standard-yellow)
![Tests](https://img.shields.io/badge/Tests-1215%2F1215_passing-green)

Every other meter shows you one number at a time. Multi Meters shows the whole group in one grid —
who kicked, who dispelled, who stood in the fire, and who died — all in a single window, one row per
player and one column per statistic.

It reads everything from Blizzard's own damage meter. It does not watch the combat log, so it costs
you nothing that the game is not already spending.

```
Player      | Damage       | Healing     | Int | Disp | Avoid Dmg | Deaths
Rukhmar     | 12.4M  188K  | 0.9M   14K  |  3  |  1   |    412K   |   1
Thundertusk |  8.1M  123K  | 6.2M   94K  |  1  |  0   |    180K   |   0
Ashvane     |  6.7M  102K  | 0.2M    3K  |  4  |  2   |     22K   |   0
```

Every column is the same width, the player's name is in their class color, and the per-second figure
sits beside the total with no `/s` cluttering it — the column header already says what it is.

## What's new in 0.1.0

The first release.

- **One window, every statistic.** Damage, Healing, Interrupts, Dispels, Avoidable Damage and Deaths
  as columns of a single grid, each cell with its own bar and text. Damage and Healing show the total
  and the per-second figure together.
- **Current or overall.** Switch between the pull you are in and the whole run.
- **As many windows as you want.** Each one configured separately, with "copy settings from" so you
  do not have to set up the second one by hand.
- **Deep configuration** — frame, header, rows, bars, text, icons, tooltips, visibility, columns and
  data, all per window.
- **Hover for the detail.** A cell tells you which spells made up that number; a name tells you
  everything tracked for that player. A Damage cell can also list **which enemies that player hit**.
  Click a cell to drill into it, or a Deaths cell to open the death recap.
- **The tooltip is yours too.** Its own bar texture, spacing and border, its own font, nine anchor
  positions with an x/y nudge, and a spell cap you can set to zero for "show me all of them".
- **Take the numbers with you.** The export button in the title bar hands you the whole fight as CSV
  to paste into a spreadsheet, or prints a ranked top-N to chat — to yourself by default, so a
  misclick cannot reach your raid.
- **Stays out of the way.** Shows in dungeons, raids, arenas and battlegrounds; hidden in the open
  world and when you are alone, unless you say otherwise.

## Screenshots

None yet — this is the first release and the addon has not been photographed in a live run. They land
with the next version.

## Usage

Type `/mm` for the command list. `/multimeters` does the same thing if you prefer.

### Slash commands

| Command | What it does |
|---|---|
| `/mm` | Show the command list |
| `/mm config` | Open the settings panel |
| `/mm lock` | Lock or unlock every window for dragging |
| `/mm test` | Toggle placeholder rows, for positioning without being in a fight |
| `/mm toggle` | Show or hide a window by name, or all of them |
| `/mm window` | Window management — list, new, delete, copy |
| `/mm reset-positions` | Move every window back to the center of the screen |
| `/mm export` | Export a window's segment to CSV or to chat — `/mm export [window]` |
| `/mm list` | List every setting and its current value |
| `/mm get PATH` | Print one setting |
| `/mm set PATH VALUE` | Change one setting |
| `/mm reset PATH` | Reset one setting to its default |
| `/mm resetall` | Reset every setting to defaults |
| `/mm version` | Print the addon version |
| `/mm debug` | Open the debug console (`on` / `off` control logging, `diag` prints a diagnostic report, `recap` the death-recap probe) |
| `/mm perf` | Measure performance — run `/mm perf` for the workflow |

Settings that belong to a window are written as `window.something`, and they apply to whichever
window is selected in the settings panel. So `/mm set window.frame.width 420` widens the window you
are currently looking at, not all of them.

### Settings panel

`/mm config`, or the Options → AddOns list. Thirteen pages:

| Page | What you set there |
|---|---|
| Windows | Pick the window you are configuring; create, rename, delete, duplicate, copy settings from another |
| Frame | Size, scale, opacity, background, border, lock, title bar, close button |
| Header | Title, session name, duration, totals, font, alignment, background |
| Rows | Row height, spacing, how many, growth direction, self highlight, alternating backgrounds |
| Bars | Texture, color mode, background, border, opacity, fill direction |
| Text | Which text sits left and right, number format, max name length, font, size, outline, shadow, color |
| Icons | Class, spec and role icons — which to show, how big, where |
| Tooltip | What appears on hover, where it anchors and by how much, how many spells to list (0 for all), its own bar texture, spacing, border and font, and whether to list the enemies a player hit |
| Visibility | Dungeon, raid, arena, battleground, open world; hide when solo or in a vehicle |
| Columns | Add, remove and reorder columns; per-column width and whether it draws a bar |
| Data | Current or overall session, sort mode, sort column, refresh rate. Individual past fights are picked from the window header, not here |
| General | Minimap button, debug console, and what the export modal remembers — metric, channel, whisper target, chat lines |
| Profiles | Share a setup between characters |

## How it works

Blizzard's built-in damage meter already tracks all of this. Multi Meters asks it for the numbers
and arranges them as a grid — so the figures you see are the same ones Blizzard's own meter would
show, and there is no second copy of the combat log being parsed in the background.

That also explains the one behavior that might surprise you. In Midnight, the game hands addons
combat numbers in a sealed form — an addon can display them but cannot read them — and it seals the
identifier that says which row a number belongs to along with them. So **while you are actually
fighting, the grid is built a different way**: the rows are the game's own ranking of the sort column,
which keeps updating live, and the other columns are matched to those rows by class and
specialization. Two players who share both cannot be told apart, so their other cells stay blank
rather than showing a number that might be the other player's; the header says so in gray. Everything
fills back in the moment the fight ends.

## FAQ

**Do I need Details or Skada?**
No. This is not a plugin for another meter and does not read one. It only needs Blizzard's meter
turned on.

**Does it replace my damage meter?**
It can. Add the Damage and Healing columns and you have the usual numbers alongside the ones other
meters make you switch windows to see. Many people run it beside their existing meter instead.

**Why is a cell empty mid-fight, and why is the header gray?**
Midnight hides the identifier the game normally gives addons for each row, for the whole of a fight.
The rows themselves are the game's own ranking and keep updating; the other columns are matched to
them by class and specialization. Two players with the same class *and* spec cannot be told apart,
so those cells are left blank rather than showing a number that might be the other player's. The
header says so, and everything fills back in the moment the fight ends.

**Can I look back at an earlier fight?**
Yes. Click the segment control in the window's header — the three horizontal lines — and pick the
fight out of the list — it shows each
one's name and how long it ran, with Current and Overall at the bottom. The window stays on that fight
until you pick another, and remembers your choice across a reload. If the game discards the fight, the
window falls back to Current on its own.

**Can I have one window for damage and another for utility?**
Yes. Make a second window on the Windows page and give it a different column set. Every setting is
per window.

**Does it work in raids and PvP?**
Yes. Visibility is per window, so you can have a window that only appears in dungeons and another
that only appears in arenas.

## Troubleshooting

**The window says the damage meter is unavailable.**
Blizzard's meter is switched off or unavailable in your current situation. The window shows the
reason the game gave. Turn the built-in meter on and the rows appear.

**The window is empty and says it is waiting for combat data.**
Normal between pulls — nothing has happened yet in the session you are showing. Switch to Overall on
the Data page, or pick a past fight from the window's header, to see something other than the current
pull.

**The window only shows placeholder rows.**
The window is unlocked, and an unlocked window fills with placeholder data so you can position it
against a real-looking grid. Lock it — `/mm lock on`, or the Lock window box on the Frame page — and
the real numbers appear. Turning off Preview mode on its own is not enough while the window is
unlocked.

**I cannot open the settings while fighting.**
That is deliberate. Blizzard protects the settings machinery during combat, so the panel refuses to
open rather than risk breaking your action bars. It opens the moment you leave combat.

**A pet is missing from the meter.**
Pet damage folds into its owner's row. While you are in combat the game will not let addons add the
two together, so pet damage is left out until the fight ends rather than shown as a separate row.

**I cannot find the window.**
`/mm reset-positions` brings every window back to the middle of the screen.

**Something looks wrong and you want to report it.**
`/mm debug on`, reproduce it, then `/mm debug` to open the console and copy the log into your issue.

## Issues and feature requests

Please raise them on GitHub:
<https://github.com/tusharsaxena/MultiMeters/issues>

## Version History

| Version | Date | Highlights |
|---|---|---|
| 0.1.0 | 2026-08-09 | First release. Multi-column single-frame group meter sourced from Blizzard's damage meter: Damage, Healing, Interrupts, Dispels, Avoidable Damage and Deaths; current/overall sessions; multiple independently configured windows with copy-settings-from; tooltips, cell drill-down and death recap; per-window visibility. |

## Credits

The debug console uses [JetBrains Mono](https://www.jetbrains.com/lp/mono/), licensed under the SIL
Open Font License 1.1, and the header controls draw [Open Iconic](https://github.com/iconic/open-iconic)
(MIT). Both ship inside the bundled LibKa0s payload, with their license text beside them.
