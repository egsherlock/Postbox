local _, ns = ...

-- =====================================================================
-- Postbox :: the "Blizzard" window style (first-party skin, chosen in options)
-- ---------------------------------------------------------------------
-- The game's own window, built from the game's own art on Postbox's own
-- frames: the metal frame the game's windows wear without a portrait, the
-- rock ground under the title streaks, the red close button, the title in
-- the game's gold, and the sunken inset under every list and card. Every
-- piece is asked for by the game's atlas name or file path, so a UI pack
-- that replaces the game's art replaces it here too (the 1.19.1 decision,
-- Lib/UI/Theme.lua), and WoW Forever draws its own bronze twins: the client
-- swaps an atlas to its bronze member by itself when the plain name is
-- asked for, and its NineSlice layouts carry its own offsets.
--
-- A SKIN, like Core/Skin_Postbox.lua: it claims ns.Skin at PLAYER_LOGIN,
-- only when the style choice is "blizzard", and rides the same contract
-- (Apply / ApplyWindow / Refresh / RefreshWindow over the tagged children).
-- Any other choice never claims it, so the Postbox style, EllesmereUI and
-- ElvUI run exactly the code they ran before this file existed. A host
-- skin standing down (EllesmereUI on its Blizzard or Classic look, an
-- opt-out) leaves ns.Skin unclaimed as before: that look is unchanged.
--
-- It answers only what it dresses. Everything a skin may publish and this
-- one does not (GetAccent, GetHostBaseline, GetFontFace, StyleTabPlate,
-- ButtonTextRGB, the appearance getters, ApplyLook...) is asked for by
-- presence, so leaving it out keeps the game's own answer, as when no skin
-- claimed. The places that read "no skin" as "the game's own look" ask
-- Theme.NativeLook() instead, which says yes for this skin too.
--
-- A surface treatment only: no frame moves or changes size, and nothing is
-- shown, hidden or created in combat that is not already. Each frame is
-- dressed once and tagged; a walk over a window finds work only where
-- something new was tagged since the last one.
--
-- Dressed so far: the window frame, the sunken panels, the main window's
-- Mail and Send tabs, every push button, the Mail tab's totals strip and
-- every field and search box, and every list's scroll bar. The options'
-- tabs, other plates, joined cells, other bands, dropdowns and rows draw
-- as they did.
-- =====================================================================

local Skin = {}
Skin.IsBlizzardStyle = true
ns.BlizzardSkin = Skin

-------------------------------------------------------------
-- Art, by name
-------------------------------------------------------------

-- The game's frame without a portrait (ButtonFrameTemplate with its
-- portrait hidden, DefaultPanelTemplate, the Settings panel).
local FRAME_LAYOUT = "ButtonFrameTemplateNoPortrait"
local FRAME_ATLASES = {
  "UI-Frame-Metal-CornerTopLeft", "UI-Frame-Metal-CornerTopRight",
  "UI-Frame-Metal-CornerBottomLeft", "UI-Frame-Metal-CornerBottomRight",
  "_UI-Frame-Metal-EdgeTop", "_UI-Frame-Metal-EdgeBottom",
  "!UI-Frame-Metal-EdgeLeft", "!UI-Frame-Metal-EdgeRight",
}
local STREAKS = "_UI-Frame-TopTileStreaks"

-- BasicFrameTemplate(WithInset)'s own art, by its parent keys: the thin
-- frame and its title tile (where the metal replaces them), and the ground
-- under the rock layer Postbox lays: the template's own rock, its streaks,
-- and the marble inset with its bevel, which stands over Postbox's rock.
-- Faded, never hidden or taken off the frame, so a key someone anchors to
-- stays put.
-- The title tile in particular: the Postbox window centres its title on it.
local TEMPLATE_FRAME = {
  "TopLeftCorner", "TopRightCorner", "TopBorder",
  "BotLeftCorner", "BotRightCorner", "BottomBorder", "LeftBorder", "RightBorder", "TitleBg",
}
local TEMPLATE_GROUND = {
  "Bg", "TopTileStreaks",
  "InsetBg", "InsetBorderTopLeft", "InsetBorderTopRight", "InsetBorderBottomLeft",
  "InsetBorderBottomRight", "InsetBorderTop", "InsetBorderBottom", "InsetBorderLeft", "InsetBorderRight",
}

-- The game's inset bevel (InsetFrameTemplate's art): four 6-unit corners and
-- four 3-unit tiles, the same pieces on both clients (they have no bronze
-- twin), so they are laid here directly rather than through NineSliceUtil:
-- point, atlas, tiles across / down.
local INSET = {
  { key = "TopLeft", atlas = "UI-Frame-InnerTopLeft", point = "TOPLEFT" },
  { key = "TopRight", atlas = "UI-Frame-InnerTopRight", point = "TOPRIGHT" },
  { key = "BottomLeft", atlas = "UI-Frame-InnerBotLeftCorner", point = "BOTTOMLEFT" },
  { key = "BottomRight", atlas = "UI-Frame-InnerBotRight", point = "BOTTOMRIGHT" },
}
-- Each tile between two corners: its two points on them, so the corners set
-- its length and the art its thickness.
local INSET_EDGES = {
  { atlas = "_UI-Frame-InnerTopTile", across = true,
    "TOPLEFT", "TopLeft", "TOPRIGHT", "TOPRIGHT", "TopRight", "TOPLEFT" },
  { atlas = "_UI-Frame-InnerBotTile", across = true,
    "BOTTOMLEFT", "BottomLeft", "BOTTOMRIGHT", "BOTTOMRIGHT", "BottomRight", "BOTTOMLEFT" },
  { atlas = "!UI-Frame-InnerLeftTile", across = false,
    "TOPLEFT", "TopLeft", "BOTTOMLEFT", "BOTTOMLEFT", "BottomLeft", "TOPLEFT" },
  { atlas = "!UI-Frame-InnerRightTile", across = false,
    "TOPRIGHT", "TopRight", "BOTTOMRIGHT", "BOTTOMRIGHT", "BottomRight", "TOPRIGHT" },
}

-- The 1px backdrop's edge pieces (BackdropTemplateMixin's keys): faded under
-- the bevel, which takes their place. Faded rather than recoloured, so the
-- Theme recolouring the backdrop later never brings the line back.
local BACKDROP_EDGES = {
  "TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner",
  "TopEdge", "BottomEdge", "LeftEdge", "RightEdge",
}

local function HasAtlas(name)
  local T = ns.Theme
  if T and type(T.AtlasExists) == "function" then return T.AtlasExists(name) end
  return false
end

-- SetAtlas, only for an atlas this client has: a missing piece is left
-- blank, never an error.
local function Atlas(texture, name, useSize)
  if not HasAtlas(name) then return false end
  return pcall(texture.SetAtlas, texture, name, useSize and true or false) and true or false
end

local function Fade(region)
  if region and type(region.SetAlpha) == "function" then region:SetAlpha(0) end
end

-- The controls this skin dresses, one entry per kind (the Mail and Send
-- tabs, push buttons, the totals strip, fields, scroll bars), each made in
-- a section of its own below and called by the walk at call time. One table,
-- so the sections add no chunk locals.
local Parts = {}

-- An atlas's own size in units, asked once per name and kept: art is laid
-- by the client's own size for it (a bronze twin can differ), never by
-- retail's numbers. nil where the client does not have it.
do
  local widths, heights = {}, {}
  function Parts.Size(name)
    local w = widths[name]
    if w == nil then
      w, heights[name] = false, false
      local get = C_Texture and C_Texture.GetAtlasInfo
      if type(get) == "function" then
        local ok, info = pcall(get, name)
        if ok and type(info) == "table" and type(info.width) == "number" and info.width > 0
           and type(info.height) == "number" and info.height > 0 then
          w, heights[name] = info.width, info.height
        end
      end
      widths[name] = w
    end
    if not w then return nil end
    return w, heights[name]
  end
end

-- A game font's colour: GameFontNormal's gold, GameFontHighlight's white,
-- as the client (or a UI pack) has them, else the stock values given.
function Parts.FontRGB(name, r, g, b)
  local font = _G[name]
  if font and type(font.GetTextColor) == "function" then
    local fr, fg, fb = font:GetTextColor()
    if type(fr) == "number" and type(fg) == "number" and type(fb) == "number" then return fr, fg, fb end
  end
  return r, g, b
end

-------------------------------------------------------------
-- The window frame
-------------------------------------------------------------

-- Postbox's windows are BasicFrameTemplateWithInset frames, and that
-- template has no NineSlice to restyle: its frame is eight loose textures in
-- the thin pre-metal style (it has no NineSlice and no Inset frame on either
-- client; Interface/AddOns/Blizzard_UIPanelTemplates, BaseBasicFrameTemplate).
-- So its art is faded and the metal frame is laid by the game's own
-- NineSliceUtil, which carries Forever's own offsets for the bronze pieces
-- (its NineSliceLayouts are adjusted at load there), on pieces Postbox owns.
--
-- The pieces are textures of the window itself, in its BORDER layer: over
-- its rock, under its title and status text (OVERLAY), and under every
-- child frame (the content, the cog, the close button), as the game's metal
-- sits under the title of its own windows. NineSliceUtil anchors each piece
-- to the container it is given; the container is an empty frame over the
-- window that hands NineSliceUtil the window's own textures through
-- GetNineSlicePiece, so no texture of the frame is ever re-keyed and the
-- template's own TopLeftCorner / TopRightCorner fields stay its own.
local function LayFrame(frame)
  local util = _G.NineSliceUtil
  if type(util) ~= "table" or type(util.ApplyLayoutByName) ~= "function" then return false end
  if type(util.GetLayout) == "function" and not util.GetLayout(FRAME_LAYOUT) then return false end
  for i = 1, #FRAME_ATLASES do
    if not HasAtlas(FRAME_ATLASES[i]) then return false end
  end
  local holder = CreateFrame("Frame", nil, frame)
  holder:SetAllPoints(frame)
  holder.layoutTextureLayer = "BORDER"
  holder.__pbPieces = {}
  function holder:GetNineSlicePiece(name)
    local piece = self.__pbPieces[name]
    if not piece then
      piece = frame:CreateTexture(nil, "BORDER")
      self.__pbPieces[name] = piece
    end
    return piece
  end
  local ok = pcall(util.ApplyLayoutByName, holder, FRAME_LAYOUT)
  if not ok then
    for _, piece in pairs(holder.__pbPieces) do Fade(piece) end
    return false
  end
  frame.__pbBlizzFrame = holder
  return true
end

-- The rock as the game lays it: untinted, the game's streaks across its
-- top. Postbox's own rock layer (Theme.ApplyFrameTheme's `pbWindowStone`)
-- is kept where it stands, so nothing in the window moves; its warm wash
-- goes.
local function LayGround(frame)
  local stone = frame.pbWindowStone
  if stone then stone:SetVertexColor(1, 1, 1, 1) end
  Fade(frame.pbWindowTint)
  if not stone or not HasAtlas(STREAKS) then return end
  local streaks = frame:CreateTexture(nil, "BACKGROUND", nil, -6)
  if not Atlas(streaks, STREAKS, true) then return end
  streaks:SetHorizTile(true)
  -- As PortraitFrameTexturedBaseTemplate lays them: four units in from the
  -- rock's left edge, to its right edge, on its top.
  streaks:SetPoint("TOPLEFT", stone, "TOPLEFT", 4, 0)
  streaks:SetPoint("TOPRIGHT", stone, "TOPRIGHT", 0, 0)
  frame.__pbBlizzStreaks = streaks
end

-------------------------------------------------------------
-- Sunken panels
-------------------------------------------------------------

-- A list or card that stands in a window this skin dressed: not a popup
-- (one with the popup floor, or the dropdown's list), not a field (an
-- input's wrap is a card too), not a button (the options' feature tiles
-- paint their own edge on hover). Popups float; only what sits in the
-- window is sunk into it.
local function DressedWindowOf(frame)
  local f = frame
  for _ = 1, 14 do
    if not f then return nil end
    if f.__pbBlizzWindow then return f end
    f = f.GetParent and f:GetParent() or nil
  end
  return nil
end

-- A frame's strata, or nil where it has none to read: on WoW Forever
-- GetFrameStrata can answer a secret value, which can't be compared
-- (Theme's StrataOf, the popup floor's test, reads it the same way).
local function StrataOf(frame)
  if type(frame.GetFrameStrata) ~= "function" then return nil end
  local strata = frame:GetFrameStrata()
  if type(issecretvalue) == "function" and issecretvalue(strata) then return nil end
  if type(strata) ~= "string" then return nil end
  return strata
