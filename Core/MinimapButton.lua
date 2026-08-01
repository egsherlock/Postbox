local _, ns = ...

-- =====================================================================
-- Postbox :: minimap mail icon
-- ---------------------------------------------------------------------
-- A replacement for the default "you have new mail" minimap indicator.
-- Behavioural spec: .dev/SPEC-MinimapIcon.md. The short version:
--
--   * Shows while HasNewMail() is true, hides when it is not -- the same
--     contract as MinimapCluster.IndicatorFrame.MailFrame, which this
--     suppresses (Hide + a Show hook) while the feature is on. Suppression
--     never reparents and never unregisters Blizzard's events: ElvUI
--     snapshots the frame's parent once and restores it forever after, and
--     keeping Blizzard's state machine intact is what makes live disable a
--     one-call restore.
--
--   * The button is UNNAMED on purpose. EllesmereUI's minimap module sweeps
--     named Buttons (and LibDBIcon10_* frames) parented to the Minimap into
--     its own drawer; a nameless button is structurally invisible to it, and
--     to the ProjectAzilroka-style collectors that key off names. Do not
--     "fix" this by naming the frame.
--
--   * Frame level is minimap + 20: above EllesmereUI's ping-blocker overlay
--     (+10) and ElvUI's click-handler child, level with EllesmereUI's own
--     indicators. Re-asserted on every re-layout because both hosts rebuild
--     the minimap at login and on profile switches.
-- =====================================================================

ns.MinimapButton = ns.MinimapButton or {}
local MB = ns.MinimapButton

local L = ns.L

local DEFAULTS = {
  enabled = false,   -- turning it on changes visible UI; that is the user's call
  icon    = "postbox",
  size    = 20,
  angle   = 212,     -- degrees, 0 = east, CCW; lower-left is the least
                     -- contested spot on all three host UIs
  accent  = true,
  glow    = false,
}

local MEDIA = "Interface\\AddOns\\Postbox\\Media\\"

-- `aspect` is height/width for art that is not square: the stock envelope
-- atlas is a 19.5x15 slot and stretching it square gives it jowls.
local ICONS = {
  postbox  = { texture = MEDIA .. "minimap-envelope.tga", tintable = true },
  blizzard = { atlas = "ui-hud-minimap-mail-up", aspect = 15 / 19.5 },
  clean    = { atlas = "communities-icon-invitemail" },
  mailbox  = { texture = MEDIA .. "icon.png" },
}

local GLOW_SCALE = 2.2

local function Settings()
  return ns.Store.EnsurePath("profile.minimap", DEFAULTS)
end

-------------------------------------------------------------
-- 1. Guarded reads of the mail state
--
-- On 12.x the client can hand back secret values in mail APIs; branching on
-- one raises. EllesmereUI's own indicator carries the same guards.
-------------------------------------------------------------

local function IsSecret(value)
  return type(issecretvalue) == "function" and issecretvalue(value)
end

local function MailWaiting()
  if type(HasNewMail) ~= "function" then return false end
  local ok, pending = pcall(HasNewMail)
  if not ok or IsSecret(pending) then return false end
  return pending and true or false
end

local function LatestSenders()
  local senders = {}
  if type(GetLatestThreeSenders) ~= "function" then return senders end
  local ok, s1, s2, s3 = pcall(GetLatestThreeSenders)
  if not ok then return senders end
  for i = 1, 3 do
    local sender = (i == 1 and s1) or (i == 2 and s2) or s3
    if not IsSecret(sender) and type(sender) == "string" and sender ~= "" then
      senders[#senders + 1] = sender
    end
  end
  return senders
end

-- The default indicator's own OnLoad stands down under this rule (special
-- game modes without mail notifications); a replacement must too.
local function NotificationsRuledOut()
  if not (C_GameRules and type(C_GameRules.IsGameRuleActive) == "function") then
    return false
  end
  local rule = Enum and Enum.GameRule and Enum.GameRule.IngameMailNotificationDisabled
  if not rule then return false end
  local ok, active = pcall(C_GameRules.IsGameRuleActive, rule)
  return ok and active == true
end

