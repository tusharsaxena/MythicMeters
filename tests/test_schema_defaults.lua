-- tests/test_schema_defaults.lua
--
-- The schema-vs-defaults agreement, walked MECHANICALLY over every row rather
-- than sampled.
--
-- settings/Schema.lua restates each shipped value that defaults/Profile.lua also
-- states, deliberately: one is what a widget shows before the db exists and what
-- a Defaults click restores, the other is what a fresh profile is built from. Two
-- independent statements of one value are the only thing NS.ValidateSchema() can
-- actually check — a shared reference would agree with itself by construction —
-- and until settings/OptionsSetup.lua's `validate` descriptor field was pointed at
-- NS.ValidateSchema rather than at a Helpers member that does not exist, that
-- check had never once run in the client.
--
-- So this suite does not merely call the validator and read its answer. It
-- reproduces the comparison here, INDEPENDENTLY and DEEPLY, and then proves the
-- validator agrees — because a validator asserted only against itself proves
-- nothing, and because settings/Schema.lua's own `sameDefault` is one level deep
-- while nothing stops a future default from being two.

local T = _G.MYTHICMETERS_TEST
local NS = T.NS
local test, assertEqual, assertTrue = T.test, T.assertEqual, T.assertTrue

local WINDOW_PREFIX = "window"

-- ---------------------------------------------------------------------------
-- The independent comparison
-- ---------------------------------------------------------------------------

