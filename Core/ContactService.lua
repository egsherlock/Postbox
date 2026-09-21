local _, ns = ...

-------------------------------------------------------------
-- Recipient sources.
--
-- Answers ONE question: who exists that the player might mail. What the player
-- has decided about those people -- hidden, favourite, note, manually added --
-- belongs to Core/Recipients.lua and is composed on top at query time, never
-- duplicated here.
--
-- The shape is a cache with an invalidation policy, not a per-keystroke
-- aggregator. Collecting the sources means a full guild-roster walk, a friends
-- walk and a Battle.net walk; doing that on every character typed into the To:
-- box is a roster walk per keystroke in a 900-member guild. So each source is
-- gathered into its own pre-sorted array, rebuilt only when an event says THAT
-- source changed, and a query becomes a plain substring scan over the arrays.
--
-- Per-source is the load-bearing word. A friend changing zone must not cost a
-- guild-roster walk, and it used to: every source lived in one snapshot that any
-- presence event discarded whole.
--
-- Two requests here are asynchronous (the guild roster and the friends list).
-- Reading them on the line after asking returns the PREVIOUS answer, and on the
-- first call after login there isn't one -- which is why typing a guildmate's
-- name straight after logging in used to produce nothing. The requests are
-- issued from events instead, and the reads are served from whatever the
-- matching update event last delivered. A server request is never issued from a
-- keystroke.
-------------------------------------------------------------

ns.ContactService = ns.ContactService or {}
local CS = ns.ContactService

-- Resolved at call time, never at file scope, so a TOC reorder degrades into a
-- late error instead of a load-time one. Core/CollectTab.lua reaches across the
-- same way and for the same reason.
local function Helpers() return ns.Helpers end

-------------------------------------------------------------
-- Identity
--
-- ONE canonicalisation point for the whole module. Every collector below hands
-- back exactly what its API gave it -- realm suffix included, because for an
-- off-realm character that suffix IS the address -- and everything downstream
-- goes through these two functions instead of comparing raw strings.
--
--   IdentityKey  who this is:      (name, realm), via Recipients.Key. A bare
--                name resolves against the player's own realm, so "Arsol" from
--                the guild roster and "Arsol-Kazzak" from recent allies are one
--                recipient, while "Arsol-Draenor" stays a different one.
--   Address      how to reach them: via Recipients.Address. Bare on the
--                player's own realm, "Name-Realm" everywhere else.
--
-- Comparing raw normalised strings is what put the same character in the picker
-- twice, once with a realm and once without -- and stripping the realm to make
-- them agree is worse than the duplicate, because the stripped form addresses
-- somebody else.
--
-- Both are nil-tolerant and both degrade to a lowercase/trimmed string if
-- Recipients is somehow unavailable, so nothing here can hard-error on a
-- partially loaded addon.
-------------------------------------------------------------

local function IdentityKey(name)
  local R = ns.Recipients
  if type(R) == "table" and type(R.Key) == "function" then
    return (R.Key(name))
  end
  return Helpers().Lower(name)
end

local function Address(name)
  local R = ns.Recipients
  if type(R) == "table" and type(R.Address) == "function" then
    local value = R.Address(name)
    if value ~= "" then return value end
  end
  return Helpers().NormalizeText(name)
end

-- Realm normalisation for the collectors that receive a bare name and a raw
-- realm as two separate fields and have to join them themselves. Delegates to
-- Recipients so there is exactly one definition of the rule in the addon:
-- spaces, hyphens and periods out, apostrophes KEPT ("Twilight's Hammer" ->
-- "Twilight'sHammer"), which is what GetNormalizedRealmName() does and what
-- mail addressing wants. The inline fallback exists only so a partially loaded
-- addon degrades instead of erroring, and is the same expression.
local function NormalizeRealm(realm)
  local R = ns.Recipients
  if type(R) == "table" and type(R.NormalizeRealm) == "function" then
    return R.NormalizeRealm(realm)
  end
  return (tostring(realm or ""):gsub("[%s%-%.]", ""))
end

-- Joins a bare character name to a raw realm field, or returns the name alone
-- when there is no usable realm. A name that already carries a suffix is left
-- alone so we cannot build "Name-Realm-Realm".
local function JoinRealm(name, realm)
  if type(name) ~= "string" or name == "" then return nil end
  if name:find("-", 1, true) then return name end
  local suffix = NormalizeRealm(realm)
  if suffix == "" then return name end
  return name .. "-" .. suffix
end

