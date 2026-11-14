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

-- Finding a folded query in text that was never folded: whether
-- Lower(text) holds `query` (itself folded), answered without making the
-- folded copy. A search walking a month of every character's History would
-- otherwise fold and keep a copy of every subject, sender and item name.
--
-- Strings.FoldPattern(query) -> a Lua pattern that matches, byte for byte,
-- every way the text can be written before folding: each letter as either
-- case ("[aA]", Latin-1 and Cyrillic by the same pairs as above), anything
-- else as itself. Every piece of it matches exactly one byte, so a match is
-- always #query bytes long. Two more answers: `cross`, true where a letter's
-- two cases begin with different bytes (most of Cyrillic's lower half: р is
-- D1 80, Р is D0 A0), which a byte class can only over-match, so each match
-- is then checked (Strings.FoldedAt); and `never`, true where the query holds
-- a letter folding always removes (an uppercase one), which no folded text
-- can hold. nil for a query that is not whole UTF-8, which the caller folds
-- the old way. The last query's answer is kept: one per keystroke.
do
  local byte, sub, find, concat = string.byte, string.sub, string.find, table.concat
  local parts = {}
  local last, lastPat, lastCross, lastNever

  function Strings.FoldPattern(query)
    if query == last then return lastPat, lastCross, lastNever end
    local i, n, k = 1, #query, 0
    local cross, never = false, false
    while i <= n do
      local b = byte(query, i)
      local size = (b < 128 and 1) or (b >= 240 and 4) or (b >= 224 and 3) or (b >= 194 and 2) or 0
      if b == 0 or size == 0 or i + size - 1 > n then return nil end
      for j = i + 1, i + size - 1 do
        local c = byte(query, j)
        if c < 128 or c > 191 then return nil end
      end
      local ch = sub(query, i, i + size - 1)
      local up = UPPER[ch]
      local piece
      if LOWER[ch] then
        never = true
        piece = ch
      elseif not up then
        piece = (size == 1 and not find(ch, "%w")) and ("%" .. ch) or ch
      elseif size == 1 then
        piece = "[" .. ch .. up .. "]"
      elseif byte(up, 1) == b then
        piece = sub(ch, 1, 1) .. "[" .. sub(ch, 2, 2) .. sub(up, 2, 2) .. "]"
      else
        cross = true
        piece = "[" .. sub(ch, 1, 1) .. sub(up, 1, 1) .. "][" .. sub(ch, 2, 2) .. sub(up, 2, 2) .. "]"
      end
      k = k + 1
      parts[k] = piece
      i = i + size
    end
    local pat = concat(parts, "", 1, k)
    for j = k, 1, -1 do parts[j] = nil end
    last, lastPat, lastCross, lastNever = query, pat, cross, never
    return pat, cross, never
  end

  -- text, at, query -> whether Lower(text) holds `query` at byte `at`,
  -- compared byte by byte as LowerBytes would fold them: A-Z, and the two
  -- lead bytes whose pairs it rewrites. Nothing is made.
  function Strings.FoldedAt(text, at, query)
    local j, n = 1, #query
    while j <= n do
      local q, t = byte(query, j), byte(text, at + j - 1)
      if not t then return false end
      local t2 = (t == 195 or t == 208) and byte(text, at + j) or nil
      if t2 and t2 >= 128 and t2 <= 191 then
        local f1, f2 = t, t2
        if t == 195 then
          if t2 <= 158 and t2 ~= 151 then f2 = t2 + 32 end
        elseif t2 >= 144 and t2 <= 159 then
          f2 = t2 + 32
        elseif t2 >= 160 and t2 <= 175 then
          f1, f2 = 209, t2 - 32
        elseif t2 <= 143 then
          f1, f2 = 209, t2 + 16
        end
        if f1 ~= q or f2 ~= byte(query, j + 1) then return false end
        j = j + 2
      else
        if t >= 65 and t <= 90 then t = t + 32 end
        if t ~= q then return false end
        j = j + 1
      end
    end
    return true
  end

  -- text, query, pattern, cross[, from[, to]] -> whether Lower of the text
  -- (or of its bytes from..to) holds the query, by FoldPattern's answer.
  function Strings.FoldFind(text, query, pat, cross, from, to)
    local init = from or 1
    while true do
      local s, e = find(text, pat, init)
      if not s or (to and e > to) then return false end
      if not cross or Strings.FoldedAt(text, s, query) then return true end
      init = s + 1
    end
  end
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

