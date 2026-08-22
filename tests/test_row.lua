-- tests/test_row.lua — modules/Row.lua: the cells, and the fact that none of
-- them ever looks at a number.
--
-- Every meter figure that reaches SetValue / SetText here is an OPAQUE HANDLE.
-- The simulated secret in tests/wow_mock.lua traps arithmetic, comparison,
-- indexing and concatenation, so a case that renders a restricted row and then
-- asserts on the widget is a live probe for an inspection rather than a
-- restatement of the file header. What it CAN legally do is exactly two things:
-- test a value for nil-ness, and hand it to a widget setter or to the native
-- formatter — and both are asserted below on the values the widget actually
-- received, which the frame stub records raw.

local T = _G.MYTHICMETERS_TEST

local test        = T.test
local assertEqual = T.assertEqual
local assertTrue  = T.assertTrue
local assertFalse = T.assertFalse
local assertNil   = T.assertNil

--- A window instance with a known column set, plus one row built off its pool.
---
--- The row is created through NS.Row.New rather than through a refresh so a case
--- can hand it any entry it likes, including shapes the aggregator would never
--- produce.
local function bench(configure)
    local inst = T.load()
    local NS = inst.NS

    local cfg = NS.Database.GetWindows()[1]
    cfg.frame.locked = true
    cfg.columns = {
        { stat = "DamageDone",  width = 90, showBar = true },
        { stat = "Interrupts",  width = 40, showBar = true },
    }
    cfg.data.sortColumn = "DamageDone"
    if configure then configure(cfg) end

    local window = NS.Window.New(cfg)
    local row = NS.Row.New(window)
    row:ApplyLayout(window.layout)
    return inst, window, row, cfg
end

--- An aggregator-shaped entry.
local function entry(values, opts)
    opts = opts or {}
    return {
        guid          = opts.guid or "Player-1-0000000A",
        name          = opts.name or "Alpha",
        classFilename = opts.classFilename or "MAGE",
        specIconID    = opts.specIconID,
        role          = opts.role or "DAMAGER",
        isPlayer      = opts.isPlayer or false,
        isDrillDown   = opts.isDrillDown,
        icon          = opts.icon,
        maxAmount     = opts.maxAmount,
        values        = values,
        cells         = values,
    }
end

-- ---------------------------------------------------------------------------
-- Geometry, from config only
-- ---------------------------------------------------------------------------

test("Row.OffsetFor is a pure function of the index and the row config", function()
    local layout = { rowHeight = 16, rowSpacing = 1 }
    local OffsetFor = T.NS.Row.OffsetFor
    assertEqual(OffsetFor(layout, 1), 0)
    assertEqual(OffsetFor(layout, 2), 17)
    assertEqual(OffsetFor(layout, 5), 68)
    -- No widget is consulted, which is rule R3 for the vertical axis exactly as
    -- Cell:ApplyLayout is for the horizontal.
    assertEqual(OffsetFor({ rowHeight = 20, rowSpacing = 0 }, 3), 40)
end)

test("Cell:ApplyLayout places every cell from the layout table", function()
    local inst, window, row = bench()
    local layout = window.layout
    local Const = inst.NS.Constants

    assertEqual(row.frame:GetWidth(), layout.rowWidth)
    assertEqual(row.frame:GetHeight(), layout.rowHeight)

    local damage = row.cells.DamageDone
    local point, relativeTo, _, x = damage.frame:GetPoint(1)
    assertEqual(point, "TOPLEFT")
    assertTrue(relativeTo == row.frame)
    assertEqual(x, Const.NAME_COLUMN_WIDTH + 2)
    -- The DRAWN width is the layout's share of the frame, not the stored width.
    assertEqual(damage.frame:GetWidth(), layout.columns[1].width)
    assertEqual(damage.frame:GetHeight(), layout.rowHeight)
end)

test("A column toggled off hides its cell rather than destroying it", function()
    local _, window, row, cfg = bench()
    local before = row.cells.Interrupts
    assertTrue(before ~= nil)

    cfg.columns = { { stat = "DamageDone", width = 90 } }
    window:RefreshUpvalues()
    row:ApplyLayout(window.layout)

    assertEqual(row.cells.Interrupts.frame:IsShown(), false)
    assertTrue(row.cells.Interrupts == before, "the widget is kept for when it comes back")

    cfg.columns = { { stat = "DamageDone", width = 90 }, { stat = "Interrupts", width = 40 } }
    window:RefreshUpvalues()
    row:ApplyLayout(window.layout)
    assertEqual(row.cells.Interrupts.frame:IsShown(), true)
    assertTrue(row.cells.Interrupts == before, "and re-used, not rebuilt")
end)