-------------------------------------------------------------
-- Collation
--
-- One sort key per name, so that a roster of mixed alphabets lands in a fixed,
-- case-blind order and the compose screen can match what was typed against it
-- without caring how either side was capitalised.
--
-- It lives here, next to the names it describes, rather than in the window that
-- happens to sort them -- for two reasons. It is a property of a NAME, not of a
-- list, so two windows sorting the same roster must not be able to disagree
-- about it. And it is not free: two full passes over the string plus an upper,
-- each allocating. Computed inside a sort comparator, as the contact picker
-- did, a 900-name list is ~9,000 comparisons x 6 allocations -- tens of
-- thousands of transient strings for one click, and again on every favourite
-- toggle, which repopulates in place. Computed once per entry at
-- canonicalisation it is paid once per name per rebuild and then never again.
--
-- The memo is keyed by the string it folds and is a pure function of it, so it
-- is never invalidated for correctness -- it also serves the names that reach
-- no source at all (the player's own stored favourites). It is dropped with the
-- class cache on PLAYER_LEAVING_WORLD only so a session-long list of every name
-- seen does not outlive the character.
--
-- THE FOLD MAPS CHARACTERS, ONE TO ONE. Every letter comes out as exactly one
-- letter -- an accented Latin letter as its base letter, a Cyrillic letter
-- as its capital -- and nothing else in the string moves. Byte lengths are
-- NOT preserved (É is two bytes, E is one) and nothing may assume they are:
-- Core/SendTab.lua's inline completion counts characters on the raw name
-- for that reason. What the one-to-one shape guarantees is the property it
-- does rely on: fold(name) starts with fold(typed) exactly when the first
-- characters of name are, letter for letter, what was typed.
--
-- The fold used to substitute bytes, with byte sets that overlapped, so every
-- Latin-1 accent grouped under A and a Cyrillic letter's continuation byte
-- was eaten by the Latin pass before its own could see it. It was stable, so
-- lists sorted consistently -- into the wrong order.
-------------------------------------------------------------

-- Latin letters carrying a diacritic, filed under the ASCII letter they are
-- meant to sort with. Both cases are listed: Latin-1 has a case fold in the
-- foundation, the Latin Extended letters (Ā, Ć, Ł...) do not, and this table
-- must answer for either spelling.
local ACCENT_GROUPS = {
  { "A", "ÀÁÂÃÄÅàáâãäåĀāĂăĄą" },
  { "C", "ÇçĆćĈĉĊċČč" },
  { "E", "ÈÉÊËèéêëĒēĔĕĖėĘęĚě" },
  { "I", "ÌÍÎÏìíîïĨĩĪīĬĭĮįİı" },
  { "N", "ÑñŃńŅņŇň" },
  { "O", "ÒÓÔÕÖØòóôõöøŌōŎŏŐő" },
  { "U", "ÙÚÛÜùúûüŨũŪūŬŭŮůŰűŲų" },
  { "Y", "ÝŸýÿŶŷ" },
}

-- character -> the letter it folds to, flattened once at load. Every letter
-- above is a two-byte sequence (lead C3, C4 or C5), so the walk is in twos;
-- a slice that is not a lead byte followed by a continuation byte means the
-- source line is malformed, and is skipped rather than allowed to map a
-- fragment onto a letter.
local ACCENT_BASE = {}
for _, group in ipairs(ACCENT_GROUPS) do
  local letter, sources = group[1], group[2]
  local offset = 1
  while offset < #sources do
    local lead, trail = sources:byte(offset, offset + 1)
    if lead >= 0xC0 and lead < 0xE0 and trail and trail >= 0x80 and trail < 0xC0 then
      ACCENT_BASE[sources:sub(offset, offset + 1)] = letter
      offset = offset + 2
    else
      offset = offset + 1
    end
  end
end

local foldCache = {}
local foldCacheCount = 0

-- The memo is fed by every name in every list AND by every prefix the player
-- types on the way to a name ("s", "sh", "sha", ...). Names are bounded by
-- the roster; the prefixes are bounded only by the session. Well above any
-- real roster, and when it is reached the whole memo is dropped rather than
-- pruned -- a rebuild is one pass over names that are about to be folded
-- anyway, and a session that reaches this has typed a very great deal.
local FOLD_CACHE_MAX = 4096

-- Public: the compose screen sorts and filters on this, calling it with the
-- address strings out of the results arrays; the memo is what makes that one
-- table lookup per name rather than a rescan per comparison.
function CS.Fold(text)
  local input = (type(text) == "string") and text or tostring(text or "")
  local cached = foldCache[input]
  if cached then return cached end
  if foldCacheCount >= FOLD_CACHE_MAX then
    foldCache = {}
    foldCacheCount = 0
  end
  foldCacheCount = foldCacheCount + 1

  -- Case first, through the foundation's byte-exact tables (never
  -- string.upper -- see Lib/Util.lua for why), then the diacritics off the
  -- Latin letters. The second pass touches only the three lead bytes the
  -- table can answer for, so a Cyrillic or ASCII name pays for no
  -- substitution at all. A letter the table does not know is left exactly as
  -- it was, which is what a nil lookup means to gsub.
  local folded = Helpers().Upper(input)
  folded = folded:gsub("[\195-\197][\128-\191]", ACCENT_BASE)

  foldCache[input] = folded
  return folded
end

-------------------------------------------------------------
-- Class colours
--
-- Cache: recipient key (see IdentityKey) -> class token ("WARRIOR").
--
-- Keyed on (name, realm), not on the short name: two characters called Arsol on
-- two realms are two people, and a short-name cache hands the second one
-- whichever class happened to be cached first.
-------------------------------------------------------------

local classCache = {}

-- Reverse map: lowercase localized class name -> class token.
--
-- Built from BOTH gendered tables. frFR, deDE, ruRU and esES return the female
-- form for a female character, and a map built only from the male forms never
-- resolves those -- so every female character in those locales silently lost
-- her class colour. Where the two tables agree the second pass writes the same
-- token, so absorbing both is safe.
local localisedClassMap

local function GetLocalizedClassMap()
  if localisedClassMap then return localisedClassMap end

  -- Filled and only then published, so a table that threw half way through
  -- building cannot be handed out as though it were complete.
  local map = {}
  local function Absorb(names)
    if type(names) ~= "table" then return end
    for token, localName in pairs(names) do
      if type(token) == "string" and type(localName) == "string" and localName ~= "" then
        map[string.lower(localName)] = token
      end
    end
  end

  Absorb(LOCALIZED_CLASS_NAMES_MALE)
  Absorb(LOCALIZED_CLASS_NAMES_FEMALE)

  localisedClassMap = map
  return map
end

local function CacheClass(name, classToken)
  if type(name) ~= "string" or name == "" then return end
  if type(classToken) ~= "string" or classToken == "" then return end
  local key = IdentityKey(name)
  if key ~= "" then classCache[key] = classToken end
end

-- Resolves a source row's class to a token: the file-name field when the source
-- has one, otherwise the localized display name through the reverse map.
local function ClassTokenOf(classFile, className)
  if type(classFile) == "string" and classFile ~= "" then return classFile end
  if type(className) == "string" and className ~= "" then
    return GetLocalizedClassMap()[string.lower(className)]
  end
  return nil
end

-------------------------------------------------------------
-- Sources
--
-- Each collector appends raw names -- exactly as its API returned them -- to
-- `out`, and caches any class it learns on the way. Canonicalisation happens in
-- one place afterwards; a collector that "helpfully" tidied a name would be a
-- second identity rule.
--
-- A defensive ceiling per source keeps a pathological roster from turning the
-- snapshot into an unbounded table. It is far above any real guild.
-------------------------------------------------------------

local MAX_SOURCE_ENTRIES = 2000

-- Guild -----------------------------------------------------

-- Both the roster request and the friends request are throttled by the server;
-- asking more often than this achieves nothing and the interval is generous
-- enough that a mailbox open per minute never hits it.
local REQUEST_INTERVAL = 10
local guildRequestedAt, friendsRequestedAt = 0, 0

local function Now()
  if type(GetTime) ~= "function" then return 0 end
  local ok, value = pcall(GetTime)
  if ok and type(value) == "number" then return value end
  return 0
end

local function RequestGuildRoster()
  if type(IsInGuild) ~= "function" or not IsInGuild() then return end
  local now = Now()
  if now > 0 and (now - guildRequestedAt) < REQUEST_INTERVAL then return end
  guildRequestedAt = now

  -- The unnamespaced GuildRoster() is deprecated; C_GuildInfo.GuildRoster is
  -- the current call. The old global stays as a fallback for older clients only.
  if type(C_GuildInfo) == "table" and type(C_GuildInfo.GuildRoster) == "function" then
    C_GuildInfo.GuildRoster()
  elseif type(GuildRoster) == "function" then
    GuildRoster()
  end
end

