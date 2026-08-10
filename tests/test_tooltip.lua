-- tests/test_tooltip.lua — modules/Tooltip.lua: the spell breakdown, and the
-- two real bugs a tooltip invites.
--
-- A tooltip LOOKS like the safest place in a meter — unprotected, built out of
-- strings, nothing secure about it. It is in fact the most dangerous, because it
-- is where the instinct is to say "just show the top five spells" and "put the
-- total at the bottom". A top-N is a COMPARISON and a total is ARITHMETIC, and
-- both raise while the Combat restriction is active.
--
-- Every fixture below therefore lists its spells in ASCENDING order. That is the
-- one detail that makes the sort cases falsifiable: a sort that ran shows the
-- list reversed, and a sort that was correctly refused shows the API's own
-- order, so "did it sort" is answered by looking at the tooltip rather than by
-- trusting a flag.

local T = _G.MYTHICMETERS_TEST

local test        = T.test
local assertEqual = T.assertEqual
local assertTrue  = T.assertTrue
local assertFalse = T.assertFalse

local CURRENT = 1
local ALPHA   = "Player-1-0000000A"

--- A per-source breakdown whose spells ASCEND, so a legal sort is visible.
local function ascendingSpells()
    return {
        combatSpells = {
            { spellID = 101, totalAmount = 100 },
            { spellID = 102, totalAmount = 200 },
            { spellID = 103, totalAmount = 300 },
        },
        maxAmount = 300, totalAmount = 600,
    }
end

--- A loaded instance with one source detail installed, plus a window config and
--- a bare anchor frame to hang the tooltip on.
local function bench(opts)
    opts = opts or {}
    local inst = T.load()
    local NS, mocks = inst.NS, inst.mocks

    mocks.setSourceDetail(CURRENT, "*", "*", opts.detail or ascendingSpells())
    if opts.restricted then mocks.setRestricted(true) end

    local cfg = NS.Database.GetWindows()[1]
    -- The shipped default is Overall; this fixture seeds the CURRENT session.
    cfg.data.sessionType = CURRENT
    if opts.configure then opts.configure(cfg) end

    local anchor = mocks.__stubFrame("Frame")
    mocks.GameTooltip:ClearLines()
    return inst, cfg, anchor
end

local function row(opts)
    opts = opts or {}
    return {
        guid          = opts.guid or ALPHA,
        windowId      = opts.windowId,
        name          = opts.name or "Alpha",
        classFilename = "MAGE",
        deathRecapID  = opts.deathRecapID,
        values        = {},
    }
end

--- The spell IDs the tooltip listed, in the order it listed them.
local function listedSpellIDs(mocks)
    local out = {}
    for _, line in ipairs(mocks.GameTooltip.__lines) do
        local text = line.text
        if type(text) == "string" then
            local id = text:match("Mock Spell (%d+)")
            if id then out[#out + 1] = tonumber(id) end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- The cell tooltip
-- ---------------------------------------------------------------------------

test("CellTooltip opens on the hovered cell and heads with the player and the stat", function()
    local inst, cfg, anchor = bench()
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    local tt = inst.mocks.GameTooltip
    assertTrue(tt:GetOwner() == anchor, "GameTooltip is re-owned on every hover")
    assertEqual(tt.__lines[1].text, "Alpha")
    assertEqual(tt.__lines[1].right, "Damage", "localized at the use site, from the catalog")
end)

test("CellTooltip honors the anchor setting and falls back to the cursor", function()
    local inst, cfg, anchor = bench()
    cfg.tooltip.anchor = "BOTTOMRIGHT"
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)
    assertEqual(inst.mocks.GameTooltip.__anchor, "ANCHOR_BOTTOMRIGHT")

    cfg.tooltip.anchor = "SOMETHINGWRONG"
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)
    assertEqual(inst.mocks.GameTooltip.__anchor, "ANCHOR_CURSOR",
        "a typo'd token must not silently become a broken anchor")
end)

