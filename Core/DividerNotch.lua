local _, ns = ...

-------------------------------------------------------------
-- Postbox :: the read mail's divider as a notch (Options, Mail, Divider:
-- the Notch looks; CollectTab, RV.LOOKS).
--
-- While the read mail is below the view, or folded, a small notch stands on
-- the list's foot in the pinned copy's place: a tab with the divider's words
-- (Stretch), or a chip with the number (Count), over a short fade of the
-- list's own ground, so a row passing under it reads as passing under it.
-- When the divider's place comes into the view, or a click on the notch
-- takes the list to it, the notch goes and the divider itself -- Hairline,
-- in its place -- draws itself in; scrolling away, or a click folding the
-- read mail, brings the notch back. Scrolling never unfolds what a click
-- folded: folded, it stays a notch at the foot.
--
-- Every move happens where it stands, never across the list: a wheel step
-- moves the list half a view at once (the template's step), so a divider
-- can come into the view anywhere, and anything travelling to it would be
-- chasing a moving target. In place, any frame of a move is a blend of the
-- two ends, and a move turned round half-way (the wheel back) runs back
-- from where it is.
--   stretch  the tab flattens and widens into a hairline across the foot,
--            which thins away (160 ms); coming back, the line gathers into
--            the tab.
--   count    the chip settles into the list's foot, smaller about its foot
--            as it fades (160 ms), and grows out of it coming back.
--   both     the divider fades in where it stands and its hairline draws
--            from the words to Delete all (220 ms).
--
-- Built as the house builds: the notch is one frame of Postbox's own in the
-- list (above the rows, as the pinned copy was, and clipped with them), made
-- on the first pass that wants it. Every texture is given its colour in the
-- call that makes it -- the ground as a colour texture, the inks through
-- Theme -- so nothing can stand white for a frame, whichever path shows it
-- first (the first build tinted a white file texture with SetGradient later,
-- and the client drew the fade solid white). A move is one OnUpdate on the
-- notch, set when it starts and taken off when it lands; at rest nothing
-- runs, and a pass through it compares a few numbers and makes nothing.
-------------------------------------------------------------

ns.DividerNotch = ns.DividerNotch or {}
local DN = ns.DividerNotch

local floor, max, min = math.floor, math.max, math.min
local format = string.format

local WHITE = "Interface\\AddOns\\Postbox\\Media\\white8x8.tga"

local function Th() return ns.Theme end
local function L() return ns.L end
local function Parts() return ns.CollectTab and ns.CollectTab.DividerParts end

-- The tab's height, the room each side of its words (the chip's, of its
-- number).
DN.TAB_H = 16
DN.PAD = 10
DN.CHIP_PAD = 7
-- The fade under it: steps of the list's ground from the foot up, each
-- DN.FADE_STEP tall, at these shares of the ground's alpha. Solid steps, not
-- a gradient: a colour texture is the one fill that is never drawn white.
DN.FADE = { 1, 0.84, 0.66, 0.48, 0.30, 0.14 }
DN.FADE_STEP = 3
-- The tab's edges in the hairline's ink, its lift over the list's ground
-- (brighter under the pointer).
DN.EDGE_A = 0.18
DN.WASH_A, DN.WASH_HOVER = 0.05, 0.10
-- How long the notch takes to go or come back, and the divider to draw
-- itself in.
DN.OUT = 0.16
DN.IN = 0.22
-- Count's chip at its smallest, gone.
DN.SMALL = 0.6

-------------------------------------------------------------
-- Build
-------------------------------------------------------------

local function Edge(parent)
  local t = parent:CreateTexture(nil, "BORDER")
  t:SetTexture(WHITE)
  Th().SetColor(t, "textSecondary")
  t:SetAlpha(DN.EDGE_A)
  return t
end

