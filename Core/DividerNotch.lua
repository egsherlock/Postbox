local _, ns = ...

-------------------------------------------------------------
-- Postbox :: the read mail's divider as a notch (Options, Mail, Divider:
-- the Notch looks; CollectTab, RV.LOOKS).
--
-- While the read mail is below the view, or folded, a small notch stands on
-- the list's foot in the pinned copy's place: the divider's words on a tab
-- (the count alone on a chip, for Count). Scrolling to the divider's place,
-- or a click on the notch, opens it into the divider itself -- Hairline,
-- in its place -- and the finished rows show under it; scrolling away, or
-- a click folding the read mail, closes it again. Scrolling never unfolds
-- what a click folded: folded, it stays a notch at the foot.
--
-- Four ways to go between the two, to try in game:
--   stretch  the tab fades as its top edge stretches into the hairline, its
--            words travel to the divider's place, the sign and Delete all
--            come in. 240 ms out; closing 85% of that, eased in.
--   count    a chip with the number; the number flies to its place in
--            "(3)", the words slide out leftward from it, the hairline draws
--            from them to Delete all.
--   drawer   a lip across the list's foot with the tab on it; both rise into
--            the divider as its words travel, a soft shade under it for a
--            moment, and the rows below are wiped into view downward.
--   scroll   scrubbed, not played: the tab widens into the divider as the
--            divider's place scrolls in, by how far it has come (the last
--            row before it, then its own). A wheel step moves the list half
--            a view at once (the template's step), so a step is eased over
--            DN.EASE; a drag on the bar follows the bar.
--
-- Built as the house builds: the notch is one frame of Postbox's own in the
-- list (above the rows, as the pinned copy was, and clipped with them), made
-- on the first pass that wants it. Its pieces are a tab, a fade under it
-- and, for the moments between, copies of the divider's parts ("ghosts")
-- that travel; the divider itself is shown only at rest, so no animation
-- ever runs on a frame the list hides and shows on every pass. Every timed
-- move is an AnimationGroup, built once per look and direction and given
-- its distances before each play; Scroll's easing is the one OnUpdate, set
-- for the ease and taken off when it lands. At rest nothing runs: a pass
-- through it compares a few numbers and places one frame only when the
-- foot moved, and makes nothing.
-------------------------------------------------------------

ns.DividerNotch = ns.DividerNotch or {}
local DN = ns.DividerNotch

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local format = string.format

local WHITE = "Interface\\AddOns\\Postbox\\Media\\white8x8.tga"

local function Th() return ns.Theme end
local function L() return ns.L end
local function Parts() return ns.CollectTab and ns.CollectTab.DividerParts end

-- The tab's height, the room each side of its words (the chip's, of its
-- number), and the fade under it at the list's foot.
DN.TAB_H = 16
DN.PAD = 12
DN.CHIP_PAD = 7
DN.FADE_H = 20
DN.FADE_A = 0.9
-- The tab's edges in the hairline's ink, its lift over the list's ground
-- (brighter under the pointer), the drawer's lip.
DN.EDGE_A = 0.18
DN.WASH_A, DN.WASH_HOVER = 0.05, 0.10
DN.LIP_A = 0.14
-- The drawer's shade under the opening divider, the curtain's soft edge.
DN.SHADE_H, DN.SHADE_A = 10, 0.35
DN.EDGE_H = 12
-- Closing plays at this share of opening's time.
DN.CLOSE = 0.85
-- Scroll: how long a jump is eased over; a step past this share of the way
-- is a jump; how many rows before its own the opening starts.
DN.EASE = 0.18
DN.JUMP = 0.25
DN.ZONE = 1

-------------------------------------------------------------
-- Build
-------------------------------------------------------------

local function Tiny(fs)
  local shared = Th()._sharedTheme
  if shared and type(shared.BindFont) == "function" then shared.BindFont(fs, "tiny") end
end

local function Text(parent)
  local fs = Th().CreateText(parent, "secondary")
  Tiny(fs)
  fs:Hide()
  return fs
end

local function Edge(parent, layer)
  local t = parent:CreateTexture(nil, layer or "BORDER")
  t:SetTexture(WHITE)
  Th().SetColor(t, "textSecondary")
  t:SetAlpha(DN.EDGE_A)
  return t
end

-- A soft band: `lo` at its foot, `hi` at its head, kept and retinted (a
-- gradient takes colour objects, and a new pair per paint would be garbage).
local function Band(parent, sub)
  local t = parent:CreateTexture(nil, "BACKGROUND", nil, sub)
  t:SetTexture(WHITE)
  t:Hide()
  if type(CreateColor) == "function" and t.SetGradient then
    t.lo, t.hi = CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0)
  end
  return t
end

local function Tint(t, r, g, b, aLo, aHi)
  if t.lo then
    t.lo:SetRGBA(r, g, b, aLo)
    t.hi:SetRGBA(r, g, b, aHi)
    t:SetGradient("VERTICAL", t.lo, t.hi)
  else
    t:SetVertexColor(r, g, b, (aLo + aHi) / 2)
  end
end

