-- Postbox :: a one-time line for players who also run TradeSkillMaster
--
-- TradeSkillMaster (TSM) has a mail window of its own. At a mailbox it opens
-- that window a frame after the game's, and hides the game's mail frame,
-- unless the player has clicked "WOW UI" in its title bar, which TSM
-- remembers for the account (its saved global.mailingUIContext.showDefault)
-- and which leaves the game's mailbox, and so Postbox, alone. With both
-- addons on and TSM's own window chosen, two mail windows stand on one
-- inbox. So, the first time that is seen, one line on the Mail tab under its
-- top row says how to keep only Postbox's, in TSM's own words for the
-- button. Once, for the account: never again after it has shown.
--
-- What it reads of TSM is only what TSM publishes for other addons: whether
-- the addon is loaded, and TSM_API.IsUIVisible("MAILING"), which answers
-- whether its mail window is up. Nothing of TSM's is hooked, replaced or
-- written, and nothing of Blizzard's mail code is touched: the line is a
-- string of Postbox's own on its own window.
--
-- Cost. Without TSM, or once the line has shown: one check at login and
-- nothing after it, no event, no timer, no frame. With TSM and the line
-- still unseen: at each mailbox opened, one look two frames later (TSM
-- decides a frame after the open), through two one-shot timers made of
-- functions made once; no OnUpdate, no repeating timer.
--
-- Saved: PostboxDB.tsmNoticeShown (true), at the root: not a setting, so
-- Reset to defaults keeps it, and Reset everything keeps it too
-- (Core/MailboxUI.lua, CENSUS_KEEP).

local _, ns = ...

local TN = {}
ns.TSMNotice = TN

local L = ns.L

-- The addon's folder name, as C_AddOns knows it.
local TSM_ADDON = "TradeSkillMaster"

local function Seen()
  local db = PostboxDB
  return type(db) == "table" and db.tsmNoticeShown == true
end

local function TSMLoaded()
  local addons = C_AddOns
  local loaded = addons and addons.IsAddOnLoaded
  if type(loaded) ~= "function" then return false end
  local ok, yes = pcall(loaded, TSM_ADDON)
  return ok and yes and true or false
end

-- TSM's own answer, through its public API (TSM_API, its Core/API.lua):
-- whether its mail window is up now. Anything else -- no API, an error, an
-- answer that is not a plain true -- is "not known", and says nothing.
local function TSMWindowUp()
  local api = _G.TSM_API
  local ask = type(api) == "table" and api.IsUIVisible or nil
  if type(ask) ~= "function" then return false end
  local ok, up = pcall(ask, "MAILING")
  return ok and up == true
end

-------------------------------------------------------------
-- 1. The line
--
-- On the Mail tab, under its top row where the filter chips stand, as wide
-- as the list, in the window's secondary ink on the window itself (a plate
-- under the words where the window is too clear to carry them,
-- Theme.OnWindow). It wraps where a language or a narrow window needs a
-- second line, and the list starts under it, the chips' tight gap away
-- (CollectTab.PlaceListTop). It stands for the rest of the visit and goes
-- with the mailbox.
-------------------------------------------------------------
local function Panel()
  local UI = ns.MailboxUI
  local frame = UI and UI._frame
  return frame and frame.Tabs and frame.Tabs.collect or nil
end

local function Place(panel)
  local CT = ns.CollectTab
  if CT and type(CT.PlaceListTop) == "function" then CT.PlaceListTop(panel) end
end

local function ShowLine(panel)
  local T = ns.Theme
  local note = panel.Note
  if not note then
    local M = T.Metrics
    note = T.CreateText(panel, "secondary")
    note:SetPoint("TOPLEFT", panel.ViewToggle, "BOTTOMLEFT", 0, -M.tightGap)
    note:SetPoint("RIGHT", panel, "RIGHT", -M.inset, 0)
    note:SetJustifyH("LEFT")
    note:SetJustifyV("TOP")
    note:SetWordWrap(true)
    if T.OnWindow then T.OnWindow(note, "window", "LEFT") end
    panel.Note = note
  end
  note:SetText(L["TSM_NOTICE"])
  note:Show()
  Place(panel)
end

local function HideLine()
  local panel = Panel()
  local note = panel and panel.Note
  if note and note:IsShown() then
    note:Hide()
    Place(panel)
  end
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

-- The mailbox closed with the line up: it goes, and the list is where it
-- always was.
local function OnMailClosed()
  local bus = ns.Events
  if bus then
    bus.Unregister("MAIL_CLOSED", OnMailClosed)
    bus.Unregister("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", OnMailClosed)
  end
  HideLine()
end

-- Two frames after the open: Postbox's window is up, and TSM has had its
-- frame to choose its window or the game's.
local function Look()
  pending = false
  if Seen() then StopWatching() return end
  local UI = ns.MailboxUI
  local st = UI and UI._state
  local frame = UI and UI._frame
  -- Not a mailbox Postbox opened (a controller player's visit on Forever,
  -- UI.StepsAside; the mailbox already closed again).
  if not (st and st.mailboxOpen and frame and frame:IsShown()) then return end
  if not TSMWindowUp() then return end
  local panel = Panel()
  if not (panel and panel.ViewToggle and panel.MailListArea) then return end
  local db = PostboxDB
  if type(db) ~= "table" then return end
  db.tsmNoticeShown = true
  StopWatching()
  ShowLine(panel)
  local bus = ns.Events
  if bus then
    bus.Register("MAIL_CLOSED", OnMailClosed)
    bus.Register("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", OnMailClosed)
  end
end

local function LookNextFrame()
  C_Timer.After(0, Look)
end

local function Opened()
  if pending then return end
  pending = true
  C_Timer.After(0, LookNextFrame)
end

OnMailShow = function() Opened() end

OnInteraction = function(_, kind)
  local helpers = ns.Helpers
  if helpers and helpers.IsMailInteraction and helpers.IsMailInteraction(kind) then Opened() end
end

-- At login, once: every addon that is not load-on-demand has loaded by
-- now, TSM among them. Without TSM, or with the line seen, this is all.
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
