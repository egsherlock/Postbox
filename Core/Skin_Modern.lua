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
  border = { 0.000, 0.000, 0.000, 1.00 },
}

local FLAT_BACKDROP = {
  bgFile = WHITE,
  edgeFile = WHITE,
  edgeSize = 1,
  insets = { left = 1, right = 1, top = 1, bottom = 1 },
}

local function Accent()
  if ns.Theme and ns.Theme.GetAccent then return ns.Theme.GetAccent() end
  return 1.0, 0.82, 0.0
end

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

local function Paint(frame, color)
  if not EnsureBackdrop(frame) then return end
  frame:SetBackdrop(FLAT_BACKDROP)
  frame:SetBackdropColor(color[1], color[2], color[3], color[4])
  frame:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], C.border[4])
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
  Paint(frame, C.window)
  FlatClose(frame.CloseButton)

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

  -- A host UI's skin inherits a whole interface's look; the first-party one
  -- never competes with that, whatever the option says. Host globals are
  -- settled by login, so this is a fact and not a race.
  if _G.EllesmereUI or _G.ElvUI then return end

  local UI = ns.MailboxUI
  if not (UI and type(UI.GetStyleChoice) == "function") then return end
  if UI.GetStyleChoice() ~= "modern" then return end
  if ns.Skin then return end
  ns.Skin = Skin
end)
