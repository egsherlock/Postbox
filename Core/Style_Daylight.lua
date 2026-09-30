local _, ns = ...

-- =====================================================================
-- Postbox :: creative window style "Daylight"
-- ---------------------------------------------------------------------
-- A light window done as a sheet of good paper: warm white with a grain you
-- see only up close, graphite ink, a warm grey keyline with a white line
-- inside it, a soft shadow under the sheet, and a band of deeper paper
-- behind the title with a hairline under it. No ornaments. Round 1 of
-- .dev/design/creative-styles (notes.md, "Daylight") is the brief; the
-- foundation is Core/Skin_Creative.lua; the art is .dev/tools/gen-styles.py's.
--
-- BESIDE THE POSTBOX STYLE'S LIGHT MODE, which it is built on (`light`: the
-- same palette, twins and 85% opacity floor): Light mode is neutral grey
-- paper under whatever accent, tint, corners and border the player picks;
-- Daylight is fixed and warm -- paper instead of grey, graphite instead of
-- black, rules and rings in warm greys, the brand gold as its accent, and
-- the sheet's own chrome (grain, shadow, title band). A sibling, not a copy:
-- a player who wants a light window they tune picks Light mode.
-- =====================================================================

local CS = ns.CreativeStyles
if not CS then return end

local DIR = CS.MEDIA .. "Daylight\\"

-- The atlas, in UI units (gen-styles.py prints these).
local ATLAS = { file = DIR .. "daylight-parts.tga", w = 64, h = 32 }
local PART = {
  -- The rim: 5 units of shadow outside the sheet, the keyline, the white
  -- line; laid 5 units out from the window.
  rim = { x = 1, y = 1, w = 24, h = 24, c = 10 },
}
local SHADOW = 5

local Hex = ns.Theme.HexColor

local colors = {
  paper    = Hex("f8f4ec"),
  hairline = Hex("cfc5b3"),
}

local GRAPHITE = Hex("262523")

local def = {
  key = "daylight",
  nameKey = "OPT_STYLE_DAYLIGHT",
  light = true,
  ground = { file = DIR .. "daylight-paper.tga", unit = 64, inset = 1, tint = "paper" },
  -- The deeper paper behind the title, faded with the ground.
  titleBand = Hex("ece4d4", 0.90),
  bandInset = 1,
  colors = colors,
  trim = "hairline",
  titleColor = GRAPHITE,
  palette = {
    -- The sheet accent text and inked colours are read on: the paper's
    -- darkest grain at the 85% floor over a dark scene.
    window      = Hex("cac7c1"),
    title       = GRAPHITE,
    accent      = Hex("d3a44a"),
    optCard     = Hex("fffdf8", 0.85),
    optCardEdge = Hex("e0d8c9"),
    list        = Hex("fffdf8", 0.95),
    listEdge    = Hex("ddd5c6"),
    field       = Hex("ffffff"),
    fieldEdge   = Hex("d3cab9"),
    band        = Hex("f6f1e7", 0.95),
    bandEdge    = Hex("ddd5c6"),
    button      = Hex("fbf8f1", 0.97),
    buttonEdge  = Hex("cbc1ae"),
    hover       = { 0.25, 0.18, 0.08, 0.06 },
    select      = Hex("fbf8f1", 0.97),
    selectEdge  = Hex("c2b7a2"),
    caret       = Hex("756c5e"),
    check       = Hex("ffffff"),
    checkEdge   = Hex("b3a891"),
    close       = { 0.15, 0.14, 0.13, 0.75 },
    tooltipEdge = Hex("b8ad99"),
  },
  -- The Theme's tokens on top of its light palette: graphite ink, warm
  -- rings and rules; the figure colours are the light palette's twins.
  plates = {
    plateIdle         = Hex("f4efe6", 0.99),
    plateHover        = Hex("f8f5ee", 0.99),
    plateSelected     = Hex("ffffff", 0.99),
    plateFlagged      = Hex("f5f1e8", 0.99),
    plateEdge         = Hex("dcd3c3"),
    plateEdgeHover    = Hex("c9bfad"),
    plateEdgeSelected = Hex("aea38e"),
    plateBevel        = { 1, 1, 1, 0.70 },
    plateHighlight    = { 0.25, 0.18, 0.08, 0.04 },
    plateCaption      = Hex("36332f"),
    tabCaption        = Hex("56514a"),
    textPrimary       = GRAPHITE,
    textSecondary     = Hex("48443e"),
    textDisabled      = Hex("736d64"),
    textPlaceholder   = Hex("6e685f", 0.90),
    surface           = Hex("fffdf8"),
    surfaceBorder     = { 0.30, 0.22, 0.10, 0.18 },
    bandFill          = Hex("f6f1e7", 0.95),
    bandBorder        = { 0.30, 0.22, 0.10, 0.16 },
    stripeOdd         = { 0.35, 0.25, 0.10, 0.025 },
    stripeEven        = { 0.35, 0.25, 0.10, 0.050 },
    stripeHover       = { 0.35, 0.25, 0.10, 0.090 },
    insetEdge         = { 0.30, 0.22, 0.10, 0.16 },
    chromeInk         = { 0.15, 0.13, 0.10, 1.25 },
  },
  tabs = {
    plateIdle         = Hex("ece6da", 0.92),
    plateHover        = Hex("f2ede4", 0.94),
    plateSelected     = Hex("ffffff", 0.96),
    plateFlagged      = Hex("ece6da", 0.92),
    plateEdge         = Hex("d6ccbb"),
    plateEdgeHover    = Hex("c7bca9"),
    plateEdgeSelected = Hex("b2a690"),
    plateBevel        = { 1, 1, 1, 0 },
    plateHighlight    = { 0.20, 0.15, 0.08, 0.03 },
    accentWash        = { 0, 0, 0, 0 },
    captionToken      = "tabCaption",
  },
}

function def.Build(art)
  -- The rim, its shadow outside the window: art that takes no mouse, so the
  -- window's own edge is where it always was.
  local rim = CS.Nine(art, ATLAS, PART.rim, "BORDER", 0)
  CS.LayNine(rim, art, -SHADOW)

  -- The hairline under the title band.
  local rule = CS.Line(art, "BORDER", 1)
  rule:SetPoint("TOPLEFT", art, "TOPLEFT", 2, -25)
  rule:SetPoint("TOPRIGHT", art, "TOPRIGHT", -2, -25)
  rule:SetHeight(1)
  CS.Tinted(art, rule, "hairline")
end

CS.Register(def)
