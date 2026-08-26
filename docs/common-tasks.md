# Common tasks

Recipes for the changes made most often in this addon: the files each one touches, in order, and the
thing that will bite you.

The architecture behind them is in [ARCHITECTURE.md](ARCHITECTURE.md),
[schema.md](schema.md), [settings-panel.md](settings-panel.md) and [data-flow.md](data-flow.md).
This file is the "how do I actually do it" page.

---

## House rules every recipe obeys

These are the rules that make the recipes short. Break one and the recipe stops working.

**R1 — `core/Secrets.lua` is the only file that inspects a value.** Everywhere else a number that
came out of `C_DamageMeter` is an **opaque handle**: you may store it, put it in a table *value*,
pass it to a Lua function, hand it to a widget setter (`StatusBar:SetValue`, `SetMinMaxValues`,
`FontString:SetText`) or to `modules/Format.lua`, and concatenate it with `..`. You may **not**
compare it, do arithmetic on it, boolean-test it, use it as a table **key**, apply `#` to it, index
it, or pass it to `table.concat`. Every one of those raises immediately while the Combat addon
restriction is active. The only test permitted on a non-boolean secret is `== nil`.

**`modules/Provider.lua` is the only caller of `C_DamageMeter`** (through `core/Compat.lua`'s
shims). Nothing else names the namespace.

**R2 — row order is never computed from values while comparison is illegal.** `modules/Aggregator.lua`
checks comparability in a separate pass *before* `table.sort` is entered, never inside the
comparator: a comparator that discovers an illegal comparison halfway through has already raised,
and there is no way to unwind a partially sorted array.

**R3 — layout is computed from config, never read back off a frame.** A frame handed a secret via
`SetValue` is marked `HasSecretValues`, which makes its own position and size data secret and
propagates that to everything anchored to it. There is not one `GetWidth` / `GetHeight` /
`GetLeft` / `GetPoint` call anywhere in `modules/Row.lua`. The single exception in the addon is
`modules/Window.lua`'s `inst.anchor`: an empty, invisible, childless frame the visible window is
anchored *to*, upstream of everything, which can therefore never receive a value.

**Nothing divides a meter number.** Abbreviating is arithmetic. `C_StringUtil.CreateNumericRuleFormatter()`
does it natively and accepts secrets; `modules/Format.lua` owns the instances and is the only file
that asks for one.

**Every user-facing string goes through `NS.L`.** Never a bare literal in panel or chat code. `L`
carries the metatable fallback the standard mandates, so a missing key returns the key itself — you
can ship `L["Some New String"]` before `locales/enUS.lua` is updated, and you should still update it.

