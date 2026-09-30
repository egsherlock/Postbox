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
-- difference table).
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
-- so a control stays legible at any opacity.
--
-- Claimed once, at PLAYER_LOGIN, when the style choice is "postbox"; changing
-- the style asks for a /reload.
-- =====================================================================

local Skin = {}
Skin.IsPostboxStyle = true

local WHITE = "Interface\\AddOns\\Postbox\\Media\\white8x8.tga"
local FONT_DIR = "Interface\\AddOns\\Postbox\\Media\\Fonts\\"

local floor, max, min = math.floor, math.max, math.min

local function Hex(h, a)
  local r = tonumber((h:sub(1, 2)), 16) / 255
  local g = tonumber((h:sub(3, 4)), 16) / 255
  local b = tonumber((h:sub(5, 6)), 16) / 255
  return { r, g, b, a or 1 }
end

-------------------------------------------------------------
-- The palette
--
-- Every value this style paints with, by name, and nothing painted from a
-- literal. The options' colour rows (accent, surface, border tone, stripes)
-- write their choice into this table and repaint; until they exist it holds
-- the defaults, which are the mockups' and EllesmereUI's in-game values.
-------------------------------------------------------------

local P = {
  -- The accent: Postbox gold, answered through Skin.GetAccent, so it is the
  -- one Theme.GetAccent hands every control.
  accent      = Hex("d3a44a"),
  -- The window: the fill (its alpha is the opacity setting, 90% by default)
  -- and the title strip over its top, black at half strength, faded with it.
  window      = Hex("0a0b0b"),
  opacity     = 0.90,
  strip       = { 0, 0, 0, 0.50 },
  stripHeight = 25,
  titleSize   = 15,
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
  buttonHover = 0.10,
  select      = Hex("141414", 0.92),
  selectEdge  = Hex("404040"),
  caret       = Hex("8c8c8c"),
  check       = Hex("050505"),
  checkEdge   = Hex("404040"),
  checkBox    = 18,
  close       = { 1, 1, 1, 0.75 },
  tooltip     = Hex("080809", 0.96),
  tooltipEdge = Hex("3a3a3a"),
}
Skin.Palette = P

-- The segments, tiles and the options' tabs: Postbox's plates as in every
-- look, their ring from the mockups (concept C) -- solid greys rising with
-- state instead of a white at three alphas. The fills and the accent wash stay
-- the Theme's ladder.
local PLATE_RINGS = {
  plateEdge         = Hex("3e3e3e"),
  plateEdgeHover    = Hex("555555"),
  plateEdgeSelected = Hex("6c6c6c"),
}

-- The window tabs: the mockups' plates, which are EllesmereUI's in game --
-- dark idle, a lighter plate selected, a ring each, no bevel, no wash, the
-- 2-pixel accent underline -- and a dimmer idle caption than a segment's.
local TAB_TOKENS = {
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
  captionToken      = "tabCaption",
}

local function Accent()
  if ns.Theme and ns.Theme.GetAccent then return ns.Theme.GetAccent() end
  return P.accent[1], P.accent[2], P.accent[3]
end

function Skin.GetAccent()
  return P.accent[1], P.accent[2], P.accent[3]
end

-- The ground a popup's floor is laid in (Theme's popup opacity floor).
function Skin.GetHostBaseline()
  return P.window[1], P.window[2], P.window[3]
end

-- One physical pixel at this frame's scale, not one UI unit: at a UI scale
-- that is not a whole ratio of the screen, a "1" edge lands on a fraction of a
-- pixel and each side rounds on its own, so one border renders 1 px on one
-- side and 2 on the other. Snapped, every edge is the same weight.
local function Hairline(frame)
  local scale = (frame and frame.GetEffectiveScale and frame:GetEffectiveScale()) or 1
  if PixelUtil and PixelUtil.GetNearestPixelSize then
    local ok, size = pcall(PixelUtil.GetNearestPixelSize, 1, scale, 1)
    if ok and type(size) == "number" and size > 0 then return size end
  end
  if scale > 0 then return max(1, floor(scale + 0.5)) / scale end
  return 1
end

