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
-- Beside it, for text built while an item's name was not loaded yet: the
-- names fill it was built at (Helpers.SearchNamesFilled).
local searchMissed = setmetatable({}, { __mode = "k" })

-- One mail's items as the capture's slot scan reads them, id and count in
-- turn, before they are copied into that mail's own list (`it`). One table
-- for every mail of every capture.
local scanned = {}
-- Lists of items a capture let go -- a table of this visit's look now holds
-- a mail with none -- emptied and kept for the next that has some. A collect
-- run moves every mail's index as it empties them, so the tables' mails
-- change from one look to the next, and a list made for each change was
-- garbage at every inbox update. Never more than a look holds.
local spareLists = {}

-- MM.Characters is memoised (section 2b); this generation says its list is
-- stale. Everything in this file that writes what the list reads -- a
-- snapshot saved, an arrival or auction noted, a watch settled, a character
-- hidden or shown -- calls CharactersChanged. Nothing outside the file
-- writes mailMemory, mailWatch or hiddenChars, but for the options' Reset
-- everything, which empties them and says so (MM.DataCleared).
local charactersGen = 0
local function CharactersChanged()
  charactersGen = charactersGen + 1
  -- The minimap icon reads the list too (Core/MinimapButton.lua, 1b); it
  -- asks again once this write has settled, and only if it reads it at all.
  local Icon = ns.MinimapButton
  if Icon and Icon.MemoryChanged then Icon.MemoryChanged() end
