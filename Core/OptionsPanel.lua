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

-- The reload offer that follows a style change. Registered on first use, so
-- a player who never touches the style never pays for the dialog.
local POPUP_STYLE_RELOAD = "POSTBOX_STYLE_RELOAD"
local function EnsureStyleDialog()
  if type(StaticPopupDialogs) ~= "table" or type(StaticPopup_Show) ~= "function" then
    return false
  end
  if StaticPopupDialogs[POPUP_STYLE_RELOAD] then return true end
  StaticPopupDialogs[POPUP_STYLE_RELOAD] = {
    text = L["MSG_STYLE_RELOAD"],
    button1 = L["BTN_RELOAD_NOW"],
    button2 = L["BTN_LATER"],
    OnAccept = function() ReloadUI() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    -- Above the options panel, which is FULLSCREEN_DIALOG strata.
    preferredIndex = 3,
  }
  return true
end

-- The HOST UI driving the window's look, or nil when the look is Postbox's
-- own (either style). SkinAppliedBy is the truth once a window has been
-- painted; before that -- the options panel opens from the minimap icon
-- without a mailbox ever having been opened -- fall back to who claimed the
-- skin slot, which login settled.
local function HostSkinName()
  local by = ns.SkinAppliedBy
  if by == "ellesmereui" then return "EllesmereUI" end
  if by == "elvui" then return "ElvUI" end
  if by == "modern" then return nil end

  -- Nothing has been painted yet, so fall back to who holds the skin slot.
  --
  -- The style choice has to be consulted FIRST. This used to read "ns.Skin is
  -- set and a host global exists, therefore the host is painting", which was
  -- sound only while a host skin was the only thing that could claim with one
  -- installed. Postbox Modern can now claim over a host, and on that session
  -- the old test named the host as the painter -- so the panel would have
  -- reported inheriting, in green, while Modern was on screen.
  local UI = ns.MailboxUI
  if UI and type(UI.HostSkinAllowed) == "function" and not UI.HostSkinAllowed() then
    return nil
  end

  if ns.Skin then
    if _G.EllesmereUI then return "EllesmereUI" end
    if _G.ElvUI then return "ElvUI" end
  end
  return nil
end

-- The host UI that is INSTALLED, whether or not it is the one painting. This
-- is the one the style dropdown offers and the one the inheritance line names:
-- a player who has overridden EllesmereUI still needs to see that EllesmereUI
-- is what they overrode, and HostSkinName above deliberately answers nil in
-- exactly that case.
local function InstalledHostName()
  if _G.EllesmereUI then return "EllesmereUI" end
  if _G.ElvUI then return "ElvUI" end
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
-- Returns the next y AND the heading itself, so a section that puts something
-- on the heading line can size it against the heading rather than against a
-- guessed offset.
local function AddSectionHeading(frame, y, title)
  local heading = ns.Theme.CreateText(frame, "heading")
  heading:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
  heading:SetWordWrap(false)
  heading:SetText(title)
  return y - 20, heading
end

local function StartCard(frame, y)
  local card = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  card:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, y)
  card:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
  ns.Theme.ApplyList(card)
  -- Shared by reference: rows built into the card register their refreshers
  -- on the panel, which is what replays them on open.
  card.__refreshers = frame.__refreshers
  return card
end