test("modules/Row.lua contains no geometry getter at all", function()
    -- The static half of rule R3. There is not one GetWidth / GetHeight /
    -- GetLeft / GetPoint call in this file, and there must not be: the layout
    -- table the window hands in is the whole geometry story.
    local fh = assert(io.open(T.root .. "/modules/Row.lua", "r"))
    local n, offenders = 0, {}
    for line in fh:lines() do
        n = n + 1
        if not line:match("^%s*%-%-") then
            local code = line:gsub("%s%-%-.*$", "")
            for _, getter in ipairs{ "GetWidth", "GetHeight", "GetLeft", "GetPoint" } do
                if code:find(":" .. getter .. "%(") then
                    offenders[#offenders + 1] = "modules/Row.lua:" .. n .. " " .. getter
                end
            end
        end
    end
    fh:close()
    assertEqual(#offenders, 0, table.concat(offenders, ", "))
end)

-- ---------------------------------------------------------------------------
-- Values reach the widget untouched
-- ---------------------------------------------------------------------------

test("Cell:SetValue hands the raw handle to SetValue and SetMinMaxValues", function()
    local inst, _, row = bench()
    local mocks = inst.mocks
    mocks.setRestricted(true)

    local total = mocks.secret(4200000)
    local max   = mocks.secret(4200000)
    row:Update(entry{ DamageDone = { total = total, rate = mocks.secret(14000),
                                     maxAmount = max } }, 1)

    local bar = row.cells.DamageDone.frame
    -- The stub stores what it was handed, raw. Identity here is the whole point:
    -- nothing between the session read and the C side looked at the value.
    assertTrue(bar:GetValue() == total, "the same handle, not a copy or a coercion")
    local mn, mx = bar:GetMinMaxValues()
    assertEqual(mn, 0)
    assertTrue(mx == max)
    assertEqual(bar:HasSecretValues(), true,
        "which is why nothing may read this frame's geometry back")
end)

test("Cell:SetValue substitutes 0 and 1 for an ABSENT figure, not for a hidden one", function()
    local _, _, row = bench()
    -- `== nil` is the one test this file applies to a meter value, and it is how
    -- "this player has no dispels" is told apart from "this player dispelled a
    -- secret number of times".
    row:Update(entry{ Interrupts = {} }, 1)

    local bar = row.cells.Interrupts.frame
    assertEqual(bar:GetValue(), 0)
    local _, mx = bar:GetMinMaxValues()
    assertEqual(mx, 1)
    assertEqual(bar:HasSecretValues(), false)
end)

test("A rate-capable column renders the TOTAL ALONE by default", function()
    -- The shipped layout: `leftSlot = "total"`, `rightSlot = "none"`. Both slots
    -- take the same four values now, and the total is the figure a player reads
    -- a meter for; anyone who wants the rate beside it sets the right slot.
    local inst, _, row = bench()
    inst.mocks.setRestricted(true)

    row:Update(entry{
        DamageDone = { total = inst.mocks.secret(4200000),
                       rate  = inst.mocks.secret(14000),
                       maxAmount = inst.mocks.secret(4200000) },
    }, 1)

    -- ONE figure sits in the LEFT slot, at the cell's left edge, under a
    -- left-aligned column header. Filling the right slot first put a lone number
    -- hard against the cell's right edge and the header hard against its left.
    local cell = row.cells.DamageDone
    assertEqual(cell.left:GetText(), "4.2M")
    assertEqual(cell.right:GetText(), "", "the rate is off unless it is asked for")
end)

test("Both figures appear when the right slot is turned on", function()
    local inst, _, row = bench(function(c) c.text.rightSlot = "rate" end)
    inst.mocks.setRestricted(true)

    row:Update(entry{
        DamageDone = { total = inst.mocks.secret(4200000),
                       rate  = inst.mocks.secret(14000),
                       maxAmount = inst.mocks.secret(4200000) },
    }, 1)

    local cell = row.cells.DamageDone
    assertEqual(cell.left:GetText(), "4.2M")
    assertEqual(cell.right:GetText(), "14.0K",
        "amountPerSecond ships beside totalAmount, which is why Dps is never queried")
    assertEqual(cell.left:GetJustifyH(), "LEFT",
        "cells line up under their left-aligned column headers")
    assertFalse(cell.right:GetText():find("/", 1, true) ~= nil,
        "the rate slot carries no unit suffix — the column header already names the stat")
end)

test("A counting column renders the total only", function()
    local _, _, row = bench()
    row:Update(entry{ Interrupts = { total = 9, rate = 3, maxAmount = 9 } }, 1)

    local cell = row.cells.Interrupts
    assertEqual(cell.left:GetText(), "9")
    assertEqual(cell.right:GetText(), "",
        "\"0.42 interrupts per second\" is noise, so the slot stays empty")
    assertEqual(cell.stat.isRate, false, "and the catalog is where that is decided")
end)

test("The text slots are configurable, and percent is the one that goes quiet", function()
    local inst, _, row = bench(function(cfg)
        cfg.text.leftSlot  = "percent"
        cfg.text.rightSlot = "percent"
    end)

    row:Update(entry{ DamageDone = { total = 60, maxAmount = 100, percent = 60 } }, 1)
    assertEqual(row.cells.DamageDone.left:GetText(), "60.0%")

    -- The aggregator only produces `percent` when the division was legal, which
    -- is not most of a pull. nil is "cannot be known", never "zero percent".
    inst.mocks.setRestricted(true)
    row:Update(entry{ DamageDone = { total = inst.mocks.secret(60),
                                     maxAmount = inst.mocks.secret(100) } }, 1)
    assertEqual(row.cells.DamageDone.left:GetText(), "")
    assertEqual(row.cells.DamageDone.right:GetText(), "")
end)

test("A 'none' text slot renders nothing", function()
    -- The RIGHT slot, because a cell whose slots are both None falls back to its
    -- total rather than rendering a header, a bar and no number — see the case
    -- below, which pins that fallback.
    local _, _, row = bench(function(cfg) cfg.text.rightSlot = "none" end)
    row:Update(entry{ DamageDone = { total = 100, rate = 10, maxAmount = 100 } }, 1)
    assertEqual(row.cells.DamageDone.right:GetText(), "")
end)

test("A cell with BOTH slots off still shows its total", function()
    -- Otherwise the column renders a header, a bar and no number at all, which
    -- reads as a broken addon rather than as a deliberate setting. The same
    -- fallback covers a counting stat whose only slot is set to Per second.
    -- red under: honouring "none" on both slots literally.
    local _, _, row = bench(function(cfg)
        cfg.text.leftSlot, cfg.text.rightSlot = "none", "none"
    end)
    row:Update(entry{ DamageDone = { total = 100, rate = 10, maxAmount = 100 } }, 1)
    assertEqual(row.cells.DamageDone.left:GetText(), "100")
end)

test("Both slots take the same four values, in either position", function()
    -- They used to take different three-value sets overlapping on two, which
    -- made "the total on the right" unexpressible for no reason anyone could
    -- state.
    -- red under: a rightSlot that ignores "total", or a leftSlot that ignores "rate".
    local _, _, row = bench(function(cfg)
        cfg.text.leftSlot, cfg.text.rightSlot = "rate", "total"
    end)
    row:Update(entry{ DamageDone = { total = 100, rate = 10, maxAmount = 100 } }, 1)
    assertEqual(row.cells.DamageDone.left:GetText(), "10", "the left slot refused a rate")
    assertEqual(row.cells.DamageDone.right:GetText(), "100", "the right slot refused a total")
end)

test("Cell figures are read out of EITHER row shape the addon produces", function()
    local _, _, row = bench()

    -- modules/Aggregator.lua emits { total }, modules/DrillDown.lua emits
    -- { total } on `values` with the max on the ROW. Both are legitimate, and
    -- the branch lives in one place rather than at every call site.
    row:Update({ guid = "spell:101", name = "Fireball", isDrillDown = true,
                 maxAmount = 500,
                 values = { DamageDone = { total = 250, rate = 25 } } }, 1)

    local bar = row.cells.DamageDone.frame
    assertEqual(bar:GetValue(), 250)
    local _, mx = bar:GetMinMaxValues()
    assertEqual(mx, 500, "the max fell back to the row's")
end)

-- ---------------------------------------------------------------------------
-- Color
-- ---------------------------------------------------------------------------

test("Class color comes from classFilename, which keeps working while restricted", function()
    local inst, _, row = bench(function(cfg) cfg.bars.colorMode = "class" end)
    inst.mocks.setRestricted(true)

    row:Update(entry({ DamageDone = { total = inst.mocks.secret(100),
                                      maxAmount = inst.mocks.secret(100) } },
        { classFilename = "PRIEST" }), 1)

    -- classFilename is NeverSecret. That is what makes "class" the default and
    -- what makes it keep working at the height of a pull when every number on
    -- the row is opaque.
    local color = row.cells.DamageDone.frame.__barColor
    local expected = inst.mocks.RAID_CLASS_COLORS.PRIEST
    assertEqual(color[1], expected.r)
    assertEqual(color[2], expected.g)
    assertEqual(color[3], expected.b)
end)

test("Every color mode falls back to one neutral, never to a fourth palette", function()
    local _, _, row = bench(function(cfg) cfg.bars.colorMode = "class" end)
    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } },
        { classFilename = "NOTACLASS" }), 1)

    local color = row.cells.DamageDone.frame.__barColor
    assertEqual(color[1], 0.45)
    assertEqual(color[2], 0.45)
    assertEqual(color[3], 0.5)
