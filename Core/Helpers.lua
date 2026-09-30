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

-- copper -> compact plain text ("12g 30s"), "" for zero.
H.FormatMoney = ns.Core.Formatting.FormatMoneyText

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
