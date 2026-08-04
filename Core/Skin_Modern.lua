local _, ns = ...

-- =====================================================================
-- Postbox :: "Postbox Modern" first-party skin (optional, chosen in options)
-- ---------------------------------------------------------------------
-- A clean flat look for players on the plain Blizzard UI who want less
-- Blizzard: near-black surfaces, hairline borders, the accent doing all the
-- talking. It is a SKIN, not a theme fork -- it claims ns.Skin and rides the
-- exact contract the EllesmereUI and ElvUI skins ride (Apply / Refresh over
-- tagged children), so every window that knows how to be host-skinned is
-- Modern-skinnable for free, now and in the future.
--
-- Precedence is structural and absolute: if EllesmereUI or ElvUI is
-- installed this file never claims, whatever the style option says -- those
-- skins inherit a whole UI's look and outrank a first-party palette. The
-- style option is read ONCE, at PLAYER_LOGIN, which is why changing it asks
-- for a /reload instead of pretending to restyle a half-built session.
-- =====================================================================

local Skin = {}

local WHITE = "Interface\\AddOns\\Postbox\\Media\\white8x8.tga"

-- One flat family, black-boned. The accent is read live from ns.Theme at
-- every paint, so the palette carries no colour of its own beyond greys.
local C = {
  window = { 0.055, 0.055, 0.065, 0.94 },
  panel  = { 0.090, 0.090, 0.105, 0.92 },
  input  = { 0.050, 0.050, 0.060, 0.95 },
  button = { 0.120, 0.120, 0.140, 0.95 },
  -- A LIGHT hairline, not black. Pure black borders were the flat look's
  -- worst idea: on near-black fills they are darker than everything around
  -- them, so every place two elements sit close -- a field under a label, a
  -- button inside a card, a card inside the window -- stacked two or three
  -- black lines into a smear that read as dirt on the panel. A faint white
  -- edge separates by LIGHT, which is what a modern flat UI actually does,
  -- and two adjacent hairlines simply read as one slightly brighter one.
  border = { 1.000, 1.000, 1.000, 0.085 },
  -- The title strip: a shade above the window so the bar holding the title,
  -- the cog and the close button reads as chrome rather than as more panel.
  title  = { 0.105, 0.105, 0.122, 0.95 },
}

-- Title-bar height for the Blizzard window templates Postbox builds on.
local TITLE_HEIGHT = 22

-- One physical pixel at this frame's scale, not one UI unit. At a UI scale
-- that is not a whole ratio of the screen, a "1" edge lands on a fraction
-- of a physical pixel and the client rounds each side independently -- so
-- one border renders 1px on the left and 2px on the right, which is exactly
-- the non-uniformity a flat skin cannot hide. Snapping the size to the
-- nearest real pixel makes every edge the same weight everywhere.
local function Hairline(frame)
  local scale = (frame and frame.GetEffectiveScale and frame:GetEffectiveScale()) or 1
  if PixelUtil and PixelUtil.GetNearestPixelSize then
    local ok, size = pcall(PixelUtil.GetNearestPixelSize, 1, scale, 1)
    if ok and type(size) == "number" and size > 0 then return size end
  end
  if scale > 0 then
    local size = math.max(1, math.floor(scale + 0.5)) / scale
    return size
  end
  return 1
end

local function Accent()
  if ns.Theme and ns.Theme.GetAccent then return ns.Theme.GetAccent() end
  return 1.0, 0.82, 0.0
end

-- ------------------------------------------------------------------
-- Appearance settings
--
-- The same contract Core/Skin_EllesmereUI.lua publishes, so Core/OptionsPanel
-- builds the identical three controls without knowing which skin answers them.
-- Under a host UI those controls read that UI's own configuration and default
-- to "match it"; here there is nothing above us to match, so the default is
-- simply what this skin was authored with.
--
-- Modern draws one border and it is a faint LIGHT hairline, so "style" cannot
-- mean a texture the way it does for a UI pack. It means weight of light --
-- how present the edge is -- and size means how thick. Both are worth asking:
-- a thin bright edge and a thick faint one are different looks, not the same
-- one twice.
--
-- All three apply to the WINDOW's outer edge and fill only. The hairlines
-- between panels, inputs and buttons inside it stay fixed: they are what
-- separates one control from the next, and a player asking for a heavier
-- window border is not asking for every seam in the window to thicken.
-- ------------------------------------------------------------------

