local _, ns = ...

-- =====================================================================
-- Postbox :: mailbox memory
-- ---------------------------------------------------------------------
-- "What was in my mailbox?", answered away from any mailbox: a snapshot
-- of the inbox as it looked the last time this character had it open,
-- shown in a small read-only window from the minimap icon's left-click.
--
-- The snapshot is HISTORY and the window never pretends otherwise: it
-- leads with how long ago it was taken, flags new arrivals since, and
-- greys mails whose expiry has passed in the meantime.
--
-- Cost discipline (the reason this file is small): the capture rides the
-- MAIL_INBOX_UPDATE walks the mailbox session performs anyway, coalesced
-- to one pass per frame; the client caps the shown inbox page at ~50
-- headers however many hundreds a hoarder character holds, so a pass is
-- bounded; persistence is ONE saved-variables write per visit, at close;
-- and the window does not exist until the first time it is asked for.
-- Away from a mailbox this module is completely idle, and the "Mailbox
-- memory" option (on by default) turns even that idle wiring into two
-- one-comparison no-ops.
-- =====================================================================

ns.MailMemory = ns.MailMemory or {}
local MM = ns.MailMemory

local L = ns.L

-- Our own bound on the saved record. It was 50 -- the page the client used
-- to show -- and the client now shows more, so a full box was cut off at 50
-- while the Collect tab counted 56. The client's inbox holds at most 100.
local MAX_MAILS = 100

local ROW_HEIGHT = 24
local WINDOW_WIDTH = 400
local PAD = 12

-- The window's fixed chrome: title bar plus the header line above the card,
-- and the strip below it that holds the overflow note and the resize grip.
-- The card fills whatever is between the two, which is what makes the resize
-- grip work with no per-drag layout code at all.
local CHROME_TOP = 52
local CHROME_BOTTOM = 26

-- Six rows: the default AND the floor -- enough to be useful, small enough
-- to stay a note rather than a second mail window; the grip only ever
-- grows it toward the content. Height only — the width is not resizable,
-- so the bounds pin it.
local DEFAULT_ROWS = 6
local MIN_ROWS = 6

local function RowsHeight(rows)
  return CHROME_TOP + CHROME_BOTTOM + rows * ROW_HEIGHT + 2
end

-- A hover target takes MOTION and never clicks. This window is dragged from
-- anywhere on it, so a child that swallows the mouse-down is a patch the
-- window cannot be dragged by -- which is exactly what the main window's
-- status label did to its own title bar. Nothing here wants a click.
local function HoverOnly(frame)
  if frame.SetMouseMotionEnabled and frame.SetMouseClickEnabled then
    frame:SetMouseClickEnabled(false)
    frame:SetMouseMotionEnabled(true)
    if frame.SetPropagateMouseClicks then frame:SetPropagateMouseClicks(true) end
  else
    frame:EnableMouse(false)
  end
end

-- The refusal marker's art. The candidate list is Theme.AtlasSets.warning --
-- literally the same table Core/CollectTab.lua probes, not a matching copy --
-- so the two screens cannot land on different art on a client that has only the
-- second choice. Theme memoises the probe per name.
local function WarningAtlas()
  return ns.Theme.FirstAtlas(ns.Theme.AtlasSets.warning)
end

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

-- Session timestamps for the arrival watch (section 5): the client fires
-- UPDATE_PENDING_MAIL at login to establish state and churns it around a
-- mailbox close, and neither is an arrival.
local loginAt = nil
local closedAt = 0

-- What the last pending-mail event did, for /postbox debug: "does the event
-- even fire here" was undiagnosable from the outside for two releases.
local lastPendingAt = nil
local lastPendingVerdict = "never fired"

-- Filled by the event wiring (section 5); read by Diagnose, which is why it
-- is declared here rather than beside the Register calls.
local registered = {}

local function MailboxState()
  return ns.MailboxUI and ns.MailboxUI._state or nil
end

