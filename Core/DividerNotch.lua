local _, ns = ...

-------------------------------------------------------------
-- Postbox :: the bar over the read mail in the Island look (saved as
-- "notch"): the island (CollectTab: RV.BuildBar makes it, RV.PaintBar gives
-- it its words and colours; this file its shape, its shadow, where it
-- stands and how it moves).
--
-- One copy of the bar, in the list with the rows, drawn at the lower of
-- two places: its own place in the list, and its stand at the view's foot.
-- While its place is below the stand it waits there in a room of its own,
-- the bar's slot (24 on one-line rows, 28 on Larger), full width, over its
-- shadow: one see-through gradient over the rows at the list's foot, in
-- Shadow color, strongest at the foot and gone a little above the room, so
-- the mail behind it reads faded and the island stands out. As the place
-- comes up the room tightens onto the bar and the shadow fades away, and
-- the place picks the bar up exactly where it stands: one copy, one rule,
-- nothing handed over.
--
-- Its shape is the island while the place is below the view: a capsule as
-- tall as the bar, as wide as its icon, words and number with RV.BAR.pad
-- each side, centred. Once the place's top is in the view it opens into the
-- bar, edge to edge, on one critically damped spring: both edges move by
-- the same whole units every frame about the list's middle, the ends stay
-- round until they come within the capsule's radius of the list's edges
-- and then square off as they meet them (the corners' radius the edges'
-- whole-unit gap, at most the capsule's), the colours mix into the bar's,
-- and the fold sign and Delete all, standing
-- where the bar has them, come up once the edge has passed them whole,
-- settling as the shape lands; they take the pointer only once it is open.
-- The words never move during a move: they are cut once, for the room they
-- are going to have, as it starts. Scrolling back, it closes into the
-- island where it stands, a little quicker, the fold sign and Delete all
-- gone before the edge reaches them.
--
-- A wheel step can carry the place across the stand in one pass. Then,
-- while the shape is still mostly island, it keeps its place on screen for
-- that frame and flies to the new one on a spring of its own as it opens.
-- A click on the island glides the list itself to the bar's place instead,
-- a pass of the list each frame as a drag of the scroll bar is, and the
-- one rule carries the island up as its place comes into view; the
-- player's own scroll stops a glide where it stands.
--
-- State, on the panel, numbers only: how open (_barE, its speed _barEV,
-- where it is going _barTo), how far the shape is off its place in a
-- flight (_barYO, _barYV), the last pass's stand (_barYT, _barFoot, _barK)
-- and a glide (_glideY, _glideV, _glideTo, _glideSet); on the copy, the
-- pointer's eases and the fold sign's turn. A move is one OnUpdate on a
-- frame of the panel's own, set when something starts to move and taken
-- off when everything has landed; the window hidden mid-move lands it all
-- at once. At rest nothing
-- runs, and a pass compares a few numbers and makes nothing.
-------------------------------------------------------------

ns.DividerNotch = ns.DividerNotch or {}
local DN = ns.DividerNotch

local max, min, floor, ceil, exp, abs = math.max, math.min, math.floor, math.ceil, math.exp, math.abs

-- The springs (rad/s): opening, closing, the flight to the place, the
-- list's glide to the bar (a click on the island: visually there in about
-- 300 ms, as the bar opens on its way), and the fold sign's quarter turn
-- (about 150 ms). Opening is at 50% in 70 ms, 90% in 160 ms; closing a
-- little quicker. All critically damped: nothing overshoots or bounces.
DN.OPEN, DN.CLOSE, DN.FLY, DN.GLIDE, DN.TURN = 24, 28, 22, 24, 32
-- The longest frame a move counts: a hitch slows it, never skips it.
DN.STEP = 0.05
-- Landed: under a fifth of a percent of the way and almost still (well
-- under a unit of the widest move); a flight under a third of a unit; a
-- glide within half a unit and under half a unit a frame.
DN.LAND, DN.LAND_V, DN.LAND_Y, DN.LAND_YV, DN.LAND_G = 0.002, 0.05, 0.33, 2, 30
-- Where along the opening the colours mix from the island's into the
-- bar's. (The corners follow the edges instead: DN.Shape.)
DN.MIX = { 0.15, 0.85 }
-- The inks, as shares of the chrome ink mixed into the bar's fill (white on
-- a dark palette, black on a light one): the island's fill and ring, at
-- rest, pointed at and pressed; the bar's wash pointed at and pressed (a
-- press a step back from the pointer's, toward the ground).
DN.INK = { fill = 0.08, fillHot = 0.13, fillDown = 0.04, ring = 0.26, ringHot = 0.40, ringDown = 0.30,
  wash = 0.035, washDown = -0.025 }
-- The pointer's eases: an exponential approach this many seconds long per
-- e-fold (95% in about 120 ms).
DN.EASE = 0.04
-- The shadow fades away over this many units of the place's last approach
-- (and is whole beyond them).
DN.FADE_K = 4
-- The shadow: its strength at the list's foot (falling evenly to none at
-- its top), how far its top stands over the room, and how much of a
-- colour chosen for it (Shadow color) is mixed into the list's ground --
-- Neutral is the ground itself. Measured on renders: the rows' words in
-- the room keep about half their contrast with their row.
DN.SHADE = { a = 0.7, up = 16, mix = 0.6 }