function DN.Build(panel)
  local child = panel.MailListChild
  local N = CreateFrame("Button", nil, child)
  N:RegisterForClicks("LeftButtonUp")
  N:SetHeight(DN.TAB_H)
  N:Hide()
  N.panel = panel
  N.groups = {}
  -- Under the tab, the list's foot fading into its ground, so a row passing
  -- under the notch reads as passing under it, not cut.
  N.Fade = Band(N, -8)
  N.Fade:SetPoint("BOTTOMLEFT", N, "BOTTOMLEFT", 0, 0)
  N.Fade:SetPoint("BOTTOMRIGHT", N, "BOTTOMRIGHT", 0, 0)
  N.Fade:SetHeight(DN.FADE_H)
  -- Over the rows that come in under an opening divider, for a moment: the
  -- list's ground, then its soft leading edge (Drawer's wipe).
  N.Curtain = N:CreateTexture(nil, "BACKGROUND", nil, -6)
  N.Curtain:SetTexture(WHITE)
  N.Curtain:Hide()
  N.CurtainEdge = Band(N, -5)
  N.Shade = Band(N, -4)
  -- Drawer's lip: across the foot at the tab's top.
  N.Lip = Edge(N, "BORDER")
  N.Lip:SetHeight(1)
  N.Lip:Hide()
  -- The divider's parts, travelling between the notch and the divider.
  N.GSign = Text(N)
  N.GWords = Text(N)
  N.GNum = Text(N)
  N.GTail = Text(N)
  N.GDelete = Text(N)
  N.GRule = N:CreateTexture(nil, "ARTWORK")
  N.GRule:SetTexture(WHITE)
  N.GRule:SetHeight(1)
  Th().SetColor(N.GRule, "textSecondary")
  N.GRule:Hide()
  -- The tab: the list's ground lifted a touch, its top and sides in the
  -- hairline's ink, and the words (Count: the number).
  local tab = CreateFrame("Frame", nil, N)
  tab:SetSize(DN.TAB_H * 2, DN.TAB_H)
  tab.Fill = tab:CreateTexture(nil, "BACKGROUND", nil, -8)
  tab.Fill:SetAllPoints()
  tab.Fill:SetTexture(WHITE)
  tab.Wash = tab:CreateTexture(nil, "BACKGROUND", nil, -7)
  tab.Wash:SetAllPoints()
  Th().FillChrome(tab.Wash, DN.WASH_A)
  tab.Top = Edge(tab)
  tab.Top:SetPoint("TOPLEFT", tab, "TOPLEFT", 0, 0)
  tab.Top:SetPoint("TOPRIGHT", tab, "TOPRIGHT", 0, 0)
  tab.Top:SetHeight(1)
  tab.Left = Edge(tab)
  tab.Left:SetPoint("TOPLEFT", tab, "TOPLEFT", 0, -1)
  tab.Left:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 0, 0)
  tab.Left:SetWidth(1)
  tab.Right = Edge(tab)
  tab.Right:SetPoint("TOPRIGHT", tab, "TOPRIGHT", 0, -1)
  tab.Right:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", 0, 0)
  tab.Right:SetWidth(1)
  tab.Text = Text(tab)
  tab.Text:SetPoint("CENTER", tab, "CENTER", 0, 0)
  tab.Text:Show()
  N.Tab = tab
  N:SetScript("OnClick", DN.Click)
  N:SetScript("OnEnter", DN.Enter)
  N:SetScript("OnLeave", DN.Leave)
  N:SetScript("OnHide", DN.Hidden)
  panel.Notch = N
  return N
end

-------------------------------------------------------------
-- Paint: the words, the sizes, the colours -- each only when it moved
-------------------------------------------------------------

-- The list's own colour, as the pinned copy stood on (CollectTab,
-- RV.PaintGround), under the tab, the fade and the curtain.
function DN.Ground(N, panel)
  local area = panel.MailListArea
  local r, g, b
  if area and type(area.GetBackdropColor) == "function" then r, g, b = area:GetBackdropColor() end
  if type(r) ~= "number" then
    local c = Th().Colors.surface
    r, g, b = c[1], c[2], c[3]
  end
  if N.gr == r and N.gg == g and N.gb == b then return end
  N.gr, N.gg, N.gb = r, g, b
  N.Tab.Fill:SetVertexColor(r, g, b, 0.95)
  N.Curtain:SetVertexColor(r, g, b, 0.95)
  Tint(N.Fade, r, g, b, DN.FADE_A, 0)
  Tint(N.CurtainEdge, r, g, b, 0.95, 0)
  Tint(N.Shade, 0, 0, 0, 0, DN.SHADE_A)
end

