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
-- tiles keep their color and a click takes nothing: a lock shows on the
-- tile and the line under the list lights (BV.NoTake), as on a mail row of
-- the list there.
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
BV.GLYPH = "pouch"

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

-- Whether the button is offered at all (profile.bagButton, Options > Mail
-- tab; unset is on). Off, nothing of the bag is built or drawn.
function BV.Offered()
  local UI = ns.MailboxUI
  return UI ~= nil and type(UI.GetOption) == "function" and UI.GetOption("bagButton") == true
end

-- Whether the player chose the bag (profile.bagView, MailboxUI's
-- OPTION_DEFAULTS; unset is off), where the button is offered. The choice
-- is kept while it is not, for when it is again.
function BV.On()
  local UI = ns.MailboxUI
  return BV.Offered() and UI.GetOption("bagView") == true
end

-- panel -> whether the list on screen has no bag to show: the Done tab, and
-- the list the arrange mode arranges or the sample mail stands in (the
-- options' preview), where the list is what shows whatever was chosen. The
-- switch is gray there, its click and right-click do nothing, and it is
-- never lit over a list.
function BV.Gray(panel)
  local P = Parts()
  if not P then return false end
  if panel._bagYield or panel._preview or P.RV.Arranging(panel) then return true end
  return panel.viewMode == P.VIEW_DONE and not P.AV.Active(panel)
end

-- panel -> whether a tile's mails are on screen (BV.ShowMails): for this
-- visit only, the list in the bag's place, searched for the tile's item,
-- while the saved choice stays the bag. `_bagPeek` is the view it was asked
-- on and `_bagPeekAlt` the box. It holds while the search box has words in
-- it, on that list, whatever the words are now; it ends, and the bag is
-- back, once the box is emptied (its x, Escape, the words deleted, the
-- mailbox closing), the view changes (History, Done, another character) or
-- the bag's own button is clicked. Never saved. A comparison and a find, no
-- garbage. The letters' line's click (BV.ShowLetters) sets no search, so
-- its look (`_bagPeekAll`) holds whatever the box says, and ends by the
-- rest of the same rule: the view or the box changing, the mailbox
-- closing, the bag's button.
function BV.Peek(panel)
  local view = panel._bagPeek
  if view == nil then return false end
  if view == panel.viewMode and panel._alt == panel._bagPeekAlt then
    if panel._bagPeekAll then return true end
    local box = panel.SearchBox
    local text = box and box:GetText()
    if type(text) == "string" and text:find("%S") then return true end
  end
  panel._bagPeek, panel._bagPeekAlt, panel._bagPeekAll = nil, nil, nil
  return false
end

-- panel -> whether the bag is what is drawn: chosen, and the list on screen
-- one it can draw (BV.Gray), and not a tile's mails (BV.Peek).
function BV.Active(panel)
  if not BV.On() then return false end
  if BV.Peek(panel) then return false end
  local P = Parts()
  if not P then return false end
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
  -- The words in one ink belong to the line that set them (TallyRemembered).
  s.plain = nil
  -- The line for the letters with nothing attached (BV.TallyLetters).
  s.letters = false
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
-- an ITEM of it (the key is the item, as in the main section): its stacks
-- of that item counted together, the slot its first stack is in kept for
-- the tooltip and the checks, so the price is shown once and one click
-- asks once (BV.TakeCOD). The line's words are made again only when the
-- price or the sender of that place changed.
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
      local kind = Kind(s, id or name or tex)
      if kind then
        if kind.stacks == 0 then
          kind.id, kind.name, kind.tex, kind.index, kind.slot = id, name, tex, index, slot
          kind.cod, kind.live = true, true
        end
        Put(kind, tonumber(count) or 1, index, held == nil, held)
      end
      if found >= itemCount then break end
    end
  end
end

-- money, cod, itemCount, wasRead (a mail's header, as numbers) -> whether
-- it is a letter the letters' line counts: nothing attached, no gold, no
-- C.O.D., and not finished, so unread (a read letter with nothing in it is
-- the list's Done, and the bag leaves it out as it leaves all of those).
-- The one test for the line's count (BV.TallyInbox) and its click
-- (BV.OneLetter).
function BV.IsLetter(money, cod, itemCount, wasRead)
  return money <= 0 and cod <= 0 and itemCount <= 0 and not wasRead
end

-- The inbox's list as it is drawn (panel._filtered: the search, the sort
-- and the filters have shaped it): the gold and every stack of the mail
-- still to collect, a kind an item id. Mail a sweep leaves -- stuck, or
-- waiting for bag room -- is counted and not `free`. Held in place
-- (`frozen`), only the first section's counts are read again. Answers how
-- many unread letters with nothing attached the list holds (no tile, so
-- BV.TallyLetters gives them a line).
function BV.TallyInbox(panel, frozen)
  local P, M = Parts(), Mail()
  local filtered, done = panel._filtered, panel._filteredDone
  local main = model.sects[1]
  local slots = M.MAX_ATTACHMENTS or 16
  local divider = P.DIVIDER
  local letters = 0
  for i = 1, #filtered do
    local index = filtered[i]
    if index ~= divider and not done[i] then
      local _, _, sender, _, money, cod, _, itemCount, wasRead = GetInboxHeaderInfo(index)
      money, cod, itemCount = tonumber(money) or 0, tonumber(cod) or 0, tonumber(itemCount) or 0
      local held = itemCount > 0 and M.HeldBack(index, itemCount) or nil
      if BV.IsLetter(money, cod, itemCount, wasRead) then letters = letters + 1 end
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
  return letters
end

-- n -> the letters' line: unread letters with nothing attached have no
-- tile, so where the list holds any they are said once, a line of their
-- own after the listed mail's tiles (before the mail not listed yet), a
-- section with no tiles as the remembered mail's line is. Its words are
-- made again only when the count changes.
function BV.TallyLetters(n)
  if (n or 0) <= 0 then return end
  if BV.lettersN ~= n then BV.lettersN, BV.lettersText = n, ns.Plural("BAG_LETTERS", n) end
  local s = Sect(BV.lettersText, 0)
  s.letters = true
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
  -- Held in place while a run goes, and while a tile's mails go back
  -- (section 7: the return sweep).
  local frozen = src == "inbox" and m.src == "inbox" and m.sn > 0
    and (ns.CollectTab.IsRunning() or BV.Alt.running)
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
  -- C.O.D. mail's tiles, which a run's builds leave as they were. The
  -- inbox's kinds are read from the list as it was last built, so they
  -- carry the mark that list was built at, as its rows do (RV.Acting): a
  -- bag drawn again before a queued refresh is not current.
  if src == "inbox" then m.gen = panel._bindGen else m.gen = Mail().InboxGen() end
  if not frozen then m.wholeGen = m.gen end
  if src == "inbox" then
    local letters = BV.TallyInbox(panel, frozen)
    if not frozen then
      BV.TallyLetters(letters)
      BV.TallyRemembered(panel)
    end
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
    s.shown = s.head ~= nil and (s.n > 0 or s.rem or s.letters)
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
  tile:SetScript("OnClick", ns.Guard(BV.TileClick))
  -- What was under the pointer at the press, for a return's click (7).
  tile:SetScript("OnMouseDown", BV.Alt.Down)
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

-- The letters' line's look (his f77 B02 pick, "glyph"): a 12-unit envelope
-- (Theme.GLYPHS envelope-12), LET_GAP before the words, the two centred
-- together on the line. Its top LET_TOP under the line's top: the words'
-- box is centred 1 under the line's middle (11 of 20), and their x-height's
-- centre stands 1.25 under that in Friz Quadrata at 12 (0.87 to 1.44 over
-- the faces and sizes measured), so at 12.25; the envelope's ink centre is
-- 5.87 under its top, so its top on 6 puts it at 11.87, the nearest whole
-- unit (a whole screen pixel at one pixel a unit).
BV.LET_GLYPH, BV.LET_GAP, BV.LET_TOP = 12, 6, 6

-- The letters' line (BV.TallyLetters): a frame of its own, as the
-- remembered mail's is, since it alone hears a click (BV.HeadPointer); its
-- envelope and its light under the pointer made with it, once.
function BV.LettersHead()
  local head = BV.lettersHead
  if not head then
    local T = Th()
    head = BV.NewHead()
    head.Wash = head:CreateTexture(nil, "BACKGROUND")
    head.Wash:SetPoint("TOPLEFT", head, "TOPLEFT", 0, -1)
    head.Wash:SetPoint("BOTTOMRIGHT", head, "BOTTOMRIGHT", 0, 0)
    T.FillColor(head.Wash, "stripeHover")
    head.Wash:Hide()
    head.Env = T.Glyph and T.Glyph(head, "envelope-12", nil, "ARTWORK") or nil
    head.Text:SetJustifyH("LEFT")
    head.hot = false
    head:SetScript("OnHide", BV.LettersHidden)
    BV.lettersHead = head
  end
  return head
end

-- Hidden (the bag gone, the line scrolled away, no letters): at rest when
-- it comes back.
function BV.LettersHidden(head)
  if head.hot then
    head.hot = false
    BV.LettersInk(head)
  end
end

-- head, text -> the letters' line drawn. Its look, all of it, is here,
-- apart from what is counted: the section's line (BV.HeadLook) with the
-- room for the envelope kept, the envelope and the words centred together
-- (placed again only when the words or the width change), then its inks.
function BV.LettersLook(head, text)
  local env = head.Env
  local lead = env and (BV.LET_GLYPH + BV.LET_GAP) or 0
  local T = Th()
  if BV.HeadLook(head, text, nil, lead) or head.letLead ~= lead then
    head.letLead = lead
    local width = head.pbWidth or 0
    local x0 = floor((width - (lead + T.TextWidth(head.Text))) / 2 + 0.5)
    if x0 < 0 then x0 = 0 end
    head.Text:ClearAllPoints()
    head.Text:SetPoint("LEFT", head, "LEFT", x0 + lead, -1)
    if env then
      env:ClearAllPoints()
      env:SetPoint("TOPLEFT", head, "TOPLEFT", x0, -BV.LET_TOP)
    end
  end
  BV.LettersInk(head)
end

-- The letters' line's inks: at rest the words and the envelope in the
-- secondary gray, quieter than the tiles (on the Blizzard look's ground,
-- the ground's own ink, which its words are given at each bind); under the
-- pointer both white and the line lit with the list rows' hover wash (on
-- that ground the wash stands under the note, and the white words are its
-- light). Asked at every bind and on enter and leave; nothing is made.
function BV.LettersInk(head)
  local T = Th()
  local text, env, hot = head.Text, head.Env, head.hot
  if hot then
    T.SetColor(text, "textPrimary")
    if env then T.SetColor(env, "textPrimary") end
  elseif head.grounded then
    if env then env:SetVertexColor(text:GetTextColor()) end
  else
    T.SetColor(text, "textSecondary")
    if env then T.SetColor(env, "textSecondary") end
  end
  if head.Wash:IsShown() ~= hot then head.Wash:SetShown(hot) end
end

-- head, text, plain [, lead] -> a section's line drawn: on the look's
-- ground for a line of words where it has one (the Blizzard look's
-- gold-edged note, Theme.LineGround, on its page): the words in the
-- ground's one ink (`plain`, where the words carry inks of their own), a
-- C.O.D. line's price still in its own, and the hairline the ground's.
-- Asked for every line at every bind, so a line follows Row texture to None
-- and back. `lead`: room kept before the words (the letters' envelope).
-- Answers whether the words were fitted again.
function BV.HeadLook(head, text, plain, lead)
  local T = Th()
  local grounded = T.LineGround and T.LineGround(head) or false
  if head.grounded ~= grounded then
    if not grounded and head.grounded ~= nil then T.ApplyTextRole(head.Text, "value") end
    head.grounded = grounded
    head.Rule:SetShown(not grounded)
  end
  if grounded and plain then text = plain end
  local width = BV.child:GetWidth() or 0
  if head.pbText ~= text or head.pbWidth ~= width then
    head.pbText, head.pbWidth = text, width
    T.FitText(head.Text, width - 2 * T.Metrics.inset - (lead or 0), text, nil)
    return true
  end
  return false
end

-- head, s, every -> whether the line hears a click, and what it does: the
-- letters' line opens its one letter or shows the list (BV.LettersClick);
-- a character's heading among every box's matches (`every`, BV.EveryBox) shows that box, as the
-- list's heading does (BV.GoBox). Every other line takes no pointer. A
-- line that hears one passes every press on, so the window is dragged by
-- it as by the ground under it, and only a press that did not move is its
-- click.
function BV.HeadPointer(head, s, every)
  local go = nil
  if s.letters then
    go = "letters"
  elseif every and s.name then
    go = "box"
  end
  head.go, head.realm, head.name = go, s.realm, s.name
  local on = go ~= nil
  if head.pbMouse ~= on then
    head.pbMouse = on
    head:EnableMouse(on)
    if not on and GameTooltip:IsOwned(head) then GameTooltip:Hide() end
  end
end

function BV.HeadDown(head, button)
  if button ~= "LeftButton" then return end
  BV.downHead = head
  BV.downX, BV.downY = GetCursorPosition()
end

function BV.HeadUp(head, button)
  local down = BV.downHead
  BV.downHead = nil
  if button ~= "LeftButton" or down ~= head or not head.go then return end
  local x, y = GetCursorPosition()
  if math.abs((x or 0) - (BV.downX or 0)) > 4 or math.abs((y or 0) - (BV.downY or 0)) > 4 then return end
  local P, panel = Parts(), BV.panel
  if not (P and panel) or P.RV.Modified() then return end
  if head.go == "letters" then
    BV.LettersClick(panel)
  else
    BV.GoBox(panel, head.realm, head.name)
  end
end

-- A character's heading: whose matches these are and what its click does,
-- as the list's heading says it (nothing on it looks like a button). The
-- letters' line has no tooltip (his f72 B02 pick; f82 T03 kept it so): it
-- lights under the pointer, and leaves any tooltip that is up alone.
function BV.HeadEnter(head)
  if head.go == "letters" then
    head.hot = true
    BV.LettersInk(head)
    return
  end
  if head.go ~= "box" then return end
  local T, Memory = Th(), ns.MailMemory
  T.TipBegin(head)
  local name = head.name
  if Memory and type(Memory.ClassName) == "function" then name = Memory.ClassName(head.realm, head.name, nil, "tooltip") end
  T.TipTitle(name)
  T.TipHint(L()["MEMORY_HEADER_TIP"])
  GameTooltip:Show()
end

function BV.HeadLeave(head)
  if head.hot then
    head.hot = false
    BV.LettersInk(head)
  end
  if GameTooltip:IsOwned(head) then GameTooltip:Hide() end
end

function BV.NewHead()
  local T = Th()
  local head = CreateFrame("Frame", nil, BV.child)
  head:SetHeight(BV.HEAD)
  head:EnableMouse(false)
  head.pbMouse = false
  -- Heard only while BV.HeadPointer gives it the pointer; a press passes
  -- on to what is under it.
  if head.SetPropagateMouseClicks then head:SetPropagateMouseClicks(true) end
  head:SetScript("OnMouseDown", BV.HeadDown)
  head:SetScript("OnMouseUp", BV.HeadUp)
  head:SetScript("OnEnter", BV.HeadEnter)
  head:SetScript("OnLeave", BV.HeadLeave)
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
  local used, lines, remUp, letUp = 0, 0, false, false
  -- Whether a character's heading goes to that box (a search of every box).
  local every = m.src == "away" and BV.EveryBox(BV.panel)
  for si = 1, m.sn do
    local s = m.sects[si]
    if s.shown and s.y >= offset - BV.HEAD and s.y <= bottom then
      local head = nil
      if s.rem then
        head, remUp = BV.RemHead(), true
      elseif s.letters then
        head, letUp = BV.LettersHead(), true
      else
        lines = lines + 1
        head = BV.Head(lines)
      end
      head:ClearAllPoints()
      head:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -s.y)
      head:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -s.y)
      if s.letters then
        BV.LettersLook(head, s.head)
      else
        BV.HeadLook(head, s.head, s.plain)
      end
      if not s.rem then BV.HeadPointer(head, s, every) end
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
        -- Its Return mark while the Alt marks show, or put away (7).
        if tile.AltMark or BV.Alt.Live() then BV.Alt.PaintTile(tile) end
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
  if BV.lettersHead and not letUp then BV.lettersHead:Hide() end
  Th().TipFollow(child)
  -- A tile that was answered (BV.NoTake) and is bound to something else.
  if BV.NT.on then BV.NoTakeCheck() end
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
  local listEmpty = none and panel.Empty and panel.Empty:IsShown() or false
  if none then
    area.Empty:SetText(listEmpty and (panel.Empty:GetText() or "") or L()["BAG_EMPTY"])
  end
  area.Empty:SetShown(none)
  BV.LendClear(panel, listEmpty)
end

-- The list's Clear filter (panel.EmptyClear, shown by RV.PaintEmptyClear
-- while a filter leaves nothing) stands under the list's words in the
-- list's own frame, which is hidden while the bag is up. While the bag
-- says the list's words it is lent to the bag, under them, and given back
-- as the bag goes: one button, one click (RV.ClearFilter).
function BV.LendClear(panel, lend)
  local clear, area = panel.EmptyClear, BV.area
  if not (clear and area and panel.Empty) then return end
  local owner = lend and area or panel.MailListArea
  if clear:GetParent() == owner then return end
  local gap = Th().Metrics.gap
  if lend then
    clear._homeLevel = clear._homeLevel or clear:GetFrameLevel()
    clear:SetParent(area)
    clear:ClearAllPoints()
    clear:SetPoint("TOPLEFT", area.Empty, "BOTTOMLEFT", 0, -gap)
    clear:SetFrameLevel(BV.scroll:GetFrameLevel() + 10)
  else
    clear:SetParent(owner)
    clear:ClearAllPoints()
    clear:SetPoint("TOPLEFT", panel.Empty, "BOTTOMLEFT", 0, -gap)
    if clear._homeLevel then clear:SetFrameLevel(clear._homeLevel) end
  end
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
  -- The list was bound again, or the view changed: an answer on a row or a
  -- note no longer there ends (BV.NoTake).
  if BV.NT.on then BV.NoTakeCheck() end
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
    -- A question to return a tile's mails goes with the bag, unanswered.
    if BV.Alt.open then BV.Alt.Hide() end
    if area then BV.LendClear(panel, false) end
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
    -- What the bag last drew is not held in place as it comes up, even
    -- during a run: the mail may have changed while it was away, so it is
    -- tallied anew from the list (BV.Build holds only a bag left up).
    model.sn = 0
    local RV = Parts().RV
    RV.FanClose(true)
    -- Alt's marks go on in the bag on this character's own Inbox at a
    -- mailbox, held or kept on (RV.Marks is eligible while the list or
    -- the bag in its place shows): a tile's click then asks, and returns
    -- the mails it named (section 7). Anywhere the marks are not eligible
    -- (another box, History) they end here.
    if RV.Marks and RV.Marks.Sync then RV.Marks.Sync(panel) end
  end
  if not BV.Build(panel) then BV.Layout() end
  BV.Apply(panel)
  if BV.Many.open then BV.Many.Check() end
  -- A question to return a tile's mails stands only while they show (7).
  if BV.Alt.open then
    local M = BV.Alt.M()
    BV.Alt.Watch(M ~= nil and M.Eligible(panel))
  end
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

