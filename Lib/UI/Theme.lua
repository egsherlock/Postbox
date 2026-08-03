-- Postbox foundation :: the theme.
--
-- One concern, one file: the palette, font sizing, surface painting, the
-- button factory, list-row striping, and the thin facade Core/Theme.lua
-- installs onto ns.Theme.
--
-- Publishes: ns.Core.UI.Theme, ns.Core.UI.RowStyling

local _, ns = ...

ns.Core = ns.Core or {}
local Core = ns.Core
Core.UI = Core.UI or {}
Core.UI.Theme = Core.UI.Theme or {}
Core.UI.RowStyling = Core.UI.RowStyling or {}

local Theme = Core.UI.Theme
local RowStyling = Core.UI.RowStyling

local floor = math.floor
local max = math.max

-------------------------------------------------------------
-- Palette
--
-- Published as data so a host-UI skin can read or override it rather than
-- hiding our textures and painting over them.
-------------------------------------------------------------

-- Backdrop schemes. `list` must be fully opaque so rows scrolling behind other
-- content cannot show through; `card` is near-opaque; `controls` is a
-- barely-there tint that must read as a divider, not a panel.
--
-- `card` was 0.92, which is below the opacity floor the addon holds every
-- text-bearing surface to (0.95): a card is what the contact picker, the
-- type-ahead list and the dropdown are made of, and 8% of the window behind a
-- popup is a scroll bar showing through a name the reader is trying to pick.
-- Core/Theme.lua recolours these to its own palette, where the card is fully
-- opaque; this is the value the foundation layer carries on its own.
Theme.Palette = {
  list = {
    bg = { 0.00, 0.00, 0.00, 1.00 },
    border = { 0.46, 0.36, 0.24, 0.55 },
    surface = true,
  },
  card = {
    bg = { 0.00, 0.00, 0.00, 0.95 },
    border = { 0.46, 0.36, 0.24, 0.55 },
    surface = true,
  },
  controls = {
    bg = { 0.15, 0.14, 0.12, 0.34 },
    border = { 0.34, 0.31, 0.27, 0.82 },
    surface = false,
  },
}

-- Alternating list rows. A neutral cool grey at very low alpha: the even
-- stripe is roughly twice the odd one, and hover roughly twice the even
-- stripe, so the scheme stays readable over our stone background and over a
-- host UI's dark backdrop alike.
Theme.RowColors = {
  even = { 0.62, 0.66, 0.72, 0.10 },
  odd = { 0.48, 0.52, 0.58, 0.05 },
  hover = { 0.62, 0.66, 0.72, 0.20 },
}

-- Icon tints: a vertex colour laid over artwork that already exists, which is a
-- different thing from a backdrop scheme and so does not belong in Palette.
--
-- `starEmpty` is the hollow favourite outline. BOTH recipient surfaces draw it
-- -- the Send tab's contact picker and the recipient manager -- and each used to
-- carry the triple verbatim with a comment naming the other file, so changing it
-- in one place would have left the two windows drawing different stars. It is a
-- cool near-white rather than a grey: the outline is a thin shape at 14-17px and
-- anything darker sinks into the plate behind it, while staying plainly not the
-- gold of the filled star.
Theme.IconTints = {
  starEmpty = { 0.82, 0.84, 0.90 },
}

-- The dropdown's own list panel. Fully opaque: at high-but-not-full alpha the
-- borders of the widgets behind it show through as bright seams.
Theme.MenuColors = {
  fill = { 0.05, 0.05, 0.06, 1.00 },
  border = { 0.46, 0.36, 0.24, 0.55 },
  hover = { 0.90, 0.78, 0.30, 0.18 },
}

