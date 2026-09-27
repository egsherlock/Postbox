local _, ns = ...

-------------------------------------------------------------
-- Postbox :: the arrange mode.
--
-- A mail row's columns -- the read mark, the item's icon, the sender, the
-- subject, the time left, the gold, the slots -- in the player's own order,
-- each shown or hidden, arranged right where the rows are. A small grip
-- beside the options cog opens it (and the same grip in Mail Memory's title
-- bar); a strip of chips then stands over the list, one chip per column in
-- the row's order, the subject stretched across the middle as the subject is
-- in the row. Drag a chip and the others slide aside, the rows re-laying
-- under it as it crosses them; let go and it snaps into its slot. Click a
-- chip for its own card: show or hide the column, and the gold's and the
-- time left's own choices. The category buttons under the list take the same
-- drag and a click to hide or show while the mode is open. Done, the grip
-- again, Escape, or the window going away all end it.
--
-- One arrangement for every list that draws mail rows: it is stored by
-- MailboxUI.GetRowLayout / SetRowLayout, and drawn by CollectTab's RV.Place,
-- which the Mail tab, its History and Mail Memory all go through. This file
-- owns only the mode: the strip, the card, the drag, the grip, Escape.
--
-- A drag is a gesture, not a state: its OnUpdate runs from the press to the
-- release and clears itself, with GLOBAL_MOUSE_UP as the net for a release
-- anywhere else. Nothing here runs while the mode is closed.
-------------------------------------------------------------

ns.Arrange = ns.Arrange or {}
local AR = ns.Arrange

local WHITE = "Interface\\AddOns\\Postbox\\Media\\white8x8.tga"
local ROUND_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
-- A generic item for the icon column's chip: the chip shows what the column
-- shows.
local ICON_SAMPLE = "Interface\\Icons\\INV_Misc_Bag_10"

-- Cross-module dependencies are resolved at call time, never at file scope.
local function L() return ns.L end
local function Th() return ns.Theme end
local function UI() return ns.MailboxUI end

-- The columns, in the words the strip and the card use. `glyph` chips show
-- what the column draws rather than a word; `fixed` is the subject, which
-- takes whatever room the others leave and so cannot be hidden; `choice` is
-- the column's own setting.
AR.COLUMNS = {
  read    = { title = "COL_READ",       desc = "COL_READ_DESC",       glyph = "dot" },
  icon    = { title = "COL_ICON",       desc = "COL_ICON_DESC",       glyph = "icon" },
  sender  = { title = "COL_SENDER",     desc = "COL_SENDER_DESC" },
  subject = { title = "COL_SUBJECT",    desc = "COL_SUBJECT_DESC",    fixed = true },
  time    = { title = "OPT_ROW_EXPIRY", desc = "OPT_ROW_EXPIRY_DESC", choice = "expiry" },
  money   = { title = "OPT_ROW_GOLD",   desc = "OPT_ROW_GOLD_DESC",   choice = "gold" },
  slots   = { title = "OPT_ROW_SLOTS",  desc = "OPT_ROW_SLOTS_DESC" },
}

-- The chips' geometry: a grip, the caption or glyph, and air either side.
local CHIP_GAP = 4
local CHIP_LEAD = 15   -- the grip and the space after it
local CHIP_TAIL = 7
local GLYPH = 14

-- Who is arranging (a host, below), and what the rows' wash points at.
AR.host = nil
AR.hover = nil
AR.focus = nil
AR.drag = nil

-------------------------------------------------------------
-- 1. The arrangement, read and written
-------------------------------------------------------------

function AR.Layout()
  local ui = UI()
  return ui and type(ui.GetRowLayout) == "function" and ui.GetRowLayout() or nil
end

-- A copy the caller may change, for SetRowLayout.
local function CopyLayout()
  local layout, out = AR.Layout() or {}, {}
  for i = 1, #layout do out[i] = { id = layout[i].id, shown = layout[i].shown } end
  return out
end

local function IndexOf(list, id)
  for i = 1, #list do
    if list[i].id == id then return i end
  end
  return nil
end