-- Lit while the bag is on; gray where the list on screen has none to show;
-- unlit while a tile's mails are the list on screen (BV.Peek).
function BV.PaintSwitch(panel)
  local cell = panel.BagSwitch
  if not cell then return end
  local gray = BV.Gray(panel)
  local on = BV.On() and not gray and not BV.Peek(panel)
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
-- Rows picked with Shift or Ctrl are let go as the bag comes up: it shows
-- every mail listed, so picks it cannot show would still steer All mail.
function BV.Set(panel, on)
  local UI = ns.MailboxUI
  if not (UI and type(UI.SetOption) == "function") then return end
  local P = Parts()
  if on and P and P.ClearSelection then P.ClearSelection(panel) end
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
-- click itself; while the list is up it does nothing. While a tile's mails
-- are up (BV.Peek) a click is the way back to the bag, the search the
-- right-click set cleared; the saved choice never changed.
function BV.SwitchClick(cell, button)
  if cell._gray then return end
  if button == "RightButton" and not cell.isSelected then return end
  local panel = cell._panel
  if BV.Peek(panel) then
    BV.Back(panel)
  else
    BV.Set(panel, not BV.On())
  end
  if GameTooltip:IsOwned(cell) then BV.SwitchTip(cell) end
end

-- A tile's mails let go: the search emptied, the bag drawn again. The
-- letters' look set no search, and leaves the box as the player left it.
function BV.Back(panel)
  local all = panel._bagPeekAll
  panel._bagPeek, panel._bagPeekAlt, panel._bagPeekAll = nil, nil, nil
  local box = panel.SearchBox
  -- The box's own change lists the mail again; where a text set from code
  -- told nobody, the list is drawn here.
  if not all and box and (box:GetText() or "") ~= "" then box:SetText("") end
  if not (BV.area and BV.area:IsShown()) then ns.CollectTab.RefreshMailList(panel) end
end

-- The switch, built with the find plate (CollectTab's BuildSearchBox) where
-- it is offered (BV.Offered): a square plate the segments' height, joined
-- to the search as its last cell after the sort, which moves one cell in
-- (Theme.JoinCell; the search ends before both, Theme's search.endExtra,
-- and RV.SortRoom counts both).
function BV.BuildSwitch(panel)
  BV.PlaceSwitch(panel)
end

-- The switch in the row or out of it, as the option says; asked by the
-- row's layout (CollectTab's LayoutViewToggle) before it measures the find
-- plate, so a change of the option or a reset finds it laid out. Out, the
-- cell is hidden and kept (panel._bagCell), `panel.BagSwitch` is nil, and
-- the sort and the search stand exactly as they did before the switch
-- existed: the sort the wrap's last cell at its right end, the search's
-- end before the sort alone. Changes only when the option does.
function BV.PlaceSwitch(panel)
  local P, T = Parts(), Th()
  local wrap, search, sort = panel.SearchWrap, panel.Search, panel.Sort
  if not (P and wrap and search and sort) then return end
  local offered = BV.Offered()
  if offered == (panel.BagSwitch ~= nil) then return end
  local size = T.Metrics.segmentHeight
  local cell = panel.BagSwitch or panel._bagCell
  local inset = 0
  if offered then
    if cell then
      cell:Show()
    else
      cell = T.CreatePlate(panel, "segment")
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
      cell:SetScript("OnClick", ns.Guard(BV.SwitchClick))
      cell:HookScript("OnEnter", BV.SwitchEnter)
      cell:HookScript("OnLeave", BV.SwitchLeave)
      T.JoinCell(wrap, cell)
      T.SetPlateSelected(cell, false)
    end
    panel.BagSwitch, panel._bagCell = cell, nil
    inset = -(size - 1)
    search.endExtra = size - 1
  else
    cell:Hide()
    if GameTooltip:IsOwned(cell) then GameTooltip:Hide() end
    panel.BagSwitch, panel._bagCell = nil, cell
    search.endExtra = nil
    -- What belonged to the bag ends with it.
    panel._bagPeek, panel._bagPeekAlt, panel._bagPeekAll = nil, nil, nil
    if BV.Many.open then BV.Many.Close() end
  end
  sort:ClearAllPoints()
  sort:SetPoint("TOPRIGHT", wrap, "TOPRIGHT", inset, 0)
  sort:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", inset, 0)
  search.SetJoined(panel._sortPlaced ~= false)
  panel._searchW = nil
  P.RV.SizeSearch(panel, panel._searchGiven or 0)
  if offered then BV.PaintSwitch(panel) end
end

-- The option changed (Options > Mail tab): the row laid out again, with the
-- switch in it or not (CT.UpdateTabCounts lays the row out, and the
-- window's floor follows it), and the list drawn for it: the bag, where it
-- was chosen and is offered again, or the list.
function BV.OfferChanged()
  local UI, CT = ns.MailboxUI, ns.CollectTab
  local panel = UI and UI._frame and UI._frame.Tabs and UI._frame.Tabs.collect
  if not (panel and CT) then return end
  if type(CT.UpdateTabCounts) == "function" then CT.UpdateTabCounts(panel) end
  if type(CT.RequestRefresh) == "function" then CT.RequestRefresh(panel) end
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
  if not name and kind.id then
    -- The searches' own cache of names: where the client has not loaded
    -- the item, it is asked for, and BV.NamesArrived hears it come.
    local H = ns.Helpers
    if H and type(H.SearchItemName) == "function" then
      name = H.SearchItemName(kind.id)
    elseif C_Item and type(C_Item.GetItemInfo) == "function" then
      name = C_Item.GetItemInfo(kind.id)
    end
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
  local link = kind.link
  if index and type(GameTooltip.SetInboxItem) == "function" then
    GameTooltip:SetInboxItem(index, slot)
  elseif type(link) == "string" and link:find("battlepet:", 1, true) then
    -- A caged pet's link is not an item's, and the game's tooltip is not
    -- handed it: the pet's name stands as the title (BV.NameOf reads it
    -- from the link).
    Th().TipTitle(BV.NameOf(kind) or RETRIEVING_ITEM_INFO or "?")
  elseif type(link) == "string" then
    GameTooltip:SetHyperlink(link)
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
  -- A tally's row (Mail Memory, s33 tiles) names no mail: its count is in
  -- the line above (BV.MailsOf).
  if type(where) == "table" and where.tally then return end
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
  -- A person whole, in their class colour, as every tooltip writes one
  -- (CollectTab's RV.TipSender; the box's realm where the tile has one).
  if type(who) ~= "string" or who == "" then
    who = L()["SENDER_UNKNOWN"]
  else
    who = P.RV.TipSender(who, kind.sect and kind.sect.realm)
  end
  -- Gold exact, as the title says it: this line is the one place each
  -- mail's share is given.
  local right = kind.gold and H.FormatMoney(count) or tostring(count)
  if age then
    right = right .. P.RV.SLOT_DOT .. age
  elseif days and days > 0 then
    local _, short = P.ExpiryState(days, false)
    local left = H.TimeLeft(days)
    right = right .. P.RV.SLOT_DOT .. (short and T.TipTone("warning", left) or left)
  end
  local m = T.TIP_MUTED
  GameTooltip:AddDoubleLine(who, right, m, m, m, 1, 1, 1)