-- The coins, as inline textures: one set of the three escapes per height,
-- drop and gap (Formatting.CoinSet). What height and drop a string's coins
-- take is a rule of the font it is drawn in, and lives with the other rules
-- of that kind (Core/CollectTab.lua, RV.Coins); a caller that knows no font
-- gets the default set, 12 units with no drop.
local ICON_SIZE = 12
-- The units between a figure and its coin: the texture's own offset to the
-- right, as the game's money strings space theirs.
local COIN_GAP = 1
-- Published for anything that has to measure a money string without a set
-- in hand: the client's own measurement leaves inline textures out.
Formatting.MONEY_ICON_SIZE = ICON_SIZE
Formatting.COIN_GAP = COIN_GAP

-- The sets made, by key, and how many: a handful (one per font size and
-- face a surface draws money in), let go whole past COIN_SETS_MAX.
local coinSets, coinSetCount, COIN_SETS_MAX = {}, 0, 24

-- h, dy, gap -> the coins h units tall, `dy` units up from the line's centre
-- (negative: down) and `gap` units right of what comes before them: a table
-- of the escapes (gold, silver, copper) and the room each takes across (w),
-- which a string's measure leaves out. Made once per (h, dy, gap) and kept.
function Formatting.CoinSet(h, dy, gap)
  h = floor(tonumber(h) or ICON_SIZE)
  if h < 1 then h = 1 end
  dy, gap = floor(tonumber(dy) or 0), floor(tonumber(gap) or COIN_GAP)
  local key = (h * 1000 + dy + 500) * 100 + gap
  local set = coinSets[key]
  if set then return set end
  if coinSetCount >= COIN_SETS_MAX then
    for k in pairs(coinSets) do coinSets[k] = nil end
    coinSetCount = 0
  end
  set = {
    gold = format("|TInterface\\MoneyFrame\\UI-GoldIcon:%d:%d:%d:%d|t", h, h, gap, dy),
    silver = format("|TInterface\\MoneyFrame\\UI-SilverIcon:%d:%d:%d:%d|t", h, h, gap, dy),
    copper = format("|TInterface\\MoneyFrame\\UI-CopperIcon:%d:%d:%d:%d|t", h, h, gap, dy),
    w = h + gap, h = h, dy = dy, gap = gap,
  }
  coinSets[key] = set
  coinSetCount = coinSetCount + 1
  return set
end

-- The set for a caller that knows no font.
function Formatting.DefaultCoins()
  return Formatting.CoinSet(ICON_SIZE, 0, COIN_GAP)
end

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
-- The shortest honest reading of an amount, for a list row that has one
-- column for it: "1.2m", "123k", "12.3k", "1309g", "52g 26s", "3s 60c".
-- Above a thousand gold the silver is dropped, above ten thousand the
-- amount is in thousands; the reading view has the exact sum.
--
-- `brief` keeps the largest coin alone ("1g", "33s"): the compact row has one
-- narrow column for this and the silver on a gold sum is noise there.
--
-- On a Chinese client, which counts large numbers in ten thousands (万/萬) and
-- hundred millions (亿/億) rather than thousands and millions, the amounts from
-- ten thousand gold up are the client's own abbreviation of the gold,
-- AbbreviateNumbers with the client's locale, which groups them that way in
-- its characters; everything under ten thousand reads as above. Every other
-- client keeps the letters, exactly. Decided once at load (the locale is fixed
-- until the client restarts); a call is one C call, as the format it replaces
-- is.
local ABBREVIATE, ABBREVIATE_OPTIONS
do
  local locale = type(GetLocale) == "function" and GetLocale() or nil
  if (locale == "zhCN" or locale == "zhTW") and type(AbbreviateNumbers) == "function" then
    ABBREVIATE, ABBREVIATE_OPTIONS = AbbreviateNumbers, { locale = locale }
  end