function DN.Paint(N, panel, look)
  DN.Ground(N, panel)
  local P = Parts()
  local loc = L()
  local words = P.Words()
  local count = panel._readCount or 0
  local n = P.Count(panel, words)
  local W = panel.MailListChild:GetWidth() or 0
  if N.__n == n and N.__count == count and N.__words == words and N.__loc == loc
      and N.__look == look and N.W == W then
    return
  end
  local M = Th().Metrics
  if N.__loc ~= loc then
    N.GDelete:SetText(loc["BTN_DELETE_ALL"])
    N.delW = N.GDelete:GetStringWidth() or 0
    N.GSign:SetText(P.SIGN)
  end
  N.__n, N.__count, N.__words, N.__loc, N.__look, N.W = n, count, words, loc, look, W
  local text = P.Text(loc, words, n)
  N.text = text
  N.GWords:SetText(text)
  N.textW = N.GWords:GetStringWidth() or 0
  local chip = look == "count"
  N.Tab.Text:SetText(chip and format("%d", count) or text)
  local inner = N.Tab.Text:GetStringWidth() or 0
  N.tabTextW = inner
  N.tabW = floor(inner + 2 * (chip and DN.CHIP_PAD or DN.PAD) + 0.5)
  if N.tabW < 2 * DN.TAB_H then N.tabW = 2 * DN.TAB_H end
  -- Where the divider's parts stand in its slot (CollectTab,
  -- RV.DividerLook's Hairline): the sign at the inset, the words past the
  -- fold mark's room, Delete all at the far inset, the rule between.
  N.inset = M.inset
  N.textX = M.inset + P.FOLD
  N.ruleL = N.textX + N.textW + M.gap
  N.ruleR = W - M.inset - (N.delW or 0) - M.gap
  if N.ruleR < N.ruleL + 1 then N.ruleR = N.ruleL + 1 end
  N.split, N.ad = nil, nil
  if N.rest == "notch" then
    N.rest = nil
    DN.Rest(N, "notch")
  end
end

-- Show mail counts moved (CollectTab, CT.RepaintBoxCounts): the words again.
function DN.Repaint(panel)
  local N = panel.Notch
  if N and N:IsShown() and ns.CollectTab then ns.CollectTab.RebindRows(panel) end
end

-------------------------------------------------------------
-- Rest: the notch standing, or put away for the divider
-------------------------------------------------------------

local function HideGhosts(N)
  N.GSign:Hide()
  N.GWords:Hide()
  N.GNum:Hide()
  N.GTail:Hide()
  N.GDelete:Hide()
  N.GRule:Hide()
  N.Curtain:Hide()
  N.CurtainEdge:Hide()
  N.Shade:Hide()
end

local function Hit(N, left, right)
  local l, r = floor(left), floor(N.W - right)
  if N.hitL ~= l or N.hitR ~= r then
    N.hitL, N.hitR = l, r
    N:SetHitRectInsets(max(0, l), max(0, r), 0, 0)
  end
end

-- The tab and the lip where they stand at rest, whole.
local function Home(N)
  local tab = N.Tab
  tab:ClearAllPoints()
  tab:SetPoint("BOTTOM", N, "BOTTOM", 0, 0)
  tab:SetSize(N.tabW, DN.TAB_H)
  tab:SetAlpha(1)
  tab.Text:SetAlpha(1)
  tab.Fill:SetAlpha(1)
  tab.Wash:SetAlpha(1)
  tab.Left:SetAlpha(DN.EDGE_A)
  tab.Right:SetAlpha(DN.EDGE_A)
  tab.Top:SetAlpha(DN.EDGE_A)
  tab:Show()
  local lip = N.Lip
  lip:ClearAllPoints()
  lip:SetPoint("BOTTOMLEFT", N, "BOTTOMLEFT", 0, DN.TAB_H - 1)
  lip:SetPoint("BOTTOMRIGHT", N, "BOTTOMRIGHT", 0, DN.TAB_H - 1)
  lip:SetAlpha(DN.LIP_A)
  lip:SetShown(N.look == "drawer")
  N.Fade:SetAlpha(1)
  N.Fade:Show()
end

function DN.Rest(N, face)
  if N.rest == face then return end
  N.rest = face
  if face == "header" then
    N:Hide()
    return
  end
  HideGhosts(N)
  Home(N)
  local half = (N.W - N.tabW) / 2
  Hit(N, half, half + N.tabW)
  N:EnableMouse(true)
  N:Show()
end

-------------------------------------------------------------
-- The timed looks: one group per look and direction
-------------------------------------------------------------

local function Anim(g, kind, target, dur, delay, smooth)
  local a = g:CreateAnimation(kind)
  a:SetTarget(target)
  a:SetDuration(dur)
  if delay and delay > 0 then a:SetStartDelay(delay) end
  if smooth then a:SetSmoothing(smooth) end
  return a
end

local function Fade(g, target, from, to, dur, delay)
  local a = Anim(g, "Alpha", target, dur, delay)
  a:SetFromAlpha(from)
  a:SetToAlpha(to)
  return a
end

local function Scale(g, target, dur, delay, smooth, fx, fy, tx, ty, point)
  local a = Anim(g, "Scale", target, dur, delay, smooth)
  a:SetScaleFrom(fx, fy)
  a:SetScaleTo(tx, ty)
  a:SetOrigin(point or "CENTER", 0, 0)
  return a
end

-- One look's groups, made the first time it plays them. `g.a` holds the
-- moves whose distances each play sets.
DN.MAKE = {}

local function NewGroup(N)
  local g = N:CreateAnimationGroup()
  g:SetToFinalAlpha(true)
  g:SetScript("OnFinished", DN.Landed)
  g.N = N
  g.a = {}
  return g
end

-- What every timed look shares opening: the words travel from the tab's
-- to the divider's; the sign and Delete all come in from a few units off;
-- the rows under it out from behind the list's ground.
local function Arrivals(g, N, t)
  local a = g.a
  a.words = Anim(g, "Translation", N.GWords, t.words, t.wordsAt, "OUT")
  Fade(g, N.GSign, 0, 1, t.sign, t.signAt)
  a.sign = Anim(g, "Translation", N.GSign, t.sign, t.signAt, "OUT")
  Fade(g, N.GDelete, 0, 1, t.del, t.delAt)
  a.del = Anim(g, "Translation", N.GDelete, t.del, t.delAt, "OUT")