end

-- A card that floats over its window (a toplevel one, or one raised to a
-- strata of its own, as the type-ahead list is) is a popup whether or not
-- the popup floor was laid under it yet.
local function Sinks(c)
  local tag = c.__postboxPanel
  if tag ~= "list" and tag ~= "card" then return false end
  if c.__postboxInputWrap or c.__pbPopupFloor or c.__pbPopupAlways then return false end
  if c:IsObjectType("Button") then return false end
  if type(c.IsToplevel) == "function" and c:IsToplevel() then return false end
  local window = DressedWindowOf(c)
  if not window then return false end
  local mine, theirs = StrataOf(c), StrataOf(window)
  if mine and theirs and mine ~= theirs then return false end
  return true
end

-- The bevel on the panel's own BORDER layer, over its dark ground and its
-- grain, under everything the panel holds; the 1px edge it replaces faded.
local function SinkPanel(c)
  if c.__pbBlizzInset then return end
  c.__pbBlizzInset = true
  local corners = {}
  for i = 1, #INSET do
    local spec = INSET[i]
    local t = c:CreateTexture(nil, "BORDER", nil, 7)
    if not Atlas(t, spec.atlas, true) then t:Hide() end
    t:SetPoint(spec.point, c, spec.point, 0, 0)
    corners[spec.key] = t
  end
  for i = 1, #INSET_EDGES do
    local spec = INSET_EDGES[i]
    local t = c:CreateTexture(nil, "BORDER", nil, 7)
    if Atlas(t, spec.atlas, true) then
      if spec.across then t:SetHorizTile(true) else t:SetVertTile(true) end
      t:SetPoint(spec[1], corners[spec[2]], spec[3], 0, 0)
      t:SetPoint(spec[4], corners[spec[5]], spec[6], 0, 0)
    else
      t:Hide()
    end
  end
  for i = 1, #BACKDROP_EDGES do Fade(c[BACKDROP_EDGES[i]]) end
end

-------------------------------------------------------------
-- The Mail and Send tabs
-------------------------------------------------------------

-- The game's tab art turned to open downward, as PanelTopTabButtonTemplate
-- turns it (the Macro window, the Auction House), laid as textures on
-- Postbox's own plate: the template itself is never made (its mixin sizes
-- the tab to its text; Core/Theme.lua, section 7). The closed tab is the
-- client's own (bronze on WoW Forever), the open one the gold.
--
-- Laid by its rim, not its texture box (measured from both clients' art,
-- the same on each): the closed end carries 7 units of soft shadow past its
-- rim, the sides 3 and 7 (closed) or 2 and 8 (open), the template's own -3 /
-- +7 offsets. So the rim meets the plate's top and sides, the shadow falls
-- outside it, and the joining end is trimmed at the plate's foot: the art
-- shows its closed end and the plate's height of its body, nothing more.
-- The plate keeps its size, its hit rectangle and its clicks.
do
  local SHADOW = 7
  local SETS = {
    rest = { "uiframe-tab-left", "_uiframe-tab-center", "uiframe-tab-right", l = 3, r = 7 },
    open = { "uiframe-activetab-left", "_uiframe-activetab-center", "uiframe-activetab-right", l = 2, r = 8 },
  }
  -- The game's Settings rule, across the window under the tabs: they stand
  -- on it. Eight units past the tabs at each end, as the mock-ups drew it.
  local DIVIDER, DIVIDER_RUN = "Options_HorizontalDivider", 8

  -- Three pieces in `layer`, or nil (and nothing made) where the client
  -- lacks one.
  local function Lay(tab, set, layer)
    for i = 1, 3 do
      if not HasAtlas(set[i]) then return nil end
    end
    local plateH = tab:GetHeight()
    if type(plateH) ~= "number" or plateH <= 0 then plateH = 28 end
    local keep = plateH + SHADOW
    local pieces = {}
    for i = 1, 3 do
      local t = tab:CreateTexture(nil, layer)
      Atlas(t, set[i], false)
      -- Turned over (the closed end on top) and trimmed at the joining end
      -- to the plate's height plus the shadow, as a share of the art's own.
      local _, h = Parts.Size(set[i])
      local cut = h and (1 - keep / h) or 0
      if cut < 0 then cut = 0 end
      t:SetTexCoord(0, 1, 1, cut)
      pieces[i] = t
    end
    local L, M, R = pieces[1], pieces[2], pieces[3]
    L:SetWidth(Parts.Size(set[1]) or 35)
    L:SetPoint("TOPLEFT", tab, "TOPLEFT", -set.l, SHADOW)
    L:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", -set.l, 0)
    R:SetWidth(Parts.Size(set[3]) or 37)
    R:SetPoint("TOPRIGHT", tab, "TOPRIGHT", set.r, SHADOW)
    R:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", set.r, 0)
    M:SetPoint("TOPLEFT", L, "TOPRIGHT", 0, 0)
    M:SetPoint("BOTTOMRIGHT", R, "BOTTOMLEFT", 0, 0)
    return pieces
  end

  local function ShowAll(list, on)
    for i = 1, #list do list[i]:SetShown(on) end
  end

  -- The tab's whole look for its state, as the skin's selection override
  -- (Theme.SetPlateSelected hands it over and retires the plate's own
  -- art): the open art or the closed with its hover glow, and the caption
  -- in the game's gold at rest, white on the open tab. The dot mark rides
  -- in the caption's own colour escape and keeps its colour.
  local function PaintTab(tab, selected)
    local art = tab.__pbBlizzTab
    if not art then return end
    selected = selected and true or false
    ShowAll(art.open, selected)
    ShowAll(art.rest, not selected)
    ShowAll(art.glow, not selected)
    local text = tab.Text
    if text and type(text.SetTextColor) == "function" then
      if selected then
        text:SetTextColor(Parts.FontRGB("GameFontHighlight", 1, 1, 1))
      else
        text:SetTextColor(Parts.FontRGB("GameFontNormal", 1, 0.82, 0))
      end
    end
  end

  -- The main window's two tabs and the line under them, once.
  function Parts.Tabs(frame)
    local tabs = frame.TabButtons
    if type(tabs) ~= "table" or frame.__pbBlizzTabs then return end
    frame.__pbBlizzTabs = true
    local T = ns.Theme
    local dressed = false
    for _, tab in pairs(tabs) do
      if tab and not tab.__pbBlizzTab and type(tab.CreateTexture) == "function" then
        local rest = Lay(tab, SETS.rest, "BACKGROUND")
        local open = rest and Lay(tab, SETS.open, "BACKGROUND")
        if rest and open then
          -- The game's hover: the closed art again, added at 0.4.
          local glow = Lay(tab, SETS.rest, "HIGHLIGHT") or {}
          for i = 1, #glow do
            glow[i]:SetBlendMode("ADD")
            glow[i]:SetAlpha(0.4)
          end
          tab.__pbBlizzTab = { rest = rest, open = open, glow = glow }
          tab.__setSelectedOverride = PaintTab
          if T and type(T.SetPlateSelected) == "function" then
            T.SetPlateSelected(tab, tab.isSelected)
          else
            PaintTab(tab, tab.isSelected)
          end
          dressed = true
        elseif rest then
          ShowAll(rest, false)
        end
      end
    end
    local bar = frame.TabBar
    if not (dressed and bar and HasAtlas(DIVIDER)) then return end
    local line = frame:CreateTexture(nil, "ARTWORK")
    if not Atlas(line, DIVIDER, false) then return end
    local _, h = Parts.Size(DIVIDER)
    h = h or 1
    -- At least a screen pixel, so the line shows at any UI scale.
    local px = T and type(T.OnePixel) == "function" and T.OnePixel(frame) or 1
    if px > h then h = px end
    line:SetHeight(h)
    line:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", -DIVIDER_RUN, 0)
    line:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", DIVIDER_RUN, 0)
    frame.__pbBlizzTabLine = line
  end
end

-------------------------------------------------------------
-- Push buttons
-------------------------------------------------------------

