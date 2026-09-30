local _, ns = ...

-- =====================================================================
-- Postbox :: what's new
-- ---------------------------------------------------------------------
-- What an update brings with it, in two small pieces.
--
-- What's new: a small window with each release's highlights -- the
-- changelog's own groups, a line to a highlight, in the player's language
-- -- opened from the notice below, from the options' footer (What's new,
-- and the version beside it) and by /postbox whatsnew.
--
-- The notice: when an update has put the settings back on their defaults
-- (Postbox.lua, 4b, which names the release in PostboxDB.notice), a card
-- stands beside the mail window the first time it opens -- two sentences,
-- What's new and OK. Either button answers it for good; a mailbox closed
-- without an answer shows it again at the next one. It stands outside the
-- window, so nothing the player needs is under it, and it steps aside
-- while the arrange mode's inspector stands beside the window (WN.Aside,
-- from Core/Arrange.lua).
--
-- Nothing here is built until it is shown. With no notice waiting, a
-- mailbox open costs one read of the saved variables' root.
-- =====================================================================

ns.WhatsNew = ns.WhatsNew or {}
local WN = ns.WhatsNew
local L = ns.L

local ceil, max, min = math.ceil, math.max, math.min

-- The notice PostboxDB.notice can name: its release, which is its title,
-- and its words.
local NOTICE = { key = "1.50", text = "NOTICE_150" }

-------------------------------------------------------------
-- 1. The releases
--
-- Newest first: each release is its version and its groups, each group
-- the locale keys of its heading and of its lines (one string, a line to
-- each "\n"). The changelog's own groups, condensed to a line a highlight
-- (.dev/RELEASING.md: the in-game What's new is the same release,
-- condensed and translated). The next release adds its own at the top; an
-- older one stays, or goes when the page grows long. Made when the window
-- is first built, not at load.
-------------------------------------------------------------
local function Releases()
  return {
    { version = "1.50", groups = {
      { "WHATSNEW_150_ARRANGE", "WHATSNEW_150_ARRANGE_LINES" },
      { "WHATSNEW_150_LOOKS", "WHATSNEW_150_LOOKS_LINES" },
      { "WHATSNEW_150_MAILBOX", "WHATSNEW_150_MAILBOX_LINES" },
      { "WHATSNEW_150_HISTORY", "WHATSNEW_150_HISTORY_LINES" },
      { "WHATSNEW_150_SENDING", "WHATSNEW_150_SENDING_LINES" },
      { "WHATSNEW_150_OPTIONS", "WHATSNEW_150_OPTIONS_LINES" },
      { "WHATSNEW_150_UI", "WHATSNEW_150_UI_LINES" },
      { "WHATSNEW_150_LIGHTER", "WHATSNEW_150_LIGHTER_LINES" },
      { "WHATSNEW_150_FIXED", "WHATSNEW_150_FIXED_LINES" },
    } },
  }
end

-------------------------------------------------------------
-- 2. The window
--
-- A window of the house's own kind, as the bug report is: the template,
-- the theme and whichever skin paints those, the window scale, Escape and
-- its close button, and never see-through: it is read to the letter at
-- any window opacity. As wide as a comfortable line and as tall as its
-- pages, up to MAX_H; past that the pages scroll, and the slim bar shows
-- only then. Laid out on every open, after the skin's pass: a host skin
-- can re-font it after it is built.
-------------------------------------------------------------
local WIN = {
  W = 400, MAX_H = 560,    -- at 130%, still inside a 768-unit screen
  TOP = 30,                -- under the template's title bar
  EDGE = 10,               -- the card in from the window's edges
  PAD_X = 10, PAD_Y = 8,   -- the pages in from the card's
  BULLET = 12,             -- a line's words in from its bullet
  RELEASE_GAP = 16,        -- one release's pages to the next
  TITLE_GAP = 6,           -- a release's title to its first heading
  GROUP_GAP = 10,          -- a group's last line to the next heading
  LINE_GAP = 2,            -- a heading to its first line, and line to line
}
local BULLET = "\226\128\162"
local win

-- The pages' width: the window's, less the card's edges, the text's own
-- inset and the scroll bar's gutter, which is theirs whether it shows or not.
local function PageWidth()
  return WIN.W - 2 * WIN.EDGE - WIN.PAD_X - ns.Theme.Metrics.scrollGutter
end

