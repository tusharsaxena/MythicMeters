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

local T = _G.MULTIMETERS_TEST

local test        = T.test
local assertEqual = T.assertEqual
local assertTrue  = T.assertTrue
local assertFalse = T.assertFalse
local assertNil   = T.assertNil

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

-- ---------------------------------------------------------------------------
-- Reading the spell lines back
-- ---------------------------------------------------------------------------
--
-- A spell line is NOT one tooltip line any more. The tooltip holds the icon and
-- the spell name; the amount and the share live on our own carrier Frame, in two
-- fixed-width right-aligned slots, because AddDoubleLine right-aligns one string
-- and would let the share column zig-zag behind amounts of different widths.
--
-- So a suite that reads `line.right` is reading a slot the addon stopped using.
-- These two helpers read what the player actually sees.

--- Every shown carrier Frame, keyed by the tooltip line index it sits on.
---
--- The index is recovered from the carrier's own LEFT anchor, which is pinned to
--- `GameTooltipTextLeft<N>` — so this asserts the anchoring incidentally, and a
--- carrier that drifted off its line would simply not be found.
local function tooltipLines(inst)
    local out = {}
    for _, f in ipairs(inst.mocks.__frames) do
        if f.__objectType == "Frame" and f.__parent == inst.mocks.GameTooltip
            and f:IsShown() then
            for _, p in ipairs(f.__points) do
                local rel = p.relativeTo
                local index = rel and rel.__name
                    and rel.__name:match("^GameTooltipTextLeft(%d+)$")
                if index then out[tonumber(index)] = f end
            end
        end
    end
    return out
end