local function Parts() return ns.CollectTab and ns.CollectTab.BarParts end
local function Th() return ns.Theme end

-- Smoothstep over the range r = { from, to } of e.
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

-- One step of an exponential approach, `k` of the way: landed within a
-- hundredth. Answers the value and whether it still moves.
local function Ease(x, to, k)
  x = x + (to - x) * k
  if abs(to - x) < 0.01 then return to, false end
  return x, true
end

local function Clamp(v)
  if v < 0 then return 0 elseif v > 1 then return 1 end
  return v
end

-- A texture shown or hidden by its own flag, so a redraw asks the client
-- only where it changed.
local function On(t, on)
  if t.__dnOn == on then return end
  t.__dnOn = on
  t:SetShown(on)
end

-------------------------------------------------------------
-- The island's parts (RV.BuildBar, for the copy that is the Notch look)
-------------------------------------------------------------

-- Made once, on a copy built for the foot: the shape (a frame that clips
-- what it holds, so the fold sign and Delete all show only inside it),
-- the frame inside it that holds the words, the fold sign and Delete all
-- at the bar's own places.
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

-- The shape's textures, on the copy itself under everything the shape
-- holds: a rounded rectangle at any radius, every point of it one piece --
-- the middle's fill, the fill beside the corners, four corners (a quarter
-- of a disc in the ring's ink, a quarter a unit smaller in the fill's over
-- it), the top and bottom hairlines between the corners and the straight
-- sides between them. Drawn solid, in the inks the fill would show over the
-- room, so a corner's fill over its ring shows the fill alone: the corners
-- are the middle's shade. Then the shadow, on the room's own texture (one
-- gradient; where the client draws no gradient, the room and a strip over
-- it in two solid steps), and the pointer. After RV.BuildBar has made the
-- rest, so no other part's place in the copy moves. Every texture takes
-- its colour in the call that makes it.
function DN.Skin(f)
  local T = Th()
  local WHITE = "Interface\\Buttons\\WHITE8X8"
  local g = T.GLYPHS and T.GLYPHS.cap
  local shape = f.Shape
  local function Plain(layer, sub)
    local t = f:CreateTexture(nil, layer, nil, sub)
    t:SetTexture(WHITE)
    t:SetVertexColor(0, 0, 0, 0)
    return t
  end
  local Q = DN.QUARTER
  local function Quarter(sub, i, inset)
    local t = f:CreateTexture(nil, "BACKGROUND", nil, sub)
    if g then
      t:SetTexture(g.file)
      local l, r, top, b = g.l, g.r, g.t, g.b
      if i > 2 then l, r = r, l end
      if i % 2 == 0 then top, b = b, top end
      t:SetTexCoord(l, r, top, b)
      -- Blended, not sharpened, as Theme.Glyph has its art: the curve is
      -- drawn smaller than its art at every radius but the largest.
      if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(true) end
      if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
    else
      t:SetTexture(WHITE)
    end
    t:SetVertexColor(0, 0, 0, 0)
    local corner = Q[i]
    t:SetPoint(corner, shape, corner, inset and Q.dx[i] or 0, inset and Q.dy[i] or 0)
    return t
  end
  local P = {}
  -- The fill: the middle, and the strips beside the corners.
  P.mid = Plain("BACKGROUND", -6)
  P.side = { Plain("BACKGROUND", -6), Plain("BACKGROUND", -6) }
  -- The corners: top-left, bottom-left, top-right, bottom-right; the ring's
  -- quarter under, the fill's over it.
  P.ring = { Quarter(-7, 1), Quarter(-7, 2), Quarter(-7, 3), Quarter(-7, 4) }
  P.fill = { Quarter(-6, 1, true), Quarter(-6, 2, true), Quarter(-6, 3, true), Quarter(-6, 4, true) }
  -- The ring's straight parts: top and bottom, left and right.
  P.top, P.bot = Plain("BORDER", 0), Plain("BORDER", 0)
  P.top:SetHeight(1)
  P.bot:SetHeight(1)
  P.edgeL, P.edgeR = Plain("BORDER", 0), Plain("BORDER", 0)
  P.edgeL:SetWidth(1)
  P.edgeR:SetWidth(1)
  -- The inks the pieces are mixed from (DN.Ink): the bar's fill, the chrome
  -- ink and its strength, the fill's strength over the rows, the bar's
  -- hairlines' share. Then the words' and Delete all's tones at rest and
  -- pointed at (DN.Type).
  P.br, P.bg, P.bb, P.ir, P.ig, P.ib, P.ik, P.a, P.edge = 0, 0, 0, 1, 1, 1, 1, 0.95, 0.14
  P.tone = { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }
  f.Isle = P
  -- The shadow: the room's texture (f.Fill, under everything the copy
  -- draws), from the room's foot to DN.SHADE.up over its top, in Shadow
  -- color, DN.SHADE.a strong at the foot to none at the top (DN.Shade).
  -- The colour objects are made once and re-set in place. Where the client
  -- draws no gradient: the room at the strength the gradient has at its
  -- middle and a strip over it at the strength over the room's top.
  local shade = { r = false }
  local fill = f.Fill
  fill:SetTexture(WHITE)
  fill:SetVertexColor(0, 0, 0, 0)
  if fill.SetGradient and type(CreateColor) == "function" then
    shade.lo, shade.hi = CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0)
  else
    local up = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    up:SetColorTexture(0, 0, 0, 0)
    up:SetPoint("BOTTOMLEFT", fill, "TOPLEFT", 0, 0)
    up:SetPoint("BOTTOMRIGHT", fill, "TOPRIGHT", 0, 0)
    up:SetHeight(DN.SHADE.up)
    up:Hide()
    shade.up = up
  end
  f.Shade = shade
  local edges = f.Edges
  for i = 1, #edges do edges[i]:Hide() end
  -- The pointer's eases (0 at rest, 1 pointed at, pressed, Delete all's red).
  f.__hv, f.__pv, f.__dv = 0, 0, 0
  f:SetScript("OnEnter", DN.Enter)
  f:SetScript("OnLeave", DN.Leave)
  f:SetScript("OnMouseDown", DN.Down)
  f:SetScript("OnMouseUp", DN.Up)
  -- Delete all's red eases in and out: after its own handlers, which say
  -- its tooltip and set the red outright.
  local delete = f.Delete
  delete.__copy = f
  delete:HookScript("OnEnter", DN.DeleteHot)
  delete:HookScript("OnLeave", DN.DeleteHot)
