local ADDON_NAME, ns = ...

-- =====================================================================
-- Postbox :: EllesmereUI skin (optional, auto-applied)
-- ---------------------------------------------------------------------
-- Inert unless EllesmereUI is installed. Two backends, one skinning body:
--
--   "api"    -- EllesmereUI 8.6.8+ ships a public third-party skinning
--               API (EllesmereUI.RegisterSkin, see SKINNING_API.md at its
--               repo root). The surface is additive-only and versioned by
--               S.apiVersion: 1 is the primitives this file has always used,
--               2 (EllesmereUI 9.3) adds S.SetTabSelection, which the tabs
--               use where it exists. Preferred: EllesmereUI owns every
--               visual, so the skin tracks all their future tweaks for free.
--
--   "compat" -- wherever that API cannot answer. We build the same facade
--               ourselves out of the public helpers the parent addon has
--               exported since 8.6.6 -- the border engine, accent colour,
--               UI font and the pixel-perfect border helper -- reproducing
--               the house window style. NOT a legacy bridge: the API's
--               dispatcher lives in the Blizz UI Enhanced module
--               (EllesmereUIBlizzardSkin), so every player who runs
--               EllesmereUI with that module disabled lands here every
--               session, whatever their version (see OnSilence at the
--               bottom of the file). So does an EllesmereUI older than
--               8.6.8, until it updates and "api" takes over by itself.
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
-- Compatibility shim (no skinning API: Blizz UI Enhanced off, or < 8.6.8)
-------------------------------------------------------------
-- Values below mirror EllesmereUIBlizzardSkin's own window engine so the
-- result is visually identical to a natively-skinned Blizzard window.
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

-- The suite-wide baseline: EllesmereUI's Dark Mode "fill" colour (and alpha),
-- resolved per-profile (GetDarkModeFill -> active profile's darkMode table,
-- falling back to DEFAULT_DARK_MODE). It is the colour of the fills Postbox
-- draws itself -- the compat shim's backdrop, the floor under the host's
-- shell, popup grounds -- wherever no other skinner paints the windows beside
-- Postbox, and is what a profile import like atrocityUI actually sets. Its
-- alpha is Dark Mode's for unit and raid frames, not the windows', so what the
-- window takes is decided by Beside below.
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

-- The accent as a mark -- the selected tab's underline, a tick -- through the
-- contrast guard (Theme.GetAccentTone "mark": 3:1 on the plate it sits on),
-- read live, as every accent mark of Postbox's own is. The accent itself
-- where the theme cannot answer.
local function ShimMark()
  local T = ns.Theme
  if T and type(T.GetAccentTone) == "function" then
    local ok, r, g, b = pcall(T.GetAccentTone, "mark")
    if ok and type(r) == "number" then return r, g, b end
  end
  return ShimAccent()
end

-- The ticks the shim tinted, repainted on every accent change
-- (RepaintShimMarks). Weak: a discarded checkbox is not kept for this.
local shimTicks = setmetatable({}, { __mode = "k" })

local function RepaintShimMarks()
  local r, g, b = ShimMark()
  for tick in pairs(shimTicks) do tick:SetVertexColor(r, g, b, 1) end
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

