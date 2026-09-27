local _, ns = ...

-- =====================================================================
-- Postbox :: Mail Memory
-- ---------------------------------------------------------------------
-- "What was in my mailbox?", answered away from any mailbox: a snapshot
-- of the inbox as it looked the last time each character had it open.
-- Shown in a small read-only window (the minimap icon, the addon
-- compartment, /postbox mail) and, for the other characters, in the Postbox
-- window's own Mail tab while a mailbox is open.
--
-- The snapshot is HISTORY and the window never pretends otherwise: it
-- leads with how long ago it was taken, flags new arrivals since, and
-- greys mails whose expiry has passed in the meantime.
--
-- Cost discipline (the reason this file is small): the capture rides the
-- MAIL_INBOX_UPDATE walks the mailbox session performs anyway, coalesced
-- to one pass per frame; the record keeps at most MAX_MAILS however many
-- hundreds a hoarder character holds, so a pass is bounded; the snapshot
-- is written once per visit, at close (History and the arrival notices add
-- a small write per event); and the window does not exist until the first
-- time it is asked for. Away from a mailbox this module is idle, and the
-- "Mail Memory" option (on by default) turns even that idle wiring into
-- one-comparison no-ops.
-- =====================================================================

ns.MailMemory = ns.MailMemory or {}
local MM = ns.MailMemory

local L = ns.L

-- Our own bound on the saved record. It was 50 -- the page the client used
-- to show -- and the client now shows more, so a full box was cut off at 50
-- while the Collect tab counted 56. The client's inbox holds at most 100.
local MAX_MAILS = 100

-- The Mail tab's compact row height, so a row reads the same in both windows.
local ROW_HEIGHT = 26
-- Narrowest and widest: the grip stretches it between the two.
local WINDOW_WIDTH = 400
local WINDOW_MAX_WIDTH = 640
local PAD = 12

-- The window's fixed chrome: title bar plus the top row (whose box, the
-- picker, the search) above the card, and the strip below it that holds the
-- seen-when line and the resize grip. The card fills whatever is between
-- the two, which is what makes the resize grip work with no per-drag layout
-- code at all.
local CHROME_TOP = 56
local CHROME_BOTTOM = 26

-- Six rows: the default AND the floor -- enough to be useful, small enough
-- to stay a note rather than a second mail window; the grip only ever
-- grows it toward the content.
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
-- `live` is this visit's latest look, refilled in place on every coalesced
-- capture and persisted (then dropped) when the session closes. MAIL_CLOSED
-- and the interaction manager's hide event both fire for one close; dropping
-- `live` on the first persist is what makes the second arrival a no-op, and
-- what keeps a later capture from ever writing into the saved record.
-------------------------------------------------------------

local live = nil
local captureQueued = false

-- The search's folded text, kept per mail table (Matches, section 3d). Weak
-- keys, so a snapshot dropped takes its entries with it -- and never a field
-- on the mail itself, which is saved variables. Here because a capture that
-- puts another mail into one of this visit's tables drops that table's text.
local searchText = setmetatable({}, { __mode = "k" })

