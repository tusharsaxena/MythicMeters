-- tests/test_vendor_sync.lua — the vendored-payload gate, delegated.
--
-- The ~150 lines that used to live in each consumer's copy of this file were the
-- same gate in six repos with a one-line delta (`local T = _G.KICKCD_TEST` versus
-- `_G.AT_TEST`). Six copies is six chances to fix one problem six different ways,
-- and that is exactly what happened: every copy carried a bare `return` on the
-- missing-sibling path, which registers as PASS, so six green gates reported
-- "checked, fine" for a comparison that never ran. The gate now lives once, in
-- the payload it checks, at `tests/_kit/vendor_sync.lua`. See its header for what
-- it compares and why it compares against the TAG rather than the working tree.
--
-- WHAT IT PROVES HERE: that `libs/LibKa0s/` and `tests/_kit/` are byte-for-byte
-- what the LibKa0s repo published at the tag CLAUDE.md says this addon bundles
-- ("Bundles [LibKa0s](...) v1.8.3 (MIT)."). The provenance line is an INPUT, not
-- a constant — a line and a payload that disagree is precisely the drift this
-- exists to catch, so the claim has to be the thing under test. Bump the line and
-- the bytes in the same commit.
--
-- The gate is INSIDE the payload it checks, deliberately: a local patch to
-- `tests/_kit/` breaks this file's own byte-identity assertion, which is the
-- right outcome. The fix for a kit problem is upstream and re-vendor, never a
-- local edit.
--
-- ONE NORMALIZATION, AND ONLY ONE — carried in verbatim, because it is the one
-- thing a reader must not have to infer. `git show` hands back the stored blob,
-- which is LF, while the working tree is CRLF because `.gitattributes` pins
-- `* text=auto eol=crlf`. CR is stripped from the working-tree side so the file
-- is compared to the blob it round-trips to. Nothing else is normalized — a real
-- fork in content still fails. A vendored copy differing from the blob ONLY in
-- line endings PASSES; one differing by a single content byte FAILS. That is the
-- intended split: line endings are decided per checkout by `.gitattributes`, so
-- treating them as a content fork would redden this gate for a fact about the
-- checkout rather than about the bytes.
--
-- A missing sibling LibKa0s checkout is the one case that may go quiet, and it
-- reports a SKIP carrying its reason rather than a PASS.
--
-- The case names below are the consumer's, not the kit's, which is why
-- `register` is a factory rather than auto-registration: adopting the shared gate
-- must not move docs/test-cases.md's counts.

local T = _G.MULTIMETERS_TEST
local ROOT = T.root or "."
local VendorSync = dofile(ROOT .. "/tests/_kit/vendor_sync.lua")

VendorSync.register(T, { root = ROOT })