local BORDER_NONE = "none"
-- `light` is the authored default and must stay exactly what it was: it is the
-- edge the whole flat look was tuned around. `strong` is a long way above it
-- rather than a nudge -- three choices a player cannot tell apart are one
-- choice with two decoys, and against a near-black fill 0.20 was still reading
-- as "the same line again".
local BORDER_ALPHA = { none = 0, light = 0.085, strong = 0.320 }
local BORDER_ORDER = { BORDER_NONE, "light", "strong" }
local BORDER_NAME_KEY = {
  none   = "OPT_BORDER_NONE",
  light  = "OPT_BORDER_LIGHT",
  strong = "OPT_BORDER_STRONG",
}

local DEFAULT_BORDER_STYLE = "light"
local DEFAULT_BORDER_SIZE  = 1
-- Read from the palette rather than written twice, so the authored alpha stays
-- the single source of what "default" means.
local DEFAULT_BG_OPACITY   = C.window[4]

local function GetProfile()
  return ns.Store.EnsurePath("profile", {})
end

function Skin.GetBorderChoices()
  local out = {}
  for i = 1, #BORDER_ORDER do
    local key = BORDER_ORDER[i]
    out[i] = { key = key, name = ns.L[BORDER_NAME_KEY[key]] }
  end
  return out
end

function Skin.GetBorderStyle()
  local saved = GetProfile().modernBorder
  if BORDER_ALPHA[saved] then return saved end
  return DEFAULT_BORDER_STYLE
end

function Skin.IsBorderDefault()
  return GetProfile().modernBorder == nil
end

function Skin.SetBorderStyle(key)
  if not BORDER_ALPHA[key] then return end
  GetProfile().modernBorder = key
  Skin.ApplyAppearance()
end

function Skin.ResetBorder()
  GetProfile().modernBorder = nil
  Skin.ApplyAppearance()
end

function Skin.GetBorderSize()
  local saved = tonumber(GetProfile().modernBorderSize)
  if saved then return math.max(1, math.min(4, saved)) end
  return DEFAULT_BORDER_SIZE
end

function Skin.IsBorderSizeDefault()
  return GetProfile().modernBorderSize == nil
end

function Skin.SetBorderSize(step)
  GetProfile().modernBorderSize = tonumber(step) or DEFAULT_BORDER_SIZE
  Skin.ApplyAppearance()
end

function Skin.ResetBorderSize()
  GetProfile().modernBorderSize = nil
  Skin.ApplyAppearance()
end

function Skin.GetBgOpacity()
  local saved = tonumber(GetProfile().modernBgOpacity)
  if saved then return math.max(0, math.min(1, saved)) end
  return DEFAULT_BG_OPACITY
end

function Skin.IsBgOpacityDefault()
  return GetProfile().modernBgOpacity == nil
end

function Skin.SetBgOpacity(value)
  GetProfile().modernBgOpacity = math.max(0, math.min(1, tonumber(value) or 1))
  Skin.ApplyAppearance()
end

function Skin.ResetBgOpacity()
  GetProfile().modernBgOpacity = nil
  Skin.ApplyAppearance()
end

-- The title strip is part of the window, so it fades with it -- a solid bar
-- floating over a transparent window would read as a separate object. It is
-- told apart from the window by COLOUR (0.105 against 0.055), not by opacity,
-- so it stays distinguishable at every setting that shows anything at all.
--
-- Scaled rather than set, so the authored pair survives exactly at the default:
-- 0.94 * (0.95/0.94) is 0.95, the value written in the palette.
function Skin.TitleAlpha()
  local ratio = (DEFAULT_BG_OPACITY > 0) and (C.title[4] / DEFAULT_BG_OPACITY) or 1
  return math.max(0, math.min(1, Skin.GetBgOpacity() * ratio))
end

-- Every window this skin has painted. Weak-keyed, so a window going away takes
-- its entry with it. Appearance changes apply to all of them at once -- the
-- options panel is a Postbox window too, and watching it take the change you
-- just made is most of how you judge the change.
Skin._windows = setmetatable({}, { __mode = "k" })

