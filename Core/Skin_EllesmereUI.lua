local ADDON_NAME, ns = ...

-- =====================================================================
-- Postbox :: EllesmereUI skin (optional, auto-applied)
-- ---------------------------------------------------------------------
-- Inert unless EllesmereUI is installed. Two backends, one skinning body:
--
--   "api"    -- EllesmereUI 8.6.8+ ships a public third-party skinning
--               API (EllesmereUI.RegisterSkin, see SKINNING_API.md at its
--               repo root; S.apiVersion is 1 and the surface is
--               additive-only). Preferred: EllesmereUI owns every visual,
--               so the skin tracks all their future tweaks for free.
--
--   "compat" -- 8.6.7 and earlier have no such API. There we build the
--               same facade ourselves out of the public helpers 8.6.6
--               *does* export -- the border engine, accent colour, UI
--               font and the pixel-perfect border helper -- reproducing
--               the house window style. This is a bridge: when the user
--               updates, the "api" backend takes over automatically and
--               the shim stops being used. It is also where an
--               EllesmereUI that ships the stub but not its dispatcher
--               lands (see OnSilence at the bottom of the file).
--
-- Either way the style follows the user's own EllesmereUI setup rather
-- than anything hardcoded here, and the skinning body below is identical.
--
-- Precedence: when both ElvUI and EllesmereUI are installed this wins --
-- it claims ns.Skin at PLAYER_LOGIN, before the window is ever built, and
-- Core/Skin_ElvUI.lua stands down for the session when EllesmereUI is loaded.
-- =====================================================================

-- Resolved in the boot handler at the bottom of the file, NOT here: a
-- file-scope `if not _G.EllesmereUI then return end` bakes in a permanent,
-- silent no-op whenever the global is not published by the time this chunk
-- runs -- a load-on-demand EllesmereUI, a sub-addon that owns the global, a
-- third addon's dependency graph reordering the load. Every helper below
-- tolerates EUI being nil, and none of them is reachable before the skin has
-- a host: they are only published through S / ns.Skin / ns.SkinEllesmere,
-- all of which are assigned only once EllesmereUI has actually been found.
-- With no EllesmereUI installed the file stays a no-op: one idle event frame,
-- nothing claimed, nothing drawn.
local EUI

local Skin = {}
local S                -- primitive facade: EllesmereUI's, or our shim
local BACKEND          -- "api" | "compat"

-------------------------------------------------------------
-- Compatibility shim (EllesmereUI < 8.6.7)
-------------------------------------------------------------
-- Values below mirror EllesmereUIBlizzardSkin's own window engine so the
-- result is visually identical to a natively-skinned Blizzard window.
local SHELL_TEX   = "Interface\\AddOns\\EllesmereUI\\media\\modern_blizz.png"
local BORDER_ATLAS = "AdventureMap_TopBorder"
local BG_ASPECT   = 561 / 433
local BASE_L, BASE_R, BASE_T, BASE_B = 0.25, 1, 0, 0.75
local BASE_U, BASE_V = BASE_R - BASE_L, BASE_B - BASE_T

local function PP()
  if not EUI then return nil end
  return EUI.PanelPP or EUI.PP
end

local function ShimFont()
  local path, flag
  if EUI and EUI.GetFontPath then
    local ok, resolved = pcall(EUI.GetFontPath, "blizzardSkin")
    if ok then path = resolved end
  end
  if EUI and EUI.GetFontOutlineFlag then
    local ok, resolved = pcall(EUI.GetFontOutlineFlag, "blizzardSkin")
    if ok then flag = resolved end
  end
  return path or STANDARD_TEXT_FONT, flag or ""
end

-- The suite-wide baseline: EllesmereUI's Dark Mode "fill" colour AND alpha,
-- resolved per-profile (GetDarkModeFill -> active profile's darkMode table,
-- falling back to DEFAULT_DARK_MODE). This is the one value that is genuinely
-- shared across the user's whole UI -- unit frames, bars, panels -- and is what
-- a profile import like atrocityUI actually sets, so it is the right thing for
-- Postbox to inherit rather than the window shell's fixed, opaque art.
local function HostBaseline()
  if not EUI then return 0.067, 0.067, 0.067, 0.90 end
  if EUI.GetDarkModeFill then
    local ok, r, g, b, a = pcall(EUI.GetDarkModeFill)
    if ok and r then return r, g, b, a or 1 end
  end
  local d = EUI.DEFAULT_DARK_MODE
  if d then
    return d.fillR or 0.067, d.fillG or 0.067, d.fillB or 0.067, d.fillA or 0.90
  end
  return 0.067, 0.067, 0.067, 0.90
end

local function ShimAccent()
  local c = (EUI and EUI.ELLESMERE_GREEN) or {}
  return c.r or 0.047, c.g or 0.824, c.b or 0.616
end

-- Resolve the user's window style the way 8.6.7's GetThirdPartySkinStyle does:
-- a majority vote across their per-window choices. Reading EllesmereUIDB is a
-- shim-only concession -- 8.6.6 exposes no accessor -- and it is read-only.
local function ShimStyle()
  local styles = EllesmereUIDB and EllesmereUIDB.blizzWindowSkinStyles
  if type(styles) ~= "table" then return "eui" end
  local eui, modern = 0, 0
  for _, v in pairs(styles) do
    if v == "modern" then modern = modern + 1 else eui = eui + 1 end
  end
  return (modern > eui) and "modern" or "eui"
end

local function ShimModernBG()
  local c = EllesmereUIDB and EllesmereUIDB.blizzWindowModernDefault
  if not (c and c.r) then return 0.067, 0.067, 0.067, 0.97 end
  return c.r, c.g, c.b, c.a or 0.97
end

local function ShimFadeRegions(frame, keep)
  if not frame then return end
  for i = 1, select("#", frame:GetRegions()) do
    local r = select(i, frame:GetRegions())
    if r and r.IsObjectType and r:IsObjectType("Texture") and not (keep and keep[r]) then
      r:SetAlpha(0)
    end
  end
end

local NINESLICE_PIECES = {
  "TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner",
  "TopEdge", "BottomEdge", "LeftEdge", "RightEdge", "Center",
}
local function ShimFadeNineSlice(nsl)
  if not nsl then return end
  ShimFadeRegions(nsl)
  for _, k in ipairs(NINESLICE_PIECES) do
    local p = nsl[k]
    if p and p.SetAlpha then p:SetAlpha(0) end
  end
  if nsl.SetAlpha then nsl:SetAlpha(0) end
end

local function ShimBorder(frame, r, g, b, a)
  local pp = PP()
  if pp and pp.CreateBorder and not frame.__pbShimBorder then
    frame.__pbShimBorder = true
    pp.CreateBorder(frame, r or 0.2, g or 0.2, b or 0.2, a or 1, 1, "OVERLAY", 7)
  end
end

local function ShimSolid(parent, layer, r, g, b, a, sub)
  local t = parent:CreateTexture(nil, layer, nil, sub)
  t:SetColorTexture(r, g, b, a)
  return t
end

