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

-- Trim, then lowercase. WoW strings are UTF-8 and Lua's lower() only touches
-- ASCII, so non-Latin names compare case-sensitively here. That is acceptable
-- deliberately: this is used for character-name and mail-subject comparison,
-- and the server already case-normalises character names.
function Strings.Lower(value)
  return Strings.Trim(value):lower()
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
function Formatting.FormatMoneyIcons(copper, colorHex)
  local gold, silver, rest = Split(copper)

  local open, close = "", ""
  if type(colorHex) == "string" and colorHex ~= "" then
    open, close = "|c" .. colorHex, "|r"
  end

  if gold > 0 then
    return format("%s%d%s%s %s%d%s%s %s%d%s%s",
      open, gold, close, GOLD_ICON,
      open, silver, close, SILVER_ICON,
      open, rest, close, COPPER_ICON)
  end

  if silver > 0 then
    return format("%s%d%s%s %s%d%s%s",
      open, silver, close, SILVER_ICON,
      open, rest, close, COPPER_ICON)
  end

  return format("%s%d%s%s", open, rest, close, COPPER_ICON)
end
