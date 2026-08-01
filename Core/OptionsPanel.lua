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

  y = AddCheckbox(frame, y, L["GRID_TOGGLE_TITLE"], L["GRID_TOGGLE_DESC"],
        function() return ns.MailboxUI.GetOption("gridDock") end,
        function(on)
          ns.MailboxUI.SetOption("gridDock", on)
          if on and ns.MailboxUI._state then ns.MailboxUI._state.freeMoved = false end
          if ns.MailboxUI.ApplyWindowLayout then ns.MailboxUI.ApplyWindowLayout() end
        end)

  y = AddCheckbox(frame, y, L["OPT_TAB_COUNTS_TITLE"], L["OPT_TAB_COUNTS_DESC"],
        function() return ns.MailboxUI.GetOption("showTabCounts") end,
        function(on)
          ns.MailboxUI.SetOption("showTabCounts", on)
          if ns.MailboxUI.RefreshCollectTabCounts then ns.MailboxUI.RefreshCollectTabCounts() end
        end)

  y = AddCheckbox(frame, y, L["OPT_COMPACT_ROWS_TITLE"], L["OPT_COMPACT_ROWS_DESC"],
        function() return ns.MailboxUI.GetOption("compactRows") end,
        function(on)
          ns.MailboxUI.SetOption("compactRows", on)
          if ns.MailboxUI.RefreshCollectRowLayout then ns.MailboxUI.RefreshCollectRowLayout() end
        end)

  -- Nothing to refresh: the mapping is read at the moment a row is clicked, and
  -- the row tooltip's hint line is composed on hover from the same reading. A
  -- list rebuild would repaint rows that are already correct.
  y = AddCheckbox(frame, y, L["OPT_PREVIEW_CLICK_TITLE"], L["OPT_PREVIEW_CLICK_DESC"],
        function() return ns.MailboxUI.GetOption("previewOnClick") end,
        function(on) ns.MailboxUI.SetOption("previewOnClick", on) end)

  -- Recipient manager. Opens a standalone window, so it works away from a
  -- mailbox as well; /postbox recipients is the other way in.
  y = y - 4
  y = AddButton(frame, y,
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

  -- Minimap mail icon (Core/MinimapButton.lua). Resolved at click time like
  -- every other binding, so the section stays honest if the module is absent.
  y = y - 6
  local mmHeading = ns.Theme.CreateText(frame, "heading")
  mmHeading:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
  mmHeading:SetWordWrap(false)
  mmHeading:SetText(L["OPT_MINIMAP_HEADING"])
  y = y - 22

  y = AddCheckbox(frame, y, L["OPT_MINIMAP_TITLE"], L["OPT_MINIMAP_DESC"],
        function() return ns.MinimapButton and ns.MinimapButton.GetEnabled() end,
        function(on) if ns.MinimapButton then ns.MinimapButton.SetEnabled(on) end end)

  local iconItems = {
    { id = "postbox",  name = L["OPT_MINIMAP_ICON_POSTBOX"] },
    { id = "blizzard", name = L["OPT_MINIMAP_ICON_BLIZZARD"] },
    { id = "clean",    name = L["OPT_MINIMAP_ICON_CLEAN"] },
    { id = "mailbox",  name = L["OPT_MINIMAP_ICON_MAILBOX"] },
  }
  y = AddDropdown(frame, y, L["OPT_MINIMAP_ICON_TITLE"], iconItems,
        function() return ns.MinimapButton and ns.MinimapButton.GetIcon() end,
        function(id) if ns.MinimapButton then ns.MinimapButton.SetIcon(id) end end)

  local mmSizeItems = {}
  for _, px in ipairs({ 16, 20, 24, 28 }) do
    mmSizeItems[#mmSizeItems + 1] = {
      id = px, name = string.format(L["OPT_MINIMAP_SIZE_STEP"], px),
    }
  end
  y = AddDropdown(frame, y, L["OPT_MINIMAP_SIZE_TITLE"], mmSizeItems,
        function() return ns.MinimapButton and ns.MinimapButton.GetIconSize() end,
        function(id) if ns.MinimapButton then ns.MinimapButton.SetIconSize(id) end end)

  y = AddCheckbox(frame, y, L["OPT_MINIMAP_ACCENT_TITLE"], L["OPT_MINIMAP_ACCENT_DESC"],
        function() return ns.MinimapButton and ns.MinimapButton.GetAccentTint() end,
        function(on) if ns.MinimapButton then ns.MinimapButton.SetAccentTint(on) end end)

  y = AddCheckbox(frame, y, L["OPT_MINIMAP_GLOW_TITLE"], L["OPT_MINIMAP_GLOW_DESC"],
        function() return ns.MinimapButton and ns.MinimapButton.GetGlow() end,
        function(on) if ns.MinimapButton then ns.MinimapButton.SetGlow(on) end end)

  y = y - 4
  y = AddButton(frame, y,
        function() return L["OPT_MINIMAP_RESET_POS"] end,
        L["OPT_MINIMAP_RESET_POS_DESC"],
        function() if ns.MinimapButton then ns.MinimapButton.ResetPosition() end end)

  -- EllesmereUI's own minimap draws a mail icon of its own that no supported
  -- setting hides (verified against its source; its hideMail key is dead
  -- code). Postbox will not reach into another addon's internals to remove
  -- it, so when that module is loaded the honest thing is to say both may be
  -- visible and let the user decide.
  if C_AddOns and type(C_AddOns.IsAddOnLoaded) == "function"
     and C_AddOns.IsAddOnLoaded("EllesmereUIMinimap") then
    local note = ns.Theme.CreateText(frame, "bodySmall")
    note:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
    note:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
    note:SetJustifyH("LEFT")
    note:SetWordWrap(true)
    note:SetText(L["OPT_MINIMAP_EUI_NOTE"])
    MarkBottom(frame, y, 30)
    y = y - 36
  end

  -- Host-UI appearance section (only when a skin exposes these controls).
  local Skin = GetSkin()
  if Skin then
    y = y - 6
    local heading = ns.Theme.CreateText(frame, "heading")
    heading:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
    heading:SetWordWrap(false)
    heading:SetText(L["OPT_APPEARANCE_HEADING"])
    y = y - 22

    -- Border style and size both default to whatever EllesmereUI itself is
    -- configured for, so a shadow (or none) on the rest of the UI carries here.
    local borderItems = { { id = "auto", name = L["OPT_BG_OPACITY_AUTO"] } }
    for _, choice in ipairs(Skin.GetBorderChoices()) do
      borderItems[#borderItems + 1] = { id = choice.key, name = choice.name }
    end
    y = AddDropdown(frame, y, L["OPT_BORDER_TITLE"], borderItems,
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
    y = AddDropdown(frame, y, L["OPT_BORDER_SIZE_TITLE"], sizeItems,
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
    y = AddDropdown(frame, y, L["OPT_BG_OPACITY_TITLE"], opacityItems,
          function()
            if Skin.IsBgOpacityDefault and Skin.IsBgOpacityDefault() then return "auto" end
            return math.floor(Skin.GetBgOpacity() * 100 + 0.5)
          end,
          function(id)
            if id == "auto" then Skin.ResetBgOpacity()
            else Skin.SetBgOpacity((tonumber(id) or 100) / 100) end
          end)
  end

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
