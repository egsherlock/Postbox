local _, ns = ...

-------------------------------------------------------------
-- Postbox :: the bar over the read mail, and its notch (CollectTab,
-- RV.BuildBar and RV.PaintBar draw both).
--
-- While the bar's place is below the view, the bar waits at the list's
-- foot as its notch: its own fill, outline and words, as narrow as the
-- words, centred on the foot, the bar's own height. It stays there however
-- the list scrolls, folded or not, until the bar's place comes up. Then,
-- or when the notch is clicked (which unfolds the read mail and takes the
-- list to it), the notch opens where it stands: nothing moves sideways,
-- the fill grows out of both its sides to the list's edges, and the fold
-- sign and Delete all fade in at the bar's ends over the second half. Open
-- at the foot, it is the bar standing in for its place, which is coming
-- up under it; the moment the bar's own bottom reaches the foot, the bar in
-- its place takes over in the same spot. Scrolling back, the bar at the
-- foot closes into the notch again, a little quicker.
--
-- One state per list: how open the bar stands (panel._barV, 0 the notch,
-- 1 the bar) and where it is going (panel._barTo). It is the state that
-- moves, never a position: a wheel step moves the list half a view at
-- once, so the bar's place can arrive anywhere, and whichever copy stands
-- -- the notch's, or the bar in its place -- is drawn at the state as it
-- is. A move turned round half-way runs back from where it stands.
--
-- A move is one OnUpdate on a frame of the panel's own, set when it starts
-- and taken off when it lands; the window hidden mid-move lands it at
-- once. At rest nothing runs, and a pass compares a few numbers and makes
-- nothing.
-------------------------------------------------------------

ns.DividerNotch = ns.DividerNotch or {}
local DN = ns.DividerNotch

local max, min = math.max, math.min

-- How long opening takes, and closing (85% of it).
DN.OPEN = 0.20
DN.CLOSE = 0.17
-- The longest frame a move counts: a hitch slows it, never skips it.
DN.STEP = 0.05

local function Parts() return ns.CollectTab and ns.CollectTab.BarParts end

-- Ease in and out, even both ways, so a move turned round runs back along
-- the same curve.
local function Ease(u)
  return u * u * (3 - 2 * u)
end
DN.Ease = Ease

-------------------------------------------------------------
-- The move
-------------------------------------------------------------

-- One frame of a move: the state a step nearer where it is going, drawn on
-- the copy that stands; off once it lands.
function DN.Tick(driver, elapsed)
  local panel = driver.panel
  local v, to = panel._barV, panel._barTo
  if v == nil or to == nil then
    DN.Stop(panel)
    return
  end
  elapsed = min(elapsed or 0, DN.STEP)
  if to > v then
    v = min(to, v + elapsed / DN.OPEN)
  else
    v = max(to, v - elapsed / DN.CLOSE)
  end
  panel._barV = v
  local who = panel._barWho
  if who and who.__on then Parts().Apply(who, Ease(v)) end
  if v == to then DN.Stop(panel) end
end

-- Hidden with the panel (another tab, the window closing) while a move
-- runs: landed where it was going, nothing left running.
function DN.Hidden(driver)
  local panel = driver.panel
  if panel._barTo ~= nil then panel._barV = panel._barTo end
  DN.Stop(panel)
  local who = panel._barWho
  if who and who.__on and panel._barV then Parts().Apply(who, Ease(panel._barV)) end
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
-- History, another character's box): the notch put away and the state
-- forgotten, so the bar's next coming is drawn as it then stands.
function DN.Off(panel)
  local N = panel.Notch
  if N then Shown(N, false) end
  if panel._barV ~= nil or panel._barWho ~= nil then
    DN.Stop(panel)
    panel._barV, panel._barTo, panel._barWho = nil, nil, nil
  end
end

-- One pass of the list. `at`: the bar's place in the list (nil for none);
-- `band`: the bar's height. The bar in its place has been placed and shown
-- by the pass where its slot is in the rows it binds.
function DN.Update(panel, at, offset, viewport, stride, band, compact)
  local N, divider = panel.Notch, panel.Divider
  if not (at and N and divider) or viewport <= 0 then
    DN.Off(panel)
    return
  end
  local P = Parts()
  local slotTop = (at - 1) * stride
  local viewBottom = offset + viewport
  local who, to
  if slotTop + band <= viewBottom + 0.5 then
    -- Its own bottom in the view: the bar in its place, open.
    who, to = divider, 1
  elseif slotTop + 0.5 < viewBottom then
    -- Its place coming up at the foot: the notch open into the bar there.
    who, to = N, 1
  else
    -- Below the view: the notch.
    who, to = N, 0
  end
  divider.__on = (who == divider) and divider:IsShown() or false
  if who == N then
    divider:Hide()
    -- On the view's foot, or the list's end where the list is shorter
    -- (it must not reach past the list, which the client would scroll to).
    local child = panel.MailListChild
    local foot = viewBottom
    local listH = child:GetHeight() or foot
    if listH < foot then foot = listH end
    local y = -(foot - band)
    if N.__y ~= y or N.__h ~= band then
      N.__y, N.__h = y, band
      N:ClearAllPoints()
      N:SetPoint("TOPLEFT", child, "TOPLEFT", 0, y)
      N:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, y)
      N:SetHeight(band)
    end
    -- Over the rows, under the fan's plate (CollectTab, + 10).
    local level = child:GetFrameLevel() + 8
    if N.__level ~= level then
      N.__level = level
      N:SetFrameLevel(level)
    end
    Shown(N, true)
  else
    Shown(N, false)
  end
  panel._barWho = who
  local v = panel._barV
  -- First seen: as it stands, with no move.
  if v == nil then v = to end
  panel._barV, panel._barTo = v, to
  if who.__on then
    P.Paint(panel, who, compact)
    P.Apply(who, Ease(v))
  end
  if v ~= to then DN.Start(panel) else DN.Stop(panel) end
end

-- For `/postbox debug divider`: how the bar stands.
function DN.State(panel)
  local who = panel and panel._barWho
  if not who then return "none" end
  local v, to = panel._barV or 0, panel._barTo or 0
  local where = (who == panel.Notch) and ((to == 1) and "open at the foot" or "notch at the foot") or "in its place"
  if v ~= to then where = where .. string.format(" (moving, %d%%)", math.floor(v * 100 + 0.5)) end
  return where
end
