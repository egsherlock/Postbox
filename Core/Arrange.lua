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
-- column, a block under the list or a category button to select it: the
-- inspector docked beside the window shows its card -- show or hide it, its
-- own choices, Move for the no-drag way -- and the rows show the column; for
-- the subject, how far each row's runs and why. A right-click hides or
-- shows it. One gesture model for everything the mode arranges: a drag
-- moves, a click selects, a right-click hides or shows; the subject and All
-- mail cannot be hidden, and their right-click does nothing. With nothing
-- selected the inspector says how the mode works, lists what is hidden and
-- offers the reset. The key, lit as Done while the mode is open, Escape, or
-- the window going away all end it, and the top row comes back as it was.
--
-- Two arrangements: the mail rows' -- the Mail tab's and Mail Memory's,
-- stored by MailboxUI.GetRowLayout / SetRowLayout -- and History's own,
-- with its age and without the columns it has not (GetHistoryLayout /
-- SetHistoryLayout). Both are drawn by CollectTab's RV.Place. The mode
-- arranges the one the list it is opened over follows (AR.Layout), and
-- follows the list when it is switched under it (AR.SyncList). This file
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
-- may not have. The age is History's alone: how long ago a mail was
-- collected, which every History row has.
AR.COLUMNS = {
  read    = { title = "COL_READ",       desc = "COL_READ_DESC",       head = "dot" },
  icon    = { title = "COL_ICON",       desc = "COL_ICON_DESC",       head = "icon" },
  sender  = { title = "COL_SENDER",     desc = "COL_SENDER_DESC" },
  subject = { title = "COL_SUBJECT",    desc = "COL_SUBJECT_DESC",    fixed = true },
  time    = { title = "OPT_ROW_EXPIRY", desc = "OPT_ROW_EXPIRY_DESC", choice = "expiry", figure = true, head = "hourglass" },
  money   = { title = "OPT_ROW_GOLD",   desc = "OPT_ROW_GOLD_DESC",   choice = "gold", figure = true, head = "coin" },
  slots   = { title = "OPT_ROW_SLOTS",  desc = "OPT_ROW_SLOTS_DESC", choice = "slots", figure = true, head = "slot" },
  age     = { title = "COL_AGE",        desc = "COL_AGE_DESC",        choice = "age", head = "history" },
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
-- ("column", "block" or "button", a category button) and an id, or nil for
-- the overview; and while something is in the hand, its name.
AR.selKind = nil
AR.selId = nil
AR.moving = nil

-------------------------------------------------------------
-- 1. The arrangement, read and written
-------------------------------------------------------------

-- Whether the mode arranges History's own arrangement: the list it is open
-- over follows it (the host's History()). Answered from the list as it is
-- now, so a list switched under the mode is followed (AR.SyncList).
function AR.EditsHistory()
  local host = AR.host
  return host ~= nil and host.History ~= nil and host.History() == true
end

-- The arrangement the mode arranges (above): History's or the mail rows'.
function AR.Layout()
  local ui = UI()
  if not ui then return nil end
  if AR.EditsHistory() then
    return type(ui.GetHistoryLayout) == "function" and ui.GetHistoryLayout() or nil
  end
  return type(ui.GetRowLayout) == "function" and ui.GetRowLayout() or nil
end

-- The arrangement written (a list as AR.Layout's, or nil for the default):
-- the one the mode arranges, unless `history` says which.
function AR.SetLayout(list, history)
  local ui = UI()
  if not ui then return end
  if history == nil then history = AR.EditsHistory() end
  if history then
    if ui.SetHistoryLayout then ui.SetHistoryLayout(list) end
  elseif ui.SetRowLayout then
    ui.SetRowLayout(list)
  end
end

-- A copy the caller may change, for AR.SetLayout.
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

-- Row layout (MailboxUI.GetRowPacking; Columns unless Packed): whether the
-- rows stand in lanes, in the mode as out of it (CollectTab's RV.LinedUp).
local function LinedUp()
  local ui = UI()
  return not (ui and ui.GetRowPacking) or ui.GetRowPacking() ~= "packed"
end

function AR.MoveColumn(from, to)
  local list = CopyLayout()
  local entry = table.remove(list, from)
  if not entry then return end
  table.insert(list, math.max(1, math.min(to, #list + 1)), entry)
  AR.SetLayout(list)
end

function AR.SetColumnShown(id, on)
  local list = CopyLayout()
  local i = IndexOf(list, id)
  if not i or AR.COLUMNS[id].fixed then return end
  list[i].shown = on and true or false
  AR.SetLayout(list)
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

-- Right-click on the lit key, or the inspector's reset: what the mode
-- arranges from the list it is open over, as it comes. From the mail rows:
-- their columns, the blocks under the list and the buttons, with the
-- gold's, the time left's and the slots' own defaults. From History: its
-- columns and its age's wording, the blocks under the list and the gold's
-- default (its money's card), and nothing History does not show -- not
-- the mail rows' columns, not the buttons. `history` says which (nil: the
-- list the mode is open over).
function AR.Reset(history)
  local ui = UI()
  if not ui then return end
  if history == nil then history = AR.EditsHistory() end
  AR.SetLayout(nil, history)
  if ui.SetGoldMode then ui.SetGoldMode("both") end
  if history then
    if ui.SetHistoryAge then ui.SetHistoryAge(nil) end
  else
    if ui.SetExpiryWhen then ui.SetExpiryWhen("3") end
    if ui.SetSlotsStyle then ui.SetSlotsStyle(nil) end
    if ui.SetGridLayout then ui.SetGridLayout(nil) end
  end
  if ui.SetStackOrder then ui.SetStackOrder(nil) end
  -- The grid and the totals hidden in the mode are the "Show category
  -- buttons" and "Show totals" options, so they come back with the rest,
  -- and the window's floor with them.
  local gridBack = not history and ui.GetOption and ui.SetOption and not ui.GetOption("showCategoryButtons")
  if gridBack then ui.SetOption("showCategoryButtons", true) end
  local totalsBack = ui.GetOption and ui.SetOption and not ui.GetOption("showTotals")
  if totalsBack then ui.SetOption("showTotals", true) end
  AR.RowsChanged(true)
  if AR.host then AR.LayoutStrip(AR.host) end
  if (gridBack or totalsBack) and ui.RefreshCollectCategoryButtons then
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
-- about the arrangement, not the mode -- the one being arranged when it
-- was asked (AR.resetHistory), whose own words it asks in.
AR.POPUP_RESET = "POSTBOX_ARRANGE_RESET"
AR.resetHistory = false

function AR.AskReset()
  if type(StaticPopupDialogs) ~= "table" or type(StaticPopup_Show) ~= "function" then return end
  if not StaticPopupDialogs[AR.POPUP_RESET] then
    StaticPopupDialogs[AR.POPUP_RESET] = {
      text = "%s",
      button1 = L()["BTN_RESET"],
      button2 = L()["COD_CONFIRM_CANCEL"],
      OnAccept = function() AR.Reset(AR.resetHistory) end,
      timeout = 0,
      whileDead = true,
      hideOnEscape = true,
    }
  end
  AR.resetHistory = AR.EditsHistory()
  local dialog = StaticPopup_Show(AR.POPUP_RESET,
    L()[AR.resetHistory and "ARRANGE_RESET_CONFIRM_HISTORY" or "ARRANGE_RESET_CONFIRM"])
  local T = Th()
  if dialog and T and T.LiftPopup then T.LiftPopup(dialog) end
end

-- The column the rows mark (section 7b): the one being dragged, else the one
-- the cursor is over, on its heading or on its column in the rows (section
-- 7a, AR.Pointed), else the selected one. Only while the mode is open.
function AR.Focus()
  if not AR.host then return nil end
  return AR.focus
end

function AR.UpdateFocus()
  local focus = (AR.drag and AR.drag.id) or AR.hover or AR.Pointed()
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
-- host's blocks and buttons.
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
  -- A drag let go after an Escape was heard and before it is answered (the
  -- client can end the press with the key) goes back where it began: the
  -- Escape was the drag's (section 5).
  if released and dragging and AR._escHeld then
    putBack, released = true, false
    AR._escDone = true
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
  -- Escape is the mode's while anything is in the hand (section 5).
  if AR.host then AR.GuardEscape() end
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
-- `selHover` a block's or a button's while it is selected, and
-- `hiddenSel` a hidden button's, dark as it is and ringed in the accent.
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
    sel            = { accent = 0.12, top = 0.08, drop = 2, dropA = 0.45 },
    selHover       = { accent = 0.18, top = 0.12, drop = 3, dropA = 0.55 },
    hiddenSel      = { wash = { 0, 0.40 }, drop = 2, dropA = 0.35 },
    hiddenSelHover = { wash = { 0, 0.25 }, top = 0.06, drop = 3, dropA = 0.45 },
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

function AR.NewCard(parent, kind, frameType)
  local card = CreateFrame(frameType or "Frame", nil, parent)
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

-- The line every tooltip in the mode ends with: what the three gestures do
-- to the thing under the pointer, the same words everywhere. `state` is
-- "hide" for a shown thing a right-click hides, "show" for a hidden thing
-- it shows, "fixed" for one that cannot be hidden (the subject, All mail).
-- It is the form of every gesture line in Postbox: the mode's own Done and
-- Back say theirs the same way, in the same grey.
local GESTURE = { hide = "ARRANGE_GESTURE_HIDE", show = "ARRANGE_GESTURE_SHOW", fixed = "ARRANGE_GESTURE_FIXED" }

function AR.GestureLine(state)
  return L()[GESTURE[state] or GESTURE.fixed]
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
    GameTooltip:AddLine(L()["ARRANGE_GESTURE_DONE"], 0.7, 0.7, 0.7, true)
  else
    GameTooltip:SetText(L()["ARRANGE_TITLE"])
    GameTooltip:AddLine(ns.Summary(L()["ARRANGE_TIP"]), 1, 1, 1, true)
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
-- Escape works in layers, one per press, and while the mode is open it does
-- nothing else: no window closes under the mode -- not the Postbox window,
-- not the mailbox, not the bags, the character pane or anyone else's. A
-- drag in progress is put back where it began; else the character groups'
-- window, which the grid's card opens, closes (a layer of its own); else a
-- selection is let go, and the inspector goes back to its overview; else
-- the mode ends. The inspector's cross does the same, less the drag.
--
-- Why the key has to be heard first. The client answers the game-menu key
-- with ToggleGameMenu, which asks its handlers in turn -- popups, menus, a
-- cast, Blizzard's own overlays and the game menu, then addons' -- and,
-- when none claims the key, closes every UI panel and every frame named in
-- UISpecialFrames in one pass (CloseAllWindows). The mailbox's own frame is
-- one of those panels, shown unseen under the Postbox window, so that pass
-- closes the mailbox, and Postbox with it. Nothing listening inside the
-- pass can make it close one thing. Blizzard's list of handlers
-- (RegisterGameMenuEscHandler, 12.1) is not joined: an entry added from an
-- addon taints the list, and every later Escape would run tainted.
--
-- Out of combat, then, a small frame of ours, over the host and shown only
-- while the mode is open, takes the keyboard with every key passed on
-- (propagation on, set before it is ever shown). The key bound to the game
-- menu (TOGGLEGAMEMENU, with the modifiers held, matched as the client
-- matches it: a rebound key included, a key another addon has taken with
-- an override binding left to it) is kept from the bindings for that
-- one press, and only when the mode is what the press would reach: a
-- popup, an open menu or flyout, a spell being cast or aimed, a focused
-- edit box, or one of Blizzard's windows that answer the key before any
-- addon's (the game menu, the settings, the help or report window, the
-- clock ...) take it first, exactly as stock (AR.EscapeIsOurs). The press
-- is answered the next frame, when keys pass again: propagation is put
-- back on then, at the key's release, whenever the frame hides or shows,
-- and at PLAYER_REGEN_DISABLED, which comes before the lockdown. Every
-- other key passes untouched, with nothing allocated for it.
--
-- In combat an addon may not call SetPropagateKeyboardInput (10.1.5 on),
-- so the frame hides for the fight -- hiding our own frame is always
-- allowed, and a hidden frame takes no keys -- and Escape reaches the
-- client's pass as it would without Postbox. For that, and for any press
-- the keyboard passed on that still reaches the pass (a controller's
-- button, a legacy menu closing, which claims nothing), the mode also
-- listens inside the pass for as long as it is open: the Postbox windows'
-- names in UISpecialFrames are swapped IN PLACE for a small frame of ours
-- (so no other entry shifts), and that frame hiding is the Escape. The
-- mode keeps its layers and Mail Memory stays open, but everything else
-- the pass closes still closes -- at a mailbox that is the mailbox, and
-- the Mail tab with it. The swap is made again at every press and after
-- every Escape, so a name added meanwhile is taken too (AR.GuardEscape),
-- and undone however the mode ends. An Escape whose pass also closed the
-- character groups' window was that window's.
--
-- Either way an Escape heard while a column, a block or a button is in the
-- hand is the drag's, however the press ends before the Escape is answered
-- a frame later: a release in between puts the drag back rather than
-- dropping it (EndGesture). A press still deciding whether it is a drag
-- ends with the key, its click unmade. A layer that fails still leaves the
-- mode listening, and a check that fails passes the key on.
-------------------------------------------------------------

AR.ESC_WINDOWS = { PostboxFrame = true, PostboxMailMemoryFrame = true }

-- Blizzard's windows that answer the game-menu key before any addon's
-- (GameMenuEscPriority up to Framework), by name, as most load on demand:
-- while one is shown the key is theirs. The legacy menus are passed on too,
-- to close as the client always has closed them. Blizzard's Edit Mode is
-- left out on purpose: Postbox never reads it.
AR.ESC_FIRST = {
  "GameMenuFrame", "SettingsPanel", "OpacityFrame", "HelpFrame", "ReportFrame",
  "TimeManagerFrame", "SpellFlyout", "HouseEditorFrame",
  "HousingBlueprintExportFrame", "HousingBlueprintImportFrame",
  "HousingBlueprintRenameFrame", "DropDownList1", "DropDownList2",
}

do
  local ESC_NAME = "PostboxArrangeEscape"
  local MODIFIERS = { ALT = true, CTRL = true, SHIFT = true, META = true }

  -- The keys that can be the game-menu key, bare (a binding's modifiers
  -- taken off): only a press of one of these is looked at further. Read
  -- when the mode opens and whenever the bindings change.
  local menuKeys = {}

  local function AddMenuKeys(...)
    for i = 1, select("#", ...) do
      local key = select(i, ...)
      if type(key) == "string" and key ~= "" then
        local base = key
        while true do
          local mod, rest = base:match("^(%u+)%-(.+)$")
          if not (mod and MODIFIERS[mod]) then break end
          base = rest
        end
        menuKeys[base] = true
      end
    end
  end

  local function ReadMenuKeys()
    for k in pairs(menuKeys) do menuKeys[k] = nil end
    menuKeys.ESCAPE = true
    if type(GetBindingKey) == "function" then AddMenuKeys(GetBindingKey("TOGGLEGAMEMENU")) end
  end

  -- A cast or channel of the player's own, which the client's Escape stops
  -- first. A secret answer is a cast.
  local function Casting(query)
    if type(query) ~= "function" then return false end
    local name = (query("player"))
    if type(issecretvalue) == "function" and issecretvalue(name) then return true end
    return name ~= nil
  end

  local function Held(query) return type(query) == "function" and query() or false end

  -- What a press of `pressed` runs, as the client's dispatch finds it: the
  -- chord with the modifiers held (in the client's order), an override
  -- binding before the player's own, and a chord with nothing bound to it
  -- falling back to the bare key. Only a candidate key gets here, so the
  -- chord's string is built for the game-menu key alone.
  local function BoundTo(pressed)
    if type(GetBindingAction) ~= "function" then
      return type(GetBindingFromClick) == "function" and GetBindingFromClick(pressed) or nil
    end
    local chord = pressed
    if Held(IsModifierKeyDown) then
      chord = (Held(IsAltKeyDown) and "ALT-" or "") .. (Held(IsControlKeyDown) and "CTRL-" or "")
        .. (Held(IsShiftKeyDown) and "SHIFT-" or "") .. (Held(IsMetaKeyDown) and "META-" or "") .. pressed
    end
    local action = GetBindingAction(chord, true)
    if (action == nil or action == "") and chord ~= pressed then action = GetBindingAction(pressed, true) end
    return action
  end

  -- Whether this press is the mode's: the game-menu key as the client
  -- would match it, with nothing up that the client asks before an addon's
  -- window. Reads only.
  function AR.EscapeIsOurs(pressed)
    if not AR.host or not menuKeys[pressed] then return false end
    if BoundTo(pressed) ~= "TOGGLEGAMEMENU" then return false end
    if type(GetCurrentKeyBoardFocus) == "function" and GetCurrentKeyBoardFocus() then return false end
    if type(StaticPopup_IsAnyDialogShown) == "function" and StaticPopup_IsAnyDialogShown() then return false end
    local menu = type(Menu) == "table" and type(Menu.GetManager) == "function" and Menu.GetManager() or nil
    if menu and menu.IsAnyMenuOpen and menu:IsAnyMenuOpen() then return false end
    if type(SpellIsTargeting) == "function" and SpellIsTargeting() then return false end
    if Casting(UnitCastingInfo) or Casting(UnitChannelInfo) then return false end
    local dock = type(GENERAL_CHAT_DOCK) == "table" and GENERAL_CHAT_DOCK.overflowButton
    local list = dock and dock.list
    if list and list.IsShown and list:IsShown() then return false end
    local first = AR.ESC_FIRST
    for i = 1, #first do
      local frame = _G[first[i]]
      if type(frame) == "table" and frame.IsShown and frame:IsShown() then return false end
    end
    -- A controller's Escape, which hands the cursor over first.
    if type(CanAutoSetGamePadCursorControl) == "function" and CanAutoSetGamePadCursorControl(true)
      and not Held(IsModifierKeyDown) then
      return false
    end
    return true
  end

  -- The layer one Escape steps back: the drag (`drag`: one was in the hand
  -- when the key was heard, or is now), else the selection, else the mode.
  -- Answers whether the mode ended.
  local function EscapeLayer(drag)
    if drag then
      if AR.Dragging() then AR.CancelPress(true) end
      return false
    end
    AR.CancelPress()
    if AR.selKind then
      AR.Select(nil)
      return false
    end
    AR.Leave()
    return true
  end

  -- One Escape, one layer. From the keyboard (`fromKey`), the character
  -- groups' window -- which the grid's card opens (a host's FollowBlockLink)
  -- -- is a layer of its own, after the drag. From the client's pass, the
  -- same pass may have closed that window: then the press was that
  -- window's, and the mode keeps its layers.
  local function Answer(fromKey)
    local drag = AR._escDrag or AR._escDone or AR.Dragging()
    AR._escHeld, AR._escDrag, AR._escDone = nil, nil, nil
    if not AR.host then return end
    local groups = ns.CharacterGroups
    local theirs = false
    if fromKey then
      if not drag and groups and type(groups.EditorShown) == "function" and groups.EditorShown() then
        theirs = true
        groups.CloseEditor()
      end
    else
      theirs = groups ~= nil and AR._escAt ~= nil and groups._hiddenAt == AR._escAt
    end
    if not theirs then
      local ok, left = pcall(EscapeLayer, drag)
      if not ok and type(geterrorhandler) == "function" then geterrorhandler()(left) end
      if ok and left then return end
    end
    if not AR.host then return end
    -- The mode stays open. In the client's pass (combat), the catcher,
    -- whose name still stands in the windows' places, listens again.
    AR.GuardEscape()
    local catcher = AR._esc
    if catcher and AR._escTaken then
      catcher.armed = true
      catcher:Show()
    end
  end

  function AR.OnEscape() Answer(false) end
  function AR.OnEscapeKey() Answer(true) end

  -- Heard: the answer waits a frame, as the window's own close does
  -- (COMBAT_TAINT.md), and only our own state is read now -- whether a drag
  -- is in progress, which makes the Escape the drag's.
  local function Heard()
    AR._escAt = GetTime()
    AR._escHeld, AR._escDrag = true, AR.Dragging()
  end

  ---------------------------------------------------------------
  -- The keyboard (out of combat)
  ---------------------------------------------------------------

  -- Keys pass again. In combat propagation cannot be set, and the frame
  -- hides instead: a hidden frame takes no keys at all.
  local function PassKeys(self)
    if self:GetPropagateKeyboardInput() then return end
    if InCombatLockdown() then
      self:Hide()
    else
      self:SetPropagateKeyboardInput(true)
    end
  end

  -- The frame after a press was kept: keys pass, then the press is answered.
  local function KeyAnswer(self)
    self:SetScript("OnUpdate", nil)
    self.pending = nil
    PassKeys(self)
    Answer(true)
  end

  local function OnKeyDown(self, pressed)
    if InCombatLockdown() then
      -- Shown in combat, which it is not meant to be: out of the way.
      self:Hide()
      return
    end
    local ok, ours = pcall(AR.EscapeIsOurs, pressed)
    if not (ok and ours) then
      -- Passed on. Set back only if a press this same frame had kept it.
      if not self:GetPropagateKeyboardInput() then self:SetPropagateKeyboardInput(true) end
      return
    end
    -- The way back is armed before the key is kept. A second press inside
    -- the same frame is kept too, the first being answered already.
    if not self.pending then
      self.pending = true
      self:SetScript("OnUpdate", KeyAnswer)
      Heard()
    end
    if self:GetPropagateKeyboardInput() then self:SetPropagateKeyboardInput(false) end
  end

  local function KeyHidden(self)
    self:SetScript("OnUpdate", nil)
    PassKeys(self)
    -- Hidden with a press unanswered (combat began, or the mode went): it
    -- is answered a frame later all the same.
    if self.pending then
      self.pending = nil
      C_Timer.After(0, AR.OnEscapeKey)
    end
  end

  -- The keyboard frame, made on first use out of combat, propagation on
  -- before it is ever shown. It stands in the host window's strata, just
  -- over it, so a frame above the window that keeps keys of its own hears
  -- them first. On UIParent rather than in the window: a host skin sweeps a
  -- window's children for art. Answers whether it is taking keys; it never
  -- does in combat.
  local function KeyOn()
    local host = AR.host
    if not host or InCombatLockdown() then return false end
    local key = AR._key
    if not key then
      if type(CreateFrame) ~= "function" then return false end
      key = CreateFrame("Frame", nil, UIParent)
      if type(key.EnableKeyboard) ~= "function" or type(key.SetPropagateKeyboardInput) ~= "function"
        or type(key.GetPropagateKeyboardInput) ~= "function" then
        return false
      end
      key:Hide()
      key:SetPropagateKeyboardInput(true)
      key:EnableKeyboard(true)
      key:SetScript("OnKeyDown", OnKeyDown)
      key:SetScript("OnKeyUp", PassKeys)
      key:SetScript("OnShow", PassKeys)
      key:SetScript("OnHide", KeyHidden)
      AR._key = key
    end
    local owner = host.owner
    if owner and owner.GetFrameStrata then
      key:SetFrameStrata(owner:GetFrameStrata())
      key:SetFrameLevel(math.min((owner:GetFrameLevel() or 0) + 1, 10000))
    end
    key:SetPropagateKeyboardInput(true)
    key:Show()
    return true
  end

  local function KeyOff()
    local key = AR._key
    if key then key:Hide() end
  end

  ---------------------------------------------------------------
  -- The client's pass (combat)
  ---------------------------------------------------------------

  -- Every entry of UISpecialFrames that names a window of ours, swapped for
  -- the catcher and remembered, while the swap stands. Entries are only
  -- rewritten, never added.
  function AR.GuardEscape()
    local list, taken = UISpecialFrames, AR._escTaken
    if type(list) ~= "table" or not taken then return end
    for i, name in pairs(list) do
      if AR.ESC_WINDOWS[name] then
        taken[i] = name
        list[i] = ESC_NAME
      end
    end
  end

  local function Swap(on)
    local list, catcher = UISpecialFrames, AR._esc
    if type(list) ~= "table" or not catcher then return end
    if on then
      local taken = {}
      AR._escTaken = taken
      AR.GuardEscape()
      -- No window of ours listed (its name registers on first open): the
      -- catcher still has to be heard.
      if not next(taken) then
        list[#list + 1] = ESC_NAME
        taken.appended = #list
      end
      catcher.armed = true
      catcher:Show()
      return
    end
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

  local function OnCatcherEvent(_, event)
    if not AR.host then return end
    if event == "PLAYER_REGEN_DISABLED" then
      -- Before the lockdown: keys pass and the frame goes for the fight.
      KeyOff()
    elseif event == "PLAYER_REGEN_ENABLED" then
      KeyOn()
    elseif event == "UPDATE_BINDINGS" then
      ReadMenuKeys()
    end
  end

  local function Catcher()
    local catcher = AR._esc
    if catcher then return catcher end
    catcher = CreateFrame("Frame", ESC_NAME, UIParent)
    catcher:SetSize(1, 1)
    catcher:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    catcher:EnableMouse(false)
    catcher:Hide()
    catcher:SetScript("OnHide", function(self)
      if not self.armed then return end
      self.armed = false
      -- Hidden by the client's close-windows pass on an Escape.
      Heard()
      C_Timer.After(0, AR.OnEscape)
    end)
    catcher:SetScript("OnEvent", OnCatcherEvent)
    AR._esc = catcher
    return catcher
  end

  -- The mode opening (`on`) and ending: the client's pass listened to for
  -- the whole mode, the keyboard out of combat, and the events that take
  -- the keyboard away for a fight and give it back.
  function AR.CatchEscape(on)
    local catcher = Catcher()
    if on then
      ReadMenuKeys()
      catcher:RegisterEvent("PLAYER_REGEN_DISABLED")
      catcher:RegisterEvent("PLAYER_REGEN_ENABLED")
      catcher:RegisterEvent("UPDATE_BINDINGS")
      Swap(true)
      KeyOn()
    else
      catcher:UnregisterAllEvents()
      KeyOff()
      Swap(false)
    end
  end
end

-------------------------------------------------------------
-- 6. The column header
--
-- While the mode is open, the list's top row steps aside (Inbox, History and
-- the search on the Mail tab; the box, its sort, the picker and the search
-- in Mail Memory) and a column header takes its place, so the list itself
-- does not move. The columns tile the row, and a heading is its column's
-- box: from the line between its lane and the one before it to the line
-- after it, the first from the row's left edge and the last to its right
-- edge, GAP between two. So the row's edge insets are room inside the
-- columns at its ends, and a mark a row keeps at its end (a read mail's
-- delete mark) stands over the last column's box. A line stands in the
-- middle of the gap between two lanes, the lanes being the columns' content
-- as RV.Place publishes it for the list (s.laneX, s.laneW, from the row's
-- left edge, which is the header's; s.width, where the row ends). One
-- rule, whichever column stands where, and the same box outlines the
-- column's cells on the rows
-- (AR.CellBox, section 7b): each column's home, where a row with every
-- figure has it in Columns, whichever Row layout the rows follow (in the
-- mode as out of it; packed, a row without a figure shows its others out
-- from under their headings, which is what Packed does). A heading's glyph stands
-- in the middle of its box, from line to line, whatever the lane under it
-- draws; a name starts where its lane does. The narrow columns wear glyphs
-- (the read dot, the icon, the hourglass, the coin, the slots, History's
-- age), with their names in the tooltip and the inspector; the subject's
-- heading carries the stretch arrow across the room it takes, after its
-- name.
--
-- The header describes the list shown and the arrangement it follows
-- (AR.Layout): History's has its age and none of the columns History does
-- not draw (the read mark, the time left, the slots), and a column the list
-- has no such column for at all (the spec's el names what a list draws)
-- has no heading and no peg in it. A hidden column is a peg on the header
-- where it stands, its crossed eye and nothing else; a click on it, or a right-click, shows the
-- column again, there. A shown one with no lane in this list -- no mail
-- listed has it -- keeps a narrow dimmed heading in its place. Pegs and
-- narrow headings take no room: they stand over the line between the two
-- headings either side of them, on top of those headings' plates (a peg
-- above a narrow heading, both above the plates), so every heading keeps
-- its whole box and is one rectangle with its column's cells. They are the
-- header's alone: the rows have no such column. With no
-- lanes at all -- an empty list, or Larger mail rows, whose figures are a
-- line of text -- the header keeps the one-line order at widths of its own,
-- pegs among them.
--
-- Headings are movable things (section 3b): at rest, pointed at, selected,
-- in the hand. A press on one, or on its column in any row (section 7a), is
-- the column's: a drag moves it, a click selects it for the inspector, a
-- right-click hides it (the subject's does nothing), wherever on the
-- heading the press lands. A shown heading wears no eye, pointed at or
-- not: the header has little room, and its tooltip says the right-click;
-- a hidden column's peg is the crossed eye.
--
-- The header spans what the list spans: from the rows' left edge to their
-- right edge while nothing scrolls, the same inset on both sides (the
-- host's PlaceStrip). While the list scrolls the rows end at the scroll
-- track, and so does the last column's box; the last column's heading
-- carries its plate on over the track's column to the header's end (a peg
-- or a narrow heading after it standing over its end; without lanes,
-- whatever stands last carries it), the one place a heading's
-- plate is wider than its box; what it shows is still placed on its box
-- (its glyph in the box's middle, its name and the stretch arrow fitted to
-- the box).
--
-- Built the first time the mode opens over a list, and laid out again after
-- every pass of the list's rows (AR.ListPlaced): the lanes are the rows'.
-- Every table the layout fills is made with the header.
-------------------------------------------------------------

local HEAD = {
  PAD = 3,          -- the tick where the subject stops stands this far past its text
  GAP = 2,          -- between two columns' boxes
  PEG = 12,         -- a hidden column's peg
  RUN_GAP = 1,      -- between pegs and narrow headings standing together
  TEXT = 4,         -- a name's inset from its heading's edges
  ARROW_GAP = 6,    -- the subject's name to its stretch arrow
  ARROW_MIN = 12,   -- the shortest stretch arrow drawn
  SUBJECT_MIN = 40, -- the subject's heading where the list has no lanes
  SLACK = 4,        -- how far back the hand comes before a drag swaps back (section 7)
  -- A shown heading with no lane of its own.
  NARROW = { read = 14, icon = 22, sender = 44, subject = 60, time = 22, money = 22, slots = 22, age = 22 },
  -- Every heading's width where the list publishes no lanes.
  FALLBACK = { read = 14, icon = 24, sender = 72, time = 22, money = 40, slots = 42, age = 36 },
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

-- A heading's tooltip: its column's name, why it has no lane where it has
-- none, and the gestures. Not over the selected one, whose card is in the
-- inspector, nor during a drag.
local function HeadTip(head)
  if AR.drag then return end
  if AR.Selected("column", head.colId) then return end
  local spec = AR.COLUMNS[head.colId]
  GameTooltip:SetOwner(head, "ANCHOR_TOP")
  GameTooltip:SetText(L()[spec.title])
  if head.colId == "read" then GameTooltip:AddLine(L()["COL_READ_STUCK"], 1, 1, 1, true) end
  if head.narrow then GameTooltip:AddLine(L()["ARRANGE_HEADING_EMPTY"], 1, 1, 1, true) end
  GameTooltip:AddLine(AR.GestureLine(spec.fixed and "fixed" or "hide"), 0.7, 0.7, 0.7, true)
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
    elseif head.glyphKind == "hourglass" or head.glyphKind == "history" or head.glyphKind == "slot" then
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
-- and the subject's arrow fitted to its box (`_w`, which the last heading's
-- plate runs past): again only when one of them changes (AR.LayoutStrip).
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
  arrow[3]:ClearAllPoints()
  arrow[3]:SetPoint("RIGHT", head, "LEFT", w - HEAD.TEXT, 0)
  for k = 1, 3 do arrow[k]:SetShown(show) end
end

-- Where a heading's glyph and name stand in its box of width `w` (above):
-- a glyph in the middle, however wide the box and wherever in it the lane
-- lies; a name from its lane's start (`lx`, from the box's left) where the
-- list has one, else at the inset.
function AR.HeadContent(w, lx)
  local tx = HEAD.TEXT
  if lx then tx = math.max(lx, HEAD.TEXT) end
  return w / 2, tx
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

-- A right-click, let go over the heading: the column hidden (AR.ToggleColumn).
local function HeadUp(self, button)
  if button ~= "RightButton" or not self:IsMouseOver() then return end
  local host = AR.host
  if host and host.strip == self:GetParent() then AR.ToggleColumn(self.colId) end
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
  elseif kind == "hourglass" or kind == "history" then
    -- At the glyph's own height (the history mark a unit wider, for its
    -- arrow's head).
    glyph = T.Glyph and T.Glyph(head, kind, 11, "ARTWORK") or nil
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
  head:SetScript("OnMouseUp", HeadUp)
  return head
end

-- A hidden column's peg: a dark plate with the crossed eye, lighter when
-- pointed at, there or where a row shows the column anyway (section 7a).
local function PaintPeg(peg)
  local hover = peg.hover or AR.rowHover == peg.colId
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
  GameTooltip:AddLine(L()["ARRANGE_HIDDEN_STATE"], 1, 1, 1, true)
  GameTooltip:AddLine(L()["ARRANGE_PEG_TIP"], 0.7, 0.7, 0.7, true)
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
  -- In the peg's own width, which the last peg's plate runs past.
  if peg.Eye then peg.Eye:SetPoint("CENTER", peg, "LEFT", HEAD.PEG / 2, 0) end
  peg:SetScript("OnEnter", PegEnter)
  peg:SetScript("OnLeave", PegLeave)
  -- The peg is its crossed eye: a click on it shows the column, and so does
  -- a right-click, as it would on any hidden thing.
  peg:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  peg:SetScript("OnClick", AR.ShowPeg)
  PaintPeg(peg)
  peg:Hide()
  return peg
end

function AR.BuildStrip(host)
  local T = Th()
  local strip = CreateFrame("Frame", nil, host.owner)
  strip:SetHeight(T.Metrics.tileHeight)
  -- From the rows' left edge to their right edge while nothing scrolls
  -- (above).
  host.PlaceStrip(strip)
  strip:Hide()
  strip.heads, strip.pegs = {}, {}
  -- The layout's working tables, made once: each column's heading x and
  -- width, its kind ("lane", "narrow", "peg", or "absent" where the list
  -- has no such column), a lane's heading box (where a row is hit),
  -- whether it stands over the line between two, and the columns with a
  -- place on the header, in order.
  strip.bx, strip.bw, strip.kind, strip.hx, strip.hw, strip.over = {}, {}, {}, {}, {}, {}
  strip.order = {}
  for id in pairs(AR.COLUMNS) do
    strip.heads[id] = BuildHead(strip, id)
    strip.pegs[id] = BuildPeg(strip, id)
    strip.kind[id] = "absent"
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
-- beside the subject, and a peg's width elsewhere for one that wears a
-- glyph.
local function RunWidth(strip, id, beside)
  if strip.kind[id] == "peg" then return HEAD.PEG end
  if not beside then
    local head = strip.heads[id]
    if head and head.Glyph then return HEAD.PEG end
  end
  return HEAD.NARROW[id] or 22
end

-- Each run stands over the line between the two headings either side of
-- it, centred on it, on top of their plates: no heading gives it any room,
-- so every heading keeps its whole box and is one rectangle with its
-- column's cells, wherever a column is hidden. Before the first heading a
-- run stands from the header's start over the first heading; after the
-- last, against the header's end over the last one's. The rows have no
-- such column: the run is the header's alone. `order` holds the `n`
-- columns with a place on the header, which runs from 0 to `span`.
function AR.PlaceRuns(order, n, strip, span)
  local bx, bw, over = strip.bx, strip.bw, strip.over
  local i = 1
  while i <= n do
    if bx[order[i]] == nil then
      local a = (i > 1) and order[i - 1] or nil
      local j = i
      while j <= n and bx[order[j]] == nil do j = j + 1 end
      local b = (j <= n) and order[j] or nil
      local beside = a == "subject" or b == "subject"
      local total = -HEAD.RUN_GAP
      for k = i, j - 1 do total = total + RunWidth(strip, order[k], beside) + HEAD.RUN_GAP end
      -- The line: in the middle of the gap after the heading before it.
      local line = 0
      if a then
        line = bx[a] + bw[a] + HEAD.GAP / 2
      elseif b then
        line = bx[b] - HEAD.GAP / 2
      end
      local x = math.floor(line - total / 2 + 0.5)
      x = math.max(0, math.min(x, span - total))
      for k = i, j - 1 do
        local id = order[k]
        local w = RunWidth(strip, id, beside)
        bx[id], bw[id], over[id] = x, w, true
        x = x + w + HEAD.RUN_GAP
      end
      i = j
    else
      i = i + 1
    end
  end
end

-- The header laid out on the list's lanes (above), and put on screen: a
-- heading, or a peg, per column the list has in the arrangement it follows,
-- and the last one's plate carried on to the header's end; the heading in
-- the hand is left where the cursor holds it and its slot takes the ghost.
-- A column the other arrangement has and this one has not (History's age
-- over the mail rows, their read mark over History) has neither. Anchored
-- again only where a place, a width or where its glyph and name stand
-- changed.
function AR.LayoutStrip(host)
  local strip = host and host.strip
  local layout = AR.Layout()
  if not (strip and layout) then return end
  AR.SyncLanes(strip)
  local width = strip:GetWidth() or 0
  if width < 60 then return end
  local n = #layout
  local spec = host.Spec and host.Spec()
  local laneX, laneW = spec and spec.laneX, spec and spec.laneW
  local lanes = laneX ~= nil and laneW ~= nil and laneW.subject ~= nil and laneX.subject ~= nil
  -- What the list draws at all (the spec's regions, once a row has been
  -- placed): a column it has no such column for takes no place (above).
  local has = spec and spec.el
  if has and has.subject == nil then has = nil end
  local bx, bw, kind, hx, hw, order = strip.bx, strip.bw, strip.kind, strip.hx, strip.hw, strip.order
  local span = width
  local count = 0
  -- Every column the header could show starts with no place, the ones
  -- this arrangement has not among them.
  for id in pairs(kind) do
    kind[id] = "absent"
    bx[id], bw[id], hx[id], hw[id], strip.over[id] = nil, nil, nil, nil, nil
  end
  for i = 1, n do
    local id = layout[i].id
    if has and has[id] == nil then
      kind[id] = "absent"
    elseif not layout[i].shown and not AR.COLUMNS[id].fixed then
      kind[id] = "peg"
    elseif not lanes then
      kind[id] = "lane"
    elseif laneX[id] ~= nil and (laneW[id] or 0) > 0 then
      kind[id] = "lane"
    else
      kind[id] = "narrow"
    end
    if kind[id] ~= "absent" then
      count = count + 1
      order[count] = id
    end
  end
  for i = count + 1, #order do order[i] = nil end
  if lanes then
    -- The columns tile the row (above): each lane's heading ends on the
    -- line between its lane and the next, in the middle of the gap between
    -- them, and the next starts GAP after that line; the first starts where
    -- the row does and the last ends where the row does (its plate runs on,
    -- below).
    span = math.max(math.min(spec.width or width, width), 60)
    local prev
    for i = 1, count do
      local id = order[i]
      if kind[id] == "lane" then
        if prev then
          local line = math.floor((laneX[prev] + laneW[prev] + laneX[id]) / 2)
          bw[prev] = math.max(line - bx[prev], 1)
          bx[id] = line + HEAD.GAP
        else
          bx[id] = 0
        end
        prev = id
      end
    end
    if prev then bw[prev] = math.max(span - bx[prev], 1) end
    for i = 1, count do
      local id = order[i]
      if kind[id] == "lane" then hx[id], hw[id] = bx[id], bw[id] end
    end
    AR.PlaceRuns(order, count, strip, span)
  else
    -- No lanes: the one-line order at the header's own widths, pegs among
    -- them, the subject taking what they leave.
    local total = 0
    for i = 1, count do
      local id = order[i]
      if kind[id] == "peg" then
        total = total + HEAD.PEG
      elseif id ~= "subject" then
        total = total + (HEAD.FALLBACK[id] or 40)
      end
    end
    local subjectW = math.max(width - total - HEAD.GAP * math.max(count - 1, 0), HEAD.SUBJECT_MIN)
    local x = 0
    for i = 1, count do
      local id = order[i]
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

  -- The last on the header, whose plate runs on to its end: on lanes, the
  -- last column's heading, a run at the end standing over it.
  local last = order[count]
  if lanes then
    for i = count, 1, -1 do
      if kind[order[i]] == "lane" then
        last = order[i]
        break
      end
    end
  end
  local drag = AR.drag
  for id, head in pairs(strip.heads) do
    local peg = strip.pegs[id]
    if peg then
      if kind[id] == "absent" then
        head:Hide()
        peg:Hide()
      elseif kind[id] == "peg" then
        head:Hide()
        if peg._x ~= bx[id] then
          peg:ClearAllPoints()
          peg:SetPoint("LEFT", strip, "LEFT", bx[id], 0)
          peg._x = bx[id]
        end
        local pw = HEAD.PEG
        if id == last then pw = math.max(width - bx[id], pw) end
        if peg._pw ~= pw then
          peg._pw = pw
          peg:SetWidth(pw)
        end
        peg:Show()
      else
        peg:Hide()
        local narrow = kind[id] == "narrow"
        local w = bw[id]
        local pw = w
        if id == last then pw = math.max(width - bx[id], w) end
        local lx
        if lanes and not narrow then lx = laneX[id] - bx[id] end
        local cx, tx = AR.HeadContent(w, lx)
        if head._w ~= w or head._pw ~= pw or head.narrow ~= narrow or head._cx ~= cx or head._tx ~= tx then
          head._w, head._pw, head.narrow, head._cx, head._tx = w, pw, narrow, cx, tx
          head:SetWidth(pw)
          AR.FitHead(head)
        end
        if drag and drag.id == id then
          local ghost = strip.Ghost
          ghost:ClearAllPoints()
          ghost:SetPoint("LEFT", strip, "LEFT", bx[id], 0)
          ghost:SetSize(pw, Th().Metrics.tileHeight)
          AR.PaintGhost(ghost)
          ghost:Show()
        else
          if head._x ~= bx[id] then
            head:ClearAllPoints()
            head:SetPoint("LEFT", strip, "LEFT", bx[id], 0)
            head._x = bx[id]
          end
          -- Over the line between two, a narrow heading stands a few levels
          -- up, under the pegs.
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
-- header; when its leading edge crosses the middle of the heading beside it
-- -- its left edge the one before it, its right edge the one after -- the
-- two change places, in the arrangement itself, so the rows re-lay under it
-- and the header stands on their new lanes, the heading's slot ringed. By
-- its edges, not its middle: the hand stops at the header's ends, and a
-- column wider than the one at the end it is dragged to could never bring
-- its own middle past that one's. A change back the other way waits until
-- the hand has come back HEAD.SLACK from where the last one happened, so a
-- hand held still on the line -- or a heading whose width changes with its
-- place, as the headings round the subject's do -- never flips the two
-- back and forth. In the rows the
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
  local drag = AR.drag
  if drag and drag.before then AR.SetLayout(drag.before, drag.history) end
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
    -- The arrangement as it was, and which one, for Escape to put back;
    -- and the rows whose cells ride in the hand (AR.LetGo).
    before = CopyLayout(), history = AR.EditsHistory(), pool = host.Pool and host.Pool() or nil,
  }
  head:SetFrameLevel(strip:GetFrameLevel() + 20)
  -- Lifted a unit above and below its place.
  head:SetHeight(Th().Metrics.tileHeight + 2)
  AR.LayoutStrip(host)
  AR.ShowHand(host)
  RefocusRows()
end

-- The heading follows the cursor along the header, and the column's lane
-- follows it over the rows. The heading stops at the header's ends; where
-- it changes places is read from the hand -- where the cursor would have
-- it -- so pushing on past an end takes it on to the last slot, and a
-- heading whose width changes as it lands against an end is not pulled
-- back by its own stop.
function AR.DragColumn(host, cursorX)
  local drag, strip = AR.drag, host.strip
  if not (drag and strip) then return end
  local head = drag.head
  local left = strip:GetLeft()
  if not left then return end
  -- Its box decides where it changes places; its plate, which runs on to
  -- the header's end in the last slot, where it stops.
  local w = head._w or head:GetWidth() or 0
  local hand = cursorX - left - drag.grab
  local x = math.min(math.max(hand, 0), math.max((strip:GetWidth() or 0) - (head._pw or w), 0))
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
    -- The neighbours on the header: a column this list has no place for
    -- (section 6) is passed over, and moves past with the one it is beside.
    local p, q = k - 1, k + 1
    while p >= 1 and bx[layout[p].id] == nil do p = p - 1 end
    while q <= #layout and bx[layout[q].id] == nil do q = q + 1 end
    local prev, nxt = layout[p], layout[q]
    -- Only the way the hand is from its slot: in a crowded header a run of
    -- pegs may stand over the edge of the heading before it, its middle on
    -- the wrong side of that heading's.
    local last, at, home = drag.swapDir, drag.swapX or hand, bx[drag.id] or hand
    local target
    if prev and bx[prev.id] and hand < home and hand < bx[prev.id] + bw[prev.id] / 2
        and (last ~= 1 or hand <= at - HEAD.SLACK) then
      target = p
    elseif nxt and bx[nxt.id] and hand > home and hand + w > bx[nxt.id] + bw[nxt.id] / 2
        and (last ~= -1 or hand >= at + HEAD.SLACK) then
      target = q
    end
    if target then
      drag.swapDir, drag.swapX = (target < k) and -1 or 1, hand
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
  if host and host.cover then host.cover._cx = false end
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
--                    from the header through the rows, while the rows line
--                    up (closed up, no row stands in lanes);
--   the press        on any row, the column whose box is under the cursor
--                    -- closed up, the one that row drew there, and on a
--                    two-line row whatever it draws there -- is taken as
--                    its heading would be, and a right-click hides it;
--                    pointed at, it looks as its heading does pointed at
--                    (AR.SetRowHover). So a click on a row does nothing
--                    else while the mode is open: nothing opens, nothing
--                    is collected;
--   the hand         while a column is dragged, the column riding offset in
--                    a lifted lane at its home, its cells copied onto the
--                    lane from the rows -- closed up, gathered into it as a
--                    lined-up row has them -- and, lined up, its slot
--                    ringed down the list.
-- The mouse wheel is not taken: the list still scrolls under it. Nothing
-- here runs while the mode is closed; pointed at, a look a frame at where
-- the cursor is, which goes on to which column only when the cursor moved
-- and changes something only when that column changed, gone with the
-- pointer.
-------------------------------------------------------------

-- Which column a press or the pointer on the list is over, or nil: by the
-- lanes where the rows line up, by what the row draws otherwise.
local REGION_OF = { read = "Indicator", icon = "Icon", sender = "Sender", subject = "Subject" }

-- Every column's region on a row, by id (History's gold is its Money).
local ROW_REGION = {
  read = "Indicator", icon = "Icon", sender = "Sender", subject = "Subject",
  time = "ColTime", money = "ColMoney", slots = "ColSlots", age = "Age",
}

-- Where a column region stands on its row, from where RV.Place anchored it
-- (RV.Anchor: by its left edge, or by its right one on a row `width`
-- wide), and how wide it is: its left edge and width, in the row's units.
function AR.RegionSpan(region, width)
  local w = region:GetWidth() or 0
  local left = region.__pbAtX or 0
  if region.__pbAt == 2 then left = (width or 0) + left - w end
  return left, w
end

-- Packed, the column a press on a row takes is the one that row drew
-- there, not a lane: each column where the row placed it, the subject with
-- the room its quality mark keeps, and the nearest to the cursor wins, so a
-- press between two goes to the nearer. Only inside the row (as the
-- headings span it; a mark the row keeps at its end stands over its last
-- column). Nothing is made.
function AR.RowColumnAt(host, cx, cy)
  local pool = host.Pool and host.Pool()
  local spec = host.Spec and host.Spec()
  local layout = AR.Layout()
  if not (pool and spec and layout) then return nil end
  for i = 1, #pool do
    local row = pool[i]
    if row:IsShown() then
      local top, bottom, left = row:GetTop(), row:GetBottom(), row:GetLeft()
      if top and bottom and left and cy <= top and cy >= bottom then
        local x = cx - left
        if x < 0 or x > (spec.width or x) then return nil end
        local best, bestD
        for k = 1, #layout do
          local id = layout[k].id
          local region = row[ROW_REGION[id]] or (id == "money" and row.Money) or nil
          if region and region:IsShown() then
            local l, w = AR.RegionSpan(region, spec.width)
            if id == "subject" then l, w = l - (spec.markW or 0), w + (spec.markW or 0) end
            local d = 0
            if x < l then d = l - x elseif x > l + w then d = x - l - w end
            if not bestD or d < bestD then best, bestD = id, d end
          end
        end
        return best
      end
    end
  end
  return nil
end

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
  if strip.lanes and not strip.lined then return AR.RowColumnAt(host, cx, cy) end
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

-- The column the pointer is over in the rows, where that points at a
-- column as its heading does: one with a heading on the header, not a
-- peg's (a hidden column a row shows anyway).
function AR.Pointed()
  local id = AR.rowHover
  local strip = AR.host and AR.host.strip
  if not (id and strip and AR.COLUMNS[id]) then return nil end
  local kind = strip.kind[id]
  if kind == "lane" or kind == "narrow" then return id end
  return nil
end

-- What the pointer is over in the rows looks as its heading does pointed
-- at: a column's heading lights and its cells are outlined (it is the
-- rows' focus, AR.UpdateFocus), with the move cross; a peg lights, with
-- the pointer left as it is. No tooltip: the header's are for the header,
-- and a tip following the pointer down the list would cover the rows it is
-- about.
function AR.SetRowHover(id)
  local was = AR.rowHover
  AR.rowHover = id
  local strip = AR.host and AR.host.strip
  if strip then
    AR.PaintPointed(strip, was)
    AR.PaintPointed(strip, id)
  end
  AR.UpdateFocus()
  AR.MoveCursor(AR.Pointed() ~= nil)
end

function AR.PaintPointed(strip, id)
  if not id then return end
  local head, peg = strip.heads[id], strip.pegs[id]
  if head then AR.PaintHead(head) end
  if peg then PaintPeg(peg) end
end

-- A frame's look at the pointer, only while it is over the list: nothing
-- when it has not moved since the last, and a change only when what it is
-- over changed. Nothing is made.
local function CoverUpdate(self)
  local host = AR.host
  if not (host and host.cover == self) or AR.drag then return end
  local cx, cy = GetCursorPosition()
  if cx == self._cx and cy == self._cy then return end
  self._cx, self._cy = cx, cy
  local id = AR.ColumnAt(host)
  if id ~= AR.rowHover then AR.SetRowHover(id) end
end

local function CoverEnter(self)
  self._cx, self._cy = false, false
  self:SetScript("OnUpdate", CoverUpdate)
end

local function CoverLeave(self)
  self:SetScript("OnUpdate", nil)
  self._cx, self._cy = false, false
  if AR.rowHover then AR.SetRowHover(nil) end
end

local function CoverDown(self, button)
  if button ~= "LeftButton" then return end
  local host = AR.host
  if not (host and host.cover == self) then return end
  local id = AR.ColumnAt(host)
  if id then AR.PressColumn(host, id, self) end
end

-- A right-click on a row hides the column it lands on, as one on its
-- heading does.
local function CoverUp(self, button)
  if button ~= "RightButton" or not self:IsMouseOver() then return end
  local host = AR.host
  if not (host and host.cover == self) then return end
  local id = AR.ColumnAt(host)
  if id then AR.ToggleColumn(id) end
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
  -- Where the pointer was at the last look (CoverUpdate).
  cover._cx, cover._cy = false, false
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
  cover:SetScript("OnMouseUp", CoverUp)
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
-- it ends (AR.LayoutStrip). None without lanes, nor while the rows close
-- up: no row stands in them then.
function AR.PlaceLines(host)
  local cover, strip = host.cover, host.strip
  if not (cover and strip) then return end
  local layout = AR.Layout()
  local count = 0
  if strip.lanes and strip.lined and layout then
    local hx, hw, kind = strip.hx, strip.hw, strip.kind
    local prev = false
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

-- The dragged column's lane over the list, offset by as much as its heading
-- is from its slot, and while the rows line up the slot ringed down the
-- list; closed up no row has that slot, and the header's ring says where
-- it lands. Only where the rows have lanes.
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
  ghost:SetShown(strip.lined and true or false)
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
  AR.SyncList(host)
  local spec = host.Spec and host.Spec()
  local widths = spec and spec.laneW
  if widths then
    for id in pairs(widths) do widths[id] = nil end
  end
end

function AR.ListPlaced(owner)
  local host = AR.host
  if not (host and host.owner == owner) then return end
  -- Rows placed again may put another column under a pointer held still
  -- (a closed-up list scrolled by the wheel): looked at once more.
  if host.cover then host.cover._cx = false end
  AR.CoverLevel(host)
  AR.LayoutStrip(host)
  if AR.drag then AR.PlaceHand(host) end
  -- A list switched under the mode: the inspector says what the one now
  -- shown has, once its rows stand.
  if AR.relisted then
    AR.relisted = false
    AR.Inspect()
  end
end

-- A column in the hand let go where it is, nothing dropped: the heading
-- back on the header and the rows' cells off the lane, the rows it was
-- carried from among them (drag.pool) whether or not they still show.
-- Nothing is placed again: the caller's pass does that.
function AR.LetGo(host)
  local drag = AR.drag
  AR.drag = nil
  if not drag then return end
  drag.head:SetFrameLevel(drag.level)
  drag.head:SetHeight(Th().Metrics.tileHeight)
  drag.head._x = nil
  local pool = drag.pool
  if pool then
    for i = 1, #pool do AR.UnmarkRow(pool[i]) end
  end
  if host then
    AR.HideHand(host)
    if host.strip then host.strip.Ghost:Hide() end
  end
end

-- The list under the mode switched to one that follows the other
-- arrangement (History, or back from it): the mode arranges that one now.
-- Told as a pass of the list's rows begins (AR.ListPlacing), so every row
-- of the pass is placed for it: a press or a drag is let go -- nothing is
-- dropped into the other arrangement -- and a column the new one has not
-- is let go of, pointed at or selected; the header is laid out on the new
-- lanes as the pass ends (AR.ListPlaced), and the inspector filled again.
-- Nothing binds rows here: the pass under way does.
AR.editsHistory = false

function AR.SyncList(host)
  local history = AR.EditsHistory()
  if AR.editsHistory == history then return end
  AR.editsHistory = history
  AR.CancelPress()
  AR.LetGo(host)
  if AR.moving then AR.moving = nil end
  local layout = AR.Layout()
  local strip = host.strip
  if AR.hover and not (layout and IndexOf(layout, AR.hover)) then AR.hover = nil end
  if AR.rowHover then
    local was = AR.rowHover
    AR.rowHover = nil
    if strip then AR.PaintPointed(strip, was) end
  end
  if AR.selKind == "column" and not (layout and IndexOf(layout, AR.selId)) then
    AR.selKind, AR.selId = nil, nil
  end
  AR.focus = AR.hover or (AR.selKind == "column" and AR.selId) or nil
  AR.relisted = true
end

-------------------------------------------------------------
-- 7b. The rows while arranging
--
-- RV.Place hands each row it places while the mode points at a column
-- (AR.Focus: the one in the hand, else under the pointer on its heading or
-- in the rows, else the selected one) to AR.MarkRow, with where the row's
-- subject stands and runs. What is marked is the column's box on the row
-- (AR.CellBox): the rule the header's boxes follow (section 6), so a
-- column's cells and its heading are one rectangle, from the line before it
-- to the line after it, the first from the row's left edge and the last to
-- its right edge. On a one-line row lined up, which stands in lanes:
--   a column         its box washed where the row draws it; for a figure,
--                    hatched where the subject runs on through it, and
--                    outlined where the mail has none and the subject
--                    stopped short of it;
--   the subject      its own box washed, the boxes it borrowed from empty
--                    columns hatched, and a tick where it stops;
--   in the hand      the row's cell leaves its lane and rides on the lifted
--                    lane over the list (7a).
-- Packed, a row's columns are its own: a column's box between what this
-- row draws either side of it, washed where the row drew it, and nothing on
-- a row without it (the subject has its room); the subject's box washed and
-- a tick where it stops, which is where the mail's own figures begin; in
-- the hand, a figure's cell rides on the
-- lifted lane where a row with every figure has it, so the column in the
-- hand reads as one. The accent while the column is selected or in the
-- hand, white while it is only pointed at. A two-line row keeps RV.Wash's
-- wash around what it draws of the column. Every mark is a texture of the
-- row's own, made the first time the row needs one and reused, as
-- RV.Wash's is; a mark is anchored again only where it moved. RV.Wash with
-- nothing to point at takes them all away (AR.UnmarkRow).
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
-- has it, moved by the drag's offset. The subject's is its own room. A
-- figure named `home` (a closed-up row's) rides in its home lane instead,
-- where a row with every figure has it, so the column in the hand reads as
-- one down the list.
local function Carry(row, m, region, s, x, subjectW, dx, home)
  local host = AR.host
  local cover = host and host.cover
  if not cover then return end
  local carry = m.carry
  if not carry or carry.cover ~= cover then
    carry = NewCarry(cover)
    m.carry = carry
  end
  local left, w = AR.RegionSpan(region, s.width)
  if region == s.el.subject then w = math.max(math.min(w, x + subjectW - left), 1) end
  local lx = home and s.laneX and s.laneX[home]
  local lw = home and s.laneW and s.laneW[home]
  if lx and lw and lw > 0 then left, w = lx, lw end
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

-- Where column `id` stands on a row, for its box: its lane where the rows
-- stand in columns (`lined`) -- every row of a list on the same lanes, a
-- read mail's delete mark drawing over the last one's end -- or where the
-- row drew it, packed; the subject's own room (`x`, `subjectW`) either way.
-- Nil where it has none.
function AR.CellSpan(s, id, lined, x, subjectW)
  local region = s.el[id]
  if region == nil then return nil end
  if id == "subject" then return x, subjectW end
  if lined then
    local lx, lw = s.laneX and s.laneX[id], s.laneW and s.laneW[id]
    if not (lx and lw and lw > 0) then return nil end
    return lx, lw
  end
  if not region:IsShown() then return nil end
  return AR.RegionSpan(region, s.width)
end

-- Column `id`'s box on a row, as its left edge and width in the row's
-- units, or nil where the row has no place for it: from the line between
-- it and what stands before it -- in the middle of the gap between the
-- two, GAP after it -- to the line before what stands after it; the first
-- from the row's left edge, the last to its right edge. The header's rule
-- (AR.LayoutStrip), so on a row that stands where the list's lanes are it
-- is the heading's box. In the arrangement the row was placed by (s.layout,
-- History's; else the one the mode arranges). Nothing is made.
function AR.CellBox(s, id, lined, x, subjectW)
  local layout = s.layout or AR.Layout()
  if not layout then return nil end
  local seen = false
  local lo, w, prevEnd, nextStart
  for k = 1, #layout do
    local col = layout[k].id
    local l, cw = AR.CellSpan(s, col, lined, x, subjectW)
    if col == id then
      seen, lo, w = true, l, cw
    elseif l then
      if not seen then
        prevEnd = l + cw
      elseif not nextStart then
        nextStart = l
      end
    end
  end
  if not lo then return nil end
  local left = 0
  if prevEnd then left = math.floor((prevEnd + lo) / 2) + HEAD.GAP end
  local right = s.width or (lo + w)
  if nextStart then right = math.floor((lo + w + nextStart) / 2) end
  return left, math.max(right - left, 1)
end

-- Where the boxes the subject runs on through end, `runEnd` being where
-- its text may run to on a lined-up row: at the line before the first lane
-- after it, or at the row's end.
function AR.RunLine(s, runEnd)
  local layout = s.layout or AR.Layout()
  local laneX, laneW = s.laneX, s.laneW
  local after = false
  if layout and laneX and laneW then
    for k = 1, #layout do
      local col = layout[k].id
      if after and s.el[col] ~= nil and (laneW[col] or 0) > 0 and laneX[col] then
        local lx = laneX[col]
        if lx >= runEnd - 0.5 then return math.floor((runEnd + lx) / 2) end
      end
      if col == "subject" then after = true end
    end
  end
  return s.width or runEnd
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
-- above. `lanes` is whether the row stands in lanes (lined up); `x`,
-- `subjectW` the subject's own room; `sx`, `run` where it starts and how
-- far it runs (a one-line row's; nil on a two-line row).
function AR.MarkRow(row, s, target, lanes, x, subjectW, sx, run)
  local R = Rules()
  local focus = s.focus
  local host = AR.host
  -- The other window's rows, if it is up, keep the plain wash: the header,
  -- its lanes and the lane in the hand are this list's.
  local list = host and host.List and host.List()
  if not (sx and list and row:GetParent() == list) then
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
      local spec = AR.COLUMNS[focus]
      Carry(row, m, region, s, x, subjectW, drag.dx, (not lanes and spec and spec.figure) and focus or nil)
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
  -- The column's box on this row, by the header's rule.
  local bx, bw = AR.CellBox(s, focus, lanes, x, subjectW)
  local ownEnd = x + subjectW
  local runEnd = sx + (run or subjectW)
  if focus == "subject" then
    if bx then
      MarkBox(row, m, bx, bw, sel and "sel" or "hover")
    else
      HideBox(m)
    end
    if bx and runEnd > ownEnd + 0.5 then
      local from = bx + bw + HEAD.GAP
      MarkHatch(row, m, from, AR.RunLine(s, runEnd) - from, sel, true)
    else
      HideHatch(m)
    end
    MarkTick(row, m, runEnd + HEAD.PAD, sel)
    return
  end
  HideTick(m)
  if not lanes then
    -- Closed up: the column where this row drew it, and nothing on a row
    -- without it, whose subject has that room.
    local region = s.el[focus]
    if bx and region and region:IsShown() then
      MarkBox(row, m, bx, bw, sel and "sel" or "hover")
    else
      HideBox(m)
    end
    HideHatch(m)
    return
  end
  local laneX, laneW = s.laneX, s.laneW
  local lx = laneX and laneX[focus]
  local lw = laneW and laneW[focus] or 0
  if not (lx and bx) or lw <= 0 then
    -- No lane in this list: what the row draws of it, if anything, washed
    -- where it stands.
    HideBox(m)
    HideHatch(m)
    if target and R and R.Wash then R.Wash(row, target) end
    return
  end
  local region = s.el[focus]
  -- A row carrying a delete mark stops its subject short of the mark
  -- (RV.Place, s.markEnd): a lane the run reaches the mark through is lent
  -- all the same.
  local reach = runEnd
  if s.markEnd and runEnd >= (s.width or 0) - s.markEnd - 0.5 then reach = s.width or runEnd end
  if region and region:IsShown() then
    MarkBox(row, m, bx, bw, sel and "sel" or "hover")
    HideHatch(m)
  elseif AR.COLUMNS[focus] and AR.COLUMNS[focus].figure and lx >= ownEnd - 0.5 and lx + lw <= reach + 0.5 then
    MarkBox(row, m, bx, bw, "lent")
    MarkHatch(row, m, bx, bw, false, false)
  else
    MarkBox(row, m, bx, bw, sel and "empty" or "emptyHover")
    HideHatch(m)
  end
end

-------------------------------------------------------------
-- 8. The inspector
--
-- One card docked beside the window being arranged, 8 units out from its
-- right edge (from its left one when the screen has no room on the right),
-- its top level with the window's top row. Shown only while the mode is
-- open, and nothing of it covers the rows. It says one of two things:
--   nothing selected: how the mode works, on the Mail tab which list's
--     arrangement it arranges (the Inbox's or History's: a click switches
--     the list), Row layout, what is hidden
--     (each a chip; a click shows it again), the reset, and that Escape
--     finishes -- or, while something is in the hand, that Escape cancels,
--     the one change a drag makes to it;
--   a column, a block or a category button selected: its card -- what it
--     is, its eye, its own choice, Move (the way to reorder without a
--     drag), and, for a figure, what the rows do on a mail without it; for
--     the subject, what the rows show of its run, what Row layout does
--     and where it is; for a block, the stack's order, each line the way to
--     that block's card (the way to a block that is hard to take in the
--     window), and for the grid the way to the character groups; for a
--     button, the link up to the grid's card.
-- A click on a heading, a column on a row, a block or a button selects it,
-- a second click lets it go; the cross and Escape go back a layer (section
-- 5).
--
-- Built the first time the mode opens and refilled in place: every region
-- exists once, the choices are lists made once, and a fill sets texts,
-- colours and points -- a selection or a pointer allocates nothing. A text
-- is measured once per string and font (Measured). Everything it draws is
-- on child frames of its own: the card itself is tagged for the host skin
-- (Theme.ApplyCard), and EllesmereUI fades a tagged frame's own textures.
--
-- Its type is the mockup's, in the host's own faces, sized as the mockup
-- sizes it against the mail rows (INSP.TYPE): the title in the title role,
-- which stands to the rows as the mockup's does; the words, the chips, Move
-- and the reset a size under the rows' text, the switches and the choices
-- half a size under it, the notes and "to finish" a size and a half, the
-- kickers and the key cap two, the kickers in capitals. The client has no
-- letter spacing: the capitals carry the kickers. Each size is set on the
-- string's own font (Sized), so what a text measures is what it draws: the
-- client's text scale draws a string smaller but measures it at full size.
--
-- Its spacing is the mockup's margins between line boxes: every text keeps
-- the half of its line box's leading above and below it (INSP.LEAD) that a
-- font string, which is only as tall as its lines, does not have, and a
-- paragraph's lines stand the mockup's line height apart (INSP.SPACING).
-------------------------------------------------------------

-- The inspector's measures, from the mockup (concept-c.html), in UI units.
local INSP = {
  W = 208, PAD = 11, TOP = 10, BOTTOM = 11, DOCK = 8,
  CLOSE = 18,                 -- the cross's square, beside the title's line
  HEAD_GAP = 6,               -- the title to what follows it
  ROW_GAP = 8,                -- a text to the switch and Move under it
  ROW_WRAP = 6,               -- the switch to Move, where one row is too narrow
  SWITCH_H = 20, SWITCH_LEAD = 24, SWITCH_TAIL = 8,
  NUDGE_W = 22, NUDGE_H = 18, NUDGE_GAP = 4, MOVE_GAP = 8,
  KICK_TOP = 10, KICK_GAP = 4,
  RADIO_H = 19, RADIO_TEXT = 17,
  -- Row layout's answers: the preview's size, its bars and the gap between
  -- its two rows, its inset from the line's right end, and the room under
  -- an answer's one line.
  PREVIEW_W = 26, PREVIEW_H = 8, PREVIEW_BAR = 3, PREVIEW_GAP = 2, PREVIEW_PAD = 3, LAYOUT_TAIL = 4,
  -- A hidden chip, and the room it keeps above and below (the mockup's
  -- margin): a first row two under its kicker, the foot two further down.
  CHIP_H = 19, CHIP_GAP = 4, CHIP_LEAD = 6, CHIP_EYE = 12, CHIP_EYE_GAP = 5, CHIP_TAIL = 7, CHIP_EDGE = 2,
  LINE_H = 18, LINE_NUM = 14,  -- a block's line in the stack's order, and where its name starts
  NOTE_TOP = 8, NOTE_PAD = 7,
  UP_GAP = 4, UP_ARROW = 10,  -- the link up: its words to its arrow, and the arrow's room
  SWATCH_W = 14, SWATCH_H = 9, SWATCH_GAP = 5,  -- the hatch's sample before a note
  -- The foot: its rule, the row its words are centred on (the reset's line
  -- box), the least room between the reset and the key cap, the cap.
  FOOT_TOP = 10, FOOT_PAD = 7, FOOT_H = 18, FOOT_GAP = 8, KEY_PAD = 4, KEY_H = 15, KEY_GAP = 4,
  -- The mockup's type against the rows' 13: each size as a share of the
  -- small text the rows are set in (bodySmall and secondary).
  TYPE = {
    body = 12 / 13,           -- the words, the chips, Move, the blocks' lines, the reset and the link up
    control = 12.5 / 13,      -- the switches' names and the choices
    note = 11.5 / 13,         -- the notes and "to finish"
    kicker = 10.5 / 13,       -- the kickers and the key cap
  },
  -- Half of each line box's leading, above and below the text: the
  -- mockup's line height (1.32 for the words, 1.3 for the notes, 1.55 for
  -- the title and the kickers) less the host face's line.
  LEAD = { title = 4, body = 2, note = 2, kicker = 3 },
  SPACING = { body = 4, note = 3 },  -- between a paragraph's lines
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

-- A text at its size in the mockup (INSP.TYPE), a share of its role's own:
-- set on the string's font, read once as it is made, so it measures what
-- it draws.
local function Sized(fs, share)
  if not (fs and share and fs.GetFont and fs.SetFont) then return fs end
  local path, size, flags = fs:GetFont()
  if path and size and size > 0 then fs:SetFont(path, size * share, flags or "") end
  return fs
end

-- A text of one of the inspector's sizes, in a role.
local function Text(parent, role, size)
  return Sized(Th().CreateText(parent, role), INSP.TYPE[size])
end

local function PlayToggle(on)
  if type(SOUNDKIT) == "table" and type(PlaySound) == "function" then
    PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
  end
end

-- The column's own choice: the gold's, the time left's, the slots' and
-- History's age's. The lists are made once; what is chosen and how to
-- choose are read each time.
AR.CHOICE_KINDS = { gold = true, expiry = true, slots = true, age = true }

function AR.Choices(kind)
  local ui = UI()
  local lists = AR._choices
  if not lists then
    lists = { none = {} }
    AR._choices = lists
  end
  if not ui or not AR.CHOICE_KINDS[kind] then return lists.none, nil, nil end
  local list = lists[kind]
  if not list then
    local collect = ns.CollectTab
    local age = collect and collect.HistoryAgeText
    if kind == "age" and not age then return lists.none, nil, nil end
    if kind == "age" then
      -- "3d ago" or "3 days ago": each wording as the rows write it, for
      -- three days.
      list = {
        { id = "short", name = age(3, 3, "short") },
        { id = "long",  name = age(3, 3, "long") },
      }
    elseif kind == "gold" then
      list = {
        { id = "both",   name = L()["OPT_GOLD_BOTH"] },
        { id = "earned", name = L()["OPT_GOLD_EARNED"] },
        { id = "spent",  name = L()["OPT_GOLD_SPENT"] },
      }
    elseif kind == "slots" then
      -- "4 slots" or "4": how the rows write the count.
      list = {
        { id = "words",  name = L()["OPT_SLOTS_WORDS"] },
        { id = "number", name = L()["OPT_SLOTS_NUMBER"] },
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
  if kind == "slots" then return list, ui.GetSlotsStyle and ui.GetSlotsStyle(), ui.SetSlotsStyle end
  if kind == "age" then return list, ui.GetHistoryAge and ui.GetHistoryAge(), ui.SetHistoryAge end
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

-- A right-click on a column, on its heading or on any row: hidden if it
-- shows, shown if it is hidden. The subject is never hidden, so its
-- right-click does nothing; nor does one while something is in the hand.
function AR.ToggleColumn(id)
  local spec, layout = AR.COLUMNS[id], AR.Layout()
  if not (AR.host and spec and layout) or spec.fixed or AR.Dragging() then return end
  local on = not layout.shown[id]
  GameTooltip:Hide()
  AR.ShowColumn(id, on)
  PlayToggle(on)
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

-- What is moving, while a drag lasts (section 2), or nil. The inspector
-- keeps what it shows; only its foot changes, to what Escape does now.
function AR.Moving(name)
  if AR.moving == name then return end
  AR.moving = name
  AR.Inspect()
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
  elseif AR.selKind == "button" and host.SetButtonShown then
    host.SetButtonShown(AR.selId, on)
    PlayToggle(on)
  end
  AR.Inspect()
end

-- Row layout, in the overview under how the mode works: the options
-- panel's own choice (MailboxUI.GetRowPacking), which decides how every
-- column of every row stands, so it belongs to no one column's card. Its
-- two answers in the manner of a column's own choices (PaintRadio): the
-- chosen one's square in the accent and its name white, the other's a
-- lighter grey, a wash while pointed at; each with its one line under its
-- name and, at the name's right, a small preview drawn in code -- two rows
-- of a subject and two figures, the second without the outer figure: in
-- Columns its other figure stays under the one above; Packed, it moves out
-- to the edge and the subject takes the room. The preview's figures are in
-- the accent while chosen. A click places every list again at once
-- (AR.SetRowPacking), so the rows show what it does while the choice is
-- still under the hand.
AR.ROW_LAYOUTS = { "columns", "packed" }
AR.LAYOUT_TEXT = {
  columns = { "OPT_ROW_LAYOUT_COLUMNS", "OPT_ROW_LAYOUT_COLUMNS_DESC" },
  packed  = { "OPT_ROW_LAYOUT_PACKED", "OPT_ROW_LAYOUT_PACKED_DESC" },
}
-- The preview's bars, each a left edge and a width in its INSP.PREVIEW_W
-- units: the subject, the inner figure and the outer one on the first row;
-- the subject and the inner figure on the second.
AR.LAYOUT_BARS = {
  columns = { 0, 12, 14, 6, 22, 4, 0, 12, 14, 6 },
  packed  = { 0, 12, 14, 6, 22, 4, 0, 18, 20, 6 },
}

local function PaintLayout(row)
  local chosen, hover = row.chosen, row.hover
  row.Hover:SetShown(hover and true or false)
  local r, g, b = 0.55, 0.55, 0.55
  if chosen then
    r, g, b = Th().GetAccent()
    row.Mark:SetVertexColor(r, g, b, 1)
  elseif hover then
    r, g, b = 1, 1, 1
  end
  row.Mark:SetShown(chosen and true or false)
  row.MarkKey:SetShown(chosen and true or false)
  Grey(row.Text, (chosen or hover) and 1 or 0.91)
  local s = hover and 0.6 or 0.4
  local bars = row.Bars
  for k = 1, #bars do
    if k == 1 or k == 4 then
      bars[k]:SetVertexColor(s, s, s, 1)
    else
      bars[k]:SetVertexColor(r, g, b, 1)
    end
  end
end

local function LayoutEnter(self)
  self.hover = true
  PaintLayout(self)
end

local function LayoutLeave(self)
  self.hover = false
  PaintLayout(self)
end

-- Row layout chosen from the mode: the choice itself, the options panel's
-- where it is open, and every list placed again where it stands, so the
-- rows show at once what it does; the header stays on its lanes, draws its
-- lane lines only in Columns, and the overview shows the choice as it now
-- is (AR.SyncLanes).
function AR.SetRowPacking(mode)
  local ui = UI()
  if not (AR.host and ui and ui.SetRowPacking and ui.GetRowPacking) then return end
  if ui.GetRowPacking() == mode then return end
  ui.SetRowPacking(mode)
  local panel = ns.OptionsPanel
  if panel and type(panel.RefreshControls) == "function" then panel.RefreshControls() end
  AR.RowsChanged(false)
  if AR.host then AR.LayoutStrip(AR.host) end
end

-- The mode's choice as the option now stands, wherever it was chosen (the
-- overview or the options panel): the inspector filled again -- the
-- choice, and the notes that say what the rows do -- once per change.
-- Called as the header is laid out, which every pass of the rows ends with.
function AR.SyncLanes(strip)
  local lined = LinedUp() and true or false
  if strip.lined == lined then return end
  strip.lined = lined
  local insp = AR._insp
  if insp and insp:IsShown() then AR.Inspect() end
end

local function LayoutClick(self)
  if not AR.host then return end
  AR.SetRowPacking(self.mode)
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
  elseif AR.selKind == "button" and host.MoveButton then
    host.MoveButton(AR.selId, self.step)
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
  local set = insp.set
  set(self.choiceId)
  -- The list switched is placed by its own switch.
  if set ~= AR.ShowList then AR.RowsChanged(true) end
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
  row.Text = Text(row, "bodySmall", "control")
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
  -- A block's own switch (the grid's, the totals') makes its own sound.
  if self.kind ~= "grid" and self.kind ~= "band" then PlayToggle(true) end
  AR.Inspect()
end

local function HiddenChip(insp, i)
  local T = Th()
  local chip = InspPlate(insp, "Button", true)
  chip:SetHeight(INSP.CHIP_H)
  chip.hover = false
  chip.Eye = T.Glyph and T.Glyph(chip, "eye-off", 8, "ARTWORK") or nil
  if chip.Eye then chip.Eye:SetPoint("CENTER", chip, "LEFT", INSP.CHIP_LEAD + INSP.CHIP_EYE / 2, 0) end
  chip.Label = Text(chip, "bodySmall", "body")
  chip.Label:SetPoint("LEFT", chip, "LEFT", INSP.CHIP_LEAD + INSP.CHIP_EYE + INSP.CHIP_EYE_GAP, 0)
  chip.Label:SetJustifyH("LEFT")
  chip.Label:SetWordWrap(false)
  chip:SetScript("OnEnter", HiddenEnter)
  chip:SetScript("OnLeave", HiddenLeave)
  chip:SetScript("OnClick", HiddenClick)
  insp.Chips[i] = chip
  return chip
end

-- The cross on the overview, out of the mode, and on a card the arrow back
-- to the overview (AR.Inspect shows the one that fits) -- Escape's layers,
-- less the drag.
local function CloseTip(self)
  AR.InspTip(self)
  if AR.selKind then
    GameTooltip:SetText(L()["ARRANGE_BACK"])
    GameTooltip:AddLine(L()["ARRANGE_GESTURE_BACK"], 0.7, 0.7, 0.7, true)
  else
    GameTooltip:SetText(L()["ARRANGE_DONE"])
    GameTooltip:AddLine(L()["ARRANGE_DONE_TIP"], 1, 1, 1, true)
    GameTooltip:AddLine(L()["ARRANGE_GESTURE_FINISH"], 0.7, 0.7, 0.7, true)
  end
  GameTooltip:Show()
end

local function CloseEnter(self)
  Grey(self.Text, 1)
  if self.Back then Grey(self.Back, 1) end
  CloseTip(self)
end

local function CloseLeave(self)
  Grey(self.Text, 0.74)
  if self.Back then Grey(self.Back, 0.74) end
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

-- The link up from a category button's card to the block it stands in: the
-- block's words, underlined as the reset is, and an arrow after them.
local function PaintUp(up)
  PaintLink(up)
  if up.Arrow then Grey(up.Arrow, up.hover and 1 or 0.74) end
end

local function UpEnter(self)
  self.hover = true
  PaintUp(self)
end

local function UpLeave(self)
  self.hover = false
  PaintUp(self)
end

local function UpClick(self)
  if AR.host and self.blockId then AR.Select("block", self.blockId) end
end

-- A block's own way elsewhere (the grid's: the character groups' window),
-- as a plate with its words, lit as the switch is when pointed at.
local function PaintAction(b)
  local spec = PLATE.switch
  local hover = b.hover
  TintPlate(b, hover and 0.17 or spec.fill, hover and spec.hover or spec.ring)
  Grey(b.Label, hover and 1 or 0.84)
end

local function ActionEnter(self)
  self.hover = true
  PaintAction(self)
end

local function ActionLeave(self)
  self.hover = false
  PaintAction(self)
end

local function ActionClick()
  local host = AR.host
  if host and AR.selKind == "block" and host.FollowBlockLink then host.FollowBlockLink(AR.selId) end
end

-- A block card's line for a block under the list, in the stack's order:
-- its place and its name. The block whose card this is stands in the
-- accent over a faint accent wash, as a selected card does, and does
-- nothing; any other is a way to its card -- a click selects it, and
-- pointed at it lights, with an arrow after it. A hidden block's line is a
-- quieter grey, and is a way to its card all the same.
local function PaintBlockRow(row)
  local hover = row.hover and not row.current
  local wash = row.Hover
  if row.current then
    local r, g, b = Th().GetAccent()
    wash:SetVertexColor(r, g, b, 0.1)
    wash:Show()
    row.Name:SetTextColor(r, g, b, 1)
    row.Num:SetTextColor(r, g, b, 1)
  else
    wash:SetVertexColor(1, 1, 1, 0.06)
    wash:SetShown(hover and true or false)
    Grey(row.Name, hover and 1 or (row.hidden and 0.45 or 0.74))
    Grey(row.Num, hover and 0.84 or (row.hidden and 0.36 or 0.55))
  end
  if row.Arrow then
    row.Arrow:SetShown(hover and true or false)
    Grey(row.Arrow, 1)
  end
end

local function BlockRowEnter(self)
  self.hover = true
  PaintBlockRow(self)
end

local function BlockRowLeave(self)
  self.hover = false
  PaintBlockRow(self)
end

local function BlockRowClick(self)
  if self.current then return end
  self.hover = false
  if AR.host and self.blockId then AR.Select("block", self.blockId) end
end

local function BlockRow(insp, i)
  local T = Th()
  local row = CreateFrame("Button", nil, insp)
  row:SetSize(INSP.INNER, INSP.LINE_H)
  row.hover, row.hidden, row.current = false, false, false
  row.Hover = row:CreateTexture(nil, "BACKGROUND")
  row.Hover:SetTexture(WHITE)
  row.Hover:SetVertexColor(1, 1, 1, 0.06)
  row.Hover:SetAllPoints()
  row.Hover:Hide()
  row.Num = Text(row, "bodySmall", "body")
  row.Num:SetPoint("LEFT", row, "LEFT", 3, 0)
  row.Name = Text(row, "bodySmall", "body")
  row.Name:SetPoint("LEFT", row, "LEFT", INSP.LINE_NUM, 0)
  row.Name:SetJustifyH("LEFT")
  row.Name:SetWordWrap(false)
  row.Arrow = T.Glyph and T.Glyph(row, "arrow-right", 6, "ARTWORK") or nil
  if row.Arrow then row.Arrow:SetPoint("RIGHT", row, "RIGHT", -4, 0) end
  row:SetScript("OnEnter", BlockRowEnter)
  row:SetScript("OnLeave", BlockRowLeave)
  row:SetScript("OnClick", BlockRowClick)
  insp.BlockRows[i] = row
  return row
end

-- A text of the inspector, wrapped across its width, in a role, one of its
-- sizes and a grey; its lines stand the mockup's line height apart.
local function Paragraph(art, role, size, grey)
  local fs = Text(art, role, size)
  fs:SetWidth(INSP.INNER)
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(true)
  if fs.SetSpacing then fs:SetSpacing(INSP.SPACING[size] or INSP.SPACING.body) end
  if grey then Grey(fs, grey) end
  fs:Hide()
  return fs
end

local function Line(art, role, size)
  local fs = size and Text(art, role, size) or Th().CreateText(art, role)
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

-- One of Row layout's two answers (PaintLayout, above), made the first
-- time the overview is filled: its square and name on a choice's line, its
-- one line under them, the preview at the line's right.
local function LayoutChoice(insp, i)
  local P = INSP
  local row = CreateFrame("Button", nil, insp)
  row:SetWidth(P.INNER)
  row.hover, row.chosen, row.mode = false, false, AR.ROW_LAYOUTS[i]
  row.Hover = row:CreateTexture(nil, "BACKGROUND")
  row.Hover:SetTexture(WHITE)
  row.Hover:SetVertexColor(1, 1, 1, 0.06)
  row.Hover:SetAllPoints()
  row.Hover:Hide()
  local mid = -P.RADIO_H / 2
  row.MarkKey = row:CreateTexture(nil, "ARTWORK", nil, 0)
  row.MarkKey:SetTexture(WHITE)
  row.MarkKey:SetVertexColor(0, 0, 0, 1)
  row.MarkKey:SetSize(7, 7)
  row.MarkKey:SetPoint("LEFT", row, "TOPLEFT", 3, mid)
  row.Mark = row:CreateTexture(nil, "ARTWORK", nil, 1)
  row.Mark:SetTexture(WHITE)
  row.Mark:SetSize(5, 5)
  row.Mark:SetPoint("CENTER", row.MarkKey, "CENTER", 0, 0)
  row.Text = Text(row, "bodySmall", "control")
  row.Text:SetPoint("LEFT", row, "TOPLEFT", P.RADIO_TEXT, mid)
  row.Text:SetJustifyH("LEFT")
  row.Text:SetWordWrap(false)
  row.Desc = Text(row, "secondary", "note")
  row.Desc:SetWidth(P.INNER - P.RADIO_TEXT)
  row.Desc:SetJustifyH("LEFT")
  row.Desc:SetWordWrap(true)
  if row.Desc.SetSpacing then row.Desc:SetSpacing(P.SPACING.note) end
  row.Desc:SetPoint("TOPLEFT", row, "TOPLEFT", P.RADIO_TEXT, -P.RADIO_H)
  Grey(row.Desc, 0.66)
  row.Bars = {}
  local at = AR.LAYOUT_BARS[row.mode]
  local top = mid + math.floor(P.PREVIEW_H / 2)
  for k = 1, 5 do
    local bar = row:CreateTexture(nil, "ARTWORK")
    bar:SetTexture(WHITE)
    bar:SetSize(at[2 * k], P.PREVIEW_BAR)
    local y = top - ((k > 3) and (P.PREVIEW_BAR + P.PREVIEW_GAP) or 0)
    bar:SetPoint("TOPLEFT", row, "TOPRIGHT", at[2 * k - 1] - P.PREVIEW_W - P.PREVIEW_PAD, y)
    row.Bars[k] = bar
  end
  row:SetScript("OnEnter", LayoutEnter)
  row:SetScript("OnLeave", LayoutLeave)
  row:SetScript("OnClick", LayoutClick)
  insp.Layouts[i] = row
  return row
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
  insp.Radios, insp.Chips, insp.BlockRows, insp.Kickers, insp.Layouts = {}, {}, {}, {}, {}

  -- Every text and rule is on this holder, never on the card itself.
  local art = CreateFrame("Frame", nil, insp)
  art:SetAllPoints()
  insp.Art = art

  insp.Title = Line(art, "title")
  insp.Title:SetPoint("TOPLEFT", insp, "TOPLEFT", P.PAD, -(P.TOP + P.LEAD.title))
  T.SetColor(insp.Title, "accent")
  insp.Title:Show()
  insp.Lead = Paragraph(art, "bodySmall", "body", 0.81)
  insp.Empty = Paragraph(art, "bodySmall", "body", 0.55)
  insp.Note = Paragraph(art, "secondary", "note", 0.66)
  -- A card's kickers, one per section it has (PutKicker), made as needed.
  insp.kickN = 0
  -- The subject's card: how far each row's subject runs, in words, and
  -- where the switch that decides it is.
  insp.Why = Paragraph(art, "bodySmall", "body", 0.81)
  insp.Where = Paragraph(art, "secondary", "note", 0.55)
  -- A note that begins with the hatch the rows draw (PutSwatchNote): the
  -- sample where its first line begins, the words after it.
  insp.SwatchNote = Paragraph(art, "secondary", "note", 0.66)
  insp.Swatch = T.Glyph and T.Glyph(art, "hatch", nil, "ARTWORK") or nil
  if insp.Swatch then
    insp.Swatch:SetSize(P.SWATCH_W, P.SWATCH_H)
    insp.Swatch:SetTexCoord(0, P.SWATCH_W / 8, 0, P.SWATCH_H / 8)
    insp.SwatchRing = AR.NewEdges(art, "ARTWORK", 1, 0, 1)
    AR.PlaceEdges(insp.SwatchRing, insp.Swatch, 0, 1)
    insp.Swatch:Hide()
    AR.ShowEdges(insp.SwatchRing, false)
  end
  insp.MoveLabel = Line(art, "bodySmall", "body")
  Grey(insp.MoveLabel, 0.74)
  insp.NoteRule = Rule(art)
  insp.FootRule = Rule(art)
  insp.Finish = Line(art, "secondary", "note")
  Grey(insp.Finish, 0.55)
  -- One line of each size, never shown: where a single line is measured
  -- whole, whatever width the one on show was fitted to.
  insp.Measure = {}
  for size in pairs(P.TYPE) do insp.Measure[size] = Line(art, "bodySmall", size) end

  local close = CreateFrame("Button", nil, insp)
  close:SetSize(P.CLOSE, P.CLOSE)
  -- Placed beside the title's line as the card is filled (AR.Inspect).
  close.Text = T.CreateText(close, "title")
  close.Text:SetPoint("CENTER", close, "CENTER", 0, 1)
  close.Text:SetText("\195\151")
  Grey(close.Text, 0.74)
  -- On a card, the arrow back in the cross's place (Theme.GLYPHS).
  close.Back = T.Glyph and T.Glyph(close, "arrow-back", nil, "ARTWORK") or nil
  if close.Back then
    close.Back:SetPoint("CENTER", close, "CENTER", 0, 0)
    Grey(close.Back, 0.74)
    close.Back:Hide()
  end
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
  sw.Label = Text(sw, "bodySmall", "control")
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
  link.Label = Text(link, "secondary", "body")
  link.Label:SetPoint("TOPLEFT", link, "TOPLEFT", 0, 0)
  link.Label:SetJustifyH("LEFT")
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

  -- The link up from a button's card (PaintUp).
  local up = CreateFrame("Button", nil, insp)
  up.hover = false
  up.Label = Text(up, "secondary", "body")
  up.Label:SetPoint("TOPLEFT", up, "TOPLEFT", 0, 0)
  up.Label:SetJustifyH("LEFT")
  up.Label:SetWordWrap(false)
  up.Line = up:CreateTexture(nil, "ARTWORK")
  up.Line:SetTexture(WHITE)
  up.Line:SetHeight(1)
  up.Line:SetPoint("TOPLEFT", up.Label, "BOTTOMLEFT", 0, -1)
  up.Line:SetPoint("TOPRIGHT", up.Label, "BOTTOMRIGHT", 0, -1)
  up.Arrow = T.Glyph and T.Glyph(up, "arrow-right", 6, "ARTWORK") or nil
  if up.Arrow then up.Arrow:SetPoint("LEFT", up.Label, "RIGHT", P.UP_GAP, 0) end
  up:SetScript("OnEnter", UpEnter)
  up:SetScript("OnLeave", UpLeave)
  up:SetScript("OnClick", UpClick)
  up:Hide()
  insp.Up = up

  -- A block's own way elsewhere (PaintAction).
  local act = InspPlate(insp, "Button", true)
  act:SetHeight(P.SWITCH_H)
  act.hover = false
  act.Label = Text(act, "bodySmall", "control")
  act.Label:SetPoint("LEFT", act, "LEFT", P.SWITCH_TAIL, 0)
  act.Label:SetJustifyH("LEFT")
  act.Label:SetWordWrap(false)
  act:SetScript("OnEnter", ActionEnter)
  act:SetScript("OnLeave", ActionLeave)
  act:SetScript("OnClick", ActionClick)
  act:Hide()
  insp.Action = act

  local key = InspPlate(insp, "Frame", false)
  TintPlate(key, PLATE.key.fill, PLATE.key.ring)
  key:SetHeight(P.KEY_H)
  key.Label = Text(key, "secondary", "kicker")
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

-- Postbox's tooltips while the inspector is up, so none covers it: a thing
-- in the window opens its tooltip above itself, reaching away from the
-- inspector from its own edge on the inspector's side (which is inside the
-- window, and the inspector stands outside it); anywhere else, or with no
-- inspector, the tooltip goes where `anchor` puts it. The headings' own
-- open above them, over the inspector's top edge, and keep ANCHOR_TOP.
function AR.TipOwner(owner, anchor)
  local insp = AR._insp
  if AR.host and insp and insp.side and insp:IsShown() then
    anchor = (insp.side == 1) and "ANCHOR_TOPRIGHT" or "ANCHOR_TOPLEFT"
  end
  GameTooltip:SetOwner(owner, anchor)
end

-- The inspector's own controls open their tooltips above the inspector,
-- off it, on its edge away from the window.
function AR.InspTip(owner)
  local insp = AR._insp
  GameTooltip:SetOwner(owner, "ANCHOR_NONE")
  GameTooltip:ClearAllPoints()
  if insp.side == -1 then
    GameTooltip:SetPoint("BOTTOMLEFT", insp, "TOPLEFT", 0, 4)
  else
    GameTooltip:SetPoint("BOTTOMRIGHT", insp, "TOPRIGHT", 0, 4)
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

-- A text and the leading of its line box above and below it (INSP.LEAD,
-- the words' unless `lead` names another).
local function PutText(fs, text, y, lead)
  lead = INSP.LEAD[lead or "body"]
  At(fs, INSP.PAD, y - lead)
  fs:Show()
  return y - lead - Measured(fs, text, true) - lead
end

-- A kicker in capitals, the next of the card's own; one that does not fit
-- the width (a long German one) takes a second line rather than losing its
-- end.
local function PutKicker(text, y)
  local insp = AR._insp
  local n = insp.kickN + 1
  insp.kickN = n
  local k = insp.Kickers[n]
  if not k then
    k = Paragraph(insp.Art, "secondary", "kicker", 0.55)
    insp.Kickers[n] = k
  end
  return PutText(k, Upper(text), y - INSP.KICK_TOP, "kicker") - INSP.KICK_GAP
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
  return PutText(insp.Note, text, y - 1 - INSP.NOTE_PAD, "note")
end

-- A note's words led by as many spaces as the hatch's sample and its gap
-- are wide in the note's own font: the first line starts after the sample
-- and the next ones run back under it, as the mockup sets the sample inline
-- (a font string has no inline art that tiles). Made once per string and
-- per width of a space, the memo holding the few notes there are.
local function AfterSwatch(fs, text)
  local P = INSP
  local space = Measured(fs, "x x", false) - Measured(fs, "xx", false)
  local n = math.ceil((P.SWATCH_W + P.SWATCH_GAP) / math.max(space, 1))
  local memo = AR._afterSwatch
  if not memo or memo.n ~= n then
    memo = { n = n, lead = string.rep(" ", n) }
    AR._afterSwatch = memo
  end
  local out = memo[text]
  if not out then
    out = memo.lead .. text
    memo[text] = out
  end
  return out
end

-- A note that speaks of the hatch the rows draw: the sample first, as the
-- rows have it -- in the accent where it is the subject's borrowed room,
-- grey where it is a figure's lane the subject runs through -- and the
-- words after it (AfterSwatch). A plain note where the hatch's art is
-- missing.
local function PutSwatchNote(text, y, accent)
  local insp, P = AR._insp, INSP
  local swatch = insp.Swatch
  if not swatch then return PutNote(text, y) end
  y = y - P.NOTE_TOP
  PutRule(insp.NoteRule, y)
  y = y - 1 - P.NOTE_PAD - P.LEAD.note
  if accent then
    local r, g, b = Th().GetAccent()
    swatch:SetVertexColor(r, g, b, 0.7)
    AR.TintEdges(insp.SwatchRing, r, g, b, 0.6)
  else
    swatch:SetVertexColor(1, 1, 1, 0.35)
    AR.TintEdges(insp.SwatchRing, 1, 1, 1, 0.3)
  end
  local fs = insp.SwatchNote
  local line = Measured(fs, "x", true)
  swatch:ClearAllPoints()
  swatch:SetPoint("TOPLEFT", insp, "TOPLEFT", P.PAD, y - math.floor((line - P.SWATCH_H) / 2 + 0.5))
  swatch:Show()
  AR.ShowEdges(insp.SwatchRing, true)
  At(fs, P.PAD, y)
  fs:Show()
  return y - math.max(Measured(fs, AfterSwatch(fs, text), true), P.SWATCH_H) - P.LEAD.note
end

-- The eye switch at the row's left; answers its width.
local function PutSwitch(on, y)
  local insp, P = AR._insp, INSP
  local sw = insp.Switch
  local text = L()[on and "ARRANGE_SHOWN" or "ARRANGE_HIDDEN_STATE"]
  local w = P.SWITCH_LEAD + Measured(insp.Measure.control, text, false) + P.SWITCH_TAIL
  sw.on = on and true or false
  sw.Label:SetText(text)
  sw:SetWidth(w)
  At(sw, P.PAD, y)
  PaintSwitch(sw)
  sw:Show()
  return w
end

-- Row layout's kicker and its two answers, in the overview (LayoutChoice):
-- each as tall as its line and its one line under it. A name too long
-- for the room beside the preview is cut. Answers the y under them.
local function PutLayout(y)
  local insp, P = AR._insp, INSP
  y = PutKicker(L()["OPT_ROW_LAYOUT_TITLE"], y)
  local packed = not LinedUp()
  for i = 1, #AR.ROW_LAYOUTS do
    local row = insp.Layouts[i] or LayoutChoice(insp, i)
    local text = AR.LAYOUT_TEXT[row.mode]
    row.chosen = (row.mode == "packed") == packed
    row.hover = row.hover and row:IsMouseOver() or false
    Th().FitText(row.Text, P.INNER - P.RADIO_TEXT - P.PREVIEW_W - P.PREVIEW_PAD - P.MOVE_GAP, L()[text[1]], row)
    local h = P.RADIO_H + Measured(row.Desc, L()[text[2]], true) + P.LAYOUT_TAIL
    row:SetHeight(h)
    At(row, P.PAD, y)
    PaintLayout(row)
    row:Show()
    y = y - h
  end
  return y
end

-- Move and its two arrows at the row's right: left and right for a column,
-- up and down for a block, each live only where there is a place to go.
-- `used` is the width the row's left already has (the switch); where the
-- words and the arrows do not fit beside it, they take a row of their own
-- under it. Answers the y under the row.
local function PutMove(y, vertical, back, forward, used)
  local insp, P = AR._insp, INSP
  local text = L()["ARRANGE_MOVE"]
  local need = Measured(insp.Measure.body, text, false) + P.MOVE_GAP + 2 * P.NUDGE_W + P.NUDGE_GAP
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

-- A block card's line for a block (BlockRow): `current` is the block the
-- card is for.
local function PutBlockRow(i, id, name, hidden, current, y)
  local insp = AR._insp
  local row = insp.BlockRows[i] or BlockRow(insp, i)
  row.blockId, row.hidden, row.current = id, hidden and true or false, current and true or false
  row.hover = row.hover and row:IsMouseOver() or false
  row.Num:SetFormattedText("%d", i)
  Th().FitText(row.Name, INSP.INNER - INSP.RADIO_TEXT - INSP.UP_ARROW, name, row)
  At(row, INSP.PAD, y)
  PaintBlockRow(row)
  row:Show()
  return y - INSP.RADIO_H
end

-- The link up from a button's card, after a rule: the words for the block
-- it stands in and the arrow after them, cut where the card is too narrow.
local UP_TEXT = { grid = "ARRANGE_UP_GRID" }

local function PutUp(blockId, y)
  local insp, P = AR._insp, INSP
  local key = UP_TEXT[blockId]
  if not key then return y end
  local text = L()[key]
  y = y - P.NOTE_TOP
  PutRule(insp.NoteRule, y)
  y = y - 1 - P.NOTE_PAD - P.LEAD.body
  local up = insp.Up
  local room = P.INNER - P.UP_ARROW
  local w = math.min(Measured(insp.Measure.body, text, false), room)
  local h = Measured(insp.Measure.body, text, true)
  Th().FitText(up.Label, w, text, up)
  up.blockId = blockId
  up.hover = up.hover and up:IsMouseOver() or false
  up:SetSize(w + P.UP_ARROW, h + 2)
  At(up, P.PAD, y)
  PaintUp(up)
  up:Show()
  return y - h - 2 - P.LEAD.body
end

-- A block's own way elsewhere, on a plate at the row's left; answers the y
-- under it.
local function PutAction(text, y)
  local insp, P = AR._insp, INSP
  local b = insp.Action
  local w = math.min(2 * P.SWITCH_TAIL + Measured(insp.Measure.control, text, false), P.INNER)
  Th().FitText(b.Label, w - 2 * P.SWITCH_TAIL + 1, text, b)
  b:SetWidth(w)
  b.hover = b.hover and b:IsMouseOver() or false
  At(b, P.PAD, y)
  PaintAction(b)
  b:Show()
  return y - P.SWITCH_H
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
  local w = math.min(lead + Measured(insp.Measure.body, name, false) + P.CHIP_TAIL, P.INNER)
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

-- The foot, one line: the reset on the left, the key cap and "to finish" on
-- the right -- "to cancel" while something is in the hand, the one change a
-- drag makes to the inspector -- each centred on a row the reset's line box
-- tall (FOOT_H). Each is measured in the size it is drawn in. Only where
-- the two cannot stand side by side (a long German or Russian pair) does
-- the right-hand pair take a row of its own under the reset, whichever
-- words it has, so a drag never reflows it.
local function PutFoot(y)
  local insp, P = AR._insp, INSP
  local m = insp.Measure
  y = y - P.FOOT_TOP
  PutRule(insp.FootRule, y)
  y = y - 1 - P.FOOT_PAD
  local link, key, finish = insp.Reset, insp.Key, insp.Finish
  local resetText, keyText = L()["ARRANGE_RESET"], L()["ARRANGE_ESC_KEY"]
  local finishText = L()[AR.moving and "ARRANGE_ESC_CANCEL" or "ARRANGE_ESC_FINISH"]
  local linkW = Measured(m.body, resetText, false)
  local keyW = Measured(m.kicker, keyText, false) + 2 * P.KEY_PAD
  local finishW = math.max(Measured(m.note, L()["ARRANGE_ESC_FINISH"], false),
    Measured(m.note, L()["ARRANGE_ESC_CANCEL"], false))
  local lineH = Measured(m.body, resetText, true)
  link.Label:SetText(resetText)
  link:SetSize(linkW, lineH + 2)
  link:ClearAllPoints()
  -- Its words, not its underline, centred on the row.
  link:SetPoint("LEFT", insp, "TOPLEFT", P.PAD, y - P.FOOT_H / 2 - 1)
  PaintLink(link)
  link:Show()
  local rowY = y
  if linkW + P.FOOT_GAP + keyW + P.KEY_GAP + finishW > P.INNER then
    rowY = y - P.FOOT_H
  end
  finish:SetText(finishText)
  finish:ClearAllPoints()
  finish:SetPoint("RIGHT", insp, "TOPLEFT", P.PAD + P.INNER, rowY - P.FOOT_H / 2)
  finish:Show()
  key.Label:SetText(keyText)
  key:SetWidth(keyW)
  key:ClearAllPoints()
  key:SetPoint("RIGHT", finish, "LEFT", -P.KEY_GAP, 0)
  key:Show()
  return rowY - P.FOOT_H
end

-- The list the mode arranges, where the host offers the other (the Mail
-- tab on this character's box, History kept): the inbox's arrangement or
-- History's, as a column's own choices are shown. A click switches the
-- list under the mode (the host's ShowHistory), and the mode follows it
-- (AR.SyncList).
function AR.ShowList(id)
  local host = AR.host
  if host and host.ShowHistory then host.ShowHistory(id == "history") end
end

local function PutLists(host, y)
  local insp = AR._insp
  if not (host.CanSwitch and host.CanSwitch() and host.ShowHistory) then return y end
  local lists = AR._lists
  if not lists then
    lists = {
      { id = "inbox",   name = L()["VIEW_INBOX"] },
      { id = "history", name = L()["VIEW_HISTORY"] },
    }
    AR._lists = lists
  end
  y = PutKicker(L()["ARRANGE_LIST"], y)
  local current = AR.EditsHistory() and "history" or "inbox"
  insp.set = AR.ShowList
  for i = 1, #lists do
    y = PutRadio(i, lists[i], lists[i].id == current, true, y)
  end
  return y
end

-- With nothing selected: how the mode works, the list it arranges, Row
-- layout -- it is every column's, so it belongs to no one column's card --
-- what is hidden, and the foot.
local function FillOverview(host, y)
  local insp, P = AR._insp, INSP
  y = PutText(insp.Lead, L()["ARRANGE_OVERVIEW"], y)
  y = PutLists(host, y)
  y = PutLayout(y)
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
  chipsN, chipsX, chipsY = 0, P.PAD, y - P.CHIP_EDGE
  if layout then
    for i = 1, #layout do
      local entry = layout[i]
      local spec = AR.COLUMNS[entry.id]
      if spec and not entry.shown and not spec.fixed then PutHidden("column", entry.id, L()[spec.title]) end
    end
  end
  if host.ListHidden then host.ListHidden(PutHidden) end
  return PutFoot(chipsY - P.CHIP_H - P.CHIP_EDGE)
end

-- A column's card.
local function FillColumn(id, y)
  local insp, P = AR._insp, INSP
  local spec = AR.COLUMNS[id]
  local layout = AR.Layout()
  local shown = layout and layout.shown[id] or false
  local k = layout and IndexOf(layout, id) or 1
  y = PutText(insp.Lead, L()[spec.desc], y) - P.ROW_GAP
  -- The subject cannot be hidden: no eye, and Move has the row.
  local used = 0
  if not spec.fixed then used = PutSwitch(shown, y) end
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
  -- What a mail without a figure does: in Columns by its place beside the
  -- subject, and Packed the same on either side; the subject's card says
  -- what the Row layout chosen does, and in one quiet line where the choice
  -- is. Where the subject runs on into a column, the note begins with the
  -- hatch the rows draw there: only in Columns, the rows drawing no hatch
  -- packed.
  local lined = LinedUp()
  if spec.figure and layout then
    local at = IndexOf(layout, "subject") or 0
    if not lined then
      y = PutNote(L()["ARRANGE_NOTE_PACKED"], y)
    elseif k <= at then
      y = PutNote(L()["ARRANGE_NOTE_LEFT"], y)
    else
      y = PutSwatchNote(L()["ARRANGE_NOTE_RIGHT"], y, false)
    end
  elseif spec.fixed then
    if lined then
      y = PutSwatchNote(L()["ARRANGE_LANES_ON"], y, true)
    else
      y = PutNote(L()["OPT_ROW_LAYOUT_PACKED_DESC"], y)
    end
    -- Under the note as its own last line, ROW_WRAP from its words.
    y = PutText(insp.Where, L()["ARRANGE_LAYOUT_WHERE"], y + 2 * P.LEAD.note - P.ROW_WRAP, "note")
  end
  return y
end

-- A block's card: the host's words for it, its switch, Move up and down,
-- its own way elsewhere (the grid's: the character groups), what hiding it
-- does, beside the switch it is about, and last the stack's order -- the
-- blocks the view has, top down, each line the way to its own card, this
-- one's in the accent and a hidden one's greyed.
local function FillBlock(host, id, y)
  local insp, P = AR._insp, INSP
  y = PutText(insp.Lead, host.BlockText(id), y) - P.ROW_GAP
  local used = 0
  local on = host.BlockShown and host.BlockShown(id)
  if on ~= nil then used = PutSwitch(on, y) end
  y = PutMove(y, true, host.CanMoveBlock(id, -1), host.CanMoveBlock(id, 1), used)
  local link = host.BlockLink and host.BlockLink(id)
  if link then y = PutAction(link, y - P.ROW_WRAP) end
  local note = host.BlockNote and host.BlockNote(id)
  if note then y = PutNote(note, y) end
  y = PutKicker(L()["ARRANGE_UNDER_LIST"], y)
  local order, n = host.StackOrder(), 0
  for i = 1, #order do
    local other = order[i]
    if not host.BlockPresent or host.BlockPresent(other) then
      n = n + 1
      y = PutBlockRow(n, other, host.BlockName(other), host.BlockShown and host.BlockShown(other) == false, other == id, y)
    end
  end
  return y
end

-- A category button's card: the host's words for it, its eye switch, Move
-- back and on along the grid's order, and the link up to the block it
-- stands in, whose card is the grid's as a whole.
local function FillButton(host, id, y)
  local insp, P = AR._insp, INSP
  y = PutText(insp.Lead, host.ButtonText(id), y) - P.ROW_GAP
  local used = PutSwitch(host.ButtonShown(id), y)
  y = PutMove(y, false, host.CanMoveButton(id, -1), host.CanMoveButton(id, 1), used)
  local block = host.ButtonBlock and host.ButtonBlock(id)
  if block then y = PutUp(block, y) end
  return y
end

local function HideParts(insp)
  insp.Lead:Hide()
  insp.Empty:Hide()
  insp.Note:Hide()
  insp.Why:Hide()
  insp.Where:Hide()
  insp.SwatchNote:Hide()
  if insp.Swatch then
    insp.Swatch:Hide()
    AR.ShowEdges(insp.SwatchRing, false)
  end
  for i = 1, #insp.Kickers do insp.Kickers[i]:Hide() end
  insp.kickN = 0
  insp.MoveLabel:Hide()
  insp.NoteRule:Hide()
  insp.FootRule:Hide()
  insp.Finish:Hide()
  insp.Switch:Hide()
  for i = 1, #insp.Layouts do insp.Layouts[i]:Hide() end
  insp.NudgeA:Hide()
  insp.NudgeB:Hide()
  insp.Reset:Hide()
  insp.Key:Hide()
  insp.Up:Hide()
  insp.Action:Hide()
  for i = 1, #insp.Radios do insp.Radios[i]:Hide() end
  for i = 1, #insp.Chips do insp.Chips[i]:Hide() end
  for i = 1, #insp.BlockRows do insp.BlockRows[i]:Hide() end
end

-- The inspector filled again for what is selected now, if it is up. Called
-- after anything it shows may have changed; a block or a button the view no
-- longer has is let go first.
function AR.Inspect()
  local insp, host = AR._insp, AR.host
  if not (insp and host and insp:IsShown()) then return end
  local P, T = INSP, Th()
  local sel = AR.selKind
  if (sel == "block" and not (host.BlockPresent and host.BlockPresent(AR.selId)))
      or (sel == "button" and not (host.ButtonPresent and host.ButtonPresent(AR.selId))) then
    AR.selKind, AR.selId = nil, nil
    AR.UpdateFocus()
  end
  local kind, id = AR.selKind, AR.selId
  HideParts(insp)
  local title
  if kind == "column" then
    title = L()[AR.COLUMNS[id].title]
  elseif kind == "block" then
    title = host.BlockName(id)
  elseif kind == "button" then
    title = host.ButtonName(id)
  else
    title = L()["ARRANGE_TITLE"]
  end
  -- The cross on the overview, the arrow back on a card: what a click on
  -- it does now.
  local back = AR.selKind ~= nil and insp.Close.Back ~= nil
  insp.Close.Text:SetShown(not back)
  if insp.Close.Back then insp.Close.Back:SetShown(back) end
  T.FitText(insp.Title, P.INNER - P.CLOSE, title, nil)
  -- The title's line box, and the cross centred on its line.
  local titleH = Measured(insp.Title, title, true)
  local box = math.max(titleH + 2 * P.LEAD.title, P.CLOSE)
  local closeY = -math.floor(P.TOP + P.LEAD.title + (titleH - P.CLOSE) / 2 + 0.5)
  if insp.closeY ~= closeY then
    insp.closeY = closeY
    insp.Close:ClearAllPoints()
    insp.Close:SetPoint("TOPRIGHT", insp, "TOPRIGHT", -(P.PAD - 5), closeY)
  end
  local y = -P.TOP - box - P.HEAD_GAP
  if kind == "column" then
    y = FillColumn(id, y)
  elseif kind == "block" then
    y = FillBlock(host, id, y)
  elseif kind == "button" then
    y = FillButton(host, id, y)
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
-- (the header in the top row's place, from the rows' left edge to their
-- right edge while nothing scrolls),
-- OnEnter(strip) (the top row steps aside), OnLeave() (and comes back as it
-- was), toggle = the key that opened it }. Opening the mode moves nothing
-- the host already shows: its cards appear over its blocks where they stand,
-- with no settling in. For the header and the rows it
-- answers, for the list on screen: Spec() (its placement table, whose lanes
-- RV.Place publishes), Pool() (its rows), Scroll() (its scroll frame),
-- List() (the frame its rows stand in) and TwoLine() (whether its rows are
-- the two-line ones, which have no lanes), and may answer History()
-- (whether the list on screen follows History's arrangement, which the
-- mode then arranges; the mail rows' otherwise), CanSwitch() and
-- ShowHistory(on) (the overview's list choice: the list switched under
-- the mode). It tells the
-- mode when a pass of its rows begins and ends (AR.ListPlacing,
-- AR.ListPlaced). The Mail
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
-- PaintBlocks() (the selection's ring moved, on a block or a button), and
-- may offer a block's own way elsewhere: BlockLink(id) (its words, or nil)
-- and FollowBlockLink(id). One with category buttons answers for them by id
-- the same way: ButtonPresent, ButtonName, ButtonText, ButtonShown,
-- SetButtonShown, CanMoveButton(id, step), MoveButton(id, step) and
-- ButtonBlock(id) (the block the button stands in, for the link up).
-------------------------------------------------------------

function AR.Enter(host)
  if not host or AR.host == host then return end
  if AR.host then AR.Leave() end
  local strip = host.strip or AR.BuildStrip(host)
  local cover = host.cover or AR.BuildCover(host)
  AR.host = host
  AR.hover, AR.focus, AR.drag, AR.rowHover = nil, nil, nil, nil
  AR.selKind, AR.selId, AR.moving = nil, nil, nil
  AR.editsHistory, AR.relisted = AR.EditsHistory(), false
  strip:Show()
  if host.OnEnter then host.OnEnter(strip) end
  if cover then
    AR.CoverLevel(host)
    cover:Show()
  end
  AR.CatchEscape(true)
  if host.toggle then AR.PaintToggle(host.toggle) end
  -- The rows placed again for the mode, publishing the lanes the header
  -- stands on, and the header laid on them as each pass ends
  -- (AR.ListPlaced) -- and here, for a list that placed none.
  AR.RowsChanged(false)
  AR.LayoutStrip(host)
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
  -- The rows placed again with nothing marked on them.
  AR.RowsChanged(false)
end

-- The mode ends with the frame it was opened over.
function AR.LeaveIf(owner)
  if AR.host and AR.host.owner == owner then AR.Leave() end
end