local function BuildShim()
  local shim = {}

  function shim.FadeRegions(frame, keep) ShimFadeRegions(frame, keep) end
  function shim.FadeNineSlice(nsl) ShimFadeNineSlice(nsl) end

  function shim.Shell(frame)
    if not frame or frame.__pbShimShell then return end
    frame.__pbShimShell = true
    ShimFadeRegions(frame)
    ShimFadeNineSlice(frame.NineSlice)

    -- Flat fill in the host baseline colour. EllesmereUI's own window art
    -- (modern_blizz.png) is a palette PNG with no tRNS chunk -- fully opaque,
    -- and cropped per window aspect ratio, so it can neither be made
    -- see-through nor matched consistently. The Dark Mode fill is the value
    -- the rest of the user's UI actually shares, so we use that instead.
    local br, bg_, bb = HostBaseline()
    local fill = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    fill:SetColorTexture(br, bg_, bb, 1)
    fill:SetAllPoints(frame)
    -- The one handle for "the window's backdrop fill", shared with the api
    -- backend, so Skin.ApplyBgOpacity needs no backend-specific branch.
    frame.__pbEuiShellArt = fill

    -- Dark strip behind the window title.
    local topBar = ShimSolid(frame, "BACKGROUND", 0, 0, 0, 0.5, -5)
    frame.__pbShimTopBar = topBar
    topBar:SetPoint("TOPLEFT")
    topBar:SetPoint("TOPRIGHT")
    topBar:SetHeight(25)

    -- House window border: a complete window-frame atlas over the backdrop.
    local ov = CreateFrame("Frame", nil, frame)
    ov:SetAllPoints(frame)
    ov:SetFrameLevel(frame:GetFrameLevel() + 6)
    local tex = ov:CreateTexture(nil, "OVERLAY", nil, 7)
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(BORDER_ATLAS) then
      tex:SetAtlas(BORDER_ATLAS)
      tex:SetAllPoints(ov)
      -- Kept so the border option can hide the house chrome for "None".
      frame.__pbShimBorderFrame = ov
    else
      ShimBorder(frame)
    end
  end

  function shim.Panel(frame, opts)
    if not frame or frame.__pbShimPanel then return end
    frame.__pbShimPanel = true
    opts = opts or {}
    ShimFadeRegions(frame)
    if not opts.noBg then
      local r, g, b, a = 0.08, 0.08, 0.08, 0.92
      if opts.inset then r, g, b, a = 0.04, 0.04, 0.04, 0.85 end
      local bg = ShimSolid(frame, "BACKGROUND", r, g, b, a, -8)
      bg:SetAllPoints(frame)
      frame.__pbEuiShellArt = bg
    end
    if not opts.noBorder then ShimBorder(frame) end
  end

  function shim.Inset(inset)
    if not inset then return end
    ShimFadeRegions(inset)
    if inset.Bg then inset.Bg:SetAlpha(0) end
    ShimFadeNineSlice(inset.NineSlice)
  end

  function shim.Button(btn)
    if not btn or btn.__pbShimBtn then return end
    btn.__pbShimBtn = true
    ShimFadeRegions(btn)
    for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture",
                             "GetDisabledTexture", "GetHighlightTexture" }) do
      local fn = btn[getter]
      local t = fn and fn(btn)
      if t then t:SetAlpha(0) end
    end
    for _, k in ipairs({ "Left", "Middle", "Right" }) do
      if btn[k] and btn[k].SetAlpha then btn[k]:SetAlpha(0) end
    end
    local fill = ShimSolid(btn, "BACKGROUND", 0.08, 0.08, 0.08, 0.92)
    fill:SetAllPoints(btn)
    ShimBorder(btn)
    local hover = ShimSolid(btn, "HIGHLIGHT", 1, 1, 1, 0.1)
    hover:SetAllPoints(btn)
  end

  function shim.EditBox(eb)
    if not eb or eb.__pbShimEdit then return end
    eb.__pbShimEdit = true
    ShimFadeRegions(eb)
    for _, k in ipairs({ "Left", "Right", "Middle", "Mid" }) do
      if eb[k] and eb[k].SetAlpha then eb[k]:SetAlpha(0) end
    end
    local fill = ShimSolid(eb, "BACKGROUND", 0.02, 0.02, 0.02, 1)
    fill:SetAllPoints(eb)
    ShimBorder(eb)
  end

  function shim.Checkbox(cb)
    if not cb or cb.__pbShimCheck then return end
    cb.__pbShimCheck = true
    if cb.SetNormalTexture then cb:SetNormalTexture("") end
    if cb.SetPushedTexture then cb:SetPushedTexture("") end
    if cb.SetHighlightTexture then cb:SetHighlightTexture("") end
    local checked = cb.GetCheckedTexture and cb:GetCheckedTexture()
    for i = 1, select("#", cb:GetRegions()) do
      local r = select(i, cb:GetRegions())
      if r and r ~= checked and r.IsObjectType and r:IsObjectType("Texture") then
        r:SetAlpha(0)
      end
    end
    local fill = ShimSolid(cb, "BACKGROUND", 0.02, 0.02, 0.02, 1)
    fill:SetPoint("TOPLEFT", 4, -4)
    fill:SetPoint("BOTTOMRIGHT", -4, 4)
    ShimBorder(cb, 0.25, 0.25, 0.25, 1)
    if checked then
      local ar, ag, ab = ShimAccent()
      checked:SetVertexColor(ar, ag, ab, 1)
    end
  end

  function shim.CloseButton(btn)
    if not btn or btn.__pbShimClose then return end
    btn.__pbShimClose = true
    if btn.SetNormalTexture then btn:SetNormalTexture("") end
    if btn.SetPushedTexture then btn:SetPushedTexture("") end
    if btn.SetHighlightTexture then btn:SetHighlightTexture("") end
    if btn.SetDisabledTexture then btn:SetDisabledTexture("") end
    ShimFadeRegions(btn)
    local x = btn:CreateTexture(nil, "OVERLAY")
    x:SetAtlas("uitools-icon-close")
    x:SetSize(14, 14)
    x:SetPoint("CENTER", -2, 0)
    x:SetVertexColor(1, 1, 1, 0.75)
    btn:HookScript("OnEnter", function() x:SetVertexColor(1, 1, 1, 1) end)
    btn:HookScript("OnLeave", function() x:SetVertexColor(1, 1, 1, 0.75) end)
  end

  -- Flat plate, own label, accent underline on the active tab. Mirrors the
  -- house tab exactly, including hiding Blizzard's own label behind ours.
  function shim.Tab(tab)
    if not tab then return end
    if tab.__pbShimTab then
      local sel = tab.isSelected and true or false
      if tab.__pbShimLabel then
        tab.__pbShimLabel:SetTextColor(1, 1, 1, sel and 1 or 0.5)
        if tab.__pbShimBliz and tab.__pbShimBliz.GetText then
          tab.__pbShimLabel:SetText(tab.__pbShimBliz:GetText() or "")
        end
      end
      if tab.__pbShimUnderline then tab.__pbShimUnderline:SetShown(sel) end
      if tab.__pbShimActive then tab.__pbShimActive:SetShown(sel) end
      return
    end
    tab.__pbShimTab = true

    for j = 1, select("#", tab:GetRegions()) do
      local r = select(j, tab:GetRegions())
      if r and r:IsObjectType("Texture") then
        r:SetTexture("")
        if r.SetAtlas then r:SetAtlas("") end
      end
    end
    for _, k in ipairs({ "Left", "Middle", "Right",
                         "LeftDisabled", "MiddleDisabled", "RightDisabled" }) do
      if tab[k] and tab[k].SetTexture then tab[k]:SetTexture("") end
    end
    local hl = tab.GetHighlightTexture and tab:GetHighlightTexture()
    if hl then hl:SetTexture("") end

    local bg = ShimSolid(tab, "BACKGROUND", 0.068, 0.056, 0.052, 1)
    bg:SetAllPoints()

    -- The house border. Postbox's tabs are far wider than a Blizzard window's,
    -- and an unbordered plate in almost exactly the Dark Mode fill colour is
    -- invisible against the window behind it -- which left the tab bar reading
    -- as two floating words rather than as a control.
    ShimBorder(tab)

    -- Selected wash. At 2% this was indistinguishable from the idle plate, so
    -- the 1px underline was carrying the entire selected state on its own.
    local active = tab:CreateTexture(nil, "ARTWORK", nil, -6)
    active:SetAllPoints()
    active:SetColorTexture(1, 1, 1, 0.07)
    active:SetBlendMode("ADD")
    active:Hide()
    tab.__pbShimActive = active

    local bliz = tab.Text or (tab.GetFontString and tab:GetFontString())
    local text = (bliz and bliz.GetText and bliz:GetText()) or ""
    if bliz and bliz.SetTextColor then bliz:SetTextColor(0, 0, 0, 0) end
    if tab.SetPushedTextOffset then tab:SetPushedTextOffset(0, 0) end

    local path, flag = ShimFont()
    local label = tab:CreateFontString(nil, "OVERLAY")
    -- 12, not 11: these are the window's primary navigation and were set
    -- smaller than every other label in it.
    label:SetFont(path, 12, flag)
    label:SetPoint("CENTER", tab, "CENTER", 0, 0)
    label:SetText(text)
    tab.__pbShimLabel, tab.__pbShimBliz = label, bliz

    -- Inset by the border's own pixel: the border sits a sublevel above this,
    -- so a flush underline would have its bottom row painted over.
    local underline = tab:CreateTexture(nil, "OVERLAY", nil, 6)
    underline:SetHeight(2)
    underline:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 1, 1)
    underline:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -1, 1)
    local ar, ag, ab = ShimAccent()
    underline:SetColorTexture(ar, ag, ab, 1)
    underline:Hide()
    tab.__pbShimUnderline = underline

    shim.Tab(tab)
  end

  -- Modern MinimalScrollBar shape. Postbox's own lists are the legacy slider
  -- (handled by SkinScrollBar), but nested Blizzard widgets can use this one.
  function shim.ScrollBar(sb)
    if not sb or sb.__pbShimBar then return end
    sb.__pbShimBar = true
    for _, k in ipairs({ "Back", "Forward" }) do
      local b = sb[k]
      if b then
        ShimFadeRegions(b)
        if b.Texture then b.Texture:SetAlpha(0) end
      end
    end
    local track = sb.Track
    if track then ShimFadeRegions(track) end
    local thumb = (track and track.Thumb) or (sb.GetThumb and sb:GetThumb())
    if thumb then
      ShimFadeRegions(thumb)
      thumb:SetAlpha(1)
      local t = ShimSolid(thumb, "ARTWORK", 1, 1, 1, 0.35)
      t:SetPoint("TOP", thumb, "TOP", 0, 0)
      t:SetPoint("BOTTOM", thumb, "BOTTOM", 0, 0)
      t:SetWidth(4)
    end
  end

  function shim.Font(fs, r, g, b)
    if not fs or not fs.GetFont then return end
    local _, size = fs:GetFont()
    local path, flag = ShimFont()
    if EUI.PrimeFontShadow then pcall(EUI.PrimeFontShadow, fs, flag == "") end
    fs:SetFont(path, size or 12, flag)
    if r then fs:SetTextColor(r, g, b or r) end
  end

  function shim.GetStyle() return ShimStyle() end
  function shim.GetAccentColor() return ShimAccent() end
  function shim.GetPanelColor() return 0.08, 0.08, 0.08, 0.92 end
  function shim.GetFont() return ShimFont() end
  function shim.IsEnabled() return true end
  -- 8.6.6 has no live-looks callback; accent edits need a /reload on this path.
  function shim.OnLooksChanged() end

  return shim