end

-- ... and closing, the other way and quicker.
local function Departures(g, N, t)
  local k = DN.CLOSE
  local a = g.a
  a.words = Anim(g, "Translation", N.GWords, t.words * k, 0, "IN")
  Fade(g, N.GSign, 1, 0, t.sign * k)
  a.sign = Anim(g, "Translation", N.GSign, t.sign * k, 0, "IN")
  Fade(g, N.GDelete, 1, 0, t.del * k)
  a.del = Anim(g, "Translation", N.GDelete, t.del * k, 0, "IN")
end

-- The notch coming back at the foot on its own (the divider scrolled away).
local function NotchIn(N, sx, sy, point)
  local g = NewGroup(N)
  Fade(g, N.Tab, 0, 1, 0.14)
  Scale(g, N.Tab, 0.17, 0, "OUT", sx, sy, 1, 1, point)
  Fade(g, N.Fade, 0, 1, 0.14)
  Fade(g, N.Lip, 0, DN.LIP_A, 0.14)
  return g
end

local STRETCH = { words = 0.24, sign = 0.13, signAt = 0.11, del = 0.17, delAt = 0.08 }
DN.MAKE.stretch = {
  open = function(N)
    local g = NewGroup(N)
    local a = g.a
    Fade(g, N.Tab, 1, 0, 0.20)
    Scale(g, N.Tab, 0.20, 0, "OUT", 1, 1, 1.5, 0.6, "BOTTOM")
    Fade(g, N.Fade, 1, 0, 0.20)
    Arrivals(g, N, STRETCH)
    a.ruleA = Fade(g, N.GRule, 0, 0, 0.05)
    a.rule = Anim(g, "Translation", N.GRule, 0.24, 0, "OUT")
    a.ruleS = Anim(g, "Scale", N.GRule, 0.24, 0, "OUT")
    Fade(g, N.Curtain, 1, 0, 0.17, 0.07)
    return g
  end,
  close = function(N)
    local g = NewGroup(N)
    local a = g.a
    local k = DN.CLOSE
    Departures(g, N, STRETCH)
    a.ruleA = Fade(g, N.GRule, 0, 0, 0.05 * k, 0.15 * k)
    a.rule = Anim(g, "Translation", N.GRule, 0.24 * k, 0, "IN")
    a.ruleS = Anim(g, "Scale", N.GRule, 0.24 * k, 0, "IN")
    Fade(g, N.Tab, 0, 1, 0.17 * k, 0.07 * k)
    Scale(g, N.Tab, 0.17 * k, 0.07 * k, "OUT", 1.5, 0.6, 1, 1, "BOTTOM")
    Fade(g, N.Fade, 0, 1, 0.17 * k, 0.07 * k)
    return g
  end,
  notchIn = function(N) return NotchIn(N, 1.3, 0.7, "BOTTOM") end,
}

local COUNT = { words = 0.20, wordsAt = 0.05, sign = 0.12, signAt = 0.12, del = 0.15, delAt = 0.12 }
DN.MAKE.count = {
  open = function(N)
    local g = NewGroup(N)
    local a = g.a
    Fade(g, N.Tab, 1, 0, 0.16)
    Scale(g, N.Tab, 0.16, 0, "OUT", 1, 1, 0.7, 0.7, "CENTER")
    Fade(g, N.Fade, 1, 0, 0.16)
    a.num = Anim(g, "Translation", N.GNum, 0.24, 0, "OUT")
    a.numA = Fade(g, N.GNum, 1, 1, 0.08, 0.16)
    Fade(g, N.GWords, 0, 1, COUNT.words, COUNT.wordsAt)
    Arrivals(g, N, COUNT)
    Fade(g, N.GTail, 0, 1, 0.11, 0.13)
    a.ruleA = Fade(g, N.GRule, 0, 0, 0.04, 0.10)
    a.ruleS = Scale(g, N.GRule, 0.18, 0.10, "OUT", 0.02, 1, 1, 1, "LEFT")
    Fade(g, N.Curtain, 1, 0, 0.17, 0.07)
    return g
  end,
  close = function(N)
    local g = NewGroup(N)
    local a = g.a
    local k = DN.CLOSE
    a.num = Anim(g, "Translation", N.GNum, 0.24 * k, 0, "IN")
    a.numA = Fade(g, N.GNum, 1, 1, 0.08 * k)
    Fade(g, N.GWords, 1, 0, COUNT.words * k)
    Departures(g, N, COUNT)
    Fade(g, N.GTail, 1, 0, 0.11 * k)
    a.ruleA = Fade(g, N.GRule, 0, 0, 0.04 * k, 0.14 * k)
    a.ruleS = Scale(g, N.GRule, 0.18 * k, 0, "IN", 1, 1, 0.02, 1, "LEFT")
    Fade(g, N.Tab, 0, 1, 0.14 * k, 0.10 * k)
    Scale(g, N.Tab, 0.14 * k, 0.10 * k, "OUT", 0.7, 0.7, 1, 1, "CENTER")
    Fade(g, N.Fade, 0, 1, 0.14 * k, 0.10 * k)
    return g
  end,
  notchIn = function(N) return NotchIn(N, 0.7, 0.7, "CENTER") end,
}

