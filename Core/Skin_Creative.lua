local _, ns = ...

-- =====================================================================
-- Postbox :: the creative window styles (the shared foundation)
-- ---------------------------------------------------------------------
-- Pillar Box, Faction, Post Office Counter and Goblin Express: choices in
-- the Window style list beside Postbox, Blizzard and the host UI, each a
-- small table in its own file (Core/Style_*.lua) registered here. The
-- designs are .dev/design/creative-styles (round 1, notes.md) and its v2
-- fixes; the art is drawn by .dev/tools/gen-styles.py into Media/Styles.
--
-- A CREATIVE STYLE IS THE POSTBOX STYLE WITH ART LAID ROUND IT. Chosen, it
-- claims the Postbox style's skin (ns.PostboxSkin) in that style's place and
-- adds to it: its own palette values for the controls, its own accent, and
-- an art holder behind every window the skin paints. Rows, text, figures and
-- every state wash stay the Postbox style's, code-drawn on the dark list, so
-- a refresh or a row bind costs exactly what it does there.
--
-- THE ART HOLDER. A child frame of each window, one level BELOW it, so every
-- region of the window (its title) and every child (the controls, the cog,
-- the close button, the resize grip) draws over the art, and nothing of the
-- art takes the mouse. On it:
--   ground   the painted face: a greyscale tile wrapped REPEAT and tinted,
--            its texture coordinates set from the size so a grain unit is
--            always the same size on screen. It is the only part the
--            window's opacity setting fades.
--   rim      the frame, a nine-slice of fixed corners and edges that are
--            uniform along their length, so a stretched edge is the same
--            edge; it stays solid whatever the opacity.
--   lip      the title bar, a three-slice drawn the same way.
--   rivets   placed by code at an even spacing that fits the length, so
--            none is ever cut in half, laid out again on a resize.
--   extras   whatever the style adds (the flag, the emblem, the tank).
-- Paint is authored greyscale and tinted with SetVertexColor, so a colour
-- choice costs one colour.
--
-- TITLE-BAR CONTROLS. A style declares how far in from the window's edge the
-- cog and the close button stand, so its corner art never cuts them: the
-- Postbox style's title strip, which both are centred on, is narrowed to
-- that inset, and anything seated on it later (Mail Memory's cog key)
-- follows.
--
-- COST. Textures load when the first window is dressed, and only the chosen
-- style's. Nothing runs on a timer; the art is laid out on a size change.
-- The flag and the tank change on the Mail tab caption's own pass
-- (Skin.OnMailState, MailboxUI), the counter's pigeonholes when the category
-- buttons are laid out (Skin.DressSweep, CollectTab), each only when what
-- they show has changed.
--
-- Claimed once, at PLAYER_LOGIN, when the style choice is one of these keys.
-- Under a host UI the default stays the host; a creative style applies only
-- when picked, as the Postbox style does. Changing style asks for a /reload,
-- and a new file here needs a full client restart.
-- =====================================================================

local CS = {}
ns.CreativeStyles = CS

local WHITE = "Interface\\AddOns\\Postbox\\Media\\white8x8.tga"
CS.WHITE = WHITE
CS.MEDIA = "Interface\\AddOns\\Postbox\\Media\\Styles\\"

local floor, max, min = math.floor, math.max, math.min

-------------------------------------------------------------
-- 1. The registry
--
-- A style file calls CS.Register with its table:
--   key          the saved style choice (profile.style)
--   nameKey      its name in the Window style list (a locale key)
--   inset        units from the window's edge to the cog and the close X
--   ground       { file, unit, inset, tint }: the tile, its size in units,
--                how far it keeps from the edge (under the rim), its tint
--   rivets       { atlas, part, spacing, top, bottom, x, tint }
--   titleBand    { r, g, b, a }: a band behind the title, faded with the
--                ground; `bandInset` units from each side
--   palette      values for the Postbox style's palette (Skin.Palette)
--   plates       Theme palette tokens for the segments and tiles
--   tabs         Theme.SetPlateTokens tokens for the window tabs
--   titleColor   the window titles' colour, where white does not read
--   trim         the colour name (of `colors`) of the keyline a floating card
--                of Postbox's (the arrange inspector, a dropdown's list) wears
--   colors       name -> { r, g, b }: the tints its art takes (CS.Tinted)
--   RefreshColors()  fills `colors` again from the colour choice
--   variants     { key, nameKey, ... } a colour choice, saved at variantKey
--   Prepare()    at the claim, before the palette is read: what depends on
--                the character (the faction)
--   Setup(CS)    once, at the first window
--   Build(art)   a window's own art (the holder is `art`, its window art.frame)
--   Layout(art, w, h)            the window's size changed
--   OnMailState(art, open)       the Mail tab's pass (main window only)
--   DressSweep(button, n, primary)   a category button was laid out
--   BannerInk(text, up, down)        the totals band's inks (see CollectTab)
-------------------------------------------------------------