end

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
  local perfAt = perf and perf.cur and perf.Begin and perf.Begin()

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
      -- What the mail holds, from one scan of its slots. The first item is
      -- the one the Mail tab's row shows (Mail.GetMailIcon): its own icon --
      -- the header's package icon is a generic crate for a mail of several
      -- items -- its link, when the client has it, which buys the row the
      -- item's real tooltip, and its count for the row's icon (nil for 1,
      -- as the row writes nothing for it). Then every item's id and count,
      -- in slot order, for what the icon's hover lists (section 3): numbers,
      -- not links, so a mail of sixteen stacks costs thirty-two of them.
      -- The scan stops at the header's count of items: a mail of one item
      -- in its first slot costs one read, as it did before the list.
      local itemIcon, link, stack
      local held, found = 0, 0
      local attached = tonumber(itemCount) or 0
      if attached > 0 and type(GetInboxItem) == "function" then
        for slot = 1, (ns.MailService and ns.MailService.MAX_ATTACHMENTS) or 16 do
          local _, itemID, texture, n = GetInboxItem(index, slot)
          if texture then
            n = tonumber(n) or 1
            if not itemIcon then
              itemIcon = texture
              if n > 1 then stack = n end
              if type(GetInboxItemLink) == "function" then link = GetInboxItemLink(index, slot) end
            end
            itemID = tonumber(itemID)
            if itemID then
              scanned[held + 1], scanned[held + 2] = itemID, n
              held = held + 2
            end
            found = found + 1
            if found >= attached then break end
          end
        end
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
      -- What the server does with it when it expires (MailService's
      -- ExpiryFate), for the rows' expiry mark: true, it goes back to its
      -- sender; false, it is deleted; nil where the client cannot say, as
      -- every record saved before this was asked, which then shows no mark.
      local back
      if service and type(service.ExpiryFate) == "function" then
        local fate = service.ExpiryFate(index)
        if fate then back = (fate == "back") end
      end

      sender, subject = tostring(sender or ""), tostring(subject or "")
      count = count + 1
      local mail = mails[count]
      if not mail then
        -- Sized for all its fields at once; each is set just below.
        mail = { stuck = false, icon = false, sender = "", subject = "", money = 0, cod = 0, items = 0,
          read = false, link = false, kind = false, paid = false, expires = 0, count = false, it = false,
          back = false }
        mails[count] = mail
      elseif mail.sender ~= sender or mail.subject ~= subject or mail.kind ~= kind then
        -- Another mail in this slot now: the text a search folded is not its.
        searchText[mail] = nil
      end
      -- The items, into the list this slot's mail kept from the last look;
      -- none is no list at all, so a letter or gold alone saves nothing.
      local list = mail.it
      if held > 0 then
        if type(list) ~= "table" then
          list = spareLists[#spareLists] or {}
          spareLists[#spareLists] = nil
          mail.it = list
          -- Items the text a search folded did not have: it names them now.
          searchText[mail] = nil
        elseif #list ~= held then
          searchText[mail] = nil
        end
        for k = 1, held do
          if list[k] ~= scanned[k] then
            -- Another item in a slot (an odd place; the even ones are
            -- counts): the search's text may not name it.
            if k % 2 == 1 then searchText[mail] = nil end
            list[k] = scanned[k]
          end
        end
        for k = #list, held + 1, -1 do list[k] = nil end
      else
        if type(list) == "table" then searchText[mail] = nil end
        if type(list) == "table" and #spareLists < MAX_MAILS then
          for k = #list, 1, -1 do list[k] = nil end
          spareLists[#spareLists + 1] = list
        end
        mail.it = nil
      end
      mail.stuck   = stuck
      mail.icon    = itemIcon or packageIcon or stationeryIcon
      mail.sender  = sender
      mail.subject = subject
      mail.money   = tonumber(money) or 0
      mail.cod     = tonumber(cod) or 0
      mail.items   = tonumber(itemCount) or 0
      mail.read    = wasRead and true or false
      mail.link    = link
      mail.count   = stack
      mail.kind    = kind
      mail.paid    = paid
      mail.back    = back
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

-- -> hasNew, a, b, c, sendersKnown: the client's unread-mail indicators,
-- read the one way every caller here reads them. The minimap tooltip asks
-- for these anywhere, combat included, and a restricted context may hand
-- insecure code a secret value, which throws the moment it is tested,
-- compared or concatenated. So each read is protected and a secret counts
-- as unknown: hasNew is true/false, or nil when the flag cannot be read;
-- the senders are plain values, or all nil with sendersKnown false when
-- any of them cannot be (a partial line would compare as a change).
local function Plain(v)
  if type(issecretvalue) == "function" and issecretvalue(v) then return nil, false end
  return v, true
end

function MM.ReadMailFlags()
  local hasNew
  if type(HasNewMail) == "function" then
    local ok, flag = pcall(HasNewMail)
    local plain
    if ok then flag, plain = Plain(flag) end
    if ok and plain then hasNew = flag and true or false end
  end
  if type(GetLatestThreeSenders) ~= "function" then return hasNew, nil, nil, nil, false end
  local ok, a, b, c = pcall(GetLatestThreeSenders)
  if not ok then return hasNew, nil, nil, nil, false end
  local pa, pb, pc
  a, pa = Plain(a)
  b, pb = Plain(b)
  c, pc = Plain(c)
  if not (pa and pb and pc) then return hasNew, nil, nil, nil, false end
  return hasNew, a, b, c, true
end

-- The senders of the latest unread mails, as one comparable string. This is
-- the arrival detector that needs no event: any mail landing -- even while
-- logged out -- reshuffles this triple, and the snapshot remembers what it
-- was at close. nil when the line cannot be read.
local function SenderTriple()
  local _, a, b, c, known = MM.ReadMailFlags()
  if not known then return nil end
  if a == nil and b == nil and c == nil then return "" end
  return tostring(a) .. "\001" .. tostring(b) .. "\001" .. tostring(c)
end

-- The latest senders as a list for the badge's "from", or nil.
local function SendersList()
  local _, a, b, c = MM.ReadMailFlags()
  if a == nil and b == nil and c == nil then return nil end
  local from = {}
  if a then from[#from + 1] = tostring(a) end
  if b then from[#from + 1] = tostring(b) end
  if c then from[#from + 1] = tostring(c) end
  return from
end

local function PersistOnClose()
  if not live then return end
  local snapshot = live
  live = nil

  -- The arrival baseline, taken at the boundary the badge measures from:
  -- what the client's unread indicators said the moment the box closed.
  -- Either can be unknown (nil) where the client will not say; each
  -- detector below stands down on an unknown baseline rather than guess.
  snapshot.baseNew = (MM.ReadMailFlags())
  snapshot.baseFrom = SenderTriple()

  -- Forever: the ruleset and the full name (Helpers.PlayerRealm/PlayerName).
  local realm = ns.Helpers.PlayerRealm()
  local name = ns.Helpers.PlayerName()
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
  local realm = ns.Helpers.PlayerRealm()
  local name = ns.Helpers.PlayerName()
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
-- As History writes its short form ("3d ago": CollectTab's HistoryAge, its
-- strings kept there), and "just now" under a minute. Time REMAINING is
-- the Mail tab's own (Helpers.TimeLeft).
-------------------------------------------------------------

local function AgeText(seenAt)
  local age = math.max(0, time() - (tonumber(seenAt) or 0))
  local collect = ns.CollectTab
  if age < 60 or not (collect and collect.HistoryAge) then return L["MEMORY_AGO_NOW"] end
  return collect.HistoryAge(age, "short")
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
  return ns.Helpers.TimeLeft(left / 86400), false
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
--   uncountedAt    the last time mail arrived that no notice named: the
--                  unread flag up at login, an arrival or expiry event with
--                  no auction house notice to go with it, a purchase, mail
--                  Postbox sent from another character. The count says
--                  "new" or "N+" while it stands (MM.CountText): how many
--                  came is not known, only that some did. An auction
--                  posted since the visit says the same once it has
--                  surely ended (Uncounted): every ending sends mail.
--
-- Mail lives thirty days. Either time is therefore the earliest that unseen
-- mail could start to be lost, and a character is flagged a week before it.
-- A character whose snapshot holds mail under three days from expiring (one
-- for C.O.D., as the rows turn amber) is flagged too. That is the whole of it: nothing is guessed, and a character
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

-- realm, name: exactly two values (UnitName's realm, or Forever's surname,
-- never rides along as a third).
local function Me()
  return ns.Helpers.PlayerRealm(), ns.Helpers.PlayerName()
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
-- all that is known is "since the last visit"). `uncounted`: nothing named
-- it, so the count cannot include it (uncountedAt).
local function NoteArrival(realm, name, at, uncounted)
  if not MemoryEnabled() then return end
  local watch = WatchFor(realm, name, true)
  if not watch then return end
  local changed = false
  if not watch.newAt then
    watch.newAt = tonumber(at) or time()
    changed = true
  end
  if uncounted then
    watch.uncountedAt = time()
    changed = true
  end
  if changed then CharactersChanged() end
end

-- An arrival on the character being played that says neither what nor how
-- many: the client's pending-mail event, the auctions-expired event, a
-- purchase. The auction house names its own outcomes in a notice
-- (NotePending, section 5), and the same mail raises both, in either order
-- and some seconds apart -- the notice up to an hour before the mail, which
-- lands within the hour. So the arrival is counted already when a notice
-- came in the hour before it, or comes in the seconds after; only when
-- neither did is it an uncounted one. One timer for an event the client
-- sends a handful of times an hour at most.
do
  local NOTICE_LANDS, NOTICE_PAIR = 3600, 10

  local function NoticeSince(watch, from)
    local pending = watch and type(watch.pending) == "table" and watch.pending or nil
    local last = pending and pending[#pending]
    return last ~= nil and (tonumber(last.t) or 0) >= from
  end

  function MM._NoteSignal()
    if not MemoryEnabled() then return end
    local realm, name = Me()
    NoteArrival(realm, name)
    local at = time()
    if NoticeSince(WatchFor(realm, name, false), at - NOTICE_LANDS) then return end
    C_Timer.After(NOTICE_PAIR, function()
      local watch = WatchFor(realm, name, false)
      if not watch or NoticeSince(watch, at - NOTICE_LANDS) then return end
      -- A visit since then holds the mail in its record.
      local snap = SnapshotFor(realm, name)
      if snap and (tonumber(snap.seenAt) or 0) >= at then return end
      NoteArrival(realm, name, nil, true)
    end)
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
  -- What the notifications said had arrived is in the snapshot now, and so
  -- is what nothing named.
  watch.pending = nil
  watch.uncountedAt = nil
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

-- The warnings' rule, in one place: Warn about (MailboxUI.GetMemoryWarn)
-- drives both warnings, the line in chat at login and the minimap marker,
-- and both read it here (MM.Warns). Three decisions, each a line below:
--   * Which mail counts: only mail holding gold or items, or a C.O.D.
--     (Counts). An unread letter that holds nothing is still waiting (Holds)
--     and still amber in the rows, but it is not worth a warning.
--   * Which characters count: every character Mail Memory knows, the one
--     being played included; only the hidden are left out (MM.Warns).
--   * What each choice warns of: "deleted", mail the server deletes when
--     its time runs out (`gone`, the bin), or whose fate the record cannot
--     say (saved before 1.60); "any", that and mail going back
--     to its sender (the arrow) or long unopened on its way (`warn`); "off",
--     nothing.
local function Counts(mail)
  return (mail.items or 0) > 0 or (mail.money or 0) > 0 or (mail.cod or 0) > 0
end

-- watch, seenAt, now -> whether mail nothing named has come since the last
-- visit (uncountedAt), while it can still be there.
local function Uncounted(watch, seenAt, now)
  if not watch then return false end
  local at = tonumber(watch.uncountedAt)
  if at ~= nil and now - at < MAIL_LIFE then return true end
  -- An auction posted since the last visit has ended by 48 hours on, and
  -- every ending, sold, expired or canceled, sends mail. Only one posted
  -- AFTER the visit: one carried over a visit (auctionAt is then the
  -- visit, _SettleWatch) may have sold and been collected already.
  local posted = tonumber(watch.auctionAt)
  return (posted ~= nil and posted > (tonumber(seenAt) or 0)
    and now - posted >= AUCTION_LONGEST and now - posted < UNSEEN_STOP) and true or false
end

-- realm, name, now -> what there is to say about that character's mail.
--   waiting    mails in its snapshot still waiting
--   pending    the mail the auction house's notices named since, and `sent`
--   sent       the mail Postbox sent it from another character since
--              (MM.SentSince; never on the character being played)
--   uncounted  mail came since that nothing named (Uncounted): the count
--              is waiting + pending and more (MM.CountText)
--   soon       how many of them are short (three days, one for C.O.D.) and
--              worth a warning (Counts), and `soonest`
--   held       when the first of its waiting mail holding something
--              (Counts) expires, short or not; nil where none does (the
--              character list's Expiring soonest, MM.CharactersInOrder)
--   unseenDays set when mail known to be on the way has gone unopened
--              long enough to be a week from its earliest loss
local function Status(realm, name, now)
  local snap = SnapshotFor(realm, name)
  -- Every field it will carry, here and in MM.Characters, named at once so
  -- the table is sized once rather than grown twice; the ones left nil are
  -- set below, or there, when they apply.
  local st = { realm = realm, name = name, waiting = 0, seenAt = snap and snap.seenAt or nil,
    soon = nil, soonest = nil, held = nil, pending = 0, sent = 0, uncounted = false, unseenDays = nil, warn = false,
    gone = nil, goneSoonest = nil, goneText = nil,
    me = nil, hidden = nil, label = nil, text = nil }
  local mails = snap and snap.mails or {}
  -- Soon by the rows' own rule (the Mail tab's RV.ShortDays, its amber):
  -- under three days, or one for a C.O.D. mail, which only lives three.
  -- Mail that goes back to its sender counts as well; a letter holding
  -- nothing does not (Counts).
  local CT = ns.CollectTab
  local shortDays = CT and CT.RowRules and CT.RowRules.ShortDays
  for i = 1, #mails do
    local mail = mails[i]
    if Holds(mail, now) then
      st.waiting = st.waiting + 1
      local left = (tonumber(mail.expires) or 0) - now
      local cod = (tonumber(mail.cod) or 0) > 0
      local soon = shortDays and shortDays(cod) * DAY or (cod and DAY or SOON)
      local counts = Counts(mail)
      if left > 0 and counts and (not st.held or mail.expires < st.held) then st.held = mail.expires end
      if left > 0 and left < soon and counts then
        st.soon = (st.soon or 0) + 1
        if not st.soonest or mail.expires < st.soonest then st.soonest = mail.expires end
        -- Of those, the ones the server deletes rather than sends back,
        -- still holding gold or items (the bin, the rows' expiry mark): what
        -- Warn about's "Deleted" speaks of. A record that cannot
        -- say (`back` nil: every one saved before 1.60 asked) counts too,
        -- since it already holds something (Counts): a warning that turns
        -- out needless beats a silent loss. Only the warning reads it so;
        -- the rows and the summary card show no mark for an unknown fate.
        local back = mail.back
        if back == nil or (back == false and ((mail.money or 0) > 0 or (mail.items or 0) > 0)) then
          st.gone = (st.gone or 0) + 1
          if not st.goneSoonest or mail.expires < st.goneSoonest then st.goneSoonest = mail.expires end
        end
      end
    end
  end
  local watch = WatchFor(realm, name, false)
  st.pending = LivePendingCount(watch, now)
  -- And the mail Postbox sent it from another of the player's characters
  -- since its last visit (MM.SentSince), counted with the mail known to
  -- be on its way. Never the character being played: its own box knows.
  local myRealm, myName = Me()
  if not (realm == myRealm and name == myName) and MM.SentSince then
    st.sent = MM.SentSince(realm, name, st.seenAt, now)
    st.pending = st.pending + st.sent
  end
  if watch then
    st.uncounted = Uncounted(watch, st.seenAt, now)
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
    -- Counted from the last visit where there was one ("mailbox last opened
    -- 24 days ago"), otherwise from the first mail known to be on its way
    -- ("mail waiting 24 days").
    local unseen = ns.Plural(st.seenAt and "OVERVIEW_UNSEEN" or "OVERVIEW_UNVISITED", st.unseenDays)
    text = text and (text .. "; " .. unseen) or unseen
  end
  return text
end

-- A character's count as every list says it. `n` is what is counted (the
-- snapshot's mail waiting and what the notices named); `uncounted`, that
-- more came which nothing named (Status). Then it is "N+", or "new" where
-- nothing was counted: never a bare 0 beside mail known to be there.
-- CountText is the bare number (the minimap tooltip, the Mail tab's
-- plate); MailsText says "mails" with it (the character list).
function MM.CountText(n, uncounted)
  n = tonumber(n) or 0
  if not uncounted then return tostring(n) end
  if n <= 0 then return L["OVERVIEW_COUNT_NEW"] end
  return string.format(L["OVERVIEW_COUNT_MORE"], n)
end

function MM.MailsText(n, uncounted)
  n = tonumber(n) or 0
  if not uncounted then return ns.Plural("COUNT_MAILS", n) end
  if n <= 0 then return L["OVERVIEW_MAILS_NEW"] end
  return ns.Plural("OVERVIEW_MAILS_MORE", n)
end

-- The last seven days by mail, for the options' General tab: `who` "me"
-- (the character being played) or "all" (every character with a record,
-- a hidden one left out as the lists of every box leave it out). Read from
-- History (2c: `m` gold taken, `c` C.O.D. paid, `p` a won auction's price,
-- `dp` and `ct` a sale's deposit and the auction house's cut, one entry a
-- mail collected), Sent (2d: `m` gold sent, one entry a mail sent) and the
-- deposits paid (2f: hour, copper pairs):
--   earned     copper taken from mail: sales + other
--     sales      from sold auctions' mail, the deposits returned in it
--       depBack    of which deposits returned (sales whose invoice was read)
--     other      from every other mail
--     cut        the auction house's cut of those sales, never in a mail
--     unopened   sales taken without their invoice: deposit and cut unknown
--   spent      copper out for mail and auctions: bought + cod + gold + depPaid
--     bought     won auctions' prices    cod      C.O.D. paid
--     gold       gold sent               depPaid  deposits paid on posts
--   collected  mails in History gold or items were taken from (`m`, `it`,
--              or `c`), not letters only read; sent  mails in Sent
--   chars      the characters counted under "all": this one and every other
--              with a record, the hidden left out (asked of either scope)
--   partial    the week reaches back past a counted character's first run of
--              the deposits' record: its deposits and cut start there
--   walked     the entries read, for a cost check
-- Each record is oldest first, so it is read from its newest end back to
-- the first entry older than the week and no further: one walk per
-- character and record, nothing pruned, written or built. The answer is
-- one table, filled again on each call; the caller says when to ask
-- (OptionsPanel's Week: on General's show, MM.recordWrites, the switch).
do
  local WEEK = { earned = 0, spent = 0, collected = 0, sent = 0, walked = 0,
    sales = 0, depBack = 0, other = 0, cut = 0, unopened = 0,
    bought = 0, cod = 0, gold = 0, depPaid = 0, chars = 0, partial = false }
  local HOUR = 3600
  local KEYS = { "mailHistory", "mailSent", "auctionDeposits" }
  local roots = {}

  -- A History or Sent list: whether any of it was in the week.
  local function WeekWalk(list, cutoff, sent)
    local w = WEEK
    local any = false
    for i = #list, 1, -1 do
      local e = list[i]
      w.walked = w.walked + 1
      local t = type(e) == "table" and tonumber(e.t) or nil
      if not t or t < cutoff then return any end
      any = true
      if sent then
        w.gold = w.gold + (tonumber(e.m) or 0)
        w.sent = w.sent + 1
      else
        local m, c = tonumber(e.m) or 0, tonumber(e.c) or 0
        w.cod = w.cod + c
        w.bought = w.bought + (tonumber(e.p) or 0)
        if e.k == "sold" then
          w.sales = w.sales + m
          -- An invoice read has `dp` or `ct`, `ct = 0` where it held
          -- neither; a sale with neither was never read.
          local dp, ct = tonumber(e.dp), tonumber(e.ct)
          if dp or ct then
            w.depBack, w.cut = w.depBack + (dp or 0), w.cut + (ct or 0)
          elseif m > 0 then
            w.unopened = w.unopened + 1
          end
        else
          w.other = w.other + m
        end
        -- Collected: a mail gold or items were taken from (a C.O.D. paid
        -- gave its items); a letter only read is in History, not here.
        if m > 0 or c > 0 or (type(e.it) == "table" and e.it[1] ~= nil) then
          w.collected = w.collected + 1
        end
      end
    end
    return any
  end

  -- A deposits record: hour, copper pairs, oldest first. The hour the week
  -- starts in is counted whole.
  local function DepositWalk(list, cutoffH)
    local w = WEEK
    for i = #list - 1, 1, -2 do
      w.walked = w.walked + 1
      local h = tonumber(list[i])
      if not h or h < cutoffH then return end
      w.depPaid = w.depPaid + (tonumber(list[i + 1]) or 0)
    end
  end

  local function ListOf(root, realm, name)
    local byRealm = root and root[realm]
    local list = type(byRealm) == "table" and byRealm[name] or nil
    return type(list) == "table" and list or nil
  end

  -- A record that holds something: an empty one (a deposits record begun,
  -- nothing paid) does not make its character one of "all".
  local function Holds(list)
    return type(list) == "table" and list[1] ~= nil
  end

  -- One character's three records, and whether its week reaches back past
  -- the start of its deposits' record.
  local function WeekCharacter(realm, name, cutoff)
    local hist, sent, deps = ListOf(roots[1], realm, name), ListOf(roots[2], realm, name), ListOf(roots[3], realm, name)
    local any = false
    if hist then any = WeekWalk(hist, cutoff, false) end
    if sent then any = WeekWalk(sent, cutoff, true) or any end
    if deps then DepositWalk(deps, math.floor(cutoff / HOUR)) end
    -- The record's start: the character's own (written before 1.70's
    -- release) or the account's, whichever is earlier.
    local since = deps and tonumber(deps.s) or nil
    local began = roots[3] and tonumber(roots[3].s) or nil
    if began and (not since or began < since) then since = began end
    if any and (not since or since > cutoff) then WEEK.partial = true end
  end

  function MM.Week(who)
    local w = WEEK
    w.earned, w.spent, w.collected, w.sent, w.walked = 0, 0, 0, 0, 0
    w.sales, w.depBack, w.other, w.cut, w.unopened = 0, 0, 0, 0, 0
    w.bought, w.cod, w.gold, w.depPaid, w.chars, w.partial = 0, 0, 0, 0, 1, false
    local myRealm, myName = Me()
    if not (myRealm and myName) then return w end
    local get = ns.Store and ns.Store.Get
    for k = 1, 3 do
      local root = get and get(KEYS[k])
      roots[k] = type(root) == "table" and root or false
    end
    local cutoff, all = time() - 7 * DAY, who == "all"
    WeekCharacter(myRealm, myName, cutoff)
    -- The others: counted once each, whichever record names them first,
    -- and added up only under "all".
    for k = 1, 3 do
      local root = roots[k]
      if root then
        for realm, byRealm in pairs(root) do
          if type(byRealm) == "table" then
            for name, list in pairs(byRealm) do
              if Holds(list) and not (realm == myRealm and name == myName)
                  and not (k > 1 and Holds(ListOf(roots[1], realm, name)))
                  and not (k > 2 and Holds(ListOf(roots[2], realm, name)))
                  and not MM.IsHidden(realm, name) then
                w.chars = w.chars + 1
                if all then WeekCharacter(realm, name, cutoff) end
              end
            end
          end
        end
      end
    end
    for k = 1, 3 do roots[k] = false end
    w.earned = w.sales + w.other
    w.spent = w.bought + w.cod + w.gold + w.depPaid
    return w
  end
end

-- st (one of MM.Characters) -> whether it has mail to show: counted, or
-- known to have come uncounted. What decides whether a list names it.
function MM.HasMail(st)
  return (st.waiting + (st.pending or 0)) > 0 or st.uncounted == true
end

-- A character's name as the lists show it: the realm only when it is not
-- `myRealm`, the one being played.
-- On Forever a full name says whose box it is on its own: no ruleset after
-- it, and the character being played as the player has chosen to see it
-- (Helpers.ShownName).
local function CharacterLabel(realm, name, myRealm)
  if ns.Helpers.TwoPartNames() then return ns.Helpers.ShownName(name) end
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
    if st.gone then st.goneText = ns.Plural("OVERVIEW_EXPIRE", st.gone, (ExpiryText(st.goneSoonest, now))) end
  end
  memo.list, memo.gen, memo.minute = list, charactersGen, minute
  memo.memory, memo.watches, memo.hiddenRoot = memory, watches, hiddenRoot
  memo.realm, memo.name = myRealm, myName
  return list
end

-- Whether `st` (one of MM.Characters) is warned of under `mode`, Warn
-- about's choice (MailboxUI.GetMemoryWarn): the one rule both warnings read
-- (see Counts, above). A hidden character says nothing: the player hid it,
-- most often an alt that was deleted or moved, and a warning about it could
-- only nag. The character being played counts like any other.
function MM.Warns(st, mode)
  if mode == "off" or st.hidden then return false end
  if mode == "deleted" then return st.gone ~= nil end
  return st.warn and true or false
end

-- The characters with something to say, for the login line, by MM.Warns.
-- Empty when memory is off. Under "deleted" a character's words are
-- `goneText`, otherwise `text`.
function MM.Warnings(mode)
  local out = {}
  if not MemoryEnabled() or mode == "off" then return out end
  local all = MM.Characters()
  for i = 1, #all do
    local st = all[i]
    if MM.Warns(st, mode) then out[#out + 1] = st end
  end
  return out
end

-- The options' summary (OptionsPanel, the General tab's "Mail waiting in
-- your mailboxes"): each character's box as it was last seen, added up. Only
-- what MM.Characters already reads, and one more walk of each box with mail
-- for what it does not keep: the gold waiting, and the soonest mail with its
-- fate. Read by the panel only while its General tab is shown, and made
-- again only when the list it is made from is (a write, the minute turning:
-- MM.Characters' own rule) or Mail Memory is switched; otherwise the same
-- tables come back untouched, and `gen` says when they changed. The row
-- tables are kept and refilled, never let go.
--
--   enabled   Mail Memory on
--   recorded  some character's box has been seen
--   n         the characters with mail waiting, the hidden left out: every
--             one of them is in the totals
--   listed    the rows filled, at most DASH_CAP of them: the mail short of
--             time first, the soonest of it first (so an alt not seen for
--             months whose mail is about to go back or be deleted is always
--             a line), then the most recently seen. Picked as the walk goes,
--             into a list never longer than the cap: hundreds of characters
--             are never sorted.
--   mails, gold, soonest, fate, amber   the totals over all n, and the
--             soonest mail of all (its expiry time, "back" / "gone" / nil,
--             short of time)
-- Each row: realm, name, mails, gold (copper), seenAt and the same three
-- for its own soonest mail.
local DASH_CAP = 20
local dash = { gen = 0, rows = {}, n = 0, listed = 0, from = false, enabled = false, recorded = false,
  mails = 0, gold = 0, soonest = nil, fate = nil, amber = false,
  -- The character being weighed, before it is known whether it is listed.
  cand = { realm = "", name = "", mails = 0, gold = 0, seenAt = 0, soonest = nil, fate = nil, amber = false } }

-- Whether `a` lists before `b`.
local function DashOrder(a, b)
  if a.amber ~= b.amber then return a.amber end
  if a.amber and a.soonest ~= b.soonest then return (a.soonest or 0) < (b.soonest or 0) end
  if a.seenAt ~= b.seenAt then return a.seenAt > b.seenAt end
  if a.name ~= b.name then return a.name < b.name end
  return a.realm < b.realm
end

-- `cand` into the list of `k` rows kept in order, when it lists before the
-- last of them or the list is short of the cap; answers the new length.
-- The row table it takes is a spare one, or the one it pushes out.
local function DashKeep(rows, k, cand)
  if k >= DASH_CAP and not DashOrder(cand, rows[k]) then return k end
  if k < DASH_CAP then k = k + 1 end
  local row = rows[k]
  if not row then
    row = { realm = "", name = "", mails = 0, gold = 0, seenAt = 0, soonest = nil, fate = nil, amber = false }
  end
  row.realm, row.name, row.mails, row.gold, row.seenAt = cand.realm, cand.name, cand.mails, cand.gold, cand.seenAt
  row.soonest, row.fate, row.amber = cand.soonest, cand.fate, cand.amber
  local i = k
  while i > 1 and DashOrder(row, rows[i - 1]) do
    rows[i] = rows[i - 1]
    i = i - 1
  end
  rows[i] = row
  return k
end

function MM.Dashboard()
  local enabled = MemoryEnabled() and true or false
  local all = MM.Characters()
  if dash.from == all and dash.enabled == enabled then return dash end
  dash.from, dash.enabled, dash.gen = all, enabled, dash.gen + 1
  local now = time()
  local CT = ns.CollectTab
  local shortDays = CT and CT.RowRules and CT.RowRules.ShortDays
  local rows, cand, n, k = dash.rows, dash.cand, 0, 0
  dash.recorded, dash.mails, dash.gold = false, 0, 0
  dash.soonest, dash.fate, dash.amber = nil, nil, false
  for i = 1, #all do
    local st = all[i]
    if st.seenAt then dash.recorded = true end
    if not st.hidden and st.waiting > 0 then
      local mails = (SnapshotFor(st.realm, st.name) or {}).mails or {}
      local gold, soonest, fate, amber = 0, nil, nil, false
      for j = 1, #mails do
        local mail = mails[j]
        if Holds(mail, now) then
          gold = gold + (tonumber(mail.money) or 0)
          local at = tonumber(mail.expires) or 0
          local cod = (tonumber(mail.cod) or 0) > 0
          local short = shortDays and shortDays(cod) * DAY or (cod and DAY or SOON)
          local isShort = at > now and at - now < short
          -- The short mail first, then the soonest: the row's amber is the
          -- list's own, and a mail that is not short never outranks one that is.
          if at > 0 and ((isShort and not amber) or (isShort == amber and (not soonest or at < soonest))) then
            soonest, amber = at, isShort
            fate = nil
            if mail.back ~= nil and ((mail.money or 0) > 0 or (mail.items or 0) > 0) then
              fate = mail.back and "back" or "gone"
            end
          end
        end
      end
      n = n + 1
      cand.realm, cand.name, cand.mails, cand.gold, cand.seenAt = st.realm, st.name, st.waiting, gold, st.seenAt or 0
      cand.soonest, cand.fate, cand.amber = soonest, fate, amber
      k = DashKeep(rows, k, cand)
      dash.mails, dash.gold = dash.mails + st.waiting, dash.gold + gold
      if soonest and ((amber and not dash.amber) or (amber == dash.amber and (not dash.soonest or soonest < dash.soonest))) then
        dash.soonest, dash.fate, dash.amber = soonest, fate, amber
      end
    end
  end
  -- Rows past `listed` are spares, kept for the next walk.
  dash.n, dash.listed = n, k
  return dash
end

-- realm, name -> that character's box in Mail Memory: its window away from a
-- mailbox, the Mail tab's own view of it at one; nil for this character's
-- own (at a mailbox, the character list, as the minimap's way in has it).
function MM.OpenCharacter(realm, name)
  if not MemoryEnabled() then
    ns.Print(L["MEMORY_OFF"])
    return
  end
  local myRealm, myName = Me()
  local mine = not realm or (realm == myRealm and name == myName)
  local state = MailboxState()
  if state and state.mailboxOpen then
    local UI, CT = ns.MailboxUI, ns.CollectTab
    if not mine and CT and type(CT.ShowCharacter) == "function" then
      CT.ShowCharacter(realm, name)
    elseif UI and type(UI.ShowCharacterPicker) == "function" then
      UI.ShowCharacterPicker()
    end
    return
  end
  local frame = MM._frame
  if not (frame and frame:IsShown()) then
    MM.Toggle()
    frame = MM._frame
  end
  if not (frame and frame:IsShown()) then return end
  frame.viewing = (not mine) and { realm = realm, name = name } or nil
  frame.searchAll = false
  if frame.SearchAllButton then frame.SearchAllButton.Paint() end
  if frame.SearchBox then frame.SearchBox:SetText("") end
  if frame.Scroll then frame.Scroll:SetVerticalScroll(0) end
  MM.Refresh()
  frame:Raise()
end

-- Hiding a character is about the lists of other characters alone: who is
-- offered as a recipient is the Send tab's and Manage Recipients' own
-- (Recipients.SetHidden), and hiding or showing a character here never
-- changes it, as hiding a recipient never changes this list. Two kinds of
-- hiding, each undone where it was done.
--
-- Builds of 1.70 before this kept a second mark in `hiddenChars`,
-- RECIPIENT_HID ("recipient"), where hiding the character had hidden its
-- recipient too (plain true where it had not: the recipient was hidden by
-- hand already, or a favorite). MM.SettleRecipientMarks undoes that once,
-- at load (Postbox.lua, 4b). Both marks are truthy, which is all any other
-- reader asks.
local RECIPIENT_HID = "recipient"

-- realm, name -> the character's recipient key and its address with realm
-- (Recipients.CharacterKey: on Forever the full name alone), or nil before
-- the client knows the realm.
local function RecipientOf(realm, name)
  local R = ns.Recipients
  if type(R) ~= "table" or type(R.CharacterKey) ~= "function" then return nil end
  local key = R.CharacterKey(name, realm)
  if type(key) ~= "string" or key == "" then return nil end
  local H = ns.Helpers
  local twoPart = H and type(H.TwoPartNames) == "function" and H.TwoPartNames()
  return key, twoPart and name or (name .. "-" .. realm)
end

-- Once, at load: each recipient a hidden character's RECIPIENT_HID mark
-- says was hidden with it is offered again (shown only if it is still
-- hidden), and the mark becomes plain true. A recipient hidden by hand
-- (marked true) stays as it is. -> true when every mark was settled, false
-- where a recipient could not be named yet (no Recipients, no realm), so
-- the caller tries again at the next load.
function MM.SettleRecipientMarks()
  local set = HiddenSet(false)
  if not set then return true end
  local R = ns.Recipients
  local readable = type(R) == "table" and type(R.SetHidden) == "function" and type(R.IsHidden) == "function"
  local done = true
  for realm, byRealm in pairs(set) do
    if type(realm) == "string" and type(byRealm) == "table" then
      for name, mark in pairs(byRealm) do
        if mark == RECIPIENT_HID and type(name) == "string" then
          local key, address
          if readable then key, address = RecipientOf(realm, name) end
          if key then
            if R.IsHidden(key) then R.SetHidden(address, false) end
            byRealm[name] = true
          else
            done = false
          end
        end
      end
    end
  end
  return done
end

-- realm, name, hidden -> the character hidden from the lists of other
-- characters, or shown in them again; as a recipient it stays as it was
-- (above). The caller repaints (MM.HiddenChanged); the character list does
-- that once, when it closes.
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

-- Every hidden character shown again. `quiet`: the caller repaints
-- (MM.HiddenChanged), as the options' list does once it closes.
function MM.ShowAllHidden(quiet)
  local set = HiddenSet(false)
  if set then
    for realm in pairs(set) do set[realm] = nil end
  end
  CharactersChanged()
  if not quiet then MM.HiddenChanged() end
end

-- Postbox just sent mail to `toName`. If that is one of the player's own
-- characters, mail is now waiting in its box -- and nothing else would know,
-- if that character is not played for a month. `recorded`: the Sent entry
-- the send wrote (2d), or nil where none was (History off). A mail with a
-- record is counted where that character's box is listed (MM.SentSince),
-- so it is noted as an arrival only; one without is noted uncounted ("new",
-- "N+": nothing names it to that character's count). On Forever mail stays
-- on its ruleset, so only the characters on this one are looked at.
function MM.NoteSentTo(toName, recorded)
  if not MemoryEnabled() or type(toName) ~= "string" or toName == "" then return end
  local myRealm, myName = Me()
  if type(recorded) == "table" and MM.SentTarget then
    local realm, name = MM.SentTarget(recorded, myRealm, myName)
    if realm then
      NoteArrival(realm, name, nil, false)
      -- The count it shows under is read where the list is built.
      CharactersChanged()
      return
    end
  end
  local R = ns.Recipients
  if not (R and type(R.Key) == "function") then return end
  local key = R.Key(toName)
  local alts = ns.Store and ns.Store.Get and ns.Store.Get("alts")
  if not key or type(alts) ~= "table" then return end
  local two = ns.Helpers.TwoPartNames()
  for realm, names in pairs(alts) do
    if type(names) == "table" and not (two and realm ~= myRealm) then
      for i = 1, #names do
        local name = names[i]
        if not (realm == myRealm and name == myName)
           and (R.CharacterKey and R.CharacterKey(name, realm) or R.Key(name .. "-" .. realm)) == key then
          -- One mail, but nothing names it to that character's count.
          NoteArrival(realm, name, nil, true)
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
-- of it as the player chose, at most as many entries as History holds
-- (PruneHistory), one entry per mail
-- however many takes that mail needed -- the caller holding one record per
-- mail is what makes it one. Written by Core/MailService.lua as each take is
-- CONFIRMED -- never when the command is sent, since the server may refuse
-- it -- and read by the Mail tab's History view. Pruned on every write, so
-- it never holds more than the days it shows.
-------------------------------------------------------------

-- Kept as long as the player chose (Options, General: 7 days by default, up
-- to a year, or "Never", which records nothing and prunes everything away), and
-- never much more than the entries History holds (Options, General: 1000 by
-- default, 2500 or 5000; MailboxUI.GetHistoryCap) however busy the box: the
-- record is saved per character, and a month of a busy auction goblin's mail
-- must not become megabytes of saved variables. A record may run a twentieth
-- over its cap and is then cut back to the cap in one pass,
-- so a mail recorded at the cap moves no list; History's view lists at most
-- the cap's newest (CollectTab, HV.BuildHistoryList).
local function HistoryCap()
  local UI = ns.MailboxUI
  return tonumber(UI and type(UI.GetHistoryCap) == "function" and UI.GetHistoryCap()) or 1000
end
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
    -- A record made: the list of every character's (MM.HistoryCharacters)
    -- has one more.
    MM.HistoryChanged()
  end
  return list
end

-- Every write to a History or Sent record -- an entry made, an entry
-- added to, entries dropped, a record made or let go -- moves this count,
-- so a list built from the records (CollectTab's History) knows exactly
-- when what it built from has changed.
MM.recordWrites = 0
-- The same for the Sent records alone: an entry written, entries dropped, a
-- record made or let go. What is built from them for the player's own
-- characters' boxes (2d, MM.SentSince) is built again when it moves; a
-- collect, which writes History, leaves it be.
MM.sentGen = 0

-- What runs past the cap before it is cut back: a twentieth of it (50 at
-- 1000, 250 at 5000), so the pass that moves the list comes once in that
-- many mails and each mail's share of it stays the same at any cap.
-- `list`, `now` -> the entries older than the days kept dropped and, once
-- the record runs past cap + slack, its oldest down to the cap.
local function PruneHistory(list, now)
  local keep = HistoryKeep()
  local cutoff = now - keep
  local n = #list
  local drop = 0
  -- "Never": History is off, and nothing it held stays.
  if keep <= 0 then drop = n end
  while list[drop + 1] and (tonumber(list[drop + 1].t) or 0) < cutoff do
    drop = drop + 1
  end
  local cap = HistoryCap()
  if n - drop > cap + math.floor(cap / 20) then drop = n - cap end
  if drop > 0 then
    MM.recordWrites = MM.recordWrites + 1
    -- And the mail sent to the player's own characters, read from the
    -- records (2d, MM.SentSince), is read again.
    MM.sentGen = MM.sentGen + 1
    for i = 1, n - drop do list[i] = list[i + drop] end
    for i = n, n - drop + 1, -1 do list[i] = nil end
  end
end

-- Every character's History, pruned to the days the player chose. A list is
-- otherwise pruned only when its own character reads or writes it, so an alt
-- not played for months kept all it had -- and a lower "Keep History" never
-- reached it. Once per login, and the moment "Never" is chosen (below);
-- each list is in date order, so this touches only what goes. A list left
-- empty is dropped, so "Never" leaves no character's record behind, and a
-- record already empty costs one lookup and allocates nothing.
-- What was sent (2d) is kept and pruned by the same rule, in its own root,
-- and so is what was returned to the player's own characters (2d,
-- MM.ReturnRecord), in its own.
local function PruneAllHistory()
  for pass = 1, 3 do
    local key = (pass == 1) and "mailHistory" or (pass == 2) and "mailSent" or "mailReturned"
    local root = ns.Store and ns.Store.Get and ns.Store.Get(key)
    if type(root) == "table" then
      local now = time()
      for realm, byRealm in pairs(root) do
        if type(byRealm) == "table" then
          for name, list in pairs(byRealm) do
            if type(list) == "table" then
              PruneHistory(list, now)
              if #list == 0 then
                byRealm[name] = nil
                if pass == 1 then MM.HistoryChanged() else MM.SentChanged() end
              end
            end
          end
          if next(byRealm) == nil then root[realm] = nil end
        end
      end
    end
  end
  -- And the deposits paid (2f), kept and emptied with History.
  if MM.PruneDeposits then MM.PruneDeposits() end
end

-- Frozen: Core/MailboxUI.lua calls this when History is set to "Never", so
-- the saved record is emptied then, not at the next login. Safe at any
-- time: it reads only the saved record and the stored choice.
MM.PruneAllHistory = PruneAllHistory

-- This character's record, oldest first, pruned to the week; empty when
-- there is none.
function MM.History()
  local list = HistoryList(false)
  if not list then return {} end
  PruneHistory(list, time())
  return list
end

-- Every character's History, for the Mail tab's search of all of them
-- (CollectTab's HV.BuildHistoryList): this character first, then the others
-- by name, a hidden character left out as the search of every box leaves it
-- out. Each item is also the heading its matches list under -- `header`,
-- `realm`, `name` and `label` are what MM.FillRow draws for one -- so a
-- keystroke builds nothing. One list until the record's root is replaced, a
-- character's record is made or dropped (MM.HistoryChanged), the hidden set
-- changes (charactersGen) or another character is played.
-- What was sent (2d) is listed by the same rule from its own root: one memo
-- per root, each with its own generation.
do
  local memos = { mailHistory = {}, mailSent = {} }
  local gens = { mailHistory = 0, mailSent = 0 }

  function MM.HistoryChanged()
    gens.mailHistory = gens.mailHistory + 1
    MM.recordWrites = MM.recordWrites + 1
  end
  function MM.SentChanged()
    gens.mailSent = gens.mailSent + 1
    MM.recordWrites = MM.recordWrites + 1
    -- A record made or let go ("Never" empties them all): the counts of the
    -- mail sent to the player's own characters move with it.
    MM.sentGen = MM.sentGen + 1
    CharactersChanged()
  end

  local function MeFirst(a, b)
    if a.me ~= b.me then return a.me end
    if a.name ~= b.name then return a.name < b.name end
    return a.realm < b.realm
  end

  local function Characters(key)
    local memo, historyGen = memos[key], gens[key]
    local root = ns.Store and ns.Store.Get and ns.Store.Get(key)
    local myRealm, myName = Me()
    if memo.list and memo.root == root and memo.gen == historyGen and memo.chars == charactersGen
      and memo.realm == myRealm and memo.name == myName then
      return memo.list
    end
    local list = {}
    if myRealm and myName then list[1] = { header = true, me = true, realm = myRealm, name = myName } end
    if type(root) == "table" then
      local hidden = HiddenSet(false)
      for realm, byRealm in pairs(root) do
        if type(byRealm) == "table" then
          for name, entries in pairs(byRealm) do
            if type(entries) == "table" and not (realm == myRealm and name == myName)
              and not InHiddenSet(hidden, realm, name) then
              list[#list + 1] = { header = true, me = false, realm = realm, name = name }
            end
          end
        end
      end
    end
    table.sort(list, MeFirst)
    for i = 1, #list do list[i].label = MM.ClassName(list[i].realm, list[i].name) end
    memo.list, memo.root, memo.gen, memo.chars = list, root, historyGen, charactersGen
    memo.realm, memo.name = myRealm, myName
    return list
  end

  function MM.HistoryCharacters() return Characters("mailHistory") end
  function MM.SentCharacters() return Characters("mailSent") end

  -- An item of that list -> its character's record, oldest first, pruned to
  -- the days kept as this character's is on every read; nil when it has
  -- none.
  local function RecordOf(key, item)
    local root = ns.Store and ns.Store.Get and ns.Store.Get(key)
    local byRealm = type(root) == "table" and root[item.realm] or nil
    local list = type(byRealm) == "table" and byRealm[item.name] or nil
    if type(list) ~= "table" then return nil end
    PruneHistory(list, time())
    return list
  end

  function MM.HistoryOf(item)
    if item.me then return MM.History() end
    return RecordOf("mailHistory", item)
  end
  function MM.SentOf(item)
    if item.me then return MM.Sent() end
    return RecordOf("mailSent", item)
  end

  -- The Sent half as History lists it (CollectTab, HV.Record and the search
  -- of every character): a character's Sent record with the mail it
  -- returned to another of the player's characters among it, in time order
  -- (MM.ReturnRecord; each such entry carries r = true, set again here for
  -- one kept before it did). Without returns, the Sent record itself, as
  -- before. A merged list is made once per write and kept, one per
  -- character, until either record moves (MM.recordWrites, or another
  -- list); a refresh makes nothing. Read only: neither record is written
  -- but by its pruning, as every read of them prunes.
  local listed = {}
  local NONE_SENT = {}
  local function Listed(realm, name, sent)
    local root = ns.Store and ns.Store.Get and ns.Store.Get("mailReturned")
    local byRealm = type(root) == "table" and root[realm] or nil
    local back = type(byRealm) == "table" and byRealm[name] or nil
    if type(back) ~= "table" or back[1] == nil then return sent end
    PruneHistory(back, time())
    if back[1] == nil then return sent end
    sent = sent or NONE_SENT
    local mine = listed[realm]
    if not mine then
      mine = {}
      listed[realm] = mine
    end
    local kept = mine[name]
    if kept and kept.writes == MM.recordWrites and kept.sent == sent and kept.back == back
        and kept.ns == #sent and kept.nb == #back then
      return kept.list
    end
    local list, i, j = {}, 1, 1
    local ns_, nb = #sent, #back
    while i <= ns_ or j <= nb do
      local a, b = sent[i], back[j]
      if b and (not a or (tonumber(b.t) or 0) < (tonumber(a.t) or 0)) then
        b.r = true
        list[#list + 1] = b
        j = j + 1
      else
        list[#list + 1] = a
        i = i + 1
      end
    end
    mine[name] = { writes = MM.recordWrites, sent = sent, back = back, ns = ns_, nb = nb, list = list }
    return list
  end

  function MM.SentListed()
    local realm, name = Me()
    if not (realm and name) then return MM.Sent() end
    return Listed(realm, name, MM.Sent())
  end
  function MM.SentListedOf(item)
    if item.me then return MM.SentListed() end
    return Listed(item.realm, item.name, RecordOf("mailSent", item))
  end

  -- Whether another character (not hidden) has History to search: asked
  -- whenever History comes on screen, so read straight off the record,
  -- building nothing.
  local function Others(key)
    local root = ns.Store and ns.Store.Get and ns.Store.Get(key)
    if type(root) ~= "table" then return false end
    local myRealm, myName = Me()
    local hidden = HiddenSet(false)
    for realm, byRealm in pairs(root) do
      if type(byRealm) == "table" then
        for name, entries in pairs(byRealm) do
          if type(entries) == "table" and #entries > 0 and not (realm == myRealm and name == myName)
            and not InHiddenSet(hidden, realm, name) then
            return true
          end
        end
      end
    end
    return false
  end

  function MM.HistoryOthers() return Others("mailHistory") end
  function MM.SentOthers() return Others("mailSent") end
end

-------------------------------------------------------------
-- 2d. What went out of the box
--
-- History's other half: each mail a send of Postbox's put in the post, one
-- entry per mail (a run of mails from one press makes one each), written
-- when the server CONFIRMS the send (Core/SendTab.lua, on its
-- MAIL_SEND_SUCCESS) and never when it is asked, since the server may
-- refuse it. Kept per character beside History, under its days and its
-- cap, at the root `mailSent`, realm -> name -> entries oldest first:
--   t    when the server took it
--   s    the recipient as addressed, its realm resolved and kept
--        (Recipients.Qualify: "Name-Realm"; Forever's full name)
--   sub  the subject it went with
--   it   what it carried, { l = link, n = count } per item, as History's
--   m    the gold it carried, c the C.O.D. it asked (copper)
--   h    true when the game takes about an hour to deliver it (MailRules:
--        items, gold or C.O.D. to someone not known as the player's own)
-- "Never" records nothing and clears it with History (PruneAllHistory).
-- Nothing runs between sends: one write per mail the server took.
-------------------------------------------------------------
do
  -- No record: one empty list, read and never written.
  local NONE = {}

  local function SentList(create)
    local realm, name = Me()
    if not (realm and name) then return nil end
    local root
    if create then
      root = ns.Store.EnsurePath("mailSent")
    else
      root = ns.Store and ns.Store.Get and ns.Store.Get("mailSent")
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
      MM.SentChanged()
    end
    return list
  end

  -- This character's record of what it sent, oldest first, pruned to the
  -- days kept; empty when there is none.
  function MM.Sent()
    local list = SentList(false)
    if not list then return NONE end
    PruneHistory(list, time())
    return list
  end

  -- One mail the server took: `entry` as above, built by the send that
  -- posted it, kept as given. Returns it, or nil when History is off.
  function MM.SentRecord(entry)
    if type(entry) ~= "table" or HistoryKeep() <= 0 then return nil end
    local list = SentList(true)
    if not list then return nil end
    entry.t = entry.t or time()
    list[#list + 1] = entry
    MM.recordWrites = MM.recordWrites + 1
    -- What is built from the records for the player's own characters'
    -- boxes takes the one entry (below); a cut back to the cap builds it
    -- again.
    local gen = MM.sentGen
    MM.sentGen = gen + 1
    if MM._SentAdded then MM._SentAdded(entry, gen) end
    PruneHistory(list, entry.t)
    return entry
  end

  -- When each recipient was last mailed, for Manage Recipients' Mailed
  -- column: `into` emptied and filled with key -> the newest `t` any
  -- character's record holds for that recipient, each `s` turned into a key
  -- by `keyOf` (Recipients.Key) once and kept in `memo` (s -> key, or false),
  -- so the window's next open turns none again. Read only: nothing is
  -- pruned or written. -> into, or nil (into left empty) while History is
  -- off, when what is recorded no longer says when anyone was last mailed.
  function MM.LastMailedInto(into, keyOf, memo)
    for k in pairs(into) do into[k] = nil end
    if HistoryKeep() <= 0 then return nil end
    local root = ns.Store and ns.Store.Get and ns.Store.Get("mailSent")
    if type(root) ~= "table" then return into end
    for _, byRealm in pairs(root) do
      if type(byRealm) == "table" then
        for _, list in pairs(byRealm) do
          if type(list) == "table" then
            for i = 1, #list do
              local e = list[i]
              local s = type(e) == "table" and e.s
              local t = type(s) == "string" and tonumber(e.t)
              if t then
                local key = memo and memo[s]
                if key == nil then
                  key = keyOf(s)
                  if type(key) ~= "string" or key == "" then key = false end
                  if memo then memo[s] = key end
                end
                if key and (into[key] or 0) < t then into[key] = t end
              end
            end
          end
        end
      end
    end
    return into
  end

  -- Mail sent to the player's own characters, by the character it went
  -- to: what that character's box holds that its last snapshot cannot
  -- know. Read from the records above, every character's (several may
  -- have mailed one alt), and from the mail returned to one
  -- (MM.ReturnRecord, below): each entry whose `s` is one of the characters
  -- in the census (`alts`), by the census's own key (Recipients.
  -- CharacterKey, as Mail.OwnCharacterKeys keys them), and not the one
  -- that sent it. On Forever mail cannot cross a ruleset, so an entry is
  -- matched only to the characters on its sender's.
  --
  -- Each character it went to (a target) holds one part per character
  -- that sent it some: the entries themselves, oldest first as the record
  -- has them, so nothing is sorted. Built when first asked and kept until
  -- the records move (MM.sentGen: entries dropped, a record made or let
  -- go), the census grows, or the roots are replaced; a mail sent adds its
  -- one entry where it goes (MM._SentAdded) rather than build again. Never
  -- per refresh. A row is made for an entry the first time a box lists it
  -- (SentRow) and kept while the entry is (weak keys), so a refresh makes
  -- nothing.
  local built = { gen = -1, root = false, alts = false, altsN = -1, two = false, targets = false, own = false,
    keys = false }
  local rowOf = setmetatable({}, { __mode = "k" })
  local LETTER = "Interface\\Icons\\INV_Letter_02"
  -- Where the newest-first walk over a target's parts stands in each part
  -- (SentWalk): one table for every walk, emptied after it.
  local cursor = {}

  local function CensusCount(alts)
    local n = 0
    for _, names in pairs(alts) do
      if type(names) == "table" then n = n + #names end
    end
    return n
  end

  -- An address as written in a record (`s`) -> its recipient key, or false.
  -- Kept per build: a record names few recipients many times.
  local function KeyOf(s)
    local keys = built.keys
    local key = keys[s]
    if key == nil then
      local R = ns.Recipients
      key = (R and type(R.Key) == "function") and (R.Key(s)) or false
      if type(key) ~= "string" or key == "" then key = false end
      keys[s] = key
    end
    return key
  end

  -- entry, realm, name (of the character whose record holds it) -> the
  -- target it went to, or nil.
  local function TargetOf(e, sRealm, sName)
    local s = type(e) == "table" and e.s or nil
    if type(s) ~= "string" or not tonumber(e.t) then return nil end
    local own = built.own
    local mine = (not built.two) and own or own[sRealm]
    local key = mine and KeyOf(s)
    local target = key and mine[key]
    if target and not (target.realm == sRealm and target.name == sName) then return target end
    return nil
  end

  -- One entry onto its target, in the part of the character that sent it:
  -- a part per sender and per record, sent (2d) or returned
  -- (MM.ReturnRecord), so a part's entries stay in their record's order.
  local function Add(target, e, sRealm, sName, returned)
    local parts = target.parts
    if not parts then
      parts = {}
      target.parts = parts
    end
    returned = returned and true or false
    local part
    for i = 1, #parts do
      local p = parts[i]
      if p.realm == sRealm and p.name == sName and p.returned == returned then
        part = p
        break
      end
    end
    if not part then
      part = { realm = sRealm, name = sName, returned = returned }
      parts[#parts + 1] = part
    end
    part[#part + 1] = e
  end

  local function AddRecords(root, returned)
    if type(root) ~= "table" then return end
    for sRealm, byRealm in pairs(root) do
      if type(byRealm) == "table" then
        for sName, list in pairs(byRealm) do
          if type(list) == "table" then
            for i = 1, #list do
              local e = list[i]
              local target = TargetOf(e, sRealm, sName)
              if target then Add(target, e, sRealm, sName, returned) end
            end
          end
        end
      end
    end
  end

  local function Build(root, returns, alts, two)
    local b = built
    b.targets, b.own, b.keys, b.two = {}, {}, {}, two
    local R = ns.Recipients
    if not (R and type(R.Key) == "function") then return end
    for realm, names in pairs(alts) do
      if type(names) == "table" then
        for i = 1, #names do
          local name = names[i]
          local key = type(name) == "string" and name ~= "" and ((type(R.CharacterKey) == "function")
            and R.CharacterKey(name, realm) or (R.Key(name .. "-" .. realm))) or nil
          if type(key) == "string" and key ~= "" then
            local target = { realm = realm, name = name, parts = false }
            b.targets[realm] = b.targets[realm] or {}
            b.targets[realm][name] = target
            if two then
              b.own[realm] = b.own[realm] or {}
              b.own[realm][key] = target
            else
              b.own[key] = target
            end
          end
        end
      end
    end
    AddRecords(root, false)
    AddRecords(returns, true)
  end

  -- -> `built`, current, or nil without a census. The Sent records and the
  -- returns' (MM.ReturnRecord) are each read where there are any.
  local function Fresh()
    local get = ns.Store and ns.Store.Get
    local root = get and get("mailSent")
    local returns = get and get("mailReturned")
    local alts = get and get("alts")
    if type(alts) ~= "table" then return nil end
    if type(root) ~= "table" then root = false end
    if type(returns) ~= "table" then returns = false end
    local n = CensusCount(alts)
    local two = ns.Helpers.TwoPartNames() and true or false
    local b = built
    if not (b.targets and b.gen == MM.sentGen and b.root == root and b.returns == returns and b.alts == alts
        and b.altsN == n and b.two == two) then
      Build(root, returns, alts, two)
      b.gen, b.root, b.returns, b.alts, b.altsN = MM.sentGen, root, returns, alts, n
    end
    return b
  end

  local function TargetFor(realm, name)
    local b = Fresh()
    local byRealm = b and b.targets[realm]
    return byRealm and byRealm[name] or nil
  end

  -- A record of the character played took `entry` (MM.SentRecord, or
  -- MM.ReturnRecord with `returned`), and `gen` is what MM.sentGen was
  -- before: what is built stays current with the entry added where it goes,
  -- if it was current before.
  function MM._SentAdded(entry, gen, returned)
    local b = built
    if not (b.targets and b.gen == gen) then return end
    local realm, name = Me()
    local target = TargetOf(entry, realm, name)
    if target then Add(target, entry, realm, name, returned) end
    b.gen = MM.sentGen
  end

  -- entry, realm, name (of the character that sent it, the one played) ->
  -- the realm and name of the player's own character it went to, or nil.
  function MM.SentTarget(entry, realm, name)
    if type(entry) ~= "table" or not (realm and name) or not Fresh() then return nil end
    local target = TargetOf(entry, realm, name)
    if not target then return nil end
    return target.realm, target.name
  end

  -- target, after, cutoff -> the newest entry of its parts newer than both
  -- (the walk's cursor moved past it) and its part, or nil when none is.
  -- The cursor starts at each part's end (SentWalk).
  local function NextNewest(parts, after, cutoff)
    local best, bestPart, bestAt, bestT = nil, nil, 0, nil
    for p = 1, #parts do
      local at = cursor[p]
      local e = at > 0 and parts[p][at] or nil
      local t = e and (tonumber(e.t) or 0)
      if t and t > after and t >= cutoff and (not bestT or t > bestT) then
        best, bestPart, bestAt, bestT = e, p, at, t
      end
    end
    if not best then return nil end
    cursor[bestPart] = bestAt - 1
    return best, parts[bestPart]
  end

  -- A mail Postbox returned, the server CONFIRMED (Core/MailService.lua,
  -- Mail.ReturnMail: the mail has left the inbox by that command), as read
  -- just before the command went: `entry` { s = its sender as the inbox
  -- named it, sub, it = { { l = link, n = count } }, m = gold, c = C.O.D. }.
  -- Kept only when that sender is one of the player's own characters (by
  -- the census's key, as a Sent entry's recipient is matched), so its box
  -- lists the mail on its way back with what was sent it (SentRow, marked
  -- returned). Kept apart from Sent, which lists what this character sent,
  -- at the root `mailReturned`, realm -> name (the character that returned
  -- it) -> entries oldest first, `s` turned into the address a Sent entry
  -- keeps; under History's days and cap as Sent is (PruneHistory), and
  -- nothing while History is Never. What the game does to a C.O.D. or
  -- gold on a mail sent back is not established here: what it held is
  -- recorded, and its row shows no C.O.D. -> the entry, or nil.
  function MM.ReturnRecord(entry)
    if type(entry) ~= "table" or type(entry.s) ~= "string" or entry.s == "" or HistoryKeep() <= 0 then return nil end
    local realm, name = Me()
    if not (realm and name) then return nil end
    local R = ns.Recipients
    local to = R and type(R.Qualify) == "function" and R.Qualify(entry.s) or ""
    if type(to) ~= "string" or to == "" then return nil end
    entry.s = to
    entry.t = entry.t or time()
    -- Told apart from a mail sent where History > Sent lists both
    -- (MM.SentListed).
    entry.r = true
    if not Fresh() then return nil end
    local target = TargetOf(entry, realm, name)
    if not target then return nil end
    local root = ns.Store.EnsurePath("mailReturned")
    local byRealm = root[realm]
    if type(byRealm) ~= "table" then
      byRealm = {}
      root[realm] = byRealm
    end
    local list = byRealm[name]
    if type(list) ~= "table" then
      list = {}
      byRealm[name] = list
      MM.SentChanged()
    end
    list[#list + 1] = entry
    MM.recordWrites = MM.recordWrites + 1
    local gen = MM.sentGen
    MM.sentGen = gen + 1
    MM._SentAdded(entry, gen, true)
    PruneHistory(list, entry.t)
    -- Mail on its way to that character, counted where its box is listed.
    NoteArrival(target.realm, target.name, nil, false)
    CharactersChanged()
    return entry
  end

  -- realm, name, seenAt, now -> how many of the mails sent to that
  -- character are newer than `seenAt` (its box's last visit; nil: none
  -- recorded, every one) and still within the days History keeps. 0 while
  -- History is off: nothing is recorded then.
  function MM.SentSince(realm, name, seenAt, now)
    local keep = HistoryKeep()
    if keep <= 0 then return 0 end
    local target = TargetFor(realm, name)
    local parts = target and target.parts
    if not parts then return 0 end
    local after, cutoff = tonumber(seenAt) or -1, (now or time()) - keep
    local n = 0
    for p = 1, #parts do
      local part = parts[p]
      for i = #part, 1, -1 do
        local t = tonumber(part[i].t) or 0
        if t <= after or t < cutoff then break end
        n = n + 1
      end
    end
    return n
  end

  -- entry, part (its sender), realm (of the box) -> the row a box lists
  -- for it: a mail as a snapshot keeps one (section 1), with `sent` set
  -- and no `expires` (nothing here says when it goes), its sender the
  -- character that sent it, as a box names a sender: bare on the box's own
  -- realm, "Name-Realm" from another; on Forever the full name. Its items
  -- as a capture lists them, id and count in turn; its subject the one it
  -- went with, or its first item's name.
  local function SentRow(e, part, toRealm)
    local row = rowOf[e]
    if row then return row end
    local sender = part.name
    if part.realm ~= toRealm and not ns.Helpers.TwoPartNames() then
      sender = part.name .. "-" .. (part.realm:gsub("[%s%-]", ""))
    end
    local list, first, firstId = nil, nil, nil
    if type(e.it) == "table" then
      for k = 1, #e.it do
        local item = e.it[k]
        local link = type(item) == "table" and item.l or nil
        local id = type(link) == "string" and tonumber((link:match("item:(%d+)"))) or nil
        if id then
          list = list or {}
          local at = #list
          list[at + 1] = id
          list[at + 2] = tonumber(item.n) or 1
          if not first then first, firstId = item, id end
        end
      end
    end
    local subject = type(e.sub) == "string" and e.sub or ""
    if subject == "" and first then subject = first.l:match("|h%[(.-)%]|h") or "" end
    local icon
    if firstId and C_Item and type(C_Item.GetItemIconByID) == "function" then icon = C_Item.GetItemIconByID(firstId) end
    -- A mail returned to the box (MM.ReturnRecord) says so, and shows no
    -- C.O.D.: nothing here establishes that one stays on a mail sent back.
    local returned = part.returned and true or false
    row = { sent = true, returned = returned, t = tonumber(e.t), stuck = false, icon = icon or LETTER, sender = sender,
      subject = subject, money = tonumber(e.m) or 0, cod = (not returned) and (tonumber(e.c) or 0) or 0,
      items = list and #list / 2 or 0, read = false, link = first and first.l or false, id = firstId, kind = false,
      paid = false, count = first and (tonumber(first.n) or 1) or false, it = list }
    rowOf[e] = row
    return row
  end

  -- out, realm, name, seenAt, now, oldest -> how many rows were appended
  -- to `out`: the mails MM.SentSince counts, newest first whoever sent
  -- them (`oldest`: the other way round).
  function MM.SentRowsInto(out, realm, name, seenAt, now, oldest)
    local keep = HistoryKeep()
    if keep <= 0 then return 0 end
    local target = TargetFor(realm, name)
    local parts = target and target.parts
    if not parts then return 0 end
    local after, cutoff = tonumber(seenAt) or -1, (now or time()) - keep
    for p = 1, #parts do cursor[p] = #parts[p] end
    local at, n = #out, 0
    while true do
      local e, part = NextNewest(parts, after, cutoff)
      if not e then break end
      n = n + 1
      out[at + n] = SentRow(e, part, realm)
    end
    for p = #cursor, 1, -1 do cursor[p] = nil end
    if oldest then
      for i = 1, math.floor(n / 2) do
        out[at + i], out[at + n + 1 - i] = out[at + n + 1 - i], out[at + i]
      end
    end
    return n
  end

  -- realm, name -> the heading over that character's sent rows and the
  -- line under them (its box's own, MM.SeenText), made once per build and
  -- kept on its target, so a refresh makes neither. The heading is a
  -- heading of the box it stands in (header, its realm and name), drawn as
  -- words alone (`note`); the line's words are set by the list that shows
  -- it.
  function MM.SentNotes(realm, name)
    local target = TargetFor(realm, name)
    if not target then return nil end
    local head = target.head
    if not head then
      head = { header = true, note = true, realm = realm, name = name, label = L["MEMORY_SENT_SINCE"] }
      target.head = head
      target.line = { note = true, line = true, label = "" }
    end
    return head, target.line
  end
end

-- index -> what is known about the mail before anything is taken from it,
-- or nil when its header has not arrived. Its first confirmed take turns it
-- into an entry.
function MM.HistoryBegin(index)
  local _, _, sender, subject, _, cod = GetInboxHeaderInfo(index)
  if sender == nil and subject == nil then return nil end
  local service = ns.MailService
  local kind = service and service.ClassifyMail and service.ClassifyMail(index) or "other"
  local ctx = {
    sender = tostring(sender or ""), subject = tostring(subject or ""),
    kind = kind, cod = tonumber(cod) or 0,
  }
  MM.HistoryInvoice(ctx, index)
  return ctx
end

-- What an auction mail's invoice says, onto the record `ctx` of the mail at
-- `index`: a won auction's price (`price`), a sale's deposit returned and
-- the auction house's cut (`deposit`, `cut`), read once. The game answers
-- GetInboxInvoiceInfo only once the mail's body has been fetched, so this
-- is asked when the record begins and again where the collect has fetched
-- it (MailService's HistoryRecord, before the takes): a won auction opened
-- unread has its price from the second. Amounts as the invoice gives them,
-- no rate assumed. Only a settled sale ("seller") is read: a pending one
-- holds no gold yet.
function MM.HistoryInvoice(ctx, index)
  if type(ctx) ~= "table" or ctx.invoiced or type(GetInboxInvoiceInfo) ~= "function" then return end
  if ctx.kind ~= "bought" and ctx.kind ~= "sold" then return end
  local ok, invoiceType, _, _, bid, _, deposit, consignment = pcall(GetInboxInvoiceInfo, index)
  if not ok then return end
  local secret = type(issecretvalue) == "function" and issecretvalue or nil
  if secret and (secret(invoiceType) or secret(bid) or secret(deposit) or secret(consignment)) then return end
  bid, deposit, consignment = tonumber(bid) or 0, tonumber(deposit) or 0, tonumber(consignment) or 0
  if invoiceType == "buyer" and ctx.kind == "bought" then
    if bid > 0 then ctx.price, ctx.invoiced = bid, true end
  elseif invoiceType == "seller" and ctx.kind == "sold" then
    ctx.deposit, ctx.cut, ctx.invoiced = deposit, consignment, true
  end
end

-- One confirmed take from the mail `ctx` describes: "money" and a sum in
-- copper, or "item", a link and a count. The first take of a C.O.D. mail is
-- the one that paid the price.
function MM.HistoryTook(ctx, what, value, count)
  -- "Never": History is off, and nothing is recorded.
  if not ctx or HistoryKeep() <= 0 then return end
  local list = HistoryList(true)
  if not list then return end
  MM.recordWrites = MM.recordWrites + 1
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
    -- A sale's invoice, where it was read: the deposit that came back in
    -- this gold and the cut taken before it, each only when not zero
    -- (MM.Week). An invoice read that holds neither keeps `ct = 0`, so the
    -- week can tell it from one never read.
    if entry.k == "sold" and ctx.invoiced and entry.dp == nil and entry.ct == nil then
      if (ctx.deposit or 0) > 0 then entry.dp = ctx.deposit end
      if (ctx.cut or 0) > 0 then entry.ct = ctx.cut end
      if entry.dp == nil and entry.ct == nil then entry.ct = 0 end
    end
    -- A sold auction's gold: the item that sold, kept with the entry where
    -- it can be told now (CollectTab, CT.SoldIcon), so its row needs no
    -- telling again.
    if entry.k == "sold" and entry.ic == nil then
      local CT = ns.CollectTab
      local ok, icon = false, nil
      if CT and type(CT.SoldIcon) == "function" then ok, icon = pcall(CT.SoldIcon, entry.sub) end
      if ok and type(icon) == "number" then entry.ic = icon end
    end
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
  -- An item now in the record: a sold auction's row can be told by it
  -- (CollectTab, CT.SoldLearn).
  local CT = ns.CollectTab
  if CT and type(CT.SoldLearn) == "function" then pcall(CT.SoldLearn, value) end
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
-- 2e. What was put up for auction
--
-- A sold auction's mail names its item only by name, and holds only gold,
-- so its row cannot show the item unless something knows which item that
-- name was. Every auction this account posts is noted as it goes up, in
-- `auctionPosts` (realm -> name -> item name -> { i = item id, t = when,
-- c = the posted item's own icon, only where its id's icon is another }):
-- the name exactly as this client wrote it, from the item the post was made
-- from (C_AuctionHouse.PostItem and PostCommodity, post-hooked; an item's
-- auction is noted again from AUCTION_HOUSE_AUCTION_CREATED where the client
-- can say what it was). Nothing else: no price, no count. Kept POSTS_KEEP,
-- longer than an auction runs and its mail lives, at most POSTS_MAX names a
-- character, pruned as History is at login and as each post is noted.
-- Read by CollectTab's RV.SoldIcon, through MM.PostedItem.
-------------------------------------------------------------
do
  local POSTS_KEEP, POSTS_MAX = 33 * DAY, 200
  local postsGen = 0

  local function Posts(create)
    local realm, name = Me()
    if not (realm and name) then return nil end
    local root
    if create then
      root = ns.Store.EnsurePath("auctionPosts")
    else
      root = ns.Store and ns.Store.Get and ns.Store.Get("auctionPosts")
    end
    if type(root) ~= "table" then return nil end
    local byRealm = root[realm]
    if type(byRealm) ~= "table" then
      if not create then return nil end
      byRealm = {}
      root[realm] = byRealm
    end
    local list = byRealm[name]
    if type(list) ~= "table" then
      if not create then return nil end
      list = {}
      byRealm[name] = list
    end
    return list
  end

  -- One character's notes past POSTS_KEEP dropped, and the oldest past
  -- POSTS_MAX.
  local function Prune(list, now)
    local count, oldest, oldestAt = 0, nil, nil
    for item, note in pairs(list) do
      local t = type(note) == "table" and tonumber(note.t) or nil
      if not t or t < now - POSTS_KEEP then
        list[item] = nil
      else
        count = count + 1
        if not oldestAt or t < oldestAt then oldest, oldestAt = item, t end
      end
    end
    if count > POSTS_MAX and oldest then list[oldest] = nil end
  end

  -- An item put up for auction, by its id and its name as this client wrote
  -- it: noted for this character. `icon`: the icon the game gave the very
  -- item posted, kept (`c`) only where its id's own icon differs -- a caged
  -- pet's id is the Pet Cage's -- so an ordinary note stays { i, t }.
  local function Note(itemID, itemName, icon)
    itemID = tonumber(itemID)
    if not itemID or type(itemName) ~= "string" or itemName == "" then return end
    local secret = type(issecretvalue) == "function" and issecretvalue or nil
    if secret and secret(itemName) then return end
    if icon ~= nil and secret and secret(icon) then icon = nil end
    if type(icon) ~= "number" then icon = nil end
    if icon and C_Item and type(C_Item.GetItemIconByID) == "function" then
      local ok, own = pcall(C_Item.GetItemIconByID, itemID)
      if ok and own == icon then icon = nil end
    end
    local list = Posts(true)
    if not list then return end
    local now = time()
    local note = list[itemName]
    if type(note) == "table" then
      -- An icon kept for another item of this name is not this one's.
      if icon or tonumber(note.i) ~= itemID then note.c = icon end
      note.i, note.t = itemID, now
    else
      note = { i = itemID, t = now }
      if icon then note.c = icon end
      list[itemName] = note
    end
    Prune(list, now)
    postsGen = postsGen + 1
    -- A sold row that showed the coin for it may show it now.
    local CT = ns.CollectTab
    if CT and type(CT.SoldAgain) == "function" then pcall(CT.SoldAgain) end
  end

  -- The post-hook on C_AuctionHouse.PostItem / PostCommodity: the item the
  -- auction is made from, by the bag slot it was posted from, with the icon
  -- the game gives that very item.
  local function Posted(location)
    local api = C_Item
    if type(api) ~= "table" or type(location) ~= "table" then return end
    if type(api.DoesItemExist) == "function" and not api.DoesItemExist(location) then return end
    if type(api.GetItemID) ~= "function" or type(api.GetItemName) ~= "function" then return end
    local icon
    if type(api.GetItemIcon) == "function" then
      local ok, got = pcall(api.GetItemIcon, location)
      if ok then icon = got end
    end
    Note(api.GetItemID(location), api.GetItemName(location), icon)
  end
  -- The deposit a post would cost (2f): what the game answers for that item,
  -- duration and quantity, rounded up to the silver where the house takes
  -- no copper, as its own sell frame shows it, and the item's id. Nothing
  -- when it cannot say. Asked at the hook, while the item is still in its
  -- bag slot.
  local function DepositOf(commodity, location, duration, quantity)
    local house, api = C_AuctionHouse, C_Item
    if type(house) ~= "table" or type(location) ~= "table" then return end
    local secret = type(issecretvalue) == "function" and issecretvalue or nil
    local itemID
    if type(api) == "table" and type(api.GetItemID) == "function" then
      local got, id = pcall(api.GetItemID, location)
      if got and type(id) == "number" and not (secret and secret(id)) then itemID = id end
    end
    local ok, cost
    if commodity then
      if type(house.CalculateCommodityDeposit) ~= "function" or not itemID then return end
      ok, cost = pcall(house.CalculateCommodityDeposit, itemID, duration, quantity)
    else
      if type(house.CalculateItemDeposit) ~= "function" then return end
      ok, cost = pcall(house.CalculateItemDeposit, location, duration, quantity)
    end
    if not ok or (secret and secret(cost)) or type(cost) ~= "number" or cost <= 0 then return end
    if type(house.SupportsCopperValues) == "function" then
      local fine, copper = pcall(house.SupportsCopperValues)
      if fine and copper == false then cost = math.ceil(cost / 100) * 100 end
    end
    return cost, itemID
  end

  -- Deposits waiting for their auction. A post's deposit is worked out at
  -- the hook and held here; it is added to the record (MM.NoteDeposit) only
  -- when the game says an auction was made (AUCTION_HOUSE_AUCTION_CREATED,
  -- MM.DepositCreated), the oldest waiting one for that item first, so
  -- several posts in a row each count once. One the game asks the player
  -- about first (AUCTION_HOUSE_POST_WARNING) waits as a question: no
  -- auction is credited to it until the confirm. Dropped, never counted:
  -- a question when a newer post is made (it was answered no), a post the
  -- game reports an error for, anything older than PENDING_AGE seconds, and
  -- all of them when the auction house closes. At most PENDING_MAX, in
  -- parallel arrays reused for the session: nothing is built per post.
  local PENDING_MAX, PENDING_AGE, FAIL_WINDOW = 16, 30, 5
  local qCost, qItem, qAt, qAsk = {}, {}, {}, {}
  local qN = 0
  -- A warning or error, by its frame's time (GetTime holds still through a
  -- frame): raised inside PostItem / PostCommodity, it is claimed by that
  -- call's hook in the same frame; one that arrives later is matched to the
  -- post before it the next time the queue is used (Settle).
  local warnedAt, failedAt = false, false

  local function Now() return type(GetTime) == "function" and GetTime() or 0 end

  local function QRemove(i)
    for j = i, qN - 1 do
      qCost[j], qItem[j], qAt[j], qAsk[j] = qCost[j + 1], qItem[j + 1], qAt[j + 1], qAsk[j + 1]
    end
    qN = qN - 1
  end

  local function QPush(cost, itemID, asking, now)
    if qN >= PENDING_MAX then QRemove(1) end
    qN = qN + 1
    qCost[qN], qItem[qN], qAt[qN], qAsk[qN] = cost, itemID or false, now, asking == true
  end

  -- Signals from an earlier frame settled against the posts made before
  -- them, and anything too old dropped.
  local function Settle(now)
    if warnedAt and warnedAt ~= now then
      for i = qN, 1, -1 do
        if qAt[i] <= warnedAt then qAsk[i] = true break end
      end
      warnedAt = false
    end
    if failedAt and failedAt ~= now then
      for i = qN, 1, -1 do
        if qAt[i] <= failedAt then
          if not qAsk[i] and failedAt - qAt[i] <= FAIL_WINDOW then QRemove(i) end
          break
        end
      end
      failedAt = false
    end
    local i = 1
    while i <= qN do
      if now - qAt[i] > PENDING_AGE or now < qAt[i] then QRemove(i) else i = i + 1 end
    end
  end

  function MM.PostWarned() warnedAt = Now() end
  function MM.PostFailed() failedAt = Now() end
  function MM.PostsClosed() qN, warnedAt, failedAt = 0, false, false end

  -- PostItem / PostCommodity's hook: the post's deposit, waiting.
  local function PostMade(commodity, location, duration, quantity)
    local now = Now()
    local asked, failed = warnedAt == now, failedAt == now
    if asked then warnedAt = false end
    if failed then failedAt = false end
    Settle(now)
    -- A question still standing was answered no: this is a new post.
    local i = 1
    while i <= qN do
      if qAsk[i] then QRemove(i) else i = i + 1 end
    end
    if failed then return end
    local cost, itemID = DepositOf(commodity, location, duration, quantity)
    if cost then QPush(cost, itemID, asked, now) end
  end

  -- ConfirmPostItem / ConfirmPostCommodity's hook: the question answered
  -- yes, its deposit waiting for the auction from now. Where no question
  -- was seen, a post of the same item and deposit already waiting is this
  -- one, so it is not held twice.
  local function PostConfirmed(commodity, location, duration, quantity)
    local now = Now()
    Settle(now)
    local cost, itemID = DepositOf(commodity, location, duration, quantity)
    for i = qN, 1, -1 do
      if qAsk[i] then
        qAsk[i], qAt[i] = false, now
        if cost then qCost[i], qItem[i] = cost, itemID or false end
        return
      end
    end
    if not cost then return end
    for i = qN, 1, -1 do
      if qCost[i] == cost and qItem[i] == (itemID or false) then
        qAt[i] = now
        return
      end
    end
    QPush(cost, itemID, false, now)
  end

  -- An auction the game made: the oldest deposit waiting for its item (or
  -- the oldest waiting, where the game cannot say which item), counted.
  function MM.DepositCreated(itemID)
    Settle(Now())
    itemID = tonumber(itemID)
    for i = 1, qN do
      if not qAsk[i] and (not itemID or qItem[i] == itemID) then
        local cost = qCost[i]
        QRemove(i)
        if MM.NoteDeposit then MM.NoteDeposit(cost) end
        return
      end
    end
  end

  local function ItemPosted(location, duration, quantity)
    pcall(Posted, location)
    pcall(PostMade, false, location, duration, quantity)
  end
  local function CommodityPosted(location, duration, quantity)
    pcall(Posted, location)
    pcall(PostMade, true, location, duration, quantity)
  end
  local function ItemConfirmed(location, duration, quantity)
    pcall(PostConfirmed, false, location, duration, quantity)
  end
  local function CommodityConfirmed(location, duration, quantity)
    pcall(PostConfirmed, true, location, duration, quantity)
  end

  -- Hooked once, the first time the auction house opens: nothing is hooked
  -- for a player who never uses it.
  local hooked = false
  function MM.WatchPosts()
    if hooked then return end
    local house = C_AuctionHouse
    if type(house) ~= "table" or type(hooksecurefunc) ~= "function" then return end
    hooked = true
    if type(house.PostItem) == "function" then hooksecurefunc(house, "PostItem", ItemPosted) end
    if type(house.PostCommodity) == "function" then hooksecurefunc(house, "PostCommodity", CommodityPosted) end
    if type(house.ConfirmPostItem) == "function" then hooksecurefunc(house, "ConfirmPostItem", ItemConfirmed) end
    if type(house.ConfirmPostCommodity) == "function" then
      hooksecurefunc(house, "ConfirmPostCommodity", CommodityConfirmed)
    end
  end

  -- An auction the client says was made (AUCTION_HOUSE_AUCTION_CREATED):
  -- its item, where the client can say what it was. Returns the item's id
  -- (for its deposit, MM.DepositCreated), or nil.
  function MM.PostCreated(auctionID)
    local house, api = C_AuctionHouse, C_Item
    if type(house) ~= "table" or type(house.GetAuctionInfoByID) ~= "function" then return end
    local ok, info = pcall(house.GetAuctionInfoByID, auctionID)
    local key = ok and type(info) == "table" and info.itemKey or nil
    local itemID = type(key) == "table" and tonumber(key.itemID) or nil
    if not itemID then return end
    local name = type(info.itemLink) == "string" and info.itemLink:match("|h%[(.-)%]|h") or nil
    if not name and type(api) == "table" and type(api.GetItemNameByID) == "function" then
      local got, n = pcall(api.GetItemNameByID, itemID)
      if got then name = n end
    end
    Note(itemID, name)
    return itemID
  end

  -- An item name -> the id of the item this character (else any on the
  -- account) last put up for auction under exactly that name, and the icon
  -- noted with it where one was (nil for a note without one), or nil.
  function MM.PostedItem(itemName)
    if type(itemName) ~= "string" or itemName == "" then return nil end
    local own = Posts(false)
    local note = own and own[itemName]
    if type(note) == "table" and tonumber(note.i) then return tonumber(note.i), tonumber(note.c) end
    local root = ns.Store and ns.Store.Get and ns.Store.Get("auctionPosts")
    if type(root) ~= "table" then return nil end
    for _, byRealm in pairs(root) do
      if type(byRealm) == "table" then
        for _, list in pairs(byRealm) do
          note = type(list) == "table" and list[itemName]
          if type(note) == "table" and tonumber(note.i) then return tonumber(note.i), tonumber(note.c) end
        end
      end
    end
    return nil
  end

  -- Every character's notes pruned (at login, with History), a character
  -- left with none dropped.
  function MM.PrunePosts()
    local root = ns.Store and ns.Store.Get and ns.Store.Get("auctionPosts")
    if type(root) ~= "table" then return end
    local now = time()
    for realm, byRealm in pairs(root) do
      if type(byRealm) == "table" then
        for name, list in pairs(byRealm) do
          if type(list) == "table" then Prune(list, now) end
          if type(list) ~= "table" or next(list) == nil then byRealm[name] = nil end
        end
        if next(byRealm) == nil then root[realm] = nil end
      end
    end
  end

  function MM.PostsGen() return postsGen end
end

-------------------------------------------------------------
-- 2f. Deposits paid
--
-- What posting auctions cost, for the options' 7-day card (MM.Week): no mail
-- ever says it. Each post's deposit (2e's hooks: the game's own answer for
-- that item, duration and quantity, held until the game says the auction
-- was made) is added to the hour it was paid in,
-- per character, at the root `auctionDeposits`, realm -> name -> a list of
-- hour, copper pairs, oldest first (hour = time / 3600, whole), and `s`, when
-- the record began (at the root for the account, set at login; in a list,
-- when that character's first deposit began it): the week reaches back past
-- the earlier, and the card says its deposits count from then. Not tied to any auction: "paid in the last
-- seven days" is a plain sum. Kept DEPOSITS_KEEP hours (a day more than
-- the week), so a list never holds more than that many pairs however many
-- auctions are posted. Written only while History is kept, and emptied with
-- it ("Never"); pruned at login with History.
-------------------------------------------------------------
do
  local HOUR, DEPOSITS_KEEP = 3600, 8 * 24

  local function Deposits(create)
    local realm, name = Me()
    if not (realm and name) then return nil end
    local root
    if create then
      root = ns.Store.EnsurePath("auctionDeposits")
    else
      root = ns.Store and ns.Store.Get and ns.Store.Get("auctionDeposits")
    end
    if type(root) ~= "table" then return nil end
    local byRealm = root[realm]
    if type(byRealm) ~= "table" then
      if not create then return nil end
      byRealm = {}
      root[realm] = byRealm
    end
    local list = byRealm[name]
    if type(list) ~= "table" then
      if not create then return nil end
      list = { s = time() }
      byRealm[name] = list
    end
    return list
  end

  -- Pairs older than DEPOSITS_KEEP hours dropped, the rest moved down.
  local function Prune(list, now)
    local keep = math.floor(now / HOUR) - DEPOSITS_KEEP
    local n, first = #list, 1
    while first < n and (tonumber(list[first]) or 0) < keep do first = first + 2 end
    if first == 1 then return end
    local j = 1
    for i = first, n do
      list[j] = list[i]
      j = j + 1
    end
    for i = j, n do list[i] = nil end
  end

  -- `copper` paid as a deposit, now.
  function MM.NoteDeposit(copper)
    copper = tonumber(copper)
    if not copper or copper <= 0 or HistoryKeep() <= 0 then return end
    local list = Deposits(true)
    if not list then return end
    local now = time()
    local h, n = math.floor(now / HOUR), #list
    if n >= 2 and list[n - 1] == h then
      list[n] = (tonumber(list[n]) or 0) + copper
    else
      list[n + 1], list[n + 2] = h, copper
    end
    Prune(list, now)
    MM.recordWrites = MM.recordWrites + 1
  end

  -- At login: every character's record pruned, and the record begun (`s` at
  -- the root, beside the realms) where it has not been, so deposits count
  -- from this account's first run of this; with History off, none kept. No
  -- character's record is made here: one is begun by its first deposit.
  function MM.PruneDeposits()
    local root = ns.Store and ns.Store.Get and ns.Store.Get("auctionDeposits")
    if HistoryKeep() <= 0 then
      if type(root) == "table" then
        for realm in pairs(root) do root[realm] = nil end
      end
      return
    end
    root = ns.Store.EnsurePath("auctionDeposits")
    if type(root) ~= "table" then return end
    if not tonumber(root.s) then root.s = time() end
    local now = time()
    for _, byRealm in pairs(root) do
      if type(byRealm) == "table" then
        for _, list in pairs(byRealm) do
          if type(list) == "table" then Prune(list, now) end
        end
      end
    end
  end
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

-- realm, name [, noRealm [, ground]] -> the name in its class colour (plain
-- where the class is not known), and the realm after it, quieter, when it is
-- not the one being played -- unless `noRealm`: where a box is already on
-- screen, picked from a list that named the realm, the name alone says
-- whose. `ground`: where the name is read when not on the lists -- "tooltip"
-- for a tooltip, which stays dark in Light mode: both colours are inked for
-- it (Theme section 2c).
function MM.ClassName(realm, name, noRealm, ground)
  local text = tostring(name or "")
  -- Forever: no ruleset after a full name, and the player's own as they
  -- have chosen to see it.
  local forever = ns.Helpers.TwoPartNames()
  if forever then text = ns.Helpers.ShownName(text) end
  local CS = ns.ContactService
  local token = ClassOf(realm, name)
  if token and CS and CS.WrapClass then text = CS.WrapClass(token, text, ground) end
  if not noRealm and not forever and realm and realm ~= ns.Helpers.PlayerRealm() then
    text = text .. " " .. ns.Theme.Colorize("textSecondary", "- " .. realm, ground)
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

-------------------------------------------------------------
-- 3c'. Class icons
--
-- One place decides how a character's class is drawn wherever the
-- switcher shows one: the Inbox button's cap on the Mail tab, Mail Memory's
-- own plate, each row of the character list both open, and the heading
-- over a character's matches in a search of every box (MM.FillRow). The
-- style is the player's choice (Options > Window, "Class icons";
-- profile.classIcons, UI.GetClassIcons):
--   game      the game's ability-style class icons,
--             Interface\Icons\ClassIcon_*, cropped as an item's icon is
--             (the default; until 1.70 "Game: square", whose saved id
--             "square" reads as game)
--   round     the game's gold-ringed portraits, UI-Classes-Circles cut
--             with CLASS_ICON_TCOORDS
--   painted, pixel, comic, glyphs
--             Postbox's own sheets (Media/ClassIcons), 4 x 4 cells in
--             SHEET_CELL's order; glyphs is white art worn in the class
--             colour the names in the list wear (ContactService)
--   eui:<s>   one of EllesmereUI's class icon sets, only while EllesmereUI
--             is loaded: the sheet path, the style list and each class's
--             cell are asked of EllesmereUI itself (EUI below), so Postbox
--             carries none of its art or data and follows its updates.
-- A style the client cannot draw for a character's class (Game included,
-- where the client has no ClassIcon_ file for it) draws that one in the
-- game's class crest (MM.ClassIcon's atlas; on a cap cropped, MM.SetCrest);
-- a saved style that is not offered now (EllesmereUI not
-- loaded) is read as game and left as saved, so it returns with it. A
-- character whose class is not known wears the generic figure in every
-- style. Every answer is kept per class the first time it is worked out:
-- a repaint makes no tables and no strings.
-------------------------------------------------------------
do
  local Icons = {}
  MM.Icons = Icons

  local SHEET_DIR = "Interface\\AddOns\\Postbox\\Media\\ClassIcons\\"
  -- Postbox's own sheets. `cell`: the art's box inside a cell of the sheet,
  -- as a share of the cell: the art fills that box, the gutter round it
  -- keeps the next cell's texels out of the small mips. comic and glyphs:
  -- 58 of 64 texels; pixel: 28 of 32, one texel an art pixel; painted: 52
  -- of 64, cut past the frame its pictures were painted with (three texels
  -- of it inside the gutter), so the icon shows the picture, not a frame
  -- inside whatever border the look gives it.
  -- Each is drawn from its box, so the art runs to the icon's edges as the
  -- game's crest does, and sampled with the client's own filtering and mip
  -- chain (no filter given): pixel's sheet is the art's own 32 x 32 grid per
  -- cell, so at 18 and 22 it is softened evenly rather than having single
  -- art pixels dropped or doubled, as NEAREST would.
  local SHEETS = {
    painted = { file = SHEET_DIR .. "painted.tga", gutter = 6 / 64 },
    pixel   = { file = SHEET_DIR .. "pixel.tga",   gutter = 2 / 32 },
    comic   = { file = SHEET_DIR .. "comic.tga",   gutter = 3 / 64 },
    glyphs  = { file = SHEET_DIR .. "glyphs.tga",  gutter = 3 / 64, tint = true },
  }
  local SHEET_CELL = {
    WARRIOR = 0, PALADIN = 1, HUNTER = 2, ROGUE = 3, PRIEST = 4, DEATHKNIGHT = 5, SHAMAN = 6, MAGE = 7,
    WARLOCK = 8, MONK = 9, DRUID = 10, DEMONHUNTER = 11, EVOKER = 12,
  }
  -- The order the option lists them in; EllesmereUI's after these. None,
  -- the last of Postbox's own: no class icon anywhere, the names in their
  -- class colours alone, and every place that kept the icon's room gives it
  -- back (Icons.Off).
  Icons.ORDER = { "game", "round", "painted", "pixel", "comic", "glyphs", "none" }
  Icons.NAMES = {
    game = "CLASS_ICONS_GAME", round = "CLASS_ICONS_ROUND",
    painted = "CLASS_ICONS_PAINTED", pixel = "CLASS_ICONS_PIXEL", comic = "CLASS_ICONS_COMIC",
    glyphs = "CLASS_ICONS_GLYPHS", none = "CLASS_ICONS_NONE",
  }
  -- None's item in the option's list: no art, its square kept empty, so
  -- its name starts where the others' names do (Lib/UI/Dropdown.lua).
  local NONE_SPEC = { blank = true }

  -- The game's art. The portraits' sheet and the class icons' folder (Game);
  -- a class icon is cropped as an item's icon is (MM.CREST_CROP), its own
  -- frame cut away, the same on a cap, a list's row and the option's items.
  local CIRCLES = "Interface\\TargetingFrame\\UI-Classes-Circles"
  local SQUARE_DIR = "Interface\\Icons\\ClassIcon_"

  -- Whether the client holds a file: its file id, where the client can say
  -- (the way Arrange's coin is looked up). Without the API, nothing is
  -- claimed.
  local function HasFile(path)
    if type(GetFileIDFromPath) ~= "function" then return false end
    local ok, id = pcall(GetFileIDFromPath, path)
    return ok and type(id) == "number" and id > 0
  end

  -- Per class, worked out once: the crest's atlas (false where none), the
  -- class icon's path (false where the client has no such file).
  local crestOf, squareOf = {}, {}
  local fallback
  local function Crest(token)
    if not token then
      if fallback == nil then fallback = ns.Theme.FirstAtlas(CLASS_FALLBACK) or false end
      return fallback or nil
    end
    local atlas = crestOf[token]
    if atlas == nil then
      local H = ns.Helpers
      local lower = (H and H.Lower) and H.Lower(token) or token
      atlas = ns.Theme.FirstAtlas({ "classicon-" .. lower, "groupfinder-icon-class-" .. lower }) or false
      crestOf[token] = atlas
    end
    if atlas then return atlas end
    return Crest(nil)
  end
  local function Square(token)
    local path = squareOf[token]
    if path == nil then
      path = SQUARE_DIR .. token
      if not HasFile(path) then path = false end
      squareOf[token] = path
    end
    return path or nil
  end
  local circlesHeld
  local function Round(token)
    local all = CLASS_ICON_TCOORDS
    local c = type(all) == "table" and all[token] or nil
    if type(c) ~= "table" or type(c[4]) ~= "number" then return nil end
    if circlesHeld == nil then circlesHeld = HasFile(CIRCLES) end
    return circlesHeld and c or nil
  end

  -- EllesmereUI, asked at run time: its class -> cell table
  -- (EllesmereUI.CLASS_ICON_SPRITE_COORDS, { left, right, top, bottom } per
  -- class file, shared by every EllesmereUI module) and its Class Icon
  -- Theme list and sheet paths (EllesmereUI.FriendsKit: ICON_STYLE_ORDER,
  -- ICON_STYLE_VALUES, ClassIconSprite). nil while any of it is missing.
  local EUI = {}
  function EUI.Get()
    local eui = _G.EllesmereUI
    if type(eui) ~= "table" then return nil end
    local coords, kit = eui.CLASS_ICON_SPRITE_COORDS, eui.FriendsKit
    if type(coords) ~= "table" or type(kit) ~= "table" or type(kit.ClassIconSprite) ~= "function"
        or type(kit.ICON_STYLE_ORDER) ~= "table" then
      return nil
    end
    return coords, kit
  end
  -- An EllesmereUI style's sheet, as EllesmereUI names it, kept once: a
  -- path into EllesmereUI's own folder, or false. "blizzard" is the game's
  -- art, not a sheet of EllesmereUI's.
  local euiPath = {}
  function EUI.Path(style, kit)
    local path = euiPath[style]
    if path == nil then
      path = false
      if style ~= "blizzard" then
        local ok, p = pcall(kit.ClassIconSprite, style)
        if ok and type(p) == "string" and p:lower():find("^interface\\addons\\ellesmereui\\") then path = p end
      end
      euiPath[style] = path
    end
    return path or nil
  end
  -- "eui:<style>" -> <style>, once per id seen; false for any other id.
  local euiStyleOf = {}
  function EUI.StyleOf(id)
    local s = euiStyleOf[id]
    if s == nil then
      s = (type(id) == "string" and id:sub(1, 4) == "eui:" and #id > 4) and id:sub(5) or false
      euiStyleOf[id] = s
    end
    return s
  end
  -- Whether EllesmereUI lists `style` now.
  function EUI.Lists(kit, style)
    local order = kit.ICON_STYLE_ORDER
    for i = 1, #order do
      if order[i] == style then return true end
    end
    return false
  end

  -- The style saved, as it can be drawn now: the id, and for an
  -- EllesmereUI one its style and sheet. A style not on offer reads as game,
  -- "square" (Game: square until 1.70, now Game's own art) among them.
  local function Current()
    local UI = ns.MailboxUI
    local id = UI and UI.GetClassIcons and UI.GetClassIcons() or "game"
    if SHEETS[id] or id == "round" or id == "none" then return id end
    local style = EUI.StyleOf(id)
    if style then
      local _, kit = EUI.Get()
      local path = kit and EUI.Lists(kit, style) and EUI.Path(style, kit)
      if path then return id, style, path end
    end
    return "game"
  end
  Icons.Current = Current

  -- Whether None is chosen: no class icon anywhere, and no room kept for
  -- one (the plates' cap, the character list's rows).
  function Icons.Off()
    return Current() == "none"
  end

  -- style id, class file -> how that class is drawn in that style:
  --   "atlas", atlas
  --   "file", file, left, right, top, bottom, tinted
  -- The game's crest where the style has nothing for the class (Game too,
  -- where the client has no ClassIcon_ file for it) or the class is unknown.
  local function Resolve(id, token, euiStyle, euiFile)
    if token then
      local sheet = SHEETS[id]
      if sheet then
        local cell = SHEET_CELL[token]
        if cell then
          local g = sheet.gutter / 4
          local l, t = (cell % 4) / 4, math.floor(cell / 4) / 4
          return "file", sheet.file, l + g, l + 0.25 - g, t + g, t + 0.25 - g, sheet.tint
        end
      elseif id == "round" then
        local c = Round(token)
        if c then return "file", CIRCLES, c[1], c[2], c[3], c[4], false end
      elseif id == "game" then
        local path = Square(token)
        if path then
          local k = MM.CREST_CROP
          return "file", path, k, 1 - k, k, 1 - k, false
        end
      elseif euiFile then
        local coords = EUI.Get()
        local c = coords and coords[token]
        if type(c) == "table" and type(c[4]) == "number" then
          return "file", euiFile, c[1], c[2], c[3], c[4], false
        end
      end
    end
    return "atlas", Crest(token)
  end

  -- texture, class file [, size [, how]] -> the texture wears that class's
  -- icon in the chosen style: its file or atlas, its crop, its colour.
  -- `size`: the size it is drawn at (one sheet serves every size today).
  -- `how`: nil, a list's icon (the crest, where it is the fallback, whole);
  -- "cap", a plate's portrait cap (the crest cropped, MM.SetCrest; its
  -- colour is the cap's to paint, MM.PaintPickIcon, which multiplies in the
  -- tint kept here); "muted", a hidden character's row (a tinted style
  -- white, so the row's grey reads as grey). Builds nothing.
  -- Returns whether there is an icon to show: false with None, which leaves
  -- the texture empty and holding nothing a later style could trip on (no
  -- file or atlas kept, no colour), for its caller to hide.
  function Icons.Apply(tex, token, size, how)
    if not tex then return false end
    if token == "" then token = nil end
    local id, euiStyle, euiFile = Current()
    if id == "none" then
      tex.__pbIconFile, tex.__pbAtlas = nil, nil
      tex:SetTexture(nil)
      if how == "cap" then
        tex.__pbTintR, tex.__pbTintG, tex.__pbTintB = 1, 1, 1
      elseif tex.__pbIconTinted then
        tex.__pbIconTinted = nil
        tex:SetVertexColor(1, 1, 1)
      end
      return false
    end
    local kind, file, l, r, t, b, tinted = Resolve(id, token, euiStyle, euiFile)
    local tr, tg, tb = 1, 1, 1
    if kind == "atlas" then
      tex.__pbIconFile = nil
      if how == "cap" then
        if file then MM.SetCrest(tex, file) end
      else
        tex.__pbAtlas = nil
        if file then MM.WearAtlas(tex, file, 0) else tex:SetTexture(nil) end
      end
    else
      -- SetCrest keeps the atlas it set; another file is not it.
      tex.__pbAtlas = nil
      if tex.__pbIconFile ~= file then
        tex.__pbIconFile = file
        tex:SetTexture(file)
      end
      tex:SetTexCoord(l, r, t, b)
      if tinted and how ~= "muted" then
        local CS = ns.ContactService
        local cr, cg, cb
        if CS and CS.ClassColour then cr, cg, cb = CS.ClassColour(token) end
        if cr then tr, tg, tb = cr, cg, cb end
      end
    end
    if how == "cap" then
      -- The cap's painter multiplies these in (MM.PaintPickIcon).
      tex.__pbTintR, tex.__pbTintG, tex.__pbTintB = tr, tg, tb
    elseif tr ~= 1 or tg ~= 1 or tb ~= 1 then
      tex.__pbIconTinted = true
      tex:SetVertexColor(tr, tg, tb)
    elseif tex.__pbIconTinted then
      tex.__pbIconTinted = nil
      tex:SetVertexColor(1, 1, 1)
    end
    return true
  end

  -- texture -> another painter is about to draw on it (a row that was a
  -- character's heading and is now a mail, MM.FillRow): what Apply kept of
  -- it no longer holds. Without this, the row's next turn as a heading in
  -- the same sheet style would skip setting the sheet and cut its cell out
  -- of the mail's icon, and a tinted style's colour would stay on the mail.
  function Icons.Release(tex)
    tex.__pbIconFile, tex.__pbAtlas = nil, nil
    if tex.__pbIconTinted then
      tex.__pbIconTinted = nil
      tex:SetVertexColor(1, 1, 1)
    end
  end

  -- The styles the client can draw now for the class of the character being
  -- played, in the option's order: ids, EllesmereUI's as "eui:<style>".
  -- For the options, when their page is built.
  function Icons.Styles()
    local out = {}
    local _, token = UnitClass("player")
    for i = 1, #Icons.ORDER do
      local id = Icons.ORDER[i]
      local ok = true
      if id == "round" then ok = token ~= nil and Round(token) ~= nil end
      if ok then out[#out + 1] = id end
    end
    local coords, kit = EUI.Get()
    if kit and token and type(coords[token]) == "table" then
      local order = kit.ICON_STYLE_ORDER
      for i = 1, #order do
        local style = order[i]
        if type(style) == "string" and EUI.Path(style, kit) then out[#out + 1] = "eui:" .. style end
      end
    end
    return out
  end

  -- id -> the style's name in the option's list.
  function Icons.Name(id)
    local key = Icons.NAMES[id]
    if key then return L[key] end
    local style = EUI.StyleOf(id)
    if style then
      local _, kit = EUI.Get()
      local names = kit and kit.ICON_STYLE_VALUES
      local name = type(names) == "table" and names[style] or nil
      return string.format(L["CLASS_ICONS_EUI"], type(name) == "string" and name or style)
    end
    return tostring(id)
  end

  -- id, class file -> the art a dropdown item shows for that style
  -- (Lib/UI/Dropdown.lua: texture or atlas, coords, color).
  function Icons.Spec(id, token)
    if id == "none" then return NONE_SPEC end
    local style = EUI.StyleOf(id)
    local _, kit = EUI.Get()
    local path = style and kit and EUI.Path(style, kit) or nil
    local kind, file, l, r, t, b, tinted = Resolve(id, token, style, path)
    if kind == "atlas" then return file and { atlas = file } or nil end
    local spec = { texture = file, coords = { l, r, t, b } }
    if tinted then
      local CS = ns.ContactService
      local cr, cg, cb
      if CS and CS.ClassColour then cr, cg, cb = CS.ClassColour(token) end
      if cr then spec.color = { cr, cg, cb } end
    end
    return spec
  end

  -- The choice changed: every place that wears a class icon, painted again
  -- at once -- the open character list, Mail Memory's window, the Mail
  -- tab's Inbox cap.
  function Icons.Changed()
    local list = MM._picker
    if list and list:IsShown() and MM.RepaintPicker then MM.RepaintPicker(list) end
    if MM.Refresh then MM.Refresh() end
    local UI = ns.MailboxUI
    if UI and type(UI.RefreshMemoryState) == "function" then UI.RefreshMemoryState() end
  end
end

-- texture, realm, name [, size [, how]] -> that character's class icon on
-- the texture, in the chosen style (MM.Icons.Apply). -> whether it has one
-- to show (false with None).
function MM.PaintClassIcon(tex, realm, name, size, how)
  return MM.Icons.Apply(tex, ClassOf(realm, name), size, how)
end

-- picker, realm, name -> the picker's cap wears that character's class icon
-- (nil, nil: the generic figure), painted with the cap's own colour; with
-- None, no cap (its room is given back where the plate is hosted,
-- MM.HostPick).
function MM.PaintCap(zone, realm, name)
  if not (zone and zone.Icon) then return end
  zone.Icon:SetShown(MM.Icons.Apply(zone.Icon, realm and ClassOf(realm, name) or nil, zone.lead, "cap"))
  MM.PaintPickIcon(zone)
end

-- mail -> the icon its row shows: the first item's own, as the Mail tab's
-- row has it. A record saved before the capture kept that icon (it has no
-- `it`, its list of items) holds the header's package icon, which for a mail
-- of several items is a generic crate; where it kept the item's link, the
-- icon is the item's, by that link. A number either way: nothing is made.
function MM.MailIcon(mail)
  -- A sold auction's gold: the item that sold, where it can be told
  -- (CollectTab, CT.SoldIcon, kept by its subject), else the coin.
  if mail.kind == "sold" and (mail.items or 0) == 0 then
    local CT = ns.CollectTab
    local icon = CT and type(CT.SoldIcon) == "function" and CT.SoldIcon(mail.subject) or nil
    if icon then return icon end
  end
  if mail.it == nil and mail.link and C_Item and type(C_Item.GetItemIconByID) == "function" then
    local icon = C_Item.GetItemIconByID(mail.link)
    if icon then return icon end
  end
  return mail.icon
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

-- row, k -> what the row's mail held k-th, from the snapshot's list: its
-- icon, its name, its quality, its crafting mark and a link for it -- the
-- first item's own link where the snapshot kept it, the item's by id
-- otherwise, so a tiered reagent still wears its tier. Its count is the
-- list's. Asked on hover, never on a bind.
function MM.ItemFacts(row, k)
  local list = row.itemList
  local id = list and list[2 * k - 1]
  if not id then return nil end
  local own = (k == 1) and row.itemLink or nil
  local name, generic, quality
  if C_Item and type(C_Item.GetItemInfo) == "function" then name, generic, quality = C_Item.GetItemInfo(id) end
  local link = own or generic
  if not name and type(link) == "string" then
    name = link:match("|h%[(.-)%]|h")
    if name then name = name:gsub("%s*|A:.-|a", "") end
  end
  if not quality and C_Item and type(C_Item.GetItemQualityByID) == "function" then
    quality = C_Item.GetItemQualityByID(id)
  end
  local icon = (C_Item and type(C_Item.GetItemIconByID) == "function") and C_Item.GetItemIconByID(id) or nil
  local R = Rules()
  local mark = R and R.QualityMark and R.QualityMark(link) or nil
  return icon, name, quality, mark, link
end

-- row, tile, dress -> where what the row's mail held can be taken: at the
-- mailbox of the character whose box it is, named, or at a mailbox, for the
-- one being played. `tile`: a fan tile's line, which adds the link gesture,
-- and the try-on where `dress` (an item there is something to try on). A
-- tooltip's hint: the name inked for the tooltip.
function MM.TakeHint(row, tile, dress)
  local myRealm, myName = Me()
  local realm, name = row.boxRealm or myRealm, row.boxName
  local on = name and not (name == myName and realm == myRealm)
  if tile then
    if on then return L(dress and "MEMORY_TILE_ON_DRESS" or "MEMORY_TILE_ON", MM.ClassName(realm, name, true, "tooltip")) end
    return L[dress and "MEMORY_TILE_HERE_DRESS" or "MEMORY_TILE_HERE"]
  end
  if on then return L("MEMORY_TAKE_ON", MM.ClassName(realm, name, true, "tooltip")) end
  return L["MEMORY_TAKE_HERE"]
end

-- R, row[, withRead] -> the State fact of a remembered mail (the rules'
-- TipState): stuck as the snapshot recorded it, with the possibilities for
-- a reason, as the Mail tab says it; and, for the row's own tooltip
-- (`withRead`), read or unread while the read mark's column is hidden.
local function TipState(R, row, withRead)
  if not (R and R.TipState) then return end
  local mail = row.mail
  local unread
  if withRead and R.Shows and not R.Shows("read") then unread = not (mail.read and not mail.pending) end
  R.TipState(row.stuck and true or nil, unread)
end

-- owner, row -> the tooltip of the icon of a remembered mail that held
-- several items, as the Mail tab's icon has one (RV.ItemsTooltip): how
-- many, one line per item in the Mail tab's own words (the rules'
-- ItemLine), the gold and the C.O.D. price, why it is stuck, and where it
-- can be taken. Whether there was a list to show.
function MM.ItemsTooltip(owner, row)
  local R = Rules()
  local T = ns.Theme
  local mail = row.mail
  if not (mail and row.itemList and R and R.ItemLine) then return false end
  T.TipBegin(owner)
  T.TipTitle(ns.Plural("COUNT_ITEMS", row.iconItems))
  local list = row.itemList
  for k = 1, row.iconItems do
    local icon, name, quality, mark = MM.ItemFacts(row, k)
    R.ItemLine(icon, name, quality, mark, list[2 * k])
  end
  if R.MoneyFacts then R.MoneyFacts(tonumber(mail.money) or 0, tonumber(mail.cod) or 0) end
  TipState(R, row)
  T.TipHint(MM.TakeHint(row))
  GameTooltip:Show()
  return true
end

-- The Holds line's pieces, filled and joined once per hover.
local tipHolds = {}

-- row[, owner] -> the tooltip of a remembered mail's row, in the Mail tab
-- rows' format (CollectTab's RV.RowTip): the subject; From, where the row
-- shows less of the sender; Holds, what the snapshot says it held; the
-- price a won auction cost, where the row does not show it; Time left,
-- where the row does not; State; then where it can be collected. Read
-- from the record on hover; a bind makes no string for it. Whether there
-- was a mail to describe.
function MM.RowTip(row, owner)
  local mail = row.mail
  local R = Rules()
  if not (mail and R and R.TipItem) then return false end
  local T = ns.Theme
  T.TipBegin(owner or row)
  local subject = mail.subject
  local named = (mail.sender ~= "" and mail.sender) or nil
  local title = (subject and subject ~= "") and subject or named or L["MEMORY_SENDER_UNKNOWN"]
  T.TipTitle(title)
  -- A mail the box had returned to it (MM.ReturnRecord), whether or not the
  -- row's time column shows it so.
  if mail.returned then
    T.TipLine(T.TipTone("muted", (R.ReturnedTip and R.ReturnedTip()) or L["STATUS_RETURNED"]))
  end

  if named and (not R.Shows("sender") or row.tipShort or row.Sender.__pbOverflowText) then
    T.TipFact(L["TIP_FROM"], R.TipSender(named, row.boxRealm))
  end

  -- Holds: the stacks the snapshot listed (the first item's own link and
  -- the slot count, on a record saved before it kept a list), unless the
  -- one stack is the one an auction's subject names; the gold unless the
  -- row shows exactly that; the C.O.D. price.
  local buf = tipHolds
  for i = #buf, 1, -1 do buf[i] = nil end
  local stacks = row.iconItems > 0 and row.iconItems or (tonumber(mail.items) or 0)
  local first
  if stacks == 1 and subject and R.IsAuction and R.IsAuction(mail.kind) then
    local _, name = MM.ItemFacts(row, 1)
    if not name and type(mail.link) == "string" then name = mail.link:match("|h%[(.-)%]|h") end
    first = name and name:gsub("%s*|A:.-|a", "")
  end
  if stacks > 0 and not (first and subject:find(first, 1, true)) then
    if row.iconItems > 0 then
      local list = row.itemList
      for k = 1, math.min(row.iconItems, R.TIP_ITEMS) do
        local _, name, quality, mark = MM.ItemFacts(row, k)
        R.TipItem(buf, name, quality, mark, list[2 * k])
      end
      R.TipMore(buf, row.iconItems - R.TIP_ITEMS)
    elseif type(mail.link) == "string" then
      local name = mail.link:match("|h%[(.-)%]|h")
      name = name and name:gsub("%s*|A:.-|a", "")
      local quality = C_Item and type(C_Item.GetItemQualityByID) == "function" and mail.id
        and C_Item.GetItemQualityByID(mail.id) or nil
      R.TipItem(buf, name, quality, R.QualityMark and R.QualityMark(mail.link) or nil, mail.count)
      R.TipMore(buf, stacks - 1)
    end
  end
  local money, cod = tonumber(mail.money) or 0, tonumber(mail.cod) or 0
  local moneyOnRow = row.ColMoney:IsShown()
  local goldShown
  if money > 0 and moneyOnRow and R.MoneyShown("earned") then
    goldShown = ns.Core.Formatting.FormatMoneyCompact(money, true)
  end
  R.TipMoney(buf, money, cod, goldShown)
  if #buf > 0 then T.TipFact(L["TIP_HOLDS"], table.concat(buf)) end

  -- What a won auction cost, where the row does not show it.
  local paid = tonumber(mail.paid) or 0
  if paid > 0 and money == 0 and cod == 0 and not (moneyOnRow and R.MoneyShown("spent")) then
    T.TipFact(L["LABEL_PURCHASE"], T.TipTone("negative", ns.Helpers.FormatMoney(paid)))
  end

  -- Time left, where the row does not show it; past its date, "expired".
  local expiry = row.expiryTip
  if expiry and not row.ColTime:IsShown() then
    local left = (tonumber(mail.expires) or 0) - time()
    local warn = left <= 0
    if not warn and R.ExpiryState then
      local _, short = R.ExpiryState(left / 86400, cod > 0)
      warn = short
    end
    T.TipFact(L["TIP_TIME_LEFT"], warn and T.TipTone("warning", expiry) or expiry)
  end

  -- On expiry: what the server does with it, as the visit recorded it, on
  -- a mail that held gold or items; past its date, what it did. A record
  -- from before the visits asked says nothing (mail.back nil).
  if mail.back ~= nil and R.TipFate and (money > 0 or (tonumber(mail.items) or 0) > 0) then
    local past = (tonumber(mail.expires) or 0) <= time()
    R.TipFate(mail.back and "back" or "gone", named and R.DisplaySender(named) or nil, past)
  end

  TipState(R, row, true)
  T.TipHint(MM.TakeHint(row))
  GameTooltip:Show()
  return true
end

-- The fan over a remembered mail (CollectTab.lua, "The fan"), where the
-- player chose it: the tiles of what the snapshot says the mail held, the
-- gold first. Read-only: a record, often of another character's box, holds
-- nothing to take. A plain click does nothing; Shift-click links and
-- Ctrl-click tries on, as on any item (the fan's own TileClick); each
-- tile's tooltip says where it can be taken. A row whose mail held a list
-- carries this table as its `fanSource`: the fan asks it, never the inbox.
MM.FanSource = {}

-- row -> whether a fan may stand over it: not while the arrange mode is
-- open, whose Preview mail these rows may be showing.
function MM.FanSource.Allowed(row)
  local A = ns.Arrange
  return row.mail ~= nil and not (A and A.host)
end

-- row -> the list it stands in: its rows are children of the scroll
-- frame's child, in this window and on the Mail tab alike.
function MM.FanSource.Scroll(row)
  local child = row:GetParent()
  return child and child:GetParent() or nil
end

-- row -> the mail's gold, its C.O.D. price and how many items it held.
function MM.FanSource.Totals(row)
  local mail = row.mail
  return tonumber(mail.money) or 0, tonumber(mail.cod) or 0, row.iconItems
end

-- row, k -> the k-th item's icon, count and crafting mark.
function MM.FanSource.Item(row, k)
  local icon, _, _, mark = MM.ItemFacts(row, k)
  return icon, row.itemList[2 * k], mark
end

-- row, k -> a link for the k-th item, for a modified click.
function MM.FanSource.Link(row, k)
  local _, _, _, _, link = MM.ItemFacts(row, k)
  return link
end

-- row, k -> the tooltip being built for the k-th item's tile (nil: the
-- gold's), after the fan's TipBegin: the item's own, by the link the
-- snapshot kept or by its id, or the gold's sum; the stuck state where the
-- mail was refused; and where it can be taken, with the tile's gestures.
function MM.FanSource.TileTip(row, k)
  local T = ns.Theme
  local mail = row.mail
  if not k then
    T.TipTitle(L["LABEL_GOLD"] .. ns.Helpers.FormatMoney(tonumber(mail.money) or 0))
    T.TipHint(MM.TakeHint(row))
    return
  end
  local own = (k == 1) and row.itemLink or nil
  local id = row.itemList and row.itemList[2 * k - 1]
  if own then
    GameTooltip:SetHyperlink(own)
  elseif id and type(GameTooltip.SetItemByID) == "function" then
    GameTooltip:SetItemByID(id)
  end
  local R = Rules()
  TipState(R, row)
  T.TipHint(MM.TakeHint(row, true, R and R.Dressable and R.Dressable(id) or false))
end

-- parent -> a row for the pool; the caller places it.
function MM.NewRow(parent)
  local T = ns.Theme
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(ROW_HEIGHT)
  -- How many items the bound mail held, as the snapshot listed them (FillRow).
  row.iconItems = 0
  -- A compact row, whose fan's tiles are the compact rows' (the fan's
  -- Fan.TILE).
  row._compact = true

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
  -- Its soft shadow, as the Mail tab's rows have it (RV.Place shows it).
  if Rules() and Rules().ShadeDot then Rules().ShadeDot(row) end

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

  -- The same marker the mail list puts on a refused mail, from the same art
  -- and at its size, in the same place: centred on the read mark, which it
  -- stands in for (the rules' PaintDot; the placement shows it).
  local atlas = WarningAtlas()
  if atlas then
    row.Warning = row:CreateTexture(nil, "OVERLAY")
    row.Warning:SetAtlas(atlas, false)
    local size = (Rules() and Rules().WARNING) or 11
    row.Warning:SetSize(size, size)
  else
    row.Warning = T.CreateText(row, "value")
    row.Warning:SetText("!")
  end
  row.Warning:SetPoint("CENTER", row.Indicator, "CENTER", 0, 0)
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

  -- The row says what the mail was in the Mail tab rows' format (MM.RowTip),
  -- as a hover target that takes motion and never clicks: this window is
  -- dragged from anywhere on it, and on the Mail tab the list under it takes
  -- the clicks. Lit under the pointer, as a Mail tab row is.
  HoverOnly(row)
  row:SetScript("OnEnter", function(self)
    if not self.mail then return end
    ns.Theme.StyleMailRow(self, self._rowIndex, true)
    MM.RowTip(self)
  end)
  row:SetScript("OnLeave", function(self)
    if self._rowIndex then ns.Theme.StyleMailRow(self, self._rowIndex, false) end
    GameTooltip:Hide()
  end)

  -- The icon says what the mail held. A mail that held several items lists
  -- them, as the Mail tab's icon does (MM.ItemsTooltip); one item shows its
  -- own tooltip, where the snapshot kept its link or id; anything else the
  -- row's own tooltip. Each ends where it can be collected.
  local hit = CreateFrame("Frame", nil, row)
  hit:SetPoint("TOPLEFT", row.Icon, "TOPLEFT", -2, 2)
  hit:SetPoint("BOTTOMRIGHT", row.Icon, "BOTTOMRIGHT", 2, -2)
  HoverOnly(hit)
  hit:SetScript("OnEnter", function(self)
    -- A child that takes the mouse ends the row's own hover: its light is
    -- put back, as on a Mail tab row.
    if row.mail then ns.Theme.StyleMailRow(row, row._rowIndex, true) end
    -- Where the player chose the fan and it may open here, it opens after a
    -- rest instead, and nothing shows before it (the fan's own rules).
    if row.iconItems > 1 then
      local R = Rules()
      if R and R.FanHover and R.FanHover(row) then return end
      if MM.ItemsTooltip(self, row) then return end
    end
    local T = ns.Theme
    local item = row.itemLink or (row.itemID and type(GameTooltip.SetItemByID) == "function")
    if not item then
      MM.RowTip(row, self)
      return
    end
    T.TipBegin(self)
    if row.itemLink then GameTooltip:SetHyperlink(row.itemLink) else GameTooltip:SetItemByID(row.itemID) end
    -- A mail the server refused, as it was remembered: its mark in the row
    -- is the read mark's, and the arrangement may hide that.
    TipState(Rules(), row)
    T.TipHint(MM.TakeHint(row))
    GameTooltip:Show()
  end)
  hit:SetScript("OnLeave", function()
    if row.mail and row._rowIndex then ns.Theme.StyleMailRow(row, row._rowIndex, false) end
    GameTooltip:Hide()
    -- A rest ends; an open fan's grace begins.
    local R = Rules()
    if R and R.FanLeave then R.FanLeave(row) end
  end)
  row.IconHit = hit

  -- A character's name heading its matches in a search of every box: a
  -- click opens that box.
  row.HeaderHit = CreateFrame("Button", nil, row)
  row.HeaderHit:SetAllPoints()
  row.HeaderHit:RegisterForClicks("LeftButtonUp")
  row.HeaderHit:SetScript("OnClick", function(self)
    local owner = self:GetParent()
    -- No other box opens under a list whose columns are being arranged.
    local arrange = ns.Arrange
    if arrange and arrange.host then return end
    if owner.onHeader then owner.onHeader(owner.headerRealm, owner.headerName) end
  end)
  row.HeaderHit:SetScript("OnEnter", function(self)
    local owner = self:GetParent()
    local T = ns.Theme
    T.StyleMailRow(owner, owner._rowIndex, true)
    -- Whose matches these are, and what the heading does: nothing on it
    -- looks like a button.
    T.TipBegin(self)
    T.TipTitle(MM.ClassName(owner.headerRealm, owner.headerName, nil, "tooltip"))
    T.TipHint(L["MEMORY_HEADER_TIP"])
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

-- mail, now, fs -> the row's three figures as coloured text (or nil each),
-- what the switches keep off the row for its tooltip, and the time-left
-- line. `fs`: the string the time is drawn in, which sizes its expiry mark.
local function Figures(mail, now, fs)
  local R = Rules()
  local T = ns.Theme
  local hasCOD = (mail.cod or 0) > 0
  local money, moneyKind
  -- With coins where the Mail tab's rows have them (they share an
  -- arrangement), made for `fs`, the rows' figures' font.
  if R then
    money, moneyKind = R.MoneyText(hasCOD, mail.money or 0, mail.cod or 0, mail.paid, true, nil,
      R.RowCoins and R.RowCoins(nil, fs) or nil)
  end
  -- The slot count in the quiet tone, and as the player chose it written, as
  -- the Mail tab has it: in the words when it goes to the tooltip (below).
  local slots
  if (mail.items or 0) > 0 then
    local onRow = not R or R.Shows("slots")
    local text = (R and R.SlotsText) and R.SlotsText(mail.items, onRow) or ns.Plural("COUNT_SLOTS", mail.items)
    slots = T.Colorize("textSecondary", text)
  end

  -- Mail sent the box since its last visit (MM.SentRowsInto): nothing
  -- recorded says when it goes, so no time is shown for it. One the box
  -- had returned to it says Returned where the time would stand, after the
  -- expiry marks' arrow back, in the row's quiet ink (the rules'
  -- ReturnedText, as History > Sent writes it).
  if mail.sent then
    if R and money and not R.MoneyShown(moneyKind) then money = nil end
    if R and slots and not R.Shows("slots") then slots = nil end
    local mark = nil
    if mail.returned and not (R and not R.Shows("time")) then
      mark = (R and R.ReturnedText) and R.ReturnedText(fs) or T.Colorize("textSecondary", L["STATUS_RETURNED"])
    end
    return money, slots, mark, nil, nil, false, moneyKind == "cod" and money ~= nil
  end

  -- Time left by the mail list's own rule (ExpiryState): the player's
  -- threshold, amber when genuinely short -- and "expired" always shows.
  local expiryText, expired = ExpiryText(mail.expires, now)
  local left = (tonumber(mail.expires) or 0) - now
  -- Short, or past its date, a mail that held gold or items carries the
  -- expiry mark the visit recorded (the Mail tab's RV.FateText): where it
  -- goes, or where it went. None on a record from before the visits asked.
  local fate
  if mail.back ~= nil and R and R.FateText and ((mail.money or 0) > 0 or (mail.items or 0) > 0) then
    fate = mail.back and "back" or "gone"
  end
  local expiry
  if expired then
    expiry = fate and R.FateText(expiryText, fate, fs) or T.Colorize("warning", expiryText)
  elseif R then
    local show, warn = R.ExpiryState(left / 86400, hasCOD)
    if show then
      expiry = (warn and fate) and R.FateText(expiryText, fate, fs)
        or T.Colorize(warn and "warning" or "textSecondary", expiryText)
    end
  end

  -- A figure switched off leaves the row; the row's tooltip says it in full
  -- (MM.RowTip), from the record, on hover.
  if R and money and not R.MoneyShown(moneyKind) then money = nil end
  if R and slots and not R.Shows("slots") then slots = nil end
  if R and not R.Shows("time") then expiry = nil end
  return money, slots, expiry, nil, expiryText, expired, moneyKind == "cod" and money ~= nil
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

-- One row's figure texts, keyed by column, and the time left in words.
-- A row known to have arrived but never opened says "New" where the row's
-- last figure would stand, and nothing else.
--
-- One table, filled again for every row: both callers read it before they
-- ask for the next row, and neither keeps it. The figure ids are the three
-- columns (the rules' IsFigure), so the fields cleared here are all it holds.
local rowTexts = {}
local function RowTexts(mail, now, fs)
  local R = Rules()
  local texts = rowTexts
  texts.time, texts.money, texts.slots, texts.facts = nil, nil, nil, nil
  texts.expiryText, texts.expired, texts.cod = nil, nil, nil
  if mail.header or mail.note then return texts end
  if mail.pending then
    local last = LastShownFigure(R)
    if last then texts[last] = ns.Theme.Colorize("positive", L["MEMORY_NEW_ROW"]) end
    return texts
  end
  texts.money, texts.slots, texts.time, texts.facts, texts.expiryText, texts.expired, texts.cod = Figures(mail, now, fs)
  return texts
end

-- The list's column widths, measured over every row in it: the mail list's
-- "widest entry anywhere" rule, so nothing twitches as the list scrolls.
-- `owner` is a frame to measure with; `sample` a built row, for its fonts.
do
  -- The figure columns, in the order they are measured.
  local FIGURES = { "time", "money", "slots" }

  -- Each distinct text measured once per pass: a list of every box's
  -- matches repeats "AH Sold", "2 slots" and "29 d" hundreds of times, and
  -- each measure is a SetText and a width read. The widths are kept on the
  -- owner, one table per font string, and emptied as each pass begins (a
  -- font or a scale can change between passes); the tables stay, so a
  -- pass over texts already seen makes nothing.
  local function Width(widths, owner, R, fs, text)
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

  function MM.MeasureRows(owner, rows, now, sample)
    local R = Rules()
    local cols = owner._memCols or {}
    owner._memCols = cols
    cols.money, cols.slots, cols.time, cols.timeMark = 0, 0, 0, 0
    if not R then
      cols.sender = 92
      return cols
    end
    local cap = R.SenderColumn(owner, sample.Sender)
    cols.sender = 0
    -- The list's packed rows measure their own figures as its columns are
    -- measured here (the rules' MeasureIn), and read what this pass measured
    -- from the owner's memo: a window of its own keeps one too, emptied when
    -- its drawing scale moves (the rules' MeasureScale); the Mail tab's
    -- view of a box measures with the tab's own.
    local spec = MM.PlaceSpec(sample:GetParent())
    if spec and R.MeasureIn then R.MeasureIn(spec, owner, sample.ColTime, sample.ColMoney, sample.ColSlots, nil) end
    if owner._measurePass == nil then owner._measurePass = 0 end
    if R.MeasureScale then R.MeasureScale(owner) end
    local fsFor = owner._memFsFor
    if not fsFor then
      fsFor = {}
      owner._memFsFor = fsFor
    end
    fsFor.time, fsFor.money, fsFor.slots = sample.ColTime, sample.ColMoney, sample.ColSlots
    local widths = owner._memWidths
    if not widths then
      widths = {}
      owner._memWidths = widths
    end
    for _, byFont in pairs(widths) do
      for text in pairs(byFont) do byFont[text] = nil end
    end
    -- The sender column is measured only while the arrangement shows it.
    if not R.Shows("sender") then cap = 0 end
    for i = 1, #rows do
      local mail = rows[i]
      if not (mail.header or mail.note) and cols.sender < cap then
        local label = R.OutcomeSender(mail.kind) or R.DisplaySender(mail.sender) or ""
        cols.sender = math.min(math.max(cols.sender, Width(widths, owner, R, sample.Sender, label) + 2), cap)
      end
      local texts = RowTexts(mail, now, sample.ColTime)
      for k = 1, #FIGURES do
        local id = FIGURES[k]
        local text = texts[id]
        if text then cols[id] = math.max(cols[id], Width(widths, owner, R, fsFor[id], text)) end
        if id == "time" and text and R.FateMarkW then cols.timeMark = math.max(cols.timeMark, R.FateMarkW(text)) end
      end
    end
    -- Slot counts written as the number alone can measure narrower than any
    -- column is drawn: the column stands at the narrowest, as the Mail tab's.
    if cols.slots > 0 then cols.slots = math.max(cols.slots, R.FIGURE_MIN or 12) end
    -- On World of Warcraft: Forever, which first names this list shares,
    -- where the rows write first names (the rules' Firsts); MM.FillRow
    -- reads it from here. Never on retail.
    local FN = R.Firsts
    cols.firsts = nil
    if FN and FN.On("rows") then
      local owners = owner._memFirsts or {}
      owner._memFirsts = owners
      FN.Begin(owners)
      for i = 1, #rows do
        local mail = rows[i]
        if not (mail.header or mail.note) then FN.Note(owners, R.DisplaySender(mail.sender)) end
      end
      cols.firsts = owners
    end
    return cols
  end
end

-- list -> the placement table (the rules' NewSpec) for one list of these
-- rows: this window's, or the Mail tab's view of another character's box.
-- Made on the list's first row and kept on the list's own frame, so each
-- list's lanes (RV.Place) are its own. Nil without the row rules.
function MM.PlaceSpec(list)
  local spec = list and list.__pbPlaceSpec
  if spec then return spec end
  local R = Rules()
  spec = list and R and R.NewSpec and R.NewSpec() or nil
  if spec then list.__pbPlaceSpec = spec end
  return spec
end

-- row, mail, now, cols, position [, onHeader [, realm [, name]]] -> the row
-- bound to the mail. `onHeader(realm, name)` answers a click on a
-- character's heading; `realm` is the realm of the box the mail is in (nil:
-- the one being played), which a sender without a realm of its own is on,
-- and `name` whose box it is, which the icon's hover says its items can be
-- taken at (nil: the one being played).
function MM.FillRow(row, mail, now, cols, position, onHeader, realm, name)
  local R = Rules()
  local T = ns.Theme
  T.StyleMailRow(row, position, false)
  -- A line of words is not a row of the list: no band of its own.
  if row._bg then row._bg:SetShown(not mail.note) end
  row.onHeader = onHeader
  if mail.note then
    -- Words of the list's own (MM.SentNotes): the heading over the mail
    -- sent a box since its last visit, and the box's own line under it.
    -- No icon, no mark, no figure, nothing under the pointer.
    row.itemLink, row.itemID = nil, nil
    row.expiryTip, row.stuck = nil, nil
    row.mail, row.itemList, row.iconItems, row.fanSource = nil, nil, 0, nil
    row.headerRealm, row.headerName = nil, nil
    if row.HeaderWash then
      row.HeaderWash:Hide()
      row.HeaderRule:Hide()
    end
    row.HeaderHit:Hide()
    MM.Icons.Release(row.Icon)
    row.Icon:Hide()
    if row.IconHit then row.IconHit:Hide() end
    row.Indicator:Hide()
    if row.Indicator.__pbShade then row.Indicator.__pbShade:Hide() end
    row.Warning:Hide()
    row.ColTime:Hide()
    row.ColMoney:Hide()
    row.ColSlots:Hide()
    local width = row:GetParent():GetWidth() or 0
    if width < 100 then width = WINDOW_WIDTH - 44 end
    if R and R.Anchor then
      R.Anchor(row, row.Sender, 1, 6, 0)
      R.Wash(row, nil)
    end
    if R and R.PaintSender then R.PaintSender(row.Sender, nil) end
    T.SetColor(row.Sender, "textSecondary")
    row.Sender:Show()
    row.Subject:Show()
    T.FitText(row.Sender, width - 12, mail.label, nil)
    T.FitText(row.Subject, 1, "", nil)
    if R and R.PaintQuality then R.PaintQuality(row, nil) end
    if R and R.PaintNameMark then R.PaintNameMark(row, nil) end
    if R and R.PaintCount then R.PaintCount(row, nil, nil) end
    row:SetAlpha(1)
    row:Show()
    return
  end
  if mail.header then
    -- A search across characters: the name the matches below belong to.
    row.itemLink, row.itemID = nil, nil
    row.expiryTip, row.stuck = nil, nil
    row.mail, row.itemList, row.iconItems, row.fanSource = nil, nil, 0, nil
    row.headerRealm, row.headerName = mail.realm, mail.name
    -- The character's class icon, in the chosen style (MM.Icons); with None,
    -- none, and its column kept empty, as a mail without an icon keeps it,
    -- so the heading's name starts on the line the names under it start on.
    local crest = MM.PaintClassIcon(row.Icon, mail.realm, mail.name, ROW_ICON)
    -- A heading, not a mail: a quiet band of its own and a hairline above it,
    -- neutral (the name's class colour is the only colour it needs).
    if not row.HeaderWash then
      row.HeaderWash = row:CreateTexture(nil, "BACKGROUND", nil, 2)
      row.HeaderWash:SetAllPoints()
      ns.Theme.FillChrome(row.HeaderWash, 0.07)
      row.HeaderRule = row:CreateTexture(nil, "ARTWORK")
      row.HeaderRule:SetHeight(1)
      row.HeaderRule:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
      row.HeaderRule:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
      ns.Theme.FillChrome(row.HeaderRule, 0.16)
    end
    row.HeaderWash:Show()
    row.HeaderRule:Show()
    row.Icon:SetShown(crest)
    row.Indicator:Hide()
    if row.Indicator.__pbShade then row.Indicator.__pbShade:Hide() end
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
    -- The heading's name carries its own class colour: the string's own is
    -- the role's, whatever mail the row showed before.
    if R and R.PaintSender then R.PaintSender(row.Sender, nil) end
    T.FitText(row.Sender, width - 40, mail.label, nil)
    T.FitText(row.Subject, 1, "", nil)
    row.HeaderHit:SetShown(onHeader ~= nil)
    local R0 = Rules()
    if R0 and R0.PaintQuality then R0.PaintQuality(row, nil) end
    if R0 and R0.PaintNameMark then R0.PaintNameMark(row, nil) end
    if R0 and R0.PaintCount then R0.PaintCount(row, nil, nil) end
    row:SetAlpha(1)
    row:Show()
    return
  end
  row.HeaderHit:Hide()
  if row.HeaderWash then
    row.HeaderWash:Hide()
    row.HeaderRule:Hide()
  end
  row.itemLink = mail.link
  -- What the mail held, for the icon's hover: the snapshot's list of its
  -- items (ids and counts), nil for a record saved before it kept one; and
  -- whose box it is. Fields, not closures: a bind makes nothing.
  local list = mail.it
  if type(list) ~= "table" or #list < 2 then list = nil end
  row.mail, row.itemList = mail, list
  row.iconItems = list and math.floor(#list / 2) or 0
  -- The fan's tiles come from the list, never the inbox (MM.FanSource).
  row.fanSource = list and MM.FanSource or nil
  row.itemID = mail.id or (list and list[1]) or nil
  row.boxRealm, row.boxName = realm, name

  -- No icon of its own (a letter the snapshot kept none for): the column
  -- keeps its place, empty, so the names still start on one line.
  MM.Icons.Release(row.Icon)
  row.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  row.Icon:SetTexture(MM.MailIcon(mail))

  -- The read mark, as the Mail tab has it: mail known to have arrived and
  -- not yet opened is unread by definition. On a mail remembered as stuck,
  -- the warning triangle stands in its place (the rules' PaintDot; the
  -- placement shows it).
  local stuck = mail.stuck and true or false
  row.stuck = stuck
  local read = mail.read and not mail.pending
  if R and R.PaintDot then
    R.PaintDot(row.Indicator, read, stuck)
  else
    T.SetColor(row.Indicator, read and "read" or "unread")
  end

  -- Read at once: RowTexts fills the same table for the next row.
  local texts = RowTexts(mail, now, row.ColTime)
  local timeText, moneyText, slotsText = texts.time, texts.money, texts.slots
  local codShown, expired = texts.cod, texts.expired
  -- The time left in words, for the row's tooltip (MM.RowTip).
  row.expiryTip = texts.expiryText

  local list = row:GetParent()
  local width = list:GetWidth() or 0
  if width < 100 then width = WINDOW_WIDTH - 44 end
  -- The trailing inset. No mark keeps room at the row's end: the stuck mark
  -- stands in the read mark's place.
  local trail = 6

  local named = (mail.sender ~= "" and mail.sender) or nil
  local outcome = R and R.OutcomeSender(mail.kind) or nil
  local senderText = (R and (outcome or R.DisplaySender(named)))
    or named or L["MEMORY_SENDER_UNKNOWN"]
  -- On Forever, the first name alone where no other sender listed shares it
  -- (the rules' Firsts, noted as the list was measured).
  if cols and cols.firsts and named and not outcome then senderText = R.Firsts.Pick(cols.firsts, senderText) end
  -- Whether the row shows less of the name than the mail has, for the
  -- tooltip, which then says it whole.
  row.tipShort = named ~= nil and not outcome and senderText ~= named
  -- A player the address book knows the class of, in its colour, as on the
  -- Mail tab.
  if R and R.PaintSender then R.PaintSender(row.Sender, not outcome and named or nil, realm) end
  local subject = (ns.Helpers and ns.Helpers.ShortSubject) and ns.Helpers.ShortSubject(mail.subject or "")
    or (mail.subject or "")
  -- The crafting quality mark: on the icon's corner, after the name, both,
  -- or before the name -- wherever the Mail tab puts it.
  local mark = (not mail.pending) and MailMark(mail) or nil
  -- The first item's count on the icon, and the stack edge for more than
  -- one item, as on the Mail tab. A single stack's count the icon writes is
  -- not said again by an auction's subject; one the mail no longer holds
  -- all of is (the counts differ).
  if R and R.SaysCount and (mail.items or 0) <= 1 and R.SaysCount(mail.count) then
    subject = R.DropCount(subject, mail.count)
  end
  if R and R.WithMark and R.MarkOnName and R.MarkOnName() then subject = R.WithMark(subject, mark) end
  if R and R.PaintQuality then R.PaintQuality(row, mark) end
  if R and R.PaintNameMark then R.PaintNameMark(row, mark) end
  -- A number for every mail, so its icon wears the rows' edge whatever it
  -- holds (a heading passes none).
  if R and R.PaintCount then R.PaintCount(row, mail.count, mail.items or 0) end

  local spec = R and R.Place and MM.PlaceSpec(list)
  if spec then
    -- The Mail tab's own placement, at this window's spacing: every column
    -- where the arrangement puts it, the figures in columns or packed by
    -- the mail list's own rule (the Row layout option), the subject taking
    -- the rest. No mark keeps room at a row's end here (markEnd unset).
    local el, text = spec.el, spec.text
    el.read, el.icon, el.sender, el.subject = row.Indicator, row.Icon, row.Sender, row.Subject
    el.time, el.money, el.slots = row.ColTime, row.ColMoney, row.ColSlots
    el.stuck, spec.stuck = row.Warning, stuck
    text.sender, text.subject = senderText, subject
    text.time, text.money, text.slots = timeText, moneyText, slotsText
    spec.size.icon = ROW_ICON
    spec.width, spec.left, spec.trail, spec.gap = width, 6, trail, 6
    spec.cols = cols
    spec.senderCol = cols.sender or 92
    spec.share, spec.two = R.META_SHARE, false
    -- A C.O.D. price shows with the gold column hidden, as on the Mail tab.
    spec.force = codShown and "money" or nil
    -- "Before the name": the mark's room before every row's subject.
    spec.markW = R.NameMarkRoom and R.NameMarkRoom() or nil
    spec.focus = R.Focus and R.Focus() or nil
    R.Place(row, spec)
    -- The icon's hover goes with the icon.
    if row.IconHit then row.IconHit:SetShown(row.Icon:IsShown()) end
  else
    -- No row rules (the Mail tab's file did not load): the names alone.
    row.Warning:Hide()
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
-- sender, name -> whether the sender is three words or more and its last
-- words are `name` ("Horde Auction House", "Auction House"), or its first
-- ones, as the other languages put a house's faction after it
-- ("Auktionshaus der Horde", "Hôtel des ventes de la Horde").
function MM.EndsWithWord(sender, name)
  if type(name) ~= "string" or name == "" or #sender <= #name + 1 then return false end
  if sender:sub(-(#name + 1)) ~= " " .. name and sender:sub(1, #name + 1) ~= name .. " " then
    return false
  end
  local _, spaces = sender:gsub(" ", " ")
  return spaces >= 2
end

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
    out[#out + 1] = { pending = true, kind = p.k, sender = "", subject = subject, icon = PendingIcon(p),
      count = tonumber(p.n) }
  end
  if arrived then
    local ah = L["MEMORY_FROM_AH"]
    local hostAH = type(_G.AUCTION_HOUSE) == "string" and _G.AUCTION_HOUSE or nil
    if type(from) == "table" then
      for i = 1, #from do
        local sender = from[i]
        local isAH = (sender == ah or sender == hostAH)
        -- On World of Warcraft: Forever the auction house signs its mail with
        -- its faction (a beta dump of a canceled auction: "Horde Auction
        -- House"; the client's houses are Alliance, Horde and Blackwater). A
        -- character's name there is two words of letters with one space
        -- between, so a sender of three words or more that ends or begins
        -- with the auction house's name is the auction house, never a player.
        if not isAH and ns.IsForever and type(sender) == "string" then
          isAH = MM.EndsWithWord(sender, ah) or MM.EndsWithWord(sender, hostAH)
        end
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
-- newest first, as { label = outcome in its tone, item = name }; the tone
-- inked for the tooltip, which stays dark in Light mode.
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
    out[#out + 1] = { label = (R and R.OutcomeSender(p.k, "tooltip")) or L["MEMORY_FROM_AH"], item = item }
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
    if st.me or MM.HasMail(st) or st.warn then
      if st.hidden then hidden[#hidden + 1] = st else out[#out + 1] = st end
    end
  end
  return out, hidden
end

-- Whether there is another character's box to look at, and how many more
-- there would be but for the ones the player hid. `all` is an
-- MM.Characters() list the caller has already built, where it has one.
--
-- Without `all` it is answered straight off the saved roots, by the rule
-- SwitchChoices applies to MM.Characters (MM.HasMail, or a warning), and
-- builds nothing: the Mail tab asks it on every paint, the mailbox's close
-- among them, just after the list was let go.
do
  -- Whether that character's box would be offered (SwitchChoices): mail in
  -- its record still waiting (Holds), mail the notices named, mail come
  -- uncounted, or a box unopened long enough to warn of (Status). Mail
  -- going soon is waiting mail, so it is in the first.
  local function Offered(realm, name, now)
    local snap = SnapshotFor(realm, name)
    local mails = snap and snap.mails
    if mails then
      for i = 1, #mails do
        if Holds(mails[i], now) then return true end
      end
    end
    -- Mail sent it from another character since its last visit (Status).
    if MM.SentSince(realm, name, snap and snap.seenAt or nil, now) > 0 then return true end
    local watch = WatchFor(realm, name, false)
    if not watch then return false end
    if LivePendingCount(watch, now) > 0 then return true end
    if Uncounted(watch, snap and snap.seenAt or nil, now) then return true end
    local since = watch.newAt
    if watch.auctionAt and (not since or watch.auctionAt < since) then since = watch.auctionAt end
    return (since and now - since >= UNSEEN_WARN and now - since < UNSEEN_STOP) and true or false
  end

  -- One root's characters (mailMemory, then mailWatch's not in it, as
  -- MM.Characters adds them once each), other than this one: whether one
  -- shown is offered, and how many hidden are, added to `hiddenN`.
  local function Scan(root, skip, myRealm, myName, hiddenSet, now, hiddenN)
    if type(root) ~= "table" then return false, hiddenN end
    for realm, byRealm in pairs(root) do
      if type(byRealm) == "table" then
        local skipRealm = type(skip) == "table" and skip[realm] or nil
        for name in pairs(byRealm) do
          if not (realm == myRealm and name == myName)
              and not (type(skipRealm) == "table" and skipRealm[name] ~= nil) then
            if InHiddenSet(hiddenSet, realm, name) then
              if Offered(realm, name, now) then hiddenN = hiddenN + 1 end
            elseif Offered(realm, name, now) then
              return true, hiddenN
            end
          end
        end
      end
    end
    return false, hiddenN
  end

  -- How many hidden characters would be offered, whatever else is.
  local function CountHidden(root, skip, myRealm, myName, hiddenSet, now, hiddenN)
    if type(root) ~= "table" or not hiddenSet then return hiddenN end
    for realm, names in pairs(hiddenSet) do
      local byRealm = type(names) == "table" and root[realm] or nil
      if type(byRealm) == "table" then
        local skipRealm = type(skip) == "table" and skip[realm] or nil
        for name in pairs(names) do
          if byRealm[name] ~= nil and names[name] and not (realm == myRealm and name == myName)
              and not (type(skipRealm) == "table" and skipRealm[name] ~= nil)
              and Offered(realm, name, now) then
            hiddenN = hiddenN + 1
          end
        end
      end
    end
    return hiddenN
  end

  function MM.HasOthers(all)
    if not MemoryEnabled() then return false, 0 end
    if all then
      local choices, hidden = SwitchChoices(all)
      for i = 1, #choices do
        if not choices[i].me then return true, #hidden end
      end
      return false, #hidden
    end
    local get = ns.Store and ns.Store.Get
    local memory = get and get("mailMemory")
    local watches = get and get("mailWatch")
    local myRealm, myName = Me()
    local hiddenSet = HiddenSet(false)
    local now = time()
    local found, hiddenN = Scan(memory, nil, myRealm, myName, hiddenSet, now, 0)
    if not found then found, hiddenN = Scan(watches, memory, myRealm, myName, hiddenSet, now, hiddenN) end
    if not found then return false, hiddenN end
    -- One is offered: the hidden counted again whole, since the scan
    -- stopped at the first.
    hiddenN = CountHidden(memory, nil, myRealm, myName, hiddenSet, now, 0)
    hiddenN = CountHidden(watches, memory, myRealm, myName, hiddenSet, now, hiddenN)
    return true, hiddenN
  end
end

-- realm, name -> what the picker says of that character: its count of mail
-- waiting (with what is known to be on the way), whether it warns, the
-- warning's words, and whether more came than the count holds (Status's
-- `uncounted`; MM.CountText says them together).
function MM.CountFor(realm, name)
  local myRealm, myName = Me()
  local st = Status(realm or myRealm, name or myName, time())
  return st.waiting + (st.pending or 0), st.warn, WarningText(st, time()), st.uncounted
end

-- The whole box a list heads, as the Mail tab's Inbox counts its own: every
-- mail in the record still in date, read or not, holding anything or not;
-- the ones past the record's cap, as the server counted them; and `pending`,
-- the mail known to have come since, which the list shows at its top. Only
-- mail past its date is left out: the server has returned or deleted it.
local function BoxTotal(snapshot, pending, now)
  local n = pending or 0
  local mails = snapshot and snapshot.mails
  if not mails then return n end
  for i = 1, #mails do
    local expires = tonumber(mails[i].expires)
    if not (expires and expires > 0 and expires <= now) then n = n + 1 end
  end
  return n + math.max(0, (tonumber(snapshot.total) or #mails) - #mails)
end

-- realm, name -> another character's whole box, for its plate on the Mail
-- tab: the count MM.RowsFor gives that box as info.box, the mail sent it
-- since its last visit included (MM.SentSince); and whether more came than
-- it holds (Uncounted; MM.CountText says them together).
function MM.BoxCount(realm, name)
  local now = time()
  local snapshot, watch = SnapshotFor(realm, name), WatchFor(realm, name, false)
  local seenAt = snapshot and snapshot.seenAt or nil
  local myRealm, myName = Me()
  local sent = (realm == myRealm and name == myName) and 0 or MM.SentSince(realm, name, seenAt, now)
  return BoxTotal(snapshot, LivePendingCount(watch, now) + sent, now), Uncounted(watch, seenAt, now)
end

-- The foot of the list, standing for the characters the player hid: one
-- shared marker, told apart from a character by `foot`.
local PICK_FOOT = { foot = true }

-- The characters in the order the list offers them (Options > General >
-- Characters: Character order, MailboxUI.GetCharacterOrder), the one being
-- played always first. Warnings first is MM.Characters' own order, and is
-- that list itself; the others are a copy of it, sorted once and kept
-- until MM.Characters makes a new list (its own rule: a write, the minute
-- turning) or the order changes. Every other reader of MM.Characters keeps
-- its order. The comparators are made once, here.
do
  local memo = { list = {}, from = false, order = false }
  -- Last played, for the build under way: each character's login time
  -- (Recipients' altMeta, as Manage Recipients' Played column reads it),
  -- false where none is recorded.
  local played = {}

  -- x, y: a key each, nil where the character has none (after the others);
  -- `less`: whether x lists first. Ties by name, then realm (ByName).
  local function By(a, b, x, y, less)
    if x ~= y then
      if not x then return false end
      if not y then return true end
      if less then return x < y end
      return x > y
    end
    return ByName(a, b)
  end

  local ORDERS = {
    expiring = function(a, b)
      if a.me ~= b.me then return a.me end
      return By(a, b, a.held, b.held, true)
    end,
    mail = function(a, b)
      if a.me ~= b.me then return a.me end
      return By(a, b, a.waiting + (a.pending or 0), b.waiting + (b.pending or 0), false)
    end,
    name = function(a, b)
      if a.me ~= b.me then return a.me end
      return ByName(a, b)
    end,
    played = function(a, b)
      if a.me ~= b.me then return a.me end
      return By(a, b, played[a] or nil, played[b] or nil, false)
    end,
  }

  function MM.CharactersInOrder()
    local all = MM.Characters()
    local UI = ns.MailboxUI
    local order = UI and type(UI.GetCharacterOrder) == "function" and UI.GetCharacterOrder() or "warnings"
    -- Warnings first while Warn about expiring mail is Off: its own next
    -- rule, by name then realm (MM.Characters' sort without st.warn), which
    -- is Name's. The saved choice is kept and comes back with the warnings.
    if order == "warnings" and UI and type(UI.GetMemoryWarn) == "function" and UI.GetMemoryWarn() == "off" then
      order = "name"
    end
    local sortBy = ORDERS[order]
    if not sortBy then return all end
    local list = memo.list
    if memo.from == all and memo.order == order then return list end
    for i = #list, #all + 1, -1 do list[i] = nil end
    for i = 1, #all do list[i] = all[i] end
    if order == "played" then
      for st in pairs(played) do played[st] = nil end
      local R = ns.Recipients
      local metaOf = type(R) == "table" and type(R.AltMeta) == "function" and R.AltMeta or nil
      for i = 1, #all do
        local st = all[i]
        local key = metaOf and RecipientOf(st.realm, st.name)
        local meta = key and metaOf(key)
        played[st] = type(meta) == "table" and tonumber(meta.lastSeen) or false
      end
    end
    table.sort(list, sortBy)
    memo.from, memo.order = all, order
    return list
  end
end

-- The list's entries, read afresh -- a hide or a show moves a character
-- from one half to the other: the characters it offers, then, while any are
-- hidden, the foot that folds them away and, unfolded, the hidden ones under
-- it by name. The offset stays inside what is left.
local function LoadPicker(list)
  local choices, hidden = SwitchChoices(MM.CharactersInOrder())
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
  local T = ns.Theme
  T.TipBegin(row)
  if kind == "foot" then
    T.TipTitle(L["HIDDEN_TITLE"])
    T.TipLine(ns.Summary(L["HIDDEN_DESC"]))
  else
    T.TipTitle(MM.ClassName(row.realm, row.charName, nil, "tooltip"))
    if kind == "hidden" then
      T.TipHint(L["PICKER_SHOW_TIP"])
    else
      -- The reason the character is listed is a warning: mail about to
      -- expire, or unseen too long.
      if row.reason then T.TipLine(T.TipTone("warning", row.reason)) end
      if not row.isMe then T.TipHint(L["PICKER_HIDE_HINT"]) end
    end
  end
  GameTooltip:Show()
end

-- The list is drawn as the house's menus are (Lib/UI/Dropdown.lua): its rows
-- PICK_PAD in from the card's edges, the count PICK_GUTTER in from the
-- row's right edge, the crest at the menus' art size, and the row under the pointer in
-- the menus' hover wash (MenuColors.hover, which the palette recolours in
-- place), painted as it is entered so it follows the look. The crest is 18
-- in the 20-unit row, a unit of air above and below it.
local PICK_PAD, PICK_GUTTER, PICK_CREST = 4, 8, 18
-- The chosen row's marker, a bar PICK_BAR wide at the row's left edge, and
-- the crest's place on every row, PICK_LEAD in: straight after the bar's
-- place, a unit clear of it, as the Inbox plate's cap stands a unit in
-- from the plate's edge (MM.NewPickCell). The foot's words start there too.
MM.PICK_BAR = 2
MM.PICK_LEAD = MM.PICK_BAR + 1
-- From a row's icon to its name: close, as a label stands by its icon.
MM.PICK_GAP = 3

local function PaintPickHover(texture)
  local shared = ns.Core and ns.Core.UI and ns.Core.UI.Theme
  local h = shared and shared.MenuColors and shared.MenuColors.hover
  if h then
    texture:SetColorTexture(h[1], h[2], h[3], h[4] or 1)
  else
    texture:SetColorTexture(0.90, 0.78, 0.30, 0.18)
  end
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
      row.Hover:Hide()
      -- The box on screen wears the one mark every list and menu gives a
      -- chosen row: an accent wash over the row and an accent bar at its
      -- left edge (its name keeps its class colour, which says whose it
      -- is); the row under the pointer, the lighter neutral wash alone.
      row.Wash = row:CreateTexture(nil, "BACKGROUND", nil, 1)
      row.Wash:SetAllPoints()
      row.Wash:SetTexture("Interface\\AddOns\\Postbox\\Media\\white8x8.tga")
      row.Wash:Hide()
      row.Bar = row:CreateTexture(nil, "ARTWORK")
      row.Bar:SetWidth(MM.PICK_BAR)
      row.Bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
      row.Bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
      row.Bar:SetTexture("Interface\\AddOns\\Postbox\\Media\\white8x8.tga")
      -- The hairline over the foot: the names above it are offered, the ones
      -- below it are not. Neutral, the row's width, as a menu's rule is.
      row.Rule = row:CreateTexture(nil, "ARTWORK")
      row.Rule:SetHeight(1)
      row.Rule:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
      row.Rule:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
      ns.Theme.FillChrome(row.Rule, 0.12)
      row.Rule:Hide()
      row.Crest = row:CreateTexture(nil, "ARTWORK")
      row.Crest:SetSize(PICK_CREST, PICK_CREST)
      row.Crest:SetPoint("LEFT", row, "LEFT", MM.PICK_LEAD, 0)
      row.Name = T.CreateText(row, "value")
      row.Name:SetJustifyH("LEFT")
      row.Name:SetWordWrap(false)
      row.Count = T.CreateText(row, "secondary")
      row.Count:SetPoint("RIGHT", row, "RIGHT", -PICK_GUTTER, 0)
      row.Count:SetJustifyH("RIGHT")
      row:SetScript("OnEnter", function(self)
        PaintPickHover(self.Hover)
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
      row.Name:SetPoint("LEFT", row, "LEFT", MM.PICK_LEAD, 0)
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
      -- With None, no crest: the name starts where the crest did.
      if MM.PaintClassIcon(row.Crest, st.realm, st.name, PICK_CREST, st.hidden and "muted" or nil) then
        row.Crest:Show()
        row.Name:SetPoint("LEFT", row.Crest, "RIGHT", MM.PICK_GAP, 0)
      else
        row.Crest:Hide()
        row.Name:SetPoint("LEFT", row, "LEFT", MM.PICK_LEAD, 0)
      end
      if st.hidden then
        -- A step back: no class colour, the name in the disabled grey (at
        -- full strength: a text dimmed by its alpha reads on whatever it
        -- lets through), a crest without its hue and faded -- and Show
        -- beside it at full strength, the one thing on the row to do.
        row.Crest:SetDesaturated(true)
        row.Crest:SetAlpha(0.5)
        T.SetColor(row.Name, "textDisabled")
        row.Name:SetAlpha(1)
        row.Name:SetText(st.label)
        row.Count:SetText(L["PICKER_SHOW"])
      else
        row.Crest:SetDesaturated(false)
        row.Crest:SetAlpha(1)
        T.SetColor(row.Name, "textPrimary")
        row.Name:SetAlpha(1)
        row.Name:SetText(MM.ClassName(st.realm, st.name))
        if st.me then
          -- The character being played, always first: the way back to its
          -- own box, said in words where the others have their counts.
          row.Count:SetText(L["PICKER_THIS_CHARACTER"])
        else
          local count = MM.MailsText(st.waiting + (st.pending or 0), st.uncounted)
          row.Count:SetText(st.warn and T.Colorize("warning", count) or count)
        end
      end
      -- A hairline under it, between this character and the others.
      local above = first + i - 2 >= 1 and entries[first + i - 2] or nil
      row.Rule:SetShown(above ~= nil and above.me == true and not st.hidden)
      nameW = math.max(nameW, row.Name:GetStringWidth() or 0)
      countW = math.max(countW, row.Count:GetStringWidth() or 0)
      current = (cur == nil and st.me) or (cur ~= nil and cur.realm == st.realm and cur.name == st.name)
    end
    if current and T.GetAccentTone then
      local r, g, b = T.GetAccent()
      row.Wash:SetVertexColor(r, g, b, 0.14)
      r, g, b = T.GetAccentTone("mark")
      row.Bar:SetVertexColor(r, g, b, 0.9)
    end
    row.Wash:SetShown(current and true or false)
    row.Bar:SetShown(current and true or false)
  end
  -- A row no longer needed keeps no hover wash for the next time it is.
  for i = shown + 1, #list.rows do
    list.rows[i].Hover:Hide()
    list.rows[i]:Hide()
  end

  -- The row's width: its contents with the gutters; the card's, the rows
  -- and the padding either side, as a menu's. With None, no crest's room.
  local inner = MM.PICK_LEAD
  local crest = MM.Icons.Off() and 0 or (PICK_CREST + MM.PICK_GAP)
  local width = inner + crest + math.ceil(nameW) + 20 + math.ceil(countW) + PICK_GUTTER
  width = math.max(width, inner + math.ceil(footW) + PICK_GUTTER)
  for i = 1, shown do
    local row = list.rows[i]
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", list, "TOPLEFT", PICK_PAD, -PICK_PAD - (i - 1) * PICK_ROW_H)
    row:SetWidth(width)
    row.Name:SetWidth(math.ceil(row.kind == "foot" and footW or nameW) + 2)
    row:Show()
  end
  list:SetSize(width + 2 * PICK_PAD, 2 * PICK_PAD + shown * PICK_ROW_H)
end
-- An open list painted again where it stands (MM.Icons.Changed).
MM.RepaintPicker = PaintPicker

-- The open list, if any, read again and painted: its characters in the
-- order just chosen (MailboxUI.SetCharacterOrder).
function MM.ReloadPicker()
  local list = MM._picker
  if not (list and list:IsShown()) then return end
  LoadPicker(list)
  PaintPicker(list)
end

-- anchor -> the character list that hangs from `anchor`, made the first
-- time it opens there. Each button the list opens from has its own, a child
-- of that button as a menu is of the button it opens from (Lib/UI/
-- Dropdown.lua), so it wears what that window's menus wear: the house card
-- with the popups' opacity floor under it (a menu is never see-through,
-- whatever the window's opacity), and the skins' pass from the button, which
-- dresses it as they dress that window's menus. Above the window by the
-- menus' margin, at the window's own scale.
local function NewPickList(anchor)
  local T = ns.Theme
  local list = CreateFrame("Frame", nil, anchor, "BackdropTemplate")
  list.__pbPopupAlways = true
  T.ApplyCard(list)
  list:SetFrameStrata("FULLSCREEN_DIALOG")
  list:SetClampedToScreen(true)
  list:EnableMouse(true)
  list:EnableMouseWheel(true)
  list.rows = {}
  list.anchor = anchor
  -- Closes on any click outside it -- the list and the button that opened
  -- it excepted, so that button's own click can close it. No full-screen
  -- catcher frame: one swallowed the very click that chose a character.
  -- Its button holds its lit look while it is open (MM.PaintPickIcon).
  list:SetScript("OnShow", function(self)
    self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    MM.PaintPickIcon(self.anchor)
  end)
  list:SetScript("OnHide", function(self)
    self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    -- Put away with its button (a row stepping aside, the window closing),
    -- it stays closed when the button comes back.
    if self:IsShown() then self:Hide() end
    MM.PaintPickIcon(self.anchor)
    -- A hide or a show made while the list was up repaints everything that
    -- lists characters now, once: until the list closes, the button it
    -- hangs from has to stay where it is.
    if self.dirty then
      self.dirty = false
      MM.HiddenChanged()
    end
  end)
  list:SetScript("OnEvent", function(self)
    if self:IsMouseOver() or self.anchor:IsMouseOver() then return end
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
  anchor.__pbPickList = list
  -- One Escape closes it before the window (Helpers.RegisterEscPopup);
  -- after its own OnShow and OnHide, which are set above.
  ns.Core.UI.Helpers.RegisterEscPopup(list)
  -- The skins' pass, from the button: they walk a frame's children.
  if ns.Skin and ns.Skin.Refresh then pcall(ns.Skin.Refresh, anchor) end
  -- A new frame starts SHOWN, so the Show below would not fire OnShow and
  -- the click-away would never be registered on the first open.
  list:Hide()
  return list
end

-- anchor, current, onPick -> the character list under `anchor`. `current` is
-- the box on screen ({ realm, name }, or nil for the one being played);
-- onPick(realm, name, isMe) answers a pick. A second click on the same
-- anchor closes it; one list is open at a time (MM._picker, the last).
function MM.OpenPicker(anchor, current, onPick)
  local open, list = MM._picker, anchor.__pbPickList
  if open and open:IsShown() then
    open:Hide()
    if open == list then return end
  end
  list = list or NewPickList(anchor)
  MM._picker = list
  list.onPick, list.current = onPick, current
  list.offset = 0
  -- The hidden characters folded away -- unless the box on screen is one of
  -- them, when the mark that says which box it is has to be seen.
  list.showHidden = current ~= nil and MM.IsHidden(current.realm, current.name)
  LoadPicker(list)
  PaintPicker(list)
  -- Hanging from the button's left edge and growing right, as a menu opens
  -- from what was clicked, the menus' gap under it -- out past the window's
  -- edge where it must; it is clamped to the screen, not the window.
  list:ClearAllPoints()
  list:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
  list:SetFrameLevel((ns.Theme.LevelOf(anchor) or 0) + 40)
  list:Show()
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

local function Fold(text) return ns.Helpers.Lower(text) end

-- One matcher for every list a search narrows, by the rule every list's
-- search follows (Helpers.SearchHaystack): the sender as written, the sender
-- as the row shows it (an auction outcome, "AH Sold"), the subject, and the
-- name of every item the mail holds, from the IDs its record keeps
-- (Helpers.SearchItemName: the client's item cache; names are never saved).
--
-- The folded text is kept per mail table (`searchText`, section 1): a search
-- of every box used to colour, uncolour and fold every remembered mail on
-- every keystroke. Text built while an item's name was not loaded yet is
-- built again once names have arrived (`searchMissed`, the fill it missed
-- one at).
local hayNames = {}
local function Matches(mail, query)
  local H = ns.Helpers
  local hay = searchText[mail]
  local missed = searchMissed[mail]
  if not hay or (missed and missed ~= H.SearchNamesFilled()) then
    local R = Rules()
    local outcome = R and R.OutcomeSender and mail.kind and R.OutcomeSender(mail.kind) or nil
    local items, n, miss = mail.it, 0, false
    if type(items) == "table" then
      -- Pairs of item ID and count.
      for k = 1, #items, 2 do
        local name = H.SearchItemName(items[k])
        if name then
          n = n + 1
          hayNames[n] = name
        else
          miss = true
        end
      end
    end
    hay = H.SearchHaystack(mail.sender, outcome, mail.subject, hayNames, n)
    for j = n, 1, -1 do hayNames[j] = nil end
    -- Kept only once the row rules could name the outcome.
    if R then
      searchText[mail] = hay
      searchMissed[mail] = miss and H.SearchNamesFilled() or nil
    end
  end
  return H.SearchFinds(hay, query)
end
MM.Fold = Fold

-- The order "expiry": the soonest to go first, and what has already gone
-- last. One comparator for every sort, made once; `Order.now` is the moment
-- the order is taken at, set before each sort. The mails are sorted in
-- `Order.list`, kept for it, and handed on from there, so a refresh makes no
-- table and no function for its order ("mailbox" is the box's own, and
-- sorts nothing).
local Order = { now = 0, list = {} }
function Order.ByExpiry(a, b)
  local now = Order.now
  local ea, eb = tonumber(a.expires) or 0, tonumber(b.expires) or 0
  local ga, gb = ea <= now, eb <= now
  if ga ~= gb then return gb end
  if ea ~= eb then return ea < eb end
  return (a.subject or "") < (b.subject or "")
end
-- "expirylast", the order turned round (a sort row clicked again): the
-- most time left first, its ties turned with it. What has already gone
-- stays last: it is no longer in the box to expire.
function Order.ByExpiryLast(a, b)
  local now = Order.now
  local ea, eb = tonumber(a.expires) or 0, tonumber(b.expires) or 0
  local ga, gb = ea <= now, eb <= now
  if ga ~= gb then return gb end
  if ea ~= eb then return ea > eb end
  return (a.subject or "") > (b.subject or "")
end
-- The orders that shape the record here: the two by expiry, and "oldest",
-- the box's order read backwards (no comparison made).
Order.BY = { expiry = Order.ByExpiry, expirylast = Order.ByExpiryLast }
Order.SHAPED = { expiry = true, expirylast = true, oldest = true }

-- Appends to `rows` the first `n` mails of Order.list in `order` (one of
-- Order.SHAPED; nil is "expiry"), each through `copy` where one is given,
-- and empties the list for the next.
function Order.Append(rows, n, now, copy, order)
  local list = Order.list
  -- Nothing past the n given: a sort that threw part-way left its mails.
  for i = #list, n + 1, -1 do list[i] = nil end
  local by = Order.BY[order or "expiry"]
  if by and n > 1 then
    Order.now = now
    table.sort(list, by)
  end
  local at, back = #rows, order == "oldest"
  for i = 1, n do
    local mail = list[back and (n + 1 - i) or i]
    rows[at + i] = copy and copy(mail) or mail
  end
  for i = 1, n do list[i] = nil end
end

-- A mail of this visit's look, as a list may keep it: the next capture fills
-- that look's tables again (section 1), and a list built from them must go on
-- showing what it was built from.
local function Frozen(mail)
  local copy = {}
  for key, value in pairs(mail) do copy[key] = value end
  -- Its list of items is refilled in place too.
  local items = mail.it
  if type(items) == "table" then
    local list = {}
    for k = 1, #items do list[k] = items[k] end
    copy.it = list
  end
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

-- The mail Postbox sent another of the player's characters since its last
-- visit (MM.SentRowsInto), gathered here on its way into a list: one table
-- for every list, emptied as it is read.
local sentScratch = {}

-- rows, realm, name, snapshot, now, query, order -> rows with the mail sent
-- that character since its last visit at their top, under their heading
-- and over the box's own line (MM.SentNotes), each through the search as
-- the box's own mail goes; and how many. In the box's order, newest first
-- ("oldest": the other way round); they have no expiry to sort by. `rows`
-- is the list RowsFor made for this call, moved down in place.
local function SentBlock(rows, realm, name, snapshot, now, query, order)
  local sc = sentScratch
  local n = MM.SentRowsInto(sc, realm, name, snapshot and snapshot.seenAt or nil, now, order == "oldest")
  local k = 0
  for i = 1, n do
    local row = sc[i]
    sc[i] = nil
    if query == "" or Matches(row, query) then
      k = k + 1
      sc[k] = row
    end
  end
  if k == 0 then return rows, 0 end
  local head, line = MM.SentNotes(realm, name)
  line.label = MM.SeenText(snapshot, true)
  local m, shift = #rows, k + 2
  for i = m, 1, -1 do rows[i + shift] = rows[i] end
  rows[1] = head
  for i = 1, k do
    rows[i + 1] = sc[i]
    sc[i] = nil
  end
  rows[k + 2] = line
  return rows, k
end

-- Every character's matches, each under a heading with its name. A hidden
-- character is not searched: the search of every box browses the other
-- characters, and the player took that one out of them. The mail sent
-- another character since its last visit is searched with its box, and
-- listed first under its heading (SentBlock's order).
local function SearchAll(query, now, order, all)
  local rows, characters = {}, 0
  all = all or MM.Characters()
  -- In an order of its own (Order.SHAPED) each box's matches are gathered
  -- in Order.list and put in it there, under the box's heading.
  local byExpiry, list = Order.SHAPED[order], Order.list
  for i = 1, #all do
    local st = all[i]
    local snap = (not st.hidden) and SnapshotOf(st.realm, st.name) or nil
    local mails = snap and snap.mails
    local copy = (snap ~= nil and snap == live) and Frozen or nil
    local found = 0
    local headed = false
    if not st.hidden and not st.me and (st.sent or 0) > 0 then
      local sc = sentScratch
      local n = MM.SentRowsInto(sc, st.realm, st.name, snap and snap.seenAt or nil, now, order == "oldest")
      for j = 1, n do
        local row = sc[j]
        sc[j] = nil
        if Matches(row, query) then
          if not headed then
            headed = true
            characters = characters + 1
            rows[#rows + 1] = { header = true, realm = st.realm, name = st.name,
              label = MM.ClassName(st.realm, st.name) }
          end
          rows[#rows + 1] = row
        end
      end
    end
    for j = 1, mails and #mails or 0 do
      local mail = mails[j]
      if Matches(mail, query) then
        if found == 0 and not headed then
          characters = characters + 1
          rows[#rows + 1] = { header = true, realm = st.realm, name = st.name,
            label = MM.ClassName(st.realm, st.name) }
        end
        found = found + 1
        if byExpiry then
          list[found] = mail
        else
          rows[#rows + 1] = copy and copy(mail) or mail
        end
      end
    end
    if byExpiry and found > 0 then Order.Append(rows, found, now, copy, order) end
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
-- The answer alone, with no list of senders made (Arrived); ArrivedSince
-- adds who from.
local function Arrived(snapshot)
  EnsureBaseline(snapshot)
  local state = MailboxState()
  local away = not (state and state.mailboxOpen)
  local flagNow = away and MM.ReadMailFlags() == true
  local tripleNow = away and SenderTriple() or nil
  local arrived = snapshot.newSince == true
    or (flagNow and snapshot.baseNew == false)
    or (tripleNow ~= nil and snapshot.baseFrom ~= nil and tripleNow ~= snapshot.baseFrom)
  return arrived and true or false
end

local function ArrivedSince(snapshot)
  if not snapshot then return false, nil end
  local arrived = Arrived(snapshot)
  local from = snapshot.newFrom
  if arrived and not from then from = SendersList() end
  return arrived, from
end

-- Whether mail has come to the character being played since its mailbox
-- was last opened, by the same three detectors (Arrived): the minimap
-- icon's New since last visit. False at a mailbox, where that visit is
-- under way; nil where it cannot be said -- Mail Memory off, or no visit
-- recorded for this character yet. Makes nothing.
function MM.NewSinceVisit()
  if not MemoryEnabled() then return nil end
  local state = MailboxState()
  if state and state.mailboxOpen then return false end
  local snapshot = StoredSnapshot()
  if not snapshot then return nil end
  return Arrived(snapshot)
end

-- realm, name, opts -> rows, info. `realm`/`name` nil for the character
-- being played. opts.query: the search, folded ("" for none); opts.all:
-- search every character's box; opts.sort: "expiry" for the soonest first,
-- "expirylast" for the latest first, "oldest" for the box's order turned;
-- opts.characters: an MM.Characters() list already built for this refresh.
-- info: realm, name, me, snapshot, total (mails in the snapshot), hidden
-- (in the box but past the record's cap), box (the whole box, BoxTotal,
-- whatever the search), matched, onCharacters, sent (the mail sent another
-- character since its last visit listed at the top, SentBlock).
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
  -- The record after the arrivals: as the box has it, or sorted in
  -- Order.list on its way (the arrivals stay first either way).
  local mails = snapshot and snapshot.mails
  local count = mails and #mails or 0
  if Order.SHAPED[opts.sort] then
    local list = Order.list
    for i = 1, count do list[i] = mails[i] end
    Order.Append(rows, count, now, nil, opts.sort)
  else
    for i = 1, count do rows[#rows + 1] = mails[i] end
  end

  local info = { realm = realm, name = name, me = me, snapshot = snapshot, total = count, sent = 0 }
  info.hidden = snapshot and math.max(0, (tonumber(snapshot.total) or count) - count) or 0
  -- Another character's box: the mail sent it since its last visit, which
  -- the box holds too (MM.SentSince), listed at the top below.
  local sentN = me and 0 or MM.SentSince(realm, name, snapshot and snapshot.seenAt or nil, now)
  -- The rows so far are the arrivals, then the record.
  info.box = BoxTotal(snapshot, #rows - count + sentN, now)

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
  -- The sent mail over the box (SentBlock), but in a search of every box,
  -- which lists it under each box's heading (SearchAll). `info.sent`: how
  -- many it lists.
  if sentN > 0 and not (query ~= "" and opts.all) then
    rows, info.sent = SentBlock(rows, realm, name, snapshot, now, query, opts.sort)
    if info.matched then info.matched = info.matched + info.sent end
  end
  -- This character's box at a mailbox is this visit's look (SearchAll makes
  -- its own copies).
  if live and snapshot == live and not (query ~= "" and opts.all) then
    for i = 1, #rows do rows[i] = Frozen(rows[i]) end
  end
  return rows, info
end

-- rows, i, info -> the realm and name of the box row i of MM.RowsFor's list
-- came from, MM.FillRow's `realm` and `name`: the box shown, or in a search
-- of every box the box whose heading the row is under. A binder asks once,
-- for the first row it binds, and takes each heading's as it passes it --
-- so the list carries nothing extra and a bind builds nothing.
function MM.RowRealm(rows, i, info)
  if info and info.onCharacters and rows then
    for k = i, 1, -1 do
      local row = rows[k]
      if row and row.header then return row.realm, row.name end
    end
  end
  return info and info.realm or nil, info and info.name or nil
end

-- The arrange mode's Preview mail (CollectTab.lua, "Preview mail") as rows
-- of this kind: the Mail tab's sample set, each mail as a snapshot would
-- have remembered it. Made once per set; read, never written, by the rows.
-- `order` "expiry": the same rows, the soonest to go first -- a second list,
-- sorted once per set; likewise each order of Order.SHAPED.
function MM.PreviewRows(order)
  local CT = ns.CollectTab
  local mails = CT and CT.PreviewMails and CT.PreviewMails() or {}
  local gen = CT and CT.PreviewGen and CT.PreviewGen() or 0
  local kept = MM._previewRows
  if not (kept and kept.gen == gen) then
    local now = time()
    local rows = {}
    for i = 1, #mails do
      local m = mails[i]
      local first = m.items[1]
      -- Its items as a capture lists them (section 1): id and count in turn.
      local list, n = nil, 0
      for k = 1, #m.items do
        local item = m.items[k]
        if item.id then
          list = list or {}
          list[n + 1], list[n + 2] = item.id, tonumber(item.count) or 1
          n = n + 2
        end
      end
      rows[i] = {
        sender = m.sender, subject = m.subject, money = m.money, cod = m.cod, paid = m.price,
        items = #m.items, expires = now + math.floor(m.days * 86400), read = m.read,
        kind = m.kind, icon = m.icon, link = first and first.link or nil, id = first and first.id or nil,
        stuck = false, it = list, back = (m.fate == "back"),
      }
    end
    kept = { gen = gen, rows = rows }
    MM._previewRows = kept
  end
  if not Order.SHAPED[order] then return kept.rows end
  local shaped = kept.shaped
  if not shaped then
    shaped = {}
    kept.shaped = shaped
  end
  local sorted = shaped[order]
  if not sorted then
    sorted = {}
    local list, rows = Order.list, kept.rows
    for i = 1, #rows do list[i] = rows[i] end
    Order.Append(sorted, #rows, time(), nil, order)
    shaped[order] = sorted
  end
  return sorted
end

function MM.PreviewRelease()
  MM._previewRows = nil
end

-- snapshot -> "Last seen 27 min ago." or the words for none / an empty box.
-- `sentAbove`: the mail sent the box since stands over it (MM.RowsFor), and
-- an empty box was empty then.
function MM.SeenText(snapshot, sentAbove)
  if not snapshot then return L["MEMORY_EMPTY"] end
  if #(snapshot.mails or {}) == 0 then
    return string.format(L[sentAbove and "MEMORY_ASOF_EMPTY_THEN" or "MEMORY_ASOF_EMPTY"], AgeText(snapshot.seenAt))
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

local Refresh

local function SearchQuery(frame)
  local box = frame.SearchBox
  local text = box and box:GetText() or ""
  return Fold((text:match("^%s*(.-)%s*$")))
end

-- Whose box: one control for both windows, the Mail tab's top row and this
-- one's. The plate that names the box on screen -- the Mail tab's Inbox, or
-- another character's name and count in its class colour; here, always the
-- name -- wears the crest of that box as its left end, a portrait cap: the
-- crest square, edge to edge inside the plate's ring, as tall as the ring
-- leaves room for, and the caption centred in the rest. One button, one
-- state, one click: the picker (MM.NewPickCell) lies over the whole plate,
-- lights it whole under the pointer, and is the plate's click. A click on
-- the plate while it is the lit one -- the list it names is the one on
-- screen -- opens the character list; while it is not, it is the plate's
-- own click (the way back to that Inbox), and the next opens the list, as
-- a click on the lit History clock is its way back. Right-click, while
-- another character's box is on screen, goes back to this character's own.
MM.PLATE_MAX = 160
-- The letters of a name the plate keeps however narrow it has to go.
-- Three: with the class colour and the crest beside them they tell a
-- roster's characters apart, where two letters too often do not; a name no
-- longer than that is never cut at all.
MM.PLATE_LETTERS = 3

-- The crest's quiet cue that it opens something: a step dimmer at rest,
-- whole under the pointer and while its list is open. Solid either way: a
-- cap that faded would let the window's ground through it. A class icon
-- worn in its class colour (MM.Icons.Apply, the cap's __pbTint*) keeps it,
-- dimmed the same step.
function MM.PaintPickIcon(zone)
  local icon = zone and zone.Icon
  if not icon then return end
  local list = zone.__pbPickList
  local lit = (zone.__pbOver or (list ~= nil and list:IsShown())) and true or false
  local tr, tg, tb = icon.__pbTintR or 1, icon.__pbTintG or 1, icon.__pbTintB or 1
  if lit == zone.__pbLit and tr == zone.__pbTR and tg == zone.__pbTG and tb == zone.__pbTB then return end
  zone.__pbLit, zone.__pbTR, zone.__pbTG, zone.__pbTB = lit, tr, tg, tb
  local v = lit and 1 or 0.85
  icon:SetVertexColor(v * tr, v * tg, v * tb)
  icon:SetAlpha(1)
end

-- texture, atlas, crop -> the atlas on the texture, `crop` of its width
-- and height cut from each edge (0: whole), set as its file and its own
-- coordinates rather than by SetAtlas. Seen in game (2026-11-13): a list's
-- icon that had worn a cell of a sheet (another class icon style) and was
-- then given the crest by SetAtlas came out as a corner of the crest, the
-- old crop still standing, while the cap, set this way, was whole. So no
-- class icon relies on SetAtlas to clear a crop. Where the client cannot
-- say an atlas's coordinates: SetAtlas, the old crop cleared first. Each
-- atlas's place is asked once and kept (the classes' crests: a dozen
-- entries), so a repaint builds nothing.
MM.atlasPlace = {}
function MM.WearAtlas(tex, atlas, crop)
  local place = MM.atlasPlace[atlas]
  if place == nil then
    place = false
    local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas)
    local file = info and (info.file or info.filename)
    if file and info.leftTexCoord and info.rightTexCoord and info.topTexCoord and info.bottomTexCoord
        and not (info.tilesHorizontally or info.tilesVertically) then
      place = { file, info.leftTexCoord, info.rightTexCoord, info.topTexCoord, info.bottomTexCoord }
    end
    MM.atlasPlace[atlas] = place
  end
  if place then
    local l, r, t, b = place[2], place[3], place[4], place[5]
    local dx, dy = (r - l) * crop, (b - t) * crop
    tex:SetTexture(place[1])
    tex:SetTexCoord(l + dx, r - dx, t + dy, b - dy)
  else
    tex:SetTexCoord(0, 1, 0, 1)
    tex:SetAtlas(atlas, false)
  end
end

-- texture, atlas -> the crest as the cap wears it: square, its own frame's
-- edge cropped away so the class's picture runs to the cap's edges, as an
-- item's icon is cropped on a row (MM.WearAtlas). Only on a change.
MM.CREST_CROP = 0.08
function MM.SetCrest(tex, atlas)
  if not (tex and atlas) or tex.__pbAtlas == atlas then return end
  tex.__pbAtlas = atlas
  MM.WearAtlas(tex, atlas, MM.CREST_CROP)
end

-- The pointer anywhere on the plate is on the button: the plate lit whole,
-- its wash and caption as under the pointer.
local function PickOver(zone, over)
  zone.__pbOver = over
  local host = zone.host
  if host then
    ns.Theme.SetPlateHover(host, over)
    if over then host:LockHighlight() else host:UnlockHighlight() end
  end
  MM.PaintPickIcon(zone)
end
local function PickEnter(self) PickOver(self, true) end
local function PickLeave(self) PickOver(self, false) end

-- parent, height -> the picker: laid over the whole of the plate it is
-- given (MM.HostPick), with no art of its own but the crest, the plate's
-- portrait cap. Clicks and tooltip are the caller's (HookScript for the
-- tooltip: the enter and leave here light the plate).
MM.CAP_TUCK = 4
function MM.NewPickCell(parent, height)
  local zone = CreateFrame("Button", nil, parent)
  zone:SetHeight(height)
  -- The cap: square, as tall as the plate's ring leaves room for, a unit in
  -- from its top, bottom and left edges, so the ring runs round it.
  local cap = height - 2
  zone.Icon = zone:CreateTexture(nil, "OVERLAY")
  zone.Icon:SetSize(cap, cap)
  if zone.Icon.SetSnapToPixelGrid then zone.Icon:SetSnapToPixelGrid(true) end
  -- The room the cap takes in a plate's width: the cap less CAP_TUCK, so
  -- the caption stands that much nearer the cap than the plate's far edge
  -- and the plate is that much narrower.
  zone.lead = cap
  zone.room = cap - MM.CAP_TUCK
  zone:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  zone:SetScript("OnEnter", PickEnter)
  zone:SetScript("OnLeave", PickLeave)
  MM.PaintPickIcon(zone)
  return zone
end

-- The caption where its plate holds the cap, or not: half the cap's room
-- right of the middle, so the caption stands centred in the rest of the
-- plate; a name plate from its fit (MM.FitPlate), measured with the room.
local function PlaceCaption(plate)
  if plate.pad then
    plate._whole = nil
    if plate._room then MM.FitPlate(plate, plate._room) end
    return
  end
  plate.Text:ClearAllPoints()
  plate.Text:SetPoint("CENTER", plate, "CENTER", (plate.lead or 0) / 2, 0)
end

-- The picker onto `plate` (nil: onto none, while it is hidden): the
-- plate's caption makes room for the cap (`plate.lead`, which its owner
-- adds to its width), the cap fills the plate's left end inside its ring,
-- and the picker's click and tooltip cover the whole plate. Only on a
-- change, but for its level over the plate. With None (MM.Icons.Off) there
-- is no cap: the plate keeps no room for it, its caption centred as a
-- plain plate's, and the picker still covers it whole, so its click, its
-- tooltip and its hover are the same. A change of style changes the room
-- on the plate already hosted; its owner measures and lays it out after.
function MM.HostPick(zone, plate)
  local old = zone.host
  if old == plate then
    if plate then
      local room = MM.Icons.Off() and 0 or (zone.room or zone.lead)
      if plate.lead ~= room then
        plate.lead = room
        PlaceCaption(plate)
      end
    end
  else
    if old then
      if zone.__pbOver then
        ns.Theme.SetPlateHover(old, false)
        old:UnlockHighlight()
      end
      old.lead = nil
      PlaceCaption(old)
    end
    zone.host = plate
    if plate then
      plate.lead = MM.Icons.Off() and 0 or (zone.room or zone.lead)
      PlaceCaption(plate)
      zone.Icon:ClearAllPoints()
      zone.Icon:SetPoint("TOPLEFT", plate, "TOPLEFT", 1, -1)
      zone:ClearAllPoints()
      zone:SetAllPoints(plate)
      if zone.__pbOver then
        ns.Theme.SetPlateHover(plate, true)
        plate:LockHighlight()
      end
    else
      zone.__pbOver = nil
      MM.PaintPickIcon(zone)
    end
  end
  if plate then
    local level = ns.Theme.LevelOf(plate)
    if level and ns.Theme.LevelOf(zone) ~= level + 2 then zone:SetFrameLevel(level + 2) end
  end
end

-- parent -> the plate that names a box. The count has a caption of its own,
-- used only while a long name is cut: the ellipsis then falls in the name
-- and the number stays whole beside it (MM.FitPlate).
function MM.NewNamePlate(parent)
  local T = ns.Theme
  local plate = T.CreatePlate(parent, "segment")
  plate.Count = T.CreateText(plate, "segment")
  plate.Count:SetPoint("LEFT", plate.Text, "RIGHT", 0, 0)
  plate.Count:SetWordWrap(false)
  plate.Count:Hide()
  return plate
end

-- owner, sample, text -> the width `text` takes in `sample`'s face, on a
-- string of the owner's kept for it, so the plate's own words are never
-- set to be measured.
function MM.MeasureWith(owner, sample, text)
  local fs = owner._pbMeasure
  if not fs then
    fs = owner:CreateFontString(nil, "ARTWORK")
    fs:Hide()
    owner._pbMeasure = fs
  end
  local path, size, flags = sample:GetFont()
  if path and (fs.__pbPath ~= path or fs.__pbSize ~= size or fs.__pbFlags ~= flags) then
    fs:SetFont(path, size, flags)
    fs.__pbPath, fs.__pbSize, fs.__pbFlags = path, size, flags
  end
  fs:SetText(text or "")
  local width = fs:GetStringWidth()
  return (type(width) == "number" and width > 0) and width or 0
end

-- measure, owner, sample -> the digit, "0" to "9", that runs widest in
-- `sample`'s face: a count is measured with it in every place, so a plate
-- is as wide for 21 as for 29 and moves only when the count gains or loses
-- a digit. Found once per face (its file, size and outline, and the host
-- face's generation, Theme.FontGeneration) and kept on the owner; a face
-- still loading measures nothing and is asked again next time.
-- `measure(owner, sample, text, exact)` is the caller's measure.
MM.DIGITS = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }
function MM.WidestDigit(measure, owner, sample)
  if not (owner and sample) then return "0" end
  local path, size, flags = sample:GetFont()
  local T = ns.Theme
  local gen = T and type(T.FontGeneration) == "function" and T.FontGeneration() or 0
  if owner._pbDigit and owner._pbDigitPath == path and owner._pbDigitSize == size
      and owner._pbDigitFlags == flags and owner._pbDigitGen == gen then
    return owner._pbDigit
  end
  local digits, best, bestW = MM.DIGITS, "0", 0
  for i = 1, #digits do
    local w = measure(owner, sample, digits[i], true) or 0
    if w > bestW then best, bestW = digits[i], w end
  end
  if bestW > 0 then
    owner._pbDigit, owner._pbDigitPath, owner._pbDigitSize, owner._pbDigitFlags, owner._pbDigitGen =
      best, path, size, flags, gen
  end
  return best
end

-- The plate's caption, measured when a box is put on screen: whole, as it
-- is shown while it fits; and the name and the count apart, with the
-- narrowest the name may go, for when it does not. `count` is the caption's
-- " (N)", or ""; `lit`, whether the plate is drawn selected, which its ink
-- is made for; `measure(owner, fs, text)` the caller's measure. `minW` is
-- the narrowest the plate itself may be. The count is measured with each
-- digit as the widest (MM.WidestDigit), so the plate keeps its width while
-- the count changes and keeps its number of digits.
function MM.MeasurePlate(plate, realm, name, count, lit, measure, owner)
  local T = ns.Theme
  local M = T.Metrics
  local shown = MM.ClassName(realm, name, true, T.PlateGround(plate, lit))
  local fs = plate:GetFontString()
  plate.pad = 2 * M.tightGap + 12
  plate.caption, plate.nameText = shown .. count, shown
  plate.fullName = MM.ClassName(realm, name, nil, "tooltip")
  plate._lit = lit
  plate.Count:SetText(count)
  -- The cap's room, where the plate holds the picker (MM.HostPick).
  local lead = plate.lead or 0
  plate._mLead = lead
  local shape = count
  if count ~= "" then shape = (count:gsub("%d", MM.WidestDigit(measure, owner, fs))) end
  plate.natW = measure(owner, fs, shown .. shape) + plate.pad + lead
  plate.nameW = measure(owner, fs, shown)
  plate.countW = (count ~= "") and measure(owner, fs, shape) or 0
  -- The first letters, by character: a name can be accented or Cyrillic.
  local raw = tostring(name or "")
  local cut, letters = 0, 0
  for letter in raw:gmatch("[^\128-\191][\128-\191]*") do
    letters = letters + 1
    cut = cut + #letter
    if letters >= MM.PLATE_LETTERS then break end
  end
  -- A pixel over the measure, so the client's own cut leaves them standing.
  local least = measure(owner, fs, raw:sub(1, cut) .. "...") + 1
  plate.minNameW = math.min(plate.nameW, least)
  plate.minW = math.min(plate.natW, plate.pad + lead + plate.minNameW + plate.countW)
end

-- The plate at the width a row can give it (`room`), capped at PLATE_MAX
-- and the crest's room (`lead`, MM.HostPick). While its whole caption fits
-- it is drawn whole, centred beside the crest; past that the name gives way
-- -- an ellipsis, down to its first letters -- and the count stays whole
-- beside it, the full name in the tooltip. Never narrower than `minW`: a
-- row that cannot give it that much is made wider instead. Returns the
-- width.
function MM.FitPlate(plate, room)
  local T = ns.Theme
  local fs, pad, lead = plate.Text, plate.pad, plate.lead or 0
  local cap = math.min(MM.PLATE_MAX + lead, room)
  local whole = plate.natW <= cap
  if whole ~= plate._whole then
    plate._whole = whole
    fs:ClearAllPoints()
    if whole then
      fs:SetPoint("CENTER", plate, "CENTER", lead / 2, 0)
      fs:SetJustifyH("CENTER")
    else
      fs:SetPoint("LEFT", plate, "LEFT", lead + pad / 2, 0)
      fs:SetJustifyH("LEFT")
    end
    plate.Count:SetShown(not whole)
  end
  local width
  if whole then
    width = plate.natW
    T.FitText(fs, width - pad - lead, plate.caption, plate)
  else
    local nameW = math.min(plate.nameW, math.max(plate.minNameW, math.floor(cap - pad - lead - plate.countW)))
    T.FitText(fs, nameW, plate.nameText, plate)
    width = pad + lead + nameW + plate.countW
  end
  plate._room = room
  plate:SetWidth(width)
  return width
end

-- The count beside a cut name wears the caption's colour, as it does
-- inside the whole caption, inked for the plate's own ground.
function MM.PaintPlateCount(plate)
  local T = ns.Theme
  local tokens, selected = T.PlateTokens(plate), plate.isSelected
  T.SetColor(plate.Count, selected and "accentBright" or (tokens and tokens.captionToken) or "plateCaption",
    T.PlateGround(plate, selected))
end

-- The cells of one ring (`first` .. `last`, every plate in `cells` between
-- them) in one ring: each cell's own ring put away for the ring texture
-- under them, anchored from the first to the last; or (`on` false) each its
-- own again. `cells` is the caller's list of every plate the ring can hold.
-- Only on a change.
function MM.JoinRing(ring, cells, on, first, last)
  if ring._on == on and ring._first == first and ring._last == last then return end
  ring._on, ring._first, ring._last = on, first, last
  for i = 1, #cells do
    local edge = cells[i]._edge
    if edge then edge:SetShown(not on) end
  end
  if on and first and last then
    ring:ClearAllPoints()
    ring:SetPoint("TOPLEFT", first, "TOPLEFT", 0, 0)
    ring:SetPoint("BOTTOMRIGHT", last, "BOTTOMRIGHT", 0, 0)
  end
  ring:SetShown(on and first ~= nil)
end

-- The ring texture in the ring the plates would wear at rest: their
-- tokens' (a style's, Theme.PlateTokens) or the palette's.
function MM.PaintRing(ring, plate)
  local T = ns.Theme
  local c = (T.PlateTokens(plate) or T.Colors).plateEdge
  if c then ring:SetColorTexture(c[1], c[2], c[3], c[4] or 1) end
end

-- The palette, the Mode or the look changed (Theme.RepaintAccentIcons, as
-- the Mail tab's top row hears it): this window's divider between its
-- search and its sort, in the ring the look gives it now, without waiting
-- for the next refresh.
function MM.RepaintLook()
  local frame = MM._frame
  if not frame then return end
  if frame.Search and frame.Search.PaintJoin then frame.Search.PaintJoin() end
  -- The every-character toggle, in the accent it now has.
  if frame.SearchAllButton then frame.SearchAllButton.Paint() end
end

-- The order a list is shown in, from its sort (MailboxUI.GetListSort):
-- "mailbox" or "expiry". `list` is "memory" for this window, "inbox" for
-- the Mail tab's.
function MM.SortOf(list)
  local UI = ns.MailboxUI
  return UI and type(UI.GetListSort) == "function" and UI.GetListSort(list) or "mailbox"
end

-- The sort button of a window that sorts and has no filters on it -- this
-- one, and Manage Recipients (Core/RecipientManager.lua) -- built as the
-- Mail tab's sort-and-filter button is (CollectTab's RV.NewSortButton),
-- from the same parts: a square segment plate wearing the sort mark at 16
-- on its middle -- three bars and an arrow up (Theme.GLYPHS "sort-list")
-- while the order runs ascending, the smallest first, the pair's other one
-- ("sort-list-turned", the arrow down) while it runs descending, as the
-- chosen row's mark in its menu points; drawn in the house's selected
-- state while the order is not the window's default, the mark then in the
-- accent's bright tone (MM.PaintSortMark); a click opens the menu, a
-- right-click puts the default back. `spec`:
--   lit()        whether the order on screen is not the default
--   ascending()  whether it runs ascending, the smallest first
--   reset()      the default order back (the right-click and the menu's Reset)
--   menu(sort)   the menu to open now (MM.SortMenu), or nil
--   tip()        the tooltip's lines between its title and its hint
-- sort.Paint() paints the plate for lit(), only what changed; sort.Told()
-- paints it and tells the tooltip and an open menu; sort.Toggle(menu) opens
-- that menu or shuts it; sort.open is the menu open now, or nil.
function MM.NewSortButton(parent, size, spec)
  local T = ns.Theme
  local sort = T.CreatePlate(parent, "segment")
  sort:SetSize(size, size)
  sort:SetText("")
  sort.Icon = T.Glyph and T.Glyph(sort, "sort-list", 16, "OVERLAY") or nil
  if sort.Icon then
    -- Centred by its box, as the Mail tab's.
    sort.Icon:SetPoint("CENTER", sort, "CENTER", 0, 0)
    T.SetPlateGlyph(sort, sort.Icon, MM.PaintSortMark)
  else
    sort:SetText("v")
  end
  -- The house's form: the control's name, what is in force, the gestures.
  local function Tip(self)
    T.TipBegin(self, "ANCHOR_TOPRIGHT")
    T.TipTitle(L["SF_SORT_HEAD"])
    spec.tip()
    T.TipHint(L["SORT_MENU_HINT"])
    GameTooltip:Show()
  end
  function sort.Paint()
    local on = spec.lit() and true or false
    local turned = sort.isSelected ~= on
    if turned then T.SetPlateSelected(sort, on) end
    if sort.Icon then
      T.SetGlyphArt(sort.Icon, spec.ascending() and "sort-list" or "sort-list-turned")
      if on or turned then MM.PaintSortMark(sort.Icon) end
    end
  end
  function sort.Told()
    sort.Paint()
    if GameTooltip:IsOwned(sort) then Tip(sort) end
    if sort.open then sort.open:Repaint() end
  end
  function sort.Toggle(menu)
    if GameTooltip:IsOwned(sort) then GameTooltip:Hide() end
    menu:Toggle()
    sort.open = menu:IsShown() and menu or nil
  end
  sort:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  sort:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
      if spec.lit() then spec.reset() end
      return
    end
    local menu = spec.menu(self)
    if menu then sort.Toggle(menu) end
  end)
  -- The plate's own hover paint runs first (Theme.CreatePlate); where a
  -- style's tokens paint the mark as their caption, it is lit again after.
  sort:HookScript("OnEnter", function(self)
    if self.isSelected and self.Icon then MM.PaintSortMark(self.Icon) end
    Tip(self)
  end)
  sort:HookScript("OnLeave", function(self)
    if self.isSelected and self.Icon then MM.PaintSortMark(self.Icon) end
    GameTooltip:Hide()
  end)
  T.SetPlateSelected(sort, false)
  sort.Paint()
  return sort
end

-- The sort mark's ink, as the Mail tab's (CollectTab's RV.PaintSortMark):
-- the accent's bright tone while its plate is selected, otherwise the
-- chrome's grey -- unless a style's tokens paint it as their caption
-- (Theme.SetPlateGlyph), which then stands.
function MM.PaintSortMark(icon)
  local sort = icon:GetParent()
  if sort.isSelected then
    ns.Theme.SetColor(icon, "accentBright")
  elseif not sort.__pbGlyphLit then
    ns.Theme.SetColor(icon, "textSecondary")
  end
end

-- A sort button's menu (Dropdown.Menu), as the Mail tab's is made: `items`
-- its groups and Reset last under a hairline, an action row (`action`, a
-- button of its own in the foot); a pick leaves it open with its
-- dots moved; Reset grayed while there is nothing to reset. `checked(id)`,
-- `disabled(id)`, `onPick(id)`, `flipped(id)` (a field's row turned
-- round, reading its `flip` words) and `ascending(id)` (its mark up, as
-- the button's arrow) as Dropdown.Menu takes them. It opens
-- under the button, left edges lined up, free to pass the window's edge;
-- with `alignRight` its right edge is on the button's and it opens
-- leftward, over its own window (Manage Recipients).
function MM.SortMenu(sort, items, checked, disabled, onPick, flipped, alignRight, ascending)
  local D = ns.Core and ns.Core.UI and ns.Core.UI.Dropdown
  if not (D and type(D.Menu) == "function") then return nil end
  local menu
  menu = D.Menu(sort, items, {
    keepOpen = true,
    checked = checked,
    disabled = disabled,
    onPick = onPick,
    flipped = flipped,
    ascending = ascending,
    alignRight = alignRight and true or nil,
    onClose = function() if sort.open == menu then sort.open = nil end end,
  })
  return menu
end

-- This window's menu: Sort, Newest first (the default) and Expiring first,
-- then Reset. Its ids, each to the field it picks: a click chooses that
-- field the right way round, and a click on the one chosen turns it round
-- ("Oldest first", "Expiring last"), as the Mail tab's menu does. Each
-- order's field, each order turned, and each order's words.
MM.MEMORY_SORT_PICKS = { ["sort:mailbox"] = "mailbox", ["sort:expiry"] = "expiry" }
MM.SORT_FIELD = { mailbox = "mailbox", oldest = "mailbox", expiry = "expiry", expirylast = "expiry" }
MM.SORT_FLIP = { mailbox = "oldest", oldest = "mailbox", expiry = "expirylast", expirylast = "expiry" }
MM.SORT_WORDS = { mailbox = "SORT_NEWEST_TITLE", oldest = "SF_SORT_OLDEST", expiry = "SORT_EXPIRY_TITLE",
  expirylast = "SF_SORT_EXPIRY_LAST" }
-- The orders that run ascending, the smallest first: the oldest, and the
-- soonest to expire (Order.ByExpiry). The button's arrow and the menu's
-- mark point up for these, down for the rest.
MM.SORT_UP = { oldest = true, expiry = true }
function MM.MemorySortUp() return MM.SORT_UP[MM.SortOf("memory")] == true end

-- The order kept for this window (MailboxUI.SetListSort, "memory"), and the
-- list shown in it from its top; the button and an open menu told.
local function SetMemorySort(frame, order)
  if MM.SortOf("memory") == order then return end
  local UI = ns.MailboxUI
  if UI and type(UI.SetListSort) == "function" then UI.SetListSort("memory", order) end
  if frame.Scroll then frame.Scroll:SetVerticalScroll(0) end
  Refresh(frame)
  frame.Sort.Told()
end

local function BuildSearch(frame)
  local T = ns.Theme
  -- The sort, the find plate's last cell (MM.NewSortButton): the order is
  -- remembered (MailboxUI.GetListSort, "memory").
  local sort
  sort = MM.NewSortButton(frame, HEADER_H, {
    lit = function() return MM.SortOf("memory") ~= "mailbox" end,
    ascending = MM.MemorySortUp,
    reset = function() SetMemorySort(frame, "mailbox") end,
    menu = function()
      if not frame._sortMenu then
        local picks = MM.MEMORY_SORT_PICKS
        frame._sortMenu = MM.SortMenu(sort, {
          { heading = true, name = L["SF_SORT_HEAD"] },
          -- Named for what they sort by, as the Mail tab's rows are; the
          -- row's arrow says the way.
          { id = "sort:mailbox", name = L["ARRANGE_AGE_DATE"], flip = L["ARRANGE_AGE_DATE"] },
          { id = "sort:expiry", name = L["OPT_ROW_EXPIRY"], flip = L["OPT_ROW_EXPIRY"] },
          { id = "reset", name = L["SF_RESET"], rule = true, action = true, glyph = "reset" },
        }, function(id)
          return picks[id] ~= nil and MM.SORT_FIELD[MM.SortOf("memory")] == picks[id]
        end, function(id)
          return id == "reset" and MM.SortOf("memory") == "mailbox"
        end, function(id)
          if id == "reset" then return SetMemorySort(frame, "mailbox") end
          local field, now = picks[id], MM.SortOf("memory")
          if not field then return end
          SetMemorySort(frame, MM.SORT_FIELD[now] == field and MM.SORT_FLIP[now] or field)
        end, function(id)
          local now = MM.SortOf("memory")
          return picks[id] ~= nil and MM.SORT_FIELD[now] == picks[id] and now ~= picks[id]
        end, nil, MM.MemorySortUp)
      end
      return frame._sortMenu
    end,
    -- The order as a fact, in the Mail tab's form (RV.SFTip).
    tip = function()
      T.TipFact(L["SF_TIP_SORT"], L[MM.SORT_WORDS[MM.SortOf("memory")] or "SORT_NEWEST_TITLE"])
    end,
  })
  frame.Sort = sort
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
    toggleTip = function()
      T.TipTitle(L["MEMORY_SEARCH_ALL_TITLE"])
      T.TipLine(L[frame.searchAll and "MEMORY_SEARCH_ALL_ON" or "MEMORY_SEARCH_ALL_OFF"])
    end,
  })
  -- One find plate at the row's right end, as the Mail tab's: the search,
  -- then the sort as its last cell in the same ring (Theme's search.Join).
  search.Wrap:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(PAD - 2), HEADER_Y)
  search.Join(sort)
  search.Wrap:SetWidth(SEARCH_W + search.endW)
  -- Escape, as in every search box here: with text in the box the first
  -- press empties it and the second lets the keyboard go; an empty box
  -- lets it go at once. Once it has, Escape closes as it always did.
  search.Box:SetScript("OnEscapePressed", function(self)
    if (self:GetText() or "") ~= "" then
      self:SetText("")
    else
      self:ClearFocus()
    end
  end)
  frame.Search = search
  frame.SearchWrap, frame.SearchBox, frame.SearchClear = search.Wrap, search.Box, search.Clear
  -- Repaints the toggle for frame.searchAll, wherever that is set from.
  search.All.Paint = function() search.PaintToggle(frame.searchAll) end
  frame.SearchAllButton = search.All
end

-- The plate's tooltip while the picker lies over it: the whole name, realm
-- and all (the plate may show only its start), then its clicks -- the way
-- back only while there is one to take.
local function PickerButtonTip(frame)
  local T = ns.Theme
  T.TipBegin(frame.Picker, "ANCHOR_TOPRIGHT")
  T.TipTitle(frame.Who and frame.Who.fullName or L["PICKER_TITLE"])
  -- With no list to open (Refresh's `picking`), the name alone, as the
  -- plate's own tooltip has it.
  if frame.picking then
    -- The characters the player hid that the list would offer, as its foot
    -- counts them (the Mail tab's Inbox says the same, AV.PickerTip).
    local _, hidden = MM.HasOthers()
    hidden = tonumber(hidden) or 0
    if hidden > 0 then T.TipLine(T.TipTone("muted", string.format(L["PICKER_HIDDEN"], hidden))) end
    T.TipHint(L["PICKER_SWITCH_HINT"])
  end
  if frame.viewing then T.TipHint(L["PICKER_BACK_HINT"]) end
  GameTooltip:Show()
end

-- A right-click on the picker while another character's box is on screen:
-- back to this character's own, as picking its own name, first in the
-- list, is, and the list closes. A search of every box ends with the visit,
-- as it does on the Mail tab's way back (AV.Back); what is typed stays. On
-- this character's own box it does nothing.
local function Back(frame)
  if not frame.viewing then return end
  MM.ClosePicker()
  frame.viewing = nil
  frame.searchAll = false
  if frame.SearchAllButton then frame.SearchAllButton.Paint() end
  if frame.Scroll then frame.Scroll:SetVerticalScroll(0) end
  Refresh(frame)
  -- The tooltip under the pointer spoke of the box just left: the name's
  -- goes with the name, the picker's is said again for this box.
  if GameTooltip:IsOwned(frame.Who) then GameTooltip:Hide() end
  if GameTooltip:IsOwned(frame.Picker) then
    if frame.Picker:IsShown() then PickerButtonTip(frame) else GameTooltip:Hide() end
  end
end

-- Whose box, at the top row's start, as the Mail tab has it: the plate
-- naming the box on screen, its name in its class colour and its count,
-- the crest of that box its portrait cap, the picker (MM.NewPickCell) over
-- the whole of it. The plate always names the list on screen, so it is the
-- lit one. The cap is always there; with no other box to show and none
-- hidden, there is no list, and a click on it does nothing.
local function BuildHeader(frame)
  local bar = CreateFrame("Frame", nil, frame)
  bar:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, HEADER_Y)
  bar:SetSize(1, HEADER_H)
  frame.WhoBar = bar

  local picker = MM.NewPickCell(bar, HEADER_H)
  MM.PaintCap(picker, nil, nil)
  -- The plate here always names the box on screen, so a click on it opens
  -- the character list. A right-click, while another character's box is on
  -- screen, goes back to this character's own (Back); on this character's
  -- own it does nothing. A left-drag moves the window, as on the plate
  -- under it.
  picker:RegisterForDrag("LeftButton")
  picker:SetScript("OnDragStart", function() frame:StartMoving() end)
  picker:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
  picker:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
      Back(frame)
      return
    end
    if not frame.picking then return end
    MM.OpenPicker(self, frame.viewing, function(realm, name, isMe)
      frame.viewing = (not isMe) and { realm = realm, name = name } or nil
      -- This character picked is the way home, as Back is: a search of
      -- every box ends with it (the Mail tab's AV.Home).
      if isMe and frame.searchAll then
        frame.searchAll = false
        if frame.SearchAllButton then frame.SearchAllButton.Paint() end
      end
      if frame.Scroll then frame.Scroll:SetVerticalScroll(0) end
      Refresh(frame)
    end)
  end)
  picker:HookScript("OnEnter", function() PickerButtonTip(frame) end)
  picker:HookScript("OnLeave", function() GameTooltip:Hide() end)
  frame.Picker = picker

  -- The plate: the whole name, realm and all, in its tooltip, since a long
  -- one shows only its start. A left-drag on it moves the window, which is
  -- dragged from anywhere.
  local plate = MM.NewNamePlate(bar)
  plate:SetHeight(HEADER_H)
  plate:RegisterForDrag("LeftButton")
  plate:SetScript("OnDragStart", function() frame:StartMoving() end)
  plate:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
  plate:HookScript("OnEnter", function(self)
    if not self.fullName then return end
    local T = ns.Theme
    T.TipBegin(self, "ANCHOR_TOPRIGHT")
    T.TipTitle(self.fullName)
    GameTooltip:Show()
  end)
  plate:HookScript("OnLeave", function(self)
    if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
  end)
  plate:SetPoint("LEFT", bar, "LEFT", 0, 0)
  frame.Who = plate
  -- Each opening measures the plate afresh: its ink follows the looks.
  frame:HookScript("OnShow", function() frame._whoGen = (frame._whoGen or 0) + 1 end)
end

-- The plate names the box on screen: measured again only when what it says
-- changed (another box, its count, the picker in it or not), so a
-- keystroke in the search makes nothing.
local function PaintWho(frame, info, picking)
  local T = ns.Theme
  local plate, picker = frame.Who, frame.Picker
  -- The cap always, so the plate is measured with its room in every state;
  -- the list only while there is one to open.
  frame.picking = picking
  picker:Show()
  MM.HostPick(picker, plate)
  local _, warn, _, uncounted = MM.CountFor(info.realm, info.name)
  local n = tonumber(info.box) or 0
  if plate._realm ~= info.realm or plate._name ~= info.name or plate._n ~= n
      or plate._uncounted ~= uncounted or plate._warn ~= warn or plate._gen ~= frame._whoGen
      or plate._mLead ~= (plate.lead or 0) then
    plate._realm, plate._name, plate._n, plate._uncounted, plate._warn = info.realm, info.name, n, uncounted, warn
    plate._gen = frame._whoGen
    -- Counts always show here, "N+" or "new" with mail come uncounted, in
    -- the warning tone when the box needs a look.
    local count = " (" .. (uncounted and MM.CountText(n, true) or tostring(n)) .. ")"
    if warn then count = T.Colorize("warning", count) end
    MM.MeasurePlate(plate, info.realm, info.name, count, true, MM.MeasureWith, frame)
    -- The window is never narrower than the plate's widest beside the cell
    -- and the search, so it is fitted to that.
    MM.FitPlate(plate, MM.PLATE_MAX)
  end
  T.SetPlateSelected(plate, true)
  MM.PaintPlateCount(plate)
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
  -- While the arrange mode is open over this window its column header stands
  -- on the lanes this pass publishes (Core/Arrange.lua).
  local A = ns.Arrange
  local arranging = A ~= nil and A.host ~= nil and A.host.owner == frame
  if arranging and A.ListPlacing then A.ListPlacing(frame) end
  local used = 0
  local realm, name = MM.RowRealm(rows, first, frame._info)
  for i = first, last do
    used = used + 1
    if rows[i].header then realm, name = rows[i].realm, rows[i].name end
    local row = frame.Rows[used]
    if not row then
      row = MM.NewRow(frame.ListChild)
      frame.Rows[used] = row
    end
    local y = -(i - 1) * ROW_HEIGHT
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", frame.ListChild, "TOPLEFT", 0, y)
    row:SetPoint("TOPRIGHT", frame.ListChild, "TOPRIGHT", 0, y)
    MM.FillRow(row, rows[i], now, frame._cols or {}, i, onHeader, realm, name)
  end
  for i = used + 1, #frame.Rows do frame.Rows[i]:Hide() end
  if arranging and A.ListPlaced then A.ListPlaced(frame) end
  -- An open fan stays only while its row still shows its mail.
  local R = Rules()
  if R and R.FanCheck then R.FanCheck() end
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
  -- In the order the sort keeps for this window, its plate painted for it.
  local order = MM.SortOf("memory")
  frame.Sort.Paint()
  -- The find plate's divider in the ring the look gives the search now.
  if frame.Search then frame.Search.PaintJoin() end
  -- What is asked of the box, in a table kept for it.
  local opts = frame._rowsOpts
  if not opts then
    opts = {}
    frame._rowsOpts = opts
  end
  opts.query, opts.all, opts.sort, opts.characters = query, frame.searchAll, order, characters
  local rows, info = MM.RowsFor(v and v.realm, v and v.name, opts)
  opts.characters = nil
  -- The arrange mode's Preview mail: the samples in the box's place.
  if frame._preview then rows = MM.PreviewRows(order) end
  local now = time()
  local count = #rows

  -- The top row: whose box, and its count, where the Mail tab has Inbox:
  -- the whole box, as Inbox counts its own (counts always show), on the
  -- plate after the picker's cell, as the Mail tab names another box.
  MM.PaintCap(frame.Picker, info.realm, info.name)
  -- The Mail tab's rule: the cap always, and a list while there is another
  -- box with mail to show (the list holds only those), while one is on
  -- screen, or while a character the list would offer is hidden (the list
  -- then holds this character and the Hidden foot). The search of every
  -- box only while there is another box to search.
  local others, hiddenN = MM.HasOthers(characters)
  others = (others and true or false) or v ~= nil
  frame.Search.Place(others)
  PaintWho(frame, info, others or (tonumber(hiddenN) or 0) > 0)
  -- The arrange mode's column header stands where this row is.
  if frame._topHidden then MM.HideTopRow(frame) end

  -- The foot: when the box was seen, or what a search found.
  local text = MM.SeenText(info.snapshot, (info.sent or 0) > 0)
  if (info.hidden or 0) > 0 then text = text .. "  " .. string.format(L["MEMORY_MORE"], info.hidden) end
  if info.matched then
    text = ns.Plural("MEMORY_MATCHES", info.matched)
    if (info.onCharacters or 0) > 1 then
      text = text .. "  " .. ns.Plural("MEMORY_ON_CHARACTERS", info.onCharacters)
    end
  end
  frame.Status:SetText(text)

  -- A search that finds nothing says so where the list stands, in the
  -- house's one line (the Mail tab's words), the list's card kept under it.
  local noMatch = count == 0 and query ~= "" and not frame._preview
  frame.Card:SetShown(count > 0 or noMatch)
  frame.Empty:SetShown(noMatch)
  if count > 0 and not frame.Rows[1] then frame.Rows[1] = MM.NewRow(frame.ListChild) end
  frame._list = rows
  frame._info = info
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

-- The top row -- whose box, the character picker, the search and its sort --
-- steps aside while the arrange mode's column header stands in its place,
-- and comes back as it was: each part as Refresh last left it, shown or
-- not (Refresh, while the header stands, records what it lays out and
-- hides it again). `set` is what Refresh shows or hides by itself; the rest
-- is always there.
MM.TOP_ROW = { "WhoBar", "SearchWrap", "Sort", set = {} }

function MM.HideTopRow(frame)
  local kept = frame._topKept
  if not kept then
    kept = {}
    frame._topKept = kept
  end
  local parts = MM.TOP_ROW
  for i = 1, #parts do
    local key = parts[i]
    local part = frame[key]
    if part then
      -- Recorded as the header first stands there; after that only what
      -- Refresh has just laid out again.
      if not frame._topHidden or parts.set[key] then kept[key] = part:IsShown() and true or false end
      part:Hide()
    end
  end
  if frame.SearchBox and frame.SearchBox.ClearFocus then frame.SearchBox:ClearFocus() end
  frame._topHidden = true
end

function MM.ShowTopRow(frame)
  if not frame._topHidden then return end
  frame._topHidden = nil
  local kept, parts = frame._topKept, MM.TOP_ROW
  for i = 1, #parts do
    local part = frame[parts[i]]
    if part and kept then part:SetShown(kept[parts[i]] and true or false) end
  end
end

-- The arrange mode over this window (Core/Arrange.lua): its column header
-- stands in the top row's place, over the list's lanes, and the list does
-- not move; the top row comes back as it was when the mode ends. The header
-- takes no more width than the rows do, so the window keeps its own.
function MM.ArrangeHost(frame)
  if not (frame and frame.Card) then return nil end
  if frame._arrangeHost then return frame._arrangeHost end
  local host = { owner = frame }
  -- The header's left edge is the rows' own (a unit inside the card's
  -- edge), so a lane's x is a heading's; its right edge is theirs while
  -- nothing scrolls, a unit inside the card's other edge, whether the list
  -- scrolls now or not; its top is the top row's.
  function host.PlaceStrip(strip)
    strip:SetPoint("TOPLEFT", frame, "TOPLEFT", 11, HEADER_Y)
    strip:SetPoint("RIGHT", frame.Card, "RIGHT", -1, 0)
  end
  -- Before the mode takes the list: the search is cleared, as its clear
  -- button clears it, so the rows the header arranges are the whole box.
  -- It does not come back when the mode ends.
  function host.Prepare()
    local box = frame.SearchBox
    if box then
      if box:GetText() ~= "" then box:SetText("") end
      if box.ClearFocus then box:ClearFocus() end
    end
  end
  function host.OnEnter()
    MM.ClosePicker()
    MM.HideTopRow(frame)
  end
  function host.OnLeave()
    MM.ShowTopRow(frame)
  end
  -- What the header and the rows' marks read: the list's placement table
  -- (whose lanes RV.Place publishes), its rows, its scroll frame and the
  -- frame its rows stand in. Its rows are always one line.
  function host.Spec() return MM.PlaceSpec(frame.ListChild) end
  function host.Pool() return frame.Rows end
  function host.Scroll() return frame.Scroll end
  function host.List() return frame.ListChild end
  function host.TwoLine() return false end
  -- Preview mail, from the overview (Arrange.lua): a new sample set in the
  -- box's place, from its top; switched off -- or the mode ending, which
  -- switches it off -- the box as it was, at the place it was scrolled to.
  -- The window sizes itself to its rows either way (Refresh), and so comes
  -- back to the size it had.
  function host.Preview(on)
    on = on and true or false
    if (frame._preview == true) == on then return end
    local scroll = frame.Scroll
    if on then
      frame._previewOffset = scroll:GetVerticalScroll() or 0
      local CT = ns.CollectTab
      if CT and CT.PreviewBuild then CT.PreviewBuild() end
      frame._preview = true
      scroll:SetVerticalScroll(0)
      Refresh(frame)
      return
    end
    frame._preview = nil
    local CT = ns.CollectTab
    if CT and CT.PreviewRelease then CT.PreviewRelease() end
    Refresh(frame)
    local most = math.max(0, #(frame._list or {}) * ROW_HEIGHT - (scroll:GetHeight() or 0))
    scroll:SetVerticalScroll(math.min(frame._previewOffset or 0, most))
    BindRows(frame)
  end
  -- The inspector docks beside this window, level with its top row -- the
  -- header, while it stands there.
  function host.Dock() return frame end
  function host.DockTop() return host.strip or frame.SearchWrap end
  frame._arrangeHost = host
  return host
end

-- The cog's click: the options below this window (OptionsPanel.Toggle),
-- standing by it while docking is on.
local function OpenOptions()
  local panel = ns.OptionsPanel
  if panel and type(panel.Toggle) == "function" then panel.Toggle(MM._frame, "memory") end
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
  if ns.Theme.OnWindow then ns.Theme.OnWindow(frame.Status, "solid", "LEFT") end
  frame.StatusHit = CreateFrame("Frame", nil, frame)
  frame.StatusHit:SetAllPoints(frame.Status)
  HoverOnly(frame.StatusHit)
  frame.StatusHit:SetScript("OnEnter", function(self)
    if not (frame.Status.IsTruncated and frame.Status:IsTruncated()) then return end
    ns.Theme.TipBegin(self)
    ns.Theme.TipTitle(frame.Status:GetText())
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

  -- "Nothing matches.", centred in the card while a search finds nothing
  -- (Refresh): the Mail tab's line for it, in its words.
  frame.Empty = ns.Theme.CreateText(card, "secondary")
  frame.Empty:SetPoint("TOPLEFT", card, "TOPLEFT", 8, 0)
  frame.Empty:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -8, 0)
  frame.Empty:SetJustifyH("CENTER")
  frame.Empty:SetJustifyV("MIDDLE")
  frame.Empty:SetWordWrap(false)
  frame.Empty:SetText(L["EMPTY_LIST_SEARCH"])
  frame.Empty:Hide()

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
  frame.Scroll:HookScript("OnVerticalScroll", function(self)
    BindRows(frame)
    -- Any scroll closes a fan standing in the list: its row holds other mail.
    local R = Rules()
    if R and R.FanScrolled then R.FanScrolled(self) end
  end)
  -- The list ends where its rows end, as the Mail tab's does: a quality mark
  -- reaching past the last row's foot does not lengthen the scroll.
  frame.Scroll:HookScript("OnScrollRangeChanged", function(self)
    local R = Rules()
    if R and R.HoldRange then R.HoldRange(self) end
  end)

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
    -- Built once, not on every hover.
    local gripHint = { L["GRIP_TIP_DRAG"], L["GRIP_TIP_RESET"] }
    grip:HookScript("OnEnter", function(self)
      ns.Theme.ShowHint(self, gripHint)
    end)
    grip:HookScript("OnLeave", function() ns.Theme.HideHint() end)
    grip:HookScript("OnMouseDown", function() ns.Theme.HideHint() end)
  end
  frame:HookScript("OnHide", function()
    MM.ClosePicker()
    -- A fan open over the window's rows goes with it.
    local R = Rules()
    if R and R.FanGone then R.FanGone(frame.Scroll) end
    -- The arrange mode ends with the window it was opened in.
    if ns.Arrange and ns.Arrange.LeaveIf then ns.Arrange.LeaveIf(frame) end
    -- Its order back to the newest first, while Remember sort order is off.
    local UI = ns.MailboxUI
    if UI and type(UI.LetGoListSort) == "function" then UI.LetGoListSort("memory") end
  end)
  -- Shown while the arrange mode is open over the Postbox window: this
  -- window's Escape entry, added as it was built, is taken by the mode as
  -- the ones it found when it began were, so an Escape in combat steps the
  -- mode back rather than closing this window (Arrange.lua, section 5).
  frame:HookScript("OnShow", function()
    local arrange = ns.Arrange
    if arrange and arrange.host and arrange.GuardEscape then arrange.GuardEscape() end
  end)

  -- Same expression as the options panel and the recipient manager: let an
  -- active host-UI skin restyle the shell, whichever entry point it offers.
  local applyWindow = ns.Skin and (ns.Skin.ApplyWindow or ns.Skin.Apply)
  if applyWindow then applyWindow(frame) end

  -- The cog and its key, as the Postbox window has them: the same cog
  -- (MailboxUI's, so the two look and answer alike in every style), opening
  -- the options below this window, and right of it the key, since the rows
  -- here are the Mail tab's rows and arranging them is as close as the
  -- window. After the skin, so they stand in the bar the skin drew. The
  -- Postbox style centres its bar's children on the strip it draws (and
  -- seats the cog there again on every refresh); the other looks keep the
  -- template's bar, where the cog's own offsets are right.
  local UI = ns.MailboxUI
  if UI and type(UI.BuildOptionsButton) == "function" then
    frame.OptionsButton = UI.BuildOptionsButton(frame, ns.Theme, OpenOptions)
    local strip = frame.__pbModernStrip
    if strip and UI.SeatCog then
      UI.SeatCog(frame.OptionsButton, strip)
    elseif strip then
      frame.OptionsButton:ClearAllPoints()
      frame.OptionsButton:SetPoint("LEFT", strip, "LEFT", 5, 0)
    end
  end
  -- The key anchored to the cog by its left edge, so it follows the cog
  -- wherever a skin seats it and its lit Done widens to the right.
  local arrange = ns.Arrange
  if arrange and arrange.BuildToggle then
    frame.ArrangeButton = arrange.BuildToggle(frame, function(button)
      local cog = frame.OptionsButton
      if cog then
        -- AR.COG_GAP clear of the cog's box, as on the Postbox window.
        button:SetPoint("LEFT", cog, "RIGHT", arrange.COG_GAP or 1, 0)
        return
      end
      local strip = frame.__pbModernStrip
      if strip then
        button:SetPoint("LEFT", strip, "LEFT", 5, 0)
      else
        local hostBar = (ns.Skin and (_G.EllesmereUI or _G.ElvUI)) and true or false
        button:SetPoint("TOPLEFT", frame, "TOPLEFT", 5, hostBar and -4 or -2)
      end
    end, function() return MM.ArrangeHost(frame) end)
  end
  -- Its glyph before its title, clear of the cog and the key beside it.
  if ns.Theme.TitleGlyph then ns.Theme.TitleGlyph(frame, "memory") end

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

-- Item names a search was missing have arrived (Helpers.OnSearchNames): the
-- window again, once, if it is showing a search. Nothing otherwise.
function MM.SearchNamesArrived()
  local frame = MM._frame
  if frame and frame:IsShown() and SearchQuery(frame) ~= "" then Refresh(frame) end
end
if ns.Helpers and ns.Helpers.OnSearchNames then ns.Helpers.OnSearchNames(MM.SearchNamesArrived) end

-- The rows on screen bound again where they stand, without re-reading the
-- box: the arrange mode's pointer moved (Core/Arrange.lua).
function MM.Rebind()
  local frame = MM._frame
  if frame and frame:IsShown() and frame._list then BindRows(frame) end
end

-- What this file keeps -- mailMemory, mailWatch, mailHistory, mailSent, hiddenChars, auctionPosts --
-- was emptied from outside it (Options, Reset everything), each table where
-- it stands. The character list is remembered against those same tables,
-- so it is told here; the character list's popup closes, and the window,
-- which may be on a box that no longer exists, goes back to the character
-- being played. This visit's own look at an open mailbox is not a record
-- and stays. The caller repaints (MM.Refresh).
function MM.DataCleared()
  CharactersChanged()
  -- What a sold auction's row was told by (2e, History, the memory).
  local CT = ns.CollectTab
  if CT and type(CT.SoldReset) == "function" then CT.SoldReset() end
  MM.HistoryChanged()
  MM.SentChanged()
  MM.ClosePicker()
  local frame = MM._frame
  if not frame then return end
  frame.viewing = nil
  frame.searchAll = false
  if frame.SearchAllButton then frame.SearchAllButton.Paint() end
  if frame.Scroll then frame.Scroll:SetVerticalScroll(0) end
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
  local hasNew, a, b, c = MM.ReadMailFlags()
  parts[#parts + 1] = "HasNewMail " .. tostring(hasNew)
  parts[#parts + 1] = string.format("login %s | closed %ds ago",
    loginAt and string.format("%ds ago", time() - loginAt) or "unseen",
    math.max(0, time() - closedAt))
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
  if MM.ReadMailFlags() ~= true then return end

  -- An arrival. The minimap icon's sound and flash answer it whether or not
  -- Mail Memory is on to record it: they are alerts, not memory.
  local Icon = ns.MinimapButton
  if Icon and type(Icon.NotifyArrival) == "function" then Icon.NotifyArrival() end

  lastPendingVerdict = "memory off"
  if not MemoryEnabled() then return end

  -- Arrived, whatever else is known: the watch needs no snapshot. Counted
  -- only where a notice names it (MM._NoteSignal).
  MM._NoteSignal()

  lastPendingVerdict = "no snapshot"
  local snap = StoredSnapshot()
  if not snap then return end
  lastPendingVerdict = "marked"
  snap.newSince = true
  local from = SendersList()
  if from then snap.newFrom = from end

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
  -- The alert first: it does not depend on the memory. Your own purchase:
  -- the icon flashes and counts it, the sound stays quiet (MB.NotifyArrival).
  local Icon = ns.MinimapButton
  if Icon and type(Icon.NotifyArrival) == "function" then Icon.NotifyArrival("purchase") end
  if not MemoryEnabled() then return end
  MM._NoteSignal()
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

local function OnMailboxClosed()
  closedAt = time()
  -- The first handler to hear of a close, so the close's timing starts here
  -- (Postbox.lua, 5b); the shell ends it.
  local perf = ns.Perf
  if perf and type(perf.CloseBegin) == "function" then perf.CloseBegin() end
  local perfAt = perf and perf.visit and perf.Mark()
  PersistOnClose()
  if perfAt then perf.ClosePart("memory", perfAt) end
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
    if ns.Helpers.IsMailInteraction(kind) then OnMailboxClosed() end
  end)
  registered.show = bus.Register("MAIL_SHOW", OnMailboxOpened)
  registered.showInteraction = bus.Register("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(_, kind)
    if ns.Helpers.IsMailInteraction(kind) then OnMailboxOpened() end
  end)
  registered.pending = bus.Register("UPDATE_PENDING_MAIL", OnPendingMail)
  -- Item purchases and commodity purchases announce themselves on different
  -- events; both end as mail.
  registered.purchase = bus.Register("AUCTION_HOUSE_PURCHASE_COMPLETED", OnPurchaseCompleted)
  registered.commodity = bus.Register("COMMODITY_PURCHASE_SUCCEEDED", OnPurchaseCompleted)
  -- Posting an auction starts mail on its way: the gold when it sells, the
  -- item when it does not. An expiry while online is that mail arriving.
  -- The auction house opened: what is put up for auction is noted from
  -- here on (2e).
  registered.auctionShow = bus.Register("AUCTION_HOUSE_SHOW", function() pcall(MM.WatchPosts) end)
  registered.auctionPosted = bus.Register("AUCTION_HOUSE_AUCTION_CREATED", function(_, auctionID)
    -- Its item, for a sold auction's row (2e), whether or not Mail Memory is
    -- on, and the deposit that was waiting for it (2f).
    local ok, itemID = pcall(MM.PostCreated, auctionID)
    pcall(MM.DepositCreated, ok and itemID or nil)
    if not MemoryEnabled() then return end
    local watch = WatchFor(ns.Helpers.PlayerRealm(), ns.Helpers.PlayerName(), true)
    if not watch then return end
    local now = time()
    watch.auctionAt = watch.auctionAt or now
    watch.auctionsUntil = math.max(watch.auctionsUntil or 0, now + AUCTION_LONGEST)
    CharactersChanged()
  end)
  -- A post the game asks the player about first: its deposit waits for the
  -- confirm (2e, 2f). A post the game reports an error for, and every one
  -- still waiting when the auction house closes: their deposits are dropped.
  registered.postWarning = bus.Register("AUCTION_HOUSE_POST_WARNING", function() MM.PostWarned() end)
  registered.postError = bus.Register("AUCTION_HOUSE_POST_ERROR", function() MM.PostFailed() end)
  registered.auctionError = bus.Register("AUCTION_HOUSE_SHOW_ERROR", function() MM.PostFailed() end)
  registered.auctionClosed = bus.Register("AUCTION_HOUSE_CLOSED", function() MM.PostsClosed() end)
  registered.auctionExpired = bus.Register("AUCTION_HOUSE_AUCTIONS_EXPIRED", function()
    MM._NoteSignal()
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
    -- History is kept whether or not Mail Memory is on; so is its pruning,
    -- and the auctions' notes' with it (2e).
    pcall(PruneAllHistory)
    pcall(MM.PrunePosts)
    -- Once the client has settled its mail state: mail that arrived while
    -- logged out raised the unread flag that was down at the last close.
    -- Then, once per login, the one line about your characters' mail.
    C_Timer.After(LOGIN_SETTLE + 5, function()
      if not MemoryEnabled() then return end
      local snap = StoredSnapshot()
      local flag = MM.ReadMailFlags() == true
      if flag and (not snap or snap.baseNew == false) then
        -- It landed some time since the last visit: dated from that visit,
        -- the earliest it could have, so a warning never comes late.
        -- Uncounted, unless the auction house's notices since the visit
        -- can be what raised it: their mail is counted already.
        local realm, name = Me()
        local named = LivePendingCount(WatchFor(realm, name, false), time()) > 0
        NoteArrival(realm, name, snap and snap.seenAt, not named)
      end

      -- Warn about's rule (MM.Warns), and Chat line at login.
      local UI = ns.MailboxUI
      local mode = UI and type(UI.GetMemoryWarn) == "function" and UI.GetMemoryWarn() or "any"
      if mode == "off" then return end
      if UI and type(UI.GetOption) == "function" and not UI.GetOption("warnAtLogin") then return end
      local warned = MM.Warnings(mode)
      if #warned == 0 then return end
      local parts = {}
      for i = 1, #warned do
        local text = (mode == "deleted") and warned[i].goneText or warned[i].text
        parts[#parts + 1] = warned[i].label .. " (" .. text .. ")"
      end
      ns.Print(L("OVERVIEW_LOGIN", table.concat(parts, ", ")))
    end)
  end)
end