local function GetProfile()
  return ns.Store.EnsurePath("profile", {})
end

-------------------------------------------------------------
-- Appearance settings
--
-- The contract Core/OptionsPanel.lua builds its rows from, as the other skins
-- publish it: a border and an opacity. Every accessor reads nil as the
-- default, so Reset to defaults (which clears the profile) needs nothing here
-- but the repaint. Saved under profile: pbBorder, pbBorderTone, pbOpacity,
-- pbFont, pbTextScale.
-------------------------------------------------------------

local BORDER_ORDER = { "none", "thin", "thick" }
local BORDER_NAME_KEY = { none = "OPT_BORDER_NONE", thin = "OPT_BORDER_THIN", thick = "OPT_BORDER_THICK" }
local DEFAULT_BORDER = "thin"
local DEFAULT_TONE = "gray"

function Skin.GetBorderChoices()
  local out = {}
  for i = 1, #BORDER_ORDER do
    local key = BORDER_ORDER[i]
    out[i] = { key = key, name = ns.L[BORDER_NAME_KEY[key]] }
  end
  return out
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

-- The inner line's tone: Black, Dark, Gray (default) or Light.
function Skin.GetBorderTone()
  local saved = GetProfile().pbBorderTone
  if P.borderTone[saved] then return saved end
  return DEFAULT_TONE
end

function Skin.GetBgOpacity()
  local saved = tonumber((GetProfile().pbOpacity))
  if saved then return max(0, min(1, saved)) end
  return P.opacity
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

-- The face Theme.HostFont dresses its copies in: the file (false: each game
-- object's own), the flags and the shadow (false and nil: the object's own),
-- and the size factor.
function Skin.GetFontFace()
  return FontPath(Skin.GetFont()), false, nil, Skin.GetTextScale()
end

-- Window titles are set at a size of their own (15), so they are re-dressed
-- here rather than following a copy. Weak-keyed: a title goes with its window.
local titles = setmetatable({}, { __mode = "k" })

local function DressTitle(fs)
  local base = titles[fs]
  if not base then return end
  local path = FontPath(Skin.GetFont()) or base.path
  pcall(fs.SetFont, fs, path, P.titleSize * Skin.GetTextScale(), base.flags or "")
  fs:SetTextColor(1, 1, 1, 1)
end

local function AdoptTitle(fs)
  if not fs or titles[fs] or type(fs.GetFont) ~= "function" then return end
  local path, _, flags = fs:GetFont()
  if type(path) ~= "string" or path == "" then path = STANDARD_TEXT_FONT end
  titles[fs] = { path = path, flags = flags }
  DressTitle(fs)
end

-- A change of font or text size: the copies re-dressed (which forgets every
-- fitted width), the titles, then the screens that fit text to its width
-- measured again. A rare, deliberate action; nothing here runs otherwise.
function Skin.ApplyFonts()
  local T = ns.Theme
  if T and type(T.RefreshHostFonts) == "function" then T.RefreshHostFonts() end
  for fs in pairs(titles) do pcall(DressTitle, fs) end
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

local function HideRegions(holder)
  if not holder then return end
  local regions = { holder:GetRegions() }
  for i = 1, #regions do
    local region = regions[i]
    if region.IsObjectType and region:IsObjectType("Texture") then region:SetAlpha(0) end
  end
end

-------------------------------------------------------------
-- The window shell: fill, title strip, keyline, close button
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
-- paint, which is where a new scale or a new weight arrives.
local SIDES = { "TOP", "BOTTOM", "LEFT", "RIGHT" }

local function LayKeyline(frame, lines, inset, width)
  for i = 1, 4 do
    local side, line = SIDES[i], lines[i]
    line:ClearAllPoints()
    if side == "TOP" then
      line:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset)
      line:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -inset, -inset)
      line:SetHeight(width)
    elseif side == "BOTTOM" then
      line:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", inset, inset)
      line:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
      line:SetHeight(width)
    elseif side == "LEFT" then
      line:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset)
      line:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", inset, inset)
      line:SetWidth(width)
    else
      line:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -inset, -inset)
      line:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
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

