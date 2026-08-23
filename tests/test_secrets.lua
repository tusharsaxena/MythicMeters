-- tests/test_secrets.lua — core/Secrets.lua, the only file in this addon that is
-- allowed to LOOK at a value.
--
-- This is the most important suite in the repo, because the failure it guards
-- against is invisible out of combat and fatal in it. While the Combat addon
-- restriction is active every number the meter hands back is a secret, and
-- tainted code that compares one, does arithmetic on one, keys a table with one
-- or applies `#` to a table of them raises an immediate Lua error — on the
-- refresh ticker, mid-pull, where nobody can read it. Out of combat all of those
-- operations succeed, so no amount of ordinary testing finds them.
--
-- FOUR THINGS ARE PINNED HERE, in rising order of how badly they fail:
--
--   1. the restriction readers track the client's state, and degrade to the
--      SAFE direction (assume restricted) when the API is not there;
--   2. CanCompare / CanCompare2 refuse a secret and permit a plain value —
--      this is the whole of design rule R2, and a CanCompare that answered
--      `true` for everything would leave the aggregator sorting secrets;
--   3. SafeIterate and SafeCount obtain a length WITHOUT the length operator,
--      guard on canaccesstable BEFORE touching the table, stop at the first nil,
--      and never inspect the value they hand to the callback;
--   4. every one of the above is still correct when the whole secrets system is
--      ABSENT — an older client, and the world this harness runs in by default.
--
-- HOW THE SIMULATOR MAKES (3) FALSIFIABLE. `#` cannot be trapped on a table in
-- Lua 5.1 — the operator consults a metamethod only for userdata — so "it does
-- not use `#`" cannot be proven by making `#` raise. It is proven instead with a
-- LAZY array: a table whose entries come from an `__index` metamethod, so `#`
-- answers 0 while indexing answers three entries. An implementation reaching for
-- the length operator visits nothing and the case goes red.

local T = _G.MULTIMETERS_TEST
local NS, mocks = T.NS, T.mocks
local test, assertEqual, assertTrue, assertFalse, assertNil =
    T.test, T.assertEqual, T.assertTrue, T.assertFalse, T.assertNil

local Secrets = NS.Secrets

--- An array whose entries exist only through `__index`, so `#lazy` is 0 and
--- `lazy[i]` answers for i = 1..n. Any implementation that measures with the
--- length operator sees an empty array.
local function lazyArray(n, make)
    return setmetatable({}, {
        __index = function(_, i)
            if type(i) == "number" and i >= 1 and i <= n then
                return make and make(i) or { index = i }
            end
            return nil
        end,
    })
end

--- A fresh instance with the named globals removed from the simulated client
--- BEFORE any source loads — core/Secrets.lua resolves its enum constants at
--- load, so the client has to be wrong first.
local function loadWithout(...)
    local names = { ... }
    return T.load{ mutate = function(m)
        for _, name in ipairs(names) do m[name] = nil end
    end }
end

-- ── R1: nothing else inspects a value ───────────────────────────────────────

test("Secrets: core/Secrets.lua is the only file that names a detection API", function()
    -- Design rule R1. The four detection globals are the entire vocabulary for
    -- "look at this value", and confining them to one file is what makes the
    -- rule reviewable at all — a second call site is a second place that has to
    -- get the guard-for-absence right.
    -- red under: moving any issecretvalue / canaccesstable read into a module.
    local APIS = { "issecretvalue", "canaccessvalue", "issecrettable", "canaccesstable" }
    for _, rel in ipairs(T.loadedAddonFiles) do
        local fh = io.open((T.root or ".") .. "/" .. rel, "r")
        local src = fh and fh:read("*a") or ""
        if fh then fh:close() end
        if rel:lower() ~= "core/secrets.lua" then
            for _, api in ipairs(APIS) do
                -- `_G.<api>(` is the call form; the name also appears in prose
                -- comments elsewhere, which is fine and deliberately not matched.
                assertNil(src:match("_G%." .. api .. "%s*%("),
                    rel .. " calls " .. api .. " — only core/Secrets.lua may")
            end
        end
    end
end)

-- ── the restriction readers ─────────────────────────────────────────────────

