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
-- 24, and ONE number for every section. It used to be 20, with the two sections
-- that hang a control on the heading line -- Minimap's master switch and
-- Appearance's inheritance badge -- each subtracting a further 4 of their own
-- afterwards. That is the right gap for a taller line and the wrong way to
-- reach it: two thirds of the panel then sat at one spacing and the rest at
-- another, which reads as the plain headings being crowded rather than as the
-- tall ones being roomy. The gap now allows for a control on the heading line
-- whether or not a given section has one, and no section adjusts it.
local function AddSectionHeading(frame, y, title)
  local heading = ns.Theme.CreateText(frame, "heading")
  heading:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
  heading:SetWordWrap(false)
  heading:SetText(title)
  return y - 24
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

-- The figures a mail row carries, as a line of plates in the order the rows
-- draw them: click one to show or hide it, drag one sideways to move it.
-- One control answers both questions -- which, and in what order -- and it
-- reads as the row it configures rather than as a list of switches. Gold is
-- one plate with four states, because earned and spent share a column (a
-- mail has at most one sum): Gold, Earned, Spent, hidden, in that cycle.
--
-- `onChange` runs after every change, to repaint whatever lists rows.
local function AddFigurePills(frame, y, title, hint, onChange)
  local T = ns.Theme
  local UI = ns.MailboxUI
  local indent = PAD + CHECK_H + 4

  local caption = T.CreateText(frame, "label")
  caption:SetPoint("TOPLEFT", frame, "TOPLEFT", indent, y - 4)
  caption:SetJustifyH("LEFT")
  caption:SetWordWrap(false)
  caption:SetText(title)

  -- How to use it, quietly, on the caption's own line.
  local how = T.CreateText(frame, "secondary")
  how:SetPoint("LEFT", caption, "RIGHT", 8, 0)
  how:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
  how:SetJustifyH("RIGHT")
  how:SetWordWrap(false)
  how:SetText(hint)

  local lineY = y - 22
  local plates = {}

  local function Gold()
    local earned, spent = UI.GetOption("rowEarned"), UI.GetOption("rowSpent")
    if earned and spent then return "both" end
    if earned then return "earned" end
    if spent then return "spent" end
    return "none"
  end
  local GOLD_NEXT = { both = "earned", earned = "spent", spent = "none", none = "both" }
  local GOLD_LABEL = { both = "OPT_ROW_GOLD", earned = "OPT_ROW_EARNED", spent = "OPT_ROW_SPENT", none = "OPT_ROW_GOLD" }

  local spec = {
    time = {
      label = function() return L["OPT_ROW_EXPIRY"] end,
      desc = L["OPT_ROW_EXPIRY_DESC"],
      on = function() return UI.GetOption("rowExpiry") end,
      click = function() UI.SetOption("rowExpiry", not UI.GetOption("rowExpiry")) end,
    },
    money = {
      label = function() return L[GOLD_LABEL[Gold()]] end,
      desc = L["OPT_ROW_GOLD_DESC"],
      on = function() return Gold() ~= "none" end,
      click = function()
        local nextState = GOLD_NEXT[Gold()]
        UI.SetOption("rowEarned", nextState == "both" or nextState == "earned")
        UI.SetOption("rowSpent", nextState == "both" or nextState == "spent")
      end,
    },
    slots = {
      label = function() return L["OPT_ROW_SLOTS"] end,
      desc = L["OPT_ROW_SLOTS_DESC"],
      on = function() return UI.GetOption("rowSlots") end,
      click = function() UI.SetOption("rowSlots", not UI.GetOption("rowSlots")) end,
    },
  }

  local function Paint(plate)
    local s = spec[plate.figure]
    plate:SetText(s.label())
    plate:SetWidth(math.ceil(T.TextWidth(plate)) + 24)
    local on = s.on() and true or false
    T.SetPlateSelected(plate, on)
    if not on then T.DimCaption(plate) end
  end

  local function Layout()
    local order = UI.GetRowOrder()
    local x = indent
    for i = 1, #order do
      local plate = plates[order[i]]
      Paint(plate)
      plate:ClearAllPoints()
      plate:SetPoint("TOPLEFT", frame, "TOPLEFT", x, lineY)
      x = x + plate:GetWidth() + 6
    end
  end

  for id in pairs(spec) do
    local plate = T.CreatePlate(frame, "segment")
    plate.figure = id
    plate:SetHeight(CHECK_H)
    plate:RegisterForDrag("LeftButton")
    plate:SetScript("OnClick", function(self)
      -- A drag ends in a click on some clients; the drag already did its job.
      if self._dragged then
        self._dragged = nil
        return
      end
      spec[self.figure].click()
      Layout()
      if type(SOUNDKIT) == "table" then PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) end
      onChange()
    end)
    plate:SetScript("OnDragStart", function(self)
      local scale = self:GetEffectiveScale()
      local cursorX = GetCursorPosition() / scale
      self._grab = cursorX - (self:GetLeft() or cursorX)
      self:SetFrameLevel(self:GetFrameLevel() + 5)
      self:SetScript("OnUpdate", function(me)
        local left = frame:GetLeft() or 0
        local x = GetCursorPosition() / scale - left - me._grab
        me:ClearAllPoints()
        me:SetPoint("TOPLEFT", frame, "TOPLEFT", x, lineY)
      end)
    end)
    plate:SetScript("OnDragStop", function(self)
      self:SetScript("OnUpdate", nil)
      self:SetFrameLevel(math.max(self:GetFrameLevel() - 5, 0))
      self._dragged = true
      C_Timer.After(0, function() self._dragged = nil end)
      -- The new order is the plates' order across the line, dragged one
      -- included, read from where each one's centre now stands.
      local order = UI.GetRowOrder()
      table.sort(order, function(p, q)
        return (plates[p]:GetCenter() or 0) < (plates[q]:GetCenter() or 0)
      end)
      UI.SetRowOrder(order)
      Layout()
      onChange()
    end)
    plate:HookScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(spec[self.figure].label())
      GameTooltip:AddLine(spec[self.figure].desc, 1, 1, 1, true)
      GameTooltip:AddLine(hint, 0.6, 0.6, 0.6, true)
      GameTooltip:Show()
    end)
    -- The plate's own hover repaints its caption; a hidden figure has to go
    -- dim again after it.
    plate:HookScript("OnLeave", function(self)
      GameTooltip:Hide()
      if not spec[self.figure].on() then T.DimCaption(self) end
    end)
    plates[id] = plate
  end

  Layout()
  frame.__refreshers[#frame.__refreshers + 1] = Layout
  MarkBottom(frame, lineY, CHECK_H)
  return lineY - ROW_H
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

  -- The panel is ordered the way the window is: the Mail tab, the Send tab,
  -- the window they sit in, then what happens away from the mailbox. One
  -- "General" card used to hold eight unrelated switches and the recipient
  -- manager's portrait; a player looking for the thing about sending had to
  -- read the things about the list to find it.

  -- Two columns, so the panel is a rectangle a screen can hold rather than
  -- a strip taller than most. Left: the two tabs and the alerts. Right:
  -- the window and the minimap icon, the two cards with the most in them.
  -- Each column is a frame the sections build into exactly as they built
  -- into the panel, sharing the panel's refresher list; the panel's height
  -- is the taller column's.
  local colTop = y
  local left = CreateFrame("Frame", nil, frame)
  left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, colTop)
  left:SetSize(W, 10)
  left.__refreshers = frame.__refreshers
  local right = CreateFrame("Frame", nil, frame)
  right:SetPoint("TOPLEFT", frame, "TOPLEFT", W - 10, colTop)
  right:SetSize(W, 10)
  right.__refreshers = frame.__refreshers
  local col = left
  y = 0

  -- Mail tab: the list and how it is read, in the order the eye meets it --
  -- the rows, the captions above them, the views, the buttons beneath, the
  -- gesture on a row, and the tab's own caption.
  card, y = BeginSection(col, y, L["OPT_MAILTAB_HEADING"])
  cy = -12

  cy = AddCheckbox(card, cy, L["OPT_COMPACT_ROWS_TITLE"], L["OPT_COMPACT_ROWS_DESC"],
        function() return ns.MailboxUI.GetOption("compactRows") end,
        function(on)
          ns.MailboxUI.SetOption("compactRows", on)
          if ns.MailboxUI.RefreshCollectRowLayout then ns.MailboxUI.RefreshCollectRowLayout() end
        end)

  -- The figures a row carries, under the row layout they belong to. A change
  -- repaints the list and, when it is open, the mailbox memory, which draws
  -- its rows by the same rules.
  cy = AddFigurePills(card, cy, L["OPT_ROW_FIGURES_TITLE"], L["OPT_ROW_FIGURES_HINT"], function()
    if ns.MailboxUI.RefreshCollectRowLayout then ns.MailboxUI.RefreshCollectRowLayout() end
    if ns.MailMemory and ns.MailMemory.Refresh then ns.MailMemory.Refresh() end
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

  cy = AddCheckbox(card, cy, L["OPT_CATEGORY_BUTTONS_TITLE"], L["OPT_CATEGORY_BUTTONS_DESC"],
        function() return ns.MailboxUI.GetOption("showCategoryButtons") end,
        function(on)
          ns.MailboxUI.SetOption("showCategoryButtons", on)
          if ns.MailboxUI.RefreshCollectCategoryButtons then ns.MailboxUI.RefreshCollectCategoryButtons() end
        end)

  -- Nothing to refresh: the mapping is read at the moment a row is clicked, and
  -- the row tooltip's hint line is composed on hover from the same reading. A
  -- list rebuild would repaint rows that are already correct.
  cy = AddCheckbox(card, cy, L["OPT_PREVIEW_CLICK_TITLE"], L["OPT_PREVIEW_CLICK_DESC"],
        function() return ns.MailboxUI.GetOption("previewOnClick") end,
        function(on) ns.MailboxUI.SetOption("previewOnClick", on) end)

  -- The Mail tab's caption mode: a labelled dropdown, the same control the
  -- Window card uses for its style, so the two cards read as one system.
  local tcItems = {
    { id = "dot",    name = L["OPT_TAB_CAPTION_DOT"] },
    { id = "total",  name = L["OPT_TAB_CAPTION_TOTAL"] },
    { id = "counts", name = L["OPT_TAB_CAPTION_COUNTS"] },
    { id = "none",   name = L["OPT_TAB_CAPTION_NONE"] },
  }
  local tcDD
  cy, tcDD = AddDropdown(card, cy, L["OPT_TAB_CAPTION_TITLE"], tcItems,
        function() return ns.MailboxUI.GetTabCaptionMode and ns.MailboxUI.GetTabCaptionMode() or "none" end,
        function(id) if ns.MailboxUI.SetTabCaptionMode then ns.MailboxUI.SetTabCaptionMode(id) end end)
  -- The description on hover, as every checkbox carries its own.
  local tcToggle = tcDD and tcDD._toggle
  if tcToggle then
    tcToggle:HookScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(L["OPT_TAB_CAPTION_TITLE"])
      GameTooltip:AddLine(L["OPT_TAB_CAPTION_DESC"], 1, 1, 1, true)
      GameTooltip:Show()
    end)
    tcToggle:HookScript("OnLeave", function() GameTooltip:Hide() end)
  end

  y = EndSection(col, card, y)

  -- Send tab: the two switches about composing, and the address book they
  -- draw on. The recipient manager is a row here rather than a portrait
  -- beside the list switches: it is about sending, and a row with the live
  -- count on it says as much as the portrait did in a quarter of the space.
  -- /postbox recipients is the other way in.
  card, y = BeginSection(col, y, L["OPT_SENDTAB_HEADING"])
  cy = -12

  cy = AddCheckbox(card, cy, L["OPT_ATTACH_MAIL_TITLE"], L["OPT_ATTACH_MAIL_DESC"],
        function() return ns.MailboxUI.GetOption("attachFromMail") end,
        function(on)
          ns.MailboxUI.SetOption("attachFromMail", on)
          -- Applies to the mailbox that is open right now, not the next one.
          if ns.MailboxUI.RefreshMailTabAttach then ns.MailboxUI.RefreshMailTabAttach() end
        end)

  -- Nothing to refresh: the option is read at the moment a send succeeds.
  cy = AddCheckbox(card, cy, L["OPT_KEEP_RECIPIENT_TITLE"], L["OPT_KEEP_RECIPIENT_DESC"],
        function() return ns.MailboxUI.GetOption("keepRecipient") end,
        function(on) ns.MailboxUI.SetOption("keepRecipient", on) end)


  y = EndSection(col, card, y)

  -- Mail alerts: the three ways Postbox tells you about mail you are not
  -- standing in front of. They were scattered through the Minimap card,
  -- which is where the icon's LOOK is configured -- a sound is not a look,
  -- and the memory is a window rather than an icon setting. Two of the
  -- three are delivered THROUGH the icon, which their tooltips say.
  y = AddSectionHeading(col, y, L["OPT_ALERTS_HEADING"])
  card = StartCard(col, y)
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

  cy = AddCheckbox(card, cy, L["OPT_ALERT_OTHERS_TITLE"], L["OPT_ALERT_OTHERS_DESC"],
        function() return ns.MailboxUI.GetOption("mailWarnings") end,
        function(on) ns.MailboxUI.SetOption("mailWarnings", on) end)

  y = EndSection(col, card, y)

  -- Appearance: everything about how the window looks, in one card.
  --
  -- Style and Appearance used to be two sections, which read as siblings and
  -- were not. The three controls below the style row are the CHOSEN STYLE'S
  -- OWN -- they call whatever skin claimed the window -- so they are a
  -- consequence of the style rather than a peer of it. Splitting them also
  -- spent a whole section's chrome (a heading, a gap and a card's padding) on
  -- one 22px line, which was the worst ratio in the panel.
  local installedHost = InstalledHostName()

  local leftBottom = y
  col = right
  -- Level with the left column's first CARD, not its heading: the hero has
  -- no heading of its own, and its top edge lining up with the Mail tab
  -- card's is what makes the two columns read as one grid.
  y = -24

  -- Manage Recipients: a hero row at the top of the right column, where the
  -- column had the room and the left had none. It opens a whole window of
  -- its own, which makes it the one control here that is a feature rather
  -- than a setting, so it stands apart from the cards rather than in one.
  local HERO_H = 52
  local hero = ns.Theme.CreateButton(nil, right)
  hero:SetHeight(HERO_H)
  hero:SetPoint("TOPLEFT", right, "TOPLEFT", 10, y)
  hero:SetPoint("RIGHT", right, "RIGHT", -10, 0)

  -- The stock plate is a ~22px three-slice; stretched to this height it
  -- smears into pixel blocks. Under a host skin the repaint hides that, so
  -- ONLY the unskinned session flattens it: template art gone, one card
  -- surface a step lighter than the card behind, a quiet flat hover. The
  -- button template has no backdrop support, so the mixin is retrofitted
  -- first or the theme's panel paint declines silently. ns.Skin is claimed
  -- at PLAYER_LOGIN, well before this lazy Build can run.
  if not ns.Skin then
    for _, region in ipairs({ hero:GetRegions() }) do
      if region.IsObjectType and region:IsObjectType("Texture") then
        region:SetTexture(nil)
        region:Hide()
      end
    end
    if type(hero.SetBackdrop) ~= "function"
      and type(Mixin) == "function" and type(BackdropTemplateMixin) == "table" then
      Mixin(hero, BackdropTemplateMixin)
      if type(hero.OnBackdropSizeChanged) == "function" then
        hero:HookScript("OnSizeChanged", hero.OnBackdropSizeChanged)
      end
    end
    -- A card surface of its own, a step above the panel behind it, the way
    -- every field's container stands off the window: it read as a label
    -- floating on the window's own fill.
    ns.Theme.ApplyCard(hero)
    if hero.SetBackdropColor then hero:SetBackdropColor(0.14, 0.14, 0.15, 0.95) end
    hero:SetHighlightTexture("Interface\\AddOns\\Postbox\\Media\\white8x8.tga")
    local flatHover = hero:GetHighlightTexture()
    if flatHover then
      flatHover:SetAllPoints()
      flatHover:SetAlpha(0.06)
    end
  end
  -- Under a host skin the same thing by the skin's own hand: tagged as a
  -- card, it is painted like the other containers rather than as a bare
  -- button on the window's fill.
  hero.__postboxPanel = "card"

  -- The glyph, the title and the count sit on one centred block: the block
  -- is as wide as the glyph plus the wider of the two lines, and the
  -- button centres it, so the trio reads as one mark in the middle rather
  -- than a label pinned to the left edge of a wide button. On an art
  -- holder, not the button: a host skin's button repaint fades a tagged
  -- button's own texture regions.
  local HERO_TEXT_X = 48
  local heroHolder = ArtHolder(hero)
  local heroContent = CreateFrame("Frame", nil, heroHolder)
  heroContent:SetPoint("CENTER", hero, "CENTER", 0, 0)
  heroContent:SetSize(200, HERO_H)

  local heroMark = heroHolder:CreateTexture(nil, "ARTWORK")
  heroMark:SetSize(36, 36)
  heroMark:SetPoint("LEFT", heroContent, "LEFT", 0, 0)
  heroMark:SetTexture("Interface\\AddOns\\Postbox\\Media\\minimap-bundleclean.tga")

  -- The glow is the accent at low alpha, static, re-tinted on every panel open.
  local heroGlow = heroHolder:CreateTexture(nil, "ARTWORK", nil, -1)
  heroGlow:SetSize(64, 64)
  heroGlow:SetPoint("CENTER", heroMark, "CENTER", 0, 0)
  heroGlow:SetTexture("Interface\\AddOns\\Postbox\\Media\\minimap-glow.tga")
  heroGlow:SetBlendMode("ADD")
  heroGlow:SetAlpha(0.30)
  local function TintHeroGlow()
    local r, g, b = ns.Theme.GetAccent()
    heroGlow:SetVertexColor(r, g, b)
  end
  TintHeroGlow()
  frame.__refreshers[#frame.__refreshers + 1] = TintHeroGlow

  -- Title on the first line, in the button's own label one point up from the
  -- caption size (it is the loudest control on the card); the count on the
  -- second, in the secondary role. A host skin's re-font can override the
  -- size; that is its right.
  local heroLabel = hero:GetFontString()
  if heroLabel then
    heroLabel:ClearAllPoints()
    heroLabel:SetPoint("TOPLEFT", heroContent, "TOPLEFT", HERO_TEXT_X, -11)
    heroLabel:SetJustifyH("LEFT")
    heroLabel:SetWordWrap(false)
    local fontPath, fontSize, fontFlags = heroLabel:GetFont()
    if fontPath and fontSize then heroLabel:SetFont(fontPath, fontSize + 1, fontFlags) end
  end
  hero:SetText(L["RM_OPT_BUTTON"])

  local heroCount = ns.Theme.CreateText(hero, "secondary")
  heroCount:SetPoint("TOPLEFT", heroContent, "TOPLEFT", HERO_TEXT_X, -29)
  heroCount:SetJustifyH("LEFT")
  heroCount:SetWordWrap(false)

  local function FitHeroContent()
    local titleW = heroLabel and heroLabel:GetStringWidth() or 0
    local countW = heroCount:GetStringWidth() or 0
    heroContent:SetWidth(HERO_TEXT_X + math.max(titleW, countW))
  end
  local function RefreshHeroCount()
    local RM = ns.RecipientManager
    local count = (RM and type(RM.Count) == "function" and RM.Count()) or 0
    heroCount:SetText(ns.Plural("RM_HERO_COUNT", count))
    FitHeroContent()
  end
  RefreshHeroCount()
  frame.__refreshers[#frame.__refreshers + 1] = RefreshHeroCount

  hero:SetScript("OnClick", function()
    local RM = ns.RecipientManager
    if RM and type(RM.Toggle) == "function" then
      RM.Toggle()
    else
      ns.Print(L["RM_NOT_AVAILABLE"])
    end
  end)
  hero:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["RM_OPT_BUTTON"])
    GameTooltip:AddLine(L["RM_OPT_BUTTON_DESC"], 1, 1, 1, true)
    GameTooltip:Show()
  end)
  hero:SetScript("OnLeave", function() GameTooltip:Hide() end)

  y = y - HERO_H - 16

  local appHeadingY = y
  y = AddSectionHeading(col, y, L["OPT_WINDOW_HEADING"])
  card = StartCard(col, y)
  cy = -12

  -- Where the window opens, before how it is painted: the one setting about
  -- the window's place lived at the top of the old General card, a long way
  -- from the four about its look.
  cy = AddCheckbox(card, cy, L["GRID_TOGGLE_TITLE"], L["GRID_TOGGLE_DESC"],
        function() return ns.MailboxUI.GetOption("gridDock") end,
        function(on)
          ns.MailboxUI.SetOption("gridDock", on)
          if on and ns.MailboxUI._state then ns.MailboxUI._state.freeMoved = false end
          if ns.MailboxUI.ApplyWindowLayout then ns.MailboxUI.ApplyWindowLayout() end
        end)

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
    -- EVERY NUMBER HERE IS EVEN, and that is the fix rather than a detail.
    --
    -- The square was 7px centred in a container sized from the heading's string
    -- height. Centring an odd height leaves the texture's edges on half pixels,
    -- and the client rounds them -- so the square rendered half a pixel off its
    -- own anchor and read as sitting high. Two releases tried to correct that
    -- with a one-pixel offset, once in each direction, which is why neither
    -- landed: a whole pixel cannot cancel half of one, it can only overshoot
    -- the other way.
    --
    -- The geometry is now the minimap section's, which has sat correctly on its
    -- own heading line since it was built: a CHECK_H-tall frame at heading + 5,
    -- with the caption anchored RIGHT-to-LEFT against it and no vertical offset
    -- anywhere. 22 and 8 are both even, so the centre line is a whole pixel and
    -- nothing needs nudging.
    local badge = CreateFrame("Frame", nil, col)
    badge:SetHeight(CHECK_H)
    badge:SetPoint("TOPRIGHT", col, "TOPRIGHT", -PAD, appHeadingY + 5)

    local text = ns.Theme.CreateText(badge, "secondary")
    text:SetPoint("RIGHT", badge, "RIGHT", 0, 0)
    text:SetJustifyH("RIGHT")
    text:SetWordWrap(false)

    local dot = badge:CreateTexture(nil, "OVERLAY")
    dot:SetSize(8, 8)
    dot:SetPoint("RIGHT", text, "LEFT", -6, 0)

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
      badge:SetWidth(8 + 6 + math.ceil(text:GetStringWidth() or 0))
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

  y = EndSection(col, card, y)

  -- Minimap mail icon (Core/MinimapButton.lua). Resolved at click time like
  -- every other binding, so the section stays honest if the module is absent.
  --
  -- The master checkbox shares the heading line, right-aligned, and the card
  -- carries the feature's settings: unchecked, the card desaturates and
  -- stops taking clicks, which is what tells the user those rows belong to
  -- the checkbox.
  local mmHeadingY = y
  y = AddSectionHeading(col, y, L["OPT_MINIMAP_HEADING"])

  local mmHostStyled = ns.MinimapButton and ns.MinimapButton.IsHostStyled
    and ns.MinimapButton.IsHostStyled()
  local mmDesc = mmHostStyled and L["OPT_MINIMAP_DESC_EUI"] or L["OPT_MINIMAP_DESC"]
  local UpdateMinimapCardState -- defined once the card exists below

  local mmToggle = CreateFrame("CheckButton", nil, col, "UICheckButtonTemplate")
  mmToggle:SetSize(CHECK_H, CHECK_H)
  mmToggle:SetPoint("TOPRIGHT", col, "TOPRIGHT", -PAD + 4, mmHeadingY + 5)
  mmToggle.__postboxCheck = true
  local mmToggleLabel = ns.Theme.CreateText(col, "label")
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

  card = StartCard(col, y)
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

  y = EndSection(col, card, y)
  local rightBottom = y
  -- Back on the panel's own cursor: the taller column's bottom, and the
  -- footer band under it.
  y = colTop + math.min(leftBottom, rightBottom) + 16

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
  -- Wider than the options panel it opens from, and unrelated to it: the
  -- panel's width is a column of controls, this is a window for reading long
  -- diagnostic lines out of without every one of them wrapping twice.
  local BUG_W, BUG_BOX_W = 440, 416
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
      viewport:SetSize(BUG_BOX_W, boxHeight)
      viewport:SetPoint("TOPLEFT", pop, "TOPLEFT", 10, rowY - 14)

      box = CreateFrame("EditBox", nil, viewport)
      box:SetWidth(BUG_BOX_W)
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
      box:SetSize(BUG_BOX_W, 14)
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
      -- Height: the diagnostic box's own 200, plus the 74 above it (title,
      -- address row, second caption) and the 22 the hint line needs below.
      bugPopup:SetSize(BUG_W, 296)
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
      -- 200, was 100: the report grew from six lines to something nearer
      -- twenty, and a box that shows a third of it makes a reader scroll to
      -- find out whether it is worth copying at all. It still scrolls.
      bugPopup._diag = AddCopyRow(bugPopup, -60, "OPT_BUG_DIAG_LABEL", 200)

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
  frame:SetSize(2 * W - 10, math.abs(frame.__pbContentBottom or y) + PAD)

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