function DN.Build(panel)
  local P = Parts()
  local T = Th()
  local child = panel.MailListChild
  local r, g, b = P.Ground(panel)
  local ga = P.GROUND_A
  local N = CreateFrame("Button", nil, child)
  N:Hide()
  N.shown = false
  N:RegisterForClicks("LeftButtonUp")
  N:SetHeight(DN.TAB_H)
  N.panel = panel
  N.gr, N.gg, N.gb = r, g, b
  -- The fade, on a frame of its own so a move fades it with one call.
  local fade = CreateFrame("Frame", nil, N)
  fade:SetAllPoints()
  N.Fade = fade
  for i = 1, #DN.FADE do
    local t = fade:CreateTexture(nil, "BACKGROUND")
    t:SetColorTexture(r, g, b, ga * DN.FADE[i])
    local y = (i - 1) * DN.FADE_STEP
    t:SetPoint("BOTTOMLEFT", fade, "BOTTOMLEFT", 0, y)
    t:SetPoint("BOTTOMRIGHT", fade, "BOTTOMRIGHT", 0, y)
    t:SetHeight(DN.FADE_STEP)
    fade[i] = t
  end
  -- The tab: the list's ground lifted a touch, its top and sides in the
  -- hairline's ink, and the words (Count: the number), with Count and
  -- check's mark after them.
  local tab = CreateFrame("Frame", nil, N)
  tab:SetPoint("BOTTOM", N, "BOTTOM", 0, 0)
  tab:SetSize(DN.TAB_H * 2, DN.TAB_H)
  tab.Fill = tab:CreateTexture(nil, "BACKGROUND", nil, -8)
  tab.Fill:SetColorTexture(r, g, b, ga)
  tab.Fill:SetAllPoints()
  tab.Wash = tab:CreateTexture(nil, "BACKGROUND", nil, -7)
  T.FillChrome(tab.Wash, DN.WASH_A)
  tab.Wash:SetAllPoints()
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
  tab.Text = T.CreateText(tab, "secondary")
  local shared = T._sharedTheme
  if shared and type(shared.BindFont) == "function" then shared.BindFont(tab.Text, "tiny") end
  tab.Mark = T.Glyph(tab, "check", nil, "ARTWORK") or tab:CreateTexture(nil, "ARTWORK")
  T.SetColor(tab.Mark, "textSecondary")
  tab.Mark:Hide()
  N.Tab = tab
  N:SetScript("OnClick", DN.Click)
  N:SetScript("OnEnter", DN.Enter)
  N:SetScript("OnLeave", DN.Leave)
  N:SetScript("OnHide", DN.Hidden)
  panel.Notch = N
  return N
end

-------------------------------------------------------------
-- Paint: the ground, the words, the sizes -- each only when it moved
-------------------------------------------------------------

-- The list's own colour (CollectTab, RV.GroundColor: what the pinned copy
-- stands on) under the fade and the tab, again when it moved.
function DN.Ground(N, panel)
  local P = Parts()
  local r, g, b = P.Ground(panel)
  if N.gr == r and N.gg == g and N.gb == b then return end
  N.gr, N.gg, N.gb = r, g, b
  local ga = P.GROUND_A
  local fade = N.Fade
  for i = 1, #DN.FADE do fade[i]:SetColorTexture(r, g, b, ga * DN.FADE[i]) end
  N.Tab.Fill:SetColorTexture(r, g, b, ga)
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
  N.__n, N.__count, N.__words, N.__loc, N.__look, N.W = n, count, words, loc, look, W
  local tab = N.Tab
  local text = (look == "count") and format("%d", count) or P.Text(loc, words, n)
  tab.Text:SetText(text)
  local textW = tab.Text:GetStringWidth() or 0
  local mark = words == "check"
  local markW = 0
  if mark then
    local h = P.MarkSize(tab.Text)
    tab.Mark:SetSize(h, h)
    markW = P.MARK_GAP + h
  end
  tab.Mark:SetShown(mark)
  local pad = (look == "count") and DN.CHIP_PAD or DN.PAD
  local tabW = floor(textW + markW + 2 * pad + 0.5)
  if tabW < 2 * DN.TAB_H then tabW = 2 * DN.TAB_H end
  N.tabW = tabW
  tab.Text:ClearAllPoints()
  -- From the tab's middle, so the words stay centred while Stretch widens it.
  tab.Text:SetPoint("LEFT", tab, "CENTER", -floor((textW + markW) / 2 + 0.5), 0)
  if mark then
    tab.Mark:ClearAllPoints()
    tab.Mark:SetPoint("LEFT", tab.Text, "RIGHT", P.MARK_GAP, 0)
  end
  -- How wide Stretch's line runs: the hairline's own reach, inset to inset.
  N.spanW = max(tabW, W - 2 * Th().Metrics.inset)
  -- Only the tab takes the pointer.
  local side = max(0, floor((W - tabW) / 2))
  N:SetHitRectInsets(side, side, 0, 0)
  N.dirty = true
