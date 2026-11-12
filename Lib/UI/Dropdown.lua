-- Postbox foundation :: the select control.
--
-- A label, a toggle button, and a drop-down list of items, built entirely from
-- plain frames the addon owns. Blizzard's menu and dropdown APIs are avoided
-- deliberately (see COMBAT_TAINT.md), which is also what lets the list panel be
-- kept fully opaque.
--
-- Publishes: ns.Core.UI.Dropdown.Create / .CloseAll

local _, ns = ...

ns.Core = ns.Core or {}
local Core = ns.Core
Core.UI = Core.UI or {}
Core.UI.Dropdown = Core.UI.Dropdown or {}

local Dropdown = Core.UI.Dropdown

-- The addon's own white tile: the list panel's fill and edge must survive a
-- UI pack's loose-file texture overrides (see Lib/UI/Theme.lua).
local WHITE = "Interface\\AddOns\\Postbox\\Media\\white8x8.tga"

local DEFAULT_HEIGHT = 30
local DEFAULT_ROW_HEIGHT = 20
local DEFAULT_TOGGLE_WIDTH = 200
local DEFAULT_TOGGLE_HEIGHT = 22
local LIST_PADDING = 4
-- The room before every row's caption, chosen or not, so the two start at
-- the same x and a chosen row's bar (ChosenArt) stands clear of its words.
local MARK_GUTTER = 8
-- The toggle's colour square: its left edge in from the toggle's, its size,
-- and the room kept between it and the value.
local SWATCH_X, SWATCH_SIZE, SWATCH_GAP = 7, 10, 4
-- The toggle's art, where the items carry their own (the list draws each
-- beside its name; the toggle the chosen one's, PaintArt): the least room
-- between it and the toggle's left edge, and the room between it and the
-- value, the list's own.
local ART = { X = 4, GAP = 6 }
-- The room kept clear at each end of the toggle for what is drawn there: the
-- Postbox style's caret (5 wide, centred 9 in from the right edge, so out to
-- 11.5) and the stock button's end caps (12). Only a value that already ran
-- into the caret is too long for the box this leaves.
local CAPTION_GUTTER = 12
local LIST_GAP = 2
-- Twelve rows of the default height plus padding. A list taller than this
-- scrolls instead of growing (opts.maxListHeight overrides).
local DEFAULT_MAX_LIST_HEIGHT = 248
local SCROLLBAR_INSET = 3
-- Clear of every sibling widget's border overlay in the owning window.
local LIST_LEVEL_OFFSET = 40

-- Every list this module has built. Weak-keyed so a discarded dropdown does not
-- pin its frames for the rest of the session.
local lists = setmetatable({}, { __mode = "k" })

-- A press anywhere but on an open list or the toggle it hangs from closes the
-- list, heard as GLOBAL_MOUSE_DOWN -- and only while a list is open, so
-- nothing listens while none is. The toggle is left to its own click, which
-- closes the list it opened.
--
-- This was a full-screen frame behind the list, which kept the pointer off
-- everything around the list only while it lay over the window the list opens
-- from. Nothing held it there: the options panel is a toplevel window in the
-- same strata, which the client raises when it is clicked, and the frame was
-- not the panel's own. In game the rows around the list, and under the edge
-- of the list, took the pointer as if no list were open. The list is the
-- window's own descendant and rises with it, and it takes the pointer over
-- all of itself (BuildList); a window whose own hover must hold while a list
-- is open is told when it opens and closes (opts.onList).
local watcher

local function AnyListShown()
  for list in pairs(lists) do
    if list:IsShown() then return true end
  end
  return false
end

local function PressAnywhere()
  for list in pairs(lists) do
    if list:IsShown() and not list:IsMouseOver()
        and not (list._toggle and list._toggle:IsMouseOver()) then
      list:Hide()
    end
  end
end

-- Listens while a list is open, and stops when the last one closes.
local function Watch()
  local open = AnyListShown()
  if open and not watcher then
    watcher = CreateFrame("Frame")
    watcher:SetScript("OnEvent", PressAnywhere)
  end
  if not watcher then return end
  if open then
    watcher:RegisterEvent("GLOBAL_MOUSE_DOWN")
  else
    watcher:UnregisterEvent("GLOBAL_MOUSE_DOWN")
  end
end

-- One mark for a chosen row, in every list and menu here as on the mail
-- rows and the character picker: a wash of the accent over the whole row,
-- an accent bar at its left edge, and its words in the accent's bright tone.
-- The row under the pointer has a lighter, neutral wash alone (the row's
-- own hover), so chosen and pointed-at differ in hue, the bar and the words,
-- never in alpha alone, at any window opacity. Made once with the row.
local function ChosenArt(row)
  local wash = row:CreateTexture(nil, "BACKGROUND", nil, 1)
  wash:SetAllPoints()
  wash:Hide()
  local bar = row:CreateTexture(nil, "ARTWORK")
  bar:SetWidth(2)
  bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
  bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
  bar:Hide()
  row._selWash, row._selBar = wash, bar
end

-- The ink a row's words wear when it is not the chosen one: their font's,
-- as that font is now. The font is the named one the words wear (a copy of
-- a host UI's under its skin, the Postbox style's recoloured with its
-- palette), else the one they were given when the row was made (row._font).
-- Read when the row is painted, never kept: a palette, a Mode or a host's
-- looks may have moved since, and a colour kept from then is that palette's.
local function FontInk(row, text)
  local themed = ns.Theme
  local font = text.GetFontObject and text:GetFontObject() or nil
  if themed and type(themed.NamedFont) == "function" then font = themed.NamedFont(font) end
  font = font or row._font
  if font and type(font.GetTextColor) == "function" then return font:GetTextColor() end
  return nil
end