end)

test("Role and stat color modes read their own tables", function()
    local _, window, row, cfg = bench(function(c) c.bars.colorMode = "role" end)
    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } }, { role = "TANK" }), 1)
    local roleColor = row.cells.DamageDone.frame.__barColor
    assertEqual(roleColor[1], 0.30)

    cfg.bars.colorMode = "stat"
    window:RefreshUpvalues()
    row:Update(entry{ DamageDone = { total = 1, maxAmount = 1 },
                      Interrupts = { total = 1, maxAmount = 1 } }, 1)
    -- One color per column, so a glance at a wide window tells you which column
    -- you are reading.
    local damage    = row.cells.DamageDone.frame.__barColor
    local interrupt = row.cells.Interrupts.frame.__barColor
    assertFalse(damage[1] == interrupt[1] and damage[2] == interrupt[2],
        "two stats must not share a color")
end)

test("A custom color comes from the setting, not from the last-resort literal", function()
    local _, _, row = bench(function(cfg)
        cfg.bars.colorMode   = "custom"
        cfg.bars.customColor = { r = 0.1, g = 0.2, b = 0.3, a = 1 }
    end)
    row:Update(entry{ DamageDone = { total = 1, maxAmount = 1 } }, 1)
    local color = row.cells.DamageDone.frame.__barColor
    assertEqual(color[1], 0.1)
    assertEqual(color[2], 0.2)
    assertEqual(color[3], 0.3)
end)

test("A cell with its bar switched off keeps its text", function()
    local _, window, row, cfg = bench(function(c) c.text.leftSlot = "total" end)
    cfg.columns[1].showBar = false
    window:RefreshUpvalues()
    row:ApplyLayout(window.layout)
    row:Update(entry{ DamageDone = { total = 4200000, maxAmount = 4200000 } }, 1)

    assertEqual(row.cells.DamageDone.frame.__barColor[4], 0, "the bar goes transparent")
    assertEqual(row.cells.DamageDone.left:GetText(), "4.2M", "the column still reads")
    -- The BACKGROUND stays: a bar-less column still carries its class tint, it
    -- just stops competing for attention with a filled bar.
    assertEqual(row.cells.DamageDone.bg:IsShown(), true)
end)

-- ---------------------------------------------------------------------------
-- The name cell
-- ---------------------------------------------------------------------------

test("The name cell is never handed a meter value at all", function()
    local inst, _, row = bench()
    inst.mocks.setRestricted(true)
    row:Update(entry{
        DamageDone = { total = inst.mocks.secret(60), maxAmount = inst.mocks.secret(100) },
        Interrupts = { total = 9,  maxAmount = 9 },
    }, 1)

    -- The name column used to draw a bar scaled to the sort column, which meant
    -- handing this frame a secret purely to size a rectangle. Dropping the bar
    -- takes the frame OUT of the secret set: its geometry stays readable, which
    -- is the taint half of the change and the half a screenshot cannot show.
    -- red under: restoring the SetValue(total) call in Cell:SetPlayer.
    local bar = row.nameCell.frame
    assertEqual(bar:GetValue(), 0, "the name cell holds no figure")
    assertEqual(bar:HasSecretValues(), false,
        "and is therefore not marked secret, unlike every stat cell beside it")

    -- The stat cell in the same row DID take one, which is what makes the
    -- assertion above a real distinction rather than an artifact of the fixture.
    assertEqual(row.cells.DamageDone.frame:HasSecretValues(), true)
end)

test("The name cell colors the NAME by class, now that no bar carries it", function()
    local inst, _, row = bench()
    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } },
        { name = "Alpha", classFilename = "MAGE" }), 1)

    local r, g, b = row.nameCell.left:GetTextColor()
    local c = inst.mocks.RAID_CLASS_COLORS.MAGE
    assertEqual(r, c.r)
    assertEqual(g, c.g)
    assertEqual(b, c.b)
end)

test("An unknown class reads as white, not as a tenth palette entry", function()
    local _, _, row = bench()
    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } },
        { name = "Whatsit", classFilename = "NOTACLASS" }), 1)

    local r, g, b = row.nameCell.left:GetTextColor()
    assertEqual(r, 1); assertEqual(g, 1); assertEqual(b, 1)
end)

