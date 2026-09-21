local _, ns = ...

ns.Recipients = ns.Recipients or {}
local R = ns.Recipients
local H = nil

local function Helpers()
  if not H then H = ns.Helpers end
  return H
end

-------------------------------------------------------------
-- Recipient state (data layer)
--
-- Postbox builds its recipient suggestions from live game sources (guild,
-- friends, Battle.net, recent allies, Blizzard autocomplete) plus two saved
-- sources (PostboxDB.alts and profile.recipientHistory). This module owns the
-- *curation* layer on top of that: which recipients are hidden, which are
-- favourites, per-recipient notes, manually added names, and the extra alt
-- metadata (level / faction / last seen) the manager window shows.
--
-- Saved variables written here (PostboxDB is account-wide, so all of this is
-- shared between characters by design):
--
--   PostboxDB.recipients          -- sparse map, key -> state row
--   PostboxDB.altMeta             -- realm -> character -> { level, lastSeen, faction }
--
-- The state map is deliberately SPARSE: a row exists only while it carries
-- non-default state. That is what makes "a recipient nobody has touched is
-- visible" a structural property instead of something that has to be seeded
-- for every name the game hands us. Every setter therefore prunes its row back
-- out of the map as soon as the row returns to all-default, otherwise the table
-- grows dense over time and the opt-out default quietly stops being free.
--
-- Migration is additive-only and carries no version field: older saved
-- variables simply lack these tables, so every reader must tolerate nil.
--
-- The one exception to "reads never write" is the legacy-key migration (see
-- "Legacy key migration"): a read that finds a recipient filed under a
-- superseded key re-files it. That only ever rewrites a table that already
-- exists, so it still cannot materialise saved variables out of nothing.
-------------------------------------------------------------

-- Notes are a one-line label in a list row, not a journal.
local NOTE_MAX_CHARS = 40
-- Character names are 2-12 characters on live realms; allow headroom for
-- locales whose names transliterate longer rather than rejecting a valid name.
local NAME_MIN_CHARS = 2
local NAME_MAX_CHARS = 24
local REALM_MAX_CHARS = 48

-------------------------------------------------------------
-- Small utilities
-------------------------------------------------------------

-- time() is provided by WoW, but guard it the way the rest of the addon guards
-- Blizzard globals so a missing/replaced global degrades to "no timestamp"
-- instead of erroring inside a setter.
local function Now()
  if type(time) ~= "function" then return 0 end
  local ok, value = pcall(time)
  if ok and type(value) == "number" then return value end
  return 0
end

-- Truncates on a UTF-8 character boundary; cutting mid-sequence would leave a
-- broken byte the client renders as garbage. Names and notes arrive as UTF-8
-- from the client, so a byte count would under-cut non-latin realms badly.
local function TruncateChars(text, maxChars)
  local at = Helpers().CharBoundary(text, maxChars)
  if at and at <= #text then return text:sub(1, at - 1) end
  return text
end

-- The presentable form of a name rebuilt from a lowercase key. Delegated to
-- the foundation because the obvious one-liner -- sub(1, 1):upper() -- is a
-- byte operation, and on a Cyrillic or accented name the first byte is the
-- lead of a two-byte letter. Uppercasing THAT produced a name whose first
-- letter drew as a box and vanished when the string was put into the To:
-- box, which is the "bad cyrillic support" bug as reported.
local function Capitalize(text)
  return Helpers().Capitalize(text)
end