-------------------------------------------------------------
-- 2. The default indicator
-------------------------------------------------------------

-- The legacy MiniMapMailFrame global no longer exists on 12.x; the frame is
-- reachable only by this path.
local function DefaultIndicator()
  local cluster = _G.MinimapCluster
  local holder = cluster and cluster.IndicatorFrame
  return holder and holder.MailFrame or nil
end

-- A plain Hide() does not stick: UPDATE_PENDING_MAIL re-Shows the frame on
-- login, on new mail, and on every pending-mail re-sync. The hook is
-- installed once and consults the live setting, so it goes dormant -- not
-- removed, hooks cannot be -- when the feature is off.
local suppressHookInstalled = false
local suppressing = false

local function SetDefaultSuppressed(on)
  on = on == true
  if suppressing == on then return end
  local mail = DefaultIndicator()
  if not mail then return end
  suppressing = on

  if on then
    if not suppressHookInstalled then
      suppressHookInstalled = true
      hooksecurefunc(mail, "Show", function(frame)
        if suppressing then frame:Hide() end
      end)
    end
    mail:Hide()
    return
  end

  -- Restore by running Blizzard's own handler once, not by calling Show():
  -- the envelope texture inside the frame is only made visible after a
  -- notification flipbook completes, so a bare Show() would restore an
  -- empty frame. The handler re-derives everything from HasNewMail().
  local handler = mail:GetScript("OnEvent")
  if handler then pcall(handler, mail, "UPDATE_PENDING_MAIL") end
end

-------------------------------------------------------------
-- 3. Position on the rim
-------------------------------------------------------------

-- Round unless somebody says square. GetMinimapShape is the LibDBIcon-era
-- convention ElvUI implements; corner-rounded hybrid shapes are treated as
-- round, which errs toward keeping the button on the visible map edge.
-- EllesmereUI's minimap module defines no shape API at all, so its live
-- profile is read instead -- via Lite.GetAddon, because its SavedVariables
-- global is vestigial and wiped at load.
local function MinimapIsRound()
  if type(_G.GetMinimapShape) == "function" then
    local ok, shape = pcall(_G.GetMinimapShape)
    if ok and type(shape) == "string" then
      return shape ~= "SQUARE"
    end
  end
  local host = _G.EllesmereUI
  if host and host.Lite and type(host.Lite.GetAddon) == "function" then
    local ok, mm = pcall(function()
      local sub = host.Lite.GetAddon("EllesmereUIMinimap", true)
      return sub and sub.db and sub.db.profile and sub.db.profile.minimap
    end)
    if ok and type(mm) == "table" then
      return (mm.shape or "square") ~= "square"
    end
  end
  return true
end

-- The button centre is the stored angle's ray from the minimap centre,
-- clipped to the rim: the circle's radius, or for a square minimap the ray's
-- exit through the square (radius / the larger direction component).
local function Reposition(button)
  local minimap = _G.Minimap
  if not (button and minimap) then return end

  local radius = (minimap:GetWidth() or 140) / 2
  local radians = math.rad(tonumber(Settings().angle) or DEFAULTS.angle)
  local cos, sin = math.cos(radians), math.sin(radians)

  local reach = radius
  if not MinimapIsRound() then
    reach = radius / math.max(math.abs(cos), math.abs(sin))
  end

  button:ClearAllPoints()
  button:SetPoint("CENTER", minimap, "CENTER", cos * reach, sin * reach)
  button:SetFrameLevel((minimap:GetFrameLevel() or 2) + 20)
end

local function AngleFromCursor()
  local minimap = _G.Minimap
  local centerX, centerY = minimap:GetCenter()
  if not centerX then return nil end
  local scale = minimap:GetEffectiveScale()
  if not scale or scale == 0 then return nil end
  local cursorX, cursorY = GetCursorPosition()
  local dx = cursorX / scale - centerX
  local dy = cursorY / scale - centerY
  if dx == 0 and dy == 0 then return nil end
  return math.deg(math.atan2(dy, dx)) % 360
end

-------------------------------------------------------------
-- 4. Look
-------------------------------------------------------------

