local _, ns = ...

-- =====================================================================
-- Postbox :: mailbox memory
-- ---------------------------------------------------------------------
-- "What was in my mailbox?", answered away from any mailbox: a snapshot
-- of the inbox as it looked the last time this character had it open,
-- shown in a small read-only window from the minimap icon's left-click.
--
-- The snapshot is HISTORY and the window never pretends otherwise: it
-- leads with how long ago it was taken, says when new mail has arrived
-- since, and greys mails whose expiry has passed in the meantime.
--
-- Cost discipline (the reason this file is small): the capture rides the
-- MAIL_INBOX_UPDATE walks the mailbox session performs anyway, coalesced
-- to one pass per frame; the client caps the shown inbox page at ~50
-- headers however many hundreds a hoarder character holds, so a pass is
-- bounded; persistence is ONE saved-variables write per visit, at close;
-- and the window does not exist until the first time it is asked for.
-- Away from a mailbox this module is completely idle.
-- =====================================================================

ns.MailMemory = ns.MailMemory or {}
local MM = ns.MailMemory

local L = ns.L

-- The client's inbox page cap, restated here as our own bound so a future
-- client raising its page size cannot silently grow the saved record.
local MAX_MAILS = 50

local ROW_HEIGHT = 24
local WINDOW_WIDTH = 400
local LIST_MAX_HEIGHT = 320
local PAD = 12

-------------------------------------------------------------
-- 1. Capture
--
-- `live` is this visit's latest look, replaced wholesale on every coalesced
-- capture and persisted (then dropped) when the session closes. MAIL_CLOSED
-- and the interaction manager's hide event both fire for one close; dropping
-- `live` on the first persist is what makes the second arrival a no-op.
-------------------------------------------------------------

local live = nil
local captureQueued = false

local function MailboxState()
  return ns.MailboxUI and ns.MailboxUI._state or nil
end

local function CaptureNow()
  captureQueued = false

  local state = MailboxState()
  if not (state and state.mailboxOpen) then return end
  -- The inbox always reads empty between MAIL_SHOW and the first real
  -- update; a capture there would overwrite a genuine snapshot with a
  -- phantom "the box was empty". inboxSeen is MailboxUI's own record of
  -- that boundary -- the same one its status line trusts.
  if not state.inboxSeen then return end

  local numItems, totalItems = GetInboxNumItems()
  numItems = tonumber(numItems) or 0
  totalItems = tonumber(totalItems) or numItems

  local now = time()
  local mails = {}
  for index = 1, numItems do
    local packageIcon, stationeryIcon, sender, subject, money, cod, daysLeft,
      itemCount, wasRead = GetInboxHeaderInfo(index)
    -- A header that has not arrived yet answers all-nil; recording it would
    -- save a blank row for a mail the next look would fill in properly.
    if sender ~= nil or subject ~= nil then
      mails[#mails + 1] = {
        icon    = packageIcon or stationeryIcon,
        sender  = tostring(sender or ""),
        subject = tostring(subject or ""),
        money   = tonumber(money) or 0,
        cod     = tonumber(cod) or 0,
        items   = tonumber(itemCount) or 0,
        read    = wasRead and true or false,
        -- Absolute, so "has this expired since I saw it" is answerable in a
        -- later session without trusting a stale daysLeft.
        expires = now + math.floor((tonumber(daysLeft) or 0) * 86400),
      }
      if #mails >= MAX_MAILS then break end
    end
  end

  live = { seenAt = now, total = totalItems, mails = mails }
end

local function QueueCapture()
  local state = MailboxState()
  if not (state and state.mailboxOpen) or captureQueued then return end
  captureQueued = true
  local ok = pcall(C_Timer.After, 0, CaptureNow)
  if not ok then
    captureQueued = false
    CaptureNow()
  end
end

local function PersistOnClose()
  if not live then return end
  local snapshot = live
  live = nil

  local realm = GetRealmName()
  local name = UnitName("player")
  if not (realm and name) then return end

  -- Raw realm key, same convention as alts/lastRun (see Postbox.lua schema).
  local root = ns.Store.EnsurePath("mailMemory")
  root[realm] = root[realm] or {}
  root[realm][name] = snapshot
