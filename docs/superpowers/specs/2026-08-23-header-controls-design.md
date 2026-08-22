# Header controls and their icons — design (issues #6, #7)

Status: drafted 2026-08-23, awaiting approval. Implements
[#6 "Move every window control into the header"](https://github.com/tusharsaxena/MythicMeters/issues/6)
and [#7 "Ship custom icons for the addon's own glyphs"](https://github.com/tusharsaxena/MythicMeters/issues/7).
They are one design because #7 only has a subject once #6 decides what the controls are.

## 1. What was measured first

Every fact below was checked against this machine or this repo before anything was designed, because
three of them would each have sunk a different part of the plan.

| Question | Answer |
|---|---|
| Can this machine produce a texture the WoW client loads? | **Yes.** `media/textures/Default.tga` is a 256×32 32-bit TGA the client already loads, and Pillow 10.2 (present) writes a compatible 32-bit TGA. |
| Can it rasterise SVG? | **No.** No ImageMagick, Inkscape, rsvg or cairosvg. Every mainstream icon set ships SVG only — which rules out Feather, Lucide, Tabler, Bootstrap, Phosphor and Font Awesome. |
| Is there a raster-shipping set with a usable licence? | **Yes — [Open Iconic](https://github.com/iconic/open-iconic), MIT.** It ships pre-rendered PNG at 8/16/24/32/48/64px, which sidesteps the missing rasteriser entirely. |
| Does it carry the glyphs we need? | **Yes**, all ten: `cog`, `lock-locked`, `lock-unlocked`, `x`, `reload`, `minus`, `plus`, `caret-top`, `caret-bottom`, `menu`, `list`, `data-transfer-download`. |
| What shape are they? | `cog-8x.png` is **64×64 RGBA**, transparent background, `(0,0,0,α)` antialiased. Verified by fetching and inspecting it. |
| Can PanelMaster's `artwork_cleaner.py` be used as-is? | **No.** Its output box is `SIZE = 1024` — it exists for full-panel backdrops, and would letterbox a 64px glyph onto a 1024 canvas. Its *machinery* is right; its target is not. |
| Does reset need a new confirmation dialog? | **No.** `MYTHICMETERS_RESET_METER_DATA` already exists (`settings/Data.lua:43`) and already carries the warning that matters. |

The naming trap, recorded because it cost a round: the PNGs are `<name>-8x.png`, not `<name>-32.png`.
The base is 8px, so `-8x` is the 64px one. And `raw.githubusercontent.com` times out from here —
`gh api repos/iconic/open-iconic/contents/png/<file>` and base64-decoding the `content` field works.

## 2. Decisions taken

| Question | Answer |
|---|---|
| Which controls live in the header? | **All seven** — close, minimise, lock, settings, segment, reset, export. |
| How are they placed? | **Right-to-left off the frame's right edge at `index × (size + gap)`.** A hidden control yields its index rather than leaving a gap. |
| Where does the code live? | A **new module**, `modules/HeaderControls.lua`. See §4. |
| What does minimise do? | **Collapses to the title bar.** Body hides, frame shrinks to header height, state persists. |
| Does a collapsed window still refresh? | **No**, and it needs no code: `OnUpdate` does not fire on a hidden frame. |
| Hover reveal? | **Yes**, per-window, default on, hooked to `dragBar` rather than per button. |
| Does reset confirm? | **Yes — through the dialog that already exists.** No new popup. |
| Icon art source? | **Open Iconic**, MIT, recoloured white so `SetVertexColor` tints at runtime. |
| One atlas or one file per glyph? | **One file per glyph.** Drops the texcoord map from the design entirely. |
| Does custom art replace the atlas ladder? | **No.** It becomes the ladder's first rung. See §10. |
| Do #6 and #7 land together? | **Two commits, in that order.** #6 ships complete without any art. |

## 3. Files

| File | Change |
|---|---|
| `modules/HeaderControls.lua` | **new** — the control registry, the layout, hover reveal, and the art ladder. |
| `modules/Window.lua` | Loses `ApplyHeaderButtons` and the four `*Button` fields; gains a call into the new module. `HeaderRightInset` stays but asks it for the width. |
| `tools/artwork/icon_cleaner.py` | **new** — adapted from PanelMaster's, retargeted at 64px glyphs. |
| `media/textures/icons/*.tga` | **new** — one per glyph, plus `LICENSE-open-iconic.txt`. |
| `defaults/Profile.lua` | Nine new `window.frame.*` keys. |
| `settings/Schema.lua` | Nine new rows on the Frame page. |
| `locales/enUS.lua` | New strings. |
| `MythicMeters.toc` | `modules\HeaderControls.lua`, after `modules\Window.lua`. |
| `tests/test_headercontrols.lua` | **new** suite, declared in `tests/run.lua`. |
| `tests/wow_mock.lua` | A texture-loadability seam. See §12. |
| `docs/` | ARCHITECTURE (module map, counts, documentation map), module-map, schema, settings-panel, smoke-tests. |

## 4. Why a new module, and where the seam is

`modules/Window.lua` is **2,220 lines**, the largest file in the addon. #6 adds a control registry,
an indexed layout, hover machinery and two new controls — 300-odd lines into the file least able to
take them.

The boundary is clean because the controls already only touch three things: the frame they anchor
to, the header's font and colour, and the window's own config. So:

```
WindowProto:Build()          -> HeaderControls:Attach(window)   -- create the buttons
WindowProto:ApplyHeader()    -> HeaderControls:Apply(window)    -- place, draw, show/hide
WindowProto:HeaderRightInset() -> HeaderControls:WidthUsed(window) + padding
```

`HeaderRightInset` **stays on Window** and keeps its name. It is the one seam the title and the
session line already depend on, and moving it would touch two things this change has no business
touching. It just stops counting buttons by hand and asks the module instead.

**Rule R3 is why this is safe at all.** A frame handed a secret value has secret geometry, and every
one of these buttons is anchored and measured. None of them ever holds a meter value — they are
config-driven from first principles — so the header is one of the few places in this addon where
geometry may be computed at all. `WidthUsed` is computed from the same constants the placement uses,
never read back off a frame. `docs/data-flow.md` §7 is the rule; this module is an instance of it,
not an exception to it.

## 5. The seven controls

Right-to-left off the frame's right edge:

```
index    0        1          2       3          4         5        6
      close  minimise   lock   settings   segment    reset   export
        ✕       ─         🔒       ⚙          ▤         ↺        ⤓
```

Each sits at `-(padding + index × (SIZE + GAP))`. **A hidden control yields its index**, so the ones
past it shift left by exactly one slot — the property #6 asks for, and the thing today's code cannot
do. Today's placement is hand-computed offsets off a `dx` whose own comment admits it is not an
accumulator, with the gear→lock seam at 2px against everyone else's 4px, "matched" rather than
derived. That goes.

**Segment becomes a real button.** Today it is a click on the session label (`Window.lua:433` →
`OpenSegmentMenu`). The label stays clickable — that is muscle memory and costs nothing to keep —
but a label that happens to respond to clicks is not a discoverable control, and the issue's whole
premise is that the controls should be in one place.

**Export stays.** It is the one modal control rather than a toggle, which is a reason to think about
it and not a reason to move it: it is reachable today from the header and making it harder to reach
would be a regression dressed as tidiness.

## 6. Minimise

`window.frame.minimised`, a bool, stored like every other window fact so it survives a `/reload`.

Collapsed: the row container, the column headers and the resize grip hide, and the frame's height
becomes the header's. Expanded: everything comes back at the configured height, which was never
changed — the stored `frame.height` is not touched by minimising, so restoring is exact.

**The refresh stops for free.** `OnUpdate` does not fire on a hidden frame, so hiding the body *is*
the stop. No flag, no branch in the throttle, nothing to keep in step. This is the addon's existing
cost model rather than a new one, which is why the issue's note that a minimised window "should not"
refresh needs no code to honour.

The button's own glyph is the state: `minus` when expanded, `plus` when collapsed — the same
one-asset-two-states pattern the padlock already uses.

## 7. Hover reveal

Controls sit at reduced alpha until the pointer is over the title strip, then fade in as one set.

**The hook goes on `dragBar`, not on the buttons.** `dragBar` is an invisible mouse-enabled frame
spanning the entire title strip — exactly the band the buttons occupy — and the buttons already sit
five frame levels above it so they win the click. A per-button `OnEnter`/`OnLeave` would fire a
leave every time the pointer crossed the 4px gap between two buttons, and the set would flicker.
One enter and one leave for the whole strip is both correct and cheaper.

`window.frame.hoverReveal`, default **true**. Off means the controls are always at full alpha,
which is today's behaviour and therefore the honest fallback.

## 8. Reset, and the dialog that already exists

The header's reset button calls `StaticPopup_Show("MYTHICMETERS_RESET_METER_DATA")`. That is the
whole of it.

The dialog is in `settings/Data.lua:43` and its comment explains why it must exist: the reset reaches
**outside this addon** — `C_DamageMeter.ResetAllCombatSessions` wipes the data Blizzard's own meter
is showing too, not just ours, and a player who meant "clear my window" and got "clear the game's
history" has no way back.

Reusing it is not merely economy. A second dialog would be a second place for that warning to drift
out of date, and the more dangerous the warning the worse that is. The action still routes through
`Provider.Reset()`, never at `Compat`'s shim — the provider is the only permitted caller of the
meter shims, and that is where the suspend state and the memo invalidation live.

Per #6's note, `window.frame.showReset` lets a player remove it entirely.

## 9. The art pipeline

`tools/artwork/icon_cleaner.py`, adapted from `../PanelMaster/tools/artwork/artwork_cleaner.py` —
same structure, same prose register, retargeted:

| PanelMaster's | Ours | Why |
|---|---|---|
| `SIZE = 1024` | `SIZE = 64` | A header glyph, not a panel backdrop. |
| Real-ESRGAN upscale | **dropped** | The source is already 64×64. Nothing to upscale, and the vendored binary is PanelMaster's. |
| `key_dark_background` | **dropped** | Open Iconic's PNGs already carry alpha. Keying an image that has alpha is how you damage it. |
| `solidify` | **kept** | Pushes opaque colour under transparent pixels so edges cannot smear. Cheap, and it is what keeps a downscale clean. |
| `normalize` | **kept** | Forces fully-transparent pixels to `(0,0,0,0)`. |
| — | **recolour** | New. Black → white, alpha preserved, so `SetVertexColor` can tint at runtime. |

**Why white.** The existing ASCII glyphs are tinted to the header's text colour at draw time
(`headerColor(header)`). A white source multiplies to any colour; a black one multiplies to black.
Shipping white is what lets the icons obey the same colour setting the rest of the header does,
rather than becoming a second thing the player has to style.

The tool fetches its sources through `gh api` and does not ship them. What ships is the TGAs and
`LICENSE-open-iconic.txt`, beside the precedent `media/fonts/` already sets with `OFL.txt`. The
tool's header records the upstream repo, the licence and the exact file names, so the provenance
question #7 raises is answered in the one place that can go stale — the thing that regenerates them.

**`DEPENDENCIES.md` grows a release/assets entry**: Python 3 with Pillow and numpy, needed only to
regenerate the icons, evidenced by this tool. That section currently says the repo has no such
tooling; after this it does.

## 10. The ladder keeps all three rungs

```
our TGA  ->  Blizzard atlas (Compat.FirstAtlas)  ->  ASCII glyph
```

`core/Compat.lua` records **two** previous failures at this exact spot, and both failed *silently*:
first textures drawn from paths that do not exist (`Interface\Buttons\UI-SortArrow-Up`) — a texture
that fails to load draws nothing and raises nothing, so the control was simply invisible — then
Unicode glyphs (▲, ⚙, 🔒) that are not in the game's default font and rendered as replacement boxes.

An addon-shipped texture can fail to load too, and it fails the *same silent way*. So custom art does
not retire the ladder; it becomes its first rung, and the two rungs behind it stay exactly as they
are. `Compat.FirstTexture(paths)` mirrors `FirstAtlas`: try `SetTexture`, ask whether anything took,
fall through on nil.

This is the single most important paragraph in the design. The temptation once art exists is to
delete the fallbacks as dead code; they are the opposite of dead, they are the record of what
already went wrong twice.

## 11. Schema

Nine rows on the Frame page, all `window.frame.*`:

`showMinimise` · `showLock` · `showSettings` · `showSegment` · `showReset` · `showExport` (bools,
default true) · `hoverReveal` (bool, default true) · `minimised` (bool, default false) ·
`controlSize` (number, default 18).

**`closeButton` keeps its existing path and name.** Renaming it to `showClose` for symmetry would
migrate every stored profile in exchange for consistency nobody can see. The asymmetry is worth a
comment, not a migration.

`controlSize` is the sizing lever #7 asks for — the art is 64px and drawn at whatever this says,
never at its native size. Same rule `icons.size` already follows for the row icons.

## 12. Testing

The mock cannot currently fail a texture load, so the ladder's new first rung has no way to be
driven. It gains a seam shaped like the existing `setAtlases`:

```lua
mocks.setTextureLoadable(path, false)   -- SetTexture takes, GetTexture answers nil
```

Cases that must exist, each red before its fix:

* Each rung is selected in turn: our TGA present; absent but the atlas there; neither.
* A hidden control yields its index — the ones past it move by exactly one slot, and the rest do not move.
* `HeaderRightInset` equals the width actually occupied, for every combination of shown and hidden.
* Nothing reads geometry off a frame: the existing `GetWidth`/`GetLeft`/`GetPoint` ban that
  `tests/test_row.lua:115` enforces for rows is extended to this module.
* Minimise hides the body, keeps the stored height, and restores exactly.
* Hover shows and hides the whole set from one `dragBar` enter/leave, not per button.
* Reset opens the existing dialog rather than resetting, and only resets on accept.
* A control turned off in the schema is not created-and-hidden but genuinely absent from the layout.

## 13. Order

Two commits, both in one session.

1. **#6** — the module, the seven controls, minimise, hover, reset, the schema, the docs. Ships
   complete against the existing atlas→ASCII ladder. No art, no new tool.
2. **#7** — `icon_cleaner.py`, the TGAs, the licence, `Compat.FirstTexture`, and the ladder's first
   rung.

The split is not ceremony. #6 is the larger and riskier change and it is worth reviewing without a
binary-asset diff in it; and if the art pipeline turns out worse than it looks, #6 is still done and
shippable rather than half-merged.

## 14. Not in scope

* **The bar texture (#4).** #7's note suggests answering the licence-and-registration question once
  for both. This design answers it for control glyphs — MIT source, licence file beside the art,
  provenance in the tool. #4 can adopt the same answer, but a bar texture is a different asset with
  a different shape and it is not being changed here.
* **Details!-style bottom bar.** #6 names it as the alternative considered; the header is where this
  addon's title, session label and duration already are, so that is where the controls go.
* **Retiring the clickable session label.** It stays alongside the segment button.