test("CellTooltip sorts biggest-first when comparison is legal", function()
    local inst, cfg, anchor = bench()
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    -- The fixture ascends; a sorted tooltip descends.
    local ids = listedSpellIDs(inst.mocks)
    assertEqual(#ids, 3)
    assertEqual(ids[1], 103)
    assertEqual(ids[2], 102)
    assertEqual(ids[3], 101)
end)

test("CellTooltip REFUSES the sort while comparison is illegal", function()
    local inst, cfg, anchor = bench{ restricted = true }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    -- Not a degradation: the API already returns a meaningful sequence, and the
    -- alternative is a Lua error on every hover for the whole of a pull.
    local ids = listedSpellIDs(inst.mocks)
    assertEqual(#ids, 3)
    assertEqual(ids[1], 101, "the provider's own order, unreversed")
    assertEqual(ids[3], 103)
end)

test("CellTooltip refuses the sort when an amount is MISSING, not merely secret", function()
    -- CanAccess(nil) is TRUE — nil is not a secret — so a spell row with no
    -- totalAmount sails through a comparability check and then raises inside the
    -- comparator with "attempt to compare nil with number". This was a real bug.
    local inst, cfg, anchor = bench{ detail = {
        combatSpells = {
            { spellID = 101, totalAmount = 100 },
            { spellID = 102 },                      -- no amount at all
            { spellID = 103, totalAmount = 300 },
        },
        maxAmount = 300, totalAmount = 400,
    } }

    local ok = pcall(function()
        inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)
    end)
    assertTrue(ok, "a missing amount must refuse the sort, not raise inside it")

    local ids = listedSpellIDs(inst.mocks)
    assertEqual(ids[1], 101, "and the whole list keeps the provider's order")
    assertEqual(ids[2], 102)
    assertEqual(ids[3], 103)
end)

test("CellTooltip caps the list at maxSpells and says how many were left out", function()
    local inst, cfg, anchor = bench{
        detail = { combatSpells = {
            { spellID = 101, totalAmount = 500 }, { spellID = 102, totalAmount = 400 },
            { spellID = 103, totalAmount = 300 }, { spellID = 104, totalAmount = 200 },
            { spellID = 105, totalAmount = 100 },
        }, maxAmount = 500, totalAmount = 1500 },
        configure = function(cfg) cfg.tooltip.maxSpells = 2 end,
    }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    assertEqual(#listedSpellIDs(inst.mocks), 2)

    -- The count comes from NS.Secrets.SafeCount, which never applies `#` to a
    -- possibly-secret array — which is what lets this line be honest at all.
    local more = false
    for _, line in ipairs(inst.mocks.GameTooltip.__lines) do
        if type(line.text) == "string" and line.text:find("and 3 more", 1, true) then
            more = true
        end
    end
    assertTrue(more, "the tooltip must say what it left out")
end)

test("CellTooltip renders secret amounts through the formatter, untouched", function()
    local inst, cfg, anchor = bench{ restricted = true }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    local amounts = {}
    for _, line in ipairs(inst.mocks.GameTooltip.__lines) do
        if type(line.text) == "string" and line.text:find("Mock Spell", 1, true) then
            amounts[#amounts + 1] = line.right
        end
    end
    assertEqual(#amounts, 3)
    -- Nothing added them, nothing compared them; they went through the native
    -- formatter and straight to the widget.
    assertEqual(amounts[1], "100")
    assertEqual(amounts[3], "300")
end)

test("CellTooltip says 'no data' rather than showing an empty frame", function()
    local inst = T.load()
    local cfg = inst.NS.Database.GetWindows()[1]
    local anchor = inst.mocks.__stubFrame("Frame")
    inst.mocks.GameTooltip:ClearLines()

    -- No source detail installed at all: the provider refuses and the tooltip
    -- has to say something.
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)
    local found = false
    for _, line in ipairs(inst.mocks.GameTooltip.__lines) do
        if line.text == inst.NS.L["No data yet"] then found = true end
    end
    assertTrue(found)
end)

test("showSpells = false keeps the header and drops the breakdown", function()
    local inst, cfg, anchor = bench{ configure = function(c) c.tooltip.showSpells = false end }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)
    assertEqual(#listedSpellIDs(inst.mocks), 0)
end)

test("hideInCombat refuses the hover outright", function()
    local inst, cfg, anchor = bench{ configure = function(c) c.tooltip.hideInCombat = true end }
    inst.mocks.setInCombat(true)

    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)
    assertEqual(#inst.mocks.GameTooltip.__lines, 0, "nothing is added at all")

    -- The test is UnitAffectingCombat, not InCombatLockdown: what the setting
    -- means is "while I am fighting, keep this out of my way", which is a
    -- statement about the player rather than about secure writes.
    inst.mocks.setInCombat(false)
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)
    assertTrue(#inst.mocks.GameTooltip.__lines > 0)
end)

test("An unresolvable spell is shown by ID rather than dropped", function()
    local inst, cfg, anchor = bench{
        detail = { combatSpells = { { spellID = 909, totalAmount = 10 } },
                   maxAmount = 10, totalAmount = 10 },
    }
    inst.mocks.C_Spell.GetSpellInfo = function() return nil end

    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    local found = false
    for _, line in ipairs(inst.mocks.GameTooltip.__lines) do
        if type(line.text) == "string" and line.text:find("#909", 1, true) then found = true end
    end
    assertTrue(found, "an unnamed row is still evidence; a silently missing row is not")
end)

-- ---------------------------------------------------------------------------
-- Avoidable damage carries its own facts
-- ---------------------------------------------------------------------------

test("The avoidable column tags Avoidable and Deadly, and NOT Overkill", function()
    local inst, cfg, anchor = bench{ detail = {
        combatSpells = {
            { spellID = 101, totalAmount = 100, isAvoidable = true, isDeadly = true,
              overkillAmount = 40 },
        },
        maxAmount = 100, totalAmount = 100,
    } }
    inst.NS.Tooltip:CellTooltip(row(), "AvoidableDamageTaken", anchor, cfg)

    local text = ""
    for _, line in ipairs(inst.mocks.GameTooltip.__lines) do
        if type(line.text) == "string" then text = text .. line.text .. "\n" end
    end
    assertTrue(text:find("Avoidable", 1, true) ~= nil)
    assertTrue(text:find("Deadly", 1, true) ~= nil)

    -- Overkill is the part of a KILLING BLOW that exceeded the target's remaining
    -- health — a fact about damage DEALT. On damage the player took it is either
    -- zero or the amount by which they were already dead, and neither answers
    -- "could I have stepped out of this". Blizzard still ships the field; we have
    -- no column it belongs to.
    -- red under: restoring the overkillAmount line to addAvoidableDetail.
    assertFalse(text:find("Overkill", 1, true) ~= nil,
        "the overkill line is noise on damage taken")
end)

test("Those flags are never truth-tested directly — a secret boolean would raise", function()
    local inst, cfg, anchor = bench{ restricted = true, detail = {
        combatSpells = {
            { spellID = 101, totalAmount = 100, isAvoidable = true, isDeadly = true,
              overkillAmount = 40 },
        },
        maxAmount = 100, totalAmount = 100,
    } }

    -- `if spell.isAvoidable then` is the natural way to write it and raises the
    -- moment the restriction is active. An inaccessible flag reads as false: the
    -- tooltip loses a tag mid-pull rather than erroring.
    local ok = pcall(function()
        inst.NS.Tooltip:CellTooltip(row(), "AvoidableDamageTaken", anchor, cfg)
    end)
    assertTrue(ok)

    local text = ""
    for _, line in ipairs(inst.mocks.GameTooltip.__lines) do
        if type(line.text) == "string" then text = text .. line.text .. "\n" end
    end
    -- Reaching this line at all is the assertion: the simulator raises on a
    -- boolean test of a secret, so a `if spell.isAvoidable then` that crept back
    -- in would have failed the pcall above rather than produced a wrong string.
    assertFalse(text:find("Overkill", 1, true) ~= nil)
end)

-- ---------------------------------------------------------------------------
-- The Deaths cell
-- ---------------------------------------------------------------------------

test("The Deaths cell advertises the click that opens the recap", function()
    local inst, cfg, anchor = bench()
    inst.NS.Tooltip:CellTooltip(row{ deathRecapID = 4242 }, "Deaths", anchor, cfg)

    local found = false
    for _, line in ipairs(inst.mocks.GameTooltip.__lines) do
        if line.text == inst.NS.L["Click for details"] then found = true end
    end
    assertTrue(found, "it is the one cell where a click does something else")
end)

test("A death with no recap id advertises nothing", function()
    local inst, cfg, anchor = bench()
    inst.NS.Tooltip:CellTooltip(row(), "Deaths", anchor, cfg)
    for _, line in ipairs(inst.mocks.GameTooltip.__lines) do
        assertFalse(line.text == inst.NS.L["Click for details"])
    end
end)

-- ---------------------------------------------------------------------------
-- The name tooltip
-- ---------------------------------------------------------------------------

test("NameTooltip lists EVERY tracked stat, dimming the ones not on screen", function()
    local inst, cfg, anchor = bench()
    cfg.columns = { { stat = "DamageDone", width = 90 } }

    inst.NS.Tooltip:NameTooltip(row(), anchor, cfg)

    local labels = {}
    for _, line in ipairs(inst.mocks.GameTooltip.__lines) do
        if line.double then labels[#labels + 1] = line.text end
    end
    -- Showing the hidden columns is the requirement: the reason to hover a name
    -- is to ask "what else did they do".
    assertEqual(#labels, #inst.NS.Constants.STATS)

    local gray = inst.NS.GRAY
    local onScreen, dimmed = 0, 0
    for _, label in ipairs(labels) do
        if label:sub(1, #gray) == gray then dimmed = dimmed + 1 else onScreen = onScreen + 1 end
    end
    assertEqual(onScreen, 1, "the window's own column is drawn in full color")
    assertEqual(dimmed, #inst.NS.Constants.STATS - 1)
end)

test("NameTooltip works while restricted, adding nothing up", function()
    local inst, cfg, anchor = bench{ restricted = true }
    local ok = pcall(function() inst.NS.Tooltip:NameTooltip(row(), anchor, cfg) end)
    assertTrue(ok)
    assertTrue(#inst.mocks.GameTooltip.__lines > 1)
end)

test("showAllStatsOnName = false stops after the name", function()
    local inst, cfg, anchor = bench{
        configure = function(c) c.tooltip.showAllStatsOnName = false end }
    inst.NS.Tooltip:NameTooltip(row(), anchor, cfg)
    assertEqual(#inst.mocks.GameTooltip.__lines, 1)
end)

test("NameTooltip says 'no data' when the meter has nothing for the player", function()
    local inst = T.load()
    local cfg = inst.NS.Database.GetWindows()[1]
    local anchor = inst.mocks.__stubFrame("Frame")
    inst.mocks.GameTooltip:ClearLines()

    inst.NS.Tooltip:NameTooltip(row(), anchor, cfg)
    local found = false
    for _, line in ipairs(inst.mocks.GameTooltip.__lines) do
        if line.text == inst.NS.L["No data yet"] then found = true end
    end
    assertTrue(found)
end)

test("A tooltip resolves its window from row.windowId when it was not handed one", function()
    local inst, cfg, anchor = bench()
    -- The row-pool call sites hold a window ID on the frame, not the table.
    inst.NS.Tooltip:CellTooltip(row{ windowId = cfg.id }, "DamageDone", anchor)
    assertTrue(#inst.mocks.GameTooltip.__lines > 0)
end)

test("Tooltip:Hide is unconditional", function()
    local inst, cfg, anchor = bench()
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)
    inst.NS.Tooltip:Hide()
    -- A hide the addon did not need to do is invisible; a tooltip left pinned
    -- under the cursor is the single most reported meter bug there is.
    assertEqual(inst.mocks.GameTooltip:IsShown(), false)
end)

-- ---------------------------------------------------------------------------
-- Static guarantees
-- ---------------------------------------------------------------------------

test("modules/Tooltip.lua never applies `#` to a meter array", function()
    -- `#spells` on the LOCAL array this file built is fine — it is a plain
    -- table. `#` on combatSpells is the forbidden one, and SafeCount is the
    -- reason it never has to happen.
    local fh = assert(io.open(T.root .. "/modules/Tooltip.lua", "r"))
    local n, offenders, sawSafeCount = 0, {}, false
    for line in fh:lines() do
        n = n + 1
        if not line:match("^%s*%-%-") then
            local code = line:gsub("%s%-%-.*$", "")
            if code:find("SafeCount", 1, true) then sawSafeCount = true end
            if code:find("#%s*source%.combatSpells") or code:find("#combatSpells") then
                offenders[#offenders + 1] = "modules/Tooltip.lua:" .. n
            end
        end
    end
    fh:close()
    assertTrue(sawSafeCount, "the count must come from NS.Secrets.SafeCount")
    assertEqual(#offenders, 0, table.concat(offenders, ", "))
end)

-- ---------------------------------------------------------------------------
-- Bars in the breakdown
-- ---------------------------------------------------------------------------

--- Every StatusBar parented to the tooltip that is currently shown.
local function tooltipBars(inst)
    local shown = {}
    for _, f in ipairs(inst.mocks.__frames) do
        if f.__objectType == "StatusBar" and f.__parent == inst.mocks.GameTooltip
            and f:IsShown() then
            shown[#shown + 1] = f
        end
    end
    return shown
end

test("A spell line carries a real class-colored BAR, not a run of characters", function()
    -- Two earlier attempts drew text: block glyphs (not in the game font, drew
    -- boxes) and then `=` (legible, and obviously not a bar). A GameTooltip line
    -- is text and `|T…|t` carries no tint, so the only way to get a real bar is a
    -- StatusBar parented to the tooltip and anchored to the line.
    -- red under: concatenating characters into the right-hand string.
    local inst, cfg, anchor = bench()
    inst.NS.Tooltip:CellTooltip(row{ classFilename = "MAGE" }, "DamageDone", anchor, cfg)

    local bars = tooltipBars(inst)
    assertTrue(#bars > 0, "no bar was drawn")

    local c = inst.mocks.RAID_CLASS_COLORS.MAGE
    assertEqual(bars[1].__barColor[1], c.r, "the bar must wear the row's class color")

    -- And nothing text-shaped is pretending to be one.
    for _, line in ipairs(inst.mocks.GameTooltip.__lines) do
        if type(line.right) == "string" then
            assertFalse(line.right:find("==", 1, true) ~= nil,
                "an ASCII bar is still in the line")
        end
    end
end)

test("Bars are released between hovers, never stacked", function()
    -- They are pooled and re-anchored rather than created per line, so a stale
    -- bar would otherwise sit behind a line it no longer describes.
    -- red under: dropping the releaseBars call at the top of CellTooltip.
    local inst, cfg, anchor = bench()
    inst.NS.Tooltip:CellTooltip(row{ classFilename = "MAGE" }, "DamageDone", anchor, cfg)
    local first = #tooltipBars(inst)

    inst.mocks.GameTooltip:ClearLines()
    inst.NS.Tooltip:CellTooltip(row{ classFilename = "MAGE" }, "DamageDone", anchor, cfg)
    assertEqual(#tooltipBars(inst), first, "the second hover doubled the bars")
end)

test("The bar is OMITTED while the values cannot be divided", function()
    -- A bar's length is amount / max, which raises on two secrets. So it is drawn
    -- when core/Secrets.lua says both operands are readable and omitted when they
    -- are not — exactly like the percent text slot. The NUMBER never goes away,
    -- so a mid-pull tooltip loses decoration rather than information.
    -- red under: dividing without the CanCompare2 gate.
    local inst, cfg, anchor = bench{ restricted = true }
    inst.mocks.setSecretValues(true)

    local ok = pcall(function()
        inst.NS.Tooltip:CellTooltip(row{ classFilename = "MAGE" }, "DamageDone", anchor, cfg)
    end)
    assertTrue(ok, "the tooltip divided a secret")

    assertEqual(#tooltipBars(inst), 0,
        "a bar cannot be sized from values we may not divide")
end)