test("Secrets: IsRestricted tracks the client's restriction state", function()
    local inst = T.load{}
    local S = inst.NS.Secrets
    inst.mocks.setRestricted(false)
    assertFalse(S.IsRestricted(), "out of combat the restriction is inactive")
    inst.mocks.setRestricted(true)
    assertTrue(S.IsRestricted(), "inside the restriction IsRestricted must say so")
    inst.mocks.setRestricted(false)
    assertFalse(S.IsRestricted(), "the flag must fall again, not latch")
end)

test("Secrets: IsRestricted answers a plain boolean, never the API's raw return", function()
    -- Callers store this into NS.State.restricted and branch on it per render
    -- pass; a truthy non-boolean would be a value the mirror could not compare.
    local inst = T.load{}
    inst.mocks.setRestricted(true)
    assertEqual(type(inst.NS.Secrets.IsRestricted()), "boolean")
    inst.mocks.setRestricted(false)
    assertEqual(type(inst.NS.Secrets.IsRestricted()), "boolean")
end)

test("Secrets: with no C_RestrictedActions, IsRestricted falls back to combat lockdown", function()
    -- The honest answer on such a client is "we cannot know", and the closest
    -- approximation is combat lockdown — which is when the restriction WOULD be
    -- active if the client had one. Erring toward "restricted" costs a frozen
    -- sort for the duration of a pull; erring the other way is a Lua error.
    -- red under: returning `false` from the tail of IsRestricted.
    local inst = loadWithout("C_RestrictedActions")
    local S = inst.NS.Secrets
    inst.mocks.setRestricted(false)
    assertFalse(S.IsRestricted(), "out of combat with no API, nothing is restricted")
    inst.mocks.setRestricted(true)   -- also flips the InCombatLockdown source
    assertTrue(S.IsRestricted(), "in combat with no API, assume restricted")
end)

test("Secrets: with neither API nor lockdown, IsRestricted is false rather than an error", function()
    local inst = loadWithout("C_RestrictedActions", "InCombatLockdown")
    assertFalse(inst.NS.Secrets.IsRestricted())
end)

test("Secrets: a raising IsAddOnRestrictionActive degrades instead of propagating", function()
    -- The call is wrapped in pcall for a PTR shape we have actually seen: the
    -- namespace present, the function present, and the call raising on an
    -- argument it does not recognize. A raise here would take the render pass
    -- with it.
    local inst = T.load{}
    inst.mocks.C_RestrictedActions = {
        IsAddOnRestrictionActive = function() error("simulated PTR raise") end,
    }
    inst.mocks.__restricted = true
    assertTrue(inst.NS.Secrets.IsRestricted(),
        "a raising API must fall through to the lockdown approximation, not propagate")
end)

test("Secrets: GetRestrictionState forwards the raw state, including Activating", function()
    -- Collapsing this to a boolean would throw away the only edge at which a
    -- correct value-sort can still be taken (design §5): Activating fires BEFORE
    -- enforcement begins and access is still permitted during that dispatch.
    local inst = T.load{}
    local S, m = inst.NS.Secrets, inst.mocks
    m.setRestricted(false)
    assertEqual(S.GetRestrictionState(), S.STATE.Inactive)
    m.setRestricted(true)
    assertEqual(S.GetRestrictionState(), S.STATE.Active)
    m.setRestrictionState(S.STATE.Activating)
    assertEqual(S.GetRestrictionState(), S.STATE.Activating)
end)

test("Secrets: GetRestrictionState answers nil — not a state — when the API is absent", function()
    -- nil and Inactive are different facts. A caller that treated "cannot ask"
    -- as "not restricted" would take the value-sort branch on a client whose
    -- restriction state it has no way to see.
    local inst = loadWithout("C_RestrictedActions")
    assertNil(inst.NS.Secrets.GetRestrictionState())
end)

test("Secrets: STATE republishes the client's enum, and falls back to the documented literals",
function()
    assertEqual(Secrets.STATE.Inactive, mocks.Enum.AddOnRestrictionState.Inactive)
    assertEqual(Secrets.STATE.Activating, mocks.Enum.AddOnRestrictionState.Activating)
    assertEqual(Secrets.STATE.Active, mocks.Enum.AddOnRestrictionState.Active)

    -- Removed at LOAD, because STATE is resolved at load and a later removal
    -- would prove nothing.
    local bare = T.load{ mutate = function(m) m.Enum = nil end }
    local S = bare.NS.Secrets
    assertEqual(S.STATE.Inactive, 0)
    assertEqual(S.STATE.Activating, 1)
    assertEqual(S.STATE.Active, 2)
end)

