local _, ns = ...

ns.MailRules = ns.MailRules or {}
local MR = ns.MailRules

-------------------------------------------------------------
-- What the game will do with a mail before it is sent
--
-- One place for the handful of mail rules Postbox is confident enough to state
-- out loud, so the compose screen can say what will happen instead of leaving
-- the player to find out from a red error line -- or, worse, from a mail that
-- never turns up.
--
-- The module is in two halves and the split is the point:
--
--   MR.Assess(ctx)   PURE. Reads nothing but its argument table, calls no
--                    Blizzard API, touches no saved variable, allocates one
--                    result table. Every rule it encodes is listed below with
--                    the fact it rests on, so the rule set can be checked by
--                    reading rather than by playing.
--   MR.Context(...)  the adapter that asks the client and the saved variables
--                    the questions Assess needs answered. Read-only, memoised,
--                    and every call guarded -- a missing API degrades the
--                    assessment, it never errors.
--
-- WHAT THIS MODULE MAY NEVER DO: stop a send. It returns advice; the Send tab
-- shows it and the player decides. Two independent reasons, both real:
--
--   * "Warbound until equipped" gear becomes soulbound the moment it is
--     equipped, so no client-side reading of an item's binding is reliable
--     enough to refuse a send on.
--   * whether a recipient is one of the player's own characters can only ever
--     be guessed at (see KnownOwnCharacters). A false "this will fail" breaks a
--     legal send and gives the player nothing to diagnose.
--
-- Consequently every string this module selects is phrased so that being wrong
-- about the recipient is harmless: it states a rule of the game, never a
-- prediction about this particular mail.
--
-- THE RULES, AND WHERE THEY COME FROM
--
--  1. Cross-realm mail carries Warbound (Battle.net account-bound) items only,
--     to the player's own characters only.
--     Blizzard Support 000012907, "How to Mail Battle.net Account-Bound Items":
--     "You can mail Battle.net Account-bound items to your other characters that
--     reside on a different realm or faction on the same Battle.net account. ...
--     You cannot send gold or non-Battle.net Account-bound items cross-server or
--     cross-faction."
--  2. Gold cannot cross realms; the Warband bank can.
--     Blizzard Support 000010818: "You can send gold and non-soulbound items to
--     your own characters on the same realm". The Warband bank holds gold and
--     any non-soulbound item across every character on the account, so it is the
--     actual answer for what mail refuses to carry -- which is why the
--     cross-realm advice names it instead of stopping at "no".
--  3. Connected realms are the exception to 1 and 2 in practice: 000010818's
--     instructions for sending items "between realms" are addressed to players
--     in a connected group. So the warning fires only for a realm we can show is
--     NOT in the player's connected group -- see ConnectedRealms.
--  4. Mail between the player's own characters is instant, attachments and all;
--     mail from anybody else carrying items or gold takes about an hour; plain
--     text is immediate. (Warcraft Wiki "Mail", corroborated by the 2.1.3 patch
--     note "Mail sent between characters on the same account is now always
--     instant" and the 2007-07-11 coin hotfix.) Stated as an expectation, never
--     as a countdown: the sources say "same account" and predate the Battle.net
--     merge, so whether two WoW licences under one Battle.net account count as
--     one account is not settled.
--  5. C.O.D. is capped. MAX_COD_AMOUNT is 10000 (gold) in the shipped client and
--     Blizzard's own send frame refuses anything above it.
--  6. A character cannot mail itself (ERR_MAIL_TO_SELF).
--
-- DELIBERATELY NOT ENCODED, because the research behind this module could not
-- establish them and a wrong warning costs more than a missing one:
--
--   * whether a text-only mail to another realm is accepted. One player report
--     says no and the client carries ERR_MAIL_CANT_SEND_REALM, but no Blizzard
--     source settles it, so an unattached letter draws no warning here.
--   * the Battle.net-friend cross-faction exception (player testimony only).
--   * any guild-membership privilege, cross-realm or otherwise. No evidence it
--     exists; a cross-realm guildmate is treated exactly like any other
--     off-realm character. The Guild Mail "instant delivery" perk is likewise
--     unconfirmed on the current client, so guild membership changes no
--     delivery estimate here either.
--   * C.O.D.-specific expiry. Sources contradict each other; the inbox reads
--     daysLeft from the server instead.
--   * any per-day gold cap.
--
-- Nothing here is faction-aware. Postbox cannot read an arbitrary recipient's
-- faction, and the one cross-faction rule that IS confirmed -- your own
-- characters can be mailed across factions -- needs no warning.
-------------------------------------------------------------

-- Realm relationship between the sending character and the recipient.
MR.SCOPE_OWN       = "own"        -- same realm
MR.SCOPE_CONNECTED = "connected"  -- a different realm in the connected group
MR.SCOPE_OTHER     = "other"      -- a different, unconnected realm
MR.SCOPE_UNKNOWN   = "unknown"    -- not determinable; assert nothing

-- Expected delivery time.
MR.DELIVERY_INSTANT   = "instant"    -- the player's own characters
MR.DELIVERY_IMMEDIATE = "immediate"  -- a letter with nothing attached
MR.DELIVERY_DELAYED   = "delayed"    -- another player, with items or gold

-- Severity of the guidance line, for the UI to colour by.
MR.INFO = "info"
MR.WARN = "warn"

-- Copper per gold. A constant of the game rather than an API, so Assess may hold
-- it without reaching for COPPER_PER_GOLD and losing its purity.
local COPPER_IN_GOLD = 10000
-- Fallback for MAX_COD_AMOUNT; the live value is read in Context.
local DEFAULT_COD_LIMIT_GOLD = 10000

-------------------------------------------------------------
-- The rule engine (pure)
-------------------------------------------------------------

-- ctx, all fields optional and all defensive:
--
--   realm             recipient's realm, normalised AND lowercased, "" if none
--   ownRealm          the sender's realm, same form, "" if not known yet
--   connectedRealms   set of lowercased normalised realm names, or nil for
--                     "could not ask". nil and empty mean different things:
--                     empty is an answer (no connected realms), nil is not.
--   isSelf            recipient is the sending character
--   knownOwnCharacter recipient is known to be one of the player's own
--                     characters. FALSE MEANS "NO EVIDENCE", never "no".
--   items             number of attached items
--   money             copper in the money field -- attached gold when cod is
--                     false, the amount demanded when it is true
--   cod               the C.O.D. box is ticked
--   codLimitGold      MAX_COD_AMOUNT, in gold
--
-- Returns nil for an empty/unusable recipient, so the caller can simply hide the
-- guidance line. Otherwise:
--
--   { scope, delivery, isSelf, knownOwnCharacter, hasItems, hasMoney, isCOD,
--     guidance = { key = <locale key>, severity = MR.INFO|MR.WARN,
--                  value = <number|nil, format argument> } or nil }
function MR.Assess(ctx)
  if type(ctx) ~= "table" then return nil end
  if type(ctx.name) ~= "string" or ctx.name == "" then return nil end

  local realm    = type(ctx.realm) == "string" and ctx.realm or ""
  local ownRealm = type(ctx.ownRealm) == "string" and ctx.ownRealm or ""
  local items    = (type(ctx.items) == "number" and ctx.items > 0) and ctx.items or 0
  local money    = (type(ctx.money) == "number" and ctx.money > 0) and ctx.money or 0
  local isCOD    = ctx.cod and true or false

  local out = {
    isSelf            = ctx.isSelf and true or false,
    knownOwnCharacter = ctx.knownOwnCharacter and true or false,
    hasItems          = items > 0,
    -- C.O.D. is money the RECIPIENT pays, so it is not gold in transit and none
    -- of the cross-realm gold reasoning applies to it.
    hasMoney          = (not isCOD) and money > 0,
    isCOD             = isCOD,
  }

  -- Realm relationship. Anything we cannot establish stays UNKNOWN, and UNKNOWN
  -- produces no warning at all: silence is the only honest output when the
  -- premise of the warning is a guess.
  if realm == "" or ownRealm == "" then
    out.scope = MR.SCOPE_UNKNOWN
  elseif realm == ownRealm then
    out.scope = MR.SCOPE_OWN
  elseif type(ctx.connectedRealms) ~= "table" then
    out.scope = MR.SCOPE_UNKNOWN
  elseif ctx.connectedRealms[realm] then
    out.scope = MR.SCOPE_CONNECTED
  else
    out.scope = MR.SCOPE_OTHER
  end

  -- Delivery (rule 4). Classified for every mail, whether or not it ends up
  -- being what the line says.
  if out.knownOwnCharacter then
    out.delivery = MR.DELIVERY_INSTANT
  elseif out.hasItems or out.hasMoney or isCOD then
    out.delivery = MR.DELIVERY_DELAYED
  else
    out.delivery = MR.DELIVERY_IMMEDIATE
  end

  -- One line is shown, so one note is chosen: the most consequential first.
  -- A mail that will be refused outranks a mail that will merely be slow.
  local codLimitGold = (type(ctx.codLimitGold) == "number" and ctx.codLimitGold > 0)
    and ctx.codLimitGold or DEFAULT_COD_LIMIT_GOLD

  if out.isSelf then
    -- Rule 6. Identity, not a guess: the recipient resolved to the sending
    -- character's own key.
    out.guidance = { key = "SEND_RULE_SELF", severity = MR.WARN }
  elseif isCOD and money > codLimitGold * COPPER_IN_GOLD then
    -- Rule 5. The client's own gate, so this is certain.
    out.guidance = { key = "SEND_RULE_COD_CAP", severity = MR.WARN, value = codLimitGold }
  elseif out.scope == MR.SCOPE_OTHER and (out.hasItems or out.hasMoney or isCOD) then
    -- Rules 1-3. Only ever for a realm we could show is outside the connected
    -- group, and only when something is actually attached.
    if out.knownOwnCharacter then
      -- Names the route that does work, because "no" on its own is a dead end.
      out.guidance = { key = "SEND_RULE_XREALM_WARBAND", severity = MR.WARN }
    else
      -- Phrased as the rule rather than as a verdict on this recipient: if the
      -- alt list simply has not heard of one of the player's own characters,
      -- this still reads as true and harmless.
      out.guidance = { key = "SEND_RULE_XREALM_STRANGER", severity = MR.WARN }
    end
  elseif out.delivery == MR.DELIVERY_INSTANT then
    out.guidance = { key = "SEND_RULE_DELIVERY_OWN", severity = MR.INFO }
  elseif out.delivery == MR.DELIVERY_DELAYED then
    out.guidance = { key = "SEND_RULE_DELIVERY_HOUR", severity = MR.INFO }
  end
  -- DELIVERY_IMMEDIATE deliberately says nothing. "Your letter will arrive at
  -- once" is not news, and a line that is always on screen stops being read.

  return out
end

-------------------------------------------------------------
-- The adapter (reads the client; never writes)
--
-- Both lookups below are memoised for the life of a mailbox session and dropped
-- by MR.Invalidate, which the Send tab calls when it is shown. Neither answer
-- can change while a mailbox is open -- the player is not logging in an alt or
-- moving realms mid-compose -- and the guidance line is rebuilt on every
-- keystroke in the To: box, so re-querying would put a 200-entry autocomplete
-- scan on the typing path for nothing.
-------------------------------------------------------------

local function Recipients()
  local R = ns.Recipients
  if type(R) == "table" and type(R.Key) == "function" then return R end
  return nil
end

local function Lower(value)
  local h = ns.Helpers
  if type(h) == "table" and type(h.Lower) == "function" then return h.Lower(value) end
  return tostring(value or ""):lower()
end

-- Connected-realm group, as a set of lowercased normalised realm names.
--
-- GetAutoCompleteRealms is used HERE and only here. Core/Recipients.lua refuses
-- it for addressing on purpose -- a bare name always means the sender's own
-- realm, connected group or not -- but that is an argument about what to write
-- into the To: box, not about what to tell the player. For guidance the group
-- membership is exactly the fact that decides whether gold and ordinary items
-- can make the trip, and there is no other API that answers it.
--
-- Returns nil when the question could not be asked at all, which Assess treats
-- as "say nothing". An EMPTY table is a real answer (no connected realms) and is
-- returned as such: Blizzard's generated documentation marks the return
-- non-nilable, and this only ever runs with a mailbox open, long past the
-- PLAYER_LOGIN window in which the list is documented as unpopulated.
local realmSet, realmProbed

local function ConnectedRealms()
  if realmProbed then return realmSet end
  realmProbed = true

  local fn = type(C_AutoComplete) == "table" and C_AutoComplete.GetAutoCompleteRealms or nil
  -- The unnamespaced global was deprecated in 12.0.5 and now lives inside
  -- Blizzard_DeprecatedAutoComplete behind the loadDeprecationFallbacks CVar, so
  -- it is the fallback and not the other way round.
  if type(fn) ~= "function" then fn = GetAutoCompleteRealms end
  if type(fn) ~= "function" then return nil end

  local ok, realms = pcall(fn)
  if not ok or type(realms) ~= "table" then return nil end

  local R = Recipients()
  local set = {}
  for _, name in ipairs(realms) do
    if type(name) == "string" and name ~= "" then
      -- The list is documented as already normalised, but it costs nothing to
      -- put both sides of the comparison through the same normaliser.
      local realm = (R and type(R.NormalizeRealm) == "function") and R.NormalizeRealm(name) or name
      if realm ~= "" then set[Lower(realm)] = true end
    end
  end
  realmSet = set
  return set
end

-- Autocomplete flag for "a character on one of this Battle.net account's game
-- accounts" -- the warband alt set, spanning realms and WoW licences.
-- Enum.AutoCompleteEntryFlag is the source of truth; the literal is the value
-- Blizzard ships, kept only for a client old enough to lack the enum. (These are
-- bit positions in a mask the server understands, not table indices, so the
-- literal cannot drift.)
local function AccountCharacterFlag()
  local enum = type(Enum) == "table" and Enum.AutoCompleteEntryFlag or nil
  local value = type(enum) == "table" and enum.AccountCharacter or nil
  if type(value) == "number" then return value end
  return 0x00000080
end

-- Recipient keys for every character we have reason to believe belongs to this
-- player. Membership is EVIDENCE, absence is NOTHING -- see the two sources:
--
--   PostboxDB.alts        characters that have logged in with Postbox
--                         installed. Certain when present, and blind to any
--                         character the player has not played since installing.
--   account autocomplete  the client's own account-character list, which spans
--                         every realm and every WoW licence on the Battle.net
--                         account. Better coverage, but it is a client-side
--                         cache and can simply be empty.
--
-- So this is a set of "definitely yours"; everything else is "no idea".
local ownKeys

local function KnownOwnCharacters()
  if ownKeys then return ownKeys end
  local R = Recipients()
  if not R then return nil end

  local set = {}
  local function Add(name)
    if type(name) ~= "string" or name == "" then return end
    local key = R.Key(name)
    if key ~= "" then set[key] = true end
  end

  if type(UnitName) == "function" then Add(UnitName("player")) end

  -- alts is realm -> array of BARE names, keyed by the raw GetRealmName() of the
  -- character that wrote it, so the two halves have to be rejoined before they
  -- mean anything: a bare name resolves against whatever realm the player
  -- happens to be on now, which for every other bucket is the wrong one.
  local db = type(PostboxDB) == "table" and PostboxDB or nil
  local alts = db and type(db.alts) == "table" and db.alts or nil
  if alts then
    local normalize = type(R.NormalizeRealm) == "function" and R.NormalizeRealm or nil
    for realmKey, list in pairs(alts) do
      if type(realmKey) == "string" and type(list) == "table" then
        local realm = normalize and normalize(realmKey) or realmKey
        for _, name in ipairs(list) do
          if type(name) == "string" and name ~= "" then
            if realm ~= "" and not name:find("-", 1, true) then
              Add(name .. "-" .. realm)
            else
              Add(name)
            end
          end
        end
      end
    end
  end

  -- GetAutoCompleteResults(text, numResults, cursorPosition, allowFullMatch,
  -- includeBitField, excludeBitField). Best effort: a client that answers
  -- nothing simply leaves us with the saved alts.
  local fn = type(C_AutoComplete) == "table" and C_AutoComplete.GetAutoCompleteResults or nil
  if type(fn) ~= "function" then fn = GetAutoCompleteResults end
  if type(fn) == "function" then
    local ok, results = pcall(fn, "", 200, 0, true, AccountCharacterFlag(), 0)
    if ok and type(results) == "table" then
      for _, entry in ipairs(results) do
        if type(entry) == "table" then
          Add(entry.name)
        elseif type(entry) == "string" then
          Add(entry)
        end
      end
    end
  end

  ownKeys = set
  return set
end

-- Drops both memos. Called when the Send tab is shown, which is the only moment
-- either answer can have changed since it was last needed.
function MR.Invalidate()
  realmSet, realmProbed = nil, nil
  ownKeys = nil
end

-- Builds the ctx table MR.Assess wants from the client's current state.
--
--   recipient  raw To: box text
--   send       { items = <count>, money = <copper>, cod = <bool> }
function MR.Context(recipient, send)
  local ctx = { name = "", realm = "", ownRealm = "" }
  if type(send) == "table" then
    ctx.items = send.items
    ctx.money = send.money
    ctx.cod = send.cod
  end
  if type(MAX_COD_AMOUNT) == "number" and MAX_COD_AMOUNT > 0 then
    ctx.codLimitGold = MAX_COD_AMOUNT
  end

  local R = Recipients()
  if not R then return ctx end

  -- R.Key owns every question about who a written name refers to: it splits the
  -- realm half off, normalises it the way GetNormalizedRealmName does, and
  -- resolves a bare name against the sender's own realm. Nothing here re-derives
  -- any of that.
  local key, short, realm = R.Key(recipient)
  if key == "" then return ctx end
  ctx.name = short
  ctx.realm = Lower(realm)

  -- The sender's own realm comes from the same function applied to the sending
  -- character, so the two realms are guaranteed to be in the same form.
  local ownKey, _, ownRealm = R.Key(type(UnitName) == "function" and UnitName("player") or "")
  ctx.ownRealm = Lower(ownRealm)
  ctx.isSelf = (ownKey ~= "" and key == ownKey)

  ctx.connectedRealms = ConnectedRealms()

  local own = KnownOwnCharacters()
  ctx.knownOwnCharacter = (own ~= nil and own[key] == true)

  return ctx
end

-- The one call the UI makes: recipient text plus what is attached, in; an
-- assessment, or nil, out.
function MR.Inspect(recipient, send)
  return MR.Assess(MR.Context(recipient, send))
end