-- Blizzard's rock tile, DELIBERATELY, and a decision worth recording: UI
-- packs (AtrocityUI, NaowhUI, ...) ship loose files under Interface\ that
-- replace this art client-wide, which flattens these surfaces on such an
-- install. 1.18.1 shipped a Postbox-owned stone tile to be immune to that,
-- and it was reverted: a generated tile matched neither the real rock (so
-- pristine installs got a worse look) nor the pack (so pack installs got a
-- third look that matched nothing). A pack-textured install is pack-styled
-- in every Blizzard window already -- Postbox reading as "part of that UI"
-- is the correct outcome, and those players run a skin (EllesmereUI/ElvUI)
-- that replaces these surfaces anyway. Do not re-own this texture without
-- extracting the genuine art.
local SURFACE_TEXTURE = "Interface\\FrameGeneral\\UI-Background-Rock"
local SURFACE_TINT = { 0.40, 0.32, 0.24, 1.00 }

local WINDOW_STONE_TINT = { 0.78, 0.65, 0.50, 1.00 }
local WINDOW_WASH_TINT = { 0.42, 0.33, 0.22, 0.14 }
local WINDOW_BORDER_TINT = { 0.94, 0.82, 0.56, 1.00 }
-- Keeps the stone off the title-bar art. Functional for whatever title height
-- the frame template gives us.
local WINDOW_TITLE_INSET = 22
local WINDOW_EDGE_INSET = 2

-------------------------------------------------------------
-- Fonts
--
-- Sizes are applied through named font objects rather than a registry of
-- bound font strings. Core/CollectTab.lua builds a fresh row frame — with
-- several font strings — for every mail on every list refresh; a strong-keyed
-- registry grows for the whole session and leaks every one of them. Font
-- objects are per (source template, role) instead, which is a handful of
-- objects for the life of the addon no matter how many rows are built.
-------------------------------------------------------------

local ROLE_SCALE = {
  tiny = 0.90,
  small = 0.96,
  normal = 1.00,
  category = 1.02,
  medium = 1.08,
  large = 1.16,
  title = 1.24,
}

local MIN_FONT_SIZE = 8  -- below this the client renders text illegibly

local derivedFonts = {}   -- cache key -> font object
local derivedInfo = {}    -- font object -> the source it was derived from
local derivedCount = 0

local function ScaleFor(spec)
  if type(spec) == "string" then
    local scale = ROLE_SCALE[spec]
    if not scale and ns.PrintError then
      ns.PrintError(("unknown font role '%s'; using normal."):format(spec))
    end
    return scale or 1.0
  end

  if type(spec) == "table" then
    local explicit = tonumber(spec.scale)
    if explicit then return explicit end
    if type(spec.role) == "string" then return ROLE_SCALE[spec.role] or 1.0 end
  end

  return 1.0
end

local function DeriveFont(source, path, baseSize, baseFlags, size, flags)
  -- Back to the size and flags it started with: hand back the original object
  -- rather than minting a duplicate of it.
  if source and size == baseSize and flags == baseFlags then return source end

  local key
  if source and type(source.GetName) == "function" then key = source:GetName() end
  if not key then key = tostring(path) .. "@" .. tostring(baseSize) end
  key = key .. "/" .. tostring(size) .. "/" .. tostring(flags)

  local object = derivedFonts[key]
  if object then return object end

  derivedCount = derivedCount + 1
  object = CreateFont("PostboxFont" .. derivedCount)
  if not object then return nil end

  -- Copy first so colour, shadow and justification carry over from whatever
  -- template the font string came from, then override the size.
  if source and type(object.CopyFontObject) == "function" then
    pcall(object.CopyFontObject, object, source)
  end
  if not pcall(object.SetFont, object, path, size, flags) then return nil end

  derivedFonts[key] = object
  derivedInfo[object] = { source = source, path = path, size = baseSize, flags = baseFlags }
  return object
end