--- The carriers in tooltip-line order, so `[1]` is the first spell line.
local function spellLines(inst)
    local byIndex, keys = tooltipLines(inst), {}
    for index in pairs(byIndex) do keys[#keys + 1] = index end
    table.sort(keys)
    local out = {}
    for _, index in ipairs(keys) do out[#out + 1] = byIndex[index] end
    return out
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

test("CellTooltip honors the anchor setting and falls back to the default", function()
    local inst, cfg, anchor = bench()
    cfg.tooltip.anchor = "BOTTOMRIGHT"
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)
    assertEqual(inst.mocks.GameTooltip.__anchor, "ANCHOR_BOTTOMRIGHT")

    -- TOP, because it is the shipped default: an anchor this build does not
    -- offer -- a typo, or a profile that escaped the v9 -> v10 step still
    -- carrying "CURSOR" -- lands where a new window does rather than somewhere
    -- nothing else uses.
    cfg.tooltip.anchor = "SOMETHINGWRONG"
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)
    assertEqual(inst.mocks.GameTooltip.__anchor, "ANCHOR_TOP",
        "a typo'd token must not silently become a broken anchor")

    local tip, _, rel = inst.mocks.GameTooltip:GetPoint(1)
    assertEqual(tip, "BOTTOM", "the fallback must be PLACED as well as owned")
    assertEqual(rel, "TOP")
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
    for _, carrier in ipairs(spellLines(inst)) do
        amounts[#amounts + 1] = carrier.amount.__text
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

test("The avoidable column tags nothing per spell — no Deadly, no Overkill", function()
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

    -- EVERY spell in an Avoidable Damage breakdown is avoidable, and the header
    -- above the list already says so — a gray "Avoidable" / "Avoidable, Deadly"
    -- sub-line beneath each bar restated the column once per row and broke the
    -- list into ragged groups. It was most visible in test mode, where the
    -- preview detail sets both flags on alternating spells.
    -- red under: restoring addAvoidableDetail.
    assertFalse(text:find("Deadly", 1, true) ~= nil,
        "the per-spell flag lines are noise inside a column that IS the flag")

    -- Overkill is the part of a KILLING BLOW that exceeded the target's remaining
    -- health — a fact about damage DEALT. On damage the player took it is either
    -- zero or the amount by which they were already dead, and neither answers
    -- "could I have stepped out of this". Blizzard still ships the field; we have
    -- no column it belongs to.
    assertFalse(text:find("Overkill", 1, true) ~= nil,
        "the overkill line is noise on damage taken")
end)

test("Those flags are never truth-tested anywhere — a secret boolean would raise", function()
    local inst, cfg, anchor = bench{ restricted = true, detail = {
        combatSpells = {
            { spellID = 101, totalAmount = 100, isAvoidable = true, isDeadly = true,
              overkillAmount = 40 },
        },
        maxAmount = 100, totalAmount = 100,
    } }

    -- `if spell.isAvoidable then` is the natural way to write it and raises the
    -- moment the restriction is active. Nothing reads these flags today, and this
    -- case is what keeps a reader that comes back from reading them the raising
    -- way — the spells still carry them, so a direct truth test would fail here.
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

    local Const = inst.NS.Constants
    local lines = {}
    for _, line in ipairs(inst.mocks.GameTooltip.__lines) do
        if line.double then lines[#lines + 1] = line end
    end

    local onScreen, dimmed = 0, 0
    for i, stat in ipairs(Const.STATS) do
        local full = Const.STAT_COLORS[stat.key]
        local red  = lines[i].leftColor[1]
        if math.abs(red - full[1]) < 0.001 then
            onScreen = onScreen + 1
        elseif math.abs(red - full[1] * Const.STAT_DIM) < 0.001 then
            dimmed = dimmed + 1
        end
    end
    assertEqual(onScreen, 1, "the window's own column is drawn in full color")
    assertEqual(dimmed, #Const.STATS - 1)
end)

test("NameTooltip colors each stat by the catalog palette, whatever colorMode says", function()
    -- THE PALETTE IS NOT THE BAR SETTING. `bars.colorMode` governs the bars in the
    -- grid; this list is the one surface where all nine statistics appear at once,
    -- and the color is what ties a line here to its column in the window behind
    -- it. So it wears the palette even with the bars set to class color.
    -- red under: gating the line color on bars.colorMode == "stat".
    local inst, cfg, anchor = bench()
    cfg.bars.colorMode = "class"
    cfg.columns = { { stat = "DamageDone", width = 90 }, { stat = "HealingDone", width = 90 } }

    inst.NS.Tooltip:NameTooltip(row(), anchor, cfg)

    local Const = inst.NS.Constants
    local lines = {}
    for _, line in ipairs(inst.mocks.GameTooltip.__lines) do
        if line.double then lines[#lines + 1] = line end
    end

    -- The catalog's order is the tooltip's order: Damage first, Healing second.
    local damage, healing = Const.STAT_COLORS.DamageDone, Const.STAT_COLORS.HealingDone
    assertEqual(lines[1].leftColor[1], damage[1])
    assertEqual(lines[1].leftColor[2], damage[2])
    assertEqual(lines[2].leftColor[1], healing[1])
    assertEqual(lines[2].leftColor[2], healing[2])
    assertTrue(damage[1] ~= healing[1] or damage[2] ~= healing[2],
        "two statistics must not share one color, or the palette says nothing")
end)

test("NameTooltip colors the AMOUNT the same as its label, on both sides of the line", function()
    -- A colored name beside a white number reads as two things; the line is one
    -- fact. It was also plainly inconsistent — the dimmed rows carried a gray
    -- number while the rest carried white ones.
    -- red under: passing 1, 1, 1 for the right-hand side again.
    local inst, cfg, anchor = bench()
    cfg.columns = { { stat = "DamageDone", width = 90 } }

    inst.NS.Tooltip:NameTooltip(row(), anchor, cfg)

    local Const = inst.NS.Constants
    local lines = {}
    for _, line in ipairs(inst.mocks.GameTooltip.__lines) do
        if line.double then lines[#lines + 1] = line end
    end

    for i, stat in ipairs(Const.STATS) do
        local line = lines[i]
        for channel = 1, 3 do
            assertEqual(line.rightColor[channel], line.leftColor[channel],
                stat.key .. "'s amount must wear its label's color")
        end
    end

    -- And the dimming reaches the amount too: the second statistic has no column
    -- in this window, so its whole line is the dimmed hue.
    local hidden = Const.STATS[2]
    assertEqual(lines[2].rightColor[1], Const.STAT_COLORS[hidden.key][1] * Const.STAT_DIM)
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

--- Every shown bar under the tooltip.
---
--- One level deeper than it used to be: the bar hangs off a carrier Frame rather
--- than off GameTooltip directly, because the carrier survives a hover the bar
--- cannot — mid-pull the amount and the share still have to be drawn.
local function tooltipBars(inst)
    local shown = {}
    for _, f in ipairs(inst.mocks.__frames) do
        local parent = f.__parent
        if f.__objectType == "StatusBar" and parent
            and parent.__parent == inst.mocks.GameTooltip and f:IsShown() then
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

test("The bar is DRAWN mid-pull, because the widget does the division", function()
    -- THE ASSERTION THAT USED TO SAY THE OPPOSITE, and it cost the tooltip its
    -- bars for the whole of every pull. It read: "a bar's length is amount / max,
    -- which raises on two secrets", and gated the bar on CanCompare2 — so in
    -- combat, where every operand is secret, every bar was hidden. The main
    -- window kept its own bars the entire time, which is what gives the lie away.
    --
    -- The rule forbids TAINTED CODE doing the division. It does not forbid the
    -- division: a StatusBar computes its own fill natively, in code that may see
    -- secrets, and core/Secrets.lua lists SetValue and SetMinMaxValues among the
    -- things tainted code MAY do with a handle. modules/Row.lua has always taken
    -- them raw for exactly this reason.
    -- red under: restoring the CanCompare2 gate, or any `max <= 0` beside it.
    local inst, cfg, anchor = bench{ restricted = true }
    inst.mocks.setSecretValues(true)

    local ok, err = pcall(function()
        inst.NS.Tooltip:CellTooltip(row{ classFilename = "MAGE" }, "DamageDone", anchor, cfg)
    end)
    assertTrue(ok, "the tooltip compared or divided a secret: " .. tostring(err))

    assertEqual(#tooltipBars(inst), 3,
        "the bars were hidden mid-pull, which is the whole bug this pins")
end)

test("A bar spans the FULL line, so its length is comparable down the column", function()
    -- The first shipped version anchored LEFT to the name's RIGHT and RIGHT to the
    -- number's LEFT, which put the bar in the empty gap between the two texts. A
    -- bar in a gap has a length that means nothing: the gap is as wide as the
    -- name is short, so a long spell name shortened its own bar. Every bar has to
    -- start and end where every other bar does — the FILL is what differs.
    -- red under: restoring the LEFT-to-RIGHT / RIGHT-to-LEFT anchoring.
    local inst, cfg, anchor = bench()
    inst.NS.Tooltip:CellTooltip(row{ classFilename = "MAGE" }, "DamageDone", anchor, cfg)

    local carrier = spellLines(inst)[1]
    assertTrue(carrier ~= nil, "no spell line was drawn")

    local seen = {}
    for _, p in ipairs(carrier.__points) do seen[p.point] = p end

    assertTrue(seen.LEFT ~= nil and seen.RIGHT ~= nil, "a line needs both edges pinned")
    assertEqual(seen.LEFT.relativePoint, "LEFT",
        "the track must be measured from the left text's LEFT edge, not from its right")
    assertEqual(seen.RIGHT.relativeTo, inst.mocks.GameTooltip,
        "the track must run out to the tooltip's own right margin")
end)

test("A bar clears the icon rather than running underneath it", function()
    -- The icon is a `|T…|t` escape INSIDE the left line, so the FontString's left
    -- edge is the ICON's left edge. Pinning the track there tints the icon and
    -- makes the row start look ragged; it has to begin where the spell NAME
    -- begins, so the icon reads as its own column the way it does in the grid.
    -- red under: a zero or negative LEFT offset.
    local inst, cfg, anchor = bench()
    inst.NS.Tooltip:CellTooltip(row{ classFilename = "MAGE" }, "DamageDone", anchor, cfg)

    local carrier = spellLines(inst)[1]
    assertTrue(carrier ~= nil, "no spell line was drawn")

    local left
    for _, p in ipairs(carrier.__points) do if p.point == "LEFT" then left = p end end
    assertTrue(left ~= nil, "the track's left edge is unpinned")
    -- 14 is TOOLTIP_ICON_SIZE. Clearing exactly the icon is the point: any less
    -- tints it, any more pushes the track past the spell name and leaves the name
    -- hanging outside its own bar.
    assertEqual(left.x, 14, "the track does not begin at the icon's right edge")
end)

test("The player's name is class-coloured on every tooltip that names one", function()
    -- Every other name this addon draws is class-coloured -- the Player column
    -- has been since the first build -- and the tooltip header was the one place
    -- a name came out white, so a hover read as belonging to nothing.
    -- red under: passing 1, 1, 1 to AddDoubleLine's first colour triple.
    local inst, cfg, anchor = bench()
    local want = inst.mocks.RAID_CLASS_COLORS.MAGE
    assertTrue(want ~= nil, "the mock has no MAGE colour to compare against")

    -- The cell tooltip's header is a DOUBLE line -- name on the left, statistic
    -- on the right -- so its colours are the pair recorded for each side.
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)
    local first = inst.mocks.GameTooltip.__lines[1]
    assertEqual(first.leftColor[1], want.r, "the cell tooltip's name is not class-coloured")
    assertEqual(first.leftColor[3], want.b)
    assertEqual(first.rightColor[1], 1, "the statistic beside it lost its gold")

    -- The name tooltip's is a single line.
    inst.NS.Tooltip:NameTooltip(row(), anchor, cfg)
    first = inst.mocks.GameTooltip.__lines[1]
    assertEqual(first.r, want.r, "the name tooltip's name is not class-coloured")
end)

test("A row with no class keeps a white name rather than an invented colour", function()
    local inst, cfg, anchor = bench()
    local r = row()
    r.classFilename = nil
    inst.NS.Tooltip:CellTooltip(r, "DamageDone", anchor, cfg)
    assertEqual(inst.mocks.GameTooltip.__lines[1].leftColor[1], 1)
end)

test("The scale reaches the tooltip BEFORE it is placed, and is put back after", function()
    -- Set after SetOwner, the placement is computed against the old size and a
    -- scaled-up tooltip runs off the edge of the screen it was just fitted to.
    -- And GameTooltip is Blizzard's: a scale left behind rescales the next quest
    -- text anybody hovers, with nothing on screen to connect it to this addon.
    -- red under: dropping the restore, or scaling after SetOwner.
    local inst, cfg, anchor = bench{ configure = function(c) c.tooltip.scale = 1.4 end }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)
    assertEqual(inst.mocks.GameTooltip.__scale, 1.4)

    inst.NS.Tooltip:Hide()
    assertEqual(inst.mocks.GameTooltip.__scale, 1, "the shared tooltip was left scaled")
end)

test("A nonsense scale is bounded rather than handed to the client", function()
    for _, bad in ipairs({ 0, -3, 99, "big" }) do
        local inst, cfg, anchor = bench{ configure = function(c) c.tooltip.scale = bad end }
        inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)
        local got = inst.mocks.GameTooltip.__scale
        assertTrue(got >= 0.5 and got <= 2,
            "scale " .. tostring(bad) .. " reached the client as " .. tostring(got))
    end
end)

test("The bar's fill and its backdrop each take their own colour and opacity", function()
    -- The fill used to be the hovered player's class and nothing else, with no
    -- setting reaching it; the backdrop was a hard-coded black at 0.35 set once
    -- at creation, which no setting reached and which a POOLED line carried from
    -- one hover to the next.
    -- red under: hard-coding either.
    local inst, cfg, anchor = bench{ configure = function(c)
        c.tooltip.barColorMode   = "custom"
        c.tooltip.barColor       = { r = 1, g = 0, b = 0, a = 1 }
        c.tooltip.barAlpha       = 0.5
        c.tooltip.barBgColorMode = "custom"
        c.tooltip.barBgColor     = { r = 0, g = 0, b = 1, a = 1 }
        c.tooltip.barBgAlpha     = 0.25
    end }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    local b = tooltipBars(inst)[1]
    assertTrue(b ~= nil, "no bar was drawn")
    assertEqual(b.__barColor[1], 1, "the fill ignored its colour")
    assertEqual(b.__barColor[4], 0.5, "the fill ignored its opacity")
    assertEqual(b.bg.__colorTexture[3], 1, "the backdrop ignored its colour")
    assertEqual(b.bg.__colorTexture[4], 0.25, "the backdrop ignored its opacity")
end)

test("Per-statistic mode is the HOVERED column's colour, not the sort column's", function()
    -- THE BUG: it resolved to the window's sort column, so every breakdown of
    -- every column came out in the sort column's colour -- a Healing tooltip in
    -- Damage red. This tooltip IS the breakdown of one statistic, and that
    -- statistic is the one whose cell the pointer is on.
    -- red under: reading window.data.sortColumn in lineStyle.
    local inst, cfg, anchor = bench{ configure = function(c)
        c.tooltip.barColorMode = "stat"
        c.data.sortColumn      = "DamageDone"
    end }
    local Const = inst.NS.Constants
    local want = Const.STAT_COLORS.HealingDone
    local sorted = Const.STAT_COLORS.DamageDone
    assertTrue(want ~= nil and sorted ~= nil, "the palette has no pair to tell apart")
    assertTrue(want[1] ~= sorted[1], "the two colours are identical; the case proves nothing")

    inst.NS.Tooltip:CellTooltip(row(), "HealingDone", anchor, cfg)
    local b = tooltipBars(inst)[1]
    assertTrue(b ~= nil, "no bar was drawn")
    assertEqual(b.__barColor[1], want[1], "a Healing breakdown took the sort column's colour")
end)

test("The text mode follows the hovered column too", function()
    -- One tooltip, one statistic: the bar and the writing on it must not disagree
    -- about which.
    local inst, cfg, anchor = bench{ configure = function(c)
        c.tooltip.colorMode = "stat"
        c.data.sortColumn   = "DamageDone"
    end }
    local want = inst.NS.Constants.STAT_COLORS.HealingDone
    inst.NS.Tooltip:CellTooltip(row(), "HealingDone", anchor, cfg)

    local b = tooltipBars(inst)[1]
    local carrier = b.__parent
    assertEqual(carrier.amount.__textColor[1], want[1],
        "the amount took a different statistic's colour from its own bar")
end)

test("Class mode paints the bar with the hovered player's class", function()
    local inst, cfg, anchor = bench{ configure = function(c)
        c.tooltip.barColorMode = "class"
    end }
    local want = inst.mocks.RAID_CLASS_COLORS.MAGE
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    local b = tooltipBars(inst)[1]
    assertEqual(b.__barColor[1], want.r)
    assertEqual(b.__barColor[3], want.b)
end)

test("The bar border is drawn on the BAR, where it can be seen", function()
    -- IT DID NOTHING AT ANY THICKNESS. The carrier is the parent and the bar is a
    -- child covering it edge to edge, so a backdrop on the carrier was drawn
    -- underneath the bar.
    -- red under: putting the backdrop back on the carrier.
    local inst, cfg, anchor = bench{ configure = function(c)
        c.tooltip.barBorderStyle = "Ka0s Edge"
        c.tooltip.barBorderSize  = 4
    end }
    inst.mocks.__media.border["Ka0s Edge"] = "Interface\\Test\\Edge"
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    local b = tooltipBars(inst)[1]
    assertTrue(b ~= nil, "no bar was drawn")
    assertTrue(b.__backdrop ~= nil, "the border did not reach the bar")
    assertEqual(b.__backdrop.edgeSize, 4, "the thickness slider does not reach the art")
    assertNil(b.__parent.__backdrop, "the carrier kept a backdrop nobody can see")
end)

test("A bar sits UNDER the tooltip's text, not over it", function()
    -- GameTooltip draws its line FontStrings in ARTWORK, and a frame at the
    -- tooltip's own level interleaves its draw layers with the tooltip's. So the
    -- fill goes at the BOTTOM of the stack: any higher and a full-width bar paints
    -- over the very spell name it is behind.
    --
    -- BACKGROUND rather than BORDER, and the sublevel is the point. BORDER is
    -- where a BACKDROP draws its edge, so a fill sitting there was level with the
    -- border that is supposed to outline it -- which is why "Bar border" appeared
    -- to do nothing at any thickness. Sublevel 1 keeps it above the bar's own
    -- backdrop texture at sublevel 0.
    -- red under: leaving the fill on the StatusBar's default layer, or putting it
    -- back on BORDER where the outline lives.
    local inst, cfg, anchor = bench()
    inst.NS.Tooltip:CellTooltip(row{ classFilename = "MAGE" }, "DamageDone", anchor, cfg)

    local b = tooltipBars(inst)[1]
    assertTrue(b ~= nil, "no bar was drawn")
    assertEqual(b.__level, inst.mocks.GameTooltip:GetFrameLevel(),
        "a bar above the tooltip's level cannot interleave with its text")
    assertEqual(b.__parent.__level, inst.mocks.GameTooltip:GetFrameLevel(),
        "the carrier must share the level too, or it lifts the bar with it")

    local fill = b:GetStatusBarTexture()
    assertTrue(fill ~= nil, "a StatusBar with no texture draws nothing at all")
    assertEqual(fill.__drawLayer and fill.__drawLayer[1], "BACKGROUND",
        "the fill must draw below the tooltip's ARTWORK text")
    assertEqual(fill.__drawLayer and fill.__drawLayer[2], 1,
        "the fill must still sit above the bar's own backdrop")
end)

test("Bars come down when GameTooltip closes, whoever closed it", function()
    -- GameTooltip is SHARED and RECYCLED, and hiding it does not un-Show the
    -- frames parented to it. A bar left Shown reappears the instant a unit or an
    -- item opens GameTooltip, re-anchored onto THAT tooltip's lines — which is how
    -- this addon put class-colored bars through the middle of a player's unit
    -- tooltip. The only signal that catches every route out is the tooltip's own
    -- OnHide.
    -- red under: dropping the HookScript("OnHide", releaseBars) install.
    local inst, cfg, anchor = bench()
    inst.NS.Tooltip:CellTooltip(row{ classFilename = "MAGE" }, "DamageDone", anchor, cfg)
    assertTrue(#tooltipBars(inst) > 0, "no bar was drawn")

    -- Somebody ELSE hides the tooltip. Nothing routes this through our module.
    inst.mocks.GameTooltip:Show()
    inst.mocks.GameTooltip:Hide()

    assertEqual(#tooltipBars(inst), 0, "a bar outlived the tooltip that owned it")
end)

-- ---------------------------------------------------------------------------
-- The percent slot
-- ---------------------------------------------------------------------------

--- Every share slot the tooltip filled in, as one blob.
local function shareText(inst)
    local out = {}
    for _, carrier in ipairs(spellLines(inst)) do
        out[#out + 1] = tostring(carrier.share.__text or "")
    end
    return table.concat(out, "\n")
end

test("A spell line carries its SHARE of the player's total beside the amount", function()
    -- The amount alone answers "how much"; the share answers "how much of what I
    -- did", which is the question a breakdown exists for. The denominator is the
    -- source's own total for this column, not the column max.
    -- red under: dropping the sourceTotal argument, or passing maxAmount instead.
    local inst, cfg, anchor = bench()
    inst.NS.Tooltip:CellTooltip(row{ classFilename = "MAGE" }, "DamageDone", anchor, cfg)

    -- The fixture totals 600, and its largest spell is 300 — exactly half.
    assertTrue(shareText(inst):find("50.0%%") ~= nil,
        "the top spell's share of a 600 total is not on the line")
    -- 100/600 rounds to 16.7, which no other reading of the numbers produces:
    -- against maxAmount (300) the same spell would read 33.3%.
    assertTrue(shareText(inst):find("16.7%%") ~= nil,
        "the share is being taken against the wrong denominator")
end)

test("The percent slot GOES QUIET mid-pull rather than approximating", function()
    -- A share is a DIVISION, so it is the one slot on a spell line that cannot
    -- survive the Combat restriction. modules/Format.lua answers an empty string
    -- when the operands may not be divided, and an empty answer must append
    -- NOTHING — never a zero, never a guess. The amount is untouched either way,
    -- so a mid-pull tooltip loses the share and keeps the figure.
    -- red under: reading Format.Percent's "" as a number, or dividing unguarded.
    local inst, cfg, anchor = bench{ restricted = true }
    inst.mocks.setSecretValues(true)

    local ok = pcall(function()
        inst.NS.Tooltip:CellTooltip(row{ classFilename = "MAGE" }, "DamageDone", anchor, cfg)
    end)
    assertTrue(ok, "the tooltip divided a secret to get a percentage")

    assertFalse(shareText(inst):find("%%") ~= nil,
        "a percentage was rendered from values we may not divide")
    -- And the tooltip still drew its spell lines: the share went, the data did not.
    assertTrue(#inst.mocks.GameTooltip.__lines > 3, "the breakdown vanished with the shares")
end)

-- ---------------------------------------------------------------------------
-- The two number slots
-- ---------------------------------------------------------------------------

test("The amount and the share sit in FIXED right-aligned slots", function()
    -- AddDoubleLine right-aligns ONE string, so "5.7M 36.5%" and "398.9K 2.1%"
    -- line up at their right edge and nowhere else — the share column zig-zags
    -- behind amounts of different widths. Two right-justified FontStrings at fixed
    -- widths are the only way to get two columns out of one line; the game font is
    -- proportional, so padding with spaces cannot substitute.
    -- red under: putting either number back in the tooltip's own right column.
    local inst, cfg, anchor = bench()
    inst.NS.Tooltip:CellTooltip(row{ classFilename = "MAGE" }, "DamageDone", anchor, cfg)

    local carriers = spellLines(inst)
    assertEqual(#carriers, 3, "the breakdown did not draw its three lines")

    for _, carrier in ipairs(carriers) do
        assertEqual(carrier.amount.__justifyH, "RIGHT", "the amount slot is not right-aligned")
        assertEqual(carrier.share.__justifyH, "RIGHT", "the share slot is not right-aligned")
        assertTrue(carrier.amount.__w > 0, "the amount slot has no fixed width")
        assertTrue(carrier.share.__w > 0, "the share slot has no fixed width")
    end

    -- Same widths on every line, which is what makes them columns rather than
    -- two numbers that happen to be near each other.
    assertEqual(carriers[1].amount.__w, carriers[3].amount.__w,
        "the amount slot changes width between lines")
    assertEqual(carriers[1].share.__w, carriers[3].share.__w,
        "the share slot changes width between lines")

    -- And nothing is left in a SPELL line's own right column to fight them. The
    -- header line keeps its right side — that is the column's name, not a number.
    for index in pairs(tooltipLines(inst)) do
        local line = inst.mocks.GameTooltip.__lines[index]
        assertTrue(line ~= nil, "a carrier is anchored to a line that does not exist")
        assertTrue(line.right == nil or line.right == "",
            "a number is still being drawn in the tooltip's right column")
    end
end)

test("Both number slots are white by default, not two kinds of number", function()
    -- The amount used to be gold and the share white. They are one row's two
    -- figures, and colouring them differently made the line read as two.
    -- red under: reinstating either hardcoded colour.
    local inst, cfg, anchor = bench()
    inst.NS.Tooltip:CellTooltip(row{ classFilename = "MAGE" }, "DamageDone", anchor, cfg)

    local carrier = spellLines(inst)[1]
    for _, slot in ipairs({ "share", "amount" }) do
        local c = carrier[slot].__textColor
        assertEqual(c[1], 1, slot .. " is not white")
        assertEqual(c[2], 1, slot .. " is not white")
        assertEqual(c[3], 1, slot .. " is not white")
    end
end)

test("The tooltip text colour is configurable, and reaches every slot", function()
    -- Including the target label, which lives on the carrier rather than in the
    -- tooltip's own line and would otherwise keep the default silently.
    -- red under: colouring only the amount, or reading the colour once at
    -- widget-creation time rather than on every draw.
    local inst, cfg, anchor = bench{ configure = function(c)
        c.tooltip.textColor = { r = 1, g = 0, b = 0, a = 1 }
    end }
    inst.NS.Tooltip:CellTooltip(row{ classFilename = "MAGE" }, "DamageDone", anchor, cfg)

    local carrier = spellLines(inst)[1]
    for _, slot in ipairs({ "amount", "share", "label" }) do
        local c = carrier[slot].__textColor
        assertEqual(c[1], 1, slot .. " did not take the configured colour")
        assertEqual(c[2], 0, slot .. " did not take the configured colour")
    end
end)

test("The AMOUNT rides on the carrier, not on the bar", function()
    -- This is the inversion the carrier Frame exists to prevent: the amount is
    -- the INFORMATION, and hanging the number slots off the bar would tie them
    -- to whether the bar draws. That is a live risk even now that the bar
    -- survives a pull, because a bar still goes when a line has no max to scale
    -- against — and an empty tooltip is the exact opposite of the rule.
    -- red under: parenting the amount and share to the bar instead of the carrier.
    local inst, cfg, anchor = bench{ restricted = true }
    inst.mocks.setSecretValues(true)

    inst.NS.Tooltip:CellTooltip(row{ classFilename = "MAGE" }, "DamageDone", anchor, cfg)

    local carriers = spellLines(inst)
    assertEqual(#carriers, 3, "the spell lines went down with the restriction")
    for _, carrier in ipairs(carriers) do
        assertTrue(carrier.amount.__text ~= nil, "a spell line lost its amount")
        -- Asserted non-nil first, so the parent check below cannot pass by being
        -- vacuous on a mock that never recorded a parent at all.
        assertTrue(carrier.amount.__parent ~= nil, "the mock recorded no parent to check")
        assertTrue(carrier.amount.__parent ~= carrier.bar,
            "the amount is parented to the bar, so it dies whenever the bar does")
    end
end)

test("The tooltip is widened for the slots, and put back afterwards", function()
    -- GameTooltip sizes itself from its own text, and the slots are not its text —
    -- so without a minimum width it shrinks to the width of the spell names and
    -- the numbers sit on top of them. The minimum is a property of the SHARED
    -- tooltip, so leaving ours on it makes the next addon's item tooltip
    -- inexplicably wide: the same class of bug as a bar left Shown.
    -- red under: dropping either the applyMinimumWidth call or the reset.
    local inst, cfg, anchor = bench()
    inst.NS.Tooltip:CellTooltip(row{ classFilename = "MAGE" }, "DamageDone", anchor, cfg)

    assertTrue(inst.mocks.GameTooltip:GetMinimumWidth() > 0,
        "the tooltip was never widened for the number slots")

    inst.mocks.GameTooltip:Show()
    inst.mocks.GameTooltip:Hide()

    assertEqual(inst.mocks.GameTooltip:GetMinimumWidth(), 0,
        "our minimum width outlived our tooltip")
end)

-- ---------------------------------------------------------------------------
-- Anchoring and offsets
-- ---------------------------------------------------------------------------

test("Every anchor the schema offers resolves to a real GameTooltip token", function()
    -- The token is the FALLBACK now, not the placement: SetOwner is called with
    -- one so the tooltip always has a valid position, and placeTooltip lays the
    -- exact box over it. A missing token would leave a tooltip with nothing to
    -- fall back to if our own SetPoint raises.
    -- red under: dropping any entry from ANCHOR_TOKENS.
    local expected = {
        TOP         = "ANCHOR_TOP",
        BOTTOM      = "ANCHOR_BOTTOM",
        LEFT        = "ANCHOR_LEFT",
        RIGHT       = "ANCHOR_RIGHT",
        TOPLEFT     = "ANCHOR_TOPLEFT",
        TOPRIGHT    = "ANCHOR_TOPRIGHT",
        BOTTOMLEFT  = "ANCHOR_BOTTOMLEFT",
        BOTTOMRIGHT = "ANCHOR_BOTTOMRIGHT",
    }

    for value, token in pairs(expected) do
        local inst, cfg, anchor = bench{ configure = function(c) c.tooltip.anchor = value end }
        inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)
        assertEqual(inst.mocks.GameTooltip.__anchor, token,
            "anchor " .. value .. " did not reach the client")
    end
end)

test("Each anchor puts the tooltip in the box of a 3x3 around the cell", function()
    -- "Top left" is the box ABOVE AND TO THE LEFT of the cell, not the box above
    -- it aligned to its left edge -- so it grows away from the thing you are
    -- hovering rather than across it. Blizzard's tokens cannot say that: their
    -- TOPLEFT and TOPRIGHT are both directly above, and there is no token at all
    -- for the four diagonals.
    -- red under: going back to SetOwner's placement.
    local EXPECTED = {
        TOPLEFT     = { "BOTTOMRIGHT", "TOPLEFT" },
        TOP         = { "BOTTOM",      "TOP" },
        TOPRIGHT    = { "BOTTOMLEFT",  "TOPRIGHT" },
        LEFT        = { "RIGHT",       "LEFT" },
        RIGHT       = { "LEFT",        "RIGHT" },
        BOTTOMLEFT  = { "TOPRIGHT",    "BOTTOMLEFT" },
        BOTTOM      = { "TOP",         "BOTTOM" },
        BOTTOMRIGHT = { "TOPLEFT",     "BOTTOMRIGHT" },
    }

    for value, want in pairs(EXPECTED) do
        local inst, cfg, anchor = bench{ configure = function(c) c.tooltip.anchor = value end }
        inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

        local tip, relTo, rel = inst.mocks.GameTooltip:GetPoint(1)
        assertTrue(tip ~= nil, value .. ": the tooltip was never placed")
        assertEqual(tip, want[1], value .. ": the tooltip's own corner")
        assertEqual(rel, want[2], value .. ": the corner of the cell it is put against")
        assertTrue(relTo == anchor, value .. ": anchored to something other than the cell")
    end
end)

test("There is no \"At cursor\" anchor, and TOP is what shipped instead", function()
    -- It was the default and it is what every other tooltip in the game does,
    -- which is exactly the trouble: over a grid it lands wherever the pointer
    -- happens to be inside a cell, so the same hover puts the tooltip somewhere
    -- different every time and reads as jitter rather than as a choice. TOP is
    -- the deliberate version of the same thing.
    -- red under: putting the entry back without deciding what it means.
    local inst = T.load()
    local row = inst.NS.FindSchemaRow("window.tooltip.anchor")
    assertTrue(row ~= nil)
    assertEqual(row.default, "TOP")
    assertNil(row.values.CURSOR, "the dropdown still offers the cursor")
end)

test("The anchor dropdown offers nothing the token table cannot resolve", function()
    -- Two independent statements of one list is exactly what a test can check. A
    -- value offered by the dropdown with no token behind it does not error — it
    -- falls back to the cursor, which reads as "the setting does nothing".
    -- red under: adding a value to ANCHOR_VALUES without adding its token.
    local probe = T.load()
    local anchorRow
    for _, r in ipairs(probe.NS.Schema) do
        if r.path == "window.tooltip.anchor" then anchorRow = r end
    end
    assertTrue(anchorRow ~= nil, "the anchor row left the schema")

    for value in pairs(anchorRow.values) do
        local inst, cfg, frame = bench{ configure = function(c) c.tooltip.anchor = value end }
        inst.NS.Tooltip:CellTooltip(row(), "DamageDone", frame, cfg)
        local token = inst.mocks.GameTooltip.__anchor
        if value == "CURSOR" then
            assertEqual(token, "ANCHOR_CURSOR")
        else
            assertTrue(token ~= "ANCHOR_CURSOR",
                "anchor " .. value .. " silently fell back to the cursor")
        end
        assertTrue(anchorRow.values[value] ~= nil)
    end

    -- Sorting and values must agree, or the dropdown lists an option it cannot order.
    for _, key in ipairs(anchorRow.sorting) do
        assertTrue(anchorRow.values[key] ~= nil, "sorted anchor " .. key .. " has no label")
    end
    local sorted = 0
    for _ in pairs(anchorRow.values) do sorted = sorted + 1 end
    assertEqual(#anchorRow.sorting, sorted, "the sort order and the value list disagree")
end)

test("The x/y offset reaches SetOwner rather than a SetPoint of our own", function()
    -- The offsets go to the CLIENT, as SetOwner's third and fourth arguments, so
    -- the client still does the placing and still keeps the tooltip on screen.
    -- Nudging it ourselves would mean reading a point back off a frame that has
    -- held a secret value, which is rule R3 exactly.
    -- red under: dropping the offsets from the SetOwner call.
    local inst, cfg, anchor = bench{ configure = function(c)
        c.tooltip.offsetX, c.tooltip.offsetY = 25, -40
    end }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    assertEqual(inst.mocks.GameTooltip.__ownerX, 25, "the horizontal offset never arrived")
    assertEqual(inst.mocks.GameTooltip.__ownerY, -40, "the vertical offset never arrived")
end)

test("A junk offset off an old profile is clamped, never handed to the client", function()
    -- A string here raises inside Blizzard's own code, where the traceback names
    -- neither this addon nor the setting that caused it.
    -- red under: passing config.offsetX straight through.
    local inst, cfg, anchor = bench{ configure = function(c)
        c.tooltip.offsetX, c.tooltip.offsetY = "left a bit", 99999
    end }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    assertEqual(inst.mocks.GameTooltip.__ownerX, 0, "a non-number offset was not neutralized")
    assertEqual(inst.mocks.GameTooltip.__ownerY, 400, "an out-of-range offset was not clamped")
end)

-- ---------------------------------------------------------------------------
-- Line spacing
-- ---------------------------------------------------------------------------

test("Bar spacing is applied to the tooltip, and taken back off when it hides", function()
    -- Line spacing belongs to the SHARED GameTooltip, like the minimum width, and
    -- a value left on it silently respaces the next addon's item tooltip.
    -- red under: dropping either the SetCustomLineSpacing call or its reset.
    local inst, cfg, anchor = bench{ configure = function(c) c.tooltip.barSpacing = 5 end }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    assertEqual(inst.mocks.GameTooltip:GetCustomLineSpacing(), 5,
        "the configured spacing never reached the tooltip")

    inst.mocks.GameTooltip:Show()
    inst.mocks.GameTooltip:Hide()

    assertEqual(inst.mocks.GameTooltip:GetCustomLineSpacing(), 0,
        "our line spacing outlived our tooltip")
end)

-- ---------------------------------------------------------------------------
-- The font, and putting it back
-- ---------------------------------------------------------------------------

test("The configured font reaches both number slots and the spell name", function()
    -- The names are the bulk of the tooltip's text, so a font that reached only
    -- our own two slots would look half-applied — which is why this asserts the
    -- shared line FontString as well as the carrier's.
    -- red under: dropping the applyLineFont call.
    local inst, cfg, anchor = bench{ configure = function(c)
        c.tooltip.fontSize    = 17
        c.tooltip.fontOutline = "THICKOUTLINE"
    end }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    local lines = spellLines(inst)
    assertTrue(#lines > 0, "no spell lines were drawn")

    local _, size, flags = lines[1].amount:GetFont()
    assertEqual(size, 17, "the amount slot did not take the configured size")
    assertEqual(flags, "THICKOUTLINE", "the amount slot did not take the outline flag")

    local _, shareSize = lines[1].share:GetFont()
    assertEqual(shareSize, 17, "the share slot did not take the configured size")

    local left = inst.mocks["GameTooltipTextLeft4"]
    assertTrue(left ~= nil, "the first spell line has no left FontString")
    local _, lineSize = left:GetFont()
    assertEqual(lineSize, 17, "the spell NAME kept the game's tooltip font")
end)

test("NONE is an absent outline flag, not the literal string", function()
    -- WoW wants nil here. The string "NONE" is not a flag it knows, and the
    -- difference is invisible until a font renders wrong.
    -- red under: passing config.fontOutline through unconditionally.
    local inst, cfg, anchor = bench{ configure = function(c) c.tooltip.fontOutline = "NONE" end }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    local lines = spellLines(inst)
    local _, _, flags = lines[1].amount:GetFont()
    assertEqual(flags, nil, "\"NONE\" was passed to SetFont as a flag string")
end)

test("Every tooltip line we restyled is put back when the tooltip hides", function()
    -- THE ONE THAT MATTERS. GameTooltipTextLeft<N> is SHARED with every other
    -- addon and with every unit, item and quest hover in the game. A SetFont left
    -- on one is this addon silently restyling somebody else's tooltip until the
    -- next reload — the same class of bug as a bar left Shown, and less visible.
    -- red under: dropping restoreFonts from releaseLines.
    local inst, cfg, anchor = bench{ configure = function(c) c.tooltip.fontSize = 19 end }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    local left = inst.mocks["GameTooltipTextLeft4"]
    assertTrue(select(2, left:GetFont()) == 19, "the line never took our font to begin with")

    inst.mocks.GameTooltip:Show()
    inst.mocks.GameTooltip:Hide()

    assertEqual(left:GetFont(), nil, "our font outlived our tooltip on a SHARED line")
    assertEqual(left:GetFontObject(), inst.mocks.GameTooltipText,
        "the line was cleared but never put back on the game's own font object")
end)

-- ---------------------------------------------------------------------------
-- Bar texture and border
-- ---------------------------------------------------------------------------

test("The tooltip's own bar texture is used, not the grid's", function()
    -- These were one setting and are now two, deliberately: a 14px spell line and
    -- a 90px cell are different surfaces, and a texture that reads across one
    -- often does not across the other. Two DISTINCT files are registered so the
    -- assertion can tell which setting was read — with one file, or with none,
    -- both settings resolve to the same path and the test proves nothing.
    -- red under: reading window.bars.texture here again.
    local inst, cfg, anchor = bench{ configure = function(c)
        c.bars.texture       = "GridTexture"
        c.tooltip.barTexture = "TipTexture"
    end }
    local media = inst.mocks.__libs["LibSharedMedia-3.0"]
    media:Register("statusbar", "GridTexture", [[Interface\Grid]])
    media:Register("statusbar", "TipTexture",  [[Interface\Tip]])

    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    local lines = spellLines(inst)
    assertTrue(#lines > 0, "no spell lines were drawn")
    assertEqual(lines[1].bar.__barTexture, [[Interface\Tip]],
        "the tooltip bar took the GRID's texture instead of its own")
end)

test("Tooltip text takes the HOVERED player's class color when asked", function()
    -- A tooltip is about ONE player, which is what makes the question answerable
    -- here where the window header has to fall back to the local player's class
    -- instead. The bars have always worn this colour; the text can now too.
    -- red under: colouring the tooltip from NS.PlayerClassRGB, or ignoring the
    -- setting.
    local inst, cfg, anchorFrame = bench{ configure = function(c)
        c.tooltip.colorMode = "class"
        c.tooltip.textColor  = { r = 1, g = 1, b = 1, a = 1 }
    end }
    -- The mock ships every class the same colour, so one is given its own.
    inst.mocks.RAID_CLASS_COLORS.MAGE = { r = 0.41, g = 0.8, b = 0.94 }

    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchorFrame, cfg)

    local lines = spellLines(inst)
    assertTrue(#lines > 0, "no spell lines were drawn")
    assertEqual(lines[1].amount.__textColor[1], 0.41)
    assertEqual(lines[1].share.__textColor[3], 0.94,
        "both number slots, or one line carries two kinds of number")
end)

test("With the class colour off, the tooltip keeps its configured text colour", function()
    -- red under: the class colour applying whether or not it was asked for.
    local inst, cfg, anchorFrame = bench{ configure = function(c)
        c.tooltip.colorMode = "custom"
        c.tooltip.textColor  = { r = 0.2, g = 0.4, b = 0.6, a = 1 }
    end }
    inst.mocks.RAID_CLASS_COLORS.MAGE = { r = 0.41, g = 0.8, b = 0.94 }

    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchorFrame, cfg)
    local lines = spellLines(inst)
    assertEqual(lines[1].amount.__textColor[1], 0.2)
end)

test("Tooltip shadow reaches the line, and survives the post-Show re-font", function()
    -- `reapplyFonts` runs AFTER Show, because the show path re-fonts the
    -- tooltip's own lines. A shadow set only on the first pass would be put back
    -- without it -- the same trap the font size fell into.
    -- red under: recording the font in `fontedLines` without its shadow.
    local inst, cfg, anchorFrame = bench{ configure = function(c)
        c.tooltip.fontShadow = true
    end }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchorFrame, cfg)

    local lines = spellLines(inst)
    assertTrue(#lines > 0, "no spell lines were drawn")
    assertEqual(lines[1].amount.__shadow[1], 1)
    assertEqual(lines[1].amount.__shadow[2], -1)
end)

test("The tooltip puts a SHARED line's shadow back when it lets go", function()
    -- GameTooltip is Blizzard's and every addon in the game draws on it. A
    -- SetFont left behind is a leak this file has always cleaned up; a shadow is
    -- the same leak, and a font OBJECT does not carry one -- so restoring the
    -- face is not enough to take the shadow off.
    -- red under: restoreFonts putting back SetFontObject alone.
    local inst, cfg, anchorFrame = bench{ configure = function(c)
        c.tooltip.fontShadow = true
    end }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchorFrame, cfg)

    -- The shared line widgets are reachable exactly the way an addon reaches
    -- them in the client: by global name. Collected BEFORE the hide, and the
    -- collection is asserted non-empty -- a loop over nothing would pass forever.
    local shared = {}
    for index = 1, inst.mocks.GameTooltip:NumLines() do
        local fs = inst.mocks["GameTooltipTextLeft" .. index]
        if type(fs) == "table" and fs.__shadow and fs.__shadow[1] ~= 0 then
            shared[#shared + 1] = fs
        end
    end
    assertTrue(#shared > 0, "no shared line carried our shadow -- nothing to restore")

    inst.NS.Tooltip:Hide()

    for _, fs in ipairs(shared) do
        assertEqual(fs.__shadow[1], 0,
            "our shadow was left on a line the next addon will draw on")
        assertEqual(fs.__shadow[2], 0)
    end
end)

test("A bar border is applied when asked and cleared off the POOLED line when not", function()
    -- The carrier drawing line 4 of this hover drew line 4 of the last one, so a
    -- player who turns the border off between two hovers keeps it unless the
    -- clear is explicit.
    -- red under: skipping the SetBackdrop(nil) branch.
    local inst, cfg, anchor = bench{ configure = function(c)
        c.tooltip.barBorderStyle = "None"
        c.tooltip.barBorderSize  = 1
    end }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    local lines = spellLines(inst)
    assertTrue(#lines > 0, "no spell lines were drawn")
    assertEqual(lines[1].__backdrop, nil, "\"None\" still drew a border")
end)

test("Border size zero drops the border FILE with it", function()
    -- A zero edgeSize with a texture still present is the combination WoW draws
    -- as a hard 1px line, which is the setting doing the opposite of what it says.
    -- red under: keeping edgeFile when borderSize is 0.
    local inst, cfg, anchor = bench{ configure = function(c)
        c.tooltip.barBorderStyle = "Blizzard Tooltip"
        c.tooltip.barBorderSize  = 0
    end }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    local lines = spellLines(inst)
    assertEqual(lines[1].__backdrop, nil, "a zero-thickness border still carried a file")
end)

-- ---------------------------------------------------------------------------
-- maxSpells = 0
-- ---------------------------------------------------------------------------

test("maxSpells 0 lists every spell the breakdown collected", function()
    -- 0 is the same "no cap" spelling rows.maxRows and text.maxNameLength use.
    -- red under: the old `cap < 1 then return 10` clamp, which turns 0 into 10.
    local spells = {}
    for i = 1, 18 do spells[i] = { spellID = 100 + i, totalAmount = i * 1000 } end

    local inst, cfg, anchor = bench{
        detail = { combatSpells = spells, maxAmount = 18000, totalAmount = 171000 },
        configure = function(c) c.tooltip.maxSpells = 0 end,
    }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    assertEqual(#spellLines(inst), 18, "a 0 cap did not list every spell")
end)

test("maxSpells 0 is bounded by the collector, and says so", function()
    -- "Every spell" is honest only up to COLLECT_LIMIT, because that is all
    -- collectSpells ever pulls. What must not happen is a silent truncation: the
    -- "and N more" line counts the remainder with SafeCount and keeps saying so.
    -- red under: returning math.huge from spellLineCap, which drops the more-line.
    local spells = {}
    for i = 1, 80 do spells[i] = { spellID = 100 + i, totalAmount = i * 1000 } end

    local inst, cfg, anchor = bench{
        detail = { combatSpells = spells, maxAmount = 80000, totalAmount = 1 },
        configure = function(c) c.tooltip.maxSpells = 0 end,
    }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    assertEqual(#spellLines(inst), 64, "the collector's own ceiling was not respected")

    local sawMore = false
    for _, line in ipairs(inst.mocks.GameTooltip.__lines) do
        if type(line.text) == "string" and line.text:match("^and %d+ more$") then sawMore = true end
    end
    assertTrue(sawMore, "80 spells were cut to 64 with nothing said about it")
end)

test("A negative or non-numeric cap still falls back to the shipped default", function()
    -- 0 gained a meaning; junk did not.
    -- red under: treating every non-positive number as "no cap".
    local spells = {}
    for i = 1, 18 do spells[i] = { spellID = 100 + i, totalAmount = i * 1000 } end
    local detail = { combatSpells = spells, maxAmount = 18000, totalAmount = 171000 }

    for _, junk in ipairs({ -4, "ten" }) do
        local inst, cfg, anchor = bench{
            detail = detail,
            configure = function(c) c.tooltip.maxSpells = junk end,
        }
        inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)
        assertEqual(#spellLines(inst), 10,
            "a junk cap (" .. tostring(junk) .. ") did not fall back to 10")
    end
end)

test("The font survives a UI skin that re-fonts every line on show", function()
    -- MEASURED ON A LIVE CLIENT, not imagined. The in-game probe reported the
    -- SetFont taking (asked 10/OUTLINE, read back 10/OUTLINE) and the SAME
    -- FontString reading 11/no-flags after Show — the signature of a tooltip skin
    -- hooking OnShow and re-applying its own face at its own size. Setting the
    -- font before Show is therefore not enough, however correct it looks.
    --
    -- The skin is modelled with a real OnShow hook so the ORDERING is the real
    -- one: Show fires the hook, the hook restyles, and our second pass runs after
    -- Show returns. A test that just called SetFont twice would prove nothing.
    -- red under: applying the font only inside drawLine.
    local inst, cfg, anchor = bench{ configure = function(c)
        c.tooltip.fontSize    = 17
        c.tooltip.fontOutline = "THICKOUTLINE"
    end }

    local mocks = inst.mocks
    -- Hidden first, deliberately. The mock fires OnShow only on a hide->show
    -- TRANSITION, and a GameTooltip left shown by an earlier case makes the hook
    -- below never run — which made this case pass against the very code it was
    -- written to catch. `restyled` is asserted at the end for the same reason: a
    -- skin that never ran proves nothing about surviving one.
    mocks.GameTooltip:Hide()
    local restyled = 0
    mocks.GameTooltip:HookScript("OnShow", function()
        restyled = restyled + 1
        local i = 1
        while mocks["GameTooltipTextLeft" .. i] do
            local fs = mocks["GameTooltipTextLeft" .. i]
            local path = fs:GetFont()
            if path then fs:SetFont(path, 11, "") end
            i = i + 1
        end
    end)

    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    assertTrue(restyled > 0, "the simulated skin never ran, so this proves nothing")
    local left = mocks["GameTooltipTextLeft4"]
    assertTrue(left ~= nil, "the first spell line has no left FontString")
    local _, size, flags = left:GetFont()
    assertEqual(size, 17, "the skin's re-font on Show won — our pass runs too early")
    assertEqual(flags, "THICKOUTLINE", "the outline flag was lost to the skin")
end)

test("The post-layout pass still restores every line it touched", function()
    -- Applying the font twice must not leave twice as much to clean up. The
    -- lines are SHARED with every other addon, so a second pass that escaped the
    -- restore bookkeeping would be the original leak with an extra step.
    -- red under: reapplyFonts writing to lines it never recorded.
    local inst, cfg, anchor = bench{ configure = function(c) c.tooltip.fontSize = 19 end }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    local left = inst.mocks["GameTooltipTextLeft4"]
    assertEqual(select(2, left:GetFont()), 19, "the line never took our font")

    inst.mocks.GameTooltip:Show()
    inst.mocks.GameTooltip:Hide()

    assertEqual(left:GetFont(), nil, "our font outlived our tooltip on a SHARED line")
end)

test("A target's name is drawn on our own carrier, not on the tooltip's line", function()
    -- A target has no icon — a unit is not a spell — but its name still has to
    -- start where a spell NAME starts rather than where a spell ICON starts, or
    -- the two sections read as two unrelated tables. There is no way to indent
    -- GameTooltip's own line text (a `|T…|t` spacer needs a transparent texture
    -- to point at, and padding with spaces is font-dependent), so the name goes
    -- on the carrier's own label slot, which is already anchored past the icon.
    -- red under: passing the name to AddLine and leaving the label empty.
    local inst, cfg, anchor = bench{ configure = function(c)
        c.tooltip.showTargets = true
        c.tooltip.maxTargets  = 2
    end }

    local mocks = inst.mocks
    local ENEMY_STAT = mocks.Enum.DamageMeterType.EnemyDamageTaken
    local sources = {}
    for i, enemy in ipairs({ "Primal Thundercloud", "Storm Warrior" }) do
        local guid = string.format("Creature-0-0000-0-0-%04d", i)
        sources[i] = { sourceGUID = guid, guid = guid, sourceCreatureID = 7000 + i,
                       name = enemy, totalAmount = 1 }
        local detail = { combatSpells = { { spellID = i, totalAmount = 900 - i * 100,
            combatSpellDetails = { unitName = "Alpha" } } } }
        mocks.setSourceDetail(CURRENT, ENEMY_STAT, guid, detail)
        mocks.setSourceDetail(CURRENT, ENEMY_STAT, "creature:" .. (7000 + i), detail)
    end
    mocks.setSession(CURRENT, ENEMY_STAT,
        { combatSources = sources, maxAmount = 1, totalAmount = 1 })

    inst.NS.Tooltip:CellTooltip(row{ name = "Alpha" }, "DamageDone", anchor, cfg)

    local labels = {}
    for _, carrier in ipairs(spellLines(inst)) do
        local text = carrier.label and carrier.label:GetText()
        if text and text ~= "" then labels[#labels + 1] = text end
    end

    assertEqual(#labels, 2, "the target names never reached a carrier label")
    assertEqual(labels[1], "Primal Thundercloud")

    -- And the tooltip's own line for a target is blank, so nothing is drawn
    -- twice at two different indents.
    local sawNameInLine = false
    for _, line in ipairs(inst.mocks.GameTooltip.__lines) do
        if type(line.text) == "string" and line.text:find("Primal Thundercloud") then
            sawNameInLine = true
        end
    end
    assertFalse(sawNameInLine, "the name was also written into the tooltip's own line")
end)

test("The gap above a section is half the text size, not a whole blank line", function()
    -- A blank AddLine is a WHOLE line of the tooltip's font, which read as a
    -- paragraph gap above "Spell breakdown" and again above "Targets". There is
    -- no half-line in GameTooltip, but a line's HEIGHT follows its font — so the
    -- spacer takes the same face at half the size.
    -- red under: a bare AddLine(" ") before the section header.
    local inst, cfg, anchor = bench{ configure = function(c) c.tooltip.fontSize = 20 end }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    -- Line 2 is the gap: line 1 is the "<player> / <stat>" header, line 3 is
    -- "Spell breakdown", and the spell lines follow.
    local gap = inst.mocks["GameTooltipTextLeft2"]
    assertTrue(gap ~= nil, "there is no line where the section gap should be")
    assertEqual(select(2, gap:GetFont()), 10, "the gap is not half the configured size")

    -- The header beneath it keeps the full size, or the section title shrinks too.
    local spell = inst.mocks["GameTooltipTextLeft4"]
    assertEqual(select(2, spell:GetFont()), 20, "the spell line was shrunk along with the gap")
end)

test("The half-size gap survives the post-layout pass", function()
    -- The re-apply after Show walks every line it touched. Remembering ONE font
    -- for the hover would have it stamp full size back over the gap and quietly
    -- restore the blank line this just halved.
    -- red under: reapplyFonts using a single remembered font.
    local inst, cfg, anchor = bench{ configure = function(c) c.tooltip.fontSize = 20 end }
    local mocks = inst.mocks

    mocks.GameTooltip:Hide()
    mocks.GameTooltip:HookScript("OnShow", function()
        local i = 1
        while mocks["GameTooltipTextLeft" .. i] do
            local fs = mocks["GameTooltipTextLeft" .. i]
            local path = fs:GetFont()
            if path then fs:SetFont(path, 11, "") end
            i = i + 1
        end
    end)

    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)
    assertEqual(select(2, mocks["GameTooltipTextLeft2"]:GetFont()), 10,
        "the gap was restored to full size by the re-apply")
end)

test("The gap is restored with every other line it was applied alongside", function()
    -- A shrunken font left on a SHARED line is the same leak as any other, and
    -- it would land on whatever the next addon puts there.
    -- red under: applying the gap's font outside the restore bookkeeping.
    local inst, cfg, anchor = bench{ configure = function(c) c.tooltip.fontSize = 20 end }
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    local gap = inst.mocks["GameTooltipTextLeft2"]
    assertEqual(select(2, gap:GetFont()), 10, "the gap never took the half size")

    inst.mocks.GameTooltip:Show()
    inst.mocks.GameTooltip:Hide()
    assertEqual(gap:GetFont(), nil, "a shrunken font outlived our tooltip on a shared line")
end)

-- ---------------------------------------------------------------------------
-- The minimum width is COMPUTED, never measured
-- ---------------------------------------------------------------------------

test("The tooltip is widened without measuring anything inside GameTooltip", function()
    -- THE BUG THIS PINS. The width used to be read off GameTooltip's own line
    -- FontStrings. `GetStringWidth` inside a shared Blizzard frame answers a
    -- SECRET number to tainted code — even when every value on the line is
    -- plainly readable, because it is the FRAME that is out of bounds rather
    -- than the values — so `w > widest` raised and took every cell tooltip with
    -- it. The harness models that now (wow_mock marks GameTooltip tainted), so
    -- reintroducing any measurement raises here rather than only in game.
    -- red under: any GetStringWidth call on a widget inside GameTooltip.
    local inst, cfg, anchor = bench()
    inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

    assertTrue(inst.mocks.GameTooltip:GetMinimumWidth() > 0,
        "the tooltip was not widened for the number slots at all")
end)

test("The width follows the font size, because it is computed", function()
    -- Proves it is derived from config rather than from the widget: a bigger
    -- font on the same spells must ask for a wider tooltip.
    -- red under: a flat pixel constant, which would fit the small font and clip
    -- the large one.
    local function widthAt(size)
        local inst, cfg, anchor = bench{ configure = function(c) c.tooltip.fontSize = size end }
        inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)
        return inst.mocks.GameTooltip:GetMinimumWidth()
    end

    assertTrue(widthAt(20) > widthAt(8),
        "the minimum width ignored the configured font size")
end)

test("A name that cannot be read does not change the width, because none is read", function()
    -- The captions in a spell breakdown ARE secret in combat: C_DamageMeter
    -- hands out a secret spellID, so the name resolved from it is secret too. It
    -- renders — SetText takes a secret happily — but it cannot be measured, and
    -- an earlier version that tried left the tooltip un-widened and the numbers
    -- sitting on top of the names. Nothing here reads a caption at all now, so a
    -- secret one is simply not an event.
    -- red under: any reintroduction of caption measurement.
    local inst, cfg, anchor = bench()
    local ok, err = pcall(function()
        inst.NS.Tooltip:CellTooltip(
            { guid = "Player-1-0000000A", name = inst.mocks.secret("Alpha"), values = {} },
            "DamageDone", anchor, cfg)
    end)
    assertTrue(ok, "a secret name raised inside the width computation: " .. tostring(err))
end)

test("The name's room is a FIXED span, not the length of the names on screen", function()
    -- THE BUG THIS PINS, and it took a live client to see. Two versions sized
    -- the name span from the names themselves — first by reading GameTooltip's
    -- own FontStrings, then by measuring the captions on a ruler of our own —
    -- and both collapsed to zero width in combat, because every caption is
    -- secret there and a refused name widens nothing. The tooltip was never
    -- widened at all and the amounts drew straight through the names.
    --
    -- So the span is a RESERVATION: NAME_COLUMN_CHARS characters at the
    -- configured font, identical whatever the names are. Two different sets of
    -- spells must therefore ask for exactly the same width.
    -- red under: any width that varies with the captions.
    local SIZE = 10
    local function widthFor(spells)
        local inst, cfg, anchor = bench{
            detail = { combatSpells = spells, maxAmount = 655000, totalAmount = 655000 },
            configure = function(c) c.tooltip.fontSize = SIZE end,
        }
        inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)
        return inst.mocks.GameTooltip:GetMinimumWidth()
    end

    local short = widthFor{ { spellID = 1, totalAmount = 655000 } }
    local long  = widthFor{ { spellID = 1234567, totalAmount = 655000 },
                            { spellID = 7654321, totalAmount = 100 } }
    assertEqual(short, long,
        "the width moved with the spell names, so it will collapse in combat")

    -- And it is the reservation, exactly: 25 'n' on the mock's ruler (0.5px per
    -- character per point), plus the slots. Asserting the figure catches a
    -- silent fall back to the character estimate, which uses 0.55.
    local nameSpan = 25 * SIZE * 0.5
    local share    = math.max(#"100.0%" * SIZE * 0.5 + 3, 44)
    assertEqual(short, nameSpan + 10 + 66 + 6 + share + 20,
        "the reserved span is not 25 characters at the configured font")
end)

test("The share slot fits a full 100.0%, at any configured font size", function()
    -- WHAT WENT WRONG. The slot was a flat 36px, sized for "xx.x%" on the
    -- reasoning that a share cannot exceed 100% and so cannot get wider. But
    -- Format.Percent renders "%.1f%%", so a capped row is "100.0%" — six glyphs,
    -- not five — and it drew as "100...." on screen. The font size is the
    -- player's to choose besides, so no pixel constant can be the answer: the
    -- slot is measured per font, with the old constant kept only as a floor.
    -- red under: a fixed share slot, at the default size or at a large one.
    for _, size in ipairs({ 8, 10, 16, 24 }) do
        local inst, cfg, anchor = bench{ configure = function(c) c.tooltip.fontSize = size end }
        inst.NS.Tooltip:CellTooltip(row(), "DamageDone", anchor, cfg)

        local carriers = spellLines(inst)
        assertTrue(#carriers > 0, "the breakdown drew no lines to measure")

        -- The mock's ruler is 0.5px per character per point.
        local needed = #"100.0%" * size * 0.5
        assertTrue(carriers[1].share.__w >= needed, string.format(
            "the share slot is %s at font size %d, which clips 100.0%% at %s",
            tostring(carriers[1].share.__w), size, tostring(needed)))
    end
end)


-- ---------------------------------------------------------------------------
-- The death-event tooltip (issue #1)
-- ---------------------------------------------------------------------------
--
-- Hovering a death row shows what killed that player: one line per incoming
-- event, oldest first, so the killing blow is the last thing read. Icon and
-- caption on the tooltip's own line; damage and HP percentage in the carrier's
-- two slots; the bar behind them is HP REMAINING, not damage.
--
-- The caption is the risky part. It joins a spell name and an attacker name,
-- both resolved off ids that the client may hand back secret, and this file has
-- never concatenated anything that could be one.

--- Two events, newest first, as the client returns them.
local function recapEvents(opts)
    opts = opts or {}
    return {
        { spellId = 264206, spellName = opts.lastName or "Volley",
          sourceName = opts.lastSource, hideCaster = opts.hideCaster,
          amount = 787300, overkill = 138100, currentHP = 100000,
          event = "SPELL_DAMAGE", timestamp = 1000.0 },
        { spellId = 1301253, spellName = "Gust", sourceName = "Merektha",
          amount = 36900, currentHP = 700000,
          event = "SPELL_DAMAGE", timestamp = 954.6 },
    }
end

--- A drill-down death row plus a client that answers its recap.
local function deathBench(opts)
    opts = opts or {}
    local inst, cfg, anchor = bench()
    inst.mocks.setDeathRecap({
        HasRecapEvents    = function() return true end,
        GetRecapEvents    = function() return opts.events or recapEvents(opts) end,
        GetRecapMaxHealth = function() return opts.maxHealth or 738800 end,
    })
    local row = {
        guid = "death:29", recapID = 29, isDeath = true, name = "Death 3",
        deathClock = "13:01:06",
        classFilename = "PALADIN", isDrillDown = true,
        values = { Deaths = { total = 1, maxAmount = 1, displayText = "13:01:06" } },
        maxAmount = 1,
    }
    return inst, cfg, anchor, row
end

--- Every death line's four slots, joined, so a case can assert on content
--- without caring which column it landed in.
---
--- The tooltip's own line holds ONLY the icon now — time, spell, caster and the
--- two numbers are all carrier slots — so a case that reads GameTooltipTextLeft
--- for a spell name is reading the wrong widget.
local function slotTexts(inst)
    local out = {}
    for _, line in ipairs(spellLines(inst)) do
        out[#out + 1] = table.concat({
            line.time:GetText() or "", line.label:GetText() or "",
            line.caster:GetText() or "", line.amount:GetText() or "",
            line.share:GetText() or "",
        }, " ")
    end
    return table.concat(out, "\n")
end

--- Every tooltip line's text, in order.
local function lineTexts(inst)
    local out, i = {}, 1
    while inst.mocks["GameTooltipTextLeft" .. i] do
        local fs = inst.mocks["GameTooltipTextLeft" .. i]
        if not fs:IsShown() then break end
        out[i] = fs:GetText()
        i = i + 1
    end
    return out
end

test("Tooltip: hovering a death row lists its events, OLDEST first", function()
    -- The killing blow is the last line read, which is the order the whole
    -- surface is meant to be read in. The client returns them newest first.
    -- red under: rendering the array as it arrives.
    local inst, cfg, anchor, row = deathBench()
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)

    local texts = slotTexts(inst)
    local gust, volley = texts:find("Gust", 1, true), texts:find("Volley", 1, true)
    assertTrue(gust ~= nil and volley ~= nil, "both events must be listed")
    assertTrue(gust < volley, "the killing blow must be last")
end)

test("Tooltip: a death row never reaches the client's spell tooltip", function()
    -- SetSpellByID replaces the tooltip's whole content, so a death row that
    -- happened to carry a spellID would silently render a spell page instead of
    -- the event list.
    -- red under: the death branch sitting after the spellID path.
    local inst, cfg, anchor, row = deathBench()
    row.spellID = 264206
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)
    assertTrue(#spellLines(inst) > 0, "the event carriers were never drawn")
end)

test("Tooltip: each event line shows the time before death and the attacker", function()
    local inst, cfg, anchor, row = deathBench{ lastSource = "Merektha" }
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)

    local texts = slotTexts(inst)
    assertTrue(texts:find("-45.4s", 1, true) ~= nil,
        "the first event is 45.4s before the killing blow")
    assertTrue(texts:find("Merektha", 1, true) ~= nil, "the attacker was dropped")
end)

test("Tooltip: an event with no attacker renders without the clause", function()
    -- `hideCaster` is true on a real sample and sourceName is simply absent. A
    -- caption reading "Volley ()" is worse than one reading "Volley".
    -- red under: formatting the attacker unconditionally.
    local inst, cfg, anchor, row = deathBench{ hideCaster = true }
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)
    assertTrue(slotTexts(inst):find("()", 1, true) == nil,
        "an empty attacker clause was rendered")
end)

test("Tooltip: the bar behind an event is HP REMAINING, handed over raw", function()
    -- The percentage is a division and dividing a secret is what rule R1
    -- forbids. Passing currentHP and maxHealth to the widget lets the engine
    -- divide, which core/Secrets.lua puts on the MAY list.
    -- red under: computing currentHP / maxHealth in Lua.
    local inst, cfg, anchor, row = deathBench()
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)

    local first = spellLines(inst)[1]
    local mn, mx = first.bar:GetMinMaxValues()
    assertEqual(mn, 0)
    assertEqual(mx, 738800, "the max must be the recap's own max health")
    assertEqual(first.bar:GetValue(), 700000, "the value must be HP at that event")
end)

test("Tooltip: the killing blow is the LAST line, and carries no overkill", function()
    -- Overkill was dropped from this surface on purpose — it is the part of a
    -- killing blow that exceeded health the player no longer had, it appears on
    -- one line in ten, and it collided with the HP percentage. What still has to
    -- hold is that the fatal hit reads last.
    local inst, cfg, anchor, row = deathBench()
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)

    local lines = spellLines(inst)
    assertEqual(lines[#lines].label:GetText(), "Volley", "the killing blow must be last")
    assertTrue(slotTexts(inst):lower():find("overkill", 1, true) == nil)
end)

test("Tooltip: a secret spell name never meets concatenation", function()
    -- The whole reason the caption goes through one string.format. Under the
    -- simulated secret the mock traps `..`, so a join raises here rather than
    -- mid-pull in front of a player.
    -- red under: `caption .. " (" .. sourceName .. ")"`.
    local inst, cfg, anchor, row = deathBench{
        lastName = nil, lastSource = nil,
    }
    inst.mocks.setDeathRecap({
        HasRecapEvents    = function() return true end,
        GetRecapEvents    = function()
            return {
                { spellId = 264206, spellName = inst.mocks.secret("Volley"),
                  sourceName = inst.mocks.secret("Merektha"),
                  amount = inst.mocks.secret(787300),
                  currentHP = inst.mocks.secret(100000),
                  timestamp = inst.mocks.secret(1000.0) },
            }
        end,
        GetRecapMaxHealth = function() return inst.mocks.secret(738800) end,
    })
    inst.mocks.setSecretsAccessible(false)

    local ok, err = pcall(function()
        inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)
    end)
    assertTrue(ok, "the death tooltip raised on a secret: " .. tostring(err))
end)

test("Tooltip: with the values secret the bar still draws and the share does not lie", function()
    -- A percentage that cannot be computed is rendered as nothing, never as 0%.
    -- The bar is unaffected, because the widget divides.
    local inst, cfg, anchor, row = deathBench()
    inst.mocks.setDeathRecap({
        HasRecapEvents    = function() return true end,
        GetRecapEvents    = function()
            return { { spellId = 264206, spellName = "Volley",
                       amount = inst.mocks.secret(787300),
                       currentHP = inst.mocks.secret(100000),
                       timestamp = 1000.0 } }
        end,
        GetRecapMaxHealth = function() return inst.mocks.secret(738800) end,
    })
    inst.mocks.setSecretsAccessible(false)
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)

    local first = spellLines(inst)[1]
    assertTrue(first ~= nil, "no line was drawn at all")
    -- EXACTLY EMPTY, not merely "not 0%". The old assertion was true of the
    -- right answer, of a wrongly computed percentage, and of almost anything
    -- else — deleting the share argument outright kept the suite green.
    assertEqual(first.share:GetText(), "",
        "a refused division must render nothing, never a number")
    local mn, mx = first.bar:GetMinMaxValues()
    assertEqual(mn, 0)
    assertTrue(mx ~= nil and mx ~= 1, "the bar lost its max and fell back to 0..1")
end)

test("Tooltip: with the values plain the share slot carries the percentage", function()
    -- The other half of design §9's requirement, which nothing asserted at all.
    -- red under: passing "" as the share, which deletes the HP column and which
    -- the suite used to accept.
    local inst, cfg, anchor, row = deathBench{ maxHealth = 1000 }
    inst.mocks.setDeathRecap({
        HasRecapEvents    = function() return true end,
        GetRecapEvents    = function()
            return { { spellId = 264206, spellName = "Volley", amount = 250,
                       currentHP = 500, timestamp = 1000.0 } }
        end,
        GetRecapMaxHealth = function() return 1000 end,
    })
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)

    local share = spellLines(inst)[1].share:GetText()
    assertTrue(share:find("50", 1, true) ~= nil,
        "500 of 1000 must render as 50%, got " .. tostring(share))
end)

test("Tooltip: a death whose recap has gone says so instead of drawing nothing", function()
    local inst, cfg, anchor, row = deathBench()
    inst.mocks.setDeathRecap({ HasRecapEvents = function() return false end })
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)

    local texts = table.concat(lineTexts(inst), "\n")
    assertTrue(texts:find("recap", 1, true) ~= nil, "an empty tooltip reads as a bug")
end)

test("Tooltip: a death with no recap id says so rather than showing a name", function()
    -- It fell through to the one-line displayName path, which on a death row
    -- renders "Death 2" and nothing else — indistinguishable from a tooltip that
    -- failed to build.
    -- red under: keying the death branch on recapID instead of on the row kind.
    local inst, cfg, anchor = deathBench()
    local row = {
        guid = "death:none:2", isDeath = true, name = "Death 2",
        classFilename = "PALADIN", isDrillDown = true,
        values = { Deaths = { total = 1, maxAmount = 1, displayText = "\226\128\148" } },
    }
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)

    local texts = table.concat(lineTexts(inst), "\n")
    assertTrue(texts:find("recap", 1, true) ~= nil,
        "a death row with no id must explain itself")
end)

test("Tooltip: a death tooltip has a HEADER, so no carrier ever lands on line 1", function()
    -- FOUND BY REVIEW, and it leaks out of this addon entirely. drawLine calls
    -- applyLineFont on the tooltip line it sits behind and records it, and
    -- restoreFonts puts SetFontObject(GameTooltipText) back on teardown. On a
    -- live client GameTooltipTextLeft1 inherits GameTooltipHeaderText, not
    -- GameTooltipText — so a carrier on line 1 means every GameTooltip in the
    -- GAME renders its title in the small body font until /reload.
    --
    -- Every other caller puts a header on line 1 and never hands index 1 to
    -- drawLine, which is exactly what this file's own releaseLines comment
    -- claims: "a spell line is never line 1".
    -- red under: addDeathBreakdown adding no title line.
    local inst, cfg, anchor, row = deathBench()
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)

    local byIndex = tooltipLines(inst)
    assertTrue(byIndex[1] == nil, "an event carrier landed on the tooltip's header line")
    assertTrue(lineTexts(inst)[1] ~= nil, "there must be a header line at all")
end)

test("Tooltip: the death header names the player and when they died", function()
    -- The row itself only says "Death 3"; the tooltip is where the reader finds
    -- out whose death and at what time.
    local inst, cfg, anchor, row = deathBench()
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)
    -- AddDoubleLine, as CellTooltip's header is: the player on the left, the
    -- time on the right, so the two read as a caption rather than a sentence.
    local left  = inst.mocks.GameTooltipTextLeft1
    local right = inst.mocks.GameTooltipTextRight1
    assertTrue((right and right:GetText() or ""):find("13:01:06", 1, true) ~= nil,
        "the time of death is missing")
    assertTrue((left and left:GetText() or "") ~= "", "the player is missing")
end)

test("Tooltip: a death with no recap keeps the header too", function()
    -- The empty case takes the same route out, or it reintroduces the bug on the
    -- one path nobody looks at.
    local inst, cfg, anchor, row = deathBench()
    inst.mocks.setDeathRecap({ HasRecapEvents = function() return false end })
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)
    assertTrue(tooltipLines(inst)[1] == nil, "a carrier landed on the header line")
end)

-- ---------------------------------------------------------------------------
-- The GRID's Deaths cell (issue #1's first complaint)
-- ---------------------------------------------------------------------------
--
-- "The tooltip runs the ordinary spell-breakdown path, which asks the provider
-- for combatSpells on a Deaths source. There is no spell list on a death row, so
-- it renders 'No data yet' — technically honest, and useless. A Deaths cell
-- should not be showing a spell breakdown at all."

--- A grid row for somebody who died three times.
local function deadGridRow()
    return {
        guid = "Player-1-0000000A", name = "Yllarie", classFilename = "PRIEST",
        deaths = { 29, 28, 27 }, deathRecapID = 29,
        values = { Deaths = { total = 3, maxAmount = 3 } },
    }
end

test("Tooltip: a Deaths cell lists the DEATHS, not a spell breakdown", function()
    -- red under: the Deaths cell falling through to addSpellBreakdown, which is
    -- what shipped and what the issue opens with.
    local inst, cfg, anchor = bench()
    inst.mocks.setDeathRecap({
        HasRecapEvents = function() return true end,
        GetRecapEvents = function(id)
            return { { spellId = 1, spellName = "X", amount = 1, currentHP = 1,
                       timestamp = 1000 + id } }
        end,
        GetRecapMaxHealth = function() return 100 end,
    })
    inst.NS.Tooltip:CellTooltip(deadGridRow(), "Deaths", anchor, cfg)

    local texts = table.concat(lineTexts(inst), "\n")
    assertTrue(texts:find("No data yet", 1, true) == nil,
        "the Deaths cell still ran the spell path")
    assertTrue(texts:find("Spell breakdown", 1, true) == nil,
        "a death has no spells and must not claim to")
end)

test("Tooltip: a Deaths cell shows one line per death, newest first", function()
    local inst, cfg, anchor = bench()
    inst.mocks.setDeathRecap({
        HasRecapEvents = function() return true end,
        GetRecapEvents = function(id)
            return { { spellId = 1, spellName = "X", amount = 1, currentHP = 1,
                       timestamp = id } }
        end,
        GetRecapMaxHealth = function() return 100 end,
    })
    inst.NS.Tooltip:CellTooltip(deadGridRow(), "Deaths", anchor, cfg)

    -- The times sit in the carrier's AMOUNT slot, so they line up in a column
    -- instead of ragging against labels of two lengths.
    local slots = {}
    for _, line in ipairs(spellLines(inst)) do slots[#slots + 1] = line.amount:GetText() end
    local joined = table.concat(slots, "\n")
    for _, id in ipairs({ 29, 28, 27 }) do
        local clock = inst.mocks.date("%H:%M:%S", id)
        assertTrue(joined:find(clock, 1, true) ~= nil,
            "the death at " .. clock .. " is missing from the cell tooltip")
    end
    assertEqual(slots[1], inst.mocks.date("%H:%M:%S", 29), "newest first")
end)

--- "Take this field OFF the event", which `nil` cannot say: a nil in a table
--- literal is a key that was never written, so `pairs` never sees it and the
--- override silently does nothing. Half of these cases are about a field the
--- client did NOT send, so the absence has to be expressible.
local ABSENT = {}

--- A recap whose killing blow names a caster and a spell.
local function killerRecap(overrides)
    return {
        HasRecapEvents = function() return true end,
        GetRecapEvents = function(id)
            local newest = { spellId = 1, spellName = "Sulfuras Smash",
                             sourceName = "Ragnaros", amount = 1, currentHP = 1,
                             timestamp = id }
            for k, v in pairs(overrides or {}) do
                if v == ABSENT then v = nil end
                newest[k] = v
            end
            -- Two events, so the case also pins that it is the NEWEST one that
            -- gets read: element two is a hit that did not kill anybody.
            return { newest, { spellId = 2, spellName = "Living Meteor",
                               sourceName = "Sulfuron Harbinger", amount = 1,
                               currentHP = 50, timestamp = id - 4 } }
        end,
        GetRecapMaxHealth = function() return 100 end,
    }
end

test("Tooltip: the death line ships naming the KILLER and not the spell", function()
    -- The split a death list is actually read for. "Death 3" alone says nothing
    -- the reader did not already know -- the count is in the cell they hovered to
    -- get here -- and the caster closes that. The spell is the longest thing on
    -- the line, the half most often absent, and it answers a question a reader has
    -- after clicking into the recap rather than while scanning the list.
    -- red under: shipping both on, which is what this shipped as first.
    local inst, cfg, anchor = bench()
    inst.mocks.setDeathRecap(killerRecap())
    inst.NS.Tooltip:CellTooltip(deadGridRow(), "Deaths", anchor, cfg)

    local shipped = table.concat(lineTexts(inst), "\n")
    assertTrue(shipped:find("Death 3 | Ragnaros", 1, true) ~= nil,
        "the shipped death line does not name the killer")
    assertTrue(shipped:find("Sulfuras Smash", 1, true) == nil,
        "the spell is drawn on a fresh profile; it ships off")
end)

test("Tooltip: a death line names who and what landed the killing blow", function()
    -- "Death 3 | Ragnaros | Sulfuras Smash". The recap's newest event IS the
    -- killing blow -- the array arrives newest first -- which is the same fact
    -- the timestamp is read off one line above.
    -- red under: reading events[#events], or dropping either half of the label.
    local inst, cfg, anchor = bench()
    inst.mocks.setDeathRecap(killerRecap())
    -- Asked for explicitly: the spell half ships OFF, and this case is about what
    -- the line draws when both are on rather than about what a fresh profile does.
    inst.NS.Database.GetWindows()[1].tooltip.showDeathSpell = true
    inst.NS.Tooltip:CellTooltip(deadGridRow(), "Deaths", anchor, cfg)

    local texts = table.concat(lineTexts(inst), "\n")
    assertTrue(texts:find("Death 3 | Ragnaros | Sulfuras Smash", 1, true) ~= nil,
        "the death line did not name the killing blow")
    assertTrue(texts:find("Living Meteor", 1, true) == nil,
        "an earlier event was read as the killing blow")
end)

test("Tooltip: either half of a death line can be switched off on its own", function()
    -- Who killed me is a positioning question and what killed me is a cooldown
    -- question, which is why they are two settings and not one.
    -- red under: one switch governing both, or a separator left behind by the
    -- half that was turned off.
    local inst, cfg, anchor = bench()
    inst.mocks.setDeathRecap(killerRecap())

    local window = inst.NS.Database.GetWindows()[1]
    window.tooltip.showDeathSpell  = true          -- ships off; this case needs both live
    window.tooltip.showDeathCaster = false
    inst.NS.Tooltip:CellTooltip(deadGridRow(), "Deaths", anchor, cfg)
    local texts = table.concat(lineTexts(inst), "\n")
    assertTrue(texts:find("Death 3 | Sulfuras Smash", 1, true) ~= nil,
        "the spell did not survive the caster being switched off")
    assertTrue(texts:find("Ragnaros", 1, true) == nil, "the caster was still drawn")

    window.tooltip.showDeathCaster = true
    window.tooltip.showDeathSpell  = false
    inst.NS.Tooltip:CellTooltip(deadGridRow(), "Deaths", anchor, cfg)
    texts = table.concat(lineTexts(inst), "\n")
    assertTrue(texts:find("Death 3 | Ragnaros", 1, true) ~= nil,
        "the caster did not survive the spell being switched off")
    assertTrue(texts:find("Sulfuras Smash", 1, true) == nil, "the spell was still drawn")
end)

test("Tooltip: a death with nothing to name is still a numbered death", function()
    -- An environmental kill sets `hideCaster` and a melee swing has no spell name
    -- at all. Neither is a failure and neither may take the line down with it --
    -- what is missing is simply not drawn.
    -- red under: printing "nil", a dangling separator, or skipping the line.
    local inst, cfg, anchor = bench()
    inst.mocks.setDeathRecap(killerRecap({
        hideCaster = true, spellName = ABSENT, spellId = ABSENT,
        event = "ENVIRONMENTAL_DAMAGE",
    }))
    inst.NS.Tooltip:CellTooltip(deadGridRow(), "Deaths", anchor, cfg)

    local texts = table.concat(lineTexts(inst), "\n")
    assertTrue(texts:find("Death 3", 1, true) ~= nil, "the death line went missing")
    assertTrue(texts:find("Death 3 |", 1, true) == nil, "a separator was left behind")
    assertTrue(texts:find("nil", 1, true) == nil, "a missing name rendered as 'nil'")
end)

test("Tooltip: a melee killing blow is named Melee rather than left blank", function()
    -- The same call Blizzard's own recap makes, and the same one eventColumns
    -- makes one screen down: a swing has no spell at all, and "#?" reads as a bug
    -- in the addon rather than as a melee hit.
    -- red under: falling through to the spell-id placeholder in a one-line summary.
    local inst, cfg, anchor = bench()
    inst.mocks.setDeathRecap(killerRecap({
        spellName = ABSENT, spellId = ABSENT, event = "SWING_DAMAGE",
    }))
    inst.NS.Database.GetWindows()[1].tooltip.showDeathSpell = true
    inst.NS.Tooltip:CellTooltip(deadGridRow(), "Deaths", anchor, cfg)

    local texts = table.concat(lineTexts(inst), "\n")
    assertTrue(texts:find("Death 3 | Ragnaros | Melee", 1, true) ~= nil,
        "a melee killing blow was not named")
end)

test("Tooltip: a secret caster or spell name is left off rather than joined", function()
    -- Both are resolved off ids the client may hand back SECRET, and the label is
    -- built with `..`. So everything goes through plainWord on the way out and a
    -- name that cannot be read is simply absent -- "not available" and "secret
    -- right now" are the same thing to a reader.
    -- red under: concatenating a secret name into the line, which raises on a
    -- coalesced refresh ticker rather than in front of anybody.
    local inst, cfg, anchor = bench()
    inst.mocks.setDeathRecap(killerRecap({
        sourceName = inst.mocks.secret("Ragnaros"),
        spellName  = inst.mocks.secret("Sulfuras Smash"),
    }))
    inst.mocks.setRestricted(true)

    local ok = pcall(function()
        inst.NS.Tooltip:CellTooltip(deadGridRow(), "Deaths", anchor, cfg)
    end)
    assertTrue(ok, "joining a secret name raised")

    local texts = table.concat(lineTexts(inst), "\n")
    assertTrue(texts:find("Death 3", 1, true) ~= nil, "the death line went missing")
    assertTrue(texts:find("Death 3 |", 1, true) == nil, "a separator was left behind")
end)

test("Tooltip: a Deaths cell still says a click opens the list", function()
    local inst, cfg, anchor = bench()
    inst.mocks.setDeathRecap({
        HasRecapEvents = function() return true end,
        GetRecapEvents = function() return { { spellId = 1, timestamp = 5 } } end,
    })
    inst.NS.Tooltip:CellTooltip(deadGridRow(), "Deaths", anchor, cfg)
    local texts = table.concat(lineTexts(inst), "\n")
    assertTrue(texts:lower():find("click", 1, true) ~= nil)
end)

test("Tooltip: a cell for a player who has NOT died is unchanged", function()
    -- The Deaths column with a zero in it, and every other column, must keep
    -- exactly the tooltip they have.
    local inst, cfg, anchor = bench()
    local row = { guid = ALPHA, name = "Alpha", classFilename = "MAGE",
                  values = { DamageDone = { total = 100, maxAmount = 100 } } }
    inst.NS.Tooltip:CellTooltip(row, "DamageDone", anchor, cfg)
    local texts = table.concat(lineTexts(inst), "\n")
    assertTrue(texts:find("Spell breakdown", 1, true) ~= nil,
        "an ordinary cell lost its spell breakdown")
end)

test("Tooltip: the death breakdown gets the same gap and caption every section has", function()
    -- The header sat flush against the first bar, which no other tooltip in the
    -- addon does — a spell breakdown puts a paragraph gap and a caption between
    -- the two, and the death list has to read the same way or it looks like a
    -- different addon drew it.
    -- red under: the death branch going straight from AddDoubleLine to drawLine.
    local inst, cfg, anchor, row = deathBench()
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)

    local texts = lineTexts(inst)
    assertTrue((texts[2] or ""):find("%S") == nil,
        "line 2 must be the section gap, got " .. tostring(texts[2]))
    assertTrue((texts[3] or "") ~= "", "line 3 must be the caption")
    -- and the first event carrier therefore starts at line 4, exactly where a
    -- spell line does.
    local byIndex = tooltipLines(inst)
    assertTrue(byIndex[1] == nil and byIndex[2] == nil and byIndex[3] == nil,
        "an event carrier landed on the header, the gap or the caption")
    assertTrue(byIndex[4] ~= nil, "the first event should sit on line 4")
end)

-- ---------------------------------------------------------------------------
-- The event tooltip's columns
-- ---------------------------------------------------------------------------
--
-- One string held the time, the spell, the caster and the overkill, so a long
-- name pushed the numbers off the right edge and the killing blow rendered as
-- "355.8Kove…37.3%". Four slots now, each a reservation the engine clips
-- against — never a truncation this code performs, because a spell name and a
-- caster name can both be secret and cutting one up is inspecting it.

test("Tooltip: an event's time, spell and caster are three separate slots", function()
    -- red under: one composed caption in the label slot.
    local inst, cfg, anchor, row = deathBench{ lastSource = "Merektha" }
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)

    local last = spellLines(inst)[2]
    assertEqual(last.time:GetText(), "-0.0s")
    assertEqual(last.label:GetText(), "Volley")
    assertEqual(last.caster:GetText(), "Merektha")
end)

test("Tooltip: each slot has a reserved width, so a long name cannot push the numbers off", function()
    -- The widths are fixed and the engine clips into them. Measuring the names
    -- to size the columns is what rule R3 forbids — a caption is secret mid-pull.
    local inst, cfg, anchor, row = deathBench{
        lastName = "Ritual of the Fang of the Loa Speaker Nanea and Friends",
        lastSource = "High Channeler Ryvati of the Bleeding Hollow",
    }
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)

    local first, second = spellLines(inst)[1], spellLines(inst)[2]
    assertTrue(second.label:GetWidth() > 0, "the spell slot has no reserved width")
    assertEqual(first.label:GetWidth(), second.label:GetWidth(),
        "a longer name widened its column instead of being clipped into it")
    assertEqual(first.caster:GetWidth(), second.caster:GetWidth())
end)