end

-- Show mail counts moved (CollectTab, CT.RepaintBoxCounts): the words again.
function DN.Repaint(panel)
  local N = panel.Notch
  if N and N:IsShown() and ns.CollectTab then ns.CollectTab.RebindRows(panel) end
end

-------------------------------------------------------------
-- The state drawn: N.v, how much of the notch stands (0..1); N.dv, while
-- the divider draws itself in, how far (0..1)
-------------------------------------------------------------

-- Even both ways, so a move turned round half-way runs back the way it came.
local function Ease(u)
  return u * u * (3 - 2 * u)
end

-- How far the divider's hairline still has to reach: from the words (and
-- Count and check's mark) to Delete all, as CollectTab places them.
local function RuleSpan(N, divider)
  local P = Parts()
  local M = Th().Metrics
  local from = M.inset + P.FOLD + (divider.Label:GetStringWidth() or 0) + M.gap
  if divider.__mark then from = from + P.MARK_GAP + (divider.Mark:GetWidth() or 0) end
  local to = N.W - M.inset - (divider.Delete.Text:GetStringWidth() or 0) - M.gap
  return max(0, to - from - 1)
end

function DN.Apply(N)
  local e = Ease(N.v or 1)
  local tab = N.Tab
  N.Fade:SetAlpha(e)
  if N.look == "count" then
    -- Settling into the foot: smaller about its foot as it fades. Scaled,
    -- not moved, so nothing of it ever stands past the list's end (the
    -- client would scroll to it).
    tab:SetSize(N.tabW, DN.TAB_H)
    tab:SetScale(DN.SMALL + (1 - DN.SMALL) * e)
    tab:SetAlpha(e)
  else
    -- Flattening into a line across the foot, which thins away last.
    local spanW = N.spanW
    tab:SetSize(floor(spanW + (N.tabW - spanW) * e + 0.5), 1 + (DN.TAB_H - 1) * e)
    tab.Fill:SetAlpha(e)
    tab.Wash:SetAlpha(e)
    tab.Left:SetAlpha(DN.EDGE_A * e)
    tab.Right:SetAlpha(DN.EDGE_A * e)
    local ruleA = Parts().RULE_A
    tab.Top:SetAlpha((ruleA + (DN.EDGE_A - ruleA) * e) * min(1, 3 * e))
    local words = e * e
    tab.Text:SetAlpha(words)
    tab.Mark:SetAlpha(words)
  end
  local dv = N.dv
  if dv then
    local divider = N.panel.Divider
    local d = Ease(dv)
    divider:SetAlpha(d)
    Parts().AnchorRule(divider, floor(RuleSpan(N, divider) * (1 - d) + 0.5))
  end
end

-- The divider drawn in whole: as CollectTab left it.
function DN.EndArrival(N)
  if not N.dv then return end
  N.dv = nil
  local divider = N.panel.Divider
  divider:SetAlpha(1)
  Parts().AnchorRule(divider, 0)
end

-- One frame of a move; it takes itself off when everything has landed.
function DN.Tick(N, elapsed)
  elapsed = min(elapsed or 0, 0.05)
  local moving = false
  local v, to = N.v, N.vTo
  if v ~= to then
    local step = elapsed / DN.OUT
    if to > v then v = min(to, v + step) else v = max(to, v - step) end
    N.v = v
    moving = v ~= to
  end
  local dv = N.dv
  if dv then
    dv = dv + elapsed / DN.IN
    if dv >= 1 then
      DN.EndArrival(N)
    else
      N.dv = dv
      moving = true
    end
  end
  DN.Apply(N)
  if not moving then DN.Land(N) end
end

function DN.Start(N)
  if not N.shown then
    N.shown = true
    N:Show()
  end
  if not N.moving then
    N.moving = true
    N:SetScript("OnUpdate", DN.Tick)
  end
end

-- Landed, or put to rest at once: no OnUpdate, and the notch hidden where
-- none of it stands. N.shown is its own Show and Hide, kept so a pass at
-- rest asks the client nothing.
function DN.Land(N)
  if N.moving then
    N.moving = false
    N:SetScript("OnUpdate", nil)
  end
  local shown = N.v ~= 0
  if N.shown ~= shown then
    N.shown = shown
    N:SetShown(shown)
  end