end

-- The pieces in `g`, `s` and `c` after the figures: the letters, or the
-- coins (FormatMoneyCompactCoins), with no colour of their own. Where the
-- amount is abbreviated ("12.3k") the gold's piece follows it: nothing for
-- the letters, which the k and m already say, the gold coin for the coins.
local MoneyIn
local function CompactIn(copper, brief, g, s, c, after)
  local gold, _, _, total = Split(copper)
  if total == 0 then return "" end
  if ABBREVIATE and gold >= 10000 then
    if after then return ABBREVIATE(gold, ABBREVIATE_OPTIONS) .. after end
    return ABBREVIATE(gold, ABBREVIATE_OPTIONS)
  end
  -- Cut down to the digit shown, never rounded up, as the thousands are: a
  -- reading never says more than the mail holds (12,960g is "12.9k", and
  -- 99,950g stays "99.9k" rather than "100.0k").
  if gold >= 1000000 then return format("%.1fm%s", floor(gold / 100000) / 10, after or "") end
  if gold >= 100000 then return format("%dk%s", floor(gold / 1000), after or "") end
  if gold >= 10000 then return format("%.1fk%s", floor(gold / 100) / 10, after or "") end
  if gold >= 1000 then return format("%d%s", gold, g) end
  return MoneyIn(copper, brief and 1 or 2, g, s, c)
end

function Formatting.FormatMoneyCompact(copper, brief)
  return CompactIn(copper, brief, GOLD_SUFFIX, SILVER_SUFFIX, COPPER_SUFFIX, nil)
end

-- The same reading with the coins of `coins` (Formatting.CoinSet) in place
-- of the letters: "1373" and the gold coin, "52" gold "26" silver, "12.3k"
-- gold. No colour: the caller tints the whole, which leaves the coins as
-- they are.
function Formatting.FormatMoneyCompactCoins(copper, brief, coins)
  coins = coins or Formatting.DefaultCoins()
  return CompactIn(copper, brief, coins.gold, coins.silver, coins.copper, coins.gold)
end