-- Every push button (Theme.CreateButton: the game's UIPanelButtonTemplate)
-- wears the game's newer red button, ThreeSliceButtonTemplate's art,
-- drawn as ThreeSliceButtonMixin draws it: the end pieces scaled to the
-- button's height, cropped when the two ends are wider than the button, the
-- middle between them, the state's art on press and when disabled, the
-- game's glow on hover. On Postbox's own button: the template is never
-- made, and the button's own art is faded, never taken away (its scripts
-- still set it, unseen).
--
-- Laid by its rim (measured from both clients' art, the same on each): the
-- art carries 10 units of soft shadow round its face on every side, of its
-- 128, so it is drawn that much past the button's box and its rim meets the
-- box; the button keeps its size and its hit rectangle.
--
-- The dropdown boxes (also tagged as buttons) keep their look: a later step
-- gives them the game's dropdown.
do
  local RIM = 10 / 128
  -- ALL MAIL wears the gold-rimmed sister, to be judged in game: false here
  -- gives it the red one like the rest.
  local GOLD_ALL_MAIL = true

  -- Every name made once: no string is built when a state changes.
  local function Family(base)
    local names = { highlight = base .. "-Highlight" }
    local states = { up = "", down = "-Pressed", off = "-Disabled" }
    for state, suffix in pairs(states) do
      names[state] = { base .. "-Left" .. suffix, "_" .. base .. "-Center" .. suffix, base .. "-Right" .. suffix }
    end
    return names
  end
  local RED, GOLD = Family("128-RedButton"), Family("128-GoldRedButton")

  local STATES = { "up", "down", "off" }
  local function Has(names)
    if not HasAtlas(names.highlight) then return false end
    for s = 1, #STATES do
      local set = names[STATES[s]]
      for i = 1, 3 do
        if not HasAtlas(set[i]) then return false end
      end
    end
    return true
  end

  -- The pieces' size and crop for the button's present size, as
  -- ThreeSliceButtonMixin.UpdateScale does it, for an art box the rim's
  -- margin larger than the button all round.
  local function Fit(button)
    local art = button.__pbBlizzButton
    if not art then return end
    local w, h = button:GetWidth(), button:GetHeight()
    if type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then return end
    local set = art.names.up
    local lw, lh = Parts.Size(set[1])
    local rw = Parts.Size(set[3])
    if not (lw and lh and rw) then return end
    local artH = h / (1 - 2 * RIM)
    local m = artH * RIM
    local scale = artH / lh
    local boxW = w + 2 * m
    local leftW, rightW = lw * scale, rw * scale
    local newL, newR = leftW, rightW
    if leftW + rightW > boxW then
      local extra = leftW + rightW - boxW
      if leftW - extra > rightW then
        newL = leftW - extra
      elseif rightW - extra > leftW then
        newR = rightW - extra
      else
        if leftW ~= rightW then
          extra = extra - math.abs(leftW - rightW)
          newL = math.min(leftW, rightW)
          newR = newL
        end
        newL, newR = newL - extra / 2, newR - extra / 2
      end
    end
    local L, R = art[1], art[3]
    L:SetTexCoord(0, newL / leftW, 0, 1)
    L:SetSize(newL, artH)
    R:SetTexCoord(1 - newR / rightW, 1, 0, 1)
    R:SetSize(newR, artH)
    -- A cell standing at the button's left end (the Send tab's Sent clock,
    -- Parts.SentCell) while it is shown: the left end is the cell's, and
    -- the middle runs from the button's own edge.
    local joined = (art.cell ~= nil and art.cell:IsShown()) and true or false
    if art.m ~= m or art.joined ~= joined then
      art.m, art.joined = m, joined
      L:ClearAllPoints()
      L:SetPoint("TOPLEFT", button, "TOPLEFT", -m, m)
      R:ClearAllPoints()
      R:SetPoint("TOPRIGHT", button, "TOPRIGHT", m, m)
      local M = art[2]
      M:ClearAllPoints()
      if joined then
        M:SetPoint("TOPLEFT", button, "TOPLEFT", 0, m)
      else
        M:SetPoint("TOPLEFT", L, "TOPRIGHT", 0, 0)
      end
      M:SetPoint("BOTTOMRIGHT", R, "BOTTOMLEFT", 0, 0)
      L:SetShown(not joined and not art.hidden)
      local glow = art.glow
      if glow then
        glow:ClearAllPoints()
        glow:SetPoint("TOPLEFT", joined and M or L, "TOPLEFT", 0, 0)
        glow:SetPoint("BOTTOMRIGHT", R, "BOTTOMRIGHT", 0, 0)
      end
    end
  end

  -- The art for the button's state: disabled, pressed, or at rest.
  local function Paint(button)
    local art = button.__pbBlizzButton
    if not art then return end
    local state = "up"
    if not button:IsEnabled() then state = "off" elseif art.down or art.held then state = "down" end
    if art.state == state then return end
    art.state = state
    local set = art.names[state]
    for i = 1, 3 do Atlas(art[i], set[i], false) end
    -- The middle tiles across, as the template's does; SetAtlas sets the
    -- whole piece again, its crop and tiling with it.
    art[2]:SetHorizTile(true)
    Fit(button)
  end

  local function Down(button)
    local art = button.__pbBlizzButton
    if art and button:IsEnabled() then
      art.down = true
      Paint(button)
    end
  end

  local function Up(button)
    local art = button.__pbBlizzButton
    if art then
      art.down = false
      Paint(button)
    end
  end

  function Parts.Button(button)
    if button.__pbBlizzButton ~= nil then return end
    button.__pbBlizzButton = false
    local names = (GOLD_ALL_MAIL and button.gridId == "all") and GOLD or RED
    if not Has(names) then return end
    local art = { names = names, m = false }
    for i = 1, 3 do art[i] = button:CreateTexture(nil, "BACKGROUND", nil, 1) end
    art[2]:SetPoint("TOPLEFT", art[1], "TOPRIGHT", 0, 0)
    art[2]:SetPoint("BOTTOMRIGHT", art[3], "BOTTOMLEFT", 0, 0)
    button.__pbBlizzButton = art
    -- The template's own three pieces, faded under the new art.
    Fade(button.Left)
    Fade(button.Middle)
    Fade(button.Right)
    Paint(button)
    -- The game's glow over the whole art, as its template sets it.
    if pcall(button.SetHighlightAtlas, button, names.highlight) then
      local glow = button:GetHighlightTexture()
      if glow then
        glow:ClearAllPoints()
        glow:SetPoint("TOPLEFT", art[1], "TOPLEFT", 0, 0)
        glow:SetPoint("BOTTOMRIGHT", art[3], "BOTTOMRIGHT", 0, 0)
        art.glow = glow
      end
    end
    button:HookScript("OnMouseDown", Down)
    button:HookScript("OnMouseUp", Up)
    button:HookScript("OnShow", Up)
    button:HookScript("OnEnable", Paint)
    button:HookScript("OnDisable", Paint)
    button:HookScript("OnSizeChanged", Fit)
  end

  -- A switch that is a push button (the options' Test mail, Rows.Lead):
  -- its art held down while it is on, let go when it is off. -> true where
  -- the button wears this skin's art.
  function Parts.HoldButton(button, held)
    local art = button and button.__pbBlizzButton
    if not art then return false end
    held = held and true or false
    if art.held ~= held then
      art.held = held
      Paint(button)
    end
    return true
  end

  -- A switch drawn as a plate of its own that is the red button held down
  -- while it is on (Arrange's own Test mail): the art on `frame`, over its
  -- plate (whose fill and edges the caller fades), shown or put away.
  function Parts.HeldArt(frame, on)
    local art = frame.__pbBlizzButton
    if art == nil then
      frame.__pbBlizzButton = false
      if not Has(RED) then return false end
      art = { names = RED, m = false, held = true, hidden = false }
      for i = 1, 3 do art[i] = frame:CreateTexture(nil, "BORDER", nil, 7) end
      frame.__pbBlizzButton = art
      Paint(frame)
      frame:HookScript("OnSizeChanged", Fit)
    end
    if not art then return false end
    on = on and true or false
    art.hidden = not on
    art[1]:SetShown(on and not art.joined)
    art[2]:SetShown(on)
    art[3]:SetShown(on)
    return true
  end

  ---------------------------------------------------------------
  -- The Sent key as a cell of Send mail
  ---------------------------------------------------------------

  -- The Send tab's Sent clock (ST.BuildSentClock: a square plate of its
  -- own, left of the Send button, M.gap apart) drawn as a cell at the left
  -- end of Send mail's own red button: the button's left end on the clock,
  -- its middle on through the gap to the button, a dark line a unit wide
  -- between the cell and the caption, the clock in the game's gold (white
  -- under the pointer). Art only: the clock keeps its own frame, size,
  -- click, tooltip and its hiding while History is off; hidden, Send mail
  -- is whole again (Fit reads it). Pressed, the cell's part of the art is
  -- the pressed art; the button's part follows the button.
  local CELL_LINE = 2

  local function PaintCell(clock)
    local cell = clock.__pbBlizzCell
    if not cell then return end
    local state = cell.down and "down" or "up"
    if cell.state ~= state then
      cell.state = state
      local set = cell.names[state]
      Atlas(cell[1], set[1], false)
      Atlas(cell[2], set[2], false)
      cell[2]:SetHorizTile(true)
      cell.fit = nil
    end
    if not cell.fit then
      local h = clock:GetHeight()
      local lw, lh = Parts.Size(cell.names.up[1])
      if type(h) == "number" and h > 0 and lw and lh then
        cell.fit = true
        local artH = h / (1 - 2 * RIM)
        local m = artH * RIM
        local leftW = lw * artH / lh
        -- The end no wider than the cell and its share of the gap.
        local room = (clock:GetWidth() or h) + m
        local newL = math.min(leftW, room)
        cell[1]:SetTexCoord(0, newL / leftW, 0, 1)
        cell[1]:SetSize(newL, artH)
        cell[1]:ClearAllPoints()
        cell[1]:SetPoint("TOPLEFT", clock, "TOPLEFT", -m, m)
        cell[2]:ClearAllPoints()
        cell[2]:SetPoint("TOPLEFT", cell[1], "TOPRIGHT", 0, 0)
        cell[2]:SetPoint("BOTTOMRIGHT", cell.button, "BOTTOMLEFT", 0, -m)
      end
    end
    local glyph = clock.__pbGlyph
    local lit = cell.down or clock.__pbHover
    local r, g, b
    if lit then
      r, g, b = Parts.FontRGB("GameFontHighlight", 1, 1, 1)
    else
      r, g, b = Parts.FontRGB("GameFontNormal", 1, 0.82, 0)
    end
    if glyph then
      clock.__pbGlyphLit = true
      glyph:SetVertexColor(r, g, b, 1)
      glyph:SetAlpha(1)
    end
    if clock.Text then clock.Text:SetTextColor(r, g, b) end
  end

  local function CellDown(clock)
    local cell = clock.__pbBlizzCell
    if cell then
      cell.down = true
      PaintCell(clock)
    end
  end

  local function CellUp(clock)
    local cell = clock.__pbBlizzCell
    if cell then
      cell.down = false
      PaintCell(clock)
    end
  end

  -- The cell shown or hidden: Send mail laid again, whole without it.
  local function CellMoved(clock)
    local cell = clock.__pbBlizzCell
    if not cell then return end
    if clock:IsShown() then CellUp(clock) end
    Fit(cell.button)
  end

  local function CellSized(clock)
    local cell = clock.__pbBlizzCell
    if cell then
      cell.fit = nil
      PaintCell(clock)
    end
  end

  function Parts.SentCell(clock, button)
    if clock.__pbBlizzCell ~= nil then return end
    clock.__pbBlizzCell = false
    if not (button and button:IsObjectType("Button")) then return end
    if button.__pbBlizzButton == nil then Parts.Button(button) end
    local art = button.__pbBlizzButton
    if not art or art.names ~= RED then return end
    local cell = { names = RED, button = button, down = false }
    cell[1] = clock:CreateTexture(nil, "BACKGROUND", nil, 1)
    cell[2] = clock:CreateTexture(nil, "BACKGROUND", nil, 1)
    -- The dark line between the cell and the caption: Postbox's own white
    -- tile, tinted in code, inside the button's face.
    local line = clock:CreateTexture(nil, "BACKGROUND", nil, 2)
    line:SetColorTexture(0, 0, 0, 0.6)
    line:SetWidth(1)
    line:SetPoint("TOPLEFT", clock, "TOPRIGHT", 0, -CELL_LINE)
    line:SetPoint("BOTTOMLEFT", clock, "BOTTOMRIGHT", 0, CELL_LINE)
    cell.line = line
    clock.__pbBlizzCell = cell
    art.cell = clock
    clock.__setSelectedOverride = PaintCell
    clock.__pbHoverOverride = PaintCell
    clock:HookScript("OnMouseDown", CellDown)
    clock:HookScript("OnMouseUp", CellUp)
    clock:HookScript("OnShow", CellMoved)
    clock:HookScript("OnHide", CellMoved)
    clock:HookScript("OnSizeChanged", CellSized)
    -- The plate's own art retired, the button laid again with its cell.
    local T = ns.Theme
    if T and type(T.SetPlateSelected) == "function" then
      T.SetPlateSelected(clock, clock.isSelected)
    else
      PaintCell(clock)
    end
    art.m = false
    Fit(button)
  end
end

-------------------------------------------------------------
-- The Earned / Spent strip
-------------------------------------------------------------

-- The Mail tab's totals strip as the game's money strips are drawn (the
-- Auction House's, Send Mail's): ThinGoldEdgeTemplate's art, the file
-- Interface\Common\Moneyframe in its three pieces by the template's own
-- texture coordinates, with the game's dark marble (InsetFrameTemplate's
-- ground) inside the gold line on all four sides, and the words in the
-- game's gold. The figures keep their own colors.
--
-- Laid by its rim (measured from the file): the gold line stands 2 of the
-- art's 20 units in from its top and bottom edges and 1 in from each end,
-- so the art is drawn that much past the strip's box and the line meets the
-- box. The art's own middle is opaque black: the marble lies above it,
-- inset past the line so it never covers it. Only the totals strip: the
-- other bands keep their look.
do
  local EDGE = "Interface\\Common\\Moneyframe"
  local MARBLE = "Interface\\FrameGeneral\\UI-Background-Marble"
  -- ThinGoldEdgeTemplate's pieces: texture coordinates, and the end caps'
  -- width.
  local PIECES = {
    { 0.953125, 0.9921875, 0, 0.296875 },
    { 0, 0.9921875, 0.3125, 0.609375 },
    { 0, 0.0546875, 0, 0.296875 },
  }
  local CAP = 7
  -- The rim, in the art's units: 2 of 20 at the top and the foot, 1 at
  -- each end. The marble stands 2 in from the strip's box, inside the line.
  local RIM_Y, ART_H, RIM_X, MARBLE_IN = 2, 20, 1, 2

  -- The strip the Mail tab's totals stand on (CollectTab: panel.Banner,
  -- whose words are panel.BannerText).
  function Parts.IsTotals(c)
    if c.__postboxPanel ~= "band" then return false end
    local p = c.GetParent and c:GetParent()
    return (p and p.Banner == c and p.BannerText) and true or false
  end

  local function Ink(band)
    local p = band:GetParent()
    local text = p and p.BannerText
    if text and type(text.SetTextColor) == "function" then
      text:SetTextColor(Parts.FontRGB("GameFontNormal", 1, 0.82, 0))
    end
  end

  function Parts.Totals(band)
    if band.__pbBlizzBand ~= nil then return end
    band.__pbBlizzBand = false
    local h = band:GetHeight()
    if type(h) ~= "number" or h <= 0 then h = 24 end
    -- The art's height that puts its line on the strip's top and foot.
    local face = ART_H - 2 * RIM_Y
    local out = h * RIM_Y / face
    local pieces = {}
    for i = 1, 3 do
      local t = band:CreateTexture(nil, "BACKGROUND", nil, 2)
      t:SetTexture(EDGE)
      local c = PIECES[i]
      t:SetTexCoord(c[1], c[2], c[3], c[4])
      pieces[i] = t
    end
    local L, M, R = pieces[1], pieces[2], pieces[3]
    L:SetWidth(CAP)
    L:SetPoint("TOPLEFT", band, "TOPLEFT", -RIM_X, out)
    L:SetPoint("BOTTOMLEFT", band, "BOTTOMLEFT", -RIM_X, -out)
    R:SetWidth(CAP)
    R:SetPoint("TOPRIGHT", band, "TOPRIGHT", RIM_X, out)
    R:SetPoint("BOTTOMRIGHT", band, "BOTTOMRIGHT", RIM_X, -out)
    M:SetPoint("TOPLEFT", L, "TOPRIGHT", 0, 0)
    M:SetPoint("BOTTOMRIGHT", R, "BOTTOMLEFT", 0, 0)
    local marble = band:CreateTexture(nil, "BORDER", nil, -1)
    marble:SetTexture(MARBLE, "REPEAT", "REPEAT")
    marble:SetHorizTile(true)
    marble:SetVertTile(true)
    marble:SetPoint("TOPLEFT", band, "TOPLEFT", MARBLE_IN, -MARBLE_IN)
    marble:SetPoint("BOTTOMRIGHT", band, "BOTTOMRIGHT", -MARBLE_IN, MARBLE_IN)
    band.__pbBlizzBand = pieces
    band.__pbBlizzMarble = marble
    -- The strip's own fill and line, faded under the art (never recolored,
    -- so a later repaint of the band cannot bring them back).
    Fade(band.Center)
    for i = 1, #BACKDROP_EDGES do Fade(band[BACKDROP_EDGES[i]]) end
    Fade(band.pbSurfaceTexture)
    Ink(band)
  end

  -- The totals' words, each time the strip writes them (CollectTab's
  -- FitBanner asks the skin for its inks): the game's gold on the dressed
  -- strip. The figures' inks are handed back as they came.
  function Skin.BannerInk(text, up, down)
    local band = text and text.GetParent and text:GetParent()
    if band and band.__pbBlizzBand then Ink(band) end
    return up, down
  end