local function MemoryEnabled()
  local UI = ns.MailboxUI
  if UI and type(UI.GetOption) == "function" then
    return UI.GetOption("mailMemory")
  end
  return true
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
      -- The first attachment's link, when the client has it (links exist
      -- only for mail whose body has been fetched, i.e. read mail). It
      -- buys the row a real item tooltip later, at the cost of one string.
      local link
      if (tonumber(itemCount) or 0) > 0 and type(GetInboxItemLink) == "function" then
        link = GetInboxItemLink(index, 1)
      end
      -- Whether the server refused this mail's attachments on a previous
      -- attempt. Read from the domain's registry at capture time, because
      -- it is session state -- the record has to carry it or a reopened
      -- memory could not tell a stuck mail from an ordinary one.
      local stuck = false
      local service = ns.MailService
      if service and type(service.StuckReason) == "function" then
        local ok, reason = pcall(service.StuckReason, index)
        stuck = (ok and reason) and true or false
      end
      -- What kind of mail it is, so the row can say "AH Sold" in its tone as
      -- the mail list does; and what a won auction cost, which only its
      -- invoice knows. "other" is not stored: it is what a missing kind means.
      local kind, paid
      if service and type(service.ClassifyMail) == "function" then
        local ok, k = pcall(service.ClassifyMail, index)
        if ok and k ~= "other" then kind = k end
      end
      if kind == "bought" and type(GetInboxInvoiceInfo) == "function" then
        local ok, invoiceType, _, _, bid = pcall(GetInboxInvoiceInfo, index)
        bid = ok and tonumber(bid) or 0
        if invoiceType == "buyer" and bid > 0 then paid = bid end
      end

      mails[#mails + 1] = {
        stuck   = stuck,
        icon    = packageIcon or stationeryIcon,
        sender  = tostring(sender or ""),
        subject = tostring(subject or ""),
        money   = tonumber(money) or 0,
        cod     = tonumber(cod) or 0,
        items   = tonumber(itemCount) or 0,
        read    = wasRead and true or false,
        link    = link,
        kind    = kind,
        paid    = paid,
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
  if not MemoryEnabled() then return end
  captureQueued = true
  local ok = pcall(C_Timer.After, 0, CaptureNow)
  if not ok then
    captureQueued = false
    CaptureNow()
  end
end

-- The senders of the latest unread mails, as one comparable string. This is
-- the arrival detector that needs no event: any mail landing -- even while
-- logged out -- reshuffles this triple, and the snapshot remembers what it
-- was at close.
local function SenderTriple()
  if type(GetLatestThreeSenders) ~= "function" then return nil end
  local a, b, c = GetLatestThreeSenders()
  if a == nil and b == nil and c == nil then return "" end
  return tostring(a) .. "\001" .. tostring(b) .. "\001" .. tostring(c)
end

local function PersistOnClose()
  if not live then return end
  local snapshot = live
  live = nil

  -- The arrival baseline, taken at the boundary the badge measures from:
  -- what the client's unread indicators said the moment the box closed.
  snapshot.baseNew = type(HasNewMail) == "function" and HasNewMail() and true or false
  snapshot.baseFrom = SenderTriple()

  local realm = GetRealmName()
  local name = UnitName("player")
  if not (realm and name) then return end

  -- Raw realm key, same convention as alts/lastRun (see Postbox.lua schema).
  local root = ns.Store.EnsurePath("mailMemory")
  root[realm] = root[realm] or {}
  root[realm][name] = snapshot
  -- Defined in section 2b, below this function in the file.
  if MM._SettleWatch then MM._SettleWatch(realm, name, snapshot.seenAt or time()) end
end

local function StoredSnapshot()
  local realm = GetRealmName()
  local name = UnitName("player")
  if not (realm and name) then return nil end
  local root = ns.Store and ns.Store.Get and ns.Store.Get("mailMemory")
  local byRealm = root and root[realm]
  return byRealm and byRealm[name] or nil
end

-- A snapshot from before the baseline fields existed cannot support the
-- flip/triple detectors. Heal it at the first away-from-box look: the
-- baseline becomes NOW, so arrivals from this moment on are detectable
-- without demanding a fresh mailbox visit first. Run at login too, so an
-- arrival between login and the first window-open is not folded into the
-- healed baseline.
local function EnsureBaseline(snap)
  if not snap or snap.baseFrom ~= nil then return end
  local state = MailboxState()
  if state and state.mailboxOpen then return end
  snap.baseFrom = SenderTriple()
  snap.baseNew = type(HasNewMail) == "function" and HasNewMail() and true or false
end

-------------------------------------------------------------
-- 2. Words for a snapshot's age
--
-- The AGO family carries its own "ago" so every locale can put it where its
-- grammar wants it; time REMAINING uses bare units, a different family.
-------------------------------------------------------------

local function AgeText(seenAt)
  local age = math.max(0, time() - (tonumber(seenAt) or 0))
  if age < 90 then return L["MEMORY_AGO_NOW"] end
  if age < 5400 then return string.format(L["MEMORY_AGO_M"], math.floor(age / 60 + 0.5)) end
  if age < 129600 then return string.format(L["MEMORY_AGO_H"], math.floor(age / 3600 + 0.5)) end
  return string.format(L["MEMORY_AGO_D"], math.floor(age / 86400 + 0.5))
end

-- Mail that still HOLDS something -- items, gold or a C.O.D. -- grouped by
-- sender, biggest group first. This is the one summary in the addon built
-- from mails actually read rather than inferred: every count is a fact
-- about a mail in the record.
--
-- Deliberately not "unread": a mail that was opened but whose attachment
-- the server refused is read AND still waiting, which is exactly the stuck
-- Postmaster mail an unread test silently dropped. An opened text-only
-- mail holds nothing and is correctly absent.
-- `wantStuck` selects which half is being asked for: nil counts every mail
-- that holds something, false only the ones the server has not refused,
-- true only the refused ones.
local function WaitingBySender(snap, wantStuck)
  local counts, order = {}, {}
  local mails = snap and snap.mails or {}
  for i = 1, #mails do
    local mail = mails[i]
    local holds = (mail.items or 0) > 0 or (mail.money or 0) > 0 or (mail.cod or 0) > 0
      or not mail.read
    if wantStuck ~= nil then
      holds = holds and ((mail.stuck and true or false) == wantStuck)
    end
    if holds then
      local who = (mail.sender ~= "" and mail.sender) or L["MEMORY_SENDER_UNKNOWN"]
      if counts[who] then
        counts[who] = counts[who] + 1
      else
        counts[who] = 1
        order[#order + 1] = who
      end
    end
  end
  table.sort(order, function(a, b)
    if counts[a] ~= counts[b] then return counts[a] > counts[b] end
    return a < b
  end)
  return order, counts
end

local function ExpiryText(expires, now)
  local left = (tonumber(expires) or 0) - now
  if left <= 0 then return L["MEMORY_EXPIRED"], true end
  if left < 86400 then return string.format(L["MEMORY_LEFT_H"], math.max(1, math.floor(left / 3600))), false end
  return string.format(L["MEMORY_LEFT_D"], math.floor(left / 86400 + 0.5)), false
end

-------------------------------------------------------------
-- 2b. Every character's mailbox
--
-- The memory is account-wide already (realm -> name -> snapshot), so what
-- every other character's box held is on disk. Two things a snapshot cannot
-- know are kept beside it, in `mailWatch` (realm -> name):
--
--   newAt          the first time since that character's last mailbox visit
--                  that mail is KNOWN to have arrived: an arrival event, an
--                  auction bought or expired, the unread flag up at login
--                  when it was down at the last close, or Postbox sending it
--                  mail from another character.
--   auctionAt /    an auction was posted, and its mail -- the gold, or the
--   auctionsUntil  item back -- has had no visit to land in yet. Until is the
--                  latest such auction could end (48h, the longest listing).
--
-- Mail lives thirty days. Either time is therefore the earliest that unseen
-- mail could start to be lost, and a character is flagged a week before it.
-- A character whose snapshot holds mail under three days from expiring is
-- flagged too. That is the whole of it: nothing is guessed, and a character
-- with nothing on the way says nothing, however long it has been idle.
-------------------------------------------------------------

local DAY = 86400
local SOON = 3 * DAY
local UNSEEN_WARN = 23 * DAY
local AUCTION_LONGEST = 48 * 3600

local function Me()
  return GetRealmName(), UnitName("player")
end

local function WatchFor(realm, name, create)
  if not (realm and name) then return nil end
  local root
  if create then
    root = ns.Store.EnsurePath("mailWatch")
  else
    root = ns.Store and ns.Store.Get and ns.Store.Get("mailWatch")
  end
  if type(root) ~= "table" then return nil end
  local byRealm = root[realm]
  if type(byRealm) ~= "table" then
    if not create then return nil end
    byRealm = {}
    root[realm] = byRealm
  end
  local watch = byRealm[name]
  if type(watch) ~= "table" and create then
    watch = {}
    byRealm[name] = watch
  end
  return watch
end

local function SnapshotFor(realm, name)
  local root = ns.Store and ns.Store.Get and ns.Store.Get("mailMemory")
  local byRealm = type(root) == "table" and root[realm] or nil
  return type(byRealm) == "table" and byRealm[name] or nil
end

-- Mail is known to have arrived for this character.
local function NoteArrival(realm, name)
  if not MemoryEnabled() then return end
  local watch = WatchFor(realm, name, true)
  if watch and not watch.newAt then watch.newAt = time() end
end

-- This character's box was opened and recorded: what the watch guarded is in
-- the snapshot now. An auction still running can send mail after the visit,
-- so it stays watched -- from now.
function MM._SettleWatch(realm, name, now)
  local watch = WatchFor(realm, name, false)
  if not watch then return end
  watch.newAt = nil
  if watch.auctionsUntil and watch.auctionsUntil > now then
    watch.auctionAt = now
  else
    watch.auctionAt, watch.auctionsUntil = nil, nil
  end
end

-- A mail waits while it holds anything, or is unread: the Collect tab's rule.
local function Holds(mail)
  return (mail.items or 0) > 0 or (mail.money or 0) > 0 or (mail.cod or 0) > 0 or not mail.read
end

-- realm, name, now -> what there is to say about that character's mail.
--   waiting    mails in its snapshot still waiting
--   soon       how many of them expire within three days, and `soonest`
--   unseenDays set when mail known to be on the way has gone unopened
--              long enough to be a week from its earliest loss
local function Status(realm, name, now)
  local snap = SnapshotFor(realm, name)
  local st = { realm = realm, name = name, waiting = 0, seenAt = snap and snap.seenAt or nil }
  local mails = snap and snap.mails or {}
  for i = 1, #mails do
    local mail = mails[i]
    if Holds(mail) then
      st.waiting = st.waiting + 1
      local left = (tonumber(mail.expires) or 0) - now
      if left > 0 and left < SOON then
        st.soon = (st.soon or 0) + 1
        if not st.soonest or mail.expires < st.soonest then st.soonest = mail.expires end
      end
    end
  end
  local watch = WatchFor(realm, name, false)
  if watch then
    local since = watch.newAt
    if watch.auctionAt and (not since or watch.auctionAt < since) then since = watch.auctionAt end
    if since and now - since >= UNSEEN_WARN then
      st.unseenDays = math.floor((now - (st.seenAt or since)) / DAY)
    end
  end
  st.warn = (st.soon ~= nil) or (st.unseenDays ~= nil)
  return st
end

-- The status as a phrase, in the warning tone; nil when there is none.
local function WarningText(st, now)
  local parts = {}
  if st.soon then
    parts[#parts + 1] = ns.Plural("OVERVIEW_EXPIRE", st.soon, (ExpiryText(st.soonest, now)))
  end
  if st.unseenDays then
    parts[#parts + 1] = ns.Plural("OVERVIEW_UNSEEN", st.unseenDays)
  end
  if #parts == 0 then return nil end
  return table.concat(parts, "; ")
end

-- A character's name as the lists show it: the realm only when it is not
-- the one being played.
local function CharacterLabel(realm, name)
  local myRealm = GetRealmName()
  if realm ~= myRealm then return name .. " - " .. realm end
  return name
end

-- Every character Postbox knows a mailbox for: this one first, then those
-- with something to say, then by name.
function MM.Characters()
  local now = time()
  local seen, list = {}, {}
  local function Add(realm, name)
    local key = realm .. "\001" .. name
    if seen[key] then return end
    seen[key] = true
    list[#list + 1] = Status(realm, name, now)
  end
  for _, rootName in ipairs({ "mailMemory", "mailWatch" }) do
    local root = ns.Store and ns.Store.Get and ns.Store.Get(rootName)
    if type(root) == "table" then
      for realm, byRealm in pairs(root) do
        if type(byRealm) == "table" then
          for name in pairs(byRealm) do Add(realm, name) end
        end
      end
    end
  end
  local myRealm, myName = Me()
  table.sort(list, function(a, b)
    local aMe = (a.realm == myRealm and a.name == myName)
    local bMe = (b.realm == myRealm and b.name == myName)
    if aMe ~= bMe then return aMe end
    if a.warn ~= b.warn then return a.warn end
    if a.name ~= b.name then return a.name < b.name end
    return a.realm < b.realm
  end)
  for i = 1, #list do
    local st = list[i]
    st.me = (st.realm == myRealm and st.name == myName)
    st.label = CharacterLabel(st.realm, st.name)
    st.text = WarningText(st, now)
  end
  return list
end

-- The other characters with something to say, for the minimap tooltip and
-- the login line. Empty when memory is off.
function MM.OtherWarnings()
  local out = {}
  if not MemoryEnabled() then return out end
  local all = MM.Characters()
  for i = 1, #all do
    if all[i].warn and not all[i].me then out[#out + 1] = all[i] end
  end
  return out
end

-- Postbox just sent mail to `toName`. If that is one of the player's own
-- characters, mail is now waiting in its box -- and nothing else would know,
-- if that character is not played for a month.
function MM.NoteSentTo(toName)
  if not MemoryEnabled() or type(toName) ~= "string" or toName == "" then return end
  local R = ns.Recipients
  if not (R and type(R.Key) == "function") then return end
  local key = R.Key(toName)
  local alts = ns.Store and ns.Store.Get and ns.Store.Get("alts")
  if not key or type(alts) ~= "table" then return end
  local myRealm, myName = Me()
  for realm, names in pairs(alts) do
    if type(names) == "table" then
      for i = 1, #names do
        local name = names[i]
        if not (realm == myRealm and name == myName) and R.Key(name .. "-" .. realm) == key then
          NoteArrival(realm, name)
          return
        end
      end
    end
  end
end

-------------------------------------------------------------
-- 2c. What came out of the box
--
-- A short record of what Postbox collected on each character: a week of it,
-- at most HISTORY_CAP entries, one entry per mail however many takes that
-- mail needed. Written by Core/MailService.lua as each take is CONFIRMED --
-- never when the command is sent, since the server may refuse it -- and read
-- by the Mail tab's History view. Pruned on every write, so it never holds
-- more than the week it shows.
-------------------------------------------------------------

local HISTORY_KEEP = 7 * DAY
local HISTORY_CAP = 500

local function HistoryList(create)
  local realm, name = Me()
  if not (realm and name) then return nil end
  local root
  if create then
    root = ns.Store.EnsurePath("mailHistory")
  else
    root = ns.Store and ns.Store.Get and ns.Store.Get("mailHistory")
  end
  if type(root) ~= "table" then return nil end
  local byRealm = root[realm]
  if type(byRealm) ~= "table" then
    if not create then return nil end
    byRealm = {}
    root[realm] = byRealm
  end
  local list = byRealm[name]
  if type(list) ~= "table" and create then
    list = {}
    byRealm[name] = list
  end
  return list
end

local function PruneHistory(list, now)
  local cutoff = now - HISTORY_KEEP
  local drop = 0
  while list[drop + 1] and ((tonumber(list[drop + 1].t) or 0) < cutoff or #list - drop > HISTORY_CAP) do
    drop = drop + 1
  end
  if drop > 0 then
    for i = 1, #list - drop do list[i] = list[i + drop] end
    for i = #list, #list - drop + 1, -1 do list[i] = nil end
  end
end

-- This character's record, oldest first, pruned to the week; empty when
-- there is none.
function MM.History()
  local list = HistoryList(false)
  if not list then return {} end
  PruneHistory(list, time())
  return list
end

-- index -> what is known about the mail before anything is taken from it,
-- or nil when its header has not arrived. Its first confirmed take turns it
-- into an entry.
function MM.HistoryBegin(index)
  local _, _, sender, subject, _, cod = GetInboxHeaderInfo(index)
  if sender == nil and subject == nil then return nil end
  local service = ns.MailService
  local kind = service and service.ClassifyMail and service.ClassifyMail(index) or "other"
  local price
  if kind == "bought" and type(GetInboxInvoiceInfo) == "function" then
    local invoiceType, _, _, bid = GetInboxInvoiceInfo(index)
    bid = tonumber(bid) or 0
    if invoiceType == "buyer" and bid > 0 then price = bid end
  end
  return {
    sender = tostring(sender or ""), subject = tostring(subject or ""),
    kind = kind, cod = tonumber(cod) or 0, price = price,
  }
end

-- One confirmed take from the mail `ctx` describes: "money" and a sum in
-- copper, or "item", a link and a count. The first take of a C.O.D. mail is
-- the one that paid the price.
function MM.HistoryTook(ctx, what, value, count)
  if not ctx then return end
  local list = HistoryList(true)
  if not list then return end
  local entry = ctx.entry
  if not entry then
    entry = {
      t = time(),
      s = ctx.sender,
      k = (ctx.kind ~= "other") and ctx.kind or nil,
      sub = ctx.subject,
    }
    list[#list + 1] = entry
    ctx.entry = entry
    PruneHistory(list, entry.t)
  end
  if what == "money" then
    entry.m = (entry.m or 0) + (tonumber(value) or 0)
    return
  end
  if ctx.cod > 0 and not ctx.codPaid then
    entry.c = ctx.cod
    ctx.codPaid = true
  end
  if ctx.price and not entry.p then entry.p = ctx.price end
  if type(value) ~= "string" then return end
  entry.it = entry.it or {}
  for i = 1, #entry.it do
    if entry.it[i].l == value then
      entry.it[i].n = (entry.it[i].n or 1) + (tonumber(count) or 1)
      return
    end
  end
  entry.it[#entry.it + 1] = { l = value, n = tonumber(count) or 1 }
end

-------------------------------------------------------------
-- 3. The window
--
-- Same construction family as the options panel: a Blizzard window template
-- (skins re-point or strip it), the addon's frame theme, Escape to close,
-- and a themed card whose children both host skins can find. Built on the
-- first Toggle and reused; rows are pooled and re-filled, never rebuilt.
--
-- The card is anchored to the window's edges, so the resize grip needs no
-- layout code: dragging the grip stretches the card and the scroll frame
-- inside it, and the scrollbar absorbs whatever no longer fits.
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

  -- The same three figure columns the compact mail list stands at its right
  -- edge -- time left, money, slots -- placed on fill, because where each
  -- stands depends on the whole snapshot (see FillRow).
  row.ColTime = ns.Theme.CreateText(row, "secondary")
  row.ColMoney = ns.Theme.CreateText(row, "secondary")
  row.ColSlots = ns.Theme.CreateText(row, "secondary")
  row.ColTime:SetJustifyH("RIGHT")
  row.ColMoney:SetJustifyH("RIGHT")
  row.ColSlots:SetJustifyH("RIGHT")

  -- The same marker the collect screen puts on a refused mail: the client's
  -- warning-triangle atlas where it exists, the "!" only as the fallback
  -- for a client that lacks it -- and in the same place, the row's right
  -- end after the expiry. A mail the server would not hand over should look
  -- identical wherever Postbox shows it, and it was wearing the fallback
  -- here while the mail list wore the triangle.
  local atlas = WarningAtlas()
  if atlas then
    row.Warning = row:CreateTexture(nil, "OVERLAY")
    row.Warning:SetAtlas(atlas, false)
    row.Warning:SetSize(12, 12)
  else
    row.Warning = ns.Theme.CreateText(row, "value")
    row.Warning:SetText("!")
  end
  row.Warning:SetPoint("RIGHT", row, "RIGHT", -4, 0)
  ns.Theme.SetColor(row.Warning, "warning")
  row.Warning:Hide()

  -- Sender and subject in the mail list's own roles and widths, so a memory
  -- row reads as the row it was.
  row.Sender = ns.Theme.CreateText(row, "label")
  row.Sender:SetPoint("LEFT", row.Icon, "RIGHT", 6, 0)
  row.Sender:SetJustifyH("LEFT")
  row.Sender:SetWordWrap(false)

  row.Subject = ns.Theme.CreateText(row, "value")
  row.Subject:SetPoint("LEFT", row.Sender, "RIGHT", 6, 0)
  row.Subject:SetJustifyH("LEFT")
  row.Subject:SetWordWrap(false)

  -- The tooltip belongs to the ICON, not the whole row: a row-wide hit area
  -- meant the tooltip followed the cursor across a list you were only
  -- scanning, and covered the rows below whatever you happened to pass
  -- over. Hovering the item is a deliberate act; hovering a row is not.
  --
  -- A real item tooltip where the snapshot kept a link (read mail only --
  -- unread mail's links were never loaded, and this window does not talk to
  -- the server). Otherwise the full subject, which the row truncates
  -- without mercy.
  local hit = CreateFrame("Frame", nil, row)
  hit:SetPoint("TOPLEFT", row.Icon, "TOPLEFT", -2, 2)
  hit:SetPoint("BOTTOMRIGHT", row.Icon, "BOTTOMRIGHT", 2, -2)
  HoverOnly(hit)
  hit:SetScript("OnEnter", function(self)
    if row.itemLink then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink(row.itemLink)
      GameTooltip:Show()
      return
    end
    if not row.fullSubject or row.fullSubject == "" then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(row.fullSubject, 1, 1, 1, true)
    if row.fullSender and row.fullSender ~= "" then
      GameTooltip:AddLine(row.fullSender, 0.7, 0.7, 0.7)
    end
    -- The figures an option keeps off the row, and the time left, which the
    -- row shows only when it is short.
    if row.factsTip then
      for line in row.factsTip:gmatch("[^\n]+") do GameTooltip:AddLine(line, 1, 1, 1, true) end
    end
    if row.expiryTip then GameTooltip:AddLine(row.expiryTip, 0.75, 0.75, 0.75) end
    GameTooltip:Show()
  end)
  hit:SetScript("OnLeave", function() GameTooltip:Hide() end)

  return row
end

-- The mail row rules (Core/CollectTab.lua's CT.RowRules), or nil when the
-- collect screen has not loaded -- in which case the row falls back to plain
-- text, which is still a correct if plainer row.
local function Rules()
  return ns.CollectTab and ns.CollectTab.RowRules or nil
end

-- mail, now -> the row's three figures as coloured text (or nil each), what
-- the switches keep off the row for its tooltip, and the time-left line.
local function Figures(mail, now)
  local R = Rules()
  local T = ns.Theme
  local hasCOD = mail.cod > 0
  local money, moneyKind
  if R then money, moneyKind = R.MoneyText(hasCOD, mail.money, mail.cod, mail.paid, true) end
  local slots = (mail.items > 0) and T.Colorize("accent", ns.Plural("COUNT_SLOTS", mail.items)) or nil

  -- Time left as the mail list shows it: only when short, in the warning
  -- tone -- and "expired" counts as short.
  local expiryText, expired = ExpiryText(mail.expires, now)
  local left = (tonumber(mail.expires) or 0) - now
  local soon = (R and R.EXPIRY_SOON_DAYS or 3) * 86400
  if hasCOD then soon = 86400 end
  local expiry = (expired or left < soon) and T.Colorize("warning", expiryText) or nil

  local facts = {}
  if R and money and not R.MoneyShown(moneyKind) then
    facts[#facts + 1] = R.MoneyText(hasCOD, mail.money, mail.cod, mail.paid, false)
    money = nil
  end
  if R and slots and not R.Shows("rowSlots") then
    facts[#facts + 1] = slots
    slots = nil
  end
  if R and not R.Shows("rowExpiry") then expiry = nil end
  return money, slots, expiry, (#facts > 0) and table.concat(facts, "\n") or nil, expiryText, expired
end

-- The snapshot's column widths, measured over every mail in it: the same
-- "widest entry anywhere" rule the mail list uses, so nothing twitches as the
-- window scrolls. `sample` is a built row, for its fonts.
local function MeasureColumns(frame, mails, now, sample)
  local R = Rules()
  local cols = frame._cols or {}
  frame._cols = cols
  cols.money, cols.slots, cols.time, cols.stuck = 0, 0, 0, false
  if not R then
    cols.sender = 92
    return cols
  end
  -- The widest name shown, up to the auction labels' width: the mail list's rule.
  local cap = R.SenderColumn(frame, sample.Sender)
  cols.sender = 0
  for i = 1, #mails do
    local mail = mails[i]
    if cols.sender < cap then
      local label = R.OutcomeSender(mail.kind) or R.DisplaySender(mail.sender) or ""
      cols.sender = math.min(math.max(cols.sender, R.Measure(frame, sample.Sender, label) + 2), cap)
    end
    local money, slots, expiry = Figures(mails[i], now)
    if money then cols.money = math.max(cols.money, R.Measure(frame, sample.ColMoney, money)) end
    if slots then cols.slots = math.max(cols.slots, R.Measure(frame, sample.ColSlots, slots)) end
    if expiry then cols.time = math.max(cols.time, R.Measure(frame, sample.ColTime, expiry)) end
    if mails[i].stuck then cols.stuck = true end
  end
  return cols
end

local Refresh

local function FillRow(row, mail, now, cols)
  local R = Rules()
  local T = ns.Theme
  row.fullSubject = mail.subject
  row.fullSender = mail.sender
  row.itemLink = mail.link

  if mail.icon then
    row.Icon:SetTexture(mail.icon)
    row.Icon:Show()
  else
    row.Icon:Hide()
  end

  row.Warning:SetShown(mail.stuck and true or false)

  local money, slots, expiry, facts, expiryText, expired = Figures(mail, now)
  row.factsTip = facts
  row.expiryTip = expiryText

  -- Right to left, as the compact mail list: slots on the edge, money inside
  -- them, time left inside that, each at the width the snapshot measured.
  -- The stuck marker's room is kept on every row when any mail has one.
  local width = WINDOW_WIDTH - 44
  local trail = 6 + (cols.stuck and 16 or 0)
  local textWidth = width - (4 + 18 + 6) - trail
  local right = trail
  if R then
    local room = math.floor(textWidth * R.META_SHARE)
    right = R.PlaceColumn(row, row.ColSlots, right, cols.slots, slots, room)
    right = R.PlaceColumn(row, row.ColMoney, right, cols.money, money, room - (right - trail))
    right = R.PlaceColumn(row, row.ColTime, right, cols.time, expiry, room - (right - trail))
  end

  local senderText = (R and (R.OutcomeSender(mail.kind) or R.DisplaySender(mail.sender))) or mail.sender
  local subject = (ns.Helpers and ns.Helpers.ShortSubject) and ns.Helpers.ShortSubject(mail.subject) or mail.subject
  local lineWidth = math.max(textWidth - (right - trail), 40)
  local senderWidth = math.min(cols.sender, math.floor(lineWidth / 2))
  T.FitText(row.Sender, senderWidth, senderText, nil)
  T.FitText(row.Subject, math.max(lineWidth - senderWidth - 6, 20), subject, nil)

  -- A mail past its date is PROBABLY gone (returned or deleted by the
  -- server); the row stays listed -- it was true when seen -- but visibly
  -- belongs to the past.
  row:SetAlpha(expired and 0.45 or 1)
  row:Show()
end

-- The character picker: only when there is more than one character to pick
-- from. Rebuilt when the set of characters or what they say changes -- the
-- dropdown takes its items at build -- and never otherwise.
local function UpdatePicker(frame)
  local chars = MM.Characters()
  local items, labels, sig = {}, {}, {}
  for i = 1, #chars do
    local st = chars[i]
    local id = st.realm .. "\001" .. st.name
    local tail
    if st.text then
      tail = ns.Theme.Colorize("warning", st.text)
    elseif st.seenAt then
      tail = ns.Theme.Colorize("textSecondary", ns.Plural("COUNT_MAILS", st.waiting))
    end
    items[i] = { id = id, name = tail and (st.label .. "   " .. tail) or st.label }
    labels[id] = st.label
    sig[i] = items[i].name
  end
  frame._pickLabels = labels

  local want = #chars > 1
  local signature = table.concat(sig, "\002")
  if want and frame._pickSig ~= signature then
    if frame.Picker then frame.Picker:Hide() end
    local widest = 0
    local probe = frame._probe or frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    frame._probe = probe
    probe:Hide()
    for i = 1, #chars do
      probe:SetText(chars[i].label)
      widest = math.max(widest, probe:GetStringWidth() or 0)
    end
    local picker = ns.Core.UI.Dropdown.Create(frame, {
      items = items,
      toggleWidth = math.min(math.max(math.ceil(widest) + 34, 90), 170),
      toggleHeight = 20,
      height = 20,
      listWidth = 300,
      listLeft = true,
    })
    picker:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD - 2, -30)
    picker:SetWidth(math.min(math.max(math.ceil(widest) + 34, 90), 170))
    picker:SetChangeCallback(function(id)
      local realm, name = id:match("^(.-)\001(.*)$")
      local myRealm, myName = Me()
      if realm == myRealm and name == myName then
        frame.viewing = nil
      else
        frame.viewing = { realm = realm, name = name }
      end
      Refresh(frame)
    end)
    if ns.Skin and ns.Skin.Refresh then pcall(ns.Skin.Refresh, picker) end
    frame.Picker = picker
    frame._pickSig = signature
  end

  if frame.Picker then
    frame.Picker:SetShown(want)
    if want then
      local v = frame.viewing
      local myRealm, myName = Me()
      local id = v and (v.realm .. "\001" .. v.name) or (myRealm .. "\001" .. myName)
      frame.Picker._selectedId = id
      frame.Picker:SetText(labels[id] or myName)
    end
  end
  frame.Header:ClearAllPoints()
  if want and frame.Picker then
    frame.Header:SetPoint("LEFT", frame.Picker, "RIGHT", 8, 0)
  else
    frame.Header:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -34)
  end
  frame.Header:SetPoint("RIGHT", frame.NewSinceHit, "LEFT", -8, 0)
end

function Refresh(frame)
  UpdatePicker(frame)
  -- Another character's box is read-only history: no live look, no heal, no
  -- arrival badge -- those all describe the character being played.
  local viewing = frame.viewing
  -- Self-heal for a missed close signal. If `live` still exists while no
  -- mailbox is open, the visit ended without either close event reaching us
  -- -- and every arrival mark since then went to the STORED record while
  -- this window kept reading `live`: content right, badge structurally
  -- impossible. Settle the visit now exactly as the close handler would,
  -- carrying marks made against the prior record across the late persist.
  local state = MailboxState()
  if not viewing and live and not (state and state.mailboxOpen) then
    local prior = StoredSnapshot()
    local priorMark = prior and prior.newSince and prior.newFrom or nil
    local priorMarked = prior and prior.newSince == true
    if closedAt == 0 then closedAt = time() end
    PersistOnClose()
    local healed = StoredSnapshot()
    if healed and priorMarked then
      healed.newSince = true
      healed.newFrom = priorMark
    end
  end

  local snapshot
  if viewing then
    snapshot = SnapshotFor(viewing.realm, viewing.name)
  else
    snapshot = live or StoredSnapshot()
  end
  local now = time()

  local mails = snapshot and snapshot.mails or nil
  local count = mails and #mails or 0

  if not snapshot then
    frame.Header:SetText(L["MEMORY_EMPTY"])
  elseif count == 0 then
    frame.Header:SetText(string.format(L["MEMORY_ASOF_EMPTY"], AgeText(snapshot.seenAt)))
  else
    frame.Header:SetText(string.format(L["MEMORY_ASOF"],
      AgeText(snapshot.seenAt), ns.Plural("COUNT_MAILS", count)))
  end

  -- The badge means one exact thing: mail arrived after this snapshot.
  -- Three independent detectors, ANY suffices, each sound on its own:
  --
  --   1. The arrival watch's stored mark (the pending-mail event, guarded).
  --   2. The flag FLIP: HasNewMail() is "unread mail exists", so its value
  --      proves nothing (1.24.1 read it as state and lit the badge for
  --      every uncollected auction mail) -- but false at close and true now
  --      can only mean an arrival in between.
  --   3. The sender-triple CHANGE: the latest-unread-senders line the
  --      client keeps reshuffles whenever mail lands, including while
  --      logged out; the snapshot remembers what it said at close.
  --
  -- A mailbox visit replaces the record and re-baselines all three. Blind
  -- spot, stated rather than papered over: >3 unread mails from one sender
  -- where another lands from the same sender leaves the triple unchanged --
  -- then only detectors 1 and 2 can see it.
  local arrived = false
  local from = nil
  if snapshot and not viewing then
    EnsureBaseline(snapshot)
    local state = MailboxState()
    local away = not (state and state.mailboxOpen)
    local flagNow = away and type(HasNewMail) == "function" and HasNewMail() and true or false
    local tripleNow = away and SenderTriple() or nil
    arrived = snapshot.newSince == true
      or (flagNow and snapshot.baseNew == false)
      or (tripleNow ~= nil and snapshot.baseFrom ~= nil and tripleNow ~= snapshot.baseFrom)
    from = snapshot.newFrom
    if arrived and not from and type(GetLatestThreeSenders) == "function" then
      local a, b, c = GetLatestThreeSenders()
      from = {}
      if a then from[#from + 1] = tostring(a) end
      if b then from[#from + 1] = tostring(b) end
      if c then from[#from + 1] = tostring(c) end
      if #from == 0 then from = nil end
    end
  end
  frame.NewSinceHit:SetShown(arrived)
  frame.newFrom = arrived and from or nil

  local hidden = snapshot and math.max(0, (tonumber(snapshot.total) or count) - count) or 0
  if hidden > 0 then
    frame.More:SetText(string.format(L["MEMORY_MORE"], hidden))
    frame.More:Show()
  else
    frame.More:Hide()
  end

  frame.Card:SetShown(count > 0)
  for i = 1, count do
    if not frame.Rows[i] then frame.Rows[i] = BuildRow(frame.ListChild, i) end
  end
  local cols = (count > 0) and MeasureColumns(frame, mails, now, frame.Rows[1]) or nil
  for i = 1, count do
    FillRow(frame.Rows[i], mails[i], now, cols)
  end
  for i = count + 1, #frame.Rows do frame.Rows[i]:Hide() end
  frame.ListChild:SetHeight(math.max(1, count * ROW_HEIGHT))

  -- Height: eight rows by default, the user's own height once they have
  -- dragged the grip, and never taller than the content or shorter than
  -- four rows. Width is pinned by the bounds -- this window grows down,
  -- not sideways.
  local contentRows = math.max(count, 1)
  local minH = RowsHeight(math.min(MIN_ROWS, contentRows))
  local maxH = RowsHeight(contentRows)
  frame:SetResizeBounds(WINDOW_WIDTH, minH, WINDOW_WIDTH, maxH)

  local wanted = frame.userHeight or RowsHeight(math.min(DEFAULT_ROWS, contentRows))
  if wanted < minH then wanted = minH end
  if wanted > maxH then wanted = maxH end
  frame:SetSize(WINDOW_WIDTH, wanted)
end

local function Build()
  if MM._frame then return MM._frame end

  local frame = CreateFrame("Frame", "PostboxMailMemoryFrame", UIParent,
                            "BasicFrameTemplateWithInset")
  frame:SetSize(WINDOW_WIDTH, RowsHeight(DEFAULT_ROWS))
  frame:SetFrameStrata("DIALOG")
  frame:SetToplevel(true)
  frame:SetClampedToScreen(true)
  frame:SetResizable(true)
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

  -- The badge is a real (small) frame so it can carry a tooltip naming who
  -- the new mail is from -- a bare font string cannot take the mouse.
  frame.NewSinceHit = CreateFrame("Frame", nil, frame)
  frame.NewSinceHit:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -32)
  frame.NewSinceHit:SetHeight(16)
  HoverOnly(frame.NewSinceHit)

  -- GREEN, not the accent. New mail is good news, and the accent is the
  -- colour this addon uses for "selected" and "attention" -- an orange-gold
  -- pill reads as a warning toast, which is the opposite of what arriving
  -- mail means. Green says it plainly and cannot be confused with the
  -- orange a stuck mail wears three rows below.
  local pos = ns.Theme.Colors.positive
  local r, g, b = pos[1], pos[2], pos[3]

  -- A pill, not a line of coloured text: this badge has to be read while
  -- the eye is on a list of mails, where one more coloured caption reads as
  -- a column heading. Wash plus dot plus word is unmistakably a marker.
  local pill = frame.NewSinceHit:CreateTexture(nil, "BACKGROUND")
  pill:SetAllPoints()
  pill:SetColorTexture(r, g, b, 0.13)

  frame.NewSince = ns.Theme.CreateText(frame.NewSinceHit, "small")
  frame.NewSince:SetPoint("RIGHT", frame.NewSinceHit, "RIGHT", -6, 0)
  frame.NewSince:SetText(L["MEMORY_NEW_SINCE"])
  frame.NewSince:SetTextColor(r, g, b)

  local dot = frame.NewSinceHit:CreateTexture(nil, "OVERLAY")
  dot:SetSize(5, 5)
  dot:SetPoint("RIGHT", frame.NewSince, "LEFT", -5, 0)
  dot:SetColorTexture(r, g, b, 1)

  frame.NewSinceHit:SetWidth(frame.NewSince:GetStringWidth() + 22)
  -- Two facts, in the order they matter: what has landed since (which the
  -- list below cannot show), then what was already waiting, grouped by
  -- sender so "Auction House  x10" reads at a glance instead of ten rows.
  local SUMMARY_LINES = 5
  frame.NewSinceHit:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["MEMORY_ARRIVED_TIP"])
    local from = frame.newFrom
    if type(from) == "table" and #from > 0 then
      for i = 1, #from do
        GameTooltip:AddLine(from[i], 1, 1, 1)
      end
    else
      GameTooltip:AddLine(L["MEMORY_ARRIVED_ANON"], 1, 1, 1, true)
    end

    -- Same two-section breakdown as the minimap tooltip, from the same
    -- summary, so the two never describe one mailbox differently. The
    -- headings carry a count, which is why they are FORMATTED here -- this
    -- one printed a literal "%d" for a release.
    local state = MM.MailboxSummary()
    local function Breakdown(groups, heading, count, hr, hg, hb)
      if not groups then return end
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(string.format(heading, count), hr, hg, hb)
      local shown = math.min(#groups, SUMMARY_LINES)
      for i = 1, shown do
        GameTooltip:AddDoubleLine(groups[i].name, "x" .. groups[i].count,
          1, 1, 1, 0.75, 0.75, 0.78)
      end
      if #groups > shown then
        GameTooltip:AddLine(string.format(L["MEMORY_WAITING_MORE"], #groups - shown),
          0.6, 0.6, 0.63)
      end
    end
    if state then
      Breakdown(state.groups, L["MEMORY_WAITING_HEAD"], state.waiting,
        0.75, 0.75, 0.78)
      local warn = ns.Theme.Colors.warning
      Breakdown(state.stuckGroups, L["MEMORY_STUCK_HEAD"], state.stuck,
        warn[1], warn[2], warn[3])
    end
    GameTooltip:Show()
  end)
  frame.NewSinceHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
  frame.NewSinceHit:Hide()

  frame.Header = ns.Theme.CreateText(frame, "label")
  frame.Header:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -34)
  frame.Header:SetPoint("RIGHT", frame.NewSinceHit, "LEFT", -8, 0)
  frame.Header:SetJustifyH("LEFT")
  frame.Header:SetWordWrap(false)

  frame.More = ns.Theme.CreateText(frame, "tiny")
  frame.More:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, 8)
  frame.More:SetAlpha(0.7)
  frame.More:Hide()

  local card = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  card:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -CHROME_TOP)
  card:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, CHROME_BOTTOM)
  ns.Theme.ApplyList(card)
  frame.Card = card

  frame.Scroll = CreateFrame("ScrollFrame", nil, card, "UIPanelScrollFrameTemplate")
  frame.Scroll:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -1)
  frame.Scroll:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -(ns.Theme.Metrics.scrollGutter), 1)
  frame.Scroll.scrollBarHideable = 1
  ns.Theme.SlimScrollBar(frame.Scroll, card, 1)

  frame.ListChild = CreateFrame("Frame", nil, frame.Scroll)
  frame.ListChild:SetWidth(WINDOW_WIDTH - 44)
  frame.Scroll:SetScrollChild(frame.ListChild)

  frame.Rows = {}

  -- The grip only ever changes height (the bounds pin the width). Once the
  -- user has chosen a height it is theirs for the session; Refresh keeps
  -- honouring it within the new content's bounds.
  ns.Core.UI.Helpers.CreateResizeButton(frame, function(self)
    self.userHeight = self:GetHeight()
  end)

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
-- contract: the real window is on screen and it is the truth. Opens beside
-- the minimap rather than under the cursor -- the icon is small and an
-- anchored window would cover the map.
-- The options panel's row switches: repaint the window if it is showing. A
-- hidden window is filled fresh on its next open anyway.
function MM.Refresh()
  local frame = MM._frame
  if frame and frame:IsShown() then Refresh(frame) end
end

function MM.Toggle()
  if not MemoryEnabled() then return end
  local state = MailboxState()
  if state and state.mailboxOpen then
    -- The real mailbox is on screen; a memory of it would be a second,
    -- staler copy. Say why the click did nothing rather than being a dead
    -- button.
    ns.Print(L["MEMORY_MAILBOX_OPEN"])
    return
  end

  local frame = Build()
  if frame:IsShown() then
    frame:Hide()
    return
  end

  -- Every open starts on the character being played.
  frame.viewing = nil
  Refresh(frame)
  frame:ClearAllPoints()
  local minimap = _G.Minimap
  if minimap then
    frame:SetPoint("TOPRIGHT", minimap, "TOPLEFT", -10, 0)
  else
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
  end
  frame:Show()
  frame:Raise()
  if ns.Skin and ns.Skin.Refresh then pcall(ns.Skin.Refresh, frame) end
end

-- Unread mail grouped by sender, for the minimap tooltip: a list of
-- { name = ..., count = ... }, biggest first, or nil when the snapshot has
-- nothing unread to describe. Same grouping the memory window's badge
-- tooltip uses, so the two can never disagree.
function MM.UnreadSummary()
  local state = MM.MailboxSummary()
  return state and state.groups or nil
end

-- Everything the minimap tooltip needs to describe the mailbox in one read,
-- or nil when there is nothing recorded to describe. Assembled here rather
-- than in the icon so the tooltip and the memory window can never tell
-- different stories about the same snapshot.
function MM.MailboxSummary()
  if not MemoryEnabled() then return nil end
  local snap = live or StoredSnapshot()
  if not snap then return nil end

  -- Two lists, not one with a footnote: a refused mail is still holding
  -- your item, but "waiting to collect" and "the server would not give me
  -- this" are different problems with different answers, and reading a
  -- sender under the first heading and then a count under a separate
  -- refusal line made one mail look like two.
  local waiting, stuck = 0, 0
  local mails = snap.mails or {}
  for i = 1, #mails do
    local mail = mails[i]
    -- The Collect tab's rule, so the two counts agree: a mail waits while it
    -- holds anything, or has not been read.
    if (mail.items or 0) > 0 or (mail.money or 0) > 0 or (mail.cod or 0) > 0 or not mail.read then
      if mail.stuck then stuck = stuck + 1 else waiting = waiting + 1 end
    end
  end

  local function GroupsFor(wantStuck)
    local order, counts = WaitingBySender(snap, wantStuck)
    if #order == 0 then return nil end
    local out = {}
    for i = 1, #order do
      out[i] = { name = order[i], count = counts[order[i]] }
    end
    return out
  end

  return {
    groups      = GroupsFor(false),
    stuckGroups = GroupsFor(true),
    waiting     = waiting,
    stuck       = stuck,
    total       = #mails,
    seenAt      = snap.seenAt,
    arrived     = snap.newSince and true or false,
    newFrom     = snap.newSince and snap.newFrom or nil,
  }
end

-- The minimap tooltip's memory line: the same sentence the window leads
-- with -- one truth, one phrasing -- or nil when there is nothing to say.
-- Just the age. The mail count moved up into the breakdown headings, where
-- the numbers describe the lists they sit above instead of repeating a
-- total the reader has to reconcile with them.
function MM.SummaryText()
  if not MemoryEnabled() then return nil end
  local snap = live or StoredSnapshot()
  if not snap then return nil end
  return string.format(L["MEMORY_LASTSEEN"], AgeText(snap.seenAt))
end

-- One line for /postbox debug: everything needed to see why a badge did or
-- did not show, without asking for a reproduction.
function MM.Diagnose()
  local snap = live or StoredSnapshot()
  local parts = {}
  parts[#parts + 1] = MemoryEnabled() and "on" or "OFF"
  if snap then
    parts[#parts + 1] = string.format("%d mails, seen %ds ago",
      #(snap.mails or {}), math.max(0, time() - (tonumber(snap.seenAt) or 0)))
    parts[#parts + 1] = "newSince " .. tostring(snap.newSince == true)
    local triple = SenderTriple()
    parts[#parts + 1] = string.format("baseNew %s | tripleChanged %s",
      tostring(snap.baseNew),
      tostring(snap.baseFrom ~= nil and triple ~= nil and triple ~= snap.baseFrom))
  else
    parts[#parts + 1] = "no snapshot"
  end
  parts[#parts + 1] = "pending evt " ..
    (lastPendingAt and string.format("%ds ago (%s)", time() - lastPendingAt, lastPendingVerdict)
     or lastPendingVerdict)
  -- The two structural tells: a stranded live capture means a close signal
  -- was missed; a false registration means this client refused an event
  -- name outright.
  parts[#parts + 1] = "liveHeld " .. tostring(live ~= nil)
  local failed = {}
  for name, ok in pairs(registered) do
    if not ok then failed[#failed + 1] = name end
  end
  parts[#parts + 1] = (#failed == 0) and "events ok"
    or ("events FAILED: " .. table.concat(failed, ","))
  parts[#parts + 1] = "HasNewMail " ..
    tostring(type(HasNewMail) == "function" and HasNewMail() and true or false)
  parts[#parts + 1] = string.format("login %s | closed %ds ago",
    loginAt and string.format("%ds ago", time() - loginAt) or "unseen",
    math.max(0, time() - closedAt))
  local a, b, c
  if type(GetLatestThreeSenders) == "function" then a, b, c = GetLatestThreeSenders() end
  parts[#parts + 1] = "senders " .. table.concat({ tostring(a), tostring(b), tostring(c) }, "/")
  return table.concat(parts, " | ")
end

-------------------------------------------------------------
-- 5. Event wiring
--
-- Registered once at load; every handler stands down in one comparison
-- while no mailbox session is open, which is this module's idle state.
-------------------------------------------------------------

-- The arrival watch. UPDATE_PENDING_MAIL fires when the client's pending
-- set CHANGES -- the only arrival signal the API offers once unread mail
-- already sits in the box (HasNewMail stays true throughout, so its VALUE
-- proves nothing; only the event does). Two time guards keep the event
-- honest: the client fires one at login to establish state (not an
-- arrival), and closing the mailbox churns the pending set (also not an
-- arrival). Marking the SAVED record costs one field write per real event,
-- of which the client sends a handful an hour at most.
local LOGIN_SETTLE = 10
local CLOSE_SETTLE = 5

local function OnPendingMail()
  lastPendingAt = time()
  lastPendingVerdict = "disabled"
  if not MemoryEnabled() then return end
  lastPendingVerdict = "at mailbox"
  local state = MailboxState()
  if state and state.mailboxOpen then return end
  lastPendingVerdict = "login settle"
  if not loginAt or (time() - loginAt) < LOGIN_SETTLE then return end
  lastPendingVerdict = "close settle"
  if (time() - closedAt) < CLOSE_SETTLE then return end
  lastPendingVerdict = "flag false"
  if not (type(HasNewMail) == "function" and HasNewMail()) then return end

  -- Arrived, whatever else is known: the watch needs no snapshot.
  NoteArrival(Me())

  lastPendingVerdict = "no snapshot"
  local snap = StoredSnapshot()
  if not snap then return end
  lastPendingVerdict = "marked"
  snap.newSince = true
  if type(GetLatestThreeSenders) == "function" then
    local a, b, c = GetLatestThreeSenders()
    local from = {}
    if a then from[#from + 1] = tostring(a) end
    if b then from[#from + 1] = tostring(b) end
    if c then from[#from + 1] = tostring(c) end
    if #from > 0 then snap.newFrom = from end
  end

  -- Mail can land while the window is on screen -- the exact moment the
  -- badge is worth something. One row-refill against the ≤50 cached mails,
  -- only when visible.
  local frame = MM._frame
  if frame and frame:IsShown() then Refresh(frame) end

  -- One witness, two consumers: the badge above and the minimap icon's
  -- optional sound/flash. Both answer to the same arrival.
  local Icon = ns.MinimapButton
  if Icon and type(Icon.NotifyArrival) == "function" then Icon.NotifyArrival() end
end

-- The fourth detector watches the CAUSE instead of the effect. The server
-- sends no new-mail push while the mail flag is already up, so an auction
-- purchase on top of existing unread mail -- the single most common arrival
-- -- can be completely silent on the mail side. But the purchase itself is
-- loudly announced to the buyer, and a completed purchase IS mail in
-- transit. Witnessed cause, honest badge.
local function OnPurchaseCompleted()
  if not MemoryEnabled() then return end
  NoteArrival(Me())
  local snap = StoredSnapshot()
  if not snap then return end
  snap.newSince = true
  local label = L["MEMORY_FROM_AH"]
  local from = snap.newFrom or {}
  local listed = false
  for i = 1, #from do
    if from[i] == label then
      listed = true
      break
    end
  end
  if not listed then from[#from + 1] = label end
  snap.newFrom = from

  local frame = MM._frame
  if frame and frame:IsShown() then Refresh(frame) end

  local Icon = ns.MinimapButton
  if Icon and type(Icon.NotifyArrival) == "function" then Icon.NotifyArrival() end
end

-- Same dual close coverage as Core/MailboxUI.lua, for the same reason: the
-- two close signals do not both arrive on every close path, and a session
-- whose end this module misses strands `live` (see the heal in Refresh).
local MAIL_INTERACTION = 17
local function IsMailInteraction(kind)
  if kind == MAIL_INTERACTION then return true end
  local enum = type(Enum) == "table" and Enum.PlayerInteractionType or nil
  return enum ~= nil and kind == enum.MailInfo
end

local function OnMailboxClosed()
  closedAt = time()
  PersistOnClose()
end

-- The real mailbox supersedes its memory: the moment a mail session opens,
-- the memory window closes itself rather than sitting beside the truth
-- going stale.
local function OnMailboxOpened()
  local frame = MM._frame
  if frame and frame:IsShown() then frame:Hide() end
end

-- Registration results surface in Diagnose (`registered`, declared in
-- section 1): a name this client does not know is refused by the bus, and
-- an invisible refusal cost three blind releases of detector archaeology.
local bus = ns.Events
if bus then
  registered.inbox = bus.Register("MAIL_INBOX_UPDATE", QueueCapture)
  registered.closed = bus.Register("MAIL_CLOSED", OnMailboxClosed)
  registered.interaction = bus.Register("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(_, kind)
    if IsMailInteraction(kind) then OnMailboxClosed() end
  end)
  registered.show = bus.Register("MAIL_SHOW", OnMailboxOpened)
  registered.showInteraction = bus.Register("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(_, kind)
    if IsMailInteraction(kind) then OnMailboxOpened() end
  end)
  registered.pending = bus.Register("UPDATE_PENDING_MAIL", OnPendingMail)
  -- Item purchases and commodity purchases announce themselves on different
  -- events; both end as mail.
  registered.purchase = bus.Register("AUCTION_HOUSE_PURCHASE_COMPLETED", OnPurchaseCompleted)
  registered.commodity = bus.Register("COMMODITY_PURCHASE_SUCCEEDED", OnPurchaseCompleted)
  -- Posting an auction starts mail on its way: the gold when it sells, the
  -- item when it does not. An expiry while online is that mail arriving.
  registered.auctionPosted = bus.Register("AUCTION_HOUSE_AUCTION_CREATED", function()
    if not MemoryEnabled() then return end
    local watch = WatchFor(GetRealmName(), UnitName("player"), true)
    if not watch then return end
    local now = time()
    watch.auctionAt = watch.auctionAt or now
    watch.auctionsUntil = math.max(watch.auctionsUntil or 0, now + AUCTION_LONGEST)
  end)
  registered.auctionExpired = bus.Register("AUCTION_HOUSE_AUCTIONS_EXPIRED", function()
    NoteArrival(Me())
  end)
  registered.login = bus.Register("PLAYER_ENTERING_WORLD", function(_, isInitialLogin)
    loginAt = time()
    if MemoryEnabled() then EnsureBaseline(StoredSnapshot()) end
    if not isInitialLogin then return end
    -- Once the client has settled its mail state: mail that arrived while
    -- logged out raised the unread flag that was down at the last close.
    -- Then, once per login, the one line about the other characters.
    C_Timer.After(LOGIN_SETTLE + 5, function()
      if not MemoryEnabled() then return end
      local snap = StoredSnapshot()
      local flag = type(HasNewMail) == "function" and HasNewMail() and true or false
      if flag and (not snap or snap.baseNew == false) then NoteArrival(Me()) end

      local UI = ns.MailboxUI
      if UI and type(UI.GetOption) == "function" and not UI.GetOption("mailWarnings") then return end
      local others = MM.OtherWarnings()
      if #others == 0 then return end
      local parts = {}
      for i = 1, #others do
        parts[#parts + 1] = others[i].label .. " (" .. others[i].text .. ")"
      end
      ns.Print(L("OVERVIEW_LOGIN", table.concat(parts, ", ")))
    end)
  end)
end