-- The window's fill, strip and keyline from the current settings.
local function PaintWindow(frame)
  local shell = EnsureShell(frame)
  local opaque = frame.__pbEuiAlwaysOpaque and true or false
  local color = opaque and P.opaque or P.window
  local alpha = opaque and P.opaque[4] or Skin.GetBgOpacity()
  shell.fill:SetColorTexture(color[1], color[2], color[3], alpha)
  -- The strip fades with the window: its own half strength times the fill's.
  local s = P.strip
  shell.strip:SetColorTexture(s[1], s[2], s[3], s[4] * alpha)

  local border = Skin.GetBorderStyle()
  local unit = Hairline(frame)
  local show = border ~= "none"
  local tone = P.borderTone[Skin.GetBorderTone()] or P.borderTone.gray
  local o = P.keyOuter
  LayKeyline(frame, shell.outer, 0, unit)
  LayKeyline(frame, shell.inner, unit, (border == "thick") and 2 * unit or unit)
  for i = 1, 4 do
    shell.outer[i]:SetColorTexture(o[1], o[2], o[3], o[4])
    shell.inner[i]:SetColorTexture(tone[1], tone[2], tone[3], tone[4])
    shell.outer[i]:SetShown(show)
    shell.inner[i]:SetShown(show)
  end
end

function Skin.ApplyAppearance()
  for frame in pairs(Skin._windows) do
    if frame then pcall(PaintWindow, frame) end
  end
end

-- The window scale moved: every one-pixel edge is a pixel of the new scale,
-- so each painted block is painted again, then the windows.
function Skin.ApplyScale()
  for frame, fill in pairs(paintedFill) do
    local edge = paintedEdge[frame]
    if frame and edge then pcall(Paint, frame, fill, edge) end
  end
  Skin.ApplyAppearance()
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

-- The house X, white at three quarters and full under the pointer: the
-- client's close atlas where it has one, else two rotated bars of the white
-- tile.
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
  local c = P.close
  local function Tint(a)
    for i = 1, #marks do marks[i]:SetVertexColor(c[1], c[2], c[3], a) end
  end
  Tint(c[4])
  button:HookScript("OnEnter", function() Tint(1) end)
  button:HookScript("OnLeave", function() Tint(c[4]) end)
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

