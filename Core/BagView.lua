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
-- The mails a tile's run is started with, copied from its kind: the list
-- may be built again before the run reads them.
BV.queue = {}
-- A link's item id, kept (History's records hold links): false for none.
BV.ids, BV.idsN, BV.IDS_MAX = {}, 0, 2048

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
-- The "how many" box (section 5b).
BV.Many = { open = false, steps = {}, stacks = {}, at = {}, n = 0, pick = 1 }

-------------------------------------------------------------
-- 1. The switch's state
-------------------------------------------------------------

-- Whether the player chose the bag (profile.bagView, MailboxUI's
-- OPTION_DEFAULTS; unset is off).
function BV.On()
  local UI = ns.MailboxUI
  return UI ~= nil and type(UI.GetOption) == "function" and UI.GetOption("bagView") == true
end

-- panel -> whether the list on screen has no bag to show: the Done tab.
function BV.Gray(panel)
  local P = Parts()
  return P ~= nil and panel.viewMode == P.VIEW_DONE and not P.AV.Active(panel)
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
    kind = { ref = {}, cnt = {}, stk = {}, fre = {}, top = 0 }
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
    kind.stk[m] = kind.stk[m] + 1
  else
    m = m + 1
    kind.mails = m
    kind.ref[m], kind.cnt[m] = where, count
    -- The stacks it holds there, and whether a run may take them.
    kind.stk[m], kind.fre[m] = 1, free and true or false
  end
end

-- link -> its item id, read once a link.
function BV.IdOf(link)
  if type(link) ~= "string" then return nil end
  local id = BV.ids[link]
  if id == nil then
    id = tonumber((link:match("item:(%d+)"))) or false
    if BV.idsN >= BV.IDS_MAX then
      for key in pairs(BV.ids) do BV.ids[key] = nil end
      BV.idsN = 0
    end
    BV.ids[link] = id
    BV.idsN = BV.idsN + 1
  end
  return id or nil
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

-- A C.O.D. mail: its own section under its price and who sent it, one tile
-- a stack (the key is the slot), so a click names one take, as the fan's
-- does. The line's words are made again only when the price or the sender
-- of that place changed.
local function TallyCOD(P, index, sender, cod, itemCount, slots, held)
  local s = Sect(nil, 0)
  if s.codAmount ~= cod or s.codFrom ~= sender then
    s.codAmount, s.codFrom = cod, sender
    s.codText = P.RV.Fan.MoneyText(true, cod) .. P.RV.SLOT_DOT .. tostring(sender or L()["SENDER_UNKNOWN"])
  end
  s.head = s.codText
  local found = 0
  for slot = 1, slots do
    local name, id, tex, count = GetInboxItem(index, slot)
    if tex then
      found = found + 1
      local kind = Kind(s, slot)
      if kind then
        kind.id, kind.name, kind.tex, kind.index, kind.slot = id, name, tex, index, slot
        kind.cod, kind.live = true, true
        Put(kind, tonumber(count) or 1, index, held == nil, held)
      end
      if found >= itemCount then break end
    end
  end
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
        if not frozen and itemCount > 0 then TallyCOD(P, index, sender, cod, itemCount, slots, held) end
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

-- Under the list's own line, the mail the game has not listed yet that
-- Postbox remembers: the list's remembered rows (RV.remShown, Mail Memory's
-- own set, as the search and the filters left it), each row's source read
-- for what it held. The line stands with none, as it does in the list.
function BV.TallyRemembered(panel)
  if (panel._remExtra or 0) <= 0 then return end
  local s = Sect(panel._lineText, 2)
  -- Its words without their inks, for a look that lays the line on a
  -- ground of its own (BV.Bind).
  s.rem, s.plain = true, panel._linePlain
  local shown = Parts().RV.remShown
  for k = 1, #shown do
    local m = shown[k]
    if (m.money or 0) > 0 then Gold(s, m.money, m, false) end
    if (m.items or 0) > 0 then
      local note, seen = m.note, m.seen
      local list = seen and seen.it
      if type(list) == "table" and #list >= 2 then
        for j = 1, #list - 1, 2 do
          Item(s, tonumber(list[j]), nil, nil, list[j + 1], m, j == 1 and seen.link or nil)
        end
      elseif note then
        Item(s, tonumber(note.i), m.b, m.icon, max(1, m.quantity or 1), m, note.l or nil)
      else
        Item(s, seen and tonumber(seen.id) or nil, nil, m.icon, max(1, m.iconCount or 1), m, seen and seen.link or nil)
      end
    end
  end
end

-- A heading of the list (a character's, in a search of every box; the mail
-- sent a box since its visit) -> its words.
local function HeadText(row)
  if type(row.label) == "string" and row.label ~= "" then return row.label end
  local Memory = ns.MailMemory
  if Memory and type(Memory.ClassName) == "function" and row.name then
    return Memory.ClassName(row.realm, row.name, false, "window")
  end
  return tostring(row.name or "")
end

