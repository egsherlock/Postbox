local _, ns = ...

-------------------------------------------------------------
-- Postbox :: the bar over the read mail in the Notch look: the island
-- (CollectTab: RV.BuildBar makes it, RV.PaintBar gives it its words and
-- colours; this file its shape, where it stands and how it moves).
--
-- One copy of the bar, in the list with the rows, drawn at the lower of
-- two places: its own place in the list, and its stand at the view's foot.
-- While its place is below the stand it waits there in a room of its own,
-- the bar's slot (24 on one-line rows, 28 on Larger), full width, in the
-- bar's fill, with a short fade over the rows passing under it. As the
-- place comes up the room tightens onto the bar, and the place picks the
-- bar up exactly where it stands: one copy, one rule, nothing handed over.
--
-- Its shape is the island while the place is below the view: a capsule as
-- tall as the bar, as wide as its icon, words and number with RV.BAR.pad
-- each side, centred. Once the place's top is in the view it opens into the
-- bar, edge to edge, on one critically damped spring: both edges move by
-- the same whole units every frame about the list's middle, the round ends
-- turn square, the colours mix into the bar's, and the fold sign and Delete
-- all, standing where the bar has them, are uncovered by the growing edge
-- (the shape clips them) and take the pointer only once it is open. The
-- words never move during a move: they are cut once, for the room they are
-- going to have, as it starts. Scrolling back, it closes into the island
-- where it stands, a little quicker.
--
-- A jump (a wheel step, a click on the island) can carry the place across
-- the stand in one pass. Then, while the shape is still mostly island, it
-- keeps its place on screen for that frame and flies to the new one on a
-- spring of its own as it opens. Once mostly bar it moves with the list,
-- as any row does.
--
-- State, on the panel, numbers only: how open (_barE, its speed _barEV,
-- where it is going _barTo), how far the shape is off its place in a
-- flight (_barYO, _barYV), and the last pass's stand (_barYT, _barFoot,
-- _barK). A move is one OnUpdate on a frame of the panel's own, set when
-- it starts and taken off when it lands; the window hidden mid-move lands
-- it at once. At rest nothing runs, and a pass compares a few numbers and
-- makes nothing.
-------------------------------------------------------------

ns.DividerNotch = ns.DividerNotch or {}
local DN = ns.DividerNotch

local max, min, floor, exp, abs = math.max, math.min, math.floor, math.exp, math.abs

-- The springs (rad/s): opening, closing, and the flight to the place.
-- Opening is at 50% in 70 ms, 90% in 160 ms; closing a little quicker.
DN.OPEN, DN.CLOSE, DN.FLY = 24, 28, 22
-- The longest frame a move counts: a hitch slows it, never skips it.
DN.STEP = 0.05
-- Landed: under a fifth of a percent of the way and almost still (well
-- under a unit of the widest move); a flight under a third of a unit.
DN.LAND, DN.LAND_V, DN.LAND_Y, DN.LAND_YV = 0.002, 0.05, 0.33, 2
-- Where along the opening each change happens: the colours mix from the
-- island's into the bar's, the round ends turn square, and the fold sign
-- and Delete all come up.
DN.MIX = { 0.15, 0.85 }
DN.ENDS = { 0.55, 0.95 }
DN.UP = { 0.72, 1 }
-- The inks, as shares of the chrome ink mixed into the bar's fill (white on
-- a dark palette, black on a light one): the island's fill and ring, at rest
-- and pointed at; the bar's hairlines (RV.BAR.edgeA) and its wash pointed at.
DN.INK = { fill = 0.08, fillHot = 0.13, ring = 0.26, ringHot = 0.40, wash = 0.035 }
-- The fade over the rows above the room reaches its whole in this many
-- units of approach.
DN.FADE_K = 4

local function Parts() return ns.CollectTab and ns.CollectTab.BarParts end
local function Th() return ns.Theme end