end

-- The four corners, in DN.Skin's order (the left end's top and bottom, the
-- right end's), and where each one's fill stands in from it.
DN.QUARTER = { "TOPLEFT", "BOTTOMLEFT", "TOPRIGHT", "BOTTOMRIGHT", dx = { 1, 1, -1, -1 }, dy = { -1, 1, -1, 1 } }

-- The shape laid out for a bar `band` tall: its radius drawn again on the
-- next frame. Only when the height moves.
function DN.Size(f, band)
  if f.__isleBand == band then return end
  f.__isleBand = band
  f.__R = nil
  -- The shadow's two steps, where there is no gradient, are measured on
  -- the room.
  if f.Shade and f.Shade.up then f.Shade.r = false end
end

-- The pieces laid out for a radius of `R` units (whole, from the capsule's
-- half height to none): the fill's middle from the radius in (a unit at
-- least, inside the ring's sides), the hairlines between the corners, the
-- straight sides and the fill beside the corners where the corners leave
-- room for them, the corners a radius wide. No piece overlaps another but
-- a corner's fill on its ring.
local function Round(f, R)
  local P, shape = f.Isle, f.Shape
  local h = f.__isleBand or 22
  local a = (R >= 1) and R or 1
  local mid = P.mid
  mid:SetPoint("TOPLEFT", shape, "TOPLEFT", a, -1)
  mid:SetPoint("BOTTOMRIGHT", shape, "BOTTOMRIGHT", -a, 1)
  local top, bot = P.top, P.bot
  top:SetPoint("TOPLEFT", shape, "TOPLEFT", R, 0)
  top:SetPoint("TOPRIGHT", shape, "TOPRIGHT", -R, 0)
  bot:SetPoint("BOTTOMLEFT", shape, "BOTTOMLEFT", R, 0)
  bot:SetPoint("BOTTOMRIGHT", shape, "BOTTOMRIGHT", -R, 0)
  local sides = h - 2 * a > 0
  local l, r = P.edgeL, P.edgeR
  On(l, sides)
  On(r, sides)
  if sides then
    l:SetPoint("TOPLEFT", shape, "TOPLEFT", 0, -a)
    l:SetPoint("BOTTOMLEFT", shape, "BOTTOMLEFT", 0, a)
    r:SetPoint("TOPRIGHT", shape, "TOPRIGHT", 0, -a)
    r:SetPoint("BOTTOMRIGHT", shape, "BOTTOMRIGHT", 0, a)
  end
  local strips = R > 1 and h - 2 * R > 0
  local sl, sr = P.side[1], P.side[2]
  On(sl, strips)
  On(sr, strips)
  if strips then
    sl:SetPoint("TOPLEFT", shape, "TOPLEFT", 1, -R)
    sl:SetPoint("BOTTOMRIGHT", shape, "BOTTOMLEFT", R, R)
    sr:SetPoint("TOPLEFT", shape, "TOPRIGHT", -R, -R)
    sr:SetPoint("BOTTOMRIGHT", shape, "BOTTOMRIGHT", -1, R)
  end
  local ring, fill = R > 0, R > 1
  for i = 1, 4 do
    local ri, fi = P.ring[i], P.fill[i]
    On(ri, ring)
    On(fi, fill)
    if ring then ri:SetSize(R, R) end
    if fill then fi:SetSize(R - 1, R - 1) end
  end
end

-- The inks of the island and of the bar, from the bar's fill (r, g, b, Bar
-- color): the chrome ink and its strength as the palette gives it; the
-- pieces are coloured again on the next frame. Only when the fill or the
-- palette moves. The shadow has its own colour (DN.Shade).
function DN.Ink(f, r, g, b)
  local c = Th().Colors.chromeInk
  local P = f.Isle
  local B = Parts()
  P.br, P.bg, P.bb = r, g, b
  P.ir, P.ig, P.ib, P.ik = c[1], c[2], c[3], c[4] or 1
  P.a = B and B.groundA or 0.95
  P.edge = B and B.edgeA or 0.14
  f.__kf = nil
