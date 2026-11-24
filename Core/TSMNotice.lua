-- Postbox :: a one-time notice for players who also run TradeSkillMaster
--
-- TradeSkillMaster (TSM) has a mail window of its own, which it opens at a
-- mailbox unless the player has clicked "WOW UI" in its title bar (TSM
-- remembers that for the account). With both addons on, two mail windows
-- can stand on one inbox, and Postbox has not been tested beside TSM. So,
-- once per account, a small window of Postbox's own says so: how to keep
-- only Postbox's mail window, that the two are untested together, and
-- where a bug report goes, with the address in a box to copy. One button
-- closes it, as do its close button and Escape.
--
-- When: TSM is loaded (asked once, at login), and a mailbox opens out of
-- combat with Postbox's window up. The notice opens a frame later, beside
-- that window, never over it, and takes no keyboard focus. In combat it
-- waits for the next mailbox; so it does while the 1.50 update notice
-- (Core/WhatsNew.lua, section 3) is still waiting for its answer, which
-- stands where this would. It does not close with the mailbox: it is
-- read at the player's pace, and the address stays there to copy.
--
-- What it reads of TSM: only whether the addon is loaded. Nothing of TSM's
-- is called, hooked, replaced or written, and nothing of Blizzard's mail
-- code or of the mail window's layout is touched.
--
-- Cost. Without TSM, or once the notice has shown: one check at login and
-- nothing after it, no event, no timer, no frame. With TSM and the notice
-- still unseen: at a mailbox, one one-shot timer; no OnUpdate, no
-- repeating timer. The window is built the first time it shows.
--
-- Saved: PostboxDB.tsmNoticeShown, at the root: the notice's KEY once it
-- has shown. Not a setting, so Reset to defaults keeps it, and Reset
-- everything keeps it too (Core/MailboxUI.lua, CENSUS_KEEP). The one-line
-- version of 2.1.0's dev builds saved `true`; that is not this KEY, so a
-- tester who saw the line sees this notice once.

local _, ns = ...

local TN = {}
ns.TSMNotice = TN

local L = ns.L
local ceil, max, min = math.ceil, math.max, math.min

-- The addon's folder name, as the client knows it.
local TSM_ADDON = "TradeSkillMaster"
-- What PostboxDB.tsmNoticeShown holds once this notice has shown.
local KEY = "2.1"

local function Seen()
  local db = PostboxDB
  return type(db) == "table" and db.tsmNoticeShown == KEY
end

local function TSMLoaded()
  local addons = C_AddOns
  local loaded = addons and addons.IsAddOnLoaded or _G.IsAddOnLoaded
  if type(loaded) ~= "function" then return false end
  local ok, yes = pcall(loaded, TSM_ADDON)
  return ok and yes and true or false
end

