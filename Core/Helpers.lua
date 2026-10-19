local _, ns = ...

-------------------------------------------------------------
-- Shared utility surface for the mail domain.
--
-- Three of the four names are the foundation layer's own functions, republished
-- under the names the rest of Core/ has always used. They are captured BY
-- REFERENCE at load time, which is why Postbox.toc loads the whole of Lib\
-- before Core\ (the TOC says so out loud). A wrapper would be a spurious call
-- frame on a path that runs once per guild member per keystroke.
--
-- Every function here returns EXACTLY ONE value. That is a contract, not a
-- detail: a gsub chain returns (string, count), and a helper that propagates
-- both silently corrupts any use in a multi-value position -- the last argument
-- of a call, string.format(...), table.insert(t, x), a table constructor.
-- Core/Recipients.lua defensively parenthesises its own gsubs for this reason;
-- it should not have to do the same to ours.
-------------------------------------------------------------

ns.Helpers = ns.Helpers or {}
local H = ns.Helpers

-- value -> trimmed string ("" for nil / non-string). Interior whitespace kept.
H.NormalizeText = ns.Core.Strings.Trim

-- value -> trimmed, lowercased string. Used as a case-folding key generator, so
-- it must be total and stable.
H.Lower = ns.Core.Strings.Lower

-- The rest of the foundation's text surface, under the names Core/ reads them
-- by. Same capture-by-reference contract as the three above.
H.Upper        = ns.Core.Strings.Upper
H.Capitalize   = ns.Core.Strings.Capitalize
H.CharCount    = ns.Core.Strings.CharCount
H.CharBoundary = ns.Core.Strings.CharBoundary

-------------------------------------------------------------
-- Auction subjects, shortened
--
-- Every auction-house mail carries a subject built from one of the client's
-- templates -- "Auction won: %s", "Auction successful: %s" and so on -- and
-- the list already says who sent it and what kind of mail it is. The
-- template half is therefore said three times on one row, and the item's
-- name, the only part that varies, is the part pushed off the end. This
-- returns just the item name for a subject that matches one of those
-- templates, and the subject untouched for anything else.
--
-- Patterns are built once from the client's own (localised) templates, so
-- this is right in every locale the client is, and it is plain string work
-- with no magic characters left live: everything but the placeholder is
-- escaped before the placeholder becomes a capture.
-------------------------------------------------------------

local SUBJECT_TEMPLATES = {
  "AUCTION_WON_MAIL_SUBJECT", "AUCTION_SOLD_MAIL_SUBJECT",
  "AUCTION_EXPIRED_MAIL_SUBJECT", "AUCTION_REMOVED_MAIL_SUBJECT",
  "AUCTION_OUTBID_MAIL_SUBJECT", "AUCTION_INVOICE_MAIL_SUBJECT",
}

local subjectPatterns = nil