local DRAWER = { words = 0.24, sign = 0.14, signAt = 0.10, del = 0.16, delAt = 0.09 }
DN.MAKE.drawer = {
  open = function(N)
    local g = NewGroup(N)
    local a = g.a
    a.tab = Anim(g, "Translation", N.Tab, 0.22, 0, "OUT")
    Fade(g, N.Tab, 1, 0, 0.22)
    a.lip = Anim(g, "Translation", N.Lip, 0.24, 0, "OUT")
    Fade(g, N.Lip, DN.LIP_A, 0, 0.24)
    Fade(g, N.Fade, 1, 0, 0.20)
    Arrivals(g, N, DRAWER)
    a.ruleA = Fade(g, N.GRule, 0, 0, 0.156, 0.084)
    a.curtain = Anim(g, "Translation", N.Curtain, 0.24, 0.04, "IN_OUT")
    a.edge = Anim(g, "Translation", N.CurtainEdge, 0.24, 0.04, "IN_OUT")
    -- The shade blooms and goes in a group of its own: two steps, one
    -- after the other.
    local s = N:CreateAnimationGroup()
    s:SetToFinalAlpha(true)
    local up = Fade(s, N.Shade, 0, 1, 0.10)
    up:SetOrder(1)
    local down = Fade(s, N.Shade, 1, 0, 0.18)
    down:SetOrder(2)
    g.shade = s
    return g
  end,
  close = function(N)
    local g = NewGroup(N)
    local a = g.a
    local k = DN.CLOSE
    Departures(g, N, DRAWER)
    a.ruleA = Fade(g, N.GRule, 0, 0, 0.08 * k)
    a.tab = Anim(g, "Translation", N.Tab, 0.22 * k, 0, "OUT")
    Fade(g, N.Tab, 0, 1, 0.22 * k)
    a.lip = Anim(g, "Translation", N.Lip, 0.24 * k, 0, "OUT")
    Fade(g, N.Lip, 0, DN.LIP_A, 0.24 * k)
    Fade(g, N.Fade, 0, 1, 0.20 * k)
    return g
  end,
  notchIn = function(N) return NotchIn(N, 1, 0.6, "BOTTOM") end,
}

function DN.Group(N, look, kind)
  local set = N.groups[look]
  if not set then
    set = {}
    N.groups[look] = set
  end
  local g = set[kind]
  if not g then
    g = DN.MAKE[look][kind](N)
    set[kind] = g
  end
  return g
end

-- A part of the divider at its place in the slot, moved (dx, dy) off it.
local function At(region, divider, point, x, dx, dy)
  region:ClearAllPoints()
  region:SetPoint(point, divider, (point == "TOPLEFT") and "LEFT" or point, x + dx, dy)
  region:Show()
end

-- Count's words in three: before the number, the number, after it -- from
-- the words as they are, kept until they change.
local function Split(N, count)
  local text = N.text
  if N.split == text then return end
  N.split = text
  local s, e = string.find(text, "%d+")
  if s then
    N.GWords:SetText(string.sub(text, 1, s - 1))
    N.GNum:SetText(string.sub(text, s, e))
    N.GTail:SetText(string.sub(text, e + 1))
    N.numIn = true
  else
    -- No number in the words (Show mail counts is off): the chip's flies to
    -- the words' end and goes there.
    N.GWords:SetText(text)
    N.GNum:SetText(format("%d", count))
    N.GTail:SetText("")
    N.numIn = false
  end
  N.wordsW = N.GWords:GetStringWidth() or 0
  N.numW = N.GNum:GetStringWidth() or 0
end