end

-- kind -> how many mails it is in: one a mail, and a tally's row (Mail
-- Memory, s33 tiles) its mails.
function BV.MailsOf(kind)
  local sum = 0
  for i = 1, kind.mails do
    local where = kind.ref[i]
    sum = sum + ((type(where) == "table" and where.tally and where.mails) or 1)
  end
  return sum
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
      if index and kind.stacks > 1 and kind.look ~= 1 then
        -- Its stacks in the mail are one take: all of them, as a tile's.
        T.TipHint(L0("BAG_HINT_TAKE", kind.n))
        T.TipHint(linkHint)
      elseif index then
        T.TipHint(RV.TileHint(index, slot, kind.look == 1))
      end
    elseif kind.gold then
      T.TipHint(L0["FAN_GOLD_HINT"])
    else
      if kind.free > 0 then T.TipHint(L0("BAG_HINT_TAKE", kind.freeN)) end
      T.TipHint(mailsHint)
      -- In two mails or more a Shift-click with no chat box open asks how
      -- many (BV.Many), and links with one open: one line says both, and
      -- the try-on has a line of its own.
      if BV.Many.Steps(kind) >= 2 then
        T.TipHint(L0["BAG_HINT_MANY"])
        if dress then T.TipHint(L0["BAG_HINT_TRY_ON"]) end
      else
        T.TipHint(linkHint)
      end
    end
  elseif src == "away" then
    local Memory = ns.MailMemory
    local who = BV.who
    local info = BV.panel and BV.panel._avInfo
    who.boxRealm, who.boxName = s.realm or (info and info.realm), s.name or (info and info.name)
    -- A search of every box: the click goes to the character's box, said in
    -- the list's heading's words; where to collect stays after it, but for
    -- this character at a mailbox, where the click itself lands.
    local every = s.name ~= nil and BV.EveryBox(BV.panel)
    if every then T.TipHint(L0["MEMORY_HEADER_TIP"]) end
    local here = every and BV.Mine(who.boxRealm, who.boxName) and P.MailboxOpen()
    if not here and Memory and type(Memory.TakeHint) == "function" then T.TipHint(Memory.TakeHint(who)) end
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
  -- While the Alt marks show in the bag (section 7), what a click returns.
  local alt = BV.Alt.Live() and src == "inbox" and kind.sect.look ~= 2
  if alt then BV.Alt.Ink(tile, true) end
  T.TipBegin(tile)
  if kind.gold then
    T.TipTitle(L0["LABEL_GOLD"] .. H.FormatMoney(kind.n))
    local mails = BV.MailsOf(kind)
    if mails > 1 then T.TipLine(ns.Plural("COUNT_MAILS", mails)) end
    -- The gold tile does nothing while the marks show: no hint.
    if alt then return GameTooltip:Show() end
  else
    BV.TipItem(kind)
    if kind.cod and not alt then
      local _, _, _, _, _, cod = GetInboxHeaderInfo(kind.index)
      if (tonumber(cod) or 0) > 0 and BV.Current(kind) then
        T.TipFact(L0["LABEL_COD"], T.TipTone("negative", H.FormatMoney(tonumber(cod))))
      end
    elseif not alt then
      T.TipLine(L0("BAG_IN_MAILS", tostring(kind.n), ns.Plural("COUNT_MAILS", BV.MailsOf(kind))))
    end
  end
  if alt then
    BV.Alt.TipBody(kind)
    return GameTooltip:Show()
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

function BV.TileLeave(tile)
  if tile and tile.AltMark then BV.Alt.Ink(tile, false) end
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
-- While it is open, out of combat, it hears the keyboard and keeps only
-- its own keys, the arrows, Enter and Escape; every other key reaches the
-- game, so the player can still walk. Shut, it hears nothing; in combat it
-- is the mouse's alone (and combat starting closes it). Made the first time it
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

-- The keys the box answers while it is open; every other key, and these
-- with Ctrl or Alt held (a keybind's chord), reach the game untouched.
Many.KEYS = { LEFT = -1, DOWN = -1, RIGHT = 1, UP = 1, ENTER = "take", NUMPADENTER = "take", ESCAPE = "close" }

-- Keys pass again. In combat propagation cannot be set (10.1.5 on, and on
-- Forever), and the frame hides instead: a hidden frame takes no keys.
function Many.Pass(key)
  if key:GetPropagateKeyboardInput() then return end
  if InCombatLockdown() then
    key:Hide()
  else
    key:SetPropagateKeyboardInput(true)
  end
end

-- A key the box answers is kept from the game for that one press; an arrow
-- steps at once, and Enter or Escape is answered the next frame, once keys
-- pass again (Many.KeyAnswer), since closing the box in the press itself
-- would let the press through.
function Many.KeyDown(key, pressed)
  if InCombatLockdown() then
    key:Hide()
    return
  end
  local act = Many.open and Many.KEYS[pressed] or nil
  if act and (IsControlKeyDown() or IsAltKeyDown()) then act = nil end
  if not act then
    if not key:GetPropagateKeyboardInput() then key:SetPropagateKeyboardInput(true) end
    return
  end
  if key:GetPropagateKeyboardInput() then key:SetPropagateKeyboardInput(false) end
  if act == -1 or act == 1 then
    Many.Step(act)
  elseif not key.pending then
    key.pending = act
    key:SetScript("OnUpdate", Many.KeyAnswer)
  end
end

-- The frame after Enter or Escape was kept: keys pass, then it is answered.
function Many.KeyAnswer(key)
  key:SetScript("OnUpdate", nil)
  local act = key.pending
  key.pending = nil
  Many.Pass(key)
  if act == "take" then Many.Take() else Many.Close() end
end

-- Hidden with the box (or for a fight): a press not yet answered is let go
-- with it, and keys pass.
function Many.KeyHidden(key)
  key:SetScript("OnUpdate", nil)
  key.pending = nil
  Many.Pass(key)
end

-- The keyboard frame given the keys once, out of combat, propagation on
-- before it is ever shown. Answers whether it hears keys: never in combat,
-- where neither may be set, and never on a client without these.
function Many.Arm(key)
  if key.armed then return true end
  if InCombatLockdown() or type(key.EnableKeyboard) ~= "function"
      or type(key.SetPropagateKeyboardInput) ~= "function" or type(key.GetPropagateKeyboardInput) ~= "function" then
    return false
  end
  key:SetPropagateKeyboardInput(true)
  key:EnableKeyboard(true)
  key:SetScript("OnKeyDown", Many.KeyDown)
  key:SetScript("OnKeyUp", Many.Pass)
  key:SetScript("OnShow", Many.Pass)
  key:SetScript("OnHide", Many.KeyHidden)
  key.armed = true
  return true
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
  box:UnregisterEvent("PLAYER_REGEN_DISABLED")
  -- Hidden with the bag or the window: shut for good, so it is not there
  -- again when they are next shown.
  if box:IsShown() then box:Hide() end
end

-- A press anywhere but on it closes it, and so does combat starting: the
-- keyboard is the game's again for the fight.
function Many.Event(box, event)
  if not Many.open then return end
  if event == "PLAYER_REGEN_DISABLED" or (event == "GLOBAL_MOUSE_DOWN" and not box:IsMouseOver()) then Many.Close() end
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
  take:SetScript("OnClick", ns.Guard(Many.Take))
  Many.TakeButton = take
  Many.Sub = T.CreateText(box, "secondary")
  Many.Sub:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -33)
  Many.Sub:SetPoint("RIGHT", box, "RIGHT", -6, 0)
  Many.Sub:SetJustifyH("LEFT")
  Many.Sub:SetWordWrap(false)
  -- The keys, while the box is open: a frame of its own, with no art, that
  -- hears every key and keeps only the box's (Many.KEYS), so W A S D, jump
  -- and every keybind reach the game as if the box were not there. A child
  -- of the box, so it is shown and hidden with it; given the keys out of
  -- combat only (Many.Arm, Many.Open).
  local key = CreateFrame("Frame", nil, box)
  key:SetAllPoints(box)
  key:EnableMouse(false)
  key:Hide()
  Many.keys = key
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
  box:RegisterEvent("PLAYER_REGEN_DISABLED")
  -- The keys, out of combat: in combat the box is the mouse's alone.
  local key = Many.keys
  if not InCombatLockdown() and Many.Arm(key) then
    -- The list's own search box, if it has the keyboard, lets it go, so the
    -- arrows step the box (a chat box open would have taken the Shift-click
    -- as a link, and never opened it).
    local focus = type(GetCurrentKeyBoardFocus) == "function" and GetCurrentKeyBoardFocus() or nil
    if focus and BV.panel and focus == BV.panel.SearchBox then focus:ClearFocus() end
    key:Show()
  else
    key:Hide()
  end
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
-- clear -- for as long as the search has words (BV.Peek); the bag is back
-- as it is emptied, and the saved choice is never touched.
function BV.ShowMails(panel, kind)
  if kind.gold then return end
  local box = panel.SearchBox
  if not box then return end
  local name = BV.NameOf(kind)
  if not (name and name ~= "") then return BV.WaitName(kind) end
  BV.want = nil
  GameTooltip:Hide()
  panel._bagPeek, panel._bagPeekAlt, panel._bagPeekAll = panel.viewMode, panel._alt, nil
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

-- The client has not got the item's name yet, so there is nothing to search
-- for: it has been asked for (BV.NameOf), and the right-click is answered
-- when the name comes, if it comes within BV.NAME_WAIT seconds and the bag
-- is still the one clicked (the same build, still up). Otherwise nothing.
BV.NAME_WAIT = 3
function BV.WaitName(kind)
  if not kind.id then return end
  BV.want, BV.wantBuild, BV.wantAt = kind, model.build, GetTime()
end

-- Names the searches asked for have come (Helpers.OnSearchNames).
function BV.NamesArrived()
  local kind, panel = BV.want, BV.panel
  if not kind then return end
  if model.build ~= BV.wantBuild or GetTime() - (BV.wantAt or 0) > BV.NAME_WAIT or kind.n <= 0
      or not (panel and panel:IsShown() and BV.area and BV.area:IsShown()) then
    BV.want = nil
    return
  end
  local name = BV.NameOf(kind)
  if name and name ~= "" then BV.ShowMails(panel, kind) end
end

-- The mailbox closed: a tile's mails, and a name waited for, end with the
-- visit (the search is emptied too, CollectTab's CT.ClearSearch).
function BV.Closed()
  local panel = BV.panel
  if panel then panel._bagPeek, panel._bagPeekAlt, panel._bagPeekAll = nil, nil, nil end
  BV.want = nil
  -- A question to return a tile's mails goes with the visit (CollectTab's
  -- RV.HideQuestions takes the box down); an answer after it sends nothing.
  BV.Alt.Hide()
end

-- The letters' line clicked: the list in the bag's place for this visit,
-- from its top, as a tile's right-click shows it but with no search set
-- (BV.Peek, `_bagPeekAll`); the saved choice stays the bag, and the bag's
-- button, unlit, brings it back.
function BV.ShowLetters(panel)
  if not panel then return end
  BV.want = nil
  if GameTooltip:IsShown() then GameTooltip:Hide() end
  panel._bagPeek, panel._bagPeekAlt, panel._bagPeekAll = panel.viewMode, panel._alt, true
  if panel.MailListScroll then panel.MailListScroll:SetVerticalScroll(0) end
  ns.CollectTab.RefreshMailList(panel)
end