-- Smoothstep from a to b.
local function Smooth(r, x)
  local t = (x - r[1]) / (r[2] - r[1])
  if t <= 0 then return 0 elseif t >= 1 then return 1 end
  return t * t * (3 - 2 * t)
end
DN.Smooth = Smooth

-- One step of a critically damped spring, by its exact solution, so a
-- frame of any length lands on the curve: from x moving at v, toward `to`,
-- `w` rad/s, `dt` seconds. It never overshoots from rest, and turned round
-- mid-way it keeps its speed.
local function Spring(x, v, to, w, dt)
  local d = x - to
  local k = exp(-w * dt)
  local wd = v + w * d
  return to + (d + wd * dt) * k, (v - w * wd * dt) * k
end
DN.Spring = Spring

-------------------------------------------------------------
-- The island's parts (RV.BuildBar, for the copy that is the Notch look)
-------------------------------------------------------------

-- Made once, on a copy built for the foot: the shape (a frame that clips
-- what it holds, so the fold sign and Delete all show only inside it),
-- the frame inside it that holds the words, the fold sign and Delete all
-- at the bar's own places, and the textures of the capsule: its middle
-- (fill, top and bottom hairlines), four round quarters (ring, and the
-- fill a unit inside it) and two square ends (fill and hairlines). Every
-- texture takes its colour in the call that makes it.
function DN.Build(f)
  local shape = CreateFrame("Frame", nil, f)
  shape:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  shape:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
  if shape.SetClipsChildren then shape:SetClipsChildren(true) end
  shape:EnableMouse(false)
  f.Shape = shape
  local inner = CreateFrame("Frame", nil, shape)
  inner:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  inner:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
  inner:EnableMouse(false)
  f.Inner = inner
  return inner
end

-- The capsule's textures, on the copy itself under everything the shape
-- holds. After RV.BuildBar has made the rest, so no other part's place in
-- the copy moves.
function DN.Skin(f)
  local T = Th()
  local WHITE = "Interface\\Buttons\\WHITE8X8"
  local g = T.GLYPHS and T.GLYPHS.cap
  local function Plain(layer, sub)
    local t = f:CreateTexture(nil, layer, nil, sub)
    t:SetTexture(WHITE)
    t:SetVertexColor(0, 0, 0, 0)
    return t
  end
  local function Quarter(sub, flipX, flipY)
    local t = f:CreateTexture(nil, "BACKGROUND", nil, sub)
    if g then
      t:SetTexture(g.file)
      local l, r, top, b = g.l, g.r, g.t, g.b
      if flipX then l, r = r, l end
      if flipY then top, b = b, top end
      t:SetTexCoord(l, r, top, b)
      -- Blended, not sharpened, as Theme.Glyph has its art: the curve is
      -- drawn smaller than its art on one-line rows.
      if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(true) end
      if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
    else
      t:SetTexture(WHITE)
    end
    t:SetVertexColor(0, 0, 0, 0)
    return t
  end
  local P = {}
  -- The middle.
  P.mid, P.midT, P.midB = Plain("BACKGROUND", -6), Plain("BORDER", 0), Plain("BORDER", 0)
  -- The round ends: top-left, bottom-left, top-right, bottom-right; the ring
  -- under, the fill over it.
  P.ring = { Quarter(-7, false, false), Quarter(-7, false, true), Quarter(-7, true, false), Quarter(-7, true, true) }
  P.fill = { Quarter(-6, false, false), Quarter(-6, false, true), Quarter(-6, true, false), Quarter(-6, true, true) }
  -- The square ends: left and right, a fill and its two hairlines each.
  P.sq = { Plain("BACKGROUND", -6), Plain("BACKGROUND", -6) }
  P.sqT = { Plain("BORDER", 0), Plain("BORDER", 0) }
  P.sqB = { Plain("BORDER", 0), Plain("BORDER", 0) }
  -- The inks the pieces are mixed from (DN.Ink), and the colours drawn.
  P.ink = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  f.Isle = P
  -- Over the rows above the room, the fade stands on the room's top.
  local fade = f.Fade
  if fade then
    fade.holder:ClearAllPoints()
    fade.holder:SetPoint("BOTTOMLEFT", f.Fill, "TOPLEFT", 0, 0)
    fade.holder:SetPoint("BOTTOMRIGHT", f.Fill, "TOPRIGHT", 0, 0)
  end
  local edges = f.Edges
  for i = 1, #edges do edges[i]:Hide() end
  f:SetScript("OnEnter", DN.Enter)
  f:SetScript("OnLeave", DN.Leave)