-- EllesmereUI's one global Modern window backdrop (Blizz UI Enhanced > Modern
-- colour and opacity, default #111111 at 97%). The facade has no getter for
-- it, so it is read from the saved variable, read-only, with the engine's own
-- fallback (WindowEngine's GetModernBG).
local function ModernBackdrop()
  local db = _G.EllesmereUIDB
  local c = type(db) == "table" and db.blizzWindowModernDefault or nil
  if not (type(c) == "table" and type(c.r) == "number") then return 0.067, 0.067, 0.067, 0.97 end
  return c.r, c.g or 0.067, c.b or 0.067, tonumber(c.a) or 0.97
end

-------------------------------------------------------------
-- The windows beside Postbox
-------------------------------------------------------------
-- "Match EllesmereUI" means: look like the windows the player sees beside
-- Postbox. Which windows those are, and who paints them, depends on the
-- setup, so this is one answer, read by the opacity, the fill colour and the
-- Match border alike, and re-read on every apply (never cached, never per
-- frame):
--
--   "api" -- Blizz UI Enhanced paints Blizzard's windows: EllesmereUI's own
--            window look. The Dark Mode fill's colour; opaque under the
--            EllesmereUI window style, the Modern backdrop's own opacity under
--            Modern (the skinning API's style is the one Postbox's shell
--            wears); and for the edge the shell's own chrome, which S.Shell
--            lays down, so no line of Postbox's (edgePx 0).
--   "aes" -- compat, and atrocityEssentials skins Blizzard's windows (its Dark
--            Theme): the window colours its player saved, the backdrop's fill
--            and its edge, and an edge one physical pixel wide (its
--            SkinningAPI's EdgeFor).
--   "eui" -- compat otherwise: EllesmereUI draws no Blizzard window at all, so
--            the Dark Mode fill, colour and alpha -- the figure the player's UI
--            shares -- with a one-pixel black edge, EllesmereUI's own pixel
--            border convention (PP.CreateBorder, as its unit frames wear it).
--
-- Beside() returns r, g, b, a (the fill), er, eg, eb, ea (the edge), edgePx
-- (the edge's thickness in physical pixels; 0 = the shell's chrome is the
-- edge) and the source.
--
-- atrocityEssentials keeps its namespace private, so its saved variable is
-- read instead, read-only and pcall-guarded, as ModernBackdrop reads
-- EllesmereUI's.
local Beside, BesideProfile
do
  -- Its designed look (Core/Defaults.lua): what an unsaved colour reads as, or
  -- a component missing from a saved one (AceDB keeps only what differs).
  local AES_FILL = { 0.031, 0.031, 0.031, 0.80 }
  local AES_EDGE = { 0, 0, 0, 1 }
  local AES_ADDON = "atrocityEssentials"
  local LDS = "LibDualSpec-1.0"
  local charKey

  local function Loaded(name)
    local probe = (C_AddOns and C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
    if type(probe) ~= "function" then return nil end
    local ok, loaded = pcall(probe, name)
    if not ok then return nil end
    return loaded and true or false
  end

  -- AceDB's key for this character, "Name - Realm". Made once: it cannot
  -- change without a relog.
  local function CharKey()
    if charKey then return charKey end
    local name = type(UnitName) == "function" and UnitName("player") or nil
    local realm = type(GetRealmName) == "function" and GetRealmName() or nil
    if type(name) ~= "string" or type(realm) ~= "string" or name == "" then return nil end
    charKey = name .. " - " .. realm
    return charKey
  end

  -- The profile atrocityEssentials is using on this character. AceDB writes
  -- it into profileKeys when it loads and on every switch -- the account-wide
  -- profile atrocityEssentials applies at load (UseGlobalProfile), and
  -- LibDualSpec's per-spec profile at login and on every spec change -- so
  -- the live entry is the answer. The rest repeats that order, for a table
  -- AceDB has not loaded yet.
  local function ProfileName(db)
    local key = CharKey()
    local keys = db.profileKeys
    local name = (key and type(keys) == "table") and keys[key] or nil
    if type(name) == "string" then return name end
    name = "Default"
    local global = db.global
    if type(global) == "table" and global.UseGlobalProfile then
      name = type(global.GlobalProfile) == "string" and global.GlobalProfile or "Default"
    end
    local spaces = db.namespaces
    local lds = type(spaces) == "table" and spaces[LDS] or nil
    local chars = type(lds) == "table" and lds.char or nil
    local mine = (key and type(chars) == "table") and chars[key] or nil
    if type(mine) == "table" and mine.enabled and type(GetSpecialization) == "function" then
      local ok, spec = pcall(GetSpecialization)
      local pick = (ok and type(spec) == "number") and mine[spec] or nil
      if type(pick) == "string" then name = pick end
    end
    return name
  end

  -- Its Blizzard skinning is painting the windows: the Dark Theme switch
  -- (BlizzardSkinning.Frames.Enabled, on unless saved off; reload-bound in
  -- atrocityEssentials itself), and not stood down for ElvUI, which it does
  -- whenever ElvUI is loaded and its UseElvUI gate is not switched off
  -- (AE:ShouldNotLoadModule).
  local function SkinningOn(bs)
    local on
    local frames = type(bs) == "table" and bs.Frames or nil
    if type(frames) == "table" then on = frames.Enabled end
    if on == nil then on = true end
    if on ~= true then return false end
    if Loaded("ElvUI") then
      local gate = type(bs) == "table" and bs.UseElvUI or nil
      if not (type(gate) == "table" and gate.Enabled == false) then return false end
    end
    return true
  end

  -- One component of a saved colour, over the default.
  local function Part(saved, i, default)
    local v = type(saved) == "table" and tonumber(saved[i]) or nil
    return v or default[i]
  end

  -- The profile's BlizzardSkinning table, or false while atrocityEssentials
  -- is not loaded (no saved variable either way).
  local function Settings()
    if Loaded(AES_ADDON) == false then return false end
    local db = _G.atrocityEssentialsDB
    if type(db) ~= "table" then return false end
    local profiles = db.profiles
    local prof = type(profiles) == "table" and profiles[ProfileName(db)] or nil
    return type(prof) == "table" and prof.BlizzardSkinning or nil, db
  end

  -- Its window colours, or nil while it is not painting the windows.
  local function AESLook()
    local bs = Settings()
    if bs == false or not SkinningOn(bs) then return nil end
    local fill = type(bs) == "table" and bs.BackdropColor or nil
    local edge = type(bs) == "table" and bs.BorderColor or nil
    return Part(fill, 1, AES_FILL), Part(fill, 2, AES_FILL), Part(fill, 3, AES_FILL), Part(fill, 4, AES_FILL),
           Part(edge, 1, AES_EDGE), Part(edge, 2, AES_EDGE), Part(edge, 3, AES_EDGE), Part(edge, 4, AES_EDGE)
  end

  -- How solid EllesmereUI's own windows are (the api backend).
  local function ApiWindowAlpha()
    local style
    if S and type(S.GetStyle) == "function" then
      local ok, v = pcall(S.GetStyle)
      if ok then style = v end
    end
    if style == "modern" then
      local _, _, _, a = ModernBackdrop()
      return a
    end
    return 1
  end

  Beside = function()
    local r, g, b, a = HostBaseline()
    if BACKEND ~= "compat" then
      return r, g, b, ApiWindowAlpha(), 0, 0, 0, 1, 0, "api"
    end
    local ok, fr, fg, fb, fa, er, eg, eb, ea = pcall(AESLook)
    if ok and fr then return fr, fg, fb, fa, er, eg, eb, ea, 1, "aes" end
    return r, g, b, a, 0, 0, 0, 1, 1, "eui"
  end

  -- The atrocityEssentials profile being read, for the diagnostic; nil while
  -- it is not loaded.
  BesideProfile = function()
    local ok, bs, db = pcall(Settings)
    if not ok or bs == false or type(db) ~= "table" then return nil end
    return ProfileName(db)
  end
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

    -- Flat fill in the colour of the windows beside Postbox. EllesmereUI's own
    -- window art (modern_blizz.png) is a palette PNG with no tRNS chunk --
    -- fully opaque, and cropped per window aspect ratio, so it can neither be
    -- made see-through nor matched consistently. A flat fill can, in the
    -- colour those windows share (Beside).
    local br, bg_, bb = Beside()
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

    -- No frame of its own. The window's edge is the border option's, and
    -- nothing else draws one: Blizz UI Enhanced's shell chrome (the
    -- AdventureMap_TopBorder atlas stretched over the whole window) belongs to
    -- the windows it skins, and with it off no window beside Postbox wears it.
    -- Laid under a chosen border, it was a second, shadowed frame inside the
    -- window.
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
      local ar, ag, ab = ShimMark()
      checked:SetVertexColor(ar, ag, ab, 1)
      shimTicks[checked] = true
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
      local underline = tab.__pbShimUnderline
      if underline then
        -- Every repaint takes the accent as it is now: the accent sweep
        -- repaints a tab by re-issuing its selection, which lands here.
        local ar, ag, ab = ShimMark()
        underline:SetColorTexture(ar, ag, ab, 1)
        underline:SetShown(sel)
      end
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
  -- No facade, no facade callback. The compat backend follows accent, Dark
  -- Mode and profile changes live through the parent addon's own registries
  -- instead (HookHostRefreshes), and every window open re-resolves regardless.
  function shim.OnLooksChanged() end

  return shim
end

-------------------------------------------------------------
-- Optional outer window border (EllesmereUI's shared border engine)
-------------------------------------------------------------
-- Present in 8.6.6 and later, so this works on both backends: the same
-- Glow/Shadow/texture picker the rest of the suite uses, on a frame of its own,
-- so switching styles is live with no reload. On the compat backend the chosen
-- style is the window's only frame.
--
-- "Match EllesmereUI", the default, is the edge the windows beside Postbox
-- have (Beside), not a setting of EllesmereUI's: EllesmereUI has no border
-- for windows in general -- every module owns the border of its own kind of
-- frame, most of them none or a 1px black line hugging a bar, and the root
-- windowBorderSize/Texture an old Match read have never existed. So Match is:
--
--   api    -- EllesmereUI's own shell chrome, which S.Shell lays down for
--             every border but None (Apply's noBorder); nothing of Postbox's.
--   compat -- a line one physical pixel wide on the window's outer edge, in
--             the resolver's colour: atrocityEssentials' window edge where it
--             paints the windows (its backdrop's EdgeFor line, on the same
--             outermost pixel), a black one otherwise. Drawn by Postbox
--             (EnsureEdge), at whatever scale the window is.
--
-- Unset is Match. An explicitly saved None stays None, and every other style
-- is the shared engine's, drawn alone at its size step.
local BORDER_NONE = "none"
local BORDER_MATCH = "match"
local DEFAULT_BORDER = BORDER_MATCH
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

function Skin.GetBorderStyle()
  local saved = GetProfile().euiBorder
  if saved ~= nil then return saved end
  return DEFAULT_BORDER
end

-- Unset, or Match written by hand: both are Match, the default.
function Skin.IsBorderDefault()
  local saved = GetProfile().euiBorder
  return saved == nil or saved == BORDER_MATCH
end

-- Read by the options panel: whether the border row offers a "leave it alone"
-- entry, named as the opacity row's is ("Match EllesmereUI"). Here it is Match,
-- the edge of the windows beside Postbox, stored as unset. The Postbox style
-- offers none: its list names its own default (Thin).
function Skin.OffersBorderDefault()
  return true
end

-- True when the chosen border is drawn at a size step, so the Border size row
-- means something: not for None, and not for Match, whose edge is the
-- windows' own.
function Skin.BorderHasSize()
  local key = Skin.GetBorderStyle()
  return key ~= BORDER_NONE and key ~= BORDER_MATCH
end

function Skin.ResetBorder()
  local p = GetProfile()
  p.euiBorder, p.euiBorderSize = nil, nil
  Skin.ApplyBorder()
end

function Skin.GetBorderSize()
  local saved = tonumber((GetProfile().euiBorderSize))
  if saved then return saved end
  return DEFAULT_BORDER_SIZE
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
  if key == BORDER_MATCH then return Skin.ResetBorder() end
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

-- The edge of the windows beside Postbox (Beside): r, g, b, a, its thickness
-- in physical pixels (0: the shell's chrome is the edge, on the api backend)
-- and whose windows those are. Read by the options panel's drawing.
function Skin.GetEdge()
  local _, _, _, _, er, eg, eb, ea, px, source = Beside()
  return er, eg, eb, ea, px, source
end

-- One physical pixel in `frame`'s own units, at the scale it draws at:
-- atrocityEssentials' EdgeFor, and EllesmereUI's PP one-pixel. 768 UI units
-- span the screen's height at scale 1, so a pixel is 768 / the physical height
-- at scale 1, and that over the frame's effective scale here.
local function OnePixel(frame)
  local es = frame.GetEffectiveScale and frame:GetEffectiveScale()
  if type(es) ~= "number" or es <= 0 then return 1 end
  local ph
  if type(GetPhysicalScreenSize) == "function" then
    local _, h = GetPhysicalScreenSize()
    ph = h
  end
  if type(ph) == "number" and ph > 0 then return 768 / ph / es end
  if PixelUtil and type(PixelUtil.GetPixelToUIUnitFactor) == "function" then
    local ok, factor = pcall(PixelUtil.GetPixelToUIUnitFactor)
    if ok and type(factor) == "number" and factor > 0 then return factor / es end
  end
  return 1 / es
end

-- Match's line, on a frame of Postbox's own over the window: four strips,
-- each `px` physical pixels thick, inside the window's rect with their outer
-- side on its outer edge -- where atrocityEssentials' backdrop draws its edge
-- (the backdrop is the window's own rect; BackdropTemplate lays its edge
-- inside it) and where EllesmereUI's PP border sits. Pixel-grid snapping off,
-- as both of theirs have it: a strip exactly one pixel thick then covers
-- exactly one row of pixels wherever the window stands, where a snapped one
-- can round to none. Above the window's contents, as every border style but
-- Shadow is. Made the first time Match is drawn on the window.
local function EnsureEdge(frame)
  local edge = frame.__pbEuiEdge
  if edge then return edge end
  edge = CreateFrame("Frame", nil, frame)
  edge:EnableMouse(false)
  edge:SetAllPoints(frame)
  for i = 1, 4 do
    local strip = edge:CreateTexture(nil, "OVERLAY", nil, 7)
    if strip.SetSnapToPixelGrid then
      strip:SetSnapToPixelGrid(false)
      strip:SetTexelSnappingBias(0)
    end
    edge[i] = strip
  end
  frame.__pbEuiEdge = edge
  return edge
end

-- Lays the strips out again only when their thickness moved (a new window or
-- UI scale), so an ordinary apply is the four colours and nothing else.
local function PaintEdge(frame, r, g, b, a, px)
  local edge = EnsureEdge(frame)
  local w = px * OnePixel(frame)
  if edge.width ~= w then
    edge.width = w
    local top, bottom, left, right = edge[1], edge[2], edge[3], edge[4]
    top:ClearAllPoints()
    top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    top:SetHeight(w)
    bottom:ClearAllPoints()
    bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    bottom:SetHeight(w)
    left:ClearAllPoints()
    left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -w)
    left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, w)
    left:SetWidth(w)
    right:ClearAllPoints()
    right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -w)
    right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, w)
    right:SetWidth(w)
  end
  for i = 1, 4 do edge[i]:SetColorTexture(r, g, b, a) end
  edge:SetFrameLevel((frame:GetFrameLevel() or 1) + 8)
  edge:Show()