-- The value of a select, in the accent's text tone: a font object of its own
-- (a copy of the game's button font, recoloured), which the host-font copies
-- dress in the chosen face. A button puts its state's font back on its label
-- at every enable and disable, so the colour lives on the object.
local selectFont

local function SelectFont()
  if selectFont ~= nil then return selectFont or nil end
  local base = _G.GameFontNormal
  if type(CreateFont) ~= "function" or not base then selectFont = false return nil end
  local font = CreateFont("PostboxSelectValue")
  if not font then selectFont = false return nil end
  if type(font.CopyFontObject) == "function" then pcall(font.CopyFontObject, font, base) end
  local r, g, b = 1, 0.82, 0
  if ns.Theme and ns.Theme.GetAccentTone then r, g, b = ns.Theme.GetAccentTone("text") end
  if type(font.SetTextColor) == "function" then font:SetTextColor(r, g, b) end
  selectFont = font
  return font
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
    hover:SetVertexColor(1, 1, 1, 1)
    hover:SetAlpha(P.buttonHover)
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
    end
  end
  -- The button's own state fonts in the chosen face (Theme.HostFontButton).
  if T and type(T.HostFontButton) == "function" then pcall(T.HostFontButton, button) end
end

-- A checkbox: a flat box with a one-pixel edge, and the house tick (the
-- mockups' own mark) in the accent.
local checks = setmetatable({}, { __mode = "k" })

local function PaintTick(cb)
  local tick = cb.GetCheckedTexture and cb:GetCheckedTexture()
  if tick then tick:SetVertexColor(Accent()) end
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
  if disabledTick then disabledTick:SetVertexColor(0.56, 0.56, 0.56, 1) end
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
    thumb:SetColorTexture(1, 1, 1, 0.30)
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

local function SkinTree(frame, depth, opaque)
  if not frame or depth > 8 then return end
  local kids = { frame:GetChildren() }
  for i = 1, #kids do
    local c = kids[i]
    if c and c.IsObjectType then
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
    SkinTree(c, depth + 1, opaque)
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

-- The accent moved (the accent row, when it exists): the ticks, the select
-- values, the plates and the accent-toned text and icons.
function Skin.RefreshAccents()
  for cb in pairs(checks) do pcall(PaintTick, cb) end
  local font = selectFont
  if font and ns.Theme and ns.Theme.GetAccentTone then
    local r, g, b = ns.Theme.GetAccentTone("text")
    font:SetTextColor(r, g, b)
    local copy = ns.Theme.HostFont and ns.Theme.HostFont(font)
    if copy and copy ~= font then copy:SetTextColor(r, g, b) end
  end
  local T = ns.Theme
  if T then
    if T.RepaintAccentText then T.RepaintAccentText() end
    if T.RepaintAccentIcons then T.RepaintAccentIcons() end
    if T.RepaintPlates then
      for frame in pairs(Skin._windows) do pcall(T.RepaintPlates, frame, 0) end
    end
  end
end

-------------------------------------------------------------
-- Tooltips
--
-- Postbox's own tooltips arrive on the shared GameTooltip. On a stock UI it
-- stays Blizzard's, which beside a flat black window looks like a leftover,
-- so while the tooltip belongs to Postbox its art steps aside for this
-- style's fill and edge, and steps straight back for every other tooltip in
-- the game. Nothing is destroyed. Under a host UI the tooltip is that UI's
-- and is never touched.
-------------------------------------------------------------

local function IsOurs(owner)
  local frame = owner
  for _ = 1, 6 do
    if type(frame) ~= "table" then return false end
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
  local wasDressed = tip.__pbDressed
  if not ours and not wasDressed then return end
  tip.__pbDressed = ours or nil

  if not tip.__pbPostboxTip then
    tip.__pbPostboxTip = true
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
    tip.__pbFill = fill
    tip.__pbEdges = edges
  end

  tip.__pbFill:SetShown(ours)
  for i = 1, #tip.__pbEdges do tip.__pbEdges[i]:SetShown(ours) end
  if tip.NineSlice then
    if ours then
      if not wasDressed then tip.__pbNineShown = tip.NineSlice:IsShown() end
      tip.NineSlice:Hide()
    else
      tip.NineSlice:SetShown(tip.__pbNineShown ~= false)
    end
  end
end

local tooltipHooked = false
local function HookTooltips()
  if tooltipHooked or type(hooksecurefunc) ~= "function" then return end
  -- GameTooltip is shared, and a host UI skins it for the whole interface:
  -- choosing this style is a statement about Postbox's windows, not a licence
  -- to restyle a frame the rest of the interface also uses.
  if _G.EllesmereUI or _G.ElvUI then return end
  tooltipHooked = true
  hooksecurefunc(GameTooltip, "SetOwner", function(self, owner)
    DressTooltip(self, IsOurs(owner))
  end)
  GameTooltip:HookScript("OnHide", function(self)
    DressTooltip(self, false)
  end)
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
end

-- Postbox's secondary windows (options, Mail Memory, groups, recipients, the
-- bug report): the same shell, with no tabs of their own.
Skin.ApplyWindow = Skin.Apply

-------------------------------------------------------------
-- Claim: only when the style choice asks for it
-------------------------------------------------------------

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
  self:UnregisterEvent("PLAYER_LOGIN")

  local UI = ns.MailboxUI
  if not (UI and type(UI.GetStyleChoice) == "function") then return end
  if UI.GetStyleChoice() ~= "postbox" then return end

  -- No race with the host skins: reaching here means the player chose this
  -- style, and both consult UI.HostSkinAllowed() before claiming. The ns.Skin
  -- guard stays for the ordinary case of something else having claimed first.
  if ns.Skin then return end
  ns.Skin = Skin
  -- The style's plate rings, into the palette every plate paints from.
  if ns.Theme and type(ns.Theme.OverridePalette) == "function" then
    ns.Theme.OverridePalette(PLATE_RINGS)
  end
end)