**One sender per bus message.** The owner of each is named in `core/Constants.lua`'s `MSG` block. A
second sender is a bug, not a convenience. Receivers that are not AceAddon modules take a private
target from `NS.NewBusTarget()` — CallbackHandler keys callbacks by `(message, target)`, so two
receivers on the same object silently clobber each other (anti-pattern #32).

**Modules subscribe; they never register game events.** `core/MultiMeters.lua` is the addon's single
game-event listener and fans everything onto the bus.

**Perf brackets are Shape A, inline, with a load-time upvalue.** `local Perf = NS.Perf` at file
scope, then `local t0 = Perf.on and debugprofilestop()` … `if t0 then Perf.Note(key, debugprofilestop() - t0) end`.
Never an `NS.Perf` lookup on a hot path (`performance-§2`).

**Debug lines defer their formatting.** `NS.Debug("Tag", "fmt %d", n)` — arguments only, never a
string built at the call site, and one line per pass rather than one per row (`debug-logging-§3/§4`).

**A pass that repeats on a timer logs through `NS.DebugSteady(key, "Tag", "fmt %d", n)` instead.**
One line per *change*, plus a heartbeat every 10s carrying `(xN)` for the passes it stood for — the
refresh loop runs four times a second and the console buffer holds 1500 lines, so `NS.Debug` on that
path spends the whole buffer on one steady state. `key` separates emitters that share a call site
(pass the window id); the call site itself is identified by the format string, so two `NS.Debug`
calls under one tag do not need distinct keys. Still gated at the call site exactly as `NS.Debug` is
— the arguments are evaluated to get there. Ratified as a deviation from `debug-logging-§8`; see
[ARCHITECTURE.md](ARCHITECTURE.md) → Documented deviations.

---

## Add a new statistic column

The stat catalog in `core/Constants.lua` is the single source of truth for which
`Enum.DamageMeterType` values this addon is willing to show. Nothing else in the addon enumerates
them.

**1. Add one row to `Constants.STATS`.** Position in the array is the order the column editor offers
it *and* the order it lands in a new window if it ships enabled.

```lua
{
    key = "Absorbs", enumValue = Constants.STAT_TYPE.Absorbs,
    label = "Absorbs", shortLabel = "ABS",
    isRate = false, defaultWidth = 78, defaultEnabled = false,
},
```

- `key` is the enum name **on purpose**, so a reader holding Blizzard's documentation can map a row
  to an API value without a lookup table. It is what a window's column config stores, what `/mm`
  accepts, and what a test asserts on.
- `enumValue` comes from `Constants.STAT_TYPE`, which resolves each enum defensively with the
  documented numeric literal as a fallback. Add the entry there too if the stat is new: a bare
  `Enum.DamageMeterType.Whatever` is an index into nil on a client that lacks the namespace and
  raises at **file load**, taking the whole addon down before it can render the notice it already
  knows how to show.
- `label` is the **English** string, and `core/Constants.lua` deliberately does not call `L` itself —
  `locales/` may load either side of it, and a value frozen at load would miss a locale that
  registers later. Localize at the use site: `L[stat.label]`.
- `isRate` is true **only** where `amountPerSecond` is meaningful — `DamageDone` and `HealingDone`.
  Counting stats do carry the field, but "0.42 interrupts per second" is noise, and this flag is
  what makes the right-hand text slot stay empty for them.
- `defaultWidth` must fit the abbreviated form the formatter produces at that magnitude, and it must
  fall inside the column editor's **24–240** range or `NS.SetByPath` will refuse to store it.

**2. Add `label` and `shortLabel` to `locales/enUS.lua`.**

**3. Nothing else.** Derived automatically:

| Surface | How |
|---|---|
| `Constants.STAT_BY_KEY` | built from the array |
| `Constants.DEFAULT_STAT_KEYS` | derived from `defaultEnabled`; drives `NS.DefaultWindow`'s columns |
| The Columns page's Add picker | `unusedStatList` walks `Const.STATS` |
| The Data page's Sort column dropdown | `STATCOL_VALUES` is derived in `settings/Schema.lua` |
| The name tooltip's all-statistics list | `modules/Tooltip.lua` walks `Const.STATS` |
| The aggregator's per-stat read | `columnKeys(window)` filters the window's columns through `STAT_BY_KEY` |

**4. Optionally add a color** to `Constants.STAT_COLORS` in `core/Constants.lua`. The same three
numbers are worn in two places: a bar under `bars.colorMode == "stat"`, and — always, whatever that
setting says — the new statistic's whole line in the name tooltip's all-statistics list, taken down
by `Constants.STAT_DIM` when the hovered window has no column for it. Absent, the bar falls back to
the shared neutral and the tooltip line to plain white or gray — correct rather than broken, but it
means two columns read alike.

**Gotchas.**
- `defaultEnabled = true` changes what a **new** window ships with. It does **not** appear in an
  existing profile: `Database.EnsureWindowShape` deliberately leaves the `columns` array alone,
  because key-filling it would re-add columns the user removed. Existing users add it from the
  Columns page, or `/mm resetall`.
- Removing a stat from the catalog is safe: `WindowProto:BuildLayout` and
  `Aggregator.columnKeys` both drop a column whose key `STAT_BY_KEY` does not answer, and the
  Columns page still **lists** it (labelled with its raw key) so the player can remove it.
- Never add `Dps` or `Hps`. `amountPerSecond` ships on the same source row as `totalAmount`, so one
  `DamageDone` read fills both halves of the column; querying them would double the session reads
  for a number the addon already holds.

---

## Export a segment

Two destinations, one modal, and a hard refusal in combat.

**In the client.** Click the **export glyph** in any window's title bar — the fourth button, one slot
left of the padlock — or type `/mm export` (`/mm export <window>` for a window that is not the one
the settings picker is on). The modal that opens offers **Metric**, **Channel** and **Lines**, plus a
whisper-name box that appears only while the channel is Whisper, and two actions:

| Action | Where it goes |
|---|---|
| **Export to CSV** | A copy-paste window: monospace, whole text pre-selected, Ctrl+C then Esc. There is no file I/O in WoW, so this is the only way a file can leave the client. |
| **Print to Chat** | One metric, ranked and capped, as a header line plus N ranked lines, sent on the chosen channel. |

What comes out is **the whole segment and every stat in the catalog**, not the invoking window's
column set, sort or row cap: what is on screen is a display choice, and "export this" means the data.
The one thing that *is* inherited is the **segment** — exporting from a window pinned to a stored
fight exports that fight, not the live pull. The four choices are remembered addon-wide at `export.*`
in the profile, and the General settings page edits the same four rows.

**In code**, the entry points are all on `NS.Export` (`modules/Export.lua`), a plain table on `NS`
like `NS.Slash` rather than an AceAddon module:

```lua
local result = NS.Export.Build(win, "HealingDone")        -- an Aggregator.Build result
local csv    = NS.Export.CSV(result, NS.Export.SessionLabel(win))
local lines  = NS.Export.ChatLines(result, "HealingDone", 5, label)
NS.Export.Send(lines, "PARTY")
NS.Export:Open(win)                                       -- the modal
```

Every one of them takes **either a Window instance or a bare config table** — the glyph has only the
instance, the slash verb has only the config, and each unwraps with `(win and win.config) or win`.

**Four things about that file are load-bearing.**

- **It has no data path of its own.** `Export.SessionConfig` builds a *synthetic* window config —
  every catalog stat enabled, the invoking window's segment, `rows.maxRows = Const.MAX_ROWS` — and
  hands it to `Aggregator.Build`. Nothing here touches `Provider`, `core/Compat.lua`'s meter shims or
  `C_DamageMeter`; an export is a **consumer** of the grid's data, never a second producer, and R1
  allows exactly one producer.
- **The whole thing refuses while the Combat restriction is active.** A CSV cell is
  `tostring(value)`, and `tostring` is not on R1's permitted list — it neither raises nor launders,
  it answers a *secret string*, which then poisons the `find`, the `gsub` and the `..` that RFC-4180
  quoting is made of. So `Export.Available()` is asked at the top of the serializers, when the modal
  opens, **and again inside each click handler**, because the restriction can activate while the
  modal sits open. Underneath that, every field passes `Secrets.CanAccess` on its way in and yields
  `""` when it fails: a race can produce a blank cell, never an error.
- **Nothing in it sorts.** Ranking is a comparison, and the aggregator has already done it under its
  own guards. To rank by a different stat, pass that stat as `Export.Build`'s `sortColumn` — which is
  exactly what Print to Chat does, so "top 5 healing" is the top five healers rather than the top
  five damage dealers with their healing beside them.
- **Everything above the `Export modal` divider is pure and unit-tested** (`tests/test_export.lua`);
  everything below it is UI, built lazily on the first `Open` and guarded on `CreateFrame` so the file
  loads in a harness with no client at all. Keep new serialization above the line.

**Gotchas.**
- **The 40-row ceiling** is `Constants.MAX_ROWS`, inherited from `Aggregator.ApplyRowLimit`. A raid of
  more than 40 exports 40 rows. Documented rather than worked around.
- **`SELF` is the default channel and must stay so.** The trigger is a glyph in a title bar, and a
  misclick that reaches a raid is a wipe-night apology where a misclick that prints to your own frame
  is three lines nobody else sees.
- The copy window is a **deliberate local copy** of the ones in `LibKa0s/DebugLog.lua` and
  LootHistory. It is the third in the collection and a harvest candidate for `lib.MakeCopyWindow`, not
  something to unify from inside this addon.
- The header glyph is **not** wired to the restriction, on purpose: an icon that greys and ungreys
  four times a second through a pull is worse than a modal that opens and says why.

---

## Add a CSV column

Most of the time the answer is **do nothing**. The stat half of the column set is derived, so a new
row in `Constants.STATS` brings its own CSV columns with it — see
[Add a new statistic column](#add-a-new-statistic-column). `Export.Columns()` emits, per catalog stat
and in catalog order:

| Kind | Header | When |
|---|---|---|
| `total` | `damage_done` | every stat |
| `rate` | `damage_done_ps` | `isRate` stats only — "0.42 interrupts per second" is noise, and an always-blank column is worse than an absent one |
| `pct` | `damage_done_pct` | every stat, blank when the share cannot be computed |

Header names come from `Export.HeaderName`, which lowercases and underscores the stat key
(`AvoidableDamageTaken` → `avoidable_damage_taken`). It is a **rule rather than a table** on purpose:
a hand-written list of eight names goes stale the first time the catalog grows a ninth stat, and it
goes stale silently. It is also emphatically **not** `L[stat.label]` — a CSV is a data interchange,
and a German client must produce a file a colleague on an English client can open with the same
formulas.

**A genuinely new column** — one that is not a stat — is two edits.

**1. An identity column** (something the row already knows: guild, realm, item level) goes in
`LEAD_HEADERS` and in the matching `cells` literal inside `Export.CSV`. The two are positional and
must stay in step; add to the same index in both.

```lua
local LEAD_HEADERS = { "session", "duration", "name", "class", "spec", "role", "realm" }
```

```lua
local cells = {
    session_, duration,
    Export.CsvField(row.name),
    Export.CsvField(row.classFilename),
    Export.CsvField(row.specIconID),
    Export.CsvField(row.role),
    Export.CsvField(row.realm),
}
```

**2. A fourth *kind* of stat column** (a per-stat maximum, say) is a case in `Export.Columns`'s `add`
loop and a matching branch in `Export.CSV`'s per-column `if`. Both are three lines, and both must be
touched — a kind emitted by one and unknown to the other produces a header with no data under it.

**Everything goes through `Export.CsvField` and nothing goes around it.** That function is the
laundering point of the whole file: upstream of it a value may be an opaque meter handle, downstream
of it everything is a plain Lua string, which is the *only* reason the row assembly below is allowed
to use `table.concat` at all. Skip it for one field and that row's `concat` raises the moment
somebody exports during a pull.

**Gotchas.**
- **Raw values, never formatted ones.** `4821993`, not `Format.Number`'s `4.8M`. A spreadsheet wants
  the integer; the abbreviated form belongs to `Export.ChatLines`.
- **A percentage is a bare two-decimal number, not `Format.Percent`'s string** — the `%` sign makes
  the column unaverageable. `percentField` does that formatting, and `cell.percent` is already scaled
  0..100 and is a plain number or nil, because the aggregator computes it only when the division
  behind it was legal.
- **A nil field is `""`, never `"nil"`.** `CsvField` answers the empty string for nil and for an
  inaccessible value alike, and an absent cell is the common case rather than an error — most players
  have no row in Dispels, Interrupts or Deaths.
- **Do not strip the realm.** `modules/Row.lua` gates its realm strip on the GUID for display; a CSV
  is interchange and `Name-Realm` is the more useful answer. It needs no quoting either — `CsvField`
  quotes only on `[,"\r\n]`, so `Crenna Earth-Daughter` travels unquoted and intact.
- **Add the case to `tests/test_export.lua`.** The pure half of that file is reachable from the
  headless harness, so a new column is one assertion on the header line and one on a row, and the
  suite already asserts the `_ps`/`_pct` invariants that a careless `add` breaks.

---

## Add a new setting

One row, one default, one locale entry. A schema row automatically gains `/mm get`, `/mm set`,
`/mm list`, `/mm reset`, its page widget, the per-page **Defaults** button and the `/mm resetall`
sweep — so **do not** write a parallel mutator for a field that already has a row.

**1. `settings/Schema.lua`** — add the row in the block for its page, positioned where you want it
to render (the flow engine pairs consecutive rows two to a line, so neighbors here are neighbors on
screen).

```lua
{
    path = "window.rows.compactMode", type = "bool", default = false,
    page = "rows", group = L["Row layout"],
    label = L["Compact mode"], desc = L["Draw rows without spacing."],
},
```

Use a `window.`-prefixed path for anything per-window, which is nearly everything; an absolute path
only for the genuinely addon-wide. See
[schema.md](schema.md#the-window-relative-path-model).

**2. `defaults/Profile.lua`** — add the same literal at the matching path. For a `window.` row that
is inside `WINDOW_TEMPLATE`, at `WINDOW_TEMPLATE.rows.compactMode`; for an absolute row it is inside
`NS.defaults.profile`. **The two values must be identical** — they are restated in two files on
purpose, and `NS.ValidateSchema` compares them.

**3. `locales/enUS.lua`** — the `label` and `desc` strings.

**4. Where the value is read**, wire the behavior. Not in the row: the row's job is storage plus a
`CONFIG_CHANGED` announcement, and every window already re-applies itself on that message. Add an
`onChange` **only** if the effect is something the message genuinely cannot express — today that is
the visibility ladder needing a re-run, and LibDBIcon needing to be told to look again.

**5. `lua tests/run.lua`.** It asserts `NS.ValidateSchema() == 0`, which is what catches a typo'd
path (writes land on a key nothing reads — the panel renders, the widget shows the row's default,
the write succeeds, and nothing anywhere says so) and a default that disagrees with the tree.

**Gotchas.**
- A number row that carries `values` is inferred as an **enum** by both library majors and
  constrained rather than clamped. That is what `window.data.sessionType` needs; it is not what a
  slider needs.
- `type` is the widget dispatch key for the panel **and** the value parser for the CLI. There is
  deliberately no separate `widget` field.
- A color default is a table, so it must be deep-copied on the way out. `NS.ApplyDefault` does that;
  do not hand `row.default` to anything directly.
- Adding a leaf is **additive** and needs no `schemaVersion` bump. Renaming or restructuring one
  does — and needs a migrator beside it.

---

## Add a settings page

Only worth doing for a genuinely new group of settings; nine of the thirteen existing pages are one
`RenderSchema` call.

**1. `settings/<Name>.lua`.** Copy `settings/Rows.lua` — it is the minimal shape.

```lua
local addonName, NS = ...
local L = NS.L
local PAGE = "<pagekey>"

local function Build(mainCategory)
    if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then return nil end
    local H = NS.Helpers
    if not (H and H.CreatePanel) then return nil end

    local ctx = H.CreatePanel("MultiMeters<Name>Panel", L["<Name>"], {
        panelKey = PAGE, defaultsButton = true,
    })
    ctx.panel.defaultsOnClick = function() H.RestoreDefaults(PAGE, ctx) end

    H.SetRenderer(ctx, function(c)
        c.unit = NS.State and NS.State.activeWindowId or nil
        H.ClearScroll(c)
        H.RenderSchema(c, PAGE)
    end)

    return Settings.RegisterCanvasLayoutSubcategory(mainCategory, ctx.panel, L["<Name>"])
end

if NS.RegisterOptionsPage then
    NS.RegisterOptionsPage(PAGE, L["<Name>"], Build)
end
```

**2. `MultiMeters.toc`** — add the file in the `# Settings` block, **after** `settings/Schema.lua`
and `settings/OptionsSetup.lua`, in the position you want the page to appear. Registration order is
page order.

**3. `settings/Schema.lua`** — the rows, with `page = "<pagekey>"`.

**4. `defaults/Profile.lua`** — a new config group if the page owns one. If it is per-window, add it
to `WINDOW_TEMPLATE` **and** to `COPY_GROUPS` in `modules/WindowManager.lua` and `COPY_GROUPS` in
`settings/Windows.lua`. A group in the template but not in those lists simply never copies, silently.

**5. `locales/enUS.lua`** — the page name, group headings, labels and descriptions.

**Gotchas.**
- **Build lazily.** `SetRenderer` is not optional: a builder that runs at registration lays its
  children out against a zero-width body and loses the AceGUI skinning race (`options-ui-§5`).
- **`H.ClearScroll(c)` first.** `RenderSchema` appends; it does not clear. Without it, a re-render
  after the picker moved stacks a second copy of the page under the first.
- **`c.unit`** carries the active window id as the library's row filter. Set it on any page with
  `window.` rows.
- If you draw anything past the end of a `RenderSchema` call — a button, a bespoke control — end
  with `H.Relayout(c)`. `RenderRows` runs its own layout pass and `InlineButtonPair` appends after
  it, so the appended child has no measured height until you ask.
- A page with **no** schema rows must pass `defaultsButton = false`. There is nothing for the button
  to restore, and a button that appears to do nothing is worse than no button.
- If the page has destructive controls, add its key to `vetoedFromResetAll` in
  `settings/OptionsSetup.lua` — and remember that predicate is enforced twice, in the descriptor and
  in the degradation stub's own reset loop.

---

## Add a slash verb

**1. `settings/Slash.lua`** — append to `NS.COMMANDS`, after the ten reserved verbs
(`slash-commands-§2` fixes their order).

```lua
{ "status", "Print what each window is doing", function(rest) doStatus(rest) end },
```

The entries are **ordered positional triples** `{ name, description, handler }`, which is the shape
`LibKa0s-Slash-1.0` reads (`entry[1]`, `entry[2]`, `entry[3]`). A table of named fields
(`{ name =, desc =, fn = }`) **does not fail loudly**: it loads, dispatches nothing, and answers
every verb the user types with "unknown command". There is no error to read and nothing in the log.

**2. Forward-declare the handler** as a local above the table and assign it below. The verb table
sits above the dispatcher it dispatches through, and the host verbs reach
`modules/WindowManager.lua`, which loads long after this file. A handler that closes over an upvalue
resolves at call time; one that closes over a value resolves to nil forever.

**3. The handler takes `(rest)` only** — everything after the verb, case and internal spacing
preserved. Lowercase a sub-verb (it is an identifier); leave the remainder exactly as typed if it is
a window name (that is user data, and folding it resolves something the user did not name).

**4. Name every sub-verb in the entry's own `desc`.** The generated help index, the settings landing
page and the README's command table all read that string and nothing else — a sub-verb missing there
is a sub-verb nobody can discover (`slash-commands-§4`).

**Gotchas.**
- `perf` is a **reserved** verb across the collection and is already registered here. It is
  registered **by the addon**, never by the harness: `NS.COMMANDS` is the one place every command in
  this addon is declared, and a verb registered behind its back is a verb the help index, the landing
  page and the README all miss.
- Registration goes through AceConsole (`Sl:Register`), never a raw `SLASH_*` global. AceConsole owns
  the deregistration a `/reload` needs and the collision check two addons claiming one token need.
- `/multimeters` is a real alias reaching the same dispatcher, not a second command.
- If the verb acts on windows, route it through `modules/WindowManager.lua` rather than
  reimplementing anything. The panel calls the same methods, and duplicating the rule gives the CLI
  and the panel two ideas of what "delete a window" means.

---

## Add a bus message

**1. `core/Constants.lua`** — add the constant to `Constants.MSG`, with the sender named in the
comment beside it and the payload shape after it.

```lua
SESSION_PICKED = "Ka0s_MultiMeters_SESSION_PICKED",   -- { windowId, sessionID }
```

Every name is declared here so the catalog in `ARCHITECTURE.md` has one place to be checked against,
and so a typo in a subscriber is a nil index at load rather than a callback that silently never
fires.

**2. Send it from exactly one place**, and say so in that file's header. The existing owners:

| Message | Sole sender |
|---|---|
| `METER_UPDATED` `METER_SESSION` `METER_RESET` `ROSTER_CHANGED` `ZONE_CHANGED` `ENTERING_WORLD` `RESTRICTION_CHANGED` | `core/MultiMeters.lua` (the addon's only game-event listener) |
| `PROFILE_CHANGED` | `core/Database.lua` |
| `CONFIG_CHANGED` | `settings/Schema.lua` (`NS.SetByPath`'s tail) |
| `WINDOWS_CHANGED` | `modules/WindowManager.lua` |
| `PREVIEW_CHANGED` | `core/State.lua` |
| `DRILLDOWN_CHANGED` | `modules/DrillDown.lua` |

`METER_RESET` is the documented near-exception: `Provider.Reset()` announces it *and*
`DAMAGE_METER_RESET` fans onto the same message, so it can dispatch twice. Every handler on it is
idempotent, and a duplicate wipe is a far smaller problem than a window that keeps drawing rows for
sessions that no longer exist.

**3. Subscribe.** An AceAddon module (`Provider`, `Roster`, `Aggregator`, `WindowManager`,
`Visibility`, `Tooltip`, `DrillDown`) is its own AceEvent target and registers in `OnEnable`.
Anything else — a window instance, `modules/Format.lua` — takes a private target from
`NS.NewBusTarget()`.

**4. Name it from the catalog and only the catalog.** Never `Const.MSG.X or "Ka0s_MultiMeters_X"`.
A hand-spelled fallback defeats the exact protection the catalog exists to give: a misspelled or
removed key must fail loudly at load, not quietly ship a name no subscriber is listening on.

**Gotchas.**
- Distinguish *shape* from *value*. `WINDOWS_CHANGED` means the registry changed shape and forces a
  rebuild; `CONFIG_CHANGED` means a setting moved inside a window that already exists and forces a
  refresh. Collapsing them would make every settings edit rebuild every window.
- Carry `windowId` in the payload for anything window-scoped, and have subscribers ignore a
  mismatched id. A twenty-window profile must not re-apply nineteen windows because one was edited.
- A message handler should do the **minimum**: invalidate what the message invalidated, then set the
  dirty flag. The throttle decides when work happens.

---

## Add a perf bucket

**1. `core/PerfSetup.lua`** — add the key to the `buckets` array, in report order, declaring nesting
with `within`.

```lua
buckets = {
    { key = "meterEvent" },
    { key = "refresh" },
    { key = "providerRead", within = "refresh" },
    { key = "aggregate",    within = "refresh" },
    { key = "render",       within = "refresh" },
    { key = "renderRow",    within = "render"  },
    { key = "tooltip" },
},
```

These keys are the contract the module layer brackets against. **A bracket naming a key that is not
here still records — it just never appears in the report**, which is the quiet failure this list
exists to prevent.

**2. Bracket the call site**, Shape A, inline, with the load-time upvalue:

```lua
local Perf = NS.Perf              -- file scope, once

local t0 = Perf.on and debugprofilestop()
-- ... the work ...
if t0 then Perf.Note("myBucket", debugprofilestop() - t0) end
```

**Gotchas.**
- **Never double-count.** A parent must never be summed with its children, and one span must never
  land in two buckets. `modules/Roster.lua` carries no bracket at all for exactly this reason: its
  rebuild is lazy, so it happens *inside* the aggregator's `aggregate` bracket and is already
  counted there.
- **Declare the nesting rather than leaving it as prose.** A reader comparing two captures months
  apart cannot be expected to know which totals overlap.
- **Do not bracket three-line functions.** `modules/Format.lua` deliberately has no bracket: the cost
  a reader wants attributed is "what did rendering this row cost", which `renderRow` already gives,
  and a second bracket inside it would cost more than the work it measured.
- **`core/Secrets.lua` has no bracket either**, and must not grow one: `core/PerfSetup.lua` loads
  after it in the core block, so a load-time upvalue there would capture nil forever, and an `NS`
  lookup per value is exactly the per-call cost the perf contract forbids.
- If the new bucket covers work that must stop under `suspend`, wire that in the descriptor's
  `suspend` / `resume` hooks — and remember `resume` restores from **current** state, so a window
  created while suspended comes back correctly.

---

## Add a test suite

**1. Write `tests/test_<name>.lua`.**

```lua
local T = _G.MULTIMETERS_TEST
local NS = T.NS

T.test("aggregator drops an unattributable pet", function()
    ...
    T.assertEqual(#rows, 4)
end)
```

The exposed surface is `T.test`, `T.skip`, `T.fail`, `T.assertEqual`, `T.assertTrue`,
`T.assertFalse`, `T.assertNil`, `T.assertNear`, `T.assertError`, `T.assertSurfaceParity`,
`T.assertSuiteInventory`, plus `T.NS` / `T.mocks` (the shared instance), `T.load(opts)` (a fresh
isolated instance), `T.root`, `T.suites`, `T.libFiles`, `T.loadedAddonFiles` and `T.Loader`.

**2. Declare the basename in `SUITES` in `tests/run.lua`**, in the block it belongs to. `Kit.run`
asserts the list against `tests/` **in both directions** before it loads a single case: a declared
suite with no file is a hard error, and a `tests/test_*.lua` that is not declared is one too.
Neither is a skip.

A suite still being written is declared as `{ name = "test_foo", pending = "why" }` and **must** lose
that field the moment its file lands.

**3. `lua tests/run.lua`.**

**Gotchas.**
- **The collect-then-run split.** `T.test()` only *records*; nothing executes until `Kit.run`. That
  is why `lua tests/run.lua --list` cannot disagree with the run it enumerates.
- **Use `T.load{...}` when you need a different world.** The shared instance is fully loaded, DB
  built, options panel created, modules **not** enabled. Options:
  `initDB = false`, `options = false`, `enable = true` (runs every module's `OnEnable` and flushes
  timers), `libFiles = {}` (loads the addon with **LibKa0s absent** — the degraded scenario
  `testing-§8` requires to be exercised by a real load rather than by hand-stubbing the member under
  test), and `mutate = function(mocks) ... end`.
- **`mutate` runs before any source loads**, and that matters: the enum fallbacks in
  `core/Constants.lua` and `core/Secrets.lua` are resolved at **load**, so `Enum` has to be wrong
  before the file runs, not after.
- **Testing the secret path means testing the guards, not the values.** The mock can return
  secret-like opaque values; the point is to prove that `modules/Provider.lua` never inspects one,
  that `Aggregator` refuses the value sort, and that `Secrets.SafeIterate` never applies `#`.
- Do not edit anything under `tests/_kit/` — it is vendored, and `tests/test_vendor_sync.lua` is a
  byte-identity gate that will fail.

---

## Re-vendor LibKa0s

Two things move, and **they must move in the same commit.**

**1. Copy the payload.** From a clean checkout of the LibKa0s repo **at the tag you are adopting**:

```sh
LIBKA0S=/path/to/LibKa0s          # checked out at the tag, e.g. v1.8.4
MM=/path/to/MultiMeters

rm -rf "$MM/libs/LibKa0s" "$MM/tests/_kit"
cp -r "$LIBKA0S/LibKa0s" "$MM/libs/LibKa0s"
cp -r "$LIBKA0S/testkit"  "$MM/tests/_kit"
```

**2. Move the provenance line in `CLAUDE.md`** — the last line of the file:

```
Bundles [LibKa0s](https://github.com/tusharsaxena/LibKa0s) v1.8.3 (MIT).
```

`tests/test_vendor_sync.lua` **reads that line and uses it as the input to the check.** It diffs
`libs/LibKa0s/` and `tests/_kit/` against what the LibKa0s repo published **at that tag**, not
against its working tree — LibKa0s can be several commits and a pile of uncommitted work ahead of
anything it has tagged, and diffing against the tree would redden this suite for upstream progress
this addon has not adopted. The natural "fix" for that red is to vendor uncommitted work, shipping
bytes that exist at no ref anybody can check out.

So a provenance line and a payload that disagree is precisely the drift the gate exists to catch,
which is why bumping one without the other fails the suite. **Bump the line and the bytes in the same
commit.**

**3. Check the load list.** `tests/run.lua` derives `LIB_FILES` from `libs/LibKa0s/LibKa0s.xml` and
then asserts the eight expected majors are present by name:

```
Core.lua  DebugLog.lua  Slash.lua  Options.lua
OptionsWidgets.lua  OptionsScroll.lua  Perf.lua  PerfPanel.lua
```

That assertion is not decoration. A short load list does not raise — it leaves the dependent major
unregistered, the host's setup file falls back to its degradation stub, and the suite happily
measures the stub: green, and testing nothing (`testing-§9`). This addon has **five** seams that
degrade that way — `core/CoreSetup.lua`, `core/PerfSetup.lua`, `core/DebugLogSetup.lua`,
`settings/Slash.lua`, `settings/OptionsSetup.lua`.

**4. Line endings.** The repo pins CRLF via `.gitattributes`, and `tests/_kit/run-automated-tests.sh`
**must stay LF** — a `#!/usr/bin/env bash` line followed by CRLF makes the kernel look for an
interpreter literally named `bash\r`. The carve-out is `*.sh text eol=lf`. Note that
`vendor_sync.lua` normalizes line endings and **only** line endings: a vendored copy differing from
the blob only in CR passes, and one differing by a single content byte fails.

**5. `lua tests/run.lua`**, then update `DEPENDENCIES.md` if the toolchain moved.

---

## Run the green gate

Two commands, both must be clean, before every commit:

```sh
lua tests/run.lua        # exits non-zero on any failure
luacheck .               # must be 0 warnings / 0 errors
```

If `lua` is not 5.1 on your box, use `lua5.1` explicitly. **Lua 5.1 exactly** is a requirement, not
a preference: `tests/_kit/loader.lua` sandboxes each source file with `setfenv`, which was removed in
5.2.

Useful variants:

```sh
lua tests/run.lua --list     # emit docs/test-cases.md's body; exit 0
lua tests/perf.lua           # the offline scenario runner — NOT part of the gate
```

`tests/perf.lua` is deliberately outside the gate. It asserts the **deterministic** half — how many
`C_DamageMeter` reads a refresh makes, how many refreshes a burst of events produces, how many
unit-API walks a roster change costs, how many bytes a dormant perf bracket allocates. It asserts no
wall-clock threshold, ever: those vary with the machine and the CPU governor, and a gate that flakes
is a gate everyone learns to bypass. Its timings are for orientation only — read them as ratios
between scenarios inside one run, never as absolute numbers across machines.

The one scenario worth knowing by name is `refresh20x7`, which asserts that **one refresh makes
exactly one `Provider.GetColumn` call per enabled column**. It used to make two —
`modules/Window.lua` re-entered the provider for each column's group total so the cells could divide
by it, while `modules/Aggregator.lua` already held both operands and already divided. That was a
doubling of the addon's entire session-read cost on its hot path, and it was invisible because
nothing counted.

---

## Produce an automated-test bundle

```sh
tests/_kit/run-automated-tests.sh                             # all four suites, writes a bundle
tests/_kit/run-automated-tests.sh --suite lint --suite tests  # a subset
tests/_kit/run-automated-tests.sh --no-bundle                 # print only, write nothing
```

Four suites — **lint**, **tests**, **perf**, **complexity** — recorded as one frozen bundle under
`docs/automated-tests/<YYYYMMDD-HHMMSS>/`, then rolled into `docs/automated-tests/RESULTS.md`. Write
the `ANALYSIS.md` alongside it; the `/wow-addon:automated-tests` command drives the whole flow and
fetches the living playbook.

Three things about the runner are load-bearing:

- **`lint` and `tests` gate; `perf` and `complexity` do not.** They are measured, recorded and
  diffed, never used to fail the run. A wall-clock or complexity threshold that fails a run teaches
  everyone to reach for `--no-verify`, after which the gate protects nothing and the habit remains
  (`performance-§9`/`§10`).
- **A missing tool is a skip, and is recorded as one** — so a green run that actually measured
  nothing cannot read as a green run that measured everything. Install `lizard` via **pipx**, not
  pip: Ubuntu 24.04 marks its Python `EXTERNALLY-MANAGED` (PEP 668).
- **The bundle is written to whatever `.gitattributes` declares**, read per path at the end of the
  run. Everything the runner writes goes down a plain shell redirect, which bypasses git's filters
  entirely.

A release bundle is gated harder: `/wow-addon:bump-version` runs all four first and refuses to bump
anything unless lint, tests, perf and complexity all pass with **zero functions above CCN 15**.
