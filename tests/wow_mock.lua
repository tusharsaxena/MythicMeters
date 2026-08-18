-- tests/wow_mock.lua
--
-- Ka0s Mythic Meters' half of the WoW-API mock, layered over the shared base in
-- tests/_kit/mock_base.lua (testing-§1).
--
-- Returns a BUILDER — `mockmod.build()` — so every instance gets a fresh, fully
-- isolated fake client. Nothing is shared between two builds: not the meter data,
-- not the frame registry, not LibStub's library table.
--
-- ---------------------------------------------------------------------------
-- WHAT THE BASE CONTRIBUTES, AND WHAT THIS FILE ADDS
-- ---------------------------------------------------------------------------
--
-- build() starts from the vendored base builder and then OVERWRITES PER KEY, per
-- the kit's README. There is no merge machinery, because the base hands back a
-- fresh table on every call.
--
-- Inherited from the base and used as-is: `time`, `date`, `GetTime`, `wipe`,
-- `tinsert`, `tremove`, `C_Timer`, `debugprofilestop` + `__profileMs`, the
-- Settings canvas registry (`Settings`, `__mainPanel`, `__subcategories`,
-- `SettingsPanel`, `__settingsClosed`), `hooksecurefunc`, `CreateColor`,
-- `PlaySound`, `StaticPopupDialogs` / `StaticPopup_Show`, `UISpecialFrames`,
-- `DEFAULT_CHAT_FRAME`, the AceDB-3.0 fake (whose copyDefaults reproduces AceDB's
-- real merge-in-place semantics, which core/Database.lua's `== nil` window fill
-- depends on), the AceGUI-3.0 widget factory, and LibStub itself — including its
-- STRICT silent flag, which is what proves every soft-optional
-- `LibStub("LibKa0s-...-1.0", true)` in this addon actually passed `true`.
--
-- Overwritten here, and why:
--
--   * THE FRAME MODEL. The base's frame stub answers any PascalCase method from
--     a metatable and returns THE FRAME ITSELF, so `bar:CreateFontString()` and
--     the bar are one object and "which widget got the text" is unanswerable.
--     This addon's whole output is text and bar values written onto per-cell
--     FontStrings and StatusBars (modules/Row.lua), so distinct region objects
--     with REAL STATE are a correctness requirement here, exactly as they are in
--     KickCD and WhatGroup. The base's own header names this as a divergence it
--     expects consumers to make in their own extender.
--   * THE ACE MODULE LIFECYCLE. Seven of this addon's modules are
--     `NS:NewModule(name, "AceEvent-3.0")` children, and the base's AceAddon fake
--     has no NewModule / GetModule at all. Without them not one module file
--     loads.
--   * THE MESSAGE BUS. The base's AceEvent fake has RegisterMessage /
--     UnregisterMessage / SendMessage but no `UnregisterAllMessages`, which
--     modules/Provider.lua's Suspend and modules/Window.lua's UnregisterBus both
--     call. The fake is replaced rather than patched so the (message, target)
--     fan-out and the teardown live in one readable place.
--   * `C_AddOns`. The base deliberately does not stub it (see its header). This
--     addon reads the TOC manifest through it for NS.version and for the perf
--     descriptor's record stamp, so it is stubbed HERE, where a test that wants
--     the deprecated-global fallback can clear it with `mocks.C_AddOns = nil`.
--     Clearing `_G.C_AddOns` is NOT enough: `mocks._G` is the loader environment,
--     so `_G.C_AddOns` resolves back through this table.
--   * `string` / `format`. See THE SECRET SIMULATOR below.
--
-- ---------------------------------------------------------------------------
-- THE SECRET SIMULATOR — the most valuable thing in this file
-- ---------------------------------------------------------------------------
--
-- While WoW 12.0's Combat addon restriction is active, every number this addon
-- displays arrives as a SECRET VALUE. Tainted code — all of ours — may store one,
-- pass it, put it in a table VALUE, hand it to StatusBar:SetValue /
-- FontString:SetText, and hand it to a native formatter. It may NOT compare it,
-- do arithmetic on it, boolean-test it, use it as a table KEY, apply `#` to it,
-- or index it.
--
-- `mocks.secret(v)` returns a TABLE whose metatable raises a recognizable error
-- from every one of those forbidden operations, so an illegal line anywhere in
-- the addon fails the test LOUDLY instead of quietly passing on a plain number.
-- That is the whole point: without it, a suite that "proves" the never-inspect
-- rule proves nothing, because a plain number satisfies every assertion a secret
-- would have failed.
--
-- WHAT CANNOT BE TRAPPED IN LUA 5.1, stated rather than pretended:
--
--   * `__eq` is only consulted when BOTH operands are tables of the same
--     metatable. `secret == nil`, `secret == 0` and `secret == "x"` are answered
--     false by the VM without any metamethod running. That is fine — nil-ness
--     testing is the one permitted boolean-shaped operation on a non-boolean
--     secret, and it is what modules/Row.lua and modules/Format.lua rely on — but
--     it does mean an ILLEGAL `secret == someOtherValue` cannot be caught here.
--   * TRUTH TESTING (`if secret then`, `secret and x`, `not secret`) has no
--     metamethod in any Lua version. A table is always truthy, so
--     `if src.totalAmount then` passes here and raises in the client. There is no
--     way to close that from Lua; the guard against it is review and the
--     `== nil` idiom the source files use everywhere.
--   * `__len` IS DEFINED BELOW AND LUA 5.1 IGNORES IT. In 5.1 the length operator
--     consults a metamethod only for userdata, never for a table, so `#secret`
--     quietly answers 0 here and raises in the client. The metamethod is kept so
--     the trap becomes live the day this harness moves to 5.2+, and because a
--     reader looking for "is `#` covered?" should find an answer rather than a
--     silence — but `#` is NOT a caught mistake today. The real defense is
--     core/Secrets.lua's SafeIterate / SafeCount, which never apply the operator
--     at all, and `mocks.secretTable(t)` below, whose INDEXING trap does fire and
--     therefore catches any walk that skipped the CanAccessTable guard.
--   * A SECRET USED AS A TABLE KEY is legal Lua and cannot be trapped: `t[secret]`
--     is an ordinary hash lookup on a table reference. The addon's defense is
--     structural — modules/Aggregator.lua joins on `sourceGUID`, which is the one
--     field the client never makes secret, and the mock never wraps it.
--   * A MIXED-TYPE COMPARISON (`secret < 5`) raises, but with Lua's own "attempt
--     to compare number with table" rather than the tagged message: the VM
--     rejects the operand types before any metamethod runs. Two secrets compared
--     against each other do reach `__lt` / `__le` and produce the tagged error.
--     Either way it fails loudly, which is the point; a suite matching on
--     `mocks.SECRET_ERROR` should use two secrets.
--   * `type(secret)` answers "table", where the client answers the underlying
--     type. Every `type(x) ~= "number"` guard in modules/Aggregator.lua and
--     modules/Format.lua therefore takes its REFUSAL branch under simulation,
--     which is the behavior those guards exist to produce while restricted — so
--     the divergence lands on the correct side.
--   * `string.format("%s", secret)` and `tostring(secret)`: the client permits
--     both (they yield a secret STRING). Lua 5.1's `string.format` calls
--     `luaL_checklstring`, which does not honor `__tostring` and raises on a
--     table. Rather than pretend, this file publishes `mocks.string` — a
--     pass-through of the real string library whose `format` substitutes each
--     simulated secret with the value behind it — and `mocks.format` alongside
--     it. Addon chunks resolve `string` and `format` through the loader
--     environment, so they get the faithful behavior; nothing else in the process
--     is touched.
--   * `table.concat` REALLY DOES raise on a table element in stock Lua 5.1, with
--     no help from this file. That is the exact probe core/CoreSetup.lua's
--     IsConcatSafe uses, so the degradation path it guards is genuinely
--     exercised.
--
-- `__concat` IS trapped, which is stricter than the live client (where `..` on a
-- secret yields a secret string). It is trapped deliberately: `..` is the one
-- forbidden-adjacent operation a well-meaning refactor reaches for, every call
-- site in this addon that concatenates a possibly-secret value already guards it
-- (`pcall` in modules/Format.lua, `NS.IsConcatSafe` in modules/Row.lua), and a
-- trap there turns "somebody removed the guard" into a failing test.
--
-- ---------------------------------------------------------------------------
-- THE CONTROL SURFACE, in one place
-- ---------------------------------------------------------------------------
--
-- Secrets      mocks.secret(v) · mocks.secretTable(t) · mocks.reveal(v)
--              mocks.isSimulatedSecret(v) · mocks.SECRET_ERROR
--              mocks.setRestricted(b) · mocks.setSecretValues(b)
--              mocks.setSecretsAccessible(b) · mocks.setRestrictionState(n)
-- Meter        mocks.setMeterAvailable(ok, reason) · mocks.setSession(...)
--              mocks.setSourceDetail(...) · mocks.buildSession(opts)
--              mocks.setSessionDuration(...) · mocks.setAvailableSessions(list)
--              mocks.resetMeterCalls() · mocks.__meter
-- Menus        mocks.MenuUtil · mocks.__lastMenu (root:Nth(kind, n))
-- Group        mocks.setGroup(spec) · mocks.setPet(unit, guid) · mocks.setSolo()
--              mocks.setInstance(type) · mocks.setInCombat(b)
--              mocks.setInVehicle(b) · mocks.__group
-- Frames       mocks.__frames (creation order) · mocks.__frameByName
--              mocks.__stubFrame(objectType, parent, name)
-- Manifest     mocks.__toc (Version / Title / Notes)
-- Timers       mocks.__timers · mocks.__fireTimers() (base) · mocks.__flushTimers()

