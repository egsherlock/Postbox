local _, ns = ...

-------------------------------------------------------------
-- Postbox :: the arrange mode.
--
-- A mail row's columns -- the read mark, the item's icon, the sender, the
-- subject, the time left, the gold, the slots -- in the player's own order,
-- each shown or hidden, arranged right where the rows are. The layout mark
-- beside the options cog opens it (the cog key; the same key stands in Mail
-- Memory's title bar); a column header then takes the top row's place, one
-- heading standing exactly over each column, placed from the lanes the rows
-- are laid on, with faint lines down the boundaries through the rows. Take
-- a column by its heading or on any row and drag it: its lane lifts and
-- rides over the list, the others slide aside and the rows re-lay as it
-- crosses them; let go and it snaps into its slot. Click a heading, a row's
-- column or a block under the list to select it: the inspector docked
-- beside the window shows its card -- show or hide it, its own choices,
-- Move for the no-drag way -- and the rows show the column; for the
-- subject, how far each row's runs and why. With nothing selected the
-- inspector says how the mode works, lists what is hidden and offers the
-- reset. The category buttons under the list take the same drag and a
-- click to hide or show while the mode is open. The key, lit as Done while
-- the mode is open, Escape, or the window going away all end it, and the
-- top row comes back as it was.
--
-- One arrangement for every list that draws mail rows: it is stored by
-- MailboxUI.GetRowLayout / SetRowLayout, and drawn by CollectTab's RV.Place,
-- which the Mail tab, its History and Mail Memory all go through. This file
-- owns only the mode: the header, the marks on the rows, the inspector, the
-- drag, the key, Escape.
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

-- The columns, in the words the header and the inspector use. `head` is the
-- glyph a heading wears in place of the name -- what the column draws, or
-- its sign -- where the column is too narrow for a word; `fixed` is the
-- subject, which takes whatever room the others leave and so cannot be
-- hidden; `choice` is the column's own setting; `figure`, a figure a mail
-- may not have.
AR.COLUMNS = {
  read    = { title = "COL_READ",       desc = "COL_READ_DESC",       head = "dot" },
  icon    = { title = "COL_ICON",       desc = "COL_ICON_DESC",       head = "icon" },
  sender  = { title = "COL_SENDER",     desc = "COL_SENDER_DESC" },
  subject = { title = "COL_SUBJECT",    desc = "COL_SUBJECT_DESC",    fixed = true },
  time    = { title = "OPT_ROW_EXPIRY", desc = "OPT_ROW_EXPIRY_DESC", choice = "expiry", figure = true, head = "clock" },
  money   = { title = "OPT_ROW_GOLD",   desc = "OPT_ROW_GOLD_DESC",   choice = "gold", figure = true, head = "coin" },
  slots   = { title = "OPT_ROW_SLOTS",  desc = "OPT_ROW_SLOTS_DESC", figure = true, head = "slot" },
}

-- The cog key (section 4): the cog's size at rest; lit, a check and Done on
-- a selected plate, `KEY_LEAD` in, the check's width and `KEY_GAP`, the
-- word, and `KEY_TAIL` after it, both lifted `KEY_LIFT` off the plate's
-- middle: a word with no descenders sits a unit low in a line box centred
-- on an 18-unit plate whose foot is the underline.
local KEY_SIZE = 18
local KEY_MARK = 12
local KEY_CHECK = 8
local KEY_LEAD, KEY_GAP, KEY_TAIL = 6, 4, 7
local KEY_LIFT = 1
-- The mark's grey at rest: the chrome's quietest text grey, as near as the
-- palette comes to the mockup's #a2a2a2, so the accent cog beside it is the
-- louder of the two at a glance.
local KEY_REST = "textDisabled"

-- Who is arranging (a host, below), and what the rows' marks point at: the
-- heading pointed at, the column the marks show, the column in the hand;
-- and the column the pointer is over in the rows, whose heading lights.
AR.host = nil
AR.hover = nil
AR.focus = nil
AR.drag = nil
AR.rowHover = nil
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
  AR.RowsChanged(true)
  if AR.host then AR.LayoutStrip(AR.host) end
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

-- The column the rows mark (section 7b): the one being dragged, else the one
-- whose heading is under the cursor, else the selected one. Only while the
-- mode is open.
function AR.Focus()
  if not AR.host then return nil end
  return AR.focus
end

function AR.UpdateFocus()
  local focus = (AR.drag and AR.drag.id) or AR.hover
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

-- Selects a column or a block (a host's, by id) for the inspector's card;
-- the same thing again, or nil, goes back to the overview. What it was and
-- what it is are painted again, the rows' marks follow a column -- in the
-- accent once it is selected, even where the pointer already had them
-- showing it -- and the inspector is filled for it.
function AR.Select(kind, id)
  if not AR.host then return end
  if kind == nil or (AR.selKind == kind and AR.selId == id) then kind, id = nil, nil end
  local wasKind, wasId = AR.selKind, AR.selId
  AR.selKind, AR.selId = kind, id
  AR.PaintSelected(wasKind, wasId)
  AR.PaintSelected(kind, id)
  GameTooltip:Hide()
  local before = AR.focus
  AR.UpdateFocus()
  if AR.focus == before and before ~= nil and (before == id or before == wasId) then AR.RowsChanged(false) end
  AR.Inspect()
end

-- One selectable thing painted from its state: a column's heading, or the
-- host's blocks.
function AR.PaintSelected(kind, id)
  local host = AR.host
  if not (host and kind) then return end
  if kind == "column" then
    local head = host.strip and host.strip.heads[id]
    if head then AR.PaintHead(head) end
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
--   fold   the grid's placeholder while the option hides it: a dim fill;
--   head   a column's heading in the header, which is the card itself;
--   lane   the column's lane in the hand, over the list.
-- `hidden` is a small card's look while its button is hidden; `sel` and
-- `selHover` a block's while it is selected.
--
-- A spec is { fill = {grey, alpha}, wash = {grey, alpha}, accent = the
-- accent wash's alpha, ring = the ring's grey (nil: the accent), ringW,
-- top = the lit edge's alpha, drop = the shadow's length (0: none),
-- dropA = its alpha at the top }. Cards are made on first use and hidden
-- with the mode.
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
  -- A column's heading in the header (section 6): flat on the header until
  -- it is taken, then lifted; `dim` while the column has no lane in the
  -- list shown.
  head = {
    rest     = { wash = { 1, 0.05 }, ring = 0.48, drop = 0 },
    hover    = { wash = { 1, 0.10 }, ring = 0.86, drop = 0 },
    sel      = { accent = 0.10, drop = 0 },
    selHover = { accent = 0.15, drop = 0 },
    hand     = { fill = { 0.06, 0.97 }, accent = 0.10, ringW = 2, drop = 9, dropA = 0.6 },
    dim      = { wash = { 1, 0.02 }, ring = 0.29, drop = 0 },
    dimHover = { wash = { 1, 0.07 }, ring = 0.62, drop = 0 },
  },
  -- The column's lane in the hand, over the list (section 7a).
  lane = {
    hand     = { fill = { 0.06, 0.97 }, accent = 0.10, ringW = 2, drop = 10, dropA = 0.6 },
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
  local drop = s.drop or 4
  if drop <= 0 then
    card.Drop:Hide()
    return
  end
  card.Drop:SetHeight(drop)
  card.Drop:Show()
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
-- lit Done -- a check and the word on a selected plate, as the window's
-- selected tab and segments draw it -- which is the way out; right-click on
-- it goes back to the default arrangement. `place` anchors
-- it by its left edge, so the widening runs to the right; `getHost` answers
-- which list it arranges, and may bring that list forward first.
--
-- All of it is drawn on the key itself, a button of Postbox's own: nothing
-- is laid on the title bar or on any frame a skin repaints.
-------------------------------------------------------------

-- Every look the key has, from its state: at rest the mark alone; pointed
-- at, white on a plate (a 7% white fill, a grey ring, a black keyline);
-- lit, the house's selected plate (Theme's PaintPlate, from the same
-- palette): a dark fill with the accent's wash, the selected ring, a lit top
-- edge and the accent's underline, the check and Done in the accent's
-- selected-caption tone, in a black keyline that holds it over a bright
-- scene. Pointed at while lit, the plate's hover wash lifts it, as it lifts
-- a selected tab.
function AR.PaintToggle(button)
  if not button then return end
  local T = Th()
  local lit = AR.host ~= nil and AR.host.toggle == button
  local hover = button.hover and true or false
  local mark, check, label = button.Mark, button.Check, button.Label
  if lit then
    local C = T.Colors
    local fill, ring, bevel, lift = C.plateSelected, C.plateEdgeSelected, C.plateBevel, C.plateHighlight
    button.Fill:SetVertexColor(fill[1], fill[2], fill[3], fill[4])
    button.Fill:Show()
    AR.TintEdges(button.Ring, ring[1], ring[2], ring[3], ring[4])
    AR.ShowEdges(button.Ring, true)
    AR.TintEdges(button.Key, 0, 0, 0, 1)
    AR.ShowEdges(button.Key, true)
    local r, g, b = T.GetAccentTone("base")
    button.Wash:SetVertexColor(r, g, b, C.accentWash[4])
    button.Wash:Show()
    button.Base:SetVertexColor(r, g, b, 1)
    button.Base:Show()
    button.Bevel:SetVertexColor(bevel[1], bevel[2], bevel[3], bevel[4])
    button.Bevel:Show()
    button.Lift:SetVertexColor(lift[1], lift[2], lift[3], lift[4])
    button.Lift:SetShown(hover)
    if mark then mark:Hide() end
    if button.grip then button.grip:Hide() end
    if check then
      T.SetColor(check, "accentBright")
      check:Show()
    end
    T.SetColor(label, "accentBright")
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
  button.Wash:Hide()
  button.Base:Hide()
  button.Bevel:Hide()
  button.Lift:Hide()
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

-- The key's art, made once with the key. Back to front: the keyline, the
-- fill, the accent's wash, the ring, the lit top edge, the underline and
-- the hover wash, then the mark, the check and the word.
local function BuildKeyArt(button)
  local T = Th()
  button.Key = AR.NewEdges(button, "BACKGROUND", -7, 1, 1)
  button.Fill = button:CreateTexture(nil, "BACKGROUND", nil, -6)
  button.Fill:SetTexture(WHITE)
  button.Fill:SetAllPoints()
  button.Wash = button:CreateTexture(nil, "BACKGROUND", nil, -5)
  button.Wash:SetTexture(WHITE)
  button.Wash:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
  button.Wash:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
  button.Ring = AR.NewEdges(button, "BORDER", 0, 0, 1)
  button.Bevel = button:CreateTexture(nil, "BORDER", nil, 1)
  button.Bevel:SetTexture(WHITE)
  button.Bevel:SetHeight(1)
  button.Bevel:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
  button.Bevel:SetPoint("TOPRIGHT", button, "TOPRIGHT", -1, -1)
  -- The underline, two units tall inside the ring, as a selected tab's.
  button.Base = button:CreateTexture(nil, "BORDER", nil, 2)
  button.Base:SetTexture(WHITE)
  button.Base:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 1, 1)
  button.Base:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
  button.Base:SetHeight(2)
  button.Lift = button:CreateTexture(nil, "BORDER", nil, 3)
  button.Lift:SetTexture(WHITE)
  button.Lift:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
  button.Lift:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)

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
    button.Check:SetPoint("CENTER", button, "LEFT", KEY_LEAD + KEY_CHECK / 2, KEY_LIFT)
  end
  -- The plates' caption font, and its own shadow: light words on a dark
  -- plate, as every other caption in the window.
  button.Label = T.CreateText(button, "segment", "ARTWORK")
  button.Label:SetPoint("LEFT", button, "LEFT", KEY_LEAD + KEY_CHECK + KEY_GAP, KEY_LIFT)
  button.Label:SetWordWrap(false)
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
-- 6. The column header
--
-- While the mode is open, the list's top row steps aside (Inbox, History and
-- the search on the Mail tab; the box, its sort, the picker and the search
-- in Mail Memory) and a column header takes its place, so the list itself
-- does not move. The headings fill the row between them: each is its
-- column, from the line between its lane and the one before it (the row's
-- edge, for the first) to the line after it (where the room the rows keep
-- for their marks begins, for the last), GAP between two, the lanes being
-- the columns as RV.Place publishes them for the list (s.laneX, s.laneW,
-- from the row's left edge, which is the header's; s.lead and s.laneEnd,
-- where the arrangement's room begins and ends). A heading's glyph or name
-- stands over its lane, not in the middle of its box. The narrow figures
-- wear glyphs -- the clock, the coin, the slots -- with their names in the
-- tooltip and the inspector; the subject's heading carries the stretch
-- arrow across the room it takes.
--
-- A hidden column is a peg on the header where it stands; a click shows it
-- again, there. A shown one with no lane in this list -- no mail listed has
-- it, or the list has no such column -- keeps a narrow dimmed heading in
-- its place. Pegs and narrow headings take room of their own: out of the
-- subject's heading where they stand beside the subject, out of the
-- headings either side of them otherwise, and the heading beside them ends
-- GAP before them. With no lanes at all -- an empty list, or Larger mail
-- rows, whose figures are a line of text -- the header keeps the one-line
-- order at widths of its own, pegs among them.
--
-- Headings are movable things (section 3b): at rest, pointed at, selected,
-- in the hand. A press on one, or on its column in any row (section 7a), is
-- the column's: a drag moves it, a click selects it for the inspector.
--
-- Built the first time the mode opens over a list, and laid out again after
-- every pass of the list's rows (AR.ListPlaced): the lanes are the rows'.
-- Every table the layout fills is made with the header.
-------------------------------------------------------------

local HEAD = {
  PAD = 3,          -- a row's mark of a column stands this far out from its lane
  GAP = 2,          -- between two headings
  PEG = 12,         -- a hidden column's peg
  RUN_GAP = 1,      -- between pegs and narrow headings standing together
  TEXT = 4,         -- a name's inset from its heading's edges
  ARROW_GAP = 6,    -- the subject's name to its stretch arrow
  ARROW_MIN = 12,   -- the shortest stretch arrow drawn
  SUBJECT_MIN = 40, -- the subject's heading never gives up more than this
  KEEP = 12,        -- nor does any other heading, for a peg beside it
  -- A shown heading with no lane of its own.
  NARROW = { read = 14, icon = 22, sender = 44, subject = 60, time = 22, money = 22, slots = 22 },
  -- Every heading's width where the list publishes no lanes.
  FALLBACK = { read = 14, icon = 24, sender = 72, time = 22, money = 40, slots = 42 },
}
AR.HEAD = HEAD

-- The native gold coin, where the client has the file.
local COIN_ART = "Interface\\MoneyFrame\\UI-GoldIcon"

function AR.CoinArt()
  if AR._coin == nil then
    local id
    if type(GetFileIDFromPath) == "function" then
      local ok, found = pcall(GetFileIDFromPath, COIN_ART)
      if ok then id = found end
    end
    AR._coin = (type(id) == "number" and id > 0) and COIN_ART or false
  end
  return AR._coin or nil
end

-- A heading's tooltip: its column's name, and how to take it. Not over the
-- selected one, whose card is in the inspector, nor during a drag.
local function HeadTip(head)
  if AR.drag then return end
  if AR.Selected("column", head.colId) then return end
  GameTooltip:SetOwner(head, "ANCHOR_TOP")
  GameTooltip:SetText(L()[AR.COLUMNS[head.colId].title])
  GameTooltip:AddLine(L()["ARRANGE_HEADING_TIP"], 1, 1, 1, true)
  if head.narrow then GameTooltip:AddLine(L()["ARRANGE_HEADING_EMPTY"], 0.7, 0.7, 0.7, true) end
  GameTooltip:Show()
end

-- Every look a heading has, from its state: the lift's (section 3b), then
-- its name or glyph -- white while it is pointed at, selected or in the
-- hand, a lighter grey at rest, dimmed while it has no lane -- and the
-- subject's arrow, in the accent while selected.
function AR.PaintHead(head)
  local T = Th()
  local id = head.colId
  local hand = AR.drag ~= nil and AR.drag.id == id
  local sel = AR.Selected("column", id)
  local hover = head.hover or AR.rowHover == id
  local state
  if hand then
    state = "hand"
  elseif sel then
    state = hover and "selHover" or "sel"
  elseif head.narrow then
    state = hover and "dimHover" or "dim"
  else
    state = hover and "hover" or "rest"
  end
  AR.PaintCard(head, state)
  local lit = hand or sel or hover
  local dim = head.narrow and not lit
  local grey = dim and 0.45 or (lit and 1 or 0.9)
  if head.Text then head.Text:SetTextColor(grey, grey, grey, 1) end
  local glyph = head.Glyph
  if glyph then
    if head.glyphKind == "dot" then
      T.SetColor(glyph, dim and "textDisabled" or "unread")
    elseif head.glyphKind == "clock" or head.glyphKind == "slot" then
      glyph:SetVertexColor(grey, grey, grey, 1)
    else
      glyph:SetDesaturated(dim and true or false)
      glyph:SetAlpha(dim and 0.55 or 1)
    end
  end
  local arrow = head.Stretch
  if arrow then
    local r, g, b = 0.6, 0.6, 0.6
    if hand or sel then
      r, g, b = T.GetAccent()
    elseif hover then
      r, g, b = 0.8, 0.8, 0.8
    end
    for k = 1, 3 do arrow[k]:SetVertexColor(r, g, b, 1) end
  end
end

-- A heading's glyph or name where it stands (`_cx`, the glyph's middle,
-- and `_tx`, the name's start, both from the heading's left), and the name
-- and the subject's arrow fitted to its width: again only when one of them
-- changes (AR.LayoutStrip).
function AR.FitHead(head)
  local glyph = head.Glyph
  if glyph then
    glyph:ClearAllPoints()
    glyph:SetPoint("CENTER", head, "LEFT", head._cx or 0, 0)
  end
  local text = head.Text
  if not text then return end
  local w, tx = head._w or 0, head._tx or HEAD.TEXT
  text:ClearAllPoints()
  text:SetPoint("LEFT", head, "LEFT", tx, 0)
  local room = math.max(w - tx - HEAD.TEXT, 1)
  Th().FitText(text, room, head.caption, head)
  local arrow = head.Stretch
  if not arrow then return end
  local measure = head.Measure
  measure:SetText(head.caption)
  local from = tx + math.min(math.ceil(measure:GetStringWidth() or 0), room) + HEAD.ARROW_GAP
  local show = w - HEAD.TEXT - from >= HEAD.ARROW_MIN
  arrow[1]:ClearAllPoints()
  arrow[1]:SetPoint("LEFT", head, "LEFT", from, 0)
  for k = 1, 3 do arrow[k]:SetShown(show) end