end

-------------------------------------------------------------
-- Fields
-------------------------------------------------------------

-- Every field (an input wrap: Recipient, Subject, the message, the gold
-- boxes, the group name, the bug report's address) wears the game's input
-- border, by the file the game's own Send Mail names
-- (Interface\Common\Common-Input-Border); every search box
-- (Theme.CreateSearchBox) the game's search border with its magnifier at
-- the left, and its words moved right by what the magnifier takes. Art only,
-- on Postbox's own frames: the game's InputBoxTemplate and SearchBoxTemplate
-- are never made (their scripts would take the box's focus, hint and clear
-- button over). The field's own fill, line and grain are faded under the
-- art.
--
-- The input file has no margin round its rim (measured), so it is laid on
-- the field's box. It is cut in nine by its own corners (8 units) so the
-- message box, many lines tall, keeps a thin even border: on a one-line box
-- that is the game's own three pieces. The search art (also measured) is
-- laid on the box too, its ends scaled with its height.
--
-- A cell joined to a field (the Manage Recipients key, the sort) draws as
-- it did, over the field's art at its end: a later step gives it its own.
do
  local INPUT = "Interface\\Common\\Common-Input-Border"
  -- The file's corners and middles: 8 units in from each end and from its
  -- top, 8 up from its foot, of its 20-unit art.
  local U = { 0, 0.0625, 0.9375, 1 }
  local V = { 0, 0.25, 0.375, 0.625 }
  local CORNER = 8
  local SEARCH = { "common-search-border-left", "common-search-border-middle", "common-search-border-right" }
  local GLASS = "common-search-magnifyingglass"
  -- SearchBoxTemplate's own layout, per its 20-unit box from the art's left
  -- end: the magnifier 10 square at 6 in and 1 down, the words at 21.
  local GLASS_X, GLASS_Y, GLASS_SIZE, TEXT_X, BOX_H = 6, -1, 10, 21, 20

  local function Quiet(wrap)
    Fade(wrap.Center)
    for i = 1, #BACKDROP_EDGES do Fade(wrap[BACKDROP_EDGES[i]]) end
    Fade(wrap.pbSurfaceTexture)
  end

  local function LayInput(wrap)
    local h = wrap:GetHeight()
    local corner = CORNER
    if type(h) == "number" and h > 0 and h < 2 * CORNER then corner = h / 2 end
    -- Each column's left and right, each row's top and foot: the point on
    -- the wrap and the offset from it.
    local cols = { { "LEFT", 0, "LEFT", corner }, { "LEFT", corner, "RIGHT", -corner }, { "RIGHT", -corner, "RIGHT", 0 } }
    local rows = { { "TOP", 0, "TOP", -corner }, { "TOP", -corner, "BOTTOM", corner }, { "BOTTOM", corner, "BOTTOM", 0 } }
    local pieces = {}
    for r = 1, 3 do
      local row = rows[r]
      for c = 1, 3 do
        local col = cols[c]
        local t = wrap:CreateTexture(nil, "BORDER", nil, 1)
        t:SetTexture(INPUT)
        t:SetTexCoord(U[c], U[c + 1], V[r], V[r + 1])
        t:SetPoint("TOPLEFT", wrap, row[1] .. col[1], col[2], row[2])
        t:SetPoint("BOTTOMRIGHT", wrap, row[3] .. col[3], col[4], row[4])
        pieces[#pieces + 1] = t
      end
    end
    return pieces
  end

  -- The search border and its magnifier on `wrap` (h units tall), as the
  -- template lays them, grown with the box: the three pieces, and the
  -- magnifier as the fourth where the client has it. Art only.
  function Parts.SearchArt(wrap, h)
    for i = 1, 3 do
      if not HasAtlas(SEARCH[i]) then return nil end
    end
    local pieces = {}
    for i = 1, 3 do
      local t = wrap:CreateTexture(nil, "BORDER", nil, 1)
      Atlas(t, SEARCH[i], false)
      pieces[i] = t
    end
    local L, M, R = pieces[1], pieces[2], pieces[3]
    local lw, lh = Parts.Size(SEARCH[1])
    local rw, rh = Parts.Size(SEARCH[3])
    L:SetWidth(lw and lh and lw * h / lh or h * 0.4)
    L:SetPoint("TOPLEFT", wrap, "TOPLEFT", 0, 0)
    L:SetPoint("BOTTOMLEFT", wrap, "BOTTOMLEFT", 0, 0)
    R:SetWidth(rw and rh and rw * h / rh or h * 0.4)
    R:SetPoint("TOPRIGHT", wrap, "TOPRIGHT", 0, 0)
    R:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", 0, 0)
    M:SetPoint("TOPLEFT", L, "TOPRIGHT", 0, 0)
    M:SetPoint("BOTTOMRIGHT", R, "BOTTOMLEFT", 0, 0)
    -- The magnifier, as the template places it, grown with the box.
    local k = h / BOX_H
    if HasAtlas(GLASS) then
      local glass = wrap:CreateTexture(nil, "ARTWORK")
      if Atlas(glass, GLASS, false) then
        glass:SetSize(GLASS_SIZE * k, GLASS_SIZE * k)
        glass:SetPoint("LEFT", wrap, "LEFT", GLASS_X * k, GLASS_Y * k)
        pieces[4] = glass
      end
    end
    return pieces
  end

  -- A search box: the art, and its words after the magnifier as the
  -- template places them, grown with the box.
  local function LaySearch(wrap, search)
    local h = wrap:GetHeight()
    if type(h) ~= "number" or h <= 0 then h = 24 end
    local pieces = Parts.SearchArt(wrap, h)
    if pieces and pieces[4] then
      local lead = math.floor(TEXT_X * h / BOX_H + 0.5)
      wrap.__pbTextLead = lead
      if search.Box then search.Box:SetPoint("TOPLEFT", wrap, "TOPLEFT", lead, -2) end
      if search.Placeholder then search.Placeholder:SetPoint("TOPLEFT", wrap, "TOPLEFT", lead, -2) end
      -- The words' room, measured again with the new lead.
      if type(search.Place) == "function" then search.Place(search.toggled) end
    end
    return pieces
  end

  -- The options' title-bar Find box (Core/OptionsPanel.lua, Find.Build:
  -- tagged __pbFindBox): the same art in place of its hairline and its own
  -- magnifier, which are faded; its words stay where they stand, already
  -- clear of the magnifier.
  function Parts.Find(wrap)
    if wrap.__pbBlizzFind ~= nil then return end
    wrap.__pbBlizzFind = false
    local h = wrap:GetHeight()
    if type(h) ~= "number" or h <= 0 then return end
    local pieces = Parts.SearchArt(wrap, h)
    if not pieces then return end
    wrap.__pbBlizzFind = pieces
    Fade(wrap.Line)
    if pieces[4] then Fade(wrap.Glyph) end
  end

  function Parts.Field(wrap)
    if wrap.__pbBlizzField ~= nil then return end
    wrap.__pbBlizzField = false
    local search = wrap.__pbSearch
    local pieces
    if type(search) == "table" then
      pieces = LaySearch(wrap, search)
    else
      pieces = LayInput(wrap)
    end
    if not pieces then return end
    wrap.__pbBlizzField = pieces
    Quiet(wrap)
  end
end

-------------------------------------------------------------
-- The scroll bar
-------------------------------------------------------------

-- Every list's bar (Theme.SlimScrollBar: Postbox's own slider and step
-- buttons, in the gutter it has) wears the game's minimal scroll bar
-- (MinimalScrollBar, the bar every one of the game's own lists carries):
-- its track, its small thumb and its two arrows, each with the game's hover
-- and pressed art. The bar's own drawing is faded or hidden; the slider,
-- its range, its steps and its clicks are untouched.
--
-- Laid by its rim (measured): the track's art is 8 wide with a clear unit
-- at each side, so on the 6-unit bar it is drawn a unit past each side and
-- its visible track is the bar; the thumb's art is 8 wide and solid, a unit
-- past the bar each side, as the game's thumb stands past its track. The
-- arrows keep the art's own proportions and are drawn no wider than the
-- gutter allows, so they never pass the list's edge.
do
  local TRACK = { "minimal-scrollbar-track-top", "!minimal-scrollbar-track-middle", "minimal-scrollbar-track-bottom" }
  local THUMB = {
    up = { "minimal-scrollbar-small-thumb-top", "minimal-scrollbar-small-thumb-middle", "minimal-scrollbar-small-thumb-bottom" },
    over = { "minimal-scrollbar-small-thumb-top-over", "minimal-scrollbar-small-thumb-middle-over", "minimal-scrollbar-small-thumb-bottom-over" },
    down = { "minimal-scrollbar-small-thumb-top-down", "minimal-scrollbar-small-thumb-middle-down", "minimal-scrollbar-small-thumb-bottom-down" },
  }
  local ARROWS = {
    top = { up = "minimal-scrollbar-arrow-top", over = "minimal-scrollbar-arrow-top-over", down = "minimal-scrollbar-arrow-top-down" },
    bottom = { up = "minimal-scrollbar-arrow-bottom", over = "minimal-scrollbar-arrow-bottom-over", down = "minimal-scrollbar-arrow-bottom-down" },
  }
  -- The clear unit at each side of the arrows' art.
  local ARROW_RIM = 1

  local function HasAll(list)
    for i = 1, #list do
      if not HasAtlas(list[i]) then return false end
    end
    return true
  end

  local function HasArrows(set)
    return HasAtlas(set.up) and HasAtlas(set.over) and HasAtlas(set.down)
  end

  -- Three pieces stacked down `host`'s height, `out` past each side: the
  -- ends at the art's own height, the middle between.
  local function Stack(owner, host, names, layer, out)
    local pieces = {}
    for i = 1, 3 do
      local t = owner:CreateTexture(nil, layer)
      Atlas(t, names[i], false)
      pieces[i] = t
    end
    local T, M, B = pieces[1], pieces[2], pieces[3]
    local _, th = Parts.Size(names[1])
    local _, bh = Parts.Size(names[3])
    T:SetHeight(th or 8)
    T:SetPoint("TOPLEFT", host, "TOPLEFT", -out, 0)
    T:SetPoint("TOPRIGHT", host, "TOPRIGHT", out, 0)
    B:SetHeight(bh or 8)
    B:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", -out, 0)
    B:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", out, 0)
    M:SetPoint("TOPLEFT", T, "BOTTOMLEFT", 0, 0)
    M:SetPoint("BOTTOMRIGHT", B, "TOPRIGHT", 0, 0)
    return pieces
  end

  -- The thumb's art for the bar's state: pressed, pointed at, at rest.
  local function PaintThumb(bar)
    local art = bar.__pbBlizzBar
    if not art then return end
    local state = (art.down and "down") or (art.over and "over") or "up"
    if art.state == state then return end
    art.state = state
    local names = THUMB[state]
    for i = 1, 3 do Atlas(art.thumb[i], names[i], false) end
  end

  local function BarEnter(bar) local a = bar.__pbBlizzBar if a then a.over = true PaintThumb(bar) end end
  local function BarLeave(bar) local a = bar.__pbBlizzBar if a then a.over = false PaintThumb(bar) end end
  local function BarDown(bar) local a = bar.__pbBlizzBar if a then a.down = true PaintThumb(bar) end end
  local function BarUp(bar) local a = bar.__pbBlizzBar if a then a.down = false PaintThumb(bar) end end

  local function PaintArrow(btn)
    local art = btn.__pbBlizzArrow
    if not art then return end
    local state = (art.down and "down") or (art.over and "over") or "up"
    if art.state == state then return end
    art.state = state
    Atlas(art.tex, art.names[state], false)
  end

  local function ArrowEnter(btn) local a = btn.__pbBlizzArrow if a then a.over = true PaintArrow(btn) end end
  local function ArrowLeave(btn) local a = btn.__pbBlizzArrow if a then a.over, a.down = false, false PaintArrow(btn) end end
  local function ArrowDown(btn) local a = btn.__pbBlizzArrow if a then a.down = true PaintArrow(btn) end end
  local function ArrowUp(btn) local a = btn.__pbBlizzArrow if a then a.down = false PaintArrow(btn) end end

  -- The step button's own chevron hidden, the game's arrow in its place.
  local function Arrow(btn, names, maxW)
    if not btn or btn.__pbBlizzArrow then return end
    for i = 1, select("#", btn:GetRegions()) do
      local r = select(i, btn:GetRegions())
      if r and r.Hide then r:Hide() end
    end
    local tex = btn:CreateTexture(nil, "ARTWORK")
    local w, h = Parts.Size(names.up)
    w, h = w or 17, h or 11
    if maxW and w > maxW then
      h = h * maxW / w
      w = maxW
    end
    tex:SetSize(w, h)
    tex:SetPoint("CENTER", btn, "CENTER", 0, 0)
    btn.__pbBlizzArrow = { tex = tex, names = names }
    PaintArrow(btn)
    btn:HookScript("OnEnter", ArrowEnter)
    btn:HookScript("OnLeave", ArrowLeave)
    btn:HookScript("OnMouseDown", ArrowDown)
    btn:HookScript("OnMouseUp", ArrowUp)
  end

  function Parts.ScrollBar(bar)
    if bar.__pbBlizzBar ~= nil then return end
    bar.__pbBlizzBar = false
    if not (HasAll(TRACK) and HasAll(THUMB.up) and HasAll(THUMB.over) and HasAll(THUMB.down)) then return end
    local thumb = bar.GetThumbTexture and bar:GetThumbTexture()
    if not thumb then return end
    local w = bar:GetWidth()
    if type(w) ~= "number" or w <= 0 then w = 6 end
    -- The track art, 8 wide with a clear unit each side, centred on the bar
    -- so its visible track is the bar's width; the thumb's 8 solid units
    -- centred on the bar's thumb.
    local tw = Parts.Size(TRACK[1]) or 8
    local trackOut = (tw - 2 - w) / 2
    if trackOut < 0 then trackOut = 0 end
    local hw = Parts.Size(THUMB.up[1]) or 8
    local thumbOut = (hw - w) / 2
    if thumbOut < 0 then thumbOut = 0 end
    local art = { over = false, down = false }
    art.track = Stack(bar, bar, TRACK, "BACKGROUND", trackOut + 1)
    art.thumb = Stack(bar, thumb, THUMB.up, "OVERLAY", thumbOut)
    art.state = "up"
    bar.__pbBlizzBar = art
    -- The bar's own track and thumb, faded (their paint, not their place:
    -- the slider still sizes and moves the thumb the art stands on).
    Fade(bar.Track)
    thumb:SetAlpha(0)
    bar:HookScript("OnEnter", BarEnter)
    bar:HookScript("OnLeave", BarLeave)
    bar:HookScript("OnMouseDown", BarDown)
    bar:HookScript("OnMouseUp", BarUp)
    -- The arrows, no wider than the gutter: twice the bar's middle's
    -- distance from the list's edge, plus the art's clear rim.
    local maxW
    local _, _, _, x = bar:GetPoint(1)
    if type(x) == "number" and x <= 0 then maxW = 2 * (-x + w / 2 + ARROW_RIM) end
    if HasArrows(ARROWS.top) then Arrow(bar.Up, ARROWS.top, maxW) end
    if HasArrows(ARROWS.bottom) then Arrow(bar.Down, ARROWS.bottom, maxW) end
  end