local root = ... or "."
local kitMockBase = dofile(root .. "/tests/_kit/mock_base.lua")

-- ===========================================================================
-- The secret simulator
-- ===========================================================================

-- The marker every trap message carries. Suites match on this rather than on a
-- full message so the wording can be improved without breaking a case.
local SECRET_ERROR = "MOCK_SECRET_VIOLATION"

--- The plain value behind a simulated secret. A separate weak-keyed registry
--- rather than a field on the object, because `__index` is trapped and the
--- object therefore cannot be read from at all.
local plainOf = setmetatable({}, { __mode = "k" })

--- Tables that report as SECRET TABLES (issecrettable / canaccesstable), as
--- distinct from tables of secret values. Indexing one raises, which is what
--- makes core/Secrets.lua's CanAccessTable guard in SafeIterate provable.
local secretTables = setmetatable({}, { __mode = "k" })

local function trap(op)
    return function()
        error(SECRET_ERROR .. ": " .. op .. " on a secret value — tainted code may store, pass, "
            .. "table-value and widget-set a secret and may do nothing else (design rule R1)", 2)
    end
end

-- Every forbidden operation, and only those. `__eq` is absent on purpose: see the
-- header — the VM never consults it against nil or a number, and `== nil` is the
-- one test the addon is allowed to make.
local secretMeta = {
    __lt     = trap("<"),
    __le     = trap("<="),
    __add    = trap("+"),
    __sub    = trap("-"),
    __mul    = trap("*"),
    __div    = trap("/"),
    __mod    = trap("%"),
    __pow    = trap("^"),
    __unm    = trap("unary -"),
    __len    = trap("#"),
    __concat = trap(".."),
    __index  = trap("indexing"),
    -- Assignment is trapped too: a secret is not a container, and an addon that
    -- caches something onto one has confused a value for a table.
    __newindex = trap("field assignment"),
    -- Honored by tostring() but NOT by string.format in 5.1 (header).
    __tostring = function() return "<secret>" end,
}

local secretTableMeta = {
    __index    = trap("indexing a secret table"),
    __newindex = trap("assigning into a secret table"),
    __len      = trap("# on a secret table"),
    __tostring = function() return "<secret table>" end,
}

--- Wrap `v` so it behaves like a WoW 12.0 secret value.
---
--- nil passes through unchanged: "absent" and "present but opaque" are different
--- facts, and every consumer in this addon tells them apart with `== nil`.
local function secret(v)
    if v == nil then return nil end
    local s = setmetatable({}, secretMeta)
    plainOf[s] = v
    return s
end

--- Wrap `t` so it reports as a secret TABLE and raises on any index.
local function secretTable(t)
    local s = setmetatable({}, secretTableMeta)
    secretTables[s] = t or {}
    return s
end

local function isSimulatedSecret(v)
    return plainOf[v] ~= nil
end

local function isSimulatedSecretTable(t)
    return secretTables[t] ~= nil
end

--- The value behind a simulated secret, or the argument itself when it is plain.
--- This is what a NATIVE seam is allowed to do — the numeric rule formatter, a
--- StatusBar's C side — and what a suite uses to assert what a widget was handed.
local function reveal(v)
    local p = plainOf[v]
    if p ~= nil then return p end
    local t = secretTables[v]
    if t ~= nil then return t end
    return v
end

-- ===========================================================================
-- The frame model
-- ===========================================================================
--
-- Real state for everything this addon's correctness depends on, and a
-- self-returning no-op for everything else. What is modeled, and why:
--
--   VISIBILITY — modules/Window.lua's whole show ladder is observable only if
--     IsShown() can answer false. The base's blanket stub returns the frame,
--     which is permanently truthy.
--   GEOMETRY — the anchor frame's GetPoint round trip IS WindowProto:SavePosition
--     (the file exists to keep that read off a value-carrying widget), so a
--     SetPoint that recorded nothing would make rule R3's payoff untestable.
--   TEXT / FONT / COLOR — the cells and the header line are the addon's entire
--     visible output.
--   STATUS BAR values — `SetValue` / `SetMinMaxValues` are where a secret ends
--     up. Recording them raw is how a suite proves the handle reached the widget
--     without anything having looked at it.
--   BACKDROP — modules/Window.lua's ApplyBorder branches on `frame.SetBackdrop`
--     and writes a table whose edgeFile/edgeSize encode the "borderSize == 0
--     means no edge" rule.
--
-- Numeric getters that are NOT modeled return real numbers, never the frame:
-- LibKa0s-Options-1.0's always-shown-scrollbar patch does arithmetic on
-- GetHeight() and concatenates GetName(), and a table in either place raises
-- inside the library on the first panel render (kit fidelity rule 2).

local NUMERIC_GETTERS = {
    GetLeft = 0, GetRight = 0, GetTop = 0, GetBottom = 0,
    GetStringWidth = 0, GetStringHeight = 0,
    GetTextWidth = 0, GetTextHeight = 0,
    GetNumRegions = 0, GetNumChildren = 0,
    GetID = 0,
}

local makeFrame  -- forward declaration; regions are frames too

--- Normalize SetPoint's two overloads into one record. Both forms are used by
--- modules/Window.lua (`SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -5)`) and by
--- modules/Row.lua (`SetPoint("LEFT", bar, "LEFT", 2, 0)`).
local function recordPoint(point, a, b, c, d)
    if type(a) == "number" or a == nil then
        return { point = point, relativeTo = nil, relativePoint = point, x = a or 0, y = b or 0 }
    end
    return { point = point, relativeTo = a, relativePoint = b or point, x = c or 0, y = d or 0 }
end

local FRAME = {}

-- ── visibility ─────────────────────────────────────────────────────────────
function FRAME.Show(self)
    local was = self.__shown
    self.__shown = true
    if not was then self:_run("OnShow") end
    return self
end
function FRAME.Hide(self)
    local was = self.__shown
    self.__shown = false
    if was then self:_run("OnHide") end
    return self
end
function FRAME.SetShown(self, v)
    if v then self:Show() else self:Hide() end
    return self
end
function FRAME.IsShown(self) return self.__shown end
--- Shown AND every ancestor shown — the distinction that matters once a row is
--- parented onto a hidden window body.
function FRAME.IsVisible(self)
    local f = self
    while f do
        if not f.__shown then return false end
        f = f.__parent
    end
    return true
end

