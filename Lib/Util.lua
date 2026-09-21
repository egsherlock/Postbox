-- Postbox foundation :: text normalisation and money formatting.
--
-- Publishes:
--   ns.Core.Strings.Trim / .Lower
--   ns.Core.Formatting.FormatMoneyText / .FormatMoneyIcons
--
-- Core/Helpers.lua captures these by reference at load time, so they must be
-- plain function fields present on the tables by the time it loads.

local _, ns = ...

ns.Core = ns.Core or {}
local Core = ns.Core
Core.Strings = Core.Strings or {}
Core.Formatting = Core.Formatting or {}

local Strings = Core.Strings
local Formatting = Core.Formatting

local floor = math.floor
local format = string.format

-------------------------------------------------------------
-- Strings
-------------------------------------------------------------

-- Every helper here returns exactly one value. A gsub chain returns
-- (string, count), and any such helper used as the last argument of a call
-- leaks the count into the argument list.

local strtrim = _G.strtrim

-- Coerces nil/non-string to "", strips leading and trailing whitespace, and
-- preserves interior whitespace. Callers pass EditBox:GetText() results, which
-- can be nil, so the coercion is load-bearing.
function Strings.Trim(value)
  if type(value) ~= "string" then
    if value == nil then return "" end
    value = tostring(value)
  end
  if strtrim then return strtrim(value) end
  return (value:match("^%s*(.-)%s*$"))
end

-------------------------------------------------------------
-- Case
--
-- Never string.lower or string.upper, on anything that can carry a name.
-- Those are the C library's tolower/toupper applied byte by byte, and the
-- client does not promise to run them in the "C" locale: on a runtime whose
-- locale is a single-byte Cyrillic or Latin code page they rewrite bytes
-- above 127 as well -- which in UTF-8 means rewriting the lead or a
-- continuation byte of a multi-byte letter into something that is no longer
-- valid UTF-8. A ruRU player reported exactly that shape: a favourited
-- Cyrillic name whose first letter drew as a box, and came out of the To:
-- box one letter short.
--
-- The mappings here are explicit and byte-exact, and touch only the letters
-- they know:
--
--   ASCII       A-Z / a-z
--   Latin-1     À..Þ <-> à..þ   (C3 80..9E <-> C3 A0..BE; × and ÷ are not letters)
--   Cyrillic    А..П <-> а..п   (D0 90..9F <-> D0 B0..BF)
--               Р..Я <-> р..я   (D0 A0..AF <-> D1 80..8F)
--               Ѐ..Џ <-> ѐ..џ   (D0 80..8F <-> D1 90..9F, the row that holds Ё)
--
-- Every pair is one byte to one byte or two bytes to two, so neither
-- function ever changes a string's byte length. That is also why a Russian
-- player typing a lowercase "ив" now finds Иван: the same fold serves the
-- keys the address book files people under.
-------------------------------------------------------------

local LOWER = {}   -- "A" -> "a", "И" -> "и"
local UPPER = {}   -- the reverse

local function Pair(upper, lower)
  LOWER[upper] = lower
  UPPER[lower] = upper
end

for b = 65, 90 do Pair(string.char(b), string.char(b + 32)) end
for b = 0x80, 0x9E do
  if b ~= 0x97 then Pair(string.char(0xC3, b), string.char(0xC3, b + 0x20)) end
end
for b = 0x90, 0x9F do Pair(string.char(0xD0, b), string.char(0xD0, b + 0x20)) end
for b = 0xA0, 0xAF do Pair(string.char(0xD0, b), string.char(0xD1, b - 0x20)) end
for b = 0x80, 0x8F do Pair(string.char(0xD0, b), string.char(0xD1, b + 0x10)) end

-- Character classes are BYTE ranges, deliberately: %a and %l are the locale's
-- opinion, [A-Z] is not.
local function LowerBytes(text)
  text = text:gsub("[A-Z]", LOWER)
  -- Only the two lead bytes that can start an uppercase letter; the lowercase
  -- rows under D1 never match and cost nothing.
  text = text:gsub("[\195\208][\128-\191]", LOWER)
  return text
end

local function UpperBytes(text)
  text = text:gsub("[a-z]", UPPER)
  text = text:gsub("[\195\208\209][\128-\191]", UPPER)
  return text
end

-- Trim, then lowercase. Used as the case-folding key generator for character
-- names and for mail-subject matching, so it must be total and stable.
function Strings.Lower(value)
  return LowerBytes(Strings.Trim(value))
end

-- Uppercase, same alphabet. Not trimmed: this is a fold for comparison, and
-- what it is given is what it answers for.
function Strings.Upper(value)
  if type(value) ~= "string" then value = tostring(value or "") end
  return UpperBytes(value)
end

-- First letter uppercased, the rest untouched -- the presentable form of a
-- name that was rebuilt from a lowercase key. A first character outside the
-- alphabets above is left exactly as it is.
function Strings.Capitalize(text)
  if type(text) ~= "string" or text == "" then return "" end
  local upper = UPPER[text:sub(1, 1)]
  if upper then return upper .. text:sub(2) end
  local lead = text:byte(1)
  if lead >= 0xC0 then
    upper = UPPER[text:sub(1, 2)]
    if upper then return upper .. text:sub(3) end
  end
  return text
end

-------------------------------------------------------------
-- Character boundaries
--
-- WoW strings are UTF-8 and Lua's # counts bytes. A name is cut, counted or
-- extended on CHARACTER boundaries or it is not cut at all: half a sequence
-- renders as a broken glyph.
-------------------------------------------------------------