end

-------------------------------------------------------------
-- Optional outer window border (EllesmereUI's shared border engine)
-------------------------------------------------------------
-- Present in 8.6.6 and later, so this works on both backends: the same
-- Glow/Shadow/texture picker the rest of the suite uses. Drawn outside the
-- shell's own chrome, so switching styles is live with no reload.
local BORDER_NONE = "none"
local DEFAULT_BORDER = "shadow"
local DEFAULT_BORDER_SIZE = 2
local THICKNESS_STEP = { thin = 1, normal = 2, heavy = 3 }

local function GetProfile()
  return ns.Store.EnsurePath("profile", {})
end

-- Every Postbox window we have skinned. Appearance settings apply to all of
-- them, so the options panel is styled and bordered like the main window
-- instead of keeping whatever it had when it was first built.
Skin._windows = setmetatable({}, { __mode = "k" })

function Skin.ForEachWindow(fn)
  for frame in pairs(Skin._windows) do
    if frame then pcall(fn, frame) end
  end
end

-- EllesmereUI's own configured window border (the one its Damage Meters window
-- and friends use), read live. Size 0 means "no border", which we express as
-- our BORDER_NONE. Returns styleKey, sizeStep.
local function HostBorder()
  local db = EllesmereUIDB
  if type(db) ~= "table" then return BORDER_NONE, DEFAULT_BORDER_SIZE end
  local size = tonumber(db.windowBorderSize)
  local tex  = db.windowBorderTexture
  if size == nil and tex == nil then return BORDER_NONE, DEFAULT_BORDER_SIZE end
  if (size or 0) <= 0 then return BORDER_NONE, DEFAULT_BORDER_SIZE end
  return tex or "solid", math.max(1, math.min(4, size))
end
Skin.GetHostBorder = HostBorder

function Skin.GetBorderStyle()
  local saved = GetProfile().euiBorder
  if saved ~= nil then return saved end
  return (HostBorder())
end

function Skin.IsBorderDefault()
  return GetProfile().euiBorder == nil
end

function Skin.ResetBorder()
  local p = GetProfile()
  p.euiBorder, p.euiBorderSize = nil, nil
  Skin.ApplyBorder()
end

function Skin.GetBorderSize()
  local saved = tonumber(GetProfile().euiBorderSize)
  if saved then return saved end
  local _, size = HostBorder()
  return size
end

function Skin.IsBorderSizeDefault()
  return GetProfile().euiBorderSize == nil
end

function Skin.ResetBorderSize()
  GetProfile().euiBorderSize = nil
  Skin.ApplyBorder()
end

function Skin.GetBorderChoices()
  local out = { { key = BORDER_NONE, name = ns.L["OPT_BORDER_NONE"] } }
  if not (EUI and EUI.GetBorderTextureList) then return out end
  local ok, list = pcall(EUI.GetBorderTextureList)
  if not ok or type(list) ~= "table" then return out end
  for i = 1, #list do out[#out + 1] = list[i] end
  return out
end

function Skin.SetBorderStyle(key)
  local p = GetProfile()
  p.euiBorder = key
  if EUI and EUI.GetBorderTextureDefaultThickness then
    local ok, name = pcall(EUI.GetBorderTextureDefaultThickness, key)
    if ok then p.euiBorderSize = THICKNESS_STEP[name] or DEFAULT_BORDER_SIZE end
  end
  Skin.ApplyBorder()
end

function Skin.SetBorderSize(step)
  GetProfile().euiBorderSize = tonumber(step) or DEFAULT_BORDER_SIZE
  Skin.ApplyBorder()
end

-- Re-draw the outer border from the saved style/size. Safe to call any time.
function Skin.ApplyBorder(frame)
  if not frame then return Skin.ForEachWindow(Skin.ApplyBorder) end
  if not (EUI and EUI.ApplyBorderStyle) then return end

  local host = frame.__pbEuiBorderHost
  if not host then
    host = CreateFrame("Frame", nil, frame)
    host:EnableMouse(false)
    host:SetAllPoints(frame)
    frame.__pbEuiBorderHost = host
  end

  local key = Skin.GetBorderStyle()

  -- "None" means no border at all, including EllesmereUI's own window chrome
  -- (the atlas the shell lays down), which otherwise reads as a soft inner
  -- border still being present.
  if frame.__pbShimBorderFrame then
    frame.__pbShimBorderFrame:SetShown(key ~= BORDER_NONE)
  end

  if key == BORDER_NONE then
    pcall(EUI.ApplyBorderStyle, host, 0, 0, 0, 0, 0, "solid")
    host:Hide()
    return
  end

  local color, behind = { r = 1, g = 1, b = 1 }, false
  if EUI.GetBorderStyleSelectDefaults then
    local ok, c, b = pcall(EUI.GetBorderStyleSelectDefaults, key)
    if ok and c then color, behind = c, b and true or false end
  end

  local level = frame:GetFrameLevel() or 1
  host:SetFrameLevel(behind and math.max(0, level - 1) or (level + 8))
  host:Show()
  pcall(EUI.ApplyBorderStyle, host, Skin.GetBorderSize(),
        color.r or 1, color.g or 1, color.b or 1, 1, key)
end


