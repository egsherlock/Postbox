local _, ns = ...

-- =====================================================================
-- Postbox :: creative window style "Post Office Counter"
-- ---------------------------------------------------------------------
-- A walnut counter with brass fittings: a moulded walnut rim with a brass
-- inlay line, brass brackets on the corners, the title on an engraved brass
-- nameplate, All mail as a drawer front with two knobs and a brass card
-- holder, and the category buttons as pigeonholes that hold one envelope,
-- two or three as the category holds one mail, a few or many (none when it
-- holds nothing; the count is still written). The cog and the close X stand
-- 20 units in, on the plain moulding, clear of the brackets (the v2 fix).
--
-- The pigeonholes and the drawer are laid on the buttons themselves
-- (Postbox's own frames): above the button's fill, under its caption and
-- its hover wash. They are dressed as the category buttons are laid out
-- (Skin.DressSweep, from CollectTab) and change only when a count crosses
-- into another level or a caption changes width.
-- =====================================================================

local CS = ns.CreativeStyles
if not CS then return end

-- Built at login only when this is the chosen style (Core/Skin_Creative.lua).
CS.Register("counter", "OPT_STYLE_COUNTER", function()
  local floor, max = math.floor, math.max

  local DIR = CS.MEDIA .. "Counter\\"

  local ATLAS = { file = DIR .. "counter-parts.tga", w = 128, h = 64 }
  local PART = {
    rim       = { x = 1,   y = 1,  w = 28, h = 28, c = 12 },
    drawer    = { x = 31,  y = 1,  w = 14, h = 14, c = 5 },
    cubby     = { x = 47,  y = 1,  w = 16, h = 16, c = 6 },
    label     = { x = 65,  y = 1,  w = 12, h = 16, c = 4 },
    nameplate = { x = 79,  y = 1,  w = 28, h = 18, c = 12 },
    bracket   = { x = 109, y = 1,  w = 16, h = 16 },
    knob      = { x = 1,   y = 31, w = 8,  h = 8 },
    envelope  = { x = 11,  y = 31, w = 14, h = 9 },
  }
  local WOOD = DIR .. "counter-walnut.tga"

  local colors = {
    wood     = { 0.56, 0.35, 0.20 },
    moulding = { 0.62, 0.40, 0.24 },
    drawer   = { 0.66, 0.41, 0.23 },
    brass    = { 0.80, 0.62, 0.30 },
  }

  local def = {
    key = "counter",
    nameKey = "OPT_STYLE_COUNTER",
    inset = 20,
    ground = { file = WOOD, unit = 64, inset = 2, tint = "wood" },
    -- The tile's grey range (gen-styles.py: counter-walnut), for the grounds.
    grain = { 0.46, 1.0 },
    colors = colors,
    trim = "brass",
    -- Engraved: dark lettering on the brass nameplate.
    titleColor = { 0.17, 0.11, 0.035 },
    palette = {
      accent      = { 0.84, 0.66, 0.32, 1 },
      button      = { 0.13, 0.085, 0.055, 0.95 },
      buttonEdge  = { 0.07, 0.045, 0.03, 1 },
      select      = { 0.13, 0.085, 0.055, 0.95 },
      selectEdge  = { 0.40, 0.30, 0.15, 1 },
      tooltipEdge = { 0.62, 0.48, 0.24, 1 },
    },
    plates = {
      plateIdle         = { 0.12, 0.08, 0.05, 0.94 },
      plateHover        = { 0.17, 0.115, 0.075, 0.96 },
      plateSelected     = { 0.23, 0.16, 0.10, 0.99 },
      plateFlagged      = { 0.14, 0.095, 0.06, 0.95 },
      plateEdge         = { 0.30, 0.22, 0.12, 0.85 },
      plateEdgeHover    = { 0.46, 0.35, 0.19, 1 },
      plateEdgeSelected = { 0.66, 0.51, 0.26, 1 },
    },
    tabs = {
      plateIdle         = { 0.10, 0.065, 0.04, 0.90 },
      plateHover        = { 0.15, 0.10, 0.065, 0.93 },
      plateSelected     = { 0.22, 0.15, 0.09, 0.97 },
      plateFlagged      = { 0.10, 0.065, 0.04, 0.90 },
      plateEdge         = { 0.30, 0.22, 0.12, 0.90 },
      plateEdgeHover    = { 0.44, 0.33, 0.18, 1 },
      plateEdgeSelected = { 0.72, 0.56, 0.28, 1 },
      plateBevel        = { 1, 1, 1, 0.05 },
      plateHighlight    = { 1, 1, 1, 0.05 },
      accentWash        = { 0, 0, 0, 0 },
      captionToken      = "tabCaption",
    },
  }

  local CORNERS = {
    { "TOPLEFT", 1, -1, nil }, { "TOPRIGHT", -1, -1, "h" },
    { "BOTTOMLEFT", 1, 1, "v" }, { "BOTTOMRIGHT", -1, 1, "hv" },
  }

  function def.Build(art)
    local rim = CS.Nine(art, ATLAS, PART.rim, "BORDER", 0)
    CS.LayNine(rim, art, 0)
    CS.TintedSet(art, rim, "moulding")

    -- The brass inlay just inside the moulding, and a second under the title.
    local inlay = CS.Frame4(art, "BORDER", 1)
    CS.LayFrame4(inlay, art, 10, 1, 26)
    for i = 1, 4 do CS.Tinted(art, inlay[i], "brass") end
    local rule = CS.Line(art, "BORDER", 1)
    rule:SetPoint("TOPLEFT", art, "TOPLEFT", 10, -10)
    rule:SetPoint("TOPRIGHT", art, "TOPRIGHT", -10, -10)
    rule:SetHeight(1)
    CS.Tinted(art, rule, "brass")
    rule:SetAlpha(0.45)

    for i = 1, 4 do
      local spec = CORNERS[i]
      local tex = CS.Tex(art, "ARTWORK", 1)
      CS.Part(tex, ATLAS, PART.bracket, spec[4])
      tex:SetSize(16, 16)
      tex:SetPoint(spec[1], art, spec[1], spec[2] * 1, spec[3] * 1)
    end

    -- The nameplate: sized to the title in Layout.
    local plate = CS.Three(art, ATLAS, PART.nameplate, "ARTWORK", 2)
    plate.m:SetPoint("CENTER", art, "TOP", 0, -12.5)
    plate.m:SetHeight(18)
    plate.l3:SetPoint("RIGHT", plate.m, "LEFT")
    plate.l3:SetSize(12, 18)
    plate.r3:SetPoint("LEFT", plate.m, "RIGHT")
    plate.r3:SetSize(12, 18)
    art.nameplate = plate
  end

  function def.Layout(art, w)
    local plate = art.nameplate
    if not plate then return end
    local title = art.frame.TitleText
    local tw = title and title.GetStringWidth and title:GetStringWidth() or 40
    -- The title and a screw's width either side; never past the controls.
    local mid = max(8, floor(tw + 0.5) + 8)
    local most = w - 2 * (def.inset + 26) - 24
    if most > 8 and mid > most then mid = most end
    plate.m:SetWidth(mid)
  end

  -------------------------------------------------------------
  -- The drawer and the pigeonholes (the main window's category buttons)
  -------------------------------------------------------------

  -- A card holder round the caption: a brass three-slice 16 tall whose middle
  -- follows the caption's width (DressSweep).
  local function Label(button)
    local label = CS.Three(button, ATLAS, PART.label, "BACKGROUND", 5)
    local fs = button:GetFontString()
    label.m:SetPoint("CENTER", fs or button, "CENTER", 0, 0)
    label.m:SetHeight(16)
    label.l3:SetPoint("RIGHT", label.m, "LEFT")
    label.l3:SetSize(4, 16)
    label.r3:SetPoint("LEFT", label.m, "RIGHT")
    label.r3:SetSize(4, 16)
    return label
  end

  local ENVELOPES = {
    -- where, x, y (from the button's top corner), rotation
    { "TOPLEFT", 6, -2, 0.10 },
    { "TOPRIGHT", -6, -3, -0.12 },
    { "TOPLEFT", 14, -4, -0.06 },
  }

  local function BuildCubby(button)
    local d = { level = -1, labelW = -1 }
    local cubby = CS.Nine(button, ATLAS, PART.cubby, "BACKGROUND", 1, true)
    CS.LayNine(cubby, button, 0, 0, 0, 0, 6)
    d.envelopes = {}
    for i = 1, 3 do
      local spec = ENVELOPES[i]
      local tex = CS.Tex(button, "BACKGROUND", 3)
      CS.Part(tex, ATLAS, PART.envelope)
      tex:SetSize(14, 9)
      tex:SetPoint(spec[1], button, spec[1], spec[2], spec[3])
      if tex.SetRotation then tex:SetRotation(spec[4]) end
      tex:Hide()
      d.envelopes[i] = tex
    end
    d.label = Label(button)
    return d
  end

  local function BuildDrawer(button)
    local d = { level = -1, labelW = -1, w = -1 }
    local art = CS.mainArt
    local wood = CS.Tex(button, "BACKGROUND", 1, WOOD, "REPEAT")
    wood:SetAllPoints(button)
    if art then CS.Tinted(art, wood, "drawer") end
    d.wood = wood
    local frame = CS.Nine(button, ATLAS, PART.drawer, "BACKGROUND", 2)
    CS.LayNine(frame, button, 0, 0, 0, 0, 5)
    if art then CS.TintedSet(art, frame, "moulding") end
    d.knobs = {}
    for i, side in ipairs({ "LEFT", "RIGHT" }) do
      local knob = CS.Tex(button, "BACKGROUND", 4)
      CS.Part(knob, ATLAS, PART.knob)
      knob:SetSize(8, 8)
      knob:SetPoint("CENTER", button, side, (i == 1) and 34 or -34, 0)
      d.knobs[i] = knob
    end
    d.label = Label(button)
    return d
  end

  -- 0, 1, 2 (a few: 2 to 5) or 3 (many: 6 and up) envelopes.
  local function Level(n)
    if n <= 0 then return 0 end
    if n == 1 then return 1 end
    if n <= 5 then return 2 end
    return 3
  end

  function def.DressSweep(button, n, primary)
    -- Only once the skin has painted the button: its pass clears every
    -- texture a button carries, and the buttons are first laid out before it.
    if not (button and button.__postboxSkinned) then return end
    local d = button.__pbCounter
    if not d then
      d = primary and BuildDrawer(button) or BuildCubby(button)
      button.__pbCounter = d
    end
    if primary then
      local w = floor((button:GetWidth() or 0) + 0.5)
      if w ~= d.w then
        d.w = w
        CS.TileCoords(d.wood, w, button:GetHeight() or 28, 64)
      end
    else
      local level = Level(tonumber(n) or 0)
      if level ~= d.level then
        d.level = level
        for i = 1, 3 do d.envelopes[i]:SetShown(i <= level) end
      end
    end
    local fs = button:GetFontString()
    local tw = fs and fs.GetStringWidth and floor((fs:GetStringWidth() or 0) + 0.5) or 0
    if tw ~= d.labelW then
      d.labelW = tw
      d.label.m:SetWidth(max(4, tw + 4))
    end
  end

  return def
end)
