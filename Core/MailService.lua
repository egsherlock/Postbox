local _, ns = ...

-------------------------------------------------------------
-- The mail domain: everything Postbox knows about the inbox that is not a
-- frame. Two layers, and the split matters.
--
--   QUERY LAYER   pure, synchronous questions about a mail at an inbox index --
--                 what kind of mail is it, what should it look like, is there
--                 anything left in it -- plus the ordered work list that bulk
--                 collection consumes.
--
--   COMMAND LAYER the asynchronous half. Every mail command is a round trip and
--                 THE SERVER HANDLES ONE AT A TIME. Issuing a second while one
--                 is outstanding does not error and does not fire a failure
--                 event: the command is discarded, the item stays in the
--                 mailbox, and an addon that assumed otherwise reports success.
--                 That failure mode is why this layer exists as a module rather
--                 than as a set of helpers inside a tab file, and why nothing
--                 outside it may call TakeInboxItem / TakeInboxMoney /
--                 DeleteInboxItem / ReturnInboxItem / GetInboxText directly.
--
-- No frames, no printing, no locale strings beyond the category label table.
-- Every command reports a status code and lets the UI choose the words.
-------------------------------------------------------------

ns.MailService = ns.MailService or {}
local Mail = ns.MailService

-------------------------------------------------------------
-- Constants
-------------------------------------------------------------

-- Inbox attachment slots. Blizzard's own constant, with the current value as a
-- fallback for a client that has not defined it yet. Slots are NOT compacted
-- when an item is taken, so every scan runs the full range.
local MAX_ATTACHMENTS = 16
if type(ATTACHMENTS_MAX_RECEIVE) == "number" and ATTACHMENTS_MAX_RECEIVE > 0 then
  MAX_ATTACHMENTS = ATTACHMENTS_MAX_RECEIVE
end
Mail.MAX_ATTACHMENTS = MAX_ATTACHMENTS

local FALLBACK_ICON = "Interface\\Icons\\INV_Letter_02"

-- The category vocabulary, and the only place it is written down. Five of the
-- seven are outcomes ClassifyMail can return; "all" is a filter the collect
-- tab offers and is never a classification result, and "alts" is a sweep by
-- SENDER -- mail from the player's own characters -- whatever its kind. Core/CollectTab.lua filters on
-- these tokens and Core/Locales.lua has to carry a label for each, so a new
-- category is a three-file change and starts here.
local CATEGORY_LOCALE_KEY = {
  sold     = "CAT_SOLD",
  bought   = "CAT_BOUGHT",
  expired  = "CAT_EXPIRED",
  canceled = "CAT_CANCELED",
  other    = "CAT_OTHER",
  all      = "CAT_ALL",
  alts     = "CAT_ALTS",
}
-- One more family of tokens has no entry here because it has no fixed label:
-- "group:<id>", a sweep by the senders in one of the player's character
-- groups (Core/CharacterGroups.lua), labelled with the player's own name for
-- it. The queue builders resolve it through Mail.SenderSet below.

-- token -> the player's word for it, translated on first ask and remembered.
-- Deferring the lookup is what keeps this module free of a load-order
-- dependency on Core/Locales.lua: nothing wants a category label until a
-- mailbox is open, by which point every file has loaded. Consumers only ever
-- index this table, never iterate it.
ns.CATEGORY_LABELS = setmetatable({}, {
  __index = function(cache, token)
    local key = CATEGORY_LOCALE_KEY[token]
    if not key then return nil end
    local label = ns.L[key]
    rawset(cache, token, label)
    return label
  end,
})

-------------------------------------------------------------
-- Header reads
--
-- GetInboxHeaderInfo returns, in order:
--   packageIcon, stationeryIcon, sender, subject, money, codAmount, daysLeft,
--   itemCount, wasRead, wasReturned, textCreated, canReply, isGM, ...
-- Blizzard has appended returns to it across expansions, so nothing here reads
-- past isGM.
-------------------------------------------------------------

-- One read, and the three answers anything downstream wants from it: has the
-- client sent this header yet, and the two fields classification turns on.
--
-- Emptiness has to be judged across the group rather than field by field.
-- System mail carries no sender, an ordinary letter carries neither money nor
-- COD, and every one of those is a real mail; only a header the client has not
-- delivered is absent in all four at once.
local function ReadHeader(index)
  local _, _, sender, subject, money, cod = GetInboxHeaderInfo(index)
  local arrived = sender ~= nil or subject ~= nil or money ~= nil or cod ~= nil
  return arrived, subject, cod
end

-- index -> boolean, for callers that only want to know whether the row is
-- worth asking about yet.
local function HeaderLoaded(index)
  return (ReadHeader(index))
end

Mail.HeaderLoaded = HeaderLoaded

-------------------------------------------------------------
-- Classification
--
-- Two tiers, consulted in order, because they come good at different moments.
-- The invoice tier is authoritative but silent until the mail's body has been
-- fetched; the subject tier answers immediately and in every locale. Running
-- both is what keeps a mail's category from changing under the player the
-- instant they open it -- and a category that moves mid-run is a category
-- button that collects a different set of mail than it offered to.
-------------------------------------------------------------

-- Invoice token -> category. These tokens come off the server verbatim and are
-- the same in every locale, which is what makes this tier the trusted one. A
-- sale the server has not finished settling reports the temporary form; it is
-- still a sale, and letting it fall through to the subject tier would be a
-- visible flicker between categories.
local INVOICE_CATEGORY = {
  seller              = "sold",
  seller_temp_invoice = "sold",
  buyer               = "bought",
}

local function InvoiceCategory(index)
  if type(GetInboxInvoiceInfo) ~= "function" then return nil end
  local token = GetInboxInvoiceInfo(index)
  if type(token) ~= "string" then return nil end
  -- An unknown or empty token is simply not in the table, so no guard is owed
  -- to either: both fall through to the subject tier.
  return INVOICE_CATEGORY[token]
end

-- Subject template -> what a match means. The templates are the client's own
-- globals, already in the player's language, which is the whole point: hunting
-- for English fragments such as "cancel" or "expired" would miss in every
-- other locale and, worse, would drag an ordinary player letter whose subject
-- happens to contain the word into a bulk-collect run.
--
-- Captured at load; these are GlobalStrings and exist long before any addon.
-- A build missing one leaves that template nil, which SubjectLooksLike reads
-- as "no match" rather than erroring.
--
-- Sales are listed alongside failures deliberately. They are exactly the cases
-- the invoice tier will answer later, and listing them here is what stops a
-- sold auction reading as "other" for as long as it sits unopened.
local SUBJECT_CATEGORY = {
  { AUCTION_SOLD_MAIL_SUBJECT,    "sold"     },
  { AUCTION_WON_MAIL_SUBJECT,     "bought"   },
  { AUCTION_EXPIRED_MAIL_SUBJECT, "expired"  },
  { AUCTION_REMOVED_MAIL_SUBJECT, "canceled" },
}

-- subject -> category, remembered: this runs for every mail on every refresh,
-- and every inbox update of a collect run, and a subject's answer never
-- changes (the templates above are fixed at load). Bounded the way Helpers'
-- template cache is: when full it starts again, so a long session of auction
-- mail cannot grow it without limit. `false` remembers "no category".
local SUBJECT_MEMO_MAX = 256
local subjectMemo, subjectMemoCount = {}, 0

local function SubjectCategory(subject)
  if type(subject) ~= "string" or subject == "" then return nil end
  local known = subjectMemo[subject]
  if known ~= nil then return known or nil end
  local H = ns.Helpers
  -- Folded once, not once per rule.
  local folded = H.Lower(subject)
  local category = nil
  for _, rule in ipairs(SUBJECT_CATEGORY) do
    if H.SubjectLooksLike(subject, rule[1], folded) then
      category = rule[2]
      break
    end
  end
  if subjectMemoCount >= SUBJECT_MEMO_MAX then
    subjectMemo, subjectMemoCount = {}, 0
  end
  subjectMemo[subject] = category or false
  subjectMemoCount = subjectMemoCount + 1
  return category
end

-- index -> category token, hasCOD
--
-- hasCOD gates bulk collection, so it is deliberately pessimistic: a mail whose
-- header has not arrived reports true and is never swept up by a category
-- button. BuildQueue counts those separately rather than letting them vanish
-- into a run that then reports success.
function Mail.ClassifyMail(index)
  local arrived, subject, cod = ReadHeader(index)
  if not arrived then return "other", true end

  local category = InvoiceCategory(index) or SubjectCategory(subject) or "other"
  return category, (tonumber(cod) or 0) > 0
end

-------------------------------------------------------------
-- Presentation data
-------------------------------------------------------------

-- index -> texture path or file ID. Never nil.
--
-- The attachment scan is gated on the header's item count so that a mail with
-- no attachments costs one header read instead of MAX_ATTACHMENTS misses -- this
-- runs once per visible row on every list refresh.
function Mail.GetMailIcon(index)
  local packageIcon, stationeryIcon, _, _, _, _, _, itemCount = GetInboxHeaderInfo(index)

  if (tonumber(itemCount) or 0) > 0 then
    -- The first attachment's own texture is more specific than the generic
    -- package icon, but it is nil until the body has been fetched.
    for slot = 1, MAX_ATTACHMENTS do
      local _, _, texture = GetInboxItem(index, slot)
      if texture then return texture end
    end
    if packageIcon and packageIcon ~= "" then return packageIcon end
  end

  if stationeryIcon and stationeryIcon ~= "" then return stationeryIcon end
  return FALLBACK_ICON
end

-------------------------------------------------------------
-- "Is there anything left in it"
-------------------------------------------------------------

-- Money still attached to the mail, in copper.
function Mail.MoneyLeft(index)
  local _, _, _, _, money = GetInboxHeaderInfo(index)
  return tonumber(money) or 0
end

-- Attachments still in the mail, counted rather than probed slot by slot.
-- Emptying a slot can let a higher attachment compact down into it, so "is slot
-- 7 still occupied" cannot tell a refusal from a neighbour moving in; "does this
-- mail still hold the same number of attachments" can.
function Mail.AttachmentsLeft(index)
  local n = 0
  for slot = 1, MAX_ATTACHMENTS do
    if GetInboxItemLink(index, slot) then n = n + 1 end
  end
  return n
end

-- Attachment slots the mail needs, from the header. Unlike AttachmentsLeft this
-- works before the body has been fetched, which is what makes a bag-space
-- pre-flight possible without a round trip per mail.
function Mail.AttachmentCount(index)
  local _, _, _, _, _, _, _, itemCount = GetInboxHeaderInfo(index)
  return tonumber(itemCount) or 0
end

-- Whether the mail still holds anything worth taking. False for a mail that is
-- no longer there.
function Mail.HasContent(index)
  local _, _, sender, subject, money = GetInboxHeaderInfo(index)
  if sender == nil and subject == nil then return false end
  if (tonumber(money) or 0) > 0 then return true end
  return Mail.AttachmentsLeft(index) > 0
end

-- index -> boolean. True iff the mail has been read AND has no money left AND
-- has no attachments left.
--
-- This drives the Collect tab's two view modes, and "was read" alone will not
-- do: collection marks every mail read as a side effect of loading its
-- attachments, so a mail that was read but still holds items -- the normal
-- outcome when bags fill mid-run -- has to stay in the actionable list.
function Mail.IsReadPersistent(index)
  local _, _, _, _, money, _, _, itemCount, wasRead = GetInboxHeaderInfo(index)
  if not wasRead then return false end
  if (tonumber(money) or 0) > 0 then return false end
  -- The header's count is the cheap early-out; the link scan is the one that is
  -- authoritative after a partial take, so a mail only reaches "done" when both
  -- agree.
  if (tonumber(itemCount) or 0) > 0 then return false end
  return Mail.AttachmentsLeft(index) == 0
