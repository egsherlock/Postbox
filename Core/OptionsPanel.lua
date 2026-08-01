local _, ns = ...

-- =====================================================================
-- Postbox :: options panel
-- ---------------------------------------------------------------------
-- A Postbox-owned window rather than a MenuUtil context menu.
--
-- Why: Blizzard's menu frames are Compositor-guarded (CreateTexture and
-- friends hard-error on them), submenu panels are only reachable through
-- an API that taints Blizzard's menu pipeline, and their backdrop is the
-- host UI's to control -- which together meant nested option submenus
-- rendered with no background at all and could not be fixed from here.
-- Owning the frame means we own its opacity, and every control is visible
-- at once instead of hidden behind hover-out submenus.
-- =====================================================================

ns.OptionsPanel = ns.OptionsPanel or {}
local Panel = ns.OptionsPanel

local L = ns.L

local W, ROW_H, PAD = 340, 30, 14
local CHECK_H, BUTTON_H, DROPDOWN_H = 22, 24, 24

-- Rows are laid out downwards from a negative `y`, which is the TOP of the next
-- row -- a full row-pitch below the last control's own bottom. Sizing the frame
-- from that left a whole empty row under the last control (34px on a stock UI,
-- where the appearance section is hidden). Every builder records where its
-- control actually ends, and the frame is sized from that plus one pad.
local function MarkBottom(frame, y, height)
  frame.__pbContentBottom = y - height
end

local function GetSkin()
  local s = ns.Skin
  if s and s.GetBorderChoices then return s end
  return nil
end

-- A host skin's repaint of a tagged panel fades every texture region the
-- panel itself owns (that is how it substitutes its own art). Any art of
-- OURS that must survive on such a panel therefore lives on a small child
-- frame, whose regions the sweep never touches.
local function ArtHolder(parent)
  local holder = CreateFrame("Frame", nil, parent)
  holder:SetAllPoints(parent)
  holder:SetFrameLevel(parent:GetFrameLevel() + 1)
  return holder
end

-------------------------------------------------------------
-- Row builders
-------------------------------------------------------------

-- A titled section: a heading, then a quiet list-surface card the section's
-- rows sit inside -- the same surface the main window's panels use, so both
-- host-UI skins already know how to paint it. Rows are laid into the card
-- with their own inner cursor; EndSection sizes the card to its content and
-- returns the panel cursor moved past it. The two halves are separate
-- because the minimap section puts its master checkbox BETWEEN them.
local function AddSectionHeading(frame, y, title)
  local heading = ns.Theme.CreateText(frame, "heading")
  heading:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
  heading:SetWordWrap(false)
  heading:SetText(title)
  return y - 20
end

local function StartCard(frame, y)
  local card = CreateFrame("Frame", nil, frame)
  card:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, y)
  card:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
  ns.Theme.ApplyList(card)
  -- Shared by reference: rows built into the card register their refreshers
  -- on the panel, which is what replays them on open.
  card.__refreshers = frame.__refreshers
  return card
end

local function BeginSection(frame, y, title)
  y = AddSectionHeading(frame, y, title)
  return StartCard(frame, y), y
end

local function EndSection(frame, card, y)
  local height = math.abs(card.__pbContentBottom or -12) + 12
  card:SetHeight(height)
  MarkBottom(frame, y, height)
  return y - height - 16