-- The mark painted on (`on`) or off a row, the accent resolved live (a host
-- UI's own colour wins where the addon theme is present). A row given the
-- accent's ink once takes its font's ink again whenever it is painted
-- unchosen (FontInk), off the theme's repaints so none paints it in the
-- accent it no longer wears; a row never chosen keeps following its font
-- untouched. Nothing is made.
local function PaintChosen(row, text, on)
  local wash, bar = row._selWash, row._selBar
  if not wash then return end
  local themed = ns.Theme
  if on then
    local r, g, b = 0.90, 0.78, 0.30
    if themed and type(themed.GetAccent) == "function" then r, g, b = themed.GetAccent() end
    wash:SetColorTexture(r, g, b, 0.14)
    -- The bar is a mark: the accent's mark tone, legible on a light list.
    if themed and type(themed.GetAccentTone) == "function" then r, g, b = themed.GetAccentTone("mark") end
    bar:SetColorTexture(r, g, b, 0.9)
    if text then
      if themed and type(themed.SetColor) == "function" then
        themed.SetColor(text, "accentBright")
      else
        text:SetTextColor(r, g, b, 1)
      end
    end
    row._inked = true
  elseif row._inked and text then
    local r, g, b, a = FontInk(row, text)
    if type(r) == "number" then
      if themed and type(themed.SetTextRGB) == "function" then
        themed.SetTextRGB(text, r, g, b, a)
      else
        text:SetTextColor(r, g, b, a or 1)
      end
    end
  end
  wash:SetShown(on and true or false)
  bar:SetShown(on and true or false)
end

-- An item drawn in a face of its own (`item.face`, a font file: the
-- options' Font list, each font's name in that font). Its words wear a font
-- object of this module's own, one per file and use -- "row" for the list's
-- rows, "value" for the toggle's caption -- made the first time that file is
-- shown and kept for the session: a dozen objects at most, never one per
-- row or per open. Each is the font its words wore otherwise (`base`, a
-- named font: the row's sized font, the toggle's select value) copied, then
-- set in the item's file at that font's size and outline, so it keeps the
-- base's colour, shadow and size and changes only the file. It is dressed
-- again only when the base moved (a Text size, an outline, a palette:
-- FACE.Dress compares), and the words take it again then (Theme.Retake). A
-- file the client does not set leaves the words in their base. Copied
-- with CopyFontObject and never given a font object to inherit from, so no
-- chain of fonts can loop (the 2026-10-15 crash: a font inheriting from
-- itself); its base is always a named font that is not one of these.
local FACE = { objs = { row = {}, value = {} }, state = {}, n = 0, selects = setmetatable({}, { __mode = "k" }) }

function FACE.Object(kind, path)
  local byPath = FACE.objs[kind]
  local font = byPath[path]
  if font == nil then
    font = false
    if type(CreateFont) == "function" then
      FACE.n = FACE.n + 1
      font = CreateFont("PostboxFaceFont" .. FACE.n) or false
    end
    if font then
      FACE.state[font] = { path = path, ok = false }
      -- Postbox's own, kept as it is: never copied again in a host's face.
      local themed = ns.Theme
      if themed and type(themed.OwnFont) == "function" then themed.OwnFont(font) end
    end
    byPath[path] = font
  end
  return font or nil
end

-- `object` where it can be a base: a named font that is not one of these.
function FACE.Base(object)
  local themed = ns.Theme
  if not object or FACE.state[object] then return nil end
  if themed and type(themed.NamedFont) == "function" then return themed.NamedFont(object) end
  return nil
end

-- `font` as `base` is now, in its own file. -> whether it set (the words
-- may wear it), and whether it was dressed anew (the words take it again).
function FACE.Dress(font, base)
  local st = FACE.state[font]
  if not (st and base and type(base.GetFont) == "function") then return false, false end
  local p, s, f = base:GetFont()
  local r, g, b, a = base:GetTextColor()
  local sr, sg, sb, sa, sx, sy
  if type(base.GetShadowColor) == "function" then sr, sg, sb, sa = base:GetShadowColor() end
  if type(base.GetShadowOffset) == "function" then sx, sy = base:GetShadowOffset() end
  if st.base == base and st.p == p and st.s == s and st.f == f and st.r == r and st.g == g and st.b == b
      and st.a == a and st.sr == sr and st.sg == sg and st.sb == sb and st.sa == sa and st.sx == sx
      and st.sy == sy then
    return st.ok, false
  end
  st.base, st.p, st.s, st.f, st.r, st.g, st.b, st.a = base, p, s, f, r, g, b, a
  st.sr, st.sg, st.sb, st.sa, st.sx, st.sy = sr, sg, sb, sa, sx, sy
  st.ok = false
  if type(s) ~= "number" or s <= 0 then return false, true end
  if type(font.CopyFontObject) == "function" then pcall(font.CopyFontObject, font, base) end
  local fine, set = pcall(font.SetFont, font, st.path, s, f or "")
  st.ok = fine and set ~= false
  return st.ok, true
end

-- A string onto `want`: set where it wears another, taken again where it
-- wears it and it was dressed anew.
function FACE.Wear(fs, want, worn, changed)
  if worn ~= want then
    fs:SetFontObject(want)
  elseif changed then
    local themed = ns.Theme
    if themed and type(themed.Retake) == "function" then themed.Retake(fs, want) else fs:SetFontObject(want) end
  end
end

-- A list's rows that carry a face, in it (on each open, before the list is
-- measured): a row's base is the font it wore before, or the one a skin's
-- pass put on it since.
function FACE.PaintRows(list)
  local rows = list and list._rows
  if not rows then return end
  for i = 1, #rows do
    local row = rows[i]
    local item, text = row._item, row._text
    local path = item and item.face
    if path and text then
      local worn = text:GetFontObject()
      local base = FACE.Base(worn) or row._faceBase
      row._faceBase = base
      local font = FACE.Object("row", path)
      if font and base then
        local ok, changed = FACE.Dress(font, base)
        if ok then
          FACE.Wear(text, font, worn, changed)
        elseif worn ~= base then
          text:SetFontObject(base)
        end
      end
    end
  end
end