-- ── per-value inspection ────────────────────────────────────────────────────

test("Secrets: IsSecret is true for a secret and false for every plain value", function()
    assertTrue(Secrets.IsSecret(mocks.secret(1234)))
    for _, plain in ipairs({ 0, 1234, "text", true, {} }) do
        assertFalse(Secrets.IsSecret(plain), "a plain value must not read as secret")
    end
    assertFalse(Secrets.IsSecret(nil), "nil is not secret")
end)

test("Secrets: IsSecret answers a boolean, not the client's raw return", function()
    assertEqual(type(Secrets.IsSecret(mocks.secret(1))), "boolean")
    assertEqual(type(Secrets.IsSecret(1)), "boolean")
end)

test("Secrets: CanAccess permits plain values and refuses an inaccessible secret", function()
    local inst = T.load{}
    local S, m = inst.NS.Secrets, inst.mocks
    m.setSecretsAccessible(false)
    assertTrue(S.CanAccess(0), "zero is a plain value and must stay comparable")
    assertTrue(S.CanAccess(false), "false is a plain value")
    assertTrue(S.CanAccess(nil), "nil is not a secret")
    assertFalse(S.CanAccess(m.secret(99)), "an inaccessible secret must be refused")
end)

test("Secrets: CanAccess permits a secret during the Activating edge", function()
    -- The one window in which a value is SECRET and still READABLE. This is the
    -- distinction between issecretvalue and canaccessvalue, and the reason
    -- CanCompare is built on the second one.
    -- red under: implementing CanAccess as `not IsSecret(v)`.
    local inst = T.load{}
    local S, m = inst.NS.Secrets, inst.mocks
    local v = m.secret(7)
    m.setSecretsAccessible(true)
    assertTrue(S.IsSecret(v), "the value is still secret during Activating")
    assertTrue(S.CanAccess(v), "but it is still readable, which is the whole point of the edge")
    m.setSecretsAccessible(false)
    assertFalse(S.CanAccess(v), "once enforcement starts the same value is refused")
end)

test("Secrets: CanCompare refuses a secret and permits a plain value", function()
    -- Design rule R2 in one line: row order is never computed from values while
    -- comparison is illegal.
    local inst = T.load{}
    local S, m = inst.NS.Secrets, inst.mocks
    m.setSecretsAccessible(false)
    assertTrue(S.CanCompare(5))
    assertTrue(S.CanCompare(0), "0 must not be mistaken for absent")
    assertFalse(S.CanCompare(m.secret(5)))
end)

test("Secrets: CanCompare2 refuses when EITHER operand is secret", function()
    -- A comparison is one operation and one secret operand is enough to raise.
    -- The asymmetric cases are the ones a hand-written call site gets wrong, and
    -- they only appear when two players' numbers straddle the restriction edge.
    -- red under: `return CanAccess(a)` — the plain-then-secret case goes green
    -- and the addon sorts a secret.
    local inst = T.load{}
    local S, m = inst.NS.Secrets, inst.mocks
    m.setSecretsAccessible(false)
    local s = m.secret(3)
    assertTrue(S.CanCompare2(1, 2), "two plain values are comparable")
    assertFalse(S.CanCompare2(s, 2), "secret first")
    assertFalse(S.CanCompare2(1, s), "secret second")
    assertFalse(S.CanCompare2(s, s), "both secret")
end)

test("Secrets: IsSafeKey refuses a secret even when this context may READ it", function()
    -- The key restriction is about the value being secret at all, not about
    -- access — the two answers differ, and they differ in the direction that
    -- matters here. Accessibility is left ON so this case is not smuggled
    -- through by CanAccess happening to say no as well.
    -- red under: `return Secrets.CanAccess(v)` — an accessible secret goes green
    -- and the roster keys on it again.
    local inst = T.load{}
    local S, m = inst.NS.Secrets, inst.mocks
    m.setSecretsAccessible(true)
    local s = m.secret("Pet-0-SECRET")

    assertTrue(S.CanAccess(s), "the fixture is an ACCESSIBLE secret")
    assertFalse(S.IsSafeKey(s), "and it is still illegal as a key")
    assertTrue(S.IsSafeKey("Player-1-0000000A"), "a plain GUID is a legal key")
    assertFalse(S.IsSafeKey(nil), "nil is not a key either, and is not an error")
end)

