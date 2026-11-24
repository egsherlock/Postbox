-------------------------------------------------------------
-- Postbox :: Core/BagView.lua
--
-- The Mail tab's list drawn as one bag.
--
-- One square button, the find plate's last cell after the sort, turns the
-- list that is on screen into a grid of item tiles and back. It is a way of
-- showing, not a place: the inbox, a search, a filter, another character's
-- box and History are each drawn from the very list the rows are bound
-- from, so the search, the sort and the filters act on the bag as they act
-- on the list, and the totals band, All mail, the sweeps and the notes
-- under the list stay what they are. On the Done tab there is nothing to
-- show (finished mail holds nothing) and the button is gray.
--
-- A tile is one KIND of item with its total across the mail shown (the same
-- item in forty mails is one tile); the gold is the first tile. What is not
-- a plain take stands after the rest under a line that says why: a C.O.D.
-- mail's items under its price, one tile a stack, and the mail the game has
-- not listed yet under the list's own line, in one gray.
--
-- A click on a tile takes every stack of that item as ONE collect run
-- (CollectTab's StartCategoryRun with `only`, MailService's opts.only): the
-- bags asked first, Keep bag slots free kept, never a C.O.D., stuck mail and
-- mail waiting for bag room left, every stop rule, the run's line and words
-- and History as for any run; only that item leaves a mail that holds other
-- things. A C.O.D. tile asks first and takes its one stack, as the fan's
-- tile does (MailService's TakeAttachment). Shift-click links, Ctrl-click
-- tries on; right-click shows its mails (the list, searched for the item).
-- Where nothing can be taken -- another character's box, History -- the
-- tiles keep their color, a click does nothing and the line under the list
-- says so, as it does for the list.
--
-- Nothing here runs while the switch is off but the button's own paint, a
-- comparison or two at the end of a list refresh. On, the bag is built once
-- per list refresh, in one pass over the list into tables that are kept
-- (kinds, sections, each kind's mails); tiles come from a pool and only the
-- lines in view are bound. While a run is going nothing moves: the kinds
-- keep their places, a taken one stands as an empty slot, and the bag
-- closes up at the run's end. No OnUpdate, no timer.
--
-- Loaded after Core/CollectTab.lua, whose own parts it is built from
-- (ns.CollectTab.Bag, read at call time).
-------------------------------------------------------------

local _, ns = ...

ns.BagView = ns.BagView or {}
local BV = ns.BagView

local floor, max = math.floor, math.max

local function Th() return ns.Theme end
local function L() return ns.L end
local function Mail() return ns.MailService end
local function Parts()
  local CT = ns.CollectTab
  return CT and CT.Bag or nil
end

-- Tiles are the reading view's slot (Theme's Metrics.slotSize), GAP apart;
-- a section's line is HEAD tall; PAD above the first line and under the
-- last, room for a quality mark's overhang inside the clipped list.
BV.GAP, BV.HEAD, BV.PAD = 6, 20, 5
-- How many of its mails a tile's tooltip names before "+N more".
BV.TIP_MAILS = 8
-- A tile that cannot be taken from here: its art without color at this
-- alpha, its count in this gray (lighter than a refused tile's dim, so the
-- item can still be told).
BV.GRAY_A, BV.GRAY_INK = 0.55, 0.62
BV.COIN = "Interface\\Icons\\INV_Misc_Coin_02"
BV.UNKNOWN = "Interface\\Icons\\INV_Misc_QuestionMark"
-- The switch's mark: TEMPORARY, the Slots column's glyph, until the real
-- one is drawn.
BV.GLYPH = "slot"

BV.tiles, BV.heads = {}, {}

-- The bag as last built. `kinds` and `sects` are pools, `n` and `sn` how
-- many of each are in use; a section's `list` is its kinds in the order
-- they stand, `by` finds one by its key. `src` is the list it was built
-- from ("inbox", "away", "history"), `gen` the inbox's mark then
-- (Mail.InboxGen), `build` counts the builds that laid the kinds out.
local model = {
  kinds = {}, n = 0, sects = {}, sn = 0,
  src = nil, gen = nil, build = 0, frozen = false, height = 0,
}
BV.model = model

local NONE = {}

-------------------------------------------------------------
-- 1. The switch's state
-------------------------------------------------------------

-- Whether the player chose the bag (profile.bagView, MailboxUI's
-- OPTION_DEFAULTS; unset is off).
function BV.On()
  local UI = ns.MailboxUI
  return UI ~= nil and type(UI.GetOption) == "function" and UI.GetOption("bagView") == true
end

-- panel -> whether the list on screen has no bag to show: the Done tab,
-- and, until they are drawn as one, History and another character's box.
function BV.Gray(panel)
  local P = Parts()
  return P ~= nil and (panel.viewMode ~= P.VIEW_COLLECT or P.AV.Active(panel))
end

-- panel -> whether the bag is what is drawn: chosen, and the list on screen
-- one it can draw. The arrange mode and its Preview mail keep the list.
function BV.Active(panel)
  if not BV.On() then return false end
  local P = Parts()
  if not P or panel._bagYield or panel._preview or P.RV.Arranging(panel) then return false end
  -- The reading view has the list's place while it is up.
  local detail = panel.Detail
  if detail and detail:IsShown() then return false end
  return not BV.Gray(panel)
end

-------------------------------------------------------------
-- 2. The data: kinds tallied from the list that is up
-------------------------------------------------------------

-- head, look -> the next section, emptied. `look` 2: its tiles cannot be
-- taken from here (the gray).
local function Sect(head, look)
  local m = model
  local k = m.sn + 1
  m.sn = k
  local s = m.sects[k]
  if not s then
    s = { list = {}, by = {} }
    m.sects[k] = s
  end
  local by = s.by
  for key in pairs(by) do by[key] = nil end
  s.n, s.head, s.look, s.rem, s.realm, s.name, s.shown, s.y = 0, head, look or 0, false, nil, nil, false, 0
  return s
end

-- s, key -> the section's kind under that key, made (from the pool) where
-- it has none; nil for a new one while the kinds are held in place.
local function Kind(s, key)
  local kind = s.by[key]
  if kind then return kind end
  local m = model
  if m.frozen then return nil end
  local k = m.n + 1
  m.n = k
  kind = m.kinds[k]
  if not kind then
    kind = { ref = {}, cnt = {}, top = 0 }
    m.kinds[k] = kind
  end
  kind.key, kind.sect = key, s
  kind.id, kind.name, kind.tex, kind.link = nil, nil, nil, nil
  kind.n, kind.stacks, kind.mails, kind.free, kind.freeN, kind.why = 0, 0, 0, 0, 0, nil
  kind.gold, kind.cod, kind.live, kind.index, kind.slot = false, false, false, nil, nil
  kind.markAt, kind.mark, kind.look = nil, nil, 0
  s.by[key] = kind
  s.n = s.n + 1
  s.list[s.n] = kind
  return kind
end

-- One stack (or one mail's gold) into its kind: `where` is the mail it is
-- in, an inbox index or a record; `free`, whether a run may take it;
-- `why`, what holds it back otherwise ("bags", "stuck").
local function Put(kind, count, where, free, why)
  kind.n = kind.n + count
  kind.stacks = kind.stacks + 1
  if free then
    kind.free = kind.free + 1
    kind.freeN = kind.freeN + count
  elseif why and not kind.why then
    kind.why = why
  end
  local m = kind.mails
  if m > 0 and kind.ref[m] == where then
    kind.cnt[m] = kind.cnt[m] + count
  else
    m = m + 1
    kind.mails = m
    kind.ref[m], kind.cnt[m] = where, count
  end
end

-- A stack a record describes (Mail Memory's, History's): by its id where
-- the record has one, else by `alt` (a name, a link) or its icon.
local function Item(s, id, alt, tex, count, where, link)
  local key = id or alt or tex
  if not key then return end
  local kind = Kind(s, key)
  if not kind then return end
  if kind.stacks == 0 then
    kind.id = id
    if not tex and id and C_Item and type(C_Item.GetItemIconByID) == "function" then tex = C_Item.GetItemIconByID(id) end
    kind.tex = tex or BV.UNKNOWN
    if type(alt) == "string" and alt ~= link then kind.name = alt end
  end
  if link and not kind.link then kind.link = link end
  Put(kind, tonumber(count) or 1, where, false, nil)
end

local function Gold(s, amount, where, free)
  local kind = Kind(s, 0)
  if not kind then return end
  if kind.stacks == 0 then kind.gold, kind.tex = true, BV.COIN end
  Put(kind, amount, where, free, nil)
end

-- The inbox's list as it is drawn (panel._filtered: the search, the sort
-- and the filters have shaped it): the gold and every stack of the mail
-- still to collect, a kind an item id. Mail a sweep leaves -- stuck, or
-- waiting for bag room -- is counted and not `free`. Held in place
-- (`frozen`), only the first section's counts are read again.
function BV.TallyInbox(panel, frozen)
  local P, M = Parts(), Mail()
  local filtered, done = panel._filtered, panel._filteredDone
  local main = model.sects[1]
  local slots = M.MAX_ATTACHMENTS or 16
  local divider = P.DIVIDER
  for i = 1, #filtered do
    local index = filtered[i]
    if index ~= divider and not done[i] then
      local _, _, sender, _, money, cod, _, itemCount = GetInboxHeaderInfo(index)
      money, cod, itemCount = tonumber(money) or 0, tonumber(cod) or 0, tonumber(itemCount) or 0
      local held = itemCount > 0 and M.HeldBack(index, itemCount) or nil
      if cod > 0 then
        -- A C.O.D. mail's items are not drawn yet.
      else
        if money > 0 then Gold(main, money, index, true) end
        if itemCount > 0 then
          local found = 0
          for slot = 1, slots do
            local name, id, tex, count = GetInboxItem(index, slot)
            if tex then
              found = found + 1
              local kind = Kind(main, id or name or tex)
              if kind then
                if kind.stacks == 0 then
                  kind.id, kind.name, kind.tex, kind.index, kind.slot = id, name, tex, index, slot
                  kind.live = true
                end
                Put(kind, tonumber(count) or 1, index, held == nil and id ~= nil, held)
              end
              if found >= itemCount then break end
            end
          end
        end
      end
    end
  end
end

-- The bag, from the list CT.RefreshMailList has just built. While a run is
-- going over the inbox's list the kinds are held in place and only counted
-- again; otherwise everything is made anew, in tables that are kept.
function BV.Build(panel)
  local P = Parts()
  local m = model
  local src = "inbox"
  if panel.viewMode == P.VIEW_HISTORY then
    src = "history"
  elseif P.AV.Active(panel) then
    src = "away"
  end
  local frozen = src == "inbox" and m.src == "inbox" and m.sn > 0 and ns.CollectTab.IsRunning()
  m.frozen = frozen
  if frozen then
    local main = m.sects[1]
    for i = 1, main.n do
      local kind = main.list[i]
      kind.n, kind.stacks, kind.mails, kind.free, kind.freeN, kind.why = 0, 0, 0, 0, 0, nil
    end
  else
    -- Another list: from its top.
    if m.src ~= src or m.alt ~= panel._alt then
      m.alt = panel._alt
      if BV.scroll then BV.scroll:SetVerticalScroll(0) end
    end
    m.n, m.sn = 0, 0
    m.build = m.build + 1
    Sect(nil, 0)
  end
  m.src = src
  -- The inbox's mark the kinds were read at: every build's for the first
  -- section, which is always read again; the last whole build's for a
  -- C.O.D. mail's tiles, which a run's builds leave as they were.
  m.gen = Mail().InboxGen()
  if not frozen then m.wholeGen = m.gen end
  if src == "inbox" then
    BV.TallyInbox(panel, frozen)
  end
  m.frozen = false
  return frozen
end

-------------------------------------------------------------
-- 3. The grid
-------------------------------------------------------------

-- Where every kind and every line stands, for the width the bag has: as
-- many tiles to a line as fit (the scroll bar's room is always kept, so
-- the count never changes when the bar comes), the lines centered; a
-- section's gold first; each section's line over its tiles.
function BV.Layout()
  local m = model
  local size, gap = Th().Metrics.slotSize, BV.GAP
  local width = BV.scroll:GetWidth() or 0
  -- Not laid out yet (its first frame): the width its child was made with.
  if width <= 10 then width = BV.child:GetWidth() or 0 end
  if width < size then width = size end
  local step = size + gap
  local per = max(1, floor((width + gap) / step))
  local x0 = max(0, floor((width - (per * size + (per - 1) * gap)) / 2))
  local y = BV.PAD
  local shown, tail = 0, 0
  for si = 1, m.sn do
    local s = m.sects[si]
    local list = s.list
    local gold = s.by[0]
    if gold and list[1] ~= gold then
      local at = 1
      for i = 2, s.n do
        if list[i] == gold then
          at = i
          break
        end
      end
      for i = at, 2, -1 do list[i] = list[i - 1] end
      list[1] = gold
    end
    s.shown = s.head ~= nil and (s.n > 0 or s.rem)
    if s.shown then
      s.y = y
      y = y + BV.HEAD
      shown = shown + 1
      tail = 0
    end
    for i = 1, s.n do
      local kind = list[i]
      local col = (i - 1) % per
      if col == 0 and i > 1 then y = y + step end
      kind.x, kind.y = x0 + col * step, y
      -- What its lists held past this build's mails is let go.
      for k = kind.mails + 1, kind.top do kind.ref[k], kind.cnt[k] = nil, nil end
      kind.top = kind.mails
    end
    if s.n > 0 then
      y = y + step
      tail = gap
    end
  end
  m.lines = shown
  m.height = (m.n > 0 or shown > 0) and (y - tail + BV.PAD) or 0
end

-- kind -> its crafting mark, read once a build: the stack's own link where
-- the mail is listed and read, the item's by its id otherwise.
function BV.MarkOf(kind)
  if kind.markAt == model.build then return kind.mark end
  kind.markAt = model.build
  local RV = Parts().RV
  local mark
  if kind.live and kind.index and kind.slot then
    mark = RV.QualityMark(kind.index, kind.slot)
  else
    local link = kind.link
    if not link and kind.id and C_Item and type(C_Item.GetItemInfo) == "function" then
      local _, generic = C_Item.GetItemInfo(kind.id)
      link = generic
    end
    mark = RV.MarkOf(link)
  end
  kind.mark = mark
  return mark
end

-- The i-th tile, made on first use: the fan's tile and the reading view's
-- slot, part for part (the slot's surface through Theme.ApplySlot, the
-- quality mark and the count by the icons' own rules, the warning triangle
-- at its top right), so every look dresses it as it dresses those.
function BV.Tile(i)
  local tile = BV.tiles[i]
  if tile then return tile end
  local P, T = Parts(), Th()
  local RV = P.RV
  local size = T.Metrics.slotSize
  tile = CreateFrame("Button", nil, BV.child, "BackdropTemplate")
  tile:SetSize(size, size)
  tile:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  local art = tile:CreateTexture(nil, "BACKGROUND")
  art:SetAllPoints()
  art:SetTexture(P.EMPTY_SLOT_ART)
  art:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  tile.Icon = tile:CreateTexture(nil, "ARTWORK")
  tile.Icon:SetAllPoints()
  tile.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  local over = CreateFrame("Frame", nil, tile)
  over:SetAllPoints(tile)
  tile.Mark, tile.MarkShadow = RV.NewMark(over)
  tile.Count = RV.IconRule.NewCount(over)
  tile.Count:Show()
  local warning = P.ProbeAtlas(T.AtlasSets.warning)
  if warning then
    tile.Warn = tile:CreateTexture(nil, "OVERLAY", nil, 2)
    tile.Warn:SetAtlas(warning, false)
    tile.Warn:SetSize(P.ROW_WARNING + 1, P.ROW_WARNING + 1)
  else
    tile.Warn = T.CreateText(tile, "value")
    tile.Warn:SetText(P.WARNING_GLYPH)
  end
  tile.Warn:SetPoint("TOPRIGHT", tile, "TOPRIGHT", -1, -1)
  T.SetColor(tile.Warn, "warning")
  tile.Warn:Hide()
  tile.Hi = tile:CreateTexture(nil, "HIGHLIGHT")
  tile.Hi:SetAllPoints()
  tile.Hi:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
  tile.Hi:SetBlendMode("ADD")
  T.ApplySlot(tile)
  -- A tile bound again under a pointer that has not moved says what it now
  -- shows (Theme.TipFollow).
  tile.__pbTipRow = tile
  BV.tiles[i] = tile
  return tile
end

-- tile, kind -> the tile as the kind reads now; only what changed is set.
-- Its look: 0 as it is, 1 held back (the fan's dim, with the triangle),
-- 2 not from here (the gray), 3 an emptied place kept while a run is going.
function BV.Paint(tile, kind)
  tile.kind = kind
  local RV = Parts().RV
  local look = 0
  if kind.n <= 0 then
    look = 3
  elseif kind.sect.look == 2 then
    look = 2
  elseif model.src == "inbox" and not kind.gold and kind.free == 0 then
    look = 1
  end
  kind.look = look
  local tex, text, atlas = nil, "", nil
  if look ~= 3 then
    tex = kind.tex
    if kind.gold then
      text = RV.Fan.MoneyText(false, kind.n)
    else
      text = RV.CountText(kind.n) or ""
      if RV.MarkOnIcon() then atlas = RV.AtlasOf(BV.MarkOf(kind)) end
    end
  end
  if tile.pbTex ~= tex then
    tile.pbTex = tex
    tile.Icon:SetTexture(tex)
    tile.Icon:SetShown(tex ~= nil)
  end
  if tile.pbText ~= text then
    tile.pbText = text
    tile.Count:SetText(text)
  end
  if tile.pbAtlas ~= atlas then
    tile.pbAtlas = atlas
    RV.ShowMark(tile.Mark, tile.MarkShadow, atlas)
  end
  if tile.pbLook ~= look then
    tile.pbLook = look
    local dim, gray = look == 1, look == 2
    -- In color and alpha together, so each reads at any window opacity.
    tile.Icon:SetDesaturated(dim or gray)
    local v = dim and 0.6 or 1
    tile.Icon:SetVertexColor(v, v, v)
    tile.Icon:SetAlpha(dim and 0.6 or (gray and BV.GRAY_A or 1))
    tile.Warn:SetShown(dim)
    local ink = gray and BV.GRAY_INK or 1
    tile.Count:SetTextColor(ink, ink, ink, 1)
    -- Nothing lights under the pointer where a click does nothing.
    tile.Hi:SetAlpha((gray or look == 3) and 0 or 1)
  end
end

-- The i-th section line, made on first use: a hairline and its words
-- centered, nothing under the pointer.
function BV.Head(i)
  local head = BV.heads[i]
  if head then return head end
  local T = Th()
  head = CreateFrame("Frame", nil, BV.child)
  head:SetHeight(BV.HEAD)
  head:EnableMouse(false)
  head.Rule = head:CreateTexture(nil, "ARTWORK")
  head.Rule:SetHeight(1)
  head.Rule:SetPoint("TOPLEFT", head, "TOPLEFT", 0, 0)
  head.Rule:SetPoint("TOPRIGHT", head, "TOPRIGHT", 0, 0)
  T.FillChrome(head.Rule, 0.16)
  head.Text = T.CreateText(head, "value")
  head.Text:SetPoint("CENTER", head, "CENTER", 0, -1)
  head.Text:SetJustifyH("CENTER")
  head.Text:SetWordWrap(false)
  BV.heads[i] = head
  return head
end

-- The tiles and lines in view bound, each tile placed again where it
-- stands; the rest of both pools put away.
function BV.Bind()
  local m = model
  local RV = Parts().RV
  local scroll, child = BV.scroll, BV.child
  local size = Th().Metrics.slotSize
  local offset = scroll:GetVerticalScroll() or 0
  local top, bottom = offset - size, offset + (scroll:GetHeight() or 0)
  local used, lines = 0, 0
  for si = 1, m.sn do
    local s = m.sects[si]
    if s.shown and s.y >= offset - BV.HEAD and s.y <= bottom then
      lines = lines + 1
      local head = BV.Head(lines)
      head:ClearAllPoints()
      head:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -s.y)
      head:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -s.y)
      local width = child:GetWidth() or 0
      if head.pbText ~= s.head or head.pbWidth ~= width then
        head.pbText, head.pbWidth = s.head, width
        Th().FitText(head.Text, width - 2 * Th().Metrics.inset, s.head, nil)
      end
      head:Show()
    end
    local list = s.list
    for i = 1, s.n do
      local kind = list[i]
      local y = kind.y
      if y >= top and y <= bottom then
        used = used + 1
        local tile = BV.Tile(used)
        RV.PlaceMark(tile.Mark, tile.MarkShadow, tile.Icon, size)
        RV.IconRule.EnsureCount(tile.Count, tile.Icon, size)
        BV.Paint(tile, kind)
        tile:ClearAllPoints()
        tile:SetPoint("TOPLEFT", child, "TOPLEFT", kind.x, -y)
        tile:Show()
      end
    end
  end
  local tiles, heads = BV.tiles, BV.heads
  for i = used + 1, #tiles do
    local tile = tiles[i]
    if tile.kind ~= nil or tile:IsShown() then
      tile.kind = nil
      tile:Hide()
    end
  end
  for i = lines + 1, #heads do heads[i]:Hide() end
  Th().TipFollow(child)