local defs, order = {}, {}

function CS.Register(def)
  if type(def) ~= "table" or type(def.key) ~= "string" or defs[def.key] then return end
  defs[def.key] = def
  order[#order + 1] = def.key
end

function CS.Has(key)
  return type(key) == "string" and defs[key] ~= nil
end

-- The Window style list's entries, in load order.
function CS.Choices()
  local out = {}
  local L = ns.L
  for i = 1, #order do
    local def = defs[order[i]]
    out[#out + 1] = { id = def.key, name = L and L[def.nameKey] or def.key }
  end
  return out
end

-- The style this session wears, or nil.
function CS.Active()
  return CS.def
end

-------------------------------------------------------------
-- 2. Art primitives, for the style files
--
-- `atlas` is { file, w, h }: the file and its size in UI units (two texels
-- to a unit, as the glyphs). A part is { x, y, w, h [, c] } in the same
-- units; `c` is a slice's corner (or end) size.
-------------------------------------------------------------

local function Sharp(tex)
  if tex.SetSnapToPixelGrid then tex:SetSnapToPixelGrid(true) end
  if tex.SetTexelSnappingBias then tex:SetTexelSnappingBias(0) end
end

-- A texture on the holder. `wrap` "REPEAT" for a tile.
function CS.Tex(parent, layer, sub, file, wrap)
  local tex = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub or 0)
  if file then
    if wrap then tex:SetTexture(file, wrap, wrap) else tex:SetTexture(file) end
  end
  Sharp(tex)
  return tex
end

-- One part of an atlas on `tex`, optionally mirrored: "h", "v" or "hv".
function CS.Part(tex, atlas, part, mirror)
  tex:SetTexture(atlas.file)
  local l, r = part.x / atlas.w, (part.x + part.w) / atlas.w
  local t, b = part.y / atlas.h, (part.y + part.h) / atlas.h
  if mirror == "h" or mirror == "hv" then l, r = r, l end
  if mirror == "v" or mirror == "hv" then t, b = b, t end
  tex:SetTexCoord(l, r, t, b)
  return tex
end

-- A tile's coordinates for a region `w` by `h` units, the tile `unit` units
-- square (and `unitH` tall where it differs).
function CS.TileCoords(tex, w, h, unit, unitH)
  tex:SetTexCoord(0, max(0.01, (w or 0) / unit), 0, max(0.01, (h or 0) / (unitH or unit)))
end

-- A nine-slice: four corners of `c` units, four edges between them, and the
-- centre where `center` asks for it. The pieces are anchored to each other,
-- so they follow any size with no layout pass. Returns the nine; lay them
-- with CS.LayNine.
local NINE_KEYS = { "tl", "t", "tr", "l", "c", "r", "bl", "b", "br" }

function CS.Nine(parent, atlas, part, layer, sub, center)
  local nine = {}
  local c = part.c
  local x0, x1, x2, x3 = part.x, part.x + c, part.x + part.w - c, part.x + part.w
  local y0, y1, y2, y3 = part.y, part.y + c, part.y + part.h - c, part.y + part.h
  local xs = { x0, x1, x2, x3 }
  local ys = { y0, y1, y2, y3 }
  for i = 1, 9 do
    local key = NINE_KEYS[i]
    if key ~= "c" or center then
      local col, row = (i - 1) % 3, floor((i - 1) / 3)
      local tex = CS.Tex(parent, layer, sub, atlas.file)
      tex:SetTexCoord(xs[col + 1] / atlas.w, xs[col + 2] / atlas.w, ys[row + 1] / atlas.h, ys[row + 2] / atlas.h)
      nine[key] = tex
    end
  end
  nine.size = c
  return nine
end

-- Lays a nine-slice over `target`, `inset` units in from each edge (four
-- insets: left, top, right, bottom; one number for all), corners `size`
-- units square (the part's own corner by default).
function CS.LayNine(nine, target, l, t, r, b, size)
  t, r, b = t or l, r or l, b or l
  local s = size or nine.size
  nine.tl:ClearAllPoints()
  nine.tl:SetPoint("TOPLEFT", target, "TOPLEFT", l, -t)
  nine.tl:SetSize(s, s)
  nine.tr:ClearAllPoints()
  nine.tr:SetPoint("TOPRIGHT", target, "TOPRIGHT", -r, -t)
  nine.tr:SetSize(s, s)
  nine.bl:ClearAllPoints()
  nine.bl:SetPoint("BOTTOMLEFT", target, "BOTTOMLEFT", l, b)
  nine.bl:SetSize(s, s)
  nine.br:ClearAllPoints()
  nine.br:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", -r, b)
  nine.br:SetSize(s, s)
  nine.t:ClearAllPoints()
  nine.t:SetPoint("TOPLEFT", nine.tl, "TOPRIGHT")
  nine.t:SetPoint("BOTTOMRIGHT", nine.tr, "BOTTOMLEFT")
  nine.b:ClearAllPoints()
  nine.b:SetPoint("TOPLEFT", nine.bl, "TOPRIGHT")
  nine.b:SetPoint("BOTTOMRIGHT", nine.br, "BOTTOMLEFT")
  nine.l:ClearAllPoints()
  nine.l:SetPoint("TOPLEFT", nine.tl, "BOTTOMLEFT")
  nine.l:SetPoint("BOTTOMRIGHT", nine.bl, "TOPRIGHT")
  nine.r:ClearAllPoints()
  nine.r:SetPoint("TOPLEFT", nine.tr, "BOTTOMLEFT")
  nine.r:SetPoint("BOTTOMRIGHT", nine.br, "TOPRIGHT")
  if nine.c then
    nine.c:ClearAllPoints()
    nine.c:SetPoint("TOPLEFT", nine.tl, "BOTTOMRIGHT")
    nine.c:SetPoint("BOTTOMRIGHT", nine.br, "TOPLEFT")
  end
end

-- Every piece of a slice set, through `fn(tex, ...)`.
function CS.Each(set, fn, ...)
  for i = 1, 9 do
    local tex = set[NINE_KEYS[i]]
    if tex then fn(tex, ...) end
  end
  if set.m then fn(set.l3, ...) fn(set.m, ...) fn(set.r3, ...) end
end

-- A horizontal three-slice: ends `c` units wide, the middle between them.
function CS.Three(parent, atlas, part, layer, sub)
  local c = part.c
  local three = { size = c, h = part.h }
  local xs = { part.x, part.x + c, part.x + part.w - c, part.x + part.w }
  local t, b = part.y / atlas.h, (part.y + part.h) / atlas.h
  local keys = { "l3", "m", "r3" }
  for i = 1, 3 do
    local tex = CS.Tex(parent, layer, sub, atlas.file)
    tex:SetTexCoord(xs[i] / atlas.w, xs[i + 1] / atlas.w, t, b)
    three[keys[i]] = tex
  end
  return three
end

-- Lays a three-slice from `left` to `right` (both points relative to
-- `target`'s TOPLEFT and TOPRIGHT), `y` down from its top, `h` tall and its
-- ends `e` wide (the part's height and end by default).
function CS.LayThree(three, target, left, right, y, h, e)
  h = h or three.h
  e = e or three.size
  three.l3:ClearAllPoints()
  three.l3:SetPoint("TOPLEFT", target, "TOPLEFT", left, -y)
  three.l3:SetSize(e, h)
  three.r3:ClearAllPoints()
  three.r3:SetPoint("TOPRIGHT", target, "TOPRIGHT", -right, -y)
  three.r3:SetSize(e, h)
  three.m:ClearAllPoints()
  three.m:SetPoint("TOPLEFT", three.l3, "TOPRIGHT")
  three.m:SetPoint("BOTTOMRIGHT", three.r3, "BOTTOMLEFT")
end

-- A code-drawn line: the white tile, tinted.
function CS.Line(parent, layer, sub)
  local tex = parent:CreateTexture(nil, layer or "BORDER", nil, sub or 0)
  tex:SetTexture(WHITE)
  return tex
end

-- Four lines forming a rectangle `inset` units inside `target`, `width`
-- units wide. Returns them; tint with CS.TintAll.
function CS.Frame4(parent, layer, sub)
  local out = {}
  for i = 1, 4 do out[i] = CS.Line(parent, layer, sub) end
  return out
end

function CS.LayFrame4(lines, target, inset, width, top)
  local t = top or inset
  local a, b, c, d = lines[1], lines[2], lines[3], lines[4]
  a:ClearAllPoints()
  a:SetPoint("TOPLEFT", target, "TOPLEFT", inset, -t)
  a:SetPoint("TOPRIGHT", target, "TOPRIGHT", -inset, -t)
  a:SetHeight(width)
  b:ClearAllPoints()
  b:SetPoint("BOTTOMLEFT", target, "BOTTOMLEFT", inset, inset)
  b:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", -inset, inset)
  b:SetHeight(width)
  c:ClearAllPoints()
  c:SetPoint("TOPLEFT", target, "TOPLEFT", inset, -t)
  c:SetPoint("BOTTOMLEFT", target, "BOTTOMLEFT", inset, inset)
  c:SetWidth(width)
  d:ClearAllPoints()
  d:SetPoint("TOPRIGHT", target, "TOPRIGHT", -inset, -t)
  d:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", -inset, inset)
  d:SetWidth(width)
end

local function TintOne(tex, color)
  tex:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
end

function CS.TintAll(list, color)
  for i = 1, #list do TintOne(list[i], color) end
end

-- A texture's tint that follows the style's colour choice: `name` is a key of
-- the style's `colors`. Registered on the window's
-- holder, so a new choice repaints every window at once.
function CS.Tinted(art, tex, name)
  art.tinted[tex] = name
  local color = CS.Color(name)
  if color then TintOne(tex, color) end
  return tex
end

function CS.TintedSet(art, set, name)
  for i = 1, 9 do
    local tex = set[NINE_KEYS[i]]
    if tex then CS.Tinted(art, tex, name) end
  end
  if set.m then
    CS.Tinted(art, set.l3, name)
    CS.Tinted(art, set.m, name)
    CS.Tinted(art, set.r3, name)
  end
end

-- The style's current colour for `name`.
function CS.Color(name)
  local def = CS.def
  if not def then return nil end
  return def.colors and def.colors[name]
end

-------------------------------------------------------------
-- 3. The colour choice (a style's variants: the post box's paint)
-------------------------------------------------------------

local function Profile()
  return ns.Store.EnsurePath("profile", {})
end

function CS.GetVariant()
  local def = CS.def
  if not (def and def.variants) then return nil end
  local saved = Profile()[def.variantKey]
  for i = 1, #def.variants do
    if def.variants[i].key == saved then return saved end
  end
  return def.variants[1].key
end

function CS.SetVariant(key)
  local def = CS.def
  if not (def and def.variants) then return end
  local found = false
  for i = 1, #def.variants do
    if def.variants[i].key == key then found = true end
  end
  if not found then return end
  Profile()[def.variantKey] = (key ~= def.variants[1].key) and key or nil
  if def.RefreshColors then def.RefreshColors() end
  CS.Repaint()
end

-- The rows the options draw for it: { id, name }, or nil for a style
-- without one.
function CS.VariantChoices()
  local def = CS.def
  if not (def and def.variants) then return nil end
  local out, L = {}, ns.L
  for i = 1, #def.variants do
    local v = def.variants[i]
    out[i] = { id = v.key, name = L and L[v.nameKey] or v.key }
  end
  return out
end

-------------------------------------------------------------
-- 4. Windows
-------------------------------------------------------------

-- Every dressed window's holder, weak-keyed by holder.
local holders = setmetatable({}, { __mode = "k" })
CS._holders = holders
-- And every floating card's keyline (CS.Trim).
local trims = setmetatable({}, { __mode = "k" })

local function Opacity(art)
  local skin = CS.skin
  if art.opaque then
    local p = skin and skin.Palette and skin.Palette.opaque
    return p and p[4] or 0.97
  end
  return skin and skin.GetBgOpacity and skin.GetBgOpacity() or 0.9
end

-- The opacity setting fades the ground and nothing else; the Postbox style's
-- own fill and strip step aside for it (region alpha, which its repaint,
-- a colour, never touches).
local function ApplyOpacity(art)
  local shell = art.frame.__pbShell
  if shell then
    shell.fill:SetAlpha(0)
    shell.strip:SetAlpha(0)
  end
  local alpha = Opacity(art)
  if art.ground then art.ground:SetAlpha(alpha) end
  if art.band then art.band:SetAlpha(alpha) end
  local def = CS.def
  if def and def.OnOpacity then def.OnOpacity(art, alpha) end
end

-- Rivets down both sides, evenly spaced in the room between `top` and
-- `bottom`, `x` units in from each edge (their centres). Pooled: a resize
-- reuses them, and only a window grown past every size before makes more.
local function LayRivets(art, h)
  local spec = art.rivetSpec
  if not spec then return end
  local room = h - spec.top - spec.bottom
  local n = max(2, floor(room / spec.spacing + 0.5) + 1)
  if room <= 0 then n = 0 end
  local pool = art.rivets
  local need = n * 2
  for i = #pool + 1, need do
    local tex = CS.Tex(art, "ARTWORK", 2)
    CS.Part(tex, spec.atlas, spec.part)
    tex:SetSize(spec.part.w, spec.part.h)
    if spec.tint then CS.Tinted(art, tex, spec.tint) end
    pool[i] = tex
  end
  local step = (n > 1) and room / (n - 1) or 0
  for i = 1, n do
    local y = spec.top + (i - 1) * step
    local left, right = pool[2 * i - 1], pool[2 * i]
    left:ClearAllPoints()
    left:SetPoint("CENTER", art, "TOPLEFT", spec.x, -y)
    left:Show()
    right:ClearAllPoints()
    right:SetPoint("CENTER", art, "TOPRIGHT", -spec.x, -y)
    right:Show()
  end
  for i = need + 1, #pool do pool[i]:Hide() end
end

local function Layout(art)
  local w, h = art:GetSize()
  w, h = w or 0, h or 0
  if w <= 0 or h <= 0 then return end
  if art.ground then
    local g = art.groundInset or 0
    CS.TileCoords(art.ground, w - 2 * g, h - 2 * g, art.groundUnit)
  end
  LayRivets(art, h)
  local def = CS.def
  if def and def.Layout then def.Layout(art, w, h) end
end
CS.Layout = Layout

local function OnArtSize(self)
  Layout(self)
end

-- The title strip narrowed to the style's inset: the cog (5 units in from
-- the strip's left), the close X (3 from its right) and whatever else stands
-- on it move in with it. The title is centred on the window instead of the
-- strip, which the two different offsets would move by a unit.
local function SeatControls(frame, def)
  local shell = frame.__pbShell
  local strip = shell and shell.strip
  local inset = def.inset
  if strip and inset then
    strip:ClearAllPoints()
    strip:SetPoint("TOPLEFT", frame, "TOPLEFT", max(0, inset - 5), 0)
    strip:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -max(0, inset - 3), 0)
  end
  local title = frame.TitleText
  if title and strip then
    title:ClearAllPoints()
    title:SetPoint("CENTER", frame, "TOP", 0, -(strip:GetHeight() or 25) / 2)
  end
end

local function PaintTitle(frame, def)
  local title = frame.TitleText
  local c = def.titleColor
  if title and c then title:SetTextColor(c[1], c[2], c[3], 1) end
end

function CS.Dress(frame)
  local def, skin = CS.def, CS.skin
  if not (def and skin and frame) or frame.__pbCreativeArt then return end
  if not CS.ready then
    CS.ready = true
    if def.Setup then def.Setup(CS) end
  end

  local art = CreateFrame("Frame", nil, frame)
  art:SetAllPoints(frame)
  art:SetFrameLevel(max(0, (frame:GetFrameLevel() or 1) - 1))
  art:EnableMouse(false)
  art.frame = frame
  art.opaque = frame.__pbEuiAlwaysOpaque and true or false
  art.main = frame.GetName and frame:GetName() == "PostboxFrame" or false
  art.tinted = {}
  art.rivets = {}
  frame.__pbCreativeArt = art
  holders[art] = true
  if art.main then CS.mainArt = art end

  -- The ground, under the rim by `groundInset` on every side so a rounded
  -- corner never shows a square one behind it.
  local ground = def.ground
  if ground then
    local g = ground.inset or 0
    art.ground = CS.Tex(art, "BACKGROUND", -8, ground.file, "REPEAT")
    art.ground:SetPoint("TOPLEFT", art, "TOPLEFT", g, -g)
    art.ground:SetPoint("BOTTOMRIGHT", art, "BOTTOMRIGHT", -g, g)
    art.groundInset, art.groundUnit = g, ground.unit
    if ground.tint then CS.Tinted(art, art.ground, ground.tint) end
  end

  local band = def.titleBand
  if band then
    local inset = def.bandInset or 0
    art.band = CS.Line(art, "BACKGROUND", -7)
    art.band:SetVertexColor(band[1], band[2], band[3], band[4] or 1)
    art.band:SetPoint("TOPLEFT", art, "TOPLEFT", inset, -inset)
    art.band:SetPoint("TOPRIGHT", art, "TOPRIGHT", -inset, -inset)
    art.band:SetHeight(25 - inset)
  end

  if def.rivets then
    art.rivetSpec = def.rivets
  end

  if def.Build then def.Build(art) end

  SeatControls(frame, def)
  PaintTitle(frame, def)
  ApplyOpacity(art)
  art:SetScript("OnSizeChanged", OnArtSize)
  Layout(art)
  return art
end

-- A floating card of Postbox's own (the arrange inspector, a dropdown's
-- list): too tight for the rim, so a two-unit keyline in the frame's colour
-- on a child laid over its edge, where no text stands.
function CS.Trim(card)
  local def = CS.def
  if not (def and def.trim and card) or card.__pbCreativeTrim then return end
  local holder = CreateFrame("Frame", nil, card)
  holder:SetAllPoints(card)
  holder:EnableMouse(false)
  holder.frame = card
  holder.tinted = {}
  local lines = CS.Frame4(holder, "BORDER", 7)
  CS.LayFrame4(lines, holder, 0, 2)
  for i = 1, 4 do CS.Tinted(holder, lines[i], def.trim) end
  card.__pbCreativeTrim = holder
  trims[holder] = true
end

-- Every window again: a colour choice, or the opacity.
function CS.Repaint()
  for art in pairs(holders) do
    for tex, name in pairs(art.tinted) do
      local color = CS.Color(name)
      if color then TintOne(tex, color) end
    end
    ApplyOpacity(art)
  end
  for holder in pairs(trims) do
    for tex, name in pairs(holder.tinted) do
      local color = CS.Color(name)
      if color then TintOne(tex, color) end
    end
  end
  local def = CS.def
  if def and def.OnRepaint then def.OnRepaint() end
end

-------------------------------------------------------------
-- 5. The claim
-------------------------------------------------------------

-- Art that fails to build leaves the window as the Postbox style draws it,
-- and says why where errors are read (BugSack), rather than breaking the
-- window it was dressing.
local function Report(ok, err)
  if ok then return end
  if type(geterrorhandler) == "function" then geterrorhandler()(err) end
end

local function Activate(def, skin)
  CS.def, CS.skin = def, skin
  if def.Prepare then def.Prepare() end

  -- The palette: the style's values for the Postbox style's names. A name
  -- the Postbox style no longer has is skipped rather than invented.
  local P = skin.Palette
  if P and def.palette then
    for key, value in pairs(def.palette) do
      if P[key] ~= nil then P[key] = value end
    end
  end
  if def.plates and ns.Theme and type(ns.Theme.OverridePalette) == "function" then
    ns.Theme.OverridePalette(def.plates)
  end

  if def.RefreshColors then def.RefreshColors() end
  skin.IsCreativeStyle = true
  skin.CreativeKey = def.key

  -- The rim is the window's edge: the Postbox style's keyline stays off.
  skin.GetBorderStyle = function() return "none" end

  local baseApply = skin.Apply
  skin.Apply = function(frame)
    local fresh = frame and not frame.__postboxSkinned
    baseApply(frame)
    if not fresh then return end
    if def.tabs and frame.TabButtons and ns.Theme and ns.Theme.SetPlateTokens then
      for _, tab in pairs(frame.TabButtons) do
        if tab then ns.Theme.SetPlateTokens(tab, def.tabs) end
      end
    end
    Report(pcall(CS.Dress, frame))
  end
  skin.ApplyWindow = skin.Apply

  local baseAppearance = skin.ApplyAppearance
  skin.ApplyAppearance = function()
    baseAppearance()
    for art in pairs(holders) do pcall(ApplyOpacity, art) end
  end

  -- A change of font re-dresses the titles in white; a style whose titles
  -- are another colour puts its own back.
  local baseFonts = skin.ApplyFonts
  skin.ApplyFonts = function()
    baseFonts()
    -- The title's width moved: what is sized to it (a nameplate, whether
    -- an emblem fits) is laid out again.
    for art in pairs(holders) do
      PaintTitle(art.frame, def)
      pcall(Layout, art)
    end
  end

  -- A floating card is refreshed, never applied: it is dressed on its first
  -- refresh. One field read for every other frame.
  local baseRefresh = skin.Refresh
  skin.Refresh = function(frame)
    baseRefresh(frame)
    if frame and frame.__pbPopupAlways and not frame.__pbCreativeTrim then Report(pcall(CS.Trim, frame)) end
  end

  skin.OnMailState = function(open)
    local art = CS.mainArt
    if art and def.OnMailState then def.OnMailState(art, open) end
  end
  skin.DressSweep = def.DressSweep
  skin.BannerInk = def.BannerInk
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
  self:UnregisterEvent("PLAYER_LOGIN")
  local UI = ns.MailboxUI
  if not (UI and type(UI.GetStyleChoice) == "function") then return end
  local def = defs[UI.GetStyleChoice()]
  if not def then return end
  local skin = ns.PostboxSkin
  if not skin or ns.Skin then return end
  Activate(def, skin)
  ns.Skin = skin
end)