end

-- Re-draw the outer border from the saved style/size. Safe to call any time.
function Skin.ApplyBorder(frame)
  if not frame then return Skin.ForEachWindow(Skin.ApplyBorder) end
  local key = Skin.GetBorderStyle()

  -- Match: the resolver's edge, where it is a line (compat); on the api
  -- backend the shell's chrome is the edge and nothing is drawn here -- unless
  -- the window wears the compat shell, built before the facade took over
  -- mid-session (AdoptFacade), which has no chrome: it keeps its line.
  local edge = frame.__pbEuiEdge
  if key == BORDER_MATCH then
    local _, _, _, _, er, eg, eb, ea, px = Beside()
    if px == 0 and frame.__pbShimShell then px = 1 end
    if px > 0 then
      PaintEdge(frame, er, eg, eb, ea, px)
    elseif edge then
      edge:Hide()
    end
  elseif edge then
    edge:Hide()
  end

  if not (EUI and EUI.ApplyBorderStyle) then return end

  local host = frame.__pbEuiBorderHost
  if not host then
    host = CreateFrame("Frame", nil, frame)
    host:EnableMouse(false)
    host:SetAllPoints(frame)
    frame.__pbEuiBorderHost = host
  end

  -- A chosen style is drawn alone: on the compat backend nothing else frames
  -- the window (the shim lays down no chrome of its own). None and Match draw
  -- nothing from the shared engine.
  if key == BORDER_NONE or key == BORDER_MATCH then
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