test("Tooltip: the amount slot carries the damage ALONE", function()
    -- Overkill is dropped from this surface entirely. It is the part of a
    -- killing blow that exceeded health the player no longer had, it only ever
    -- appears on one line, and it was colliding with the HP percentage.
    -- red under: appending an overkill clause anywhere on the line.
    local inst, cfg, anchor, row = deathBench()
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)

    local texts = table.concat(lineTexts(inst), "\n")
    for _, line in ipairs(spellLines(inst)) do
        texts = texts .. "\n" .. line.amount:GetText() .. "\n" .. line.label:GetText()
    end
    assertTrue(texts:lower():find("overkill", 1, true) == nil,
        "overkill is still on the death tooltip")
end)

test("Tooltip: a spell line gets its slots BACK after an event line used them", function()
    -- THE POOL HAZARD. A carrier is keyed by tooltip line index, so line 4 of
    -- this hover is the frame that drew line 4 of the last one. An event line
    -- narrows the label and shows two extra slots; a spell line after it must
    -- not inherit either.
    -- red under: laying the columns out once at creation instead of per draw.
    local inst, cfg, anchor, row = deathBench()
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)
    local eventWidth = spellLines(inst)[1].label:GetWidth()

    inst.NS.Tooltip:CellTooltip(
        { guid = ALPHA, name = "Alpha", classFilename = "MAGE",
          values = { DamageDone = { total = 100, maxAmount = 100 } } },
        "DamageDone", anchor, cfg)

    local spell = spellLines(inst)[1]
    assertTrue(spell ~= nil, "no spell line was drawn")
    assertEqual(spell.time:IsShown(), false, "a spell line kept the event's time slot")
    assertEqual(spell.caster:IsShown(), false, "a spell line kept the event's caster slot")
    assertTrue(spell.label:GetWidth() ~= eventWidth,
        "a spell line inherited the event line's narrowed name column")