test("Secrets: no inspector ever compares or measures the value it is handed", function()
    -- The simulator raises on arithmetic, ordering and concatenation, so putting
    -- a secret through every entry point at once is a real test of the rule
    -- rather than a restatement of it.
    local inst = T.load{}
    local S, m = inst.NS.Secrets, inst.mocks
    local s = m.secret(42)
    m.setSecretsAccessible(false)
    for _, fn in ipairs({ "IsSecret", "CanAccess", "CanCompare", "IsSecretTable",
                          "CanAccessTable" }) do
        local ok, err = pcall(S[fn], s)
        assertTrue(ok, "Secrets." .. fn .. " raised on a secret: " .. tostring(err))
    end
    local ok, err = pcall(S.CanCompare2, s, s)
    assertTrue(ok, "Secrets.CanCompare2 raised on two secrets: " .. tostring(err))
end)

-- ── table inspection ────────────────────────────────────────────────────────

test("Secrets: IsSecretTable distinguishes a secret table from a table of secrets", function()
    -- They are different facts. A table of secret VALUES is an ordinary table
    -- that may be walked; a secret TABLE may not be indexed at all.
    local plain = { mocks.secret(1), mocks.secret(2) }
    assertFalse(Secrets.IsSecretTable(plain),
        "a plain array holding secrets is not itself a secret table")
    assertTrue(Secrets.IsSecretTable(mocks.secretTable({ 1, 2 })))
    assertFalse(Secrets.IsSecretTable(nil))
    assertFalse(Secrets.IsSecretTable("not a table"))
end)

test("Secrets: CanAccessTable refuses everything that is not a table", function()
    -- The guard is what stops SafeIterate indexing a number.
    for _, v in ipairs({ 1, "x", true }) do
        assertFalse(Secrets.CanAccessTable(v))
    end
    assertFalse(Secrets.CanAccessTable(nil))
    assertTrue(Secrets.CanAccessTable({}))
end)

test("Secrets: CanAccessTable refuses a secret table under enforcement", function()
    local inst = T.load{}
    local S, m = inst.NS.Secrets, inst.mocks
    m.setSecretsAccessible(false)
    assertFalse(S.CanAccessTable(m.secretTable({ 1 })))
    assertTrue(S.CanAccessTable({ 1 }), "an ordinary table is always accessible")
end)

-- ── SafeIterate ─────────────────────────────────────────────────────────────