end

-- The shadow's colour (Shadow color): the list's ground under Neutral, so
-- the rows fade toward it (darker on a dark palette, lighter on a light
-- one); a colour chosen, DN.SHADE.mix of it in the ground, so it reads as
-- that colour. Numbers only; the ground as the caller read it, where it
-- did.
function DN.ShadeRGB(panel, gr, gg, gb)
  local r, g, b = gr, gg, gb
  if not r then r, g, b = Parts().Ground(panel) end
  local UI = ns.MailboxUI
  local cr, cg, cb
  if UI and type(UI.ShadowColorRGB) == "function" then cr, cg, cb = UI.ShadowColorRGB() end
  if type(cr) == "number" then
    local k = DN.SHADE.mix
    r, g, b = r + (cr - r) * k, g + (cg - g) * k, b + (cb - b) * k
  end
  return r, g, b
end

-- The shadow painted in its colour, on every pass that shows the island
-- (RV.PaintBar, with the list's ground it read): set only where the colour
-- moved, so at rest it compares three numbers.
function DN.Shade(panel, f, gr, gg, gb)
  local S = f.Shade
  if not S then return end
  local r, g, b = DN.ShadeRGB(panel, gr, gg, gb)
  if S.r == r and S.g == g and S.b == b then return end
  S.r, S.g, S.b = r, g, b
  local a = DN.SHADE.a
  local fill = f.Fill
  if S.lo then
    S.lo:SetRGBA(r, g, b, a)
    S.hi:SetRGBA(r, g, b, 0)
    fill:SetVertexColor(1, 1, 1, 1)
    fill:SetGradient("VERTICAL", S.lo, S.hi)
  else
    -- The gradient's strength at the room's middle and over its top.
    local up = DN.SHADE.up
    local room = (f.__isleBand or 22) + 2
    fill:SetColorTexture(r, g, b, a * (room / 2 + up) / (room + up))
    S.up:SetColorTexture(r, g, b, a * (up / 2) / (room + up))
  end
end

-- The pieces coloured for `kf` (0 the island, 1 the bar), the pointer's
-- ease `hv` and the press's `pv`, and `ks` of the way the straight sides
-- have gone into the fill. Each ink is the share of the chrome ink the
-- fill would show at its strength over the room, drawn solid.
local function Colour(f, kf, hv, pv, ks)
  local P = f.Isle
  local I = DN.INK
  local k, A = P.ik, P.a
  local u = 1 - kf
  local sf = I.fill + (I.fillHot - I.fill) * hv
  sf = sf + (I.fillDown - sf) * pv
  local sb = I.wash * hv
  sb = sb + (I.washDown - sb) * pv
  local sr = I.ring + (I.ringHot - I.ring) * hv
  sr = sr + (I.ringDown - sr) * pv
  local fs = (min(1, sf * k) * u + min(1, sb * k) * kf) * A
  local rs = (min(1, sr * k) * u + min(1, P.edge * k) * kf) * A
  local es = rs + (fs - rs) * ks
  local br, bg, bb = P.br, P.bg, P.bb
  local dr, dg, db = P.ir - br, P.ig - bg, P.ib - bb
  local fr, fg, fb = Clamp(br + dr * fs), Clamp(bg + dg * fs), Clamp(bb + db * fs)
  local rr, rg, rb = Clamp(br + dr * rs), Clamp(bg + dg * rs), Clamp(bb + db * rs)
  P.mid:SetVertexColor(fr, fg, fb, 1)
  P.side[1]:SetVertexColor(fr, fg, fb, 1)
  P.side[2]:SetVertexColor(fr, fg, fb, 1)
  for i = 1, 4 do
    P.fill[i]:SetVertexColor(fr, fg, fb, 1)
    P.ring[i]:SetVertexColor(rr, rg, rb, 1)
  end
  P.top:SetVertexColor(rr, rg, rb, 1)
  P.bot:SetVertexColor(rr, rg, rb, 1)
  local er, eg, eb = Clamp(br + dr * es), Clamp(bg + dg * es), Clamp(bb + db * es)
  P.edgeL:SetVertexColor(er, eg, eb, 1)
  P.edgeR:SetVertexColor(er, eg, eb, 1)
end

-- The words, icon and number in their ink (the number's brackets keep
-- their own, dimmer): brighter under the pointer.
local function WordsInk(f, hot)
  local T = Th()
  local tone = hot and "textPrimary" or "textSecondary"
  T.SetColor(f.Label, tone)
  T.SetColor(f.Count, tone)
  T.SetColor(f.Mark, tone)
end

-- The words' and Delete all's tones as the pointer's eases stand: at either
-- end the palette's own (Theme.SetColor, as at rest), between them the two
-- mixed (DN.Type's tones). Only where an ease moved.
function DN.Tones(f)
  local hv, dv = f.__hv or 0, f.__dv or 0
  local t = f.Isle.tone
  if f.__thv ~= hv then
    f.__thv = hv
    if hv <= 0 or hv >= 1 then
      WordsInk(f, hv >= 1)
    else
      local u = 1 - hv
      local r, g, b, a = t[1] * u + t[5] * hv, t[2] * u + t[6] * hv, t[3] * u + t[7] * hv, t[4] * u + t[8] * hv
      f.Label:SetTextColor(r, g, b, a)
      f.Count:SetTextColor(r, g, b, a)
      f.Mark:SetVertexColor(t[9] * u + t[13] * hv, t[10] * u + t[14] * hv, t[11] * u + t[15] * hv, t[12] * u + t[16] * hv)
    end
  end
  if f.__tdv ~= dv then
    f.__tdv = dv
    local text = f.Delete.Text
    if dv <= 0 or dv >= 1 then
      Th().SetColor(text, (dv >= 1) and "negative" or (f.__deleteInk or "textSecondary"))
    else
      local u = 1 - dv
      text:SetTextColor(t[17] * u + t[21] * dv, t[18] * u + t[22] * dv, t[19] * u + t[23] * dv, t[20] * u + t[24] * dv)
    end
  end
end

-------------------------------------------------------------
-- The words (RV.PaintBar calls these for the island's copy)
-------------------------------------------------------------

-- The island's own type, after RV.BarType: Delete all in the words' size
-- and ink, on their middle, its click its words and the house's padding,
-- its words' right end at the row's inset like Hairline's; and the tones
-- the pointer's eases mix (the words and their icon at rest and pointed
-- at, Delete all at rest and red).
function DN.Type(f)
  local T = Th()
  local M = T.Metrics
  local delete = f.Delete
  delete:ClearAllPoints()
  delete:SetPoint("RIGHT", f.Inner, "RIGHT", -(M.inset - M.tightGap), 0)
  delete.Text:ClearAllPoints()
  delete.Text:SetPoint("CENTER", delete, "CENTER", 0, 0)
  f.__deleteInk = "textSecondary"
  local t = f.Isle.tone
  t[1], t[2], t[3], t[4] = T.Ink("textSecondary")
  t[5], t[6], t[7], t[8] = T.Ink("textPrimary")
  local C = T.Colors
  local c0, c1 = C.textSecondary or t, C.textPrimary or t
  t[9], t[10], t[11], t[12] = c0[1], c0[2], c0[3], c0[4] or 1
  t[13], t[14], t[15], t[16] = c1[1], c1[2], c1[3], c1[4] or 1
  t[17], t[18], t[19], t[20] = T.Ink(f.__deleteInk)
  t[21], t[22], t[23], t[24] = T.Ink("negative")
  f.__thv, f.__tdv = nil, nil
  DN.Tones(f)
  f.__fitW = nil
end

-- What the words have room for, in a copy `W` wide (RV.BarFit's rule): the
-- icon and the number always whole, the words cut short past the room. In
-- the island, half the list less its padding; in the bar, the list less
-- the wider of its two ends (the fold sign, Delete all) and the padding,
-- each side, centred. Then the island's side inset at rest (`__s0`, whole
-- units, so its width has the list's parity and both its edges stand on
-- whole units), Delete all's click, the words placed, and how far in from
-- the list's edges the shape's edges must be for the fold sign (at its
-- widest, turned) and Delete all's words both to stand whole inside it
-- (`__reveal`). Numbers only; run when the words, the list's width or the
-- fold sign's place move.
function DN.Fit(f, W)
  local B = Parts()
  local pad, gap, checkGap = B.pad, f.__gap or B.gap, B.checkGap
  local T = Th()
  local M = T.Metrics
  local delete = f.Delete
  local deleteW = math.ceil(tonumber((delete.Text:GetStringWidth())) or 0) + 2 * M.tightGap
  delete:SetSize(deleteW, f.__isleBand or f:GetHeight() or 22)
  -- Its words' ink on the middle, as the words' (RV.Lifts).
  delete.Text:SetPoint("CENTER", delete, "CENTER", 0, f.__liftD or 0)
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
  -- The fold sign's art is 24 of its canvas's 32 at its longest; Delete
  -- all's words end the row's inset from the right.
  local signL = floor((f.__signX or 0) - (f.__canvas or 12) * 12 / 32)
  f.__reveal = max(0, min(signL, M.inset))
  f.__late = nil
  DN.Place(f, f.__wide or false, true)
end

-- The icon, the words and the number centred on the list as one, at the
-- island's cut or the bar's (`wide`), on whole units from the copy's left,
-- their letters on the middle (RV.CentreAt), each lifted so its ink is on
-- the middle (RV.Lifts); the number in one string with whole words
-- (RV.Join). Only where the cut moves, or `again`.
function DN.Place(f, wide, again)
  local cut = (wide and f.__barW or f.__tabW) or false
  if not again and f.__pw == wide and f.__placed == cut then return end
  f.__pw = wide
  local B = Parts()
  local label, count, mark, inner = f.Label, f.Count, f.Mark, f.Inner
  B.Join(f, cut)
  if cut then
    label:SetWidth(cut)
  elseif f.__placed then
    label:SetWidth(0)
  end
  f.__placed = cut
  local wordsW, iconW = f.__wordsW or 0, f.__iconW or 0
  local lead = f.__lead or 0
  local x
  local runL, runR = f.__runL, f.__runR
  if not cut and runL then
    -- Where the client lays the letters out in their string (RV.Span): from
    -- the icon, or from the first letter, to the last, on the middle.
    local lo = (iconW > 0) and 0 or (lead + runL)
    x = floor((f.__W2 or 0) / 2 - (lo + lead + runR) / 2 + 0.5)
  else
    x = B.CentreAt((f.__W2 or 0) / 2, lead + (cut or wordsW) + (f.__tail or 0), f.__shadowX)
  end
  if iconW > 0 then
    mark:ClearAllPoints()
    mark:SetPoint("LEFT", inner, "LEFT", x, f.__iconUp or 0)
    x = x + iconW + B.checkGap
  end
  local lift = f.__lift or 0
  if wordsW > 0 then
    label:ClearAllPoints()
    label:SetPoint("LEFT", inner, "LEFT", x, lift)
    count:ClearAllPoints()
    count:SetPoint("LEFT", label, "RIGHT", f.__gap or B.gap, 0)
  else
    count:ClearAllPoints()
    count:SetPoint("LEFT", inner, "LEFT", x, lift)
  end
end

-------------------------------------------------------------
-- The fold sign (RV.PaintBar, on the island's copy)
-------------------------------------------------------------

-- Whether the copy turns its fold sign, eases its pointer or glides: the
-- panel's own copy, shown, on a client that turns textures.
local function Lively(f)
  local panel = f.__panel
  return panel ~= nil and panel.Notch == f and f.__on == true and panel.GetObjectType ~= nil
end

-- The fold sign drawn as its turn stands: pointing right (folded) and down
-- (open) by its art's coordinates, at its art's size, exactly as it has
-- always stood; between them the right-pointing art turned clockwise about
-- its middle. Only where it moved.
function DN.SignDraw(f)
  local a = f.__sgA or 0
  local k = (f.__canvas or 12) / 32
  local mode = (a <= 0) and 0 or ((a >= 1) and 1 or 2)
  local sign = f.Sign
  if f.__sgMode ~= mode or f.__sgK ~= k then
    local B = Parts()
    local c = (mode == 1) and B.signOpen or B.signShut
    sign:SetTexCoord(c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8])
    if mode == 1 then sign:SetSize(24 * k, 14 * k) else sign:SetSize(14 * k, 24 * k) end
    if mode ~= 2 and f.__sgR and f.__sgR ~= 0 then
      sign:SetRotation(0)
      f.__sgR = 0
    end
    f.__sgMode, f.__sgK = mode, k
  end
  if mode == 2 then
    local r = -a * 1.5707963267949
    if f.__sgR ~= r then
      sign:SetRotation(r)
      f.__sgR = r
    end
  end
end

-- The fold sign told the fold (`open`, the read mail shown): it turns a
-- quarter on its spring where it is seen and the client turns textures;
-- else it stands at once. Called again after a retype, which may have
-- moved its size.
function DN.Sign(f, open)
  local to = open and 1 or 0
  f.__sgTo = to
  f.__sgMode = nil
  local turn = f.__sgA ~= nil and f.__sgA ~= to and (f.__late or 0) > 0 and f.Sign.SetRotation ~= nil and Lively(f)
  if turn then
    DN.Start(f.__panel)
  else
    f.__sgA, f.__sgV = to, 0
  end
  DN.SignDraw(f)
end

-------------------------------------------------------------
-- Drawing: the shape at `e`, the room at `k`
-------------------------------------------------------------

-- The fold sign's and Delete all's alpha with the shape's edges `s` in:
-- none until both stand whole inside it, then up over the rest of the
-- opening, whole as it lands; closing, gone the frame the edge leaves them.
local function Reveal(f, s, e)
  local d = f.__reveal or 0
  if s > d then return 0 end
  if e >= 1 then return 1 end
  local s0 = f.__s0 or 0
  local from = (s0 > d) and (1 - (d + 0.5) / s0) or 0
  local t = (e - from) / (1 - from)
  if t <= 0 then return 0 elseif t >= 1 then return 1 end
  return t * t * (3 - 2 * t)
end

-- The shape `e` open (0 the island, 1 the bar), `yo` whole units off its
-- place in a flight: both edges `s` in from the list's, s whole; the
-- corners' radius the lesser of the capsule's and s, so the ends are round
-- until they come within it of the list's edges and square exactly as they
-- meet them, the ring's straight sides (there only then) going into the
-- fill as the radius goes, since the bar has no sides of its own; the
-- colours as the pointer's eases stand; the fold sign's and Delete all's
-- alpha and Delete all's pointer, each set only where it moved. Every frame
-- of a move comes here, and makes nothing.
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
  local r0 = (f.__isleBand or 22) / 2
  local R = (s < r0) and s or r0
  if f.__R ~= R then
    f.__R = R
    Round(f, R)
  end
  local kf = Smooth(DN.MIX, e)
  local ks = (r0 > 0) and (1 - R / r0) or 1
  local hv, pv = f.__hv or 0, f.__pv or 0
  if f.__kf ~= kf or f.__khv ~= hv or f.__kpv ~= pv or f.__ks ~= ks then
    f.__kf, f.__khv, f.__kpv, f.__ks = kf, hv, pv, ks
    Colour(f, kf, hv, pv, ks)
  end
  local ka = Reveal(f, s, e)
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
-- whole units, and the shadow over it fades away over the last DN.FADE_K;
-- the whole room takes the pointer. The shadow stands from the room's foot
-- to DN.SHADE.up over its top. Only where it moved.
function DN.Room(f, k, m)
  local on = k > 0
  local pad = on and min(m, floor(k)) or 0
  local fill = f.Fill
  local up = f.Shade and f.Shade.up
  if f.__roomOn ~= on then
    f.__roomOn = on
    fill:SetShown(on)
    if up then up:SetShown(on) end
  end
  if f.__roomPad ~= pad then
    f.__roomPad = pad
    fill:ClearAllPoints()
    fill:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, -pad)
    fill:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, pad + (up and 0 or DN.SHADE.up))
    f:SetHitRectInsets(0, 0, -pad, -pad)
  end
  local a = on and min(1, k / DN.FADE_K) or 0
  if f.__fadeE ~= a then
    f.__fadeE = a
    fill:SetAlpha(a)
    if up then up:SetAlpha(a) end
  end
