# TODO — Ka0s Mythic Meters

Working notes for work that is known, wanted, and not scheduled. **Temporary.** These move to
GitHub issues on the addon's repo, at which point this file goes away — it exists so a decision made
in conversation is not lost between now and then.

Anything already tracked elsewhere does not belong here: audit and review bundles under
`docs/audits/` and `docs/reviews/` carry their own execution plans, and `docs/ARCHITECTURE.md` ->
`## Known limitations` is where a *shipped* constraint is recorded rather than a *pending* one.

---

## A death-recap window for the run

**Status:** decided, not started. Raised 2026-08-10.

The Deaths column already knows every death in the session individually. That was the discovery
behind the counting fix: `C_DamageMeter` returns **one source row per death**, not one per player —
the same `sourceGUID` appears once for each time they died, each row carrying its own
**`deathRecapID`**. `modules/Aggregator.lua` currently tallies those rows into a count and keeps only
the newest recap id per player.

Every other id is being thrown away, and each one is a complete "what killed them" breakdown the
client will hand back on request. That is a whole view sitting one API call from existing: **a
window listing every death in the run, newest first — who, when, and what did it** — with the recap
expanding inline the way Blizzard's own death recap does.

Notes for whoever picks this up:

- The recap ids are already in hand; the aggregator drops them. Keep the whole list per row rather
  than only the first, or re-read the Deaths column when the window is opened.
- `deathTimeSeconds` is `-1` on the Overall session (seen in a live dump) and presumably real on a
  Current one. Do not assume it is usable for ordering — the array's own order is newest-first, which
  is what the counting fix already relies on.
- This is a **different window type**, like the enemy-damage-taken note below: its rows are deaths,
  not group members, so it wants its own row identity and its own columns rather than a flag on the
  existing grid.
- The two window-type notes should probably land together, since both need the same thing first —
  `defaults/Profile.lua`'s `WINDOW_TEMPLATE` growing a type, and a migration behind it.

## Enemy damage taken belongs in its own window, not in a column

**Status:** decided, not started. Raised 2026-08-09.

`EnemyDamageTaken` is in the stat catalog (`core/Constants.lua`) with `defaultEnabled = false`, and
it is currently offered as one more column in the same grid as everything else. That is the wrong
shape for it, and the reason is that it does not describe the same subject as its neighbors.

Every other column answers a question about **a group member**: how much damage did Alpha do, how
many kicks did Beta land. `EnemyDamageTaken` answers a question about **an enemy**: how much damage
did the boss take. Putting the two in one grid means one row has to be both a player and a mob, and
the roster filter in `modules/Aggregator.lua` — which drops any source that is not a group member or
an attributable pet — is written for the former and has to be special-cased for the latter.

What it should be instead: **a distinct window type** whose rows are enemies, with its own row
identity (creature name and `sourceCreatureID` rather than player name, class and spec), its own
default columns, and its own drill-down meaning — clicking an enemy row should break down *who* damaged
it, which is a different pivot from the spell breakdown a player row gives.

Notes for whoever picks this up:

- `sourceCreatureID` is the join key for an enemy, not `sourceGUID`: an enemy GUID is per-spawn, so
  two pulls of the same mob are two GUIDs and one creature id. `Compat.GetCombatSessionSourceFromType`
  already takes a `sourceCreatureID` argument for exactly this, and `modules/Provider.lua` already
  forwards it.
- `Constants.SOURCE_DISPLAY_TYPE.Enemy` is how a source announces which side it is on, and the
  provider already copies `sourceDisplayType` onto every row it flattens. Nothing new has to be read.
- The window type would want its own entry in the window template rather than a flag on the existing
  one — `defaults/Profile.lua`'s `WINDOW_TEMPLATE` is one shape today, and a second shape is a
  schema change with a migration behind it (`core/Database.lua`).
- Until this lands, leave `EnemyDamageTaken` where it is. It is off by default, and a player who
  turns it on gets a column of numbers that are real, just oddly framed.

## The refresh rate should be a visible setting

**Status:** decided, not started. Raised 2026-08-11.

`data.throttle` already exists, ships at 0.25s, is clamped to `Constants.THROTTLE_MIN` / `MAX`
(0.05–2.0), and is the only clock in `modules/Window.lua`. What it is not is **discoverable**: it is
reachable through `/mm set window.data.throttle 0.1` and nowhere else. A player who thinks the meter
feels sluggish, or who wants it to cost less on a forty-player pull, has no way to find the knob that
decides both.

It wants a row on the window's General page — a slider in seconds, or an "updates per second"
framing, which is the way a player actually thinks about it.

Notes for whoever picks this up:

- It is one `settings/Schema.lua` row (`window.data.throttle`), which is the whole point of the
  schema: the panel widget, `/mm get|set|list`, the per-page reset and the defaults check all come
  from that one row. Do not add a parallel mutator.
- `WindowProto:RefreshUpvalues` already caches it into `self.throttle` on every `CONFIG_CHANGED`, so
  a change takes effect on the next tick with no extra wiring.
- The clamp belongs in the schema row's bounds as well as in the code, so the slider cannot express a
  value the code will silently correct.
- Worth pairing with the poll note in `WindowProto:ShouldPoll`: while a fight is on, a shown window
  refreshes on this clock whether or not a meter event arrived, so the setting governs real cost and
  the page copy should say so.

## Wire up the shipped bar texture

**Status:** file committed, not wired. Raised 2026-08-11.

`media/textures/Default.tga` ships as of this commit — 256x32 RGBA, RLE, which is the shape a WoW
statusbar texture wants. Nothing registers it and nothing reads it: `core/LSMPatch.lua` registers the
console font and deliberately stops there, and `defaults/Profile.lua` still ships
`bars.texture = "Blizzard Raid Bar"`, an LSM key that exists on every install.

Two things have to be answered before it is registered, and they are the same two the LSMPatch
comment has always named:

- **Its license and provenance are unrecorded.** `media/fonts/` carries `OFL.txt` beside the font and
  `DEPENDENCIES.md` names it as committed-not-generated; the texture has neither. Where this file
  came from needs establishing and writing down before it ships in a release, not after.
- **It needs a registry key.** LSM is a namespace every addon writes into, so the key wants the
  addon's own prefix rather than a bare `"Default"`, which is exactly the collision the comment
  warned about.

Then it is: one `LSM:Register(LSM.MediaType.STATUSBAR, key, path)` beside the font registration, a
constant for the path in `core/Constants.lua` next to `FONT_MONO`, and a decision about whether
`bars.texture`'s default moves to it — which is a schema default change, so
`NS.ValidateSchema()` and `defaults/Profile.lua` move together with a migration if it does.