local function SubjectPatterns()
  if subjectPatterns then return subjectPatterns end
  subjectPatterns = {}
  for i = 1, #SUBJECT_TEMPLATES do
    local template = _G[SUBJECT_TEMPLATES[i]]
    -- A PLAIN find, so the placeholder is spelled as it appears, not as a
    -- pattern would spell it. (Spelling it "%%s" here matched nothing, and
    -- every subject came back untouched.)
    if type(template) == "string" and template:find("%s", 1, true) then
      -- Escape everything, then let the one placeholder through as a capture.
      local escaped = template:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
      local pattern = "^%s*" .. escaped:gsub("%%%%s", "(.-)", 1) .. "%s*$"
      subjectPatterns[#subjectPatterns + 1] = pattern
    end
  end
  return subjectPatterns
end

-- subject -> the item name alone for an auction-template subject, else the
-- subject as given. Never empty for a non-empty input: a template whose
-- capture comes back blank hands the whole subject back instead.
function H.ShortSubject(subject)
  if type(subject) ~= "string" or subject == "" then return subject or "" end
  local patterns = SubjectPatterns()
  for i = 1, #patterns do
    local item = subject:match(patterns[i])
    if item and item ~= "" then return item end
  end
  return subject
end

-------------------------------------------------------------
-- Who is playing, and how names are written
--
-- Retail names are one word, and "Name-Realm" addresses a character on
-- another realm. World of Warcraft: Forever gives every character a main
-- name and a secondary name ("Abla Stone"), unique across the region, so a
-- full name is an address on its own: Forever never puts a realm in one, and
-- Blizzard accepts "Abla-Stone" as well as "Abla Stone" there, so a hyphen
-- is not a realm separator. Mail cannot cross Forever's rulesets, and its
-- realm names drift inside one ruleset ("Classic Beta PvE" and "... PvE 2"),
-- so Postbox's "my realm" on Forever is the ruleset, named the way AceDB and
-- Syndicator name it: PvE, PvP, RP, Hardcore.
--
-- Everything here returns exactly one value, as the rest of this file does,
-- and is memoised once it has a real answer: neither the character nor its
-- realm can change while this Lua state lives.
-------------------------------------------------------------

local function IsSecret(value)
  return type(issecretvalue) == "function" and issecretvalue(value) == true
end

-- Blizzard's own separator between the two names, a space.
local separator = nil
local function Separator()
  if separator then return separator end
  local consts = type(Constants) == "table" and Constants.CharacterNameSeparatorConsts or nil
  local sep = type(consts) == "table" and consts.CHARACTERNAME_SURNAME_SEPARATOR or nil
  separator = (type(sep) == "string" and sep ~= "") and sep or " "
  return separator
end
H.NameSeparator = Separator

-- Whether character names have two parts: Forever, or any client that
-- answers RegionalUniqueNamesEnabled() yes. Constant for the session.
local twoPart = nil
function H.TwoPartNames()
  if twoPart ~= nil then return twoPart end
  local on = ns.IsForever == true
  if not on and type(RegionalUniqueNamesEnabled) == "function" then
    local ok, value = pcall(RegionalUniqueNamesEnabled)
    on = ok and value == true
  end
  twoPart = on
  return on
end

-- name, surname -> "Name Surname", or name alone when there is no surname
-- or the name already ends with it (an early Forever build handed both
-- parts back as the first value).
local function JoinSurname(name, surname)
  if type(name) ~= "string" or name == "" then return name end
  if type(surname) ~= "string" or surname == "" then return name end
  local tail = Separator() .. surname
  if #name > #tail and name:sub(-#tail) == tail then return name end
  return name .. tail
end

-- The character being played, by name: retail's UnitName("player"), exactly;
-- on Forever the full name, "Abla Stone". On Forever a name without its
-- second half is half an identity: it is returned but never kept, so the
-- next call asks again.
local playerName = nil
function H.PlayerName()
  if playerName then return playerName end
  if type(UnitName) ~= "function" then return nil end
  if not H.TwoPartNames() then
    local name = UnitName("player")
    if not IsSecret(name) and type(name) == "string" and name ~= "" then playerName = name end
    return name
  end
  local name, surname = UnitName("player")
  if IsSecret(name) or IsSecret(surname) then return name end
  local full = JoinSurname(name, surname)
  if type(full) == "string" and not full:find(Separator(), 1, true)
     and type(UnitNameUnmodified) == "function" then
    local n, s = UnitNameUnmodified("player")
    if not (IsSecret(n) or IsSecret(s)) then
      local other = JoinSurname(n, s)
      if type(other) == "string" and other:find(Separator(), 1, true) then full = other end
    end
  end
  if type(full) == "string" and full:find(Separator(), 1, true) then playerName = full end
  return full
end

-- Forever's ruleset, as the realm key: Hardcore, RP, PvP, or PvE for the
-- normal one (AceDB-3.0's names and order). Kept once the player is logged
-- in; before that the game rules may not be known yet, so it is asked again.
local ruleset = nil
local RULESETS = { { "HardcoreRuleset", "Hardcore" }, { "RPRuleset", "RP" }, { "PvPRuleset", "PvP" } }
local function Ruleset()
  if ruleset then return ruleset end
  local answer = "PvE"
  local rules = type(Enum) == "table" and Enum.GameRule or nil
  if type(C_GameRules) == "table" and type(C_GameRules.IsGameRuleActive) == "function"
     and type(rules) == "table" then
    for i = 1, #RULESETS do
      local rule = rules[RULESETS[i][1]]
      if rule ~= nil then
        local ok, active = pcall(C_GameRules.IsGameRuleActive, rule)
        if ok and active == true then
          answer = RULESETS[i][2]
          break
        end
      end
    end
  end
  if type(IsLoggedIn) == "function" and IsLoggedIn() then ruleset = answer end
  return answer
end

-- The realm the character being played is on, as a key.
--   retail, plain:       GetRealmName(), "Twilight's Hammer"
--   retail, normalized:  GetNormalizedRealmName(), "Twilight'sHammer", or
--                        GetRealmName() in the moment after login where the
--                        normalized one is not known yet (not kept)
--   Forever:             the ruleset, either way
local realmPlain, realmNormalized = nil, nil
function H.PlayerRealm(normalized)
  if ns.IsForever then return Ruleset() end
  if normalized then
    if realmNormalized then return realmNormalized end
    local realm
    if type(GetNormalizedRealmName) == "function" then
      local ok, value = pcall(GetNormalizedRealmName)
      if ok and type(value) == "string" then realm = value end
    end
    if realm and realm ~= "" then
      realmNormalized = realm
      return realm
    end
    if type(GetRealmName) == "function" then
      local ok, value = pcall(GetRealmName)
      if ok and type(value) == "string" then realm = value end
    end
    return realm
  end
  if realmPlain then return realmPlain end
  if type(GetRealmName) ~= "function" then return nil end
  local realm = GetRealmName()
  if type(realm) == "string" and realm ~= "" and not IsSecret(realm) then realmPlain = realm end
  return realm
end

-- text -> on a client with two-part names, the full name it spells, the
-- caller's casing kept: "abla-stone" and "Abla  Stone" both give the two
-- names joined by one separator, a single name is itself, and anything
-- after the second name (a realm someone joined on) is not part of it.
-- Elsewhere the text, trimmed. Never nil.
function H.FullName(text)
  text = H.NormalizeText(text)
  if text == "" or not H.TwoPartNames() then return text end
  local sep = Separator()
  -- Already in shape: the common case, and it builds nothing.
  if sep == " " and text:find("^[^%s%-]+ [^%s%-]+$") then return text end
  local first, second
  for part in text:gmatch("[^%s%-]+") do
    if not first then
      first = part
    else
      second = part
      break
    end
  end
  if not first then return "" end
  if not second then return first end
  return first .. sep .. second
end

-- A name as written from a lowercase key: each name's first letter up.
-- Retail's is Capitalize; Forever's capitalizes both halves ("Abla Stone",
-- where Capitalize alone would give "Abla stone").
function H.CapitalizeName(text)
  if not H.TwoPartNames() then return H.Capitalize(text) end
  if type(text) ~= "string" or text == "" then return "" end
  local sep = Separator()
  local at = text:find(sep, 1, true)
  if not at then return H.Capitalize(text) end
  return H.Capitalize(text:sub(1, at - 1)) .. sep .. H.Capitalize(text:sub(at + #sep))
end

-- Letters only: ASCII letters and anything outside ASCII (an accented,
-- Cyrillic or Hangul letter), as Blizzard's name boxes allow.
local NAME_PART_MIN, NAME_PART_MAX = 2, 12

-- text -> the full name a player typed, in the game's spelling ("Abla
-- Stone" from "abla-stone"), or false when it is not one: exactly two
-- names of letters only, each 2 to 12 of them (Forever's character create
-- allows 12 a name, and the game's names start at 2), with one space or
-- one hyphen between. For the boxes that take a name typed by hand, on a
-- client with two-part names; RM_ERR_NAME_FULL says what is wanted.
function H.TypedFullName(text)
  text = H.NormalizeText(text)
  local first, second = text:match("^([%a\128-\255]+)[ %-]([%a\128-\255]+)$")
  if not first then return false end
  local a, b = H.CharCount(first), H.CharCount(second)
  if a < NAME_PART_MIN or a > NAME_PART_MAX or b < NAME_PART_MIN or b > NAME_PART_MAX then
    return false
  end
  return H.Capitalize(H.Lower(first)) .. Separator() .. H.Capitalize(H.Lower(second))
end

-- name -> the name as it is SHOWN. Forever lets a player hide their own
-- secondary name (C_PlayerInfo.ShouldDisplaySurname, which EllesmereUI
-- honors too); where they have, the character being played is shown by its
-- main name alone. Display only: every address and key keeps the full name.
local shortPlayerName = nil
function H.ShownName(name)
  if not ns.IsForever or type(name) ~= "string" or name == "" then return name end
  local me = H.PlayerName()
  if name ~= me then return name end
  local info = C_PlayerInfo
  if not (type(info) == "table" and type(info.ShouldDisplaySurname) == "function") then return name end
  local ok, show = pcall(info.ShouldDisplaySurname)
  if not ok or show ~= false then return name end
  if not shortPlayerName then
    local at = me:find(Separator(), 1, true)
    shortPlayerName = at and me:sub(1, at - 1) or me
  end
  return shortPlayerName
end

-- copper -> compact plain text ("12g 30s"), "" for zero.
H.FormatMoney = ns.Core.Formatting.FormatMoneyText

-- Whether a PLAYER_INTERACTION_MANAGER_FRAME_SHOW/HIDE payload is the mailbox:
-- Enum.PlayerInteractionType.MailInfo, or its number (17) on a client that
-- does not publish the enum.
local MAIL_INTERACTION = 17
function H.IsMailInteraction(kind)
  if kind == MAIL_INTERACTION then return true end
  local enum = type(Enum) == "table" and Enum.PlayerInteractionType or nil
  return enum ~= nil and kind == enum.MailInfo
end

-------------------------------------------------------------
-- Time left
--
-- One way to write how long a mail has left, wherever it is written: the
-- Mail tab's rows, their tooltip and the reading view, and Mail Memory's
-- rows and warnings. Hours under a day ("9h", never less than 1h), whole
-- days after, floored ("3d" from three days to just under four), so a
-- figure never reads as more than is left and the amber that starts under
-- three days (CollectTab's ExpiryState) always starts at "2d". Each text is
-- made once per value and kept: a list holds a few dozen distinct values
-- (hours 1-23 and days up to the mail's thirty), and a table past
-- TIME_MAX (only a wrong clock gets there) is emptied and filled again.
-------------------------------------------------------------
local TIME_MAX = 120
local timeShort, timeDetail = {}, {}
local timeCount = 0

-- days (a number, fractions welcome) -> the value's key: -hours under a
-- day, whole days otherwise.
local function TimeKey(days)
  days = tonumber(days) or 0
  if days < 1 then return -math.max(1, math.floor(days * 24)) end
  return math.floor(days)
end

local function TimeText(key)
  local text = timeShort[key]
  if text then return text end
  if timeCount >= TIME_MAX then
    for k in pairs(timeShort) do timeShort[k] = nil end
    for k in pairs(timeDetail) do timeDetail[k] = nil end
    timeCount = 0
  end
  local L = ns.L
  if key < 0 then text = L("HOURS_SHORT", -key) else text = L("DAYS_SHORT", key) end
  timeShort[key] = text
  timeDetail[key] = L("DETAIL_EXPIRES", text)
  timeCount = timeCount + 1
  return text
end

-- days -> "9h" / "3d".
function H.TimeLeft(days)
  return TimeText(TimeKey(days))
end

-- days -> "Expires in 9h" / "Expires in 3d".
function H.ExpiresIn(days)
  local key = TimeKey(days)
  TimeText(key)
  return timeDetail[key]
end

-------------------------------------------------------------
-- Mail-subject matching
--
-- Answers: does this mail subject correspond to this Blizzard global format
-- string? The globals in question (AUCTION_SOLD_MAIL_SUBJECT and friends) are
-- localized string.format templates -- "Auction expired: %s" -- and the real
-- subject has the placeholder filled in. So the test is: does the subject
-- contain the template's literal text?
--
-- Two rules make this safe:
--
--   PLAIN matching, never Lua patterns. Localized subjects routinely contain
--   -, (, ), . and %, every one of which is a pattern metacharacter. A pattern
--   match here is both a latent error and a source of false positives.
--
--   The placeholders are stripped BEFORE matching. Testing the raw template
--   could only ever succeed against a subject that literally contained "%s",
--   so it was dead weight.
--
-- This is deliberately the *secondary* signal for classification -- it is
-- locale-shaped, and GetInboxInvoiceInfo answers the same question with a
-- server-supplied token. See Core/MailService.lua.
-------------------------------------------------------------

-- A stripped template shorter than this is not evidence of anything: some
-- locales reduce to a bare connective or a fragment of punctuation that would
-- substring-match ordinary player mail. Bytes, not characters, so that a CJK
-- locale (3 bytes per character) still clears it on one character.
local MIN_LITERAL_BYTES = 3

-- Stripping is pure and the inputs are a handful of constant globals, so the
-- result is memoised: classification runs for every mail on every list refresh.
-- The bound exists only so a caller passing arbitrary strings cannot grow the
-- table without limit; the real key set is two or three entries.
local LITERAL_CACHE_MAX = 32
local literalCache = {}
local literalCacheCount = 0

-- template -> its literal text, lowercased, or "" when nothing usable remains.
local function TemplateLiteral(template)
  local cached = literalCache[template]
  if cached ~= nil then return cached end

  local literal = H.Lower(template)
  -- printf placeholders: "%s", "%d", and the positional "%1$s" form some
  -- locales use. A literal "%%" survives -- its second character is not a
  -- letter, so the pattern cannot consume it.
  literal = literal:gsub("%%%d*%$?%a", " ")
  literal = literal:gsub("%s+", " ")
  -- Punctuation left stranded at either end by the removal ("...: " -> "...")
  -- would have to be matched verbatim in the subject, which is exactly the kind
  -- of locale-specific detail this predicate must not depend on.
  literal = literal:gsub("^[%s%p]+", "")
  literal = literal:gsub("[%s%p]+$", "")
  if #literal < MIN_LITERAL_BYTES then literal = "" end

  if literalCacheCount >= LITERAL_CACHE_MAX then
    literalCache = {}
    literalCacheCount = 0
  end
  literalCache[template] = literal
  literalCacheCount = literalCacheCount + 1
  return literal
end

-- subject, globalPattern [, folded] -> boolean. Case-insensitive, plain
-- matching, false for an empty subject or a template that does not exist in
-- this client build. `folded` is H.Lower(subject) where the caller already has
-- it: a caller testing one subject against several templates folds it once.
function H.SubjectLooksLike(subject, globalPattern, folded)
  if type(globalPattern) ~= "string" then return false end
  local source = folded or H.Lower(subject)
  if source == "" then return false end

  local literal = TemplateLiteral(globalPattern)
  if literal == "" then return false end
  if source == literal then return true end
  return source:find(literal, 1, true) ~= nil
end