-- The window scale moved (MailboxUI.ApplyWindowScale). A pixel line is sized
-- in whole physical pixels at the scale it was drawn at -- EllesmereUI's Solid
-- snaps its strips once, when it is applied -- so each window's border is
-- drawn again at the new one. The UI scale and the screen are watched in
-- HookHostRefreshes.
function Skin.ApplyScale()
  pcall(Skin.ApplyBorder)
end


-------------------------------------------------------------
-- Background baseline: colour and opacity
-------------------------------------------------------------
-- One absolute alpha for the window backdrop. Unset ("Match EllesmereUI"), the
-- window is exactly as solid as EllesmereUI's own windows: its shell art is left
-- at the alpha EllesmereUI itself gives it -- opaque under the EllesmereUI
-- style, the Modern backdrop's own colour and opacity (97% by default) under
-- Modern -- so the Modern opacity control EllesmereUI players already know
-- governs Postbox too. On the compat backend, where EllesmereUI draws no
-- windows, it follows the windows that are there (see Beside); on the api
-- backend the Dark Mode fill's alpha is for unit and raid frames, 90% by
-- default, a touch more see-through than every EllesmereUI window beside it.
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
--
-- Unset, both are the windows beside Postbox's (Beside, above): EllesmereUI's
-- own on the api backend; on compat, where EllesmereUI draws no Blizzard window
-- and "opaque" left Postbox a solid slab beside see-through ones,
-- atrocityEssentials' where it paints them and the Dark Mode fill otherwise.

-- The options panel is deliberately exempt from the user's transparency (its
-- whole job is to stay legible while the window behind it is adjusted).
local OPAQUE_ALPHA = 0.97

-- The window's opacity: the user's own, or the windows' beside it (see above).
function Skin.GetBgOpacity()
  local saved = tonumber(GetProfile().euiBgAlpha)
  if saved then return saved end
  local _, _, _, a = Beside()
  return a
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
  -- Two alphas, equal whenever the user has set one. Unset, Postbox's own fill
  -- (the backdrop where it owns it) takes EllesmereUI's window opacity, while
  -- the host's shell art is driven to 1 -- its region alpha, which multiplies
  -- the colour alpha the host gave it, so the Modern backdrop keeps its own 97%.
  -- The compat shim has no host art, and its title strip takes the fill's alpha.
  local saved = tonumber((GetProfile().euiBgAlpha))
  local _, _, _, besideAlpha = Beside()
  local alpha = saved or besideAlpha
  local hostAlpha = saved or (BACKEND == "compat" and alpha) or 1

  local function paint(f)
    if not f then return end
    -- Before anything is read: a deferred border or a texture built on the
    -- window's first OnShow is host art that ApplyShell's picture predates.
    if RescanHostArt then pcall(RescanHostArt, f) end
    local opaque = f.__pbEuiAlwaysOpaque and true or false
    local a = opaque and OPAQUE_ALPHA or alpha
    local ha = opaque and OPAQUE_ALPHA or hostAlpha
    local r, g, b = Beside()

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

    -- The host's art is driven to the chosen alpha only where the HOST shows
    -- it. EllesmereUI's shell carries both of its backdrops at once and picks
    -- one by region alpha: under its Modern style it holds the atlas art and
    -- its darkening overlay at 0 and shows a flat fill (WindowEngine's
    -- ApplyShellStyle). Raising every region to the chosen alpha put the
    -- EllesmereUI art back under the Modern fill.
    --
    -- The host writes only 0 or 1, and only when it restyles, so a region whose
    -- alpha is no longer the one written here last was set by the host since:
    -- that is when its shown/hidden state is re-read. First sight reads it
    -- straight from the host. Under the EllesmereUI style every region is shown
    -- and this is the same single SetAlpha it always was. The one case it
    -- cannot see is a restyle while the window sits at 0% -- zero over zero --
    -- which the next restyle or /reload settles.
    local hostArt = f.__pbEuiHostArt
    if hostArt then
      local wrote, shown = f.__pbEuiArtWrote, f.__pbEuiArtShown
      if not (wrote and shown) then
        wrote, shown = {}, {}
        f.__pbEuiArtWrote, f.__pbEuiArtShown = wrote, shown
      end
      for i = 1, #hostArt do
        local region = hostArt[i]
        if region and region.SetAlpha then
          local now = region.GetAlpha and region:GetAlpha()
          local last = wrote[region]
          if shown[region] == nil
             or (type(now) == "number" and type(last) == "number"
                 and math.abs(now - last) > 0.01) then
            shown[region] = not (type(now) == "number" and now <= 0.01)
          end
          local target = shown[region] and ha or 0
          region:SetAlpha(target)
          wrote[region] = target
        end
      end
    end

    -- The shim's title strip stands for the host's, which the host leaves at
    -- region alpha 1 over its colour's own 0.5.
    if f.__pbShimTopBar then f.__pbShimTopBar:SetAlpha(ha) end
  end

  if frame then paint(frame) else Skin.ForEachWindow(paint) end
end