-- ── geometry ───────────────────────────────────────────────────────────────
function FRAME.SetPoint(self, point, a, b, c, d)
    self.__points[#self.__points + 1] = recordPoint(point, a, b, c, d)
    return self
end
function FRAME.ClearAllPoints(self) self.__points = {}; return self end
function FRAME.GetNumPoints(self) return #self.__points end
function FRAME.GetPoint(self, i)
    local p = self.__points[i or 1]
    if not p then return nil end
    return p.point, p.relativeTo, p.relativePoint, p.x, p.y
end
function FRAME.SetAllPoints(self, rel)
    self.__allPoints = rel or self.__parent or true
    return self
end
function FRAME.SetSize(self, w, h) self.__w, self.__h = w or 0, h or 0; return self end
function FRAME.SetWidth(self, w) self.__w = w or 0; return self end
function FRAME.SetHeight(self, h) self.__h = h or 0; return self end
function FRAME.GetWidth(self) return self.__w end
function FRAME.GetHeight(self) return self.__h end
function FRAME.GetSize(self) return self.__w, self.__h end
function FRAME.SetScale(self, s) self.__scale = s or 1; return self end
function FRAME.GetScale(self) return self.__scale end
function FRAME.GetEffectiveScale(self)
    local s, f = 1, self
    while f do
        s = s * (f.__scale or 1)
        f = f.__parent
    end
    return s
end
function FRAME.SetAlpha(self, a) self.__alpha = a or 1; return self end
function FRAME.GetAlpha(self) return self.__alpha end
function FRAME.SetFrameStrata(self, v) self.__strata = v; return self end
function FRAME.GetFrameStrata(self) return self.__strata end
function FRAME.SetFrameLevel(self, v) self.__level = v or 0; return self end
function FRAME.GetFrameLevel(self) return self.__level end

-- ── identity / parenting ───────────────────────────────────────────────────
--- Always a STRING (kit fidelity rule 2). An anonymous frame gets a synthetic
--- unique name rather than nil, because the scrollbar patch concatenates it.
function FRAME.GetName(self) return self.__name end
function FRAME.GetObjectType(self) return self.__objectType end
function FRAME.SetParent(self, p) self.__parent = p; return self end
function FRAME.GetParent(self) return self.__parent end

-- ── movement / sizing ──────────────────────────────────────────────────────
--
-- Recorded rather than no-opped: modules/Window.lua's drag and resize handlers
-- are the ONLY place in the addon permitted to read geometry back off a widget,
-- and the whole two-frame anchor design exists so that read lands on a frame
-- that never held a value. A test proves that by seeing StartMoving land on
-- `inst.anchor` and never on `inst.frame`.
function FRAME.SetMovable(self, v) self.__movable = v and true or false; return self end
function FRAME.SetResizable(self, v) self.__resizable = v and true or false; return self end
function FRAME.SetClampedToScreen(self, v) self.__clamped = v and true or false; return self end
function FRAME.EnableMouse(self, v) self.__mouseEnabled = v and true or false; return self end
function FRAME.IsMouseEnabled(self) return self.__mouseEnabled and true or false end
function FRAME.RegisterForDrag(self, ...) self.__dragButtons = { ... }; return self end
function FRAME.StartMoving(self) self.__moves = (self.__moves or 0) + 1; return self end
function FRAME.StartSizing(self, point)
    self.__sizings = (self.__sizings or 0) + 1
    self.__lastSizingPoint = point
    return self
end
function FRAME.StopMovingOrSizing(self) self.__stops = (self.__stops or 0) + 1; return self end

-- ── text ───────────────────────────────────────────────────────────────────
--
-- SetText takes the value RAW and stores it raw. That is deliberate and it is
-- the point of the whole harness: a FontString handed a secret keeps the handle,
-- so a suite can assert `mocks.reveal(fs.__text)` without the mock having
-- inspected anything on the addon's behalf.
-- A FONTSTRING WITH NO FONT RAISES ON SetText, exactly as the client does.
--
-- This was silent here for a release and it cost a load: a glyph FontString was
-- built and given its text in the same breath, before anything called SetFont,
-- and the client answered `FontString:SetText(): Font not set` at BuildFrame —
-- taking the whole addon down before a single window existed. Every test passed,
-- because this stub happily stored the string.
--
-- A FontString created FROM A TEMPLATE inherits a font, which is why the check
-- keys on `__font or __template` rather than on `__font` alone; a bare
-- CreateFontString() is the case that has to be caught.
function FRAME.SetText(self, t)
    if self.__objectType == "FontString" and not (self.__font or self.__template) then
        error("FontString:SetText(): Font not set", 2)
    end
    self.__text = t
    return self
end
function FRAME.GetText(self) return self.__text end
--- A PROPORTIONAL-ISH string width, so layout that measures text is testable.
---
--- The numeric-getter default answers 0, which silently disables any code that
--- sizes something from a string — modules/Tooltip.lua widens the tooltip from
--- the longest spell name, and a zero measurement made that whole path look like
--- a no-op that still passed.
---
--- Six pixels a character is close enough for the game's default font at 12pt,
--- and the exact figure does not matter: what a suite asserts is that a wider
--- string produced a wider layout.
---
--- Answers 0 for anything that is not a plain string — a FontString handed a
--- SECRET must not be measured, and a double that measured one anyway would let
--- a rule-R3 violation through.
function FRAME.GetStringWidth(self)
    local t = self.__text
    if type(t) ~= "string" then return 0 end
    return #t * 6
end
function FRAME.SetFormattedText(self, fmt, ...)
    if self.__objectType == "FontString" and not (self.__font or self.__template) then
        error("FontString:SetFormattedText(): Font not set", 2)
    end
    self.__text = fmt and string.format(fmt, ...) or nil
    return self
end
function FRAME.SetFont(self, path, size, flags)
    self.__font = { path = path, size = size, flags = flags }
    return self
end
function FRAME.GetFont(self)
    local f = self.__font
    if not f then return nil end
    return f.path, f.size, f.flags
end
function FRAME.SetTextColor(self, r, g, b, a)
    self.__textColor = { r, g, b, a or 1 }
    return self
end
function FRAME.GetTextColor(self)
    local c = self.__textColor
    if not c then return 1, 1, 1, 1 end
    return c[1], c[2], c[3], c[4]
end
function FRAME.SetJustifyH(self, v) self.__justifyH = v; return self end
function FRAME.GetJustifyH(self) return self.__justifyH end
function FRAME.SetJustifyV(self, v) self.__justifyV = v; return self end
function FRAME.SetShadowOffset(self, x, y) self.__shadow = { x, y }; return self end
function FRAME.SetShadowColor(self, r, g, b, a) self.__shadowColor = { r, g, b, a }; return self end
function FRAME.SetWordWrap(self, v) self.__wordWrap = v; return self end

-- ── textures ───────────────────────────────────────────────────────────────
function FRAME.SetTexture(self, t) self.__texture = t; return self end
function FRAME.GetTexture(self) return self.__texture end
function FRAME.SetAtlas(self, a) self.__atlas = a; return self end
function FRAME.SetTexCoord(self, ...) self.__texCoord = { ... }; return self end
function FRAME.GetTexCoord(self)
    local c = self.__texCoord
    if not c then return nil end
    return c[1], c[2], c[3], c[4]
end
function FRAME.SetColorTexture(self, r, g, b, a)
    self.__colorTexture = { r, g, b, a or 1 }
    return self
end
function FRAME.SetVertexColor(self, r, g, b, a)
    self.__vertexColor = { r, g, b, a or 1 }
    return self
end
function FRAME.SetDrawLayer(self, layer, sub) self.__drawLayer = { layer, sub }; return self end
function FRAME.SetNormalTexture(self, t) self.__normalTexture = t; return self end
function FRAME.SetDesaturated(self, v) self.__desaturated = v and true or false; return self end
function FRAME.SetHitRectInsets(self, l, r, t, b)
    self.__hitRect = { l, r, t, b }
    return self
end
-- Resize bounds, as the client models them: the frame refuses to be sized below
-- the minimum, which is what modules/Window.lua leans on instead of clamping in
-- Lua on every OnSizeChanged tick.
function FRAME.SetResizeBounds(self, minW, minH, maxW, maxH)
    self.__resizeBounds = { minW = minW, minH = minH, maxW = maxW, maxH = maxH }
    return self
end
function FRAME.GetResizeBounds(self)
    local b = self.__resizeBounds
    if not b then return nil end
    return b.minW, b.minH, b.maxW, b.maxH
end
function FRAME.SetHighlightTexture(self, t) self.__highlightTexture = t; return self end
function FRAME.SetPushedTexture(self, t) self.__pushedTexture = t; return self end
function FRAME.SetDisabledTexture(self, t) self.__disabledTexture = t; return self end

-- ── backdrop ───────────────────────────────────────────────────────────────
function FRAME.SetBackdrop(self, b) self.__backdrop = b; return self end
function FRAME.GetBackdrop(self) return self.__backdrop end
function FRAME.SetBackdropColor(self, r, g, b, a)
    self.__backdropColor = { r, g, b, a or 1 }
    return self
end
function FRAME.SetBackdropBorderColor(self, r, g, b, a)
    self.__backdropBorderColor = { r, g, b, a or 1 }
    return self
end

-- ── status bar ─────────────────────────────────────────────────────────────
--
-- The four setters a secret meter value legally reaches. Values are stored
-- UNTOUCHED — no tonumber, no comparison, no default substitution — because the
-- C side is the layer allowed to look and this stub is standing in for it.
function FRAME.SetMinMaxValues(self, mn, mx) self.__min, self.__max = mn, mx; return self end
function FRAME.GetMinMaxValues(self) return self.__min, self.__max end
function FRAME.SetValue(self, v)
    self.__value = v
    self.__setValueCount = (self.__setValueCount or 0) + 1
    -- Mirror the client's HasSecretValues marking: a bar handed a secret has
    -- secret geometry from then on, and rule R3 says nothing may read it back.
    -- Recorded rather than enforced, so a suite can assert the rule rather than
    -- discover it as a crash.
    if isSimulatedSecret(v) then self.__hasSecretValues = true end
    return self
end
function FRAME.GetValue(self) return self.__value end
function FRAME.HasSecretValues(self) return self.__hasSecretValues and true or false end
function FRAME.SetStatusBarColor(self, r, g, b, a)
    self.__barColor = { r, g, b, a or 1 }
    return self
end
function FRAME.GetStatusBarColor(self)
    local c = self.__barColor
    if not c then return 1, 1, 1, 1 end
    return c[1], c[2], c[3], c[4]
end
function FRAME.SetStatusBarTexture(self, t)
    self.__barTexture = t
    if type(t) == "table" then
        self.__barTextureObj = t
    else
        self.__barTextureObj = self.__barTextureObj or makeFrame("Texture", self)
        self.__barTextureObj.__texture = t
    end
    return self
end
function FRAME.GetStatusBarTexture(self)
    self.__barTextureObj = self.__barTextureObj or makeFrame("Texture", self)
    return self.__barTextureObj
end
function FRAME.SetOrientation(self, v) self.__orientation = v; return self end
function FRAME.GetOrientation(self) return self.__orientation end
function FRAME.SetReverseFill(self, v) self.__reverseFill = v and true or false; return self end
function FRAME.GetReverseFill(self) return self.__reverseFill and true or false end

-- ── child regions ──────────────────────────────────────────────────────────
--
-- DISTINCT objects, recorded in creation order. The base returns the parent
-- itself; here a cell's bar, its background texture and its two FontStrings must
-- be four different things or modules/Row.lua's left/right text slots are one
-- slot and every text assertion is vacuous.
local function createRegion(self, objectType, template)
    local r = makeFrame(objectType, self)
    r.__template = template
    self.__regions[#self.__regions + 1] = r
    return r
end
function FRAME.CreateTexture(self, _name, layer, template)
    local r = createRegion(self, "Texture", template)
    r.__layer = layer
    return r
end
function FRAME.CreateFontString(self, _name, layer, template)
    local r = createRegion(self, "FontString", template)
    r.__layer = layer
    r.__template = template
    return r
end
function FRAME.CreateLine(self) return createRegion(self, "Line", nil) end
function FRAME.CreateMaskTexture(self) return createRegion(self, "MaskTexture", nil) end
function FRAME.GetRegions(self) return unpack(self.__regions) end

-- ── scripts / events ───────────────────────────────────────────────────────
--
-- Handlers are STORED, and `_run` / `_fire` drive them. modules/Window.lua's
-- entire refresh clock is an OnUpdate, so a no-op SetScript would make the
-- throttle — the addon's single most important performance property —
-- unreachable from a test.
function FRAME.SetScript(self, which, fn)
    self.__scripts[which] = fn and { fn } or nil
    if which == "OnEvent" then self.__onEvent = fn end
    return self
end
function FRAME.HookScript(self, which, fn)
    local list = self.__scripts[which]
    if not list then list = {}; self.__scripts[which] = list end
    list[#list + 1] = fn
    return self
end
function FRAME.GetScript(self, which)
    local list = self.__scripts[which]
    return list and list[1]
end
function FRAME._run(self, which, ...)
    local list = self.__scripts[which]
    if not list then return end
    for _, fn in ipairs(list) do fn(self, ...) end
end
--- Alias for the kit's own spelling, so a suite written against the base's
--- `__fire` keeps working.
function FRAME.__fire(self, which, ...) return self:_run(which, ...) end
function FRAME._fire(self, ev, ...)
    if self.__onEvent then self.__onEvent(self, ev, ...) end
end
function FRAME.RegisterEvent(self, ev) self.__events[ev] = true; return self end
function FRAME.RegisterUnitEvent(self, ev, ...) self.__events[ev] = { ... }; return self end
function FRAME.UnregisterEvent(self, ev) self.__events[ev] = nil; return self end
function FRAME.UnregisterAllEvents(self) self.__events = {}; return self end
function FRAME.IsEventRegistered(self, ev) return self.__events[ev] ~= nil end

local frameSeq = 0

--- Build a frame-shaped stub.
---
--- `objectType` mirrors CreateFrame's first argument, or "Texture" /
--- "FontString" for a region. `parent` wires the chain IsVisible and
--- GetEffectiveScale walk.
function makeFrame(objectType, parent, name)
    frameSeq = frameSeq + 1
    local f = {
        __objectType = objectType or "Frame",
        __name       = name or ("MythicMetersMockFrame" .. frameSeq),
        __parent     = parent,
        __shown      = true,   -- CreateFrame'd frames start shown
        __points     = {},
        __regions    = {},
        __scripts    = {},
        __events     = {},
        __w = 0, __h = 0, __scale = 1, __alpha = 1, __level = 0,
    }
    return setmetatable(f, {
        __index = function(_, k)
            local m = FRAME[k]
            if m ~= nil then return m end
            local n = NUMERIC_GETTERS[k]
            if n ~= nil then return function() return n end end
            -- WoW frame methods are PascalCase; addon-stored data fields are not
            -- (`frame.mmWindow`, `bar.mmCell`, `cell.showBar`). Answer a no-op
            -- method for the former and nil for the latter — a real frame returns
            -- nil for an unset field, and returning a callable there is how an
            -- unset `self.__whatever` silently becomes truthy.
            if type(k) == "string" and k:match("^%u") then
                return function() return f end
            end
            return nil
        end,
    })
end

-- ===========================================================================
-- The meter fixture
-- ===========================================================================
--
-- Sessions are held as PLAIN SPECS and materialized on read. The materializer is
-- what wraps the secret-bearing fields, so a suite writes ordinary numbers and
-- flips `mocks.setSecretValues(true)` to make the same fixture arrive opaque —
-- which is exactly the transition the addon has to survive.
--
-- The field list below is the addon's own reading of the 12.0 contract, taken
-- from core/Secrets.lua and modules/Provider.lua: amounts, rates, durations and
-- the ConditionalSecret display `name` are secret; GUIDs, class files, spec icon
-- IDs, spell IDs, recap IDs, classifications and the display-type enum are not.
-- `sourceGUID` in particular is the ONLY legal join key in the whole addon, so it
-- is never wrapped.

local SECRET_FIELDS = {
    totalAmount      = true,
    amountPerSecond  = true,
    maxAmount        = true,
    durationSeconds  = true,
    deathTimeSeconds = true,
    overkillAmount   = true,
    name             = true,   -- ConditionalSecret
    -- SecretWhenInCombat, per Blizzard's own annotation on
    -- DamageMeterCombatSource — and the omission that let this harness stay
    -- green while the addon showed an empty grid for every pull it ever ran.
    --
    -- The addon was built on the reading that a meter sourceGUID is never
    -- secret and is therefore its only legal join key. The mock was written from
    -- the same reading, so the restricted cases handed the aggregator a PLAIN
    -- GUID, the GUID join ran, the rows came out, and 771 cases agreed with each
    -- other about a client neither of them had asked. Measured in-game it comes
    -- back secret AND inaccessible: NS.Secrets.IsSafeKey refuses it, every
    -- source is dropped, and the window says "Waiting for combat data" with a
    -- full session behind it.
    --
    -- A fixture is only worth what it refuses to let you get away with.
    sourceGUID       = true,
}

--- Deep-copy `spec`, wrapping the secret-bearing leaves when `wrap` is true.
---
--- A SIMULATED SECRET IS ITSELF A TABLE (see the header), so it is carried
--- through by reference rather than recursed into. Copying it produced a plain
--- empty table with none of the trapping metatable on it — silently stripping
--- the one property the fixture was written to express — so a suite that placed
--- `mocks.secret(x)` in a session spec was testing a plain value and passing for
--- the wrong reason. The SECRET_FIELDS wrapping below is unaffected: it wraps
--- leaves on the way out, after this branch.
local function materialize(spec, wrap)
    if type(spec) ~= "table" then return spec end
    local out = {}
    for k, v in pairs(spec) do
        if isSimulatedSecret(v) or isSimulatedSecretTable(v) then
            out[k] = v
        elseif type(v) == "table" then
            out[k] = materialize(v, wrap)
        elseif wrap and SECRET_FIELDS[k] and v ~= nil then
            out[k] = secret(v)
        else
            out[k] = v
        end
    end
    return out
end

-- ===========================================================================
-- Session fixtures
-- ===========================================================================

-- The class ladder a generated roster walks, one per source and wrapping at the
-- end. Ten distinct classes so a fixture the size of a full party never repeats
-- a class — a repeat would make a class-colour or spec-icon assertion pass for
-- the wrong row.
local DEFAULT_CLASSES = {
    "WARRIOR", "PRIEST", "MAGE", "ROGUE", "HUNTER", "WARLOCK",
    "MONK", "DRUID", "PALADIN", "DEATHKNIGHT",
}

--- buildSession's knobs with every default already resolved, so the two builders
--- below read as a description of the fixture rather than as a pile of `or`s.
--- The defaults are the ones a suite gets by writing `mocks.buildSession()`:
--- five allies, a plausible top parse, and a 212-second run.
---
--- @param opts table|nil  see buildSession
--- @return table
local function sessionOptions(opts)
    opts = opts or {}
    return {
        count           = opts.count or 5,
        top             = opts.top or 4200000,
        step            = opts.step or 0.085,
        prefix          = opts.guidPrefix or "Player-1-",
        classes         = opts.classes or DEFAULT_CLASSES,
        names           = opts.names,
        deaths          = opts.deaths,
        durationSeconds = opts.durationSeconds or 212,
    }
end

-- ===========================================================================
-- The builder
-- ===========================================================================

local function build()
    local M = kitMockBase()

    -- ── secret plumbing, published ─────────────────────────────────────────
    M.SECRET_ERROR        = SECRET_ERROR
    M.secret              = secret
    M.secretTable         = secretTable
    M.reveal              = reveal
    M.isSimulatedSecret   = isSimulatedSecret
    M.isSimulatedSecretTable = isSimulatedSecretTable

    -- Faithful string.format over a simulated secret (see the header). A plain
    -- pass-through of the real library for everything else, so `string.rep`,
    -- `string.match` and the rest are untouched.
    local mockString = setmetatable({}, { __index = string })
    local function formatShim(fmt, ...)
        local n = select("#", ...)
        if n == 0 then return string.format(fmt) end
        local args = {}
        for i = 1, n do
            local v = select(i, ...)
            args[i] = isSimulatedSecret(v) and reveal(v) or v
        end
        return string.format(fmt, unpack(args, 1, n))
    end
    mockString.format = formatShim
    M.string = mockString
    M.format = formatShim

    -- ── restriction state ──────────────────────────────────────────────────
    --
    -- Three flags rather than one, because they are three different facts and the
    -- addon reacts to each separately:
    --   __restricted        is the Combat restriction active (drives
    --                       C_RestrictedActions and the InCombatLockdown fallback
    --                       core/Secrets.lua uses on a client without the API)
    --   __secretValues      does the meter hand back opaque values
    --   __secretsAccessible may tainted code still look at them — true during the
    --                       `Activating` dispatch, which is the last legal moment
    --                       for a value sort (design §5)
    M.__restricted        = false
    M.__secretValues      = false
    M.__secretsAccessible = false
    M.__restrictionState  = nil   -- nil = derive from __restricted

    --- Turn the Combat addon restriction on or off.
    ---
    --- Flips `__secretValues` with it, because that is the pairing the client
    --- actually produces; call `mocks.setSecretValues` afterwards to separate them
    --- (the Activating edge is the case that needs it).
    function M.setRestricted(v)
        v = v and true or false
        M.__restricted   = v
        M.__secretValues = v
        M.__inCombat     = v          -- the base's UnitAffectingCombat source
        M.__group.inCombat = v
    end

    function M.setSecretValues(v) M.__secretValues = v and true or false end
    function M.setSecretsAccessible(v) M.__secretsAccessible = v and true or false end

    --- Force the raw Enum.AddOnRestrictionState the API reports. nil restores the
    --- derived answer (Active while restricted, Inactive otherwise).
    function M.setRestrictionState(state) M.__restrictionState = state end

    M.Enum = M.Enum or {}
    -- Real 12.0 values, restated from core/Constants.lua so the mock and the
    -- addon's guarded fallbacks cannot disagree about what a number means.
    M.Enum.AddOnRestrictionType  = { Combat = 0 }
    M.Enum.AddOnRestrictionState = { Inactive = 0, Activating = 1, Active = 2 }
    M.Enum.DamageMeterType = {
        DamageDone = 0, Dps = 1, HealingDone = 2, Hps = 3, Absorbs = 4,
        Interrupts = 5, Dispels = 6, DamageTaken = 7, AvoidableDamageTaken = 8,
        Deaths = 9, EnemyDamageTaken = 10,
    }
    M.Enum.DamageMeterSessionType       = { Overall = 0, Current = 1, Expired = 2 }
    M.Enum.DamageMeterSourceDisplayType = { None = 0, Ally = 1, Enemy = 2 }

    M.C_RestrictedActions = {
        IsAddOnRestrictionActive = function(restrictionType)
            if restrictionType ~= nil and restrictionType ~= M.Enum.AddOnRestrictionType.Combat then
                return false
            end
            return M.__restricted
        end,
        GetAddOnRestrictionState = function(restrictionType)
            if restrictionType ~= nil and restrictionType ~= M.Enum.AddOnRestrictionType.Combat then
                return M.Enum.AddOnRestrictionState.Inactive
            end
            if M.__restrictionState ~= nil then return M.__restrictionState end
            return M.__restricted and M.Enum.AddOnRestrictionState.Active
                or M.Enum.AddOnRestrictionState.Inactive
        end,
    }

    M.InCombatLockdown = function() return M.__restricted end

    -- ── the four detection globals ─────────────────────────────────────────
    --
    -- Consistent with the simulator by construction: a value is secret iff this
    -- file wrapped it. Accessibility is the separate question core/Secrets.lua's
    -- CanAccess / CanCompare2 ask, and `__secretsAccessible` is what makes the
    -- Activating edge — where values are secret AND still readable — reachable.
    M.issecretvalue = function(v) return isSimulatedSecret(v) end
    M.canaccessvalue = function(v)
        if not isSimulatedSecret(v) then return true end
        return M.__secretsAccessible
    end
    M.issecrettable = function(t) return isSimulatedSecretTable(t) end
    M.canaccesstable = function(t)
        if type(t) ~= "table" then return false end
        if not isSimulatedSecretTable(t) then return true end
        return M.__secretsAccessible
    end

    -- ── C_DamageMeter ──────────────────────────────────────────────────────
    local meter = {
        available     = true,
        failureReason = nil,
        -- [sessionType][statType] = plain session spec
        sessionSpecs  = {},
        -- [sessionType][statType][key] = plain source spec; key is a GUID, or
        -- "creature:<id>" for an enemy, or "*" as the catch-all
        sourceSpecs   = {},
        durations     = {},
        sessions      = {},
        resets        = 0,
        calls         = {},
    }
    M.__meter = meter

    local function bump(name)
        meter.calls[name] = (meter.calls[name] or 0) + 1
    end

    --- Zero every call counter. Suites and tests/perf.lua both measure "how many
    --- reads did one refresh make", which is only a number if it can be reset.
    function M.resetMeterCalls()
        for k in pairs(meter.calls) do meter.calls[k] = nil end
    end

    function M.setMeterAvailable(ok, reason)
        meter.available     = ok and true or false
        meter.failureReason = reason
    end

    --- Install a session spec for (sessionType, statType). Pass nil to remove it,
    --- which is how the "no session" reason is reached.
    function M.setSession(sessionType, statType, spec)
        meter.sessionSpecs[sessionType] = meter.sessionSpecs[sessionType] or {}
        meter.sessionSpecs[sessionType][statType] = spec
    end

    --- Install the per-source spell breakdown behind one cell.
    --- `key` is a source GUID, "creature:<id>", or "*" for every source.
    function M.setSourceDetail(sessionType, statType, key, spec)
        meter.sourceSpecs[sessionType] = meter.sourceSpecs[sessionType] or {}
        meter.sourceSpecs[sessionType][statType] = meter.sourceSpecs[sessionType][statType] or {}
        meter.sourceSpecs[sessionType][statType][key or "*"] = spec
    end

    function M.setSessionDuration(sessionType, seconds) meter.durations[sessionType] = seconds end
    function M.setAvailableSessions(list) meter.sessions = list or {} end

    --- A plausible session spec: `count` ally sources, descending by amount.
    ---
    --- Deterministic on purpose — the perf runner and every suite need the same
    --- numbers on every run, and a randomized fixture makes a failure
    --- irreproducible. `opts.guidPrefix` lets a caller line the GUIDs up with a
    --- group built by `mocks.setGroup`, which is what makes the aggregator's join
    --- assertable.
    ---
    --- @param opts table|nil {
    ---   count, top, step, guidPrefix, names, classes, statKey, deaths,
    ---   durationSeconds }
    --- @return table  a plain session spec, ready for setSession
    --- The i-th combat source of a generated session, carrying `amount` as its
    --- total. Source 1 is the local player, which is what makes the "highlight
    --- me" rendering assertable without a caller having to say so.
    ---
    --- @param spec table    a resolved sessionOptions table
    --- @param i number      1-based position in the roster
    --- @param amount number this source's total for the run
    --- @return table
    local function buildSource(spec, i, amount)
        -- The design brief names this field `guid`; modules/Provider.lua reads
        -- `sourceGUID`. Both are published, from the one string, so a fixture
        -- written against either spelling lines up with the code that consumes it.
        local guid = string.format("%s%08X", spec.prefix, i)
        return {
            sourceGUID        = guid,
            guid              = guid,
            sourceCreatureID  = nil,
            name              = (spec.names and spec.names[i]) or ("Mock" .. i),
            classFilename     = spec.classes[((i - 1) % #spec.classes) + 1],
            specIconID        = 135000 + i,
            isLocalPlayer     = (i == 1),
            totalAmount       = amount,
            amountPerSecond   = math.floor(amount / 300),
            deathTimeSeconds  = spec.deaths and (i * 7) or nil,
            deathRecapID      = spec.deaths and (1000 + i) or nil,
            classification    = "normal",
            sourceDisplayType = M.Enum.DamageMeterSourceDisplayType.Ally,
            factionGroup      = "Alliance",
        }
    end

    function M.buildSession(opts)
        local spec = sessionOptions(opts)

        -- A descending ladder from `top`, each source `step` below the one above
        -- it, floored at 1 so a long roster never produces a zero or a negative
        -- total that the aggregator's percentages would divide by.
        local sources, total = {}, 0
        for i = 1, spec.count do
            local amount = math.floor(spec.top * (1 - (i - 1) * spec.step))
            if amount < 1 then amount = 1 end
            total = total + amount
            sources[i] = buildSource(spec, i, amount)
        end

        return {
            combatSources   = sources,
            maxAmount       = sources[1] and sources[1].totalAmount or 0,
            totalAmount     = total,
            durationSeconds = spec.durationSeconds,
        }
    end

    --- A plausible per-source spell breakdown, for the tooltip and drill-down.
    function M.buildSourceDetail(opts)
        opts = opts or {}
        local count = opts.count or 4
        local top   = opts.top or 900000
        local spells, total = {}, 0
        for i = 1, count do
            local amount = math.floor(top / i)
            total = total + amount
            spells[i] = {
                spellID        = 100 + i,
                name           = "Mock Spell " .. i,
                totalAmount    = amount,
                isAvoidable    = opts.avoidable and (i % 2 == 0) or false,
                isDeadly       = opts.deadly and (i == 1) or false,
                overkillAmount = opts.overkill and math.floor(amount / 10) or nil,
            }
        end
        return { combatSpells = spells, maxAmount = spells[1] and spells[1].totalAmount or 0,
                 totalAmount = total }
    end

    M.C_DamageMeter = {
        IsDamageMeterAvailable = function()
            bump("IsDamageMeterAvailable")
            if meter.available then return true, nil end
            return false, meter.failureReason
        end,

        GetCombatSessionFromType = function(sessionType, statType)
            bump("GetCombatSessionFromType")
            local byStat = meter.sessionSpecs[sessionType]
            local spec = byStat and (byStat[statType] or byStat["*"])
            if spec == nil then return nil end
            return materialize(spec, M.__secretValues)
        end,

        GetCombatSessionFromID = function(sessionID, statType)
            bump("GetCombatSessionFromID")
            local byStat = meter.sessionSpecs[sessionID]
            local spec = byStat and (byStat[statType] or byStat["*"])
            if spec == nil then return nil end
            return materialize(spec, M.__secretValues)
        end,

        GetCombatSessionSourceFromType = function(sessionType, statType, sourceGUID, creatureID)
            bump("GetCombatSessionSourceFromType")
            local byStat = meter.sourceSpecs[sessionType]
            local byKey = byStat and (byStat[statType] or byStat["*"])
            if not byKey then return nil end
            local key = sourceGUID or (creatureID and ("creature:" .. tostring(creatureID)))
            local spec = (key and byKey[key]) or byKey["*"]
            if spec == nil then return nil end
            return materialize(spec, M.__secretValues)
        end,

        GetCombatSessionSourceFromID = function(sessionID, statType, sourceGUID, creatureID)
            bump("GetCombatSessionSourceFromID")
            return M.C_DamageMeter.GetCombatSessionSourceFromType(
                sessionID, statType, sourceGUID, creatureID)
        end,

        GetAvailableCombatSessions = function()
            bump("GetAvailableCombatSessions")
            return meter.sessions
        end,

        GetSessionDurationSeconds = function(sessionType)
            bump("GetSessionDurationSeconds")
            local d = meter.durations[sessionType]
            if d == nil then return nil end
            if M.__secretValues then return secret(d) end
            return d
        end,

        ResetAllCombatSessions = function()
            bump("ResetAllCombatSessions")
            meter.resets = meter.resets + 1
            meter.sessionSpecs = {}
            meter.sourceSpecs  = {}
        end,
    }

    -- ── C_StringUtil: the only legal way to abbreviate a secret ────────────
    --
    -- The formatter is a NATIVE seam, which is the entire reason modules/Format.lua
    -- may hand it a secret at all — so this stub is allowed to reveal the value.
    -- Nothing else in the mock does.
    -- A FORMATTER ONLY ABBREVIATES IF IT HAS BREAKPOINTS, and modelling that is
    -- the whole point of this stub.
    --
    -- The previous version of this mock abbreviated unconditionally, inside
    -- CreateNumericRuleFormatter. That made the entire suite green while the LIVE
    -- client rendered "53571.392857143" in every cell, because the real
    -- NumericRuleFormatter with no breakpoints on it is a working formatter that
    -- does not abbreviate — the addon was asking the wrong object and no test
    -- could see it. A mock that is kinder than the client is a mock that hides
    -- the bug it exists to catch (mock_base's rule 5).
    --
    -- Breakpoint semantics, MEASURED ON A LIVE CLIENT rather than taken from the
    -- documentation:
    --
    --     displayed = n / (significandDivisor * fractionDivisor)
    --     decimals  = log10(fractionDivisor)
    --
    -- The wiki's worked example does not hold under that formula, and this stub
    -- previously implemented the wiki's version — which is how a ladder that put
    -- every number two orders of magnitude too small passed every test. Truncated,
    -- not rounded, also per observation ("4.75" renders "4.7").
    local function decimalsFor(fractionDivisor)
        local d, n = 0, fractionDivisor or 1
        while n >= 10 do n, d = n / 10, d + 1 end
        return d
    end

    local function newFormatter(kind)
        local formatter = { __formatCount = 0, __kind = kind, __breakpoints = nil }

        function formatter:SetBreakpoints(list)
            if type(list) ~= "table" then error("SetBreakpoints wants an array", 2) end
            self.__breakpoints = list
        end
        function formatter:GetBreakpoints()   return self.__breakpoints end
        function formatter:ClearBreakpoints() self.__breakpoints = nil end
        function formatter:AddBreakpoint(bp)
            self.__breakpoints = self.__breakpoints or {}
            self.__breakpoints[#self.__breakpoints + 1] = bp
        end

        function formatter:FormatNumber(v)
            self.__formatCount = self.__formatCount + 1
            local n = reveal(v)
            if type(n) ~= "number" then return tostring(n) end

            local best
            for _, bp in ipairs(self.__breakpoints or {}) do
                if n >= (bp.breakpoint or 0)
                    and (best == nil or (bp.breakpoint or 0) >= (best.breakpoint or 0)) then
                    best = bp
                end
            end

            -- NO BREAKPOINT MATCHED: the plain render. This is the branch the
            -- addon lived in for a whole release.
            if best == nil then return tostring(n) end

            local scaled = n / ((best.significandDivisor or 1) * (best.fractionDivisor or 1))
            local d = decimalsFor(best.fractionDivisor)
            local factor = 10 ^ d
            local truncated = math.floor(scaled * factor) / factor
            return string.format("%." .. d .. "f", truncated) .. (best.abbreviation or "")
        end

        M.__lastNumericFormatter = formatter
        return formatter
    end

    M.C_StringUtil = {
        -- The RULE formatter. Ships with no breakpoints, so it renders plainly
        -- until somebody puts some on it.
        CreateNumericRuleFormatter = function() return newFormatter("rule") end,

        -- The ABBREVIATING formatter. Also ships with no breakpoints — the
        -- caller is expected to set them, from GetDefaultAbbreviationBreakpoints
        -- or its own ladder.
        CreateAbbreviatedNumberFormatter = function() return newFormatter("abbreviated") end,

        GetDefaultAbbreviationBreakpoints = function()
            -- Blizzard's own ladder, in the same multiplying semantics: one
            -- decimal below 10K, none above, which is what the live client shows
            -- when our own array is refused.
            return {
                { breakpoint = 1e3, abbreviation = "K", significandDivisor = 100, fractionDivisor = 10,
                  abbreviationIsGlobal = false },
                { breakpoint = 1e4, abbreviation = "K", significandDivisor = 1e3, fractionDivisor = 1,
                  abbreviationIsGlobal = false },
                { breakpoint = 1e6, abbreviation = "M", significandDivisor = 1e5, fractionDivisor = 10,
                  abbreviationIsGlobal = false },
            }
        end,
    }

    M.AbbreviateNumbers = function(v)
        local n = reveal(v)
        if type(n) ~= "number" then return tostring(n) end
        if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
        if n >= 1e3 then return string.format("%.1fK", n / 1e3) end
        return string.format("%d", n)
    end

    -- ── group / units ──────────────────────────────────────────────────────
    --
    -- modules/Roster.lua walks `player`, then `raid1..N` (in a raid) or
    -- `party1..N-1`, and asks for each unit's pet by token. Everything it can ask
    -- is answered from this one table so a suite composes a group in one call.
    local group = {
        inGroup      = false,
        inRaid       = false,
        size         = 0,
        inInstance   = false,
        instanceType = "none",
        inCombat     = false,
        inVehicle    = false,
        units        = {},   -- [unitToken] = { guid, name, class, classFile, role }
    }
    M.__group = group

    local CLASS_NAMES = {
        WARRIOR = "Warrior", PRIEST = "Priest", MAGE = "Mage", ROGUE = "Rogue",
        HUNTER = "Hunter", WARLOCK = "Warlock", MONK = "Monk", DRUID = "Druid",
        PALADIN = "Paladin", DEATHKNIGHT = "Death Knight", SHAMAN = "Shaman",
        DEMONHUNTER = "Demon Hunter", EVOKER = "Evoker",
    }

    local function setUnit(token, spec)
        if spec == nil then group.units[token] = nil; return end
        group.units[token] = {
            guid      = spec.guid,
            name      = spec.name,
            classFile = spec.classFile or spec.class or "WARRIOR",
            role      = spec.role or "NONE",
        }
    end
    M.setUnit = setUnit

    --- Compose a group.
    ---
    --- `spec` is an array of { guid, name, class, role }, the PLAYER FIRST — the
    --- order modules/Roster.lua produces and the order `roster` sort mode is
    --- defined against. `opts.raid` builds raid1..N instead of party1..N-1.
    ---
    --- GUIDs default to the same "Player-1-%08X" shape `mocks.buildSession`
    --- produces, so a session built with the default prefix joins against a group
    --- built with no GUIDs at all.
    function M.setGroup(spec, opts)
        opts = opts or {}
        spec = spec or {}
        group.units = {}
        group.inRaid = opts.raid and true or false
        group.size   = #spec
        group.inGroup = #spec > 1

        for i, member in ipairs(spec) do
            local guid = member.guid or string.format("Player-1-%08X", i)
            local token = (i == 1) and "player"
                or (group.inRaid and ("raid" .. i) or ("party" .. (i - 1)))
            setUnit(token, {
                guid = guid, name = member.name or ("Mock" .. i),
                class = member.class, role = member.role,
            })
            -- In a raid the player is also raidN. Roster de-duplicates by GUID,
            -- and reproducing the duplicate here is what makes that provable.
            if group.inRaid and i == 1 then
                setUnit("raid1", { guid = guid, name = member.name or "Mock1",
                                   class = member.class, role = member.role })
            end
        end
        return group
    end

    --- Solo: one unit, `player`, and no group. The default state.
    function M.setSolo(guid, name, class)
        return M.setGroup({ { guid = guid or "Player-1-00000001",
                              name = name or "Mock1", class = class or "MAGE",
                              role = "DAMAGER" } })
    end

    --- Give `unit` a pet. The token is derived exactly as modules/Roster.lua
    --- derives it, so a mismatch is impossible.
    function M.setPet(unit, guid, name)
        local token = (unit == "player") and "playerpet" or (unit .. "pet")
        setUnit(token, { guid = guid, name = name or "MockPet", class = "PET" })
        return token
    end

    function M.setInstance(instanceType)
        group.inInstance   = (instanceType ~= nil and instanceType ~= "none")
        group.instanceType = instanceType or "none"
    end

    function M.setInCombat(v)
        group.inCombat = v and true or false
        M.__inCombat   = group.inCombat
    end

    function M.setInVehicle(v) group.inVehicle = v and true or false end

    local function unit(token) return group.units[token] end

    M.UnitExists = function(token) return unit(token) ~= nil end
    M.UnitGUID   = function(token) local u = unit(token) return u and u.guid end
    M.UnitName   = function(token) local u = unit(token) return u and u.name end
    M.UnitClass  = function(token)
        local u = unit(token)
        if not u then return nil end
        return CLASS_NAMES[u.classFile] or u.classFile, u.classFile
    end
    M.UnitGroupRolesAssigned = function(token)
        local u = unit(token)
        return u and u.role or "NONE"
    end

    -- The player's own specialization role, which is what modules/Roster.lua
    -- falls back to when no group has assigned one. `mocks.setSpecRole(nil)`
    -- drives the case where even this is unavailable.
    group.specRole = nil
    function M.setSpecRole(role) group.specRole = role end
    M.GetSpecialization     = function() return group.specRole and 1 or nil end
    M.GetSpecializationRole = function() return group.specRole end
    M.UnitAffectingCombat = function() return group.inCombat end
    M.UnitInVehicle       = function() return group.inVehicle end
    M.UnitIsUnit          = function(a, b)
        local ua, ub = unit(a), unit(b)
        return ua ~= nil and ub ~= nil and ua.guid == ub.guid
    end
    M.UnitIsPlayer = function(token) return unit(token) ~= nil end
    M.UnitIsDead   = function() return false end
    M.IsInGroup           = function() return group.inGroup end
    M.IsInRaid            = function() return group.inRaid end
    M.GetNumGroupMembers  = function() return group.size end
    M.IsInInstance        = function() return group.inInstance, group.instanceType end
    M.IsLoggedIn          = function() return true end

    M.setSolo()

    -- Class colors and icon coordinates, so modules/Row.lua's `class` color mode
    -- and class-icon path are exercised rather than skipped over.
    M.RAID_CLASS_COLORS = {}
    M.CLASS_ICON_TCOORDS = {}
    for cls in pairs(CLASS_NAMES) do
        M.RAID_CLASS_COLORS[cls] = { r = 0.5, g = 0.6, b = 0.7 }
        M.CLASS_ICON_TCOORDS[cls] = { 0, 0.25, 0, 0.25 }
    end
    M.STANDARD_TEXT_FONT = [[Fonts\FRIZQT__.TTF]]

    -- ── C_Texture ──────────────────────────────────────────────────────────
    --
    -- Atlas existence, which core/Compat.lua's FirstAtlas asks before drawing
    -- anything. The known set is deliberately SMALL and settable: the bug this
    -- guards against is art that does not exist on the live client, so the
    -- default here is "almost nothing exists" rather than "everything does".
    -- The set a live 12.x client reported through `/mm debug diag`. Small on
    -- purpose: the bug this guards against is art that does not exist, so the
    -- default is "almost nothing exists" rather than "everything does".
    M.__atlases = {
        ["auctionhouse-ui-sortarrow"] = true,
        ["GM-icon-settings"]          = true,
        ["Garr_LockedBuilding"]       = true,
    }
    function M.setAtlases(set) M.__atlases = set or {} end
    M.C_Texture = {
        GetAtlasInfo = function(name)
            if M.__atlases[name] then return { width = 16, height = 16 } end
            return nil
        end,
    }

    -- ── MenuUtil ───────────────────────────────────────────────────────────
    --
    -- The 11.0+ context-menu API, behind core/Compat.lua's OpenContextMenu shim
    -- and used by the window header's segment selector.
    --
    -- RECORDS THE MENU RATHER THAN DRAWING ONE. The generator runs immediately
    -- against a root that appends a descriptor per call, so a test can assert
    -- what the menu OFFERS — its entries, their order, the divider between the
    -- stored segments and the synthetic ones — and can invoke an entry's callback
    -- to prove the click does what the label promises. A mock that merely
    -- swallowed the call would leave the whole dropdown untested.
    --
    -- Clear `mocks.MenuUtil` to drive the shim's "this client has no menu API"
    -- path, which is what the headless-degradation suite does.
    M.__lastMenu = nil

    local function newMenuRoot()
        local root = { entries = {} }
        local function add(kind, text, callback)
            root.entries[#root.entries + 1] =
                { kind = kind, text = text, callback = callback }
            return root.entries[#root.entries]
        end
        function root:CreateTitle(text)             return add("title", text, nil) end
        function root:CreateDivider()               return add("divider", nil, nil) end
        function root:CreateButton(text, callback)  return add("button", text, callback) end
        --- The nth entry of one kind, so a case can say "the second button"
        --- without counting dividers.
        function root:Nth(kind, n)
            local seen = 0
            for _, e in ipairs(self.entries) do
                if e.kind == kind then
                    seen = seen + 1
                    if seen == n then return e end
                end
            end
            return nil
        end
        return root
    end

    M.MenuUtil = {
        CreateContextMenu = function(owner, generator)
            local root = newMenuRoot()
            root.owner = owner
            generator(owner, root)
            M.__lastMenu = root
            return root
        end,
    }

    -- ── manifest ───────────────────────────────────────────────────────────
    --
    -- Stubbed HERE and not in the base (whose header explains why). Clear
    -- `mocks.C_AddOns` — not `_G.C_AddOns` — to drive core/Compat.lua's
    -- deprecated-global fallback; `mocks._G` resolves through this table.
    M.__toc = {
        Version = "0.1.0",
        Title   = "Ka0s Mythic Meters",
        Notes   = "One grid, one row per group member, one column per stat.",
    }
    M.C_AddOns = {
        GetAddOnMetadata = function(_, field) return M.__toc[field] end,
        IsAddOnLoaded    = function() return true, true end,
    }

    -- ── spell / spec APIs ──────────────────────────────────────────────────
    M.__spells = setmetatable({}, { __index = function(_, id)
        return { name = "Mock Spell " .. tostring(id), iconID = 130000 + (tonumber(id) or 0),
                 castTime = 0, minRange = 0, maxRange = 40, spellID = id }
    end })
    M.C_Spell = {
        GetSpellInfo    = function(id) return M.__spells[id] end,
        GetSpellTexture = function(id) return 130000 + (tonumber(id) or 0) end,
    }
    M.C_SpecializationInfo = {
        GetSpecialization     = function() return 1 end,
        GetSpecializationInfo = function() return 250, "Blood", "", 135771, "TANK" end,
    }

    M.OpenDeathRecapUI = function(id)
        M.__deathRecaps = (M.__deathRecaps or 0) + 1
        M.__lastRecapID = id
    end

    -- ── frames ─────────────────────────────────────────────────────────────
    --
    -- Every frame this run creates, in creation order, plus a by-name index. The
    -- window's frames are NAMED (modules/Window.lua names them so they can go into
    -- UISpecialFrames), so a suite can reach "MythicMetersWindow1" without holding
    -- the instance.
    M.__frames      = {}
    M.__frameByName = {}
    M.__stubFrame   = makeFrame

    M.CreateFrame = function(objectType, name, parent, template)
        local f = makeFrame(objectType or "Frame", parent, name)
        f.__template = template
        M.__frames[#M.__frames + 1] = f
        if name then M.__frameByName[name] = f end
        return f
    end

    M.UIParent           = makeFrame("Frame", nil, "UIParent")
    M.DEFAULT_CHAT_FRAME = makeFrame("Frame", nil, "ChatFrame1")
    M.__chat             = {}
    M.DEFAULT_CHAT_FRAME.AddMessage = function(_, msg)
        M.__chat[#M.__chat + 1] = msg
    end
    M.UISpecialFrames = {}

    -- GameTooltip with a RECORDED line list. modules/Tooltip.lua's whole output is
    -- AddLine / AddDoubleLine calls, so a no-op tooltip would make every tooltip
    -- case pass without asserting anything.
    local tooltip = makeFrame("GameTooltip", nil, "GameTooltip")
    tooltip.__lines = {}
    function tooltip:SetOwner(owner, anchor)
        self.__owner, self.__anchor = owner, anchor
        return self
    end
    function tooltip:GetOwner() return self.__owner end
    function tooltip:ClearLines() self.__lines = {}; return self end
    -- PER-LINE FONTSTRINGS, under the client's own global names.
    --
    -- `GameTooltipTextLeft3` / `TextRight3` are how an addon anchors anything to a
    -- tooltip line, and modules/Tooltip.lua's spell bars are anchored between the
    -- two. A stub with no line widgets made those bars silently undrawable — the
    -- code ran, found nil, and returned, which is a real failure mode wearing a
    -- passing test.
    local function lineWidgets(index)
        local leftName  = "GameTooltipTextLeft"  .. index
        local rightName = "GameTooltipTextRight" .. index
        -- Registered on the MOCK TABLE, not just in the by-name index: an addon
        -- reaches these through `_G["GameTooltipTextLeft3"]`, and `mocks._G`
        -- resolves through this table (see the C_AddOns note above).
        if not M[leftName] then
            M[leftName]  = makeFrame("FontString", tooltip, leftName)
            M[rightName] = makeFrame("FontString", tooltip, rightName)
            -- The real ones inherit GameTooltipText, so they HAVE a font and
            -- SetText works on them. Without this the writes below raise the
            -- mock's own "Font not set" guard.
            M[leftName].__template  = "GameTooltipText"
            M[rightName].__template = "GameTooltipText"
            M.__frameByName[leftName]  = M[leftName]
            M.__frameByName[rightName] = M[rightName]
        end
        return M[leftName], M[rightName]
    end

    -- The TEXT REACHES THE LINE WIDGETS, not just the recorded line list.
    -- modules/Tooltip.lua widens the tooltip from the longest spell name, which it
    -- measures off GameTooltipTextLeft<N> — and a widget the mock never wrote to
    -- measures zero, which turned that whole path into a no-op that still passed.
    function tooltip:AddLine(text, r, g, b)
        self.__lines[#self.__lines + 1] = { text = text, r = r, g = g, b = b }
        local left, right = lineWidgets(#self.__lines)
        left:SetText(text)
        right:SetText(nil)
        return self
    end
    function tooltip:AddDoubleLine(leftText, rightText, ...)
        self.__lines[#self.__lines + 1] =
            { text = leftText, right = rightText, double = true }
        local left, right = lineWidgets(#self.__lines)
        left:SetText(leftText)
        right:SetText(rightText)
        return self
    end
    function tooltip:NumLines() return #self.__lines end
    -- The tooltip sizes itself from its own text, and modules/Tooltip.lua's amount
    -- and share slots are NOT its text — they are addon widgets. So the addon
    -- widens the frame itself, and has to put the width back afterwards or the
    -- next addon's item tooltip inherits it. A no-op stub would make both halves
    -- of that unassertable.
    function tooltip:SetMinimumWidth(w) self.__minWidth = w or 0; return self end
    function tooltip:GetMinimumWidth() return self.__minWidth or 0 end
    M.GameTooltip = tooltip
    M.GameTooltip_SetDefaultAnchor = function() end

    -- ── timers ─────────────────────────────────────────────────────────────
    --
    -- The base already records C_Timer.After / NewTimer into `__timers` and fires
    -- them with `__fireTimers`. `__flushTimers` is the collection's other spelling
    -- of the same thing, published so a suite copied from a sibling addon works.
    M.__flushTimers = M.__fireTimers

    -- ── LibStub extras ─────────────────────────────────────────────────────
    local libs = M.__libs

    --- AceEvent-3.0, REPLACED rather than extended.
    ---
    --- The base's fake models the (message, target) fan-out correctly — which is
    --- the property this addon most depends on, since every window subscribes to
    --- the same refresh messages and CallbackHandler would otherwise let the last
    --- registrant clobber the rest (anti-pattern #32). What it lacks is
    --- `UnregisterAllMessages`, which modules/Provider.lua's Suspend and
    --- modules/Window.lua's UnregisterBus both call, and the base's registry is
    --- closure-private so it cannot be extended in place. One registry, shared
    --- across every embed, dispatching fn(message, ...) exactly as CallbackHandler
    --- fires a function-ref callback; a STRING method name resolves against the
    --- registering object at dispatch time, which is the form every module in this
    --- addon uses (`self:RegisterMessage(MSG.METER_RESET, "OnMeterInvalidated")`).
    local busRegistry = {}   -- [message] = { [target] = callable }
    M.__busRegistry = busRegistry

    local function resolveCallback(target, method, message)
        if type(method) == "function" then
            return function(...) return method(...) end
        end
        local name = (type(method) == "string") and method or message
        return function(...)
            local fn = target[name]
            if fn then return fn(target, ...) end
        end
    end

    local function embedAceEvent(obj)
        obj.RegisterMessage = function(self, message, method)
            busRegistry[message] = busRegistry[message] or {}
            busRegistry[message][self] = resolveCallback(self, method, message)
        end
        obj.UnregisterMessage = function(self, message)
            if busRegistry[message] then busRegistry[message][self] = nil end
        end
        obj.UnregisterAllMessages = function(self)
            for _, targets in pairs(busRegistry) do targets[self] = nil end
        end
        obj.SendMessage = function(_, message, ...)
            local targets = busRegistry[message]
            if not targets then return end
            -- Snapshot: a handler may unregister (or register) during dispatch,
            -- and mutating the table under `pairs` is undefined.
            local snapshot = {}
            for target, cb in pairs(targets) do snapshot[#snapshot + 1] = { target, cb } end
            for _, entry in ipairs(snapshot) do entry[2](message, ...) end
        end
        -- Game events are the addon object's, and core/MythicMeters.lua is the only
        -- registrant. Recorded so a suite can fire one; see __fireEvent below.
        obj.__events = obj.__events or {}
        obj.RegisterEvent = function(self, event, handler)
            self.__events[event] = handler or event
        end
        obj.UnregisterEvent = function(self, event) self.__events[event] = nil end
        obj.UnregisterAllEvents = function(self) self.__events = {} end
        return obj
    end
    M.__embedAceEvent = embedAceEvent

    libs["AceEvent-3.0"] = { Embed = function(_, obj) return embedAceEvent(obj) end }

    --- AceAddon-3.0 with the MODULE LIFECYCLE the base has no need for.
    ---
    --- Seven of this addon's files are `NS:NewModule(name, "AceEvent-3.0")`
    --- children, so without NewModule / GetModule not one of them loads. Modules
    --- are registered in creation order and exposed as `addon.__moduleOrder`, and
    --- `addon:__enableAll()` runs every OnEnable in that order — which is what a
    --- suite uses to reach the bus subscriptions the real client sets up during
    --- AceAddon's enable pass.
    local baseNewAddon = libs["AceAddon-3.0"].NewAddon
    libs["AceAddon-3.0"] = {
        NewAddon = function(self, target, ...)
            local addon = baseNewAddon(self, target, ...)
            embedAceEvent(addon)

            addon.__modules     = {}
            addon.__moduleOrder = {}

            addon.NewModule = function(host, name, ...)
                local m = { moduleName = name, __addon = host }
                embedAceEvent(m)
                m.ScheduleTimer = host.ScheduleTimer
                m.CancelTimer   = host.CancelTimer
                m.Enable  = function(mod) if mod.OnEnable then mod:OnEnable() end end
                m.Disable = function(mod) if mod.OnDisable then mod:OnDisable() end end
                m.IsEnabled = function() return true end
                host.__modules[name] = m
                host.__moduleOrder[#host.__moduleOrder + 1] = name
                return m
            end

            addon.GetModule = function(host, name, silent)
                local m = host.__modules[name]
                if not m and not silent then
                    error("Cannot find a module named " .. tostring(name), 2)
                end
                return m
            end

            addon.IterateModules = function(host) return pairs(host.__modules) end

            --- Run every module's OnEnable, in registration order — the client's
            --- own order. Not part of AceAddon's surface; it is the harness's
            --- entry point into the lifecycle step a headless run has no client to
            --- perform.
            addon.__enableAll = function(host)
                for _, name in ipairs(host.__moduleOrder) do
                    local m = host.__modules[name]
                    if m and m.OnEnable then m:OnEnable() end
                end
                if host.OnEnable then host:OnEnable() end
            end

            --- Fire a game event at the addon object, exactly as the client would.
            --- Handlers are registered by NAME (`"OnMeterUpdated"`), so this is the
            --- only way a suite can drive core/MythicMeters.lua's fan-out.
            addon.__fireEvent = function(host, event, ...)
                local handler = host.__events[event]
                if handler == nil then return false end
                local fn = (type(handler) == "function") and handler or host[handler]
                if not fn then return false end
                fn(host, event, ...)
                return true
            end

            return addon
        end,
    }

    -- LibSharedMedia-3.0. Real enough to answer a Fetch: modules/Window.lua and
    -- modules/Row.lua resolve every font, bar texture and border through it, and a
    -- nil library sends them all down the fallback branch, leaving the LSM path
    -- untested. core/LSMPatch.lua registers the shipped monospace font into this.
    local media = { font = {}, statusbar = {}, border = {}, background = {}, sound = {} }
    libs["LibSharedMedia-3.0"] = {
        MediaType = { FONT = "font", STATUSBAR = "statusbar", BORDER = "border",
                      BACKGROUND = "background", SOUND = "sound" },
        Register = function(_, mediaType, key, path)
            media[mediaType] = media[mediaType] or {}
            media[mediaType][key] = path
            return true
        end,
        Fetch = function(_, mediaType, key)
            return media[mediaType] and media[mediaType][key]
        end,
        List = function(_, mediaType)
            local out = {}
            for key in pairs(media[mediaType] or {}) do out[#out + 1] = key end
            table.sort(out)
            return out
        end,
        HashTable = function(_, mediaType) return media[mediaType] or {} end,
        __media = media,
    }
    M.__media = media

    -- LibDataBroker / LibDBIcon, for modules/Minimap.lua. Present rather than
    -- absent so the registration path runs; a suite that wants the "no broker
    -- library" degradation clears them from `mocks.__libs`.
    local brokers = {}
    libs["LibDataBroker-1.1"] = {
        NewDataObject = function(_, name, obj)
            brokers[name] = obj
            return obj
        end,
        GetDataObjectByName = function(_, name) return brokers[name] end,
        __objects = brokers,
    }
    libs["LibDBIcon-1.0"] = {
        objects = {},
        Register = function(self, name, broker, db)
            self.objects[name] = { broker = broker, db = db }
        end,
        Refresh = function(self, name, db)
            self.__refreshes = (self.__refreshes or 0) + 1
            local o = self.objects[name]
            if o then o.db = db end
        end,
        Hide = function() end,
        Show = function() end,
    }

    -- AceDBOptions / AceConfig, for settings/Profiles.lua — the one page in this
    -- addon that is drawn by AceConfigDialog rather than from NS.Schema.
    libs["AceDBOptions-3.0"] = {
        GetOptionsTable = function(_, db)
            return { type = "group", name = "Profiles", args = {}, __db = db }
        end,
    }
    local registered = {}
    libs["AceConfig-3.0"] = {
        RegisterOptionsTable = function(_, name, tbl) registered[name] = tbl end,
        __registered = registered,
    }
    libs["AceConfigDialog-3.0"] = {
        Open = function(self, name, container)
            self.__opens = (self.__opens or 0) + 1
            self.__lastOpen = { name = name, container = container }
        end,
        Close = function(self) self.__closes = (self.__closes or 0) + 1 end,
        SetDefaultSize = function() end,
    }
    libs["AceConfigRegistry-3.0"] = {
        NotifyChange = function() end,
        RegisterOptionsTable = function() end,
    }

    return M
end

return { build = build }