end

-- The capsule laid out for a bar `band` tall: the round ends a radius
-- wide, the fill a unit in from the ring. Only when the height moves.
function DN.Size(f, band)
  if f.__isleBand == band then return end
  f.__isleBand = band
  local P, shape = f.Isle, f.Shape
  local r = band / 2
  local q = r - 1
  local mid, midT, midB = P.mid, P.midT, P.midB
  mid:ClearAllPoints()
  mid:SetPoint("TOPLEFT", shape, "TOPLEFT", r, 0)
  mid:SetPoint("BOTTOMRIGHT", shape, "BOTTOMRIGHT", -r, 0)
  midT:ClearAllPoints()
  midT:SetPoint("TOPLEFT", shape, "TOPLEFT", r, 0)
  midT:SetPoint("TOPRIGHT", shape, "TOPRIGHT", -r, 0)
  midT:SetHeight(1)
  midB:ClearAllPoints()
  midB:SetPoint("BOTTOMLEFT", shape, "BOTTOMLEFT", r, 0)
  midB:SetPoint("BOTTOMRIGHT", shape, "BOTTOMRIGHT", -r, 0)
  midB:SetHeight(1)
  local Q = DN.QUARTER
  for i = 1, 4 do
    local ring, fill, corner = P.ring[i], P.fill[i], Q[i]
    ring:ClearAllPoints()
    ring:SetPoint(corner, shape, corner, 0, 0)
    ring:SetSize(r, r)
    fill:ClearAllPoints()
    fill:SetPoint(corner, shape, corner, Q.dx[i], Q.dy[i])
    fill:SetSize(q, q)
  end
  for i = 1, 2 do
    local top, bottom = Q[i * 2 - 1], Q[i * 2]
    local sq, sqT, sqB = P.sq[i], P.sqT[i], P.sqB[i]
    sq:ClearAllPoints()
    sq:SetPoint(top, shape, top, 0, 0)
    sq:SetPoint(bottom, shape, bottom, 0, 0)
    sq:SetWidth(r)
    sqT:ClearAllPoints()
    sqT:SetPoint(top, shape, top, 0, 0)
    sqT:SetSize(r, 1)
    sqB:ClearAllPoints()
    sqB:SetPoint(bottom, shape, bottom, 0, 0)
    sqB:SetSize(r, 1)
  end
  f.__kc = nil