-- Realm names are normalised the way GetNormalizedRealmName() does it: spaces,
-- hyphens and periods removed, and NOTHING else touched -- apostrophes,
-- parentheses and accented characters are all kept.
--
-- Keeping the apostrophe is the load-bearing part. Blizzard's support article
-- for cross-realm mail gives "Character-Blade'sEdge" as a correct address, and
-- GetNormalizedRealmName() turns "Twilight's Hammer" into "Twilight'sHammer",
-- not "TwilightsHammer". An apostrophe-stripped realm is not a shorter address,
-- it is a wrong one, and dozens of live realms carry an apostrophe (Blade's
-- Edge, Twilight's Hammer, Ahn'Qiraj, Kel'Thuzad, Mal'Ganis, Ner'zhul, ...).
--
-- ONE function serves both the identity key and the address, deliberately. If
-- the two normalised differently, curation state would be filed under a key
-- that the name actually written into the To: box no longer resolves to.
local function NormalizeRealm(realm)
  return (tostring(realm or ""):gsub("[%s%-%.]", ""))
end

-- Published so that collectors which have to join a bare name to a raw realm
-- field -- ContactService's Battle.net path, where gameAccountInfo.realmName is
-- the DISPLAY realm and still contains its spaces -- reach for this
-- normalisation instead of inventing a second one that can drift from it.
R.NormalizeRealm = NormalizeRealm

-- How the realm half was normalised BEFORE the apostrophe fix. Kept for exactly
-- one purpose: locating saved rows written by that earlier version so they can
-- be moved onto their correct key. See "Legacy key migration" below.
local function LegacyNormalizeRealm(realm)
  return (tostring(realm or ""):gsub("[%s'%-]", ""))
end

-------------------------------------------------------------
-- Saved-variable accessors
--
-- Reads use raw PostboxDB lookups so that merely asking a question never
-- materialises saved variables; only the writers go through ns.Store.
-------------------------------------------------------------

local function DB()
  return type(PostboxDB) == "table" and PostboxDB or nil
end

local function CanWrite()
  return ns.Store ~= nil and type(ns.Store.EnsurePath) == "function"
end

-- Read-only view of the state map; nil when nothing has ever been stored.
local function StateMap()
  local db = DB()
  local map = db and db.recipients
  return type(map) == "table" and map or nil
end

-- Read/write view of the state map, created on demand.
local function StateMapRW()
  if not CanWrite() then return nil end
  return ns.Store.EnsurePath("recipients", {})
end

-- profile.recipientHistory is owned by ContactService.SaveRecipient; this
-- module only ever removes entries from it (via R.Delete).
local function HistoryList()
  local db = DB()
  local profile = db and db.profile
  local list = profile and profile.recipientHistory
  return type(list) == "table" and list or nil
end

-------------------------------------------------------------
-- Identity / keying
-------------------------------------------------------------

-- The player's realm, normalised, or "" when it is not known yet.
--
-- GetNormalizedRealmName() returns nil for a short window early in login, so
-- fall back to GetRealmName() and finally to "" rather than erroring. A key
-- computed inside that window has no realm half and will NOT match the same
-- character's key computed afterwards -- which is why R.Key must never be
-- called at file scope, only from event handlers and user actions.
--
-- Memoised once it answers, because a character's realm cannot change while
-- this Lua state lives (both logout and /reload rebuild it) and R.Key is now on
-- the per-name path of every suggestion rebuild -- a guild roster is hundreds
-- of names on every keystroke, and two pcalls each for a constant is not a
-- price worth paying. An EMPTY answer is deliberately not cached, so the
-- pre-login window still resolves the moment the client knows the realm.
--
-- Both spellings are memoised together from the one query: the current one, and
-- the pre-fix one the migration below has to look under.
local cachedRealm = nil
local cachedLegacyRealm = nil

local function RefreshRealmCache()
  local realm
  if type(GetNormalizedRealmName) == "function" then
    local ok, value = pcall(GetNormalizedRealmName)
    if ok and type(value) == "string" then realm = value end
  end
  if (realm == nil or realm == "") and type(GetRealmName) == "function" then
    local ok, value = pcall(GetRealmName)
    if ok and type(value) == "string" then realm = value end
  end
  cachedRealm = NormalizeRealm(realm)
  cachedLegacyRealm = LegacyNormalizeRealm(realm)
end

local function CurrentRealm()
  if not cachedRealm or cachedRealm == "" then RefreshRealmCache() end
  return cachedRealm
end

local function LegacyCurrentRealm()
  if not cachedLegacyRealm or cachedLegacyRealm == "" then RefreshRealmCache() end
  return cachedLegacyRealm
end

-- The shared shape of R.Key and LegacyKey. `normalize` is the realm normaliser
-- and `ownRealm` supplies the realm for a bare name; passing the latter as a
-- function keeps the pre-login pcalls off the path of names that already carry
-- a realm suffix.
local function BuildKey(name, normalize, ownRealm)
  local text = Helpers().NormalizeText(name)
  if text == "" then return "", "", "" end

  local short, realm = text:match("^([^%-]+)%-(.+)$")
  if not short then
    -- No realm half: strip any stray hyphen (real character names have none)
    -- and assume the player's own realm.
    short = (text:gsub("%-", ""))
    realm = ownRealm()
  end

  short = Helpers().NormalizeText(short)
  realm = normalize(realm)
  if short == "" then return "", "", "" end

  local lower = Helpers().Lower
  -- Realm unknown (pre-login): key on the bare lowercase name so callers never
  -- error. See the CurrentRealm comment for why this window matters.
  if realm == "" then return lower(short), short, "" end
  return lower(short) .. "-" .. lower(realm), short, realm
end

-- name -> key, short, realm
--
--   R.Key("Bob")            on Ravencrest -> "bob-ravencrest", "Bob", "Ravencrest"
--   R.Key("Bob-Ravencrest") anywhere      -> "bob-ravencrest", "Bob", "Ravencrest"
--   R.Key("Bob-Draenor")    anywhere      -> "bob-draenor",    "Bob", "Draenor"
--   R.Key("Bob-Twilight's Hammer")        -> "bob-twilight'shammer", "Bob",
--                                            "Twilight'sHammer"
--
-- A bare To: name means "on my realm" in WoW, so the first two forms collapse
-- to one key. Connected realms stay distinct because the realm half is kept.
-- Pure: no saved-variable access, and idempotent on its own output
-- (R.Key(R.Key(x)) == R.Key(x)) so every accessor below can accept either a
-- key or a raw name.
function R.Key(name)
  return BuildKey(name, NormalizeRealm, CurrentRealm)
end

-------------------------------------------------------------
-- Legacy key migration
--
-- Before the apostrophe fix the realm half was normalised with [%s'%-], so a
-- character on Twilight's Hammer was filed under "bob-twilightshammer" and is
-- now keyed "bob-twilight'shammer". PostboxDB.recipients is account-wide and
-- long-lived, so those rows must be carried across rather than orphaned --
-- silently losing somebody's hidden/favourite/note state is a worse bug than
-- the one being fixed.
--
-- Two mechanisms, because neither covers the other's ground:
--
--   RowFor            lazy, per-recipient, and general. Any lookup that misses
--                     under the new key retries under the old one and, on a
--                     hit, moves the row. This catches every realm, because the
--                     name being looked up still spells its own apostrophe.
--   SweepOwnRealmKeys one-shot, and only for the player's own realm. Needed
--                     because the enumerators (R.ForEach / R.Favorites) walk
--                     raw keys and never look anything up by name, so a stale
--                     row would keep being listed -- and addressed -- without
--                     its apostrophe until something happened to touch it.
--                     Restricted to the player's own realm because that is the
--                     one realm whose old and new spellings we can both name
--                     for certain: given only "bob-kelthuzad" there is no way
--                     to tell a stripped "Kel'Thuzad" from a realm genuinely
--                     spelled that way.
--
-- There is no version stamp and no upgrade pass, so this also works on saved
-- variables written by a build this one has never seen, and it is inert (one
-- string compare) for the great majority of players, whose realm contains
-- neither an apostrophe nor a period.
-------------------------------------------------------------

local function LegacyKey(name)
  return (BuildKey(name, LegacyNormalizeRealm, LegacyCurrentRealm))
end

-- True only when the two normalisations can actually disagree for this input:
-- an apostrophe in the resolved realm (kept now, stripped then) or a period
-- anywhere in the input (stripped now, kept then). The state map is sparse, so
-- misses are the common case, and this keeps the miss path free of a second
-- key build for everyone the migration cannot possibly concern.
local function LegacyMayDiffer(input, realm)
  if realm ~= "" and realm:find("'", 1, true) then return true end
  return type(input) == "string" and input:find(".", 1, true) ~= nil
end

-- Defined below; a miss in RowFor is the first place it is wanted.
local SweepOwnRealmKeys

-- map[key], first moving a pre-fix row onto `key` if that is where it lives.
-- `input` is the caller's original argument (a raw name or a key) and `realm`
-- the realm half R.Key resolved from it.
local function RowFor(map, key, input, realm)
  if type(map) ~= "table" or key == "" then return nil end
  local row = map[key]
  if type(row) == "table" then return row end
  -- The one-shot sweep, paid for on the first miss of the session rather than
  -- only when a list is enumerated: a favourite filed under a pre-fold key
  -- has to answer to R.Get and R.Display too, and those come first.
  SweepOwnRealmKeys(map)
  row = map[key]
  if type(row) == "table" then return row end
  if not LegacyMayDiffer(input, realm) then return nil end

  local legacy = LegacyKey(input)
  if legacy == "" or legacy == key then return nil end
  local stale = map[legacy]
  if type(stale) ~= "table" then return nil end

  map[legacy] = nil
  -- row.realm was saved in the pre-fix shape too ("Twilightshammer"). Drop it
  -- when it no longer normalises to this key's realm, so R.Display recovers the
  -- apostrophe from the alt tables (or by capitalising the key) rather than
  -- printing an address that is still missing it.
  local lower = Helpers().Lower
  if type(stale.realm) == "string" and lower(NormalizeRealm(stale.realm)) ~= lower(realm) then
    stale.realm = nil
  end
  map[key] = stale
  return stale
end

-- Runs at most once per resolved realm. Keys are "name-realm" with the name
-- half guaranteed hyphen-free, so the old realm can be matched as a suffix.
--
-- The same pass carries a second, unrelated migration: keys whose name half
-- holds an uppercase non-ASCII letter. The key fold used to be Lua's
-- string.lower, which leaves every byte above 127 alone, so a Cyrillic or
-- accented name was filed under its capitalised spelling ("Иван-realm").
-- The fold now lowercases those letters too (Lib/Util.lua), and the row has
-- to move to where the new key will look for it or the favourite is simply
-- gone. It is a one-string test per key, and inert for a map of plain
-- ASCII names, which is nearly every map there is.
local sweptRealm = nil

function SweepOwnRealmKeys(map)
  if type(map) ~= "table" then return end
  local realm = CurrentRealm()
  if realm == "" or sweptRealm == realm then return end
  sweptRealm = realm

  local lower = Helpers().Lower
  local legacyRealm = LegacyCurrentRealm()
  local suffix = nil
  if legacyRealm ~= "" and lower(legacyRealm) ~= lower(realm) then
    suffix = "-" .. lower(legacyRealm)
  end

  -- Collected first and moved after: adding keys to a table under pairs() is
  -- undefined in Lua, and both migrations add keys.
  local moves = {}
  for key, row in pairs(map) do
    if type(key) == "string" and type(row) == "table" then
      local target = key
      if suffix and #key > #suffix and key:sub(#key - #suffix + 1) == suffix then
        target = key:sub(1, #key - #suffix) .. "-" .. lower(realm)
      end
      -- Cheap for the common case: a key with no byte above 127 lowercases
      -- to itself and is never even compared.
      if key:find("[\128-\255]") then target = lower(target) end
      if target ~= key then moves[#moves + 1] = { key, target, row } end
    end
  end

  for _, move in ipairs(moves) do
    map[move[1]] = nil
    if type(map[move[2]]) ~= "table" then
      local row = move[3]
      if suffix and type(row.realm) == "string"
         and lower(NormalizeRealm(row.realm)) ~= lower(realm) then
        -- Unlike the lazy path this one knows the answer: CurrentRealm carries
        -- the client's own spelling and casing of the player's realm.
        row.realm = realm
      end
      map[move[2]] = row
    end
  end
end

-------------------------------------------------------------
-- Addressing
--
-- The one rule for what may be written into the To: box, in one place, because
-- getting it wrong is silent: SendMail accepts a bare name and delivers it to
-- the character of that name ON THE SENDER'S OWN REALM. A bare name for an
-- off-realm character is therefore not a shorter address, it is a wrong one --
-- it reaches somebody else or nobody at all.
--
-- Connected realms are NOT given a shortcut here, deliberately.
-- GetAutoCompleteRealms() is the only API that names the player's connected
-- group, and it is a poor foundation: deprecated as of 12.0.5 (this addon
-- targets 12.1), unpopulated until PLAYER_LOGIN, and undocumented as to whether
-- the player's own realm is even in the list. An address that always works
-- beats one that is prettier and occasionally silently misdelivers, so every
-- realm that is not the player's own keeps its suffix.
--
-- Ambiguate(name, "mail") was evaluated for this job and deliberately not used.
-- It is a total function to a safe address form -- it returns "character-realm"
-- in all four of its documented cases, and Blizzard's own To: box uses that
-- context -- but it solves neither half of the problem here. It cannot invent a
-- realm for a bare name, which is the only genuinely hard case (that rule lives
-- in R.Key: bare means my realm), and it does not normalise the realm's
-- punctuation, which is the bug this module actually had. What it WOULD change
-- is that every same-realm recipient in the picker grows a redundant "-Realm"
-- suffix, which is noise in a list the player reads. Nothing gained, legibility
-- lost, and a Blizzard global on the hot path for it.
-------------------------------------------------------------

local function FormatAddress(short, realm)
  if short == "" then return "" end
  -- No realm half at all (including the pre-login window, where CurrentRealm is
  -- "" and no comparison is meaningful): the bare name is all we have, and it
  -- is what mail defaults to anyway.
  if realm == "" then return short end
  local lower = Helpers().Lower
  if lower(realm) == lower(CurrentRealm()) then return short end
  return short .. "-" .. realm
end

-- name -> the string to put in the To: box, keeping the caller's own casing.
--
-- The cheap half of R.Display: pure, and it never reads a saved variable. Use
-- it for names that came from a live source (guild roster, friends list,
-- Battle.net, autocomplete), which already carry the client's own spelling.
-- R.Display is for names rebuilt from a key, where the casing has to be
-- recovered from storage first.
--
-- Idempotent: R.Address(R.Address(x)) == R.Address(x).
function R.Address(name)
  local k, short, realm = R.Key(name)
  if k == "" then return "" end
  return FormatAddress(short, realm)
end

-------------------------------------------------------------
-- Alt tables (alts / altClasses / altMeta)
--
-- These three are keyed by GetRealmName() -- the raw realm, which may contain
-- spaces and apostrophes and whose casing is whatever the client returned.
-- Recipient keys use the normalised lowercase realm, so bucket lookups have to
-- compare normalised forms instead of indexing directly. Both sides of that
-- comparison go through NormalizeRealm, so the apostrophe fix does not disturb
-- these tables: their keys are raw and were never rewritten.
--
-- PostboxDB.alts[realm] stays a plain array: ContactService's saved-alt
-- collector ipairs() it, and reshaping it would be a breaking migration for no
-- gain.
-------------------------------------------------------------

local function MatchingRealmBuckets(container, realm)
  local out = {}
  if type(container) ~= "table" or realm == "" then return out end
  local lower = Helpers().Lower
  local want = lower(realm)
  for realmKey in pairs(container) do
    if type(realmKey) == "string" and lower(NormalizeRealm(realmKey)) == want then
      out[#out + 1] = realmKey
    end
  end
  return out
end

-- Visits every stored character name for `realm`, as
--   fn(name, tableName, realmKey, index)
-- where tableName is "alts" / "altClasses" / "altMeta" and index is only set
-- for the alts array. Realm buckets are collected up front and the alts array
-- is walked backwards, so a visitor may remove what it is shown.
local function ForEachStoredAlt(realm, fn)
  local db = DB()
  if not db or realm == "" then return end

  local altBuckets = MatchingRealmBuckets(db.alts, realm)
  for _, realmKey in ipairs(altBuckets) do
    local list = db.alts[realmKey]
    if type(list) == "table" then
      for i = #list, 1, -1 do
        if type(list[i]) == "string" then fn(list[i], "alts", realmKey, i) end
      end
    end
  end

  local mapped = { "altClasses", "altMeta" }
  for _, tableName in ipairs(mapped) do
    local container = db[tableName]
    local buckets = MatchingRealmBuckets(container, realm)
    for _, realmKey in ipairs(buckets) do
      local bucket = container[realmKey]
      if type(bucket) == "table" then
        for charName in pairs(bucket) do
          if type(charName) == "string" then fn(charName, tableName, realmKey) end
        end
      end
    end
  end
end

-- Best-effort original casing for a key whose state row does not carry a name
-- yet. Only the saved alt tables are consulted -- live sources are not a source
-- of truth here and are not worth a roster scan for a cosmetic detail.
local function StoredCasing(short, realm)
  if short == "" or realm == "" then return nil end
  local lower = Helpers().Lower
  local want = lower(short)
  local foundName, foundRealm
  ForEachStoredAlt(realm, function(name, _, realmKey)
    if not foundName and lower(name) == want then
      foundName = name
      foundRealm = NormalizeRealm(realmKey)
    end
  end)
  return foundName, foundRealm
end

-- Turns the lowercase halves of a key back into something presentable.
local function ResolveCasing(short, realm)
  local storedName, storedRealm = StoredCasing(short, realm)
  return storedName or Capitalize(short), storedRealm or Capitalize(realm)
end

-------------------------------------------------------------
-- State rows
-------------------------------------------------------------

-- A row is "default" when nothing about it is worth persisting. name/realm/added
-- are bookkeeping and never keep a row alive on their own.
local function IsDefaultRow(row)
  if type(row) ~= "table" then return true end
  if row.hidden or row.fav or row.manual then return false end
  if type(row.note) == "string" and row.note ~= "" then return false end
  return true
end

-- Drops a row that has returned to all-default. Keeping the map sparse is a
-- requirement, not an optimisation -- see the module header.
local function Prune(key)
  local map = StateMap()
  if not map then return end
  if IsDefaultRow(map[key]) then map[key] = nil end
end

-- key -> row, or nil. Never creates. Accepts a raw name as well as a key.
function R.Get(key)
  local k, _, realm = R.Key(key)
  if k == "" then return nil end
  local row = RowFor(StateMap(), k, key, realm)
  return type(row) == "table" and row or nil
end

-- key -> row, creating it (with name/realm populated) when absent.
--
-- `key` is authoritative for identity. `name` is only used to give the row its
-- original casing, and only when it resolves to the same key -- a disagreeing
-- name is ignored rather than silently retargeting the write.
function R.Ensure(key, name)
  local k, short, realm = R.Key(key)
  if k == "" then return nil end
  -- Held before the casing pass below rewrites `realm` into its display form;
  -- the migration lookup wants the key's own realm half.
  local keyRealm = realm

  local cased = false
  -- A hint that IS the key carries no casing (a key is all lowercase), so it
  -- is passed over for the recovery below rather than filed as the name.
  if type(name) == "string" and name ~= "" and name ~= k then
    local nk, nShort, nRealm = R.Key(name)
    if nk == k then
      short, realm = nShort, nRealm
      cased = true
    end
  end
  if not cased then short, realm = ResolveCasing(short, realm) end

  local map = StateMapRW()
  if not map then return nil end

  local row = RowFor(map, k, key, keyRealm)
  if type(row) ~= "table" then
    row = {}
    map[k] = row
  end
  if type(row.name) ~= "string" or row.name == "" then row.name = short end
  if realm ~= "" and (type(row.realm) ~= "string" or row.realm == "") then row.realm = realm end
  return row
end

-- key -> the string to put in the To: box, with the recipient's stored casing
-- restored. R.Address's rule for the realm half; see that function.
--
-- Costlier than R.Address because recovering the casing means scanning the
-- saved alt tables when no state row exists. Fine for a single name on a click;
-- not something to run once per guild member on a keystroke.
function R.Display(key)
  local k, short, realm = R.Key(key)
  if k == "" then return "" end

  local row = RowFor(StateMap(), k, key, realm)
  local storedName, storedRealm
  if type(row) == "table" then
    if type(row.name) == "string" and row.name ~= "" then storedName = row.name end
    if type(row.realm) == "string" and row.realm ~= "" then storedRealm = row.realm end
  end

  -- Each half falls back independently. A row can legitimately carry one and
  -- not the other -- a migrated row has had its pre-fix realm dropped, and an
  -- old row may never have had one -- and taking the key's lowercase realm in
  -- that case would print "Bob-twilight'shammer".
  if not storedName or not storedRealm then
    local casedName, casedRealm = ResolveCasing(short, realm)
    storedName = storedName or casedName
    storedRealm = storedRealm or casedRealm
  end

  return FormatAddress(storedName, storedRealm)
end

function R.IsHidden(keyOrName)
  local row = R.Get(keyOrName)
  return (row ~= nil and row.hidden == true)
end

function R.IsFavorite(keyOrName)
  local row = R.Get(keyOrName)
  return (row ~= nil and row.fav == true)
end

-- fav and hidden are mutually exclusive: a hidden favourite is a contradiction,
-- so each setter clears the other rather than leaving the UI to sort it out.
--
-- Each passes the caller's own string to R.Ensure as the casing source. The
-- setters are reached from lists that hold the client's spelling of a name,
-- and a row created from the bare key would have to reconstruct its casing
-- by capitalising a lowercase key -- a guess, and for a name in any alphabet
-- the fold does not know, a wrong one. R.Ensure ignores the hint unless it
-- resolves to the same key, so a caller passing a key gets the old behaviour.
function R.SetHidden(key, on)
  local k = R.Key(key)
  if k == "" then return false end
  local row = R.Ensure(k, key)
  if not row then return false end
  row.hidden = on and true or nil
  if row.hidden then row.fav = nil end
  local result = row.hidden == true
  Prune(k)
  return result
end

function R.SetFavorite(key, on)
  local k = R.Key(key)
  if k == "" then return false end
  local row = R.Ensure(k, key)
  if not row then return false end
  row.fav = on and true or nil
  if row.fav then row.hidden = nil end
  local result = row.fav == true
  Prune(k)
  return result
end

-- Trimmed and truncated to NOTE_MAX_CHARS. An empty string clears the note (and
-- with it the row, if the note was the only thing keeping it alive).
function R.SetNote(key, text)
  local k = R.Key(key)
  if k == "" then return nil end
  local note = TruncateChars(Helpers().NormalizeText(text), NOTE_MAX_CHARS)
  local row = R.Ensure(k, key)
  if not row then return nil end
  if note == "" then
    row.note = nil
  else
    row.note = note
  end
  local result = row.note
  Prune(k)
  return result
end

-- name -> key, or nil plus a locale key describing why it was rejected.
--
-- A manual recipient is also marked as a favourite: the player just typed it in
-- and will look for it at the top of the list, not buried in an alphabetical
-- roster of several hundred guild members.
function R.AddManual(name)
  local text = Helpers().NormalizeText(name)
  if text == "" then return nil, "RM_ERR_NAME_EMPTY" end

  local k, short, realm = R.Key(text)
  if k == "" or short == "" then return nil, "RM_ERR_NAME_EMPTY" end
  if short:find("%s") then return nil, "RM_ERR_NAME_SPACES" end

  local charCount = Helpers().CharCount
  local shortLen = charCount(short)
  if shortLen < NAME_MIN_CHARS or shortLen > NAME_MAX_CHARS then
    return nil, "RM_ERR_NAME_LENGTH"
  end
  if charCount(realm) > REALM_MAX_CHARS then return nil, "RM_ERR_NAME_LENGTH" end

  local map = StateMapRW()
  if not map then return nil, "RM_ERR_NOT_READY" end
  local existing = RowFor(map, k, text, realm)
  if type(existing) == "table" and existing.manual then return nil, "RM_ERR_ALREADY_ADDED" end

  local row = R.Ensure(k, text)
  if not row then return nil, "RM_ERR_NOT_READY" end
  row.manual = true
  row.fav = true
  row.hidden = nil
  row.added = row.added or Now()
  return k
end

-------------------------------------------------------------
-- Deletion
-------------------------------------------------------------

local function HistoryHolds(key)
  local list = HistoryList()
  if not list then return false end
  for i = 1, #list do
    local entry = list[i]
    if type(entry) == "string" and R.Key(entry) == key then return true end
  end
  return false
end

local function RemoveFromHistory(key)
  local list = HistoryList()
  if not list then return 0 end
  local removed = 0
  for i = #list, 1, -1 do
    local entry = list[i]
    if type(entry) == "string" and R.Key(entry) == key then
      table.remove(list, i)
      removed = removed + 1
    end
  end
  return removed
end

local function StoredAsAlt(short, realm)
  local lower = Helpers().Lower
  local want = lower(short)
  local found = false
  ForEachStoredAlt(realm, function(name)
    if lower(name) == want then found = true end
  end)
  return found
end

-- key -> bool, reason (a locale key, set only when false).
--
-- Deleting only makes sense for names Postbox itself stored. A guild member,
-- friend or autocomplete hit is regenerated by the very next scan, so there is
-- nothing to delete and the manager should offer Hide instead of pretending
-- otherwise. Curation state on its own (hidden/fav/note) is not an identity --
-- removing it would un-hide the recipient rather than remove it.
function R.CanDelete(key)
  local k, short, realm = R.Key(key)
  if k == "" then return false, "RM_ERR_NAME_EMPTY" end

  local row = R.Get(k)
  if row and row.manual then return true end
  if HistoryHolds(k) then return true end
  if StoredAsAlt(short, realm) then return true end
  return false, "RM_ERR_LIVE_ONLY"
end

-- Removes everything Postbox has stored for a recipient and reports what was
-- actually removed, so the UI can say what happened instead of guessing:
--
--   { key = "bob-ravencrest", state = true, history = 2,
--     alts = true, altClasses = true, altMeta = false, any = true }
--
-- Deliberately NOT gated on R.CanDelete: the caller decides whether deleting is
-- offered, and this still resets the state row if it is called anyway.
function R.Delete(key)
  local k, short, realm = R.Key(key)
  local removed = {
    key = k, state = false, history = 0,
    alts = false, altClasses = false, altMeta = false, any = false,
  }
  if k == "" then return removed end

  local map = StateMap()
  if map then
    -- Adopt any pre-fix row first, so deleting a recipient on an apostrophe
    -- realm clears the old key as well as the new one instead of leaving state
    -- behind that would reappear the moment the migration ran.
    RowFor(map, k, key, realm)
    if map[k] ~= nil then
      map[k] = nil
      removed.state = true
    end
  end

  removed.history = RemoveFromHistory(k)

  local db = DB()
  local lower = Helpers().Lower
  local want = lower(short)
  local touched = {}
  ForEachStoredAlt(realm, function(name, tableName, realmKey, index)
    if lower(name) ~= want then return end
    if tableName == "alts" then
      table.remove(db.alts[realmKey], index)
      removed.alts = true
    else
      db[tableName][realmKey][name] = nil
      removed[tableName] = true
    end
    touched[#touched + 1] = { tableName, realmKey }
  end)

  -- Drop realm buckets the deletion emptied so the saved variables do not
  -- accumulate husks of realms the player no longer has characters on.
  for _, entry in ipairs(touched) do
    local container = db and db[entry[1]]
    local bucket = container and container[entry[2]]
    if type(bucket) == "table" and next(bucket) == nil then
      container[entry[2]] = nil
    end
  end

  removed.any = removed.state or removed.history > 0
    or removed.alts or removed.altClasses or removed.altMeta
  return removed
end

-------------------------------------------------------------
-- Enumeration
-------------------------------------------------------------

-- Sorted array of mailable display names for every favourite.
function R.Favorites()
  local out = {}
  local map = StateMap()
  if not map then return out end
  SweepOwnRealmKeys(map)
  for k, row in pairs(map) do
    if type(row) == "table" and row.fav then out[#out + 1] = R.Display(k) end
  end
  local lower = Helpers().Lower
  table.sort(out, function(a, b)
    local la, lb = lower(a), lower(b)
    if la == lb then return a < b end
    return la < lb
  end)
  return out
end

-- True when any recipient carries curation state at all -- one next(), so a
-- caller can skip per-name state work entirely on a profile that has never
-- hidden, favourited or annotated anything, which is the common case.
function R.HasState()
  local map = StateMap()
  return map ~= nil and next(map) ~= nil
end

-- Iterates the state rows as fn(key, row). Only rows that carry non-default
-- state exist, so this is NOT a list of every known recipient -- it is the
-- curation overlay. Returning true from fn stops the iteration.
function R.ForEach(fn)
  if type(fn) ~= "function" then return end
  local map = StateMap()
  if not map then return end
  -- Enumeration is the one path the lazy migration cannot reach, so it is where
  -- the own-realm sweep is paid for. Runs at most once; see its definition.
  SweepOwnRealmKeys(map)
  for k, row in pairs(map) do
    if type(row) == "table" then
      if fn(k, row) == true then return end
    end
  end
end

-------------------------------------------------------------
-- Alt metadata
-------------------------------------------------------------

-- keyOrName -> the live { level, lastSeen, faction } table, or nil. Treat it as
-- read-only; R.RecordAlt owns the writes.
function R.AltMeta(keyOrName)
  local _, short, realm = R.Key(keyOrName)
  if short == "" or realm == "" then return nil end
  local db = DB()
  if not db or type(db.altMeta) ~= "table" then return nil end

  local lower = Helpers().Lower
  local want = lower(short)
  local buckets = MatchingRealmBuckets(db.altMeta, realm)
  for _, realmKey in ipairs(buckets) do
    local bucket = db.altMeta[realmKey]
    if type(bucket) == "table" then
      for name, meta in pairs(bucket) do
        if type(name) == "string" and lower(name) == want and type(meta) == "table" then
          return meta
        end
      end
    end
  end
  return nil
end

-- Records what we know about one of the player's own characters. Keyed by the
-- raw GetRealmName() so it sits alongside PostboxDB.alts / altClasses.
--
-- level and faction are only written when they look real: UnitLevel is not
-- reliably populated at ADDON_LOADED, and overwriting a good level with 0 would
-- make the manager show worse data after a relog than before it.
function R.RecordAlt(name, realm, level, class, faction)
  if not CanWrite() then return nil end
  local short = Helpers().NormalizeText(name)
  local realmKey = Helpers().NormalizeText(realm)
  if short == "" or realmKey == "" then return nil end

  local meta = ns.Store.EnsurePath("altMeta", {})
  meta[realmKey] = meta[realmKey] or {}
  local row = meta[realmKey][short]
  if type(row) ~= "table" then
    row = {}
    meta[realmKey][short] = row
  end

  if type(level) == "number" and level > 0 then row.level = level end
  if type(faction) == "string" and faction ~= "" and faction ~= "Neutral" then
    row.faction = faction
  end
  row.lastSeen = Now()

  -- Class already has a home in altClasses (ContactService reads it there);
  -- mirror it only when missing so the refresh paths do not have to repeat
  -- RegisterCurrentAlt's write.
  if type(class) == "string" and class ~= "" then
    local classes = ns.Store.EnsurePath("altClasses", {})
    classes[realmKey] = classes[realmKey] or {}
    if classes[realmKey][short] == nil then classes[realmKey][short] = class end
  end

  return row
end