test("SafeIterate: walks an ordinary array in order and reports how many it visited", function()
    local seen = {}
    local n = Secrets.SafeIterate({ "a", "b", "c" }, function(i, v)
        seen[#seen + 1] = i .. "=" .. v
    end)
    assertEqual(n, 3)
    assertEqual(table.concat(seen, ","), "1=a,2=b,3=c")
end)

test("SafeIterate: stops at the first nil rather than running to the limit", function()
    -- Rule 3. Testing a NON-BOOLEAN secret for nil-ness is the one permitted
    -- boolean-shaped operation, and session rows are tables — never booleans —
    -- so this is legal on the real client too.
    local t = { "a", "b" }
    t[4] = "d"   -- past the hole; must never be reached
    local seen = 0
    local n = Secrets.SafeIterate(t, function() seen = seen + 1 end)
    assertEqual(n, 2, "the walk must stop at index 3, where the array ends")
    assertEqual(seen, 2)
end)

test("SafeIterate: never applies the length operator to the table", function()
    -- THE case. A lazy array answers 0 for `#` and three entries for indexing,
    -- so an implementation that measured first would visit nothing.
    -- red under: rewriting the loop as `for i = 1, #tbl do`.
    local visited = 0
    local n = Secrets.SafeIterate(lazyArray(3), function() visited = visited + 1 end)
    assertEqual(visited, 3, "a length-operator implementation would have visited 0")
    assertEqual(n, 3)
end)

test("SafeIterate: a secret table is refused before it is ever indexed", function()
    -- Rule 2 — the guard has to come FIRST. Indexing a secret table raises, so
    -- an implementation that read `tbl[1]` before asking canaccesstable would
    -- not return 0; it would take the whole render pass down.
    -- red under: moving the CanAccessTable guard below the loop.
    local inst = T.load{}
    local S, m = inst.NS.Secrets, inst.mocks
    m.setSecretsAccessible(false)
    local calls = 0
    local ok, err = pcall(S.SafeIterate, m.secretTable({ 1, 2, 3 }),
        function() calls = calls + 1 end)
    assertTrue(ok, "SafeIterate raised on a secret table: " .. tostring(err))
    assertEqual(err, 0, "an inaccessible table has visited zero entries")
    assertEqual(calls, 0, "the callback must never see an entry of a secret table")
end)

test("SafeIterate: hands secret VALUES to the callback untouched", function()
    -- Rule 4. The value goes through opaque; what the callback does with it is
    -- the callback's contract. Anything this function did to it — a comparison,
    -- a tostring, a table-key — would raise in combat.
    local inst = T.load{}
    local S, m = inst.NS.Secrets, inst.mocks
    local rows = { m.secret(500), m.secret(250) }
    local got = {}
    local n = S.SafeIterate(rows, function(_, v) got[#got + 1] = v end)
    assertEqual(n, 2)
    assertTrue(m.isSimulatedSecret(got[1]), "the value must arrive still secret")
    assertEqual(m.reveal(got[1]), 500, "and still be the value it started as")
    assertEqual(m.reveal(got[2]), 250)
end)

test("SafeIterate: a callback returning false stops the walk", function()
    -- The tooltip wants the first N spells and has no legal way to ask how many
    -- there are first, so early exit is the only bound it has.
    local seen = 0
    local n = Secrets.SafeIterate({ 1, 2, 3, 4, 5 }, function(i)
        seen = seen + 1
        if i == 2 then return false end
    end)
    assertEqual(seen, 2)
    assertEqual(n, 2, "the count must be what was visited, not what was there")
end)

test("SafeIterate: a callback returning nil does NOT stop the walk", function()
    -- The stop signal is `false` specifically. Most callbacks return nothing,
    -- and treating a falsy return as a stop would make every one of them visit
    -- exactly one entry.
    -- red under: `if not fn(i, value) then break end`.
    local seen = 0
    assertEqual(Secrets.SafeIterate({ 1, 2, 3 }, function() seen = seen + 1 end), 3)
    assertEqual(seen, 3)
end)

test("SafeIterate: bad arguments are refused rather than raising", function()
    assertEqual(Secrets.SafeIterate(nil, function() end), 0)
    assertEqual(Secrets.SafeIterate("not a table", function() end), 0)
    assertEqual(Secrets.SafeIterate({ 1, 2 }, nil), 0)
    assertEqual(Secrets.SafeIterate({ 1, 2 }, "not a function"), 0)
end)

test("SafeIterate: an unbounded array stops at the hard ceiling", function()
    -- Without `#` and without a trustworthy nil terminator, the only thing
    -- standing between a corrupt table and a frozen client is the ceiling. A
    -- table that answers for EVERY index is exactly that case.
    local endless = setmetatable({}, { __index = function(_, i) return { i } end })
    local visited = 0
    local n = Secrets.SafeIterate(endless, function() visited = visited + 1 end)
    assertTrue(n > 0, "the walk must actually run")
    assertTrue(n <= 1024, "the walk is unbounded — a corrupt table would freeze the client")
    assertEqual(visited, n)
end)

-- ── SafeCount ───────────────────────────────────────────────────────────────

test("SafeCount: counts an ordinary array and stops at the first nil", function()
    assertEqual(Secrets.SafeCount({ "a", "b", "c" }), 3)
    assertEqual(Secrets.SafeCount({}), 0, "an empty array has zero entries, which is knowable")
    local holed = { "a" }
    holed[3] = "c"
    assertEqual(Secrets.SafeCount(holed), 1)
end)

test("SafeCount: never applies the length operator", function()
    -- red under: `return #tbl`.
    assertEqual(Secrets.SafeCount(lazyArray(4)), 4,
        "a length-operator implementation would have answered 0")
end)

test("SafeCount: answers nil — not 0 — when the count is not obtainable", function()
    -- The two are different facts, and a window that rendered "0 sources" when
    -- it means "I cannot see the sources" is lying to the player. The nil is
    -- what selects the unavailable notice instead.
    -- red under: returning 0 from either guard.
    local inst = T.load{}
    local S, m = inst.NS.Secrets, inst.mocks
    m.setSecretsAccessible(false)
    assertNil(S.SafeCount(nil))
    assertNil(S.SafeCount("not a table"))
    assertNil(S.SafeCount(m.secretTable({ 1, 2, 3 })))
    assertEqual(S.SafeCount({}), 0, "an accessible empty table is a real zero")
end)

test("SafeCount: counts a table of secret values without touching one", function()
    local inst = T.load{}
    local S, m = inst.NS.Secrets, inst.mocks
    m.setSecretsAccessible(false)
    local rows = { m.secret(1), m.secret(2), m.secret(3) }
    local ok, n = pcall(S.SafeCount, rows)
    assertTrue(ok, "SafeCount raised on an array of secrets: " .. tostring(n))
    assertEqual(n, 3)
end)

test("SafeCount and SafeIterate agree on the same array", function()
    -- They are two readings of one rule, and a divergence between them is how a
    -- window ends up drawing a different number of rows than it counted.
    for _, t in ipairs({ {}, { 1 }, { 1, 2, 3, 4, 5 } }) do
        assertEqual(Secrets.SafeCount(t), Secrets.SafeIterate(t, function() end))
    end
    assertEqual(Secrets.SafeCount(lazyArray(6)),
        Secrets.SafeIterate(lazyArray(6), function() end))
end)

-- ── the whole secrets system absent ─────────────────────────────────────────

test("Secrets degraded: with no detection APIs, nothing is secret and everything compares",
function()
    -- The rule in that world is "everything is a plain value". Each function
    -- assumes NOTHING exists and builds up from there, rather than assuming the
    -- modern client and guarding the exceptions — which is why this is one case
    -- over the whole surface rather than five guarded ones.
    -- red under: dropping any `if not fn then` guard in core/Secrets.lua.
    local inst = loadWithout("issecretvalue", "canaccessvalue",
                             "issecrettable", "canaccesstable")
    local S, m = inst.NS.Secrets, inst.mocks
    local wrapped = m.secret(1234)   -- still a simulated secret; the client just cannot tell

    assertFalse(S.IsSecret(wrapped), "with no issecretvalue, nothing reads as secret")
    assertTrue(S.CanAccess(wrapped), "and everything is therefore accessible")
    assertTrue(S.CanCompare(wrapped))
    assertTrue(S.CanCompare2(wrapped, wrapped))
    assertFalse(S.IsSecretTable(m.secretTable({})), "with no issecrettable, no table is secret")
    assertTrue(S.CanAccessTable({ 1, 2 }))
    assertFalse(S.CanAccessTable(nil), "the type guard is ours and survives the absence")
end)

test("Secrets degraded: SafeIterate and SafeCount are ordinary array walks", function()
    local inst = loadWithout("issecretvalue", "canaccessvalue",
                             "issecrettable", "canaccesstable")
    local S = inst.NS.Secrets
    local seen = {}
    assertEqual(S.SafeIterate({ "a", "b" }, function(i, v) seen[i] = v end), 2)
    assertEqual(seen[1] .. seen[2], "ab")
    assertEqual(S.SafeCount({ "a", "b" }), 2)
    assertNil(S.SafeCount(nil), "the not-a-table answer is still nil, not 0")
    assertEqual(S.SafeIterate(lazyArray(3), function() end), 3,
        "the no-length-operator rule holds on the old client too")
end)

test("Secrets degraded: canaccessvalue alone missing still refuses a known secret", function()
    -- The half-present client: issecretvalue exists, canaccessvalue does not.
    -- CanAccess then falls back to "accessible unless known secret", which is
    -- the only answer that keeps a comparison from being attempted on a value
    -- the client has already said is opaque.
    -- red under: `if fn then ... end return true`.
    local inst = loadWithout("canaccessvalue")
    local S, m = inst.NS.Secrets, inst.mocks
    assertTrue(S.IsSecret(m.secret(1)), "issecretvalue is still there")
    assertFalse(S.CanAccess(m.secret(1)), "so a known secret must still be refused")
    assertTrue(S.CanAccess(1), "and a plain value must still pass")
end)

test("Secrets degraded: canaccesstable alone missing still refuses a secret table", function()
    local inst = loadWithout("canaccesstable")
    local S, m = inst.NS.Secrets, inst.mocks
    assertFalse(S.CanAccessTable(m.secretTable({ 1 })))
    assertNil(S.SafeCount(m.secretTable({ 1 })))
    assertEqual(S.SafeIterate(m.secretTable({ 1 }), function() end), 0)
    assertTrue(S.CanAccessTable({ 1 }), "an ordinary table is still fine")
end)
