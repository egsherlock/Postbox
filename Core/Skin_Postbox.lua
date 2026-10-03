local _, ns = ...

-- =====================================================================
-- Postbox :: the "Postbox" window style (first-party skin, chosen in options)
-- ---------------------------------------------------------------------
-- The look every 1.50 mockup was drawn in, and the one Postbox wears under
-- EllesmereUI, made Postbox's own so it needs no EllesmereUI: near-black glass
-- the player sees through, a dark title strip, controls that each bring their
-- own near-opaque ground edged by one pixel, the open tab lit by a 2-pixel
-- accent line. The design and every value below are in
-- .dev/design/postbox-style/spec.md, section 1 (the right-hand column of its
-- difference table), and its options in section 3.
--
-- It is a SKIN, not a theme fork: it claims ns.Skin and rides the contract
-- the EllesmereUI and ElvUI skins ride (Apply / Refresh over tagged children),
-- so every window that knows how to be host-skinned wears it for free. It
-- replaced Postbox Modern, whose saved choice reads as this style
-- (MailboxUI.GetStyleChoice, and the settings carried over in MigrateModern).
--
-- A surface treatment only: it never moves a frame or changes a size, so the
-- arrange mode, the fits and the German widths carry over untouched.
--
-- WHAT IS FIXED, WHATEVER THE SETTINGS: only the accent carries meaning;
-- opacity drives the window's fill and its title strip and nothing else --
-- the list (0.85), plates (0.92-0.99), buttons (0.92), fields (1.0), the band
-- (0.92), tooltips (0.96) and the options panel (0.97) keep their own ground,
-- so a control stays legible at any opacity. The accent's text and marks go
-- through the Theme's contrast guard, so a dark accent is lightened where it
-- is painted (a light one darkened, in Light mode) and the colour picked
-- stays what is saved.
--
-- Every setting applies live, on change, and only then: the palette below is
-- rewritten in place and each window, control and tracked text painted
-- again. Nothing runs between changes.
--
-- Claimed once, at PLAYER_LOGIN, when the style choice is "postbox"; changing
-- the style asks for a /reload.
--
-- BUILT ON DEMAND. Everything from here to the claim at the end of the file
-- is one function's body, BuildSkin, run the first time the skin is asked for
-- (ns.GetPostboxSkin): at login when the Postbox style or a creative style is
-- the choice. Any other look never makes its palettes, tables and functions:
-- the Blizzard look and a host UI's look let go of the builder at login. The
-- body is not indented, so it reads as it always has.
-- =====================================================================

local function BuildSkin()

local Skin = {}
Skin.IsPostboxStyle = true
-- The creative window styles (Core/Skin_Creative.lua) are this skin with art
-- laid round it, and claim it in its place when one of them is chosen.
ns.PostboxSkin = Skin

local WHITE = "Interface\\AddOns\\Postbox\\Media\\white8x8.tga"
local FONT_DIR = "Interface\\AddOns\\Postbox\\Media\\Fonts\\"

local floor, max, min = math.floor, math.max, math.min

local Hex = ns.Theme.HexColor

local function Recolor(dest, src)
  dest[1], dest[2], dest[3], dest[4] = src[1], src[2], src[3], src[4] or 1
end

local function Copy(t)
  local out = {}
  for k, v in pairs(t) do
    if type(v) == "table" then out[k] = Copy(v) else out[k] = v end
  end
  return out
end

-------------------------------------------------------------
-- The palette
--
-- Every value this style paints with, by name, and nothing painted from a
-- literal. Two sets, DARK (the mockups' and EllesmereUI's in-game values)
-- and LIGHT (paper: a light sheet, white controls, dark ink); P is the one in
-- use, written in place from whichever the Mode setting names, then from the
-- player's surface, tint and border colour (ResolveLook). Painted blocks hold
-- P's own entries, so a repaint reads the new values with nothing re-made.
-------------------------------------------------------------

local DARK = {
  -- The window: the fill (its alpha is the opacity setting, 90% by default)
  -- and the title strip over its top, black at half strength, faded with it.
  window      = Hex("0a0b0b"),
  strip       = { 0, 0, 0, 0.50 },
  title       = { 1, 1, 1, 1 },
  -- The options panel and the other always-solid windows (Mail Memory, the
  -- groups window): their own fill, never following the opacity, and their
  -- cards.
  opaque      = Hex("0b0b0d", 0.97),
  optCard     = Hex("030404", 0.80),
  optCardEdge = Hex("3e3e3e"),
  -- The keyline round every window: black outside, a tone inside.
  keyOuter    = { 0, 0, 0, 1 },
  borderTone  = {
    black = { 0, 0, 0, 1 }, dark = Hex("2a2a2a"), gray = Hex("3a3a3a"), light = Hex("6a6a6a"),
  },
  -- Controls: each on its own ground.
  list        = Hex("0a0a0a", 0.85),
  listEdge    = Hex("333333"),
  field       = Hex("050505"),
  fieldEdge   = Hex("333333"),
  band        = Hex("141414", 0.92),
  bandEdge    = Hex("333333"),
  button      = Hex("141414", 0.92),
  buttonEdge  = Hex("333333"),
  hover       = { 1, 1, 1, 0.10 },
  select      = Hex("141414", 0.92),
  selectEdge  = Hex("404040"),
  caret       = Hex("8c8c8c"),
  check       = Hex("050505"),
  checkEdge   = Hex("404040"),
  close       = { 1, 1, 1, 0.75 },
  -- A faint light over the window's top (Sheen).
  sheen       = { 1, 1, 1, 0.05 },
}

local LIGHT = {
  window      = Hex("ebebe8"),
  strip       = { 0, 0, 0, 0.05 },
  title       = Hex("1a1a1a"),
  opaque      = Hex("efefec", 0.97),
  optCard     = Hex("fbfbf9", 0.85),
  optCardEdge = Hex("cdcdca"),
  keyOuter    = Hex("5a5a57"),
  borderTone  = {
    black = { 0, 0, 0, 1 }, dark = Hex("5a5a58"), gray = Hex("9a9a97"), light = Hex("d4d4d1"),
  },
  list        = Hex("fafaf8", 0.92),
  listEdge    = Hex("c9c9c6"),
  field       = Hex("ffffff"),
  fieldEdge   = Hex("bdbdba"),
  band        = Hex("efefec", 0.94),
  bandEdge    = Hex("c9c9c6"),
  button      = Hex("f4f4f1", 0.96),
  buttonEdge  = Hex("b8b8b5"),
  hover       = { 0, 0, 0, 0.06 },
  select      = Hex("f4f4f1", 0.96),
  selectEdge  = Hex("adadaa"),
  caret       = Hex("6a6a6a"),
  check       = Hex("ffffff"),
  checkEdge   = Hex("9a9a97"),
  close       = { 0.10, 0.10, 0.10, 0.75 },
  sheen       = { 1, 1, 1, 0.40 },
}

local P = Copy(DARK)
P.accent      = Hex("d3a44a")
P.opacity     = 0.90
P.stripHeight = 25
P.titleSize   = 15
P.checkBox    = 18
-- The keyline's inner line, as resolved: the default gray until the settings
-- are read (a creative style, which claims this skin in the Postbox style's
-- place, never reads them).
P.inner       = Copy(DARK.borderTone.gray)
P.tooltip     = Hex("080809", 0.96)
P.tooltipEdge = Hex("3a3a3a")
Skin.Palette = P
Skin.PaletteDark, Skin.PaletteLight = DARK, LIGHT

-- The segments, tiles and the options' tabs: Postbox's plates as in every
-- look, their ring from the mockups (concept C) -- solid greys rising with
-- state instead of a white at three alphas. The fills and the accent wash stay
-- the Theme's ladder (its light palette's, in Light mode).
local RINGS_DARK = {
  plateEdge         = Hex("3e3e3e"),
  plateEdgeHover    = Hex("555555"),
  plateEdgeSelected = Hex("6c6c6c"),
}
local RINGS_LIGHT = {
  plateEdge         = Hex("c9c9c6"),
  plateEdgeHover    = Hex("b4b4b1"),
  plateEdgeSelected = Hex("9d9d9a"),
}

-- The window tabs: the mockups' plates, which are EllesmereUI's in game --
-- dark idle, a lighter plate selected, a ring each, no bevel, no wash, the
-- 2-pixel accent underline -- and a dimmer idle caption than a segment's.
-- TAB_TOKENS is the table the tabs hold, rewritten in place from a set.
local TABS_DARK = {
  plateIdle         = { 18 / 255, 13 / 255, 11 / 255, 0.92 },
  plateHover        = { 30 / 255, 26 / 255, 24 / 255, 0.94 },
  plateSelected     = { 43 / 255, 39 / 255, 37 / 255, 0.95 },
  plateFlagged      = { 18 / 255, 13 / 255, 11 / 255, 0.92 },
  plateEdge         = Hex("3b3532"),
  plateEdgeHover    = Hex("444140"),
  plateEdgeSelected = Hex("4d4946"),
  plateBevel        = { 1, 1, 1, 0 },
  plateHighlight    = { 1, 1, 1, 0.03 },
  accentWash        = { 0, 0, 0, 0 },
}
local TABS_LIGHT = {
  plateIdle         = Hex("e6e6e3", 0.92),
  plateHover        = Hex("ecebe8", 0.94),
  plateSelected     = Hex("ffffff", 0.95),
  plateFlagged      = Hex("e6e6e3", 0.92),
  plateEdge         = Hex("c7c3bf"),
  plateEdgeHover    = Hex("b8b4b0"),
  plateEdgeSelected = Hex("a6a29e"),
  plateBevel        = { 1, 1, 1, 0 },
  plateHighlight    = { 0, 0, 0, 0.03 },
  accentWash        = { 0, 0, 0, 0 },
}
local TAB_TOKENS = Copy(TABS_DARK)
TAB_TOKENS.captionToken = "tabCaption"

-- Row stripes off: one even shade under every row.
local STRIPES_OFF_DARK = {
  stripeOdd = { 1, 1, 1, 0.06 }, stripeEven = { 1, 1, 1, 0.06 },
}
local STRIPES_OFF_LIGHT = {
  stripeOdd = { 0, 0, 0, 0.04 }, stripeEven = { 0, 0, 0, 0.04 },
}

local function Accent()
  if ns.Theme and ns.Theme.GetAccent then return ns.Theme.GetAccent() end
  return P.accent[1], P.accent[2], P.accent[3]
end

-- The accent as a mark (a tick, the accent border): the Theme's mark tone,
-- 3:1 on the selected plate.
local function AccentMark()
  if ns.Theme and ns.Theme.GetAccentTone then return ns.Theme.GetAccentTone("mark") end
  return Accent()
end

-- The accent the player picked, as picked: the Theme's guard makes the tones
-- it paints with from this.
function Skin.GetAccent()
  return P.accent[1], P.accent[2], P.accent[3]
end

-- The ground a popup's floor is laid in (Theme's popup opacity floor).
function Skin.GetHostBaseline()
  return P.window[1], P.window[2], P.window[3]
end

-- One UI unit at this frame's scale, snapped to whole physical pixels (at
-- least one): at a UI scale that is not a whole ratio of the screen, a "1"
-- edge lands on a fraction of a pixel and each side rounds on its own, so one
-- border renders 1 px on one side and 2 on the other. Snapped, every edge is
-- the same weight. It follows the UI scale on purpose, as text does: 1 px at a
-- pixel-perfect scale, 2 or 3 px on a high-DPI screen at scale 1.0, where a
-- single pixel would all but vanish. (The EllesmereUI skin's Match edge is the
-- one line that is always exactly one pixel, because the windows it matches
-- draw theirs that way.)
local function Hairline(frame)
  local scale = (frame and frame.GetEffectiveScale and frame:GetEffectiveScale()) or 1
  if PixelUtil and PixelUtil.GetNearestPixelSize then
    local ok, size = pcall(PixelUtil.GetNearestPixelSize, 1, scale, 1)
    if ok and type(size) == "number" and size > 0 then return size end
  end
  if scale > 0 then return max(1, floor(scale + 0.5)) / scale end
  return 1
end

-- No defaults table: an empty one merged nothing, and was made per read.
local function GetProfile()
  return ns.Store.EnsurePath("profile")
end

-- A creative window style (Core/Skin_Creative.lua) wears this skin with its
-- own art, palette values and accent round it. The colours below are the
-- Postbox style's own: under a creative style each reads as its default --
-- Dark, the style's accent, no tint, square corners, no sheen, gold
-- captions -- whatever is saved, and the saved choice waits for the Postbox
-- style. Text outline and row stripes apply to both, as font and size do.
local function Creative()
  return Skin.IsCreativeStyle and true or false
end

-- The creative style's own palette values, by name, which the Postbox
-- style's sets never write over.
local function CreativePalette()
  if not Creative() then return nil end
  local CS = ns.CreativeStyles
  local def = CS and type(CS.Active) == "function" and CS.Active() or nil
  return def and def.palette or nil, def and def.plates or nil
end