end)

test("Tooltip: an event with no caster leaves that column empty, not absent", function()
    -- The columns must line up down the whole tooltip; a missing caster that
    -- collapsed its slot would shift every column on that row.
    local inst, cfg, anchor, row = deathBench{ hideCaster = true }
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)

    local last = spellLines(inst)[2]
    assertEqual(last.caster:GetText(), "")
    assertTrue(last.caster:IsShown(), "the empty caster slot was hidden, moving the row")
end)

test("Tooltip: the death tooltip reserves a WIDER minimum than a spell breakdown", function()
    -- Two more columns have to be paid for, or they overlap the numbers.
    local inst, cfg, anchor, row = deathBench()
    local parts = inst.NS.Tooltip.WidthParts()
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)
    assertTrue(inst.mocks.GameTooltip.__minWidth > parts.total,
        "the death tooltip is no wider than a spell one, so its columns collide")
end)

test("Tooltip: a Deaths cell's rows carry a FULL bar, not an empty one", function()
    -- An empty bar behind every line reads as a value that failed to load. A
    -- death is not a quantity, so the bar is the row's backing rather than a
    -- measure — full, from plain ones, the same way a death row's cell in the
    -- drill-down does it.
    -- red under: passing nil for value and max, which draws 0 of 1.
    local inst, cfg, anchor = bench()
    inst.mocks.setDeathRecap({
        HasRecapEvents = function() return true end,
        GetRecapEvents = function(id) return { { spellId = 1, timestamp = id } } end,
    })
    inst.NS.Tooltip:CellTooltip(deadGridRow(), "Deaths", anchor, cfg)

    for _, line in ipairs(spellLines(inst)) do
        local mn, mx = line.bar:GetMinMaxValues()
        assertEqual(mn, 0)
        assertEqual(mx, 1)
        assertEqual(line.bar:GetValue(), 1, "a death line's bar drew empty")
    end
end)

