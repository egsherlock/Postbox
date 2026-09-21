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

-- Records the frame's centre as an integer offset from the screen centre.
-- Both centres are nil before the first layout pass; bail rather than write
-- garbage.
function Helpers.SaveFramePosition(frame, store)
  if not frame or type(store) ~= "table" then return false end

  local cx, cy = frame:GetCenter()
  if not cx or not cy then return false end

  local ux, uy = UIParent:GetCenter()
  if not ux or not uy then return false end

  store.x = Round(cx - ux)
  store.y = Round(cy - uy)
  return true
end

-- `extraHeight` is transient height the caller layered on top of the size the
-- user actually chose -- the mail window grows to fit a second row of attachment
-- slots, and again to fit a message that has outgrown its box. Subtract it so
-- the persisted height is always the user's base size, whatever the window
-- happens to be showing at the moment the write lands.
local function SaveFrameSize(frame, store, bounds, extraHeight)
  if not frame or type(store) ~= "table" then return false end

  local width, height = frame:GetSize()
  if not width or not height then return false end

  height = height - (tonumber(extraHeight) or 0)
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

  -- Restore size first, then position, then pin immediately — otherwise the
  -- very first layout after login uses a centre anchor and the first resize
  -- drag moves the window.
  if store.width and store.height then
    frame:SetSize(store.width, store.height)
  end

  if store.x and store.y then
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", store.x, store.y)
  end
  Helpers.PinFrameTopLeft(frame)

  -- OnSizeChanged fires on every frame of a resize drag. Writing to saved
  -- variables 60 times a second is pure waste, so coalesce: mark dirty, flush
  -- once shortly after the last change (and immediately on hide).
  local dirty, scheduled = false, false

  local function Flush()
    scheduled = false
    if not dirty then return end
    dirty = false
    SaveFrameSize(frame, store, bounds, ExtraHeight())
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
    Helpers.SaveFramePosition(self, store)
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
  end)

  frame:HookScript("OnHide", function(self)
    Helpers.SaveFramePosition(self, store)
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
  button:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  button:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  button:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")

  local sizing = false

  local function StopSizing()
    button:SetScript("OnUpdate", nil)
    -- Also cancel any engine-driven move in progress (a title-bar drag when the
    -- window is hidden mid-gesture). Harmless otherwise.
    if type(frame.StopMovingOrSizing) == "function" then frame:StopMovingOrSizing() end
    if not sizing then return end
    sizing = false
    if type(onStop) == "function" then onStop(frame) end
  end

  button:SetScript("OnMouseDown", function(self, mouseButton)
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
