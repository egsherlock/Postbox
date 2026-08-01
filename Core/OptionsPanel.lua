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

  -- Recipient manager. Opens a standalone window, so it works away from a
  -- mailbox as well; /postbox recipients is the other way in.
  cy = cy - 4
  cy = AddButton(card, cy,
        function()
          local RM = ns.RecipientManager
          local count = (RM and type(RM.Count) == "function" and RM.Count()) or 0
          return string.format(L["RM_OPT_BUTTON"], count)
        end,
        L["RM_OPT_BUTTON_DESC"],
        function()
          local RM = ns.RecipientManager
          if RM and type(RM.Toggle) == "function" then
            RM.Toggle()
          else
            ns.Print(L["RM_NOT_AVAILABLE"])
          end
        end)

  y = EndSection(frame, card, y)

  -- Minimap mail icon (Core/MinimapButton.lua). Resolved at click time like
  -- every other binding, so the section stays honest if the module is absent.
  --
  -- The master checkbox sits ABOVE the card, and the card carries the
  -- feature's settings: unchecked, the card desaturates and stops taking
  -- clicks, which is what tells the user those rows belong to the checkbox.
  y = AddSectionHeading(frame, y, L["OPT_MINIMAP_HEADING"])

  local mmHostStyled = ns.MinimapButton and ns.MinimapButton.IsHostStyled
    and ns.MinimapButton.IsHostStyled()
  local UpdateMinimapCardState -- defined once the card exists below

  y = AddCheckbox(frame, y, L["OPT_MINIMAP_TITLE"],
        mmHostStyled and L["OPT_MINIMAP_DESC_EUI"] or L["OPT_MINIMAP_DESC"],
        function() return ns.MinimapButton and ns.MinimapButton.GetEnabled() end,
        function(on)
          if ns.MinimapButton then ns.MinimapButton.SetEnabled(on) end
          if UpdateMinimapCardState then UpdateMinimapCardState() end
        end)

  card = StartCard(frame, y)
  cy = -12

  local iconItems = {
    { id = "letter",   name = L["OPT_MINIMAP_ICON_LETTER"] },
    { id = "sealed",   name = L["OPT_MINIMAP_ICON_SEALED"] },
    { id = "parcel",   name = L["OPT_MINIMAP_ICON_PARCEL"] },
    { id = "seal",     name = L["OPT_MINIMAP_ICON_SEAL"] },
    { id = "blizzard", name = L["OPT_MINIMAP_ICON_BLIZZARD"] },
    { id = "postbox",  name = L["OPT_MINIMAP_ICON_POSTBOX"] },
    { id = "badge",    name = L["OPT_MINIMAP_ICON_BADGE"] },
  }
  cy = AddDropdown(card, cy, L["OPT_MINIMAP_ICON_TITLE"], iconItems,
        function() return ns.MinimapButton and ns.MinimapButton.GetIcon() end,
        function(id) if ns.MinimapButton then ns.MinimapButton.SetIcon(id) end end)

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

  cy = AddCheckbox(card, cy, L["OPT_MINIMAP_ACCENT_TITLE"], L["OPT_MINIMAP_ACCENT_DESC"],
        function() return ns.MinimapButton and ns.MinimapButton.GetAccentTint() end,
        function(on) if ns.MinimapButton then ns.MinimapButton.SetAccentTint(on) end end)

  cy = AddCheckbox(card, cy, L["OPT_MINIMAP_GLOW_TITLE"], L["OPT_MINIMAP_GLOW_DESC"],
        function() return ns.MinimapButton and ns.MinimapButton.GetGlow() end,
        function(on) if ns.MinimapButton then ns.MinimapButton.SetGlow(on) end end)

  if not mmHostStyled then
    cy = cy - 4
    cy = AddButton(card, cy,
          function() return L["OPT_MINIMAP_RESET_POS"] end,
          L["OPT_MINIMAP_RESET_POS_DESC"],
          function() if ns.MinimapButton then ns.MinimapButton.ResetPosition() end end)
  else
    local note = ns.Theme.CreateText(card, "bodySmall")
    note:SetPoint("TOPLEFT", card, "TOPLEFT", PAD, cy)
    note:SetPoint("RIGHT", card, "RIGHT", -PAD, 0)
    note:SetJustifyH("LEFT")
    note:SetWordWrap(true)
    note:SetText(L["OPT_MINIMAP_EUI_STYLED"])
    MarkBottom(card, cy, 30)
    cy = cy - 36
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

  -- Which look is painting the addon right now: the host-UI skin's name, or
  -- Postbox's own theme. Refreshed on every open rather than baked in --
  -- skins claim ns.Skin at PLAYER_LOGIN and the EllesmereUI handshake can
  -- resolve seconds later, after this panel was first built.
  y = y - 6
  local statusDot = frame:CreateTexture(nil, "ARTWORK")
  statusDot:SetSize(6, 6)
  statusDot:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 1, y - 5)
  local statusText = ns.Theme.CreateText(frame, "bodySmall")
  statusText:SetPoint("LEFT", statusDot, "RIGHT", 6, 0)
  statusText:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
  statusText:SetJustifyH("LEFT")
  statusText:SetWordWrap(false)
  local function RefreshStyleStatus()
    local by = ns.SkinAppliedBy
    local name = (by == "ellesmereui" and "EllesmereUI")
      or (by == "elvui" and "ElvUI")
      or "Postbox"
    statusText:SetText(L("OPT_STYLE_STATUS", name))
    ns.Theme.FillColor(statusDot, "accent")
  end
  RefreshStyleStatus()
  frame.__refreshers[#frame.__refreshers + 1] = RefreshStyleStatus
  MarkBottom(frame, y, 16)

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