-- ------------------------------------------------------------------
-- Primitives
-- ------------------------------------------------------------------

local function EnsureBackdrop(frame)
  if type(frame.SetBackdrop) == "function" then return true end
  if type(Mixin) ~= "function" or type(BackdropTemplateMixin) ~= "table" then return false end
  Mixin(frame, BackdropTemplateMixin)
  if type(frame.OnBackdropSizeChanged) == "function" then
    frame:HookScript("OnSizeChanged", frame.OnBackdropSizeChanged)
  end
  return true
end

-- `outer` marks the window's own frame -- the one edge and fill the appearance
-- settings speak for. Everything else keeps the authored hairline: those seams
-- separate one control from the next and are not what "window border" means.
local function Paint(frame, color, outer)
  if not EnsureBackdrop(frame) then return end

  local unit = Hairline(frame)
  local edge, alpha = unit, C.border[4]
  local fill = color[4]

  if outer then
    edge  = unit * Skin.GetBorderSize()
    alpha = BORDER_ALPHA[Skin.GetBorderStyle()] or C.border[4]
    fill  = Skin.GetBgOpacity()
  end

  -- Built per frame rather than shared: the edge is scale-dependent, and a
  -- shared table would hand one frame's snapped size to a frame at another
  -- scale (a popup at a different strata, a host UI's own scaling).
  frame:SetBackdrop({
    bgFile = WHITE,
    edgeFile = WHITE,
    -- A zero edgeSize is not "no border", it is an invalid backdrop that the
    -- client draws unpredictably. None is expressed as a real edge at zero
    -- alpha, which is nothing to look at and well-defined to draw.
    edgeSize = math.max(edge, unit),
    -- ZERO, and this is the whole reason a wide border used to look like a
    -- bite taken out of the window.
    --
    -- `insets` do not describe the border, they hold the BACKGROUND back from
    -- the frame's edge. That is right for an opaque border, which would cover
    -- the gap it makes. This border is a faint light line -- 0.085 alpha, 92%
    -- see-through -- so insetting the fill by its width did not draw a wider
    -- border, it carved a transparent ring out of the window and put almost
    -- nothing in it. The wider the setting, the more window went missing; at
    -- one pixel it was invisible, which is why this survived until the size
    -- became adjustable.
    --
    -- At zero the fill runs to the frame's edge and the line sits ON it,
    -- brightening the outermost pixels. Which is what "separates by light"
    -- meant in the first place.
    insets = { left = 0, right = 0, top = 0, bottom = 0 },
  })
  frame:SetBackdropColor(color[1], color[2], color[3], fill)
  frame:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], alpha)
end

-- Repaint every window's outer edge, fill and title strip from the current
-- settings. Safe to call any time; windows this skin never painted are not in
-- the registry and are left alone.
--
-- Defined here rather than up with the accessors that call it because it needs
-- Paint, which is a local: referenced any earlier it would resolve as a global
-- and silently do nothing.
function Skin.ApplyAppearance()
  for frame in pairs(Skin._windows) do
    if frame then
      pcall(function()
        Paint(frame, C.window, true)
        local strip = frame.__pbModernStrip
        if strip then
          strip:SetColorTexture(C.title[1], C.title[2], C.title[3], Skin.TitleAlpha())
        end
      end)
    end
  end
end

-- The themed panels already carry a backdrop and the stone grain; Modern
-- does not strip them, it re-dresses them -- grain off, flat colours on.
-- Idempotent via the same key both host skins use, so a later host-skin
-- activation (ns.SkinAppliedBy) knows the window is spoken for.
local function FlatPanel(panel, color)
  if not panel or panel.__postboxSkinned then return end
  panel.__postboxSkinned = true
  if panel.pbSurfaceTexture then panel.pbSurfaceTexture:SetAlpha(0) end
  Paint(panel, color or C.panel)
end

local function FlatButton(button)
  if not button or button.__postboxSkinned then return end
  button.__postboxSkinned = true
  for _, region in ipairs({ button:GetRegions() }) do
    if region.IsObjectType and region:IsObjectType("Texture") then
      region:SetTexture(nil)
      region:Hide()
    end
  end
  Paint(button, C.button)
  button:SetHighlightTexture(WHITE)
  local hover = button:GetHighlightTexture()
  if hover then
    hover:SetAllPoints()
    hover:SetAlpha(0.06)
  end
