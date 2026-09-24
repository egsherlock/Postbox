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

local function SubjectCategory(subject)
  if type(subject) ~= "string" or subject == "" then return nil end
  local looksLike = ns.Helpers.SubjectLooksLike
  for _, rule in ipairs(SUBJECT_CATEGORY) do
    if looksLike(subject, rule[1]) then return rule[2] end
  end
  return nil
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
-- The player's own characters, as recipient keys: Postbox.lua's census,
-- account-wide, every realm. Built per queue and per list refresh rather than
-- kept, because the census grows as characters log in.
function Mail.OwnCharacterKeys()
  local set = {}
  local R = ns.Recipients
  local alts = ns.Store and ns.Store.Get and ns.Store.Get("alts")
  if not (R and type(R.Key) == "function") or type(alts) ~= "table" then return set end
  for realm, names in pairs(alts) do
    if type(names) == "table" then
      for i = 1, #names do
        local key = R.Key(names[i] .. "-" .. realm)
        if key then set[key] = true end
      end
    end
  end
  return set
end

-- index [, keys] -> whether the mail is from one of the player's own
-- characters. A bare sender is on the player's realm, which R.Key resolves.
function Mail.FromOwnCharacter(index, keys)
  local _, _, sender = GetInboxHeaderInfo(index)
  if type(sender) ~= "string" or sender == "" then return false end
  local R = ns.Recipients
  local key = R and type(R.Key) == "function" and R.Key(sender) or nil
  return key ~= nil and (keys or Mail.OwnCharacterKeys())[key] == true
end