end

-------------------------------------------------------------
-- Queue construction -- the critical ordering invariant
-------------------------------------------------------------

-- category -> queue, info
--
-- `queue` is an array of inbox indices, STRICTLY DESCENDING, and it must be
-- consumed in that order. When a mail's last attachment and last copper are
-- taken the server deletes it and every higher inbox index shifts down by one.
-- Processing high-to-low means a deletion only invalidates indices ABOVE the
-- cursor, which are already done. Processing low-to-high means every deletion
-- corrupts every remaining entry, and the run loots the wrong mails -- including
-- the C.O.D. mails that were deliberately excluded. This is the single most
-- dangerous thing in the addon to get wrong.
--
-- `info` reports what the queue does NOT contain, so the caller can say so
-- instead of reporting a clean run over a truncated list:
--   numItems    mails addressable now
--   totalItems  mails the server has (may exceed numItems)
--   unreachable totalItems - numItems
--   unloaded    indices whose header has not arrived yet
--   skippedCOD  matching mails held back because they are C.O.D.
--   heldBack    matching mails left for now (Mail.HeldBack): stuck, or
--               holding items while the bags are full
-- The player's own characters, as recipient keys: Postbox.lua's census,
-- account-wide, every realm. Read-only to every caller. Kept between calls
-- -- it was rebuilt on every list refresh, ten string operations per alt --
-- and rebuilt when the census has changed: characters are only ever added
-- to it (at their login), so the count of names is the whole signature. Each
-- name carries its realm, so a key never depends on the realm being known yet.
local ownKeys, ownKeysFrom, ownKeysCount = nil, nil, -1
function Mail.OwnCharacterKeys()
  local R = ns.Recipients
  local alts = ns.Store and ns.Store.Get and ns.Store.Get("alts")
  if not (R and type(R.Key) == "function") or type(alts) ~= "table" then return {} end
  local count = 0
  for _, names in pairs(alts) do
    if type(names) == "table" then count = count + #names end
  end
  if ownKeys and ownKeysFrom == alts and ownKeysCount == count then return ownKeys end
  local set = {}
  for realm, names in pairs(alts) do
    if type(names) == "table" then
      for i = 1, #names do
        local key = R.Key(names[i] .. "-" .. realm)
        if key then set[key] = true end
      end
    end
  end
  ownKeys, ownKeysFrom, ownKeysCount = set, alts, count
  return set
end

-- sender text -> its recipient key, or nil for no sender at all (the game's
-- own mail) or a key that cannot be built. A bare sender is on the player's
-- realm, which R.Key resolves.
--
-- Remembered per sender text, because every list refresh asks it of every
-- mail. R.Key is pure once the player's realm is known, so an answer is kept
-- only when it carried a realm: a bare name keyed in the moment after login
-- when the realm is not known yet is asked again. The census is no part of a
-- key, so nothing it learns makes one stale. Bounded as the subjects are.
local SENDER_MEMO_MAX = 256
local senderMemo, senderMemoCount = {}, 0

local function SenderKeyOf(sender)
  if type(sender) ~= "string" or sender == "" then return nil end
  local known = senderMemo[sender]
  if known ~= nil then return known or nil end
  local R = ns.Recipients
  if not (R and type(R.Key) == "function") then return nil end
  local key, _, realm = R.Key(sender)
  if type(key) ~= "string" or key == "" then key = nil end
  if type(realm) == "string" and realm ~= "" then
    if senderMemoCount >= SENDER_MEMO_MAX then
      senderMemo, senderMemoCount = {}, 0
    end
    senderMemo[sender] = key or false
    senderMemoCount = senderMemoCount + 1
  end
  return key
end

-- index [, keys] -> whether the mail is from one of the player's own
-- characters. A bare sender is on the player's realm, which R.Key resolves.
function Mail.FromOwnCharacter(index, keys)
  local _, _, sender = GetInboxHeaderInfo(index)
  local key = SenderKeyOf(sender)
  return key ~= nil and (keys or Mail.OwnCharacterKeys())[key] == true
end

-- index -> the mail's sender as a recipient key, or nil.
function Mail.SenderKey(index)
  local _, _, sender = GetInboxHeaderInfo(index)
  return SenderKeyOf(sender)
end

-- category -> the set of sender keys (key -> true) a sweep BY SENDER takes,
-- or nil when the category is not one. Resolved at call time, so a group
-- deleted after its button was drawn resolves to the empty set and its sweep
-- finds nothing, never everything. The set is the caller's to read, never to
-- write.
local NO_SENDERS = {}
function Mail.SenderSet(category)
  if type(category) ~= "string" then return nil end
  local id = category:match("^group:(.+)$")
  if not id then return nil end
  local groups = ns.CharacterGroups
  local set = groups and type(groups.KeySet) == "function" and groups.KeySet(id) or nil
  return type(set) == "table" and set or NO_SENDERS
end