end

-------------------------------------------------------------
-- The small dark button
-------------------------------------------------------------

-- Every segment and tile plate (Theme.CreatePlate "segment" / "tile":
-- Inbox and Done, another character's name, the History clock, Received
-- and Sent, the Send tab's name row, Manage Recipients' filters, the filter
-- chips, the bug report's switch, a sort that stands alone) wears the
-- game's small dark button, the tertiary button of its raid manager and
-- friend requests: its normal, hover, pressed, selected (a white glow) and
-- disabled art, on Postbox's own plate. The skin owns the plate's look
-- through its selection override (Theme.SetPlateSelected retires the
-- plate's own art once) and its pointed-at state through the hover
-- override (Theme.SetPlateHover); the plate keeps its size, its hit
-- rectangle, its clicks and its scripts. The caption is the game's gold at
-- rest and white on a lit plate, a glyph caption (the clock, a sort) with
-- it; an empty tile's caption stays dimmed.
--
-- Laid by its rim (measured from both clients' art, the same on each): of
-- the normal art's 46 x 34 the metal rim stands 3 units in from each end, 2
-- from the top and 4 from the foot; a larger state (retail's selected glow,
-- 52 x 40) is the same rim with its glow round it. So the art is drawn that
-- much past the plate's box, scaled to its height, and the rim meets the
-- box: a row of plates is as wide as the field above it. Sizes come from the
-- client's own atlas sizes (Parts.Size).
--
-- Plates joined today are drawn as one strip: the art's left end on the
-- first cell, its middle on the inner ones, its right end on the last, the
-- rim's own column (one unit) between cells, and the lit cell in the same
-- cut of the selected art. Which plates are joined is read from what joins
-- them, when the plate is painted: Inbox and Done from their ring
-- (MailMemory.JoinRing's ring._first / _last), the History clock from
-- RV.JoinClock (`_joined`) and Received / Sent after it, a bar of tiles (the
-- Send tab's name row, Manage Recipients' filters) from the shown tiles in
-- it, two units apart. A plate standing alone is a whole button. Cells
-- joined to a FIELD (the sort on a search, the Manage Recipients key) keep
-- the look milestone 2 left them, and so does the options preview.
do
  local BASE = "common-button-tertiary-"
  local NAMES = {
    up = BASE .. "normal", over = BASE .. "hover", down = BASE .. "pressed",
    lit = BASE .. "selected", off = BASE .. "disabled",
  }
  local LIST = { "up", "over", "down", "lit", "off" }
  -- The rim, as shares of the normal art's own size, and each end piece's
  -- share of its width (the end with its rounded corners).
  local RIM_X, RIM_T, RIM_B, CAP = 3 / 46, 2 / 34, 4 / 34, 11 / 46

  local function HasAll()
    for i = 1, #LIST do
      if not HasAtlas(NAMES[LIST[i]]) then return false end
    end
    return Parts.Size(NAMES.up) ~= nil
  end

  -- One state's geometry at plate height `h`, in one table reused by every
  -- call (nothing is made): `s` units per art unit; `outX`, `outT`, `outB`
  -- how far the art stands past the box; `capW` an end piece's width and
  -- `capU` its share of the art; the rim's own place in the art (`rx`, `rt`,
  -- `rb`) and the art's size (`w`, `hh`).
  local G = {}
  local function Geo(state, h)
    local w0, h0 = Parts.Size(NAMES.up)
    local w, hh = Parts.Size(NAMES[state])
    w, hh = w or w0, hh or h0
    local gx, gy = (w - w0) / 2, (hh - h0) / 2
    local rx, rt, rb = RIM_X * w0 + gx, RIM_T * h0 + gy, RIM_B * h0 + gy
    local s = h / (h0 - RIM_T * h0 - RIM_B * h0)
    local cap = CAP * w0 + gx
    G.s, G.w, G.hh, G.rx, G.rt, G.rb = s, w, hh, rx, rt, rb
    G.outX, G.outT, G.outB = rx * s, rt * s, rb * s
    G.capW, G.capU = cap * s, cap / w
    return G
  end

  -- The three pieces for `state` on `frame` (h units tall), cut for its
  -- `role` in a strip ("alone", "first", "middle", "last"); an inner end
  -- runs `gap` past the frame's right edge, to the next cell's left.
  local function Lay(art, frame, state, role, gap, h)
    local g = Geo(state, h)
    local name = NAMES[state]
    local L, M, R = art[1], art[2], art[3]
    local left = role == "alone" or role == "first"
    local right = role == "alone" or role == "last"
    M:ClearAllPoints()
    Atlas(M, name, false)
    M:SetTexCoord(g.capU, 1 - g.capU, 0, 1)
    if left then
      Atlas(L, name, false)
      L:SetTexCoord(0, g.capU, 0, 1)
      L:ClearAllPoints()
      L:SetWidth(g.capW)
      L:SetPoint("TOPLEFT", frame, "TOPLEFT", -g.outX, g.outT)
      L:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", -g.outX, -g.outB)
      L:Show()
      M:SetPoint("TOPLEFT", L, "TOPRIGHT", 0, 0)
    else
      L:Hide()
      M:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, g.outT)
    end
    if right then
      Atlas(R, name, false)
      R:SetTexCoord(1 - g.capU, 1, 0, 1)
      R:ClearAllPoints()
      R:SetWidth(g.capW)
      R:SetPoint("TOPRIGHT", frame, "TOPRIGHT", g.outX, g.outT)
      R:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", g.outX, -g.outB)
      R:Show()
      M:SetPoint("BOTTOMRIGHT", R, "BOTTOMLEFT", 0, 0)
    else
      R:Hide()
      M:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", gap, -g.outB)
    end
  end

  -- Three pieces on `frame`, in its BACKGROUND layer over the plate's own
  -- (faded) art, and the line between cells over them.
  function Parts.SmallArt(frame)
    if not HasAll() then return nil end
    local art = {}
    for i = 1, 3 do art[i] = frame:CreateTexture(nil, "BACKGROUND", nil, 1) end
    art.line = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
    art.line:Hide()
    return art
  end
  Parts.LaySmall = Lay

  -- The rim's own column, one unit wide, at the right end of a cell with a
  -- cell after it: the metal at rest, the selected art's white beside a lit
  -- cell. Only on a change.
  local function Line(plate, nxt)
    local art = plate.__pbBlizzSeg
    local D = art.line
    if not nxt then
      D:Hide()
      art.lineLit = nil
      return
    end
    local lit = (plate.isSelected or nxt.isSelected) and true or false
    if art.lineLit ~= lit or art.lineH ~= art.h or art.lineGap ~= art.gap then
      art.lineLit, art.lineH, art.lineGap = lit, art.h, art.gap
      local state = lit and "lit" or "up"
      local g = Geo(state, art.h)
      Atlas(D, NAMES[state], false)
      D:SetTexCoord(g.rx / g.w, (g.rx + 1 / g.s) / g.w, g.rt / g.hh, 1 - g.rb / g.hh)
      D:ClearAllPoints()
      D:SetPoint("TOPLEFT", plate, "TOPRIGHT", art.gap - 1, 0)
      D:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", art.gap, 0)
    end
    D:Show()
  end

  -- The plate's state: disabled, lit, pressed, pointed at, at rest.
  local function StateOf(plate, art)
    if not plate:IsEnabled() then return "off" end
    if plate.isSelected then return "lit" end
    if art.down then return "down" end
    if plate.__pbHover then return "over" end
    return "up"
  end

  -- The caption and a glyph caption in the game's gold, white on a lit
  -- plate, the disabled gray on a disabled plate or an empty tile (Theme's
  -- rule). The sort marks' own painters leave a glyph marked lit alone.
  local function Ink(plate, state)
    local T = ns.Theme
    local r, g, b
    if state == "off" or (T and T.EmptyTile and T.EmptyTile(plate)) then
      r, g, b = Parts.FontRGB("GameFontDisable", 0.5, 0.5, 0.5)
    elseif state == "lit" then
      r, g, b = Parts.FontRGB("GameFontHighlight", 1, 1, 1)
    else
      r, g, b = Parts.FontRGB("GameFontNormal", 1, 0.82, 0)
    end
    if plate.Text then plate.Text:SetTextColor(r, g, b) end
    local glyph = plate.__pbGlyph
    if glyph then
      plate.__pbGlyphLit = true
      glyph:SetVertexColor(r, g, b, 1)
      glyph:SetAlpha(1)
    end
  end

  -- -> role, gap, the cell after, the cell before.
  function Parts.SegRole(plate)
    local kind = plate.__pbBlizzJoin
    if kind == "ring" then
      local ring = plate.__pbBlizzRing
      local first, last = ring._first, ring._last
      if ring._on and first and last and first ~= last then
        if plate == first then return "first", -1, last, nil end
        if plate == last then return "last", -1, nil, first end
      end
    elseif kind == "clock" then
      if plate._joined then return "first", -1, plate.__pbBlizzSides[1], nil end
    elseif kind == "side" then
      local sides = plate.__pbBlizzSides
      if plate == sides[1] then return "middle", -1, sides[2], plate.__pbBlizzClock end
      return "last", -1, nil, sides[1]
    elseif kind == "bar" then
      local cells = plate.__pbBlizzBar
      local prev, nxt, seen = nil, nil, false
      for i = 1, #cells do
        local c = cells[i]
        if c == plate then
          seen = true
        elseif c:IsShown() then
          if seen then
            nxt = c
            break
          end
          prev = c
        end
      end
      if prev and nxt then return "middle", cells.gap, nxt, prev end
      if nxt then return "first", cells.gap, nxt, nil end
      if prev then return "last", cells.gap, nil, prev end
    end
    return "alone", 0, nil, nil
  end

  local Paint
  Paint = function(plate)
    local art = plate.__pbBlizzSeg
    if not art then return end
    local state = StateOf(plate, art)
    local role, gap, nxt, prev = Parts.SegRole(plate)
    local h = plate:GetHeight()
    if type(h) ~= "number" or h <= 0 then h = 24 end
    if art.state ~= state or art.role ~= role or art.gap ~= gap or art.h ~= h then
      art.state, art.role, art.gap, art.h = state, role, gap, h
      Lay(art, plate, state, role, gap, h)
    end
    art.next = nxt
    Line(plate, nxt)
    Ink(plate, state)
    -- The cell before: its line follows this one's light, and it is laid
    -- again where it last had another cell after it.
    local before = prev and prev.__pbBlizzSeg
    if before then
      if before.next ~= plate then Paint(prev) else Line(prev, plate) end
    end
  end
  Parts.PaintSeg = Paint

  local function Down(plate)
    local art = plate.__pbBlizzSeg
    if art and plate:IsEnabled() then
      art.down = true
      Paint(plate)
    end
  end

  local function Up(plate)
    local art = plate.__pbBlizzSeg
    if art then
      art.down = false
      Paint(plate)
    end
  end

  -- A tile of a bar shown or hidden: every shown tile of it laid again
  -- (each only where its place in the strip moved).
  local function BarMoved(plate)
    local cells = plate.__pbBlizzBar
    if plate:IsShown() then Up(plate) end
    for i = 1, #cells do
      local c = cells[i]
      if c ~= plate and c:IsShown() then Paint(c) end
    end
  end

  -- What joins the plate, read once: the ring it is a cell of, History's
  -- switch, or a bar of tiles (its tiles in the order they stand, the star
  -- first).
  local function IsPlate(c)
    local V = ns.Theme and ns.Theme.PlateVariants
    local v = c and c.__pbVariant
    return V ~= nil and v ~= nil and (v == V.segment or v == V.tile)
  end

  -- The ring a joined row draws round its plates today (a texture of the
  -- row's own, under them) is faded: the strip's art is the ring now.
  local function Join(plate)
    local p = plate:GetParent()
    if not p then return end
    local cells = p.ringCells
    if p.segRing and type(cells) == "table" then
      for i = 1, #cells do
        if cells[i] == plate then
          plate.__pbBlizzJoin, plate.__pbBlizzRing = "ring", p.segRing
          Fade(p.segRing)
          return
        end
      end
    end
    if p.history == plate and type(p.sides) == "table" then
      plate.__pbBlizzJoin, plate.__pbBlizzSides = "clock", p.sides
      Fade(p.sides.holder and p.sides.holder.Ring)
      return
    end
    local up = p:GetParent()
    local sides = up and up.sides
    if type(sides) == "table" and sides.holder == p then
      plate.__pbBlizzJoin, plate.__pbBlizzSides, plate.__pbBlizzClock = "side", sides, up.history
      Fade(p.Ring)
      return
    end
    local up2 = up and up:GetParent()
    if not ((up and (up.ContactBar == p or up.CategoryBar == p)) or (up2 and up2.CategoryBar == p)) then return end
    local bar = p.__pbBlizzCells
    if not bar then
      local T = ns.Theme
      bar = { gap = (T and T.Metrics and T.Metrics.space and T.Metrics.space.hair) or 2 }
      for i = 1, select("#", p:GetChildren()) do
        local c = select(i, p:GetChildren())
        if IsPlate(c) and (c._isStar or c._starTile) then bar[#bar + 1] = c end
      end
      for i = 1, select("#", p:GetChildren()) do
        local c = select(i, p:GetChildren())
        if IsPlate(c) and not (c._isStar or c._starTile) then bar[#bar + 1] = c end
      end
      p.__pbBlizzCells = bar
    end
    plate.__pbBlizzJoin, plate.__pbBlizzBar = "bar", bar
    plate:HookScript("OnShow", BarMoved)
    plate:HookScript("OnHide", BarMoved)
  end

  -- A segment or tile plate this skin dresses: not one joined to a field
  -- (Theme.JoinCell), not the options preview's, not the Send tab's Sent
  -- clock (Send mail's cell), not one another look already owns.
  function Parts.IsSeg(c)
    if not IsPlate(c) or c.__pbDivider or c.__setSelectedOverride then return false end
    local p = c:GetParent()
    if p and (p.Segs or p.SentClock == c) then return false end
    return true
  end

  function Parts.Seg(plate)
    if plate.__pbBlizzSeg ~= nil then return end
    plate.__pbBlizzSeg = false
    local art = Parts.SmallArt(plate)
    if not art then return end
    art.down = false
    plate.__pbBlizzSeg = art
    Join(plate)
    plate.__setSelectedOverride = Paint
    plate.__pbHoverOverride = Paint
    plate:HookScript("OnMouseDown", Down)
    plate:HookScript("OnMouseUp", Up)
    if plate.__pbBlizzJoin ~= "bar" then plate:HookScript("OnShow", Up) end
    plate:HookScript("OnEnable", Paint)
    plate:HookScript("OnDisable", Paint)
    plate:HookScript("OnSizeChanged", Paint)
    -- Its own art retired, and its look painted now.
    local T = ns.Theme
    if T and type(T.SetPlateSelected) == "function" then
      T.SetPlateSelected(plate, plate.isSelected)
    else
      Paint(plate)
    end
  end
end

-------------------------------------------------------------
-- Dropdowns
-------------------------------------------------------------

-- A select's box (Lib/UI/Dropdown.lua, tagged __postboxSelect) wears the
-- game's dropdown (WowStyle1DropdownTemplate's art): the text holder round
-- the box and the gold arrow button at its right end, with its hover,
-- pressed, open and disabled art; the value in the game's white, at the
-- box's left as the game sets it, its room kept clear of the arrow
-- (`__pbValueRoom`, which the select's own fit reads). A select whose items
-- carry art keeps its value centred, the art before it, as it stood.
-- The open list, a select's or a menu's, wears the game's menu ground
-- (common-dropdown-bg, cut in nine by its own corners), and its rows the
-- game's marks by kind: a select's rows are one choice, a circle on each
-- and the chosen one's dot; a menu that marks choices (Dropdown.Menu with
-- `checked`) marks a row that turns an order (`flip`, the sort menus'
-- orders) as one choice too, and every other choice row (a filter, a hidden
-- character) as one of several, a box on each and a tick on those that are
-- on. A menu of actions alone (the Reset menu) and the action rows in a
-- menu's foot have no marks. The chosen row's wash and bar go; a row's own
-- art (a class icon, a colour, a sort's turn mark) stays. The lists stay
-- Postbox's own, their scroller and their hover as they were.
--
-- Laid by the rim (measured from both clients' art): the text holder's
-- metal stands 8 in from each end of its 54 x 41, 7 from its top and 9.5
-- (10.5 on WoW Forever) from its foot, so it is drawn that much past the
-- box, scaled to the box's height, its ends cut at 16 of the 54; the arrow
-- (27 square) as the template lays it on the game's 25-unit box, scaled
-- alike. The menu ground's metal stands 9 in from each side of its 68, 6
-- from its top and 12 from its foot: drawn at its own size that much past
-- the list, its corners 20 units.
Skin.MarkRoom = 18
do
  local HOLDER = "common-dropdown-textholder"
  local ARROW = {
    up = "common-dropdown-a-button", over = "common-dropdown-a-button-hover",
    down = "common-dropdown-a-button-pressed", open = "common-dropdown-a-button-open",
    off = "common-dropdown-a-button-disabled",
  }
  local ARROW_LIST = { "up", "over", "down", "open", "off" }
  local H_X, H_T, H_CAP = 8, 7, 16
  local H_B = ns.IsForever and 10.5 or 9.5
  -- The arrow on the game's box: right +1, down 3; its face 4 in from each
  -- side. The value's lead in from the box's left, and its gap to the arrow.
  local A_X, A_Y, A_FACE, LEAD, GAP = 1, -3, 4, 8, 2
  -- A swatch before the value (Dropdown's SWATCH_X + SIZE + GAP).
  local SWATCH_LEAD = 21

  local BG = "common-dropdown-bg"
  local BG_L, BG_R, BG_T, BG_B, BG_CORNER = 9, 9, 6, 12, 20

  local MARKS = {
    radio = { "common-dropdown-tickradial", "common-dropdown-icon-radialtick-yellow" },
    box = { "common-dropdown-ticksquare", "common-dropdown-icon-checkmark-yellow" },
  }
  -- The marks' middle in from a row's left, inside Skin.MarkRoom: the
  -- words (the list's padding and the room in, 22) start seven units past
  -- the circle's drawn edge, as the game's menus set them.
  local MARK_X = 9

  local function HasArrows()
    for i = 1, #ARROW_LIST do
      if not HasAtlas(ARROW[ARROW_LIST[i]]) then return false end
    end
    return true
  end

  local function ArrowState(toggle, sel)
    if not toggle:IsEnabled() then return "off" end
    if sel.open then return "open" end
    if sel.down then return "down" end
    if sel.over then return "over" end
    return "up"
  end

  local function PaintArrow(toggle)
    local sel = toggle.__pbBlizzSelect
    if not sel then return end
    local state = ArrowState(toggle, sel)
    if sel.state == state then return end
    sel.state = state
    Atlas(sel.arrow, ARROW[state], false)
  end

  local function Over(toggle) local s = toggle.__pbBlizzSelect if s then s.over = true PaintArrow(toggle) end end
  local function Out(toggle) local s = toggle.__pbBlizzSelect if s then s.over, s.down = false, false PaintArrow(toggle) end end
  local function Down(toggle) local s = toggle.__pbBlizzSelect if s and toggle:IsEnabled() then s.down = true PaintArrow(toggle) end end
  local function Up(toggle) local s = toggle.__pbBlizzSelect if s then s.down = false PaintArrow(toggle) end end

  function Parts.Select(toggle)
    if toggle.__pbBlizzSelect ~= nil then return end
    toggle.__pbBlizzSelect = false
    if not (HasAtlas(HOLDER) and HasArrows()) then return end
    local w0, h0 = Parts.Size(HOLDER)
    local aw, ah = Parts.Size(ARROW.up)
    if not (w0 and h0 and aw and ah) then return end
    local h = toggle:GetHeight()
    if type(h) ~= "number" or h <= 0 then h = 22 end
    if h0 <= H_T + H_B then return end
    local s = h / (h0 - H_T - H_B)
    local pieces = {}
    for i = 1, 3 do
      local t = toggle:CreateTexture(nil, "BACKGROUND", nil, 1)
      Atlas(t, HOLDER, false)
      pieces[i] = t
    end
    local L, M, R = pieces[1], pieces[2], pieces[3]
    local cap = H_CAP / w0
    L:SetTexCoord(0, cap, 0, 1)
    L:SetWidth(H_CAP * s)
    L:SetPoint("TOPLEFT", toggle, "TOPLEFT", -H_X * s, H_T * s)
    L:SetPoint("BOTTOMLEFT", toggle, "BOTTOMLEFT", -H_X * s, -H_B * s)
    R:SetTexCoord(1 - cap, 1, 0, 1)
    R:SetWidth(H_CAP * s)
    R:SetPoint("TOPRIGHT", toggle, "TOPRIGHT", H_X * s, H_T * s)
    R:SetPoint("BOTTOMRIGHT", toggle, "BOTTOMRIGHT", H_X * s, -H_B * s)
    M:SetTexCoord(cap, 1 - cap, 0, 1)
    M:SetPoint("TOPLEFT", L, "TOPRIGHT", 0, 0)
    M:SetPoint("BOTTOMRIGHT", R, "BOTTOMLEFT", 0, 0)
    local arrow = toggle:CreateTexture(nil, "ARTWORK")
    arrow:SetSize(aw * s, ah * s)
    arrow:SetPoint("RIGHT", toggle, "RIGHT", A_X * s, A_Y * s)
    local sel = { pieces = pieces, arrow = arrow, over = false, down = false, open = false }
    toggle.__pbBlizzSelect = sel
    -- The red button's own pieces and its glow, faded under the art.
    Fade(toggle.Left)
    Fade(toggle.Middle)
    Fade(toggle.Right)
    local glow = toggle.GetHighlightTexture and toggle:GetHighlightTexture()
    if glow then Fade(glow) end
    PaintArrow(toggle)
    toggle:HookScript("OnEnter", Over)
    toggle:HookScript("OnLeave", Out)
    toggle:HookScript("OnMouseDown", Down)
    toggle:HookScript("OnMouseUp", Up)
    toggle:HookScript("OnEnable", PaintArrow)
    toggle:HookScript("OnDisable", PaintArrow)
    -- The value in the game's white: the button's normal font is its
    -- highlight font (the house's even copy, a named font: Theme's
    -- EvenButtonFonts), so it reads white at rest as under the pointer.
    local T = ns.Theme
    local lit = T and T.NamedFont and type(toggle.GetHighlightFontObject) == "function"
      and T.NamedFont(toggle:GetHighlightFontObject()) or nil
    if lit and type(toggle.SetNormalFontObject) == "function" then toggle:SetNormalFontObject(lit) end
    -- Its place: at the box's left (after a swatch where it has one),
    -- clear of the arrow; a select whose items carry art keeps it centred.
    local inset = tonumber(toggle.__pbInset) or 12
    local label = toggle.GetFontString and toggle:GetFontString()
    if label and inset <= SWATCH_LEAD then
      local lead = (inset >= SWATCH_LEAD) and SWATCH_LEAD or math.floor(LEAD * s + 0.5)
      toggle.__pbValueRoom = lead + math.ceil((aw - A_FACE - A_X) * s) + GAP
      label:ClearAllPoints()
      label:SetPoint("LEFT", toggle, "LEFT", lead, 0)
      label:SetJustifyH("LEFT")
      if type(toggle.__pbRefit) == "function" then toggle.__pbRefit() end
    end
  end

  -- The list's ground: the menu art cut in nine by its corners.
  local CUTS = { { 0, 0 }, { 0, 0 }, { 0, 0 } }
  function Parts.List(list)
    if list.__pbBlizzList ~= nil then return end
    list.__pbBlizzList = false
    local w0, h0 = Parts.Size(BG)
    if not (w0 and h0 and HasAtlas(BG)) or w0 <= 2 * BG_CORNER or h0 <= 2 * BG_CORNER then return end
    local cu, cv = BG_CORNER / w0, BG_CORNER / h0
    CUTS[1][1], CUTS[1][2] = 0, cu
    CUTS[2][1], CUTS[2][2] = cu, 1 - cu
    CUTS[3][1], CUTS[3][2] = 1 - cu, 1
    local pieces = {}
    for row = 1, 3 do
      for col = 1, 3 do
        local t = list:CreateTexture(nil, "BACKGROUND", nil, 1)
        Atlas(t, BG, false)
        t:SetTexCoord(CUTS[col][1], CUTS[col][2], row == 1 and 0 or (row == 2 and cv or 1 - cv),
          row == 1 and cv or (row == 2 and 1 - cv or 1))
        pieces[#pieces + 1] = t
      end
    end
    -- Corners at their own size, past the list by the rim; edges and the
    -- middle between them.
    local TL, T, TR, Lf, C = pieces[1], pieces[2], pieces[3], pieces[4], pieces[5]
    local Rt, BL, B, BR = pieces[6], pieces[7], pieces[8], pieces[9]
    TL:SetSize(BG_CORNER, BG_CORNER)
    TL:SetPoint("TOPLEFT", list, "TOPLEFT", -BG_L, BG_T)
    TR:SetSize(BG_CORNER, BG_CORNER)
    TR:SetPoint("TOPRIGHT", list, "TOPRIGHT", BG_R, BG_T)
    BL:SetSize(BG_CORNER, BG_CORNER)
    BL:SetPoint("BOTTOMLEFT", list, "BOTTOMLEFT", -BG_L, -BG_B)
    BR:SetSize(BG_CORNER, BG_CORNER)
    BR:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", BG_R, -BG_B)
    T:SetPoint("TOPLEFT", TL, "TOPRIGHT", 0, 0)
    T:SetPoint("BOTTOMRIGHT", TR, "BOTTOMLEFT", 0, 0)
    B:SetPoint("TOPLEFT", BL, "TOPRIGHT", 0, 0)
    B:SetPoint("BOTTOMRIGHT", BR, "BOTTOMLEFT", 0, 0)
    Lf:SetPoint("TOPLEFT", TL, "BOTTOMLEFT", 0, 0)
    Lf:SetPoint("BOTTOMRIGHT", BL, "TOPRIGHT", 0, 0)
    Rt:SetPoint("TOPLEFT", TR, "BOTTOMLEFT", 0, 0)
    Rt:SetPoint("BOTTOMRIGHT", BR, "TOPRIGHT", 0, 0)
    C:SetPoint("TOPLEFT", TL, "BOTTOMRIGHT", 0, 0)
    C:SetPoint("BOTTOMRIGHT", BR, "TOPLEFT", 0, 0)
    list.__pbBlizzList = pieces
    -- The card's own fill, line and grain, and the popup floor, faded under
    -- the art (its middle is the game's dark ground at its own strength).
    Fade(list.Center)
    for i = 1, #BACKDROP_EDGES do Fade(list[BACKDROP_EDGES[i]]) end
    Fade(list.pbSurfaceTexture)
    Fade(list.__pbPopupFloor)
    -- Open, the select's arrow is the open arrow.
    local toggle = list._toggle
    if toggle and toggle.__pbBlizzSelect then
      list:HookScript("OnShow", Parts.ListShown)
      list:HookScript("OnHide", Parts.ListShown)
    end
  end

  function Parts.ListShown(list)
    local toggle = list._toggle
    local sel = toggle and toggle.__pbBlizzSelect
    if not sel then return end
    sel.open = list:IsShown() and true or false
    PaintArrow(toggle)
  end

  -- The chosen mark painted on or off (Dropdown's PaintChosen hands it
  -- over): the dot or the tick, and the words in the game's white as every
  -- row's are; a row set aside is faint, its mark with it.
  local function Mark(row, text, on)
    local m = row.__pbBlizzMark
    if not m then return end
    m.tick:SetShown(on and true or false)
    if on and text then text:SetTextColor(Parts.FontRGB("GameFontHighlight", 1, 1, 1)) end
    local a = (text and text.GetAlpha and text:GetAlpha()) or 1
    m.ring:SetAlpha(a)
    m.tick:SetAlpha(a)
  end

  -- A choice row of a list: which mark it takes, or nil.
  local function KindOf(row)
    if not row._selWash then return nil end
    if row._itemId ~= nil and row._text then return "radio" end
    local item = row.item
    if type(item) == "table" and row.Text then return item.flip and "radio" or "box" end
    return nil
  end

  function Parts.Row(row)
    if row.__pbBlizzMark ~= nil then return end
    row.__pbBlizzMark = false
    local kind = KindOf(row)
    local names = kind and MARKS[kind]
    if not (names and HasAtlas(names[1]) and HasAtlas(names[2])) then return end
    local ring = row:CreateTexture(nil, "ARTWORK")
    Atlas(ring, names[1], true)
    ring:SetPoint("CENTER", row, "LEFT", MARK_X, 0)
    local tick = row:CreateTexture(nil, "OVERLAY")
    Atlas(tick, names[2], true)
    tick:SetPoint("CENTER", row, "LEFT", MARK_X, 0)
    tick:Hide()
    row.__pbBlizzMark = { ring = ring, tick = tick, kind = kind }
    -- The house's chosen wash and bar, faded for good.
    Fade(row._selWash)
    Fade(row._selBar)
    row.__pbChosenMark = Mark
  end
end

-------------------------------------------------------------
-- The options window's Settings parts
-------------------------------------------------------------

-- The options window wears the game's Settings panel parts:
--   * its six tabs are the Settings tabs (MinimalTabTemplate's art,
--     Options_Tab_* at 23 units, the open one Options_Tab_Active_* at 26,
--     both on the plate's foot), on the game's Settings rule across the
--     window under them; inside each a dark ground, the open one taller
--     with a soft gold glow at its top (Postbox's own white tile, tinted in
--     code, as the approved drawing has it). Captions in the game's gold,
--     white when open or pointed at (the template's fonts); the Minimap
--     tab's square stays. Through the skin's StyleTabPlate, which the
--     options call for each tab as it is made; the preview's tabs (made
--     without the pointer) are left as they are.
--   * every checkbox in it (__postboxCheck) is the Settings checkbox, its
--     box and tick (checkbox-minimal, checkmark-minimal) on the same button,
--     at its size and place;
--   * each group heading's rule is the game's Settings rule
--     (Options_HorizontalDivider) where the rule stands, never under a
--     screen pixel; the rule's own line is faded.
-- The Find box is dressed with the search boxes (Parts.Find).
do
  local REST = { "Options_Tab_Left", "Options_Tab_Middle", "Options_Tab_Right" }
  local OPEN = { "Options_Tab_Active_Left", "Options_Tab_Active_Middle", "Options_Tab_Active_Right" }
  local DIVIDER, DIVIDER_RUN = "Options_HorizontalDivider", 8
  -- The ground inside a tab: two units in from its sides and top edge; at
  -- rest a near-black, open a warmer dark under the glow (its gold at a
  -- quarter at the top, none at the foot).
  local IN = 2
  local GROUND_REST, GROUND_OPEN = { 0.04, 0.035, 0.03, 0.84 }, { 0.08, 0.063, 0.04, 0.92 }
  local GLOW = { 1, 0.82, 0, 0.25 }

  local function Has(set)
    for i = 1, 3 do
      if not HasAtlas(set[i]) then return false end
    end
    return true
  end

  -- Three pieces at the art's own height on the plate's foot.
  local function Lay(plate, set)
    local pieces = {}
    for i = 1, 3 do
      local t = plate:CreateTexture(nil, "BACKGROUND", nil, 2)
      Atlas(t, set[i], false)
      pieces[i] = t
    end
    local L, M, R = pieces[1], pieces[2], pieces[3]
    local lw, lh = Parts.Size(set[1])
    local rw = Parts.Size(set[3])
    lh = lh or 23
    L:SetSize(lw or 7, lh)
    L:SetPoint("BOTTOMLEFT", plate, "BOTTOMLEFT", 0, 0)
    R:SetSize(rw or 7, lh)
    R:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", 0, 0)
    M:SetPoint("TOPLEFT", L, "TOPRIGHT", 0, 0)
    M:SetPoint("BOTTOMRIGHT", R, "BOTTOMLEFT", 0, 0)
    pieces.h = lh
    return pieces
  end

  local function Ground(plate, h, color)
    local t = plate:CreateTexture(nil, "BACKGROUND", nil, 1)
    t:SetColorTexture(color[1], color[2], color[3], color[4])
    t:SetPoint("TOPLEFT", plate, "BOTTOMLEFT", IN, h - IN)
    t:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -IN, 0)
    return t
  end

  local function ShowAll(list, on)
    for i = 1, #list do list[i]:SetShown(on) end
  end

  local function PaintTab(plate)
    local art = plate.__pbBlizzOptTab
    if not art then return end
    local open = plate.isSelected and true or false
    ShowAll(art.open, open)
    ShowAll(art.rest, not open)
    art.restGround:SetShown(not open)
    art.openGround:SetShown(open)
    if art.glow then art.glow:SetShown(open) end
    if plate.Text then
      if open or plate.__pbHover then
        plate.Text:SetTextColor(Parts.FontRGB("GameFontHighlight", 1, 1, 1))
      else
        plate.Text:SetTextColor(Parts.FontRGB("GameFontNormal", 1, 0.82, 0))
      end
    end
  end

  function Skin.StyleTabPlate(plate)
    if not plate or plate.__pbBlizzOptTab ~= nil then return end
    plate.__pbBlizzOptTab = false
    -- The options preview's tabs (its window's `Tabs`, made without the
    -- pointer) draw the window as the preview draws it.
    local parent = plate:GetParent()
    if (parent and type(parent.Tabs) == "table")
       or (type(plate.IsMouseEnabled) == "function" and not plate:IsMouseEnabled()) then
      return
    end
    if not (Has(REST) and Has(OPEN)) then return end
    local rest, open = Lay(plate, REST), Lay(plate, OPEN)
    local art = {
      rest = rest, open = open,
      restGround = Ground(plate, rest.h, GROUND_REST), openGround = Ground(plate, open.h, GROUND_OPEN),
    }
    -- The glow: gold at the top of the open tab's ground, fading down.
    local glow = plate:CreateTexture(nil, "BACKGROUND", nil, 1)
    glow:SetColorTexture(1, 1, 1, 1)
    glow:SetPoint("TOPLEFT", art.openGround, "TOPLEFT", 0, 0)
    glow:SetPoint("BOTTOMRIGHT", art.openGround, "BOTTOMRIGHT", 0, 0)
    local mixin = _G.CreateColor
    if type(mixin) == "function" and type(glow.SetGradient) == "function"
       and pcall(glow.SetGradient, glow, "VERTICAL", mixin(GLOW[1], GLOW[2], GLOW[3], 0), mixin(GLOW[1], GLOW[2], GLOW[3], GLOW[4])) then
      art.glow = glow
    else
      glow:Hide()
    end
    plate.__pbBlizzOptTab = art
    plate.__setSelectedOverride = PaintTab
    plate.__pbHoverOverride = PaintTab
    local T = ns.Theme
    if T and type(T.SetPlateSelected) == "function" then T.SetPlateSelected(plate, plate.isSelected) else PaintTab(plate) end
    -- The rule under the tabs: from the first tab dressed to the last, the
    -- run past each end; one per window.
    local frame = plate:GetParent()
    if not (frame and HasAtlas(DIVIDER)) then return end
    local line = frame.__pbBlizzTabRule
    if not line then
      line = frame:CreateTexture(nil, "ARTWORK")
      if not Atlas(line, DIVIDER, false) then
        line:Hide()
        return
      end
      local _, h = Parts.Size(DIVIDER)
      h = h or 1
      local px = T and type(T.OnePixel) == "function" and T.OnePixel(frame) or 1
      if px > h then h = px end
      line:SetHeight(h)
      line:SetPoint("TOPLEFT", plate, "BOTTOMLEFT", -DIVIDER_RUN, 0)
      frame.__pbBlizzTabRule = line
    end
    line:SetPoint("TOPRIGHT", plate, "BOTTOMRIGHT", DIVIDER_RUN, 0)
  end

  -- A checkbox in the options window: the Settings box and tick.
  local CHECK = { box = "checkbox-minimal", tick = "checkmark-minimal", off = "checkmark-minimal-disabled" }
  function Parts.Check(cb)
    if cb.__pbBlizzCheck ~= nil then return end
    cb.__pbBlizzCheck = false
    local window = DressedWindowOf(cb)
    if not (window and window == _G.PostboxOptionsFrame) then return end
    if not (HasAtlas(CHECK.box) and HasAtlas(CHECK.tick)) then return end
    local normal = cb.GetNormalTexture and cb:GetNormalTexture()
    local checked = cb.GetCheckedTexture and cb:GetCheckedTexture()
    if not (normal and checked) then return end
    Atlas(normal, CHECK.box, false)
    local pushed = cb.GetPushedTexture and cb:GetPushedTexture()
    if pushed then Atlas(pushed, CHECK.box, false) end
    local glow = cb.GetHighlightTexture and cb:GetHighlightTexture()
    if glow and Atlas(glow, CHECK.box, false) then glow:SetBlendMode("ADD") end
    Atlas(checked, CHECK.tick, false)
    local off = cb.GetDisabledCheckedTexture and cb:GetDisabledCheckedTexture()
    if off then Atlas(off, HasAtlas(CHECK.off) and CHECK.off or CHECK.tick, false) end
    cb.__pbBlizzCheck = true
  end

  -- A group heading's rule (Rows.Group, tagged __pbGroupHead).
  function Parts.Heading(head)
    if head.__pbBlizzHeading ~= nil then return end
    head.__pbBlizzHeading = false
    local rule = head.Rule
    if not (rule and HasAtlas(DIVIDER)) then return end
    local line = head:CreateTexture(nil, "ARTWORK")
    if not Atlas(line, DIVIDER, false) then
      line:Hide()
      return
    end
    local _, h = Parts.Size(DIVIDER)
    h = h or 1
    local T = ns.Theme
    local px = T and type(T.OnePixel) == "function" and T.OnePixel(head) or 1
    if px > h then h = px end
    line:SetHeight(h)
    line:SetPoint("TOPLEFT", rule, "TOPLEFT", 0, 0)
    line:SetPoint("TOPRIGHT", rule, "TOPRIGHT", 0, 0)
    Fade(rule)
    head.__pbBlizzHeading = line
  end
end

-------------------------------------------------------------
-- Lit states that were Postbox's own plates
-------------------------------------------------------------

-- Three switches drew their "on" as a Postbox plate in every look; under
-- this skin each asks it here (a hook each, which no other look answers):
--   * the options' Test mail (Rows.PaintLead) on is the red button held
--     down, its pressed art, the eye and the word in the game's white;
--   * Arrange's own Test mail (AR.Test.Paint) on is the same red button
--     held down over its plate;
--   * the Arrange key on the title bar, lit (Done), is the small dark
--     button's selected art, its check and word white.
-- Off, each is as before.
do
  local function White(region, isGlyph)
    if not region then return end
    local r, g, b = Parts.FontRGB("GameFontHighlight", 1, 1, 1)
    if isGlyph then region:SetVertexColor(r, g, b, 1) else region:SetTextColor(r, g, b) end
  end

  -- -> true where this skin drew the state (the house's lit plate stays
  -- put away), false to let the house draw it.
  function Skin.PaintLead(btn, label, mark, on)
    if not Parts.HoldButton(btn, on) then return false end
    if not on then return false end
    local lit = btn.Lit
    if lit then
      lit:Hide()
      if lit.Lift then lit.Lift:Hide() end
    end
    White(label)
    White(mark, true)
    return true
  end

  local function Edges(list, a)
    if type(list) ~= "table" then return end
    for i = 1, #list do list[i]:SetAlpha(a) end
  end

  function Skin.PaintTestSwitch(b, on)
    if not Parts.HeldArt(b, on) then return end
    local a = on and 0 or 1
    if b.Fill then b.Fill:SetAlpha(a) end
    Edges(b.Ring, a)
    Edges(b.Key, a)
    if on then
      White(b.Label)
      White(b.Eye, true)
    end
  end

  -- The key, lit: the selected art alone, laid by its rim on the key; the
  -- house's lit plate (fill, wash, ring, keyline, edge, underline, lift)
  -- put away. Unlit, the house shows what it shows and the art goes.
  function Skin.PaintKey(button, lit)
    local art = button.__pbBlizzKey
    if not lit then
      if art then
        for i = 1, 3 do art[i]:Hide() end
      end
      return
    end
    if art == nil then
      art = Parts.SmallArt(button) or false
      button.__pbBlizzKey = art
    end
    if not art then return end
    local h = button:GetHeight()
    if type(h) ~= "number" or h <= 0 then return end
    if art.h ~= h then
      art.h = h
      Parts.LaySmall(art, button, "lit", "alone", 0, h)
    end
    for i = 1, 3 do art[i]:Show() end
    if button.Fill then button.Fill:Hide() end
    if button.Wash then button.Wash:Hide() end
    if button.Base then button.Base:Hide() end
    if button.Bevel then button.Bevel:Hide() end
    if button.Lift then button.Lift:Hide() end
    if type(button.Ring) == "table" then for i = 1, #button.Ring do button.Ring[i]:Hide() end end
    if type(button.Key) == "table" then for i = 1, #button.Key do button.Key[i]:Hide() end end
    White(button.Label)
    White(button.Check, true)
  end
end

-- One tagged child: what this skin dresses on it, each once.
function Parts.DressOne(c)
  if c.SlimBar and c.SlimBar.__pbBlizzBar == nil and c:IsObjectType("ScrollFrame") then Parts.ScrollBar(c.SlimBar) end
  if c.__postboxInputWrap and c.__pbBlizzField == nil then Parts.Field(c) end
  if c.__postboxPanel and not c.__pbBlizzInset and Sinks(c) then SinkPanel(c) end
  if c.__postboxPanel == "band" and c.__pbBlizzBand == nil and Parts.IsTotals(c) then Parts.Totals(c) end
  if c.__postboxButton and not c.__postboxSelect and c.__pbBlizzButton == nil and c:IsObjectType("Button") then
    Parts.Button(c)
  end
  if c.__postboxCheck and c.__pbBlizzCheck == nil and c:IsObjectType("CheckButton") then Parts.Check(c) end
  if c.__pbGroupHead and c.__pbBlizzHeading == nil then Parts.Heading(c) end
  if c.__pbFindBox and c.__pbBlizzFind == nil then Parts.Find(c) end
  if c.__postboxSelect and c.__pbBlizzSelect == nil and c:IsObjectType("Button") then Parts.Select(c) end
  if c.__pbPopupAlways and c._toggle and c.__pbBlizzList == nil then Parts.List(c) end
  if c._selWash and c.__pbBlizzMark == nil then Parts.Row(c) end
  if c.__pbVariant and c.__pbBlizzSeg == nil and Parts.IsSeg(c) then Parts.Seg(c) end
  if c.__pbVariant and c.__pbBlizzCell == nil then
    local p = c:GetParent()
    if p and p.SentClock == c and p.FillButton then Parts.SentCell(c, p.FillButton) end
  end
end

-------------------------------------------------------------
-- The pass over tagged content
-------------------------------------------------------------

-- Depth-first, eight levels down, on one stack reused by every walk (no
-- garbage); a walk begun inside a walk takes a stack of its own.
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

  local function Walk(frame, st, dp)
    local n = Push(st, dp, 0, 1, frame:GetChildren())
    while n > 0 do
      local c, d = st[n], dp[n]
      st[n], dp[n] = nil, nil
      n = n - 1
      if c then
        if c.IsObjectType then Parts.DressOne(c) end
        if d <= 8 then n = Push(st, dp, n, d + 1, c:GetChildren()) end
      end
    end
  end

  SkinTree = function(frame)
    if not frame or type(frame.GetChildren) ~= "function" then return end
    if busy then return Walk(frame, {}, {}) end
    busy = true
    pcall(Walk, frame, stack, depths)
    for i = #stack, 1, -1 do stack[i], depths[i] = nil, nil end
    busy = false
  end
end

function Skin.Refresh(frame)
  if not frame then return end
  pcall(SkinTree, frame)
end

-- A window already walked at the current skin generation (Theme
-- SkinGeneration: it moves whenever a frame is tagged for the skins) is
-- left as it is.
local walkedAt = setmetatable({}, { __mode = "k" })

function Skin.RefreshWindow(frame)
  if not frame then return end
  local T = ns.Theme
  local gen = T and type(T.SkinGeneration) == "function" and T.SkinGeneration() or nil
  if gen ~= nil and walkedAt[frame] == gen then return end
  Skin.Refresh(frame)
  walkedAt[frame] = gen
end

-------------------------------------------------------------
-- Apply
-------------------------------------------------------------

-- A Postbox window, dressed once: the template's thin frame, title tile,
-- marble and bevel faded where the metal frame replaces them; the rock
-- untinted with the streaks; then the panels inside it. The close button is
-- the template's own (the red RedButton-Exit art on both clients) and is
-- left exactly as it is, its click included: the Postbox window gives it
-- its own handler (Core/MailboxUI.lua), the other windows keep theirs.
function Skin.Apply(frame)
  if not frame or frame.__pbBlizzWindow then return end
  frame.__pbBlizzWindow = true
  -- The shared claim record the other skins and the debug report read.
  ns.SkinAppliedBy = "blizzard"

  -- Without the metal (a client missing a piece), the template's own thin
  -- frame stays: a window is never left without a frame.
  if LayFrame(frame) then
    for i = 1, #TEMPLATE_FRAME do Fade(frame[TEMPLATE_FRAME[i]]) end
  end
  for i = 1, #TEMPLATE_GROUND do Fade(frame[TEMPLATE_GROUND[i]]) end
  if frame.Inset then
    Fade(frame.Inset.Bg)
    if frame.Inset.NineSlice then frame.Inset.NineSlice:SetAlpha(0) end
  end
  LayGround(frame)
  -- The main window's Mail and Send tabs (no other window has TabButtons).
  Parts.Tabs(frame)
  Skin.Refresh(frame)
end

-- The secondary windows (options, Mail Memory, groups, recipients, What's
-- new, the bug report): the same shell.
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
  if UI.GetStyleChoice() ~= "blizzard" then return end
  if ns.Skin then return end
  ns.Skin = Skin
end)