-- Applies a size role (or an explicit options table) to a font string.
--
-- `spec` may be a role name ("small", "title", …) or a table with any of
-- { role, scale, flags, color, minSize }. Accepting both is deliberate: the
-- dropdown used to pass a role name where an options table was expected, which
-- silently did nothing.
--
-- Re-binding the same font string always measures from the size it originally
-- had, never from the size a previous bind produced, so repeated binds cannot
-- compound.
function Theme.BindFont(fontString, spec)
  if not fontString or type(fontString.GetFont) ~= "function" then return end

  local options = type(spec) == "table" and spec or nil
  local scale = ScaleFor(spec)
  local minSize = max(MIN_FONT_SIZE, floor((options and tonumber(options.minSize) or MIN_FONT_SIZE) + 0.5))

  local current = type(fontString.GetFontObject) == "function" and fontString:GetFontObject() or nil
  local info = current and derivedInfo[current] or nil

  local source, path, baseSize, baseFlags
  if info then
    source, path, baseSize, baseFlags = info.source, info.path, info.size, info.flags
  else
    source = current
    path, baseSize, baseFlags = fontString:GetFont()
  end

  if type(path) ~= "string" or path == "" then path = STANDARD_TEXT_FONT end
  baseSize = tonumber(baseSize) or 12

  local flags = (options and options.flags) or baseFlags
  local size = max(minSize, floor((baseSize * scale) + 0.5))

  if size ~= baseSize or flags ~= baseFlags or info then
    local object = path and DeriveFont(source, path, baseSize, baseFlags, size, flags)
    if object and type(fontString.SetFontObject) == "function" then
      fontString:SetFontObject(object)
    elseif path then
      fontString:SetFont(path, size, flags)
    end
  end

  -- Colour is set on the font string, not the shared font object, so it can
  -- never bleed onto every other user of that object.
  local color = options and options.color
  if type(color) == "table" and type(fontString.SetTextColor) == "function" then
    fontString:SetTextColor(color[1] or 1, color[2] or 1, color[3] or 1)
  end
end

-------------------------------------------------------------
-- Surface painting
-------------------------------------------------------------

-- The tiled stone layer behind a themed container. Created once per frame and
-- never re-configured: these functions are re-invoked on every theme refresh
-- and by the skins' re-assert passes, and a skin that has hidden the texture
-- must stay hidden.
--
-- `pbSurfaceTexture` is read by both skin files: Core/Skin_ElvUI.lua uses it as
-- a detector ("this child has our surface texture, therefore it is one of our
-- themed panels"), so it must keep landing on exactly the frames that get the
-- list/card treatment.
function Theme.ApplySurfaceTexture(frame)
  if not frame then return nil end

  local texture = frame.pbSurfaceTexture
  if texture then return texture end
  if type(frame.CreateTexture) ~= "function" then return nil end

  texture = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
  texture:SetAllPoints()
  texture:SetTexture(SURFACE_TEXTURE)
  -- Required: the asset is a small tile, not a stretched image.
  texture:SetHorizTile(true)
  texture:SetVertTile(true)
  texture:SetVertexColor(SURFACE_TINT[1], SURFACE_TINT[2], SURFACE_TINT[3], SURFACE_TINT[4])

  frame.pbSurfaceTexture = texture
  return texture
end

-- Colours an existing backdrop from a named scheme. The caller is responsible
-- for having applied a backdrop template first; a frame without backdrop
-- support is a silent no-op.
function Theme.ApplyBackdropTheme(frame, variant)
  if not frame then return end
  if type(frame.SetBackdropColor) ~= "function" or type(frame.SetBackdropBorderColor) ~= "function" then
    return
  end

  local scheme = Theme.Palette[variant] or Theme.Palette.list
  local bg, border = scheme.bg, scheme.border

  frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
  frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4])

  if scheme.surface then Theme.ApplySurfaceTexture(frame) end
end

-- GetRegions() builds a fresh table on every call; the nine-slice's region list
-- never changes, so remember it per frame instead.
local nineSliceRegions = setmetatable({}, { __mode = "k" })

local function RegionsOf(nineSlice)
  local regions = nineSliceRegions[nineSlice]
  if not regions then
    regions = { nineSlice:GetRegions() }
    nineSliceRegions[nineSlice] = regions
  end
  return regions
end