-- panel -> the index of the list's one letter with nothing attached, found
-- now, by the walk and the test the line's count is made with
-- (BV.TallyInbox, BV.IsLetter), in the list as it was built; nil where an
-- inbox update has come since it was built (its indices may name other
-- mail), or it holds none or more than one. Nothing is kept from the draw,
-- so nothing can go stale, and nothing is made.
function BV.OneLetter(panel)
  local P = Parts()
  local filtered, done = panel._filtered, panel._filteredDone
  if not (P and filtered and done) then return nil end
  local gen = panel._bindGen
  if gen == nil or gen ~= Mail().InboxGen() then return nil end
  local divider = P.DIVIDER
  local found = nil
  for i = 1, #filtered do
    local index = filtered[i]
    if index ~= divider and not done[i] then
      local _, _, sender, subject, money, cod, _, itemCount, wasRead = GetInboxHeaderInfo(index)
      -- An index that names no mail (as the reading view's fingerprint
      -- reads it) is no letter.
      if (sender ~= nil or subject ~= nil)
          and BV.IsLetter(tonumber(money) or 0, tonumber(cod) or 0, tonumber(itemCount) or 0, wasRead) then
        if found then return nil end
        found = index
      end
    end
  end
  return found
end

-- The letters' line clicked (his f82 T03 pick, "one"): where it says one
-- letter, that letter opens to read in the reading view, as its row's open
-- gesture opens it (ShowDetail), and closing the view brings the bag back
-- without it (reading marks it read; BV.DetailChanged); where it says
-- several, the list in the bag's place (BV.ShowLetters). The one letter
-- opens only where its row would open it (ActivateRow): never while a run
-- is on, the columns are being arranged, Test mail stands in the list's
-- place, or away from this character's own box at an open mailbox; then
-- the click does nothing, as the row's does.
-- Where the letter cannot be found for certain now (BV.OneLetter: the box
-- changed since the line was drawn), the list, and nothing is opened.
-- While Return and Delete with Alt is kept on over the bag (Alt.Live), the
-- one letter does not open: its row does nothing in the mode either, and
-- opening it would end the mode, so the next tile click would collect.
function BV.LettersClick(panel)
  if BV.lettersN ~= 1 then return BV.ShowLetters(panel) end
  if BV.Alt.Live() then return end
  local P = Parts()
  local CT = ns.CollectTab
  if not (P and CT) or type(P.ShowDetail) ~= "function" then return BV.ShowLetters(panel) end
  if panel._preview or P.RV.Arranging(panel) or CT.IsRunning() then return end
  if model.src ~= "inbox" or P.AV.Active(panel) or not P.MailboxOpen() then return end
  local index = BV.OneLetter(panel)
  if not index then return BV.ShowLetters(panel) end
  BV.want = nil
  if GameTooltip:IsShown() then GameTooltip:Hide() end
  P.ShowDetail(panel, index)
end
do
  local H = ns.Helpers
  if H and type(H.OnSearchNames) == "function" then H.OnSearchNames(BV.NamesArrived) end
  local bus = ns.Events
  if bus and type(bus.Register) == "function" then bus.Register("MAIL_CLOSED", BV.Closed) end
end

-- A C.O.D. mail's tile: the fan's tile take (CollectTab, Fan.TakeItem),
-- from here. The question first (ConfirmCOD, once, with the mail's whole
-- price), the mail found again after the wait by what was clicked, the
-- slot still holding the item clicked, and then MailService's take: one
-- stack, TakeAttachment; the item in two stacks or more, CollectMail with
-- `only`, as a row's click collects a C.O.D. mail. Each is a place a take
-- that pays is sent only with the player's answer, and checks all of it
-- once more.
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
    local function done(status, refused, reason, _, paid)
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
    end
    if kind.stacks > 1 and id then
      -- Every stack of the item in this one mail, as one take of the mail
      -- (Mail.CollectMail with `only`): the first take is the one that pays,
      -- for what was clicked and nothing else; the rest go only to the same
      -- mail, adopted once under its paid form, each stack found again by
      -- its item and size before its command (RunPlan). Not seen to pay, or
      -- the mail lost or changed, and nothing more is sent.
      M.CollectMail(index, done, { allowCOD = true, history = record, clicked = what, only = id })
    else
      M.TakeAttachment(index, slot, done, { allowCOD = true, history = record, fetch = true, clicked = what })
    end
  end)
end