test("Tooltip: every death line in a Deaths cell carries the skull icon", function()
    -- The line had no icon at all, so it sat a glyph-width left of every other
    -- tooltip in the addon and read as a missing texture.
    -- red under: adding the line without a |T…|t head.
    local inst, cfg, anchor = bench()
    inst.mocks.setDeathRecap({
        HasRecapEvents = function() return true end,
        GetRecapEvents = function(id) return { { spellId = 1, timestamp = id } } end,
    })
    inst.NS.Tooltip:CellTooltip(deadGridRow(), "Deaths", anchor, cfg)

    local texts = table.concat(lineTexts(inst), "\n")
    assertTrue(texts:find("|T237275:", 1, true) ~= nil,
        "the skull icon is missing from the death lines")
end)

test("Tooltip: a Deaths cell's time sits at the right edge, where a share does", function()
    -- It was in the AMOUNT slot, which is inset by the width of the share slot
    -- beside it — so the times floated a column short of the bar's right edge
    -- while every other tooltip's rightmost figure sits against it.
    -- red under: leaving the clock in the amount slot with the share slot shown.
    local inst, cfg, anchor = bench()
    inst.mocks.setDeathRecap({
        HasRecapEvents = function() return true end,
        GetRecapEvents = function(id) return { { spellId = 1, timestamp = id } } end,
    })
    inst.NS.Tooltip:CellTooltip(deadGridRow(), "Deaths", anchor, cfg)

    local line = spellLines(inst)[1]
    assertEqual(line.share:IsShown(), false,
        "the empty share slot is still holding the time away from the edge")
    local _, relTo, relPoint = line.amount:GetPoint(1)
    assertTrue(relTo == line and relPoint == "RIGHT",
        "the time must be anchored to the carrier's own right edge")
end)