local function ApplyLook(button)
  local prefs = Settings()
  local size = tonumber(prefs.size) or DEFAULTS.size
  button:SetSize(size, size)

  local spec = ICONS[prefs.icon] or ICONS.postbox
  local icon = button.icon
  icon:SetSize(size, size * (spec.aspect or 1))
  if spec.atlas then
    icon:SetAtlas(spec.atlas)
  else
    icon:SetTexture(spec.texture)
  end

  -- One accent switch for the whole element: the glyph (where the art is
  -- tintable) and the glow follow ns.Theme.GetAccent() together -- the
  -- EllesmereUI accent when that skin is active, Postbox's own otherwise.
  -- Untintable art keeps its colours and only the glow carries the accent.
  local r, g, b = 1, 1, 1
  if prefs.accent ~= false then
    r, g, b = ns.Theme.GetAccent()
  end
  if spec.tintable then
    icon:SetVertexColor(r, g, b)
  else
    icon:SetVertexColor(1, 1, 1)
  end

  local glow = button.glow
  glow:SetSize(size * GLOW_SCALE, size * GLOW_SCALE)
  glow:SetVertexColor(r, g, b)
  if prefs.glow == true then
    glow:Show()
    if not button.pulse:IsPlaying() then button.pulse:Play() end
  else
    button.pulse:Stop()
    glow:Hide()
  end

  Reposition(button)
end

-------------------------------------------------------------
-- 5. The button
-------------------------------------------------------------

local function ShowTooltip(button)
  GameTooltip:SetOwner(button, "ANCHOR_BOTTOMLEFT")

  -- Same content as the default indicator: the shared formatter when the
  -- client provides it, the same strings by hand when it does not.
  local senders = LatestSenders()
  local header = (#senders > 0 and HAVE_MAIL_FROM) or HAVE_MAIL or ""
  local formatted = type(FormatUnreadMailTooltip) == "function"
    and pcall(FormatUnreadMailTooltip, GameTooltip, header, senders)
  if not formatted then
    GameTooltip:SetText(header)
    for i = 1, #senders do
      GameTooltip:AddLine(senders[i], 1, 1, 1)
    end
  end

  GameTooltip:AddLine(L["MINIMAP_TIP_HINT"], 0.6, 0.6, 0.6, true)
  GameTooltip:Show()
end

local function OnDragUpdate(button)
  local angle = AngleFromCursor()
  if angle then
    Settings().angle = angle
    Reposition(button)
  end
end

local function Build()
  if MB._button then return MB._button end
  local minimap = _G.Minimap
  if not minimap then return nil end

  -- Unnamed: see the header comment before naming this frame.
  local button = CreateFrame("Button", nil, minimap)
  button:Hide()
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:RegisterForDrag("LeftButton")

  local glow = button:CreateTexture(nil, "BACKGROUND")
  glow:SetPoint("CENTER")
  glow:SetTexture(MEDIA .. "minimap-glow.tga")
  glow:SetBlendMode("ADD")
  glow:Hide()
  button.glow = glow

  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetPoint("CENTER")
  button.icon = icon

  -- Hover feedback reuses the glow art faintly, so the hit target reads as a
  -- control without adding chrome.
  button:SetHighlightTexture(MEDIA .. "minimap-glow.tga", "ADD")
  local highlight = button:GetHighlightTexture()
  highlight:ClearAllPoints()
  highlight:SetPoint("CENTER")
  highlight:SetSize(DEFAULTS.size * GLOW_SCALE, DEFAULTS.size * GLOW_SCALE)
  highlight:SetAlpha(0.35)
  button.highlight = highlight

  -- A slow breathe on the glow while mail waits. BOUNCE alternates the fade
  -- direction each loop, so there is no snap at the ends.
  local pulse = glow:CreateAnimationGroup()
  pulse:SetLooping("BOUNCE")
  local fade = pulse:CreateAnimation("Alpha")
  fade:SetFromAlpha(1)
  fade:SetToAlpha(0.55)
  fade:SetDuration(1.6)
  fade:SetSmoothing("IN_OUT")
  button.pulse = pulse

  button:SetScript("OnEnter", ShowTooltip)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  button:SetScript("OnClick", function(self)
    if IsShiftKeyDown() then return end -- shift is the drag modifier
    local Panel = ns.OptionsPanel
    if Panel and type(Panel.Toggle) == "function" then
      Panel.Toggle(self)
    end
  end)

  -- Shift-drag anywhere on the rim; a plain drag is ignored so a click can
  -- never smear the position. The angle is saved live, so releasing the
  -- button anywhere leaves the icon exactly where it looks.
  button:SetScript("OnDragStart", function(self)
    if not IsShiftKeyDown() then return end
    self:SetScript("OnUpdate", OnDragUpdate)
  end)
  button:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
  end)

  MB._button = button
  return button