-------------------------------------------------------------
-- 1. The window
--
-- A window of the house's own kind, as What's new and the bug report are:
-- the template, the theme and whichever skin paints those, the window
-- scale, Escape and its close button, and never see-through. The words on
-- the list surface What's new's pages stand on; under them the bug
-- report's address line (its caption, its Ctrl+C hint and its read-only
-- box, ns.BugReport), and OK. As wide as W, or as the address line needs,
-- up to MAX_W; as tall as its words at that width, so a long translation
-- makes a taller window and is never cut. Laid out on every show, after
-- the skin's pass.
-------------------------------------------------------------
local WIN = {
  W = 400, MAX_W = 500,
  TOP = 30,                -- under the template's title bar
  EDGE = 10,               -- the card and the box in from the window's edges
  PAD = 10,                -- the words in from the card's edges
  INDENT = 4,              -- a caption in from its field (the bug report's)
  LINE_H = 22,             -- the address's heading line
  BUTTON_H = 22,
}
local win

local function Build()
  local T = ns.Theme
  local M = T.Metrics

  -- Named: Escape closes it through UISpecialFrames, a list of names, and
  -- What's new's Escape closes it alone (its ESC.ALL).
  local f = CreateFrame("Frame", "PostboxTSMNoticeFrame", UIParent, "BasicFrameTemplateWithInset")
  f:SetSize(WIN.W, 300)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:Hide()
  -- Read to the letter, so opaque whatever the mailbox window's opacity.
  -- Skin.ApplyBgOpacity honours this flag.
  f.__pbEuiAlwaysOpaque = true
  if f.SetTitle then
    f:SetTitle(L["TSM_NOTICE_TITLE"])
  elseif f.TitleText then
    f.TitleText:SetText(L["TSM_NOTICE_TITLE"])
  end
  T.ApplyFrameTheme(f)
  ns.Core.UI.Helpers.RegisterEscClose(f)

  -- The words.
  local card = CreateFrame("Frame", nil, f, "BackdropTemplate")
  card:SetPoint("TOPLEFT", f, "TOPLEFT", WIN.EDGE, -WIN.TOP)
  card:SetPoint("TOPRIGHT", f, "TOPRIGHT", -WIN.EDGE, -WIN.TOP)
  T.ApplyList(card)
  local text = T.CreateText(card, "bodySmall")
  text:SetPoint("TOPLEFT", card, "TOPLEFT", WIN.PAD, -WIN.PAD)
  text:SetJustifyH("LEFT")
  text:SetJustifyV("TOP")
  text:SetWordWrap(true)

  -- Where to report: the bug report's caption, hint and box.
  local line = CreateFrame("Frame", nil, f)
  line:SetHeight(WIN.LINE_H)
  line:SetPoint("TOPLEFT", card, "BOTTOMLEFT", WIN.INDENT, -M.gap)
  line:SetPoint("TOPRIGHT", card, "BOTTOMRIGHT", -WIN.INDENT, -M.gap)
  local caption = T.CreateText(line, "heading")
  caption:SetPoint("LEFT", line, "LEFT", 0, 0)
  caption:SetWordWrap(false)
  caption:SetText(L["OPT_BUG_URL_LABEL"])
  local hint = T.CreateText(line, "secondary")
  hint:SetPoint("RIGHT", line, "RIGHT", 0, 0)
  hint:SetJustifyH("RIGHT")
  -- Motion only, for a translation the line cuts short: a click passes
  -- on, so the window still drags from here.
  line:EnableMouse(true)
  if line.SetPropagateMouseClicks then line:SetPropagateMouseClicks(true) end
  line:SetScript("OnEnter", function(self)
    if not self.__pbOverflowText then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    T.AddOverflowLine(self, GameTooltip)
    GameTooltip:Show()
  end)
  line:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local wrap = CreateFrame("Frame", nil, f, "BackdropTemplate")
  wrap:SetPoint("TOPLEFT", line, "BOTTOMLEFT", -WIN.INDENT, -M.labelGap)
  wrap:SetPoint("TOPRIGHT", line, "BOTTOMRIGHT", WIN.INDENT, -M.labelGap)
  wrap:SetHeight(M.controlHeight)
  local url = CreateFrame("EditBox", nil, wrap)
  T.StyleInput(wrap, url)
  url:SetPoint("TOPLEFT", wrap, "TOPLEFT", 8, -2)
  url:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", -8, 2)
  local report = ns.BugReport
  if report and type(report.ReadOnly) == "function" then
    report.ReadOnly(url)
  else
    url:SetAutoFocus(false)
  end
  url:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  -- A click anywhere on the field selects the address (ReadOnly's focus).
  wrap:SetScript("OnMouseDown", function() url:SetFocus() end)

  local ok = T.CreateButton(nil, f)
  ok:SetText(L["NOTICE_OK"])
  ok:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -WIN.EDGE, WIN.EDGE)
  ok:SetScript("OnClick", function() f:Hide() end)

  -- Closing lets go of the keyboard, wherever it was. Hooked, not set:
  -- Escape's own hide hook (RegisterEscClose, above) stays.
  f:HookScript("OnHide", function()
    url:ClearFocus()
    GameTooltip:Hide()
  end)

  f.Card, f.Text, f.Line, f.Caption, f.Hint, f.Url, f.OK = card, text, line, caption, hint, url, ok
  return f
end

-- Measured on every show: a host skin may have re-fonted it since, and
-- every line here is a translation. The address line whole where the
-- window can widen for it; past MAX_W the hint is cut (its whole text in
-- the line's tooltip). The words wrap at the width that gives, and the
-- window is as tall as they make it.
local function Layout(f)
  local T = ns.Theme
  local M = T.Metrics
  local hintText = L["OPT_BUG_HINT"]
  f.Hint:SetText(hintText)
  local captionW = ceil(T.TextWidth(f.Caption))
  local need = captionW + M.gap + ceil(T.TextWidth(f.Hint)) + 2 * (WIN.EDGE + WIN.INDENT)
  local width = max(WIN.W, min(WIN.MAX_W, need))
  f:SetWidth(width)
  T.FitText(f.Hint, width - 2 * (WIN.EDGE + WIN.INDENT) - captionW - M.gap, hintText, f.Line)

  local text = f.Text
  text:SetWidth(width - 2 * (WIN.EDGE + WIN.PAD))
  text:SetText(L["TSM_NOTICE_TEXT"])
  local textH = ceil(text:GetStringHeight() or 12)
  f.Card:SetHeight(textH + 2 * WIN.PAD)

  local address = ns.BugReport and ns.BugReport.URL or ""
  f.Url._value = address
  f.Url:SetText(address)
  f.Url:SetCursorPosition(0)

  T.SizeToText(f.OK, { height = WIN.BUTTON_H, minWidth = 64 })
  f:SetHeight(WIN.TOP + textH + 2 * WIN.PAD + M.gap + WIN.LINE_H + M.labelGap + M.controlHeight
    + M.gap + WIN.BUTTON_H + WIN.EDGE)
  if type(T.FitToScreen) == "function" then T.FitToScreen(f) end
end

-- Shown beside `beside` (the mail window; the side with room, right
-- first), or in the screen's middle without one. Never focused: the
-- keyboard stays where it was.
local function Open(beside)
  if not win then
    win = Build()
    -- The same expression as What's new and the bug report.
    local skin = ns.Skin
    local apply = skin and (skin.ApplyWindow or skin.Apply)
    if apply then apply(win) end
  end
  win:Show()
  win:Raise()
  local skin = ns.Skin
  if skin and skin.Refresh then pcall(skin.Refresh, win) end
  Layout(win)
  local helpers = ns.Core and ns.Core.UI and ns.Core.UI.Helpers
  if helpers and helpers.PlaceBeside then
    helpers.PlaceBeside(win, beside, "right")
  else
    win:ClearAllPoints()
    win:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
  end
end

-- /postbox whatsnew tsm: the notice as a TradeSkillMaster player sees it,
-- to try it in game without TSM; beside the mail window if it is open.
-- Nothing is written.
function TN.Try()
  local UI = ns.MailboxUI
  local frame = UI and UI._frame
  Open(frame and frame:IsShown() and frame or nil)
end

-------------------------------------------------------------
-- 2. When
-------------------------------------------------------------
local watching = false
local pending = false
local OnMailShow, OnInteraction

local function StopWatching()
  if not watching then return end
  watching = false
  local bus = ns.Events
  if bus then
    bus.Unregister("MAIL_SHOW", OnMailShow)
    bus.Unregister("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", OnInteraction)
  end
end

-- A frame after the open, with Postbox's window up: the notice, once.
local function Look()
  pending = false
  if Seen() then StopWatching() return end
  -- Not in combat, and not while the update notice waits for its answer:
  -- the next mailbox.
  if InCombatLockdown() then return end
  local db = PostboxDB
  if type(db) ~= "table" or db.notice ~= nil then return end
  local UI = ns.MailboxUI
  local st = UI and UI._state
  local frame = UI and UI._frame
  -- Not a mailbox Postbox opened (a controller player's visit on Forever,
  -- UI.StepsAside; the mailbox already closed again).
  if not (st and st.mailboxOpen and frame and frame:IsShown()) then return end
  db.tsmNoticeShown = KEY
  StopWatching()
  Open(frame)
end

local function Opened()
  if pending then return end
  pending = true
  C_Timer.After(0, Look)
end

OnMailShow = function() Opened() end

OnInteraction = function(_, kind)
  local helpers = ns.Helpers
  if helpers and helpers.IsMailInteraction and helpers.IsMailInteraction(kind) then Opened() end
end

-- At login, once: every addon that is not load-on-demand has loaded by
-- now, TSM among them. Without TSM, or with the notice seen, this is all.
local function OnLogin()
  local bus = ns.Events
  if not bus then return end
  bus.Unregister("PLAYER_LOGIN", OnLogin)
  if Seen() or not TSMLoaded() then return end
  if not (C_Timer and type(C_Timer.After) == "function") then return end
  watching = true
  bus.Register("MAIL_SHOW", OnMailShow)
  bus.Register("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", OnInteraction)
end

if ns.Events then ns.Events.Register("PLAYER_LOGIN", OnLogin) end