end
local function AddCheckbox(frame, y, title, desc, get, set)
  local cb = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
  cb:SetSize(CHECK_H, CHECK_H)
  cb:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
  cb.__postboxCheck = true

  -- A control's caption is the design system's `label` role -- the same gold
  -- GameFontNormalSmall the rest of the addon labels its controls with. These
  -- were raw white GameFontHighlight, the one place in the addon where a
  -- caption did not follow the palette.
  --
  -- Word wrap off: the label carries both a LEFT and a RIGHT anchor, and rows
  -- are a fixed pitch apart, so a translated caption would otherwise wrap into
  -- the row below it.
  local label = ns.Theme.CreateText(frame, "label")
  label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
  label:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
  label:SetJustifyH("LEFT")
  label:SetWordWrap(false)
  label:SetText(title)
  cb.__label = label

  cb:SetChecked(get())
  cb:SetScript("OnClick", function(self)
    local on = self:GetChecked() and true or false
    set(on)
    if type(SOUNDKIT) == "table" then
      PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
                   or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
    end
  end)
  cb:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(title)
    if desc then GameTooltip:AddLine(desc, 1, 1, 1, true) end
    GameTooltip:Show()
  end)
  cb:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.__refreshers[#frame.__refreshers + 1] = function() cb:SetChecked(get()) end
  MarkBottom(frame, y, CHECK_H)
  return y - ROW_H
end

-- A full-width push-button row. `getText` is re-evaluated every time the panel
-- opens, so a button whose caption carries a live count (e.g. how many
-- recipients there are to manage) stays accurate without a refresh event.
local function AddButton(frame, y, getText, desc, onClick)
  local btn = ns.Theme.CreateButton(nil, frame)
  btn:SetHeight(BUTTON_H)
  btn:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
  btn:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
  btn:SetText(getText())
  btn:SetScript("OnClick", onClick)
  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(self:GetText())
    if desc then GameTooltip:AddLine(desc, 1, 1, 1, true) end
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.__refreshers[#frame.__refreshers + 1] = function() btn:SetText(getText()) end
  MarkBottom(frame, y, BUTTON_H)
  return y - (ROW_H + 4), btn
end

-- Uses Postbox's own dropdown element, not UIDropDownMenu / MenuUtil, so the
-- list panel is a frame we own and can keep fully opaque.
local function AddDropdown(frame, y, label, items, getValue, setValue)
  local dd = ns.Core.UI.Dropdown.Create(frame, {
    label       = label,
    items       = items,
    toggleWidth = 165,
    toggleHeight = 22,
    alignRight  = true,
    height      = DROPDOWN_H,
    defaultId   = getValue(),
  })
  dd:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
  dd:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
  dd:SetChangeCallback(function(id) setValue(id) end)

  -- Reflect the stored value in the toggle text on every open.
  frame.__refreshers[#frame.__refreshers + 1] = function()
    local current = getValue()
    for _, item in ipairs(items) do
      if item.id == current then
        dd._selectedId = current
        if dd.SetText then dd:SetText(item.name) end
        break
      end
    end
  end
  MarkBottom(frame, y, DROPDOWN_H)
  return y - (ROW_H + 4), dd
end

-------------------------------------------------------------
-- Build
-------------------------------------------------------------
local function Build()
  if Panel._frame then return Panel._frame end

  local frame = CreateFrame("Frame", "PostboxOptionsFrame", UIParent,
                            "BasicFrameTemplateWithInset")
  frame:SetFrameStrata("FULLSCREEN_DIALOG")
  frame:SetToplevel(true)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:Hide()
  frame.__refreshers = {}

  -- Never transparent: you need to read it while adjusting the transparency of
  -- the window behind it. Skin.ApplyBgOpacity honours this flag.
  frame.__pbEuiAlwaysOpaque = true

  -- TitleText is not guaranteed: Blizzard has been moving it behind
  -- TitleContainer, and the TOC declares two interface versions. The main
  -- window and the recipient manager already guard the identical access on the
  -- identical template; an unguarded index here would make the options panel
  -- permanently unreachable rather than merely untitled.
  if frame.SetTitle then
    frame:SetTitle(L["OPTIONS_TITLE"])
  elseif frame.TitleText then
    frame.TitleText:SetText(L["OPTIONS_TITLE"])
  end
  ns.Theme.ApplyFrameTheme(frame)
  ns.Core.UI.Helpers.RegisterEscClose(frame)

  local y = -34
  local card, cy

  card, y = BeginSection(frame, y, L["OPT_GENERAL_HEADING"])
  cy = -12

  cy = AddCheckbox(card, cy, L["GRID_TOGGLE_TITLE"], L["GRID_TOGGLE_DESC"],
        function() return ns.MailboxUI.GetOption("gridDock") end,
        function(on)
          ns.MailboxUI.SetOption("gridDock", on)
          if on and ns.MailboxUI._state then ns.MailboxUI._state.freeMoved = false end
          if ns.MailboxUI.ApplyWindowLayout then ns.MailboxUI.ApplyWindowLayout() end
        end)

  cy = AddCheckbox(card, cy, L["OPT_TAB_COUNTS_TITLE"], L["OPT_TAB_COUNTS_DESC"],
        function() return ns.MailboxUI.GetOption("showTabCounts") end,
        function(on)
          ns.MailboxUI.SetOption("showTabCounts", on)
          if ns.MailboxUI.RefreshCollectTabCounts then ns.MailboxUI.RefreshCollectTabCounts() end
        end)

  cy = AddCheckbox(card, cy, L["OPT_COMPACT_ROWS_TITLE"], L["OPT_COMPACT_ROWS_DESC"],
        function() return ns.MailboxUI.GetOption("compactRows") end,
        function(on)
          ns.MailboxUI.SetOption("compactRows", on)
          if ns.MailboxUI.RefreshCollectRowLayout then ns.MailboxUI.RefreshCollectRowLayout() end
        end)

  -- Nothing to refresh: the mapping is read at the moment a row is clicked, and
  -- the row tooltip's hint line is composed on hover from the same reading. A
  -- list rebuild would repaint rows that are already correct.
  cy = AddCheckbox(card, cy, L["OPT_PREVIEW_CLICK_TITLE"], L["OPT_PREVIEW_CLICK_DESC"],
        function() return ns.MailboxUI.GetOption("previewOnClick") end,
        function(on) ns.MailboxUI.SetOption("previewOnClick", on) end)

  -- Recipient manager: a portrait button filling the space to the right of
  -- the checkbox column, tall as all four rows. It makes the feature loud
  -- and shaves a whole row off the card. /postbox recipients is the other
  -- way in.
  local rmButton = ns.Theme.CreateButton(nil, card)
  rmButton:SetSize(108, (ROW_H * 4) - 8)
  rmButton:SetPoint("TOPRIGHT", card, "TOPRIGHT", -PAD, -12)

  -- Portrait composition: title up top, the letter-bundle icon full-strength
  -- in the middle -- the same glyph as the Send tab's doorway, carrying the
  -- "this is the address book" idea -- and the live count underneath. The
  -- icon sits in the button's own ARTWORK layer, above the plate fill and
  -- below the OVERLAY captions.
  local rmLabel = rmButton:GetFontString()
  if rmLabel then
    rmLabel:SetWordWrap(true)
    rmLabel:SetWidth(92)
    rmLabel:ClearAllPoints()
    rmLabel:SetPoint("TOP", rmButton, "TOP", 0, -12)
  end
  rmButton:SetText(L["RM_OPT_BUTTON"])
  -- On an art holder, not the button: a host skin's button repaint fades
  -- the tagged button's own texture regions, which kept this icon invisible.
  local rmMark = ArtHolder(rmButton):CreateTexture(nil, "ARTWORK")
  rmMark:SetSize(46, 46)
  rmMark:SetPoint("CENTER", rmButton, "CENTER", 0, -4)
  rmMark:SetTexture("Interface\\AddOns\\Postbox\\Media\\minimap-bundleclean.tga")
  local rmCount = ns.Theme.CreateText(rmButton, "bodySmall")
  rmCount:SetPoint("BOTTOM", rmButton, "BOTTOM", 0, 9)
  rmCount:SetAlpha(0.8)
  local function RefreshRmCount()
    local RM = ns.RecipientManager
    local count = (RM and type(RM.Count) == "function" and RM.Count()) or 0
    rmCount:SetText(string.format("(%d)", count))
  end
  RefreshRmCount()
  rmButton:SetScript("OnClick", function()
    local RM = ns.RecipientManager
    if RM and type(RM.Toggle) == "function" then
      RM.Toggle()
    else
      ns.Print(L["RM_NOT_AVAILABLE"])
    end
  end)
  rmButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["RM_OPT_BUTTON"])
    GameTooltip:AddLine(L["RM_OPT_BUTTON_DESC"], 1, 1, 1, true)
    GameTooltip:Show()
  end)
  rmButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
  frame.__refreshers[#frame.__refreshers + 1] = RefreshRmCount

  y = EndSection(frame, card, y)

  -- Minimap mail icon (Core/MinimapButton.lua). Resolved at click time like
  -- every other binding, so the section stays honest if the module is absent.
  --
  -- The master checkbox shares the heading line, right-aligned, and the card
  -- carries the feature's settings: unchecked, the card desaturates and
  -- stops taking clicks, which is what tells the user those rows belong to
  -- the checkbox.
  local mmHeadingY = y
  y = AddSectionHeading(frame, y, L["OPT_MINIMAP_HEADING"])
  y = y - 4 -- the checkbox is taller than the heading text

  local mmHostStyled = ns.MinimapButton and ns.MinimapButton.IsHostStyled
    and ns.MinimapButton.IsHostStyled()
  local mmDesc = mmHostStyled and L["OPT_MINIMAP_DESC_EUI"] or L["OPT_MINIMAP_DESC"]
  local UpdateMinimapCardState -- defined once the card exists below

  local mmToggle = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
  mmToggle:SetSize(CHECK_H, CHECK_H)
  mmToggle:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD + 4, mmHeadingY + 5)
  mmToggle.__postboxCheck = true
  local mmToggleLabel = ns.Theme.CreateText(frame, "label")
  mmToggleLabel:SetPoint("RIGHT", mmToggle, "LEFT", -4, 0)
  mmToggleLabel:SetWordWrap(false)
  mmToggleLabel:SetText(L["OPT_MINIMAP_TITLE"])
  mmToggle.__label = mmToggleLabel
  mmToggle:SetChecked(ns.MinimapButton and ns.MinimapButton.GetEnabled())
  mmToggle:SetScript("OnClick", function(self)
    local on = self:GetChecked() and true or false
    if ns.MinimapButton then ns.MinimapButton.SetEnabled(on) end
    if UpdateMinimapCardState then UpdateMinimapCardState() end
    if type(SOUNDKIT) == "table" then
      PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
                   or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
    end
  end)
  mmToggle:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["OPT_MINIMAP_TITLE"])
    GameTooltip:AddLine(mmDesc, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  mmToggle:SetScript("OnLeave", function() GameTooltip:Hide() end)
  frame.__refreshers[#frame.__refreshers + 1] = function()
    mmToggle:SetChecked(ns.MinimapButton and ns.MinimapButton.GetEnabled())
  end

  card = StartCard(frame, y)
  cy = -12

  -- Each "clean" restyle sits directly beneath its original, named as the
  -- original plus the localized clean suffix.
  local function CleanName(baseKey)
    return string.format(L["OPT_MINIMAP_ICON_CLEAN_SUFFIX"], L[baseKey])
  end
  local iconItems = {
    { id = "letter",       name = L["OPT_MINIMAP_ICON_LETTER"] },
    { id = "letterclean",  name = CleanName("OPT_MINIMAP_ICON_LETTER") },
    { id = "sealed",       name = L["OPT_MINIMAP_ICON_SEALED"] },
    { id = "stamped",      name = L["OPT_MINIMAP_ICON_STAMPED"] },
    { id = "stampedclean", name = CleanName("OPT_MINIMAP_ICON_STAMPED") },
    { id = "weathered",    name = L["OPT_MINIMAP_ICON_WEATHERED"] },
    { id = "open",         name = L["OPT_MINIMAP_ICON_OPEN"] },
    { id = "scroll",       name = L["OPT_MINIMAP_ICON_SCROLL"] },
    { id = "seal",         name = L["OPT_MINIMAP_ICON_SEAL"] },
    { id = "bundle",       name = L["OPT_MINIMAP_ICON_BUNDLE"] },
    { id = "bundleclean",  name = CleanName("OPT_MINIMAP_ICON_BUNDLE") },
    { id = "parcel",       name = L["OPT_MINIMAP_ICON_PARCEL"] },
    { id = "parcelclean",  name = CleanName("OPT_MINIMAP_ICON_PARCEL") },
    { id = "mailbag",      name = L["OPT_MINIMAP_ICON_MAILBAG"] },
    { id = "satchel",      name = L["OPT_MINIMAP_ICON_SATCHEL"] },
    { id = "quill",        name = L["OPT_MINIMAP_ICON_QUILL"] },
    { id = "pillar",       name = L["OPT_MINIMAP_ICON_PILLAR"] },
    { id = "pillarclean",  name = CleanName("OPT_MINIMAP_ICON_PILLAR") },
    { id = "stone",        name = L["OPT_MINIMAP_ICON_STONE"] },
    { id = "stoneclean",   name = CleanName("OPT_MINIMAP_ICON_STONE") },
    { id = "wood",         name = L["OPT_MINIMAP_ICON_WOOD"] },
    { id = "woodclean",    name = CleanName("OPT_MINIMAP_ICON_WOOD") },
    { id = "gold",         name = L["OPT_MINIMAP_ICON_GOLD"] },
    { id = "goldclean",    name = CleanName("OPT_MINIMAP_ICON_GOLD") },
    { id = "blizzard",     name = L["OPT_MINIMAP_ICON_BLIZZARD"] },
    { id = "postbox",      name = L["OPT_MINIMAP_ICON_POSTBOX"] },
    { id = "badge",        name = L["OPT_MINIMAP_ICON_BADGE"] },
  }
  -- This section exists to pick this icon, so the row IS the picker: a live
  -- swatch of the current choice beside a dropdown that fills the rest of
  -- the row -- not a small toggle stranded across the card from a label.
  -- Every item also carries its art, so the open list shows the icons
  -- themselves -- the only way to browse them without pending mail.
  if ns.MinimapButton and ns.MinimapButton.GetIconSpec then
    for _, item in ipairs(iconItems) do
      item.icon = ns.MinimapButton.GetIconSpec(item.id)
    end
  end
  -- The showcase stage: the current icon at a size you can actually judge,
  -- on a quiet dark plate, WEARING the live settings -- accent tint, glow
  -- (with its pulse) and shadow render here exactly as they will on the
  -- minimap, so the card previews the feature instead of naming it.
  local GLOW_TGA = "Interface\\AddOns\\Postbox\\Media\\minimap-glow.tga"
  local PREVIEW_ICON_SIZE = 38
  -- Sized and placed so its top edge lines up with the toggle grid's top and
  -- its bottom with the icon switcher's bottom: one rectangle, two columns.
  local stage = CreateFrame("Frame", nil, card)
  stage:SetSize(72, 72)
  stage:SetPoint("TOPLEFT", card, "TOPLEFT", PAD, cy - 4)
  stage:SetClipsChildren(true)
  local stageArt = ArtHolder(stage)
  -- A neutral mid-tone ground, not black: the shadow option is jet black
  -- and was invisible against a dark plate. This is roughly a minimap's
  -- average terrain value, so both glow and shadow read the way they will
  -- in the world.
  local stageBg = stageArt:CreateTexture(nil, "BACKGROUND", nil, -7)
  stageBg:SetAllPoints()
  stageBg:SetColorTexture(0.40, 0.41, 0.38, 1)
  local prevShadow = stageArt:CreateTexture(nil, "BACKGROUND", nil, -1)
  prevShadow:SetPoint("CENTER", stage, "CENTER", 0, -1)
  prevShadow:SetTexture(GLOW_TGA)
  prevShadow:SetVertexColor(0, 0, 0)
  prevShadow:SetAlpha(0.9)
  prevShadow:SetSize(PREVIEW_ICON_SIZE * 1.8, PREVIEW_ICON_SIZE * 1.8)
  local prevGlow = stageArt:CreateTexture(nil, "BACKGROUND", nil, 0)
  prevGlow:SetPoint("CENTER", stage, "CENTER", 0, 0)
  prevGlow:SetTexture(GLOW_TGA)
  prevGlow:SetBlendMode("ADD")
  prevGlow:SetSize(PREVIEW_ICON_SIZE * 2.2, PREVIEW_ICON_SIZE * 2.2)
  local prevPulse = prevGlow:CreateAnimationGroup()
  prevPulse:SetLooping("BOUNCE")
  local prevFade = prevPulse:CreateAnimation("Alpha")
  prevFade:SetFromAlpha(1)
  prevFade:SetToAlpha(0.55)
  prevFade:SetDuration(1.6)
  prevFade:SetSmoothing("IN_OUT")
  local iconPreview = stageArt:CreateTexture(nil, "ARTWORK")
  iconPreview:SetPoint("CENTER", stage, "CENTER", 0, 0)

  local function PaintIconPreview()
    local Icon = ns.MinimapButton
    local spec = Icon and Icon.GetIconSpec and Icon.GetIconSpec()
    if not spec then
      iconPreview:Hide()
      prevGlow:Hide()
      prevShadow:Hide()
      return
    end
    iconPreview:Show()
    if spec.atlas then
      iconPreview:SetAtlas(spec.atlas)
    else
      iconPreview:SetTexture(spec.texture)
    end
    iconPreview:SetSize(PREVIEW_ICON_SIZE, PREVIEW_ICON_SIZE * (spec.aspect or 1))

    local r, g, b = 1, 1, 1
    local accentOn = Icon.GetAccentTint and Icon.GetAccentTint()
    if accentOn then r, g, b = ns.Theme.GetAccent() end
    if spec.tintable and accentOn then
      iconPreview:SetVertexColor(r, g, b)
    else
      iconPreview:SetVertexColor(1, 1, 1)
    end

    prevGlow:SetVertexColor(r, g, b)
    if Icon.GetGlow and Icon.GetGlow() then
      prevGlow:Show()
      if not Icon.GetPulse or Icon.GetPulse() then
        if not prevPulse:IsPlaying() then prevPulse:Play() end
      else
        prevPulse:Stop()
      end
    else
      prevPulse:Stop()
      prevGlow:Hide()
    end
    prevShadow:SetShown(Icon.GetShadow and Icon.GetShadow() or false)
  end
  -- The chunk beside the stage: a 2x2 grid of compact toggles -- the two
  -- effects on top, their two modifiers beneath (Accent colours the glow,
  -- Pulse breathes it) -- with the icon switcher under the grid. One
  -- rectangle, clear reading order, no wasted rows.
  local function MiniCheck(gridX, gridY, labelKey, descKey, get, set)
    local cb = CreateFrame("CheckButton", nil, card, "UICheckButtonTemplate")
    cb:SetSize(20, 20)
    cb:SetPoint("TOPLEFT", card, "TOPLEFT", PAD + 80 + gridX * 106, cy - 4 - gridY * 24)
    cb.__postboxCheck = true
    local label = ns.Theme.CreateText(card, "label")
    label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    label:SetWordWrap(false)
    label:SetText(L[labelKey])
    cb.__label = label
    cb:SetChecked(get())
    cb:SetScript("OnClick", function(self)
      local on = self:GetChecked() and true or false
      set(on)
      PaintIconPreview()
      if type(SOUNDKIT) == "table" then
        PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
                     or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
      end
    end)
    cb:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(L[labelKey])
      GameTooltip:AddLine(L[descKey], 1, 1, 1, true)
      GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame.__refreshers[#frame.__refreshers + 1] = function() cb:SetChecked(get()) end
  end

  MiniCheck(0, 0, "OPT_MINIMAP_GLOW_TITLE", "OPT_MINIMAP_GLOW_DESC",
        function() return ns.MinimapButton and ns.MinimapButton.GetGlow() end,
        function(on) if ns.MinimapButton then ns.MinimapButton.SetGlow(on) end end)
  MiniCheck(1, 0, "OPT_MINIMAP_SHADOW_TITLE", "OPT_MINIMAP_SHADOW_DESC",
        function() return ns.MinimapButton and ns.MinimapButton.GetShadow() end,
        function(on) if ns.MinimapButton then ns.MinimapButton.SetShadow(on) end end)
  MiniCheck(0, 1, "OPT_MINIMAP_ACCENT_TITLE", "OPT_MINIMAP_ACCENT_DESC",
        function() return ns.MinimapButton and ns.MinimapButton.GetAccentTint() end,
        function(on) if ns.MinimapButton then ns.MinimapButton.SetAccentTint(on) end end)
  MiniCheck(1, 1, "OPT_MINIMAP_PULSE_TITLE", "OPT_MINIMAP_PULSE_DESC",
        function() return ns.MinimapButton and ns.MinimapButton.GetPulse() end,
        function(on) if ns.MinimapButton then ns.MinimapButton.SetPulse(on) end end)

  local iconDD = ns.Core.UI.Dropdown.Create(card, {
    items        = iconItems,
    toggleWidth  = 212,
    toggleHeight = 22,
    alignRight   = true,
    height       = DROPDOWN_H,
    defaultId    = ns.MinimapButton and ns.MinimapButton.GetIcon(),
  })
  iconDD:SetPoint("TOPLEFT", card, "TOPLEFT", PAD + 80, cy - 54)
  iconDD:SetPoint("RIGHT", card, "RIGHT", -PAD, 0)
  iconDD:SetChangeCallback(function(id)
    if ns.MinimapButton then ns.MinimapButton.SetIcon(id) end
    PaintIconPreview()
  end)
  frame.__refreshers[#frame.__refreshers + 1] = function()
    local current = ns.MinimapButton and ns.MinimapButton.GetIcon()
    for _, item in ipairs(iconItems) do
      if item.id == current then
        iconDD._selectedId = current
        iconDD:SetText(item.name)
        break
      end
    end
    PaintIconPreview()
  end
  PaintIconPreview()
  MarkBottom(card, cy, 80)
  cy = cy - 88

  -- With EllesmereUI's minimap module running, Postbox restyles EllesmereUI's
  -- own mail icon in place rather than drawing a second one; position and
  -- size are then EllesmereUI's to control, so those rows would be dead
  -- weight and are left out (see Core/MinimapButton.lua section 3).
  if not mmHostStyled then
    local mmSizeItems = {}
    for _, px in ipairs({ 16, 20, 24, 28 }) do
      mmSizeItems[#mmSizeItems + 1] = {
        id = px, name = string.format(L["OPT_MINIMAP_SIZE_STEP"], px),
      }
    end
    cy = AddDropdown(card, cy, L["OPT_MINIMAP_SIZE_TITLE"], mmSizeItems,
          function() return ns.MinimapButton and ns.MinimapButton.GetIconSize() end,
          function(id) if ns.MinimapButton then ns.MinimapButton.SetIconSize(id) end end)

    local mmPositionItems = {
      { id = "TOPRIGHT",    name = L["OPT_MINIMAP_POS_TR"] },
      { id = "TOPLEFT",     name = L["OPT_MINIMAP_POS_TL"] },
      { id = "BOTTOMRIGHT", name = L["OPT_MINIMAP_POS_BR"] },
      { id = "BOTTOMLEFT",  name = L["OPT_MINIMAP_POS_BL"] },
      { id = "CUSTOM",      name = L["OPT_MINIMAP_POS_CUSTOM"] },
    }
    cy = AddDropdown(card, cy, L["OPT_MINIMAP_POS_TITLE"], mmPositionItems,
          function() return ns.MinimapButton and ns.MinimapButton.GetPosition() end,
          function(id) if ns.MinimapButton then ns.MinimapButton.SetPosition(id) end end)
  end

  if not mmHostStyled then
    cy = cy - 4
    cy = AddButton(card, cy,
          function() return L["OPT_MINIMAP_RESET_POS"] end,
          L["OPT_MINIMAP_RESET_POS_DESC"],
          function() if ns.MinimapButton then ns.MinimapButton.ResetPosition() end end)
  else
    -- One quiet line, not a paragraph: the full explanation lives in its
    -- hover tooltip.
    local hint = CreateFrame("Frame", nil, card)
    hint:SetHeight(14)
    hint:SetPoint("TOPLEFT", card, "TOPLEFT", PAD, cy)
    hint:SetPoint("RIGHT", card, "RIGHT", -PAD, 0)
    hint:EnableMouse(true)
    local hintText = ns.Theme.CreateText(hint, "bodySmall")
    hintText:SetPoint("CENTER", hint, "CENTER", 0, 0)
    hintText:SetJustifyH("CENTER")
    hintText:SetWordWrap(false)
    hintText:SetText(L["OPT_MINIMAP_EUI_SHORT"])
    hintText:SetAlpha(0.7)
    hint:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(L["OPT_MINIMAP_EUI_SHORT"])
      GameTooltip:AddLine(L["OPT_MINIMAP_EUI_STYLED"], 1, 1, 1, true)
      GameTooltip:Show()
    end)
    hint:SetScript("OnLeave", function() GameTooltip:Hide() end)
    MarkBottom(card, cy, 14)
    cy = cy - 20
  end

  y = EndSection(frame, card, y)

  -- The desaturate-and-lock for the card above. Alpha carries the look; the
  -- overlay eats the mouse so nothing inside can be clicked or hovered while
  -- the feature is off. Level +40 clears every row control in the card.
  do
    local mmCard = card
    local blocker = CreateFrame("Frame", nil, mmCard)
    blocker:SetAllPoints(mmCard)
    blocker:SetFrameLevel(mmCard:GetFrameLevel() + 40)
    blocker:EnableMouse(true)
    blocker:Hide()
    UpdateMinimapCardState = function()
      local on = ns.MinimapButton and ns.MinimapButton.GetEnabled
        and ns.MinimapButton.GetEnabled()
      mmCard:SetAlpha(on and 1 or 0.4)
      blocker:SetShown(not on)
      -- A disabled card must not keep moving: the preview's pulse animation
      -- plays on regardless of frame alpha, so it is stopped here and
      -- re-derived from the settings when the feature comes back on.
      if on then
        PaintIconPreview()
      else
        prevPulse:Stop()
      end
    end
    UpdateMinimapCardState()
    frame.__refreshers[#frame.__refreshers + 1] = UpdateMinimapCardState
  end

  -- Host-UI appearance section (only when a skin exposes these controls).
  local Skin = GetSkin()
  if Skin then
    card, y = BeginSection(frame, y, L["OPT_APPEARANCE_HEADING"])
    cy = -12

    -- Border style and size both default to whatever EllesmereUI itself is
    -- configured for, so a shadow (or none) on the rest of the UI carries here.
    local borderItems = { { id = "auto", name = L["OPT_BG_OPACITY_AUTO"] } }
    for _, choice in ipairs(Skin.GetBorderChoices()) do
      borderItems[#borderItems + 1] = { id = choice.key, name = choice.name }
    end
    cy = AddDropdown(card, cy, L["OPT_BORDER_TITLE"], borderItems,
          function()
            if Skin.IsBorderDefault and Skin.IsBorderDefault() then return "auto" end
            return Skin.GetBorderStyle()
          end,
          function(id)
            if id == "auto" then Skin.ResetBorder() else Skin.SetBorderStyle(id) end
          end)

    local sizeItems = { { id = "auto", name = L["OPT_BG_OPACITY_AUTO"] } }
    for step = 1, 4 do
      sizeItems[#sizeItems + 1] = { id = step, name = string.format(L["OPT_BORDER_SIZE_STEP"], step) }
    end
    cy = AddDropdown(card, cy, L["OPT_BORDER_SIZE_TITLE"], sizeItems,
          function()
            if Skin.IsBorderSizeDefault and Skin.IsBorderSizeDefault() then return "auto" end
            return Skin.GetBorderSize()
          end,
          function(id)
            if id == "auto" then Skin.ResetBorderSize() else Skin.SetBorderSize(id) end
          end)

    local opacityItems = { { id = "auto", name = L["OPT_BG_OPACITY_AUTO"] } }
    for _, pct in ipairs({ 100, 95, 90, 85, 80, 75, 70, 60, 50, 40, 25, 0 }) do
      opacityItems[#opacityItems + 1] = {
        id = pct, name = string.format(L["OPT_BG_OPACITY_STEP"], pct),
      }
    end
    cy = AddDropdown(card, cy, L["OPT_BG_OPACITY_TITLE"], opacityItems,
          function()
            if Skin.IsBgOpacityDefault and Skin.IsBgOpacityDefault() then return "auto" end
            return math.floor(Skin.GetBgOpacity() * 100 + 0.5)
          end,
          function(id)
            if id == "auto" then Skin.ResetBgOpacity()
            else Skin.SetBgOpacity((tonumber(id) or 100) / 100) end
          end)

    y = EndSection(frame, card, y)
  end

  -- Which look is painting the addon right now: a quiet band phrased as
  -- reassurance -- "options synced with EllesmereUI" -- with a green status
  -- light and wash for "successfully wired in", the addon version tucked in
  -- the corner, and one more job: clicking it opens the bug-report popup
  -- (the least intrusive home for that). Refreshed on every open rather
  -- than baked in: skins claim ns.Skin at PLAYER_LOGIN and the EllesmereUI
  -- handshake can resolve seconds later, after this panel was first built.
  y = y - 2
  local GREEN = { 0.38, 0.80, 0.44 }
  local statusBand = CreateFrame("Button", nil, frame)
  statusBand:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, y)
  statusBand:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
  statusBand:SetHeight(24)
  ns.Theme.ApplyBand(statusBand)

  -- Wash and dot live on an art holder: the band is a tagged panel, and a
  -- host skin's repaint fades the band's own texture regions (which is why
  -- both were invisible under EllesmereUI at first).
  local bandArt = ArtHolder(statusBand)
  local wash = bandArt:CreateTexture(nil, "ARTWORK")
  wash:SetPoint("TOPLEFT", statusBand, "TOPLEFT", 1, -1)
  wash:SetPoint("BOTTOMRIGHT", statusBand, "BOTTOMRIGHT", -1, 1)
  wash:SetColorTexture(GREEN[1], GREEN[2], GREEN[3], 0.07)

  local statusText = ns.Theme.CreateText(statusBand, "bodySmall")
  statusText:SetPoint("CENTER", statusBand, "CENTER", 0, 0)
  statusText:SetJustifyH("CENTER")
  statusText:SetWordWrap(false)
  local statusDot = bandArt:CreateTexture(nil, "OVERLAY")
  statusDot:SetSize(7, 7)
  statusDot:SetPoint("RIGHT", statusText, "LEFT", -7, 0)
  statusDot:SetColorTexture(GREEN[1], GREEN[2], GREEN[3], 1)

  -- The packager stamps the release TAG into the TOC, which already carries
  -- its own "v" -- do not add another.
  local versionText = ns.Theme.CreateText(statusBand, "bodySmall")
  versionText:SetPoint("RIGHT", statusBand, "RIGHT", -8, 0)
  versionText:SetJustifyH("RIGHT")
  versionText:SetText(tostring(ns.VERSION or ""))
  versionText:SetAlpha(0.55)

  local function StyleName()
    local by = ns.SkinAppliedBy
    return (by == "ellesmereui" and "EllesmereUI")
      or (by == "elvui" and "ElvUI")
      or nil
  end
  local function RefreshStyleStatus()
    local name = StyleName()
    statusText:SetText(name and L("OPT_STYLE_SYNCED", name) or L["OPT_STYLE_OWN"])
  end
  RefreshStyleStatus()
  frame.__refreshers[#frame.__refreshers + 1] = RefreshStyleStatus

  -- The bug-report popup: the report address and a one-line setup summary,
  -- each in a copyable box. No browser can be opened from in-game, so
  -- copyable is the whole feature.
  local BUG_URL = "https://github.com/egsherlock/Postbox/issues"
  local bugPopup
  local function AddCopyRow(pop, rowY, labelKey, boxHeight)
    local caption = ns.Theme.CreateText(pop, "label")
    caption:SetPoint("TOPLEFT", pop, "TOPLEFT", 10, rowY)
    caption:SetText(L[labelKey])
    local box = CreateFrame("EditBox", nil, pop)
    box:SetSize(304, boxHeight or 14)
    box:SetPoint("TOPLEFT", pop, "TOPLEFT", 10, rowY - 14)
    box:SetAutoFocus(false)
    if boxHeight then
      box:SetMultiLine(true)
    end
    box:SetFontObject(ns.Theme.FontObject("bodySmall") or GameFontHighlightSmall)
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- Read-only in effect: typing snaps the text back and re-selects, so
    -- ctrl-C always copies the intact value.
    box:SetScript("OnChar", function(self)
      self:SetText(self._value or "")
      self:HighlightText()
    end)
    function box:SetValue(value)
      self._value = value or ""
      self:SetText(self._value)
    end
    return box
  end
  local function ToggleBugReport()
    if not bugPopup then
      -- Its own little window, not a child of the panel: parented into the
      -- panel at the same strata it interleaved with the panel's controls
      -- and could be neither raised nor moved. UIParent + TOOLTIP strata
      -- puts it above everything, and the opaque flag keeps it readable at
      -- any host opacity.
      bugPopup = CreateFrame("Frame", nil, UIParent)
      bugPopup:SetSize(324, 196)
      bugPopup:SetFrameStrata("TOOLTIP")
      bugPopup:SetToplevel(true)
      bugPopup:SetClampedToScreen(true)
      bugPopup:EnableMouse(true)
      bugPopup:SetMovable(true)
      bugPopup:RegisterForDrag("LeftButton")
      bugPopup:SetScript("OnDragStart", bugPopup.StartMoving)
      bugPopup:SetScript("OnDragStop", bugPopup.StopMovingOrSizing)
      bugPopup.__pbEuiAlwaysOpaque = true
      ns.Theme.ApplyCard(bugPopup)

      -- A guaranteed-opaque ground. This window exists to read exact text
      -- out of, so it opts out of every transparency system: the popup
      -- floor stops at 95%, and a host skin paints its card art at the
      -- user's opacity above that. The ground sits on a holder one frame
      -- level BELOW the popup -- the same trick the floor itself uses --
      -- so everything the popup and the skin draw composites over solid.
      local groundHolder = CreateFrame("Frame", nil, bugPopup)
      groundHolder:SetAllPoints(bugPopup)
      groundHolder:SetFrameLevel(math.max(0, bugPopup:GetFrameLevel() - 1))
      local groundEdge = groundHolder:CreateTexture(nil, "BACKGROUND", nil, -8)
      groundEdge:SetPoint("TOPLEFT", groundHolder, "TOPLEFT", -1, 1)
      groundEdge:SetPoint("BOTTOMRIGHT", groundHolder, "BOTTOMRIGHT", 1, -1)
      groundEdge:SetColorTexture(1, 1, 1, 0.15)
      local ground = groundHolder:CreateTexture(nil, "BACKGROUND", nil, -7)
      ground:SetAllPoints(groundHolder)
      ground:SetColorTexture(0.05, 0.05, 0.06, 1)

      local title = ns.Theme.CreateText(bugPopup, "heading")
      title:SetPoint("TOPLEFT", bugPopup, "TOPLEFT", 10, -8)
      title:SetText(L["OPT_BUG_TIP_TITLE"])

      -- The standard close button, same species as the options panel's own,
      -- so both host skins restyle it the way they restyle every close box.
      local close = CreateFrame("Button", nil, bugPopup, "UIPanelCloseButton")
      close:SetSize(24, 24)
      close:SetPoint("TOPRIGHT", bugPopup, "TOPRIGHT", -2, -2)
      close:SetScript("OnClick", function() bugPopup:Hide() end)

      bugPopup._url = AddCopyRow(bugPopup, -24, "OPT_BUG_URL_LABEL")
      bugPopup._diag = AddCopyRow(bugPopup, -60, "OPT_BUG_DIAG_LABEL", 100)

      local hint = ns.Theme.CreateText(bugPopup, "bodySmall")
      hint:SetPoint("BOTTOMLEFT", bugPopup, "BOTTOMLEFT", 10, 7)
      hint:SetText(L["OPT_BUG_HINT"])
      hint:SetAlpha(0.6)

      ns.Core.UI.Helpers.RegisterEscClose(bugPopup)
      -- Not a child of the panel any more, so closing the panel must take
      -- the popup with it explicitly.
      frame:HookScript("OnHide", function() bugPopup:Hide() end)
      bugPopup:Hide()
      if ns.Skin and ns.Skin.Refresh then pcall(ns.Skin.Refresh, bugPopup) end
    end
    if bugPopup:IsShown() then
      bugPopup:Hide()
      return
    end
    bugPopup._url:SetValue(BUG_URL)
    bugPopup._diag:SetValue(
      (type(ns.BuildDiagnosticReport) == "function" and ns.BuildDiagnosticReport())
      or "")
    bugPopup:ClearAllPoints()
    bugPopup:SetPoint("BOTTOM", statusBand, "TOP", 0, 8)
    bugPopup:Show()
    -- Effortless copying: the address arrives focused and selected, so
    -- Ctrl+C is the only keystroke needed.
    bugPopup._url:SetFocus()
  end
  -- /postbox debug reaches this without the panel being open.
  Panel._toggleBugReport = ToggleBugReport

  statusBand:SetScript("OnClick", ToggleBugReport)
  statusBand:SetScript("OnEnter", function(self)
    wash:SetColorTexture(GREEN[1], GREEN[2], GREEN[3], 0.13)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["OPT_BUG_TIP_TITLE"])
    GameTooltip:AddLine(L["OPT_BUG_TIP_DESC"], 1, 1, 1, true)
    GameTooltip:Show()
  end)
  statusBand:SetScript("OnLeave", function()
    wash:SetColorTexture(GREEN[1], GREEN[2], GREEN[3], 0.07)
    GameTooltip:Hide()
  end)
  MarkBottom(frame, y, 24)

  -- Sized to the last control's own bottom edge plus one pad, so hiding the
  -- appearance section (no host-UI skin) shortens the window rather than
  -- leaving an empty row under the last button.
  frame:SetSize(W, math.abs(frame.__pbContentBottom or y) + PAD)

  -- Let an active host-UI skin restyle the panel like the main window. ElvUI's
  -- skin has no ApplyWindow, so testing only for that left the options panel
  -- wearing Postbox's gold chrome while Skin.Refresh below ElvUI-skinned every
  -- control inside it. Same expression as Core/RecipientManager.lua.
  local applyWindow = ns.Skin and (ns.Skin.ApplyWindow or ns.Skin.Apply)
  if applyWindow then applyWindow(frame) end

  Panel._frame = frame
  return frame
end

-------------------------------------------------------------
-- Public API
-------------------------------------------------------------

-- /postbox debug lands here: builds the panel if this is the first touch,
-- then opens the same bug-report window the status band does.
function Panel.ToggleBugReport()
  Build()
  if Panel._toggleBugReport then Panel._toggleBugReport() end
end

function Panel.Toggle(anchor)
  local frame = Build()
  if frame:IsShown() then
    frame:Hide()
    return
  end
  for _, fn in ipairs(frame.__refreshers) do pcall(fn) end
  frame:ClearAllPoints()
  if anchor then
    frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
  else
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
  frame:Show()
  frame:Raise()
  if ns.Skin and ns.Skin.Refresh then ns.Skin.Refresh(frame) end
end