-- Paints the main window: tiled stone inset from the edges and below the title
-- bar, a warm brown wash over it, the frame template's own background art
-- hidden, and the nine-slice border tinted pale gold.
function Theme.ApplyFrameTheme(frame)
  if not frame or type(frame.CreateTexture) ~= "function" then return end

  local stone = frame.pbWindowStone
  if not stone then
    stone = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    stone:SetPoint("TOPLEFT", frame, "TOPLEFT", WINDOW_EDGE_INSET, -WINDOW_TITLE_INSET)
    stone:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -WINDOW_EDGE_INSET, WINDOW_EDGE_INSET)
    stone:SetTexture(SURFACE_TEXTURE)
    stone:SetHorizTile(true)
    stone:SetVertTile(true)
    stone:SetVertexColor(WINDOW_STONE_TINT[1], WINDOW_STONE_TINT[2], WINDOW_STONE_TINT[3], WINDOW_STONE_TINT[4])
    frame.pbWindowStone = stone
  end

  local wash = frame.pbWindowTint
  if not wash then
    wash = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
    wash:SetPoint("TOPLEFT", frame, "TOPLEFT", WINDOW_EDGE_INSET, -WINDOW_TITLE_INSET)
    wash:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -WINDOW_EDGE_INSET, WINDOW_EDGE_INSET)
    wash:SetColorTexture(WINDOW_WASH_TINT[1], WINDOW_WASH_TINT[2], WINDOW_WASH_TINT[3], WINDOW_WASH_TINT[4])
    frame.pbWindowTint = wash
  end

  -- Hide the template's own art so only our stone shows.
  if frame.Bg then frame.Bg:SetVertexColor(1, 1, 1, 0) end

  if frame.Inset then
    if frame.Inset.Bg then frame.Inset.Bg:Hide() end
    if frame.Inset.NineSlice then frame.Inset.NineSlice:SetAlpha(0) end
  end

  local nineSlice = frame.NineSlice
  if nineSlice and type(nineSlice.SetAlpha) == "function" then
    nineSlice:SetAlpha(0.95)
    local regions = RegionsOf(nineSlice)
    for i = 1, #regions do
      local region = regions[i]
      if region and region.SetVertexColor then
        region:SetVertexColor(WINDOW_BORDER_TINT[1], WINDOW_BORDER_TINT[2],
                              WINDOW_BORDER_TINT[3], WINDOW_BORDER_TINT[4])
      end
    end
  end
end

-- Ensures the tab bar has a full-size background texture and sets its colour.
-- Core/MailboxUI.lua calls this with no colour, which yields fully transparent:
-- in the default theme the texture is invisible and exists only so the skins
-- have a handle to hide (Core/Skin_EllesmereUI.lua reads `pbTabBarBg`).
function Theme.ApplyTabBarBackground(tabBar, color)
  if not tabBar or type(tabBar.CreateTexture) ~= "function" then return end

  local texture = tabBar.pbTabBarBg
  if not texture then
    texture = tabBar:CreateTexture(nil, "BACKGROUND")
    texture:SetAllPoints()
    tabBar.pbTabBarBg = texture
  end

  local tint = type(color) == "table" and color or nil
  if tint then
    texture:SetColorTexture(tint[1] or 0, tint[2] or 0, tint[3] or 0, tint[4] or 0)
  else
    texture:SetColorTexture(0, 0, 0, 0)
  end
end

-------------------------------------------------------------
-- Buttons
-------------------------------------------------------------

-- ONE template, named outright, with no probe in front of it.
--
-- This used to prefer "WowStyle1ButtonTemplate" and fall back to
-- UIPanelButtonTemplate on a client that did not register it. The preference
-- never once took: WowStyle1ButtonTemplate does not exist in the live client's
-- template registry -- verified against a C_XMLUtil.GetTemplateInfo dump of
-- 12.0.7, which carries WowStyle1DropdownTemplate, WowStyle1FilterDropdown-
-- Template and the rest of that family but no plain button. So every call in
-- the addon paid a registry lookup to arrive at the fallback, and the code read
-- as though Postbox drew modern buttons somewhere. It never did.
--
-- If a modern template is adopted later it belongs here, named, and the
-- decision belongs in this comment -- not behind a probe that reports "not on
-- this client" forever and tells nobody.
local BUTTON_TEMPLATE = "UIPanelButtonTemplate"

