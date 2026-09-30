local _, ns = ...

-- =====================================================================
-- Postbox :: creative window style "Faction"
-- ---------------------------------------------------------------------
-- Tinted chrome chosen by the character being played. Alliance: navy
-- lacquer, a double gold trim and gold filigree corners. Horde: oxblood
-- leather, an iron edge with iron corner caps and a stitched seam. A
-- character with no faction yet (a Pandaren on the Wandering Isle) wears the
-- leather in brown with bronze and no emblem. The list stays the dark list,
-- not navy or red: Shaman blue dies on navy and Death Knight red on red
-- leather.
--
-- THE EMBLEM IS BLIZZARD'S. Just left of the title (the cog's neighbour, the
-- arrange key, widens while arranging, so it is measured from the title,
-- and shown only where the two leave it room): the game's
-- own gold faction silhouette from the character-select screen, looked up by
-- atlas name at runtime and checked with C_Texture.GetAtlasInfo; the PvP
-- sidebar badge if that is missing, and nothing if both are. Postbox ships
-- no crest and draws none. Gold, as the game draws it, not the accent.
--
-- The faction is read when the style is claimed (PLAYER_LOGIN) and again
-- when the first window is dressed, which is after the world has loaded; a
-- faction chosen later in the session shows after a /reload.
-- =====================================================================

local CS = ns.CreativeStyles
if not CS then return end