end

-- Where a heading's glyph and name stand in its box (above): over its
-- column's lane where the list has one, else its glyph in the middle and
-- its name at the inset; a glyph is kept inside the box.
function AR.HeadContent(head, lx, lw, w)
  local cx, tx = w / 2, HEAD.TEXT
  if lx and lw and lw > 0 then
    cx = lx + lw / 2
    tx = math.max(lx, HEAD.TEXT)
  end
  local half = head.glyphHalf or 0
  cx = math.max(math.min(cx, w - half - 1), half + 1)
  return cx, tx
end

local function HeadEnter(self)
  self.hover = true
  AR.hover = self.colId
  AR.PaintHead(self)
  AR.UpdateFocus()
  HeadTip(self)
  AR.MoveCursor(true)
end

local function HeadLeave(self)
  self.hover = false
  if AR.hover == self.colId then AR.hover = nil end
  AR.PaintHead(self)
  AR.UpdateFocus()
  GameTooltip:Hide()
  -- A column in the hand keeps the move cross wherever it passes.
  if not AR.drag then AR.MoveCursor(false) end
end

local function HeadDown(self, button)
  if button ~= "LeftButton" then return end
  local host = AR.host
  if host and host.strip == self:GetParent() then AR.PressColumn(host, self.colId, self) end