-------------------------------------------------------------
-- Appearance settings
--
-- The contract Core/OptionsPanel.lua builds its rows from, as the other skins
-- publish it: a border and an opacity, then this style's own. Every accessor
-- reads nil as the default, so Reset to defaults (which clears the profile)
-- needs nothing here but the repaint. Saved under profile: pbBorder,
-- pbBorderTone, pbBorderHex, pbOpacity, pbFont, pbTextScale, pbMode,
-- pbAccent, pbAccentHex, pbSurface and pbSurfaceHex (Dark's background),
-- pbSurfaceLight and pbSurfaceLightHex (Light's), pbOutline, pbCorners,
-- pbSheen; and rowStripes, a boolean option (MailboxUI OPTION_DEFAULTS).
-- Read and never written: pbTint, the Tint a background colour now carries
-- (GetSurfaceKey). Ignored: pbButtonText, from when a button's caption had
-- a colour of its own choosing; it is worked out from the button now.
-------------------------------------------------------------

-- Edge: the inner line alone, one pixel on the window's outer edge, as the
-- windows of a pixel-perfect UI draw theirs.
local BORDER_ORDER = { "none", "edge", "thin", "thick" }
local BORDER_NAME_KEY = { none = "OPT_BORDER_NONE", edge = "OPT_BORDER_EDGE", thin = "OPT_BORDER_THIN", thick = "OPT_BORDER_THICK" }
local DEFAULT_BORDER = "thin"
local DEFAULT_TONE = "gray"

-- A saved "rrggbb" -> r, g, b, or nil.
local function FromHex(h)
  if type(h) ~= "string" or not h:match("^%x%x%x%x%x%x$") then return nil end
  return tonumber((h:sub(1, 2)), 16) / 255, tonumber((h:sub(3, 4)), 16) / 255, tonumber((h:sub(5, 6)), 16) / 255
end

local function ToHex(r, g, b)
  local function byte(v) return floor(max(0, min(1, v)) * 255 + 0.5) end
  return string.format("%02x%02x%02x", byte(r), byte(g), byte(b))
end

-- One choice list, from a spec table: key -> locale key, in order.
local function Choices(order, names)
  local out = {}
  for i = 1, #order do
    local key = order[i]
    out[i] = { key = key, name = ns.L[names[key]] }
  end
  return out
end

-- The player's class colour: the shared table class colour addons publish
-- first, the client's otherwise. Asked each time (a handful of lookups, on a
-- settings change only).
local function ClassRGB()
  local token
  if type(UnitClass) == "function" then
    local _, t = UnitClass("player")
    token = t
  end
  if type(token) ~= "string" then return nil end
  local custom = _G.CUSTOM_CLASS_COLORS
  local c = type(custom) == "table" and custom[token] or nil
  if not c and C_ClassColor and type(C_ClassColor.GetClassColor) == "function" then
    local ok, v = pcall(C_ClassColor.GetClassColor, token)
    if ok then c = v end
  end
  if not c and type(RAID_CLASS_COLORS) == "table" then c = RAID_CLASS_COLORS[token] end
  if type(c) == "table" and type(c.r) == "number" then return c.r, c.g, c.b end
  return nil
end

-- Border -----------------------------------------------------------------

function Skin.GetBorderChoices()
  return Choices(BORDER_ORDER, BORDER_NAME_KEY)
end

-- No "Default" entry in the border list: the default is Thin, and the list
-- names it.
function Skin.OffersBorderDefault() return false end

function Skin.GetBorderStyle()
  local saved = GetProfile().pbBorder
  if BORDER_NAME_KEY[saved] then return saved end
  return DEFAULT_BORDER
end

function Skin.IsBorderDefault()
  return GetProfile().pbBorder == nil
end

function Skin.SetBorderStyle(key)
  if not BORDER_NAME_KEY[key] then return end
  GetProfile().pbBorder = (key ~= DEFAULT_BORDER) and key or nil
  Skin.ApplyAppearance()
end

function Skin.ResetBorder()
  GetProfile().pbBorder = nil
  Skin.ApplyAppearance()
end

-- The inner line's colour: the greys (Black, Dark gray, Gray -- the default --
-- Light gray), the accent, or a colour of the player's own. The greys are
-- each palette's own (a light window's gray is lighter).
local TONE_ORDER = { "black", "dark", "gray", "light", "accent", "custom" }
local TONE_NAME_KEY = {
  black = "OPT_TONE_BLACK", dark = "OPT_TONE_DARK", gray = "OPT_TONE_GRAY", light = "OPT_TONE_LIGHT",
  accent = "OPT_COLOR_ACCENT", custom = "OPT_COLOR_CUSTOM",
}

function Skin.GetBorderToneChoices()
  local out = Choices(TONE_ORDER, TONE_NAME_KEY)
  for i = 1, #out do
    local tone = P.borderTone[out[i].key]
    if tone then out[i].swatch = tone end
  end
  return out
end

function Skin.GetBorderTone()
  if Creative() then return DEFAULT_TONE end
  local saved = GetProfile().pbBorderTone
  if saved == "accent" then return saved end
  if saved == "custom" and FromHex(GetProfile().pbBorderHex) then return saved end
  if DARK.borderTone[saved] then return saved end
  return DEFAULT_TONE
end

function Skin.SetBorderTone(key)
  if not TONE_NAME_KEY[key] then return end
  GetProfile().pbBorderTone = (key ~= DEFAULT_TONE) and key or nil
  Skin.ApplyAppearance()
end

-- Opacity ----------------------------------------------------------------

-- In Light mode never below 85%: dark ink over a see-through light sheet
-- turns unreadable over a bright or busy world. The saved value is kept, and
-- Dark mode uses it again.
local LIGHT_OPACITY_FLOOR = 0.85
Skin.LIGHT_OPACITY_FLOOR = LIGHT_OPACITY_FLOOR

function Skin.GetBgOpacity()
  local saved = tonumber((GetProfile().pbOpacity))
  local value = saved and max(0, min(1, saved)) or P.opacity
  if Skin.GetMode() == "light" then value = max(LIGHT_OPACITY_FLOOR, value) end
  return value
end

function Skin.IsBgOpacityDefault()
  return GetProfile().pbOpacity == nil
end

function Skin.SetBgOpacity(value)
  GetProfile().pbOpacity = max(0, min(1, tonumber(value) or 1))
  Skin.ApplyAppearance()
end

function Skin.ResetBgOpacity()
  GetProfile().pbOpacity = nil
  Skin.ApplyAppearance()
end

-- Mode -------------------------------------------------------------------

-- Dark (the look), or Light: Postbox's own; it never follows a host UI.
local MODE_ORDER = { "dark", "light" }
local MODE_NAME_KEY = { dark = "OPT_MODE_DARK", light = "OPT_MODE_LIGHT" }

function Skin.GetModeChoices() return Choices(MODE_ORDER, MODE_NAME_KEY) end

function Skin.GetMode()
  if Creative() then return "dark" end
  return (GetProfile().pbMode == "light") and "light" or "dark"
end

function Skin.SetMode(key)
  if not MODE_NAME_KEY[key] then return end
  GetProfile().pbMode = (key == "light") and "light" or nil
  Skin.ApplyLook(true)
end

-- Accent -----------------------------------------------------------------

local ACCENT_ORDER = { "gold", "eui", "white", "elvui", "ice", "violet", "pink", "class", "custom" }
local ACCENT_HEX = {
  gold = "d3a44a", eui = "0cd29d", white = "f2f2f2", elvui = "1785d1",
  ice = "86d6ff", violet = "a77bff", pink = "ff7ac8",
}
local ACCENT_NAME_KEY = {
  gold = "OPT_ACCENT_GOLD", eui = "OPT_ACCENT_EUI", white = "OPT_ACCENT_WHITE", elvui = "OPT_ACCENT_ELVUI",
  ice = "OPT_ACCENT_ICE", violet = "OPT_ACCENT_VIOLET", pink = "OPT_ACCENT_PINK",
  class = "OPT_COLOR_CLASS", custom = "OPT_COLOR_CUSTOM",
}
local DEFAULT_ACCENT = "gold"

function Skin.GetAccentKey()
  if Creative() then return DEFAULT_ACCENT end
  local profile = GetProfile()
  local saved = profile.pbAccent
  if saved == "custom" and FromHex(profile.pbAccentHex) then return saved end
  if saved == "class" and ClassRGB() then return saved end
  if ACCENT_HEX[saved] then return saved end
  return DEFAULT_ACCENT
end

-- The picked accent for a key, as picked.
local function AccentFor(key)
  if key == "custom" then
    local r, g, b = FromHex(GetProfile().pbAccentHex)
    if r then return r, g, b end
  elseif key == "class" then
    local r, g, b = ClassRGB()
    if r then return r, g, b end
  end
  return FromHex(ACCENT_HEX[key] or ACCENT_HEX[DEFAULT_ACCENT])
end