-- GetGuildRosterInfo's name is ALWAYS "Name-Realm", including for same-realm
-- members, and cross-realm guilds have been live since 11.0 -- so the suffix can
-- name a genuinely off-realm character. It is passed through whole: stripping it
-- produces a bare name that duplicates a same-realm entry in the picker and,
-- worse, addresses a different character or none at all.
-- How many rows the last guild walk actually saw, BEFORE the current character
-- is filtered out of them. It answers one question and only one: has the roster
-- request come back yet? An empty guild source is ambiguous on its own -- a
-- roster still in flight and a guild whose only member is you both produce
-- zero entries -- and "is this favourite gone for good" is decided on that
-- distinction. See CS.SourcesReady.
local guildRosterSeen = 0

local function CollectGuild(out)
  guildRosterSeen = 0
  if type(GetNumGuildMembers) ~= "function" or type(GetGuildRosterInfo) ~= "function" then return end
  -- Extra parentheses truncate to one value. GetNumGuildMembers returns total,
  -- online and online-plus-mobile; without them the online count lands in
  -- tonumber's *base* argument, which must be 2-36, and throws for most guilds.
  local total = tonumber((GetNumGuildMembers())) or 0
  if total > MAX_SOURCE_ENTRIES then total = MAX_SOURCE_ENTRIES end
  for i = 1, total do
    local fullName, _, _, _, _, _, _, _, _, _, classFileName = GetGuildRosterInfo(i)
    if type(fullName) == "string" and fullName ~= "" then
      guildRosterSeen = guildRosterSeen + 1
      out[#out + 1] = fullName
      CacheClass(fullName, classFileName)
    end
  end
end

-- Friends ---------------------------------------------------

local function RequestFriendList()
  if type(C_FriendList) ~= "table" or type(C_FriendList.ShowFriends) ~= "function" then return end
  local now = Now()
  if now > 0 and (now - friendsRequestedAt) < REQUEST_INTERVAL then return end
  friendsRequestedAt = now
  C_FriendList.ShowFriends()
end

-- info.name carries "-Realm" for a cross-realm friend and is bare otherwise,
-- which is exactly the distinction we need; it is passed through untouched.
--
-- There is deliberately no fallback to info.notes. A note is free text ("main is
-- Bob", "AH guy") and offering it as a mail recipient is offering garbage.
-- The character-friend half of the friends source, counted for the same reason
-- guildRosterSeen is (see above). Battle.net is deliberately NOT counted here:
-- a player can have Battle.net friends and no mailable WoW character among
-- them, so an empty Battle.net walk is a legitimate answer rather than a
-- pending one.
local friendListSeen = 0

local function CollectFriends(out)
  friendListSeen = 0
  if type(C_FriendList) ~= "table" then return end
  if type(C_FriendList.GetNumFriends) ~= "function" then return end
  if type(C_FriendList.GetFriendInfoByIndex) ~= "function" then return end

  local total = tonumber((C_FriendList.GetNumFriends())) or 0
  if total > MAX_SOURCE_ENTRIES then total = MAX_SOURCE_ENTRIES end
  for i = 1, total do
    local info = C_FriendList.GetFriendInfoByIndex(i)
    local name = type(info) == "table" and info.name or nil
    if type(name) == "string" and name ~= "" then
      friendListSeen = friendListSeen + 1
      out[#out + 1] = name
      CacheClass(name, ClassTokenOf(info.classFile, info.className))
    end
  end
end

-- Battle.net ------------------------------------------------

-- BNGetFriendInfo was REMOVED in 8.2.5 and exists nowhere in retail's shipped
-- Lua, so gating the collector on it -- as this once did -- meant Battle.net
-- friends were never collected on any modern client, even though the C_BattleNet
-- call nested inside the guard would have worked perfectly. The gate is the
-- modern pair and nothing else.
--
-- What is filtered out, and what deliberately is not:
--
--   FILTERED  a game account that is not WoW, or not this WoW, or not in this
--             region. None of those can receive a letter under any conditions.
--   NOT       realm and faction. Mail crosses both for the player's own
--             characters, cross-faction mail to a Battle.net friend on a
--             connected realm is widely reported to work, and the connected
--             group cannot be determined without an API this addon has already
--             decided not to build addresses on. Offering a name that might
--             bounce is a smaller error than hiding one that would have worked;
--             the address carries its realm suffix either way, so the game gives
--             the player its own reason if it refuses.
local function IsMailableGameAccount(game)
  if type(game) ~= "table" then return false end

  if type(game.clientProgram) == "string" and type(BNET_CLIENT_WOW) == "string"
     and game.clientProgram ~= BNET_CLIENT_WOW then
    return false
  end
  if game.wowProjectID ~= nil and type(WOW_PROJECT_ID) == "number"
     and game.wowProjectID ~= WOW_PROJECT_ID then
    return false
  end
  if game.isInCurrentRegion == false then return false end
  return true
end

local function CollectBattleNet(out)
  if type(BNGetNumFriends) ~= "function" then return end
  if type(C_BattleNet) ~= "table" or type(C_BattleNet.GetFriendAccountInfo) ~= "function" then return end

  local numGameAccounts = C_BattleNet.GetFriendNumGameAccounts
  local gameAccountInfo = C_BattleNet.GetFriendGameAccountInfo

  local function push(game)
    if not IsMailableGameAccount(game) then return end
    -- gameAccountInfo.characterName is ALWAYS bare -- the realm lives in its own
    -- field, and realmName is the DISPLAY realm ("Wyrmrest Accord"), so joining
    -- it raw produces "Name-Wyrmrest Accord": a space, and not a valid mail
    -- address. It goes through the shared realm normaliser like every other
    -- realm in the addon.
    local name = JoinRealm(game.characterName, game.realmName)
    if type(name) ~= "string" or name == "" then return end
    out[#out + 1] = name
    CacheClass(name, ClassTokenOf(game.classFile, game.className))
  end

  local total = tonumber((BNGetNumFriends())) or 0
  for i = 1, total do
    local enumerated = false
    -- The primary gameAccountInfo is only ONE of a friend's characters. A friend
    -- logged in on a character you cannot mail, who also has one you can, would
    -- be missed entirely by reading the primary alone.
    if type(numGameAccounts) == "function" and type(gameAccountInfo) == "function" then
      local count = tonumber((numGameAccounts(i))) or 0
      for j = 1, count do
        push(gameAccountInfo(i, j))
        enumerated = true
      end
    end
    if not enumerated then
      local accountInfo = C_BattleNet.GetFriendAccountInfo(i)
      if type(accountInfo) == "table" then push(accountInfo.gameAccountInfo) end
    end
  end
end

-- Recent allies ---------------------------------------------

-- One RecentAllyData row -> a mailable name, or nil.
--
-- The character fields are NESTED under entry.characterData ({ name, fullName,
-- realmName }, per Blizzard's own generated documentation). Reading them from
-- the top level -- as this collector once did -- matched nothing whatsoever, so
-- the recent-allies bucket was silently empty rather than merely incomplete.
--
-- fullName is the pre-joined "Name-Realm" and is what we want. name plus
-- realmName is the fallback for a row that omits it, and the top-level reads are
-- kept last because C_RecentAllies is young enough that its shape is worth
-- tolerating rather than asserting.
local function RecentAllyName(entry)
  if type(entry) ~= "table" then return nil end
  local data = type(entry.characterData) == "table" and entry.characterData or entry

  local full = data.fullName or data.fullCharacterName
    or entry.fullCharacterName or entry.fullName
  if type(full) == "string" and full ~= "" then return full end

  local short = data.name or data.characterName or entry.characterName or entry.name
  if type(short) ~= "string" or short == "" then return nil end
  return JoinRealm(short, data.realmName or entry.realmName)
end

local function CollectRecentAllies(out)
  local Query = type(C_RecentAllies) == "table" and C_RecentAllies.GetRecentAllies
  if type(Query) ~= "function" then return end

  -- C_RecentAllies is flagged RequiresRecentAllies, so it can fail as a
  -- precondition rather than returning an empty list; the pcall is load-bearing
  -- and is not standing in for argument validation.
  local ok, allies = pcall(Query)
  if not ok or type(allies) ~= "table" then return end

  for i = 1, #allies do
    local name = RecentAllyName(allies[i])
    if type(name) == "string" and name ~= "" then out[#out + 1] = name end
  end
end

-- Blizzard autocomplete -------------------------------------
--
-- C_AutoComplete.GetAutoCompleteResults is the current API. The unnamespaced
-- GetAutoCompleteResults was deprecated in 12.0.5 and now survives only inside
-- Blizzard_DeprecatedAutoComplete, which begins
--
--     if not GetCVarBool("loadDeprecationFallbacks") then return; end
--
-- and defines the AUTOCOMPLETE_FLAG_* / AUTO_COMPLETE_* globals after that line.
-- A player who turns that CVar off therefore has nil for all of them, and these
-- collectors -- the account-alt one in particular -- silently produced nothing at
-- all. The namespaced call is tried first and the global is only a fallback for
-- clients that predate it; the two take identical arguments, because the
-- deprecated one is a direct wrapper over the other.
--
-- Returns array of { name, priority, bnetID } tables. entry.name is the client's
-- own mail-addressing form and already carries a realm suffix wherever one is
-- needed, so it is passed through verbatim; Address normalises the realm half
-- afterwards, which covers the documented cases where the client hands back a
-- realm that still has a space in it.
--
-- The flag values are bit positions in a mask the server understands, not
-- indices, so hardcoding them is safe -- but Enum.AutoCompleteEntryFlag is the
-- source of truth when it exists, and the literal is only the fallback for a
-- client old enough to lack the enum.

local function EntryFlag(field, fallback)
  local enum = type(Enum) == "table" and Enum.AutoCompleteEntryFlag or nil
  local value = type(enum) == "table" and enum[field] or nil
  if type(value) == "number" then return value end
  return fallback
end

-- Masks, not enum members: Blizzard defines neither of these on the enum.
local AUTOCOMPLETE_FLAG_ALL = 0xFFFFFFFF
local AUTOCOMPLETE_FLAG_NONE = 0x00000000
local AUTOCOMPLETE_FLAG_ACCOUNT_CHARACTER = EntryFlag("AccountCharacter", 0x00000080)
local AUTOCOMPLETE_FLAG_INTERACTED_WITH = EntryFlag("InteractedWith", 0x00000010)

-- Returns the raw result array, or nil when neither API is present. A missing
-- legacy global is a quiet "no suggestions", never an error.
local function AutoCompleteResults(query, numResults, cursorPosition, includeFlags)
  if type(query) ~= "string" then return nil end
  if type(numResults) ~= "number" or type(cursorPosition) ~= "number" then return nil end

  local fn = type(C_AutoComplete) == "table" and C_AutoComplete.GetAutoCompleteResults or nil
  if type(fn) ~= "function" then fn = GetAutoCompleteResults end
  if type(fn) ~= "function" then return nil end

  -- pcall as a deliberate compatibility shim, not as argument validation: the
  -- arguments are checked above, but this call has changed namespace once
  -- already and a future signature change must not take the To: box with it.
  local ok, results = pcall(fn, query, numResults, cursorPosition, true, includeFlags, AUTOCOMPLETE_FLAG_NONE)
  if not ok or type(results) ~= "table" then return nil end
  return results
end

-- A result row is documented as a table carrying `name`, but the deprecated
-- global wrapper has been seen handing back bare strings, so both shapes are
-- read and anything else is skipped rather than trusted.
local function AutoCompleteName(entry)
  if type(entry) == "table" then return entry.name end
  if type(entry) == "string" then return entry end
  return nil
end

local function PushAutoCompleteNames(out, results)
  if type(results) ~= "table" then return end
  for i = 1, #results do
    local name = AutoCompleteName(results[i])
    if type(name) == "string" and name ~= "" then out[#out + 1] = name end
  end
end

-- The player's own characters across every realm the account has them on. This
-- is the only source for a cross-realm warband alt, so the realm suffix is more
-- load-bearing here than anywhere else -- a stripped suffix turns every off-realm
-- alt into a bare name that addresses the player's own realm instead.
--
-- Enumerating the whole cache means asking with no search text, which is not a
-- documented idiom in either direction. "" is tried first and a single space is
-- the fallback, so a client that treats one of them as "match nothing" still
-- yields the list rather than silently emptying the Alts section.
local function CollectAccountAlts(out)
  local results = AutoCompleteResults("", 200, 0, AUTOCOMPLETE_FLAG_ACCOUNT_CHARACTER)
  if not results or #results == 0 then
    results = AutoCompleteResults(" ", 200, 1, AUTOCOMPLETE_FLAG_ACCOUNT_CHARACTER)
  end
  PushAutoCompleteNames(out, results)
end

-- Names the client itself would complete for what the player has typed. Used
-- only for a non-empty query -- which is the documented use of this API -- and
-- only as the last resort for names no specific source claimed.
local function CollectQueryAutoComplete(text, out)
  if type(text) ~= "string" or text == "" then return end
  PushAutoCompleteNames(out, AutoCompleteResults(text, 50, #text, AUTOCOMPLETE_FLAG_INTERACTED_WITH))
  PushAutoCompleteNames(out, AutoCompleteResults(text, 20, #text, AUTOCOMPLETE_FLAG_ALL))
end

-- Saved alts ------------------------------------------------

-- Characters the player has logged into with Postbox installed. PostboxDB.alts
-- is keyed by the RAW GetRealmName(), spaces and all, and holds bare names, so
-- the two halves are rejoined through the shared normaliser rather than emitting
-- a bare name and leaving the reader to assume a realm.
local function CollectSavedAlts(out)
  if type(PostboxDB) ~= "table" or type(PostboxDB.alts) ~= "table" then return end
  local realm = type(GetRealmName) == "function" and GetRealmName() or nil
  if type(realm) ~= "string" or realm == "" then return end

  local alts = PostboxDB.alts[realm]
  if type(alts) ~= "table" then return end

  local altClasses = type(PostboxDB.altClasses) == "table" and PostboxDB.altClasses[realm] or nil
  for _, name in ipairs(alts) do
    if type(name) == "string" and name ~= "" then
      local full = JoinRealm(name, realm) or name
      out[#out + 1] = full
      -- altClasses is indexed by the stored (bare) name; the cache is keyed by
      -- identity, so the two are looked up separately.
      if altClasses then CacheClass(full, altClasses[name]) end
    end
  end
end

-------------------------------------------------------------
-- The sources
--
-- FIVE INDEPENDENT MEMBERSHIPS, not five slices of one list.
--
-- This used to be one snapshot with cross-bucket first-wins dedup, scanned
-- recent -> friends -> guild -> recent-allies -> alts. The consequence was that
-- the browsable categories did not mean what their labels said: a guildmate you
-- had mailed was claimed by `recent` and never appeared under Guild, so the
-- Guild tile listed "the guildmates I have never written to" -- which is
-- precisely the wrong half of your guild.
--
-- A name now belongs to EVERY source that produced it. Someone who is in your
-- guild, on your friends list and in your mail history is in all three lists,
-- and each list is complete on its own terms. Browsing selects by membership;
-- the flat type-ahead does its own dedup across the lists it concatenates, which
-- is where a single answer per person is actually wanted.
--
-- Each source is collected, canonicalised and (where it has no order of its
-- own) sorted independently, so one source can be rebuilt without touching the
-- others -- see the invalidation policy below.
-------------------------------------------------------------

local function SortEntries(list)
  table.sort(list, function(a, b)
    -- Case-insensitive, so "arthas" and "Arthas" do not sort into two groups.
    -- Byte order within a case-folded tie keeps the sort total and stable.
    if a.lower == b.lower then return a.address < b.address end
    return a.lower < b.lower
  end)
end

local function CollectRecent(out)
  local db = ns.EnsureDB()
  local history = type(db) == "table" and db.recipientHistory or nil
  if type(history) ~= "table" then return end
  for i = 1, #history do out[#out + 1] = history[i] end
end

local function CollectAlts(out)
  CollectSavedAlts(out)
  CollectAccountAlts(out)
end

-- Battle.net friends are FRIENDS. They used to be filed with the recent allies,
-- under a heading with a faction word in it, two buttons away from a Friends
-- tile that did not contain them.
local function CollectAllFriends(out)
  CollectFriends(out)
  CollectBattleNet(out)
end

-- `ordered` marks a source that arrives in a meaningful order of its own and
-- must NOT be alphabetised. Mail history is the only one: it is most-recent
-- first, that order is the entire reason the Recent category exists, and
-- sorting it was what put the person you wrote to ten minutes ago thirtieth.
local SOURCES = {
  { id = "recent",  collect = CollectRecent,      ordered = true },
  { id = "alts",    collect = CollectAlts },
  { id = "friends", collect = CollectAllFriends },
  { id = "guild",   collect = CollectGuild },
  -- C_RecentAllies: people the player recently grouped with. A source in its
  -- own right, named for what it is rather than for a faction.
  { id = "grouped", collect = CollectRecentAllies },
}

local sources = {}
for i = 1, #SOURCES do
  sources[SOURCES[i].id] = {
    list = {}, seen = {}, built = false, dirty = true, force = true, at = 0,
  }
end

-- Every key any source holds. One flat set, so "does any live source know this
-- name" stays a single lookup for the callers that ask it per entry.
local unionKeys = {}
local unionDirty = true

-- The player's own identity key. Mail to self is rejected by the server, so the
-- current character is dropped from every source. This is an identity question,
-- not a string one: UnitName is bare and most sources are not, so they only
-- agree once both are keys -- and a same-named character on ANOTHER realm is a
-- perfectly valid recipient that a bare-string comparison would wrongly exclude.
local me = nil

-- An apostrophe realm is the one place a recipient's saved curation state can
-- still be filed under a superseded key -- Postbox used to strip apostrophes out
-- of the realm half, so "Zug-Kel'Thuzad" was stored as "zug-kelthuzad".
-- Recipients re-files such a row the moment anything looks it up by name, and
-- R.Get is that lookup. Done once per rebuild rather than once per collected
-- name per keystroke.
local probeLegacy = false

-- Reduces one collected name to the only two forms anything downstream may see:
-- its identity key, and its address.
local function Resolve(name, h)
  if type(name) ~= "string" then return nil end
  local clean = h.NormalizeText(name)
  if clean == "" then return nil end
  local key = IdentityKey(clean)
  if key == "" or key == me then return nil end
  if probeLegacy then
    local R = ns.Recipients
    if key:find("'", 1, true) and type(R) == "table" then R.Get(key) end
  end
  return key, Address(clean)
end

-------------------------------------------------------------
-- Invalidation policy
--
-- "Dirty" and "rebuilt" are two different things, and conflating them is what
-- made the per-keystroke cache almost always cold.
--
-- BN_FRIEND_INFO_CHANGED fires whenever any Battle.net friend changes zone,
-- status or character, and GUILD_ROSTER_UPDATE ticks constantly in a populated
-- guild. Both used to discard the WHOLE snapshot, so in a city or a raid the
-- next query paid a full guild-roster walk, a friends walk, a Battle.net walk
-- and five sorts -- potentially once per debounced keystroke.
--
-- Now an event dirties only the source it can possibly have changed, the
-- rebuild happens lazily on the next query, and every other source keeps its
-- built, sorted array. A presence tick therefore costs a guild player nothing
-- at all.
--
-- Dirty is also COALESCED: a source that has already been built waits this long
-- before it is re-collected, so a burst of roster updates is one rebuild rather
-- than one per event. A source that has never been built, and any source
-- dirtied by a MEMBERSHIP event (joining a guild, zoning in, sending a mail),
-- rebuilds on the next query with no delay -- so a genuinely new guildmate or
-- friend is never more than this far behind, and usually not behind at all.
-------------------------------------------------------------

local SOURCE_COALESCE = 3

local function MarkDirty(id, force)
  local state = sources[id]
  if not state then return end
  state.dirty = true
  if force then state.force = true end
end

local function MarkAllDirty()
  for i = 1, #SOURCES do
    local state = sources[SOURCES[i].id]
    state.dirty, state.force = true, true
  end
  -- The character can be different on the other side of a loading screen.
  me = nil
end

-- The module's public reset: everything dirty, everything forced. Nothing in
-- the addon calls it in normal play -- the UI's "list still arriving" case
-- goes through CS.RefreshPending, which is targeted and throttled -- but it
-- is the documented big hammer and stays public.
CS.Invalidate = MarkAllDirty

-- One scratch array for every collector, reused across rebuilds.
local rawScratch = {}

local function RebuildSource(def, state, now, h)
  local raw = rawScratch
  for i = #raw, 1, -1 do raw[i] = nil end
  def.collect(raw)

  local seen = state.seen
  for key in pairs(seen) do seen[key] = nil end

  -- Entry tables are reused in place. A steady-state rebuild of a 900-member
  -- guild therefore allocates nothing but the two strings Resolve returns.
  --
  -- `lower` is the match key (substring scans, case-insensitive ordering);
  -- `fold` is the DISPLAY sort key (see Collation, above). Both are computed
  -- here, once per entry, because both used to be computed inside a loop that
  -- ran per comparison or per keystroke.
  local list, n = state.list, 0
  for i = 1, #raw do
    if n >= MAX_SOURCE_ENTRIES then break end
    local key, address = Resolve(raw[i], h)
    if key and not seen[key] then
      seen[key] = true
      n = n + 1
      local entry = list[n]
      if entry then
        entry.key, entry.address = key, address
        entry.lower = h.Lower(address)
      else
        list[n] = { key = key, address = address, lower = h.Lower(address) }
      end
    end
  end
  for i = #list, n + 1, -1 do list[i] = nil end

  if not def.ordered then SortEntries(list) end

  state.built, state.dirty, state.force, state.at = true, false, false, now
end

local function EnsureSources()
  local h = Helpers()

  if me == nil or me == "" then
    me = IdentityKey(type(UnitName) == "function" and UnitName("player") or nil)
  end

  local R = ns.Recipients
  probeLegacy = (type(R) == "table" and type(R.Get) == "function"
    and type(R.HasState) == "function" and R.HasState()) and true or false

  local now = Now()
  for i = 1, #SOURCES do
    local def = SOURCES[i]
    local state = sources[def.id]
    if state.dirty and (state.force or not state.built
                        or now <= 0 or (now - state.at) >= SOURCE_COALESCE) then
      RebuildSource(def, state, now, h)
      unionDirty = true
    end
  end

  if unionDirty then
    for key in pairs(unionKeys) do unionKeys[key] = nil end
    for i = 1, #SOURCES do
      local list = sources[SOURCES[i].id].list
      for j = 1, #list do unionKeys[list[j].key] = true end
    end
    unionDirty = false
  end
end

-------------------------------------------------------------
-- Readiness
--
-- Whether every source that COULD hold a given name has answered. The curation
-- window uses this to decide when "this favourite is in no current list" may be
-- said out loud, and the answer has to be per-source: it used to be "all five
-- lists are non-empty", which is false forever for anyone with no guild, no
-- friends, or no mail history -- i.e. for most players -- so the one sentence
-- that tells you a favourite no longer exists was effectively dead UI.
--
-- Only the two asynchronous sources can be empty because a request has not come
-- back yet. Alts, mail history and recent allies are read synchronously and an
-- empty one is a fact, not a wait.
--
-- The counts are the RAW rows the walk saw, before the current character is
-- filtered out: a guild whose only member is you produces zero entries and one
-- raw row, and that is a loaded roster, not a pending one.
--
-- Ask per source. The two waits are independent -- a 900-member roster in flight
-- says nothing whatever about the friends list -- so ANDing them meant a player
-- clicking Friends on an empty friends list was told to wait for a list that had
-- already arrived, and was told it until the roster landed. The no-argument form
-- is still the AND, because "may I say this favourite is in no current list"
-- genuinely does need every source to have answered.
-------------------------------------------------------------

local function GuildReady()
  if type(IsInGuild) == "function" and IsInGuild() and guildRosterSeen == 0 then
    return false
  end
  return true
end

local function FriendsReady()
  if type(C_FriendList) == "table" and type(C_FriendList.GetNumFriends) == "function" then
    local total = tonumber((C_FriendList.GetNumFriends())) or 0
    if total > 0 and friendListSeen == 0 then return false end
  end
  return true
end

function CS.SourcesReady(id)
  EnsureSources()

  if id == "guild" then return GuildReady() end
  if id == "friends" then return FriendsReady() end
  -- Every other source is read synchronously, so it has answered by definition.
  if id ~= nil then return true end

  return GuildReady() and FriendsReady()
end

-------------------------------------------------------------
-- Why a source is empty
--
-- Both recipient windows draw an empty list, and both used to draw the same
-- sentence for every category: "Nothing in this list yet." That is technically
-- true and useless in the two cases players actually meet -- not being in a
-- guild, and clicking Guild inside the roster round trip on a cold login.
--
-- The reason is decided HERE, and returned as a LOCALE KEY, because this module
-- is the only one that knows whether a request is still in flight. Putting the
-- decision in the UI would mean two windows guessing at it separately and
-- disagreeing. Returning a key rather than a sentence keeps every string in
-- Core/Locales.lua, which is the rule this file would otherwise be breaking.
--
-- nil means "no better answer than the generic line" -- an empty guild list on
-- a loaded roster (a guild whose only member is you) and the recently-grouped
-- list are both legitimately just empty.
-------------------------------------------------------------

function CS.EmptyReason(id)
  if id == "guild" then
    if type(IsInGuild) ~= "function" or not IsInGuild() then
      return "CONTACT_EMPTY_GUILD"
    end
    if not CS.SourcesReady("guild") then return "CONTACT_EMPTY_LOADING" end
    return nil
  end

  if id == "friends" then
    if not CS.SourcesReady("friends") then return "CONTACT_EMPTY_LOADING" end
    return "CONTACT_EMPTY_FRIENDS"
  end

  if id == "alts" then return "CONTACT_EMPTY_ALTS" end
  if id == "recent" then return "CONTACT_EMPTY_RECENT" end
  return nil
end

-------------------------------------------------------------
-- Requests
--
-- The requests live on events, never on a keystroke. A guild roster request is
-- a server round trip; issuing one per character typed is what made a large
-- guild feel like a stutter.
-------------------------------------------------------------

local function RequestSources()
  RequestGuildRoster()
  RequestFriendList()
end

-- The UI's hook for the "first answer still in flight" window: an open picker
-- wants to fill in when the roster lands, but forcing every source dirty on
-- each roster tick would be a full five-source rebuild per event -- the exact
-- per-keystroke cost the invalidation policy above exists to prevent. This
-- dirties ONLY the sources that have not answered yet, no more often than the
-- coalescing window, and re-issues the (already throttled) requests -- which is
-- what lets a session whose first request was lost ever leave this state.
local pendingRefreshedAt = 0
function CS.RefreshPending()
  EnsureSources()
  local now = Now()
  if now > 0 and (now - pendingRefreshedAt) < SOURCE_COALESCE then return end
  pendingRefreshedAt = now
  if not GuildReady() then MarkDirty("guild", true) end
  if not FriendsReady() then MarkDirty("friends", true) end
  RequestSources()
end

do
  local bus = ns.Events
  if type(bus) == "table" and type(bus.Register) == "function" then
    -- Presence, not membership: each of these dirties exactly one source and
    -- waits out the coalescing window. See the invalidation policy above.
    bus.Register("GUILD_ROSTER_UPDATE", function() MarkDirty("guild") end)
    bus.Register("FRIENDLIST_UPDATE", function() MarkDirty("friends") end)
    bus.Register("BN_FRIEND_INFO_CHANGED", function() MarkDirty("friends") end)
    bus.Register("BN_DISCONNECTED", function() MarkDirty("friends") end)
    -- The friends list has just become readable again; do not make the player
    -- wait out a coalescing window for it.
    bus.Register("BN_CONNECTED", function() MarkDirty("friends", true) end)

    -- Membership. Joining or leaving a guild must show at once.
    bus.Register("PLAYER_GUILD_UPDATE", function()
      MarkDirty("guild", true)
      RequestGuildRoster()
    end)

    -- Login and zone-in: ask early so the caches are warm long before the
    -- player opens a mailbox and starts typing.
    bus.Register("PLAYER_ENTERING_WORLD", function()
      MarkAllDirty()
      RequestSources()
    end)
    bus.Register("MAIL_SHOW", function()
      -- C_RecentAllies publishes no update event, so a mailbox open -- the one
      -- moment its contents are about to be read -- is where it is refreshed.
      MarkDirty("grouped", true)
      RequestSources()
    end)

    bus.Register("PLAYER_LEAVING_WORLD", function()
      MarkAllDirty()
      classCache = {}
      -- Correctness never needs this -- a fold is a pure function of its input
      -- -- but a character switch is the natural place to stop carrying every
      -- name the last one ever saw.
      foldCache = {}
      foldCacheCount = 0
    end)
  end
end

-------------------------------------------------------------
-- Public API
-------------------------------------------------------------

-- Class token -> the client's colour for it. Two tables answer this and they
-- do not agree about which builds have them, so ask the modern one first and
-- keep RAID_CLASS_COLORS as the answer for anything it does not know.
local function ClassColour(token)
  if C_ClassColor and type(C_ClassColor.GetClassColor) == "function" then
    local colour = C_ClassColor.GetClassColor(token)
    if colour then return colour end
  end
  if type(RAID_CLASS_COLORS) == "table" then return RAID_CLASS_COLORS[token] end
  return nil
end

-- Colour objects carry their own wrapper; the plain tables in
-- RAID_CLASS_COLORS carry three floats and nothing else, so the escape gets
-- built by hand for those. Either way an unknown class returns the text
-- untouched rather than a default colour -- a name drawn in the wrong class
-- colour is a lie, a name drawn plain is merely unhelpful.
local function WrapInClassColour(token, text)
  local colour = ClassColour(token)
  if not colour then return text end
  if type(colour.WrapTextInColorCode) == "function" then
    return colour:WrapTextInColorCode(text)
  end
  local r, g, b = (colour.r or 1) * 255, (colour.g or 1) * 255, (colour.b or 1) * 255
  return string.format("|cff%02x%02x%02x%s|r", r, g, b, text)
end

-- `name` identifies the character and must be the full name the caller has,
-- realm suffix and all -- the cache is keyed on (name, realm).
--
-- `text` is optional and is what actually gets wrapped. The two differ where a
-- caller wants only the name half coloured (with the realm drawn separately, in
-- grey) but must still identify the right character to colour it as. Passing
-- only the short half instead would resolve against the player's own realm and
-- mis-colour anyone off-realm.
function CS.GetClassColoredName(name, text)
  local out = (type(text) == "string" and text ~= "") and text or name
  if type(name) ~= "string" or name == "" then return out end

  -- Class tokens are learned while collecting the sources. A caller that draws
  -- names without ever having asked for suggestions -- the recipient manager --
  -- would otherwise get no colours at all. Only the first such call pays for it,
  -- and it deliberately does not force anything: a friend going offline must not
  -- cost a rebuild here.
  if next(classCache) == nil then EnsureSources() end

  local classToken = classCache[IdentityKey(name)]
  if not classToken then return out end
  return WrapInClassColour(classToken, out)
end

-- Records a recipient the player has SUCCESSFULLY mailed, most-recent-first.
--
-- History stores the ADDRESS, not the raw text typed, and dedupes on identity.
-- Typing "Arsol" one day and "Arsol-Kazzak" the next is one correspondent, and
-- letting both sit in the list is how the same character ends up in the Recent
-- bucket twice -- and how real entries get evicted to stay under the cap.
--
-- This is the only thing that appends to profile.recipientHistory;
-- ns.Recipients.Delete is the only thing that removes from it. The removal loop
-- here exists solely to de-duplicate this insert.
local HISTORY_MAX = 50

function CS.SaveRecipient(name)
  local text = Address(name)
  if text == "" then return end
  local key = IdentityKey(text)

  local db = ns.EnsureDB()
  local list = db.recipientHistory
  for i = #list, 1, -1 do
    if type(list[i]) == "string" and IdentityKey(list[i]) == key then
      table.remove(list, i)
    end
  end
  table.insert(list, 1, text)
  while #list > HISTORY_MAX do table.remove(list) end

  -- Forced, not coalesced: the player has just written to this person and the
  -- top of Recent is where they expect to find them a second later.
  MarkDirty("recent", true)
end

-- text  : filter, "" for everything.
-- opts  : { includeHidden = bool } -- defaults to FALSE, i.e. recipients the
--         player has hidden are left out. Hidden means hidden: not in the
--         browsable picker, not in the as-you-type suggestions, and not
--         inline-completed. ONE caller passes true -- the recipient manager,
--         because it is the window you go to in order to FIND what you hid and
--         bring it back, and a curation window that could not see what it was
--         curating would be a trap.
--
--         The compose screen's To: box is free text and always was, so a hidden
--         name typed out in full is still a perfectly good recipient. What
--         hiding buys is that the addon stops OFFERING it.
--
-- Returns eight array-valued keys. Each one means exactly what it says, and a
-- recipient appears in EVERY key that describes them:
--
--   favorites  the player's own curated list, from stored state
--   recent     people the player has mailed, MOST RECENT FIRST (see below)
--   alts       the player's own characters
--   friends    friends list and Battle.net friends
--   guild      guild roster
--   grouped    people recently grouped with (C_RecentAllies)
--   manual     added by hand in the recipient manager and since un-favourited;
--              no live source knows about them, so nothing else would list them
--   other      whatever the client's own autocomplete offered for a TYPED query
--              that no source above claimed. Always empty for an empty query.
--
-- RECENCY. `recent` is the one list that is not alphabetical, because recency is
-- the only reason that category exists. For an empty query it is exactly
-- profile.recipientHistory's order; for a typed one, prefix matches lead and
-- both groups keep their recency order within themselves. A caller that wants
-- the "last N people I wrote to" takes the first N entries and nothing else --
-- do not re-sort it.
--
-- Every array contains ADDRESSES (Recipients.Address): bare on the player's own
-- realm, "Name-Realm" everywhere else, never the raw string a collector happened
-- to return. Callers may therefore put an entry straight into the To: box, and
-- Recipients.Key on an entry always yields that recipient's key.
function CS.BuildSuggestions(text, opts)
  local h = Helpers()
  local clean = h.NormalizeText(text)
  local query = h.Lower(clean)
  local includeHidden = (type(opts) == "table" and opts.includeHidden) and true or false
  local R = ns.Recipients

  local results = {
    favorites = {}, recent = {}, alts = {}, friends = {}, guild = {},
    grouped = {}, manual = {}, other = {},
  }

  EnsureSources()

  -- The single hide gate. The state map is sparse and hiding anything at all is
  -- the exception, so the decision is made once per build: with nothing hidden
  -- the gate is one scan of that map instead of a state lookup per entry, and a
  -- guild roster is hundreds of entries on every keystroke.
  local anyHidden = false
  if not includeHidden and type(R) == "table"
     and type(R.ForEach) == "function" and type(R.IsHidden) == "function" then
    R.ForEach(function(_, row)
      if row.hidden then
        anyHidden = true
        return true
      end
    end)
  end

  local function IsHidden(key)
    if not anyHidden then return false end
    return R.IsHidden(key) == true
  end

  -- Matched against the address AND the key. The key always carries the realm
  -- half, so typing "arsol-kaz" still completes a same-realm character whose
  -- address is the bare "Arsol" -- which is what a player who copied the name out
  -- of Blizzard's own autocomplete will have typed.
  --
  -- Prefix matches lead, then substring matches. That is what a player typing a
  -- name expects and what Blizzard's own autocomplete does; a pure substring
  -- match buries the obvious answer behind whoever happens to sort first.
  local function Emit(dest, source)
    if query == "" then
      for i = 1, #source do
        local e = source[i]
        if not IsHidden(e.key) then dest[#dest + 1] = e.address end
      end
      return
    end

    local rest = nil
    for i = 1, #source do
      local e = source[i]
      if not IsHidden(e.key) then
        local addressAt = e.lower:find(query, 1, true)
        local keyAt = e.key:find(query, 1, true)
        if addressAt == 1 or keyAt == 1 then
          dest[#dest + 1] = e.address
        elseif addressAt or keyAt then
          rest = rest or {}
          rest[#rest + 1] = e.address
        end
      end
    end
    if rest then
      for i = 1, #rest do dest[#dest + 1] = rest[i] end
    end
  end

  Emit(results.recent, sources.recent.list)
  Emit(results.alts, sources.alts.list)
  Emit(results.friends, sources.friends.list)
  Emit(results.guild, sources.guild.list)
  Emit(results.grouped, sources.grouped.list)

  -- Whatever the client itself would complete, for names no cached source
  -- claimed. Only for a typed query: that is this API's documented use, and it
  -- keeps the browsable picker off an undocumented "enumerate everything" idiom
  -- that would silently blank the whole window if a future client stopped
  -- honouring it.
  --
  -- These land in `other` and nowhere else. They used to be appended to the
  -- recent-allies bucket, which meant a list labelled for people you had
  -- grouped with was partly made of names the client happened to remember.
  if query ~= "" then
    local extraRaw = {}
    CollectQueryAutoComplete(clean, extraRaw)
    local extraSeen = {}
    for i = 1, #extraRaw do
      local name = h.NormalizeText(extraRaw[i])
      if name ~= "" then
        local key = IdentityKey(name)
        if key ~= "" and key ~= me and not unionKeys[key]
           and not extraSeen[key] and not IsHidden(key) then
          extraSeen[key] = true
          results.other[#results.other + 1] = Address(name)
        end
      end
    end
  end

  -- Curation state, read live rather than baked into the snapshot: hiding or
  -- favouriting somebody must take effect on the next redraw, not on the next
  -- roster update.
  --
  -- Favourites come from the stored state and NOT from a rescan of the live
  -- sources: a favourite who leaves the guild, or an alt whose roster has not
  -- loaded yet, must not drop out of the one list the player curated by hand.
  -- They are additive, like alts -- a favourite still appears under its natural
  -- category as well.
  if type(R) == "table" and type(R.ForEach) == "function" and type(R.Display) == "function" then
    local favSeen = {}

    R.ForEach(function(key, row)
      if not (row.fav or row.manual) then return end
      local address = R.Display(key)
      if address == "" then return end
      local lower = h.Lower(address)
      if query ~= "" and not lower:find(query, 1, true) and not key:find(query, 1, true) then
        return
      end
      if row.fav then
        if not favSeen[key] then
          favSeen[key] = true
          results.favorites[#results.favorites + 1] = address
        end
      elseif not unionKeys[key] and not IsHidden(key) then
        -- A manually added recipient the player later un-favourited. No live
        -- source knows about it, so without this it would vanish from the addon
        -- entirely while still holding saved state. It gets its own list rather
        -- than being appended to Recent, which would put somebody the player has
        -- never written to at the bottom of "people you have written to".
        results.manual[#results.manual + 1] = address
      end
    end)

    table.sort(results.favorites, function(a, b)
      local la, lb = h.Lower(a), h.Lower(b)
      if la == lb then return a < b end
      return la < lb
    end)

    table.sort(results.manual, function(a, b)
      local la, lb = h.Lower(a), h.Lower(b)
      if la == lb then return a < b end
      return la < lb
    end)
  end

  return results
end