-- Postbox's own flat fill, in the colour of the windows beside it, at the very
-- bottom of the window. On compat this is the whole backdrop; on api it is the
-- floor under EllesmereUI's shell and the thing that makes the always-opaque
-- exemption possible there.
local function EnsureShellArt(frame)
  local art = frame.__pbEuiShellArt
  if art then return art end
  art = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
  art:SetAllPoints(frame)
  local r, g, b = Beside()
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
-- The window fill's colour and alpha, for the grounds Postbox lays under its
-- popups and detail panels: the windows beside Postbox's (Beside).
function Skin.GetHostBaseline()
  local r, g, b, a = Beside()
  return r, g, b, a
end

function Skin.GetAccent()
  if not (S and S.GetAccentColor) then return nil end
  local ok, r, g, b = pcall(S.GetAccentColor)
  if ok and r then return r, g, b end
  return nil
end

-- EllesmereUI's font for all of Postbox's text: path, outline flags and
-- whether a drop shadow goes with it, for Theme.HostFont. The face and flags
-- are the facade's own answer (S.GetFont, "the user's UI font", the one its
-- S.Font sets); the shadow follows its rule for its own strings -- a drop
-- shadow only with no outline, and then only while the player's shadow toggle
-- is on (WindowEngine's ResolveTheme). The outline is the player's EllesmereUI
-- Outline Mode, applied as EllesmereUI applies it to its own window text.
function Skin.GetFontFace()
  if not (S and type(S.GetFont) == "function") then return nil end
  local ok, path, flags = pcall(S.GetFont)
  if not ok or type(path) ~= "string" or path == "" then return nil end
  if type(flags) ~= "string" then flags = "" end
  local shadow = (flags == "")
  if shadow and EUI and type(EUI.GetFontUseShadow) == "function" then
    local ok2, use = pcall(EUI.GetFontUseShadow, "blizzardSkin")
    if ok2 then shadow = use and true or false end
  end
  return path, flags, shadow
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

-- A push button: the house primitive, and its fonts in EllesmereUI's face. The
-- primitive leaves a label's font alone (its own buttons keep the game font);
-- Postbox's text is all in the house face, and a label beside plates and rows
-- set in it would be the one string in the game font. Its state fonts are what
-- change, not the label's, because the button puts those back on the label at
-- every enable and disable.
local function SkinButton(btn)
  S.Button(btn)
  if ns.Theme and type(ns.Theme.HostFontButton) == "function" then
    pcall(ns.Theme.HostFontButton, btn)
  end
end

local function SkinOne(c)
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
    if c.__postboxButton then SkinLeaf(c, SkinButton) end
  end
end

-- Depth-first, each node's children in turn, eight levels down, on one stack
-- reused by every walk (filled in place: no garbage); a walk begun inside a
-- walk takes its own.
local SkinTree
do
  local stack, depths = {}, {}
  local busy = false

  local function Push(st, dp, n, d, ...)
    for i = select("#", ...), 1, -1 do
      n = n + 1
      st[n], dp[n] = (select(i, ...)), d
    end
    return n
  end

  local function Walk(frame, st, dp)
    local n = Push(st, dp, 0, 1, frame:GetChildren())
    while n > 0 do
      local c, d = st[n], dp[n]
      st[n], dp[n] = nil, nil
      n = n - 1
      if c then
        if c.IsObjectType then SkinOne(c) end
        if d <= 8 then n = Push(st, dp, n, d + 1, c:GetChildren()) end
      end
    end
  end

  SkinTree = function(frame, depth)
    if not frame then return end
    if busy then return Walk(frame, {}, {}) end
    -- Every caller walks under pcall and moves on, so a failure here ends
    -- the walk the same way; the stack is emptied either way.
    busy = true
    pcall(Walk, frame, stack, depths)
    for i = #stack, 1, -1 do stack[i], depths[i] = nil, nil end
    busy = false
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
          -- Kept on the tab either way: the plate sweep re-issues it.
          t.isSelected = selected and true or false
          -- API v2's call for tabs an addon switches itself: the selection is
          -- held in EllesmereUI's own state for the tab, ahead of anything it
          -- would read off the tab or its parent, and the tab repaints. Before
          -- v2, the flag above and a re-skin, which reads it.
          if type(S.SetTabSelection) == "function" then
            S.SetTabSelection(t, t.isSelected)
          else
            S.Tab(t)
          end
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

-- The mailbox window's open: the walk only where something was tagged for
-- the skins since this window's last one (Theme.SkinGeneration; every step
-- of the walk skins a frame once), the colour and alpha re-assert always.
local walkedAt = setmetatable({}, { __mode = "k" })

function Skin.RefreshWindow(frame)
  if not (S and frame) then return end
  local T = ns.Theme
  local gen = T and type(T.SkinGeneration) == "function" and T.SkinGeneration() or nil
  if gen ~= nil and walkedAt[frame] == gen then
    pcall(Skin.ApplyBgOpacity)
    return
  end
  Skin.Refresh(frame)
  walkedAt[frame] = T and type(T.SkinGeneration) == "function" and T.SkinGeneration() or nil
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
  -- Accent, Dark Mode, profile and window-style changes arrive live
  -- (RequestHostRefresh), so this is the backstop: for an EllesmereUI without
  -- the style refresh to hook (whose RefreshStyles repaints the host shell on
  -- our frame at full alpha and tells nobody), and for anything a future
  -- EllesmereUI moves without saying so.
  pcall(function()
    frame:HookScript("OnShow", function() Skin.OnHostLooksChanged(true) end)
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
    frame:HookScript("OnShow", function() Skin.OnHostLooksChanged(true) end)
  end)
  Skin.Refresh(frame)
end

-- The accent-tinted icons: the minimap mail icon (outside every window, so
-- re-tinted whether or not the mailbox has ever been opened), the options cog
-- and the view toggle. Core/Theme.lua holds them, for the ElvUI skin too.
function Skin.RefreshAccents()
  if ns.Theme and type(ns.Theme.RepaintAccentIcons) == "function" then
    ns.Theme.RepaintAccentIcons()
  end
end

