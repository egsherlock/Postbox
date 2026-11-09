local _, ns = ...

-- =====================================================================
-- Postbox :: what's new
-- ---------------------------------------------------------------------
-- What an update brings with it, in two small pieces.
--
-- What's new?: a small window with the last three releases' highlights --
-- the changelog's own groups, a line to a highlight, in the player's
-- language -- opened from the notice below, from the options' footer and
-- by /postbox whatsnew.
--
-- The notice: when an update has put the settings back on their defaults
-- (Postbox.lua, 4b, which names the release in PostboxDB.notice), a card
-- stands beside the mail window the first time it opens -- what changed,
-- what was kept, What's new? and OK. Either button answers it for good, and
-- so does Escape, as OK; a mailbox closed without an answer shows it again
-- at the next one. Escape closes the window or the notice alone, leaving
-- the mail window up (section 4). It
-- stands outside the window, so nothing the player needs is under it, and
-- it steps aside while the arrange mode's inspector stands beside the
-- window (WN.Aside, from Core/Arrange.lua).
--
-- Once by itself: a release with news for everyone (NEWS, section 5) opens
-- the window by itself beside the mail window the first time a player
-- opens a mailbox with it, and never again.
--
-- Nothing here is built until it is shown. With no notice waiting and the
-- news shown, a mailbox open costs one read of the saved variables' root,
-- and a login one more.
-- =====================================================================

ns.WhatsNew = ns.WhatsNew or {}
local WN = ns.WhatsNew
local L = ns.L

local ceil, floor, max, min = math.ceil, math.floor, math.max, math.min

-- The notice PostboxDB.notice can name: its release, which is its title,
-- and its words.
local NOTICE = { key = "1.50", text = "NOTICE_150" }

-- Escape's own small parts (section 4), and the open by itself's (section
-- 5), named here so the window and the notice can reach them.
local ESC = {}
local ONCE = {}

-------------------------------------------------------------
-- 1. The releases
--
-- The newest KEEP releases, newest first: each is its version and its
-- groups, each group the locale keys of its heading and of its lines (one
-- string, a line to each "\n"). The changelog's own groups, condensed to a
-- line a highlight (.dev/RELEASING.md: the in-game What's new is the same
-- release, condensed and translated); a release with the plain shape shares
-- the New, Improved and Fixed headings. The next release adds its own at
-- the top, and the one that falls past KEEP goes, with its WHATSNEW_ keys:
-- nothing shows them any more. Made when the window is first built, not at
-- load.
--
-- A release may also carry a placard, the words of a small plate beside its
-- title (section 2b), and a note, a line of its own under the title: 1.60's
-- say that Postbox now supports WoW Forever, and ask for bug reports.
-------------------------------------------------------------
local KEEP = 3