-- panel -> whether the bag shows a search of every box (the people toggle
-- on and words in the search): each character's matches under its
-- heading, as Mail Memory was asked for them (AV.Build's options).
function BV.EveryBox(panel)
  if model.src ~= "away" or not panel or panel._searchAll ~= true then return false end
  local opts = panel._avOpts
  return opts ~= nil and opts.all == true and type(opts.query) == "string" and opts.query ~= ""
end

-- realm, name -> whether that is the character logged in.
function BV.Mine(realm, name)
  local H = ns.Helpers
  return H ~= nil and name == H.PlayerName() and (realm == nil or realm == H.PlayerRealm())
end

-- A tile or a heading of a search of every box, clicked: that character's
-- box, as the list's heading's click shows it (AV.OpenHeader: the search
-- cleared, and the box shown; this character's own Inbox for its own
-- name, where a click takes). Nothing is taken or sent, and nothing lights.
function BV.GoBox(panel, realm, name)
  if not (panel and name) then return end
  local arrange = ns.Arrange
  if arrange and arrange.host then return end
  if BV.Many.open then BV.Many.Close() end
  if GameTooltip:IsShown() then GameTooltip:Hide() end
  Parts().AV.OpenHeader(panel, realm, name)
end

-- A click on a tile. Right: its mails. Modified left: the game's item
-- rules (Shift links, Ctrl tries on), never the plain click's take. Plain
-- left: every stack of the item as one run, at a mailbox, on a tile that
-- can be taken, while the bag is drawn from the inbox as it stands; a
-- C.O.D. tile asks first. Anywhere else a click does nothing.
function BV.TileClick(tile, button)
  -- While the Alt marks show in the bag, the click is theirs (section 7).
  if BV.Alt.Owns(tile, button) then return end
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
  -- In a search of every box a tile goes to its character's box, as its
  -- heading does (BV.GoBox).
  if kind.sect.name and BV.EveryBox(panel) then return BV.GoBox(panel, kind.sect.realm, kind.sect.name) end
  -- Nothing can be taken from another character's box or from History: a
  -- lock on the tile, and the line under the list lit for a moment
  -- (BV.NoTake), as a mail row there answers.
  if model.src ~= "inbox" or not P.MailboxOpen() then return BV.NoTake(panel, tile, tile, 16, "kind") end
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
-- 6b. Nothing to take here
--
-- A plain click where nothing can be taken (another character's box, its
-- History or this character's, a search of every character) takes nothing,
-- in the bag and in the list alike, and is answered on the thing clicked
-- and at the foot, for about two seconds, every fade eased in and out:
--   * a small white lock (Phosphor's lock-simple, Theme.GLYPHS lock-16 on a
--     tile, lock-12 on a row's icon) over the tile or the icon, which is
--     darkened under it: in 0.25 s, held 0.9 s, out 0.8 s. White on the
--     darkened art, with a black copy a unit under it, so it reads on a
--     pale icon and on any window opacity;
--   * the line at the foot answers in the accent, in its own place. Where
--     its words say why already (another character's box, "Log in on ...
--     to collect it"), they turn the accent (f91 F01): a copy of them in
--     the accent (`Lit`) fades in over the line as the line fades out
--     under it (0.3 s), held 0.85 s, and back (0.8 s); the character's
--     name keeps its class color, and under the name alone a thin accent
--     line grows from its middle (0.45 s) and fades with the words. The
--     name is found in the words as the language put it, measured once
--     per text; no name found, no line. Where the words do not say why
--     (History, the matches of a search of every character, another
--     character's History), "Nothing to take here" (NOTHING_TO_TAKE)
--     stands in their place in the accent while they step aside (f91 F02):
--     they fade out (0.25 s), the reason fades in (0.2 s on, 0.3 s), held,
--     out (0.3 s), and the words come back (by 1.83 s). Nothing is added
--     under the line and nothing moves.
-- No chat line, no sound, no gray band over the line. The line's own ink
-- is never changed: it rests a step over textSecondary (Theme.FOOT_LIFT)
-- throughout, and only its alpha moves.
--
-- One answer at a time, on one lock frame, one line texture, one copy of
-- the words, one reason text (on a frame of its own, with its plate) and
-- one measuring text made the first time, and one fade on each note made the first time it answers (nothing is
-- built per click, no closure per click). The fades are the client's own
-- animations; the answer is ended by ONE C_Timer.After of its length, told
-- from an older one by two counts, so a second click starts it again on
-- the thing newly clicked (the old one put back at once) and only the last
-- timer ends it. The tab, the window or the mailbox hidden, the window
-- resized, the view changed, the list scrolled or bound again under it: it
-- ends there, everything as it was. Nothing runs between answers.
-------------------------------------------------------------
-- The lock: in, held, out.
BV.NT_IN, BV.NT_HOLD, BV.NT_OUT = 0.25, 0.9, 0.8
-- The darkening under the lock; the black copy's alpha under the glyph.
BV.NT_DIM, BV.NT_SHADE = 0.58, 0.9
-- The words in the accent: in, held, out (the line under them the other
-- way round on the same timing).
BV.NT_LIT_IN, BV.NT_LIT_HOLD, BV.NT_LIT_OUT = 0.3, 0.85, 0.8
-- The line under the name: grown from its middle in NT_GROW, NT_RULE_H
-- tall, its top NT_RULE_Y under the words' middle (3 under their
-- baseline), NT_RULE_PAD wider than the name each side; it fades out with
-- the words.
BV.NT_GROW, BV.NT_RULE_H, BV.NT_RULE_Y, BV.NT_RULE_PAD = 0.45, 2, 9, 2
-- Where the words do not say why: they fade out in NT_AWAY and are back
-- NT_BACK after NT_AWAY_HOLD more; the reason fades in NT_WHY_IN after
-- NT_WHY_DELAY, held NT_WHY_HOLD, out in NT_WHY_OUT.
BV.NT_AWAY, BV.NT_AWAY_HOLD, BV.NT_BACK = 0.25, 1.13, 0.45
BV.NT_WHY_DELAY, BV.NT_WHY_IN, BV.NT_WHY_HOLD, BV.NT_WHY_OUT = 0.2, 0.3, 0.6, 0.3
-- What is lit: the note, the panel, the frame clicked and which of its
-- fields says what it shows (a tile's `kind`, a box row's `mail`, a History
-- row's `entry`), and that thing; the two timer counts; the footer's size
-- at the click.
BV.NT = { armed = 0, fired = 0, fw = 0, fh = 0 }

-- panel -> the note standing in All mail's place, if one is.
function BV.Note(panel)
  local note = panel.AltNote
  if note and note:IsShown() then return note end
  note = panel.HistoryNote
  if note and note:IsShown() then return note end
  return nil
end

-- The notes' words are set here (CollectTab's AV.Build and the History
-- view): `why` where they do not say why nothing can be taken here, so a
-- lit line says it in their place; `name`, the character's name exactly as
-- it stands in `text` (its class color included), where the words name
-- whose box it is, so a lit line underlines it. Set while lit, the line
-- keeps its light with the new words; its words are never changed for the
-- answer.
function BV.SetNote(note, text, why, name)
  if not note then return end
  why = why and true or nil
  local NT = BV.NT
  -- Lit the other way (the view changed under the light): it ends.
  if NT.note == note and note.__pbWhy ~= why then BV.NoTakeEnd() end
  note.__pbWhy = why
  note.__pbName = name
  note:SetText(text)
  if NT.note == note and not why then
    local lit = BV.rule and BV.rule.Lit
    if lit then lit:SetText(text) end
    BV.PlaceRule(note)
  end
end

-- The room the note's words have: the footer's width, inset each side as
-- the note is (CollectTab's notes, RV.PlaceStack). Read off the footer,
-- a frame of Postbox's own, never the words.
function BV.NoteRoom(note)
  local footer = note:GetParent()
  local w = footer and footer:GetWidth() or 0
  return (w or 0) - 2 * Th().Metrics.inset
end

-- note -> where its name stands in its words: the middle's offset from the
-- note's middle (the words are centred) and the name's width; nil where no
-- name is set, the name is not in the words, or the words do not fit the
-- room they have now (cut short, the name may be too). Measured on the
-- measuring text (the note's face) the first time a text is asked about
-- and kept on the note until its words change, so a repaint or a second
-- click measures nothing.
function BV.NameSpot(note)
  local text = note:GetText()
  if note.__pbSpotOf ~= text then
    note.__pbSpotOf, note.__pbSpotX, note.__pbSpotW, note.__pbSpotFull = text, 0, 0, 0
    local name, meas = note.__pbName, BV.rule and BV.rule.Meas
    local s = meas and type(text) == "string" and type(name) == "string" and name ~= ""
      and string.find(text, name, 1, true)
    if s then
      local T = Th()
      meas:SetText(text)
      local full = T.TextWidth(meas)
      meas:SetText(name)
      local w = T.TextWidth(meas)
      local before = 0
      if s > 1 then
        meas:SetText(string.sub(text, 1, s - 1))
        before = T.TextWidth(meas)
      end
      meas:SetText("")
      if w > 0 and full > 0 then
        note.__pbSpotX, note.__pbSpotW, note.__pbSpotFull = before + w / 2 - full / 2, w, full
      end
    end
  end
  local full = note.__pbSpotFull
  if full <= 0 then return nil end
  local room = BV.NoteRoom(note)
  if room > 0 and full > room then return nil end
  return note.__pbSpotX, note.__pbSpotW
end

-- The accent line under the name, as wide as the name and NT_RULE_PAD more
-- each side, centred under it. Hidden, and false, where no name is found.
function BV.PlaceRule(note)
  local rule = BV.rule
  if not rule then return false end
  local tex = rule.Tex
  local x, w = BV.NameSpot(note)
  if not x then
    if rule.Grow then rule.Grow:Stop() end
    if tex:IsShown() then tex:Hide() end
    return false
  end
  tex:ClearAllPoints()
  tex:SetPoint("TOP", note, "CENTER", x, -BV.NT_RULE_Y)
  tex:SetWidth(w + 2 * BV.NT_RULE_PAD)
  tex:Show()
  return true
end

-- An Alpha animation on `group`: from, to, delay, duration, order, eased
-- in and out.
function BV.FadeStep(group, from, to, delay, duration, order)
  local a = group:CreateAnimation("Alpha")
  a:SetFromAlpha(from)
  a:SetToAlpha(to)
  a:SetStartDelay(delay)
  a:SetDuration(duration)
  a:SetSmoothing("IN_OUT")
  a:SetOrder(order)
  return a
end

-- region, in, hold, out [, delay]: a fade in, held, out, ending hidden
-- (alpha 0). The lock's, the accent words' and the reason's.
function BV.FadeOf(region, fadeIn, hold, fadeOut, delay)
  if type(region.CreateAnimationGroup) ~= "function" then return nil end
  local fade = region:CreateAnimationGroup()
  BV.FadeStep(fade, 0, 1, delay or 0, fadeIn, 1)
  BV.FadeStep(fade, 1, 0, hold, fadeOut, 2)
  if fade.SetToFinalAlpha then fade:SetToFinalAlpha(true) end
  return fade
end

-- note -> its fade out and back, made the first time it answers: the line
-- steps aside for the accent copy or the reason. The timing is set per
-- answer (BV.NoTake), on the same two animations.
function BV.NoteFade(note)
  local fade = note.__pbFade
  if fade ~= nil then return fade or nil end
  if type(note.CreateAnimationGroup) ~= "function" then
    note.__pbFade = false
    return nil
  end
  fade = note:CreateAnimationGroup()
  fade.Away = BV.FadeStep(fade, 1, 0, 0, BV.NT_AWAY, 1)
  fade.Back = BV.FadeStep(fade, 0, 1, BV.NT_AWAY_HOLD, BV.NT_BACK, 2)
  if fade.SetToFinalAlpha then fade:SetToFinalAlpha(true) end
  note.__pbFade = fade
  return fade
end

-- The lock, the line and the texts, made the first time anything is
-- answered.
function BV.NoTakeParts(panel)
  local T = Th()
  local lock = BV.lock
  if not lock then
    lock = CreateFrame("Frame", nil, panel)
    lock:EnableMouse(false)
    lock.Dim = lock:CreateTexture(nil, "ARTWORK")
    lock.Dim:SetAllPoints()
    lock.Dim:SetColorTexture(0, 0, 0, BV.NT_DIM)
    lock.Shade = T.Glyph(lock, "lock-16", 16, "OVERLAY")
    lock.Glyph = T.Glyph(lock, "lock-16", 16, "OVERLAY")
    if lock.Shade then
      lock.Shade:SetDrawLayer("OVERLAY", 1)
      lock.Shade:SetVertexColor(0, 0, 0, BV.NT_SHADE)
      lock.Shade:SetPoint("CENTER", lock, "CENTER", 0, -1)
    end
    if lock.Glyph then
      lock.Glyph:SetDrawLayer("OVERLAY", 2)
      lock.Glyph:SetVertexColor(1, 1, 1, 1)
      lock.Glyph:SetPoint("CENTER", lock, "CENTER", 0, 0)
    end
    lock.Fade = BV.FadeOf(lock, BV.NT_IN, BV.NT_HOLD, BV.NT_OUT)
    lock:SetScript("OnHide", BV.NoTakeEnd)
    lock:Hide()
    BV.lock = lock
  end
  local rule = BV.rule
  if not rule then
    rule = CreateFrame("Frame", nil, panel.Footer)
    rule:EnableMouse(false)
    rule:SetAllPoints(panel.Footer)
    rule.Tex = rule:CreateTexture(nil, "ARTWORK")
    rule.Tex:SetHeight(BV.NT_RULE_H)
    rule.Tex:Hide()
    if type(rule.Tex.CreateAnimationGroup) == "function" then
      local g = rule.Tex:CreateAnimationGroup()
      local grow = g:CreateAnimation("Scale")
      if grow.SetScaleFrom then
        grow:SetScaleFrom(0.02, 1)
        grow:SetScaleTo(1, 1)
      elseif grow.SetFromScale then
        grow:SetFromScale(0.02, 1)
        grow:SetToScale(1, 1)
      end
      if grow.SetOrigin then grow:SetOrigin("CENTER", 0, 0) end
      grow:SetDuration(BV.NT_GROW)
      grow:SetSmoothing("IN_OUT")
      grow:SetOrder(1)
      -- Out with the words, from the start of the answer.
      BV.FadeStep(g, 1, 0, BV.NT_LIT_IN + BV.NT_LIT_HOLD, BV.NT_LIT_OUT, 1)
      if g.SetToFinalAlpha then g:SetToFinalAlpha(true) end
      rule.Grow = g
    end
    -- The texts stand in the note's own place, in the note's face, their
    -- ink for the window, as the note's. The words in the accent, set to
    -- the note's words at each answer: as wide as the note's own words,
    -- so the note's plate (Theme.OnWindow), which stays while the note
    -- fades, is under them already.
    local lit = T.CreateText(rule, "secondary")
    if lit then
      lit:SetJustifyH("CENTER")
      lit:SetWordWrap(false)
      T.SetColor(lit, "accent", "window")
      lit:Hide()
      lit.Fade = BV.FadeOf(lit, BV.NT_LIT_IN, BV.NT_LIT_HOLD, BV.NT_LIT_OUT)
      rule.Lit = lit
    end
    -- The reason, its words set once. It can be wider than the line it
    -- stands in for (a short History line, a search's "2 matches"), so it
    -- lays a plate of its own (Theme.OnWindow), legible at any window
    -- opacity. Both stand on a frame of their own whose alpha the fade
    -- moves: the plate, shown and hidden with the words, also fades with
    -- them, so it never stands without them, nor over them at alpha 0.
    local why = CreateFrame("Frame", nil, rule)
    why:EnableMouse(false)
    why:SetAllPoints(rule)
    local reason = T.CreateText(why, "secondary")
    if reason then
      reason:SetJustifyH("CENTER")
      reason:SetWordWrap(false)
      reason:SetText(L()["NOTHING_TO_TAKE"])
      T.SetColor(reason, "accent", "window")
      reason:Hide()
      if T.OnWindow then T.OnWindow(reason, "window", "CENTER") end
      reason.Fader = why
      reason.Fade = BV.FadeOf(why, BV.NT_WHY_IN, BV.NT_WHY_HOLD, BV.NT_WHY_OUT, BV.NT_WHY_DELAY)
      rule.Reason = reason
    end
    -- Where the name stands in the words: measured here, never shown.
    local meas = T.CreateText(rule, "secondary")
    if meas then
      meas:SetWordWrap(false)
      meas:Hide()
      rule.Meas = meas
    end
    rule:SetScript("OnHide", BV.NoTakeEnd)
    -- The window resized (the footer is the rule frame's size): it ends.
    rule:SetScript("OnSizeChanged", BV.NoTakeSized)
    rule:Hide()
    BV.rule = rule
  end
  return lock, rule
end

-- text, note: `text` laid over the note, in its place, and its fade played
-- from the start, on the text or on the frame it stands on (`Fader`).
function BV.NoTakeShow(text, note)
  if not text then return end
  local fader = text.Fader or text
  text:ClearAllPoints()
  text:SetPoint("LEFT", note, "LEFT", 0, 0)
  text:SetPoint("RIGHT", note, "RIGHT", 0, 0)
  fader:SetAlpha(0)
  text:Show()
  if text.Fade then
    text.Fade:Stop()
    text.Fade:Play()
  else
    fader:SetAlpha(1)
  end
end

-- panel, owner, region, size, field: a click on `owner` (a tile, a row)
-- took nothing. The lock over `region` at `size` (16 a tile, 12 a row's
-- icon); `owner[field]` is what it shows, so the answer ends if it is
-- bound to something else. Nothing where no note stands under the list.
function BV.NoTake(panel, owner, region, size, field)
  local note = panel and BV.Note(panel)
  if not (note and panel.Footer and owner and region) then return end
  local NT = BV.NT
  if NT.note then BV.NoTakeEnd() end
  local T = Th()
  local lock, rule = BV.NoTakeParts(panel)
  NT.note, NT.panel, NT.on, NT.field, NT.what = note, panel, owner, field, owner[field]

  local art = size >= 16 and "lock-16" or "lock-12"
  if lock.Glyph then T.SetGlyphArt(lock.Glyph, art) end
  if lock.Shade then T.SetGlyphArt(lock.Shade, art) end
  lock:SetParent(owner)
  lock:ClearAllPoints()
  lock:SetAllPoints(region)
  lock:SetFrameLevel(owner:GetFrameLevel() + 8)
  lock:Show()
  if lock.Fade then
    lock.Fade:Stop()
    lock.Fade:Play()
  end

  -- The line steps aside for the answer standing in its place: the
  -- reason where its words do not say why, else its words in the accent,
  -- the name underlined.
  local fade = BV.NoteFade(note)
  local why = note.__pbWhy and rule.Reason
  if fade then
    fade:Stop()
    if why then
      fade.Away:SetDuration(BV.NT_AWAY)
      fade.Back:SetStartDelay(BV.NT_AWAY_HOLD)
      fade.Back:SetDuration(BV.NT_BACK)
    else
      fade.Away:SetDuration(BV.NT_LIT_IN)
      fade.Back:SetStartDelay(BV.NT_LIT_HOLD)
      fade.Back:SetDuration(BV.NT_LIT_OUT)
    end
  end
  NT.fw, NT.fh = panel.Footer:GetWidth() or 0, panel.Footer:GetHeight() or 0
  rule:Show()
  if why then
    BV.NoTakeShow(rule.Reason, note)
  else
    local lit = rule.Lit
    if lit then
      lit:SetText(note:GetText())
      BV.NoTakeShow(lit, note)
    end
    if BV.PlaceRule(note) then
      T.FillColor(rule.Tex, "accent")
      -- Whole for the grow, whatever the last answer's fade left.
      rule.Tex:SetAlpha(1)
      if rule.Grow then
        rule.Grow:Stop()
        rule.Grow:Play()
      end
    end
  end
  -- The note steps aside only where something stands in its place.
  if fade and (why or rule.Lit) then fade:Play() end

  NT.armed = NT.armed + 1
  C_Timer.After(BV.NT_IN + BV.NT_HOLD + BV.NT_OUT, BV.NoTakeDue)
end

-- The answer is over: the line whole, in its own ink, the texts, the lock
-- and the line under the name put away.
function BV.NoTakeEnd()
  local NT = BV.NT
  local note = NT.note
  if not note then return end
  NT.note, NT.panel, NT.on, NT.field, NT.what = nil, nil, nil, nil, nil
  local fade = note.__pbFade
  if fade then fade:Stop() end
  note:SetAlpha(1)
  -- Its resting ink, a step over textSecondary (Theme.FOOT_LIFT).
  local T = Th()
  T.SetColorLift(note, "textSecondary", T.FOOT_LIFT, "window")
  local lock, rule = BV.lock, BV.rule
  if lock then
    if lock.Fade then lock.Fade:Stop() end
    if lock:IsShown() then lock:Hide() end
  end
  if rule then
    if rule.Grow then rule.Grow:Stop() end
    if rule.Tex:IsShown() then rule.Tex:Hide() end
    local lit, reason = rule.Lit, rule.Reason
    if lit then
      if lit.Fade then lit.Fade:Stop() end
      if lit:IsShown() then lit:Hide() end
    end
    if reason then
      if reason.Fade then reason.Fade:Stop() end
      if reason:IsShown() then reason:Hide() end
      if reason.Fader then reason.Fader:SetAlpha(1) end
    end
    if rule:IsShown() then rule:Hide() end
  end
end

-- The rule frame, the footer's size, changed while lit (the window resized,
-- the band shown or hidden): the answer ends, everything put back.
function BV.NoTakeSized(_, w, h)
  local NT = BV.NT
  if not NT.note then return end
  w, h = tonumber(w) or 0, tonumber(h) or 0
  if w - NT.fw > 0.5 or NT.fw - w > 0.5 or h - NT.fh > 0.5 or NT.fh - h > 0.5 then BV.NoTakeEnd() end
end

function BV.NoTakeDue()
  local NT = BV.NT
  NT.fired = NT.fired + 1
  if NT.fired == NT.armed then BV.NoTakeEnd() end
end

-- After the list or the bag is bound again, or scrolled: the answer ends
-- where what was clicked is gone, shows something else, or the note went.
function BV.NoTakeCheck()
  local NT = BV.NT
  local on = NT.on
  if not on then return end
  if on[NT.field] ~= NT.what or not on:IsVisible() or not NT.note:IsShown() then BV.NoTakeEnd() end
end

-------------------------------------------------------------
-- 7. Return and Delete with Alt, in the bag (s33 bagalt)
--
-- His picks: f70 M01 "all" (a click on a tile returns), M02 "plain" (the
-- row's Return arrow in the tile's corner), f74 T01 "senders" (the
-- tooltip: a line per sender, what else goes under it), S01 "build" (one
-- question, then every mail it named, one at a time, each checked again).
-- f80 Q03 (when the question is asked): one mail holding nothing but the
-- tile's item goes back at the click (Mail.OnlyItem); anything more asks
-- first (Alt.Asks, the one place that decides it).
--
-- Only on this character's own Inbox at a mailbox, where the marks are
-- eligible (CollectTab's M.Eligible: the list, or the bag in its place),
-- with Options > Mail tab > Return and Delete with Alt on. Every guard of
-- the rows' marks holds here as there: no marks while a text box has the
-- keyboard or when the Alt press begins with Ctrl down (M.OnEvent); a
-- click in the first 150 ms does nothing at all (M.p < 1); a return's
-- click within 0.4 s of the last does nothing (M.Calm); a click acts only
-- on the tile pressed (Alt.Pressed). And, as nowhere else: one question
-- at a time, nothing while a run or any command is out, nothing in combat.
--
-- While the marks show:
--   click         a tile with mail that can go back (Mail.Returnable, the
--                 rows' own rule): the question, naming every sender (eight
--                 at most; the rest stays), how many mails each, what else
--                 those mails hold, the auction mail that stays; Return
--                 sends exactly the mails it named (Mail.ReturnMails, which
--                 looks at each again right before it goes and stops at
--                 the first that does not match). A C.O.D. mail's tile:
--                 that one mail, "Nothing is paid" (the game's return pays
--                 nothing). The gold tile, a gray tile (mail the game has
--                 not listed), a tile with nothing to return: nothing.
--   right-click   its mails in the list, as without the marks (BV.ShowMails);
--                 nothing is deleted from the bag: a tile is never finished
--                 mail (finished mail holds nothing).
--   Shift / Ctrl  Alt held: nothing. Kept on: the game's item rules (a
--                 link, a try-on), never "how many".
-- Anywhere else (another box, History, the every-character search) the
-- marks are not eligible and a click is what it always was.
--
-- What the tooltip says and what the question says are each drawn by ONE
-- function from the facts (Alt.Tip, Alt.AskText), and the facts are
-- gathered by one more (Alt.Facts), so their look can change without
-- touching what is returned. Built when the tooltip opens or the click is
-- made, never per bag pass, into tables that are kept. The marks on the
-- tiles: one plate and one arrow a tile, made the first time it wears
-- one; scripts shared; nothing per frame but the fade's alpha.
-------------------------------------------------------------
local Alt = {
  -- How many senders one question names: past them, their mail stays.
  CAP = 8,
  -- The mark: a plate this square in the tile's top right, inside its
  -- edge, black at PLATE_A, the rows' Return arrow centered on it in a
  -- fixed light ink (INK, white under the pointer), legible on the plate
  -- under every palette.
  PLATE = 13, PLATE_A = 0.72, INK = 0.82,
  -- Whether a C.O.D. mail's tile offers its mail back, as a row's arrow
  -- does (Mail.ReturnRule); its question says nothing is paid.
  COD = true,
  -- The question: a count told apart from an older one's answer, whether
  -- one stands, the panel it was asked on; a sweep under way.
  serial = 0, open = false, panel = nil, running = false,
  -- Kept: the tooltip's facts, the question's, what the question names
  -- for the service (Mail.ReturnWant), the words being joined.
  tip = nil, ask = nil, want = {}, lines = {}, parts = {},
  -- The "+" line's and the gray lines' joint; the warning tone (as the
  -- tooltip draws it) and how near a class colour may come to it before a
  -- name is drawn white (Alt.Name).
  SEP = " \194\183 ", WARN = { 0.98, 0.56, 0.18 }, NEAR = 0.35,
  -- Cutting the "+" lines: the header's arrow and its space, the least gap
  -- between a double line's two sides, the "+" lines' indent, and the room
  -- the game's question box gives its words (290 of its 320), kept short of
  -- it so the game never wraps a "+" line itself.
  HEAD_ARROW = 18, DOUBLE_GAP = 20, PLUS_INDENT = 8, BOX_ROOM = 270, plus = {},
}
BV.Alt = Alt

function Alt.M()
  local P = Parts()
  return P and P.RV.Marks or nil
end

-- panel -> whether the bag is what shows in the panel's list place.
function Alt.Shows(panel)
  local area = BV.area
  return panel ~= nil and BV.panel == panel and area ~= nil and area:IsShown() and true or false
end

-- Whether the marks show over the bag now, on the inbox's own tiles.
function Alt.Live()
  local M = Alt.M()
  return M ~= nil and M.goal == 1 and model.src == "inbox" and Alt.Shows(BV.panel)
end

-- A facts table, made once for each of its two uses.
function Alt.NewFacts()
  return { g = {}, pool = {}, gn = 0, total = 0, back = 0, auction = 0, qn = 0, cod = 0, shown = 0, capped = 0 }
end

-- F, sender -> that sender's group, made (from the pool) where it has none.
function Alt.Group(F, sender)
  local g
  for i = 1, F.gn do
    g = F.g[i]
    if g.name == sender then return g end
  end
  local i = F.gn + 1
  F.gn = i
  g = F.pool[i]
  if not g then
    g = { idx = {}, cnt = {}, oid = {}, oname = {}, ocnt = {} }
    F.pool[i] = g
  end
  g.name, g.n, g.mails, g.on, g.gold, g.letter, g.unread = sender, 0, 0, 0, 0, false, 0
  F.g[i] = g
  return g
end

-- Another item in the group's mails, added to what they also hold.
function Alt.Other(g, key, name, count)
  for j = 1, g.on do
    if g.oid[j] == key then
      g.ocnt[j] = g.ocnt[j] + count
      if not g.oname[j] then g.oname[j] = name end
      return
    end
  end
  local j = g.on + 1
  g.on = j
  g.oid[j], g.oname[j], g.ocnt[j] = key, name, count
end

-- Most of the item first, then by name.
function Alt.Order(a, b)
  if a.n ~= b.n then return a.n > b.n end
  return a.name < b.name
end

-- A group's mails, most of the item first; its other items, most first.
function Alt.SortGroup(g)
  local idx, cnt = g.idx, g.cnt
  for j = 2, g.mails do
    local i, c = idx[j], cnt[j]
    local k = j - 1
    while k >= 1 and cnt[k] < c do
      idx[k + 1], cnt[k + 1] = idx[k], cnt[k]
      k = k - 1
    end
    idx[k + 1], cnt[k + 1] = i, c
  end
  local oid, oname, ocnt = g.oid, g.oname, g.ocnt
  for j = 2, g.on do
    local a, b, c = oid[j], oname[j], ocnt[j]
    local k = j - 1
    while k >= 1 and ocnt[k] < c do
      oid[k + 1], oname[k + 1], ocnt[k + 1] = oid[k], oname[k], ocnt[k]
      k = k - 1
    end
    oid[k + 1], oname[k + 1], ocnt[k + 1] = a, b, c
  end
end

-- kind, F [, want] -> F: what a click on the tile would return, read from
-- the inbox as it stands (the bag current, BV.Current): each of its mails
-- that can go back (Mail.Returnable), grouped by sender, the sender with
-- most of the item first, each sender's mails most first; what else those
-- mails hold (other items, gold, a letter of their own: nothing opened,
-- nothing marked read); the C.O.D. owed; the auction mail that stays.
-- Past CAP senders the rest are counted, not named, and stay. With `want`
-- (Mail.ReturnWant's, at the click), every mail named is noted for the
-- service in the order it will go: nothing else can be sent back.
-- THE place that decides what a tile returns.
function Alt.Facts(kind, F, want)
  local M = Mail()
  local slots = M.MAX_ATTACHMENTS or 16
  local unknown = L()["SENDER_UNKNOWN"]
  F.gn, F.total, F.back, F.auction, F.qn, F.cod = 0, 0, 0, 0, 0, 0
  F.name = BV.NameOf(kind) or RETRIEVING_ITEM_INFO or "?"
  local id = kind.id
  for i = 1, kind.mails do
    local index = kind.ref[i]
    if type(index) == "number" then
      F.total = F.total + 1
      if M.Returnable(index) then
        F.back = F.back + 1
        local _, _, sender, _, money, cod = GetInboxHeaderInfo(index)
        if type(sender) ~= "string" or sender == "" then sender = unknown end
        local g = Alt.Group(F, sender)
        local m = g.mails + 1
        local count = kind.cnt[i] or 0
        g.mails, g.n = m, g.n + count
        g.idx[m], g.cnt[m] = index, count
        g.gold = g.gold + (tonumber(money) or 0)
        F.cod = F.cod + (tonumber(cod) or 0)
        if M.HasOwnText(index) then g.letter = true end
        local read = 0
        for slot = 1, slots do
          local name, sid, tex, n = GetInboxItem(index, slot)
          if name or sid or tex then
            read = read + 1
            local mine
            if id ~= nil then mine = sid == id else mine = (name ~= nil and name == kind.name) or (name == nil and tex == kind.tex) end
            if not mine then Alt.Other(g, sid or name or tex, name, tonumber(n) or 1) end
          end
        end
        -- Attachments the header counts and no slot names: said as "more
        -- items", never left out.
        local _, _, _, _, _, _, _, count = GetInboxHeaderInfo(index)
        count = tonumber(count) or 0
        if count > read then g.unread = g.unread + (count - read) end
      elseif M.SenderKind(index) == "ah" then
        F.auction = F.auction + 1
      end
    end
  end
  local list = F.g
  for i = #list, F.gn + 1, -1 do list[i] = nil end
  if F.gn > 1 then table.sort(list, Alt.Order) end
  F.shown = F.gn > Alt.CAP and Alt.CAP or F.gn
  F.capped = F.gn - F.shown
  for i = 1, F.gn do
    local g = list[i]
    Alt.SortGroup(g)
    if i <= F.shown then
      F.qn = F.qn + g.mails
      if want then
        for j = 1, g.mails do M.ReturnNote(g.idx[j], want) end
      end
    end
  end
  -- One mail holding nothing but this item, no gold, no letter, no
  -- C.O.D.: the one case the tile shows everything that would leave.
  local g1 = list[1]
  F.only = F.qn == 1 and g1 ~= nil and g1.on == 0 and g1.unread == 0 and g1.gold == 0 and not g1.letter and F.cod == 0
    and M.OnlyItem(g1.idx[1], kind.id, kind.name)
  -- The sums the tooltip and the question say: how much of the item goes
  -- (the named senders'), of how much the tile holds; what stays, in how
  -- many mails, and whether those are all the auction house's.
  local nb = 0
  for i = 1, F.shown do nb = nb + list[i].n end
  F.nb, F.nt = nb, kind.n
  F.stayN, F.stayMails = kind.n - nb, F.total - F.qn
  F.stayAuction = F.auction > 0 and F.auction == F.stayMails
  return F
end

-- Q01, his f80 Q03 pick "only when more goes": a tile's return asks
-- first unless it is ONE mail holding nothing but this item (no other
-- item, no gold, no letter of its own, no C.O.D.), which goes back at the
-- click as a row's does; the sweep still looks at it again right before
-- the command, and stops if it holds anything else by then.
function Alt.Asks(F)
  return not F.only
end

-- An item's name where its stack gave none.
function Alt.ItemName(key)
  local H = ns.Helpers
  if type(key) == "number" and H and type(H.SearchItemName) == "function" then
    local name = H.SearchItemName(key)
    if type(name) == "string" and name ~= "" then return name end
  end
  return RETRIEVING_ITEM_INFO or "?"
end

-- A sender's name in its class colour, as a mail's From line shows it,
-- but white where that colour would read as the warning tone of the "+"
-- lines under it (a druid's orange): the "+" is never mistaken for a name.
function Alt.Name(sender)
  local CS = ns.ContactService
  local token = (CS and CS.ClassOf) and CS.ClassOf(sender) or nil
  if not (token and CS.WrapClass) then return sender end
  local r, g, b = nil, nil, nil
  if CS.ClassColour then r, g, b = CS.ClassColour(token) end
  if r and math.abs(r - Alt.WARN[1]) + math.abs(g - Alt.WARN[2]) + math.abs(b - Alt.WARN[3]) < Alt.NEAR then
    return sender
  end
  return CS.WrapClass(token, sender, "tooltip")
end

-- g -> how many parts of what the group's mails hold besides the tile's
-- item, written into Alt.parts: ONE other item by name ("8 Weavercloth"),
-- then how many more items, the gold as the rows write it, a letter of
-- their own. 0 where they hold nothing else.
function Alt.AlsoParts(g)
  local L0 = L()
  local parts, n = Alt.parts, 0
  if g.on >= 1 then
    n = n + 1
    parts[n] = L0("BAGALT_ITEM_COUNT", g.ocnt[1], g.oname[1] or Alt.ItemName(g.oid[1]))
  end
  local more = (g.on > 1 and g.on - 1 or 0) + (g.unread or 0)
  if more > 0 then
    n = n + 1
    parts[n] = ns.Plural("BAGALT_ALSO_MORE", more)
  end
  if g.gold > 0 then
    n = n + 1
    parts[n] = ns.Core.Formatting.FormatMoneyCompact(g.gold, true)
  end
  if g.letter then
    n = n + 1
    parts[n] = L0["BAGALT_ALSO_LETTER"]
  end
  return n
end

-- n parts (Alt.parts), room, kind, out, k -> the "+" lines, written into
-- `out` from k + 1, returning the last index: as many parts on a line as
-- fit `room` in that type (Theme.TipTextWidth), joined by " · ", each line
-- "+ ..."; a line breaks only between parts, never inside one, so an
-- item's name, "7 more items" and "a letter" are never split. A part wider
-- than the room stands alone on its line. Nothing here is wrapped by the
-- game.
function Alt.Pack(n, room, kind, out, k)
  local T, L0 = Th(), L()
  local parts = Alt.parts
  local line = nil
  for i = 1, n do
    local try = line and (line .. Alt.SEP .. parts[i]) or parts[i]
    if line and T.TipTextWidth(L0("BAGALT_PLUS", try), kind) > room then
      k = k + 1
      out[k] = L0("BAGALT_PLUS", line)
      line = parts[i]
    else
      line = try
    end
  end
  if line then
    k = k + 1
    out[k] = L0("BAGALT_PLUS", line)
  end
  return k
end

-- The Return arrow, drawn in a line of text (the rows' art).
function Alt.Arrow()
  local arrow = Alt.arrow
  if arrow == nil then
    local G = Th().GLYPHS and Th().GLYPHS["expiry-back"]
    arrow = G and ("|T" .. G.file .. ":0:0:0:0:16:16:0:12:0:12|t ") or false
    Alt.arrow = arrow
  end
  return arrow or ""
end

-- THE TOOLTIP'S LOOK (his f80 T02 pick, "head"), from the facts alone,
-- after the item's own lines. One sender and nothing staying: one line in
-- the item name's size, "Returns all 20 to Thessaly" (with "in 3 mails"
-- where there are several), and its "+" line. Otherwise: "Returns 100 of
-- 140" in that size, "4 mails · 3 senders" under it in gray; a line per
-- sender, the name in its class colour at the left, "60 · 2 mails" at the
-- right; under a sender, only if its mails hold more, the "+" line (small,
-- in the warning tone, wrapped); eight senders, then "+N more"; what stays
-- in one gray line. A C.O.D. mail's tile adds its price and that nothing is
-- paid. Where nothing can go back, why (the rows' faded x's words). Then
-- the hints.
function Alt.Tip(F, kind)
  local T, L0, H = Th(), L(), ns.Helpers
  if F.back == 0 then
    local auction = F.auction > 0 and F.auction == F.total
    T.TipLine(L0[auction and "MARKS_FADED_AUCTION" or "MARKS_FADED_OTHER"])
  elseif F.shown == 1 and F.stayN <= 0 then
    local g = F.g[1]
    local text = Alt.Arrow() .. L0("BAGALT_TIP_ALL", F.nb, Alt.Name(g.name))
    if g.mails > 1 then text = text .. " " .. T.TipTone("muted", L0("BAGALT_TIP_IN", ns.Plural("COUNT_MAILS", g.mails))) end
    T.TipHead(text)
    Alt.TipPlus(g, T.TipTextWidth(text, "head") + Alt.HEAD_ARROW)
    if F.cod > 0 then
      T.TipFact(L0["LABEL_COD"], T.TipTone("negative", H.FormatMoney(F.cod)) .. T.TipTone("muted", Alt.SEP .. L0["BAGALT_COD_FREE"]))
    end
  else
    -- Everything of the item goes: "Returns all 720"; something stays:
    -- "Returns 100 of 140".
    local head = (F.nb >= F.nt) and L0("BAGALT_TIP_ALL_N", F.nb) or L0("BAGALT_TIP_SUM", F.nb, F.nt)
    local sub = ns.Plural("COUNT_MAILS", F.qn) .. Alt.SEP .. ns.Plural("BAGALT_SENDERS", F.shown)
    T.TipHead(Alt.Arrow() .. head)
    T.TipLine(T.TipTone("muted", sub))
    -- The tooltip's width, as far as Postbox's own lines make it.
    local room = T.TipTextWidth(head, "head") + Alt.HEAD_ARROW
    local w = T.TipTextWidth(sub, "body")
    if w > room then room = w end
    for i = 1, F.shown do
      local g = F.g[i]
      local right = tostring(g.n) .. Alt.SEP .. ns.Plural("COUNT_MAILS", g.mails)
      w = T.TipTextWidth(g.name, "body") + Alt.DOUBLE_GAP + T.TipTextWidth(right, "body")
      if w > room then room = w end
    end
    for i = 1, F.shown do
      local g = F.g[i]
      GameTooltip:AddDoubleLine(Alt.Name(g.name), tostring(g.n) .. T.TipTone("muted", Alt.SEP .. ns.Plural("COUNT_MAILS", g.mails)),
        1, 1, 1, 1, 1, 1)
      Alt.TipPlus(g, room)
    end
    if F.capped > 0 then T.TipLine(T.TipTone("muted", ns.Plural("TIP_MORE", F.capped))) end
    if F.stayN > 0 and F.stayMails > 0 then
      local mails = F.stayAuction and ns.Plural("BAGALT_AUCTION_MAILS", F.stayMails) or ns.Plural("COUNT_MAILS", F.stayMails)
      T.TipLine(T.TipTone("muted", L0("BAGALT_STAYS", F.stayN, mails)))
    end
  end
  if F.qn == 1 then
    T.TipHint(L0["HINT_MARKS_RETURN"])
  elseif F.qn > 1 then
    T.TipHint(L0("BAGALT_HINT_RETURN_N", ns.Plural("COUNT_MAILS", F.qn)))
  end
  T.TipHint(L0["BAG_HINT_MAILS"])
end

-- A sender's "+" lines in the tooltip: its parts packed to `room` (less
-- the lines' indent), each line unwrapped.
function Alt.TipPlus(g, room)
  local n = Alt.AlsoParts(g)
  if n == 0 then return end
  local out = Alt.plus
  local k = Alt.Pack(n, room - Alt.PLUS_INDENT, "hint", out, 0)
  local T = Th()
  for i = 1, k do T.TipPlus(out[i]) end
end

-- The tooltip's body while the marks show (BV.TileEnter): the facts read
-- now, then drawn. A bag not current says only where its mails are.
function Alt.TipBody(kind)
  if not BV.Current(kind) or (kind.cod and not Alt.COD) then
    Th().TipHint(L()["BAG_HINT_MAILS"])
    return
  end
  local F = Alt.tip
  if not F then
    F = Alt.NewFacts()
    Alt.tip = F
  end
  Alt.Facts(kind, F, nil)
  Alt.Tip(F, kind)
end

-- A sender's "+" lines in the question: packed to the box's room for its
-- words, each in the warning tone. -> the last index of `lines`.
function Alt.AskPlus(g, lines, n)
  local parts = Alt.AlsoParts(g)
  if parts == 0 then return n end
  local first = n + 1
  n = Alt.Pack(parts, Alt.BOX_ROOM, "box", lines, n)
  local T = Th()
  for i = first, n do lines[i] = T.TipTone("warning", lines[i]) end
  return n
end

-- THE QUESTION'S LOOK (his f80 Q02 pick, "words"), in the game's own box,
-- from the facts alone: the act first; one mail holding more, its item
-- and the "+" line; several mails, the sum ("100 of 140 Ironclaw Ore go
-- back."), each sender most of the item first with what goes and its "+"
-- line, what stays; a C.O.D.; the senders past the cap whose mail stays;
-- last Delete's own closing words, in gray. (One mail holding only the
-- item is never asked: Alt.Asks.)
function Alt.AskText(F)
  local T, L0, H = Th(), L(), ns.Helpers
  local lines, n = Alt.lines, 0
  local g1 = F.g[1]
  n = n + 1
  if F.qn == 1 then
    lines[n] = L0("BAGALT_ASK_THIS", g1.name)
    n = n + 1
    lines[n] = L0("BAGALT_ITEM_COUNT", g1.n, F.name)
    n = Alt.AskPlus(g1, lines, n)
  else
    local to = (F.shown == 1) and g1.name or ns.Plural("BAGALT_TO_SENDERS", F.shown)
    lines[n] = L0("BAGALT_ASK_TO", ns.Plural("COUNT_MAILS", F.qn), to)
    n = n + 1
    if F.nb < F.nt then
      lines[n] = L0("BAGALT_Q_SUM", F.nb, F.nt, F.name)
    else
      lines[n] = L0("BAGALT_Q_SUM_ALL", F.nb, F.name)
    end
    n = n + 1
    lines[n] = ""
    for i = 1, F.shown do
      local g = F.g[i]
      n = n + 1
      lines[n] = L0("BAGALT_Q_SENDER", g.name, g.n, ns.Plural("COUNT_MAILS", g.mails))
      n = Alt.AskPlus(g, lines, n)
    end
  end
  if F.cod > 0 then
    n = n + 1
    lines[n] = L0("BAGALT_ASK_COD", H.FormatMoney(F.cod))
  end
  local tail = false
  if F.qn > 1 and F.stayN > 0 and F.stayMails > 0 then
    n = n + 1
    lines[n] = ""
    tail = true
    local mails = F.stayAuction and ns.Plural("BAGALT_AUCTION_MAILS", F.stayMails) or ns.Plural("COUNT_MAILS", F.stayMails)
    n = n + 1
    lines[n] = T.TipTone("muted", L0("BAGALT_Q_STAYS", F.stayN, mails))
  end
  if F.capped > 0 then
    if not tail then
      n = n + 1
      lines[n] = ""
      tail = true
    end
    n = n + 1
    lines[n] = ns.Plural("BAGALT_ASK_CAPPED", F.capped)
  end
  if not tail then
    n = n + 1
    lines[n] = ""
  end
  n = n + 1
  lines[n] = T.TipTone("muted", L0["BAGALT_UNDONE"])
  for k = #lines, n + 1, -1 do lines[k] = nil end
  return table.concat(lines, "\n", 1, n)
end

-- kind -> whether any of the tile's mails can go back (its mark), read
-- once for each build of the bag and each inbox mark.
function Alt.Has(kind)
  local gen = Mail().InboxGen()
  if kind.altAt == model.build and kind.altGen == gen then return kind.alt end
  kind.altAt, kind.altGen = model.build, gen
  local has = false
  if not kind.gold and kind.n > 0 and kind.sect.look ~= 2 and kind.look ~= 3
      and (Alt.COD or not kind.cod) and BV.Current(kind) then
    local M = Mail()
    for i = 1, kind.mails do
      local index = kind.ref[i]
      if type(index) == "number" and M.Returnable(index) then
        has = true
        break
      end
    end
  end
  kind.alt = has
  return has
end

-- The tile's mark, made the first time it wears one and kept.
function Alt.Mark(tile)
  local mark = tile.AltMark
  if mark then return mark end
  local T, M = Th(), Alt.M()
  mark = CreateFrame("Frame", nil, tile)
  mark:SetSize(Alt.PLATE, Alt.PLATE)
  mark:SetPoint("TOPRIGHT", tile, "TOPRIGHT", -1, -1)
  mark:SetFrameLevel(tile:GetFrameLevel() + 4)
  mark:EnableMouse(false)
  local plate = mark:CreateTexture(nil, "BACKGROUND")
  plate:SetAllPoints()
  plate:SetColorTexture(0, 0, 0, Alt.PLATE_A)
  local glyph = T.Glyph and T.Glyph(mark, "expiry-back", M and M.SIZE or 9, "ARTWORK")
  if glyph then
    glyph:SetPoint("CENTER", mark, "CENTER", 0, 0)
    glyph:SetVertexColor(Alt.INK, Alt.INK, Alt.INK, 1)
  end
  mark.Plate, mark.Glyph = plate, glyph
  mark:Hide()
  tile.AltMark = mark
  return mark
end

-- The arrow's ink: white under the pointer.
function Alt.Ink(tile, hover)
  local mark = tile.AltMark
  local glyph = mark and mark.Glyph
  if not glyph then return end
  local v = hover and 1 or Alt.INK
  glyph:SetVertexColor(v, v, v, 1)
end

-- The tile's mark as the marks stand (their fade's place, M.p): shown on a
-- tile with mail that can go back, in the warning triangle's place where
-- the tile wears one; put away otherwise.
function Alt.PaintTile(tile)
  local M = Alt.M()
  local p = M and M.p or 0
  local kind = tile.kind
  local mark = tile.AltMark
  if not (p > 0 and kind and model.src == "inbox" and Alt.Shows(BV.panel) and Alt.Has(kind)) then
    if mark and mark:IsShown() then mark:Hide() end
    if tile.altDim then
      tile.altDim = nil
      tile.Warn:SetAlpha(1)
    end
    return
  end
  mark = Alt.Mark(tile)
  mark:SetAlpha(p)
  if not mark:IsShown() then mark:Show() end
  if tile.Warn:IsShown() then
    tile.altDim = true
    tile.Warn:SetAlpha(1 - p)
  elseif tile.altDim then
    tile.altDim = nil
    tile.Warn:SetAlpha(1)
  end
end

-- Every tile in view at the fade's place (CollectTab's M.PaintAll).
function Alt.PaintAll()
  if not (BV.area and BV.area:IsShown()) then return end
  local tiles = BV.tiles
  for i = 1, #tiles do
    local tile = tiles[i]
    if tile.kind and (tile.AltMark or tile:IsShown()) then Alt.PaintTile(tile) end
  end
end

-- The marks came in (CollectTab's M.Rows): the tiles read again; the "how
-- many" box, a take, closes.
function Alt.Kinds()
  if not Alt.Shows(BV.panel) then return end
  if BV.Many.open then BV.Many.Close() end
  Alt.PaintAll()
end

-- The marks gone (CollectTab's M.ClearAll): every tile's mark put away.
function Alt.ClearAll()
  local tiles = BV.tiles
  for i = 1, #tiles do
    local tile = tiles[i]
    local mark = tile.AltMark
    if mark and mark:IsShown() then mark:Hide() end
    if tile.altDim then
      tile.altDim = nil
      tile.Warn:SetAlpha(1)
    end
  end
end

-- A press on a tile: what it shows then, for the click that ends it.
function Alt.Down(tile)
  tile.altKind, tile.altBuild, tile.altMode = tile.kind, model.build, Alt.Live()
end

-- tile -> whether it shows what it showed at the press that ends in this
-- click, and whether there was a press and the marks owned it; the press
-- is used up either way.
function Alt.Pressed(tile)
  local kind, build, mode = tile.altKind, tile.altBuild, tile.altMode
  tile.altKind, tile.altBuild, tile.altMode = nil, nil, nil
  return kind ~= nil and kind == tile.kind and build == model.build, kind ~= nil, mode and true or false
end

-- tile, button -> true where the marks own the click (BV.TileClick asks
-- first, as ActivateRow asks M.Click): what each button does is in this
-- section's head. A click while the marks are still coming in does
-- nothing at all.
function Alt.Owns(tile, button)
  local same, pressed, pressMode = Alt.Pressed(tile)
  local M = Alt.M()
  local shows = M ~= nil and model.src == "inbox" and Alt.Shows(BV.panel)
  -- Alt read again, as a row's click reads it (M.Click): one still down
  -- that no hold took (a text box had the keyboard) brings the marks in
  -- now, and this click, before they are fully in, does nothing.
  if shows then M.Check() end
  local live = shows and M.goal == 1
  -- A press made with the marks showing and released without them (Alt let
  -- go first), or the other way round, is neither the marks' click nor a
  -- take: nothing.
  if pressed and pressMode ~= live then return true end
  if not live then return false end
  M.Used()
  if M.p < 1 then return true end
  local kind = tile.kind
  local shifted = (type(IsShiftKeyDown) == "function" and IsShiftKeyDown()) or (type(IsControlKeyDown) == "function" and IsControlKeyDown())
  if button == "RightButton" then
    if not shifted and kind and kind.n > 0 then BV.ShowMails(BV.panel, kind) end
    return true
  end
  if button ~= "LeftButton" then return true end
  if shifted then
    if not M.held and kind and kind.n > 0 and not kind.gold then
      local link = BV.LinkOf(kind)
      if link and type(HandleModifiedItemClick) == "function" then HandleModifiedItemClick(link) end
    end
    return true
  end
  if not same or M.Calm() then return true end
  Alt.Start(kind)
  return true
end

-- panel -> whether a return may be asked or sent now: at a mailbox, the
-- bag up on the inbox, nothing running or out on the channel, not
-- arranging, not in combat.
function Alt.Base(panel)
  local P = Parts()
  if not (panel and P and panel:IsVisible() and P.MailboxOpen()) then return false end
  if model.src ~= "inbox" or not BV.Active(panel) or not Alt.Shows(panel) then return false end
  if ns.CollectTab.IsRunning() or Mail().IsBusy() or Alt.running then return false end
  if P.RV.Arranging(panel) then return false end
  if type(InCombatLockdown) == "function" and InCombatLockdown() then return false end
  return true
end

-- A tile's return clicked: the facts read at the click, every mail named
-- noted for the service with a stamp of the inbox, then the question.
function Alt.Start(kind)
  local panel = BV.panel
  if Alt.open then
    -- One question at a time; the game's own word where it has one, so a
    -- box that went without telling cannot hold the next one back.
    if Parts().RV.ReturnAsked() ~= false then return end
    Alt.open = false
  end
  if not Alt.Base(panel) then return end
  if not kind or kind.n <= 0 or kind.gold or kind.sect.look == 2 or kind.look == 3 then return end
  if kind.cod and not Alt.COD then return end
  if not BV.Current(kind) then return ns.CollectTab.RequestRefresh(panel) end
  local want = Mail().ReturnWant(Alt.want)
  local F = Alt.ask
  if not F then
    F = Alt.NewFacts()
    Alt.ask = F
  end
  Alt.Facts(kind, F, want)
  if F.qn == 0 then return end
  GameTooltip:Hide()
  if Alt.Asks(F) then return Alt.Ask(F) end
  -- No question: the service checks again, right before the command, that
  -- the mail still holds nothing but this item (Mail.OnlyItem).
  want.only, want.onlyId, want.onlyName = true, kind.id, kind.name
  Alt.Send()
end

function Alt.Ask(F)
  local text = Alt.AskText(F)
  Alt.serial = Alt.serial + 1
  local serial = Alt.serial
  Alt.open, Alt.panel = true, BV.panel
  local shown = Parts().RV.ConfirmReturn(text,
    function() Alt.Accept(serial) end,
    function() Alt.Hidden(serial) end)
  if not shown then Alt.open = false end
end

-- The box went (answered, Escape, taken down).
function Alt.Hidden(serial)
  if serial == Alt.serial then Alt.open = false end
end

-- The question taken down, unanswered, and any answer to it sent nothing:
-- the mailbox closing, combat, the bag going, the Options switch off.
function Alt.Hide()
  Alt.serial = Alt.serial + 1
  if not Alt.open then return end
  Alt.open = false
  local P = Parts()
  if P and type(StaticPopup_Hide) == "function" then StaticPopup_Hide(P.RV.POPUP_RETURN) end
end

-- Return answered: only the question standing now, and only while
-- everything it was asked under still holds. The mails go as it named
-- them; the service looks at each again before it goes.
function Alt.Accept(serial)
  if serial ~= Alt.serial then return end
  Alt.serial = Alt.serial + 1
  Alt.open = false
  local M = Alt.M()
  if not (M and M.Wanted()) then return end
  local panel = Alt.panel
  if not Alt.Base(panel) then
    -- Nothing is sent; the title bar says why.
    local busy = ns.CollectTab.IsRunning() or Mail().IsBusy() or Alt.running
    Parts().StatusOutcome(L()[busy and "STATUS_RETURN_BUSY" or "STATUS_RETURN_GONE"], "warning")
    return
  end
  Alt.Send()
end

-- The question stands only while what it names is on screen: the bag, on
-- the inbox, with the marks eligible (CollectTab's M.Sync asks after every
-- pass). Otherwise it goes, unanswered, as on the bag switching off.
function Alt.Watch(eligible)
  if not Alt.open then return end
  if eligible and model.src == "inbox" and Alt.Shows(Alt.panel) and BV.Active(Alt.panel) then return end
  Alt.Hide()
end

function Alt.Send()
  local P, M = Parts(), Alt.M()
  local want = Alt.want
  Alt.running, Alt.panel = true, BV.panel
  if M then M.actAt = GetTime() end
  want.onStep = Alt.Step
  P.StatusActivity(L()("STATUS_REMAINING", want.n))
  Mail().ReturnMails(want, Alt.Done)
end

-- One mail gone: how many are left, in the title bar.
function Alt.Step(returned, n)
  Parts().StatusActivity(L()("STATUS_REMAINING", (n or 0) - (returned or 0)))
end

-- The sweep's end: the title bar says how it ended (all back; stopped,
-- how far and why; the mailbox closed), chat keeps the receipt of what
-- went, and the bag is drawn again once. A further return waits CALM.
-- `returned` is only what the mailbox showed going; `unsure`, one more may
-- have gone that it never showed (a command out when the sweep stopped):
-- then every line says "at least", never a number that may be wrong.
function Alt.Done(returned, status, n, _, unsure)
  local P, M, L0 = Parts(), Alt.M(), L()
  Alt.running = false
  Alt.want.onStep = nil
  if M then M.actAt = GetTime() end
  returned, n = tonumber(returned) or 0, tonumber(n) or 0
  if status == "done" then
    P.StatusOutcome(L0("STATUS_RETURNED_N", returned))
  elseif status == "closed" then
    P.StatusMailboxClosed()
  elseif status == "timeout" then
    P.StatusActivity(nil)
    ns.Print(L0["MSG_MAIL_TIMEOUT"])
  elseif unsure and returned == 0 then
    P.StatusOutcome(L0("STATUS_RETURN_UNSURE_NONE", n), "warning")
  elseif unsure then
    P.StatusOutcome(L0("STATUS_RETURN_UNSURE", returned, n), "warning")
  elseif status == "changed" or status == "refused" or status == "error" then
    local key = (status == "refused" and "STATUS_RETURN_REFUSED") or (status == "error" and "STATUS_RETURN_ERROR")
      or "STATUS_RETURN_CHANGED"
    P.StatusOutcome(L0(key, returned, n), "warning")
  else
    P.StatusActivity(nil)
  end
  if unsure and returned == 0 then
    ns.Print(L0("MSG_RETURNED_UNSURE_NONE", ns.Plural("COUNT_MAILS", n)))
  elseif unsure then
    ns.Print(L0("MSG_RETURNED_UNSURE", returned, ns.Plural("COUNT_MAILS", n)))
  elseif returned > 0 then
    if returned >= n then
      ns.Print(L0("MSG_RETURNED", ns.Plural("COUNT_MAILS", returned)))
    else
      ns.Print(L0("MSG_RETURNED_PART", returned, ns.Plural("COUNT_MAILS", n)))
    end
  end
  local panel = Alt.panel or BV.panel
  if panel then ns.CollectTab.RequestRefresh(panel) end
end

do
  local bus = ns.Events
  if bus and type(bus.Register) == "function" then
    -- Combat: the question goes, unanswered.
    bus.Register("PLAYER_REGEN_DISABLED", Alt.Hide)
  end
end
