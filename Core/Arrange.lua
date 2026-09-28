local _, ns = ...

-------------------------------------------------------------
-- Postbox :: the arrange mode.
--
-- A mail row's columns -- the read mark, the item's icon, the sender, the
-- subject, the time left, the gold, the slots -- in the player's own order,
-- each shown or hidden, arranged right where the rows are. The layout mark
-- beside the options cog opens it (the cog key; the same key stands in Mail
-- Memory's title bar); a strip of chips then stands over the list, one chip
-- per column in the row's order, the subject stretched across the middle as
-- the subject is in the row. Drag a chip and the others slide aside, the
-- rows re-laying under it as it crosses them; let go and it snaps into its
-- slot. Click a chip, or a block under the list, to select it: the
-- inspector docked beside the window shows its card -- show or hide it,
-- its own choices, Move for the no-drag way. With nothing selected the
-- inspector says how the mode works, lists what is hidden and offers the
-- reset. The category buttons under the list take the same drag and a
-- click to hide or show while the mode is open. The key, lit as Done while
-- the mode is open, Escape, or the window going away all end it.
--
-- One arrangement for every list that draws mail rows: it is stored by
-- MailboxUI.GetRowLayout / SetRowLayout, and drawn by CollectTab's RV.Place,
-- which the Mail tab, its History and Mail Memory all go through. This file
-- owns only the mode: the strip, the inspector, the drag, the key, Escape.
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

-- The columns, in the words the strip and the inspector use. `glyph` chips
-- show what the column draws rather than a word; `fixed` is the subject,
-- which takes whatever room the others leave and so cannot be hidden;
-- `choice` is the column's own setting; `figure`, a figure a mail may not
-- have.
AR.COLUMNS = {
  read    = { title = "COL_READ",       desc = "COL_READ_DESC",       glyph = "dot" },
  icon    = { title = "COL_ICON",       desc = "COL_ICON_DESC",       glyph = "icon" },
  sender  = { title = "COL_SENDER",     desc = "COL_SENDER_DESC" },
  subject = { title = "COL_SUBJECT",    desc = "COL_SUBJECT_DESC",    fixed = true },
  time    = { title = "OPT_ROW_EXPIRY", desc = "OPT_ROW_EXPIRY_DESC", choice = "expiry", figure = true },
  money   = { title = "OPT_ROW_GOLD",   desc = "OPT_ROW_GOLD_DESC",   choice = "gold", figure = true },
  slots   = { title = "OPT_ROW_SLOTS",  desc = "OPT_ROW_SLOTS_DESC", figure = true },
}

-- The chips' geometry: the caption or glyph with air either side, and, on a
-- hidden column's chip, its crossed eye before them. The whole chip is the
-- handle: it wears no grip. Tight on purpose: seven chips fit the Mail tab
-- at its narrowest in German, and Mail Memory's window widens for them
-- while it arranges.
local CHIP_GAP = 3
local CHIP_LEAD = 6
local CHIP_TAIL = 6
local CHIP_EYE = 12    -- the crossed eye's width, and the space after it
local CHIP_EYE_GAP = 4
local GLYPH = 14

-- The cog key (section 4): the cog's size at rest; lit, a check and Done on
-- the accent, `KEY_LEAD` in, the check's width and `KEY_GAP`, the word, and
-- `KEY_TAIL` after it.
local KEY_SIZE = 18
local KEY_MARK = 12
local KEY_CHECK = 8
local KEY_LEAD, KEY_GAP, KEY_TAIL = 6, 4, 7
-- The mark's grey at rest: the chrome's quietest text grey, as near as the
-- palette comes to the mockup's #a2a2a2, so the accent cog beside it is the
-- louder of the two at a glance.
local KEY_REST = "textDisabled"

-- Who is arranging (a host, below), and what the rows' wash points at.
AR.host = nil
AR.hover = nil
AR.focus = nil
AR.drag = nil
-- What the inspector shows (section 8): the selected thing, as a kind
-- ("column" or "block") and an id, or nil for the overview; and while
-- something is in the hand, its name.
AR.selKind = nil
AR.selId = nil
AR.moving = nil

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

-- Right-click on the lit key: the rows, the blocks under the list and the
-- buttons as they come, with the gold's and the time left's own defaults.
function AR.Reset()
  local ui = UI()
  if not ui then return end
  if ui.SetRowLayout then ui.SetRowLayout(nil) end
  if ui.SetGoldMode then ui.SetGoldMode("both") end
  if ui.SetExpiryWhen then ui.SetExpiryWhen("3") end
  if ui.SetGridLayout then ui.SetGridLayout(nil) end
  if ui.SetStackOrder then ui.SetStackOrder(nil) end
  -- The grid hidden in the mode is the "Show category buttons" option, so
  -- it comes back with the rest, and the window's floor with it.
  local gridBack = ui.GetOption and ui.SetOption and not ui.GetOption("showCategoryButtons")
  if gridBack then ui.SetOption("showCategoryButtons", true) end
  if AR.host then AR.LayoutStrip(AR.host) end
  AR.RowsChanged(true)
  if gridBack and ui.RefreshCollectCategoryButtons then
    ui.RefreshCollectCategoryButtons()
  else
    AR.GridChanged()
  end
  -- The selection stays: the thing it names is still there, shown.
  AR.Inspect()
end

-- The reset is asked for first: one StaticPopup, its key added on first use
-- and only where the client offers the popup at all -- no popup, no reset.
-- Lifted over the windows it may open from (Theme.LiftPopup). The answer
-- resets whether or not the mode is still open by then: the question was
-- about the arrangement, not the mode.
AR.POPUP_RESET = "POSTBOX_ARRANGE_RESET"

function AR.AskReset()
  if type(StaticPopupDialogs) ~= "table" or type(StaticPopup_Show) ~= "function" then return end
  if not StaticPopupDialogs[AR.POPUP_RESET] then
    StaticPopupDialogs[AR.POPUP_RESET] = {
      text = "%s",
      button1 = L()["BTN_RESET"],
      button2 = L()["COD_CONFIRM_CANCEL"],
      OnAccept = function() AR.Reset() end,
      timeout = 0,
      whileDead = true,
      hideOnEscape = true,
    }
  end
  local dialog = StaticPopup_Show(AR.POPUP_RESET, L()["ARRANGE_RESET_CONFIRM"])
  local T = Th()
  if dialog and T and T.LiftPopup then T.LiftPopup(dialog) end
end

-- The column the rows wash: the one being dragged, else the one under the
-- cursor, else the selected one. Only while the mode is open.
function AR.Focus()
  if not AR.host then return nil end
  return AR.focus
end

function AR.UpdateFocus()
  local focus = (AR.drag and AR.drag.chip.colId) or AR.hover
    or (AR.selKind == "column" and AR.selId) or nil
  if not AR.host then focus = nil end
  if focus == AR.focus then return end
  AR.focus = focus
  AR.RowsChanged(false)
end

function AR.IsActive(owner)
  return AR.host ~= nil and AR.host.owner == owner
end

-- Whether `kind`/`id` is the thing selected in the mode now.
function AR.Selected(kind, id)
  return AR.host ~= nil and AR.selKind == kind and AR.selId == id
end

-- Selects a column's chip or a block (a host's, by id) for the inspector's
-- card; the same thing again, or nil, goes back to the overview. What it
-- was and what it is are painted again, the rows' wash follows a column,
-- and the inspector is filled for it.
function AR.Select(kind, id)
  if not AR.host then return end
  if kind == nil or (AR.selKind == kind and AR.selId == id) then kind, id = nil, nil end
  local wasKind, wasId = AR.selKind, AR.selId
  AR.selKind, AR.selId = kind, id
  AR.PaintSelected(wasKind, wasId)
  AR.PaintSelected(kind, id)
  GameTooltip:Hide()
  AR.UpdateFocus()
  AR.Inspect()
end

-- One selectable thing painted from its state: a chip in the strip, or the
-- host's blocks.
function AR.PaintSelected(kind, id)
  local host = AR.host
  if not (host and kind) then return end
  if kind == "column" then
    local chip = host.strip and host.strip.chips[id]
    if chip then AR.PaintChip(chip) end
  elseif host.PaintBlocks then
    host.PaintBlocks()
  end
end

-------------------------------------------------------------
-- 2. The press
--
-- One press in flight at a time, for the chips, the category buttons and
-- the blocks under the list alike. A press that moves four units is a drag:
-- start(x0, y0) once, then move(x, y) every frame; its release is drop(). A
-- press that never moved is a click(). A drag Escape puts back is cancel():
-- the arrangement as it was when the drag began. Coordinates are in the
-- pressed frame's own scale. `name`, if the handlers carry one, is what the
-- inspector says is moving while the drag lasts.
-------------------------------------------------------------

local gesture = {}
local driver

function AR.Cursor(frame)
  local x, y = GetCursorPosition()
  local scale = frame and frame:GetEffectiveScale() or 1
  if type(scale) ~= "number" or scale <= 0 then scale = 1 end
  return (x or 0) / scale, (y or 0) / scale
end