end

-------------------------------------------------------------
-- 6. State
-------------------------------------------------------------

local function Refresh()
  local prefs = Settings()

  if prefs.enabled ~= true or NotificationsRuledOut() then
    SetDefaultSuppressed(false)
    if MB._button then MB._button:Hide() end
    return
  end

  SetDefaultSuppressed(true)
  local button = Build()
  if not button then return end
  ApplyLook(button)

  -- Update the highlight to the configured size too; it is anchored art, not
  -- a child, so ApplyLook's SetSize does not reach it.
  local size = tonumber(prefs.size) or DEFAULTS.size
  button.highlight:SetSize(size * GLOW_SCALE, size * GLOW_SCALE)

  button:SetShown(MailWaiting())
end

MB.Refresh = Refresh

-- Called by Skin_EllesmereUI.RefreshAccents so an accent retune repaints a
-- visible icon immediately rather than on the next mail event.
function MB.RefreshLook()
  local button = MB._button
  if button and button:IsShown() then ApplyLook(button) end
end

-------------------------------------------------------------
-- 7. Options surface (consumed by Core/OptionsPanel.lua)
-------------------------------------------------------------

function MB.GetEnabled() return Settings().enabled == true end

function MB.SetEnabled(on)
  Settings().enabled = on == true
  Refresh()
end

function MB.Toggle()
  MB.SetEnabled(not MB.GetEnabled())
  ns.Print(L[MB.GetEnabled() and "MINIMAP_TOGGLE_ON" or "MINIMAP_TOGGLE_OFF"])
end

function MB.GetIcon()
  local id = Settings().icon
  return ICONS[id] and id or DEFAULTS.icon
end

function MB.SetIcon(id)
  if not ICONS[id] then return end
  Settings().icon = id
  Refresh()
end

function MB.GetIconSize()
  return tonumber(Settings().size) or DEFAULTS.size
end

function MB.SetIconSize(px)
  px = tonumber(px)
  if not px then return end
  Settings().size = px
  Refresh()
end

function MB.GetAccentTint() return Settings().accent ~= false end

function MB.SetAccentTint(on)
  Settings().accent = on == true
  Refresh()
end

function MB.GetGlow() return Settings().glow == true end

function MB.SetGlow(on)
  Settings().glow = on == true
  Refresh()
end

function MB.ResetPosition()
  Settings().angle = DEFAULTS.angle
  Refresh()
end

-------------------------------------------------------------
-- 8. Init
-------------------------------------------------------------

function MB.Initialize()
  if MB._ready then return end
  MB._ready = true

  -- Same stand-down as the default indicator's own OnLoad: a game mode that
  -- rules out mail notifications gets no replacement for them either.
  if NotificationsRuledOut() then return end

  ns.Events.Register("UPDATE_PENDING_MAIL", function()
    if Settings().enabled == true then Refresh() end
  end)

  -- Re-derives everything on zone-in: both host UIs rebuild and resize the
  -- minimap at login and on profile switches, which moves the rim.
  ns.Events.Register("PLAYER_ENTERING_WORLD", function()
    Refresh()
  end)

  local minimap = _G.Minimap
  if minimap and not MB._sizeHooked then
    MB._sizeHooked = true
    hooksecurefunc(minimap, "SetSize", function()
      if MB._button and MB._button:IsShown() then Reposition(MB._button) end
    end)
  end

  Refresh()
end