end

-- One heading: a lifted card with the column's glyph, or its name.
local function BuildHead(strip, id)
  local T = Th()
  local spec = AR.COLUMNS[id]
  local head = AR.NewCard(strip, "head")
  head.colId = id
  head:SetHeight(T.Metrics.tileHeight)
  head:EnableMouse(true)
  local kind = spec.head
  local glyph
  if kind == "dot" then
    local size = (ns.CollectTab and ns.CollectTab.RowRules and ns.CollectTab.RowRules.DOT or 8) - 1
    glyph = head:CreateTexture(nil, "ARTWORK")
    glyph:SetSize(size, size)
    glyph:SetTexture(WHITE)
    if type(head.CreateMaskTexture) == "function" then
      local mask = head:CreateMaskTexture()
      mask:SetTexture(ROUND_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
      mask:SetAllPoints(glyph)
      glyph:AddMaskTexture(mask)
    end
  elseif kind == "icon" then
    -- What the column shows: an item, in a black keyline.
    glyph = head:CreateTexture(nil, "ARTWORK", nil, 1)
    glyph:SetSize(11, 11)
    glyph:SetTexture(ICON_SAMPLE)
    glyph:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local key = head:CreateTexture(nil, "ARTWORK", nil, 0)
    key:SetTexture(WHITE)
    key:SetVertexColor(0, 0, 0, 1)
    key:SetSize(13, 13)
    key:SetPoint("CENTER", glyph, "CENTER", 0, 0)
  elseif kind == "clock" then
    glyph = T.Glyph and T.Glyph(head, "clock", 11, "ARTWORK") or nil
  elseif kind == "slot" then
    glyph = T.Glyph and T.Glyph(head, "slot", nil, "ARTWORK") or nil
  elseif kind == "coin" then
    local art = AR.CoinArt()
    if art then
      glyph = head:CreateTexture(nil, "ARTWORK")
      glyph:SetTexture(art)
      glyph:SetSize(11, 11)
    end
  end
  if glyph then
    glyph:SetPoint("CENTER", head, "CENTER", 0, 0)
    head.Glyph, head.glyphKind = glyph, kind
    head.glyphHalf = (glyph:GetWidth() or 0) / 2 + ((kind == "icon") and 1 or 0)
  else
    -- A name, and where its glyph's art is missing, the name too.
    head.caption = L()[spec.title]
    head.Text = T.CreateText(head, "value", "OVERLAY")
    head.Text:SetPoint("LEFT", head, "LEFT", HEAD.TEXT, 0)
    head.Text:SetJustifyH("LEFT")
    head.Text:SetWordWrap(false)
    head.Text:SetText(head.caption)
    -- Where the whole name is measured, whatever width the shown one has.
    head.Measure = T.CreateText(head, "value", "OVERLAY")
    head.Measure:Hide()
  end
  -- The subject's stretch arrow, in its three slices: the heads at the
  -- ends, the middle anchored between them.
  if spec.fixed and head.Text and T.Glyph then
    local l = T.Glyph(head, "stretch-left", nil, "ARTWORK")
    local m = T.Glyph(head, "stretch-mid", nil, "ARTWORK")
    local r = T.Glyph(head, "stretch-right", nil, "ARTWORK")
    if l and m and r then
      r:SetPoint("RIGHT", head, "RIGHT", -HEAD.TEXT, 0)
      m:SetPoint("LEFT", l, "RIGHT", 0, 0)
      m:SetPoint("RIGHT", r, "LEFT", 0, 0)
      head.Stretch = { l, m, r }
      l:SetPoint("LEFT", head, "LEFT", HEAD.TEXT, 0)
    end
  end
  head:SetScript("OnEnter", HeadEnter)
  head:SetScript("OnLeave", HeadLeave)
  head:SetScript("OnMouseDown", HeadDown)
  return head
end

-- A hidden column's peg: a dark plate with the crossed eye, lighter when
-- pointed at.
local function PaintPeg(peg)
  local hover = peg.hover
  local fill = hover and 0.12 or 0.063
  peg.Fill:SetVertexColor(fill, fill, fill, 0.95)
  local ring = hover and 0.62 or 0.353
  AR.TintEdges(peg.Ring, ring, ring, ring, 1)
  local eye = hover and 1 or 0.6
  if peg.Eye then peg.Eye:SetVertexColor(eye, eye, eye, 1) end
end

local function PegEnter(self)
  self.hover = true
  PaintPeg(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:SetText(L()[AR.COLUMNS[self.colId].title])
  GameTooltip:AddLine(L()["ARRANGE_PEG_TIP"], 1, 1, 1, true)
  GameTooltip:Show()
end

local function PegLeave(self)
  self.hover = false
  PaintPeg(self)
  GameTooltip:Hide()
end

local function BuildPeg(strip, id)
  local T = Th()
  local peg = CreateFrame("Button", nil, strip)
  peg.colId = id
  peg.hover = false
  peg:SetSize(HEAD.PEG, T.Metrics.tileHeight)
  peg:SetFrameLevel(strip:GetFrameLevel() + 6)
  peg.Fill = peg:CreateTexture(nil, "BACKGROUND")
  peg.Fill:SetTexture(WHITE)
  peg.Fill:SetAllPoints()
  peg.Key = AR.NewEdges(peg, "BORDER", 0, 1, 1)
  AR.TintEdges(peg.Key, 0, 0, 0, 1)
  peg.Ring = AR.NewEdges(peg, "BORDER", 1, 0, 1)
  peg.Eye = T.Glyph and T.Glyph(peg, "eye-off", 6, "ARTWORK") or nil
  if peg.Eye then peg.Eye:SetPoint("CENTER", peg, "CENTER", 0, 0) end
  peg:SetScript("OnEnter", PegEnter)
  peg:SetScript("OnLeave", PegLeave)
  peg:SetScript("OnClick", function(self) AR.ShowPeg(self) end)
  PaintPeg(peg)
  peg:Hide()
  return peg
end

function AR.BuildStrip(host)
  local T = Th()
  local strip = CreateFrame("Frame", nil, host.owner)
  strip:SetHeight(T.Metrics.tileHeight)
  host.PlaceStrip(strip)
  strip:Hide()
  strip.heads, strip.pegs = {}, {}
  -- The layout's working tables, made once: each column's heading x and
  -- width, its kind ("lane", "narrow", "peg"), its lane's own heading
  -- before the subject gives room away (where a row is hit), and whether
  -- it stands over its neighbours' edges.
  strip.bx, strip.bw, strip.kind, strip.hx, strip.hw, strip.over = {}, {}, {}, {}, {}, {}
  for id in pairs(AR.COLUMNS) do
    strip.heads[id] = BuildHead(strip, id)
    strip.pegs[id] = BuildPeg(strip, id)
  end
  strip.Ghost = AR.NewGhost(strip)
  strip.Ghost:SetFrameLevel(strip:GetFrameLevel() + 2)
  strip:SetScript("OnSizeChanged", function()
    if AR.host == host then AR.LayoutStrip(host) end
  end)
  host.strip = strip
  if ns.Skin and ns.Skin.Refresh then pcall(ns.Skin.Refresh, strip) end
  return strip
end

-- A run -- pegs and narrow headings standing together between two lanes'
-- headings -- and each one's width in it: a peg's; a narrow heading's own
-- beside the subject, where the subject gives the room, and a peg's width
-- elsewhere for one that wears a glyph.
local function RunWidth(strip, id, beside)
  if strip.kind[id] == "peg" then return HEAD.PEG end
  if not beside then
    local head = strip.heads[id]
    if head and head.Glyph then return HEAD.PEG end
  end
  return HEAD.NARROW[id] or 22
end

-- How much of its width a heading can give to a run beside it, and how
-- much of that lies outside its lane, a unit clear of it, on the run's side
-- (`after`: the run stands after it).
local function Spare(strip, id)
  if not id then return 0 end
  local keep = (id == "subject") and HEAD.SUBJECT_MIN or HEAD.KEEP
  return math.max((strip.bw[id] or 0) - keep, 0)
end

local function Free(strip, id, lx, lw, after)
  if not (id and lx and lw) then return 0 end
  local room
  if after then
    room = strip.bx[id] + strip.bw[id] - (lx + lw) - 1
  else
    room = lx - strip.bx[id] - 1
  end
  return math.min(math.max(room, 0), Spare(strip, id))
end

-- Each run, with room of its own: the room between the headings either side
-- of it (at the header's start, the room before the first heading; at its
-- end, none), and what that leaves it short from the headings beside it --
-- first what they have outside their lanes, then the subject's where it
-- stands beside the subject, then a name's column before a glyph's (a
-- name moved along its column still names it; a glyph moved off its column
-- does not), and last half from each, one giving what the other cannot. No
-- heading gives up more than it keeps (Spare), and the one that gives ends
-- GAP before the run. A run with room to spare stands against its lane (at
-- the header's start, the one after it), else in the middle of its room.
-- Only where both neighbours are down to what they keep does a run stand
-- over their edges, a few levels up.
function AR.PlaceRuns(layout, strip, span, laneX, laneW)
  local bx, bw, over = strip.bx, strip.bw, strip.over
  local n = #layout
  local i = 1
  while i <= n do
    if bx[layout[i].id] == nil then
      local a = (i > 1) and layout[i - 1].id or nil
      local j = i
      while j <= n and bx[layout[j].id] == nil do j = j + 1 end
      local b = (j <= n) and layout[j].id or nil
      local beside = a == "subject" or b == "subject"
      local total = -HEAD.RUN_GAP
      for k = i, j - 1 do total = total + RunWidth(strip, layout[k].id, beside) + HEAD.RUN_GAP end
      local left = a and (bx[a] + bw[a] + HEAD.GAP) or 0
      local right = b and (bx[b] - HEAD.GAP) or span
      local need = total - (right - left)
      if need > 0 then
        local capA, capB = Spare(strip, a), Spare(strip, b)
        local takeA = math.min(Free(strip, a, a and laneX[a], a and laneW[a], true), need)
        local takeB = math.min(Free(strip, b, b and laneX[b], b and laneW[b], false), need - takeA)
        local rest = need - takeA - takeB
        if rest > 0 and a == "subject" then
          local give = math.min(capA - takeA, rest)
          takeA, rest = takeA + give, rest - give
        elseif rest > 0 and b == "subject" then
          local give = math.min(capB - takeB, rest)
          takeB, rest = takeB + give, rest - give
        end
        if rest > 0 then
          local glyphA = not a or strip.heads[a].Glyph ~= nil
          local glyphB = not b or strip.heads[b].Glyph ~= nil
          if glyphA and not glyphB then
            local give = math.min(capB - takeB, rest)
            takeB, rest = takeB + give, rest - give
          elseif glyphB and not glyphA then
            local give = math.min(capA - takeA, rest)
            takeA, rest = takeA + give, rest - give
          end
        end
        if rest > 0 then
          local gb = math.min(capB - takeB, math.ceil(rest / 2))
          local ga = math.min(capA - takeA, rest - gb)
          gb = math.min(capB - takeB, rest - ga)
          takeA, takeB = takeA + ga, takeB + gb
        end
        if a then bw[a] = bw[a] - takeA end
        if b then bx[b], bw[b] = bx[b] + takeB, bw[b] - takeB end
        left, right = left - takeA, right + takeB
      end
      local x
      if not a then
        x = right - total
      elseif not b then
        x = left
      else
        x = math.floor((left + right - total) / 2 + 0.5)
      end
      x = math.max(0, math.min(x, span - total))
      local short = right - left < total
      for k = i, j - 1 do
        local id = layout[k].id
        local w = RunWidth(strip, id, beside)
        bx[id], bw[id], over[id] = x, w, short or nil
        x = x + w + HEAD.RUN_GAP
      end
      i = j
    else
      i = i + 1
    end
  end
end

-- The header laid out on the list's lanes (above), and put on screen: a
-- heading, or a peg, per column; the heading in the hand is left where the
-- cursor holds it and its slot takes the ghost. Anchored again only where
-- a place, a width or where its glyph and name stand changed.
function AR.LayoutStrip(host)
  local strip = host and host.strip
  local layout = AR.Layout()
  if not (strip and layout) then return end
  local width = strip:GetWidth() or 0
  if width < 60 then return end
  local n = #layout
  local spec = host.Spec and host.Spec()
  local laneX, laneW = spec and spec.laneX, spec and spec.laneW
  local lanes = laneX ~= nil and laneW ~= nil and laneW.subject ~= nil and laneX.subject ~= nil
  local bx, bw, kind, hx, hw = strip.bx, strip.bw, strip.kind, strip.hx, strip.hw
  local span = width
  for i = 1, n do
    local id = layout[i].id
    bx[id], bw[id], hx[id], hw[id], strip.over[id] = nil, nil, nil, nil, nil
    if not layout[i].shown and not AR.COLUMNS[id].fixed then
      kind[id] = "peg"
    elseif not lanes then
      kind[id] = "lane"
    elseif laneX[id] ~= nil and (laneW[id] or 0) > 0 then
      kind[id] = "lane"
    else
      kind[id] = "narrow"
    end
  end
  if lanes then
    -- Each lane's heading is its column: it ends on the line between its
    -- lane and the next, which stands in the middle of the gap between
    -- them, and the next starts GAP after that line.
    local from = spec.lead or 0
    span = math.max(spec.laneEnd or spec.width or width, from + 60)
    local prev
    for i = 1, n do
      local id = layout[i].id
      if kind[id] == "lane" then
        if prev then
          local line = math.floor((laneX[prev] + laneW[prev] + laneX[id]) / 2)
          bw[prev] = math.max(line - bx[prev], 1)
          bx[id] = line + HEAD.GAP
        else
          bx[id] = from
        end
        prev = id
      end
    end
    if prev then bw[prev] = math.max(span - bx[prev], 1) end
    for i = 1, n do
      local id = layout[i].id
      if kind[id] == "lane" then hx[id], hw[id] = bx[id], bw[id] end
    end
    AR.PlaceRuns(layout, strip, span, laneX, laneW)
  else
    -- No lanes: the one-line order at the header's own widths, pegs among
    -- them, the subject taking what they leave.
    local total, count = 0, 0
    for i = 1, n do
      local id = layout[i].id
      count = count + 1
      if kind[id] == "peg" then
        total = total + HEAD.PEG
      elseif id ~= "subject" then
        total = total + (HEAD.FALLBACK[id] or 40)
      end
    end
    local subjectW = math.max(width - total - HEAD.GAP * math.max(count - 1, 0), HEAD.SUBJECT_MIN)
    local x = 0
    for i = 1, n do
      local id = layout[i].id
      local w
      if kind[id] == "peg" then
        w = HEAD.PEG
      elseif id == "subject" then
        w = subjectW
      else
        w = HEAD.FALLBACK[id] or 40
      end
      bx[id], bw[id] = x, w
      x = x + w + HEAD.GAP
    end
  end
  strip.lanes, strip.span = lanes, span

  local drag = AR.drag
  for i = 1, n do
    local id = layout[i].id
    local head, peg = strip.heads[id], strip.pegs[id]
    if head and peg then
      if kind[id] == "peg" then
        head:Hide()
        if peg._x ~= bx[id] then
          peg:ClearAllPoints()
          peg:SetPoint("LEFT", strip, "LEFT", bx[id], 0)
          peg._x = bx[id]
        end
        peg:Show()
      else
        peg:Hide()
        local narrow = kind[id] == "narrow"
        local w = bw[id]
        local lx, lw
        if lanes and not narrow then lx, lw = laneX[id] - bx[id], laneW[id] end
        local cx, tx = AR.HeadContent(head, lx, lw, w)
        if head._w ~= w or head.narrow ~= narrow or head._cx ~= cx or head._tx ~= tx then
          head._w, head.narrow, head._cx, head._tx = w, narrow, cx, tx
          head:SetWidth(w)
          AR.FitHead(head)
        end
        if drag and drag.id == id then
          local ghost = strip.Ghost
          ghost:ClearAllPoints()
          ghost:SetPoint("LEFT", strip, "LEFT", bx[id], 0)
          ghost:SetSize(w, Th().Metrics.tileHeight)
          AR.PaintGhost(ghost)
          ghost:Show()
        else
          if head._x ~= bx[id] then
            head:ClearAllPoints()
            head:SetPoint("LEFT", strip, "LEFT", bx[id], 0)
            head._x = bx[id]
          end
          -- Over its neighbours' edges, a heading stands a few levels up.
          local level = strip:GetFrameLevel() + (strip.over[id] and 5 or 1)
          if head:GetFrameLevel() ~= level then head:SetFrameLevel(level) end
        end
        head:Show()
        AR.PaintHead(head)
      end
    end
  end
  if not drag then strip.Ghost:Hide() end
  AR.PlaceLines(host)
end

-------------------------------------------------------------
-- 7. Moving a column
--
-- By its heading or by its column on any row (section 7a), one press at a
-- time (section 2). The heading lifts and follows the cursor along the
-- header; past the middle of the heading beside it, the two change places
-- -- in the arrangement itself, so the rows re-lay under it and the header
-- stands on their new lanes, the heading's slot ringed. In the rows the
-- column rides in a lifted lane of its own over the list (7a), drawn
-- offset by as much as the heading is from its slot: each frame of the
-- drag moves that lane and its cells, and nothing is bound again unless
-- the order changed. A click selects the column.
-------------------------------------------------------------

-- The press in flight: one table of handlers for every column press, and
-- what they act on -- nothing is made per press.
local pressed = {}
local columnPress = {}

function columnPress.start(x0) AR.LiftColumn(pressed.host, pressed.id, x0) end
function columnPress.move(x) AR.DragColumn(pressed.host, x) end
function columnPress.drop() AR.DropColumn(pressed.host) end
function columnPress.cancel()
  local drag, ui = AR.drag, UI()
  if drag and drag.before and ui and ui.SetRowLayout then ui.SetRowLayout(drag.before) end
  AR.DropColumn(pressed.host)
  AR.RowsChanged(true)
end
function columnPress.click()
  if AR.host == pressed.host then AR.Select("column", pressed.id) end
end

function AR.PressColumn(host, id, frame)
  pressed.host, pressed.id = host, id
  columnPress.name = L()[AR.COLUMNS[id].title]
  AR.Press(frame, columnPress)
end

-- The rows bound again for a change in what the mode draws on them, when
-- the column they point at stayed the same (AR.UpdateFocus binds them
-- itself when it moved).
local function RefocusRows()
  local before = AR.focus
  AR.UpdateFocus()
  if AR.focus == before then AR.RowsChanged(false) end
end

function AR.LiftColumn(host, id, x0)
  if AR.host ~= host then return end
  local strip = host.strip
  local head = strip and strip.heads[id]
  if not (head and head:IsShown()) then return end
  GameTooltip:Hide()
  AR.drag = {
    id = id, head = head, grab = x0 - (head:GetLeft() or x0), level = head:GetFrameLevel(),
    x = head._x or 0, dx = 0,
    -- The arrangement as it was, for Escape to put back.
    before = CopyLayout(),
  }
  head:SetFrameLevel(strip:GetFrameLevel() + 20)
  -- Lifted a unit above and below its place.
  head:SetHeight(Th().Metrics.tileHeight + 2)
  AR.LayoutStrip(host)
  AR.ShowHand(host)
  RefocusRows()
end

-- The heading follows the cursor along the header, and the column's lane
-- follows it over the rows.
function AR.DragColumn(host, cursorX)
  local drag, strip = AR.drag, host.strip
  if not (drag and strip) then return end
  local head = drag.head
  local left = strip:GetLeft()
  if not left then return end
  local w = head._w or head:GetWidth() or 0
  local x = math.min(math.max(cursorX - left - drag.grab, 0), math.max((strip:GetWidth() or 0) - w, 0))
  if x ~= drag.x then
    drag.x = x
    head:ClearAllPoints()
    head:SetPoint("LEFT", strip, "LEFT", x, 0)
    head._x = nil
  end
  -- One place a frame: the lanes the next decision reads are the ones the
  -- rows have just been laid on.
  local layout = AR.Layout()
  local k = layout and IndexOf(layout, drag.id)
  local moved = false
  if k then
    local bx, bw = strip.bx, strip.bw
    local centre = x + w / 2
    local prev, nxt = layout[k - 1], layout[k + 1]
    local target
    if prev and bx[prev.id] and centre < bx[prev.id] + bw[prev.id] / 2 then target = k - 1 end
    if not target and nxt and bx[nxt.id] and centre > bx[nxt.id] + bw[nxt.id] / 2 then target = k + 1 end
    if target then
      AR.MoveColumn(k, target)
      AR.RowsChanged(true)
      moved = true
    end
  end
  local dx = x - (strip.bx[drag.id] or x)
  if moved or dx ~= drag.dx then
    drag.dx = dx
    AR.CarryRows(host, dx)
  end
end

function AR.DropColumn(host)
  local drag = AR.drag
  AR.drag = nil
  if not drag then return end
  local head = drag.head
  head:SetFrameLevel(drag.level)
  head:SetHeight(Th().Metrics.tileHeight)
  head._x = nil
  AR.HideHand(host)
  -- What the pointer is over is looked at again (the list's, next frame).
  AR.rowHover = nil
  if host and host.strip then
    host.strip.Ghost:Hide()
    AR.LayoutStrip(host)
  end
  local over = head:IsMouseOver()
  AR.hover = over and head.colId or nil
  AR.MoveCursor(over)
  RefocusRows()
  AR.PaintHead(head)
end

-------------------------------------------------------------
-- 7a. The list under the header
--
-- A frame of Postbox's own over the list's rows while the mode is open (the
-- cover), from under the header to the list's foot, a few levels above the
-- rows. It carries:
--   the lane lines   one faint line down each boundary between two lanes,
--                    from the header through the rows;
--   the press        on any row, the column whose lane is under the cursor
--                    (on a two-line row, whatever the row draws there) is
--                    taken as its heading would be; pointed at, its heading
--                    lights. So a click on a row does nothing else while
--                    the mode is open: nothing opens, nothing is collected;
--   the hand         while a column is dragged, its slot ringed down the
--                    list and the column riding offset in a lifted lane,
--                    its cells copied onto the lane from the rows.
-- The mouse wheel is not taken: the list still scrolls under it. Nothing
-- here runs while the mode is closed; pointed at, a check a frame of which
-- column is under the cursor, gone with the pointer.
-------------------------------------------------------------

-- Which column a press or the pointer on the list is over, or nil: by the
-- lanes where the rows have them, by what a two-line row draws otherwise.
local REGION_OF = { read = "Indicator", icon = "Icon", sender = "Sender", subject = "Subject" }

function AR.RegionAt(host, cx, cy)
  local pool = host.Pool and host.Pool()
  if not pool then return nil end
  for i = 1, #pool do
    local row = pool[i]
    if row:IsShown() then
      local top, bottom = row:GetTop(), row:GetBottom()
      if top and bottom and cy <= top and cy >= bottom then
        for id, key in pairs(REGION_OF) do
          local region = row[key]
          if region and region:IsShown() then
            local l, r = region:GetLeft(), region:GetRight()
            if l and r and cx >= l - 3 and cx <= r + 3 then return id end
          end
        end
        return nil
      end
    end
  end
  return nil
end

function AR.ColumnAt(host)
  local cover, strip = host.cover, host.strip
  local layout = AR.Layout()
  if not (cover and strip and layout) then return nil end
  local left = cover:GetLeft()
  if not left then return nil end
  local cx, cy = AR.Cursor(cover)
  if strip.lanes then
    local x = cx - left
    local hx, hw, kind = strip.hx, strip.hw, strip.kind
    for i = 1, #layout do
      local id = layout[i].id
      if kind[id] == "lane" and hx[id] and x >= hx[id] - 1 and x < hx[id] + hw[id] + 1 then return id end
    end
    return nil
  end
  if host.TwoLine and host.TwoLine() then return AR.RegionAt(host, cx, cy) end
  return nil
end

-- The column the pointer is over in the rows: its heading lights, and the
-- pointer is the move cross while it is over one.
function AR.SetRowHover(id)
  local was = AR.rowHover
  AR.rowHover = id
  local strip = AR.host and AR.host.strip
  if strip then
    if was and strip.heads[was] then AR.PaintHead(strip.heads[was]) end
    if id and strip.heads[id] then AR.PaintHead(strip.heads[id]) end
  end
  AR.MoveCursor(id ~= nil)
end

local function CoverUpdate(self)
  local host = AR.host
  if not (host and host.cover == self) or AR.drag then return end
  local id = AR.ColumnAt(host)
  if id ~= AR.rowHover then AR.SetRowHover(id) end
end

local function CoverEnter(self)
  self:SetScript("OnUpdate", CoverUpdate)
end

local function CoverLeave(self)
  self:SetScript("OnUpdate", nil)
  if AR.rowHover then AR.SetRowHover(nil) end
end

local function CoverDown(self, button)
  if button ~= "LeftButton" then return end
  local host = AR.host
  if not (host and host.cover == self) then return end
  local id = AR.ColumnAt(host)
  if id then AR.PressColumn(host, id, self) end
end

function AR.BuildCover(host)
  local scroll = host.Scroll and host.Scroll()
  local strip = host.strip
  if not (scroll and strip and host.List) then return nil end
  local cover = CreateFrame("Frame", nil, scroll:GetParent())
  cover:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, 0)
  cover:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 0, 0)
  cover:EnableMouse(true)
  cover.Lines = {}
  cover.Ghost = AR.NewGhost(cover)
  -- The lane in the hand: a lifted card (section 3b) whose cells ride on a
  -- frame of their own inside it, clipped to it.
  local hand = AR.NewCard(cover, "lane")
  if hand.SetClipsChildren then hand:SetClipsChildren(true) end
  hand.Cells = CreateFrame("Frame", nil, hand)
  hand.Cells:SetAllPoints()
  cover.Hand = hand
  cover:SetScript("OnEnter", CoverEnter)
  cover:SetScript("OnLeave", CoverLeave)
  cover:SetScript("OnHide", CoverLeave)
  cover:SetScript("OnMouseDown", CoverDown)
  cover:Hide()
  host.cover = cover
  return cover
end

-- A few levels over the rows and the list's pinned divider, whatever
-- raised the window since.
function AR.CoverLevel(host)
  local cover, list = host.cover, host.List and host.List()
  if not (cover and list) then return end
  local level = list:GetFrameLevel() + 12
  if cover:GetFrameLevel() ~= level then
    cover:SetFrameLevel(level)
    cover.Ghost:SetFrameLevel(level + 1)
    cover.Hand:SetFrameLevel(level + 3)
  end
end

local function NewLine(cover, i)
  local line = cover:CreateTexture(nil, "ARTWORK")
  line:SetTexture(WHITE)
  line:SetWidth(1)
  line:SetVertexColor(1, 1, 1, 0.13)
  cover.Lines[i] = line
  return line
end

-- One line down each boundary between two lanes, where the heading before
-- it ends (AR.LayoutStrip). None without lanes.
function AR.PlaceLines(host)
  local cover, strip = host.cover, host.strip
  if not (cover and strip) then return end
  local layout = AR.Layout()
  local count = 0
  if strip.lanes and layout then
    local hx, hw, kind = strip.hx, strip.hw, strip.kind
    local prev
    for i = 1, #layout do
      local id = layout[i].id
      if kind[id] == "lane" and hx[id] then
        if prev then
          count = count + 1
          local line = cover.Lines[count] or NewLine(cover, count)
          local x = hx[id] - HEAD.GAP
          if line._x ~= x then
            line:ClearAllPoints()
            line:SetPoint("TOPLEFT", cover, "TOPLEFT", x, 0)
            line:SetPoint("BOTTOMLEFT", cover, "BOTTOMLEFT", x, 0)
            line._x = x
          end
          line:Show()
        end
        prev = id
      end
    end
  end
  for i = count + 1, #cover.Lines do cover.Lines[i]:Hide() end
end

-- The dragged column's slot down the list, and its lane over it, offset by
-- as much as its heading is from the slot. Only where the rows have lanes.
function AR.PlaceHand(host)
  local cover, strip, drag = host.cover, host.strip, AR.drag
  local scroll = host.Scroll and host.Scroll()
  if not (cover and strip and drag and scroll) then return end
  local x, w = strip.hx[drag.id], strip.hw[drag.id]
  if not (strip.lanes and x and w) then
    cover.Hand:Hide()
    cover.Ghost:Hide()
    return
  end
  local ghost, hand = cover.Ghost, cover.Hand
  ghost:SetPoint("TOPLEFT", scroll, "TOPLEFT", x - 1, 3)
  ghost:SetPoint("BOTTOMLEFT", scroll, "BOTTOMLEFT", x - 1, 0)
  ghost:SetWidth(w + 2)
  hand:SetPoint("TOPLEFT", scroll, "TOPLEFT", x - 1 + drag.dx, 3)
  hand:SetPoint("BOTTOMLEFT", scroll, "BOTTOMLEFT", x - 1 + drag.dx, 0)
  hand:SetWidth(w + 2)
  ghost:Show()
  hand:Show()
end

function AR.ShowHand(host)
  local cover = host and host.cover
  if not cover then return end
  AR.PaintCard(cover.Hand, "hand")
  AR.PaintGhost(cover.Ghost)
  AR.PlaceHand(host)
end

function AR.HideHand(host)
  local cover = host and host.cover
  if not cover then return end
  cover.Hand:Hide()
  cover.Ghost:Hide()
end

-- A frame of the drag: the lane over the list, and every row's cell on it,
-- moved by `dx`. Nothing is bound again and nothing is made.
function AR.CarryRows(host, dx)
  AR.PlaceHand(host)
  local pool = host.Pool and host.Pool()
  if not pool then return end
  for i = 1, #pool do
    local row = pool[i]
    local marks = row.__pbMarks
    local carry = marks and marks.carry
    if carry and carry.on and row:IsShown() then
      carry.cur:SetPoint("LEFT", row, "LEFT", carry.left + dx, 0)
    end
  end
end

-- A list's pass of its rows is about to publish its lanes: last pass's go,
-- so a pass that places no one-line row leaves the header on widths of its
-- own rather than on lanes from another view. And the pass is done: the
-- header stands on what it published.
function AR.ListPlacing(owner)
  local host = AR.host
  if not (host and host.owner == owner) then return end
  local spec = host.Spec and host.Spec()
  local widths = spec and spec.laneW
  if widths then
    for id in pairs(widths) do widths[id] = nil end
  end
end

function AR.ListPlaced(owner)
  local host = AR.host
  if not (host and host.owner == owner) then return end
  AR.CoverLevel(host)
  AR.LayoutStrip(host)
  if AR.drag then AR.PlaceHand(host) end
end

-------------------------------------------------------------
-- 7b. The rows while arranging
--
-- RV.Place hands each row it places while the mode points at a column
-- (AR.Focus: the one in the hand, else under the pointer in the header,
-- else the selected one) to AR.MarkRow, with where the row's subject stands
-- and runs. On a one-line row, which has lanes:
--   a column         its lane washed where the row draws it; for a figure,
--                    hatched where the subject runs on through it, and
--                    outlined where the mail has none and the subject
--                    stopped short of it;
--   the subject      its own room washed, the room it borrowed from empty
--                    columns hatched, and a tick where it stops;
--   in the hand      the row's cell leaves its lane and rides on the lifted
--                    lane over the list (7a).
-- The accent while the column is selected or in the hand, white while it
-- is only pointed at. A two-line row keeps RV.Wash's wash around what it
-- draws of the column. Every mark is a texture of the row's own, made the
-- first time the row needs one and reused, as RV.Wash's is; a mark is
-- anchored again only where it moved. RV.Wash with nothing to point at
-- takes them all away (AR.UnmarkRow).
-------------------------------------------------------------

local MARK = {
  -- look -> { fill grey or "accent", fill alpha, ring grey or "accent", ring alpha }
  sel        = { "accent", 0.11, "accent", 0.45 },
  hover      = { 1, 0.10, 1, 0.45 },
  lent       = { 1, 0, 1, 0.18 },
  empty      = { "accent", 0, "accent", 0.28 },
  emptyHover = { 1, 0, 1, 0.25 },
}
AR.MARK = MARK

local function Rules()
  return ns.CollectTab and ns.CollectTab.RowRules or nil
end

-- The marks' textures by number, for where each was last anchored (kept in
-- the row's marks table, not on the textures).
local BOX, HATCH, TICK, TICK_KEY = 1, 2, 3, 4

-- Mark `i` (`tex`) from `x` for `w` units along the row, `inset` in from its
-- top and foot.
local function Span(m, i, tex, row, x, w, inset)
  if m.sx[i] ~= x or m.sw[i] ~= w or m.si[i] ~= inset then
    m.sx[i], m.sw[i], m.si[i] = x, w, inset
    tex:ClearAllPoints()
    tex:SetPoint("TOPLEFT", row, "TOPLEFT", x, -inset)
    tex:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", x, inset)
    tex:SetWidth(math.max(w, 1))
  end
  tex:Show()
end

function AR.NewMarks(row)
  local T = Th()
  -- Every field the marks ever hold, set here: the table never grows.
  local m = {
    sx = {}, sw = {}, si = {}, on = false, carry = false, flatHatch = false, tileW = 0, tileH = 0,
    box = false, ring = false, hatch = false, hatchTop = false, hatchFoot = false, tickKey = false, tick = false,
  }
  m.box = row:CreateTexture(nil, "BACKGROUND", nil, 4)
  m.box:SetTexture(WHITE)
  m.ring = AR.NewEdges(row, "BACKGROUND", 5, 0, 1)
  AR.PlaceEdges(m.ring, m.box, 0, 1)
  -- The hatch tiles (Theme.GLYPHS: sized, then its coordinates set to the
  -- size); a flat wash where its art is missing.
  m.hatch = T.Glyph and T.Glyph(row, "hatch", nil, "BACKGROUND") or false
  if m.hatch then
    m.hatch:SetDrawLayer("BACKGROUND", 5)
  else
    m.hatch = row:CreateTexture(nil, "BACKGROUND", nil, 5)
    m.hatch:SetTexture(WHITE)
    m.flatHatch = true
  end
  m.hatchTop = row:CreateTexture(nil, "BACKGROUND", nil, 6)
  m.hatchTop:SetTexture(WHITE)
  m.hatchTop:SetHeight(1)
  m.hatchTop:SetPoint("TOPLEFT", m.hatch, "TOPLEFT", 0, 0)
  m.hatchTop:SetPoint("TOPRIGHT", m.hatch, "TOPRIGHT", 0, 0)
  m.hatchFoot = row:CreateTexture(nil, "BACKGROUND", nil, 6)
  m.hatchFoot:SetTexture(WHITE)
  m.hatchFoot:SetHeight(1)
  m.hatchFoot:SetPoint("BOTTOMLEFT", m.hatch, "BOTTOMLEFT", 0, 0)
  m.hatchFoot:SetPoint("BOTTOMRIGHT", m.hatch, "BOTTOMRIGHT", 0, 0)
  m.tickKey = row:CreateTexture(nil, "ARTWORK", nil, 6)
  m.tickKey:SetTexture(WHITE)
  m.tickKey:SetVertexColor(0, 0, 0, 1)
  m.tick = row:CreateTexture(nil, "ARTWORK", nil, 7)
  m.tick:SetTexture(WHITE)
  m.box:Hide()
  AR.ShowEdges(m.ring, false)
  m.hatch:Hide()
  m.hatchTop:Hide()
  m.hatchFoot:Hide()
  m.tickKey:Hide()
  m.tick:Hide()
  row.__pbMarks = m
  return m
end

local function MarkBox(row, m, x, w, look)
  local spec = MARK[look] or MARK.sel
  local ar, ag, ab = Th().GetAccent()
  Span(m, BOX, m.box, row, x, w, 1)
  if spec[1] == "accent" then
    m.box:SetVertexColor(ar, ag, ab, spec[2])
  else
    m.box:SetVertexColor(spec[1], spec[1], spec[1], spec[2])
  end
  if spec[3] == "accent" then
    AR.TintEdges(m.ring, ar, ag, ab, spec[4])
  else
    AR.TintEdges(m.ring, spec[3], spec[3], spec[3], spec[4])
  end
  AR.ShowEdges(m.ring, true)
end

local function HideBox(m)
  m.box:Hide()
  AR.ShowEdges(m.ring, false)
end

-- The hatch from `x` for `w`: the subject's borrowed room (`edged`, with a
-- line along its top and foot) or a figure's lane it runs through.
local function MarkHatch(row, m, x, w, accent, edged)
  local hatch = m.hatch
  Span(m, HATCH, hatch, row, x, w, 1)
  local h = math.max((row:GetHeight() or 26) - 2, 1)
  if not m.flatHatch and (m.tileW ~= w or m.tileH ~= h) then
    m.tileW, m.tileH = w, h
    hatch:SetTexCoord(0, w / 8, 0, h / 8)
  end
  local r, g, b, a = 1, 1, 1, edged and 0.3 or 0.2
  if accent then
    r, g, b = Th().GetAccent()
    a = 0.4
  end
  if m.flatHatch then a = a * 0.3 end
  hatch:SetVertexColor(r, g, b, a)
  m.hatchTop:SetShown(edged and true or false)
  m.hatchFoot:SetShown(edged and true or false)
  if edged then
    local la = accent and 0.45 or 0.35
    m.hatchTop:SetVertexColor(r, g, b, la)
    m.hatchFoot:SetVertexColor(r, g, b, la)
  end
end

local function HideHatch(m)
  m.hatch:Hide()
  m.hatchTop:Hide()
  m.hatchFoot:Hide()
end

-- The tick where the subject stops: two units wide, centred on `x`, in a
-- black keyline.
local function MarkTick(row, m, x, accent)
  Span(m, TICK_KEY, m.tickKey, row, x - 2, 4, 2)
  Span(m, TICK, m.tick, row, x - 1, 2, 3)
  if accent then
    local r, g, b = Th().GetAccent()
    m.tick:SetVertexColor(r, g, b, 1)
  else
    m.tick:SetVertexColor(0.85, 0.85, 0.85, 1)
  end
end

local function HideTick(m)
  m.tick:Hide()
  m.tickKey:Hide()
end

-- The cells the lane in the hand carries: a copy of a row's own, on the
-- lane (7a), made once per row and filled from the row whenever it is
-- bound during a drag.
local function NewCarry(cover)
  local cells = cover.Hand.Cells
  local carry = { cover = cover, Text = false, Tex = false, Dot = false, cur = false, left = 0, on = false }
  carry.Text = cells:CreateFontString(nil, "OVERLAY")
  Th().ApplyTextRole(carry.Text, "value")
  carry.Text:SetWordWrap(false)
  carry.Tex = cells:CreateTexture(nil, "ARTWORK")
  carry.Dot = cells:CreateTexture(nil, "ARTWORK")
  carry.Dot:SetTexture(WHITE)
  if type(cells.CreateMaskTexture) == "function" then
    local mask = cells:CreateMaskTexture()
    mask:SetTexture(ROUND_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(carry.Dot)
    carry.Dot:AddMaskTexture(mask)
  end
  carry.Text:Hide()
  carry.Tex:Hide()
  carry.Dot:Hide()
  return carry
end

local function Uncarry(m)
  local carry = m.carry
  if carry and carry.on then
    carry.on = false
    carry.cur:Hide()
  end
end

-- The row's cell of the column in the hand, onto the lane: where the row
-- has it, moved by the drag's offset. The subject's is its own room.
local function Carry(row, m, region, s, x, subjectW, dx)
  local host = AR.host
  local cover = host and host.cover
  if not cover then return end
  local carry = m.carry
  if not carry or carry.cover ~= cover then
    carry = NewCarry(cover)
    m.carry = carry
  end
  local w = region:GetWidth() or 0
  local left = region.__pbAtX or 0
  if region.__pbAt == 2 then left = (s.width or 0) + left - w end
  if region == s.el.subject then w = math.max(math.min(w, x + subjectW - left), 1) end
  local cur
  if region:GetObjectType() == "FontString" then
    cur = carry.Text
    local path, size, flags = region:GetFont()
    if path then cur:SetFont(path, size, flags or "") end
    cur:SetTextColor(region:GetTextColor())
    if region.GetShadowOffset then
      cur:SetShadowOffset(region:GetShadowOffset())
      cur:SetShadowColor(region:GetShadowColor())
    end
    cur:SetJustifyH(region:GetJustifyH() or "LEFT")
    cur:SetWidth(w)
    cur:SetText(region:GetText() or "")
    carry.Tex:Hide()
    carry.Dot:Hide()
  else
    cur = (region == s.el.read) and carry.Dot or carry.Tex
    if cur == carry.Tex then
      cur:SetTexture(region:GetTexture())
      cur:SetTexCoord(region:GetTexCoord())
      carry.Dot:Hide()
    else
      carry.Tex:Hide()
    end
    cur:SetVertexColor(region:GetVertexColor())
    cur:SetSize(w, region:GetHeight() or w)
    carry.Text:Hide()
  end
  carry.cur, carry.left, carry.on = cur, left, true
  cur:ClearAllPoints()
  cur:SetPoint("LEFT", row, "LEFT", left + dx, 0)
  cur:Show()
end

function AR.UnmarkRow(row)
  local m = row.__pbMarks
  if not (m and m.on) then return end
  m.on = false
  HideBox(m)
  HideHatch(m)
  HideTick(m)
  Uncarry(m)
end

-- RV.Place's last step for a row, while the mode points at a column: see
-- above. `lanes` is whether the row stands in lanes; `x`, `subjectW` the
-- subject's own room; `sx`, `run` where it starts and how far it runs.
function AR.MarkRow(row, s, target, lanes, x, subjectW, sx, run)
  local R = Rules()
  local focus = s.focus
  local host = AR.host
  -- The other window's rows, if it is up, keep the plain wash: the header,
  -- its lanes and the lane in the hand are this list's.
  local list = host and host.List and host.List()
  if not (lanes and sx and list and row:GetParent() == list) then
    AR.UnmarkRow(row)
    if R and R.Wash then R.Wash(row, target) end
    return
  end
  local wash = row.__pbWash
  if wash then wash:Hide() end
  local m = row.__pbMarks or AR.NewMarks(row)
  m.on = true
  local drag = AR.drag
  if drag and drag.id == focus then
    HideBox(m)
    HideHatch(m)
    HideTick(m)
    local region = s.el[focus]
    if region and region:IsShown() then
      Carry(row, m, region, s, x, subjectW, drag.dx)
      region:Hide()
      -- The icon's quality mark goes with it (the row paints it again
      -- when it is next bound).
      if region == s.el.icon and row.QualityHolder then row.QualityHolder:Hide() end
    else
      Uncarry(m)
    end
    return
  end
  Uncarry(m)
  local sel = AR.Selected("column", focus)
  local pad = HEAD.PAD
  local ownEnd = x + subjectW
  local runEnd = sx + (run or subjectW)
  if focus == "subject" then
    MarkBox(row, m, sx - pad, math.min(ownEnd, runEnd) - sx + 2 * pad, sel and "sel" or "hover")
    if runEnd > ownEnd + 0.5 then
      MarkHatch(row, m, ownEnd + pad, runEnd - ownEnd, sel, true)
    else
      HideHatch(m)
    end
    MarkTick(row, m, runEnd + pad, sel)
    return
  end
  HideTick(m)
  local laneX, laneW = s.laneX, s.laneW
  local lx = laneX and laneX[focus]
  local lw = laneW and laneW[focus] or 0
  if not lx or lw <= 0 then
    -- No lane in this list: what the row draws of it, if anything, washed
    -- where it stands.
    HideBox(m)
    HideHatch(m)
    if target and R and R.Wash then R.Wash(row, target) end
    return
  end
  local region = s.el[focus]
  if region and region:IsShown() then
    MarkBox(row, m, lx - pad, lw + 2 * pad, sel and "sel" or "hover")
    HideHatch(m)
  elseif AR.COLUMNS[focus] and AR.COLUMNS[focus].figure and lx >= ownEnd - 0.5 and lx + lw <= runEnd + 0.5 then
    MarkBox(row, m, lx - pad, lw + 2 * pad, "lent")
    MarkHatch(row, m, lx - pad, lw + 2 * pad, false, false)
  else
    MarkBox(row, m, lx - pad, lw + 2 * pad, sel and "empty" or "emptyHover")
    HideHatch(m)
  end
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
--     what the rows do on a mail without it; for the subject, Line up
--     columns, what the rows show of its run, and what Line up columns
--     does; for a block, the stack's order.
-- A click on a heading, a column on a row or a block selects it, a second
-- click lets it go; the cross and Escape go back a layer (section 5).
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
  SWATCH_W = 14, SWATCH_H = 9, SWATCH_GAP = 5,  -- the hatch's sample before a note
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

-- A column shown or hidden from the inspector: the rows and the header on
-- their lanes follow, as they follow a drag.
function AR.ShowColumn(id, on)
  AR.SetColumnShown(id, on)
  AR.RowsChanged(true)
  if AR.host then AR.LayoutStrip(AR.host) end
end

-- A hidden column's peg, clicked (section 6): the column back where it
-- stands.
function AR.ShowPeg(peg)
  if not (AR.host and peg and peg.colId) then return end
  peg.hover = false
  GameTooltip:Hide()
  AR.ShowColumn(peg.colId, true)
  PlayToggle(true)
  AR.Inspect()
end

-- A column one place along the row, left (-1) or right (1).
function AR.NudgeColumn(id, step)
  local layout = AR.Layout()
  local k = layout and IndexOf(layout, id)
  if not k then return end
  local to = k + step
  if to < 1 or to > #layout then return end
  AR.MoveColumn(k, to)
  AR.RowsChanged(true)
  if AR.host then AR.LayoutStrip(AR.host) end
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

-- Line up columns, on the subject's card: the options panel's own switch
-- (MailboxUI, lineUpColumns; unset is on), since it decides how much room
-- the subject has. A box before its name, filled with the accent and
-- checked while on; its words and ring rise with it, and go white when
-- pointed at. While arranging the rows line up whatever it says, so a click
-- places nothing again: the rows follow it when the mode ends
-- (AR.Leave), and the card's note says what it does meanwhile.
local function LinedUp()
  local ui = UI()
  return not (ui and ui.GetOption) or ui.GetOption("lineUpColumns")
end

local function PaintLanes(sw)
  local spec = PLATE.switch
  local on, hover = sw.on, sw.hover
  TintPlate(sw, hover and 0.17 or spec.fill, hover and spec.hover or (on and spec.on or spec.ring))
  if on then
    local r, g, b = Th().GetAccent()
    sw.Box:SetVertexColor(r, g, b, 1)
  else
    Grey(sw.Box, hover and 0.36 or 0.22)
  end
  if sw.Check then
    sw.Check:SetShown(on and true or false)
    Grey(sw.Check, 0.06)
  end
  Grey(sw.Label, (on or hover) and 1 or 0.74)
end

local function LanesTip(self)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:SetText(L()["OPT_LINE_UP_TITLE"])
  GameTooltip:AddLine(L()["OPT_LINE_UP_DESC"], 1, 1, 1, true)
  GameTooltip:Show()
end

local function LanesEnter(self)
  self.hover = true
  PaintLanes(self)
  LanesTip(self)
end

local function LanesLeave(self)
  self.hover = false
  PaintLanes(self)
  GameTooltip:Hide()
end

local function LanesClick(self)
  local ui = UI()
  if not (AR.host and ui and ui.SetOption) then return end
  local on = not LinedUp()
  ui.SetOption("lineUpColumns", on)
  PlayToggle(on)
  -- The options panel, where it is open, shows the switch as it now is.
  local panel = ns.OptionsPanel
  if panel and type(panel.RefreshControls) == "function" then panel.RefreshControls() end
  AR.Inspect()
  if GameTooltip:IsOwned(self) then LanesTip(self) end
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
  -- The subject's card: how far each row's subject runs, in words.
  insp.Why = Paragraph(art, "body", 0.81)
  -- A note that begins with the hatch the rows draw (PutSwatchNote): the
  -- sample at the note's left, the words beside it.
  insp.SwatchNote = Paragraph(art, "secondary", 0.66)
  insp.SwatchNote:SetWidth(P.INNER - P.SWATCH_W - P.SWATCH_GAP)
  insp.Swatch = T.Glyph and T.Glyph(art, "hatch", nil, "ARTWORK") or nil
  if insp.Swatch then
    insp.Swatch:SetSize(P.SWATCH_W, P.SWATCH_H)
    insp.Swatch:SetTexCoord(0, P.SWATCH_W / 8, 0, P.SWATCH_H / 8)
    insp.SwatchRing = AR.NewEdges(art, "ARTWORK", 1, 0, 1)
    AR.PlaceEdges(insp.SwatchRing, insp.Swatch, 0, 1)
    insp.Swatch:Hide()
    AR.ShowEdges(insp.SwatchRing, false)
  end
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

  -- Line up columns (above): a box in a black keyline, checked while on.
  local lanes = InspPlate(insp, "Button", true)
  lanes:SetHeight(P.SWITCH_H)
  lanes.hover, lanes.on = false, false
  lanes.BoxKey = lanes:CreateTexture(nil, "ARTWORK", nil, 0)
  lanes.BoxKey:SetTexture(WHITE)
  lanes.BoxKey:SetVertexColor(0, 0, 0, 1)
  lanes.BoxKey:SetSize(10, 10)
  lanes.BoxKey:SetPoint("CENTER", lanes, "LEFT", 12, 0)
  lanes.Box = lanes:CreateTexture(nil, "ARTWORK", nil, 1)
  lanes.Box:SetTexture(WHITE)
  lanes.Box:SetSize(8, 8)
  lanes.Box:SetPoint("CENTER", lanes.BoxKey, "CENTER", 0, 0)
  lanes.Check = T.Glyph and T.Glyph(lanes, "check", 6, "OVERLAY") or nil
  if lanes.Check then lanes.Check:SetPoint("CENTER", lanes.BoxKey, "CENTER", 0, 0) end
  lanes.Label = T.CreateText(lanes, "segment")
  lanes.Label:SetPoint("LEFT", lanes, "LEFT", P.SWITCH_LEAD, 0)
  lanes.Label:SetJustifyH("LEFT")
  lanes.Label:SetWordWrap(false)
  lanes:SetScript("OnEnter", LanesEnter)
  lanes:SetScript("OnLeave", LanesLeave)
  lanes:SetScript("OnClick", LanesClick)
  lanes:Hide()
  insp.Lanes = lanes

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

-- A note that speaks of the hatch the rows draw: the sample first, as the
-- rows have it -- in the accent where it is the subject's borrowed room,
-- grey where it is a figure's lane the subject runs through -- and the
-- words beside it. A plain note where the hatch's art is missing.
local function PutSwatchNote(text, y, accent)
  local insp, P = AR._insp, INSP
  local swatch = insp.Swatch
  if not swatch then return PutNote(text, y) end
  y = y - P.NOTE_TOP
  PutRule(insp.NoteRule, y)
  y = y - 1 - P.NOTE_PAD
  if accent then
    local r, g, b = Th().GetAccent()
    swatch:SetVertexColor(r, g, b, 0.7)
    AR.TintEdges(insp.SwatchRing, r, g, b, 0.6)
  else
    swatch:SetVertexColor(1, 1, 1, 0.35)
    AR.TintEdges(insp.SwatchRing, 1, 1, 1, 0.3)
  end
  swatch:ClearAllPoints()
  swatch:SetPoint("TOPLEFT", insp, "TOPLEFT", P.PAD, y - 2)
  swatch:Show()
  AR.ShowEdges(insp.SwatchRing, true)
  local fs = insp.SwatchNote
  At(fs, P.PAD + P.SWATCH_W + P.SWATCH_GAP, y)
  fs:Show()
  return y - math.max(Measured(fs, text, true), P.SWATCH_H + 2)
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

-- Line up columns at the row's left, on the subject's card; answers its
-- width. A name too long for the card is cut, and whole in the tooltip.
local function PutLanes(y)
  local insp, P = AR._insp, INSP
  local sw = insp.Lanes
  local text = L()["OPT_LINE_UP_TITLE"]
  local w = math.min(P.SWITCH_LEAD + Measured(insp.MeasureSegment, text, false) + P.SWITCH_TAIL, P.INNER)
  sw.on = LinedUp() and true or false
  Th().FitText(sw.Label, w - P.SWITCH_LEAD - P.SWITCH_TAIL + 1, text, sw)
  sw:SetWidth(w)
  At(sw, P.PAD, y)
  PaintLanes(sw)
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
  local used
  if spec.fixed then used = PutLanes(y) else used = PutSwitch(shown, y) end
  y = PutMove(y, false, k > 1, layout ~= nil and k < #layout, used)
  -- The subject's card says what the rows show while it is selected: each
  -- row's run, and why it stops where it does.
  if spec.fixed then
    y = PutKicker(L()["ARRANGE_SUBJECT_WHY"], y)
    y = PutText(insp.Why, L()["ARRANGE_SUBJECT_RUN"], y)
  end
  local choices, current, set = AR.Choices(spec.choice)
  insp.set = set
  if #choices > 0 then
    y = PutKicker(L()["COL_SHOW"], y)
    for i = 1, #choices do
      y = PutRadio(i, choices[i], choices[i].id == current, shown and true or false, y)
    end
  end
  -- A figure's place beside the subject, and after it whether the columns
  -- line up, say what a mail without it does; the subject's card says what
  -- Line up columns does, as it stands. Where the subject runs on into a
  -- column, the note begins with the hatch the rows draw there.
  if spec.figure and layout then
    local at = IndexOf(layout, "subject") or 0
    if k > at then
      y = PutSwatchNote(L()[LinedUp() and "ARRANGE_NOTE_RIGHT" or "ARRANGE_NOTE_RIGHT_OFF"], y, false)
    else
      y = PutNote(L()["ARRANGE_NOTE_LEFT"], y)
    end
  elseif spec.fixed then
    y = PutSwatchNote(L()[LinedUp() and "ARRANGE_LANES_ON" or "ARRANGE_LANES_OFF"], y, true)
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
  insp.Why:Hide()
  insp.SwatchNote:Hide()
  if insp.Swatch then
    insp.Swatch:Hide()
    AR.ShowEdges(insp.SwatchRing, false)
  end
  insp.Kicker:Hide()
  insp.MoveLabel:Hide()
  insp.NoteRule:Hide()
  insp.FootRule:Hide()
  insp.Finish:Hide()
  insp.Switch:Hide()
  insp.Lanes:Hide()
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
-- A host is the list being arranged: { owner = its frame, PlaceStrip(strip)
-- (the header in the top row's place, its left edge the rows' own),
-- OnEnter(strip) (the top row steps aside), OnLeave() (and comes back as it
-- was), Rise() (optional: its cards settle in, played once as the mode
-- opens), toggle = the key that opened it }. For the header and the rows it
-- answers, for the list on screen: Spec() (its placement table, whose lanes
-- RV.Place publishes), Pool() (its rows), Scroll() (its scroll frame),
-- List() (the frame its rows stand in) and TwoLine() (whether its rows are
-- the two-line ones, which have no lanes). It tells the mode when a pass
-- of its rows begins and ends (AR.ListPlacing, AR.ListPlaced). The Mail
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
  local cover = host.cover or AR.BuildCover(host)
  AR.host = host
  AR.hover, AR.focus, AR.drag, AR.rowHover = nil, nil, nil, nil
  AR.selKind, AR.selId, AR.moving = nil, nil, nil
  strip:Show()
  if host.OnEnter then host.OnEnter(strip) end
  if cover then
    AR.CoverLevel(host)
    cover:Show()
  end
  AR.CatchEscape(true)
  if host.toggle then AR.PaintToggle(host.toggle) end
  -- The rows line up while the mode is open: placed again, and the header
  -- laid on their lanes as each pass ends (AR.ListPlaced) -- and here, for
  -- a list that placed none.
  AR.RowsChanged(false)
  AR.LayoutStrip(host)
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
  if drag then
    drag.head:SetFrameLevel(drag.level)
    drag.head:SetHeight(Th().Metrics.tileHeight)
    drag.head._x = nil
  end
  AR.selKind, AR.selId, AR.moving = nil, nil, nil
  AR.host = nil
  if AR._insp then AR._insp:Hide() end
  AR.hover, AR.focus, AR.rowHover = nil, nil, nil
  AR.CatchEscape(false)
  local strip = host.strip
  if strip then
    strip.Ghost:Hide()
    strip:Hide()
    for _, head in pairs(strip.heads) do head.hover = false end
    for _, peg in pairs(strip.pegs) do peg.hover = false end
  end
  local cover = host.cover
  if cover then
    cover:SetScript("OnUpdate", nil)
    cover.Hand:Hide()
    cover.Ghost:Hide()
    cover:Hide()
  end
  if host.OnLeave then host.OnLeave() end
  if host.toggle then AR.PaintToggle(host.toggle) end
  -- A card that went with the mode may have had the pointer.
  AR.MoveCursor(false)
  -- The rows as the switch has them again, and nothing marked on them.
  AR.RowsChanged(false)
end

-- The mode ends with the frame it was opened over.
function AR.LeaveIf(owner)
  if AR.host and AR.host.owner == owner then AR.Leave() end
end