end

-- The bag's own frames, made the first time it shows: its ground in the
-- list's place (the list's own surface, tagged as the list's is, so each
-- look dresses it alike), a scroll frame with the house's slim bar and the
-- bar's room always kept, and the words for a bag with nothing in it.
function BV.Ensure(panel)
  if BV.area then return BV.area end
  local P, T = Parts(), Th()
  local M = T.Metrics
  local area = CreateFrame("Frame", nil, panel, "BackdropTemplate")
  area:SetAllPoints(panel.MailListArea)
  T.ApplyList(area)
  local scroll = CreateFrame("ScrollFrame", nil, area, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", area, "TOPLEFT", M.tightGap, -M.tightGap)
  scroll:SetPoint("BOTTOMRIGHT", area, "BOTTOMRIGHT", -M.scrollGutter, M.tightGap)
  P.PinScrollBar(scroll, area)
  if scroll.SetClipsChildren then scroll:SetClipsChildren(true) end
  local child = CreateFrame("Frame", nil, scroll)
  local width = scroll:GetWidth() or 0
  if width <= 10 then width = max(1, (panel.MailListArea:GetWidth() or 0) - M.tightGap - M.scrollGutter) end
  child:SetSize(width, 1)
  scroll:SetScrollChild(child)
  scroll:HookScript("OnSizeChanged", BV.OnSize)
  scroll:HookScript("OnVerticalScroll", BV.OnScroll)
  area.Empty = T.CreateText(area, "secondary")
  area.Empty:SetPoint("TOPLEFT", area, "TOPLEFT", M.inset * 2, -M.inset * 2)
  area.Empty:SetPoint("RIGHT", area, "RIGHT", -M.inset * 2, 0)
  area.Empty:SetJustifyH("LEFT")
  area.Empty:Hide()
  area:Hide()
  BV.area, BV.scroll, BV.child, BV.panel = area, scroll, child, panel
  if ns.Skin and ns.Skin.Refresh then pcall(ns.Skin.Refresh, area) end
  return area
end

-- The bag laid out as built: its height, the scroll held inside it, the
-- tiles in view, and the words where there is nothing to draw (the list's
-- own where the list is empty too).
function BV.Apply(panel)
  local m = model
  local scroll, child, area = BV.scroll, BV.child, BV.area
  local height = max(m.height, 1)
  local most = max(0, m.height - (scroll:GetHeight() or 0))
  if (scroll:GetVerticalScroll() or 0) > most then scroll:SetVerticalScroll(most) end
  if BV.laidHeight ~= height then
    BV.laidHeight = height
    child:SetHeight(height)
    if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end
  end
  BV.Bind()
  local none = m.n == 0 and (m.lines or 0) == 0
  if none then
    local listEmpty = panel.Empty and panel.Empty:IsShown()
    area.Empty:SetText(listEmpty and (panel.Empty:GetText() or "") or L()["BAG_EMPTY"])
  end
  area.Empty:SetShown(none)
end

function BV.OnSize(scroll, width)
  if not (BV.area and BV.area:IsShown()) then return end
  if width and width > 10 then BV.child:SetWidth(width) end
  BV.Layout()
  BV.Apply(BV.panel)
end

function BV.OnScroll()
  if BV.area and BV.area:IsShown() then BV.Bind() end
end

-- The end of every list refresh (CT.RefreshMailList): the switch painted
-- for the list on screen, and the bag drawn in the list's place, or the
-- list put back. Off, that is all it does.
function BV.Refresh(panel)
  if not panel._bagHooked and panel.Detail then
    -- Once a panel: the reading view's coming and going is heard.
    panel._bagHooked = true
    BV.panel = panel
    panel.Detail:HookScript("OnShow", BV.DetailChanged)
    panel.Detail:HookScript("OnHide", BV.DetailChanged)
  end
  local area = BV.area
  if not BV.Active(panel) then
    if area and area:IsShown() then
      area:Hide()
      if GameTooltip:IsShown() then GameTooltip:Hide() end
      -- The list back in its place, unless the reading view has it.
      local detail = panel.Detail
      if not (detail and detail:IsShown()) then
        panel.MailListArea:Show()
        -- The rows were bound while out of sight: once more, as the list
        -- on screen (its Alt marks are aimed by this pass).
        local CT = ns.CollectTab
        if type(CT.RebindRows) == "function" then CT.RebindRows(panel) end
      end
    end
    return
  end
  area = BV.Ensure(panel)
  if panel.MailListArea:IsShown() then panel.MailListArea:Hide() end
  if not area:IsShown() then
    area:Show()
    Parts().RV.FanClose(true)
  end
  if not BV.Build(panel) then BV.Layout() end
  BV.Apply(panel)
end

-- The arrange mode opened over the tab or left it (CT.ArrangeHost): it
-- arranges the list's rows, so the list is what shows while it is up.
function BV.Yield(panel, on)
  panel._bagYield = on and true or nil
  if panel:IsShown() then BV.Refresh(panel) end
end

-- The reading view came up or went (CollectTab's BuildDetail hides the list
-- as it shows and puts it back as it hides): the bag stands aside for it as
-- the list does, and is drawn again in the list's place after it.
function BV.DetailChanged()
  local panel = BV.panel
  if not (panel and BV.On()) then return end
  local detail = panel.Detail
  if detail and detail:IsShown() then
    if BV.area and BV.area:IsShown() then BV.area:Hide() end
  elseif panel:IsShown() and BV.Active(panel) then
    BV.Refresh(panel)
  end
end