-- Ends the press in flight: released (the drop, or the click), put back
-- (Escape: the drag's cancel), or neither (the mode closing under it).
-- Answers whether it was a drag.
local function EndGesture(released, putBack)
  if not gesture.frame then return false end
  local handlers, dragging = gesture.handlers, gesture.dragging
  gesture.frame, gesture.handlers, gesture.dragging = nil, nil, false
  if driver then
    driver:SetScript("OnUpdate", nil)
    driver:UnregisterEvent("GLOBAL_MOUSE_UP")
  end
  if putBack then
    if dragging and handlers.cancel then handlers.cancel() end
  elseif released then
    if dragging then
      if handlers.drop then handlers.drop() end
    elseif handlers.click then
      handlers.click()
    end
  end
  -- Nothing is moving now: the inspector says what it said before.
  if dragging and AR.moving then AR.Moving(nil) end
  return dragging
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
    if gesture.handlers.name and AR.host then AR.Moving(gesture.handlers.name) end
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

-- Ends a press without its release: the mode is closing under it, or,
-- with `putBack`, Escape is putting a drag back where it began. Answers
-- whether a drag was in progress.
function AR.CancelPress(putBack)
  return EndGesture(false, putBack)
end

-- A drag in progress, rather than a press still deciding.
function AR.Dragging()
  return gesture.frame ~= nil and gesture.dragging == true
end

-------------------------------------------------------------
-- 3. Parts
-------------------------------------------------------------

-- The grip: two columns of three dots, the sign for "this moves" the title
-- bar and the chips wore before the layout mark and the eyes. Round where
-- the dots are big enough for a mask to show. Kept whole for a caller that
-- asks for it where the glyph art is missing (the key below, and the
-- options panel's mark).
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

-- Four edges of `owner`'s rect as white textures, to tint: a ring drawn
-- inside it, or a line drawn outside it. `out` is how far the outer side
-- of each edge stands past the rect (0 for a ring inside, 1 for a keyline
-- just outside), `thick` how far the edge reaches in from there. Set again
-- with another thickness by AR.PlaceEdges.
function AR.NewEdges(owner, layer, sublevel, out, thick)
  local edges = {}
  for i = 1, 4 do
    local t = owner:CreateTexture(nil, layer, nil, sublevel)
    t:SetTexture(WHITE)
    edges[i] = t
  end
  AR.PlaceEdges(edges, owner, out, thick)
  return edges
end

function AR.PlaceEdges(edges, owner, out, thick)
  local top, bottom, left, right = edges[1], edges[2], edges[3], edges[4]
  top:ClearAllPoints()
  top:SetPoint("TOPLEFT", owner, "TOPLEFT", -out, out)
  top:SetPoint("TOPRIGHT", owner, "TOPRIGHT", out, out)
  top:SetHeight(thick)
  bottom:ClearAllPoints()
  bottom:SetPoint("BOTTOMLEFT", owner, "BOTTOMLEFT", -out, -out)
  bottom:SetPoint("BOTTOMRIGHT", owner, "BOTTOMRIGHT", out, -out)
  bottom:SetHeight(thick)
  left:ClearAllPoints()
  left:SetPoint("TOPLEFT", owner, "TOPLEFT", -out, out - thick)
  left:SetPoint("BOTTOMLEFT", owner, "BOTTOMLEFT", -out, thick - out)
  left:SetWidth(thick)
  right:ClearAllPoints()
  right:SetPoint("TOPRIGHT", owner, "TOPRIGHT", out, out - thick)
  right:SetPoint("BOTTOMRIGHT", owner, "BOTTOMRIGHT", out, thick - out)
  right:SetWidth(thick)
end

function AR.TintEdges(edges, r, g, b, a)
  for i = 1, 4 do edges[i]:SetVertexColor(r, g, b, a) end
end

function AR.ShowEdges(edges, shown)
  for i = 1, 4 do edges[i]:SetShown(shown) end
end

-------------------------------------------------------------
-- 3b. Lift: the look of a thing that moves
--
-- While the mode is open, whatever can be moved is a card lifted off the
-- panel: one step lighter, a grey ring inside a black keyline, a lit top
-- edge and a short shadow under it. Pointed at, it rises a unit, its ring
-- goes white and its shadow lengthens; selected (its card in the
-- inspector), its ring is the accent over a faint accent wash; in the hand
-- it is ringed twice as thick in the accent over an accent wash, with a
-- long shadow. State rises in colour and in alpha together, never in alpha
-- alone, and the keyline and the ring hold the outline over a bright scene
-- at any window opacity.
--
-- A card is a frame of its own, laid over the thing it lifts or, for the
-- tray and the placeholder, under and in place of it. Its kind says which:
--   block  over a block under the list: a wash, no fill of its own;
--   small  over a category button: the same, with a shorter shadow;
--   tray   under the category buttons, four units out: a fill of its own;
--   fold   the grid's placeholder while the option hides it: a dim fill.
-- `hidden` is a small card's look while its button is hidden; `sel` and
-- `selHover` a block's while it is selected.
--
-- A spec is { fill = {grey, alpha}, wash = {grey, alpha}, accent = the
-- accent wash's alpha, ring = the ring's grey (nil: the accent), ringW,
-- top = the lit edge's alpha, drop = the shadow's length, dropA = its
-- alpha at the top }. Cards are made on first use and hidden with the mode.
-------------------------------------------------------------

local LIFT = {
  block = {
    rest     = { wash = { 1, 0.08 }, ring = 0.48, top = 0.09, drop = 4, dropA = 0.45 },
    hover    = { wash = { 1, 0.14 }, ring = 0.89, top = 0.14, drop = 6, dropA = 0.55 },
    sel      = { accent = 0.12, top = 0.08, drop = 4, dropA = 0.45 },
    selHover = { accent = 0.18, top = 0.12, drop = 6, dropA = 0.55 },
    hand     = { accent = 0.16, ringW = 2, drop = 10, dropA = 0.6 },
  },
  small = {
    rest        = { wash = { 1, 0.06 }, ring = 0.48, top = 0.09, drop = 2, dropA = 0.45 },
    hover       = { wash = { 1, 0.12 }, ring = 0.89, top = 0.14, drop = 3, dropA = 0.55 },
    hand        = { accent = 0.16, ringW = 2, drop = 8, dropA = 0.6 },
    hidden      = { wash = { 0, 0.40 }, ring = 0.29, drop = 2, dropA = 0.35 },
    hiddenHover = { wash = { 0, 0.25 }, ring = 0.62, top = 0.06, drop = 3, dropA = 0.45 },
  },
  tray = {
    rest     = { fill = { 0.10, 0.93 }, ring = 0.38, top = 0.07, drop = 4, dropA = 0.42 },
    hover    = { fill = { 0.157, 0.96 }, ring = 0.89, top = 0.12, drop = 6, dropA = 0.5 },
    sel      = { fill = { 0.10, 0.93 }, accent = 0.08, top = 0.07, drop = 4, dropA = 0.42 },
    selHover = { fill = { 0.157, 0.96 }, accent = 0.12, top = 0.12, drop = 6, dropA = 0.5 },
    hand     = { fill = { 0.10, 0.97 }, accent = 0.14, ringW = 2, drop = 10, dropA = 0.6 },
  },
  fold = {
    rest     = { fill = { 0.063, 0.94 }, ring = 0.29, drop = 2, dropA = 0.35 },
    hover    = { fill = { 0.12, 0.96 }, ring = 0.62, top = 0.06, drop = 3, dropA = 0.45 },
    sel      = { fill = { 0.063, 0.94 }, accent = 0.12, drop = 2, dropA = 0.35 },
    selHover = { fill = { 0.12, 0.96 }, accent = 0.16, top = 0.06, drop = 3, dropA = 0.45 },
    hand     = { fill = { 0.063, 0.97 }, accent = 0.14, ringW = 2, drop = 10, dropA = 0.6 },
  },
}
AR.LIFT = LIFT

function AR.NewCard(parent, kind)
  local card = CreateFrame("Frame", nil, parent)
  card.kind = LIFT[kind] and kind or "block"
  card.Fill = card:CreateTexture(nil, "BACKGROUND", nil, -7)
  card.Fill:SetTexture(WHITE)
  card.Fill:SetAllPoints()
  card.Drop = card:CreateTexture(nil, "BACKGROUND", nil, -8)
  card.Drop:SetTexture(WHITE)
  card.Drop:SetPoint("TOPLEFT", card, "BOTTOMLEFT", -1, -1)
  card.Drop:SetPoint("TOPRIGHT", card, "BOTTOMRIGHT", 1, -1)
  card.Wash = card:CreateTexture(nil, "BORDER", nil, -1)
  card.Wash:SetTexture(WHITE)
  card.Wash:SetAllPoints()
  card.Key = AR.NewEdges(card, "BORDER", 0, 1, 1)
  AR.TintEdges(card.Key, 0, 0, 0, 1)
  card.ringW = 1
  card.Ring = AR.NewEdges(card, "BORDER", 1, 0, 1)
  card.Top = card:CreateTexture(nil, "BORDER", nil, 2)
  card.Top:SetTexture(WHITE)
  card.Top:SetHeight(1)
  -- The shadow's two ends, kept and retinted: a gradient takes colour
  -- objects, and a new pair per paint would be garbage per hover.
  if type(CreateColor) == "function" and card.Drop.SetGradient then
    card.dropLow, card.dropHigh = CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.45)
  end
  card:Hide()
  return card
end

function AR.PaintCard(card, state)
  local set = LIFT[card.kind] or LIFT.block
  local s = set[state] or set.rest
  card.state = state
  local ar, ag, ab = Th().GetAccent()
  local fill = s.fill
  if fill then
    card.Fill:SetVertexColor(fill[1], fill[1], fill[1], fill[2])
    card.Fill:Show()
  else
    card.Fill:Hide()
  end
  local wash = s.wash
  if s.accent then
    card.Wash:SetVertexColor(ar, ag, ab, s.accent)
    card.Wash:Show()
  elseif wash then
    card.Wash:SetVertexColor(wash[1], wash[1], wash[1], wash[2])
    card.Wash:Show()
  else
    card.Wash:Hide()
  end
  local w = s.ringW or 1
  if card.ringW ~= w then
    AR.PlaceEdges(card.Ring, card, 0, w)
    card.ringW = w
  end
  if s.ring then
    AR.TintEdges(card.Ring, s.ring, s.ring, s.ring, 1)
  else
    AR.TintEdges(card.Ring, ar, ag, ab, 1)
  end
  local top = s.top or 0
  if top > 0 then
    card.Top:ClearAllPoints()
    card.Top:SetPoint("TOPLEFT", card, "TOPLEFT", w, -w)
    card.Top:SetPoint("TOPRIGHT", card, "TOPRIGHT", -w, -w)
    card.Top:SetVertexColor(1, 1, 1, top)
    card.Top:Show()
  else
    card.Top:Hide()
  end
  card.Drop:SetHeight(s.drop or 4)
  local dropA = s.dropA or 0.45
  if card.dropHigh then
    card.dropHigh:SetRGBA(0, 0, 0, dropA)
    card.Drop:SetVertexColor(1, 1, 1, 1)
    card.Drop:SetGradient("VERTICAL", card.dropLow, card.dropHigh)
  else
    card.Drop:SetVertexColor(0, 0, 0, dropA * 0.5)
  end
end

-- The mode opening: each card settles up from a unit below its place, once,
-- `delay` seconds after the first. One animation group per card, made on
-- its first rise: a step down at once, then the rise.
function AR.Rise(card, delay)
  if not card or type(card.CreateAnimationGroup) ~= "function" then return end
  local group = card.RiseGroup
  if not group then
    group = card:CreateAnimationGroup()
    local down = group:CreateAnimation("Translation")
    down:SetOffset(0, -1)
    down:SetDuration(0.001)
    down:SetOrder(1)
    local up = group:CreateAnimation("Translation")
    up:SetOffset(0, 1)
    up:SetDuration(0.38)
    up:SetOrder(2)
    if up.SetSmoothing then up:SetSmoothing("OUT") end
    group.up = up
    card.RiseGroup = group
  end
  group:Stop()
  group.up:SetStartDelay(delay or 0)
  group:Play()
end

-- The pointer over something that moves is the client's own move cross (the
-- cursor its panels' drag bars show); anywhere else it is the pointer.
function AR.MoveCursor(on)
  if on then
    if type(SetCursor) == "function" then SetCursor("UI_MOVE_CURSOR") end
  elseif type(ResetCursor) == "function" then
    ResetCursor()
  elseif type(SetCursor) == "function" then
    SetCursor(nil)
  end
end

-------------------------------------------------------------
-- 4. The cog key
--
-- Beside the cog, the cog's size: the layout mark, a plan of the window --
-- the list on top, two blocks under it, one of them being placed -- in the
-- chrome's grey, with a black keyline baked into the art so it holds over a
-- bright scene. It reads as neither a handle nor the cog: a different
-- silhouette, a quieter colour, four units apart. Pointed at, the mark goes
-- white on a faint plate. While the mode is open it widens in place into a
-- lit Done -- a check and the word on the accent -- which is the way out;
-- right-click on it goes back to the default arrangement. `place` anchors
-- it by its left edge, so the widening runs to the right; `getHost` answers
-- which list it arranges, and may bring that list forward first.
--
-- All of it is drawn on the key itself, a button of Postbox's own: nothing
-- is laid on the title bar or on any frame a skin repaints.
-------------------------------------------------------------

-- The ink a lit accent carries: dark on a light accent, as on the brand
-- gold; white on a dark one a host UI might publish.
local function Ink(r, g, b)
  if 0.2126 * r + 0.7152 * g + 0.0722 * b >= 0.45 then return 0.086, 0.071, 0 end
  return 1, 1, 1
end

-- Every look the key has, from its state: at rest the mark alone; pointed
-- at, white on a plate (a 7% white fill, a grey ring, a black keyline);
-- lit, the accent with a black keyline and a darker foot, the check and
-- Done in its ink, and pointed at while lit, a lighter accent with a halo.
function AR.PaintToggle(button)
  if not button then return end
  local T = Th()
  local lit = AR.host ~= nil and AR.host.toggle == button
  local hover = button.hover and true or false
  local mark, check, label = button.Mark, button.Check, button.Label
  if lit then
    local r, g, b = T.GetAccent()
    local ir, ig, ib = Ink(r, g, b)
    AR.TintEdges(button.Glow, r, g, b, 0.35)
    AR.ShowEdges(button.Glow, hover)
    if hover then r, g, b = r + (1 - r) * 0.38, g + (1 - g) * 0.38, b + (1 - b) * 0.38 end
    button.Fill:SetVertexColor(r, g, b, 1)
    button.Fill:Show()
    AR.ShowEdges(button.Ring, false)
    AR.TintEdges(button.Key, 0, 0, 0, 1)
    AR.ShowEdges(button.Key, true)
    button.Base:Show()
    if mark then mark:Hide() end
    if button.grip then button.grip:Hide() end
    if check then
      check:SetVertexColor(ir, ig, ib, 1)
      check:Show()
    end
    label:SetTextColor(ir, ig, ib, 1)
    label:Show()
    button:SetWidth(KEY_LEAD + KEY_CHECK + KEY_GAP + math.ceil(T.TextWidth(label)) + KEY_TAIL)
    return
  end
  button:SetWidth(KEY_SIZE)
  button.Fill:SetVertexColor(1, 1, 1, 0.07)
  button.Fill:SetShown(hover)
  AR.TintEdges(button.Ring, 0.365, 0.365, 0.365, 1)
  AR.ShowEdges(button.Ring, hover)
  AR.TintEdges(button.Key, 0, 0, 0, 0.8)
  AR.ShowEdges(button.Key, hover)
  AR.ShowEdges(button.Glow, false)
  button.Base:Hide()
  if check then check:Hide() end
  label:Hide()
  local token = hover and "textPrimary" or KEY_REST
  if mark then
    T.SetColor(mark, token)
    mark:Show()
  elseif button.grip then
    for i = 1, #button.grip.dots do T.SetColor(button.grip.dots[i], token) end
    button.grip:Show()
  end
end

local function ToggleTip(button)
  GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
  if AR.host and AR.host.toggle == button then
    GameTooltip:SetText(L()["ARRANGE_DONE"])
    GameTooltip:AddLine(L()["ARRANGE_DONE_TIP"], 1, 1, 1, true)
    GameTooltip:AddLine(L()["ARRANGE_TIP_ACTIVE"], 0.7, 0.7, 0.7, true)
    GameTooltip:AddLine(L()["ARRANGE_TIP_RESET"], 0.7, 0.7, 0.7, true)
  else
    GameTooltip:SetText(L()["ARRANGE_TITLE"])
    GameTooltip:AddLine(L()["ARRANGE_TIP"], 1, 1, 1, true)
  end
  GameTooltip:Show()
end

-- The key's art, made once with the key. Back to front: the lit halo, the
-- keyline, the fill, the ring and the lit foot, then the mark, the check
-- and the word.
local function BuildKeyArt(button)
  local T = Th()
  button.Glow = AR.NewEdges(button, "BACKGROUND", -8, 2, 1)
  button.Key = AR.NewEdges(button, "BACKGROUND", -7, 1, 1)
  button.Fill = button:CreateTexture(nil, "BACKGROUND", nil, -6)
  button.Fill:SetTexture(WHITE)
  button.Fill:SetAllPoints()
  button.Ring = AR.NewEdges(button, "BORDER", 0, 0, 1)
  button.Base = button:CreateTexture(nil, "BORDER", nil, 1)
  button.Base:SetTexture(WHITE)
  button.Base:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
  button.Base:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
  button.Base:SetHeight(1)
  button.Base:SetVertexColor(0, 0, 0, 0.25)

  -- The mark, and where the glyph art is missing the six dots it replaced.
  button.Mark = T.Glyph and T.Glyph(button, "layout", KEY_MARK, "ARTWORK") or nil
  if button.Mark then
    button.Mark:SetPoint("CENTER", button, "CENTER", 0, 0)
  else
    button.grip = AR.Grip(button, 4, 3)
    button.grip:SetPoint("CENTER")
  end
  button.Check = T.Glyph and T.Glyph(button, "check", KEY_CHECK, "ARTWORK") or nil
  if button.Check then
    button.Check:SetPoint("CENTER", button, "LEFT", KEY_LEAD + KEY_CHECK / 2, 0)
  end
  button.Label = T.CreateText(button, "segment", "ARTWORK")
  button.Label:SetPoint("LEFT", button, "LEFT", KEY_LEAD + KEY_CHECK + KEY_GAP, 0)
  button.Label:SetWordWrap(false)
  -- Ink on the accent, flat: the role's drop shadow would muddy it.
  if button.Label.SetShadowOffset then button.Label:SetShadowOffset(0, 0) end
  button.Label:SetText(L()["ARRANGE_DONE"])
end

function AR.BuildToggle(parent, place, getHost)
  local button = CreateFrame("Button", nil, parent)
  button:SetSize(KEY_SIZE, KEY_SIZE)
  place(button)
  button:SetFrameLevel(parent:GetFrameLevel() + 20)
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  BuildKeyArt(button)
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
      if active then
        GameTooltip:Hide()
        AR.AskReset()
      end
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
-- Escape works in layers, one per press, and never closes the window under
-- the mode -- nor the mailbox: a drag in progress is put back where it
-- began; else a selection is let go, and the inspector goes back to its
-- overview; else the mode ends. The inspector's cross does the same, less
-- the drag. The client closes windows on Escape by hiding every shown
-- frame named in UISpecialFrames; while the mode is open the Postbox
-- windows' names there are swapped IN PLACE for a small frame of ours, and
-- that frame hiding is what an Escape is heard by. In place, so no other
-- entry shifts. A layer short of the last shows the frame again for the
-- next Escape; the swap is undone on the way out, however the mode ends.
-- No keyboard is taken for any of it.
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
      -- Hidden by the client's close-windows pass on an Escape: answered a
      -- frame later, off that path, as the window's own close is
      -- (COMBAT_TAINT.md).
      C_Timer.After(0, AR.OnEscape)
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

-- One Escape, one layer.
function AR.OnEscape()
  if not AR.host then return end
  if AR.Dragging() then
    AR.CancelPress(true)
  elseif AR.selKind then
    AR.Select(nil)
  else
    AR.Leave()
    return
  end
  -- The mode stays open: the catcher, whose name still stands in the
  -- windows' places, listens for the next Escape.
  local catcher = AR._esc
  if catcher and AR._escTaken then
    catcher.armed = true
    catcher:Show()
  end
end

-------------------------------------------------------------
-- 6. The strip
--
-- A row of chips, one per column, in the row's order: the column's name (or,
-- for the read mark and the icon, what the column draws). The subject's chip
-- stretches across what the others leave, as the subject does in the row,
-- so the strip reads as the row it arranges. A hidden column's chip keeps
-- its place, greyed, with a crossed eye before its name: showing it again
-- puts it back where it was. A click selects a chip, and the inspector
-- shows its column's card; the chip is then ringed in the accent.
-------------------------------------------------------------

local function ChipTip(chip)
  if AR.drag then return end
  if AR.Selected("column", chip.colId) then return end
  GameTooltip:SetOwner(chip, "ANCHOR_TOP")
  GameTooltip:SetText(L()[AR.COLUMNS[chip.colId].title])
  GameTooltip:Show()
end

-- Where a chip's name or glyph starts: past the crossed eye while its
-- column is hidden.
local function ChipLead(chip)
  return chip.hidden and (CHIP_LEAD + CHIP_EYE + CHIP_EYE_GAP) or CHIP_LEAD
end

-- The name or glyph at the chip's lead, and the crossed eye before it.
local function PlaceChipContent(chip)
  local lead = ChipLead(chip)
  if chip.lead == lead then return end
  chip.lead = lead
  if chip.Glyph then
    chip.Glyph:ClearAllPoints()
    if chip.glyphKind == "dot" then
      chip.Glyph:SetPoint("CENTER", chip, "LEFT", lead + GLYPH / 2, 0)
    else
      chip.Glyph:SetPoint("LEFT", chip, "LEFT", lead, 0)
    end
  elseif chip.Text then
    chip.Text:ClearAllPoints()
    chip.Text:SetPoint("LEFT", chip, "LEFT", lead, 0)
  end
end

-- The chip's look after every repaint the plate makes of itself: selected
-- while in the hand or while its card is in the inspector, and then ringed
-- in the accent inside its edge (the ring made the first time); greyed,
-- with its eye crossed, while its column is hidden.
function AR.PaintChip(chip)
  local T = Th()
  local selected = (AR.drag ~= nil and AR.drag.chip == chip) or AR.Selected("column", chip.colId)
  T.SetPlateSelected(chip, selected)
  if selected and not chip.SelRing then chip.SelRing = AR.NewEdges(chip, "ARTWORK", 3, 0, 1) end
  if chip.SelRing then
    if selected then
      local r, g, b = T.GetAccent()
      AR.TintEdges(chip.SelRing, r, g, b, 1)
    end
    AR.ShowEdges(chip.SelRing, selected)
  end
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
  if chip.EyeOff then
    chip.EyeOff:SetShown(hidden and true or false)
    T.SetColor(chip.EyeOff, (selected or chip.__pbHover) and "textSecondary" or "textDisabled")
  end
end

local function BuildChip(strip, host, id)
  local T = Th()
  local spec = AR.COLUMNS[id]
  local chip = T.CreatePlate(strip, "tile")
  chip.colId = id
  chip:SetHeight(T.Metrics.tileHeight)

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
    else
      chip.Glyph:SetSize(GLYPH, GLYPH)
      chip.Glyph:SetTexture(ICON_SAMPLE)
      chip.Glyph:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      chip.glyphW = GLYPH
    end
  else
    chip.caption = L()[spec.title]
    chip:SetText(chip.caption)
    chip.Text:SetJustifyH("LEFT")
  end
  PlaceChipContent(chip)

  -- Crossed while the column is hidden, before its name or glyph.
  chip.EyeOff = T.Glyph and T.Glyph(chip, "eye-off", 8, "OVERLAY") or nil
  if chip.EyeOff then
    chip.EyeOff:SetPoint("CENTER", chip, "LEFT", CHIP_LEAD + CHIP_EYE / 2, 0)
    chip.EyeOff:Hide()
  end

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

  strip.Ghost = AR.NewGhost(strip)
  strip:SetScript("OnSizeChanged", function()
    if AR.host == host then AR.LayoutStrip(host) end
  end)
  host.strip = strip
  -- The chips are Postbox's own plates, as the view switch beside them is;
  -- the skin's pass finds whatever it styles among them, as it always has.
  if ns.Skin and ns.Skin.Refresh then pcall(ns.Skin.Refresh, strip) end
  return strip
end

-- A chip's width with nothing cut: the eye if its column is hidden, the
-- name or glyph, and air.
local function Natural(chip)
  if chip.Glyph then return ChipLead(chip) + chip.glyphW + CHIP_TAIL end
  chip.Text:SetWidth(0)
  chip.Text:SetText(chip.caption)
  return ChipLead(chip) + math.ceil(chip.Text:GetStringWidth() or 0) + CHIP_TAIL
end

-- The width the strip needs to say every name whole: a window that can grow
-- (Mail Memory's) grows to it while it arranges.
function AR.StripNeed(host)
  local strip = host and host.strip
  if not strip then return 0 end
  local total = 0
  local n = 0
  -- Each chip as the arrangement has it now: a hidden column's is wider by
  -- its eye.
  local layout = AR.Layout()
  if layout then
    for i = 1, #layout do
      local chip = strip.chips[layout[i].id]
      if chip then chip.hidden = not layout[i].shown end
    end
  end
  for _, chip in pairs(strip.chips) do
    total = total + Natural(chip)
    n = n + 1
  end
  return total + CHIP_GAP * math.max(n - 1, 0)
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
  local avail = width
  strip._avail = avail

  local total, flexible = CHIP_GAP * (#layout - 1), 0
  for i = 1, #layout do
    local chip = strip.chips[layout[i].id]
    chip.hidden = not layout[i].shown
    PlaceChipContent(chip)
    chip._nat = Natural(chip)
    total = total + chip._nat
    if not chip.Glyph then flexible = flexible + chip._nat - ChipLead(chip) - CHIP_TAIL end
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
    local lead = ChipLead(chip)
    if spare < 0 and not chip.Glyph then
      w = lead + CHIP_TAIL + math.floor((chip._nat - lead - CHIP_TAIL) * scale)
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
    if chip.caption then T.FitText(chip.Text, w - lead - CHIP_TAIL + 2, chip.caption, chip) end
    chip:Show()
    AR.PaintChip(chip)
    x = x + w + CHIP_GAP
  end
  if not drag then strip.Ghost:Hide() end
end

-------------------------------------------------------------
-- 7. Dragging a chip
-------------------------------------------------------------

function AR.PressChip(host, chip)
  AR.Press(chip, {
    name = L()[AR.COLUMNS[chip.colId].title],
    start = function(x0)
      if AR.host ~= host then return end
      GameTooltip:Hide()
      AR.drag = {
        chip = chip, grab = x0 - (chip:GetLeft() or x0), level = chip:GetFrameLevel(),
        -- The arrangement as it was, for Escape to put back.
        before = CopyLayout(),
      }
      chip:SetFrameLevel(host.strip:GetFrameLevel() + 20)
      AR.LayoutStrip(host)
      AR.UpdateFocus()
    end,
    move = function(x) AR.DragChip(host, x) end,
    drop = function() AR.DropChip(host) end,
    cancel = function()
      local drag, ui = AR.drag, UI()
      if drag and drag.before and ui and ui.SetRowLayout then ui.SetRowLayout(drag.before) end
      AR.DropChip(host)
      AR.RowsChanged(true)
    end,
    click = function()
      if AR.host == host then AR.Select("column", chip.colId) end
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
-- 8. The inspector
--
-- One card docked beside the window being arranged, 8 units out from its
-- right edge (from its left one when the screen has no room on the right),
-- its top level with the window's top row. Shown only while the mode is
-- open, and nothing of it covers the rows. It says one of three things:
--   nothing selected: how the mode works, what is hidden (each a chip; a
--     click shows it again), the reset, and that Escape finishes;
--   something in the hand: what is moving, and that Escape puts it back;
--   a column or a block selected: its card -- what it is, its eye, its own
--     choice, Move (the way to reorder without a drag), and, for a figure,
--     what the rows do on a mail without it; for a block, the stack's order.
-- A click on a chip or a block selects it, a second click lets it go; the
-- cross and Escape go back a layer (section 5).
--
-- Built the first time the mode opens and refilled in place: every region
-- exists once, the choices are lists made once, and a fill sets texts,
-- colours and points -- a selection or a pointer allocates nothing. A text
-- is measured once per string and font (Measured). Everything it draws is
-- on child frames of its own: the card itself is tagged for the host skin
-- (Theme.ApplyCard), and EllesmereUI fades a tagged frame's own textures.
-------------------------------------------------------------

-- The inspector's measures, from the mockup (concept-c.html), in UI units.
local INSP = {
  W = 208, PAD = 11, TOP = 10, BOTTOM = 11, DOCK = 8,
  CLOSE = 18,                 -- the cross's square, in the top right corner
  HEAD_GAP = 6,               -- the title to what follows it
  ROW_GAP = 8,                -- a text to the switch and Move under it
  ROW_WRAP = 6,               -- the switch to Move, where one row is too narrow
  SWITCH_H = 20, SWITCH_LEAD = 24, SWITCH_TAIL = 8,
  NUDGE_W = 22, NUDGE_H = 18, NUDGE_GAP = 4, MOVE_GAP = 8,
  KICK_TOP = 10, KICK_GAP = 4,
  RADIO_H = 19, RADIO_TEXT = 17,
  CHIP_H = 19, CHIP_GAP = 4, CHIP_LEAD = 6, CHIP_EYE = 12, CHIP_EYE_GAP = 5, CHIP_TAIL = 7,
  LINE_H = 18, LINE_NUM = 14,  -- a line of the stack's order, and its number's column
  NOTE_TOP = 8, NOTE_PAD = 7,
  FOOT_TOP = 10, FOOT_PAD = 7, FOOT_GAP = 8, KEY_PAD = 4, KEY_H = 15, KEY_GAP = 4,
  SPACING = 2,
  MEMO_MAX = 96,
}
INSP.INNER = INSP.W - 2 * INSP.PAD
AR.INSP = INSP

-- The greys of the inspector's own plates (a fill, a grey ring and, but
-- for the key cap, a black keyline): at rest, pointed at, and -- the switch
-- while shown, a Move that cannot go further -- in their other state.
local PLATE = {
  switch = { fill = 0.13, ring = 0.365, hover = 0.86, on = 0.54 },
  nudge  = { fill = 0.13, ring = 0.365, hover = 0.86, off = 0.22 },
  chip   = { fill = 0.057, ring = 0.28, hover = 0.62 },
  key    = { fill = 0.17, ring = 0.33 },
}

-- A text's width on one line, or its height wrapped at the string's own
-- width, remembered per string: the inspector's texts are the locale's own
-- and a few names, so the memo stays small. It empties when the font under
-- it changes (a host UI re-fonts after load) or its scale does, and past
-- MEMO_MAX strings.
local function Measured(fs, text, wrapped)
  fs:SetText(text)
  local memo = fs.__arMemo
  if not memo then
    memo = { w = {}, h = {}, n = 0 }
    fs.__arMemo = memo
  end
  local path, size, flags = fs:GetFont()
  local scale = fs:GetEffectiveScale()
  if memo.path ~= path or memo.size ~= size or memo.flags ~= flags or memo.scale ~= scale
      or memo.n > INSP.MEMO_MAX then
    local w, h = memo.w, memo.h
    for key in pairs(w) do w[key] = nil end
    for key in pairs(h) do h[key] = nil end
    memo.path, memo.size, memo.flags, memo.scale, memo.n = path, size, flags, scale, 0
  end
  local sizes = wrapped and memo.h or memo.w
  local v = sizes[text]
  if not v then
    if wrapped then v = fs:GetStringHeight() else v = fs:GetStringWidth() end
    v = math.ceil(v or 0)
    -- A font the client has not laid out yet measures nothing: not kept.
    if v > 0 then
      sizes[text] = v
      memo.n = memo.n + 1
    end
  end
  return v
end

-- A kicker's words in capitals, made once per string (Strings.Upper knows
-- the Latin-1 and Cyrillic letters string.upper does not).
local function Upper(text)
  local cache = AR._upper
  if not cache then
    cache = {}
    AR._upper = cache
  end
  local up = cache[text]
  if not up then
    local S = ns.Core and ns.Core.Strings
    up = (S and type(S.Upper) == "function") and S.Upper(text) or text
    cache[text] = up
  end
  return up
end

local function PlayToggle(on)
  if type(SOUNDKIT) == "table" and type(PlaySound) == "function" then
    PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
  end
end

-- The column's own choice: the gold's and the time left's. The lists are
-- made once; what is chosen and how to choose are read each time.
function AR.Choices(kind)
  local ui = UI()
  local lists = AR._choices
  if not lists then
    lists = { none = {} }
    AR._choices = lists
  end
  if not ui or (kind ~= "gold" and kind ~= "expiry") then return lists.none, nil, nil end
  local list = lists[kind]
  if not list then
    if kind == "gold" then
      list = {
        { id = "both",   name = L()["OPT_GOLD_BOTH"] },
        { id = "earned", name = L()["OPT_GOLD_EARNED"] },
        { id = "spent",  name = L()["OPT_GOLD_SPENT"] },
      }
    else
      list = {
        { id = "always", name = L()["OPT_EXPIRY_ALWAYS"] },
        { id = "7", name = ns.Plural("OPT_EXPIRY_UNDER", 7) },
        { id = "3", name = ns.Plural("OPT_EXPIRY_UNDER", 3) },
        { id = "1", name = ns.Plural("OPT_EXPIRY_UNDER", 1) },
      }
    end
    lists[kind] = list
  end
  if kind == "gold" then return list, ui.GetGoldMode and ui.GetGoldMode(), ui.SetGoldMode end
  return list, ui.GetExpiryWhen and ui.GetExpiryWhen(), ui.SetExpiryWhen
end

-- A column shown or hidden from the inspector: the strip and the rows
-- follow, as they follow a drag.
function AR.ShowColumn(id, on)
  AR.SetColumnShown(id, on)
  if AR.host then AR.LayoutStrip(AR.host) end
  AR.RowsChanged(true)
end

-- A column one place along the row, left (-1) or right (1).
function AR.NudgeColumn(id, step)
  local layout = AR.Layout()
  local k = layout and IndexOf(layout, id)
  if not k then return end
  local to = k + step
  if to < 1 or to > #layout then return end
  AR.MoveColumn(k, to)
  if AR.host then AR.LayoutStrip(AR.host) end
  AR.RowsChanged(true)
end

-- What is moving, while a drag lasts (section 2), or nil.
function AR.Moving(name)
  if AR.moving == name then return end
  AR.moving = name
  AR.Inspect()
end

-- The moving line: made once per name.
local function MovingText(name)
  if AR._movingName ~= name then
    AR._movingName = name
    AR._movingText = "|cffffffff" .. L()("ARRANGE_MOVING", name) .. "|r " .. L()["ARRANGE_MOVING_HOW"]
  end
  return AR._movingText
end

-------------------------------------------------------------
-- 8a. Its parts
-------------------------------------------------------------

-- A small plate of the inspector's own: a fill, a grey ring and a black
-- keyline outside it, as the mockup draws its switch, Move buttons and
-- hidden chips; the key cap has no keyline.
local function InspPlate(parent, frameType, keyline)
  local plate = CreateFrame(frameType, nil, parent)
  plate.Fill = plate:CreateTexture(nil, "BACKGROUND", nil, -7)
  plate.Fill:SetTexture(WHITE)
  plate.Fill:SetAllPoints()
  if keyline then
    plate.Key = AR.NewEdges(plate, "BORDER", 0, 1, 1)
    AR.TintEdges(plate.Key, 0, 0, 0, 1)
  end
  plate.Ring = AR.NewEdges(plate, "BORDER", 1, 0, 1)
  return plate
end

local function TintPlate(plate, fill, ring)
  plate.Fill:SetVertexColor(fill, fill, fill, 0.95)
  AR.TintEdges(plate.Ring, ring, ring, ring, 1)
end

local function Grey(region, v)
  if region.SetTextColor then
    region:SetTextColor(v, v, v, 1)
  else
    region:SetVertexColor(v, v, v, 1)
  end
end

-- The eye switch: open and "Shown", or crossed and "Hidden". Its words
-- rise to white and its ring to a lighter grey while shown, and both go
-- white when pointed at.
local function PaintSwitch(sw)
  local spec = PLATE.switch
  local on, hover = sw.on, sw.hover
  TintPlate(sw, hover and 0.17 or spec.fill, hover and spec.hover or (on and spec.on or spec.ring))
  if sw.Eye then
    sw.Eye:SetShown(on and true or false)
    Grey(sw.Eye, hover and 1 or 0.84)
  end
  if sw.EyeOff then
    sw.EyeOff:SetShown(not on)
    Grey(sw.EyeOff, hover and 1 or 0.84)
  end
  Grey(sw.Label, (on or hover) and 1 or 0.74)
end

local function SwitchEnter(self)
  self.hover = true
  PaintSwitch(self)
end

local function SwitchLeave(self)
  self.hover = false
  PaintSwitch(self)
end

local function SwitchClick(self)
  local host = AR.host
  if not host then return end
  local on = not self.on
  if AR.selKind == "column" then
    AR.ShowColumn(AR.selId, on)
    PlayToggle(on)
  elseif AR.selKind == "block" and host.SetBlockShown then
    host.SetBlockShown(AR.selId, on)
  end
  AR.Inspect()
end

-- Move, one step: an arrow on a plate, dimmed where the thing cannot go
-- further that way.
local function PaintNudge(b)
  local spec = PLATE.nudge
  local live, hover = b.live, b.hover and b.live
  TintPlate(b, hover and 0.17 or spec.fill, live and (hover and spec.hover or spec.ring) or spec.off)
  local glyph = b.vertical and b.V or b.H
  local other = b.vertical and b.H or b.V
  if other then other:Hide() end
  if glyph then
    glyph:Show()
    Grey(glyph, live and (hover and 1 or 0.84) or 0.4)
  end
end

local function NudgeEnter(self)
  self.hover = true
  PaintNudge(self)
end

local function NudgeLeave(self)
  self.hover = false
  PaintNudge(self)
end

local function NudgeClick(self)
  local host = AR.host
  if not (host and self.live) then return end
  if AR.selKind == "column" then
    AR.NudgeColumn(AR.selId, self.step)
  elseif AR.selKind == "block" and host.MoveBlock then
    host.MoveBlock(AR.selId, self.step)
  end
  AR.Inspect()
end

-- The chosen one of a column's own choices: a small accent square in a
-- black keyline before its name, the name white; the others a lighter
-- grey; all of it grey while the column is hidden.
local function PaintRadio(row)
  local live, chosen, hover = row.live, row.chosen, row.hover and row.live
  row.Hover:SetShown(hover and true or false)
  if chosen then
    if live then
      local r, g, b = Th().GetAccent()
      row.Mark:SetVertexColor(r, g, b, 1)
    else
      Grey(row.Mark, 0.44)
    end
  end
  row.Mark:SetShown(chosen and true or false)
  row.MarkKey:SetShown(chosen and true or false)
  Grey(row.Text, live and ((chosen or hover) and 1 or 0.91) or 0.44)
end

local function RadioEnter(self)
  self.hover = true
  PaintRadio(self)
end

local function RadioLeave(self)
  self.hover = false
  PaintRadio(self)
end

local function RadioClick(self)
  local insp = AR._insp
  if not (self.live and insp and insp.set) then return end
  insp.set(self.choiceId)
  AR.RowsChanged(true)
  AR.Inspect()
end

local function Radio(insp, i)
  local T = Th()
  local row = CreateFrame("Button", nil, insp)
  row:SetSize(INSP.INNER, INSP.RADIO_H)
  row.hover, row.live, row.chosen = false, false, false
  row.Hover = row:CreateTexture(nil, "BACKGROUND")
  row.Hover:SetTexture(WHITE)
  row.Hover:SetVertexColor(1, 1, 1, 0.06)
  row.Hover:SetAllPoints()
  row.Hover:Hide()
  row.MarkKey = row:CreateTexture(nil, "ARTWORK", nil, 0)
  row.MarkKey:SetTexture(WHITE)
  row.MarkKey:SetVertexColor(0, 0, 0, 1)
  row.MarkKey:SetSize(7, 7)
  row.MarkKey:SetPoint("LEFT", row, "LEFT", 3, 0)
  row.Mark = row:CreateTexture(nil, "ARTWORK", nil, 1)
  row.Mark:SetTexture(WHITE)
  row.Mark:SetSize(5, 5)
  row.Mark:SetPoint("CENTER", row.MarkKey, "CENTER", 0, 0)
  row.Text = T.CreateText(row, "body")
  row.Text:SetPoint("LEFT", row, "LEFT", INSP.RADIO_TEXT, 0)
  row.Text:SetJustifyH("LEFT")
  row.Text:SetWordWrap(false)
  row:SetScript("OnEnter", RadioEnter)
  row:SetScript("OnLeave", RadioLeave)
  row:SetScript("OnClick", RadioClick)
  insp.Radios[i] = row
  return row
end

-- A hidden thing's chip: a crossed eye and its name on a dark plate; a
-- click shows it again. Pointed at, its ring and its words lighten.
local function PaintHiddenChip(chip)
  local spec = PLATE.chip
  local hover = chip.hover
  TintPlate(chip, hover and 0.12 or spec.fill, hover and spec.hover or spec.ring)
  local v = hover and 1 or 0.6
  Grey(chip.Label, v)
  if chip.Eye then Grey(chip.Eye, v) end
end

local function HiddenEnter(self)
  self.hover = true
  PaintHiddenChip(self)
end

local function HiddenLeave(self)
  self.hover = false
  PaintHiddenChip(self)
end

local function HiddenClick(self)
  local host = AR.host
  if not host then return end
  self.hover = false
  if self.kind == "column" then
    AR.ShowColumn(self.key, true)
  elseif host.ShowHidden then
    host.ShowHidden(self.kind, self.key)
  end
  -- The grid's own switch makes its own sound.
  if self.kind ~= "grid" then PlayToggle(true) end
  AR.Inspect()
end

local function HiddenChip(insp, i)
  local T = Th()
  local chip = InspPlate(insp, "Button", true)
  chip:SetHeight(INSP.CHIP_H)
  chip.hover = false
  chip.Eye = T.Glyph and T.Glyph(chip, "eye-off", 8, "ARTWORK") or nil
  if chip.Eye then chip.Eye:SetPoint("CENTER", chip, "LEFT", INSP.CHIP_LEAD + INSP.CHIP_EYE / 2, 0) end
  chip.Label = T.CreateText(chip, "body")
  chip.Label:SetPoint("LEFT", chip, "LEFT", INSP.CHIP_LEAD + INSP.CHIP_EYE + INSP.CHIP_EYE_GAP, 0)
  chip.Label:SetJustifyH("LEFT")
  chip.Label:SetWordWrap(false)
  chip:SetScript("OnEnter", HiddenEnter)
  chip:SetScript("OnLeave", HiddenLeave)
  chip:SetScript("OnClick", HiddenClick)
  insp.Chips[i] = chip
  return chip
end

-- The cross: back to the overview from a card, out of the mode from the
-- overview -- Escape's layers, less the drag.
local function CloseTip(self)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  if AR.selKind then
    GameTooltip:SetText(L()["ARRANGE_BACK_TIP"], 1, 1, 1, 1, true)
  else
    GameTooltip:SetText(L()["ARRANGE_DONE"])
    GameTooltip:AddLine(L()["ARRANGE_DONE_TIP"], 1, 1, 1, true)
    GameTooltip:AddLine(L()["ARRANGE_TIP_ACTIVE"], 0.7, 0.7, 0.7, true)
  end
  GameTooltip:Show()
end

local function CloseEnter(self)
  Grey(self.Text, 1)
  CloseTip(self)
end

local function CloseLeave(self)
  Grey(self.Text, 0.74)
  GameTooltip:Hide()
end

local function CloseClick(self)
  if AR.selKind then
    AR.Select(nil)
    if GameTooltip:IsOwned(self) then CloseTip(self) end
  else
    GameTooltip:Hide()
    AR.Leave()
  end
end

-- The reset, as a link: underlined, lighter when pointed at.
local function PaintLink(link)
  local hover = link.hover
  Grey(link.Label, hover and 1 or 0.74)
  Grey(link.Line, hover and 0.6 or 0.33)
end

local function LinkEnter(self)
  self.hover = true
  PaintLink(self)
end

local function LinkLeave(self)
  self.hover = false
  PaintLink(self)
end

local function LinkClick()
  AR.AskReset()
end

-- A text of the inspector, wrapped across its width, in a role and a grey.
local function Paragraph(art, role, grey)
  local fs = Th().CreateText(art, role)
  fs:SetWidth(INSP.INNER)
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(true)
  if fs.SetSpacing then fs:SetSpacing(INSP.SPACING) end
  if grey then Grey(fs, grey) end
  fs:Hide()
  return fs
end

local function Line(art, role)
  local fs = Th().CreateText(art, role)
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(false)
  fs:Hide()
  return fs
end

local function Rule(art)
  local rule = art:CreateTexture(nil, "ARTWORK")
  rule:SetTexture(WHITE)
  rule:SetHeight(1)
  Grey(rule, 0.17)
  rule:Hide()
  return rule
end

function AR.BuildInspector()
  local T = Th()
  local P = INSP
  local insp = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  insp.__pbPopupAlways = true
  T.ApplyCard(insp)
  insp:SetFrameStrata("FULLSCREEN_DIALOG")
  insp:SetClampedToScreen(true)
  insp:EnableMouse(true)
  insp:SetWidth(P.W)
  insp.Radios, insp.Chips, insp.OrderNum, insp.OrderName = {}, {}, {}, {}

  -- Every text and rule is on this holder, never on the card itself.
  local art = CreateFrame("Frame", nil, insp)
  art:SetAllPoints()
  insp.Art = art

  insp.Title = Line(art, "title")
  insp.Title:SetPoint("TOPLEFT", insp, "TOPLEFT", P.PAD, -P.TOP)
  T.SetColor(insp.Title, "accent")
  insp.Title:Show()
  insp.Lead = Paragraph(art, "body", 0.81)
  insp.Empty = Paragraph(art, "body", 0.55)
  insp.Note = Paragraph(art, "secondary", 0.66)
  insp.Kicker = Paragraph(art, "secondary", 0.55)
  insp.MoveLabel = Line(art, "body")
  Grey(insp.MoveLabel, 0.74)
  insp.NoteRule = Rule(art)
  insp.FootRule = Rule(art)
  insp.Finish = Line(art, "secondary")
  Grey(insp.Finish, 0.55)
  -- One line of each role, never shown: where a single line is measured
  -- whole, whatever width the one on show was fitted to.
  insp.MeasureBody = Line(art, "body")
  insp.MeasureSegment = Line(art, "segment")
  insp.MeasureSmall = Line(art, "secondary")

  local close = CreateFrame("Button", nil, insp)
  close:SetSize(P.CLOSE, P.CLOSE)
  close:SetPoint("TOPRIGHT", insp, "TOPRIGHT", -(P.PAD - 5), -(P.TOP - 3))
  close.Text = T.CreateText(close, "title")
  close.Text:SetPoint("CENTER", close, "CENTER", 0, 1)
  close.Text:SetText("\195\151")
  Grey(close.Text, 0.74)
  close:SetScript("OnEnter", CloseEnter)
  close:SetScript("OnLeave", CloseLeave)
  close:SetScript("OnClick", CloseClick)
  insp.Close = close

  local sw = InspPlate(insp, "Button", true)
  sw:SetHeight(P.SWITCH_H)
  sw.hover, sw.on = false, false
  sw.Eye = T.Glyph and T.Glyph(sw, "eye", 8, "ARTWORK") or nil
  sw.EyeOff = T.Glyph and T.Glyph(sw, "eye-off", 8, "ARTWORK") or nil
  if sw.Eye then sw.Eye:SetPoint("CENTER", sw, "LEFT", 12, 0) end
  if sw.EyeOff then sw.EyeOff:SetPoint("CENTER", sw, "LEFT", 12, 0) end
  sw.Label = T.CreateText(sw, "segment")
  sw.Label:SetPoint("LEFT", sw, "LEFT", P.SWITCH_LEAD, 0)
  sw.Label:SetWordWrap(false)
  sw:SetScript("OnEnter", SwitchEnter)
  sw:SetScript("OnLeave", SwitchLeave)
  sw:SetScript("OnClick", SwitchClick)
  sw:Hide()
  insp.Switch = sw

  for i = 1, 2 do
    local b = InspPlate(insp, "Button", true)
    b:SetSize(P.NUDGE_W, P.NUDGE_H)
    b.step = (i == 1) and -1 or 1
    b.hover, b.live, b.vertical = false, false, false
    b.H = T.Glyph and T.Glyph(b, i == 1 and "arrow-left" or "arrow-right", 8, "ARTWORK") or nil
    b.V = T.Glyph and T.Glyph(b, i == 1 and "arrow-up" or "arrow-down", 6, "ARTWORK") or nil
    if b.H then b.H:SetPoint("CENTER", b, "CENTER", 0, 0) end
    if b.V then b.V:SetPoint("CENTER", b, "CENTER", 0, 0) end
    b:SetScript("OnEnter", NudgeEnter)
    b:SetScript("OnLeave", NudgeLeave)
    b:SetScript("OnClick", NudgeClick)
    b:Hide()
    if i == 1 then insp.NudgeA = b else insp.NudgeB = b end
  end

  local link = CreateFrame("Button", nil, insp)
  link.hover = false
  link.Label = T.CreateText(link, "secondary")
  link.Label:SetPoint("TOPLEFT", link, "TOPLEFT", 0, 0)
  link.Label:SetWordWrap(false)
  link.Line = link:CreateTexture(nil, "ARTWORK")
  link.Line:SetTexture(WHITE)
  link.Line:SetHeight(1)
  link.Line:SetPoint("TOPLEFT", link.Label, "BOTTOMLEFT", 0, -1)
  link.Line:SetPoint("TOPRIGHT", link.Label, "BOTTOMRIGHT", 0, -1)
  link:SetScript("OnEnter", LinkEnter)
  link:SetScript("OnLeave", LinkLeave)
  link:SetScript("OnClick", LinkClick)
  link:Hide()
  insp.Reset = link

  local key = InspPlate(insp, "Frame", false)
  TintPlate(key, PLATE.key.fill, PLATE.key.ring)
  key:SetHeight(P.KEY_H)
  key.Label = T.CreateText(key, "secondary")
  key.Label:SetPoint("CENTER", key, "CENTER", 0, 0)
  key.Label:SetWordWrap(false)
  Grey(key.Label, 0.87)
  key:Hide()
  insp.Key = key

  -- The side it docks on is looked at again after every mouse release while
  -- it is up: a window dragged to the screen's edge, or widened, is only
  -- ever moved by a press that ends.
  insp:SetScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_UP") end)
  insp:SetScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_UP") end)
  insp:SetScript("OnEvent", function(self)
    if AR.host then AR.Dock(self, AR.host) end
  end)
  -- A new frame starts shown: hidden now, so the first Show fires OnShow.
  insp:Hide()
  if ns.Skin and ns.Skin.Refresh then pcall(ns.Skin.Refresh, insp) end
  AR._insp = insp
  return insp
end

-- Beside the host's window, its top level with the window's top row (the
-- host's DockTop), on the right unless the screen has no room there and
-- more on the left. Anchored to the window, so it follows the window while
-- it is dragged; re-anchored only when the side or the row moved.
function AR.Dock(insp, host)
  local dock = (host.Dock and host.Dock()) or host.owner
  if not (insp and dock) then return end
  local left, right, top = dock:GetLeft(), dock:GetRight(), dock:GetTop()
  if not (left and right and top) then return end
  local P = INSP
  local dy = 0
  local row = host.DockTop and host.DockTop()
  local rowTop = row and row:GetTop()
  if rowTop then dy = math.floor(rowTop - top + 0.5) end
  local ds = dock:GetEffectiveScale() or 1
  local us = UIParent:GetEffectiveScale() or 1
  local screen = (UIParent:GetRight() or 0) * us
  local need = (P.DOCK + P.W) * (insp:GetEffectiveScale() or 1)
  local roomRight, roomLeft = screen - right * ds, left * ds
  local side = (roomRight >= need or roomRight >= roomLeft) and 1 or -1
  if insp.side == side and insp.dockTo == dock and insp.dy == dy then return end
  insp.side, insp.dockTo, insp.dy = side, dock, dy
  insp:ClearAllPoints()
  if side == 1 then
    insp:SetPoint("TOPLEFT", dock, "TOPRIGHT", P.DOCK, dy)
  else
    insp:SetPoint("TOPRIGHT", dock, "TOPLEFT", -P.DOCK, dy)
  end
end

-------------------------------------------------------------
-- 8b. Filling it
--
-- Top down from `y` (the card's own, negative downward); each Put answers
-- the y under what it placed.
-------------------------------------------------------------

local function At(region, x, y)
  region:ClearAllPoints()
  region:SetPoint("TOPLEFT", AR._insp, "TOPLEFT", x, y)
end

local function PutText(fs, text, y)
  At(fs, INSP.PAD, y)
  fs:Show()
  return y - Measured(fs, text, true)
end

-- A kicker in capitals; one that does not fit the width (a long German one)
-- takes a second line rather than losing its end.
local function PutKicker(text, y)
  local k = AR._insp.Kicker
  y = y - INSP.KICK_TOP
  At(k, INSP.PAD, y)
  k:Show()
  return y - Measured(k, Upper(text), true) - INSP.KICK_GAP
end

local function PutRule(rule, y)
  rule:ClearAllPoints()
  rule:SetPoint("TOPLEFT", AR._insp, "TOPLEFT", INSP.PAD, y)
  rule:SetPoint("TOPRIGHT", AR._insp, "TOPRIGHT", -INSP.PAD, y)
  rule:Show()
end

local function PutNote(text, y)
  local insp = AR._insp
  y = y - INSP.NOTE_TOP
  PutRule(insp.NoteRule, y)
  return PutText(insp.Note, text, y - 1 - INSP.NOTE_PAD)
end

-- The eye switch at the row's left; answers its width.
local function PutSwitch(on, y)
  local insp, P = AR._insp, INSP
  local sw = insp.Switch
  local text = L()[on and "ARRANGE_SHOWN" or "ARRANGE_HIDDEN_STATE"]
  local w = P.SWITCH_LEAD + Measured(insp.MeasureSegment, text, false) + P.SWITCH_TAIL
  sw.on = on and true or false
  sw.Label:SetText(text)
  sw:SetWidth(w)
  At(sw, P.PAD, y)
  PaintSwitch(sw)
  sw:Show()
  return w
end

-- Move and its two arrows at the row's right: left and right for a column,
-- up and down for a block, each live only where there is a place to go.
-- `used` is the width the row's left already has (the switch); where the
-- words and the arrows do not fit beside it, they take a row of their own
-- under it. Answers the y under the row.
local function PutMove(y, vertical, back, forward, used)
  local insp, P = AR._insp, INSP
  local text = L()["ARRANGE_MOVE"]
  local need = Measured(insp.MeasureBody, text, false) + P.MOVE_GAP + 2 * P.NUDGE_W + P.NUDGE_GAP
  local rowY = y
  if used > 0 and used + P.MOVE_GAP + need > P.INNER then rowY = y - P.SWITCH_H - P.ROW_WRAP end
  local a, b = insp.NudgeA, insp.NudgeB
  local ny = rowY - (P.SWITCH_H - P.NUDGE_H) / 2
  b:ClearAllPoints()
  b:SetPoint("TOPRIGHT", insp, "TOPLEFT", P.PAD + P.INNER, ny)
  a:ClearAllPoints()
  a:SetPoint("TOPRIGHT", b, "TOPLEFT", -P.NUDGE_GAP, 0)
  a.vertical, a.live = vertical, back and true or false
  b.vertical, b.live = vertical, forward and true or false
  PaintNudge(a)
  PaintNudge(b)
  a:Show()
  b:Show()
  local label = insp.MoveLabel
  label:ClearAllPoints()
  label:SetPoint("RIGHT", a, "LEFT", -P.MOVE_GAP, 0)
  label:SetText(text)
  label:Show()
  return rowY - P.SWITCH_H
end

local function PutRadio(i, choice, chosen, live, y)
  local insp = AR._insp
  local row = insp.Radios[i] or Radio(insp, i)
  row.choiceId, row.chosen, row.live = choice.id, chosen, live
  row.hover = row.hover and row:IsMouseOver() or false
  Th().FitText(row.Text, INSP.INNER - INSP.RADIO_TEXT, choice.name, row)
  At(row, INSP.PAD, y)
  PaintRadio(row)
  row:Show()
  return y - INSP.RADIO_H
end

-- A line of the stack's order: its place and its name, the selected block
-- in the accent.
local function PutOrderLine(i, name, selected, y)
  local insp, T = AR._insp, Th()
  local num, text = insp.OrderNum[i], insp.OrderName[i]
  if not num then
    num, text = Line(insp.Art, "body"), Line(insp.Art, "body")
    insp.OrderNum[i], insp.OrderName[i] = num, text
  end
  num:SetFormattedText("%d", i)
  At(num, INSP.PAD, y)
  At(text, INSP.PAD + INSP.LINE_NUM, y)
  T.FitText(text, INSP.INNER - INSP.LINE_NUM, name, nil)
  if selected then
    T.SetColor(num, "accent")
    T.SetColor(text, "accent")
  else
    T.SetColor(num, "textSecondary")
    T.SetColor(text, "textSecondary")
  end
  num:Show()
  text:Show()
  return y - INSP.LINE_H
end

-- The hidden list, flowing left to right in rows; the host's own are put
-- through the same function (host.ListHidden).
local chipsN, chipsX, chipsY = 0, 0, 0

local function PutHidden(kind, key, name)
  local insp, P = AR._insp, INSP
  chipsN = chipsN + 1
  local chip = insp.Chips[chipsN] or HiddenChip(insp, chipsN)
  chip.kind, chip.key = kind, key
  chip.hover = chip:IsMouseOver() and true or false
  local lead = P.CHIP_LEAD + P.CHIP_EYE + P.CHIP_EYE_GAP
  local w = math.min(lead + Measured(insp.MeasureBody, name, false) + P.CHIP_TAIL, P.INNER)
  if chipsX > P.PAD and chipsX + w > P.PAD + P.INNER then
    chipsX = P.PAD
    chipsY = chipsY - P.CHIP_H - P.CHIP_GAP
  end
  chip:SetWidth(w)
  Th().FitText(chip.Label, w - lead - P.CHIP_TAIL + 1, name, chip)
  At(chip, chipsX, chipsY)
  PaintHiddenChip(chip)
  chip:Show()
  chipsX = chipsX + w + P.CHIP_GAP
end

local function CountHidden()
  chipsN = chipsN + 1
end

-- The foot: the reset on the left, the key cap and "to finish" on the right,
-- each centred on a row the key cap's height -- the right-hand pair on a
-- row of its own under the reset where the two do not fit side by side.
local function PutFoot(y)
  local insp, P = AR._insp, INSP
  y = y - P.FOOT_TOP
  PutRule(insp.FootRule, y)
  y = y - 1 - P.FOOT_PAD
  local link, key, finish = insp.Reset, insp.Key, insp.Finish
  local resetText, keyText, finishText = L()["ARRANGE_RESET"], L()["ARRANGE_ESC_KEY"], L()["ARRANGE_ESC_FINISH"]
  local linkW = Measured(insp.MeasureSmall, resetText, false)
  local keyW = Measured(insp.MeasureSmall, keyText, false) + 2 * P.KEY_PAD
  local finishW = Measured(insp.MeasureSmall, finishText, false)
  local lineH = Measured(insp.MeasureSmall, resetText, true)
  link.Label:SetText(resetText)
  link:SetSize(linkW, lineH + 2)
  link:ClearAllPoints()
  link:SetPoint("LEFT", insp, "TOPLEFT", P.PAD, y - P.KEY_H / 2)
  PaintLink(link)
  link:Show()
  local rowY = y
  if linkW + P.FOOT_GAP + keyW + P.KEY_GAP + finishW > P.INNER then
    rowY = y - P.KEY_H - P.KEY_GAP
  end
  finish:SetText(finishText)
  finish:ClearAllPoints()
  finish:SetPoint("RIGHT", insp, "TOPLEFT", P.PAD + P.INNER, rowY - P.KEY_H / 2)
  finish:Show()
  key.Label:SetText(keyText)
  key:SetWidth(keyW)
  key:ClearAllPoints()
  key:SetPoint("RIGHT", finish, "LEFT", -P.KEY_GAP, 0)
  key:Show()
  return rowY - P.KEY_H
end

-- With nothing selected: how the mode works (or, while something is in the
-- hand, what is moving), what is hidden, and the foot.
local function FillOverview(host, y)
  local insp, P = AR._insp, INSP
  local lead = AR.moving and MovingText(AR.moving) or L()["ARRANGE_OVERVIEW"]
  y = PutText(insp.Lead, lead, y)
  -- What is hidden: the columns, then the host's own -- counted first, so
  -- the kicker says whether a click shows them.
  local layout = AR.Layout()
  chipsN = 0
  if layout then
    for i = 1, #layout do
      local spec = AR.COLUMNS[layout[i].id]
      if spec and not layout[i].shown and not spec.fixed then chipsN = chipsN + 1 end
    end
  end
  if host.ListHidden then host.ListHidden(CountHidden) end
  y = PutKicker(L()[chipsN > 0 and "ARRANGE_HIDDEN_CLICK" or "ARRANGE_HIDDEN"], y)
  if chipsN == 0 then return PutFoot(PutText(insp.Empty, L()["ARRANGE_HIDDEN_NONE"], y)) end
  chipsN, chipsX, chipsY = 0, P.PAD, y
  if layout then
    for i = 1, #layout do
      local entry = layout[i]
      local spec = AR.COLUMNS[entry.id]
      if spec and not entry.shown and not spec.fixed then PutHidden("column", entry.id, L()[spec.title]) end
    end
  end
  if host.ListHidden then host.ListHidden(PutHidden) end
  return PutFoot(chipsY - P.CHIP_H)
end

-- A column's card.
local function FillColumn(id, y)
  local insp, P = AR._insp, INSP
  local spec = AR.COLUMNS[id]
  local layout = AR.Layout()
  local shown = layout and layout.shown[id] or false
  local k = layout and IndexOf(layout, id) or 1
  y = PutText(insp.Lead, L()[spec.desc], y) - P.ROW_GAP
  local used = 0
  if not spec.fixed then used = PutSwitch(shown, y) end
  y = PutMove(y, false, k > 1, layout ~= nil and k < #layout, used)
  local choices, current, set = AR.Choices(spec.choice)
  insp.set = set
  if #choices > 0 then
    y = PutKicker(L()["COL_SHOW"], y)
    for i = 1, #choices do
      y = PutRadio(i, choices[i], choices[i].id == current, shown and true or false, y)
    end
  end
  -- A figure's place beside the subject says what a mail without it does.
  if spec.figure and layout then
    local at = IndexOf(layout, "subject") or 0
    y = PutNote(L()[k < at and "ARRANGE_NOTE_LEFT" or "ARRANGE_NOTE_RIGHT"], y)
  end
  return y
end

-- A block's card: the host's words for it, the grid's switch, Move up and
-- down, and the stack's order.
local function FillBlock(host, id, y)
  local insp, P = AR._insp, INSP
  y = PutText(insp.Lead, host.BlockText(id), y) - P.ROW_GAP
  local used = 0
  local on = host.BlockShown and host.BlockShown(id)
  if on ~= nil then used = PutSwitch(on, y) end
  y = PutMove(y, true, host.CanMoveBlock(id, -1), host.CanMoveBlock(id, 1), used)
  y = PutKicker(L()["ARRANGE_UNDER_LIST"], y)
  local order = host.StackOrder()
  for i = 1, #order do y = PutOrderLine(i, host.BlockName(order[i]), order[i] == id, y) end
  local note = host.BlockNote and host.BlockNote(id)
  if note then y = PutNote(note, y) end
  return y
end

local function HideParts(insp)
  insp.Lead:Hide()
  insp.Empty:Hide()
  insp.Note:Hide()
  insp.Kicker:Hide()
  insp.MoveLabel:Hide()
  insp.NoteRule:Hide()
  insp.FootRule:Hide()
  insp.Finish:Hide()
  insp.Switch:Hide()
  insp.NudgeA:Hide()
  insp.NudgeB:Hide()
  insp.Reset:Hide()
  insp.Key:Hide()
  for i = 1, #insp.Radios do insp.Radios[i]:Hide() end
  for i = 1, #insp.Chips do insp.Chips[i]:Hide() end
  for i = 1, #insp.OrderNum do
    insp.OrderNum[i]:Hide()
    insp.OrderName[i]:Hide()
  end
end

-- The inspector filled again for what is selected now, if it is up. Called
-- after anything it shows may have changed; a block the view no longer has
-- is let go first.
function AR.Inspect()
  local insp, host = AR._insp, AR.host
  if not (insp and host and insp:IsShown()) then return end
  local P, T = INSP, Th()
  if AR.selKind == "block" and not (host.BlockPresent and host.BlockPresent(AR.selId)) then
    AR.selKind, AR.selId = nil, nil
    AR.UpdateFocus()
  end
  local kind, id = AR.selKind, AR.selId
  if AR.moving then kind = nil end
  HideParts(insp)
  local title
  if kind == "column" then
    title = L()[AR.COLUMNS[id].title]
  elseif kind == "block" then
    title = host.BlockName(id)
  else
    title = L()["ARRANGE_TITLE"]
  end
  T.FitText(insp.Title, P.INNER - P.CLOSE, title, nil)
  local y = -P.TOP - math.max(Measured(insp.Title, title, true), P.CLOSE - 4) - P.HEAD_GAP
  if kind == "column" then
    y = FillColumn(id, y)
  elseif kind == "block" then
    y = FillBlock(host, id, y)
  else
    y = FillOverview(host, y)
  end
  insp:SetHeight(math.ceil(-y + P.BOTTOM))
end

-- Up beside the host's window, on the overview.
function AR.ShowInspector(host)
  local insp = AR._insp or AR.BuildInspector()
  insp.side = nil
  AR.Dock(insp, host)
  insp:Show()
  AR.Inspect()
end

-------------------------------------------------------------
-- 9. Opening and closing
--
-- A host is the list being arranged: { owner = its frame, PlaceStrip(strip),
-- OnEnter(strip), OnLeave(), Rise() (optional: its cards settle in, played
-- once as the mode opens), toggle = the key that opened it }. The Mail
-- tab's is CollectTab's CT.ArrangeHost; Mail Memory's is its own. One at a
-- time: opening one closes the other.
--
-- For the inspector a host may also answer: Dock() (the window it docks
-- beside; the owner if absent) and DockTop() (the top row it lines up
-- with); ListHidden(put) (put(kind, key, name) for each hidden thing of
-- its own) and ShowHidden(kind, key). A host with blocks under its list
-- answers for them by id: BlockPresent, BlockName, BlockText, BlockNote
-- (or nil), BlockShown (a switch's state, or nil for none), SetBlockShown,
-- CanMoveBlock(id, step), MoveBlock(id, step), StackOrder() and
-- PaintBlocks() (the selection's ring moved).
-------------------------------------------------------------

function AR.Enter(host)
  if not host or AR.host == host then return end
  if AR.host then AR.Leave() end
  local strip = host.strip or AR.BuildStrip(host)
  AR.host = host
  AR.hover, AR.focus, AR.drag = nil, nil, nil
  AR.selKind, AR.selId, AR.moving = nil, nil, nil
  strip:Show()
  if host.OnEnter then host.OnEnter(strip) end
  AR.LayoutStrip(host)
  AR.CatchEscape(true)
  if host.toggle then AR.PaintToggle(host.toggle) end
  AR.RowsChanged(false)
  -- The host's cards settle into place, once (AR.Rise).
  if host.Rise then host.Rise() end
  AR.ShowInspector(host)
end

function AR.Leave()
  local host = AR.host
  if not host then return end
  AR.CancelPress()
  local drag = AR.drag
  AR.drag = nil
  if drag then drag.chip:SetFrameLevel(drag.level) end
  AR.selKind, AR.selId, AR.moving = nil, nil, nil
  AR.host = nil
  if AR._insp then AR._insp:Hide() end
  AR.hover, AR.focus = nil, nil
  AR.CatchEscape(false)
  if host.strip then
    host.strip.Ghost:Hide()
    host.strip:Hide()
  end
  if host.OnLeave then host.OnLeave() end
  if host.toggle then AR.PaintToggle(host.toggle) end
  -- A card that went with the mode may have had the pointer.
  AR.MoveCursor(false)
  AR.RowsChanged(false)
end

-- The mode ends with the frame it was opened over.
function AR.LeaveIf(owner)
  if AR.host and AR.host.owner == owner then AR.Leave() end
end
