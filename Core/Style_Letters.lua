local _, ns = ...

-- =====================================================================
-- Postbox :: creative window style "Letters"
-- ---------------------------------------------------------------------
-- The window is a sheet of parchment written in ink: an aged, darker edge
-- round the sheet, a double rule under the title, the mail list on ledger
-- paper with a blue rule under every row and a red margin down its side,
-- and wax seals where the accent would be -- on the open window tab and
-- beside All mail. Round 1 of .dev/design/creative-styles is the design; the
-- foundation is Core/Skin_Creative.lua; the art is .dev/tools/gen-styles.py's.
--
-- THE FIRST LIGHT GROUND. The style asks the foundation for one (`light`):
-- the Postbox style's Light mode palette, Theme.PALETTE_LIGHT, with its
-- light-ground twin of every figure colour, and its 85% opacity floor. Only
-- what parchment changes is set here, as a small table of tokens: the ink
-- (warm, and at least as dark as Light mode's greys), the plates and the
-- paper the list, fields and cards stand on. The sheet the guard reads
-- accent text and inked colours against is the parchment's darkest grain at
-- the 85% floor over a dark scene, so a heading or a gold caption keeps
-- 4.5:1 wherever the window stands.
--
-- THE LEDGER. The rows stand in the list one stride apart with a two-unit
-- gap under each (CollectTab: n rows are n * stride - 2 tall). One tile laid
-- REPEAT down the list's scroll child, a stride to a tile, draws a rule into
-- every gap and scrolls with the rows; the rule is the tile's bottom three
-- texels of 64, inside the gap at every row size. The stride is read off the
-- scroll child's height when it changes; a height no stride divides lays no
-- rules rather than wrong ones. The margin is a line down the list's left
-- edge, anchored to the scroll frame, so it does not scroll.
-- =====================================================================

local CS = ns.CreativeStyles
if not CS then return end

local floor, abs = math.floor, math.abs

local DIR = CS.MEDIA .. "Letters\\"

-- The atlas, in UI units (gen-styles.py prints these).
local ATLAS = { file = DIR .. "letters-parts.tga", w = 64, h = 32 }
local PART = {
  edge = { x = 1,  y = 1, w = 30, h = 30, c = 14 },
  seal = { x = 33, y = 1, w = 16, h = 16 },
}
local RULE = DIR .. "letters-rule.tga"   -- 4 x 32 units; the rule at its foot

-- The list's row gap, and the stride of the lists that are always one-line
-- rows (History, another character's box). The inbox's own stride is asked
-- for (CollectTab.RowStride).
local ROW_GAP = 2
local LINE_STRIDE = 28

local function Hex(h, a)
  return { tonumber((h:sub(1, 2)), 16) / 255, tonumber((h:sub(3, 4)), 16) / 255,
           tonumber((h:sub(5, 6)), 16) / 255, a or 1 }
end

local colors = {
  paper  = Hex("f3e6c7"),
  edge   = Hex("7a5528"),
  ink    = Hex("5a3c19", 0.55),   -- the title's double rule
  rule   = Hex("466ea0", 0.45),   -- the ledger's blue
  margin = Hex("be2828", 0.50),   -- and its red margin
}

-- The ink.
local INK = Hex("2b1d0e")

local def = {
  key = "letters",
  nameKey = "OPT_STYLE_LETTERS",
  light = true,
  inset = 8,
  ground = { file = DIR .. "letters-paper.tga", unit = 64, inset = 1, tint = "paper" },
  colors = colors,
  trim = "edge",
  titleColor = INK,
  -- The Postbox style's palette names (its Light set underneath).
  palette = {
    -- The sheet accent text and inked colours are read on: the parchment's
    -- darkest grain at the 85% floor over a dark scene. Also the popups'
    -- floor, under their own opaque cards.
    window      = Hex("b7ad96"),
    title       = INK,
    accent      = Hex("a3201c"),
    optCard     = Hex("fbf6e8", 0.85),
    optCardEdge = Hex("cdbb94"),
    list        = Hex("fbf6e8", 0.95),
    listEdge    = Hex("b9a47c"),
    field       = Hex("fffbf0"),
    fieldEdge   = Hex("b09a70"),
    band        = Hex("f6eed8", 0.95),
    bandEdge    = Hex("b9a47c"),
    button      = Hex("f6ecd2", 0.97),
    buttonEdge  = Hex("9c8456"),
    hover       = { 0.30, 0.18, 0.05, 0.08 },
    select      = Hex("f6ecd2", 0.97),
    selectEdge  = Hex("8f7549"),
    caret       = Hex("6b5a44"),
    check       = Hex("fffbf0"),
    checkEdge   = Hex("8f7549"),
    close       = { 0.26, 0.16, 0.06, 0.80 },
    tooltipEdge = Hex("7a5528"),
  },
  -- The Theme's tokens on top of its light palette: the plates, the ink, the
  -- paper the cards and the rows stand on. The figure colours are the light
  -- palette's own twins.
  plates = {
    plateIdle         = Hex("efe4c8", 0.95),
    plateHover        = Hex("f4ead2", 0.97),
    plateSelected     = Hex("fdf8ea", 0.99),
    plateFlagged      = Hex("f1e6cb", 0.96),
    plateEdge         = Hex("c4ae84"),
    plateEdgeHover    = Hex("a88f60"),
    plateEdgeSelected = Hex("7a5f33"),
    plateBevel        = { 1, 1, 1, 0.60 },
    plateHighlight    = { 0.30, 0.18, 0.05, 0.05 },
    plateCaption      = Hex("3f2e1c"),
    tabCaption        = Hex("574531"),
    textPrimary       = INK,
    textSecondary     = Hex("4f3f2c"),
    textDisabled      = Hex("7d6d58"),
    textPlaceholder   = Hex("7a6a55", 0.90),
    surface           = Hex("fbf6e8"),
    surfaceBorder     = { 0.35, 0.24, 0.10, 0.30 },
    bandFill          = Hex("f6eed8", 0.95),
    bandBorder        = { 0.35, 0.24, 0.10, 0.25 },
    stripeOdd         = { 0.30, 0.20, 0.08, 0.025 },
    stripeEven        = { 0.30, 0.20, 0.08, 0.050 },
    stripeHover       = { 0.30, 0.20, 0.08, 0.100 },
    inset             = { 1.00, 0.98, 0.93, 0.55 },
    insetEdge         = { 0.35, 0.24, 0.10, 0.20 },
    chromeInk         = { 0.17, 0.11, 0.05, 1.25 },
  },
  -- The window tabs: a darker paper idle, a fresh sheet open (with its seal).
  tabs = {
    plateIdle         = Hex("e3d3ac", 0.92),
    plateHover        = Hex("eadcb9", 0.94),
    plateSelected     = Hex("fbf4e2", 0.98),
    plateFlagged      = Hex("e3d3ac", 0.92),
    plateEdge         = Hex("a88f60"),
    plateEdgeHover    = Hex("8c7244"),
    plateEdgeSelected = Hex("6b4d25"),
    plateBevel        = { 1, 1, 1, 0.50 },
    plateHighlight    = { 0.30, 0.18, 0.05, 0.04 },
    accentWash        = { 0, 0, 0, 0 },
    captionToken      = "tabCaption",
  },
}

-------------------------------------------------------------
-- The seals
-------------------------------------------------------------

local function Seal(parent, layer, size)
  local tex = CS.Tex(parent, layer, 1)
  CS.Part(tex, ATLAS, PART.seal)
  tex:SetSize(size, size)
  return tex
end

-- The open tab's seal, shown with the selection.
local function PaintSeal(tab)
  local seal = tab and tab.__pbSeal
  if not seal then return end
  local on = tab.isSelected and true or false
  if seal.on == on then return end
  seal.on = on
  seal:SetShown(on)
end

local function BuildTabSeals(art)
  local tabs = art.frame.TabButtons
  if not tabs then return end
  for _, tab in pairs(tabs) do
    if tab and not tab.__pbSeal then
      local seal = Seal(tab, "OVERLAY", 12)
      seal:SetPoint("CENTER", tab, "LEFT", 13, 0)
      tab.__pbSeal = seal
      PaintSeal(tab)
    end
  end
end

function def.Setup()
  -- A tab's selection is painted through Theme.SetTabSelected (MailboxUI,
  -- UI.SelectTab); the seal follows it there. Postbox's own function, and
  -- only while this style is chosen.
  local T = ns.Theme
  if T and type(T.SetTabSelected) == "function" and type(hooksecurefunc) == "function" then
    hooksecurefunc(T, "SetTabSelected", PaintSeal)
  end
end

-- All mail sealed: the seal just left of its caption, following it.
function def.DressSweep(button, _, primary)
  if not (primary and button and button.__postboxSkinned) or button.__pbSeal then return end
  local seal = Seal(button, "ARTWORK", 14)
  local fs = button:GetFontString()
  if fs then
    seal:SetPoint("RIGHT", fs, "LEFT", -4, 0)
  else
    seal:SetPoint("LEFT", button, "LEFT", 8, 0)
  end
  button.__pbSeal = seal
end

-------------------------------------------------------------
-- The ledger
-------------------------------------------------------------

-- The stride the list is laid at, from its height: the inbox's or the
-- one-line lists'. Both, only for a height they share (rare), where the view
-- decides; neither, nil.
local function Divides(h, stride)
  local n = (h + ROW_GAP) / stride
  return n >= 1 and abs(n - floor(n + 0.5)) < 0.01
end

local function LedgerStride(child, h)
  local CT = ns.CollectTab
  local inbox = CT and type(CT.RowStride) == "function" and tonumber((CT.RowStride())) or LINE_STRIDE
  local a, b = Divides(h, inbox), Divides(h, LINE_STRIDE)
  if a and b then
    local panel = child.__pbLedgerPanel
    if panel and (panel.viewMode == "history" or panel._alt) then return LINE_STRIDE end
    return inbox
  end
  if a then return inbox end
  if b then return LINE_STRIDE end
  return nil
end

local function LayLedger(child)
  local ledger = child.__pbLedger
  if not ledger then return end
  local w, h = child:GetWidth() or 0, child:GetHeight() or 0
  local stride = (h > 1) and LedgerStride(child, h) or nil
  if not stride then
    if ledger.shown then
      ledger.rules:Hide()
      ledger.shown = false
    end
    return
  end
  -- Along the rows the tile only repeats the rule: any width reads the same.
  ledger.rules:SetTexCoord(0, 1, 0, h / stride)
  if not ledger.shown then
    ledger.rules:Show()
    ledger.shown = true
  end
end

local function OnListSize(self)
  LayLedger(self)
end

local function BuildLedger(art)
  local tabs = art.frame.Tabs
  local panel = tabs and tabs.collect
  local child = panel and panel.MailListChild
  local scroll = panel and panel.MailListScroll
  if not (child and scroll) or child.__pbLedger then return end
  local rules = CS.Tex(child, "BACKGROUND", 1, RULE, "REPEAT")
  rules:SetAllPoints(child)
  CS.Tinted(art, rules, "rule")
  rules:Hide()
  local margin = CS.Line(child, "BACKGROUND", 2)
  margin:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0.5, 0)
  margin:SetPoint("BOTTOMLEFT", scroll, "BOTTOMLEFT", 0.5, 0)
  margin:SetWidth(1)
  CS.Tinted(art, margin, "margin")
  child.__pbLedger = { rules = rules, margin = margin, shown = false }
  child.__pbLedgerPanel = panel
  child:HookScript("OnSizeChanged", OnListSize)
  LayLedger(child)
end

-------------------------------------------------------------
-- The sheet
-------------------------------------------------------------

function def.Build(art)
  local edge = CS.Nine(art, ATLAS, PART.edge, "BORDER", 0)
  CS.LayNine(edge, art, 0)
  CS.TintedSet(art, edge, "edge")

  -- A double rule under the title.
  for i, y in ipairs({ 24.5, 26.5 }) do
    local rule = CS.Line(art, "BORDER", 1)
    rule:SetPoint("TOPLEFT", art, "TOPLEFT", 9, -y)
    rule:SetPoint("TOPRIGHT", art, "TOPRIGHT", -9, -y)
    rule:SetHeight((i == 1) and 1 or 0.8)
    CS.Tinted(art, rule, "ink")
  end

  if art.main then
    BuildTabSeals(art)
    BuildLedger(art)
  end
end

-- The list may be built after the window was dressed: the ledger is laid on
-- the Mail tab's next pass. One field read once it stands.
function def.OnMailState(art)
  local tabs = art.frame.Tabs
  local panel = tabs and tabs.collect
  local child = panel and panel.MailListChild
  if child and not child.__pbLedger then BuildLedger(art) end
end

CS.Register(def)