-- copper -> a number that names the brief compact reading of the amount
-- (FormatMoneyCompact(copper, true), and the coins' reading of it): two
-- amounts with one key read the same, so whatever is made of a reading --
-- its text, its width -- can be kept by the key instead of by the amount.
-- A month of History holds a thousand distinct amounts and far fewer
-- readings: 1373g and 1373g 50s are both "1373g". The ranges follow
-- CompactIn above, and change with it: 0 for nothing, the gold up to ten
-- thousand, the silver and the copper alone, the abbreviations each in a
-- range of their own, and on a client that abbreviates its own way the
-- gold itself.
-- Split's arithmetic in place, the common case (some gold) first: a list's
-- walk asks it of every sum.
function Formatting.CompactKey(copper)
  local value = tonumber(copper) or 0
  if value < 1 then return 0 end
  value = floor(value)
  local gold = floor(value / COPPER_PER_GOLD)
  if gold > 0 and gold < 10000 then return gold end
  if gold > 0 then
    if ABBREVIATE then return 4e9 + gold end
    if gold >= 1000000 then return 3e9 + floor(gold / 100000) end
    if gold >= 100000 then return 2e9 + floor(gold / 1000) end
    return 1e9 + floor(gold / 100)
  end
  local silver = floor(value / COPPER_PER_SILVER)
  if silver > 0 then return 1e8 + silver end
  return 2e8 + value
end

-- Zero coins in the middle are skipped ("5g 35c"), and `parts` caps the
-- coins by rank from the largest non-zero one: 2 keeps gold and silver of
-- an amount with gold in it, silver and copper of one without. A list row
-- has no room for the copper on a sale, and nobody reads it there.
--
-- One format per amount and no tables: every money figure on every list
-- refresh comes through here, a month of History is a thousand of them, and
-- the pieces-and-join way made five tables a call.
MoneyIn = function(copper, parts, GOLD_SUFFIX, SILVER_SUFFIX, COPPER_SUFFIX)
  local gold, silver, rest, total = Split(copper)
  if total == 0 then return "" end

  -- How many coins, counted from the largest non-zero one, the cap leaves:
  -- a cap under one is no cap.
  local limit = tonumber(parts)
  if not (limit and limit >= 1) then limit = 3 end

  if gold > 0 then
    local withSilver = silver > 0 and limit >= 2
    local withCopper = rest > 0 and limit >= 3
    if withSilver and withCopper then
      return format("%d%s %d%s %d%s", gold, GOLD_SUFFIX, silver, SILVER_SUFFIX, rest, COPPER_SUFFIX)
    elseif withSilver then
      return format("%d%s %d%s", gold, GOLD_SUFFIX, silver, SILVER_SUFFIX)
    elseif withCopper then
      return format("%d%s %d%s", gold, GOLD_SUFFIX, rest, COPPER_SUFFIX)
    end
    return format("%d%s", gold, GOLD_SUFFIX)
  end
  if silver > 0 then
    if rest > 0 and limit >= 2 then
      return format("%d%s %d%s", silver, SILVER_SUFFIX, rest, COPPER_SUFFIX)
    end
    return format("%d%s", silver, SILVER_SUFFIX)
  end
  return format("%d%s", rest, COPPER_SUFFIX)
end

function Formatting.FormatMoneyText(copper, parts)
  return MoneyIn(copper, parts, GOLD_SUFFIX, SILVER_SUFFIX, COPPER_SUFFIX)
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
-- One format per amount, as FormatMoneyText: the banner asks for its two sums
-- on every list refresh, at up to four widths.
-- `coins`: the set to draw (Formatting.CoinSet; RV.Coins makes the one for
-- a string's font); the default set without it.
function Formatting.FormatMoneyIcons(copper, colorHex, parts, coins)
  local gold, silver, rest = Split(copper)
  coins = coins or Formatting.DefaultCoins()
  local GOLD_ICON, SILVER_ICON, COPPER_ICON = coins.gold, coins.silver, coins.copper

  local open, close = "", ""
  if type(colorHex) == "string" and colorHex ~= "" then
    open, close = "|c" .. colorHex, "|r"
  end

  -- How many of those coins stand: all of them, or no more than the cap, a
  -- fractional cap rounding up.
  local shown = (gold > 0 and 3) or (silver > 0 and 2) or 1
  local limit = tonumber(parts)
  if limit and limit >= 1 then shown = math.min(shown, math.ceil(limit)) end

  if gold > 0 then
    if shown >= 3 then
      return format("%s%d%s%s %s%d%s%s %s%d%s%s", open, gold, close, GOLD_ICON,
        open, silver, close, SILVER_ICON, open, rest, close, COPPER_ICON)
    elseif shown == 2 then
      return format("%s%d%s%s %s%d%s%s", open, gold, close, GOLD_ICON, open, silver, close, SILVER_ICON)
    end
    return format("%s%d%s%s", open, gold, close, GOLD_ICON)
  end
  if silver > 0 then
    if shown >= 2 then
      return format("%s%d%s%s %s%d%s%s", open, silver, close, SILVER_ICON, open, rest, close, COPPER_ICON)
    end
    return format("%s%d%s%s", open, silver, close, SILVER_ICON)
  end
  return format("%s%d%s%s", open, rest, close, COPPER_ICON)
end

-- An amount with the coins of `coins` (Formatting.CoinSet), every coin that
-- is not zero and only those: 482150g, 220112g 10s 35c, 5g 35c (MoneyIn's
-- rule, no cap). Nothing at all is one zero copper coin, as FormatMoneyIcons
-- writes it. Exact where FormatMoneyIcons' zeros are not wanted (the
-- options' 7-day tooltips' titles). One format per amount, no colour: the
-- caller tints the whole.
function Formatting.FormatMoneyIconsNonZero(copper, coins)
  coins = coins or Formatting.DefaultCoins()
  local text = MoneyIn(copper, 3, coins.gold, coins.silver, coins.copper)
  if text == "" then return format("%d%s", 0, coins.copper) end
  return text
end