end

-- At rest after a pass: drawn again only where something moved.
function DN.Rest(N)
  if N.dirty or N.moving then
    N.dirty = false
    DN.Apply(N)
  end
  DN.Land(N)
end

-------------------------------------------------------------
-- The pass (CollectTab, RV.UpdatePin)
-------------------------------------------------------------

-- Stops and forgets everything: a look changed, the notch put away, the
-- window hidden. The divider is left whole.
function DN.Reset(N)
  DN.EndArrival(N)
  if N.moving then
    N.moving = false
    N:SetScript("OnUpdate", nil)
  end
  N.face, N.v, N.vTo, N.y = nil, nil, nil, nil
  N.__look = nil
  local tab = N.Tab
  tab:SetAlpha(1)
  tab.Fill:SetAlpha(1)
  tab.Wash:SetAlpha(1)
  tab.Left:SetAlpha(DN.EDGE_A)
  tab.Right:SetAlpha(DN.EDGE_A)
  tab.Top:SetAlpha(DN.EDGE_A)
  tab.Text:SetAlpha(1)
  tab.Mark:SetAlpha(1)
  tab:SetScale(1)
  N.Fade:SetAlpha(1)
end

function DN.Off(panel)
  local N = panel.Notch
  if not N or not (N:IsShown() or N.face or N.dv or N.moving) then return end
  DN.Reset(N)
  N.shown = false
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
  -- Where the pinned copy stood, a few levels over the rows, still under the
  -- fan's plate (CollectTab, + 10).
  local level = child:GetFrameLevel() + 8
  if N.level ~= level then
    N.level = level
    N:SetFrameLevel(level)
  end
end

-- The pointer taken only while the notch stands, set only when that moves.
local function Mouse(N, on)
  if N.mouse == on then return end
  N.mouse = on
  N:EnableMouse(on)
end

-- One pass of the list. -> whether the divider in its place is left undrawn
-- (the notch stands for it).
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
  local slotBottom = (at - 1) * stride + height
  local foot = offset + viewport
  local listH = child:GetHeight() or foot
  if listH < foot then foot = listH end
  DN.Paint(N, panel, look)
  Place(N, child, foot)
  local folded = Parts().Folded(panel)
  local face = (not folded and slotBottom <= foot + 0.5) and "header" or "notch"
  local was = N.face
  N.face = face
  if face == "notch" then
    -- The divider is not drawn: whatever it was doing is over.
    DN.EndArrival(N)
    N.vTo = 1
    if was == nil then N.v = 1 end
    Mouse(N, true)
  else
    N.vTo = 0
    if was == nil then
      N.v = 0
    elseif was == "notch" then
      N.dv = 0
    end
    Mouse(N, false)
  end
  if N.v ~= N.vTo or N.dv then
    DN.Start(N)
    DN.Apply(N)
  else
    DN.Rest(N)
  end
  return face == "notch"
end

-------------------------------------------------------------
-- The notch's own scripts
-------------------------------------------------------------

-- A click is the pinned copy's: the read mail unfolded, and the list taken
-- to it (CollectTab, CT.Build).
function DN.Click(N)
  local pin = N.panel and N.panel.DividerPin
  local click = pin and pin:GetScript("OnClick")
  if click then click(pin, "LeftButton") end
end

-- Lit under the pointer. Where it shows the number alone (Count, or Count
-- only and Count and check), the words it stands for in a tooltip: the
-- words chosen, or the whole words where the choice is the number.
function DN.Enter(N)
  Th().FillChrome(N.Tab.Wash, DN.WASH_HOVER)
  local P = Parts()
  local words = P.Words()
  local numberOnly = P.NUMBER_ONLY[words]
  if N.look ~= "count" and not numberOnly then return end
  if numberOnly then words = "full" end
  local T = Th()
  T.TipBegin(N)
  T.TipTitle(P.Text(L(), words, P.Count(N.panel, words)))
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
-- running, the divider whole, and the next show starts at rest. Its own
-- Hide (nothing of it left standing) leaves it shown-flagged off, and
-- changes nothing.
function DN.Hidden(N)
  if N:IsShown() then DN.Reset(N) end
end
