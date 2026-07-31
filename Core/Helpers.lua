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

-- copper -> compact plain text ("12g 30s"), "" for zero.
H.FormatMoney = ns.Core.Formatting.FormatMoneyText

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

-- subject, globalPattern -> boolean. Case-insensitive, plain matching, false
-- for an empty subject or a template that does not exist in this client build.
function H.SubjectLooksLike(subject, globalPattern)
  if type(globalPattern) ~= "string" then return false end
  local source = H.Lower(subject)
  if source == "" then return false end

  local literal = TemplateLiteral(globalPattern)
  if literal == "" then return false end
  if source == literal then return true end
  return source:find(literal, 1, true) ~= nil
end
