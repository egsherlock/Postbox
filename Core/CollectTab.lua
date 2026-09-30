local _, ns = ...

-------------------------------------------------------------
-- Postbox :: the collect screen.
--
-- Five things live here and nothing else does:
--
--   THE VIEW SWITCH   three segments -- mail that still holds something
--                     ("Collect"), mail that is finished ("Done"), and the
--                     unfiltered inbox ("All") -- drawn as plates from the
--                     theme's control-plate tokens.
--   THE MAIL LIST     a virtualised, pooled list. WoW cannot free a frame, so
--                     rows are acquired from a pool and released by hiding
--                     them. Only the rows the viewport can show ever exist.
--   THE TOTALS BANNER earned / spent across the mails currently listed.
--   THE ACTION AREA   the category grid in the to-collect view, the bulk delete
--                     in the done view.
--   THE DETAIL VIEW   an overlay over the screen: header, metadata, body,
--                     attachment slots, action row.
--
-- Two rules govern the whole file.
--
--   NO MAIL COMMANDS. Every mail command is a round trip and the server handles
--   one at a time; ns.MailService owns the handshake, the descending-index
--   invariant, take verification and the timeout that stops a run instead of
--   advancing past it. Nothing here calls TakeInboxItem, TakeInboxMoney,
--   DeleteInboxItem, ReturnInboxItem, AutoLootMailItem or CheckInbox. What
--   stays here is what a status code cannot carry: which words the player sees,
--   which confirmation to raise, and the bookkeeping a run needs to report
--   honestly at the end.
--
--   NO COLOUR, FONT OR METRIC OF ITS OWN. Core/Theme.lua is the design system;
--   every surface, text role, gap and measured width comes from it. Anything
--   whose caption comes from a locale is sized from the rendered string, never
--   from a constant tuned to English.
--
-- That now holds without exception. GetInboxText was the last mail API called
-- from this file -- the detail view needed it for a mail's body -- and it was
-- the one that least deserved an exception: it reads like a getter and is a
-- command that marks the mail read. It is ns.MailService.FetchMailBody now, and
-- the rule above has no "except".
-------------------------------------------------------------

ns.CollectTab = ns.CollectTab or {}
local CT = ns.CollectTab

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local format, concat = string.format, table.concat

-- Cross-module dependencies are resolved at call time, never at file scope, so
-- a TOC reorder degrades instead of erroring at load.
local function Mail()    return ns.MailService end
local function Helpers() return ns.Helpers end
local function Labels()  return ns.CATEGORY_LABELS or {} end
local function L()       return ns.L end
local function Th()      return ns.Theme end

-- What a row says in place of "Auction House" for each auction outcome, and
-- the palette role it says it in: a sale is good news, a win is neutral,
-- an expiry wants a look, a cancellation is the player's own doing.
local AUCTION_OUTCOME = {
  sold     = { key = "ROW_AH_SOLD",     role = "positive" },
  bought   = { key = "ROW_AH_BOUGHT",   role = "info" },
  expired  = { key = "ROW_AH_EXPIRED",  role = "warning" },
  canceled = { key = "ROW_AH_CANCELED", role = "textSecondary" },
}

-- The template's scroll bar, put where a modern one goes: pinned inside the
-- container's right edge with the rows ending just beside it, instead of
-- hanging six pixels outside the scroll frame with a hand's width of empty
-- track between it and the content. And hidden when there is nothing to
-- scroll -- the template's own scrollBarHideable flag, honoured by its
-- OnScrollRangeChanged, so no handler of ours is involved. Both host skins
-- and the Postbox style flatten the bar's art; this only decides where it is.
local function PinScrollBar(scroll, container)
  if not scroll then return end
  scroll.scrollBarHideable = 1
  Th().SlimScrollBar(scroll, container)
end

-------------------------------------------------------------
-- Constants
--
-- Hoisted to module scope: the layout code runs on every resize and the row
-- binder runs once per visible row per refresh, so neither rebuilds a table.
-------------------------------------------------------------

-- ONE TAXONOMY, AND IT IS ABOUT CONTENT, NEVER ABOUT THE READ FLAG.
--
-- A mail is either still holding something -- money, attachments, or simply the
-- fact that it has not been opened -- or it is finished with. That is the split
-- the first two segments make and the split the tab counts count.
-- Mail().IsReadPersistent is the single predicate behind both.
--
-- The screen used to say this two ways at once: the segments read "Mail" and
-- "Read", which sound like a read/unread split, while the summary above them
-- counted the read FLAG. Both numbers were correct and they disagreed on screen,
-- which is the worst of both. The read flag survives in exactly two places now,
-- and neither is a headline: the per-row dot, and the detail view's metadata.
--
-- The third segment applies no filter at all. It is not a third KIND of mail --
-- it is the union of the other two, in the same order -- so nothing in this file
-- branches on "the all view" to decide what a mail IS. Everything a row's
-- appearance or behaviour depends on comes from that row's own verdict
-- (`row.mailDone`), which is why a done mail carries its delete control and
-- opens on any click whether it is being shown under "Done" or under "All".
-- Two views. The inbox lists every mail: what still holds something first,
-- then -- under a divider that carries their delete -- the read mails with
-- nothing left. (Collect / Done / All used to be three views of the same box,
-- two of them overlapping.) History is what Postbox took out.
local VIEW_COLLECT = "collect"
-- The divider's place in the inbox list. Inbox indices start at 1, so 0 can
-- never name a mail; everything that walks the list skips it.
local DIVIDER = 0
-- A week of what Postbox collected here (Core/MailMemory.lua, 2c). Not a part
-- of the inbox, so not in the counts' arithmetic: an icon after the three.
local VIEW_HISTORY = "history"
-- The read mail's own segment, when the player asks for read mail in a tab of
-- its own rather than under the divider (MailboxUI.GetReadMode "tab").
local VIEW_DONE = "done"

-- What a finished mail does and where it goes: the read-mail mode, the pinned
-- divider, auto-delete, the quality mark. One table, for the file's local count.
local RV = {}
-- Another character's box in this list (section "Other characters").
local AV = {}

function RV.Mode()
  local UI = ns.MailboxUI
  return UI and type(UI.GetReadMode) == "function" and UI.GetReadMode() or "fold"
end

-- link -> the crafting quality mark an item link carries in its name (the
-- atlas escape the client puts there for tiered reagents and crafted gear),
-- or nil. Read from the link rather than built from an atlas name: the name
-- has changed between expansions and the link is always the client's own.
function RV.MarkOf(link)
  if type(link) ~= "string" then return nil end
  return link:match("|A:Professions%-[^|]*|a") or link:match("|A:[^|]*[Qq]uality[^|]*|a")
end

-- The mark for a mail's attachment: its own link once the body is loaded, the
-- item's generic link by id before (tiered reagents are a different item per
-- tier, so the generic link carries the right mark).
function RV.QualityMark(index, slot)
  local link = GetInboxItemLink(index, slot)
  if not link then
    local _, itemID = GetInboxItem(index, slot)
    if itemID and C_Item and type(C_Item.GetItemInfo) == "function" then
      local _, generic = C_Item.GetItemInfo(itemID)
      link = generic
      -- An uncached answer is a request to the server; /postbox debug counts
      -- them while an open is being measured (Postbox.lua, 5b).
      local perf = ns.Perf
      if perf and perf.cur and perf.ItemAsk then perf.ItemAsk(generic ~= nil) end
    end
  end
  return RV.MarkOf(link)
end

-- Where a quality mark goes: on the corner of the item's icon or not
-- (MailboxUI.GetQualityIcon), and beside the item's name "before" it,
-- "after" it or "off" (MailboxUI.GetQualityName) -- two settings, either
-- without the other.
function RV.MarkOnIcon()
  local UI = ns.MailboxUI
  if not (UI and type(UI.GetQualityIcon) == "function") then return true end
  return UI.GetQualityIcon()
end

function RV.NameMark()
  local UI = ns.MailboxUI
  return UI and type(UI.GetQualityName) == "function" and UI.GetQualityName() or "off"
end

function RV.MarkOnName()
  return RV.NameMark() == "after"
end

function RV.MarkBefore()
  return RV.NameMark() == "before"
end

-- Whether a row wears the mark anywhere, so whether it is worth finding.
function RV.MarkAny()
  return RV.MarkOnIcon() or RV.NameMark() ~= "off"
end

-- "Before the name": the mark drawn as the item's link draws it inline --
-- the size its own markup gives it, |A:name:17:15::1|a, 17 tall and 15
-- wide, fitted into that box whatever another mark asks for -- and the
-- gap after it. Every row of a list keeps that room before the subject
-- (RV.Place, s.markW), so the names start on one line down the list
-- whether or not a row's item has a mark: 17 units of the subject.
RV.NAME_MARK_W, RV.NAME_MARK_H, RV.NAME_MARK_GAP = 15, 17, 2

-- The room a row keeps before its subject for the mark: nothing unless the
-- player chose "Before the name".
function RV.NameMarkRoom()
  if not RV.MarkBefore() then return 0 end
  return RV.NAME_MARK_W + RV.NAME_MARK_GAP
end

-- row, mark[, parent, anchor] -> the mark before the item's name, or
-- nothing: its right edge the gap before `anchor`'s left (the row's
-- subject), where RV.Place leaves it room, and shown and hidden with the
-- subject there. On a texture of `parent`'s (the row), made on first use:
-- most rows never carry one. The atlas and its size are set again only
-- when the mark changes.
function RV.PaintNameMark(row, mark, parent, anchor)
  -- A row with no mark wears no mark after its name either: a row bound
  -- to no mail at all (Mail Memory's heading) is never placed to say so.
  if not mark then RV.HideTail(row) end
  local atlas = (type(mark) == "string" and RV.MarkBefore()) and mark:match("|A:([^:|]+)") or nil
  local tex = row.QualityName
  if not atlas then
    if tex then
      tex.__pbOn = false
      tex:Hide()
    end
    return
  end
  if not tex then
    tex = (parent or row):CreateTexture(nil, "ARTWORK")
    tex:SetPoint("RIGHT", anchor or row.Subject, "LEFT", -RV.NAME_MARK_GAP, 0)
    row.QualityName = tex
  end
  if tex.__pbAtlas ~= atlas then
    tex.__pbAtlas = atlas
    tex:SetAtlas(atlas, false)
    local h, w = mark:match("|A:[^:|]+:(%d+):(%d+)")
    h, w = tonumber(h) or 0, tonumber(w) or 0
    if h <= 0 or w <= 0 then h, w = RV.NAME_MARK_H, RV.NAME_MARK_W end
    local k = min(1, RV.NAME_MARK_W / w, RV.NAME_MARK_H / h)
    tex:SetSize(w * k, h * k)
  end
  tex.__pbOn = true
  tex:Show()
end

-- atlas -> the art the icon's corner wears for a mark, and whether that art
-- is square. The item button's own art for the mark where the client has
-- it: the "-Inv" form, the mark in the corner of a 33 x 28 piece with a
-- soft shade of its own running into the icon, as the bags draw it. Else
-- the mark's small form, else its own atlas, both square. Found once per
-- atlas name and kept, so a bind with a mark builds nothing; the answer is
-- Theme.AtlasExists's, which is kept per name too. The quality marks are a
-- handful of names; past RV.ART_MAX both tables are emptied and start
-- again, so they stay bounded whatever links come through.
RV.art, RV.artSquare, RV.artN, RV.ART_MAX = {}, {}, 0, 32

function RV.MarkArt(atlas)
  local known = RV.art
  local art = known[atlas]
  if art then return art, RV.artSquare[atlas] end
  if RV.artN >= RV.ART_MAX then
    for key in pairs(known) do known[key] = nil end
    for key in pairs(RV.artSquare) do RV.artSquare[key] = nil end
    RV.artN = 0
  end
  local T = Th()
  local base = (atlas:gsub("ChatIcon", "Icon"))
  art = base .. "-Inv"
  local square = not T.AtlasExists(art)
  if square then art = T.FirstAtlas({ base .. "-Small", atlas }) or atlas end
  known[atlas], RV.artSquare[atlas] = art, square
  RV.artN = RV.artN + 1
  return art, square
end

-------------------------------------------------------------
-- The quality mark on an item's icon
--
-- One rule for every item icon Postbox draws -- a mail row's, History's,
-- Mail Memory's, a fan tile, a reading-view tile -- so a mark reads the
-- same on each by construction. The rule is the game's own item buttons'
-- (ItemButtonTemplate's ProfessionQualityOverlay): the mark's item-button
-- art (RV.MarkArt) at its own size on a 37-unit button, 33 x 28, its
-- top-left 3 out and 2 up from the button's. Here that is scaled to the
-- icon, so on every icon the mark takes the share of the corner it takes
-- in the bags: its gem about a third of the icon's width, in the corner,
-- while the stack count keeps the opposite one.
--
-- It overhangs the icon by what the bags' does and never more than 2 units
-- upward, whatever the size: every icon it is drawn on has that room above
-- it inside what holds it (a compact row 4 units, a larger row 8, a fan
-- tile its plate's 3-unit pad), so the mark never rises past its row's top
-- and the list's edge never cuts the first row's.
--
-- RV.MARK_SCALE scales the whole rule, 1 being the bags' proportion; every
-- placement remembers the RV.markGen it was made at, so a change of scale
-- places each mark again where it is next shown. Sizes are not rounded: at UI
-- scale 1 a unit is nearly two screen pixels, too coarse a step to tune a
-- mark this small in.
--
-- The mark stands on a frame over the icon's owner, with the stack count
-- over it: where the two meet on a small icon, the count stays whole.
-------------------------------------------------------------

-- The item button's art and where it stands (33 x 28, 3 out and 2 up, on a
-- 37-unit button), and the most the mark ever rises above an icon.
RV.MARK = { W = 33, H = 28, BUTTON = 37, OUT_X = 3, OUT_Y = 2, UP_MAX = 2 }
RV.MARK_SCALE, RV.markGen = 1, 0

-- iconSize -> the mark's width and height, and where its top-left stands
-- against the icon's top-left (x right, y up).
function RV.MarkGeometry(iconSize)
  local M = RV.MARK
  local k = (tonumber(iconSize) or 18) / M.BUTTON * RV.MARK_SCALE
  return M.W * k, M.H * k, -min(M.OUT_X, M.OUT_X * k), min(M.UP_MAX, M.OUT_Y * k)
end

-- mark -> the atlas it draws, or nil.
function RV.AtlasOf(mark)
  return type(mark) == "string" and mark:match("|A:([^:|]+)") or nil
end

-- holder -> a mark on that frame, hidden, and its shadow: a soft dark copy
-- just behind it, so the mark reads on light item art.
function RV.NewMark(holder)
  local shadow = holder:CreateTexture(nil, "ARTWORK")
  shadow:SetAlpha(0.6)
  shadow:Hide()
  local mark = holder:CreateTexture(nil, "OVERLAY")
  mark:Hide()
  return mark, shadow
end

-- mark, shadow, icon, iconSize -> both sized and placed on the icon's
-- top-left corner by the rule, square where the mark's art is (RV.ShowMark
-- says which). Placed again only when the icon, its size, the art's shape
-- or the rule changed, so nearly every bind leaves the mark where it is;
-- the icon and its size are kept with the mark for RV.ShowMark.
function RV.PlaceMark(mark, shadow, icon, iconSize)
  local square = mark.__pbSquare and true or false
  if mark.__pbIcon == icon and mark.__pbIconSize == iconSize and mark.__pbGen == RV.markGen
      and mark.__pbPlaced == square then
    return
  end
  mark.__pbIcon, mark.__pbIconSize, mark.__pbGen, mark.__pbPlaced = icon, iconSize, RV.markGen, square
  local w, h, x, y = RV.MarkGeometry(iconSize)
  if square then w = h end
  mark:SetSize(w, h)
  mark:ClearAllPoints()
  mark:SetPoint("TOPLEFT", icon, "TOPLEFT", x, y)
  shadow:SetSize(w + 2, h + 2)
  shadow:ClearAllPoints()
  shadow:SetPoint("CENTER", mark, "CENTER", 0, -1)
end

-- mark, shadow, atlas -> the mark wearing its art (RV.MarkArt) and shown;
-- both hidden for none. The item button's art brings its own shade into
-- the icon, as it does in the bags; square art has the soft dark copy
-- behind it instead, so it reads on light item art. A mark placed for the
-- other shape, or before a retune, is placed again here.
function RV.ShowMark(mark, shadow, atlas)
  if not atlas then
    mark:Hide()
    shadow:Hide()
    return
  end
  local art, square = RV.MarkArt(atlas)
  if mark.__pbArt ~= art then
    mark.__pbArt = art
    mark:SetAtlas(art, false)
    shadow:SetAtlas(art, false)
    shadow:SetVertexColor(0, 0, 0, 1)
  end
  mark.__pbSquare = square
  local icon = mark.__pbIcon
  if icon and (mark.__pbPlaced ~= square or mark.__pbGen ~= RV.markGen) then
    RV.PlaceMark(mark, shadow, icon, mark.__pbIconSize)
  end
  mark:Show()
  if square then shadow:Show() else shadow:Hide() end
end

-- row -> the frame its icon's mark and count stand on, made on first use
-- and shown: a level above the row, so nothing the row draws over its icon
-- covers them, and the mark's overhang above the row is not covered by the
-- row before it.
function RV.IconOverlay(row)
  local holder = row.QualityHolder
  if not holder then
    holder = CreateFrame("Frame", nil, row)
    holder:SetAllPoints(row)
    holder:SetFrameLevel(row:GetFrameLevel() + 2)
    row.QualityHolder = holder
  end
  if not holder:IsShown() then holder:Show() end
  return holder
end

-- row, mark -> the mark on the top-left corner of the row's item icon, in
-- the art an item button wears there where the client has it (RV.ShowMark),
-- or nothing. Created on first use: most rows never carry one.
-- `layout` is the row's arrangement (History's has its own; nil: the mail
-- rows'). The top-left, as every item button puts it: the bottom-right is
-- the stack count's (RV.PaintCount).
function RV.PaintQuality(row, mark, layout)
  local atlas = RV.AtlasOf(mark)
  -- Nothing to mark when the arrangement hides the icon.
  if not (atlas and row.Icon and RV.MarkOnIcon() and (layout or RV.Layout()).shown.icon) then
    if row.Quality then RV.ShowMark(row.Quality, row.QualityShadow, nil) end
    return
  end
  local holder = RV.IconOverlay(row)
  if not row.Quality then row.Quality, row.QualityShadow = RV.NewMark(holder) end
  RV.ShowMark(row.Quality, row.QualityShadow, atlas)
  RV.PlaceMark(row.Quality, row.QualityShadow, row.Icon, row.Icon:GetWidth() or 18)
end

-------------------------------------------------------------
-- The icon's stack count, and the edge of a second card behind it
--
-- As a bag shows it: the first item's count at the icon's bottom-right,
-- white with a black outline, so it reads on the item's art (opaque at any
-- window opacity) whatever the art is. A count of 1 is not written. On a
-- mail holding two items or more, a second card's edge shows behind the
-- icon, 2 up and 2 right: a shape, not a number, so it never reads as part
-- of the count (the Slots figure says how many). Both stay inside the gap
-- before the next column, so the icon's lane keeps its width and every
-- other column stands where it did.
--
-- Nothing for a mail without items (gold alone, a letter), and nothing
-- when the arrangement hides the icon or the player turned the counts off
-- (MailboxUI option iconCounts). The count comes from the slot scan the
-- bind already runs; its text is made once per number (RV.CountText), and
-- the regions are made on first use and only shown or hidden after, so a
-- bind makes nothing.
-------------------------------------------------------------

-- The count's size in the number font: compact icons, the larger icon.
RV.COUNT_FONT, RV.COUNT_FONT_LARGE = 10, 12

-- iconSize -> the count's font size, and where its bottom-right stands
-- against the icon's (x right, y up): at the corner and 2 out past it on a
-- compact icon, whose art a count drawn inside would mostly cover; inside
-- the art on a larger one, as a bag's is. One rule for every item icon: a
-- mail row's, History's, Mail Memory's, a fan tile, a reading-view tile.
function RV.CountGeometry(iconSize)
  if (tonumber(iconSize) or 18) <= 20 then return RV.COUNT_FONT, 2, -1 end
  return RV.COUNT_FONT_LARGE, -2, 1
end

-- fs, icon, iconSize -> the count's string placed by the rule and
-- right-justified, as a bag's count is: its right edge stands on the same
-- line for one digit, two or three, never centred in a box a longer
-- number once made.
function RV.PlaceCount(fs, icon, iconSize)
  local _, x, y = RV.CountGeometry(iconSize)
  fs:SetJustifyH("RIGHT")
  fs:ClearAllPoints()
  fs:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", x, y)
end

-- The stack edge's three layers, outside in: the black key, the grey ring
-- (every other ring's grey, flattened over the fill so it holds at any
-- opacity), the card's own dark face.
RV.STACK_KEY, RV.STACK_RING, RV.STACK_FACE = 0, 0.5, 0.15

function RV.CountOnIcon()
  local UI = ns.MailboxUI
  if not (UI and type(UI.GetOption) == "function") then return true end
  return UI.GetOption("iconCounts") and true or false
end

-- layout -> whether the rows it arranges write counts on their icons.
function RV.CountShown(layout)
  return RV.CountOnIcon() and (layout or RV.Layout()).shown.icon and true or false
end

-- n, layout -> whether the icon writes `n` whole, so a text beside it need
-- not say it again. A shortened count ("1.5k") is not the same number.
function RV.SaysCount(n, layout)
  n = tonumber(n) or 0
  return n > 1 and n < 1000 and RV.CountShown(layout)
end

-- n -> the count as the icon writes it, or nil for none: whole up to three
-- digits (what an 18-unit icon holds), then in thousands, "1k", "1.5k",
-- "12k". Each number's text is made once and kept, bounded as RV.marked is.
RV.counts, RV.countsN, RV.COUNTS_MAX = {}, 0, 256

function RV.CountText(n)
  n = tonumber(n)
  if not n or n <= 1 then return nil end
  local known = RV.counts
  local text = known[n]
  if text then return text end
  if RV.countsN >= RV.COUNTS_MAX then
    for key in pairs(known) do known[key] = nil end
    RV.countsN = 0
  end
  if n < 1000 then
    text = ("%d"):format(n)
  else
    local tenth = floor((n % 1000) / 100)
    if n >= 10000 or tenth == 0 then
      text = ("%dk"):format(floor(n / 1000))
    else
      text = ("%d.%dk"):format(floor(n / 1000), tenth)
    end
  end
  known[n] = text
  RV.countsN = RV.countsN + 1
  return text
end

-- row, count, items[, layout] -> the count of the item on the row's icon
-- and, for `items` of two or more, the stack edge behind it; or neither.
-- `layout` is the row's arrangement (nil: the mail rows').
function RV.PaintCount(row, count, items, layout)
  local icon = row.Icon
  local shown = icon ~= nil and RV.CountShown(layout)
  local text = shown and RV.CountText(count) or nil
  local fs = row.IconCount
  if text then
    -- On the frame the quality mark stands on, over the mark (RV.IconOverlay).
    local holder = RV.IconOverlay(row)
    if not fs then
      fs = holder:CreateFontString(nil, "OVERLAY")
      fs:SetDrawLayer("OVERLAY", 7)
      fs:SetJustifyH("RIGHT")
      fs:SetWordWrap(false)
      fs.__pbOn = false
      row.IconCount = fs
    end
    -- Sized and placed again only when the icon changes size (the row's
    -- mode), by the icons' one rule (RV.PlaceCount): on the larger icon
    -- inside the art, clear of the second line's figures.
    local iconSize = icon:GetWidth() or 18
    local size = RV.CountGeometry(iconSize)
    if fs.__pbSize ~= size then
      fs.__pbSize = size
      local object = Th().FontObject("numberSmall")
      local path = object and object:GetFont()
      fs:SetFont(path or STANDARD_TEXT_FONT, size, "OUTLINE")
      fs:SetTextColor(1, 1, 1, 1)
      RV.PlaceCount(fs, icon, iconSize)
    end
    if fs.__pbText ~= text then
      fs.__pbText = text
      fs:SetText(text)
    end
    if not fs.__pbOn then
      fs.__pbOn = true
      fs:Show()
    end
  elseif fs and fs.__pbOn then
    fs.__pbOn = false
    fs:Hide()
  end

  local stack = shown and (tonumber(items) or 0) >= 2
  local face = row.StackFace
  if stack then
    if not face then
      -- Under the icon (BORDER, below its ARTWORK), so only the edge that
      -- stands out past it shows. Anchored to the icon at both corners, so
      -- it follows the icon's size and place with no work per bind.
      local key = row:CreateTexture(nil, "BORDER", nil, 1)
      local ring = row:CreateTexture(nil, "BORDER", nil, 2)
      face = row:CreateTexture(nil, "BORDER", nil, 3)
      key:SetColorTexture(RV.STACK_KEY, RV.STACK_KEY, RV.STACK_KEY, 1)
      ring:SetColorTexture(RV.STACK_RING, RV.STACK_RING, RV.STACK_RING, 1)
      face:SetColorTexture(RV.STACK_FACE, RV.STACK_FACE, RV.STACK_FACE, 1)
      key:SetPoint("TOPLEFT", icon, "TOPLEFT", 1, 3)
      key:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 3, 1)
      ring:SetPoint("TOPLEFT", icon, "TOPLEFT", 2, 2)
      ring:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 2, 2)
      face:SetPoint("TOPLEFT", icon, "TOPLEFT", 3, 1)
      face:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, 3)
      row.StackKey, row.StackRing, row.StackFace = key, ring, face
      face.__pbOn = false
    end
    if not face.__pbOn then
      face.__pbOn = true
      row.StackKey:Show()
      row.StackRing:Show()
      face:Show()
    end
  elseif face and face.__pbOn then
    face.__pbOn = false
    row.StackKey:Hide()
    row.StackRing:Hide()
    face:Hide()
  end
end

-- row -> its count and stack edge hidden, as a hidden icon's are, until the
-- row is next painted (the arrange mode's drag lifts the icon out of it).
function RV.HideCount(row)
  local fs, face = row.IconCount, row.StackFace
  if fs and fs.__pbOn then
    fs.__pbOn = false
    fs:Hide()
  end
  if face and face.__pbOn then
    face.__pbOn = false
    row.StackKey:Hide()
    row.StackRing:Hide()
    face:Hide()
  end
end

-- text, n -> the text without its trailing "(n)", where it ends in exactly
-- that count (an auction's subject, "Light's Potential (19)"); the text as
-- it was otherwise. Each shortened text is made once and kept (RV.dropped,
-- keyed by the text, which carries its count), so a bind makes nothing;
-- bounded as RV.marked is.
RV.dropped, RV.droppedN, RV.DROPPED_MAX = {}, 0, 256

function RV.DropCount(text, n)
  if type(text) ~= "string" then return text end
  local said = text:match("%((%d+)%)%s*$")
  if not said or tonumber(said) ~= tonumber(n) then return text end
  local known = RV.dropped
  local short = known[text]
  if short then return short end
  if RV.droppedN >= RV.DROPPED_MAX then
    for key in pairs(known) do known[key] = nil end
    RV.droppedN = 0
  end
  short = (text:gsub("%s*%(%d+%)%s*$", ""))
  known[text] = short
  RV.droppedN = RV.droppedN + 1
  return short
end

-- text, mark -> the text with the mark after the item's name and before a
-- trailing "(20)" count, where a chat link draws it. Each marked subject is
-- made once and kept (RV.marked, a table per mark keyed by the text), so a
-- row bind makes nothing: the replacement the pattern needs was a new string
-- every call. A list shows a few dozen marked subjects; past RV.MARKED_MAX
-- every one is dropped and the table fills again, so it stays bounded
-- whatever mail comes through.
RV.marked, RV.markedN, RV.MARKED_MAX = {}, 0, 256

function RV.WithMark(text, mark)
  if not mark or type(text) ~= "string" then return text end
  local byMark = RV.marked[mark]
  local marked = byMark and byMark[text]
  if marked then return marked end
  if RV.markedN >= RV.MARKED_MAX then
    for key in pairs(RV.marked) do RV.marked[key] = nil end
    RV.markedN, byMark = 0, nil
  end
  if not byMark then
    byMark = {}
    RV.marked[mark] = byMark
  end
  local safe = mark:gsub("%%", "%%%%")
  local n
  marked, n = text:gsub("%s*(%(%d+%))%s*$", " " .. safe .. " %1", 1)
  if n == 0 then marked = text .. " " .. mark end
  byMark[text] = marked
  RV.markedN = RV.markedN + 1
  return marked
end

-- "After the name": the mark always shows whole. A subject that carries it
-- and fits is drawn as it is, one string, as the item's link has it. One
-- that does not fit is drawn in two: the name, shortened with the ellipsis,
-- and after it, on a string of the row's own (row.QualityTail, made on
-- first use), the mark and whatever followed it (a "(20)" count, History's
-- "x5  +2") in full. Only the row that needs it changes; no room is kept on
-- a row whose item has no mark, or on one that fits.
--
-- text -> { name, tail } where the text carries a quality mark after a
-- name, or false. Found once per marked text and kept (RV.cuts), bounded as
-- RV.marked is; only texts with an atlas in them are ever looked up.
RV.cuts, RV.cutsN, RV.CUT_MAX = {}, 0, 256

function RV.Cut(text)
  local cuts = RV.cuts
  local cut = cuts[text]
  if cut ~= nil then return cut end
  if RV.cutsN >= RV.CUT_MAX then
    for key in pairs(cuts) do cuts[key] = nil end
    RV.cutsN = 0
  end
  local at = text:find("|A:Professions%-[^|]*|a") or text:find("|A:[^|]*[Qq]uality[^|]*|a")
  cut = false
  -- A whole link or a coloured text (a Mail Memory row can name its item
  -- by its link) is not cut: one half would carry an escape the other
  -- closes. It is drawn as before.
  if at and at > 1 and not text:find("|H", 1, true) and not text:find("|c", 1, true) then
    local name = text:sub(1, at - 1):match("^(.-)%s*$")
    if name ~= "" then cut = { name = name, tail = text:sub(#name + 1) } end
  end
  cuts[text] = cut
  RV.cutsN = RV.cutsN + 1
  return cut
end

-- row -> its tail string hidden, if it has one showing.
function RV.HideTail(row)
  local tail = row.QualityTail
  if tail and tail.__pbOn then
    tail.__pbOn = false
    tail:Hide()
  end
end

-- row, fs, tailText[, parent] -> the row's tail string, made on `parent`
-- the first time, in the subject's own look (whatever a skin or the row's
-- state gave it) and saying `tailText`; and its width.
function RV.Tail(row, fs, tailText, parent)
  local tail = row.QualityTail
  if not tail then
    tail = (parent or row):CreateFontString(nil, "ARTWORK")
    tail:SetWordWrap(false)
    tail:SetJustifyH("LEFT")
    tail.__pbOn = false
    tail:Hide()
    row.QualityTail = tail
  end
  local path, size, flags = fs:GetFont()
  if path and (tail.__pbPath ~= path or tail.__pbSize ~= size or tail.__pbFlags ~= flags) then
    tail:SetFont(path, size, flags or "")
    tail.__pbPath, tail.__pbSize, tail.__pbFlags = path, size, flags
  end
  tail:SetTextColor(fs:GetTextColor())
  if fs.GetShadowOffset and tail.SetShadowOffset then
    tail:SetShadowOffset(fs:GetShadowOffset())
    tail:SetShadowColor(fs:GetShadowColor())
  end
  if tail:GetText() ~= tailText then tail:SetText(tailText) end
  return tail, Th().TextWidth(tail)
end

-- row, fs, width, text[, parent] -> fits `text` into the row's subject
-- string `fs` as Theme.FitText does, the string its own tooltip owner, and
-- answers whether it was cut -- with the rule above for a mark after the
-- name. A row drawn in two remembers it for its text and width, and binding
-- it again goes straight to the two strings, each fitted as it was, unless
-- the tail no longer measures what it did (a re-font, a new scale): then
-- the whole text is tried again. A row that fits costs one fit, as before.
function RV.FitSubject(row, fs, width, text, parent)
  local T = Th()
  local cut = RV.MarkOnName() and type(text) == "string" and text:find("|A:", 1, true)
    and RV.Cut(text) or nil
  if not cut then
    RV.HideTail(row)
    return T.FitText(fs, width, text, fs)
  end
  local tail, tailW
  if row.__pbCutText == text and row.__pbCutW == width then
    tail, tailW = RV.Tail(row, fs, cut.tail, parent)
    if tailW ~= row.__pbCutTail then tail = nil end
  end
  if not tail then
    row.__pbCutText = nil
    if not T.FitText(fs, width, text, fs) then
      RV.HideTail(row)
      return false
    end
    tail, tailW = RV.Tail(row, fs, cut.tail, parent)
    row.__pbCutText, row.__pbCutW, row.__pbCutTail = text, width, tailW
  end
  local room = max(width - tailW, 1)
  local short = T.FitText(fs, room, cut.name, nil)
  fs.__pbOverflowText = short and text or nil
  tail:ClearAllPoints()
  tail:SetPoint("LEFT", fs, "LEFT", min(T.TextWidth(fs), room), 0)
  tail.__pbOn = true
  tail:Show()
  return true
end

-- The category vocabulary is the domain's; the order is presentation. "all"
-- leads and spans the full width -- deliberate hierarchy, not an accident.
-- "alts" -- mail from the player's own characters -- takes the sixth cell of
-- the two rows of three, which stood empty.
local CATEGORY_ORDER = { "all", "bought", "sold", "canceled", "expired", "other", "alts" }
local GRID_COLUMNS = 3

-- The window's persisted minimum is 480 wide; the shell's content inset takes
-- ~20 of it. Used only as the fallback when a container's anchored width still
-- reads zero -- during the very first layout pass, before the window has been
-- sized. Laying out against this is what stops the grid visibly jumping into
-- place a frame after the window opens.
local FALLBACK_PANEL_WIDTH = 460

-- Mail row geometry. The stride is what the virtualiser divides by, so it is
-- the row plus its separating gap and nothing else.
--
-- Two sets of sizes, one per layout: the standard two-line row, and the compact
-- single-line row the `compactRows` option asks for. Everything here is a SIZE
-- and never a position -- ApplyRowMode is the only place that decides which set
-- a row is wearing, and RowMetrics is the only place that decides how tall it
-- makes the row.
local ROW_GAP = 2
local ROW_INDICATOR = 8
local ROW_ICON = 28
local ROW_ICON_COMPACT = 18
local ROW_DELETE = 20
local ROW_DELETE_COMPACT = 16
-- The stuck marker: a warning triangle standing in the read mark's place
-- (RV.PaintDot), one size in both row layouts, as the dot is. Small on
-- purpose: it appears on the handful of rows the server refused and must
-- read as an annotation on the row, not as a control; centred on the dot,
-- it keeps clear of the lane lines either side of the dot's column.
local ROW_WARNING = 11

-- The compact row's height, and NOT a fraction of Theme.Metrics.rowHeight: this
-- is the height at which one line of the small font sits centred beside an 18px
-- icon, and a fraction of a metric someone later retunes would quietly stop
-- being that. It is a hair under 60% of the standard 44.
local COMPACT_ROW_HEIGHT = 26

-- The most of a compact row's text area its right-hand columns may claim. The
-- sender and the subject are what a mailbox is scanned by; the gold, the slots
-- and the expiry annotate them, and an annotation may not crowd out the thing
-- it annotates.
local COMPACT_META_SHARE = 0.45

-- The standard row's meta line separator.
local ROW_META_JOIN = "  |  "

-- A row says how long a mail has left only when that is short: "30d" on
-- every row of a full inbox was the one figure nobody read, and the one
-- that mattered -- a mail about to go -- looked like all the others.
local EXPIRY_SOON_DAYS = 3

-- Category grid: the full-width primary, then two rows of three.
-- The primary matches the Send tab's Send button exactly: the two tabs'
-- bottom-most control is the same control in both, and reads as such.
local GRID_PRIMARY_HEIGHT = 28
local GRID_BUTTON_HEIGHT  = 26

-- The sender column of a mail row: as wide as the widest auction outcome in the
-- player's own language ("AH Expired" in English), MEASURED rather than tuned,
-- so every subject starts on the same line down the list. A name longer than
-- that is cut and the row's tooltip carries it whole. The floor and ceiling are
-- for a locale whose four labels are unusually short or long.
local SENDER_MIN, SENDER_MAX = 48, 140

-- The addon's own white tile: a UI pack's loose-file overrides can replace
-- art at Blizzard paths, and a structural fill must survive that (see
-- Lib/UI/Theme.lua). Glyph art like the empty-slot backpack stays native on
-- purpose -- it SHOULD follow whatever the player's base UI looks like.
local WHITE = "Interface\\AddOns\\Postbox\\Media\\white8x8.tga"
local EMPTY_SLOT_ART = "Interface\\PaperDoll\\UI-Backpack-EmptySlot"

-- Art, in preference order, PROBED and never assumed -- SetAtlas with a name the
-- client does not have does not error, it clears the texture, which would leave
-- a silent hole exactly where a control or a warning should be. Same probe
-- Core/RecipientManager.lua uses for the favourite star.
--
-- Each family falls back to a bare character in the same tone: a glyph that
-- renders on every client, in every locale, and needs no artwork at all.
--
-- The delete control used to be Interface\Buttons\UI-GroupLoot-Pass-Up drawn at
-- the control's full size. That file is a group-loot BUTTON, not a glyph: its
-- art fills its own square edge to edge, so at 20px it read as a solid red tile
-- rather than as a small X -- and it was the only red object on an otherwise
-- neutral row. A close/remove atlas is a glyph on transparency, which is what
-- this control wanted all along.
local DELETE_ATLASES = { "uitools-icon-close", "transmog-icon-remove", "common-icon-redx" }
local DELETE_GLYPH = "\195\151"   -- U+00D7 MULTIPLICATION SIGN
-- The refusal marker's candidates are Theme.AtlasSets.warning, NOT a list of
-- this file's own: the mailbox memory draws the same marker, and a copy here
-- would let the two screens land on different art on a client that has only the
-- second choice. Delete is this screen's alone and stays local.
local WARNING_GLYPH = "!"

-- The glyph is inset inside the control on every side. THE CONTROL IS THE HIT
-- AREA and the glyph is what the hit area contains: shrinking the art is what
-- turns a tile into a mark, and doing it by shrinking the BUTTON would have made
-- a 20px target into a 14px one.
local DELETE_GLYPH_INSET = 3

local function Clear(t)
  for i = #t, 1, -1 do t[i] = nil end
end

-- candidates -> the first name this client actually has, or nil. Theme's, and
-- memoised per NAME there, so a family shared with another screen is probed once
-- for the session and both screens land on the same art. Reached through Th()
-- like every other theme call in this file, so nothing here depends on load
-- order.
local function ProbeAtlas(candidates)
  return Th().FirstAtlas(candidates)
end

-------------------------------------------------------------
-- Talking to the shell
--
-- The screen never reaches into the window's internals. It asks the shell to
-- render a status line and, failing that, writes the one named field the skin
-- contract already guarantees exists. It publishes its own run state instead of
-- parking it on the shell's shared table, which is what used to couple the two
-- in both directions.
-------------------------------------------------------------

-- The shell layers the status line: an activity is transient and belongs to a
-- run in progress, an outcome is sticky and is what the run ended up doing.
-- Keeping them apart is what stops an unrelated inbox update overwriting
-- "Incomplete: 3 left" a fraction of a second after it appears. `tone` is a
-- palette token.
local function WriteStatus(setter, text, tone)
  local UI = ns.MailboxUI
  if not UI then return end
  if type(UI[setter]) == "function" then
    UI[setter](text, tone)
    return
  end
  -- No layered status on this shell: write the one named field the skin
  -- contract guarantees, and let it take the text over.
  local label = UI._frame and UI._frame.Status
  if label and type(label.SetText) == "function" then label:SetText(text) end
end

local function StatusActivity(text, tone)
  WriteStatus("SetStatusActivity", text, tone)
end

local function StatusOutcome(text, tone)
  WriteStatus("SetStatusOutcome", text, tone)
end

-- The shell's idle line reports stuck mail and nothing else, and a take the
-- server refused may change nothing in the inbox at all -- so there is no
-- MAIL_INBOX_UPDATE to recompute it on. The two single-mail paths therefore say
-- so directly. A run does not: its outcome owns the status line for the rest of
-- the visit, and it asks the domain for an inbox refresh when it ends.
--
-- This is not new event traffic. It is the same recomputation the shell already
-- runs on every inbox update, asked for at the one moment its answer changed.
local function RefreshIdleSummary()
  local UI = ns.MailboxUI
  if UI and type(UI.UpdateStatusSummary) == "function" then UI.UpdateStatusSummary() end
end

-- The mailbox interaction. ns.MailService owns the question -- it is the module
-- that gates every command on the answer, and a second copy here could disagree
-- with the one that actually decides. This is the same "open unless both the
-- client and the shell say closed" rule, reached through the service.
local function MailboxOpen()
  local service = Mail()
  if service and type(service.IsMailboxOpen) == "function" then
    return service.IsMailboxOpen() and true or false
  end
  local UI = ns.MailboxUI
  if UI and type(UI.IsMailboxOpen) == "function" then return UI.IsMailboxOpen() end
  if UI and UI._state then return UI._state.mailboxOpen == true end
  return true
end

-- "The mailbox closed" is the one outcome that used to be swallowed everywhere
-- it could occur: the service returns "closed", the caller returned, and the
-- button appeared to do nothing at all. Every path that can end that way now
-- says so on the status line, which also means a client that reported "closed"
-- wrongly would be visibly wrong instead of silently broken.
local function StatusMailboxClosed()
  StatusOutcome(L()["STATUS_STOPPED"], "warning")
end

-- The client's own word for "delete", already localised for every locale it
-- ships. The addon key is a fallback for a client that somehow lacks it.
local function DeleteLabel()
  if type(DELETE) == "string" and DELETE ~= "" then return DELETE end
  return L()["BTN_DELETE_ALL_DONE"]
end

local function ShowTabCounts()
  local UI = ns.MailboxUI
  -- Default on when the option plumbing has not loaded yet.
  if not UI or type(UI.GetOption) ~= "function" then return true end
  -- The preview window (MailboxUI, 5c) has no inbox to count.
  if UI._state and UI._state.preview then return false end
  return UI.GetOption("showTabCounts") and true or false
end

-- The third segment. Collect and Done are the two halves of the inbox and
-- always exist; All is their union, which some players read as one screen
-- too many. Default on -- it is what the screen has always offered.
-- The stuck filter: the title bar's "Stuck: N", clicked, narrows the inbox
-- to the mails the server refused. Off by itself when nothing is stuck.
local function StuckOnly(panel)
  return panel and panel._stuckOnly == true
end

-- The category sweeps under the full-width Collect button: the six built in
-- and a character group's own, all or none. Default on, for the same reason
-- as the All segment; off gives the list their rows.
local function ShowCategoryButtons()
  local UI = ns.MailboxUI
  if not UI or type(UI.GetOption) ~= "function" then return true end
  return UI.GetOption("showCategoryButtons") and true or false
end

-- The totals band under the list: default on, as the option is. Off, the
-- stack under the list has no band (RV.StackBlocks) and the floor none
-- either (CT.MinPanelHeight).
function RV.ShowTotals()
  local UI = ns.MailboxUI
  if not UI or type(UI.GetOption) ~= "function" then return true end
  return UI.GetOption("showTotals") and true or false
end

-- Default OFF when the option plumbing has not loaded yet: a plain click that
-- collects is the mapping every other part of this screen was written around,
-- and the destructive-looking surprise is the other way round.
local function PreviewOnClick()
  local UI = ns.MailboxUI
  if not UI or type(UI.GetOption) ~= "function" then return false end
  return UI.GetOption("previewOnClick") and true or false
end

-- Default ON when the option plumbing has not loaded yet, as the option is.
local function CompactRows()
  local UI = ns.MailboxUI
  if not UI or type(UI.GetOption) ~= "function" then return true end
  return UI.GetOption("compactRows") and true or false
end

-- THE answer to "how tall is a mail row", and the only one.
--
-- The row builder, the binder's column widths, the virtualiser's visible-count
-- and offset maths, the scroll child's height and the option toggle's
-- scroll-position preservation all take the mode, the height and the stride
-- from here in one call. A second copy of that arithmetic anywhere would be a
-- copy that can disagree by a pixel or two -- which is invisible at the top of
-- the list and, a screenful down, is rows creeping out of the viewport the
-- scroller thinks it filled.
local function RowMetrics()
  local compact = CompactRows()
  local height = compact and COMPACT_ROW_HEIGHT or Th().Metrics.rowHeight
  return compact, height, height + ROW_GAP
end

-------------------------------------------------------------
-- The screen's floor
--
-- A mailbox that can only show two rows is a peephole, not a list: every answer
-- to "what is in here" costs a scroll, and the scroll bar is taller than the
-- thing it scrolls. So the list claims a minimum of its own, the shell adds the
-- fixed furniture and the window's own chrome to it (Core/MailboxUI.lua's
-- MinWindowHeight takes the taller of this and the compose screen's demand), and
-- the window cannot be dragged -- or restored from saved variables -- below it.
--
-- The minimum is WHOLE ROWS OF THE ROW SIZE ON SCREEN: five compact rows, or
-- three larger ones -- the same judgement in the two densities, enough rows
-- that scrolling continues something rather than being the only way to see
-- anything. (It was once one number for both layouts; whole rows in every
-- combination won, 1.37.) The two land two pixels apart with today's heights
-- (138 and 136), so a window standing on its floor moves by that much when
-- the row size is switched -- Core/MailboxUI.lua's FollowFloor carries it.
local COMPACT_MIN_ROWS  = 5
local STANDARD_MIN_ROWS = 3

-- N rows occupy N heights AND the N-1 gaps between them -- the same arithmetic
-- the virtualiser positions them with. N * height alone leaves the last row
-- clipped by exactly the gaps it forgot, which is the difference between five
-- rows fitting and four rows plus a sliver.
local function RowsHeight(rows, height)
  return rows * height + (rows - 1) * ROW_GAP
end

-- The same arithmetic for a list's content: n rows at this pitch are n rows
-- and the n-1 gaps between them. The list used to be n pitches tall, a
-- trailing gap after the last row that nothing needed -- and a list that
-- exactly filled its floor then scrolled by those two pixels, bar and all.
function RV.ListHeight(n, stride)
  if n <= 0 then return 0 end
  return n * stride - ROW_GAP
end

-- The scroll ends where that height ends. The client measures a scroll child
-- by everything drawn in it, and a row's quality mark reaches past the row's
-- foot: on the list's last row it reached past the list's, and the list
-- scrolled that much further (six pixels at compact size), leaving air under
-- the last row -- and a list that exactly fits showed a scroll bar. So after
-- the template has written the client's range into the bar, the range is
-- held to the scroll child's own height less the view, rounded down as the
-- template rounds the client's. It only ever lowers it. Hooked on
-- OnScrollRangeChanged of the Mail tab's list and of Mail Memory's (through
-- CT.RowRules), whose rows carry the same mark.
function RV.HoldRange(scroll)
  local child = scroll and scroll:GetScrollChild()
  local bar = scroll and scroll.ScrollBar
  if not (bar and child) then return end
  local most = max(0, floor((child:GetHeight() or 0) - (scroll:GetHeight() or 0)))
  local low, high = bar:GetMinMaxValues()
  if (high or 0) > most then bar:SetMinMaxValues(low or 0, most) end
  if (scroll:GetVerticalScroll() or 0) > most then scroll:SetVerticalScroll(most) end
end


-- THE PANEL'S FLOOR. Frozen: Core/MailboxUI.lua adds the window's chrome to this
-- and makes the sum the window's minimum height.
--
-- The list is this screen's one elastic band -- it is anchored between the view
-- toggle and the totals banner, so every pixel a taller window adds lands there
-- -- and everything else is fixed. Each term below is read from the token
-- CT.Build anchors that band with, never restated as a number, so moving a band
-- moves the floor with it:
--
--   panel top
--     inset             the panel's own top margin
--   view toggle         segmentHeight (the C.O.D. hint shares this row, so it
--     gap               adds nothing to the height)
--   list container      tightGap, the scroll viewport, tightGap
--     gap
--   totals banner       controlHeight, while the option shows it (RV.ShowTotals)
--     gap
--   footer              the category grid: one full-width primary over the rows
--     inset             of three its sweeps fill (two, as the grid comes), or
--                       the primary alone when the option hides them or the
--                       player hid them all. The Done view swaps in a single delete button
--                       and is therefore SHORTER, so sizing for the grid is what
--                       makes the guarantee hold in both views. The floor
--                       follows the option, the row mode AND the other tab's
--                       need -- see the function for how the last is met.
-- `atLeast` is the OTHER tab's need for the same window. The window's floor
-- is the taller of the two, and when the compose screen's is the taller the
-- list would get whatever was left over -- some number of rows and part of
-- one. So this answers with the smallest WHOLE-ROW height that is at least
-- both: its own floor, and enough whole rows of the current pitch to clear
-- the other tab's. The floor is therefore whole rows in every combination
-- of row mode and category buttons, and Core/MailboxUI.lua moves a window
-- standing on it whenever it moves.
function CT.MinPanelHeight(atLeast)
  local M = Th().Metrics
  -- The footer as the option has it: with the rows the sweeps it shows fill,
  -- or the primary alone.
  local footer = GRID_PRIMARY_HEIGHT
  if ShowCategoryButtons() then
    footer = footer + RV.FloorGridRows() * (M.gap + GRID_BUTTON_HEIGHT)
  end
  local band = RV.ShowTotals() and (M.controlHeight + M.gap) or 0
  local fixed = M.inset
              + M.segmentHeight + M.gap
              + 2 * M.tightGap + M.gap
              + band
              + footer
              + M.inset

  local compact, height, stride = RowMetrics()
  local rows = compact and COMPACT_MIN_ROWS or STANDARD_MIN_ROWS
  local need = tonumber(atLeast) or 0
  if need > fixed + RowsHeight(rows, height) then
    -- Whole rows over the other tab's need: the list height that clears it,
    -- rounded up to the pitch.
    rows = max(rows, ceil((need - fixed + ROW_GAP) / stride))
  end
  return ceil(fixed + RowsHeight(rows, height))
end

-- Frozen: Core/MailboxUI.lua steps the window's height in these above the
-- floor -- the ceiling, a drag, a restored height -- so no height it can
-- reach shows part of a row. One row's pitch in the current row mode.
function CT.RowStride()
  local _, _, stride = RowMetrics()
  return stride
end

-- For /postbox debug: the floor's arithmetic, so "half a row" arrives with
-- the numbers that decided the window's smallest height.
function CT.Diagnose()
  local compact, height, stride = RowMetrics()
  return string.format("compact %s | row %d pitch %d | buttons %s | list floor %d",
    tostring(compact), height, stride, tostring(ShowCategoryButtons()), CT.MinPanelHeight())
end

-------------------------------------------------------------
-- The inbox counts
--
-- THE numbers for "how much is there still to collect", and the only ones. All
-- three segment captions carry them, so they may never be able to disagree with
-- each other or with the list under them -- which they can only be guaranteed
-- not to if there is one walk of the inbox behind all of them, not three walks
-- that happen to use the same rule today. The shell's status line states no
-- count at all now, precisely because the segments already do.
--
-- So the list refresh, which has to reach a verdict on every mail anyway to
-- filter the list, RECORDS what it found here, and everything else READS. The
-- walk below exists for the two moments when nobody has recorded anything: the
-- option toggle (Core/MailboxUI.lua's RefreshCollectTabCounts, with no refresh
-- in flight to borrow from) and an inbox that changed while the collect panel
-- was hidden -- a hidden panel skips its refresh entirely, so the shell
-- invalidates on MAIL_INBOX_UPDATE and the next read pays for one walk.
--
-- The walk is not free: Mail().IsReadPersistent scans all sixteen attachment
-- slots of a mail its header calls empty. That is exactly why the recorded
-- answer is preferred and why there is no second counter anywhere.
-------------------------------------------------------------

local counts = { toCollect = 0, done = 0, total = 0, server = 0, gone = 0, known = false }

-- `total` is what the client lists; `server` what the mailbox holds, which is
-- more once it passes what the client will list at a time. `gone` of those are
-- on their way out (RV.Leaving), and neither number counts them: the next
-- update will not list them either.
local function RecordCounts(toCollect, done, total, server, gone)
  gone = tonumber(gone) or 0
  counts.toCollect = toCollect
  counts.done = done
  counts.total = total - gone
  counts.server = math.max((tonumber(server) or total) - gone, total - gone)
  counts.gone = gone
  counts.known = true
end

local function WalkCounts()
  local total, server = 0, 0
  if type(GetInboxNumItems) == "function" then total, server = GetInboxNumItems() end
  total = tonumber(total) or 0
  local done, gone = 0, 0
  for index = 1, total do
    if RV.Leaving(index) then
      gone = gone + 1
    elseif Mail().IsReadPersistent(index) then
      done = done + 1
    end
  end
  RecordCounts(total - done - gone, done, total, server, gone)
end

-- -> toCollect, done, total (listed), server (in the mailbox).
function CT.InboxCounts()
  if not counts.known then WalkCounts() end
  return counts.toCollect, counts.done, counts.total, counts.server
end

-- The inbox changed and no refresh has looked at it yet. Frozen: Core/MailboxUI.lua
-- calls this from MAIL_INBOX_UPDATE and when a mail session ends.
function CT.InvalidateCounts()
  counts.known = false
end

-------------------------------------------------------------
-- Refresh coalescing
--
-- A run refreshes the list once per mail. Rebuilding the list on each of those
-- inside the same frame is wasted work, and refreshing a panel nobody is
-- looking at is entirely wasted. Both collapse into one dirty flag: mark, drain
-- on the next frame, and skip while hidden -- the panel's OnShow drains it.
--
-- Published, because the shell needs it too: MAIL_INBOX_UPDATE is the burstiest
-- source of all (the initial inbox load, every body fetch, every CheckInbox) and
-- it used to reach RefreshMailList synchronously, which is several complete
-- rebuilds inside a handful of frames for one user-visible change. Every
-- event-driven refresh goes through here; only opening the window rebuilds
-- synchronously, because there the list has to exist in the frame the window
-- appears in.
-------------------------------------------------------------

local function RequestRefresh(panel)
  if not panel then return end
  panel._dirty = true
  if panel._refreshQueued then return end
  panel._refreshQueued = true
  -- The flag is a latch: nothing else ever clears it, so if the schedule failed
  -- the panel would never refresh again for the rest of the session. Unlatch and
  -- rebuild inline instead -- slower, but the list stays truthful. The
  -- callback is made once per panel, not per request.
  local run = panel._refreshRun
  if not run then
    run = function()
      panel._refreshQueued = false
      if panel._dirty then CT.RefreshMailList(panel) end
    end
    panel._refreshRun = run
  end
  local ok = pcall(C_Timer.After, 0, run)
  if not ok then
    panel._refreshQueued = false
    CT.RefreshMailList(panel)
  end
end

CT.RequestRefresh = RequestRefresh

-- index -> whether the mail at this index is on its way out: emptied by
-- Postbox a moment ago and being deleted by the client (MailService, "Mail on
-- its way out"). The list and every count leave it out, so an auction mail
-- just emptied never shows under the divider or as Done on its way to going.
-- The hold is bounded, and the screen looks again when it lapses: a mail that
-- stays after all is listed then, not whenever something else refreshes.
function RV.Leaving(index)
  local service = Mail()
  local at = service and type(service.Leaving) == "function" and service.Leaving(index)
  if not at then return false end
  RV.WakeAt(at)
  return true
end

-- One wake at a time, and one-shot. Holds lapse in the order they start, so a
-- wake already queued is never later than the one a newer hold would ask for,
-- and the refresh it brings asks again of whatever is still held.
function RV.WakeAt(at)
  if RV.waking then return end
  RV.waking = true
  local ok = pcall(C_Timer.After, max(0, at - GetTime()) + 0.1, function()
    RV.waking = false
    -- The mail went, as it almost always has by now, and the update that
    -- removed it has already refreshed everything.
    if (counts.gone or 0) == 0 then return end
    CT.InvalidateCounts()
    local UI = ns.MailboxUI
    RequestRefresh(UI and UI._frame and UI._frame.Tabs and UI._frame.Tabs.collect)
    if UI and type(UI.RefreshCollectTabCounts) == "function" then UI.RefreshCollectTabCounts() end
  end)
  if not ok then RV.waking = false end
end

-------------------------------------------------------------
-- Confirmations
--
-- The client's own dialog: it sits above everything, is keyboard-dismissable,
-- and needs no skinning. When the dialog API is missing the message is printed
-- and NOTHING IRREVERSIBLE HAPPENS -- a missing confirmation is never an
-- implicit yes.
-------------------------------------------------------------

local POPUP_COD        = "POSTBOX_COD_CONFIRM"
local POPUP_BAGSPACE   = "POSTBOX_BAGSPACE_CONFIRM"
local POPUP_DELETE_ALL = "POSTBOX_DELETE_ALL_READ"
local POPUP_DELETE_ONE = "POSTBOX_DELETE_MAIL"
local POPUP_NOTICE     = "POSTBOX_COLLECT_NOTICE"

local function PopupsAvailable()
  return type(StaticPopupDialogs) == "table" and type(StaticPopup_Show) == "function"
end

-- No `preferredIndex` on any dialog below, deliberately. The field was a taint
-- mitigation: it asked StaticPopup for the last dialog frame, the one least
-- likely to be reused by secure code. 12.x's rewritten StaticPopup does not
-- read it at all -- dialogs come from a shared pool, first free frame -- and
-- STATICPOPUP_NUMDIALOGS no longer exists, so the helper that fed it always
-- returned nil. Nothing replaces it: GetReservedDialogFrame needs a reserved
-- frame an addon cannot create.
local function EnsureDialog(key, accept, cancel)
  if not PopupsAvailable() then return false end
  if StaticPopupDialogs[key] then return true end
  StaticPopupDialogs[key] = {
    text = "%s",
    button1 = accept,
    button2 = cancel,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, data)
      if type(data) == "table" and type(data.onConfirm) == "function" then data.onConfirm() end
    end,
  }
  return true
end

local function Confirm(key, accept, cancel, message, onConfirm)
  if EnsureDialog(key, accept, cancel) then
    StaticPopup_Show(key, message, nil, { onConfirm = onConfirm })
    return
  end
  ns.Print(message)
end

local function ShowNotice(message)
  if EnsureDialog(POPUP_NOTICE, L()["POPUP_OK"], nil) then
    StaticPopup_Show(POPUP_NOTICE, message)
    return
  end
  ns.Print(message)
end

-- Before collecting a single mail the player clicked. Bulk runs never include
-- C.O.D. mail -- the domain excludes it -- so this is the only path that can
-- spend the player's money.
--
-- The accept re-verifies the mail's identity: a StaticPopup is not modal, so
-- the inbox can reindex while the question waits (another row clicked, a
-- spontaneous inbox update), and the quoted amount must never be paid for
-- whatever mail slid onto the index since. Forward declaration -- Fingerprint
-- lives with the mail-identity block below.
local Fingerprint

local function ConfirmCOD(index, onConfirm)
  local _, _, _, _, _, cod = GetInboxHeaderInfo(index)
  local amount = tonumber(cod) or 0
  if amount <= 0 then
    onConfirm()
    return
  end
  local expected = Fingerprint(index)
  Confirm(POPUP_COD, L()["COD_CONFIRM_ACCEPT"], L()["COD_CONFIRM_CANCEL"],
    L()("COD_CONFIRM_MSG", Helpers().FormatMoney(amount)), function()
      -- Silently stand down on a mismatch, like every LiveIndex caller: the
      -- coalesced refresh has already re-bound the rows the player sees.
      if Fingerprint(index) ~= expected then return end
      onConfirm()
    end)
end

-------------------------------------------------------------
-- Words for a status code
--
-- ns.MailService reports what happened; which of those outcomes deserves a
-- chat line, and in what words, is this file's job.
--
--   "collected" the mail (or slot) is empty.
--   "refused"   the server declined specific attachments. They are still in the
--               mailbox, nothing is at risk, carry on.
--   "timeout"   the server stopped acknowledging commands. Stop.
--   "busy"      another Postbox sequence owns the command channel; the click is
--               a no-op and the run in progress reports its own status.
--   "closed"    the mailbox is not open.
-------------------------------------------------------------

-- When we captured the game's own error text we quote it, because it names the
-- actual cause. Without it we can only list the usual ones, so the fallback
-- offers them as possibilities rather than asserting a cause.
local function ItemRefusedMessage(reason)
  if reason and reason ~= "" then return L()("MSG_ITEM_REFUSED_REASON", reason) end
  return L()["MSG_ITEM_REFUSED"]
end

local function MailPartialMessage(refused, reason)
  if reason and reason ~= "" then return ns.Plural("MSG_MAIL_PARTIAL_REASON", refused, reason) end
  return ns.Plural("MSG_MAIL_PARTIAL", refused)
end

-- The one line a stuck mail gets, wherever it is shown -- the row's tooltip and
-- the detail view's metadata both read it from here, so the two can never say
-- different things about the same mail.
--
-- `reason` is what ns.MailService recorded: the game's own error text, or `true`
-- where it refused with nothing we could attribute to this mail. The generic
-- half is phrased as possibilities, never as a cause: the addon does not know
-- which of them it was, and guessing out loud is how a player ends up emptying a
-- bag over a unique item they already owned.
local function StuckLine(reason)
  local words = (type(reason) == "string" and reason ~= "") and reason
    or L()["STUCK_GENERIC"]
  return L()("STUCK_LINE", words)
end

-- A locale key that the locale pass has not added yet must not render as its
-- own name in the middle of the UI. Every new string in this file reads raw
-- first and composes a neutral fallback when the key is absent.
local function RawKey(key)
  local value = rawget(L(), key)
  if type(value) == "string" then return value end
  return nil
end

-------------------------------------------------------------
-- Mail identity
--
-- An inbox index stops naming a mail the moment that mail is emptied: the
-- server deletes it and every higher index slides down onto it. The detail view
-- is addressed by index, so it has to be able to notice.
-------------------------------------------------------------

-- Split from Fingerprint so a caller that has already read the header -- the row
-- binder reads all nine return values anyway -- can build the same string
-- without a second GetInboxHeaderInfo, and so the two can never disagree about
-- what a fingerprint is made of.
local function FingerprintOf(sender, subject, cod)
  if sender == nil and subject == nil then return nil end
  return tostring(sender) .. "\001" .. tostring(subject) .. "\001" .. tostring(tonumber(cod) or 0)
end

-- Declared `local` above ConfirmCOD, which closes over it; assigned here.
function Fingerprint(index)
  local _, _, sender, subject, _, cod = GetInboxHeaderInfo(index)
  return FingerprintOf(sender, subject, cod)
end

-- Any widget that stores `mailIndex` also stores the `fingerprint` the mail had
-- when that index was written to it. This returns the index only while the two
-- still agree, and nil otherwise.
--
-- The list re-binds on every refresh, but a refresh is COALESCED to the next
-- frame -- so between a take completing and that rebuild every row below the
-- emptied mail carries an index that has already slid onto its neighbour. That
-- window is long enough to hover in, and a tooltip read straight off an index
-- (GameTooltip:SetInboxItem takes one) would describe the wrong mail's item.
-- The check costs one header read on hover, which is where all of this is.
local function LiveIndex(widget)
  local index = widget and widget.mailIndex
  if not index or not widget.fingerprint then return nil end
  if Fingerprint(index) ~= widget.fingerprint then return nil end
  return index
end

-- The real item tooltip for an attachment still sitting in the mailbox.
--
-- SetInboxItem, not SetHyperlink: it is addressed by mail and slot and needs no
-- item link, which matters because an unread mail's attachment links are not
-- loaded until its body is fetched -- and not fetching the body is the entire
-- point of a preview.
local function ShowAttachmentTooltip(owner, index, slot)
  if not (owner and index and slot) then return false end
  if type(GameTooltip.SetInboxItem) ~= "function" then return false end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:ClearLines()
  GameTooltip:SetInboxItem(index, slot)
  GameTooltip:Show()
  return true
end

-------------------------------------------------------------
-- Per-mail economy
--
-- Derived from the invoice where one exists, and from the classification
-- otherwise. A buyer invoice is a purchase; a seller invoice counts the money
-- actually collectable from the mailbox, not the gross sale -- the deposit and
-- the auction house's cut never arrive.
-------------------------------------------------------------

local function MailEconomy(index, kind, money)
  local amount = tonumber(money) or 0
  local invoiceType, bid
  if type(GetInboxInvoiceInfo) == "function" then
    invoiceType, _, _, bid = GetInboxInvoiceInfo(index)
  end

  if invoiceType == "buyer" then
    bid = tonumber(bid) or 0
    if bid > 0 then return 0, bid end
    return 0, amount
  end

  if invoiceType == "seller" or invoiceType == "seller_temp_invoice" then
    return amount, 0
  end

  if kind == "bought" then return 0, amount end
  return amount, 0
end

-- The money lines an invoice is worth printing, in reading order, keyed by the
-- token the server puts on it. Naming the field rather than its position keeps
-- this readable next to a GetInboxInvoiceInfo call that discards four of its
-- seven returns.
--
-- `saleTotal` marks the one figure the two screens disagree about. A list row
-- already carries what the mail is worth NOW, and following that with the
-- gross sale reads as though the gold arrived twice; the overlay has the room
-- to show the whole breakdown and is the place a player goes to reconcile it.
local INVOICE_FIGURES = {
  seller = {
    { field = "bid",         label = "LABEL_SALE", saleTotal = true },
    { field = "deposit",     label = "LABEL_DEPOSIT" },
    { field = "consignment", label = "LABEL_AH_COMMISSION" },
  },
  buyer = {
    { field = "bid", label = "LABEL_PURCHASE" },
  },
}

-- A sale the server has not finished settling arrives under its own token and
-- reads identically.
INVOICE_FIGURES.seller_temp_invoice = INVOICE_FIGURES.seller

-- Reused for the same reason the row's own tables are: one mail is described
-- at a time, and this runs per visible row per refresh.
local invoiceAmounts = {}

-- Appends an auction mail's money breakdown to `parts`, and nothing at all for
-- a mail that has no invoice -- which includes every auction mail whose body
-- has not been fetched yet, since GetInboxInvoiceInfo stays silent until then.
--
-- Zero is not a figure: an auction that cost no deposit must not print a
-- deposit of nothing, and the same goes for a commission-free sale.
local function AppendInvoiceFigures(parts, index, withSaleTotal)
  if type(GetInboxInvoiceInfo) ~= "function" then return end

  local invoiceType, _, _, bid, _, deposit, consignment = GetInboxInvoiceInfo(index)
  RV.InvoiceFigures(parts, invoiceType, bid, deposit, consignment, withSaleTotal)
end

-- The same lines from an invoice's figures however they were read: the
-- inbox's, or a sample mail's in the arrange mode's preview (RV.SAMPLE).
function RV.InvoiceFigures(parts, invoiceType, bid, deposit, consignment, withSaleTotal)
  local figures = INVOICE_FIGURES[invoiceType]
  if not figures then return end

  invoiceAmounts.bid = tonumber(bid) or 0
  invoiceAmounts.deposit = tonumber(deposit) or 0
  invoiceAmounts.consignment = tonumber(consignment) or 0

  local fmt = Helpers().FormatMoney
  for i = 1, #figures do
    local figure = figures[i]
    local amount = invoiceAmounts[figure.field]
    if amount > 0 and (withSaleTotal or not figure.saleTotal) then
      parts[#parts + 1] = L()[figure.label] .. fmt(amount)
    end
  end
end

-- What a won auction cost, for the row's money column, or nil for any other
-- mail -- and nil for a won auction whose invoice the client has not
-- fetched yet, which is every one until its body has been read once.
local function PurchasePrice(index)
  if type(GetInboxInvoiceInfo) ~= "function" then return nil end
  local invoiceType, _, _, bid = GetInboxInvoiceInfo(index)
  if invoiceType ~= "buyer" then return nil end
  bid = tonumber(bid) or 0
  return (bid > 0) and bid or nil
end

-------------------------------------------------------------
-- Mail rows :: the columns
--
-- A compact row is a table, not a sentence. The sender sits in a column as
-- wide as the widest auction outcome, the subject takes everything left, and
-- the three figures -- time left, money, slots -- stand where the player's
-- arrangement puts them (at the right edge, as they come), each as wide as
-- its widest entry ANYWHERE in the list. Measured over the
-- list rather than the rows on screen, so a column does not twitch as the list
-- scrolls. A stuck mail's mark takes the read mark's place, so it needs no
-- room of its own; in columns a read mail's delete mark draws over the end
-- of the last column, which keeps room for it on every row only where the
-- mark would cover what a marked row draws there (RV.MarkReserve), and a
-- packed row closes up against its own mark.
--
-- Which columns a row shows, and in what order, is the player's arrangement
-- (MailboxUI.GetRowLayout, arranged in the window by Core/Arrange.lua), and
-- it is one arrangement for every list that draws mail rows; History's rows
-- have one of their own (MailboxUI.GetHistoryLayout), which RV.Place is
-- handed in its spec. What a hidden column would have said still reaches
-- the row's tooltip, so no fact becomes unreachable.
-------------------------------------------------------------

-- The row's columns as the player has arranged them: { {id=, shown=}, ...,
-- shown = { [id] = bool } }, shared and read-only. The default arrangement
-- when the option plumbing has not loaded yet.
RV.DEFAULT_LAYOUT = { shown = {} }
for _, id in ipairs({ "read", "icon", "sender", "subject", "time", "money", "slots" }) do
  RV.DEFAULT_LAYOUT[#RV.DEFAULT_LAYOUT + 1] = { id = id, shown = true }
  RV.DEFAULT_LAYOUT.shown[id] = true
end

function RV.Layout()
  local UI = ns.MailboxUI
  if UI and type(UI.GetRowLayout) == "function" then return UI.GetRowLayout() end
  return RV.DEFAULT_LAYOUT
end

-- The Mail tab's two-line rows keep an arrangement of their own
-- (MailboxUI.GetLargeLayout): the one-line rows' until it is first stored.
function RV.LargeLayout()
  local UI = ns.MailboxUI
  if UI and type(UI.GetLargeLayout) == "function" then return UI.GetLargeLayout() end
  return RV.Layout()
end

-- Where a two-line row draws the sender in `layout`: on its second line,
-- among the figures and in their order (2), where a figure stands between
-- the sender and the subject in the arrangement; on the first line
-- otherwise (1), before the subject or at the line's end, by its side.
-- Hidden figures count, so hiding one never moves the sender. Answered
-- once per arrangement: the tables are shared and kept until they change.
function RV.SenderLine(layout)
  if RV._senderFor == layout then return RV._senderLine end
  local s, d = 0, 0
  for i = 1, #layout do
    local id = layout[i].id
    if id == "subject" then s = i elseif id == "sender" then d = i end
  end
  local line = 1
  if s > 0 and d > 0 then
    for i = min(s, d) + 1, max(s, d) - 1 do
      if RV.FIGURE[layout[i].id] then
        line = 2
        break
      end
    end
  end
  RV._senderFor, RV._senderLine = layout, line
  return line
end

-- The sender written into a two-line row's second line: in its class's
-- colour where Postbox knows it (RV.PaintSender), else in the name's own
-- role colour, the live accent where that is the accent. An auction
-- outcome carries its own colour and is passed as it is. The string is the
-- same each time for the same name and colour, so a bind makes nothing new.
function RV.InlineSender(sender, text)
  local T = Th()
  local CS = ns.ContactService
  local token = (sender and CS and CS.ClassOf) and CS.ClassOf(sender) or nil
  local r, g, b
  if token and CS.ClassColour then r, g, b = CS.ClassColour(token) end
  if not r then
    local role = T.TextRoles and T.TextRoles.label
    local color = role and role.color or "accent"
    if color == "accent" then
      r, g, b = T.GetAccent()
    else
      local c = T.Colors and T.Colors[color]
      if not c then return text end
      r, g, b = c[1], c[2], c[3]
    end
  end
  return format("|cff%02x%02x%02x%s|r", floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5), text or "")
end

-- The figures: columns with a list-wide width of their own -- the mail
-- rows' time left, money and slots, and History's age.
RV.FIGURE = { time = true, money = true, slots = true, age = true }
-- The narrowest a figure's column is drawn (RV.Place): squeezed below it
-- by the others, a figure gives up its column. A column whose widest entry
-- is narrower -- a slot count written as the number alone -- is measured
-- up to it (RV.SlotsWidth, Mail Memory's MeasureRows), not dropped.
RV.FIGURE_MIN = 12

-- Whether the arrangement shows this column ("read", "icon", "sender",
-- "subject", "time", "money" or "slots").
local function RowShows(id)
  return RV.Layout().shown[id] == true
end

-- The arrange mode's state, as the rows need it: whether it is open over
-- this panel (a row click then does nothing -- a stray click while columns
-- are being moved must not collect a mail), and which column it points at.
function RV.Arranging(owner)
  local A = ns.Arrange
  return A ~= nil and type(A.IsActive) == "function" and A.IsActive(owner) or false
end

function RV.Focus()
  local A = ns.Arrange
  return A and type(A.Focus) == "function" and A.Focus() or nil
end

-- Whether the figures stand in lanes (RV.Place): the Row layout choice,
-- Columns (the default) rather than Packed -- in the arrange mode too, so
-- what the choice does is seen while the columns are arranged (the header
-- stands on each column's home lane either way: RV.HomeLanes). Read once
-- per row placed: the options' memo.
function RV.LinedUp()
  local UI = ns.MailboxUI
  if not (UI and UI.GetRowPacking) then return true end
  return UI.GetRowPacking() ~= "packed"
end

-- The money, in its shortest honest form ("52g 26s", "1309g", "12.3k"; the
-- compact row keeps the largest coin alone). Three tones for three meanings:
-- green is gold arriving, amber is a C.O.D. price you would pay by collecting
-- (a decision, so the warning tone), red is what a won auction already cost
-- (spent, as the band's own "Spent" is red). Returns the text or nil, and
-- which of the three it is: "earned", "cod" or "spent" -- a won auction's
-- price, which the invoice figures then skip.
-- `price` is that price, or nil. A live inbox row passes its index as
-- `priceIndex` instead, and the price is read from the invoice only when
-- nothing else answered, because reading it costs an invoice call.
local function MoneyText(hasCOD, moneyValue, codValue, price, brief, priceIndex)
  local T = Th()
  local compactMoney = ns.Core.Formatting.FormatMoneyCompact
  if moneyValue > 0 then
    return T.Colorize("positive", compactMoney(moneyValue, brief)), "earned"
  end
  if hasCOD then
    if codValue > 0 then
      return T.Colorize("warning", L()["LABEL_COD"] .. compactMoney(codValue, brief)), "cod"
    end
    return T.Colorize("warning", L()["LABEL_COD_SHORT"]), "cod"
  end
  if price == nil and priceIndex then price = PurchasePrice(priceIndex) end
  if price then return T.Colorize("negative", compactMoney(price, brief)), "spent" end
  return nil, nil
end

-- Whether money of this kind stands on the row. Earned and spent go with the
-- gold column and its choice of which; a C.O.D. price always shows, because
-- it is the one sum nothing collects on its own -- Postbox never pays one
-- without asking. `layout` is the row's arrangement (nil: the mail rows'),
-- whose own choice of which gold it is.
local function MoneyShown(kind, layout)
  if kind ~= "earned" and kind ~= "spent" then return true end
  layout = layout or RV.Layout()
  if not layout.shown.money then return false end
  local UI = ns.MailboxUI
  local mode = UI and UI.GetGoldMode and UI.GetGoldMode(layout.arrangement) or "both"
  return mode == "both" or mode == kind
end

-- The name a row shows for a sender. A player's realm is dropped -- the row is
-- for recognising a name, and the tooltip and Reply both use the whole of it
-- from the mail itself. An NPC's leading article is dropped too ("The
-- Postmaster" -> "Postmaster"); an NPC is the only sender with a space in its
-- name, since a player's name cannot hold one, so no player is ever touched.
local NPC_ARTICLES = ({
  enUS = { "The " }, enGB = { "The " },
  deDE = { "Der ", "Die ", "Das " },
  frFR = { "Le ", "La ", "Les ", "L'" },
  esES = { "El ", "La ", "Los ", "Las " }, esMX = { "El ", "La ", "Los ", "Las " },
})[GetLocale()] or {}

local function DisplaySender(sender)
  if type(sender) ~= "string" or sender == "" then return sender end
  -- Name-Realm first: the name part never has a space, the realm part may.
  local dash = sender:find("-", 1, true)
  if dash and dash > 1 and not sender:sub(1, dash - 1):find(" ", 1, true) then
    return sender:sub(1, dash - 1)
  end
  if sender:find(" ", 1, true) then
    for i = 1, #NPC_ARTICLES do
      local article = NPC_ARTICLES[i]
      if #sender > #article and sender:sub(1, #article) == article then
        return sender:sub(#article + 1)
      end
    end
    return sender
  end
  return sender
end

local function RowMoneyText(index, hasCOD, moneyValue, codValue, brief)
  return MoneyText(hasCOD, moneyValue, codValue, nil, brief, index)
end

-- texture, name, quality, mark, count -> one item's line in the tooltip
-- being built: its icon, its name in its quality's colour with the crafting
-- mark its link carries, and its count beside it. Mail Memory's icons list
-- what a remembered mail held with it too.
function RV.ItemLine(texture, name, quality, mark, count)
  local r, g, b = 1, 1, 1
  local qualityColor = C_Item and C_Item.GetItemQualityColor
  if quality and type(qualityColor) == "function" then
    local qr, qg, qb = qualityColor(quality)
    if qr then r, g, b = qr, qg, qb end
  end
  local line = "|T" .. tostring(texture) .. ":14:14:0:0:64:64:5:59:5:59|t "
    .. (name or RETRIEVING_ITEM_INFO or "") .. (mark and (" " .. mark) or "")
  count = tonumber(count) or 1
  if count > 1 then
    GameTooltip:AddDoubleLine(line, ("x%d"):format(count), r, g, b, 0.82, 0.82, 0.82)
  else
    GameTooltip:AddLine(line, r, g, b)
  end
end

-- owner, index, items -> the tooltip of the icon of a mail holding several
-- items: how many, then one line per item (RV.ItemLine), and the gold or
-- the C.O.D. price, if any; then how to take them one at a time, by the
-- gesture that opens a mail under the player's setting. Built on hover,
-- never on a bind.
function RV.ItemsTooltip(owner, index, items)
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:ClearLines()
  GameTooltip:SetText(ns.Plural("COUNT_ITEMS", items), 1, 1, 1)
  for slot = 1, Mail().MAX_ATTACHMENTS do
    local name, _, texture, count, quality = GetInboxItem(index, slot)
    if texture then RV.ItemLine(texture, name, quality, RV.QualityMark(index, slot), count) end
  end
  local _, _, _, _, money, cod = GetInboxHeaderInfo(index)
  money, cod = tonumber(money) or 0, tonumber(cod) or 0
  if money > 0 or cod > 0 then
    local text = RowMoneyText(index, cod > 0, money, cod, false)
    if text then GameTooltip:AddLine(text, 1, 1, 1) end
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine(L()[PreviewOnClick() and "HINT_ICON_TAKE_CLICK" or "HINT_ICON_TAKE_RIGHT"], 0.7, 0.7, 0.7, true)
  GameTooltip:Show()
end

-- daysLeft, hasCOD -> whether the row shows the time left, and whether in
-- the warning tone. Shown always (the default) or under the player's
-- threshold; amber when it is genuinely short -- under three days,
-- or under one for a C.O.D. mail, which only lives three. The threshold
-- is the row's arrangement's own (`layout`; nil: the one-line rows').
local function ExpiryState(daysLeft, hasCOD, layout)
  local UI = ns.MailboxUI
  local when = UI and UI.GetExpiryWhen and UI.GetExpiryWhen(layout and layout.arrangement) or "always"
  local limit = (when ~= "always") and tonumber(when) or nil
  local show = (limit == nil) or daysLeft < limit
  local warn = daysLeft < (hasCOD and 1 or EXPIRY_SOON_DAYS)
  return show, warn
end

local function RowExpiryText(daysLeft, hasCOD, layout)
  if not daysLeft then return nil end
  local show, warn = ExpiryState(daysLeft, hasCOD, layout)
  if not show then return nil end
  return Th().Colorize(warn and "warning" or "textSecondary", Helpers().TimeLeft(daysLeft))
end

-- The rendered width of `text` in `sample`'s font. One hidden string per
-- panel, re-fonted from the sample on every call, so the measurement is taken
-- in exactly the face and size the row draws in -- whatever skin set it.
--
-- One hidden measuring string per sample, re-fonted only when the sample's
-- font changes: a walk alternates between two or three samples, and one
-- shared string was re-fonted on nearly every call. Where the owner counts
-- passes (`_measurePass`, the Mail tab's list), each distinct text is also
-- measured once -- "AH Sold" forty times is one measure -- and kept until
-- the font or the drawing scale changes (see the memo below). A font still
-- loading measures zero, which is never kept, so the next refresh measures
-- again, as it always did.
--
-- While the list's own walk measures (`_measureWalk` is its pass), each
-- sample's font is read once: the walk runs to its end in one go and nothing
-- re-fonts a row inside it. Anywhere else the font is read on every call, as
-- it always was. The memo is one table per string, emptied when it must be
-- rather than made anew.
--
-- A width comes rounded up to the next unit, the room a column keeps;
-- `exact` answers it as the client measured it, for a sum of widths that
-- must land on a position within one string (RV.RecordTwo).
RV.MEMO_MAX = 512

-- At the start of the list's walk: a new measuring generation when the scale
-- the list is drawn at has moved (the window's scale, the game's UI scale),
-- since a string's width in its own units can move with the pixels it lands
-- on. One read and a compare per walk.
function RV.MeasureScale(panel)
  local scale = panel:GetEffectiveScale()
  if scale ~= panel._measureScale then
    panel._measureScale = scale
    panel._measureGen = (panel._measureGen or 0) + 1
  end
end

local function MeasureWith(panel, sample, text, exact)
  text = text or ""
  local strings = panel._measureFor
  if not strings then
    strings = {}
    panel._measureFor = strings
  end
  local fs = strings[sample]
  if not fs then
    fs = panel:CreateFontString(nil, "ARTWORK")
    fs:Hide()
    strings[sample] = fs
  end
  local pass = panel._measurePass
  if pass == nil or panel._measureWalk ~= pass or fs.__pbFontPass ~= pass then
    local path, size, flags = sample:GetFont()
    if path and (fs.__pbPath ~= path or fs.__pbSize ~= size or fs.__pbFlags ~= flags) then
      fs:SetFont(path, size, flags or "")
      fs.__pbPath, fs.__pbSize, fs.__pbFlags = path, size, flags
      -- Widths taken in the old font: emptied on the next memo read.
      fs.__pbMemoPass = nil
    end
    fs.__pbFontPass = pass
  end
  if pass == nil then
    fs:SetText(text)
    local width = fs:GetStringWidth() or 0
    if exact then return width end
    return ceil(width)
  end
  -- The memo outlives the pass: a width changes only with the font (the
  -- re-font above empties it) or the scale the string is drawn at (the walk
  -- moves `_measureGen`, RV.MeasureScale). A zero -- a font not laid out
  -- yet -- is never kept, and the memo is emptied at RV.MEMO_MAX texts, so
  -- a session of distinct amounts cannot grow it without bound.
  local gen = panel._measureGen or 0
  local memo = fs.__pbMemo
  if not memo then
    memo = {}
    fs.__pbMemo, fs.__pbMemoPass, fs.__pbMemoN = memo, gen, 0
  elseif fs.__pbMemoPass ~= gen or fs.__pbMemoN >= RV.MEMO_MAX then
    for key in pairs(memo) do memo[key] = nil end
    fs.__pbMemoPass, fs.__pbMemoN = gen, 0
  end
  local width = memo[text]
  if not width then
    fs:SetText(text)
    width = fs:GetStringWidth() or 0
    if width > 0 then
      memo[text] = width
      fs.__pbMemoN = fs.__pbMemoN + 1
    end
  end
  if exact then return width end
  return ceil(width)
end

-- Whether a row writes its slot count as the number alone (MailboxUI's
-- "Slots" choice): "4" rather than "4 slots".
function RV.SlotsNumber()
  local UI = ns.MailboxUI
  return UI ~= nil and type(UI.GetSlotsStyle) == "function" and UI.GetSlotsStyle() == "number"
end

-- n, onRow -> the slot count as a row writes it: the number alone where the
-- player chose it and it stands in a one-line row's column (`onRow`), the
-- plural words otherwise -- a two-line row's second line and a tooltip
-- always say "4 slots".
function RV.SlotsText(n, onRow)
  if onRow and RV.SlotsNumber() then return tostring(n) end
  return ns.Plural("COUNT_SLOTS", n)
end

-- The slots column's width for counts up to `most`: the widest any of them
-- is written, every digit the font's widest, in the plural word each count
-- takes -- "4 slots" is wider than "7 slots" in a font whose 4 is wider, and
-- Russian's forms differ in length -- so no count is cut; the number alone
-- where the player chose it (RV.SlotsText). The widest digit and each width
-- are kept per font (a host UI re-fonts after load) and per scale the text
-- is drawn at (the measuring's generation, RV.MeasureScale), and measured
-- again only when either changes; the locale needs a reload to change. A
-- number-only width is kept under -most, so the two styles never read each
-- other's. A font not laid out yet measures nothing, and nothing is kept
-- from it.
RV.DIGITS = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }

function RV.SlotsWidth(panel, sample, most)
  local fit = panel._slotsFit
  if not fit then
    fit = { w = {} }
    panel._slotsFit = fit
  end
  local path, size, flags = sample:GetFont()
  local gen = panel._measureGen or 0
  if fit.path ~= path or fit.size ~= size or fit.flags ~= flags or fit.gen ~= gen then
    fit.path, fit.size, fit.flags, fit.gen, fit.digit = path, size, flags, gen, nil
    for key in pairs(fit.w) do fit.w[key] = nil end
  end
  local number = RV.SlotsNumber()
  local key = number and -most or most
  local width = fit.w[key]
  if width then return width end
  local digit = fit.digit
  if not digit then
    local widest = 0
    for i = 1, #RV.DIGITS do
      local w = MeasureWith(panel, sample, RV.DIGITS[i])
      if w > widest then digit, widest = RV.DIGITS[i], w end
    end
    if not digit then
      local w = MeasureWith(panel, sample, RV.SlotsText(most, true))
      return (w > 0) and max(w, RV.FIGURE_MIN) or 0
    end
    fit.digit = digit
  end
  width = 0
  for n = 1, most do
    local text = RV.SlotsText(n, true):gsub("%d", digit)
    width = max(width, MeasureWith(panel, sample, text))
  end
  -- A lone digit is narrower than any column is drawn: the column stands
  -- at the narrowest (RV.FIGURE_MIN), the count at its right edge.
  if width > 0 then
    width = max(width, RV.FIGURE_MIN)
    fit.w[key] = width
  end
  return width
end

-- The sender column's CEILING, from the four outcome labels in `sample`'s font.
-- The column itself is the widest sender actually listed, up to this: a list
-- of short names gives the subjects the room, and a long name is cut at the
-- same width an auction label needs.
local function SenderColumnWidth(panel, sample)
  local widest = 0
  for _, outcome in pairs(AUCTION_OUTCOME) do
    widest = max(widest, MeasureWith(panel, sample, L()[outcome.key]))
  end
  return min(max(widest + 2, SENDER_MIN), SENDER_MAX)
end

-- The spots an anchor can take, by number: a row re-bound where it already
-- stands -- nearly every bind -- is then left alone without comparing a
-- string or re-anchoring anything.
RV.POINTS = { "LEFT", "RIGHT", "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT" }

-- region -> anchored to its row at POINTS[point], x, y. Everything that
-- anchors a column region goes through here, so the remembered spot is
-- always the region's real one.
function RV.Anchor(row, region, point, x, y)
  if region.__pbAt == point and region.__pbAtX == x and region.__pbAtY == y then return end
  region.__pbAt, region.__pbAtX, region.__pbAtY = point, x, y
  local name = RV.POINTS[point]
  region:ClearAllPoints()
  region:SetPoint(name, row, name, x, y)
end

-- The arrange mode's pointer on a row with no lanes to mark (the other
-- window's rows, or a figure standing in the subject's room): a soft accent wash
-- around what the row draws of the column being moved or chosen, so the
-- column its heading stands for is found in the list at a glance. On a
-- texture of the row's own, made on first use; nil takes it away, and with
-- it whatever else the mode marked on the row.
function RV.Wash(row, target)
  local wash = row.__pbWash
  if not target then
    if wash then wash:Hide() end
    -- And what the mode marked on it (Core/Arrange.lua, AR.MarkRow).
    local marks = row.__pbMarks
    if marks and marks.on then
      local A = ns.Arrange
      if A and A.UnmarkRow then A.UnmarkRow(row) end
    end
    return
  end
  if not wash then
    wash = row:CreateTexture(nil, "BACKGROUND", nil, 3)
    row.__pbWash = wash
  end
  local r, g, b = Th().GetAccent()
  wash:SetColorTexture(r, g, b, 0.22)
  wash:ClearAllPoints()
  wash:SetPoint("TOPLEFT", target, "TOPLEFT", -3, 2)
  wash:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", 3, -2)
  wash:Show()
end

-- The room a mail row's marks take at its right end, inside its trailing
-- inset: the delete mark on a read mail, with the small gap before it; on
-- a one-line row (`compact`) the smaller one. The stuck mark takes the read
-- mark's place (RV.PaintDot) and needs none. Every other number the rows
-- read for it comes from here. A two-line row keeps it clear of its text,
-- and so does a packed one-line row, whose figures close up against the
-- mark as they close up against the edge: each packed row is its own. A
-- one-line row in columns draws the mark over the end of its last column's
-- box and stands its columns where every other row does (RV.MarkReserve).
function RV.MarkRoom(compact, delete)
  if not delete then return 0 end
  return (compact and ROW_DELETE_COMPACT or ROW_DELETE) + Th().Metrics.tightGap
end

-- How much further in than its trailing inset every one-line row of the
-- Mail tab's list stands its outermost column while the rows stand in
-- columns, so that the delete mark a read mail draws over the end of the
-- last column's box never covers what that column draws on a row that
-- carries it: the mark's room where some row the list shows carries the
-- mark (`any`) AND draws something in the outermost column with a lane
-- after the subject, else none. A figure no mail listed has takes no lane;
-- a graphic or the sender always draws; a figure only on a marked row that
-- has it (`has[id]`, from the list's walk). One answer for the whole list,
-- applied to every row alike, so a row with the mark keeps its lanes and
-- its gold stands under the gold above it. The subject standing last needs
-- none: a marked row's is only cut short of the mark (RV.Place, s.markEnd),
-- where it starts unmoved. No other column reaches the mark: the one
-- inside the last starts a gap and a lane (at least FIGURE_MIN) in, clear
-- of it by as much as a row's text always was. `layout`: the arrangement;
-- `cols`: the figures' list-wide widths. Nothing is made.
function RV.MarkReserve(layout, cols, has, any, compact)
  if not any then return 0 end
  local least = RV.FIGURE_MIN
  for i = #layout, 1, -1 do
    local id = layout[i].id
    if id == "subject" then break end
    if layout[i].shown then
      if not RV.FIGURE[id] then return RV.MarkRoom(compact, true) end
      if (cols[id] or 0) >= least then return has[id] and RV.MarkRoom(compact, true) or 0 end
    end
  end
  return 0
end

-- A placement table for RV.Place, one per list, reused for every row it binds;
-- laneX and laneW are where RV.Place publishes the list's lanes; held and
-- roomX are the rooms it keeps while the arrange mode is open over the list.
function RV.NewSpec()
  return { el = {}, size = {}, text = {}, w = {}, laneX = {}, laneW = {}, held = {}, roomX = {} }
end

-- Where the read mark stands before the subject, `x` being where its column
-- begins on a row whose first column begins at `left`. Leading the row, it
-- is centred between the row's left edge and the line before the next
-- column -- the arrange mode's lane line, in the middle of the gap between
-- the two -- and that line stands as far from the next column as the line
-- after that column does from it, half a house gap: so the dot and the
-- icon after it are each centred in their column. Elsewhere it sits in the
-- gap before the next column, as a bullet does.
function RV.DotX(x, left, gap)
  if x ~= left then return x - 3 end
  local line = x + ROW_INDICATOR + 2 - 1 - floor(gap / 2)
  return floor((line - (ROW_INDICATOR - 1)) / 2)
end

-- The read mark's soft shadow (Theme.GLYPHS "dot-shadow"): black at a low
-- alpha, behind the dot and a unit under it, shown and hidden with it at the
-- end of every RV.Place. Made once with the row; nil where the art is
-- missing.
RV.SHADE_ALPHA = 0.5

function RV.ShadeDot(row)
  local dot, T = row.Indicator, Th()
  local shade = dot and T.Glyph and T.Glyph(row, "dot-shadow", nil, "ARTWORK") or nil
  if not shade then return end
  shade:SetDrawLayer("ARTWORK", -1)
  shade:SetVertexColor(0, 0, 0, RV.SHADE_ALPHA)
  shade:SetPoint("CENTER", dot, "CENTER", 0, -1)
  shade:SetShown(dot:IsShown())
  dot.__pbShade = shade
end

-- The read mark's paint for the mail a row is bound to: its colour, read
-- or unread -- or, on a mail the server refused (stuck), none. There a
-- warning triangle stands in the dot's place: the row's `el.stuck`,
-- anchored to the dot's centre when the row is made and shown by RV.Place
-- where the dot is. The dot keeps its place, so the column, its lane and
-- the arrange mode's grip on it are the same on every row; it is just not
-- drawn. A shape, not a colour, so it reads colour-blind and on a window
-- faded near to nothing. A stuck mail has been tried, so it is read: the
-- dot there only ever said so.
function RV.PaintDot(dot, read, stuck)
  if stuck then
    dot:SetVertexColor(1, 1, 1, 0)
  else
    Th().SetColor(dot, read and "read" or "unread")
  end
end

-- The sender's colour for the mail a row (or the reading pane) is bound to:
-- a player whose class Postbox knows -- one of the player's own characters,
-- or a friend, guildmate or contact the address book has learned
-- (ContactService.ClassOf) -- in that class's colour; anyone else, and an
-- auction outcome, whose words carry their own tone, in the text's role
-- colour (`role`, "label" by default) as ever. `sender` is the mail's own,
-- nil where the column says something else; `realm` the box's realm (nil:
-- the one being played). The class the string wears is kept on it and the
-- colour written only when that changes, so a pooled row bound to somebody
-- else next never keeps the last one's colour, and an unknown sender costs
-- one lookup and no write. The colour is the player's UI's where it keeps
-- class colours of its own (ContactService.ClassColour); when that palette
-- changes, ContactService repaints the strings it was told wear one
-- (CS.WearClass), so a bind with the same class still skips the write.
function RV.PaintSender(fs, sender, realm, role)
  if not fs then return end
  local CS = ns.ContactService
  local token = (sender and CS and CS.ClassOf) and CS.ClassOf(sender, realm) or nil
  if token == fs.__pbClass then return end
  local r, g, b
  if token and CS.ClassColour then r, g, b = CS.ClassColour(token) end
  local T = Th()
  if r then
    fs.__pbClass = token
    T.SetTextRGB(fs, r, g, b)
  else
    fs.__pbClass = nil
    T.SetColor(fs, (T.TextRoles[role or "label"] or T.TextRoles.label).color)
  end
  if CS and CS.WearClass then CS.WearClass(fs, fs.__pbClass) end
end

-- What a graphic takes from the text area: the dot sits in the gap before
-- its neighbour on the left of the subject, as a bullet does -- two in from
-- the icon, as the dot has always stood -- and takes a gap like any other
-- column on the right.
function RV.Footprint(id, before, size, gap)
  if id == "read" then return before and (ROW_INDICATOR + 2) or (ROW_INDICATOR - 1 + gap) end
  return (size.icon or 0) + gap
end

-- THE placement of a mail row's columns, and the only one: the Mail tab's
-- two row sizes, History's rows and Mail Memory's all come through here, so
-- a column the player moves moves in every list that follows the same
-- arrangement at once (History follows its own: s.layout).
--
-- The row is read in the arrangement's order and split at the subject --
-- the one column with no width of its own, which takes what the others
-- leave. What stands before it stands from the left edge; what stands
-- after it from the right edge inward, so every row ends on the same edge.
-- Then the player's choice (Row layout, RV.LinedUp):
--   Columns    a figure the arrangement shows keeps its column on every
--              row, so gold stands under gold, and the subjects start on
--              one line. A lane this mail leaves empty is kept and not
--              drawn, and the subject runs on through the empty lanes after
--              it, up to the first thing the mail has. A figure with no
--              lane in the list -- hidden by the arrangement but shown on
--              this row anyway (`force`), or left no room by the lanes
--              further out in a narrow list -- takes the subject's room
--              next to it on its own side, within the row's share, and no
--              lane moves for one row.
--   Packed     each row closes its gaps away from the subject: a figure
--              this mail does not have takes NO room, and what stands
--              beyond it moves up toward the edge on its side -- the right
--              edge after the subject, the left edge before it -- so the
--              subject has all the room the mail's own figures leave. One
--              rule for any arrangement; the graphics and the sender close
--              up with the figures, and the gaps between columns and at the
--              edges are the same as in Columns.
-- The figures together may claim at most `share` of the text area: the
-- sender and the subject are what a mailbox is scanned by.
--
-- The two-line row -- the Mail tab's Larger mail rows, which follow an
-- arrangement of their own (RV.LargeLayout) -- keeps the arrangement's
-- order on each line: the icon and the dot keep their side, the sender and
-- the subject share the first line in their order, or the sender is written
-- into the second line among the figures where a figure stands between the
-- two (RV.SenderLine), and the figures are written out in theirs on the
-- second. It has no columns to line up, and is placed the same either way.
-- While the arrange mode is open over it, it records where each part
-- stands (RV.RecordTwo) and keeps rooms for its header's pegs.
--
-- While a one-line row is lined up, each column's lane is published into
-- the spec as it is placed, in units from the row's left edge: s.laneX[id],
-- s.laneW[id], for every column this list has. A lane is what the column
-- draws in -- its content -- and nothing more: the arrange mode's column
-- boxes are drawn from the lanes by one rule of its own (Core/Arrange.lua,
-- AR.CellBox), which gives the row's edge insets to the columns at its
-- ends. The subject's is its own room, before it runs on; a column with no
-- room is 0 wide where it would stand. One row's lanes are its whole
-- list's -- every row of a list in columns has the same trailing room, a
-- read mail's delete mark drawing over its last column (RV.MarkReserve) --
-- so a binder may set s.publish before each pass, and only the first row
-- placed publishes. Packed, a row's figures are its own and nothing is published,
-- but for the arrange mode: while it is open the header still stands on
-- each column's home lane, where a row with every figure has it in
-- Columns, and the row publishes those instead (RV.HomeLanes).
--
-- While the arrange mode is open over the list a row stands in, whatever
-- its header shows has room in the row too: a hidden column (its peg) and
-- a shown figure with no lane in the list (its narrow heading) each keep an
-- empty lane where the arrangement puts them, as wide as makes the column's
-- box the heading's own width (RV.RoomWidth), and the row's content steps
-- aside by that room. So the headings beside it and their cells end at its
-- edges. The rooms are the list's (s.held, the
-- room's width by column), placed like any column in Columns and packed
-- with the others in Packed (s.roomX, where this row keeps each), and a
-- subject never runs on through one. Out of the mode no row keeps any.
--
-- `s` (RV.NewSpec, reused):
--   width, left, trail, gap   the row's width; where its first column may
--                             start; what its trailing inset takes (with
--                             its marks, RV.MarkRoom, but on a one-line
--                             row in columns); the step
--   markEnd                   a one-line row's delete mark: no text of the
--                             row runs nearer its right edge than this
--                             (nil: none)
--   layout                    the arrangement the row follows (nil: the
--                             mail rows', RV.Layout; History's rows are
--                             handed their own)
--   el[id]                    the region drawing each column (nil: this list
--                             has no such column); el.detail the second line;
--                             el.stuck the warning triangle anchored to the
--                             read mark (RV.PaintDot)
--   stuck                     true: this mail is stuck, and el.stuck shows
--                             where the read mark stands
--   markW                     the room every row keeps before its subject's
--                             text for the quality mark (RV.NameMarkRoom;
--                             nil: none); inside the subject's own room, so
--                             its lane and every other column stay put
--   size.icon                 the icon's width
--   cols[id], senderCol       the figures' list-wide widths; the sender's
--   text[id]                  what each text column says (a figure nil: this
--                             mail does not have it)
--   share, reserve            the figures' cap (nil: none); whether a figure
--                             keeps its room on a row without it (History)
--   force                     a hidden figure this row shows anyway (a C.O.D.
--                             price always shows)
--   two, top, bottom          the two-line row, and its lines' offsets
--   detailText                the second line
--   focus                     the column the arrange mode points at
--   laneX[id], laneW[id]      written here: each column's lane (above)
--   held[id], roomX[id]       written here while arranging: each room's
--                             width, and where this row keeps it (above)
--   publish                   true: the next row placed publishes, the rest
--                             of the pass not; nil: every row does
function RV.Place(row, s)
  local layout = s.layout or RV.Layout()
  local T = Th()
  local el, text, cols, size, w = s.el, s.text, s.cols or {}, s.size, s.w
  local gap, two, force = s.gap, s.two, s.force
  -- Lanes are a one-line row's: the two-line row writes its figures out.
  local lanes = not two and RV.LinedUp()
  local publish = lanes and s.publish ~= false
  local laneX, laneW = s.laneX, s.laneW
  if publish then
    if s.publish then s.publish = false end
    if not laneX then
      laneX, laneW = {}, {}
      s.laneX, s.laneW = laneX, laneW
    end
  end
  local n = #layout
  local at = n
  for i = 1, n do
    if layout[i].id == "subject" then at = i break end
  end

  -- While the arrange mode is open over the list this row stands in, the
  -- rooms its header's pegs and narrow headings keep (above). A two-line
  -- row keeps rooms only for what its header stands over: a hidden graphic,
  -- the whole row's height, and a hidden sender on its first line (below).
  local held
  local Arr = ns.Arrange
  if Arr and Arr.host and Arr.StandWidth and Arr.HEAD and s.held then
    local list = Arr.host.List and Arr.host.List()
    if list and row:GetParent() == list then held = s.held end
  end

  -- The graphics' footprint on both sides, and so the text area between;
  -- the pegs' rooms come out of it as well.
  local fixed = 0
  for i = 1, n do
    local id = layout[i].id
    if layout[i].shown and el[id] and (id == "read" or id == "icon") then
      fixed = fixed + RV.Footprint(id, i < at, size, gap)
    end
    if held then
      local r = nil
      if el[id] and not layout[i].shown and id ~= "subject" and (not two or id == "read" or id == "icon") then
        r = RV.RoomWidth(s, layout, i, at, Arr.StandWidth(id, true), Arr.HEAD.GAP)
      end
      held[id] = r
      if r then fixed = fixed + r + gap end
    end
  end
  local textWidth = max(s.width - s.left - s.trail - fixed, 60)

  -- The figures' widths: those after the subject from the edge in, then
  -- those before it, out of one allowance. Lined up, a figure the
  -- arrangement shows has its width whether this mail has it or not, as
  -- History's reserve does; a hidden one forced onto this row is left to
  -- the subject's room (below). Packed, on either side, only what the mail
  -- has.
  local room = s.share and floor(textWidth * s.share) or textWidth
  local used = 0
  -- The narrowest a figure's column may be drawn (RV.FIGURE_MIN).
  local least = RV.FIGURE_MIN
  -- Lined up: whether a figure the row may show has no lane (below).
  local laneless = lanes and force ~= nil and not layout.shown[force]
  -- While arranging, what the home lanes have taken (RV.HomeLanes): a
  -- shown figure with none has a narrow heading, and its room.
  local homeUsed = 0
  for pass = 1, 2 do
    local from, to, step = n, at + 1, -1
    if pass == 2 then from, to, step = 1, at - 1, 1 end
    for i = from, to, step do
      local id = layout[i].id
      if RV.FIGURE[id] and el[id] then
        local width = 0
        if (layout[i].shown or (force == id and not lanes)) and not two then
          local has = s.reserve or lanes or text[id] ~= nil
          width = min(cols[id] or 0, room - used)
          if not has or width < least then
            if lanes and width < least and (cols[id] or 0) >= least then laneless = true end
            width = 0
          end
        end
        w[id] = width
        if width > 0 then used = used + width + gap end
        if held and not two and layout[i].shown then
          local home = width
          if not lanes then
            home = min(cols[id] or 0, room - homeUsed)
            if home < least then home = 0 end
          end
          if home > 0 then
            homeUsed = homeUsed + home + gap
          else
            local r = RV.RoomWidth(s, layout, i, at, Arr.StandWidth(id, false), Arr.HEAD.GAP)
            held[id] = r
            used, homeUsed = used + r + gap, homeUsed + r + gap
          end
        end
      end
    end
  end
  -- Packed while the arrange mode is open: the home lanes, for the header
  -- (above).
  if not lanes and not two and s.publish ~= false then
    local A = ns.Arrange
    if A and A.host then
      if s.publish then s.publish = false end
      RV.HomeLanes(s, layout, at, textWidth, room, held)
    end
  end

  local lineWidth = max(textWidth - used, 40)
  local senderShown = layout.shown.sender and el.sender ~= nil
  local senderW = senderShown and min(s.senderCol or SENDER_MIN, floor(lineWidth / 2)) or 0
  local subjectW = max(lineWidth - (senderShown and (senderW + gap) or 0), 20)

  local focus, target = s.focus, nil
  -- What this row's own figures take, lined up (below).
  local drawn = 0
  local x = s.left
  for i = 1, at - 1 do
    local id = layout[i].id
    local region = el[id]
    if region then
      local placed = false
      local lx, lw = x, 0
      if layout[i].shown or force == id then
        if id == "read" then
          lx, lw = RV.DotX(x, s.left, gap), ROW_INDICATOR - 1
          RV.Anchor(row, region, 1, lx, 0)
          x = x + ROW_INDICATOR + 2
          placed = true
        elseif id == "icon" then
          RV.Anchor(row, region, 1, x, 0)
          lw = size.icon or 0
          x = x + (size.icon or 0) + gap
          placed = true
        elseif two then
          placed = nil  -- a name, on the first line below
        elseif id == "sender" then
          RV.Anchor(row, region, 1, x, 0)
          T.FitText(region, senderW, text.sender, region)
          lw = senderW
          x = x + senderW + gap
          placed = true
        elseif (w[id] or 0) > 0 then
          -- Lined up, a lane this mail leaves empty is kept, not drawn.
          placed = not (lanes and text[id] == nil)
          if placed then
            RV.Anchor(row, region, 1, x, 0)
            T.FitText(region, w[id], text[id] or "", nil)
            drawn = drawn + w[id] + gap
          end
          lw = w[id]
          x = x + w[id] + gap
        end
      end
      local r = held and held[id]
      if r then
        lx, lw = x, r
        x = x + r + gap
        s.roomX[id] = lx
      end
      if publish then laneX[id], laneW[id] = lx, lw end
      if placed ~= nil then
        region:SetShown(placed)
        if placed and id == focus then target = region end
      end
    end
  end

  local edge = s.trail
  for i = n, at + 1, -1 do
    local id = layout[i].id
    local region = el[id]
    if region then
      local placed = false
      local from, lw = edge, 0
      if layout[i].shown or force == id then
        if id == "read" then
          RV.Anchor(row, region, 2, -edge, 0)
          lw = ROW_INDICATOR - 1
          edge = edge + ROW_INDICATOR - 1 + gap
          placed = true
        elseif id == "icon" then
          RV.Anchor(row, region, 2, -edge, 0)
          lw = size.icon or 0
          edge = edge + (size.icon or 0) + gap
          placed = true
        elseif two then
          placed = nil
        elseif id == "sender" then
          RV.Anchor(row, region, 2, -edge, 0)
          T.FitText(region, senderW, text.sender, region)
          lw = senderW
          edge = edge + senderW + gap
          placed = true
        elseif (w[id] or 0) > 0 then
          placed = not (lanes and text[id] == nil)
          if placed then
            RV.Anchor(row, region, 2, -edge, 0)
            T.FitText(region, w[id], text[id] or "", nil)
            drawn = drawn + w[id] + gap
          end
          lw = w[id]
          edge = edge + w[id] + gap
        end
      end
      local r = held and held[id]
      if r then
        from, lw = edge, r
        edge = edge + r + gap
        s.roomX[id] = s.width - from - r
      end
      if publish then laneX[id], laneW[id] = s.width - from - lw, lw end
      if placed ~= nil then
        region:SetShown(placed)
        if placed and id == focus then target = region end
      end
    end
  end

  local subject, sender, detail = el.subject, el.sender, el.detail
  -- The quality mark's room before the subject's text, on every row
  -- ("Before the name"): part of the subject's room, lane and all.
  local mw = s.markW or 0
  if publish then laneX.subject, laneW.subject = x, subjectW end
  -- Where a one-line row's subject starts and how far it runs.
  local sx, run
  if not two then
    sx, run = x, subjectW
    if lanes then
      -- The subject runs on through the lanes next to it that this mail
      -- leaves empty, up to the first thing it has; a lane with no room
      -- takes none, and a room the arrange mode keeps stops it.
      for i = at + 1, n do
        local id = layout[i].id
        if held and held[id] then break end
        if el[id] and layout[i].shown then
          if not RV.FIGURE[id] then break end
          local width = w[id] or 0
          if width > 0 then
            if text[id] ~= nil then break end
            run = run + width + gap
          end
        end
      end
    end
    -- A row carrying a delete mark: the subject stops short of it,
    -- wherever it would have run (RV.MarkReserve keeps the columns clear).
    local markEnd = s.markEnd
    if markEnd and sx + run > s.width - markEnd then run = max(s.width - markEnd - sx, 20) end
    if lanes then
      -- A figure with no lane in this list that this row has -- one the
      -- arrangement hides but the row shows anyway (a C.O.D. price), or one
      -- the lanes further out left no room -- stands in the subject's room,
      -- next to the subject on its own side and in its own order, so no lane
      -- moves for one row. The row's own figures still claim no more than
      -- their share, as packed rows' do.
      for pass = 1, laneless and 2 or 0 do
        local from, to, step = n, at + 1, -1
        if pass == 2 then from, to, step = 1, at - 1, 1 end
        for i = from, to, step do
          local id = layout[i].id
          local region = el[id]
          if region and RV.FIGURE[id] and (w[id] or 0) == 0 and text[id] ~= nil
              and (layout[i].shown or force == id) then
            local width = min(cols[id] or 0, room - drawn, run - gap - 20 - mw)
            if width >= least then
              run = run - width - gap
              drawn = drawn + width + gap
              if pass == 2 then
                RV.Anchor(row, region, 1, sx, 0)
                sx = sx + width + gap
              else
                RV.Anchor(row, region, 1, sx + run + gap, 0)
              end
              T.FitText(region, width, text[id], nil)
              region:Show()
              if id == focus then target = region end
            end
          end
        end
      end
    end
    RV.Anchor(row, subject, 1, sx + mw, 0)
    RV.FitSubject(row, subject, run - mw, text.subject)
    subject:Show()
    -- Not drawn, so nothing of it was cut: what a two-line bind cut of the
    -- line last is not this row's tooltip's any more.
    if detail then
      detail:Hide()
      detail.__pbOverflowText = nil
    end
    -- The two-line row's figures live on its second line; this row's are
    -- columns, placed above.
    if row.__pbTwo then row.__pbTwo.on = false end
  else
    -- The names share the first line in their order; the figures are the
    -- second line's, in theirs. A figure's column region stands down.
    for id in pairs(RV.FIGURE) do
      if el[id] then el[id]:Hide() end
    end
    local top = s.top or 0
    -- The sender stands on the first line, before the subject or at its
    -- end, or on the second line (RV.SenderLine), written into it among
    -- the figures by the binder, the subject then having the first line
    -- to itself. Hidden on the first line while the arrange mode is open
    -- over the list, it keeps a room there for its peg (Core/Arrange.lua),
    -- and the subject steps aside by just that room.
    local second = el.sender ~= nil and RV.SenderLine(layout) == 2
    local before = RV.IndexOf(layout, "sender") < at
    local room = 0
    if held and el.sender and not layout.shown.sender and not second then
      room = max(Arr.StandWidth("sender", true) + Arr.HEAD.GAP - gap, 1)
    end
    local subX = x
    if senderShown and not second then
      if before then
        RV.Anchor(row, sender, 3, x, top)
        T.FitText(sender, senderW, text.sender, sender)
        subX = x + senderW + gap
        RV.Anchor(row, subject, 3, subX + mw, top)
      else
        RV.Anchor(row, subject, 3, x + mw, top)
        RV.Anchor(row, sender, 4, -edge, top)
        T.FitText(sender, senderW, text.sender, sender)
      end
      sender:Show()
    else
      if sender then sender:Hide() end
      -- Written into the second line, or hidden, the name is not the first
      -- line's to cut: what the first line cut of it last is not this row's
      -- any more.
      if sender then sender.__pbOverflowText = nil end
      subjectW = max(lineWidth - ((room > 0) and (room + gap) or 0), 20)
      if room > 0 and before then subX = x + room + gap end
      RV.Anchor(row, subject, 3, subX + mw, top)
    end
    RV.FitSubject(row, subject, subjectW - mw, text.subject)
    subject:Show()
    if detail then
      RV.Anchor(row, detail, 5, x, s.bottom or 0)
      T.FitText(detail, textWidth, s.detailText or "", detail)
      detail:Show()
    end
    if focus == "sender" and senderShown then target = second and detail or sender end
    if RV.FIGURE[focus] and layout.shown[focus] then target = detail end
    -- While the arrange mode is open over the list, where each part stands
    -- on this row, for its header and its marks.
    if held then
      RV.RecordTwo(row, s, layout, x, edge, textWidth, subX, subjectW, second, before, room, senderW)
    elseif row.__pbTwo then
      row.__pbTwo.on = false
    end
  end
  if focus == "subject" then target = subject end
  -- A hidden sender is fitted nowhere: nothing of it is cut on this row.
  if not senderShown and sender then
    sender:Hide()
    sender.__pbOverflowText = nil
  end
  -- While the arrange mode points at a column the rows show it
  -- (Core/Arrange.lua, AR.MarkRow): its lane, the subject's run, the column
  -- in the hand. Otherwise nothing is marked.
  local A = focus and ns.Arrange
  if A and A.MarkRow then
    A.MarkRow(row, s, target, lanes, x, subjectW, sx, run)
  else
    RV.Wash(row, target)
  end
  -- The read mark's shadow goes where the mark went, and with it: placed,
  -- hidden, or in the arrange mode's hand. On a stuck mail the warning
  -- triangle is shown where the mark is, and the shadow is not: the disc
  -- is the dot's size, and behind a larger triangle it shows only as a
  -- smudge beside its apex.
  local dot = el.read
  if dot then
    local on = dot:IsShown()
    local stuck = on and s.stuck == true
    local warn = el.stuck
    if warn then warn:SetShown(stuck) end
    local shade = dot.__pbShade
    if shade then shade:SetShown(on and not stuck) end
  end
  -- The quality mark before the name goes with the name: drawn, or in the
  -- arrange mode's hand.
  local named = row.QualityName
  if named then named:SetShown(named.__pbOn == true and subject:IsShown()) end
  -- And the mark after a shortened name (RV.FitSubject) the same way.
  local tail = row.QualityTail
  if tail then tail:SetShown(tail.__pbOn == true and subject:IsShown()) end
end

-- Where each part of a two-line row stands, recorded by RV.Place while the
-- arrange mode is open over the list (Core/Arrange.lua reads it for the
-- two-line header, the row's marks and what a press on the row takes), in
-- units from the row's left edge: rec.x[id], rec.w[id] for a graphic (its
-- art, or the room it keeps hidden, rec.room[id]), the sender on the first
-- line (its column, or its room) and the subject (its own room); rec.t0 and
-- rec.t1, where the text between the graphics begins and ends; rec.sender,
-- the line the sender stands on (0: the list has none); and the second
-- line's segments, one per figure and the sender written into it, in the
-- order they are written, each where the line draws it (measured when the
-- line or its font changes) and cut where the line is cut. Made with the row the first
-- time it is placed so and refilled in place; the first row placed in a
-- pass publishes its record (s.twoRec), or the first without a delete mark
-- after it, which moves what stands at the row's right end.
function RV.RecordTwo(row, s, layout, x, edge, textWidth, subX, subW, second, before, room, senderW)
  local rec = row.__pbTwo
  if not rec then
    rec = { on = false, x = {}, w = {}, room = {}, t0 = 0, t1 = 0, width = 0, sender = 0, marked = false,
      segN = 0, segId = {}, segX = {}, segW = {},
      segText = false, segCount = 0, segPath = false, segSize = false, segFlags = false, segOff = {}, segLen = {} }
    row.__pbTwo = rec
  end
  local el, held = s.el, s.held
  local rx, rw, rroom = rec.x, rec.w, rec.room
  rec.on, rec.width, rec.t0, rec.t1 = true, s.width, x, s.width - edge
  rec.marked = (s.trail or 0) > (s.left or 0) + 0.5
  for i = 1, #layout do
    local id = layout[i].id
    rx[id], rw[id], rroom[id] = nil, nil, nil
    local region = el[id]
    if region and (id == "read" or id == "icon") then
      local r = held and held[id]
      if r then
        rx[id], rw[id], rroom[id] = s.roomX[id], r, true
      elseif region:IsShown() then
        local w = region:GetWidth() or 0
        local left = region.__pbAtX or 0
        if region.__pbAt == 2 then left = s.width + left - w end
        rx[id], rw[id] = left, w
      end
    end
  end
  rec.sender = 0
  if el.sender then
    if second then
      rec.sender = 2
    elseif layout.shown.sender then
      rec.sender = 1
      rx.sender, rw.sender = before and x or (s.width - edge - senderW), senderW
    elseif room > 0 then
      rec.sender = 1
      rx.sender, rw.sender, rroom.sender = before and x or (s.width - edge - room), room, true
    end
  end
  rx.subject, rw.subject = subX, subW
  -- Each piece of the second line where the line draws it. The line is one
  -- string, and a string's measured width is more than the advance of its
  -- letters: an outline (EllesmereUI's, and Slug's more so) pads each end,
  -- so pieces measured one by one and added up ran a few units further
  -- right with every piece, and each width came rounded up besides. So a
  -- piece starts where the line up to its end measures, less the piece
  -- itself, both unrounded and in the line's own font: whatever a string's
  -- measure adds, it adds to both. Measured when the line or its font
  -- changes, and kept on the record, so a pass over lines that did not
  -- change measures nothing.
  local n = 0
  local parts, ids, owner, detail, line = s.detailParts, s.detailIds, row.panel, el.detail, s.detailText
  if parts and ids and owner and detail and line then
    local off, len = rec.segOff, rec.segLen
    local path, size, flags = detail:GetFont()
    local count = #parts
    if rec.segText ~= line or rec.segCount ~= count or rec.segPath ~= path
        or rec.segSize ~= size or rec.segFlags ~= flags then
      rec.segText, rec.segCount, rec.segPath, rec.segSize, rec.segFlags = line, count, path, size, flags
      local stop, joinLen = 0, #ROW_META_JOIN
      for k = 1, count do
        local part = parts[k]
        stop = stop + #part
        local w = MeasureWith(owner, detail, part, true)
        if k == 1 then
          off[k] = 0
        else
          off[k] = max(MeasureWith(owner, detail, line:sub(1, stop), true) - w, 0)
        end
        len[k] = w
        -- A font the client has not laid out yet measures nothing: not
        -- kept, so the next pass measures again.
        if w <= 0 and part ~= "" then rec.segText = false end
        stop = stop + joinLen
      end
    end
    local limit = x + textWidth
    for k = 1, count do
      local id, cx = ids[k], x + off[k]
      if id and cx < limit then
        n = n + 1
        rec.segId[n], rec.segX[n], rec.segW[n] = id, cx, min(len[k], limit - cx)
      end
    end
  end
  rec.segN = n
  if s.publish ~= false or s.twoMarked then
    s.twoRec, s.publish, s.twoMarked = rec, false, rec.marked
  end
end

-- The room column layout[i] keeps in a row while the arrange mode is open
-- (RV.Place), `at` being the subject's place: the lane that makes the
-- column's box `stand` wide, `stand` being its peg's or narrow heading's
-- width (Core/Arrange.lua, AR.StandWidth). A box runs from `hgap` past the
-- line before its lane to the line after it, each line in the middle of the
-- gap between two lanes (AR.CellBox). Between two columns that stand a
-- step apart the lines are half a step out; before the subject, the read
-- mark stands in the gap next to it as a bullet does (RV.DotX), so a line
-- beside it is nearer and the room as much wider. Every column the row has
-- stands in the arrangement's order while arranging, a room for each one
-- hidden, so the neighbours are the arrangement's. At either end of the row
-- the box takes in the row's inset as every end column's does, and the
-- room is the one between two columns. Nothing is made.
function RV.RoomWidth(s, layout, i, at, stand, hgap)
  local gap, el = s.gap, s.el
  -- The lines, from the room's start and from its end.
  local before, after = -ceil(gap / 2), floor(gap / 2)
  if i < at then
    local prev, nxt
    for k = i - 1, 1, -1 do
      if el[layout[k].id] then prev = k break end
    end
    for k = i + 1, at do
      if el[layout[k].id] then nxt = k break end
    end
    if prev and layout[prev].id == "read" and layout[prev].shown then
      local lead = true
      for k = prev - 1, 1, -1 do
        if el[layout[k].id] then lead = false break end
      end
      -- The mark's lane ends this far from the room's start.
      local dotEnd = -6
      if lead then dotEnd = RV.DotX(s.left, s.left, gap) - s.left - 3 end
      before = floor(dotEnd / 2)
    end
    if nxt and nxt < at and layout[nxt].id == "read" and layout[nxt].shown then
      after = floor((gap - 3) / 2)
    end
  end
  return max(stand + hgap + before - after, 1)
end

-- Each column's home lane, published into `s` as RV.Place publishes a
-- lined-up row's (s.laneX, s.laneW): where it stands on a row that has
-- every figure, which a packed row places the same way. By the
-- same arithmetic as RV.Place, from the room the row was given (`at` the
-- subject's place in `layout`, `textWidth` and `room` its text area and the
-- figures' share of it): a figure the arrangement shows is as wide as its
-- column, out of the share, and a hidden one has no lane. While the mode
-- is open over the list (`held`, RV.Place's rooms), a peg's room and a
-- narrow heading's are lanes too, where the arrangement puts them. Places
-- nothing; the widths are written straight into s.laneW, so nothing is
-- made.
function RV.HomeLanes(s, layout, at, textWidth, room, held)
  local el, cols, size, gap = s.el, s.cols, s.size, s.gap
  local laneX, laneW = s.laneX, s.laneW
  if not laneX then
    laneX, laneW = {}, {}
    s.laneX, s.laneW = laneX, laneW
  end
  local n = #layout
  local least = RV.FIGURE_MIN
  local used = 0
  for pass = 1, 2 do
    local from, to, step = n, at + 1, -1
    if pass == 2 then from, to, step = 1, at - 1, 1 end
    for i = from, to, step do
      local id = layout[i].id
      if RV.FIGURE[id] and el[id] then
        local width = 0
        if layout[i].shown then
          width = min(cols and cols[id] or 0, room - used)
          if width < least then width = 0 end
        end
        laneW[id] = width
        if width > 0 then used = used + width + gap end
        if held and layout[i].shown and held[id] then used = used + held[id] + gap end
      end
    end
  end
  local lineWidth = max(textWidth - used, 40)
  local senderShown = layout.shown.sender and el.sender ~= nil
  local senderW = senderShown and min(s.senderCol or SENDER_MIN, floor(lineWidth / 2)) or 0
  local x = s.left
  for i = 1, at - 1 do
    local id = layout[i].id
    if el[id] then
      local lx, lw = x, 0
      if layout[i].shown then
        if id == "read" then
          lx, lw = RV.DotX(x, s.left, gap), ROW_INDICATOR - 1
          x = x + ROW_INDICATOR + 2
        elseif id == "icon" then
          lw = size.icon or 0
          x = x + lw + gap
        elseif id == "sender" then
          lw = senderW
          x = x + senderW + gap
        elseif (laneW[id] or 0) > 0 then
          lw = laneW[id]
          x = x + lw + gap
        end
      end
      if held and held[id] then
        lx, lw = x, held[id]
        x = x + lw + gap
      end
      laneX[id], laneW[id] = lx, lw
    end
  end
  local edge = s.trail
  for i = n, at + 1, -1 do
    local id = layout[i].id
    if el[id] then
      local from, lw = edge, 0
      if layout[i].shown then
        if id == "read" then
          lw = ROW_INDICATOR - 1
          edge = edge + lw + gap
        elseif id == "icon" then
          lw = size.icon or 0
          edge = edge + lw + gap
        elseif id == "sender" then
          lw = senderW
          edge = edge + senderW + gap
        elseif (laneW[id] or 0) > 0 then
          lw = laneW[id]
          edge = edge + lw + gap
        end
      end
      if held and held[id] then
        from, lw = edge, held[id]
        edge = edge + lw + gap
      end
      laneX[id], laneW[id] = s.width - from - lw, lw
    end
  end
  laneX.subject = x
  laneW.subject = max(lineWidth - (senderShown and (senderW + gap) or 0), 20)
end

-- layout, id -> where the arrangement has that column.
function RV.IndexOf(layout, id)
  for i = 1, #layout do
    if layout[i].id == id then return i end
  end
  return 0
end

-- What an auction mail says where its sender would be, in its own tone, or
-- nil for any other kind of mail.
local function OutcomeSender(kind)
  local outcome = AUCTION_OUTCOME[kind]
  if not outcome then return nil end
  return Th().Colorize(outcome.role, L()[outcome.key])
end

-- Published for the mailbox memory, which draws its rows by these same rules
-- from a snapshot instead of the live inbox. One copy of the rules, so the two
-- windows cannot come to disagree about what a mail row says.
CT.RowRules = {
  Shows = RowShows,
  MoneyShown = MoneyShown,
  DisplaySender = DisplaySender,
  MoneyText = MoneyText,
  Measure = MeasureWith,
  SenderColumn = SenderColumnWidth,
  -- The one placement (RV.Place) and what it reads.
  Place = RV.Place,
  NewSpec = RV.NewSpec,
  Anchor = RV.Anchor,
  Wash = RV.Wash,
  ShadeDot = RV.ShadeDot,
  PaintDot = RV.PaintDot,
  WARNING = ROW_WARNING,
  Layout = RV.Layout,
  Focus = RV.Focus,
  IsFigure = function(id) return RV.FIGURE[id] == true end,
  -- Where a two-line row draws the sender in an arrangement.
  SenderLine = RV.SenderLine,
  FIGURE_MIN = RV.FIGURE_MIN,
  DOT = ROW_INDICATOR,
  OutcomeSender = OutcomeSender,
  PaintSender = RV.PaintSender,
  EXPIRY_SOON_DAYS = EXPIRY_SOON_DAYS,
  ExpiryState = ExpiryState,
  META_SHARE = COMPACT_META_SHARE,
  SlotsText = RV.SlotsText,
  QualityMark = RV.MarkOf,
  WithMark = RV.WithMark,
  MarkOnName = RV.MarkOnName,
  PaintQuality = RV.PaintQuality,
  PaintCount = RV.PaintCount,
  HideCount = RV.HideCount,
  SaysCount = RV.SaysCount,
  DropCount = RV.DropCount,
  -- The icon's mark by the list's own rule, for the options' sample rows.
  ShowMark = RV.ShowMark,
  PlaceMark = RV.PlaceMark,
  PaintNameMark = RV.PaintNameMark,
  NameMarkRoom = RV.NameMarkRoom,
  FitSubject = RV.FitSubject,
  HoldRange = RV.HoldRange,
  ItemLine = RV.ItemLine,
}

-------------------------------------------------------------
-- Widths
--
-- A container anchored to its parent's edges measures zero until the first
-- layout pass. Every layout function below asks for its width through this, so
-- the synchronous pass at the end of build produces the same result the first
-- resize would -- which is the whole of the "controls jump into place a frame
-- after opening" defect.
-------------------------------------------------------------

local function UsableWidth(frame, fallback)
  local width = frame and frame:GetWidth() or 0
  if width and width > 10 then return width end
  return fallback
end

local function PanelWidth(panel)
  return UsableWidth(panel, FALLBACK_PANEL_WIDTH)
end

-------------------------------------------------------------
-- The view switch
--
-- A segmented control built from Theme.CreatePlate at its `segment` variant:
-- the same control the window tabs and the compose screen's category bar are
-- drawn from, so the three read as one family and there is one place to change
-- what a plate looks like.
--
-- This file used to carry a SECOND plate implementation. It read the theme's
-- plate TOKENS -- so it inherited the opacity fix when they were raised -- but
-- it drew no bevel, hardcoded the mouse-over wash at 1,1,1,0.05 instead of
-- plateHighlight, hardcoded the selected ring's alpha at 0.9 instead of
-- accentEdge, and painted the selected caption from the RAW accent rather than
-- the derived bright tone. On a dark host accent that last one is the
-- difference between a caption and a smudge, which is exactly what
-- Theme.GetAccentTone("bright") exists to prevent.
--
-- The active accent is still resolved on every repaint and never cached: the
-- factory reads Theme.GetAccentTone each time, and a host-UI skin publishing
-- the user's own accent re-drives this through CT.RepaintViewToggle.
--
-- The underline is the plate's own, not a texture parented to the container.
-- The container-owned one was defensive -- a skin's texture-stripping pass over
-- a button must not be able to take the only indication of which view is
-- showing -- and the factory answers that properly: every texture a plate owns
-- is filed in `__pbPlateArt`, and a skin that wants the selection visual
-- installs `__setSelectedOverride`, which retires that art wholesale rather
-- than stripping half of it. Neither shipped skin touches these buttons at all
-- (SkinTree only restyles frames tagged __postboxButton, which a flat segment
-- deliberately is not).
-------------------------------------------------------------

local function PaintViewToggle(panel)
  local container = panel and panel.ViewToggle
  if not container or not container.buttons then return end
  local T = Th()
  -- Another box on screen (or every box's matches) owns the selection: this
  -- character's segments stand unselected beside it, as the way back.
  local away = AV.Active(panel)
  local active = (not away) and panel.viewMode or nil

  for i = 1, #container.buttons do
    local seg = container.buttons[i]
    T.SetPlateSelected(seg, seg.segId == active)
  end
  if container.history then T.SetPlateSelected(container.history, active == VIEW_HISTORY) end
  local alt = container.alt
  if alt then
    T.SetPlateSelected(alt, away and panel._alt ~= nil)
    -- The count beside a cut name wears the caption's colour, as it does
    -- inside the whole caption.
    T.SetColor(alt.Count, alt.isSelected and "accentBright" or "plateCaption")
  end
end

-- Frozen: Core/Skin_EllesmereUI.lua calls this when the user changes their
-- accent colour live.
function CT.RepaintViewToggle(panel)
  PaintViewToggle(panel)
end

local SetViewMode  -- forward declaration; the segments call it

local function BuildViewToggle(panel)
  local T = Th()
  local container = CreateFrame("Frame", nil, panel)
  container:SetPoint("TOPLEFT", panel, "TOPLEFT", T.Metrics.inset, -T.Metrics.inset)
  container:SetHeight(T.Metrics.segmentHeight)

  container.buttons = {}
  -- The inbox, and -- only when read mail is kept in a tab of its own -- the
  -- Done segment beside it.
  local segments = {
    { id = VIEW_COLLECT, label = L()["VIEW_INBOX"] },
    { id = VIEW_DONE, label = L()["VIEW_DONE"] },
  }

  for i = 1, #segments do
    local seg = T.CreatePlate(container, "segment")
    seg.segId = segments[i].id
    -- The base caption is kept apart from the displayed text so the optional
    -- "(count)" suffix can be added and removed without corrupting the label.
    seg.baseLabel = segments[i].label
    seg:SetText(segments[i].label)
    -- From another character's box, a segment is the way home first.
    seg:SetScript("OnClick", function(self)
      AV.Leave(panel)
      SetViewMode(panel, self.segId)
    end)
    -- Hover is the plate's own OnEnter/OnLeave, installed by the factory and
    -- deliberately left alone: these segments carry no tooltip, so there is
    -- nothing to hook and nothing to replace them with.
    container.buttons[i] = seg
  end

  -- History: a square icon plate after the captions. Kept out of `buttons`,
  -- which the counts and the caption sizing walk -- it has neither.
  local hist = T.CreatePlate(container, "segment")
  hist.segId = VIEW_HISTORY
  -- The history glyph (a clock with a counter-clockwise arrow round it) at
  -- the clock's height, made once with the plate.
  hist.Icon = T.Glyph and T.Glyph(hist, "history", 11, "OVERLAY") or nil
  if hist.Icon then
    hist:SetText("")
    hist.Icon:SetPoint("CENTER")
    -- Chrome stays neutral: a grey glyph, like the captions beside it.
    hist.Icon:SetAlpha(0.85)
  else
    hist:SetText(L()["VIEW_HISTORY"])
  end
  hist:SetScript("OnClick", function(self)
    AV.Leave(panel)
    SetViewMode(panel, self.segId)
  end)
  hist:HookScript("OnEnter", function(self)
    local UI = ns.MailboxUI
    local days = UI and type(UI.GetHistoryDays) == "function" and UI.GetHistoryDays() or 7
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L()["VIEW_HISTORY"])
    GameTooltip:AddLine(ns.Plural("HISTORY_TIP", days), 1, 1, 1, true)
    GameTooltip:Show()
  end)
  hist:HookScript("OnLeave", function() GameTooltip:Hide() end)
  container.history = hist

  -- Another character's box, while one is on screen: its name in its class
  -- colour and its count, selected, where this character's Inbox sits beside
  -- it. A click opens the character list again; a right-click goes back to
  -- this character's own box (AV.Back).
  local alt = T.CreatePlate(panel, "segment")
  alt:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  alt:SetScript("OnClick", function(_, button)
    if button == "RightButton" then AV.Back(panel) else CT.OpenPicker(panel) end
  end)
  -- The count on a caption of its own, used only while a long name is cut:
  -- the ellipsis then falls in the name and the number stays whole beside
  -- it (AV.FitPlate). Coloured as the caption is (PaintViewToggle).
  alt.Count = T.CreateText(alt, "segment")
  alt.Count:SetPoint("LEFT", alt.Text, "RIGHT", 0, 0)
  alt.Count:SetWordWrap(false)
  alt.Count:Hide()
  -- The whole name, realm and all -- the plate may show only its start --
  -- and the way back, which the plate cannot show by itself.
  alt:HookScript("OnEnter", function(self)
    if not (self.fullName and AV.Other(panel)) then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
    GameTooltip:SetText(self.fullName)
    GameTooltip:AddLine(L()["PICKER_BACK_HINT"], 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  alt:HookScript("OnLeave", function(self)
    if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
  end)
  alt:Hide()
  container.alt = alt

  panel.ViewToggle = container
end

-------------------------------------------------------------
-- Search
--
-- One box on the top row, right-aligned, narrowing the list to the mails
-- whose sender or subject contains what is typed. It is a view of the same
-- list, not a fourth view: the segment counts still describe the whole
-- inbox, and the totals banner still describes what is listed. While a
-- search is on, each category sweep takes the mails on screen of its own
-- kind, and the full-width button reads "Collect shown" and takes exactly
-- the mails on screen -- "All mail" under a list of three would otherwise
-- take fifty.
-------------------------------------------------------------

local SEARCH_W = 150

local function Trim(text) return ns.Helpers.NormalizeText(text) end

-- The query as typed, trimmed; "" when the box is empty or not built.
local function SearchQuery(panel)
  local box = panel and panel.SearchBox
  if not box then return "" end
  return Trim(box:GetText() or "")
end

local function Searching(panel)
  return SearchQuery(panel) ~= ""
end

-- The case fold the address book uses (Cyrillic-aware, see Lib/Util.lua),
-- so a Russian player searching in lowercase finds a capitalised sender.
local function Fold(text) return ns.Helpers.Lower(text) end

local function BuildSearchBox(panel)
  local T = Th()
  local M = T.Metrics

  -- Theme's search box, as Mail Memory's is: the toggle inside its right end
  -- searches every character's box -- on History, every character's History
  -- (AV.Paint shows it and places the clear button beside it).
  local search = T.CreateSearchBox(panel, SEARCH_W, M.segmentHeight, L()["SEARCH_PLACEHOLDER"], {
    onTextChanged = function(text)
      local searching = Trim(text) ~= ""
      -- Emptied by a switch between Inbox and History (AV.ResetSearch),
      -- which refreshes once itself.
      if panel._searchQuiet then
        panel._searchOn = searching
        return
      end
      -- The footer changes shape only when the search turns on or off, not
      -- on every keystroke inside one.
      if searching ~= (panel._searchOn == true) then
        panel._searchOn = searching
        CT.RefreshCategoryButtons(panel)
        -- With every box searched, a query is what puts the matches on screen.
        if panel._searchAll then AV.Paint(panel) end
      end
      CT.RefreshMailList(panel)
    end,
    onToggle = function()
      panel._searchAll = not panel._searchAll
      if panel.MailListScroll then panel.MailListScroll:SetVerticalScroll(0) end
      AV.Paint(panel)
      CT.RefreshMailList(panel)
    end,
    toggleTip = function(tip)
      tip:SetText(L()["MEMORY_SEARCH_ALL_TITLE"])
      local key = panel._searchAll and "MEMORY_SEARCH_ALL_ON" or "MEMORY_SEARCH_ALL_OFF"
      if AV.History(panel) then
        key = panel._searchAll and "MEMORY_SEARCH_ALL_HISTORY_ON" or "MEMORY_SEARCH_ALL_HISTORY_OFF"
      end
      tip:AddLine(L()[key], 1, 1, 1, true)
    end,
  })
  local wrap = search.Wrap
  wrap:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -M.inset, -M.inset)
  panel.Search = search
  panel.SearchWrap, panel.SearchBox, panel.SearchPlaceholder = wrap, search.Box, search.Placeholder
  panel.SearchAll, panel.SearchClear = search.All, search.Clear

  -- The character picker, left of the search box: it wears the crest of the
  -- box on screen, and lists every character with mail to look at.
  local picker = T.CreatePlate(panel, "segment")
  picker:SetSize(M.segmentHeight, M.segmentHeight)
  -- One unit with the search it scopes, so the snug step of a switch's
  -- segments, as Inbox and History are.
  picker:SetPoint("RIGHT", wrap, "LEFT", -M.space.snug, 0)
  picker:SetText("")
  picker.Icon = picker:CreateTexture(nil, "OVERLAY")
  picker.Icon:SetSize(M.segmentHeight - 8, M.segmentHeight - 8)
  picker.Icon:SetPoint("CENTER")
  -- A right-click, while another character's box is on screen, goes back to
  -- this character's own (AV.Back); on this character's own it does nothing.
  picker:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  picker:SetScript("OnClick", function(_, button)
    if button == "RightButton" then AV.Back(panel) else CT.OpenPicker(panel) end
  end)
  picker:HookScript("OnEnter", function(self) AV.PickerTip(self, panel) end)
  picker:HookScript("OnLeave", function() GameTooltip:Hide() end)
  picker:Hide()
  panel.Picker = picker
end

-- The auction outcome a row shows where its sender would be ("AH Sold"), so
-- a search finds the mail by the words on screen, as the other lists do.
function RV.OutcomeMatches(index, query)
  local outcome = AUCTION_OUTCOME[Mail().ClassifyMail(index)]
  return outcome ~= nil and Fold(L()[outcome.key]):find(query, 1, true) ~= nil
end

-- Frozen: Core/MailboxUI.lua calls this when the mailbox closes. A search is
-- a question about THIS inbox; the next one starts unfiltered.
function CT.ClearSearch(panel)
  local box = panel and panel.SearchBox
  if box and box:GetText() ~= "" then box:SetText("") end
  if panel then
    panel._stuckOnly = false
    -- And back to this character's own box: a later visit must never open
    -- on somebody else's mail.
    panel._alt = nil
    panel._searchAll = false
    AV.Paint(panel)
    if ns.MailMemory and ns.MailMemory.ClosePicker then ns.MailMemory.ClosePicker() end
    -- And the folded text History's search built: kept only while in use.
    if RV.ForgetHistorySearch then RV.ForgetHistorySearch() end
  end
end

-------------------------------------------------------------
-- Selection
--
-- Pick the mails to collect before collecting them. Shift-click a row and
-- it is selected; shift-click another and everything between the two is;
-- ctrl-click picks or unpicks single rows anywhere. The gestures are the
-- file manager's, because that is where everyone learned them. Only mail
-- with something left to collect can be picked -- a finished mail has no
-- part in a collect run -- and a selection can be made inside a search:
-- the range runs over the rows on screen, whatever narrowed them.
--
-- The selection is a set of inbox INDICES, which is the one thing a collect
-- run needs and the one thing an inbox reindex invalidates. So it lives
-- exactly as long as the inbox it was made in: the moment the mail count
-- changes -- a collect, a delete, a return, new mail landing -- or any pick
-- stops naming the mail it was made on (a mail going and another arriving
-- in one update reindexes with the count unchanged), it is dropped rather
-- than allowed to name different mails. Each pick keeps the fingerprint its
-- mail had, and every list refresh checks them (RV.SelectionHolds). A run
-- started from it takes the selected indices through the same queue the
-- sweeps use.
--
-- While anything is selected the footer behaves as it does under a search:
-- the category sweeps withdraw and the one button reads "Collect N
-- selected" and takes exactly those.
-------------------------------------------------------------

local function Selection(panel)
  local set = panel._selected
  if not set then
    set = {}
    panel._selected = set
  end
  return set
end

local function SelectionCount(panel)
  return panel._selectedCount or 0
end

local function Selecting(panel)
  return SelectionCount(panel) > 0
end

-- The selected rows' wash: the accent at low alpha over the stripe, and a
-- bar at the left edge. Separate textures over the row's own background,
-- so the hover repaint (which rewrites that background) leaves them be.
local function PaintRowSelection(panel, row)
  local on = panel._selected ~= nil and row.mailIndex ~= nil
    and panel._selected[row.mailIndex] == true
  if on and not row._selBar then
    local T = Th()
    row._selWash = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row._selWash:SetAllPoints()
    row._selBar = row:CreateTexture(nil, "ARTWORK")
    row._selBar:SetWidth(2)
    row._selBar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row._selBar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    local r, g, b = T.GetAccent()
    row._selWash:SetColorTexture(r, g, b, 0.14)
    r, g, b = T.GetAccentTone("mark")
    row._selBar:SetColorTexture(r, g, b, 0.9)
  end
  if row._selBar then
    if on then
      -- Re-tinted on every paint: the accent can change under a host skin.
      -- The bar is a mark: the accent's mark tone, legible on a light list.
      local r, g, b = Th().GetAccent()
      row._selWash:SetColorTexture(r, g, b, 0.14)
      r, g, b = Th().GetAccentTone("mark")
      row._selBar:SetColorTexture(r, g, b, 0.9)
    end
    row._selWash:SetShown(on)
    row._selBar:SetShown(on)
  end
end

-- Re-paints every bound row and the footer: the primary button's caption
-- carries the count, so it is redrawn on every change and not only when the
-- selection appears or empties.
local function AfterSelectionChange(panel)
  local rows = panel._rows or {}
  for i = 1, #rows do
    if rows[i].mailIndex then PaintRowSelection(panel, rows[i]) end
  end
  CT.RefreshCategoryButtons(panel)
end

local function ClearSelection(panel)
  if not panel or not Selecting(panel) then return end
  panel._selected, panel._selectedCount = nil, 0
  panel._selectedFp = nil
  panel._selectAnchor = nil
  -- The selection's generation, which its counts are kept against
  -- (RV.SelectionCounts).
  panel._selGen = (panel._selGen or 0) + 1
  AfterSelectionChange(panel)
end

-- `fingerprint`: the picked mail's, as its row showed it -- what the pick is
-- checked against on every refresh (RV.SelectionHolds).
local function SetSelected(panel, index, on, fingerprint)
  local set = Selection(panel)
  if (set[index] == true) == on then return end
  set[index] = on or nil
  local prints = panel._selectedFp
  if not prints then
    prints = {}
    panel._selectedFp = prints
  end
  prints[index] = on and fingerprint or nil
  panel._selectedCount = SelectionCount(panel) + (on and 1 or -1)
  panel._selGen = (panel._selGen or 0) + 1
end

-- Whether every pick still names the mail it was made on. One header read
-- per pick, and a pick that still matches builds no new string: its
-- fingerprint is the one already made, and Lua hands the same one back.
function RV.SelectionHolds(panel)
  local prints = panel._selectedFp
  for index in pairs(panel._selected or RV.NONE) do
    if not prints or prints[index] == nil or Fingerprint(index) ~= prints[index] then return false end
  end
  return true
end

local function SelectToggle(panel, row)
  local index = row.mailIndex
  if not index then return end
  local set = Selection(panel)
  SetSelected(panel, index, not set[index], row.fingerprint)
  -- The row just picked is where the next shift-click measures from,
  -- picked or unpicked: that is the file manager's rule too.
  panel._selectAnchor = row._rowIndex
  AfterSelectionChange(panel)
end

-- Shift-click. A row that is already picked is unpicked -- shift is the
-- only modifier most people will reach for, so it has to be able to undo
-- what it did. Otherwise, with something picked, everything between the
-- anchor and this row is picked; with nothing picked, this row is.
local function SelectRange(panel, row)
  local index = row.mailIndex
  if not index then return end
  local set = Selection(panel)
  local anchor = panel._selectAnchor
  if set[index] or not anchor or not Selecting(panel) then
    SelectToggle(panel, row)
    return
  end
  local from, to = anchor, row._rowIndex or anchor
  if from > to then from, to = to, from end
  local filtered, done = panel._filtered, panel._filteredDone
  for position = from, to do
    local at = filtered[position]
    if at and not done[position] then SetSelected(panel, at, true, Fingerprint(at)) end
  end
  panel._selectAnchor = row._rowIndex
  AfterSelectionChange(panel)
end

-- The selected indices, highest first: the order a collect run wants them
-- in, so that taking one never shifts the ones still to come.
local function SelectionIndices(panel)
  local out = {}
  for index in pairs(panel._selected or {}) do out[#out + 1] = index end
  table.sort(out, function(a, b) return a > b end)
  return out
end

-- The title bar's "Stuck: N", clicked (Core/MailboxUI.lua). Toggles the
-- inbox between everything and only the refused mails -- or sets it, when
-- `on` is given -- and puts the inbox on screen if History was.
function CT.ToggleStuckFilter(panel, on)
  if not panel then return end
  -- The stuck mail is this character's: from another box, come home first.
  if panel._alt or panel._searchAll then
    panel._alt, panel._searchAll = nil, false
    AV.Paint(panel)
  end
  if on == nil then on = not StuckOnly(panel) end
  panel._stuckOnly = on and Mail().StuckCount() > 0
  -- A selection made over the whole list would reach rows the filter hides.
  ClearSelection(panel)
  if panel.viewMode ~= VIEW_COLLECT then
    SetViewMode(panel, VIEW_COLLECT)
  else
    if panel.MailListScroll then panel.MailListScroll:SetVerticalScroll(0) end
    CT.RefreshMailList(panel)
  end
  CT.RefreshCategoryButtons(panel)
  local UI = ns.MailboxUI
  if UI and UI.UpdateStatusSummary then UI.UpdateStatusSummary() end
end

function CT.StuckFilterOn(panel)
  return StuckOnly(panel)
end

-- Sizes every segment to the longest rendered caption -- counts included -- and
-- lays them out. A fixed width sized for English "Read (99+)" is what clipped
-- the German and Russian captions into their neighbour.
-- The segments actually on screen, in order. Hiding one is a layout fact,
-- not a special case: everything below sizes and spaces what this returns.
-- Done is this character's read mail, so it steps out while another box is
-- on screen (`other`), and is back the moment this one is.
-- The list is the container's own, filled again on every layout: a list
-- refresh lays the row out, and nothing reads the list past the layout.
local function VisibleSegments(container, other)
  local shown = container._shownSegs
  if not shown then
    shown = {}
    container._shownSegs = shown
  end
  local n = 0
  local tab = RV.Mode() == "tab" and not other
  for i = 1, #container.buttons do
    local seg = container.buttons[i]
    local on = (seg.segId ~= VIEW_DONE) or tab
    seg:SetShown(on)
    if on then
      n = n + 1
      shown[n] = seg
    end
  end
  for i = #shown, n + 1, -1 do shown[i] = nil end
  return shown
end

-- History is offered unless the player chose "Never" (Options, Mail tab),
-- which turns it off.
function RV.HistoryOn()
  local UI = ns.MailboxUI
  return not (UI and type(UI.GetHistoryDays) == "function") or UI.GetHistoryDays() > 0
end

local function LayoutViewToggle(panel)
  local container = panel.ViewToggle
  if not container or not container.buttons then return end
  local T = Th()
  -- The ladder's `snug` rung is defined as "two controls acting as one unit
  -- (the segments of a switch)", which is precisely what these are. It was
  -- tightGap, the padding rung, so the group read a shade tighter than the
  -- design says a switch should.
  local gap = T.Metrics.space.snug
  -- Another character's box: nothing there can be deleted or collected, and
  -- History is this character's, so the row is the Inbox (the way home), the
  -- box's name, the picker and the search.
  local other = AV.Other(panel)
  local shown = VisibleSegments(container, other)

  -- The sizing's options, the container's own and set afresh each time.
  local opts = container._sizeOpts
  if not opts then
    opts = {}
    container._sizeOpts = opts
  end
  opts.height, opts.gap, opts.minWidth = T.Metrics.segmentHeight, gap, T.Metrics.buttonMinWidth
  local per, total = T.SizeRow(shown, opts)

  for i = 1, #shown do
    local seg = shown[i]
    seg:ClearAllPoints()
    seg:SetPoint("LEFT", container, "LEFT", (i - 1) * (per + gap), 0)
  end
  -- The history plate: square when it wears the icon, its caption's width
  -- when it fell back to text. Out of the row, which closes up without it,
  -- while History is off.
  local hist = container.history
  if hist then
    local histShown = not other and RV.HistoryOn()
    hist:SetShown(histShown)
    if histShown then
      local width = hist.Icon and T.Metrics.segmentHeight + 6
        or ceil(T.TextWidth(hist)) + 2 * T.Metrics.tightGap + 8
      hist:SetSize(width, T.Metrics.segmentHeight)
      hist:ClearAllPoints()
      hist:SetPoint("LEFT", container, "LEFT", total + gap, 0)
      total = total + gap + width
    end
  end
  container:SetWidth(max(total, 1))

  -- The right-hand end of the row, which gives way to nothing: the search box,
  -- the picker left of it, and the other box's name left of that -- which is
  -- given the room the rest of the row leaves it (AV.FitPlate). `least` is the
  -- same end with the name at its narrowest.
  local M = T.Metrics
  local row = PanelWidth(panel) - 2 * M.inset
  local right = panel.SearchWrap and SEARCH_W or 0
  if panel.Picker and panel.Picker:IsShown() then right = right + M.space.snug + M.segmentHeight end
  local least = right
  local alt = container.alt
  if alt and alt:IsShown() and alt.natW then
    right = right + M.space.snug + AV.FitPlate(panel, row - total - M.gap - right - M.space.snug)
    least = least + M.space.snug + alt.minW
  end

  -- The hint shares the top row. It is genuinely optional text, so it is shown
  -- only when it fits beside the segments in full: clipping it would be worse
  -- than not showing it, and it has no frame of its own to hang a tooltip on.
  local hint = panel.Hint
  if hint then
    -- A gap either side of it.
    local room = row - total - M.gap - right - M.gap
    hint:SetShown(room >= T.TextWidth(hint) and not AV.Active(panel))
  end

  PaintViewToggle(panel)

  -- The width this row needs, whatever the window is now: the segments as
  -- measured, a gap, and the right-hand end with the name at its narrowest.
  -- Where the window is narrower than that, the window's floor is raised to
  -- it (Core/MailboxUI.lua, UI.RefreshCollectWidth) -- which hears of it only
  -- when it moves. Last, so a resize it causes finds the row already laid.
  local need = ceil(total + M.gap + least + 2 * M.inset)
  if need ~= panel._needW then
    panel._needW = need
    local UI = ns.MailboxUI
    if UI and type(UI.RefreshCollectWidth) == "function" then UI.RefreshCollectWidth() end
  end
  -- While the arrange mode's column header stands in the row's place, what
  -- was just laid out stays out of sight (CT.ArrangeHost).
  if panel._topHidden then RV.HideTopRow(panel) end
end

-- Frozen: Core/MailboxUI.lua reads this for the window's floor. The panel
-- width the top row needs (see LayoutViewToggle); 0 before the first layout.
function CT.MinPanelWidth(panel)
  return panel and panel._needW or 0
end

-- Frozen: Core/MailboxUI.lua calls this when the read-mail option changes.
-- A hidden segment cannot be the one on screen, so the Done view falls back
-- to the inbox -- and that path re-lays the row on its way through.
function CT.RefreshReadMode(panel)
  if not panel or not panel.ViewToggle then return end
  if RV.Mode() ~= "tab" and panel.viewMode == VIEW_DONE then
    SetViewMode(panel, VIEW_COLLECT)
  end
  CT.UpdateTabCounts(panel)
  RequestRefresh(panel)
end

-- Frozen: Core/MailboxUI.lua calls this when History's days change. The
-- row is laid out again, since at "Never" History's plate leaves it (and
-- comes back after). Off, the view lets go of what it last listed, as the
-- record it came from is gone; and a view that is not offered cannot be
-- the one on screen, so History falls back to the inbox, which lists
-- itself.
function CT.RefreshHistoryDays(panel)
  if not panel or not panel.ViewToggle then return end
  LayoutViewToggle(panel)
  if not RV.HistoryOn() and panel._history then Clear(panel._history) end
  if panel.viewMode == VIEW_HISTORY and not RV.HistoryOn() then
    SetViewMode(panel, VIEW_COLLECT)
  else
    RequestRefresh(panel)
  end
end

-------------------------------------------------------------
-- Segment counts
-------------------------------------------------------------

-- The true count, however large: the segments and buttons are measured from
-- their rendered captions, so three digits cannot push a neighbour out (a
-- "99+" cap used to stand in for that).
local function FormatCount(n)
  return tostring(n)
end

-- panel -> nothing. The three numbers come from CT.InboxCounts and from nowhere
-- else, which is what guarantees the arithmetic a reader will do on them --
-- Collect + Done = All -- actually holds rather than merely tending to.
function CT.UpdateTabCounts(panel)
  local container = panel and panel.ViewToggle
  if not container or not container.buttons then return end

  local show = ShowTabCounts()
  -- Asked for only when a caption will carry it: with the option off the walk
  -- this can trigger would be paid for a number nobody is shown.
  local toCollect, done, total, server
  if show then toCollect, done, total, server = CT.InboxCounts() end
  local tabbed = RV.Mode() == "tab"

  for i = 1, #container.buttons do
    local seg = container.buttons[i]
    local base = seg.baseLabel or seg:GetText() or ""
    if show then
      -- Each segment counts the mail it holds. The Inbox is the whole box --
      -- read mail with nothing left included, and mail the server holds past
      -- what the client lists -- unless read mail has a Done tab of its own,
      -- which then counts it. What there is to COLLECT is the number on the
      -- button that collects it.
      local n
      if seg.segId == VIEW_DONE then
        n = done
      elseif tabbed then
        n = toCollect + max(0, server - total)
      else
        n = server
      end
      seg:SetText(base .. " (" .. FormatCount(n) .. ")")
    else
      seg:SetText(base)
    end
  end

  -- The captions just changed length, so the row has to be measured again.
  LayoutViewToggle(panel)
end

-------------------------------------------------------------
-- Other characters
--
-- The Mail tab shows another character's box, as Mail Memory remembers it:
-- pick a character with the button beside the search box and the list is
-- that box -- read-only, the same rows, the name in its class colour beside
-- this character's own Inbox, which is the way back. The toggle inside the
-- search box searches every character's box at once, each character's
-- matches under its name. The mailbox closing puts everything back to this
-- character's own box, so a later visit never opens on somebody else's mail.
-------------------------------------------------------------

function AV.Memory()
  local Memory = ns.MailMemory
  if not (Memory and type(Memory.RowsFor) == "function") then return nil end
  local UI = ns.MailboxUI
  if UI and type(UI.GetOption) == "function" and not UI.GetOption("mailMemory") then return nil end
  return Memory
end

-- Showing another box, or every box's matches for a search. On History the
-- toggle widens the search to every character's History instead, which is
-- History's own list (HV.BuildHistoryList), not the boxes'.
function AV.Active(panel)
  if not panel or not AV.Memory() then return false end
  if panel._alt then return true end
  return panel._searchAll == true and Searching(panel) and panel.viewMode ~= VIEW_HISTORY
end

-- Whether the search box searches History: this character's History view on
-- screen, not another character's box picked from it.
function AV.History(panel)
  return panel ~= nil and panel.viewMode == VIEW_HISTORY and panel._alt == nil
end

-- Inbox to History or back (SetViewMode): a search is a question about the
-- list on screen, so the next one starts empty and on this character alone.
-- Quiet: the caller refreshes the list once. Neither view is another box, so
-- the row's layout stands and only the box itself is painted again.
function AV.ResetSearch(panel)
  panel._searchAll = false
  local box = panel.SearchBox
  if box and box:GetText() ~= "" then
    panel._searchQuiet = true
    box:SetText("")
    panel._searchQuiet = nil
  end
  panel._searchOn = false
  if panel.Search then AV.PaintSearch(panel, panel._searchOthers) end
end

-- The search box's part of the paint: the every-character toggle, shown
-- while there is another box to search (`others`, as AV.Paint last found)
-- -- on History, another character's History -- and its tint; and the
-- placeholder, saying what the box searches.
function AV.PaintSearch(panel, others)
  panel._searchOthers = others
  local history = AV.History(panel)
  local toggle = others
  if history then
    local Memory = AV.Memory()
    toggle = Memory ~= nil and Memory.HistoryOthers ~= nil and Memory.HistoryOthers()
  end
  panel.Search.PaintToggle(panel._searchAll)
  panel.Search.Place(toggle)
  if panel._searchHistory ~= history then
    panel._searchHistory = history
    panel.SearchPlaceholder:SetText(L()[history and "SEARCH_HISTORY_PLACEHOLDER" or "SEARCH_PLACEHOLDER"])
  end
end

-- Showing another character's box -- one box, not every box's matches: the
-- state the plate stands for, and the one this character's Done and History
-- step out of the row for.
function AV.Other(panel)
  return panel ~= nil and panel._alt ~= nil and AV.Memory() ~= nil
end

-- The plate's widest, and the letters of a name it keeps however narrow it
-- has to go. Three: with the class colour and the crest beside them they
-- tell a roster's characters apart, where two letters too often do not; a
-- name no longer than that is never cut at all.
AV.PLATE_MAX = 160
AV.PLATE_LETTERS = 3

-- The plate's caption, measured when a box is put on screen: whole, as it is
-- shown while it fits; and the name and the count apart, with the narrowest
-- the name may go, for when it does not. `minW` is the narrowest the plate
-- itself may be, which is what the row reports as its need.
function AV.MeasurePlate(panel, plate, Memory, who)
  local M = Th().Metrics
  local name = Memory.ClassName(who.realm, who.name, true)
  local count = ""
  if ShowTabCounts() then
    count = " (" .. FormatCount((Memory.BoxCount(who.realm, who.name))) .. ")"
  end
  local fs = plate:GetFontString()
  plate.pad = 2 * M.tightGap + 12
  plate.caption, plate.nameText = name .. count, name
  plate.fullName = Memory.ClassName(who.realm, who.name)
  plate.Count:SetText(count)
  plate.natW = MeasureWith(panel, fs, plate.caption) + plate.pad
  plate.nameW = MeasureWith(panel, fs, name)
  plate.countW = (count ~= "") and MeasureWith(panel, fs, count) or 0
  -- The first letters, by character: a name can be accented or Cyrillic.
  local raw = tostring(who.name or "")
  local cut, letters = 0, 0
  for letter in raw:gmatch("[^\128-\191][\128-\191]*") do
    letters = letters + 1
    cut = cut + #letter
    if letters >= AV.PLATE_LETTERS then break end
  end
  -- A pixel over the measure, so the client's own cut leaves them standing.
  local least = MeasureWith(panel, fs, raw:sub(1, cut) .. "...") + 1
  plate.minNameW = min(plate.nameW, least)
  plate.minW = min(plate.natW, plate.pad + plate.minNameW + plate.countW)
end

-- The plate at the width the row can give it (`room`), capped. While its
-- whole caption fits it is drawn exactly as it always was; past that the
-- name gives way -- an ellipsis, down to its first letters -- and the count
-- stays whole beside it, the full name in the tooltip. Never narrower than
-- `minW`: a row that cannot give it that much has the window made wider
-- instead (LayoutViewToggle). Returns the width.
function AV.FitPlate(panel, room)
  local T = Th()
  local plate = panel.ViewToggle.alt
  local fs, pad = plate.Text, plate.pad
  local cap = min(AV.PLATE_MAX, room)
  local whole = plate.natW <= cap
  if whole ~= plate._whole then
    plate._whole = whole
    fs:ClearAllPoints()
    if whole then
      fs:SetPoint("CENTER", plate, "CENTER", 0, 0)
      fs:SetJustifyH("CENTER")
    else
      fs:SetPoint("LEFT", plate, "LEFT", pad / 2, 0)
      fs:SetJustifyH("LEFT")
    end
    plate.Count:SetShown(not whole)
  end
  local width
  if whole then
    width = plate.natW
    T.FitText(fs, width - pad, plate.caption, plate)
  else
    local nameW = min(plate.nameW, max(plate.minNameW, floor(cap - pad - plate.countW)))
    T.FitText(fs, nameW, plate.nameText, plate)
    width = pad + nameW + plate.countW
  end
  plate:SetWidth(width)
  return width
end

-- The picker's crest, the toggle's tint, the other box's name beside Inbox,
-- and where the hint stops -- everything the state above changes on screen.
function AV.Paint(panel)
  if not (panel and panel.Picker) then return end
  local T = Th()
  local M = T.Metrics
  local Memory = AV.Memory()
  local others = Memory and Memory.HasOthers() or false
  local who = panel._alt

  panel.Picker:SetShown(others or who ~= nil)
  if Memory then
    local crest = Memory.ClassIcon(who and who.realm or GetRealmName(), who and who.name or UnitName("player"))
    if crest then panel.Picker.Icon:SetAtlas(crest, false) end
  end
  T.SetPlateSelected(panel.Picker, who ~= nil)

  -- The every-character toggle shows while there is another box to search,
  -- and the box says what it searches.
  AV.PaintSearch(panel, others)

  -- The other box's name and count, just left of the picker that chose it:
  -- the two read as one control. No realm -- the list the name was picked
  -- from said which -- and never wider than the row can give it: a long name
  -- is cut, its count kept (AV.FitPlate, from the row's layout below).
  -- Measured from the full caption, so a cut never feeds the next width.
  local plate = panel.ViewToggle and panel.ViewToggle.alt
  if plate then
    if who and Memory then
      AV.MeasurePlate(panel, plate, Memory, who)
      plate:SetHeight(M.segmentHeight)
      plate:ClearAllPoints()
      plate:SetPoint("RIGHT", panel.Picker, "LEFT", -M.space.snug, 0)
      plate:Show()
    else
      plate:Hide()
    end
  end

  local hint = panel.Hint
  if hint then
    local edge = (plate and plate:IsShown() and plate)
      or (panel.Picker:IsShown() and panel.Picker) or panel.SearchWrap
    hint:SetPoint("RIGHT", edge, "LEFT", -M.gap, 0)
  end
  LayoutViewToggle(panel)
  if RV.ApplyFooter then RV.ApplyFooter(panel) end
end

-- who: { realm, name } of another character, or nil for this one.
function AV.Show(panel, who)
  -- A box picked from History, or History back from one: the search was
  -- asked of the other list (AV.ResetSearch). Refreshed below.
  local history = AV.History(panel)
  panel._alt = who
  if AV.History(panel) ~= history then AV.ResetSearch(panel) end
  ClearSelection(panel)
  if panel.Detail then panel.Detail:Hide() end
  if panel.MailListScroll then panel.MailListScroll:SetVerticalScroll(0) end
  AV.Paint(panel)
  CT.RefreshMailList(panel)
end

-- Back to this character's own box. Whether there was anywhere to come back
-- from.
function AV.Leave(panel)
  -- Only from somewhere: the toggle on with nothing typed changes nothing
  -- on screen, and a segment click leaves it be.
  if not (panel and (panel._alt or AV.Active(panel))) then return false end
  panel._searchAll = false
  AV.Show(panel, nil)
  return true
end

-- A right-click on the picker or on the other box's plate: back to this
-- character's own box, as picking its own name from the list is -- the list
-- closes, and the view on screen before the visit returns. From this
-- character's own box it does nothing. Whether there was anywhere to come
-- back from.
function AV.Back(panel)
  if not AV.Other(panel) then return false end
  local Memory = ns.MailMemory
  if Memory and Memory.ClosePicker then Memory.ClosePicker() end
  AV.Leave(panel)
  -- The tooltip under the pointer spoke of the box just left: the plate's
  -- goes with the plate, the picker's is said again without the way back.
  local plate, picker = panel.ViewToggle and panel.ViewToggle.alt, panel.Picker
  if plate and GameTooltip:IsOwned(plate) then GameTooltip:Hide() end
  if picker and GameTooltip:IsOwned(picker) then
    if picker:IsShown() then AV.PickerTip(picker, panel) else GameTooltip:Hide() end
  end
  return true
end

-- The picker's tooltip; the way back only while there is one to take.
function AV.PickerTip(picker, panel)
  GameTooltip:SetOwner(picker, "ANCHOR_TOPRIGHT")
  GameTooltip:SetText(L()["PICKER_TITLE"])
  GameTooltip:AddLine(L()["PICKER_TIP"], 1, 1, 1, true)
  if AV.Other(panel) then GameTooltip:AddLine(L()["PICKER_BACK_HINT"], 0.7, 0.7, 0.7, true) end
  GameTooltip:Show()
end

-- A character's heading among every box's matches, clicked: that box.
function AV.OpenHeader(panel, realm, name)
  panel._searchAll = false
  if panel.SearchBox then panel.SearchBox:SetText("") end
  local mine = (realm == GetRealmName() and name == UnitName("player"))
  AV.Show(panel, (not mine) and { realm = realm, name = name } or nil)
end

-- Frozen: Core/MailboxUI.lua calls this when Mail Memory is switched on or
-- off. Off, there is no other box to show, so this character's comes back;
-- `home` brings it back regardless (Reset everything: the others are gone).
function CT.RefreshOthers(panel, home)
  if not panel then return end
  if home or not AV.Memory() then
    panel._alt, panel._searchAll = nil, false
  end
  AV.Paint(panel)
  RequestRefresh(panel)
end

-- Frozen: Core/MailboxUI.lua calls this when Show mail counts changes: the
-- counts the segments and the buttons do not carry -- the read mail's
-- divider, where it stands, and another character's plate -- painted again.
function CT.RepaintBoxCounts(panel)
  if not panel then return end
  local divider, pin = panel.Divider, panel.DividerPin
  if divider and divider:IsShown() then RV.PaintDivider(panel, divider) end
  if pin and pin:IsShown() then RV.PaintDivider(panel, pin) end
  if AV.Other(panel) then AV.Paint(panel) end
end

-- Frozen: Core/MailboxUI.lua calls this for every way into Mail Memory while
-- a mailbox is open -- the character list, under its button.
function CT.OpenPicker(panel)
  local Memory = AV.Memory()
  if not (panel and panel.Picker and Memory) then return end
  -- Timed on the visit's record (Postbox.lua, 5b): the list's frame is built
  -- on the first.
  local perf = ns.Perf
  local perfAt = perf and perf.visit and perf.Mark()
  if not panel.Picker:IsShown() then AV.Paint(panel) end
  if not panel.Picker:IsShown() then
    -- No other character has a box to show: say so, not a dead click -- and,
    -- when it is only because the player hid them, where they come back.
    local _, hidden = Memory.HasOthers()
    ns.Print(L()[(tonumber(hidden) or 0) > 0 and "MEMORY_NO_OTHERS_HIDDEN" or "MEMORY_NO_OTHERS"])
    return
  end
  Memory.OpenPicker(panel.Picker, panel._alt, function(realm, name, isMe)
    AV.Show(panel, (not isMe) and { realm = realm, name = name } or nil)
  end)
  if perfAt then perf.Done("picker", perfAt) end
end

-- The pool of memory rows, built by Mail Memory (one row construction for
-- both windows) and placed here at the list's own pitch.
function AV.Row(panel, slot)
  local pool = panel._avPool
  local row = pool[slot]
  if row then return row end
  row = ns.MailMemory.NewRow(panel.MailListChild)
  row:SetHeight(COMPACT_ROW_HEIGHT)
  pool[slot] = row
  return row
end

function AV.HideRows(panel)
  local pool = panel._avPool or {}
  for i = 1, #pool do pool[i]:Hide() end
end

-- The rows, their columns, the note under them and the totals they carry.
-- Returns earned, spent and how many rows are listed.
function AV.Build(panel, query)
  local Memory = AV.Memory()
  local who = panel._alt
  local rows, info = Memory.RowsFor(who and who.realm, who and who.name,
    { query = query, all = panel._searchAll })
  -- The arrange mode's Preview mail: the samples, as remembered mail.
  if panel._preview and Memory.PreviewRows then rows = Memory.PreviewRows() end
  panel._avRows, panel._avInfo = rows, info
  -- The moment the columns are measured at is the one the rows are drawn
  -- at (AV.UpdateRows), so an age measured as "9m" is not drawn as "10m".
  local now = time()
  panel._avNow = now
  panel._avCols = (#rows > 0) and Memory.MeasureRows(panel, rows, now, AV.Row(panel, 1)) or {}

  local earned, spent = 0, 0
  for i = 1, #rows do
    local mail = rows[i]
    if not mail.header and not mail.pending then
      earned = earned + (tonumber(mail.money) or 0)
      spent = spent + (tonumber(mail.paid) or 0) + (tonumber(mail.cod) or 0)
    end
  end

  -- The note where the sweeps stand: whose box and when it was seen, and
  -- where to go to collect it; or what a search of every box found.
  local note
  if info.matched and panel._searchAll and query ~= "" then
    note = ns.Plural("MEMORY_MATCHES", info.matched)
    if (info.onCharacters or 0) > 1 then
      note = note .. "  " .. ns.Plural("MEMORY_ON_CHARACTERS", info.onCharacters)
    end
  elseif who and info.snapshot then
    note = L()("ALT_NOTE", Memory.AgeText(info.snapshot), Memory.ClassName(who.realm, who.name, true))
  else
    note = Memory.SeenText(info.snapshot)
  end
  panel.AltNote:SetText(note)
  return earned, spent, #rows
end

function AV.UpdateRows(panel)
  local stride = COMPACT_ROW_HEIGHT + ROW_GAP
  panel._rowStride = stride
  local rows = panel._avRows or {}
  local scroll = panel.MailListScroll
  local viewport = scroll:GetHeight() or 0
  local offset = scroll:GetVerticalScroll() or 0
  local first = max(1, floor(offset / stride) + 1)
  local last = first - 1
  if viewport > 0 then last = min(#rows, ceil((offset + viewport) / stride)) end
  local now = panel._avNow or time()
  local used = 0
  -- A heading's click, made once per panel.
  local onHeader = panel._avOnHeader
  if not onHeader then
    onHeader = function(realm, name) AV.OpenHeader(panel, realm, name) end
    panel._avOnHeader = onHeader
  end
  -- The box each row is from, for its sender's class and for where its
  -- items can be taken (MM.RowRealm).
  local Memory = ns.MailMemory
  local realm, name
  if Memory.RowRealm then realm, name = Memory.RowRealm(rows, first, panel._avInfo) end
  for i = first, last do
    used = used + 1
    local row = AV.Row(panel, used)
    local y = -((i - 1) * stride)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", panel.MailListChild, "TOPLEFT", 0, y)
    row:SetPoint("TOPRIGHT", panel.MailListChild, "TOPRIGHT", 0, y)
    if rows[i].header then realm, name = rows[i].realm, rows[i].name end
    Memory.FillRow(row, rows[i], now, panel._avCols, i, onHeader, realm, name)
  end
  local pool = panel._avPool
  for i = used + 1, #pool do pool[i]:Hide() end
end

-------------------------------------------------------------
-- Mail rows :: the pool
--
-- WoW cannot free a frame. The previous build hid every row and re-parented it
-- to nil on each refresh, then built fresh frames -- so a fifty-mail run, which
-- refreshes once per mail, leaked on the order of 2500 frames for the session.
--
-- Rows are therefore acquired by viewport slot and released by hiding. Every
-- script is installed once, at creation, and reads the mail it is bound to from
-- a field re-written on each bind: a closure per row per refresh is the second
-- leak, and the one that is easy to reintroduce.
-------------------------------------------------------------

local ShowDetail, CollectSingleMail, DeleteOneMail  -- forward declarations

-- ONE reading of a click on a mail row, and the only one. The row, the icon
-- hover area laid on top of it and the row's own tooltip hint all come through
-- here, so what a gesture does and what the tooltip says it does cannot drift
-- apart -- which they would the moment either was decided twice.
--
-- Two mappings, chosen by the `previewOnClick` option, and both are the same
-- pair of verbs the other way round:
--
--                     option OFF (default)      option ON
--   left              collect                   open the mail
--   right             open the mail             collect
--
-- Shift-click used to be a second spelling of right-click. It is a selection
-- gesture now (see "Selection"), which is why it appears in neither column.
--
-- A FINISHED mail has nothing to collect, so every button opens it under either
-- mapping. That is a property of the MAIL and not of the view it is being listed
-- in: the same mail behaves identically under "Done" and under "All", which is
-- what stops a gesture meaning two things depending on which segment is lit.
--
-- Why an alternate gesture exists at all: when the server refuses a take ("You
-- can't carry any more of those items") the mail stays in the to-collect list,
-- and without this the only way to see what is in it, or read what it says,
-- would be to collect it -- which is the thing that will not work.
--
-- Returns true to preview, false to collect.
local function PreviewGesture(row, button)
  if row.mailDone then return true end
  local alternate = (button == "RightButton")
  if PreviewOnClick() then return not alternate end
  return alternate
end

local function ActivateRow(row, button)
  local panel = row.panel
  local index = LiveIndex(row)
  if not (panel and index) then return end
  -- While the columns are being arranged a press on a row takes the column
  -- under it (Core/Arrange.lua lays a cover of its own over the list), and
  -- nothing that reaches a row may collect or open a mail.
  if RV.Arranging(panel) then return end

  -- A modified left-click is a selection gesture, under either mapping and
  -- on either button's verb: shift extends a range from the last row picked,
  -- ctrl picks or unpicks the one row. See "Selection" above.
  if button == "LeftButton" and not row.mailDone then
    if IsShiftKeyDown() then SelectRange(panel, row) return end
    if IsControlKeyDown() then SelectToggle(panel, row) return end
  end

  if not PreviewGesture(row, button) then
    CollectSingleMail(panel, index)
    return
  end

  -- A run owns every inbox index for its whole duration, and the overlay is
  -- addressed by index -- CloseDetailIfStale hides it outright while one is
  -- active, so an overlay opened mid-run would appear and vanish. This is the
  -- same "one sequence at a time" the collect path gets for free from
  -- MailService's channel ownership; the preview path issues no command, so it
  -- has to state it.
  if CT.IsRunning() then return end
  ShowDetail(panel, index)
end

-------------------------------------------------------------
-- Mail rows :: the two layouts
--
--   STANDARD  two lines beside a 28px icon: sender and subject on the first,
--             the meta line -- gold, C.O.D., slots left, category, expiry,
--             invoice breakdown -- on the second.
--   COMPACT   one line beside an 18px icon: sender, then subject, with the
--             essentials of the meta line right-aligned at the trailing edge.
--             The category and the invoice breakdown are not drawn at all; the
--             row's hover tooltip carries the WHOLE meta line instead, so
--             nothing a standard row says stops being reachable.
--
-- A row is pooled and recycled between the two, so this re-sizes only when the
-- mode a row is wearing is not the mode it is being bound into -- which for the
-- overwhelmingly common case (the option never changes mid-session) is once, at
-- build. WHERE each column stands is the arrangement's, and RV.Place decides it
-- on every bind for both layouts; everything that depends on the MAIL -- which
-- trailing controls are showing, how wide each string may be -- stays in
-- BindRow.
--
-- `row._compact` starts nil, so a freshly built row is always sized by the
-- first call: BuildRow deliberately leaves every mode-dependent size unset
-- rather than duplicating one of the two branches below.
-------------------------------------------------------------

local function ApplyRowMode(row, compact, height)
  if row._compact == compact then return end
  row._compact = compact

  local iconSize = compact and ROW_ICON_COMPACT or ROW_ICON
  local deleteSize = compact and ROW_DELETE_COMPACT or ROW_DELETE

  row:SetHeight(height)

  -- The hit area is SetAllPoints(row.Icon), so it follows the icon wherever
  -- the arrangement puts it; the stripe is SetAllPoints(row), so it follows
  -- the height.
  row.Icon:SetSize(iconSize, iconSize)

  -- The BUTTON is the hit area and keeps the full size; only its glyph is inset.
  row.Delete:SetSize(deleteSize, deleteSize)
  if row._deleteTexture then
    local glyphSize = max(deleteSize - 2 * DELETE_GLYPH_INSET, 1)
    row.Delete.Glyph:SetSize(glyphSize, glyphSize)
  end
end

local function BuildRow(panel)
  local T = Th()
  local row = CreateFrame("Button", nil, panel.MailListChild)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row.panel = panel

  -- The read/unread mark: a flat dot in the theme's two colours. A dot, not
  -- a square, and one pixel smaller than the space it is given -- the row
  -- has two marks at its left edge now (the selection bar sits on the edge
  -- itself) and a square beside a bar read as one shape. Where it stands is
  -- the arrangement's (RV.Place, RV.DotX): first, it is centred between the
  -- row's edge and the icon's column, clear of the bar. A soft shadow under
  -- it holds it over a bright scene.
  row.Indicator = row:CreateTexture(nil, "ARTWORK")
  row.Indicator:SetSize(ROW_INDICATOR - 1, ROW_INDICATOR - 1)
  row.Indicator:SetTexture(WHITE)
  if type(row.CreateMaskTexture) == "function" then
    local mask = row:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
                    "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(row.Indicator)
    row.Indicator:AddMaskTexture(mask)
  end
  RV.ShadeDot(row)

  -- Sized by ApplyRowMode, which the virtualiser calls before it binds
  -- anything to this row, and placed by the bind. Same for the texts below
  -- it; the delete control is sized there too.
  row.Icon = row:CreateTexture(nil, "ARTWORK")
  row.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  -- The row's icon IS the first attachment whenever the mail has one -- that is
  -- what Mail().GetMailIcon resolves to -- so hovering it should say which item,
  -- at its real quality, with its real count. A texture cannot take mouse input,
  -- so the hover area is a button laid exactly over it; and because the whole
  -- row surface is clickable, that button has to forward its clicks or the icon
  -- would be a dead hole in the middle of the row.
  row.IconHit = CreateFrame("Button", nil, row)
  row.IconHit:SetAllPoints(row.Icon)
  row.IconHit:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row.IconHit:SetScript("OnClick", function(self, button)
    ActivateRow(self:GetParent(), button)
  end)
  row.IconHit:SetScript("OnEnter", function(self)
    local owner = self:GetParent()
    -- Moving onto a child that takes the mouse fires the ROW's OnLeave, so the
    -- hover paint is re-asserted here; without it the row visibly unhighlights
    -- while the cursor is still on it.
    Th().StyleMailRow(owner, owner._rowIndex, true)
    local index = LiveIndex(owner)
    if not (index and owner.iconSlot) then return end
    -- A mail with several items lists them all; one item, its own tooltip.
    -- Where the player chose the fan and it may open here, it opens after a
    -- rest instead, and nothing shows before it (RV.FanHover).
    if (owner.iconItems or 0) > 1 then
      if RV.FanHover(owner) then return end
      RV.ItemsTooltip(self, index, owner.iconItems)
      return
    end
    ShowAttachmentTooltip(self, index, owner.iconSlot)
  end)
  row.IconHit:SetScript("OnLeave", function(self)
    local owner = self:GetParent()
    Th().StyleMailRow(owner, owner._rowIndex, false)
    GameTooltip:Hide()
    RV.FanLeave(owner)
  end)

  row.Sender = T.CreateText(row, "label")
  row.Sender:SetJustifyH("LEFT")

  row.Subject = T.CreateText(row, "value")
  row.Subject:SetJustifyH("LEFT")

  -- Secondary, never the disabled font object: this line carries the gold, the
  -- C.O.D., the remaining slots, the category and the expiry. It is the densest
  -- line on the screen and it is not inactive.
  row.Detail = T.CreateText(row, "secondary")
  row.Detail:SetJustifyH("LEFT")
  row.Detail:Hide()

  -- The compact row's three figure columns (see "the columns"). Anchored on
  -- bind, because where each stands depends on the list, not on the row.
  row.ColTime = T.CreateText(row, "secondary")
  row.ColMoney = T.CreateText(row, "secondary")
  row.ColSlots = T.CreateText(row, "secondary")
  row.ColTime:SetJustifyH("RIGHT")
  row.ColMoney:SetJustifyH("RIGHT")
  row.ColSlots:SetJustifyH("RIGHT")
  row.ColTime:Hide()
  row.ColMoney:Hide()
  row.ColSlots:Hide()

  -- Shown on a DONE mail, wherever that mail is being listed. Built once and
  -- shown per bind, because a row is recycled between the views. Its anchor is
  -- the same in both layouts; only its size steps down with the row.
  --
  -- A MARK, NOT A PLATE. It sits inside a list of mails, most of which do not
  -- carry it, so it may not have a filled surface of its own in either state:
  -- an opaque square is heavier than the row it annotates and reads as the
  -- loudest thing on the screen. Idle is the same neutral the row's own
  -- secondary text is; hover swaps the tint to `negative`, which is the tone
  -- this addon uses for everything that costs the player something. Nothing is
  -- drawn behind it in either state.
  row.Delete = CreateFrame("Button", nil, row)
  row.Delete:SetPoint("RIGHT", row, "RIGHT", -T.Metrics.tightGap, 0)

  local deleteAtlasName = ProbeAtlas(DELETE_ATLASES)
  if deleteAtlasName then
    row.Delete.Glyph = row.Delete:CreateTexture(nil, "ARTWORK")
    row.Delete.Glyph:SetAtlas(deleteAtlasName, false)
    row.Delete.Glyph:SetPoint("CENTER")
    -- Which of the two representations this row got: ApplyRowMode sizes a
    -- texture and must not constrain the font string, which would clip it.
    row._deleteTexture = true
  else
    row.Delete.Glyph = T.CreateText(row.Delete, "value")
    row.Delete.Glyph:SetPoint("CENTER")
    row.Delete.Glyph:SetText(DELETE_GLYPH)
  end
  -- Theme.SetColor tints a texture and colours a font string, so neither this
  -- nor the hover handlers below has to know which of the two it got.
  T.SetColor(row.Delete.Glyph, "textSecondary")

  row.Delete:SetScript("OnEnter", function(self)
    -- Same reason as the icon hover area: this is a child that takes the mouse,
    -- so the row's own OnLeave has just fired and the hover paint needs
    -- re-asserting or the row dims under the cursor.
    local owner = self:GetParent()
    local T2 = Th()
    T2.StyleMailRow(owner, owner._rowIndex, true)
    T2.SetColor(self.Glyph, "negative")
    -- The same shape every other tooltip in this file uses: own the tooltip,
    -- clear it, title, then a wrapped line under it. SetText alone gave a
    -- one-word tooltip that said no more than the glyph already does.
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:SetText(DeleteLabel())
    local hint = RawKey("HINT_ROW_DELETE")
    if hint then GameTooltip:AddLine(hint, 1, 1, 1, true) end
    GameTooltip:Show()
  end)
  row.Delete:SetScript("OnLeave", function(self)
    local owner = self:GetParent()
    local T2 = Th()
    T2.StyleMailRow(owner, owner._rowIndex, false)
    T2.SetColor(self.Glyph, "textSecondary")
    GameTooltip:Hide()
  end)
  row.Delete:SetScript("OnClick", function(self)
    local parent = self:GetParent()
    -- Nor delete one, while the columns are being arranged.
    if RV.Arranging(parent.panel) then return end
    -- Verified, not assumed: deleting is irreversible, so it may only ever act
    -- on an index that still names the mail this row is showing -- now, and
    -- again right before the command goes (DeleteOneMail).
    DeleteOneMail(parent.panel, LiveIndex(parent), parent.fingerprint)
  end)

  -- The stuck marker: this mail's attachments were refused by the server
  -- earlier in this visit. Never shown for a mail that merely HAS attachments --
  -- most of the list has those -- so it carries information every time it
  -- appears, and there is nothing to switch off when nothing is wrong.
  --
  -- A texture, not a button. The reason is read from the row's own hover
  -- tooltip, which is already on screen when the cursor is anywhere on the row,
  -- so the marker takes no mouse input and cannot become a dead spot in the
  -- middle of a clickable row the way an inert child frame would.
  --
  -- It stands in the read mark's place, centred on the dot wherever the
  -- arrangement puts it, and RV.Place shows it there (RV.PaintDot): a mail
  -- whose read mark is hidden shows no mark in the row, and its tooltip and
  -- the title bar's "Stuck: N" still say it.
  local warningAtlasName = ProbeAtlas(Th().AtlasSets.warning)
  if warningAtlasName then
    row.Warning = row:CreateTexture(nil, "OVERLAY")
    row.Warning:SetAtlas(warningAtlasName, false)
    -- Only the texture form has a size to give: the fallback is a font
    -- string carrying a single character, and constraining that would clip
    -- it.
    row.Warning:SetSize(ROW_WARNING, ROW_WARNING)
  else
    row.Warning = T.CreateText(row, "value")
    row.Warning:SetText(WARNING_GLYPH)
  end
  row.Warning:SetPoint("CENTER", row.Indicator, "CENTER", 0, 0)
  -- One tone for both representations, from the palette. Theme.SetColor tints a
  -- texture and colours a font string, so the caller does not have to know which
  -- of the two it got.
  T.SetColor(row.Warning, "warning")
  row.Warning:Hide()

  row:SetScript("OnClick", function(self, button) ActivateRow(self, button) end)

  row:SetScript("OnEnter", function(self)
    local T2 = Th()
    T2.StyleMailRow(self, self._rowIndex, true)

    -- A compact row draws a subset of the meta line, so it hands the WHOLE of
    -- it to the tooltip -- category and invoice breakdown included -- and the
    -- Detail string's own overflow is not asked about, because the full line
    -- already contains it. `detailFull` is nil on a standard row, where the
    -- line is on screen in full or was cut and is the overflow line's business.
    local full = self.detailFull
    local cut = self.Sender.__pbOverflowText or self.Subject.__pbOverflowText
      or (not full and self.Detail.__pbOverflowText)

    -- The gesture line is the one reason this tooltip is no longer conditional
    -- on something having been cut: shift-click and right-click cannot be
    -- discovered by looking. Which line it is follows the ACTIVE mapping -- the
    -- alternate gesture teaches whichever verb the plain click is not, and the
    -- selection gestures follow it in the same line -- because a hint that
    -- describes the other setting is worse than no hint at all. A finished
    -- mail still gets nothing: there every button opens the mail and nothing
    -- can be picked, so there is no alternative to teach -- and that is read
    -- from the MAIL, so it holds on the all view too.
    local teach = nil
    if not self.mailDone then
      teach = PreviewOnClick() and RawKey("HINT_ROW_COLLECT") or RawKey("HINT_ROW_PREVIEW")
    end
    local stuck = self.stuckReason
    local expiry = self.expiryTip
    local facts = self.factsTip
    local whole = self.senderTip
    local unread = self.unreadTip
    if not cut and not full and not teach and not stuck and not expiry and not facts and not whole
      and not unread then return end

    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    -- The sender's whole name, realm and all, when the row shortened it; it
    -- supersedes the overflow line, which would only repeat the short form.
    if whole then
      GameTooltip:AddLine(whole, 1, 1, 1, true)
    else
      T2.AddOverflowLine(self.Sender, GameTooltip)
    end
    T2.AddOverflowLine(self.Subject, GameTooltip)
    if full then
      -- One line per fact: the first is what the mail is, the rest are the
      -- invoice's figures, in the quieter tone.
      local first = true
      for line in full:gmatch("[^\n]+") do
        if first then
          GameTooltip:AddLine(line, 1, 1, 1, true)
        else
          GameTooltip:AddLine(line, 0.75, 0.75, 0.75, true)
        end
        first = false
      end
    else
      T2.AddOverflowLine(self.Detail, GameTooltip)
    end
    -- The figures an option took off the row, so switching one off never
    -- makes it unreachable -- and the read mark's word, when its column is
    -- hidden.
    if facts then
      for line in facts:gmatch("[^\n]+") do GameTooltip:AddLine(line, 1, 1, 1, true) end
    end
    if unread then GameTooltip:AddLine(unread, 0.75, 0.75, 0.75, true) end
    -- How long the mail has left, always here and on the row only when short.
    if expiry then GameTooltip:AddLine(expiry, 0.75, 0.75, 0.75, true) end
    -- Air between what the mail is and what a click does with it.
    if teach or stuck then GameTooltip:AddLine(" ") end
    -- After the mail's own text, which identifies WHICH mail this is, and before
    -- the generic gesture hint: this line is about this mail and it is the
    -- reason the marker is there.
    if stuck then
      GameTooltip:AddLine(T2.Colorize("warning", StuckLine(stuck)), 1, 1, 1, true)
    end
    if teach then GameTooltip:AddLine(teach, 0.7, 0.7, 0.7, true) end
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function(self)
    Th().StyleMailRow(self, self._rowIndex, false)
    GameTooltip:Hide()
  end)

  -- A row is never handed back without a height and without its icon anchored:
  -- the hit area is SetAllPoints(row.Icon) and would have nothing to follow. The
  -- virtualiser applies the mode again before every bind, which is a no-op
  -- unless the option changed in between.
  local compact, height = RowMetrics()
  ApplyRowMode(row, compact, height)

  return row
end

local function AcquireRow(panel, slot)
  local row = panel._rows[slot]
  if row then return row end
  row = BuildRow(panel)
  panel._rows[slot] = row
  return row
end

-------------------------------------------------------------
-- Mail rows :: where a row's facts come from
--
-- A row asks the same few things of every mail it is bound to -- its header,
-- its kind, why it is stuck, its icon, its attachments, its crafting quality
-- mark, its money and its invoice's figures -- through a source: RV.LIVE,
-- the inbox, and RV.SAMPLE, the sample mail the arrange mode's Preview mail
-- lists in its place (below). Each of RV.LIVE's answers is the call the
-- binder has always made, made at call time, so whatever another addon has
-- hooked onto the client's functions is still what is asked.
-------------------------------------------------------------

RV.LIVE = {}
-- An empty list, for a walk that has nothing to walk.
RV.NONE = {}

function RV.LIVE.Header(index) return GetInboxHeaderInfo(index) end
function RV.LIVE.Classify(index) return Mail().ClassifyMail(index) end
function RV.LIVE.Stuck(index) return Mail().StuckReason(index) end
function RV.LIVE.Icon(index) return Mail().GetMailIcon(index) end
function RV.LIVE.Mark(index, slot) return RV.QualityMark(index, slot) end
RV.LIVE.Money = RowMoneyText
RV.LIVE.Invoice = AppendInvoiceFigures

-- One scan of the attachment slots, not two, and none at all for a mail whose
-- header says it has no attachments. This runs for every visible row on every
-- refresh, and a run refreshes once per mail. Answers the attachments left,
-- their total count, which slot the row's icon came from (so hovering it
-- can raise that item's own tooltip; Mail().GetMailIcon returns the first
-- slot bearing a texture, so this has to find the same one -- and after a
-- partial take that is not necessarily slot 1), that item's count and how
-- many items the mail holds (RV.PaintCount).
function RV.LIVE.Attachments(index, itemCount)
  local remaining, quantity = 0, 0
  local iconSlot = nil
  local iconCount, stacks = 0, 0
  if (tonumber(itemCount) or 0) > 0 then
    for slot = 1, Mail().MAX_ATTACHMENTS do
      if GetInboxItemLink(index, slot) then remaining = remaining + 1 end
      local _, _, texture, count = GetInboxItem(index, slot)
      if texture then
        stacks = stacks + 1
        if not iconSlot then iconSlot, iconCount = slot, tonumber(count) or 0 end
      end
      quantity = quantity + (tonumber(count) or 0)
    end
  end
  return remaining, quantity, iconSlot, iconCount, stacks
end

-------------------------------------------------------------
-- Mail rows :: Preview mail
--
-- The arrange mode's Preview mail (Core/Arrange.lua, its overview) lists a
-- set of sample mails in place of the list on screen, so that every column,
-- and every state a row can be in, has something to show while it is being
-- arranged: gold earned and spent, a C.O.D., a short time left and a long
-- one, one slot and many, each auction outcome, a letter with nothing
-- attached, a long item name, items with a crafting quality, read mail and
-- unread, a read mail with nothing left in it (its delete mark), and a mail
-- from one of the player's own characters (in the class colour). A mail
-- without gold or slots sits among mails with both, so Row layout's Columns
-- and Packed visibly differ.
--
-- The rows are this file's own, bound by BindRow through RV.SAMPLE, so a
-- sample is drawn exactly as a real mail is. Nothing is asked of the
-- mailbox for one: a sample row names no inbox index, so nothing can
-- collect, open, delete or select it (and the arrange mode's cover takes
-- every click over the list besides). The counts on the view switch and on
-- the category buttons stay the inbox's, as they do under a search; the
-- totals band totals what is listed, which is the samples.
--
-- The set is made each time the preview is switched on -- its amounts, its
-- times and its items chosen afresh from a seed, and the same for as long as
-- it stays on -- from items the client already has: the item cache, then
-- the bags. The server is never asked for one. Mail Memory draws the same
-- set as its own rows (MailMemory.lua, MM.PreviewRows), and History as the
-- entries collecting it would have made (RV.PreviewHistory).
-------------------------------------------------------------

do
  -- Sample items, by what each is for, as item IDs; the first the client
  -- has cached is used, the bags stand in where none is. Tiered reagents
  -- and crafted goods carry a crafting quality mark; the long names show a
  -- subject cut short.
  local ITEMS = {
    quality = { 241326, 241289, 241308, 238202, 241288, 241309, 271887, 270898 },
    long = { 243991, 273072, 44742, 35183, 35184, 40772 },
    stack = { 6260, 3371, 30817, 2589, 238202 },
    any = { 6948, 6256, 40772, 6260, 3371 },
  }
  -- What a letter and an auction's gold arrive under, as the client's own
  -- stationery draws them.
  local LETTER_ICON, COIN_ICON = 134327, 134939
  -- The other senders' names.
  local NAMES = { "Aldric", "Brynna", "Corwen", "Elowen", "Garrick", "Isolde", "Kaelan", "Maelis", "Oswin", "Tamsin" }
  local GOLD = 10000

  local pv = { mails = nil, history = nil, historyGen = nil, seed = 1, gen = 0 }
  RV.pv = pv

  -- The seed's next step (Park-Miller: exact in a double), 1..n.
  local function Rand(n)
    pv.seed = (pv.seed * 16807) % 2147483647
    return (pv.seed % n) + 1
  end

  -- About `base` gold, a third either way, to the silver.
  local function Gold(base)
    return floor(base * (0.67 + (Rand(67) - 1) / 100) * 100) * (GOLD / 100)
  end

  -- A time left in days, from `lo` up to `hi`.
  local function Days(lo, hi)
    return lo + (hi - lo) * (Rand(100) - 1) / 100
  end

  -- The name an item's link carries, without the quality mark inside it.
  local function Plain(name)
    return (name:gsub("%s*|A:.-|a", ""))
  end

  -- An item the client has cached, or nil. Asked only once the client says
  -- it has it, so the question never becomes a request to the server.
  local function Cached(id)
    if not (C_Item and type(C_Item.GetItemInfo) == "function") then return nil end
    if type(C_Item.IsItemDataCachedByID) == "function" and not C_Item.IsItemDataCachedByID(id) then return nil end
    local name, link, _, _, _, _, _, _, _, icon = C_Item.GetItemInfo(id)
    if type(name) ~= "string" or name == "" then return nil end
    if not icon and type(C_Item.GetItemInfoInstant) == "function" then
      icon = select(5, C_Item.GetItemInfoInstant(id))
    end
    return { id = id, name = Plain(name), link = link, icon = icon }
  end

  -- The bags' items: the client always knows those. Read once per set, and
  -- only when the lists above came up short.
  local function Bags()
    local out = pv.bags
    if out then return out end
    out = {}
    pv.bags = out
    if not (C_Container and type(C_Container.GetContainerNumSlots) == "function"
        and type(C_Container.GetContainerItemInfo) == "function") then return out end
    for bag = 0, 4 do
      for slot = 1, tonumber((C_Container.GetContainerNumSlots(bag))) or 0 do
        local info = C_Container.GetContainerItemInfo(bag, slot)
        local link = type(info) == "table" and info.hyperlink or nil
        local name = type(link) == "string" and link:match("|h%[(.-)%]|h") or nil
        if name and name ~= "" then
          out[#out + 1] = { id = info.itemID, name = Plain(name), link = link, icon = info.iconFileID }
        end
      end
    end
    return out
  end

  -- An item for `role`, not used yet in this set: for a long name the
  -- longest the client has, for any other the first from a place the seed
  -- picks.
  local function Item(role, used)
    local ids = ITEMS[role]
    local start = Rand(#ids)
    local longest
    for k = 0, #ids - 1 do
      local id = ids[((start + k - 1) % #ids) + 1]
      if not used[id] then
        local item = Cached(id)
        if item and role ~= "long" then
          used[id] = true
          return item
        end
        if item and (not longest or #item.name > #longest.name) then longest = item end
      end
    end
    if longest then
      used[longest.id] = true
      return longest
    end
    -- From the bags: for a quality, one that wears a mark; for a long
    -- name, the longest; else the first not used yet.
    local best
    local bags = Bags()
    for i = 1, #bags do
      local item = bags[i]
      local key = item.id or item.name
      if not used[key] then
        if role == "quality" then
          if RV.MarkOf(item.link) then best = item break end
        elseif role == "long" then
          if not best or #item.name > #best.name then best = item end
        elseif not best then
          best = item
        end
      end
    end
    if not best and role == "quality" then return Item("any", used) end
    if best then used[best.id or best.name] = true end
    return best
  end

  -- One of the player's own characters, named as a mail from them names
  -- them -- alone on this realm, Name-Realm on another -- and preferably one
  -- whose class Postbox knows, so it wears the class colour. Nil when the
  -- player has no other character.
  local function Alt()
    local Store = ns.Store
    local alts = Store and Store.Get and Store.Get("alts")
    if type(alts) ~= "table" then return nil end
    local classes = Store.Get("altClasses")
    local myRealm, me = GetRealmName(), UnitName("player")
    local function Known(realm, name)
      local byRealm = type(classes) == "table" and classes[realm] or nil
      return type(byRealm) == "table" and byRealm[name] ~= nil
    end
    local mine = alts[myRealm]
    if type(mine) == "table" and #mine > 0 then
      local start = Rand(#mine)
      for pass = 1, 2 do
        for k = 0, #mine - 1 do
          local name = mine[((start + k - 1) % #mine) + 1]
          if name ~= me and (pass == 2 or Known(myRealm, name)) then return name end
        end
      end
    end
    for realm, names in pairs(alts) do
      if realm ~= myRealm and type(names) == "table" then
        for i = 1, #names do
          if Known(realm, names[i]) then return names[i] .. "-" .. (realm:gsub("[%s%-]", "")) end
        end
      end
    end
    return nil
  end

  -- An auction mail's subject, in the client's own words for it.
  local function AuctionSubject(template, item, count)
    local name = item.name
    if count and count > 1 then name = name .. " (" .. count .. ")" end
    return type(template) == "string" and format(template, name) or name
  end

  -- A mail of the set: what BindRow, Mail Memory and History read of it.
  local function Add(out, m)
    m.money, m.cod = m.money or 0, m.cod or 0
    m.items = m.items or {}
    local quantity = 0
    for i = 1, #m.items do quantity = quantity + (m.items[i].count or 1) end
    m.quantity = quantity
    local first = m.items[1]
    m.icon = m.icon or (first and first.icon) or LETTER_ICON
    m.mark = first and RV.MarkOf(first.link) or nil
    -- How long ago it arrived, for the inbox's order: a C.O.D. lives three
    -- days, every other mail thirty.
    m.age = ((m.cod > 0) and 3 or 30) - m.days
    out[#out + 1] = m
  end

  local function Slot(item, count)
    return { id = item.id, name = item.name, link = item.link, icon = item.icon, count = count }
  end

  local function Newest(a, b) return a.age < b.age end

  -- The set, made afresh: a new seed, the same set until the next.
  function RV.PreviewBuild()
    pv.seed = ((time and time() or 1) % 2147483646) + 1
    pv.gen = pv.gen + 1
    pv.bags = nil
    local L0 = L()
    local ah = L0["MEMORY_FROM_AH"]
    local used = {}
    local out = {}
    local first = Rand(#NAMES)
    local function Name(k) return NAMES[((first + k - 1) % #NAMES) + 1] end
    local alt = Alt() or Name(3)

    -- Sold, unread: the gold alone, and its invoice not fetched yet.
    local item = Item("stack", used) or Item("any", used)
    if item then
      Add(out, { kind = "sold", sender = ah, subject = AuctionSubject(AUCTION_SOLD_MAIL_SUBJECT, item, Rand(3)),
        money = Gold(1284), days = Days(29.3, 29.95), read = false, icon = COIN_ICON })
    end
    -- Sold, read: its invoice's deposit and the auction house's cut.
    item = Item("any", used)
    if item then
      local bid = Gold(92)
      local cut = floor(bid * 0.05 / 100) * 100
      local deposit = Gold(3)
      Add(out, { kind = "sold", sender = ah, subject = AuctionSubject(AUCTION_SOLD_MAIL_SUBJECT, item),
        money = bid - cut + deposit, days = Days(26.5, 27.5), read = true, icon = COIN_ICON,
        invoice = { type = "seller", bid = bid, deposit = deposit, consignment = cut } })
    end
    -- Won, read: what it cost, from its invoice, and a quality mark.
    item = Item("quality", used)
    if item then
      local price = Gold(3420)
      Add(out, { kind = "bought", sender = ah, subject = AuctionSubject(AUCTION_WON_MAIL_SUBJECT, item),
        days = Days(29.0, 29.6), read = true, price = price, items = { Slot(item, 1) },
        invoice = { type = "buyer", bid = price } })
    end
    -- Won, unread: no price until its invoice is fetched, as in the inbox.
    item = Item("quality", used)
    if item then
      local n = 5 * Rand(4)
      Add(out, { kind = "bought", sender = ah, subject = AuctionSubject(AUCTION_WON_MAIL_SUBJECT, item, n),
        days = Days(27.8, 28.6), read = false, items = { Slot(item, n) } })
    end
    -- Expired: a long name coming back.
    item = Item("long", used)
    if item then
      Add(out, { kind = "expired", sender = ah, subject = AuctionSubject(AUCTION_EXPIRED_MAIL_SUBJECT, item),
        days = Days(29.7, 29.99), read = false, items = { Slot(item, 1) } })
    end
    -- Canceled, with little time left: the warning tone.
    item = Item("stack", used)
    if item then
      local n = 10 + Rand(10)
      Add(out, { kind = "canceled", sender = ah, subject = AuctionSubject(AUCTION_REMOVED_MAIL_SUBJECT, item, n),
        days = Days(1.6, 2.6), read = false, items = { Slot(item, n) } })
    end
    -- A C.O.D. from another player, on its last day.
    local a, b = Item("quality", used), Item("stack", used)
    if a then
      local slots = { Slot(a, 10 + Rand(10)) }
      if b then slots[2] = Slot(b, Rand(5)) end
      Add(out, { kind = "other", sender = Name(1), subject = a.name, cod = Gold(180),
        days = Days(0.35, 0.85), read = false, items = slots })
    end
    -- From one of the player's own characters: gold, read but not taken.
    Add(out, { kind = "other", sender = alt, subject = L0["PREVIEW_GIFT"], money = Gold(500),
      days = Days(20.5, 22), read = true, icon = LETTER_ICON })
    -- And their materials: many slots.
    local pool = {}
    for k = 1, 3 do
      local it = Item(k == 2 and "quality" or "stack", used)
      if it then pool[#pool + 1] = it end
    end
    if #pool > 0 then
      local slots = {}
      for k = 1, 8 do slots[k] = Slot(pool[((k - 1) % #pool) + 1], 20 * Rand(10)) end
      Add(out, { kind = "other", sender = alt, subject = pool[1].name, days = Days(25.5, 27),
        read = false, items = slots })
    end
    -- A letter with nothing attached: no gold, no slots.
    Add(out, { kind = "other", sender = Name(2), subject = L0["PREVIEW_LETTER"], days = Days(11, 13.5),
      read = false, icon = LETTER_ICON })
    -- Read, with nothing left in it: the delete mark.
    item = Item("any", used)
    Add(out, { kind = "other", sender = Name(1), subject = item and item.name or L0["PREVIEW_LETTER"],
      days = Days(17, 19), read = true, done = true, icon = LETTER_ICON })

    table.sort(out, Newest)
    pv.mails = out
    pv.bags = nil
    return out
  end

  function CT.PreviewMails()
    return pv.mails or RV.PreviewBuild()
  end

  function CT.PreviewGen() return pv.gen end
  CT.PreviewBuild = RV.PreviewBuild

  -- The preview switched off: the set and everything made from it let go,
  -- Mail Memory's rows of it too, so nothing of it outlives the preview.
  function CT.PreviewRelease()
    pv.mails, pv.history, pv.historyGen, pv.bags = nil, nil, nil, nil
    local Memory = ns.MailMemory
    if Memory and Memory.PreviewRelease then Memory.PreviewRelease() end
  end

  -- History as collecting the set would have left it, oldest first as
  -- History keeps it: an entry per mail that held something, and the letter,
  -- read. Made once per set.
  function RV.PreviewHistory()
    local mails = CT.PreviewMails()
    if pv.history and pv.historyGen == pv.gen then return pv.history end
    local out, now = {}, time()
    for i = #mails, 1, -1 do
      local m = mails[i]
      if not m.done then
        local entry = { t = now - i * i * 1500, s = m.sender, sub = m.subject,
          k = (m.kind ~= "other") and m.kind or nil }
        if m.money > 0 then entry.m = m.money end
        if m.cod > 0 then entry.c = m.cod end
        if m.price then entry.p = m.price end
        for k = 1, #m.items do
          local it = m.items[k]
          if it.link then
            entry.it = entry.it or {}
            entry.it[#entry.it + 1] = { l = it.link, n = it.count or 1 }
          end
        end
        out[#out + 1] = entry
      end
    end
    pv.history, pv.historyGen = out, pv.gen
    return out
  end

  -- The sample source: what BindRow asks, answered from the set.
  local function At(index) return pv.mails and pv.mails[index] end
  RV.SAMPLE = {}
  function RV.SAMPLE.Header(index)
    local m = At(index)
    if not m then return nil end
    return m.icon, nil, m.sender, m.subject, m.money, m.cod, m.days, #m.items, m.read
  end
  function RV.SAMPLE.Classify(index)
    local m = At(index)
    return m and m.kind or "other", m ~= nil and m.cod > 0
  end
  function RV.SAMPLE.Stuck() return nil end
  function RV.SAMPLE.Icon(index)
    local m = At(index)
    return m and m.icon or LETTER_ICON
  end
  function RV.SAMPLE.Attachments(index)
    local m = At(index)
    if not (m and #m.items > 0) then return 0, 0, nil, 0, 0 end
    return #m.items, m.quantity, 1, m.items[1].count or 0, #m.items
  end
  function RV.SAMPLE.Mark(index)
    local m = At(index)
    return m and m.mark or nil
  end
  function RV.SAMPLE.Money(index, hasCOD, moneyValue, codValue, brief)
    local m = At(index)
    return MoneyText(hasCOD, moneyValue, codValue, m and m.price or nil, brief)
  end
  function RV.SAMPLE.Invoice(parts, index, withSaleTotal)
    local m = At(index)
    local inv = m and m.invoice
    if inv then RV.InvoiceFigures(parts, inv.type, inv.bid, inv.deposit, inv.consignment, withSaleTotal) end
  end

  -- The list the rows show, its columns and its totals from the set instead
  -- of the inbox, by the walk's own rules (CT.RefreshMailList): what is
  -- finished goes under the divider, or into Done's own tab, and each
  -- column is as wide as the widest it holds. The list is its own
  -- (panel._pvList, which the virtualiser binds from while previewing): the
  -- walk's panel._filtered stays the inbox's, for everything that counts or
  -- sweeps what is listed -- the character groups' buttons among them.
  -- `sample` is the row the walk measures in. Answers what the band totals.
  function RV.PreviewList(panel, sample, compact, view)
    local mails = CT.PreviewMails()
    local filtered, filteredDone, tail = panel._pvList, panel._pvDone, panel._pvTail
    if not filtered then
      filtered, filteredDone, tail = {}, {}, {}
      panel._pvList, panel._pvDone, panel._pvTail = filtered, filteredDone, tail
    end
    Clear(filtered)
    Clear(filteredDone)
    Clear(tail)
    local cols, markHas = panel._cols, panel._markHas
    local layout = compact and RV.Layout() or RV.LargeLayout()
    local senderCap = layout.shown.sender and SenderColumnWidth(panel, sample.Sender) or 0
    cols.sender, cols.money, cols.slots, cols.time = 0, 0, 0, 0
    markHas.time, markHas.money, markHas.slots = false, false, false
    local showEarned = compact and MoneyShown("earned")
    local showSpent = compact and MoneyShown("spent")
    local measureSlots = compact and RowShows("slots")
    local measureExpiry = compact and RowShows("time")
    local slotsMost, earned, spent = 0, 0, 0
    for i = 1, #mails do
      local m = mails[i]
      local finished = m.done == true
      if finished then
        tail[#tail + 1] = i
      else
        filtered[#filtered + 1] = i
        filteredDone[#filtered] = false
      end
      local hasCOD = m.cod > 0
      if m.kind == "bought" then spent = spent + (m.price or m.money) else earned = earned + m.money end
      if cols.sender < senderCap then
        local label = AUCTION_OUTCOME[m.kind] and L()[AUCTION_OUTCOME[m.kind].key] or DisplaySender(m.sender)
        cols.sender = min(max(cols.sender, MeasureWith(panel, sample.Sender, label) + 2), senderCap)
      end
      if compact then
        local text, kind = MoneyText(hasCOD, m.money, m.cod, m.price, true)
        local shown = true
        if kind == "earned" then shown = showEarned elseif kind == "spent" then shown = showSpent end
        if text and shown then
          cols.money = max(cols.money, MeasureWith(panel, sample.ColMoney, text))
          if finished then markHas.money = true end
        end
        if measureSlots then slotsMost = max(slotsMost, #m.items) end
        if measureExpiry then
          local expiry = RowExpiryText(m.days, hasCOD)
          if expiry then
            cols.time = max(cols.time, MeasureWith(panel, sample.ColTime, expiry))
            if finished then markHas.time = true end
          end
        end
      end
    end
    panel._readCount = #tail
    panel._dividerAt = nil
    panel._markAny = #tail > 0 and (view == VIEW_DONE or (RV.Mode() ~= "tab" and not RV.Folded(panel)))
    if view == VIEW_DONE then
      Clear(filtered)
      Clear(filteredDone)
      for i = 1, #tail do
        filtered[i] = tail[i]
        filteredDone[i] = true
      end
      earned, spent = 0, 0
    elseif #tail > 0 and RV.Mode() ~= "tab" then
      filtered[#filtered + 1] = DIVIDER
      filteredDone[#filtered] = true
      panel._dividerAt = #filtered
      if not RV.Folded(panel) then
        for i = 1, #tail do
          filtered[#filtered + 1] = tail[i]
          filteredDone[#filtered] = true
        end
      end
    end
    if slotsMost > 0 then cols.slots = RV.SlotsWidth(panel, sample.ColSlots, slotsMost) end
    return earned, spent
  end
end

-------------------------------------------------------------
-- Mail rows :: the bind
--
-- `position` is the row's DISPLAYED position, not its inbox index. The list is
-- filtered by view mode, so striping by inbox index shows three identically
-- shaded rows in a row in the read view.
--
-- `done` is the verdict the list walk already reached for this mail. It is
-- passed in rather than recomputed: Mail().IsReadPersistent scans all sixteen
-- attachment slots, and the walk that filtered the list has just paid for it.
-- Everything that follows from "this mail is finished" -- the delete control,
-- the click mapping, the tooltip's gesture hint -- reads THIS and never the
-- view, which is the whole of what makes the all view work.
-------------------------------------------------------------

local function BindRow(panel, row, index, position, compact, done)
  local T = Th()
  local M = T.Metrics
  -- Where the mail's facts are read from: the inbox, or while the arrange
  -- mode previews sample mail, the sample set (RV.SAMPLE) -- the same
  -- questions, so both are drawn by everything below alike.
  local S = panel._preview and RV.SAMPLE or RV.LIVE

  local _, _, sender, subject, money, cod, daysLeft, itemCount, wasRead = S.Header(index)
  local kind, hasCOD = S.Classify(index)
  local moneyValue = tonumber(money) or 0
  local codValue = tonumber(cod) or 0
  -- A finished mail is the only thing there is to delete from here, and it
  -- carries the control in every view that lists it.
  local showDelete = (done == true)
  -- Free when nothing has been refused this visit -- the domain answers from
  -- an empty registry without touching the inbox.
  local stuckReason = S.Stuck(index)

  -- A sample names no mail: nothing can act on it or ask the inbox about it.
  row.mailIndex = (S == RV.LIVE) and index or nil
  row.mailDone = showDelete
  -- The arrangement this row follows: the one-line rows', or the two-line
  -- rows' own (RV.LargeLayout).
  local layout = compact and RV.Layout() or RV.LargeLayout()
  -- Written from the header just read, so identity costs no extra API call. Read
  -- back by LiveIndex before anything acts on -- or describes -- this row's
  -- index; see the comment there for the window it closes.
  row.fingerprint = (S == RV.LIVE) and FingerprintOf(sender, subject, cod) or nil
  -- StyleMailRow writes _rowIndex / _hovered, which the hover handlers repaint
  -- from. `position` is the DISPLAYED position, never the inbox index.
  T.StyleMailRow(row, position, false)
  PaintRowSelection(panel, row)
  -- A finished mail is kept, not waiting: it sits back under the divider.
  row:SetAlpha(showDelete and 0.6 or 1)

  -- The read mark, or on a stuck mail the warning triangle in its place
  -- (RV.PaintDot; RV.Place shows the triangle).
  RV.PaintDot(row.Indicator, wasRead, stuckReason ~= nil)
  -- The mark's column hidden: the tooltip says what it would have.
  row.unreadTip = (not wasRead and not layout.shown.read) and L()["STATUS_UNREAD"] or nil
  row.Icon:SetTexture(S.Icon(index))
  row.Delete:SetShown(showDelete)
  -- Back to the idle tint, for the same reason StyleMailRow above re-asserts the
  -- unhovered row: this row is being bound to a different mail, so whatever
  -- hover state the last one left on it is not this one's.
  if showDelete then T.SetColor(row.Delete.Glyph, "textSecondary") end

  -- The tooltip's reason line reads it.
  row.stuckReason = stuckReason

  -- The attachments left, their total count, the slot the row's icon came
  -- from, that item's count and how many items the mail holds, for the
  -- icon's corner (RV.PaintCount) and its tooltip (RV.LIVE.Attachments).
  local remaining, quantity, iconSlot, iconCount, stacks = S.Attachments(index, itemCount)
  iconCount, stacks = iconCount or 0, stacks or 0
  row.iconSlot = iconSlot
  row.iconItems = stacks

  -- What the trailing controls take out of the row, stacking inwards from its
  -- right edge: the inset and its marks (RV.MarkRoom) -- but on a one-line
  -- row in columns the inset and what the list keeps for the delete mark
  -- on every row (RV.MarkReserve, once per pass), the mark itself drawing
  -- over the end of the last column's box, and its own text stopping short
  -- of it (markEnd).
  local markRoom = RV.MarkRoom(compact, showDelete)
  local trailing = M.inset + (compact and panel._markReserve or markRoom)
  local cols = panel._cols

  -- A partially collected auction stack must not keep advertising the quantity
  -- it arrived with, so a parenthesised count is rewritten to what is left.
  -- Only a TRAILING count: that is where the auction house writes it, and a
  -- player-written subject may contain parenthesised numbers of its own.
  -- An auction subject is shown as the item's name alone: the sender column
  -- already says "Auction House" and the category says what kind of mail it
  -- is, so "Auction won:" was the same fact a third time, and the part that
  -- pushed the item's name off the end of the row.
  local displaySubject = Helpers().ShortSubject(subject or "")
  if quantity > 0 then
    displaySubject = (displaySubject:gsub("%(%d+%)%s*$", "(" .. quantity .. ")"))
    -- A single stack whose count the icon writes: the subject does not say
    -- it again ("Light's Potential", the icon's 19). A hidden icon, or a
    -- count it shortens, and the subject keeps it.
    if stacks == 1 and RV.SaysCount(iconCount, layout) then
      displaySubject = RV.DropCount(displaySubject, quantity)
    end
  end
  -- The crafting quality mark, as the item's own link draws it: on the
  -- icon's corner, before or after the name, or both.
  local mark = (iconSlot and RV.MarkAny()) and S.Mark(index, iconSlot) or nil
  if mark and RV.MarkOnName() then displaySubject = RV.WithMark(displaySubject, mark) end
  RV.PaintQuality(row, mark, layout)
  RV.PaintNameMark(row, mark)
  RV.PaintCount(row, iconCount, stacks, layout)

  -- The meta line. `parts` is what the standard row draws under the name; the
  -- compact row draws the same figures in its columns and hands the rest --
  -- category and invoice breakdown, the two that describe rather than alert --
  -- to its tooltip. Reused tables: this runs for every visible row on every
  -- refresh, and a run refreshes once per mail.
  local parts, facts = panel._rowParts, panel._rowFacts
  Clear(parts)
  Clear(facts)

  local showSlots, showExpiry = layout.shown.slots == true, layout.shown.time == true
  local money, moneyKind = S.Money(index, hasCOD, moneyValue, codValue, compact)
  local purchaseShown = (moneyKind == "spent")
  -- In the quiet tone the time left wears: a count, not a warning. The
  -- money is the row's one coloured figure. The number alone where the
  -- player chose it and the count stands in its column: a one-line row's.
  -- The two-line row spells its figures out, with no column to say what a
  -- bare "4" counts, and the tooltip always has the words (below).
  local slots = (remaining > 0) and T.Colorize("textSecondary", RV.SlotsText(remaining, showSlots and compact)) or nil

  -- Time left is a warning, not a column: on the row only when it is short;
  -- always in the tooltip.
  row.expiryTip = daysLeft and Helpers().ExpiresIn(daysLeft) or nil
  local expiry = RowExpiryText(daysLeft, hasCOD, layout)

  -- A figure switched off leaves the row and goes to its tooltip, in full.
  if money and not MoneyShown(moneyKind, layout) then
    facts[#facts + 1] = S.Money(index, hasCOD, moneyValue, codValue, false)
    money = nil
  end
  if slots and not showSlots then
    facts[#facts + 1] = slots
    slots = nil
  end
  row.factsTip = (#facts > 0) and concat(facts, "\n") or nil

  -- The standard row reads left to right in full: money, slots, category, the
  -- time left (in the quiet tone, or the warning tone when it is short), then
  -- the invoice's figures -- except a won auction's price, which IS the money.
  -- The time left on a standard row is always there (quiet), and in the
  -- warning tone when short; a compact row carries only the warning.
  -- Both layouts follow the same time-left rule (ExpiryState), each
  -- with its own arrangement's threshold.
  local timeText = nil
  if showExpiry then
    timeText = expiry
  else
    expiry = nil
  end
  local senderText = DisplaySender(sender) or L()["SENDER_UNKNOWN"]
  -- The whole name, for the tooltip, when the row shows less of it.
  row.senderTip = (sender and senderText ~= sender) and sender or nil
  -- Auction mail says what happened where the sender would be: "Sold",
  -- "Won", "Expired", "Cancelled", each in its own colour, with the item's
  -- name beside it. "Auction House" carried no information the outcome
  -- does not, and the outcome was the one thing the row did not say.
  local outcome = OutcomeSender(kind)
  senderText = outcome or senderText
  -- A player the address book knows the class of, in its colour.
  RV.PaintSender(row.Sender, not outcome and sender or nil)
  -- A hidden sender column is said by the tooltip instead.
  if not layout.shown.sender then row.senderTip = senderText end

  -- No category on the line: the sender column already says "AH Sold", and
  -- "Other" says nothing at all. Only the two-line row draws this line, the
  -- figures in the arrangement's order, and the sender among them where
  -- that arrangement puts it on this line (RV.SenderLine); the compact row
  -- gives each figure its own column (RV.Place). Which part each piece is,
  -- for the arrange mode's segments (RV.RecordTwo).
  local ids = panel._rowPartIds
  Clear(ids)
  if not compact then
    local texts = panel._rowTexts
    texts.time, texts.money, texts.slots = timeText, money, slots
    texts.sender = nil
    if layout.shown.sender and RV.SenderLine(layout) == 2 then
      texts.sender = outcome or RV.InlineSender(sender, senderText)
    end
    for i = 1, #layout do
      local id = layout[i].id
      local text = texts[id]
      if text and (RV.FIGURE[id] or id == "sender") then
        parts[#parts + 1] = text
        ids[#parts] = id
      end
    end
    if not purchaseShown then S.Invoice(parts, index, false) end
  end

  if compact then
    -- What the row does not draw goes to the tooltip, one fact per line: the
    -- invoice figures. The money and the slot count are on the row already
    -- and are not said twice, and nor is the kind of mail -- the sender
    -- column says it.
    local tip = panel._rowTip
    Clear(tip)
    if not purchaseShown then S.Invoice(tip, index, false) end
    row.detailFull = (#tip > 0) and concat(tip, "\n") or nil
  else
    row.detailFull = nil
  end

  -- Widths derived from the list's own width, so a caption is truncated with a
  -- tooltip rather than clipped, in any locale and at any window size. The
  -- sender keeps its column whatever this mail's name is, so the subjects
  -- start on one line down the whole list.
  local spec = panel._rowSpec
  local el, text = spec.el, spec.text
  el.read, el.icon, el.sender, el.subject = row.Indicator, row.Icon, row.Sender, row.Subject
  el.time, el.money, el.slots, el.detail = row.ColTime, row.ColMoney, row.ColSlots, row.Detail
  el.stuck, spec.stuck = row.Warning, stuckReason ~= nil
  spec.markW = RV.NameMarkRoom()
  text.sender, text.subject = senderText, displaySubject
  text.time, text.money, text.slots = expiry, money, slots
  spec.size.icon = compact and ROW_ICON_COMPACT or ROW_ICON
  spec.width = UsableWidth(panel.MailListChild, FALLBACK_PANEL_WIDTH - 2 * M.inset)
  spec.left, spec.trail, spec.gap = M.inset, trailing, M.gap
  spec.markEnd = (compact and showDelete) and (M.inset + markRoom) or nil
  spec.cols = cols
  spec.senderCol = ((cols.sender or 0) > 0) and cols.sender or SENDER_MIN
  spec.share, spec.reserve = COMPACT_META_SHARE, false
  -- A C.O.D. price stands on the row even with the gold column hidden.
  spec.force = (moneyKind == "cod" and money) and "money" or nil
  spec.two = not compact
  -- The two-line row's lines sit two above and below its icon's edges.
  local lines = ((row:GetHeight() or 0) - ROW_ICON) / 2 - 2
  spec.top, spec.bottom = -lines, lines
  spec.detailText = (not compact) and concat(parts, ROW_META_JOIN) or nil
  spec.layout = (not compact) and layout or nil
  spec.detailParts = (not compact) and parts or nil
  spec.detailIds = (not compact) and ids or nil
  spec.focus = RV.Focus()
  RV.Place(row, spec)
  -- The icon's hover area goes with the icon.
  row.IconHit:SetShown(row.Icon:IsShown())

  row:Show()
end

-------------------------------------------------------------
-- History :: rows
--
-- One line per mail collected, newest first: how long ago, who from (or the
-- auction outcome), what came out of it, and what it was worth. Rows of their
-- own, not mail rows: a mail row collects on a click, and nothing here may.
-- Pooled and virtualised exactly like the mail list, in the same scroll.
-------------------------------------------------------------

-- One table for the whole section: CollectTab.lua sits near Lua 5.1's
-- two-hundred-local ceiling (see SendTab's history), so a section adds one.
local HV = {}

-- Nothing, for a record or a list there is none of: one table, not one per
-- call.
HV.NONE = {}

-- How many days History keeps (Options, Mail tab): 7 unless the player chose more.
function HV.Days()
  local UI = ns.MailboxUI
  return UI and type(UI.GetHistoryDays) == "function" and UI.GetHistoryDays() or 7
end

-- History's arrangement (MailboxUI.GetHistoryLayout), and how it writes
-- when a mail was collected (GetHistoryAge: "plain", "short", "long",
-- "date_dm", "date_md", "num_dm" or "num_md").
function HV.Layout()
  local UI = ns.MailboxUI
  if UI and type(UI.GetHistoryLayout) == "function" then return UI.GetHistoryLayout() end
  return HV.DEFAULT_LAYOUT
end
HV.DEFAULT_LAYOUT = { shown = {}, arrangement = "history" }
for _, id in ipairs({ "age", "icon", "sender", "subject", "money" }) do
  HV.DEFAULT_LAYOUT[#HV.DEFAULT_LAYOUT + 1] = { id = id, shown = true }
  HV.DEFAULT_LAYOUT.shown[id] = true
end

function HV.AgeStyle()
  local UI = ns.MailboxUI
  return UI and type(UI.GetHistoryAge) == "function" and UI.GetHistoryAge() or "short"
end

-- How long ago, as History writes it: in minutes under an hour, hours under
-- a day, days after -- "3d" plain, "3d ago" short, "3 days ago" long, each
-- language in its own words and the long one in its plural forms. `unit` is
-- 1, 2 or 3 (minutes, hours, days). Each string is made once per value,
-- unit and style and kept (HV.ages, a table per style keyed by unit and
-- value), so a row bind and the list's measuring pass make nothing: a list
-- holds a few dozen distinct ages. The locale is fixed for the session, so
-- nothing goes stale; a table past AGE_MAX strings (days beyond History's
-- month, which only a wrong clock gives) is emptied and filled again.
HV.AGE_KEYS = {
  plain = { "HISTORY_AGE_M", "HISTORY_AGE_H", "HISTORY_AGE_D" },
  short = { "HISTORY_AGO_M", "HISTORY_AGO_H", "HISTORY_AGO_D" },
  long  = { "HISTORY_AGO_MINUTES", "HISTORY_AGO_HOURS", "HISTORY_AGO_DAYS" },
}
HV.ages = { plain = {}, short = {}, long = {}, date_dm = {}, date_md = {}, num_dm = {}, num_md = {} }
HV.agesN = { plain = 0, short = 0, long = 0, date_dm = 0, date_md = 0, num_dm = 0, num_md = 0 }
HV.AGE_MAX = 200

function HV.AgeText(value, unit, style)
  if not HV.AGE_KEYS[style] then style = "short" end
  local cache = HV.ages[style]
  local key = unit * 100000 + value
  local text = cache[key]
  if text then return text end
  if HV.agesN[style] >= HV.AGE_MAX then
    for k in pairs(cache) do cache[k] = nil end
    HV.agesN[style] = 0
  end
  local name = HV.AGE_KEYS[style][unit] or HV.AGE_KEYS[style][3]
  if style == "long" then
    text = ns.Plural(name, value)
  else
    text = format(L()[name], value)
  end
  cache[key] = text
  HV.agesN[style] = HV.agesN[style] + 1
  return text
end

-- seconds [, style] -> the age as History writes it (above).
function HV.HistoryAge(seconds, style)
  seconds = max(0, seconds)
  style = style or HV.AgeStyle()
  if seconds < 3600 then return HV.AgeText(max(1, floor(seconds / 60)), 1, style) end
  if seconds < 86400 then return HV.AgeText(floor(seconds / 3600), 2, style) end
  return HV.AgeText(floor(seconds / 86400), 3, style)
end
-- The day instead: "30 Sep" (date_dm, the day first) or "Sep 30" (date_md,
-- the month first), and the year after only for a mail from another year.
-- The month is a word, never a number, so neither order can be read as the
-- other: the client's own name for it (the full date's form, which some
-- languages decline), shortened to its first three letters, and lengthened
-- where another month begins the same way (juin, juil). How a day and a
-- month stand together is each language's own (HISTORY_DATE_DM, _MD and
-- their _YEAR forms: {d} the day, {m} the month's name, {n} its number, {y}
-- the year): "30. Sep" in German, the month's number and day in Chinese.
-- Or in numbers (num_dm and num_md, HISTORY_DATE_NUM_*): {dd} and {nn} the
-- day and the month's number in two digits, {yy} the year's last two, in
-- each language's own order and marks -- "30/09", "30.09." in German,
-- "09-30" in Chinese. The year only for a mail from another year, as the
-- words have it, and in two digits where the language allows, so the
-- column stays narrow ("30/09/25").
-- Each date is written once and kept, keyed by the day (HV.ages[style], as
-- the ages are), so a bind makes nothing; the tables are written again
-- when the year turns, which moves the year in or out.
HV.MONTH_KEYS = { "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY",
  "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER" }
HV.MONTH_EN = { "January", "February", "March", "April", "May", "June", "July",
  "August", "September", "October", "November", "December" }

-- The twelve short names, found once.
function HV.Months()
  if HV.months then return HV.months end
  local chars, n = {}, {}
  for i = 1, 12 do
    local key = HV.MONTH_KEYS[i]
    local name = _G["FULLDATE_MONTH_" .. key]
    if type(name) ~= "string" or name == "" then name = _G["MONTH_" .. key] end
    if type(name) ~= "string" or name == "" then name = HV.MONTH_EN[i] end
    local list = {}
    for ch in name:gmatch("[%z\1-\127\194-\244][\128-\191]*") do list[#list + 1] = ch end
    chars[i] = list
    n[i] = min(#list, 3)
  end
  -- A short name another month's name also begins with could be either:
  -- it is lengthened by a letter until no other month's does (juin and
  -- juillet: "juin", "juil"), or it is the whole name.
  local short = {}
  for i = 1, 12 do
    local mine = chars[i]
    local ambiguous = true
    while ambiguous and n[i] < #mine do
      ambiguous = false
      for j = 1, 12 do
        local other = chars[j]
        if j ~= i and #other >= n[i] then
          local same = true
          for k = 1, n[i] do
            if other[k] ~= mine[k] then same = false break end
          end
          if same then ambiguous = true break end
        end
      end
      if ambiguous then n[i] = n[i] + 1 end
    end
    short[i] = table.concat(mine, "", 1, n[i])
  end
  HV.months = short
  return short
end

-- ymd ("20260930"), style, year now -> the date as History writes it.
HV.DATE_KEYS = {
  date_dm = { "HISTORY_DATE_DM", "HISTORY_DATE_DM_YEAR" },
  date_md = { "HISTORY_DATE_MD", "HISTORY_DATE_MD_YEAR" },
  num_dm  = { "HISTORY_DATE_NUM_DM", "HISTORY_DATE_NUM_DM_YEAR" },
  num_md  = { "HISTORY_DATE_NUM_MD", "HISTORY_DATE_NUM_MD_YEAR" },
}
function HV.FormatDate(ymd, style, year)
  local y, m, d = ymd:sub(1, 4), tonumber((ymd:sub(5, 6))), tonumber((ymd:sub(7, 8)))
  local key = (HV.DATE_KEYS[style] or HV.DATE_KEYS.date_dm)[(y ~= year) and 2 or 1]
  local parts = { d = tostring(d), m = HV.Months()[m] or tostring(m), n = tostring(m), y = y,
    dd = ymd:sub(7, 8), nn = ymd:sub(5, 6), yy = y:sub(3, 4) }
  return (L()[key]:gsub("{(%a+)}", parts))
end

-- t -> "YYYYMMDD", the day `t` fell on. Each day's bounds are kept once
-- found -- its midnight and the next, from the client's own clock, so a day
-- of 23 or 25 hours is its own length -- and any time between them reads as
-- that day without asking the clock again: a month of History asked for
-- its date once per entry on every refresh. The walk is in time order, so
-- the day used last answers nearly every entry, and the few others are
-- searched. Bounded: past HV.DAY_MAX days they are let go and found again.
HV.dayLo, HV.dayHi, HV.dayYmd, HV.dayN, HV.dayAt = {}, {}, {}, 0, 0
HV.DAY_MAX = 64
HV.dayT = {}
function HV.Ymd(t)
  local lo, hi = HV.dayLo, HV.dayHi
  local at = HV.dayAt
  if at > 0 and t >= lo[at] and t < hi[at] then return HV.dayYmd[at] end
  for i = 1, HV.dayN do
    if t >= lo[i] and t < hi[i] then
      HV.dayAt = i
      return HV.dayYmd[i]
    end
  end
  local ymd = date("%Y%m%d", t)
  local n = tonumber(ymd)
  if not n or type(time) ~= "function" then return ymd end
  -- Midnight, and the next: the day's fields set whole before each ask, as
  -- a client may write its answer back into them.
  local day = HV.dayT
  local y, m, d = floor(n / 10000), floor(n / 100) % 100, n % 100
  day.year, day.month, day.day, day.hour, day.min, day.sec, day.isdst = y, m, d, 0, 0, 0, nil
  local from = time(day)
  day.year, day.month, day.day, day.hour, day.min, day.sec, day.isdst = y, m, d + 1, 0, 0, 0, nil
  local to = time(day)
  -- Kept only when it holds `t`, as a day must.
  if not (from and to and from <= t and t < to) then return ymd end
  if HV.dayN >= HV.DAY_MAX then HV.dayN = 0 end
  at = HV.dayN + 1
  HV.dayN, HV.dayAt = at, at
  lo[at], hi[at], HV.dayYmd[at] = from, to, ymd
  return ymd
end

-- t, style, now -> the day `t` fell on, as History writes it (above).
function HV.DateText(t, style, now)
  if now ~= HV.dateNow then
    HV.dateNow = now
    local year = date("%Y", now)
    if year ~= HV.dateYear then
      HV.dateYear = year
      for s in pairs(HV.DATE_KEYS) do
        for key in pairs(HV.ages[s]) do HV.ages[s][key] = nil end
        HV.agesN[s] = 0
      end
      -- And the days found: a new year is as good a time as any to find
      -- them again (a clock set to another zone is otherwise never noticed).
      HV.dayN, HV.dayAt = 0, 0
    end
  end
  if not HV.DATE_KEYS[style] then style = "date_dm" end
  local cache = HV.ages[style]
  local ymd = HV.Ymd(t)
  local text = cache[ymd]
  if text then return text end
  if HV.agesN[style] >= HV.AGE_MAX then
    for key in pairs(cache) do cache[key] = nil end
    HV.agesN[style] = 0
  end
  text = HV.FormatDate(ymd, style, HV.dateYear)
  cache[ymd] = text
  HV.agesN[style] = HV.agesN[style] + 1
  return text
end

-- entry, now, style -> what the age column says for a History entry: how
-- long ago it was collected, or the day it was.
function HV.EntryAge(entry, now, style)
  local t = tonumber(entry.t) or now
  if HV.DATE_KEYS[style] then return HV.DateText(t, style, now) end
  return HV.HistoryAge(now - t, style)
end

-- For the arrange mode's age card, which shows each wording as it reads,
-- and for Mail Memory, whose ages read as History's short form.
CT.HistoryAgeText = HV.AgeText
CT.HistoryAge = HV.HistoryAge
CT.HistoryDateText = HV.DateText

function HV.ItemName(link)
  local name = type(link) == "string" and link:match("%[(.-)%]") or nil
  -- The crafting quality mark rides inside the link's name; the option that
  -- hides it in the list hides it here too.
  if name and not RV.MarkOnName() then
    name = (name:gsub("%s*|A:.-|a", ""))
  end
  return name
end

-- entry[, iconSays] -> what came out of it, as one short line: the first
-- item and its count, "+N" for the rest, or the subject when only money
-- came out. The count is left to the icon when `iconSays` (it writes it:
-- RV.SaysCount).
function HV.HistoryWhat(entry, iconSays)
  local items = entry.it
  if items and items[1] then
    local text = HV.ItemName(items[1].l) or ""
    if (items[1].n or 1) > 1 and not iconSays then text = text .. " x" .. items[1].n end
    if #items > 1 then text = text .. "  +" .. (#items - 1) end
    return text
  end
  return Helpers().ShortSubject(entry.sub or "")
end

-- entry, brief -> the money line in its tone, or nil: gold in green, a
-- C.O.D. paid in amber, a won auction's price in red.
function HV.HistoryMoney(entry, brief)
  local T = Th()
  local compactMoney = ns.Core.Formatting.FormatMoneyCompact
  if (entry.m or 0) > 0 then return T.Colorize("positive", "+" .. compactMoney(entry.m, brief)) end
  if (entry.c or 0) > 0 then return T.Colorize("warning", "-" .. compactMoney(entry.c, brief)) end
  if (entry.p or 0) > 0 then return T.Colorize("negative", "-" .. compactMoney(entry.p, brief)) end
  return nil
end

function HV.BuildHistoryRow(panel)
  local T = Th()
  local M = T.Metrics
  local row = CreateFrame("Button", nil, panel.MailListChild)
  row:SetHeight(COMPACT_ROW_HEIGHT)

  -- How long ago: a column as wide as the widest age listed
  -- (BuildHistoryList measures it), and one line always: "23 d" wrapped at
  -- a fixed 30px and pushed its row to two.
  row.Age = T.CreateText(row, "secondary")
  row.Age:SetPoint("LEFT", row, "LEFT", M.inset, 0)
  row.Age:SetWidth(30)
  row.Age:SetJustifyH("RIGHT")
  row.Age:SetWordWrap(false)

  -- Every column follows History's arrangement, placed on bind (RV.Place):
  -- the age leads by default, as the list is by time.
  row.Icon = row:CreateTexture(nil, "ARTWORK")
  row.Icon:SetSize(ROW_ICON_COMPACT, ROW_ICON_COMPACT)
  row.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  row.Sender = T.CreateText(row, "label")
  row.Sender:SetJustifyH("LEFT")

  row.Subject = T.CreateText(row, "value")
  row.Subject:SetJustifyH("LEFT")

  row.Money = T.CreateText(row, "secondary")
  row.Money:SetJustifyH("RIGHT")

  row:SetScript("OnEnter", function(self)
    Th().StyleMailRow(self, self._rowIndex, true)
    local entry = self.entry
    if not entry then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:SetText(entry.s ~= "" and entry.s or L()["SENDER_UNKNOWN"])
    if entry.sub and entry.sub ~= "" then GameTooltip:AddLine(entry.sub, 0.75, 0.75, 0.75, true) end
    if type(date) == "function" and entry.t then
      GameTooltip:AddLine(date("%Y-%m-%d %H:%M", entry.t), 0.6, 0.6, 0.6)
    end
    local items = entry.it or {}
    for i = 1, #items do
      local line = items[i].l or ""
      if (items[i].n or 1) > 1 then line = line .. " x" .. items[i].n end
      GameTooltip:AddLine(line, 1, 1, 1)
    end
    local money = HV.HistoryMoney(entry, false)
    if money then GameTooltip:AddLine(money, 1, 1, 1) end
    -- What the letter said, kept because the mail itself may be gone.
    if type(entry.b) == "string" and entry.b ~= "" then
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(entry.b, 1, 0.82, 0.55, true)
    end
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function(self)
    Th().StyleMailRow(self, self._rowIndex, false)
    GameTooltip:Hide()
  end)
  return row
end

function HV.BindHistoryRow(panel, row, entry, position, now, style, realm)
  local T = Th()
  local M = T.Metrics
  local R = CT.RowRules
  local layout = HV.Layout()
  row.entry = entry
  T.StyleMailRow(row, position, false)

  local icon
  local first = entry.it and entry.it[1]
  if first and first.l then
    if C_Item and type(C_Item.GetItemIconByID) == "function" then
      icon = C_Item.GetItemIconByID(first.l)
    end
  end
  if not icon and (entry.m or 0) > 0 then icon = "Interface\\Icons\\INV_Misc_Coin_01" end
  row.Icon:SetTexture(icon or "Interface\\Icons\\INV_Letter_02")
  -- The first item's quality mark on the icon's corner or before its name,
  -- as the list has it.
  local mark = first and RV.MarkOf(first.l) or nil
  RV.PaintQuality(row, mark, layout)
  RV.PaintNameMark(row, mark)
  -- Its count on the icon, and the stack edge for more than one item.
  local firstCount = first and first.n or 0
  RV.PaintCount(row, firstCount, entry.it and #entry.it or 0, layout)

  -- History's arrangement (HV.Layout), with the columns History has: the
  -- age, the icon, the sender, what came out, and the money -- which keeps
  -- its column on every row, so the list reads as a ledger, whether or not
  -- the rows line up; lined up, what came out runs on into the money's
  -- column on a row with none, as a mail row's subject does (RV.Place).
  local cols = panel._hcols
  local kind = HV.MoneyKind(entry)
  -- A system mail's sender is recorded as "": that is "unknown", not a name.
  local named = (entry.s ~= "" and entry.s) or nil
  local spec = panel._histSpec
  local el, text = spec.el, spec.text
  el.age, el.icon, el.sender, el.subject, el.money = row.Age, row.Icon, row.Sender, row.Subject, row.Money
  text.age = HV.EntryAge(entry, now, style)
  local outcome = R.OutcomeSender(entry.k)
  text.sender = outcome or R.DisplaySender(named) or L()["SENDER_UNKNOWN"]
  -- Coloured by the class it has on the realm its record is from (`realm`:
  -- nil, this character's own).
  RV.PaintSender(row.Sender, not outcome and named or nil, realm)
  text.subject = HV.HistoryWhat(entry, RV.SaysCount(firstCount, layout))
  text.money = MoneyShown(kind, layout) and HV.HistoryMoney(entry, true) or nil
  spec.layout = layout
  spec.size.icon = ROW_ICON_COMPACT
  spec.width = UsableWidth(panel.MailListChild, FALLBACK_PANEL_WIDTH - 2 * M.inset)
  spec.left, spec.trail, spec.gap = M.inset, M.inset, M.gap
  spec.cols = cols
  spec.senderCol = cols.sender or SENDER_MIN
  spec.share, spec.reserve, spec.two = nil, true, false
  spec.force = (kind == "cod") and "money" or nil
  spec.markW = RV.NameMarkRoom()
  spec.focus = RV.Focus()
  RV.Place(row, spec)
  row:Show()
end

-- entry -> what its money is, as a mail row's money is: "earned", "cod"
-- (a C.O.D. paid) or "spent" (a won auction's price), or nil.
function HV.MoneyKind(entry)
  if (entry.m or 0) > 0 then return "earned" end
  if (entry.c or 0) > 0 then return "cod" end
  if (entry.p or 0) > 0 then return "spent" end
  return nil
end

-- entry -> the folded text a search looks in: sender, subject, the outcome
-- label and every item's name. Built once per entry, not per keystroke per
-- entry (a month of History is up to a thousand of them, and a search of
-- every character's History walks each character's). Weak keys, and never a
-- field on the entry, which is saved variables; the text and the item count
-- it was built from are kept apart, so an entry costs no table of its own.
-- Rebuilt when the entry gains an item -- the reading view adds to its entry
-- as it takes -- and all of it when the quality-mark option changes what a
-- name carries (HV.SearchFresh, asked once per list) or the mailbox closes
-- (HV.ForgetSearch): what a visit's search built is not kept for the session.
HV.WEAK_KEYS = { __mode = "k" }
function HV.ForgetSearch()
  -- Nothing built since the last time: nothing to let go of.
  if HV.searchText and next(HV.searchText) == nil then return end
  HV.searchText = setmetatable({}, HV.WEAK_KEYS)
  HV.searchItems = setmetatable({}, HV.WEAK_KEYS)
end
HV.ForgetSearch()
RV.ForgetHistorySearch = HV.ForgetSearch

function HV.SearchFresh()
  local mode = RV.MarkOnName()
  if HV.searchMode ~= mode then
    HV.ForgetSearch()
    HV.searchMode = mode
  end
end

-- The pieces, joined once: a string grown item by item left one string of
-- garbage per item behind it, and an entry holds up to sixteen.
HV.searchParts = {}
function HV.SearchText(entry)
  local items = entry.it or HV.NONE
  local text = HV.searchText[entry]
  if text and HV.searchItems[entry] == #items then return text end
  local outcome = AUCTION_OUTCOME[entry.k]
  local parts = HV.searchParts
  parts[1], parts[2] = entry.s or "", entry.sub or ""
  parts[3] = outcome and L()[outcome.key] or ""
  for j = 1, #items do parts[3 + j] = HV.ItemName(items[j].l) or "" end
  text = Fold(concat(parts, "\001", 1, 3 + #items))
  HV.searchText[entry], HV.searchItems[entry] = text, #items
  return text
end

-- Whether History's list is every character's (HV.BuildHistoryList): the
-- toggle on, something typed, and Mail Memory there to say who they are.
function HV.SearchingAll(panel, query)
  local Memory = AV.Memory()
  return query ~= "" and panel._searchAll == true and panel._alt == nil
    and Memory ~= nil and Memory.HistoryCharacters ~= nil
end

-- The history view's list, newest first, narrowed by the search; its totals
-- for the banner; its columns, measured as the mail list measures its own.
-- Searching every character's History (HV.SearchingAll), each character's
-- matches follow a heading with its name, this character's first, as a
-- search of every box lists them. The headings are Mail Memory's list of
-- those characters, whose items are made to be drawn as headings, so a
-- keystroke builds nothing; `_hmatched` and `_hchars` count what it found.
function HV.BuildHistoryList(panel, query)
  local out = panel._history
  Clear(out)
  local Memory = ns.MailMemory
  local chars = HV.SearchingAll(panel, query) and Memory.HistoryCharacters() or nil
  local found = 0
  if query ~= "" then HV.SearchFresh() end
  local list = HV.NONE
  -- The arrange mode's Preview mail: History's samples (RV.PreviewHistory).
  if not chars then
    list = panel._preview and RV.PreviewHistory()
      or (Memory and Memory.History and Memory.History() or HV.NONE)
  end
  local R = CT.RowRules
  local sample = AcquireRow(panel, 1)
  local cap = SenderColumnWidth(panel, sample.Sender)
  local cols = panel._hcols
  cols.sender, cols.money, cols.age = 0, 0, 0
  local layout = HV.Layout()
  local showSender, showAge = layout.shown.sender, layout.shown.age
  local style = HV.AgeStyle()
  -- Whether the gold column shows each kind, asked once for the list rather
  -- than once per entry: a month of History is a thousand of them.
  local showEarned, showSpent = MoneyShown("earned", layout), MoneyShown("spent", layout)
  local earned, spent = 0, 0
  -- The ages are drawn at the moment they are measured at (HV.UpdateHistoryRows).
  local now = time()
  panel._hNow = now
  -- One walk, over this character's record or over each character's in
  -- turn: the next record is taken up when the one before runs out.
  local c, head, headed = 0, nil, false
  local i = #list
  while true do
    while i < 1 and chars and c < #chars do
      c = c + 1
      head, headed = chars[c], false
      list = Memory.HistoryOf(head) or HV.NONE
      i = #list
    end
    if i < 1 then break end
    local entry = list[i]
    local keep = true
    if query ~= "" then
      keep = HV.SearchText(entry):find(query, 1, true) ~= nil
    end
    if keep then
      if head and not headed then
        headed = true
        found = found + 1
        out[#out + 1] = head
      end
      out[#out + 1] = entry
      earned = earned + (entry.m or 0)
      spent = spent + (entry.c or 0) + (entry.p or 0)
      if cols.sender < cap and showSender then
        local label = (AUCTION_OUTCOME[entry.k] and L()[AUCTION_OUTCOME[entry.k].key]) or R.DisplaySender(entry.s) or ""
        cols.sender = min(max(cols.sender, MeasureWith(panel, sample.Sender, label) + 2), cap)
      end
      local kind = HV.MoneyKind(entry)
      local shown = true
      if kind == "earned" then shown = showEarned elseif kind == "spent" then shown = showSpent end
      local money = shown and HV.HistoryMoney(entry, true) or nil
      if money then cols.money = max(cols.money, MeasureWith(panel, sample.ColMoney, money)) end
      -- The age's column is as wide as the widest age listed, in the words
      -- chosen: whatever the language and wording, no age is cut.
      if showAge then
        local age = HV.EntryAge(entry, now, style)
        cols.age = max(cols.age, MeasureWith(panel, sample.ColTime, age) + 2)
      end
    end
    i = i - 1
  end
  panel._hmatched = chars and (#out - found) or nil
  panel._hchars = chars and found or nil
  return earned, spent
end

-- The note under History: the days it keeps; or, over every character's
-- History, what the search found and on how many characters, as the note
-- over a search of every box says (AV.Build).
function HV.Note(panel)
  local matched = panel._hmatched
  if not matched then return ns.Plural("HISTORY_NOTE", HV.Days()) end
  local note = ns.Plural("MEMORY_MATCHES", matched)
  if (panel._hchars or 0) > 1 then
    note = note .. "  " .. ns.Plural("MEMORY_ON_CHARACTERS", panel._hchars)
  end
  return note
end

-- The headings of a search of every character's History: Mail Memory's
-- rows, as the search of every box has them, pooled by slot apart from
-- History's own.
function HV.Head(panel, slot)
  local heads = panel._hheads
  local row = heads[slot]
  if row then return row end
  row = ns.MailMemory.NewRow(panel.MailListChild)
  row:SetHeight(COMPACT_ROW_HEIGHT)
  heads[slot] = row
  return row
end

function HV.HideHeads(panel, from)
  local heads = panel._hheads
  for i = from or 1, #heads do heads[i]:Hide() end
end

function HV.UpdateHistoryRows(panel)
  local stride = COMPACT_ROW_HEIGHT + ROW_GAP
  panel._rowStride = stride
  local list = panel._history
  local scroll = panel.MailListScroll
  local viewport = scroll:GetHeight() or 0
  local offset = scroll:GetVerticalScroll() or 0
  local first = max(1, floor(offset / stride) + 1)
  local last = first - 1
  if viewport > 0 then last = min(#list, ceil((offset + viewport) / stride)) end

  local pool = panel._hrows
  local now = panel._hNow or time()
  local style = HV.AgeStyle()
  local used, heads = 0, 0
  -- The realm of the record each entry is from, for its sender's class:
  -- over every character's History, the heading's it stands under -- the
  -- one above the first entry bound, then each heading passed -- as Mail
  -- Memory's search of every box has it (MM.RowRealm); nil, this
  -- character's own.
  local realm
  if panel._hchars then
    for k = first, 1, -1 do
      local e = list[k]
      if e and e.header then
        realm = e.realm
        break
      end
    end
  end
  for i = first, last do
    local entry = list[i]
    local y = -((i - 1) * stride)
    local row
    if entry.header then
      -- A character's heading, over every character's History: not a
      -- button, since History has no view of another character's own.
      heads = heads + 1
      realm = entry.realm
      row = HV.Head(panel, heads)
    else
      used = used + 1
      row = pool[used]
      if not row then
        row = HV.BuildHistoryRow(panel)
        pool[used] = row
      end
    end
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", panel.MailListChild, "TOPLEFT", 0, y)
    row:SetPoint("TOPRIGHT", panel.MailListChild, "TOPRIGHT", 0, y)
    if entry.header then
      ns.MailMemory.FillRow(row, entry, now, nil, i, nil, entry.realm)
    else
      HV.BindHistoryRow(panel, row, entry, i, now, style, realm)
    end
  end
  for i = used + 1, #pool do
    pool[i].entry = nil
    pool[i]:Hide()
  end
  HV.HideHeads(panel, heads + 1)
end

-- Whether the read mail is folded away under its divider: the player's own
-- click, remembered between visits. A search shows it regardless -- a match
-- must not hide behind a fold -- and so does Preview mail, whose read samples
-- are there to show the columns a read mail's row has. Nothing else folds
-- or opens it: not a scroll.
function RV.Folded(panel)
  if panel and panel._preview then return false end
  local UI = ns.MailboxUI
  local folded = UI and type(UI.GetOption) == "function" and UI.GetOption("readFolded") or false
  return folded and not Searching(panel)
end

function RV.SetFolded(folded)
  local UI = ns.MailboxUI
  if UI and type(UI.SetOption) == "function" then UI.SetOption("readFolded", folded and true or false) end
end

-- The divider's words and fold mark, for the one in the list and its pinned
-- copy. Its count follows Show mail counts, as every box count does.
function RV.PaintDivider(panel, divider)
  if ShowTabCounts() then
    divider.Label:SetText(L()("INBOX_READ_DIVIDER", panel._readCount or 0))
  else
    divider.Label:SetText(L()["INBOX_READ_DIVIDER_PLAIN"])
  end
  divider.Fold:SetTexture(RV.Folded(panel) and "Interface\\Buttons\\UI-PlusButton-Up"
    or "Interface\\Buttons\\UI-MinusButton-Up")
end

-- The divider pinned to the list's foot while its own place is below the
-- viewport: in a long inbox it is the one sign that read mail is waiting to
-- be cleared, and it has to be seen without scrolling down to find out. The
-- moment its own place scrolls into view it un-pins and sits there. Returns
-- whether it is pinned.
function RV.UpdatePin(panel, offset, viewport, stride, height)
  local pin = panel.DividerPin
  if not pin then return false end
  local at = (panel.viewMode == VIEW_COLLECT) and panel._dividerAt or nil
  -- The foot fills the list's bottom margin under whichever copy of the
  -- divider is standing on the view's foot -- this pinned one, or the one in
  -- the list at its very end -- so the bar is one height either side of the
  -- hand-over. (Shown with the pin alone, it made the bar 3px shorter the
  -- moment it settled into place.)
  local slotBottom = at and ((at - 1) * stride + height) or 0
  local viewBottom = offset + viewport
  -- Handed over within half a pixel of its place, so the bar does not move.
  -- A list whose scroll stops a hair short of its end keeps the pinned copy,
  -- in the same place.
  if not at or viewport <= 0 or slotBottom <= viewBottom + 0.5 then
    pin:Hide()
    if pin.Foot then
      pin.Foot:SetShown(at ~= nil and viewport > 0 and math.abs(slotBottom - viewBottom) <= 0.5)
    end
    return false
  end
  RV.PaintDivider(panel, pin)
  -- One compact row, whichever row size the list is in: it is a label and a
  -- button, and at a two-line row's height it hid most of a mail to say so.
  -- It lives in the list itself, a sibling of the rows a few levels above
  -- them, and is placed at the view's foot on every bind. Outside the list
  -- it was drawn UNDER the rows whatever its own level said -- the row
  -- passing beneath read straight through its fill -- and it was not clipped
  -- as they are.
  local child = panel.MailListChild
  local y = -(offset + viewport - COMPACT_ROW_HEIGHT)
  pin:ClearAllPoints()
  pin:SetPoint("TOPLEFT", child, "TOPLEFT", 0, y)
  pin:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, y)
  pin:SetHeight(COMPACT_ROW_HEIGHT)
  pin:SetFrameLevel(child:GetFrameLevel() + 8)
  pin:Show()
  if pin.Foot then pin.Foot:Show() end
  return true
end

-------------------------------------------------------------
-- Mail rows :: the virtualiser
--
-- Only the rows the viewport can show are materialised. The pool therefore
-- never grows past one screenful however large the inbox is, and a refresh is a
-- re-bind of frames that already exist rather than a rebuild.
-------------------------------------------------------------

local function UpdateVisibleRows(panel)
  -- Timed, with the rows it binds, while an open is being measured
  -- (Postbox.lua, 5b); nil otherwise.
  local perf = ns.Perf
  local perfAt = perf and perf.cur and perf.Begin and perf.Begin()
  -- While the arrange mode is open over this tab its column header stands on
  -- the lanes this pass publishes (Core/Arrange.lua): told before, so a pass
  -- that places no one-line row leaves none, and after.
  local A = ns.Arrange
  local arranging = A ~= nil and A.host ~= nil and A.host.owner == panel
  if arranging and A.ListPlacing then A.ListPlacing(panel) end
  -- Another character's box takes the list: its own rows, and none of these.
  local away = AV.Active(panel)
  if away then AV.UpdateRows(panel) else AV.HideRows(panel) end
  local historyView = (panel.viewMode == VIEW_HISTORY) and not away
  if historyView then
    HV.UpdateHistoryRows(panel)
  else
    for i = 1, #panel._hrows do
      panel._hrows[i].entry = nil
      panel._hrows[i]:Hide()
    end
    HV.HideHeads(panel)
  end
  local compact, height, stride = RowMetrics()
  -- The stride this pass laid the list out at. Read by CT.ApplyRowLayout, which
  -- has to convert a scroll offset taken under one stride into the same place
  -- under the other; nothing else may write it.
  panel._rowStride = stride
  local filtered, filteredDone = panel._filtered, panel._filteredDone
  -- Preview mail's own list (RV.PreviewList), in the inbox's place.
  if panel._preview and panel._pvList then filtered, filteredDone = panel._pvList, panel._pvDone end
  local scroll = panel.MailListScroll
  local viewport = scroll:GetHeight() or 0
  local offset = scroll:GetVerticalScroll() or 0

  local first = max(1, floor(offset / stride) + 1)
  local last = first - 1
  if viewport > 0 and not historyView and not away then
    last = min(#filtered, ceil((offset + viewport) / stride))
  end
  if historyView or away then panel._rowStride = COMPACT_ROW_HEIGHT + ROW_GAP end

  local used = 0
  local divider = panel.Divider
  if divider then divider:Hide() end
  -- The list's lanes are its first row's (RV.Place): in columns every
  -- one-line row keeps the same room for the delete mark a read mail draws
  -- over its last column (RV.MarkReserve), from what the list's walk found;
  -- false while they are packed, each row keeping its own mark's room.
  panel._rowSpec.publish = true
  panel._markReserve = (compact and not historyView and not away and RV.LinedUp())
    and RV.MarkReserve(RV.Layout(), panel._cols, panel._markHas, panel._markAny, true) or false
  for i = first, last do
    if filtered[i] == DIVIDER then
      -- One compact row in either row size, at the FOOT of its slot: that is
      -- where the pinned copy stands at the moment it hands over (its slot
      -- has just come fully into view), so the bar stays where it is. Larger
      -- rows leave the rest of the slot as air above it.
      local y = -((i - 1) * stride) - (height - COMPACT_ROW_HEIGHT)
      divider:SetHeight(COMPACT_ROW_HEIGHT)
      divider:ClearAllPoints()
      divider:SetPoint("TOPLEFT", panel.MailListChild, "TOPLEFT", 0, y)
      divider:SetPoint("TOPRIGHT", panel.MailListChild, "TOPRIGHT", 0, y)
      RV.PaintDivider(panel, divider)
      divider:Show()
    else
    used = used + 1
    local row = AcquireRow(panel, used)
    -- Before the bind, and before the row is positioned: this is what gives a
    -- freshly built row its height, and what re-lays a pooled one the first time
    -- it is bound after the option changed.
    ApplyRowMode(row, compact, height)
    local y = -((i - 1) * stride)
    -- Two corner points on the same edge fix the width and the top without
    -- constraining the vertical centre, which would fight SetHeight.
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", panel.MailListChild, "TOPLEFT", 0, y)
    row:SetPoint("TOPRIGHT", panel.MailListChild, "TOPRIGHT", 0, y)
    BindRow(panel, row, filtered[i], i, compact, filteredDone[i])
    end
  end

  for i = used + 1, #panel._rows do
    local row = panel._rows[i]
    -- Everything the row knows about a mail goes with the mail. A released row
    -- names nothing, so nothing it is still holding can act or be described.
    row.mailIndex = nil
    row.mailDone = nil
    row.fingerprint = nil
    row.iconSlot = nil
    row.stuckReason = nil
    row.detailFull = nil
    row.expiryTip = nil
    row.factsTip = nil
    row.senderTip = nil
    row.unreadTip = nil
    row.Warning:Hide()
    row:Hide()
  end
  -- Pinned, the divider's copy stands at the foot and its own place (at most
  -- a sliver of it, at the viewport's bottom edge) is not drawn twice.
  if RV.UpdatePin(panel, offset, (historyView or away) and 0 or viewport, stride, height) and divider then
    divider:Hide()
  end
  -- Rows carry no skinnable children -- no tagged push button, no themed panel,
  -- no edit box -- so a newly grown pool entry needs no ns.Skin.Refresh pass.
  -- Adding one here would re-walk the whole panel on every scroll tick.
  if arranging and A.ListPlaced then A.ListPlaced(panel) end
  -- An open fan follows its row: the same mail, drawn again as it now is;
  -- anything else closes it. One comparison while none is open.
  if RV.fanOpen then RV.FanCheck(panel) end
  if perfAt then perf.Rows(perfAt, used) end
end

-------------------------------------------------------------
-- The totals banner
-------------------------------------------------------------

-- The banner's text, at whatever detail its width allows. Two sums with
-- coins outrun a narrow window -- "Total spent: 1309g 62s 0c" ran off the
-- band's right edge -- so the line is tried at falling detail: both labels
-- and every coin, then without the copper, then the short labels, then the
-- largest coin alone. The first that fits is the one shown. Runs again
-- whenever the band's width changes, from the sums it last drew.
-- The helpers and the candidates' list are made once, here, rather than on
-- every refresh.
local FitBanner
do
  local candidates = {}

  local function Line(strings, icons, sums, up, down, parts)
    return strings["BANNER_EARNED_SHORT"] .. icons(sums.earned, up, parts)
        .. "   |   " .. strings["BANNER_SPENT_SHORT"] .. icons(sums.spent, down, parts)
  end

  -- How many inline textures a line carries ("|T" escapes), counted in
  -- place.
  local function IconCount(s)
    local n, at = 0, 1
    while true do
      local i = s:find("|T", at, true)
      if not i then return n end
      n, at = n + 1, i + 2
    end
  end

  -- The client's measurement leaves inline textures out -- the fullest
  -- line "fitted" and ran off the band by about the width of its coins --
  -- so each coin is added back at its declared size. Where a client does
  -- count them the line is judged a little wide, which at the worst costs
  -- a coin at a borderline width.
  local function Width(text, candidate, iconSize)
    return (text:GetStringWidth() or 0) + IconCount(candidate) * iconSize
  end

  FitBanner = function(panel)
    local text = panel.BannerText
    local sums = panel._bannerSums
    if not (text and sums) then return end
    local T = Th()
    local icons = ns.Core.Formatting.FormatMoneyIcons
    local strings = L()
    local up, down = "ff" .. T.Hex.positive, "ff" .. T.Hex.negative
    -- A window style that lays the band on a light plate (the post box's white
    -- enamel) inks the label and hands back the figures' dark twins.
    local skin = ns.Skin
    if skin and skin.BannerInk then up, down = skin.BannerInk(text, up, down) end

    -- Two coins is the whole of it: "Earned 95g 57s". The copper on a total
    -- of the whole inbox is noise, and "Total" said nothing the band's
    -- position under the list did not. The single coin is for a narrow window.
    candidates[1] = Line(strings, icons, sums, up, down, 2)
    candidates[2] = Line(strings, icons, sums, up, down, 1)
    local iconSize = ns.Core.Formatting.MONEY_ICON_SIZE or 12

    -- The room is the band's, not the string's: asked for its own width, the
    -- string answered with the width of whatever it was showing, so the
    -- fullest line always "fit" and ran off the band regardless. The band's
    -- width is a fact. No width yet (the first paint) means no verdict: the
    -- fullest line stands, and the size change that follows the layout fits
    -- it. The width is then SET on the string, so a line that still does not
    -- fit is cut with an ellipsis rather than drawn past the edge -- and
    -- whether it was cut is the verdict, textures and all, where the client
    -- can say; the measured width is the fallback where it cannot.
    local room = (panel.Banner:GetWidth() or 0) - (panel._bannerTextLeft or 0) - (panel._bannerTextRight or 0)
    if room <= 0 then
      text:SetText(candidates[1])
      return
    end
    text:SetWidth(room)
    local canAsk = type(text.IsTruncated) == "function"
    for i = 1, #candidates do
      text:SetText(candidates[i])
      if i == #candidates then return end
      -- Both tests, and a line passes only both: the cut flag knows about the
      -- coin textures, the measured width does not depend on the wrap.
      local cut = canAsk and text:IsTruncated()
      local wide = Width(text, candidates[i], iconSize) > room
      if not cut and not wide then return end
    end
  end
end

-- The sums, kept in one table per panel, rewritten in place.
local function UpdateBanner(panel, earned, spent)
  if not panel.Banner then return end
  local sums = panel._bannerSums
  if not sums then
    sums = {}
    panel._bannerSums = sums
  end
  sums.earned, sums.spent = tonumber(earned) or 0, tonumber(spent) or 0
  FitBanner(panel)
end

-------------------------------------------------------------
-- The list
-------------------------------------------------------------

local CloseDetailIfStale  -- forward declaration

-- The inbox can hold more mail than the server will address at once. Saying so
-- is the difference between "you have collected everything" and "you have
-- collected everything the game would show us".
--
-- The hint line is the natural place for it, but that line yields to the view
-- segments when a long translation leaves no room -- and a notice the player
-- may not see is not a notice. So it is also said once in chat, on the
-- transition into the truncated state.
local function UpdateHint(panel, numItems, totalItems)
  local hint = panel.Hint
  if not hint then return end

  local truncated = totalItems > numItems
  if StuckOnly(panel) then
    hint:SetText(Th().Colorize("warning", L()["HINT_STUCK_ONLY"]))
  elseif truncated then
    -- The top row has room for the numbers alone ("50 of 72 shown"); the
    -- chat says why, once.
    hint:SetText(L()("HINT_INBOX_TRUNCATED", numItems, totalItems))
    if not panel._truncationTold then
      panel._truncationTold = true
      ns.Print(L()("MSG_INBOX_TRUNCATED", numItems, totalItems))
    end
  else
    -- Nothing to say. This line used to carry "C.O.D. mail is never taken
    -- automatically" -- a promise the screen keeps anyway, standing on the
    -- top row of every visit to reassure about something that has not
    -- happened. The confirmation dialog is where that fact belongs, and it
    -- is already there.
    hint:SetText("")
    panel._truncationTold = false
  end
end

function CT.RefreshMailList(panel)
  if not panel or not panel.MailListChild then return end
  -- Refreshing a panel nobody can see is wasted work; the OnShow handler drains
  -- the flag.
  if not panel:IsShown() then
    panel._dirty = true
    return
  end
  panel._dirty = false
  -- Timed while an open is being measured (Postbox.lua, 5b): the whole
  -- refresh, and the walk up to the row binds. nil otherwise.
  local perf = ns.Perf
  local perfAt = perf and perf.cur and perf.Begin and perf.Begin()

  CloseDetailIfStale(panel)

  local numItems, totalItems = 0, 0
  if type(GetInboxNumItems) == "function" then
    numItems, totalItems = GetInboxNumItems()
    numItems = tonumber(numItems) or 0
    totalItems = tonumber(totalItems) or numItems
  end

  -- A selection names inbox indices, and a changed count means those indices
  -- name different mails now -- as does a pick whose index no longer holds
  -- the mail it was made on (RV.SelectionHolds). Dropped before the list is
  -- rebuilt, so no row is ever painted as picked for a mail nobody picked.
  if panel._lastNumItems ~= numItems then
    panel._lastNumItems = numItems
    ClearSelection(panel)
  elseif Selecting(panel) and not RV.SelectionHolds(panel) then
    ClearSelection(panel)
  end

  local filtered, filteredDone = panel._filtered, panel._filteredDone
  Clear(filtered)
  Clear(filteredDone)

  -- The inbox lists every mail; what is finished goes after the rest, under
  -- the divider. One pass either way.
  local view = panel.viewMode
  local tail, tailDone = panel._tail, panel._tailDone
  Clear(tail)
  -- Nothing stuck any more: the filter has nothing to show and lets go.
  if StuckOnly(panel) and Mail().StuckCount() == 0 then panel._stuckOnly = false end
  local stuckOnly = StuckOnly(panel)
  local earned, spent = 0, 0
  -- Tallied here rather than by a second walk anywhere else. Every consumer
  -- wants the same verdict for the same mails, and that verdict is the expensive
  -- one: IsReadPersistent scans all sixteen attachment slots of every finished
  -- mail, so a second walk cost a fifty-mail inbox some eight hundred redundant
  -- API calls on every single refresh. This walk is the one that records; see
  -- "The inbox counts".
  local doneCount, toCollectCount, goneCount = 0, 0, 0
  -- The search, folded once. Matched against the sender and the subject as
  -- the client reports them; the counts above are deliberately NOT narrowed
  -- by it, because the segment captions describe the inbox, not the view.
  local query = Fold(SearchQuery(panel))

  -- The compact row's columns and the category buttons' counts, from this same
  -- walk (see "the columns"). The first pooled row is the font sample, so the
  -- measuring is done in the face the rows actually draw in.
  local cols, counts = panel._cols, panel._catCounts
  for key in pairs(counts) do counts[key] = nil end
  -- A new measuring pass: each distinct text is measured once in it. The
  -- walk's measuring runs from here to the other lists' builds below, and
  -- reads each sample's font once (MeasureWith).
  panel._measurePass = (panel._measurePass or 0) + 1
  panel._measureWalk = panel._measurePass
  RV.MeasureScale(panel)
  local compact = CompactRows()
  local sample = AcquireRow(panel, 1)
  -- The arrangement the inbox's rows follow at this size (BindRow).
  local rowLayout = compact and RV.Layout() or RV.LargeLayout()
  local senderCap = rowLayout.shown.sender and SenderColumnWidth(panel, sample.Sender) or 0
  cols.sender = 0
  cols.money, cols.slots, cols.time = 0, 0, 0
  -- The inbox's own columns are measured only while its rows are what is on
  -- screen: History and another character's box measure their own, and the
  -- walk below still has to run for the counts and the totals. Coming back
  -- to the inbox refreshes the list, which measures again.
  local measuring = not (view == VIEW_HISTORY or AV.Active(panel))
  local measureMoney = compact and measuring
  -- Whether the gold column shows each kind, asked once for the walk rather
  -- than once per mail.
  local showEarned = measureMoney and MoneyShown("earned")
  local showSpent = measureMoney and MoneyShown("spent")
  local measureSlots = compact and measuring and RowShows("slots")
  local measureExpiry = compact and measuring and RowShows("time")
  local slotsMost = 0
  local altKeys = Mail().OwnCharacterKeys()
  -- The figures a finished mail -- a read mail, listed with its delete
  -- mark -- draws on its row (RV.MarkReserve): its time left or a won
  -- auction's price; it holds nothing, so never slots.
  local markHas = panel._markHas
  markHas.time, markHas.money, markHas.slots = false, false, false
  -- Only the mails this view lists are measured: a finished mail folded
  -- away under the divider (RV.Folded) or waiting in the Done tab widens no
  -- column of the inbox's, and on the Done tab a mail still to collect
  -- widens none of its. Both are known before the walk, as the split after
  -- it reads them.
  local measureOpen = measuring and view ~= VIEW_DONE
  local measureDone = measuring and (view == VIEW_DONE or (RV.Mode() ~= "tab" and not RV.Folded(panel)))

  for index = 1, numItems do
    -- "Read" alone will not do: collecting marks every mail read as a side
    -- effect of loading its attachments, so a mail that was read but still
    -- holds items -- the normal outcome when bags fill mid-run -- has to stay
    -- in the actionable list.
    -- A mail on its way out is neither: as far as the list and its counts
    -- go, it has already gone (RV.Leaving).
    local leaving = RV.Leaving(index)
    local finished = not leaving and Mail().IsReadPersistent(index)
    if leaving then
      goneCount = goneCount + 1
    elseif finished then
      doneCount = doneCount + 1
    else
      toCollectCount = toCollectCount + 1
    end
    local listed = not leaving and (not stuckOnly or Mail().StuckReason(index) ~= nil)
    local money, cod, daysLeft, itemCount, sender
    if listed then
      local _, _, subject
      _, _, sender, subject, money, cod, daysLeft, itemCount = GetInboxHeaderInfo(index)
      if query ~= "" then
        listed = Fold(sender or ""):find(query, 1, true) ~= nil
              or Fold(subject or ""):find(query, 1, true) ~= nil
              or RV.OutcomeMatches(index, query)
      end
    end
    if listed then
      -- The verdict travels with the index, so the row binder never repeats the
      -- sixteen-slot scan this walk has already paid for.
      if finished then
        tail[#tail + 1] = index
      else
        filtered[#filtered + 1] = index
        filteredDone[#filtered] = false
      end
      local kind, hasCOD = Mail().ClassifyMail(index)
      local rowEarned, rowSpent = MailEconomy(index, kind, money)
      earned = earned + rowEarned
      spent = spent + rowSpent

      -- Under the stuck filter every listed mail is stuck, which no sweep
      -- takes; the primary ("Shown") retries them as a selection would
      -- (StartCategoryRun), so it counts them. The block below never does.
      if stuckOnly and not finished and not hasCOD then counts.all = (counts.all or 0) + 1 end
      -- What each sweep would take: unfinished, never C.O.D., and not held
      -- back -- stuck, or holding items while the bags are full -- the rules
      -- the queue builder applies, so a count is a promise the button keeps.
      if not finished and not hasCOD and not Mail().HeldBack(index, tonumber(itemCount) or 0) then
        counts.all = (counts.all or 0) + 1
        -- From alts and Other split the non-auction mail between them.
        if Mail().FromOwnCharacter(index, altKeys) then
          counts.alts = (counts.alts or 0) + 1
          if kind ~= "other" then counts[kind] = (counts[kind] or 0) + 1 end
        else
          counts[kind] = (counts[kind] or 0) + 1
        end
      end

      -- The sender column is as wide as the widest name it will show, up to
      -- the ceiling; an auction outcome shows its label, not "Auction House".
      -- (senderCap is zero while the arrangement hides the column.)
      local measured = finished and measureDone or (not finished and measureOpen)
      if measured and cols.sender < senderCap then
        local label = AUCTION_OUTCOME[kind] and L()[AUCTION_OUTCOME[kind].key]
          or DisplaySender(sender or L()["SENDER_UNKNOWN"])
        cols.sender = min(max(cols.sender, MeasureWith(panel, sample.Sender, label) + 2), senderCap)
      end

      if compact and measured then
        if measureMoney then
          local text, moneyKind = RowMoneyText(index, hasCOD, tonumber(money) or 0, tonumber(cod) or 0, true)
          local shown = true
          if moneyKind == "earned" then shown = showEarned elseif moneyKind == "spent" then shown = showSpent end
          if text and shown then
            cols.money = max(cols.money, MeasureWith(panel, sample.ColMoney, text))
            if finished then markHas.money = true end
          end
        end
        if measureSlots then slotsMost = max(slotsMost, tonumber(itemCount) or 0) end
        if measureExpiry then
          local text = RowExpiryText(daysLeft, hasCOD)
          if text then
            cols.time = max(cols.time, MeasureWith(panel, sample.ColTime, text))
            if finished then markHas.time = true end
          end
        end
      end
    end
  end

  -- The finished mails, after the divider: simply the rest of the list, so
  -- the scroll bar is the whole list from the start -- unless the player has
  -- folded them away with a click (RV.Folded). The divider is their heading,
  -- pinned at the list's foot while its place is further down (RV.UpdatePin):
  -- read mail waiting is seen without a scroll. (They were once opened and
  -- folded BY the scroll, and the scroll bar jumped each time the list grew;
  -- only a click moves the fold now.)
  -- In a tab of their own they are that tab's whole list, and the inbox has
  -- no divider at all.
  panel._readCount = #tail
  panel._dividerAt = nil
  -- Whether a row the list shows carries the delete mark: a finished mail
  -- listed, and not folded away (RV.MarkReserve). By what is listed, never
  -- by what is scrolled into view.
  panel._markAny = #tail > 0 and (view == VIEW_DONE or (RV.Mode() ~= "tab" and not RV.Folded(panel)))
  if view == VIEW_DONE then
    Clear(filtered)
    Clear(filteredDone)
    for i = 1, #tail do
      filtered[i] = tail[i]
      filteredDone[i] = true
    end
    -- The band totals what is listed, and read mail with nothing left in it
    -- carries no gold either way.
    earned, spent = 0, 0
  elseif #tail > 0 and RV.Mode() ~= "tab" then
    filtered[#filtered + 1] = DIVIDER
    filteredDone[#filtered] = true
    panel._dividerAt = #filtered
    if not RV.Folded(panel) then
      for i = 1, #tail do
        filtered[#filtered + 1] = tail[i]
        filteredDone[#filtered] = true
      end
    end
  end

  if slotsMost > 0 then
    cols.slots = RV.SlotsWidth(panel, sample.ColSlots, slotsMost)
  end
  -- The arrange mode's Preview mail lists its samples in the inbox's place
  -- (RV.PreviewList). The walk above has still run: the counts it recorded
  -- stay the inbox's.
  local previewed = nil
  if panel._preview and view ~= VIEW_HISTORY and not AV.Active(panel) then
    earned, spent = RV.PreviewList(panel, sample, compact, view)
    previewed = panel._pvList
  end
  -- A stuck mail's mark stands in its read mark's place and needs no room;
  -- the room the rows keep for a read mail's delete mark is decided as they
  -- are placed (RV.MarkReserve), from what this walk found.

  local _, _, stride = RowMetrics()
  local listed = #filtered
  if previewed then listed = #previewed end
  -- The history view lists the record, not the inbox. The walk above still
  -- ran: the segment counts describe the inbox whichever view is showing.
  if view == VIEW_HISTORY then
    earned, spent = HV.BuildHistoryList(panel, query)
    stride = COMPACT_ROW_HEIGHT + ROW_GAP
    listed = #panel._history
    panel.HistoryNote:SetText(HV.Note(panel))
  end
  -- Another character's box, or every box's matches: that list instead.
  local away = AV.Active(panel)
  if away then
    earned, spent, listed = AV.Build(panel, query)
    stride = COMPACT_ROW_HEIGHT + ROW_GAP
  end
  panel._measureWalk = nil
  RV.ApplyFooter(panel)
  panel.MailListChild:SetHeight(max(RV.ListHeight(listed, stride), 1))

  -- A shorter list can leave the scroll offset past the new end, which would
  -- render an empty viewport over a list that has content.
  local scroll = panel.MailListScroll
  local maxScroll = max(0, RV.ListHeight(listed, stride) - (scroll:GetHeight() or 0))
  if (scroll:GetVerticalScroll() or 0) > maxScroll then scroll:SetVerticalScroll(maxScroll) end
  if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end

  if perfAt then perf.Walk(perfAt) end
  UpdateVisibleRows(panel)

  -- One sentence per view, each true of exactly that view: "nothing to collect"
  -- on a mailbox that still holds finished mail would be right and would read as
  -- a lie on the all view, where those mails are on screen.
  local emptyText = L()["EMPTY_LIST_ALL"]
  if query ~= "" then
    emptyText = L()["EMPTY_LIST_SEARCH"]
  elseif away then
    emptyText = ns.MailMemory.SeenText(panel._avInfo and panel._avInfo.snapshot)
  elseif view == VIEW_HISTORY then
    emptyText = ns.Plural("EMPTY_LIST_HISTORY", HV.Days())
  elseif view == VIEW_DONE then
    emptyText = L()["EMPTY_LIST_DONE"]
  elseif #tail > 0 then
    -- Read mail waits in the Done tab: the box is not empty, there is just
    -- nothing to collect.
    emptyText = L()["EMPTY_LIST_COLLECT"]
  end
  panel.Empty:SetText(emptyText)
  panel.Empty:SetShown(listed == 0)

  UpdateBanner(panel, earned, spent)
  -- The verdicts this walk reached, published before anything renders them: all
  -- three segment captions are readings of these two numbers, and `numItems` --
  -- what the client can actually address -- is the total they add up to and the
  -- number the all segment carries.
  RecordCounts(toCollectCount, doneCount, numItems, totalItems, goneCount)
  -- More mail on the server than the client lists: the primary stays live.
  panel._moreOnServer = totalItems > numItems
  -- Hint first, counts second: both change the width of something in the top
  -- row, and UpdateTabCounts ends in the one layout pass that measures it.
  UpdateHint(panel, numItems, totalItems)
  CT.UpdateTabCounts(panel)
  -- The category buttons carry counts from this walk too.
  CT.RefreshCategoryButtons(panel)
  -- The stuck registry can have changed under this refresh, so the idle line is
  -- re-rendered rather than left showing whatever the last inbox event computed.
  RefreshIdleSummary()

  -- A run owns the status line for its whole duration. Re-asserting it here
  -- means nothing else can leave a stale idle summary on screen mid-run.
  if CT.IsRunning() then CT.RefreshRunStatus() end

  if perfAt then perf.End("refresh", perfAt) end
end

-- The row layout option changed. Frozen: Core/MailboxUI.lua calls this from the
-- options panel's checkbox.
--
-- A refresh IS the relayout -- it re-binds every visible row, and a bind goes
-- through ApplyRowMode -- so the only thing this has to add is the scroll
-- position. That is stored in PIXELS, and the same pixel offset names a
-- different mail the instant the stride changes; carrying it across as the
-- fractional row it was pointing at is what stops the list jumping somewhere
-- else the moment a display option is toggled.
function CT.ApplyRowLayout(panel)
  if not panel or not panel.MailListChild then return end
  -- The rebuild is what applies the new layout and it will not run on a hidden
  -- panel. Mark it instead; the panel's OnShow drains the flag.
  if not panel:IsShown() then
    RequestRefresh(panel)
    return
  end

  local scroll = panel.MailListScroll
  local previous = panel._rowStride or 0
  local anchor = (previous > 0) and ((scroll:GetVerticalScroll() or 0) / previous) or 0

  CT.RefreshMailList(panel)

  local stride = panel._rowStride or 0
  if stride <= 0 then return end
  local listed = #((panel._preview and panel._pvList) or panel._filtered)
  if AV.Active(panel) then
    listed = #(panel._avRows or {})
  elseif panel.viewMode == VIEW_HISTORY then
    listed = #panel._history
  end
  local maxScroll = max(0, RV.ListHeight(listed, stride) - (scroll:GetHeight() or 0))
  scroll:SetVerticalScroll(min(anchor * stride, maxScroll))
  if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end
  -- Explicit rather than left to the scroll frame's own handler: that fires only
  -- when the offset actually moved, and when it did not the rows the refresh
  -- just bound are already the right ones -- so this is a no-op in the one case
  -- and the whole point in the other.
  UpdateVisibleRows(panel)
end

-- The shell nudges the list on MAIL_SUCCESS. Coalesced like every other
-- refresh, so a burst of successes during a run costs one rebuild per frame.
function CT.OnMailSuccess()
  local UI = ns.MailboxUI
  local panel = UI and UI._frame and UI._frame.Tabs and UI._frame.Tabs.collect
  RequestRefresh(panel)
end

-------------------------------------------------------------
-- Single-mail actions
-------------------------------------------------------------

-- Read-mail mode "delete": a mail Postbox has just emptied of gold or items,
-- or a letter the reading view's Back has just closed on, goes the moment it
-- is finished with -- read, and nothing left in it. Checked against what
-- RV.Before took before the take: an auction mail the server deleted on its
-- own has moved on, and whatever slid into its index is not this call's to
-- delete. `record` is the mail's
-- History record, so a deleted letter stays listed there with what it said.
-- `andThen` runs whatever happened.
function RV.AutoDelete(panel, index, before, record, andThen)
  local function Continue() if andThen then andThen() end end
  if RV.Mode() ~= "delete" or not index or type(before) ~= "table" then return Continue() end
  if not MailboxOpen() or Mail().IsBusy() then return Continue() end
  if (tonumber((GetInboxNumItems())) or 0) ~= before.count then return Continue() end
  -- Emptiness is the client's word, header and links both. A collect hands
  -- over its mail once the header has caught up with the take (MailService,
  -- "Letting the header catch up"); a mail that still does not read finished
  -- by then is left where it is, under the divider, never deleted on a guess.
  if RV.Identity(index) ~= before.id or not Mail().IsReadPersistent(index) then return Continue() end
  -- Mail with no text of its own that Postbox has just emptied is already
  -- on its way out: the client deletes it itself (MailService, "Mail on its
  -- way out"), and a delete of ours would be a second command for a mail
  -- the server is removing. A run waits for it to go, as it would have
  -- waited for a delete of its own, so the next mail is taken and checked
  -- against the inbox as it will stand (RV.AfterLeaving).
  local leaving = Mail().Leaving(index)
  if leaving then
    if andThen then return RV.AfterLeaving(before, leaving, andThen) end
    return
  end
  -- The option's promise is that History keeps what a deleted letter said.
  -- With History at Never it keeps nothing, so a letter with words of its
  -- own stays, under the divider, for the player to clear; mail with no
  -- text of its own still goes.
  if not RV.HistoryOn() and Mail().HasOwnText(index) then return Continue() end
  if record and Mail().HistoryNote then Mail().HistoryNote(record, "read") end
  -- Through the sweep that re-checks the index immediately before its
  -- command: deleting is the irreversible one.
  Mail().DeleteMails({ index }, function()
    RequestRefresh(panel)
    Continue()
  end, { [index] = Fingerprint(index) })
end

-- before, at, fn -> fn() once the mail just emptied, which the client is
-- deleting, has gone: the inbox lists fewer mails than it did before the
-- take (RV.Before). Or once its hold lapses (`at`, MailService.Leaving), or
-- the mailbox closes, whichever comes first. Event-driven, registered only
-- for the wait, one one-shot deadline.
function RV.AfterLeaving(before, at, fn)
  local bus = ns.Events
  if not (bus and type(bus.Register) == "function") then return fn() end
  local check
  local function go()
    if not check then return end
    bus.Unregister("MAIL_INBOX_UPDATE", check)
    bus.Unregister("MAIL_CLOSED", go)
    check = nil
    fn()
  end
  check = function()
    if (tonumber((GetInboxNumItems())) or 0) < before.count or not MailboxOpen() then go() end
  end
  bus.Register("MAIL_INBOX_UPDATE", check)
  bus.Register("MAIL_CLOSED", go)
  C_Timer.After(max(0, at - GetTime()) + 0.1, go)
end

-- index -> sender and subject: the part of a mail's identity a take cannot
-- change (a paid C.O.D. reads 0 afterwards, which the full fingerprint counts).
function RV.Identity(index)
  local _, _, sender, subject = GetInboxHeaderInfo(index)
  if sender == nil and subject == nil then return nil end
  return tostring(sender) .. "\001" .. tostring(subject)
end

-- index -> what RV.AutoDelete checks the mail against once the take is done:
-- its identity, and how many mails the client lists. Sender and subject alone
-- are not enough: a mail emptied of everything and with no text is deleted
-- by the server, the one above it slides into its index, and two mails from
-- one alt with one subject read alike. A count that moved means the listing
-- changed under the take, and nothing is deleted on a guess.
function RV.Before(index)
  local id = RV.Identity(index)
  if not id then return nil end
  return { id = id, count = tonumber((GetInboxNumItems())) or 0 }
end

-- index, unpaid -> whether the C.O.D. the player confirmed has changed hands:
-- the mail at the index no longer reads as `unpaid`, its fingerprint before
-- the take. The first take pays, and a paid mail reads nothing owed from
-- then on; one it emptied has gone. A take that moved nothing -- refused,
-- or answered "collected" with no link loaded to take by -- leaves the mail
-- reading exactly as it did, and nothing is said.
function RV.CODPaid(index, unpaid)
  return unpaid ~= nil and Fingerprint(index) ~= unpaid
end

-- Whether the mail held gold or items, from its header (an unread mail's
-- attachment links are not loaded yet, so the header is the one reading).
function RV.HeldSomething(index)
  local _, _, _, _, money, _, _, itemCount = GetInboxHeaderInfo(index)
  return (tonumber(money) or 0) > 0 or (tonumber(itemCount) or 0) > 0
end

function CollectSingleMail(panel, index, opts)
  ConfirmCOD(index, function()
    -- The one path allowed to pay a C.O.D. -- the player just confirmed this
    -- exact mail's amount (or it has none). The service refuses everywhere
    -- else, whatever mail an index turns out to name (see Mail.CollectMail).
    local confirmed = {}
    if type(opts) == "table" then
      for k, v in pairs(opts) do confirmed[k] = v end
    end
    confirmed.allowCOD = true
    local _, _, _, _, _, codBefore = GetInboxHeaderInfo(index)
    codBefore = tonumber(codBefore) or 0
    local unpaid = codBefore > 0 and Fingerprint(index) or nil
    -- Only a mail that held something is finished by a collect: an unread
    -- letter "collected" was read by the fetch, not by the player.
    local before = RV.HeldSomething(index) and RV.Before(index) or nil
    Mail().CollectMail(index, function(status, refused, reason)
      -- A confirmed C.O.D. that actually changed hands is reported in chat,
      -- with the amount, once the mail no longer reads as owing it
      -- (RV.CODPaid): emptied, or partly taken with its C.O.D. reading zero.
      -- Read before anything else can touch the mail.
      if codBefore > 0 and (status == "collected" or status == "refused")
        and RV.CODPaid(index, unpaid) then
        ns.Print(L()("MSG_COD_PAID", Helpers().FormatMoney(codBefore)))
      end
      -- Emptied: in the "delete" read-mail mode it goes now, not later.
      if status == "collected" then
        RV.AutoDelete(panel, index, before, confirmed.history)
      end
      -- "busy" is a Postbox sequence already owning the channel; that run is
      -- writing its own status and must not be talked over.
      if status == "busy" then return end
      if status == "closed" then
        StatusMailboxClosed()
        return
      end
      if status == "timeout" then
        ns.Print(L()["MSG_MAIL_TIMEOUT"])
      elseif status == "refused" then
        if refused > 0 then
          -- The money and the other attachments did come through; only the
          -- takes the server declined are left behind.
          ns.Print(MailPartialMessage(refused, reason))
        else
          -- Nothing attributable to a particular take, but the mail is not
          -- empty. Say only that, without guessing why.
          ns.Print(L()["MSG_ITEM_NOT_COLLECTED"])
        end
        -- The domain has just recorded this mail as stuck, so the number in the
        -- title bar is out of date as of this instant.
        RefreshIdleSummary()
      end
      RequestRefresh(panel)
    end, confirmed)
  end)
end

-- A row in the read view is finished by definition -- read, no money, no
-- attachments -- so deleting it loses nothing and needs no confirmation. The
-- detail view's Delete can reach a mail that still holds something, and that
-- one confirms; see BuildDetail.
--
-- `fingerprint` is the mail's as the player saw it when they chose to delete
-- it. The service checks it against the index immediately before the
-- command, after any wait for the channel, and leaves a mail that has moved
-- alone ("moved": the refresh shows the list as it now is).
function DeleteOneMail(panel, index, fingerprint)
  if not index or not fingerprint then return end
  Mail().DeleteMail(index, function(status)
    if status == "closed" then
      StatusMailboxClosed()
    elseif status == "timeout" then
      ns.Print(L()["MSG_MAIL_TIMEOUT"])
    end
    RequestRefresh(panel)
  end, fingerprint)
end

-------------------------------------------------------------
-- Bulk delete
--
-- Irreversible, and the previous build asked nothing at all.
--
-- It deletes what the done view LISTS, which is not the same thing as "every
-- mail with the read flag set": Mail().BuildDeleteQueue requires read AND no
-- money AND no attachments left, the same three tests IsReadPersistent makes. So
-- a mail the server refused -- read, but still holding the items it refused --
-- is never in the queue, and the button cannot reach anything that is still
-- waiting to be collected. That is why it could be renamed to match the done
-- view without touching what it does.
-------------------------------------------------------------

local function DeleteAllDone(panel)
  -- The list holds samples while the arrange mode previews them.
  if panel._preview then return end
  if not MailboxOpen() then
    StatusMailboxClosed()
    return
  end
  local queue = Mail().BuildDeleteQueue()
  -- Under a search the divider counts the read mail it lists, so Delete
  -- takes exactly those: the dialog must name the number the divider did.
  if Searching(panel) then
    local shown = {}
    for i = 1, #panel._tail do shown[panel._tail[i]] = true end
    local narrowed = {}
    for i = 1, #queue do
      if shown[queue[i]] then narrowed[#narrowed + 1] = queue[i] end
    end
    queue = narrowed
  end
  if #queue == 0 then return end

  local message = ns.Plural("CONFIRM_DELETE_ALL_DONE", #queue)

  -- What each queued index NAMES right now. Deleting is the irreversible one,
  -- and the inbox can reindex both while the dialog waits and between the
  -- sweep's own commands -- so the sweep verifies each index against this
  -- snapshot immediately before its command and skips any that moved.
  local expected = {}
  for i = 1, #queue do expected[queue[i]] = Fingerprint(queue[i]) end

  Confirm(POPUP_DELETE_ALL, DeleteLabel(), L()["COD_CONFIRM_CANCEL"],
    message, function()
      Mail().DeleteMails(queue, function(deleted, status)
        -- The mailbox can close between the confirmation and the answer, and
        -- the sweep stops where it is; saying so beats a dialog that dismisses
        -- itself over a half-deleted list.
        if status == "closed" then
          StatusMailboxClosed()
        elseif status == "timeout" then
          ns.Print(L()["MSG_MAIL_TIMEOUT"])
        end
        -- The receipt for an irreversible sweep: how many actually went, in
        -- chat, where it survives the window closing. Zero stays silent --
        -- every deletable mail moved before the answer, nothing happened.
        if (tonumber(deleted) or 0) > 0 then
          ns.Print(L()("MSG_DELETED_COUNT", ns.Plural("COUNT_MAILS", deleted)))
        end
        RequestRefresh(panel)
      end, expected)
    end)
end

-------------------------------------------------------------
-- The collection run
--
-- MailService owns the handshake for one mail. What a run adds is bookkeeping:
-- how many mails came through, how many attachments the server refused and why,
-- and -- the part that matters -- whether the run reached the end of its queue
-- or was stopped. Reporting "Done" for a stopped run is what made the old
-- silent-loss bug invisible, so the three outcomes are kept apart:
--
--   left > 0      the run was STOPPED and that many queued mails are still in
--                 the mailbox. stopReason says which guard stopped it: the
--                 connection ("timeout"), or bags with no room left ("bags",
--                 which is a state rather than a failure -- see FinishRun),
--                 or the slots "Keep bag slots free" leaves free ("keep").
--   refused > 0   the server would not hand over some attachments, for
--                 reasons of those mails' own (Run.stuck counts the mails).
--                 Nothing was at risk.
--   neither       everything came through.
--
-- The run state lives here rather than on the shell's shared table: the shell
-- renders what this publishes and does not own it.
--
-- It also tallies MONEY, because a run is the only thing that knows which mails
-- it took. The banner above the list totals what is currently LISTED, which is a
-- different question with a different answer -- it changes as the player switches
-- segments and it says nothing about what this particular sweep brought in. The
-- two are the same arithmetic (MailEconomy) applied to two different sets, which
-- is why there is one function and not two definitions of "earned".
-------------------------------------------------------------

local Run = {
  active = false,
  panel = nil,
  queue = {},
  cursor = 0,
  current = nil,
  collected = 0,
  refused = 0,
  -- Mails the server refused for reasons of their own: the outcome's
  -- "Stuck: N", counted by mail as the title bar's is. `refused` counts items.
  stuck = 0,
  earned = 0,
  spent = 0,
  reason = nil,
  reasonMixed = false,
  -- Handed to every CollectMail of the run: { keepFree = N } (BeginRun).
  opts = {},
}

function CT.IsRunning()
  return Run.active and true or false
end

local function Remaining()
  local left = #Run.queue - Run.cursor
  if Run.current then left = left + 1 end
  return max(left, 0)
end

function CT.RefreshRunStatus()
  if not Run.active then return end
  StatusActivity(format(L()["STATUS_REMAINING"], Remaining()))
end

-- One refusal reason for a whole run. Two attachments can be refused for
-- different reasons, and quoting one would misdescribe the other, so a second
-- different reason falls back to the generic wording.
local function NoteReason(reason)
  if not reason or reason == "" or Run.reasonMixed then return end
  if Run.reason == nil then
    Run.reason = reason
  elseif Run.reason ~= reason then
    Run.reason, Run.reasonMixed = nil, true
  end
end

local function ResetRun()
  Run.active = false
  Run.current = nil
  Run.cursor = 0
  Clear(Run.queue)
  Run.collected = 0
  Run.refused = 0
  Run.stuck = 0
  Run.earned = 0
  Run.spent = 0
  Run.reason = nil
  Run.reasonMixed = false
end

-- One line, at the end of a run, for the money that changed hands during it.
--
-- Both sides or one: a sweep of expired auctions earns nothing and a sweep of
-- purchases costs nothing, and "Earned 0g" is noise on either. Nothing is said
-- at all when neither side moved, which is the ordinary case for a mailbox full
-- of item mail -- a run that moved no gold should not announce that it did not.
--
-- Chat rather than the status line: the status line has one slot and a run's
-- OUTCOME owns it, and the outcome is the thing a player has to read.
local function ReportRunMoney(earned, spent)
  if earned <= 0 and spent <= 0 then return end

  local fmt = Helpers().FormatMoney
  local template
  if earned > 0 and spent > 0 then
    template = RawKey("MSG_RUN_EARNED_SPENT")
    if template then
      ns.Print(format(template, fmt(earned), fmt(spent)))
      return
    end
  end

  -- Either only one side moved, or the combined key is not in this locale yet.
  -- Two independent sentences say the same facts and cannot render as a broken
  -- template, so the fallback is the same shape as the normal path.
  if earned > 0 then
    local one = RawKey("MSG_RUN_EARNED")
    if one then ns.Print(format(one, fmt(earned))) end
  end
  if spent > 0 then
    local one = RawKey("MSG_RUN_SPENT")
    if one then ns.Print(format(one, fmt(spent))) end
  end
end

-------------------------------------------------------------
-- Run memory (.dev/SPEC-RunMemory.md): one small saved record per character
-- of the last run that ended badly, so the NEXT mailbox visit -- or the next
-- session -- opens with "last visit: N mails could not be taken" instead of
-- silence. A clean finish erases it; an inbox that emptied on its own erases
-- it at read time (Core/MailboxUI.lua, UpdateStatusSummary). Keyed by raw
-- GetRealmName()/UnitName like every other per-character table, stored at
-- the saved-variables root because profile values are boolean-only.
-------------------------------------------------------------

local function LastRunStore(create)
  local realm = GetRealmName()
  local name = UnitName("player")
  if type(realm) ~= "string" or realm == "" then return nil end
  if type(name) ~= "string" or name == "" then return nil end

  if create then
    local root = ns.Store.EnsurePath("lastRun")
    local byName = root[realm]
    if type(byName) ~= "table" then
      byName = {}
      root[realm] = byName
    end
    return byName, name
  end

  local root = ns.Store.Get("lastRun")
  local byName = type(root) == "table" and root[realm] or nil
  return type(byName) == "table" and byName or nil, name
end

function CT.GetLastRunRecord()
  local byName, name = LastRunStore(false)
  local record = byName and name and byName[name]
  if type(record) == "table" then return record end
  return nil
end

function CT.ClearLastRunRecord()
  local byName, name = LastRunStore(false)
  if byName and name then byName[name] = nil end
end

local function SaveLastRunRecord(collected, refused, left, reason, stopReason)
  local byName, name = LastRunStore(true)
  if not byName then return end
  local M = Mail()
  byName[name] = {
    at         = (type(time) == "function" and time()) or 0,
    collected  = collected,
    refused    = refused,
    left       = left,
    -- The game's own words, kept verbatim so the summary can attribute them
    -- the way every refusal message does.
    reason     = reason,
    stopReason = stopReason,
    -- The stuck registry's fingerprints ride along (capped in the service),
    -- so the next session can revive the per-mail markers, not just the
    -- sentence. See SeedStuckFromRecord below.
    stuck      = M and M.StuckSnapshot and M.StuckSnapshot() or nil,
  }
end

-- Run-memory bridge, called by the shell on mail open: the saved record's
-- fingerprints revive the live registry once per session, so the row
-- triangles and the Stuck count come back after a relog. After the seed the
-- live registry is the truth -- its entries re-validate against the live
-- inbox on every read, so anything resolved since simply never shows.
local recordSeeded = false

function CT.SeedStuckFromRecord()
  if recordSeeded then return end
  recordSeeded = true
  local record = CT.GetLastRunRecord()
  local M = Mail()
  if record and type(record.stuck) == "table" and M and M.SeedStuck then
    M.SeedStuck(record.stuck)
  end
end

-- The closing half of the bridge, called by the shell when the mailbox
-- shuts: the record's fingerprints re-sync to whatever the registry holds
-- NOW. This is what makes relog survival independent of HOW a refusal
-- happened -- a run that finished wrote its record, but a run the player
-- walked out of writes nothing, a clean sweep of one category erases the
-- record while another category's mail is still stuck, and a single-click
-- take never touches the record at all. One sync at the boundary covers
-- every path. What it saves has been pruned of fingerprints whose mail has
-- gone whenever the whole inbox was in view (Mail.PruneStuck, on each inbox
-- update); with a truncated inbox they ride along, capped, and are filtered
-- at read.
function CT.SyncStuckRecord()
  local M = Mail()
  local snap = M and type(M.StuckSnapshot) == "function" and M.StuckSnapshot() or nil
  local record = CT.GetLastRunRecord()
  if snap then
    if record then
      -- The stored table itself: writing through updates SavedVariables.
      record.stuck = snap
    else
      -- No run wrote a record this visit (walk-away, or a single take's
      -- refusal). The counts claim nothing -- the fingerprints are the
      -- payload, and /postbox debug is the counts' only reader.
      SaveLastRunRecord(0, 0, 0, nil, nil)
    end
  elseif record then
    record.stuck = nil
  end
end

local function FinishRun(left, stopReason)
  local refused = Run.refused
  local stuck = Run.stuck
  local collected = Run.collected
  local reason = Run.reason
  local earned, spent = Run.earned, Run.spent
  local panel = Run.panel
  local keepFree = Run.opts.keepFree or 0
  ResetRun()

  -- A bad ending is written down for next visit; a clean one erases the note.
  if (tonumber(left) or 0) > 0 or (tonumber(refused) or 0) > 0 then
    SaveLastRunRecord(collected, refused, left, reason, stopReason)
  else
    CT.ClearLastRunRecord()
  end

  -- Every outcome leads with what came out: "Collected: 12" alone when the
  -- run was clean, with the problem appended after an em dash when it was
  -- not. The count is this session's report and deliberately does NOT
  -- persist -- a reopen shows only what is still actionable (the summary
  -- layer's Stuck line); what was collected is already in the bags.
  --
  -- Coloured PER SEGMENT with inline escapes, not one layer tone for the
  -- whole line: a green fact and an amber problem sharing one sentence must
  -- not both wear the problem's colour. The em dash carries no colour of
  -- its own, so it renders in the label's default -- a neutral divider.
  local theme = ns.Theme
  local function Tinted(token, text)
    if theme and theme.Colorize then return theme.Colorize(token, text) end
    return text
  end
  local got = tonumber(collected) or 0
  local JOIN = " \226\128\148 " -- em dash, spaced
  -- The green half leads only when there is anything green to say:
  -- "Collected: 0 — Stuck: 1" buries the one fact that matters under a
  -- zero. A clean run still reports its zero ("Collected: 0" on an empty
  -- category is a truthful nothing-to-do).
  local function WithCollected(problemText)
    if got > 0 then
      return Tinted("positive", format(L()["STATUS_COLLECTED"], got))
        .. JOIN .. problemText
    end
    return problemText
  end

  -- Bags full is the character's state, not this run's alone (MailService,
  -- "Bags full"): whenever it holds as a run ends -- this run stopped on it,
  -- or an earlier one did and this one took what needed no room -- the
  -- outcome says how many mails are waiting for room, and the shell takes
  -- the line down by itself once there is room (MailboxUI.OnBagsFullChanged).
  local M = Mail()
  local waiting = (M.BagsFull and M.BagsFull() and M.BagsWaiting and M.BagsWaiting()) or 0

  if left > 0 and stopReason ~= "bags" and stopReason ~= "keep" then
    StatusOutcome(WithCollected(
      Tinted("negative", format(L()["STATUS_INCOMPLETE"], left))))
    ns.Print(ns.Plural("MSG_COLLECT_INCOMPLETE", left))
  else
    -- What stayed behind, by mail: the stuck ones, then the ones waiting for
    -- room. Either, both, or neither.
    local problem
    if stuck > 0 then problem = Tinted("warning", format(L()["STATUS_PARTIAL"], stuck)) end
    if waiting > 0 then
      local full = Tinted("warning", format(L()["STATUS_BAGS_FULL"], waiting))
      problem = problem and (problem .. JOIN .. full) or full
    end
    -- Stopped by "Keep bag slots free": the bags state's wording, for a
    -- stop the player asked for. Not a state -- the next run goes as far.
    if stopReason == "keep" then
      local kept = Tinted("warning", ns.Plural("STATUS_KEPT_FREE", keepFree))
      problem = problem and (problem .. JOIN .. kept) or kept
    end
    if problem then
      StatusOutcome(WithCollected(problem))
      -- When room appears only the bags part comes down: the line then reads
      -- as it would have after a clean run, with any stuck mail still named.
      local UI = ns.MailboxUI
      if waiting > 0 and UI and type(UI.TagStatusOutcome) == "function" then
        UI.TagStatusOutcome("bags", stuck > 0
          and WithCollected(Tinted("warning", format(L()["STATUS_PARTIAL"], stuck)))
          or Tinted("positive", format(L()["STATUS_COLLECTED"], got)))
      end
    else
      StatusOutcome(Tinted("positive", format(L()["STATUS_COLLECTED"], got)))
    end
    -- The chat keeps the items: which of a mail's attachments stayed is what
    -- the game's words are about.
    if refused > 0 then
      local stayed
      if reason and reason ~= "" then
        stayed = ns.Plural("MSG_ITEMS_REFUSED_REASON", refused, reason)
      else
        stayed = ns.Plural("MSG_ITEMS_REFUSED", refused)
      end
      ns.Print(L()("MSG_COLLECT_PARTIAL", ns.Plural("COUNT_MAILS", collected), stayed))
    end
    if stopReason == "bags" then
      ns.Print(ns.Plural("MSG_COLLECT_STOPPED_BAGS", left))
    elseif stopReason == "keep" then
      ns.Print(ns.Plural("MSG_COLLECT_STOPPED_KEEP", left, ns.Plural("COUNT_SLOTS", keepFree)))
    end
  end

  -- After the outcome, never instead of it: a stopped run's "3 left" is the line
  -- the player has to act on, and the money is context under it.
  ReportRunMoney(earned, spent)

  RequestRefresh(panel)
  Mail().RequestInboxRefresh()
end

-- The mailbox closed under the run. What it had already taken is still taken, so
-- the money is reported here too -- a sweep that is interrupted halfway is
-- exactly when a player wants to know what did come through.
local function StopRun()
  local panel = Run.panel
  local earned, spent = Run.earned, Run.spent
  ResetRun()
  StatusMailboxClosed()
  ReportRunMoney(earned, spent)
  RequestRefresh(panel)
end

local function RunStep()
  if not Run.active then return end
  if not MailboxOpen() then
    -- The player walked away mid-run. Stop where we are and say so.
    StopRun()
    return
  end

  Run.cursor = Run.cursor + 1
  local index = Run.queue[Run.cursor]
  if not index then
    FinishRun(0)
    return
  end

  Run.current = index
  CT.RefreshRunStatus()
  RequestRefresh(Run.panel)

  -- Read BEFORE the take, because the take is what removes the evidence: a mail
  -- emptied of its money reports zero, and one emptied completely is deleted by
  -- the server and its index names a different mail entirely.
  local _, _, _, _, money = GetInboxHeaderInfo(index)
  local kind = Mail().ClassifyMail(index)
  local mailEarned, mailSpent = MailEconomy(index, kind, money)
  local before = RV.HeldSomething(index) and RV.Before(index) or nil

  Mail().CollectMail(index, function(status, refused, reason, refusal)
    Run.current = nil
    RequestRefresh(Run.panel)

    if not Run.active then return end

    if status == "closed" then
      StopRun()
      return
    end

    if status == "busy" or status == "timeout" then
      -- Something is wrong with the run itself: the server stopped
      -- acknowledging commands, or the command channel was not ours to use at
      -- all. Either way the next command could be silently discarded. Stop, and
      -- count this mail plus everything still queued as left behind.
      FinishRun(Remaining() + 1, "timeout")
      return
    end

    -- The run keeps bag slots free and has reached them (Run.opts.keepFree):
    -- it ends here, as a bags stop does, with this mail and the rest still
    -- in the mailbox. Only the gold of a mail that had some came out -- a
    -- mail holding only items was not touched -- so only then is it tallied.
    if status == "refused" and refusal == "keep" then
      if (tonumber(money) or 0) > 0 then
        Run.earned = Run.earned + mailEarned
        Run.spent = Run.spent + mailSpent
      end
      FinishRun(Remaining() + 1, "keep")
      return
    end

    -- Past the two statuses that mean "the take may not have happened", so the
    -- money did change hands -- including on a REFUSED take, where the server
    -- declines specific attachments and hands over the money and the rest
    -- regardless. Tallied before the bag-space guard below, which can end the
    -- run on this very mail.
    Run.earned = Run.earned + mailEarned
    Run.spent = Run.spent + mailSpent

    if status == "refused" and refusal == "bags" then
      -- The one refusal that stops the run: the bags are full (the service
      -- has set its bags-full state and marked nothing on the mail). Every
      -- further take would be refused too, and each mail walked past would be
      -- marked read for nothing. The mail just refused still holds its items,
      -- so it counts as left alongside everything still queued.
      FinishRun(Remaining() + 1, "bags")
      return
    elseif status == "refused" then
      -- A fact about those items, not about the run: record them and keep
      -- going, because one item the player cannot hold must not block every
      -- other mail in the queue. Counted by mail for the outcome, by item for
      -- the chat line.
      local n = tonumber(refused) or 0
      Run.refused = Run.refused + n
      if n > 0 then Run.stuck = Run.stuck + 1 end
      NoteReason(reason)
    else
      Run.collected = Run.collected + 1
    end

    -- An emptied letter goes before the next mail, in the "delete" read-mail
    -- mode. The run works downwards, so deleting this index moves none of the
    -- indices still queued.
    if status == "collected" then
      RV.AutoDelete(Run.panel, index, before, nil, RunStep)
    else
      RunStep()
    end
  end, Run.opts)
end

local function BeginRun(panel, queue)
  ResetRun()
  Run.active = true
  Run.panel = panel
  -- "Keep bag slots free", read once for the run: the service stops before
  -- the item take that would go below it (MailService, RunPlan). One table
  -- for every mail of every run, not one per mail.
  Run.opts.keepFree = RV.KeepFreeSlots()
  for i = 1, #queue do Run.queue[i] = queue[i] end
  -- Indices shift under a run; an overlay addressed by index cannot survive it.
  if panel.Detail then panel.Detail:Hide() end
  RV.FanClose(true)
  CT.RefreshRunStatus()
  RunStep()
end

-- Bag space is checked before a single mail is marked read. Collecting marks
-- every queued mail read, which resets its expiry clock and moves it out of the
-- actionable view, so doing that for mails whose attachments cannot physically
-- fit is the damaging part.
local function StartCategoryRun(panel, category)
  if Run.active or Mail().IsBusy() then return end
  -- While the arrange mode previews sample mail the list holds samples, not
  -- inbox indices: nothing may be queued from it.
  if panel._preview then return end
  if not MailboxOpen() then
    ns.Print(L()["ERR_OPEN_MAILBOX_LOOT"])
    return
  end

  -- Under a search the primary takes the mails on screen -- the list this
  -- panel last built -- and nothing else. The category buttons are withdrawn
  -- while a search is on, so `all` is the only category that can arrive here
  -- in that state.
  local queue, info
  if Selecting(panel) then
    -- The picked rows, and of those only the ones the button names: the
    -- primary takes them all, a category button the picked mail of its
    -- kind, a group's button the picked mail from its characters (never a
    -- C.O.D.). The selection is the narrowing that counts, over a search as
    -- well: the primary under a selection takes every pick, so a button
    -- takes its kind of every pick. The selection is spent by the run
    -- whatever comes of it: collecting moves the inbox's indices, and a
    -- refused run leaves ordinary uncollected mail, which the next press
    -- picks up as such. Picked one by one, they are tried as a click on
    -- each row would be, stuck or not.
    queue, info = Mail().BuildQueueFor(SelectionIndices(panel), category, true)
    ClearSelection(panel)
  elseif Searching(panel) or StuckOnly(panel) then
    -- The rows on screen, narrowed again by the sweep's own category. The
    -- stuck filter is a narrowing like a search: the buttons count what it
    -- shows, so they take what it shows. Its rows are the stuck mails the
    -- player asked to see, so the primary ("Shown") retries them as it
    -- would a selection; the category sweeps still leave them be.
    queue, info = Mail().BuildQueueFor(panel._filtered, category,
      StuckOnly(panel) and category == "all")
  else
    queue, info = Mail().BuildQueue(category)
  end

  -- The inbox is still arriving: GetInboxNumItems reports 0 between MAIL_SHOW
  -- and the first MAIL_INBOX_UPDATE, and an index whose header has not landed
  -- is left out of the queue. Running now would sweep a truncated list and then
  -- report a clean finish over the mails it never saw.
  if info.unloaded > 0 or (info.numItems == 0 and info.totalItems > 0) then
    StatusOutcome(L()["STATUS_READY"])
    Mail().RequestInboxRefresh()
    RequestRefresh(panel)
    return
  end

  -- Everything the client shows is dealt with but the server holds more:
  -- the click asks for the next batch rather than answering "Done".
  if #queue == 0 and (tonumber(info.totalItems) or 0) > (tonumber(info.numItems) or 0) then
    StatusOutcome(L()["STATUS_READY"])
    Mail().RequestInboxRefresh()
    RequestRefresh(panel)
    return
  end

  if #queue == 0 then
    -- Everything it matched is stuck or waiting for bag room: not "Done",
    -- and the status line already says which.
    if (info.heldBack or 0) > 0 then
      RefreshIdleSummary()
    else
      StatusOutcome(L()["STATUS_DONE"], "positive")
    end
    RequestRefresh(panel)
    return
  end

  -- The general bags and the reagent bag together, as this check has always
  -- counted: reagent mail may well fit there, and a run that meets full bags
  -- anyway stops cleanly as a bags stop. What it says is the general bags'
  -- number, as All mail's tooltip does, with the reagent bag's room said
  -- apart: only reagents go there (RV.ReagentExtra).
  local free, reagent = Mail().FreeBagSlots()
  if free ~= nil then
    -- "Keep bag slots free": the run fills only the general slots above
    -- that, so they are the room it has (0 keeps none, and this is exactly
    -- the check it always was). Said as the slots it may fill, with the kept
    -- ones after them: "you have 3 slots free (+2 kept free)".
    local keep = RV.KeepFreeSlots()
    local usable = math.max(0, free - keep)
    local room = usable + (reagent or 0)
    local needed = Mail().QueueAttachmentSlots(queue)
    if needed > room then
      local fits = Mail().QueuePrefixThatFits(queue, room)
      local need, have = ns.Plural("COUNT_SLOTS", needed), ns.Plural("COUNT_SLOTS", usable)
      local extra = RV.KeptExtra(free, keep) .. RV.ReagentExtra(reagent)
      if fits <= 0 and usable < free then
        -- Nothing fits above the slots kept free, and there are free slots:
        -- no dialog about bag space the player can see is there, just the
        -- run's own stop, before anything is marked read.
        StatusOutcome(Th().Colorize("warning", ns.Plural("STATUS_KEPT_FREE", keep)))
        ns.Print(ns.Plural("MSG_COLLECT_STOPPED_KEEP", #queue, ns.Plural("COUNT_SLOTS", keep)))
        RequestRefresh(panel)
        return
      end
      if fits <= 0 then
        -- Nothing at all would fit. Refuse before anything is marked read.
        ShowNotice(L()("MSG_BAGS_FULL", need, have, extra))
        return
      end
      -- Snapshot what the dialog is about to describe, in queue order (highest
      -- inbox index first, so the remaining indices stay valid). The player can
      -- click a different category before answering, and this run must collect
      -- what the dialog said it would.
      local planned, prints = {}, {}
      for i = 1, fits do
        planned[i] = queue[i]
        prints[i] = Fingerprint(queue[i])
      end
      Confirm(POPUP_BAGSPACE, L()["BAGSPACE_CONFIRM_ACCEPT"], L()["COD_CONFIRM_CANCEL"],
        ns.Plural("MSG_BAGSPACE_PARTIAL", fits, ns.Plural("COUNT_MAILS", #queue), need, have, extra),
        function()
          -- The dialog is not modal: rows can be clicked and the inbox can
          -- reindex while it waits, and then these indices name different
          -- mails -- including, possibly, C.O.D. mail the queue was built to
          -- exclude. Only the entries that still name the mail the dialog
          -- described are run; the dropped ones are ordinary uncollected mail
          -- the next run picks up at their new indices.
          local verified = {}
          for i = 1, #planned do
            if prints[i] and Fingerprint(planned[i]) == prints[i] then
              verified[#verified + 1] = planned[i]
            end
          end
          if #verified == 0 then
            RequestRefresh(panel)
            return
          end
          BeginRun(panel, verified)
        end)
      return
    end
  end

  BeginRun(panel, queue)
end
-- For a sweep drawn outside this file: a character group's button starts its
-- run here with the token "group:<id>" (Core/CharacterGroups.lua).
CT.StartCategoryRun = StartCategoryRun

-------------------------------------------------------------
-- The detail view
--
-- An overlay over the collect screen: at the 480px window minimum there is no
-- room for a two-pane layout.
--
-- Three bands, bottom-anchored in this order: the action row, then the
-- attachment row, then the body. They are separate frames and the body's bottom
-- inset follows the two below it, which is what makes the Delete control
-- reachable -- in the previous build it sat at the bottom-left underneath the
-- first three attachment slots, which were created later at the same frame
-- level and therefore ate every click on it.
-------------------------------------------------------------

local DETAIL_ACTIONS = { "Back", "Collect", "Reply", "Return", "Delete" }

local function LayoutDetailActions(detail)
  local T = Th()
  local M = T.Metrics
  local shown = detail._shownActions
  Clear(shown)
  for i = 1, #DETAIL_ACTIONS do
    local button = detail[DETAIL_ACTIONS[i]]
    if button:IsShown() then shown[#shown + 1] = button end
  end
  if #shown == 0 then
    detail.ActionRow:SetHeight(1)
    return
  end

  local available = UsableWidth(detail.ActionRow, FALLBACK_PANEL_WIDTH - 2 * M.inset)
  -- Measured, longest-member-wins, and it wraps rather than overflowing: the
  -- four fixed-width buttons this replaces needed ~456px of a ~460px panel in
  -- English, and German "Zurueckschicken" did not fit its 100px allowance at
  -- all.
  local per, lines = T.LayoutRow(shown, available, {
    height = M.controlHeight,
    gap = M.tightGap,
    minWidth = M.buttonMinWidth,
  })
  local perLine = ceil(#shown / max(lines, 1))

  for i = 1, #shown do
    local line = floor((i - 1) / perLine)
    local column = (i - 1) - line * perLine
    shown[i]:ClearAllPoints()
    shown[i]:SetPoint("TOPLEFT", detail.ActionRow, "TOPLEFT",
      column * (per + M.tightGap), -line * (M.controlHeight + M.tightGap))
  end

  detail.ActionRow:SetHeight(lines * M.controlHeight + (lines - 1) * M.tightGap)
end

local function LayoutDetailSlots(detail)
  local T = Th()
  local M = T.Metrics
  -- The tiles in row order: the coin first when there is gold, then the
  -- item slots that hold something.
  local tiles = detail._tiles
  if not tiles then
    tiles = {}
    detail._tiles = tiles
  end
  Clear(tiles)
  if detail.MoneySlot and (detail._money or 0) > 0 then tiles[#tiles + 1] = detail.MoneySlot end
  for i = 1, detail._slotCount or 0 do tiles[#tiles + 1] = detail.Slots[i] end

  local count = #tiles
  if count <= 0 then
    detail.SlotRow:SetHeight(1)
    detail.SlotRow:Hide()
    return
  end

  local available = UsableWidth(detail.SlotRow, FALLBACK_PANEL_WIDTH - 2 * M.inset)
  local step = M.slotSize + M.tightGap
  local perLine = max(1, floor((available + M.tightGap) / step))
  local lines = ceil(count / perLine)

  for i = 1, count do
    local slot = tiles[i]
    local line = floor((i - 1) / perLine)
    local column = (i - 1) - line * perLine
    slot:ClearAllPoints()
    slot:SetPoint("TOPLEFT", detail.SlotRow, "TOPLEFT", column * step, -line * step)
  end

  detail.SlotRow:SetHeight(lines * step - M.tightGap)
  detail.SlotRow:Show()
end

-- The header is two stacked strings beside a fixed-size icon, so where the
-- metadata line starts is the taller of the two -- which no anchor can express.
-- Recomputed whenever the text or the width changes; the subject wraps, so its
-- height is a function of both.
local function LayoutDetailHeader(detail)
  local T = Th()
  local M = T.Metrics
  local headerHeight = (detail.Sender:GetStringHeight() or 0)
    + M.tightGap + (detail.Subject:GetStringHeight() or 0)
  detail.Info:ClearAllPoints()
  detail.Info:SetPoint("TOPLEFT", detail, "TOPLEFT", M.inset, -(M.inset + headerHeight + M.gap))
  detail.Info:SetPoint("RIGHT", detail, "RIGHT", -M.inset, 0)
end

local function LayoutDetail(detail)
  LayoutDetailActions(detail)
  LayoutDetailSlots(detail)
  LayoutDetailHeader(detail)
end

-- Forward declared: a refused take has to repaint the metadata line, and the
-- painter is defined further down beside the rest of the overlay's content.
local PaintDetailContent

-- The reading view across the C.O.D. its own tile pays. The overlay names its
-- mail by fingerprint, C.O.D. included, and the header reads the C.O.D. as 0
-- once the first take has paid it: a mail with several items is the same
-- mail afterwards, still holding the rest (RunPlan follows the same change
-- for Take all). A tile take on a C.O.D. the player has just confirmed is
-- armed before it is issued; a refresh that finds the mail reading as that
-- take's paid form leaves the overlay up until the take reports; the report
-- adopts the paid fingerprint, once, or the overlay closes as it always has.

-- detail, index, cod -> the tile take about to be issued, armed on the
-- overlay; nil where there is nothing to follow: no C.O.D., a take that
-- would empty the mail (one item, which goes as any emptied mail does), or a
-- channel another take owns (the click is answered "busy", nothing issued).
function RV.ArmPaidTake(detail, index, cod)
  if (tonumber(cod) or 0) <= 0 or Mail().IsBusy() then return nil end
  local _, _, sender, subject, money, _, _, itemCount = GetInboxHeaderInfo(index)
  if (tonumber(itemCount) or 0) < 2 and (tonumber(money) or 0) <= 0 then return nil end
  local take = { index = index, from = detail.fingerprint, paid = FingerprintOf(sender, subject, 0) }
  detail._paidTake = take
  return take
end

-- detail -> whether the overlay waits for its armed take to report: the mail
-- at its index reads as the take's paid form (same sender and subject,
-- nothing owed) and still holds something.
function RV.AwaitsPaidTake(detail)
  local take = detail._paidTake
  if not take or detail.fingerprint ~= take.from or detail.mailIndex ~= take.index then return false end
  if Fingerprint(take.index) ~= take.paid or not RV.HeldSomething(take.index) then return false end
  take.held = true
  return true
end

-- detail, take, landed -> whether the overlay now follows the paid mail. The
-- one place the paid form is adopted: the take landed, the overlay still
-- shows the mail it was confirmed on, and that mail is at its index, paid and
-- holding something. From then on the fingerprint reads nothing owed, so a
-- mail that owes a C.O.D. never matches it, and every take still goes through
-- ConfirmCOD. Anything else disarms, and an overlay held for this report is
-- checked now, as the refresh it waited through would have.
function RV.SettlePaidTake(detail, take, landed)
  if not take or detail._paidTake ~= take then return false end
  detail._paidTake = nil
  if landed and detail:IsShown() and detail.fingerprint == take.from
    and detail.mailIndex == take.index and Fingerprint(take.index) == take.paid
    and RV.HeldSomething(take.index) then
    detail.fingerprint = take.paid
    return true
  end
  if take.held then CloseDetailIfStale(detail._panel) end
  return false
end

-- Whether the click being handled is a modified one.
function RV.Modified()
  if type(IsModifiedClick) == "function" then return IsModifiedClick() and true or false end
  return (IsShiftKeyDown() or IsControlKeyDown() or IsAltKeyDown()) and true or false
end

-- A modified click on a mail's item tile is the game's item rules, as on
-- its own mail tiles: Shift links, Ctrl tries on (HandleModifiedItemClick),
-- and whatever it leaves is nothing, never the plain click's take. The link
-- where the body is not loaded yet is the item's own, by id. `slot` nil is
-- the gold tile, which has no item to link. True when a modifier was held.
function RV.ModifiedItemClick(index, slot)
  if not RV.Modified() then return false end
  if not slot or type(HandleModifiedItemClick) ~= "function" then return true end
  local link = GetInboxItemLink(index, slot)
  if not link then
    local _, itemID = GetInboxItem(index, slot)
    if itemID and C_Item and type(C_Item.GetItemInfo) == "function" then
      local _, generic = C_Item.GetItemInfo(itemID)
      link = generic
    end
  end
  if link then HandleModifiedItemClick(link) end
  return true
end

local function TakeOneAttachment(detail, slot)
  -- LiveIndex, not detail.mailIndex: a take is a command, and it may only be
  -- aimed at an index that still names the mail this overlay is showing.
  --
  -- The itemLink guard carries the case where no fetch landed. A mail's links
  -- are not loaded until its body is fetched, and the fetch declines while
  -- another sequence owns the command channel -- so in an overlay opened at that
  -- moment the slots show what the client knows and stay inert, rather than
  -- firing a take the service would answer "collected" to and blanking a slot
  -- whose item never moved.
  local index, slotIndex = LiveIndex(detail), slot.slotIndex
  if not index or not slotIndex then return end
  -- Shift- and Ctrl-click link and try on, as the fan's tiles do.
  if RV.ModifiedItemClick(index, slotIndex) then return end
  if not slot.itemLink then return end

  -- The FIRST take from a C.O.D. mail pays the whole amount, so the same
  -- confirmation the Collect button gets stands in front of a slot click too.
  -- For everything else ConfirmCOD calls straight through. Its accept
  -- re-verifies the mail's identity against the fingerprint read at the
  -- click; the take is aimed at that index and goes only while the overlay
  -- still shows that same mail there. The dialog is not modal, and the
  -- overlay can be turned to another mail under it (Back, another row), so
  -- what it shows after the wait is not the mail the player answered for.
  local clicked = detail.fingerprint
  ConfirmCOD(index, function()
    if not detail:IsShown() or detail.fingerprint ~= clicked or LiveIndex(detail) ~= index then return end
    local _, _, _, _, _, codBefore = GetInboxHeaderInfo(index)
    codBefore = tonumber(codBefore) or 0
    local paying = RV.ArmPaidTake(detail, index, codBefore)

    Mail().TakeAttachment(index, slotIndex, function(status, refused, reason)
      local followed = RV.SettlePaidTake(detail, paying, status == "collected")
      -- The slot is cleared only once the item has actually left the mailbox.
      -- Blanking it on a timeout, or on a take the server refused, would tell
      -- the player it was collected while it is still sitting there. It stays
      -- clickable, so a retry is their decision rather than an automatic one.
      if status == "busy" then return end
      if status == "closed" then
        StatusMailboxClosed()
        return
      end
      if status == "timeout" then
        ns.Print(L()["MSG_MAIL_TIMEOUT"])
        return
      end
      if status == "refused" or (tonumber(refused) or 0) > 0 then
        ns.Print(ItemRefusedMessage(reason))
        -- The domain has just recorded this mail as stuck, and the overlay is
        -- still the screen the player is looking at. Repainting puts the
        -- reason in the metadata line where the click was, instead of only in
        -- a chat message and on a row hidden behind this frame.
        PaintDetailContent(detail, index)
        LayoutDetail(detail)
        RefreshIdleSummary()
        return
      end

      -- A confirmed C.O.D. that was just paid: say so in the game's chat, in
      -- gold, where the player can check it against the bill -- once the
      -- mail no longer reads as owing it (RV.CODPaid), since "collected" is
      -- also the answer for a take that found nothing to take.
      if codBefore > 0 and RV.CODPaid(index, clicked) then
        ns.Print(L()("MSG_COD_PAID", Helpers().FormatMoney(codBefore)))
      end

      -- Taking one attachment can compact the others downwards, so never
      -- assume the slot is now empty: re-read it.
      local link = GetInboxItemLink(index, slotIndex)
      if link then
        local _, _, texture, count = GetInboxItem(index, slotIndex)
        if texture then slot.Icon:SetTexture(texture) end
        slot.Count:SetText((tonumber(count) or 0) > 1 and tostring(count) or "")
        RV.ShowMark(slot.Mark, slot.MarkShadow, RV.MarkOnIcon() and RV.AtlasOf(RV.MarkOf(link)) or nil)
        slot.itemLink = link
      else
        slot.Icon:Hide()
        slot.Count:SetText("")
        slot.itemLink = nil
        slot:Hide()
      end
      -- The same mail, paid: repainted as it reads now, with nothing owed.
      if followed then
        PaintDetailContent(detail, index)
        LayoutDetail(detail)
      end
      RequestRefresh(detail._panel)
    end, { allowCOD = true, history = detail._history })
  end)
end

local function BuildDetailSlot(detail, i)
  local T = Th()
  local slot = CreateFrame("Button", nil, detail.SlotRow, "BackdropTemplate")
  slot:SetSize(T.Metrics.slotSize, T.Metrics.slotSize)
  slot.slotIndex = i

  -- The native empty-slot art IS the look. Nothing opaque goes over it: the
  -- previous build laid this down, shaded it, then applied a full-alpha card
  -- surface above both, so the art was dead pixels.
  local art = slot:CreateTexture(nil, "BACKGROUND")
  art:SetAllPoints()
  art:SetTexture(EMPTY_SLOT_ART)
  art:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  slot.Icon = slot:CreateTexture(nil, "ARTWORK")
  slot.Icon:SetAllPoints()
  slot.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  slot.Icon:Hide()

  -- The item's quality mark and the count over it, by the icons' rules
  -- (RV.PlaceMark, RV.PlaceCount), on a frame over the slot, as a fan tile
  -- has them.
  local over = CreateFrame("Frame", nil, slot)
  over:SetAllPoints(slot)
  slot.Mark, slot.MarkShadow = RV.NewMark(over)
  RV.PlaceMark(slot.Mark, slot.MarkShadow, slot.Icon, T.Metrics.slotSize)
  slot.Count = T.CreateText(over, "numberSmall", "OVERLAY")
  slot.Count:SetDrawLayer("OVERLAY", 7)
  RV.PlaceCount(slot.Count, slot.Icon, T.Metrics.slotSize)

  -- The client's own square slot highlight, additively blended -- the same one
  -- the compose screen's attachment slots use, so the two grids of item slots
  -- hover identically. It was a flat 15% white wash: a colour this file chose
  -- for itself, and the last one in it.
  local highlight = slot:CreateTexture(nil, "HIGHLIGHT")
  highlight:SetAllPoints()
  highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
  highlight:SetBlendMode("ADD")

  -- The card border and nothing else: no fill, no grain, and NOT tagged as a
  -- themed panel -- an item slot is not a panel and both skins would paint over
  -- its art if it claimed to be one.
  T.ApplySlot(slot)

  -- SetInboxItem rather than SetHyperlink on the stored link: the link is nil
  -- until the mail's body has been fetched, so a link-based tooltip is dead on
  -- exactly the mails a preview exists for. Addressed by mail and slot, and the
  -- mail is re-verified on every hover -- indices slide down whenever a mail
  -- below this one is emptied.
  -- No "does this slot hold anything" guard: a slot is shown only while it does,
  -- and a hidden frame receives no OnEnter.
  slot:SetScript("OnEnter", function(self)
    local index = LiveIndex(detail)
    if not index then return end
    -- The hint line the fan's tiles carry: what the tile does beyond a click.
    if ShowAttachmentTooltip(self, index, self.slotIndex) then
      GameTooltip:AddLine(L()["FAN_TILE_HINT"], 0.7, 0.7, 0.7)
      GameTooltip:Show()
    end
  end)
  slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
  slot:SetScript("OnClick", function(self) TakeOneAttachment(detail, self) end)
  slot:Hide()

  return slot
end

local function HideDetail(panel)
  if panel.Detail then panel.Detail:Hide() end
end

-- The detail is addressed by inbox index, and an index stops naming its mail
-- the moment the mail is emptied. Rather than closing on every refresh -- which
-- used to need a timer, because reading a mail marks it read and refreshes the
-- list underneath the thing just opened -- the overlay closes only when its
-- mail has actually gone, or when a run is shifting indices wholesale. A tile
-- take paying the mail's C.O.D. is waited for (RV.AwaitsPaidTake).
function CloseDetailIfStale(panel)
  local detail = panel.Detail
  if not detail or not detail:IsShown() then return end
  if Run.active then
    detail:Hide()
    return
  end
  if not LiveIndex(detail) and not RV.AwaitsPaidTake(detail) then detail:Hide() end
end

-------------------------------------------------------------
-- The detail view :: the body
--
-- Opening a mail shows the mail, all of it, immediately. There is no longer a
-- "Show message" gate in front of the body of an unread one.
--
-- The gate was never about the text. GetInboxText fetches the body AND marks the
-- mail read, and while the screen's headline numbers counted the READ FLAG that
-- meant a peek silently moved a number the player was not looking at -- so the
-- cost had to be stated and consented to. The numbers count CONTENT now (see
-- "One taxonomy" at the top of this file): reading a mail moves nothing it was
-- not already true of, the row's unread dot goes out on the next refresh, and
-- that is the whole of the effect. Which is exactly how every mail client the
-- player has ever used behaves.
--
-- `_bodyFetched` survives, because it is not friction: Collect's `skipFetch` is
-- a claim that this mail's attachment links are already loaded, and only a fetch
-- that actually WENT OUT can make it. Mail().FetchMailBody declines while
-- another sequence owns the command channel, so the flag follows what happened
-- rather than what was intended.
-------------------------------------------------------------

-- The body area, showing whatever the fetch returned. nil is "no fetch went
-- out"; "" is "the mail genuinely has no text". Both read the same to the
-- player, and only the first leaves `skipFetch` unclaimable.
local function ShowBody(detail, text)
  detail._bodyFetched = (text ~= nil)
  detail.BodyText:SetText((text and text ~= "") and text or L()["DETAIL_NO_BODY"])
  detail.BodyChild:SetHeight(max(detail.BodyText:GetStringHeight() or 10, 10))
  detail.BodyScroll:SetVerticalScroll(0)
  detail.BodyScroll:Show()
end

-------------------------------------------------------------
-- The detail view :: its own ground
--
-- One mail, read on its own. Nothing behind it may show through -- not a row of
-- the list, not the segment captions it covers, not the totals banner. Two
-- separate things were letting them:
--
--   THE SURFACE FOLLOWED THE WINDOW'S OPACITY. The overlay is a card, and a
--   card is part of the window's surface -- which under a host-UI skin is
--   painted at whatever background opacity the user set, so at 70% the list
--   underneath was legible THROUGH the mail's own header. Theme's popup floor
--   exists for exactly this, but it is applied to cards that FLOAT (toplevel or
--   raised out of their parent's strata) and this one deliberately does not
--   float: it is a panel-sized overlay, not a dialog. So it lays its own ground.
--
--   THE LIST WAS STILL THERE. Even an all-but-opaque ground composites what is
--   under it, and a list of rows is high-contrast text. It is hidden outright
--   while the overlay is up -- which is both cheaper and more honest than
--   trimming the last few per cent of alpha out of a stack of frames.
--
-- The ground is a texture on a HOLDER FRAME one level below the overlay, and
-- that is not tidiness. A host skin's first act on one of our panels is to fade
-- every texture region the frame owns to alpha 0 so that its own art is what
-- shows (Core/Skin_EllesmereUI.lua, ShimFadeRegions); a region of a CHILD frame
-- is not a region of the overlay, so the sweep never reaches it, and a child one
-- level down draws beneath everything the skin then paints on top. Same
-- construction as Core/Theme.lua's popup floor, for the same reason.
-------------------------------------------------------------

-- Above the popup floor's 0.95: this one covers a dense list rather than a
-- couple of controls, and the last two per cent are the difference between "very
-- faint" and "not there".
local DETAIL_GROUND_ALPHA = 0.98

-- The host's own window fill where a skin publishes one, so the ground is the
-- colour that skin would have used rather than a Postbox grey under its art.
-- Re-resolved on every paint: EllesmereUI's baseline moves on a profile switch.
local function DetailGroundColor()
  local skin = ns.Skin
  if skin and type(skin.GetHostBaseline) == "function" then
    local ok, r, g, b = pcall(skin.GetHostBaseline)
    if ok and type(r) == "number" and type(g) == "number" and type(b) == "number" then
      return r, g, b
    end
  end
  local fill = Th().Colors.surface
  return fill[1], fill[2], fill[3]
end

local function PaintDetailGround(detail)
  local art = detail and detail.__pbGround
  if not art then return end
  local r, g, b = DetailGroundColor()
  art:SetColorTexture(r, g, b, DETAIL_GROUND_ALPHA)
  -- Region alpha and colour alpha MULTIPLY, so the line above is only half of
  -- it: anything that faded this region would otherwise survive the repaint.
  art:SetAlpha(1)
end

local function BuildDetailGround(detail)
  local level = tonumber((detail.GetFrameLevel and detail:GetFrameLevel())) or 1
  local holder = CreateFrame("Frame", nil, detail)
  holder:SetAllPoints(detail)
  holder:SetFrameLevel(max(0, level - 1))
  detail.__pbGroundHolder = holder

  detail.__pbGround = holder:CreateTexture(nil, "BACKGROUND", nil, -8)
  detail.__pbGround:SetAllPoints(holder)
  PaintDetailGround(detail)
end

local function BuildDetail(panel)
  local T = Th()
  local M = T.Metrics

  local detail = CreateFrame("Frame", nil, panel, "BackdropTemplate")
  -- Inset like the list it covers: the same margin the top row, the list
  -- area and the footer keep from the panel's edges, so the overlay is
  -- exactly as wide as the tabs above it rather than running to the window.
  detail:SetPoint("TOPLEFT", panel, "TOPLEFT", M.inset, -M.inset)
  detail:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -M.inset, M.inset)
  detail:SetFrameLevel(panel:GetFrameLevel() + 20)
  detail:EnableMouse(true)
  T.ApplyCard(detail)
  BuildDetailGround(detail)
  detail._panel = panel
  detail._shownActions = {}
  detail._infoParts = {}
  detail.Slots = {}

  -- Bottom band 1: the actions. Anchored to the panel's own bottom edge, so
  -- nothing created later can be drawn over them.
  detail.ActionRow = CreateFrame("Frame", nil, detail)
  detail.ActionRow:SetPoint("BOTTOMLEFT", detail, "BOTTOMLEFT", M.inset, M.inset)
  detail.ActionRow:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -M.inset, M.inset)
  detail.ActionRow:SetHeight(M.controlHeight)

  -- Bottom band 2: the attachments, above the actions and never overlapping.
  detail.SlotRow = CreateFrame("Frame", nil, detail)
  detail.SlotRow:SetPoint("BOTTOMLEFT", detail.ActionRow, "TOPLEFT", 0, M.gap)
  detail.SlotRow:SetPoint("BOTTOMRIGHT", detail.ActionRow, "TOPRIGHT", 0, M.gap)
  detail.SlotRow:SetHeight(M.slotSize)

  for i = 1, Mail().MAX_ATTACHMENTS do
    detail.Slots[i] = BuildDetailSlot(detail, i)
  end

  -- The coin tile: gold in a mail, shown where the items are and taken the
  -- way an item is. It used to be a number in the metadata line only, and
  -- a sale's proceeds read as a fact about the mail rather than as the
  -- thing there was to collect from it. First in the row, before any item.
  local money = CreateFrame("Button", nil, detail.SlotRow, "BackdropTemplate")
  money:SetSize(M.slotSize, M.slotSize)
  local moneyArt = money:CreateTexture(nil, "BACKGROUND")
  moneyArt:SetAllPoints()
  moneyArt:SetTexture(EMPTY_SLOT_ART)
  moneyArt:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  money.Icon = money:CreateTexture(nil, "ARTWORK")
  money.Icon:SetAllPoints()
  money.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  money.Icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
  money.Count = T.CreateText(money, "numberSmall", "OVERLAY")
  -- Where an item tile's count stands (RV.PlaceCount), as the fan's gold
  -- tile has it.
  RV.PlaceCount(money.Count, money.Icon, M.slotSize)
  local moneyHighlight = money:CreateTexture(nil, "HIGHLIGHT")
  moneyHighlight:SetAllPoints()
  moneyHighlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
  moneyHighlight:SetBlendMode("ADD")
  T.ApplySlot(money)
  money:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L()["LABEL_GOLD"] .. Helpers().FormatMoney(detail._money or 0), 1, 1, 1)
    GameTooltip:Show()
  end)
  money:SetScript("OnLeave", function() GameTooltip:Hide() end)
  money:SetScript("OnClick", function()
    local index = LiveIndex(detail)
    if not index then return end
    -- A modified click is never the plain click's take, as on the item tiles
    -- beside it and the fan's coin; with no item to link, it does nothing.
    if RV.ModifiedItemClick(index, nil) then return end
    Mail().TakeMoney(index, function(status)
      if status == "busy" then return end
      if status == "closed" then
        StatusMailboxClosed()
        return
      end
      if status == "timeout" then
        ns.Print(L()["MSG_MAIL_TIMEOUT"])
        return
      end
      -- Re-read rather than assumed: the header says whether the gold went.
      local live = LiveIndex(detail)
      if live then
        PaintDetailContent(detail, live)
        LayoutDetail(detail)
      end
      RequestRefresh(panel)
    end, detail._history)
  end)
  money:Hide()
  detail.MoneySlot = money

  for i = 1, #DETAIL_ACTIONS do
    detail[DETAIL_ACTIONS[i]] = T.CreateButton(nil, detail.ActionRow)
  end
  detail.Back:SetText(L()["BTN_BACK"])
  detail.Collect:SetText(L()["BTN_TAKE_ALL"])
  detail.Reply:SetText(L()["BTN_REPLY"])
  detail.Return:SetText(L()["BTN_RETURN"])
  detail.Delete:SetText(DeleteLabel())

  -- Back on a letter that is finished with -- read, and nothing left in it --
  -- deletes it in the "delete" read-mail mode; History keeps what it said.
  -- Back only: Escape and the tab switching away also hide this, and neither
  -- is a player saying they are done with the letter. And only a letter
  -- History holds from this reading -- read here for the first time, or
  -- emptied here -- which is also what makes "History keeps what it said"
  -- true. An old letter opened again stays under the divider until the
  -- player clears it, as the option's description promises.
  detail.Back:SetScript("OnClick", function()
    local index = LiveIndex(detail)
    detail:Hide()
    local record = detail._history
    if index and record and record.entry then
      RV.AutoDelete(panel, index, RV.Before(index), record)
    end
  end)

  detail.Collect:SetScript("OnClick", function()
    local index = LiveIndex(detail)
    if not index then return end
    detail:Hide()
    -- skipFetch is a claim that this mail's attachment links are already loaded,
    -- and only a fetch that actually went out can make it. Opening the overlay
    -- asks for one, but the service declines while another sequence owns the
    -- command channel -- so the flag follows what happened rather than what was
    -- asked for. MailService re-checks it anyway; a caller should still not be
    -- asserting something it does not know.
    CollectSingleMail(panel, index, {
      skipFetch = detail._bodyFetched and true or false,
      history = detail._history,
    })
  end)

  detail.Reply:SetScript("OnClick", function()
    -- Verified like the rest: this reads a sender off an index, and addressing a
    -- reply to whoever slid into that slot is the one way this button can be
    -- quietly wrong.
    local index = LiveIndex(detail)
    if not index then return end
    local _, _, sender = GetInboxHeaderInfo(index)
    detail:Hide()
    CT.RequestReply(sender, detail.Subject:GetText() or "")
  end)

  detail.Return:SetScript("OnClick", function()
    -- Verified: returning a mail is irreversible and reindexes the inbox, so it
    -- may only ever be aimed at an index that still names this mail.
    local index = LiveIndex(detail)
    if not index then return end
    local fingerprint = detail.fingerprint
    detail:Hide()
    -- Checked again right before the command goes (Mail.ReturnMail).
    Mail().ReturnMail(index, function(status)
      if status == "closed" then
        StatusMailboxClosed()
      elseif status == "timeout" then
        ns.Print(L()["MSG_MAIL_TIMEOUT"])
      end
      RequestRefresh(panel)
    end, fingerprint)
  end)

  detail.Delete:SetScript("OnClick", function()
    local index = LiveIndex(detail)
    if not index then return end
    local fingerprint = detail.fingerprint
    -- Delete is offered on read mail, and a read mail can still hold items when
    -- the bags filled mid-run. Deleting that loses them, so it confirms -- in
    -- the client's own words where it has them.
    if Mail().HasContent(index) then
      -- The client's own wording where it has one -- it is already translated
      -- for every locale and says exactly the right thing.
      local native = _G["DELETE_MAIL_CONFIRMATION"]
      local message = (type(native) == "string" and native ~= "" and native)
        or RawKey("CONFIRM_DELETE_MAIL")
        or DeleteLabel()
      Confirm(POPUP_DELETE_ONE, DeleteLabel(), L()["COD_CONFIRM_CANCEL"],
        message, function()
          -- The mail the question was about, by the index and fingerprint
          -- read at the click, never whatever the overlay shows now: it can
          -- be turned to another mail while the dialog stands. The inbox can
          -- reindex between the question and the answer too, and this is the
          -- irreversible one, so the service checks the index once more
          -- right before the command (DeleteOneMail).
          if detail.mailIndex == index and detail.fingerprint == fingerprint then detail:Hide() end
          DeleteOneMail(panel, index, fingerprint)
        end)
      return
    end
    detail:Hide()
    DeleteOneMail(panel, index, fingerprint)
  end)

  -- Header: sender, subject, then the metadata line, flush with the panel's
  -- left edge. There used to be a 36px icon box at the top-left with the
  -- text hanging off its right; the same icon sits in the attachment row
  -- below, so up here it was a square of nothing that looked like a slot
  -- waiting for an item.
  detail.Sender = T.CreateText(detail, "heading")
  detail.Sender:SetPoint("TOPLEFT", detail, "TOPLEFT", M.inset, -M.inset)
  detail.Sender:SetPoint("RIGHT", detail, "RIGHT", -M.inset, 0)
  detail.Sender:SetJustifyH("LEFT")
  detail.Sender:SetWordWrap(false)

  -- The full panel width. It used to stop 148px short, pinned to the left edge
  -- of a button sitting 22px higher that could not have collided with it, so a
  -- long auction subject wrapped into the metadata line below.
  detail.Subject = T.CreateText(detail, "body")
  detail.Subject:SetPoint("TOPLEFT", detail.Sender, "BOTTOMLEFT", 0, -M.tightGap)
  detail.Subject:SetPoint("RIGHT", detail, "RIGHT", -M.inset, 0)
  detail.Subject:SetJustifyH("LEFT")
  detail.Subject:SetWordWrap(true)

  detail.Info = T.CreateText(detail, "secondary")
  detail.Info:SetJustifyH("LEFT")
  detail.Info:SetWordWrap(true)

  -- Body, between the header and the two bottom bands, on its own surface:
  -- the list surface the mail rows sit on, so the message reads as content
  -- inside the card and the header as the card's own chrome. The scroll
  -- frame sits inside it with the rows' padding, and its bar is pinned to
  -- the surface's edge and hidden until the text needs it.
  detail.BodyCard = CreateFrame("Frame", nil, detail, "BackdropTemplate")
  detail.BodyCard:SetPoint("TOPLEFT", detail.Info, "BOTTOMLEFT", 0, -M.gap)
  detail.BodyCard:SetPoint("RIGHT", detail, "RIGHT", -M.inset, 0)
  detail.BodyCard:SetPoint("BOTTOM", detail.SlotRow, "TOP", 0, M.gap)
  T.ApplyList(detail.BodyCard)

  detail.BodyScroll = CreateFrame("ScrollFrame", nil, detail.BodyCard, "UIPanelScrollFrameTemplate")
  detail.BodyScroll:SetPoint("TOPLEFT", detail.BodyCard, "TOPLEFT", M.gap, -M.gap)
  detail.BodyScroll:SetPoint("BOTTOMRIGHT", detail.BodyCard, "BOTTOMRIGHT", -M.scrollGutter, M.gap)
  PinScrollBar(detail.BodyScroll, detail.BodyCard)

  detail.BodyChild = CreateFrame("Frame", nil, detail.BodyScroll)
  detail.BodyChild:SetSize(FALLBACK_PANEL_WIDTH, 10)
  detail.BodyScroll:SetScrollChild(detail.BodyChild)

  detail.BodyText = T.CreateText(detail.BodyChild, "bodySmall")
  detail.BodyText:SetPoint("TOPLEFT", detail.BodyChild, "TOPLEFT", 0, 0)
  detail.BodyText:SetJustifyH("LEFT")
  detail.BodyText:SetWordWrap(true)
  detail.BodyText:SetWidth(FALLBACK_PANEL_WIDTH)

  detail.BodyScroll:HookScript("OnSizeChanged", function(_, width)
    if not width or width <= 10 then return end
    detail.BodyChild:SetWidth(width)
    detail.BodyText:SetWidth(width)
    detail.BodyChild:SetHeight(max(detail.BodyText:GetStringHeight() or 10, 10))
  end)

  detail:SetScript("OnSizeChanged", function(self) LayoutDetail(self) end)

  -- The list goes away while one mail is being read, and comes back whichever
  -- way the overlay closed -- Back, Collect, Return, Delete, a stale index, a
  -- run starting, or the whole panel being hidden underneath it. Driven from the
  -- overlay's own visibility rather than from each of those call sites, because
  -- there are seven of them and a missed one would leave the screen empty.
  --
  -- The refresh running underneath is unaffected: CT.RefreshMailList gates on
  -- the PANEL being shown, not the list container, and a hidden frame keeps its
  -- rect -- so the virtualiser's viewport maths, the scroll clamp and the row
  -- binds all still produce the list that is waiting when it reappears.
  detail:SetScript("OnShow", function(self)
    PaintDetailGround(self)
    panel.MailListArea:Hide()
  end)
  detail:SetScript("OnHide", function() panel.MailListArea:Show() end)
  detail:Hide()

  panel.Detail = detail
end

-- Builds the metadata line. One pass, one table, reused: this is the densest
-- string in the addon and it is rebuilt whenever the overlay opens.
local function DetailInfoText(detail, index, kind, hasCOD)
  local T = Th()
  local fmt = Helpers().FormatMoney
  local labels = Labels()
  local _, _, _, _, money, cod, daysLeft, itemCount, wasRead, wasReturned = GetInboxHeaderInfo(index)

  local parts = detail._infoParts
  Clear(parts)

  local moneyValue = tonumber(money) or 0
  local codValue = tonumber(cod) or 0
  if moneyValue > 0 then parts[#parts + 1] = L()["LABEL_GOLD"] .. fmt(moneyValue) end
  if hasCOD and codValue > 0 then
    parts[#parts + 1] = T.Colorize("negative", L()["LABEL_COD"] .. fmt(codValue))
  end
  parts[#parts + 1] = labels[kind] or kind
  itemCount = tonumber(itemCount) or 0
  if itemCount > 0 then parts[#parts + 1] = ns.Plural("COUNT_ITEMS", itemCount) end
  parts[#parts + 1] = wasRead and L()["STATUS_READ"] or L()["STATUS_UNREAD"]
  if wasReturned then parts[#parts + 1] = L()["STATUS_RETURNED"] end
  if daysLeft then parts[#parts + 1] = Helpers().ExpiresIn(daysLeft) end

  AppendInvoiceFigures(parts, index, true)

  -- Last, and in the warning tone: everything above describes what the mail IS,
  -- and this says why it is still here. The line wraps, so a long quotation from
  -- the server pushes the body down rather than being cut off -- which is the
  -- right trade for the one sentence that explains the whole screen.
  local stuckReason = Mail().StuckReason(index)
  if stuckReason then
    parts[#parts + 1] = T.Colorize("warning", StuckLine(stuckReason))
  end

  return concat(parts, "  |  ")
end

-- Everything the overlay shows EXCEPT the body, from data the client already
-- holds. Split out because it has two callers: opening the overlay -- where it
-- runs AFTER the body fetch, which is what makes the read status, the icon and
-- the attachment links it reads the current ones -- and a refused take, which
-- has to put the reason in the metadata line under the click that produced it.
function PaintDetailContent(detail, index)
  local _, _, sender, subject, money, cod, _, itemCount, wasRead = GetInboxHeaderInfo(index)
  local kind, hasCOD = Mail().ClassifyMail(index)
  local codValue = tonumber(cod) or 0
  local isCOD = hasCOD and codValue > 0
  local hasContent = (tonumber(money) or 0) > 0 or (tonumber(itemCount) or 0) > 0

  detail.Sender:SetText(sender or L()["SENDER_UNKNOWN"])
  RV.PaintSender(detail.Sender, sender, nil, "heading")
  detail.Subject:SetText(Helpers().ShortSubject(subject or ""))
  detail.Info:SetText(DetailInfoText(detail, index, kind, hasCOD))

  -- Reply exists to hand a C.O.D. mail back. Return is offered wherever the
  -- client would offer it in place of Delete: a mail from a player that still
  -- holds something -- the client's InboxItemCanDelete answers false for
  -- exactly those, and its own OpenMail frame swaps its Delete button for
  -- Return on the same test. Once a mail has been emptied there is nothing to
  -- return, and a system mail (auction house, quest reward) cannot be. Delete
  -- is never offered on a C.O.D. mail, nor on one the client says to return.
  local canDelete = true
  if type(InboxItemCanDelete) == "function" then
    local ok, answer = pcall(InboxItemCanDelete, index)
    if ok then canDelete = answer and true or false end
  end
  detail.Reply:SetShown(isCOD and hasContent)
  detail.Return:SetShown(hasContent and (isCOD or not canDelete))
  detail.Delete:SetShown(wasRead and not isCOD and canDelete)

  local shownSlots = 0
  local marks = RV.MarkOnIcon()
  for i = 1, Mail().MAX_ATTACHMENTS do
    local slot = detail.Slots[i]
    local _, _, texture, count = GetInboxItem(index, i)
    if texture then
      shownSlots = i
      slot.Icon:SetTexture(texture)
      slot.Icon:Show()
      slot.Count:SetText((tonumber(count) or 0) > 1 and tostring(count) or "")
      RV.ShowMark(slot.Mark, slot.MarkShadow, marks and RV.AtlasOf(RV.QualityMark(index, i)) or nil)
      -- nil where no fetch has landed for this mail -- the channel was busy when
      -- the overlay opened. The slot still shows the item and still raises its
      -- tooltip (SetInboxItem needs no link); what the link decides is whether
      -- clicking it can take anything -- see TakeOneAttachment.
      slot.itemLink = GetInboxItemLink(index, i)
      slot:Show()
    else
      slot.Icon:Hide()
      slot.Count:SetText("")
      slot.itemLink = nil
      slot:Hide()
    end
  end
  detail._slotCount = shownSlots

  -- The coin tile, with the amount's leading denomination on it ("25g");
  -- the whole sum is in its tooltip and in the metadata line above.
  local moneyValue = tonumber(money) or 0
  detail._money = moneyValue
  if detail.MoneySlot then
    if moneyValue > 0 then
      local text = Helpers().FormatMoney(moneyValue)
      detail.MoneySlot.Count:SetText(text:match("^%S+") or text)
      detail.MoneySlot:Show()
    else
      detail.MoneySlot:Hide()
    end
  end
end

function ShowDetail(panel, index)
  local detail = panel.Detail
  if not detail then return end

  local fingerprint = Fingerprint(index)
  if not fingerprint then return end
  -- The reading view covers the list, and the fan with it.
  RV.FanClose(true)

  detail.mailIndex = index
  detail.fingerprint = fingerprint

  -- Read BEFORE the fetch, because the fetch is what changes it, and it is the
  -- one thing that decides whether the list underneath needs rebuilding at all.
  local _, _, _, _, _, _, _, _, wasRead = GetInboxHeaderInfo(index)

  -- THE BODY FIRST, and everything else painted from what the fetch left behind.
  -- The fetch marks the mail read, loads its attachment links and can turn a
  -- generic package icon into the first attachment's own art -- so a paint taken
  -- before it would say "Unread" beside a mail that no longer is, and leave every
  -- slot inert (TakeOneAttachment needs the link). Run.active is re-checked here
  -- rather than trusted to the row gate, because this is where the command would
  -- actually be issued, and a fetch mid-run would be read by the run's own
  -- sequence as its acknowledgement.
  -- One History record for this mail, however many separate takes follow
  -- from here: the coin, each tile, Take all. Taken before the fetch, while
  -- the header still says what arrived.
  detail._history = Mail().HistoryRecord and Mail().HistoryRecord(index) or nil
  local body = (not Run.active) and Mail().FetchMailBody(index) or nil
  if detail._history and type(body) == "string" and body ~= "" then detail._history.body = body end
  ShowBody(detail, body)
  PaintDetailContent(detail, index)

  LayoutDetail(detail)
  detail:Show()

  -- Opening an unread mail read it, so the row this came from is now wrong: its
  -- unread dot, and -- for a mail that held nothing else -- which of the two
  -- views it belongs in. Nothing changed for a mail that was already read, and a
  -- rebuild of a list currently hidden behind this overlay is not free.
  --
  -- Coalesced, and it cannot close the overlay: the fingerprint is sender +
  -- subject + C.O.D., none of which reading alters.
  if not wasRead then
    -- A letter with nothing to take is "collected" by reading it: History
    -- lists it, so the record is every mail dealt with, not only the ones
    -- that held something. Only when the fetch went out -- a declined fetch
    -- read nothing, and the letter is still unread.
    local _, _, _, _, money, _, _, items = GetInboxHeaderInfo(index)
    if body ~= nil and (tonumber(money) or 0) == 0 and (tonumber(items) or 0) == 0 and Mail().HistoryNote then
      Mail().HistoryNote(detail._history, "read")
    end
    RequestRefresh(panel)
  end
end

-------------------------------------------------------------
-- Reply
--
-- The compose screen owns its own fields. Ask it to prepare a reply where it
-- offers an entry point, and fall back to writing the boxes directly where it
-- does not.
-------------------------------------------------------------

function CT.RequestReply(recipient, originalSubject)
  local UI = ns.MailboxUI
  if not UI or not UI._frame then return end

  local prefix = RawKey("REPLY_PREFIX")
  local subject
  if originalSubject and originalSubject ~= "" then
    subject = prefix and format(prefix, originalSubject) or ("Re: " .. originalSubject)
  else
    subject = L()["DEFAULT_SUBJECT"]
  end

  if type(UI.SelectTab) == "function" then UI.SelectTab("send") end

  local Send = ns.SendTab
  if Send and type(Send.PrepareReply) == "function" then
    Send.PrepareReply(recipient, subject)
    return
  end

  local panel = UI._frame.Tabs and UI._frame.Tabs.send
  if not panel or not panel.ToBox then return end
  panel.ToBox:SetText(recipient or "")
  panel.ToBox:SetCursorPosition(0)
  if panel.SubjectBox then
    panel.SubjectBox:SetText(subject)
    panel.SubjectBox:SetCursorPosition(0)
  end
  if panel.BodyBox then
    panel.BodyBox:SetText(L()["DEFAULT_BODY"])
    panel.BodyBox:SetCursorPosition(0)
  end
end

-------------------------------------------------------------
-- The category grid
--
-- The full-width primary, then the sweeps tiling in rows of three: six of
-- them as the grid comes (two rows), and a character group's own button for
-- each group the player has made (ns.CharacterGroups.GridButtons), wrapping
-- onto as many rows as they need. Which sweeps show and in what order is the
-- player's (MailboxUI.GetGridLayout), arranged in the arrange mode; the
-- primary is not part of it -- it is the one button that takes everything,
-- and it always stands first. Column edges are derived from the usable width
-- so the right-hand column lands exactly on the grid edge -- flooring one
-- button width instead discards up to a pixel per column and the right
-- margin visibly shifts as the window resizes.
-------------------------------------------------------------

-- The built-in sweeps, in the grid's own order: CATEGORY_ORDER after "all".
function RV.BuiltinGridIds()
  local out = {}
  for i = 2, #CATEGORY_ORDER do out[#out + 1] = CATEGORY_ORDER[i] end
  return out
end

-- The character groups' buttons, or nil when there is no groups module to
-- ask. Their failure must not take the grid with it: it is reported, and
-- the grid stands without them.
function RV.GroupSpecs(panel)
  local groups = ns.CharacterGroups
  if not (groups and type(groups.GridButtons) == "function") then return nil end
  local ok, specs = pcall(groups.GridButtons, panel)
  if not ok then
    if type(geterrorhandler) == "function" then geterrorhandler()(specs) end
    return nil
  end
  return type(specs) == "table" and specs or {}
end

-- stored, available, known [, keep] -> the grid's entries { {id=, shown=},
-- ... } and whether the stored list named a button that no longer exists.
-- The stored order first, for the ids that exist; then every id it has never
-- seen, at the end and shown, in the order `available` gives them. A group's
-- id can only be judged gone when the groups module answered (`known`);
-- until then it is kept for later rather than forgotten. `keep(id)`, where
-- given, names an id the grid cannot draw now that is not gone either -- an
-- empty group's, whose button comes back with its first member.
function RV.ReconcileGrid(stored, available, known, keep)
  local isAvailable, seen, out = {}, {}, {}
  for i = 1, #available do isAvailable[available[i]] = true end
  local stale = false
  for i = 1, #(stored or {}) do
    local entry = stored[i]
    local id = type(entry) == "table" and entry.id or nil
    if id ~= nil and isAvailable[id] and not seen[id] then
      seen[id] = true
      out[#out + 1] = { id = id, shown = entry.shown ~= false }
    elseif id ~= nil and not isAvailable[id] then
      if (known or not (type(id) == "string" and id:sub(1, 6) == "group:")) and not (keep and keep(id)) then
        stale = true
      end
    end
  end
  for i = 1, #available do
    local id = available[i]
    if not seen[id] then out[#out + 1] = { id = id, shown = true } end
  end
  return out, stale
end

-- The grid's entries now: the built-ins, the groups' buttons, and the
-- player's arrangement of them. Kept on the panel for the layout passes a
-- resize makes; read afresh on every refresh. A button the stored list names
-- that is gone for good is forgotten there too; an empty group's is not
-- gone (RV.KeepGone), and a deleted group's is forgotten by the deletion
-- itself (CharacterGroups, CG.Delete), whichever tab is open.
--
-- Read afresh, but not rebuilt when nothing it is built from has moved: the
-- same stored arrangement (MailboxUI hands back the same table while the
-- saved string is the same), the same ids in the same order, the groups
-- module answering or not as before, and the list on the panel still the
-- one made here. Then the entries made last time are the answer; they are
-- never edited in place (the arrange mode copies them, RV.CopyEntries, and
-- stores a new list, RV.StoreGrid), so they are still exactly what
-- reconciling again would give. The ids go into one list kept on the panel,
-- noting as they are written whether any differs from last time.
function RV.GridEntries(panel)
  local specs = RV.GroupSpecs(panel)
  local available = panel._gridAvailable or {}
  panel._gridAvailable = available
  local before, n, changed = #available, 0, false
  for i = 2, #CATEGORY_ORDER do
    n = n + 1
    if available[n] ~= CATEGORY_ORDER[i] then available[n] = CATEGORY_ORDER[i]; changed = true end
  end
  local bySpec = panel._gridSpecs or {}
  panel._gridSpecs = bySpec
  for id in pairs(bySpec) do bySpec[id] = nil end
  if specs then
    -- An id is one button: a group's that repeats another's, or a
    -- built-in's, is not a second one. The groups' ids taken so far are
    -- bySpec's keys; the built-ins' are the first `builtins` of the list.
    local builtins = n
    for i = 1, #specs do
      local spec = specs[i]
      local id = type(spec) == "table" and spec.id or nil
      local taken = type(id) ~= "string" or id == "" or bySpec[id] ~= nil
      for k = 1, builtins do
        if taken then break end
        if available[k] == id then taken = true end
      end
      if not taken then
        bySpec[id] = spec
        n = n + 1
        if available[n] ~= id then available[n] = id; changed = true end
      end
    end
  end
  for i = before, n + 1, -1 do available[i] = nil end
  if before ~= n then changed = true end

  local UI = ns.MailboxUI
  local stored = UI and type(UI.GetGridLayout) == "function" and UI.GetGridLayout() or {}
  local known = specs ~= nil
  local last = panel._gridLast
  if last and not changed and last.stored == stored and last.known == known
      and last.entries == panel._gridEntries then
    return last.entries
  end
  local groups = ns.CharacterGroups
  local keep = groups and type(groups.Exists) == "function" and groups.Exists or nil
  local entries, stale = RV.ReconcileGrid(stored, available, known, keep)
  if stale and known and UI and UI.SetGridLayout then UI.SetGridLayout(RV.KeepGone(entries)) end
  panel._gridEntries = entries
  last = last or {}
  panel._gridLast = last
  last.stored, last.known, last.entries = stored, known, entries
  return entries
end

-- How many sweeps the grid shows outside the arrange mode. Without a panel
-- (the window's floor is asked for before the grid exists), from the stored
-- arrangement and the built-ins alone; the first refresh corrects it.
function RV.GridShownCount(panel)
  local entries = panel and panel._gridEntries
  if not entries then
    local UI = ns.MailboxUI
    local stored = UI and type(UI.GetGridLayout) == "function" and UI.GetGridLayout() or {}
    entries = RV.ReconcileGrid(stored, RV.BuiltinGridIds(), false)
  end
  local n = 0
  for i = 1, #entries do
    if entries[i].shown then n = n + 1 end
  end
  return n
end

-- Rows of sweeps on screen: every button while arranging, the shown ones
-- otherwise, none with the option off.
function RV.GridRows(panel)
  if not ShowCategoryButtons() then return 0 end
  local n = RV.GridShownCount(panel)
  if panel and panel._gridArranging and panel._gridEntries then n = #panel._gridEntries end
  return ceil(n / GRID_COLUMNS)
end

-- The rows the window's floor is taken at (CT.MinPanelHeight), remembered so
-- the grid can tell when a hidden button or a new group has moved it.
function RV.FloorGridRows()
  local UI = ns.MailboxUI
  local frame = UI and UI._frame
  local panel = frame and frame.Tabs and frame.Tabs.collect
  local rows = ceil(RV.GridShownCount(panel) / GRID_COLUMNS)
  RV._floorRows = rows
  return rows
end

-- While rows are picked, what each button would collect of them: the rules
-- a run over the picks applies (MailService's BuildQueueFor, picked) --
-- nothing finished, no C.O.D., stuck or not -- counted by kind, as the list
-- walk counts (From alts and Other split what is not auction mail), and by
-- sender, for the groups. One pass over the picks, into tables kept on the
-- panel, again only when the selection or the list has changed since.
function RV.SelectionCounts(panel)
  local sc = panel._selCounts
  if not sc then
    sc = { senders = {} }
    panel._selCounts = sc
  end
  if sc.gen == panel._selGen and sc.pass == panel._measurePass then return sc end
  local senders = sc.senders
  for key in pairs(senders) do senders[key] = nil end
  for key in pairs(sc) do
    if key ~= "senders" then sc[key] = nil end
  end
  local M = Mail()
  local altKeys = M.OwnCharacterKeys()
  for index in pairs(panel._selected or senders) do
    if M.HeaderLoaded(index) and not M.IsReadPersistent(index) then
      local kind, hasCOD = M.ClassifyMail(index)
      if not hasCOD then
        sc.all = (sc.all or 0) + 1
        if M.FromOwnCharacter(index, altKeys) then
          sc.alts = (sc.alts or 0) + 1
          if kind ~= "other" then sc[kind] = (sc[kind] or 0) + 1 end
        else
          sc[kind] = (sc[kind] or 0) + 1
        end
        local key = M.SenderKey(index)
        if key then senders[key] = (senders[key] or 0) + 1 end
      end
    end
  end
  sc.gen, sc.pass = panel._selGen, panel._measurePass
  return sc
end

-- What a sweep would collect: the walk's own count for a built-in, the
-- group's answer for a group's button -- and while rows are picked, what
-- it would collect of them (RV.SelectionCounts): a button with none of
-- them greys as an empty one does.
function RV.GridCount(panel, id)
  if Selecting(panel) then
    local sc = RV.SelectionCounts(panel)
    local set = Mail().SenderSet(id)
    if not set then return sc[id] or 0 end
    local n = 0
    for key in pairs(set) do n = n + (sc.senders[key] or 0) end
    return n
  end
  local spec = panel._gridSpecs[id]
  if spec then
    if type(spec.count) ~= "function" then return 0 end
    local ok, n = pcall(spec.count, panel)
    return (ok and tonumber(n)) or 0
  end
  return (panel._catCounts or {})[id] or 0
end

-- A sweep's click: its run, or the group's own collect.
function RV.GridClick(panel, id)
  if panel._gridArranging then return end
  local spec = panel._gridSpecs[id]
  if spec then
    if CT.IsRunning() then return end
    if type(spec.collect) == "function" then
      local ok, err = pcall(spec.collect, panel)
      if not ok and type(geterrorhandler) == "function" then geterrorhandler()(err) end
    end
    return
  end
  StartCategoryRun(panel, id)
end

-- A sweep's right-click: the groups window beside the Postbox window, on
-- this group for a group's button, on the one it last showed for From alts.
-- Nothing for the other sweeps, and nothing while arranging, where a click
-- in the grid means the arrangement.
function RV.GridEdit(panel, id)
  if panel._gridArranging then return end
  if not (panel._gridSpecs[id] or id == "alts") then return end
  local groups = ns.CharacterGroups
  if not (groups and type(groups.OpenEditor) == "function") then return end
  local UI = ns.MailboxUI
  local ok, err = pcall(groups.OpenEditor, id ~= "alts" and id or nil, UI and UI._frame)
  if not ok and type(geterrorhandler) == "function" then geterrorhandler()(err) end
end

-- index [, picked] -> the attachments a sweep would take from this mail: its
-- header's count, or 0 for a mail no sweep takes -- not arrived, C.O.D., or
-- held back (stuck, or waiting for bag room). The player's picks are taken
-- held back or not, as their run takes them.
function RV.RoomItems(index, picked)
  local _, _, sender, subject, _, cod, _, itemCount = GetInboxHeaderInfo(index)
  if sender == nil and subject == nil then return 0 end
  if (tonumber(cod) or 0) > 0 then return 0 end
  local n = tonumber(itemCount) or 0
  if n > 0 and not picked and Mail().HeldBack(index, n) then return 0 end
  return n
end

-- All mail's own line: whether what it would collect fits the bags -- "Up to
-- 23 items · 12 bag slots free", in the warning colour when the items are
-- more than the slots. "Up to", because the header counts attachments and a
-- stack that joins one already in the bags needs no slot of its own. The
-- mails are the ones its count is of: the picked rows under a selection,
-- otherwise the unfinished rows the list walk kept (panel._filtered, the
-- whole inbox when nothing narrows it) -- one header read each, only while
-- the tooltip is up, and nothing kept but the lines themselves. The slots are
-- the general bags' (MailService.FreeBagSlots: backpack and bag slots), the
-- room every attachment can use; a reagent bag with room says so on a line
-- of its own, since only reagents can go there.
-- The reagent bag's room as the bags-full messages add it after the
-- general slots: " (+10 in the reagent bag, for reagents only)", or "".
function RV.ReagentExtra(reagent)
  if (tonumber(reagent) or 0) <= 0 then return "" end
  return L()("BAGS_REAGENT_EXTRA", reagent)
end

-- "Keep bag slots free" (Options, Mail tab): the general bag slots a collect
-- run leaves free, 0 when it leaves none.
function RV.KeepFreeSlots()
  local UI = ns.MailboxUI
  local n = UI and type(UI.GetKeepFreeSlots) == "function" and UI.GetKeepFreeSlots() or 0
  return tonumber(n) or 0
end

-- The general slots a run may fill: the free ones less those it keeps free.
-- " (+2 kept free)", or "", for the messages that quote the room.
function RV.KeptExtra(free, keep)
  if keep <= 0 or (tonumber(free) or 0) <= 0 then return "" end
  return L()("BAGS_KEPT_EXTRA", math.min(keep, free))
end

function RV.AllMailRoom(panel, tooltip)
  local M = Mail()
  local free, reagent = M.FreeBagSlots()
  if not free then return end
  -- A run keeping slots free fills only the rest, so the warning compares
  -- the items with those; the line under it says how many are kept.
  local keep = RV.KeepFreeSlots()
  local usable = math.max(0, free - keep)
  local items = 0
  if Selecting(panel) and panel._selected then
    for index in pairs(panel._selected) do items = items + RV.RoomItems(index, true) end
  else
    -- Under the stuck filter the rows are retried as picks would be. A list
    -- of samples (Preview mail) holds no mail to ask about.
    local list, done, retry = panel._filtered, panel._filteredDone, StuckOnly(panel)
    if panel._preview then list = RV.NONE end
    for i = 1, #list do
      if done[i] == false and type(list[i]) == "number" then items = items + RV.RoomItems(list[i], retry) end
    end
  end
  local text = ns.Plural("ROOM_FREE", free)
  if items > 0 then text = ns.Plural("ROOM_ITEMS", items) .. " \194\183 " .. text end
  local warn = items > usable and Th().Colors and Th().Colors.warning
  if warn then
    tooltip:AddLine(text, warn[1], warn[2], warn[3], true)
  else
    tooltip:AddLine(text, 1, 1, 1, true)
  end
  if keep > 0 then tooltip:AddLine(ns.Plural("ROOM_KEPT", keep), 0.7, 0.7, 0.7, true) end
  if (reagent or 0) > 0 then tooltip:AddLine(ns.Plural("ROOM_REAGENT", reagent), 0.7, 0.7, 0.7, true) end
  -- While the bags are full the mails with items wait, and the count above
  -- is only what needs no room: say why.
  if M.BagsFull and M.BagsFull() then tooltip:AddLine(L()["BAGS_FULL_TIP"], 0.7, 0.7, 0.7, true) end
end

-- The tooltip a sweep says: a group's own, the two sweeps whose names do
-- not say exactly what they cover, or the whole of a cut caption; All mail
-- adds the bag room its sweep needs (RV.AllMailRoom). In the arrange mode
-- the pointer never reaches a button: each wears a card that takes it and
-- says the mode's own (RV.HandleTip), and the primary is under the All mail
-- block's card.
function RV.GridTip(panel, button)
  local spec = panel._gridSpecs[button.gridId]
  local plain = not (spec and type(spec.tooltip) == "function") and not button.tip
    and button.gridId ~= "all"
  if plain and not button.__pbOverflowText then return end
  GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
  GameTooltip:ClearLines()
  if spec and type(spec.tooltip) == "function" then
    local ok = pcall(spec.tooltip, GameTooltip)
    if not ok then GameTooltip:SetText(button.caption or "") end
  elseif button.tip then
    GameTooltip:SetText(button.caption)
    GameTooltip:AddLine(button.tip, 1, 1, 1, true)
    -- From alts says it can be split into the player's own groups.
    local groups = ns.CharacterGroups
    if button.gridId == "alts" and groups and type(groups.AltsTooltip) == "function" then
      pcall(groups.AltsTooltip, GameTooltip)
    end
  elseif button.__pbOverflowText then
    Th().AddOverflowLine(button, GameTooltip)
  else
    GameTooltip:SetText(button.caption or "")
  end
  if button.gridId == "all" then RV.AllMailRoom(panel, GameTooltip) end
  GameTooltip:Show()
end

-- The button for a sweep, made on first use: the built-ins at build, a
-- group's when it first appears. A group's name can change, so its caption
-- is read again on every layout.
function RV.GridButton(panel, id)
  local button = panel._gridById[id]
  local spec = panel._gridSpecs[id]
  if button then
    if spec then button.caption = tostring(spec.label or id) end
    return button
  end
  local T = Th()
  button = T.CreateButton(nil, panel.Grid)
  button.gridId = id
  button.caption = spec and tostring(spec.label or id) or (Labels()[id] or id)
  button:SetText(button.caption)
  if id == "alts" then button.tip = L()["CAT_ALTS_TIP"] end
  if id == "other" then button.tip = L()["CAT_OTHER_TIP"] end
  button:SetScript("OnClick", function(self) RV.GridClick(panel, self.gridId) end)
  button:SetScript("OnEnter", function(self) RV.GridTip(panel, self) end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- The right-click rides on the mouse-up, which a button greyed at 0 still
  -- gets and its click does not: a group with nothing to collect right now
  -- is still one to edit. Those two buttons say so on hover when greyed too.
  button:HookScript("OnMouseUp", function(self, mouse)
    if mouse == "RightButton" and self:IsMouseOver() then RV.GridEdit(panel, self.gridId) end
  end)
  if (spec or id == "alts") and button.SetMotionScriptsWhileDisabled then
    button:SetMotionScriptsWhileDisabled(true)
  end
  button:Hide()
  panel._gridById[id] = button
  -- Made after the window's skin pass: it takes the host's look now, as its
  -- neighbours did then.
  if panel._gridBuilt and ns.Skin and ns.Skin.Refresh then pcall(ns.Skin.Refresh, panel.Grid) end
  return button
end

local function LayoutGrid(panel)
  local grid = panel.Grid
  if not grid or not panel._gridButtons then return end
  local T = Th()
  local M = T.Metrics
  local width = UsableWidth(grid, PanelWidth(panel) - 2 * M.inset)
  local primary = panel._gridButtons[1]
  local arranging = panel._gridArranging
  local drag = panel._gridDrag

  -- The primary in its slot of the stack, the sweeps in theirs (RV.StackY:
  -- the blocks under the list).
  primary:ClearAllPoints()
  primary:SetSize(width, GRID_PRIMARY_HEIGHT)
  primary:SetPoint("TOPLEFT", grid, "TOPLEFT", 0, -RV.StackY(panel, "all"))
  local gridY = RV.StackY(panel, "grid")

  -- Neither a search nor a selection withdraws the sweeps. Under a search
  -- each sweep acts on the rows on screen of its own kind -- "All sold"
  -- over a search for one seller is the sold mail from that seller -- so
  -- they still mean what they say; and a footer that changed shape under a
  -- keystroke or a shift-click read as the screen moving for no reason, and
  -- pushed the list a half-row off its whole-row floor.
  local extras = ShowCategoryButtons()
  if Selecting(panel) then
    -- The picks it will take, by the run's own rules (RV.SelectionCounts):
    -- not a C.O.D. one, nor one finished since it was picked.
    primary.caption = L()("CAT_SELECTED", RV.SelectionCounts(panel).all or 0)
  elseif Searching(panel) or StuckOnly(panel) then
    primary.caption = L()["CAT_SHOWN"]
  else
    primary.caption = Labels().all or "all"
  end

  -- The sweeps the arrangement shows, in its order, filling the rows of
  -- three -- every one of them while it is being arranged, the hidden ones
  -- greyed and struck through, so one can be brought back where it was.
  -- The one in the hand stands where the cursor holds it; its cell takes
  -- the ghost.
  local columns = T.ColumnEdges(width, GRID_COLUMNS, M.gap, panel._gridColumns)
  local entries = panel._gridEntries or RV.GridEntries(panel)
  local placed = panel._gridPlaced
  for id in pairs(placed) do placed[id] = nil end
  local slot = 0
  for i = 1, #entries do
    local entry = entries[i]
    local button = RV.GridButton(panel, entry.id)
    if extras and (entry.shown or arranging) then
      local line = floor(slot / GRID_COLUMNS)
      local edge = columns[slot - line * GRID_COLUMNS + 1]
      -- From the grid block's top.
      local y = -(line * (GRID_BUTTON_HEIGHT + M.gap))
      button:SetSize(edge.width, GRID_BUTTON_HEIGHT)
      button._cellX, button._cellY = edge.left, y
      if drag and drag.button == button then
        local ghost = panel._gridGhost
        if ghost and ns.Arrange then
          ghost:ClearAllPoints()
          ghost:SetPoint("TOPLEFT", grid, "TOPLEFT", edge.left, y - gridY)
          ghost:SetSize(edge.width, GRID_BUTTON_HEIGHT)
          ns.Arrange.PaintGhost(ghost)
          ghost:Show()
        end
      else
        RV.PlaceSweep(panel, button, gridY)
      end
      button.hiddenInGrid = not entry.shown
      button:Show()
      placed[entry.id] = true
      slot = slot + 1
    else
      button:Hide()
    end
  end
  -- A group's button whose group is gone.
  for id, button in pairs(panel._gridById) do
    if not placed[id] then button:Hide() end
  end
  if panel._gridGhost and not drag then panel._gridGhost:Hide() end

  -- Captions are measured against the column they landed in. A caption that
  -- does not fit is truncated and its full text goes to the button's tooltip;
  -- it is never clipped, and word wrap is never left on inside a 26px button.
  --
  -- Each button also says how many mails it would collect, and one that would
  -- collect nothing is disabled: a sweep that can only answer "Done" is not
  -- worth a click, and the grey says so before the click rather than after.
  -- The count follows the segments' own switch; the disabling does not. The
  -- primary under a selection names its own count already. In the arrange
  -- mode the grey means hidden instead.
  local counts = panel._catCounts or {}
  local withCounts = ShowTabCounts()
  local picked = Selecting(panel)
  -- A window style that dresses the sweeps by what they hold (the counter's
  -- drawer and pigeonholes) is handed each button and its count here.
  local dress = ns.Skin and ns.Skin.DressSweep
  do
    -- The primary also stays live while the server holds mail the client
    -- has not shown yet: its click fetches the next batch.
    local n = counts.all or 0
    local caption = primary.caption
    if withCounts and n > 0 and not picked then caption = caption .. " (" .. FormatCount(n) .. ")" end
    -- Under a selection, live while it names any pick it will take.
    if picked then
      primary:SetEnabled((RV.SelectionCounts(panel).all or 0) > 0)
    else
      primary:SetEnabled(panel._moreOnServer or n > 0)
    end
    T.FitText(primary:GetFontString(), primary:GetWidth() - M.gap, caption, primary)
    if dress then dress(primary, n, true) end
  end
  for i = 1, #entries do
    local button = panel._gridById[entries[i].id]
    if button and placed[entries[i].id] then
      local n = RV.GridCount(panel, entries[i].id)
      local caption = button.caption
      if withCounts and n > 0 then caption = caption .. " (" .. FormatCount(n) .. ")" end
      local room = button:GetWidth() - M.gap
      if arranging then
        button:SetEnabled(not button.hiddenInGrid)
        room = button:GetWidth() - 2 * RV.EYE_ROOM
      else
        button:SetEnabled(n > 0)
      end
      T.FitText(button:GetFontString(), room, caption, button)
      if dress then dress(button, n, false) end
    end
  end
  RV.PaintGridHandles(panel)
end

-------------------------------------------------------------
-- The blocks under the list
--
-- Three blocks stand between the list and the panel's foot: the totals band
-- ("band"), while its option shows it; the full-width primary ("all"),
-- whose place the Done view's Delete, History's note and another
-- character's note take in those views; and the category buttons ("grid"),
-- in the inbox view only and only while the option shows them. Their
-- order, top down, is the player's (MailboxUI.GetStackOrder, arranged in
-- the arrange mode). Every order is the same height, so the list above --
-- the one elastic part -- and the window's floor (CT.MinPanelHeight) do not
-- depend on it; a hidden block is simply not in the stack, the others
-- close up, and the floor leaves it out.
--
-- All three stand in the footer, placed from its top, and the list's foot
-- is the footer's top. panel._stack holds each block's offset and height
-- for the view on screen, filled in place (RV.StackBlocks); RV.PlaceStack
-- anchors the band and the primary's slot from it, and LayoutGrid the
-- sweeps. In the default order every block stands exactly where it stood
-- when the band was anchored over the footer on its own.
--
-- While arranging, every block is a card (Core/Arrange.lua, "Lift"),
-- rising a unit and ringed in white when pointed at. The grid sits in a
-- tray, a card of its own four units out on every side -- further while
-- the pointer is over the grid, so it is easy to reach (RV.TrayPads) --
-- which is what takes it; its buttons are smaller cards on it. The
-- mode's one gesture model holds on every card: a drag moves the block, a
-- click on a block's card, or on the tray, selects the block, and the
-- arrange mode's inspector shows its card -- Move up and down, and for the
-- grid its own eye, which is the "Show category buttons" option itself --
-- and a right-click hides or shows it (All mail cannot be hidden: its
-- right-click does nothing). While the option hides the grid, or the
-- totals, a folded placeholder stands in its slot, so it can still be
-- moved, or selected, or brought back with a right-click. The placeholder
-- wears the crossed eye, and the totals' card, pointed at, its open eye:
-- signs of what a right-click does, never controls of their own. The tray
-- itself wears no eye: its rim has no room for one beside the buttons,
-- each of which has its own. Outside the mode the option works as it
-- always has, and a hidden grid simply is not there.
-- Opening the mode moves no block: the cards appear over the blocks where
-- they stand. Only what the mode adds takes room -- a hidden block's
-- placeholder, a hidden button shown dimmed in its cell -- and the list
-- gives it up, so the blocks above that room step up by it.
-- The cards are made the first time the mode opens, and the whole of it
-- costs one comparison per layout while the mode is shut.
-------------------------------------------------------------

RV.STACK_IDS = { "band", "all", "grid" }
-- What each block is, in its card in the arrange mode's inspector.
RV.BLOCK_TEXT = {
  band = "ARRANGE_BLOCK_TOTALS_DESC", all = "ARRANGE_BLOCK_ALL_DESC", grid = "ARRANGE_BLOCK_GRID_DESC",
}
RV.TRAY_PAD = 4
RV.FOLD_HEIGHT = 22
-- A sweep's eye, in from its right edge, and the room its caption keeps
-- clear of it on both sides while arranging, so a centred caption never
-- runs under it.
RV.EYE_RIGHT = 13
RV.EYE_ROOM = 22

-- The order, top down: the player's, or the default when there is no
-- settings module to ask. Shared; never written to.
function RV.StackOrder()
  local UI = ns.MailboxUI
  local order = UI and type(UI.GetStackOrder) == "function" and UI.GetStackOrder() or nil
  return type(order) == "table" and order or RV.STACK_IDS
end

-- Each block's offset from the footer's top and its height, for the view
-- on screen, into panel._stack; the total height is the answer (the
-- footer's height). A block the view does not have has no offset.
function RV.StackBlocks(panel)
  local M = Th().Metrics
  local s = panel._stack
  if not s then
    s = { y = {}, h = {}, placed = {} }
    panel._stack = s
  end
  local y, h = s.y, s.h
  local away, view = AV.Active(panel), panel.viewMode
  -- The band, or while the arrange mode is open and its option hides it,
  -- its folded placeholder -- in every view, as the band is.
  h.band = nil
  s.bandFolded = false
  if RV.ShowTotals() then
    h.band = M.controlHeight
  elseif panel._gridArranging then
    h.band = RV.FOLD_HEIGHT
    s.bandFolded = true
  end
  h.all = (away or view == VIEW_HISTORY) and GRID_BUTTON_HEIGHT or GRID_PRIMARY_HEIGHT
  h.grid = nil
  s.folded = false
  if not away and view == VIEW_COLLECT then
    local rows = RV.GridRows(panel)
    if rows > 0 then
      h.grid = rows * GRID_BUTTON_HEIGHT + (rows - 1) * M.gap
    elseif panel._gridArranging and not ShowCategoryButtons() then
      h.grid = RV.FOLD_HEIGHT
      s.folded = true
    end
  end
  y.band, y.all, y.grid = nil, nil, nil
  local order, top = RV.StackOrder(), 0
  for i = 1, #order do
    local id = order[i]
    local height = h[id]
    if height and not y[id] then
      y[id] = top
      top = top + height + M.gap
    end
  end
  s.total = top > 0 and top - M.gap or 0
  return s.total
end

-- Where a block's content stands now, from the footer's top: its slot, a
-- unit higher while it is pointed at in the arrange mode, or wherever the
-- hand holds it while it is dragged.
function RV.StackY(panel, id)
  local s = panel._stack
  local y = s and s.y[id]
  if not y then return 0 end
  local drag = panel._stackDrag
  if drag and drag.id == id then return drag.y end
  if panel._stackHover == id then return y - 1 end
  return y
end

-- The band and whatever holds the primary's slot, anchored from their
-- offsets -- again only where an offset moved -- and, while arranging, the
-- cards over them.
function RV.PlaceStack(panel)
  local s, footer = panel._stack, panel.Footer
  if not (s and footer and panel.Banner) then return end
  local placed = s.placed
  -- The band is on screen where the stack has it, and not while it is
  -- hidden or stands folded; shown or hidden again only when that changes.
  local band = s.y.band ~= nil and not s.bandFolded
  if placed.bandShown ~= band then
    placed.bandShown = band
    panel.Banner:SetShown(band)
  end
  local y = RV.StackY(panel, "band")
  if band and placed.band ~= y then
    placed.band = y
    panel.Banner:SetPoint("TOPLEFT", footer, "TOPLEFT", 0, -y)
    panel.Banner:SetPoint("TOPRIGHT", footer, "TOPRIGHT", 0, -y)
  end
  y = RV.StackY(panel, "all")
  if placed.all ~= y then
    placed.all = y
    local primary = panel._gridButtons and panel._gridButtons[1]
    if primary then primary:SetPoint("TOPLEFT", panel.Grid, "TOPLEFT", 0, -y) end
    local done = panel.DoneFooter
    if done then
      done:SetPoint("TOPLEFT", footer, "TOPLEFT", 0, -y)
      done:SetPoint("TOPRIGHT", footer, "TOPRIGHT", 0, -y)
    end
    -- The notes stand in the middle of the slot, as tall as a button.
    local inset, mid = Th().Metrics.inset, -(y + GRID_BUTTON_HEIGHT / 2)
    local note = panel.HistoryNote
    if note then
      note:SetPoint("LEFT", footer, "TOPLEFT", inset, mid)
      note:SetPoint("RIGHT", footer, "TOPRIGHT", -inset, mid)
    end
    note = panel.AltNote
    if note then
      note:SetPoint("LEFT", footer, "TOPLEFT", inset, mid)
      note:SetPoint("RIGHT", footer, "TOPRIGHT", -inset, mid)
    end
  end
  RV.PlaceCards(panel)
end

-- A sweep at its cell: `gridY` is the grid block's top, from the footer's.
-- A unit higher while it is pointed at in the arrange mode.
function RV.PlaceSweep(panel, button, gridY)
  local raise = (panel._sweepHover == button) and 1 or 0
  button:ClearAllPoints()
  button:SetPoint("TOPLEFT", panel.Grid, "TOPLEFT", button._cellX or 0, (button._cellY or 0) - gridY + raise)
end

-- Every sweep on screen at its cell again, the one in the hand apart: the
-- grid block moved, or rose.
function RV.PlaceSweeps(panel)
  local placed, byId = panel._gridPlaced, panel._gridById
  if not (placed and byId) then return end
  local gridY = RV.StackY(panel, "grid")
  local drag = panel._gridDrag
  for id in pairs(placed) do
    local button = byId[id]
    if button and not (drag and drag.button == button) then RV.PlaceSweep(panel, button, gridY) end
  end
end

-- The blocks moved, rose or settled: placed and painted again.
function RV.StackChanged(panel)
  RV.PlaceStack(panel)
  RV.PlaceSweeps(panel)
end

-- The tray's rim, from the buttons out (top, bottom, sides): TRAY_PAD at
-- rest; while the pointer is over the grid -- the tray or any button on it
-- -- as far out as the gaps and margins round it allow, two units short of
-- what stands beyond: the block or the list above and below it (the
-- stack's gap), the panel's edge at the sides and under the stack's last
-- block (the panel's inset). Drawn outward only: nothing else moves.
function RV.TrayPads(panel)
  local pad = RV.TRAY_PAD
  if not panel._gridOver then return pad, pad, pad end
  local M = Th().Metrics
  local near, edge = M.gap - 2, M.inset - 2
  local order, y = RV.StackOrder(), panel._stack.y
  local last
  for i = #order, 1, -1 do
    if y[order[i]] then
      last = order[i]
      break
    end
  end
  return near, (last == "grid") and edge or near, edge
end

-- The pointer came to the grid or left it: the tray's rim follows
-- (RV.TrayPads). Asked on every enter and leave of the tray and of its
-- buttons; the tray's own rect holds its buttons, so it answers for both.
function RV.GridOver(panel)
  local tray = panel._stackCards and panel._stackCards.grid
  local over = (panel._gridArranging and tray and tray:IsShown() and tray:IsMouseOver()) and true or nil
  if over == panel._gridOver then return end
  panel._gridOver = over
  RV.PlaceCards(panel)
end

-- The cards, while arranging: over the band and the primary's slot, and the
-- tray under the grid. Shut, they are hidden once and then left alone.
function RV.PlaceCards(panel)
  local cards = panel._stackCards
  if not panel._gridArranging then
    if panel._stackCardsOn then
      panel._stackCardsOn = nil
      panel._stackHover, panel._gridOver = nil, nil
      for _, card in pairs(cards) do card:Hide() end
    end
    return
  end
  local A = ns.Arrange
  if not (A and A.NewCard) then return end
  if not cards then
    cards = {}
    panel._stackCards = cards
  end
  panel._stackCardsOn = true
  local s, ids = panel._stack, RV.STACK_IDS
  for i = 1, #ids do
    local id = ids[i]
    local key = id
    if id == "grid" then
      -- The tray, or the placeholder while the option hides the grid.
      key = s.folded and "fold" or "grid"
      local other = cards[s.folded and "grid" or "fold"]
      if other then other:Hide() end
    elseif id == "band" then
      -- The band's card, or its placeholder while the option hides it.
      key = s.bandFolded and "bandFold" or "band"
      local other = cards[s.bandFolded and "band" or "bandFold"]
      if other then other:Hide() end
    end
    local card = cards[key]
    if s.y[id] then
      card = card or RV.NewStackCard(panel, key)
      local above, below, side = 0, 0, 0
      if key == "grid" then above, below, side = RV.TrayPads(panel) end
      local top = RV.StackY(panel, id) - above
      card:SetPoint("TOPLEFT", panel.Footer, "TOPLEFT", -side, -top)
      card:SetPoint("TOPRIGHT", panel.Footer, "TOPRIGHT", side, -top)
      card:SetHeight(s.h[id] + above + below)
      RV.PaintStackCard(panel, card)
      card:Show()
    elseif card then
      card:Hide()
    end
  end
end

-- A block's card, made the first time the mode shows the block. Over the
-- band and the primary's slot it stands above what it lifts and takes the
-- mouse, so nothing there collects or deletes while arranging; the tray
-- stands under the sweeps, whose own cards take the mouse over them, and
-- takes it in the gaps and at its rim.
-- Keys: "band", "all", "grid" (the tray), and the placeholders "fold" (the
-- grid's) and "bandFold" (the totals').
RV.FOLD_OF = { fold = "grid", bandFold = "band" }

function RV.NewStackCard(panel, key)
  local A, T = ns.Arrange, Th()
  local folds = RV.FOLD_OF[key]
  local kind = (key == "grid" and "tray") or (folds and "fold") or "block"
  local card = A.NewCard(panel.Footer, kind)
  card.stackId, card.panel = folds or key, panel
  local base = panel.Footer:GetFrameLevel()
  card:SetFrameLevel(key == "grid" and base or base + 8)
  card:EnableMouse(true)
  card:SetScript("OnEnter", RV.StackCardEnter)
  card:SetScript("OnLeave", RV.StackCardLeave)
  card:SetScript("OnMouseDown", RV.StackCardDown)
  card:SetScript("OnMouseUp", RV.StackCardUp)
  if folds then
    -- A crossed eye and the block's name, together in the middle.
    card.Text = T.CreateText(card, "secondary", "OVERLAY")
    card.Text:SetWordWrap(false)
    card.Text:SetText(L()[folds == "grid" and "ARRANGE_BLOCK_GRID" or "ARRANGE_BLOCK_TOTALS"])
    card.Text:SetPoint("CENTER", card, "CENTER", 9, 0)
    card.Eye = T.Glyph and T.Glyph(card, "eye-off", 8, "OVERLAY") or nil
    if card.Eye then card.Eye:SetPoint("RIGHT", card.Text, "LEFT", -6, 0) end
  elseif key == "band" and T.Glyph then
    -- The totals can be hidden: their open eye at the right end, as a
    -- category button's stands, only while pointed at (RV.PaintStackCard).
    card.Eye = T.Glyph(card, "eye", 8, "OVERLAY")
    if card.Eye then
      card.Eye:SetPoint("CENTER", card, "RIGHT", -RV.EYE_RIGHT, 0)
      card.Eye:Hide()
    end
  end
  panel._stackCards[key] = card
  return card
end

function RV.PaintStackCard(panel, card)
  local A = ns.Arrange
  if not (A and A.PaintCard) then return end
  local id, drag = card.stackId, panel._stackDrag
  local over = panel._stackHover == id
  local state = "rest"
  if drag and drag.id == id then
    state = "hand"
  elseif A.Selected and A.Selected("block", id) then
    state = over and "selHover" or "sel"
  elseif over then
    state = "hover"
  end
  A.PaintCard(card, state)
  if card.Text then
    local token = (state == "rest") and "textDisabled" or "textSecondary"
    Th().SetColor(card.Text, token)
    if card.Eye then Th().SetColor(card.Eye, token) end
  elseif card.Eye then
    -- A shown block's open eye, only while it is pointed at.
    local show = over and not drag
    card.Eye:SetShown(show and true or false)
    if show then Th().SetColor(card.Eye, "textSecondary") end
  end
end

-- Every card on screen painted again: the selection moved.
function RV.PaintStackCards(panel)
  local cards = panel._stackCards
  if not (cards and panel._gridArranging) then return end
  for _, card in pairs(cards) do
    if card:IsShown() then RV.PaintStackCard(panel, card) end
  end
end

-- What the primary's slot holds, in words, for its card's tooltip.
function RV.SlotName(panel)
  if AV.Active(panel) then return panel.AltNote and panel.AltNote:GetText() or "" end
  if panel.viewMode == VIEW_HISTORY then return L()["VIEW_HISTORY"] end
  if panel.viewMode == VIEW_DONE then return L()["BTN_DELETE_ALL_DONE"] end
  return Labels().all or "all"
end

-- What the primary's slot is in each view, for its card in the inspector:
-- All mail in the inbox, History's note, Done's Delete, and the note under
-- another character's box.
function RV.SlotTextKey(panel)
  if AV.Active(panel) then return "ARRANGE_BLOCK_ALT_DESC" end
  if panel.viewMode == VIEW_HISTORY then return "ARRANGE_BLOCK_HISTORY_DESC" end
  if panel.viewMode == VIEW_DONE then return "ARRANGE_BLOCK_DONE_DESC" end
  return "ARRANGE_BLOCK_ALL_DESC"
end

-- A block's name, for its tooltip and its card in the inspector.
function RV.BlockName(panel, id)
  if id == "band" then return L()["ARRANGE_BLOCK_TOTALS"] end
  if id == "grid" then return L()["ARRANGE_BLOCK_GRID"] end
  return RV.SlotName(panel)
end

-- Whether a right-click shows the block ("show"), hides it ("hide"), or
-- does nothing to it ("fixed"): the mode's words for its gestures
-- (Arrange.lua's AR.GestureLine).
function RV.BlockGesture(panel, id)
  if id == "grid" then return (panel._stack and panel._stack.folded) and "show" or "hide" end
  if id == "band" then return (panel._stack and panel._stack.bandFolded) and "show" or "hide" end
  return "fixed"
end

function RV.StackTip(panel, card)
  local id = card.stackId
  -- Clear of the arrange mode's inspector beside the window.
  local A = ns.Arrange
  if A and A.TipOwner then A.TipOwner(card, "ANCHOR_CURSOR") else GameTooltip:SetOwner(card, "ANCHOR_CURSOR") end
  GameTooltip:SetText(RV.BlockName(panel, id))
  if A and A.GestureLine then GameTooltip:AddLine(A.GestureLine(RV.BlockGesture(panel, id)), 0.7, 0.7, 0.7, true) end
  GameTooltip:Show()
end

-- Pointed at: the block rises a unit, its ring goes white, the pointer is
-- the move cross. Not while something is in the hand, whose drag decides
-- what is lifted.
function RV.StackCardEnter(card)
  local panel = card.panel
  if panel._stackDrag or panel._gridDrag then return end
  panel._stackHover = card.stackId
  -- On the tray, the pointer is over the grid: its rim grows as it rises.
  if card == panel._stackCards.grid then panel._gridOver = true end
  RV.StackChanged(panel)
  local A = ns.Arrange
  if A and A.MoveCursor then A.MoveCursor(true) end
  RV.StackTip(panel, card)
end

function RV.StackCardLeave(card)
  local panel = card.panel
  GameTooltip:Hide()
  if panel._stackDrag or panel._gridDrag then return end
  if panel._stackHover == card.stackId then
    panel._stackHover = nil
    RV.StackChanged(panel)
  end
  RV.GridOver(panel)
  local A = ns.Arrange
  if A and A.MoveCursor then A.MoveCursor(false) end
end

function RV.StackCardDown(card, mouse)
  if mouse ~= "LeftButton" then return end
  RV.StackPress(card.panel, card.stackId, card)
end

-- A right-click let go over a block's card hides or shows the block
-- (RV.BlockToggle); not while something is in the hand.
function RV.StackCardUp(card, mouse)
  if mouse ~= "RightButton" or not card:IsMouseOver() then return end
  local A = ns.Arrange
  if A and A.Dragging and A.Dragging() then return end
  RV.BlockToggle(card.panel, card.stackId)
end

-- A block taken by its card. A press that moves four units is a drag (the
-- shared gesture, Core/Arrange.lua's AR.Press): the block follows the
-- pointer up and down the stack, over the others, its slot ringed where it
-- will land; past the middle of the block above or below, the two change
-- places -- in the stored order itself, so the rest of the stack steps
-- aside as it goes. A press let go where it began is a click, wherever on
-- the card it landed: it selects the block. The handlers are one table per
-- panel, made on the first press, and what they act on is written into it:
-- nothing is made per press.
function RV.StackPress(panel, id, card)
  local A = ns.Arrange
  if not (A and A.Press) then return end
  local h = panel._stackPress
  if not h then
    h = {}
    function h.start(_, y0) RV.StackStart(h.panel, h.id, y0) end
    function h.move(_, y) RV.StackDrag(h.panel, y) end
    function h.drop() RV.StackDrop(h.panel) end
    function h.cancel() RV.StackCancel(h.panel) end
    function h.click() RV.StackClick(h.panel, h.id) end
    panel._stackPress = h
  end
  h.panel, h.id, h.name = panel, id, RV.BlockName(panel, id)
  A.Press(card, h)
end

-- Escape during a drag: the order as it was when the block was taken.
function RV.StackCancel(panel)
  local drag, UI = panel._stackDrag, ns.MailboxUI
  if drag and drag.before and UI and type(UI.SetStackOrder) == "function" then UI.SetStackOrder(drag.before) end
  RV.StackDrop(panel)
end

-- A click on a block selects it, and the inspector shows its card; a
-- second click lets it go. A click anywhere on the grid's tray, the gaps
-- between its buttons included, selects the grid and moves nothing, and so
-- does one on its placeholder while the option hides the grid: the card's
-- switch shows it.
function RV.StackClick(panel, id)
  if not panel._gridArranging then return end
  local A = ns.Arrange
  if A and A.Select then A.Select("block", id) end
end

-- A block's right-click: the grid or the totals hidden or shown (the block,
-- or its placeholder). All mail has nothing to hide.
function RV.BlockToggle(panel, id)
  if not panel._gridArranging then return end
  if id == "grid" then
    RV.SetGridShown(panel, not ShowCategoryButtons())
  elseif id == "band" then
    RV.SetTotalsShown(panel, not RV.ShowTotals())
  end
end

-- The grid's eye: the "Show category buttons" option itself, and the
-- window's floor follows it as it follows the option.
function RV.SetGridShown(panel, show)
  local UI = ns.MailboxUI
  if not (UI and type(UI.SetOption) == "function") then return end
  show = show and true or false
  GameTooltip:Hide()
  panel._stackHover = nil
  UI.SetOption("showCategoryButtons", show)
  RV.BlockOptionChanged(panel, show)
end

-- The totals' eye: the "Show totals" option itself, as the grid's is Show
-- category buttons, and the window's floor follows it the same way.
function RV.SetTotalsShown(panel, show)
  local UI = ns.MailboxUI
  if not (UI and type(UI.SetOption) == "function") then return end
  show = show and true or false
  GameTooltip:Hide()
  panel._stackHover = nil
  UI.SetOption("showTotals", show)
  RV.BlockOptionChanged(panel, show)
end

-- A block's option written from the mode: the stack and the floor after it
-- (MailboxUI's refresh moves a window standing on its floor), the options
-- panel's switch where it is open, the switch's sound, and whatever card is
-- under the pointer now.
function RV.BlockOptionChanged(panel, show)
  local UI = ns.MailboxUI
  if UI and type(UI.RefreshCollectCategoryButtons) == "function" then
    UI.RefreshCollectCategoryButtons()
  else
    CT.RefreshCategoryButtons(panel)
  end
  local options = ns.OptionsPanel
  if options and type(options.RefreshControls) == "function" then options.RefreshControls() end
  if type(SOUNDKIT) == "table" and type(PlaySound) == "function" then
    PlaySound(show and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
  end
  RV.Rehover(panel)
end

-- Move up (-1) or down (1) from the inspector: the block changes places
-- with the next one the view has that way, as a drag past it would.
function RV.MoveBlock(panel, id, step)
  local UI = ns.MailboxUI
  if not (panel._stack and UI and type(UI.SetStackOrder) == "function") then return end
  local order = RV.StackOrder()
  local k
  for i = 1, #order do
    if order[i] == id then k = i break end
  end
  if not k then return end
  local _, j = RV.StackNeighbour(panel, order, k, step)
  if not j then return end
  local moved = { order[1], order[2], order[3] }
  moved[k], moved[j] = moved[j], moved[k]
  UI.SetStackOrder(moved)
  CT.RefreshCategoryButtons(panel)
end

function RV.CanMoveBlock(panel, id, step)
  if not panel._stack then return false end
  local order = RV.StackOrder()
  for i = 1, #order do
    if order[i] == id then return RV.StackNeighbour(panel, order, i, step) ~= nil end
  end
  return false
end

function RV.StackStart(panel, id, y0)
  local s = panel._stack
  local top = panel.Footer:GetTop()
  if not (panel._gridArranging and s and s.y[id] and top) then return end
  GameTooltip:Hide()
  local order = RV.StackOrder()
  -- The tray in the hand at its rest rim, as its slot's ring is drawn.
  panel._stackHover, panel._sweepHover, panel._gridOver = nil, nil, nil
  panel._stackDrag = {
    id = id, y = s.y[id],
    -- The pointer's distance under the block's top, kept as it moves.
    grab = (top - s.y[id]) - y0,
    -- The order as it was, for Escape to put back (Arrange.lua, section 5).
    before = { order[1], order[2], order[3] },
  }
  RV.StackRaise(panel, id, true)
  local A = ns.Arrange
  if A and A.MoveCursor then A.MoveCursor(true) end
  RV.StackMoved(panel)
end

-- The present block next to `id` in the order, above (step -1) or below
-- (step 1), and its index; nil where there is none.
function RV.StackNeighbour(panel, order, k, step)
  local y = panel._stack.y
  local j = k + step
  while order[j] do
    if y[order[j]] then return order[j], j end
    j = j + step
  end
  return nil
end

-- The block in the hand changes places with the one above when its top edge
-- crosses that block's middle, and with the one below when its foot does.
-- By its edges, not its middle: the hand stops at the stack's ends, and a
-- block taller than the one at the end it is dragged to could never bring
-- its own middle past that one's. Crossing back takes the gap between the
-- blocks again, so a hand held still at the line does not flip them.
function RV.StackDrag(panel, cursorY)
  local drag, s = panel._stackDrag, panel._stack
  local top = panel.Footer:GetTop()
  if not (drag and s and top) then return end
  local h = s.h[drag.id] or 0
  drag.y = min(max(top - cursorY - drag.grab, 0), max(s.total - h, 0))
  local foot = drag.y + h
  local UI = ns.MailboxUI
  -- A quick hand can cross more than one block in a frame.
  for _ = 1, #RV.STACK_IDS do
    local order = RV.StackOrder()
    local k
    for i = 1, #order do
      if order[i] == drag.id then k = i break end
    end
    if not k then break end
    local prev, pj = RV.StackNeighbour(panel, order, k, -1)
    local nxt, nj = RV.StackNeighbour(panel, order, k, 1)
    local j
    if prev and drag.y < s.y[prev] + s.h[prev] / 2 then
      j = pj
    elseif nxt and foot > s.y[nxt] + s.h[nxt] / 2 then
      j = nj
    end
    if not (j and UI and type(UI.SetStackOrder) == "function") then break end
    local moved = { order[1], order[2], order[3] }
    moved[k], moved[j] = moved[j], moved[k]
    UI.SetStackOrder(moved)
    RV.StackBlocks(panel)
  end
  RV.StackMoved(panel)
end

-- The gesture's end, however it ends: levels back, the ghost gone.
function RV.StackEnd(panel)
  local drag = panel._stackDrag
  panel._stackDrag = nil
  if not drag then return nil end
  RV.StackRaise(panel, drag.id, false)
  if panel._stackGhost then panel._stackGhost:Hide() end
  return drag
end

function RV.StackDrop(panel)
  if not RV.StackEnd(panel) then return end
  RV.StackBlocks(panel)
  RV.StackMoved(panel)
  -- The sweeps' cards back at their buttons' levels.
  LayoutGrid(panel)
  RV.Rehover(panel)
end

-- Everything placed again while a block is in the hand: the others in
-- their slots, the one in the hand where it is held, the ghost in its slot.
function RV.StackMoved(panel)
  RV.PlaceStack(panel)
  RV.PlaceSweeps(panel)
  local drag, A = panel._stackDrag, ns.Arrange
  local ghost = panel._stackGhost
  if not drag then
    if ghost then ghost:Hide() end
    return
  end
  if not (A and A.NewGhost) then return end
  if not ghost then
    ghost = A.NewGhost(panel.Footer)
    panel._stackGhost = ghost
  end
  local s = panel._stack
  local slot = s.y[drag.id]
  if not slot then
    ghost:Hide()
    return
  end
  local pad = (drag.id == "grid") and RV.TRAY_PAD + 1 or 1
  local y = slot - pad
  ghost:ClearAllPoints()
  ghost:SetPoint("TOPLEFT", panel.Footer, "TOPLEFT", -pad, -y)
  ghost:SetPoint("TOPRIGHT", panel.Footer, "TOPRIGHT", pad, -y)
  ghost:SetHeight(s.h[drag.id] + 2 * pad)
  ghost:SetFrameLevel(panel.Footer:GetFrameLevel() + 7)
  A.PaintGhost(ghost)
  ghost:Show()
end

-- The block in the hand is drawn over the others it crosses: its content
-- and its card lifted above theirs for the gesture, each frame's own level
-- kept to be put back after.
function RV.LiftLevel(panel, frame, level)
  if not frame then return end
  local levels = panel._stackLevels
  if not levels then
    levels = {}
    panel._stackLevels = levels
  end
  if levels[frame] == nil then levels[frame] = frame:GetFrameLevel() end
  frame:SetFrameLevel(level)
end

function RV.StackRaise(panel, id, on)
  local levels = panel._stackLevels
  if not on then
    if levels then
      for frame, level in pairs(levels) do
        frame:SetFrameLevel(level)
        levels[frame] = nil
      end
    end
    return
  end
  local base = panel.Footer:GetFrameLevel()
  local cards = panel._stackCards
  if id == "band" and panel._stack.bandFolded then
    RV.LiftLevel(panel, cards and cards.bandFold, base + 25)
    return
  elseif id == "band" then
    RV.LiftLevel(panel, panel.Banner, base + 20)
  elseif id == "all" then
    RV.LiftLevel(panel, panel._gridButtons and panel._gridButtons[1], base + 20)
    RV.LiftLevel(panel, panel.DoneFooter, base + 20)
  elseif id == "grid" and panel._stack.folded then
    RV.LiftLevel(panel, cards and cards.fold, base + 25)
    return
  elseif id == "grid" then
    local placed, byId, handles = panel._gridPlaced, panel._gridById, panel._gridHandles
    for gridId in pairs(placed) do
      local button = byId[gridId]
      RV.LiftLevel(panel, button, base + 20)
      RV.LiftLevel(panel, handles and handles[button], base + 25)
    end
    RV.LiftLevel(panel, cards and cards.grid, base + 19)
    return
  end
  RV.LiftLevel(panel, cards and cards[id], base + 25)
end

-- The footer's height is the stack's: every block the view has, and the
-- gaps between them.
local function FooterHeight(panel)
  return RV.StackBlocks(panel)
end

-- Frozen: Core/MailboxUI.lua calls this when the category-buttons option
-- changes, and the list's refresh calls it for the counts. The window's
-- floor is sized for the grid's rows (see CT.MinPanelHeight); when those
-- rows change without the option moving -- a button hidden in the arrange
-- mode, a group's button come or gone -- the floor is asked to follow, as
-- the option's change moves it.
function CT.RefreshCategoryButtons(panel)
  if not panel or not panel.Footer then return end
  RV.GridEntries(panel)
  panel.Footer:SetHeight(FooterHeight(panel))
  RV.PlaceStack(panel)
  LayoutGrid(panel)
  if not panel._gridArranging and ShowCategoryButtons() and RV._floorRows ~= nil then
    local rows = ceil(RV.GridShownCount(panel) / GRID_COLUMNS)
    local UI = ns.MailboxUI
    if rows ~= RV._floorRows and UI and type(UI.RefreshCollectFloor) == "function" then
      RV._floorRows = rows
      UI.RefreshCollectFloor()
    end
  end
  -- While arranging, the inspector says what the blocks and the buttons are
  -- now: their order, what is hidden, the view's own block names.
  if panel._gridArranging then
    local A = ns.Arrange
    if A and A.Inspect then A.Inspect() end
  end
end

-- Each view's own footer: the sweeps under the inbox, Delete under Done, a
-- note under History, and a note under another character's box -- which
-- nothing here can collect from.
function RV.ApplyFooter(panel)
  if not (panel and panel.Footer and panel.Grid) then return end
  local away = AV.Active(panel)
  local id = panel.viewMode
  panel.Footer:SetHeight(FooterHeight(panel))
  RV.PlaceStack(panel)
  panel.Grid:SetShown(not away and id == VIEW_COLLECT)
  if panel.HistoryNote then panel.HistoryNote:SetShown(not away and id == VIEW_HISTORY) end
  if panel.DoneFooter then panel.DoneFooter:SetShown(not away and id == VIEW_DONE) end
  if panel.AltNote then panel.AltNote:SetShown(away) end
end

local function BuildGrid(panel)
  local T = Th()
  local labels = Labels()

  panel.Grid = CreateFrame("Frame", nil, panel.Footer)
  panel.Grid:SetAllPoints()

  panel._gridButtons = {}
  panel._gridColumns = {}
  panel._gridById = {}
  panel._gridSpecs = {}
  panel._gridPlaced = {}

  -- The primary: everything, always first.
  local primary = T.CreateButton(nil, panel.Grid)
  primary.caption = labels.all or "all"
  primary.gridId = "all"
  primary:SetText(primary.caption)
  primary:SetScript("OnClick", function()
    if panel._gridArranging then return end
    StartCategoryRun(panel, "all")
  end)
  primary:SetScript("OnEnter", function(self) RV.GridTip(panel, self) end)
  primary:SetScript("OnLeave", function() GameTooltip:Hide() end)
  panel._gridButtons[1] = primary

  local builtins = RV.BuiltinGridIds()
  for i = 1, #builtins do RV.GridButton(panel, builtins[i]) end
  panel._gridBuilt = true
end

-------------------------------------------------------------
-- The category grid :: arranged
--
-- While the arrange mode is open over the tab (Core/Arrange.lua) every sweep
-- shows, the hidden ones dimmed with their eye crossed, and each wears a
-- small card over it (Arrange.lua's "Lift") that takes the mouse instead of
-- the button: a drag moves the button through the grid, its cell ringed
-- where it will land, the others stepping aside; a click selects it, for
-- its card in the inspector; a right-click hides or shows it. Pointed at, a
-- card rises a unit and its ring goes white. Nothing collects while this is
-- open: the primary's slot is under a card of its own (the blocks under the
-- list).
-------------------------------------------------------------

function RV.GridHandle(panel, button)
  local handles = panel._gridHandles
  if not handles then
    handles = {}
    panel._gridHandles = handles
  end
  local handle = handles[button]
  if handle then return handle end
  local A = ns.Arrange
  handle = (A and A.NewCard) and A.NewCard(panel.Grid, "small") or CreateFrame("Frame", nil, panel.Grid)
  handle:SetAllPoints(button)
  handle:EnableMouse(true)
  handle.button, handle.panel = button, panel
  -- Its eye: crossed while the button is hidden, always; open while it
  -- shows only while it is pointed at. Either is a sign of what a
  -- right-click does, never a control of its own: a click anywhere on the
  -- card, the eye included, selects the button.
  local T = Th()
  if T.Glyph then
    handle.Eye = T.Glyph(handle, "eye", 8, "OVERLAY")
    handle.EyeOff = T.Glyph(handle, "eye-off", 8, "OVERLAY")
    if handle.Eye then handle.Eye:SetPoint("CENTER", handle, "RIGHT", -RV.EYE_RIGHT, 0) end
    if handle.EyeOff then handle.EyeOff:SetPoint("CENTER", handle, "RIGHT", -RV.EYE_RIGHT, 0) end
  end
  handle:SetScript("OnEnter", RV.HandleEnter)
  handle:SetScript("OnLeave", RV.HandleLeave)
  handle:SetScript("OnMouseDown", RV.HandleDown)
  handle:SetScript("OnMouseUp", RV.HandleUp)
  handle:Hide()
  handles[button] = handle
  return handle
end

-- A sweep's card in its state: in the hand, hidden, selected, both, or
-- neither, each pointed at or not.
function RV.PaintGridHandle(panel, handle)
  local A = ns.Arrange
  if not (A and A.PaintCard and handle.Ring) then return end
  local button, drag = handle.button, panel._gridDrag
  local over = panel._sweepHover == button
  local sel = A.Selected and A.Selected("button", button.gridId)
  local state = "rest"
  if drag and drag.button == button then
    state = "hand"
  elseif button.hiddenInGrid and sel then
    state = over and "hiddenSelHover" or "hiddenSel"
  elseif button.hiddenInGrid then
    state = over and "hiddenHover" or "hidden"
  elseif sel then
    state = over and "selHover" or "sel"
  elseif over then
    state = "hover"
  end
  A.PaintCard(handle, state)
  local hidden, T = button.hiddenInGrid and true or false, Th()
  if handle.Eye then
    handle.Eye:SetShown(over and not hidden)
    if over then T.SetColor(handle.Eye, "textSecondary") end
  end
  if handle.EyeOff then
    handle.EyeOff:SetShown(hidden)
    T.SetColor(handle.EyeOff, (over or state == "hand") and "textSecondary" or "textDisabled")
  end
end

-- Pointed at: the sweep rises a unit, its ring goes white, the pointer is
-- the move cross. Not while something is in the hand.
function RV.HandleEnter(handle)
  local panel = handle.panel
  if panel._gridDrag or panel._stackDrag then return end
  panel._sweepHover = handle.button
  RV.PlaceSweep(panel, handle.button, RV.StackY(panel, "grid"))
  RV.PaintGridHandle(panel, handle)
  RV.GridOver(panel)
  local A = ns.Arrange
  if A and A.MoveCursor then A.MoveCursor(true) end
  RV.HandleTip(panel, handle.button)
end

-- A sweep's tooltip while arranging: its whole name, what it collects where
-- the name does not say, and the mode's gestures -- clear of the inspector
-- beside the window.
function RV.HandleTip(panel, button)
  local A = ns.Arrange
  if A and A.TipOwner then A.TipOwner(button, "ANCHOR_RIGHT") else GameTooltip:SetOwner(button, "ANCHOR_RIGHT") end
  GameTooltip:SetText(button.caption or "")
  if button.tip then GameTooltip:AddLine(button.tip, 1, 1, 1, true) end
  if A and A.GestureLine then
    GameTooltip:AddLine(A.GestureLine(button.hiddenInGrid and "show" or "hide"), 0.7, 0.7, 0.7, true)
  end
  GameTooltip:Show()
end

function RV.HandleLeave(handle)
  local panel = handle.panel
  GameTooltip:Hide()
  if panel._gridDrag or panel._stackDrag then return end
  if panel._sweepHover == handle.button then
    panel._sweepHover = nil
    RV.PlaceSweep(panel, handle.button, RV.StackY(panel, "grid"))
    RV.PaintGridHandle(panel, handle)
  end
  RV.GridOver(panel)
  local A = ns.Arrange
  if A and A.MoveCursor then A.MoveCursor(false) end
end

function RV.HandleDown(handle, mouse)
  if mouse ~= "LeftButton" then return end
  RV.GridPress(handle.panel, handle.button)
end

-- A right-click let go over a sweep hides it, or shows it again.
function RV.HandleUp(handle, mouse)
  if mouse ~= "RightButton" or not handle:IsMouseOver() then return end
  local panel, A = handle.panel, ns.Arrange
  if not panel._gridArranging or (A and A.Dragging and A.Dragging()) then return end
  RV.SweepToggle(panel, handle.button.gridId)
end

-- A sweep hidden or shown from the mode, with the switch's sound.
function RV.SweepToggle(panel, id)
  GameTooltip:Hide()
  local hidden = false
  local entries = panel._gridEntries or RV.GridEntries(panel)
  for i = 1, #entries do
    if entries[i].id == id then hidden = not entries[i].shown end
  end
  RV.GridToggle(panel, id)
  if type(SOUNDKIT) == "table" and type(PlaySound) == "function" then
    PlaySound(hidden and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
  end
  RV.Rehover(panel)
end

-- After a drop: whatever card is under the pointer now takes it, as if it
-- had just been pointed at -- its hover was held off while the hand was
-- full. None, and the pointer is the pointer again.
function RV.Rehover(panel)
  RV.GridOver(panel)
  local handles = panel._gridHandles
  if handles then
    for _, handle in pairs(handles) do
      if handle:IsShown() and handle:IsMouseOver() then
        RV.HandleEnter(handle)
        return
      end
    end
  end
  local cards = panel._stackCards
  if cards then
    for _, card in pairs(cards) do
      if card:IsShown() and card:IsMouseOver() then
        RV.StackCardEnter(card)
        return
      end
    end
  end
  local A = ns.Arrange
  if A and A.MoveCursor then A.MoveCursor(false) end
end

function RV.PaintGridHandles(panel)
  local arranging = panel._gridArranging and ShowCategoryButtons()
  for id, button in pairs(panel._gridById) do
    if arranging and button:IsShown() then
      local handle = RV.GridHandle(panel, button)
      local drag = panel._gridDrag
      if not (drag and drag.button == button) then handle:SetFrameLevel(button:GetFrameLevel() + 5) end
      RV.PaintGridHandle(panel, handle)
      handle:Show()
    elseif panel._gridHandles and panel._gridHandles[button] then
      panel._gridHandles[button]:Hide()
    end
  end
end

-- The arrange mode opening or closing over this tab's grid.
function RV.ArrangeGrid(panel, on)
  panel._gridArranging = on and true or nil
  panel._sweepHover, panel._stackHover, panel._gridOver = nil, nil, nil
  if on then
    local A = ns.Arrange
    if not panel._gridGhost and A and A.NewGhost then panel._gridGhost = A.NewGhost(panel.Grid) end
  else
    local drag = panel._gridDrag
    panel._gridDrag = nil
    if drag then drag.button:SetFrameLevel(drag.level) end
    if panel._gridGhost then panel._gridGhost:Hide() end
    RV.StackEnd(panel)
  end
  CT.RefreshCategoryButtons(panel)
end

-- The arrangement with one button's place or visibility changed: stored,
-- and the grid laid out from it.
function RV.StoreGrid(panel, entries)
  local UI = ns.MailboxUI
  if UI and type(UI.SetGridLayout) == "function" then UI.SetGridLayout(RV.KeepGone(entries)) end
  panel._gridEntries = entries
end

-- The arrangement to store for `entries` -- the grid's, which name only the
-- buttons it can draw now -- with every stored entry the grid does not draw
-- but must not forget put back after the entry it followed: an empty
-- group's, whose button comes back where it was, hidden or shown as it
-- was, when the group has someone in it again. Only a group's deletion
-- drops its entry (CharacterGroups, CG.Delete). `entries` itself, when
-- there is nothing to keep.
function RV.KeepGone(entries)
  local UI, groups = ns.MailboxUI, ns.CharacterGroups
  local keep = groups and groups.Exists
  local stored = UI and type(UI.GetGridLayout) == "function" and UI.GetGridLayout()
  if type(keep) ~= "function" or type(stored) ~= "table" then return entries end
  local drawn = RV._drawn or {}
  RV._drawn = drawn
  for id in pairs(drawn) do drawn[id] = nil end
  for i = 1, #entries do drawn[entries[i].id] = true end
  -- Each kept entry under the drawn one it followed (false: at the front).
  local after, prev = nil, false
  for i = 1, #stored do
    local entry = stored[i]
    if drawn[entry.id] then
      prev = entry.id
    elseif keep(entry.id) then
      after = after or {}
      local list = after[prev]
      if not list then
        list = {}
        after[prev] = list
      end
      list[#list + 1] = entry
    end
  end
  if not after then return entries end
  local out = {}
  local lead = after[false]
  if lead then
    for k = 1, #lead do out[#out + 1] = lead[k] end
  end
  for i = 1, #entries do
    out[#out + 1] = entries[i]
    local list = after[entries[i].id]
    if list then
      for k = 1, #list do out[#out + 1] = list[k] end
    end
  end
  return out
end

function RV.CopyEntries(entries)
  local out = {}
  for i = 1, #entries do out[i] = { id = entries[i].id, shown = entries[i].shown } end
  return out
end

function RV.GridToggle(panel, id)
  local entries = RV.CopyEntries(panel._gridEntries or RV.GridEntries(panel))
  for i = 1, #entries do
    if entries[i].id == id then entries[i].shown = not entries[i].shown end
  end
  RV.StoreGrid(panel, entries)
  CT.RefreshCategoryButtons(panel)
end

-- What is hidden under the list, for the inspector's overview: the totals
-- while their option hides them; the grid itself while the option hides it
-- (its own hidden buttons wait with it), else each hidden button, in the
-- grid's order. put(kind, key, name).
function RV.ListHidden(panel, put)
  if not RV.ShowTotals() then put("band", "band", L()["ARRANGE_BLOCK_TOTALS"]) end
  if not ShowCategoryButtons() then
    put("grid", "grid", L()["ARRANGE_BLOCK_GRID"])
    return
  end
  local entries = panel._gridEntries or RV.GridEntries(panel)
  for i = 1, #entries do
    local entry = entries[i]
    if not entry.shown then
      local button = panel._gridById[entry.id]
      put("button", entry.id, button and button.caption or entry.id)
    end
  end
end

function RV.ShowHidden(panel, kind, key)
  if kind == "grid" then
    RV.SetGridShown(panel, true)
  elseif kind == "band" then
    RV.SetTotalsShown(panel, true)
  elseif kind == "button" then
    RV.GridToggle(panel, key)
  end
end

-- A sweep's card in the inspector (Arrange.lua, section 9): where it stands
-- in the grid's order, whether it shows, what it collects, and a step
-- along the order either way.
function RV.SweepIndex(panel, id)
  local entries = panel._gridEntries or RV.GridEntries(panel)
  for i = 1, #entries do
    if entries[i].id == id then return i, entries end
  end
  return nil, entries
end

function RV.SweepShown(panel, id)
  local k, entries = RV.SweepIndex(panel, id)
  return k ~= nil and entries[k].shown and true or false
end

function RV.SweepText(panel, id)
  local button = panel._gridById[id]
  if button and button.tip then return button.tip end
  return L()[panel._gridSpecs[id] and "ARRANGE_BUTTON_GROUP_DESC" or "ARRANGE_BUTTON_DESC"]
end

function RV.CanMoveSweep(panel, id, step)
  local k, entries = RV.SweepIndex(panel, id)
  return k ~= nil and entries[k + step] ~= nil
end

function RV.MoveSweep(panel, id, step)
  local k, entries = RV.SweepIndex(panel, id)
  if not (k and entries[k + step]) then return end
  local moved = RV.CopyEntries(entries)
  moved[k], moved[k + step] = moved[k + step], moved[k]
  RV.StoreGrid(panel, moved)
  CT.RefreshCategoryButtons(panel)
end

-- A sweep taken by its card: a drag moves it (RV.GridStart, below), a
-- click selects it. The handlers are one table per panel, made on the
-- first press, and the button they act on is written into it: nothing is
-- made per press.
function RV.GridPress(panel, button)
  local A = ns.Arrange
  if not (A and A.Press) then return end
  local h = panel._gridPress
  if not h then
    h = {}
    function h.start(x0, y0) RV.GridStart(h.panel, h.button, x0, y0) end
    function h.move(x, y) RV.GridDrag(h.panel, x, y) end
    function h.drop() RV.GridDrop(h.panel) end
    function h.cancel()
      local drag = h.panel._gridDrag
      if drag and drag.before then RV.StoreGrid(h.panel, drag.before) end
      RV.GridDrop(h.panel)
    end
    function h.click() RV.SweepClick(h.panel, h.button.gridId) end
    panel._gridPress = h
  end
  h.panel, h.button, h.name = panel, button, button.caption
  A.Press(button, h)
end

function RV.GridStart(panel, button, x0, y0)
  if not panel._gridArranging then return end
  GameTooltip:Hide()
  panel._gridDrag = {
    button = button, level = button:GetFrameLevel(),
    dx = x0 - (button:GetLeft() or x0), dy = y0 - (button:GetTop() or y0),
    -- The arrangement as it was, for Escape to put back.
    before = RV.CopyEntries(panel._gridEntries or RV.GridEntries(panel)),
  }
  button:SetFrameLevel(panel.Grid:GetFrameLevel() + 30)
  -- The button in the hand is a card in the hand: ringed in the accent,
  -- as its cell is, and over everything it crosses.
  local handle = RV.GridHandle(panel, button)
  handle:SetFrameLevel(button:GetFrameLevel() + 5)
  local A = ns.Arrange
  if A and A.MoveCursor then A.MoveCursor(true) end
  LayoutGrid(panel)
end

-- A sweep's click selects it for its card in the inspector; a second click
-- lets it go.
function RV.SweepClick(panel, id)
  if not panel._gridArranging then return end
  local A = ns.Arrange
  if A and A.Select then A.Select("button", id) end
end

-- The button follows the cursor over the grid; the cell under its middle is
-- where it goes, and the others step along to make room -- in the stored
-- arrangement itself, so what is on screen is what is kept.
function RV.GridDrag(panel, x, y)
  local drag = panel._gridDrag
  if not drag then return end
  local grid, button = panel.Grid, drag.button
  local left, top = grid:GetLeft(), grid:GetTop()
  if not (left and top) then return end
  local M = Th().Metrics
  local width = grid:GetWidth() or 0
  local w, h = button:GetWidth() or 0, button:GetHeight() or 0
  local rows = max(RV.GridRows(panel), 1)
  local firstY = RV.StackY(panel, "grid")
  local lastY = firstY + (rows - 1) * (GRID_BUTTON_HEIGHT + M.gap)
  local bx = min(max(x - left - drag.dx, 0), max(width - w, 0))
  local by = min(max(top - y + drag.dy, firstY), lastY)
  button:ClearAllPoints()
  button:SetPoint("TOPLEFT", grid, "TOPLEFT", bx, -by)

  local columns = panel._gridColumns
  local cx = bx + w / 2
  local column = GRID_COLUMNS
  for c = 1, GRID_COLUMNS do
    local edge = columns[c]
    if edge and cx < edge.right + M.gap / 2 then
      column = c
      break
    end
  end
  local line = floor((by + h / 2 - firstY) / (GRID_BUTTON_HEIGHT + M.gap))
  line = min(max(line, 0), rows - 1)
  local entries = panel._gridEntries or {}
  local target = min(max(line * GRID_COLUMNS + column, 1), #entries)
  local k
  for i = 1, #entries do
    if panel._gridById[entries[i].id] == button then k = i break end
  end
  if not k or k == target then return end
  local moved = RV.CopyEntries(entries)
  table.insert(moved, target, table.remove(moved, k))
  RV.StoreGrid(panel, moved)
  LayoutGrid(panel)
end

function RV.GridDrop(panel)
  local drag = panel._gridDrag
  panel._gridDrag = nil
  if not drag then return end
  drag.button:SetFrameLevel(drag.level)
  if panel._gridGhost then panel._gridGhost:Hide() end
  panel._sweepHover = nil
  LayoutGrid(panel)
  RV.Rehover(panel)
end

-------------------------------------------------------------
-- View mode
-------------------------------------------------------------

function SetViewMode(panel, id)
  if panel.viewMode == id then return end
  -- Timed on the visit's record (Postbox.lua, 5b): History's rows are first
  -- built here.
  local perf = ns.Perf
  local perfAt = perf and perf.visit and perf.Mark()
  local crossed = (panel.viewMode == VIEW_HISTORY) ~= (id == VIEW_HISTORY)
  panel.viewMode = id
  -- A selection was made over one view's rows; the next view lists others.
  ClearSelection(panel)
  -- The stuck filter is about the inbox.
  if id ~= VIEW_COLLECT then panel._stuckOnly = false end
  -- The search finds mail on the inbox and entries on History: into History
  -- or out of it, what was typed was asked of the other list.
  if crossed then AV.ResetSearch(panel) end

  RV.ApplyFooter(panel)

  panel.MailListScroll:SetVerticalScroll(0)
  PaintViewToggle(panel)
  CT.RefreshMailList(panel)
  if perfAt then perf.Done(id == VIEW_HISTORY and "history" or "view", perfAt) end
end

-- The top row -- the view switch, the other box's name, the hint, the
-- character picker and the search -- steps aside while the arrange mode's
-- column header stands in its place, and comes back as the tab's own
-- layout has it: the view switch and the search are always there, and the
-- rest is laid out again from where things stand (AV.Paint), so nothing the
-- mode did is left on it. Hidden, not moved: the list under it stays where
-- it is. LayoutViewToggle hides it again whenever it lays the row out
-- while the header stands there.
function RV.HideTopRow(panel)
  panel._topHidden = true
  local toggle = panel.ViewToggle
  if toggle then
    toggle:Hide()
    if toggle.alt then toggle.alt:Hide() end
  end
  if panel.Hint then panel.Hint:Hide() end
  if panel.Picker then panel.Picker:Hide() end
  -- The keyboard never stays with a box nobody can see.
  if panel.SearchBox and panel.SearchBox.ClearFocus then panel.SearchBox:ClearFocus() end
  if panel.SearchWrap then panel.SearchWrap:Hide() end
end

function RV.ShowTopRow(panel)
  if not panel._topHidden then return end
  panel._topHidden = nil
  if panel.ViewToggle then panel.ViewToggle:Show() end
  if panel.SearchWrap then panel.SearchWrap:Show() end
  AV.Paint(panel)
end

-- The arrange mode over this tab (Core/Arrange.lua): its column header
-- stands in the top row's place, over the list's lanes, and the list does
-- not move; the blocks under the list become cards, and the category grid
-- takes its drags and clicks instead of collecting. The top row comes back
-- as it was when the mode ends. Built once per panel.
function CT.ArrangeHost(panel)
  if not (panel and panel.MailListArea) then return nil end
  if panel._arrangeHost then return panel._arrangeHost end
  local host = { owner = panel }
  -- The header's left edge is the rows' own (the list's inset inside its
  -- container), so a lane's x is a heading's; its right edge is theirs
  -- while nothing scrolls, the same inset in from the container's edge,
  -- whether the list scrolls now or not; its top is the top row's.
  function host.PlaceStrip(strip)
    local M = Th().Metrics
    strip:SetPoint("TOPLEFT", panel.ViewToggle, "TOPLEFT", M.tightGap, 0)
    strip:SetPoint("RIGHT", panel.MailListArea, "RIGHT", -M.tightGap, 0)
  end
  -- Before the mode takes the list: the search is cleared, as its clear
  -- button clears it, so the rows the header arranges are the whole list
  -- (and a search of every box ends with its query); and the selection is
  -- let go, since a click on a row now takes a column, not a mail, and a
  -- collect button under the mode is a card. Neither comes back when the
  -- mode ends.
  function host.Prepare()
    ClearSelection(panel)
    local box = panel.SearchBox
    if box then
      if box:GetText() ~= "" then box:SetText("") end
      if box.ClearFocus then box:ClearFocus() end
    end
  end
  function host.OnEnter()
    -- The reading view is over the list the header describes.
    HideDetail(panel)
    RV.FanClose(true)
    RV.HideTopRow(panel)
    if RV.ArrangeGrid then RV.ArrangeGrid(panel, true) end
  end
  function host.OnLeave()
    RV.ShowTopRow(panel)
    if RV.ArrangeGrid then RV.ArrangeGrid(panel, false) end
  end
  -- What the header and the rows' marks read, for the list on screen: its
  -- placement table (whose lanes RV.Place publishes), its row pool, its
  -- scroll frame and the frame its rows stand in, and whether its rows are
  -- the two-line ones, which have no lanes.
  function host.Spec()
    if AV.Active(panel) then
      local Memory = ns.MailMemory
      return Memory and Memory.PlaceSpec and Memory.PlaceSpec(panel.MailListChild) or nil
    end
    if panel.viewMode == VIEW_HISTORY then return panel._histSpec end
    return panel._rowSpec
  end
  function host.Pool()
    if AV.Active(panel) then return panel._avPool end
    if panel.viewMode == VIEW_HISTORY then return panel._hrows end
    return panel._rows
  end
  function host.Scroll() return panel.MailListScroll end
  function host.List() return panel.MailListChild end
  -- Whether the list is the tab's own mail rows, whose icon's hover the
  -- Icon card chooses (the fan); not History, not another character's box.
  function host.AttachHover()
    return not AV.Active(panel) and panel.viewMode ~= VIEW_HISTORY
  end
  function host.TwoLine()
    return not AV.Active(panel) and panel.viewMode ~= VIEW_HISTORY and not RowMetrics()
  end
  -- Preview mail, from the overview (Arrange.lua): a new sample set in the
  -- list's place, from its top; switched off -- or the mode ending, which
  -- switches it off -- the list as it was, at the place it was scrolled to
  -- when the list is still the one it was (the same view, the same box),
  -- carried across a change of row size as CT.ApplyRowLayout carries it.
  function host.Preview(on)
    on = on and true or false
    if (panel._preview == true) == on then return end
    local scroll = panel.MailListScroll
    local keep = panel._previewKeep or {}
    panel._previewKeep = keep
    if on then
      keep.offset, keep.stride = scroll:GetVerticalScroll() or 0, panel._rowStride or 0
      keep.view, keep.alt = panel.viewMode, panel._alt
      RV.PreviewBuild()
      panel._preview = true
      scroll:SetVerticalScroll(0)
      CT.RefreshMailList(panel)
      return
    end
    panel._preview = nil
    panel._pvList, panel._pvDone, panel._pvTail = nil, nil, nil
    CT.PreviewRelease()
    -- The preview window closes with the mode (MailboxUI, 5c): nothing on
    -- screen needs the list again, and its next show draws it afresh.
    if host.PreviewLocked() then return end
    CT.RefreshMailList(panel)
    local stride = panel._rowStride or 0
    local offset = 0
    if keep.view == panel.viewMode and keep.alt == panel._alt and stride > 0 and (keep.stride or 0) > 0 then
      offset = (keep.stride == stride) and keep.offset or keep.offset / keep.stride * stride
    end
    local listed = #panel._filtered
    if AV.Active(panel) then
      listed = #(panel._avRows or {})
    elseif panel.viewMode == VIEW_HISTORY then
      listed = #panel._history
    end
    local maxScroll = max(0, RV.ListHeight(listed, stride) - (scroll:GetHeight() or 0))
    scroll:SetVerticalScroll(min(offset, maxScroll))
    if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end
    if panel:IsShown() then UpdateVisibleRows(panel) end
  end
  -- The preview window, away from a mailbox (MailboxUI, 5c): the samples are
  -- the list for the whole mode, and the window goes with the mode.
  function host.PreviewLocked()
    local UI = ns.MailboxUI
    return UI and UI.IsPreview and UI.IsPreview() or false
  end
  function host.Left()
    local UI = ns.MailboxUI
    if UI and UI.PreviewModeEnded then UI.PreviewModeEnded() end
  end
  -- Which arrangement the list on screen follows: History's own while
  -- History shows, the mail rows' otherwise (another character's box
  -- included). The mode arranges that one, and while this character's box
  -- shows and History is kept, the inspector offers the other: the list is
  -- switched under the mode, which follows it.
  function host.History() return panel.viewMode == VIEW_HISTORY and not AV.Active(panel) end
  function host.CanSwitch() return not AV.Active(panel) and RV.HistoryOn() end
  function host.ShowHistory(on)
    if host.History() == (on and true or false) then return end
    SetViewMode(panel, on and VIEW_HISTORY or VIEW_COLLECT)
  end
  -- The inspector docks beside the Postbox window, level with this tab's
  -- top row -- the header, while it stands there -- and answers for the
  -- blocks under the list (Arrange.lua, section 9).
  function host.Dock()
    local UI = ns.MailboxUI
    return UI and UI._frame or panel
  end
  function host.DockTop() return host.strip or panel.ViewToggle end
  function host.ListHidden(put) RV.ListHidden(panel, put) end
  function host.ShowHidden(kind, key) RV.ShowHidden(panel, kind, key) end
  function host.BlockPresent(id) return panel._stack ~= nil and panel._stack.y[id] ~= nil end
  function host.BlockName(id) return RV.BlockName(panel, id) end
  function host.BlockText(id)
    if id == "all" then return L()[RV.SlotTextKey(panel)] end
    return L()[RV.BLOCK_TEXT[id] or "ARRANGE_BLOCK_ALL_DESC"]
  end
  function host.BlockNote(id)
    if id == "grid" then return L()["ARRANGE_GRID_FOLD_NOTE"] end
    if id == "band" then return L()["ARRANGE_TOTALS_FOLD_NOTE"] end
    return nil
  end
  function host.BlockShown(id)
    if id == "grid" then return ShowCategoryButtons() end
    if id == "band" then return RV.ShowTotals() end
    return nil
  end
  function host.SetBlockShown(id, on)
    if id == "grid" then
      RV.SetGridShown(panel, on)
    elseif id == "band" then
      RV.SetTotalsShown(panel, on)
    end
  end
  function host.CanMoveBlock(id, step) return RV.CanMoveBlock(panel, id, step) end
  function host.MoveBlock(id, step) RV.MoveBlock(panel, id, step) end
  function host.StackOrder() return RV.StackOrder() end
  function host.PaintBlocks()
    RV.PaintStackCards(panel)
    if panel._gridArranging then RV.PaintGridHandles(panel) end
  end
  -- And for the category buttons, each by its grid id.
  function host.ButtonPresent(id) return panel._gridArranging ~= nil and panel._gridPlaced[id] == true end
  function host.ButtonName(id)
    local button = panel._gridById[id]
    return button and button.caption or tostring(id)
  end
  function host.ButtonText(id) return RV.SweepText(panel, id) end
  function host.ButtonShown(id) return RV.SweepShown(panel, id) end
  function host.SetButtonShown(id, on)
    if RV.SweepShown(panel, id) ~= (on and true or false) then RV.GridToggle(panel, id) end
  end
  function host.CanMoveButton(id, step) return RV.CanMoveSweep(panel, id, step) end
  function host.MoveButton(id, step) RV.MoveSweep(panel, id, step) end
  -- The block a button stands in, for the link up from its card; and the
  -- grid's own way to the character groups, whose buttons stand in it.
  function host.ButtonBlock() return "grid" end
  function host.BlockLink(id) return id == "grid" and L()["ARRANGE_GROUPS_OPEN"] or nil end
  function host.FollowBlockLink(id)
    local groups = ns.CharacterGroups
    if id ~= "grid" or not (groups and type(groups.OpenEditor) == "function") then return end
    -- Beside the inspector, on its side away from the window.
    local A = ns.Arrange
    local insp = A and A._insp
    local UI = ns.MailboxUI
    local anchor = (insp and insp:IsShown()) and insp or (UI and UI._frame)
    local ok, err = pcall(groups.OpenEditor, nil, anchor, insp and insp:IsShown() and insp.side or nil)
    if not ok and type(geterrorhandler) == "function" then geterrorhandler()(err) end
  end
  panel._arrangeHost = host
  return host
end

-- The rows on screen bound again where they are -- the arrange mode's pointer
-- moved -- without the walk a refresh makes.
function CT.RebindRows(panel)
  if panel and panel.MailListChild and panel:IsShown() then UpdateVisibleRows(panel) end
end

-------------------------------------------------------------
-- Build
-------------------------------------------------------------

-- "Read, nothing left (3)" with a fold mark and their Delete at its right.
-- Built twice: the one in the list, and its copy pinned at the list's foot.
-- The caller sets the click.
function RV.BuildDivider(panel, parent)
  local T = Th()
  local M = T.Metrics
  local divider = CreateFrame("Button", nil, parent)
  divider:RegisterForClicks("LeftButtonUp")
  -- The same ground on both copies, so the pinned one hands over to the one
  -- in the list without changing its look: a neutral fill, nearly opaque --
  -- enough to hide a row passing under the pinned copy, not a hard block.
  -- Untagged and plain, so no host skin repaints it or fades it with the
  -- window's opacity (it wore the band surface once, and under EllesmereUI
  -- the rows read through it).
  divider.Fill = divider:CreateTexture(nil, "BACKGROUND")
  divider.Fill:SetAllPoints()
  Th().FillColor(divider.Fill, "surface", 0.95)
  divider.Rule = divider:CreateTexture(nil, "ARTWORK")
  divider.Rule:SetHeight(1)
  -- Edge to edge, as wide as the rows it separates.
  divider.Rule:SetPoint("TOPLEFT", divider, "TOPLEFT", 0, -1)
  divider.Rule:SetPoint("TOPRIGHT", divider, "TOPRIGHT", 0, -1)
  divider.Rule:SetTexture(WHITE)
  T.SetColor(divider.Rule, "textSecondary")
  divider.Rule:SetAlpha(0.25)
  -- The fold mark: plus while folded, minus while open. The cue that a click
  -- here folds the read mail away.
  divider.Fold = divider:CreateTexture(nil, "ARTWORK")
  divider.Fold:SetSize(12, 12)
  divider.Fold:SetPoint("LEFT", divider, "LEFT", M.inset, 0)
  divider.Fold:SetDesaturated(true)
  divider.Fold:SetAlpha(0.7)
  divider.Label = T.CreateText(divider, "secondary")
  divider.Label:SetPoint("LEFT", divider.Fold, "RIGHT", 6, 0)
  divider.Delete = CreateFrame("Button", nil, divider)
  divider.Delete:SetPoint("RIGHT", divider, "RIGHT", -M.inset, 0)
  divider.Delete.Text = T.CreateText(divider.Delete, "secondary")
  divider.Delete.Text:SetPoint("RIGHT")
  -- "Delete all", not the one-mail "Delete": this button takes every read
  -- mail with nothing left, and the word has to say so before the click.
  divider.Delete.Text:SetText(L()["BTN_DELETE_ALL"])
  divider.Delete:SetSize(max(T.TextWidth(divider.Delete.Text) + 8, 40), 18)
  -- Nothing is deleted from the list while its columns are being arranged.
  divider.Delete:SetScript("OnClick", function()
    if not RV.Arranging(panel) then DeleteAllDone(panel) end
  end)
  divider.Delete:SetScript("OnEnter", function(self)
    Th().SetColor(self.Text, "negative")
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L()["BTN_DELETE_ALL"])
    GameTooltip:AddLine(RawKey("HINT_DELETE_READ") or "", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  divider.Delete:SetScript("OnLeave", function(self)
    Th().SetColor(self.Text, "textSecondary")
    GameTooltip:Hide()
  end)
  divider:Hide()
  return divider
end

-------------------------------------------------------------
-- The fan (Options, Mail tab: Attachments on hover, Fan out)
--
-- Where the player chose it, resting the pointer on the item icon of a mail
-- holding two items or more (RV.FanHover, from the icon's own hover) opens,
-- after Fan.DWELL, a plate beside the icon on the same row: the gold first,
-- as the reading view has it, then one tile per item with its count. It is
-- a tooltip the player can use -- its own ground at any window opacity
-- (Theme's popup floor), over the rows and under the reading view -- and a
-- click on a tile takes that item through the reading view's own path:
-- ConfirmCOD first, RV.ArmPaidTake across the C.O.D. its take pays, and
-- MailService's TakeAttachment, which fetches the body first where the
-- mail was never opened (opts.fetch). Shift- and Ctrl-click do what they
-- do on Blizzard's own mail tiles (HandleModifiedItemClick); right-click
-- does nothing; the gold tile takes the gold. A tile the server refused,
-- or every item's while the bags are full, is dimmed with the warning
-- triangle, says why, and takes no click.
--
-- Placed by rule: past the icon's far edge, or before its near edge when
-- the icon stands in the list's far half (the row's end); a second line
-- past Fan.PER_LINE tiles, or where the room runs out; clamped inside the
-- list. It closes on leaving the icon and the plate (Fan.GRACE for the
-- step between them), a press anywhere else (GLOBAL_MOUSE_DOWN, registered
-- only while it is open), any scroll, a row pass that binds its row to
-- other mail (RV.FanCheck), a run, the reading view, the arrange mode and
-- the tab hiding. It never opens during a run, while arranging, with the
-- reading view up, over Preview mail's samples, on a row half scrolled out
-- or for a mail with one item (that keeps the item's own tooltip). After a
-- take it follows its row in place, and closes once the mail holds nothing.
--
-- Mail Memory's rows open it too, in Mail Memory's window and over another
-- character's box on this tab, from what a snapshot says a mail held: the
-- row carries the source its tiles come from (`fanSource`, MM.FanSource).
-- Read-only -- a record, often of another character's box, holds nothing
-- to take: a plain click does nothing, Shift- and Ctrl-click link and try
-- on, and each tile says where it can be taken. Each list keeps its own
-- plate and tiles (Fan.Use), the fan standing in the list it opens over.
--
-- Nothing runs while it is shut. The plate and its tiles are made the first
-- time one opens and reused after; the dwell and the grace are single
-- C_Timer.After calls on shared functions, told apart by counters rather
-- than closures (timers of one length fire in the order they were set), so
-- a rest, an open and a close allocate nothing once the texts are known.
-- Motion is AnimationGroups alone: the plate fades in, the tiles slide out
-- from under the icon, staggered, and the plate fades out on a close.
-------------------------------------------------------------
do
  local Fan = {
    DWELL = 0.25, GRACE = 0.1, QUICK = 0.5,
    -- The plate stands GAP past the icon; PAD inside its edge, tiles TILE
    -- (TILE_LARGE on Larger mail rows) square and TILE_GAP apart.
    GAP = 3, PAD = 3, TILE = 28, TILE_LARGE = 32, TILE_GAP = 2, PER_LINE = 12,
    -- A line of tiles is kept on a short row's room only while it holds at
    -- least this many, or all of them; past that it takes the list's width.
    MIN_LINE = 4,
    FADE_IN = 0.08, SLIDE = 0.12, STAGGER = 0.012, LAND_BY = 0.2, FADE_OUT = 0.06,
    COIN = "Interface\\Icons\\INV_Misc_Coin_02",
    tiles = {}, n = 0,
    -- Refusals met from this fan, by item link, for the mail `fp` names.
    refused = {},
    armN = 0, fireN = 0, graceN = 0, graceFireN = 0, graceOn = false,
    open = false, closedAt = -1,
    -- The gold tile's count and the C.O.D. line, one text per amount.
    golds = {}, cods = {}, textsN = 0, TEXTS_MAX = 64,
  }
  RV.Fan = Fan
  RV.fanOpen = false

  -- Whether the player chose the fan (MailboxUI.GetAttachHover).
  function Fan.Wanted()
    local UI = ns.MailboxUI
    return UI ~= nil and type(UI.GetAttachHover) == "function" and UI.GetAttachHover() == "fan"
  end

  -- row -> whether a fan may stand over it at all: a live mail of the inbox,
  -- no run, no arranging, no reading view, no sample mail. A row of
  -- remembered mail carries the source its tiles come from (`fanSource`,
  -- Mail Memory's rows: MM.FanSource), which answers for itself.
  function Fan.Allowed(row)
    local src = row.fanSource
    if src then return src.Allowed(row) end
    local panel = row.panel
    if not panel or panel._preview or Run.active then return false end
    if RV.Arranging(panel) then return false end
    local detail = panel.Detail
    if detail and detail:IsShown() then return false end
    return true
  end

  -- row -> the list it stands in: the fan opens there, and within it.
  function Fan.ScrollOf(row)
    local src = row.fanSource
    if src then return src.Scroll(row) end
    return row.panel.MailListScroll
  end

  -- row -> what tells the mail it shows from another: the inbox mail's
  -- fingerprint, or the remembered mail itself.
  function Fan.Identity(row)
    if row.fanSource then return row.mail end
    return row.fingerprint
  end

  -- row -> whether one may open over it now: allowed, a mail of two items
  -- or more, and its icon wholly inside the visible list.
  function Fan.MayOpen(row)
    if (row.iconItems or 0) < 2 or not Fan.Allowed(row) or not row:IsVisible() then return false end
    if not row.fanSource and not LiveIndex(row) then return false end
    local scroll = Fan.ScrollOf(row)
    if not scroll then return false end
    local top, bottom = row.Icon:GetTop(), row.Icon:GetBottom()
    local sTop, sBottom = scroll:GetTop(), scroll:GetBottom()
    if not (top and bottom and sTop and sBottom) then return false end
    return top <= sTop + 0.5 and bottom >= sBottom - 0.5
  end

  -- cod, amount -> the C.O.D. line ("C.O.D.: 45g", in the warning tone) or
  -- the gold tile's count ("250g"), each made once per amount and kept,
  -- bounded as RV.counts is.
  function Fan.MoneyText(cod, amount)
    local memo = cod and Fan.cods or Fan.golds
    local text = memo[amount]
    if text then return text end
    if Fan.textsN >= Fan.TEXTS_MAX then
      for key in pairs(Fan.golds) do Fan.golds[key] = nil end
      for key in pairs(Fan.cods) do Fan.cods[key] = nil end
      Fan.textsN = 0
    end
    if cod then
      text = MoneyText(true, 0, amount, nil, false) or ""
    else
      text = ns.Core.Formatting.FormatMoneyCompact(amount, true)
    end
    memo[amount] = text
    Fan.textsN = Fan.textsN + 1
    return text
  end

  -- scroll, panel -> the plate for the list `scroll` scrolls, in the frame
  -- that holds it; `panel` is the Mail tab's, for its list (nil elsewhere).
  function Fan.Build(scroll, panel)
    local T = Th()
    local plate = CreateFrame("Frame", nil, scroll:GetParent(), "BackdropTemplate")
    -- Over the rows, their quality marks and the divider's pinned copy
    -- (MailListChild + 8), under the reading view (the panel's + 20). Set
    -- before the card is painted: the popup floor's holder takes its level
    -- from it.
    plate:SetFrameLevel(scroll:GetScrollChild():GetFrameLevel() + 10)
    plate:EnableMouse(true)
    plate:Hide()
    plate.__pbPopupAlways = true
    T.ApplyCard(plate)
    plate._panel = panel
    plate.Cod = T.CreateText(plate, "secondary")
    plate.Cod:SetJustifyH("LEFT")
    plate.Cod:SetWordWrap(false)
    plate.Cod:SetPoint("TOPLEFT", plate, "TOPLEFT", Fan.PAD + 1, -Fan.PAD)
    plate.Cod:Hide()
    local fadeIn = plate:CreateAnimationGroup()
    local alpha = fadeIn:CreateAnimation("Alpha")
    alpha:SetFromAlpha(0)
    alpha:SetToAlpha(1)
    alpha:SetDuration(Fan.FADE_IN)
    fadeIn:SetToFinalAlpha(true)
    local fadeOut = plate:CreateAnimationGroup()
    alpha = fadeOut:CreateAnimation("Alpha")
    alpha:SetFromAlpha(1)
    alpha:SetToAlpha(0)
    alpha:SetDuration(Fan.FADE_OUT)
    fadeOut:SetToFinalAlpha(true)
    fadeOut:SetScript("OnFinished", Fan.FadedOut)
    plate.In, plate.Out = fadeIn, fadeOut
    plate:SetScript("OnEnter", Fan.Hold)
    plate:SetScript("OnLeave", Fan.Leaving)
    plate:SetScript("OnEvent", Fan.MouseDown)
    if ns.Skin and ns.Skin.Refresh then pcall(ns.Skin.Refresh, plate) end
    return plate
  end

  -- scroll, panel -> the plate and tiles of that list in use (Fan.plate,
  -- Fan.tiles), made the first time a fan opens there: a fan stands in the
  -- list it opens over, and each list keeps its own -- the Mail tab's, and
  -- Mail Memory's window. Called only while no fan is open; the last one
  -- used is put away if it is another.
  Fan.sets = {}
  function Fan.Use(scroll, panel)
    local set = Fan.sets[scroll]
    if not set then
      set = { plate = Fan.Build(scroll, panel), tiles = {} }
      Fan.sets[scroll] = set
    end
    -- The Mail tab's list is also where another character's remembered box
    -- is shown, whose rows name no panel: the plate keeps the tab's.
    if panel then set.plate._panel = panel end
    local last = Fan.plate
    if last and last ~= set.plate and last:IsShown() then
      last.Out:Stop()
      last:Hide()
    end
    Fan.plate, Fan.tiles, Fan.scroll = set.plate, set.tiles, scroll
  end

  -- The i-th tile, made on first use: the reading view's slot, with the
  -- quality mark at its top-left and the warning triangle at its top-right,
  -- and its slide.
  function Fan.Tile(i)
    local tile = Fan.tiles[i]
    if tile then return tile end
    local T = Th()
    tile = CreateFrame("Button", nil, Fan.plate, "BackdropTemplate")
    tile:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local art = tile:CreateTexture(nil, "BACKGROUND")
    art:SetAllPoints()
    art:SetTexture(EMPTY_SLOT_ART)
    art:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    tile.Icon = tile:CreateTexture(nil, "ARTWORK")
    tile.Icon:SetAllPoints()
    tile.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    -- The quality mark and the count over it, by the icons' rules
    -- (RV.PlaceMark, RV.PlaceCount, from Fan.Place at the tile's size), on
    -- a frame over the tile: a level above every tile, as the mark
    -- overhangs its tile's corner.
    local over = CreateFrame("Frame", nil, tile)
    over:SetAllPoints(tile)
    tile.Mark, tile.MarkShadow = RV.NewMark(over)
    tile.Count = T.CreateText(over, "numberSmall", "OVERLAY")
    tile.Count:SetDrawLayer("OVERLAY", 7)
    local warning = ProbeAtlas(T.AtlasSets.warning)
    if warning then
      tile.Warn = tile:CreateTexture(nil, "OVERLAY", nil, 2)
      tile.Warn:SetAtlas(warning, false)
      tile.Warn:SetSize(ROW_WARNING + 1, ROW_WARNING + 1)
    else
      tile.Warn = T.CreateText(tile, "value")
      tile.Warn:SetText(WARNING_GLYPH)
    end
    tile.Warn:SetPoint("TOPRIGHT", tile, "TOPRIGHT", -1, -1)
    T.SetColor(tile.Warn, "warning")
    tile.Warn:Hide()
    local highlight = tile:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")
    T.ApplySlot(tile)
    -- From under the icon to its place, fading in, eased out.
    local slide = tile:CreateAnimationGroup()
    local move = slide:CreateAnimation("Translation")
    move:SetDuration(Fan.SLIDE)
    move:SetSmoothing("OUT")
    local fade = slide:CreateAnimation("Alpha")
    fade:SetFromAlpha(0)
    fade:SetToAlpha(1)
    fade:SetDuration(Fan.SLIDE)
    slide:SetToFinalAlpha(true)
    slide:SetScript("OnFinished", Fan.Landed)
    slide.tile = tile
    tile.Slide, tile.Move, tile.Fade = slide, move, fade
    tile:SetScript("OnEnter", Fan.TileEnter)
    tile:SetScript("OnLeave", Fan.TileLeave)
    tile:SetScript("OnClick", Fan.TileClick)
    Fan.tiles[i] = tile
    return tile
  end

  -- tile, texture, count text, mark, why -> the tile as it should read;
  -- whether anything about it changed. Only what changed is set.
  function Fan.Paint(tile, texture, text, mark, why)
    local atlas = RV.AtlasOf(mark)
    local dim = why ~= nil
    if tile.pbTex == texture and tile.pbText == text and tile.pbAtlas == atlas and tile.pbDim == dim then
      return false
    end
    tile.pbTex, tile.pbText, tile.pbAtlas, tile.pbDim = texture, text, atlas, dim
    tile.Icon:SetTexture(texture)
    tile.Count:SetText(text)
    RV.ShowMark(tile.Mark, tile.MarkShadow, atlas)
    -- Dimmed in colour and alpha together, so it reads at any opacity.
    tile.Icon:SetDesaturated(dim)
    tile.Icon:SetVertexColor(dim and 0.6 or 1, dim and 0.6 or 1, dim and 0.6 or 1)
    tile.Icon:SetAlpha(dim and 0.6 or 1)
    tile.Warn:SetShown(dim)
    return true
  end

  -- index[, row] -> the tiles for the mail as it is now, gold first; how
  -- many, and whether anything differs from what they showed. With a source
  -- open (Fan.src), the remembered mail `row` shows, as the source tells it
  -- -- a tile's `slot` is then the item's place in the mail's list -- with
  -- nothing refused and nothing held back by full bags: nothing is taken.
  function Fan.Fill(index, row)
    local plate = Fan.plate
    local src = Fan.src
    local money, cod, items
    if src then
      money, cod, items = src.Totals(row)
    else
      local _, _, _, _, m, c = GetInboxHeaderInfo(index)
      money, cod = tonumber(m) or 0, tonumber(c) or 0
    end
    local n, changed = 0, false
    if money > 0 then
      n = 1
      local tile = Fan.Tile(1)
      if not tile.gold then changed = true end
      tile.gold, tile.slot, tile.why = true, nil, nil
      if Fan.Paint(tile, Fan.COIN, Fan.MoneyText(false, money), nil, nil) then changed = true end
    end
    local marks = RV.MarkOnIcon()
    if src then
      for k = 1, items do
        local texture, count, mark = src.Item(row, k)
        if texture then
          n = n + 1
          local tile = Fan.Tile(n)
          if tile.gold or tile.slot ~= k then changed = true end
          tile.gold, tile.slot, tile.why = false, k, nil
          if Fan.Paint(tile, texture, RV.CountText(count) or "", marks and mark or nil, nil) then changed = true end
        end
      end
    else
      local bags = Mail().BagsFull()
      for slot = 1, Mail().MAX_ATTACHMENTS do
        local _, _, texture, count = GetInboxItem(index, slot)
        if texture then
          n = n + 1
          local tile = Fan.Tile(n)
          if tile.gold or tile.slot ~= slot then changed = true end
          tile.gold, tile.slot = false, slot
          local link = GetInboxItemLink(index, slot)
          local refused = link and Fan.refused[link] or nil
          tile.why = refused or (bags and "bags") or nil
          local mark = marks and RV.QualityMark(index, slot) or nil
          if Fan.Paint(tile, texture, RV.CountText(count) or "", mark, tile.why) then changed = true end
        end
      end
    end
    if n ~= Fan.n then changed = true end
    for i = n + 1, #Fan.tiles do
      local tile = Fan.tiles[i]
      tile.gold, tile.slot, tile.why = false, nil, nil
      tile:Hide()
    end
    local codShown = cod > 0
    if codShown then plate.Cod:SetText(Fan.MoneyText(true, cod)) end
    if codShown ~= plate.codShown then
      changed = true
      plate.codShown = codShown
      plate.Cod:SetShown(codShown)
    end
    Fan.n = n
    return n, changed
  end

  -- An animation group that ran, or one stopped: its tile at its place.
  function Fan.Landed(slide)
    local tile = slide.tile
    tile:ClearAllPoints()
    tile:SetPoint("TOPLEFT", Fan.plate, "TOPLEFT", tile.fx or 0, tile.fy or 0)
    tile:SetAlpha(1)
  end

  -- row, n, animate -> the plate and its n tiles placed by the rules above;
  -- false where the geometry is not known yet.
  function Fan.Place(row, n, animate)
    local plate, P, G = Fan.plate, Fan.PAD, Fan.TILE_GAP
    local scroll = Fan.scroll
    local icon = row.Icon
    local sL, sR, sT, sB = scroll:GetLeft(), scroll:GetRight(), scroll:GetTop(), scroll:GetBottom()
    local iL, iR = icon:GetLeft(), icon:GetRight()
    local rT, rB = row:GetTop(), row:GetBottom()
    if not (sL and sR and sT and sB and iL and iR and rT and rB) then return false end
    local size = row._compact and Fan.TILE or Fan.TILE_LARGE
    local step = size + G
    -- The icon in the list's far half stands at the row's end: leftward.
    local leftward = (iL + iR) > (sL + sR)
    local room = leftward and (iL - Fan.GAP - sL) or (sR - iR - Fan.GAP)
    local per = floor((room - 2 * P + G) / step)
    if per < min(n, Fan.MIN_LINE) then per = floor((sR - sL - 2 * P + G) / step) end
    per = max(1, min(Fan.PER_LINE, per, n))
    local lines = ceil(n / per)
    local codH, codW = 0, 0
    if plate.codShown then
      codH = ceil(plate.Cod:GetStringHeight() or 0) + 2
      codW = Th().TextWidth(plate.Cod) + 2 * P + 2
    end
    local w = max(2 * P + per * size + (per - 1) * G, codW)
    local h = 2 * P + lines * size + (lines - 1) * G + codH
    local x = leftward and (iL - Fan.GAP - w - sL) or (iR + Fan.GAP - sL)
    x = max(0, min(x, (sR - sL) - w))
    -- The tiles centred on the row, the C.O.D. line above them.
    local mid = (rT + rB) / 2
    local y = max(0, min(sT - (mid + (h - codH) / 2 + codH), (sT - sB) - h))
    plate:ClearAllPoints()
    plate:SetPoint("TOPLEFT", scroll, "TOPLEFT", x, -y)
    plate:SetSize(w, h)
    -- The hit area reaches back over the gap to the icon, so the step from
    -- one to the other crosses no dead strip.
    if leftward then plate:SetHitRectInsets(0, -Fan.GAP, 0, 0) else plate:SetHitRectInsets(-Fan.GAP, 0, 0, 0) end
    -- Where a tile starts its slide: under the icon, in the plate's terms.
    local sx = (iL + iR) / 2 - size / 2 - (sL + x)
    local sy = mid + size / 2 - (sT - y)
    local most = Fan.LAND_BY - Fan.SLIDE
    for k = 1, n do
      local tile = Fan.tiles[k]
      local line, col = floor((k - 1) / per), (k - 1) % per
      if leftward then col = per - 1 - col end
      tile:SetSize(size, size)
      -- The mark and the count follow the tile's size (Larger mail rows'
      -- tiles are larger), each placed again only when that, or the mark's
      -- rule, changed.
      RV.PlaceMark(tile.Mark, tile.MarkShadow, tile.Icon, size)
      if tile.pbSize ~= size then
        tile.pbSize = size
        RV.PlaceCount(tile.Count, tile.Icon, size)
      end
      tile.fx, tile.fy = P + col * step, -(P + codH + line * step)
      tile.Slide:Stop()
      if animate then
        tile:ClearAllPoints()
        tile:SetPoint("TOPLEFT", plate, "TOPLEFT", sx, sy)
        tile.Move:SetOffset(tile.fx - sx, tile.fy - sy)
        local delay = min((k - 1) * Fan.STAGGER, most)
        tile.Move:SetStartDelay(delay)
        tile.Fade:SetStartDelay(delay)
        tile:SetAlpha(0)
        tile:Show()
        tile.Slide:Play()
      else
        Fan.Landed(tile.Slide)
        tile:Show()
      end
    end
    return true
  end

  function Fan.Open(row)
    local panel = row.panel
    local src = row.fanSource
    local index
    if not src then
      index = LiveIndex(row)
      if not index then return end
    end
    local scroll = Fan.ScrollOf(row)
    if not scroll then return end
    Fan.Use(scroll, panel)
    local plate = Fan.plate
    -- The remembered mail it shows, or none: the inbox's.
    Fan.src, Fan.mail = src, src and row.mail or nil
    if src then
      -- Nothing here names an inbox mail: nothing can be taken from it.
      plate.mailIndex, plate.fingerprint, plate._paidTake = nil, nil, nil
    else
      -- Another mail: the refusals and the History record were the last one's.
      if Fan.fp ~= row.fingerprint or Fan.index ~= index then
        for key in pairs(Fan.refused) do Fan.refused[key] = nil end
        Fan.fp, Fan.index, Fan.history, Fan.bagsWhy = row.fingerprint, index, nil, nil
      end
      plate.mailIndex, plate.fingerprint, plate._paidTake = index, row.fingerprint, nil
    end
    if Fan.Fill(index, row) == 0 then return end
    plate.Out:Stop()
    plate.In:Stop()
    if not Fan.Place(row, Fan.n, true) then return end
    Fan.row = row
    Fan.open, RV.fanOpen, Fan.graceOn = true, true, false
    Fan.offset = scroll:GetVerticalScroll()
    plate:SetAlpha(0)
    plate:Show()
    plate.In:Play()
    plate:RegisterEvent("GLOBAL_MOUSE_DOWN")
    Th().StyleMailRow(row, row._rowIndex, true)
  end

  -- [instant] -> the fan closed: faded out, or at once where it is hidden
  -- anyway or its row has gone (a scroll, the reading view, the tab). A
  -- pending rest is dropped too.
  function Fan.Close(instant)
    Fan.armRow = nil
    if not Fan.open then
      -- Still fading out as the tab hides: gone now, or it would come back
      -- with the tab (a stopped fade leaves the plate as it was).
      local plate = Fan.plate
      if instant and plate and plate:IsShown() then
        plate.Out:Stop()
        plate:Hide()
      end
      return
    end
    Fan.open, RV.fanOpen, Fan.graceOn = false, false, false
    Fan.closedAt = GetTime()
    local plate, row = Fan.plate, Fan.row
    Fan.row = nil
    plate:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    for i = 1, Fan.n do
      local tile = Fan.tiles[i]
      tile.Slide:Stop()
      Fan.Landed(tile.Slide)
    end
    local owner = GameTooltip.GetOwner and GameTooltip:GetOwner()
    if owner and (owner == plate or owner:GetParent() == plate) then GameTooltip:Hide() end
    if row and not row:IsMouseOver() then Th().StyleMailRow(row, row._rowIndex, false) end
    plate.In:Stop()
    if instant or not plate:IsVisible() then
      plate.Out:Stop()
      plate:Hide()
    else
      plate.Out:Play()
    end
  end

  function Fan.FadedOut()
    if not Fan.open then Fan.plate:Hide() end
  end

  -- The pointer is on the icon, the plate or a tile: no grace running, and
  -- the row painted as hovered while its fan is out.
  function Fan.Hold()
    Fan.graceOn = false
    local row = Fan.row
    if row then Th().StyleMailRow(row, row._rowIndex, true) end
  end

  -- The pointer left one of them: closed after the grace unless it is on
  -- another by then.
  function Fan.Leaving()
    if not Fan.open then return end
    Fan.graceOn = true
    Fan.graceN = Fan.graceN + 1
    C_Timer.After(Fan.GRACE, Fan.GraceDue)
  end

  function Fan.GraceDue()
    Fan.graceFireN = Fan.graceFireN + 1
    if Fan.graceFireN ~= Fan.graceN or not (Fan.open and Fan.graceOn) then return end
    local row = Fan.row
    if Fan.plate:IsMouseOver() or (row and row.IconHit:IsMouseOver()) then
      Fan.graceOn = false
      return
    end
    Fan.Close()
  end

  -- The rest is over: the fan opens if the pointer is still on the icon of
  -- the mail it rested on and nothing has come to stop it. Only the last
  -- rest's timer counts.
  function Fan.Due()
    Fan.fireN = Fan.fireN + 1
    if Fan.fireN ~= Fan.armN then return end
    local row = Fan.armRow
    Fan.armRow = nil
    if not row or Fan.open or Fan.Identity(row) ~= Fan.armFp then return end
    if not row.IconHit:IsMouseOver() then return end
    if not (Fan.Wanted() and Fan.MayOpen(row)) then return end
    Fan.Open(row)
  end

  -- A press while it is open: anywhere but the plate closes it.
  function Fan.MouseDown(plate, event)
    if event ~= "GLOBAL_MOUSE_DOWN" or not Fan.open or plate:IsMouseOver() then return end
    Fan.Close()
  end

  -- Hovering a tile: the item's own tooltip (SetInboxItem, by mail and
  -- slot, the mail checked on every hover), or the gold's sum, and what a
  -- click does -- or why it does nothing. Above the plate, or under it
  -- where the list has no room above; never over the other tiles.
  function Fan.TileEnter(tile)
    Fan.Hold()
    if not Fan.open then return end
    local plate = Fan.plate
    -- A remembered mail's tile: what its source says, and where it can be
    -- taken.
    if Fan.src then
      GameTooltip:SetOwner(tile, "ANCHOR_NONE")
      GameTooltip:ClearLines()
      Fan.src.TileTip(Fan.row, not tile.gold and tile.slot or nil)
      GameTooltip:Show()
      Fan.PlaceTip(plate)
      return
    end
    local index = LiveIndex(plate)
    if not index then return end
    GameTooltip:SetOwner(tile, "ANCHOR_NONE")
    GameTooltip:ClearLines()
    if tile.gold then
      local _, _, _, _, money = GetInboxHeaderInfo(index)
      GameTooltip:SetText(L()["LABEL_GOLD"] .. Helpers().FormatMoney(tonumber(money) or 0), 1, 1, 1)
      GameTooltip:AddLine(L()["FAN_GOLD_HINT"], 0.7, 0.7, 0.7)
    else
      if type(GameTooltip.SetInboxItem) == "function" then GameTooltip:SetInboxItem(index, tile.slot) end
      if tile.why then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(Th().Colorize("warning", Fan.Why(tile.why)), 1, 1, 1, true)
      else
        GameTooltip:AddLine(L()["FAN_TILE_HINT"], 0.7, 0.7, 0.7)
      end
    end
    GameTooltip:Show()
    Fan.PlaceTip(plate)
  end

  -- why -> the reason line: the game's words where it gave any.
  function Fan.Why(why)
    if why == "bags" then
      local words = Fan.bagsWhy
      if type(words) == "string" and words ~= "" then return StuckLine(words) end
      return L()["FAN_TILE_BAGS"]
    end
    return StuckLine(why)
  end

  function Fan.PlaceTip(plate)
    local scroll = Fan.scroll
    local top, sTop = plate:GetTop(), scroll:GetTop()
    local ps, ts = plate:GetEffectiveScale(), GameTooltip:GetEffectiveScale()
    GameTooltip:ClearAllPoints()
    local below = false
    if top and sTop and ps and ts and ps > 0 then
      below = top + 2 + (GameTooltip:GetHeight() or 0) * ts / ps > sTop
    end
    if below then
      GameTooltip:SetPoint("TOPLEFT", plate, "BOTTOMLEFT", 0, -2)
    else
      GameTooltip:SetPoint("BOTTOMLEFT", plate, "TOPLEFT", 0, 2)
    end
  end

  function Fan.TileLeave()
    GameTooltip:Hide()
    Fan.Leaving()
  end

  -- A click on a tile. Modified, the game's item rules, as on its own mail
  -- tiles (the link where the body is not loaded yet is the item's own, by
  -- id); plain, the take, unless the tile says why not; right, nothing. On a
  -- remembered mail's tile there is nothing to take: a plain click does
  -- nothing, a modified one follows the game's item rules on the link its
  -- source gives, and the gold tile swallows both.
  function Fan.TileClick(tile, button)
    if not Fan.open or button ~= "LeftButton" then return end
    local plate = Fan.plate
    if Fan.src then
      if not tile.gold and RV.Modified() and type(HandleModifiedItemClick) == "function" then
        local link = Fan.src.Link(Fan.row, tile.slot)
        if link then HandleModifiedItemClick(link) end
      end
      return
    end
    local index = LiveIndex(plate)
    if not index then return end
    if RV.ModifiedItemClick(index, not tile.gold and tile.slot or nil) then return end
    if tile.gold then return Fan.TakeGold(plate, index) end
    if tile.why then return end
    Fan.TakeItem(plate, index, tile.slot)
  end

  -- One History record for the fan's mail, however many takes follow.
  function Fan.Record(index)
    if not Fan.history and Mail().HistoryRecord then Fan.history = Mail().HistoryRecord(index) end
    return Fan.history
  end

  -- The reading view's tile take (TakeOneAttachment), from the plate: the
  -- C.O.D. confirmed first, the mail re-checked after the wait, the take
  -- that pays armed so the fan follows the paid mail, the body fetched
  -- first where it never was.
  --
  -- The take is aimed at the mail the tile was clicked on, by the index
  -- and fingerprint read at the click. The question is not modal and the
  -- plate is re-bound whenever the fan opens over another mail, so what
  -- the plate names after the wait is not evidence of anything: the take
  -- goes only while the plate still shows that same mail at that index,
  -- and ConfirmCOD has checked the inbox itself.
  function Fan.TakeItem(plate, index, slot)
    local panel = plate._panel
    local clicked = plate.fingerprint
    ConfirmCOD(index, function()
      if plate.mailIndex ~= index or plate.fingerprint ~= clicked or LiveIndex(plate) ~= index then return end
      local _, _, _, _, _, codBefore = GetInboxHeaderInfo(index)
      codBefore = tonumber(codBefore) or 0
      local paying = RV.ArmPaidTake(plate, index, codBefore)
      local record = Fan.Record(index)
      -- What Delete when done checks the mail against once the take is done,
      -- as a row click's collect does (RV.AutoDelete).
      local before = RV.Before(index)
      Mail().TakeAttachment(index, slot, function(status, refused, reason, kind)
        if RV.SettlePaidTake(plate, paying, status == "collected") then Fan.fp = plate.fingerprint end
        if status == "busy" then return end
        if status == "closed" then
          StatusMailboxClosed()
          return
        end
        if status == "timeout" then
          ns.Print(L()["MSG_MAIL_TIMEOUT"])
          return
        end
        if status == "refused" or (tonumber(refused) or 0) > 0 then
          ns.Print(ItemRefusedMessage(reason))
          -- Bags full dims every item (Mail.BagsFull); anything else, the
          -- item refused, by its link, which the take has loaded.
          if kind == "bags" then
            Fan.bagsWhy = reason
          else
            local live = LiveIndex(plate)
            local link = live and GetInboxItemLink(live, slot)
            if link then Fan.refused[link] = reason or true end
          end
          RefreshIdleSummary()
          RV.FanCheck(panel)
          return
        end
        -- Paid only once the mail no longer reads as owing it (RV.CODPaid):
        -- a take that found no link loaded answers "collected" too.
        if codBefore > 0 and RV.CODPaid(index, clicked) then
          ns.Print(L()("MSG_COD_PAID", Helpers().FormatMoney(codBefore)))
        end
        -- The last tile of a letter emptied tile by tile: in the "delete"
        -- read-mail mode it goes now, as a collected mail does. Only a mail
        -- that reads finished is touched (RV.AutoDelete).
        RV.AutoDelete(panel, index, before, record)
        -- The row pass redraws the fan from the mailbox (RV.FanCheck): a take
        -- can move the other items down a slot.
        RequestRefresh(panel)
      end, { allowCOD = true, history = record, fetch = true })
    end)
  end

  -- The reading view's coin tile, from the plate.
  function Fan.TakeGold(plate, index)
    local panel = plate._panel
    local record = Fan.Record(index)
    local before = RV.Before(index)
    Mail().TakeMoney(index, function(status)
      if status == "busy" then return end
      if status == "closed" then
        StatusMailboxClosed()
        return
      end
      if status == "timeout" then
        ns.Print(L()["MSG_MAIL_TIMEOUT"])
        return
      end
      -- The gold the last thing left in it: Delete when done, as above.
      if status == "done" then RV.AutoDelete(panel, index, before, record) end
      RequestRefresh(panel)
    end, record)
  end

  -- row -> whether the fan answers the icon's hover: a rest begun, or the
  -- fan already out over this row, or opened at once when one closed a
  -- moment ago (as tooltips do). False, and the icon shows its tooltip.
  function RV.FanHover(row)
    if not (Fan.Wanted() and Fan.MayOpen(row)) then return false end
    if Fan.open then
      if Fan.row == row then
        Fan.Hold()
        return true
      end
      Fan.Close(true)
    end
    if GetTime() - Fan.closedAt < Fan.QUICK then
      Fan.Open(row)
      if Fan.open then return true end
    end
    Fan.armRow, Fan.armFp = row, Fan.Identity(row)
    Fan.armN = Fan.armN + 1
    C_Timer.After(Fan.DWELL, Fan.Due)
    return true
  end

  -- The pointer left a row's icon: its rest is over, and its fan's grace
  -- begins.
  function RV.FanLeave(row)
    if Fan.armRow == row then Fan.armRow = nil end
    if Fan.open and Fan.row == row then Fan.Leaving() end
  end

  RV.FanClose = Fan.Close
  function CT.CloseFan() Fan.Close(true) end

  -- The list scrolled: the row under the fan holds other mail now.
  function RV.FanScrolled(scroll)
    if not Fan.open or scroll ~= Fan.scroll then return end
    if scroll:GetVerticalScroll() ~= Fan.offset then Fan.Close(true) end
  end

  -- The list went away (its window hid): a fan standing in it goes with it.
  function RV.FanGone(scroll)
    if Fan.open and scroll == Fan.scroll then Fan.Close(true) end
  end

  -- After every row pass while a fan is open: its row still holding its
  -- mail (or that mail as its confirmed take paid it), it is drawn again as
  -- the mail now is, and placed again where anything changed; its row bound
  -- to other mail, the mail empty, or a state it cannot stand in, it closes.
  -- Over remembered mail, which does not change, it stays while its row
  -- still shows that mail and the fan may stand there, from any list's pass
  -- (`panel` nil: Mail Memory's window).
  function RV.FanCheck(panel)
    if not Fan.open then return end
    local plate, row = Fan.plate, Fan.row
    if Fan.src then
      if not (row and row:IsShown() and row.mail == Fan.mail and Fan.Wanted() and Fan.Allowed(row)) then
        Fan.Close(true)
      end
      return
    end
    if plate._panel ~= panel then return end
    if not (row and row:IsShown() and row.mailIndex == plate.mailIndex) then return Fan.Close(true) end
    if row.fingerprint ~= plate.fingerprint and not RV.AwaitsPaidTake(plate) then return Fan.Close(true) end
    if not (Fan.Wanted() and Fan.Allowed(row)) then return Fan.Close(true) end
    local index = LiveIndex(row)
    if not index then return Fan.Close(true) end
    local n, changed = Fan.Fill(index)
    if n == 0 then return Fan.Close() end
    if changed then Fan.Place(row, n, false) end
  end

  -- Mail Memory's rows open the fan over remembered mail too, read-only
  -- (MailMemory.lua, MM.FanSource), through the row rules it draws with.
  CT.RowRules.FanHover, CT.RowRules.FanLeave, CT.RowRules.FanCheck = RV.FanHover, RV.FanLeave, RV.FanCheck
  CT.RowRules.FanScrolled, CT.RowRules.FanGone = RV.FanScrolled, RV.FanGone
end

local function LayoutPanel(panel)
  LayoutViewToggle(panel)
  RV.PlaceStack(panel)
  LayoutGrid(panel)
  if panel.Detail then LayoutDetail(panel.Detail) end
end

function CT.Build(parent)
  local T = ns.Theme
  local M = T.Metrics

  local panel = CreateFrame("Frame", nil, parent)
  panel:SetAllPoints()
  panel.viewMode = VIEW_COLLECT
  panel._filtered = {}
  -- Parallel to _filtered: the list walk's verdict for each listed mail, so the
  -- row binder can dress a row from the mail rather than from the view.
  panel._filteredDone = {}
  panel._rows = {}
  panel._rowParts = {}
  -- The figures an option took off a row, for its tooltip.
  panel._rowFacts = {}
  -- The two-line row's figure texts, in the arrangement's order.
  panel._rowTexts = {}
  -- Which part each piece of the two-line row's second line is.
  panel._rowPartIds = {}
  -- What RV.Place is handed for each mail row, and for each History row.
  panel._rowSpec = RV.NewSpec()
  panel._histSpec = RV.NewSpec()
  -- The list's column widths and reserve, measured by RefreshMailList for
  -- every row it binds (see "the columns").
  panel._cols = {}
  -- Which figures a read mail listed with its delete mark draws, and
  -- whether one is listed at all (RV.MarkReserve), from the same walk.
  panel._markHas, panel._markAny = {}, false
  -- What each category button would collect right now, from the same walk.
  panel._catCounts = {}
  -- The inbox's finished mails, gathered by the walk to go after the divider.
  panel._tail = {}
  panel._tailDone = {}
  -- The history view: its listed entries, row pool and columns.
  panel._history = {}
  panel._hrows = {}
  panel._hheads = {}
  panel._hcols = {}
  -- Another character's box: its row pool (Mail Memory's rows).
  panel._avPool = {}

  panel._rowTip = {}
  -- Top row: the view switch, the search box at the far right, and the hint
  -- between them.
  BuildViewToggle(panel)
  BuildSearchBox(panel)

  -- Blank until something needs saying: this line's only remaining job is
  -- the truncated-inbox notice (see UpdateHint).
  panel.Hint = T.CreateText(panel, "secondary")
  panel.Hint:SetPoint("LEFT", panel.ViewToggle, "RIGHT", M.gap, 0)
  panel.Hint:SetPoint("RIGHT", panel.SearchWrap, "LEFT", -M.gap, 0)
  panel.Hint:SetJustifyH("RIGHT")
  panel.Hint:SetWordWrap(false)
  panel.Hint:SetText("")

  -- Bottom: one footer holding the blocks under the list -- the totals band,
  -- the primary's slot and the category grid, in the player's order (RV,
  -- "The blocks under the list"). Its height is the only thing a view change
  -- moves.
  panel.Footer = CreateFrame("Frame", nil, panel)
  panel.Footer:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", M.inset, M.inset)
  panel.Footer:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -M.inset, M.inset)
  panel.Footer:SetHeight(FooterHeight(panel))

  BuildGrid(panel)

  -- The history view has nothing to act on, so its footer says what the list
  -- is instead: whose, and how far back.
  panel.HistoryNote = T.CreateText(panel.Footer, "secondary")
  panel.HistoryNote:SetPoint("LEFT", panel.Footer, "LEFT", M.inset, 0)
  panel.HistoryNote:SetPoint("RIGHT", panel.Footer, "RIGHT", -M.inset, 0)
  panel.HistoryNote:SetJustifyH("CENTER")
  panel.HistoryNote:SetWordWrap(false)
  panel.HistoryNote:SetText(ns.Plural("HISTORY_NOTE", HV.Days()))
  panel.HistoryNote:Hide()

  -- The Done view's footer: its one action, full width, where the inbox has
  -- its primary.
  panel.DoneFooter = T.CreateButton(nil, panel.Footer)
  panel.DoneFooter:SetPoint("TOPLEFT", panel.Footer, "TOPLEFT", 0, 0)
  panel.DoneFooter:SetPoint("TOPRIGHT", panel.Footer, "TOPRIGHT", 0, 0)
  panel.DoneFooter:SetHeight(GRID_PRIMARY_HEIGHT)
  panel.DoneFooter:SetText(L()["BTN_DELETE_ALL_DONE"])
  panel.DoneFooter:SetScript("OnClick", function() DeleteAllDone(panel) end)
  panel.DoneFooter:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L()["BTN_DELETE_ALL_DONE"])
    GameTooltip:AddLine(RawKey("HINT_DELETE_READ") or "", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  panel.DoneFooter:SetScript("OnLeave", function() GameTooltip:Hide() end)
  panel.DoneFooter:Hide()

  -- Under another character's box: whose it is, when it was seen, and where
  -- to go to collect it -- nothing here can.
  panel.AltNote = T.CreateText(panel.Footer, "secondary")
  panel.AltNote:SetPoint("LEFT", panel.Footer, "LEFT", M.inset, 0)
  panel.AltNote:SetPoint("RIGHT", panel.Footer, "RIGHT", -M.inset, 0)
  panel.AltNote:SetJustifyH("CENTER")
  panel.AltNote:SetWordWrap(false)
  panel.AltNote:Hide()


  -- The totals banner: a divider, not a panel, aligned to the same inset as the
  -- grid below it so the columns line up. Its fill is `bandFill`, which is held
  -- at the plate opacity floor -- it carries the run's gold earned/spent
  -- figures, and a text-bearing surface may not depend on the window's own fill
  -- to stay legible. It is a block of the stack under the list, which the
  -- footer holds: placed from the footer's top by RV.PlaceStack, and at its
  -- top until then, which is where the default order has it.
  panel.Banner = CreateFrame("Frame", nil, panel, "BackdropTemplate")
  panel.Banner:SetPoint("TOPLEFT", panel.Footer, "TOPLEFT", 0, 0)
  panel.Banner:SetPoint("TOPRIGHT", panel.Footer, "TOPRIGHT", 0, 0)
  panel.Banner:SetHeight(M.controlHeight)
  T.ApplyBand(panel.Banner)

  panel.BannerText = T.CreateText(panel.Banner, "value")
  -- One anchor and an explicit width (set by FitBanner from the band's
  -- width), not a right anchor: the fit has to know exactly what room the
  -- string has, and has to be able to make the string honour it. Centred
  -- in the band: two sums with their own coins need no coin at the edge
  -- to introduce them, and a line that starts at the left edge of a wide
  -- band reads as a label rather than a total.
  panel.BannerText:SetPoint("LEFT", panel.Banner, "LEFT", M.inset, 0)
  panel.BannerText:SetJustifyH("CENTER")
  -- A font string never clips its own text: with wrapping off, a line
  -- wider than the string simply runs past it (which is what was seen).
  -- Wrapping ON with one line allowed is the client's own way to hold a
  -- line to a width -- whatever does not fit goes to a second line that is
  -- not drawn, an ellipsis marks the cut, and IsTruncated() says so.
  panel.BannerText:SetWordWrap(true)
  panel.BannerText:SetNonSpaceWrap(false)
  panel.BannerText:SetMaxLines(1)
  panel._bannerTextLeft  = M.inset
  panel._bannerTextRight = M.inset
  -- The sums are re-fitted to whatever width the band ends up with: the
  -- window resizing, or the first layout after a paint that had none.
  panel.Banner:SetScript("OnSizeChanged", function() FitBanner(panel) end)

  -- The list absorbs everything between the top row and the blocks under it.
  panel.MailListArea = CreateFrame("Frame", nil, panel, "BackdropTemplate")
  panel.MailListArea:SetPoint("TOPLEFT", panel.ViewToggle, "BOTTOMLEFT", 0, -M.gap)
  panel.MailListArea:SetPoint("RIGHT", panel, "RIGHT", -M.inset, 0)
  panel.MailListArea:SetPoint("BOTTOM", panel.Footer, "TOP", 0, M.gap)
  T.ApplyList(panel.MailListArea)

  -- The list runs to the container's inner edge while nothing scrolls, and
  -- stops a gutter short of it only while the bar is there (Theme's slim bar
  -- calls this as it shows and hides). Set before the bar is built: the
  -- build's own first show calls it too.
  local scroll = CreateFrame("ScrollFrame", nil, panel.MailListArea, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", panel.MailListArea, "TOPLEFT", M.tightGap, -M.tightGap)
  scroll:SetPoint("BOTTOMRIGHT", panel.MailListArea, "BOTTOMRIGHT", -M.scrollGutter, M.tightGap)
  scroll.__pbGutter = function(scrolling)
    scroll:SetPoint("BOTTOMRIGHT", panel.MailListArea, "BOTTOMRIGHT",
      -(scrolling and M.scrollGutter or M.tightGap), M.tightGap)
  end
  PinScrollBar(scroll, panel.MailListArea)
  -- The rows end at the list's edge. A row partly scrolled out drew on past
  -- it, into the padding under the pinned divider and below the list.
  if scroll.SetClipsChildren then scroll:SetClipsChildren(true) end
  panel.MailListScroll = scroll

  panel.MailListChild = CreateFrame("Frame", nil, scroll)
  -- The scroll frame has no measured width until the first layout pass; the
  -- child must not start wider than it, or the list scrolls sideways.
  local childWidth = scroll:GetWidth() or 0
  if childWidth <= 10 then childWidth = FALLBACK_PANEL_WIDTH - M.scrollGutter end
  panel.MailListChild:SetSize(childWidth, 1)
  scroll:SetScrollChild(panel.MailListChild)

  -- The inbox divider: "Read, nothing left (3)" with their delete at its right.
  -- A row's slot in the list, so the virtualiser places it like one; its own
  -- frame, because nothing about it is a mail.
  local divider = RV.BuildDivider(panel, panel.MailListChild)
  -- A click folds the read mail away or brings it back, and it stays so.
  divider:SetScript("OnClick", function()
    -- A search shows it regardless; a click then would flip it unseen. The
    -- arrange mode's list folds nothing either.
    if Searching(panel) or RV.Arranging(panel) then return end
    RV.SetFolded(not RV.Folded(panel))
    CT.RefreshMailList(panel)
  end)
  panel.Divider = divider

  -- Its pinned copy, in the list with the rows, standing at the view's foot
  -- while the divider's own place is further down (RV.UpdatePin). A click
  -- goes to the read mail -- unfolding it if it was folded; its Delete all is
  -- the same Delete all.
  local pin = RV.BuildDivider(panel, panel.MailListChild)
  pin:SetScript("OnClick", function()
    if RV.Arranging(panel) then return end
    if RV.Folded(panel) then
      RV.SetFolded(false)
      CT.RefreshMailList(panel)
    end
    local at = panel._dividerAt
    if not at then return end
    local _, _, stride = RowMetrics()
    local maxScroll = max(0, RV.ListHeight(#panel._filtered, stride) - (scroll:GetHeight() or 0))
    scroll:SetVerticalScroll(min((at - 1) * stride, maxScroll))
    UpdateVisibleRows(panel)
  end)
  panel.DividerPin = pin

  -- The pinned bar's foot: the list's bottom margin under it, painted as the
  -- bar is, so the bar reaches the container's edge instead of stopping the
  -- margin short of it. Outside the scroll area, where nothing scrolls, and
  -- shown only with the bar (RV.UpdatePin).
  local foot = CreateFrame("Frame", nil, panel.MailListArea)
  foot:SetPoint("TOPLEFT", scroll, "BOTTOMLEFT", 0, 0)
  foot:SetPoint("TOPRIGHT", scroll, "BOTTOMRIGHT", 0, 0)
  foot:SetHeight(max(1, M.tightGap - 1))
  foot.Fill = foot:CreateTexture(nil, "BACKGROUND")
  foot.Fill:SetAllPoints()
  Th().FillColor(foot.Fill, "surface", 0.95)
  foot:Hide()
  pin.Foot = foot

  -- HookScript, not SetScript: the template installs its own handlers here and
  -- replacing them desynchronises the scroll bar.
  scroll:HookScript("OnSizeChanged", function(_, width)
    if width and width > 10 then panel.MailListChild:SetWidth(width) end
    UpdateVisibleRows(panel)
  end)
  scroll:HookScript("OnVerticalScroll", function() UpdateVisibleRows(panel) end)
  -- Any scroll closes the fan: its row is bound to other mail.
  scroll:HookScript("OnVerticalScroll", RV.FanScrolled)
  -- After the template's own handler, which sets the bar from the client's
  -- measure of the list (RV.HoldRange).
  scroll:HookScript("OnScrollRangeChanged", RV.HoldRange)

  panel.Empty = T.CreateText(panel.MailListArea, "secondary")
  panel.Empty:SetPoint("TOPLEFT", panel.MailListArea, "TOPLEFT", M.inset * 2, -M.inset * 2)
  panel.Empty:SetPoint("RIGHT", panel.MailListArea, "RIGHT", -M.inset * 2, 0)
  panel.Empty:SetJustifyH("LEFT")
  panel.Empty:Hide()

  BuildDetail(panel)

  -- Synchronous, at the end of build: the grid used to be positioned only by a
  -- size-change hook plus a next-frame callback, so six buttons visibly jumped
  -- into place after the window appeared. Genuine resizes still arrive through
  -- OnSizeChanged.
  LayoutPanel(panel)
  AV.Paint(panel)

  panel:SetScript("OnSizeChanged", function(self) LayoutPanel(self) end)
  panel:SetScript("OnShow", function(self)
    LayoutPanel(self)
    -- Whether there is another character to pick changes between visits.
    AV.Paint(self)
    CT.RefreshMailList(self)
  end)
  panel:SetScript("OnHide", function(self)
    HideDetail(self)
    RV.FanClose(true)
    if ns.MailMemory and ns.MailMemory.ClosePicker then ns.MailMemory.ClosePicker() end
    -- The arrange mode ends with the tab: the Send tab, the window closing,
    -- the mailbox going away.
    if ns.Arrange and ns.Arrange.LeaveIf then ns.Arrange.LeaveIf(self) end
  end)

  return panel
end
