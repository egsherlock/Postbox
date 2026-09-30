local _, ns = ...

-- =====================================================================
-- Postbox :: creative window style "Goblin Express"
-- ---------------------------------------------------------------------
-- The auction house's goblins run the post: riveted green steel plate, a
-- heavy steel rim with rivets down the sides, hazard stripes under the
-- title and round All mail, a lamp on each window tab that is lit on the
-- open one, and a sight-glass tank beside the title (the v2 fix for a dial
-- that read as a clock). The tank is how full the inbox is: its share of
-- the 50 mails the game shows at a time, green up to 80%, amber up to 96%,
-- red past that. It is filled on the Mail tab caption's own pass
-- (Skin.OnMailState), a width and a colour, and only when the count moved.
--
-- The odometer totals of round 1 are not built: the totals are one string
-- the list fits to the band's width, and wheels per digit would be a second
-- layout of it.
-- =====================================================================

local CS = ns.CreativeStyles
if not CS then return end

-- Built at login only when this is the chosen style (Core/Skin_Creative.lua).
CS.Register("goblin", "OPT_STYLE_GOBLIN", function()
  local floor, max, min = math.floor, math.max, math.min

  local DIR = CS.MEDIA .. "Goblin\\"

  local ATLAS = { file = DIR .. "goblin-parts.tga", w = 128, h = 64 }
  local PART = {
    rim     = { x = 1,  y = 1,  w = 28, h = 28, c = 12 },
    rivet   = { x = 31, y = 1,  w = 6,  h = 6 },
    lampOn  = { x = 39, y = 1,  w = 8,  h = 8 },
    lampOff = { x = 49, y = 1,  w = 8,  h = 8 },
    tank    = { x = 1,  y = 31, w = 88, h = 14 },
  }
  local HAZARD = DIR .. "goblin-hazard.tga"   -- 16 x 8 units, repeats along x

  -- The inbox the game shows at a time, and the tank's thresholds.
  local INBOX_SHOWN = 50
  local AMBER_AT, RED_AT = 0.80, 0.96
  local GREEN = { 0.34, 0.86, 0.26 }
  local AMBER = { 0.96, 0.64, 0.12 }
  local RED   = { 0.92, 0.20, 0.13 }

  local colors = {
    steel = { 0.40, 0.52, 0.28 },
    rim   = { 0.50, 0.62, 0.36 },
    rivet = { 0.74, 0.82, 0.64 },
  }

  local def = {
    key = "goblin",
    nameKey = "OPT_STYLE_GOBLIN",
    inset = 13,
    ground = { file = DIR .. "goblin-steel.tga", unit = 64, inset = 2, tint = "steel" },
    rivets = { atlas = ATLAS, part = PART.rivet, spacing = 64, top = 42, bottom = 16, x = 4.5, tint = "rivet" },
    trim = "rim",
    titleBand = { 0.02, 0.03, 0.01, 0.35 },
    bandInset = 2,
    colors = colors,
    palette = {
      accent      = { 0.96, 0.78, 0.20, 1 },
      button      = { 0.16, 0.22, 0.12, 0.95 },
      buttonEdge  = { 0.05, 0.07, 0.04, 1 },
      select      = { 0.16, 0.22, 0.12, 0.95 },
      selectEdge  = { 0.30, 0.38, 0.20, 1 },
      tooltipEdge = { 0.58, 0.66, 0.30, 1 },
    },
    plates = {
      plateIdle         = { 0.13, 0.18, 0.10, 0.94 },
      plateHover        = { 0.18, 0.24, 0.13, 0.96 },
      plateSelected     = { 0.24, 0.31, 0.17, 0.99 },
      plateFlagged      = { 0.15, 0.20, 0.11, 0.95 },
      plateEdge         = { 0.04, 0.06, 0.03, 0.90 },
      plateEdgeHover    = { 0.36, 0.44, 0.24, 1 },
      plateEdgeSelected = { 0.55, 0.64, 0.34, 1 },
    },
    tabs = {
      plateIdle         = { 0.12, 0.17, 0.09, 0.90 },
      plateHover        = { 0.17, 0.23, 0.12, 0.93 },
      plateSelected     = { 0.22, 0.29, 0.15, 0.97 },
      plateFlagged      = { 0.12, 0.17, 0.09, 0.90 },
      plateEdge         = { 0.04, 0.06, 0.03, 0.95 },
      plateEdgeHover    = { 0.34, 0.42, 0.22, 1 },
      plateEdgeSelected = { 0.62, 0.56, 0.20, 1 },
      plateBevel        = { 1, 1, 1, 0.06 },
      plateHighlight    = { 1, 1, 1, 0.05 },
      accentWash        = { 0, 0, 0, 0 },
      captionToken      = "tabCaption",
    },
  }

  -------------------------------------------------------------
  -- The tank
  -------------------------------------------------------------

  local function BuildTank(art)
    local title = art.frame.TitleText
    local tank = CS.Tex(art, "ARTWORK", 4)
    CS.Part(tank, ATLAS, PART.tank)
    tank:SetSize(PART.tank.w, PART.tank.h)
    if title then
      tank:SetPoint("LEFT", title, "RIGHT", 10, 0)
    else
      tank:SetPoint("CENTER", art, "TOP", 70, -12.5)
    end
    -- The dark glass behind the liquid, and the liquid, laid under the tube.
    local back = CS.Line(art, "ARTWORK", 2)
    back:SetVertexColor(0.03, 0.04, 0.03, 0.90)
    back:SetPoint("TOPLEFT", tank, "TOPLEFT", 8, -2)
    back:SetPoint("BOTTOMRIGHT", tank, "BOTTOMRIGHT", -8, 2)
    local liquid = CS.Line(art, "ARTWORK", 3)
    liquid:SetPoint("TOPLEFT", tank, "TOPLEFT", 8, -2.5)
    liquid:SetHeight(PART.tank.h - 5)
    liquid:Hide()
    art.tank, art.liquid, art.fill = tank, liquid, -1
  end

  local function PaintTank(art, shown)
    local fill = min(1, max(0, (tonumber(shown) or 0) / INBOX_SHOWN))
    if fill == art.fill then return end
    art.fill = fill
    local liquid = art.liquid
    if fill <= 0 then
      liquid:Hide()
      return
    end
    local c = (fill < AMBER_AT) and GREEN or (fill < RED_AT) and AMBER or RED
    liquid:SetVertexColor(c[1], c[2], c[3], 0.95)
    liquid:SetWidth(max(1, (PART.tank.w - 16) * fill))
    liquid:Show()
  end

  -------------------------------------------------------------
  -- The tabs' lamps
  -------------------------------------------------------------

  local function PaintLamp(tab)
    local lamp = tab and tab.__pbLamp
    if not lamp then return end
    local on = tab.isSelected and true or false
    if lamp.on == on then return end
    lamp.on = on
    CS.Part(lamp, ATLAS, on and PART.lampOn or PART.lampOff)
  end

  local function BuildLamps(art)
    local tabs = art.frame.TabButtons
    if not tabs then return end
    for _, tab in pairs(tabs) do
      if tab and not tab.__pbLamp then
        local lamp = CS.Tex(tab, "OVERLAY", 1)
        lamp:SetSize(8, 8)
        lamp:SetPoint("CENTER", tab, "LEFT", 13, 0)
        tab.__pbLamp = lamp
        PaintLamp(tab)
      end
    end
  end

  function def.Setup()
    -- A tab's selection is painted through Theme.SetTabSelected (MailboxUI,
    -- UI.SelectTab); the lamp follows it there, only while this style is chosen.
    local T = ns.Theme
    if T and type(T.OnTabSelected) == "function" then T.OnTabSelected(PaintLamp) end
  end

  -------------------------------------------------------------
  -- The frame
  -------------------------------------------------------------

  local function Hazard(parent, layer, sub)
    return CS.Tex(parent, layer, sub, HAZARD, "REPEAT")
  end

  function def.Build(art)
    local rim = CS.Nine(art, ATLAS, PART.rim, "BORDER", 0)
    CS.LayNine(rim, art, 0)
    CS.TintedSet(art, rim, "rim")

    -- The stripe under the title, five units of the eight-unit tile so the
    -- stripes keep their angle.
    local stripe = Hazard(art, "BORDER", 3)
    stripe:SetPoint("TOPLEFT", art, "TOPLEFT", 8, -25)
    stripe:SetPoint("TOPRIGHT", art, "TOPRIGHT", -8, -25)
    stripe:SetHeight(5)
    art.stripe = stripe

    if art.main then
      BuildTank(art)
      BuildLamps(art)
    end
  end

  function def.Layout(art, w)
    if art.stripe then art.stripe:SetTexCoord(0, max(0.1, (w - 16) / 16), 0, 5 / 8) end
  end

  function def.OnMailState(art, open)
    if not art.tank then return end
    local shown = 0
    if open and type(GetInboxNumItems) == "function" then shown = tonumber((GetInboxNumItems())) or 0 end
    PaintTank(art, shown)
  end

  -- All mail inside a hazard frame: the stripes fill the button, a plate of
  -- the buttons' own colour four units in covers the middle.
  function def.DressSweep(button, _, primary)
    -- Only once the skin has painted the button (its pass clears every
    -- texture a button carries).
    if not (primary and button and button.__postboxSkinned) then return end
    local d = button.__pbGoblin
    if not d then
      d = { w = -1 }
      d.stripes = Hazard(button, "BACKGROUND", 1)
      d.stripes:SetAllPoints(button)
      d.plate = CS.Line(button, "BACKGROUND", 2)
      d.plate:SetPoint("TOPLEFT", button, "TOPLEFT", 4, -4)
      d.plate:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -4, 4)
      local c = def.palette.button
      d.plate:SetVertexColor(c[1], c[2], c[3], 1)
      d.edge = CS.Frame4(button, "BACKGROUND", 3)
      CS.LayFrame4(d.edge, d.plate, 0, 1)
      CS.TintAll(d.edge, def.palette.buttonEdge)
      button.__pbGoblin = d
    end
    local w = floor((button:GetWidth() or 0) + 0.5)
    if w ~= d.w then
      d.w = w
      CS.TileCoords(d.stripes, w, button:GetHeight() or 28, 16, 8)
    end
  end

  return def
end)