local function Releases()
  return {
    { version = "1.61.0", groups = {
      { "WHATSNEW_161_SENT", "WHATSNEW_161_SENT_LINES" },
      { "WHATSNEW_161_SEARCH", "WHATSNEW_161_SEARCH_LINES" },
      { "WHATSNEW_FIXED", "WHATSNEW_161_FIXED_LINES" },
    } },
    { version = "1.60.0", placard = "WHATSNEW_160_PLACARD", note = "WHATSNEW_160_BUGS", groups = {
      { "WHATSNEW_160_FOREVER", "WHATSNEW_160_FOREVER_LINES" },
      { "WHATSNEW_160_EXPIRY", "WHATSNEW_160_EXPIRY_LINES" },
      { "WHATSNEW_160_BAR", "WHATSNEW_160_BAR_LINES" },
      { "WHATSNEW_160_OPTIONS", "WHATSNEW_160_OPTIONS_LINES" },
      { "WHATSNEW_FIXED", "WHATSNEW_160_FIXED_LINES" },
    } },
    { version = "1.50.0", groups = {
      { "WHATSNEW_150_ARRANGE", "WHATSNEW_150_ARRANGE_LINES" },
      { "WHATSNEW_150_LOOKS", "WHATSNEW_150_LOOKS_LINES" },
      { "WHATSNEW_150_MAILBOX", "WHATSNEW_150_MAILBOX_LINES" },
      { "WHATSNEW_150_MINIMAP", "WHATSNEW_150_MINIMAP_LINES" },
      { "WHATSNEW_150_HISTORY", "WHATSNEW_150_HISTORY_LINES" },
      { "WHATSNEW_150_SENDING", "WHATSNEW_150_SENDING_LINES" },
      { "WHATSNEW_150_OPTIONS", "WHATSNEW_150_OPTIONS_LINES" },
      { "WHATSNEW_150_UI", "WHATSNEW_150_UI_LINES" },
      { "WHATSNEW_150_LIGHTER", "WHATSNEW_150_LIGHTER_LINES" },
      { "WHATSNEW_FIXED", "WHATSNEW_150_FIXED_LINES" },
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

-------------------------------------------------------------
-- 2b. A release's placard
--
-- Beside the release's title, at the right end of its line: a small plate
-- in the window's own chrome (the totals banner's quiet fill inside its
-- one-pixel edge, bandFill and bandBorder: neutral, following the look and
-- the mode), WoW Forever's emblem at its left end and the words beside it
-- in the body's small type, on one line, "WoW Forever" in the bright ink and
-- the rest a step quieter. The emblem at its own size, 19 by 22 units (its
-- art's 2 texels a unit), so it stays legible at one screen pixel a unit;
-- the plate a unit clear of it all round, and centred on the title's line,
-- which it may stand taller than. All of it painted again on every open.
--
-- The emblem is Blizzard's, shown only to say Postbox supports their game:
-- the Forever client's own Interface\Glues\Common\
-- Glues-WoW-ForeverLogo-Infinity, shipped as Media/forever-logo.tga so
-- retail, which has no such art, shows it too. Drawn in its own colours,
-- never tinted. A new file under Media/ is found only after a full client
-- restart.
--
-- The rule for a translation too long for the line: where the title's
-- words, TITLE_GAP and the whole placard would not fit the page, the
-- placard is the emblem alone, and its words are its tooltip. It never
-- wraps, never runs past the page and never moves the title. Measured on
-- every open: a host skin can re-font the window after it is built.
-------------------------------------------------------------
local PLACARD = {
  FILE = "Interface\\AddOns\\Postbox\\Media\\forever-logo.tga",
  -- The art on its 64-texel canvas, and its own size in units.
  L = 0.203125, R = 0.796875, T = 0.15625, B = 0.84375,
  ART_W = 19, ART_H = 22,
  PAD_Y = 1,               -- the emblem in from the plate's top and bottom
  PAD = 5,                 -- the emblem's left and the words' last letter in from the plate's edges
  WORDS_GAP = 5,           -- the emblem to the words
  RIGHT_IN = 6,            -- the plate in from the page's right end, clear of the scroll bar's gutter
  BRIGHT = "WoW Forever",  -- the words' name of the game, in the bright ink
  TITLE_GAP = 12,          -- the least room between the title and the plate
}

-- The emblem alone: its words, which it does not show, as its tooltip.
function PLACARD.Tip(self)
  local T = ns.Theme
  T.TipBegin(self, "ANCHOR_TOP")
  T.TipTitle(self.__words or "")
  GameTooltip:Show()
  self.__tip = true
end

function PLACARD.TipOff(self)
  if not self.__tip then return end
  self.__tip = nil
  GameTooltip:Hide()
end

local function BuildPlacard(page, words)
  local T = ns.Theme
  local plate = CreateFrame("Frame", nil, page)
  local fill = plate:CreateTexture(nil, "BACKGROUND")
  local ring = {}
  for i = 1, 4 do ring[i] = plate:CreateTexture(nil, "BORDER") end
  local emblem = plate:CreateTexture(nil, "ARTWORK")
  emblem:SetTexture(PLACARD.FILE)
  emblem:SetTexCoord(PLACARD.L, PLACARD.R, PLACARD.T, PLACARD.B)
  -- Theme.Glyph's sampling: on the pixel grid, no texel snapping bias.
  if emblem.SetSnapToPixelGrid then emblem:SetSnapToPixelGrid(true) end
  if emblem.SetTexelSnappingBias then emblem:SetTexelSnappingBias(0) end
  local text = T.CreateText(plate, "bodySmall")
  text:SetJustifyH("LEFT")
  text:SetWordWrap(false)
  plate.Fill, plate.Ring, plate.Emblem, plate.Words = fill, ring, emblem, text
  plate.__words = words
  return plate
end

-- From the tokens as they are now: the look or the mode may have moved
-- since the last open.
local function PaintPlacard(plate)
  local T = ns.Theme
  T.FillColor(plate.Fill, "bandFill")
  for i = 1, 4 do T.FillColor(plate.Ring[i], "bandBorder") end
  -- The words a step quieter, the game's name in them bright: inks as the
  -- look has them now, so the string is made here, once an open.
  local words, bright = plate.__words or "", PLACARD.BRIGHT
  T.SetColor(plate.Words, "textSecondary")
  local hex = T.InkHex("textPrimary")
  if hex and words:find(bright, 1, true) then
    local s, e = words:find(bright, 1, true)
    words = words:sub(1, s - 1) .. "|cff" .. hex .. bright .. "|r" .. words:sub(e + 1)
  end
  plate.Words:SetText(words)
end

-- The ring inside the plate's edge, `px` thick, and the fill inside the
-- ring, so neither doubles the other's alpha.
local function PlaceRing(plate, px)
  local top, bottom, left, right = plate.Ring[1], plate.Ring[2], plate.Ring[3], plate.Ring[4]
  top:ClearAllPoints()
  top:SetPoint("TOPLEFT", plate, "TOPLEFT", 0, 0)
  top:SetPoint("TOPRIGHT", plate, "TOPRIGHT", 0, 0)
  top:SetHeight(px)
  bottom:ClearAllPoints()
  bottom:SetPoint("BOTTOMLEFT", plate, "BOTTOMLEFT", 0, 0)
  bottom:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", 0, 0)
  bottom:SetHeight(px)
  left:ClearAllPoints()
  left:SetPoint("TOPLEFT", plate, "TOPLEFT", 0, -px)
  left:SetPoint("BOTTOMLEFT", plate, "BOTTOMLEFT", 0, px)
  left:SetWidth(px)
  right:ClearAllPoints()
  right:SetPoint("TOPRIGHT", plate, "TOPRIGHT", 0, -px)
  right:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", 0, px)
  right:SetWidth(px)
  local fill = plate.Fill
  fill:ClearAllPoints()
  fill:SetPoint("TOPLEFT", plate, "TOPLEFT", px, -px)
  fill:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -px, px)
end

-- A text's own width on one line, whatever width it was given.
local function Natural(fs)
  local w = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()
  return ceil(tonumber(w) or 0)
end

-- Beside `title`, which stands at `y` down a page `width` wide, at the
-- right end of its line. Answers the line's height, or 0 where not even
-- the emblem fits beside the title.
local function LayoutPlacard(plate, title, page, y, width)
  local P = PLACARD
  local words, emblem = plate.Words, plate.Emblem
  PaintPlacard(plate)
  local _, size = title:GetFont()
  local line = ceil(tonumber(size) or P.ART_H)
  local eh, ew = P.ART_H, P.ART_W
  -- The plate a unit clear of the emblem, never shorter than the line, and
  -- centred on it: `over` above the title's top, the rest below.
  local plateH = max(line, eh + 2 * P.PAD_Y)
  local over = floor((plateH - line) / 2)
  emblem:SetSize(ew, eh)
  emblem:ClearAllPoints()
  emblem:SetPoint("LEFT", plate, "LEFT", P.PAD, 0)

  -- The plate's right end, a little in from the page's.
  local right = width - P.RIGHT_IN
  local room = right - Natural(title) - P.TITLE_GAP
  local lead = P.PAD + ew + P.WORDS_GAP
  -- A unit to spare: a string given exactly its own width can still be
  -- cut by the client's rounding. The words stand left, so it is never seen.
  local shown = Natural(words) + 1
  -- Where the last letter really ends, as the client lays the words out
  -- (CollectTab's Span, the island's own rule): a client can measure a
  -- string several units past its letters, which would leave the plate's
  -- right gap wider than its left. The measured width where it cannot say.
  local inkR = shown
  local CT = ns.CollectTab
  local Span = CT and CT.BarParts and CT.BarParts.Span
  if Span then
    local _, r = Span(words, words:GetText())
    if r and r > 0 and r <= shown then inkR = ceil(r) end
  end
  local w = lead + inkR + P.PAD
  local alone = w > room
  if alone then
    w = P.PAD + ew + P.PAD
    words:Hide()
  else
    words:SetWidth(shown)
    words:ClearAllPoints()
    words:SetPoint("LEFT", plate, "LEFT", lead, 0)
    words:Show()
  end
  plate:EnableMouse(alone)
  plate:SetScript("OnEnter", alone and P.Tip or nil)
  plate:SetScript("OnLeave", alone and P.TipOff or nil)
  if w > room then
    plate:Hide()
    return 0
  end
  plate:ClearAllPoints()
  plate:SetPoint("TOPRIGHT", page, "TOPLEFT", right, -(y - over))
  plate:SetSize(w, plateH)
  PlaceRing(plate, ns.Theme.OnePixel(plate))
  plate:Show()
  -- The line's height with the plate's part below the title's line.
  return plateH - over
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
  -- Escape closes it alone (section 4); the client's own pass, by this
  -- name, is the net for a press in combat.
  ns.Core.UI.Helpers.RegisterEscClose(f)
  f:HookScript("OnShow", ESC.Sync)
  f:HookScript("OnHide", ESC.Sync)

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
  for r = 1, min(KEEP, #releases) do
    local release = releases[r]
    local title = T.CreateText(page, "title")
    title:SetJustifyH("LEFT")
    title:SetText(L("WHATSNEW_RELEASE", release.version))
    local plate = release.placard and BuildPlacard(page, L[release.placard]) or nil
    items[#items + 1] = { kind = "release", text = title, plate = plate }
    if release.note then
      local note = T.CreateText(page, "secondary")
      note:SetJustifyH("LEFT")
      note:SetWordWrap(true)
      note:SetText(L[release.note])
      items[#items + 1] = { kind = "note", text = note }
    end
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
-- the window as tall as that, up to MAX_H. A placard stands on its
-- release's title line, and the line is as tall as the taller of the two;
-- a note stands between the title and the first heading, a title's gap
-- below the title and a group's gap above the heading.
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
    elseif kind == "note" then
      y = y + WIN.TITLE_GAP
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
    local h = ceil(text:GetStringHeight() or 12)
    if item.plate then h = max(h, LayoutPlacard(item.plate, text, f.Page, y, width)) end
    y = y + h
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
-- However it is opened, the news it brings counts as shown (section 5).
function WN.Open(beside, foot)
  ONCE.Shown()
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
-- and as tall as its words. Words that would run past LINES lines at that
-- width widen it a STEP at a time, up to MAX_W, so a long translation makes
-- a wider card rather than a column standing beside the window; only past
-- MAX_W does it grow taller instead.
-------------------------------------------------------------
local CARD = {
  W = 250, MAX_W = 340, STEP = 10, LINES = 8,
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
  -- Escape answers it as OK does, and closes nothing else (section 4).
  -- Hooked, as the window's are: ApplyCard has hooked the show already, to
  -- paint the card's floor in the look of the moment.
  c:HookScript("OnShow", ESC.Sync)
  c:HookScript("OnHide", ESC.Sync)

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

-- The lines a wrapped text takes at the width it has: the client's count,
-- or its height over its font's.
local function LineCount(fs)
  local n = fs.GetNumLines and tonumber((fs:GetNumLines()))
  if n and n > 0 then return n end
  local _, size = fs:GetFont()
  return ceil((fs:GetStringHeight() or 0) / max(1, tonumber(size) or 12))
end

-- Measured on every show: the skin's pass may have re-fonted it since.
local function LayoutCard(c)
  local T = ns.Theme
  local P = CARD
  local news = T.SizeToText(c.News, P.FIT)
  local ok = T.SizeToText(c.OK, P.FIT)
  local width = max(P.W, min(P.MAX_W, news + P.BUTTON_GAP + ok + 2 * P.PAD))

  local title, text = c.Title, c.Text
  text:SetText(L[NOTICE.text])
  text:SetWidth(width - 2 * P.PAD)
  while width < P.MAX_W and LineCount(text) > P.LINES do
    width = min(P.MAX_W, width + P.STEP)
    text:SetWidth(width - 2 * P.PAD)
  end
  local inner = width - 2 * P.PAD
  c:SetWidth(width)

  title:SetText(L("WHATSNEW_RELEASE", NOTICE.key))
  title:ClearAllPoints()
  title:SetPoint("TOPLEFT", c, "TOPLEFT", P.PAD, -P.PAD)
  title:SetWidth(inner)
  local titleH = ceil(title:GetStringHeight() or 12)
  text:ClearAllPoints()
  text:SetPoint("TOPLEFT", c, "TOPLEFT", P.PAD, -(P.PAD + titleH + P.TEXT_GAP))
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

-- The mail window has opened, at a mailbox (Core/MailboxUI.lua, OnMailShow):
-- the notice, where one waits, else the news, the first time (section 5).
function WN.WindowShown(frame)
  if Waiting() then
    ShowCard(frame)
  elseif ONCE.armed then
    ONCE.Try(frame)
  end
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

-------------------------------------------------------------
-- 4. Escape
--
-- Escape closes the window, or answers the notice (as OK does), and only
-- that: the mail window and everything else stay up for the next press.
--
-- The client cannot be asked for that through UISpecialFrames alone. Its
-- answer to the game-menu key, when nothing before the addons claims it,
-- is one pass that hides every UI panel and every frame named in
-- UISpecialFrames (CloseAllWindows) -- and at a mailbox the mail frame is
-- one of those panels, shown unseen under the Postbox window, so the pass
-- closes the mailbox with What's new (Core/Arrange.lua, section 5, which
-- meets the same pass the same way).
--
-- So, out of combat, while the window or the notice is up, a small frame
-- of ours hears the keyboard with every key passed on (propagation on, set
-- before it is ever shown). The game-menu key is kept from the bindings for
-- that one press, and only when the client would reach the addons' windows
-- with it (AR.EscapeReachesAddOns: no popup, menu, cast, focused edit box or
-- Blizzard window that answers first); the next frame keys pass again and
-- the press is answered. Every other key passes untouched. In combat an
-- addon may not set propagation, so the frame hides for the fight
-- (PLAYER_REGEN_DISABLED comes before the lockdown) and Escape is the
-- client's pass as before: the window's name stays in UISpecialFrames for
-- it. Nothing of Blizzard's is touched, and the frame and its two events
-- exist only while there is something of ours to close.
-------------------------------------------------------------

-- The topmost thing of ours up: the window (over the mail window's strata),
-- then the notice. Hides it; answers whether there was one.
function ESC.Close()
  if win and win:IsVisible() then
    win:Hide()
    return true
  end
  if card and card:IsVisible() then
    Answer(false)
    return true
  end
  return false
end

-- Keys pass again. In combat propagation cannot be set, and the frame
-- hides instead: a hidden frame takes no keys at all.
function ESC.Pass(self)
  if self:GetPropagateKeyboardInput() then return end
  if InCombatLockdown() then
    self:Hide()
  else
    self:SetPropagateKeyboardInput(true)
  end
end

-- The frame after a press was kept: keys pass, then the press is answered.
function ESC.KeyAnswer(self)
  self:SetScript("OnUpdate", nil)
  self.pending = nil
  ESC.Pass(self)
  ESC.Close()
end

function ESC.KeyDown(self, pressed)
  if InCombatLockdown() then
    self:Hide()
    return
  end
  local AR = ns.Arrange
  local ours = false
  if AR and type(AR.EscapeReachesAddOns) == "function" then
    local ok, yes = pcall(AR.EscapeReachesAddOns, pressed)
    ours = ok and yes
  end
  if not ours then
    if not self:GetPropagateKeyboardInput() then self:SetPropagateKeyboardInput(true) end
    return
  end
  if not self.pending then
    self.pending = true
    self:SetScript("OnUpdate", ESC.KeyAnswer)
  end
  if self:GetPropagateKeyboardInput() then self:SetPropagateKeyboardInput(false) end
end

-- Hidden with a press unanswered (combat began, or what it would close went
-- another way): answered a frame later all the same.
function ESC.KeyHidden(self)
  self:SetScript("OnUpdate", nil)
  ESC.Pass(self)
  if self.pending then
    self.pending = nil
    C_Timer.After(0, ESC.Close)
  end
end

function ESC.OnEvent(self, event)
  if event == "PLAYER_REGEN_DISABLED" then
    -- Before the lockdown: keys pass and the frame goes for the fight.
    self:Hide()
  else
    ESC.Sync()
  end
end

-- Made on first use. On UIParent in the window's strata, over the mail
-- window and the arrange mode's own key frame, so it hears a key first.
function ESC.Frame()
  local key = ESC.key
  if key then return key end
  key = CreateFrame("Frame", nil, UIParent)
  key:Hide()
  key:SetFrameStrata("FULLSCREEN_DIALOG")
  key:SetScript("OnEvent", ESC.OnEvent)
  ESC.key = key
  return key
end

-- Given the keyboard once, out of combat, propagation on before it is ever
-- shown. Answers whether it hears keys (never on a client without these).
function ESC.Arm(key)
  if key.armed then return true end
  if type(key.EnableKeyboard) ~= "function" or type(key.SetPropagateKeyboardInput) ~= "function"
    or type(key.GetPropagateKeyboardInput) ~= "function" then
    return false
  end
  key:SetPropagateKeyboardInput(true)
  key:EnableKeyboard(true)
  key:SetScript("OnKeyDown", ESC.KeyDown)
  key:SetScript("OnKeyUp", ESC.Pass)
  key:SetScript("OnShow", ESC.Pass)
  key:SetScript("OnHide", ESC.KeyHidden)
  key.armed = true
  return true
end

-- The window or the notice shown or hidden, or a fight ended: the frame
-- up while either is up out of combat, and listening for combat while
-- either is up at all.
function ESC.Sync()
  local up = (win and win:IsVisible()) or (card and card:IsVisible())
  local key = ESC.key
  if not up then
    if key then
      key:UnregisterEvent("PLAYER_REGEN_DISABLED")
      key:UnregisterEvent("PLAYER_REGEN_ENABLED")
      key:Hide()
    end
    return
  end
  key = key or ESC.Frame()
  key:RegisterEvent("PLAYER_REGEN_DISABLED")
  key:RegisterEvent("PLAYER_REGEN_ENABLED")
  if InCombatLockdown() or not ESC.Arm(key) then
    key:Hide()
    return
  end
  if not key:IsShown() then
    local AR = ns.Arrange
    if AR and type(AR.ReadMenuKeys) == "function" then AR.ReadMenuKeys() end
    key:Show()
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

-------------------------------------------------------------
-- 5. Once by itself
--
-- A release with news for everyone names it in NEWS, and What's new opens
-- by itself for it once: the first time the player opens a mailbox with
-- it, after an update or on a fresh install (WoW Forever keeps saved
-- variables of its own, so nearly every Forever player is one), beside the
-- mail window as the 1.50 notice stands (WN.WindowShown, from the mail
-- window's open in Core/MailboxUI.lua). 1.60's is WoW Forever. A release
-- without such news sets NEWS to nil, and nothing here runs at all.
--
-- Postbox.lua arms it at load (WN.ArmOnce), after the one-time steps: one
-- read of PostboxDB.newsShown. Once it was shown nothing is armed, and a
-- mailbox open reads nothing more than the notice's one read.
--
-- Shown politely, with no timer and no OnUpdate:
--   * never in combat: a mailbox opened in a fight waits for
--     PLAYER_REGEN_ENABLED, once, and it opens then beside the mail window
--     if that is still up, else at the next mailbox;
--   * never with the 1.50 notice, which only a player coming from 1.40 has.
--     While it waits, the news is left to it (its What's new? opens this
--     window), and comes by itself at the next mailbox if it was answered
--     with OK;
--   * never over the arrange mode's inspector, nor for a visit Postbox
--     stepped aside from (a controller player in Forever, whose mailbox is
--     Blizzard's): the next mailbox.
-- Escape and its close button close it as ever.
--
-- Any open of the window shows the news -- by itself, from the notice, the
-- options' footer or /postbox whatsnew -- and the mark is written as it
-- opens (ONCE.Shown), so a /reload or a second mailbox straight after
-- never shows it twice. Reset everything keeps the mark
-- (Core/MailboxUI.lua, CENSUS_KEEP).
-------------------------------------------------------------
local NEWS = "1.60"

-- The one saved read: shown already, or no news to show.
local function NewsShown()
  if not NEWS then return true end
  local db = PostboxDB
  return type(db) == "table" and db.newsShown == NEWS
end

-- Nothing more to wait for; unregistering what is not registered costs
-- nothing.
function ONCE.Disarm()
  ONCE.armed, ONCE.fight = nil, nil
  ns.Events.Unregister("PLAYER_REGEN_ENABLED", ONCE.Resume)
end

-- The window opened, however: the news is shown, for good.
function ONCE.Shown()
  if NewsShown() then return end
  local db = PostboxDB
  if type(db) ~= "table" then return end
  db.newsShown = NEWS
  ONCE.Disarm()
end

-- The mail window has opened at a mailbox, or a fight it opened in is
-- over: open beside it, unless something says not yet.
function ONCE.Try(frame)
  if not (ONCE.armed and frame and frame:IsShown()) then return end
  -- The 1.50 notice goes first, and alone.
  if Waiting() then return end
  local arrange = ns.Arrange
  if arrange and arrange.host then return end
  if InCombatLockdown() then
    if not ONCE.fight then
      ONCE.fight = true
      ns.Events.Register("PLAYER_REGEN_ENABLED", ONCE.Resume)
    end
    return
  end
  WN.Open(frame, false)
end

-- The fight is over: the mail window, if a mailbox still holds it open.
function ONCE.Resume()
  ONCE.fight = nil
  ns.Events.Unregister("PLAYER_REGEN_ENABLED", ONCE.Resume)
  local UI = ns.MailboxUI
  local st = UI and UI._state
  if st and st.mailboxOpen then ONCE.Try(UI._frame) end
end

-- At load, from Postbox.lua's ADDON_LOADED.
function WN.ArmOnce()
  ONCE.armed = not NewsShown() or nil
end