-- Every select with faces fitted again in its chosen face: the fonts they
-- are made from moved (the Postbox style's fonts, Skin._PaintFonts).
function Dropdown.RepaintFaces()
  for container in pairs(FACE.selects) do
    if container.__pbRefaces then pcall(container.__pbRefaces) end
  end
end

-- Closes every list this module created, except the one passed in. Called with
-- no argument by Core/SendTab.lua and Core/RecipientManager.lua before they
-- open their own popups, so two lists can never overlap.
function Dropdown.CloseAll(except)
  for list in pairs(lists) do
    if list ~= except and list:IsShown() then list:Hide() end
  end
  Watch()
end

-- A colour swatch: a one-unit edge in the theme's quiet grey and the colour
-- inside it, on a holder frame of its own (a skin's repaint of the button it
-- sits on fades the button's own textures, never a child's). `size` square.
-- `round`: a dot rather than a square, so a colour beside a name never reads
-- as an unticked checkbox; a colour the same as the ground behind it still
-- shows, as its thin grey ring. Where the client has no masks, a square.
local ROUND_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local function NewSwatch(parent, size, round)
  local holder = CreateFrame("Frame", nil, parent)
  holder:SetSize(size, size)
  holder:SetFrameLevel((parent:GetFrameLevel() or 1) + 2)
  local edge = holder:CreateTexture(nil, "OVERLAY", nil, 0)
  edge:SetAllPoints()
  local fill = holder:CreateTexture(nil, "OVERLAY", nil, 1)
  fill:SetPoint("TOPLEFT", holder, "TOPLEFT", 1, -1)
  fill:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -1, 1)
  if round and type(holder.CreateMaskTexture) == "function" then
    local outer = holder:CreateMaskTexture()
    outer:SetTexture(ROUND_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    outer:SetAllPoints(edge)
    edge:AddMaskTexture(outer)
    local inner = holder:CreateMaskTexture()
    inner:SetTexture(ROUND_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    inner:SetAllPoints(fill)
    fill:AddMaskTexture(inner)
  end
  holder.Edge, holder.Fill = edge, fill
  holder:Hide()
  return holder
end

-- A value cut short in its caption box says the whole of it on hover, as the
-- addon's other fitted captions do (Theme.FitText leaves it on the toggle).
-- An owner that puts a tooltip of its own over the toggle (the options
-- panel) builds over this one and adds the value itself; this one stands
-- where nothing else does (the recipient manager's sort).
local function ToggleEnter(self)
  -- Fitted again first: the box is the same, but the font the value wears
  -- may not be (a skin's pass after the value was set); unchanged, the
  -- fitter answers from its memo.
  if self.__pbRefit then self.__pbRefit() end
  local text = self.__pbOverflowText
  local tip = GameTooltip
  if not text or not tip then return end
  tip:SetOwner(self, "ANCHOR_TOP")
  local themed = ns.Theme
  if themed and type(themed.AddOverflowLine) == "function" then
    themed.AddOverflowLine(self, tip)
  else
    tip:AddLine(text, 1, 1, 1, true)
  end
  tip:Show()
end

local function ToggleLeave(self)
  local tip = GameTooltip
  if tip and tip:IsOwned(self) then tip:Hide() end
end

-- A caption's width with nothing holding it in: its box (Caption) bounds
-- the string, and a value is measured against that box, not by it.
local function TextWidth(label)
  local w
  if label.GetUnboundedStringWidth then w = label:GetUnboundedStringWidth() else w = label:GetStringWidth() end
  return tonumber(w) or 0
end

local function PaintSwatch(swatch, r, g, b)
  if not swatch then return end
  if type(r) ~= "number" then
    swatch:Hide()
    return
  end
  local themed = ns.Theme
  if themed and type(themed.FillColor) == "function" then
    themed.FillColor(swatch.Edge, "textDisabled")
  else
    swatch.Edge:SetColorTexture(0.56, 0.56, 0.56, 1)
  end
  swatch.Fill:SetColorTexture(r, g, b, 1)
  swatch:Show()
end

-- opts.swatchFor(id) -> r, g, b (or nil): a list of colours shows each one,
-- in a square before its name and on the toggle beside the one chosen.
-- opts.onList(container, open): the list opened (true) or closed (false),
-- once each way, however it closed.
-- opts.captions: every text the toggle can show, where the owner puts its
-- own there rather than an item's name (the recipient manager's "Sort:
-- Name"); measured in the names' place (container:FitWidth).
-- An item { heading = true, name = } is no choice: it names the group of
-- items under it in the list (Sound on new mail's Postbox, Game, Other
-- addons).
-- opts.sample = { w, h }: the toggle is a small colour button, no words and
-- no caret on it, only a sample `w` x `h` in its middle, of the colour
-- opts.sampleFor() answers (else swatchFor's for the choice); its list as
-- any other (the options' Bar color).
function Dropdown.Create(parent, opts)
  opts = type(opts) == "table" and opts or {}
  local swatchFor = type(opts.swatchFor) == "function" and opts.swatchFor or nil
  local sample = type(opts.sample) == "table" and opts.sample or nil
  local sampleFor = sample and type(opts.sampleFor) == "function" and opts.sampleFor or nil
  local onList = type(opts.onList) == "function" and opts.onList or nil
  local captions = type(opts.captions) == "table" and opts.captions or nil

  local Theme = Core.UI.Theme
  local items = type(opts.items) == "table" and opts.items or {}
  local rowHeight = tonumber(opts.rowHeight) or DEFAULT_ROW_HEIGHT
  local toggleWidth = tonumber(opts.toggleWidth) or DEFAULT_TOGGLE_WIDTH
  local listWidth = tonumber(opts.listWidth) or toggleWidth

  local container = CreateFrame("Frame", nil, parent)
  container:SetHeight(tonumber(opts.height) or DEFAULT_HEIGHT)

  -- Ids are mixed-type — Core/OptionsPanel.lua uses the string "auto" alongside
  -- integers — so identity comparison must never assume a type.
  if opts.defaultId ~= nil then
    container._selectedId = opts.defaultId
  elseif items[1] then
    container._selectedId = items[1].id
  end

  if opts.label then
    local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", container, "LEFT", 0, 0)
    label:SetText(opts.label)
    if Theme and Theme.BindFont then Theme.BindFont(label, "small") end
    container._label = label
  end

  -- Through the theme's button factory, so the select control is built from the
  -- same template as every other push button in the addon. It used to be the
  -- one UIPanelButtonTemplate here, which on a stock UI put a classic
  -- gold-bracket button beside the modern ones in the options panel and 2px
  -- from a flat plate tile in the recipient manager's sort group.
  local toggle
  if Theme and type(Theme.CreateButton) == "function" then
    toggle = Theme.CreateButton(opts.toggleName, container)
  else
    toggle = CreateFrame("Button", opts.toggleName, container, "UIPanelButtonTemplate")
  end
  toggle:SetSize(toggleWidth, tonumber(opts.toggleHeight) or DEFAULT_TOGGLE_HEIGHT)

  -- alignRight pins the toggle to the container's right edge instead of
  -- trailing the label. Without it a column of dropdowns is ragged, each toggle
  -- starting wherever its own label happens to end.
  if opts.alignRight then
    toggle:SetPoint("RIGHT", container, "RIGHT", 0, 0)
  elseif container._label then
    toggle:SetPoint("LEFT", container._label, "RIGHT", 6, 0)
  else
    toggle:SetPoint("LEFT", container, "LEFT", 0, 0)
  end

  -- Tagged so a host-UI skin treats it like the addon's other push buttons,
  -- and as a select where a style draws those differently (the Postbox style's
  -- caret and accent value).
  toggle.__postboxButton = true
  toggle.__postboxSelect = not sample
  container._toggle = toggle
  -- News to the skins' window walk (Core/Theme.lua, SkinGeneration).
  if ns.Theme and type(ns.Theme.SkinChanged) == "function" then ns.Theme.SkinChanged() end

  local function NameFor(id)
    for i = 1, #items do
      if items[i].id == id then return items[i].name end
    end
    -- Unknown default: show the first item rather than an empty toggle. The
    -- selection itself is left as given.
    return (items[1] and items[1].name) or ""
  end

  -- The art an item carries ({ texture= or atlas=, aspect= }, or { glyph= },
  -- one of the addon theme's glyphs), or nil.
  local function ArtOf(id)
    for i = 1, #items do
      local item = items[i]
      if item.id == id then return type(item.icon) == "table" and item.icon or nil end
    end
    return nil
  end

  -- The art's side: the list rows' own (BuildList).
  local artSize = rowHeight - 4

  -- An item's glyph ({ glyph = name }) as the addon theme has it, or nil.
  local function GlyphOf(spec)
    local glyphs = spec.glyph and ns.Theme and ns.Theme.GLYPHS
    return glyphs and glyphs[spec.glyph] or nil
  end

  -- The value's caption box: the toggle less a gutter at each end, the same
  -- at both, so a value that fits stands centred on the toggle exactly where
  -- it always stood -- clear of the colour square at the left, of the
  -- chosen item's art just before the value, and of a style's caret at the
  -- right. One line, never wrapped. A value too long
  -- for its box (a long translation, a large text size) widens the toggle
  -- where its owner has the room (FitWidth); only one that still does not
  -- fit is cut short by the house fitter (Theme.FitText) and says the whole
  -- of it on hover (ToggleEnter). A box of its own rather than a string
  -- sized to its text: that width is measured when the text is set and kept
  -- when a font object is changed under it, which wrapped a value's last
  -- letter onto a second line. Where the items carry art, the box leaves
  -- the art's room at both ends, so the longest value that fits still has
  -- its art whole on the toggle, and the value stays centred.
  local function Inset()
    local n = CAPTION_GUTTER
    if swatchFor then n = math.max(n, SWATCH_X + SWATCH_SIZE + SWATCH_GAP) end
    for i = 1, #items do
      if type(items[i].icon) == "table" then
        n = math.max(n, ART.X + artSize + ART.GAP)
        break
      end
    end
    return n
  end
  local inset = Inset()

  -- Items in faces of their own (FACE): the toggle's caption in the chosen
  -- one's, through the button's own fonts, since a button puts its state's
  -- font back on its label as it is enabled and pointed at. Its base is the
  -- button's own font as the skin left it (the select value); an item with
  -- no face, or a file that does not set, shows in that.
  local function Faced()
    for i = 1, #items do
      if items[i].face then return true end
    end
    return false
  end
  local faced = Faced()
  local valueBase, valueLit
  local function PaintFace()
    if not faced or type(toggle.GetNormalFontObject) ~= "function"
        or type(toggle.GetHighlightFontObject) ~= "function" then
      return
    end
    local label = toggle:GetFontString()
    if not label then return end
    local normal = toggle:GetNormalFontObject()
    local base = FACE.Base(normal)
    if base then
      valueBase = base
      valueLit = FACE.Base(toggle:GetHighlightFontObject()) or base
    end
    base = valueBase
    if not base then return end
    local path
    for i = 1, #items do
      if items[i].id == container._selectedId then path = items[i].face break end
    end
    local font = path and FACE.Object("value", path)
    local ok, changed = false, false
    if font then ok, changed = FACE.Dress(font, base) end
    local want = ok and font or base
    local lit = ok and font or valueLit
    if normal ~= want then toggle:SetNormalFontObject(want) end
    if toggle:GetHighlightFontObject() ~= lit then toggle:SetHighlightFontObject(lit) end
    -- A greyed toggle wears its disabled font, and takes the normal one
    -- back itself when it is enabled.
    if toggle:IsEnabled() then FACE.Wear(label, want, label:GetFontObject(), changed) end
  end

  -- The chosen item's art on the toggle, the list's art at the list's size,
  -- just before the value as it shows (its words centred, the art a gap to
  -- their left), on a holder frame of its own: a skin's repaint of the
  -- button fades the button's own textures, never a child's. One texture
  -- per toggle, made the first time a chosen item has art; a new choice
  -- sets its file only when the art is another, and builds nothing. Greyed
  -- with the toggle (ArtState).
  local art
  local function ArtState()
    if not art then return end
    local on = toggle:IsEnabled() and true or false
    if art.on == on then return end
    art.on = on
    art.Tex:SetDesaturated(not on)
    art:SetAlpha(on and 1 or 0.5)
  end
  local function PaintArt()
    local spec = ArtOf(container._selectedId)
    if not spec then
      if art then art:Hide() end
      return
    end
    if not art then
      art = CreateFrame("Frame", nil, toggle)
      art:SetFrameLevel((toggle:GetFrameLevel() or 1) + 2)
      art.Tex = art:CreateTexture(nil, "ARTWORK")
      art.Tex:SetAllPoints()
      toggle:HookScript("OnEnable", ArtState)
      toggle:HookScript("OnDisable", ArtState)
    end
    local label = toggle:GetFontString()
    if art.spec ~= spec then
      art.spec = spec
      local tex = art.Tex
      local g = GlyphOf(spec)
      if g then
        -- A glyph at its own size, so its whole pixels stay whole.
        tex:SetTexture(g.file)
        tex:SetTexCoord(g.l, g.r, g.t, g.b)
        if tex.SetSnapToPixelGrid then tex:SetSnapToPixelGrid(true) end
        if tex.SetTexelSnappingBias then tex:SetTexelSnappingBias(0) end
        art:SetSize(g.w, g.h)
      elseif spec.atlas then
        tex:SetAtlas(spec.atlas)
      else
        tex:SetTexture(spec.texture)
        tex:SetTexCoord(0, 1, 0, 1)
      end
      if not g then
        tex:SetVertexColor(1, 1, 1, 1)
        art:SetSize(artSize, artSize * (spec.aspect or 1))
      end
    end
    -- A glyph is white art: it wears the value's own ink.
    if spec.glyph and label and label.GetTextColor then art.Tex:SetVertexColor(label:GetTextColor()) end
    -- The value's words as they show: their whole width, or the box's
    -- where they were cut short to it.
    local w = 0
    if label then
      w = TextWidth(label)
      local box = label:GetWidth() or 0
      if box > 0 and w > box then w = box end
    end
    art:ClearAllPoints()
    art:SetPoint("RIGHT", label or toggle, "CENTER", -(math.floor(w / 2 + 0.5) + ART.GAP), 0)
    ArtState()
    art:Show()
  end

  local caption = ""   -- the value as given, whatever its box shows of it
  local function Caption(text)
    caption = text or ""
    if sample then
      toggle:SetText("")
      return
    end
    -- In the chosen item's face first, so it is fitted as it is drawn.
    PaintFace()
    local label = toggle:GetFontString()
    local fit = ns.Theme and ns.Theme.FitText
    if not label or type(fit) ~= "function" then
      toggle:SetText(caption)
      PaintArt()
      return
    end
    fit(label, math.max(1, (toggle:GetWidth() or 0) - 2 * inset), caption, toggle)
    PaintArt()
  end

  toggle:SetText(NameFor(container._selectedId))
  local label = toggle:GetFontString()
  if label then
    if label.SetWordWrap then label:SetWordWrap(false) end
    if label.SetMaxLines then label:SetMaxLines(1) end
  end
  Caption(NameFor(container._selectedId))
  -- A toggle given another width (the options panel narrows one beside a
  -- long name) fits its value to the new box.
  local function Refit() Caption(caption) end
  toggle.__pbRefit = Refit
  -- Faced, it is fitted again when the fonts it is made from move
  -- (Dropdown.RepaintFaces).
  container.__pbRefaces = Refit
  if faced then FACE.selects[container] = true end
  toggle:HookScript("OnSizeChanged", Refit)
  toggle:HookScript("OnEnter", ToggleEnter)
  toggle:HookScript("OnLeave", ToggleLeave)

  -- The toggle's width that shows every value whole: the width the owner
  -- asked for (opts.toggleWidth), the normal case, unless a value -- each
  -- measured on the toggle's own caption, in the face, size and outline it
  -- wears now -- runs past that width's box; then the widest one's width
  -- and the box's gutters, so that one select alone is wider. The owner
  -- sets it, beside whatever else its layout holds (the options' rows,
  -- Rows.Fit; the recipient manager's sort), when the face is known and
  -- again when it moves; what cannot be given room is still cut short and
  -- said whole on hover (Caption). Measuring sets each value on the caption
  -- and puts back what it showed, so the answer is kept until the face or
  -- the scale moves or the select is given other items (SetItems: a list is
  -- kept per items table the same way); a font still loading measures
  -- nothing and is not kept.
  local fitW, fitValues, fitPath, fitSize, fitFlags, fitShadow, fitScale
  function container:FitWidth()
    if sample then return toggleWidth end
    local label = toggle:GetFontString()
    if not label or type(label.GetFont) ~= "function" then return toggleWidth end
    local values = captions or items
    local path, size, flags = label:GetFont()
    local shadow = label.GetShadowOffset and label:GetShadowOffset() or 0
    local scale = label:GetEffectiveScale()
    if fitW and fitValues == values and fitPath == path and fitSize == size and fitFlags == flags
        and fitShadow == shadow and fitScale == scale then
      return fitW
    end
    local shown = label:GetText()
    local widest = 0
    for i = 1, #values do
      local value = values[i]
      -- A heading is never the value: the list shows it, the toggle never.
      if type(value) == "table" then value = (not value.heading) and value.name or nil end
      if value then
        label:SetText(value)
        local w = TextWidth(label)
        if w > widest then widest = w end
      end
    end
    label:SetText(shown)
    -- The art beside the value as this face draws it.
    PaintArt()
    local width = toggleWidth
    if widest > width - 2 * inset then width = math.ceil(widest) + 2 * inset end
    if widest > 0 then
      fitW, fitValues, fitPath, fitSize, fitFlags, fitShadow, fitScale = width, values, path, size, flags, shadow, scale
    end
    return width
  end

  -- The chosen colour on the toggle, at its left, where the list has them.
  local toggleSwatch
  if sample then
    toggleSwatch = NewSwatch(toggle, tonumber(sample.w) or SWATCH_SIZE)
    toggleSwatch:SetSize(tonumber(sample.w) or SWATCH_SIZE, tonumber(sample.h) or SWATCH_SIZE)
    toggleSwatch:SetPoint("CENTER", toggle, "CENTER", 0, 0)
    -- Greyed with the button: the sample at half strength.
    local function SampleState() toggleSwatch:SetAlpha(toggle:IsEnabled() and 1 or 0.5) end
    toggle:HookScript("OnEnable", SampleState)
    toggle:HookScript("OnDisable", SampleState)
  elseif swatchFor then
    toggleSwatch = NewSwatch(toggle, SWATCH_SIZE, true)
    toggleSwatch:SetPoint("LEFT", toggle, "LEFT", SWATCH_X, 0)
  end
  local function PaintToggleSwatch()
    if not toggleSwatch then return end
    if sampleFor then
      PaintSwatch(toggleSwatch, sampleFor(container._selectedId))
    elseif swatchFor then
      PaintSwatch(toggleSwatch, swatchFor(container._selectedId))
    end
  end
  PaintToggleSwatch()

  local list  -- built on first open

  -- The owner hears each change once, whichever of the ways a list closes
  -- runs first.
  local told = false
  local function Tell(open)
    if told == open then return end
    told = open
    if onList then onList(container, open) end
  end

  local function ListHidden()
    Watch()
    Tell(false)
  end

  local function BuildList()
    if list then return list end

    local colors = (Theme and Theme.MenuColors) or nil
    local hover = colors and colors.hover or { 0.90, 0.78, 0.30, 0.18 }

    local contentHeight = #items * rowHeight
    local maxHeight = tonumber(opts.maxListHeight) or DEFAULT_MAX_LIST_HEIGHT
    local scrolling = (LIST_PADDING * 2) + contentHeight > maxHeight
    local viewport = maxHeight - (LIST_PADDING * 2)

    list = CreateFrame("Frame", nil, toggle, "BackdropTemplate")
    -- Placed on each open (PlaceList). Kept on the screen whatever else.
    list:SetClampedToScreen(true)
    list:SetWidth(listWidth)
    list:SetHeight(scrolling and maxHeight or ((LIST_PADDING * 2) + contentHeight))
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    -- The whole card takes the pointer, not only its rows: its padding and
    -- its edges let the pointer through to the row under them, which then
    -- answered as if nothing covered it.
    list:EnableMouse(true)
    list._toggle = toggle

    -- The list is a popup, and the addon has one popup surface: the same card
    -- the contact picker and the type-ahead list wear. Going through the
    -- addon's surface entry point rather than hand-rolling a backdrop is what
    -- gets it the shared fill, border and stone grain on a stock UI *and* the
    -- `__postboxPanel` tag both host-UI skins walk for -- without which this is
    -- the one Postbox-coloured panel left inside an otherwise host-styled
    -- window. Resolved at first open, not at load: this file is foundation and
    -- loads before the addon theme.
    --
    -- __pbPopupAlways: the strata heuristic behind the popup opacity floor
    -- cannot see that this is a popup when the OWNING window already sits at
    -- FULLSCREEN_DIALOG (the options panel), which left this one list as
    -- see-through as the window. Declare it instead of hoping.
    list.__pbPopupAlways = true
    local surface = ns.Theme and ns.Theme.ApplyCard
    if type(surface) == "function" then
      surface(list)
    else
      -- No addon theme (foundation used on its own): a solid white 8x8 tinted
      -- by the menu palette, with a 1px edge.
      local fill = colors and colors.fill or { 0.05, 0.05, 0.06, 1 }
      local border = colors and colors.border or { 0.46, 0.36, 0.24, 0.55 }
      list:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
      list:SetBackdropColor(fill[1], fill[2], fill[3], fill[4])
      list:SetBackdropBorderColor(border[1], border[2], border[3], border[4])
      list.__postboxPanel = "card"
    end
    list:Hide()

    -- Long lists scroll inside a fixed height rather than running off the
    -- screen: rows go on a scroll child, and a hairline track with a light
    -- draggable thumb carries the position. Deliberately minimal -- no
    -- buttons, no Blizzard scroll templates.
    local rowParent = list
    if scrolling then
      local scroll = CreateFrame("ScrollFrame", nil, list)
      scroll:SetPoint("TOPLEFT", list, "TOPLEFT", LIST_PADDING, -LIST_PADDING)
      scroll:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT",
        -(LIST_PADDING + SCROLLBAR_INSET + 4), LIST_PADDING)

      local content = CreateFrame("Frame", nil, scroll)
      content:SetSize(1, contentHeight)
      scroll:SetScrollChild(content)
      scroll:SetScript("OnSizeChanged", function(_, width)
        content:SetWidth(width or 1)
      end)

      -- The track rides a child frame, not the list itself: the list is a
      -- tagged panel, and a host skin's repaint fades every texture region
      -- the panel owns directly (the thumb survives for exactly this reason
      -- -- its art lives on the thumb frame).
      local trackHolder = CreateFrame("Frame", nil, list)
      trackHolder:SetWidth(3)
      trackHolder:SetPoint("TOPRIGHT", list, "TOPRIGHT", -SCROLLBAR_INSET, -LIST_PADDING)
      trackHolder:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -SCROLLBAR_INSET, LIST_PADDING)
      local track = trackHolder:CreateTexture(nil, "ARTWORK")
      track:SetAllPoints()
      -- The chrome ink: white on a dark palette, dark on a light one.
      local themed = ns.Theme
      if themed and type(themed.FillChrome) == "function" then
        themed.FillChrome(track, 0.08)
      else
        track:SetColorTexture(1, 1, 1, 0.08)
      end

      local span = contentHeight - viewport
      local thumbHeight = math.max(20, viewport * viewport / contentHeight)
      local thumb = CreateFrame("Frame", nil, list)
      thumb:SetSize(3, thumbHeight)
      thumb:EnableMouse(true)
      local thumbArt = thumb:CreateTexture(nil, "OVERLAY")
      thumbArt:SetAllPoints()
      if themed and type(themed.FillChrome) == "function" then
        themed.FillChrome(thumbArt, 0.35)
      else
        thumbArt:SetColorTexture(1, 1, 1, 0.35)
      end

      local function SetOffset(offset)
        offset = math.max(0, math.min(span, offset))
        scroll:SetVerticalScroll(offset)
        local travel = viewport - thumbHeight
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPRIGHT", list, "TOPRIGHT", -SCROLLBAR_INSET,
          -LIST_PADDING - (span > 0 and (offset / span) * travel or 0))
      end
      SetOffset(0)
      list._setOffset = SetOffset
      list._viewport = viewport
      list._scroll = scroll
      list._content = content

      local function OnWheel(_, delta)
        SetOffset(scroll:GetVerticalScroll() - delta * rowHeight * 3)
      end
      list:EnableMouseWheel(true)
      list:SetScript("OnMouseWheel", OnWheel)
      scroll:EnableMouseWheel(true)
      scroll:SetScript("OnMouseWheel", OnWheel)

      thumb:SetScript("OnMouseDown", function(self)
        local scale = self:GetEffectiveScale()
        local _, startY = GetCursorPosition()
        local startOffset = scroll:GetVerticalScroll()
        local travel = viewport - thumbHeight
        self:SetScript("OnUpdate", function()
          if travel <= 0 then return end
          local _, cursorY = GetCursorPosition()
          SetOffset(startOffset + ((startY - cursorY) / scale) * (span / travel))
        end)
      end)
      thumb:SetScript("OnMouseUp", function(self)
        self:SetScript("OnUpdate", nil)
      end)
      -- A list closed mid-drag never sees the mouse come up: the drag ends
      -- with it, or it would resume following the cursor at the next open.
      thumb:SetScript("OnHide", function(self)
        self:SetScript("OnUpdate", nil)
      end)

      rowParent = content
    end

    list._rows = {}
    for i = 1, #items do
      local item = items[i]

      -- A heading ({ heading = true, name = }): the name of the group of
      -- items under it, quiet and at the list's own edge, where the
      -- choices stand a gutter in. Not a choice: no wash, no click, no mark.
      if item.heading then
        local head = CreateFrame("Frame", nil, rowParent)
        head:SetHeight(rowHeight)
        if scrolling then
          head:SetPoint("TOPLEFT", rowParent, "TOPLEFT", 0, -((i - 1) * rowHeight))
          head:SetPoint("RIGHT", rowParent, "RIGHT", 0, 0)
        else
          head:SetPoint("TOPLEFT", rowParent, "TOPLEFT", LIST_PADDING, -LIST_PADDING - ((i - 1) * rowHeight))
          head:SetPoint("RIGHT", rowParent, "RIGHT", -LIST_PADDING, 0)
        end
        local text = head:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        text:SetPoint("LEFT", head, "LEFT", LIST_PADDING, 0)
        text:SetPoint("RIGHT", head, "RIGHT", -LIST_PADDING, 0)
        text:SetJustifyH("LEFT")
        text:SetWordWrap(false)
        text:SetText(item.name)
        if Theme and Theme.BindFont then Theme.BindFont(text, "small") end
        local themed = ns.Theme
        if themed and type(themed.SetColor) == "function" then
          themed.SetColor(text, "textSecondary")
        else
          text:SetTextColor(0.6, 0.6, 0.6)
        end
        head.Text, head._heading, head._textX = text, true, LIST_PADDING
        list._rows[#list._rows + 1] = head
      else
        local row = CreateFrame("Button", nil, rowParent)
        row:SetHeight(rowHeight)
        row._itemId = item.id
        list._rows[#list._rows + 1] = row
        if scrolling then
          row:SetPoint("TOPLEFT", rowParent, "TOPLEFT", 0, -((i - 1) * rowHeight))
          row:SetPoint("RIGHT", rowParent, "RIGHT", 0, 0)
        else
          row:SetPoint("TOPLEFT", rowParent, "TOPLEFT", LIST_PADDING, -LIST_PADDING - ((i - 1) * rowHeight))
          row:SetPoint("RIGHT", rowParent, "RIGHT", -LIST_PADDING, 0)
        end

        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0)

        -- An item may carry its own art: { texture= or atlas=, aspect= }.
        -- Drawn at row height beside the caption, so a list of visual choices
        -- shows the choices. Everything sits one gutter in (MARK_GUTTER) --
        -- on EVERY row, so the captions of chosen and unchosen items line up.
        local textOffset = LIST_PADDING + MARK_GUTTER
        if type(item.icon) == "table" then
          local size = rowHeight - 4
          local g = GlyphOf(item.icon)
          if g then
            -- A glyph at its own size, centred in the art's square, in the
            -- caption's ink (painted on each open).
            local art = ns.Theme.Glyph(row, item.icon.glyph, nil, "ARTWORK")
            art:SetPoint("CENTER", row, "LEFT", LIST_PADDING + MARK_GUTTER + size / 2, 0)
            row._glyph = art
          elseif item.icon.glyph then
            size = 0
          else
            local art = row:CreateTexture(nil, "ARTWORK")
            art:SetSize(size, size * (item.icon.aspect or 1))
            art:SetPoint("LEFT", row, "LEFT", LIST_PADDING + MARK_GUTTER, 0)
            if item.icon.atlas then
              art:SetAtlas(item.icon.atlas)
            else
              art:SetTexture(item.icon.texture)
            end
          end
          textOffset = LIST_PADDING + MARK_GUTTER + size + 6
        elseif swatchFor then
          local size = rowHeight - 10
          local sw = NewSwatch(row, size, true)
          sw:SetPoint("LEFT", row, "LEFT", LIST_PADDING + MARK_GUTTER, 0)
          row._swatch = sw
          textOffset = LIST_PADDING + MARK_GUTTER + size + 6
        end

        local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("LEFT", row, "LEFT", textOffset, 0)
        text:SetText(item.name)
        if Theme and Theme.BindFont then Theme.BindFont(text, "small") end
        -- The named font the words were given, for FontInk where they
        -- answer none of their own later.
        row._font = ns.Theme and type(ns.Theme.NamedFont) == "function"
          and ns.Theme.NamedFont(text:GetFontObject()) or nil

        -- The current selection's mark (ChosenArt), painted on open: the
        -- choice in effect, even when the toggle's caption does not repeat
        -- it (an owner may keep a fixed title there instead). Its bar
        -- stands on a washed row, the list's padding clear of the card's
        -- edge, so it reads as a mark and never as the card's border.
        ChosenArt(row)

        row:SetScript("OnEnter", function()
          if item.off then return end
          bg:SetColorTexture(hover[1], hover[2], hover[3], hover[4])
        end)
        row:SetScript("OnLeave", function()
          bg:SetColorTexture(0, 0, 0, 0)
        end)
        row._item, row._text, row._textX = item, text, textOffset
        row:SetScript("OnClick", function()
          -- A choice its owner has set aside for now (item.off): drawn
          -- faint on each open, and a click on it changes nothing.
          if item.off then return end
          container._selectedId = item.id
          Caption(item.name)
          PaintToggleSwatch()
          list:Hide()
          if container._onChange then container._onChange(item.id, item.name) end
        end)
      end
    end

    list:SetScript("OnHide", ListHidden)
    lists[list] = true
    return list
  end

  -- Under the toggle's right edge by default, growing leftwards: the options
  -- panel's toggles sit at the right of their rows. opts.listLeft is for a
  -- toggle at a window's LEFT edge, whose list would otherwise hang off the
  -- window. Above the toggle instead when the room under it is too short
  -- for the list and the room over it is longer: a toggle near the foot of
  -- the screen (a large window scale, a low window).
  local function PlaceList()
    local up = false
    local bottom, top = toggle:GetBottom(), toggle:GetTop()
    local height = list:GetHeight() or 0
    if bottom and top and UIParent then
      -- Both rooms in the toggle's own units, like the list's height.
      local own = toggle:GetEffectiveScale() or 1
      local screenTop = (UIParent:GetTop() or 0) * (UIParent:GetEffectiveScale() or 1) / own
      local below, above = bottom - LIST_GAP, screenTop - top - LIST_GAP
      up = below < height and above > below
    end
    list:ClearAllPoints()
    if up then
      if opts.listLeft then
        list:SetPoint("BOTTOMLEFT", toggle, "TOPLEFT", 0, LIST_GAP)
      else
        list:SetPoint("BOTTOMRIGHT", toggle, "TOPRIGHT", 0, LIST_GAP)
      end
    elseif opts.listLeft then
      list:SetPoint("TOPLEFT", toggle, "BOTTOMLEFT", 0, -LIST_GAP)
    else
      list:SetPoint("TOPRIGHT", toggle, "BOTTOMRIGHT", 0, -LIST_GAP)
    end
  end

  -- The list's width that shows every item's words whole, in the face they
  -- wear now: each row's words from where they start in it (`_textX`, the
  -- gutter and any art or colour before them) and a pad after, inside
  -- the list's own padding, and the scroll bar's room where it scrolls.
  -- Measured on each open; nothing is made.
  local function ListNeed()
    local rows = list._rows
    if not rows then return 0 end
    local widest = 0
    for i = 1, #rows do
      local row = rows[i]
      local text = row._text or row.Text
      if text then
        local w = (row._textX or 0) + TextWidth(text) + LIST_PADDING
        if w > widest then widest = w end
      end
    end
    local right = list._scroll and (LIST_PADDING + SCROLLBAR_INSET + 4) or LIST_PADDING
    return math.ceil(LIST_PADDING + widest + right)
  end

  local function CloseList()
    if list and list:IsShown() then list:Hide() end
    -- Unconditional: hiding the owning window fires OnHide on its children too,
    -- and the order of those is not guaranteed.
    Watch()
    Tell(false)
  end

  local function OpenList()
    local built = not list
    BuildList()
    Dropdown.CloseAll(list)

    -- The list is built lazily on first open, so it misses the skin pass the
    -- owning window had. Hand it over now -- from the container, because both
    -- skins walk a frame's CHILDREN, and the list is a child of the toggle.
    if built and ns.Skin and ns.Skin.Refresh then
      pcall(ns.Skin.Refresh, container)
      -- And the list itself, to a style that dresses popups of its own.
      if type(ns.Skin.DressPopup) == "function" then pcall(ns.Skin.DressPopup, list) end
    end
    -- Each row with a face of its own in it, before the list is measured.
    if faced then FACE.PaintRows(list) end

    local owner = container:GetParent()
    local base = (owner and owner:GetFrameLevel()) or 0
    local level = base + LIST_LEVEL_OFFSET

    -- Never narrower than the toggle it hangs from: a toggle widened for its
    -- widest value (FitWidth) takes its list with it. And never narrower
    -- than its widest item as it measures now (ListNeed): a select kept at
    -- its column's width (the options' dropdowns) cuts a long value short
    -- on the toggle, never in its list, which opens wider instead.
    local width = math.max(listWidth, toggle:GetWidth() or 0, ListNeed())
    if list:GetWidth() ~= width then list:SetWidth(width) end
    list:SetFrameLevel(level)
    PlaceList()
    list:Show()
    list:Raise()
    Watch()
    Tell(true)

    -- Paint the selection mark for THIS open: selection may have changed
    -- since the last one, and the accent is resolved live (PaintChosen).
    -- A row's glyph wears its words' ink, the chosen one's accent with them.
    if list._rows then
      for i = 1, #list._rows do
        local row = list._rows[i]
        if row._selWash then PaintChosen(row, row._text, row._itemId == container._selectedId) end
        if row._swatch then PaintSwatch(row._swatch, swatchFor(row._itemId)) end
        if row._glyph and row._text then row._glyph:SetVertexColor(row._text:GetTextColor()) end
        -- A choice set aside (item.off, the owner's to set): faint, at
        -- half strength, whatever ink a skin gave it.
        local item = row._item
        if item and row._text then
          local off = item.off and true or false
          if row._off ~= off then
            row._off = off
            row._text:SetAlpha(off and 0.4 or 1)
          end
        end
      end
    end

    -- A scrolling list opens with the current selection in view rather than
    -- at the top of a long ride down. Width is re-asserted here because the
    -- scroll child's is derived, and the first OnSizeChanged can land before
    -- the list has real geometry.
    if list._setOffset then
      if list._content and list._scroll then
        list._content:SetWidth(list._scroll:GetWidth())
      end
      local index
      for i = 1, #items do
        if items[i].id == container._selectedId then index = i break end
      end
      if index then
        local rowHeightUsed = rowHeight
        list._setOffset(((index - 1) * rowHeightUsed) - (list._viewport - rowHeightUsed) / 2)
      end
    end
  end

  toggle:SetScript("OnClick", function()
    if list and list:IsShown() then
      CloseList()
    else
      OpenList()
    end
  end)

  -- An options panel closed with Escape would otherwise leave an orphaned list
  -- panel visible at fullscreen-dialog strata. Hiding a parent fires OnHide on
  -- its children, so this covers the whole owning window going away too.
  container:HookScript("OnHide", CloseList)

  -- Sets the selection and the visible label together.
  function container:SetSelectedId(id)
    container._selectedId = id
    Caption(NameFor(id))
    PaintToggleSwatch()
  end

  -- The toggle's colour square again, from swatchFor: the colours moved.
  function container:PaintSwatch()
    PaintToggleSwatch()
  end

  -- Sets the toggle's visible label only, without changing the selection: an
  -- external source of truth re-syncing itself into the widget.
  function container:SetText(text)
    Caption(text)
  end

  function container:SetChangeCallback(fn)
    container._onChange = fn
  end

  -- Another list of items, live: the options' Background color, whose
  -- choices are the Mode's. An open list closes; the next open shows the new
  -- items. The list built for each item table is kept beside it (built on
  -- its first open, as ever), so going back to a list builds nothing again
  -- -- the select holds as many lists as it was given tables, never one per
  -- change. The selection is the caller's to set (SetSelectedId), and the
  -- value is fitted again in its box, from the new items.
  local built
  function container:SetItems(newItems)
    if type(newItems) ~= "table" or newItems == items then return end
    CloseList()
    built = built or {}
    if list then built[items] = list end
    items = newItems
    list = built[newItems]
    inset = Inset()
    faced = Faced()
    if faced then FACE.selects[container] = true end
    Caption(NameFor(container._selectedId))
    PaintToggleSwatch()
  end

  return container
end

-- A menu of actions that opens from a button of the owner's (the options'
-- Reset to defaults): the select's list without a value -- the same card,
-- rows, wash and type, no selection mark -- that closes on a pick, on a press
-- anywhere else, or with its window. items: { id, name } each; opts:
-- onPick(id), onEnter(row, item) and onLeave(row, item) for a row's tooltip,
-- onOpen() each time it opens, onClose() however it closed, minWidth. Built
-- on first open; each open fits it to its captions as they measure now and
-- puts it under the button, over it only where the screen has no room
-- under it. -> the menu: :Toggle(), :Close(), :IsShown().
-- A menu of choices (the Mail tab's sort and filter) adds to that: an item
-- { heading = true, name = } names the group under it, as a select's list
-- has them, and a heading after the first item has a hairline over it;
-- opts.checked(id) -> whether that choice is the one in effect, marked with
-- the select's mark (ChosenArt) on each open and after each pick;
-- opts.keepOpen, a pick leaves the menu open with its marks painted again (a menu of two groups is
-- set twice). Every menu opens the one way, outward: its left edge on the
-- button's, out past the window's edge where it must, the screen keeping
-- it whole (it is clamped to the screen, which shifts it in rather than
-- flipping it). :Repaint() paints the marks
-- again while it is open (the choices changed under it). An item with
-- `rule` has a hairline over it; opts.disabled(id) -> a row drawn faint
-- whose click does nothing, asked with the marks.
-- A choice that runs two ways (the sort menus' orders): an item with
-- `flip`, its words the other way round ("Oldest first" to "Newest
-- first"); opts.flipped(id) -> whether it reads them now, asked with the
-- marks. While it is the choice in effect it carries the turn mark at its
-- right end -- the house caret (Theme.GLYPHS "caret"), pointing down the
-- way its `name` runs and up the way its `flip` does, turned as it changes
-- (Theme.TurnGlyph) -- so it is plain that another click turns it round.
-- The menu is as wide as the longer words of each.
local FLIP = { SIZE = 5, X = 8, ROOM = 12 }

-- An action, not a choice (the sort menus' Reset): an item with `action`,
-- drawn in the menu's foot as a quiet full-width button -- an inset plate
-- of its own, its words centred with the house glyph `item.glyph` (a
-- Theme.GLYPHS name) before them -- never the chosen mark, never a tick.
-- Live, its plate's outline and wash stand in the chrome's ink and its
-- words and glyph in the body text's, and the pointer lights it further;
-- at rest (opts.disabled) the outline is faint, the words and glyph the
-- disabled grey, and the pointer lights nothing -- colour and strength
-- change together, so it reads at any window opacity. Its click, pointer
-- and tooltip hooks are any row's. Taller than a row by its plate's
-- margins (H); its plate is SIDE in from the rows' edges, TOP under the
-- hairline over it and BOTTOM over the menu's padding.
local ACTION = { H = 26, SIDE = 2, TOP = 5, BOTTOM = 1, GLYPH = 12, GAP = 4 }

function ACTION.Paint(row)
  local themed = ns.Theme
  local off = row._off and true or false
  local hot = row._hover and not off
  local edgeA = off and 0.10 or (hot and 0.45 or 0.28)
  local fillA = off and 0.02 or (hot and 0.14 or 0.07)
  local chrome = themed and type(themed.FillChrome) == "function"
  for k = 1, #row._edges do
    if chrome then themed.FillChrome(row._edges[k], edgeA) else row._edges[k]:SetColorTexture(1, 1, 1, edgeA) end
  end
  if chrome then themed.FillChrome(row._fill, fillA) else row._fill:SetColorTexture(1, 1, 1, fillA) end
  if themed and type(themed.SetColor) == "function" then
    local token = off and "textDisabled" or "textPrimary"
    themed.SetColor(row.Text, token)
    if row._glyph then themed.SetColor(row._glyph, token) end
  else
    local v = off and 0.5 or 1
    row.Text:SetTextColor(v, v, v)
    if row._glyph then row._glyph:SetVertexColor(v, v, v) end
  end
end

-- The row at `y` under the list's top, and its plate: a wash and four
-- hairlines, each one unit, the sides between the top and bottom so no
-- corner is drawn twice. The caller gives it its click.
function ACTION.Build(list, item, y, opts)
  local themed = ns.Theme
  local Theme = Core.UI.Theme
  local row = CreateFrame("Button", nil, list)
  row:SetHeight(ACTION.H)
  row:SetPoint("TOPLEFT", list, "TOPLEFT", LIST_PADDING, -y)
  row:SetPoint("RIGHT", list, "RIGHT", -LIST_PADDING, 0)
  row.item = item
  if item.rule then
    local rule = row:CreateTexture(nil, "ARTWORK")
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    rule:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    if themed and type(themed.FillChrome) == "function" then
      themed.FillChrome(rule, 0.12)
    else
      rule:SetColorTexture(1, 1, 1, 0.12)
    end
  end
  local fill = row:CreateTexture(nil, "BACKGROUND")
  fill:SetPoint("TOPLEFT", row, "TOPLEFT", ACTION.SIDE, -ACTION.TOP)
  fill:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -ACTION.SIDE, ACTION.BOTTOM)
  local top, bottom, left, right = row:CreateTexture(nil, "BORDER"), row:CreateTexture(nil, "BORDER"),
    row:CreateTexture(nil, "BORDER"), row:CreateTexture(nil, "BORDER")
  top:SetHeight(1)
  top:SetPoint("TOPLEFT", fill, "TOPLEFT", 0, 0)
  top:SetPoint("TOPRIGHT", fill, "TOPRIGHT", 0, 0)
  bottom:SetHeight(1)
  bottom:SetPoint("BOTTOMLEFT", fill, "BOTTOMLEFT", 0, 0)
  bottom:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT", 0, 0)
  left:SetWidth(1)
  left:SetPoint("TOPLEFT", fill, "TOPLEFT", 0, -1)
  left:SetPoint("BOTTOMLEFT", fill, "BOTTOMLEFT", 0, 1)
  right:SetWidth(1)
  right:SetPoint("TOPRIGHT", fill, "TOPRIGHT", 0, -1)
  right:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT", 0, 1)
  local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  text:SetWordWrap(false)
  text:SetText(item.name)
  if Theme and Theme.BindFont then Theme.BindFont(text, "small") end
  local glyph = item.glyph and themed and type(themed.Glyph) == "function"
    and themed.Glyph(row, item.glyph, ACTION.GLYPH, "OVERLAY") or nil
  -- The glyph and the words centred together on the plate.
  text:SetPoint("CENTER", fill, "CENTER", glyph and (ACTION.GLYPH + ACTION.GAP) / 2 or 0, 0)
  if glyph then glyph:SetPoint("RIGHT", text, "LEFT", -ACTION.GAP, 0) end
  row.Text, row._fill, row._glyph = text, fill, glyph
  row._edges = { top, bottom, left, right }
  row._paintAction = ACTION.Paint
  row:SetScript("OnEnter", function(self)
    self._hover = true
    ACTION.Paint(self)
    if opts.onEnter then opts.onEnter(self, self.item) end
  end)
  row:SetScript("OnLeave", function(self)
    self._hover = false
    ACTION.Paint(self)
    if opts.onLeave then opts.onLeave(self, self.item) end
  end)
  ACTION.Paint(row)
  return row
end

function Dropdown.Menu(owner, items, opts)
  opts = type(opts) == "table" and opts or {}
  items = type(items) == "table" and items or {}
  local menu = {}
  local list, rows
  local checked = type(opts.checked) == "function" and opts.checked or nil
  local disabled = type(opts.disabled) == "function" and opts.disabled or nil
  local flipped = type(opts.flipped) == "function" and opts.flipped or nil

  -- A two-way row's words and its turn mark, as the choice stands now. A
  -- mark is turned while out of sight where `still` (the menu opening), so
  -- it never spins as the menu appears; a click on a shown one turns it.
  local function PaintTurn(row, on, still)
    local item, mark = row.item, row._turn
    local back = flipped and flipped(item.id) and true or false
    local words = back and item.flip or item.name
    if row.Text:GetText() ~= words then row.Text:SetText(words) end
    if not mark then return end
    local themed = ns.Theme
    if not on or still then mark:Hide() end
    if themed and type(themed.TurnGlyph) == "function" then themed.TurnGlyph(mark, not back) end
    if on then
      if themed and type(themed.SetColor) == "function" then themed.SetColor(mark, "accentBright") end
      mark:Show()
    end
  end

  -- The chosen rows' mark, as the select's (PaintChosen); and a row its
  -- owner has set aside for now, faint (as a select's `off` item is).
  local function PaintMarks(still)
    if not rows then return end
    for i = 1, #rows do
      local row = rows[i]
      if row._paintAction then
        -- An action row: live or at rest in its own look (ACTION.Paint).
        row._off = disabled and disabled(row.item.id) and true or false
        row._paintAction(row)
      elseif disabled and row.item.id ~= nil and not row.item.heading then
        local off = disabled(row.item.id) and true or false
        row._off = off
        row.Text:SetAlpha(off and 0.4 or 1)
      end
    end
    if not checked then return end
    for i = 1, #rows do
      local row = rows[i]
      if row._selWash then
        local on = checked(row.item.id) and true or false
        if row.item.flip then PaintTurn(row, on, still) end
        PaintChosen(row, row.Text, on)
      end
    end
  end

  local function Build()
    local Theme = Core.UI.Theme
    local colors = (Theme and Theme.MenuColors) or nil
    local hover = colors and colors.hover or { 0.90, 0.78, 0.30, 0.18 }
    list = CreateFrame("Frame", nil, owner, "BackdropTemplate")
    list:SetClampedToScreen(true)
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    list:EnableMouse(true)
    list._toggle = owner
    list.__pbPopupAlways = true
    local surface = ns.Theme and ns.Theme.ApplyCard
    if type(surface) == "function" then
      surface(list)
    else
      local fill = colors and colors.fill or { 0.05, 0.05, 0.06, 1 }
      local border = colors and colors.border or { 0.46, 0.36, 0.24, 0.55 }
      list:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
      list:SetBackdropColor(fill[1], fill[2], fill[3], fill[4])
      list:SetBackdropBorderColor(border[1], border[2], border[3], border[4])
      list.__postboxPanel = "card"
    end
    list:Hide()
    rows = {}
    -- Each row under the last: an action row is taller (ACTION.H).
    local y = LIST_PADDING
    for i = 1, #items do
      local item = items[i]
      -- A heading: the group's name, quiet, at the rows' edge, as a
      -- select's list draws one (Dropdown.Create); no wash, no click. A
      -- hairline over it where a group stands above.
      if item.action then
        local row = ACTION.Build(list, item, y, opts)
        -- A click as any row's: nothing while at rest, else the pick.
        row:SetScript("OnClick", function(self)
          if self._off then return end
          if not opts.keepOpen then list:Hide() end
          if opts.onPick then opts.onPick(self.item.id) end
          if opts.keepOpen and list:IsShown() then PaintMarks() end
        end)
        rows[i] = row
        y = y + ACTION.H
      elseif item.heading then
        local head = CreateFrame("Frame", nil, list)
        head:SetHeight(DEFAULT_ROW_HEIGHT)
        head:SetPoint("TOPLEFT", list, "TOPLEFT", LIST_PADDING, -y)
        head:SetPoint("RIGHT", list, "RIGHT", -LIST_PADDING, 0)
        local text = head:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        text:SetPoint("LEFT", head, "LEFT", LIST_PADDING, 0)
        text:SetWordWrap(false)
        text:SetText(item.name)
        if Theme and Theme.BindFont then Theme.BindFont(text, "small") end
        local themed = ns.Theme
        if themed and type(themed.SetColor) == "function" then
          themed.SetColor(text, "textSecondary")
        else
          text:SetTextColor(0.6, 0.6, 0.6)
        end
        if i > 1 then
          local rule = head:CreateTexture(nil, "ARTWORK")
          rule:SetHeight(1)
          rule:SetPoint("TOPLEFT", head, "TOPLEFT", 0, 0)
          rule:SetPoint("TOPRIGHT", head, "TOPRIGHT", 0, 0)
          if themed and type(themed.FillChrome) == "function" then
            themed.FillChrome(rule, 0.12)
          else
            rule:SetColorTexture(1, 1, 1, 0.12)
          end
        end
        -- Measured with the rows (Place): its words from the rows' edge.
        head.Text, head.item, head._textX = text, item, LIST_PADDING
        rows[i] = head
        y = y + DEFAULT_ROW_HEIGHT
      else
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(DEFAULT_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", LIST_PADDING, -y)
        row:SetPoint("RIGHT", list, "RIGHT", -LIST_PADDING, 0)
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0)
        local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("LEFT", row, "LEFT", LIST_PADDING + MARK_GUTTER, 0)
        text:SetWordWrap(false)
        text:SetText(item.name)
        if Theme and Theme.BindFont then Theme.BindFont(text, "small") end
        row.Text, row.item = text, item
        row._font = ns.Theme and type(ns.Theme.NamedFont) == "function"
          and ns.Theme.NamedFont(text:GetFontObject()) or nil
        if item.rule then
          local rule = row:CreateTexture(nil, "ARTWORK")
          rule:SetHeight(1)
          rule:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
          rule:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
          local themed = ns.Theme
          if themed and type(themed.FillChrome) == "function" then
            themed.FillChrome(rule, 0.12)
          else
            rule:SetColorTexture(1, 1, 1, 0.12)
          end
        end
        -- The choice in effect, where the menu has one: the select's mark.
        if checked then ChosenArt(row) end
        -- A two-way choice's turn mark, shown while it is the one in effect.
        local themed = ns.Theme
        if item.flip and themed and type(themed.Glyph) == "function" then
          local mark = themed.Glyph(row, "caret", FLIP.SIZE, "OVERLAY")
          if mark then
            mark:SetPoint("CENTER", row, "RIGHT", -FLIP.X, 0)
            mark:Hide()
            row._turn = mark
          end
        end
        row:SetScript("OnEnter", function(self)
          if not self._off then bg:SetColorTexture(hover[1], hover[2], hover[3], hover[4]) end
          if opts.onEnter then opts.onEnter(self, self.item) end
        end)
        row:SetScript("OnLeave", function(self)
          bg:SetColorTexture(0, 0, 0, 0)
          if opts.onLeave then opts.onLeave(self, self.item) end
        end)
        row:SetScript("OnClick", function(self)
          if self._off then return end
          if not opts.keepOpen then list:Hide() end
          if opts.onPick then opts.onPick(self.item.id) end
          if opts.keepOpen and list:IsShown() then PaintMarks() end
        end)
        rows[i] = row
        y = y + DEFAULT_ROW_HEIGHT
      end
    end
    list:SetHeight(y + LIST_PADDING)
    list:SetScript("OnHide", function()
      Watch()
      if opts.onClose then opts.onClose() end
    end)
    lists[list] = true
    -- The skins' pass, from the owner: they walk a frame's children.
    if ns.Skin and ns.Skin.Refresh then pcall(ns.Skin.Refresh, owner) end
  end

  -- As wide as its widest caption in the face it wears now, and under the
  -- button, left edges lined up, as the selects' lists open (PlaceList);
  -- over it only where the room under it is too short for the menu and the
  -- room over it is longer (a button near the foot of the screen). Kept on
  -- the screen whatever else.
  local function Place()
    local widest, room = 0, 0
    for i = 1, #rows do
      local row = rows[i]
      local w = TextWidth(row.Text)
      -- A two-way row: its other words too, and the room for its mark.
      local flip = row.item and row.item.flip
      if flip then
        local now = row.Text:GetText()
        row.Text:SetText(flip)
        w = math.max(w, TextWidth(row.Text))
        row.Text:SetText(now)
        room = FLIP.ROOM
      end
      -- An action row: its glyph and the gap beside its words too.
      if row._glyph then w = w + ACTION.GLYPH + ACTION.GAP end
      if w > widest then widest = w end
    end
    local width = math.max(tonumber(opts.minWidth) or 0, math.ceil(widest) + 2 * (LIST_PADDING + MARK_GUTTER) + room)
    list:SetWidth(width)
    local height = list:GetHeight() or 0
    local bottom, top = owner:GetBottom(), owner:GetTop()
    local up = false
    if bottom and top and UIParent then
      local own = owner:GetEffectiveScale() or 1
      local screenTop = (UIParent:GetTop() or 0) * (UIParent:GetEffectiveScale() or 1) / own
      local above, below = screenTop - top - LIST_GAP, bottom - LIST_GAP
      up = below < height and above > below
    end
    list:ClearAllPoints()
    if up then
      list:SetPoint("BOTTOMLEFT", owner, "TOPLEFT", 0, LIST_GAP)
    else
      list:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -LIST_GAP)
    end
    list:SetFrameLevel(((owner:GetFrameLevel()) or 0) + LIST_LEVEL_OFFSET)
  end

  function menu:IsShown() return list ~= nil and list:IsShown() end

  function menu:Close()
    if list and list:IsShown() then list:Hide() end
    Watch()
  end

  function menu:Toggle()
    if list and list:IsShown() then
      menu:Close()
      return
    end
    if not list then Build() end
    Dropdown.CloseAll(list)
    Place()
    list:Show()
    list:Raise()
    PaintMarks(true)
    Watch()
    if opts.onOpen then opts.onOpen() end
  end

  function menu:Repaint()
    if list and list:IsShown() then PaintMarks() end
  end

  return menu
end