-------------------------------------------------------------
-- Background baseline: colour and opacity
-------------------------------------------------------------
-- One absolute alpha for the window backdrop, defaulting to the alpha
-- EllesmereUI's own Dark Mode fill carries, so "auto" means "exactly as
-- transparent as the rest of the user's UI".
--
-- Not an additive wash: EllesmereUI's shell art (media/modern_blizz.png) is a
-- palette PNG with NO tRNS chunk -- every pixel is fully opaque -- so a solid
-- plate *underneath* it is invisible and can never produce transparency (an
-- earlier attempt did exactly that, which is why the setting appeared to do
-- nothing). The only thing that makes a window see-through is lowering the
-- alpha of the backdrop textures themselves, which is what this drives, on
-- both backends:
--
--   compat -- the shim draws the backdrop, so Postbox owns the texture.
--   api    -- EllesmereUI's facade draws its own shell. Its textures are not
--             reachable *through the facade*, but they are regions of a frame
--             Postbox owns, so ApplyShell records the ones S.Shell added and
--             drives those. If the facade drew nothing we can reach, Postbox's
--             own fill (__pbEuiShellArt) carries the backdrop instead.
--
-- The fill COLOUR is re-resolved here on every call rather than being baked in
-- at build time: GetDarkModeFill() is per-profile, so a mid-session profile
-- swap changes it, and a window still wearing the old grey next to one wearing
-- the new one is the exact symptom this avoids.

-- The options panel is deliberately exempt from the user's transparency (its
-- whole job is to stay legible while the window behind it is adjusted).
local OPAQUE_ALPHA = 0.97

-- Baseline alpha unless the user has explicitly overridden it.
function Skin.GetBgOpacity()
  local saved = tonumber(GetProfile().euiBgAlpha)
  if saved then return saved end
  local _, _, _, a = HostBaseline()
  return a or 0.90
end

-- True when opacity is following EllesmereUI rather than a manual override.
function Skin.IsBgOpacityDefault()
  return GetProfile().euiBgAlpha == nil
end

function Skin.ResetBgOpacity()
  GetProfile().euiBgAlpha = nil
  Skin.ApplyBgOpacity()
end

function Skin.SetBgOpacity(value)
  GetProfile().euiBgAlpha = tonumber(value)
  Skin.ApplyBgOpacity()
end