test("Tooltip: the caster column's CAP is narrower than the spell column's", function()
    -- Both columns size to their content now, so which is wider on any given
    -- hover is up to the data. What still holds is the ceiling each may reach: a
    -- caster name is shorter than a spell name in almost every case, and the
    -- reservation reflects that. Forced onto the reserved path with secret
    -- captions, which is also the mid-pull case.
    local inst, cfg, anchor, row = deathBench()
    inst.mocks.setDeathRecap({
        HasRecapEvents = function() return true end,
        GetRecapEvents = function()
            return { { spellId = 1, spellName = inst.mocks.secret("X"),
                       sourceName = inst.mocks.secret("Y"),
                       amount = inst.mocks.secret(1),
                       currentHP = inst.mocks.secret(1), timestamp = 1000 } }
        end,
        GetRecapMaxHealth = function() return inst.mocks.secret(1000) end,
    })
    inst.mocks.setSecretsAccessible(false)
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)

    local line = spellLines(inst)[1]
    assertTrue(line.caster:GetWidth() < line.label:GetWidth(),
        "the caster column's cap is no narrower than the spell column's")
end)

test("Tooltip: both name columns refuse to wrap, so the engine clips them", function()
    -- This is the whole truncation story. A spell name and a caster name can
    -- both be secret, so neither may be cut up here — `string.sub` on a secret
    -- raises, and measuring one to decide where to cut is an inspection. A fixed
    -- width with wrapping off leaves the clipping to the engine, which is
    -- allowed to look.
    -- red under: dropping SetWordWrap(false), which makes a long name wrap onto
    -- a second line and push every row below it down.
    local inst, cfg, anchor, row = deathBench{
        lastName = "Ritual of the Fang of the Loa Speaker Nanea",
        lastSource = "High Channeler Ryvati of the Bleeding Hollow",
    }
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)

    local line = spellLines(inst)[2]
    assertEqual(line.label.__wordWrap, false, "the spell column may wrap")
    assertEqual(line.caster.__wordWrap, false, "the caster column may wrap")