-- Places every part for a play of `kind` and starts it. Distances are in
-- the divider's frame: x from its left, y up from its middle.
function DN.Play(N, panel, kind)
  local look = N.look
  local g = DN.Group(N, look, kind)
  local a = g.a
  local P = Parts()
  local divider = panel.Divider
  local tabH, h, lift = DN.TAB_H, N.height, N.lift
  local W = N.W
  local opening = kind == "open"
  -- The tab's middle and top, and where its words start.
  local tabY = tabH / 2 - h / 2 - lift
  local tabTop = tabY + tabH / 2
  local tabTextL = (W - N.tabTextW) / 2
  local sign = opening and 1 or -1
  HideGhosts(N)
  Home(N)
  N.Tab.Text:SetAlpha(0)
  if kind == "notchIn" then
    N.Tab.Text:SetAlpha(1)
    N.Tab:SetAlpha(0)
    N.Fade:SetAlpha(0)
    N.Lip:SetAlpha(0)
    local half = (W - N.tabW) / 2
    Hit(N, half, half + N.tabW)
    N:EnableMouse(true)
  else
    N:EnableMouse(false)
    if not opening then
      N.Tab:SetAlpha(0)
      N.Fade:SetAlpha(0)
      N.Lip:SetAlpha(0)
    end
    -- The words: whole, or (Count) in three about the number.
    local wordsX = N.textX
    if look == "count" then
      Split(N, panel._readCount or 0)
      local numX = N.textX + N.wordsW
      local chipL = (W - N.numW) / 2
      At(N.GNum, divider, "LEFT", numX, opening and (chipL - numX) or 0, opening and tabY or 0)
      a.num:SetOffset(sign * (numX - chipL), sign * -tabY)
      -- A number the words do not carry goes as it lands (comes as it
      -- leaves, closing).
      local stays = N.numIn and 1 or 0
      a.numA:SetFromAlpha(opening and 1 or stays)
      a.numA:SetToAlpha(opening and stays or 1)
      N.GNum:SetAlpha(opening and 1 or stays)
      At(N.GTail, divider, "LEFT", numX + N.numW, 0, 0)
      N.GTail:SetAlpha(opening and 0 or 1)
      At(N.GWords, divider, "LEFT", wordsX, opening and 14 or 0, 0)
      N.GWords:SetAlpha(opening and 0 or 1)
      a.words:SetOffset(sign * -14, 0)
    else
      N.GWords:SetText(N.text)
      N.split = nil
      local dx, dy = tabTextL - wordsX, tabY
      At(N.GWords, divider, "LEFT", wordsX, opening and dx or 0, opening and dy or 0)
      N.GWords:SetAlpha(1)
      a.words:SetOffset(sign * -dx, sign * -dy)
    end
    At(N.GSign, divider, "LEFT", N.inset, opening and 5 or 0, 0)
    N.GSign:SetAlpha(opening and 0 or 1)
    a.sign:SetOffset(sign * -5, 0)
    At(N.GDelete, divider, "RIGHT", -N.inset, opening and -10 or 0, 0)
    N.GDelete:SetAlpha(opening and 0 or 1)
    a.del:SetOffset(sign * 10, 0)
    -- The hairline: from the words to Delete all, its top on the middle.
    local ruleL, ruleW = N.ruleL, N.ruleR - N.ruleL
    local rule = N.GRule
    rule:SetWidth(ruleW)
    a.ruleA:SetFromAlpha(opening and 0 or P.RULE_A)
    a.ruleA:SetToAlpha(opening and P.RULE_A or 0)
    rule:SetAlpha(opening and 0 or P.RULE_A)
    if look == "stretch" then
      -- It starts as the tab's top edge: scaled about the point that maps
      -- its ends onto the tab's, and moved up from the tab's top.
      local s = N.tabW / ruleW
      local tabL = (W - N.tabW) / 2
      local ox = 0
      if abs(1 - s) > 0.001 then ox = (tabL - s * ruleL) / (1 - s) - ruleL end
      a.ruleS:SetOrigin("LEFT", ox, 0)
      if opening then
        a.ruleS:SetScaleFrom(s, 1)
        a.ruleS:SetScaleTo(1, 1)
      else
        a.ruleS:SetScaleFrom(1, 1)
        a.ruleS:SetScaleTo(s, 1)
      end
      At(rule, divider, "TOPLEFT", ruleL, 0, opening and tabTop or 0)
      a.rule:SetOffset(0, sign * -tabTop)
    else
      At(rule, divider, "TOPLEFT", ruleL, 0, 0)
    end
    if look == "drawer" then
      -- Tab and lip rise from the foot to the divider's middle (closing,
      -- they come down from it).
      local rise = -tabY
      local lipRise = h / 2 + lift - tabH
      if not opening then
        N.Tab:ClearAllPoints()
        N.Tab:SetPoint("BOTTOM", N, "BOTTOM", 0, rise)
        N.Lip:ClearAllPoints()
        N.Lip:SetPoint("BOTTOMLEFT", N, "BOTTOMLEFT", 0, tabH - 1 + lipRise)
        N.Lip:SetPoint("BOTTOMRIGHT", N, "BOTTOMRIGHT", 0, tabH - 1 + lipRise)
      end
      a.tab:SetOffset(0, sign * rise)
      a.lip:SetOffset(0, sign * lipRise)
    end
    -- The rows coming in under it, from behind the list's ground: faded
    -- (Stretch, Count) or wiped downward (Drawer). Not while it closes, and
    -- not where no row is under it.
    if opening and lift > 1 then
      local curtain = N.Curtain
      local edge = look == "drawer" and DN.EDGE_H or 0
      curtain:ClearAllPoints()
      curtain:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -edge)
      curtain:SetPoint("BOTTOMRIGHT", N, "BOTTOMRIGHT", 0, 0)
      curtain:SetAlpha(1)
      curtain:Show()
      if look == "drawer" then
        local band = N.CurtainEdge
        band:ClearAllPoints()
        band:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, 0)
        band:SetPoint("TOPRIGHT", divider, "BOTTOMRIGHT", 0, 0)
        band:SetHeight(min(edge, lift))
        band:Show()
        a.curtain:SetOffset(0, -(lift + edge))
        a.edge:SetOffset(0, -(lift + edge))
      end
    end
    if look == "drawer" and opening then
      local shade = N.Shade
      shade:ClearAllPoints()
      shade:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, 0)
      shade:SetPoint("TOPRIGHT", divider, "BOTTOMRIGHT", 0, 0)
      shade:SetHeight(min(DN.SHADE_H, max(1, lift)))
      shade:SetAlpha(0)
      shade:SetShown(lift > 1)
    end
  end
  N.rest = nil
  N.playing = g
  N:Show()
  g:Play()
  if g.shade and opening then g.shade:Play() end
