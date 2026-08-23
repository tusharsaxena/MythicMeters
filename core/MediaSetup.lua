-- core/MediaSetup.lua
--
-- The LibKa0s-Media-1.0 seam: where this addon's art and its monospace face come from.
--
-- ---------------------------------------------------------------------------
-- THEY USED TO BE OURS, AND THAT WAS THE PROBLEM
-- ---------------------------------------------------------------------------
--
-- This addon built 49 icons from Open Iconic and shipped them under its own
-- `media/textures/icons/`, beside its own copy of JetBrains Mono, produced by a
-- tool that lived in `tools/artwork/` here. All of it now ships inside LibKa0s
-- (v1.9.0, `LibKa0s-Media-1.0`) and arrives with the library payload, because
-- the second Ka0s addon to want a gear icon would otherwise have copied both —
-- and two copies of a texture is two licenses to track, two provenance stories,
-- and a collection whose addons stop looking like one author's work the first
-- time one copy is regenerated and the other is not.
--
-- The tool went with the art: `tools/artwork/icon_cleaner.py` is in the LibKa0s
-- repo now. It is the provenance record — which upstream glyph each name draws,
-- and every transformation applied — and separating it from the art would leave
-- a folder of binaries nobody can regenerate, relicense or resize.
--
-- ---------------------------------------------------------------------------
-- WHY THE LIBRARY HAS TO BE TOLD OUR NAME
-- ---------------------------------------------------------------------------
--
-- A texture path is absolute from `Interface\AddOns\`, and LibKa0s is VENDORED:
-- every consumer has its own copy at its own path, and a copy cannot know which
-- addon folder it was copied into. So the library asks, and this file is where
-- the answer lives — `addonName`, the first vararg every TOC-loaded file gets.
--
-- ---------------------------------------------------------------------------
-- WHY THIS LOADS BEFORE core/Constants.lua
-- ---------------------------------------------------------------------------
--
-- `Constants.FONT_MONO` is resolved from `NS.MediaFont` at load, so the seam has
-- to be published first. That is also why this file is one of the few in core/
-- whose TOC position is load-bearing rather than conventional.
--
-- ---------------------------------------------------------------------------
-- WHAT A DEGRADED INSTALL GETS
-- ---------------------------------------------------------------------------
--
-- No LibKa0s means no art and no face — they are inside the payload that is
-- missing. `NS.Icon` answers nil, which modules/HeaderControls.lua already
-- treats as "walk down the art ladder" (its Blizzard-atlas and ASCII rungs exist
-- for exactly this), and `NS.MediaFont` answers nil, which core/Constants.lua
-- turns into the client's own STANDARD_TEXT_FONT. Neither is an error: chrome
-- degrades, and the numbers stay readable in a proportional face.
--
-- ---------------------------------------------------------------------------
-- CONSUMER NOTES — who asks for which name
-- ---------------------------------------------------------------------------
--
-- Not a full catalog (the library's own ICONS table is that); just the names
-- whose consumer would not be obvious from the call site alone.
--
--   "chevron-down" — modules/Export.lua's three modal selectors (Metric,
--   Channel, Lines), each passed as `opts.chevron` to LibKa0s-Widgets-1.0's
--   Dropdown constructor. NS.Icon degrading to nil there is exactly the
--   Dropdown's own fallback: the widget draws Blizzard's own arrow instead.

local addonName, NS = ...

local Media = LibStub and LibStub("LibKa0s-Media-1.0", true)

--- The texture path for one shipped icon, or nil.
---
--- NIL IS A REAL ANSWER, twice over: the library may be absent, and the name may
--- not be one the library ships. Both are the same thing to a caller — draw
--- something else — and both are far better than the alternative the library
--- exists to remove, which is a plausible path to a texture that does not load,
--- draws nothing, and raises nothing.
---
--- @param name string  an entry of the library's `ICONS` catalog, e.g. "settings"
--- @return string|nil
function NS.Icon(name)
    if not Media then return nil end
    return Media.Icon(addonName, name)
end

--- The path of one shipped font face, or nil when the library is absent.
---
--- @param name string  a key of the library's `FONTS`, e.g. "JetBrains Mono"
--- @return string|nil
function NS.MediaFont(name)
    if not Media then return nil end
    return Media.Font(addonName, name)
end

-- REGISTERED AT FILE LOAD, not at PLAYER_LOGIN, and the reason is one this addon
-- has already had to fix once: LibSharedMedia is vendored under libs/ and has
-- therefore already run by the time the TOC reaches core/, while
-- defaults/Profile.lua names the font at load time too. Deferring would open a
-- window in which a shipped default named a face LSM had never heard of.
--
-- What registration buys over the bare path is the settings panel: a registered
-- face appears in the font dropdown beside every other font the player has, and
-- a profile then stores the NAME — portable across installs — rather than a path
-- naming one addon's folder. The library's own call is idempotent and points
-- every consumer at one set of bytes under one key, which is what makes two Ka0s
-- addons registering "JetBrains Mono" agree rather than collide.
if Media then Media.RegisterLSM(addonName) end
