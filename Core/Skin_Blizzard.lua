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
-- A SKIN, like Core/Skin_Postbox.lua: it claims ns.Skin at PLAYER_LOGIN
-- when the style choice is "blizzard" (the default where no host UI is
-- installed), and rides the same contract (Apply / ApplyWindow / Refresh /
-- RefreshWindow over the tagged children). It also takes the window when
-- the EllesmereUI skin stands down to Postbox's own look (EllesmereUI on its
-- Blizzard Style or Classic WoW UI look, or its skinning switched off for
-- Postbox: Skin.HostStoodDown, at the end of this file). Otherwise it never
-- claims, so the Postbox style, EllesmereUI and ElvUI run exactly the code
-- they ran before this file existed.
--
-- It answers only what it dresses. Everything a skin may publish and this
-- one does not (GetAccent, GetHostBaseline, StyleTabPlate, ButtonTextRGB,
-- the appearance getters...) is asked for by presence, so leaving it out
-- keeps the game's own answer, as when no skin claimed. Its GetFontFace
-- (Text, below) answers the game's own at its defaults. The places that read "no skin" as "the game's own look" ask
-- Theme.NativeLook() instead, which says yes for this skin too.
--
-- A surface treatment only: no frame moves or changes size, and nothing is
-- shown, hidden or created in combat that is not already. Each frame is
-- dressed once and tagged; a walk over a window finds work only where
-- something new was tagged since the last one.
--
-- Dressed so far: the window frame, the sunken panels, the main window's
-- Mail and Send tabs, every push button, the Mail tab's totals strip and
-- the bar over finished mail, every field and search box, every list's scroll bar, every segment and
-- tile (one strip where they are joined, and a field's last cell joined to
-- its field), the Sent clock as a cell of Send mail, the dropdowns and their
-- lists, the options' tabs, checkboxes, heading rules, Find box and footer
-- buttons, and the lit Test mail switches and Arrange key; the mail rows
-- stand on the ground Row texture chooses (the game's letter paper by
-- default), with inks of their own. Other bands and the options preview
-- draw as they did.
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
-- blank, never an error. The whole piece: the client keeps a crop the
-- texture already carried (SetTexCoord, a template's own) and applies it
-- inside the new piece, so the crop is cleared here and a caller that wants
-- one sets it after this.
local function Atlas(texture, name, useSize)
  if not HasAtlas(name) then return false end
  if not pcall(texture.SetAtlas, texture, name, useSize and true or false) then return false end
  texture:SetTexCoord(0, 1, 0, 1)
  return true
end

-- A button's hover glow from an atlas (SetHighlightAtlas), whole: the game's
-- classic button, which Postbox's push buttons are made from, crops its own
-- highlight file (its left five eighths, its top eleven sixteenths), and
-- that crop would cut the new glow the same way and throw its light to the
-- bottom right. -> the glow's texture, or nil.
local function Glow(button, name)
  if not (HasAtlas(name) and pcall(button.SetHighlightAtlas, button, name)) then return nil end
  local glow = button:GetHighlightTexture()
  if glow then glow:SetTexCoord(0, 1, 0, 1) end
  return glow
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

-- The frame stands evenly about the window. The game's layout for it is
-- not centred on the frame it dresses (its left corners stand 8 units out,
-- its right ones 4, or 2 on WoW Forever), and the two clients' art carries
-- its metal at different places in the pieces: so the visible border's inner
-- edge stood 7.5 units in on the left and 2.5 on the right on retail, 10.5
-- and 6.5 on Forever, where the bronze is 7 units thick and its foot 6 above
-- the window's bottom. Postbox's content stands evenly in its windows, so it
-- sat to the left between the borders, and on Forever touched the left one.
-- Once the client's layout is laid, the corners are seated again so that the
-- metal's inner edge stands EDGE units in from the window's left, right and
-- bottom on both clients; the title band keeps the client's own height.
--
-- Where the metal's inner edge stands in each piece, in units from the
-- piece's outer side (the side the piece is anchored by): the left pieces
-- from their left, the right pieces from their right, the bottom pieces from
-- their bottom. Measured from each client's own art where it is more than
-- half opaque (retail's 2x metal, Forever's c60 bronze). Keyed by the side
-- piece's own width (Parts.Size), so the numbers are only ever used on the
-- art they were measured from: a UI pack's own frame art of another size
-- keeps the client's layout as it is.
do
  local EDGE = 4
  local METAL = {
    [75] = { left = 15.5, right = 6.5, bottom = 6.5 },   -- retail: metal 13.0-15.5 of 75 wide; foot rows 25.5-28.0 of 32
    [95] = { left = 18.5, right = 8.5, bottom = 14 },    -- Forever: bronze 11.5-18.5 and 86.5-93.5 of 95; foot rows 86-95 of 100
  }
  local CORNERS = {
    { "TopLeftCorner", "left" }, { "BottomLeftCorner", "left", true },
    { "TopRightCorner", "right" }, { "BottomRightCorner", "right", true },
  }
  -- The four corners seated by the rule, each keeping its anchor point and,
  -- for the top ones, the client's own height; the edges run between the
  -- corners, so they follow. All four or none: each anchor is read before
  -- any moves. -> true if seated.
  local anchors = {}
  function Parts.SeatFrame(pieces)
    local m = METAL[Parts.Size("!UI-Frame-Metal-EdgeLeft") or 0]
    if not m or type(pieces) ~= "table" then return false end
    for i = 1, #CORNERS do
      local piece = pieces[CORNERS[i][1]]
      if not piece then return false end
      local point, rel, relPoint, _, y = piece:GetPoint(1)
      if type(point) ~= "string" or type(relPoint) ~= "string" or type(y) ~= "number" then return false end
      local a = anchors[i] or {}
      anchors[i] = a
      a[1], a[2], a[3], a[4] = point, rel, relPoint, y
    end
    for i = 1, #CORNERS do
      local c, a = CORNERS[i], anchors[i]
      local piece = pieces[c[1]]
      local x = c[2] == "left" and (EDGE - m.left) or (m.right - EDGE)
      local y = c[3] and (EDGE - m.bottom) or a[4]
      piece:ClearAllPoints()
      piece:SetPoint(a[1], a[2], a[3], x, y)
      a[2] = nil
    end
    return true
  end
end

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
  pcall(Parts.SeatFrame, holder.__pbPieces)
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
-- Background opacity
-------------------------------------------------------------

-- Options > Window > Background opacity (MailboxUI.GetBlizzOpacity): the
-- window's rock and its streaks drawn at the chosen strength, so the world
-- shows through them. Everything standing on the rock keeps its own ground
-- and stays solid: the metal frame and its title band, the lists and cards
-- with their dark grounds and bevels, the mail rows' paper, the fields, the
-- buttons, the tabs, the totals strip. The windows every style keeps solid
-- (__pbEuiAlwaysOpaque: the options, Mail Memory, Character Groups, What's
-- new, the bug report) keep their rock whole; the mailbox window and Manage
-- Recipients take the strength.
--
-- The words that stand on the rock itself (the ones Postbox tells Theme
-- stand on the bare window, Theme.OnWindow: the Send tab's captions, its
-- cost and guidance lines, the Mail tab's hint and notes, Manage Recipients'
-- count) would go with it. Under each, while the rock is weaker than FLOOR,
-- a patch of the same rock is laid round the words, at the strength that
-- puts the rock under them back at FLOOR: the least at which the game's gold
-- (the captions), the warning orange and the notes' gray all read at 4.5:1
-- over a white world behind the window (the rock's brightest tenth, 0.031
-- luminance; gold needs 0.93, the orange 0.94, the gray 0.80). The patch is
-- the rock under the rock, so at 95% and above there is none, and below it
-- the words keep the ground they have at 100%.
--
-- Solid, the default, is the look as it was: no rock is touched and no
-- word looked for until the setting is moved off 100%. A change is one pass
-- over the windows built (Theme.ForEachWindow); a window dressed later takes
-- the strength as it is dressed or walked.
do
  local FLOOR = 0.94
  local PAD_X, PAD_Y = 4, 2
  local O = { alpha = 1, read = false }
  Parts.Opacity = O
  -- font string -> the patch under it, and the window it stands in.
  local patches = setmetatable({}, { __mode = "k" })
  local FOLLOWED = { "SetText", "SetFormattedText", "Show", "Hide", "SetShown" }

  local function Rock(frame) return frame.pbWindowStone end

  -- The patch's strength over a rock at `a`: 1 - (1 - FLOOR) / (1 - a), so
  -- the two together cover FLOOR of the world; none at FLOOR and above.
  local function PatchAlpha(a)
    if a >= FLOOR then return 0 end
    return 1 - (1 - FLOOR) / (1 - a)
  end

  -- The patch round the words, on the side they are justified to, shown
  -- only under words that show. Its parent is the text's parent, so it does
  -- not hide with the text by itself.
  local function Paint(fs)
    local patch = patches[fs]
    if not patch then return end
    local p = PatchAlpha(O.alpha)
    local text = (p > 0) and fs:IsShown() and fs:GetText() or nil
    if not text or text == "" then
      if patch:IsShown() then patch:Hide() end
      return
    end
    local w = fs:GetStringWidth() or 0
    local box = fs:GetWidth() or 0
    if box > 0 and w > box then w = box end
    patch:SetWidth(w + 2 * PAD_X)
    patch:SetAlpha(p)
    patch:Show()
  end

  local function Lay(fs, patch)
    local side = type(fs.GetJustifyH) == "function" and fs:GetJustifyH() or "LEFT"
    if side == "RIGHT" then
      patch:SetPoint("TOPRIGHT", fs, "TOPRIGHT", PAD_X, PAD_Y)
      patch:SetPoint("BOTTOMRIGHT", fs, "BOTTOMRIGHT", PAD_X, -PAD_Y)
    elseif side == "CENTER" then
      patch:SetPoint("TOP", fs, "TOP", 0, PAD_Y)
      patch:SetPoint("BOTTOM", fs, "BOTTOM", 0, -PAD_Y)
    else
      patch:SetPoint("TOPLEFT", fs, "TOPLEFT", -PAD_X, PAD_Y)
      patch:SetPoint("BOTTOMLEFT", fs, "BOTTOMLEFT", -PAD_X, -PAD_Y)
    end
  end

  -- One word on the window's rock: its patch, made once, and its methods
  -- followed so the patch keeps to its words.
  local function Patch(fs, rock)
    if patches[fs] then return end
    local parent = fs:GetParent()
    if not parent or type(parent.CreateTexture) ~= "function" then return end
    -- Over the window's rock and streaks, under the words.
    local patch = parent:CreateTexture(nil, "BACKGROUND", nil, 7)
    patch:Hide()
    patch:SetTexture(rock:GetTexture() or "Interface\\FrameGeneral\\UI-Background-Rock")
    patch:SetHorizTile(true)
    patch:SetVertTile(true)
    patch.__pbBlizzPatch = true
    Lay(fs, patch)
    patches[fs] = patch
    if type(hooksecurefunc) == "function" then
      for i = 1, #FOLLOWED do
        if type(fs[FOLLOWED[i]]) == "function" then hooksecurefunc(fs, FOLLOWED[i], Paint) end
      end
    end
  end

  -- The words among `...` (a frame's regions) that stand on the bare
  -- window: Theme was told so (Theme.OnWindow, ground "window").
  local function Words(rock, ...)
    local G = ns.Theme and ns.Theme._Grounds
    if not (G and G.Of) then return end
    for i = 1, select("#", ...) do
      local r = select(i, ...)
      if r and not patches[r] and G.Of(r) == "window" and r:IsObjectType("FontString") then Patch(r, rock) end
    end
  end

  -- Every frame under the window, ten levels down; no table is made.
  local function Walk(rock, depth, ...)
    for i = 1, select("#", ...) do
      local c = select(i, ...)
      if c and type(c.GetRegions) == "function" then
        Words(rock, c:GetRegions())
        if depth < 10 then Walk(rock, depth + 1, c:GetChildren()) end
      end
    end
  end

  -- One dressed window at the strength in force: its rock and streaks, and,
  -- while it is under 100%, a patch under each word on its rock (new words
  -- found on each walk).
  function O.Window(frame)
    if not (frame and frame.__pbBlizzWindow) or frame.__pbEuiAlwaysOpaque then return end
    local rock = Rock(frame)
    if not rock then return end
    local a = O.alpha
    rock:SetAlpha(a)
    if frame.__pbBlizzStreaks then frame.__pbBlizzStreaks:SetAlpha(a) end
    if a < 1 then
      Words(rock, frame:GetRegions())
      Walk(rock, 1, frame:GetChildren())
    end
  end

  -- The setting as saved, read once at the first window dressed.
  function O.Read()
    if O.read then return end
    O.read = true
    local UI = ns.MailboxUI
    O.alpha = UI and type(UI.GetBlizzOpacity) == "function" and UI.GetBlizzOpacity() or 1
  end

  -- The setting changed (Options > Window, or a reset): every window built
  -- at the new strength, every patch with it.
  function Skin.OpacityChanged()
    local UI = ns.MailboxUI
    O.read = true
    O.alpha = UI and type(UI.GetBlizzOpacity) == "function" and UI.GetBlizzOpacity() or 1
    local T = ns.Theme
    if T and type(T.ForEachWindow) == "function" then T.ForEachWindow(O.Window) end
    for fs in pairs(patches) do Paint(fs) end
  end
  -- A window walked while under 100%: the words it holds now, patched.
  function O.Walked(frame)
    if O.alpha < 1 then
      O.Window(frame)
      for fs in pairs(patches) do Paint(fs) end
    end
  end
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
--
-- Options > Window > Buttons (MailboxUI.GetButtonLook) says which of them
-- wear the red button: "red", all of them; "mailred" (the default), the ones
-- that collect or send mail -- All mail with its gold rim and the category
-- buttons (the grid's, `gridId`), Send mail with its Sent cell, and the
-- reading view's Take all and Return -- and every other push button the
-- game's small dark button (the segments' art, laid by its rim, Parts.LaySmall:
-- its hover, pressed, selected and disabled art, the words and marks in the
-- game's gold); "dark", every push button the dark one, All mail without a
-- rim (the game has no dark button with one). A switch held on (Test mail)
-- is the dark button's selected art. The switches (segments, tiles, tabs,
-- dropdowns) are the dark art in every choice. The choice is read when it
-- changes (Skin.ButtonLookChanged), and each button keeps both arts once it
-- has worn both.
do
  local RIM = 10 / 128
  -- Every button and footer frame wearing this art, for a change of the
  -- choice; the Sent cells too.
  local dressed = setmetatable({}, { __mode = "k" })
  local cells = setmetatable({}, { __mode = "k" })
  Parts.ButtonLook = false

  -- A button that collects or sends mail (above).
  local function IsMail(button)
    if button.gridId ~= nil then return true end
    local p = button:GetParent()
    if p and p.FillButton == button then return true end
    local d = p and p:GetParent()
    if d and d.ActionRow == p and (d.Collect == button or d.Return == button) then return true end
    return false
  end

  local function LookNow()
    if not Parts.ButtonLook then
      local UI = ns.MailboxUI
      Parts.ButtonLook = UI and type(UI.GetButtonLook) == "function" and UI.GetButtonLook() or "mailred"
    end
    return Parts.ButtonLook
  end

  local function KindOf(art)
    local look = LookNow()
    if look == "red" or (look == "mailred" and art.mail) then return "red" end
    return "dark"
  end

  -- The dark button's state: disabled, held on, pressed, pointed at, at rest.
  local function DarkState(button, art)
    if type(button.IsEnabled) == "function" and not button:IsEnabled() then return "off" end
    if art.held then return "lit" end
    if art.down then return "down" end
    if art.over then return "over" end
    return "up"
  end

  -- The dark button laid round its box for its state; a Send mail with its
  -- cell shown has no left end (the cell's art runs into it).
  local function PaintDark(button)
    local art = button.__pbBlizzButton
    local d = art.dark
    if d == nil then
      d = Parts.SmallArt and Parts.SmallArt(button) or false
      art.dark = d
    end
    if not d then return end
    local box = art.box or button
    local h = box:GetHeight()
    if type(h) ~= "number" or h <= 0 then return end
    local state = DarkState(button, art)
    local role = (art.cell ~= nil and art.cell:IsShown()) and "last" or "alone"
    if d.state ~= state or d.h ~= h or d.role ~= role then
      d.state, d.h, d.role = state, h, role
      Parts.LaySmall(d, box, state, role, 0, h)
    end
    local show = not art.hidden
    if role == "alone" then d[1]:SetShown(show) end
    d[2]:SetShown(show)
    d[3]:SetShown(show)
  end
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
    if art.kind == "dark" then return PaintDark(button) end
    -- The box the art is laid round: the button, or a box of its own (the
    -- options' footer, Parts.FooterButton).
    local box = art.box or button
    local w, h = box:GetWidth(), box:GetHeight()
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
      L:SetPoint("TOPLEFT", box, "TOPLEFT", -m, m)
      R:ClearAllPoints()
      R:SetPoint("TOPRIGHT", box, "TOPRIGHT", m, m)
      local M = art[2]
      M:ClearAllPoints()
      if joined then
        M:SetPoint("TOPLEFT", box, "TOPLEFT", 0, m)
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
    local kind = KindOf(art)
    if art.kind ~= kind then
      art.kind, art.state, art.m = kind, nil, false
      local red = kind == "red"
      local d = art.dark
      if d then
        d.state = nil
        for i = 1, 3 do d[i]:SetShown(not red and not art.hidden) end
        d.line:Hide()
      end
      if red then
        art[2]:SetShown(not art.hidden)
        art[3]:SetShown(not art.hidden)
      else
        for i = 1, 3 do art[i]:Hide() end
      end
      -- The red button's glow is the red art's; the dark one lights by its art.
      if art.glow then art.glow:SetAlpha(red and 1 or 0) end
      -- A button that inks its own words by the art it wears (Parts.Tile).
      if art.onKind then art.onKind(button) end
    end
    if kind == "dark" then return PaintDark(button) end
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

  local function Over(button)
    local art = button.__pbBlizzButton
    if art then
      art.over = true
      if art.kind == "dark" then Paint(button) end
    end
  end

  local function Out(button)
    local art = button.__pbBlizzButton
    if art then
      art.over, art.down = false, false
      if art.kind == "dark" then Paint(button) end
    end
  end

  function Parts.Button(button)
    if button.__pbBlizzButton ~= nil then return end
    button.__pbBlizzButton = false
    local names = (GOLD_ALL_MAIL and button.gridId == "all") and GOLD or RED
    if not Has(names) then return end
    local art = { names = names, m = false, mail = IsMail(button) }
    for i = 1, 3 do art[i] = button:CreateTexture(nil, "BACKGROUND", nil, 1) end
    art[2]:SetPoint("TOPLEFT", art[1], "TOPRIGHT", 0, 0)
    art[2]:SetPoint("BOTTOMRIGHT", art[3], "BOTTOMLEFT", 0, 0)
    button.__pbBlizzButton = art
    dressed[button] = true
    -- The template's own three pieces, faded under the new art.
    Fade(button.Left)
    Fade(button.Middle)
    Fade(button.Right)
    -- The game's glow over the whole art, as its template sets it.
    local glow = Glow(button, names.highlight)
    if glow then
      glow:ClearAllPoints()
      glow:SetPoint("TOPLEFT", art[1], "TOPLEFT", 0, 0)
      glow:SetPoint("BOTTOMRIGHT", art[3], "BOTTOMRIGHT", 0, 0)
      art.glow = glow
    end
    Paint(button)
    button:HookScript("OnMouseDown", Down)
    button:HookScript("OnMouseUp", Up)
    button:HookScript("OnEnter", Over)
    button:HookScript("OnLeave", Out)
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
      dressed[frame] = true
      Paint(frame)
      frame:HookScript("OnSizeChanged", Fit)
    end
    if not art then return false end
    on = on and true or false
    art.hidden = not on
    if art.dark then art.dark.state = nil end
    Paint(frame)
    if art.kind == "red" then
      art[1]:SetShown(on and not art.joined)
      art[2]:SetShown(on)
      art[3]:SetShown(on)
    end
    return true
  end

  ---------------------------------------------------------------
  -- The options' footer: three red buttons on the window's stone
  ---------------------------------------------------------------

  -- Reset to defaults, Report a bug and What's new? are words (and marks)
  -- on the footer's band, each a plain frame sized to its words. Here each
  -- wears the newer red button round its words, standing straight on the
  -- window's stone: the band's own fill, line and grain are not drawn. The
  -- button is the band's height (24, the height the words are centred in),
  -- its face PAD units past the words at each side, as a button of that
  -- height carries them. The two outer faces end where the band does, so
  -- they line up with the panes above, and their words are moved in to keep
  -- the same PAD there: Reset to defaults with its mark PAD in from the
  -- band's left end, What's new? PAD in from its right (Ends; Footer.Fit
  -- reads the two from `resetX` and `newsX`). Report a bug and the version
  -- line do not move.
  --
  -- The art is laid on the frame that owns the words (Reset's and What's
  -- new?'s buttons, the band for Report a bug), under them, round a box of
  -- its own (an empty frame anchored to the words), so it follows them when
  -- the footer is measured again. The frame's pressed state presses it, its
  -- hover shows the game's glow; each click area is the art (reset and What's
  -- new? a little larger, the band only where Report a bug's art stands).
  local PAD = 12

  local function BoxSized(box)
    local owner = box.__pbOwner
    if owner then Fit(owner) end
  end

  -- The art on `owner`, round `box`. -> the art, or nil.
  local function BoxArt(owner, box)
    if owner.__pbBlizzButton ~= nil or not Has(RED) then return nil end
    local art = { names = RED, m = false, box = box, mail = false }
    for i = 1, 3 do art[i] = owner:CreateTexture(nil, "BACKGROUND", nil, 1) end
    art[2]:SetPoint("TOPLEFT", art[1], "TOPRIGHT", 0, 0)
    art[2]:SetPoint("BOTTOMRIGHT", art[3], "BOTTOMLEFT", 0, 0)
    owner.__pbBlizzButton = art
    dressed[owner] = true
    box.__pbOwner = owner
    local glow = Glow(owner, RED.highlight)
    if glow then
      glow:ClearAllPoints()
      glow:SetPoint("TOPLEFT", art[1], "TOPLEFT", 0, 0)
      glow:SetPoint("BOTTOMRIGHT", art[3], "BOTTOMRIGHT", 0, 0)
      art.glow = glow
    end
    Paint(owner)
    owner:HookScript("OnMouseDown", Down)
    owner:HookScript("OnMouseUp", Up)
    owner:HookScript("OnEnter", Over)
    owner:HookScript("OnLeave", Out)
    owner:HookScript("OnShow", Up)
    box:SetScript("OnSizeChanged", BoxSized)
    return art
  end

  -- The band's click area: Report a bug's art, measured again each time
  -- the footer lays its words (Footer.Fit sets the words' place).
  local function BandHits(text)
    local f = text.__pbFooterOf
    local band = f and f.band
    if not (band and band.__pbBlizzButton) then return end
    -- The art round the words where they now stand.
    Fit(band)
    local _, _, _, x = text:GetPoint(1)
    local bandW = band:GetWidth()
    local tw = text:GetStringWidth()
    if type(x) ~= "number" or type(bandW) ~= "number" or bandW <= 0 or type(tw) ~= "number" then return end
    local lead = f.bugGlyph and (f.bugMark or 0) + 2 + (f.bugGap or 0) or 0
    local left = math.max(0, x - lead - PAD)
    local right = math.max(0, bandW - (x + tw + PAD))
    band:SetHitRectInsets(left, right, 0, 0)
  end

  -- The two outer items moved in from the band's ends: Reset's frame so
  -- that its mark (2 into the frame; its words 4 in where there is no mark)
  -- starts PAD from the band's left end, What's new?'s so that its words
  -- end PAD from the band's right. Footer.Fit keeps Report a bug clear of
  -- the two where they now stand.
  local function Ends(f, band)
    if f.reset and f.resetText then
      local x = PAD - (f.resetArrow and 2 or 4)
      f.reset:ClearAllPoints()
      f.reset:SetPoint("TOPLEFT", band, "TOPLEFT", x, 0)
      f.reset:SetPoint("BOTTOMLEFT", band, "BOTTOMLEFT", x, 0)
      f.resetX = x
    end
    if f.news and f.newsText then
      f.news:ClearAllPoints()
      f.news:SetPoint("TOPRIGHT", band, "TOPRIGHT", -PAD, 0)
      f.news:SetPoint("BOTTOMRIGHT", band, "BOTTOMRIGHT", -PAD, 0)
      f.newsX = PAD
    end
  end

  function Parts.FooterButtons(band)
    local f = band.__pbFooter
    if type(f) ~= "table" or band.__pbBlizzFootArt ~= nil then return end
    band.__pbBlizzFootArt = false
    if not Has(RED) then return end
    local h = band:GetHeight()
    if type(h) ~= "number" or h <= 0 then h = 24 end
    local half = h / 2
    band.__pbBlizzFootArt = true
    Ends(f, band)
    -- The band itself is not drawn.
    Fade(band.Center)
    for i = 1, #BACKDROP_EDGES do Fade(band[BACKDROP_EDGES[i]]) end
    Fade(band.pbSurfaceTexture)
    -- Report a bug: on the band, round its mark and words.
    if f.bugText then
      -- Both corners on the words (centred on the band), the mark's room
      -- before them: the mark is centred 11 units plus the gap before the
      -- words, 16 wide (Footer.Build).
      local lead = f.bugGlyph and (f.bugMark or 0) + 2 + (f.bugGap or 0) or 0
      local box = CreateFrame("Frame", nil, band)
      box:SetPoint("TOPLEFT", f.bugText, "LEFT", -PAD - lead, half)
      box:SetPoint("BOTTOMRIGHT", f.bugText, "RIGHT", PAD, -half)
      if BoxArt(band, box) then
        f.bugText.__pbFooterOf = f
        hooksecurefunc(f.bugText, "SetPoint", BandHits)
        BandHits(f.bugText)
      end
    end
    -- Reset to defaults: from the band's left end to PAD past its caret.
    local reset = f.reset
    if reset and f.resetText then
      local last = f.resetCaret or f.resetText
      local box = CreateFrame("Frame", nil, reset)
      box:SetPoint("TOPLEFT", band, "TOPLEFT", 0, 0)
      box:SetPoint("BOTTOMRIGHT", last, "RIGHT", PAD, -half)
      if BoxArt(reset, box) then
        -- The click area out to the art: the frame stands in from the
        -- band's end (Ends), and ends 18 past its words (4 without a caret).
        local _, _, _, x = reset:GetPoint(1)
        local over = (f.resetCaret and 12 or 0) + PAD - (f.resetCaret and 18 or 4)
        reset:SetHitRectInsets(-(tonumber(x) or 0), -math.max(0, over), 0, 0)
      end
    end
    -- What's new?: from PAD before its words to the band's right end.
    local news = f.news
    if news and f.newsText then
      local box = CreateFrame("Frame", nil, news)
      box:SetPoint("TOPLEFT", f.newsText, "LEFT", -PAD, half)
      box:SetPoint("BOTTOMRIGHT", band, "BOTTOMRIGHT", 0, 0)
      if BoxArt(news, box) then
        local _, _, _, x = news:GetPoint(1)
        news:SetHitRectInsets(-PAD, -math.max(0, -(tonumber(x) or 0)), 0, 0)
      end
    end
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

  -- Under the dark Send mail, the cell is the dark art's first cell: its
  -- left end on the clock, its middle on through the gap into the button's
  -- art (PaintDark gives the button no left end while the cell shows).
  local function DarkCell(clock, cell, dark)
    local d = cell.dark
    if dark and d == nil then
      d = Parts.SmallArt and Parts.SmallArt(clock) or false
      cell.dark = d
    end
    cell[1]:SetShown(not dark)
    cell[2]:SetShown(not dark)
    if not d then return false end
    if not dark then
      for i = 1, 3 do d[i]:Hide() end
      d.line:Hide()
      d.state = nil
      return false
    end
    local h = clock:GetHeight()
    if type(h) ~= "number" or h <= 0 then return true end
    local state = cell.down and "down" or (clock.__pbHover and "over" or "up")
    local l, r = cell.button:GetLeft(), clock:GetRight()
    local gap = (type(l) == "number" and type(r) == "number") and (l - r) or 0
    if d.state ~= state or d.h ~= h or d.gap ~= gap then
      d.state, d.h, d.gap = state, h, gap
      Parts.LaySmall(d, clock, state, "first", gap, h)
    end
    d[1]:Show()
    d[2]:Show()
    return true
  end

  -- The clock on the middle of the cell's face as it shows: from the inner
  -- edge of the art's rim to the dark line at the clock's right, between
  -- the rim's inner edges at the top and the foot (the red art's darker
  -- bottom band is its bevel, not its face). Measured from both clients'
  -- art, the same on each, in units of the art's height: the red face 10
  -- of 108 in from the box at the left and the top and 18 at the foot; the
  -- dark face 2 of 28 in on each side. The clock's glyph is re-anchored
  -- only when its offset moves.
  local FACE = { red = { 10 / 108, 10 / 108, 18 / 108 }, dark = { 2 / 28, 2 / 28, 2 / 28 } }
  local function CentreGlyph(clock, cell, kind)
    local glyph = clock.__pbGlyph
    local h = clock:GetHeight()
    if not glyph or type(h) ~= "number" or h <= 0 then return end
    local f = FACE[kind]
    local dx = f[1] * h / 2
    local dy = (f[3] - f[2]) * h / 2
    if cell.gx == dx and cell.gy == dy then return end
    cell.gx, cell.gy = dx, dy
    glyph:ClearAllPoints()
    glyph:SetPoint("CENTER", clock, "CENTER", dx, dy)
  end

  local function PaintCell(clock)
    local cell = clock.__pbBlizzCell
    if not cell then return end
    local owner = cell.button.__pbBlizzButton
    local dark = DarkCell(clock, cell, owner and owner.kind == "dark")
    CentreGlyph(clock, cell, dark and "dark" or "red")
    if dark then
      cell.state = nil
    else
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
    cells[clock] = true
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

  -- Options > Window > Buttons changed: every button and cell dressed so
  -- far wears the choice now.
  function Skin.ButtonLookChanged()
    Parts.ButtonLook = false
    LookNow()
    for button in pairs(dressed) do Paint(button) end
    for clock in pairs(cells) do PaintCell(clock) end
  end
end

-------------------------------------------------------------
-- The options' tiles
-------------------------------------------------------------

-- Options > General's three ways in (Mail Memory, Character Groups, Manage
-- Recipients: Core/OptionsPanel.lua, Ctx.Tile) are the game's buttons and
-- follow Options > Window > Buttons as every push button does (Parts.Button:
-- the small dark button under Mail red, rest dark and All dark, the newer
-- red button under All red, with their pointer and press). Postbox's own
-- plate, ring, left edge and chevron are not drawn; the game's small forward
-- arrow stands where the chevron stood (its middle 14.5 in from the right,
-- as the chevron's was 15). The name and the mark in the game's gold (the
-- disabled gray on a tile whose list is off), the second line in its quiet
-- gray, white on the red button.
--
-- Room for the second line in this style: the words start 2 units nearer
-- the mark (46 in, 7 clear of the mark's 30) and run to 4 units short of
-- the arrow, 150 units on the 218-unit tile where the chevron left 142
-- (`tile.__pbTextRoom`, which Ctx.PaintTile reads). The tile keeps its
-- size, place and clicks.
do
  local ARROW = "common-icon-forwardarrow"
  -- The arrow's art is a square with the arrow 6 wide and 10 tall in its
  -- middle (measured, both clients): drawn 12 square, its middle ARROW_X in
  -- from the tile's right, so the arrow stands from 17.5 to 11.5 in.
  local ARROW_SIZE, ARROW_X, ARROW_INK, ARROW_GAP, TEXT_X = 12, 14.5, 3, 4, 46
  local busy = false

  local function Ink(tile)
    if busy or not tile.__pbBlizzTile then return end
    busy = true
    local art = tile.__pbBlizzButton
    local red = art and art.kind == "red"
    local r, g, b
    if tile.off then
      r, g, b = Parts.FontRGB("GameFontDisable", 0.5, 0.5, 0.5)
    else
      r, g, b = Parts.FontRGB("GameFontNormal", 1, 0.82, 0)
    end
    tile.Title:SetTextColor(r, g, b)
    if tile.glyph then tile.Mark:SetVertexColor(r, g, b, 1) end
    if red then
      tile.Sub:SetTextColor(Parts.FontRGB("GameFontHighlight", 1, 1, 1))
    elseif tile.__pbBlizzTile.white then
      local T = ns.Theme
      if T and T.SetColor then T.SetColor(tile.Sub, "textSecondary") end
    end
    tile.__pbBlizzTile.white = red
    busy = false
  end

  function Parts.IsTile(c)
    return c.Chevron ~= nil and c.Holder ~= nil and c.Sub ~= nil and c.Title ~= nil and c.Edge ~= nil
      and c:IsObjectType("Button")
  end

  function Parts.Tile(tile)
    if tile.__pbBlizzTile ~= nil then return end
    tile.__pbBlizzTile = false
    if not HasAtlas(ARROW) then return end
    Parts.Button(tile)
    local art = tile.__pbBlizzButton
    if not art then return end
    tile.__pbBlizzTile = { white = false }
    -- Postbox's plate: the card's own fill and line, and the holder's rest,
    -- hover, ring and edge; the mark (and an art tile's glow) stay.
    Fade(tile.Center)
    for i = 1, #BACKDROP_EDGES do Fade(tile[BACKDROP_EDGES[i]]) end
    Fade(tile.pbSurfaceTexture)
    for i = 1, select("#", tile.Holder:GetRegions()) do
      local region = select(i, tile.Holder:GetRegions())
      if region and region ~= tile.Mark and region ~= tile.Glow and region:IsObjectType("Texture") then Fade(region) end
    end
    local parts = tile.Chevron
    for i = 1, #parts do Fade(parts[i]) end
    local arrow = tile.Holder:CreateTexture(nil, "OVERLAY")
    Atlas(arrow, ARROW, false)
    arrow:SetSize(ARROW_SIZE, ARROW_SIZE)
    arrow:SetPoint("CENTER", tile, "RIGHT", -ARROW_X, 0)
    tile.__pbBlizzTile.arrow = arrow
    -- The words' room and lead.
    local w = tile:GetWidth()
    if type(w) == "number" and w > 0 then
      local room = math.floor(w - ARROW_X - ARROW_INK - ARROW_GAP - TEXT_X)
      tile.__pbTextRoom = room
      tile.Title:SetPoint("BOTTOMLEFT", tile, "LEFT", TEXT_X, 1)
      tile.Sub:SetPoint("TOPLEFT", tile, "LEFT", TEXT_X, -1)
      tile.Title:SetWidth(room)
      tile.Sub:SetWidth(room)
    end
    -- The inks, again whenever the options paint them their own way.
    art.onKind = Ink
    local function Again() Ink(tile) end
    hooksecurefunc(tile.Title, "SetTextColor", Again)
    hooksecurefunc(tile.Sub, "SetTextColor", Again)
    if tile.glyph then hooksecurefunc(tile.Mark, "SetVertexColor", Again) end
    Ink(tile)
  end
end

-------------------------------------------------------------
-- The options' summary table
-------------------------------------------------------------

-- Options > General's "Mail waiting in your mailboxes" (OptionsPanel's Dash:
-- the card's parts in `card.__pbDash`) as the game's own lists are drawn:
-- the Auction House list's stripes under the lines (auctionhouse-rowstripe-1
-- and -2, 16 x 18 on both clients, one line each, tiled across) in place of
-- the plain alternating shade, the column names in the game's gold over the
-- game's divider (Options_HorizontalDivider, as the headings' rule), and a
-- divider over the totals line where its hairline and shade were. The
-- title's strip stays as it is, without its hairline. Rows, heights and
-- columns do not move. A line's hover is the house's wash as before, shown
-- only while the pointer is on it. A line made later (the list grows) is
-- dressed as it is made (`card.__pbDashLine`).
do
  local STRIPES = { "auctionhouse-rowstripe-1", "auctionhouse-rowstripe-2" }
  local DIVIDER = "Options_HorizontalDivider"
  -- The dividers' ends: this far in from the list side's edges.
  local RULE_IN = 5
  local busy = false

  local function Gold(fs)
    if busy or not fs then return end
    busy = true
    fs:SetTextColor(Parts.FontRGB("GameFontNormal", 1, 0.82, 0))
    busy = false
  end

  -- A divider across `frame`, on its top (or its foot), `RULE_IN` in.
  local function Rule(frame, foot)
    local t = frame:CreateTexture(nil, "BORDER", nil, 1)
    if not Atlas(t, DIVIDER, false) then
      t:Hide()
      return nil
    end
    local _, h = Parts.Size(DIVIDER)
    h = h or 1
    local T = ns.Theme
    local px = T and type(T.OnePixel) == "function" and T.OnePixel(frame) or 1
    if px > h then h = px end
    t:SetHeight(h)
    local edge = foot and "BOTTOM" or "TOP"
    t:SetPoint(edge .. "LEFT", frame, edge .. "LEFT", RULE_IN, 0)
    t:SetPoint(edge .. "RIGHT", frame, edge .. "RIGHT", -RULE_IN, 0)
    return t
  end

  local function WashShow(wash)
    local line = wash.line
    wash.house.Show(wash.house)
    line.Stripe:SetAlpha(1)
  end

  local function WashHide(wash)
    local line = wash.line
    wash.house.Hide(wash.house)
    line.Stripe:SetAlpha(0)
  end

  -- A line of the list (NewLine): its stripe of the Auction House list's,
  -- under the house's own, which shows only as the hover's wash.
  local function Line(f, i)
    if f.__pbBlizzStripe ~= nil then return end
    f.__pbBlizzStripe = false
    local name = STRIPES[(i % 2 == 1) and 1 or 2]
    if not HasAtlas(name) then return end
    local t = f:CreateTexture(nil, "BACKGROUND", nil, -1)
    if not Atlas(t, name, false) then
      t:Hide()
      return
    end
    t:SetHorizTile(true)
    t:SetAllPoints(f)
    f.__pbBlizzStripe = t
    if f.Stripe and type(f.Wash) == "table" and type(f.Wash.Show) == "function" then
      f.Stripe:SetAlpha(0)
      f.Wash = { line = f, house = f.Wash, Show = WashShow, Hide = WashHide }
    end
  end

  function Parts.Dash(card)
    if card.__pbBlizzDash ~= nil then return end
    card.__pbBlizzDash = false
    local d = card.__pbDash
    if type(d) ~= "table" or not (d.cols and d.total and d.child) then return end
    if not (HasAtlas(DIVIDER) and HasAtlas(STRIPES[1]) and HasAtlas(STRIPES[2])) then return end
    card.__pbBlizzDash = true
    -- The column names in the gold, kept there whatever repaints them.
    local cols = d.cols
    local names = { cols.Name, cols.Seen, cols.Soon, cols.Gold, cols.Mail }
    for i = 1, #names do
      local fs = names[i]
      if fs then
        Gold(fs)
        hooksecurefunc(fs, "SetTextColor", Gold)
      end
    end
    Rule(cols, true)
    -- The title's strip without its hairline; the totals under a divider.
    Fade(d.rule)
    Fade(d.footRule)
    Fade(d.foot)
    Rule(d.total, false)
    -- The lines made so far, and each one made from here on.
    for i = 1, select("#", d.child:GetChildren()) do
      local f = select(i, d.child:GetChildren())
      if f and f.Stripe then
        local _, _, _, _, y = f:GetPoint(1)
        local row = f:GetHeight()
        local n = (type(y) == "number" and type(row) == "number" and row > 0) and (math.floor(-y / row + 0.5) + 1) or i
        Line(f, n)
      end
    end
    card.__pbDashLine = Line
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

  -- The three pieces laid on `box` by the rim, for a box `h` units tall:
  -- the art's height that puts its line on the box's top and foot. Again
  -- where the height moves (the same points set anew).
  function Parts.EdgeOn(pieces, box, h)
    local out = h * RIM_Y / (ART_H - 2 * RIM_Y)
    local L, M, R = pieces[1], pieces[2], pieces[3]
    L:SetWidth(CAP)
    L:SetPoint("TOPLEFT", box, "TOPLEFT", -RIM_X, out)
    L:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", -RIM_X, -out)
    R:SetWidth(CAP)
    R:SetPoint("TOPRIGHT", box, "TOPRIGHT", RIM_X, out)
    R:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", RIM_X, -out)
    M:SetPoint("TOPLEFT", L, "TOPRIGHT", 0, 0)
    M:SetPoint("BOTTOMRIGHT", R, "BOTTOMLEFT", 0, 0)
  end

  -- The same pieces laid so that the art's whole picture stops at the box's
  -- foot: the art's 19 rows (a row of shadow and the line at the foot, two
  -- rows of shadow and the line at the top, measured from the file) each
  -- 1/18 of the box's height, the art's foot on the box's foot and its top
  -- a row over the box's top, so the two lines stand evenly about the
  -- box's middle (the words') and nothing is drawn below the box. The
  -- marble between the lines' inner edges, two rows in. For the island,
  -- whose box stands a unit over the list's foot (DividerNotch's stand):
  -- laid by its line, the art ran under the list's foot and was cut there.
  function Parts.EdgeLift(pieces, marble, box, h)
    local row = h / 18
    local L, R = pieces[1], pieces[3]
    L:SetPoint("TOPLEFT", box, "TOPLEFT", -RIM_X, row)
    L:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", -RIM_X, 0)
    R:SetPoint("TOPRIGHT", box, "TOPRIGHT", RIM_X, row)
    R:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", RIM_X, 0)
    if marble then
      marble:ClearAllPoints()
      marble:SetPoint("TOPLEFT", box, "TOPLEFT", MARBLE_IN, -2 * row)
      marble:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -MARBLE_IN, 2 * row)
    end
  end

  -- The gold edge with the marble inside it, as textures of `owner` (the
  -- pieces on `layer` / `sub`, the marble on `mLayer` / `mSub`, over the
  -- pieces' black middle), laid on `box`, `h` units tall: the strip's own
  -- box, or a frame that moves (the bar over finished mail's island shape),
  -- which the art then follows by its anchors alone. Answers the pieces and
  -- the marble.
  function Parts.GoldEdge(owner, box, h, layer, sub, mLayer, mSub)
    local pieces = {}
    for i = 1, 3 do
      local t = owner:CreateTexture(nil, layer, nil, sub)
      t:SetTexture(EDGE)
      local c = PIECES[i]
      t:SetTexCoord(c[1], c[2], c[3], c[4])
      pieces[i] = t
    end
    Parts.EdgeOn(pieces, box, h)
    local marble = owner:CreateTexture(nil, mLayer, nil, mSub)
    marble:SetTexture(MARBLE, "REPEAT", "REPEAT")
    marble:SetHorizTile(true)
    marble:SetVertTile(true)
    marble:SetPoint("TOPLEFT", box, "TOPLEFT", MARBLE_IN, -MARBLE_IN)
    marble:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -MARBLE_IN, MARBLE_IN)
    return pieces, marble
  end

  function Parts.Totals(band)
    if band.__pbBlizzBand ~= nil then return end
    band.__pbBlizzBand = false
    local h = band:GetHeight()
    if type(h) ~= "number" or h <= 0 then h = 24 end
    local pieces, marble = Parts.GoldEdge(band, band, h, "BACKGROUND", 2, "BORDER", -1)
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
-- The bar over finished mail
-------------------------------------------------------------

-- The bar over the finished mail (CollectTab's RV.BuildBar; its looks in
-- the comments above RV.BAR) wears the totals strip's art and the game's
-- gold, in all three Bar looks; its sizes, places, clicks and moves are the
-- window's own and do not change:
--   Island  the island at the list's foot is a small plaque, the gold edge
--           with the marble inside it, exactly where and as large as the
--           capsule it replaces (whose fill and ring are faded, never
--           drawn); opened, the same edge runs across the list. The art is
--           anchored to the island's shape (Core/DividerNotch.lua, f.Shape),
--           which the move already sets each frame, so the plaque follows
--           its edges with no work of its own. Its shadow over the rows
--           stays. The words, the number and Bar icon's mark in the game's
--           gold, white under the pointer (the game's own pair, as the
--           options' tabs have it), where the capsule lit up.
--   Hairline and Full row  the words in the gold, and the rule from them to
--           Delete all the game's Settings rule (Options_HorizontalDivider,
--           as the headings wear it) over the rule's own faded line, on
--           their own ground as before.
-- In each the number's brackets are the gold a step dimmer, Delete all
-- keeps its quiet words and its red, and the fold sign is the game's own
-- "+" / "-" (the Professions recipe list's, professions-recipe-header-
-- expand / -collapse, 22 x 16 on both clients): "-" while the finished mail
-- shows, "+" folded and on the copy at the list's foot. It stands at once,
-- never turned (it is no arrow), 10 units tall on one-line rows (11 on
-- Larger mail rows; the art at five eighths, 13.75 across), between the
-- chevron's room and the art's own size. In the island it is the fold sign
-- itself, moved in from the rows' read-dot column so that its line starts
-- as far from the gold edge's left end as Delete all's words end from its
-- right (the row's inset; `f.__pbSignX`, which RV.PaintBar reads); on
-- Hairline and Full row the same mark on the "+" strokes' middle, 8 units
-- tall (9 on Full row with Larger mail rows), its line about the read
-- dot's width as the strokes were, the strokes faded.
-- Bar color is mixed into the island's marble by the share the bar's fill
-- mixes in everywhere (CT.BarParts.mix, 15%): the colour laid over the
-- marble at that strength, none under Neutral; the rest of the bar as
-- before. Under the pointer the marble lights a little and a press
-- darkens it (a wash over it, white or black), on the pointer's own ease
-- as the capsule lit: `f.__pbColour`, called where the capsule's pieces
-- are coloured (DividerNotch's Colour), only when that ease or the opening
-- moves.
--
-- How it reaches the bar: the walk meets the window's three copies (the
-- panel's Notch, Divider and DividerPin; never the options' drawing, whose
-- copies stand for a panel of their own) and dresses each once. The window
-- then calls back at the moments its own look sets these parts, through
-- fields on the copy that are nil in every other look: f.__pbDress after a
-- copy is typed (RV.BarType, RV.LineType) and when the island's inks move
-- (DN.Ink); f.__pbWords where the island puts its words' ink at rest or
-- pointed at; f.__pbSign where a fold sign is drawn (DN.SignDraw, RV.
-- SignPlace); f.__pbDimHex for the brackets (RV.BarText). Each runs only
-- when that part changes: a pass at rest, and every frame of a move, sets
-- nothing more. Where the client lacks the marks or the rule, those parts
-- stay as they were.
do
  local MARK_OPEN, MARK_SHUT = "professions-recipe-header-collapse", "professions-recipe-header-expand"
  local DIVIDER = "Options_HorizontalDivider"
  -- The fold sign's canvas (RV.BAR.sign / signL), and the brackets' share
  -- of the gold.
  local SIGN, SIGN_L, DIM = 12, 13, 0.7
  -- The mark's height, of its canvas: in the island 10 of the 12 units; on
  -- Hairline and Full row 8, which makes its line as long as the rows' read
  -- dot is wide, whose column it stands on. And its line, of the art's
  -- width (both clients: 18 of 22).
  local MARK_H, MARK_LINE_H, MARK_CROSS = 10 / 12, 8 / 12, 18 / 22
  -- The wash over the marble: under the pointer on the island and on the
  -- open bar (white), and pressed (black).
  local LIT_ISLE, LIT_BAR, LIT_DOWN = 0.12, 0.05, 0.35
  local floor = math.floor

  local function Gold() return Parts.FontRGB("GameFontNormal", 1, 0.82, 0) end
  local function White() return Parts.FontRGB("GameFontHighlight", 1, 1, 1) end

  -- The words, the number and the mark: the gold, or white pointed at.
  local function Words(f, hot)
    local r, g, b
    if hot then r, g, b = White() else r, g, b = Gold() end
    f.Label:SetTextColor(r, g, b, 1)
    f.Count:SetTextColor(r, g, b, 1)
    f.Mark:SetVertexColor(r, g, b, 1)
  end

  -- A mark's size for a fold sign's canvas `c` units square, `k` of it
  -- tall, at its art's own proportion: whole units tall (in the island 10
  -- for the 12-unit canvas, 11 for the 13), so its line stands on the bar's
  -- middle. -> width, height
  local function MarkSize(c, k)
    local w0, h0 = Parts.Size(MARK_OPEN)
    w0, h0 = w0 or 22, h0 or 16
    local h = floor(c * k + 0.5)
    return h * w0 / h0, h
  end

  -- The mark, "-" (`open`) or "+", for the canvas `c`, `k` of it tall.
  local function LayMark(t, open, c, k)
    Atlas(t, open and MARK_OPEN or MARK_SHUT, false)
    t:SetSize(MarkSize(c, k))
  end

  -- The island's fold sign (DN.SignDraw, as the fold moves).
  local function IsleSign(f, open)
    LayMark(f.Sign, open, f.__canvas or SIGN, MARK_H)
  end

  -- Hairline's and Full row's (RV.SignPlace, as the sign moves), on the
  -- island's canvas: Full row's for the row size, Hairline's the one-line
  -- rows' in both (Hairline is the same in either size).
  local function LineSign(f, open)
    local a = f.__pbBlizzBar
    if not (a and a.mark) then return end
    LayMark(a.mark, open, (f.__look == "full" and not f.__compact) and SIGN_L or SIGN, MARK_LINE_H)
  end

  -- The island's height as its move lays it (DN.Size); a copy not laid out
  -- yet, the one-line rows' bar.
  local function Band(f)
    local h = f.__isleBand
    if type(h) ~= "number" or h <= 0 then h = 22 end
    return h
  end

  -- Bar color on the island's marble: the colour laid over it at the share
  -- the bar's fill mixes in (RV.BarRGB); nothing under Neutral.
  local function Tint(wash)
    local UI = ns.MailboxUI
    local cr, cg, cb
    if UI and type(UI.DividerColorRGB) == "function" then cr, cg, cb = UI.DividerColorRGB() end
    if type(cr) ~= "number" then
      wash:Hide()
      return
    end
    local B = ns.CollectTab and ns.CollectTab.BarParts
    wash:SetColorTexture(cr, cg, cb, B and B.mix or 0.15)
    wash:Show()
  end

  -- f.__pbColour (DividerNotch's Colour: `kf` 0 the island, 1 the bar; the
  -- pointer's ease `hv`, the press's `pv`): the marble lit under the
  -- pointer, darkened by a press. Only where it moved.
  local function Light(f, kf, hv, pv)
    local a = f.__pbBlizzBar
    local glow = a and a.glow
    if not glow then return end
    local s = (LIT_ISLE + (LIT_BAR - LIT_ISLE) * kf) * hv
    s = s + (-LIT_DOWN - s) * pv
    if a.lit == s then return end
    a.lit = s
    if s > 0 then
      glow:SetColorTexture(1, 1, 1, s)
      glow:Show()
    elseif s < 0 then
      glow:SetColorTexture(0, 0, 0, -s)
      glow:Show()
    else
      glow:Hide()
    end
  end

  -- f.__pbDress: after a copy is typed, and as the island's inks move.
  local function Dress(f)
    local a = f.__pbBlizzBar
    if not a then return end
    local look = f.__look
    local line = look == "hairline" or look == "full"
    local P = f.Isle
    Words(f, P and not line and (f.__hv or 0) >= 1)
    if P then
      -- The tones the pointer's ease mixes (DN.Tones): the gold at rest,
      -- white pointed at, for the words and for the mark.
      local t = P.tone
      local r, g, b = Gold()
      t[1], t[2], t[3], t[4], t[9], t[10], t[11], t[12] = r, g, b, 1, r, g, b, 1
      r, g, b = White()
      t[5], t[6], t[7], t[8], t[13], t[14], t[15], t[16] = r, g, b, 1, r, g, b, 1
      -- The mark in its own colours, its line the row's inset in from the
      -- bar's left end (RV.PaintBar places the fold sign's middle there).
      if f.__pbSign then
        f.Sign:SetVertexColor(1, 1, 1, 1)
        local T = ns.Theme
        local inset = T and T.Metrics and T.Metrics.inset or 10
        f.__pbSignX = inset + MarkSize(f.__canvas or SIGN, MARK_H) * MARK_CROSS / 2
      end
      local h = Band(f)
      if a.band ~= h then
        a.band = h
        Parts.EdgeLift(a.edge, a.marble, f.Shape, h)
      end
      if a.wash then Tint(a.wash) end
    end
    if a.mark then a.mark:SetShown(line) end
    if a.rule then
      a.rule:SetShown(line)
      -- RV.LineType gives the rule its strength each time.
      if line then f.Rule:SetAlpha(0) end
    end
  end

  -- The brackets' ink: the gold a step dimmer, "rrggbb".
  local function DimHex()
    local r, g, b = Gold()
    return ("%02x%02x%02x"):format(floor(r * DIM * 255 + 0.5), floor(g * DIM * 255 + 0.5), floor(b * DIM * 255 + 0.5))
  end

  -- A copy of the bar (it has Hairline's strokes, `SignH`), met by the walk.
  function Parts.Bar(f)
    f.__pbBlizzBar = false
    local panel = f.__panel
    if not (panel and (panel.Notch == f or panel.Divider == f or panel.DividerPin == f)) then return end
    local a = {}
    local marks = HasAtlas(MARK_OPEN) and HasAtlas(MARK_SHUT)
    local P = f.Isle
    if P and f.Shape then
      local h = Band(f)
      a.band = h
      -- Over the shadow (BACKGROUND -8), above the capsule's pieces.
      a.edge, a.marble = Parts.GoldEdge(f, f.Shape, h, "BACKGROUND", -5, "BACKGROUND", -4)
      Parts.EdgeLift(a.edge, a.marble, f.Shape, h)
      -- Over the marble, inside the gold line: Bar color's wash, then the
      -- pointer's.
      a.wash = f:CreateTexture(nil, "BACKGROUND", nil, -3)
      a.wash:SetAllPoints(a.marble)
      a.wash:Hide()
      a.glow = f:CreateTexture(nil, "BACKGROUND", nil, -2)
      a.glow:SetAllPoints(a.marble)
      a.glow:Hide()
      a.lit = 0
      f.__pbColour = Light
      Fade(P.mid)
      Fade(P.side[1])
      Fade(P.side[2])
      for i = 1, 4 do
        Fade(P.ring[i])
        Fade(P.fill[i])
      end
      Fade(P.top)
      Fade(P.bot)
      Fade(P.edgeL)
      Fade(P.edgeR)
      f.__pbWords = Words
      if marks then f.__pbSign = IsleSign end
    else
      if marks then
        local mark = f:CreateTexture(nil, "ARTWORK")
        mark:SetPoint("CENTER", f.SignH, "CENTER", 0, 0)
        mark:Hide()
        a.mark = mark
        Fade(f.SignH)
        Fade(f.SignV)
        f.__pbSign = LineSign
      end
      if HasAtlas(DIVIDER) then
        local rule = f:CreateTexture(nil, "ARTWORK")
        if Atlas(rule, DIVIDER, false) then
          local _, h = Parts.Size(DIVIDER)
          h = h or 1
          local T = ns.Theme
          local px = T and type(T.OnePixel) == "function" and T.OnePixel(f) or 1
          if px > h then h = px end
          rule:SetHeight(h)
          rule:SetPoint("TOPLEFT", f.Rule, "TOPLEFT", 0, 0)
          rule:SetPoint("TOPRIGHT", f.Rule, "TOPRIGHT", 0, 0)
          rule:Hide()
          a.rule = rule
        else
          rule:Hide()
        end
      end
    end
    f.__pbDimHex = DimHex()
    f.__pbBlizzBar = a
    f.__pbDress = Dress
    -- Whatever the copy has drawn already is typed, written and signed
    -- again on its next pass, and dressed now.
    f.__gen, f.__words, f.__folded, f.__sign = nil, nil, nil, nil
    Dress(f)
  end
end

-------------------------------------------------------------
-- Fields
-------------------------------------------------------------

-- Every one-line field (an input wrap: Recipient, Subject, the gold boxes,
-- Character Groups' name, the bug report's address, the options' words
-- boxes) wears the game's newer box border, the one its search boxes wear
-- (common-search-border-*: bronze on WoW Forever, grey on retail), without
-- the magnifier, its words where they stood; every search box
-- (Theme.CreateSearchBox) the same border with its magnifier at the left,
-- and its words moved right by what the magnifier takes. Art only, on
-- Postbox's own frames: the game's InputBoxTemplate and SearchBoxTemplate
-- are never made (their scripts would take the box's focus, hint and clear
-- button over). The field's own fill, line and grain are faded under the
-- art. The older Common-Input-Border is not drawn anywhere.
--
-- The border is art for one line (its ends 16 x 40, its middle 224 x 40,
-- measured: the rim stands on the art's own edges), laid on the field's box,
-- its ends scaled with its height. A field many lines tall (the Send tab's
-- Message box) is not stretched into it: it is sunk into the window as the
-- lists are, the game's inset bevel round it, and its ground inside is the
-- rows' (Row texture: the paper, the shaded paper, or the dark ground the
-- lists keep; Parts.MessageGround).
--
-- A cell joined to a field (the Manage Recipients key, the sort) is the
-- field's last cell (Parts.FieldEnd).
do
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

  -- The search border and its magnifier on `wrap` (h units tall), as the
  -- template lays them, grown with the box: the three pieces, and the
  -- magnifier as the fourth where the client has it (none where `bare`: a
  -- field). Art only.
  function Parts.SearchArt(wrap, h, bare)
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
    if not bare then pieces[4] = Parts.Glass(wrap, h) end
    return pieces
  end

  -- The magnifier, as the template places it, grown with the box, or nil.
  function Parts.Glass(wrap, h)
    if not HasAtlas(GLASS) then return nil end
    local k = h / BOX_H
    local glass = wrap:CreateTexture(nil, "ARTWORK")
    if not Atlas(glass, GLASS, false) then return nil end
    glass:SetSize(GLASS_SIZE * k, GLASS_SIZE * k)
    glass:SetPoint("LEFT", wrap, "LEFT", GLASS_X * k, GLASS_Y * k)
    return glass
  end

  -- A field with a key joined to it (Theme.JoinCell: the Mail tab's and
  -- Mail Memory's search with their sort, Manage Recipients' search and the
  -- Send tab's Recipient box with their keys) wears the key's own rim: the
  -- small dark button's art (Parts.LaySmall), the strip's first cell, its
  -- middle running on to the key's left edge, where the key's art (the
  -- strip's last cell, its one-unit line at its left) takes it on, as
  -- Received and Sent are joined. Its key hidden (a search with its sort
  -- taken out), the field is a whole button of that art. At rest always: a
  -- field is not pressed. `strip` the three pieces; the magnifier as the
  -- fourth on a search.
  local function LayStrip(wrap, strip, cell)
    local h = wrap:GetHeight()
    if type(h) ~= "number" or h <= 0 then h = 24 end
    local joined = (cell and cell.__pbBlizzSeg and cell:IsShown()) and true or false
    if strip.joined == joined and strip.h == h then return end
    strip.joined, strip.h = joined, h
    Parts.LaySmall(strip, wrap, "up", joined and "first" or "alone", 0, h)
    if joined then
      strip[2]:SetPoint("BOTTOMRIGHT", cell, "BOTTOMLEFT", 0, -Parts.SmallGeo("up", h).outB)
    end
  end

  local function Strip(wrap, search)
    local strip = Parts.SmallArt(wrap)
    if not strip then return nil end
    strip.strip = true
    local h = wrap:GetHeight()
    if type(h) ~= "number" or h <= 0 then h = 24 end
    if search then strip[4] = Parts.Glass(wrap, h) end
    return strip
  end

  -- A search box: the art, and its words after the magnifier as the
  -- template places them, grown with the box.
  local function LaySearch(wrap, search, strip)
    local h = wrap:GetHeight()
    if type(h) ~= "number" or h <= 0 then h = 24 end
    local pieces = strip and Strip(wrap, true) or Parts.SearchArt(wrap, h)
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
  -- magnifier; its words stay where they stand, already clear of the
  -- magnifier. One magnifier, the game's: Postbox's own is hidden as well as
  -- faded (faded alone, it was still drawn beside the game's in the game),
  -- and nothing of the options shows it again.
  function Parts.Find(wrap)
    if wrap.__pbBlizzFind ~= nil then return end
    wrap.__pbBlizzFind = false
    local h = wrap:GetHeight()
    if type(h) ~= "number" or h <= 0 then return end
    local pieces = Parts.SearchArt(wrap, h)
    if not pieces then return end
    wrap.__pbBlizzFind = pieces
    Fade(wrap.Line)
    local glyph = wrap.Glyph
    if pieces[4] and glyph then
      Fade(glyph)
      glyph:Hide()
    end
  end

  -- The plate joined to the wrap as its last cell (Theme.JoinCell: the
  -- search's sort, the Manage Recipients key), or nil.
  function Parts.JoinedCell(wrap)
    local search = wrap.__pbSearch
    if type(search) == "table" and search.cell then return search.cell end
    for i = 1, select("#", wrap:GetChildren()) do
      local c = select(i, wrap:GetChildren())
      if c and c.__pbJoinWrap == wrap then return c end
    end
    return nil
  end

  -- The field's end at its joined cell, while the cell is shown and wears
  -- the small dark button (Parts.Seg): no end cap there, the border's top
  -- and foot running straight on to the cell's left edge, where the cell's
  -- own art takes them on. Hidden (a search with its sort taken out), the
  -- field is whole again. Anchors only; nothing is made.
  function Parts.FieldEnd(wrap, cell)
    local pieces = wrap.__pbBlizzField
    if not pieces or pieces.tall then return end
    if pieces.strip then return LayStrip(wrap, pieces, cell) end
    local joined = (cell and cell.__pbBlizzSeg and cell:IsShown()) and true or false
    if pieces.joined == joined then return end
    pieces.joined = joined
    local M, R = pieces[2], pieces[3]
    if joined then
      M:SetPoint("BOTTOMRIGHT", cell, "BOTTOMLEFT", 0, 0)
    else
      M:SetPoint("BOTTOMRIGHT", R, "BOTTOMLEFT", 0, 0)
    end
    R:SetShown(not joined)
  end

  function Parts.Field(wrap)
    if wrap.__pbBlizzField ~= nil then return end
    wrap.__pbBlizzField = false
    local search = wrap.__pbSearch
    local pieces
    -- A field with a key joined to it wears the key's rim (LayStrip).
    local joins = not wrap._scroll and Parts.JoinedCell(wrap) ~= nil
    if type(search) == "table" then
      pieces = LaySearch(wrap, search, joins)
    elseif joins then
      pieces = Strip(wrap, false)
    elseif wrap._scroll then
      -- Many lines tall: sunk, with the rows' ground inside (above). The
      -- lists' own dark ground stays under it for the dark list.
      SinkPanel(wrap)
      wrap.__pbBlizzField = { tall = true }
      Fade(wrap.pbSurfaceTexture)
      if Parts.MessageGround then Parts.MessageGround(wrap) end
      return
    else
      local h = wrap:GetHeight()
      if type(h) ~= "number" or h <= 0 then h = 24 end
      pieces = Parts.SearchArt(wrap, h, true)
    end
    if not pieces then return end
    wrap.__pbBlizzField = pieces
    Quiet(wrap)
    -- A cell dressed before its field (a walk that met it first).
    local cell = Parts.JoinedCell(wrap)
    if cell then Parts.FieldEnd(wrap, cell) end
  end
end

-------------------------------------------------------------
-- The scroll bar
-------------------------------------------------------------

-- Every list's bar (Theme.SlimScrollBar: Postbox's own slider and step
-- buttons, in the gutter it has) wears the game's minimal scroll bar
-- (MinimalScrollBar, the bar every one of the game's own lists carries):
-- its track and its small thumb, with the game's hover and pressed art, and
-- no arrows: the step buttons at the bar's two ends are not drawn and take
-- no clicks, and the bar runs through their room, so the track is as long
-- as the bar and its two buttons were. The wheel, the thumb and a click on
-- the track move the list. The bar's own drawing is faded; the slider, its
-- range and its steps are untouched.
--
-- Laid by its rim (measured): the track's art is 8 wide with a clear unit
-- at each side, so on the 6-unit bar it is drawn a unit past each side and
-- its visible track is the bar; the thumb's art is 8 wide and solid, a unit
-- past the bar each side, as the game's thumb stands past its track; its
-- middle is cut to the thumb's length, never squashed.
do
  local TRACK = { "minimal-scrollbar-track-top", "!minimal-scrollbar-track-middle", "minimal-scrollbar-track-bottom" }
  local THUMB = {
    up = { "minimal-scrollbar-small-thumb-top", "minimal-scrollbar-small-thumb-middle", "minimal-scrollbar-small-thumb-bottom" },
    over = { "minimal-scrollbar-small-thumb-top-over", "minimal-scrollbar-small-thumb-middle-over", "minimal-scrollbar-small-thumb-bottom-over" },
    down = { "minimal-scrollbar-small-thumb-top-down", "minimal-scrollbar-small-thumb-middle-down", "minimal-scrollbar-small-thumb-bottom-down" },
  }

  local function HasAll(list)
    for i = 1, #list do
      if not HasAtlas(list[i]) then return false end
    end
    return true
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

  -- The thumb's middle cut to its length from the top of the art, as
  -- MinimalScrollBar's thumb cuts it (its art is 715 units long, and WoW
  -- Forever's carries a grain that stretching would squash): on each
  -- change of the thumb's length and after each change of its art.
  local function CropThumb(thumb)
    local bar = thumb.__pbBlizzBarOf
    local art = bar and bar.__pbBlizzBar
    if not art then return end
    local h = thumb:GetHeight()
    local _, th = Parts.Size(THUMB.up[1])
    local _, mh = Parts.Size(THUMB.up[2])
    local _, bh = Parts.Size(THUMB.up[3])
    if type(h) ~= "number" or not (th and mh and bh) then return end
    local v = (h - th - bh) / mh
    if v < 0 then v = 0 elseif v > 1 then v = 1 end
    art.thumb[2]:SetTexCoord(0, 1, 0, v)
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
    CropThumb(art.thumbTex)
  end

  local function BarEnter(bar) local a = bar.__pbBlizzBar if a then a.over = true PaintThumb(bar) end end
  local function BarLeave(bar) local a = bar.__pbBlizzBar if a then a.over = false PaintThumb(bar) end end
  local function BarDown(bar) local a = bar.__pbBlizzBar if a then a.down = true PaintThumb(bar) end end
  local function BarUp(bar) local a = bar.__pbBlizzBar if a then a.down = false PaintThumb(bar) end end

  -- A step button, unseen and out of the pointer's way (the bar shows and
  -- hides it with itself, so it is faded, not hidden). -> its height, the
  -- room it leaves the bar.
  local function NoStep(btn)
    if not btn then return 0 end
    btn:SetAlpha(0)
    btn:EnableMouse(false)
    local h = btn:GetHeight()
    return type(h) == "number" and h > 0 and h or 0
  end

  -- The bar through its two step buttons' room: its top and its foot each
  -- moved out by that button's height (Theme.SlimScrollBar hangs the bar by
  -- its top right and bottom right corners, a button's height in from the
  -- span it was given). Anything else, and the bar keeps its place.
  local function TakeStepRoom(bar)
    local up, down = NoStep(bar.Up), NoStep(bar.Down)
    if bar:GetNumPoints() ~= 2 then return end
    local p1, r1, rp1, x1, y1 = bar:GetPoint(1)
    local p2, r2, rp2, x2, y2 = bar:GetPoint(2)
    if p1 ~= "TOPRIGHT" or p2 ~= "BOTTOMRIGHT" or type(y1) ~= "number" or type(y2) ~= "number" then return end
    bar:ClearAllPoints()
    bar:SetPoint(p1, r1, rp1, x1, y1 + up)
    bar:SetPoint(p2, r2, rp2, x2, y2 - down)
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
    art.thumbTex = thumb
    bar.__pbBlizzBar = art
    thumb.__pbBlizzBarOf = bar
    -- The bar sets its thumb's length (Theme.SlimScrollBar's FitThumb): the
    -- middle is cut again each time, on Postbox's own texture.
    hooksecurefunc(thumb, "SetHeight", CropThumb)
    CropThumb(thumb)
    -- The bar's own track and thumb, faded (their paint, not their place:
    -- the slider still sizes and moves the thumb the art stands on).
    Fade(bar.Track)
    thumb:SetAlpha(0)
    bar:HookScript("OnEnter", BarEnter)
    bar:HookScript("OnLeave", BarLeave)
    bar:HookScript("OnMouseDown", BarDown)
    bar:HookScript("OnMouseUp", BarUp)
    -- No arrows: the bar takes its step buttons' room.
    TakeStepRoom(bar)
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
-- it, two units apart. A plate standing alone is a whole button. A cell
-- joined to a FIELD (Theme.JoinCell: the sort on a search, the Manage
-- Recipients key) is the field's last cell: the field's border has no end
-- cap there and runs on into the cell (Parts.FieldEnd), which wears the art
-- without its left end (its rim at its top, foot and right) and the rim's
-- one-unit column at its left, the line between field and key. The options
-- preview's plates keep their look.
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
  -- runs `gap` past the frame's right edge, to the next cell's left. An
  -- outer end stands on `leftTo` / `rightTo` where given (a bar's own edge,
  -- the field's above it), else on the frame.
  local function Lay(art, frame, state, role, gap, h, leftTo, rightTo)
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
      L:SetPoint("TOPLEFT", leftTo or frame, "TOPLEFT", -g.outX, g.outT)
      L:SetPoint("BOTTOMLEFT", leftTo or frame, "BOTTOMLEFT", -g.outX, -g.outB)
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
      R:SetPoint("TOPRIGHT", rightTo or frame, "TOPRIGHT", g.outX, g.outT)
      R:SetPoint("BOTTOMRIGHT", rightTo or frame, "BOTTOMRIGHT", g.outX, -g.outB)
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
  Parts.SmallGeo = Geo

  -- The rim's own column, one unit wide, at the right end of a cell with a
  -- cell after it: the metal at rest, the selected art's white beside a lit
  -- cell. Only on a change.
  -- A cell joined to a field has its line at its own left instead: the
  -- one-unit column its plate leaves for the divider (Theme.JoinCell).
  local function Line(plate, nxt)
    local art = plate.__pbBlizzSeg
    local D = art.line
    local field = plate.__pbBlizzJoin == "field"
    if not (nxt or field) then
      D:Hide()
      art.lineLit = nil
      return
    end
    local lit = (plate.isSelected or (nxt and nxt.isSelected)) and true or false
    if art.lineLit ~= lit or art.lineH ~= art.h or art.lineGap ~= art.gap then
      art.lineLit, art.lineH, art.lineGap = lit, art.h, art.gap
      local state = lit and "lit" or "up"
      local g = Geo(state, art.h)
      Atlas(D, NAMES[state], false)
      D:SetTexCoord(g.rx / g.w, (g.rx + 1 / g.s) / g.w, g.rt / g.hh, 1 - g.rb / g.hh)
      D:ClearAllPoints()
      if field then
        D:SetPoint("TOPLEFT", plate, "TOPLEFT", 0, 0)
        D:SetPoint("BOTTOMRIGHT", plate, "BOTTOMLEFT", 1, 0)
      else
        D:SetPoint("TOPLEFT", plate, "TOPRIGHT", art.gap - 1, 0)
        D:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", art.gap, 0)
      end
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
    elseif kind == "field" then
      return "last", 0, nil, nil
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
      -- A bar's outer ends stand on the bar's own edges, which are the
      -- field's above it: a strip is exactly as wide as that field, though
      -- a bar's last tile may stop short of its end (Manage Recipients').
      local bar = plate.__pbBlizzBar
      local owner = bar and bar.owner
      Lay(art, plate, state, role, gap, h, owner, owner)
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
  -- A field's cell shown or hidden: the field's end follows it.
  local function FieldMoved(plate)
    local wrap = plate.__pbJoinWrap
    if wrap then Parts.FieldEnd(wrap, plate) end
  end

  local function Join(plate)
    local wrap = plate.__pbJoinWrap
    if wrap then
      -- Its divider is the art's own line now.
      plate.__pbBlizzJoin = "field"
      Fade(plate.__pbDivider)
      plate:HookScript("OnShow", FieldMoved)
      plate:HookScript("OnHide", FieldMoved)
      Parts.FieldEnd(wrap, plate)
      return
    end
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
      bar = { gap = (T and T.Metrics and T.Metrics.space and T.Metrics.space.hair) or 2, owner = p }
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
    if not IsPlate(c) or c.__setSelectedOverride then return false end
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
  -- side. The value's room, in the art's units (scaled with the box): from
  -- a unit and a half inside the text holder's rim (which stands 4 in from
  -- the box's edge) to a unit short of the arrow's face, measured from both
  -- clients' art: 3.4 units more than it had (8 in, 2 from the art's left).
  local A_X, A_Y, A_FACE, LEAD, GAP = 1, -3, 4, 5.5, 1
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
    -- Only the evened copy (the normal font in the highlight's colour, at
    -- the normal font's size): a game font of its own could be larger.
    local lit = T and T.NamedFont and type(toggle.GetHighlightFontObject) == "function"
      and T.NamedFont(toggle:GetHighlightFontObject()) or nil
    local name = lit and type(lit.GetName) == "function" and lit:GetName() or nil
    if name and name:find("^PostboxEvenFont") and type(toggle.SetNormalFontObject) == "function" then
      -- The options' push buttons take their words' font from a select's
      -- (OptionsPanel's CAPTION.Font): at rest they keep the gold one.
      toggle.__pbCaptionFont = toggle:GetNormalFontObject()
      toggle:SetNormalFontObject(lit)
    end
    -- Its place: at the box's left (after a swatch where it has one),
    -- clear of the arrow; a select whose items carry art keeps it centred.
    local inset = tonumber(toggle.__pbInset) or 12
    local label = toggle.GetFontString and toggle:GetFontString()
    if label and inset <= SWATCH_LEAD then
      local lead = (inset >= SWATCH_LEAD) and SWATCH_LEAD or math.floor(LEAD * s + 0.5)
      toggle.__pbValueRoom = lead + (aw - A_FACE - A_X) * s + GAP
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

  -- A divider in a list (Lib/UI/Dropdown.lua: an item { divider = true },
  -- a frame of its own with a hairline `Rule`) wears the divider the game's
  -- own menus draw between their groups: the file Interface\Common\
  -- UI-TooltipDivider-Transparent across the rule's span, 13 units tall as
  -- the menus lay it, on the divider's middle, the hairline faded under it.
  -- The divider's own room in the list does not change. Where the client
  -- cannot load the file, the hairline stays.
  local MENU_DIVIDER, MENU_DIVIDER_H = "Interface\\Common\\UI-TooltipDivider-Transparent", 13
  function Parts.ListDivider(div)
    if div.__pbBlizzDivider ~= nil then return end
    div.__pbBlizzDivider = false
    local rule = div.Rule
    if not rule then return end
    local t = div:CreateTexture(nil, "ARTWORK")
    if t:SetTexture(MENU_DIVIDER) == false then
      t:Hide()
      return
    end
    t:SetHeight(MENU_DIVIDER_H)
    t:SetPoint("LEFT", rule, "LEFT", 0, 0)
    t:SetPoint("RIGHT", rule, "RIGHT", 0, 0)
    Fade(rule)
    div.__pbBlizzDivider = t
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
--   * every checkbox Postbox makes (__postboxCheck: the options', and C.O.D.
--     and Character Groups' members outside them) is the Settings
--     checkbox, its box and tick (checkbox-minimal, checkmark-minimal) on
--     the same button, at its size and place;
--   * the footer's Report a bug, What's new? and Reset to defaults are
--     three red buttons on the window's stone, the band behind them not
--     drawn (Parts.FooterButtons), their words the game's gold at rest;
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

  -- Every checkbox Postbox makes (UICheckButtonTemplate, tagged
  -- __postboxCheck: the options', C.O.D. on the Send tab, Character
  -- Groups' members), in a window this skin dressed: the Settings box and
  -- tick.
  local CHECK = { box = "checkbox-minimal", tick = "checkmark-minimal", off = "checkmark-minimal-disabled" }
  function Parts.Check(cb)
    if cb.__pbBlizzCheck ~= nil then return end
    cb.__pbBlizzCheck = false
    if not DressedWindowOf(cb) then return end
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

  -- The options' footer (Footer.Build: the band names its parts in
  -- `__pbFooter`): Report a bug, What's new? and Reset to defaults wear
  -- the game's gold at rest, words and marks, as the approved drawing has
  -- them; pointed at (and Reset while its menu is open) the house's own
  -- bright ink stands. Painted at rest after each leave and as Reset's menu
  -- closes; nothing else.
  local function Gold(...)
    local r, g, b = Parts.FontRGB("GameFontNormal", 1, 0.82, 0)
    for i = 1, select("#", ...) do
      local region = select(i, ...)
      if region then
        if region.SetTextColor then region:SetTextColor(r, g, b) else region:SetVertexColor(r, g, b, 1) end
      end
    end
  end

  local function BugRest(band)
    local f = band.__pbFooter
    if f then Gold(f.bugText, f.bugGlyph) end
  end

  local function NewsRest(news)
    local f = news.__pbFooterOf
    if f then Gold(f.newsText) end
  end

  function Parts.ResetRest(reset)
    local f = reset.__pbFooterOf
    if not f then return end
    local list = reset.__pbFooterMenu
    if reset:IsMouseOver() or (list and list:IsShown()) then return end
    Gold(f.resetText, f.resetArrow, f.resetCaret)
  end

  local function MenuClosed(list)
    if list._toggle then Parts.ResetRest(list._toggle) end
  end

  function Parts.Footer(band)
    if band.__pbBlizzFooter ~= nil then return end
    band.__pbBlizzFooter = false
    local f = band.__pbFooter
    if type(f) ~= "table" then return end
    band.__pbBlizzFooter = true
    -- The three as red buttons on the stone, the band not drawn.
    Parts.FooterButtons(band)
    band:HookScript("OnLeave", BugRest)
    BugRest(band)
    if f.news then
      f.news.__pbFooterOf = f
      f.news:HookScript("OnLeave", NewsRest)
      NewsRest(f.news)
    end
    if f.reset then
      f.reset.__pbFooterOf = f
      f.reset:HookScript("OnLeave", Parts.ResetRest)
      Parts.ResetRest(f.reset)
    end
  end

  -- Reset's menu, met by the walk when it is first built.
  function Parts.FooterMenu(list)
    local reset = list._toggle
    if not (reset and reset.__pbFooterOf) or reset.__pbFooterMenu then return end
    reset.__pbFooterMenu = list
    list:HookScript("OnHide", MenuClosed)
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
    head.__pbPaintRule = Parts.PaintRule
    Parts.PaintRule(head)
  end

  -- A grayed group (`head.off`, Rows.PaintGroup) grays its rule with its
  -- words: the divider without its colour, at the disabled words' strength.
  function Parts.PaintRule(head)
    local line = head.__pbBlizzHeading
    if not line then return end
    local off = head.off and true or false
    line:SetDesaturated(off)
    line:SetAlpha(off and 0.45 or 1)
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
    local lit = btn.Lit
    if lit then
      lit:Hide()
      if lit.Lift then lit.Lift:Hide() end
    end
    if on then
      White(label)
      White(mark, true)
    else
      -- At rest, the red button's own words: the game's gold, the eye with
      -- them (as the options' other push buttons' words).
      local r, g, b = Parts.FontRGB("GameFontNormal", 1, 0.82, 0)
      if label then label:SetTextColor(r, g, b) end
      if mark then mark:SetVertexColor(r, g, b, 1) end
    end
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

-------------------------------------------------------------
-- Text: Font, Text style and Text weight
-------------------------------------------------------------

-- Options > Window > Font, Text style and Text weight: the Postbox style's
-- three, the same fonts offered by the same rules (ns.SkinFonts: a font
-- without this client's letters is not offered, Bold only where the font
-- has a Bold that loads), saved for this style apart (profile blizzFont,
-- blizzOutline, blizzWeight; nil is the default), so each style keeps its
-- own. They reach every text through the copies Theme dresses
-- (Skin.GetFontFace, read by Theme.HostFont), as a host's face does:
--   Font         the game's (the default: each game font's own face) or one
--                of the others, at Text weight's Regular or Bold;
--   Text style   Shadow (the default): the game fonts' own soft shadow and
--                flags, in whichever font; Outline: the client's thin
--                outline, no shadow; None: neither.
-- With all three at their defaults the face is the game objects' own, as
-- when this skin published none: the look as it was, byte for byte. On the
-- letter paper (Row texture Light: the mail rows and the Message box) the
-- dark words stay clean whatever Text style says (Row texture, below).
-- A change dresses the copies again in place (Theme.RefreshHostFonts) and
-- measures the screens that fit text again: live, nothing per row.
do
  local function Saved(path)
    local Store = ns.Store
    return Store and type(Store.Get) == "function" and Store.Get(path) or nil
  end

  local function Save(key, value)
    local Store = ns.Store
    local profile = Store and type(Store.EnsurePath) == "function" and Store.EnsurePath("profile")
    if profile then profile[key] = value end
  end

  function Skin.GetFontChoices() return ns.SkinFonts.FontChoices() end

  -- The font drawn: the saved one where its file loads here, else the game's.
  function Skin.GetFont() return ns.SkinFonts.Resolve(Saved("profile.blizzFont")) end

  function Skin.SetFont(key)
    if not ns.SkinFonts.Valid(key) then return end
    Save("blizzFont", (key ~= "game") and key or nil)
    Skin.ApplyFonts()
  end

  function Skin.GetWeightChoices() return ns.SkinFonts.WeightChoices() end

  -- The saved choice, whatever the chosen font can draw (nil is Regular).
  function Skin.GetWeight()
    return (Saved("profile.blizzWeight") == "bold") and "bold" or "regular"
  end

  function Skin.SetWeight(key)
    if not ns.SkinFonts.IsWeight(key) then return end
    Save("blizzWeight", (key == "bold") and "bold" or nil)
    Skin.ApplyFonts()
  end

  -- nil where the chosen font can be drawn Bold here; else why not.
  function Skin.GetWeightWhy() return ns.SkinFonts.WeightWhy(Skin.GetFont()) end

  function Skin.GetOutlineChoices() return ns.SkinFonts.OutlineChoices() end

  function Skin.GetOutline()
    local saved = Saved("profile.blizzOutline")
    if ns.SkinFonts.IsOutline(saved) then return saved end
    return "shadow"
  end

  function Skin.SetOutline(key)
    if not ns.SkinFonts.IsOutline(key) then return end
    Save("blizzOutline", (key ~= "shadow") and key or nil)
    Skin.ApplyFonts()
  end

  -- The face the copies wear (Theme's HostFace): the file (false: each game
  -- font's own), the flags (false: its own) and the shadow (nil: its own).
  -- At the defaults false, false, nil: what no answer meant.
  function Skin.GetFontFace()
    local path = ns.SkinFonts.Path(Skin.GetFont(), Skin.GetWeight())
    local outline = Skin.GetOutline()
    if outline == "outline" then return path, "OUTLINE", false end
    if outline == "none" then return path, "", false end
    return path, false, nil
  end

  -- A change of font, weight, Text style or Text size (Theme.FontsMoved, a
  -- reset): the copies dressed again where the face moved, the paper's
  -- words given their clean face or their usual one, and the screens that
  -- fit text measured again (which binds the mail rows again).
  function Skin.ApplyFonts()
    local T = ns.Theme
    if not T then return end
    if type(T.RefreshHostFonts) == "function" then T.RefreshHostFonts() end
    local R = Parts.Rows
    local outline = Skin.GetOutline() == "outline"
    if R and R.outline ~= outline then
      R.outline = outline
      if R.mode and Parts.MessageGrounds then Parts.MessageGrounds() end
    end
    if type(T.RefitScreens) == "function" then T.RefitScreens() end
  end
end

-------------------------------------------------------------
-- Row texture: what the mail rows stand on
-------------------------------------------------------------

-- Options > Window > Row texture (MailboxUI.GetRowTexture), for the mail
-- rows of the main window (Inbox, Done, History's Received and Sent, the
-- search) in both row sizes, and Mail Memory's list (each binder calls
-- Theme.RowGround):
--   light  each row a strip of the game's letter paper (the file the game's
--          Send Mail page is written on, Interface\Stationery\StationeryTest1,
--          by path: a UI pack that replaces it restyles the rows), a
--          different band of the page per row so neighbours do not repeat;
--          the row's text in dark ink, drawn clean (no shadow), every
--          coloured word moved to a dark ink of its own hue;
--   dark   the same paper shaded in code (vertex 0.30), the light inks with
--          their shadows, a colour moved lighter where it reads under 4.5:1;
--   none   the dark list, the rows as they were.
-- The inks are worked out once per setting, by the rule the measured inks
-- were made with (.dev/design/native-skin/scripts/inks.py): a colour keeps
-- its hue and moves only as far as 4.6:1 needs (4.5 and a margin), toward
-- black on the paper against its darker grain, toward white on the shaded
-- paper against its brighter grain as the pointer lights it. They reach the
-- rows' texts through the "row" ground (Theme.SetRowInks); the window's
-- other texts keep the palette.
--
-- One paper texture per row, made once, under the row's own stripe; a bind
-- sets its band and the row's text colours from the inks resolved, and
-- makes nothing. The stripe is none on paper (each row is its own band of
-- it) and the pointer's wash is white, lighter on the shaded paper.
do
  local PAPER = "Interface\\Stationery\\StationeryTest1"
  -- The page's grain, clear of its left edge's red wash, in texels of its 256.
  local PX0, PY0, PX1, PY1, SIZE = 40, 6, 250, 250, 256
  -- A row's band: 1.15 texels a unit of its height, at least 10, and each
  -- row's 37 texels further down the page than the last.
  local BAND_K, BAND_MIN, STEP = 1.15, 10, 37
  local DARK_V = 0.30
  -- Luminance, measured from the rendered rows on both clients (the same):
  -- the paper's darker grain (its darkest tenth), and the shaded paper's
  -- brighter grain (its brightest tenth).
  local LIGHT_LO, DARK_HI = 0.299, 0.043
  -- The pointer's wash on each (white).
  local HOVER = { light = 0.16, dark = 0.08 }
  local TARGET = 4.6
  -- On the paper the game's own dark ink (QuestFont's, MailTextFontNormal's)
  -- stands for the white and the greys, and dark gold for the gold; 0-255.
  local LIGHT_BASE = {
    textPrimary = { 46, 31, 15 }, textSecondary = { 96, 72, 44 }, textPlaceholder = { 96, 72, 44 },
    accent = { 120, 82, 0 }, accentText = { 120, 82, 0 }, accentBright = { 120, 82, 0 },
  }

  local R = { mode = false, light = false, ground = 0 }
  Parts.Rows = R

  local function Lin(c)
    if c <= 0.04045 then return c / 12.92 end
    return ((c + 0.055) / 1.055) ^ 2.4
  end
  local function Lum(r, g, b) return 0.2126 * Lin(r / 255) + 0.7152 * Lin(g / 255) + 0.0722 * Lin(b / 255) end
  local function Ratio(a, b)
    if a < b then a, b = b, a end
    return (a + 0.05) / (b + 0.05)
  end

  -- The fitting ground of the shaded paper: its brighter grain under the
  -- pointer's wash.
  local function DarkGround()
    local s = 1.055 * DARK_HI ^ (1 / 2.4) - 0.055
    local w = HOVER.dark
    return Lin(s * (1 - w) + w)
  end

  -- r, g, b (0-255) on `bg` (a luminance): itself where it reads 4.6:1, else
  -- moved toward black (`down`) or white a hundredth at a time until it
  -- does, hue kept. 0-255 out.
  local floor = math.floor
  local function Fit(r, g, b, bg, down)
    if Ratio(Lum(r, g, b), bg) >= TARGET then return r, g, b end
    for t = 1, 100 do
      local f = t / 100
      local cr, cg, cb
      if down then
        cr, cg, cb = floor(r * (1 - f) + 0.5), floor(g * (1 - f) + 0.5), floor(b * (1 - f) + 0.5)
      else
        cr, cg, cb = floor(r + (255 - r) * f + 0.5), floor(g + (255 - g) * f + 0.5), floor(b + (255 - b) * f + 0.5)
      end
      if Ratio(Lum(cr, cg, cb), bg) >= TARGET then return cr, cg, cb end
    end
    if down then return 0, 0, 0 end
    return 255, 255, 255
  end

  -- token -> { r, g, b, a, hex = "rrggbb", mode = ... }: written in place
  -- when the setting moves, made once per token.
  local inks = {}
  function R.Ink(token)
    local mode = R.mode
    if mode ~= "light" and mode ~= "dark" then return nil end
    local e = inks[token]
    if e and e.mode == mode then return e end
    local T = ns.Theme
    local c = T and T.Colors and T.Colors[token]
    if type(c) ~= "table" then return nil end
    local base = mode == "light" and LIGHT_BASE[token]
    local r, g, b
    if base then
      r, g, b = base[1], base[2], base[3]
    else
      r, g, b = floor(c[1] * 255 + 0.5), floor(c[2] * 255 + 0.5), floor(c[3] * 255 + 0.5)
    end
    r, g, b = Fit(r, g, b, R.ground, mode == "light")
    if not e then
      e = {}
      inks[token] = e
    end
    e[1], e[2], e[3] = r / 255, g / 255, b / 255
    -- On the paper a mark is as solid as the words; on the shaded paper
    -- it keeps its own strength (the read dot's quiet).
    e[4] = (mode == "light") and 1 or (c[4] or 1)
    e.hex = ("%02x%02x%02x"):format(r, g, b)
    e.mode = mode
    return e
  end

  -- A colour that is no token (a class colour, 0-1) on the rows: a ring of
  -- answers, written in place.
  local ring, ringN, ringAt = {}, 0, 0
  function R.RGB(r, g, b)
    local mode = R.mode
    if mode ~= "light" and mode ~= "dark" then return r, g, b end
    for i = 1, ringN do
      local m = ring[i]
      if m.r == r and m.g == g and m.b == b and m.mode == mode then return m[1], m[2], m[3] end
    end
    local fr, fg, fb = Fit(floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5), R.ground, mode == "light")
    ringAt = (ringAt % 24) + 1
    if ringAt > ringN then ringN = ringAt end
    local m = ring[ringAt]
    if not m then
      m = {}
      ring[ringAt] = m
    end
    m.r, m.g, m.b, m.mode = r, g, b, mode
    m[1], m[2], m[3] = fr / 255, fg / 255, fb / 255
    return m[1], m[2], m[3]
  end

  -- The setting, read and put in force: the rows' inks published (none on
  -- the dark list, whose rows take the palette's), the fitting ground set.
  function R.Resolve()
    local UI = ns.MailboxUI
    local mode = UI and type(UI.GetRowTexture) == "function" and UI.GetRowTexture() or "light"
    R.mode = mode
    R.light = mode == "light"
    R.ground = (mode == "light") and LIGHT_LO or DarkGround()
    local T = ns.Theme
    if T and type(T.SetRowInks) == "function" then T.SetRowInks((mode ~= "none") and R or nil) end
  end

  -- Once, as the skin dresses its first window: the setting resolved, the
  -- mail binders given this ground (Theme.RowGround), and Theme's row paint
  -- (StyleMailRow) handing a paper row's stripe and hover over (Wash). Only
  -- here: every other look keeps the functions it always ran.
  function R.Install()
    R.Resolve()
    -- Text style Outline, which the paper's words are kept clean of (Face).
    R.outline = Skin.GetOutline() == "outline"
    local T = ns.Theme
    if not T or T.RowGround then return end
    T.RowGround = Skin.RowGround
    local style = T.StyleMailRow
    if type(style) == "function" then
      T.StyleMailRow = function(row, position, hovered)
        style(row, position, hovered)
        local paint = row and row.__pbRowPaint
        if paint then paint(row, row._rowIndex, row._hovered) end
      end
    end
  end

  -- The row's texts whose colour is their role's (the rest are painted per
  -- bind through the "row" ground): key, token.
  local STATIC = {
    "Subject", "textPrimary", "Detail", "textSecondary", "ColTime", "textSecondary",
    "ColMoney", "textSecondary", "ColSlots", "textSecondary", "Age", "textSecondary", "Money", "textSecondary",
  }
  local SHADOWED = { "Sender", "Subject", "Detail", "ColTime", "ColMoney", "ColSlots", "Age", "Money" }

  -- A text's shadow off (clean, on the paper) or back as its font gave it,
  -- read once from the string.
  local function Shadow(fs, clean)
    if not (fs and fs.SetShadowColor) then return end
    if fs.__pbShA == nil then
      local r, g, b, a
      if type(fs.GetShadowColor) == "function" then r, g, b, a = fs:GetShadowColor() end
      fs.__pbShR, fs.__pbShG, fs.__pbShB, fs.__pbShA = r or 0, g or 0, b or 0, a or 1
    end
    if clean then
      fs:SetShadowColor(0, 0, 0, 0)
    else
      fs:SetShadowColor(fs.__pbShR, fs.__pbShG, fs.__pbShB, fs.__pbShA)
    end
  end

  -- Under Text style Outline the dark words on the paper wear the copy
  -- Theme makes for a light ground (Theme.HostFont "light"), drawn with no
  -- outline and no shadow; anywhere else, and on the paper under Shadow and
  -- None, the copy every text wears. Only a copy is swapped (Theme.CopyBase):
  -- a font of any other kind is left as it is. `light`: the clean one.
  local function Face(fs, light)
    if not (fs and fs.GetFontObject) then return end
    local T = ns.Theme
    local object = fs:GetFontObject()
    local base = object and T.CopyBase and T.CopyBase(object)
    if not base then return end
    local want = T.HostFont(base, light and "light" or nil)
    if want and want ~= object then fs:SetFontObject(want) end
  end

  -- The row's own texts and marks in the rows' inks (`ground` "row"), or,
  -- with `ground` nil, back in the palette's.
  local function Texts(row, ground, clean)
    local T = ns.Theme
    -- Their face first, as a new font object may carry its own colour. Only
    -- under Outline on the paper, or to undo it: nothing otherwise.
    local light = clean and R.outline
    if light or row.__pbCleanFace then
      row.__pbCleanFace = light or nil
      for i = 1, #SHADOWED do Face(row[SHADOWED[i]], light) end
    end
    for i = 1, #STATIC, 2 do
      local fs = row[STATIC[i]]
      if fs then T.SetColor(fs, STATIC[i + 1], ground) end
    end
    for i = 1, #SHADOWED do Shadow(row[SHADOWED[i]], clean) end
    if row.Warning then T.SetColor(row.Warning, "warning", ground) end
    local dot = row.Indicator
    local shade = dot and dot.__pbShade
    if shade then shade:SetAlpha(clean and 0 or 1) end
  end

  -- The stripe and the pointer's wash on a row with paper (Theme's
  -- StyleMailRow hands them over): none at rest, white under the pointer.
  local function Wash(row, _, hovered)
    local bg = row._bg
    if not (bg and row.__pbPaperOn) then return end
    if hovered then
      bg:SetColorTexture(1, 1, 1, HOVER[R.mode] or 0.16)
    else
      bg:SetColorTexture(0, 0, 0, 0)
    end
  end

  -- Theme.RowGround: the row bound at displayed `position` (nil: not a
  -- mail, a heading in Mail Memory's list).
  function Skin.RowGround(row, position)
    local mode = R.mode
    local paper = row.__pbPaper
    if position == nil or mode == "none" then
      if row.__pbGround then
        row.__pbGround, row.__pbPaperOn = nil, nil
        if paper then paper:Hide() end
        Texts(row, nil, false)
        -- The sender's colour is painted again by the binder.
        if row.Sender then row.Sender.__pbClass = nil end
        -- The palette's stripe back.
        local T = ns.Theme
        if T and T.StyleMailRow then T.StyleMailRow(row, row._rowIndex, row._hovered) end
      end
      return
    end
    if not paper then
      paper = row:CreateTexture(nil, "BACKGROUND", nil, -2)
      paper:SetTexture(PAPER)
      paper:SetAllPoints(row)
      row.__pbPaper = paper
      row.__pbRowPaint = Wash
    end
    local h = row:GetHeight()
    if type(h) ~= "number" or h <= 0 then h = 24 end
    local band = floor(h * BAND_K + 0.5)
    if band < BAND_MIN then band = BAND_MIN end
    local span = (PY1 - PY0) - band
    local top = PY0 + ((tonumber(position) or 0) * STEP) % span
    paper:SetTexCoord(PX0 / SIZE, PX1 / SIZE, top / SIZE, (top + band) / SIZE)
    if row.__pbGround ~= mode then
      row.__pbGround, row.__pbPaperOn = mode, true
      local v = (mode == "dark") and DARK_V or 1
      paper:SetVertexColor(v, v, v, 1)
      paper:Show()
      if row.Sender then row.Sender.__pbClass = nil end
    end
    -- Each bind: a re-fonted or re-roled string comes back in its ink.
    Texts(row, "row", R.light)
    Wash(row, nil, row._hovered)
  end

  -------------------------------------------------------------
  -- The Send tab's Message box follows the rows
  -------------------------------------------------------------

  -- The Message box (the field many lines tall, Parts.Field) wears the
  -- rows' ground inside its bevel: the letter paper with the typed words in
  -- the dark ink, clean, and a selection a warm brown wash; the shaded paper
  -- with the light words; on the dark list, the dark sunken box the lists
  -- are. The client draws the cursor in the words' colour. Recipient,
  -- Subject and the gold boxes keep their look. Laid when the box is
  -- dressed and again when the setting changes; the box's own font set
  -- again (the text size) takes the ink again.
  local BEVEL = 3
  local SELECT_LIGHT = { 0.55, 0.42, 0.18, 0.30 }
  local grounds = setmetatable({}, { __mode = "k" })

  local function Highlight(box, light)
    if type(box.SetHighlightColor) ~= "function" then return end
    if box.__pbHiR == nil and type(box.GetHighlightColor) == "function" then
      local r, g, b, a = box:GetHighlightColor()
      if type(r) == "number" then box.__pbHiR, box.__pbHiG, box.__pbHiB, box.__pbHiA = r, g, b, a or 1 end
    end
    if light then
      box:SetHighlightColor(SELECT_LIGHT[1], SELECT_LIGHT[2], SELECT_LIGHT[3], SELECT_LIGHT[4])
    elseif box.__pbHiR then
      box:SetHighlightColor(box.__pbHiR, box.__pbHiG, box.__pbHiB, box.__pbHiA)
    end
  end

  local function Words(box)
    local T = ns.Theme
    if not T then return end
    -- As the rows' words (Face): clean on the paper under Outline. An edit
    -- box by the font Postbox gave it (Theme.SetBoxFont), set as that does;
    -- its SetFontObject comes back here and finds it in place.
    local light = R.light and R.outline
    if light or box.__pbCleanFace then
      box.__pbCleanFace = light or nil
      local object = box.__pbFont
      local base = object and T.CopyBase and T.CopyBase(object)
      local want = base and T.HostFont(base, light and "light" or nil)
      if want and want ~= object then
        box.__pbFont = want
        box:SetFontObject(want)
      end
      Face(box._placeholder, light)
    end
    T.SetColor(box, "textPrimary", T.ROW)
    Shadow(box, R.light)
    Highlight(box, R.light)
    local ph = box._placeholder
    if ph then
      T.SetColor(ph, "textPlaceholder", T.ROW)
      Shadow(ph, R.light)
    end
  end

  function Parts.MessageGround(wrap)
    grounds[wrap] = true
    if not R.mode then R.Install() end
    local mode = R.mode
    local paper = wrap.__pbPaper
    if mode ~= "none" and not paper then
      -- Inside the bevel, over the dark ground, under the bevel's art.
      paper = wrap:CreateTexture(nil, "BORDER", nil, -1)
      paper:SetTexture(PAPER)
      paper:SetTexCoord(PX0 / SIZE, PX1 / SIZE, PY0 / SIZE, PY1 / SIZE)
      paper:SetPoint("TOPLEFT", wrap, "TOPLEFT", BEVEL, -BEVEL)
      paper:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", -BEVEL, BEVEL)
      wrap.__pbPaper = paper
    end
    if paper then
      local v = (mode == "dark") and DARK_V or 1
      paper:SetVertexColor(v, v, v, 1)
      paper:SetShown(mode ~= "none")
    end
    local scroll = wrap._scroll
    local box = scroll and type(scroll.GetScrollChild) == "function" and scroll:GetScrollChild() or nil
    if not box then return end
    if not box.__pbGroundHooked and type(box.SetFontObject) == "function" then
      box.__pbGroundHooked = true
      hooksecurefunc(box, "SetFontObject", Words)
    end
    Words(box)
  end

  function Parts.MessageGrounds()
    for wrap in pairs(grounds) do Parts.MessageGround(wrap) end
  end

  -- The setting changed (Options > Window): the inks put in force and every
  -- mail list bound again, the message box laid on its new ground.
  function Skin.RowTextureChanged()
    R.Resolve()
    if Parts.MessageGrounds then Parts.MessageGrounds() end
    local UI = ns.MailboxUI
    if UI and type(UI.RefreshCollectRowLayout) == "function" then pcall(UI.RefreshCollectRowLayout) end
    local memory = ns.MailMemory
    if memory and type(memory.Refresh) == "function" then pcall(memory.Refresh) end
  end

  -- A reset (MailboxUI's ApplyResetLive): Row texture and Buttons read
  -- again, and whatever moved drawn as a change of the option draws it.
  function Skin.ApplyLook()
    local UI = ns.MailboxUI
    if not UI then return end
    if R.mode and type(UI.GetRowTexture) == "function" and UI.GetRowTexture() ~= R.mode then
      Skin.RowTextureChanged()
    end
    if Parts.ButtonLook and type(UI.GetButtonLook) == "function" and UI.GetButtonLook() ~= Parts.ButtonLook
       and Skin.ButtonLookChanged then
      Skin.ButtonLookChanged()
    end
    local O = Parts.Opacity
    if O.read and type(UI.GetBlizzOpacity) == "function" and UI.GetBlizzOpacity() ~= O.alpha then
      Skin.OpacityChanged()
    end
  end
end

-- One tagged child: what this skin dresses on it, each once.
function Parts.DressOne(c)
  if c.SlimBar and c.SlimBar.__pbBlizzBar == nil and c:IsObjectType("ScrollFrame") then Parts.ScrollBar(c.SlimBar) end
  if c.__postboxInputWrap and c.__pbBlizzField == nil then Parts.Field(c) end
  if c.__postboxPanel and not c.__pbBlizzInset and Sinks(c) then SinkPanel(c) end
  if c.__postboxPanel == "band" and c.__pbBlizzBand == nil and Parts.IsTotals(c) then Parts.Totals(c) end
  if c.SignH and c.__pbBlizzBar == nil then Parts.Bar(c) end
  if c.__postboxButton and not c.__postboxSelect and c.__pbBlizzButton == nil and c:IsObjectType("Button") then
    Parts.Button(c)
  end
  if c.__postboxCheck and c.__pbBlizzCheck == nil and c:IsObjectType("CheckButton") then Parts.Check(c) end
  if c.__pbGroupHead and c.__pbBlizzHeading == nil then Parts.Heading(c) end
  if c.__pbFindBox and c.__pbBlizzFind == nil then Parts.Find(c) end
  if c.__pbBlizzTile == nil and c.Chevron and Parts.IsTile(c) then Parts.Tile(c) end
  if c.__pbDash and c.__pbBlizzDash == nil then Parts.Dash(c) end
  if c.__pbFooter and c.__pbBlizzFooter == nil then Parts.Footer(c) end
  if c.__pbPopupAlways and c._toggle and c._toggle.__pbFooterOf then Parts.FooterMenu(c) end
  if c.__postboxSelect and c.__pbBlizzSelect == nil and c:IsObjectType("Button") then Parts.Select(c) end
  if c.__pbPopupAlways and c._toggle and c.__pbBlizzList == nil then Parts.List(c) end
  if c._selWash and c.__pbBlizzMark == nil then Parts.Row(c) end
  if c._divider and c.__pbBlizzDivider == nil then Parts.ListDivider(c) end
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
  -- A whole window walked: under 100%, the words it holds now patched.
  if frame.__pbBlizzWindow then pcall(Parts.Opacity.Walked, frame) end
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
  -- The rows' ground (Options > Window > Row texture) in force.
  if not Parts.Rows.mode then Parts.Rows.Install() end
  -- And Background opacity, which the walk at the end lays (Skin.Refresh).
  Parts.Opacity.Read()

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

-------------------------------------------------------------
-- Claim: when a host skin stands down to Postbox's own look
-------------------------------------------------------------

-- The style left on the host UI, and the host's skin standing down to
-- Postbox's own look (Core/Skin_EllesmereUI.lua: EllesmereUI on its Blizzard
-- Style or Classic WoW UI look, "stocklook", or its third-party skinning
-- switched off for Postbox, "hostoptout"): the host skin calls this once, at
-- the moment it decides, which is at login or when its handshake's
-- watchdog gives up. This skin takes the window then, unless something
-- already holds it, or the ElvUI skin is loaded: that one takes a window
-- EllesmereUI stood down from by its own deferred claim, as it always has.
-- A window built before the decision is dressed now, as its build would
-- have dressed it (Apply is once per window).
--
-- Should the host's skin claim later in the session (EllesmereUI dispatches
-- live when its skinning is switched back on), it stands down again once a
-- window wears this skin (it reads ns.SkinAppliedBy), so this art is never
-- left under another skin's; before any window is dressed, it takes the
-- slot over and nothing of this skin was ever drawn.
function Skin.HostStoodDown(reason)
  if reason ~= "stocklook" and reason ~= "hostoptout" then return end
  if ns.Skin or ns.ElvUISkin then return end
  local UI = ns.MailboxUI
  if UI and type(UI.HostSkinAllowed) == "function" and not UI.HostSkinAllowed() then return end
  ns.Skin = Skin
  local T = ns.Theme
  if T and type(T.ForEachWindow) == "function" then T.ForEachWindow(Skin.ApplyWindow) end
end