test("The name cell renders a plain name and survives a secret one", function()
    local inst, _, row = bench()
    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } }, { name = "Alpha" }), 1)
    assertEqual(row.nameCell.left:GetText(), "Alpha")

    -- ConditionalSecret: mid-pull the handle goes to the widget UNTOUCHED, and
    -- the client draws the real characters. SetText accepts a secret — the same
    -- permission modules/Format.lua relies on to put "12.4M" on a bar it may not
    -- divide — so the player sees the name, not a placeholder.
    --
    -- THE BUG THIS PINS: the opaque branch used to answer NS.SafeToString(name),
    -- so every row but the local player's read `<secret>` for the whole of a
    -- pull. That is the right answer for a LOG LINE, where the alternative is a
    -- raise inside string.format, and the wrong one for a widget.
    -- red under: returning the sentinel from nameText's opaque branch.
    inst.mocks.setRestricted(true)
    local handle = inst.mocks.secret("Alpha")
    row:Update(entry({ DamageDone = { total = inst.mocks.secret(1),
                                      maxAmount = inst.mocks.secret(1) } },
        { name = handle }), 1)

    local drawn = row.nameCell.left:GetText()
    assertTrue(drawn == handle, "the widget must get the handle itself, untouched")
    assertFalse(drawn == "<secret>", "the sentinel is a log renderer, never a name")
    assertEqual(inst.mocks.reveal(drawn), "Alpha", "and it is the right handle")
end)

-- ── realm strip and truncation ──────────────────────────────────────────────

test("A cross-realm PLAYER name loses its realm", function()
    local _, _, row = bench()
    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } },
        { guid = "Player-1-0000000A", name = "Stabby-Aerie Peak" }), 1)
    assertEqual(row.nameCell.left:GetText(), "Stabby",
        "the realm is most of the column and never what anyone is scanning for")
end)

test("An NPC keeps the hyphen in its name", function()
    -- "Crenna Earth-Daughter" is a follower-dungeon companion, and the first
    -- build of the realm strip rendered her as "Crenna Earth". A hyphen is only
    -- a realm separator in a PLAYER's name; the row's GUID is what says which
    -- this is, and guessing from the string would be a heuristic about naming
    -- conventions we do not control.
    -- red under: stripping on the hyphen unconditionally.
    --
    -- The cap is raised for this case so it asserts ONE thing. At the shipped
    -- default of 20 this exact name is 21 characters and truncates, which is the
    -- cap working correctly and would mask whether the strip fired.
    local _, _, row = bench(function(c) c.text.maxNameLength = 0 end)
    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } },
        { guid = "Creature-0-3766-2813-30763-209065-000078A00B",
          name = "Crenna Earth-Daughter" }), 1)
    assertEqual(row.nameCell.left:GetText(), "Crenna Earth-Daughter")
end)

test("A pet keeps its hyphen too", function()
    local _, _, row = bench()
    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } },
        { guid = "Pet-0-1234-5-6-7-8", name = "Gore-Tusk" }), 1)
    assertEqual(row.nameCell.left:GetText(), "Gore-Tusk")
end)

test("The name never wraps, and gets a fixed width to be truncated against", function()
    -- A WRAPPED NAME IS DRAWN OUTSIDE ITS OWN ROW: the second line lands on the
    -- row below and the whole grid reads as shuffled. Two-point anchoring also
    -- let the string grow to whatever the frame became mid-resize, so the width
    -- the cap was measured against moved while the mouse did.
    -- red under: anchoring LEFT and RIGHT instead of setting a width.
    local _, window, row = bench()
    local cell = row.nameCell

    assertEqual(cell.left.__wordWrap, false, "a name must never reflow onto a second line")
    assertTrue(cell.left:GetWidth() > 0, "the name text needs a width of its own")
    assertTrue(cell.left:GetWidth() < window.layout.nameColumn.width,
        "and it must leave room for the icons beside it")
end)

test("The icon inset is the SAME for a row with no icons to draw", function()
    -- A follower NPC has no spec icon. The space is reserved from the CONFIGURED
    -- slots rather than from what the row managed to draw, so its name still
    -- starts where every other name starts — a column whose text begins at a
    -- different x per row is not a column.
    local _, _, row = bench(function(c)
        c.icons = c.icons or {}
        c.icons.showClass, c.icons.showSpec, c.icons.showRole = true, true, true
    end)

    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } },
        { name = "Withspec", classFilename = "MAGE", specIconID = 135846 }), 1)
    local withIcons = row.nameCell.left:GetWidth()

    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } },
        { name = "Nospec" }), 2)
    assertEqual(row.nameCell.left:GetWidth(), withIcons,
        "the inset is the column's, not the row's")
end)

test("A layout pass keeps the class color instead of flashing white", function()
    -- THE RESIZE FLICKER. Cell:ApplyTextStyle repaints every slot in the
    -- window's text color, and it runs on every layout pass — which during a
    -- drag-resize is every frame. The class color was only restored by the next
    -- Cell:SetPlayer, up to a throttle interval later, so names flashed white for
    -- as long as the mouse was moving.
    -- red under: ApplyTextStyle ending at SetShadowOffset.
    local _, window, row = bench()
    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } },
        { name = "Priesty", classFilename = "PRIEST" }), 1)

    local before = { row.nameCell.left:GetTextColor() }

    -- What a resize does, repeatedly, with no refresh in between.
    row:ApplyLayout(window.layout)

    local after = { row.nameCell.left:GetTextColor() }
    for i = 1, 3 do
        assertEqual(after[i], before[i],
            "the name lost its class color on a layout pass (component " .. i .. ")")
    end
    assertFalse(after[1] == 1 and after[2] == 1 and after[3] == 1,
        "the fixture must use a class whose color is not white")
end)

test("A name past the cap is truncated with NO ellipsis", function()
    -- The column is narrow and the cap is small, so a glyph spent saying "there
    -- was more" is a glyph not spent on the name. The cut is the whole signal.
    -- red under: appending U+2026 to the truncated string.
    local _, window, row = bench(function(c) c.text.maxNameLength = 8 end)
    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } },
        { name = "Meredy Huntswell" }), 1)
    assertEqual(row.nameCell.left:GetText(), "Meredy H")
    assertEqual(window.config.text.maxNameLength, 8)
end)

test("Truncation counts CHARACTERS, never bytes", function()
    -- "Helyâ" is 6 bytes and 5 characters. A byte slice at 5 lands inside the â
    -- and emits half a code point, which renders as a replacement box — and the
    -- names most likely to need truncating are exactly the accented ones.
    -- red under: `out:sub(1, cap)`.
    local _, _, row = bench(function(c) c.text.maxNameLength = 5 end)
    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } },
        { name = "Hely\195\162nder" }), 1)
    assertEqual(row.nameCell.left:GetText(), "Hely\195\162")
end)