end

local function StoredSnapshot()
  local realm = GetRealmName()
  local name = UnitName("player")
  if not (realm and name) then return nil end
  local root = ns.Store and ns.Store.Get and ns.Store.Get("mailMemory")
  local byRealm = root and root[realm]
  return byRealm and byRealm[name] or nil
end

-------------------------------------------------------------
-- 2. Words for a snapshot's age
--
-- Short units rather than sentences: the header already carries the sentence.
-- All three go through the locale table like every other user-facing string.
-------------------------------------------------------------

-- "just now" / "N min ago": the AGO family carries its own "ago" so every
-- locale can put it where its grammar wants it.
local function AgeText(seenAt)
  local age = math.max(0, time() - (tonumber(seenAt) or 0))
  if age < 90 then return L["MEMORY_AGO_NOW"] end
  if age < 5400 then return string.format(L["MEMORY_AGO_M"], math.floor(age / 60 + 0.5)) end
  if age < 129600 then return string.format(L["MEMORY_AGO_H"], math.floor(age / 3600 + 0.5)) end
  return string.format(L["MEMORY_AGO_D"], math.floor(age / 86400 + 0.5))
end

-- Time REMAINING, so its units are bare ("2 d"), not the ago family's.
local function ExpiryText(expires, now)
  local left = (tonumber(expires) or 0) - now
  if left <= 0 then return L["MEMORY_EXPIRED"], true end
  if left < 86400 then return string.format(L["MEMORY_LEFT_H"], math.max(1, math.floor(left / 3600))), false end
  return string.format(L["MEMORY_LEFT_D"], math.floor(left / 86400 + 0.5)), false
end

-------------------------------------------------------------
-- 3. The window
--
-- Same construction family as the options panel: a Blizzard window template
-- (skins re-point or strip it), the addon's frame theme, Escape to close,
-- and a themed card whose children both host skins can find. Built on the
-- first Toggle and reused; rows are pooled and re-filled, never rebuilt.
-------------------------------------------------------------