end)

test("Tooltip: a melee swing reads as Melee, not as #?", function()
    -- A swing carries NO spellId and no spellName — Blizzard's own recap draws
    -- it as "Melee" with the weapon icon. Ours fell all the way through to the
    -- "the client could not name this" placeholder and printed "#?", which reads
    -- as a bug in the addon rather than as a melee hit.
    -- red under: keying the fallback on the spell id alone.
    local inst, cfg, anchor, row = deathBench()
    inst.mocks.setDeathRecap({
        HasRecapEvents = function() return true end,
        GetRecapEvents = function()
            return { { event = "SWING_DAMAGE", amount = 115666, currentHP = 200,
                       sourceName = "Ruthless Totemcaller", timestamp = 1000 } }
        end,
        GetRecapMaxHealth = function() return 1000 end,
    })
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)

    local line = spellLines(inst)[1]
    assertEqual(line.label:GetText(), "Melee")
    assertTrue(table.concat(lineTexts(inst), "\n"):find("|T135274:", 1, true) ~= nil,
        "a swing must wear the weapon icon")
end)

test("Tooltip: a heal with no spell id reads as Heal", function()
    local inst, cfg, anchor, row = deathBench()
    inst.mocks.setDeathRecap({
        HasRecapEvents = function() return true end,
        GetRecapEvents = function()
            return { { event = "SPELL_PERIODIC_HEAL", amount = 500,
                       currentHP = 800, timestamp = 1000 } }
        end,
        GetRecapMaxHealth = function() return 1000 end,
    })
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)
    assertEqual(spellLines(inst)[1].label:GetText(), "Heal")