test("A cap of 0 means no cap", function()
    local _, _, row = bench(function(c) c.text.maxNameLength = 0 end)
    local long = "Averyveryverylongnpcnamethatkeepsgoing"
    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } }, { name = long }), 1)
    assertEqual(row.nameCell.left:GetText(), long)
end)

test("Neither the realm strip nor the cap is applied to a SECRET name", function()
    -- string.match and string.sub READ the characters of a value, and performing
    -- either on a secret is exactly what rule R1 forbids. A name we may not read
    -- goes to the widget untouched.
    -- red under: stripping before the IsConcatSafe probe.
    local inst, _, row = bench(function(c) c.text.maxNameLength = 4 end)
    inst.mocks.setRestricted(true)
    local ok = pcall(row.Update, row, entry({ DamageDone = { total = 1, maxAmount = 1 } },
        { name = inst.mocks.secret("Stabby-Aerie Peak") }), 1)
    assertTrue(ok, "inspecting a secret name raised")
end)

test("A drill-down row keeps a hyphen, which is part of a spell name", function()
    -- The realm strip is anchored to the first hyphen. On a spell that is not a
    -- separator, and stripping there would silently shorten it to its first word.
    local _, _, row = bench()
    local spell = { guid = "s1", name = "Fire-and-Brimstone", isDrillDown = true,
                    classFilename = "WARLOCK", role = "NONE",
                    values = { DamageDone = { total = 1, maxAmount = 1 } } }
    spell.cells = spell.values
    row:Update(spell, 1)
    assertEqual(row.nameCell.left:GetText(), "Fire-and-Brimstone")
end)

test("A nil name renders empty rather than the string 'nil'", function()
    local _, _, row = bench()
    -- Built by hand rather than through `entry()`, which defaults the name: the
    -- case is about a row that genuinely has none.
    local blank = { guid = "g", classFilename = "MAGE", role = "NONE",
                    values = { DamageDone = { total = 1, maxAmount = 1 } } }
    blank.cells = blank.values
    row:Update(blank, 1)
    assertEqual(row.nameCell.left:GetText(), "")
end)

test("The single icon slot prefers the SPEC where there is one", function()
    -- Spec over class because "which unit is this row" is the question the icon
    -- answers, and a spec separates the three druids in a raid where a class
    -- icon cannot.
    -- red under: drawing the class icon whenever classFilename is present.
    local _, window, row = bench()
    row:ApplyLayout(window.layout)

    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } },
        { classFilename = "MAGE", specIconID = 135771, role = "TANK" }), 1)

    local icons = row.nameCell.icons
    assertEqual(icons.unit:IsShown(), true, "the one slot drew nothing")
    assertEqual(icons.unit:GetTexture(), 135771, "specIconID is a file ID and NeverSecret")
end)

test("The slot falls back to the CLASS where no spec is known", function()
    -- An NPC, a pet, a player the unit API has not resolved. A class icon is
    -- still an answer where a spec is not available.
    -- red under: hiding the icon when specIconID is nil.
    local inst, window, row = bench()
    row:ApplyLayout(window.layout)

    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } },
        { classFilename = "MAGE", specIconID = nil, role = "TANK" }), 1)

    local icons = row.nameCell.icons
    assertEqual(icons.unit:IsShown(), true, "a row with a class but no spec drew nothing")
    local c = inst.mocks.CLASS_ICON_TCOORDS.MAGE
    assertEqual(select(1, icons.unit:GetTexCoord()), c[1], "the fallback is not the class icon")
end)

test("A ROLE icon is never drawn, whatever the row carries", function()
    -- Three roles across a whole raid identifies nobody, and it was the icon
    -- most likely to be on screen when the name column ran out of room.
    -- red under: any surviving role branch.
    local _, window, row = bench()
    row:ApplyLayout(window.layout)

    -- Built directly rather than through `entry`, which defaults a class in —
    -- and a row WITH a class would legitimately draw the class icon, so the
    -- fixture has to have neither for the assertion to mean anything.
    row:Update({ guid = "Creature-0-1", name = "Some Add", role = "TANK",
                 maxAmount = 1, values = { DamageDone = { total = 1, maxAmount = 1 } },
                 cells = { DamageDone = { total = 1, maxAmount = 1 } } }, 1)

    local icons = row.nameCell.icons
    assertEqual(icons.role, nil, "a role slot still exists")
    assertEqual(icons.unit:IsShown(), false,
        "a row with only a role drew an icon, so the role ladder survived")
end)

test("A breakdown row draws the SPELL's icon, not a unit's", function()
    -- The rung that is first because the row is not a unit at all: it has no
    -- class, no spec and no role, and its `icon` is the spell's own file id.
    -- This branch lived inside the old class drawer and would have been deleted
    -- with it.
    -- red under: dropping the isDrillDown branch from drawUnitIcon.
    local _, window, row = bench()
    row:ApplyLayout(window.layout)

    row:Update({ guid = "spell:101", name = "Fireball", isDrillDown = true,
                 icon = 135808, classFilename = "MAGE", specIconID = 135771,
                 maxAmount = 1, values = { DamageDone = { total = 1 } } }, 1)

    assertEqual(row.nameCell.icons.unit:GetTexture(), 135808,
        "a breakdown row drew a unit icon instead of its spell's")
end)

test("Turning the icon off hides it rather than destroying it", function()
    -- The pool's whole premise is that widget creation happens once.
    -- red under: rebuilding the icon set on a config change.
    local _, window, row, cfg = bench()
    row:ApplyLayout(window.layout)
    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } },
        { classFilename = "MAGE", specIconID = 135771 }), 1)
    assertEqual(row.nameCell.icons.unit:IsShown(), true)

    cfg.icons.showIcon = false
    row:ApplyLayout(window.layout)
    assertEqual(row.nameCell.icons.unit:IsShown(), false,
        "an icon turned off is hidden, not destroyed")
end)

-- ---------------------------------------------------------------------------
-- Highlights, mouse and the pool contract
-- ---------------------------------------------------------------------------