local function BuildRow(parent, index)
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(ROW_HEIGHT)
  row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
  row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

  -- The stripe is the list's own even/odd wash, so the window reads as the
  -- same surface family as the mail list itself.
  local stripe = row:CreateTexture(nil, "BACKGROUND")
  stripe:SetAllPoints()
  local colors = ns.Theme and ns.Theme.RowColors
  local tint = colors and (index % 2 == 0 and colors.even or colors.odd)
  if tint then
    stripe:SetColorTexture(tint[1], tint[2], tint[3], tint[4])
  else
    stripe:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.06 or 0.03)
  end

  row.Icon = row:CreateTexture(nil, "ARTWORK")
  row.Icon:SetSize(18, 18)
  row.Icon:SetPoint("LEFT", row, "LEFT", 4, 0)
  row.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  row.Expiry = ns.Theme.CreateText(row, "tiny")
  row.Expiry:SetPoint("RIGHT", row, "RIGHT", -6, 0)
  row.Expiry:SetJustifyH("RIGHT")
  -- Wide enough for deDE's "abgelaufen", the longest word this column shows.
  row.Expiry:SetWidth(52)
  row.Expiry:SetAlpha(0.7)

  row.Value = ns.Theme.CreateText(row, "small")
  row.Value:SetPoint("RIGHT", row.Expiry, "LEFT", -8, 0)
  row.Value:SetJustifyH("RIGHT")

  row.Sender = ns.Theme.CreateText(row, "label")
  row.Sender:SetPoint("LEFT", row.Icon, "RIGHT", 6, 0)
  row.Sender:SetWidth(92)
  row.Sender:SetJustifyH("LEFT")
  row.Sender:SetWordWrap(false)

  row.Subject = ns.Theme.CreateText(row, "small")
  row.Subject:SetPoint("LEFT", row.Sender, "RIGHT", 6, 0)
  row.Subject:SetPoint("RIGHT", row.Value, "LEFT", -8, 0)
  row.Subject:SetJustifyH("LEFT")
  row.Subject:SetWordWrap(false)

  -- The full subject on hover, because the row truncates it without mercy.
  row:EnableMouse(true)
  row:SetScript("OnEnter", function(self)
    if not self.fullSubject or self.fullSubject == "" then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(self.fullSubject, 1, 1, 1, true)
    if self.fullSender and self.fullSender ~= "" then
      GameTooltip:AddLine(self.fullSender, 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)

  return row
end

local function FillRow(row, mail, now)
  row.fullSubject = mail.subject
  row.fullSender = mail.sender

  if mail.icon then
    row.Icon:SetTexture(mail.icon)
    row.Icon:Show()
  else
    row.Icon:Hide()
  end

  row.Sender:SetText(mail.sender)
  row.Subject:SetText(mail.subject)

  local money = ns.Helpers and ns.Helpers.FormatMoney
  if mail.cod > 0 then
    row.Value:SetText(L["MEMORY_COD"])
    row.Value:SetTextColor(0.90, 0.45, 0.35)
  elseif mail.money > 0 and money then
    row.Value:SetText(money(mail.money))
    row.Value:SetTextColor(1, 1, 1)
  elseif mail.items > 0 then
    row.Value:SetText(ns.Plural("COUNT_SLOTS", mail.items))
    row.Value:SetTextColor(1, 1, 1)
  else
    row.Value:SetText("")
  end

  local expiryText, expired = ExpiryText(mail.expires, now)
  row.Expiry:SetText(expiryText)
  -- A mail past its date is PROBABLY gone (returned or deleted by the
  -- server); the row stays listed -- it was true when seen -- but visibly
  -- belongs to the past.
  row:SetAlpha(expired and 0.45 or 1)
  row:Show()
end

local function Refresh(frame)
  local snapshot = live or StoredSnapshot()
  local now = time()

  if not snapshot then
    frame.Header:SetText(L["MEMORY_EMPTY"])
    frame.NewSince:Hide()
    frame.More:Hide()
    frame.Card:SetHeight(1)
    frame.Card:Hide()
    for i = 1, #frame.Rows do frame.Rows[i]:Hide() end
    return
  end

  local mails = snapshot.mails or {}
  local counted = ns.Plural("COUNT_MAILS", #mails)
  frame.Header:SetText(string.format(L["MEMORY_ASOF"], AgeText(snapshot.seenAt), counted))

  -- Only claimable while the client still says there is unread mail waiting;
  -- HasNewMail is the same signal the default indicator trusts.
  local hasNew = type(HasNewMail) == "function" and HasNewMail()
  frame.NewSince:SetShown(hasNew and true or false)

  local hidden = math.max(0, (tonumber(snapshot.total) or #mails) - #mails)
  if hidden > 0 then
    frame.More:SetText(string.format(L["MEMORY_MORE"], hidden))
    frame.More:Show()
  else
    frame.More:Hide()
  end

  if #mails == 0 then
    frame.Header:SetText(string.format(L["MEMORY_ASOF_EMPTY"], AgeText(snapshot.seenAt)))
    frame.Card:Hide()
    for i = 1, #frame.Rows do frame.Rows[i]:Hide() end
  else
    frame.Card:Show()
    for i = 1, #mails do
      local row = frame.Rows[i]
      if not row then
        row = BuildRow(frame.ListChild, i)
        frame.Rows[i] = row
      end
      FillRow(row, mails[i], now)
    end
    for i = #mails + 1, #frame.Rows do frame.Rows[i]:Hide() end

    local listHeight = math.min(#mails * ROW_HEIGHT, LIST_MAX_HEIGHT)
    frame.ListChild:SetHeight(#mails * ROW_HEIGHT)
    frame.Scroll:SetHeight(listHeight)
    frame.Card:SetHeight(listHeight + 2)
  end

  -- The bands above the card decide the window's height; measure rather than
  -- guess so hiding a line never leaves a hole.
  local headerBlock = 30
  if frame.NewSince:IsShown() then headerBlock = headerBlock + 16 end
  if frame.More:IsShown() then headerBlock = headerBlock + 16 end
  local cardHeight = frame.Card:IsShown() and (frame.Scroll:GetHeight() + 2) or 0
  frame:SetHeight(28 + headerBlock + cardHeight + PAD)

  frame.Card:ClearAllPoints()
  frame.Card:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -(28 + headerBlock))
  frame.Card:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
end

local function Build()
  if MM._frame then return MM._frame end

  local frame = CreateFrame("Frame", "PostboxMailMemoryFrame", UIParent,
                            "BasicFrameTemplateWithInset")
  frame:SetWidth(WINDOW_WIDTH)
  frame:SetFrameStrata("DIALOG")
  frame:SetToplevel(true)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:Hide()

  -- A floating note over the game world: readable always, whatever opacity
  -- the main window runs at. Skin.ApplyBgOpacity honours this flag.
  frame.__pbEuiAlwaysOpaque = true

  -- TitleText is not guaranteed on this template across the two declared
  -- interface versions; same guard as the options panel.
  if frame.SetTitle then
    frame:SetTitle(L["MEMORY_TITLE"])
  elseif frame.TitleText then
    frame.TitleText:SetText(L["MEMORY_TITLE"])
  end
  ns.Theme.ApplyFrameTheme(frame)
  ns.Core.UI.Helpers.RegisterEscClose(frame)

  frame.Header = ns.Theme.CreateText(frame, "label")
  frame.Header:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -32)
  frame.Header:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
  frame.Header:SetJustifyH("LEFT")
  frame.Header:SetWordWrap(false)

  frame.NewSince = ns.Theme.CreateText(frame, "small")
  frame.NewSince:SetPoint("TOPLEFT", frame.Header, "BOTTOMLEFT", 0, -4)
  frame.NewSince:SetText(L["MEMORY_NEW_SINCE"])
  local r, g, b = ns.Theme.GetAccent()
  frame.NewSince:SetTextColor(r, g, b)
  frame.NewSince:Hide()

  frame.More = ns.Theme.CreateText(frame, "tiny")
  frame.More:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, 6)
  frame.More:SetAlpha(0.7)
  frame.More:Hide()

  local card = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  ns.Theme.ApplyList(card)
  frame.Card = card

  frame.Scroll = CreateFrame("ScrollFrame", nil, card, "UIPanelScrollFrameTemplate")
  frame.Scroll:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -1)
  frame.Scroll:SetPoint("RIGHT", card, "RIGHT", -1, 0)

  frame.ListChild = CreateFrame("Frame", nil, frame.Scroll)
  frame.ListChild:SetWidth(WINDOW_WIDTH - 22)
  frame.Scroll:SetScrollChild(frame.ListChild)

  frame.Rows = {}

  -- Same expression as the options panel and the recipient manager: let an
  -- active host-UI skin restyle the shell, whichever entry point it offers.
  local applyWindow = ns.Skin and (ns.Skin.ApplyWindow or ns.Skin.Apply)
  if applyWindow then applyWindow(frame) end

  MM._frame = frame
  return frame
end

-------------------------------------------------------------
-- 4. Public API
-------------------------------------------------------------

-- The minimap icon's left-click. At an open mailbox this is a no-op by
-- contract: the real window is on screen and it is the truth.
function MM.Toggle(anchor)
  local state = MailboxState()
  if state and state.mailboxOpen then return end

  local frame = Build()
  if frame:IsShown() then
    frame:Hide()
    return
  end

  Refresh(frame)
  frame:ClearAllPoints()
  if anchor then
    frame:SetPoint("TOPRIGHT", anchor, "BOTTOMLEFT", 0, -4)
  else
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
  end
  frame:Show()
  frame:Raise()
  if ns.Skin and ns.Skin.Refresh then pcall(ns.Skin.Refresh, frame) end
end

-------------------------------------------------------------
-- 5. Event wiring
--
-- Registered once at load; every handler stands down in one comparison
-- while no mailbox session is open, which is this module's idle state.
-------------------------------------------------------------

local bus = ns.Events
if bus then
  bus.Register("MAIL_INBOX_UPDATE", QueueCapture)
  bus.Register("MAIL_CLOSED", PersistOnClose)
end