-- Every push button in the addon is created here, so there is one answer to
-- "what does a Postbox button look like" and one place to change it.
function Theme.CreateButton(name, parent)
  return CreateFrame("Button", name, parent, BUTTON_TEMPLATE)
end

local function FontStringOf(widget)
  if not widget or type(widget.GetFontString) ~= "function" then return nil end
  return widget:GetFontString()
end

-- Rebinds the button's font string at the requested role, or at `normal`.
-- An icon-only button has no font string; that is not an error.
function Theme.StyleButton(button, options)
  if not button then return end

  local fontString = FontStringOf(button)
  if not fontString then return end

  local role = type(options) == "table" and options.fontRole or nil
  Theme.BindFont(fontString, (type(role) == "string" and role ~= "" and role) or "normal")
end

-------------------------------------------------------------
-- List row striping
-------------------------------------------------------------

-- Kept as fields so an existing consumer can still read them; they are the
-- same tables as Theme.RowColors, so overriding the palette overrides these.
RowStyling.ROW_COLOR_EVEN = Theme.RowColors.even
RowStyling.ROW_COLOR_ODD = Theme.RowColors.odd
RowStyling.ROW_HOVER_COLOR = Theme.RowColors.hover

-- Apply(row)                       — paints from state written onto the row
-- Apply(row, colors)               — same, with a table overriding any of the three colours
-- Apply(row, index, hovered)       — paints directly, no state written first
--
-- The third form exists for pooled rows: a recycled row should not have to
-- carry stripe state as frame fields just to be repainted.
function RowStyling.Apply(row, indexOrColors, hovered)
  if not row then return end

  local bg = row._bg or row.bg
  if not bg or type(bg.SetColorTexture) ~= "function" then return end

  local index, isHovered, overrides
  if type(indexOrColors) == "number" then
    index, isHovered = indexOrColors, hovered and true or false
  else
    overrides = type(indexOrColors) == "table" and indexOrColors or nil
    index = row._rowIndex or 0
    isHovered = row._hovered and true or false
  end

  local color
  if isHovered then
    color = (overrides and overrides.ROW_HOVER_COLOR) or Theme.RowColors.hover
  elseif index % 2 == 0 then
    color = (overrides and overrides.ROW_COLOR_EVEN) or Theme.RowColors.even
  else
    color = (overrides and overrides.ROW_COLOR_ODD) or Theme.RowColors.odd
  end

  bg:SetColorTexture(color[1], color[2], color[3], color[4])
end

-------------------------------------------------------------
-- Addon facade
-------------------------------------------------------------

-- Installs the theme entry points the addon actually calls onto its own theme
-- table (Core/Theme.lua's ns.Theme), adding the two behaviours that belong to
-- the addon rather than the shared theme.
function Theme.BindAddon(target)
  target = target or {}

  -- Core/Theme.lua reads this to reach the painting functions directly.
  target._sharedTheme = Theme

  -- Every push button the addon creates is tagged so the host-UI skins restyle
  -- exactly these and nothing else — not mail rows, not attachment slots, not
  -- icon-only buttons. Read by Core/Skin_ElvUI.lua and Core/Skin_EllesmereUI.lua.
  function target.CreateButton(name, parent)
    local button = Theme.CreateButton(name, parent)
    if button then button.__postboxButton = true end
    return button
  end

  -- Binding the window title's font is the one thing the addon wants on top of
  -- the shared frame painting.
  function target.ApplyFrameTheme(frame)
    Theme.ApplyFrameTheme(frame)
    if frame and frame.TitleText then Theme.BindFont(frame.TitleText, "title") end
  end

  target.StyleButton = Theme.StyleButton
  target.ApplyBackdropTheme = Theme.ApplyBackdropTheme

  return target
end
