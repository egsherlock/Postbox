local _, ns = ...

-- =====================================================================
-- Postbox :: creative window style "Pillar Box"
-- ---------------------------------------------------------------------
-- The window is a painted post box: a rolled lip for the title bar, a
-- steel rim with rivets down the sides, a black plinth, the totals on a
-- white enamel plate, and a flag at the top-right corner that stands up
-- while there is mail to collect and lies down along the side otherwise.
-- The paint is a choice (red, green, blue, black, gold): the art is grey and
-- takes the paint as a tint, so each colour is one colour. Round 1 of
-- .dev/design/creative-styles is the design; the foundation is
-- Core/Skin_Creative.lua; the art is .dev/tools/gen-styles.py's.
-- =====================================================================

local CS = ns.CreativeStyles
if not CS then return end

-- Built at login only when this is the chosen style (Core/Skin_Creative.lua).
CS.Register("pillar", "OPT_STYLE_PILLAR", function()
  local DIR = CS.MEDIA .. "PillarBox\\"

  -- The atlas, in UI units (gen-styles.py prints these).
  local ATLAS = { file = DIR .. "pillar-parts.tga", w = 128, h = 64 }
  local PART = {
    rim      = { x = 1,   y = 1,  w = 32, h = 32, c = 14 },
    lip      = { x = 35,  y = 1,  w = 32, h = 26, c = 14 },
    enamel   = { x = 69,  y = 1,  w = 16, h = 16, c = 6 },
    rivet    = { x = 87,  y = 1,  w = 6,  h = 6 },
    screw    = { x = 95,  y = 1,  w = 6,  h = 6 },
    flagUp   = { x = 103, y = 1,  w = 20, h = 34 },
    flagDown = { x = 35,  y = 29, w = 20, h = 34 },
  }

  -- The paints, the first the default. Each was checked for the white title
  -- on the lip where the title sits (the lip is about 0.83 grey there): every
  -- one is 4.5:1 or better.
  local PAINTS = {
    { key = "red",   nameKey = "OPT_PAINT_RED",   color = { 0.78, 0.13, 0.10 } },
    { key = "green", nameKey = "OPT_PAINT_GREEN", color = { 0.12, 0.43, 0.23 } },
    { key = "blue",  nameKey = "OPT_PAINT_BLUE",  color = { 0.15, 0.29, 0.60 } },
    { key = "black", nameKey = "OPT_PAINT_BLACK", color = { 0.25, 0.25, 0.26 } },
    { key = "gold",  nameKey = "OPT_PAINT_GOLD",  color = { 0.64, 0.47, 0.13 } },
  }

  local colors = {
    paint = { 0.78, 0.13, 0.10 },
    screw = { 0.86, 0.86, 0.86 },
  }

  -- The totals on enamel: the label in ink, the sums in the dark twins of the
  -- list's green and red (5.6:1 and 5.7:1 on the enamel).
  local INK = { 0.11, 0.10, 0.09 }
  local EARNED_DARK, SPENT_DARK = "ff176b28", "ffb21d1d"

  local def = {
    key = "pillar",
    nameKey = "OPT_STYLE_PILLAR",
    inset = 11,
    ground = { file = DIR .. "pillar-ground.tga", unit = 64, inset = 3, tint = "paint" },
    rivets = { atlas = ATLAS, part = PART.rivet, spacing = 72, top = 50, bottom = 22, x = 3.5, tint = "paint" },
    colors = colors,
    trim = "paint",
    variants = PAINTS,
    variantKey = "pbPaint",
    variantTitleKey = "OPT_PAINT_TITLE",
    variantDescKey = "OPT_PAINT_DESC",
    -- Black enamel for every button, gold lettering (the buttons' own font).
    palette = {
      button      = { 0.075, 0.066, 0.062, 0.96 },
      buttonEdge  = { 0, 0, 0, 1 },
      select      = { 0.075, 0.066, 0.062, 0.96 },
      selectEdge  = { 0.02, 0.02, 0.02, 1 },
      tooltipEdge = { 0.55, 0.13, 0.10, 1 },
    },
    plates = {
      plateIdle         = { 0.070, 0.062, 0.058, 0.95 },
      plateHover        = { 0.110, 0.098, 0.090, 0.97 },
      plateSelected     = { 0.160, 0.142, 0.130, 0.99 },
      plateFlagged      = { 0.090, 0.080, 0.075, 0.96 },
      plateEdge         = { 0, 0, 0, 0.85 },
      plateEdgeHover    = { 0.30, 0.27, 0.25, 1 },
      plateEdgeSelected = { 0.45, 0.40, 0.36, 1 },
    },
    -- The window tabs: the idle one a dark wash over the paint, the open one
    -- black enamel with the accent underline.
    tabs = {
      plateIdle         = { 0.10, 0.06, 0.05, 0.78 },
      plateHover        = { 0.14, 0.09, 0.08, 0.88 },
      plateSelected     = { 0.07, 0.06, 0.06, 0.97 },
      plateFlagged      = { 0.10, 0.06, 0.05, 0.78 },
      plateEdge         = { 0, 0, 0, 0.90 },
      plateEdgeHover    = { 0.22, 0.16, 0.14, 1 },
      plateEdgeSelected = { 0.34, 0.29, 0.25, 1 },
      plateBevel        = { 1, 1, 1, 0.06 },
      plateHighlight    = { 1, 1, 1, 0.05 },
      accentWash        = { 0, 0, 0, 0 },
      captionToken      = "tabCaption",
    },
  }

  function def.RefreshColors()
    local key = CS.GetVariant()
    for i = 1, #PAINTS do
      if PAINTS[i].key == key then
        local c = PAINTS[i].color
        colors.paint[1], colors.paint[2], colors.paint[3] = c[1], c[2], c[3]
      end
    end
  end

  -- The flag: up, the pole's foot at the corner and the flag above the window;
  -- down, the pole along the right side and the flag hanging outside it.
  local function BuildFlag(art)
    local up = CS.Tex(art, "OVERLAY", 2)
    CS.Part(up, ATLAS, PART.flagUp)
    up:SetSize(PART.flagUp.w, PART.flagUp.h)
    up:SetPoint("BOTTOMLEFT", art, "TOPRIGHT", -7, -15)
    local down = CS.Tex(art, "OVERLAY", 2)
    CS.Part(down, ATLAS, PART.flagDown)
    down:SetSize(PART.flagDown.w, PART.flagDown.h)
    down:SetPoint("TOPLEFT", art, "TOPRIGHT", -7, -12)
    up:Hide()
    art.flagUp, art.flagDown = up, down
    art.flagState = false
  end

  -- The totals band on white enamel, with a screw at each end. On the band
  -- itself (Postbox's own frame, not a panel a host skin repaints): above its
  -- fill, under its text.
  local function BuildEnamel(art)
    local tabs = art.frame.Tabs
    local panel = tabs and tabs.collect
    local band = panel and panel.Banner
    if not band or band.__pbEnamel then return end
    local plate = CS.Nine(band, ATLAS, PART.enamel, "BACKGROUND", 2, true)
    CS.LayNine(plate, band, 0, 0, 0, 0, 6)
    for i, side in ipairs({ "LEFT", "RIGHT" }) do
      local screw = CS.Tex(band, "BACKGROUND", 4)
      CS.Part(screw, ATLAS, PART.screw)
      screw:SetSize(5, 5)
      screw:SetPoint("CENTER", band, side, (i == 1) and 5 or -5, 0)
      CS.Tinted(art, screw, "screw")
    end
    band.__pbEnamel = plate
    -- The band may have been fitted already, in the inks it had then.
    local text = panel.BannerText
    if text then text:SetTextColor(INK[1], INK[2], INK[3], 1) end
  end

  function def.Build(art)
    local rim = CS.Nine(art, ATLAS, PART.rim, "BORDER", 0)
    CS.LayNine(rim, art, 0)
    CS.TintedSet(art, rim, "paint")

    local lip = CS.Three(art, ATLAS, PART.lip, "BORDER", 2)
    CS.LayThree(lip, art, 0, 0, 0, 26)
    CS.TintedSet(art, lip, "paint")

    -- The plinth: black, with a lit top edge, over the rim's foot.
    local plinth = CS.Line(art, "BORDER", 3)
    plinth:SetVertexColor(0.055, 0.052, 0.05, 1)
    plinth:SetPoint("BOTTOMLEFT", art, "BOTTOMLEFT", 3, 1.5)
    plinth:SetPoint("BOTTOMRIGHT", art, "BOTTOMRIGHT", -3, 1.5)
    plinth:SetHeight(7.5)
    local edge = CS.Line(art, "BORDER", 4)
    edge:SetVertexColor(0.32, 0.30, 0.29, 1)
    edge:SetPoint("BOTTOMLEFT", plinth, "TOPLEFT", 0, -1)
    edge:SetPoint("BOTTOMRIGHT", plinth, "TOPRIGHT", 0, -1)
    edge:SetHeight(1)

    if art.main then
      BuildFlag(art)
      BuildEnamel(art)
    end
  end

  -- Up while there is mail to collect: the Mail tab's dot says the same.
  function def.OnMailState(art, open)
    if not art.flagUp then return end
    local up = false
    if open then
      local collect = ns.CollectTab
      local toCollect = collect and type(collect.InboxCounts) == "function" and collect.InboxCounts() or 0
      up = (tonumber(toCollect) or 0) > 0
    end
    if up == art.flagState then return end
    art.flagState = up
    art.flagUp:SetShown(up)
    art.flagDown:SetShown(not up)
  end

  -- The totals band's inks while it stands on the enamel; untouched elsewhere.
  function def.BannerInk(text, up, down)
    local band = text and text.GetParent and text:GetParent()
    if not (band and band.__pbEnamel) then return up, down end
    text:SetTextColor(INK[1], INK[2], INK[3], 1)
    return EARNED_DARK, SPENT_DARK
  end

  return def
end)