-- One inbox index, tested against the queue's rules and either taken or
-- accounted for in `info`. Shared by both builders below so they cannot
-- disagree about what a collectable mail is.
local function Consider(index, category, queue, info)
  if not HeaderLoaded(index) then
    info.unloaded = info.unloaded + 1
  elseif not Mail.IsReadPersistent(index) then
    local kind, hasCOD = Mail.ClassifyMail(index)
    -- "alts" and "other" split what is not auction mail between them: mail
    -- from your own characters, and everything else. They never overlap, so
    -- the two buttons never count or take the same mail.
    local match
    if info.senders then
      -- A sweep by sender (a character group): the mail these characters
      -- sent, of whatever kind.
      match = info.senders[Mail.SenderKey(index) or ""] == true
    elseif category == "alts" then
      match = Mail.FromOwnCharacter(index, info.altKeys)
    elseif category == "other" then
      match = kind == "other" and not Mail.FromOwnCharacter(index, info.altKeys)
    else
      match = (category == "all" or kind == category)
    end
    if match then
      if hasCOD then
        -- Bulk collection must never spend the player's money.
        info.skippedCOD = info.skippedCOD + 1
      elseif not info.picked and Mail.HeldBack(index) then
        -- Stuck, or waiting for bag room: a sweep that took it would only
        -- meet the same refusal again. The player's own picks are tried.
        info.heldBack = info.heldBack + 1
      else
        queue[#queue + 1] = index
      end
    end
  end
end

function Mail.BuildQueue(category)
  local numItems, totalItems = GetInboxNumItems()
  numItems = tonumber(numItems) or 0
  totalItems = tonumber(totalItems) or numItems

  local queue = {}
  local info = {
    numItems = numItems,
    totalItems = totalItems,
    unreachable = math.max(totalItems - numItems, 0),
    unloaded = 0,
    skippedCOD = 0,
    heldBack = 0,
  }

  if category == "alts" or category == "other" then info.altKeys = Mail.OwnCharacterKeys() end
  info.senders = Mail.SenderSet(category)

  -- GetInboxNumItems returns 0 between MAIL_SHOW and the first
  -- MAIL_INBOX_UPDATE, so an empty result here means "nothing to do OR nothing
  -- known yet" and the caller is told which by info.totalItems.
  for index = numItems, 1, -1 do
    Consider(index, category, queue, info)
  end

  return queue, info
end

-- The same queue, over an explicit set of inbox indices rather than the whole
-- inbox: what the collect screen's search hands over, so that "Collect" under
-- a filtered list takes the mails on screen and nothing else. Every rule
-- BuildQueue applies -- unloaded headers, finished mail, C.O.D., held back --
-- applies here too, and the queue comes out descending for the same reason.
-- `picked`: these are rows the player picked one by one, which are tried as a
-- click on each row would be -- stuck or not, bags full or not (C.O.D. is
-- still never swept).
function Mail.BuildQueueFor(indices, category, picked)
  category = category or "all"
  local numItems, totalItems = GetInboxNumItems()
  numItems = tonumber(numItems) or 0
  totalItems = tonumber(totalItems) or numItems

  local queue = {}
  local info = {
    numItems = numItems,
    totalItems = totalItems,
    unreachable = math.max(totalItems - numItems, 0),
    unloaded = 0,
    skippedCOD = 0,
    heldBack = 0,
    picked = picked and true or nil,
  }

  local sorted = {}
  for i = 1, #indices do
    local index = tonumber(indices[i])
    if index and index >= 1 and index <= numItems then sorted[#sorted + 1] = index end
  end
  table.sort(sorted, function(a, b) return a > b end)
  if category == "alts" or category == "other" then info.altKeys = Mail.OwnCharacterKeys() end
  info.senders = Mail.SenderSet(category)
  for i = 1, #sorted do
    Consider(sorted[i], category, queue, info)
  end

  return queue, info
end

-- indices [, done] -> sender key -> how many of those mails a sweep by sender
-- would take right now. Consider's rules -- the header has arrived, something
-- is left in the mail, no C.O.D., not held back -- applied once to the whole
-- list, so every sender-based button counts from ONE walk (a character group's
-- count is a sum over its members) instead of one walk per button. `done`,
-- where given, is the caller's verdict for each position of `indices` (true:
-- finished), which the collect screen's list walk has already paid for;
-- without it each mail is asked, sixteen slots and all. Entries that are not
-- inbox indices -- the list's divider -- are skipped.
function Mail.SenderTally(indices, done)
  local tally = {}
  if type(indices) ~= "table" then return tally end
  local numItems = tonumber((GetInboxNumItems())) or 0
  for i = 1, #indices do
    local index = tonumber(indices[i])
    if index and index >= 1 and index <= numItems then
      local _, _, sender, subject, money, cod, _, itemCount = GetInboxHeaderInfo(index)
      -- ReadHeader's "has it arrived", on the one read.
      local arrived = sender ~= nil or subject ~= nil or money ~= nil or cod ~= nil
      if arrived and (tonumber(cod) or 0) <= 0 then
        local finished
        if done then
          finished = done[i] == true
        else
          finished = Mail.IsReadPersistent(index)
        end
        if not finished and not Mail.HeldBack(index, tonumber(itemCount) or 0) then
          local key = SenderKeyOf(sender)
          if key then tally[key] = (tally[key] or 0) + 1 end
        end
      end
    end
  end
  return tally
end

-- Mails that "delete all read" may remove: read, no money, no attachments.
-- Descending, for the same reason BuildQueue is.
function Mail.BuildDeleteQueue()
  local numItems = tonumber((GetInboxNumItems())) or 0
  local queue = {}
  for index = numItems, 1, -1 do
    if HeaderLoaded(index) then
      local _, _, _, _, money, _, _, itemCount, wasRead = GetInboxHeaderInfo(index)
      if wasRead and (tonumber(money) or 0) == 0 and (tonumber(itemCount) or 0) == 0
         and Mail.AttachmentsLeft(index) == 0 then
        queue[#queue + 1] = index
      end
    end
  end
  return queue
end

-------------------------------------------------------------
-- Bag space
--
-- Collecting marks every queued mail read, which resets its expiry clock and
-- moves it out of the unread view. Doing that for mails whose attachments
-- cannot physically fit is the damaging part, so the room is counted first.
-------------------------------------------------------------

-- -> free slots in the general bags, free slots in the reagent bag; nil when
-- the container API is unavailable -- in which case the caller should skip
-- the check rather than guess.
--
-- The general bags are the backpack and the four bag slots (NUM_BAG_SLOTS),
-- and of those only the ones of family 0: a profession bag takes only its own
-- trade's goods. That is the room any attachment can use.
--
-- The reagent bag is counted apart. It takes only crafting reagents, so its
-- free slots are room for some mail and none at all for the rest -- and it
-- cannot be told apart by family, since it reports family 0 like any ordinary
-- bag (the client's own container code knows it by its bag id). Added into
-- one number, as it once was, a reagent bag with room left read as room while
-- every general slot was full. Callers choose: the collect run's pre-flight
-- adds it (reagent mail may well fit, and a run that meets full bags stops
-- cleanly -- "Bags full"), All mail's tooltip names it on a line of its own.
function Mail.FreeBagSlots()
  local getFree = (type(C_Container) == "table" and C_Container.GetContainerNumFreeSlots) or nil
  if type(getFree) ~= "function" then return nil end

  local lastBag = (type(NUM_BAG_SLOTS) == "number" and NUM_BAG_SLOTS) or 4
  local reagentBag = type(Enum) == "table" and type(Enum.BagIndex) == "table"
    and Enum.BagIndex.ReagentBag or nil
  if reagentBag == nil and type(NUM_TOTAL_EQUIPPED_BAG_SLOTS) == "number"
    and NUM_TOTAL_EQUIPPED_BAG_SLOTS > lastBag then
    reagentBag = lastBag + 1
  end

  local free = 0
  for bag = 0, lastBag do
    if bag ~= reagentBag then
      local slots, family = getFree(bag)
      if (tonumber(family) or 0) == 0 then
        free = free + (tonumber(slots) or 0)
      end
    end
  end
  local reagent = 0
  if reagentBag then reagent = tonumber((getFree(reagentBag))) or 0 end
  return free, reagent
end

-- Letting the bags catch up, for runs that keep bag slots free.
--
-- The bags' count can lag a take: the take's handshake clears, and the item
-- reaches the bags (and the free count moves) a moment later. Read in that
-- moment, the count still offers the slot the take has just used, so a run
-- stopping at the slots it keeps went one item past them for every take
-- that lagged. Counting the takes ourselves instead would stop short: an
-- item that joins a stack in the bags uses no slot, and only the bags know.
-- So an item take of such a run is not over until the bags have caught up
-- with it -- their BAG_UPDATE_DELAYED, which usually comes before the
-- handshake clears and costs no wait at all -- and the next take is decided
-- from the count as it then stands. One take is watched at a time (a plan
-- runs its takes one by one), so the update after it is its own. Bounded by
-- one one-shot deadline; a take whose update never came counts as the slot
-- it would have used until the bags next update. BAG_UPDATE_DELAYED is
-- listened to only while a take is watched or so counted.
local bagsCatch = { gen = 0, watching = false, unconfirmed = 0, fn = nil, frame = nil, DEADLINE = 2 }

function bagsCatch.Listen(on)
  if on then
    if not bagsCatch.frame then
      bagsCatch.frame = CreateFrame("Frame")
      bagsCatch.frame:SetScript("OnEvent", bagsCatch.Updated)
    end
    bagsCatch.frame:RegisterEvent("BAG_UPDATE_DELAYED")
  elseif bagsCatch.frame then
    bagsCatch.frame:UnregisterEvent("BAG_UPDATE_DELAYED")
  end
end

function bagsCatch.Updated()
  bagsCatch.gen = bagsCatch.gen + 1
  bagsCatch.unconfirmed = 0
  local fn = bagsCatch.fn
  bagsCatch.fn = nil
  if not bagsCatch.watching then bagsCatch.Listen(false) end
  if fn then fn() end
end

-- keepFree -> the bags' update count as an item take is issued, or nil
-- where the run keeps nothing free and nothing is watched.
function bagsCatch.Watch(keepFree)
  if type(keepFree) ~= "number" or keepFree <= 0 then return nil end
  bagsCatch.watching = true
  bagsCatch.Listen(true)
  return bagsCatch.gen
end

-- The watched take is over without anything reaching the bags (refused,
-- or no answer at all).
function bagsCatch.Drop(since)
  if since == nil then return end
  bagsCatch.watching = false
  if bagsCatch.unconfirmed == 0 then bagsCatch.Listen(false) end
end

-- since, fn -> fn(), now if the bags have updated since the take went out
-- (or nothing was watched), otherwise at their update or the deadline.
function bagsCatch.After(since, fn)
  if since == nil then return fn() end
  local function caughtUp()
    bagsCatch.Drop(since)
    fn()
  end
  if bagsCatch.gen > since then return caughtUp() end
  bagsCatch.fn = caughtUp
  C_Timer.After(bagsCatch.DEADLINE, function()
    if bagsCatch.fn ~= caughtUp then return end
    bagsCatch.fn = nil
    bagsCatch.watching = false
    bagsCatch.unconfirmed = bagsCatch.unconfirmed + 1
    fn()
  end)
end

-- keepFree -> true when a collect run keeping that many general bag slots
-- free ("Keep bag slots free", UI.GetKeepFreeSlots) must not take another
-- item: the next one could fill a slot, and there are no more free than
-- that. Counted from the general bags only, as the option says: a reagent
-- that would have gone into the reagent bag waits too, since which bag an
-- item lands in is the client's to decide. 0 or nil keeps nothing free and
-- is never reached -- runs then go until the bags are full, as they always
-- have -- and bags that cannot be counted do not stop a run.
--
-- Asked of the bags as they stand once they have caught up with the run's
-- last take (bagsCatch, below); a take whose update never came counts as
-- the slot it would have used.
function Mail.KeepFreeReached(keepFree)
  if type(keepFree) ~= "number" or keepFree <= 0 then return false end
  local free = Mail.FreeBagSlots()
  return free ~= nil and free - bagsCatch.unconfirmed <= keepFree
end

-- Total attachment slots a queue needs.
function Mail.QueueAttachmentSlots(queue)
  local needed = 0
  for i = 1, #queue do
    needed = needed + Mail.AttachmentCount(queue[i])
  end
  return needed
end

-- How many mails from the FRONT of the queue fit in `free` slots, and how many
-- slots that uses. The prefix, not an arbitrary subset: the queue is descending
-- and only a prefix of it can be collected without invalidating the rest.
function Mail.QueuePrefixThatFits(queue, free)
  local used, fits = 0, 0
  for i = 1, #queue do
    local need = Mail.AttachmentCount(queue[i])
    if used + need > free then break end
    used = used + need
    fits = fits + 1
  end
  return fits, used
end

-------------------------------------------------------------
-- Command layer :: the handshake
-------------------------------------------------------------

local COMMAND_POLL_INTERVAL = 0.05
-- 6 s. A congested realm can take several seconds to acknowledge a take, and
-- the 2 s this used to allow made the give-up path the common case. The real
-- fix is not the number: it is that giving up now stops the run and is reported
-- as a stop, rather than being treated as "the server is ready".
local COMMAND_MAX_ATTEMPTS = 120

-- How long to keep watching for the server's error text after the handshake
-- clears. The error packet and the command acknowledgement race each other, so
-- closing the watch the instant the handshake clears misses the reason about
-- half the time. Only refusals pay this; successful takes close it immediately.
local ERROR_WATCH_GRACE = 0.2

local function CommandPending()
  if type(C_Mail) ~= "table" or type(C_Mail.IsCommandPending) ~= "function" then
    return false
  end
  return C_Mail.IsCommandPending() and true or false
end

-- Is the mailbox still open? Asked before every irreversible command and again
-- between the steps of a bulk run, so that a run whose mailbox closes mid-flight
-- stops instead of firing the rest of its commands at nothing.
--
-- Two independent witnesses, and the answer is their OR.
--
--   THE CLIENT   C_PlayerInteractionManager, asked for a MailInfo interaction.
--                This used to ask IsMailboxOpen(), which is a Classic-era global
--                that retail no longer defines: the type() guard therefore
--                always fell through to `return true`, the answer was always
--                "open", and every "closed" early-stop in this file was
--                unreachable. Reviving them on one unverified probe is the risk
--                being managed here.
--   THE SHELL    our own session flag, set from MAIL_SHOW /
--                PLAYER_INTERACTION_MANAGER_FRAME_SHOW and cleared on the
--                matching close.
--
-- Deliberately fail-open. A wrong "open" costs one command the server declines
-- and a line of chat; a wrong "closed" is total and silent -- every collect in
-- the addon would stop before issuing anything. So ANY witness answering
-- "open" wins outright, "closed" needs at least one witness to have answered
-- with none answering open, and a client that answers neither question is
-- treated as open, exactly as before the probe existed. (In practice the
-- shell's flag always answers, so both witnesses agree before a run stops.)
local function MailboxOpen()
  local answered = false

  local manager = C_PlayerInteractionManager
  local enum = type(Enum) == "table" and Enum.PlayerInteractionType or nil
  local kind = enum and enum.MailInfo
  if type(manager) == "table"
     and type(manager.IsInteractingWithNpcOfType) == "function"
     and kind ~= nil then
    local ok, open = pcall(manager.IsInteractingWithNpcOfType, kind)
    if ok then
      if open then return true end
      answered = true
    end
  end

  local UI = ns.MailboxUI
  if UI and type(UI.IsMailboxOpen) == "function" then
    local ok, open = pcall(UI.IsMailboxOpen)
    if ok then
      if open then return true end
      answered = true
    end
  end

  return not answered
end

-- Published so the screens ask the same question of the same code rather than
-- keeping a second copy that can drift from this one.
Mail.IsMailboxOpen = MailboxOpen

-- Polls until the server is ready, then calls callback(timedOut). The callback
-- always runs, but `timedOut` true means we gave up waiting: the command may
-- still be in flight, so the caller must NOT treat it as success and must not
-- issue another command on the back of it.
local function WaitForCommand(callback)
  local attempts = 0
  local function poll()
    attempts = attempts + 1
    if CommandPending() then
      if attempts >= COMMAND_MAX_ATTEMPTS then
        callback(true)
        return
      end
      C_Timer.After(COMMAND_POLL_INTERVAL, poll)
      return
    end
    callback(false)
  end
  C_Timer.After(COMMAND_POLL_INTERVAL, poll)
end

-- Runs `fn` once the command channel is idle. Never issues anything itself.
local function WhenIdle(fn, onTimeout)
  if not CommandPending() then
    fn()
    return
  end
  WaitForCommand(function(timedOut)
    if timedOut then
      onTimeout()
      return
    end
    fn()
  end)
end

-------------------------------------------------------------
-- Command layer :: exclusive ownership of the channel
--
-- IsCommandPending is a client-wide flag, not a per-caller one, so two Postbox
-- sequences running at once would interleave their commands and each would read
-- the other's handshake as its own. One sequence at a time, enforced here rather
-- than trusted to the UI: clicking a mail row during a bulk run must be a no-op,
-- not a corrupted run.
-------------------------------------------------------------

local channelOwner = nil

function Mail.IsBusy()
  return channelOwner ~= nil
end

local function Claim()
  if channelOwner then return nil end
  channelOwner = {}
  return channelOwner
end

local function Release(token)
  if channelOwner == token then channelOwner = nil end
end

-------------------------------------------------------------
-- Command layer :: the body fetch
--
-- GetInboxText is the one mail API the UI used to call for itself, and it is
-- the one that most deserves not to be: it reads like a getter and it is not.
-- It is a server command that loads the body AND the attachment links AND marks
-- the mail read -- which, on a mail holding nothing else, moves it out of the
-- Collect tab's actionable list the moment it lands. Every caller has to know
-- that, so it is stated here once instead of in a comment beside each call.
--
-- Refused while another Postbox sequence owns the channel: a command issued
-- then is discarded by the server, and its handshake would be read by the
-- sequence that does own the channel as its own acknowledgement. nil means
-- "nothing was sent"; "" means the mail genuinely has no text.
--
-- No handshake of its own. This is a fetch whose result the caller reads
-- immediately from the cache the client keeps for the open mailbox; the
-- sequences that need the fetch to have LANDED (Mail.CollectMail) wait on
-- IsCommandPending themselves and do not come through here.
-------------------------------------------------------------

function Mail.FetchMailBody(index)
  if type(GetInboxText) ~= "function" then return nil end
  if Mail.IsBusy() then return nil end
  if not MailboxOpen() then return nil end
  local text = GetInboxText(index)
  if type(text) ~= "string" then return "" end
  return text
end

-------------------------------------------------------------
-- Command layer :: server refusal reason (best effort)
--
-- When the server refuses a take it tells the player why, as an ordinary red UI
-- error ("You already have one of those", "You can't carry any more of those
-- items"). That text is far more useful than anything we could infer, so it is
-- captured -- carefully, because UI_ERROR_MESSAGE is global and fires for
-- anything the player does.
--
-- Every one of these holds before the text is handed back:
--   * the listener is open only from just before a take until shortly after its
--     handshake clears, so errors from the rest of the session are never seen;
--   * the text is only read after we have INDEPENDENTLY established, from the
--     mail's own contents, that the take was refused;
--   * if two different messages arrived inside the window we cannot say which
--     (if either) belongs to the mail, so nothing is returned.
--
-- The caller is expected to attribute it as the game's words, never as our own
-- conclusion about the cause.
-------------------------------------------------------------

local ErrorWatch = { message = nil, ambiguous = false, active = false, frame = nil }

function ErrorWatch.Open()
  if not ErrorWatch.frame then
    local f = CreateFrame("Frame")
    f:SetScript("OnEvent", function(_, _, a1, a2)
      if not ErrorWatch.active then return end
      -- Retail passes (errorType, message); older signatures pass the message
      -- alone. Take whichever argument is the string.
      local msg = (type(a2) == "string" and a2) or (type(a1) == "string" and a1) or nil
      if not msg or msg == "" then return end
      if ErrorWatch.message == nil then
        ErrorWatch.message = msg
      elseif ErrorWatch.message ~= msg then
        ErrorWatch.ambiguous = true
      end
    end)
    ErrorWatch.frame = f
  end
  ErrorWatch.message = nil
  ErrorWatch.ambiguous = false
  ErrorWatch.active = true
  ErrorWatch.frame:RegisterEvent("UI_ERROR_MESSAGE")
end

function ErrorWatch.Close()
  if ErrorWatch.frame then
    ErrorWatch.frame:UnregisterEvent("UI_ERROR_MESSAGE")
  end
  ErrorWatch.active = false
  if ErrorWatch.ambiguous then return nil end
  return ErrorWatch.message
end

-------------------------------------------------------------
-- Command layer :: does this index still name the mail we started on
--
-- An index stops naming a mail the moment that mail is emptied: the server
-- deletes it and every higher index slides down onto it. Anything measured
-- after that is a fact about somebody else's mail. Sender + subject + C.O.D. is
-- not a unique id -- two identical auction mails collide -- but a collision
-- means the two are interchangeable for the only question being asked, and the
-- alternative (no check at all) is to keep firing takes at whatever moved in.
-------------------------------------------------------------

local function Fingerprint(index)
  local _, _, sender, subject, _, cod = GetInboxHeaderInfo(index)
  if sender == nil and subject == nil then return nil end
  return tostring(sender) .. "\001" .. tostring(subject) .. "\001" .. tostring(tonumber(cod) or 0)
end

-- fingerprint -> what the same mail's fingerprint reads once its C.O.D. is
-- paid, or nil for a mail that owes none. The first take from a C.O.D. mail
-- pays the whole amount and the header reads 0 from then on, so a mail with
-- more than one item changes fingerprint under a take that landed while the
-- rest of its items are still in it. RunPlan follows it across that one
-- change and no other. A mail that owes nothing -- almost every mail --
-- answers from the find, which builds no string.
local function PaidFingerprint(fingerprint)
  if type(fingerprint) ~= "string" or fingerprint:find("\0010$") then return nil end
  local head, cod = fingerprint:match("^(.*\001)([^\001]*)$")
  if not head or (tonumber(cod) or 0) <= 0 then return nil end
  return head .. "0"
end

-------------------------------------------------------------
-- The stuck registry
--
-- A mail whose attachment the server refuses stays in the inbox looking exactly
-- like a mail nobody has got round to yet: read, still holding something, and
-- silent about why. The registry is what turns that into a statement -- this
-- mail, this reason -- so the screens can say it instead of leaving the player
-- to work it out from a chat line that scrolled away.
--
-- Keyed by FINGERPRINT, not by index. An index stops naming its mail the moment
-- a neighbour is emptied, so an index-keyed flag would migrate onto whichever
-- mail slid down into the slot -- exactly the bug LiveIndex exists to prevent,
-- reintroduced in a table.
--
-- WHAT GETS RECORDED. Only a hard per-item refusal: the take was issued, the
-- server acknowledged the command, the grace period passed, and the mail is
-- verifiably unchanged. That is the one outcome that says something about this
-- mail rather than about the connection. The transient stops are deliberately
-- excluded and each would be a lie in a different way:
--   timeout  the command may still be in flight; the take may yet land.
--   busy     nothing was sent at all -- another sequence owned the channel.
--   closed   nothing was sent at all -- the player walked away.
-- And one refusal is not about the mail at all: no room in the bags. That is
-- a state of the character -- every mail with an item in it would be refused
-- the same way, and all of them come out the moment a slot is free -- so it
-- is kept as one (see "Bags full" below) and never recorded here. What is
-- recorded is what stays true of THIS mail until it is taken: "you can't carry
-- any more of those", a unique the player already holds, or a refusal with no
-- words attributable to it while the bags had room.
--
-- COUNTED BY MAIL. Every read below is per inbox index: two identical mails
-- that share a fingerprint are two stuck mails, and both are counted and
-- listed. (The registry keys them together, which is right for the only
-- question it answers -- the twin of a mail refused for a unique would be
-- refused too.)
--
-- LIFETIME. The session -- entries live until logout, not until the mailbox
-- closes (see .dev/SPEC-RunMemory.md: the close-time wipe was reversed, since
-- reopening to find every warning gone made the one mail that would not come
-- out look exactly like the ones that would). A refusal is a fact established
-- by a command WE issued; the rules below keep it honest between visits:
--   * recorded when a take is refused, with the game's own words where the
--     error watch could attribute them to this mail and `true` where it could
--     not (two refusals with different words collapse to `true` as well: quoting
--     one would misdescribe the other);
--   * cleared for a mail whose attachments are subsequently taken -- a take that
--     lands is proof the condition has gone, and it is the reason a player who
--     empties a bag and retries does not keep the marker;
--   * ignored -- neither shown nor counted -- while no mail currently in the
--     inbox matches the fingerprint, or while the mail it matches is empty. That
--     is what stops ghosts of collected, deleted and returned mail inflating the
--     count, and it also covers a mail emptied from outside Postbox, where no
--     clear path of ours ever ran. Filtered rather than deleted, because the
--     inbox is truncated above ~50 mails and reads empty between MAIL_SHOW and
--     the first MAIL_INBOX_UPDATE: an entry that matches nothing right now may
--     match again a moment later, and deleting it there would lose a live fact;
--   * NOT wiped at mailbox close. The filter above already silences any entry
--     the next visit cannot re-match, the marker is phrased as history in the
--     game's own words rather than a claim about the present, and one retry
--     re-establishes the truth. Run memory saves a capped snapshot at each
--     close (Core/CollectTab.lua) and seeds it back after a relog.
-------------------------------------------------------------

-- fingerprint -> the game's error text, or `true` for "refused, no attributable
-- reason". Never false and never nil for a live entry, so `~= nil` is the test.
local stuck = {}
local stuckEntries = 0
-- Scratch for the prune pass, so it allocates nothing.
local stuckSeen = {}
-- sender -> subject -> how many entries carry that sender and subject: the
-- part of a fingerprint a header read hands over without building a string.
-- StuckAt asks it first, so a mail that shares neither with any stuck mail --
-- almost every mail, on every list walk and row bind -- costs two lookups
-- and no fingerprint. Kept in step by the three writers below.
local stuckMarks = {}

-- The game's words for "no room in your bags", in the client's own language:
-- its global strings, compared as they are (the error watch hands over the
-- text the client displayed). Built on first use; a client missing one simply
-- has one fewer to match.
local bagWords = nil

local function IsBagsWords(text)
  if type(text) ~= "string" or text == "" then return false end
  if not bagWords then
    bagWords = {}
    if type(ERR_INV_FULL) == "string" and ERR_INV_FULL ~= "" then bagWords[ERR_INV_FULL] = true end
    if type(ERR_BAG_FULL) == "string" and ERR_BAG_FULL ~= "" then bagWords[ERR_BAG_FULL] = true end
  end
  return bagWords[text] == true
end

-- fingerprint -> its sender and subject as Fingerprint wrote them.
local function MarkOf(fingerprint)
  return fingerprint:match("^([^\001]*)\001(.*)\001[^\001]*$")
end

local function Mark(fingerprint, delta)
  local sender, subject = MarkOf(fingerprint)
  if not sender then return end
  local bySender = stuckMarks[sender]
  if not bySender then
    if delta < 0 then return end
    bySender = {}
    stuckMarks[sender] = bySender
  end
  local n = (bySender[subject] or 0) + delta
  if n > 0 then
    bySender[subject] = n
  else
    bySender[subject] = nil
    if next(bySender) == nil then stuckMarks[sender] = nil end
  end
end

-- The one way in. `fingerprint` is the mail's, `reason` the game's words or
-- nil; words that are about the bags are never recorded (see above).
local function NoteStuck(fingerprint, reason)
  if not fingerprint then return end
  local text = (type(reason) == "string" and reason ~= "") and reason or nil
  if text and IsBagsWords(text) then return end

  local prior = stuck[fingerprint]
  if prior == nil then
    stuckEntries = stuckEntries + 1
    stuck[fingerprint] = text or true
    Mark(fingerprint, 1)
    return
  end
  -- A refusal with no attributable text leaves what we already have alone; one
  -- that contradicts it drops the quotation entirely. Same rule as RunPlan's
  -- noteReason, for the same reason.
  if text and prior ~= text then stuck[fingerprint] = true end
end

-- One mail forgets its refusal -- the only clear path the registry has; the
-- whole-registry wipe that once lived alongside it went with the close-time
-- lifetime (see LIFETIME above).
local function ForgetStuck(fingerprint)
  if not fingerprint or stuck[fingerprint] == nil then return end
  stuck[fingerprint] = nil
  stuckEntries = stuckEntries - 1
  Mark(fingerprint, -1)
end

-- index -> entry, fingerprint. The single reading of "is the mail at this index
-- stuck", so the marker on a row, the line in the detail view and the number in
-- the summary can never disagree.
--
-- Four tests, and each rules out a different way of being wrong:
--   the registry is empty         nothing has been refused this visit. First,
--                                 because it is the answer almost every time and
--                                 it costs no API call at all -- which is what
--                                 makes this free to call from the row binder,
--                                 once per visible row per refresh.
--   sender and subject are marked no stuck mail looks like this one, which
--                                 one header read and two lookups settle
--                                 without building its fingerprint.
--   the fingerprint matches       the flag belongs to the mail AT this index and
--                                 not to whoever slid down into the slot.
--   the mail still holds something  a flag only means anything while what was
--                                 refused is still in there. The native mailbox
--                                 or another addon can empty a mail without our
--                                 clear paths running, and "Not collected" on an
--                                 empty mail is simply false.
local function StuckAt(index)
  if stuckEntries == 0 then return nil end
  local _, _, sender, subject = GetInboxHeaderInfo(index)
  if sender == nil and subject == nil then return nil end
  local bySender = stuckMarks[tostring(sender)]
  if not (bySender and bySender[tostring(subject)]) then return nil end
  local fingerprint = Fingerprint(index)
  if not fingerprint then return nil end
  local entry = stuck[fingerprint]
  if entry == nil then return nil end
  if not Mail.HasContent(index) then return nil end
  return entry, fingerprint
end

-- index -> the game's refusal text for this mail, `true` when it was refused
-- with nothing quotable, or nil when it is not stuck. One value, always, and
-- only ever about the mail itself: a refusal for want of bag room is never
-- recorded, so it never answers here.
function Mail.StuckReason(index)
  return (StuckAt(index))
end

-- How many stuck mails are actually in the inbox right now: one per inbox
-- index, so two identical mails refused alike are two (COUNTED BY MAIL).
function Mail.StuckCount()
  if stuckEntries == 0 then return 0 end

  local numItems = tonumber((GetInboxNumItems())) or 0
  local n = 0
  for index = 1, numItems do
    if StuckAt(index) ~= nil then n = n + 1 end
  end
  return n
end

-- How many fingerprints the registry holds, matched or not: for /postbox
-- debug, where a large number is the cost every inbox update pays (PruneStuck
-- and StuckCount walk the inbox whenever this is above zero).
function Mail.StuckEntries()
  return stuckEntries
end

-- The stuck mails as the status tooltip tells them: one row per stuck mail in
-- the inbox, twins included -- sender, subject, and the game's words where it
-- left any. nil rather than an empty table when there is nothing to say, so
-- callers can gate on the return alone. Built only when the tooltip opens.
function Mail.StuckDetails()
  if stuckEntries == 0 then return nil end

  local numItems = tonumber((GetInboxNumItems())) or 0
  local out
  for index = 1, numItems do
    local entry = StuckAt(index)
    if entry ~= nil then
      local _, _, sender, subject = GetInboxHeaderInfo(index)
      out = out or {}
      out[#out + 1] = {
        sender  = tostring(sender or ""),
        subject = tostring(subject or ""),
        reason  = type(entry) == "string" and entry or nil,
      }
    end
  end
  return out
end

-- Forgets the fingerprints no mail in the inbox carries any more -- but only
-- when the whole inbox is in view: every mail the server holds is listed and
-- every header has arrived. A truncated or half-loaded inbox cannot tell
-- "gone" from "not shown yet" (LIFETIME, above), which is why every read
-- filters rather than deletes; this is the one place "gone" is a safe
-- verdict. Without it an entry outlived its mail for good -- saved at each
-- close, revived the next session -- and the next mail with the same sender,
-- subject and C.O.D. (another "Auction won:" for the same item) wore a
-- refusal it never had. `seen` is the caller's word that a real inbox update
-- has landed this visit.
function Mail.PruneStuck(seen)
  if stuckEntries == 0 or not seen or not MailboxOpen() or Mail.IsBusy() then return end
  local numItems, totalItems = GetInboxNumItems()
  numItems = tonumber(numItems) or 0
  totalItems = tonumber(totalItems) or numItems
  if totalItems ~= numItems then return end
  for key in pairs(stuckSeen) do stuckSeen[key] = nil end
  for index = 1, numItems do
    local _, _, sender, subject, money, _, _, itemCount = GetInboxHeaderInfo(index)
    if sender == nil and subject == nil then return end
    -- Whatever the header still counts keeps the entry: an emptied mail's
    -- header reads zero, one whose item links have not loaded yet does not.
    if (tonumber(money) or 0) > 0 or (tonumber(itemCount) or 0) > 0
      or Mail.AttachmentsLeft(index) > 0 then
      stuckSeen[Fingerprint(index)] = true
    end
  end
  for fingerprint in pairs(stuck) do
    if not stuckSeen[fingerprint] then ForgetStuck(fingerprint) end
  end
end

-- The registry flattened for run memory's saved layer (fingerprint -> reason,
-- `true` where nothing was quotable), capped so a pathological session cannot
-- bloat SavedVariables. nil when there is nothing worth saving.
local STUCK_SNAPSHOT_CAP = 25

function Mail.StuckSnapshot()
  if stuckEntries == 0 then return nil end
  local out, n = {}, 0
  for fingerprint, entry in pairs(stuck) do
    n = n + 1
    if n > STUCK_SNAPSHOT_CAP then break end
    out[fingerprint] = entry
  end
  if next(out) == nil then return nil end
  return out
end

-- The inverse, at the next session's first mailbox visit: revive a saved
-- snapshot into the live registry so the row triangles and the Stuck count
-- come back after a relog, not just the summary sentence. Additive, and it
-- loses to live entries -- a fingerprint this session has already judged
-- keeps this session's verdict. Safe to revive optimistically: every read
-- re-validates against the live inbox (StuckAt), so an entry whose mail was
-- collected, returned or expired since simply never shows.
--
-- An entry in the game's words for full bags is dropped, not revived: records
-- saved before bags full became a state of its own carry them, and full bags
-- were never a fact about the mail (see WHAT GETS RECORDED).
function Mail.SeedStuck(entries)
  if type(entries) ~= "table" then return end
  for fingerprint, entry in pairs(entries) do
    if type(fingerprint) == "string" and stuck[fingerprint] == nil
      and (entry == true or (type(entry) == "string" and not IsBagsWords(entry))) then
      stuckEntries = stuckEntries + 1
      stuck[fingerprint] = entry
      Mark(fingerprint, 1)
    end
  end
end

-------------------------------------------------------------
-- Bags full
--
-- A take the server refuses for want of room (the game's words are
-- ERR_INV_FULL or ERR_BAG_FULL, or it said nothing we could attribute while
-- no general bag slot was free) is a fact about the character, not the mail:
-- every mail with an item in it would be refused the same way, and every one
-- of them comes out once there is room. So it is a state, set by the refusal
-- (RunPlan), and it does three things while it holds:
--   * the run that met it stops there, as a bags stop;
--   * bulk collection leaves every mail holding items where it is
--     (Mail.HeldBack), so the buttons count, and take, only what needs no
--     room -- gold -- instead of walking into the same refusal mail by mail;
--   * the status line says so, with how many mails are waiting for room
--     (Mail.BagsWaiting).
-- Nothing is marked on a mail and nothing is saved.
--
-- It lasts while the mailbox is open and the bags have no more room than they
-- had when it was set. BAG_UPDATE_DELAYED is listened to only while it holds,
-- and each one compares the free slots (Mail.FreeBagSlots, general and reagent
-- together: room in either may be what the refused item needed) with the
-- fewest seen since: more than that, and it clears -- the shell is told, and
-- the buttons count those mails again. It never collects by itself; the
-- player clicks. The mailbox closing ends it quietly, and the listener goes
-- with it.
-------------------------------------------------------------

local bags = { on = false, low = nil, frame = nil }

-- Every free slot the player has, or nil when the bags cannot be counted.
local function RoomNow()
  local free, reagent = Mail.FreeBagSlots()
  if free == nil then return nil end
  return free + (reagent or 0)
end

-- The shell repaints its status line and recounts the buttons.
local function BagsChanged()
  local UI = ns.MailboxUI
  if UI and type(UI.OnBagsFullChanged) == "function" then pcall(UI.OnBagsFullChanged) end
end

local function ClearBagsFull(quiet)
  if not bags.on then return end
  bags.on, bags.low = false, nil
  local f = bags.frame
  if f then
    f:UnregisterEvent("BAG_UPDATE_DELAYED")
    f:UnregisterEvent("MAIL_CLOSED")
    f:UnregisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
  end
  if not quiet then BagsChanged() end
end

local function OnBagsEvent(_, event, kind)
  if not bags.on then return end
  -- The mailbox closed, by either signal: the state ends with the visit. The
  -- interaction manager's hide is every window's; only the mailbox's counts.
  if event == "MAIL_CLOSED" then return ClearBagsFull(true) end
  if event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
    local enum = type(Enum) == "table" and Enum.PlayerInteractionType or nil
    if enum and kind == enum.MailInfo then ClearBagsFull(true) end
    return
  end
  if not MailboxOpen() then return ClearBagsFull(true) end
  local free = RoomNow()
  -- Uncountable bags cannot say there is still no room; the next try will.
  if free == nil or bags.low == nil or free > bags.low then return ClearBagsFull() end
  if free < bags.low then bags.low = free end
end

-- A take was refused for want of room. Idempotent: a second refusal only
-- lowers the mark room has to rise above.
local function SetBagsFull()
  local free = RoomNow()
  if bags.on then
    if free and bags.low and free < bags.low then bags.low = free end
    return
  end
  bags.on, bags.low = true, free
  if not bags.frame then
    bags.frame = CreateFrame("Frame")
    bags.frame:SetScript("OnEvent", OnBagsEvent)
  end
  bags.frame:RegisterEvent("BAG_UPDATE_DELAYED")
  bags.frame:RegisterEvent("MAIL_CLOSED")
  bags.frame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
  BagsChanged()
end

-- Whether the bags-full state holds. A mailbox that has closed without either
-- close signal reaching us ends it here, quietly.
function Mail.BagsFull()
  if not bags.on then return false end
  if not MailboxOpen() then
    ClearBagsFull(true)
    return false
  end
  return true
end

-- index [, itemCount] -> why bulk collection leaves this mail where it is for
-- now, or nil: "bags" for a mail holding items while the bags are full,
-- "stuck" for a mail the server refused (Mail.StuckReason). `itemCount`, the
-- header's, where the caller has already read it. Free while neither state
-- holds -- two comparisons -- so the list walk asks it of every mail.
function Mail.HeldBack(index, itemCount)
  if bags.on then
    if itemCount == nil then itemCount = Mail.AttachmentCount(index) end
    if itemCount > 0 then return "bags" end
  end
  if stuckEntries > 0 and StuckAt(index) ~= nil then return "stuck" end
  return nil
end

-- How many mails are waiting for bag room: holding items, and otherwise
-- what a sweep would take (no C.O.D., not stuck, not on its way out). 0 while
-- the bags are not full. Asked by the status line, never by the list walk.
function Mail.BagsWaiting()
  if not bags.on then return 0 end
  local numItems = tonumber((GetInboxNumItems())) or 0
  local n = 0
  for index = 1, numItems do
    local _, _, sender, subject, _, cod, _, itemCount = GetInboxHeaderInfo(index)
    if (sender ~= nil or subject ~= nil) and (tonumber(itemCount) or 0) > 0
      and (tonumber(cod) or 0) <= 0 and StuckAt(index) == nil and not Mail.Leaving(index) then
      n = n + 1
    end
  end
  return n
end

-------------------------------------------------------------
-- Mail on its way out
--
-- A mail with no text of its own -- every auction house mail, most of the
-- game's own mail, a parcel sent without a note -- does not outlive what is
-- in it: once its last item or coin is taken, the client deletes it. That
-- delete is a round trip of its own, so the inbox update that removes the
-- mail comes a moment after the one that shows it emptied, and in between it
-- reads read and empty -- exactly what finished mail looks like. The collect
-- screen listed it under the divider and counted it, and the next update
-- took it away again: "Read, nothing left (1)" flashing up at the foot of
-- the list for a mail that was never going to stay.
--
-- WHICH MAILS GO. The header's textCreated. A mail sent with no text arrives
-- already marked as copied -- there is nothing in it to copy -- just as one
-- is marked once its text has been taken as a letter, and it is the flag the
-- client's own mail frame deletes an emptied mail on as it closes. A letter
-- that still has its words does not carry it, and stays. An auction mail has
-- no text to keep whatever the flag says, so its category is a second
-- witness.
--
-- WHICH MAILS ARE HELD. Only a mail Postbox is emptying. Each take marks its
-- mail as it is issued -- before, because the update showing the mail
-- emptied can reach the list before the take's own handshake is read -- and
-- again once it has landed. Marked by sender and subject, the part of a mail
-- a take cannot change (a paid C.O.D. reads 0 afterwards); two identical
-- auction mails share a mark, and both are on their way out once empty.
--
-- FOR HOW LONG. Until it goes, which needs nothing from here: the mail stops
-- matching. A mark lapses LEAVING_HOLD seconds after its last take, so a mail
-- that stays after all -- a letter whose text was taken as an item outside
-- Postbox -- is listed and counted again then, and the collect screen looks
-- again when it lapses (Core/CollectTab.lua, RV.Leaving). Session state only.
-------------------------------------------------------------

local LEAVING_HOLD = 5

-- sender -> subject -> when that mark's hold lapses (GetTime). Two levels
-- rather than one joined key, so the list walk's lookup builds no string.
-- `last` is the latest lapse of all, so a registry whose holds have all
-- lapsed empties itself on the next ask.
local leaving = { marks = {}, count = 0, last = 0 }

-- index -> the mail's mark, as sender and subject; nil for a header that has
-- not arrived.
local function LeavingMark(index)
  local _, _, sender, subject = GetInboxHeaderInfo(index)
  if sender == nil and subject == nil then return nil end
  return sender or "", subject or ""
end

-- Starts, or restarts, a mark's hold.
local function HoldLeaving(sender, subject)
  if sender == nil or type(GetTime) ~= "function" then return end
  local at = GetTime() + LEAVING_HOLD
  local bySender = leaving.marks[sender]
  if not bySender then
    bySender = {}
    leaving.marks[sender] = bySender
  end
  if bySender[subject] == nil then leaving.count = leaving.count + 1 end
  bySender[subject] = at
  if at > leaving.last then leaving.last = at end
end

-- index -> when the hold on the mail at this index lapses, or nil. Non-nil:
-- Postbox has just emptied this mail and the client is deleting it, so the
-- collect screen leaves it out of the list and every count. Free while
-- nothing is held -- the answer almost every time -- so the list walk asks
-- it of every mail.
function Mail.Leaving(index)
  if leaving.count == 0 then return nil end
  local now = GetTime()
  if now >= leaving.last then
    for sender in pairs(leaving.marks) do leaving.marks[sender] = nil end
    leaving.count = 0
    return nil
  end
  local _, _, sender, subject, money, _, _, itemCount, _, _, textCreated = GetInboxHeaderInfo(index)
  if sender == nil and subject == nil then return nil end
  local bySender = leaving.marks[sender or ""]
  local at = bySender and bySender[subject or ""]
  if not at or now >= at then return nil end
  if (tonumber(money) or 0) > 0 or (tonumber(itemCount) or 0) > 0 then return nil end
  if not textCreated and Mail.ClassifyMail(index) == "other" then return nil end
  if Mail.AttachmentsLeft(index) > 0 then return nil end
  return at
end

-- index -> whether the mail has words of its own: a letter somebody wrote,
-- whose text goes with it when it is deleted. The rule above, read the other
-- way round: textCreated (sent with no text, or its text already taken as a
-- letter) or an auction mail's category says there is nothing of its own to
-- keep. False for a header that has not arrived.
function Mail.HasOwnText(index)
  local _, _, sender, subject, _, _, _, _, _, _, textCreated = GetInboxHeaderInfo(index)
  if sender == nil and subject == nil then return false end
  if textCreated then return false end
  return Mail.ClassifyMail(index) == "other"
end

-------------------------------------------------------------
-- Command layer :: per-mail take runner
--
-- Two very different things go wrong during a take and they need opposite
-- responses:
--
--   Handshake timeout -- IsCommandPending never cleared. The command may still
--     be in flight and the next one would be silently discarded, so the run has
--     to stop. This is the mail-loss guard.
--
--   Refusal -- the handshake completed normally but the mail is unchanged, so
--     the server rejected this particular take: an item the player already
--     holds, a unique item, one they cannot carry more of. Nothing is at risk.
--     Skip that slot and carry on, because one un-takeable item must not block
--     everything else. Unless the refusal was for want of room ("Bags full"):
--     then every further take would be refused too, and the plan ends there.
--
-- `plan` entries are { kind = "money" } or { kind = "item", slot = n }. The plan
-- is a snapshot and each entry fires at most once, so a refused attachment is
-- never retried within a run and the runner cannot loop.
--
-- Calls done(timedOut, refusedCount, reason, fingerprint, bags) exactly once,
-- where `fingerprint` is the mail's as the plan last knew it: the one it was
-- given, or its paid form once a take has paid the mail's C.O.D.
-- (PaidFingerprint), and `bags` is true when a take was refused for want of
-- room and the plan stopped there.
-------------------------------------------------------------

-- The history (Core/MailMemory.lua, 2c): what is known of a mail before its
-- first take, and each CONFIRMED take after it. One record is one History
-- entry, so a caller making several separate takes from one mail -- the
-- reading view's tiles and its Take all -- hands the same record to each.
-- Under pcall: a record that fails to write must never stop a collection.
local function HistoryRecord(index, given)
  if given then return given end
  local History = ns.MailMemory
  if not (History and type(History.HistoryBegin) == "function") then return nil end
  local ok, record = pcall(History.HistoryBegin, index)
  return ok and record or nil
end

local function HistoryNote(record, what, value, count)
  local History = ns.MailMemory
  if record and History and type(History.HistoryTook) == "function" then
    pcall(History.HistoryTook, record, what, value, count)
  end
end

Mail.HistoryRecord = HistoryRecord
Mail.HistoryNote = HistoryNote

-- `keepFree`, where a collect run passes it: the general bag slots the run
-- leaves free ("Keep bag slots free", Mail.KeepFreeReached). An item take
-- that would go below it is not issued; the plan ends there with `kept`
-- (done's sixth value) and nothing recorded against the mail. Money takes
-- need no room and still go.
local function RunPlan(index, fingerprint, plan, done, record, keepFree)
  local cursor = 0
  local refused = 0
  local reason, reasonMixed = nil, false
  -- A C.O.D. mail's fingerprint once paid, and whether an item take of ours
  -- has landed on it -- the first one is the payment. Until one has, the
  -- paid form names some other mail, not this one.
  local paidFingerprint, tookItem = PaidFingerprint(fingerprint), false

  -- Each take is recorded once it is CONFIRMED, from the two places below
  -- that establish it.
  record = HistoryRecord(index, record)
  -- The mail's mark for "Mail on its way out", read before each take while
  -- the index still names it: by the time a take is confirmed, an emptied
  -- mail may already be gone and the index somebody else's.
  local markSender, markSubject
  local function Took(op, value, count)
    if op.kind == "item" then tookItem = true end
    HoldLeaving(markSender, markSubject)
    HistoryNote(record, op.kind, value, count)
  end

  local function noteReason(text)
    if not text or text == "" or reasonMixed then return end
    if reason == nil then
      reason = text
    elseif reason ~= text then
      -- Two attachments refused for different reasons; quoting one would
      -- misdescribe the other.
      reason, reasonMixed = nil, true
    end
  end

  local function step()
    cursor = cursor + 1
    local op = plan[cursor]
    if not op then
      done(false, refused, reason, fingerprint)
      return
    end

    -- The mail went away (emptied and deleted, or the inbox reindexed). Whatever
    -- is at this index now is not ours to take from.
    local now = Fingerprint(index)
    if now ~= fingerprint then
      -- Except the one change our own take makes to a mail that stays: the
      -- C.O.D. it paid, which the header reads as 0 from then on. Same sender
      -- and subject, nothing owed, and an item of the plan's still to take,
      -- so the take that paid cannot have emptied it: this is the mail the
      -- player confirmed, paid, with the rest of its items. Adopted once;
      -- from then on a mail that still owes a C.O.D. never matches, so
      -- nothing is paid twice and nothing is paid unasked.
      if not (tookItem and paidFingerprint and now == paidFingerprint) then
        done(false, refused, reason, fingerprint)
        return
      end
      -- A refusal recorded against the mail as it read before the payment
      -- is still this mail's: an item refused ahead of the take that paid.
      local entry = stuck[fingerprint]
      if entry ~= nil then NoteStuck(now, entry ~= true and entry or nil) end
      fingerprint, paidFingerprint = now, nil
    end

    local function measure()
      if op.kind == "money" then return Mail.MoneyLeft(index) end
      return Mail.AttachmentsLeft(index)
    end

    if op.kind == "item" and not GetInboxItemLink(index, op.slot) then
      -- Slot already empty: an earlier take emptied the mail, or the remaining
      -- attachments compacted downwards. Nothing was refused here.
      return step()
    end

    local before = measure()
    if before <= 0 then return step() end

    if op.kind == "item" and Mail.KeepFreeReached(keepFree) then
      done(false, refused, reason, fingerprint, false, true)
      return
    end

    -- What this take is about to move, read before it moves: the sum, or the
    -- item and its stack size.
    local takes, takeCount = before, nil
    if op.kind == "item" then
      takes = GetInboxItemLink(index, op.slot)
      local _, _, _, count = GetInboxItem(index, op.slot)
      takeCount = tonumber(count) or 1
    end

    markSender, markSubject = LeavingMark(index)
    HoldLeaving(markSender, markSubject)
    ErrorWatch.Open()
    -- A keep-free run's item take is over once the bags have caught up
    -- with it (bagsCatch): the next take is decided from their count.
    local watched = nil
    if op.kind == "money" then
      TakeInboxMoney(index)
    else
      watched = bagsCatch.Watch(keepFree)
      TakeInboxItem(index, op.slot)
    end

    WaitForCommand(function(timedOut)
      if timedOut then
        ErrorWatch.Close()
        bagsCatch.Drop(watched)
        done(true, refused, reason, fingerprint)
        return
      end
      if Fingerprint(index) ~= fingerprint or measure() < before then
        ErrorWatch.Close()
        Took(op, takes, takeCount)
        bagsCatch.After(watched, step)
        return
      end
      -- Looks refused: the handshake completed but the mail is unchanged. Two
      -- things race the acknowledgement -- the server's error text, and the
      -- inbox update that would show the take did land -- so this grace both
      -- catches the reason and avoids calling a slow update a refusal.
      C_Timer.After(ERROR_WATCH_GRACE, function()
        local text = ErrorWatch.Close()
        if Fingerprint(index) ~= fingerprint or measure() < before then
          Took(op, takes, takeCount)
          bagsCatch.After(watched, step)
          return
        end
        -- Nothing moved: nothing is on its way to the bags either.
        bagsCatch.Drop(watched)
        -- The mailbox closed with this command in flight -- the player
        -- walked away mid-take. The unchanged mail proves NOTHING: the
        -- server refuses everything from out of range, and the client's
        -- inbox cache keeps answering with the old headers for a beat, so
        -- without this test the walk-away paints a phantom refusal onto a
        -- perfectly collectable mail (and, via the fingerprint, onto every
        -- identical sibling). End the plan; record nothing.
        if not MailboxOpen() then
          done(false, refused, reason, fingerprint)
          return
        end
        refused = refused + 1
        noteReason(text)
        -- Which refusal this was decides everything after it. No room in the
        -- bags -- the game's words say so, or it said nothing we could
        -- attribute while no general slot was free -- is the character's
        -- state: nothing is recorded against the mail, and the plan stops,
        -- since every further take would meet the same want of room.
        if op.kind == "item"
          and (IsBagsWords(text) or (text == nil and Mail.FreeBagSlots() == 0)) then
          SetBagsFull()
          done(false, refused, reason, fingerprint, true)
          return
        end
        -- The one place a hard per-item refusal is established. Everything the
        -- registry holds comes through here or through CollectMail's closing
        -- verification; no timeout, busy or closed path can reach it -- and
        -- a close DURING flight is caught just above.
        NoteStuck(fingerprint, text)
        step()
      end)
    end)
  end

  step()
end

-------------------------------------------------------------
-- Command layer :: letting the header catch up
--
-- A mail's attachments are read two ways, and for a moment after a take the
-- two can disagree: the slot links, which the take's own result clears, and
-- the header's item count, which comes with the inbox update that follows.
-- That update and the command's handshake race. When the handshake is read
-- first, the links say empty while the header still counts the item, and
-- everything that asks whether a mail is finished (Mail.IsReadPersistent,
-- and through it the "delete" read-mail mode) needs both to agree -- so it
-- answered "not yet" and the question was never asked again.
--
-- So a take that has left the links empty while the header still counts is
-- not over until the header agrees: the sequence keeps the channel and waits
-- for MAIL_INBOX_UPDATE. Event-driven, registered only for the wait, and
-- bounded by one one-shot deadline in case no update comes. Whatever ends
-- the wait, the caller then reads the mail as it stands; a header that never
-- caught up still reads "not finished", and nothing is deleted on the link
-- scan alone. Only the sequence that owns the channel waits, so there is
-- never more than one wait at a time.
-------------------------------------------------------------

local SETTLE_DEADLINE = 3

local settle = { fn = nil, index = nil, fingerprint = nil, gen = 0 }

-- index, fingerprint -> true while the mail is still this one, holds no
-- money and no linked attachment, and its header still counts an item. The
-- header's count first: zero is the answer after almost every take, and it
-- costs one call.
local function HeaderBehind(index, fingerprint)
  local _, _, _, _, money, _, _, itemCount = GetInboxHeaderInfo(index)
  if (tonumber(itemCount) or 0) <= 0 then return false end
  if (tonumber(money) or 0) > 0 then return false end
  if Mail.AttachmentsLeft(index) > 0 then return false end
  return Fingerprint(index) == fingerprint
end

local OnSettleEvent

local function EndSettle()
  local fn = settle.fn
  if not fn then return end
  settle.fn, settle.index, settle.fingerprint = nil, nil, nil
  settle.gen = settle.gen + 1
  local bus = ns.Events
  if bus and type(bus.Unregister) == "function" then
    bus.Unregister("MAIL_INBOX_UPDATE", OnSettleEvent)
    bus.Unregister("MAIL_CLOSED", OnSettleEvent)
  end
  fn()
end

-- An inbox update ends the wait once the header agrees, or once the mail it
-- was waiting on is no longer the one at the index; a closing mailbox ends it
-- outright (the caller's own look then finds the mailbox closed).
function OnSettleEvent(event)
  if not settle.fn then return end
  if event == "MAIL_INBOX_UPDATE" and MailboxOpen()
    and HeaderBehind(settle.index, settle.fingerprint) then
    return
  end
  EndSettle()
end

-- index, fingerprint, fn -> fn(), now or once the header agrees.
local function AfterHeaderSettles(index, fingerprint, fn)
  if not HeaderBehind(index, fingerprint) or not MailboxOpen() then return fn() end
  local bus = ns.Events
  if not (bus and type(bus.Register) == "function") or type(C_Timer) ~= "table" then
    return fn()
  end
  EndSettle()
  settle.fn, settle.index, settle.fingerprint = fn, index, fingerprint
  settle.gen = settle.gen + 1
  local gen = settle.gen
  bus.Register("MAIL_INBOX_UPDATE", OnSettleEvent)
  bus.Register("MAIL_CLOSED", OnSettleEvent)
  C_Timer.After(SETTLE_DEADLINE, function()
    if settle.gen == gen then EndSettle() end
  end)
end

-------------------------------------------------------------
-- Command layer :: public entry points
--
-- Collection statuses, shared by CollectMail and TakeAttachment:
--   "collected" the mail (or slot) is empty.
--   "refused"   every handshake completed, but the server would not hand over
--               `refusedCount` of the attachments. They are still in the
--               mailbox, nothing is at risk, and the caller should carry on.
--   "timeout"   the server stopped acknowledging commands. The caller must not
--               issue another one.
--   "busy"      another Postbox command sequence owns the channel.
--   "closed"    the mailbox is not open; nothing was attempted.
-- A "refused" answer carries a fourth value, `kind`: "bags" when the take was
-- refused for want of bag room ("Bags full": nothing is recorded against the
-- mail, and a run stops), "keep" when a run's opts.keepFree stopped it before
-- an item take (nothing taken from that mail's items, nothing recorded), nil
-- when the refusal is the mail's own (recorded in the stuck registry).
-------------------------------------------------------------

-- index, onDone [, opts] -> nothing. onDone(status, refusedCount, reason, kind).
--
-- opts.skipFetch  the caller has already loaded this mail's body (the detail
--                 overlay has), so the fetch would be a wasted round trip that
--                 can also race a cached response.
-- opts.keepFree   a collect run's "Keep bag slots free": the general bag slots
--                 it leaves free (RunPlan). A mail with items met at that
--                 point, with no gold to take, is left as it is -- not even
--                 fetched, so it stays unread.
function Mail.CollectMail(index, onDone, opts)
  local token = Claim()
  local finished = false

  local function finish(status, refusedCount, reason, kind)
    if finished then return end
    finished = true
    Release(token)
    if onDone then onDone(status, tonumber(refusedCount) or 0, reason, kind) end
  end

  if not token then
    if onDone then onDone("busy", 0, nil) end
    return
  end
  if not MailboxOpen() then return finish("closed") end

  local fingerprint = Fingerprint(index)
  if not fingerprint then return finish("collected") end

  local _, _, _, _, money, cod, _, itemCount, wasRead = GetInboxHeaderInfo(index)
  money = tonumber(money) or 0
  itemCount = tonumber(itemCount) or 0
  -- Taken before anything moves: the entry names the mail as it arrived.
  local record = HistoryRecord(index, opts and opts.history)

  -- TakeInboxItem on a C.O.D. mail PAYS it, and only the single-mail path --
  -- which just showed the player this exact mail's amount -- may do that
  -- (opts.allowCOD). Bulk queues exclude C.O.D. at build time, but that
  -- exclusion named an index, and indices shift: this is the last look before
  -- any command (even the read-marking body fetch) is issued, so the promise
  -- is enforced here, on the mail the index names NOW. Refused with no count:
  -- nothing was taken, nothing is stuck, the mail is not this caller's to
  -- touch.
  if (tonumber(cod) or 0) > 0 and not (opts and opts.allowCOD) then
    return finish("refused", 0, nil)
  end

  -- The run keeps bag slots free and has reached them: a mail that holds
  -- only items has nothing this run may take, and fetching it would only
  -- mark it read. (One with gold goes on: the gold needs no room, and the
  -- plan stops at its first item.)
  if itemCount > 0 and money <= 0 and Mail.KeepFreeReached(opts and opts.keepFree) then
    return finish("refused", 0, nil, "keep")
  end

  -- The body fetch does two jobs: it loads the attachment links (which are nil
  -- until it lands -- enumerating before that finds nothing, which is what makes
  -- a naive implementation report "collected 40 mails" while collecting none),
  -- and it marks the mail read so the server clears its "new mail" flag.
  --
  -- A money-only mail needs neither: taking its money empties it and the server
  -- deletes it, so there is nothing left to be unread. Skipping the fetch there
  -- saves a full round trip per mail, and auction gold is the bulk case.
  local needFetch = not (opts and opts.skipFetch)
  -- Except a READ letter from a person holding only gold: it keeps its text
  -- once emptied, and the fetch is what hands that text to History -- the
  -- only copy once the "delete" read-mail mode has removed the letter. It is
  -- already read, so nothing about its state changes; auction mail has no
  -- text to keep and stays on the fast path.
  if itemCount == 0 and money > 0
    and (not wasRead or Mail.ClassifyMail(index) ~= "other") then
    needFetch = false
  end

  -- skipFetch is a hint, not a promise. If the header says this mail has
  -- attachments and not one link has loaded, the body was never fetched -- so
  -- enumerating now would build an empty plan and report the mail collected
  -- while every attachment was still in it. Fetch regardless.
  if not needFetch and itemCount > 0 and Mail.AttachmentsLeft(index) == 0 then
    needFetch = true
  end

  if type(GetInboxText) ~= "function" then needFetch = false end

  local function execute()
    -- Enumerate only now: before the fetch landed, every link is nil.
    local plan = {}
    if Mail.MoneyLeft(index) > 0 and type(TakeInboxMoney) == "function" then
      plan[#plan + 1] = { kind = "money" }
    end
    if type(TakeInboxItem) == "function" then
      -- Highest slot first. The plan is a snapshot of slot numbers, so working
      -- downwards keeps every queued number valid even if the remaining
      -- attachments compact into the gaps.
      for slot = MAX_ATTACHMENTS, 1, -1 do
        if GetInboxItemLink(index, slot) then
          plan[#plan + 1] = { kind = "item", slot = slot }
        end
      end
    end

    if #plan == 0 then
      -- Nothing left to take: the mail is empty, so whatever was refused before
      -- is no longer true of it.
      ForgetStuck(fingerprint)
      -- A letter with nothing in it is dealt with by reading it, and the
      -- fetch above just did: History lists it, however it was collected.
      if not wasRead and needFetch then HistoryNote(record, "read") end
      return finish("collected")
    end

    RunPlan(index, fingerprint, plan, function(timedOut, refusedCount, reason, current, full, kept)
      if timedOut then return finish("timeout", refusedCount, reason) end
      if full then return finish("refused", refusedCount, reason, "bags") end
      if kept then return finish("refused", refusedCount, reason, "keep") end
      if refusedCount > 0 then return finish("refused", refusedCount, reason) end
      -- Verify rather than assume, independently of the per-operation
      -- measurements. Only meaningful while the index still names this mail:
      -- once it is emptied the server deletes it and a different mail slides in.
      -- And only meaningful while the mailbox is still OPEN: after a
      -- mid-collection walk-away the cached headers read "still full" for
      -- every mail, including ones a retry would take instantly.
      if not MailboxOpen() then
        return finish("closed", refusedCount, reason)
      end
      -- Checked against the mail as the plan last knew it: a C.O.D. it paid
      -- reads 0 now, and the mail it names is still this one.
      current = current or fingerprint
      -- Once the header agrees with the links ("Letting the header catch
      -- up"): a caller told "collected" goes on to ask whether the mail is
      -- finished, and that answer reads the header.
      AfterHeaderSettles(index, current, function()
        if not MailboxOpen() then
          return finish("closed", refusedCount, reason)
        end
        if Fingerprint(index) == current and Mail.HasContent(index) then
          -- Every handshake completed and the mail is still not empty. Nothing
          -- attributable to one take -- so where items stayed while no general
          -- slot was free, that is the bags (see "Bags full"); otherwise the
          -- mail is stuck all the same.
          if Mail.AttachmentsLeft(index) > 0 and Mail.FreeBagSlots() == 0 then
            SetBagsFull()
            return finish("refused", 1, reason, "bags")
          end
          NoteStuck(current, reason)
          return finish("refused", 1, reason)
        end
        ForgetStuck(fingerprint)
        if current ~= fingerprint then ForgetStuck(current) end
        finish("collected", 0, reason)
      end)
    end, record, opts and opts.keepFree)
  end

  WhenIdle(function()
    if not needFetch then return execute() end
    -- The body comes back with the fetch: History keeps a letter's words
    -- (the mail may be deleted once it is finished with).
    local body = GetInboxText(index)
    if record and type(body) == "string" and body ~= "" then record.body = body end
    WaitForCommand(function(timedOut)
      if timedOut then
        -- Attachment data never arrived. Taking blind would fire commands at a
        -- server that is still busy.
        return finish("timeout")
      end
      execute()
    end)
  end, function() finish("timeout") end)
end

-- One attachment slot of a mail whose body is already loaded.
-- onDone(status, refusedCount, reason, kind), as Mail.CollectMail's.
--
-- opts.fetch  the caller may be taking from a mail whose body was never
--             fetched (the Mail tab's fan, which opens on a hover): the slot's
--             link is nil until the fetch lands, so where it is, the body is
--             fetched first, inside this take's own claim of the channel, as
--             Mail.CollectMail fetches before it enumerates. The fetch marks
--             the mail read, as taking anything from it would.
function Mail.TakeAttachment(index, slot, onDone, opts)
  local token = Claim()
  local finished = false

  local function finish(status, refusedCount, reason, kind)
    if finished then return end
    finished = true
    Release(token)
    if onDone then onDone(status, tonumber(refusedCount) or 0, reason, kind) end
  end

  if not token then
    if onDone then onDone("busy", 0, nil) end
    return
  end
  if not MailboxOpen() then return finish("closed") end
  if type(TakeInboxItem) ~= "function" then return finish("collected") end

  local fingerprint = Fingerprint(index)
  -- Not loaded yet, and the caller asked for the fetch: the slot must at
  -- least hold an item the header knows of.
  local fetch = fingerprint ~= nil and opts ~= nil and opts.fetch and not GetInboxItemLink(index, slot)
    and type(GetInboxText) == "function" and GetInboxItem(index, slot) ~= nil
  if not fingerprint or not (fetch or GetInboxItemLink(index, slot)) then
    return finish("collected")
  end

  -- The FIRST take from a C.O.D. mail pays the whole amount, and this path is
  -- reachable from a preview overlay opened on any mail. Same choke-point rule
  -- as Mail.CollectMail: no caller pays without opts.allowCOD, which only the
  -- flows that just confirmed this mail's amount with the player may pass.
  local _, _, _, _, _, codNow = GetInboxHeaderInfo(index)
  if (tonumber(codNow) or 0) > 0 and not (opts and opts.allowCOD) then
    return finish("refused", 0, nil)
  end

  local function take()
    RunPlan(index, fingerprint, { { kind = "item", slot = slot } },
      function(timedOut, refusedCount, reason, current, full)
        if timedOut then return finish("timeout", refusedCount, reason) end
        if full then return finish("refused", refusedCount, reason, "bags") end
        if refusedCount > 0 then return finish("refused", refusedCount, reason) end
        -- A take that landed is proof the refusal no longer holds -- the player
        -- made room, or dropped the unique they already had. If the next slot
        -- is refused anyway, RunPlan records it again immediately.
        ForgetStuck(fingerprint)
        -- The last tile of a mail is over once the header agrees, as a whole
        -- collect is: the reading view's Back asks whether it is finished.
        AfterHeaderSettles(index, current or fingerprint, function()
          finish("collected", 0, reason)
        end)
      end, opts and opts.history)
  end

  WhenIdle(function()
    if not fetch then return take() end
    -- The body first, and the take only once it has landed, on the same
    -- mail, with the slot's item now named by a link (Mail.CollectMail).
    local body = GetInboxText(index)
    local record = opts.history
    if record and type(body) == "string" and body ~= "" and not record.body then record.body = body end
    WaitForCommand(function(timedOut)
      if timedOut then return finish("timeout") end
      if not MailboxOpen() then return finish("closed") end
      if Fingerprint(index) ~= fingerprint or not GetInboxItemLink(index, slot) then
        return finish("collected")
      end
      take()
    end)
  end, function() finish("timeout") end)
end

-------------------------------------------------------------
-- Command layer :: single irreversible commands
--
-- Statuses: "done" | "timeout" | "busy" | "closed" | "unavailable" | "moved".
-- Both reindex the inbox, so a caller batching them must work downwards.
-- Neither asks for confirmation -- that is the UI's job, and the UI must do it.
--
-- `expected` (optional): the fingerprint of the mail the caller means, read
-- when the player acted. The command waits for an idle channel, and another
-- addon's command landing in that wait can reindex the inbox, so the index
-- is re-checked immediately before the command goes, as Mail.DeleteMails
-- does: a mail that has moved is left alone and the answer is "moved", with
-- nothing sent.
-------------------------------------------------------------

local function SingleCommand(issue, onDone, index, expected)
  local token = Claim()
  if not token then
    if onDone then onDone("busy") end
    return
  end

  local finished = false
  local function finish(status)
    if finished then return end
    finished = true
    Release(token)
    if onDone then onDone(status) end
  end

  if not MailboxOpen() then return finish("closed") end

  WhenIdle(function()
    -- The last look before the command (see `expected` above).
    if expected and Fingerprint(index) ~= expected then return finish("moved") end
    issue()
    WaitForCommand(function(timedOut)
      finish(timedOut and "timeout" or "done")
    end)
  end, function() finish("timeout") end)
end

function Mail.DeleteMail(index, onDone, expected)
  if type(DeleteInboxItem) ~= "function" then
    if onDone then onDone("unavailable") end
    return
  end
  SingleCommand(function() DeleteInboxItem(index) end, onDone, index, expected)
end

-- The money alone, for the reading view's coin tile. Same channel rules as
-- everything else: one command at a time, settled by the inbox update.
-- `history` is the reading view's record for this mail, so the coin and the
-- items taken after it land in one History entry.
function Mail.TakeMoney(index, onDone, history)
  if type(TakeInboxMoney) ~= "function" then
    if onDone then onDone("unavailable") end
    return
  end
  -- The coin tile's take is recorded like a run's (Core/MailMemory.lua, 2c),
  -- and only once the sum has actually left the mail: "done" means only that
  -- the handshake cleared.
  local record = HistoryRecord(index, history)
  local fingerprint = Fingerprint(index)
  local amount = Mail.MoneyLeft(index)
  -- Held as a run's take is ("Mail on its way out"): a gold-only mail with
  -- no text goes with its gold.
  local markSender, markSubject
  SingleCommand(function()
    markSender, markSubject = LeavingMark(index)
    HoldLeaving(markSender, markSubject)
    TakeInboxMoney(index)
  end, function(status)
    if status == "done" and amount > 0
      and (Fingerprint(index) ~= fingerprint or Mail.MoneyLeft(index) < amount) then
      HoldLeaving(markSender, markSubject)
      HistoryNote(record, "money", amount)
    end
    if onDone then onDone(status) end
  end)
end

function Mail.ReturnMail(index, onDone, expected)
  if type(ReturnInboxItem) ~= "function" then
    if onDone then onDone("unavailable") end
    return
  end
  SingleCommand(function() ReturnInboxItem(index) end, onDone, index, expected)
end

-- Deletes a list of mails, one command at a time, stopping at the first
-- handshake that times out rather than firing the next into a busy server.
-- onDone(deletedCount, status) where status is "done" | "timeout" | "busy" |
-- "closed" | "unavailable".
--
-- The list is sorted descending here regardless of what the caller passed:
-- deleting reindexes the inbox, and a caller that got the order wrong would
-- delete mail the player never selected.
--
-- `expected` (optional): index -> fingerprint, what the caller believes each
-- index names -- captured when its confirmation dialog went up. Deleting is
-- the irreversible command, so each index is re-verified immediately before
-- its DeleteInboxItem and skipped on a mismatch: the inbox can reindex while
-- a dialog waits AND between the sweep's own commands (a mail arriving
-- mid-sweep shifts every index), and a skipped mail costs one more click
-- where a wrong delete costs the mail.
function Mail.DeleteMails(indices, onDone, expected)
  if type(DeleteInboxItem) ~= "function" then
    if onDone then onDone(0, "unavailable") end
    return
  end

  local list = {}
  for i = 1, #indices do
    local index = tonumber(indices[i])
    if index then list[#list + 1] = index end
  end
  table.sort(list, function(a, b) return a > b end)

  if #list == 0 then
    if onDone then onDone(0, "done") end
    return
  end

  local token = Claim()
  if not token then
    if onDone then onDone(0, "busy") end
    return
  end

  local finished = false
  local deleted = 0
  local function finish(status)
    if finished then return end
    finished = true
    Release(token)
    if onDone then onDone(deleted, status) end
  end

  if not MailboxOpen() then return finish("closed") end

  local cursor = 0
  local function step()
    cursor = cursor + 1
    local index = list[cursor]
    if not index then return finish("done") end
    if not MailboxOpen() then return finish("closed") end

    -- The last look before the irreversible command (see the contract above).
    -- A moved mail is skipped, not chased: fingerprints are not unique across
    -- identical auction mails, so relocating by fingerprint could delete a
    -- sibling the caller never listed.
    if expected and Fingerprint(index) ~= expected[index] then
      return step()
    end

    DeleteInboxItem(index)
    WaitForCommand(function(timedOut)
      if timedOut then return finish("timeout") end
      deleted = deleted + 1
      step()
    end)
  end

  WhenIdle(step, function() finish("timeout") end)
end

-------------------------------------------------------------
-- Inbox refresh
--
-- CheckInbox has been server-throttled to roughly 30 s since 8.3, and a call
-- inside the cooldown is ignored rather than queued. C_Mail.CanCheckInbox
-- reports both facts, so a refused refresh is rescheduled for when it will
-- actually be honoured instead of being dropped.
-------------------------------------------------------------

local refreshScheduled = false

function Mail.RequestInboxRefresh()
  if type(CheckInbox) ~= "function" then return end

  if type(C_Mail) ~= "table" or type(C_Mail.CanCheckInbox) ~= "function" then
    CheckInbox()
    return
  end

  local canCheck, secondsUntilNext = C_Mail.CanCheckInbox()
  if canCheck then
    CheckInbox()
    return
  end

  -- One pending retry at a time; a run that finishes inside the cooldown would
  -- otherwise stack a timer per attempt.
  if refreshScheduled then return end
  refreshScheduled = true
  local delay = (tonumber(secondsUntilNext) or 30) + 0.5
  C_Timer.After(delay, function()
    refreshScheduled = false
    if type(CheckInbox) == "function" and MailboxOpen() then CheckInbox() end
  end)
end