-- One inbox index, tested against the queue's rules and either taken or
-- accounted for in `info`. Shared by both builders below so they cannot
-- disagree about what a collectable mail is.
local function Consider(index, category, queue, info)
  if not HeaderLoaded(index) then
    info.unloaded = info.unloaded + 1
  elseif not Mail.IsReadPersistent(index) then
    local kind, hasCOD = Mail.ClassifyMail(index)
    local match
    if category == "alts" then
      match = Mail.FromOwnCharacter(index, info.altKeys)
    else
      match = (category == "all" or kind == category)
    end
    if match then
      if hasCOD then
        -- Bulk collection must never spend the player's money.
        info.skippedCOD = info.skippedCOD + 1
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
  }

  if category == "alts" then info.altKeys = Mail.OwnCharacterKeys() end

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
-- BuildQueue applies -- unloaded headers, finished mail, C.O.D. -- applies
-- here too, and the queue comes out descending for the same reason.
function Mail.BuildQueueFor(indices, category)
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
  }

  local sorted = {}
  for i = 1, #indices do
    local index = tonumber(indices[i])
    if index and index >= 1 and index <= numItems then sorted[#sorted + 1] = index end
  end
  table.sort(sorted, function(a, b) return a > b end)
  if category == "alts" then info.altKeys = Mail.OwnCharacterKeys() end
  for i = 1, #sorted do
    Consider(sorted[i], category, queue, info)
  end

  return queue, info
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

-- Free slots in ordinary (family 0) bags, or nil when the container API is
-- unavailable -- in which case the caller should skip the check rather than
-- guess. Profession and reagent bags are excluded: they only accept their own
-- item family, so counting them would overstate the room available for
-- arbitrary mail attachments.
function Mail.FreeBagSlots()
  local getFree = (type(C_Container) == "table" and C_Container.GetContainerNumFreeSlots) or nil
  if type(getFree) ~= "function" then return nil end

  -- NUM_TOTAL_EQUIPPED_BAG_SLOTS covers the reagent bag on current clients. The
  -- family filter below excludes it anyway; including the id costs nothing and
  -- keeps the loop correct if Blizzard makes it a general-purpose bag.
  local lastBag = (type(NUM_TOTAL_EQUIPPED_BAG_SLOTS) == "number" and NUM_TOTAL_EQUIPPED_BAG_SLOTS)
    or (type(NUM_BAG_SLOTS) == "number" and NUM_BAG_SLOTS)
    or 4

  local free = 0
  for bag = 0, lastBag do
    local slots, family = getFree(bag)
    if (tonumber(family) or 0) == 0 then
      free = free + (tonumber(slots) or 0)
    end
  end
  return free
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
--     re-establishes the truth. Nothing is saved; logout is the boundary.
-------------------------------------------------------------

-- fingerprint -> the game's error text, or `true` for "refused, no attributable
-- reason". Never false and never nil for a live entry, so `~= nil` is the test.
local stuck = {}
local stuckEntries = 0
-- Scratch for the counting pass, so a summary refresh allocates nothing.
local stuckSeen = {}

local function NoteStuck(fingerprint, reason)
  if not fingerprint then return end
  local text = (type(reason) == "string" and reason ~= "") and reason or nil

  local prior = stuck[fingerprint]
  if prior == nil then
    stuckEntries = stuckEntries + 1
    stuck[fingerprint] = text or true
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
end

-- index -> entry, fingerprint. The single reading of "is the mail at this index
-- stuck", so the marker on a row, the line in the detail view and the number in
-- the summary can never disagree.
--
-- Three tests, and each rules out a different way of being wrong:
--   the registry is empty         nothing has been refused this visit. First,
--                                 because it is the answer almost every time and
--                                 it costs no API call at all -- which is what
--                                 makes this free to call from the row binder,
--                                 once per visible row per refresh.
--   the fingerprint matches       the flag belongs to the mail AT this index and
--                                 not to whoever slid down into the slot.
--   the mail still holds something  a flag only means anything while what was
--                                 refused is still in there. The native mailbox
--                                 or another addon can empty a mail without our
--                                 clear paths running, and "Not collected" on an
--                                 empty mail is simply false.
local function StuckAt(index)
  if stuckEntries == 0 then return nil end
  local fingerprint = Fingerprint(index)
  if not fingerprint then return nil end
  local entry = stuck[fingerprint]
  if entry == nil then return nil end
  if not Mail.HasContent(index) then return nil end
  return entry, fingerprint
end

-- index -> the game's refusal text for this mail, `true` when it was refused
-- with nothing quotable, or nil when it is not stuck. One value, always.
function Mail.StuckReason(index)
  return (StuckAt(index))
end

-- How many stuck mails are actually in the inbox right now. Deduplicated by
-- fingerprint: two identical auction mails share one, and one entry must not be
-- counted twice just because the mail that produced it has a twin.
function Mail.StuckCount()
  if stuckEntries == 0 then return 0 end

  local numItems = tonumber((GetInboxNumItems())) or 0
  for key in pairs(stuckSeen) do stuckSeen[key] = nil end

  local n = 0
  for index = 1, numItems do
    local entry, fingerprint = StuckAt(index)
    if entry ~= nil and not stuckSeen[fingerprint] then
      stuckSeen[fingerprint] = true
      n = n + 1
    end
  end
  return n
end

-- The stuck mails as the status tooltip tells them: one row per distinct
-- fingerprint currently matching a live mail -- sender, subject, and the
-- game's words where it left any. nil rather than an empty table when there
-- is nothing to say, so callers can gate on the return alone.
function Mail.StuckDetails()
  if stuckEntries == 0 then return nil end

  local numItems = tonumber((GetInboxNumItems())) or 0
  for key in pairs(stuckSeen) do stuckSeen[key] = nil end

  local out
  for index = 1, numItems do
    local entry, fingerprint = StuckAt(index)
    if entry ~= nil and not stuckSeen[fingerprint] then
      stuckSeen[fingerprint] = true
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
function Mail.SeedStuck(entries)
  if type(entries) ~= "table" then return end
  for fingerprint, entry in pairs(entries) do
    if type(fingerprint) == "string" and stuck[fingerprint] == nil
      and (entry == true or type(entry) == "string") then
      stuckEntries = stuckEntries + 1
      stuck[fingerprint] = entry
    end
  end
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
--     everything else.
--
-- `plan` entries are { kind = "money" } or { kind = "item", slot = n }. The plan
-- is a snapshot and each entry fires at most once, so a refused attachment is
-- never retried within a run and the runner cannot loop.
--
-- Calls done(timedOut, refusedCount, reason) exactly once.
-------------------------------------------------------------

local function RunPlan(index, fingerprint, plan, done)
  local cursor = 0
  local refused = 0
  local reason, reasonMixed = nil, false

  -- The history (Core/MailMemory.lua, 2c) hears of each take once it is
  -- CONFIRMED, from the two places below that establish it. Under pcall: a
  -- record that fails to write must never stop a collection.
  local History = ns.MailMemory
  local record = History and History.HistoryBegin and History.HistoryBegin(index) or nil
  local function Took(op, value, count)
    if record and History.HistoryTook then pcall(History.HistoryTook, record, op.kind, value, count) end
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
      done(false, refused, reason)
      return
    end

    -- The mail went away (emptied and deleted, or the inbox reindexed). Whatever
    -- is at this index now is not ours to take from.
    if Fingerprint(index) ~= fingerprint then
      done(false, refused, reason)
      return
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

    -- What this take is about to move, read before it moves: the sum, or the
    -- item and its stack size.
    local takes, takeCount = before, nil
    if op.kind == "item" then
      takes = GetInboxItemLink(index, op.slot)
      local _, _, _, count = GetInboxItem(index, op.slot)
      takeCount = tonumber(count) or 1
    end

    ErrorWatch.Open()
    if op.kind == "money" then
      TakeInboxMoney(index)
    else
      TakeInboxItem(index, op.slot)
    end

    WaitForCommand(function(timedOut)
      if timedOut then
        ErrorWatch.Close()
        done(true, refused, reason)
        return
      end
      if Fingerprint(index) ~= fingerprint or measure() < before then
        ErrorWatch.Close()
        Took(op, takes, takeCount)
        step()
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
          step()
          return
        end
        -- The mailbox closed with this command in flight -- the player
        -- walked away mid-take. The unchanged mail proves NOTHING: the
        -- server refuses everything from out of range, and the client's
        -- inbox cache keeps answering with the old headers for a beat, so
        -- without this test the walk-away paints a phantom refusal onto a
        -- perfectly collectable mail (and, via the fingerprint, onto every
        -- identical sibling). End the plan; record nothing.
        if not MailboxOpen() then
          done(false, refused, reason)
          return
        end
        refused = refused + 1
        noteReason(text)
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
-------------------------------------------------------------

-- index, onDone [, opts] -> nothing. onDone(status, refusedCount, reason).
--
-- opts.skipFetch  the caller has already loaded this mail's body (the detail
--                 overlay has), so the fetch would be a wasted round trip that
--                 can also race a cached response.
function Mail.CollectMail(index, onDone, opts)
  local token = Claim()
  local finished = false

  local function finish(status, refusedCount, reason)
    if finished then return end
    finished = true
    Release(token)
    if onDone then onDone(status, tonumber(refusedCount) or 0, reason) end
  end

  if not token then
    if onDone then onDone("busy", 0, nil) end
    return
  end
  if not MailboxOpen() then return finish("closed") end

  local fingerprint = Fingerprint(index)
  if not fingerprint then return finish("collected") end

  local _, _, _, _, money, cod, _, itemCount = GetInboxHeaderInfo(index)
  money = tonumber(money) or 0
  itemCount = tonumber(itemCount) or 0

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

  -- The body fetch does two jobs: it loads the attachment links (which are nil
  -- until it lands -- enumerating before that finds nothing, which is what makes
  -- a naive implementation report "collected 40 mails" while collecting none),
  -- and it marks the mail read so the server clears its "new mail" flag.
  --
  -- A money-only mail needs neither: taking its money empties it and the server
  -- deletes it, so there is nothing left to be unread. Skipping the fetch there
  -- saves a full round trip per mail, and auction gold is the bulk case.
  local needFetch = not (opts and opts.skipFetch)
  if itemCount == 0 and money > 0 then needFetch = false end

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
      return finish("collected")
    end

    RunPlan(index, fingerprint, plan, function(timedOut, refusedCount, reason)
      if timedOut then return finish("timeout", refusedCount, reason) end
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
      if Fingerprint(index) == fingerprint and Mail.HasContent(index) then
        -- Every handshake completed and the mail is still not empty. Nothing
        -- attributable to one take, but the mail is stuck all the same.
        NoteStuck(fingerprint, reason)
        return finish("refused", 1, reason)
      end
      ForgetStuck(fingerprint)
      finish("collected", 0, reason)
    end)
  end

  WhenIdle(function()
    if not needFetch then return execute() end
    GetInboxText(index)
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
-- onDone(status, refusedCount, reason).
function Mail.TakeAttachment(index, slot, onDone, opts)
  local token = Claim()
  local finished = false

  local function finish(status, refusedCount, reason)
    if finished then return end
    finished = true
    Release(token)
    if onDone then onDone(status, tonumber(refusedCount) or 0, reason) end
  end

  if not token then
    if onDone then onDone("busy", 0, nil) end
    return
  end
  if not MailboxOpen() then return finish("closed") end
  if type(TakeInboxItem) ~= "function" then return finish("collected") end

  local fingerprint = Fingerprint(index)
  if not fingerprint or not GetInboxItemLink(index, slot) then
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

  WhenIdle(function()
    RunPlan(index, fingerprint, { { kind = "item", slot = slot } },
      function(timedOut, refusedCount, reason)
        if timedOut then return finish("timeout", refusedCount, reason) end
        if refusedCount > 0 then return finish("refused", refusedCount, reason) end
        -- A take that landed is proof the refusal no longer holds -- the player
        -- made room, or dropped the unique they already had. If the next slot
        -- is refused anyway, RunPlan records it again immediately.
        ForgetStuck(fingerprint)
        finish("collected", 0, reason)
      end)
  end, function() finish("timeout") end)
end

-------------------------------------------------------------
-- Command layer :: single irreversible commands
--
-- Statuses: "done" | "timeout" | "busy" | "closed" | "unavailable".
-- Both reindex the inbox, so a caller batching them must work downwards.
-- Neither asks for confirmation -- that is the UI's job, and the UI must do it.
-------------------------------------------------------------

local function SingleCommand(issue, onDone)
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
    issue()
    WaitForCommand(function(timedOut)
      finish(timedOut and "timeout" or "done")
    end)
  end, function() finish("timeout") end)
end

function Mail.DeleteMail(index, onDone)
  if type(DeleteInboxItem) ~= "function" then
    if onDone then onDone("unavailable") end
    return
  end
  SingleCommand(function() DeleteInboxItem(index) end, onDone)
end

-- The money alone, for the reading view's coin tile. Same channel rules as
-- everything else: one command at a time, settled by the inbox update.
function Mail.TakeMoney(index, onDone)
  if type(TakeInboxMoney) ~= "function" then
    if onDone then onDone("unavailable") end
    return
  end
  -- The coin tile's take is recorded like a run's (Core/MailMemory.lua, 2c).
  local History = ns.MailMemory
  local record = History and History.HistoryBegin and History.HistoryBegin(index) or nil
  local amount = Mail.MoneyLeft(index)
  SingleCommand(function() TakeInboxMoney(index) end, function(status)
    if status == "done" and record and amount > 0 then
      pcall(History.HistoryTook, record, "money", amount)
    end
    if onDone then onDone(status) end
  end)
end

function Mail.ReturnMail(index, onDone)
  if type(ReturnInboxItem) ~= "function" then
    if onDone then onDone("unavailable") end
    return
  end
  SingleCommand(function() ReturnInboxItem(index) end, onDone)
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