end

-- A play ended: the parts put away, and the list drawn again, which shows
-- the divider (or the notch) at rest.
function DN.Landed(g)
  local N = g.N
  if N.playing ~= g then return end
  DN.Settle(N)
  if ns.CollectTab then ns.CollectTab.RebindRows(N.panel) end
end

-- Whatever is playing stopped where it is; at rest after the next pass.
function DN.Settle(N)
  local g = N.playing
  N.playing = nil
  if g then
    if g.shade then g.shade:Stop() end
    if g:IsPlaying() then g:Stop() end
  end
  HideGhosts(N)
  N.rest = nil
end

-------------------------------------------------------------
-- Scroll: scrubbed by the list's own scroll
-------------------------------------------------------------

-- The notch `d` of the way into the divider: the tab's top edge spreads
-- from its own ends to the hairline's and climbs to the divider's middle,
-- its ground and sides thin out, the words slide from its middle to their
-- place, the sign and Delete all come up over the last part.
function DN.Apply(N, d)
  if N.rest ~= "scrub" then
    N.rest = "scrub"
    HideGhosts(N)
    Home(N)
    N.Lip:Hide()
    N.Tab.Text:SetAlpha(0)
    N.GWords:SetText(N.text)
    N.split = nil
    N.GWords:SetAlpha(1)
    N.GWords:Show()
    N.GSign:Show()
    N.GDelete:Show()
    N:EnableMouse(true)
    N:Show()
    N.ad = nil
  end
  -- Placed already, where nothing moved (a pass at rest).
  if N.ad == d and N.alift == N.lift and N.aW == N.W and N.ah == N.height then return end
  N.ad, N.alift, N.aW, N.ah = d, N.lift, N.W, N.height
  local W, tabH = N.W, DN.TAB_H
  local tl = (W - N.tabW) / 2
  local tr = tl + N.tabW
  local left = tl + (N.ruleL - tl) * d
  local right = tr + (N.ruleR - tr) * d
  local mid = N.height / 2 + N.lift
  local top = tabH + (mid - tabH) * d
  local tab = N.Tab
  tab:ClearAllPoints()
  tab:SetPoint("BOTTOMLEFT", N, "BOTTOMLEFT", left, 0)
  tab:SetSize(max(1, right - left), max(1, top))
  local thin = 1 - d
  tab.Fill:SetAlpha(thin)
  tab.Wash:SetAlpha(thin)
  tab.Left:SetAlpha(DN.EDGE_A * thin)
  tab.Right:SetAlpha(DN.EDGE_A * thin)
  tab.Top:SetAlpha(DN.EDGE_A + (Parts().RULE_A - DN.EDGE_A) * d)
  N.Fade:SetAlpha(thin)
  local words = N.GWords
  words:ClearAllPoints()
  words:SetPoint("LEFT", N, "BOTTOMLEFT", (W - N.textW) / 2 * thin + N.textX * d, tabH / 2 + (mid - tabH / 2) * d)
  local late = (d - 0.55) / 0.45
  if late < 0 then late = 0 elseif late > 1 then late = 1 end
  N.GSign:ClearAllPoints()
  N.GSign:SetPoint("LEFT", N, "BOTTOMLEFT", N.inset, mid)
  N.GSign:SetAlpha(late)
  N.GDelete:ClearAllPoints()
  N.GDelete:SetPoint("RIGHT", N, "BOTTOMRIGHT", -N.inset, mid)
  N.GDelete:SetAlpha(late)
  Hit(N, left, right)
end

-- One frame of an ease: cubic, out, from where it was to where the list now
-- says; it takes itself off when it lands.
function DN.Tick(N, elapsed)
  N.t = N.t + (elapsed or 0)
  local k = N.t / DN.EASE
  local d
  if k >= 1 then
    d = N.to
  else
    local u = 1 - k
    d = N.d0 + (N.to - N.d0) * (1 - u * u * u)
  end
  N.d = d
  DN.Apply(N, d)
  if k >= 1 then
    N.easing = false
    N:SetScript("OnUpdate", nil)
    if d >= 1 and ns.CollectTab then ns.CollectTab.RebindRows(N.panel) end
  end
end

function DN.EaseFrom(N, from, to)
  N.d0, N.to, N.t = from, to, 0
  if not N.easing then
    N.easing = true
    N:SetScript("OnUpdate", DN.Tick)
  end
end

function DN.Scrub(N, folded, slotTop, slotBottom, foot, stride)
  local p = 0
  if not folded then
    if slotBottom <= foot + 0.5 then
      p = 1
    else
      local from = slotTop - stride * DN.ZONE
      p = (foot - from) / (slotBottom - from)
      if p < 0 then p = 0 elseif p > 1 then p = 1 end
    end
  end
  local d = N.d
  if N.easing then
    if abs(p - N.to) > DN.JUMP then DN.EaseFrom(N, d, p) else N.to = p end
  elseif d == nil then
    N.d = p
  elseif abs(p - d) > DN.JUMP then
    DN.EaseFrom(N, d, p)
  else
    N.d = p
  end
  if not N.easing and N.d >= 1 then
    DN.Rest(N, "header")
    return false
  end
  DN.Apply(N, N.d)
  return true