-- Built at login only when this is the chosen style (Core/Skin_Creative.lua).
CS.Register("faction", "OPT_STYLE_FACTION", function()
  local DIR = CS.MEDIA .. "Faction\\"

  local ATLAS = { file = DIR .. "faction-parts.tga", w = 64, h = 32 }
  local PART = {
    filigree = { x = 1,  y = 1, w = 28, h = 28 },
    stud     = { x = 31, y = 1, w = 8,  h = 8 },
    cap      = { x = 41, y = 1, w = 14, h = 14 },
  }
  local STITCH = DIR .. "faction-stitch.tga"   -- 8 x 2 units, repeats along x

  local EMBLEMS = {
    Alliance = {
      { atlas = "glues-characterselect-icon-faction-alliance-selected-2x", w = 16, h = 21 },
      { atlas = "pvpqueue-sidebar-honorbar-badge-alliance", w = 18, h = 21 },
    },
    Horde = {
      { atlas = "glues-characterselect-icon-faction-horde-selected-2x", w = 16, h = 21 },
      { atlas = "pvpqueue-sidebar-honorbar-badge-horde", w = 18, h = 21 },
    },
  }

  -- Per side: the tints, the accent and the controls' grounds.
  local LOOKS = {
    alliance = {
      ground = { 0.13, 0.19, 0.40 },
      trim   = { 0.86, 0.69, 0.33 },
      edge   = { 0.02, 0.03, 0.07 },
      accent = { 0.86, 0.69, 0.33, 1 },
      button = { 0.06, 0.09, 0.19, 0.95 }, buttonEdge = { 0.36, 0.30, 0.16, 1 },
      plate = { 0.06, 0.09, 0.18 }, plateEdge = { 0.34, 0.29, 0.17 },
      inset = 28,
    },
    horde = {
      ground = { 0.42, 0.12, 0.09 },
      trim   = { 0.62, 0.62, 0.65 },
      edge   = { 0.16, 0.16, 0.18 },
      thread = { 0.86, 0.74, 0.56 },
      accent = { 0.80, 0.55, 0.30, 1 },
      button = { 0.10, 0.065, 0.055, 0.95 }, buttonEdge = { 0.33, 0.24, 0.18, 1 },
      plate = { 0.10, 0.065, 0.055 }, plateEdge = { 0.34, 0.26, 0.20 },
      inset = 14,
    },
    neutral = {
      ground = { 0.27, 0.20, 0.15 },
      trim   = { 0.72, 0.52, 0.30 },
      edge   = { 0.10, 0.08, 0.06 },
      thread = { 0.78, 0.68, 0.52 },
      accent = { 0.80, 0.58, 0.32, 1 },
      button = { 0.09, 0.07, 0.06, 0.95 }, buttonEdge = { 0.32, 0.25, 0.18, 1 },
      plate = { 0.09, 0.07, 0.06 }, plateEdge = { 0.32, 0.25, 0.18 },
      inset = 14,
    },
  }

  local colors = {}

  local def = {
    key = "faction",
    nameKey = "OPT_STYLE_FACTION",
    colors = colors,
    trim = "trim",
    titleBand = { 0, 0, 0, 0.30 },
    bandInset = 1,
  }

  local function Faction()
    local f = type(UnitFactionGroup) == "function" and UnitFactionGroup("player") or nil
    if issecretvalue and issecretvalue(f) then return nil end
    if f == "Alliance" or f == "Horde" then return f end
    return nil
  end

  local function Side(faction)
    if faction == "Alliance" then return "alliance" end
    if faction == "Horde" then return "horde" end
    return "neutral"
  end

  local function Plate(c, a) return { c[1], c[2], c[3], a } end

  -- What the side decides, before the palette is read.
  function def.Prepare()
    def.faction = Faction()
    local side = Side(def.faction)
    def.side = side
    local look = LOOKS[side]
    def.inset = look.inset
    def.ground = {
      file = DIR .. ((side == "alliance") and "faction-lacquer.tga" or "faction-leather.tga"),
      unit = 64, inset = 1, tint = "ground",
    }
    colors.ground, colors.trim, colors.edge, colors.thread = look.ground, look.trim, look.edge, look.thread
    def.palette = {
      accent      = look.accent,
      button      = look.button,
      buttonEdge  = look.buttonEdge,
      select      = look.button,
      selectEdge  = look.buttonEdge,
      tooltipEdge = Plate(look.trim, 1),
    }
    local p, e = look.plate, look.plateEdge
    def.plates = {
      plateIdle         = Plate(p, 0.94),
      plateHover        = { p[1] + 0.04, p[2] + 0.04, p[3] + 0.04, 0.96 },
      plateSelected     = { p[1] + 0.09, p[2] + 0.09, p[3] + 0.09, 0.99 },
      plateFlagged      = Plate(p, 0.95),
      plateEdge         = Plate(e, 0.85),
      plateEdgeHover    = { e[1] + 0.12, e[2] + 0.12, e[3] + 0.12, 1 },
      plateEdgeSelected = { e[1] + 0.25, e[2] + 0.25, e[3] + 0.25, 1 },
    }
    def.tabs = {
      plateIdle         = Plate(p, 0.88),
      plateHover        = { p[1] + 0.04, p[2] + 0.04, p[3] + 0.04, 0.92 },
      plateSelected     = { p[1] + 0.08, p[2] + 0.08, p[3] + 0.08, 0.96 },
      plateFlagged      = Plate(p, 0.88),
      plateEdge         = Plate(e, 0.90),
      plateEdgeHover    = { e[1] + 0.10, e[2] + 0.10, e[3] + 0.10, 1 },
      plateEdgeSelected = Plate(look.trim, 0.85),
      plateBevel        = { 1, 1, 1, 0.05 },
      plateHighlight    = { 1, 1, 1, 0.05 },
      accentWash        = { 0, 0, 0, 0 },
      captionToken      = "tabCaption",
    }
  end

  function def.Setup()
    -- The world has loaded by the first window: a faction unknown at login
    -- (very early, or none yet) is asked again. Only the emblem follows; the
    -- palette was claimed with the side known then.
    if not def.faction then def.faction = Faction() end
    -- An emblem only on the side's own chrome: a faction learnt after the
    -- claim keeps the neutral look, and no emblem, until a /reload.
    local list = def.faction and Side(def.faction) == def.side and EMBLEMS[def.faction]
    local T = ns.Theme
    def.emblem = nil
    if list and T and T.AtlasExists then
      for i = 1, #list do
        if T.AtlasExists(list[i].atlas) then def.emblem = list[i] break end
      end
    end
  end

  local CORNERS = {
    { "TOPLEFT", 1, -1, nil }, { "TOPRIGHT", -1, -1, "h" },
    { "BOTTOMLEFT", 1, 1, "v" }, { "BOTTOMRIGHT", -1, 1, "hv" },
  }

  local function Corners(art, part, size, inset, tint)
    for i = 1, 4 do
      local spec = CORNERS[i]
      local tex = CS.Tex(art, "ARTWORK", 1)
      CS.Part(tex, ATLAS, part, spec[4])
      tex:SetSize(size, size)
      tex:SetPoint(spec[1], art, spec[1], spec[2] * inset, spec[3] * inset)
      CS.Tinted(art, tex, tint)
    end
  end

  -- The Alliance frame: a dark keyline, the double gold trim (code), the
  -- filigree in each corner (one drawing, mirrored) and a gold rule under the
  -- title.
  local function BuildAlliance(art)
    local edge = CS.Frame4(art, "BORDER", 0)
    CS.LayFrame4(edge, art, 0, 1)
    CS.TintAll(edge, colors.edge)
    local outer = CS.Frame4(art, "BORDER", 1)
    CS.LayFrame4(outer, art, 3, 1.2)
    local inner = CS.Frame4(art, "BORDER", 1)
    CS.LayFrame4(inner, art, 6, 0.8)
    for i = 1, 4 do
      CS.Tinted(art, outer[i], "trim")
      CS.Tinted(art, inner[i], "trim")
    end
    local rule = CS.Line(art, "BORDER", 1)
    rule:SetPoint("TOPLEFT", art, "TOPLEFT", 6, -25)
    rule:SetPoint("TOPRIGHT", art, "TOPRIGHT", -6, -25)
    rule:SetHeight(0.8)
    CS.Tinted(art, rule, "trim")
    Corners(art, PART.filigree, 28, 0, "trim")
  end

  -- The Horde frame: an iron edge with a lit inner line, the stitched seam
  -- inside it (a tile laid along each side), iron caps on the corners and an
  -- iron rule under the title.
  local function BuildHorde(art)
    local iron = CS.Frame4(art, "BORDER", 0)
    CS.LayFrame4(iron, art, 0, 3)
    local lit = CS.Frame4(art, "BORDER", 1)
    CS.LayFrame4(lit, art, 3, 0.8)
    for i = 1, 4 do
      CS.Tinted(art, iron[i], "edge")
      CS.Tinted(art, lit[i], "trim")
      lit[i]:SetAlpha(0.55)
    end
    local seams = {}
    for i = 1, 4 do
      seams[i] = CS.Tex(art, "BORDER", 2, STITCH, "REPEAT")
      CS.Tinted(art, seams[i], "thread")
    end
    local s, w = 5, 2
    seams[1]:SetPoint("TOPLEFT", art, "TOPLEFT", s, -s)
    seams[1]:SetPoint("TOPRIGHT", art, "TOPRIGHT", -s, -s)
    seams[1]:SetHeight(w)
    seams[2]:SetPoint("BOTTOMLEFT", art, "BOTTOMLEFT", s, s)
    seams[2]:SetPoint("BOTTOMRIGHT", art, "BOTTOMRIGHT", -s, s)
    seams[2]:SetHeight(w)
    seams[3]:SetPoint("TOPLEFT", art, "TOPLEFT", s, -s - w)
    seams[3]:SetPoint("BOTTOMLEFT", art, "BOTTOMLEFT", s, s + w)
    seams[3]:SetWidth(w)
    seams[4]:SetPoint("TOPRIGHT", art, "TOPRIGHT", -s, -s - w)
    seams[4]:SetPoint("BOTTOMRIGHT", art, "BOTTOMRIGHT", -s, s + w)
    seams[4]:SetWidth(w)
    art.seams = seams
    local rule = CS.Line(art, "BORDER", 3)
    rule:SetPoint("TOPLEFT", art, "TOPLEFT", 3, -25)
    rule:SetPoint("TOPRIGHT", art, "TOPRIGHT", -3, -25)
    rule:SetHeight(1)
    CS.Tinted(art, rule, "trim")
    rule:SetAlpha(0.7)
    Corners(art, PART.cap, 14, 0, "trim")
  end

  local function BuildEmblem(art)
    local e = def.emblem
    if not e then return end
    local tex = art:CreateTexture(nil, "OVERLAY", nil, 1)
    tex:SetAtlas(e.atlas, false)
    tex:SetSize(e.w, e.h)
    local title = art.frame.TitleText
    if title then
      tex:SetPoint("RIGHT", title, "LEFT", -6, 0)
    else
      tex:SetPoint("LEFT", art, "TOPLEFT", def.inset + 24, -12.5)
    end
    art.emblem = tex
  end

  function def.Build(art)
    if def.side == "alliance" then BuildAlliance(art) else BuildHorde(art) end
    BuildEmblem(art)
  end

  function def.Layout(art, w, h)
    local seams = art.seams
    if seams then
      local run = w - 10
      local rise = h - 14
      seams[1]:SetTexCoord(0, run / 8, 0, 1)
      seams[2]:SetTexCoord(0, run / 8, 0, 1)
      -- The vertical runs: the same tile turned a quarter, along the side.
      local n = rise / 8
      seams[3]:SetTexCoord(0, 1, n, 1, 0, 0, n, 0)
      seams[4]:SetTexCoord(0, 1, n, 1, 0, 0, n, 0)
    end
    -- The emblem only where the title leaves it room: clear of the cog and
    -- the arrange key beside it (about 60 units from the inset).
    local emblem = art.emblem
    if emblem then
      local title = art.frame.TitleText
      local tw = title and title.GetStringWidth and title:GetStringWidth() or 0
      local room = w / 2 - tw / 2 - 6 - (def.inset + 60)
      emblem:SetShown(room >= def.emblem.w)
    end
  end

  return def
end)