end

-- The window's own title strip. The templates draw theirs as part of the
-- art QuietTemplateArt silences, so without this the title, the cog and the
-- close button float on the same flat field as the content -- every other
-- Postbox look distinguishes that bar, and so should this one.
local function TitleStrip(frame)
  if frame.__pbModernTitle then return end
  frame.__pbModernTitle = true

  local edge = Hairline(frame)
  local strip = frame:CreateTexture(nil, "BACKGROUND", nil, 1)

  -- Height from the template's own title area, width from the WINDOW. Four
  -- cardinal anchors, each contributing one edge, because the two come from
  -- different frames:
  --
  --   * vertical from TitleBg, because the title text, the close button and
  --     the cog are all positioned against it -- a strip of some other
  --     height leaves all three looking low inside their own bar;
  --   * horizontal from the window, because TitleBg is inset and stops
  --     short of the close button. Taking BOTH from TitleBg (1.30.1) left a
  --     gap at the left edge and stranded the close button outside the bar,
  --     which is what made it look boxed off.
  if frame.TitleBg then
    strip:SetPoint("LEFT", frame, "LEFT", edge, 0)
    strip:SetPoint("RIGHT", frame, "RIGHT", -edge, 0)
    strip:SetPoint("TOP", frame.TitleBg, "TOP", 0, 0)
    strip:SetPoint("BOTTOM", frame.TitleBg, "BOTTOM", 0, 0)
  else
    strip:SetPoint("TOPLEFT", frame, "TOPLEFT", edge, -edge)
    strip:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -edge, -edge)
    strip:SetHeight(TITLE_HEIGHT)
  end
  frame.__pbModernStrip = strip
  strip:SetColorTexture(C.title[1], C.title[2], C.title[3], Skin.TitleAlpha())

  -- One hairline under it, the same light edge the panels use, so the bar
  -- ends on a line rather than fading into the content.
  local rule = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
  rule:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, 0)
  rule:SetPoint("TOPRIGHT", strip, "BOTTOMRIGHT", 0, 0)
  rule:SetHeight(edge)
  rule:SetColorTexture(C.border[1], C.border[2], C.border[3], C.border[4])

  -- Everything that lives in the bar is centred ON THE BAR, rather than
  -- left wherever the template put it relative to art this skin has just
  -- hidden. Three releases of nudging single pixels -- the cog by two, the
  -- title by one, the close button by whatever it took -- were all attempts
  -- to guess offsets that the template measures from a different origin
  -- than the strip does. Anchoring them to the strip makes the question go
  -- away: one reference, three children, aligned by construction.
  --
  -- Only under this skin. The other looks keep the template's own bar, and
  -- their offsets are correct for it.
  if frame.TitleText then
    frame.TitleText:ClearAllPoints()
    frame.TitleText:SetPoint("CENTER", strip, "CENTER", 0, 0)
  end
  if frame.CloseButton then
    frame.CloseButton:ClearAllPoints()
    frame.CloseButton:SetPoint("RIGHT", strip, "RIGHT", -3, 0)
  end
  if frame.OptionsButton then
    frame.OptionsButton:ClearAllPoints()
    frame.OptionsButton:SetPoint("LEFT", strip, "LEFT", 5, 0)
  end
end

