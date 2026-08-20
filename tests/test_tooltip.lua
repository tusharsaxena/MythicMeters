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

test("A bar sits UNDER the tooltip's text, not over it", function()
    -- GameTooltip draws its line FontStrings in ARTWORK, and a frame at the
    -- tooltip's own level interleaves its draw layers with the tooltip's. So the
    -- fill goes in BORDER: any higher and a full-width bar paints over the very
    -- spell name it is behind.
    -- red under: leaving the fill on the StatusBar's default layer.
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
    assertEqual(fill.__drawLayer and fill.__drawLayer[1], "BORDER",
        "the fill must draw below the tooltip's ARTWORK text")
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
    -- The setting is worded for a player ("Bottom right") and the token is
    -- Blizzard's, so the translation table is the one thing standing between a
    -- typo'd "ANCHOR_BOTTOMRIGHT" and a silent fallback to the cursor. Every value
    -- the dropdown can produce is walked, which is what makes adding a ninth
    -- anchor without adding its token a failing test rather than a shrug.
    -- red under: dropping any entry from ANCHOR_TOKENS.
    local expected = {
        CURSOR      = "ANCHOR_CURSOR",
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