-- The screens that fit text to its width, measured again after the text's
-- face moved: the Mail tab's columns and captions, Mail Memory's rows and the
-- options panel's controls, as the Postbox style does after a font change
-- (Skin_Postbox's RefitScreens). A screen not showing is measured when it
-- next shows.
local function RefitScreens()
  local UI = ns.MailboxUI
  if UI then
    if type(UI.RefreshCollectRowLayout) == "function" then pcall(UI.RefreshCollectRowLayout) end
    if type(UI.RefreshCollectTabCounts) == "function" then pcall(UI.RefreshCollectTabCounts) end
  end
  local MM = ns.MailMemory
  if MM and type(MM.Refresh) == "function" then pcall(MM.Refresh) end
  local panel = ns.OptionsPanel
  if panel and type(panel.RefreshControls) == "function" then pcall(panel.RefreshControls) end
end

-- Window tabs, view segments and category tiles sample the accent at paint
-- time; Theme.RepaintPlates sweeps a window for both kinds (the ones this
-- skin's selection override owns, and Postbox's own).
local function RepaintPlates(frame)
  if ns.Theme and type(ns.Theme.RepaintPlates) == "function" then
    ns.Theme.RepaintPlates(frame, 0)
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
--
-- `fromShow` is that hook. A window opening repaints its fill, border and
-- accent icons every time, but the accent text and the plate sweep only when
-- the looks they paint from are not the ones they were last painted in: every
-- live signal repaints both on the spot, open window or not, so on an open the
-- sweep is usually a repeat. What they paint from is read afresh here -- the
-- facade and which skin holds the window, the accent, the window style, the
-- house font and the panel colour -- so a change that arrived with no signal
-- while the window was closed (a Blizz UI Enhanced style switch, or a hook
-- that never registered) still differs, and the next open paints it.
local looksPainted, looksNow = {}, {}
local LOOKS_COUNT = 12

local function ReadLooks(out)
  local r, g, b = Skin.GetAccent()
  out[1], out[2], out[3], out[4], out[5] = S, ns.Skin, r, g, b
  local style, path, flag, pr, pg, pb, pa
  if type(S.GetStyle) == "function" then
    local ok, v = pcall(S.GetStyle)
    if ok then style = v end
  end
  if type(S.GetFont) == "function" then
    local ok, v1, v2 = pcall(S.GetFont)
    if ok then path, flag = v1, v2 end
  end
  if type(S.GetPanelColor) == "function" then
    local ok, v1, v2, v3, v4 = pcall(S.GetPanelColor)
    if ok then pr, pg, pb, pa = v1, v2, v3, v4 end
  end
  out[6], out[7], out[8], out[9], out[10], out[11], out[12] = style, path, flag, pr, pg, pb, pa
end

function Skin.OnHostLooksChanged(fromShow)
  if not S then return end
  -- The house font on Postbox's text (Theme.HostFont): moved only if the face
  -- the facade answers is not the one the text wears, so on almost every pass
  -- this is one read and a compare. When it did move -- EllesmereUI's font or
  -- its Outline Mode changed -- the widths fitted to the old face are
  -- forgotten, and the screens that fit text are measured again.
  if ns.Theme and type(ns.Theme.RefreshHostFonts) == "function" then
    local ok, moved = pcall(ns.Theme.RefreshHostFonts)
    if ok and moved then RefitScreens() end
  end
  pcall(Skin.ApplyBgOpacity)          -- baseline fill colour + opacity
  pcall(Skin.ApplyBorder)             -- the user's configured window border
  pcall(Skin.RefreshAccents)          -- options cog, collect view toggle

  local ok = pcall(ReadLooks, looksNow)
  local same = ok and looksPainted.valid
  if same then
    for i = 1, LOOKS_COUNT do
      if looksNow[i] ~= looksPainted[i] then same = false break end
    end
  end
  if fromShow and same then return end
  if ok then
    for i = 1, LOOKS_COUNT do looksPainted[i] = looksNow[i] end
  end
  looksPainted.valid = ok

  -- Accent-toned TEXT. The plate sweep below repaints art; headings, field
  -- captions and tile captions are font strings and were the half nothing
  -- tracked, so they kept the previous accent until their role happened to be
  -- re-applied. Core/Theme.lua keeps the (weak) registry; this is the one
  -- moment it is worth reading.
  if ns.Theme and type(ns.Theme.RepaintAccentText) == "function" then
    pcall(ns.Theme.RepaintAccentText)
  end
  -- The compat shim's ticks; its tab underlines repaint through the plate
  -- sweep below, which re-issues each tab's selection.
  pcall(RepaintShimMarks)
  Skin.ForEachWindow(RepaintPlates)
end

-- Every live "EllesmereUI's looks changed" signal lands here and is folded into
-- ONE pass of the handler above, on the next frame. Four sources (the fourth,
-- EllesmereUI._WSkinRefreshStyles, the window-style repaint, is explained where
-- it is hooked, in HookHostRefreshes):
--
--   S.OnLooksChanged (api backend). Rides EllesmereUI's accent registry, so it
--     fires on the accent and on Blizz UI Enhanced's global look settings --
--     once per tick while a colour picker is being dragged. It does NOT fire on
--     a window-style switch or a profile switch, whatever its comment says.
--   EllesmereUI.RegisterDarkModeRefresh (both backends; the parent addon). Runs
--     on every Dark Mode palette edit AND on every profile switch, because the
--     profile repoint calls RefreshDarkMode. The palette is Postbox's baseline,
--     colour and alpha, so this is what makes a profile switch live at last.
--   EllesmereUI.RegAccent (compat backend only). The registry the api facade's
--     own callback rides on. Compat is where every player with Blizz UI
--     Enhanced disabled lands, and there an accent change used to wait for the
--     next window open.
--
-- Next frame rather than in place: a profile switch refreshes the dark palette
-- first and re-resolves the accent after it (RefreshAllAddons runs
-- RefreshAccent once the repoint is done), so a pass run inside the first
-- callback would paint the old accent. The next frame is also after every host
-- repaint queued in this one, which settles the ordering question above. A
-- flag, not a timer per call: a picker drag costs one pass per frame at most.
local refreshPending = false

local function RunHostRefresh()
  refreshPending = false
  -- The host's font can move with the rest of its looks, and a caption Theme
  -- measured in the old one is measured again on its next fit.
  if ns.Theme and type(ns.Theme.ForgetFits) == "function" then ns.Theme.ForgetFits() end
  pcall(Skin.OnHostLooksChanged)
end

local function RequestHostRefresh()
  if refreshPending then return end
  refreshPending = true
  if C_Timer and C_Timer.After then
    C_Timer.After(0, RunHostRefresh)
  else
    RunHostRefresh()
  end
end

-- Registered once each, whichever backend activates first: EllesmereUI keeps
-- its refreshers in plain lists, so a second registration would run twice.
local hooked = { darkMode = false, accent = false, styles = false, scale = false }

local function HookHostRefreshes()
  if not EUI then return end
  if not hooked.darkMode and type(EUI.RegisterDarkModeRefresh) == "function" then
    hooked.darkMode = pcall(EUI.RegisterDarkModeRefresh, function() RequestHostRefresh() end)
  end
  -- Window styles. Blizz UI Enhanced's style dropdowns and its Modern colour
  -- swatch call EllesmereUI._WSkinRefreshStyles (WindowEngine's RefreshStyles,
  -- published on EllesmereUI's own table for its options page), which repaints
  -- every registered shell -- Postbox's among them, at region alpha 1 -- and
  -- fires no looks callback. A post-hook on that table entry, never a Blizzard
  -- one, sees every call; the refresh it asks for puts Postbox's opacity back
  -- on the next frame. An underscore field: where it is missing, the window's
  -- next open re-asserts, as it always has.
  if not hooked.styles and type(EUI._WSkinRefreshStyles) == "function"
     and type(hooksecurefunc) == "function" then
    hooked.styles = pcall(hooksecurefunc, EUI, "_WSkinRefreshStyles", function() RequestHostRefresh() end)
  end
  -- The api facade already delivers accent changes through S.OnLooksChanged.
  -- RegAccent calls its entries without a pcall of its own, in the middle of
  -- EllesmereUI's accent pass, so this entry must never be able to throw.
  if BACKEND == "compat" and not hooked.accent and type(EUI.RegAccent) == "function" then
    hooked.accent = pcall(EUI.RegAccent, {
      type = "callback",
      fn = function() pcall(RequestHostRefresh) end,
    })
  end
  -- The UI scale or the screen changed: a physical pixel is a different number
  -- of UI units, so the window borders are drawn again (next frame, with
  -- everything else). Two events that fire only on such a change; a window
  -- opened later re-draws its border on its own. Compat only: that is where
  -- Postbox draws a pixel line of its own (Match), EllesmereUI re-snaps its
  -- own on this event, and on the api backend Match is the shell's chrome.
  -- EllesmereUI's own UI-scale slider sets UIParent's scale directly and fires
  -- neither: there the next window open does it.
  if BACKEND == "compat" and not hooked.scale and type(CreateFrame) == "function" then
    local watch = CreateFrame("Frame")
    watch:RegisterEvent("UI_SCALE_CHANGED")
    watch:RegisterEvent("DISPLAY_SIZE_CHANGED")
    watch:SetScript("OnEvent", RequestHostRefresh)
    hooked.scale = true
  end
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

-- Set when this skin refuses the window on purpose. Three causes:
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
--   "stocklook"   EllesmereUI's whole UI is on one of its stock looks
--                 (Blizzard Style or Classic WoW UI; see HostLook below), so
--                 Postbox wears its own Blizzard look to match.
--
-- Reported by Diagnose -- i.e. /postbox skin, which is this addon's only debug
-- channel. A chat line at login would be noise about a situation nobody can act
-- on from the chat frame.
local standDown          -- nil | "elvui" | "hostoptout" | "stocklook"

local STAND_DOWN_TEXT = {
  elvui      = "stood down (ElvUI painted first)",
  hostoptout = "stood down (EllesmereUI skinning is switched off for Postbox)",
  stocklook  = "stood down (EllesmereUI is on a stock look; Postbox's own Blizzard look matches it)",
}

-------------------------------------------------------------
-- EllesmereUI's look (Global Settings > Style)
-------------------------------------------------------------
-- EllesmereUI 9.2.5 added three looks: its own, "Blizzard Style" (the current
-- stock art) and "Classic WoW UI" (the vanilla art). The flags are per MODULE
-- and every one is reload-gated and latched for the session; there is no single
-- whole-UI setting. What there is, is a record of the WHOLE-UI switch -- the
-- first-install picker and the Style page's Apply to All -- kept per profile:
--
--   profiles[p].windowSkinLook      written beside the window-skin swap (Blizz
--                                   UI Enhanced only), and what decides the
--                                   look of Blizzard's own windows;
--   fonts._styleSlots.active        written beside the font swap, in the parent
--                                   addon, so present with Blizz UI Enhanced
--                                   off (not in glyph-fallback locales).
--
-- EllesmereUI.ProfileWindowSkinLook reads exactly this pair, in that order,
-- when Blizz UI Enhanced is loaded; the fallback below repeats it for when it
-- is not. None of this is the skinning API -- that answers only "eui" or
-- "modern", and deliberately keeps third-party skins on the EllesmereUI theme
-- under a stock look (GetThirdPartySkinStyle votes from the EllesmereUI look's
-- window slot). Every step is nil-guarded, and anything unreadable is the
-- EllesmereUI look, which is what every session was before this existed.
--
-- Why a stock look steps Postbox down: under one, EllesmereUI turns its skins
-- off Blizzard's windows (first visit: every window at Blizz Default), so the
-- mailbox, bags and character sheet the player sees are Blizzard's. Postbox's
-- own look is built from Blizzard's art for exactly that company; EllesmereUI's
-- flat dark window would be the odd one out. Classic WoW UI maps there too: of
-- the looks Postbox has, the stone-and-gold one is the vanilla UI's relative.
--
-- Read once, when the skin first activates, like every EllesmereUI module
-- latches its style: a profile switch that changes the look is reload-bound in
-- EllesmereUI itself (it offers the reload), and Postbox's style is claimed at
-- login, so the two change together at that reload.
local LOOKS = { eui = true, blizzard = true, classic = true }
local hostLook           -- nil until read; then "eui" | "blizzard" | "classic"

local function ReadHostLook()
  local db = _G.EllesmereUIDB
  if type(db) ~= "table" then return "eui" end

  if EUI and type(EUI.ProfileWindowSkinLook) == "function"
     and type(EUI.GetActiveProfileData) == "function" then
    local ok, look = pcall(function()
      return EUI.ProfileWindowSkinLook(EUI.GetActiveProfileData(), db.fonts)
    end)
    if ok and LOOKS[look] then return look end
  end

  local profiles = db.profiles
  local prof = type(profiles) == "table" and profiles[db.activeProfile or "Default"] or nil
  local look = type(prof) == "table" and prof.windowSkinLook or nil
  if LOOKS[look] then return look end

  local fonts = db.fonts
  local slots = type(fonts) == "table" and fonts._styleSlots or nil
  look = type(slots) == "table" and slots.active or nil
  if LOOKS[look] then return look end
  return "eui"
end

local function HostLook()
  if hostLook == nil then
    local ok, look = pcall(ReadHostLook)
    hostLook = (ok and LOOKS[look]) and look or "eui"
  end
  return hostLook
end

-- "blizzard" or "classic" while this skin has stood down for EllesmereUI's
-- stock look; nil otherwise. The options panel's inheritance badge reads it.
function Skin.GetStockLook()
  if standDown == "stocklook" then return hostLook end
  return nil
end

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
      local r, g, b = Beside()
      shellArt = string.format("Postbox fill %.3f/%.3f/%.3f @ %.2f",
                               r, g, b, Skin.GetBgOpacity())
    else
      shellArt = "MISSING"
    end
  end

  -- Which windows "Match EllesmereUI" is matching, and what it reads off them.
  -- Printed after the shell art by /postbox skin: the one line that says why
  -- the fill, the opacity and the Match border are what they are.
  local fr, fg, fb, fa, er, eg, eb, ea, px, source = Beside()
  local besideText
  if source == "aes" then
    besideText = string.format(
      "matching atrocityEssentials' windows (profile %s): fill %.3f/%.3f/%.3f @ %.2f, edge %d px %.2f/%.2f/%.2f @ %.2f",
      tostring(BesideProfile() or "?"), fr, fg, fb, fa, px, er, eg, eb, ea)
  elseif source == "eui" then
    besideText = string.format(
      "matching EllesmereUI's Dark Mode fill %.3f/%.3f/%.3f @ %.2f, edge %d px %.2f/%.2f/%.2f @ %.2f",
      fr, fg, fb, fa, px, er, eg, eb, ea)
  else
    besideText = string.format("matching EllesmereUI's own windows @ %.2f, edge: its shell's frame", fa)
  end
  if not standDown then shellArt = shellArt .. " | " .. besideText end
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
    -- The skinning API's theme, then EllesmereUI's whole-UI look once it has
    -- been read (Activate reads it; a style choice other than EllesmereUI never
    -- gets that far). Printed as one field by /postbox skin.
    style       = hostLook and (style .. ", EllesmereUI look " .. hostLook) or style,
    look        = hostLook,
    borderStyle = Skin.GetBorderStyle(),
    -- Match has no size step: its line's width in pixels (0: the shell's chrome).
    borderSize  = (Skin.GetBorderStyle() == BORDER_MATCH) and px or Skin.GetBorderSize(),
    bgOpacity   = Skin.GetBgOpacity(),
    shellArt    = shellArt,
    windowBuilt = frame ~= nil,
    -- "api" | "aes" | "eui": whose windows the defaults match (Beside).
    beside      = source,
    besideText  = besideText,
  }