test("highlightSelf honors both spellings of 'this row is you'", function()
    local _, _, row = bench(function(cfg) cfg.rows.highlightSelf = true end)

    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } }, { isPlayer = true }), 1)
    assertEqual(row.selfHighlight:IsShown(), true)

    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } }, { isPlayer = false }), 1)
    assertEqual(row.selfHighlight:IsShown(), false)

    -- modules/DrillDown.lua and the API's own source rows say `isLocalPlayer`.
    local drill = { guid = "g", name = "n", isLocalPlayer = true, role = "NONE",
                    values = { DamageDone = { total = 1, maxAmount = 1 } } }
    drill.cells = drill.values
    row:Update(drill, 1)
    assertEqual(row.selfHighlight:IsShown(), true)
end)

test("The class tint is painted on the CELLS, not on the row", function()
    -- It lived on the row briefly and tinted the two-pixel seams between columns
    -- along with the cells, which lost the column separators the grid is read by.
    -- Painting each cell leaves the seams clear.
    -- red under: SetColorTexture on row.bg instead of cell.bg.
    local inst, _, row = bench()
    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } },
        { classFilename = "MAGE" }), 1)

    local c = inst.mocks.RAID_CLASS_COLORS.MAGE
    local bg = row.cells.DamageDone.bg
    assertEqual(bg:IsShown(), true)
    assertEqual(bg.__colorTexture[1], c.r)
    assertEqual(bg.__colorTexture[4], 0.1, "a tint, not a second bar")
end)

test("A row with no class falls back to the alternating stripe", function()
    -- NPCs, enemies, unattributed pets and drill-down spells land here. Inventing
    -- a color for them would put a meaningless hue on the rows a player is least
    -- able to explain.
    local _, _, row = bench(function(cfg) cfg.rows.alternatingBackground = true end)
    local e = entry({ DamageDone = { total = 1, maxAmount = 1 } },
        { classFilename = false })
    e.classFilename = nil

    row:Update(e, 1)
    assertEqual(row.bg:IsShown(), false, "odd row, no stripe")
    row:Update(e, 2)
    assertEqual(row.bg:IsShown(), true, "even row, striped")
end)

test("The class tint can be switched off", function()
    local _, _, row = bench(function(cfg) cfg.bars.bgColorMode = "none" end)
    row:Update(entry({ DamageDone = { total = 1, maxAmount = 1 } },
        { classFilename = "MAGE" }), 1)
    assertEqual(row.cells.DamageDone.bg.__colorTexture[4], 0, "no tint at all")
end)

test("The mouseover overlay is driven from the CELLS, and honors the setting", function()
    local _, _, row = bench(function(cfg) cfg.rows.mouseoverHighlight = true end)
    row:SetMouseOver(true)
    assertEqual(row.mouseHighlight:IsShown(), true)
    row:SetMouseOver(false)
    assertEqual(row.mouseHighlight:IsShown(), false)

    row.window.config.rows.mouseoverHighlight = false
    row:SetMouseOver(true)
    assertEqual(row.mouseHighlight:IsShown(), false)
end)

test("On the grid the mouse goes to every cell, including the name cell", function()
    local _, _, row = bench()

    row:EnableCellMouse()
    assertEqual(row.nameCell.frame:IsMouseEnabled(), true)
    for _, cell in pairs(row.cells) do
        assertEqual(cell.frame:IsMouseEnabled(), true)
    end
    assertEqual(row.frame:IsMouseEnabled(), true, "the row wants the seams either way")
end)

test("Release blanks the row without destroying a widget", function()
    local _, _, row = bench()
    row:Update(entry{ DamageDone = { total = 4200000, maxAmount = 4200000 } }, 1)
    assertEqual(row.frame:IsShown(), true)

    local bar = row.cells.DamageDone.frame
    row:Release()

    assertNil(row.entry)
    assertNil(row.index)
    assertEqual(row.frame:IsShown(), false)
    assertEqual(row.cells.DamageDone.left:GetText(), "")
    assertEqual(bar:GetValue(), 0)
    assertTrue(row.cells.DamageDone.frame == bar, "the widget survives; the pool re-uses it")
    assertNil(row.cells.DamageDone.entry, "and holds no reference to the player it drew")
end)

-- ---------------------------------------------------------------------------
-- Mouse hand-off
-- ---------------------------------------------------------------------------

test("Hovering a stat cell asks the tooltip the narrow question", function()
    local inst, _, row, cfg = bench()
    local seen
    inst.NS.Tooltip.CellTooltip = function(_, e, key) seen = { e, key } end
    inst.NS.Tooltip.NameTooltip = function() seen = { "name" } end

    row:Update(entry{ DamageDone = { total = 1, maxAmount = 1 } }, 1)
    row.cells.DamageDone.frame:_run("OnEnter")

    assertEqual(seen[2], "DamageDone")
    assertTrue(seen[1] == row.entry)

    -- Hovering the NAME cell summarizes every stat, which is the cross-column
    -- read the whole addon exists for.
    row.nameCell.frame:_run("OnEnter")
    assertEqual(seen[1], "name")

    cfg.tooltip.showAllStatsOnName = false
    seen = nil
    row.nameCell.frame:_run("OnEnter")
    assertNil(seen, "the setting switches the summary off entirely")
end)