-- True when Postbox's own fill is what the user sees behind the window: the
-- compat shim always, and the api backend when S.Shell laid down nothing we
-- can reach. When EllesmereUI's own shell art IS reachable it draws the
-- backdrop and our fill only sits under it as the opaque floor.
local function OwnsFill(f)
  local hostArt = f.__pbEuiHostArt
  return not (hostArt and #hostArt > 0)
end

-- Defined below, next to the shell diff it re-runs. Declared here because the
-- opacity pass is the one thing that touches every window often enough to
-- notice art the facade added after ApplyShell had already looked.
local RescanHostArt

-- Re-resolves the baseline colour AND applies the current opacity. Both, every
-- time: they come from the same live accessor and must never disagree.
function Skin.ApplyBgOpacity(frame)
  local alpha = Skin.GetBgOpacity()

  local function paint(f)
    if not f then return end
    -- Before anything is read: a deferred border or a texture built on the
    -- window's first OnShow is host art that ApplyShell's picture predates.
    if RescanHostArt then pcall(RescanHostArt, f) end
    local opaque = f.__pbEuiAlwaysOpaque and true or false
    local a = opaque and OPAQUE_ALPHA or alpha
    local r, g, b = HostBaseline()

    local art = f.__pbEuiShellArt
    if art then
      if opaque then
        -- Lift the fill a little so the panel is legible and not a flat black
        -- slab; the main window keeps the exact baseline colour.
        art:SetColorTexture(r + 0.045, g + 0.045, b + 0.05, 1)
      else
        art:SetColorTexture(r, g, b, 1)
      end
      -- Shown when it IS the backdrop, and as the floor under an always-opaque
      -- window whatever the host drew on top. Hidden when EllesmereUI's own
      -- shell art is already drawing: two backdrops at the same alpha compose
      -- to a denser window than the one the user asked for.
      art:SetAlpha((opaque or OwnsFill(f)) and a or 0)
    end

    local hostArt = f.__pbEuiHostArt
    if hostArt then
      for i = 1, #hostArt do
        local region = hostArt[i]
        if region and region.SetAlpha then region:SetAlpha(a) end
      end
    end

    if f.__pbShimTopBar then f.__pbShimTopBar:SetAlpha(a) end
  end

  if frame then paint(frame) else Skin.ForEachWindow(paint) end
end

-- Postbox's own flat fill, in the host's Dark Mode colour, at the very bottom
-- of the window. On compat this is the whole backdrop; on api it is the floor
-- under EllesmereUI's shell and the thing that makes the always-opaque
-- exemption possible there.
local function EnsureShellArt(frame)
  local art = frame.__pbEuiShellArt
  if art then return art end
  art = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
  art:SetAllPoints(frame)
  local r, g, b = HostBaseline()
  art:SetColorTexture(r, g, b, 1)
  frame.__pbEuiShellArt = art
  return art
end

-- Draws the window shell and, on the api backend, records what the facade drew.
--
-- S.Shell() paints EllesmereUI's own shell directly onto the frame, and the
-- facade exposes no handle to those textures -- but they are regions of a frame
-- Postbox owns, so the ones that appeared since we last looked are exactly the
-- difference. Without this list the opacity setting, the per-profile baseline
-- alpha and the options panel's legibility exemption are all inert on the
-- backend every user with 8.6.8 or later is on.
--
-- Two things the first version of this got wrong, both fixed below:
--
--   THE WINDOW WAS ONE CALL WIDE. A facade that defers its border to a
--   C_Timer, or builds a texture on the window's first OnShow, landed after
--   the picture was taken and was never driven. ApplyBgOpacity re-diffs when
--   the frame's region/child counts move, so late art is picked up.
--
--   THE LIST WAS REPLACED, NOT MERGED. A second ApplyShell on the same frame
--   would diff against a "before" that already contained the host's art, come
--   up empty, and leave __pbEuiHostArt = {} -- at which point OwnsFill lies,
--   Postbox's fill is shown under the host's opaque shell where it cannot be
--   seen, and the opacity control is dead for the session.
--
-- What may be adopted is decided by IDENTITY, not by timing, because the
-- re-diff runs long after Postbox has added art of its own.

-- Everything Postbox parked on the frame under one of its own keys. Textures
-- (__pbEuiShellArt, pbWindowStone) and frames (__pbEuiBorderHost) alike: driving
-- our border holder's alpha from the background slider would fade the border
-- with the backdrop, and driving our own fill twice is how it stops matching the
-- number the user set.
local function CollectOwn(frame, into)
  local ok, iter = pcall(pairs, frame)
  if not ok then return into end
  for key, value in iter, frame do
    if type(key) == "string"
       and (string.sub(key, 1, 2) == "pb" or string.sub(key, 1, 4) == "__pb") then
      into[value] = true
    end
  end
  return into
end

-- A child frame is host decoration only if fading it cannot fade a control.
-- Alpha inherits, so a container is judged by its contents rather than by its
-- own mouse state: the previous IsMouseEnabled test got both directions wrong,
-- skipping click-blocking backdrop holders (ordinary skin furniture) and
-- adopting mouse-transparent containers full of clickable children.
local function IsDecorativeChild(child)
  if not (child and child.SetAlpha and child.IsObjectType) then return false end
  if child:IsObjectType("Button") or child:IsObjectType("CheckButton")
     or child:IsObjectType("EditBox") or child:IsObjectType("Slider")
     or child:IsObjectType("ScrollFrame") then
    return false
  end
  if child.GetNumChildren and (child:GetNumChildren() or 0) > 0 then return false end
  -- Postbox tags its own widgets where they are built, so one that appears on
  -- the window after ApplyShell is recognised without the window having to carry
  -- a key for it. The late re-diff is the reason this matters: at ApplyShell
  -- time everything of ours was already in the baseline snapshot.
  if child.__pbEuiSkinned or child.__postboxPanel or child.__postboxButton
     or child.__postboxCheck or child.__postboxInputWrap then
    return false
  end
  return true
end

-- One list build, not one per index: the old form re-expanded the whole vararg
-- inside the loop, which is quadratic on a window with a lot of regions.
local function Snapshot(frame, into)
  local regions = { frame:GetRegions() }
  for i = 1, #regions do into[regions[i]] = true end
  local kids = { frame:GetChildren() }
  for i = 1, #kids do into[kids[i]] = true end
  return into
end

-- Adds whatever has appeared since the baseline snapshot to the frame's host-art
-- list, and folds it into the baseline so the next pass diffs against the truth.
local function CaptureHostArt(frame)
  local before = frame.__pbEuiPreShell
  if not before then return end

  local hostArt = frame.__pbEuiHostArt
  local index = frame.__pbEuiHostArtIndex
  if not (hostArt and index) then
    hostArt, index = {}, {}
    frame.__pbEuiHostArt, frame.__pbEuiHostArtIndex = hostArt, index
  end

  local own = CollectOwn(frame, {})

  local regions = { frame:GetRegions() }
  for i = 1, #regions do
    local region = regions[i]
    if region and not before[region] and not index[region] and not own[region]
       and region.IsObjectType and region:IsObjectType("Texture") then
      index[region] = true
      hostArt[#hostArt + 1] = region
    end
    before[region] = true
  end

  local kids = { frame:GetChildren() }
  for i = 1, #kids do
    local child = kids[i]
    if child and not before[child] and not index[child] and not own[child]
       and IsDecorativeChild(child) then
      index[child] = true
      hostArt[#hostArt + 1] = child
    end
    before[child] = true
  end

  frame.__pbEuiArtRegions = #regions
  frame.__pbEuiArtChildren = #kids
end

-- Cheap "has anything appeared?" test for ApplyBgOpacity: counts move whenever
-- a region or child is added, and a full re-diff only runs when they have.
function RescanHostArt(frame)
  if not frame.__pbEuiPreShell then return end
  local regions = frame.GetNumRegions and frame:GetNumRegions() or 0
  local kids = frame.GetNumChildren and frame:GetNumChildren() or 0
  if regions == frame.__pbEuiArtRegions and kids == frame.__pbEuiArtChildren then
    return
  end
  CaptureHostArt(frame)
end

local function ApplyShell(frame, opts)
  local isApi = (BACKEND == "api")

  if isApi and not frame.__pbEuiPreShell then
    frame.__pbEuiPreShell = Snapshot(frame, {})
  end

  local ok = pcall(S.Shell, frame, opts)

  if isApi then
    CaptureHostArt(frame)
    -- Also on a failed Shell: then this fill is the entire backdrop, which is
    -- a dark EllesmereUI-coloured window rather than Blizzard's stripped one.
    EnsureShellArt(frame)
  end

  return ok
end

-------------------------------------------------------------
-- Accent pass-through for Postbox's own painted elements
-------------------------------------------------------------
Skin.GetHostBaseline = HostBaseline

function Skin.GetAccent()
  if not (S and S.GetAccentColor) then return nil end
  local ok, r, g, b = pcall(S.GetAccentColor)
  if ok and r then return r, g, b end
  return nil
end

-------------------------------------------------------------
-- Element handlers (identical on both backends)
-------------------------------------------------------------
local function SkinPanel(panel, opts)
  if not panel or panel.__pbEuiSkinned then return end
  panel.__pbEuiSkinned = true
  if panel.pbSurfaceTexture then panel.pbSurfaceTexture:SetAlpha(0) end
  if panel.SetBackdrop then panel:SetBackdrop(nil) end
  S.Panel(panel, opts)
end

-- Postbox's lists use UIPanelScrollFrameTemplate, whose bar is the classic
-- slider rather than the MinimalScrollBar the house primitive targets. Detect
-- which shape we got; reproduce the house look for the legacy one. Scroll
-- behaviour is untouched either way.
local function SkinScrollBar(sb)
  if not sb or sb.__pbEuiSkinned then return end
  sb.__pbEuiSkinned = true

  if sb.Track or sb.Back or sb.Forward then
    S.ScrollBar(sb)
    return
  end

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
  for i = 1, select("#", sb:GetRegions()) do
    local r = select(i, sb:GetRegions())
    if r and r.IsObjectType and r:IsObjectType("Texture") then r:SetAlpha(0) end
  end
  local thumb = sb.GetThumbTexture and sb:GetThumbTexture()
  if thumb then
    thumb:SetTexture(nil)
    thumb:SetColorTexture(1, 1, 1, 0.35)
    thumb:SetWidth(4)
    -- Region alpha and colour alpha multiply: the art pass above set every
    -- region (including this thumb) to alpha 0, which cancelled the colour
    -- alpha and left the scroll bar with no visible scrubber at all.
    thumb:SetAlpha(1)
  end
end

local function SkinScroll(sf)
  local name = sf.GetName and sf:GetName()
  local sb = sf.ScrollBar or (name and _G[name .. "ScrollBar"])
  if not sb or sb.__pbEuiPinned then return end
  sb.__pbEuiPinned = true
  SkinScrollBar(sb)
  local parent = sf:GetParent()
  if parent then
    sb:ClearAllPoints()
    sb:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -18)
    sb:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -4, 18)
  end
end

-- Leaf widgets carry the same one-shot key the panels already do.
--
-- While one backend is live this changes nothing: every primitive is idempotent
-- and bails after a table lookup, and a widget created later (a pooled row, a
-- lazily built picker) has no key and is still skinned on the next Refresh.
-- What it prevents is the one moment two backends exist in the same session --
-- the api facade replacing the shim when the user switches skinning back on
-- (see AdoptFacade). The house primitives key their own idempotency off marks
-- the shim never set, so without this they would run over shim art on the next
-- Refresh and leave, say, two borders on one edit box. Already skinned is
-- already skinned, whichever facade did it.
local function SkinLeaf(widget, fn)
  if not widget or widget.__pbEuiSkinned then return end
  widget.__pbEuiSkinned = true
  fn(widget)
end

local function SkinTree(frame, depth)
  if not frame or depth > 8 then return end
  local kids = { frame:GetChildren() }
  for i = 1, #kids do
    local c = kids[i]
    if c and c.IsObjectType then
      if c.__postboxPanel then
        SkinPanel(c, c.__postboxPanel == "band" and {} or { inset = true })
      elseif c.__postboxInputWrap then
        SkinPanel(c, { inset = true })
      elseif c:IsObjectType("EditBox") then
        if not c.__postboxNoEditSkin then SkinLeaf(c, S.EditBox) end
      elseif c:IsObjectType("ScrollFrame") then
        SkinScroll(c)
      elseif c.__postboxCheck then
        -- Not through SkinLeaf: the caption is re-fonted whether or not the
        -- host offers a checkbox primitive, so both live under the one key.
        if not c.__pbEuiSkinned then
          c.__pbEuiSkinned = true
          if S.Checkbox then S.Checkbox(c) end
          if c.__label then S.Font(c.__label) end
        end
      elseif c:IsObjectType("Button") then
        if c.__postboxButton then SkinLeaf(c, S.Button) end
      end
    end
    SkinTree(c, depth + 1)
  end
end

local function InstallTabs(frame)
  if not frame.TabButtons then return end
  for _, tab in pairs(frame.TabButtons) do
    if tab and not tab.__pbEuiSkinned then
      tab.__pbEuiSkinned = true
      tab.isSelected = false
      if tab.__activeBg then tab.__activeBg:SetAlpha(0) end
      -- Guarded per tab, and the override is installed only if the primitive
      -- actually painted. The tabs are Postbox's own plates rather than
      -- Blizzard panel tabs, so a host primitive that bails on the panel-tab
      -- fields it expects would otherwise leave both tabs with no visual at
      -- all: no house art (nothing was drawn) and no Postbox art (the override
      -- retires it on the first selection change).
      --
      -- pcall success is not that test on the api backend. EllesmereUI's
      -- facade entries are late-bound pass-throughs -- they look the primitive
      -- up in the engine at call time and return quietly when it is missing --
      -- so a call that did nothing still comes back ok. The observable test is
      -- that S.Tab draws its own plate and its own mirrored label, i.e. new
      -- regions on the tab; the shim does the same. Nothing new, nothing took.
      local before = (tab.GetNumRegions and tab:GetNumRegions()) or 0
      local ok = pcall(S.Tab, tab)
      local after = (tab.GetNumRegions and tab:GetNumRegions()) or 0
      if ok and after > before then
        -- Theme.SetTabSelected honours this and skips its own painting, so the
        -- two never fight over the same tab.
        tab.__setSelectedOverride = function(t, selected)
          t:Enable()
          t.isSelected = selected and true or false
          S.Tab(t)
          -- The primitive hid the original label behind its mirror ONCE, at
          -- skin time. A later Button:SetText (the Mail tab's live counts)
          -- re-applies the button's font colour and resurrects it under the
          -- mirror; the primitive's refresh re-syncs the mirror's text but
          -- never re-hides the original -- so that is re-asserted here, on
          -- every repaint. Theme.SetTabText routes every caption change
          -- through this override for exactly that reason.
          local bliz = t.Text or (t.GetFontString and t:GetFontString())
          if bliz and bliz.SetTextColor then bliz:SetTextColor(0, 0, 0, 0) end
        end
      elseif tab.__activeBg then
        -- Hand the tab back to Postbox's own painting intact, undoing the
        -- pre-emptive fade above.
        tab.__activeBg:SetAlpha(1)
      end
    end
  end

  local active = ns.MailboxUI and ns.MailboxUI._state and ns.MailboxUI._state.activeTab
  if active then
    for _, tab in pairs(frame.TabButtons) do
      if ns.Theme and ns.Theme.SetTabSelected then
        ns.Theme.SetTabSelected(tab, tab.tabId == active)
      end
    end
  end
end

-------------------------------------------------------------
-- Public entry points (called from Core/MailboxUI.lua)
-------------------------------------------------------------
function Skin.Refresh(frame)
  if not (S and frame) then return end
  pcall(SkinTree, frame, 0)
  -- Cheap re-assert of colour and alpha: a host restrip pass can zero the
  -- backdrop's region alpha, and a profile switch moves the colour.
  pcall(Skin.ApplyBgOpacity)
end

-- One-time skin of the main window. Each step is guarded separately so a
-- single failure cannot silently skip everything after it.
function Skin.Apply(frame)
  if not (S and frame) or frame.__pbEuiSkinned then return end
  frame.__pbEuiSkinned = true
  Skin._windows[frame] = true

  -- Clear Postbox's own gold theme explicitly rather than relying on the
  -- shell's art pass, so the marble can never survive into the skinned look.
  for _, key in ipairs({ "pbWindowStone", "pbWindowTint" }) do
    if frame[key] then frame[key]:SetAlpha(0) end
  end
  if frame.TabBar and frame.TabBar.pbTabBarBg then frame.TabBar.pbTabBarBg:SetAlpha(0) end

  pcall(ApplyShell, frame, { noBorder = (Skin.GetBorderStyle() == BORDER_NONE) })
  pcall(function() Skin.ApplyBgOpacity(frame) end)
  pcall(function() if frame.Inset then S.Inset(frame.Inset) end end)
  pcall(function() if frame.NineSlice then S.FadeNineSlice(frame.NineSlice) end end)
  pcall(function() if frame.CloseButton then S.CloseButton(frame.CloseButton) end end)
  pcall(function()
    if frame.TitleText then
      S.Font(frame.TitleText, 1, 1, 1)
      frame.TitleText:ClearAllPoints()
      frame.TitleText:SetPoint("CENTER", frame, "TOP", 0, -13)
    end
  end)
  pcall(function() if frame.Status then S.Font(frame.Status) end end)
  pcall(function() InstallTabs(frame) end)
  pcall(function() Skin.ApplyBorder(frame) end)
  pcall(function() Skin.RefreshAccents() end)

  -- Re-resolve everything host-owned each time the window opens.
  --
  -- On the api backend S.OnLooksChanged drives this live, but only for what
  -- EllesmereUI counts as "looks": accent, bar fill, Modern backdrop colour and
  -- window styles. The Dark Mode fill that HostBaseline reads -- and therefore
  -- our whole baseline colour and its alpha -- moves on a PROFILE switch, which
  -- is not on that list, and neither is the window border read out of
  -- EllesmereUIDB. On compat there is no callback at all. Close-and-reopen
  -- covers both gaps, and beats the /reload it used to need.
  pcall(function()
    frame:HookScript("OnShow", function() Skin.OnHostLooksChanged() end)
  end)

  Skin.Refresh(frame)
end

-- Lighter variant of Apply for Postbox's secondary windows (the options
-- panel): shell + chrome, but no tabs and no border picker.
function Skin.ApplyWindow(frame)
  if not (S and frame) or frame.__pbEuiSkinned then return end
  frame.__pbEuiSkinned = true
  Skin._windows[frame] = true
  for _, key in ipairs({ "pbWindowStone", "pbWindowTint" }) do
    if frame[key] then frame[key]:SetAlpha(0) end
  end
  pcall(ApplyShell, frame, { noBorder = (Skin.GetBorderStyle() == BORDER_NONE) })
  pcall(function() Skin.ApplyBgOpacity(frame) end)
  pcall(function() if frame.Inset then S.Inset(frame.Inset) end end)
  pcall(function() if frame.NineSlice then S.FadeNineSlice(frame.NineSlice) end end)
  pcall(function() if frame.CloseButton then S.CloseButton(frame.CloseButton) end end)
  pcall(function() if frame.TitleText then S.Font(frame.TitleText, 1, 1, 1) end end)
  pcall(function() Skin.ApplyBorder(frame) end)
  pcall(function()
    frame:HookScript("OnShow", function() Skin.OnHostLooksChanged() end)
  end)
  Skin.Refresh(frame)
end

function Skin.RefreshAccents()
  -- The minimap mail icon lives outside every window, so it re-tints here
  -- regardless of whether the mailbox has ever been opened.
  if ns.MinimapButton and type(ns.MinimapButton.RefreshLook) == "function" then
    pcall(ns.MinimapButton.RefreshLook)
  end

  local frame = ns.MailboxUI and ns.MailboxUI._frame
  if not frame then return end
  local r, g, b = Skin.GetAccent()
  if r and frame.OptionsButton and frame.OptionsButton.icon then
    frame.OptionsButton.icon:SetVertexColor(r, g, b)
  end
  local collect = frame.Tabs and frame.Tabs.collect
  if collect and ns.CollectTab and ns.CollectTab.RepaintViewToggle then
    ns.CollectTab.RepaintViewToggle(collect)
  end
end

-- Window tabs, view segments and category tiles sample the accent at paint
-- time (Core/Theme.lua's PaintPlate), so without this they keep the previous
-- accent until the next hover or selection change. Two kinds of plate:
--
--   * one this skin has taken over -- its art is retired and the host
--     primitive owns the look, so re-issuing the selection is the documented
--     way to repaint it (ELLESMEREUI_SKINNING.md section 6);
--   * one Postbox still paints -- repaint it from its own state.
--
-- Guarded per node: one uncooperative widget must not truncate the sweep.
local function RepaintPlates(frame, depth)
  if not frame or depth > 8 then return end
  local kids = { frame:GetChildren() }
  for i = 1, #kids do
    local c = kids[i]
    if c then
      local override = c.__setSelectedOverride
      if override then
        pcall(override, c, c.isSelected and true or false)
      elseif c.__pbPlateArt and ns.Theme and ns.Theme.RepaintPlate then
        pcall(ns.Theme.RepaintPlate, c)
      end
      RepaintPlates(c, depth + 1)
    end
  end
end

-- The single answer to "EllesmereUI's looks changed": accent, profile (which
-- moves the Dark Mode fill colour AND its alpha), border style or size. Every
-- host-derived value is re-resolved from scratch -- nothing here is cached --
-- so it is correct to call on any settings change and cheap enough to call on
-- every window open. Idempotent: each step is a re-assert, not a rebuild.
--
-- On the api backend this runs ALONGSIDE work EllesmereUI does itself: a shell
-- registered through S.Shell live-restyles through the engine's own refresh
-- path, so the host repaints its art on our frame and then the S.OnLooksChanged
-- callbacks run. Two things follow, and both are why ApplyBgOpacity re-diffs
-- rather than trusting the picture ApplyShell took:
--
--   * a restyle that REPLACES art (the eui <-> modern backdrops are different
--     textures) can only ever add regions, because WoW textures are not
--     destroyed -- so RescanHostArt's region/child count test cannot miss one;
--   * a restyle that reuses its textures in place leaves the counts alone,
--     which is equally fine: our alpha is already on those same objects, and if
--     the repaint reset it, the ApplyBgOpacity below is what puts it back.
--
-- What is NOT provable from EllesmereUI's published API is the ordering -- that
-- the restyle finishes before these callbacks fire. If it were the other way
-- round the window would sit at the host's own alpha until the next window
-- open, which the OnShow hook in Apply already covers.
function Skin.OnHostLooksChanged()
  if not S then return end
  pcall(Skin.ApplyBgOpacity)          -- baseline fill colour + opacity
  pcall(Skin.ApplyBorder)             -- the user's configured window border
  pcall(Skin.RefreshAccents)          -- options cog, collect view toggle
  -- Accent-toned TEXT. The plate sweep below repaints art; headings, field
  -- captions and tile captions are font strings and were the half nothing
  -- tracked, so they kept the previous accent until their role happened to be
  -- re-applied. Core/Theme.lua keeps the (weak) registry; this is the one
  -- moment it is worth reading.
  if ns.Theme and type(ns.Theme.RepaintAccentText) == "function" then
    pcall(ns.Theme.RepaintAccentText)
  end
  Skin.ForEachWindow(function(f) RepaintPlates(f, 0) end)
end

-------------------------------------------------------------
-- Host state probes
-------------------------------------------------------------
-- Under the official contract the registered callback staying silent has three
-- distinct causes needing three different answers, and neither the facade nor
-- the registration call can tell us which one we are in -- the facade is what
-- we do not have. Both probes below are read-only, fully nil-guarded, and
-- answer "don't know" (nil) rather than guessing on a client that cannot say.

-- EllesmereUI.RegisterSkin is a stub in the PARENT addon that only queues. The
-- dispatcher that drains that queue lives in the EllesmereUIBlizzardSkin
-- sub-addon, so with that sub-addon absent or disabled no callback can ever
-- arrive, however long we wait. That is precisely the pre-8.6.8 situation, and
-- the compat shim is its right answer.
local SKIN_SUBADDON = "EllesmereUIBlizzardSkin"

local function DispatcherLoaded()
  local probe = (C_AddOns and C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
  if type(probe) ~= "function" then return nil end
  local ok, loaded = pcall(probe, SKIN_SUBADDON)
  if not ok then return nil end
  return loaded and true or false
end

-- The user's own third-party skinning switches: an account-global master plus a
-- per-addon table, both keyed so that nil means ON. Read from the saved
-- variable directly because the facade that would answer this politely
-- (S.IsEnabled) only reaches us through the callback, and the callback not
-- arriving is the thing being diagnosed.
local function HostSkinningAllowed()
  local db = _G.EllesmereUIDB
  if type(db) ~= "table" then return true end
  if db.thirdPartySkinsOff then return false end
  local per = db.thirdPartySkinAddons
  if type(per) == "table" and per[ADDON_NAME] == false then return false end
  return true
end

-- Set when this skin refuses the window on purpose. Two causes:
--
--   "elvui"       the ElvUI skin has already painted it (see Activate).
--   "hostoptout"  the user switched third-party skinning off for Postbox, or
--                 off entirely, in EllesmereUI's own options. That is an
--                 explicit choice about how EllesmereUI treats other addons,
--                 and answering it with our compat shim -- a hand-built
--                 imitation of the very skin they just switched off -- would
--                 be worse than no skin at all. So: no shim, no skin, Postbox
--                 renders its own theme. The registration stays in
--                 EllesmereUI's queue, so switching it back on dispatches live
--                 and AdoptFacade takes over without a reload.
--
-- Reported by Diagnose -- i.e. /postbox skin, which is this addon's only debug
-- channel. A chat line at login would be noise about a situation nobody can act
-- on from the chat frame.
local standDown          -- nil | "elvui" | "hostoptout"

local STAND_DOWN_TEXT = {
  elvui      = "stood down (ElvUI painted first)",
  hostoptout = "stood down (EllesmereUI skinning is switched off for Postbox)",
}

-- Why the official callback never arrived, once the watchdog has established
-- that it did not. nil while the handshake is still in play, or after it won.
local silence            -- nil | "optout" | "nodispatcher" | "silent"

local SILENCE_TEXT = {
  optout       = "switched off for Postbox in EllesmereUI's options",
  nodispatcher = SKIN_SUBADDON .. " is not loaded",
  silent       = "registered, but EllesmereUI never called back",
}

-- The version the facade declared, once one has been handed to us.
local apiVersion

-- Diagnostic for /postbox skin -- what was detected and which path is live.
function Skin.Diagnose()
  local ver = (C_AddOns and C_AddOns.GetAddOnMetadata
               and C_AddOns.GetAddOnMetadata("EllesmereUI", "Version")) or "?"
  local style = "?"
  if S and S.GetStyle then
    local ok, resolved = pcall(S.GetStyle)
    if ok and resolved then style = resolved end
  end

  -- What is actually drawing the backdrop, which is the thing worth seeing when
  -- the transparency setting looks wrong. A GetTexture() probe was useless here:
  -- the fill is a SetColorTexture solid, for which it is not a dependable
  -- non-nil, so a healthy shell could report MISSING.
  local frame = ns.MailboxUI and ns.MailboxUI._frame
  local shellArt = "no window yet"
  if standDown then
    -- Not MISSING: nothing is drawn here because nothing is meant to be. The
    -- backend line above says which skin owns the window instead.
    shellArt = (standDown == "elvui") and "not this skin (ElvUI's)"
               or "not this skin (Postbox's own theme)"
  elseif frame then
    local hostArt = frame.__pbEuiHostArt
    if hostArt and #hostArt > 0 then
      shellArt = string.format("EllesmereUI shell (%d regions, alpha %.2f)",
                               #hostArt, Skin.GetBgOpacity())
    elseif frame.__pbEuiShellArt then
      local r, g, b = HostBaseline()
      shellArt = string.format("Postbox fill %.3f/%.3f/%.3f @ %.2f",
                               r, g, b, Skin.GetBgOpacity())
    else
      shellArt = "MISSING"
    end
  end
  -- The host's live view of its own toggles. Worth reporting on its own,
  -- because switching third-party skinning OFF mid-session is reload-bound at
  -- EllesmereUI's end: this goes false while the window stays skinned, which
  -- otherwise looks like the setting is broken.
  local hostEnabled
  if S and type(S.IsEnabled) == "function" then
    local ok, enabled = pcall(S.IsEnabled)
    if ok then hostEnabled = enabled and true or false end
  end

  return {
    euiVersion  = ver,
    hasAPI      = (EUI and EUI.RegisterSkin) ~= nil,
    apiVersion  = apiVersion,
    backend     = (standDown and STAND_DOWN_TEXT[standDown])
                  or (BACKEND or "inactive"),
    -- Stood down means detected, working, and deliberately not driving anything.
    active      = (S ~= nil) and not standDown,
    standDown   = standDown,
    silence     = silence,
    silenceText = silence and SILENCE_TEXT[silence] or nil,
    dispatcher  = DispatcherLoaded(),
    hostEnabled = hostEnabled,
    style       = style,
    borderStyle = Skin.GetBorderStyle(),
    borderSize  = Skin.GetBorderSize(),
    bgOpacity   = Skin.GetBgOpacity(),
    shellArt    = shellArt,
    windowBuilt = frame ~= nil,
  }
end

-------------------------------------------------------------
-- Activation
-------------------------------------------------------------
local function Activate()
  if not S then return end

  -- Handoff with Core/Skin_ElvUI.lua.
  --
  -- Ordinarily this file wins: the ElvUI skin tests _G.EllesmereUI at
  -- PLAYER_LOGIN and stands down when the host is there. The case that outruns
  -- it is EllesmereUI published AFTER login -- load-on-demand, or a sub-addon
  -- that owns the global -- which is exactly why detection here is deferred. By
  -- then ElvUI may already have skinned a window, and its pass is
  -- StripTextures + SetTemplate + shadow: there is nothing to reverse it with,
  -- so taking over would leave an ElvUI backdrop under an EllesmereUI shell and
  -- two selection overrides on every tab.
  --
  -- So: take over freely while nothing has been painted (swapping ns.Skin costs
  -- nothing), and refuse outright once it has. One skin owns the window either
  -- way, which is the only outcome worth having.
  if ns.SkinAppliedBy and ns.SkinAppliedBy ~= "ellesmereui" then
    standDown = "elvui"
    return
  end
  standDown = nil

  ns.Skin = Skin      -- take precedence over the ElvUI skin, if one loaded
  ns.SkinAppliedBy = "ellesmereui"

  -- Everything host-derived, not just the two accent-tinted icons: an accent,
  -- profile or border change moves the fill colour, its alpha, the border and
  -- every plate caption in the window.
  if type(S.OnLooksChanged) == "function" then
    pcall(S.OnLooksChanged, function() Skin.OnHostLooksChanged() end)
  end

  local frame = ns.MailboxUI and ns.MailboxUI._frame
  if frame then Skin.Apply(frame) end
end

-- The compat facade, also the fallback whenever the official handshake cannot
-- complete for a reason the user did not choose.
local shimFacade

local function UseShim()
  if S then return end
  BACKEND = "compat"
  shimFacade = shimFacade or BuildShim()
  S = shimFacade
  Activate()
end

-- Take the official facade, whether it arrives on time or long after the
-- watchdog has already put the shim up.
--
-- Arriving late is a real path rather than a theoretical one: EllesmereUI
-- dispatches live when third-party skinning is switched back ON (only switching
-- it OFF is reload-bound), so a user who opts back in mid-session lands here
-- with a window the shim has already painted.
--
-- The facade wins from this point on -- it is the real house look and it tracks
-- every future EllesmereUI tweak -- but it cannot retroactively unpaint the
-- shim, because a WoW texture can be faded and never destroyed. So the takeover
-- is a clean swap rather than a repaint: every already-skinned frame bails on
-- its own idempotency key (__pbEuiSkinned on the window and its widgets,
-- __pbShimShell on the backdrop, __pbShimTab on the tabs), so nothing is drawn
-- twice, and everything built from here on -- new windows, the options panel on
-- its first open -- is house art. The swap does change one thing immediately:
-- Activate re-runs and registers Skin.OnHostLooksChanged with the REAL
-- S.OnLooksChanged, where the shim's was a documented no-op.
local function AdoptFacade(facade)
  if S and S == facade then return end

  -- A facade that is nil, false or not a table would throw on the first
  -- primitive lookup; the shim is a working answer, so use it.
  if type(facade) ~= "table" then
    UseShim()
    return
  end

  -- Read the declared version defensively and treat it as a FLOOR, not a match:
  -- EllesmereUI's contract is additive-only, so a higher number still has every
  -- primitive we call. An absent or non-numeric field is read as 1 rather than
  -- as grounds to refuse -- refusing costs the user the real skin over a missing
  -- annotation, and every primitive call below is pcall-guarded anyway.
  local declared = tonumber(facade.apiVersion) or 1
  if declared < 1 then
    UseShim()
    return
  end
  apiVersion = declared

  -- An opt-out stand-down is over the instant the host hands us a facade: the
  -- dispatcher only calls back for addons the user has enabled, so its arrival
  -- IS the opt-in. An ElvUI stand-down is not, and Activate re-establishes that
  -- one for itself.
  if standDown == "hostoptout" then standDown = nil end
  silence = nil

  BACKEND = "api"
  S = facade
  Activate()
end

-- How long to wait for the callback before deciding it is not coming. The
-- dispatcher fires at PLAYER_LOGIN, in the same frame as our own registration,
-- so this is slack rather than a real budget.
local HANDSHAKE_WAIT = 5

-- Nothing arrived. Which silence is it?
--
-- Answering "fall back to the shim" to all three was wrong in exactly one case,
-- and it was the case where being wrong matters most: a user who has switched
-- Postbox off in EllesmereUI's third-party options gets our hand-built
-- imitation of EllesmereUI instead of the nothing they asked for. Overriding an
-- explicit opt-out is not a fallback, it is ignoring the setting.
local function OnSilence()
  if S then return end                       -- the callback won the race

  if not HostSkinningAllowed() then
    silence, standDown = "optout", "hostoptout"
    BACKEND = nil
    -- ns.Skin is deliberately left unclaimed, so Postbox's own theme renders
    -- and the appearance controls this skin owns (border, background opacity)
    -- stay out of the options panel, which reads ns.Skin to decide whether to
    -- offer them. The one consequence worth knowing: with ElvUI ALSO loaded,
    -- its skin re-checks ns.Skin a second after this and takes the window. That
    -- is its documented recovery from "EllesmereUI never claimed", and it is
    -- the right outcome -- the user opted out of EllesmereUI's skinning, not of
    -- the ElvUI they are also running.
    return
  end

  -- Everything else takes the shim, which is the pre-8.6.8 behaviour and runs
  -- off helpers EllesmereUI has exported since 8.6.6. The two remaining causes
  -- share that answer but not their fix -- install or enable the sub-addon
  -- versus report a bug -- so they stay distinct in the diagnostic.
  silence = (DispatcherLoaded() == false) and "nodispatcher" or "silent"
  UseShim()
end

-- Backend selection is feature detection, never version parsing -- but the
-- feature being present is not the same as the handshake succeeding. A future
-- signature change (a required version argument, a table descriptor, a
-- name-collision rejection that raises) must degrade to the shim, which only
-- uses 8.6.6-era helpers and therefore still works, rather than throwing out
-- of the event handler and leaving the addon with no skin at all.
local function StartBackend()
  if S or not EUI then return end

  if type(EUI.RegisterSkin) ~= "function" then
    UseShim()
    return
  end

  -- The folder name, as EllesmereUI's guide asks: first registration of a name
  -- wins, and it is also the key its per-addon toggle is stored under, so
  -- anything else would be both collision-prone and unswitchable.
  local ok = pcall(EUI.RegisterSkin, ADDON_NAME, AdoptFacade)

  if not ok then
    UseShim()
  elseif C_Timer and C_Timer.After then
    C_Timer.After(HANDSHAKE_WAIT, OnSilence)
  else
    -- No timer to wait with, so no way to tell the three silences apart later.
    -- The shim is the only answer still available.
    UseShim()
  end
end

-- Detection AND registration are deferred, so load order can never decide
-- whether the skin runs. ADDON_LOADED covers a load-on-demand EllesmereUI (or
-- a sub-addon that publishes the global) arriving after us or after login;
-- PLAYER_LOGIN is where activation happens, because that is the point at which
-- EllesmereUI is fully initialised either way and its own dispatcher
-- explicitly supports late registration.
local loggedIn = false
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:RegisterEvent("ADDON_LOADED")
boot:SetScript("OnEvent", function(self, event)
  if event == "PLAYER_LOGIN" then
    loggedIn = true
    self:UnregisterEvent("PLAYER_LOGIN")
  end

  local host = _G.EllesmereUI
  if type(host) ~= "table" then return end   -- keep listening; a LoD load re-enters
  EUI = host

  -- Always reachable for the diagnostic once the host is found, even if the
  -- skin never activates (Postbox skinning turned off in EllesmereUI's own
  -- options, a facade that never answers). /postbox skin then reports which of
  -- those happened instead of looking like a broken theme.
  ns.SkinEllesmere = Skin

  -- Found before login: EllesmereUI may still be mid-initialisation, so hold
  -- until PLAYER_LOGIN and let that fire StartBackend.
  if not (loggedIn or (IsLoggedIn and IsLoggedIn())) then return end

  self:UnregisterAllEvents()
  StartBackend()
end)