local function BuildWindow()
  local T = ns.Theme

  -- Named: Escape closes it through UISpecialFrames, a list of names.
  local f = CreateFrame("Frame", "PostboxWhatsNewFrame", UIParent, "BasicFrameTemplateWithInset")
  f:SetSize(WIN.W, 300)
  -- The options panel's strata, so it opens over the panel it is asked from.
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:Hide()
  -- Solid whatever the mailbox window's opacity. Skin.ApplyBgOpacity
  -- honours this flag.
  f.__pbEuiAlwaysOpaque = true
  if f.SetTitle then
    f:SetTitle(L["WHATSNEW_TITLE"])
  elseif f.TitleText then
    f.TitleText:SetText(L["WHATSNEW_TITLE"])
  end
  T.ApplyFrameTheme(f)
  ns.Core.UI.Helpers.RegisterEscClose(f)

  -- The pages on the list surface the bug report's report stands on.
  local card = CreateFrame("Frame", nil, f, "BackdropTemplate")
  card:SetPoint("TOPLEFT", f, "TOPLEFT", WIN.EDGE, -WIN.TOP)
  card:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -WIN.EDGE, WIN.EDGE)
  T.ApplyList(card)

  local scroll = CreateFrame("ScrollFrame", nil, card, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", card, "TOPLEFT", WIN.PAD_X, -1)
  scroll:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -T.Metrics.scrollGutter, 1)
  if scroll.SetClipsChildren then scroll:SetClipsChildren(true) end
  scroll.scrollBarHideable = 1
  T.SlimScrollBar(scroll, card)

  local page = CreateFrame("Frame", nil, scroll)
  page:SetSize(PageWidth(), 10)
  scroll:SetScrollChild(page)

  -- Every text, made once, in reading order: a release's title, then each
  -- group's heading and its lines, each line a bullet and its words.
  local items = {}
  local releases = Releases()
  for r = 1, #releases do
    local release = releases[r]
    local title = T.CreateText(page, "title")
    title:SetJustifyH("LEFT")
    title:SetText(L("WHATSNEW_RELEASE", release.version))
    items[#items + 1] = { kind = "release", text = title }
    local groups = release.groups
    for g = 1, #groups do
      local group = groups[g]
      local heading = T.CreateText(page, "heading")
      heading:SetJustifyH("LEFT")
      heading:SetText(L[group[1]])
      items[#items + 1] = { kind = "heading", text = heading }
      for line in string.gmatch(L[group[2]], "[^\n]+") do
        local dot = T.CreateText(page, "secondary")
        dot:SetText(BULLET)
        local words = T.CreateText(page, "bodySmall")
        words:SetJustifyH("LEFT")
        words:SetWordWrap(true)
        words:SetText(line)
        items[#items + 1] = { kind = "line", text = words, dot = dot }
      end
    end
  end

  f.Scroll, f.Page, f.Items = scroll, page, items
  return f
end

-- Top down, each text at the width it has and the height that gives it;
-- the window as tall as that, up to MAX_H.
local function LayoutWindow(f)
  local width = PageWidth()
  local y, before = WIN.PAD_Y, nil
  local items = f.Items
  for i = 1, #items do
    local item = items[i]
    local kind = item.kind
    if kind == "release" then
      if before then y = y + WIN.RELEASE_GAP end
    elseif kind == "heading" then
      y = y + (before == "release" and WIN.TITLE_GAP or WIN.GROUP_GAP)
    else
      y = y + WIN.LINE_GAP
    end
    local x = (kind == "line") and WIN.BULLET or 0
    local text = item.text
    text:ClearAllPoints()
    text:SetPoint("TOPLEFT", f.Page, "TOPLEFT", x, -y)
    text:SetWidth(width - x)
    if item.dot then
      item.dot:ClearAllPoints()
      item.dot:SetPoint("TOPLEFT", f.Page, "TOPLEFT", 1, -y)
    end
    y = y + ceil(text:GetStringHeight() or 12)
    before = kind
  end
  y = y + WIN.PAD_Y
  f.Page:SetSize(width, y)
  -- The title bar over the card, the edge under it, and the card's own
  -- line above and below the pages.
  f:SetHeight(min(WIN.MAX_H, y + WIN.TOP + WIN.EDGE + 2))
  local T = ns.Theme
  if T and type(T.FitToScreen) == "function" then T.FitToScreen(f) end
  local scroll = f.Scroll
  if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end
  scroll:SetVerticalScroll(0)
end

-- Beside `beside` (the options panel, the mail window) on the side with
-- room, right first -- level with its foot when `foot`, where the footer
-- that opened it sits, else with its top -- or in the middle of the screen.
local function Place(f, beside, foot)
  f:ClearAllPoints()
  local left = beside and beside:IsShown() and beside:GetLeft()
  local right = left and beside:GetRight()
  if not (left and right) then
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    return
  end
  local scale = beside:GetEffectiveScale() or 1
  local own = (f:GetWidth() or WIN.W) * (f:GetEffectiveScale() or 1)
  local screen = (UIParent:GetRight() or 0) * (UIParent:GetEffectiveScale() or 1)
  local edge = foot and "BOTTOM" or "TOP"
  if right * scale + 8 + own > screen and left * scale - 8 - own >= 0 then
    f:SetPoint(edge .. "RIGHT", beside, edge .. "LEFT", -8, 0)
  else
    f:SetPoint(edge .. "LEFT", beside, edge .. "RIGHT", 8, 0)
  end
end

-- Shown (or raised, where it is up) beside `beside`, as Place puts it.
function WN.Open(beside, foot)
  if not win then
    win = BuildWindow()
    -- The same expression as the options panel and the bug report.
    local skin = ns.Skin
    local apply = skin and (skin.ApplyWindow or skin.Apply)
    if apply then apply(win) end
  end
  if win:IsShown() then
    win:Raise()
    return
  end
  win:Show()
  win:Raise()
  local skin = ns.Skin
  if skin and skin.Refresh then pcall(skin.Refresh, win) end
  LayoutWindow(win)
  Place(win, beside, foot)
end

-- The footer's What's new and /postbox whatsnew: open, or closed where open.
function WN.Toggle(beside, foot)
  if win and win:IsShown() then
    win:Hide()
    return
  end
  WN.Open(beside, foot)
end

-------------------------------------------------------------
-- 3. The notice
--
-- A card of the house's (Theme.ApplyCard, which every skin paints as one of
-- Postbox's cards), on the mail window, standing outside it: 8 units out
-- from its right edge, or its left one where the screen has no room on the
-- right, level with its top -- where the arrange inspector stands, so the
-- two never show together. A child of the window, so it wears the window's
-- scale, follows it when it is dragged and goes when it closes. Its fill
-- has the popups' floor under it (__pbPopupAlways), so its words stay
-- solid at any window opacity. As wide as W, or as its two buttons need,
-- and as tall as its words.
-------------------------------------------------------------
local CARD = {
  W = 250, MAX_W = 330,
  PAD = 12,
  TEXT_GAP = 5,            -- the title to the words
  BUTTONS_GAP = 12,        -- the words to the buttons
  BUTTON_H = 22, BUTTON_GAP = 6,
  DOCK = 8,
}
-- A button's size, from its caption.
CARD.FIT = { height = CARD.BUTTON_H, minWidth = 64 }
local card

-- A notice is waiting: the saved one, or /postbox whatsnew notice's.
local function Waiting()
  if WN._test then return true end
  local db = PostboxDB
  return type(db) == "table" and db.notice == NOTICE.key
end

-- Answered, by either button: gone for good, and What's new opened beside
-- the mail window where it was asked for.
local function Answer(openNews)
  WN._test = nil
  local db = PostboxDB
  if type(db) == "table" and db.notice == NOTICE.key then db.notice = nil end
  local frame = card and card:GetParent()
  if card then card:Hide() end
  if openNews then WN.Open(frame, false) end
end

local function BuildCard(frame)
  local T = ns.Theme
  local c = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  -- Over the window's own tabs and cog, which stand ten levels up.
  c:SetFrameLevel(frame:GetFrameLevel() + 20)
  c:SetClampedToScreen(true)
  c:EnableMouse(true)
  c:Hide()
  c.__pbPopupAlways = true
  T.ApplyCard(c)

  local title = T.CreateText(c, "heading")
  title:SetJustifyH("LEFT")
  title:SetWordWrap(false)
  local text = T.CreateText(c, "bodySmall")
  text:SetJustifyH("LEFT")
  text:SetWordWrap(true)

  local news = T.CreateButton(nil, c)
  news:SetText(L["WHATSNEW_TITLE"])
  news:SetScript("OnClick", function() Answer(true) end)
  local ok = T.CreateButton(nil, c)
  ok:SetText(L["NOTICE_OK"])
  ok:SetScript("OnClick", function() Answer(false) end)

  c.Title, c.Text, c.News, c.OK = title, text, news, ok
  return c
end

-- Measured on every show: the skin's pass may have re-fonted it since.
local function LayoutCard(c)
  local T = ns.Theme
  local P = CARD
  local news = T.SizeToText(c.News, P.FIT)
  local ok = T.SizeToText(c.OK, P.FIT)
  local width = max(P.W, min(P.MAX_W, news + P.BUTTON_GAP + ok + 2 * P.PAD))
  local inner = width - 2 * P.PAD
  c:SetWidth(width)

  local title, text = c.Title, c.Text
  title:SetText(L("WHATSNEW_RELEASE", NOTICE.key))
  title:ClearAllPoints()
  title:SetPoint("TOPLEFT", c, "TOPLEFT", P.PAD, -P.PAD)
  title:SetWidth(inner)
  local titleH = ceil(title:GetStringHeight() or 12)
  text:SetText(L[NOTICE.text])
  text:ClearAllPoints()
  text:SetPoint("TOPLEFT", c, "TOPLEFT", P.PAD, -(P.PAD + titleH + P.TEXT_GAP))
  text:SetWidth(inner)
  local textH = ceil(text:GetStringHeight() or 12)

  c.OK:ClearAllPoints()
  c.OK:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -P.PAD, P.PAD)
  c.News:ClearAllPoints()
  c.News:SetPoint("RIGHT", c.OK, "LEFT", -P.BUTTON_GAP, 0)
  c:SetHeight(P.PAD + titleH + P.TEXT_GAP + textH + P.BUTTONS_GAP + P.BUTTON_H + P.PAD)
end

-- Beside the window, the arrange inspector's rule (Core/Arrange.lua,
-- AR.Dock): right unless the screen has no room there and more on the left.
local function DockCard(c, frame)
  local left, right = frame:GetLeft(), frame:GetRight()
  c:ClearAllPoints()
  local side = 1
  if left and right then
    local scale = frame:GetEffectiveScale() or 1
    local screen = (UIParent:GetRight() or 0) * (UIParent:GetEffectiveScale() or 1)
    local need = (CARD.DOCK + (c:GetWidth() or CARD.W)) * scale
    local roomRight, roomLeft = screen - right * scale, left * scale
    if roomRight < need and roomRight < roomLeft then side = -1 end
  end
  if side == 1 then
    c:SetPoint("TOPLEFT", frame, "TOPRIGHT", CARD.DOCK, 0)
  else
    c:SetPoint("TOPRIGHT", frame, "TOPLEFT", -CARD.DOCK, 0)
  end
end

local function ShowCard(frame)
  if not (frame and frame:IsShown()) then return end
  if not card then
    card = BuildCard(frame)
    -- The window's skin, over what was just made: the same expression as
    -- the window's own open (Core/MailboxUI.lua).
    local skin = ns.Skin
    if skin then
      if skin.RefreshWindow then skin.RefreshWindow(frame)
      elseif skin.Refresh then skin.Refresh(frame) end
    end
  end
  -- Not while the arrange mode's inspector stands where this would.
  local arrange = ns.Arrange
  if arrange and arrange.host then
    card:Hide()
    return
  end
  LayoutCard(card)
  DockCard(card, frame)
  card:Show()
end

-- The mail window has opened, at a mailbox (Core/MailboxUI.lua, OnMailShow).
function WN.WindowShown(frame)
  if Waiting() then ShowCard(frame) end
end

-- The arrange mode opened (true) or closed (false) (Core/Arrange.lua): its
-- inspector stands where the notice does, which waits for it to close.
function WN.Aside(on)
  local frame = card and card:GetParent()
  if not frame then return end
  if on then
    card:Hide()
  else
    WN.WindowShown(frame)
  end
end

-- /postbox whatsnew notice: the notice as a player coming from 1.40 sees
-- it, without their reset, to try it in game -- beside the mail window now
-- if it is open, else the next time it opens. Answered, it is gone for the
-- session; nothing is written.
function WN.TestNotice()
  WN._test = true
  local UI = ns.MailboxUI
  local frame = UI and UI._frame
  if frame and frame:IsShown() then ShowCard(frame) end
end