end

-- The copy at `level`, and what it holds over it in order: the shape, the
-- words in the shape, Delete all over the words.
function DN.Levels(f, level)
  f:SetFrameLevel(level)
  f.Shape:SetFrameLevel(level + 1)
  f.Inner:SetFrameLevel(level + 2)
  f.Delete:SetFrameLevel(level + 3)
end

-- The copy's eases landed where they are going (hidden, or no driver).
function DN.Land(f)
  f.__hv = f.__hot and 1 or 0
  f.__pv = f.__down and 1 or 0
  f.__dv = f.Delete.__hot and 1 or 0
  if f.__sgTo then f.__sgA, f.__sgV = f.__sgTo, 0 end
end

-- Everything the drawing remembers forgotten, so the next pass sets each
-- part again (RV.NotchParts, a copy put back into the Notch look).
function DN.Reset(f)
  f.__s, f.__yo, f.__kf, f.__khv, f.__kpv, f.__ks, f.__R, f.__late, f.__live, f.__e = nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil
  f.__roomOn, f.__roomPad, f.__fadeE, f.__pw = nil, nil, nil, nil
  if f.Shade then f.Shade.r = false end
  f.__thv, f.__tdv, f.__sgMode, f.__sgK = nil, nil, nil, nil
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
  DN.Tones(f)