-- How many bytes the character starting with this lead byte occupies.
local function CharSize(lead)
  if lead >= 240 then return 4 end
  if lead >= 224 then return 3 end
  if lead >= 192 then return 2 end
  return 1
end

function Strings.CharCount(text)
  local count, i, len = 0, 1, #text
  while i <= len do
    count = count + 1
    i = i + CharSize(text:byte(i))
  end
  return count
end

-- The byte index just past the first `count` characters -- so text:sub(1, at - 1)
-- is those characters and text:sub(at) is the rest -- or nil when the text has
-- fewer than `count` characters. Zero answers 1.
function Strings.CharBoundary(text, count)
  local i, len = 1, #text
  while count > 0 do
    if i > len then return nil end
    i = i + CharSize(text:byte(i))
    count = count - 1
  end
  return i
end

-------------------------------------------------------------
-- Money
-------------------------------------------------------------

local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD = 10000

-- Rendered inline at body-text size so the coins sit on the text baseline.
local ICON_SIZE = 12
local GOLD_ICON = format("|TInterface\\MoneyFrame\\UI-GoldIcon:%d:%d:0:0|t", ICON_SIZE, ICON_SIZE)
local SILVER_ICON = format("|TInterface\\MoneyFrame\\UI-SilverIcon:%d:%d:0:0|t", ICON_SIZE, ICON_SIZE)
local COPPER_ICON = format("|TInterface\\MoneyFrame\\UI-CopperIcon:%d:%d:0:0|t", ICON_SIZE, ICON_SIZE)

-- Floor, not round: a fractional value from a division must not carry 99.6
-- copper up into "100 copper, zero silver".
local function Split(copper)
  local value = tonumber(copper) or 0
  if value < 0 then value = 0 end
  value = floor(value)
  return floor(value / COPPER_PER_GOLD),
         floor((value % COPPER_PER_GOLD) / COPPER_PER_SILVER),
         value % COPPER_PER_SILVER,
         value
end

-- The client's own denomination suffixes, so money reads natively in every
-- locale (ruRU renders "з"/"с"/"м", not "g"/"s"/"c"). These are Blizzard
-- globals; the ASCII letters are the fallback for a client that somehow lacks
-- them, and are what the addon used to hardcode.
--
-- Read once at load: they are locale constants, and the client cannot change
-- locale without restarting.
local GOLD_SUFFIX   = _G.GOLD_AMOUNT_SYMBOL or "g"
local SILVER_SUFFIX = _G.SILVER_AMOUNT_SYMBOL or "s"
local COPPER_SUFFIX = _G.COPPER_AMOUNT_SYMBOL or "c"

-- Compact plain text: only the non-zero denominations, largest first, each
-- with its suffix. Zero yields the empty string (not "0c") — call sites rely
-- on that to omit a money row entirely.
--
-- Every consumer concatenates this into a flowing metadata line
-- (Core/CollectTab.lua's row detail, detail info line and C.O.D. confirmation),
-- so nothing depends on the result's width and nothing parses it back.
function Formatting.FormatMoneyText(copper)
  local gold, silver, rest, total = Split(copper)
  if total == 0 then return "" end

  if gold > 0 then
    if silver > 0 then
      if rest > 0 then
        return format("%d%s %d%s %d%s", gold, GOLD_SUFFIX, silver, SILVER_SUFFIX, rest, COPPER_SUFFIX)
      end
      return format("%d%s %d%s", gold, GOLD_SUFFIX, silver, SILVER_SUFFIX)
    end
    if rest > 0 then
      return format("%d%s %d%s", gold, GOLD_SUFFIX, rest, COPPER_SUFFIX)
    end
    return format("%d%s", gold, GOLD_SUFFIX)
  end

  if silver > 0 then
    if rest > 0 then
      return format("%d%s %d%s", silver, SILVER_SUFFIX, rest, COPPER_SUFFIX)
    end
    return format("%d%s", silver, SILVER_SUFFIX)
  end

  return format("%d%s", rest, COPPER_SUFFIX)
end

-- Amount rendered with the client's coin textures inline.
--
-- Gold appears only when non-zero; silver appears when gold or silver is
-- non-zero; copper always appears. Large amounts therefore align as
-- "5g 0s 3c" while small ones stay short.
--
-- `colorHex` is eight hex digits *with* alpha and no escape prefix (call sites
-- pass green/red literals for income and expenditure). It colours the digits
-- only — the coin icons stay unmodified. Absent, no colour escape is emitted.
-- `parts` caps how many coins are shown, counted from the largest that is
-- non-zero: 2 turns 1309g 62s 40c into 1309g 62s, and 1 into 1309g. A caller
-- short of room asks for fewer coins rather than letting the string run off
-- its edge. Without it every coin from the largest non-zero one down is shown.
function Formatting.FormatMoneyIcons(copper, colorHex, parts)
  local gold, silver, rest = Split(copper)

  local open, close = "", ""
  if type(colorHex) == "string" and colorHex ~= "" then
    open, close = "|c" .. colorHex, "|r"
  end

  local coins = {}
  local function Coin(value, icon)
    coins[#coins + 1] = format("%s%d%s%s", open, value, close, icon)
  end
  if gold > 0 then Coin(gold, GOLD_ICON) end
  if gold > 0 or silver > 0 then Coin(silver, SILVER_ICON) end
  Coin(rest, COPPER_ICON)

  local limit = tonumber(parts)
  if limit and limit >= 1 then
    for i = #coins, limit + 1, -1 do coins[i] = nil end
  end
  return table.concat(coins, " ")
end
