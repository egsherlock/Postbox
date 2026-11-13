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
-- every field and search box. The options' tabs, other plates, joined
-- cells, other bands, dropdowns, rows and the scroll bar draw as they did.
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
    if art.m ~= m then
      art.m = m
      L:ClearAllPoints()
      L:SetPoint("TOPLEFT", button, "TOPLEFT", -m, m)
      R:ClearAllPoints()
      R:SetPoint("TOPRIGHT", button, "TOPRIGHT", m, m)
    end
  end

  -- The art for the button's state: disabled, pressed, or at rest.
  local function Paint(button)
    local art = button.__pbBlizzButton
    if not art then return end
    local state = "up"
    if not button:IsEnabled() then state = "off" elseif art.down then state = "down" end
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
      end
    end
    button:HookScript("OnMouseDown", Down)
    button:HookScript("OnMouseUp", Up)
    button:HookScript("OnShow", Up)
    button:HookScript("OnEnable", Paint)
    button:HookScript("OnDisable", Paint)
    button:HookScript("OnSizeChanged", Fit)
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

  local function LaySearch(wrap, search)
    for i = 1, 3 do
      if not HasAtlas(SEARCH[i]) then return nil end
    end
    local h = wrap:GetHeight()
    if type(h) ~= "number" or h <= 0 then h = 24 end
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
    -- The magnifier, and the words after it, as the template places them,
    -- grown with the box.
    local k = h / BOX_H
    if HasAtlas(GLASS) then
      local glass = wrap:CreateTexture(nil, "ARTWORK")
      if Atlas(glass, GLASS, false) then
        glass:SetSize(GLASS_SIZE * k, GLASS_SIZE * k)
        glass:SetPoint("LEFT", wrap, "LEFT", GLASS_X * k, GLASS_Y * k)
        pieces[4] = glass
        local lead = math.floor(TEXT_X * k + 0.5)
        wrap.__pbTextLead = lead
        if search.Box then search.Box:SetPoint("TOPLEFT", wrap, "TOPLEFT", lead, -2) end
        if search.Placeholder then search.Placeholder:SetPoint("TOPLEFT", wrap, "TOPLEFT", lead, -2) end
        -- The words' room, measured again with the new lead.
        if type(search.Place) == "function" then search.Place(search.toggled) end
      end
    end
    return pieces
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

-- One tagged child: what this skin dresses on it, each once.
function Parts.DressOne(c)
  if c.__postboxInputWrap and c.__pbBlizzField == nil then Parts.Field(c) end
  if c.__postboxPanel and not c.__pbBlizzInset and Sinks(c) then SinkPanel(c) end
  if c.__postboxPanel == "band" and c.__pbBlizzBand == nil and Parts.IsTotals(c) then Parts.Totals(c) end
  if c.__postboxButton and not c.__postboxSelect and c.__pbBlizzButton == nil and c:IsObjectType("Button") then
    Parts.Button(c)
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