end
-- The four quarters' corners, in DN.Skin's order (the left end's top and
-- bottom, the right end's), and where each one's fill stands in from it.
DN.QUARTER = { "TOPLEFT", "BOTTOMLEFT", "TOPRIGHT", "BOTTOMRIGHT", dx = { 1, 1, -1, -1 }, dy = { -1, 1, -1, 1 } }

-- The inks of the island and of the bar, from the bar's fill (r, g, b):
-- the chrome ink mixed in at DN.INK's shares, its strength as the palette
-- gives it, kept in the copy's list at DN.INKS (1 the island's fill, 4
-- pointed at; 7 its ring, 10 pointed at; 13 the bar's fill pointed at --
-- its own is the fill itself; 16 the bar's hairlines). Only when the fill
-- or the palette moves; then the pieces are coloured again, and the room.
DN.INKS = { 1, 4, 7, 10, 13, 16 }
function DN.Ink(f, r, g, b)
  local c = Th().Colors.chromeInk
  local ir, ig, ib, k = c[1], c[2], c[3], c[4] or 1
  local I, ink, at = DN.INK, f.Isle.ink, DN.INKS
  local B = ns.CollectTab and ns.CollectTab.BarParts
  for n = 1, 6 do
    local s
    if n == 1 then s = I.fill elseif n == 2 then s = I.fillHot elseif n == 3 then s = I.ring
    elseif n == 4 then s = I.ringHot elseif n == 5 then s = I.wash else s = B and B.edgeA or 0.14 end
    s = min(1, s * k)
    local i = at[n]
    ink[i], ink[i + 1], ink[i + 2] = r + (ir - r) * s, g + (ig - g) * s, b + (ib - b) * s
  end
  f.__isleR, f.__isleG, f.__isleB = r, g, b
  f.__kf = nil
  -- The room is solid: the rows passing under it never show through.
  f.Fill:SetColorTexture(r, g, b, 1)
end

-- The pieces coloured for `kf` (0 the island, 1 the bar) and the pointer.
local function Colour(f, kf, hot)
  local P = f.Isle
  local ink = P.ink
  local B = ns.CollectTab and ns.CollectTab.BarParts
  local a = B and B.groundA or 0.95
  local fi = hot and 4 or 1
  local ri = hot and 10 or 7
  local br, bg, bb = f.__isleR or 0, f.__isleG or 0, f.__isleB or 0
  if hot then br, bg, bb = ink[13], ink[14], ink[15] end
  local u = 1 - kf
  local fr, fg, fb = ink[fi] * u + br * kf, ink[fi + 1] * u + bg * kf, ink[fi + 2] * u + bb * kf
  local rr, rg, rb = ink[ri] * u + ink[16] * kf, ink[ri + 1] * u + ink[17] * kf, ink[ri + 2] * u + ink[18] * kf
  P.mid:SetVertexColor(fr, fg, fb, a)
  P.midT:SetVertexColor(rr, rg, rb, a)
  P.midB:SetVertexColor(rr, rg, rb, a)
  for i = 1, 4 do
    P.fill[i]:SetVertexColor(fr, fg, fb, a)
    P.ring[i]:SetVertexColor(rr, rg, rb, a)
  end
  for i = 1, 2 do
    P.sq[i]:SetVertexColor(fr, fg, fb, a)
    P.sqT[i]:SetVertexColor(rr, rg, rb, a)
    P.sqB[i]:SetVertexColor(rr, rg, rb, a)
  end
end

-- The words, icon and number in their ink: brighter under the pointer.
local function WordsInk(f, hot)
  local T = Th()
  local tone = hot and "textPrimary" or "textSecondary"
  T.SetColor(f.Label, tone)
  T.SetColor(f.Mark, tone)
end

-------------------------------------------------------------
-- The words (RV.PaintBar calls these for the island's copy)
-------------------------------------------------------------

-- The island's own type, after RV.BarType: Delete all in the words' size
-- and ink, on their middle, its click its words and the house's padding,
-- its words' right end at the row's inset like Hairline's.
function DN.Type(f)
  local T = Th()
  local M = T.Metrics
  local delete = f.Delete
  delete:ClearAllPoints()
  delete:SetPoint("RIGHT", f.Inner, "RIGHT", -(M.inset - M.tightGap), 0)
  delete.Text:ClearAllPoints()
  delete.Text:SetPoint("CENTER", delete, "CENTER", 0, 0)
  f.__deleteInk = "textSecondary"
  T.SetColor(delete.Text, delete.__hot and "negative" or "textSecondary")
  WordsInk(f, f.__hot)
  f.__fitW = nil
end

-- What the words have room for, in a copy `W` wide (RV.BarFit's rule): the
-- icon and the number always whole, the words cut short past the room. In
-- the island, half the list less its padding; in the bar, the list less
-- the wider of its two ends (the fold sign, Delete all) and the padding,
-- each side, centred. Then the island's side inset at rest (`__s0`, whole
-- units, so its width has the list's parity and both its edges stand on
-- whole units), Delete all's click, and the words placed. Numbers only;
-- run when the words, the list's width or the fold sign's place move.
function DN.Fit(f, W)
  local B = Parts()
  local pad, gap, checkGap = B.pad, B.gap, B.checkGap
  local T = Th()
  local M = T.Metrics
  local delete = f.Delete
  local deleteW = math.ceil(tonumber((delete.Text:GetStringWidth())) or 0) + 2 * M.tightGap
  delete:SetSize(deleteW, f.__isleBand or f:GetHeight() or 22)
  local wordsW, iconW, countW = f.__wordsW or 0, f.__iconW or 0, f.__countW or 0
  local lead = (iconW > 0) and (iconW + ((wordsW > 0 or countW > 0) and checkGap or 0)) or 0
  local tail = (countW > 0) and (((wordsW > 0) and gap or 0) + countW) or 0
  local tabW, barW = false, false
  if W > 0 and wordsW > 0 then
    local tabRoom = floor(W / 2 - 2 * pad - lead - tail)
    local left = (f.__signX or 0) + (f.__canvas or 12) / 2
    local right = (M.inset - M.tightGap) + deleteW
    local barRoom = floor(W - 2 * (max(left, right) + pad) - lead - tail)
    if wordsW > tabRoom then tabW = max(1, tabRoom) end
    if wordsW > barRoom then barW = max(1, barRoom) end
  end
  f.__lead, f.__tail, f.__tabW, f.__barW = lead, tail, tabW, barW
  local chip = math.ceil(lead + (tabW or wordsW) + tail) + 2 * pad
  f.__chipW = chip
  f.__s0 = max(0, floor((W - chip) / 2))
  f.__W2 = W
  f.__s = nil
  DN.Place(f, f.__wide or false, true)
end

-- The icon, the words and the number centred on the list as one, at the
-- island's cut or the bar's (`wide`), on whole units from the copy's left,
-- on its middle (the client centres a line on its box, which puts the
-- capitals on the middle within half a unit). Only where the cut moves,
-- or `again`.
function DN.Place(f, wide, again)
  local cut = (wide and f.__barW or f.__tabW) or false
  if not again and f.__pw == wide and f.__placed == cut then return end
  f.__pw = wide
  local B = Parts()
  local label, count, mark, inner = f.Label, f.Count, f.Mark, f.Inner
  if cut then
    label:SetWidth(cut)
  elseif f.__placed then
    label:SetWidth(0)
  end
  f.__placed = cut
  local wordsW, iconW = f.__wordsW or 0, f.__iconW or 0
  local width = math.ceil((f.__lead or 0) + (cut or wordsW) + (f.__tail or 0))
  local x = floor(((f.__W2 or 0) - width) / 2)
  if iconW > 0 then
    mark:ClearAllPoints()
    mark:SetPoint("LEFT", inner, "LEFT", x, f.__iconUp or 0)
    x = x + iconW + B.checkGap
  end
  if wordsW > 0 then
    label:ClearAllPoints()
    label:SetPoint("LEFT", inner, "LEFT", x, 0)
    count:ClearAllPoints()
    count:SetPoint("LEFT", label, "RIGHT", B.gap, 0)
  else
    count:ClearAllPoints()
    count:SetPoint("LEFT", inner, "LEFT", x, 0)
  end
end

-------------------------------------------------------------
-- Drawing: the shape at `e`, the room at `k`
-------------------------------------------------------------

-- The shape `e` open (0 the island, 1 the bar), `yo` whole units off its
-- place in a flight: both edges `s` in from the list's, s whole; the colours,
-- the ends, the fold sign's and Delete all's alpha and Delete all's pointer,
-- each set only where it moved. Every frame of a move comes here, and
-- makes nothing.
function DN.Shape(f, e, yo)
  if e < 0 then e = 0 elseif e > 1 then e = 1 end
  yo = yo or 0
  local s = floor((f.__s0 or 0) * (1 - e) + 0.5)
  if f.__s ~= s or f.__yo ~= yo then
    local shape = f.Shape
    shape:SetPoint("TOPLEFT", f, "TOPLEFT", s, -yo)
    shape:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -s, -yo)
    if f.__yo ~= yo then
      local inner = f.Inner
      inner:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -yo)
      inner:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, -yo)
    end
    f.__s, f.__yo = s, yo
  end
  local hot = f.__hot and true or false
  local kf = Smooth(DN.MIX, e)
  if f.__kf ~= kf or f.__kh ~= hot then
    f.__kf, f.__kh = kf, hot
    Colour(f, kf, hot)
  end
  local kc = Smooth(DN.ENDS, e)
  if f.__kc ~= kc then
    f.__kc = kc
    local P = f.Isle
    local round = 1 - kc
    for i = 1, 4 do
      P.ring[i]:SetAlpha(round)
      P.fill[i]:SetAlpha(round)
    end
    for i = 1, 2 do
      P.sq[i]:SetAlpha(kc)
      P.sqT[i]:SetAlpha(kc)
      P.sqB[i]:SetAlpha(kc)
    end
  end
  local ka = Smooth(DN.UP, e)
  if f.__late ~= ka then
    f.__late = ka
    f.Sign:SetAlpha(ka)
    f.Delete:SetAlpha(ka)
  end
  local live = e >= 1
  if f.__live ~= live then
    f.__live = live
    f.Delete:EnableMouse(live)
  end
  f.__e = e