local function split(path)
    local parts = {}
    for segment in tostring(path):gmatch("[^%.]+") do parts[#parts + 1] = segment end
    return parts
end

local function readFrom(root, parts, first)
    local node = root
    for i = first, #parts do
        if type(node) ~= "table" then return nil end
        node = node[parts[i]]
    end
    return node
end

--- Recursive structural equality, reported as a list of differing sub-paths.
---
--- RECURSIVE and not field-wise: a color is `{ r, g, b, a }` today, and a
--- one-level compare would wave through a nested default the moment one appears.
--- Both directions are walked, so a key present on one side only is a difference
--- rather than a silent pass.
local function diff(a, b, where, out)
    if type(a) ~= type(b) then
        out[#out + 1] = ("%s: type %s vs %s"):format(where, type(a), type(b))
        return
    end
    if type(a) ~= "table" then
        if a ~= b then
            out[#out + 1] = ("%s: %s vs %s"):format(where, tostring(a), tostring(b))
        end
        return
    end
    for k, v in pairs(a) do
        diff(v, b[k], where .. "." .. tostring(k), out)
    end
    for k, v in pairs(b) do
        if a[k] == nil then
            out[#out + 1] = ("%s.%s: missing on the schema side (defaults ship %s)")
                :format(where, tostring(k), tostring(v))
        end
    end
end

--- The root a row's path resolves against in the DEFAULTS tree, and the index of
--- its first segment inside that root. The same split settings/Schema.lua makes.
local function defaultsRootFor(parts)
    if parts[1] == WINDOW_PREFIX then
        return NS.WINDOW_TEMPLATE, 2
    end
    return NS.defaults.profile, 1
end

-- ---------------------------------------------------------------------------
-- The premise
-- ---------------------------------------------------------------------------
--
-- NS.ValidateSchema() answers 0 — a clean pass — when EITHER the defaults tree or
-- the window template is missing, because it has nothing to compare against. That
-- makes "0 unresolved paths" a claim about a load that happened, so the load is
-- asserted before the zero is trusted.

test("Schema defaults: the two trees the validator compares are both present", function()
    assertEqual(type(NS.Schema), "table", "NS.Schema")
    assertEqual(type(NS.defaults), "table", "NS.defaults")
    assertEqual(type(NS.defaults.profile), "table", "NS.defaults.profile")
    assertEqual(type(NS.WINDOW_TEMPLATE), "table", "NS.WINDOW_TEMPLATE")
    assertTrue(#NS.Schema > 50,
        "the schema is ~75 rows; a short one means a page file raised and took its "
        .. "RegisterSchemaRows with it, and every walk below would then be vacuous")
end)

-- ---------------------------------------------------------------------------
-- The mechanical walk
-- ---------------------------------------------------------------------------

test("Schema defaults: every non-session row resolves against defaults/Profile.lua", function()
    local unresolved = {}
    local checked = 0
    for _, row in ipairs(NS.Schema) do
        if not row.sessionOnly then
            checked = checked + 1
            local parts = split(row.path)
            local root, first = defaultsRootFor(parts)
            if readFrom(root, parts, first) == nil then
                unresolved[#unresolved + 1] = row.path
            end
        end
    end
    assertTrue(checked > 50, "walked only " .. checked .. " persisted rows")
    assertEqual(#unresolved, 0,
        "paths that do not resolve against the defaults tree: "
        .. table.concat(unresolved, ", "))
end)

test("Schema defaults: every row's default equals the shipped default, compared deeply", function()
    local problems = {}
    for _, row in ipairs(NS.Schema) do
        if not row.sessionOnly then
            local parts = split(row.path)
            local root, first = defaultsRootFor(parts)
            local shipped = readFrom(root, parts, first)
            diff(row.default, shipped, row.path, problems)
        end
    end
    assertEqual(#problems, 0,
        "schema/defaults disagreements:\n            " .. table.concat(problems, "\n            "))
end)

-- The nested case, called out on its own so a regression names itself. Every
-- table default in this schema is a color, and a color is exactly the shape a
-- one-level `pairs` compare handles by luck rather than by design.
test("Schema defaults: every color default agrees on all four channels", function()
    local colors = 0
    for _, row in ipairs(NS.Schema) do
        if row.type == "color" then
            colors = colors + 1
            local parts = split(row.path)
            local root, first = defaultsRootFor(parts)
            local shipped = readFrom(root, parts, first)
            assertEqual(type(shipped), "table", row.path .. ": shipped default is not a table")
            assertEqual(type(row.default), "table", row.path .. ": row default is not a table")
            for _, channel in ipairs({ "r", "g", "b", "a" }) do
                assertEqual(type(row.default[channel]), "number",
                    row.path .. "." .. channel .. " is missing from the schema default")
                assertEqual(row.default[channel], shipped[channel],
                    row.path .. "." .. channel)
            end
        end
    end
    assertTrue(colors >= 7,
        "only " .. colors .. " color rows found; the schema ships eight and this walk "
        .. "is the reason a nested default cannot drift")
end)

test("Schema defaults: a table default is never the SAME table the defaults tree holds", function()
    -- Shared identity would make every comparison above agree with itself and
    -- prove nothing, and it would alias two profiles onto one color table.
    for _, row in ipairs(NS.Schema) do
        if type(row.default) == "table" then
            local parts = split(row.path)
            local root, first = defaultsRootFor(parts)
            local shipped = readFrom(root, parts, first)
            assertTrue(row.default ~= shipped,
                row.path .. ": the schema default and the shipped default are one table")
        end
    end
end)

-- ---------------------------------------------------------------------------
-- The session-only exemption
-- ---------------------------------------------------------------------------

test("Schema defaults: session-only rows are exempt and carry their own storage", function()
    local session = 0
    for _, row in ipairs(NS.Schema) do
        if row.sessionOnly then
            session = session + 1
            assertEqual(type(row.get), "function", row.path .. " has no get()")
            assertEqual(type(row.set), "function", row.path .. " has no set()")
            -- Exempt because they are genuinely absent from the persisted tree:
            -- an exemption for a row that DOES resolve would be hiding a
            -- persisted setting from the validator.
            local parts = split(row.path)
            local root, first = defaultsRootFor(parts)
            assertEqual(readFrom(root, parts, first), nil,
                row.path .. " is declared session-only but resolves in the defaults tree")
        end
    end
    assertEqual(session, 2, "the schema declares two session-only rows")
end)

-- ---------------------------------------------------------------------------
-- The validator itself
-- ---------------------------------------------------------------------------

test("ValidateSchema: reports zero failures on a healthy load", function()
    assertEqual(NS.ValidateSchema(), 0)
end)

-- The two cases that make the zero above mean something. Both run on a FRESH
-- instance, because they corrupt the schema they measure.

test("ValidateSchema: counts a row whose default disagrees with the defaults tree", function()
    local inst = T.load()
    local row = inst.NS.FindSchemaRow("window.frame.width")
    assertEqual(inst.NS.ValidateSchema(), 0, "the fresh instance starts clean")
    row.default = row.default + 17
    assertEqual(inst.NS.ValidateSchema(), 1,
        "a moved default must be counted; if this is 0 the validator is not comparing")
end)

test("ValidateSchema: counts a row whose path does not resolve", function()
    local inst = T.load()
    inst.NS.RegisterSchemaRows({
        { path = "window.frame.widht", type = "number", default = 480, page = "frame" },
    })
    assertEqual(inst.NS.ValidateSchema(), 1,
        "a typo'd path writes to a key nothing reads, which is the bug this check exists for")
end)

test("ValidateSchema: compares a color CHANNEL, not just the presence of a table", function()
    local inst = T.load()
    local row = inst.NS.FindSchemaRow("window.frame.backdropColor")
    assertEqual(type(row.default), "table")
    row.default = { r = 0, g = 0, b = 0, a = 0.5 }   -- shipped alpha is 0.75
    assertEqual(inst.NS.ValidateSchema(), 1)
end)
