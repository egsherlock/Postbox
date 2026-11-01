-- Postbox foundation :: movable, resizable, position-remembering windows.
--
-- Escape-to-close registration, position and size persistence, anchor
-- normalisation, a manual resize grip, and a one-call themed backdrop.
--
-- Publishes: ns.Core.UI.Helpers

local _, ns = ...

ns.Core = ns.Core or {}
local Core = ns.Core
Core.UI = Core.UI or {}
Core.UI.Helpers = Core.UI.Helpers or {}

local Helpers = Core.UI.Helpers

local floor = math.floor
local min = math.min
local max = math.max

local function Clamp(value, low, high)
  if type(value) ~= "number" then return low end
  if value < low then return low end
  if value > high then return high end
  return value
end

local function Round(value)
  return floor((tonumber(value) or 0) + 0.5)
end

-- The client's tooltip background and border, tiled, with a 12px edge and 3px
-- insets: that combination is what produces the classic tooltip frame look.
-- A UI pack's loose-file texture overrides can restyle these client-wide;
-- that is accepted on purpose -- see the decision note on SURFACE_TEXTURE in
-- Lib/UI/Theme.lua.
local DEFAULT_BACKDROP = {
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true,
  tileSize = 16,
  edgeSize = 12,
  insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local DEFAULT_BOUNDS = { minW = 400, maxW = 1200, minH = 300, maxH = 900 }

-- Long enough that a drag never writes mid-gesture, short enough that a
-- crash-to-desktop right after a resize still keeps the new size.
local SIZE_SAVE_DELAY = 0.25

-------------------------------------------------------------
-- Escape-to-close
-------------------------------------------------------------

-- CloseSpecialWindows scans UISpecialFrames on every Escape press, so a
-- duplicate entry costs every addon in the UI. Names we have already added are
-- remembered locally rather than re-scanned.
local escRegistered = {}

function Helpers.RegisterEscClose(frame)
  if not frame or type(frame.GetName) ~= "function" then return false end

  local name = frame:GetName()
  if type(name) ~= "string" or name == "" then return false end
  if escRegistered[name] then return true end
  if type(UISpecialFrames) ~= "table" then return false end

  for i = 1, #UISpecialFrames do
    if UISpecialFrames[i] == name then
      escRegistered[name] = true
      return true
    end
  end

  UISpecialFrames[#UISpecialFrames + 1] = name
  escRegistered[name] = true
  return true
end

-------------------------------------------------------------
-- Geometry
-------------------------------------------------------------

-- Replaces whatever anchors a frame has with a single top-left point in screen
-- coordinates.
--
-- This is load-bearing, not a convenience: a frame anchored by its centre grows
-- symmetrically when its size changes, so a bottom-right resize drag moves the
-- top-left corner and the window appears to jump. Pinned to one corner, size
-- changes grow only rightward and downward.
--
-- GetTop() is measured from the bottom of the screen, so the pin has to be
-- expressed against UIParent's BOTTOMLEFT, not its TOPLEFT.
function Helpers.PinFrameTopLeft(frame)
  if not frame or type(frame.GetLeft) ~= "function" then return false end

  local left, top = frame:GetLeft(), frame:GetTop()
  if not left or not top then return false end  -- not laid out yet

  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
  return true
end

-- A window whose place has left the screen -- a saved spot from a larger
-- screen or UI scale, or one written while something pushed the window off
-- (the 2026-11-01 probe) -- is moved back whole onto it, pinned by its
-- top-left as PinFrameTopLeft does; one taller or wider than the screen
-- keeps its title bar's corner on it. Answers whether it moved. Nothing is
-- touched where the window already stands on the screen, or is not laid
-- out yet.
function Helpers.KeepOnScreen(frame)
  if not frame or type(frame.GetLeft) ~= "function" then return false end
  local left, top, w, h = frame:GetLeft(), frame:GetTop(), frame:GetWidth(), frame:GetHeight()
  if not (left and top and w and h) then return false end
  local s = frame:GetEffectiveScale() or 1
  local ui = UIParent:GetEffectiveScale() or 1
  if s <= 0 or ui <= 0 then return false end
  -- The screen in the frame's own units.
  local k = ui / s
  local screenW, screenH = (UIParent:GetWidth() or 0) * k, (UIParent:GetHeight() or 0) * k
  if screenW <= 0 or screenH <= 0 then return false end
  local x = max(0, min(left, screenW - w))
  local y = min(screenH, max(top, h))
  if math.abs(x - left) < 0.5 and math.abs(y - top) < 0.5 then return false end
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
  return true
end

-- Records the frame's centre as an integer offset from the screen centre.
-- Both centres are nil before the first layout pass; bail rather than write
-- garbage.
function Helpers.SaveFramePosition(frame, store)
  if not frame or type(store) ~= "table" then return false end

  local cx, cy = frame:GetCenter()
  if not cx or not cy then return false end

  local ux, uy = UIParent:GetCenter()
  if not ux or not uy then return false end

  -- The offset is read back in the frame's own units (its CENTER against
  -- UIParent's), and UIParent's centre is in UIParent's: under a window scale
  -- the two differ, so the screen's centre is put into the frame's units
  -- first. At the same scale the factor is exactly 1 and nothing moves.
  local own = type(frame.GetEffectiveScale) == "function" and frame:GetEffectiveScale() or nil
  local parent = UIParent:GetEffectiveScale()
  if type(own) == "number" and own > 0 and type(parent) == "number" and parent > 0 and own ~= parent then
    local k = parent / own
    ux, uy = ux * k, uy * k
  end

  store.x = Round(cx - ux)
  store.y = Round(cy - uy)
  return true
end

-------------------------------------------------------------
-- Beside the opener
--
-- The options, Manage Recipients and the Postbox window's preview each open
-- beside whatever opened them, every time: right of the Postbox window from
-- its cog, left of the minimap from the icon, and so on. Top edges line up
-- for a place to the left or right, left edges for one below; a side with
-- no room on screen gives way to the opposite one, and wherever the window
-- lands it is clamped whole onto the screen and put on whole pixels. A
-- window opened from nowhere in particular (a slash command) stands in the
-- screen's middle. Nothing is remembered: a drag lasts while the window
-- stays open, and the next open is beside its opener again.
--
-- Everything is measured in screen units (a frame's units times its
-- effective scale), since the windows carry different scales; the gap is
-- UIParent's 8 units, so two windows placed beside each other either way
-- round stand the same distance apart. The window is anchored to UIParent,
-- or, asked to stay beside its opener (`attach`), to the opener's facing
-- edge: the client then carries it along as the opener moves or resizes,
-- and nothing is added to the opener or heard from it. Only the placed
-- window's own anchors are written, never the opener's. (Watching the
-- opener instead, through a child frame stretched from the screen's corner
-- to the window's, was tried on 2026-11-01 and reverted: a window holding
-- such a child was pushed off the top of the screen when dragged, and saved
-- there.)
-------------------------------------------------------------

local BESIDE_GAP = 8

-- frame -> its left, right, bottom and top in screen units, or nil before
-- it has been laid out.
local function ScreenRect(frame)
  if not (frame and type(frame.GetLeft) == "function") then return nil end
  local l, r, b, t = frame:GetLeft(), frame:GetRight(), frame:GetBottom(), frame:GetTop()
  if not (l and r and b and t) then return nil end
  local s = frame:GetEffectiveScale() or 1
  return l * s, r * s, b * s, t * s
end

-- One physical pixel in screen units: 768 of them span the screen's height.
local function PixelUnit()
  if type(GetPhysicalScreenSize) == "function" then
    local _, h = GetPhysicalScreenSize()
    if type(h) == "number" and h > 0 then return 768 / h end
  end
  return 1
end

local function Snap(value, px)
  return floor(value / px + 0.5) * px
end

local OPPOSITE = { right = "left", left = "right", below = "above", above = "below" }

-- How a window placed on each side is held by its opener's edge, when it
-- stays beside it: its own point, and the opener's it is set against.
local HOLD = {
  right = { "TOPLEFT", "TOPRIGHT" }, left = { "TOPRIGHT", "TOPLEFT" },
  below = { "TOPLEFT", "BOTTOMLEFT" }, above = { "BOTTOMLEFT", "TOPLEFT" },
}

-- frame, opener, side [, keep [, attach]] -> places `frame` (its size
-- already settled) beside `opener` on `side` ("right", "left" or "below"),
-- and answers the side it took ("right", "left", "below" or "above"; nil in
-- the middle). `keep`, a side an earlier placement of this same showing
-- took, kept while it has the room. `attach`: held by the opener's edge from
-- now on (HOLD), so it goes where the opener goes; otherwise anchored to
-- the screen. With no opener, or one not laid out, the screen's middle.
function Helpers.PlaceBeside(frame, opener, side, keep, attach)
  if not (frame and type(frame.GetWidth) == "function") then return nil end
  local s = frame:GetEffectiveScale() or 1
  if s <= 0 then s = 1 end
  local ui = UIParent:GetEffectiveScale() or 1
  local screenW, screenH = (UIParent:GetWidth() or 0) * ui, (UIParent:GetHeight() or 0) * ui
  local w, h = (frame:GetWidth() or 0) * s, (frame:GetHeight() or 0) * s

  local oL, oR, oB, oT = ScreenRect(opener)
  if not oL then opener = nil end

  local x, y, took
  if not opener then
    x, y = (screenW - w) / 2, (screenH + h) / 2
  else
    local gap = BESIDE_GAP * ui
    if side == "below" or side == "above" then
      local fitsBelow, fitsAbove = oB - gap - h >= 0, oT + gap + h <= screenH
      local goAbove
      if (keep == "below" and fitsBelow) or (keep == "above" and fitsAbove) then
        goAbove = keep == "above"
      else
        -- Above it where only above has the room.
        goAbove = side == "above" and (fitsAbove or not fitsBelow) or (not fitsBelow and fitsAbove)
      end
      x, y, took = oL, goAbove and (oT + gap + h) or (oB - gap), goAbove and "above" or "below"
    else
      local right, left = oR + gap, oL - gap - w
      local fitsRight, fitsLeft = right + w <= screenW, left >= 0
      local goLeft
      if (keep == "right" and fitsRight) or (keep == "left" and fitsLeft) then
        goLeft = keep == "left"
      elseif fitsRight ~= fitsLeft then
        goLeft = fitsLeft
      elseif fitsRight then
        goLeft = side == "left"
      else
        -- Neither side has the room: the one with more, clamped below.
        goLeft = oL > screenW - oR
      end
      x, y, took = goLeft and left or right, oT, goLeft and "left" or "right"
    end
  end

  x = max(0, min(x, screenW - w))
  y = min(screenH, max(y, h))
  local px = PixelUnit()
  x, y = Snap(x, px), Snap(y, px)
  frame:ClearAllPoints()
  local hold = attach and opener and HOLD[took]
  if hold then
    -- The offset from the opener's point, in the frame's own units.
    local ax = (hold[2] == "TOPRIGHT") and oR or oL
    local ay = (hold[2] == "BOTTOMLEFT") and oB or oT
    local fx = (hold[1] == "TOPRIGHT") and (x + w) or x
    local fy = (hold[1] == "BOTTOMLEFT") and (y - h) or y
    frame:SetPoint(hold[1], opener, hold[2], (fx - ax) / s, (fy - ay) / s)
  else
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / s, y / s)
  end
  return took
end

-- frame, opener, side -> `frame` held by `opener`'s edge on `side` (HOLD)
-- exactly where it stands now: nothing moves, not even by a part of a
-- pixel, and from now on it goes where the opener goes. For a window that
-- was already placed, which something then opened beside (the preview
-- beside the options): placing it again would shift it by the rounding of
-- the newcomer's edge. Answers whether it is held.
function Helpers.HoldWhereItStands(frame, opener, side)
  local hold = HOLD[side]
  if not (hold and frame and opener) then return false end
  local fL, fR, fB, fT = ScreenRect(frame)
  local oL, oR, oB, oT = ScreenRect(opener)
  if not (fL and oL) then return false end
  local s = frame:GetEffectiveScale() or 1
  if s <= 0 then return false end
  local ax = (hold[2] == "TOPRIGHT") and oR or oL
  local ay = (hold[2] == "BOTTOMLEFT") and oB or oT
  local fx = (hold[1] == "TOPRIGHT") and fR or fL
  local fy = (hold[1] == "BOTTOMLEFT") and fB or fT
  frame:ClearAllPoints()
  frame:SetPoint(hold[1], opener, hold[2], (fx - ax) / s, (fy - ay) / s)
  return true
end

-- The side opposite `side`: where the opener stands seen from the window
-- placed beside it.
function Helpers.OppositeSide(side)
  return OPPOSITE[side]
end

-- `extraHeight` is transient height the caller layered on top of the size the
-- user actually chose -- the mail window grows to fit a second row of attachment
-- slots, and again to fit a message that has outgrown its box. Subtract it so
-- the persisted height is always the user's base size, whatever the window
-- happens to be showing at the moment the write lands. `extraWidth` is the
-- same for width: the mail window is widened while one of its rows needs more.
local function SaveFrameSize(frame, store, bounds, extraHeight, extraWidth)
  if not frame or type(store) ~= "table" then return false end

  local width, height = frame:GetSize()
  if not width or not height then return false end

  height = height - (tonumber(extraHeight) or 0)
  width = width - (tonumber(extraWidth) or 0)
  store.width = Clamp(Round(width), bounds.minW, bounds.maxW)
  store.height = Clamp(Round(height), bounds.minH, bounds.maxH)
  return true
end

-------------------------------------------------------------
-- Window persistence
-------------------------------------------------------------

function Helpers.ApplyWindowPersistence(frame, store, opts)
  if not frame or type(store) ~= "table" then return false end

  opts = type(opts) == "table" and opts or {}
  local bounds = {
    minW = tonumber(opts.minW) or DEFAULT_BOUNDS.minW,
    maxW = tonumber(opts.maxW) or DEFAULT_BOUNDS.maxW,
    minH = tonumber(opts.minH) or DEFAULT_BOUNDS.minH,
    maxH = tonumber(opts.maxH) or DEFAULT_BOUNDS.maxH,
  }

  local extraHeightFn = type(opts.extraHeightFn) == "function" and opts.extraHeightFn or nil
  local function ExtraHeight()
    if not extraHeightFn then return 0 end
    -- Parenthesised so a callback returning several values cannot spill its
    -- second into tonumber's base argument, which must be 2-36 and throws.
    return tonumber((extraHeightFn())) or 0
  end
  local extraWidthFn = type(opts.extraWidthFn) == "function" and opts.extraWidthFn or nil
  local function ExtraWidth()
    if not extraWidthFn then return 0 end
    return tonumber((extraWidthFn())) or 0
  end

  -- `savePlace`: false for a window placed by its opener instead
  -- (Helpers.PlaceBeside), whose place this neither restores nor writes; a
  -- function for one that stands, for a while, somewhere that is not its
  -- own place (the Postbox window's preview), asked at each write.
  local savePlace = opts.savePlace
  local function MaySavePlace()
    if savePlace == nil then return true end
    if type(savePlace) == "function" then return savePlace() and true or false end
    return savePlace and true or false
  end

  -- Restore size first, then position, then pin immediately — otherwise the
  -- very first layout after login uses a centre anchor and the first resize
  -- drag moves the window.
  if store.width and store.height then
    frame:SetSize(store.width, store.height)
  end

  if savePlace ~= false and store.x and store.y then
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", store.x, store.y)
  end
  Helpers.PinFrameTopLeft(frame)
  Helpers.KeepOnScreen(frame)

  -- OnSizeChanged fires on every frame of a resize drag. Writing to saved
  -- variables 60 times a second is pure waste, so coalesce: mark dirty, flush
  -- once shortly after the last change (and immediately on hide).
  local dirty, scheduled = false, false

  local function Flush()
    scheduled = false
    if not dirty then return end
    dirty = false
    SaveFrameSize(frame, store, bounds, ExtraHeight(), ExtraWidth())
  end

  local function Queue()
    dirty = true
    if scheduled then return end
    if C_Timer and type(C_Timer.After) == "function" then
      scheduled = true
      C_Timer.After(SIZE_SAVE_DELAY, Flush)
    else
      Flush()
    end
  end

  -- Drag-stop is *replaced* (chaining to whatever was installed) rather than
  -- hooked, because a hook would leave the frame still moving.
  local previousDragStop = frame:GetScript("OnDragStop")
  frame:SetScript("OnDragStop", function(self, ...)
    self:StopMovingOrSizing()
    if previousDragStop then previousDragStop(self, ...) end
    if MaySavePlace() then Helpers.SaveFramePosition(self, store) end
    -- StartMoving can leave a non-corner anchor; re-pin so the next resize
    -- starts from a clean single corner.
    Helpers.PinFrameTopLeft(self)
  end)

  frame:HookScript("OnSizeChanged", Queue)

  -- Pin on every show, before the user can reach the resize grip. This is what
  -- actually prevents the resize jump: by mouse-down the anchor is already a
  -- stable single corner and no anchor mutation happens in the same handler.
  frame:HookScript("OnShow", function(self)
    Helpers.PinFrameTopLeft(self)
    Helpers.KeepOnScreen(self)
  end)

  frame:HookScript("OnHide", function(self)
    if MaySavePlace() then Helpers.SaveFramePosition(self, store) end
    dirty = true
    Flush()
  end)

  return true
end

-------------------------------------------------------------
-- Resize grip
-------------------------------------------------------------

-- A small grabber in the bottom-right corner, above the frame in level.
--
-- The resize is driven manually from the cursor delta rather than through
-- frame:StartSizing(), because the built-in sizing intermittently snaps the
-- dragged corner on mouse-down when its internal reference is stale after a
-- move or a restore. Driving the size ourselves is snap-proof: pressing
-- without moving changes nothing, and dragging tracks the cursor exactly.
--
-- `onStart` fires on mouse-down, BEFORE the first pixel of the drag, and exists
-- so an owner that layers transient height on the window can settle up first:
-- the grip is about to become the authority on the height, and it has to start
-- from the size the user can actually see. `onStop` fires on release, once.
--
-- `dragMinHeightFn(frame)` is an optional floor for THIS drag only, asked once
-- on mouse-down and never again: the mail window raises it so a message already
-- on screen cannot be crushed under its own text in one gesture. It is a
-- separate question from SetResizeBounds because it is transient -- it must not
-- become the height a stored size is clamped to, and it must not survive the
-- release. Only ever raises the floor, and never above the height the drag
-- started at, so the answer cannot move the window on mouse-down.
-- `onReset`, when given, answers a RIGHT-click on the grip: the owner puts
-- the window back to its default size. The grip is the one control whose
-- whole meaning is "size", so a second gesture on it that means "the size
-- you started with" needs no teaching.
-- `snapFn(frame, height) -> height`, when given, is asked for every height
-- the drag proposes, after the bounds have been applied: the owner puts it
-- on whatever steps its content comes in (whole rows), and the bounds are
-- applied once more to what it answers.
function Helpers.CreateResizeButton(frame, onStop, onStart, dragMinHeightFn, onReset, snapFn)
  if not frame then return nil end

  local button = CreateFrame("Button", nil, frame)
  button:SetSize(16, 16)
  button:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 6)
  button:SetFrameStrata(frame:GetFrameStrata())
  button:SetFrameLevel(frame:GetFrameLevel() + 30)

  -- The art: the mockups' two thin diagonals (Theme.GLYPHS.resize) at their
  -- own size, their box flush with the grip's bottom-right corner, pointing
  -- into the window's. Grey at rest; white while pointed at and while
  -- held, a drag that outruns the pointer included. The grip, not the
  -- window, owns the texture (see Theme.Glyph). Blizzard's chat grabber
  -- where the theme's glyphs are not to be had. Read at call time: Lib
  -- loads before Core/Theme.lua.
  local T = ns.Theme
  local glyph = T and type(T.Glyph) == "function" and T.Glyph(button, "resize", nil, "ARTWORK") or nil
  local held = false
  local function Tint(lit)
    if glyph and T.SetColor then T.SetColor(glyph, lit and "textPrimary" or "textDisabled") end
  end
  if glyph then
    local w, h = T.GLYPHS.resize.w, T.GLYPHS.resize.h
    glyph:SetPoint("CENTER", button, "BOTTOMRIGHT", -w / 2, h / 2)
    Tint(false)
    button:SetScript("OnEnter", function() Tint(true) end)
    button:SetScript("OnLeave", function() Tint(held) end)
  else
    button:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    button:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    button:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  end

  local sizing = false

  local function StopSizing()
    button:SetScript("OnUpdate", nil)
    -- Also cancel any engine-driven move in progress (a title-bar drag when the
    -- window is hidden mid-gesture). Harmless otherwise.
    if type(frame.StopMovingOrSizing) == "function" then frame:StopMovingOrSizing() end
    -- Let go, or hidden: lit only if the pointer is still on the grip.
    held = false
    Tint(button:IsVisible() and button:IsMouseOver())
    if not sizing then return end
    sizing = false
    if type(onStop) == "function" then onStop(frame) end
  end

  button:SetScript("OnMouseDown", function(self, mouseButton)
    held = true
    Tint(true)
    if mouseButton == "RightButton" then
      if type(onReset) == "function" then onReset(frame) end
      return
    end
    -- Before anything is measured: the owner may fold transient height into the
    -- base here, and the start height read below has to be the settled one.
    sizing = true
    if type(onStart) == "function" then onStart(frame) end

    -- Pin so SetSize grows toward the bottom-right only.
    Helpers.PinFrameTopLeft(frame)

    local scale = frame:GetEffectiveScale()
    if type(scale) ~= "number" or scale <= 0 then scale = 1 end

    local cursorX, cursorY = GetCursorPosition()
    local startX, startY = cursorX / scale, cursorY / scale
    local startW, startH = frame:GetWidth(), frame:GetHeight()
    local lastW, lastH = startW, startH

    -- Bounds do not change during a drag; read them once.
    local minW, minH, maxW, maxH
    if type(frame.GetResizeBounds) == "function" then
      minW, minH, maxW, maxH = frame:GetResizeBounds()
    end

    -- The owner's transient floor, on top of the standing one. Clamped to the
    -- start height (a floor above the window's current size would snap it taller
    -- the instant the grip was touched) and to the ceiling (a floor above the
    -- maximum would leave the drag unable to reach either bound).
    if type(dragMinHeightFn) == "function" then
      -- Parenthesised so a callback returning several values cannot spill its
      -- second into tonumber's base argument, which must be 2-36 and throws.
      local dragMin = tonumber((dragMinHeightFn(frame)))
      if dragMin then
        if dragMin > startH then dragMin = startH end
        if maxH and maxH > 0 and dragMin > maxH then dragMin = maxH end
        if not minH or dragMin > minH then minH = dragMin end
      end
    end

    self:SetScript("OnUpdate", function()
      local x, y = GetCursorPosition()
      x, y = x / scale, y / scale

      local width = startW + (x - startX)   -- drag right -> wider
      local height = startH + (startY - y)  -- drag down  -> taller

      -- SetSize is not clamped by SetResizeBounds (only the built-in sizing
      -- is), so clamp manually. Each end of each axis is applied on its own:
      -- pairing them meant a client with no GetResizeBounds -- or an owner that
      -- supplied only the transient floor above -- got no clamp at all.
      -- Ceiling first, floor second, so the floor still wins if a caller ever
      -- supplies bounds that cross -- the order the paired form had.
      if maxW and maxW > 0 then width = min(maxW, width) end
      if minW then width = max(minW, width) end
      if maxH and maxH > 0 then height = min(maxH, height) end
      if minH then height = max(minH, height) end

      if type(snapFn) == "function" then
        local snapped = tonumber((snapFn(frame, height)))
        if snapped then
          height = snapped
          if maxH and maxH > 0 then height = min(maxH, height) end
          if minH then height = max(minH, height) end
        end
      end

      -- Holding the mouse still would otherwise re-set an identical size every
      -- frame, firing OnSizeChanged and everything hooked to it.
      if width ~= lastW or height ~= lastH then
        lastW, lastH = width, height
        frame:SetSize(width, height)
      end
    end)
  end)

  button:SetScript("OnMouseUp", StopSizing)
  button:SetScript("OnHide", StopSizing)

  return button
end

-------------------------------------------------------------
-- Themed backdrop
-------------------------------------------------------------

-- SetBackdrop rebuilds the whole nine-slice, and this runs on every themed
-- refresh; apply the backdrop once per frame and only re-colour afterwards.
local backdropApplied = setmetatable({}, { __mode = "k" })

-- Applies a backdrop (the caller's, or the hairline default), then the
-- theme's colours for the named variant, and optionally the surface texture.
function Helpers.ApplyThemedBackdrop(frame, theme, variant, withSurface, backdrop)
  if not frame then return end

  variant = variant or "card"

  -- A frame built without "BackdropTemplate" has no SetBackdrop on retail.
  -- Retrofit the mixin rather than skipping: a silent skip here leaves the
  -- frame tagged for the host skins but bare on a stock UI, which is
  -- invisible on the developer's own (skinned) setup -- exactly how the
  -- options panel's cards shipped without backgrounds.
  if type(frame.SetBackdrop) ~= "function"
    and type(Mixin) == "function" and type(BackdropTemplateMixin) == "table" then
    Mixin(frame, BackdropTemplateMixin)
    if type(frame.OnBackdropSizeChanged) == "function" then
      frame:HookScript("OnSizeChanged", frame.OnBackdropSizeChanged)
    end
  end

  if type(frame.SetBackdrop) == "function" and not backdropApplied[frame] then
    backdropApplied[frame] = true
    frame:SetBackdrop(backdrop or DEFAULT_BACKDROP)
  end

  if theme and theme.ApplyBackdropTheme then
    theme.ApplyBackdropTheme(frame, variant)
  end

  -- ApplyBackdropTheme already owns the surface for the variants that have
  -- one; this covers a caller that asks for it explicitly on one that does not.
  if withSurface and theme and theme.ApplySurfaceTexture then
    theme.ApplySurfaceTexture(frame, variant)
  end
end