end

-- The room at the foot: `k` units of the place below the stand (0 once the
-- place carries the bar), `m` the room's margin over and under the bar at
-- most. The room tightens onto the bar over the last units of approach, on
-- whole units, and its fade comes in over DN.FADE_K; the whole room takes
-- the pointer. Only where it moved.
function DN.Room(f, k, m)
  local on = k > 0
  local pad = on and min(m, floor(k)) or 0
  local fill = f.Fill
  if f.__roomOn ~= on then
    f.__roomOn = on
    fill:SetShown(on)
    if f.Fade then f.Fade.holder:SetShown(on) end
  end
  if f.__roomPad ~= pad then
    f.__roomPad = pad
    fill:ClearAllPoints()
    fill:SetPoint("TOPLEFT", f, "TOPLEFT", 0, pad)
    fill:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, -pad)
    f:SetHitRectInsets(0, 0, -pad, -pad)
  end
  local a = on and min(1, k / DN.FADE_K) or 0
  if f.Fade and f.__fadeE ~= a then
    f.__fadeE = a
    f.Fade.holder:SetAlpha(a)
  end
end

-- The copy at `level`, and what it holds over it in order: the fade and
-- the shape, the words in the shape, Delete all over the words.
function DN.Levels(f, level)
  f:SetFrameLevel(level)
  f.Shape:SetFrameLevel(level + 1)
  if f.Fade then f.Fade.holder:SetFrameLevel(level + 1) end
  f.Inner:SetFrameLevel(level + 2)
  f.Delete:SetFrameLevel(level + 3)