function AR.MoveColumn(from, to)
  local list = CopyLayout()
  local entry = table.remove(list, from)
  if not entry then return end
  table.insert(list, math.max(1, math.min(to, #list + 1)), entry)
  UI().SetRowLayout(list)
end

function AR.SetColumnShown(id, on)
  local list = CopyLayout()
  local i = IndexOf(list, id)
  if not i or AR.COLUMNS[id].fixed then return end
  list[i].shown = on and true or false
  UI().SetRowLayout(list)
end

-- Both windows' lists, drawn again: `full` after the arrangement changed
-- (a column's width is measured only while it is shown), a re-bind where
-- they are when only the pointer moved.
function AR.RowsChanged(full)
  local collect, memory = ns.CollectTab, ns.MailMemory
  local panel = AR.MailPanel()
  if panel and collect then
    if full and collect.RefreshMailList then
      collect.RefreshMailList(panel)
    elseif collect.RebindRows then
      collect.RebindRows(panel)
    end
  end
  if memory then
    if full and memory.Refresh then
      memory.Refresh()
    elseif memory.Rebind then
      memory.Rebind()
    end
  end
end

function AR.MailPanel()
  local ui = UI()
  local frame = ui and ui._frame
  return frame and frame.Tabs and frame.Tabs.collect or nil
end

-- The category grid, laid out again after its arrangement changed.
function AR.GridChanged()
  local collect, panel = ns.CollectTab, AR.MailPanel()
  if collect and panel and collect.RefreshCategoryButtons then collect.RefreshCategoryButtons(panel) end
end

-- Right-click on the grip while arranging: the rows and the buttons as they
-- come, with the gold's and the time left's own defaults.
function AR.Reset()
  local ui = UI()
  if not ui then return end
  if ui.SetRowLayout then ui.SetRowLayout(nil) end
  if ui.SetGoldMode then ui.SetGoldMode("both") end
  if ui.SetExpiryWhen then ui.SetExpiryWhen("3") end
  if ui.SetGridLayout then ui.SetGridLayout(nil) end
  if AR._pop then AR._pop:Hide() end
  if AR.host then AR.LayoutStrip(AR.host) end
  AR.RowsChanged(true)
  AR.GridChanged()
end

-- The column the rows wash: the one being dragged, else the one under the
-- cursor, else the one whose card is open. Only while the mode is open.
function AR.Focus()
  if not AR.host then return nil end
  return AR.focus
end

function AR.UpdateFocus()
  local pop = AR._pop
  local focus = (AR.drag and AR.drag.chip.colId) or AR.hover
    or (pop and pop:IsShown() and pop.chip and pop.chip.colId) or nil
  if not AR.host then focus = nil end
  if focus == AR.focus then return end
  AR.focus = focus
  AR.RowsChanged(false)
end

function AR.IsActive(owner)
  return AR.host ~= nil and AR.host.owner == owner
end

-------------------------------------------------------------
-- 2. The press
--
-- One press in flight at a time, for the chips and the category buttons
-- alike. A press that moves four units is a drag: start(x0, y0) once, then
-- move(x, y) every frame; its release is drop(). A press that never moved is
-- a click(). Coordinates are in the pressed frame's own scale.
-------------------------------------------------------------

local gesture = {}
local driver

function AR.Cursor(frame)
  local x, y = GetCursorPosition()
  local scale = frame and frame:GetEffectiveScale() or 1
  if type(scale) ~= "number" or scale <= 0 then scale = 1 end
  return (x or 0) / scale, (y or 0) / scale
end

local function EndGesture(released)
  if not gesture.frame then return end
  local handlers, dragging = gesture.handlers, gesture.dragging
  gesture.frame, gesture.handlers, gesture.dragging = nil, nil, false
  if driver then
    driver:SetScript("OnUpdate", nil)
    driver:UnregisterEvent("GLOBAL_MOUSE_UP")
  end
  if not released then return end
  if dragging then
    if handlers.drop then handlers.drop() end
  elseif handlers.click then
    handlers.click()
  end
end

local function OnGestureUpdate()
  local frame = gesture.frame
  if not frame then return end
  -- The button came up where no event of ours heard it.
  if type(IsMouseButtonDown) == "function" and not IsMouseButtonDown("LeftButton") then
    EndGesture(true)
    return
  end
  local x, y = AR.Cursor(frame)
  if not gesture.dragging then
    local dx, dy = x - gesture.x0, y - gesture.y0
    if dx * dx + dy * dy < 16 then return end
    gesture.dragging = true
    if gesture.handlers.start then gesture.handlers.start(gesture.x0, gesture.y0) end
    -- The start may have ended the mode.
    if not gesture.frame then return end
  end
  if gesture.handlers.move then gesture.handlers.move(x, y) end
end

function AR.Press(frame, handlers)
  EndGesture(false)
  if not driver then
    driver = CreateFrame("Frame")
    driver:SetScript("OnEvent", function(_, _, button)
      if button == nil or button == "LeftButton" then EndGesture(true) end
    end)
  end
  gesture.frame, gesture.handlers, gesture.dragging = frame, handlers, false
  gesture.x0, gesture.y0 = AR.Cursor(frame)
  driver:RegisterEvent("GLOBAL_MOUSE_UP")
  driver:SetScript("OnUpdate", OnGestureUpdate)
end

-- Ends a press without its release: the mode is closing under it.
function AR.CancelPress()
  EndGesture(false)
end

-------------------------------------------------------------
-- 3. Parts
-------------------------------------------------------------

-- The grip: two columns of three dots, the sign for "this moves". The title
-- bar's button and every chip wear it. Round where the dots are big enough
-- for a mask to show.
function AR.Grip(parent, dot, step)
  local holder = CreateFrame("Frame", nil, parent)
  holder:SetSize(2 * dot + step, 3 * dot + 2 * step)
  holder.dots = {}
  for r = 0, 2 do
    for c = 0, 1 do
      local t = holder:CreateTexture(nil, "ARTWORK")
      t:SetTexture(WHITE)
      t:SetSize(dot, dot)
      t:SetPoint("TOPLEFT", holder, "TOPLEFT", c * (dot + step), -r * (dot + step))
      if dot >= 4 and type(holder.CreateMaskTexture) == "function" then
        local mask = holder:CreateMaskTexture()
        mask:SetTexture(ROUND_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(t)
        t:AddMaskTexture(mask)
      end
      holder.dots[#holder.dots + 1] = t
    end
  end
  return holder
end

function AR.TintGrip(grip, token, accent)
  local T = Th()
  for i = 1, #grip.dots do
    local dot = grip.dots[i]
    if accent then
      local r, g, b = T.GetAccent()
      dot:SetVertexColor(r, g, b, 1)
    else
      T.SetColor(dot, token)
    end
  end
end

-- Where a dragged chip or button will land: its slot, ringed and washed in
-- the accent. The one accent the mode draws besides the thing in the hand.
function AR.NewGhost(parent)
  local ghost = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  ghost:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
  ghost:Hide()
  return ghost
end

function AR.PaintGhost(ghost)
  local r, g, b = Th().GetAccent()
  ghost:SetBackdropColor(r, g, b, 0.12)
  ghost:SetBackdropBorderColor(r, g, b, 0.9)
end

-------------------------------------------------------------
-- 4. The grip in the title bar
--
-- Beside the cog, the cog's size, drawn rather than borrowed: six dots, in
-- the chrome's grey, lit in the accent while the mode is open. `place`
-- anchors it; `getHost` answers which list it arranges, and may bring that
-- list forward first.
-------------------------------------------------------------

function AR.PaintToggle(button)
  if not button then return end
  local active = AR.host ~= nil and AR.host.toggle == button
  AR.TintGrip(button.grip, button.hover and "textPrimary" or "textSecondary", active)
end

local function ToggleTip(button)
  GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
  GameTooltip:SetText(L()["ARRANGE_TITLE"])
  GameTooltip:AddLine(L()["ARRANGE_TIP"], 1, 1, 1, true)
  if AR.host and AR.host.toggle == button then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L()["ARRANGE_TIP_ACTIVE"], 0.7, 0.7, 0.7, true)
    GameTooltip:AddLine(L()["ARRANGE_TIP_RESET"], 0.7, 0.7, 0.7, true)
  end
  GameTooltip:Show()
end

function AR.BuildToggle(parent, place, getHost)
  local button = CreateFrame("Button", nil, parent)
  button:SetSize(18, 18)
  place(button)
  button:SetFrameLevel(parent:GetFrameLevel() + 20)
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button.grip = AR.Grip(button, 4, 3)
  button.grip:SetPoint("CENTER")
  button.getHost = getHost
  button:SetScript("OnEnter", function(self)
    self.hover = true
    AR.PaintToggle(self)
    ToggleTip(self)
  end)
  button:SetScript("OnLeave", function(self)
    self.hover = false
    AR.PaintToggle(self)
    GameTooltip:Hide()
  end)
  button:SetScript("OnClick", function(self, mouse)
    local active = AR.host ~= nil and AR.host.toggle == self
    if mouse == "RightButton" then
      if active then AR.Reset() end
      return
    end
    if active then
      AR.Leave()
    else
      local host = self.getHost and self.getHost()
      if not host then return end
      host.toggle = self
      AR.Enter(host)
    end
    -- The tooltip says what the next click does.
    if GameTooltip:IsOwned(self) then ToggleTip(self) end
  end)
  AR.PaintToggle(button)
  return button
end

-------------------------------------------------------------
-- 5. Escape
--
-- Escape closes the mode, not the window under it -- and never the mailbox.
-- The client closes windows on Escape by hiding every shown frame named in
-- UISpecialFrames; while the mode is open the Postbox windows' names there
-- are swapped IN PLACE for a small frame of ours, and that frame hiding is
-- what ends the mode. In place, so no other entry shifts. The swap is undone
-- on the way out, however the mode ends.
-------------------------------------------------------------

AR.ESC_WINDOWS = { PostboxFrame = true, PostboxMailMemoryFrame = true }
local ESC_NAME = "PostboxArrangeEscape"

function AR.CatchEscape(on)
  local list = UISpecialFrames
  if type(list) ~= "table" then return end
  local catcher = AR._esc
  if not catcher then
    catcher = CreateFrame("Frame", ESC_NAME, UIParent)
    catcher:SetSize(1, 1)
    catcher:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    catcher:EnableMouse(false)
    catcher:Hide()
    catcher:SetScript("OnHide", function(self)
      if not self.armed then return end
      self.armed = false
      -- Hidden by the client's close-windows pass on an Escape: left a frame
      -- later, off that path, as the window's own close is (COMBAT_TAINT.md).
      C_Timer.After(0, function() AR.Leave() end)
    end)
    AR._esc = catcher
  end
  if on then
    local taken = {}
    for i = 1, #list do
      if AR.ESC_WINDOWS[list[i]] then
        taken[i] = list[i]
        list[i] = ESC_NAME
      end
    end
    -- No window of ours listed (its name registers on first open): the
    -- catcher still has to be heard.
    if not next(taken) then
      list[#list + 1] = ESC_NAME
      taken.appended = #list
    end
    AR._escTaken = taken
    catcher.armed = true
    catcher:Show()
  else
    catcher.armed = false
    catcher:Hide()
    local taken = AR._escTaken
    AR._escTaken = nil
    if not taken then return end
    for i, name in pairs(taken) do
      if type(i) == "number" and list[i] == ESC_NAME then list[i] = name end
    end
    if taken.appended and list[taken.appended] == ESC_NAME then
      table.remove(list, taken.appended)
    end
    -- Anything still pointing at the catcher, whatever moved it; and every
    -- window name back, wherever the list now has room for it.
    for i = #list, 1, -1 do
      if list[i] == ESC_NAME then table.remove(list, i) end
    end
    for i, name in pairs(taken) do
      if type(i) == "number" then
        local present = false
        for j = 1, #list do
          if list[j] == name then present = true break end
        end
        if not present then list[#list + 1] = name end
      end
    end
  end
end

-------------------------------------------------------------
-- 6. The how-to
--
-- Three short lines under the strip the first time the mode opens, gone at
-- the first press on a chip or a button, and not shown again once one has
-- been pressed (MailboxUI option `arrangeTaught`).
-------------------------------------------------------------

function AR.Teach(host)
  local ui = UI()
  if not ui or (ui.GetOption and ui.GetOption("arrangeTaught")) then return end
  C_Timer.After(0, function()
    if AR.host ~= host or not host.strip or not host.strip:IsVisible() then return end
    local T = Th()
    if not (T and T.ShowHint) then return end
    T.ShowHint(host.strip, { L()["ARRANGE_HOW_DRAG"], L()["ARRANGE_HOW_CLICK"], L()["ARRANGE_HOW_DONE"] },
      { "TOP", host.strip, "BOTTOM", 0, -10 })
    AR._teaching = true
  end)
end

function AR.EndTeach(learned)
  if AR._teaching then
    AR._teaching = false
    local T = Th()
    if T and T.HideHint then T.HideHint() end
  end
  local ui = UI()
  if learned and ui and ui.SetOption then ui.SetOption("arrangeTaught", true) end
end

-------------------------------------------------------------
-- 7. The strip
--
-- A row of chips, one per column, in the row's order: a grip and the
-- column's name (or, for the read mark and the icon, what the column draws).
-- The subject's chip stretches across what the others leave, as the subject
-- does in the row, so the strip reads as the row it arranges. A hidden
-- column's chip keeps its place, struck through and greyed: showing it again
-- puts it back where it was. Done stands at the end.
-------------------------------------------------------------

local function ChipTip(chip)
  if AR.drag then return end
  local pop = AR._pop
  if pop and pop:IsShown() and pop.chip == chip then return end
  GameTooltip:SetOwner(chip, "ANCHOR_TOP")
  GameTooltip:SetText(L()[AR.COLUMNS[chip.colId].title])
  GameTooltip:Show()
end

-- The chip's look after every repaint the plate makes of itself: selected
-- while in the hand or while its card is open; struck and greyed while its
-- column is hidden.
function AR.PaintChip(chip)
  local T = Th()
  local pop = AR._pop
  local selected = (AR.drag ~= nil and AR.drag.chip == chip)
    or (pop ~= nil and pop:IsShown() and pop.chip == chip)
  T.SetPlateSelected(chip, selected)
  local hidden = chip.hidden
  if chip.caption and hidden then T.SetColor(chip.Text, "textDisabled") end
  if chip.Glyph then
    if chip.glyphKind == "dot" then
      T.SetColor(chip.Glyph, hidden and "textDisabled" or "unread")
    else
      chip.Glyph:SetDesaturated(hidden and true or false)
      chip.Glyph:SetAlpha(hidden and 0.55 or 1)
    end
  end
  chip.Strike:SetShown(hidden and true or false)
  local lit = selected or chip.__pbHover
  AR.TintGrip(chip.grip, lit and "textPrimary" or "textSecondary")
end

local function BuildChip(strip, host, id)
  local T = Th()
  local spec = AR.COLUMNS[id]
  local chip = T.CreatePlate(strip, "tile")
  chip.colId = id
  chip:SetHeight(T.Metrics.tileHeight)

  chip.grip = AR.Grip(chip, 2, 2)
  chip.grip:SetPoint("LEFT", chip, "LEFT", 5, 0)

  if spec.glyph then
    chip:SetText("")
    chip.Glyph = chip:CreateTexture(nil, "OVERLAY")
    chip.glyphKind = spec.glyph
    if spec.glyph == "dot" then
      local size = (ns.CollectTab and ns.CollectTab.RowRules and ns.CollectTab.RowRules.DOT or 8) - 1
      chip.Glyph:SetSize(size, size)
      chip.Glyph:SetTexture(WHITE)
      if type(chip.CreateMaskTexture) == "function" then
        local mask = chip:CreateMaskTexture()
        mask:SetTexture(ROUND_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(chip.Glyph)
        chip.Glyph:AddMaskTexture(mask)
      end
      chip.glyphW = GLYPH
      chip.Glyph:SetPoint("CENTER", chip, "LEFT", CHIP_LEAD + GLYPH / 2, 0)
    else
      chip.Glyph:SetSize(GLYPH, GLYPH)
      chip.Glyph:SetTexture(ICON_SAMPLE)
      chip.Glyph:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      chip.glyphW = GLYPH
      chip.Glyph:SetPoint("LEFT", chip, "LEFT", CHIP_LEAD, 0)
    end
  else
    chip.caption = L()[spec.title]
    chip:SetText(chip.caption)
    chip.Text:ClearAllPoints()
    chip.Text:SetPoint("LEFT", chip, "LEFT", CHIP_LEAD, 0)
    chip.Text:SetJustifyH("LEFT")
  end

  -- Struck through while the column is hidden.
  chip.Strike = chip:CreateTexture(nil, "OVERLAY", nil, 2)
  chip.Strike:SetTexture(WHITE)
  chip.Strike:SetHeight(1)
  chip.Strike:SetPoint("LEFT", chip, "LEFT", CHIP_LEAD - 2, 0)
  chip.Strike:SetPoint("RIGHT", chip, "RIGHT", -(CHIP_TAIL - 2), 0)
  T.SetColor(chip.Strike, "textSecondary")
  chip.Strike:Hide()

  -- After the plate's own hover repaint, so the hidden look survives it.
  chip:HookScript("OnEnter", function(self)
    AR.hover = self.colId
    AR.PaintChip(self)
    AR.UpdateFocus()
    ChipTip(self)
  end)
  chip:HookScript("OnLeave", function(self)
    if AR.hover == self.colId then AR.hover = nil end
    AR.PaintChip(self)
    AR.UpdateFocus()
    GameTooltip:Hide()
  end)
  chip:SetScript("OnMouseDown", function(self, button)
    if button ~= "LeftButton" then return end
    AR.PressChip(host, self)
  end)
  return chip
end

function AR.BuildStrip(host)
  local T = Th()
  local strip = CreateFrame("Frame", nil, host.owner)
  strip:SetHeight(T.Metrics.tileHeight)
  host.PlaceStrip(strip)
  strip:Hide()
  strip.chips = {}
  for id in pairs(AR.COLUMNS) do strip.chips[id] = BuildChip(strip, host, id) end

  local done = T.CreateButton(nil, strip)
  done:SetText(L()["ARRANGE_DONE"])
  done:SetHeight(T.Metrics.tileHeight)
  done:SetWidth(math.max(math.ceil(T.TextWidth(done)) + 24, 56))
  done:SetPoint("RIGHT", strip, "RIGHT", 0, 0)
  done:SetScript("OnClick", function() AR.Leave() end)
  done:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L()["ARRANGE_DONE"])
    GameTooltip:AddLine(L()["ARRANGE_DONE_TIP"], 1, 1, 1, true)
    GameTooltip:Show()
  end)
  done:SetScript("OnLeave", function() GameTooltip:Hide() end)
  strip.Done = done

  strip.Ghost = AR.NewGhost(strip)
  strip:SetScript("OnSizeChanged", function()
    if AR.host == host then AR.LayoutStrip(host) end
  end)
  host.strip = strip
  -- The Done button wears the host UI's button look, as every push button
  -- in the window does; the chips are Postbox's own plates, as the view
  -- switch beside them is.
  if ns.Skin and ns.Skin.Refresh then pcall(ns.Skin.Refresh, strip) end
  return strip
end

-- A chip's width with nothing cut: the grip, the name or glyph, and air.
local function Natural(chip)
  if chip.Glyph then return CHIP_LEAD + chip.glyphW + CHIP_TAIL end
  chip.Text:SetWidth(0)
  chip.Text:SetText(chip.caption)
  return CHIP_LEAD + math.ceil(chip.Text:GetStringWidth() or 0) + CHIP_TAIL
end

-- Lays the chips out in the arrangement's order. The chip in the hand is
-- left where the cursor holds it and its slot takes the ghost; the others
-- stand in theirs. Where the strip is short the names give up room in
-- proportion (cut, with the whole name on hover); where it is long the
-- subject takes the rest.
function AR.LayoutStrip(host)
  local strip = host and host.strip
  local layout = AR.Layout()
  if not (strip and layout) then return end
  local T = Th()
  local width = strip:GetWidth() or 0
  if width < 60 then return end
  local avail = width - (strip.Done:GetWidth() or 0) - 8
  strip._avail = avail

  local total, flexible = CHIP_GAP * (#layout - 1), 0
  for i = 1, #layout do
    local chip = strip.chips[layout[i].id]
    chip._nat = Natural(chip)
    total = total + chip._nat
    if not chip.Glyph then flexible = flexible + chip._nat - CHIP_LEAD - CHIP_TAIL end
  end
  local spare = avail - total
  local scale = 1
  if spare < 0 and flexible > 0 then scale = math.max(0.25, (flexible + spare) / flexible) end

  local drag = AR.drag
  local x = 0
  for i = 1, #layout do
    local entry = layout[i]
    local chip = strip.chips[entry.id]
    local w = chip._nat
    if spare < 0 and not chip.Glyph then
      w = CHIP_LEAD + CHIP_TAIL + math.floor((chip._nat - CHIP_LEAD - CHIP_TAIL) * scale)
    elseif spare > 0 and entry.id == "subject" then
      w = w + spare
    end
    chip:SetWidth(w)
    chip._x, chip._w = x, w
    if drag and drag.chip == chip then
      local ghost = strip.Ghost
      ghost:ClearAllPoints()
      ghost:SetPoint("LEFT", strip, "LEFT", x, 0)
      ghost:SetSize(w, T.Metrics.tileHeight)
      AR.PaintGhost(ghost)
      ghost:Show()
    else
      chip:ClearAllPoints()
      chip:SetPoint("LEFT", strip, "LEFT", x, 0)
    end
    if chip.caption then T.FitText(chip.Text, w - CHIP_LEAD - CHIP_TAIL + 2, chip.caption, chip) end
    chip.hidden = not entry.shown
    chip:Show()
    AR.PaintChip(chip)
    x = x + w + CHIP_GAP
  end
  if not drag then strip.Ghost:Hide() end
end

-------------------------------------------------------------
-- 8. Dragging a chip
-------------------------------------------------------------

function AR.PressChip(host, chip)
  AR.EndTeach(true)
  AR.Press(chip, {
    start = function(x0)
      if AR.host ~= host then return end
      if AR._pop then AR._pop:Hide() end
      GameTooltip:Hide()
      AR.drag = { chip = chip, grab = x0 - (chip:GetLeft() or x0), level = chip:GetFrameLevel() }
      chip:SetFrameLevel(host.strip:GetFrameLevel() + 20)
      AR.LayoutStrip(host)
      AR.UpdateFocus()
    end,
    move = function(x) AR.DragChip(host, x) end,
    drop = function() AR.DropChip(host) end,
    click = function()
      if AR.host == host then AR.TogglePopover(host, chip) end
    end,
  })
end

-- The chip follows the cursor along the strip. Past the middle of the chip
-- beside it, the two change places -- in the arrangement itself, so the rows
-- under the strip follow as it goes.
function AR.DragChip(host, cursorX)
  local drag, strip = AR.drag, host.strip
  if not (drag and strip) then return end
  local chip = drag.chip
  local left = strip:GetLeft()
  if not left then return end
  local x = math.min(math.max(cursorX - left - drag.grab, 0), math.max((strip._avail or 0) - chip._w, 0))
  chip:ClearAllPoints()
  chip:SetPoint("LEFT", strip, "LEFT", x, 0)
  local centre = x + chip._w / 2
  local moved = false
  -- A quick hand can cross more than one chip in a frame.
  for _ = 1, 8 do
    local layout = AR.Layout()
    local k = IndexOf(layout, chip.colId)
    if not k then break end
    local target
    local prev, nxt = layout[k - 1], layout[k + 1]
    if prev then
      local p = strip.chips[prev.id]
      if centre < p._x + p._w / 2 then target = k - 1 end
    end
    if not target and nxt then
      local q = strip.chips[nxt.id]
      if centre > q._x + q._w / 2 then target = k + 1 end
    end
    if not target then break end
    AR.MoveColumn(k, target)
    AR.LayoutStrip(host)
    moved = true
  end
  if moved then AR.RowsChanged(true) end
end

function AR.DropChip(host)
  local drag = AR.drag
  AR.drag = nil
  if not drag then return end
  drag.chip:SetFrameLevel(drag.level)
  if host.strip then
    host.strip.Ghost:Hide()
    AR.LayoutStrip(host)
  end
  AR.hover = drag.chip:IsMouseOver() and drag.chip.colId or nil
  AR.UpdateFocus()
end

-------------------------------------------------------------
-- 9. A column's card
--
-- Opened by a click on its chip, under it: the column's name and what it
-- shows, Show, and -- for the gold and the time left -- its own choice,
-- which stands greyed while the column is hidden. Closes on a click
-- anywhere else (no full-screen catcher: one swallowed the row clicks
-- once), on a second click on the chip, and with the mode.
-------------------------------------------------------------

local CARD_W, CARD_PAD, CHOICE_H = 236, 10, 20

function AR.Choices(kind)
  local ui = UI()
  if not ui then return {}, nil, nil end
  if kind == "gold" then
    return {
      { id = "both",   name = L()["OPT_GOLD_BOTH"] },
      { id = "earned", name = L()["OPT_GOLD_EARNED"] },
      { id = "spent",  name = L()["OPT_GOLD_SPENT"] },
    }, ui.GetGoldMode and ui.GetGoldMode(), ui.SetGoldMode
  elseif kind == "expiry" then
    return {
      { id = "always", name = L()["OPT_EXPIRY_ALWAYS"] },
      { id = "7", name = ns.Plural("OPT_EXPIRY_UNDER", 7) },
      { id = "3", name = ns.Plural("OPT_EXPIRY_UNDER", 3) },
      { id = "1", name = ns.Plural("OPT_EXPIRY_UNDER", 1) },
    }, ui.GetExpiryWhen and ui.GetExpiryWhen(), ui.SetExpiryWhen
  end
  return {}, nil, nil
end

local function ChoiceRow(pop, i)
  local T = Th()
  local row = CreateFrame("Button", nil, pop)
  row:SetHeight(CHOICE_H)
  row:RegisterForClicks("LeftButtonUp")
  row.Hover = row:CreateTexture(nil, "BACKGROUND")
  row.Hover:SetAllPoints()
  row.Hover:SetColorTexture(1, 1, 1, 0.06)
  row.Hover:Hide()
  -- The chosen one's mark: a small accent dot, as the select lists have.
  row.Mark = row:CreateTexture(nil, "ARTWORK")
  row.Mark:SetSize(4, 4)
  row.Mark:SetPoint("LEFT", row, "LEFT", 6, 0)
  row.Mark:SetTexture(WHITE)
  row.Text = T.CreateText(row, "value")
  row.Text:SetPoint("LEFT", row, "LEFT", 16, 0)
  row.Text:SetJustifyH("LEFT")
  row.Text:SetWordWrap(false)
  row:SetScript("OnEnter", function(self) if self.enabled then self.Hover:Show() end end)
  row:SetScript("OnLeave", function(self) self.Hover:Hide() end)
  row:SetScript("OnClick", function(self)
    if not self.enabled or not pop.set then return end
    pop.set(self.choiceId)
    AR.RowsChanged(true)
    AR.FillPopover(pop)
  end)
  pop.rows[i] = row
  return row
end

function AR.BuildPopover()
  local T = Th()
  local pop = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  pop.__pbPopupAlways = true
  T.ApplyCard(pop)
  pop:SetFrameStrata("FULLSCREEN_DIALOG")
  pop:SetClampedToScreen(true)
  pop:EnableMouse(true)
  pop.rows = {}

  pop.Title = T.CreateText(pop, "label")
  pop.Title:SetJustifyH("LEFT")
  pop.Title:SetWordWrap(false)
  pop.Desc = T.CreateText(pop, "secondary")
  pop.Desc:SetJustifyH("LEFT")
  pop.Desc:SetWordWrap(true)

  local show = CreateFrame("CheckButton", nil, pop, "UICheckButtonTemplate")
  show:SetSize(20, 20)
  show.__postboxCheck = true
  local label = T.CreateText(pop, "label")
  label:SetPoint("LEFT", show, "RIGHT", 4, 0)
  label:SetText(L()["COL_SHOW"])
  show.__label = label
  show:SetScript("OnClick", function(self)
    local chip = pop.chip
    if not chip then return end
    local on = self:GetChecked() and true or false
    AR.SetColumnShown(chip.colId, on)
    if pop.host then AR.LayoutStrip(pop.host) end
    AR.RowsChanged(true)
    AR.FillPopover(pop)
    if type(SOUNDKIT) == "table" then
      PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
    end
  end)
  pop.ShowCheck = show
  pop.ShowLabel = label

  -- Closes on a click anywhere but itself and its chip, whose own click
  -- toggles it.
  pop:SetScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
  pop:SetScript("OnHide", function(self)
    self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    local chip = self.chip
    if chip then AR.PaintChip(chip) end
    AR.UpdateFocus()
  end)
  pop:SetScript("OnEvent", function(self)
    if self:IsMouseOver() or (self.chip and self.chip:IsMouseOver()) then return end
    self:Hide()
  end)
  -- A new frame starts shown: hidden now, so the first Show fires OnShow.
  pop:Hide()
  if ns.Skin and ns.Skin.Refresh then pcall(ns.Skin.Refresh, pop) end
  AR._pop = pop
  return pop
end

function AR.FillPopover(pop)
  local T = Th()
  local chip = pop.chip
  if not chip then return end
  local id = chip.colId
  local spec = AR.COLUMNS[id]
  local layout = AR.Layout()
  local shown = layout and layout.shown[id] or false
  local inner = CARD_W - 2 * CARD_PAD
  local y = -CARD_PAD

  pop.Title:ClearAllPoints()
  pop.Title:SetPoint("TOPLEFT", pop, "TOPLEFT", CARD_PAD, y)
  pop.Title:SetWidth(inner)
  pop.Title:SetText(L()[spec.title])
  y = y - math.ceil(pop.Title:GetStringHeight() or 12) - 4

  pop.Desc:ClearAllPoints()
  pop.Desc:SetPoint("TOPLEFT", pop, "TOPLEFT", CARD_PAD, y)
  pop.Desc:SetWidth(inner)
  pop.Desc:SetText(L()[spec.desc])
  y = y - math.ceil(pop.Desc:GetStringHeight() or 12) - 8

  local check = pop.ShowCheck
  if spec.fixed then
    check:Hide()
    pop.ShowLabel:Hide()
  else
    check:ClearAllPoints()
    check:SetPoint("TOPLEFT", pop, "TOPLEFT", CARD_PAD - 4, y)
    check:SetChecked(shown)
    check:Show()
    pop.ShowLabel:Show()
    y = y - 24
  end

  local choices, current, set = AR.Choices(spec.choice)
  pop.set = set
  local r, g, b = T.GetAccent()
  for i = 1, math.max(#choices, #pop.rows) do
    local choice = choices[i]
    local row = pop.rows[i]
    if choice then
      row = row or ChoiceRow(pop, i)
      row.choiceId = choice.id
      row.enabled = shown
      row.Text:SetText(choice.name)
      T.SetColor(row.Text, shown and "textPrimary" or "textDisabled")
      row.Mark:SetVertexColor(r, g, b, shown and 0.9 or 0.35)
      row.Mark:SetShown(choice.id == current)
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", pop, "TOPLEFT", 4, y)
      row:SetPoint("RIGHT", pop, "RIGHT", -4, 0)
      row:Show()
      y = y - CHOICE_H
    elseif row then
      row:Hide()
    end
  end
  pop:SetSize(CARD_W, -y + CARD_PAD - 2)
end

function AR.TogglePopover(host, chip)
  local pop = AR._pop
  if pop and pop:IsShown() and pop.chip == chip then
    pop:Hide()
    return
  end
  pop = pop or AR.BuildPopover()
  local previous = pop:IsShown() and pop.chip or nil
  pop.chip, pop.host = chip, host
  GameTooltip:Hide()
  AR.FillPopover(pop)
  pop:ClearAllPoints()
  pop:SetPoint("TOPLEFT", chip, "BOTTOMLEFT", 0, -4)
  pop:Show()
  pop:Raise()
  if previous and previous ~= chip then AR.PaintChip(previous) end
  AR.PaintChip(chip)
  AR.UpdateFocus()
end

-------------------------------------------------------------
-- 10. Opening and closing
--
-- A host is the list being arranged: { owner = its frame, PlaceStrip(strip),
-- OnEnter(strip), OnLeave(), toggle = the grip that opened it }. The Mail
-- tab's is CollectTab's CT.ArrangeHost; Mail Memory's is its own. One at a
-- time: opening one closes the other.
-------------------------------------------------------------

function AR.Enter(host)
  if not host or AR.host == host then return end
  if AR.host then AR.Leave() end
  local strip = host.strip or AR.BuildStrip(host)
  AR.host = host
  AR.hover, AR.focus, AR.drag = nil, nil, nil
  strip:Show()
  if host.OnEnter then host.OnEnter(strip) end
  AR.LayoutStrip(host)
  AR.CatchEscape(true)
  if host.toggle then AR.PaintToggle(host.toggle) end
  AR.RowsChanged(false)
  AR.Teach(host)
end

function AR.Leave()
  local host = AR.host
  if not host then return end
  AR.CancelPress()
  local drag = AR.drag
  AR.drag = nil
  if drag then drag.chip:SetFrameLevel(drag.level) end
  AR.host = nil
  if AR._pop then AR._pop:Hide() end
  AR.hover, AR.focus = nil, nil
  AR.EndTeach(false)
  AR.CatchEscape(false)
  if host.strip then
    host.strip.Ghost:Hide()
    host.strip:Hide()
  end
  if host.OnLeave then host.OnLeave() end
  if host.toggle then AR.PaintToggle(host.toggle) end
  AR.RowsChanged(false)
end

-- The mode ends with the frame it was opened over.
function AR.LeaveIf(owner)
  if AR.host and AR.host.owner == owner then AR.Leave() end
end