-- The two together, for a section whose heading carries nothing but its title.
-- A section that hangs a control on the heading line -- Appearance, Minimap --
-- calls the two itself, because it has to put something between them.
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

  cy = AddCheckbox(card, cy, L["OPT_ALL_TAB_TITLE"], L["OPT_ALL_TAB_DESC"],
        function() return ns.MailboxUI.GetOption("showAllTab") end,
        function(on)
          ns.MailboxUI.SetOption("showAllTab", on)
          if ns.MailboxUI.RefreshCollectSegments then ns.MailboxUI.RefreshCollectSegments() end
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
  -- the checkbox column, tall as the five rows. It makes the feature loud
  -- and shaves a whole row off the card. /postbox recipients is the other
  -- way in.
  local rmButton = ns.Theme.CreateButton(nil, card)
  rmButton:SetSize(108, (ROW_H * 5) - 8)

  -- The stock plate is a ~22px three-slice; stretched to portrait height it
  -- smears into pixel blocks (screenshot-verified). Under a host skin the
  -- repaint hides that, so ONLY the unskinned session flattens it: template
  -- art gone, one card surface, a quiet flat hover. ns.Skin is claimed at
  -- PLAYER_LOGIN, well before this lazy Build can run.
  if not ns.Skin then
    for _, region in ipairs({ rmButton:GetRegions() }) do
      if region.IsObjectType and region:IsObjectType("Texture") then
        region:SetTexture(nil)
        region:Hide()
      end
    end
    -- The button template has NO backdrop support, and the theme's panel
    -- paint declines silently on a frame without it -- which left this
    -- button entirely transparent, showing the card behind it (two rounds
    -- of "why is it still black" were colour-tuning a backdrop that never
    -- existed). Retrofit the mixin first; everything below finally lands.
    if type(rmButton.SetBackdrop) ~= "function"
      and type(Mixin) == "function" and type(BackdropTemplateMixin) == "table" then
      Mixin(rmButton, BackdropTemplateMixin)
      if type(rmButton.OnBackdropSizeChanged) == "function" then
        rmButton:HookScript("OnSizeChanged", rmButton.OnBackdropSizeChanged)
      end
    end
    ns.Theme.ApplyList(rmButton)
    -- Lifted off the list scheme's pure black: this is a BUTTON wearing the
    -- card surface, and it has to read as raised next to the checkbox column
    -- rather than as a hole in the card. The surface GRAIN has to go first
    -- -- it is a full-alpha texture painted above the backdrop fill, so any
    -- colour set below it is invisible (and a texture pack can turn the
    -- grain itself near-black, which is exactly the hole this fixes).
    if rmButton.pbSurfaceTexture then rmButton.pbSurfaceTexture:SetAlpha(0) end
    -- The card behind is pure black; the button is the SAME tone one step
    -- lighter -- a neutral near-black, not a colour of its own. (A warm
    -- brown tried here read as a different material entirely.)
    if rmButton.SetBackdropColor then
      rmButton:SetBackdropColor(0.10, 0.10, 0.11, 0.95)
    end
    rmButton:SetHighlightTexture("Interface\\AddOns\\Postbox\\Media\\white8x8.tga")
    local flatHover = rmButton:GetHighlightTexture()
    if flatHover then
      flatHover:SetAllPoints()
      flatHover:SetAlpha(0.06)
    end
  end
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
    -- One point up from the button role's size: this is the loudest control
    -- on the card and its title was set no larger than a checkbox caption.
    -- A host skin's re-font can override this; that is its right.
    local fontPath, fontSize, fontFlags = rmLabel:GetFont()
    if fontPath and fontSize then
      rmLabel:SetFont(fontPath, fontSize + 1, fontFlags)
    end
  end
  rmButton:SetText(L["RM_OPT_BUTTON"])
  -- On an art holder, not the button: a host skin's button repaint fades
  -- the tagged button's own texture regions, which kept this icon invisible.
  local rmHolder = ArtHolder(rmButton)
  -- A quiet radial glow behind the bundle: the accent at low alpha, static
  -- -- no pulse; this is presence, not an alert. Under the icon in the same
  -- ARTWORK layer, both on the holder so a host skin's repaint cannot fade
  -- either. Re-tinted on every panel open, so an accent retune follows.
  local rmGlow = rmHolder:CreateTexture(nil, "ARTWORK", nil, -1)
  rmGlow:SetSize(94, 94)
  rmGlow:SetPoint("CENTER", rmButton, "CENTER", 0, -4)
  rmGlow:SetTexture("Interface\\AddOns\\Postbox\\Media\\minimap-glow.tga")
  rmGlow:SetBlendMode("ADD")
  rmGlow:SetAlpha(0.30)
  local function TintRmGlow()
    local r, g, b = ns.Theme.GetAccent()
    rmGlow:SetVertexColor(r, g, b)
  end
  TintRmGlow()
  frame.__refreshers[#frame.__refreshers + 1] = TintRmGlow

  local rmMark = rmHolder:CreateTexture(nil, "ARTWORK")
  -- 50, was 46: the caption row below bought the portrait an extra row of
  -- height, and the icon is the thing worth spending it on.
  rmMark:SetSize(50, 50)
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

  -- The Mail tab's caption mode, one full-column control under the
  -- checkboxes. The closed toggle wears the row's NAME, not the selection --
  -- a bare "Nothing" floating in the card reads as broken -- and the open
  -- list and the tooltip carry the current choice. The recipients portrait
  -- keeps its own column and stretches to end level with this row.
  local tcItems = {
    { id = "dot",    name = L["OPT_TAB_CAPTION_DOT"] },
    { id = "total",  name = L["OPT_TAB_CAPTION_TOTAL"] },
    { id = "counts", name = L["OPT_TAB_CAPTION_COUNTS"] },
    { id = "none",   name = L["OPT_TAB_CAPTION_NONE"] },
  }
  -- The toggle wears the row's NAME while the setting is off ("Nothing" is
  -- the default and a bare "Nothing" floating in the card reads as broken),
  -- and the chosen mode's name once one is actually on -- so a glance tells
  -- you whether the tab carries anything without opening the list.
  local function TcToggleText()
    local mode = ns.MailboxUI.GetTabCaptionMode and ns.MailboxUI.GetTabCaptionMode() or "none"
    if mode ~= "none" then
      for _, item in ipairs(tcItems) do
        if item.id == mode then return item.name end
      end
    end
    return L["OPT_TAB_CAPTION_TITLE"]
  end
  -- Card width minus its own padding, the portrait column and the gap.
  local tcWidth = (W - 20) - PAD * 2 - 108 - 10
  local tcDD = ns.Core.UI.Dropdown.Create(card, {
    items        = tcItems,
    toggleWidth  = tcWidth,
    toggleHeight = 22,
    height       = DROPDOWN_H,
    listWidth    = tcWidth,
    defaultId    = ns.MailboxUI.GetTabCaptionMode and ns.MailboxUI.GetTabCaptionMode(),
  })
  -- Right edge from the CARD, not from rmButton: rmButton's bottom anchors
  -- to this row below, and any anchor back at it -- even on the other axis
  -- -- is a cycle the client refuses. The offset is the portrait column's
  -- width plus the gap, same arithmetic as tcWidth above.
  tcDD:SetPoint("TOPLEFT", card, "TOPLEFT", PAD, cy)
  tcDD:SetPoint("RIGHT", card, "RIGHT", -(PAD + 108 + 10), 0)
  local tcToggle = tcDD._toggle
  if tcToggle then
    -- Fill the column whatever the fixed width said.
    tcToggle:ClearAllPoints()
    tcToggle:SetPoint("LEFT", tcDD, "LEFT", 0, 0)
    tcToggle:SetPoint("RIGHT", tcDD, "RIGHT", 0, 0)
  end
  tcDD:SetText(TcToggleText())
  tcDD:SetChangeCallback(function(id)
    if ns.MailboxUI.SetTabCaptionMode then ns.MailboxUI.SetTabCaptionMode(id) end
    -- After the widget's own write (see the row OnClick order): the mode's
    -- name for a live mode, the row name for "Nothing".
    tcDD:SetText(TcToggleText())
  end)
  if tcToggle then
    tcToggle:HookScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(L["OPT_TAB_CAPTION_TITLE"])
      GameTooltip:AddLine(L["OPT_TAB_CAPTION_DESC"], 1, 1, 1, true)
      local mode = ns.MailboxUI.GetTabCaptionMode and ns.MailboxUI.GetTabCaptionMode()
      for _, item in ipairs(tcItems) do
        if item.id == mode then
          GameTooltip:AddLine(item.name, 0.96, 0.80, 0.18)
          break
        end
      end
      GameTooltip:Show()
    end)
    tcToggle:HookScript("OnLeave", function() GameTooltip:Hide() end)
  end
  frame.__refreshers[#frame.__refreshers + 1] = function()
    if ns.MailboxUI.GetTabCaptionMode then
      tcDD._selectedId = ns.MailboxUI.GetTabCaptionMode()
    end
    tcDD:SetText(TcToggleText())
  end
  -- The portrait ends level with this row: top from the card, bottom from
  -- the TOGGLE (which sits centred inside its slightly taller container --
  -- anchoring to the container left the portrait a pixel long). The height
  -- from SetSize above is overridden by the pair of vertical anchors.
  if tcToggle then
    rmButton:SetPoint("BOTTOM", tcToggle, "BOTTOM", 0, 0)
  else
    rmButton:SetPoint("BOTTOM", tcDD, "BOTTOM", 0, 0)
  end
  MarkBottom(card, cy, DROPDOWN_H)
  cy = cy - ROW_H

  y = EndSection(frame, card, y)

  -- Mail alerts: the three ways Postbox tells you about mail you are not
  -- standing in front of. They were scattered through the Minimap card,
  -- which is where the icon's LOOK is configured -- a sound is not a look,
  -- and the memory is a window rather than an icon setting. Two of the
  -- three are delivered THROUGH the icon, which their tooltips say.
  y = AddSectionHeading(frame, y, L["OPT_ALERTS_HEADING"])
  card = StartCard(frame, y)
  cy = -12

  cy = AddCheckbox(card, cy, L["OPT_ALERT_SOUND_TITLE"], L["OPT_ALERT_SOUND_DESC"],
        function() return ns.MinimapButton and ns.MinimapButton.GetAlertSound() end,
        function(on) if ns.MinimapButton then ns.MinimapButton.SetAlertSound(on) end end)

  cy = AddCheckbox(card, cy, L["OPT_ALERT_FLASH_TITLE"], L["OPT_ALERT_FLASH_DESC"],
        function() return ns.MinimapButton and ns.MinimapButton.GetAlertFlash() end,
        function(on) if ns.MinimapButton then ns.MinimapButton.SetAlertFlash(on) end end)

  cy = AddCheckbox(card, cy, L["OPT_MEMORY_TITLE"], L["OPT_MEMORY_DESC"],
        function() return ns.MailboxUI.GetOption("mailMemory") end,
        function(on) ns.MailboxUI.SetOption("mailMemory", on) end)

  y = EndSection(frame, card, y)

  -- Appearance: everything about how the window looks, in one card.
  --
  -- Style and Appearance used to be two sections, which read as siblings and
  -- were not. The three controls below the style row are the CHOSEN STYLE'S
  -- OWN -- they call whatever skin claimed the window -- so they are a
  -- consequence of the style rather than a peer of it. Splitting them also
  -- spent a whole section's chrome (a heading, a gap and a card's padding) on
  -- one 22px line, which was the worst ratio in the panel.
  local installedHost = InstalledHostName()

  local appHeadingY = y
  local appHeading
  y, appHeading = AddSectionHeading(frame, y, L["OPT_APPEARANCE_HEADING"])
  -- The badge makes this heading line taller than heading text alone, which is
  -- the same thing the minimap section's master switch does to its heading --
  -- so it takes the same four pixels, and the gap down to the card reads as
  -- every other section's. Conditional because the badge is: with no host UI
  -- installed this is a plain heading and wants the plain spacing.
  if installedHost then y = y - 4 end
  card = StartCard(frame, y)
  cy = -12

  -- The style choice. A host UI is offered first and is the default wherever
  -- one is installed, so the familiar answer is the one already selected --
  -- but it is now an answer rather than a foregone conclusion.
  local styleItems = {}
  if installedHost then
    styleItems[#styleItems + 1] = { id = "host", name = installedHost }
  end
  styleItems[#styleItems + 1] = { id = "blizzard", name = L["OPT_STYLE_BLIZZARD"] }
  styleItems[#styleItems + 1] = { id = "modern",   name = L["OPT_STYLE_MODERN"] }

  cy = AddDropdown(card, cy, L["OPT_STYLE_TITLE"], styleItems,
        function() return ns.MailboxUI.GetStyleChoice and ns.MailboxUI.GetStyleChoice() end,
        function(id)
          if ns.MailboxUI.SetStyleChoice then ns.MailboxUI.SetStyleChoice(id) end
          -- The style is claimed once at login, so the choice needs a
          -- reload to take. A dialog with the reload in it beats a chat
          -- line telling the player to go and type one -- and Later is a
          -- real answer: the setting is already saved either way.
          if EnsureStyleDialog() then
            StaticPopup_Show(POPUP_STYLE_RELOAD)
          else
            ns.Print(L["MSG_STYLE_RELOAD"])
          end
        end)

  -- The inheritance badge. Only where there is something to inherit FROM, and
  -- it answers one question about the section as a whole: is this window
  -- wearing your UI pack's look, or Postbox's? Green for inheriting, because
  -- that is the state where Postbox has wired itself into something else
  -- correctly -- the same language the bottom band used to carry.
  if installedHost then
    -- On the HEADING line, right-aligned, the way the minimap section hangs its
    -- master switch there. It belongs to the whole section rather than to any
    -- one row in it -- it is the answer to "where is this section's look coming
    -- from" -- and inside the card it read as another setting, indented level
    -- with the controls it was actually describing.
    --
    -- Sized against the heading rather than a guessed offset: the badge's top
    -- and height are the heading's, so anything anchored to its vertical centre
    -- is on the heading's centre line by construction, whatever font the theme
    -- gives either of them.
    local badge = CreateFrame("Frame", nil, frame)
    badge:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, appHeadingY)
    badge:SetHeight(math.max(1, math.ceil(appHeading:GetStringHeight() or 12)))

    local dot = badge:CreateTexture(nil, "OVERLAY")
    dot:SetSize(7, 7)

    local text = ns.Theme.CreateText(badge, "secondary")
    text:SetPoint("RIGHT", badge, "RIGHT", 0, 0)
    text:SetJustifyH("RIGHT")
    text:SetWordWrap(false)

    -- One pixel UP, and it is a correction rather than a nudge.
    --
    -- A font string's box runs from the ascender's top to the descender's
    -- bottom, so its geometric centre sits below the middle of the letters you
    -- actually see -- the descender space is empty on a line like this one but
    -- still counts. Centring the square on that box therefore centres it on the
    -- box and NOT on the text, which is what reads as low. The letters' own
    -- centre is half a descent higher, and at this size that is a pixel.
    dot:SetPoint("RIGHT", text, "LEFT", -6, 1)

    -- Re-derived on every open rather than fixed at build. It describes the
    -- LIVE session -- who is painting right now, not what is saved for the next
    -- one -- and that answer can still change after login: EllesmereUI can be
    -- published late by a load-on-demand addon, and its skin claims through a
    -- deferred handshake. A line that had already decided would be wrong for
    -- the rest of the session.
    --
    -- The two descriptions take different numbers of arguments (the override
    -- one names the host twice: once for the window, once for the minimap it
    -- still follows) and ns.L formats through string.format WITHOUT a pcall,
    -- so each is given exactly its own.
    local badgeTitle, badgeDesc
    local function RefreshInheritance()
      if HostSkinName() then
        dot:SetColorTexture(0.38, 0.80, 0.44, 1)
        badgeTitle = L("OPT_STYLE_INHERIT", installedHost)
        badgeDesc  = L("OPT_STYLE_INHERIT_DESC", installedHost)
      else
        -- Neutral grey, not a warning colour: a deliberate choice is not a
        -- fault, and dressing it as one would be a scold.
        dot:SetColorTexture(0.54, 0.54, 0.58, 1)
        badgeTitle = L("OPT_STYLE_OVERRIDE", installedHost)
        badgeDesc  = L("OPT_STYLE_OVERRIDE_DESC", installedHost, installedHost)
      end
      text:SetText(badgeTitle)
      -- The badge is only as wide as what it currently says: dot, gap, text.
      -- Re-measured here because the two states are different lengths, and a
      -- width left over from the other one would put the hover target in the
      -- wrong place.
      badge:SetWidth(7 + 6 + math.ceil(text:GetStringWidth() or 0))
    end
    RefreshInheritance()
    frame.__refreshers[#frame.__refreshers + 1] = RefreshInheritance

    -- The pointer, not the button. This sits over the section heading, and a
    -- frame that swallows clicks to show a tooltip is the defect 1.30.5 fixed
    -- across every window -- there it stopped the title bar being draggable.
    badge:EnableMouse(true)
    if badge.SetPropagateMouseClicks then badge:SetPropagateMouseClicks(true) end
    badge:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(badgeTitle)
      GameTooltip:AddLine(badgeDesc, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    badge:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end

  -- The chosen style's own controls. Whichever skin claimed the window
  -- answers these; the panel does not know or care which one it is talking to.
  -- A style that publishes no such controls (Blizzard) simply contributes
  -- nothing here, and the card is the style row alone.
  do
    local Skin = GetSkin()
    if Skin then
      -- "Leave it alone" means different things to different styles: under a
      -- host it means match that UI, and under Postbox's own it means the
      -- value the skin was authored with. Same control, honest label either
      -- way -- it used to read "Match EllesmereUI" from a hardcoded string,
      -- which was already wrong for ElvUI and would have been wrong here.
      local autoName = HostSkinName()
        and L("OPT_APPEARANCE_MATCH", HostSkinName())
        or L["OPT_APPEARANCE_DEFAULT"]

      local borderItems = { { id = "auto", name = autoName } }
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

      local sizeItems = { { id = "auto", name = autoName } }
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

      local opacityItems = { { id = "auto", name = autoName } }
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
    end
  end

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
    -- The sealed family is ONE name numbered 1-4: four takes on the same
    -- object, and the art-derived names read as four different objects.
    -- stampedclean gets its own key rather than the clean suffix, which
    -- would have printed "Sealed letter 2 2".
    { id = "sealed",       name = L["OPT_MINIMAP_ICON_SEALED"] },
    { id = "stamped",      name = L["OPT_MINIMAP_ICON_STAMPED"] },
    { id = "stampedclean", name = L["OPT_MINIMAP_ICON_STAMPED_B"] },
    { id = "weathered",    name = L["OPT_MINIMAP_ICON_WEATHERED"] },
    -- The bundles ride directly behind the letters they are made of.
    { id = "bundle",       name = L["OPT_MINIMAP_ICON_BUNDLE"] },
    { id = "bundleclean",  name = CleanName("OPT_MINIMAP_ICON_BUNDLE") },
    { id = "open",         name = L["OPT_MINIMAP_ICON_OPEN"] },
    { id = "scroll",       name = L["OPT_MINIMAP_ICON_SCROLL"] },
    { id = "seal",         name = L["OPT_MINIMAP_ICON_SEAL"] },
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
  -- cy - 53, not - 54: mathematically -54 puts the toggle's bottom flush with
  -- the stage's, but the rendered button reads 1px low against it (border and
  -- baseline both draw inside the frame rect). Tuned by eye in game.
  iconDD:SetPoint("TOPLEFT", card, "TOPLEFT", PAD + 80, cy - 53)
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

    -- Every placement in ONE list -- a mode checkbox beside a position list
    -- gave two controls authority over one fact, and they contradicted each
    -- other the moment shift-drag moved the icon. Blizzard default leads:
    -- it is where the stock indicator lives and the fresh-install default.
    local mmPositionItems = {
      { id = "BLIZZARD",    name = L["OPT_MINIMAP_POS_BLIZZARD"] },
      { id = "TOPRIGHT",    name = L["OPT_MINIMAP_POS_TR"] },
      { id = "TOPLEFT",     name = L["OPT_MINIMAP_POS_TL"] },
      { id = "BOTTOMRIGHT", name = L["OPT_MINIMAP_POS_BR"] },
      { id = "BOTTOMLEFT",  name = L["OPT_MINIMAP_POS_BL"] },
      { id = "CUSTOM",      name = L["OPT_MINIMAP_POS_CUSTOM"] },
      { id = "FREE",        name = L["OPT_MINIMAP_POS_FREE"] },
    }
    cy = AddDropdown(card, cy, L["OPT_MINIMAP_POS_TITLE"], mmPositionItems,
          function() return ns.MinimapButton and ns.MinimapButton.GetPosition() end,
          function(id) if ns.MinimapButton then ns.MinimapButton.SetPosition(id) end end)

    cy = AddCheckbox(card, cy, L["OPT_MINIMAP_LOCK_TITLE"], L["OPT_MINIMAP_LOCK_DESC"],
          function() return ns.MinimapButton and ns.MinimapButton.GetLocked() end,
          function(on) if ns.MinimapButton then ns.MinimapButton.SetLocked(on) end end)

  end

  if not mmHostStyled then
    cy = cy - 4
    cy = AddButton(card, cy,
          function() return L["OPT_MINIMAP_RESET_POS"] end,
          L["OPT_MINIMAP_RESET_POS_DESC"],
          function()
            if ns.MinimapButton then ns.MinimapButton.ResetPosition() end
            -- The reset just rewrote position AND detachment; the dropdown
            -- and the checkboxes above must say so immediately, not on the
            -- panel's next open.
            Panel.RefreshControls()
          end)
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

  -- The footer: what this build is, and the one door out to a bug report.
  -- It used to announce which look was painting the addon -- a sentence
  -- that belongs with the Style section (and now lives there), and that
  -- read "Postbox's own style" even when the Blizzard style had been chosen
  -- deliberately. What is left is the two things a footer is for.
  y = y - 2
  local statusBand = CreateFrame("Button", nil, frame, "BackdropTemplate")
  statusBand:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, y)
  statusBand:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
  statusBand:SetHeight(24)
  ns.Theme.ApplyBand(statusBand)

  local statusText = ns.Theme.CreateText(statusBand, "bodySmall")
  statusText:SetPoint("CENTER", statusBand, "CENTER", 0, 0)
  statusText:SetJustifyH("CENTER")
  statusText:SetWordWrap(false)
  -- Says what the click does. The band has always opened the bug report;
  -- nothing on it ever said so.
  statusText:SetText(L["OPT_REPORT_BUG"])
  statusText:SetAlpha(0.85)

  -- The packager stamps the release TAG into the TOC, which already carries
  -- its own "v" -- do not add another.
  local versionText = ns.Theme.CreateText(statusBand, "bodySmall")
  versionText:SetPoint("RIGHT", statusBand, "RIGHT", -8, 0)
  versionText:SetJustifyH("RIGHT")
  versionText:SetText(tostring(ns.VERSION or ""))
  versionText:SetAlpha(0.55)

  -- The bug-report popup: the report address and a one-line setup summary,
  -- each in a copyable box. No browser can be opened from in-game, so
  -- copyable is the whole feature.
  local BUG_URL = "https://github.com/egsherlock/Postbox/issues"
  local bugPopup
  local function AddCopyRow(pop, rowY, labelKey, boxHeight)
    local caption = ns.Theme.CreateText(pop, "label")
    caption:SetPoint("TOPLEFT", pop, "TOPLEFT", 10, rowY)
    caption:SetText(L[labelKey])

    local box
    if boxHeight then
      -- The diagnostic report outgrows any fixed height as the addon learns
      -- to say more, so the multi-line box lives inside a scroll frame: the
      -- viewport clips, the wheel scrolls, and focusing keeps the cursor in
      -- view. A multi-line EditBox sizes its own height to its content.
      local viewport = CreateFrame("ScrollFrame", nil, pop)
      viewport:SetSize(304, boxHeight)
      viewport:SetPoint("TOPLEFT", pop, "TOPLEFT", 10, rowY - 14)

      box = CreateFrame("EditBox", nil, viewport)
      box:SetWidth(304)
      box:SetHeight(boxHeight)
      box:SetAutoFocus(false)
      box:SetMultiLine(true)
      viewport:SetScrollChild(box)

      local function Range()
        return math.max(0, box:GetHeight() - boxHeight)
      end
      local function Wheel(_, delta)
        viewport:SetVerticalScroll(
          math.max(0, math.min(Range(), viewport:GetVerticalScroll() - delta * 24)))
      end
      viewport:EnableMouseWheel(true)
      viewport:SetScript("OnMouseWheel", Wheel)
      box:EnableMouseWheel(true)
      box:SetScript("OnMouseWheel", Wheel)
      -- Arrowing through the text keeps the cursor line inside the viewport.
      box:SetScript("OnCursorChanged", function(_, _, cursorY, _, cursorH)
        local offset = viewport:GetVerticalScroll()
        local top = -(tonumber(cursorY) or 0)
        local bottom = top + (tonumber(cursorH) or 0)
        if top < offset then
          viewport:SetVerticalScroll(math.max(0, top))
        elseif bottom > offset + boxHeight then
          viewport:SetVerticalScroll(math.min(Range(), bottom - boxHeight))
        end
      end)
      box.__viewport = viewport
    else
      box = CreateFrame("EditBox", nil, pop)
      box:SetSize(304, 14)
      box:SetPoint("TOPLEFT", pop, "TOPLEFT", 10, rowY - 14)
      box:SetAutoFocus(false)
    end
    box:SetFontObject(ns.Theme.FontObject("bodySmall") or GameFontHighlightSmall)
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- Read-only in effect: any user edit snaps the text back and re-selects,
    -- so Ctrl+C always copies the intact value. OnTextChanged rather than
    -- OnChar: Backspace, Delete and Enter change the text without ever
    -- firing OnChar. The flag stops the restore re-entering itself.
    box:SetScript("OnTextChanged", function(self, userInput)
      if not userInput or self._restoring then return end
      self._restoring = true
      self:SetText(self._value or "")
      self._restoring = false
      self:HighlightText()
    end)
    function box:SetValue(value)
      self._value = value or ""
      self:SetText(self._value)
      if self.__viewport then self.__viewport:SetVerticalScroll(0) end
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
      -- Named: Escape-to-close works through UISpecialFrames, which is a
      -- list of frame NAMES -- RegisterEscClose is a silent no-op on an
      -- unnamed frame.
      bugPopup = CreateFrame("Frame", "PostboxBugReportFrame", UIParent, "BackdropTemplate")
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
      -- Under the field name the skins look for: both restyle a window's
      -- `CloseButton` into their own small X, which is what keeps this one
      -- the same species as the options panel's instead of the stock art
      -- at full size.
      bugPopup.CloseButton = close

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
    if statusBand:GetTop() then
      bugPopup:SetPoint("BOTTOM", statusBand, "TOP", 0, 8)
    else
      -- /postbox debug before the panel has ever been positioned: the band
      -- has no resolvable rect, and a frame anchored to one never lays out.
      bugPopup:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    end
    bugPopup:Show()
    -- Effortless copying: the address arrives focused and selected, so
    -- Ctrl+C is the only keystroke needed.
    bugPopup._url:SetFocus()
  end
  -- /postbox debug reaches this without the panel being open.
  Panel._toggleBugReport = ToggleBugReport

  statusBand:SetScript("OnClick", ToggleBugReport)
  -- The band's own text carries the hover now; the green wash it used to
  -- brighten went with the style sentence to the Style section.
  statusBand:SetScript("OnEnter", function(self)
    statusText:SetAlpha(1)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["OPT_BUG_TIP_TITLE"])
    GameTooltip:AddLine(L["OPT_BUG_TIP_DESC"], 1, 1, 1, true)
    GameTooltip:Show()
  end)
  statusBand:SetScript("OnLeave", function()
    statusText:SetAlpha(0.85)
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

-- Re-reads every control from its source of truth. The refreshers replay on
-- every open anyway; this exists for state that changes WHILE the panel is
-- up -- a reset button, a shift-drag turning a preset into Custom.
function Panel.RefreshControls()
  local frame = Panel._frame
  if not (frame and frame:IsShown()) then return end
  for _, fn in ipairs(frame.__refreshers) do pcall(fn) end
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