-- Another character's box, or every box's matches (panel._avRows, Mail
-- Memory's rows as the list shows them): what each remembered mail held. A
-- heading of the list heads a section here; what was noted as arriving
-- since the box was seen stands under Mail Memory's own words for it.
function BV.TallyAway(panel)
  local rows = panel._avRows or NONE
  local main = model.sects[1]
  local s, arrived = main, nil
  for i = 1, #rows do
    local mail = rows[i]
    if mail.header then
      s = Sect(HeadText(mail), 0)
      s.realm, s.name = mail.realm, mail.name
    elseif mail.note then
      if mail.rule or mail.line then s = main end
    else
      local into = s
      if mail.pending and s == main then
        if not arrived then arrived = Sect(L()["MEMORY_NEW_SINCE"], 0) end
        into = arrived
      end
      local money = tonumber(mail.money) or 0
      if money > 0 then Gold(into, money, mail, false) end
      local list = mail.it
      if type(list) == "table" and #list >= 2 then
        for j = 1, #list - 1, 2 do
          Item(into, tonumber(list[j]), nil, nil, list[j + 1], mail, j == 1 and mail.link or nil)
        end
      elseif (tonumber(mail.items) or 0) > 0 then
        local id = tonumber(mail.id) or nil
        Item(into, id, (not id) and mail.pending and mail.subject or nil, mail.icon or nil,
          tonumber(mail.count) or 1, mail, mail.link or nil)
      end
    end
  end
end

-- History's list (panel._history, Received or Sent): what each entry says
-- came out or was sent, a kind an item id read from the entry's link.
function BV.TallyHistory(panel)
  local out = panel._history or NONE
  local s = model.sects[1]
  for i = 1, #out do
    local e = out[i]
    if e.header then
      s = Sect(HeadText(e), 0)
    else
      local money = tonumber(e.m) or 0
      if money > 0 and not e.r then Gold(s, money, e, false) end
      local items = e.it
      if type(items) == "table" then
        for j = 1, #items do
          local it = items[j]
          local link = type(it) == "table" and it.l or nil
          if link then Item(s, BV.IdOf(link), link, nil, it.n, e, link) end
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
    if not frozen then BV.TallyRemembered(panel) end
  elseif src == "away" then
    BV.TallyAway(panel)
  else
    BV.TallyHistory(panel)
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
  tile:SetScript("OnEnter", BV.TileEnter)
  tile:SetScript("OnLeave", BV.TileLeave)
  tile:SetScript("OnClick", BV.TileClick)
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
  head = BV.NewHead()
  BV.heads[i] = head
  return head
end

-- The line over the mail the game has not listed yet is the list's own
-- line, so it wears what the list's wears: a frame of its own, never one
-- of the pool, since a look may lay a ground on it (Theme.LineGround, the
-- Blizzard look's, as CollectTab's RV.PlaceLine asks for the list's).
function BV.RemHead()
  local head = BV.remHead
  if not head then
    head = BV.NewHead()
    BV.remHead = head
  end
  return head
end

function BV.NewHead()
  local T = Th()
  local head = CreateFrame("Frame", nil, BV.child)
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
  local used, lines, remUp = 0, 0, false
  for si = 1, m.sn do
    local s = m.sects[si]
    if s.shown and s.y >= offset - BV.HEAD and s.y <= bottom then
      local head, text = nil, s.head
      if s.rem then
        head, remUp = BV.RemHead(), true
      else
        lines = lines + 1
        head = BV.Head(lines)
      end
      head:ClearAllPoints()
      head:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -s.y)
      head:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -s.y)
      do
        -- On the look's ground for a line of words where it has one (the
        -- Blizzard look's gold-edged note, Theme.LineGround, on its page):
        -- the words in the ground's one ink, a C.O.D. line's price still in
        -- its own, and the hairline the ground's. Asked for every line at
        -- every bind, so a line follows Row texture to None and back.
        local T = Th()
        local grounded = T.LineGround and T.LineGround(head) or false
        if head.grounded ~= grounded then
          if not grounded and head.grounded ~= nil then T.ApplyTextRole(head.Text, "value") end
          head.grounded = grounded
          head.Rule:SetShown(not grounded)
        end
        if grounded and s.plain then text = s.plain end
      end
      local width = child:GetWidth() or 0
      if head.pbText ~= text or head.pbWidth ~= width then
        head.pbText, head.pbWidth = text, width
        Th().FitText(head.Text, width - 2 * Th().Metrics.inset, text, nil)
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
  if BV.remHead and not remUp then BV.remHead:Hide() end
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
  -- One sheet of the look's paper under the whole bag where the look has
  -- one for it (Theme.PageGround: the Blizzard look, Row texture Light or
  -- Dark). On one page the part not listed yet cannot stand on dimmer
  -- paper than the rest, so its tiles alone carry the gray.
  local page = Th().PageGround
  BV.paged = page and page(area) or false
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
  if BV.Many.open then BV.Many.Close() end
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
  BV.PaintSwitch(panel)
  local area = BV.area
  if not BV.Active(panel) then
    if BV.Many.box then BV.Many.Close() end
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
    local RV = Parts().RV
    RV.FanClose(true)
    -- Alt's marks belong to the list's rows: with the list out of sight
    -- they end now, held or kept on, and stay off while the bag is up
    -- (RV.Marks is eligible only while the list's own container shows).
    -- Nothing a tile does returns or deletes mail.
    if RV.Marks and RV.Marks.Sync then RV.Marks.Sync(panel) end
  end
  if not BV.Build(panel) then BV.Layout() end
  BV.Apply(panel)
  if BV.Many.open then BV.Many.Check() end
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

-------------------------------------------------------------
-- 4. The switch
-------------------------------------------------------------

-- The mark's ink: the accent's bright tone while the bag is on, as a
-- selected segment's caption; otherwise the chrome's gray, unless a look
-- paints it as its caption (Theme.SetPlateGlyph).
function BV.PaintGlyph(icon)
  local cell = icon:GetParent()
  if cell.isSelected then
    Th().SetColor(icon, "accentBright")
  elseif not cell.__pbGlyphLit then
    Th().SetColor(icon, "textSecondary")
  end
  if cell._gray then icon:SetAlpha(0.35) end
end

-- Lit while the bag is on; gray where the list on screen has none to show.
function BV.PaintSwitch(panel)
  local cell = panel.BagSwitch
  if not cell then return end
  local gray = BV.Gray(panel)
  local on = BV.On() and not gray
  if cell.isSelected ~= on or cell._gray ~= gray then
    cell._gray = gray
    if cell.isSelected ~= on then Th().SetPlateSelected(cell, on) end
    if cell.Icon then
      cell.Icon:SetAlpha(1)
      BV.PaintGlyph(cell.Icon)
    end
  end
end

-- panel, on -> the choice saved (profile.bagView) and the list drawn for it.
function BV.Set(panel, on)
  local UI = ns.MailboxUI
  if not (UI and type(UI.SetOption) == "function") then return end
  UI.SetOption("bagView", on and true or false)
  ns.CollectTab.RefreshMailList(panel)
end

function BV.SwitchTip(cell)
  local T, L0 = Th(), L()
  T.TipBegin(cell)
  T.TipTitle(L0["BAG_TIP_TITLE"])
  T.TipLine(L0["BAG_TIP_LINE"])
  if cell._gray then
    local P, panel = Parts(), cell._panel
    if P and panel and panel.viewMode == P.VIEW_DONE then T.TipLine(T.TipTone("muted", L0["BAG_TIP_DONE"])) end
  else
    T.TipHint(L0[cell.isSelected and "BAG_TIP_LIST" or "BAG_TIP_SHOW"])
  end
  GameTooltip:Show()
end

function BV.SwitchEnter(cell)
  if cell.Icon then BV.PaintGlyph(cell.Icon) end
  BV.SwitchTip(cell)
end

function BV.SwitchLeave(cell)
  if cell.Icon then BV.PaintGlyph(cell.Icon) end
  GameTooltip:Hide()
end

-- A right-click is the way back to the list: while the bag is lit it is the
-- click itself; while the list is up it does nothing.
function BV.SwitchClick(cell, button)
  if cell._gray then return end
  if button == "RightButton" and not cell.isSelected then return end
  BV.Set(cell._panel, not BV.On())
  if GameTooltip:IsOwned(cell) then BV.SwitchTip(cell) end
end

-- The switch, built with the find plate (CollectTab's BuildSearchBox): a
-- square plate the segments' height, joined to the search as its last cell
-- after the sort, which moves one cell in (Theme.JoinCell; the search ends
-- before both, Theme's search.endExtra, and RV.SortRoom counts both).
function BV.BuildSwitch(panel)
  local P, T = Parts(), Th()
  local wrap, search, sort = panel.SearchWrap, panel.Search, panel.Sort
  if panel.BagSwitch or not (P and wrap and search and sort) then return end
  local size = T.Metrics.segmentHeight
  local cell = T.CreatePlate(panel, "segment")
  cell:SetSize(size, size)
  cell:SetText("")
  cell._panel, cell._gray = panel, false
  cell.Icon = T.Glyph and T.Glyph(cell, BV.GLYPH, nil, "OVERLAY") or nil
  if cell.Icon then
    cell.Icon:SetPoint("CENTER", cell, "CENTER", 0, 0)
    T.SetPlateGlyph(cell, cell.Icon, BV.PaintGlyph)
  else
    cell:SetText("#")
  end
  cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  cell:SetScript("OnClick", BV.SwitchClick)
  cell:HookScript("OnEnter", BV.SwitchEnter)
  cell:HookScript("OnLeave", BV.SwitchLeave)
  T.JoinCell(wrap, cell)
  sort:ClearAllPoints()
  sort:SetPoint("TOPRIGHT", wrap, "TOPRIGHT", -(size - 1), 0)
  sort:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", -(size - 1), 0)
  panel.BagSwitch = cell
  search.endExtra = size - 1
  search.SetJoined(panel._sortPlaced ~= false)
  panel._searchW = nil
  P.RV.SizeSearch(panel, panel._searchGiven or 0)
  T.SetPlateSelected(cell, false)
end

-------------------------------------------------------------
-- 5. Tooltips
-------------------------------------------------------------

-- Whether the bag (or, given a kind, that kind) was read at the inbox's
-- mark as it stands: only then do its indices name the mails it drew
-- (CollectTab's binding rule).
function BV.Current(kind)
  local gen = model.gen
  if kind and kind.cod then gen = model.wholeGen end
  return gen ~= nil and gen == Mail().InboxGen()
end

-- kind -> a listed kind's first stack, while the bag is current and the
-- slot still holds that item: the mail's index and the slot.
function BV.LiveSlot(kind)
  if not (kind.live and kind.index and kind.slot and BV.Current(kind)) then return nil end
  local _, id = GetInboxItem(kind.index, kind.slot)
  if id == nil or id ~= kind.id then return nil end
  return kind.index, kind.slot
end

-- kind -> a link for it: the stack's own where the game has one, the
-- record's, or the item's by its id.
function BV.LinkOf(kind)
  local index, slot = BV.LiveSlot(kind)
  local link = index and GetInboxItemLink(index, slot) or kind.link
  if not link and kind.id and C_Item and type(C_Item.GetItemInfo) == "function" then
    local _, generic = C_Item.GetItemInfo(kind.id)
    link = generic
  end
  return link
end

-- kind -> its name, bare (no crafting mark's atlas).
function BV.NameOf(kind)
  local name = kind.name
  if not name and type(kind.link) == "string" then name = kind.link:match("|h%[(.-)%]|h") end
  if not name and kind.id and C_Item and type(C_Item.GetItemInfo) == "function" then
    name = C_Item.GetItemInfo(kind.id)
  end
  if type(name) ~= "string" then return nil end
  name = name:gsub("%s*|A:.-|a", "")
  return name
end

-- The item's own tooltip as the title: from the mail and slot where it is
-- listed, by its link or its id otherwise, its name where the game has
-- nothing for it.
function BV.TipItem(kind)
  local index, slot = BV.LiveSlot(kind)
  if index and type(GameTooltip.SetInboxItem) == "function" then
    GameTooltip:SetInboxItem(index, slot)
  elseif type(kind.link) == "string" then
    GameTooltip:SetHyperlink(kind.link)
  elseif kind.id and type(GameTooltip.SetItemByID) == "function" then
    GameTooltip:SetItemByID(kind.id)
  else
    Th().TipTitle(BV.NameOf(kind) or RETRIEVING_ITEM_INFO or "?")
  end
end

-- One of the kind's mails on a line: who, how many (or how much), and the
-- time left, in the warning tone when it is short; an entry of History's,
-- how long ago.
function BV.TipMail(kind, i)
  local P, T, H = Parts(), Th(), ns.Helpers
  local where, count = kind.ref[i], kind.cnt[i]
  local who, days, age
  if type(where) == "number" then
    local _, _, sender, _, _, _, daysLeft = GetInboxHeaderInfo(where)
    who, days = sender, tonumber(daysLeft)
  elseif model.src == "history" then
    who = where.s
    age = P.HV.EntryAge(where, time(), P.HV.AgeStyle())
  else
    who = where.sender
    local expires = tonumber(where.expires)
    if expires then days = (expires - time()) / 86400 end
  end
  if type(who) ~= "string" or who == "" then who = L()["SENDER_UNKNOWN"] end
  local right = kind.gold and ns.Core.Formatting.FormatMoneyCompact(count, true) or tostring(count)
  if age then
    right = right .. P.RV.SLOT_DOT .. age
  elseif days and days > 0 then
    local _, short = P.ExpiryState(days, false)
    local left = H.TimeLeft(days)
    right = right .. P.RV.SLOT_DOT .. (short and T.TipTone("warning", left) or left)
  end
  GameTooltip:AddDoubleLine(who, right, 0.82, 0.82, 0.82, 1, 1, 1)
end

BV.FROM = { sold = "ROWS_REM_SOLD", bought = "ROWS_REM_BOUGHT", canceled = "ROWS_REM_CANCELED",
  expired = "ROWS_REM_EXPIRED", visit = "ROWS_REM_VISIT" }
-- What Mail Memory's take hint reads of a row (MM.TakeHint): whose box.
BV.who = {}

-- Why a tile cannot simply be taken, as the last of its facts: not listed
-- by the game yet, and where Postbox knows it from (the remembered rows'
-- own words); or held back, in the warning tone.
function BV.TipWhy(kind)
  local T, L0 = Th(), L()
  if kind.sect.look == 2 then
    T.TipLine(L0["MINIMAP_TIP_UNLISTED"])
    local first = kind.ref[1]
    local from = type(first) == "table" and BV.FROM[first.src] or nil
    if from then T.TipLine(T.TipTone("muted", L0[from])) end
  elseif model.src == "inbox" and kind.why and (kind.look == 1 or not kind.cod) then
    -- Some or all of it in mail a run leaves.
    GameTooltip:AddLine(T.TipTone("warning", BV.Why(kind)), 1, 1, 1, true)
  end
end

-- What the gestures do, last: the take where a click takes (with what it
-- takes: every stack a run may), its mails, the link and the try-on; where
-- nothing can be taken from here, where it can be.
function BV.TipHints(kind)
  local P, T, L0 = Parts(), Th(), L()
  local RV = P.RV
  local src, s = model.src, kind.sect
  local dress = (not kind.gold) and RV.Dressable(kind.id) or false
  local linkHint = (not kind.gold) and L0[dress and "TILE_HINT_LINK_DRESS" or "TILE_HINT_LINK"] or nil
  local mailsHint = (not kind.gold) and L0["BAG_HINT_MAILS"] or nil
  if s.look == 2 then
    T.TipHint(L0["ROWS_REM_HINT_WAIT"])
    T.TipHint(linkHint)
  elseif src == "inbox" then
    if kind.cod then
      local index, slot = BV.LiveSlot(kind)
      if index then T.TipHint(RV.TileHint(index, slot, kind.look == 1)) end
    elseif kind.gold then
      T.TipHint(L0["FAN_GOLD_HINT"])
    else
      if kind.free > 0 then T.TipHint(L0("BAG_HINT_TAKE", kind.freeN)) end
      T.TipHint(mailsHint)
      -- In two mails or more a Shift-click with no chat box open asks how
      -- many (BV.Many); the link's line stays where there is a try-on to say.
      if BV.Many.Steps(kind) >= 2 then
        T.TipHint(L0["BAG_HINT_MANY"])
        if dress then T.TipHint(linkHint) end
      else
        T.TipHint(linkHint)
      end
    end
  elseif src == "away" then
    local Memory = ns.MailMemory
    local who = BV.who
    local info = BV.panel and BV.panel._avInfo
    who.boxRealm, who.boxName = s.realm or (info and info.realm), s.name or (info and info.name)
    if Memory and type(Memory.TakeHint) == "function" then T.TipHint(Memory.TakeHint(who)) end
    T.TipHint(mailsHint)
    T.TipHint(linkHint)
  else
    T.TipHint(mailsHint)
    T.TipHint(linkHint)
  end
end

-- Pointing at a tile: the item (or the gold's sum), how many in how many
-- mails and which, why it cannot be taken where it cannot, then what the
-- gestures do. Built on hover, from the bag as it stands.
function BV.TileEnter(tile)
  local kind = tile.kind
  if not kind or kind.look == 3 then return end
  local T, L0, H = Th(), L(), ns.Helpers
  local src = model.src
  T.TipBegin(tile)
  if kind.gold then
    T.TipTitle(L0["LABEL_GOLD"] .. H.FormatMoney(kind.n))
    if kind.mails > 1 then T.TipLine(ns.Plural("COUNT_MAILS", kind.mails)) end
  else
    BV.TipItem(kind)
    if kind.cod then
      local _, _, _, _, _, cod = GetInboxHeaderInfo(kind.index)
      if (tonumber(cod) or 0) > 0 and BV.Current(kind) then
        T.TipFact(L0["LABEL_COD"], T.TipTone("negative", H.FormatMoney(tonumber(cod))))
      end
    else
      T.TipLine(L0("BAG_IN_MAILS", tostring(kind.n), ns.Plural("COUNT_MAILS", kind.mails)))
    end
  end
  if not kind.cod and (src ~= "inbox" or kind.sect.look == 2 or BV.Current()) then
    local most = kind.mails
    if most > BV.TIP_MAILS then most = BV.TIP_MAILS end
    for i = 1, most do BV.TipMail(kind, i) end
    if kind.mails > most then T.TipLine(T.TipTone("muted", ns.Plural("TIP_MORE", kind.mails - most))) end
  end

  BV.TipWhy(kind)
  BV.TipHints(kind)
  GameTooltip:Show()
end

function BV.TileLeave()
  GameTooltip:Hide()
end

-- kind -> why a run leaves it: the bags are full, or the game's own words
-- for the mail it is stuck in.
function BV.Why(kind)
  local P = Parts()
  if kind.why == "bags" then return L()["FAN_TILE_BAGS"] end
  if BV.Current() then
    for i = 1, kind.mails do
      local where = kind.ref[i]
      local reason = type(where) == "number" and Mail().StuckReason(where) or nil
      if reason then return P.StuckLine(reason) end
    end
  end
  return P.StuckLine(true)
end

-------------------------------------------------------------
-- 5b. How many
--
-- A Shift-click on a tile in two mails or more, where the game had nowhere
-- to put a link (no chat box open), opens a small box under the tile, as
-- the game's own bags ask "how many" of a stack. The game cannot split a
-- stack that is in the mail, so the box steps by whole stacks: one step is
-- one mail's stacks of the item, in the order the list shows the mails, and
-- its number is the running total (40, 80, 100, 120, 137). Take starts the
-- run a plain click starts, for the first mails only, so every rule of a
-- run holds. The arrows, the wheel and Left / Right step; Enter takes;
-- Escape (the house's popup rule, and the box's own) or a press anywhere
-- else closes it with nothing taken, as do a scroll, a list refresh that
-- changes the tile, a run, the bag going away and the mailbox closing.
--
-- While it is open the keyboard is its own (an unseen edit box holds it,
-- as a search box does); shut, it holds nothing. Made the first time it
-- opens: a card on the popups' ground, as the fan's plate is, so each look
-- dresses it as it dresses that; two segment plates, a house button.
-------------------------------------------------------------
local Many = BV.Many
Many.W, Many.H, Many.CELL, Many.FIELD, Many.TAKE_W = 156, 54, 22, 46, 50

-- kind -> how many steps it has: the mails of it a run may take.
function Many.Steps(kind)
  local n = 0
  for i = 1, kind.mails do
    if kind.fre[i] then n = n + 1 end
  end
  return n
end

-- kind -> whether a Shift-click asks how many of it: a tile a plain click
-- would take every stack of, right now, in two mails or more.
function Many.May(kind)
  if model.src ~= "inbox" or kind.look ~= 0 or kind.cod or kind.gold or not kind.id then return false end
  if not Parts().MailboxOpen() or ns.CollectTab.IsRunning() or Mail().IsBusy() then return false end
  return BV.Current(kind) and Many.Steps(kind) >= 2
end

-- kind -> its steps read: which of its mails each is, the running total of
-- the item and of its stacks; how many steps.
function Many.Read(kind)
  local n, count, stacks = 0, 0, 0
  for i = 1, kind.mails do
    if kind.fre[i] then
      n = n + 1
      count, stacks = count + kind.cnt[i], stacks + kind.stk[i]
      Many.at[n], Many.steps[n], Many.stacks[n] = i, count, stacks
    end
  end
  Many.n = n
  return n
end

function Many.Paint()
  local T = Th()
  local pick, n = Many.pick, Many.n
  Many.Num:SetText(tostring(Many.steps[pick] or ""))
  Many.Sub:SetText(L()("BAG_MANY_STACKS", Many.stacks[pick] or 0, Many.stacks[n] or 0))
  -- An arrow at its end is drawn disabled, and its click steps nowhere.
  if Many.Less.Icon then T.SetColor(Many.Less.Icon, pick > 1 and "textSecondary" or "textDisabled") end
  if Many.More.Icon then T.SetColor(Many.More.Icon, pick < n and "textSecondary" or "textDisabled") end
end

function Many.Step(by)
  if not Many.open then return end
  local pick = Many.pick + by
  if pick < 1 then pick = 1 elseif pick > Many.n then pick = Many.n end
  if pick ~= Many.pick then
    Many.pick = pick
    Many.Paint()
  end
end

function Many.ArrowClick(plate)
  Many.Step(plate.dir)
end

function Many.Wheel(_, delta)
  Many.Step((delta or 0) > 0 and 1 or -1)
end

function Many.Key(_, key)
  if key == "LEFT" or key == "DOWN" then
    Many.Step(-1)
  elseif key == "RIGHT" or key == "UP" then
    Many.Step(1)
  end
end

-- Whatever is typed while it has the keyboard is let go: it shows a
-- number of its own, never one that was typed.
function Many.Typed(kb)
  if (kb:GetText() or "") ~= "" then kb:SetText("") end
end

function Many.Close()
  Many.open = false
  local box = Many.box
  if box and box:IsShown() then box:Hide() end
end

-- Hidden, by Many.Close or with the bag: nothing of it is left listening,
-- and the keyboard is the game's again.
function Many.Hidden(box)
  Many.open = false
  box:UnregisterEvent("GLOBAL_MOUSE_DOWN")
  if Many.kb then Many.kb:ClearFocus() end
  -- Hidden with the bag or the window: shut for good, so it is not there
  -- again when they are next shown.
  if box:IsShown() then box:Hide() end
end

-- A press anywhere but on it closes it.
function Many.Event(box, event)
  if event == "GLOBAL_MOUSE_DOWN" and Many.open and not box:IsMouseOver() then Many.Close() end
end

function Many.Build()
  local box = Many.box
  if box then return box end
  local T = Th()
  local cell = Many.CELL
  box = CreateFrame("Frame", nil, BV.area, "BackdropTemplate")
  box:SetSize(Many.W, Many.H)
  -- Over the tiles and their marks, under the reading view.
  box:SetFrameLevel(BV.scroll:GetFrameLevel() + 12)
  box:EnableMouse(true)
  box:EnableMouseWheel(true)
  box:Hide()
  box.__pbPopupAlways = true
  T.ApplyCard(box)
  for k = 1, 2 do
    local plate = T.CreatePlate(box, "segment")
    plate:SetSize(cell, cell)
    plate:SetText("")
    plate.dir = (k == 1) and -1 or 1
    -- The number's field stands between the two, their edges its ends.
    plate:SetPoint("TOPLEFT", box, "TOPLEFT", (k == 1) and 6 or (6 + cell + Many.FIELD - 2), -6)
    plate.Icon = T.Glyph and T.Glyph(plate, (k == 1) and "arrow-left" or "arrow-right", nil, "OVERLAY") or nil
    if plate.Icon then
      plate.Icon:SetPoint("CENTER", plate, "CENTER", 0, 0)
    else
      plate:SetText((k == 1) and "<" or ">")
    end
    plate:SetScript("OnClick", Many.ArrowClick)
    T.SetPlateSelected(plate, false)
    if k == 1 then Many.Less = plate else Many.More = plate end
  end
  -- The field: a hairline over and under the number, from plate to plate.
  for k = 1, 2 do
    local line = box:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", Many.Less, (k == 1) and "TOPRIGHT" or "BOTTOMRIGHT", 0, (k == 1) and 0 or 1)
    line:SetPoint("TOPRIGHT", Many.More, (k == 1) and "TOPLEFT" or "BOTTOMLEFT", 0, (k == 1) and 0 or 1)
    T.FillChrome(line, 0.16)
  end
  Many.Num = T.CreateText(box, "value")
  Many.Num:SetPoint("LEFT", Many.Less, "RIGHT", 0, 0)
  Many.Num:SetPoint("RIGHT", Many.More, "LEFT", 0, 0)
  Many.Num:SetJustifyH("CENTER")
  Many.Num:SetWordWrap(false)
  local take = T.CreateButton(nil, box)
  take:SetSize(Many.TAKE_W, cell)
  take:SetPoint("TOPLEFT", Many.More, "TOPRIGHT", 6, 0)
  take:SetText(L()["BAG_MANY_TAKE"])
  take:SetScript("OnClick", Many.Take)
  Many.TakeButton = take
  Many.Sub = T.CreateText(box, "secondary")
  Many.Sub:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -33)
  Many.Sub:SetPoint("RIGHT", box, "RIGHT", -6, 0)
  Many.Sub:SetJustifyH("LEFT")
  Many.Sub:SetWordWrap(false)
  -- The keyboard, while the box is open: an edit box nobody sees, in a
  -- named font of the house's (Theme.SetBoxFont), given the focus as the
  -- box opens and letting it go as it hides.
  local kb = CreateFrame("EditBox", nil, box)
  kb:SetSize(1, 1)
  kb:SetPoint("TOPLEFT", box, "TOPLEFT", 0, 0)
  kb:SetAlpha(0)
  kb:SetAutoFocus(false)
  local font = (T.FontObject and T.FontObject("numberSmall")) or GameFontHighlightSmall
  if font then T.SetBoxFont(kb, font) end
  if kb.SetAltArrowKeyMode then kb:SetAltArrowKeyMode(false) end
  kb:SetScript("OnEscapePressed", Many.Close)
  kb:SetScript("OnEnterPressed", Many.Take)
  kb:SetScript("OnArrowPressed", Many.Key)
  kb:SetScript("OnTextChanged", Many.Typed)
  Many.kb = kb
  box:SetScript("OnMouseWheel", Many.Wheel)
  box:SetScript("OnEvent", Many.Event)
  box:SetScript("OnHide", Many.Hidden)
  -- One Escape closes it before any window (Helpers.RegisterEscPopup).
  local H = ns.Core and ns.Core.UI and ns.Core.UI.Helpers
  if H and type(H.RegisterEscPopup) == "function" then H.RegisterEscPopup(box, Many.Close) end
  Many.box = box
  if ns.Skin and ns.Skin.Refresh then pcall(ns.Skin.Refresh, box) end
  return box
end

-- kind -> the box open under its tile, at one step: 3 under the tile's
-- foot from its left edge, kept inside the bag's width, over the tile
-- where there is no room under it.
function Many.Open(kind)
  local box = Many.Build()
  if Many.Read(kind) < 2 then return end
  Many.key, Many.total, Many.free, Many.x, Many.y = kind.key, kind.n, kind.free, kind.x, kind.y
  Many.pick = 1
  local child, scroll = BV.child, BV.scroll
  local size = Th().Metrics.slotSize
  local x, wide = kind.x, child:GetWidth() or 0
  if x + Many.W > wide then x = max(0, wide - Many.W) end
  local top = scroll:GetVerticalScroll() or 0
  local under = kind.y + size + 3
  box:ClearAllPoints()
  if under + Many.H > top + (scroll:GetHeight() or 0) and kind.y - 3 - Many.H >= top then
    box:SetPoint("BOTTOMLEFT", child, "TOPLEFT", x, -(kind.y - 3))
  else
    box:SetPoint("TOPLEFT", child, "TOPLEFT", x, -under)
  end
  if GameTooltip:IsShown() then GameTooltip:Hide() end
  Many.open = true
  Many.Paint()
  box:Show()
  box:RegisterEvent("GLOBAL_MOUSE_DOWN")
  Many.kb:SetFocus()
end

-- After a list refresh while it is open: it stays only over the tile it
-- was opened on, as that tile was (the same total, the same mails a run
-- may take, the same place) and while a Shift-click would still open it.
function Many.Check()
  local main = model.sects[1]
  local kind = main and main.by[Many.key]
  if not kind or kind.n ~= Many.total or kind.free ~= Many.free or kind.x ~= Many.x or kind.y ~= Many.y
      or not Many.May(kind) then
    return Many.Close()
  end
  Many.Read(kind)
end

-- Take: the run a plain click starts (CollectTab's StartCategoryRun with
-- the item's id), for the mails of the steps chosen and no others.
function Many.Take()
  if not Many.open then return end
  local main = model.sects[1]
  local kind = main and main.by[Many.key]
  local panel, pick = BV.panel, Many.pick
  if not (kind and panel) or kind.n ~= Many.total or kind.free ~= Many.free or not Many.May(kind) then
    Many.Close()
    if panel then ns.CollectTab.RequestRefresh(panel) end
    return
  end
  Many.Read(kind)
  local queue = BV.queue
  for i = #queue, 1, -1 do queue[i] = nil end
  for i = 1, pick do queue[i] = kind.ref[Many.at[i]] end
  Many.Close()
  ns.CollectTab.StartCategoryRun(panel, "all", kind.id, queue)
end

-------------------------------------------------------------
-- 6. Clicks
-------------------------------------------------------------

-- Right-click: the list, narrowed to the mails that hold the item -- the
-- list's own search for its name, which the player sees in the box and can
-- clear; the bag is switched off for it.
function BV.ShowMails(panel, kind)
  if kind.gold then return end
  local name = BV.NameOf(kind)
  local box = panel.SearchBox
  if not (box and name and name ~= "") then return end
  local UI = ns.MailboxUI
  if not (UI and type(UI.SetOption) == "function") then return end
  UI.SetOption("bagView", false)
  GameTooltip:Hide()
  if panel.MailListScroll then panel.MailListScroll:SetVerticalScroll(0) end
  if (box:GetText() or "") == name then
    ns.CollectTab.RefreshMailList(panel)
  else
    -- The box's own change lists the mail again; where a text set from code
    -- told nobody, the bag is still up, and the list is drawn here.
    box:SetText(name)
    if BV.area and BV.area:IsShown() then ns.CollectTab.RefreshMailList(panel) end
  end
end

-- A C.O.D. mail's tile: the fan's tile take (CollectTab, Fan.TakeItem),
-- from here. The question first (ConfirmCOD), the mail found again after
-- the wait by what was clicked, the slot still holding the item clicked,
-- and then MailService's TakeAttachment, the one place a take that pays is
-- sent, which checks all of it once more.
function BV.TakeCOD(panel, kind)
  local P, M = Parts(), Mail()
  local RV, CT = P.RV, ns.CollectTab
  local index, slot, id = kind.index, kind.slot, kind.id
  -- The mail at its index is the one its line names, owing what it says:
  -- anything else (paid since, or another mail there) and nothing is asked
  -- or sent; the bag is drawn again.
  local s = kind.sect
  local _, _, sender, _, _, cod = GetInboxHeaderInfo(index)
  cod = tonumber(cod) or 0
  if cod <= 0 or cod ~= s.codAmount or sender ~= s.codFrom then return CT.RequestRefresh(panel) end
  P.ConfirmCOD(index, function(what, at)
    -- The question was asked (the mail owes) and answered: `what` is what
    -- was clicked, and `at` where that mail is now.
    if not (what and at) then return end
    index = at
    local _, now = GetInboxItem(index, slot)
    if now == nil or now ~= id then return CT.RequestRefresh(panel) end
    local record = RV.RecordFor(index)
    local before = RV.Before(index)
    M.TakeAttachment(index, slot, function(status, refused, reason, _, paid)
      RV.SayCODPaid(paid)
      if status == "busy" then return end
      if status == "closed" then
        P.StatusMailboxClosed()
        return
      end
      CT.RequestRefresh(panel)
      if status == "moved" then return end
      if status == "timeout" then
        ns.Print(L()["MSG_MAIL_TIMEOUT"])
        return
      end
      if status == "refused" or (tonumber(refused) or 0) > 0 then
        ns.Print(P.ItemRefusedMessage(reason))
        P.RefreshIdleSummary()
        return
      end
      RV.AutoDelete(panel, index, before, record)
    end, { allowCOD = true, history = record, fetch = true, clicked = what })
  end)
end

-- A click on a tile. Right: its mails. Modified left: the game's item
-- rules (Shift links, Ctrl tries on), never the plain click's take. Plain
-- left: every stack of the item as one run, at a mailbox, on a tile that
-- can be taken, while the bag is drawn from the inbox as it stands; a
-- C.O.D. tile asks first. Anywhere else a click does nothing.
function BV.TileClick(tile, button)
  local kind = tile.kind
  local panel = BV.panel
  if not (kind and panel) or kind.n <= 0 then return end
  local P = Parts()
  local RV, CT, M = P.RV, ns.CollectTab, Mail()
  if button == "RightButton" then
    if not RV.Modified() then BV.ShowMails(panel, kind) end
    return
  end
  if button ~= "LeftButton" then return end
  if RV.Modified() then
    if kind.gold then return end
    -- The game's item rules first, as its own bag buttons have it: a link
    -- into an open chat box, a try-on. Where it took the click, that is all.
    local link = BV.LinkOf(kind)
    if link and type(HandleModifiedItemClick) == "function" and HandleModifiedItemClick(link) then return end
    -- It had nowhere to put a link: the game's split gesture (Shift) on a
    -- tile in two mails or more that can be taken here asks how many, as
    -- its bags do of a stack. Anything else is nothing, as before.
    local split
    if type(IsModifiedClick) == "function" then
      split = IsModifiedClick("SPLITSTACK")
    else
      split = type(IsShiftKeyDown) == "function" and IsShiftKeyDown()
    end
    if split and BV.Many.May(kind) then BV.Many.Open(kind) end
    return
  end
  -- Nothing can be taken from another character's box or from History;
  -- the line under the list says where, and lights for a moment to say so
  -- (BV.Flash).
  if model.src ~= "inbox" or not P.MailboxOpen() then return BV.Flash(panel) end
  if kind.look ~= 0 then return end
  if CT.IsRunning() or M.IsBusy() then return end
  if not BV.Current(kind) then return CT.RequestRefresh(panel) end
  if kind.cod then return BV.TakeCOD(panel, kind) end
  if not (kind.gold or kind.id) then return end
  local queue = BV.queue
  for i = #queue, 1, -1 do queue[i] = nil end
  for i = 1, kind.mails do queue[i] = kind.ref[i] end
  CT.StartCategoryRun(panel, "all", kind.gold and "money" or kind.id, queue)
end

-------------------------------------------------------------
-- 6b. The line at the foot, lit
--
-- A plain click on a tile where nothing can be taken (another character's
-- box, History) takes nothing, and the line already under the list that
-- says where to collect it ("Seen 2 hours ago. Log in on Charge to collect
-- it.") answers: the buttons' pointer wash across its slot and its words
-- white, in at once (0.10 s), held (0.60 s), eased out (0.40 s). No new
-- words, no chat line, no sound.
--
-- The wash's fade is the client's own animation on the one texture; the
-- words are set as it starts and put back by ONE C_Timer.After of the
-- flash's length, told from an older one by two counts (timers of one
-- length fire in the order they were set), so a second click starts the
-- flash again and only the last timer ends it. Hidden mid-flash (the tab,
-- the window, the mailbox), it ends there: the words as they were, the
-- animation stopped. Nothing runs between flashes.
-------------------------------------------------------------
BV.FLASH_IN, BV.FLASH_HOLD, BV.FLASH_OUT = 0.10, 0.60, 0.40
BV.FLASH_H, BV.FLASH_A = 28, 0.10
BV.flashArmed, BV.flashFired = 0, 0

-- panel -> the note standing in All mail's place, if one is.
function BV.Note(panel)
  local note = panel.AltNote
  if note and note:IsShown() then return note end
  note = panel.HistoryNote
  if note and note:IsShown() then return note end
  return nil
end

-- The flash is over: the words in their own ink again, the wash away.
function BV.FlashEnd()
  local note = BV.flashNote
  if not note then return end
  BV.flashNote = nil
  Th().SetColor(note, "textSecondary", "window")
  local wash = BV.wash
  if wash then
    if wash.Fade then wash.Fade:Stop() end
    if wash:IsShown() then wash:Hide() end
  end
end

function BV.FlashDue()
  BV.flashFired = BV.flashFired + 1
  if BV.flashFired == BV.flashArmed then BV.FlashEnd() end
end

function BV.Flash(panel)
  local note = BV.Note(panel)
  if not (note and panel.Footer) then return end
  local T = Th()
  local wash = BV.wash
  if not wash then
    wash = CreateFrame("Frame", nil, panel.Footer)
    wash:EnableMouse(false)
    wash.Tex = wash:CreateTexture(nil, "BACKGROUND")
    wash.Tex:SetAllPoints()
    wash.Tex:SetColorTexture(1, 1, 1, BV.FLASH_A)
    if type(wash.Tex.CreateAnimationGroup) == "function" then
      local fade = wash.Tex:CreateAnimationGroup()
      local up = fade:CreateAnimation("Alpha")
      up:SetFromAlpha(0)
      up:SetToAlpha(1)
      up:SetDuration(BV.FLASH_IN)
      up:SetOrder(1)
      local down = fade:CreateAnimation("Alpha")
      down:SetFromAlpha(1)
      down:SetToAlpha(0)
      down:SetStartDelay(BV.FLASH_HOLD)
      down:SetDuration(BV.FLASH_OUT)
      down:SetSmoothing("OUT")
      down:SetOrder(2)
      if fade.SetToFinalAlpha then fade:SetToFinalAlpha(true) end
      wash.Fade = fade
    end
    wash:SetScript("OnHide", BV.FlashEnd)
    wash:Hide()
    BV.wash = wash
  end
  -- Another note was lit (History's, then a box's): that one first.
  if BV.flashNote and BV.flashNote ~= note then BV.FlashEnd() end
  BV.flashNote = note
  -- The note's slot, wherever the stack has put it (RV.PlaceStack: the
  -- note stands in the middle of All mail's slot, inset from the footer's
  -- sides, and the band may sit above or below it): the footer's width, a
  -- button tall, about the note itself. Anchored to the note on every
  -- flash, never to the footer's middle, which is the slot's only while
  -- the slot is the whole footer.
  local inset, half = T.Metrics.inset, BV.FLASH_H / 2
  wash:ClearAllPoints()
  wash:SetPoint("TOPLEFT", note, "LEFT", -inset, half)
  wash:SetPoint("BOTTOMRIGHT", note, "RIGHT", inset, -half)
  T.SetColor(note, "textPrimary", "window")
  wash:Show()
  if wash.Fade then
    wash.Fade:Stop()
    wash.Fade:Play()
  end
  BV.flashArmed = BV.flashArmed + 1
  C_Timer.After(BV.FLASH_IN + BV.FLASH_HOLD + BV.FLASH_OUT, BV.FlashDue)
end