end

-- Everything the drawing remembers forgotten, so the next pass sets each
-- part again (RV.NotchParts, a copy put back into the Notch look).
function DN.Reset(f)
  f.__s, f.__yo, f.__kf, f.__kh, f.__kc, f.__late, f.__live, f.__e = nil, nil, nil, nil, nil, nil, nil, nil
  f.__roomOn, f.__roomPad, f.__fadeE, f.__pw, f.__isleR = nil, nil, nil, nil, nil
  local edges = f.Edges
  for i = 1, #edges do edges[i]:Hide() end
end

-- The island's copy drawn `e` open where it stands, for a copy with no
-- list driving it (the options' drawing): the words at the cut of the
-- shape it is nearer, the room around it while `k` is given.
function DN.Apply(f, e, k)
  DN.Size(f, f:GetHeight() or 22)
  DN.Place(f, e >= 0.5)
  DN.Shape(f, e, 0)
  DN.Room(f, k or 0, 1)
end

-- The pointer over the island, its room or the bar: the island's fill and
-- ring a step lighter (the bar's fill washed a little), the words bright;
-- and the bar's tooltip (RV.WordsTip).
function DN.Enter(self)
  self.__hot = true
  WordsInk(self, true)
  if self.__e then DN.Shape(self, self.__e, self.__yo) end
  local B = Parts()
  if B and B.Tip then B.Tip(self) end
end

function DN.Leave(self)
  self.__hot = nil
  WordsInk(self, false)
  if self.__e then DN.Shape(self, self.__e, self.__yo) end
  local B = Parts()
  if B and B.TipOff then B.TipOff(self) end
end

-------------------------------------------------------------
-- The move
-------------------------------------------------------------

-- The copy drawn as the state stands.
function DN.Draw(panel)
  local f = panel.Notch
  if not (f and f.__on) then return end
  local yo = panel._barYO or 0
  DN.Shape(f, panel._barE or 0, floor(yo + 0.5))
end

-- One frame of a move: each spring a step nearer, drawn; off once both
-- have landed.
function DN.Tick(driver, elapsed)
  local panel = driver.panel
  local to = panel._barTo
  if to == nil then
    DN.Stop(panel)
    return
  end
  local dt = min(elapsed or 0, DN.STEP)
  local moving = false
  local e, v = panel._barE or to, panel._barEV or 0
  if e ~= to or v ~= 0 then
    e, v = Spring(e, v, to, (to == 1) and DN.OPEN or DN.CLOSE, dt)
    if abs(e - to) < DN.LAND and abs(v) < DN.LAND_V then
      e, v = to, 0
    else
      moving = true
    end
    panel._barE, panel._barEV = e, v
  end
  local yo, yv = panel._barYO or 0, panel._barYV or 0
  if yo ~= 0 or yv ~= 0 then
    yo, yv = Spring(yo, yv, 0, DN.FLY, dt)
    if abs(yo) < DN.LAND_Y and abs(yv) < DN.LAND_YV then
      yo, yv = 0, 0
    else
      moving = true
    end
    panel._barYO, panel._barYV = yo, yv
  end
  DN.Draw(panel)
  if not moving then DN.Stop(panel) end
end

-- Hidden with the panel (another tab, the window closing) while a move
-- runs: landed where it was going, nothing left running.
function DN.Hidden(driver)
  local panel = driver.panel
  if panel._barTo ~= nil then panel._barE, panel._barEV = panel._barTo, 0 end
  panel._barYO, panel._barYV = 0, 0
  DN.Stop(panel)
  DN.Draw(panel)
end

local function Driver(panel)
  local driver = panel.BarDriver
  if driver then return driver end
  driver = CreateFrame("Frame", nil, panel)
  driver:SetSize(1, 1)
  driver:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
  driver.panel = panel
  driver.moving = false
  driver:SetScript("OnHide", DN.Hidden)
  panel.BarDriver = driver
  return driver
end

function DN.Start(panel)
  local driver = Driver(panel)
  if driver.moving then return end
  driver.moving = true
  driver:SetScript("OnUpdate", DN.Tick)
end

function DN.Stop(panel)
  local driver = panel.BarDriver
  if not (driver and driver.moving) then return end
  driver.moving = false
  driver:SetScript("OnUpdate", nil)
end

-------------------------------------------------------------
-- The pass (CollectTab, the virtualiser)
-------------------------------------------------------------

-- A copy shown or hidden, by its own flag, so a pass at rest asks the
-- client nothing.
local function Shown(f, on)
  if f.__on == on then return end
  f.__on = on
  f:SetShown(on)
end

-- No bar in the list (no read mail, read mail in the Done tab or deleted,
-- History, another character's box, another look): the copy put away and
-- the state forgotten, so the bar's next coming is drawn as it then stands.
function DN.Off(panel)
  local N = panel.Notch
  if N then Shown(N, false) end
  if panel._barE ~= nil or panel._barTo ~= nil then
    DN.Stop(panel)
    panel._barE, panel._barEV, panel._barTo = nil, nil, nil
    panel._barYO, panel._barYV, panel._barYT, panel._barFoot, panel._barK = nil, nil, nil, nil, nil
  end
end

-- One pass of the list. `at`: the bar's place in the list (nil for none);
-- `band`: the bar's height. The bar stands at the lower of its place and
-- its stand, the room's margin over the view's foot; while the place is
-- below the stand, in the room. It opens while its place's top is in the
-- view, and closes once it is not.
function DN.Update(panel, at, offset, viewport, stride, band, compact)
  local N = panel.Notch
  if not (at and N) or viewport <= 0 then
    DN.Off(panel)
    return
  end
  local P = Parts()
  local m = (P.BarSlot(compact) - band) / 2
  local place = (at - 1) * stride - offset
  local stand = viewport - band - m
  local y = place
  if y > stand then y = stand end
  local k = place - y
  local foot = k > 0
  local to = (place < viewport) and 1 or 0
  local e = panel._barE
  if e == nil then
    -- First seen: as it stands, with no move.
    panel._barE, panel._barEV, panel._barYO, panel._barYV = to, 0, 0, 0
  elseif panel._barYT and foot ~= panel._barFoot and abs(y - panel._barYT) > band and e < 0.5 then
    -- Carried across the stand in one pass while still mostly island: it
    -- stays where it was on screen and flies to its new place.
    panel._barYO, panel._barYV = (panel._barYO or 0) + (panel._barYT - y), 0
  end
  panel._barYT, panel._barFoot, panel._barK, panel._barTo = y, foot, k, to
  -- In the list with the rows, a few levels over them (under the fan's
  -- plate, CollectTab + 10), at y in the view.
  local child = panel.MailListChild
  local cy = -(offset + y)
  if N.__y ~= cy or N.__h ~= band then
    N.__y, N.__h = cy, band
    N:ClearAllPoints()
    N:SetPoint("TOPLEFT", child, "TOPLEFT", 0, cy)
    N:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, cy)
    N:SetHeight(band)
  end
  local level = child:GetFrameLevel() + 8
  if N.__level ~= level then
    N.__level = level
    DN.Levels(N, level)
  end
  Shown(N, true)
  DN.Size(N, band)
  -- The words cut for the shape it is going to (before the move starts).
  local wide = to == 1
  N.__wide = wide
  P.Paint(panel, N, compact)
  DN.Place(N, wide)
  DN.Room(N, k, m)
  DN.Draw(panel)
  if panel._barE ~= to or panel._barEV ~= 0 or panel._barYO ~= 0 then DN.Start(panel) else DN.Stop(panel) end
end

-- For `/postbox debug divider`: how the bar stands.
function DN.State(panel)
  if not (panel and panel._barTo ~= nil) then return "none" end
  local e, to = panel._barE or 0, panel._barTo
  local where = (panel._barK or 0) > 0 and "at the foot" or "in its place"
  local shape = (to == 1) and "open" or "island"
  local s = shape .. " " .. where
  if e ~= to then s = s .. string.format(" (moving, %d%%)", floor(e * 100 + 0.5)) end
  if (panel._barYO or 0) ~= 0 then s = s .. string.format(", flying %d", floor(panel._barYO + 0.5)) end
  return s
end