-- Postbox's lists use UIPanelScrollFrameTemplate, whose bar is the classic
-- three-piece slider. Same treatment the EllesmereUI skin gives it: the art
-- goes, the thumb becomes a thin bright bar. Scroll BEHAVIOUR is untouched
-- -- these are ordinary UI frames with no protected state, so restyling
-- them carries no taint or combat consequence whatsoever.
local function FlatScrollBar(sb)
  if not sb or sb.__pbModernBar then return end
  sb.__pbModernBar = true

  for _, key in ipairs({ "ScrollUpButton", "ScrollDownButton" }) do
    local b = sb[key]
    if b then
      for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture",
                                "GetDisabledTexture", "GetHighlightTexture" }) do
        local fn = b[getter]
        local t = fn and fn(b)
        if t then t:SetAlpha(0) end
      end
    end
  end

  for _, region in ipairs({ sb:GetRegions() }) do
    if region.IsObjectType and region:IsObjectType("Texture") then
      region:SetAlpha(0)
    end
  end

  -- Modern clients hand back the newer bar instead; it keeps its pieces as
  -- named children rather than plain regions.
  for _, key in ipairs({ "Back", "Forward" }) do
    local b = sb[key]
    if b then
      for _, r in ipairs({ b:GetRegions() }) do
        if r.IsObjectType and r:IsObjectType("Texture") then r:SetAlpha(0) end
      end
    end
  end
  if sb.Track then
    for _, r in ipairs({ sb.Track:GetRegions() }) do
      if r.IsObjectType and r:IsObjectType("Texture") then r:SetAlpha(0) end
    end
  end

  local thumb = sb.GetThumbTexture and sb:GetThumbTexture()
  if thumb then
    thumb:SetTexture(nil)
    thumb:SetColorTexture(1, 1, 1, 0.30)
    thumb:SetWidth(4)
    -- Region alpha and colour alpha multiply, and the sweep above set every
    -- region -- this thumb included -- to zero.
    thumb:SetAlpha(1)
  end
end

local function FlatScroll(sf)
  if not sf then return end
  local name = sf.GetName and sf:GetName()
  FlatScrollBar(sf.ScrollBar or (name and _G[name .. "ScrollBar"]))
end