end

-------------------------------------------------------------
-- The pointer
-------------------------------------------------------------

-- The pointer's eases set going toward where the pointer now has them, on
-- the panel's driver where the copy is its own and shown; else there at
-- once.
local function Pointer(f)
  if Lively(f) then
    DN.Start(f.__panel)
  else
    DN.Land(f)
    if f.__e then
      DN.Shape(f, f.__e, f.__yo)
      DN.Tones(f)
    end
  end
end

-- The pointer over the island, its room or the bar: the island's fill and
-- ring a step lighter (the bar's fill washed a little), the words bright;
-- and the bar's tooltip (RV.WordsTip). A press takes the fill a step back
-- from that (darker on a dark palette, lighter on a light one), until the
-- button comes up or the pointer leaves.
function DN.Enter(self)
  self.__hot = true
  Pointer(self)
  local B = Parts()
  if B and B.Tip then B.Tip(self) end
end

function DN.Leave(self)
  self.__hot = nil
  self.__down = nil
  Pointer(self)
  local B = Parts()
  if B and B.TipOff then B.TipOff(self) end
end

function DN.Down(self, button)
  if button ~= "LeftButton" then return end
  self.__down = true
  Pointer(self)
end

function DN.Up(self)
  if not self.__down then return end
  self.__down = nil
  Pointer(self)
end

-- Delete all pointed at or left (after its own handler set its red or its
-- ink outright): its words back at their ease's tone, and the ease set
-- going.
function DN.DeleteHot(self)
  local f = self.__copy
  if not f then return end
  f.__tdv = nil
  Pointer(f)
  DN.Tones(f)
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
  DN.Tones(f)
  DN.SignDraw(f)
end

-- Whether anything is still to move: a glide, the bar's springs, the
-- copy's eases or its fold sign.
function DN.Busy(panel)
  if panel._glideTo then return true end
  local to = panel._barTo
  if to ~= nil and (panel._barE ~= to or (panel._barEV or 0) ~= 0 or (panel._barYO or 0) ~= 0) then return true end
  local f = panel.Notch
  if not (f and f.__on) then return false end
  if f.__hv ~= (f.__hot and 1 or 0) or f.__pv ~= (f.__down and 1 or 0) or f.__dv ~= (f.Delete.__hot and 1 or 0) then
    return true
  end
  return f.__sgA ~= f.__sgTo
end

-- One frame of the glide: the list a spring's step nearer the bar's place,
-- on whole units toward it, never past it and never back, and one pass of
-- the list where that moved it. Answers whether it still moves.
local function GlideStep(panel, dt)
  local to = panel._glideTo
  local y, v = Spring(panel._glideY, panel._glideV, to, DN.GLIDE, dt)
  local landed = abs(to - y) < 0.5 and abs(v) < DN.LAND_G
  if landed then y, v = to, 0 end
  panel._glideY, panel._glideV = y, v
  local was = panel._glideSet
  local set
  if landed then
    set = to
    panel._glideTo = nil
  elseif to > was then
    set = min(to, max(was, floor(y)))
  else
    set = max(to, min(was, ceil(y)))
  end
  if set ~= was then
    panel._glideSet = set
    panel.MailListScroll:SetVerticalScroll(set)
  end
  return not landed
end

-- One frame of a move: each spring and ease a step nearer, drawn; off once
-- all have landed.
function DN.Tick(driver, elapsed)
  local panel = driver.panel
  local dt = min(elapsed or 0, DN.STEP)
  local moving = false
  panel._ticking = true
  if panel._glideTo and GlideStep(panel, dt) then moving = true end
  local to = panel._barTo
  if to ~= nil then
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
  end
  local f = panel.Notch
  if f and f.__on then
    local k = 1 - exp(-dt / DN.EASE)
    local m
    local th, tp, td = f.__hot and 1 or 0, f.__down and 1 or 0, f.Delete.__hot and 1 or 0
    if f.__hv ~= th then f.__hv, m = Ease(f.__hv, th, k); moving = moving or m end
    if f.__pv ~= tp then f.__pv, m = Ease(f.__pv, tp, k); moving = moving or m end
    if f.__dv ~= td then f.__dv, m = Ease(f.__dv, td, k); moving = moving or m end
    local sa, st = f.__sgA, f.__sgTo
    if sa ~= nil and st ~= nil and (sa ~= st or (f.__sgV or 0) ~= 0) then
      local a, v = Spring(sa, f.__sgV or 0, st, DN.TURN, dt)
      if abs(a - st) < DN.LAND and abs(v) < DN.LAND_V then a, v = st, 0 else moving = true end
      if a < 0 then a = 0 elseif a > 1 then a = 1 end
      f.__sgA, f.__sgV = a, v
    end
  elseif f then
    DN.Land(f)
  end
  panel._ticking = nil
  DN.Draw(panel)
  if not moving then DN.Stop(panel) end
end

-- Hidden with the panel (another tab, the window closing) while a move
-- runs: everything landed where it was going -- the glide's list at the
-- bar's place -- nothing left running.
function DN.Hidden(driver)
  local panel = driver.panel
  local glide = panel._glideTo
  if glide then
    panel._glideTo, panel._glideV, panel._glideSet = nil, 0, glide
    panel.MailListScroll:SetVerticalScroll(glide)
  end
  if panel._barTo ~= nil then panel._barE, panel._barEV = panel._barTo, 0 end
  panel._barYO, panel._barYV = 0, 0
  local f = panel.Notch
  if f then DN.Land(f) end
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
-- The glide (RV.GoToBar: a click on the island, or on Hairline's and Full
-- row's copy at the foot)
-------------------------------------------------------------

-- The list glides to offset `to` from where it stands, a glide already
-- under way keeping its pace.
function DN.Glide(panel, to)
  local scroll = panel.MailListScroll
  local y = scroll:GetVerticalScroll() or 0
  if not panel._glideTo then
    if abs(to - y) < 0.5 then
      scroll:SetVerticalScroll(to)
      return
    end
    panel._glideY, panel._glideV = y, 0
    panel._glideSet = y
  end
  panel._glideTo = to
  DN.Start(panel)
end

-- Every pass of the list (CollectTab, the virtualiser), at `offset`: a
-- glide stops where the list stands the moment anything but the glide has
-- moved it -- the wheel, the scroll bar, a key, a refresh that shortened
-- the list.
function DN.Watch(panel, offset)
  if panel._glideTo and abs(offset - (panel._glideSet or offset)) > 0.01 then
    panel._glideTo, panel._glideV = nil, 0
  end
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
-- the bar's state forgotten, so the bar's next coming is drawn as it then
-- stands. A glide keeps going (Hairline's and Full row's copy glides too).
function DN.Off(panel)
  local N = panel.Notch
  if N then
    Shown(N, false)
    DN.Land(N)
  end
  if panel._barE ~= nil or panel._barTo ~= nil then
    panel._barE, panel._barEV, panel._barTo = nil, nil, nil
    panel._barYO, panel._barYV, panel._barYT, panel._barFoot, panel._barK = nil, nil, nil, nil, nil
  end
  if not panel._ticking and not panel._glideTo then DN.Stop(panel) end
end

-- One pass of the list. `at`: the bar's place in the list (nil for none);
-- `band`: the bar's height. The bar stands at the lower of its place and
-- its stand, the room's margin over the view's foot; while the place is
-- below the stand, in the room over its shadow, the rows seen through it.
-- It opens while its place's top is in the view, and closes once it is
-- not.
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
  elseif panel._barYT and foot ~= panel._barFoot and abs(y - panel._barYT) > band and e < 0.5 and not panel._glideTo then
    -- Carried across the stand in one pass while still mostly island (a
    -- wheel step; a glide carries it by the rule): it stays where it was
    -- on screen and flies to its new place.
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
  -- Inside a frame of the move (a glide's pass), the move draws.
  if panel._ticking then return end
  DN.Draw(panel)
  if DN.Busy(panel) then DN.Start(panel) else DN.Stop(panel) end
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
  if panel._glideTo then s = s .. string.format(", gliding to %d", floor(panel._glideTo + 0.5)) end
  return s
end