test("Clicking a stat cell routes to the drill-down; the name cell does not", function()
    local inst, _, row = bench()
    local clicks = {}
    inst.NS.DrillDown.OnCellClick = function(_, _, _, key) clicks[#clicks + 1] = key end

    row:Update(entry{ DamageDone = { total = 1, maxAmount = 1 } }, 1)
    row.cells.DamageDone.frame:_run("OnMouseUp")
    assertEqual(#clicks, 1)
    assertEqual(clicks[1], "DamageDone")

    -- The name column's question is "how is this player doing overall", which
    -- the tooltip already answers.
    row.nameCell.frame:_run("OnMouseUp")
    assertEqual(#clicks, 1)
end)

test("A cell with no entry does nothing under the cursor", function()
    local inst, _, row = bench()
    local touched = false
    inst.NS.Tooltip.CellTooltip = function() touched = true end
    inst.NS.DrillDown.OnCellClick = function() touched = true end

    row:Release()
    row.cells.DamageDone.frame:_run("OnEnter")
    row.cells.DamageDone.frame:_run("OnMouseUp")
    assertFalse(touched)
end)

-- ---------------------------------------------------------------------------
-- Inside a breakdown, the row is a SPELL
-- ---------------------------------------------------------------------------
--
-- The rows of a drill-down are spells, and the two player tooltips answer the
-- wrong question about one. Both answers were honest and both were useless: the
-- cell tooltip asked the provider for a spell breakdown OF a spell and rendered
-- "No data yet"; the name tooltip listed every tracked statistic for a source
-- that is not a source and rendered a column of zeros.

local function spellEntry(opts)
    opts = opts or {}
    local e = entry({ DamageDone = { total = 9900 } },
        { guid = "spell:49998", name = "Death Strike", isDrillDown = true })
    e.spellID = opts.spellID ~= false and (opts.spellID or 49998) or nil
    return e
end

test("Hovering a breakdown ROW shows the client's spell tooltip", function()
    -- The ROW, not a cell: a breakdown row is one thing rather than a grid of
    -- independent numbers, so the whole of it asks one question and one frame
    -- owns the answer.
    -- red under: routing a drill row to CellTooltip / NameTooltip.
    local inst, _, row = bench()
    row:Update(spellEntry(), 1)

    row.frame:_run("OnEnter")
    assertEqual(inst.mocks.GameTooltip.__spellID, 49998,
        "the row did not hand the client a spell id")
end)

test("A breakdown row takes the mouse, and its cells give theirs up", function()
    -- WHY THE ROW TOOLTIP SHIPPED DEAD. A cell is a child of the row frame and
    -- so sits ON TOP of it, and a mouse-enabled frame consumes motion — so
    -- rowOnEnter fired only in the seams between cells and in the margin past
    -- the last column. Letting the motion through is not an option: the API for
    -- it is protected and the client answers ADDON_ACTION_BLOCKED. So the cells
    -- give the mouse up, which costs nothing because a breakdown cell has no job
    -- left. The harness calls `_run("OnEnter")` directly and never hit-tests,
    -- which is why every tooltip case here stayed green while the client showed
    -- nothing.
    -- red under: dropping the drill branch from RowProto:ApplyMouse.
    local _, _, row = bench()
    row:Update(spellEntry(), 1)

    assertEqual(row.frame:IsMouseEnabled(), true, "the row did not take the mouse")
    assertEqual(row.nameCell.frame:IsMouseEnabled(), false,
        "the name cell kept the mouse and shadows the row")
    for key, cell in pairs(row.cells) do
        assertEqual(cell.frame:IsMouseEnabled(), false,
            "cell " .. key .. " kept the mouse and shadows the row")
    end

    -- And back again: a pooled row re-pointed at a player is a grid row.
    row:Update(entry{ DamageDone = { total = 10 } }, 1)
    assertEqual(row.nameCell.frame:IsMouseEnabled(), true,
        "the cells never got the mouse back on the way out of a breakdown")
end)

test("Hovering a breakdown row lights its highlight, since no cell can", function()
    -- red under: dropping SetMouseOver from rowOnEnter/rowOnLeave.
    local _, _, row = bench()
    row:Update(spellEntry(), 1)

    -- Explicitly down first. The overlay's resting state is already hidden, so
    -- an OnEnter that does nothing at all looks exactly like a pass otherwise —
    -- which is how the first draft of this case went green against the bug.
    row:SetMouseOver(false)
    assertEqual(row.mouseHighlight:IsShown(), false, "the bench did not start dark")

    row.frame:_run("OnEnter")
    assertEqual(row.mouseHighlight:IsShown(), true)
    row.frame:_run("OnLeave")
    assertEqual(row.mouseHighlight:IsShown(), false)
end)

test("Crossing a cell boundary does NOT blink the breakdown tooltip", function()
    -- THE FLICKER. Each cell has its own OnEnter/OnLeave, so dragging the cursor
    -- sideways across a row fired hide-then-show at every seam — a tooltip
    -- blinking for no reason the player can see, on a row where every cell
    -- describes the same spell.
    -- red under: cellOnLeave hiding the tooltip for a drill row.
    local inst, _, row = bench()
    row:Update(spellEntry(), 1)

    row.frame:_run("OnEnter")
    assertEqual(inst.mocks.GameTooltip.__spellID, 49998)

    -- The cursor moves from one cell to the next, inside the same row.
    row.cells.DamageDone.frame:_run("OnEnter")
    row.cells.DamageDone.frame:_run("OnLeave")
    row.cells.Interrupts.frame:_run("OnEnter")

    assertTrue(inst.mocks.GameTooltip:IsShown(),
        "a cell seam hid the tooltip the row is still hovering")
    assertEqual(inst.mocks.GameTooltip.__spellID, 49998,
        "and it is still the same spell")
end)

test("Leaving the row hides the breakdown tooltip", function()
    -- The other half: the row owns the hide too, or the tooltip never goes away.
    -- red under: rowOnLeave not calling Tooltip:Hide.
    local inst, _, row = bench()
    row:Update(spellEntry(), 1)
    row.frame:_run("OnEnter")
    assertTrue(inst.mocks.GameTooltip:IsShown())

    row.frame:_run("OnLeave")
    assertFalse(inst.mocks.GameTooltip:IsShown(), "the tooltip outlived the row hover")
end)

test("On the GRID a cell still owns its own tooltip", function()
    -- Each column asks a different question there, so per-cell is correct rather
    -- than a bug — the row-level behaviour must not leak out of the breakdown.
    -- red under: giving every row the spell tooltip.
    local inst, _, row = bench()
    local seen
    inst.NS.Tooltip.CellTooltip = function(_, _, key) seen = key end

    row:Update(entry{ DamageDone = { total = 1, maxAmount = 1 } }, 1)
    row.cells.DamageDone.frame:_run("OnEnter")
    assertEqual(seen, "DamageDone", "a grid cell stopped showing its own tooltip")
end)

test("A breakdown row with no resolvable spell still says which spell it is", function()
    -- An empty tooltip frame is worse than a plain one. The row is still telling
    -- the player something even when the client cannot name the spell.
    -- red under: returning early when spellID is nil.
    local inst, _, row = bench()
    row:Update(spellEntry{ spellID = false }, 1)
    row.frame:_run("OnEnter")

    assertNil(inst.mocks.GameTooltip.__spellID)
    local lines = inst.mocks.GameTooltip.__lines
    assertTrue(#lines > 0, "an unresolvable spell produced an empty tooltip")
    assertEqual(lines[1].text, "Death Strike")
end)

test("A left click inside a breakdown does nothing", function()
    -- It used to reach OnCellClick with a spell row, which asked the provider
    -- for a breakdown of a spell, got nothing, and rendered an EMPTY WINDOW —
    -- which reads as a broken addon rather than as "there is nothing here".
    -- red under: falling through to DrillDown:OnCellClick.
    local inst, _, row, cfg = bench()
    row:Update(spellEntry(), 1)

    local calls = 0
    local real = inst.NS.DrillDown.OnCellClick
    inst.NS.DrillDown.OnCellClick = function(...) calls = calls + 1; return real(...) end

    row.cells.DamageDone.frame:_run("OnMouseUp", "LeftButton")
    assertEqual(calls, 0, "a left click on a spell row still tried to drill into it")
    assertTrue(cfg ~= nil)
end)

test("A right click leaves the breakdown", function()
    -- The only way out that does not require finding the cell you came in on.
    -- red under: OnMouseUp ignoring the button argument.
    local inst, _, row, cfg = bench()
    local D = inst.NS.DrillDown

    D:Enter(cfg, entry({ DamageDone = { total = 100 } }), "DamageDone")
    assertTrue(D.IsActive(cfg), "the fixture never entered a breakdown")

    row:Update(spellEntry(), 1)
    row.cells.DamageDone.frame:_run("OnMouseUp", "RightButton")

    assertFalse(D.IsActive(cfg), "right click did not leave the breakdown")
end)

test("A right click on the ROW ITSELF leaves the breakdown", function()
    -- Distinct from the cell case, and not covered by it: the cells do not tile
    -- the row. There are seams between them and a margin past the last column,
    -- and a right-click landing in one of those used to do nothing at all.
    -- red under: dropping rowOnMouseUp from the row frame.
    local inst, _, row, cfg = bench()
    local D = inst.NS.DrillDown

    D:Enter(cfg, entry({ DamageDone = { total = 100 } }), "DamageDone")
    assertTrue(D.IsActive(cfg), "the fixture never entered a breakdown")

    row:Update(spellEntry(), 1)
    row.frame:_run("OnMouseUp", "RightButton")

    assertFalse(D.IsActive(cfg), "a right click on the row's own frame did nothing")
end)

test("A right click on the GRID is a harmless no-op", function()
    -- Exit answers false when there is no view to leave, so a stray right click
    -- costs nothing and needs no special case at the call site.
    -- red under: an Exit that errors or a handler that drills on right click.
    local inst, _, row, cfg = bench()
    row:Update(entry({ DamageDone = { total = 100 } }), 1)

    row.cells.DamageDone.frame:_run("OnMouseUp", "RightButton")
    assertFalse(inst.NS.DrillDown.IsActive(cfg), "a right click on the grid opened something")
end)

test("Cells register for BOTH buttons, or the right click never arrives", function()
    -- A right-click handler on a frame that never called RegisterForClicks is a
    -- silent failure: the code is correct and the client never calls it.
    -- red under: dropping the RegisterForClicks call.
    local _, _, row = bench()
    local clicks = row.cells.DamageDone.frame.__clicks
    assertTrue(clicks ~= nil, "the cell never registered for clicks at all")

    local seen = {}
    for _, b in ipairs(clicks) do seen[b] = true end
    assertTrue(seen["LeftButtonUp"], "left clicks are not registered")
    assertTrue(seen["RightButtonUp"], "right clicks are not registered")
end)

-- ---------------------------------------------------------------------------
-- cell.displayText — a cell whose figure is not a number (issue #1)
-- ---------------------------------------------------------------------------
--
-- A death row's Deaths cell shows the wall-clock time the player died, with a
-- full bar behind it. That is a string this addon composed, not a meter value,
-- so it bypasses the number formatter entirely rather than being squeezed
-- through it. Every other cell leaves the field nil and renders exactly as it
-- always has, which is what the third case below pins.

--- A death row as modules/DrillDown.lua builds one.
local function deathEntry(displayText)
    return entry({ DamageDone = { total = 1, rate = 99, percent = 50,
                                  maxAmount = 1, displayText = displayText } },
        { guid = "death:29", name = "Death 3", isDrillDown = true, maxAmount = 1 })
end

test("Row: a cell renders displayText in place of its number", function()
    -- red under: primary being taken only from slotText/renderValue.
    local _, _, row = bench()
    row:Update(deathEntry("13:01:06"), 1)
    assertEqual(row.cells.DamageDone.left:GetText(), "13:01:06")
end)

test("Row: displayText wins over BOTH slots and over the fallback", function()
    -- The shipped default is leftSlot="none", rightSlot="rate". A death row
    -- under that profile would render the rate — or, with both slots off, fall
    -- back to the total and print the number 1 where the time should be.
    -- red under: applying the override before the slot resolution rather than
    -- after it.
    local _, _, row = bench(function(cfg)
        cfg.text = cfg.text or {}
        cfg.text.leftSlot, cfg.text.rightSlot = "percent", "rate"
    end)
    row:Update(deathEntry("12:49:43"), 1)
    assertEqual(row.cells.DamageDone.left:GetText(), "12:49:43")
    assertEqual(row.cells.DamageDone.right:GetText(), "",
        "a second figure beside the time would read as two columns")
end)

test("Row: a cell with no displayText is completely unaffected", function()
    -- The belt. Every cell in every ordinary row leaves the field nil, and the
    -- override must be invisible to all of them.
    -- red under: `primary = displayText or primary`, which is a truth test and
    -- would also fire on an empty string.
    local _, _, row = bench(function(cfg)
        cfg.text = cfg.text or {}
        cfg.text.leftSlot, cfg.text.rightSlot = "total", "none"
    end)
    row:Update(entry({ DamageDone = { total = 1234, maxAmount = 2000 } }), 1)
    assertTrue(row.cells.DamageDone.left:GetText() ~= "",
        "an ordinary cell lost its number")
end)

test("Row: a death row's bar draws FULL without comparing anything", function()
    -- total == maxAmount is arranged in the DATA, deliberately, so this file
    -- never has to compare two values that are secret on every other row.
    -- red under: a `total == maxAmount` branch in Cell:SetValue.
    local _, _, row = bench()
    row:Update(deathEntry("13:01:06"), 1)
    local bar = row.cells.DamageDone.frame
    local mn, mx = bar:GetMinMaxValues()
    assertEqual(mn, 0)
    assertEqual(mx, 1)
    assertEqual(bar:GetValue(), 1)
end)