end)

test("Tooltip: an event with an id the client cannot name still shows the id", function()
    -- The placeholder still has a job — it just is not the melee case.
    local inst, cfg, anchor, row = deathBench()
    inst.mocks.setDeathRecap({
        HasRecapEvents = function() return true end,
        GetRecapEvents = function()
            return { { spellId = 999001, event = "SPELL_DAMAGE", amount = 1,
                       currentHP = 1, timestamp = 1000 } }
        end,
        GetRecapMaxHealth = function() return 1000 end,
    })
    inst.mocks.__spells = setmetatable({}, { __index = function() return nil end })
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)
    assertTrue(spellLines(inst)[1].label:GetText():find("999001", 1, true) ~= nil)
end)

test("Tooltip: a SECRET event type is not compared", function()
    -- The melee and heal fallbacks both test `event.event`, which comes off a
    -- recap like everything else here.
    local inst, cfg, anchor, row = deathBench()
    inst.mocks.setDeathRecap({
        HasRecapEvents = function() return true end,
        GetRecapEvents = function()
            return { { event = inst.mocks.secret("SWING_DAMAGE"),
                       amount = inst.mocks.secret(1),
                       currentHP = inst.mocks.secret(1), timestamp = 1000 } }
        end,
        GetRecapMaxHealth = function() return inst.mocks.secret(1000) end,
    })
    inst.mocks.setSecretsAccessible(false)
    assertTrue(pcall(function() inst.NS.Tooltip:SpellTooltip(row, anchor, cfg) end),
        "a secret event type raised")
end)

test("Tooltip: the time column is sized to the widest time in THIS recap", function()
    -- It was reserved for "-100.0s" whatever the recap held, so a list whose
    -- longest was "-81.2s" carried a character of slack down its left edge. The
    -- offsets are numbers this addon computed, so measuring them is legal —
    -- unlike the names beside them.
    -- red under: a constant reservation.
    local function widthFor(events)
        local inst, cfg, anchor, row = deathBench()
        inst.mocks.setDeathRecap({
            HasRecapEvents = function() return true end,
            GetRecapEvents = function() return events end,
            GetRecapMaxHealth = function() return 1000 end,
        })
        inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)
        return spellLines(inst)[1].time:GetWidth()
    end

    local narrow = widthFor({ { spellId = 1, currentHP = 1, timestamp = 1000 },
                              { spellId = 1, currentHP = 1, timestamp = 998 } })
    local wide   = widthFor({ { spellId = 1, currentHP = 1, timestamp = 1000 },
                              { spellId = 1, currentHP = 1, timestamp = 100 } })
    assertTrue(wide > narrow,
        "a recap spanning 900s must reserve more room than one spanning 2s")
end)

test("Tooltip: the name columns shrink to the names actually in this recap", function()
    -- Reserved at 22 and 16 characters whatever the recap held, so a list of
    -- "Melee" and "Cryo Surge" carried half a column of slack while the numbers
    -- went short. Measured when every name is readable, which out of combat is
    -- all of them — and that is when a death recap is read.
    -- red under: a constant reservation.
    local function widths(spell, caster)
        local inst, cfg, anchor, row = deathBench()
        inst.mocks.setDeathRecap({
            HasRecapEvents = function() return true end,
            GetRecapEvents = function()
                return { { spellId = 1, spellName = spell, sourceName = caster,
                           amount = 1, currentHP = 1, timestamp = 1000 } }
            end,
            GetRecapMaxHealth = function() return 1000 end,
        })
        inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)
        local line = spellLines(inst)[1]
        return line.label:GetWidth(), line.caster:GetWidth()
    end

    local shortSpell, shortCaster = widths("Melee", "Frostfang")
    local longSpell,  longCaster  = widths("Rumbling Ward of the Deep", "Avatar of Determination")
    assertTrue(longSpell > shortSpell, "the spell column did not shrink to its content")
    assertTrue(longCaster > shortCaster, "the caster column did not shrink to its content")
end)

test("Tooltip: a name column never grows past its character cap", function()
    -- Shrinking to fit must not become growing to fit: a boss ability with a
    -- forty-character name would push the numbers off the edge, which is the
    -- thing the reservation was there to stop.
    local inst, cfg, anchor, row = deathBench()
    inst.mocks.setDeathRecap({
        HasRecapEvents = function() return true end,
        GetRecapEvents = function()
            return { { spellId = 1, amount = 1, currentHP = 1, timestamp = 1000,
                       spellName = string.rep("W", 80), sourceName = string.rep("W", 80) } }
        end,
        GetRecapMaxHealth = function() return 1000 end,
    })
    inst.NS.Tooltip:SpellTooltip(row, anchor, cfg)

    local capped = spellLines(inst)[1]
    local parts = inst.NS.Tooltip.WidthParts()
    assertTrue(capped.label:GetWidth() < parts.total,
        "an 80-character spell name took the whole tooltip")
end)

test("Tooltip: a SECRET name falls back to the fixed reservation", function()
    -- Measuring the widest of several is a comparison, and comparing a secret
    -- raises. Mid-pull the captions are secret, so the columns go back to being
    -- reserved rather than measured — the same trade applyMinimumWidth records.
    -- red under: measuring without asking whether the name may be read.
    local inst, cfg, anchor, row = deathBench()
    inst.mocks.setDeathRecap({
        HasRecapEvents = function() return true end,
        GetRecapEvents = function()
            return { { spellId = 1, spellName = inst.mocks.secret("Melee"),
                       sourceName = inst.mocks.secret("Frostfang"),
                       amount = inst.mocks.secret(1),
                       currentHP = inst.mocks.secret(1), timestamp = 1000 } }
        end,
        GetRecapMaxHealth = function() return inst.mocks.secret(1000) end,
    })
    inst.mocks.setSecretsAccessible(false)

    assertTrue(pcall(function() inst.NS.Tooltip:SpellTooltip(row, anchor, cfg) end),
        "measuring a secret name raised")
    local line = spellLines(inst)[1]
    assertTrue(line.label:GetWidth() > 0, "the column lost its reservation entirely")
end)