-- The template's close button is a chunky gold-ringed X that survives every
-- other repaint because it is Blizzard art on a Blizzard button. Modern
-- draws its own from two rotated bars of the addon's white tile: crisp at
-- any size, override-proof, and accent-lit on hover like everything else.
local function FlatClose(button)
  if not button or button.__pbModernClose then return end
  button.__pbModernClose = true

  for _, region in ipairs({ button:GetRegions() }) do
    if region.IsObjectType and region:IsObjectType("Texture") then
      region:SetTexture(nil)
      region:Hide()
    end
  end

  local bars = {}
  for _, angle in ipairs({ math.rad(45), math.rad(-45) }) do
    local bar = button:CreateTexture(nil, "ARTWORK")
    bar:SetTexture(WHITE)
    bar:SetSize(11, 1.5)
    bar:SetPoint("CENTER")
    if bar.SetRotation then bar:SetRotation(angle) end
    bars[#bars + 1] = bar
  end

  local function Tint(r, g, b)
    for i = 1, #bars do bars[i]:SetVertexColor(r, g, b) end
  end
  Tint(0.62, 0.62, 0.66)
  button:HookScript("OnEnter", function() Tint(Accent()) end)
  button:HookScript("OnLeave", function() Tint(0.62, 0.62, 0.66) end)
end

-- ------------------------------------------------------------------
-- The recursive pass over tagged content, same shape as the host skins'.
-- Native controls (checkboxes, scrollbars, close buttons, edit boxes) stay
-- native on purpose: Modern is a surface treatment, not a widget kit.
-- ------------------------------------------------------------------

local function SkinTree(frame, depth)
  if not frame or depth > 8 then return end
  local kids = { frame:GetChildren() }
  for i = 1, #kids do
    local c = kids[i]
    if c and c.IsObjectType then
      if c.__postboxPanel then
        FlatPanel(c, c.__postboxPanel == "band" and C.window or C.panel)
      elseif c.__postboxInputWrap then
        FlatPanel(c, C.input)
      elseif c:IsObjectType("ScrollFrame") then
        FlatScroll(c)
      elseif c:IsObjectType("Button") then
        if c.__postboxButton then FlatButton(c) end
      end
    end
    SkinTree(c, depth + 1)
  end
end

function Skin.Refresh(frame)
  if not frame then return end
  pcall(function() SkinTree(frame, 0) end)
  -- Popups built lazily (the bug report, the recipient add/note dialogs)
  -- arrive after Apply and carry their own small close button.
  pcall(function() FlatClose(frame.CloseButton) end)
end

-- ------------------------------------------------------------------
-- Tooltips
--
-- Postbox's own tooltips arrive on the shared GameTooltip, which under a
-- host UI is already that UI's -- EllesmereUI and ElvUI both skin it
-- globally, so those sessions need nothing from us. On a stock UI it stays
-- Blizzard's, which beside a flat black window looks like a leftover.
--
-- Rerouting 200-odd call sites onto a private tooltip frame is the textbook
-- answer and the wrong trade: it is a sweeping change for a cosmetic gain,
-- and a private frame would NOT inherit a host UI's styling. So the art is
-- swapped in place instead, and only while the tooltip belongs to us: the
-- template's nine-slice steps aside for our own fill and hairline, and
-- steps straight back for every other tooltip in the game. Nothing is
-- destroyed, so there is nothing to restore incorrectly.
-- ------------------------------------------------------------------

local function IsOurs(owner)
  local frame = owner
  for _ = 1, 6 do
    if type(frame) ~= "table" then return false end
    if frame.__pbTooltipOwner then return true end
    local name = frame.GetName and frame:GetName()
    if type(name) == "string" and name:find("^Postbox") then return true end
    frame = frame.GetParent and frame:GetParent() or nil
  end
  return false
end

local function DressTooltip(tip, ours)
  if not tip then return end

  if not tip.__pbModernSkin then
    tip.__pbModernSkin = true
    local edge = Hairline(tip)
    local fill = tip:CreateTexture(nil, "BACKGROUND", nil, -8)
    fill:SetPoint("TOPLEFT", tip, "TOPLEFT", edge, -edge)
    fill:SetPoint("BOTTOMRIGHT", tip, "BOTTOMRIGHT", -edge, edge)
    fill:SetColorTexture(C.window[1], C.window[2], C.window[3], 0.96)
    fill:Hide()

    -- Four hairlines rather than a backdrop: GameTooltip resizes itself
    -- constantly, and edge textures anchored to its corners follow for
    -- free where a backdrop would need re-applying on every resize.
    local edges = {}
    local specs = {
      { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
      { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false },
    }
    for i = 1, #specs do
      local line = tip:CreateTexture(nil, "BORDER")
      line:SetPoint(specs[i][1], tip, specs[i][1], 0, 0)
      line:SetPoint(specs[i][2], tip, specs[i][2], 0, 0)
      if specs[i][3] then line:SetHeight(edge) else line:SetWidth(edge) end
      line:SetColorTexture(C.border[1], C.border[2], C.border[3], 0.35)
      line:Hide()
      edges[i] = line
    end

    tip.__pbFill = fill
    tip.__pbEdges = edges
  end

  tip.__pbFill:SetShown(ours)
  for i = 1, #tip.__pbEdges do tip.__pbEdges[i]:SetShown(ours) end
  -- The template's own art is the thing being replaced, so it is the thing
  -- that steps aside -- and comes straight back for everyone else's
  -- tooltips.
  if tip.NineSlice then tip.NineSlice:SetShown(not ours) end
end

local tooltipHooked = false
local function HookTooltips()
  if tooltipHooked or type(hooksecurefunc) ~= "function" then return end

  -- GameTooltip is SHARED, and a host UI skins it for the whole interface.
  -- This skin can now be chosen while EllesmereUI or ElvUI is installed, so
  -- that is no longer hypothetical: swapping the art in place under one would
  -- mean two addons trading the same frame's backdrop back and forth, and the
  -- art we hand back would be the template's rather than theirs.
  --
  -- Choosing Modern is a statement about POSTBOX'S WINDOWS. It is not a licence
  -- to restyle a frame the rest of the interface also uses, so under a host UI
  -- the tooltip stays entirely theirs.
  if _G.EllesmereUI or _G.ElvUI then return end

  tooltipHooked = true
  hooksecurefunc(GameTooltip, "SetOwner", function(self, owner)
    DressTooltip(self, IsOurs(owner))
  end)
  -- Blizzard reuses the tooltip for its own frames without always going
  -- through SetOwner; the hide is the reliable moment to hand the art back.
  GameTooltip:HookScript("OnHide", function(self)
    DressTooltip(self, false)
  end)
end

-- ------------------------------------------------------------------
-- The window shell
-- ------------------------------------------------------------------

-- Hide a Blizzard window template's own art without ElvUI's StripTextures:
-- every texture region on the frame itself and on the named chrome children.
local function QuietTemplateArt(frame)
  local function hideTextures(holder)
    if not holder then return end
    for _, region in ipairs({ holder:GetRegions() }) do
      if region.IsObjectType and region:IsObjectType("Texture") then
        region:SetAlpha(0)
      end
    end
  end
  hideTextures(frame)
  hideTextures(frame.NineSlice)
  hideTextures(frame.Inset)
  if frame.Inset then hideTextures(frame.Inset.NineSlice) end
  if frame.TitleBg then frame.TitleBg:SetAlpha(0) end
  if frame.Bg then frame.Bg:SetAlpha(0) end
end

function Skin.Apply(frame)
  if not frame or frame.__postboxSkinned then return end
  frame.__postboxSkinned = true

  -- The shared claim record: the EllesmereUI skin reads this and stands
  -- down rather than layering its shell over a stripped window -- the same
  -- contract the ElvUI skin honours (see that file's Apply).
  ns.SkinAppliedBy = "modern"

  for _, key in ipairs({ "pbWindowStone", "pbWindowTint" }) do
    if frame[key] then frame[key]:SetAlpha(0) end
  end

  QuietTemplateArt(frame)
  -- Registered before the paint, so a window built while the panel is open is
  -- already on the list the next appearance change walks.
  Skin._windows[frame] = true
  Paint(frame, C.window, true)
  TitleStrip(frame)
  FlatClose(frame.CloseButton)
  -- Every window this skin paints is a tooltip owner worth recognising,
  -- including its unnamed children (IsOurs walks up to find this).
  frame.__pbTooltipOwner = true
  HookTooltips()

  -- Tabs: installing the selection override retires the widget's own plate
  -- art (Core/Theme.lua contract); Modern answers with an accent underline
  -- and accent text, the same statement the host skins make.
  if frame.TabButtons then
    for _, tab in pairs(frame.TabButtons) do
      if tab and not tab.__postboxSkinned then
        tab.__postboxSkinned = true

        if not tab.__activeAccent then
          tab.__activeAccent = tab:CreateTexture(nil, "OVERLAY")
          tab.__activeAccent:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 2, 1)
          tab.__activeAccent:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -2, 1)
          tab.__activeAccent:SetHeight(2)
          tab.__activeAccent:Hide()
        end

        tab.__setSelectedOverride = function(t, selected)
          t:Enable()
          local r, g, b = Accent()
          local fs = t.GetFontString and t:GetFontString()
          if fs then
            fs:ClearAllPoints()
            fs:SetPoint("CENTER", t, "CENTER", 0, 0)
            if selected then
              fs:SetTextColor(r, g, b)
            else
              fs:SetTextColor(0.72, 0.72, 0.75)
            end
          end
          if t.__activeBg then t.__activeBg:Hide() end
          if t.__activeAccent then
            t.__activeAccent:SetColorTexture(r, g, b, 0.9)
            t.__activeAccent:SetShown(selected)
          end
        end
      end
    end

    local active = ns.MailboxUI and ns.MailboxUI._state and ns.MailboxUI._state.activeTab
    if active and ns.Theme and ns.Theme.SetTabSelected then
      for _, tab in pairs(frame.TabButtons) do
        ns.Theme.SetTabSelected(tab, tab.tabId == active)
      end
    end
  end

  Skin.Refresh(frame)
end

-- ------------------------------------------------------------------
-- Claim: last in line, and only when invited
-- ------------------------------------------------------------------

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
  self:UnregisterEvent("PLAYER_LOGIN")

  local UI = ns.MailboxUI
  if not (UI and type(UI.GetStyleChoice) == "function") then return end
  if UI.GetStyleChoice() ~= "modern" then return end

  -- A host UI being installed no longer settles this. It used to: the rule was
  -- that a host skin inherits a whole interface's look and outranks a
  -- first-party palette, absolutely. That is a good default and it is still the
  -- default -- "host" is what GetStyleChoice returns wherever one is installed
  -- -- but it is now a default rather than a law, because a player who prefers
  -- this look to their pack's had no way to say so.
  --
  -- No race with the host skins: reaching here means the player chose "modern",
  -- and both of them consult UI.HostSkinAllowed() before claiming, so neither
  -- will. The ns.Skin guard stays for the ordinary case of something else
  -- having claimed first.
  if ns.Skin then return end
  ns.Skin = Skin
end)
