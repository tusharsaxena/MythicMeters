-- core/EnvSetup.lua
--
-- The LibKa0s-Env-1.0 seam: where this addon's own identity comes from
-- (library-stack-§7). Today that is the TOC manifest and nothing else — this
-- addon stamps no zone and no map id, so `NS.PlayerMapID` and `NS.Zone` are not
-- published here at all. A member nobody calls is a member nobody tests.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS REPLACED
-- ---------------------------------------------------------------------------
--
-- `Compat.GetAddOnMetadata`, plus the three inline ladders that had quietly
-- grown around it — core/PerfSetup.lua, settings/Slash.lua and
-- settings/OptionsSetup.lua each re-spelled the `NS.Compat and
-- NS.Compat.GetAddOnMetadata and ...` guard for themselves.
--
-- The reader had been written ELEVEN times across nine addons before the
-- library had it: six copies in a core/Compat.lua in four different spellings,
-- and five more inlined straight at the call site where no audit of the shim
-- files would ever have found them. Not one of the eleven behaved differently
-- from any other, and that sameness is the whole case — it is what makes this
-- the library's business rather than this addon's, and it is why core/Compat.lua
-- KEEPS its C_DamageMeter, spell and spec shims, which are genuinely this
-- addon's and behave like nobody else's.
--
-- ---------------------------------------------------------------------------
-- WHY THIS LOADS BEFORE core/Namespace.lua
-- ---------------------------------------------------------------------------
--
-- LOAD-BEARING POSITION, exactly like core/MediaSetup.lua's. core/Namespace.lua
-- resolves `NS.version` at FILE SCOPE, because LibKa0s-Perf-1.0 takes the
-- version as a plain string at :New time and cannot defer it. A seam that loaded
-- after it would not raise, would not log, and would leave NS.version as the
-- hardcoded FALLBACK_VERSION for the life of the session — an entirely plausible
-- number, stamped on every perf record and every `/mm version`.
-- tests/test_envsetup.lua pins it with a manifest that differs from the
-- constant, which is the only way to tell the two apart.
--
-- ---------------------------------------------------------------------------
-- WHY THE LIBRARY HAS TO BE TOLD OUR NAME
-- ---------------------------------------------------------------------------
--
-- Same reason core/MediaSetup.lua passes it: LibKa0s is VENDORED, so a copy
-- cannot know which addon folder it sits in. `addonName` is the FIRST VARARG
-- every TOC-loaded file gets — not `NS.PREFIX`, not the `## Title`, and not a
-- hand-typed literal. Here those three read "MultiMeters", "[MM]" and "Ka0s
-- Multi Meters", and only the first is the folder. A wrong name reads some other
-- addon's manifest, or none at all, and answers nil without raising a thing.
--
-- ---------------------------------------------------------------------------
-- WHAT A DEGRADED INSTALL GETS
-- ---------------------------------------------------------------------------
--
-- Exactly what this addon got before the library existed. Both helpers below
-- repeat the ladder the deleted shim ran, so an install missing LibKa0s still
-- reads its own TOC. That is why the fallbacks are written out rather than left
-- to answer nil: this is a seam, not a feature, and nil here is not an error a
-- player would ever see reported — it is a blank version in the options header
-- and "v?" on every capture record.
--
-- ---------------------------------------------------------------------------
-- WHAT THE SEAM MUST NOT CHANGE
-- ---------------------------------------------------------------------------
--
-- Any answer. The deleted shim already agreed with the library rung for rung, so
-- a difference in what comes back here is a defect in the adoption rather than
-- an improvement.

local addonName, NS = ...

local Env = LibStub and LibStub("LibKa0s-Env-1.0", true)

--- One field of this addon's TOC manifest, or nil.
---
--- NIL IS A REAL ANSWER, twice over: the client may expose no reader at all
--- (which is what an older client, and the headless harness with its manifest
--- cleared, look like), and a field the TOC does not carry answers nil on a
--- perfectly healthy client. Callers that need a value supply their own — see
--- NS.Version below, and core/Namespace.lua's FALLBACK_VERSION behind it.
---
--- The `_G.` prefixes are this repo's convention rather than the reference
--- seam's: architecture-§1 forbids naming a deprecated bare global implicitly,
--- and the explicit prefix is what makes a client-API read visible in review.
--- It is also what lets tests/wow_mock.lua drive the second rung.
---
--- @param field string  a TOC key: "Version", "Title", "Notes", "Author", …
--- @return string|nil
function NS.Meta(field)
    if Env then return Env.GetAddOnMetadata(addonName, field) end
    if _G.C_AddOns and _G.C_AddOns.GetAddOnMetadata then
        return _G.C_AddOns.GetAddOnMetadata(addonName, field)
    end
    if _G.GetAddOnMetadata then
        return _G.GetAddOnMetadata(addonName, field)
    end
    return nil
end

--- This addon's version string, preferring the TOC over the fallback constant.
--- Never nil.
---
--- The fallback stays visible HERE rather than inside the library because which
--- constant this addon falls back to is genuinely its own business — and because
--- a packaged addon whose TOC can be read should never report the constant
--- somebody forgot to edit (slash-commands-§3). `/mm version`, the options
--- header and every perf capture record all resolve through this one function,
--- so they cannot disagree.
---
--- `NS.version` is read at CALL time rather than captured as an upvalue:
--- core/Namespace.lua publishes it and loads immediately after this file.
---
--- @return string
function NS.Version()
    if Env then return Env.Version(addonName, NS.version) or "?" end
    return NS.Meta("Version") or NS.version or "?"
end