function Skin.GetAccentChoices()
  local out = Choices(ACCENT_ORDER, ACCENT_NAME_KEY)
  local kept = {}
  for i = 1, #out do
    local item = out[i]
    if item.key == "class" and not ClassRGB() then
      -- no class colour on this client: not offered
    else
      if item.key ~= "custom" then
        local r, g, b = AccentFor(item.key)
        item.swatch = { r, g, b, 1 }
      end
      kept[#kept + 1] = item
    end
  end
  return kept
end

function Skin.SetAccent(key, hex)
  if not ACCENT_NAME_KEY[key] then return end
  local profile = GetProfile()
  if key == "custom" then
    if not FromHex(hex) then return end
    profile.pbAccentHex = hex
  end
  profile.pbAccent = (key ~= DEFAULT_ACCENT) and key or nil
  Skin.ApplyLook(false)
end

-- Background color ---------------------------------------------------------

-- The window's colour, a list for each Mode, and a pick for each, so a flip
-- of the Mode and back loses neither: Dark's near-blacks, each held by the
-- dark rule (spec 3.3, rule 5: no lighter than #1c1c1c and nearly neutral,
-- so every grey and text colour keeps its contrast; Slate and Umber are
-- written as their unclamped hues and land where the rule puts them), and
-- Light's papers, inside the light rule (no darker than #e2e2df) as written,
-- Paper first and the Light set's own sheet. Then, in both, Accent tint and
-- Class tint -- the Mode's first colour with a whisper of the accent's or
-- the class colour's hue, which also tints the title strip -- and a colour
-- of the player's own, held by the Mode's rule. Light's starts on Paper the
-- first time it is chosen; nothing Dark keeps is touched by it.
local SURFACES = {
  dark = {
    order = { "charcoal", "black", "graphite", "midnight", "slate", "umber", "accent", "class", "custom" },
    hex = { charcoal = "0a0b0b", black = "000000", graphite = "17181a", midnight = "0e0e11",
            slate = "1b2230", umber = "2a1c12" },
    default = "charcoal", key = "pbSurface", hexKey = "pbSurfaceHex",
  },
  light = {
    order = { "paper", "white", "ivory", "linen", "mist", "sage", "blush", "accent", "class", "custom" },
    hex = { paper = "ebebe8", white = "f7f7f5", ivory = "f3efe4", linen = "efe8dc", mist = "e8ebee",
            sage = "e6eae2", blush = "f1e9e7" },
    default = "paper", key = "pbSurfaceLight", hexKey = "pbSurfaceLightHex",
    light = true,
  },
}
local SURFACE_NAME_KEY = {
  charcoal = "OPT_SURFACE_CHARCOAL", black = "OPT_SURFACE_BLACK", graphite = "OPT_SURFACE_GRAPHITE",
  midnight = "OPT_SURFACE_MIDNIGHT", slate = "OPT_SURFACE_SLATE", umber = "OPT_SURFACE_UMBER",
  paper = "OPT_SURFACE_PAPER", white = "OPT_SURFACE_WHITE", ivory = "OPT_SURFACE_IVORY",
  linen = "OPT_SURFACE_LINEN", mist = "OPT_SURFACE_MIST", sage = "OPT_SURFACE_SAGE", blush = "OPT_SURFACE_BLUSH",
  accent = "OPT_SURFACE_ACCENT_TINT", class = "OPT_SURFACE_CLASS_TINT", custom = "OPT_COLOR_CUSTOM",
}
local DEFAULT_SURFACE = "charcoal"

-- A Mode's list ("dark" | "light"), the Mode in force by default.
local function SurfaceSet(mode)
  return SURFACES[mode or Skin.GetMode()] or SURFACES.dark
end

-- The pick for `mode` (the Mode in force by default). Unset, the retired
-- Tint is read once more as the pick it now is (Accent tint, Class tint),
-- and the Mode's first colour otherwise.
function Skin.GetSurfaceKey(mode)
  if Creative() then return DEFAULT_SURFACE end
  local S = SurfaceSet(mode)
  local profile = GetProfile()
  local saved = profile[S.key]
  if saved == nil then saved = profile.pbTint end
  if saved == "custom" and FromHex(profile[S.hexKey]) then return saved end
  if saved == "class" and ClassRGB() then return saved end
  if saved == "accent" or S.hex[saved] then return saved end
  return S.default
end

-- The colour for a key of `mode`'s list, held by its rule; and whether it is
-- a tint (which also tints the strip).
local function SurfaceFor(key, mode)
  local S = SurfaceSet(mode)
  local light = S.light and true or false
  local T = ns.Theme
  local r, g, b
  if key == "accent" or key == "class" then
    r, g, b = FromHex(S.hex[S.default])
    local hr, hg, hb
    if key == "accent" then hr, hg, hb = Accent() else hr, hg, hb = ClassRGB() end
    if hr and T and T.TintSurface then
      r, g, b = T.TintSurface(r, g, b, hr, hg, hb, light)
      return r, g, b, true
    end
    return r, g, b, false
  end
  if key == "custom" then r, g, b = FromHex(GetProfile()[S.hexKey]) end
  if not r then r, g, b = FromHex(S.hex[key] or S.hex[S.default]) end
  if T and T.ClampSurface then r, g, b = T.ClampSurface(r, g, b, light) end
  return r, g, b, false
end

-- The Mode in force's list, each colour's square as it paints: a tint
-- reads the accent and the class colour live. Class tint stays out where
-- the client has no class colour.
function Skin.GetSurfaceChoices(mode)
  local S = SurfaceSet(mode)
  local out = Choices(S.order, SURFACE_NAME_KEY)
  local kept = {}
  for i = 1, #out do
    local item = out[i]
    if not (item.key == "class" and not ClassRGB()) then
      if item.key ~= "custom" then
        local r, g, b = SurfaceFor(item.key, mode)
        item.swatch = { r, g, b, 1 }
      end
      kept[#kept + 1] = item
    end
  end
  return kept
end

-- The colour a key of `mode`'s list paints (the Mode in force's by
-- default), or nil for a key it does not have: the options' squares.
function Skin.SurfaceColor(key, mode)
  if key == "custom" then return Skin.GetCustomColor("surface") end
  local S = SurfaceSet(mode)
  if key ~= "accent" and key ~= "class" and not S.hex[key] then return nil end
  local r, g, b = SurfaceFor(key, mode)
  return r, g, b
end

-- A pick for the Mode in force; the other Mode's stays as it is. The
-- retired Tint is let go the first time: the Mode not being set keeps what
-- it read as (GetSurfaceKey), written as its own pick.
function Skin.SetSurface(key, hex)
  if not SURFACE_NAME_KEY[key] then return end
  local mode = Skin.GetMode()
  local S = SurfaceSet(mode)
  if key ~= "accent" and key ~= "class" and key ~= "custom" and not S.hex[key] then return end
  local profile = GetProfile()
  if key == "custom" then
    if not FromHex(hex) then return end
    profile[S.hexKey] = hex
  end
  if profile.pbTint ~= nil then
    local other = (mode == "light") and "dark" or "light"
    local O = SurfaceSet(other)
    if profile[O.key] == nil then
      local kept = Skin.GetSurfaceKey(other)
      profile[O.key] = (kept ~= O.default) and kept or nil
    end
    profile.pbTint = nil
  end
  profile[S.key] = (key ~= S.default) and key or nil
  Skin.ApplyLook(false)
end

-- Row stripes --------------------------------------------------------------

function Skin.GetRowStripes()
  local UI = ns.MailboxUI
  if UI and type(UI.GetOption) == "function" then return UI.GetOption("rowStripes") and true or false end
  return true
end

function Skin.SetRowStripes(on)
  local UI = ns.MailboxUI
  if UI and type(UI.SetOption) == "function" then UI.SetOption("rowStripes", on and true or false) end
  Skin.ApplyLook(true)
end

-- Corners and sheen --------------------------------------------------------

local CORNER_ORDER = { "square", "rounded" }
local CORNER_NAME_KEY = { square = "OPT_CORNERS_SQUARE", rounded = "OPT_CORNERS_ROUNDED" }

function Skin.GetCornerChoices() return Choices(CORNER_ORDER, CORNER_NAME_KEY) end

function Skin.GetCorners()
  if Creative() then return "square" end
  return (GetProfile().pbCorners == "rounded") and "rounded" or "square"
end

function Skin.SetCorners(key)
  if not CORNER_NAME_KEY[key] then return end
  GetProfile().pbCorners = (key == "rounded") and "rounded" or nil
  Skin.ApplyAppearance()
end

function Skin.GetSheen()
  if Creative() then return false end
  return GetProfile().pbSheen == true
end

function Skin.SetSheen(on)
  GetProfile().pbSheen = on and true or nil
  Skin.ApplyAppearance()
end

-------------------------------------------------------------
-- Resolving the look
--
-- P from the settings: the Mode's set, the background colour (held by its
-- Mode's rule, a tint mixed into the fill and the strip), the keyline's
-- inner colour; then the Theme's palette -- Mode's, with this style's plate
-- rings, the row stripes and the sheet accent text is read on -- which also
-- makes the accent's tones again; then the grounds every text is read on
-- (Skin._Grounds), from which the Theme works out each ink. A few dozen
-- colour sums and a bisection per ink that moved; only on a settings change.
-------------------------------------------------------------

-- The grounds (Theme section 2c): what each surface text stands on shows at
-- its darkest and its lightest, worked out from the colours and alphas this
-- style paints it in, laid over what is under it -- the window at the
-- opacity in force (Light's floor included), over a black world and a white
-- one; a creative style's art over its tile's grain (def.grain), darkest
-- over black, lightest over white. Every number is P's, the palette's or
-- the style's; nothing is guessed. A few dozen sums, written in place.
do
  local W, S, ST = {}, {}, {}
  local R, R2 = {}, {}
  local HINT = { 0.05, 0.05, 0.06, 0.82 }
  local ACC = { 1, 1, 1 }

  -- c at alpha a over the range `under` (6 numbers), into `dest`.
  local function Over(dest, c, a, under)
    for e = 0, 3, 3 do
      dest[e + 1] = c[1] * a + under[e + 1] * (1 - a)
      dest[e + 2] = c[2] * a + under[e + 2] * (1 - a)
      dest[e + 3] = c[3] * a + under[e + 3] * (1 - a)
    end
    return dest
  end

  -- c at alpha a over the world itself.
  local WORLD = { 0, 0, 0, 1, 1, 1 }

  local function Set(name, t)
    ns.Theme.SetGroundRange(name, t[1], t[2], t[3], t[4], t[5], t[6])
  end

  -- dest widened to take in t too: its darker darkest, its lighter lightest.
  local function Widen(dest, t)
    local L = ns.Theme.Luminance
    if L(t[1], t[2], t[3]) < L(dest[1], dest[2], dest[3]) then dest[1], dest[2], dest[3] = t[1], t[2], t[3] end
    if L(t[4], t[5], t[6]) > L(dest[4], dest[5], dest[6]) then dest[4], dest[5], dest[6] = t[4], t[5], t[6] end
  end

  -- The window's fill as it shows at alpha a, into dest: the style's art
  -- where a creative style lays one (its tint times the tile's grain), its
  -- colour otherwise.
  local function Fill(dest, color, a)
    local CS = Creative() and ns.CreativeStyles
    local def = CS and type(CS.Active) == "function" and CS.Active() or nil
    local tint = def and def.ground and def.colors and def.colors[def.ground.tint]
    if tint and def.grain then
      local lo, hi = def.grain[1], def.grain[2]
      for i = 1, 3 do
        dest[i] = tint[i] * lo * a
        dest[i + 3] = min(1, tint[i] * hi) * a + (1 - a)
      end
    else
      for i = 1, 3 do
        dest[i] = color[i] * a
        dest[i + 3] = color[i] * a + (1 - a)
      end
    end
    return dest
  end

  -- "window", "solid" and "strip": the main window at the player's
  -- opacity, the always-solid windows at theirs, the title strip over the
  -- window (a creative style's title band, where it lays one). -> the
  -- window's range, its darkest first.
  function Skin._WindowGrounds()
    local T = ns.Theme
    if not (T and T.SetGroundRange) then return W end
    local o = Skin.GetBgOpacity()
    Fill(W, P.window, o)
    Fill(S, P.opaque, P.opaque[4] or 0.97)
    Set("window", W)
    Set("solid", S)
    local band
    if Creative() then
      local CS = ns.CreativeStyles
      local def = CS and type(CS.Active) == "function" and CS.Active() or nil
      band = def and def.titleBand
      if band then Over(ST, band, (band[4] or 1) * o, W) else Over(ST, P.strip, 0, W) end
    else
      Over(ST, P.strip, (P.strip[4] or 0) * o, W)
    end
    Set("strip", ST)
    return W
  end

  -- The controls and lists over the window, the cards over the solid
  -- windows, the plates in the palette's own (a creative style's), the
  -- tooltip and the hint card over the world, and a style's own grounds
  -- (def.grounds: the post box's enamel). -> whether any ground moved.
  function Skin._ControlGrounds()
    local T = ns.Theme
    if not (T and T.SetGroundRange and T.Colors) then return false end
    local C = T.Colors
    -- A list under its rows' stripes: the even stripe is under every other
    -- row, all the time.
    Over(R, P.list, P.list[4] or 1, W)
    Widen(R, Over(R2, C.stripeEven, C.stripeEven[4] or 0, R))
    Set("list", R)
    Set("band", Over(R, P.band, P.band[4] or 1, W))
    Set("button", Over(R, P.button, P.button[4] or 1, W))
    Set("select", Over(R, P.select, P.select[4] or 1, W))
    Set("field", Over(R, P.field, P.field[4] or 1, W))
    Set("card", Over(R, P.optCard, P.optCard[4] or 1, S))
    -- A plate at rest and pointed at.
    Over(R, C.plateIdle, C.plateIdle[4] or 1, W)
    Widen(R, Over(R2, C.plateHover, C.plateHover[4] or 1, W))
    Set("plate", R)
    -- The selected plate under its wash of the accent.
    Over(R, C.plateSelected, C.plateSelected[4] or 1, W)
    local ar, ag, ab = Accent()
    ACC[1], ACC[2], ACC[3] = ar, ag, ab
    Set("plateSelected", Over(R, ACC, C.accentWash[4] or 0, R))
    -- The window tabs, in their own tokens (a creative style's).
    local CS = Creative() and ns.CreativeStyles
    local def = CS and type(CS.Active) == "function" and CS.Active() or nil
    local tabs = (def and def.tabs) or TAB_TOKENS
    Over(R, tabs.plateIdle, tabs.plateIdle[4] or 1, W)
    Widen(R, Over(R2, tabs.plateHover, tabs.plateHover[4] or 1, W))
    Set("tab", R)
    Over(R, tabs.plateSelected, tabs.plateSelected[4] or 1, W)
    Set("tabSelected", Over(R, ACC, (tabs.accentWash and tabs.accentWash[4]) or 0, R))
    Set("tooltip", Over(R, P.tooltip, P.tooltip[4] or 1, WORLD))
    Set("hint", Over(R, HINT, HINT[4], WORLD))
    if def and def.grounds then
      for name, range in pairs(def.grounds) do
        local lo, hi = range[1], range[2]
        T.SetGroundRange(name, lo[1], lo[2], lo[3], hi[1], hi[2], hi[3])
      end
    end
    return T.GroundsChanged()
  end
end

local sheetExtra = { sheet = { 0, 0, 0, 0 } }

local function ResolveLook()
  local T = ns.Theme
  local light = Skin.GetMode() == "light"
  local src = light and LIGHT or DARK
  local over, overPlates = CreativePalette()
  for key, value in pairs(src) do
    if over and over[key] ~= nil then
      -- the creative style's own value stays
    elseif key == "borderTone" then
      for tone, color in pairs(value) do Recolor(P.borderTone[tone], color) end
    else
      Recolor(P[key], value)
    end
  end
  local tabs = light and TABS_LIGHT or TABS_DARK
  for key, value in pairs(tabs) do Recolor(TAB_TOKENS[key], value) end
  if not (over and over.accent) then
    local ar, ag, ab = AccentFor(Skin.GetAccentKey())
    P.accent[1], P.accent[2], P.accent[3] = ar, ag, ab
  end

  -- The fill: the Mode's background colour (a tint is one), or a creative
  -- style's own sheet, which the copy above kept.
  local r, g, b, tinted
  local surface = Skin.GetSurfaceKey()
  if over and over.window then
    r, g, b, tinted = P.window[1], P.window[2], P.window[3], false
  else
    r, g, b, tinted = SurfaceFor(surface, light and "light" or "dark")
  end
  P.window[1], P.window[2], P.window[3] = r, g, b
  -- The always-solid windows wear the same colour, but for the default
  -- charcoal, whose own solid fill (#0b0b0d) is the one they always had.
  if light or tinted or surface ~= DEFAULT_SURFACE then
    P.opaque[1], P.opaque[2], P.opaque[3] = r, g, b
  end
  -- The strip: black at half strength in Dark mode, a shadow of the sheet in
  -- Light; under a tint, the tinted fill darkened, so it carries the hue.
  if tinted and T and T.ToLab and T.AtLightness then
    local L, a, bb = T.ToLab(r, g, b)
    P.strip[1], P.strip[2], P.strip[3] = T.AtLightness(a, bb, light and (L - 0.10) or (L * 0.5))
    if light then P.strip[4] = 0.35 end
  end

  -- The keyline's inner line.
  local tone = Skin.GetBorderTone()
  if tone == "custom" then
    local cr, cg, cb = FromHex(GetProfile().pbBorderHex)
    P.inner[1], P.inner[2], P.inner[3], P.inner[4] = cr, cg, cb, 1
  elseif tone ~= "accent" then
    Recolor(P.inner, P.borderTone[tone] or P.borderTone.gray)
  end

  -- The window as it shows (its fill or art at its opacity, over a black
  -- world and a white one): the first of the grounds, and the sheet.
  local W = Skin._WindowGrounds()

  if T and T.ApplyPalette then
    local stripes = Skin.GetRowStripes()
    -- A creative style's plates in place of this style's rings, as its claim
    -- laid them.
    local extra = overPlates or (light and RINGS_LIGHT or RINGS_DARK)
    -- The sheet accent text and inked colours are read on, on a light
    -- palette: the window at its darkest -- its opacity floor over a dark
    -- scene -- not as if it were solid, which it is only at 100.
    local s = sheetExtra.sheet
    if light then
      s[1], s[2], s[3], s[4] = W[1], W[2], W[3], 1
    else
      s[1], s[2], s[3], s[4] = 0, 0, 0, 0
    end
    local off = (not stripes) and (light and STRIPES_OFF_LIGHT or STRIPES_OFF_DARK) or nil
    -- The stripes and the sheet go in one map, the rings in the other.
    local map2 = sheetExtra
    if off then
      map2 = { sheet = s, stripeOdd = off.stripeOdd, stripeEven = off.stripeEven }
    end
    T.ApplyPalette(light and "light" or "dark", extra, map2)
  end
  -- The rest of the grounds, over the window and with the palette's plates.
  -- -> whether any ground moved (the texts' inks are then due again).
  local moved = Skin._ControlGrounds()
  -- The accent border reads the mark tone, which the palette and the
  -- grounds just made.
  if tone == "accent" then
    local ar, ag, ab = AccentMark()
    P.inner[1], P.inner[2], P.inner[3], P.inner[4] = ar, ag, ab, 1
  end
  return moved
end
Skin._ResolveLook = ResolveLook

-------------------------------------------------------------
-- Fonts
--
-- The face and size of all of Postbox's text, through Theme.HostFont: a copy
-- of each game font object Postbox sets text in, which this style dresses in
-- the chosen face at the chosen size (Skin.GetFontFace). Changing either is
-- one re-dress of the copies -- a dozen objects -- and every string wearing
-- one follows, live, nothing per row.
--
-- The default is the game's own font: the copies are then the game's objects
-- exactly, whatever face this client's game fonts are. The other faces are
-- Barlow Semi Condensed SemiBold (Media/Fonts, SIL Open Font License; the
-- mockups' face), the fonts the game itself ships, and EllesmereUI's font
-- while EllesmereUI is loaded (its own copy, by its own path: nothing of it is
-- shipped here).
--
-- A face without the letters of the client's language is not offered there,
-- and a saved one falls back to the game font: Barlow and the game's Latin
-- faces have no Cyrillic (the game's Russian client has Cyrillic cuts of
-- them), and none of them has Chinese or Korean.
--
-- Text outline: Shadow (a drop shadow, no outline; a light one under dark ink
-- in Light mode), Outline (the client's thin outline, no shadow; none on a
-- light ground) or None.
-------------------------------------------------------------

local SCRIPT
local function Script()
  if SCRIPT then return SCRIPT end
  local locale = type(GetLocale) == "function" and GetLocale() or "enUS"
  if locale == "ruRU" then SCRIPT = "russian"
  elseif locale == "zhCN" or locale == "zhTW" or locale == "koKR" then SCRIPT = "cjk"
  else SCRIPT = "latin" end
  return SCRIPT
end

-- key -> the file on each script that has one. Proper names, the same in
-- every language.
local FONT_FILES = {
  barlow   = { name = "Barlow Semi Condensed", latin = FONT_DIR .. "BarlowSemiCondensed-SemiBold.ttf" },
  friz     = { name = "Friz Quadrata", latin = "Fonts\\FRIZQT__.TTF", russian = "Fonts\\FRIZQT___CYR.TTF" },
  arialn   = { name = "Arial Narrow", latin = "Fonts\\ARIALN.TTF", russian = "Fonts\\ARIALN.TTF" },
  morpheus = { name = "Morpheus", latin = "Fonts\\MORPHEUS.TTF", russian = "Fonts\\MORPHEUS_CYR.TTF" },
  skurri   = { name = "Skurri", latin = "Fonts\\SKURRI.TTF", russian = "Fonts\\SKURRI_CYR.TTF" },
}
local FONT_ORDER = { "game", "barlow", "friz", "arialn", "morpheus", "skurri", "eui" }
local TEXT_SCALES = { 0.90, 1.00, 1.10, 1.20 }

local function EUIFontPath()
  local EUI = _G.EllesmereUI
  if type(EUI) ~= "table" or type(EUI.GetFontPath) ~= "function" then return nil end
  local ok, path = pcall(EUI.GetFontPath, "blizzardSkin")
  if ok and type(path) == "string" and path ~= "" then return path end
  return nil
end

-- The file a font key draws with on this client, or false for the game's own.
local function FontPath(key)
  if key == "eui" then return EUIFontPath() or false end
  local spec = FONT_FILES[key]
  return spec and spec[Script()] or false
end

function Skin.GetFontChoices()
  local out = { { key = "game", name = ns.L["OPT_FONT_GAME"] } }
  for i = 2, #FONT_ORDER do
    local key = FONT_ORDER[i]
    if key == "eui" then
      if EUIFontPath() then out[#out + 1] = { key = key, name = ns.L["OPT_FONT_EUI"] } end
    elseif FontPath(key) then
      out[#out + 1] = { key = key, name = FONT_FILES[key].name }
    end
  end
  return out
end

function Skin.GetFont()
  local saved = GetProfile().pbFont
  if saved == "eui" or FONT_FILES[saved] then return saved end
  return "game"
end

function Skin.SetFont(key)
  if key ~= "game" and key ~= "eui" and not FONT_FILES[key] then return end
  GetProfile().pbFont = (key ~= "game") and key or nil
  Skin.ApplyFonts()
end

function Skin.GetTextScaleChoices() return TEXT_SCALES end

function Skin.GetTextScale()
  local saved = tonumber((GetProfile().pbTextScale))
  if not saved then return 1 end
  return max(TEXT_SCALES[1], min(TEXT_SCALES[#TEXT_SCALES], saved))
end

function Skin.SetTextScale(value)
  value = tonumber(value)
  if not value then return end
  value = max(TEXT_SCALES[1], min(TEXT_SCALES[#TEXT_SCALES], value))
  GetProfile().pbTextScale = (value ~= 1) and value or nil
  Skin.ApplyFonts()
end

local OUTLINE_ORDER = { "shadow", "outline", "none" }
local OUTLINE_NAME_KEY = { shadow = "OPT_OUTLINE_SHADOW", outline = "OPT_OUTLINE_OUTLINE", none = "OPT_OUTLINE_NONE" }

function Skin.GetOutlineChoices() return Choices(OUTLINE_ORDER, OUTLINE_NAME_KEY) end

function Skin.GetOutline()
  local saved = GetProfile().pbOutline
  if OUTLINE_NAME_KEY[saved] then return saved end
  return "shadow"
end

function Skin.SetOutline(key)
  if not OUTLINE_NAME_KEY[key] then return end
  GetProfile().pbOutline = (key ~= "shadow") and key or nil
  Skin.ApplyFonts()
end

-- The face Theme.HostFont dresses its copies in: the file (false: each game
-- object's own), the flags, the shadow and the size factor. Shadow is a drop
-- shadow and no outline, whatever a font pack or a host UI set on the game's
-- own fonts (one that outlines every game font would otherwise draw its
-- outline under "Shadow"); Outline the client's thin outline, no shadow;
-- None neither. On a light ground the Theme drops the outline and lays the
-- shadow in its light palette's colour (the halo follows the ground).
function Skin.GetFontFace()
  local outline = Skin.GetOutline()
  local flags, shadow = "", true
  if outline == "outline" then
    flags, shadow = "OUTLINE", false
  elseif outline == "none" then
    shadow = false
  end
  return FontPath(Skin.GetFont()), flags, shadow, Skin.GetTextScale()
end

-- Window titles are set at a size of their own (15), so they are re-dressed
-- here rather than following a copy. Weak-keyed: a title goes with its window.
local titles = setmetatable({}, { __mode = "k" })

local function DressTitle(fs)
  local base = titles[fs]
  if not base then return end
  local path = FontPath(Skin.GetFont()) or base.path
  local outline = Skin.GetOutline()
  local light = Skin.GetMode() == "light"
  -- As the copies (Skin.GetFontFace): Shadow a shadow and no outline, an
  -- outline only on a dark ground.
  local flags = (outline == "outline" and not light) and "OUTLINE" or ""
  pcall(fs.SetFont, fs, path, P.titleSize * Skin.GetTextScale(), flags)
  if fs.SetShadowOffset and fs.SetShadowColor then
    if outline ~= "shadow" then
      fs:SetShadowOffset(0, 0)
    elseif light then
      local sh = ns.Theme and ns.Theme.Colors and ns.Theme.Colors.textShadow
      fs:SetShadowOffset(1, -1)
      if sh then fs:SetShadowColor(sh[1], sh[2], sh[3], sh[4]) end
    elseif base.sx and base.sx ~= 0 and (base.sa or 0) > 0 then
      -- The title's own drop shadow, where it has one that shows.
      fs:SetShadowOffset(base.sx, base.sy)
      fs:SetShadowColor(base.sr, base.sg, base.sb, base.sa)
    else
      fs:SetShadowOffset(1, -1)
      fs:SetShadowColor(0, 0, 0, 1)
    end
  end
  local c = P.title
  fs:SetTextColor(c[1], c[2], c[3], c[4])
end

local function AdoptTitle(fs)
  if not fs or titles[fs] or type(fs.GetFont) ~= "function" then return end
  local path, _, flags = fs:GetFont()
  if type(path) ~= "string" or path == "" then path = STANDARD_TEXT_FONT end
  local base = { path = path, flags = flags }
  -- The title's own shadow, put back when Shadow is chosen again.
  if type(fs.GetShadowOffset) == "function" and type(fs.GetShadowColor) == "function" then
    local sx, sy = fs:GetShadowOffset()
    local sr, sg, sb, sa = fs:GetShadowColor()
    if type(sx) == "number" and type(sr) == "number" then
      base.sx, base.sy, base.sr, base.sg, base.sb, base.sa = sx, sy, sr, sg, sb, sa or 1
    end
  end
  titles[fs] = base
  DressTitle(fs)
end

-- The screens that fit text to its width, measured again.
local function RefitScreens()
  local UI = ns.MailboxUI
  if UI then
    if type(UI.RefreshCollectRowLayout) == "function" then pcall(UI.RefreshCollectRowLayout) end
    if type(UI.RefreshCollectTabCounts) == "function" then pcall(UI.RefreshCollectTabCounts) end
  end
  local MM = ns.MailMemory
  if MM and type(MM.Refresh) == "function" then pcall(MM.Refresh) end
  local panel = ns.OptionsPanel
  if panel and type(panel.RefreshControls) == "function" then pcall(panel.RefreshControls) end
end

-- A change of font, text size or outline: the copies re-dressed (which
-- forgets every fitted width), the titles, then the screens that fit text to
-- its width measured again. A rare, deliberate action; nothing here runs
-- otherwise.
function Skin.ApplyFonts()
  local T = ns.Theme
  if T and type(T.RefreshHostFonts) == "function" then T.RefreshHostFonts() end
  for fs in pairs(titles) do pcall(DressTitle, fs) end
  -- The style's own fonts take their colour again over a fresh dress.
  if Skin._PaintFonts then Skin._PaintFonts() end
  RefitScreens()
end

-------------------------------------------------------------
-- Primitives
-------------------------------------------------------------

local function EnsureBackdrop(frame)
  if type(frame.SetBackdrop) == "function" then return true end
  if type(Mixin) ~= "function" or type(BackdropTemplateMixin) ~= "table" then return false end
  Mixin(frame, BackdropTemplateMixin)
  if type(frame.OnBackdropSizeChanged) == "function" then
    frame:HookScript("OnSizeChanged", frame.OnBackdropSizeChanged)
  end
  return true
end

-- A flat block with a one-pixel edge: `fill` and `edge` are palette colours.
-- Built per frame: the edge is scale-dependent. The insets are zero, so the
-- fill runs to the frame's edge and the line sits on it (an inset fill under
-- a see-through edge carves a ring out of the block).
local paintedFill = setmetatable({}, { __mode = "k" })
local paintedEdge = setmetatable({}, { __mode = "k" })

local function Paint(frame, fill, edge)
  if not EnsureBackdrop(frame) then return end
  paintedFill[frame], paintedEdge[frame] = fill, edge
  local unit = Hairline(frame)
  frame:SetBackdrop({
    bgFile = WHITE, edgeFile = WHITE, edgeSize = unit,
    insets = { left = 0, right = 0, top = 0, bottom = 0 },
  })
  frame:SetBackdropColor(fill[1], fill[2], fill[3], fill[4] or 1)
  frame:SetBackdropBorderColor(edge[1], edge[2], edge[3], edge[4] or 1)
end

-- The same block in the palette's current colours, the backdrop kept.
local function Recolour(frame, fill, edge)
  if type(frame.SetBackdropColor) ~= "function" then return end
  frame:SetBackdropColor(fill[1], fill[2], fill[3], fill[4] or 1)
  frame:SetBackdropBorderColor(edge[1], edge[2], edge[3], edge[4] or 1)
end

local function HideRegions(holder)
  if not holder then return end
  local regions = { holder:GetRegions() }
  for i = 1, #regions do
    local region = regions[i]
    if region.IsObjectType and region:IsObjectType("Texture") then region:SetAlpha(0) end
  end
end

-------------------------------------------------------------
-- The window shell: fill, title strip, keyline, sheen, corners, close button
-------------------------------------------------------------

-- Every window this skin has painted. Weak-keyed. An appearance change
-- repaints all of them at once -- the options panel is one, and watching it
-- take the change is most of how the change is judged.
Skin._windows = setmetatable({}, { __mode = "k" })

-- Hide a Blizzard window template's own art: every texture on the frame and
-- on its named chrome children.
local function QuietTemplateArt(frame)
  HideRegions(frame)
  HideRegions(frame.NineSlice)
  HideRegions(frame.Inset)
  if frame.Inset then HideRegions(frame.Inset.NineSlice) end
  if frame.TitleBg then frame.TitleBg:SetAlpha(0) end
  if frame.Bg then frame.Bg:SetAlpha(0) end
end

-- The keyline's eight lines: the four outer (black) and the four inner (the
-- tone), each `unit` wide, the inner `weight` units. Laid out again on every
-- paint, which is where a new scale or a new weight arrives. `trim` shortens
-- each line at both ends, clear of a rounded corner.
local SIDES = { "TOP", "BOTTOM", "LEFT", "RIGHT" }

local function LayKeyline(frame, lines, inset, width, trim)
  trim = trim or 0
  for i = 1, 4 do
    local side, line = SIDES[i], lines[i]
    line:ClearAllPoints()
    if side == "TOP" then
      line:SetPoint("TOPLEFT", frame, "TOPLEFT", inset + trim, -inset)
      line:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -inset - trim, -inset)
      line:SetHeight(width)
    elseif side == "BOTTOM" then
      line:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", inset + trim, inset)
      line:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset - trim, inset)
      line:SetHeight(width)
    elseif side == "LEFT" then
      line:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset - trim)
      line:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", inset, inset + trim)
      line:SetWidth(width)
    else
      line:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -inset, -inset - trim)
      line:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset + trim)
      line:SetWidth(width)
    end
  end
end

local function EnsureShell(frame)
  local shell = frame.__pbShell
  if shell then return shell end
  shell = {}
  shell.fill = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
  shell.fill:SetAllPoints(frame)
  shell.strip = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
  shell.strip:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  shell.strip:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
  shell.strip:SetHeight(P.stripHeight)
  -- The name Mail Memory's cog key looks for to stand on the strip (it was
  -- Postbox Modern's).
  frame.__pbModernStrip = shell.strip
  shell.outer, shell.inner = {}, {}
  for i = 1, 4 do
    shell.outer[i] = frame:CreateTexture(nil, "BORDER", nil, 6)
    shell.inner[i] = frame:CreateTexture(nil, "BORDER", nil, 7)
  end
  frame.__pbShell = shell
  return shell
end

-- The sheen: a light falling off down the window's top, over the fill and
-- the strip and under everything the window holds. Made the first time it
-- is asked for.
local SHEEN_H = 90

local function PaintSheen(frame, shell, trim)
  local on = Skin.GetSheen()
  local sheen = shell.sheen
  if not on then
    if sheen then sheen:Hide() end
    return
  end
  if not sheen then
    sheen = frame:CreateTexture(nil, "BACKGROUND", nil, -6)
    sheen:SetTexture(WHITE)
    shell.sheen = sheen
  end
  sheen:ClearAllPoints()
  sheen:SetPoint("TOPLEFT", frame, "TOPLEFT", trim, 0)
  sheen:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -trim, 0)
  sheen:SetHeight(min(SHEEN_H, (frame:GetHeight() or SHEEN_H)))
  local c = P.sheen
  if sheen.SetGradient and type(CreateColor) == "function" then
    -- The colour objects are made once per shell and re-set in place.
    local lo, hi = shell.sheenLo, shell.sheenHi
    if not lo then
      lo, hi = CreateColor(c[1], c[2], c[3], 0), CreateColor(c[1], c[2], c[3], c[4])
      shell.sheenLo, shell.sheenHi = lo, hi
    else
      lo:SetRGBA(c[1], c[2], c[3], 0)
      hi:SetRGBA(c[1], c[2], c[3], c[4])
    end
    sheen:SetVertexColor(1, 1, 1, 1)
    sheen:SetGradient("VERTICAL", lo, hi)
  else
    sheen:SetVertexColor(c[1], c[2], c[3], c[4] * 0.5)
  end
  sheen:Show()
end

-- Rounded corners (Corners: Rounded): each window corner cut to a quarter
-- circle about 4 UI units across, with the keyline following the curve.
--
-- Crisp at any UI scale because the art is drawn one texel per SCREEN pixel
-- (Media/corner.tga, a radius from 3 to 12 pixels) and each piece is laid at
-- exactly its size in pixels (Hairline units), snapped to the pixel grid: the
-- radius is the one nearest 4 units at this scale, so it keeps its look from
-- 1080p to 4K. The fill and the title strip give up their corner squares to
-- pieces of the same colour; the keyline's straight lines stop a radius short
-- of each corner, where its arcs take over at the same weight. Square (the
-- default) hides all of it and the shell is exactly what it always was.
local CORNER_FILE = "Interface\\AddOns\\Postbox\\Media\\corner.tga"
local CORNER_UNITS = 4
local CORNER_ART = {
  [3] = { fill = { 0.015625, 0.0625, 0.0078125, 0.03125 }, outer = { 0.09375, 0.140625, 0.0078125, 0.03125 }, inner1 = { 0.171875, 0.21875, 0.0078125, 0.03125 }, inner2 = { 0.25, 0.296875, 0.0078125, 0.03125 } },
  [4] = { fill = { 0.015625, 0.078125, 0.046875, 0.078125 }, outer = { 0.109375, 0.171875, 0.046875, 0.078125 }, inner1 = { 0.203125, 0.265625, 0.046875, 0.078125 }, inner2 = { 0.296875, 0.359375, 0.046875, 0.078125 } },
  [5] = { fill = { 0.015625, 0.09375, 0.09375, 0.1328125 }, outer = { 0.125, 0.203125, 0.09375, 0.1328125 }, inner1 = { 0.234375, 0.3125, 0.09375, 0.1328125 }, inner2 = { 0.34375, 0.421875, 0.09375, 0.1328125 } },
  [6] = { fill = { 0.015625, 0.109375, 0.1484375, 0.1953125 }, outer = { 0.140625, 0.234375, 0.1484375, 0.1953125 }, inner1 = { 0.265625, 0.359375, 0.1484375, 0.1953125 }, inner2 = { 0.390625, 0.484375, 0.1484375, 0.1953125 } },
  [7] = { fill = { 0.015625, 0.125, 0.2109375, 0.265625 }, outer = { 0.15625, 0.265625, 0.2109375, 0.265625 }, inner1 = { 0.296875, 0.40625, 0.2109375, 0.265625 }, inner2 = { 0.4375, 0.546875, 0.2109375, 0.265625 } },
  [8] = { fill = { 0.015625, 0.140625, 0.28125, 0.34375 }, outer = { 0.171875, 0.296875, 0.28125, 0.34375 }, inner1 = { 0.328125, 0.453125, 0.28125, 0.34375 }, inner2 = { 0.484375, 0.609375, 0.28125, 0.34375 } },
  [9] = { fill = { 0.015625, 0.15625, 0.359375, 0.4296875 }, outer = { 0.1875, 0.328125, 0.359375, 0.4296875 }, inner1 = { 0.359375, 0.5, 0.359375, 0.4296875 }, inner2 = { 0.53125, 0.671875, 0.359375, 0.4296875 } },
  [10] = { fill = { 0.015625, 0.171875, 0.4453125, 0.5234375 }, outer = { 0.203125, 0.359375, 0.4453125, 0.5234375 }, inner1 = { 0.390625, 0.546875, 0.4453125, 0.5234375 }, inner2 = { 0.578125, 0.734375, 0.4453125, 0.5234375 } },
  [11] = { fill = { 0.015625, 0.1875, 0.5390625, 0.625 }, outer = { 0.21875, 0.390625, 0.5390625, 0.625 }, inner1 = { 0.421875, 0.59375, 0.5390625, 0.625 }, inner2 = { 0.625, 0.796875, 0.5390625, 0.625 } },
  [12] = { fill = { 0.015625, 0.203125, 0.640625, 0.734375 }, outer = { 0.234375, 0.421875, 0.640625, 0.734375 }, inner1 = { 0.453125, 0.640625, 0.640625, 0.734375 }, inner2 = { 0.671875, 0.859375, 0.640625, 0.734375 } },
}
-- corner -> its anchor, and how its texcoords turn the top-left art.
local CORNERS = {
  { "TOPLEFT", 1, -1, false, false }, { "TOPRIGHT", -1, -1, true, false },
  { "BOTTOMLEFT", 1, 1, false, true }, { "BOTTOMRIGHT", -1, 1, true, true },
}

local function CornerPiece(tex, spec, flipX, flipY)
  local l, r, t, b = spec[1], spec[2], spec[3], spec[4]
  if flipX then l, r = r, l end
  if flipY then t, b = b, t end
  tex:SetTexCoord(l, r, t, b)
end

local function EnsureRound(frame, shell)
  local round = shell.round
  if round then return round end
  round = { fill = {}, strip = {}, outer = {}, inner = {}, bands = {} }
  local function Tex(layer, sub, art)
    local t = frame:CreateTexture(nil, layer, nil, sub)
    if art then
      t:SetTexture(CORNER_FILE)
      if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(true) end
      if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
    end
    return t
  end
  for i = 1, 4 do
    round.fill[i] = Tex("BACKGROUND", -8, true)
    round.strip[i] = Tex("BACKGROUND", -7, true)
    round.outer[i] = Tex("BORDER", 6, true)
    round.inner[i] = Tex("BORDER", 7, true)
  end
  -- The fill's top and bottom bands between the corners, and the strip's
  -- band over the corners' height.
  round.bands.fillTop = Tex("BACKGROUND", -8)
  round.bands.fillBottom = Tex("BACKGROUND", -8)
  round.bands.stripTop = Tex("BACKGROUND", -7)
  round.bands.stripLow = Tex("BACKGROUND", -7)
  shell.round = round
  return round
end

-- Lays the corners for `frame` (or takes them away), and answers how far the
-- keyline's straight lines stop short of each corner: 0 when square.
local function RoundCorners(frame, shell, unit, inner, show, alpha, color)
  local rounded = Skin.GetCorners() == "rounded"
  local round = shell.round
  if not rounded then
    if round then
      for i = 1, 4 do
        round.fill[i]:Hide(); round.strip[i]:Hide(); round.outer[i]:Hide(); round.inner[i]:Hide()
      end
      for _, t in pairs(round.bands) do t:Hide() end
      shell.fill:ClearAllPoints()
      shell.fill:SetAllPoints(frame)
    end
    return 0
  end
  round = EnsureRound(frame, shell)
  local n = floor(CORNER_UNITS / unit + 0.5)
  if n < 3 then n = 3 elseif n > 12 then n = 12 end
  local art = CORNER_ART[n]
  local R = n * unit
  local s = P.strip
  local stripH = P.stripHeight

  -- The fill: a middle band full width, a band above and below it between
  -- the corners, and the four corner pieces.
  shell.fill:ClearAllPoints()
  shell.fill:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -R)
  shell.fill:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, R)
  local b = round.bands
  b.fillTop:ClearAllPoints()
  b.fillTop:SetPoint("TOPLEFT", frame, "TOPLEFT", R, 0)
  b.fillTop:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -R, 0)
  b.fillTop:SetHeight(R)
  b.fillBottom:ClearAllPoints()
  b.fillBottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", R, 0)
  b.fillBottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -R, 0)
  b.fillBottom:SetHeight(R)
  b.fillTop:SetColorTexture(color[1], color[2], color[3], alpha)
  b.fillBottom:SetColorTexture(color[1], color[2], color[3], alpha)
  b.fillTop:Show(); b.fillBottom:Show()
  -- The strip: full width below the corners, between them above. Its own
  -- texture stays where it is, clear: the title bar is seated on it.
  shell.strip:SetColorTexture(s[1], s[2], s[3], 0)
  b.stripLow:ClearAllPoints()
  b.stripLow:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -R)
  b.stripLow:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -R)
  b.stripLow:SetHeight(max(1, stripH - R))
  b.stripLow:SetColorTexture(s[1], s[2], s[3], s[4] * alpha)
  b.stripLow:Show()
  b.stripTop:ClearAllPoints()
  b.stripTop:SetPoint("TOPLEFT", frame, "TOPLEFT", R, 0)
  b.stripTop:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -R, 0)
  b.stripTop:SetHeight(R)
  b.stripTop:SetColorTexture(s[1], s[2], s[3], s[4] * alpha)
  b.stripTop:Show()

  local o, tone = P.keyOuter, P.inner
  local innerArt = (inner > unit * 1.5) and art.inner2 or art.inner1
  for i = 1, 4 do
    local spec = CORNERS[i]
    local point, flipX, flipY = spec[1], spec[4], spec[5]
    local f, st, ou, inn = round.fill[i], round.strip[i], round.outer[i], round.inner[i]
    f:ClearAllPoints(); f:SetPoint(point, frame, point, 0, 0); f:SetSize(R, R)
    st:ClearAllPoints(); st:SetPoint(point, frame, point, 0, 0); st:SetSize(R, R)
    ou:ClearAllPoints(); ou:SetPoint(point, frame, point, 0, 0); ou:SetSize(R, R)
    inn:ClearAllPoints(); inn:SetPoint(point, frame, point, 0, 0); inn:SetSize(R, R)
    CornerPiece(f, art.fill, flipX, flipY)
    f:SetVertexColor(color[1], color[2], color[3], alpha)
    f:Show()
    -- The strip's pieces at the top only.
    if i <= 2 then
      CornerPiece(st, art.fill, flipX, flipY)
      st:SetVertexColor(s[1], s[2], s[3], s[4] * alpha)
      st:Show()
    else
      st:Hide()
    end
    CornerPiece(ou, art.outer, flipX, flipY)
    ou:SetVertexColor(o[1], o[2], o[3], o[4])
    ou:SetShown(show)
    CornerPiece(inn, innerArt, flipX, flipY)
    inn:SetVertexColor(tone[1], tone[2], tone[3], tone[4])
    inn:SetShown(show)
  end
  return R
end

-- The window's fill, strip and keyline from the current settings.
local function PaintWindow(frame)
  local shell = EnsureShell(frame)
  local opaque = frame.__pbEuiAlwaysOpaque and true or false
  local color = opaque and P.opaque or P.window
  local alpha = opaque and P.opaque[4] or Skin.GetBgOpacity()
  shell.fill:SetColorTexture(color[1], color[2], color[3], alpha)
  -- The strip fades with the window: its own strength times the fill's.
  local s = P.strip
  shell.strip:SetColorTexture(s[1], s[2], s[3], s[4] * alpha)

  local border = Skin.GetBorderStyle()
  local unit = Hairline(frame)
  local show = border ~= "none"
  local tone = P.inner
  local o = P.keyOuter
  -- Edge: the inner line's colour alone, on the outer line's place -- the
  -- window's true edge -- and exactly one screen pixel wide (Theme.OnePixel),
  -- as a pixel-perfect UI draws its windows' edges. Thin and Thick are the
  -- keyline as they always were.
  local edge = border == "edge"
  if edge then
    local px = ns.Theme and ns.Theme.OnePixel and ns.Theme.OnePixel(frame) or unit
    unit, o = px, tone
  end
  local inner = (border == "thick") and 2 * unit or unit
  local trim = RoundCorners(frame, shell, unit, inner, show, alpha, color)
  LayKeyline(frame, shell.outer, 0, unit, trim)
  -- The inner line stands a pixel in, so it meets its arc a pixel sooner.
  LayKeyline(frame, shell.inner, unit, inner, (trim > 0) and (trim - unit) or 0)
  for i = 1, 4 do
    shell.outer[i]:SetColorTexture(o[1], o[2], o[3], o[4])
    shell.inner[i]:SetColorTexture(tone[1], tone[2], tone[3], tone[4])
    shell.outer[i]:SetShown(show)
    shell.inner[i]:SetShown(show and not edge)
  end
  local round = shell.round
  if edge and round and Skin.GetCorners() == "rounded" then
    for i = 1, 4 do
      round.outer[i]:SetVertexColor(tone[1], tone[2], tone[3], tone[4])
      round.inner[i]:Hide()
    end
  end
  PaintSheen(frame, shell, trim)
end

function Skin.ApplyAppearance()
  -- The accent border and the tint read the resolved palette.
  local grounds = ResolveLook()
  for frame in pairs(Skin._windows) do
    if frame then pcall(PaintWindow, frame) end
  end
  -- The opacity moves the window every text is read on: where that moved a
  -- ground, the inks and the window texts' plates are worked out again
  -- (a border, corners or the sheen move none, and repaint nothing here).
  if grounds then Skin._RepaintTexts() end
  if Skin._OnLookChanged then pcall(Skin._OnLookChanged) end
end

-- Every text this style painted, in the inks of the grounds as they are now:
-- the tracked texts and their plates, the style's fonts, the plates'
-- captions, and the class colours (which ContactService inks).
function Skin._RepaintTexts()
  local T = ns.Theme
  if not T then return end
  -- The copies' own colours (a button's caption) first: a handful of
  -- objects. Then the texts, where an ink moved (Theme.InksMoved).
  if T.RefreshHostFonts then T.RefreshHostFonts(true) end
  if not T.InksMoved or T.InksMoved() then
    if T.RepaintTracked then T.RepaintTracked() end
    Skin._PaintFonts()
    if T.RepaintAccentText then T.RepaintAccentText() end
    if T.RepaintPlates then
      for frame in pairs(Skin._windows) do pcall(T.RepaintPlates, frame, 0) end
    end
  end
  local CS = ns.ContactService
  if CS and type(CS.PaletteMoved) == "function" then pcall(CS.PaletteMoved) end
  -- And what is coloured inside a line, written again where its inks moved.
  if Skin._EscapesMoved() then RefitScreens() end
end

-- Whether the inks written inside lines (a row's figures, the status line's
-- tones: Theme.EscapeInkSignature) moved since this was last asked -- most
-- changes of the opacity or the accent move none of them, and those lines
-- are then left as they are rather than written again.
function Skin._EscapesMoved()
  local T = ns.Theme
  local sig = T and type(T.EscapeInkSignature) == "function" and T.EscapeInkSignature() or false
  if sig == Skin._escapeSig then return false end
  Skin._escapeSig = sig
  return true
end

-- The window scale moved: every one-pixel edge is a pixel of the new scale,
-- so each painted block is painted again, then the windows.
function Skin.ApplyScale()
  for frame, fill in pairs(paintedFill) do
    local edge = paintedEdge[frame]
    if frame and edge then pcall(Paint, frame, fill, edge) end
  end
  for frame in pairs(Skin._windows) do
    if frame then pcall(PaintWindow, frame) end
  end
end

-- The title, the cog and the close button, centred on the strip: one
-- reference for all three, rather than offsets guessed against the template's
-- own bar, which is hidden here.
local function SeatTitleBar(frame)
  local strip = frame.__pbShell and frame.__pbShell.strip
  if not strip then return end
  if frame.TitleText then
    frame.TitleText:ClearAllPoints()
    frame.TitleText:SetPoint("CENTER", strip, "CENTER", 0, 0)
    AdoptTitle(frame.TitleText)
    -- On the strip, which fades with the window: a plate of its own where
    -- the strip cannot carry it (Theme.OnWindow). A creative style's title
    -- stands on its own art (a lip, a nameplate, a band), not on the strip.
    if not Creative() and ns.Theme and ns.Theme.OnWindow then ns.Theme.OnWindow(frame.TitleText, "strip", "CENTER") end
  end
  if frame.CloseButton then
    frame.CloseButton:ClearAllPoints()
    frame.CloseButton:SetPoint("RIGHT", strip, "RIGHT", -3, 0)
  end
  if frame.OptionsButton then
    frame.OptionsButton:ClearAllPoints()
    frame.OptionsButton:SetPoint("LEFT", strip, "LEFT", 5, 0)
  end
end

-- The house X, the close colour at three quarters and full under the pointer:
-- the client's close atlas where it has one, else two rotated bars of the
-- white tile. Kept, so a palette change repaints it.
local closes = setmetatable({}, { __mode = "k" })

local function TintClose(button, a)
  local marks = closes[button]
  if not marks then return end
  local c = P.close
  for i = 1, #marks do marks[i]:SetVertexColor(c[1], c[2], c[3], a or c[4]) end
end

local function CloseEnter(self) TintClose(self, 1) end
local function CloseLeave(self) TintClose(self, nil) end

local function FlatClose(button)
  if not button or button.__pbPostboxClose then return end
  button.__pbPostboxClose = true
  HideRegions(button)
  for _, key in ipairs({ "SetNormalTexture", "SetPushedTexture", "SetHighlightTexture", "SetDisabledTexture" }) do
    if type(button[key]) == "function" then pcall(button[key], button, "") end
  end

  local marks = {}
  local atlas = ns.Theme and ns.Theme.FirstAtlas and ns.Theme.FirstAtlas({ "uitools-icon-close" })
  if atlas then
    local x = button:CreateTexture(nil, "OVERLAY")
    x:SetAtlas(atlas, false)
    x:SetSize(14, 14)
    x:SetPoint("CENTER")
    marks[1] = x
  else
    for _, angle in ipairs({ math.rad(45), math.rad(-45) }) do
      local bar = button:CreateTexture(nil, "OVERLAY")
      bar:SetTexture(WHITE)
      bar:SetSize(11, 1.5)
      bar:SetPoint("CENTER")
      if bar.SetRotation then bar:SetRotation(angle) end
      marks[#marks + 1] = bar
    end
  end
  closes[button] = marks
  TintClose(button, nil)
  button:HookScript("OnEnter", CloseEnter)
  button:HookScript("OnLeave", CloseLeave)
end

-------------------------------------------------------------
-- Controls
-------------------------------------------------------------

-- A tagged panel, on its own ground. Which ground is what it is: the mail list
-- and the cards the inset panel's, an input wrap a field's, the band its own;
-- in an always-solid window (the options panel, Mail Memory) the lists and
-- cards are the options' cards.
local function FlatPanel(panel, kind)
  if not panel or panel.__postboxSkinned then return end
  panel.__postboxSkinned = true
  if panel.pbSurfaceTexture then panel.pbSurfaceTexture:SetAlpha(0) end
  if kind == "input" then
    Paint(panel, P.field, P.fieldEdge)
  elseif kind == "band" then
    Paint(panel, P.band, P.bandEdge)
  elseif kind == "optCard" then
    Paint(panel, P.optCard, P.optCardEdge)
  else
    Paint(panel, P.list, P.listEdge)
  end
end

-- The style's own font object: the value of a select, in the accent's text
-- tone on the select's own ground (Theme.Ink): a copy of the game's button
-- font, recoloured, which the host-font copies dress in the chosen face. A
-- push button's caption is the button's own font, Blizzard's gold, as
-- EllesmereUI keeps it -- on a light palette the copy's colour made right
-- for the button (Theme DressCopy). A button puts its state's font back on
-- its label at every enable and disable, so the colour lives on the object.
local selectFont

local function Recoloured(font, r, g, b)
  if not font or type(font.SetTextColor) ~= "function" then return end
  font:SetTextColor(r, g, b)
  local T = ns.Theme
  local copy = T and T.HostFont and T.HostFont(font)
  if copy and copy ~= font then copy:SetTextColor(r, g, b) end
end

-- The select's value colour: the accent as text on the select.
local function SelectInk()
  local T = ns.Theme
  if T and T.Ink then return T.Ink("accentText", "select") end
  if T and T.GetAccentTone then return T.GetAccentTone("text") end
  return 1, 0.82, 0
end

-- The object and its dressed copy in their colour: after a palette change,
-- or a re-dress of the copies (which puts the copied colour back).
function Skin._PaintFonts()
  if selectFont then
    local r, g, b = SelectInk()
    Recoloured(selectFont, r, g, b)
  end
end

local function SelectFont()
  if selectFont ~= nil then return selectFont or nil end
  local base = _G.GameFontNormal
  if type(CreateFont) ~= "function" or not base then selectFont = false return nil end
  local font = CreateFont("PostboxSelectValue")
  if not font then selectFont = false return nil end
  if type(font.CopyFontObject) == "function" then pcall(font.CopyFontObject, font, base) end
  local r, g, b = SelectInk()
  if type(font.SetTextColor) == "function" then font:SetTextColor(r, g, b) end
  selectFont = font
  return font
end

-- Push buttons' hover washes and selects' carets, kept for a repaint.
local hovers = setmetatable({}, { __mode = "k" })
local carets = setmetatable({}, { __mode = "k" })

local function PaintHover(hover)
  local c = P.hover
  hover:SetVertexColor(c[1], c[2], c[3], 1)
  hover:SetAlpha(c[4])
end

local function FlatButton(button)
  if not button or button.__postboxSkinned then return end
  button.__postboxSkinned = true
  local regions = { button:GetRegions() }
  for i = 1, #regions do
    local region = regions[i]
    if region.IsObjectType and region:IsObjectType("Texture") then
      region:SetTexture(nil)
      region:Hide()
    end
  end
  local select = button.__postboxSelect and true or false
  Paint(button, select and P.select or P.button, select and P.selectEdge or P.buttonEdge)
  button:SetHighlightTexture(WHITE)
  local hover = button:GetHighlightTexture()
  if hover then
    hover:SetAllPoints()
    PaintHover(hover)
    hovers[hover] = true
  end

  local T = ns.Theme
  if select then
    local font = SelectFont()
    local face = font and T and T.HostFont and T.HostFont(font) or font
    if face then
      if button.SetNormalFontObject then button:SetNormalFontObject(face) end
      if button.SetHighlightFontObject then button:SetHighlightFontObject(face) end
      local label = button.GetFontString and button:GetFontString()
      if label and label.SetFontObject then label:SetFontObject(face) end
    end
    local caret = T and T.Glyph and T.Glyph(button, "caret", 5, "OVERLAY")
    if caret then
      caret:SetPoint("CENTER", button, "RIGHT", -9, 0)
      local c = P.caret
      caret:SetVertexColor(c[1], c[2], c[3], 1)
      button.__pbCaret = caret
      carets[caret] = true
    end
  end
  -- The button's own state fonts in the chosen face (Theme.HostFontButton).
  if T and type(T.HostFontButton) == "function" then pcall(T.HostFontButton, button) end
end

-- A push button's caption colour as it shows: the game's button font's own
-- gold, made right for the button it stands on (on a light palette, the
-- gold that reads on paper). For the options' drawing of the window.
function Skin.ButtonTextRGB()
  local r, g, b = 1, 0.82, 0
  local base = _G.GameFontNormal
  if base and type(base.GetTextColor) == "function" then
    local br, bg, bb = base:GetTextColor()
    if type(br) == "number" then r, g, b = br, bg, bb end
  end
  local T = ns.Theme
  if T and T.InkFor then return T.InkFor(r, g, b, "button") end
  return r, g, b
end

-- The colour saved as a kind's Custom ("accent" | "surface" | "border"), as
-- it is painted (a surface held by the rule), or nil where none is saved.
function Skin.GetCustomColor(kind)
  local profile = GetProfile()
  if kind == "accent" then return FromHex(profile.pbAccentHex) end
  if kind == "border" then return FromHex(profile.pbBorderHex) end
  if kind == "surface" then
    -- The Mode in force's own, held by its rule.
    local S = SurfaceSet()
    local r, g, b = FromHex(profile[S.hexKey])
    if r and ns.Theme and ns.Theme.ClampSurface then r, g, b = ns.Theme.ClampSurface(r, g, b, S.light and true or false) end
    return r, g, b
  end
  return nil
end

-- A checkbox: a flat box with a one-pixel edge, and the house tick (the
-- mockups' own mark) in the accent's mark tone.
local checks = setmetatable({}, { __mode = "k" })

local function PaintTick(cb)
  local tick = cb.GetCheckedTexture and cb:GetCheckedTexture()
  if tick then tick:SetVertexColor(AccentMark()) end
  local disabledTick = cb.GetDisabledCheckedTexture and cb:GetDisabledCheckedTexture()
  if disabledTick then
    local T = ns.Theme
    local v = (T and T.Grey) and T.Grey(0.56) or 0.56
    disabledTick:SetVertexColor(v, v, v, 1)
  end
end

local function FlatCheck(cb)
  if not cb or cb.__postboxSkinned then return end
  cb.__postboxSkinned = true
  for _, key in ipairs({ "SetNormalTexture", "SetPushedTexture", "SetHighlightTexture", "SetDisabledTexture" }) do
    if type(cb[key]) == "function" then pcall(cb[key], cb, "") end
  end
  local tick = cb.GetCheckedTexture and cb:GetCheckedTexture()
  local disabledTick = cb.GetDisabledCheckedTexture and cb:GetDisabledCheckedTexture()
  local regions = { cb:GetRegions() }
  for i = 1, #regions do
    local r = regions[i]
    if r ~= tick and r ~= disabledTick and r.IsObjectType and r:IsObjectType("Texture") then r:SetAlpha(0) end
  end
  -- The box is 18 units square, centred in the checkbox's own hit area.
  local inset = max(1, floor(((cb:GetWidth() or 22) - P.checkBox) / 2 + 0.5))
  local box = CreateFrame("Frame", nil, cb)
  box:SetPoint("TOPLEFT", cb, "TOPLEFT", inset, -inset)
  box:SetPoint("BOTTOMRIGHT", cb, "BOTTOMRIGHT", -inset, inset)
  box:SetFrameLevel(max(0, (cb:GetFrameLevel() or 1) - 1))
  Paint(box, P.check, P.checkEdge)
  box:EnableMouse(false)
  cb.__pbBox = box

  local glyph = ns.Theme and ns.Theme.GLYPHS and ns.Theme.GLYPHS.check
  for _, tex in ipairs({ tick or false, disabledTick or false }) do
    if tex then
      if glyph then
        tex:SetTexture(glyph.file)
        tex:SetTexCoord(glyph.l, glyph.r, glyph.t, glyph.b)
        tex:ClearAllPoints()
        tex:SetPoint("CENTER", box, "CENTER", 0, 0)
        tex:SetSize(10, 10)
      end
      tex:SetAlpha(1)
    end
  end
  checks[cb] = true
  PaintTick(cb)
end

-- An edit box that is not inside an input wrap: its template art faded, a
-- field's ground under it.
local function FlatEdit(eb)
  if not eb or eb.__postboxSkinned then return end
  eb.__postboxSkinned = true
  HideRegions(eb)
  for _, k in ipairs({ "Left", "Right", "Middle", "Mid" }) do
    if eb[k] and eb[k].SetAlpha then eb[k]:SetAlpha(0) end
  end
  Paint(eb, P.field, P.fieldEdge)
end

-- The classic three-piece slider some lists still carry: the art goes, the
-- thumb becomes a thin bar. Behaviour untouched. (Postbox's own lists draw
-- Theme.SlimScrollBar, which flags the template's bar so this leaves it be.)
local function FlatScrollBar(sb)
  if not sb or sb.__pbModernBar then return end
  sb.__pbModernBar = true
  for _, key in ipairs({ "ScrollUpButton", "ScrollDownButton", "Back", "Forward" }) do
    local b = sb[key]
    if b then
      HideRegions(b)
      for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetDisabledTexture", "GetHighlightTexture" }) do
        local fn = b[getter]
        local t = fn and fn(b)
        if t then t:SetAlpha(0) end
      end
    end
  end
  HideRegions(sb)
  if sb.Track then HideRegions(sb.Track) end
  local thumb = sb.GetThumbTexture and sb:GetThumbTexture()
  if thumb then
    thumb:SetTexture(nil)
    if ns.Theme and ns.Theme.FillChrome then
      ns.Theme.FillChrome(thumb, 0.30)
    else
      thumb:SetColorTexture(1, 1, 1, 0.30)
    end
    thumb:SetWidth(4)
    -- Region alpha and colour alpha multiply, and the sweep above zeroed it.
    thumb:SetAlpha(1)
  end
end

local function FlatScroll(sf)
  if not sf then return end
  local name = sf.GetName and sf:GetName()
  FlatScrollBar(sf.ScrollBar or (name and _G[name .. "ScrollBar"]))
end

-------------------------------------------------------------
-- The pass over tagged content, the same shape as the host skins'
-------------------------------------------------------------

local function SkinOne(c, opaque)
  if c.__postboxInputWrap then
    FlatPanel(c, "input")
  elseif c.__postboxPanel then
    local tag = c.__postboxPanel
    FlatPanel(c, tag == "band" and "band" or (opaque and "optCard") or "list")
  elseif c:IsObjectType("EditBox") then
    if not c.__postboxNoEditSkin then FlatEdit(c) end
  elseif c:IsObjectType("ScrollFrame") then
    FlatScroll(c)
  elseif c.__postboxCheck then
    FlatCheck(c)
  elseif c:IsObjectType("Button") then
    if c.__postboxButton then FlatButton(c) end
  end
end

-- Depth-first, each node's children in turn, as far as eight levels down --
-- on one stack reused by every walk, filled in place, so a walk makes no
-- garbage. A walk begun inside a walk (a paint that refreshes) takes a
-- stack of its own.
local SkinTree
do
  local stack, depths = {}, {}
  local busy = false

  local function Push(st, dp, n, d, ...)
    for i = select("#", ...), 1, -1 do
      n = n + 1
      st[n], dp[n] = (select(i, ...)), d
    end
    return n
  end

  local function Walk(frame, opaque, st, dp)
    local n = Push(st, dp, 0, 1, frame:GetChildren())
    while n > 0 do
      local c, d = st[n], dp[n]
      st[n], dp[n] = nil, nil
      n = n - 1
      if c then
        if c.IsObjectType then SkinOne(c, opaque) end
        if d <= 8 then n = Push(st, dp, n, d + 1, c:GetChildren()) end
      end
    end
  end

  SkinTree = function(frame, depth, opaque)
    if not frame then return end
    if busy then return Walk(frame, opaque, {}, {}) end
    -- Every caller walks under pcall and moves on, so a failure here ends
    -- the walk the same way; the stack is emptied either way.
    busy = true
    pcall(Walk, frame, opaque, stack, depths)
    for i = #stack, 1, -1 do stack[i], depths[i] = nil, nil end
    busy = false
  end
end

local function RootOf(frame)
  local f, opaque = frame, false
  for _ = 1, 12 do
    if not f then break end
    if f.__pbEuiAlwaysOpaque then opaque = true break end
    f = f.GetParent and f:GetParent() or nil
  end
  return opaque
end

function Skin.Refresh(frame)
  if not frame then return end
  pcall(SkinTree, frame, 0, RootOf(frame))
  -- Popups built lazily (the bug report, the recipient dialogs) arrive after
  -- Apply and carry their own small close button.
  pcall(FlatClose, frame.CloseButton)
end

-- The mailbox window's open. Every step of the walk skins a frame once and
-- never again, so a walk finds work only where something was made since the
-- last one; the skin generation (Theme.SkinGeneration) moves whenever a frame
-- is tagged for the skins or the palette changes. A window already walked at
-- the current generation is left as it is.
local walkedAt = setmetatable({}, { __mode = "k" })

function Skin.RefreshWindow(frame)
  if not frame then return end
  local T = ns.Theme
  local gen = T and type(T.SkinGeneration) == "function" and T.SkinGeneration() or nil
  if gen ~= nil and walkedAt[frame] == gen then return end
  -- Through the field, so a style that wraps the refresh (Skin_Creative) is
  -- asked too.
  Skin.Refresh(frame)
  walkedAt[frame] = T and type(T.SkinGeneration) == "function" and T.SkinGeneration() or nil
end

-- The accent moved: the ticks, the select values, the plates and the
-- accent-toned text and icons.
function Skin.RefreshAccents()
  for cb in pairs(checks) do pcall(PaintTick, cb) end
  Skin._PaintFonts()
  local T = ns.Theme
  if T then
    if T.RepaintAccentText then T.RepaintAccentText() end
    if T.RepaintAccentIcons then T.RepaintAccentIcons() end
    if T.RepaintPlates then
      for frame in pairs(Skin._windows) do pcall(T.RepaintPlates, frame, 0) end
    end
  end
end

-- Any colour setting changed: the palette resolved again, then everything
-- already on screen painted from it -- the windows, every block and control
-- this style painted, the text and chrome the Theme tracked, the plates, the
-- titles and the style's fonts. `full`: the palette's text colours or row
-- shades moved too (Mode, Row stripes), so the lists are bound again, which
-- remakes their coloured sums and names, and the class colours are asked for
-- again. Only on a settings change; a few hundred calls into the client.
function Skin.ApplyLook(full)
  local T = ns.Theme
  local wasLight = T and T.IsLight and T.IsLight() or false
  local grounds = ResolveLook()
  local nowLight = T and T.IsLight and T.IsLight() or false
  if T then
    -- The copies take the palette's colours and shadow (and a new shadow
    -- setting is a new face, re-dressed and re-measured).
    if T.RefreshHostFonts then T.RefreshHostFonts(true) end
    if T.RepaintTracked then T.RepaintTracked() end
  end
  for frame in pairs(Skin._windows) do
    if frame then pcall(PaintWindow, frame) end
  end
  for frame, fill in pairs(paintedFill) do
    local edge = paintedEdge[frame]
    if frame and edge then pcall(Recolour, frame, fill, edge) end
  end
  for hover in pairs(hovers) do pcall(PaintHover, hover) end
  local c = P.caret
  for caret in pairs(carets) do caret:SetVertexColor(c[1], c[2], c[3], 1) end
  for button in pairs(closes) do pcall(TintClose, button, nil) end
  for fs in pairs(titles) do pcall(DressTitle, fs) end
  Skin.RefreshAccents()
  -- A ground moved (the background colour, the opacity) and with it an ink
  -- written inside a line (a figure, a tone on the status line): those
  -- lines are written again in the new inks, as a change of Mode writes
  -- them; and a name's class colour is asked for again.
  local escapes = Skin._EscapesMoved()
  if full or wasLight ~= nowLight or (grounds and escapes) then
    local CS = ns.ContactService
    if CS and type(CS.PaletteMoved) == "function" then pcall(CS.PaletteMoved) end
    RefitScreens()
  else
    -- The class colours look again where a ground moved: each compares
    -- its own ink and repaints only if it moved.
    local CS = grounds and ns.ContactService
    if CS and type(CS.PaletteMoved) == "function" then pcall(CS.PaletteMoved) end
    local panel = ns.OptionsPanel
    if panel and type(panel.RefreshControls) == "function" then pcall(panel.RefreshControls) end
  end
  if Skin._OnLookChanged then pcall(Skin._OnLookChanged) end
end

-------------------------------------------------------------
-- A colour of the player's own: Blizzard's colour picker
--
-- ColorPickerFrame:SetupColorPickerAndShow, the client's own call for this
-- (addons and Blizzard's settings alike use it); no field of the picker is
-- written here and none of its code is hooked. It opens at the options
-- panel's strata, so it is not behind the panel, and returns to its own when
-- it closes. Dragging applies the colour live, coalesced to once a frame;
-- Cancel (or a click elsewhere, which the picker treats as one) puts back
-- what was there.
-------------------------------------------------------------

local picking

local function PickerApply()
  local job = picking
  if not job then return end
  job.queued = false
  local picker = _G.ColorPickerFrame
  if job.hex then job.set(job.hex) end
  if picker and not picker:IsShown() then
    if job.strata and picker.SetFrameStrata then picker:SetFrameStrata(job.strata) end
    picking = nil
  end
end

local function PickerQueue()
  local job = picking
  if not job or job.queued then return end
  job.queued = true
  if C_Timer and type(C_Timer.After) == "function" then C_Timer.After(0, PickerApply) else PickerApply() end
end

-- Whether the client has the picker call this needs.
function Skin.CanPickColor()
  local picker = _G.ColorPickerFrame
  return type(picker) == "table" and type(picker.SetupColorPickerAndShow) == "function"
end

-- kind: "accent" | "surface" | "border". Opens the picker on the colour in
-- use; the choice is saved as that kind's Custom.
function Skin.PickColor(kind)
  if not Skin.CanPickColor() then return false end
  local picker = _G.ColorPickerFrame
  local r, g, b, set, restore
  local profile = GetProfile()
  if kind == "accent" then
    r, g, b = Skin.GetAccent()
    local was, wasHex = profile.pbAccent, profile.pbAccentHex
    set = function(hex) Skin.SetAccent("custom", hex) end
    restore = function() profile.pbAccent, profile.pbAccentHex = was, wasHex; Skin.ApplyLook(false) end
  elseif kind == "surface" then
    -- The Mode in force's colour and its own keys: the other Mode's pick is
    -- never touched.
    local S = SurfaceSet()
    r, g, b = SurfaceFor(Skin.GetSurfaceKey(), Skin.GetMode())
    local was, wasHex, wasTint = profile[S.key], profile[S.hexKey], profile.pbTint
    local O = SurfaceSet((Skin.GetMode() == "light") and "dark" or "light")
    local wasOther = profile[O.key]
    set = function(hex) Skin.SetSurface("custom", hex) end
    restore = function()
      profile[S.key], profile[S.hexKey], profile.pbTint, profile[O.key] = was, wasHex, wasTint, wasOther
      Skin.ApplyLook(false)
    end
  elseif kind == "border" then
    r, g, b = P.inner[1], P.inner[2], P.inner[3]
    local was, wasHex = profile.pbBorderTone, profile.pbBorderHex
    set = function(hex)
      local p = GetProfile()
      p.pbBorderHex, p.pbBorderTone = hex, "custom"
      Skin.ApplyAppearance()
    end
    restore = function() profile.pbBorderTone, profile.pbBorderHex = was, wasHex; Skin.ApplyAppearance() end
  else
    return false
  end
  local job = { set = set, strata = picker.GetFrameStrata and picker:GetFrameStrata() or nil }
  picking = job
  local ok = pcall(picker.SetupColorPickerAndShow, picker, {
    r = r, g = g, b = b, hasOpacity = false,
    swatchFunc = function()
      if picking ~= job then return end
      local pr, pg, pb = picker:GetColorRGB()
      if type(pr) == "number" then job.hex = ToHex(pr, pg, pb) end
      PickerQueue()
    end,
    cancelFunc = function()
      if picking ~= job then return end
      job.hex = nil
      restore()
      if job.strata and picker.SetFrameStrata then picker:SetFrameStrata(job.strata) end
      picking = nil
    end,
  })
  if not ok then
    picking = nil
    return false
  end
  if picker.SetFrameStrata then picker:SetFrameStrata("FULLSCREEN_DIALOG") end
  if picker.Raise then picker:Raise() end
  -- Saved as Custom at once, so the options show it; the first swatch call
  -- (a drag, or OK) writes the colour.
  job.hex = ToHex(r, g, b)
  PickerQueue()
  return true
end

-------------------------------------------------------------
-- Tooltips
--
-- Postbox's own tooltips arrive on the shared GameTooltip. On a stock UI it
-- stays Blizzard's, which beside a flat black window looks like a leftover,
-- so while the tooltip belongs to Postbox its art steps aside for this
-- style's fill and edge, and steps straight back for every other tooltip in
-- the game. Nothing is destroyed. Under a host UI the tooltip is that UI's
-- and is never touched. It stays dark in Light mode: its lines are the
-- game's own white text.
--
-- Nothing is hooked and nothing is written onto the tooltip's table. A
-- sensor -- a Postbox frame with no art, spread over the tooltip -- shows
-- and hides with it, and its own scripts dress it for a Postbox owner on
-- show (or when a resize finds a new owner) and undo that on hide -- only
-- while a Postbox window is on screen (WatchTooltips): away from Postbox the
-- sensor has no scripts at all. What was made and what was hidden sits in
-- `tipState`, Postbox's own table.
-------------------------------------------------------------

local tipState = { dressed = false, owner = nil, fill = nil, edges = nil, nineShown = nil, sensor = nil, watching = false }

local function Forbidden(frame)
  return frame.IsForbidden ~= nil and frame:IsForbidden() and true or false
end

local function IsOurs(owner)
  local frame = owner
  for _ = 1, 6 do
    if type(frame) ~= "table" or Forbidden(frame) then return false end
    if frame.__pbTooltipOwner then return true end
    local name = frame.GetName and frame:GetName()
    if type(name) == "string" and name:find("^Postbox") then return true end
    frame = frame.GetParent and frame:GetParent() or nil
  end
  return false
end

local function DressTooltip(tip, ours)
  if not tip then return end
  -- Only ever undo what this did.
  local st = tipState
  local wasDressed = st.dressed
  if not ours and not wasDressed then return end
  st.dressed = ours and true or false

  if not st.fill then
    local edge = Hairline(tip)
    local c = P.tooltip
    local fill = tip:CreateTexture(nil, "BACKGROUND", nil, -8)
    fill:SetPoint("TOPLEFT", tip, "TOPLEFT", edge, -edge)
    fill:SetPoint("BOTTOMRIGHT", tip, "BOTTOMRIGHT", -edge, edge)
    fill:SetColorTexture(c[1], c[2], c[3], c[4])
    fill:Hide()
    -- Four lines rather than a backdrop: the tooltip resizes constantly, and
    -- lines anchored to its corners follow for free.
    local e = P.tooltipEdge
    local edges = {}
    local specs = {
      { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
      { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false },
    }
    for i = 1, #specs do
      local line = tip:CreateTexture(nil, "BORDER")
      line:SetPoint(specs[i][1], tip, specs[i][1], 0, 0)
      line:SetPoint(specs[i][2], tip, specs[i][2], 0, 0)
      if specs[i][3] then line:SetHeight(edge) else line:SetWidth(edge) end
      line:SetColorTexture(e[1], e[2], e[3], e[4])
      line:Hide()
      edges[i] = line
    end
    st.fill, st.edges = fill, edges
  end

  st.fill:SetShown(ours)
  for i = 1, #st.edges do st.edges[i]:SetShown(ours) end
  local nine = tip.NineSlice
  if nine then
    if ours then
      if not wasDressed then st.nineShown = nine:IsShown() end
      nine:Hide()
    else
      nine:SetShown(st.nineShown ~= false)
    end
  end
end

-- The sensor's look at the tooltip: dress for a Postbox owner, undress for
-- any other. A forbidden tooltip is left alone.
local function SenseTooltip(tip, force)
  if Forbidden(tip) then return end
  local owner = tip.GetOwner and tip:GetOwner() or nil
  if not force and owner == tipState.owner then return end
  tipState.owner = owner
  local ok, ours = pcall(IsOurs, owner)
  DressTooltip(tip, ok and ours or false)
end

local function SensorShown(self) SenseTooltip(self:GetParent(), true) end
local function SensorResized(self) SenseTooltip(self:GetParent(), false) end
local function SensorHidden(self)
  tipState.owner = nil
  local tip = self:GetParent()
  if Forbidden(tip) then return end
  DressTooltip(tip, false)
end

-- The sensor hears the tooltip only while a Postbox window is on screen: its
-- scripts run on every game tooltip's show, hide and resize, and with no
-- Postbox window up no tooltip can be Postbox's to dress. Attached when a
-- window shows, detached -- the tooltip undressed if it was dressed -- when
-- the last one hides.
local function WatchTooltips(on)
  local sensor = tipState.sensor
  if not sensor or tipState.watching == on then return end
  tipState.watching = on
  local tip = sensor:GetParent()
  if on then
    sensor:SetScript("OnShow", SensorShown)
    sensor:SetScript("OnHide", SensorHidden)
    sensor:SetScript("OnSizeChanged", SensorResized)
    -- Already up (a window shown under the cursor): look now.
    if tip and tip:IsVisible() then SenseTooltip(tip, true) end
  else
    sensor:SetScript("OnShow", nil)
    sensor:SetScript("OnHide", nil)
    sensor:SetScript("OnSizeChanged", nil)
    tipState.owner = nil
    if tipState.dressed and tip and not Forbidden(tip) then DressTooltip(tip, false) end
  end
end

local function WindowShown() WatchTooltips(true) end

local function WindowHidden()
  for frame in pairs(Skin._windows) do
    if frame:IsShown() then return end
  end
  WatchTooltips(false)
end

local function HookTooltips()
  if tipState.sensor or type(CreateFrame) ~= "function" then return end
  -- GameTooltip is shared, and a host UI skins it for the whole interface:
  -- choosing this style is a statement about Postbox's windows, not a licence
  -- to restyle a frame the rest of the interface also uses.
  if _G.EllesmereUI or _G.ElvUI then return end
  local tip = GameTooltip
  if type(tip) ~= "table" or Forbidden(tip) then return end
  local sensor = CreateFrame("Frame", nil, tip)
  sensor:SetAllPoints(tip)
  tipState.sensor = sensor
  tipState.watching = false
end

-------------------------------------------------------------
-- Apply
-------------------------------------------------------------

function Skin.Apply(frame)
  if not frame or frame.__postboxSkinned then return end
  frame.__postboxSkinned = true

  -- The shared claim record: the host skins read it and stand down rather
  -- than layering their shell over a window this style has painted.
  ns.SkinAppliedBy = "postbox"

  for _, key in ipairs({ "pbWindowStone", "pbWindowTint" }) do
    if frame[key] then frame[key]:SetAlpha(0) end
  end
  if frame.TabBar and frame.TabBar.pbTabBarBg then frame.TabBar.pbTabBarBg:SetAlpha(0) end

  QuietTemplateArt(frame)
  -- Registered before the paint, so a window built while the options panel
  -- is open is on the list the next appearance change walks.
  Skin._windows[frame] = true
  PaintWindow(frame)
  SeatTitleBar(frame)
  FlatClose(frame.CloseButton)
  frame.__pbTooltipOwner = true
  HookTooltips()
  if tipState.sensor then
    frame:HookScript("OnShow", WindowShown)
    frame:HookScript("OnHide", WindowHidden)
    if frame:IsShown() then WatchTooltips(true) end
  end

  -- The window tabs: the mockups' plates, drawn by the Theme from tokens of
  -- their own (Theme.SetPlateTokens), so hover and selection still run
  -- through the plate's own state.
  if frame.TabButtons and ns.Theme and ns.Theme.SetPlateTokens then
    for _, tab in pairs(frame.TabButtons) do
      if tab and not tab.__postboxSkinned then
        tab.__postboxSkinned = true
        ns.Theme.SetPlateTokens(tab, TAB_TOKENS)
      end
    end
  end

  Skin.Refresh(frame)
  -- The plates under the window's own text (Theme.OnWindow) stand on the
  -- window, whose own textures QuietTemplateArt has just faded: shown again
  -- where their window needs them.
  if ns.Theme and ns.Theme.RepaintTextPlates then ns.Theme.RepaintTextPlates() end
end

-- Postbox's secondary windows (options, Mail Memory, groups, recipients, the
-- bug report): the same shell, with no tabs of their own.
Skin.ApplyWindow = Skin.Apply

-- A plate drawn as a window tab (the options panel's tabs): the window tabs'
-- tokens, which a palette change rewrites in place (a creative style's own
-- tab tokens, under one).
function Skin.StyleTabPlate(plate)
  if not (plate and ns.Theme and ns.Theme.SetPlateTokens) then return end
  local CS = Creative() and ns.CreativeStyles
  local def = CS and type(CS.Active) == "function" and CS.Active() or nil
  ns.Theme.SetPlateTokens(plate, (def and def.tabs) or TAB_TOKENS)
end

return Skin
end

-------------------------------------------------------------
-- Claim: only when the style choice asks for it
-------------------------------------------------------------

-- The skin, built the first time it is asked for (a creative style's claim
-- asks, Core/Skin_Creative.lua), and the builder let go once it has run. nil
-- for a look whose login let the builder go unrun.
function ns.GetPostboxSkin()
  if not ns.PostboxSkin and BuildSkin then
    BuildSkin()
    BuildSkin = nil
  end
  return ns.PostboxSkin
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
  self:UnregisterEvent("PLAYER_LOGIN")

  local UI = ns.MailboxUI
  if not (UI and type(UI.GetStyleChoice) == "function") then return end
  local choice = UI.GetStyleChoice()
  if choice == "blizzard" or choice == "host" then
    -- A look that never wears this skin, whatever happens later this session
    -- (a style change is a reload): the builder goes, and its code with it.
    -- A host UI's look is its own skin, or the Blizzard look when that skin
    -- stands down; a creative style keeps the builder for its claim.
    BuildSkin = nil
    return
  end
  if choice ~= "postbox" then return end

  -- No race with the host skins: reaching here means the player chose this
  -- style, and both consult UI.HostSkinAllowed() before claiming. The ns.Skin
  -- guard stays for the ordinary case of something else having claimed first.
  if ns.Skin then return end
  local Skin = ns.GetPostboxSkin()
  if not Skin then return end
  ns.Skin = Skin
  local T = ns.Theme
  -- What is painted from a token, a grey or the chrome ink is kept from now
  -- on, so a palette change can paint it again; and every text's ink is
  -- worked out from the ground it stands on (Theme section 2c).
  if T and type(T.TrackPaint) == "function" then T.TrackPaint() end
  if T and type(T.UseGrounds) == "function" then T.UseGrounds(true) end
  -- The palette the settings name, before the first window is built.
  Skin._ResolveLook()
end)