end

-------------------------------------------------------------
-- The pass (CollectTab, RV.UpdatePin)
-------------------------------------------------------------

-- Stops and forgets everything: a look changed, the notch put away, the
-- window hidden.
function DN.Reset(N)
  DN.Settle(N)
  if N.easing then
    N.easing = false
    N:SetScript("OnUpdate", nil)
  end
  N.face, N.d, N.rest, N.footView = nil, nil, nil, nil
end

function DN.Off(panel)
  local N = panel.Notch
  if not N or not (N:IsShown() or N.face or N.d or N.playing) then return end
  DN.Reset(N)
  N:Hide()
end

-- The notch on the list's foot: the view's, or the list's own end where the
-- list is shorter than the view (it must not reach past the list, which the
-- client would scroll to).
local function Place(N, child, foot)
  local y = -(foot - DN.TAB_H)
  if N.y ~= y then
    N.y = y
    N:ClearAllPoints()
    N:SetPoint("TOPLEFT", child, "TOPLEFT", 0, y)
    N:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, y)
  end
  -- Where the pinned copy stood, a few levels over the rows; its tab a level
  -- higher, still under the fan's plate (CollectTab, + 10).
  local level = child:GetFrameLevel() + 8
  if N.level ~= level then
    N.level = level
    N:SetFrameLevel(level)
  end
end

-- One pass of the list. -> whether the divider in its place is left undrawn
-- (the notch, or a move between, stands for it).
function DN.Update(panel, look, at, offset, viewport, stride, height)
  local N = panel.Notch
  if not at or viewport <= 0 then
    if N then DN.Off(panel) end
    return false
  end
  N = N or DN.Build(panel)
  if N.look ~= look then
    DN.Reset(N)
    N.look = look
  end
  local child = panel.MailListChild
  local slotTop = (at - 1) * stride
  local slotBottom = slotTop + height
  local foot = offset + viewport
  local listH = child:GetHeight() or foot
  if listH < foot then foot = listH end
  N.height = height
  -- Held by its own click (DN.Click): as it stands, until the click is done.
  if N.hold and (N.face or N.d) then return true end
  DN.Paint(N, panel, look)
  local folded = Parts().Folded(panel)
  if look == "scroll" then
    N.lift = max(0, foot - slotBottom)
    Place(N, child, foot)
    return DN.Scrub(N, folded, slotTop, slotBottom, foot, stride)
  end
  local inView = slotBottom <= foot + 0.5
  local face = (not folded and inView) and "header" or "notch"
  local was = N.face
  N.face = face
  -- The tab stands on the foot; opening, where it was last seen in the
  -- view, so the move starts from the notch the player saw (a click that
  -- unfolds a short list lengthens it under the notch).
  local tabFoot = foot
  if face == "header" and N.footView and (was == "notch" or (N.playing and N.playingTo == "header")) then
    tabFoot = min(listH, offset + N.footView)
  elseif face == "notch" then
    N.footView = foot - offset
  end
  N.lift = max(0, tabFoot - slotBottom)
  Place(N, child, tabFoot)
  if N.playing then
    -- A move toward where it already goes is left to run; it stops when
    -- the divider it stands for leaves the view.
    if N.playingTo == face and (face == "notch" or inView) then return true end
    DN.Settle(N)
  end
  if was == nil or was == face then
    DN.Rest(N, face)
    return face == "notch"
  end
  local kind = "notchIn"
  if face == "header" then
    kind = "open"
  elseif folded and inView then
    kind = "close"
  end
  N.playingTo = face
  DN.Play(N, panel, kind)
  return true
end

-------------------------------------------------------------
-- The notch's own scripts
-------------------------------------------------------------

-- A click is the pinned copy's: the read mail unfolded, and the list taken
-- to it (CollectTab, CT.Build).
-- The passes the click makes on its way (unfolded, then taken to the
-- divider) are held: the move starts once, from the notch to where the
-- divider ends up.
function DN.Click(N)
  local pin = N.panel and N.panel.DividerPin
  local click = pin and pin:GetScript("OnClick")
  if not click then return end
  N.hold = true
  click(pin, "LeftButton")
  N.hold = nil
  if ns.CollectTab then ns.CollectTab.RebindRows(N.panel) end
end

-- Lit under the pointer; where it shows only the number, the words in a
-- tooltip.
function DN.Enter(N)
  Th().FillChrome(N.Tab.Wash, DN.WASH_HOVER)
  local P = Parts()
  if N.look ~= "count" and P.Words() ~= "count" then return end
  local T = Th()
  local panel = N.panel
  T.TipBegin(N)
  T.TipTitle(P.Text(L(), "full", P.Count(panel, "full")))
  GameTooltip:Show()
  N.tip = true
end

function DN.Leave(N)
  Th().FillChrome(N.Tab.Wash, DN.WASH_A)
  if N.tip then
    N.tip = nil
    GameTooltip:Hide()
  end
end

-- Hidden with the list (another tab, the window closing): nothing left
-- running, and the next show starts at rest. Its own Hide (the divider
-- taking over) leaves it shown-flagged off, and changes nothing.
function DN.Hidden(N)
  if N:IsShown() then
    DN.Reset(N)
    N.y = nil
  end
end