end

-------------------------------------------------------------
-- Activation
-------------------------------------------------------------
local function Activate()
  if not S then return end

  -- The player can prefer Postbox's own look to their UI pack's. Checked here
  -- rather than at the boot handler because this file reaches Activate from
  -- several paths -- the official handshake, its watchdog, and the compat shim
  -- -- and every one of them must respect the choice.
  local UI = ns.MailboxUI
  if UI and type(UI.HostSkinAllowed) == "function" and not UI.HostSkinAllowed() then
    return
  end

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

  -- EllesmereUI's whole UI on Blizzard Style or Classic WoW UI: Postbox wears
  -- its own Blizzard look to match (see HostLook). Nothing is claimed, exactly
  -- as for the opt-out, so the window builds in Postbox's own theme and the
  -- options panel offers no EllesmereUI appearance rows. Only a player who left
  -- the style on EllesmereUI gets here: an explicit Postbox style already
  -- returned above.
  if HostLook() ~= "eui" then
    standDown = "stocklook"
    return
  end
  standDown = nil

  ns.Skin = Skin      -- take precedence over the ElvUI skin, if one loaded
  ns.SkinAppliedBy = "ellesmereui"

  -- Everything host-derived, not just the two accent-tinted icons: an accent,
  -- profile or border change moves the fill colour, its alpha, the border and
  -- every plate caption in the window. All of it through the one coalesced
  -- request (see RequestHostRefresh).
  if type(S.OnLooksChanged) == "function" then
    pcall(S.OnLooksChanged, function() RequestHostRefresh() end)
  end
  HookHostRefreshes()

  local frame = ns.MailboxUI and ns.MailboxUI._frame
  if frame then Skin.Apply(frame) end

  -- A claim that lands after windows were built -- the watchdog's, or
  -- skinning switched back on mid-session -- skins each of them as its build
  -- would have (each bails on its own key if it already wears the skin),
  -- tints the accent icons, the minimap's among them, whether or not a
  -- window exists, and moves text set before the face was published into it.
  local T = ns.Theme
  if T and type(T.ForEachWindow) == "function" then T.ForEachWindow(Skin.ApplyWindow) end
  pcall(Skin.RefreshAccents)
  if T and type(T.AdoptHostFace) == "function" then
    local ok, moved = pcall(T.AdoptHostFace)
    if ok and moved then RefitScreens() end
  end
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