-- MM.Characters is memoised (section 2b); this generation says its list is
-- stale. Everything in this file that writes what the list reads -- a
-- snapshot saved, an arrival or auction noted, a watch settled, a character
-- hidden or shown -- calls CharactersChanged. Nothing outside the file
-- writes mailMemory, mailWatch or hiddenChars.
local charactersGen = 0
local function CharactersChanged() charactersGen = charactersGen + 1 end

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

  -- Timed while an open is being measured (Postbox.lua, 5b); nil otherwise.
  local perf = ns.Perf
  local perfAt = perf and perf.Begin()

  local numItems, totalItems = GetInboxNumItems()
  numItems = tonumber(numItems) or 0
  totalItems = tonumber(totalItems) or numItems

  local now = time()
  -- This visit's tables, filled again: a burst of inbox updates reuses one
  -- set of mails rather than building a fresh set on every frame. Nothing
  -- outside this file ever holds them (RowsFor hands out copies).
  local prev = live
  local mails = prev and prev.mails or {}
  local count = 0
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

      sender, subject = tostring(sender or ""), tostring(subject or "")
      count = count + 1
      local mail = mails[count]
      if not mail then
        -- Sized for all its fields at once; each is set just below.
        mail = { stuck = false, icon = false, sender = "", subject = "", money = 0, cod = 0, items = 0,
          read = false, link = false, kind = false, paid = false, expires = 0 }
        mails[count] = mail
      elseif mail.sender ~= sender or mail.subject ~= subject or mail.kind ~= kind then
        -- Another mail in this slot now: the text a search folded is not its.
        searchText[mail] = nil
      end
      mail.stuck   = stuck
      mail.icon    = packageIcon or stationeryIcon
      mail.sender  = sender
      mail.subject = subject
      mail.money   = tonumber(money) or 0
      mail.cod     = tonumber(cod) or 0
      mail.items   = tonumber(itemCount) or 0
      mail.read    = wasRead and true or false
      mail.link    = link
      mail.kind    = kind
      mail.paid    = paid
      -- Absolute, so "has this expired since I saw it" is answerable in a
      -- later session without trusting a stale daysLeft.
      mail.expires = now + math.floor((tonumber(daysLeft) or 0) * 86400)
      if count >= MAX_MAILS then break end
    end
  end

  -- A box that shrank keeps nothing past its new end.
  for i = #mails, count + 1, -1 do mails[i] = nil end
  if prev then
    prev.seenAt, prev.total = now, totalItems
  else
    live = { seenAt = now, total = totalItems, mails = mails }
  end
  if perfAt then perf.End("capture", perfAt) end
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
  CharactersChanged()
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
-- flip/triple detectors. Heal it at the first away-from-box look: the sender
-- line's baseline becomes NOW, so arrivals from this moment on are detectable
-- without demanding a fresh mailbox visit first. Run at login too, so an
-- arrival between login and the first window-open is not folded into the
-- healed baseline.
--
-- The unread flag's baseline is read from the snapshot itself rather than
-- from the flag now: any unread mail in it held the flag up at close, and
-- none means it was down. The flag NOW would fold mail that arrived while
-- the character was logged out into the baseline, and the flip detector
-- could then never see it. A snapshot cut short by the record's cap may
-- have had unread mail past the cut, so it counts as up.
local function EnsureBaseline(snap)
  if not snap or snap.baseFrom ~= nil then return end
  local state = MailboxState()
  if state and state.mailboxOpen then return end
  snap.baseFrom = SenderTriple()
  local mails = snap.mails or {}
  local unread = (tonumber(snap.total) or #mails) > #mails
  for i = 1, #mails do
    if not mails[i].read then
      unread = true
      break
    end
  end
  snap.baseNew = unread
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
  local now = time()
  for i = 1, #mails do
    local mail = mails[i]
    local expires = tonumber(mail.expires)
    local holds = (mail.items or 0) > 0 or (mail.money or 0) > 0 or (mail.cod or 0) > 0
      or not mail.read
    -- Past its date it is gone, whatever it held.
    if expires and expires > 0 and expires <= now then holds = false end
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
-- Past this the mail the watch guarded has been returned or deleted: a
-- warning then could only nag, about a character that may no longer exist.
local MAIL_LIFE = 30 * DAY
local UNSEEN_STOP = MAIL_LIFE + AUCTION_LONGEST

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
    -- A character the list may not have had.
    CharactersChanged()
  end
  return watch
end

local function SnapshotFor(realm, name)
  local root = ns.Store and ns.Store.Get and ns.Store.Get("mailMemory")
  local byRealm = type(root) == "table" and root[realm] or nil
  return type(byRealm) == "table" and byRealm[name] or nil
end

-- Mail is known to have arrived for this character -- at `at` at the latest
-- (default now; the earliest it could have landed is the safer guess when
-- all that is known is "since the last visit").
local function NoteArrival(realm, name, at)
  if not MemoryEnabled() then return end
  local watch = WatchFor(realm, name, true)
  if watch and not watch.newAt then
    watch.newAt = tonumber(at) or time()
    CharactersChanged()
  end
end

-- The notifications' rows still describing mail that exists: an auction's
-- mail lands within the hour and lives thirty days.
local function LivePending(watch, now)
  local out = {}
  local pending = watch and type(watch.pending) == "table" and watch.pending or {}
  local cutoff = (now or time()) - MAIL_LIFE
  for i = 1, #pending do
    if (tonumber(pending[i].t) or 0) > cutoff then out[#out + 1] = pending[i] end
  end
  return out
end

-- How many LivePending would list, by its rule, without the list: the
-- character list counts every character's.
local function LivePendingCount(watch, now)
  local pending = watch and type(watch.pending) == "table" and watch.pending or nil
  if not pending then return 0 end
  local cutoff = now - MAIL_LIFE
  local count = 0
  for i = 1, #pending do
    if (tonumber(pending[i].t) or 0) > cutoff then count = count + 1 end
  end
  return count
end

-- This character's box was opened and recorded: what the watch guarded is in
-- the snapshot now. An auction still running can send mail after the visit,
-- so it stays watched -- from now.
function MM._SettleWatch(realm, name, now)
  local watch = WatchFor(realm, name, false)
  if not watch then return end
  watch.newAt = nil
  -- What the notifications said had arrived is in the snapshot now.
  watch.pending = nil
  if watch.auctionsUntil and watch.auctionsUntil > now then
    watch.auctionAt = now
  else
    watch.auctionAt, watch.auctionsUntil = nil, nil
  end
  CharactersChanged()
end

-- A mail waits while it holds anything, or is unread: the Collect tab's rule
-- -- and only until its date. Past it the server has returned or deleted it,
-- and a character idle for months must not keep counting mail that is gone.
local function Holds(mail, now)
  local expires = tonumber(mail.expires)
  if expires and expires > 0 and expires <= (now or time()) then return false end
  return (mail.items or 0) > 0 or (mail.money or 0) > 0 or (mail.cod or 0) > 0 or not mail.read
end

-- realm, name, now -> what there is to say about that character's mail.
--   waiting    mails in its snapshot still waiting
--   soon       how many of them expire within three days, and `soonest`
--   unseenDays set when mail known to be on the way has gone unopened
--              long enough to be a week from its earliest loss
local function Status(realm, name, now)
  local snap = SnapshotFor(realm, name)
  -- Every field it will carry, here and in MM.Characters, named at once so
  -- the table is sized once rather than grown twice; the ones left nil are
  -- set below, or there, when they apply.
  local st = { realm = realm, name = name, waiting = 0, seenAt = snap and snap.seenAt or nil,
    soon = nil, soonest = nil, pending = 0, unseenDays = nil, warn = false,
    me = nil, hidden = nil, label = nil, text = nil }
  local mails = snap and snap.mails or {}
  for i = 1, #mails do
    local mail = mails[i]
    if Holds(mail, now) then
      st.waiting = st.waiting + 1
      local left = (tonumber(mail.expires) or 0) - now
      if left > 0 and left < SOON then
        st.soon = (st.soon or 0) + 1
        if not st.soonest or mail.expires < st.soonest then st.soonest = mail.expires end
      end
    end
  end
  local watch = WatchFor(realm, name, false)
  st.pending = LivePendingCount(watch, now)
  if watch then
    local since = watch.newAt
    if watch.auctionAt and (not since or watch.auctionAt < since) then since = watch.auctionAt end
    if since and now - since >= UNSEEN_WARN and now - since < UNSEEN_STOP then
      st.unseenDays = math.floor((now - (st.seenAt or since)) / DAY)
    end
  end
  st.warn = (st.soon ~= nil) or (st.unseenDays ~= nil)
  return st
end

-- The status as a phrase, in the warning tone; nil when there is none.
-- At most two phrases, joined as they come: no list per character.
local function WarningText(st, now)
  local text
  if st.soon then
    text = ns.Plural("OVERVIEW_EXPIRE", st.soon, (ExpiryText(st.soonest, now)))
  end
  if st.unseenDays then
    local unseen = ns.Plural("OVERVIEW_UNSEEN", st.unseenDays)
    text = text and (text .. "; " .. unseen) or unseen
  end
  return text
end

-- A character's name as the lists show it: the realm only when it is not
-- `myRealm`, the one being played.
local function CharacterLabel(realm, name, myRealm)
  if realm ~= myRealm then return name .. " - " .. realm end
  return name
end

-- The characters the player has hidden: `hiddenChars`, realm -> name -> true,
-- keyed exactly as mailMemory is, and kept at the saved-variable root because
-- it is something the player made, not a setting. Hidden is about what is
-- OFFERED, never about what is recorded: a hidden character's box is still
-- captured, watched and kept. It is only left out of the lists of other
-- characters -- the character list, the search of every box, the minimap
-- tooltip's warnings and the login line -- so showing it again brings back
-- everything, as if it had never gone. The character being played is never
-- hidden from itself.
local function HiddenSet(create)
  if create then return ns.Store.EnsurePath("hiddenChars") end
  local set = ns.Store and ns.Store.Get and ns.Store.Get("hiddenChars")
  return type(set) == "table" and set or nil
end

local function InHiddenSet(set, realm, name)
  local byRealm = set and set[realm]
  return type(byRealm) == "table" and byRealm[name] and true or false
end

function MM.IsHidden(realm, name)
  return InHiddenSet(HiddenSet(false), realm, name)
end

-- Characters by name, then realm: how the hidden ones are listed.
local function ByName(a, b)
  if a.name ~= b.name then return a.name < b.name end
  return a.realm < b.realm
end

-- The last list MM.Characters built, and what it was built from.
local charactersMemo = {}

-- Every character Postbox knows a mailbox for: this one first, then those
-- with something to say, then by name. Each carries `hidden`, read from the
-- set once here, so every list built from this one filters for nothing.
--
-- One list serves every caller until something it reads is written
-- (charactersGen, section 1), the saved roots themselves are replaced, or
-- the minute turns: its counts and warnings are read against the clock, and
-- a minute is as stale as they get. Callers read it and never change it.
function MM.Characters()
  local now = time()
  local myRealm, myName = Me()
  local get = ns.Store and ns.Store.Get
  local memory = get and get("mailMemory")
  local watches = get and get("mailWatch")
  local hiddenRoot = get and get("hiddenChars")
  local minute = math.floor(now / 60)
  local memo = charactersMemo
  if memo.list and memo.gen == charactersGen and memo.minute == minute and memo.memory == memory
    and memo.watches == watches and memo.hiddenRoot == hiddenRoot
    and memo.realm == myRealm and memo.name == myName then
    return memo.list
  end
  local seen, list = {}, {}
  local function Add(realm, name)
    local key = realm .. "\001" .. name
    if seen[key] then return end
    seen[key] = true
    list[#list + 1] = Status(realm, name, now)
  end
  -- The character being played is always a choice, recorded or not: a
  -- character that has never opened a mailbox is exactly the one that
  -- comes here for its alts', and needs a way back to its own.
  if myRealm and myName then Add(myRealm, myName) end
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
  table.sort(list, function(a, b)
    local aMe = (a.realm == myRealm and a.name == myName)
    local bMe = (b.realm == myRealm and b.name == myName)
    if aMe ~= bMe then return aMe end
    if a.warn ~= b.warn then return a.warn end
    if a.name ~= b.name then return a.name < b.name end
    return a.realm < b.realm
  end)
  local hidden = HiddenSet(false)
  for i = 1, #list do
    local st = list[i]
    st.me = (st.realm == myRealm and st.name == myName)
    st.hidden = (not st.me) and InHiddenSet(hidden, st.realm, st.name)
    st.label = CharacterLabel(st.realm, st.name, myRealm)
    st.text = WarningText(st, now)
  end
  memo.list, memo.gen, memo.minute = list, charactersGen, minute
  memo.memory, memo.watches, memo.hiddenRoot = memory, watches, hiddenRoot
  memo.realm, memo.name = myRealm, myName
  return list
end

-- The other characters with something to say, for the minimap tooltip and
-- the login line. Empty when memory is off. A hidden character says nothing:
-- the player hid it, most often an alt that was deleted or moved, and a
-- warning about it could only nag.
function MM.OtherWarnings()
  local out = {}
  if not MemoryEnabled() then return out end
  local all = MM.Characters()
  for i = 1, #all do
    if all[i].warn and not all[i].me and not all[i].hidden then out[#out + 1] = all[i] end
  end
  return out
end

-- realm, name, hidden -> the character hidden from the lists of other
-- characters, or shown in them again. The caller repaints (MM.HiddenChanged);
-- the character list does that once, when it closes.
function MM.SetHidden(realm, name, hidden)
  if type(realm) ~= "string" or type(name) ~= "string" then return end
  if hidden then
    local set = HiddenSet(true)
    if type(set[realm]) ~= "table" then set[realm] = {} end
    set[realm][name] = true
    CharactersChanged()
    return
  end
  local set = HiddenSet(false)
  local byRealm = set and set[realm]
  if type(byRealm) ~= "table" then return end
  byRealm[name] = nil
  if next(byRealm) == nil then set[realm] = nil end
  CharactersChanged()
end

-- Every hidden character, by name, as { realm, name }: the options panel's
-- list, which is the way back that is always there -- even once nobody is
-- left for the character list to offer.
function MM.HiddenCharacters()
  local out = {}
  local set = HiddenSet(false)
  if not set then return out end
  for realm, byRealm in pairs(set) do
    if type(realm) == "string" and type(byRealm) == "table" then
      for name, on in pairs(byRealm) do
        if on and type(name) == "string" then out[#out + 1] = { realm = realm, name = name } end
      end
    end
  end
  table.sort(out, ByName)
  return out
end

-- Everything that lists other characters, repainted after a hide or a show:
-- the memory window, the Mail tab (its character button, its search of every
-- box) and the options panel's list. The minimap tooltip and the login line
-- read the set whenever they are built.
function MM.HiddenChanged()
  if MM.Refresh then MM.Refresh() end
  local UI = ns.MailboxUI
  if UI and type(UI.RefreshMemoryState) == "function" then UI.RefreshMemoryState() end
  local Panel = ns.OptionsPanel
  if Panel and type(Panel.RefreshControls) == "function" then Panel.RefreshControls() end
end

-- Every hidden character shown again.
function MM.ShowAllHidden()
  local set = HiddenSet(false)
  if set then
    for realm in pairs(set) do set[realm] = nil end
  end
  CharactersChanged()
  MM.HiddenChanged()
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
-- A short record of what Postbox collected on each character: as many days
-- of it as the player chose, at most HISTORY_CAP entries, one entry per mail
-- however many takes that mail needed -- the caller holding one record per
-- mail is what makes it one. Written by Core/MailService.lua as each take is
-- CONFIRMED -- never when the command is sent, since the server may refuse
-- it -- and read by the Mail tab's History view. Pruned on every write, so
-- it never holds more than the days it shows.
-------------------------------------------------------------

-- Kept as long as the player chose (Options, Mail tab: 7 days by default, up
-- to 30), and never more than HISTORY_CAP entries however busy the box: the
-- record is saved per character, and a month of a busy auction goblin's mail
-- must not become megabytes of saved variables.
local HISTORY_CAP = 1000
-- The longest letter text a History entry keeps, in BYTES. The game caps a
-- mail's body at 500 characters, which is up to 1500 bytes of Chinese or
-- 1000 of Cyrillic; this keeps all of any of them.
local HISTORY_BODY_MAX = 1600

-- text, bytes -> the text cut to at most that many bytes, never inside a
-- character: the cut steps back past UTF-8 continuation bytes.
local function CutUtf8(text, bytes)
  if #text <= bytes then return text end
  local cut = bytes
  while cut > 0 do
    local b = text:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end
    cut = cut - 1
  end
  return text:sub(1, cut)
end

local function HistoryKeep()
  local UI = ns.MailboxUI
  local days = UI and type(UI.GetHistoryDays) == "function" and UI.GetHistoryDays() or 7
  return (tonumber(days) or 7) * DAY
end

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
  local cutoff = now - HistoryKeep()
  local drop = 0
  while list[drop + 1] and ((tonumber(list[drop + 1].t) or 0) < cutoff or #list - drop > HISTORY_CAP) do
    drop = drop + 1
  end
  if drop > 0 then
    for i = 1, #list - drop do list[i] = list[i + drop] end
    for i = #list, #list - drop + 1, -1 do list[i] = nil end
  end
end

-- Every character's History, pruned to the days the player chose. A list is
-- otherwise pruned only when its own character reads or writes it, so an alt
-- not played for months kept all it had -- and a lower "Keep History" never
-- reached it. Once per login; each list is in date order, so this touches
-- only what goes. A list left empty is dropped.
local function PruneAllHistory()
  local root = ns.Store and ns.Store.Get and ns.Store.Get("mailHistory")
  if type(root) ~= "table" then return end
  local now = time()
  for realm, byRealm in pairs(root) do
    if type(byRealm) == "table" then
      for name, list in pairs(byRealm) do
        if type(list) == "table" then
          PruneHistory(list, now)
          if #list == 0 then byRealm[name] = nil end
        end
      end
      if next(byRealm) == nil then root[realm] = nil end
    end
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
  -- What the letter said, when Postbox read it: the mail itself may be
  -- deleted (the "delete" read-mail mode), and this is then the only copy.
  if not entry.b and type(ctx.body) == "string" and ctx.body ~= "" then
    entry.b = CutUtf8(ctx.body, HISTORY_BODY_MAX)
  end
  if what == "money" then
    entry.m = (entry.m or 0) + (tonumber(value) or 0)
    return
  end
  -- A letter read: the entry is the whole record.
  if what == "read" then return end
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
-- 3. Rows
--
-- A memory row is a mail row drawn from a snapshot instead of the live
-- inbox: the same columns, words and colours (Core/CollectTab.lua's
-- CT.RowRules), read-only. Built here and used by both windows -- this one,
-- and the Postbox window's Mail tab when it shows another character's box.
-------------------------------------------------------------

local ROW_ICON = 18

-- The mail row rules, or nil when the collect screen has not loaded -- in
-- which case the row falls back to plain text, which is still a correct if
-- plainer row.
local function Rules()
  return ns.CollectTab and ns.CollectTab.RowRules or nil
end

-- A character's class, as Postbox recorded it at that character's login.
local function ClassOf(realm, name)
  local classes = ns.Store and ns.Store.Get and ns.Store.Get("altClasses")
  local byRealm = type(classes) == "table" and classes[realm] or nil
  return type(byRealm) == "table" and byRealm[name] or nil
end

local function ClassColour(token)
  if type(token) ~= "string" then return nil end
  if C_ClassColor and type(C_ClassColor.GetClassColor) == "function" then
    local ok, colour = pcall(C_ClassColor.GetClassColor, token)
    if ok and colour then return colour end
  end
  return type(RAID_CLASS_COLORS) == "table" and RAID_CLASS_COLORS[token] or nil
end

-- realm, name [, noRealm] -> the name in its class colour (plain where the
-- class is not known), and the realm after it, quieter, when it is not the
-- one being played -- unless `noRealm`: where a box is already on screen,
-- picked from a list that named the realm, the name alone says whose.
function MM.ClassName(realm, name, noRealm)
  local text = tostring(name or "")
  local colour = ClassColour(ClassOf(realm, name))
  if colour then
    if type(colour.WrapTextInColorCode) == "function" then
      text = colour:WrapTextInColorCode(text)
    else
      text = string.format("|cff%02x%02x%02x%s|r", math.floor((colour.r or 1) * 255 + 0.5),
        math.floor((colour.g or 1) * 255 + 0.5), math.floor((colour.b or 1) * 255 + 0.5), text)
    end
  end
  if not noRealm and realm and realm ~= GetRealmName() then
    text = text .. " " .. ns.Theme.Colorize("textSecondary", "- " .. realm)
  end
  return text
end

-- realm, name -> the atlas for that character's class crest, or a generic
-- figure where the class is not known. The character picker wears the crest
-- of the box on screen, so the control says whose box it is.
local CLASS_FALLBACK = { "groupfinder-icon-friend", "socialqueuing-icon-group" }
function MM.ClassIcon(realm, name)
  local T = ns.Theme
  local token = ClassOf(realm, name)
  if type(token) == "string" and token ~= "" then
    local H = ns.Helpers
    local lower = (H and H.Lower) and H.Lower(token) or token
    local atlas = T.FirstAtlas({ "classicon-" .. lower, "groupfinder-icon-class-" .. lower })
    if atlas then return atlas end
  end
  return T.FirstAtlas(CLASS_FALLBACK)
end

-- The crafting quality mark for a remembered mail's item: its own link where
-- the snapshot kept one, the item's generic link by id otherwise.
local function MailMark(mail)
  local R = Rules()
  if not (R and R.QualityMark) then return nil end
  local mark = R.QualityMark(mail.link)
  if not mark and mail.id and C_Item and type(C_Item.GetItemInfo) == "function" then
    local _, link = C_Item.GetItemInfo(mail.id)
    mark = R.QualityMark(link)
  end
  return mark
end

-- parent -> a row for the pool; the caller places it.
function MM.NewRow(parent)
  local T = ns.Theme
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(ROW_HEIGHT)

  -- Every column is placed on fill, where the mail rows' arrangement puts
  -- it (the Mail tab's RV.Place, through the row rules): the read mark, the
  -- icon, the sender, the subject and the three figure columns -- time
  -- left, money, slots -- whose widths depend on the whole list (see
  -- MeasureRows).
  row.Indicator = row:CreateTexture(nil, "ARTWORK")
  local dot = ((Rules() and Rules().DOT) or 8) - 1
  row.Indicator:SetSize(dot, dot)
  row.Indicator:SetTexture("Interface\\AddOns\\Postbox\\Media\\white8x8.tga")
  if type(row.CreateMaskTexture) == "function" then
    local mask = row:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
                    "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(row.Indicator)
    row.Indicator:AddMaskTexture(mask)
  end
  row.Indicator:Hide()

  row.Icon = row:CreateTexture(nil, "ARTWORK")
  row.Icon:SetSize(ROW_ICON, ROW_ICON)
  row.Icon:SetPoint("LEFT", row, "LEFT", 6, 0)
  row.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  row.ColTime = T.CreateText(row, "secondary")
  row.ColMoney = T.CreateText(row, "secondary")
  row.ColSlots = T.CreateText(row, "secondary")
  row.ColTime:SetJustifyH("RIGHT")
  row.ColMoney:SetJustifyH("RIGHT")
  row.ColSlots:SetJustifyH("RIGHT")

  -- The same marker the mail list puts on a refused mail, from the same art.
  local atlas = WarningAtlas()
  if atlas then
    row.Warning = row:CreateTexture(nil, "OVERLAY")
    row.Warning:SetAtlas(atlas, false)
    row.Warning:SetSize(12, 12)
  else
    row.Warning = T.CreateText(row, "value")
    row.Warning:SetText("!")
  end
  row.Warning:SetPoint("RIGHT", row, "RIGHT", -4, 0)
  T.SetColor(row.Warning, "warning")
  row.Warning:Hide()

  row.Sender = T.CreateText(row, "label")
  row.Sender:SetPoint("LEFT", row.Icon, "RIGHT", 6, 0)
  row.Sender:SetJustifyH("LEFT")
  row.Sender:SetWordWrap(false)

  row.Subject = T.CreateText(row, "value")
  row.Subject:SetPoint("LEFT", row.Sender, "RIGHT", 6, 0)
  row.Subject:SetJustifyH("LEFT")
  row.Subject:SetWordWrap(false)
  -- The two anchors above are the fallback for a client without the row
  -- rules; with them, FillRow places everything.

  -- The tooltip belongs to the ICON, not the whole row: a row-wide hit area
  -- meant the tooltip followed the cursor across a list you were only
  -- scanning. The item's own tooltip where the snapshot kept its link or id,
  -- the full subject otherwise.
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
    if row.itemID and type(GameTooltip.SetItemByID) == "function" then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(row.itemID)
      GameTooltip:Show()
      return
    end
    if not row.fullSubject or row.fullSubject == "" then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(row.fullSubject, 1, 1, 1, 1, true)
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
  row.IconHit = hit

  -- A character's name heading its matches in a search of every box: a
  -- click opens that box.
  row.HeaderHit = CreateFrame("Button", nil, row)
  row.HeaderHit:SetAllPoints()
  row.HeaderHit:RegisterForClicks("LeftButtonUp")
  row.HeaderHit:SetScript("OnClick", function(self)
    local owner = self:GetParent()
    if owner.onHeader then owner.onHeader(owner.headerRealm, owner.headerName) end
  end)
  row.HeaderHit:SetScript("OnEnter", function(self)
    local owner = self:GetParent()
    ns.Theme.StyleMailRow(owner, owner._rowIndex, true)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["MEMORY_HEADER_TIP"], 1, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  row.HeaderHit:SetScript("OnLeave", function(self)
    local owner = self:GetParent()
    ns.Theme.StyleMailRow(owner, owner._rowIndex, false)
    GameTooltip:Hide()
  end)
  row.HeaderHit:Hide()

  return row
end

-- mail, now -> the row's three figures as coloured text (or nil each), what
-- the switches keep off the row for its tooltip, and the time-left line.
local function Figures(mail, now)
  local R = Rules()
  local T = ns.Theme
  local hasCOD = (mail.cod or 0) > 0
  local money, moneyKind
  if R then money, moneyKind = R.MoneyText(hasCOD, mail.money or 0, mail.cod or 0, mail.paid, true) end
  local slots = ((mail.items or 0) > 0) and T.Colorize("accent", ns.Plural("COUNT_SLOTS", mail.items)) or nil

  -- Time left by the mail list's own rule (ExpiryState): the player's
  -- threshold, amber when genuinely short -- and "expired" always shows.
  local expiryText, expired = ExpiryText(mail.expires, now)
  local left = (tonumber(mail.expires) or 0) - now
  local expiry
  if expired then
    expiry = T.Colorize("warning", expiryText)
  elseif R then
    local show, warn = R.ExpiryState(left / 86400, hasCOD)
    if show then expiry = T.Colorize(warn and "warning" or "textSecondary", expiryText) end
  end

  -- At most two lines, joined as they come: no list to build per row.
  local facts
  if R and money and not R.MoneyShown(moneyKind) then
    facts = R.MoneyText(hasCOD, mail.money or 0, mail.cod or 0, mail.paid, false)
    money = nil
  end
  if R and slots and not R.Shows("slots") then
    facts = facts and (facts .. "\n" .. slots) or slots
    slots = nil
  end
  if R and not R.Shows("time") then expiry = nil end
  return money, slots, expiry, facts, expiryText, expired, moneyKind == "cod" and money ~= nil
end

-- The last figure the arrangement shows, left to right, or nil.
local function LastShownFigure(R)
  local layout = R and R.Layout and R.Layout()
  if not layout then return "slots" end
  for i = #layout, 1, -1 do
    local id = layout[i].id
    if R.IsFigure(id) and layout[i].shown then return id end
  end
  return nil
end

-- One row's figure texts, keyed by column, plus what the tooltip carries.
-- A row known to have arrived but never opened says "New" where the row's
-- last figure would stand, and nothing else.
--
-- One table, filled again for every row: both callers read it before they
-- ask for the next row, and neither keeps it. The figure ids are the three
-- columns (the rules' IsFigure), so the fields cleared here are all it holds.
local rowTexts = {}
local function RowTexts(mail, now)
  local R = Rules()
  local texts = rowTexts
  texts.time, texts.money, texts.slots, texts.facts = nil, nil, nil, nil
  texts.expiryText, texts.expired, texts.cod = nil, nil, nil
  if mail.header then return texts end
  if mail.pending then
    local last = LastShownFigure(R)
    if last then texts[last] = ns.Theme.Colorize("positive", L["MEMORY_NEW_ROW"]) end
    return texts
  end
  texts.money, texts.slots, texts.time, texts.facts, texts.expiryText, texts.expired, texts.cod = Figures(mail, now)
  return texts
end

-- The list's column widths, measured over every row in it: the mail list's
-- "widest entry anywhere" rule, so nothing twitches as the list scrolls.
-- `owner` is a frame to measure with; `sample` a built row, for its fonts.
function MM.MeasureRows(owner, rows, now, sample)
  local R = Rules()
  local cols = owner._memCols or {}
  owner._memCols = cols
  cols.money, cols.slots, cols.time, cols.stuck = 0, 0, 0, false
  if not R then
    cols.sender = 92
    return cols
  end
  local cap = R.SenderColumn(owner, sample.Sender)
  cols.sender = 0
  local fsFor = { time = sample.ColTime, money = sample.ColMoney, slots = sample.ColSlots }
  -- Each distinct text measured once per pass: a list of every box's matches
  -- repeats "AH Sold", "2 slots" and "29 d" hundreds of times, and each
  -- measure is a SetText and a width read.
  local widths = {}
  local function Width(fs, text)
    local byFont = widths[fs]
    if not byFont then
      byFont = {}
      widths[fs] = byFont
    end
    local width = byFont[text]
    if not width then
      width = R.Measure(owner, fs, text)
      byFont[text] = width
    end
    return width
  end
  -- The sender column is measured only while the arrangement shows it.
  if not R.Shows("sender") then cap = 0 end
  for i = 1, #rows do
    local mail = rows[i]
    if not mail.header and cols.sender < cap then
      local label = R.OutcomeSender(mail.kind) or R.DisplaySender(mail.sender) or ""
      cols.sender = math.min(math.max(cols.sender, Width(sample.Sender, label) + 2), cap)
    end
    local texts = RowTexts(mail, now)
    for id, fs in pairs(fsFor) do
      if texts[id] then cols[id] = math.max(cols[id], Width(fs, texts[id])) end
    end
    if mail.stuck then cols.stuck = true end
  end
  return cols
end

-- row, mail, now, cols, position [, onHeader] -> the row bound to the mail.
-- `onHeader(realm, name)` answers a click on a character's heading.
function MM.FillRow(row, mail, now, cols, position, onHeader)
  local R = Rules()
  local T = ns.Theme
  T.StyleMailRow(row, position, false)
  row.onHeader = onHeader
  if mail.header then
    -- A search across characters: the name the matches below belong to.
    row.fullSubject, row.fullSender, row.itemLink, row.itemID = nil, nil, nil, nil
    row.factsTip, row.expiryTip = nil, nil
    row.headerRealm, row.headerName = mail.realm, mail.name
    -- SetAtlas sets the atlas's own coordinates; a SetTexCoord after it would
    -- show the whole sheet the crest lives on.
    local crest = MM.ClassIcon(mail.realm, mail.name)
    if crest then row.Icon:SetAtlas(crest, false) else row.Icon:SetTexture(nil) end
    -- A heading, not a mail: a quiet band of its own and a hairline above it,
    -- neutral (the name's class colour is the only colour it needs).
    if not row.HeaderWash then
      row.HeaderWash = row:CreateTexture(nil, "BACKGROUND", nil, 2)
      row.HeaderWash:SetAllPoints()
      row.HeaderWash:SetColorTexture(1, 1, 1, 0.07)
      row.HeaderRule = row:CreateTexture(nil, "ARTWORK")
      row.HeaderRule:SetHeight(1)
      row.HeaderRule:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
      row.HeaderRule:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
      row.HeaderRule:SetColorTexture(1, 1, 1, 0.16)
    end
    row.HeaderWash:Show()
    row.HeaderRule:Show()
    row.Icon:Show()
    row.Indicator:Hide()
    row.Warning:Hide()
    row.ColTime:Hide()
    row.ColMoney:Hide()
    row.ColSlots:Hide()
    local width = row:GetParent():GetWidth() or 0
    if width < 100 then width = WINDOW_WIDTH - 44 end
    -- A heading is a crest and a name, whatever the arrangement: it is not
    -- a mail. Through the rules' own anchor, so a row reused for a mail
    -- afterwards is placed from where it really stands.
    if R and R.Anchor then
      R.Anchor(row, row.Icon, 1, 6, 0)
      R.Anchor(row, row.Sender, 1, 6 + ROW_ICON + 6, 0)
      R.Wash(row, nil)
    end
    row.Sender:Show()
    row.Subject:Show()
    T.FitText(row.Sender, width - 40, mail.label, nil)
    T.FitText(row.Subject, 1, "", nil)
    row.HeaderHit:SetShown(onHeader ~= nil)
    local R0 = Rules()
    if R0 and R0.PaintQuality then R0.PaintQuality(row, nil) end
    row:SetAlpha(1)
    row:Show()
    return
  end
  row.HeaderHit:Hide()
  if row.HeaderWash then
    row.HeaderWash:Hide()
    row.HeaderRule:Hide()
  end
  row.fullSubject = mail.subject
  row.fullSender = mail.sender
  row.itemLink = mail.link
  row.itemID = mail.id

  -- No icon of its own (a letter the snapshot kept none for): the column
  -- keeps its place, empty, so the names still start on one line.
  row.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  row.Icon:SetTexture(mail.icon)

  row.Warning:SetShown(mail.stuck and true or false)
  -- The read mark, as the Mail tab has it: mail known to have arrived and
  -- not yet opened is unread by definition.
  T.SetColor(row.Indicator, (mail.read and not mail.pending) and "read" or "unread")

  -- Read at once: RowTexts fills the same table for the next row.
  local texts = RowTexts(mail, now)
  local timeText, moneyText, slotsText = texts.time, texts.money, texts.slots
  local codShown, expired = texts.cod, texts.expired
  row.factsTip = texts.facts
  row.expiryTip = texts.expiryText

  local width = row:GetParent():GetWidth() or 0
  if width < 100 then width = WINDOW_WIDTH - 44 end
  local trail = 6 + (cols.stuck and 16 or 0)

  local named = (mail.sender ~= "" and mail.sender) or nil
  local senderText = (R and (R.OutcomeSender(mail.kind) or R.DisplaySender(named)))
    or named or L["MEMORY_SENDER_UNKNOWN"]
  local subject = (ns.Helpers and ns.Helpers.ShortSubject) and ns.Helpers.ShortSubject(mail.subject or "")
    or (mail.subject or "")
  -- The crafting quality mark: on the icon's corner, after the name, or both
  -- -- wherever the Mail tab puts it.
  local mark = (not mail.pending) and MailMark(mail) or nil
  if R and R.WithMark and R.MarkOnName and R.MarkOnName() then subject = R.WithMark(subject, mark) end
  if R and R.PaintQuality then R.PaintQuality(row, mark) end

  if R and R.Place then
    -- The Mail tab's own placement, at this window's spacing: every column
    -- where the arrangement puts it, the figures packed to the right edge
    -- by the mail list's own rule, the subject taking the rest.
    local spec = MM._fillSpec
    if not spec then
      spec = R.NewSpec()
      MM._fillSpec = spec
    end
    local el, text = spec.el, spec.text
    el.read, el.icon, el.sender, el.subject = row.Indicator, row.Icon, row.Sender, row.Subject
    el.time, el.money, el.slots = row.ColTime, row.ColMoney, row.ColSlots
    text.sender, text.subject = senderText, subject
    text.time, text.money, text.slots = timeText, moneyText, slotsText
    spec.size.icon = ROW_ICON
    spec.width, spec.left, spec.trail, spec.gap = width, 6, trail, 6
    spec.cols = cols
    spec.senderCol = cols.sender or 92
    spec.share, spec.reserve, spec.two = R.META_SHARE, false, false
    -- A C.O.D. price shows with the gold column hidden, as on the Mail tab.
    spec.force = codShown and "money" or nil
    spec.focus = R.Focus and R.Focus() or nil
    R.Place(row, spec)
    -- The icon's hover goes with the icon.
    if row.IconHit then row.IconHit:SetShown(row.Icon:IsShown()) end
  else
    -- No row rules (the Mail tab's file did not load): the names alone.
    local textWidth = width - (6 + ROW_ICON + 6) - trail
    local senderWidth = math.min(cols.sender or 92, math.floor(textWidth / 2))
    T.FitText(row.Sender, senderWidth, senderText, nil)
    T.FitText(row.Subject, math.max(textWidth - senderWidth - 6, 20), subject, nil)
  end

  -- A mail past its date is PROBABLY gone (returned or deleted by the
  -- server); the row stays listed -- it was true when seen -- but visibly
  -- belongs to the past.
  row:SetAlpha(expired and 0.45 or 1)
  row:Show()
end

-------------------------------------------------------------
-- 3b. Mail that arrived after the snapshot
--
-- Shown as rows at the top of the list, not as a badge: what is known about
-- it is shown the way the rest of the box is. The auction house names the
-- item when an auction sells, expires or is won (its notification, which
-- reaches the client wherever the player is), so those rows say "AH Sold --
-- Lightning Etched Specs". Anything else that is known to have arrived --
-- the client's latest-senders line, the unread flag -- is a row from that
-- sender, "not opened yet". Everything a visit will show properly, and a
-- visit clears it.
-------------------------------------------------------------

local function PendingIcon(entry)
  if C_Item and type(C_Item.GetItemIconByID) == "function" and entry.item then
    local ok, icon = pcall(C_Item.GetItemIconByID, entry.item)
    if ok and icon then return icon end
  end
  if entry.k == "sold" then return "Interface\\Icons\\INV_Misc_Coin_01" end
  return "Interface\\Icons\\INV_Letter_02"
end

-- watch, arrived, from, snap -> the rows for mail known to have arrived,
-- newest first. The client's latest-senders line names every UNREAD sender,
-- not only new ones, so a sender with unread mail already in the snapshot is
-- that mail, not an arrival.
local function PendingRows(watch, arrived, from, snap)
  local out = {}
  local pending = LivePending(watch)
  local known = {}
  local mails = snap and snap.mails or {}
  for i = 1, #mails do
    if not mails[i].read and mails[i].sender then known[mails[i].sender] = true end
  end
  for i = #pending, 1, -1 do
    local p = pending[i]
    local subject = p.item or ""
    if (tonumber(p.n) or 1) > 1 then subject = subject .. " (" .. p.n .. ")" end
    out[#out + 1] = { pending = true, kind = p.k, sender = "", subject = subject, icon = PendingIcon(p) }
  end
  if arrived then
    local ah = L["MEMORY_FROM_AH"]
    local hostAH = type(_G.AUCTION_HOUSE) == "string" and _G.AUCTION_HOUSE or nil
    if type(from) == "table" then
      for i = 1, #from do
        local sender = from[i]
        local isAH = (sender == ah or sender == hostAH)
        -- The auction house's arrivals are already rows, by item.
        if not (isAH and #pending > 0) and not known[sender] then
          out[#out + 1] = { pending = true, sender = sender, subject = L["MEMORY_NEW_UNOPENED"],
            icon = "Interface\\Icons\\INV_Letter_02" }
        end
      end
    end
    if #out == 0 then
      out[1] = { pending = true, sender = L["MEMORY_SENDER_UNKNOWN"], subject = L["MEMORY_NEW_UNOPENED"],
        icon = "Interface\\Icons\\INV_Letter_02" }
    end
  end
  return out
end

-- For the minimap tooltip's "arrived" section: what the notifications named,
-- newest first, as { label = outcome in its tone, item = name }.
function MM.PendingSummary()
  local realm, name = Me()
  local watch = WatchFor(realm, name, false)
  local pending = LivePending(watch)
  local R = Rules()
  local out = {}
  for i = #pending, 1, -1 do
    local p = pending[i]
    local item = p.item or ""
    if (tonumber(p.n) or 1) > 1 then item = item .. " (" .. p.n .. ")" end
    out[#out + 1] = { label = (R and R.OutcomeSender(p.k)) or L["MEMORY_FROM_AH"], item = item }
  end
  return out
end

-------------------------------------------------------------
-- 3c. Characters
--
-- Who has a box worth looking at -- the one being played, and any other
-- whose box held mail, has mail on the way, or has a warning -- and the
-- picker that lists them. One picker for both windows: it opens under the
-- button that asked for it, lists names in class colour with their counts in
-- a column, marks the box on screen, and closes on a pick or a click
-- anywhere else.
--
-- A right-click hides a character (section 2b). It does not vanish: it drops
-- under "Hidden (N)" at the foot of the list, which unfolds to show it greyed
-- with Show beside it -- the undo, one click away, in the list it left.
-------------------------------------------------------------

local PICK_ROW_H = 20
local PICK_MAX = 14

-- all -> the characters the picker offers, and the ones it would offer but
-- the player hid. Everything else about a hidden character is as it was.
local function SwitchChoices(all)
  all = all or MM.Characters()
  local out, hidden = {}, {}
  for i = 1, #all do
    local st = all[i]
    if st.me or st.waiting > 0 or (st.pending or 0) > 0 or st.warn then
      if st.hidden then hidden[#hidden + 1] = st else out[#out + 1] = st end
    end
  end
  return out, hidden
end

-- Whether there is another character's box to look at, and how many more
-- there would be but for the ones the player hid. `all` is an
-- MM.Characters() list the caller has already built, where it has one.
function MM.HasOthers(all)
  if not MemoryEnabled() then return false, 0 end
  local choices, hidden = SwitchChoices(all)
  for i = 1, #choices do
    if not choices[i].me then return true, #hidden end
  end
  return false, #hidden
end

-- realm, name -> what the picker says of that character: its count of mail
-- waiting (with what is known to be on the way) and whether it warns.
function MM.CountFor(realm, name)
  local myRealm, myName = Me()
  local st = Status(realm or myRealm, name or myName, time())
  return st.waiting + (st.pending or 0), st.warn, WarningText(st, time())
end

-- The foot of the list, standing for the characters the player hid: one
-- shared marker, told apart from a character by `foot`.
local PICK_FOOT = { foot = true }

-- The list's entries, read afresh -- a hide or a show moves a character
-- from one half to the other: the characters it offers, then, while any are
-- hidden, the foot that folds them away and, unfolded, the hidden ones under
-- it by name. The offset stays inside what is left.
local function LoadPicker(list)
  local choices, hidden = SwitchChoices()
  table.sort(hidden, ByName)
  list.choices, list.hidden = choices, hidden
  local entries = {}
  for i = 1, #choices do entries[#entries + 1] = choices[i] end
  if #hidden > 0 then
    entries[#entries + 1] = PICK_FOOT
    if list.showHidden then
      for i = 1, #hidden do entries[#entries + 1] = hidden[i] end
    end
  end
  list.entries = entries
  list.offset = math.max(0, math.min(list.offset or 0, #entries - PICK_MAX))
end

-- A row's tooltip: whose it is and what it has to say, then the gesture the
-- row cannot show by itself -- the Mail tab's rows teach theirs the same way.
-- The character being played has no gesture, so it says something only when
-- it has something to say.
local function PickerTip(row)
  local kind = row.kind
  if kind == "character" and row.isMe and not row.reason then
    GameTooltip:Hide()
    return
  end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  if kind == "foot" then
    GameTooltip:SetText(L["HIDDEN_TITLE"])
    GameTooltip:AddLine(L["HIDDEN_DESC"], 1, 1, 1, true)
  else
    GameTooltip:SetText(MM.ClassName(row.realm, row.charName))
    if kind == "hidden" then
      GameTooltip:AddLine(L["PICKER_SHOW_TIP"], 1, 1, 1, true)
    else
      if row.reason then GameTooltip:AddLine(row.reason, 1, 1, 1, true) end
      if not row.isMe then GameTooltip:AddLine(L["PICKER_HIDE_HINT"], 0.7, 0.7, 0.7, true) end
    end
  end
  GameTooltip:Show()
end

local function PaintPicker(list)
  local T = ns.Theme
  local entries = list.entries or {}
  local cur = list.current
  local first = list.offset + 1
  local shown = math.min(#entries, PICK_MAX)
  local nameW, countW, footW = 0, 0, 0
  for i = 1, shown do
    local st = entries[first + i - 1]
    local row = list.rows[i]
    if not row then
      row = CreateFrame("Button", nil, list)
      row:SetHeight(PICK_ROW_H)
      row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
      row.Hover = row:CreateTexture(nil, "BACKGROUND")
      row.Hover:SetAllPoints()
      row.Hover:SetColorTexture(1, 1, 1, 0.06)
      row.Hover:Hide()
      row.Bar = row:CreateTexture(nil, "ARTWORK")
      row.Bar:SetWidth(2)
      row.Bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
      row.Bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
      row.Bar:SetTexture("Interface\\AddOns\\Postbox\\Media\\white8x8.tga")
      -- The hairline over the foot: the names above it are offered, the ones
      -- below it are not. Neutral, as a row heading's rule is.
      row.Rule = row:CreateTexture(nil, "ARTWORK")
      row.Rule:SetHeight(1)
      row.Rule:SetPoint("TOPLEFT", row, "TOPLEFT", 6, 0)
      row.Rule:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, 0)
      row.Rule:SetColorTexture(1, 1, 1, 0.12)
      row.Rule:Hide()
      row.Crest = row:CreateTexture(nil, "ARTWORK")
      row.Crest:SetSize(14, 14)
      row.Crest:SetPoint("LEFT", row, "LEFT", 8, 0)
      row.Name = T.CreateText(row, "value")
      row.Name:SetJustifyH("LEFT")
      row.Name:SetWordWrap(false)
      row.Count = T.CreateText(row, "secondary")
      row.Count:SetPoint("RIGHT", row, "RIGHT", -8, 0)
      row.Count:SetJustifyH("RIGHT")
      row:SetScript("OnEnter", function(self)
        self.Hover:Show()
        PickerTip(self)
      end)
      row:SetScript("OnLeave", function(self)
        self.Hover:Hide()
        GameTooltip:Hide()
      end)
      -- A left click on a character picks it. A right click hides it, and it
      -- drops under the foot, unfolded, so where it went is on screen and so
      -- is the way back. A click on the foot folds or unfolds it; one on a
      -- hidden character shows it again. The list stays up for all three.
      row:SetScript("OnClick", function(self, button)
        local kind = self.kind
        if kind == "character" and button ~= "RightButton" then
          local pick = list.onPick
          list:Hide()
          if pick then pick(self.realm, self.charName, self.isMe) end
          return
        end
        if kind == "foot" then
          list.showHidden = not list.showHidden
        elseif kind == "hidden" then
          MM.SetHidden(self.realm, self.charName, false)
          list.dirty = true
        elseif not self.isMe then
          MM.SetHidden(self.realm, self.charName, true)
          list.dirty = true
          list.showHidden = true
        else
          return
        end
        LoadPicker(list)
        PaintPicker(list)
        -- The row under the pointer may stand for another entry now.
        if self:IsShown() and self:IsMouseOver() then PickerTip(self) else GameTooltip:Hide() end
      end)
      list.rows[i] = row
    end

    row.Name:ClearAllPoints()
    row.Name:SetWidth(0)
    local current = false
    if st.foot then
      row.kind = "foot"
      row.realm, row.charName, row.isMe, row.reason = nil, nil, false, nil
      row.Crest:Hide()
      row.Rule:Show()
      row.Name:SetPoint("LEFT", row, "LEFT", 8, 0)
      row.Name:SetText(string.format(L["PICKER_HIDDEN"], #(list.hidden or {})))
      -- Brighter while unfolded: its state rises in colour, not alpha alone.
      T.SetColor(row.Name, list.showHidden and "textPrimary" or "textSecondary")
      row.Name:SetAlpha(1)
      row.Count:SetText("")
      footW = math.max(footW, row.Name:GetStringWidth() or 0)
    else
      row.kind = st.hidden and "hidden" or "character"
      row.realm, row.charName, row.isMe = st.realm, st.name, st.me
      row.reason = (not st.hidden) and st.text or nil
      row.Rule:Hide()
      local crest = MM.ClassIcon(st.realm, st.name)
      if crest then row.Crest:SetAtlas(crest, false) else row.Crest:SetTexture(nil) end
      row.Crest:Show()
      row.Name:SetPoint("LEFT", row.Crest, "RIGHT", 6, 0)
      if st.hidden then
        -- Greyed in colour AND alpha together: no class colour, a crest
        -- without its hue, both a step back -- and Show beside it at full
        -- strength, the one thing on the row to do.
        row.Crest:SetDesaturated(true)
        row.Crest:SetAlpha(0.5)
        T.SetColor(row.Name, "textDisabled")
        row.Name:SetAlpha(0.8)
        row.Name:SetText(st.label)
        row.Count:SetText(L["PICKER_SHOW"])
      else
        row.Crest:SetDesaturated(false)
        row.Crest:SetAlpha(1)
        T.SetColor(row.Name, "textPrimary")
        row.Name:SetAlpha(1)
        row.Name:SetText(MM.ClassName(st.realm, st.name))
        local waiting = st.waiting + (st.pending or 0)
        local count = ns.Plural("COUNT_MAILS", waiting)
        row.Count:SetText(st.warn and T.Colorize("warning", count) or count)
      end
      nameW = math.max(nameW, row.Name:GetStringWidth() or 0)
      countW = math.max(countW, row.Count:GetStringWidth() or 0)
      current = (cur == nil and st.me) or (cur ~= nil and cur.realm == st.realm and cur.name == st.name)
    end
    if current and T.GetAccent then
      local r, g, b = T.GetAccent()
      row.Bar:SetVertexColor(r, g, b, 0.9)
    end
    row.Bar:SetShown(current and true or false)
  end
  -- A row no longer needed keeps no hover wash for the next time it is.
  for i = shown + 1, #list.rows do
    list.rows[i].Hover:Hide()
    list.rows[i]:Hide()
  end

  local width = 8 + 14 + 6 + math.ceil(nameW) + 20 + math.ceil(countW) + 8
  width = math.max(width, 8 + math.ceil(footW) + 8)
  for i = 1, shown do
    local row = list.rows[i]
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", list, "TOPLEFT", 1, -4 - (i - 1) * PICK_ROW_H)
    row:SetWidth(width - 2)
    row.Name:SetWidth(math.ceil(row.kind == "foot" and footW or nameW) + 2)
    row:Show()
  end
  list:SetSize(width, 8 + shown * PICK_ROW_H)
end

-- anchor, current, onPick -> the character list under `anchor`. `current` is
-- the box on screen ({ realm, name }, or nil for the one being played);
-- onPick(realm, name, isMe) answers a pick. A second click on the same
-- anchor closes it.
function MM.OpenPicker(anchor, current, onPick)
  local T = ns.Theme
  local list = MM._picker
  if list and list:IsShown() and list.anchor == anchor then
    list:Hide()
    return
  end
  if not list then
    list = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    list.__pbPopupAlways = true
    T.ApplyCard(list)
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    list:SetClampedToScreen(true)
    list:EnableMouse(true)
    list:EnableMouseWheel(true)
    list.rows = {}
    -- Closes on any click outside it -- the list and the button that opened
    -- it excepted, so that button's own click can close it. No full-screen
    -- catcher frame: one swallowed the very click that chose a character.
    list:SetScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
    list:SetScript("OnHide", function(self)
      self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
      -- A hide or a show made while the list was up repaints everything that
      -- lists characters now, once: until the list closes, the button it
      -- hangs from has to stay where it is.
      if self.dirty then
        self.dirty = false
        MM.HiddenChanged()
      end
    end)
    list:SetScript("OnEvent", function(self)
      if self:IsMouseOver() or (self.anchor and self.anchor:IsMouseOver()) then return end
      -- When, so a click that closed it here and then reaches a way in
      -- (the minimap icon, the addon menu) reads as the second click of a
      -- toggle, not as a request to open it again (MM.Toggle).
      self.closedAt = type(GetTime) == "function" and GetTime() or nil
      self:Hide()
    end)
    -- Past PICK_MAX names the wheel moves the list a name at a time.
    list:SetScript("OnMouseWheel", function(self, delta)
      local most = math.max(0, #(self.entries or {}) - PICK_MAX)
      local offset = math.max(0, math.min(most, self.offset - delta))
      if offset ~= self.offset then
        self.offset = offset
        PaintPicker(self)
      end
    end)
    MM._picker = list
    if ns.Skin and ns.Skin.Refresh then pcall(ns.Skin.Refresh, list) end
    -- A new frame starts SHOWN, so the Show below would not fire OnShow and
    -- the click-away would never be registered on the first open.
    list:Hide()
  end
  list.anchor, list.onPick, list.current = anchor, onPick, current
  list.offset = 0
  -- The hidden characters folded away -- unless the box on screen is one of
  -- them, when the mark that says which box it is has to be seen.
  list.showHidden = current ~= nil and MM.IsHidden(current.realm, current.name)
  LoadPicker(list)
  PaintPicker(list)
  -- Hanging from the button's left edge and growing right, as a menu opens
  -- from what was clicked -- out past the window's edge where it must; it
  -- is clamped to the screen, not the window.
  list:ClearAllPoints()
  list:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
  list:Show()
  list:Raise()
end

function MM.ClosePicker()
  if MM._picker then MM._picker:Hide() end
end

-------------------------------------------------------------
-- 3d. What a box shows
--
-- The rows for one character's box, narrowed by a search; or, searching every
-- character, each character's matches under a heading with its name. Sorted
-- as the box has them (newest first) or with the soonest to expire first.
-------------------------------------------------------------

local function Fold(text)
  local H = ns.Helpers
  if H and H.Lower then return H.Lower(tostring(text or "")) end
  return string.lower(tostring(text or ""))
end

-- One matcher for every list a search narrows: the sender as written, the
-- sender as the row shows it (an auction outcome, "AH Sold"), and the
-- subject -- which for an auction mail is the item's name.
--
-- The folded text is kept per mail table (`searchText`, section 1): a search
-- of every box used to colour, uncolour and fold every remembered mail on
-- every keystroke.
local function Matches(mail, query)
  local hay = searchText[mail]
  if not hay then
    local R = Rules()
    local outcome = R and R.OutcomeSender and mail.kind and R.OutcomeSender(mail.kind) or ""
    -- The outcome label arrives coloured; the escape codes are not searched.
    outcome = outcome:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    hay = Fold((mail.sender or "") .. "\001" .. (mail.subject or "") .. "\001" .. outcome)
    -- Kept only once the row rules could name the outcome.
    if R then searchText[mail] = hay end
  end
  return hay:find(query, 1, true) ~= nil
end
MM.Fold = Fold

-- mails, sort, now -> the mails in the order asked for. "expiry": the
-- soonest to go first, and what has already gone last.
local function Sorted(mails, sort, now)
  if sort ~= "expiry" then return mails end
  local out = {}
  for i = 1, #mails do out[i] = mails[i] end
  table.sort(out, function(a, b)
    local ea, eb = tonumber(a.expires) or 0, tonumber(b.expires) or 0
    local ga, gb = ea <= now, eb <= now
    if ga ~= gb then return gb end
    if ea ~= eb then return ea < eb end
    return (a.subject or "") < (b.subject or "")
  end)
  return out
end

-- A mail of this visit's look, as a list may keep it: the next capture fills
-- that look's tables again (section 1), and a list built from them must go on
-- showing what it was built from.
local function Frozen(mail)
  local copy = {}
  for key, value in pairs(mail) do copy[key] = value end
  return copy
end

-- A visit that ended without either close event reaching this module
-- stranded `live`: settle it now exactly as the close handler would,
-- carrying marks made against the prior record across the late persist.
local function HealLive()
  local state = MailboxState()
  if not live or (state and state.mailboxOpen) then return end
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

local function SnapshotOf(realm, name)
  local myRealm, myName = Me()
  if realm == myRealm and name == myName then return live or StoredSnapshot() end
  return SnapshotFor(realm, name)
end

-- Every character's matches, each under a heading with its name. A hidden
-- character is not searched: the search of every box browses the other
-- characters, and the player took that one out of them.
local function SearchAll(query, now, sort, all)
  local rows, characters = {}, 0
  all = all or MM.Characters()
  for i = 1, #all do
    local st = all[i]
    local snap = (not st.hidden) and SnapshotOf(st.realm, st.name) or nil
    local mails = Sorted(snap and snap.mails or {}, sort, now)
    local found = nil
    for j = 1, #mails do
      if Matches(mails[j], query) then
        if not found then
          found = true
          characters = characters + 1
          rows[#rows + 1] = { header = true, realm = st.realm, name = st.name,
            label = MM.ClassName(st.realm, st.name) }
        end
        rows[#rows + 1] = (snap == live) and Frozen(mails[j]) or mails[j]
      end
    end
  end
  return rows, characters
end

-- snapshot -> arrived, from: whether mail is known to have landed since this
-- character's snapshot, and who from, where the client says. Three
-- independent detectors, ANY suffices, each sound on its own:
--
--   1. The arrival watch's stored mark (the pending-mail event, guarded).
--   2. The flag FLIP: HasNewMail() is "unread mail exists", so its value
--      proves nothing -- but false at close and true now can only mean an
--      arrival in between.
--   3. The sender-triple CHANGE: the latest-unread-senders line the
--      client keeps reshuffles whenever mail lands, including while
--      logged out; the snapshot remembers what it said at close.
--
-- A mailbox visit replaces the record and re-baselines all three. Only the
-- character being played can be asked, and only away from a mailbox (at one,
-- the live look holds the mail itself). Mail Memory's rows and the minimap
-- tooltip both ask here: the tooltip used to read the stored mark alone, and
-- told a character back after days away "nothing waiting" over mail that had
-- landed while it was logged out.
local function ArrivedSince(snapshot)
  if not snapshot then return false, nil end
  EnsureBaseline(snapshot)
  local state = MailboxState()
  local away = not (state and state.mailboxOpen)
  local flagNow = away and type(HasNewMail) == "function" and HasNewMail() and true or false
  local tripleNow = away and SenderTriple() or nil
  local arrived = snapshot.newSince == true
    or (flagNow and snapshot.baseNew == false)
    or (tripleNow ~= nil and snapshot.baseFrom ~= nil and tripleNow ~= snapshot.baseFrom)
  local from = snapshot.newFrom
  if arrived and not from and type(GetLatestThreeSenders) == "function" then
    local a, b, c = GetLatestThreeSenders()
    from = {}
    if a then from[#from + 1] = tostring(a) end
    if b then from[#from + 1] = tostring(b) end
    if c then from[#from + 1] = tostring(c) end
    if #from == 0 then from = nil end
  end
  return arrived and true or false, from
end

-- realm, name, opts -> rows, info. `realm`/`name` nil for the character
-- being played. opts.query: the search, folded ("" for none); opts.all:
-- search every character's box; opts.sort: "expiry" for the soonest first;
-- opts.characters: an MM.Characters() list already built for this refresh.
-- info: realm, name, me, snapshot, total (mails in the snapshot), hidden
-- (in the box but past the record's cap), matched, onCharacters.
function MM.RowsFor(realm, name, opts)
  opts = opts or {}
  local myRealm, myName = Me()
  realm, name = realm or myRealm, name or myName
  local me = (realm == myRealm and name == myName)
  local now = time()
  local state = MailboxState()
  if me then HealLive() end
  local snapshot = SnapshotOf(realm, name)

  -- Mail known to have arrived after the snapshot (ArrivedSince). Only the
  -- character being played can be asked; another's watch says the rest.
  local arrived, from = false, nil
  if snapshot and me then arrived, from = ArrivedSince(snapshot) end

  -- At a mailbox the live look already holds what arrived: rows for it
  -- would list those mails twice.
  local atBox = me and state and state.mailboxOpen
  local rows = atBox and {} or PendingRows(WatchFor(realm, name, false), arrived, from, snapshot)
  local mails = Sorted(snapshot and snapshot.mails or {}, opts.sort, now)
  for i = 1, #mails do rows[#rows + 1] = mails[i] end

  local info = { realm = realm, name = name, me = me, snapshot = snapshot, total = #mails }
  info.hidden = snapshot and math.max(0, (tonumber(snapshot.total) or #mails) - #mails) or 0

  local query = opts.query or ""
  if query ~= "" then
    if opts.all then
      rows, info.onCharacters = SearchAll(query, now, opts.sort, opts.characters)
      local matched = 0
      for i = 1, #rows do if not rows[i].header then matched = matched + 1 end end
      info.matched = matched
    else
      local kept = {}
      for i = 1, #rows do
        if Matches(rows[i], query) then kept[#kept + 1] = rows[i] end
      end
      rows = kept
      info.matched = #rows
    end
  end
  -- This character's box at a mailbox is this visit's look (SearchAll makes
  -- its own copies).
  if live and snapshot == live and not (query ~= "" and opts.all) then
    for i = 1, #rows do rows[i] = Frozen(rows[i]) end
  end
  return rows, info
end

-- snapshot -> "Last seen 27 min ago." or the words for none / an empty box.
function MM.SeenText(snapshot)
  if not snapshot then return L["MEMORY_EMPTY"] end
  if #(snapshot.mails or {}) == 0 then
    return string.format(L["MEMORY_ASOF_EMPTY"], AgeText(snapshot.seenAt))
  end
  return string.format(L["MEMORY_LASTSEEN"], AgeText(snapshot.seenAt))
end

-- snapshot -> just the age, "27 min ago".
function MM.AgeText(snapshot)
  return snapshot and AgeText(snapshot.seenAt) or ""
end

-------------------------------------------------------------
-- 3e. The window
--
-- Mail Memory: what the boxes held, for when there is no mailbox to open. A
-- Blizzard window template (skins re-point or strip it), the addon's frame
-- theme, Escape to close, and a themed card whose children both host skins
-- can find. Laid out as the Mail tab is: whose box on the left of the top
-- row, the character picker and the search at its right, the list, and a
-- quiet line at the foot saying when the box was seen.
-------------------------------------------------------------

local HEADER_Y = -28
local HEADER_H = 22
local SEARCH_W = 150
local SORT_ATLASES = { "auctionhouse-ui-sortarrow", "UI-HUD-ActionBar-PageDownArrow-Up", "NPE_ArrowDown" }

local Refresh

local function SearchQuery(frame)
  local box = frame.SearchBox
  local text = box and box:GetText() or ""
  return Fold((text:match("^%s*(.-)%s*$")))
end

-- A square control from the theme's segment plate, wearing an atlas: the
-- same control the Mail tab's History clock is.
local function IconPlate(parent, atlases, size)
  local T = ns.Theme
  local plate = T.CreatePlate(parent, "segment")
  plate:SetSize(size, size)
  plate:SetText("")
  plate.Icon = plate:CreateTexture(nil, "OVERLAY")
  plate.Icon:SetSize(size - 8, size - 8)
  plate.Icon:SetPoint("CENTER")
  local atlas = atlases and T.FirstAtlas(atlases)
  if atlas then plate.Icon:SetAtlas(atlas, false) end
  return plate
end

local function BuildSearch(frame)
  local T = ns.Theme
  -- Theme's search box, as the Mail tab's is: the toggle inside its right end
  -- searches every character's box (Refresh shows it and places the clear
  -- button beside it).
  local search
  search = T.CreateSearchBox(frame, SEARCH_W, HEADER_H, L["SEARCH_PLACEHOLDER"], {
    onTextChanged = function() Refresh(frame) end,
    onToggle = function()
      frame.searchAll = not frame.searchAll
      search.PaintToggle(frame.searchAll)
      Refresh(frame)
    end,
    toggleTip = function(tip)
      tip:SetText(L["MEMORY_SEARCH_ALL_TITLE"])
      tip:AddLine(L[frame.searchAll and "MEMORY_SEARCH_ALL_ON" or "MEMORY_SEARCH_ALL_OFF"], 1, 1, 1, true)
    end,
  })
  search.Wrap:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(PAD - 2), HEADER_Y)
  frame.Search = search
  frame.SearchWrap, frame.SearchBox, frame.SearchClear = search.Wrap, search.Box, search.Clear
  -- Repaints the toggle for frame.searchAll, wherever that is set from.
  search.All.Paint = function() search.PaintToggle(frame.searchAll) end
  frame.SearchAllButton = search.All
end

-- The character picker and the sort, left of the search on the top row.
local function BuildHeader(frame)
  local T = ns.Theme
  local picker = IconPlate(frame, CLASS_FALLBACK, HEADER_H)
  picker:SetPoint("RIGHT", frame.SearchWrap, "LEFT", -4, 0)
  picker:SetScript("OnClick", function(self)
    MM.OpenPicker(self, frame.viewing, function(realm, name, isMe)
      frame.viewing = (not isMe) and { realm = realm, name = name } or nil
      if frame.Scroll then frame.Scroll:SetVerticalScroll(0) end
      Refresh(frame)
    end)
  end)
  picker:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
    GameTooltip:SetText(L["PICKER_TITLE"])
    GameTooltip:AddLine(L["PICKER_TIP"], 1, 1, 1, true)
    GameTooltip:Show()
  end)
  picker:HookScript("OnLeave", function() GameTooltip:Hide() end)
  frame.Picker = picker

  -- Newest first, as the box has them, or the soonest to expire first.
  local sort = IconPlate(frame, SORT_ATLASES, HEADER_H)
  if not (sort.Icon.GetAtlas and sort.Icon:GetAtlas()) then sort:SetText("v") end
  sort:SetPoint("RIGHT", picker, "LEFT", -4, 0)
  local function PaintSort()
    T.SetPlateSelected(sort, frame.sort == "expiry")
  end
  local function SortTip(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
    GameTooltip:SetText(L[frame.sort == "expiry" and "SORT_EXPIRY_TITLE" or "SORT_NEWEST_TITLE"])
    GameTooltip:AddLine(L["SORT_TIP"], 1, 1, 1, true)
    GameTooltip:Show()
  end
  sort:SetScript("OnClick", function(self)
    frame.sort = (frame.sort ~= "expiry") and "expiry" or nil
    PaintSort()
    if frame.Scroll then frame.Scroll:SetVerticalScroll(0) end
    Refresh(frame)
    -- The tooltip names the order on screen: it changes with the click.
    if GameTooltip:IsOwned(self) then SortTip(self) end
  end)
  sort:HookScript("OnEnter", SortTip)
  sort:HookScript("OnLeave", function() GameTooltip:Hide() end)
  frame.Sort = sort
  PaintSort()

  -- Whose box, and how much is waiting in it: the name in its class colour,
  -- the count beside it, in the warning tone when the box needs a look.
  frame.Who = T.CreateText(frame, "label")
  frame.Who:SetPoint("LEFT", frame, "TOPLEFT", PAD, HEADER_Y - HEADER_H / 2)
  frame.Who:SetPoint("RIGHT", sort, "LEFT", -8, 0)
  frame.Who:SetJustifyH("LEFT")
  frame.Who:SetWordWrap(false)
end

-- A search across every box lists each character under a heading; a click
-- on one opens that character's box.
-- The rows the viewport can show, bound and placed by position -- the Mail
-- tab's own virtualiser. Every row is re-anchored on every bind: rows placed
-- once at creation, down a list that a resize or a reset had just rebuilt,
-- drew only the first of them until something forced a redraw.
local function BindRows(frame)
  local rows = frame._list or {}
  local scroll = frame.Scroll
  local viewport = scroll:GetHeight() or 0
  if viewport <= 0 then viewport = DEFAULT_ROWS * ROW_HEIGHT end
  local offset = scroll:GetVerticalScroll() or 0
  local first = math.max(1, math.floor(offset / ROW_HEIGHT) + 1)
  local last = math.min(#rows, math.ceil((offset + viewport) / ROW_HEIGHT))
  local now = frame._now or time()
  local onHeader = frame._onHeader
  local used = 0
  for i = first, last do
    used = used + 1
    local row = frame.Rows[used]
    if not row then
      row = MM.NewRow(frame.ListChild)
      frame.Rows[used] = row
    end
    local y = -(i - 1) * ROW_HEIGHT
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", frame.ListChild, "TOPLEFT", 0, y)
    row:SetPoint("TOPRIGHT", frame.ListChild, "TOPRIGHT", 0, y)
    MM.FillRow(row, rows[i], now, frame._cols or {}, i, onHeader)
  end
  for i = used + 1, #frame.Rows do frame.Rows[i]:Hide() end
end

local function OnHeader(frame, realm, name)
  local myRealm, myName = Me()
  frame.viewing = (realm == myRealm and name == myName) and nil or { realm = realm, name = name }
  frame.searchAll = false
  if frame.SearchAllButton then frame.SearchAllButton.Paint() end
  if frame.SearchBox then frame.SearchBox:SetText("") end
  if frame.Scroll then frame.Scroll:SetVerticalScroll(0) end
  Refresh(frame)
end

function Refresh(frame)
  local T = ns.Theme
  local v = frame.viewing
  local query = SearchQuery(frame)
  -- One character list for the whole refresh: the search of every box and
  -- the picker's "anyone else?" both read it.
  local characters = MM.Characters()
  local rows, info = MM.RowsFor(v and v.realm, v and v.name,
    { query = query, all = frame.searchAll, sort = frame.sort, characters = characters })
  local now = time()
  local count = #rows

  -- The top row: whose box, and its count, where the Mail tab has Inbox.
  local waiting, warn = MM.CountFor(info.realm, info.name)
  local tally = ns.Plural("COUNT_MAILS", waiting)
  frame.Who:SetText(MM.ClassName(info.realm, info.name, true) .. "  "
    .. T.Colorize(warn and "warning" or "textSecondary", "(" .. tally .. ")"))
  local crest = MM.ClassIcon(info.realm, info.name)
  if crest then frame.Picker.Icon:SetAtlas(crest, false) end
  -- The Mail tab's rule: a picker while there is another box with mail to
  -- show (the list it opens holds only those), or while one is on screen.
  local others = MM.HasOthers(characters) or v ~= nil
  frame.Picker:SetShown(others)
  frame.Search.Place(others)
  T.SetPlateSelected(frame.Picker, v ~= nil)

  -- The foot: when the box was seen, or what a search found.
  local text = MM.SeenText(info.snapshot)
  if (info.hidden or 0) > 0 then text = text .. "  " .. string.format(L["MEMORY_MORE"], info.hidden) end
  if info.matched then
    text = ns.Plural("MEMORY_MATCHES", info.matched)
    if (info.onCharacters or 0) > 1 then
      text = text .. "  " .. ns.Plural("MEMORY_ON_CHARACTERS", info.onCharacters)
    end
  end
  frame.Status:SetText(text)

  frame.Card:SetShown(count > 0)
  if count > 0 and not frame.Rows[1] then frame.Rows[1] = MM.NewRow(frame.ListChild) end
  frame._list = rows
  frame._now = now
  frame._cols = (count > 0) and MM.MeasureRows(frame, rows, now, frame.Rows[1]) or nil
  frame.ListChild:SetHeight(math.max(1, count * ROW_HEIGHT))
  -- The scroll frame re-reads its child the moment the child's height is
  -- set, as the Mail tab's list does, and the offset stays inside the list.
  local scroll = frame.Scroll
  if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end
  local most = math.max(0, count * ROW_HEIGHT - (scroll:GetHeight() or 0))
  if (scroll:GetVerticalScroll() or 0) > most then scroll:SetVerticalScroll(most) end
  BindRows(frame)

  -- Height: six rows by default, the user's own height once they have
  -- dragged the grip, and never taller than the content or shorter than six
  -- rows. Width: the user's, between the window's narrowest and widest.
  local contentRows = math.max(count, 1)
  local minH = RowsHeight(math.min(MIN_ROWS, contentRows))
  local maxH = RowsHeight(contentRows)
  frame:SetResizeBounds(WINDOW_WIDTH, minH, WINDOW_MAX_WIDTH, math.max(maxH, minH))
  -- Mid-drag the grip owns the size: a refresh the drag itself caused (the
  -- rows re-fill as the width changes) must not pull the window back.
  if frame.sizing then return end
  local wanted = frame.userHeight or RowsHeight(math.min(DEFAULT_ROWS, contentRows))
  if wanted < minH then wanted = minH end
  if wanted > maxH then wanted = maxH end
  local width = math.max(WINDOW_WIDTH, math.min(WINDOW_MAX_WIDTH, frame:GetWidth() or WINDOW_WIDTH))
  frame:SetSize(width, wanted)
end

-- The arrange mode over this window (Core/Arrange.lua): the strip stands
-- where the card's top was and the card steps down under it; the top row
-- stays, so another box can still be picked to see the arrangement on it.
-- The window widens, if it must, until every chip says its name whole, and
-- goes back to the width it had.
function MM.ArrangeHost(frame)
  if not (frame and frame.Card) then return nil end
  if frame._arrangeHost then return frame._arrangeHost end
  local host = { owner = frame }
  function host.PlaceStrip(strip)
    strip:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -CHROME_TOP)
    strip:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
  end
  function host.OnEnter(strip)
    MM.ClosePicker()
    frame.Card:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, -6)
    local arrange = ns.Arrange
    local need = (arrange and arrange.StripNeed and arrange.StripNeed(host) or 0) + 20
    local width = frame:GetWidth() or WINDOW_WIDTH
    if need > width then
      frame._widthBeforeArrange = width
      frame:SetWidth(math.min(WINDOW_MAX_WIDTH, math.ceil(need)))
      frame._widthForArrange = frame:GetWidth()
    end
  end
  function host.OnLeave()
    frame.Card:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -CHROME_TOP)
    -- Back to the player's width, unless they chose another meanwhile.
    local before = frame._widthBeforeArrange
    frame._widthBeforeArrange = nil
    if before and math.abs((frame:GetWidth() or 0) - (frame._widthForArrange or 0)) < 0.5 then
      frame:SetWidth(before)
    end
  end
  frame._arrangeHost = host
  return host
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

  -- The foot: when the box was seen, left-aligned, stopping short of the grip.
  -- Truncates with an ellipsis; the whole line is the tooltip when it did.
  frame.Status = ns.Theme.CreateText(frame, "secondary")
  frame.Status:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, 8)
  frame.Status:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -26, 8)
  frame.Status:SetJustifyH("LEFT")
  frame.Status:SetWordWrap(false)
  frame.StatusHit = CreateFrame("Frame", nil, frame)
  frame.StatusHit:SetAllPoints(frame.Status)
  HoverOnly(frame.StatusHit)
  frame.StatusHit:SetScript("OnEnter", function(self)
    if not (frame.Status.IsTruncated and frame.Status:IsTruncated()) then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(frame.Status:GetText(), 1, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.StatusHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

  BuildSearch(frame)
  BuildHeader(frame)

  local card = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  card:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -CHROME_TOP)
  card:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, CHROME_BOTTOM)
  ns.Theme.ApplyList(card)
  frame.Card = card

  -- The rows run to the card's edge while nothing scrolls, and stop short of
  -- the bar only while it is there (Theme's slim bar calls this).
  local gutter = ns.Theme.Metrics.scrollGutter or 16
  frame.Scroll = CreateFrame("ScrollFrame", nil, card, "UIPanelScrollFrameTemplate")
  frame.Scroll:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -1)
  frame.Scroll:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -gutter, 1)
  frame.Scroll.scrollBarHideable = 1
  -- As the Mail tab's list: rows end at the card's edge.
  if frame.Scroll.SetClipsChildren then frame.Scroll:SetClipsChildren(true) end
  frame.Scroll.__pbGutter = function(scrolling)
    frame.Scroll:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -(scrolling and gutter or 1), 1)
  end
  ns.Theme.SlimScrollBar(frame.Scroll, card, 1)

  -- The rows are the scroll frame's full width: the child follows it.
  frame.ListChild = CreateFrame("Frame", nil, frame.Scroll)
  frame.ListChild:SetWidth(WINDOW_WIDTH - 20 - 2 - gutter)
  frame.Scroll:SetScrollChild(frame.ListChild)
  -- A size change re-binds the rows (never a rebuild from inside the
  -- resize): the width reaches the rows through the child, and the offset
  -- stays inside the list.
  frame.Scroll:HookScript("OnSizeChanged", function(self, width, height)
    if width and width > 10 and math.abs((frame.ListChild:GetWidth() or 0) - width) > 0.5 then
      frame.ListChild:SetWidth(width)
    end
    local most = math.max(0, (frame.ListChild:GetHeight() or 0) - (height or self:GetHeight() or 0))
    if (self:GetVerticalScroll() or 0) > most then self:SetVerticalScroll(most) end
    if frame:IsShown() then BindRows(frame) end
  end)
  frame.Scroll:HookScript("OnVerticalScroll", function() BindRows(frame) end)

  frame.Rows = {}
  -- A click on a character's heading, among every box's matches.
  frame._onHeader = function(realm, name) OnHeader(frame, realm, name) end

  -- The grip changes both: once the user has chosen a size it is theirs for
  -- the session; Refresh keeps honouring it within the content's bounds.
  -- Right-click resets it, as the Postbox window's grip does: the default
  -- width and six rows (or the content, if less).
  local grip = ns.Core.UI.Helpers.CreateResizeButton(frame, function(self)
    self.sizing = false
    self.userHeight = self:GetHeight()
  end, function(self)
    self.sizing = true
  end, nil, function(self)
    self.sizing = false
    self.userHeight = nil
    self.Scroll:SetVerticalScroll(0)
    self:SetWidth(WINDOW_WIDTH)
    Refresh(self)
    -- Once more after the layout has settled at the new size.
    C_Timer.After(0, function()
      if self:IsShown() then Refresh(self) end
    end)
  end)
  if grip then
    grip:HookScript("OnEnter", function(self)
      ns.Theme.ShowHint(self, { L["GRIP_TIP_DRAG"], L["GRIP_TIP_RESET"] })
    end)
    grip:HookScript("OnLeave", function() ns.Theme.HideHint() end)
    grip:HookScript("OnMouseDown", function() ns.Theme.HideHint() end)
  end
  frame:HookScript("OnHide", function()
    MM.ClosePicker()
    -- The arrange mode ends with the window it was opened in.
    if ns.Arrange and ns.Arrange.LeaveIf then ns.Arrange.LeaveIf(frame) end
  end)

  -- Same expression as the options panel and the recipient manager: let an
  -- active host-UI skin restyle the shell, whichever entry point it offers.
  local applyWindow = ns.Skin and (ns.Skin.ApplyWindow or ns.Skin.Apply)
  if applyWindow then applyWindow(frame) end

  -- The arrange grip, where the Postbox window has its cog and its own grip:
  -- the rows here are the Mail tab's rows, and arranging them is as close as
  -- the window. After the skin, so it stands in the bar the skin drew.
  local arrange = ns.Arrange
  if arrange and arrange.BuildToggle then
    frame.ArrangeButton = arrange.BuildToggle(frame, function(button)
      -- Postbox Modern centres its bar's children on the strip it draws;
      -- the other looks keep the template's bar, where the cog's own
      -- offsets are right.
      local strip = frame.__pbModernStrip
      if strip then
        button:SetPoint("LEFT", strip, "LEFT", 5, 0)
      else
        local hostBar = (ns.Skin and (_G.EllesmereUI or _G.ElvUI)) and true or false
        button:SetPoint("TOPLEFT", frame, "TOPLEFT", 5, hostBar and -4 or -2)
      end
    end, function() return MM.ArrangeHost(frame) end)
  end

  MM._frame = frame
  return frame
end

-------------------------------------------------------------
-- 4. Public API
-------------------------------------------------------------

-- The options panel's row switches: repaint the window if it is showing. A
-- hidden window is filled fresh on its next open anyway.
function MM.Refresh()
  local frame = MM._frame
  if frame and frame:IsShown() then Refresh(frame) end
end

-- The rows on screen bound again where they stand, without re-reading the
-- box: the arrange mode's pointer moved (Core/Arrange.lua).
function MM.Rebind()
  local frame = MM._frame
  if frame and frame:IsShown() and frame._list then BindRows(frame) end
end

-- Every way in -- the minimap icon, the addon compartment, /postbox mail --
-- comes here, and all of them do the same thing. Away from a mailbox: this
-- window, on the character being played, beside the minimap. At a mailbox
-- the Postbox window already shows the other characters (its Mail tab's
-- character picker), so that is what opens. And with Mail Memory switched
-- off, a line saying where to switch it on, rather than a dead click.
function MM.Toggle()
  if not MemoryEnabled() then
    ns.Print(L["MEMORY_OFF"])
    return
  end
  local state = MailboxState()
  if state and state.mailboxOpen then
    -- The press of this very click just closed the character list (its
    -- click-away): that was the toggle, and it is done.
    local picker = MM._picker
    local now = type(GetTime) == "function" and GetTime() or nil
    if picker and picker.closedAt and now and now - picker.closedAt < 0.5 then
      picker.closedAt = nil
      return
    end
    local UI = ns.MailboxUI
    if UI and type(UI.ShowCharacterPicker) == "function" then UI.ShowCharacterPicker() end
    return
  end

  local frame = Build()
  if frame:IsShown() then
    frame:Hide()
    return
  end

  -- Every open starts on the character being played, unsearched.
  frame.viewing = nil
  frame.searchAll = false
  if frame.SearchAllButton then frame.SearchAllButton.Paint() end
  if frame.SearchBox then frame.SearchBox:SetText("") end
  frame.Scroll:SetVerticalScroll(0)
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
  local now = time()
  for i = 1, #mails do
    local mail = mails[i]
    -- The Collect tab's rule, so the two counts agree: a mail waits while it
    -- holds anything, or has not been read -- until its date.
    if Holds(mail, now) then
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

  -- By all three detectors, as Mail Memory's rows are (ArrivedSince).
  local arrived, newFrom = ArrivedSince(snap)

  return {
    groups      = GroupsFor(false),
    stuckGroups = GroupsFor(true),
    waiting     = waiting,
    stuck       = stuck,
    total       = #mails,
    seenAt      = snap.seenAt,
    arrived     = arrived,
    newFrom     = arrived and newFrom or nil,
    pending     = MM.PendingSummary and MM.PendingSummary() or nil,
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
  lastPendingVerdict = "at mailbox"
  local state = MailboxState()
  if state and state.mailboxOpen then return end
  lastPendingVerdict = "login settle"
  if not loginAt or (time() - loginAt) < LOGIN_SETTLE then return end
  lastPendingVerdict = "close settle"
  if (time() - closedAt) < CLOSE_SETTLE then return end
  lastPendingVerdict = "flag false"
  if not (type(HasNewMail) == "function" and HasNewMail()) then return end

  -- An arrival. The minimap icon's sound and flash answer it whether or not
  -- Mail Memory is on to record it: they are alerts, not memory.
  local Icon = ns.MinimapButton
  if Icon and type(Icon.NotifyArrival) == "function" then Icon.NotifyArrival() end

  lastPendingVerdict = "memory off"
  if not MemoryEnabled() then return end

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
end

-- The fourth detector watches the CAUSE instead of the effect. The server
-- sends no new-mail push while the mail flag is already up, so an auction
-- purchase on top of existing unread mail -- the single most common arrival
-- -- can be completely silent on the mail side. But the purchase itself is
-- loudly announced to the buyer, and a completed purchase IS mail in
-- transit. Witnessed cause, honest badge.
local function OnPurchaseCompleted()
  -- The alert first: it does not depend on the memory.
  local Icon = ns.MinimapButton
  if Icon and type(Icon.NotifyArrival) == "function" then Icon.NotifyArrival() end
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
    CharactersChanged()
  end)
  registered.auctionExpired = bus.Register("AUCTION_HOUSE_AUCTIONS_EXPIRED", function()
    NoteArrival(Me())
  end)

  -- The auction house's own notices -- sold, expired, won -- name the item,
  -- and reach the client wherever the player is. Each is mail on its way, and
  -- the memory's new-mail rows say what (section 3b).
  local function NotePending(kind, item, count)
    if not MemoryEnabled() or not kind or type(item) ~= "string" or item == "" then return end
    local realm, name = Me()
    local watch = WatchFor(realm, name, true)
    if not watch then return end
    watch.pending = type(watch.pending) == "table" and watch.pending or {}
    if #watch.pending >= 30 then table.remove(watch.pending, 1) end
    watch.pending[#watch.pending + 1] = { k = kind, item = item, n = tonumber(count), t = time() }
    CharactersChanged()
    NoteArrival(realm, name)
    local snap = StoredSnapshot()
    if snap then snap.newSince = true end
    local frame = MM._frame
    if frame and frame:IsShown() then Refresh(frame) end
  end
  registered.ahNotice = bus.Register("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", function(_, notification, item)
    local E = type(Enum) == "table" and Enum.AuctionHouseNotification or nil
    if not E then return end
    local kind
    if notification == E.AuctionSold then
      kind = "sold"
    elseif notification == E.AuctionExpired then
      kind = "expired"
    elseif notification == E.AuctionWon then
      kind = "bought"
    end
    NotePending(kind, item)
  end)
  registered.commodityWon = bus.Register("AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION", function(_, item, quantity)
    NotePending("bought", item, quantity)
  end)
  registered.login = bus.Register("PLAYER_ENTERING_WORLD", function(_, isInitialLogin)
    loginAt = time()
    if MemoryEnabled() then EnsureBaseline(StoredSnapshot()) end
    if not isInitialLogin then return end
    -- History is kept whether or not Mail Memory is on; so is its pruning.
    pcall(PruneAllHistory)
    -- Once the client has settled its mail state: mail that arrived while
    -- logged out raised the unread flag that was down at the last close.
    -- Then, once per login, the one line about the other characters.
    C_Timer.After(LOGIN_SETTLE + 5, function()
      if not MemoryEnabled() then return end
      local snap = StoredSnapshot()
      local flag = type(HasNewMail) == "function" and HasNewMail() and true or false
      if flag and (not snap or snap.baseNew == false) then
        -- It landed some time since the last visit: dated from that visit,
        -- the earliest it could have, so a warning never comes late.
        local realm, name = Me()
        NoteArrival(realm, name, snap and snap.seenAt)
      end

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