-- How long to wait for the callback before deciding it is not coming, when
-- the dispatcher that would send it is loaded (with it absent, StartBackend
-- decides at once). The dispatcher fires at PLAYER_LOGIN, in the same frame
-- as our own registration, so this is slack rather than a real budget.
local HANDSHAKE_WAIT = 5

-- Nothing arrived. Which silence is it? Asked at once when the dispatcher is
-- not loaded (nothing could ever arrive), and by the watchdog otherwise.
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

  -- Everything else takes the shim, which runs off helpers EllesmereUI has
  -- exported since 8.6.6. "nodispatcher" is the everyday case, not a rare
  -- one: every player with Blizz UI Enhanced disabled. The two remaining causes
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
  elseif S then
    -- Answered inside the registration (the dispatcher calls a skin
    -- registered after its own login straight away).
    return
  elseif DispatcherLoaded() == false then
    -- Blizz UI Enhanced is off: its dispatcher is the only thing that could
    -- ever answer, so there is nothing to wait for. Decided now, at login,
    -- before any Postbox window or text is made -- the opt-out and the
    -- stand-downs exactly as the watchdog would have decided them.
    OnSilence()
  elseif C_Timer and C_Timer.After then
    -- The dispatcher is loaded and has not answered yet: the watchdog, for
    -- the one silence that can still end in a callback.
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
